# Replacing Pinba2 histograms with t-digest

Research date: 2026-08-28. This note evaluates t-digest for Pinba2, with the
implementation evidence and local benchmarks centered on the two C/C++
implementations that preallocate their working storage:
[RedisBloom/t-digest-c](https://github.com/RedisBloom/t-digest-c) and
[TIER IV/digestible](https://github.com/tier4/digestible). Apache DataSketches,
Arrow, Folly, and ClickHouse are retained only as secondary references.

The benchmarks are directional microbenchmarks on one host. They are not an
end-to-end MySQL/Pinba report benchmark and do not establish a production
compression setting.

## Decision

Use RedisBloom/t-digest-c as the first implementation baseline, behind a
Pinba-owned fixed-storage adapter. Do not adopt `digestible` unchanged.

Both implementations meet the central allocation requirement: after three
construction allocations, their ordinary update, compression, query, and
pairwise merge paths made zero further allocator calls in local probes. The
selection is instead decided by correctness and merge behavior:

- RedisBloom accepts integer-weighted observations, rejects non-finite values,
  checks weight overflow, has an active test suite, and kept every measured
  percentile within 0.34% after the shared 60-tick merge at compression 100.
  Its main weaknesses are forward-only/order sensitivity and comparatively
  expensive compression when a live digest is frozen into history.
- `digestible` used less aggregation workspace and had more balanced accuracy
  on a single stream, but its released source has a blocking weighted-endpoint
  bug: when a boundary
  observation has weight greater than one, `min`, `max`, p0, or p100 can remain
  floating-point sentinel values. This directly conflicts with Pinba timer
  aggregation. Its sequential digest-to-digest merge also had unstable p99.9
  error that became worse as capacity increased in this workload.
- RedisBloom is not a complete final implementation either. Its source always
  compresses from left to right even though the public header comment attached
  to `total_compressions` says merges alternate direction, and its public
  `td_merge` sequentially folds and
  recompresses sources. Pinba should wrap precompressed immutable histories in
  a deterministic, allocation-conscious `merge_many` path and validate
  ordering/tie behavior independently.

The recommended product architecture remains two explicit report-level
pipelines:

```text
legacy:  observation -> HDR accumulator -> flat history -> flat merge/query
tdigest: observation -> digest accumulator -> centroid history -> digest merge/query
```

Do not make HDR-to-t-digest conversion the permanent design. It would digest
weighted bucket representatives rather than original observations, compounding
HDR quantization with t-digest approximation and moving conversion work onto
tick rotation. Keep the existing histogram pipeline for compatibility and raw
histogram output; make t-digest an opt-in percentile representation.

## Findings at a glance

| Criterion | RedisBloom/t-digest-c | TIER IV/digestible |
|---|---|---|
| Post-construction allocation | None observed in add/compress/query/merge | None observed in insert/merge/query; `get()` does allocate |
| Weighted observations | `long long`, with overflow checks | Templated, but weighted extrema are incorrect |
| Non-finite input | Rejected | No equivalent robust validation |
| Working storage | Fixed parallel arrays, `6c+10` slots | Three reserved vectors, `k+k+2k` slots |
| Merge direction | Always forward in current source | Alternates forward/reverse |
| Multi-digest merge | Allocation-free sequential fold; mutates sources by compressing them | Allocation-free sequential fold; explicit merge after each source |
| Shared-workload merge, parameter 100 | 0.145 ms/row | 0.235 ms/row |
| Shared-workload merged error, parameter 100 | p50 +0.21%, p90 +0.01%, p99 -0.33%, p99.9 -0.19% | p50 +1.02%, p90 +0.33%, p99 +0.53%, p99.9 +5.77% |
| Reserved centroid payload, parameter 100 | 9,840 B/digest including struct | 6,400 B/digest excluding vector objects |
| Maintenance evidence | Recent fixes, unit and complexity tests | Small source tree; README refers to tests absent from current repository |
| Selection | Primary prototype baseline | Performance/algorithm reference requiring a correctness fork |

The numeric parameters are not equivalent compression scales. Compare actual
error, retained centroids, workspace, and time—not `c == k` alone.

## Current Pinba2 baseline and compatibility contract

Pinba's observation hot path uses an arena-backed HDR-style histogram, not
`flat_histogram_t`. For request and timer reports, tick rotation converts HDR
counters into sparse sorted `(bucket_id, count)` history. Packet history retains
HDR histograms directly.

[`histogram___configure_with_rinfo`](../../include/pinba/report_util.h#L544)
uses the configured bucket width as the HDR unit and fixes precision at seven
bits. For the README example `hv=0:2000:20000`, the expanded HDR has 1,152
`uint32_t` counters: 4,608 bytes, plus the initial 512-byte allocation retained
because [`nmpa_realloc`](../../include/misc/nmpa.h#L200) allocates and copies.
The request/timer history representation costs roughly 40 bytes plus eight
bytes per populated bucket.

On SELECT, request/timer rows lazily k-way merge their sorted sparse histories
([`multi_merge.h`](../../include/pinba/multi_merge.h#L47)). Each requested
percentile then scans the merged histogram separately. Packet snapshots merge
dense HDR arrays eagerly.

Any new percentile adapter must preserve or intentionally version these
observable behaviors:

- durations are rounded upward to `unit_size`;
- timer samples insert `timer.value / hit_count` with integer weight
  `hit_count` ([`report_by_timer.cpp`](../../src/report_by_timer.cpp#L259));
- below/above-range observations remain exact side counters and participate in
  rank selection;
- rank is `ceil(total_count * percentile / 100)`;
- empty and p0 return the configured minimum; for in-range data, p100 returns
  the upper bound of the highest occupied HDR bucket (capped at the configured
  maximum), while a rank in positive overflow returns the configured maximum;
- total weight and side counters cannot silently overflow;
- the existing raw histogram field exposes bucket counts and cannot honestly be
  reconstructed from t-digest centroids.

T-digest interpolation is not the current uniform-within-bucket interpolation.
Correctness must therefore be judged against exact sorted observations, with an
explicit value/rank error budget, rather than equality with the old histogram.

## Primary implementation audit

### RedisBloom/t-digest-c

The audited revision is
[`daf1f4a53d44a4efbee2c94edabed302010c23db`](https://github.com/RedisBloom/t-digest-c/commit/daf1f4a53d44a4efbee2c94edabed302010c23db),
dated 2026-07-29. It is MIT licensed.

`td_init()` allocates one `td_histogram_t` and two parallel arrays:

```text
capacity = 6 * compression + 10
means    = double[capacity]
weights  = long long[capacity]
```

The allocator is replaceable through `TD_MALLOC_INCLUDE`. `td_add()` appends
into the fixed arrays and calls `td_compress()` at capacity. Compression sorts
and compacts the same arrays in place using introsort with a heapsort fallback.
`td_quantile`, `td_quantiles`, and `td_merge` allocate no scratch storage.

Primary source:
[pinned `tdigest.c`](https://github.com/RedisBloom/t-digest-c/blob/daf1f4a53d44a4efbee2c94edabed302010c23db/src/tdigest.c),
[pinned public header](https://github.com/RedisBloom/t-digest-c/blob/daf1f4a53d44a4efbee2c94edabed302010c23db/src/tdigest.h).

Local allocator instrumentation created two digests with six allocator calls,
then performed two million additions, forced compression, p99 lookup, and a
merge without another call. The upstream 28-test unit binary completed roughly
5.16 million assertions with no failures. Its duplicate-heavy and adversarial
sort regression passed, confirming the current O(n log n) fallback behavior.

Limitations relevant to Pinba:

- `td_merge(into, from)` compresses both arguments, then replays every source
  centroid through `td_add`. A 60-tick SELECT therefore repeatedly sorts and
  compresses the destination and mutates the source into compressed form.
- Current `td_compress()` always scans the sorted centroids forward.
  `total_compressions` is incremented but is not used to alternate direction.
- Its custom sort is not a stable reference merge. Repeated values, insertion
  order, and merge trees need explicit accuracy tests.
- Weights are signed `long long`. A Pinba wrapper should accept only positive
  weights, check conversion from its count type, and retain its own `uint64_t`
  totals and range counters.
- The pointer-owning C object is easy to vendor but not the ideal final
  interface. A placement/caller-storage initializer would integrate more
  cleanly with `nmpa` and eliminate three independent allocations per row.

### TIER IV/digestible

The audited revision is
[`d76950a19002d7abc393b0e3d778038b801887b4`](https://github.com/tier4/digestible/commit/d76950a19002d7abc393b0e3d778038b801887b4).
It is Apache-2.0 licensed and requires C++17, which is acceptable for this work.

The class reserves three vectors at construction: two centroid vectors of
capacity `k` and one pending buffer of capacity `2k`. Insertions fill the pending
buffer; compression sorts it, writes into the inactive vector, alternates merge
direction, and reuses all three capacities. Source:
[pinned `digestible.hpp`](https://github.com/tier4/digestible/blob/d76950a19002d7abc393b0e3d778038b801887b4/include/digestible/digestible.hpp).

Allocator instrumentation confirmed three construction allocations and zero
additional allocations for one million inserts, explicit compression, and
sequentially merging 60 digests. The convenience `get()` constructs a returned
vector and does allocate.

The source-backed no-allocation claim is real, but correctness blocks adoption.
The following local reproduction uses its intended weighted interface:

```cpp
digestible::tdigest<double, uint64_t> d(20);
d.insert(10, 2);
d.insert(20, 2);
d.merge();
```

Observed output was:

```text
min = DBL_MAX
max = numeric_limits<double>::min()
p0  = DBL_MAX
p100 = numeric_limits<double>::min()
```

The merge implementation updates `min_val` and `max_val` only when a boundary
centroid has weight exactly one. It also uses `numeric_limits<T>::min()` in one
maximum fallback, which is the smallest positive floating value rather than the
most negative value. A wrapper could track exact endpoints separately, but this
defect, lack of robust finite/overflow validation, use of unstable `std::sort`,
and the current repository's missing tests make an unmodified dependency too
risky. `reset()` also leaves `run_forward` unchanged, so a reused digest does
not return to its construction-state merge direction. Fresh objects were used
for the recorded accuracy results. The merged-tail benchmark below reveals a
further issue that endpoint side fields alone would not fix.

### Secondary implementations

- Apache DataSketches C++ reserves ingest buffers, but `compress()` and
  `merge()` allocate temporary vectors. Its earlier local benchmark is removed
  from the decision tables because it does not satisfy the target allocation
  architecture.
- Apache Arrow preallocates its single-digest ingest path, but its multi-digest
  merge builds queue/vector storage dynamically and does not expose the required
  weighted point-add interface.
- Folly can reuse a warmed working buffer for selected sorted paths, but its
  default unsorted and multi-digest operations allocate and its interface does
  not directly provide Pinba's weighted add.
- ClickHouse is a useful production reference, but its `PODArray` grows and its
  centroid counts are `Float32`.
- Derrick Burns' implementation allocates processing/merge temporaries and is
  archived.

These remain algorithm and test references, not candidate dependencies.

## Microbenchmark methodology

Both primary candidates were compiled on Darwin arm64 with Apple Clang 21,
`-O3 -DNDEBUG`; `digestible` used C++17 and RedisBloom's implementation was
compiled as C99 and linked into a C++17 harness.

Inputs were generated before timed sections:

```text
PRNG             mt19937_64, seed 0x5eed
distribution     lognormal(log(200), 0.9)
normalization    ceil, then clamp to [1, 20000]
direct workload  1,000,000 observations in one digest
SELECT workload  60 independent tick digests x 1,000 observations
percentiles      p50, p90, p99, p99.9
oracle           exact nearest rank: ceil(q * N)
timing           median of five runs
```

Fresh digest objects were used for direct accuracy and SELECT merge timing.
This avoids allowing `digestible::reset()`'s retained merge direction to make
later repetitions start in a different algorithmic state.

The update benchmark measures insertion and automatic compression. The
RedisBloom direct update excludes one final explicit compression; the
`digestible` direct measurement includes it. That O(capacity) difference is
negligible across one million inputs but should be separated in an end-to-end
tick benchmark. The 1,000-observation tick measurements exclude final freeze
compression and report it separately for both implementations.

The SELECT benchmark uses each upstream public merge path: a fresh destination
sequentially consumes 60 already compressed source digests. Source compression
is outside the timer because it belongs to tick freeze, not SELECT. The result
therefore measures what can be adopted today, not a hypothetical k-way merge.

Centroid history bytes below are `used_centroids * 16` for `double` mean plus
64-bit integer weight. They exclude a small history header containing totals,
configured/observed endpoints, and side counters. Working bytes include fixed
centroid payload; `digestible` vector objects/allocator metadata are excluded.

Nominal `compression` and `k` values are not equivalent. The tables show all
settings so selection can be based on measured error and actual byte counts.

## Microbenchmark results

### Allocation behavior

| Operation | RedisBloom | digestible |
|---|---:|---:|
| Construct one digest | 3 allocations | 3 allocations |
| Updates after construction | 0 | 0 |
| Automatic/explicit compression | 0 | 0 |
| Sequential digest merge | 0 | 0 |
| Quantile query | 0 | 0 |
| Convenience centroid export | Caller reads arrays directly | `get()` allocates |

Both meet “no allocation after construction.” For Pinba, construction should
occur on the existing new-row path and use tick-arena/caller storage. Ordinary
updates of an existing report row can then remain allocation-free.

### Aggregation update performance

| Parameter | Redis direct, ns/value | Redis 1K-tick insert, ns/value | digestible direct, ns/value | digestible 1K-tick insert, ns/value |
|---:|---:|---:|---:|---:|
| 20 | 43.6 | 39.9 | 48.4 | 44.8 |
| 50 | 48.1 | 41.8 | 51.9 | 44.5 |
| 100 | 52.1 | 32.3 | 56.1 | 47.1 |
| 200 | 55.4 | 6.5 | 59.9 | 34.0 |

RedisBloom was modestly faster in every like-numbered direct test. The 1K-tick
numbers expose a more important structural effect: at `c=200`, Redis capacity
is 1,210, so a 1,000-observation tick only appends and does not compress during
insertion. `digestible(k=200)` has a 400-entry pending buffer and still performs
automatic compression. For `digestible`, the final per-source compression cost
was 0.00086, 0.00145, 0.00356, and 0.01484 ms at k=20/50/100/200.

This does not mean `c=200` is automatically best. It shifts work from the
observation path to tick freeze and reserves 19.4 KiB per live digest. The
design can exploit the trade-off deliberately: size the pending capacity above
the expected observations per row per tick when zero compression latency in
the update path matters, then measure freeze latency and active memory.

Final compression of each 1,000-observation source history cost:

| Parameter | Redis freeze, ms/source | digestible freeze, ms/source |
|---:|---:|---:|
| 20 | 0.00266 | 0.00086 |
| 50 | 0.00486 | 0.00145 |
| 100 | 0.01705 | 0.00356 |
| 200 | 0.04495 | 0.01484 |

`digestible` freezes 3-5x faster in this workload. Redis c=200 makes insertion
almost a pure append but then spends about 45 microseconds per populated report
row at tick rotation. Freeze latency and row cardinality must be benchmarked
together; shifting work out of `add()` does not make it disappear.

The old Apache-based 3.5-4.4x update ratio is no longer used. It included random
number generation inside timed regions and did not represent the selected
implementations. A production decision needs the candidate adapter and actual
`hdr_histogram_t` in one optimized harness with pre-generated inputs.

### SELECT merge performance and history size

| Parameter | Redis sequential merge, ms/row | Redis history B/tick | digestible sequential merge, ms/row | digestible history B/tick |
|---:|---:|---:|---:|---:|
| 20 | 0.048 | ~265 | 0.034 | ~197 |
| 50 | 0.091 | ~445 | 0.110 | ~427 |
| 100 | 0.145 | ~668 | 0.235 | ~829 |
| 200 | 0.263 | ~1,104 | 0.430 | ~1,537 |

The existing directional Pinba-like workload had about 423 sparse history
entries, or 3,385 bytes/tick of `(uint32_t bucket, uint32_t count)` payload, and
about 0.306 ms/row for a 60-way sparse merge. That number came from a different
harness and should be treated as context, not a precise head-to-head result.

The conclusions that survive that caveat are:

- both t-digests substantially reduce dense history payload;
- both implementations beat the contextual sparse merge at parameter 100;
- Redis c=100 was directionally about 2.1x faster than the contextual
  sparse-histogram result and, in the shared harness, about 1.6x faster than
  `digestible` k=100;
- Redis was faster than `digestible` at parameters 50/100/200 once both consumed
  already-frozen histories; `digestible` was faster at parameter 20;
- the upstream Redis sequential fold is a viable prototype. A k-way merge is a
  later optimization/accuracy experiment, not a prerequisite for beating the
  contextual SELECT result.

### Accuracy: direct stream

Relative value error against exact nearest-rank values:

| Implementation | Parameter | p50 | p90 | p99 | p99.9 |
|---|---:|---:|---:|---:|---:|
| RedisBloom | 20 | +15.42% | +4.32% | +3.14% | +2.63% |
| RedisBloom | 50 | +1.11% | +1.96% | +2.47% | +0.91% |
| RedisBloom | 100 | +2.18% | +0.93% | +0.91% | +0.17% |
| RedisBloom | 200 | +0.57% | +0.78% | +0.20% | +0.05% |
| digestible | 20 | +17.25% | +25.21% | -2.13% | -12.13% |
| digestible | 50 | +2.54% | -0.14% | +1.76% | +0.97% |
| digestible | 100 | +0.69% | +0.70% | +0.43% | +0.63% |
| digestible | 200 | +0.13% | +0.36% | +0.14% | +0.96% |

`digestible` is more balanced on a single stream at k>=50; RedisBloom strongly
prioritizes the far tail and needs higher compression for acceptable median
accuracy. This one distribution must not be generalized into a guarantee.

### Accuracy: sequentially merged 60 ticks

| Implementation | Parameter | p50 | p90 | p99 | p99.9 |
|---|---:|---:|---:|---:|---:|
| RedisBloom | 20 | +11.63% | +2.44% | +0.62% | +0.74% |
| RedisBloom | 50 | +0.98% | +1.21% | -0.63% | -0.64% |
| RedisBloom | 100 | +0.21% | +0.01% | -0.33% | -0.19% |
| RedisBloom | 200 | +0.21% | ~0% | -0.16% | +0.10% |
| digestible | 20 | +20.04% | +1.16% | -2.39% | +2.54% |
| digestible | 50 | +1.79% | +0.40% | -0.26% | +3.00% |
| digestible | 100 | +1.02% | +0.33% | +0.53% | +5.77% |
| digestible | 200 | +0.52% | +0.31% | +1.36% | +13.23% |

RedisBloom at c=100 was the smallest tested configuration keeping all four
errors within one percent after this merge tree. `digestible` did not have a
tested setting with all four within one percent; increasing k made merged
p99.9 materially worse. This is a blocking observation for the current
digest-to-digest merge, not a universal judgment on its k2 scale function.

RedisBloom pathology probes found all-equal inputs exact. Ascending order still
showed order sensitivity: at c=50 p50/p99 were about +5.3%/+3.4%, and at c=100
p50/p99 were about +1.0%/+1.6%. This is consistent with the need to test its
forward-only compression and duplicate ordering. A separate probe of
`digestible`'s default `float,unsigned` specialization was exact for all-equal
inputs; ascending p99 error was approximately +11.6% at k=20 and about
+0.4%/+0.2% at k=100/200. Repeat these pathologies with the selected Pinba
types before using them as a selection threshold.

## Memory implications

### Active aggregation

| Parameter | Redis fixed bytes/digest | digestible centroid working bytes/digest |
|---:|---:|---:|
| 20 | 2,160 | 1,280 |
| 50 | 5,040 | 3,200 |
| 100 | 9,840 | 6,400 |
| 200 | 19,440 | 12,800 |

Redis values include its 80-byte struct and two arrays. `digestible` values are
the four centroid capacities only and exclude three vector objects and
allocator metadata.

Against the common expanded Pinba HDR footprint of about 5,120 bytes including
the abandoned initial block, Redis c=100 is roughly 1.9x and c=200 roughly
3.8x. Both stay below the requested 10x budget for that expanded case. Against
a sparse row that never expands beyond the initial 512 bytes, they are roughly
19x and 38x. High-cardinality, low-sample reports are therefore the principal
active-memory risk.

Do not solve that immediately with a per-row adaptive promotion scheme. Lazy
promotion would allocate during an existing-row update, while preallocating the
promoted state loses the memory benefit. Start with an explicitly selected
digest report and measure live rows/sample counts; add slab-backed promotion
only if real workloads justify the extra state machine.

### Report history

History should contain only immutable used centroids plus total, configured and
observed endpoints, underflow, and overflow. It must not retain input,
alternate-output, or sort buffers. On the shared dense workload, both candidates
reduced centroid payload versus the contextual 3.4 KiB sparse history. Sparse
rows with only a few populated buckets can still be smaller in the legacy
format, which is another reason not to replace all reports automatically.

## Recommended Pinba implementation

Define a deep distribution module with a small caller-facing interface:

```cpp
class distribution_accumulator {
public:
    status add(duration_t value, uint64_t weight = 1) noexcept;
    frozen_distribution freeze(history_arena&) &&;
};

class frozen_distribution {
public:
    static status merge_many(span<const frozen_distribution>,
                             merge_scratch&, frozen_distribution& out);
    status quantiles(span<const double>, span<duration_t> out) const noexcept;
};
```

Histogram and t-digest are two adapters at this seam. The interface owns
rounding, side counters, endpoint behavior, overflow/error handling,
deterministic merge topology, and batched percentile calculation.

For the first digest adapter:

1. Pin RedisBloom revision `daf1f4a` as the behavioral baseline and import its
   tests and allocation probe.
2. Replace pointer-owning construction with caller-provided/arena storage for
   the struct, means, and weights. Construction occurs on the existing new-row
   path; `add()` remains allocation-free.
3. Preserve the configured range, exact observed extrema, and under/overflow
   counters in the wrapper. Explicitly version p100 semantics if digest reports
   return the observed maximum instead of the legacy highest-bucket bound.
   Accept only positive weights that fit both Pinba totals and the
   implementation representation.
4. Freeze once at tick rotation and copy only used centroids into history.
5. First implement `merge_many` as a deterministic sequential fold over
   precompressed, immutable centroid streams, matching the measured Redis
   behavior without its non-const source interface. Use reusable destination
   storage. Treat a one-pass k-way merge and alternating direction as separate
   experiments, because either changes merge topology and therefore accuracy;
   do not rely on the stale struct comment.
6. Build cumulative weights once and answer all configured percentiles in one
   ordered pass.
7. Add an explicit digest configuration and histogram kind. Do not reinterpret
   legacy bucket count as compression. Disable legacy raw-histogram output for
   digest reports or define a versioned centroid format.

`digestible` remains valuable as a performance target and source for an
alternating-direction/k2 experiment. Before reconsidering it, fix weighted
endpoints, finite/weight validation, stable duplicate handling, source merge,
and add a substantial test suite. Then rerun the exact matrix; C++17 itself is
not an obstacle.

## Required validation before adoption

The benchmark matrix must include:

| Dimension | Cases |
|---|---|
| Distribution | uniform, log-normal, exponential, bimodal, heavy tail/log-uniform |
| Ordering | random, ascending, descending, alternating extremes |
| Values | all equal, repeated clock values, singleton outliers, endpoints, under/overflow |
| Counts | empty, 1, 2, 10, 100, 1K, 1M; large weighted timer batches |
| Percentiles | p0, p0.01, p1, p50, p90, p95, p99, p99.9, p100 |
| Merge topology | direct, sequential, balanced, deterministic k-way; 1/2/10/60/1000 inputs |
| Report shape | sparse/dense histories, low/high row cardinality, 1/5/20 percentiles |

For every case record exact value and rank error, total weight, endpoint/range
behavior, update and freeze p50/p99 latency, active and history bytes,
allocations after construction, SELECT merge latency, and batched query latency.

Reject a candidate for any lost weight, weighted endpoint failure, non-finite
poisoning, silent capacity/overflow failure, or aggregation-path allocation.
Define percentile error thresholds before tuning. The shared benchmark suggests
Redis c=100 as the first configuration to investigate, not as a default.

## Limitations of this study

- Timings are one Apple arm64 host and standalone optimized harnesses.
- The candidate implementations used their upstream sequential merge methods;
  a one-pass Pinba k-way alternative has not been implemented or measured.
- The contextual Pinba sparse merge came from an earlier harness, not the same
  binary as the new candidate benchmarks.
- Only one random distribution and small ordering pathologies were measured.
- Payload figures omit history/container/allocator headers as noted.
- Neither t-digest implementation has yet been exercised through Pinba's report
  worker, tick, snapshot, or SQL code.

The result is a refined library selection and prototype plan, not approval to
replace the existing histogram.

## Primary sources

- [Dunning & Ertl, *Computing Extremely Accurate Quantiles Using t-Digests*](https://arxiv.org/abs/1902.04023)
- [Dunning, *The Size of a t-Digest*](https://arxiv.org/abs/1903.09921)
- [tdunning/t-digest reference repository](https://github.com/tdunning/t-digest)
- [RedisBloom/t-digest-c repository](https://github.com/RedisBloom/t-digest-c)
- [RedisBloom pinned implementation](https://github.com/RedisBloom/t-digest-c/blob/daf1f4a53d44a4efbee2c94edabed302010c23db/src/tdigest.c)
- [RedisBloom pinned public header](https://github.com/RedisBloom/t-digest-c/blob/daf1f4a53d44a4efbee2c94edabed302010c23db/src/tdigest.h)
- [TIER IV/digestible repository](https://github.com/tier4/digestible)
- [digestible pinned implementation](https://github.com/tier4/digestible/blob/d76950a19002d7abc393b0e3d778038b801887b4/include/digestible/digestible.hpp)
- [Apache DataSketches t-digest overview](https://datasketches.apache.org/docs/tdigest/tdigest.html)
- [Apache Arrow TDigest implementation](https://github.com/apache/arrow/blob/main/cpp/src/arrow/util/tdigest.cc)
- [Folly TDigest implementation](https://github.com/facebook/folly/blob/main/folly/stats/TDigest.cpp)
- [ClickHouse QuantileTDigest implementation](https://github.com/ClickHouse/ClickHouse/blob/master/src/AggregateFunctions/QuantileTDigest.h)

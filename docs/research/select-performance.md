# SELECT performance opportunities

Research date: 2026-08-28.

## Scope and conclusion

This is a production-read-only investigation. It identifies opportunities in
the MySQL handler and report snapshot path; it changes no production behavior.
Only this note and isolated benchmark tools were added. The repository already
keeps research notes in `docs/research/`, so this note uses that convention.

The dominant cost is not the `rnd_next()` iterator itself. Every report SELECT
first builds a complete in-memory snapshot from all retained ticks, then emits
rows through MySQL `Field::store()`. Percentile and key-string work can add a
second large per-row cost. The README records an existing baseline of about
200 ms for 300k rows without percentiles and about 300 ms additional cost for a
10k-entry histogram percentile workload (`README.md:36-40`).

## Current SELECT path

1. `pinba_handler_t::rnd_init()` activates a report if needed, then delegates
   to the view (`mysql_engine/handler.cpp:1327-1361`). A report snapshot view
   calls `get_report_snapshot()` and determines whether selected columns need
   histograms (`mysql_engine/handler.cpp:645-730`).
2. `report_snapshot__impl_t::prepare()` calculates source-row statistics,
   gathers repacker state, merges all retained ticks, and optionally calculates
   totals (`include/pinba/report_util.h:266-307`). It is cached for the lifetime
   of the SELECT (`include/pinba/report_util.h:266-270`).
3. Request and timer reports walk every row in every retained tick and perform a
   hash-table lookup/insertion for each source row. If histograms are requested,
   they also append one source histogram pointer per row
   (`src/report_by_request.cpp:490-563`, `src/report_by_timer.cpp:813-885`).
4. Each `rnd_next()` advances an unordered-map iterator and calls
   `fill_row_at_position()` (`mysql_engine/handler.cpp:583-596`). The fill path
   loops over every table field, tests `read_set`, converts keys and metrics,
   computes percentiles, and can serialize a raw histogram
   (`mysql_engine/handler.cpp:758-1055`).
5. MySQL's handler contract treats `rnd_init`/`rnd_next` as the full-table-scan
   interface and uses `position`/`rnd_pos` for rows retained by sorting
   (`handler` API documentation, [full-scan module](https://dev.mysql.com/doc/dev/mysql-server/8.0.46/classhandler.html#details),
   [source comments](https://dev.mysql.com/doc/dev/mysql-server/latest/sql_2handler_8h_source.html)).

## Prioritized opportunities

### 1. Do not decode keys when no key column is selected

**Evidence.** `fill_row_at_position()` unconditionally calls
`snapshot_->get_key_str(row_pos)` before inspecting `table->read_set`
(`mysql_engine/handler.cpp:762-781`). Thus `SELECT` of only metric columns
still translates every key part for every returned row. The conversion walks
all key parts and calls the global dictionary (`include/pinba/report_util.h:374-391`).

**Change to investigate.** Check whether `read_set` intersects the key-column
range before calling `get_key_str()`, and decode lazily on the first selected
key field. Keep output ordering and NULL/error behavior unchanged.

**Expected impact.** High for reports with wide keys and metric-only queries;
near-zero for `SELECT *` or queries selecting all keys. Confidence: high.

**Validation.** Benchmark the same 100k/300k-row snapshot with (a) metric-only
projection, (b) one key, and (c) all keys. Count dictionary calls and measure
wall time and allocations. Compare result bytes and NULL behavior.

### 2. Use the existing snapshot dictionary cache for key materialization

**Evidence.** A per-snapshot `snapshot_dictionary_t` exists specifically to
cache `word_id -> word` translations during snapshot scans
(`include/pinba/snapshot_dictionary.h:11-16`, `:49-73`). Its cache avoids the
global dictionary read lock after the first lookup. The active code instead
uses `dictionary()->get_word()`; the intended cache call is left commented out
(`include/pinba/report_util.h:380-390`). Each global lookup takes a shard read
lock (`include/pinba/dictionary.h:420-438`).

**Change to investigate.** Route `get_key_str()` through
`snapshot_dictionary()->get_word()` after opportunity 1's projection check.
Verify that the snapshot retains all needed repacker/dictionary lifetimes; the
snapshot already accumulates repacker state before merging
(`include/pinba/report_util.h:279-287`).

**Expected impact.** Medium to high when many rows repeat key IDs or when
concurrent aggregation makes dictionary lock traffic visible. Confidence:
high. This is a localized optimization, but lifetime and cache-capacity tests
are required.

**Validation.** Compare cache hit/miss counts, dictionary lock samples, and
SELECT latency for repeated versus unique key IDs. Run concurrent ingestion
while scanning.

The cache itself also needs measurement before activation. Every snapshot
constructs it eagerly (`include/pinba/report_util.h:228-240`), and its dense
hash starts with 32k buckets, documented as about 1.5 MiB
(`include/pinba/snapshot_dictionary.h:28-39`). That cost is currently paid even
when no key is selected, despite the cache being bypassed. Test lazy creation
and cardinality-based sizing together with the lookup change.

### 3. Calculate requested percentiles in one histogram pass

**Evidence.** Every requested percentile field independently calls
`get_percentile()` (`mysql_engine/handler.cpp:908-956`). The flat-histogram
implementation scans `hv.values` from the beginning for each percentile
(`include/pinba/histogram.h:52-117`). The source explicitly records this as a
TODO (`mysql_engine/handler.cpp:908-912`). Histogram merging itself is lazy and
cached after first access (`src/report_by_request.cpp:394-459`,
`src/report_by_timer.cpp:718-783`), so this opportunity concerns percentile
scans, not repeated merge work.

**Change to investigate.** Build a per-row request plan containing percentile
positions, sort positions by required rank, walk sorted buckets once, and write
answers back in original column order. Preserve the current ceiling rule,
infinity fast paths, and interpolation semantics (`include/pinba/histogram.h:60-115`).

**Expected impact.** High for multiple percentiles and long sparse histograms;
none for one percentile. Confidence: high. README's existing 10k-entry
histogram observation makes this worth measuring (`README.md:36-40`).

**Validation.** Compare one, three, and ten percentile columns over sparse and
dense histograms. Assert byte-for-byte equal numeric results, including p0,
p100, empty histograms, infinity counts, duplicate percentiles, and unsorted
percentile declarations.

### 4. Do not calculate totals unless a selected field needs them

**Evidence.** The handler always requests `with_totals`, with the comment that
totals are needed for percentage fields (`mysql_engine/handler.cpp:721-728`).
Snapshot preparation consequently performs another pass over every unique row
(`include/pinba/report_util.h:302-303`; request implementation at
`src/report_by_request.cpp:475-487`, timer at
`src/report_by_timer.cpp:799-810`). Absolute metrics, rates, keys,
percentiles, and raw histograms do not read these totals.

**Change to investigate.** Inspect `read_set` for the percent-of-total columns
and set `with_totals` only when at least one is required. A later prototype can
test accumulating totals during the mandatory source merge, but projection
gating is the smaller first experiment.

**Expected impact.** Medium for large high-cardinality reports queried without
percentage columns; none for `SELECT *` and percentage projections.
Confidence: high.

**Validation.** Compare `SELECT key, req_count` with a percentage projection on
the same snapshot. Count unique-row visits in `calculate_totals()` and assert
that all selected results remain identical.

### 5. Reduce percentile snapshot over-reservation

**Evidence.** When histograms are requested, the first occurrence of every
unique row reserves `ticks.size()` pointers, even if that key occurs in only one
tick (`src/report_by_request.cpp:535-544`,
`src/report_by_timer.cpp:857-866`). With 300k unique rows, 60 ticks, and 8-byte
pointers, pointer capacity alone can reach about 144 MB. When those histogram
sequences are later merged, `multi_merge()` reserves the sum of all input
lengths before coalescing duplicate buckets (`include/pinba/multi_merge.h:64-93`),
so repeated bucket IDs can cause another large over-allocation.

**Change to investigate.** Benchmark incremental or small-buffer growth for
`saved_hv`, and cap or estimate merged histogram reserve by expected unique
buckets. Do not choose a policy until both sparse-across-ticks and
dense-repeated-key workloads are measured.

**Expected impact.** High peak-memory opportunity for percentile SELECTs;
potential latency gain from fewer oversized allocations and less allocator
traffic. Confidence: high on over-allocation, medium on best growth policy.

**Validation.** Measure peak RSS, allocated capacity, allocations, and SELECT
latency for disjoint keys across ticks versus the same keys repeated in all
ticks. Verify merged histogram contents exactly.

### 6. Improve optimizer row estimates without preparing a snapshot in `info()`

**Evidence.** `pinba_handler_t::info()` initializes `stats.records` to 2 and
the report snapshot view's `info()` does nothing
(`mysql_engine/handler.cpp:1491-1500`, `:619-623`). The handler comments
already note that `info()` feeds the optimizer and that a one-row estimate can
change server behavior (`mysql_engine/handler.cpp:1453-1478`). MySQL's handler
documentation identifies `info()` and the `records` attribute as optimizer
inputs ([information calls and optimizer support](https://dev.mysql.com/doc/dev/mysql-server/8.0.46/classhandler.html#information-calls)).

**Change to investigate.** Publish a cheap, non-blocking row-count estimate
from report state/history metadata for `info()`; do not construct or merge the
full snapshot there. Do not set `HA_STATS_RECORDS_IS_EXACT`: the current table
row count changes with ticks and deduplication, and the flag is intentionally
not advertised (`mysql_engine/handler.h:117-134`).

**Expected impact.** Medium for `ORDER BY`, `GROUP BY`, joins, and `LIMIT`
queries where MySQL's plan depends on cardinality; no direct gain in raw scan
throughput. Confidence: medium until measured against the supported MySQL/
MariaDB versions.

**Validation.** Capture `EXPLAIN`, optimizer trace if available, filesort
behavior, and end-to-end latency before/after estimates for 1-row, 1k-row, and
300k-row reports. Ensure `info()` does not wait on the report thread or change
snapshot consistency.

### 7. Treat LIMIT/WHERE and ORDER BY as architectural opportunities, not quick fixes

**Evidence.** Request and timer views expose no index methods or index flags
(`mysql_engine/handler.h:139-159`, `:221-227`), and their merge path produces a
complete hash table from all retained ticks (`src/report_by_request.cpp:512-545`,
`src/report_by_timer.cpp:835-867`). Consequently, a `LIMIT` or server-side
`WHERE` does not avoid snapshot preparation. MySQL documents that condition
pushdown can avoid returning nonmatching rows only when the handler evaluates a
pushed condition ([`cond_push` contract](https://dev.mysql.com/doc/dev/mysql-server/latest/sql_2handler_8h_source.html)).
However, the MySQL 5.7 manual limits engine condition pushdown to NDB
([condition-pushdown overview](https://dev.mysql.com/doc/refman/5.7/en/engine-condition-pushdown-optimization.html)),
so it is not a demonstrated quick route for this custom engine. This handler
also has no condition-pushdown implementation or report index contract.

The repository's own notes confirm the symptom: sorting 30k rows was still
about 300 ms after `position()`/`rnd_pos()` were added, and the remaining item
is explicitly marked as unresolved (`TODO.md:7-10`). The unordered snapshot
iterator and MySQL filesort call sequence are documented in
`mysql_engine/handler.cpp:507-549`.

**Change to investigate later.** First measure query-shape demand. Then choose
one narrowly scoped capability: report-key lookup, an ordered snapshot index,
or top-K selection for a supported `ORDER BY ... LIMIT` pattern. Condition
pushdown must preserve report snapshot semantics and MySQL's remainder-
condition contract; it should not be attempted as a generic expression
evaluator yet.

**Expected impact.** Potentially very high for selective `WHERE`, small
`LIMIT`, or top-N queries; high implementation and correctness risk. Confidence:
high that current path cannot skip full preparation, low on the best redesign
until workload data exists.

**Validation.** Build a query-shape matrix: full scan, metric-only `LIMIT`,
key equality, selective metric predicate, `ORDER BY key`, and top-N metric sort.
Measure prepare time separately from row emission and server filesort time.

## Secondary opportunities

- Snapshot setup makes several cheap O(tick-count) metadata passes before the
  mandatory O(source-row-count) merge. `get_estimates()` sums container sizes
  and memory once (`src/report_by_request.cpp:308-347`), and `prepare()` sums
  sizes again for statistics (`include/pinba/report_util.h:271-276`). These do
  **not** iterate every row, so maintained counters are a low-priority cleanup,
  not a leading SELECT optimization.
- `fill_row_at_position()` repeatedly recomputes data pointers, totals, and
  duration-to-double conversions while iterating selected fields
  (`mysql_engine/handler.cpp:775-878`). A per-row local decode plan may reduce
  `Field::store()` preparation overhead, but profile first; it is less likely
  to matter than snapshot merge and histogram scans.
- Raw histogram output formats a new `std::string` and visits every nonzero HDR
  bucket each time the raw field is emitted
  (`mysql_engine/handler.cpp:960-1046`). Cache or stream only after measuring
  raw-histogram query frequency; `rnd_pos()` can re-emit a row during sorting.
- Active-report rows take that report's stats mutex while filling every row
  (`mysql_engine/handler.cpp:390-405`). This likely matters only with many
  concurrent active-table readers; benchmark before changing lock granularity.

## Benchmarks added and preliminary results

Two research-only benchmark artifacts were added; neither changes production
code:

- `experiments/exp_select_hotpath_bench.cpp` is a standalone C++14
  microbenchmark for multi-percentile scans and contended versus local key
  lookups (`experiments/exp_select_hotpath_bench.cpp:25-147`). Build with:

  ```sh
  c++ -O3 -std=c++14 -pthread experiments/exp_select_hotpath_bench.cpp \
    -o /tmp/select_hotpath_bench
  /tmp/select_hotpath_bench
  ```

- `scripts/benchmark_select.sh` repeats an arbitrary live MySQL SELECT after
  warmup, suppresses result formatting, and can print `EXPLAIN`
  (`scripts/benchmark_select.sh:1-68`). Example:

  ```sh
  scripts/benchmark_select.sh --iterations 20 --explain \
    'SELECT script_name, req_count FROM report_by_script_name'
  ```

Five local runs of the standalone benchmark produced these ranges:

- six independent percentile scans versus one batched scan over 1,000,000
  buckets: **3.46x-3.59x**, median **3.54x**;
- 1,000,000 lookups from four threads through one mutex-protected map versus an
  equally populated lock-free lookup map: **26.31x-32.57x**, median **29.57x**.

These results validate direction, not end-to-end gains. The percentile model
does not cover interpolation and infinity edge cases. The dictionary model uses
`std::mutex`/`std::unordered_map`, while production uses sharded rwlocks and a
dense snapshot cache. Neither model includes MySQL field conversion, snapshot
merge, allocator behavior, network time, or real key distributions. The live
harness could not run because no local `mysql` client/server is installed.

## Further benchmark plan

The repository has experiments, but its experimental C++ flags explicitly use
`-O0 -ggdb3` (`experiments/Makefile.am:8-10`), so those binaries are unsuitable
for production SELECT numbers. Add a disposable benchmark target or harness
that uses the production optimization flags and measures these phases
separately:

- snapshot `get_estimates()`;
- snapshot `prepare()` merge, with and without histograms;
- key materialization and dictionary calls;
- row-field stores for several projections;
- percentile calculation and raw histogram serialization;
- MySQL filesort/`rnd_pos()` behavior for ordered queries.

Use fixed synthetic snapshots plus one captured representative workload. Report
median and p95 over warm runs, row count, tick count, unique-key ratio,
histogram nonzero-bucket count, selected columns, and percentile count. Keep
correctness assertions beside each benchmark so an optimization cannot trade
away report values or snapshot consistency.

## Recommended sequence

1. Use the live harness to measure the phase breakdown and query-shape matrix.
2. Prototype key projection gating, lazy cache sizing, and the snapshot
   dictionary cache together;
   they are localized and low semantic risk.
3. Prototype one-pass multi-percentile calculation with exhaustive histogram
   edge-case tests.
4. Prototype totals projection gating and histogram reserve policies.
5. Measure row estimates independently.
6. Defer index/condition-pushdown/top-K work until workload data demonstrates
   that full snapshot preparation is the dominant cost for the target queries.

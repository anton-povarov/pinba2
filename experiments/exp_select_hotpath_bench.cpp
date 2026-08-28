// Standalone SELECT hot-path microbenchmarks.
// Build: c++ -O3 -std=c++14 -pthread exp_select_hotpath_bench.cpp -o select_hotpath_bench

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

namespace {

using clock_t = std::chrono::steady_clock;
using ns_t = std::chrono::nanoseconds;

uint64_t nanos(clock_t::time_point begin) {
	return std::chrono::duration_cast<ns_t>(clock_t::now() - begin).count();
}

// Independent percentile scans repeat the current flat_histogram_t loop.
// Batched scan walks sorted buckets once and resolves all thresholds together.
void benchmark_percentiles() {
	const size_t bucket_count = 1000000;
	const double percentiles[] = {50.0, 90.0, 95.0, 99.0, 99.9, 100.0};
	const size_t percentile_count = sizeof(percentiles) / sizeof(percentiles[0]);
	std::vector<uint32_t> values(bucket_count);
	uint64_t total = 0;
	for (size_t i = 0; i < bucket_count; ++i) {
		values[i] = 1u + static_cast<uint32_t>((i * 17u) % 7u == 0);
		total += values[i];
	}

	std::vector<uint32_t> independent(percentile_count);
	std::vector<uint32_t> batched(percentile_count);
	std::vector<uint64_t> targets(percentile_count);
	for (size_t p = 0; p < percentile_count; ++p)
		targets[p] = std::max<uint64_t>(1, static_cast<uint64_t>(std::ceil(total * percentiles[p] / 100.0)));
	volatile uint64_t sink = 0;
	const int rounds = 20;

	clock_t::time_point begin = clock_t::now();
	for (int round = 0; round < rounds; ++round) {
		for (size_t p = 0; p < percentile_count; ++p) {
			const uint64_t target = targets[p];
			uint64_t sum = 0;
			for (size_t bucket = 0; bucket < bucket_count; ++bucket) {
				sum += values[bucket];
				if (sum >= target) {
					independent[p] = static_cast<uint32_t>(bucket);
					break;
				}
			}
			sink += independent[p];
		}
	}
	const uint64_t independent_ns = nanos(begin);

	begin = clock_t::now();
	for (int round = 0; round < rounds; ++round) {
		size_t next = 0;
		uint64_t sum = 0;
		for (size_t bucket = 0; bucket < bucket_count && next < percentile_count; ++bucket) {
			sum += values[bucket];
			while (next < percentile_count && sum >= targets[next]) {
				batched[next++] = static_cast<uint32_t>(bucket);
			}
		}
		sink += batched[0] + batched[percentile_count - 1];
	}
	const uint64_t batched_ns = nanos(begin);

	if (independent != batched) {
		std::fprintf(stderr, "percentile benchmark mismatch\n");
		std::abort();
	}
	std::printf("percentile_scan rows=%zu rounds=%d independent_ns=%llu batched_ns=%llu speedup=%.2fx checksum=%llu\n",
		bucket_count, rounds,
		static_cast<unsigned long long>(independent_ns),
		static_cast<unsigned long long>(batched_ns),
		static_cast<double>(independent_ns) / static_cast<double>(batched_ns),
		static_cast<unsigned long long>(sink));
}

// Model handler key translation: a shared dictionary lookup takes a lock for
// every row, while a snapshot-local cache can be read without synchronization.
void benchmark_dictionary() {
	const size_t key_count = 100000;
	const size_t lookups_per_thread = 250000;
	const int thread_count = 4;
	std::unordered_map<uint32_t, std::string> dictionary;
	std::unordered_map<uint32_t, std::string> local_cache;
	local_cache.reserve(key_count);
	for (size_t i = 0; i < key_count; ++i) {
		dictionary.emplace(static_cast<uint32_t>(i), "key_" + std::to_string(i));
		local_cache.emplace(static_cast<uint32_t>(i), "key_" + std::to_string(i));
	}
	std::mutex dictionary_lock;
	const auto& local_cache_read = local_cache;
	auto run = [&](bool locked) {
		std::vector<std::thread> workers;
		std::vector<uint64_t> checksums(thread_count);
		for (int t = 0; t < thread_count; ++t) {
			workers.emplace_back([&, t]() {
				uint64_t local = 0;
				for (size_t i = 0; i < lookups_per_thread; ++i) {
					const uint32_t id = static_cast<uint32_t>((i * 17u + t * 31u) % key_count);
					if (locked) {
						std::lock_guard<std::mutex> guard(dictionary_lock);
						local += dictionary.find(id)->second.size();
					} else {
						local += local_cache_read.find(id)->second.size();
					}
				}
				checksums[t] = local;
			});
		}
		for (auto& worker : workers) worker.join();
		uint64_t checksum = 0;
		for (uint64_t value : checksums) checksum += value;
		return checksum;
	};
	clock_t::time_point begin = clock_t::now();
	const uint64_t locked_checksum = run(true);
	const uint64_t locked_ns = nanos(begin);
	begin = clock_t::now();
	const uint64_t cached_checksum = run(false);
	const uint64_t cached_ns = nanos(begin);
	std::printf("dictionary_lookup keys=%zu threads=%d lookups=%zu locked_ns=%llu local_cache_ns=%llu speedup=%.2fx checksum=%llu/%llu\n",
		key_count, thread_count, lookups_per_thread * thread_count,
		static_cast<unsigned long long>(locked_ns),
		static_cast<unsigned long long>(cached_ns),
		static_cast<double>(locked_ns) / static_cast<double>(cached_ns),
		static_cast<unsigned long long>(locked_checksum),
		static_cast<unsigned long long>(cached_checksum));
}

} // namespace

int main() {
	benchmark_percentiles();
	benchmark_dictionary();
	return 0;
}

#!/bin/sh

# Repeatable client-side SELECT benchmark. Measures complete SQL round trip.
set -eu

usage() {
	status=${1:-2}
	cat >&2 <<'EOF'
Usage: benchmark_select.sh [options] 'SELECT ...'
  --database NAME       database (default: pinba)
  --iterations N        timed executions (default: 10)
  --warmup N            untimed executions (default: 2)
  --mysql ARG           extra argument passed to mysql (repeatable)
  --explain             print EXPLAIN before timing
  --help                show help

Connection options can use MYSQL_* environment variables or mysql option files.
EOF
	exit "$status"
}

database=pinba
iterations=10
warmup=2
explain=0
mysql_args=""

while [ "$#" -gt 0 ]; do
	case "$1" in
		--database) [ "$#" -ge 2 ] || usage; database=$2; shift 2 ;;
		--iterations) [ "$#" -ge 2 ] || usage; iterations=$2; shift 2 ;;
		--warmup) [ "$#" -ge 2 ] || usage; warmup=$2; shift 2 ;;
		--mysql) [ "$#" -ge 2 ] || usage; mysql_args="$mysql_args $2"; shift 2 ;;
		--explain) explain=1; shift ;;
		--help) usage 0 ;;
		-*) echo "unknown option: $1" >&2; usage ;;
		*) break ;;
	esac
done

[ "$#" -eq 1 ] || usage
query=$1
case "$iterations" in ''|*[!0-9]*|0) echo "iterations must be positive integer" >&2; exit 2 ;; esac
case "$warmup" in ''|*[!0-9]*) echo "warmup must be non-negative integer" >&2; exit 2 ;; esac

# Keep result formatting out of timing; it can dominate small result sets.
mysql_cmd="mysql $mysql_args --batch --skip-column-names --raw --database=$database"
if [ "$explain" -eq 1 ]; then
	printf '%s\n' "EXPLAIN:"
	$mysql_cmd --execute="EXPLAIN $query"
fi

i=0
while [ "$i" -lt "$warmup" ]; do
	$mysql_cmd --execute="$query" >/dev/null
	i=$((i + 1))
done

printf 'query executions: %s (warmup: %s)\n' "$iterations" "$warmup"
printf '%s\n' 'timing: /usr/bin/time wall clock, mysql client round trip'
timing_file=$(mktemp "${TMPDIR:-/tmp}/pinba-select-time.XXXXXX")
trap 'rm -f "$timing_file"' EXIT HUP INT TERM
i=0
while [ "$i" -lt "$iterations" ]; do
	/usr/bin/time -p -o "$timing_file" sh -c "$mysql_cmd --execute=\"\$1\" >/dev/null" sh "$query"
	awk '/^real / { print $2 }' "$timing_file"
	i=$((i + 1))
done

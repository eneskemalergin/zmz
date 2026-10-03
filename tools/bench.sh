#!/usr/bin/env bash
set -euo pipefail

TOOLS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BIN_DIR="$TOOLS_DIR/bin"
READER_PEERS=(mzdata-peer pyteomics-peer pymzml-peer mzmlpy-peer pyopenms-peer)
CODEC_PEERS=(ms-numpress-cpp-peer numpress-rs-peer)
ALGORITHMS=(linear pic slof)
WORK_DIR=

cleanup_work_dir() {
  if [[ -n "$WORK_DIR" ]]; then
    rm -rf -- "$WORK_DIR"
    WORK_DIR=
  fi
}

trap cleanup_work_dir EXIT

usage() {
  cat <<'EOF'
Usage: tools/bench.sh <command> [arguments]

Commands:
  compare FILE.mzML [FILE.mzML ...]
      Compare available mzML readers on summary fields and fingerprints.
  benchmark FILE.mzML
      Measure reader fingerprint commands. Set RUNS=N for repetitions.
  numpress-compare
      Compare C++ and Rust MS-Numpress bytes and cross-decoder output.
  numpress-benchmark
      Measure standalone MS-Numpress round trips. Set RUNS=N for repetitions.
EOF
}

check_tools() {
  "$TOOLS_DIR/install.sh" --check >/dev/null
}

compare_readers() {
  if [[ "$#" -lt 1 ]]; then
    echo "usage: tools/bench.sh compare FILE.mzML [FILE.mzML ...]" >&2
    return 2
  fi

  check_tools
  local work_dir
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/zmz-peer-compare.XXXXXX")
  WORK_DIR=$work_dir

  local overall_status=0
  local incomparable=0
  local input_number=0
  local input input_dir peer peer_status
  for input in "$@"; do
    input_number=$((input_number + 1))
    if [[ ! -f "$input" ]]; then
      echo "missing input file: $input" >&2
      overall_status=1
      continue
    fi

    input_dir="$work_dir/input-$input_number"
    mkdir -p "$input_dir"
    local available_peers=()
    for peer in "${READER_PEERS[@]}"; do
      if "$BIN_DIR/$peer" summary "$input" >"$input_dir/$peer.json" 2>"$input_dir/$peer.stderr"; then
        available_peers+=("$peer")
      else
        peer_status=$?
        echo "$input: $peer unavailable for this input (exit $peer_status)" >&2
        sed 's/^/  /' "$input_dir/$peer.stderr" >&2
      fi
    done

    if [[ "${#available_peers[@]}" -lt 2 ]]; then
      echo "$input: fewer than two peers decoded the file; no comparison was made" >&2
      incomparable=1
      continue
    fi

    if ! python3 - "$input" "$input_dir" "${available_peers[@]}" <<'PY'; then
import json
import sys
from pathlib import Path

input_path = sys.argv[1]
result_dir = Path(sys.argv[2])
peers = sys.argv[3:]
fields = (
    "spectra",
    "chromatograms",
    "arrays",
    "values",
    "array_length_mismatches",
    "ms_levels",
    "fingerprint",
)
results = {
    peer: json.loads((result_dir / f"{peer}.json").read_text())
    for peer in peers
}
baseline = results[peers[0]]
failed = False
for peer in peers:
    result = results[peer]
    differences = {
        field: (baseline[field], result[field])
        for field in fields
        if baseline[field] != result[field]
    }
    if differences:
        failed = True
        print(f"{input_path}: mismatch in {peer}")
        for field, (expected, actual) in differences.items():
            print(f"  {field}: {expected!r} != {actual!r}")
if not failed:
    print(f"{input_path}: {len(peers)} available peers agree on {', '.join(fields)}")
sys.exit(1 if failed else 0)
PY
      overall_status=1
    fi
  done

  if [[ "$overall_status" -ne 0 ]]; then
    return "$overall_status"
  fi
  if [[ "$incomparable" -ne 0 ]]; then
    return 2
  fi
}

benchmark_readers() {
  if [[ "$#" -ne 1 ]]; then
    echo "usage: tools/bench.sh benchmark FILE.mzML" >&2
    return 2
  fi
  local input=$1
  local run_count=${RUNS:-3}
  if [[ ! -f "$input" ]]; then
    echo "missing input file: $input" >&2
    return 1
  fi
  if ! [[ "$run_count" =~ ^[1-9][0-9]*$ ]]; then
    echo "RUNS must be a positive integer" >&2
    return 2
  fi
  if [[ ! -x /usr/bin/time ]]; then
    echo "missing required command: /usr/bin/time" >&2
    return 1
  fi

  check_tools
  local input_bytes
  input_bytes=$(stat -c '%s' "$input")
  local work_dir
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/zmz-peer-benchmark.XXXXXX")
  WORK_DIR=$work_dir

  printf 'tool\trun\twall_seconds\tmax_rss_kib\texit_status\tinput_bytes\tcommand\n'
  local peer run timing_file output_file stderr_file status
  local wall_seconds max_rss_kib timed_status
  for peer in "${READER_PEERS[@]}"; do
    for run in $(seq 1 "$run_count"); do
      timing_file="$work_dir/$peer.$run.time"
      output_file="$work_dir/$peer.$run.json"
      stderr_file="$work_dir/$peer.$run.stderr"
      status=0
      /usr/bin/time -f '%e\t%M\t%x' -o "$timing_file" \
        "$BIN_DIR/$peer" fingerprint "$input" >"$output_file" 2>"$stderr_file" || status=$?
      if [[ -s "$timing_file" ]]; then
        IFS=$'\t' read -r wall_seconds max_rss_kib timed_status <"$timing_file"
      else
        wall_seconds=NA
        max_rss_kib=NA
        timed_status=$status
      fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\tfingerprint\n' \
        "$peer" "$run" "$wall_seconds" "$max_rss_kib" "$timed_status" "$input_bytes"
    done
  done
}

vector_values() {
  local algorithm=$1
  case "$algorithm" in
    linear) printf '%s\n' 100.0 100.1 100.2 100.3 100.4 100.5 100.6 100.7 ;;
    pic) printf '%s\n' 0 1 2 3 4 5 6 7 8 9 10 ;;
    slof) printf '%s\n' 0.01 0.1 1.0 10.0 100.0 1000.0 10000.0 100000.0 1000000.0 ;;
    *)
      echo "unknown Numpress algorithm: $algorithm" >&2
      return 1
      ;;
  esac
}

compare_numpress() {
  check_tools
  local work_dir
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/zmz-numpress-compare.XXXXXX")
  WORK_DIR=$work_dir

  local algorithm input cpp_hex rust_hex
  for algorithm in "${ALGORITHMS[@]}"; do
    input="$work_dir/$algorithm.values"
    vector_values "$algorithm" >"$input"
    "$BIN_DIR/ms-numpress-cpp-peer" encode "$algorithm" <"$input" >"$work_dir/$algorithm.ms-numpress-cpp-peer.json"
    "$BIN_DIR/numpress-rs-peer" encode "$algorithm" <"$input" >"$work_dir/$algorithm.numpress-rs-peer.json"

    cpp_hex=$(
      python3 - "$work_dir/$algorithm.ms-numpress-cpp-peer.json" <<'PY'
import json
import sys

print(json.loads(open(sys.argv[1]).read())["encoded_hex"])
PY
    )
    rust_hex=$(
      python3 - "$work_dir/$algorithm.numpress-rs-peer.json" <<'PY'
import json
import sys

print(json.loads(open(sys.argv[1]).read())["encoded_hex"])
PY
    )
    printf '%s\n' "$rust_hex" | "$BIN_DIR/ms-numpress-cpp-peer" decode "$algorithm" >"$work_dir/$algorithm.cpp-on-rust.json"
    printf '%s\n' "$cpp_hex" | "$BIN_DIR/numpress-rs-peer" decode "$algorithm" >"$work_dir/$algorithm.rust-on-cpp.json"
  done

  python3 - "$work_dir" "${ALGORITHMS[@]}" "${CODEC_PEERS[@]}" <<'PY'
import json
import sys
from pathlib import Path

work_dir = Path(sys.argv[1])
algorithms = sys.argv[2:5]
peers = sys.argv[5:]
exact_fields = (
    "input_count",
    "output_count",
    "encoded_bytes",
    "encoded_hex",
    "decoded_fingerprint",
)
failed = False
for algorithm in algorithms:
    results = {
        peer: json.loads((work_dir / f"{algorithm}.{peer}.json").read_text())
        for peer in peers
    }
    baseline = results[peers[0]]
    differences = {
        field: [baseline[field], results[peers[1]][field]]
        for field in exact_fields
        if baseline[field] != results[peers[1]][field]
    }
    error_difference = abs(
        float(baseline["max_abs_error"])
        - float(results[peers[1]]["max_abs_error"])
    )
    if error_difference > 1e-12:
        differences["max_abs_error"] = [
            baseline["max_abs_error"],
            results[peers[1]]["max_abs_error"],
        ]
    cross_checks = {
        "C++ decoder on Rust bytes": json.loads(
            (work_dir / f"{algorithm}.cpp-on-rust.json").read_text()
        ),
        "Rust decoder on C++ bytes": json.loads(
            (work_dir / f"{algorithm}.rust-on-cpp.json").read_text()
        ),
    }
    expected_fingerprints = {
        "C++ decoder on Rust bytes": results["numpress-rs-peer"]["decoded_fingerprint"],
        "Rust decoder on C++ bytes": results["ms-numpress-cpp-peer"]["decoded_fingerprint"],
    }
    for label, cross_result in cross_checks.items():
        for field in ("output_count", "decoded_fingerprint"):
            expected = (
                expected_fingerprints[label]
                if field == "decoded_fingerprint"
                else baseline["output_count"]
            )
            if cross_result[field] != expected:
                differences[f"{label} {field}"] = [expected, cross_result[field]]
    if differences:
        failed = True
        print(f"{algorithm}: mismatch")
        for field, values in differences.items():
            print(f"  {field}: {values[0]!r} != {values[1]!r}")
    else:
        print(
            f"{algorithm}: agree, {baseline['input_count']} values, "
            f"{baseline['encoded_bytes']} encoded bytes, "
            f"max_abs_error={baseline['max_abs_error']}, cross-decoders agree"
        )
sys.exit(1 if failed else 0)
PY
}

benchmark_numpress() {
  local run_count=${RUNS:-3}
  if ! [[ "$run_count" =~ ^[1-9][0-9]*$ ]]; then
    echo "RUNS must be a positive integer" >&2
    return 2
  fi
  if [[ ! -x /usr/bin/time ]]; then
    echo "missing required command: /usr/bin/time" >&2
    return 1
  fi

  check_tools
  local work_dir
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/zmz-numpress-benchmark.XXXXXX")
  WORK_DIR=$work_dir

  printf 'tool\talgorithm\trun\twall_seconds\tmax_rss_kib\texit_status\tinput_bytes\tcommand\n'
  local algorithm input input_bytes peer run timing_file stderr_file status
  local wall_seconds max_rss_kib timed_status
  for algorithm in "${ALGORITHMS[@]}"; do
    input="$work_dir/$algorithm.values"
    vector_values "$algorithm" >"$input"
    input_bytes=$(stat -c '%s' "$input")
    for peer in "${CODEC_PEERS[@]}"; do
      for run in $(seq 1 "$run_count"); do
        timing_file="$work_dir/$algorithm.$peer.$run.time"
        stderr_file="$work_dir/$algorithm.$peer.$run.stderr"
        status=0
        /usr/bin/time -f '%e\t%M\t%x' -o "$timing_file" \
          "$BIN_DIR/$peer" "$algorithm" <"$input" >/dev/null 2>"$stderr_file" || status=$?
        if [[ -s "$timing_file" ]]; then
          IFS=$'\t' read -r wall_seconds max_rss_kib timed_status <"$timing_file"
        else
          wall_seconds=NA
          max_rss_kib=NA
          timed_status=$status
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\troundtrip\n' \
          "$peer" "$algorithm" "$run" "$wall_seconds" "$max_rss_kib" \
          "$timed_status" "$input_bytes"
      done
    done
  done
}

case "${1:-}" in
  compare)
    shift
    compare_readers "$@"
    ;;
  benchmark)
    shift
    benchmark_readers "$@"
    ;;
  numpress-compare)
    shift
    [[ "$#" -eq 0 ]] || {
      echo "numpress-compare takes no arguments" >&2
      exit 2
    }
    compare_numpress
    ;;
  numpress-benchmark)
    shift
    [[ "$#" -eq 0 ]] || {
      echo "numpress-benchmark takes no arguments" >&2
      exit 2
    }
    benchmark_numpress
    ;;
  --help | -h)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

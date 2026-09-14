#!/usr/bin/env bash
set -euo pipefail

TOOLS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BIN_DIR="$TOOLS_DIR/bin"
BUILD_DIR="$TOOLS_DIR/build"
VENV_DIR="$TOOLS_DIR/venv"
WRAPPER_DIR="$TOOLS_DIR/wrappers"
NUMPRESS_CPP_WRAPPER="$TOOLS_DIR/wrappers/ms_numpress.cpp"
NUMPRESS_CPP_SOURCE_DIR="$TOOLS_DIR/src/ms-numpress"
CARGO_HOME_LOCAL="$BUILD_DIR/cargo-home"
CARGO_TARGET_DIR_LOCAL="$BUILD_DIR/cargo-target"
PIP_CACHE_DIR_LOCAL="$BUILD_DIR/pip-cache"
PYTHON=${PYTHON:-python3}
TOOL_JOBS=${TOOL_JOBS:-4}

# shellcheck source=tools/versions.sh
source "$TOOLS_DIR/versions.sh"

usage() {
  cat <<'EOF'
Usage: tools/install.sh [--check|--list|--help]

Install all enabled mzML and MS-Numpress peers into tools/.

Options:
  --check  verify the local binary, launchers, and package versions
  --list   print the tracked manifest and current local status
  --help   print this help
EOF
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

check_platform() {
  case "$(uname -s):$(uname -m)" in
    Linux:x86_64 | Linux:amd64) ;;
    *)
      echo "unsupported host: $(uname -s) $(uname -m); the initial installer target is Linux x86_64" >&2
      exit 1
      ;;
  esac
}

check_python_version() {
  "$PYTHON" -c 'import sys; minimum = (3, 12); actual = sys.version_info[:2]; raise SystemExit(f"Python {minimum[0]}.{minimum[1]} or newer is required, found {actual[0]}.{actual[1]}" if actual < minimum else None)'
}

check_tool_jobs() {
  if ! [[ "$TOOL_JOBS" =~ ^[1-9][0-9]*$ ]]; then
    echo "TOOL_JOBS must be a positive integer" >&2
    exit 2
  fi
}

check_directory_path() {
  local path=$1
  if [[ -L "$path" ]]; then
    echo "refusing installer path symlink: $path" >&2
    exit 1
  fi
  if [[ -e "$path" && ! -d "$path" ]]; then
    echo "refusing installer path that is not a directory: $path" >&2
    exit 1
  fi
}

check_output_path() {
  local path=$1
  if [[ -L "$path" ]]; then
    echo "refusing to overwrite output symlink: $path" >&2
    exit 1
  fi
  if [[ -e "$path" && ! -f "$path" ]]; then
    echo "refusing to overwrite output that is not a file: $path" >&2
    exit 1
  fi
}

check_launcher_destinations() {
  for command in pyteomics-peer pymzml-peer mzmlpy-peer pyopenms-peer; do
    if [[ -e "$BIN_DIR/$command" && ! -L "$BIN_DIR/$command" ]]; then
      echo "refusing to replace non-symlink launcher: $BIN_DIR/$command" >&2
      exit 1
    fi
  done
}

check_install_paths() {
  for path in \
    "$BIN_DIR" \
    "$BUILD_DIR" \
    "$VENV_DIR" \
    "$TOOLS_DIR/src" \
    "$WRAPPER_DIR" \
    "$CARGO_HOME_LOCAL" \
    "$CARGO_TARGET_DIR_LOCAL" \
    "$PIP_CACHE_DIR_LOCAL" \
    "$NUMPRESS_CPP_SOURCE_DIR"; do
    check_directory_path "$path"
  done
}

check_no_root_venv() {
  if [[ -e "$VENV_DIR/pyvenv.cfg" ]]; then
    echo "unexpected root virtual environment at $VENV_DIR; remove it before installing peer environments" >&2
    exit 1
  fi
  for path in bin include lib lib64 share; do
    if [[ -e "$VENV_DIR/$path" ]]; then
      echo "unexpected root virtual environment path at $VENV_DIR/$path; remove it before installing peer environments" >&2
      exit 1
    fi
  done
}

acquire_install_lock() {
  require_command flock
  exec 9>"$BUILD_DIR/install.lock"
  if ! flock -n 9; then
    echo "another peer installation is already running" >&2
    exit 1
  fi
}

print_list() {
  "$PYTHON" - "$TOOLS_DIR/manifest.json" "$BIN_DIR" "$VENV_DIR" <<'PY'
import json
import sys
from pathlib import Path

manifest_path = Path(sys.argv[1])
bin_dir = Path(sys.argv[2])
venv_dir = Path(sys.argv[3])
manifest = json.loads(manifest_path.read_text())
for tool in manifest["tools"]:
    state = "installed" if (bin_dir / tool.get("local_command", "")).exists() else "missing"
    print(f'{tool["id"]}\t{tool["version"]}\t{tool["status"]}\t{state}')
for tool in manifest.get("codec_peers", []):
    state = "installed" if (bin_dir / tool.get("local_command", "")).exists() else "missing"
    print(f'{tool["id"]}\t{tool["version"]}\t{tool["status"]}\t{state}')
print(f'python-venv-root\t{venv_dir}\tgenerated\t{"present" if venv_dir.is_dir() else "missing"}')
PY
}

check_versions() {
  for peer in pyteomics pymzml mzmlpy pyopenms; do
    check_requirement_versions "$peer" "$TOOLS_DIR/requirements/$peer.txt"
  done
}

check_requirement_versions() {
  local environment=$1
  local requirements=$2
  "$VENV_DIR/$environment/bin/python" - "$requirements" <<'PY'
import importlib.metadata
from pathlib import Path
import sys

for raw_line in Path(sys.argv[1]).read_text().splitlines():
    line = raw_line.strip()
    if not line or line.startswith("#"):
        continue
    package, wanted = line.split("==", 1)
    actual = importlib.metadata.version(package)
    if actual != wanted:
        raise SystemExit(f"{package}: expected {wanted}, found {actual}")
    print(f"{package} {actual}")
PY
}

check_python_environment() {
  local environment=$1
  [[ -x "$environment/bin/python" ]] || return 1
  "$environment/bin/python" -I -c '
import pathlib
import sys

expected = pathlib.Path(sys.argv[1]).resolve()
actual = pathlib.Path(sys.prefix).resolve()
raise SystemExit(0 if actual == expected and sys.prefix != sys.base_prefix else 1)
' "$environment"
}

check_local() {
  local status=0
  check_platform
  check_install_paths
  check_no_root_venv
  for command in mzdata-peer ms-numpress-cpp-peer numpress-rs-peer; do
    if [[ ! -f "$BIN_DIR/$command" || -L "$BIN_DIR/$command" || ! -x "$BIN_DIR/$command" ]]; then
      echo "missing local command: $BIN_DIR/$command" >&2
      status=1
    fi
  done
  for command in pyteomics-peer pymzml-peer mzmlpy-peer pyopenms-peer; do
    if [[ ! -f "$BIN_DIR/$command" || ! -x "$BIN_DIR/$command" || ! -L "$BIN_DIR/$command" || "$(readlink "$BIN_DIR/$command")" != "../peer.sh" ]]; then
      echo "invalid local launcher: $BIN_DIR/$command" >&2
      status=1
    fi
  done
  for environment in pyteomics pymzml mzmlpy pyopenms; do
    if ! check_python_environment "$VENV_DIR/$environment"; then
      echo "missing local Python environment: $VENV_DIR/$environment" >&2
      status=1
    fi
  done
  if [[ "$status" -ne 0 ]]; then
    return "$status"
  fi

  "$BIN_DIR/mzdata-peer" --version
  "$BIN_DIR/pyteomics-peer" --version
  "$BIN_DIR/pymzml-peer" --version
  "$BIN_DIR/mzmlpy-peer" --version
  "$BIN_DIR/pyopenms-peer" --version
  "$BIN_DIR/ms-numpress-cpp-peer" --version
  "$BIN_DIR/numpress-rs-peer" --version
  check_versions
}

install_python_peer() {
  local peer=$1
  local environment="$VENV_DIR/$peer"
  local requirements="$TOOLS_DIR/requirements/$peer.txt"
  check_directory_path "$environment"
  if [[ ! -x "$environment/bin/python" ]]; then
    mkdir -p "$environment"
    "$PYTHON" -m venv "$environment"
  elif ! check_python_environment "$environment"; then
    echo "invalid local Python environment: $environment" >&2
    exit 1
  fi
  if check_requirement_versions "$peer" "$requirements" >/dev/null 2>&1; then
    echo "Using existing $peer environment at $environment"
    return
  fi
  echo "Installing $peer into $environment"
  PIP_CACHE_DIR="$PIP_CACHE_DIR_LOCAL" \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_INPUT=1 \
    "$environment/bin/python" -m pip install --cache-dir "$PIP_CACHE_DIR_LOCAL" --requirement "$requirements"
}

git_public() {
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null git "$@"
}

build_ms_numpress_cpp() {
  if ! git_public -C "$NUMPRESS_CPP_SOURCE_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    git_public clone "$MS_NUMPRESS_REPOSITORY" "$NUMPRESS_CPP_SOURCE_DIR"
  fi
  if [[ -n "$(git_public -C "$NUMPRESS_CPP_SOURCE_DIR" status --porcelain)" ]]; then
    echo "refusing to replace modified MS-Numpress source checkout: $NUMPRESS_CPP_SOURCE_DIR" >&2
    exit 1
  fi
  if ! git_public -C "$NUMPRESS_CPP_SOURCE_DIR" rev-parse --verify "${MS_NUMPRESS_COMMIT}^{commit}" >/dev/null 2>&1; then
    git_public -C "$NUMPRESS_CPP_SOURCE_DIR" fetch --depth 1 "$MS_NUMPRESS_REPOSITORY" "$MS_NUMPRESS_COMMIT"
  fi
  git_public -C "$NUMPRESS_CPP_SOURCE_DIR" checkout --detach "$MS_NUMPRESS_COMMIT"
  check_output_path "$BUILD_DIR/ms-numpress-cpp-peer"
  g++ -std=c++17 -O3 -DNDEBUG \
    -I"$NUMPRESS_CPP_SOURCE_DIR/src/main/cpp" \
    "$NUMPRESS_CPP_SOURCE_DIR/src/main/cpp/MSNumpress.cpp" \
    "$NUMPRESS_CPP_WRAPPER" \
    -Wall -Wextra -Wpedantic \
    -o "$BUILD_DIR/ms-numpress-cpp-peer"
}

build_rust_peers() {
  CARGO_HOME="$CARGO_HOME_LOCAL" \
    CARGO_TARGET_DIR="$CARGO_TARGET_DIR_LOCAL" \
    cargo build --locked --release --manifest-path "$WRAPPER_DIR/Cargo.toml" --bins --jobs "$TOOL_JOBS"
}

install_native_peers() {
  check_output_path "$BIN_DIR/mzdata-peer"
  check_output_path "$BIN_DIR/numpress-rs-peer"
  check_output_path "$BIN_DIR/ms-numpress-cpp-peer"
  install -m 0755 "$CARGO_TARGET_DIR_LOCAL/release/mzdata-peer" "$BIN_DIR/mzdata-peer"
  install -m 0755 "$CARGO_TARGET_DIR_LOCAL/release/numpress-rs-peer" "$BIN_DIR/numpress-rs-peer"
  install -m 0755 "$BUILD_DIR/ms-numpress-cpp-peer" "$BIN_DIR/ms-numpress-cpp-peer"
}

install_all() {
  check_platform
  check_tool_jobs
  check_install_paths
  check_no_root_venv
  check_launcher_destinations
  require_command cargo
  require_command rustc
  require_command git
  require_command g++
  require_command "$PYTHON"
  require_command install
  require_command flock
  check_python_version

  mkdir -p "$BIN_DIR" "$BUILD_DIR" "$CARGO_HOME_LOCAL" "$CARGO_TARGET_DIR_LOCAL" "$PIP_CACHE_DIR_LOCAL" "$TOOLS_DIR/src"
  acquire_install_lock
  for peer in pyteomics pymzml mzmlpy pyopenms; do
    install_python_peer "$peer"
  done

  echo "Building Rust peers into $BIN_DIR"
  build_rust_peers

  echo "Building the MS-Numpress C++ peer into $BIN_DIR"
  build_ms_numpress_cpp
  install_native_peers

  for command in pyteomics-peer pymzml-peer mzmlpy-peer pyopenms-peer; do
    ln -sfn ../peer.sh "$BIN_DIR/$command"
  done

  check_local
  echo "Local mzML peers are ready under $TOOLS_DIR"
}

main() {
  case "${1:-}" in
    "")
      install_all
      ;;
    --check)
      check_local
      ;;
    --list)
      print_list
      ;;
    --help | -h)
      usage
      ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"

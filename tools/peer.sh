#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH=$(readlink -f "${BASH_SOURCE[0]}")
TOOLS_DIR=$(cd "$(dirname "$SCRIPT_PATH")" && pwd)
COMMAND_NAME=$(basename "$0")

case "$COMMAND_NAME" in
  pyteomics-peer)
    BACKEND=pyteomics
    VENV_NAME=pyteomics
    ;;
  pymzml-peer)
    BACKEND=pymzml
    VENV_NAME=pymzml
    ;;
  mzmlpy-peer)
    BACKEND=mzmlpy
    VENV_NAME=mzmlpy
    ;;
  pyopenms-peer)
    BACKEND=pyopenms
    VENV_NAME=pyopenms
    ;;
  *)
    echo "unknown peer launcher name: $COMMAND_NAME" >&2
    exit 2
    ;;
esac

export PYTHONDONTWRITEBYTECODE=1
exec "$TOOLS_DIR/venv/$VENV_NAME/bin/python" "$TOOLS_DIR/mzml_peer.py" --backend "$BACKEND" "$@"

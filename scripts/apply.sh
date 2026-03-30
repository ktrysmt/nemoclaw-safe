#!/usr/bin/env bash
# Apply policies to the running NemoClaw sandbox.
#
# Usage:
#   ./scripts/apply.sh [sandbox-name]
#
# Methods:
#   1. Dynamic: openshell policy set (no restart)
#   2. Static:  copy to ~/.nemoclaw/source and run nemoclaw onboard

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SANDBOX_NAME="${1:-my-agent}"
POLICY_FILE="${PROJECT_ROOT}/policies/openclaw-sandbox.yaml"

if [[ ! -f "$POLICY_FILE" ]]; then
  echo "ERROR: $POLICY_FILE not found" >&2
  exit 1
fi

echo "[nemoclaw] Applying policy to sandbox: ${SANDBOX_NAME}"

if command -v openshell &>/dev/null; then
  echo "[nemoclaw] Using dynamic apply: openshell policy set"
  openshell policy set --policy "$POLICY_FILE" --wait "$SANDBOX_NAME"
  echo "[nemoclaw] Done."
else
  echo "[nemoclaw] openshell not found. Falling back to static copy + onboard."
  DEST="${HOME}/.nemoclaw/source/nemoclaw-blueprint/policies/openclaw-sandbox.yaml"
  cp "$POLICY_FILE" "$DEST"
  echo "[nemoclaw] Copied to $DEST"
  echo "[nemoclaw] Run 'nemoclaw onboard' to apply."
fi

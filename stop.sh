#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2153
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$SCRIPT_DIR/../conf/localvllm.conf" ]; then
  # shellcheck source=/dev/null
  . "$SCRIPT_DIR/../conf/localvllm.conf"
elif [ -f "$SCRIPT_DIR/localvllm.conf" ]; then
  # shellcheck source=localvllm.conf
  . "$SCRIPT_DIR/localvllm.conf"
else
  echo "Error: localvllm.conf not found." >&2
  exit 1
fi

source_localvllm_common() {
  local candidate

  for candidate in "$SCRIPT_DIR/lib/common.sh" "$SCRIPT_DIR/../lib/common.sh"; do
    if [ -f "$candidate" ]; then
      # shellcheck source=/dev/null
      . "$candidate"
      return 0
    fi
  done

  echo "Error: missing Local vLLM library: common.sh" >&2
  exit 1
}
source_localvllm_common

AI_DIR="$(resolve_ai_dir)"
CONF_ROOT="$AI_DIR/$LOCALVLLM_CONF_SUBDIR"
localvllm_capture_global_runtime
localvllm_acquire_global_lock

BACKEND_ARG="${1:-}"
if [ "$#" -gt 0 ]; then
  shift
fi
if [ "$#" -gt 0 ]; then
  echo "Usage: $0 [vllm|omni]" >&2
  exit 2
fi
localvllm_use_backend "${BACKEND_ARG:-$LOCALVLLM_DEFAULT_BACKEND}" || exit 1

if [ ! -f "$PID_FILE" ]; then
  echo "Local $LOCALVLLM_BACKEND_LABEL is not running (no PID file)."
  exit 0
fi

PID="$(<"$PID_FILE")"
if ! [[ "$PID" =~ ^[0-9]+$ ]]; then
  rm -f "$PID_FILE" "$PID_START_FILE" "$CONF_DIR/process-group"
  echo "Removed invalid PID file."
  exit 0
fi

if ! pid_file_matches_process "$PID_FILE" "$PID_START_FILE"; then
  rm -f "$PID_FILE" "$PID_START_FILE" "$CONF_DIR/process-group"
  echo "Removed stale PID file; Local $LOCALVLLM_BACKEND_LABEL is not running."
  exit 0
fi

COMMAND="$(ps -p "$PID" -o comm= 2>/dev/null || true)"
if ! process_is_vllm "$PID"; then
  echo "Note: PID $PID is running as ${COMMAND:-unknown}; the recorded start time matches, so it is treated as this backend."
fi

GROUP="0"
[ -f "$CONF_DIR/process-group" ] && GROUP="$(<"$CONF_DIR/process-group")"

echo "Stopping Local $LOCALVLLM_BACKEND_LABEL (PID $PID)..."
if [ "$GROUP" = "1" ]; then
  kill -- -"$PID" 2>/dev/null || kill "$PID" 2>/dev/null || true
else
  kill "$PID" 2>/dev/null || true
fi

DEADLINE=$((SECONDS + ${LOCALVLLM_STOP_TIMEOUT:-30}))
while [ "$SECONDS" -lt "$DEADLINE" ]; do
  kill -0 "$PID" 2>/dev/null || break
  sleep 0.25
done

if kill -0 "$PID" 2>/dev/null; then
  echo "Warning: vLLM did not stop cleanly; sending SIGKILL." >&2
  if [ "$GROUP" = "1" ]; then
    kill -KILL -- -"$PID" 2>/dev/null || kill -KILL "$PID" 2>/dev/null || true
  else
    kill -KILL "$PID" 2>/dev/null || true
  fi
  sleep 0.5
fi

if kill -0 "$PID" 2>/dev/null; then
  echo "Error: vLLM (PID $PID) is still running." >&2
  exit 1
fi

rm -f "$PID_FILE" "$PID_START_FILE" "$CONF_DIR/process-group"
echo "Local $LOCALVLLM_BACKEND_LABEL stopped."

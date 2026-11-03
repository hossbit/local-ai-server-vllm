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
source_localvllm_lib install.sh

AI_DIR="$(resolve_ai_dir)"
CONF_ROOT="$AI_DIR/$LOCALVLLM_CONF_SUBDIR"
BIN_DIR="$AI_DIR/$LOCALVLLM_BIN_SUBDIR"
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

fail_start() {
  local message="$1"
  local group="0"

  [ -f "$CONF_DIR/process-group" ] && group="$(<"$CONF_DIR/process-group")"
  if pid_file_matches_process "$PID_FILE" "$PID_START_FILE"; then
    if [ "$group" = "1" ]; then
      kill -- -"$PID" 2>/dev/null || kill "$PID" 2>/dev/null || true
    else
      kill "$PID" 2>/dev/null || true
    fi
  fi
  rm -f "$PID_FILE" "$PID_START_FILE" "$CONF_DIR/process-group"
  echo "Error: $message. See $LOG_FILE" >&2
  if [ -f "$LOG_FILE" ]; then
    tail -n 20 "$LOG_FILE" >&2 || true
  fi
  exit 1
}

mkdir -p "$CONF_DIR" "$MODELS_DIR" "$OVERRIDES_DIR" "$(dirname "$LOG_FILE")"

if [ ! -x "$VLLM_BIN" ]; then
  echo "Error: vLLM is not installed for backend '$LOCALVLLM_BACKEND'." >&2
  echo "Install it with: $BIN_DIR/install-localvllm.sh --backend $LOCALVLLM_BACKEND" >&2
  exit 1
fi

if [ "$LOCALVLLM_BACKEND" = "omni" ] && ! vllm_omni_is_available "$VENV_DIR"; then
  echo "Error: vLLM-Omni is not installed in $VENV_DIR." >&2
  echo "Install it with: $BIN_DIR/install-localvllm.sh --backend omni" >&2
  exit 1
fi

if [ ! -f "$PORT_FILE" ]; then
  echo "$LOCALVLLM_DEFAULT_PORT" > "$PORT_FILE"
fi

PORT="$(<"$PORT_FILE")"
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || ((10#$PORT < 1 || 10#$PORT > 65535)); then
  echo "Error: invalid port in $PORT_FILE: $PORT" >&2
  exit 1
fi

if [ -f "$PID_FILE" ]; then
  PID="$(<"$PID_FILE")"
  if pid_file_matches_process "$PID_FILE" "$PID_START_FILE"; then
    echo "Local $LOCALVLLM_BACKEND_LABEL is already running (PID $PID) on port $PORT."
    exit 0
  fi
  rm -f "$PID_FILE" "$PID_START_FILE" "$CONF_DIR/process-group"
fi

localvllm_require_start_model || exit 1

if port_is_listening "$PORT"; then
  echo "Error: port $PORT is already in use by another process." >&2
  echo "Change LOCALVLLM_${LOCALVLLM_BACKEND^^}_PORT or stop the other process." >&2
  exit 1
fi

REBUILD="$BIN_DIR/rebuild-config.sh"
[ -x "$REBUILD" ] || REBUILD="$SCRIPT_DIR/rebuild-config.sh"
[ -x "$REBUILD" ] || {
  echo "Error: missing helper: $BIN_DIR/rebuild-config.sh" >&2
  exit 1
}
"$REBUILD" --backend "$LOCALVLLM_BACKEND"

if [ ! -x "$SERVE_SH" ]; then
  echo "Error: launcher was not generated: $SERVE_SH" >&2
  exit 1
fi


# Public listeners: require an active key and explicit acknowledgement. vLLM's
# key does not protect /health, /docs, or sleep/dev endpoints.
case "$LOCALVLLM_LISTEN_HOST" in
  127.0.0.1|localhost|::1) ;;
  *)
    api_key_active="$(config_assignment_value LOCALVLLM_API_KEY_ACTIVE "$SERVE_ENV" 2>/dev/null || true)"
    sleep_enabled="$(config_assignment_value LOCALVLLM_ENABLE_SLEEP "$SERVE_ENV" 2>/dev/null || true)"
    if [ "$api_key_active" != "1" ]; then
      echo "Error: refusing to listen on $LOCALVLLM_LISTEN_HOST without an active API key." >&2
      echo "Create one with: localvllm --backend $LOCALVLLM_BACKEND key create" >&2
      echo "Or bind to 127.0.0.1 and use a TLS reverse proxy for remote access." >&2
      exit 1
    fi
    if [ "$sleep_enabled" = "1" ]; then
      echo "Error: sleep mode exposes unprotected /sleep and /wake_up endpoints; use a loopback listener." >&2
      exit 1
    fi
    if [ "${LOCALVLLM_ALLOW_INSECURE_PUBLIC:-0}" != "1" ]; then
      echo "Error: non-loopback listener requires LOCALVLLM_ALLOW_INSECURE_PUBLIC=1." >&2
      echo "vLLM's API key does not protect /health or /docs; terminate TLS and authenticate at a reverse proxy." >&2
      exit 1
    fi
    echo "Warning: listening on $LOCALVLLM_LISTEN_HOST. vLLM's key does not protect /health or /docs; a TLS reverse proxy is still required." >&2
    ;;
esac

# Rotate instead of truncating so the previous startup failure stays readable.
if [ -s "$LOG_FILE" ]; then
  rotated="$LOG_FILE.$(date -u +%Y%m%dT%H%M%SZ)"
  mv -f "$LOG_FILE" "$rotated" || true
  find "$(dirname "$LOG_FILE")" -maxdepth 1 -type f -name "$(basename "$LOG_FILE").*" -print 2>/dev/null |
    sort -r |
    tail -n +$((${LOCALVLLM_LOG_KEEP:-5} + 1)) |
    while IFS= read -r old_log; do rm -f "$old_log"; done
fi

PROCESS_GROUP=0
if command -v setsid >/dev/null 2>&1; then
  # Do not let the long-running vLLM process inherit the manager lock FD.
  setsid nohup "$SERVE_SH" 9>&- > "$LOG_FILE" 2>&1 &
  PROCESS_GROUP=1
else
  nohup "$SERVE_SH" 9>&- > "$LOG_FILE" 2>&1 &
fi

PID=$!
echo "$PID" > "$PID_FILE"
process_start_time "$PID" > "$PID_START_FILE"
echo "$PROCESS_GROUP" > "$CONF_DIR/process-group"

api_auth_curl_args

READY=0
DEADLINE=$((SECONDS + ${LOCALVLLM_HEALTH_CHECK_TIMEOUT:-900}))
while [ "$SECONDS" -lt "$DEADLINE" ]; do
  if ! pid_file_matches_process "$PID_FILE" "$PID_START_FILE"; then
    fail_start "vLLM exited during startup"
  fi
  if command -v curl >/dev/null 2>&1 &&
    curl "${AUTH_CURL_ARGS[@]}" --max-time 2 -fsS "http://${LOCALVLLM_LISTEN_HOST}:${PORT}/health" >/dev/null 2>&1; then
    READY=1
    break
  fi
  if command -v curl >/dev/null 2>&1 &&
    curl "${AUTH_CURL_ARGS[@]}" --max-time 2 -fsS "http://${LOCALVLLM_LISTEN_HOST}:${PORT}/v1/models" >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 1
done

if [ "$READY" -ne 1 ]; then
  fail_start "vLLM started but the API did not become ready at http://${LOCALVLLM_LISTEN_HOST}:${PORT}/health"
fi

ACTIVE_ID="$(config_assignment_value LOCALVLLM_ACTIVE_ID "$SERVE_ENV" 2>/dev/null || true)"
SERVED_NAME="$(config_assignment_value LOCALVLLM_SERVED_MODEL_NAME "$SERVE_ENV" 2>/dev/null || true)"

echo "Local $LOCALVLLM_BACKEND_LABEL started at http://${LOCALVLLM_LISTEN_HOST}:${PORT} (PID $PID)"
echo "Model: ${ACTIVE_ID:-unknown}${SERVED_NAME:+ (served as $SERVED_NAME)}"
echo "Use 'localvllm --backend $LOCALVLLM_BACKEND models' to see model IDs."
localvllm_link_cached_model \
  "$(config_assignment_value LOCALVLLM_MODEL "$SERVE_ENV")" \
  "$(config_assignment_value LOCALVLLM_REVISION "$SERVE_ENV")"

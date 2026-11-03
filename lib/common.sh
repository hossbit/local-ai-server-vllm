#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2153,SC2154

shell_quote_token() {
  local value="$1"

  printf "'%s'" "${value//\'/\'\\\'\'}"
}

expand_path() {
  local value="$1"

  case "$value" in
    \~)
      printf '%s\n' "$HOME"
      ;;
    \~/*)
      printf '%s/%s\n' "$HOME" "${value:2}"
      ;;
    *)
      printf '%s\n' "$value"
      ;;
  esac
}

resolve_ai_dir() {
  if [ -n "${LOCALVLLM_DIR:-}" ]; then
    expand_path "$LOCALVLLM_DIR"
  elif [ -f "$SCRIPT_DIR/../conf/localvllm.conf" ]; then
    cd "$SCRIPT_DIR/.." && pwd
  elif [ -f "$SCRIPT_DIR/install-localvllm.sh" ]; then
    expand_path "$LOCALVLLM_DEFAULT_DIR"
  else
    printf '%s\n' "$SCRIPT_DIR"
  fi
}

source_localvllm_lib() {
  local name="$1"
  local candidate

  for candidate in "$SCRIPT_DIR/lib/$name" "$SCRIPT_DIR/../lib/$name"; do
    if [ -f "$candidate" ]; then
      # shellcheck source=/dev/null
      . "$candidate"
      return 0
    fi
  done

  echo "Error: missing Local vLLM library: $name" >&2
  exit 1
}

# --- Backend profiles -------------------------------------------------------
#
# One manager, two isolated engines. Every per-backend path and setting is
# derived from the canonical backend name, never shared accidentally.

declare -ga LOCALVLLM_RUNTIME_KEYS=(
  ENGINE_DEFAULTS
  TENSOR_PARALLEL_SIZE
  GPU_MEMORY_UTILIZATION
  MAX_MODEL_LEN
  DTYPE
  QUANTIZATION
  MAX_NUM_SEQS
  MAX_NUM_BATCHED_TOKENS
  KV_CACHE_DTYPE
  SWAP_SPACE
  CPU_OFFLOAD_GB
  ENFORCE_EAGER
  TRUST_REMOTE_CODE
  DISABLE_LOG_REQUESTS
  ENABLE_SLEEP
  OMNI
  SERVED_MODEL_NAME
  REVISION
  CODE_REVISION
  TOKENIZER_REVISION
  TOKENIZER
  LOAD_FORMAT
  CHAT_TEMPLATE
  REASONING_PARSER
  TOOL_CALL_PARSER
  EXTRA_ARGS
  EXTRA_ENV
)
declare -gA LOCALVLLM_GLOBAL_RUNTIME=()

localvllm_eval_value() {
  local key="$1"
  local var="$2"
  local value

  eval "value=\${$var}"
  LOCALVLLM_GLOBAL_RUNTIME["$key"]="$value"
}

localvllm_capture_global_runtime() {
  local key var

  [ "${LOCALVLLM_GLOBAL_RUNTIME_CAPTURED:-0}" = "1" ] && return 0
  LOCALVLLM_GLOBAL_RUNTIME=()
  for key in "${LOCALVLLM_RUNTIME_KEYS[@]}"; do
    var="VLLM_$key"
    if declare -p "$var" >/dev/null 2>&1; then
      localvllm_eval_value "$key" "$var"
    else
      LOCALVLLM_GLOBAL_RUNTIME["$key"]=""
    fi
  done
  LOCALVLLM_GLOBAL_RUNTIME_CAPTURED=1
}

localvllm_backend_name() {
  local name="${1:-}"

  name="${name,,}"
  case "$name" in
    vllm|text|llm) printf 'vllm\n' ;;
    omni|vllm-omni|vllm_omni|omni-vllm) printf 'omni\n' ;;
    *) return 1 ;;
  esac
}

localvllm_backend_list() {
  local name canonical backends
  local -A seen=()

  backends="${LOCALVLLM_BACKENDS:-vllm omni}"
  for name in ${backends//,/ }; do
    canonical="$(localvllm_backend_name "$name")" || continue
    [ -n "${seen[$canonical]+x}" ] && continue
    seen["$canonical"]=1
    printf '%s\n' "$canonical"
  done
}

localvllm_backend_label() {
  case "$1" in
    vllm) printf 'vLLM\n' ;;
    omni) printf 'vLLM-Omni\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

localvllm_backend_package() {
  case "$1" in
    vllm) printf 'vllm\n' ;;
    omni) printf 'vllm-omni\n' ;;
    *) return 1 ;;
  esac
}

localvllm_backend_version_var() {
  case "$1" in
    vllm) printf 'VLLM_VERSION\n' ;;
    omni) printf 'VLLM_OMNI_VERSION\n' ;;
    *) return 1 ;;
  esac
}

localvllm_backend_pip_args_var() {
  case "$1" in
    vllm) printf 'VLLM_PIP_ARGS\n' ;;
    omni) printf 'VLLM_OMNI_PIP_ARGS\n' ;;
    *) return 1 ;;
  esac
}

localvllm_backend_default_port() {
  local name="$1"

  case "$name" in
    vllm) printf '%s\n' "${LOCALVLLM_VLLM_PORT:-8000}" ;;
    omni) printf '%s\n' "${LOCALVLLM_OMNI_PORT:-8091}" ;;
    *) return 1 ;;
  esac
}

localvllm_backend_service_name() {
  local name="$1"

  case "$name" in
    vllm) printf '%s\n' "${LOCALVLLM_VLLM_SERVICE_NAME:-localvllm.service}" ;;
    omni) printf '%s\n' "${LOCALVLLM_OMNI_SERVICE_NAME:-localvllm-omni.service}" ;;
    *) return 1 ;;
  esac
}

localvllm_backend_state_dir() {
  local ai_dir="${1:-${AI_DIR:-}}" name="$2"

  printf '%s/%s/%s/%s\n' \
    "$ai_dir" "${LOCALVLLM_CONF_SUBDIR:-conf}" \
    "${LOCALVLLM_BACKENDS_STATE_SUBDIR:-backends}" "$name"
}

localvllm_backend_models_dir() {
  local ai_dir="${1:-${AI_DIR:-}}" name="$2"

  printf '%s/%s/%s\n' "$ai_dir" "${LOCALVLLM_MODELS_SUBDIR:-models}" "$name"
}

localvllm_backend_venv_dir() {
  local ai_dir="${1:-${AI_DIR:-}}" name="$2"

  printf '%s/%s/%s\n' "$ai_dir" "${LOCALVLLM_VENV_SUBDIR:-venv}" "$name"
}

localvllm_backend_log_file() {
  local ai_dir="${1:-${AI_DIR:-}}" name="$2"

  printf '%s/%s/%s.log\n' "$ai_dir" "${LOCALVLLM_LOGS_SUBDIR:-logs}" "$name"
}

localvllm_backend_profile_file() {
  local conf_root="${1:-${CONF_ROOT:-}}" name="$2"

  printf '%s/%s/%s.conf\n' \
    "$conf_root" "${LOCALVLLM_BACKEND_PROFILES_SUBDIR:-backends.d}" "$name"
}

localvllm_backend_installed() {
  local name="$1"
  local venv

  name="$(localvllm_backend_name "$name")" || return 1
  venv="$(localvllm_backend_venv_dir "${AI_DIR:-}" "$name")"
  [ -x "$venv/bin/vllm" ] || return 1
  if [ "$name" = "omni" ]; then
    # Package presence, not a successful torch/CUDA import: a broken runtime
    # should still be listed as installed so `doctor` and `update` can fix it.
    [ -n "$(vllm_omni_installed_version "$venv")" ]
    return "$?"
  fi
  return 0
}

localvllm_backend_version() {
  local name="$1"
  local venv

  name="$(localvllm_backend_name "$name")" || return 1
  venv="$(localvllm_backend_venv_dir "${AI_DIR:-}" "$name")"

  if [ "$name" = "omni" ]; then
    vllm_omni_installed_version "$venv"
  else
    vllm_installed_version "$venv"
  fi
}

# localvllm_use_backend NAME: activate one backend. Rewrites every per-backend
# global used by the rest of the scripts, resets runtime tuning to the global
# baseline, then sources conf/backends.d/<name>.conf so that backend can have
# different defaults without leaking into the other one.
localvllm_use_backend() {
  local name
  local key var

  name="$(localvllm_backend_name "${1:-}")" || {
    echo "Error: unknown backend '${1:-}'. Use one of: $(localvllm_backend_list | paste -sd', ' -)" >&2
    return 1
  }

  [ -n "${AI_DIR:-}" ] || AI_DIR="$(resolve_ai_dir)"
  [ -n "${CONF_ROOT:-}" ] || CONF_ROOT="$AI_DIR/${LOCALVLLM_CONF_SUBDIR:-conf}"

  localvllm_capture_global_runtime

  for key in "${LOCALVLLM_RUNTIME_KEYS[@]}"; do
    var="VLLM_$key"
    printf -v "$var" '%s' "${LOCALVLLM_GLOBAL_RUNTIME[$key]-}"
  done

  LOCALVLLM_BACKEND="$name"
  LOCALVLLM_BACKEND_LABEL="$(localvllm_backend_label "$name")"
  LOCALVLLM_BACKEND_PACKAGE="$(localvllm_backend_package "$name")"
  LOCALVLLM_BACKEND_PROFILE="$(localvllm_backend_profile_file "$CONF_ROOT" "$name")"

  if [ -f "$LOCALVLLM_BACKEND_PROFILE" ]; then
    # shellcheck disable=SC1090
    . "$LOCALVLLM_BACKEND_PROFILE"
  fi

  # Backend identity is not a tuning knob: omni always uses --omni, and the
  # plain vllm backend never does. A per-model OMNI=0 override can still opt a
  # single omni-backend model out when it is really a text-only model.
  case "$name" in
    omni) VLLM_OMNI=1 ;;
    vllm) VLLM_OMNI=0 ;;
  esac
  LOCALVLLM_BACKEND_OMNI="${VLLM_OMNI:-0}"

  LOCALVLLM_BACKEND_STATE_DIR="$(localvllm_backend_state_dir "$AI_DIR" "$name")"
  LOCALVLLM_BACKEND_MODELS_DIR="$(localvllm_backend_models_dir "$AI_DIR" "$name")"
  LOCALVLLM_BACKEND_VENV_DIR="$(localvllm_backend_venv_dir "$AI_DIR" "$name")"
  LOCALVLLM_BACKEND_LOG_FILE="$(localvllm_backend_log_file "$AI_DIR" "$name")"
  LOCALVLLM_BACKEND_SERVICE_NAME="$(localvllm_backend_service_name "$name")"
  LOCALVLLM_BACKEND_DEFAULT_PORT="$(localvllm_backend_default_port "$name")"

  CONF_DIR="$LOCALVLLM_BACKEND_STATE_DIR"
  MODELS_DIR="$LOCALVLLM_BACKEND_MODELS_DIR"
  VENV_DIR="$LOCALVLLM_BACKEND_VENV_DIR"
  LOG_FILE="$LOCALVLLM_BACKEND_LOG_FILE"
  LOCALVLLM_DEFAULT_PORT="$LOCALVLLM_BACKEND_DEFAULT_PORT"
  LOCALVLLM_SERVICE_NAME="$LOCALVLLM_BACKEND_SERVICE_NAME"
  SERVICE_UNIT="${LOCALVLLM_SERVICE_NAME%.service}"
  SERVICE_FILE="$LOCALVLLM_SYSTEMD_USER_DIR/$LOCALVLLM_SERVICE_NAME"
  PORT_FILE="$CONF_DIR/$LOCALVLLM_PORT_FILE"
  PID_FILE="$CONF_DIR/$LOCALVLLM_PID_FILE"
  PID_START_FILE="$CONF_DIR/$LOCALVLLM_PID_FILE.start"
  SERVE_SH="$CONF_DIR/$LOCALVLLM_SERVE_SCRIPT"
  SERVE_ENV="$CONF_DIR/$LOCALVLLM_SERVE_ENV_FILE"
  ACTIVE_MODEL_FILE="$CONF_DIR/$LOCALVLLM_ACTIVE_MODEL_FILE"
  OVERRIDES_DIR="$CONF_DIR/$LOCALVLLM_MODELS_OVERRIDE_SUBDIR"
  VLLM_BIN="$VENV_DIR/bin/vllm"
  VLLM_PYTHON="$VENV_DIR/bin/python"

  return 0
}

api_base_url_for_port_file() {
  local port_file="$1"
  local port

  port="$([ -f "$port_file" ] && cat "$port_file" || printf '%s' "$LOCALVLLM_DEFAULT_PORT")"
  printf 'http://%s:%s' "$LOCALVLLM_LISTEN_HOST" "$port"
}

port_is_listening() {
  local port="$1"
  local port_hex

  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":${port}$"
    return "$?"
  fi

  port_hex="$(printf '%04X' "$port")"
  awk -v port="$port_hex" '
    $4 == "0A" {
      n = split($2, address, ":")
      if (toupper(address[n]) == port) {
        found = 1
      }
    }
    END { exit found ? 0 : 1 }
  ' /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

system_ram_bytes() {
  if [ -n "${LOCALVLLM_SUGGEST_RAM_BYTES:-}" ]; then
    printf '%s\n' "$LOCALVLLM_SUGGEST_RAM_BYTES"
    return 0
  fi

  awk '/MemTotal:/ { printf "%.0f\n", $2 * 1024; exit }' /proc/meminfo 2>/dev/null || printf '0\n'
}

# nvidia-smi does not honor CUDA_VISIBLE_DEVICES itself. Apply the selected
# backend/model mask explicitly, and do not guess physical memory for MIG IDs.
localvllm_nvidia_query() {
  local field="$1" mask="${CUDA_VISIBLE_DEVICES-${LOCALVLLM_CUDA_VISIBLE_DEVICES:-}}"
  local -a args=("--query-gpu=$field" "--format=csv,noheader,nounits")
  if [[ "${CUDA_VISIBLE_DEVICES+x}" || -n "$mask" ]]; then
    case "$mask" in
      ''|-1|*MIG-*) return 1 ;;
    esac
    args+=("--id=$mask")
  fi
  nvidia-smi "${args[@]}" 2>/dev/null
}

gpu_vram_bytes() {
  local mib bytes candidate max_bytes=0

  if [ -n "${LOCALVLLM_SUGGEST_VRAM_BYTES:-}" ]; then
    printf '%s\n' "$LOCALVLLM_SUGGEST_VRAM_BYTES"
    return 0
  fi

  if command -v nvidia-smi >/dev/null 2>&1; then
    mib="$(localvllm_nvidia_query memory.total | awk 'NR == 1 {print int($1); exit}')" || mib=""
    if [ -n "$mib" ] && [ "$mib" -gt 0 ] 2>/dev/null; then
      printf '%s\n' "$((mib * 1024 * 1024))"
      return 0
    fi
  fi

  if [[ "${CUDA_VISIBLE_DEVICES+x}" || -n "${LOCALVLLM_CUDA_VISIBLE_DEVICES:-}" ]]; then
    printf '0\n'
    return 0
  fi

  if command -v rocm-smi >/dev/null 2>&1; then
    bytes="$(rocm-smi --showmeminfo vram 2>/dev/null | awk '/Total Memory.*\(B\)/ {printf "%.0f\n", $NF; exit}')"
    if [ -n "$bytes" ] && [ "$bytes" -gt 0 ] 2>/dev/null; then
      printf '%s\n' "$bytes"
      return 0
    fi
  fi

  for candidate in /sys/class/drm/card*/device/mem_info_vram_total; do
    [ -r "$candidate" ] || continue
    bytes="$(cat "$candidate" 2>/dev/null || printf '0')"
    if [ -n "$bytes" ] && [ "$bytes" -gt "$max_bytes" ] 2>/dev/null; then
      max_bytes="$bytes"
    fi
  done
  if [ "$max_bytes" -gt 0 ] 2>/dev/null; then
    printf '%s\n' "$max_bytes"
    return 0
  fi

  printf '0\n'
}

gpu_vram_free_bytes() {
  local mib

  if [ -n "${LOCALVLLM_SUGGEST_VRAM_FREE_BYTES:-}" ]; then
    printf '%s\n' "$LOCALVLLM_SUGGEST_VRAM_FREE_BYTES"
    return 0
  fi

  if command -v nvidia-smi >/dev/null 2>&1; then
    mib="$(localvllm_nvidia_query memory.free | awk 'NR == 1 {print int($1); exit}')" || mib=""
    if [ -n "$mib" ] && [ "$mib" -gt 0 ] 2>/dev/null; then
      printf '%s\n' "$((mib * 1024 * 1024))"
      return 0
    fi
  fi
  printf '0\n'
}

# Minimum total/free VRAM across visible GPUs. Tensor parallelism and placement
# are limited by the smallest device, not the first or largest one.
gpu_vram_total_min_bytes() {
  local min="" value

  if [ -n "${LOCALVLLM_SUGGEST_VRAM_BYTES:-}" ]; then
    printf '%s\n' "$LOCALVLLM_SUGGEST_VRAM_BYTES"
    return 0
  fi

  if command -v nvidia-smi >/dev/null 2>&1; then
    while IFS= read -r value; do
      value="$(printf '%s' "$value" | tr -d ' ')"
      [[ "$value" =~ ^[0-9]+$ ]] || continue
      if [ -z "$min" ] || [ "$value" -lt "$min" ]; then
        min="$value"
      fi
    done < <(localvllm_nvidia_query memory.total)
    if [ -n "$min" ]; then
      printf '%s\n' "$((min * 1024 * 1024))"
      return 0
    fi
  fi

  if [[ "${CUDA_VISIBLE_DEVICES+x}" || -n "${LOCALVLLM_CUDA_VISIBLE_DEVICES:-}" ]]; then
    printf '0\n'
  else
    gpu_vram_bytes
  fi
}

gpu_vram_free_min_bytes() {
  local min="" value

  if [ -n "${LOCALVLLM_SUGGEST_VRAM_FREE_BYTES:-}" ]; then
    printf '%s\n' "$LOCALVLLM_SUGGEST_VRAM_FREE_BYTES"
    return 0
  fi

  if command -v nvidia-smi >/dev/null 2>&1; then
    while IFS= read -r value; do
      value="$(printf '%s' "$value" | tr -d ' ')"
      [[ "$value" =~ ^[0-9]+$ ]] || continue
      if [ -z "$min" ] || [ "$value" -lt "$min" ]; then
        min="$value"
      fi
    done < <(localvllm_nvidia_query memory.free)
    if [ -n "$min" ]; then
      printf '%s\n' "$((min * 1024 * 1024))"
      return 0
    fi
  fi

  printf '0\n'
}

# gpu_count: number of distinct GPUs detected, used by `localvllm suggest` to
# recommend tensor-parallel size. Not used for VRAM math in the server itself.
gpu_count() {
  local count candidate

  if [ -n "${LOCALVLLM_SUGGEST_GPU_COUNT:-}" ]; then
    printf '%s\n' "$LOCALVLLM_SUGGEST_GPU_COUNT"
    return 0
  fi

  if command -v nvidia-smi >/dev/null 2>&1; then
    count="$(localvllm_nvidia_query index | grep -c .)" || count=0
    if [ -n "$count" ] && [ "$count" -gt 0 ] 2>/dev/null; then
      printf '%s\n' "$count"
      return 0
    fi
  fi

  if [[ "${CUDA_VISIBLE_DEVICES+x}" || -n "${LOCALVLLM_CUDA_VISIBLE_DEVICES:-}" ]]; then
    printf '0\n'
    return 0
  fi

  if command -v rocm-smi >/dev/null 2>&1; then
    count="$(rocm-smi --showid 2>/dev/null | grep -c '^GPU\[')" || count=0
    if [ -n "$count" ] && [ "$count" -gt 0 ] 2>/dev/null; then
      printf '%s\n' "$count"
      return 0
    fi
  fi

  count=0
  for candidate in /sys/class/drm/card*/device/mem_info_vram_total; do
    [ -r "$candidate" ] || continue
    count=$((count + 1))
  done
  printf '%s\n' "$count"
}

format_bytes_gib() {
  local bytes="$1"

  awk -v bytes="$bytes" 'BEGIN { printf "%.1f GiB", bytes / 1024 / 1024 / 1024 }'
}

format_bytes_human() {
  local bytes="$1"

  awk -v bytes="$bytes" 'BEGIN {
    if (bytes >= 1024 * 1024 * 1024) {
      printf "%.1f GiB", bytes / 1024 / 1024 / 1024
    } else if (bytes >= 1024 * 1024) {
      printf "%.1f MiB", bytes / 1024 / 1024
    } else if (bytes >= 1024) {
      printf "%.1f KiB", bytes / 1024
    } else {
      printf "%d B", bytes
    }
  }'
}

process_start_time() {
  local pid="$1"

  ps -p "$pid" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

pid_file_matches_process() {
  local pid_file="$1"
  local start_file="$2"
  local pid recorded_start current_start

  [ -f "$pid_file" ] || return 1
  pid="$(<"$pid_file")"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1

  if [ -f "$start_file" ]; then
    recorded_start="$(<"$start_file")"
    current_start="$(process_start_time "$pid")"
    [ -n "$current_start" ] && [ "$recorded_start" = "$current_start" ] || return 1
  fi

  return 0
}

process_is_vllm() {
  local pid="$1"
  local args

  args="$(ps -p "$pid" -o args= 2>/dev/null || true)"
  case "$args" in
    *vllm*|*serve.sh*) return 0 ;;
    *) return 1 ;;
  esac
}

# --- Service helpers shared by the CLI and the update/install scripts ------

localvllm_has_user_service() {
  command -v systemctl >/dev/null 2>&1 &&
    systemctl --user cat "$LOCALVLLM_SERVICE_NAME" >/dev/null 2>&1
}

localvllm_service_is_active() {
  if localvllm_has_user_service &&
    systemctl --user is-active --quiet "${LOCALVLLM_SERVICE_NAME%.service}" 2>/dev/null; then
    return 0
  fi
  pid_file_matches_process "$PID_FILE" "$PID_START_FILE"
}

localvllm_stop_service() {
  if localvllm_has_user_service; then
    systemctl --user stop "$LOCALVLLM_SERVICE_NAME"
  elif [ -x "${BIN_DIR:-}/stop.sh" ]; then
    "$BIN_DIR/stop.sh" "$LOCALVLLM_BACKEND"
  else
    return 0
  fi
}

localvllm_start_service() {
  if localvllm_has_user_service; then
    systemctl --user start "$LOCALVLLM_SERVICE_NAME"
  elif [ -x "${BIN_DIR:-}/start.sh" ]; then
    "$BIN_DIR/start.sh" "$LOCALVLLM_BACKEND"
  else
    return 0
  fi
}

# One global writer lock for the whole manager. Mutating CLI commands take it
# once and pass LOCALVLLM_LOCK_HELD=1 to helpers they invoke, avoiding nested
# locks on the same file. Direct start/stop/install/update invocations take it
# themselves.
localvllm_acquire_global_lock() {
  [ "${LOCALVLLM_LOCK_HELD:-0}" = "1" ] && return 0

  # systemd serializes its own ExecStart/ExecStop units. A CLI operation may
  # already hold the manager lock while asking systemd to restart one; requiring
  # a second lock inside the unit would deadlock that path. The unit sets this
  # marker explicitly (unlike INVOCATION_ID, which leaks into unrelated shells
  # started from a systemd service).
  if [ "${LOCALVLLM_SYSTEMD_UNIT:-0}" = "1" ]; then
    export LOCALVLLM_LOCK_HELD=1
    return 0
  fi

  if ! command -v flock >/dev/null 2>&1; then
    echo "Warning: flock not found; continuing without the Local vLLM operation lock." >&2
    export LOCALVLLM_LOCK_HELD=1
    return 0
  fi

  [ -n "${CONF_ROOT:-}" ] || CONF_ROOT="${AI_DIR:-}/conf"
  mkdir -p "$CONF_ROOT"
  # FD 9 is intentionally kept open for the lifetime of the process.
  exec 9>"$CONF_ROOT/.localvllm.lock"
  if ! flock -n 9; then
    echo "Error: another Local vLLM operation is running (lock: $CONF_ROOT/.localvllm.lock)." >&2
    exit 1
  fi
  export LOCALVLLM_LOCK_HELD=1
}

vllm_bin_path() {
  local ai_dir="${1:-${AI_DIR:-}}"

  printf '%s/%s/bin/vllm\n' "$ai_dir" "${LOCALVLLM_VENV_SUBDIR:-venv}"
}

vllm_python_path() {
  local ai_dir="${1:-${AI_DIR:-}}"

  printf '%s/%s/bin/python\n' "$ai_dir" "${LOCALVLLM_VENV_SUBDIR:-venv}"
}

vllm_installed_version() {
  local venv="${1:-${VENV_DIR:-}}"
  local out

  [ -n "$venv" ] || return 0
  # Read package metadata without importing GPU libraries. `vllm --version`
  # can print warnings with timestamps before the actual version.
  if [ -x "$venv/bin/python" ]; then
    out="$("$venv/bin/python" -c 'from importlib.metadata import version; print(version("vllm"))' 2>/dev/null)" || out=""
    if [ -n "$out" ]; then
      printf '%s\n' "$out"
      return 0
    fi
  fi
  if [ -x "$venv/bin/vllm" ]; then
    out="$("$venv/bin/vllm" --version 2>/dev/null)" || out=""
    printf '%s\n' "$out" | sed -nE 's/^(vllm[[:space:]]+)?([0-9]+\.[0-9]+(\.[0-9]+)?[A-Za-z0-9.+_-]*)$/\2/p' | tail -n1
  fi
}

vllm_latest_version() {
  local json

  json="$(curl --connect-timeout 10 --max-time 30 -fsSL https://pypi.org/pypi/vllm/json)" || return 1
  jq -er '.info.version' <<<"$json"
}

vllm_omni_installed_version() {
  local venv="${1:-${VENV_DIR:-}}"

  [ -x "$venv/bin/python" ] || return 0
  "$venv/bin/python" -c 'from importlib.metadata import version; print(version("vllm-omni"))' 2>/dev/null | head -n1 || true
}

vllm_omni_latest_version() {
  local json

  json="$(curl --connect-timeout 10 --max-time 30 -fsSL https://pypi.org/pypi/vllm-omni/json)" || return 1
  jq -er '.info.version' <<<"$json"
}

vllm_omni_is_available() {
  local venv="${1:-${VENV_DIR:-}}"

  [ -x "$venv/bin/python" ] || return 1
  "$venv/bin/python" -c 'import vllm_omni' >/dev/null 2>&1
}

versions_match() {
  local left="${1#v}"
  local right="${2#v}"

  [ "${left%%+*}" = "${right%%+*}" ]
}

python_version() {
  local python="$1"

  "$python" -c 'import sys; print(".".join(map(str, sys.version_info[:3])))' 2>/dev/null
}

python_meets_minimum() {
  local python="$1"
  local minimum="$2"
  local have

  have="$(python_version "$python")" || return 1
  awk -v have="$have" -v minimum="$minimum" 'BEGIN {
    split(have, h, ".")
    split(minimum, m, ".")
    for (i = 1; i <= 3; i++) {
      if ((h[i] + 0) > (m[i] + 0)) exit 0
      if ((h[i] + 0) < (m[i] + 0)) exit 1
    }
    exit 0
  }'
}

localvllm_detect_format() {
  local spec="$1"

  if [ -d "$spec" ]; then
    if { [ -f "$spec/config.json" ] || [ -f "$spec/model_index.json" ]; }; then
      printf 'hf\n'
      return 0
    fi
    if find "$spec" -maxdepth 1 -type f -name '*.gguf' -print -quit 2>/dev/null | grep -q .; then
      printf 'gguf\n'
      return 0
    fi
    printf 'unknown\n'
    return 0
  fi

  if [ -f "$spec" ]; then
    case "$spec" in
      *.gguf) printf 'gguf\n' ;;
      *) printf 'unknown\n' ;;
    esac
    return 0
  fi

  printf 'remote\n'
}

# Locate only the requested cached revision; never download or guess a snapshot.
localvllm_cached_model_path() {
  local model="$1" revision="${2:-main}" root snapshot
  [[ "$model" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || return 1
  root="${LOCALVLLM_HF_HOME:-$AI_DIR/${LOCALVLLM_HF_CACHE_SUBDIR:-hf-cache}}/hub/models--${model//\//--}"
  snapshot="$revision"
  if [ -f "$root/refs/$revision" ]; then
    snapshot="$(cat "$root/refs/$revision")"
  fi
  [[ "$snapshot" =~ ^[a-fA-F0-9]+$ ]] || return 1
  { [ -f "$root/snapshots/$snapshot/config.json" ] || [ -f "$root/snapshots/$snapshot/model_index.json" ]; } || return 1
  printf '%s\n' "$root/snapshots/$snapshot"
}

# A readable library link keeps one shared HF cache copy of the weights.
localvllm_link_cached_model() {
  local model="$1" revision="${2:-main}" snapshot link
  snapshot="$(localvllm_cached_model_path "$model" "$revision")" || return 0
  link="$MODELS_DIR/$(localvllm_safe_id "$model")"
  if [ -L "$link" ]; then
    # Refresh only links that already point into this model's cache snapshots.
    case "$(readlink "$link")" in
      "$(dirname "$(dirname "$snapshot")")"/snapshots/*)
        ln -sfn -- "$snapshot" "$link" 2>/dev/null || return 0
        return 0
        ;;
    esac
    return 0
  fi
  [ ! -e "$link" ] || return 0
  mkdir -p "$MODELS_DIR" || return 0
  ln -s -- "$snapshot" "$link" 2>/dev/null || return 0
  echo "Model files: $link (linked to the shared download cache)"
}

localvllm_model_size_bytes() {
  local spec="$1"

  if [ -d "$spec" ]; then
    # -L follows Hugging Face cache snapshot symlinks back to their blobs.
    du -sbL "$spec" 2>/dev/null | awk '{print $1; exit}'
  elif [ -f "$spec" ]; then
    stat -c '%s' "$spec" 2>/dev/null || printf '0\n'
  else
    printf '0\n'
  fi
}

localvllm_safe_id() {
  local id

  id="$(printf '%s' "$1" | sed 's#[/[:space:]]#__#g; s#[^A-Za-z0-9._-]#_#g')"
  [ -n "$id" ] || id=model
  printf '%s\n' "$id"
}

# localvllm_override_meta FILE: prints "ID<TAB>MODEL<TAB>FORMAT" for a
# models.d file. The file is sourced in a throwaway subshell so one malformed
# model override cannot poison discovery of every other model.
localvllm_override_meta() {
  local file="$1"

  (
    set +u
    unset ID MODEL FORMAT MODEL_TYPE
    # shellcheck disable=SC1090
    . "$file" >/dev/null 2>&1 || exit 0
    printf '%s\t%s\t%s\n' "${ID:-}" "${MODEL:-}" "${FORMAT:-}"
  )
}

localvllm_override_file_for_id() {
  local overrides_dir="$1"
  local wanted="$2"
  local file meta id candidate

  [ -d "$overrides_dir" ] || return 1

  while IFS= read -r file; do
    meta="$(localvllm_override_meta "$file")" || continue
    IFS=$'\t' read -r id _ _ <<<"$meta"
    [ -n "$id" ] || id="$(basename "$file" .conf)"
    if [ "$id" = "$wanted" ]; then
      printf '%s\n' "$file"
      return 0
    fi
  done < <(find "$overrides_dir" -mindepth 1 -maxdepth 1 -type f -name '*.conf' -print | sort)

  candidate="$overrides_dir/$(localvllm_safe_id "$wanted").conf"
  if [ -f "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  return 1
}

# localvllm_model_entries MODELS_DIR [OVERRIDES_DIR]
# Prints one tab-separated entry per model:
#   id<TAB>source<TAB>model<TAB>format<TAB>path
# source is "local" (auto-discovered) or "configured" (models.d override).
localvllm_model_entries() {
  local models_dir="$1"
  local overrides_dir="${2:-}"
  local -A id_source=()
  local -A id_model=()
  local -A id_format=()
  local -A id_path=()

  if [ -z "$overrides_dir" ] && [ -n "${CONF_DIR:-}" ]; then
    overrides_dir="$CONF_DIR/${LOCALVLLM_MODELS_OVERRIDE_SUBDIR:-models.d}"
  fi

  if [ -d "$models_dir" ]; then
    local path base id gguf config snapshot model_root parent resolved
    while IFS= read -r path; do
      base="$(basename "$path")"
      if [ -f "$path/config.json" ] || [ -f "$path/model_index.json" ]; then
        id="$base"
        if [ -L "$path" ]; then
          resolved="$(readlink -f "$path")"
          case "$resolved" in
            */models--*/snapshots/*)
              parent="$(basename "$(dirname "$(dirname "$resolved")")")"
              id="${parent#models--}"
              id="${id//--//}"
              ;;
          esac
        fi
        id_source["$id"]=local
        id_model["$id"]="$path"
        id_format["$id"]=hf
        id_path["$id"]="$path"
      else
        gguf="$(find -L "$path" -maxdepth 1 -type f -name '*.gguf' -print -quit 2>/dev/null || true)"
        if [ -n "$gguf" ]; then
          id="$base"
          id_source["$id"]=local
          id_model["$id"]="$gguf"
          id_format["$id"]=gguf
          id_path["$id"]="$path"
        elif find "$path" -maxdepth 1 -type f -name '*.safetensors' -print -quit 2>/dev/null | grep -q .; then
          echo "Warning: model folder has weights but no config.json: $path" >&2
        fi
      fi
    done < <(find -L "$models_dir" -mindepth 1 -maxdepth 1 -type d -print | sort)

    while IFS= read -r path; do
      base="$(basename "$path")"
      id="${base%.gguf}"
      [ -n "${id_source[$id]+x}" ] && continue
      id_source["$id"]=local
      id_model["$id"]="$path"
      id_format["$id"]=gguf
      id_path["$id"]="$path"
    done < <(find -L "$models_dir" -mindepth 1 -maxdepth 1 -type f -name '*.gguf' -print | sort)

    # Hugging Face cache snapshots: hub/models--org--model/snapshots/<rev>.
    # This lets models downloaded by vLLM itself appear in `localvllm models`.
    while IFS= read -r config; do
      snapshot="$(dirname "$config")"
      [ "$(basename "$(dirname "$snapshot")")" = snapshots ] || continue
      model_root="$snapshot"
      while [ "$model_root" != "/" ] && [ "$(basename "$model_root")" != "snapshots" ]; do
        model_root="$(dirname "$model_root")"
      done
      parent="$(basename "$(dirname "$model_root")")"
      case "$parent" in
        models--*)
          id="${parent#models--}"
          id="${id//--//}"
          ;;
        *)
          id="$(basename "$snapshot")"
          ;;
      esac
      [ -n "$id" ] || continue
      [ -n "${id_source[$id]+x}" ] && continue
      id_source["$id"]=local
      id_model["$id"]="$snapshot"
      id_format["$id"]=hf
      id_path["$id"]="$snapshot"
    done < <(find -L "$models_dir" -mindepth 4 -maxdepth 6 -type f \( -name config.json -o -name model_index.json \) -path '*/snapshots/*' -print 2>/dev/null | sort)
  fi

  if [ -n "$overrides_dir" ] && [ -d "$overrides_dir" ]; then
    local file meta id model format gguf_file
    while IFS= read -r file; do
      meta="$(localvllm_override_meta "$file")" || continue
      IFS=$'\t' read -r id model format <<<"$meta"
      [ -n "$id" ] || id="$(basename "$file" .conf)"

      # A models.d file may contain only tuning (no MODEL). If it names an
      # already-discovered local model, keep that model and mark the entry as
      # configured; otherwise there is nothing to attach the settings to.
      if [ -z "$model" ]; then
        if [ -n "${id_model[$id]+x}" ]; then
          id_source["$id"]=configured
        else
          echo "Warning: $file does not set MODEL and no local model '$id' exists; skipping." >&2
        fi
        continue
      fi

      if [ ! -e "$model" ] && [ -e "$models_dir/$model" ]; then
        model="$models_dir/$model"
      fi
      [ -n "$format" ] || format="$(localvllm_detect_format "$model")"
      # A GGUF model specified as a folder is served from its first file, but
      # sized from the whole folder so split shards are counted.
      if [ "$format" = "gguf" ] && [ -d "$model" ]; then
        gguf_file="$(find "$model" -maxdepth 1 -type f -name '*.gguf' -print -quit 2>/dev/null || true)"
        [ -n "$gguf_file" ] || { echo "Warning: $file points at a GGUF folder with no .gguf file; skipping." >&2; continue; }
        id_source["$id"]=configured
        id_model["$id"]="$gguf_file"
        id_format["$id"]=gguf
        id_path["$id"]="$model"
        continue
      fi
      id_source["$id"]=configured
      id_model["$id"]="$model"
      id_format["$id"]="$format"
      id_path["$id"]="$model"
      if [ "$format" = remote ] && [ -d "$models_dir/$(localvllm_safe_id "$id")" ]; then
        id_path["$id"]="$models_dir/$(localvllm_safe_id "$id")"
      fi
    done < <(find "$overrides_dir" -mindepth 1 -maxdepth 1 -type f -name '*.conf' -print | sort)
  fi

  local id
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$id" "${id_source[$id]}" "${id_model[$id]}" "${id_format[$id]}" "${id_path[$id]}"
  done < <(printf '%s\n' "${!id_source[@]}" | LC_ALL=C sort)
}

localvllm_has_model_entries() {
  local models_dir="$1"
  local overrides_dir="${2:-}"

  [ -n "$(localvllm_model_entries "$models_dir" "$overrides_dir")" ]
}

# localvllm_find_entry MODELS_DIR WANTED [OVERRIDES_DIR]
# Prints the TSV entry whose id or model spec matches WANTED.
localvllm_find_entry() {
  local models_dir="$1"
  local wanted="$2"
  local overrides_dir="${3:-}"
  local id source model format path

  while IFS=$'\t' read -r id source model format path; do
    [ -n "$id" ] || continue
    if [ "$id" = "$wanted" ] || [ "$model" = "$wanted" ]; then
      printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$source" "$model" "$format" "$path"
      return 0
    fi
  done < <(localvllm_model_entries "$models_dir" "$overrides_dir")

  return 1
}

localvllm_model_type() {
  local id="$1"
  local override="${2:-}"
  local type=""

  if [ -n "$override" ] && [ -f "$override" ]; then
    type="$(
      set +u
      unset MODEL_TYPE
      # shellcheck disable=SC1090
      . "$override" >/dev/null 2>&1 || exit 0
      printf '%s' "${MODEL_TYPE:-}"
    )"
  fi

  case "$type" in
    chat|completion|embedding|reranking)
      printf '%s\n' "$type"
      return 0
      ;;
  esac

  case "${id,,}" in
    *rerank*) printf 'reranking\n' ;;
    *embed*|*bge*|e5-*|*[-_.]e5[-_.]*|*[-_.]e5) printf 'embedding\n' ;;
    *) printf 'chat\n' ;;
  esac
}

# localvllm_resolve_active [MODELS_DIR] [ACTIVE_FILE] [OVERRIDES_DIR]
# Sets ACTIVE_ID, ACTIVE_MODEL, ACTIVE_FORMAT, ACTIVE_SOURCE, and
# ACTIVE_OVERRIDE. Returns non-zero with an actionable message when no model
# can be selected.
localvllm_resolve_active() {
  local models_dir="${1:-${MODELS_DIR:-}}"
  local active_file="${2:-${ACTIVE_MODEL_FILE:-}}"
  local overrides_dir="${3:-${OVERRIDES_DIR:-}}"
  local active_id=""
  local id source model format path found=0
  local -a ids=()

  ACTIVE_ID=""
  ACTIVE_MODEL=""
  ACTIVE_FORMAT=""
  ACTIVE_SOURCE=""
  ACTIVE_OVERRIDE=""

  if [ -n "$active_file" ] && [ -f "$active_file" ]; then
    active_id="$(<"$active_file")"
    active_id="${active_id//$'\r'/}"
    active_id="${active_id#"${active_id%%[![:space:]]*}"}"
    active_id="${active_id%"${active_id##*[![:space:]]}"}"
  fi

  if [ -n "$active_id" ]; then
    while IFS=$'\t' read -r id source model format path; do
      [ -n "$id" ] || continue
      if [ "$id" = "$active_id" ]; then
        ACTIVE_ID="$id"
        ACTIVE_MODEL="$model"
        ACTIVE_FORMAT="$format"
        ACTIVE_SOURCE="$source"
        found=1
        break
      fi
    done < <(localvllm_model_entries "$models_dir" "$overrides_dir")

    if [ "$found" -eq 0 ]; then
      echo "Error: active model '$active_id' is not available under $models_dir or $overrides_dir." >&2
      echo "Choose an available model with 'localvllm --backend ${LOCALVLLM_BACKEND:-vllm} use MODEL', or remove $active_file." >&2
      return 1
    fi
  elif [ -n "${LOCALVLLM_MODEL:-}" ]; then
    model="$LOCALVLLM_MODEL"
    if [ ! -e "$model" ] && [ -e "$models_dir/$model" ]; then
      model="$models_dir/$model"
    fi
    ACTIVE_ID="default"
    ACTIVE_MODEL="$model"
    ACTIVE_FORMAT="$(localvllm_detect_format "$model")"
    ACTIVE_SOURCE="configured"
  else
    while IFS=$'\t' read -r id source model format path; do
      [ -n "$id" ] || continue
      ids+=("$id")
      ACTIVE_ID="$id"
      ACTIVE_MODEL="$model"
      ACTIVE_FORMAT="$format"
      ACTIVE_SOURCE="$source"
    done < <(localvllm_model_entries "$models_dir" "$overrides_dir")

    if [ "${#ids[@]}" -eq 0 ]; then
      echo "Error: no models found in $models_dir." >&2
      echo "Add a Hugging Face model directory, or run 'localvllm --backend ${LOCALVLLM_BACKEND:-vllm} use org/model'." >&2
      return 1
    fi
    if [ "${#ids[@]}" -gt 1 ]; then
      echo "Error: multiple models are available; choose one first." >&2
      echo "Run: localvllm --backend ${LOCALVLLM_BACKEND:-vllm} use MODEL" >&2
      echo "Available models:" >&2
      printf '  %s\n' "${ids[@]}" >&2
      return 1
    fi
  fi

  if [ -n "$overrides_dir" ]; then
    ACTIVE_OVERRIDE="$(localvllm_override_file_for_id "$overrides_dir" "$ACTIVE_ID" 2>/dev/null || true)"
  fi

  return 0
}

# Validate the model before handing a start/restart request to systemd so
# selection errors are visible in the terminal, not just the service journal.
localvllm_serving_mode() {
  local mode=direct
  [ ! -f "$CONF_DIR/serving-mode" ] || mode="$(cat "$CONF_DIR/serving-mode")"
  case "$mode" in direct|swap) printf '%s\n' "$mode" ;; *) echo "Error: invalid serving mode: $mode" >&2; return 1 ;; esac
}

localvllm_require_start_model() {
  if [ "$(localvllm_serving_mode)" = swap ]; then
    localvllm_has_model_entries "$MODELS_DIR" "$OVERRIDES_DIR" && return 0
    echo "Add a model first with 'localvllm --backend $LOCALVLLM_BACKEND pull ORG/MODEL'." >&2
    return 1
  fi
  if ! localvllm_resolve_active "$MODELS_DIR" "$ACTIVE_MODEL_FILE" "$OVERRIDES_DIR"; then
    echo "Select a model for the $LOCALVLLM_BACKEND backend before starting it." >&2
    echo "Guided setup: localvllm setup" >&2
    echo "Or select one: localvllm --backend $LOCALVLLM_BACKEND use MODEL" >&2
    echo "Then start: localvllm start $LOCALVLLM_BACKEND" >&2
    return 1
  fi
}

localvllm_write_active() {
  local active_file="$1"
  local id="$2"
  local tmp

  mkdir -p "$(dirname "$active_file")"
  tmp="$(mktemp "${active_file}.XXXXXX")" || return 1
  if ! printf '%s\n' "$id" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$active_file"
}

# --- Terminal color helpers -------------------------------------------------

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  LOCALVLLM_COLOR_ENABLED=1
else
  LOCALVLLM_COLOR_ENABLED=0
fi

use_color() {
  [ "$LOCALVLLM_COLOR_ENABLED" = "1" ]
}

c() {
  local code="$1" text="$2"

  if use_color; then
    printf '\033[%sm%s\033[0m' "$code" "$text"
  else
    printf '%s' "$text"
  fi
}

# --- API key registry (`localvllm key ...`) --------------------------------
#
# Registry file format: one `version\t1` header line, then one line per key:
#   id\tname\tcreated_at\tstatus\tsecret
# `secret` is redacted to "-" once a key is revoked. vLLM supports one active
# key per server, so create refuses to add a second active key.

API_KEY_ID_RE='^[a-f0-9]{12}$'
API_KEY_SECRET_RE='^sk-localvllm-[0-9a-f]{64}$'
API_KEY_NAME_RE='^[A-Za-z0-9 ._-]{1,64}$'
API_KEY_TIMESTAMP_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'

api_key_registry_path() {
  printf '%s\n' "$CONF_DIR/$LOCALVLLM_API_KEY_FILE"
}

api_key_validate_name() {
  [[ "$1" =~ $API_KEY_NAME_RE ]]
}

api_key_generate_secret() {
  if command -v openssl >/dev/null 2>&1; then
    printf 'sk-localvllm-%s\n' "$(openssl rand -hex 32)"
  elif [ -r /dev/urandom ]; then
    printf 'sk-localvllm-%s\n' "$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  else
    return 1
  fi
}

api_key_generate_id() {
  printf '%s' "$1" | sha256sum | awk '{print substr($1, 1, 12)}'
}

api_key_mask() {
  local secret="$1"

  printf '%s...%s\n' "${secret:0:17}" "${secret: -4}"
}

api_key_registry_validate() {
  local file="$1"
  local line n=0 id name created status secret
  local -A seen_ids=()

  [ -f "$file" ] || return 0

  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    if [ "$n" -eq 1 ]; then
      [ "$line" = "$(printf 'version\t1')" ] ||
        { echo "Error: unsupported or missing version header in $file" >&2; return 1; }
      continue
    fi

    IFS=$'\t' read -r id name created status secret <<<"$line"

    [[ "$id" =~ $API_KEY_ID_RE ]] ||
      { echo "Error: malformed key id in $file (line $n)" >&2; return 1; }
    [ -z "${seen_ids[$id]+x}" ] ||
      { echo "Error: duplicate key id in $file (line $n)" >&2; return 1; }
    seen_ids["$id"]=1
    api_key_validate_name "$name" ||
      { echo "Error: malformed key name in $file (line $n)" >&2; return 1; }
    [[ "$created" =~ $API_KEY_TIMESTAMP_RE ]] ||
      { echo "Error: malformed timestamp in $file (line $n)" >&2; return 1; }

    case "$status" in
      active)
        [[ "$secret" =~ $API_KEY_SECRET_RE ]] ||
          { echo "Error: malformed secret in $file (line $n)" >&2; return 1; }
        ;;
      revoked)
        [ "$secret" = "-" ] ||
          { echo "Error: revoked key must have a redacted secret in $file (line $n)" >&2; return 1; }
        ;;
      *)
        echo "Error: unknown key status '$status' in $file (line $n)" >&2
        return 1
        ;;
    esac
  done < "$file"
}

api_key_registry_rows() {
  local file="$1"
  local line n=0

  [ -f "$file" ] || return 0

  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    [ "$n" -eq 1 ] && continue
    printf '%s\n' "$line"
  done < "$file"
}

api_key_active_secrets() {
  local file="$1"
  local id name created status secret

  while IFS=$'\t' read -r id name created status secret; do
    [ "$status" = active ] || continue
    printf '%s\n' "$secret"
  done < <(api_key_registry_rows "$file")
}

api_key_active_named_secrets() {
  local file="$1"
  local id name created status secret

  while IFS=$'\t' read -r id name created status secret; do
    [ "$status" = active ] || continue
    printf '%s\t%s\n' "$name" "$secret"
  done < <(api_key_registry_rows "$file")
}

api_key_active_count() {
  local file="$1"
  local count=0
  local id name created status secret

  while IFS=$'\t' read -r id name created status secret; do
    [ "$status" = active ] || continue
    count=$((count + 1))
  done < <(api_key_registry_rows "$file")

  printf '%s\n' "$count"
}

AUTH_CURL_ARGS=()
api_auth_curl_args() {
  local registry secret

  AUTH_CURL_ARGS=()
  registry="$(api_key_registry_path)"
  [ -f "$registry" ] || return 0
  secret="$(api_key_active_secrets "$registry" | head -n1)"
  [ -n "$secret" ] || return 0
  AUTH_CURL_ARGS=(-H "Authorization: Bearer $secret")
}

api_key_registry_write_atomic() {
  local file="$1"
  local content="$2"
  local tmp

  tmp="$(mktemp "${file}.XXXXXX")" || return 1
  if ! printf '%s\n' "$content" > "$tmp" || ! chmod 600 "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$file"
}

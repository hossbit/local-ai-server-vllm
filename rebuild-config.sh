#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2153
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
BIN_DIR="$AI_DIR/$LOCALVLLM_BIN_SUBDIR"
localvllm_capture_global_runtime

BACKEND_ARG="${LOCALVLLM_BACKEND:-$LOCALVLLM_DEFAULT_BACKEND}"
POSITIONAL=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --backend|-b)
      [ "$#" -ge 2 ] || { echo "Error: missing value for $1" >&2; exit 2; }
      BACKEND_ARG="$2"
      shift 2
      ;;
    --backend=*)
      BACKEND_ARG="${1#--backend=}"
      shift
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

if [ "${#POSITIONAL[@]}" -gt 2 ]; then
  echo "Usage: $0 [--backend vllm|omni] [SERVE_SH] [SERVE_ENV]" >&2
  exit 2
fi

localvllm_use_backend "$BACKEND_ARG" || exit 1

SERVE_SH="${POSITIONAL[0]:-$CONF_DIR/$LOCALVLLM_SERVE_SCRIPT}"
SERVE_ENV="${POSITIONAL[1]:-$CONF_DIR/$LOCALVLLM_SERVE_ENV_FILE}"

[ -n "$SERVE_SH" ] || { echo "Error: serve script path is empty." >&2; exit 1; }
[ -n "$SERVE_ENV" ] || { echo "Error: serve env path is empty." >&2; exit 1; }

mkdir -p "$CONF_DIR" "$MODELS_DIR" "$OVERRIDES_DIR"

if ! localvllm_resolve_active "$MODELS_DIR" "$ACTIVE_MODEL_FILE" "$OVERRIDES_DIR"; then
  exit 1
fi

# Global defaults. Environment exports of the short names are also honored so
# one-off generation can be tried without editing the installed config.
GLOBAL_TP="${TENSOR_PARALLEL_SIZE:-$VLLM_TENSOR_PARALLEL_SIZE}"
GLOBAL_UTIL="${GPU_MEMORY_UTILIZATION:-$VLLM_GPU_MEMORY_UTILIZATION}"
GLOBAL_MAX_LEN="${MAX_MODEL_LEN:-$VLLM_MAX_MODEL_LEN}"
GLOBAL_DTYPE="${DTYPE:-$VLLM_DTYPE}"
GLOBAL_QUANT="${QUANTIZATION:-$VLLM_QUANTIZATION}"
GLOBAL_MAX_SEQS="${MAX_NUM_SEQS:-$VLLM_MAX_NUM_SEQS}"
GLOBAL_MAX_BATCHED="${MAX_NUM_BATCHED_TOKENS:-$VLLM_MAX_NUM_BATCHED_TOKENS}"
GLOBAL_KV_DTYPE="${KV_CACHE_DTYPE:-$VLLM_KV_CACHE_DTYPE}"
GLOBAL_SWAP="${SWAP_SPACE:-$VLLM_SWAP_SPACE}"
GLOBAL_OFFLOAD="${CPU_OFFLOAD_GB:-$VLLM_CPU_OFFLOAD_GB}"
GLOBAL_EAGER="${ENFORCE_EAGER:-$VLLM_ENFORCE_EAGER}"
GLOBAL_TRUST="${TRUST_REMOTE_CODE:-$VLLM_TRUST_REMOTE_CODE}"
GLOBAL_NO_LOG="${DISABLE_LOG_REQUESTS:-$VLLM_DISABLE_LOG_REQUESTS}"
GLOBAL_SLEEP="${ENABLE_SLEEP:-$VLLM_ENABLE_SLEEP}"
GLOBAL_OMNI="${OMNI:-$VLLM_OMNI}"
GLOBAL_SERVED="${SERVED_MODEL_NAME:-$VLLM_SERVED_MODEL_NAME}"
GLOBAL_REVISION="${REVISION:-$VLLM_REVISION}"
GLOBAL_CODE_REVISION="${CODE_REVISION:-$VLLM_CODE_REVISION}"
GLOBAL_TOKENIZER_REVISION="${TOKENIZER_REVISION:-$VLLM_TOKENIZER_REVISION}"
GLOBAL_TOKENIZER="${TOKENIZER:-$VLLM_TOKENIZER}"
GLOBAL_LOAD_FORMAT="${LOAD_FORMAT:-$VLLM_LOAD_FORMAT}"
GLOBAL_CHAT_TEMPLATE="${CHAT_TEMPLATE:-$VLLM_CHAT_TEMPLATE}"
GLOBAL_REASONING_PARSER="${REASONING_PARSER:-$VLLM_REASONING_PARSER}"
GLOBAL_TOOL_PARSER="${TOOL_CALL_PARSER:-$VLLM_TOOL_CALL_PARSER}"
GLOBAL_TASK="${TASK:-}"
GLOBAL_EXTRA_ARGS="${EXTRA_ARGS:-$VLLM_EXTRA_ARGS}"
GLOBAL_EXTRA_ENV="${EXTRA_ENV:-$VLLM_EXTRA_ENV}"
GLOBAL_MODEL_TYPE="${MODEL_TYPE:-}"
GLOBAL_HF_TOKEN="${HF_TOKEN:-$LOCALVLLM_HF_TOKEN}"
GLOBAL_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-$LOCALVLLM_CUDA_VISIBLE_DEVICES}"

MODEL="$ACTIVE_MODEL"
FORMAT="$ACTIVE_FORMAT"

# Per-model override: conf/models.d/<model-id>.conf. Values here replace the
# global defaults for this model only.
if [ -n "$ACTIVE_OVERRIDE" ] && [ -f "$ACTIVE_OVERRIDE" ]; then
  set +u
  # shellcheck disable=SC1090
  . "$ACTIVE_OVERRIDE"
  set -u
fi

if [ ! -e "$MODEL" ] && [ -e "$MODELS_DIR/$MODEL" ]; then
  MODEL="$MODELS_DIR/$MODEL"
fi
if [ "$MODEL" != "$ACTIVE_MODEL" ]; then
  FORMAT="$(localvllm_detect_format "$MODEL")"
fi

TENSOR_PARALLEL_SIZE="${TENSOR_PARALLEL_SIZE:-$GLOBAL_TP}"
GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-$GLOBAL_UTIL}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-$GLOBAL_MAX_LEN}"
DTYPE="${DTYPE:-$GLOBAL_DTYPE}"
QUANTIZATION="${QUANTIZATION:-$GLOBAL_QUANT}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-$GLOBAL_MAX_SEQS}"
MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-$GLOBAL_MAX_BATCHED}"
KV_CACHE_DTYPE="${KV_CACHE_DTYPE:-$GLOBAL_KV_DTYPE}"
SWAP_SPACE="${SWAP_SPACE:-$GLOBAL_SWAP}"
CPU_OFFLOAD_GB="${CPU_OFFLOAD_GB:-$GLOBAL_OFFLOAD}"
ENFORCE_EAGER="${ENFORCE_EAGER:-$GLOBAL_EAGER}"
TRUST_REMOTE_CODE="${TRUST_REMOTE_CODE:-$GLOBAL_TRUST}"
DISABLE_LOG_REQUESTS="${DISABLE_LOG_REQUESTS:-$GLOBAL_NO_LOG}"
ENABLE_SLEEP="${ENABLE_SLEEP:-$GLOBAL_SLEEP}"
OMNI="${OMNI:-$GLOBAL_OMNI}"
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-$GLOBAL_SERVED}"
REVISION="${REVISION:-$GLOBAL_REVISION}"
CODE_REVISION="${CODE_REVISION:-$GLOBAL_CODE_REVISION}"
TOKENIZER_REVISION="${TOKENIZER_REVISION:-$GLOBAL_TOKENIZER_REVISION}"
TOKENIZER="${TOKENIZER:-$GLOBAL_TOKENIZER}"
LOAD_FORMAT="${LOAD_FORMAT:-$GLOBAL_LOAD_FORMAT}"
CHAT_TEMPLATE="${CHAT_TEMPLATE:-$GLOBAL_CHAT_TEMPLATE}"
REASONING_PARSER="${REASONING_PARSER:-$GLOBAL_REASONING_PARSER}"
TOOL_CALL_PARSER="${TOOL_CALL_PARSER:-$GLOBAL_TOOL_PARSER}"
TASK="${TASK:-$GLOBAL_TASK}"
MODEL_TYPE="${MODEL_TYPE:-$GLOBAL_MODEL_TYPE}"
HF_TOKEN="${HF_TOKEN:-$GLOBAL_HF_TOKEN}"
CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-$GLOBAL_VISIBLE_DEVICES}"

# EXTRA_ARGS and EXTRA_ENV are special: a models.d file may declare them as
# bash arrays (safe for values with spaces), while the global/string form is
# split on whitespace. Reset them explicitly so one model's array cannot leak
# into the next generation run.
if ! declare -p EXTRA_ARGS >/dev/null 2>&1; then
  EXTRA_ARGS="$GLOBAL_EXTRA_ARGS"
fi
if ! declare -p EXTRA_ENV >/dev/null 2>&1; then
  EXTRA_ENV="$GLOBAL_EXTRA_ENV"
fi

validate_bool() {
  local name="$1" value="$2"

  case "$value" in
    0|1) ;;
    *) echo "Error: $name must be 0 or 1." >&2; exit 1 ;;
  esac
}

validate_positive_int() {
  local name="$1" value="$2"

  if ! [[ "$value" =~ ^[0-9]+$ ]] || ((10#$value < 1)); then
    echo "Error: $name must be a positive integer." >&2
    exit 1
  fi
}

validate_optional_positive_int() {
  local name="$1" value="$2"

  [ -z "$value" ] && return 0
  validate_positive_int "$name" "$value"
}

validate_optional_nonnegative_int() {
  local name="$1" value="$2"

  [ -z "$value" ] && return 0
  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "Error: $name must be a non-negative integer." >&2
    exit 1
  fi
}

validate_float_0_1() {
  local name="$1" value="$2"

  if ! awk -v value="$value" 'BEGIN {
    if (value !~ /^[0-9]+([.][0-9]+)?$/) exit 1
    if ((value + 0) <= 0 || (value + 0) > 1) exit 1
    exit 0
  }'; then
    echo "Error: $name must be a number greater than 0 and at most 1 (for example 0.90)." >&2
    exit 1
  fi
}

validate_single_line() {
  local name="$1" value="$2"

  case "$value" in
    *$'\n'*|*$'\r'*)
      echo "Error: $name must not contain newlines." >&2
      exit 1
      ;;
  esac
}

validate_choice() {
  local name="$1" value="$2"
  shift 2
  local allowed

  for allowed in "$@"; do
    [ "$value" = "$allowed" ] && return 0
  done

  echo "Error: $name has an unsupported value: $value" >&2
  echo "Supported values: $*" >&2
  exit 1
}

[ -n "$MODEL" ] || { echo "Error: MODEL is empty." >&2; exit 1; }
validate_single_line MODEL "$MODEL"

if [ -z "$MODEL_TYPE" ]; then
  if [ "$ACTIVE_ID" = "default" ]; then
    MODEL_TYPE="$(localvllm_model_type "$(basename "$MODEL")" "")"
  else
    MODEL_TYPE="$(localvllm_model_type "$ACTIVE_ID" "$ACTIVE_OVERRIDE")"
  fi
fi
validate_choice MODEL_TYPE "$MODEL_TYPE" chat completion embedding reranking

if [ -z "$TASK" ]; then
  case "$MODEL_TYPE" in
    embedding) TASK=embed ;;
    reranking) TASK=score ;;
  esac
fi
if [ -n "$TASK" ]; then
  validate_choice TASK "$TASK" auto generate embedding embed classify score reward transcription
fi

validate_positive_int TENSOR_PARALLEL_SIZE "$TENSOR_PARALLEL_SIZE"
validate_float_0_1 GPU_MEMORY_UTILIZATION "$GPU_MEMORY_UTILIZATION"
validate_optional_positive_int MAX_MODEL_LEN "$MAX_MODEL_LEN"
validate_choice DTYPE "$DTYPE" auto half float16 bfloat16 float float32
if [ -n "$QUANTIZATION" ]; then
  if ! [[ "$QUANTIZATION" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "Error: QUANTIZATION must be empty or a simple name such as awq, gptq_marlin, or fp8." >&2
    exit 1
  fi
fi
validate_optional_positive_int MAX_NUM_SEQS "$MAX_NUM_SEQS"
validate_optional_positive_int MAX_NUM_BATCHED_TOKENS "$MAX_NUM_BATCHED_TOKENS"
validate_choice KV_CACHE_DTYPE "$KV_CACHE_DTYPE" auto fp8 fp8_e4m3 fp8_e5m2
validate_optional_nonnegative_int SWAP_SPACE "$SWAP_SPACE"
validate_optional_nonnegative_int CPU_OFFLOAD_GB "$CPU_OFFLOAD_GB"
validate_bool ENFORCE_EAGER "$ENFORCE_EAGER"
validate_bool TRUST_REMOTE_CODE "$TRUST_REMOTE_CODE"
validate_bool DISABLE_LOG_REQUESTS "$DISABLE_LOG_REQUESTS"
validate_bool ENABLE_SLEEP "$ENABLE_SLEEP"
validate_bool OMNI "$OMNI"
validate_single_line SERVED_MODEL_NAME "$SERVED_MODEL_NAME"
validate_single_line REVISION "$REVISION"
validate_single_line CODE_REVISION "$CODE_REVISION"
validate_single_line TOKENIZER_REVISION "$TOKENIZER_REVISION"
validate_single_line TOKENIZER "$TOKENIZER"
validate_single_line LOAD_FORMAT "$LOAD_FORMAT"
validate_single_line CHAT_TEMPLATE "$CHAT_TEMPLATE"
validate_single_line REASONING_PARSER "$REASONING_PARSER"
validate_single_line TOOL_CALL_PARSER "$TOOL_CALL_PARSER"
validate_single_line HF_TOKEN "$HF_TOKEN"
validate_single_line CUDA_VISIBLE_DEVICES "$CUDA_VISIBLE_DEVICES"

if [ -z "$SERVED_MODEL_NAME" ]; then
  if [ "$ACTIVE_ID" = "default" ]; then
    SERVED_MODEL_NAME="$(basename "$MODEL")"
  else
    SERVED_MODEL_NAME="$ACTIVE_ID"
  fi
fi

if [ "$OMNI" = "1" ] && ! vllm_omni_is_available "$VENV_DIR"; then
  echo "Error: OMNI=1 but vLLM-Omni is not installed in $VENV_DIR." >&2
  echo "Install it with: $BIN_DIR/install-localvllm.sh --backend omni" >&2
  echo "Or install the project from https://github.com/vllm-project/vllm-omni into the venv." >&2
  exit 1
fi

if [ "$FORMAT" = "gguf" ] && [ -z "$TOKENIZER" ]; then
  echo "Warning: GGUF model has no TOKENIZER override; vLLM will try to use GGUF metadata." >&2
fi

PORT="$LOCALVLLM_DEFAULT_PORT"
if [ -f "$PORT_FILE" ]; then
  PORT="$(<"$PORT_FILE")"
fi
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || ((10#$PORT < 1 || 10#$PORT > 65535)); then
  echo "Error: invalid port in $PORT_FILE: $PORT" >&2
  exit 1
fi

API_KEY_REGISTRY="$CONF_DIR/$LOCALVLLM_API_KEY_FILE"
REQUIRE_API_KEY="${LOCALVLLM_REQUIRE_API_KEY:-0}"
validate_bool REQUIRE_API_KEY "$REQUIRE_API_KEY"
if ! api_key_registry_validate "$API_KEY_REGISTRY"; then
  echo "Refusing to rebuild the launcher; $SERVE_SH was left unchanged." >&2
  exit 1
fi

ACTIVE_API_KEY_COUNT="$(api_key_active_count "$API_KEY_REGISTRY")"
if [ "$ACTIVE_API_KEY_COUNT" -gt 1 ]; then
  echo "Error: $ACTIVE_API_KEY_COUNT active API keys found, but vLLM supports one." >&2
  echo "Revoke extras with 'localvllm key revoke KEY_ID', then run localvllm reload." >&2
  exit 1
fi
if [ "$REQUIRE_API_KEY" = "1" ] && [ "$ACTIVE_API_KEY_COUNT" -eq 0 ]; then
  echo "Error: LOCALVLLM_REQUIRE_API_KEY=1 but no active API keys exist." >&2
  echo "Create one first: localvllm key create" >&2
  exit 1
fi
API_KEY="$(api_key_active_secrets "$API_KEY_REGISTRY" | head -n1)"

VLLM_BIN="$VENV_DIR/bin/vllm"
HF_HOME="${LOCALVLLM_HF_HOME:-$AI_DIR/$LOCALVLLM_HF_CACHE_SUBDIR}"

# Validate and normalize EXTRA_ARGS.
EXTRA_ITEMS=()
if [[ "$(declare -p EXTRA_ARGS 2>/dev/null)" == "declare -a"* ]]; then
  for EXTRA_ITEM in "${EXTRA_ARGS[@]}"; do
    [ -n "$EXTRA_ITEM" ] || continue
    validate_single_line EXTRA_ARGS "$EXTRA_ITEM"
    EXTRA_ITEMS+=("$EXTRA_ITEM")
  done
else
  if [ -n "$EXTRA_ARGS" ]; then
    read -r -a EXTRA_ITEMS <<< "$EXTRA_ARGS"
  fi
fi

ENV_ITEMS=()
if [[ "$(declare -p EXTRA_ENV 2>/dev/null)" == "declare -a"* ]]; then
  for ENV_ITEM in "${EXTRA_ENV[@]}"; do
    [ -n "$ENV_ITEM" ] || continue
    validate_single_line EXTRA_ENV "$ENV_ITEM"
    ENV_ITEMS+=("$ENV_ITEM")
  done
else
  if [ -n "$EXTRA_ENV" ]; then
    read -r -a ENV_ITEMS <<< "$EXTRA_ENV"
  fi
fi

for ENV_ITEM in "${ENV_ITEMS[@]}"; do
  if ! [[ "$ENV_ITEM" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
    echo "Error: EXTRA_ENV entries must look like KEY=VALUE: $ENV_ITEM" >&2
    exit 1
  fi
done

VLLM_ARGS=("$VLLM_BIN" serve "$MODEL" --host "$LOCALVLLM_LISTEN_HOST" --port "$PORT")
VLLM_ARGS+=(--served-model-name "$SERVED_MODEL_NAME")
VLLM_ARGS+=(--tensor-parallel-size "$TENSOR_PARALLEL_SIZE")
VLLM_ARGS+=(--gpu-memory-utilization "$GPU_MEMORY_UTILIZATION")
[ -z "$MAX_MODEL_LEN" ] || VLLM_ARGS+=(--max-model-len "$MAX_MODEL_LEN")
[ -z "$DTYPE" ] || VLLM_ARGS+=(--dtype "$DTYPE")
[ -z "$QUANTIZATION" ] || VLLM_ARGS+=(--quantization "$QUANTIZATION")
[ -z "$MAX_NUM_SEQS" ] || VLLM_ARGS+=(--max-num-seqs "$MAX_NUM_SEQS")
[ -z "$MAX_NUM_BATCHED_TOKENS" ] || VLLM_ARGS+=(--max-num-batched-tokens "$MAX_NUM_BATCHED_TOKENS")
[ -z "$KV_CACHE_DTYPE" ] || VLLM_ARGS+=(--kv-cache-dtype "$KV_CACHE_DTYPE")
[ -z "$SWAP_SPACE" ] || VLLM_ARGS+=(--swap-space "$SWAP_SPACE")
[ "${CPU_OFFLOAD_GB:-0}" = "0" ] || VLLM_ARGS+=(--cpu-offload-gb "$CPU_OFFLOAD_GB")
[ "$ENFORCE_EAGER" = "0" ] || VLLM_ARGS+=(--enforce-eager)
[ "$TRUST_REMOTE_CODE" = "0" ] || VLLM_ARGS+=(--trust-remote-code)
[ "$DISABLE_LOG_REQUESTS" = "0" ] || VLLM_ARGS+=(--disable-log-requests)
[ "$ENABLE_SLEEP" = "0" ] || VLLM_ARGS+=(--enable-sleep-mode)
[ -z "$TASK" ] || VLLM_ARGS+=(--task "$TASK")
[ -z "$REVISION" ] || VLLM_ARGS+=(--revision "$REVISION")
[ -z "$CODE_REVISION" ] || VLLM_ARGS+=(--code-revision "$CODE_REVISION")
[ -z "$TOKENIZER_REVISION" ] || VLLM_ARGS+=(--tokenizer-revision "$TOKENIZER_REVISION")
[ -z "$TOKENIZER" ] || VLLM_ARGS+=(--tokenizer "$TOKENIZER")
[ -z "$LOAD_FORMAT" ] || VLLM_ARGS+=(--load-format "$LOAD_FORMAT")
[ -z "$CHAT_TEMPLATE" ] || VLLM_ARGS+=(--chat-template "$CHAT_TEMPLATE")
[ -z "$REASONING_PARSER" ] || VLLM_ARGS+=(--reasoning-parser "$REASONING_PARSER")
[ -z "$TOOL_CALL_PARSER" ] || VLLM_ARGS+=(--tool-call-parser "$TOOL_CALL_PARSER")
[ "$OMNI" = "0" ] || VLLM_ARGS+=(--omni)
VLLM_ARGS+=("${EXTRA_ITEMS[@]}")

TMP_SH="$(mktemp "${SERVE_SH}.XXXXXX")"
TMP_ENV="$(mktemp "${SERVE_ENV}.XXXXXX")"
trap 'rm -f -- "$TMP_SH" "$TMP_ENV"' EXIT

{
  echo '#!/usr/bin/env bash'
  echo '# Generated by localvllm rebuild-config.sh. Do not edit directly.'
  printf '# Edit conf/localvllm.conf or conf/backends/%s/models.d/<model-id>.conf instead.\n' "$LOCALVLLM_BACKEND"
  echo 'set -euo pipefail'
  echo 'umask 077'
  printf 'export PATH=%q:$PATH\n' "$VENV_DIR/bin"
  printf 'export HF_HOME=%q\n' "$HF_HOME"
  [ -z "$HF_TOKEN" ] || printf 'export HF_TOKEN=%q\n' "$HF_TOKEN"
  [ -z "$CUDA_VISIBLE_DEVICES" ] || printf 'export CUDA_VISIBLE_DEVICES=%q\n' "$CUDA_VISIBLE_DEVICES"
  [ -z "$API_KEY" ] || printf 'export VLLM_API_KEY=%q\n' "$API_KEY"
  [ "$ENABLE_SLEEP" = "0" ] || echo 'export VLLM_SERVER_DEV_MODE=1'
  for ENV_ITEM in "${ENV_ITEMS[@]}"; do
    ENV_KEY="${ENV_ITEM%%=*}"
    ENV_VALUE="${ENV_ITEM#*=}"
    printf 'export %s=%q\n' "$ENV_KEY" "$ENV_VALUE"
  done
  printf 'exec '
  printf '%q ' "${VLLM_ARGS[@]}"
  printf '\n'
} > "$TMP_SH"

{
  printf 'LOCALVLLM_BACKEND=%q\n' "$LOCALVLLM_BACKEND"
  printf 'LOCALVLLM_ACTIVE_ID=%q\n' "$ACTIVE_ID"
  printf 'LOCALVLLM_MODEL=%q\n' "$MODEL"
  printf 'LOCALVLLM_FORMAT=%q\n' "$FORMAT"
  printf 'LOCALVLLM_MODEL_TYPE=%q\n' "$MODEL_TYPE"
  printf 'LOCALVLLM_SERVED_MODEL_NAME=%q\n' "$SERVED_MODEL_NAME"
  printf 'LOCALVLLM_PORT=%q\n' "$PORT"
  printf 'LOCALVLLM_OMNI=%q\n' "$OMNI"
  printf 'LOCALVLLM_API_KEY_ACTIVE=%q\n' "$([ "$ACTIVE_API_KEY_COUNT" -gt 0 ] && printf 1 || printf 0)"
  printf 'LOCALVLLM_ENABLE_SLEEP=%q\n' "$ENABLE_SLEEP"
} > "$TMP_ENV"

chmod 700 "$TMP_SH" 2>/dev/null || true
chmod 600 "$TMP_ENV" 2>/dev/null || true
mv -f -- "$TMP_SH" "$SERVE_SH"
mv -f -- "$TMP_ENV" "$SERVE_ENV"
trap - EXIT

if [ "$OMNI" = "1" ]; then
  OMNI_LABEL=", vLLM-Omni"
else
  OMNI_LABEL=""
fi
if [ "$ACTIVE_API_KEY_COUNT" -gt 0 ]; then
  echo "Generated $SERVE_SH for $LOCALVLLM_BACKEND: $ACTIVE_ID ($FORMAT), port $PORT$OMNI_LABEL, 1 active API key."
else
  echo "Generated $SERVE_SH for $LOCALVLLM_BACKEND: $ACTIVE_ID ($FORMAT), port $PORT$OMNI_LABEL."
fi

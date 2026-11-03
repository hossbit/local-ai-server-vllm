# shellcheck shell=bash disable=SC2154

localvllm_override_value() {
  local file="$1"
  local key="$2"

  [ -f "$file" ] || return 1

  (
    set +u
    unset SERVED_MODEL_NAME MODEL_TYPE CUDA_VISIBLE_DEVICES
    # shellcheck disable=SC1090
    . "$file" >/dev/null 2>&1 || exit 0
    case "$key" in
      SERVED_MODEL_NAME) printf '%s\n' "${SERVED_MODEL_NAME:-}" ;;
      CUDA_VISIBLE_DEVICES) [ "${CUDA_VISIBLE_DEVICES+x}" ] && printf '%s\n' "$CUDA_VISIBLE_DEVICES" ;;
      MODEL_TYPE) printf '%s\n' "${MODEL_TYPE:-}" ;;
    esac
  )
}

suggest_for_model() {
  local id="$1"
  local model="$2"
  local format="$3"
  local path="$4"
  local override="" model_bytes ram_bytes vram_bytes vram_free_bytes gpus
  local model_gib vram_gib usable_vram_gib tp gpu_util max_len max_seqs cpu_offload
  local gpu_mask_set="${CUDA_VISIBLE_DEVICES+x}"
  local CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES-${LOCALVLLM_CUDA_VISIBLE_DEVICES:-}}"
  local selected_devices
  # Leave an unspecified mask unset so NVIDIA can enumerate all devices.
  if [ -z "$CUDA_VISIBLE_DEVICES" ] && [ -z "$gpu_mask_set" ]; then
    unset CUDA_VISIBLE_DEVICES
  fi

  override="$(localvllm_override_file_for_id "$OVERRIDES_DIR" "$id" 2>/dev/null || true)"
  if selected_devices="$(localvllm_override_value "$override" CUDA_VISIBLE_DEVICES)"; then
    CUDA_VISIBLE_DEVICES="$selected_devices"
  fi
  model_bytes="$(localvllm_model_size_bytes "$path")"
  ram_bytes="$(system_ram_bytes)"
  vram_bytes="$(gpu_vram_total_min_bytes)"
  vram_free_bytes="$(gpu_vram_free_min_bytes)"
  gpus="$(gpu_count)"

  echo
  echo "$id"
  echo "  model: $model"
  echo "  source: $( [ "$format" = "remote" ] && printf 'Hugging Face repo id' || printf 'local files' )"
  echo "  format: $format"
  echo "  type: $(localvllm_model_type "$id" "$override")"
  echo "  override file: ${override:-$OVERRIDES_DIR/$(localvllm_safe_id "$id").conf}"

  if [ "$model_bytes" -le 0 ]; then
    echo "  model size: unavailable (remote model id)"
    echo
    echo "  Remote models are downloaded on first start, so size-specific advice"
    echo "  is unavailable yet. Starting points:"
    echo "    TENSOR_PARALLEL_SIZE=1"
    echo "    GPU_MEMORY_UTILIZATION=0.90"
    echo "    MAX_MODEL_LEN=8192"
    echo "    MAX_NUM_SEQS=256"
    echo
    echo "  Download it first for hardware-specific advice:"
    echo "    hf download '$model'"
    echo "  then point MODEL at the downloaded directory and run suggest again."
    return 0
  fi

  model_gib="$(awk -v b="$model_bytes" 'BEGIN { printf "%.2f", b / 1024 / 1024 / 1024 }')"
  echo "  model size: $(format_bytes_gib "$model_bytes")"
  [ "$ram_bytes" -gt 0 ] && echo "  system RAM: $(format_bytes_gib "$ram_bytes")"

  if [ "$vram_bytes" -le 0 ]; then
    echo "  detected VRAM: unavailable"
    echo
    echo "  vLLM needs a supported GPU. Confirm nvidia-smi works, then rerun."
    echo "  Conservative defaults: TP=1, GPU_MEMORY_UTILIZATION=0.90, MAX_MODEL_LEN=8192."
    return 0
  fi

  vram_gib="$(awk -v b="$vram_bytes" 'BEGIN { printf "%.2f", b / 1024 / 1024 / 1024 }')"
  if [ "$vram_free_bytes" -gt 0 ]; then
    echo "  detected VRAM: $(format_bytes_gib "$vram_bytes") total, $(format_bytes_gib "$vram_free_bytes") free per GPU ($gpus GPU(s), using the smallest device)"
    usable_vram_gib="$(awk -v b="$vram_free_bytes" 'BEGIN { printf "%.2f", b / 1024 / 1024 / 1024 }')"
  else
    echo "  detected VRAM: $(format_bytes_gib "$vram_bytes") per GPU ($gpus GPU(s), free VRAM unavailable)"
    usable_vram_gib="$vram_gib"
  fi

  IFS=$'\t' read -r tp gpu_util max_len max_seqs cpu_offload < <(
    awk -v m="$model_gib" -v v="$usable_vram_gib" -v g="$gpus" 'BEGIN {
      if (g < 1) g = 1
      tp = int(m * 1.10 / v)
      if (tp * v < m * 1.10) tp++
      if (tp < 1) tp = 1
      if (tp > g) tp = g
      total = v * tp
      headroom = total - m

      if (headroom > 24) {
        ctx = 32768
        seqs = 256
      } else if (headroom > 12) {
        ctx = 16384
        seqs = 256
      } else if (headroom > 6) {
        ctx = 8192
        seqs = 128
      } else {
        ctx = 4096
        seqs = 64
      }

      util = 0.90
      if (m > total * 0.80) util = 0.95

      offload = m - total * util
      if (offload < 0) offload = 0
      printf "%.0f\t%.2f\t%d\t%d\t%.0f\n", tp, util, ctx, seqs, offload
    }'
  )

  echo "  suggested TENSOR_PARALLEL_SIZE: $tp"
  echo "  suggested GPU_MEMORY_UTILIZATION: $gpu_util"
  echo "  suggested MAX_MODEL_LEN: $max_len"
  echo "  suggested MAX_NUM_SEQS: $max_seqs"
  echo "  suggested CPU_OFFLOAD_GB: $cpu_offload"
  echo "  suggested KV_CACHE_DTYPE: auto (fp8 can halve KV-cache memory on supported GPUs)"

  if [ "$vram_free_bytes" -gt 0 ] && [ "$vram_bytes" -gt 0 ] &&
    [ "$vram_free_bytes" -lt $((vram_bytes * 85 / 100)) ]; then
    echo "  note: free VRAM is much lower than total VRAM; another process or the other backend is using the GPU."
  fi
  if [ "$tp" -gt 1 ]; then
    echo "  placement: use $tp GPUs; set CUDA_VISIBLE_DEVICES or LOCALVLLM_CUDA_VISIBLE_DEVICES if needed."
  fi
  if [ "$cpu_offload" -gt 0 ]; then
    echo "  placement: the model needs about ${cpu_offload} GiB of CPU offload to fit. Expect slower generation."
  fi
  if [ "$format" = "gguf" ]; then
    echo "  warning: vLLM GGUF support is experimental; set TOKENIZER if vLLM cannot infer one."
  fi
  if [ "$ram_bytes" -gt 0 ] && [ "$model_bytes" -gt $((ram_bytes * 85 / 100)) ]; then
    echo "  warning: model files are close to or larger than available RAM; expect failure or very slow loading."
  elif [ "$ram_bytes" -gt 0 ] && [ "$model_bytes" -gt $((ram_bytes * 60 / 100)) ]; then
    echo "  warning: large model for this machine; keep MAX_MODEL_LEN and MAX_NUM_SEQS low."
  fi

  echo
  echo "  Apply: edit the override file, then run 'localvllm reload'."
  echo "  Measure the current configuration: localvllm suggest --benchmark '$id'"
}

suggest_cmd() {
  if [ "${1:-}" = "--benchmark" ]; then
    shift
    benchmark_cmd "$@"
    return $?
  fi
  if [ "${1:-}" = "--help" ]; then
    echo "Usage: localvllm suggest [MODEL]"
    echo "       localvllm suggest --benchmark MODEL [--type auto|chat|completion|embedding|reranking]"
    echo "               [--runs 1..10] [--tokens 1..4096] [--prompt-file FILE] [--json]"
    echo "Benchmarks the running service with one warm-up and repeated requests."
    echo "Settings are not changed. Use --prompt-file for your own text workload."
    return 0
  fi

  local target="${1:-}" id model format path matched=0 detected_gpus

  [ "$#" -le 1 ] || fail "usage: localvllm suggest [MODEL]"
  if [ ! -d "$MODELS_DIR" ]; then
    echo "Models directory does not exist: $MODELS_DIR"
    return 0
  fi

  echo "Backend: $LOCALVLLM_BACKEND_LABEL ($LOCALVLLM_BACKEND)  models: $MODELS_DIR"
  echo "Suggestions are advisory; memory checks use model file size plus rough RAM/VRAM heuristics."
  echo "Set settings in conf/backends/$LOCALVLLM_BACKEND/models.d/<model-id>.conf, then run 'localvllm reload'."
  detected_gpus="$(gpu_count)"
  if [ "$detected_gpus" -gt 1 ]; then
    echo "Detected $detected_gpus GPUs. Tune placement with TENSOR_PARALLEL_SIZE and LOCALVLLM_CUDA_VISIBLE_DEVICES."
  fi

  while IFS=$'\t' read -r id _source model format path; do
    [ -n "$id" ] || continue
    if [ -n "$target" ] && [ "$id" != "$target" ] && [ "$model" != "$target" ]; then
      continue
    fi
    matched=1
    suggest_for_model "$id" "$model" "$format" "$path"
  done < <(localvllm_model_entries "$MODELS_DIR" "$OVERRIDES_DIR")

  if [ "$matched" -eq 0 ]; then
    if [ -n "$target" ]; then
      fail "model not found: $target"
    fi
    echo "No models found in $MODELS_DIR"
  fi
}

benchmark_cmd() (
  local wanted="${1:-}" runs=3 tokens=128 json=0 value result elapsed metrics
  local type=auto prompt_file="" prompt="Write a detailed numbered list of practical tips for testing software. Keep going until you have at least twenty tips."
  local run_index=0 tmp samples summary embedding=0 entry_id="" entry_model=""
  local override="" served_name="" override_type="" endpoint=""

  [ -n "$wanted" ] || fail "usage: localvllm suggest --benchmark MODEL [--runs N] [--tokens N] [--type TYPE] [--json]"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --runs|--tokens)
        [ "$#" -ge 2 ] || fail "missing value for $1"
        value="$2"
        if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "${#value}" -gt 4 ]; then
          fail "invalid value for $1"
        fi
        value=$((10#$value))
        [ "$value" -ge 1 ] || fail "$1 must be positive"
        if [ "$1" = --runs ]; then
          [ "$value" -le 10 ] || fail "--runs must be at most 10"
          runs="$value"
        else
          [ "$value" -le 4096 ] || fail "--tokens must be at most 4096"
          tokens="$value"
        fi
        shift 2
        ;;
      --json)
        json=1
        shift
        ;;
      --type)
        [ "$#" -ge 2 ] || fail "missing value for --type"
        case "$2" in
          auto|chat|completion|embedding|reranking) type="$2" ;;
          *) fail "invalid benchmark type: $2" ;;
        esac
        shift 2
        ;;
      --prompt-file)
        if [ "$#" -lt 2 ] || [ ! -f "$2" ] || [ ! -r "$2" ]; then
          fail "--prompt-file needs a readable file"
        fi
        prompt_file="$2"
        shift 2
        ;;
      *)
        fail "unknown benchmark option: $1"
        ;;
    esac
  done

  if ! command -v curl >/dev/null || ! command -v jq >/dev/null; then
    fail "curl and jq are required for benchmarking"
  fi

  while IFS=$'\t' read -r entry_id entry_model _ _; do
    [ -n "$entry_id" ] || continue
    if [ "$wanted" = "$entry_id" ] || [ "$wanted" = "$entry_model" ]; then
      break
    fi
  done < <(localvllm_model_entries "$MODELS_DIR" "$OVERRIDES_DIR")

  [ -n "$entry_id" ] || fail "model not found: $wanted"
  [ "$wanted" = "$entry_id" ] || [ "$wanted" = "$entry_model" ] || fail "model not found: $wanted"

  local running_model
  running_model="$(serve_env_value LOCALVLLM_ACTIVE_ID)"
  if [ -n "$running_model" ] && [ "$running_model" != "$entry_id" ]; then
    fail "the service is configured for '$running_model', not '$entry_id'; run 'localvllm use $entry_id' first"
  fi

  override="$(localvllm_override_file_for_id "$OVERRIDES_DIR" "$entry_id" 2>/dev/null || true)"
  if [ "$type" = auto ]; then
    override_type="$(localvllm_override_value "$override" MODEL_TYPE || true)"
    if [ -n "$override_type" ]; then
      type="$override_type"
    else
      type="$(localvllm_model_type "$entry_id" "$override")"
    fi
  fi

  served_name="$(localvllm_override_value "$override" SERVED_MODEL_NAME || true)"
  [ -n "$served_name" ] || served_name="$entry_id"

  [ "$type" != embedding ] || embedding=1
  if [ -n "$prompt_file" ]; then
    prompt="$(<"$prompt_file")"
  fi

  tmp="$(mktemp -d)" || exit 1
  trap 'rm -rf -- "$tmp"' EXIT
  samples="$tmp/samples.jsonl"
  : > "$samples"

  if [ "$embedding" -eq 1 ]; then
    [ -n "$prompt_file" ] || prompt="Local search benchmark input."
    endpoint=embeddings
    payload="$(jq -nc --arg model "$served_name" --arg prompt "$prompt" '{model:$model,input:$prompt}')"
  elif [ "$type" = reranking ]; then
    endpoint=rerank
    payload="$(jq -nc --arg model "$served_name" --arg prompt "$prompt" '{model:$model,query:"software testing",documents:[$prompt,"A recipe for bread."],top_n:2}')"
  elif [ "$type" = completion ]; then
    endpoint=completions
    payload="$(jq -nc --arg model "$served_name" --arg prompt "$prompt" --argjson tokens "$tokens" '{model:$model,prompt:$prompt,max_tokens:$tokens,temperature:0,seed:42}')"
  else
    endpoint=chat/completions
    payload="$(jq -nc --arg model "$served_name" --arg prompt "$prompt" --argjson tokens "$tokens" '{model:$model,messages:[{role:"user",content:$prompt}],max_tokens:$tokens,temperature:0,seed:42,stream:false}')"
  fi

  api_auth_curl_args
  echo "Benchmarking $entry_id (served as $served_name): warm-up plus $runs measured request(s)." >&2
  echo "This measures the running service; it does not change model settings." >&2

  for ((run_index = 0; run_index <= runs; run_index++)); do
    result="$tmp/response.json"
    if ! elapsed="$(curl "${AUTH_CURL_ARGS[@]}" --connect-timeout 10 --max-time 600 -fsS \
      -H 'Content-Type: application/json' --data "$payload" -o "$result" -w '%{time_total}' \
      "$(api_base_url)/v1/$endpoint")"; then
      fail "benchmark request failed; check localvllm logs"
    fi

    if [ "$embedding" -eq 1 ]; then
      jq -e '.data | length > 0' "$result" >/dev/null || fail "invalid embedding response"
    elif [ "$type" = reranking ]; then
      jq -e '(.results // .data) | length > 0' "$result" >/dev/null || fail "invalid reranking response"
    else
      jq -e '(.usage.completion_tokens // 0) > 0 and (.choices | length > 0)' "$result" >/dev/null || fail "invalid completion response"
    fi

    [ "$run_index" -gt 0 ] || continue
    metrics="$(jq -c --argjson seconds "$elapsed" --argjson run "$run_index" '{
      run: $run,
      wall_seconds: $seconds,
      prompt_tokens: (.usage.prompt_tokens // null),
      completion_tokens: (.usage.completion_tokens // null),
      total_tokens: (.usage.total_tokens // null),
      prompt_tokens_per_second: (if (.usage.prompt_tokens // 0) > 0 then ((.usage.prompt_tokens / $seconds) * 100 | round / 100) else null end),
      generation_tokens_per_second: (if (.usage.completion_tokens // 0) > 0 then ((.usage.completion_tokens / $seconds) * 100 | round / 100) else null end)
    }' "$result")"
    printf '%s\n' "$metrics" >> "$samples"
    echo "  request $run_index/$runs: ${elapsed}s" >&2
  done

  summary="$(jq -sc --arg model "$entry_id" --arg served "$served_name" --arg type "$type" '
    def median: sort | if length == 0 then null else . as $a | length as $n | if $n % 2 == 1 then $a[($n/2|floor)] else ($a[$n/2-1]+$a[$n/2])/2 end end;
    {
      model: $model,
      served_model_name: $served,
      type: $type,
      runs: length,
      median_wall_seconds: (map(.wall_seconds) | median),
      median_generation_tokens_per_second: (map(.generation_tokens_per_second) | map(select(. != null)) | median),
      median_prompt_tokens_per_second: (map(.prompt_tokens_per_second) | map(select(. != null)) | median),
      samples: .
    }
  ' "$samples")"

  if [ "$json" -eq 1 ]; then
    printf '%s\n' "$summary"
  else
    jq -r '"Model: \(.model) (served as \(.served_model_name), \(.type))\nMeasured requests: \(.runs)\nMedian request time: \(.median_wall_seconds) seconds\nMedian generation: \(.median_generation_tokens_per_second // "unavailable") tokens/s\nMedian prompt processing: \(.median_prompt_tokens_per_second // "unavailable") tokens/s"' <<<"$summary"
    echo "Compare identical workloads and settings. This is a short speed test, not a model quality or maximum-context test."
  fi
)

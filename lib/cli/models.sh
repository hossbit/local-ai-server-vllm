# shellcheck shell=bash disable=SC2034,SC2153,SC2154

models_cmd() {
  local active_id="" served="" use_color_flag=0 selector json=0 paths=0
  local -a col_model=() col_source=() col_format=() col_type=() col_size=() col_active=()
  local -a positional=()
  local w_model=5 w_source=6 w_format=6 w_type=4 w_size=4 w_active=6
  local id source model format path size_display active_display i model_type arg
  local service_state="not installed" entries

  for arg in "$@"; do
    case "$arg" in
      --json) json=1 ;;
      --paths) paths=1 ;;
      -*) fail "usage: localvllm models [--json|--paths] [BACKEND]" ;;
      *) positional+=("$arg") ;;
    esac
  done
  [ "${#positional[@]}" -le 1 ] || fail "usage: localvllm models [--json|--paths] [BACKEND]"
  if [ "${#positional[@]}" -eq 1 ]; then
    selector="$(localvllm_resolve_selector "${positional[0]}")" || return 1
    [ "$selector" != "all" ] || fail "choose one backend: localvllm models vllm | localvllm models omni"
    localvllm_use_backend "$selector" || return 1
  fi

  if localvllm_resolve_active "$MODELS_DIR" "$ACTIVE_MODEL_FILE" "$OVERRIDES_DIR" 2>/dev/null; then
    active_id="$ACTIVE_ID"
  fi
  if service_is_active; then
    service_state="running"
  elif has_user_service; then
    service_state="stopped"
  fi

  entries="$(localvllm_model_entries "$MODELS_DIR" "$OVERRIDES_DIR" 2>/dev/null)"

  if [ "$json" -eq 1 ]; then
    command -v jq >/dev/null 2>&1 || fail "jq is required for --json output"
    if [ "$service_state" = "running" ] && command -v curl >/dev/null 2>&1; then
      served="$(api_models 2>/dev/null | head -n1 || true)"
    fi
    printf '%s\n' "$entries" | jq -R -s \
      --arg backend "$LOCALVLLM_BACKEND" \
      --arg label "$LOCALVLLM_BACKEND_LABEL" \
      --arg dir "$MODELS_DIR" \
      --arg cache "${LOCALVLLM_HF_HOME:-$AI_DIR/$LOCALVLLM_HF_CACHE_SUBDIR}" \
      --arg active "$active_id" \
      --arg service "$service_state" \
      --arg served "$served" '
        split("\n")
        | map(select(length > 0) | split("\t") | {
            id: .[0], source: .[1], model: .[2], format: .[3], path: .[4],
            active: (.[0] == $active)
          })
        | {backend: $backend, label: $label, models_dir: $dir, cache_dir: $cache,
           active_model: $active, service: $service,
           served_model: $served, models: .}
      '
    return 0
  fi

  echo "Backend: $LOCALVLLM_BACKEND_LABEL ($LOCALVLLM_BACKEND)"
  echo "Your model folders: $MODELS_DIR"
  echo "Shared download cache: ${LOCALVLLM_HF_HOME:-$AI_DIR/$LOCALVLLM_HF_CACHE_SUBDIR}"
  echo "Add your own: copy or link a complete model folder here, then run localvllm --backend $LOCALVLLM_BACKEND use FOLDER_NAME"
  echo "Or use an existing folder: localvllm --backend $LOCALVLLM_BACKEND use /path/to/model"
  echo

  if [ ! -d "$MODELS_DIR" ]; then
    echo "Models directory does not exist: $MODELS_DIR"
    return 0
  fi

  if ! localvllm_has_model_entries "$MODELS_DIR" "$OVERRIDES_DIR"; then
    echo "No models found in $MODELS_DIR"
    echo "Add a Hugging Face model directory, or run: localvllm use org/model"
    return 0
  fi

  [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && use_color_flag=1

  while IFS=$'\t' read -r id source model format path; do
    [ -n "$id" ] || continue

    model_type="$(localvllm_model_type "$id" "$(localvllm_override_file_for_id "$OVERRIDES_DIR" "$id" 2>/dev/null || true)")"
    size_display="-"
    if [ -e "$path" ]; then
      size_display="$(format_bytes_gib "$(localvllm_model_size_bytes "$path")")"
    fi

    if [ "$id" = "$active_id" ]; then
      active_display="yes"
    else
      active_display=""
    fi

    col_model+=("$id")
    col_source+=("$source")
    col_format+=("$format")
    col_size+=("$size_display")
    col_active+=("$active_display")
    col_type+=("$model_type")
    if [ "$paths" = 1 ]; then
      echo "$id"
      echo "  model: $model"
      if [ -e "$path" ]; then
        echo "  files: $path"
        [ ! -L "$path" ] || echo "  cache target: $(readlink -f "$path")"
      else
        echo "  files: downloads to the shared cache on first start"
      fi
    fi

    [ "${#id}" -le "$w_model" ] || w_model="${#id}"
    [ "${#source}" -le "$w_source" ] || w_source="${#source}"
    [ "${#format}" -le "$w_format" ] || w_format="${#format}"
    [ "${#model_type}" -le "$w_type" ] || w_type="${#model_type}"
    [ "${#size_display}" -le "$w_size" ] || w_size="${#size_display}"
    [ "${#active_display}" -le "$w_active" ] || w_active="${#active_display}"
  done < <(localvllm_model_entries "$MODELS_DIR" "$OVERRIDES_DIR")

  printf "%-${w_model}s  %-${w_source}s  %-${w_format}s  %-${w_type}s  %-${w_size}s  %s\n" \
    "MODEL" "SOURCE" "FORMAT" "TYPE" "SIZE" "ACTIVE"
  printf "%-${w_model}s  %-${w_source}s  %-${w_format}s  %-${w_type}s  %-${w_size}s  %s\n" \
    "-----" "------" "------" "----" "----" "------"

  for ((i = 0; i < ${#col_model[@]}; i++)); do
    active_display="$(printf "%-${w_active}s" "${col_active[i]}")"
    if [ "$use_color_flag" -eq 1 ] && [ "${col_active[i]}" = "yes" ]; then
      active_display=$'\033[32m'"$active_display"$'\033[0m'
    fi
    printf "%-${w_model}s  %-${w_source}s  %-${w_format}s  %-${w_type}s  %-${w_size}s  %s\n" \
      "${col_model[i]}" "${col_source[i]}" "${col_format[i]}" "${col_type[i]}" \
      "${col_size[i]}" "$active_display"
  done

  echo
  if [ -n "$active_id" ]; then
    echo "Active model: $active_id"
    if [ -n "$ACTIVE_OVERRIDE" ]; then
      echo "Override file: $ACTIVE_OVERRIDE"
    fi
  else
    echo "No active model selected. Run: localvllm use MODEL"
  fi

  if service_is_active; then
    echo "Service: running${served:+ (serving $served)}"
  else
    echo "Service: not running"
  fi
}

api_models() {
  api_auth_curl_args
  curl "${AUTH_CURL_ARGS[@]}" --max-time 10 -fsS "$(api_base_url)/v1/models" | jq -r '.data[]?.id'
}

model_is_embedding() {
  [ "$(localvllm_model_type "$1" "$2")" = embedding ]
}

apply_active_model_change() {
  local new_id="$1"
  local backup_dir was_active=0 status=0
  local file

  backup_dir="$(mktemp -d "${TMPDIR:-/tmp}/localvllm-use.XXXXXX")" ||
    fail "could not create a temporary rollback directory"

  service_is_active && was_active=1
  for file in "$ACTIVE_MODEL_FILE" "$SERVE_SH" "$SERVE_ENV"; do
    [ -f "$file" ] && cp -a "$file" "$backup_dir/$(basename "$file")"
  done

  if ! localvllm_write_active "$ACTIVE_MODEL_FILE" "$new_id"; then
    rm -rf "$backup_dir"
    echo "Error: failed to save the active model." >&2
    return 1
  fi

  if ! apply_config_change; then
    status=1
    if [ -f "$backup_dir/$(basename "$ACTIVE_MODEL_FILE")" ]; then
      cp -a "$backup_dir/$(basename "$ACTIVE_MODEL_FILE")" "$ACTIVE_MODEL_FILE"
    else
      rm -f "$ACTIVE_MODEL_FILE"
    fi
    if [ -f "$backup_dir/$(basename "$SERVE_SH")" ]; then
      cp -a "$backup_dir/$(basename "$SERVE_SH")" "$SERVE_SH"
    else
      rm -f "$SERVE_SH"
    fi
    if [ -f "$backup_dir/$(basename "$SERVE_ENV")" ]; then
      cp -a "$backup_dir/$(basename "$SERVE_ENV")" "$SERVE_ENV"
    else
      rm -f "$SERVE_ENV"
    fi
    if [ "$was_active" -eq 1 ]; then
      service_cmd restart || echo "Warning: could not restart the previous model." >&2
    fi
    echo "Error: active model was not changed; the previous model and launcher were restored." >&2
  fi

  rm -rf "$backup_dir"
  return "$status"
}

use_cmd() {
  local target="${1:-}" id="" spec="" entry_source="" format="" override="" candidate="" real=""
  local meta existing_model existing_override

  [ -n "$target" ] || fail "usage: localvllm use MODEL"
  [ "$#" -eq 1 ] || fail "usage: localvllm use MODEL"

  if localvllm_find_entry "$MODELS_DIR" "$target" "$OVERRIDES_DIR" >/dev/null 2>&1; then
    while IFS=$'\t' read -r id entry_source spec format _; do
      [ -n "$id" ] && break
    done < <(localvllm_find_entry "$MODELS_DIR" "$target" "$OVERRIDES_DIR")
  else
    candidate="$(expand_path "$target")"
    if [ -e "$candidate" ]; then
      if command -v realpath >/dev/null 2>&1; then
        real="$(realpath "$candidate")"
      else
        real="$(cd "$(dirname "$candidate")" && pwd)/$(basename "$candidate")"
      fi
      spec="$real"
      id="$(basename "$real")"
      format="$(localvllm_detect_format "$spec")"
    elif [[ "$target" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
      spec="$target"
      id="$target"
      format="remote"
    else
      fail "model not found: $target (not a local path, configured model, or Hugging Face repo id)"
    fi

    case "$format" in
      unknown)
        fail "$spec is not a Hugging Face model directory (missing config.json) or a .gguf file"
        ;;
      gguf)
        echo "Warning: vLLM GGUF support is experimental. Set TOKENIZER in the model override if vLLM cannot infer one." >&2
        ;;
    esac

    existing_override="$(localvllm_override_file_for_id "$OVERRIDES_DIR" "$id" 2>/dev/null || true)"
    if [ -n "$existing_override" ]; then
      meta="$(localvllm_override_meta "$existing_override")" || true
      IFS=$'\t' read -r existing_id existing_model existing_format <<<"$meta"
      [ -n "$existing_id" ] || existing_id="$id"
      if [ "$existing_model" != "$spec" ]; then
        fail "model id '$id' already exists with a different MODEL in $existing_override; edit or remove that file first"
      fi
      override="$existing_override"
    else
      mkdir -p "$OVERRIDES_DIR"
      override="$OVERRIDES_DIR/$(localvllm_safe_id "$id").conf"
      {
        printf '# Created by localvllm use on %s.\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'ID=%q\n' "$id"
        printf 'MODEL=%q\n' "$spec"
        [ "$format" = "gguf" ] && printf 'FORMAT=%q\n' gguf
      } > "$override"
      chmod 600 "$override" 2>/dev/null || true
      echo "Created model override: $override"
    fi
  fi

  echo "Backend: $LOCALVLLM_BACKEND_LABEL ($LOCALVLLM_BACKEND)"
  echo "Active model: $id"
  echo "Model: $spec"
  [ -n "$entry_source" ] && echo "Source: $entry_source"
  [ -n "$override" ] && echo "Override file: $override"
  [ "$format" = "gguf" ] && echo "Format: gguf (experimental in vLLM)"

  apply_active_model_change "$id"
}

backend_sleep_enabled() {
  [ "$(serve_env_value LOCALVLLM_ENABLE_SLEEP)" = "1" ]
}

vllm_is_sleeping() {
  local base response
  base="$(api_base_url)"
  api_auth_curl_args
  response="$(curl "${AUTH_CURL_ARGS[@]}" --max-time 5 -fsS "$base/is_sleeping" 2>/dev/null || true)"
  if [ -z "$response" ]; then
    printf 'unknown\n'
    return 0
  fi
  jq -r '.is_sleeping // "unknown"' <<<"$response" 2>/dev/null || printf 'unknown\n'
}

load_cmd() {
  local target="${1:-}"
  local base

  [ "$#" -le 1 ] || fail "usage: localvllm load [MODEL]"

  if [ "$target" = "all" ]; then
    fail "vLLM serves one model per server; use 'localvllm use MODEL' instead of 'load all'"
  fi

  if [ -n "$target" ]; then
    use_cmd "$target"
  elif ! service_is_active; then
    localvllm_resolve_active "$MODELS_DIR" "$ACTIVE_MODEL_FILE" "$OVERRIDES_DIR" ||
      fail "no active model is selected"
  fi

  if service_is_active; then
    if backend_sleep_enabled; then
      base="$(api_base_url)"
      api_auth_curl_args
      echo "Waking Local $LOCALVLLM_BACKEND_LABEL if it is sleeping..."
      if curl "${AUTH_CURL_ARGS[@]}" --max-time 300 -fsS -X POST "$base/wake_up" >/dev/null 2>&1; then
        echo "Local $LOCALVLLM_BACKEND_LABEL is awake."
        return 0
      fi
    fi
    echo "Local $LOCALVLLM_BACKEND_LABEL is already running."
    return 0
  fi

  service_cmd start
}

unload_cmd() {
  local base

  [ "$#" -eq 0 ] || fail "usage: localvllm unload"

  if ! service_is_active; then
    echo "Local $LOCALVLLM_BACKEND_LABEL is not running."
    return 0
  fi

  if backend_sleep_enabled && [ "$(vllm_is_sleeping)" != "true" ]; then
    base="$(api_base_url)"
    api_auth_curl_args
    echo "Putting Local $LOCALVLLM_BACKEND_LABEL to sleep (sleep mode keeps the process, releases GPU memory)..."
    if curl "${AUTH_CURL_ARGS[@]}" --max-time 300 -fsS -X POST "$base/sleep?level=1" >/dev/null 2>&1; then
      echo "Model is sleeping. Run 'localvllm load' to wake it, or 'localvllm stop' to stop the service."
      return 0
    fi
    echo "Warning: sleep endpoint failed; falling back to stopping the service." >&2
  elif backend_sleep_enabled; then
    echo "Local $LOCALVLLM_BACKEND_LABEL is already sleeping."
    return 0
  fi

  echo "Stopping vLLM releases its GPU memory."
  service_cmd stop
}

ui_usage() {
  cat <<'HELP'
Usage: localvllm ui [--open] [--docs|--api|--models]

  --docs       vLLM OpenAPI documentation (default)
  --api        OpenAI-compatible API base URL
  --models     Model listing endpoint
  --open       Open the destination in this Linux desktop's browser
  -h, --help   Show this help

vLLM does not ship a chat UI. Connect Open WebUI, LibreChat, or another
OpenAI-compatible client to the printed /v1 base URL.

Examples:
  localvllm ui
  localvllm ui --docs --open
HELP
}

ui_cmd() {
  local target="docs" open_browser=0 base url registry

  if [ "$#" -eq 1 ] && { [ "$1" = --help ] || [ "$1" = -h ]; }; then
    ui_usage
    return 0
  fi

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --open) open_browser=1 ;;
      --docs|--api|--models) target="${1#--}" ;;
      -*) fail "usage: localvllm ui [--open] [--docs|--api|--models]" ;;
      *) fail "usage: localvllm ui [--open] [--docs|--api|--models]" ;;
    esac
    shift
  done

  base="$(api_base_url)"
  echo "Backend: $LOCALVLLM_BACKEND_LABEL ($LOCALVLLM_BACKEND)"
  case "$target" in
    docs)
      url="$base/docs"
      echo "vLLM API documentation:"
      ;;
    api)
      url="$base/v1"
      echo "OpenAI-compatible API base URL:"
      ;;
    models)
      url="$base/v1/models"
      echo "Model listing endpoint:"
      ;;
  esac
  echo "  $url"
  echo
  echo "OpenAI base URL: $base/v1"
  echo "vLLM has no built-in chat UI; point Open WebUI or another client at the base URL above."

  registry="$(api_key_registry_path)"
  if [ -f "$registry" ] && [ -n "$(api_key_active_secrets "$registry" | head -n1)" ]; then
    echo
    echo "API-key auth is enabled. Use your saved key as a Bearer token."
  fi

  if [ "$open_browser" -eq 1 ]; then
    if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
      fail "no graphical desktop detected; open the URL above in your browser"
    fi
    command -v xdg-open >/dev/null 2>&1 || fail "xdg-open is unavailable; open the URL above in your browser"
    xdg-open "$url" >/dev/null 2>&1 || fail "could not open the browser; use the URL above"
  fi
}

# shellcheck shell=bash disable=SC2034,SC2154,SC1090

model_register() {
  local id="$1" spec="$2" file old meta
  mkdir -p "$OVERRIDES_DIR"
  file="$OVERRIDES_DIR/$(localvllm_safe_id "$id").conf"
  if [ -f "$file" ]; then
    meta="$(localvllm_override_meta "$file")"
    IFS=$'\t' read -r _ old _ <<< "$meta"
    [ -z "$old" ] || [ "$old" = "$spec" ] || { echo "Error: $id already points to a different model." >&2; return 1; }
    if [ -n "$old" ]; then return 0; fi
  fi
  # Append identity to a settings-only override without discarding its tuning.
  { printf 'ID=%q\n' "$id"; printf 'MODEL=%q\n' "$spec"; } >> "$file"
  chmod 600 "$file"
}

pull_cmd() {
  local model="${1:-}" revision="" file snapshot
  [ "$#" -gt 0 ] || fail 'usage: localvllm pull ORG/MODEL [--revision REF]'
  shift
  if [ "$#" -gt 0 ]; then
    if [ "$#" != 2 ] || [ "$1" != --revision ]; then
      fail 'usage: localvllm pull ORG/MODEL [--revision REF]'
    fi
    revision="$2"
    [ -n "$revision" ] || fail 'revision cannot be empty'
  fi
  [[ "$model" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || fail 'use a Hugging Face ID such as ORG/MODEL'
  [ -x "$VENV_DIR/bin/python" ] || fail "install the engine first: localvllm backend install $LOCALVLLM_BACKEND"
  file="$OVERRIDES_DIR/$(localvllm_safe_id "$model").conf"
  if [ -z "$revision" ] && [ -f "$file" ]; then
    revision="$( (set +u; unset REVISION; . "$file"; printf '%s' "${REVISION:-main}") )"
  fi
  revision="${revision:-main}"
  download_guidance
  echo "Downloading $model ($revision) for $LOCALVLLM_BACKEND; existing cached files are reused."
  if ! snapshot="$(HF_HOME="${LOCALVLLM_HF_HOME:-$AI_DIR/$LOCALVLLM_HF_CACHE_SUBDIR}" HF_TOKEN="${LOCALVLLM_HF_TOKEN:-${HF_TOKEN:-}}" \
    "$VENV_DIR/bin/python" - "$model" "$revision" <<'PY'
import sys
from huggingface_hub import snapshot_download
print(snapshot_download(repo_id=sys.argv[1], revision=sys.argv[2]))
PY
  )"; then
    echo 'Download failed. Run the same command to resume cached files.' >&2
    download_guidance >&2
    return 1
  fi
  { [ -f "$snapshot/config.json" ] || [ -f "$snapshot/model_index.json" ]; } || { echo 'Downloaded repository is not a complete supported model folder (missing config.json or model_index.json).' >&2; return 1; }
  model_register "$model" "$model" || return 1
  printf 'REVISION=%q\n' "$revision" >> "$file"
  localvllm_link_cached_model "$model" "$revision"
  echo "Downloaded: $model"
  echo "Files: $snapshot"
  echo "Registered. Run localvllm --backend $LOCALVLLM_BACKEND reload to refresh automatic routing when ready."
}

add_cmd() {
  local path id
  [ "$#" = 1 ] || fail 'usage: localvllm add /path/to/model'
  path="$(expand_path "$1")"
  if [ ! -d "$path" ] || ! { [ -f "$path/config.json" ] || [ -f "$path/model_index.json" ]; }; then
    fail 'choose a complete model folder containing config.json (or model_index.json) and all model components'
  fi
  path="$(realpath "$path")"
  id="$(basename "$path")"
  model_register "$id" "$path" || return 1
  echo "Added $id from $path. Files were not moved or copied."
  echo "Registered. Run localvllm --backend $LOCALVLLM_BACKEND reload to refresh automatic routing when ready."
}

menu_run() {
  "$SCRIPT_PATH" --backend "$LOCALVLLM_BACKEND" "$@"
}

menu_ensure_engine() {
  local answer
  localvllm_backend_installed "$LOCALVLLM_BACKEND" && return 0
  printf 'Install %s now? This downloads engine packages. [Y/n]: ' "$LOCALVLLM_BACKEND_LABEL"
  read -r answer || return 1
  case "$answer" in ''|y|Y|yes) menu_run backend install "$LOCALVLLM_BACKEND" ;; *) return 1 ;; esac
}

menu_start_model() {
  local id="$1"
  menu_ensure_engine || return 1
  if [ "$(localvllm_serving_mode)" = swap ]; then
    menu_run load "$id" || return 1
    echo "Ready. Use model '$id' at $(api_base_url)/v1."
  else
    menu_run use "$id" && menu_run start
  fi
}

menu_loop() {
  local choice id source model format path selected active state marker n value answer mode runtime live
  local -a ids=()
  while true; do
    ids=(); active="$(cat "$ACTIVE_MODEL_FILE" 2>/dev/null || true)"
    state=stopped; service_is_active && state=running
    mode="$(localvllm_serving_mode)" || return 1
    runtime='{"states":{},"runtime_state_available":false}'
    if [ "$mode" = swap ]; then runtime="$(model_runtime_info)" || return 1; fi
    echo
    echo "Local vLLM | $LOCALVLLM_BACKEND_LABEL | $mode | $state"
    echo "Model folders: $MODELS_DIR"
    n=0
    while IFS=$'\t' read -r id source model format path; do
      [ -n "$id" ] || continue
      ids+=("$id"); n=$((n + 1)); marker='not downloaded'
      [ ! -d "$path" ] || marker='local files'
      if [ "$mode" = direct ] && [ "$id" = "$active" ]; then marker="$marker, selected"; fi
      if [ "$mode" = swap ]; then
        live="$(jq -r --arg id "$id" 'if .runtime_state_available then (.states[$id] // "unloaded") else "unavailable" end' <<< "$runtime")"
        marker="$marker, $live"
      fi
      printf '  %s) %s [%s]\n'  "$n" "$id" "$marker"
    done < <(localvllm_model_entries "$MODELS_DIR" "$OVERRIDES_DIR")
    [ "$n" -gt 0 ] || echo '  No models yet. Download one or add an existing folder.'
    echo '  d) Download a Hugging Face model     a) Add an existing model folder'
    echo '  e) Download an example model        x) Remove model registration'
    echo '  r) Start server                     s) Stop server'
    echo '  c) Apply registered models (may restart server)'
    echo '  b) Choose vLLM or Omni              m) Direct or automatic switching'
    echo '  i) API and storage details          t) Advanced model settings'
    if [ "$mode" = swap ]; then echo '  w) Open model dashboard'; else echo '  w) Open API documentation'; fi
    echo '  u) Update all installed components'
    echo '  q) Quit' 
    printf 'Choose a model number or an action: '
    read -r choice || return 0
    case "$choice" in
      q|Q) return 0 ;;
      c|C) menu_run reload || echo 'Reload failed; see the error above.' ;;
      e|E)
        model_examples
        printf 'Download example number (empty cancels): '; read -r value || return 0
        id=""
        if [ "$LOCALVLLM_BACKEND" = omni ]; then
          [ "$value" != 1 ] || id=Qwen/Qwen2.5-Omni-3B
        else
          case "$value" in 1) id=Qwen/Qwen3-4B ;; 2) id=Qwen/Qwen3-0.6B ;; esac
        fi
        if [ -n "$id" ] && menu_ensure_engine; then menu_run pull "$id" || echo 'Download failed; see the error above.'; fi ;;
      x|X)
        echo 'Remove registration and managed cache link only. Weight files and shared cache are preserved.'
        printf 'Model ID (empty cancels): '; read -r value || return 0
        [ -n "$value" ] || continue
        printf 'Remove this registration? [y/N]: '; read -r answer || return 0
        case "$answer" in y|Y|yes) menu_run remove "$value" ;; esac ;;
      d|D)
        printf 'Hugging Face model ID (ORG/MODEL; empty cancels): '
        read -r value || return 0
        [ -n "$value" ] || continue
        if menu_ensure_engine && menu_run pull "$value"; then
          printf 'Use this model now? [Y/n]: '; read -r answer || return 0
          case "$answer" in ''|y|Y|yes) menu_start_model "$value" || echo 'Could not start; see the error above.' ;; esac
        fi ;;
      a|A)
        echo 'Keep the complete model folder, including config.json or model_index.json and every required component.'
        printf 'Model folder path (empty cancels): '; read -r value || return 0
        [ -n "$value" ] || continue
        if menu_run add "$value"; then
          selected="$(basename "$(realpath "$(expand_path "$value")")")"
          printf 'Use this model now? [Y/n]: '; read -r answer || return 0
          case "$answer" in ''|y|Y|yes) menu_start_model "$selected" || echo 'Could not start; see the error above.' ;; esac
        fi ;;
      r|R) if menu_ensure_engine; then menu_run start || echo 'Choose or add a model, then retry.'; fi ;;
      s|S) menu_run stop || echo 'Stop failed; see the error above.' ;;
      u|U)
        echo 'Checking the manager, installed engines and optional router. Affected services may restart.'
        "$SCRIPT_PATH" update --all || echo 'Update failed; see the error above.' ;;
      b|B)
        echo '1) vLLM — text, vision input, embeddings and reranking'
        echo '2) Omni — supported audio, image, video and multimodal generation'
        printf 'Engine [1/2]: '; read -r value || return 0
        case "$value" in 1) localvllm_use_backend vllm ;; 2) localvllm_use_backend omni ;; *) echo 'Choose 1 or 2.' ;; esac ;;
      m|M)
        echo '1) Direct — clients connect straight to the engine (default)'
        echo '2) Automatic — install/use llama-swap; models load when requested'
        printf 'Serving mode [1/2]: '; read -r value || return 0
        case "$value" in
          1) menu_run mode direct || echo 'Mode change failed; previous mode was retained.' ;;
          2) if menu_ensure_engine; then menu_run mode swap || echo 'Mode change failed; previous mode was retained.'; fi ;;
          *) echo 'Choose 1 or 2.' ;;
        esac ;;
      i|I) menu_run models --paths; menu_run ui ;;
      w|W)
        if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
          menu_run ui --open || echo 'Open the printed URL in your browser.'
        else
          menu_run ui
        fi ;;
      t|T)
        echo "Model tuning files: $OVERRIDES_DIR"
        echo "Select a model, then use localvllm --backend $LOCALVLLM_BACKEND suggest MODEL for advice."
        echo 'Omni: preserve the upstream model deployment recipe; set ENGINE_DEFAULTS=1 to keep its native tuning.'
        echo 'Guide: https://github.com/hossbit/comai-linux-assistant-wiki/blob/main/Local-vLLM-Advanced.md' ;;
      *)
        if [[ "$choice" =~ ^[0-9]{1,4}$ ]] && ((10#$choice > 0 && 10#$choice <= ${#ids[@]})); then
          menu_start_model "${ids[10#$choice-1]}" || echo 'Could not start; see the error above.'
        else
          echo 'Choose a listed model number or action.'
        fi ;;
    esac
  done
}

menu_cmd() {
  [ "$#" = 0 ] || fail 'usage: localvllm menu'
  if [ ! -t 0 ] || [ ! -t 1 ]; then
    fail "menu needs an interactive terminal; scripts can use 'localvllm pull', 'add', 'use', 'start', and 'mode'"
  fi
  menu_loop
}

# Estimates describe unquantized weight storage, not total inference memory.
model_examples() {
  if [ "$LOCALVLLM_BACKEND" = omni ]; then
    echo '1) Omni example: Qwen/Qwen2.5-Omni-3B — audio/vision; roughly 6 GB of BF16 core weights.'
    echo 'https://huggingface.co/Qwen/Qwen2.5-Omni-3B'
    echo 'Multi-stage generation needs extra memory and the matching upstream deployment recipe:'
    echo 'https://docs.vllm.ai/projects/vllm-omni/en/latest/models/supported_models/'
  else
    echo '1) Chat example: Qwen/Qwen3-4B — roughly 8 GB of BF16 weights.'
    echo 'https://huggingface.co/Qwen/Qwen3-4B'
    echo '2) Small chat example: Qwen/Qwen3-0.6B — roughly 1.2 GB of BF16 weights.'
    echo 'https://huggingface.co/Qwen/Qwen3-0.6B'
  fi
  echo 'Inference needs additional memory for caches and runtime; context and concurrency increase it.'
  echo "Download: localvllm --backend $LOCALVLLM_BACKEND pull ORG/MODEL"
  echo 'Custom Hugging Face IDs and existing model folders are also supported.'
}

download_guidance() {
  local cache="${LOCALVLLM_HF_HOME:-$AI_DIR/$LOCALVLLM_HF_CACHE_SUBDIR}" probe
  probe="$cache"
  while [ ! -d "$probe" ] && [ "$probe" != / ]; do probe="$(dirname "$probe")"; done
  echo "Download cache: $cache"
  df -h --output=avail,target "$probe" 2>/dev/null || true
  echo 'Allow space for all repository files; downloads reuse cached files.'
  echo 'Gated/private model: accept access conditions on its Hugging Face page first.'
  echo 'Provide a read token through HF_TOKEN or LOCALVLLM_HF_TOKEN in your environment.'
  echo 'If access is denied, check your account permissions; for connection errors, check your network.'
}

remove_cmd() {
  local id="${1:-}" file link backup
  [ "$#" = 1 ] || fail 'usage: localvllm remove MODEL'
  file="$(localvllm_override_file_for_id "$OVERRIDES_DIR" "$id")" || return 1
  [ -f "$file" ] || fail 'No registration found. Move manually managed folders outside the model library to stop discovering them.'
  [ "$(cat "$ACTIVE_MODEL_FILE" 2>/dev/null || true)" != "$id" ] || fail 'Select another direct-mode model before removing this one.'
  if service_is_active; then fail 'Stop this backend before removing a registration.'; fi
  link="$MODELS_DIR/$(localvllm_safe_id "$id")"
  if [ -e "$link" ] && [ ! -L "$link" ]; then fail 'Move this model folder outside the library first; its files were preserved.'; fi
  backup="$(mktemp -d "$CONF_DIR/removed-model.XXXXXX")" || return 1
  cp -a "$file" "$backup/registration.conf" || return 1
  if [ -L "$link" ]; then
    case "$(readlink -f "$link")" in
      "${LOCALVLLM_HF_HOME:-$AI_DIR/$LOCALVLLM_HF_CACHE_SUBDIR}"/hub/models--*/snapshots/*) mv "$link" "$backup/library-link" || return 1 ;;
      *) fail 'This is a user-managed link. Move it outside the library first.' ;;
    esac
  fi
  mv "$file" "$backup/original.conf" || return 1
  echo "Removed registration: $id. Model weights and cache were preserved. Backup: $backup"
  echo "Run localvllm --backend $LOCALVLLM_BACKEND reload before starting to refresh the launcher."
}

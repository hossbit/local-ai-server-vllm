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
  echo "Downloading $model ($revision) for $LOCALVLLM_BACKEND; existing cached files are reused."
  if ! snapshot="$(HF_HOME="${LOCALVLLM_HF_HOME:-$AI_DIR/$LOCALVLLM_HF_CACHE_SUBDIR}" HF_TOKEN="${LOCALVLLM_HF_TOKEN:-${HF_TOKEN:-}}" \
    "$VENV_DIR/bin/python" - "$model" "$revision" <<'PY'
import sys
from huggingface_hub import snapshot_download
print(snapshot_download(repo_id=sys.argv[1], revision=sys.argv[2]))
PY
  )"; then
    echo 'Download failed. Check the model ID, disk space, network, and access token for gated models. Run the same command to resume.' >&2
    return 1
  fi
  { [ -f "$snapshot/config.json" ] || [ -f "$snapshot/model_index.json" ]; } || { echo 'Downloaded repository is not a complete supported model folder (missing config.json or model_index.json).' >&2; return 1; }
  model_register "$model" "$model" || return 1
  printf 'REVISION=%q\n' "$revision" >> "$file"
  localvllm_link_cached_model "$model" "$revision"
  echo "Downloaded: $model"
  echo "Files: $snapshot"
  if [ "$(localvllm_serving_mode)" = swap ]; then apply_config_change; fi
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
  if [ "$(localvllm_serving_mode)" = swap ]; then apply_config_change; fi
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
  local choice id source model format path selected active state marker n value answer mode
  local -a ids=()
  while true; do
    ids=(); active="$(cat "$ACTIVE_MODEL_FILE" 2>/dev/null || true)"
    state=stopped; service_is_active && state=running
    mode="$(localvllm_serving_mode)" || return 1
    echo
    echo "Local vLLM | $LOCALVLLM_BACKEND_LABEL | $mode | $state"
    echo "Model folders: $MODELS_DIR"
    n=0
    while IFS=$'\t' read -r id source model format path; do
      [ -n "$id" ] || continue
      ids+=("$id"); n=$((n + 1)); marker='not downloaded'
      [ ! -d "$path" ] || marker='local files'
      if [ "$mode" = direct ] && [ "$id" = "$active" ]; then marker="$marker, selected"; fi
      printf '  %s) %s [%s]\n' "$n" "$id" "$marker"
    done < <(localvllm_model_entries "$MODELS_DIR" "$OVERRIDES_DIR")
    [ "$n" -gt 0 ] || echo '  No models yet. Download one or add an existing folder.'
    echo '  d) Download a Hugging Face model     a) Add an existing model folder'
    echo '  r) Start server                     s) Stop server'
    echo '  b) Choose vLLM or Omni              m) Direct or automatic switching'
    echo '  i) API and storage details          t) Advanced model settings'
    if [ "$mode" = swap ]; then echo '  w) Open model dashboard'; else echo '  w) Open API documentation'; fi
    echo '  u) Update all installed components'
    echo '  q) Quit' 
    printf 'Choose a model number or an action: '
    read -r choice || return 0
    case "$choice" in
      q|Q) return 0 ;;
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

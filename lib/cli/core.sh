# shellcheck shell=bash disable=SC2015,SC2153,SC2154

usage() {
  cat <<EOF
Usage: localvllm [--backend vllm|omni] COMMAND

Backends (isolated venv, models, port, keys, and service):
  vllm        plain vLLM for text, embeddings, and reranking
  omni        vLLM-Omni for text, image, audio, video, and action generation
  all         both backends, where the command supports it

Commands:
  setup                  Guided setup: choose a backend and model
  start [BACKEND|all]    Start one or both services
  stop [BACKEND|all]     Stop one or both services and release GPU memory
  restart [BACKEND|all]  Restart one or both services
  reload [BACKEND|all]   Rescan models and restart only if launchers change
  status [--json] [BACKEND|all]
                         Show service, process, model, and API status
  check [--chat] [BACKEND|all]
                         Check /health and /v1/models
  logs [BACKEND]         Follow one service's current log (rotated on start)
  metrics [--watch] [BACKEND]
                         Show vLLM Prometheus metrics (queue, KV cache, speed)
  models [--json|--paths] List models, storage folders, and the active one
  use MODEL              Select the model for that backend
  load [MODEL]           Start/wake the service, optionally switching MODEL
  unload                 Sleep the model when sleep mode is enabled, else stop
  ui                     Print vLLM API docs and OpenAI endpoint URLs
  suggest [MODEL]        Suggest settings from model size and hardware
  key ...                Manage that backend's single active API key
  backend ...            List/install backends, or set the default
  doctor [--json] [BACKEND|all]
                         Check Python, vLLM, GPU, models, ports, keys, pip
  update                 Update vLLM packages and helper scripts
  version                Show both backends' versions and models
  uninstall              Uninstall both backends
  help                   Show this help

Examples:
  localvllm --backend omni models
  localvllm use Qwen/Qwen3-8B
  localvllm --backend omni use Qwen/Qwen3-Omni-30B-A3B-Instruct
  localvllm backend install omni
  localvllm start all
  localvllm status all
EOF
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

has_user_service() {
  command -v systemctl >/dev/null 2>&1 &&
    systemctl --user cat "$LOCALVLLM_SERVICE_NAME" >/dev/null 2>&1
}

service_is_active() {
  if has_user_service && systemctl --user is-active --quiet "$SERVICE_UNIT" 2>/dev/null; then
    return 0
  fi
  pid_file_matches_process "$PID_FILE" "$PID_START_FILE"
}

# localvllm_resolve_selector [BACKEND|all]
# Prints the selector to use: the argument when present, otherwise the active
# backend. Returns non-zero for an unknown name.
localvllm_resolve_selector() {
  local arg="${1:-}"

  if [ -z "$arg" ]; then
    printf '%s\n' "$LOCALVLLM_BACKEND"
    return 0
  fi

  case "${arg,,}" in
    all)
      printf 'all\n'
      return 0
      ;;
    *)
      localvllm_backend_name "$arg" || {
        echo "Error: unknown backend: $arg (use vllm, omni, or all)" >&2
        return 1
      }
      ;;
  esac
}

serve_env_value() {
  local key="$1"
  local file="${2:-$CONF_DIR/$LOCALVLLM_SERVE_ENV_FILE}"

  config_assignment_value "$key" "$file" 2>/dev/null || true
}

print_service_details() {
  local method="$1"
  local active_id active_model

  active_id="$(serve_env_value LOCALVLLM_ACTIVE_ID)"
  active_model="$(serve_env_value LOCALVLLM_MODEL)"
  if [ -z "$active_id" ] &&
    localvllm_resolve_active "$MODELS_DIR" "$ACTIVE_MODEL_FILE" "$OVERRIDES_DIR" 2>/dev/null; then
    active_id="$ACTIVE_ID"
    active_model="$ACTIVE_MODEL"
  fi

  echo "Local $LOCALVLLM_BACKEND_LABEL service details:"
  echo "  backend: $LOCALVLLM_BACKEND"
  echo "  method: $method"
  echo "  service: $LOCALVLLM_SERVICE_NAME"
  echo "  service file: $SERVICE_FILE"
  echo "  install dir: $AI_DIR"
  echo "  model: ${active_id:-none}${active_model:+ ($active_model)}"
  echo "  API: http://${LOCALVLLM_LISTEN_HOST}:$([ -f "$PORT_FILE" ] && cat "$PORT_FILE" || printf '%s' "$LOCALVLLM_DEFAULT_PORT")"
  echo "  log: $LOG_FILE"
}

pid_status() {
  local pid command port

  port="$([ -f "$PORT_FILE" ] && cat "$PORT_FILE" || printf '%s' "$LOCALVLLM_DEFAULT_PORT")"
  if [ -f "$PID_FILE" ]; then
    pid="$(<"$PID_FILE")"
    if pid_file_matches_process "$PID_FILE" "$PID_START_FILE"; then
      command="$(ps -p "$pid" -o comm= 2>/dev/null || true)"
      if process_is_vllm "$pid"; then
        echo "Local $LOCALVLLM_BACKEND_LABEL process: running (vLLM PID $pid)"
      else
        echo "Local $LOCALVLLM_BACKEND_LABEL process: running (PID $pid, command ${command:-unknown})"
      fi
    else
      echo "Local $LOCALVLLM_BACKEND_LABEL process: not running; stale PID file exists at $PID_FILE"
    fi
  else
    echo "Local $LOCALVLLM_BACKEND_LABEL process: not running (no PID file)"
  fi
  echo "API: http://${LOCALVLLM_LISTEN_HOST}:$port"
  if port_is_listening "$port"; then
    echo "Port: listening"
  else
    echo "Port: not listening"
  fi
}

api_base_url() {
  api_base_url_for_port_file "$PORT_FILE"
}

require_api_tools() {
  command -v curl >/dev/null 2>&1 || fail "curl is required for this command"
  command -v jq >/dev/null 2>&1 || fail "jq is required for this command"
}

# --- doctor ---------------------------------------------------------------

DOCTOR_ERRORS=0
DOCTOR_WARNINGS=0

doctor_ok() {
  printf '  %s %s\n' "$(c 32 'OK')" "$*"
}

doctor_warn() {
  DOCTOR_WARNINGS=$((DOCTOR_WARNINGS + 1))
  printf '  %s %s\n' "$(c 33 'WARN')" "$*"
}

doctor_bad() {
  DOCTOR_ERRORS=$((DOCTOR_ERRORS + 1))
  printf '  %s %s\n' "$(c 31 'FAIL')" "$*"
}

doctor_one_backend() {
  local python="$VENV_DIR/bin/python"
  local vllm="$VENV_DIR/bin/vllm"
  local version omni_version port free_space status

  echo
  echo "Backend: $LOCALVLLM_BACKEND_LABEL ($LOCALVLLM_BACKEND)"
  echo

  echo "Installation"
  [ -d "$AI_DIR" ] && doctor_ok "install directory: $AI_DIR" || doctor_bad "install directory is missing: $AI_DIR"
  [ -f "$CONF_ROOT/localvllm.conf" ] && doctor_ok "global configuration: $CONF_ROOT/localvllm.conf" || doctor_bad "global configuration is missing"
  [ -f "$LOCALVLLM_BACKEND_PROFILE" ] && doctor_ok "backend profile: $LOCALVLLM_BACKEND_PROFILE" || doctor_warn "backend profile is missing: $LOCALVLLM_BACKEND_PROFILE"
  [ -d "$MODELS_DIR" ] && doctor_ok "models directory: $MODELS_DIR" || doctor_warn "models directory is missing: $MODELS_DIR"

  echo
  echo "Python and engine"
  if [ -x "$python" ]; then
    doctor_ok "Python: $(python_version "$python") ($python)"
  else
    doctor_bad "virtual environment is missing: $VENV_DIR (run install-localvllm.sh --backend $LOCALVLLM_BACKEND)"
  fi
  if [ -x "$vllm" ]; then
    version="$(vllm_installed_version "$VENV_DIR")"
    [ -n "$version" ] && doctor_ok "vLLM: $version" || doctor_warn "vLLM version could not be read"
  else
    doctor_bad "vLLM is not installed in $VENV_DIR"
  fi
  if [ "$LOCALVLLM_BACKEND" = "omni" ]; then
    if vllm_omni_is_available "$VENV_DIR"; then
      omni_version="$(vllm_omni_installed_version "$VENV_DIR")"
      doctor_ok "vLLM-Omni: ${omni_version:-installed}"
    else
      doctor_bad "vLLM-Omni is not installed in $VENV_DIR"
    fi
  fi
  if [ -x "$VENV_DIR/bin/python" ]; then
    if vllm_pip_check "$VENV_DIR"; then
      doctor_ok "pip check: package set is consistent"
    else
      doctor_bad "pip check failed; run: $VENV_DIR/bin/python -m pip check"
    fi
  fi

  echo
  echo "Hardware"
  if command -v nvidia-smi >/dev/null 2>&1; then
    local gpu_line
    gpu_line="$(nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>/dev/null | head -n3)"
    if [ -n "$gpu_line" ]; then
      doctor_ok "NVIDIA GPU(s):"
      while IFS= read -r line; do
        [ -n "$line" ] && printf '       %s\n' "$line"
      done <<<"$gpu_line"
    else
      doctor_warn "nvidia-smi exists but reported no GPU"
    fi
  elif command -v rocm-smi >/dev/null 2>&1 || [ -e /dev/kfd ]; then
    doctor_warn "ROCm detected; the installed vLLM wheel must match your ROCm runtime"
  else
    doctor_warn "no supported GPU detected; CPU vLLM is experimental"
  fi
  printf '  %s %s GiB system RAM\n' "$(c 32 'OK')" "$(awk -v b="$(system_ram_bytes)" 'BEGIN { printf "%.1f", b / 1024 / 1024 / 1024 }')"
  if [ "$(gpu_vram_bytes)" -gt 0 ]; then
    printf '  %s %s GiB VRAM per GPU\n' "$(c 32 'OK')" "$(awk -v b="$(gpu_vram_bytes)" 'BEGIN { printf "%.1f", b / 1024 / 1024 / 1024 }')"
  fi

  echo
  echo "Service and model"
  if has_user_service; then
    status="$(systemctl --user is-active "$SERVICE_UNIT" 2>/dev/null || true)"
    [ "$status" = active ] && doctor_ok "systemd user service is active" || doctor_warn "systemd user service is $status"
  else
    doctor_warn "systemd user service is not installed"
  fi
  if service_is_active; then
    doctor_ok "process is running (PID $(cat "$PID_FILE" 2>/dev/null || printf '?'))"
  else
    doctor_warn "process is not running"
  fi
  if localvllm_resolve_active "$MODELS_DIR" "$ACTIVE_MODEL_FILE" "$OVERRIDES_DIR" 2>/dev/null; then
    doctor_ok "active model: $ACTIVE_ID ($ACTIVE_FORMAT)"
    printf '       %s\n' "$ACTIVE_MODEL"
  else
    doctor_warn "no active model is selected"
  fi
  port="$([ -f "$PORT_FILE" ] && cat "$PORT_FILE" || printf '%s' "$LOCALVLLM_DEFAULT_PORT")"
  if port_is_listening "$port"; then
    doctor_ok "port $port is listening"
  else
    doctor_warn "port $port is not listening"
  fi

  echo
  echo "Security"
  if [ -f "$(api_key_registry_path)" ]; then
    local count
    count="$(api_key_active_count "$(api_key_registry_path)")"
    if [ "$count" -eq 0 ]; then
      doctor_warn "key registry exists but no key is active; API is unauthenticated"
    elif [ "$count" -eq 1 ]; then
      doctor_ok "one active API key"
    else
      doctor_bad "$count active API keys; vLLM supports one (run localvllm key list)"
    fi
  else
    doctor_warn "no API keys configured; API is unauthenticated (fine on loopback)"
  fi
  case "$LOCALVLLM_LISTEN_HOST" in
    127.0.0.1|localhost|::1) ;;
    *) doctor_warn "listener is $LOCALVLLM_LISTEN_HOST; vLLM's API key does not protect /health or /docs" ;;
  esac

  echo
  echo "Disk"
  free_space="$(df -h "$AI_DIR" 2>/dev/null | awk 'NR == 2 {print $4 " free of " $2}')"
  [ -n "$free_space" ] && doctor_ok "$free_space on the install filesystem" || doctor_warn "disk space could not be read"
}

doctor_json_one() {
  local installed=false version="" omni_version="" service_state="not installed"
  local port active_id="" active_model="" api_key_active=0 registry
  local profile_exists=false python_value="" vram_total vram_free pip_ok=false

  localvllm_backend_installed "$LOCALVLLM_BACKEND" && installed=true
  version="$(vllm_installed_version "$VENV_DIR")"
  if [ "$LOCALVLLM_BACKEND" = "omni" ]; then
    omni_version="$(vllm_omni_installed_version "$VENV_DIR")"
  fi
  if service_is_active; then
    service_state="running"
  elif has_user_service; then
    service_state="stopped"
  fi
  port="$([ -f "$PORT_FILE" ] && cat "$PORT_FILE" || printf '%s' "$LOCALVLLM_DEFAULT_PORT")"
  active_id="$(serve_env_value LOCALVLLM_ACTIVE_ID)"
  active_model="$(serve_env_value LOCALVLLM_MODEL)"
  if [ -z "$active_id" ] &&
    localvllm_resolve_active "$MODELS_DIR" "$ACTIVE_MODEL_FILE" "$OVERRIDES_DIR" 2>/dev/null; then
    active_id="$ACTIVE_ID"
    active_model="$ACTIVE_MODEL"
  fi
  registry="$(api_key_registry_path)"
  if [ -f "$registry" ] && [ "$(api_key_active_count "$registry")" -gt 0 ]; then
    api_key_active=1
  fi
  [ -f "$LOCALVLLM_BACKEND_PROFILE" ] && profile_exists=true
  if [ -x "$VENV_DIR/bin/python" ]; then
    python_value="$(python_version "$VENV_DIR/bin/python")"
    vllm_pip_check "$VENV_DIR" && pip_ok=true
  fi
  vram_total="$(gpu_vram_total_min_bytes)"
  vram_free="$(gpu_vram_free_min_bytes)"

  jq -n \
    --arg backend "$LOCALVLLM_BACKEND" \
    --arg label "$LOCALVLLM_BACKEND_LABEL" \
    --argjson installed "$installed" \
    --arg vllm "$version" \
    --arg omni "$omni_version" \
    --arg service "$service_state" \
    --arg port "$port" \
    --arg active "$active_id" \
    --arg model "$active_model" \
    --arg api_key_active "$api_key_active" \
    --argjson profile "$profile_exists" \
    --argjson pip_ok "$pip_ok" \
    --arg python "$python_value" \
    --arg vram_total "$vram_total" \
    --arg vram_free "$vram_free" \
    --arg models_dir "$MODELS_DIR" \
    --arg log "$LOG_FILE" \
    '{
      backend: $backend, label: $label, installed: $installed,
      vllm_version: (if $vllm == "" then null else $vllm end),
      vllm_omni_version: (if $omni == "" then null else $omni end),
      service: $service,
      port: ($port | tonumber? // null),
      active_model: (if $active == "" then null else $active end),
      model: (if $model == "" then null else $model end),
      api_key_active: ($api_key_active == "1"),
      profile_exists: $profile,
      pip_check: $pip_ok,
      python: (if $python == "" then null else $python end),
      vram_total_bytes: ($vram_total | tonumber? // 0),
      vram_free_bytes: ($vram_free | tonumber? // 0),
      models_dir: $models_dir,
      log: $log
    }'
}

doctor_json_cmd() {
  local selector="$1" original_backend name tmp errors=0 warnings=0

  command -v jq >/dev/null 2>&1 || fail "jq is required for --json output"
  original_backend="$LOCALVLLM_BACKEND"
  tmp="$(mktemp "${TMPDIR:-/tmp}/localvllm-doctor.XXXXXX")" || return 1
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN

  if [ "$selector" = "all" ]; then
    while IFS= read -r name; do
      localvllm_use_backend "$name" || continue
      doctor_json_one >> "$tmp"
    done < <(localvllm_backend_list)
    localvllm_use_backend "$original_backend" >/dev/null 2>&1 || true
  else
    localvllm_use_backend "$selector" || return 1
    doctor_json_one >> "$tmp"
  fi

  errors="$(jq -s '[.[] | select(.installed == false)] | length' "$tmp")"
  errors=$((errors + $(jq -s '[.[] | select(.installed == true and .pip_check == false)] | length' "$tmp")))
  warnings="$(jq -s '[.[] | select(.service != "running")] | length' "$tmp")"
  case "$LOCALVLLM_LISTEN_HOST" in
    127.0.0.1|localhost|::1) ;;
    *)
      errors=$((errors + $(jq -s '[.[] | select(.api_key_active == false)] | length' "$tmp")))
      ;;
  esac

  jq -s --argjson errors "$errors" --argjson warnings "$warnings" \
    '{ok: ($errors == 0), errors: $errors, warnings: $warnings, backends: .}' "$tmp"
}

doctor_cmd() {
  local selector original_backend name json=0 selector_arg="" arg

  for arg in "$@"; do
    case "$arg" in
      --json) json=1 ;;
      all|vllm|omni|text|llm|vllm-omni|vllm_omni|omni-vllm) selector_arg="$arg" ;;
      *) fail "usage: localvllm doctor [--json] [BACKEND|all]" ;;
    esac
  done
  selector="$(localvllm_resolve_selector "$selector_arg")" || return 1
  if [ "$json" -eq 1 ]; then
    doctor_json_cmd "$selector"
    return
  fi
  original_backend="$LOCALVLLM_BACKEND"
  DOCTOR_ERRORS=0
  DOCTOR_WARNINGS=0

  echo "Local vLLM doctor"

  if [ "$selector" = "all" ]; then
    while IFS= read -r name; do
      localvllm_use_backend "$name" || continue
      doctor_one_backend || true
    done < <(localvllm_backend_list)
  else
    localvllm_use_backend "$selector" || return 1
    doctor_one_backend || true
  fi

  localvllm_use_backend "$original_backend" >/dev/null 2>&1 || true

  echo
  if [ "$DOCTOR_ERRORS" -gt 0 ]; then
    echo "$DOCTOR_ERRORS error(s), $DOCTOR_WARNINGS warning(s)."
    return 1
  fi
  echo "No errors, $DOCTOR_WARNINGS warning(s)."
  return 0
}

# Interactive onboarding uses the existing installer and model/service paths.
setup_cmd() {
  local choice backend model answer
  [ "$#" -eq 0 ] || fail "usage: localvllm setup"
  [ -t 0 ] && [ -t 1 ] || fail "setup needs an interactive terminal; use 'localvllm backend install', 'localvllm use', and 'localvllm start' in scripts"
  echo
  echo "Welcome to Local AI Server"
  echo "1) Text, embeddings and reranking (recommended)"
  echo "2) Multimodal models (image, audio and video)"
  printf 'Choose 1 or 2 [1]: '
  read -r choice || return 1
  case "${choice:-1}" in
    1) backend=vllm ;;
    2) backend=omni ;;
    *) echo "Please run setup again and choose 1 or 2." >&2; return 2 ;;
  esac
  localvllm_use_backend "$backend" || return 1
  if ! localvllm_backend_installed "$backend"; then
    echo
    echo "The selected engine needs to be downloaded and installed. This can take time and disk space."
    printf 'Install it now? [Y/n]: '
    read -r answer || return 1
    case "$answer" in ''|y|Y|yes|YES) ;; *) echo "Setup stopped. Run 'localvllm setup' when ready."; return 0 ;; esac
    backend_install_cmd "$backend" || return 1
    localvllm_use_backend "$backend" || return 1
  fi
  echo
  echo "Enter a Hugging Face model ID (for example: Qwen/Qwen3-8B),"
  echo "or a model name already listed by 'localvllm --backend $backend models'."
  echo "Choose a model compatible with your hardware and selected engine."
  printf 'Model (leave empty to finish later): '
  read -r model || return 1
  if [ -z "$model" ]; then
    echo "Engine ready. Run 'localvllm setup' to choose a model later."
    return 0
  fi
  use_cmd "$model" || return 1
  printf 'Start the server now? [Y/n]: '
  read -r answer || return 1
  case "$answer" in
    ''|y|Y|yes|YES)
      service_cmd start "$backend" || return 1
      echo "Run 'localvllm --backend $backend ui' for the API and documentation URLs."
      ;;
    *) echo "Start later with: localvllm start $backend" ;;
  esac
}

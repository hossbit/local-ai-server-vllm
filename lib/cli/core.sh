# shellcheck shell=bash disable=SC2015,SC2153,SC2154

usage() {
  cat <<EOF
Usage: localvllm [--backend vllm|omni] COMMAND

Backends (isolated venv, models, port, keys, and service):
  vllm        plain vLLM for text, embeddings, and reranking
  omni        vLLM-Omni for text, image, audio, video, and action generation
  all         both backends, where the command supports it

Commands:
  start [BACKEND|all]    Start one or both services
  stop [BACKEND|all]     Stop one or both services and release GPU memory
  restart [BACKEND|all]  Restart one or both services
  reload [BACKEND|all]   Rescan models and restart only if launchers change
  status [--json] [BACKEND|all]
                         Show service, process, model, and API status
  check [--chat] [BACKEND|all]
                         Check /health and /v1/models
  logs [BACKEND|all]     Follow logs; --list lists files; --no-follow prints recent lines
  metrics [--watch] [BACKEND]
                         Readable queue/cache/token statistics; --raw for Prometheus
  models [--json|--paths] List models, storage folders, and live/selected state
  use MODEL              Select the model for that backend
  load [MODEL]           Start/wake the service, optionally switching MODEL
  unload                 Sleep the model when sleep mode is enabled, else stop
  ui                     Print vLLM API docs and OpenAI endpoint URLs
  suggest [MODEL]        Suggest settings from model size and hardware
  key ...                Manage API keys (create, list, revoke, rotate)
  backend ...            List/install backends, or set the default
  doctor [--json] [BACKEND|all]
                         Check Python, vLLM, GPU, models, ports, keys, pip
  config check [BACKEND|all]
                         Validate configuration without changing the launcher
  update [--all|--check] Update selected backend, router and helpers; --all updates every backend,
                         --check only reports available updates
  rollback [BACKEND]     Switch a backend back to the environment its last update replaced
  version                Show both backends' versions and models
  uninstall              Uninstall both backends
  menu                   Manage models and serving mode interactively
  setup                  Guided backend, serving method and model configuration; no auto-start
  pull ORG/MODEL         Download/register a model without changing the active one
  add /path/to/model     Register an existing folder without copying it
  remove MODEL           Remove a stopped backend model registration; preserve weights
  mode [direct|swap]     Show/change this backend's serving mode
  help [TOPIC]           Help: paths, models, modes, keys, logs, metrics, troubleshoot

Common workflows:
  localvllm models                         # Your models and storage
  localvllm pull ORG/MODEL                 # Download without interrupting serving
  localvllm use ORG/MODEL                  # Select a direct-mode model
  localvllm start                          # Start this backend
  localvllm --backend omni models          # Same commands for Omni
  localvllm menu                           # Optional interactive interface

Need help? localvllm help paths | models | modes | keys | logs | metrics | troubleshoot
Full guide: https://github.com/hossbit/comai-linux-assistant-wiki/blob/main/Local-vLLM.md
EOF
}

help_topic() {
  local topic="${1:-}"
  [ "$#" -le 1 ] || fail 'usage: localvllm help [TOPIC]'
  case "$topic" in
    '') usage ;;
    paths)
      cat <<EOF
Choose a workflow — setup is optional; commands work independently.
  localvllm setup                       Guided setup; leaves services stopped
  localvllm backend list                See both engines and the default marker
  localvllm backend default omni        Persist the default used by bare commands
  localvllm --backend vllm COMMAND       Target text engine without changing the default
  localvllm --backend omni COMMAND      Target Omni without changing the default

Direct/manual: install engine -> pull/add model -> use MODEL -> mode direct -> start
Automatic: install engine -> pull/add models -> mode swap -> start
After adding models to an already running router: reload when ready (may restart it).
Use --backend omni on every step for Omni; its model-specific deployment recipe may need tuning.

Stopped service? ui and metrics do not start it. Start explicitly when ready.
Direct ui: API documentation (/docs). Swap ui: model dashboard (/ui).
Diagnosis: status -> doctor all -> logs --no-follow -> logs --service --no-follow.
EOF
      ;;
    models)
      cat <<EOF
Models — use --backend omni for the separate Omni library.
  localvllm models --paths          Show your model library and shared cache
  localvllm pull ORG/MODEL          Download/register; cached files are reused
  localvllm add /path/to/model      Register a complete model folder, without copying
  localvllm use MODEL               Select a registered model or folder for direct mode
  localvllm start                   Start the selected backend
  localvllm reload                  Apply registrations to automatic routing when ready
  localvllm remove MODEL            Remove registration while stopped; preserve weights
Own files: put a complete model folder under ~/ai-vllm/models/vllm/ or models/omni/.
Use models --paths for your actual installation paths. Model memory requirements vary.
EOF
      ;;
    modes)
      cat <<EOF
Direct/manual (default): clients connect to the engine. Select with use MODEL.
Automatic (llama-swap): clients send the model ID in each API request.
  localvllm mode                   Show current mode
  localvllm mode direct            Use native serving
  localvllm mode swap              Enable automatic switching and download the router
  localvllm ui --open              Open API docs (direct) or model dashboard (swap)
Both backends retain their own models, API keys, ports and mode.
Changing modes or applying configuration may restart a running service.
After pull/add, use reload to update a running router; active requests may be interrupted.
EOF
      ;;
    keys|key) key_usage ;;
    logs)
      cat <<EOF
Logs — one directory for both backends and manager operations.
  localvllm logs                    Follow this backend (Ctrl+C exits)
  localvllm logs omni               Follow Omni
  localvllm logs all                Follow all current log files
  localvllm logs --list             File names and what each contains
  localvllm logs --path             Print the shared log directory
  localvllm logs --no-follow -n 100  Print recent lines without waiting
  localvllm logs --file update.log --no-follow
  localvllm logs --service          Read systemd startup logs and save a local copy
All logs live under <install directory>/logs, normally ~/ai-vllm/logs.
Runtime logs include native engine output and llama-swap workers in automatic mode.
Older runtime/operation sessions have timestamped filenames.
Review logs before sharing: upstream errors and package tools may include private paths or URLs.
EOF
      ;;
    metrics)
      cat <<EOF
Metrics — works in direct/manual and llama-swap modes for vLLM and Omni.
  localvllm metrics                 Queue, cache, token counters and mean first-token latency
  localvllm metrics --watch         Refresh every 2 seconds; sampled generation speed
  localvllm metrics omni            Inspect the Omni backend
  localvllm metrics --raw           Native Prometheus endpoint (router metrics in swap mode)
No inference request is sent and no model is loaded by monitoring.
In automatic mode, ready worker metrics are read directly over loopback.
Missing or model-specific metrics appear as n/a; counter resets are not negative speed.
Omni stage-specific image/audio/video metrics vary by model and engine version.
GPU memory is hardware-wide, not a per-model allocation. Ctrl+C stops live monitoring.
EOF
      ;;
    troubleshoot)
      cat <<EOF
Troubleshooting — commands work with --backend omni too.
  localvllm status                  Service and process state
  localvllm doctor all              Check both installations and dependencies
  localvllm config check            Validate configuration without changing it
  localvllm check                   Health and available API models
  localvllm check --chat            Send a small chat request (may load a model)
  localvllm logs --no-follow        Recent engine/router errors
  localvllm logs --service --no-follow  Startup and systemd errors
  localvllm update --scripts-only   Refresh manager helpers
  localvllm update                  Update this backend, router and helpers
  localvllm update --all            Update every installed backend
  localvllm update --check          Show available updates without changing anything
  localvllm rollback                Return this backend to the environment before its last update
No model? Use models, pull ORG/MODEL, then use MODEL and start.
Memory error? Choose a smaller model/context or review help models and suggest MODEL.
For ARM64, ROCm and Fedora/RHEL, consult the platform guide before selecting wheels:
https://github.com/hossbit/comai-linux-assistant-wiki/blob/main/Local-vLLM.md#platform-notes
EOF
      ;;
    *) echo "Unknown help topic: $topic. Choose models, modes, keys, logs, or troubleshoot." >&2; return 2 ;;
  esac
}

fail() {
  local topic=troubleshoot
  case "${COMMAND:-}" in
    start|restart|setup|backend) topic=paths ;;
    key) topic=keys ;;
    use|switch|pull|add|remove|models) topic=models ;;
    mode|ui) topic=modes ;;
    logs) topic=logs ;;
    metrics) topic=metrics ;;
  esac
  echo "Error: $*" >&2
  echo "Guide: localvllm --backend ${LOCALVLLM_BACKEND:-vllm} help $topic" >&2
  exit 1
}

# CLI compatibility wrappers. The single implementation lives in
# lib/common.sh and is shared with the installer, updater and uninstaller.
has_user_service() {
  localvllm_has_user_service
}

service_is_active() {
  localvllm_service_is_active
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
  echo "  mode: $(localvllm_serving_mode)"
  echo "  method: $method"
  echo "  service: $LOCALVLLM_SERVICE_NAME"
  echo "  service file: $SERVICE_FILE"
  echo "  install dir: $AI_DIR"
  if [ "$(localvllm_serving_mode)" = swap ]; then
    local runtime loaded
    runtime="$(model_runtime_info)" || return 1
    loaded="$(jq -r 'if .runtime_state_available then (.active_models | join(", ")) else "unavailable" end' <<< "$runtime")"
    echo "  loaded models: ${loaded:-none}"
  else
    echo "  selected model: ${active_id:-none}${active_model:+ ($active_model)}"
  fi
  echo "  API: http://$(localvllm_url_host "$LOCALVLLM_LISTEN_HOST"):$([ -f "$PORT_FILE" ] && cat "$PORT_FILE" || printf '%s' "$LOCALVLLM_DEFAULT_PORT")"
  echo "  log: $LOG_FILE"
}

pid_status() {
  local pid command port

  port="$([ -f "$PORT_FILE" ] && cat "$PORT_FILE" || printf '%s' "$LOCALVLLM_DEFAULT_PORT")"
  if [ -f "$PID_FILE" ] && pid_file_matches_process "$PID_FILE" "$PID_START_FILE"; then
    pid="$(<"$PID_FILE")"
    command="$(ps -p "$pid" -o comm= 2>/dev/null || true)"
    if process_is_vllm "$pid"; then
      echo "Local $LOCALVLLM_BACKEND_LABEL process: running (vLLM PID $pid)"
    else
      echo "Local $LOCALVLLM_BACKEND_LABEL process: running (PID $pid, command ${command:-unknown})"
    fi
  elif [ -f "$PID_FILE" ]; then
    echo "Local $LOCALVLLM_BACKEND_LABEL process: not running; stale PID file exists at $PID_FILE"
  elif has_user_service; then
    if pid="$(localvllm_service_main_pid)"; then
      echo "Local $LOCALVLLM_BACKEND_LABEL process: running (vLLM PID $pid via systemd)"
    elif service_is_active; then
      echo "Local $LOCALVLLM_BACKEND_LABEL process: managed by systemd (main PID pending)"
    else
      echo "Local $LOCALVLLM_BACKEND_LABEL process: not running (systemd service is not active; it may be restarting)"
    fi
  else
    echo "Local $LOCALVLLM_BACKEND_LABEL process: not running (no PID file)"
  fi
  echo "API: http://$(localvllm_url_host "$LOCALVLLM_LISTEN_HOST"):$port"
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
  local optional="${1:-0}"
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
  if [ ! -x "$python" ] && [ "$optional" = "1" ]; then
    doctor_warn "optional backend is not installed: $VENV_DIR (install with: localvllm backend install $LOCALVLLM_BACKEND)"
  else
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
    local running_pid
    running_pid="$(localvllm_service_main_pid 2>/dev/null || cat "$PID_FILE" 2>/dev/null || printf '?')"
    doctor_ok "process is running (PID $running_pid)"
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
  local port active_id="" active_model="" api_key_active=0 registry runtime
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
  runtime="$(model_runtime_info)" || return 1
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
    --argjson runtime "$runtime" \
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
      active_model: (if $runtime.active_model == "" then null else $runtime.active_model end),
      active_models: $runtime.active_models,
      direct_model: $runtime.direct_model,
      runtime_state_available: $runtime.runtime_state_available,
      model: (if $runtime.mode == "direct" and $runtime.active_model != "" then $model else null end),
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

  if [ "$selector" = "all" ]; then
    # A backend that was never installed is optional in "doctor all". Only a
    # backend that is present but broken counts as an error.
    if [ "$(jq -s '[.[] | select(.installed == true)] | length' "$tmp")" -eq 0 ]; then
      errors=1
    else
      errors=0
    fi
    errors=$((errors + $(jq -s '[.[] | select(.installed == true and .pip_check == false)] | length' "$tmp")))
    warnings="$(jq -s '[.[] | select(.installed == false or .service != "running")] | length' "$tmp")"
  else
    errors="$(jq -s '[.[] | select(.installed == false)] | length' "$tmp")"
    errors=$((errors + $(jq -s '[.[] | select(.installed == true and .pip_check == false)] | length' "$tmp")))
    warnings="$(jq -s '[.[] | select(.service != "running")] | length' "$tmp")"
  fi
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
      doctor_one_backend 1 || true
    done < <(localvllm_backend_list)
  else
    localvllm_use_backend "$selector" || return 1
    doctor_one_backend 0 || true
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

config_usage() {
  cat <<EOF
Usage: localvllm config check [BACKEND|all]

Validates configuration by generating the launcher in a temporary directory.
The installed launcher, service, and model state are not changed.
Use --backend omni for the Omni backend.
EOF
}

config_cmd() {
  local sub="${1:-check}"
  [ "$#" -eq 0 ] || shift

  case "$sub" in
    check) config_check_cmd "$@" ;;
    help|-h|--help) config_usage ;;
    *) config_usage >&2; return 2 ;;
  esac
}

config_check_cmd() {
  local selector original_backend name status=0 output rebuild
  [ "$#" -le 1 ] || fail 'usage: localvllm config check [BACKEND|all]'
  selector="$(localvllm_resolve_selector "${1:-}")" || return 1
  original_backend="$LOCALVLLM_BACKEND"

  rebuild="${BIN_DIR:-}/rebuild-config.sh"
  [ -x "$rebuild" ] || rebuild="${SCRIPT_DIR:-}/rebuild-config.sh"
  [ -x "$rebuild" ] || fail "missing helper: ${BIN_DIR:-$SCRIPT_DIR}/rebuild-config.sh"

  if [ "$selector" = "all" ]; then
    while IFS= read -r name; do
      echo
      echo "== $name =="
      localvllm_use_backend "$name" || { status=1; continue; }
      if ! localvllm_backend_installed "$name" || ! localvllm_has_model_entries "$MODELS_DIR" "$OVERRIDES_DIR"; then
        echo "Skipped: backend is not installed or has no registered models."
        continue
      fi
      if output="$("$rebuild" --backend "$name" --dry-run 2>&1)"; then
        printf '%s\n' "$output"
        echo "Configuration is valid: $name"
      else
        printf '%s\n' "$output" >&2
        echo "Configuration error: $name" >&2
        status=1
      fi
    done < <(localvllm_backend_list)
    localvllm_use_backend "$original_backend" >/dev/null 2>&1 || true
    return "$status"
  fi

  localvllm_use_backend "$selector" || return 1
  echo "Checking configuration for $LOCALVLLM_BACKEND_LABEL ($LOCALVLLM_BACKEND)"
  if output="$("$rebuild" --backend "$LOCALVLLM_BACKEND" --dry-run 2>&1)"; then
    printf '%s\n' "$output"
    echo "Configuration is valid."
    return 0
  fi
  printf '%s\n' "$output" >&2
  echo "Configuration has errors. Fix them, then run 'localvllm reload'." >&2
  return 1
}

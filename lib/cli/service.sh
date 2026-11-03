# shellcheck shell=bash disable=SC2153,SC2154

service_cmd_one() {
  local action="$1"

  case "$action" in
    start)
      if ! service_is_active; then
        localvllm_require_start_model || return 1
      fi
      ;;
    restart) localvllm_require_start_model || return 1 ;;
  esac

  if has_user_service; then
    print_service_details "systemd user service"
    echo "Running: systemctl --user $action $SERVICE_UNIT"
    if ! systemctl --user "$action" "$SERVICE_UNIT"; then
      echo "Error: systemctl --user $action $SERVICE_UNIT failed." >&2
      echo "Details: journalctl --user -u $LOCALVLLM_SERVICE_NAME -n 30 --no-pager" >&2
      echo "Server log: $LOG_FILE" >&2
      return 1
    fi
    echo "Local $LOCALVLLM_BACKEND_LABEL service $action completed."
    return 0
  fi

  case "$action" in
    start)
      [ -x "$BIN_DIR/start.sh" ] || fail "missing helper: $BIN_DIR/start.sh"
      print_service_details "helper script"
      echo "Running: $BIN_DIR/start.sh $LOCALVLLM_BACKEND"
      if ! "$BIN_DIR/start.sh" "$LOCALVLLM_BACKEND"; then
        echo "Error: $LOCALVLLM_BACKEND_LABEL failed to start." >&2
        return 1
      fi
      ;;
    stop)
      [ -x "$BIN_DIR/stop.sh" ] || fail "missing helper: $BIN_DIR/stop.sh"
      print_service_details "helper script"
      echo "Running: $BIN_DIR/stop.sh $LOCALVLLM_BACKEND"
      if ! "$BIN_DIR/stop.sh" "$LOCALVLLM_BACKEND"; then
        echo "Error: $LOCALVLLM_BACKEND_LABEL failed to stop." >&2
        return 1
      fi
      ;;
    restart)
      service_cmd_one stop || return 1
      service_cmd_one start || return 1
      ;;
    *)
      fail "unsupported service action: $action"
      ;;
  esac
}

service_cmd() {
  local action="$1"
  local selector original_backend name status=0

  shift || true
  [ "$#" -le 1 ] || fail "usage: localvllm $action [BACKEND|all]"
  selector="$(localvllm_resolve_selector "${1:-}")" || return 1
  original_backend="$LOCALVLLM_BACKEND"

  if [ "$selector" = "all" ]; then
    while IFS= read -r name; do
      echo
      echo "== $name =="
      localvllm_use_backend "$name" || continue
      service_cmd_one "$action" || status=1
    done < <(localvllm_backend_list)
    localvllm_use_backend "$original_backend" >/dev/null 2>&1 || true
    return "$status"
  fi

  localvllm_use_backend "$selector" || return 1
  service_cmd_one "$action"
}

status_cmd() {
  local selector original_backend name json=0 selector_arg="" arg
  local tmp

  for arg in "$@"; do
    case "$arg" in
      --json) json=1 ;;
      all|vllm|omni|text|llm|vllm-omni|vllm_omni|omni-vllm) selector_arg="$arg" ;;
      *) fail "usage: localvllm status [--json] [BACKEND|all]" ;;
    esac
  done
  selector="$(localvllm_resolve_selector "$selector_arg")" || return 1
  original_backend="$LOCALVLLM_BACKEND"

  if [ "$json" -eq 1 ]; then
    command -v jq >/dev/null 2>&1 || fail "jq is required for --json output"
    tmp="$(mktemp "${TMPDIR:-/tmp}/localvllm-status.XXXXXX")" || return 1
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" RETURN
    if [ "$selector" = "all" ]; then
      while IFS= read -r name; do
        localvllm_use_backend "$name" || continue
        status_json_one >> "$tmp"
      done < <(localvllm_backend_list)
      localvllm_use_backend "$original_backend" >/dev/null 2>&1 || true
      jq -s '.' "$tmp"
    else
      localvllm_use_backend "$selector" || return 1
      status_json_one
    fi
    return 0
  fi

  if [ "$selector" = "all" ]; then
    while IFS= read -r name; do
      echo
      echo "== $name =="
      localvllm_use_backend "$name" || continue
      status_cmd_one
    done < <(localvllm_backend_list)
    localvllm_use_backend "$original_backend" >/dev/null 2>&1 || true
    return 0
  fi

  localvllm_use_backend "$selector" || return 1
  status_cmd_one
}

status_json_one() {
  local installed=false version="" omni_version="" service_state="not installed"
  local port pid active_id="" active_model="" api_key_active=0 registry runtime

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
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
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

  jq -n \
    --argjson runtime "$runtime" \
    --arg backend "$LOCALVLLM_BACKEND" \
    --arg mode "$(localvllm_serving_mode)" \
    --arg label "$LOCALVLLM_BACKEND_LABEL" \
    --argjson installed "$installed" \
    --arg vllm "$version" \
    --arg omni "$omni_version" \
    --arg service "$service_state" \
    --arg port "$port" \
    --arg pid "$pid" \
    --arg active "$active_id" \
    --arg model "$active_model" \
    --arg api_key_active "$api_key_active" \
    --arg log "$LOG_FILE" \
    '{
      backend: $backend,
      mode: $mode,
      label: $label,
      installed: $installed,
      vllm_version: (if $vllm == "" then null else $vllm end),
      vllm_omni_version: (if $omni == "" then null else $omni end),
      service: $service,
      port: ($port | tonumber? // null),
      pid: ($pid | tonumber? // null),
      active_model: (if $runtime.active_model == "" then null else $runtime.active_model end),
      active_models: $runtime.active_models,
      direct_model: $runtime.direct_model,
      runtime_state_available: $runtime.runtime_state_available,
      selected_model_path: (if $model == "" then null else $model end),
      model: (if $runtime.mode == "direct" and $runtime.active_model != "" then $model else null end),
      api_key_active: ($api_key_active == "1"),
      log: $log
    }'
}

status_cmd_one() {
  local version

  if has_user_service; then
    print_service_details "systemd user service"
    echo "Systemd service:"
    systemctl --user status "$SERVICE_UNIT" --no-pager || true
    echo
    echo "Note: this service uses a helper script and may show active (exited); the process check below is authoritative."
  else
    print_service_details "helper script"
  fi
  pid_status

  version="$(vllm_installed_version "$VENV_DIR")"
  echo "vLLM: ${version:-not installed}"
  if [ "$LOCALVLLM_BACKEND" = "omni" ]; then
    version="$(vllm_omni_installed_version "$VENV_DIR")"
    echo "vLLM-Omni: ${version:-not installed}"
  fi
}

check_cmd() {
  local selector_arg="" chat=0 selector original_backend name status=0 arg

  for arg in "$@"; do
    case "$arg" in
      --chat) chat=1 ;;
      all|vllm|omni|text|llm|vllm-omni|vllm_omni|omni-vllm) selector_arg="$arg" ;;
      *) fail "usage: localvllm check [--chat] [BACKEND|all]" ;;
    esac
  done

  selector="$(localvllm_resolve_selector "$selector_arg")" || return 1
  original_backend="$LOCALVLLM_BACKEND"

  if [ "$selector" = "all" ]; then
    while IFS= read -r name; do
      echo
      echo "== $name =="
      localvllm_use_backend "$name" || continue
      check_one "$chat" || status=1
    done < <(localvllm_backend_list)
    localvllm_use_backend "$original_backend" >/dev/null 2>&1 || true
    return "$status"
  fi

  localvllm_use_backend "$selector" || return 1
  check_one "$chat"
}

check_one() {
  local chat="$1"
  local base models_json chat_response model health_ok=0

  pid_status
  require_api_tools

  base="$(api_base_url)"
  api_auth_curl_args

  echo
  echo "Health:"
  if curl "${AUTH_CURL_ARGS[@]}" --max-time 10 -fsS "$base/health" >/dev/null 2>&1; then
    health_ok=1
    echo "  /health is ready"
  elif curl "${AUTH_CURL_ARGS[@]}" --max-time 10 -fsS "$base/v1/models" >/dev/null 2>&1; then
    health_ok=1
    echo "  /health did not answer, but /v1/models is ready"
  fi
  if [ "$health_ok" -ne 1 ]; then
    echo "Error: API did not respond at $base/health or $base/v1/models" >&2
    return 1
  fi

  echo
  echo "API models:"
  if ! models_json="$(curl "${AUTH_CURL_ARGS[@]}" --max-time 10 -fsS "$base/v1/models")"; then
    echo "Error: API did not respond at $base/v1/models" >&2
    return 1
  fi
  jq -r '.data[]?.id' <<<"$models_json"

  if [ "$chat" -eq 1 ]; then
    model="$(jq -r '.data[0].id // empty' <<<"$models_json")"
    if [ -z "$model" ]; then
      echo "Error: no model is available for chat check" >&2
      return 1
    fi
    echo
    echo "Chat check ($model):"
    if ! chat_response="$(curl "${AUTH_CURL_ARGS[@]}" --max-time "$LOCALVLLM_HEALTH_CHECK_TIMEOUT" -fsS "$base/v1/chat/completions" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg model "$model" '{model: $model, messages: [{role: "user", content: "Reply with OK"}], max_tokens: 8, stream: false}')")"; then
      echo "Error: chat completion failed for $model at $base/v1/chat/completions" >&2
      return 1
    fi
    jq -r '.choices[0].message.content // .choices[0].text // .' <<<"$chat_response"
  fi
}

metrics_cmd() {
  local selector watch=0 arg base response
  local -a args=()

  for arg in "$@"; do
    case "$arg" in
      --watch) watch=1 ;;
      all|vllm|omni|text|llm|vllm-omni|vllm_omni|omni-vllm) args+=("$arg") ;;
      *) fail "usage: localvllm metrics [--watch] [BACKEND]" ;;
    esac
  done
  [ "${#args[@]}" -le 1 ] || fail "usage: localvllm metrics [--watch] [BACKEND]"
  selector="$(localvllm_resolve_selector "${args[0]:-}")" || return 1
  [ "$selector" != "all" ] || fail "choose one backend: localvllm metrics vllm | localvllm metrics omni"
  localvllm_use_backend "$selector" || return 1

  require_api_tools
  base="$(api_base_url)"
  api_auth_curl_args

  while :; do
    if ! response="$(curl "${AUTH_CURL_ARGS[@]}" --max-time 10 -fsS "$base/metrics")"; then
      echo "Error: /metrics is not available at $base/metrics" >&2
      return 1
    fi
    if [ "$watch" -eq 0 ]; then
      grep -E '^(# (HELP|TYPE) )?vllm:' <<<"$response" || printf '%s\n' "$response"
      return 0
    fi
    clear 2>/dev/null || true
    echo "Local $LOCALVLLM_BACKEND_LABEL metrics ($(date -u +%H:%M:%SZ))"
    grep -E '^(# (HELP|TYPE) )?vllm:' <<<"$response" || printf '%s\n' "$response"
    sleep 2
  done
}

logs_cmd() {
  local selector

  [ "$#" -le 1 ] || fail "usage: localvllm logs [BACKEND]"
  selector="$(localvllm_resolve_selector "${1:-}")" || return 1
  if [ "$selector" = "all" ]; then
    fail "choose one backend: localvllm logs vllm | localvllm logs omni"
  fi
  localvllm_use_backend "$selector" || return 1

  # vLLM's stdout/stderr is redirected to the backend log file by start.sh.
  # Prefer that file for useful output; fall back to journalctl only when it
  # does not exist yet.
  if [ -f "$LOG_FILE" ]; then
    tail -f "$LOG_FILE"
    return
  fi

  if has_user_service; then
    journalctl --user -u "$SERVICE_UNIT" -f
    return
  fi

  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"
  tail -f "$LOG_FILE"
}

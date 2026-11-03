# shellcheck shell=bash disable=SC2153,SC2154

localvllm_generate_candidates() {
  local candidate_sh="$1"
  local candidate_env="$2"
  local rebuild="$BIN_DIR/rebuild-config.sh"

  [ -x "$rebuild" ] || rebuild="$SCRIPT_DIR/rebuild-config.sh"
  [ -x "$rebuild" ] || {
    echo "Error: missing helper: $BIN_DIR/rebuild-config.sh" >&2
    return 1
  }

  "$rebuild" --backend "$LOCALVLLM_BACKEND" "$candidate_sh" "$candidate_env" >/dev/null
}

localvllm_candidates_differ() {
  local candidate_sh="$1"
  local candidate_env="$2"

  if [ -f "$SERVE_SH" ] && diff -q "$SERVE_SH" "$candidate_sh" >/dev/null 2>&1; then
    :
  else
    return 0
  fi

  if [ -f "$SERVE_ENV" ] && diff -q "$SERVE_ENV" "$candidate_env" >/dev/null 2>&1; then
    return 1
  fi

  return 0
}

localvllm_apply_candidates() {
  local candidate_sh="$1"
  local candidate_env="$2"

  mkdir -p "$CONF_DIR"
  install -m700 "$candidate_sh" "$SERVE_SH"
  install -m600 "$candidate_env" "$SERVE_ENV"

  if service_is_active; then
    if ! service_cmd restart; then
      echo "Error: the backend did not restart with the new configuration." >&2
      return 1
    fi
  else
    echo "Configuration updated; it will take effect on the next 'localvllm start'."
  fi
  return 0
}

apply_config_change() {
  local candidate_sh candidate_env status=0

  candidate_sh="$(mktemp "${TMPDIR:-/tmp}/localvllm-serve.XXXXXX")" || return 1
  candidate_env="$(mktemp "${TMPDIR:-/tmp}/localvllm-serve-env.XXXXXX")" || {
    rm -f "$candidate_sh"
    return 1
  }
  # shellcheck disable=SC2064
  trap "rm -f '$candidate_sh' '$candidate_env'" RETURN

  if ! localvllm_generate_candidates "$candidate_sh" "$candidate_env"; then
    echo "Error: failed to regenerate the $LOCALVLLM_BACKEND_LABEL launcher." >&2
    return 1
  fi

  if ! localvllm_candidates_differ "$candidate_sh" "$candidate_env"; then
    echo "Configuration is already up to date."
    return 0
  fi

  localvllm_apply_candidates "$candidate_sh" "$candidate_env" || status=$?
  return "$status"
}

reload_one() {
  local candidate_sh candidate_env old_id old_model new_id new_model

  candidate_sh="$(mktemp "${TMPDIR:-/tmp}/localvllm-reload.XXXXXX")" || return 1
  candidate_env="$(mktemp "${TMPDIR:-/tmp}/localvllm-reload-env.XXXXXX")" || {
    rm -f "$candidate_sh"
    return 1
  }
  # shellcheck disable=SC2064
  trap "rm -f '$candidate_sh' '$candidate_env'" RETURN

  if ! localvllm_generate_candidates "$candidate_sh" "$candidate_env"; then
    echo "Error: failed to regenerate the $LOCALVLLM_BACKEND_LABEL launcher; nothing was changed." >&2
    return 1
  fi

  if ! localvllm_candidates_differ "$candidate_sh" "$candidate_env"; then
    echo "No configuration changes detected for $LOCALVLLM_BACKEND_LABEL."
    echo "Active model: $(serve_env_value LOCALVLLM_ACTIVE_ID)"
    echo "The service was not restarted."
    return 0
  fi

  old_id="$(serve_env_value LOCALVLLM_ACTIVE_ID)"
  old_model="$(serve_env_value LOCALVLLM_MODEL)"
  new_id="$(config_assignment_value LOCALVLLM_ACTIVE_ID "$candidate_env" || true)"
  new_model="$(config_assignment_value LOCALVLLM_MODEL "$candidate_env" || true)"

  echo "Configuration changes detected for $LOCALVLLM_BACKEND_LABEL:"
  if [ "$old_id" != "$new_id" ] || [ "$old_model" != "$new_model" ]; then
    echo "  model: ${old_id:-none}${old_model:+ ($old_model)}"
    echo "      -> ${new_id:-none}${new_model:+ ($new_model)}"
  else
    echo "  model: ${new_id:-none}${new_model:+ ($new_model)}"
  fi
  echo

  localvllm_apply_candidates "$candidate_sh" "$candidate_env"
}

reload_cmd() {
  local selector original_backend name status=0

  [ "$#" -le 1 ] || fail "usage: localvllm reload [BACKEND|all]"
  selector="$(localvllm_resolve_selector "${1:-}")" || return 1
  original_backend="$LOCALVLLM_BACKEND"

  if [ "$selector" = "all" ]; then
    while IFS= read -r name; do
      echo
      echo "== $name =="
      localvllm_use_backend "$name" || continue
      reload_one || status=1
    done < <(localvllm_backend_list)
    localvllm_use_backend "$original_backend" >/dev/null 2>&1 || true
    return "$status"
  fi

  localvllm_use_backend "$selector" || return 1
  reload_one
}

update_cmd() {
  local updater="$BIN_DIR/update-localvllm.sh" arg all=0
  local -a args=("$@")

  [ -x "$updater" ] || updater="$SCRIPT_DIR/update-localvllm.sh"
  [ -x "$updater" ] || fail "missing updater: $BIN_DIR/update-localvllm.sh"

  for arg in "${args[@]}"; do
    case "$arg" in --all) all=1 ;; esac
  done
  if [ "$all" = 0 ]; then
    args=(--backend "$LOCALVLLM_BACKEND" "${args[@]}")
  fi

  "$updater" "${args[@]}"
}

version_cmd() {
  local selector original_backend name device swap_binary swap_version

  [ "$#" -le 1 ] || fail "usage: localvllm version [BACKEND|all]"
  if [ "$#" -eq 1 ]; then
    selector="$(localvllm_resolve_selector "$1")" || return 1
  elif [ "${LOCALVLLM_BACKEND_REQUESTED:-0}" = "1" ]; then
    selector="$LOCALVLLM_BACKEND"
  else
    selector="all"
  fi
  original_backend="$LOCALVLLM_BACKEND"

  echo "Local vLLM manager: $LOCALVLLM_VERSION"
  echo "Install directory: $AI_DIR"
  if swap_binary="$(localvllm_swap_bin)"; then
    swap_version="$(localvllm_swap_version "$swap_binary")" || swap_version=unknown
    echo "llama-swap: ${swap_version:-unknown} ($swap_binary)"
  else
    echo "llama-swap: not installed (optional)"
  fi

  if command -v nvidia-smi >/dev/null 2>&1; then
    device="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | paste -sd', ' -)" || device=""
    if [ -n "$device" ]; then echo "GPU: $device"; else echo 'GPU: NVIDIA device query unavailable'; fi
  elif command -v rocm-smi >/dev/null 2>&1 || [ -e /dev/kfd ]; then
    echo "GPU: AMD ROCm"
  else
    echo "GPU: none detected"
  fi

  if [ "$selector" = "all" ]; then
    while IFS= read -r name; do
      localvllm_use_backend "$name" || continue
      version_one
    done < <(localvllm_backend_list)
  else
    localvllm_use_backend "$selector" || return 1
    version_one
  fi

  localvllm_use_backend "$original_backend" >/dev/null 2>&1 || true
}

version_one() {
  local vllm_version omni_version py_version active_id active_model port

  echo
  echo "== $LOCALVLLM_BACKEND ($LOCALVLLM_BACKEND_LABEL) =="
  echo "Serving mode: $(localvllm_serving_mode)"
  vllm_version="$(vllm_installed_version "$VENV_DIR")"
  echo "vLLM: ${vllm_version:-not installed}"
  if [ "$LOCALVLLM_BACKEND" = "omni" ]; then
    omni_version="$(vllm_omni_installed_version "$VENV_DIR")"
    echo "vLLM-Omni: ${omni_version:-not installed}"
  fi

  if [ -x "$VENV_DIR/bin/python" ]; then
    py_version="$(python_version "$VENV_DIR/bin/python")" || py_version=""
    echo "Python: ${py_version:-unknown}"
  else
    echo "Python: virtual environment missing"
  fi

  if localvllm_resolve_active "$MODELS_DIR" "$ACTIVE_MODEL_FILE" "$OVERRIDES_DIR" 2>/dev/null; then
    active_id="$ACTIVE_ID"
    active_model="$ACTIVE_MODEL"
    echo "Active model: $active_id ($ACTIVE_FORMAT)"
    echo "Model path/id: $active_model"
  else
    echo "Active model: none"
  fi

  port="$([ -f "$PORT_FILE" ] && cat "$PORT_FILE" || printf '%s' "$LOCALVLLM_DEFAULT_PORT")"
  echo "Endpoint: http://${LOCALVLLM_LISTEN_HOST}:${port}/v1"
  if service_is_active; then
    echo "Service: running"
  elif has_user_service; then
    echo "Service: stopped"
  else
    echo "Service: not installed"
  fi
}

uninstall_cmd() {
  local uninstaller="$BIN_DIR/uninstall-localvllm.sh"
  local -a args=("$@")

  [ -x "$uninstaller" ] || uninstaller="$SCRIPT_DIR/uninstall-localvllm.sh"
  [ -x "$uninstaller" ] || fail "missing uninstaller: $BIN_DIR/uninstall-localvllm.sh"

  if [ "${LOCALVLLM_BACKEND_REQUESTED:-0}" = "1" ]; then
    args=(--backend "$LOCALVLLM_BACKEND" "${args[@]}")
  fi

  "$uninstaller" "${args[@]}"
}

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

  local backup file was_active=0
  backup="$(mktemp -d)" || return 1
  mkdir -p "$CONF_DIR"
  for file in "$SERVE_SH" "$SERVE_ENV"; do
    if [ -f "$file" ]; then cp -a "$file" "$backup/$(basename "$file")" || return 1; fi
  done
  service_is_active && was_active=1
  if ! install -m700 "$candidate_sh" "$SERVE_SH" ||
     ! install -m600 "$candidate_env" "$SERVE_ENV" ||
     { [ "$was_active" = 1 ] && { echo 'Restarting this backend to apply configuration; active requests may be interrupted.'; ! service_cmd restart; }; }; then
    for file in "$SERVE_SH" "$SERVE_ENV"; do
      if [ -f "$backup/$(basename "$file")" ]; then cp -a "$backup/$(basename "$file")" "$file"; else rm -f "$file"; fi
    done
    if [ "$was_active" = 1 ]; then service_cmd restart || echo 'Warning: previous configuration restored, but service recovery failed.' >&2; fi
    rm -rf "$backup"
    echo 'Error: configuration failed; previous launcher restored.' >&2
    return 1
  fi
  rm -rf "$backup"
  [ "$was_active" = 1 ] || echo "Configuration updated; it will take effect on the next 'localvllm start'."
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
  local vllm_version omni_version py_version active_id active_model port runtime loaded

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
  if vllm_venv_has_previous "$VENV_DIR"; then
    echo "Rollback: available ('localvllm rollback $LOCALVLLM_BACKEND')"
  fi

  if localvllm_resolve_active "$MODELS_DIR" "$ACTIVE_MODEL_FILE" "$OVERRIDES_DIR" 2>/dev/null; then
    active_id="$ACTIVE_ID"
    active_model="$ACTIVE_MODEL"
    echo "Selected for direct mode: $active_id ($ACTIVE_FORMAT)"
    echo "Model path/id: $active_model"
  else
    echo "Selected for direct mode: none"
  fi

  runtime="$(model_runtime_info)" || return 1
  if [ "$(jq -r .runtime_state_available <<< "$runtime")" = true ]; then
    loaded="$(jq -r '.active_models | join(", ")' <<< "$runtime")"
    echo "Loaded models: ${loaded:-none}"
  else
    echo "Loaded models: unavailable (check service/API access)"
  fi

  port="$([ -f "$PORT_FILE" ] && cat "$PORT_FILE" || printf '%s' "$LOCALVLLM_DEFAULT_PORT")"
  echo "Endpoint: http://$(localvllm_url_host "$LOCALVLLM_LISTEN_HOST"):${port}/v1"
  if service_is_active; then
    echo "Service: running"
  elif has_user_service; then
    echo "Service: stopped"
  else
    echo "Service: not installed"
  fi
}

rollback_describe() {
  local venv="$1" version

  version="vLLM $(vllm_installed_version "$venv")"
  if [ "$LOCALVLLM_BACKEND" = "omni" ]; then
    version="$version, vLLM-Omni $(vllm_omni_installed_version "$venv")"
  fi
  printf '%s\n' "$version"
}

# rollback_activate WAS_ACTIVE: make the environment now at $VENV_DIR live --
# it must import, its launcher is regenerated for it (supported flags can
# differ between releases), and a service that was running must become ready.
rollback_activate() {
  local was_active="$1" rebuild="$BIN_DIR/rebuild-config.sh"

  vllm_verify_install "$VENV_DIR" >/dev/null || return 1
  if [ "$LOCALVLLM_BACKEND" = "omni" ]; then
    vllm_omni_verify_install "$VENV_DIR" >/dev/null || return 1
  fi
  [ -x "$rebuild" ] || rebuild="$SCRIPT_DIR/rebuild-config.sh"
  if [ -x "$rebuild" ] && localvllm_require_start_model >/dev/null 2>&1; then
    "$rebuild" --backend "$LOCALVLLM_BACKEND" >/dev/null || return 1
  fi
  if [ "$was_active" = 1 ]; then
    localvllm_start_service || return 1
  fi
  return 0
}

# rollback_cmd [BACKEND]: swap one backend's environment with the one its last
# successful update replaced. Running it again returns to the newer one. The
# other backend, models, keys and settings are not touched.
rollback_cmd() {
  local selector was_active=0 previous

  [ "$#" -le 1 ] || fail "usage: localvllm rollback [BACKEND]"
  if [ "$#" -eq 1 ]; then
    selector="$(localvllm_resolve_selector "$1")" || return 1
    [ "$selector" != "all" ] || fail "roll back one backend at a time: localvllm rollback vllm|omni"
    localvllm_use_backend "$selector" || return 1
  fi

  previous="$(vllm_venv_previous_dir "$VENV_DIR")"
  if ! vllm_venv_has_previous "$VENV_DIR"; then
    fail "no previous $LOCALVLLM_BACKEND_LABEL environment to roll back to.
One is kept after each successful 'localvllm update' that changed packages
(unless LOCALVLLM_KEEP_PREVIOUS=0)."
  fi

  echo "$LOCALVLLM_BACKEND_LABEL ($LOCALVLLM_BACKEND)"
  echo "  current:   $(rollback_describe "$VENV_DIR")"
  echo "  restoring: $(rollback_describe "$previous")"
  echo

  if localvllm_service_is_active; then
    was_active=1
    echo "Stopping $LOCALVLLM_SERVICE_NAME; active requests will be interrupted."
    localvllm_stop_service || fail "could not stop $LOCALVLLM_SERVICE_NAME; nothing was changed"
  fi

  if ! vllm_venv_swap_previous "$VENV_DIR" "$CONF_DIR"; then
    [ "$was_active" = 0 ] || localvllm_start_service || true
    fail "could not swap the environments; nothing was changed"
  fi

  if ! rollback_activate "$was_active"; then
    echo "Error: the restored environment did not work; switching back." >&2
    localvllm_stop_service >/dev/null 2>&1 || true
    vllm_venv_swap_previous "$VENV_DIR" "$CONF_DIR" ||
      fail "could not switch back automatically; run 'localvllm rollback $LOCALVLLM_BACKEND' again"
    rollback_activate "$was_active" || true
    fail "rollback failed; the environment that was active before is in use again"
  fi

  echo "Rolled back $LOCALVLLM_BACKEND to $(rollback_describe "$VENV_DIR")."
  echo "Run 'localvllm rollback $LOCALVLLM_BACKEND' again to return to the newer environment."
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

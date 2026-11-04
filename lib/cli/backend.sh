# shellcheck shell=bash disable=SC2153,SC2154

backend_usage() {
  cat <<EOF
Usage: localvllm backend COMMAND

Backends are fully isolated engines sharing one manager:
  vllm   plain vLLM: text, embeddings, and reranking
  omni   vLLM-Omni: text, image, audio, video, and action generation

Commands:
  list             Show both backends, versions, ports, services, and models
  install BACKEND  Install or repair one backend without changing the default
  default BACKEND  Set the backend used when --backend is omitted
  help             Show this help

Examples:
  localvllm backend list
  localvllm backend install omni
  localvllm backend default omni
EOF
}

backend_cmd() {
  local sub="${1:-help}"

  [ "$#" -eq 0 ] || shift

  case "$sub" in
    list) backend_list_cmd "$@" ;;
    install) backend_install_cmd "$@" ;;
    default) backend_default_cmd "$@" ;;
    help|-h|--help) backend_usage ;;
    *)
      backend_usage >&2
      return 2
      ;;
  esac
}

backend_list_cmd() {
  local original_backend="$LOCALVLLM_BACKEND"
  local name installed version port service_status model active_id default_marker

  [ "$#" -eq 0 ] || fail "usage: localvllm backend list"

  printf '%-3s %-7s %-9s %-18s %-6s %-13s %s\n' \
    "" "BACKEND" "INSTALLED" "VERSION" "PORT" "SERVICE" "CONFIGURED MODEL"

  while IFS= read -r name; do
    localvllm_use_backend "$name" || continue

    if localvllm_backend_installed "$name"; then
      installed="yes"
      version="$(localvllm_backend_version "$name")"
      [ -n "$version" ] || version="unknown"
    else
      installed="no"
      version="-"
    fi

    port="$([ -f "$PORT_FILE" ] && cat "$PORT_FILE" || printf '%s' "$LOCALVLLM_DEFAULT_PORT")"

    if service_is_active; then
      service_status="running"
    elif has_user_service; then
      service_status="stopped"
    else
      service_status="not installed"
    fi

    active_id=""
    if localvllm_resolve_active "$MODELS_DIR" "$ACTIVE_MODEL_FILE" "$OVERRIDES_DIR" 2>/dev/null; then active_id="$ACTIVE_ID"; fi
    model="${active_id:--}"

    default_marker=""
    [ "$name" = "$LOCALVLLM_DEFAULT_BACKEND" ] && default_marker="*"

    printf '%-3s %-7s %-9s %-18s %-6s %-13s %s\n' \
      "$default_marker" "$name" "$installed" "$version" "$port" "$service_status" "$model"
  done < <(localvllm_backend_list)

  echo
  echo "* = default backend (used when --backend is omitted); it is not necessarily running."
  echo "View live models: localvllm --backend BACKEND models"
  echo "Engine packages: vllm (plain vLLM), omni (vllm-omni with --omni)"
  echo "Both backends use separate venvs, models, keys, ports, and services."

  localvllm_use_backend "$original_backend" >/dev/null 2>&1 || true
}

backend_install_cmd() {
  local requested="${1:-}"
  local installer name
  local -a names=()

  if [ -z "$requested" ] || [ "$#" -ne 1 ]; then
    fail "usage: localvllm backend install BACKEND  (vllm, omni, or all)"
  fi

  if [ "$requested" = "all" ]; then
    while IFS= read -r name; do
      names+=("$name")
    done < <(localvllm_backend_list)
  else
    name="$(localvllm_backend_name "$requested")" ||
      fail "unknown backend: $requested (use vllm or omni)"
    names=("$name")
  fi

  installer="$BIN_DIR/install-localvllm.sh"
  [ -x "$installer" ] || installer="$SCRIPT_DIR/install-localvllm.sh"
  [ -x "$installer" ] || fail "missing installer: $BIN_DIR/install-localvllm.sh"

  for name in "${names[@]}"; do
    echo "Installing backend: $name"
    "$installer" --dir "$AI_DIR" --backend "$name" --skip-system
  done
}

backend_default_cmd() {
  local requested="${1:-}"
  local name conf_file

  if [ -z "$requested" ] || [ "$#" -ne 1 ]; then
    fail "usage: localvllm backend default BACKEND  (vllm or omni)"
  fi

  name="$(localvllm_backend_name "$requested")" ||
    fail "unknown backend: $requested (use vllm or omni)"

  conf_file="$CONF_ROOT/localvllm.conf"
  [ -f "$conf_file" ] || fail "missing configuration: $conf_file"

  set_conf_value "$conf_file" LOCALVLLM_DEFAULT_BACKEND "$name" ||
    fail "failed to update $conf_file"

  echo "Default backend: $name"
  echo "Commands without --backend now use $name."
}

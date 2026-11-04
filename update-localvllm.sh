#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2153,SC2317
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$SCRIPT_DIR/../conf/localvllm.conf" ]; then
  # shellcheck source=/dev/null
  . "$SCRIPT_DIR/../conf/localvllm.conf"
elif [ -f "$SCRIPT_DIR/localvllm.conf" ]; then
  # shellcheck source=localvllm.conf
  . "$SCRIPT_DIR/localvllm.conf"
else
  echo "Error: localvllm.conf not found." >&2
  exit 1
fi

source_localvllm_common() {
  local candidate

  for candidate in "$SCRIPT_DIR/lib/common.sh" "$SCRIPT_DIR/../lib/common.sh"; do
    if [ -f "$candidate" ]; then
      # shellcheck source=/dev/null
      . "$candidate"
      return 0
    fi
  done

  echo "Error: missing Local vLLM library: common.sh" >&2
  exit 1
}
source_localvllm_common
source_localvllm_lib install.sh
source_localvllm_lib router.sh

AI_DIR="$(resolve_ai_dir)"
CONF_ROOT="$AI_DIR/$LOCALVLLM_CONF_SUBDIR"
BIN_DIR="$AI_DIR/$LOCALVLLM_BIN_SUBDIR"
LIB_DIR="$AI_DIR/$LOCALVLLM_LIB_SUBDIR"
LOCALVLLM_SOURCE_DIR=""
START_AFTER_UPDATE=1
SCRIPTS_ONLY=0
VLLM_ONLY=0
UPDATE_BACKENDS=()
TMP_DIR=""
STAGED_UPDATER=""
STAGED_CLI=""

localvllm_capture_global_runtime
localvllm_acquire_global_lock
localvllm_operation_log update

log() {
  printf '\n==> %s\n' "$*"
}

warn() {
  echo "Warning: $*" >&2
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

usage() {
  cat <<EOF
Usage: $0 [--no-start] [--backend NAME|all] [--scripts-only] [--vllm-only]

Updates the manager, selected engine packages, and installed managed llama-swap.

Options:
  --backend NAME   Update vllm, omni, or all (default: selected backend)
  --all            Update every installed backend
  --no-start       Leave previously running services stopped
  --scripts-only   Refresh helper scripts/config; keep engine/router versions
  --vllm-only      Upgrade engine packages only; keep manager/router versions
  -h, --help       Show this help

vLLM and vLLM-Omni use separate venvs. When pinning vLLM-Omni, keep
VLLM_OMNI_VERSION on the same release line as VLLM_VERSION.
EOF
}

add_backend() {
  local requested="$1" name

  if [ "$requested" = "all" ]; then
    while IFS= read -r name; do
      UPDATE_BACKENDS+=("$name")
    done < <(localvllm_backend_list)
    return 0
  fi

  name="$(localvllm_backend_name "$requested")" ||
    fail "unknown backend: $requested (use vllm, omni, or all)"
  UPDATE_BACKENDS+=("$name")
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-start) START_AFTER_UPDATE=0 ;;
    --scripts-only) SCRIPTS_ONLY=1 ;;
    --vllm-only) VLLM_ONLY=1 ;;
    --backend)
      [ "$#" -ge 2 ] || fail "missing name after --backend"
      add_backend "$2"
      shift
      ;;
    --backend=*) add_backend "${1#--backend=}" ;;
    --all) add_backend all ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

if [ "$SCRIPTS_ONLY" -eq 1 ] && [ "$VLLM_ONLY" -eq 1 ]; then
  fail "--scripts-only and --vllm-only cannot be combined"
fi

if [ "${#UPDATE_BACKENDS[@]}" -eq 0 ]; then
  add_backend "${LOCALVLLM_BACKEND:-$LOCALVLLM_DEFAULT_BACKEND}"
fi

declare -A SEEN=()
UNIQUE=()
for BACKEND in "${UPDATE_BACKENDS[@]}"; do
  [ -n "${SEEN[$BACKEND]+x}" ] && continue
  SEEN["$BACKEND"]=1
  UNIQUE+=("$BACKEND")
done
UPDATE_BACKENDS=("${UNIQUE[@]}")

has_user_service() {
  command -v systemctl >/dev/null 2>&1 &&
    systemctl --user cat "$LOCALVLLM_SERVICE_NAME" >/dev/null 2>&1
}

service_is_active() {
  if has_user_service && systemctl --user is-active --quiet "${LOCALVLLM_SERVICE_NAME%.service}" 2>/dev/null; then
    return 0
  fi
  pid_file_matches_process "$PID_FILE" "$PID_START_FILE"
}

stop_localvllm() {
  if has_user_service; then
    log "Stopping $LOCALVLLM_BACKEND_LABEL service"
    if ! systemctl --user stop "$LOCALVLLM_SERVICE_NAME"; then
      warn "could not stop $LOCALVLLM_SERVICE_NAME"
      return 1
    fi
  elif [ -x "$BIN_DIR/stop.sh" ]; then
    log "Stopping $LOCALVLLM_BACKEND_LABEL"
    if ! "$BIN_DIR/stop.sh" "$LOCALVLLM_BACKEND"; then
      warn "could not stop $LOCALVLLM_BACKEND_LABEL"
      return 1
    fi
  fi
  return 0
}

start_localvllm() {
  if has_user_service; then
    log "Starting $LOCALVLLM_BACKEND_LABEL service"
    if ! systemctl --user start "$LOCALVLLM_SERVICE_NAME"; then
      warn "could not start $LOCALVLLM_SERVICE_NAME"
      return 1
    fi
  elif [ -x "$BIN_DIR/start.sh" ]; then
    log "Starting $LOCALVLLM_BACKEND_LABEL"
    if ! "$BIN_DIR/start.sh" "$LOCALVLLM_BACKEND"; then
      warn "could not start $LOCALVLLM_BACKEND_LABEL"
      return 1
    fi
  fi
  return 0
}

localvllm_archive_url() {
  # GitHub resolves unqualified branches and tags; explicit refs stay explicit.
  printf '%s/%s.tar.gz\n' "${LOCALVLLM_TARBALL_BASE:-https://github.com/hossbit/local-ai-server-vllm/archive}" "${LOCALVLLM_REF:-main}"
}

resolve_localvllm_source_dir() {
  local archive_file extracted

  if [ -f "$SCRIPT_DIR/install-localvllm.sh" ] && [ -f "$SCRIPT_DIR/localvllm.conf" ]; then
    LOCALVLLM_SOURCE_DIR="$SCRIPT_DIR"
    return 0
  fi

  if [ -n "${LOCALVLLM_LOCAL_SOURCE_DIR:-}" ]; then
    LOCALVLLM_SOURCE_DIR="$(expand_path "$LOCALVLLM_LOCAL_SOURCE_DIR")"
    if [ ! -f "$LOCALVLLM_SOURCE_DIR/install-localvllm.sh" ] || [ ! -f "$LOCALVLLM_SOURCE_DIR/localvllm.conf" ]; then
      fail "LOCALVLLM_LOCAL_SOURCE_DIR=$LOCALVLLM_SOURCE_DIR is not a Local vLLM checkout"
    fi
    log "Using local Local vLLM checkout: $LOCALVLLM_SOURCE_DIR"
    return 0
  fi

  log "Fetching Local vLLM helper scripts"
  LOCALVLLM_SOURCE_DIR="$TMP_DIR/localvllm-source"

  if have git; then
    git clone --depth 1 --branch "${LOCALVLLM_REF:-main}" \
      "${LOCALVLLM_REPO_URL:-https://github.com/hossbit/local-ai-server-vllm.git}" \
      "$LOCALVLLM_SOURCE_DIR"
  else
    archive_file="$TMP_DIR/localvllm.tar.gz"
    curl -4 -fsSL "$(localvllm_archive_url)" -o "$archive_file"
    tar -xzf "$archive_file" -C "$TMP_DIR"
    extracted="$(find "$TMP_DIR" -mindepth 1 -maxdepth 1 -type d | while IFS= read -r dir; do
      [ -f "$dir/install-localvllm.sh" ] && { printf '%s\n' "$dir"; break; }
    done)"
    [ -n "$extracted" ] || fail "could not find the extracted Local vLLM source directory"
    mv "$extracted" "$LOCALVLLM_SOURCE_DIR"
  fi

  [ -f "$LOCALVLLM_SOURCE_DIR/localvllm.conf" ] || fail "downloaded Local vLLM source is missing localvllm.conf"
  [ -x "$LOCALVLLM_SOURCE_DIR/localvllm" ] || fail "downloaded Local vLLM source is missing the localvllm CLI"
}

refresh_scripts() (
  set -e
  local previous_conf backup refresh_status

  if [ "$LOCALVLLM_SOURCE_DIR" = "$AI_DIR" ]; then
    return 1
  fi

  backup="$TMP_DIR/refresh-backup"
  rm -rf "$backup" || return 1
  mkdir -p "$backup" || return 1
  if [ -d "$BIN_DIR" ]; then
    cp -a "$BIN_DIR" "$backup/bin" || return 1
  fi
  if [ -d "$LIB_DIR" ]; then
    cp -a "$LIB_DIR" "$backup/lib" || return 1
  fi
  if [ -f "$CONF_ROOT/localvllm.conf" ]; then
    cp "$CONF_ROOT/localvllm.conf" "$backup/localvllm.conf" || return 1
  fi
  if [ -f "$CONF_ROOT/.localvllm-config.sha256" ]; then
    cp "$CONF_ROOT/.localvllm-config.sha256" "$backup/config.sha256" || return 1
  fi

  # shellcheck disable=SC2329 # Invoked by the EXIT trap.
  restore_refresh_backup() {
    if [ -d "$backup/bin" ]; then
      rm -rf "$BIN_DIR"
      cp -a "$backup/bin" "$BIN_DIR"
    fi
    if [ -d "$backup/lib" ]; then
      rm -rf "$LIB_DIR"
      cp -a "$backup/lib" "$LIB_DIR"
    fi
    if [ -f "$backup/localvllm.conf" ]; then
      cp "$backup/localvllm.conf" "$CONF_ROOT/localvllm.conf"
    fi
    if [ -f "$backup/config.sha256" ]; then
      cp "$backup/config.sha256" "$CONF_ROOT/.localvllm-config.sha256"
    else
      rm -f "$CONF_ROOT/.localvllm-config.sha256"
    fi
  }
  # An ERR trap is suppressed when this function is tested with `if !`.
  # Explicit checks below return failure; EXIT restores the backup on failure.
  trap 'refresh_status=$?; if [ "$refresh_status" -ne 0 ]; then restore_refresh_backup; fi' EXIT

  log "Refreshing helper scripts"

  for SCRIPT in localvllm start.sh stop.sh rebuild-config.sh update-localvllm.sh uninstall-localvllm.sh install-localvllm.sh; do
    [ -f "$LOCALVLLM_SOURCE_DIR/$SCRIPT" ] || continue
    case "$SCRIPT" in
      localvllm)
        install -m755 "$LOCALVLLM_SOURCE_DIR/$SCRIPT" "$TMP_DIR/localvllm.staged" || return 1
        ;;
      update-localvllm.sh)
        install -m755 "$LOCALVLLM_SOURCE_DIR/$SCRIPT" "$TMP_DIR/update-localvllm.staged" || return 1
        ;;
      *)
        install -m755 "$LOCALVLLM_SOURCE_DIR/$SCRIPT" "$BIN_DIR/$SCRIPT" || return 1
        ;;
    esac
  done

  previous_conf="$CONF_ROOT/localvllm.conf"
  if [ -f "$previous_conf" ]; then
    cp "$previous_conf" "$LIB_DIR/localvllm.conf.previous" || return 1
    install -m600 "$LOCALVLLM_SOURCE_DIR/localvllm.conf" "$CONF_ROOT/localvllm.conf" || return 1
    append_runtime_tuning "$LIB_DIR/localvllm.conf.previous" "updater" || return 1
    rm -f "$LIB_DIR/localvllm.conf.previous" || return 1
  else
    install -m600 "$LOCALVLLM_SOURCE_DIR/localvllm.conf" "$CONF_ROOT/localvllm.conf" || return 1
  fi
  write_config_marker "$LOCALVLLM_SOURCE_DIR/localvllm.conf" "$CONF_ROOT" || return 1

  if [ -d "$LOCALVLLM_SOURCE_DIR/lib" ]; then
    mkdir -p "$LIB_DIR" || return 1
    while IFS= read -r path; do
      rel="${path#"$LOCALVLLM_SOURCE_DIR/lib/"}"
      mkdir -p "$LIB_DIR/$(dirname "$rel")" || return 1
      install -m644 "$path" "$LIB_DIR/$rel" || return 1
    done < <(find "$LOCALVLLM_SOURCE_DIR/lib" -type f | sort)
  fi

  for BACKEND in $(localvllm_backend_list); do
    write_backend_profile "$CONF_ROOT" "$BACKEND" || return 1
  done

  if [ -x "$BIN_DIR/localvllm" ]; then
    mkdir -p "$LOCALVLLM_USER_BIN_DIR" || return 1
    ln -sfn "$BIN_DIR/localvllm" "$LOCALVLLM_USER_BIN_DIR/$LOCALVLLM_CLI_NAME" || return 1
  fi

  for BACKEND in $(localvllm_backend_list); do
    localvllm_use_backend "$BACKEND" || continue
    if localvllm_backend_installed "$BACKEND"; then
      mkdir -p "$LOCALVLLM_SYSTEMD_USER_DIR" || return 1
      write_systemd_user_service "$SERVICE_FILE" "$BIN_DIR" "$BACKEND" || return 1
    fi
  done

  systemctl --user daemon-reload >/dev/null 2>&1 || true
  return 0
)

commit_staged_helpers() {
  if [ -n "$STAGED_CLI" ] && [ -f "$STAGED_CLI" ]; then
    install -m755 "$STAGED_CLI" "$BIN_DIR/localvllm"
    mkdir -p "$LOCALVLLM_USER_BIN_DIR"
    ln -sfn "$BIN_DIR/localvllm" "$LOCALVLLM_USER_BIN_DIR/$LOCALVLLM_CLI_NAME"
  fi
  if [ -n "$STAGED_UPDATER" ] && [ -f "$STAGED_UPDATER" ]; then
    install -m755 "$STAGED_UPDATER" "$BIN_DIR/update-localvllm.sh"
  fi
}

LATEST_VLLM=""
LATEST_OMNI=""

target_version() {
  local var="$1"
  local latest_kind="$2"
  local value="${!var}"

  if [ "$value" != "latest" ]; then
    printf '%s\n' "$value"
    return 0
  fi

  if [ "$latest_kind" = "vllm" ]; then
    if [ -z "$LATEST_VLLM" ]; then
      LATEST_VLLM="$(vllm_latest_version 2>/dev/null)" || return 1
    fi
    printf '%s\n' "$LATEST_VLLM"
  else
    if [ -z "$LATEST_OMNI" ]; then
      LATEST_OMNI="$(vllm_omni_latest_version 2>/dev/null)" || return 1
    fi
    printf '%s\n' "$LATEST_OMNI"
  fi
}

# package_need_for_backend NAME -> prints vllm, omni, both, or none.
package_need_for_backend() {
  local backend="$1"
  local installed_vllm installed_omni target_vllm target_omni need=""

  localvllm_use_backend "$backend" || return 1
  localvllm_backend_installed "$backend" || { printf 'none\n'; return 0; }

  installed_vllm="$(vllm_installed_version "$VENV_DIR")"
  installed_omni="$(vllm_omni_installed_version "$VENV_DIR")"

  if [ "$backend" = "vllm" ]; then
    if target_vllm="$(target_version VLLM_VERSION vllm)"; then
      if [ -n "$target_vllm" ] && ! versions_match "$target_vllm" "$installed_vllm"; then
        need=vllm
      fi
    else
      warn "could not check PyPI for the latest vLLM version; keeping the installed version"
    fi
  else
    if ! localvllm_omni_python_ok "$VENV_DIR/bin/python"; then
      need=omni
    fi
    if target_omni="$(target_version VLLM_OMNI_VERSION omni)"; then
      if [ -n "$target_omni" ] && ! versions_match "$target_omni" "$installed_omni"; then
        need=omni
      fi
    else
      warn "could not check PyPI for the latest vLLM-Omni version; keeping the installed version"
    fi

    # When vLLM itself is pinned, honor the pin for the omni venv too. When it
    # is "latest", let vllm-omni resolve its matching vLLM dependency.
    if [ "${VLLM_VERSION:-latest}" != "latest" ] && ! versions_match "$VLLM_VERSION" "$installed_vllm"; then
      need="${need:+$need,}vllm"
    fi
  fi

  printf '%s\n' "${need:-none}"
}

declare -A OLD_VENVS=()

update_backend_package() {
  local backend="$1"
  local need="$2"
  local pip_log="$AI_DIR/$LOCALVLLM_LOGS_SUBDIR/update-packages-$backend.log"
  local stage_venv old_venv=""

  [ "$need" = "none" ] && return 0
  localvllm_use_backend "$backend" || return 1

  mkdir -p "$(dirname "$pip_log")"
  : >> "$pip_log"

  if [ "$backend" = omni ] && ! localvllm_omni_python_ok "$VENV_DIR/bin/python"; then
    local compatible_python
    compatible_python="$(localvllm_find_compatible_python)" || return 1
    stage_venv="$(mktemp -d "${VENV_DIR}.update.XXXXXX")" || return 1
    if ! vllm_venv_create "$stage_venv" "$compatible_python"; then
      rm -rf "$stage_venv"
      return 1
    fi
  else
    stage_venv="$(vllm_venv_stage_update "$VENV_DIR")" || {
      echo "Error: could not stage an update of $VENV_DIR." >&2
      return 1
    }
  fi

  if ! vllm_bootstrap_pip "$stage_venv" "$pip_log"; then
    rm -rf "$stage_venv"
    return 1
  fi

  if [ "$backend" = "omni" ]; then
    log "Upgrading vLLM + vLLM-Omni for $backend in one resolver transaction"
    if ! vllm_pip_install_both "$stage_venv" "$VLLM_VERSION" "$VLLM_OMNI_VERSION" \
      "$VLLM_OMNI_EXTRAS" "$VLLM_PIP_ARGS" \
      "${VLLM_OMNI_PIP_ARGS:-$VLLM_PIP_ARGS}" "$pip_log"; then
      rm -rf "$stage_venv"
      return 1
    fi
  else
    log "Upgrading vLLM for $backend"
    if ! vllm_pip_install "$stage_venv" "$VLLM_VERSION" "$VLLM_PIP_ARGS" "$pip_log"; then
      rm -rf "$stage_venv"
      return 1
    fi
  fi

  if ! vllm_verify_install "$stage_venv" >/dev/null; then
    echo "Error: vLLM verification failed for backend $backend." >&2
    rm -rf "$stage_venv"
    return 1
  fi
  if [ "$backend" = "omni" ] && ! vllm_omni_verify_install "$stage_venv" >/dev/null; then
    echo "Error: vLLM-Omni verification failed for backend $backend; keep vLLM and vLLM-Omni on matching release lines." >&2
    rm -rf "$stage_venv"
    return 1
  fi
  if ! vllm_pip_check "$stage_venv"; then
    echo "Error: pip check failed for backend $backend; refusing an inconsistent environment." >&2
    rm -rf "$stage_venv"
    return 1
  fi

  old_venv="$(vllm_venv_commit_update "$VENV_DIR" "$stage_venv")" || {
    echo "Error: could not install the new environment for backend $backend." >&2
    return 1
  }
  OLD_VENVS["$backend"]="$old_venv"
  return 0
}

print_versions() {
  local backend version binary
  version="$( (unset LOCALVLLM_VERSION; . "$CONF_ROOT/localvllm.conf"; printf '%s' "$LOCALVLLM_VERSION") )"
  echo "Manager: $version"
  if binary="$(localvllm_swap_bin)"; then
    version="$(localvllm_swap_version "$binary")" || version=unknown
    echo "llama-swap: ${version:-unknown} ($binary)"
  fi

  echo
  echo "Current versions:"
  for backend in $(localvllm_backend_list); do
    localvllm_use_backend "$backend" || continue
    version="$(vllm_installed_version "$VENV_DIR")"
    echo "  $backend: vLLM ${version:-not installed}"
    if [ "$backend" = "omni" ]; then
      version="$(vllm_omni_installed_version "$VENV_DIR")"
      echo "  $backend: vLLM-Omni ${version:-not installed}"
    fi
  done
}

###############################################################################
# REQUIREMENTS AND SOURCE
###############################################################################

for COMMAND in curl jq tar; do
  command -v "$COMMAND" >/dev/null 2>&1 || fail "required command not found: $COMMAND"
done

case "$(uname -m)" in
  x86_64|aarch64|arm64) ;;
  *) fail "unsupported architecture: $(uname -m)" ;;
esac

mkdir -p "$AI_DIR" "$BIN_DIR" "$LIB_DIR" "$CONF_ROOT"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

if [ "$VLLM_ONLY" -eq 0 ]; then
  resolve_localvllm_source_dir
fi

###############################################################################
# DECIDE WHAT NEEDS CHANGING
###############################################################################

declare -A NEED=()
declare -A WAS_RUNNING=()
ANY_PACKAGE_CHANGE=0
ANY_BACKEND=0

for BACKEND in "${UPDATE_BACKENDS[@]}"; do
  localvllm_use_backend "$BACKEND" || continue
  if ! localvllm_backend_installed "$BACKEND"; then
    warn "backend '$BACKEND' is not installed; skipping (use: localvllm backend install $BACKEND)"
    continue
  fi
  ANY_BACKEND=1
  if service_is_active; then
    WAS_RUNNING["$BACKEND"]=1
  fi
  if [ "$SCRIPTS_ONLY" -eq 1 ]; then
    NEED["$BACKEND"]="none"
  else
    NEED["$BACKEND"]="$(package_need_for_backend "$BACKEND")"
    [ "${NEED[$BACKEND]}" = "none" ] || ANY_PACKAGE_CHANGE=1
  fi
done

if [ "$ANY_BACKEND" -eq 0 ]; then
  fail "no installed backends matched the request. Install one with: localvllm backend install vllm"
fi

SCRIPTS_CHANGE=0
if [ "$VLLM_ONLY" -eq 0 ] &&
  localvllm_source_changed "$LOCALVLLM_SOURCE_DIR" "$CONF_ROOT"; then
  SCRIPTS_CHANGE=1
fi

# The router is optional and shared. Only replace the executable owned by
# this installation; never modify a configured external/PATH installation.
ROUTER_CHANGE=0
STAGED_ROUTER=""
if [ "$SCRIPTS_ONLY" = 0 ] && [ "$VLLM_ONLY" = 0 ]; then
  if SWAP_BIN="$(localvllm_swap_bin)"; then
    if [ "$(realpath "$SWAP_BIN")" = "$(realpath -m "$BIN_DIR/llama-swap")" ]; then
      if SWAP_TARGET="$(localvllm_swap_target_version)"; then
        SWAP_CURRENT="$(localvllm_swap_version "$SWAP_BIN")" || SWAP_CURRENT=""
        if [ "$SWAP_CURRENT" != "$SWAP_TARGET" ]; then
          log "Staging llama-swap $SWAP_TARGET (installed: ${SWAP_CURRENT:-unknown})"
          STAGED_ROUTER="$TMP_DIR/llama-swap.staged"
          localvllm_download_swap "$STAGED_ROUTER" "$SWAP_TARGET" || fail 'could not stage llama-swap; installed components were not changed'
          ROUTER_CHANGE=1
        fi
      else
        warn 'could not check llama-swap releases; keeping the installed router'
      fi
    else
      log "External llama-swap is managed separately: $SWAP_BIN"
    fi
  fi
fi

# Shared helper/router changes can affect an unselected backend too. Include
# its service in the rollback scope without upgrading its Python packages.
if [ "$SCRIPTS_CHANGE" = 1 ] || [ "$ROUTER_CHANGE" = 1 ]; then
  while IFS= read -r BACKEND; do
    localvllm_use_backend "$BACKEND" || continue
    localvllm_backend_installed "$BACKEND" || continue
    if [ -z "${NEED[$BACKEND]+x}" ]; then
      NEED["$BACKEND"]=none
      UPDATE_BACKENDS+=("$BACKEND")
    fi
    if service_is_active; then WAS_RUNNING["$BACKEND"]=1; fi
  done < <(localvllm_backend_list)
fi
for BACKEND in "${UPDATE_BACKENDS[@]}"; do
  localvllm_use_backend "$BACKEND" || continue
  if [ "$SCRIPTS_CHANGE" = 0 ] && [ "${NEED[$BACKEND]:-none}" = none ]; then
    if [ "$ROUTER_CHANGE" = 0 ] || [ "$(localvllm_serving_mode)" != swap ]; then
      unset 'WAS_RUNNING[$BACKEND]'
    fi
  fi
done

if [ "$SCRIPTS_CHANGE" -eq 0 ] && [ "$ANY_PACKAGE_CHANGE" -eq 0 ] && [ "$ROUTER_CHANGE" = 0 ]; then
  log "Everything is already up to date"
  print_versions
  exit 0
fi

TRANSACTION_READY=0
transaction_cleanup() {
  local result=$? backend
  trap - EXIT
  if [ "$result" -ne 0 ] && [ "$TRANSACTION_READY" -eq 1 ]; then
    echo "Restoring the previous manager and backend state..." >&2
    for backend in "${UPDATE_BACKENDS[@]}"; do
      localvllm_use_backend "$backend" || continue
      if [ -n "${WAS_RUNNING[$backend]+x}" ]; then
        stop_localvllm || true
      fi
      if [ -n "${OLD_VENVS[$backend]:-}" ]; then
        vllm_venv_rollback_update "$VENV_DIR" "${OLD_VENVS[$backend]}" || true
      fi
    done
    rm -rf "$BIN_DIR" "$LIB_DIR"
    cp -a "$TMP_DIR/transaction/bin" "$BIN_DIR" || true
    cp -a "$TMP_DIR/transaction/lib" "$LIB_DIR" || true
    # Keep the lock inode held by this process while restoring configuration.
    find "$CONF_ROOT" -mindepth 1 -maxdepth 1 ! -name .localvllm.lock -exec rm -rf -- {} +
    cp -a "$TMP_DIR/transaction/conf/." "$CONF_ROOT/" || true
    while IFS= read -r backend; do
      localvllm_use_backend "$backend" || continue
      if [ -f "$TMP_DIR/transaction/services/$backend" ]; then
        cp -a "$TMP_DIR/transaction/services/$backend" "$SERVICE_FILE" || true
      else
        rm -f "$SERVICE_FILE"
      fi
    done < <(localvllm_backend_list)
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    for backend in "${UPDATE_BACKENDS[@]}"; do
      [ "$START_AFTER_UPDATE" = 1 ] || continue
      [ -n "${WAS_RUNNING[$backend]+x}" ] || continue
      localvllm_use_backend "$backend" || continue
      start_localvllm || true
    done
  fi
  rm -rf "$TMP_DIR"
  exit "$result"
}
mkdir -p "$TMP_DIR/transaction"
cp -a "$BIN_DIR" "$TMP_DIR/transaction/bin"
cp -a "$LIB_DIR" "$TMP_DIR/transaction/lib"
cp -a "$CONF_ROOT" "$TMP_DIR/transaction/conf"
mkdir -p "$TMP_DIR/transaction/services"
while IFS= read -r BACKEND; do
  localvllm_use_backend "$BACKEND" || continue
  if [ -f "$SERVICE_FILE" ]; then
    cp -a "$SERVICE_FILE" "$TMP_DIR/transaction/services/$BACKEND"
  fi
done < <(localvllm_backend_list)
TRANSACTION_READY=1
trap transaction_cleanup EXIT

###############################################################################
# STOP RUNNING SERVICES
###############################################################################

for BACKEND in "${UPDATE_BACKENDS[@]}"; do
  [ -n "${WAS_RUNNING[$BACKEND]+x}" ] || continue
  localvllm_use_backend "$BACKEND" || continue
  if ! stop_localvllm; then
    echo "Error: could not stop $BACKEND; refusing to modify its environment." >&2
    # Bring any already-stopped backends back before leaving.
    for OTHER in "${UPDATE_BACKENDS[@]}"; do
      [ "$START_AFTER_UPDATE" = 1 ] || continue
      [ -n "${WAS_RUNNING[$OTHER]+x}" ] || continue
      localvllm_use_backend "$OTHER" || continue
      localvllm_service_is_active || start_localvllm || true
    done
    exit 1
  fi
done

###############################################################################
# REFRESH SCRIPTS AND UPGRADE PACKAGES
###############################################################################


if [ "$SCRIPTS_ONLY" -eq 0 ]; then
  for BACKEND in "${UPDATE_BACKENDS[@]}"; do
    need="${NEED[$BACKEND]:-none}"
    [ "$need" = "none" ] && continue
    if ! update_backend_package "$BACKEND" "$need"; then
      echo "Error: package update failed for $BACKEND; restoring previous environments." >&2
      exit 1
    fi
  done
fi

if [ "$SCRIPTS_CHANGE" -eq 1 ]; then
  STAGED_CLI="$TMP_DIR/localvllm.staged"
  STAGED_UPDATER="$TMP_DIR/update-localvllm.staged"
  if ! refresh_scripts; then
    echo "Error: helper script refresh failed; restarting the previous services." >&2
    exit 1
  fi
fi

if [ "$ROUTER_CHANGE" = 1 ]; then
  install -m755 "$STAGED_ROUTER" "$BIN_DIR/llama-swap.next"
  mv -f "$BIN_DIR/llama-swap.next" "$BIN_DIR/llama-swap"
fi

###############################################################################
# REBUILD LAUNCHERS
###############################################################################

if [ "$SCRIPTS_CHANGE" -eq 1 ] || [ "$ANY_PACKAGE_CHANGE" -eq 1 ] || [ "$ROUTER_CHANGE" = 1 ]; then
  for BACKEND in "${UPDATE_BACKENDS[@]}"; do
    localvllm_use_backend "$BACKEND" || continue
    localvllm_backend_installed "$BACKEND" || continue
    if localvllm_require_start_model >/dev/null 2>&1; then
      "$BIN_DIR/rebuild-config.sh" --backend "$BACKEND" >/dev/null ||
        fail "could not rebuild the $BACKEND launcher; restoring the previous installation"
    fi
  done
fi

###############################################################################
# RESTART SERVICES THAT WERE RUNNING
###############################################################################

declare -A START_FAILED=()
UPDATE_FAILED=0
if [ "$START_AFTER_UPDATE" -eq 1 ]; then
  for BACKEND in "${UPDATE_BACKENDS[@]}"; do
    [ -n "${WAS_RUNNING[$BACKEND]+x}" ] || continue
    localvllm_use_backend "$BACKEND" || continue
    if ! start_localvllm; then
      echo "Error: $BACKEND failed to start after the update." >&2
      START_FAILED["$BACKEND"]=1
      UPDATE_FAILED=1
    fi
  done
else
  log "Services were left stopped (--no-start)"
fi


if [ "$UPDATE_FAILED" -ne 0 ]; then
  echo "Update completed with errors; inspect the output above." >&2
  exit 1
fi

commit_staged_helpers
for BACKEND in "${UPDATE_BACKENDS[@]}"; do
  localvllm_use_backend "$BACKEND" || continue
  localvllm_backend_installed "$BACKEND" || continue
  write_environment_manifest "$VENV_DIR" "$CONF_DIR" "$BACKEND"
done
TRANSACTION_READY=0
# A previous environment is only needed until its service has started. Keep it
# for backends that failed to start, remove it for successful/not-running ones.
for BACKEND in "${UPDATE_BACKENDS[@]}"; do
  [ -n "${OLD_VENVS[$BACKEND]:-}" ] || continue
  if [ -z "${START_FAILED[$BACKEND]+x}" ]; then
    vllm_venv_finish_update "${OLD_VENVS[$BACKEND]}"
    OLD_VENVS["$BACKEND"]=""
  fi
done

log "Local vLLM update completed"
print_versions

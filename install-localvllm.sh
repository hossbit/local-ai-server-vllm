#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2153
set -euo pipefail

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

for candidate in "$SCRIPT_DIR/lib/common.sh" "$SCRIPT_DIR/../lib/common.sh"; do
  if [ -f "$candidate" ]; then
    # shellcheck source=/dev/null
    . "$candidate"
    break
  fi
done
for candidate in "$SCRIPT_DIR/lib/install.sh" "$SCRIPT_DIR/../lib/install.sh"; do
  if [ -f "$candidate" ]; then
    # shellcheck source=/dev/null
    . "$candidate"
    break
  fi
done
if ! declare -F localvllm_use_backend >/dev/null 2>&1; then
  echo "Error: missing Local vLLM libraries." >&2
  exit 1
fi

AI_DIR="${LOCALVLLM_DIR:-}"
# Distinguish a repository checkout from the installed copy in <ai>/bin.
# The installed copy has no source tree to copy from; it only installs engine
# packages and refreshes per-backend state/services.
SOURCE_DIR=""
INSTALLED_MODE=0
if [ -f "$SCRIPT_DIR/localvllm.conf" ] && [ -d "$SCRIPT_DIR/lib" ]; then
  SOURCE_DIR="$SCRIPT_DIR"
elif [ -f "$SCRIPT_DIR/../conf/localvllm.conf" ] && [ -d "$SCRIPT_DIR/../lib" ]; then
  INSTALLED_MODE=1
  AI_DIR="${AI_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
else
  echo "Error: cannot find the Local vLLM source tree or installed configuration." >&2
  exit 1
fi
CONF_ROOT=""
BIN_DIR=""
LIB_DIR=""
MODELS_ROOT=""
VENV_ROOT=""
LOGS_DIR=""
LOCALVLLM_CLI_PATH=""
LOCALVLLM_CLI_LINK=""
SKIP_SYSTEM=0
INSTALL_BACKENDS=()

log() {
  printf '\n==> %s\n' "$*"
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage: $0 [--dir PATH] [--backend vllm|omni|all] [--skip-system]

Installs the Local vLLM manager and one or both isolated backends.

Options:
  --dir PATH        Install into PATH. Same as LOCALVLLM_DIR=PATH.
  --backend NAME    Install vllm, omni, or all. Repeatable.
                    Default: the configured default backend (vllm).
  --all             Install both backends.
  --skip-system     Do not install apt/dnf/yum packages.
  -h, --help        Show this help

Environment:
  VLLM_VERSION          vLLM version (default: latest)
  VLLM_OMNI_VERSION     vLLM-Omni version (default: latest)
  VLLM_OMNI_EXTRAS      Optional extras, e.g. demo
  VLLM_ALLOW_CPU=1      Permit installation without a detected GPU
  VLLM_PIP_ARGS         Extra pip arguments for vLLM
  VLLM_OMNI_PIP_ARGS    Extra pip arguments for vLLM-Omni
EOF
}

add_backend() {
  local requested="$1" name

  if [ "$requested" = "all" ]; then
    while IFS= read -r name; do
      INSTALL_BACKENDS+=("$name")
    done < <(localvllm_backend_list)
    return 0
  fi

  name="$(localvllm_backend_name "$requested")" ||
    fail "unknown backend: $requested (use vllm, omni, or all)"
  INSTALL_BACKENDS+=("$name")
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dir)
        [ "$#" -ge 2 ] || fail "missing path after --dir"
        AI_DIR="$2"
        shift 2
        ;;
      --dir=*)
        AI_DIR="${1#--dir=}"
        shift
        ;;
      --backend)
        [ "$#" -ge 2 ] || fail "missing name after --backend"
        add_backend "$2"
        shift 2
        ;;
      --backend=*)
        add_backend "${1#--backend=}"
        shift
        ;;
      --all)
        add_backend all
        shift
        ;;
      --skip-system)
        SKIP_SYSTEM=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        usage >&2
        exit 2
        ;;
    esac
  done
}

select_ai_dir() {
  local answer

  if [ -n "$AI_DIR" ]; then
    AI_DIR="$(expand_path "$AI_DIR")"
    log "Using Local vLLM install directory: $AI_DIR"
  elif [ -t 0 ]; then
    printf 'Local vLLM install directory [%s]: ' "$LOCALVLLM_DEFAULT_DIR_DISPLAY"
    read -r answer
  else
    answer=""
    log "No interactive terminal detected. Using default install directory: $LOCALVLLM_DEFAULT_DIR_DISPLAY"
  fi

  AI_DIR="${AI_DIR:-$(expand_path "${answer:-$LOCALVLLM_DEFAULT_DIR}")}"
  case "$AI_DIR" in
    /*) ;;
    *) fail "install directory must be an absolute path or start with ~" ;;
  esac
  case "$AI_DIR" in
    *[[:space:]%]*) fail "install directory cannot contain spaces or percent signs because it is used in a systemd service" ;;
  esac
}

install_system_dependencies() {
  local packages
  local sudo_cmd=()

  if [ "$SKIP_SYSTEM" -eq 1 ]; then
    log "Skipping system dependency installation (--skip-system)"
    return 0
  fi

  log "Installing system dependencies"

  if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || fail "sudo is required to install system dependencies when not running as root"
    sudo_cmd=(sudo)
  fi

  if command -v apt-get >/dev/null 2>&1; then
    "${sudo_cmd[@]}" apt-get update
    read -r -a packages <<< "$LOCALVLLM_APT_PACKAGES"
    "${sudo_cmd[@]}" apt-get install -y "${packages[@]}"
  elif command -v dnf >/dev/null 2>&1; then
    read -r -a packages <<< "$LOCALVLLM_DNF_PACKAGES"
    "${sudo_cmd[@]}" dnf install -y "${packages[@]}" ||
      fail "failed to install dnf packages. On RHEL 7/8, enable EPEL if jq is unavailable."
  elif command -v yum >/dev/null 2>&1; then
    read -r -a packages <<< "$LOCALVLLM_YUM_PACKAGES"
    "${sudo_cmd[@]}" yum install -y "${packages[@]}" ||
      fail "failed to install yum packages. On RHEL 7/8, enable EPEL if jq is unavailable."
  else
    fail "supported package manager not found. Install the packages from localvllm.conf, then rerun with --skip-system."
  fi
}

port_used_by_other_backend() {
  local port="$1"
  local backend="$2"
  local name other_port port_file

  while IFS= read -r name; do
    [ "$name" = "$backend" ] && continue
    port_file="$CONF_ROOT/${LOCALVLLM_BACKENDS_STATE_SUBDIR:-backends}/$name/$LOCALVLLM_PORT_FILE"
    [ -f "$port_file" ] || continue
    other_port="$(<"$port_file")"
    [ "$other_port" = "$port" ] && return 0
  done < <(localvllm_backend_list)

  return 1
}

select_port() {
  local backend="$1"
  local port="$LOCALVLLM_DEFAULT_PORT"

  if [ -f "$PORT_FILE" ]; then
    return 0
  fi

  while port_is_listening "$port" || port_used_by_other_backend "$port" "$backend"; do
    port=$((port + 1))
  done
  echo "$port" > "$PORT_FILE"
}

install_backend_packages() {
  local name="$1"
  local target_venv="$2"
  local pip_log="$3"
  local vllm_version omni_version

  if [ "$name" = "omni" ]; then
    vllm_pip_install_both "$target_venv" "$VLLM_VERSION" "$VLLM_OMNI_VERSION" \
      "$VLLM_OMNI_EXTRAS" "$VLLM_PIP_ARGS" \
      "${VLLM_OMNI_PIP_ARGS:-$VLLM_PIP_ARGS}" "$pip_log" || return 1
    vllm_version="$(vllm_verify_install "$target_venv")" || return 1
    omni_version="$(vllm_omni_verify_install "$target_venv")" || return 1
    VLLM_INSTALLED_VERSION="$vllm_version"
    VLLM_OMNI_INSTALLED_VERSION="$omni_version"
  else
    vllm_pip_install "$target_venv" "$VLLM_VERSION" "$VLLM_PIP_ARGS" "$pip_log" || return 1
    vllm_version="$(vllm_verify_install "$target_venv")" || return 1
    VLLM_INSTALLED_VERSION="$vllm_version"
  fi

  if ! vllm_pip_check "$target_venv"; then
    echo "Error: pip check failed for $name; the installed package set is inconsistent." >&2
    return 1
  fi
  return 0
}

install_backend() {
  local name="$1"
  local pip_log was_running=0 target_venv old_venv=""
  local install_status=0

  log "Installing backend: $name ($(localvllm_backend_label "$name"))"

  mkdir -p "$CONF_DIR" "$MODELS_DIR" "$OVERRIDES_DIR" "$LOGS_DIR"

  if localvllm_service_is_active; then
    log "Stopping running $LOCALVLLM_BACKEND_LABEL before changing its environment"
    if ! localvllm_stop_service; then
      echo "Error: could not stop $LOCALVLLM_BACKEND_LABEL; refusing to modify its venv." >&2
      return 1
    fi
    was_running=1
  fi

  if [ -x "$VENV_DIR/bin/python" ]; then
    if [ "$name" = omni ] && ! localvllm_omni_python_ok "$VENV_DIR/bin/python"; then
      log "The existing Omni environment uses an incompatible Python; preparing a replacement"
      LOCALVLLM_PYTHON="$(localvllm_find_compatible_python "$name")" || {
        if [ "$was_running" -eq 1 ]; then localvllm_start_service || true; fi
        return 1
      }
      target_venv="$(mktemp -d "${VENV_DIR}.update.XXXXXX")" || {
        if [ "$was_running" -eq 1 ]; then localvllm_start_service || true; fi
        return 1
      }
      vllm_venv_create "$target_venv" "$LOCALVLLM_PYTHON" || {
        rm -rf "$target_venv"
        if [ "$was_running" -eq 1 ]; then localvllm_start_service || true; fi
        return 1
      }
    else
      target_venv="$(vllm_venv_stage_update "$VENV_DIR")" || {
        echo "Error: could not stage an update of $VENV_DIR." >&2
        if [ "$was_running" -eq 1 ]; then localvllm_start_service || true; fi
        return 1
      }
    fi
  elif [ -e "$VENV_DIR" ]; then
    log "The existing environment is incomplete; preparing a replacement"
    LOCALVLLM_PYTHON="$(localvllm_find_compatible_python "$name")" || {
      if [ "$was_running" -eq 1 ]; then localvllm_start_service || true; fi
      return 1
    }
    target_venv="$(mktemp -d "${VENV_DIR}.update.XXXXXX")" || {
      if [ "$was_running" -eq 1 ]; then localvllm_start_service || true; fi
      return 1
    }
    vllm_venv_create "$target_venv" "$LOCALVLLM_PYTHON" || {
      rm -rf "$target_venv"
      if [ "$was_running" -eq 1 ]; then localvllm_start_service || true; fi
      return 1
    }
  else
    LOCALVLLM_PYTHON="$(localvllm_find_compatible_python "$name")" || {
      if [ "$was_running" -eq 1 ]; then localvllm_start_service || true; fi
      return 1
    }
    vllm_venv_create "$VENV_DIR" "$LOCALVLLM_PYTHON" || {
      rm -rf "$VENV_DIR"
      echo "Error: could not create the $name virtual environment." >&2
      if [ "$was_running" -eq 1 ]; then localvllm_start_service || true; fi
      return 1
    }
    target_venv="$VENV_DIR"
  fi

  pip_log="$LOGS_DIR/pip-install-$name.log"
  : > "$pip_log"

  vllm_bootstrap_pip "$target_venv" "$pip_log" || install_status=1
  if [ "$install_status" -eq 0 ]; then
    install_backend_packages "$name" "$target_venv" "$pip_log" || install_status=1
  fi

  if [ "$install_status" -ne 0 ]; then
    if [ "$target_venv" != "$VENV_DIR" ]; then
      rm -rf "$target_venv"
    else
      rm -rf "$VENV_DIR"
    fi
    echo "Error: installation failed for backend $name; the previous environment was left intact." >&2
    if [ "$was_running" -eq 1 ]; then localvllm_start_service || true; fi
    return 1
  fi

  if [ "$target_venv" != "$VENV_DIR" ]; then
    old_venv="$(vllm_venv_commit_update "$VENV_DIR" "$target_venv")" || {
      echo "Error: could not install the updated environment for $name." >&2
      if [ "$was_running" -eq 1 ]; then localvllm_start_service || true; fi
      return 1
    }
  fi

  select_port "$name"
  write_systemd_user_service "$SERVICE_FILE" "$BIN_DIR" "$name"

  if [ "$was_running" -eq 1 ]; then
    if ! localvllm_start_service; then
      if [ -n "$old_venv" ]; then
        vllm_venv_rollback_update "$VENV_DIR" "$old_venv" || true
        localvllm_start_service || true
      fi
      echo "Error: $LOCALVLLM_BACKEND_LABEL did not start after the update; restored the previous environment when possible." >&2
      return 1
    fi
  fi
  write_environment_manifest "$VENV_DIR" "$CONF_DIR" "$name"
  [ -z "$old_venv" ] || vllm_venv_finish_update "$old_venv"

  echo
  echo "Backend installed: $name"
  echo "  vLLM: ${VLLM_INSTALLED_VERSION:-unknown}"
  [ "$name" != "omni" ] || echo "  vLLM-Omni: ${VLLM_OMNI_INSTALLED_VERSION:-unknown}"
  echo "  venv: $VENV_DIR"
  echo "  models: $MODELS_DIR"
  echo "  port: $(cat "$PORT_FILE")"
  echo "  service: $SERVICE_FILE"
  echo "  pip log: $pip_log"
}

case "$(uname -m)" in
  x86_64|aarch64|arm64) ;;
  *) fail "unsupported architecture: $(uname -m). Use a vLLM-supported Linux platform or install manually." ;;
esac

parse_args "$@"
select_ai_dir

if [ "${#INSTALL_BACKENDS[@]}" -eq 0 ]; then
  add_backend "$LOCALVLLM_DEFAULT_BACKEND"
fi

# Deduplicate while preserving order.
declare -A SEEN_BACKENDS=()
UNIQUE_BACKENDS=()
for BACKEND in "${INSTALL_BACKENDS[@]}"; do
  [ -n "${SEEN_BACKENDS[$BACKEND]+x}" ] && continue
  SEEN_BACKENDS["$BACKEND"]=1
  UNIQUE_BACKENDS+=("$BACKEND")
done
INSTALL_BACKENDS=("${UNIQUE_BACKENDS[@]}")

CONF_ROOT="$AI_DIR/$LOCALVLLM_CONF_SUBDIR"
BIN_DIR="$AI_DIR/$LOCALVLLM_BIN_SUBDIR"
LIB_DIR="$AI_DIR/$LOCALVLLM_LIB_SUBDIR"
MODELS_ROOT="$AI_DIR/$LOCALVLLM_MODELS_SUBDIR"
VENV_ROOT="$AI_DIR/$LOCALVLLM_VENV_SUBDIR"
LOGS_DIR="$AI_DIR/$LOCALVLLM_LOGS_SUBDIR"
LOCALVLLM_CLI_PATH="$BIN_DIR/$LOCALVLLM_CLI_NAME"
LOCALVLLM_CLI_LINK="$LOCALVLLM_USER_BIN_DIR/$LOCALVLLM_CLI_NAME"

localvllm_capture_global_runtime
localvllm_acquire_global_lock

mkdir -p "$AI_DIR" "$BIN_DIR" "$LIB_DIR" "$CONF_ROOT" "$MODELS_ROOT" "$VENV_ROOT" "$LOGS_DIR"
mkdir -p "$CONF_ROOT/$LOCALVLLM_BACKEND_PROFILES_SUBDIR" "$CONF_ROOT/$LOCALVLLM_BACKENDS_STATE_SUBDIR"

TARGET_DEVICE="$(vllm_detect_target_device)"
if [ "$TARGET_DEVICE" = "cpu" ] && [ "${VLLM_ALLOW_CPU:-0}" != "1" ]; then
  fail "no supported GPU detected.

vLLM is primarily a GPU server. If you really want to try CPU inference:
  VLLM_ALLOW_CPU=1 $0 --skip-system

Or install an NVIDIA driver, then rerun."
fi
case "$TARGET_DEVICE" in
  cpu|rocm)
    if [ -z "${VLLM_TARGET_DEVICE:-}" ]; then
      export VLLM_TARGET_DEVICE="$TARGET_DEVICE"
    fi
    if [ -z "${VLLM_OMNI_TARGET_DEVICE:-}" ]; then
      export VLLM_OMNI_TARGET_DEVICE="$TARGET_DEVICE"
    fi
    ;;
esac
log "Detected device: $(vllm_device_hint "$TARGET_DEVICE")"
case "$TARGET_DEVICE" in
  rocm)
    if [ -z "${VLLM_PIP_ARGS:-}" ]; then
      fail "AMD ROCm was detected, but a compatible vLLM wheel was not selected.

The default PyPI wheel may be for NVIDIA CUDA. Follow the AMD setup guide to
choose a vLLM version and wheel index for your GPU and ROCm stack:
  https://github.com/hossbit/comai-linux-assistant-wiki/blob/main/Local-vLLM.md#amd-and-cpu-installation"
    fi
    ;;
  cpu)
    if [ -z "${VLLM_PIP_ARGS:-}" ]; then
      echo "Warning: CPU installs need a compatible CPU wheel or upstream source build." >&2
      echo "See https://github.com/hossbit/comai-linux-assistant-wiki/blob/main/Local-vLLM.md#amd-and-cpu-installation" >&2
    fi
    ;;
esac
if [ "$TARGET_DEVICE" = "cpu" ]; then
  case " ${INSTALL_BACKENDS[*]} " in
    *" omni "*) echo "Warning: vLLM-Omni on CPU is not a supported production target." >&2 ;;
  esac
fi

install_system_dependencies


for BACKEND in "${INSTALL_BACKENDS[@]}"; do
  write_backend_profile "$CONF_ROOT" "$BACKEND"
done

###############################################################################
# INSTALL ENGINE PACKAGES INTO ISOLATED VENVS
###############################################################################

for BACKEND in "${INSTALL_BACKENDS[@]}"; do
  localvllm_use_backend "$BACKEND" || fail "could not activate backend: $BACKEND"
  install_backend "$BACKEND"
done

###############################################################################
# INSTALL HELPER SCRIPTS, GLOBAL CONFIG, AND CLI
###############################################################################

if [ "$INSTALLED_MODE" -eq 0 ]; then
  log "Installing helper scripts, configuration, and CLI"

  install -m755 "$SOURCE_DIR/start.sh" "$BIN_DIR/start.sh"
  install -m755 "$SOURCE_DIR/stop.sh" "$BIN_DIR/stop.sh"
  install -m755 "$SOURCE_DIR/rebuild-config.sh" "$BIN_DIR/rebuild-config.sh"
  install -m755 "$SOURCE_DIR/update-localvllm.sh" "$BIN_DIR/update-localvllm.sh"
  install -m755 "$SOURCE_DIR/uninstall-localvllm.sh" "$BIN_DIR/uninstall-localvllm.sh"
  install -m755 "$SOURCE_DIR/install-localvllm.sh" "$BIN_DIR/install-localvllm.sh"
  install -m755 "$SOURCE_DIR/localvllm" "$LOCALVLLM_CLI_PATH"
  install_localvllm_libs "$SOURCE_DIR" "$LIB_DIR"

  PREVIOUS_LOCALVLLM_CONF=""
  if [ -f "$CONF_ROOT/localvllm.conf" ]; then
    cp "$CONF_ROOT/localvllm.conf" "$LIB_DIR/localvllm.conf.previous"
    PREVIOUS_LOCALVLLM_CONF="$LIB_DIR/localvllm.conf.previous"
  fi
  install -m600 "$SOURCE_DIR/localvllm.conf" "$CONF_ROOT/localvllm.conf"
  append_runtime_tuning "$PREVIOUS_LOCALVLLM_CONF" "installer"
  if [ -n "$PREVIOUS_LOCALVLLM_CONF" ] && [ "$PREVIOUS_LOCALVLLM_CONF" != "$CONF_ROOT/localvllm.conf" ]; then
    rm -f "$PREVIOUS_LOCALVLLM_CONF"
  fi
  write_config_marker "$SOURCE_DIR/localvllm.conf" "$CONF_ROOT"
else
  log "Using the installed helper scripts in $BIN_DIR"
  [ -x "$LOCALVLLM_CLI_PATH" ] || fail "missing installed CLI: $LOCALVLLM_CLI_PATH"
  [ -f "$CONF_ROOT/localvllm.conf" ] || fail "missing installed configuration: $CONF_ROOT/localvllm.conf"
  [ -x "$BIN_DIR/start.sh" ] || fail "missing installed helper: $BIN_DIR/start.sh"
  [ -x "$BIN_DIR/stop.sh" ] || fail "missing installed helper: $BIN_DIR/stop.sh"
  [ -x "$BIN_DIR/rebuild-config.sh" ] || fail "missing installed helper: $BIN_DIR/rebuild-config.sh"
fi

mkdir -p "$LOCALVLLM_SYSTEMD_USER_DIR" "$LOCALVLLM_USER_BIN_DIR"

# Re-apply the backend profiles after the config replacement so a first install
# and a repair both leave valid profiles.
for BACKEND in "${INSTALL_BACKENDS[@]}"; do
  write_backend_profile "$CONF_ROOT" "$BACKEND"
done

# If the configured default backend is not installed at all, point the default
# at the first backend that is. Adding a second backend must not steal the
# default from an already-installed one.
if ! localvllm_backend_installed "$LOCALVLLM_DEFAULT_BACKEND"; then
  NEW_DEFAULT=""
  for BACKEND in "${INSTALL_BACKENDS[@]}"; do
    localvllm_use_backend "$BACKEND" || continue
    if localvllm_backend_installed "$BACKEND"; then
      NEW_DEFAULT="$BACKEND"
      break
    fi
  done
  if [ -n "$NEW_DEFAULT" ]; then
    LOCALVLLM_DEFAULT_BACKEND="$NEW_DEFAULT"
    set_conf_value "$CONF_ROOT/localvllm.conf" LOCALVLLM_DEFAULT_BACKEND "$LOCALVLLM_DEFAULT_BACKEND" ||
      echo "Warning: could not update the default backend in $CONF_ROOT/localvllm.conf." >&2
  fi
fi

ln -sfn "$LOCALVLLM_CLI_PATH" "$LOCALVLLM_CLI_LINK"

if ! systemctl --user daemon-reload; then
  echo "Warning: could not reload the systemd user manager." >&2
  echo "You can still use the helper scripts in $BIN_DIR directly." >&2
fi

echo
echo "============================================================"
echo " Local vLLM installation completed"
echo "============================================================"
echo
echo "Install directory: $AI_DIR"
echo "Default backend:   $LOCALVLLM_DEFAULT_BACKEND"
echo
echo "Backends installed in this run:"
for BACKEND in "${INSTALL_BACKENDS[@]}"; do
  localvllm_use_backend "$BACKEND" || continue
  echo "  $BACKEND:"
  echo "    version: $(localvllm_backend_version "$BACKEND" || printf 'unknown')"
  echo "    models:  $MODELS_DIR"
  echo "    port:    $(cat "$PORT_FILE" 2>/dev/null || printf '%s' "$LOCALVLLM_DEFAULT_PORT")"
  echo "    service: $SERVICE_FILE"
  echo "    log:     $LOG_FILE"
done

echo
echo "Next:"
echo "  localvllm backend list"
echo "  localvllm --backend vllm use org/model"
echo "  localvllm --backend omni use org/omni-model"
echo "  localvllm start vllm"
echo "  localvllm start omni"
echo "  localvllm status all"
echo
echo "Start one backend at login:"
echo "  systemctl --user enable localvllm"
echo "  systemctl --user enable localvllm-omni"
echo
echo "CLI command:"
echo "  $LOCALVLLM_CLI_LINK"
echo "============================================================"

ENSURE_PATH_STATUS=0
ensure_cli_on_path || ENSURE_PATH_STATUS=$?
reconnect_shell_on_path "$ENSURE_PATH_STATUS"

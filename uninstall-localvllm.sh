#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2153
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

AI_DIR=""
CONF_ROOT=""
BIN_DIR=""
LIB_DIR=""
MODELS_ROOT=""
VENV_ROOT=""
REMOVE_BACKENDS=()
REMOVE_ALL=0
REMOVE_MODELS=0
REMOVE_HF_CACHE=0
KEEP_VENV=0
FORCE=0
LOCALVLLM_CLI_LINK="$LOCALVLLM_USER_BIN_DIR/$LOCALVLLM_CLI_NAME"

usage() {
  cat <<EOF
Usage: $0 [--dir PATH] [--backend NAME|all] [--remove-models]
          [--remove-hf-cache] [--keep-venv] [--force]

Uninstalls Local vLLM.

Options:
  --dir PATH          Uninstall from PATH. Same as LOCALVLLM_DIR=PATH.
  --backend NAME      Remove only vllm, omni, or all (default: all).
  --remove-models     Also delete the selected backend's models directory.
  --remove-hf-cache   Also delete the shared Hugging Face cache.
  --keep-venv         Keep the selected backend's Python virtual environment.
  --force             Do not prompt before deleting files.
  -h, --help          Show this help
EOF
}

log() {
  printf '\n==> %s\n' "$*"
}

warn() {
  echo "Warning: $*" >&2
}

add_backend() {
  local requested="$1" name

  if [ "$requested" = "all" ]; then
    REMOVE_ALL=1
    while IFS= read -r name; do
      REMOVE_BACKENDS+=("$name")
    done < <(localvllm_backend_list)
    return 0
  fi

  name="$(localvllm_backend_name "$requested")" ||
    { usage >&2; exit 2; }
  REMOVE_BACKENDS+=("$name")
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      LOCALVLLM_DIR="$2"
      shift 2
      ;;
    --dir=*)
      LOCALVLLM_DIR="${1#--dir=}"
      shift
      ;;
    --backend)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      add_backend "$2"
      shift 2
      ;;
    --backend=*)
      add_backend "${1#--backend=}"
      shift
      ;;
    --remove-models)
      REMOVE_MODELS=1
      shift
      ;;
    --remove-hf-cache)
      REMOVE_HF_CACHE=1
      shift
      ;;
    --keep-venv)
      KEEP_VENV=1
      shift
      ;;
    --force)
      FORCE=1
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

AI_DIR="$(resolve_ai_dir)"
CONF_ROOT="$AI_DIR/$LOCALVLLM_CONF_SUBDIR"
BIN_DIR="$AI_DIR/$LOCALVLLM_BIN_SUBDIR"
LIB_DIR="$AI_DIR/$LOCALVLLM_LIB_SUBDIR"
MODELS_ROOT="$AI_DIR/$LOCALVLLM_MODELS_SUBDIR"
VENV_ROOT="$AI_DIR/$LOCALVLLM_VENV_SUBDIR"
localvllm_capture_global_runtime
localvllm_acquire_global_lock

if [ "${#REMOVE_BACKENDS[@]}" -eq 0 ]; then
  add_backend all
fi

declare -A SEEN=()
UNIQUE=()
for BACKEND in "${REMOVE_BACKENDS[@]}"; do
  [ -n "${SEEN[$BACKEND]+x}" ] && continue
  SEEN["$BACKEND"]=1
  UNIQUE+=("$BACKEND")
done
REMOVE_BACKENDS=("${UNIQUE[@]}")

if [ "${#REMOVE_BACKENDS[@]}" -eq "$(localvllm_backend_list | grep -c .)" ]; then
  REMOVE_ALL=1
fi

confirm() {
  [ "$FORCE" -eq 1 ] && return 0
  printf '%s [y/N] ' "$1"
  read -r REPLY
  case "$REPLY" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

remove_if_exists() {
  local target="$1"

  if [ -e "$target" ] || [ -L "$target" ]; then
    rm -rf -- "$target"
  fi
}

path_exists() {
  [ -e "$1" ] || [ -L "$1" ]
}

echo "This will uninstall Local vLLM for the current user."
echo "Resolved install directory: $AI_DIR"
echo "Backends: ${REMOVE_BACKENDS[*]}"
echo

echo "Will remove:"
for BACKEND in "${REMOVE_BACKENDS[@]}"; do
  localvllm_use_backend "$BACKEND" || continue
  echo "  service: $LOCALVLLM_SERVICE_NAME"
  echo "  state:   $CONF_DIR"
  echo "  log:     $LOG_FILE"
  [ "$KEEP_VENV" -eq 1 ] || echo "  venv:    $VENV_DIR"
done

if [ "$REMOVE_MODELS" -eq 1 ]; then
  if [ "$REMOVE_ALL" -eq 1 ]; then
    echo "  models:  $MODELS_ROOT"
  else
    for BACKEND in "${REMOVE_BACKENDS[@]}"; do
      echo "  models:  $MODELS_ROOT/$BACKEND"
    done
  fi
fi
if [ "$REMOVE_HF_CACHE" -eq 1 ]; then
  echo "  HF cache: $AI_DIR/${LOCALVLLM_HF_CACHE_SUBDIR:-hf-cache}"
fi
if [ "$REMOVE_ALL" -eq 1 ]; then
  echo "  helper scripts: $BIN_DIR"
  echo "  libraries:      $LIB_DIR"
  echo "  configuration:  $CONF_ROOT"
  if [ "$KEEP_VENV" -eq 0 ]; then
    echo "  managed Python and tools: $VENV_ROOT/.localvllm-*"
  fi
  echo "  logs:           $AI_DIR/$LOCALVLLM_LOGS_SUBDIR"
  echo "  CLI link:       $LOCALVLLM_CLI_LINK"
fi
echo

echo "Will keep:"
if [ "$KEEP_VENV" -eq 1 ]; then
  echo "  virtual environments (--keep-venv)"
fi
if [ "$REMOVE_MODELS" -eq 0 ]; then
  echo "  models: $MODELS_ROOT"
fi
if [ "$REMOVE_HF_CACHE" -eq 0 ]; then
  echo "  HF cache: $AI_DIR/${LOCALVLLM_HF_CACHE_SUBDIR:-hf-cache}"
fi
echo

if ! confirm "Continue?"; then
  echo "Uninstall cancelled."
  exit 0
fi

###############################################################################
# STOP AND REMOVE SERVICES
###############################################################################

for BACKEND in "${REMOVE_BACKENDS[@]}"; do
  localvllm_use_backend "$BACKEND" || continue

  if localvllm_has_user_service; then
    log "Stopping and disabling $LOCALVLLM_SERVICE_NAME"
    systemctl --user stop "$LOCALVLLM_SERVICE_NAME" || warn "could not stop $LOCALVLLM_SERVICE_NAME"
    systemctl --user disable "$LOCALVLLM_SERVICE_NAME" || warn "could not disable $LOCALVLLM_SERVICE_NAME"
  elif [ -x "$BIN_DIR/stop.sh" ]; then
    log "Stopping $LOCALVLLM_BACKEND_LABEL with helper script"
    "$BIN_DIR/stop.sh" "$BACKEND" || warn "could not stop $LOCALVLLM_BACKEND_LABEL"
  fi

  remove_if_exists "$SERVICE_FILE"
  remove_if_exists "$CONF_DIR"
  remove_if_exists "$LOG_FILE"
  [ "$KEEP_VENV" -eq 1 ] || remove_if_exists "$VENV_DIR"
done

if [ "$REMOVE_ALL" -eq 1 ] && [ "$KEEP_VENV" -eq 0 ]; then
  remove_if_exists "$VENV_ROOT/.localvllm-python"
  remove_if_exists "$VENV_ROOT/.localvllm-tools"
fi

if command -v systemctl >/dev/null 2>&1; then
  systemctl --user daemon-reload || warn "could not reload the systemd user manager"
  for BACKEND in "${REMOVE_BACKENDS[@]}"; do
    localvllm_use_backend "$BACKEND" || continue
    systemctl --user reset-failed "$LOCALVLLM_SERVICE_NAME" >/dev/null 2>&1 || true
  done
fi

###############################################################################
# MODELS AND CACHE
###############################################################################

if [ "$REMOVE_MODELS" -eq 1 ]; then
  if [ "$REMOVE_ALL" -eq 1 ]; then
    remove_if_exists "$MODELS_ROOT"
  else
    for BACKEND in "${REMOVE_BACKENDS[@]}"; do
      remove_if_exists "$MODELS_ROOT/$BACKEND"
    done
  fi
fi

if [ "$REMOVE_HF_CACHE" -eq 1 ]; then
  remove_if_exists "$AI_DIR/${LOCALVLLM_HF_CACHE_SUBDIR:-hf-cache}"
fi

# If a partial uninstall removed the default backend, point the default at
# another installed backend instead of leaving a dangling default.
if [ "$REMOVE_ALL" -eq 0 ] && [ -f "$CONF_ROOT/localvllm.conf" ]; then
  for BACKEND in $(localvllm_backend_list); do
    case " ${REMOVE_BACKENDS[*]} " in
      *" $BACKEND "*) continue ;;
    esac
    localvllm_use_backend "$BACKEND" || continue
    if localvllm_backend_installed "$BACKEND"; then
      if [ "$LOCALVLLM_DEFAULT_BACKEND" != "$BACKEND" ]; then
        set_conf_value "$CONF_ROOT/localvllm.conf" LOCALVLLM_DEFAULT_BACKEND "$BACKEND" || true
        echo "Default backend changed to: $BACKEND"
      fi
      break
    fi
  done
fi

###############################################################################
# GLOBAL FILES
###############################################################################

if [ "$REMOVE_ALL" -eq 1 ]; then
  log "Removing Local vLLM helper files and configuration"
  remove_if_exists "$BIN_DIR"
  remove_if_exists "$LIB_DIR"
  remove_if_exists "$CONF_ROOT"
  remove_if_exists "$LOCALVLLM_CLI_LINK"
  remove_if_exists "$AI_DIR/$LOCALVLLM_LOGS_SUBDIR"

  # Remove the venv root only when it is empty (per-backend venvs were already
  # removed unless --keep-venv was used).
  rmdir "$VENV_ROOT" 2>/dev/null || true

  if [ -d "$AI_DIR" ] && [ -z "$(find "$AI_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
    rmdir "$AI_DIR"
  fi
fi

echo
echo "Local vLLM uninstall completed."
if [ -d "$MODELS_ROOT" ]; then
  echo "Models were kept in $MODELS_ROOT"
fi

#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2154,SC2153

config_assignment_value() {
  local key="$1"
  local file="$2"
  local value

  [ -f "$file" ] || return 1
  # Configuration files are Bash fragments written by this manager, so source
  # them in a private subshell instead of re-implementing shell quoting. This
  # preserves spaces and %q escapes in paths.
  value="$(
    set +u
    # shellcheck disable=SC1090
    . "$file" >/dev/null 2>&1 || exit 1
    eval "printf '%s' \"\${$key-}\""
  )" || return 1
  printf '%s' "$value"
}

# Preserve user-tuned runtime settings when the packaged config is refreshed.
# Literal assignments retain their original quoting across repeated refreshes.
append_runtime_tuning() {
  local installed_conf="${CONF_ROOT:-$CONF_DIR}/localvllm.conf"
  local source_conf="$1"
  local marker="$2"
  local key value
  local -a keys=(
    LOCALVLLM_LLAMA_SWAP_BIN
    LOCALVLLM_LLAMA_SWAP_VERSION
    LOCALVLLM_DEFAULT_BACKEND
    LOCALVLLM_BACKENDS
    LOCALVLLM_SYSTEMD_USER_DIR
    LOCALVLLM_USER_BIN_DIR
    LOCALVLLM_VLLM_PORT
    LOCALVLLM_OMNI_PORT
    LOCALVLLM_VLLM_SERVICE_NAME
    LOCALVLLM_OMNI_SERVICE_NAME
    LOCALVLLM_LISTEN_HOST
    LOCALVLLM_DEFAULT_PORT
    LOCALVLLM_HF_HOME
    LOCALVLLM_HF_TOKEN
    LOCALVLLM_CUDA_VISIBLE_DEVICES
    LOCALVLLM_MODEL
    LOCALVLLM_HEALTH_CHECK_TIMEOUT
    LOCALVLLM_STOP_TIMEOUT
    LOCALVLLM_LOG_KEEP
    LOCALVLLM_INSTALL_MIN_FREE_GB
    LOCALVLLM_PIP_CACHE
    LOCALVLLM_ALLOW_INSECURE_PUBLIC
    LOCALVLLM_REQUIRE_API_KEY
    LOCALVLLM_MODELS_OVERRIDE_SUBDIR
    LOCALVLLM_SERVICE_NAME
    LOCALVLLM_CLI_NAME
    LOCALVLLM_UV_VERSION
    LOCALVLLM_UV_INSTALL_SHA256
    VLLM_VERSION
    VLLM_PIP_ARGS
    VLLM_TARGET_DEVICE
    VLLM_ALLOW_CPU
    VLLM_OMNI
    VLLM_OMNI_VERSION
    VLLM_OMNI_EXTRAS
    VLLM_OMNI_PIP_ARGS
    VLLM_ENGINE_DEFAULTS
    VLLM_TENSOR_PARALLEL_SIZE
    VLLM_GPU_MEMORY_UTILIZATION
    VLLM_MAX_MODEL_LEN
    VLLM_DTYPE
    VLLM_QUANTIZATION
    VLLM_MAX_NUM_SEQS
    VLLM_MAX_NUM_BATCHED_TOKENS
    VLLM_KV_CACHE_DTYPE
    VLLM_SWAP_SPACE
    VLLM_CPU_OFFLOAD_GB
    VLLM_ENFORCE_EAGER
    VLLM_TRUST_REMOTE_CODE
    VLLM_DISABLE_LOG_REQUESTS
    VLLM_ENABLE_SLEEP
    VLLM_SERVED_MODEL_NAME
    VLLM_REVISION
    VLLM_CODE_REVISION
    VLLM_TOKENIZER_REVISION
    VLLM_TOKENIZER
    VLLM_LOAD_FORMAT
    VLLM_CHAT_TEMPLATE
    VLLM_REASONING_PARSER
    VLLM_TOOL_CALL_PARSER
    VLLM_EXTRA_ARGS
    VLLM_EXTRA_ENV
  )

  local content=""
  local line

  for key in "${keys[@]}"; do
    # Preserve the shell representation itself. Re-escaping a %q assignment
    # adds literal backslashes on every refresh. Empty assignments matter too.
    line="$(awk -v key="$key" 'index($0, key "=") == 1 {last=$0} END {print last}' "$source_conf" 2>/dev/null || true)"
    [ -n "$line" ] || continue
    value="${line#*=}"
    # Packaged defaults must continue to expand from the new configuration.
    case "$value" in
      *'${'*|*'$('*|*'`'*) continue ;;
    esac
    content+="$line"$'\n'
  done

  if [ -n "$content" ]; then
    {
      echo
      printf '# Runtime tuning preserved by %s.\n' "$marker"
      printf '%s' "$content"
    } >> "$installed_conf"
  fi
}

localvllm_config_marker() {
  local conf_root="${1:-${CONF_ROOT:-}}"

  printf '%s/.localvllm-config.sha256\n' "$conf_root"
}

write_config_marker() {
  local source_conf="$1"
  local conf_root="${2:-${CONF_ROOT:-}}"
  local marker

  [ -f "$source_conf" ] || return 0
  marker="$(localvllm_config_marker "$conf_root")"
  mkdir -p "$(dirname "$marker")"
  sha256sum "$source_conf" | awk '{print $1}' > "$marker"
}

# localvllm_source_changed SOURCE_DIR CONF_ROOT
# Returns 0 when at least one installed script/library/config differs from the
# source tree. The config comparison uses a marker because the installed config
# intentionally contains appended runtime tuning.
localvllm_source_changed() {
  local source_dir="$1"
  local conf_root="$2"
  local script rel path marker

  [ -n "$source_dir" ] || return 1
  [ "$source_dir" != "$AI_DIR" ] || return 1

  for script in localvllm start.sh stop.sh rebuild-config.sh update-localvllm.sh uninstall-localvllm.sh install-localvllm.sh; do
    [ -f "$source_dir/$script" ] || continue
    if ! cmp -s "$source_dir/$script" "$BIN_DIR/$script"; then
      return 0
    fi
  done

  if [ -d "$source_dir/lib" ]; then
    while IFS= read -r path; do
      rel="${path#"$source_dir/lib/"}"
      if ! cmp -s "$path" "$LIB_DIR/$rel"; then
        return 0
      fi
    done < <(find "$source_dir/lib" -type f | sort)
  fi

  marker="$(localvllm_config_marker "$conf_root")"
  if [ ! -f "$marker" ]; then
    return 0
  fi
  if [ "$(sha256sum "$source_dir/localvllm.conf" | awk '{print $1}')" != "$(cat "$marker" 2>/dev/null || true)" ]; then
    return 0
  fi

  return 1
}

set_conf_value() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp

  [ -f "$file" ] || return 1
  tmp="$(mktemp "${file}.XXXXXX")" || return 1
  if ! awk -v key="$key" -v value="$value" '
    BEGIN { found = 0 }
    $0 ~ "^" key "=" {
      print key "=" value
      found = 1
      next
    }
    { print }
    END {
      if (!found) print key "=" value
    }
  ' "$file" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$file"
}

write_systemd_user_service() {
  local service_file="$1"
  local bin_dir="$2"
  local backend="$3"
  local label

  label="$(localvllm_backend_label "$backend")"
  mkdir -p "$(dirname "$service_file")"

  cat > "$service_file" <<EOF
[Unit]
Description=Local ${label} OpenAI Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=LOCALVLLM_SYSTEMD_UNIT=1
ExecStart=$bin_dir/start.sh $backend
Restart=on-failure
RestartSec=5
TimeoutStartSec=1800
TimeoutStopSec=180

[Install]
WantedBy=default.target
EOF
}

write_backend_profile() {
  local conf_root="$1"
  local backend="$2"
  local profile_dir="$conf_root/${LOCALVLLM_BACKEND_PROFILES_SUBDIR:-backends.d}"
  local profile="$profile_dir/$backend.conf"

  mkdir -p "$profile_dir"
  [ -f "$profile" ] && return 0

  case "$backend" in
    vllm)
      cat > "$profile" <<'EOF'
# Plain vLLM backend profile.
# This file is sourced after conf/localvllm.conf whenever this backend is
# activated. Keep values backend-specific; edit conf/localvllm.conf for
# defaults shared by both backends.
#
# Text / embedding / reranking models live in models/vllm and in
# conf/backends/vllm/models.d. vLLM-Omni models belong in the omni backend.

VLLM_OMNI=0
VLLM_MAX_MODEL_LEN="${VLLM_MAX_MODEL_LEN-8192}"
EOF
      ;;
    omni)
      cat > "$profile" <<'EOF'
# vLLM-Omni backend profile.
# Omni models (text, image, audio, video, action) live in models/omni and in
# conf/backends/omni/models.d. Keep VLLM_VERSION and VLLM_OMNI_VERSION on the
# same release line when pinning (for example both 0.32.0).
#
# vLLM-Omni is served by the same command with --omni. Set
# VLLM_MAX_MODEL_LEN= (an explicitly empty value) to let each omni model's own
# deployment config decide, or set a value here to cap it for every omni model.

VLLM_OMNI=1
VLLM_MAX_MODEL_LEN="${VLLM_MAX_MODEL_LEN-8192}"
VLLM_TENSOR_PARALLEL_SIZE="${VLLM_TENSOR_PARALLEL_SIZE:-1}"
VLLM_GPU_MEMORY_UTILIZATION="${VLLM_GPU_MEMORY_UTILIZATION:-0.90}"
EOF
      ;;
    *)
      return 1
      ;;
  esac
}

install_localvllm_libs() {
  local source_dir="$1"
  local dest_dir="$2"
  local path rel

  mkdir -p "$dest_dir"
  while IFS= read -r path; do
    rel="${path#"$source_dir/lib/"}"
    mkdir -p "$dest_dir/$(dirname "$rel")"
    install -m644 "$path" "$dest_dir/$rel"
  done < <(find "$source_dir/lib" -type f | sort)
}

ensure_cli_on_path() {
  case ":$PATH:" in
    *":$LOCALVLLM_USER_BIN_DIR:"*) return 0 ;;
  esac

  local rc_file
  case "${SHELL:-}" in
    */zsh) rc_file="$HOME/.zshrc" ;;
    */bash) rc_file="$HOME/.bashrc" ;;
    *) rc_file="$HOME/.profile" ;;
  esac

  if grep -qF "$LOCALVLLM_USER_BIN_DIR" "$rc_file" 2>/dev/null; then
    echo "IMPORTANT: the 'localvllm' command will not work in THIS terminal window yet."
    echo "$rc_file already references $LOCALVLLM_USER_BIN_DIR, but this window started before that took effect."
    echo "Run this now:  source $rc_file"
    echo "(or just open a new terminal window)"
    echo
    return 2
  fi

  if [ -w "$rc_file" ] || { [ ! -e "$rc_file" ] && [ -w "$(dirname "$rc_file")" ]; }; then
    {
      echo
      echo "# Added by the Local vLLM installer: run \`localvllm\` from anywhere"
      echo "if [ -d \"$LOCALVLLM_USER_BIN_DIR\" ] ; then"
      echo "    PATH=\"$LOCALVLLM_USER_BIN_DIR:\$PATH\""
      echo "fi"
    } >> "$rc_file"
    echo "IMPORTANT: the 'localvllm' command will not work in THIS terminal window yet."
    echo "Added $LOCALVLLM_USER_BIN_DIR to PATH in $rc_file, but only new terminal windows pick that up."
    echo "Run this now:  source $rc_file"
    echo "(or just open a new terminal window)"
    echo
    return 2
  fi

  echo "Note: $LOCALVLLM_USER_BIN_DIR is not in your PATH, and $rc_file isn't writable."
  echo "Add it to your shell profile manually to run localvllm from anywhere."
  echo
  return 1
}

reconnect_shell_on_path() {
  local ensure_status="$1"

  [ "$ensure_status" -eq 2 ] || return 0
  [ -t 1 ] || return 0
  [ -r /dev/tty ] || return 0
  [ -n "${SHELL:-}" ] && command -v "$SHELL" >/dev/null 2>&1 || return 0

  echo "Switching this terminal to a fresh shell so 'localvllm' works right now..."
  echo
  exec "$SHELL" -i < /dev/tty
}

vllm_detect_target_device() {
  if [ -n "${VLLM_TARGET_DEVICE:-}" ]; then
    case "$VLLM_TARGET_DEVICE" in
      cuda|rocm|cpu) printf '%s\n' "$VLLM_TARGET_DEVICE" ;;
      *) echo 'Error: VLLM_TARGET_DEVICE must be cuda, rocm, or cpu.' >&2; return 1 ;;
    esac
    return 0
  fi

  if command -v nvidia-smi >/dev/null 2>&1 &&
    nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | grep -q .; then
    printf 'cuda\n'
    return 0
  fi

  if command -v rocm-smi >/dev/null 2>&1 || [ -e /dev/kfd ]; then
    printf 'rocm\n'
    return 0
  fi

  printf 'cpu\n'
}

vllm_device_hint() {
  case "$1" in
    cuda)
      printf '%s' "NVIDIA CUDA (nvidia-smi detected)"
      ;;
    rocm)
      printf '%s' "AMD ROCm (ROCm runtime detected). ROCm vLLM may need a ROCm-specific wheel/index; see VLLM_PIP_ARGS."
      ;;
    cpu)
      if [ "${VLLM_ALLOW_CPU:-0}" = "1" ]; then
        printf '%s' "CPU only (VLLM_ALLOW_CPU=1). vLLM on the CPU is slow and needs a CPU build of vLLM."
      else
        printf '%s' "CPU only. vLLM CPU is slow and may require a source build; set VLLM_ALLOW_CPU=1 to try it."
      fi
      ;;
    *)
      printf '%s' "$1"
      ;;
  esac
}

# vLLM-Omni's published releases currently support Python 3.11 through 3.13.
# Prefer 3.12 for new environments (also the current ROCm wheel target).
localvllm_omni_python_ok() {
  local version
  version="$(python_version "$1")" || return 1
  if [ "${VLLM_TARGET_DEVICE:-}" = rocm ]; then
    [[ "$version" =~ ^3\.12(\.|$) ]]
  else
    [[ "$version" =~ ^3\.(11|12|13)(\.|$) ]]
  fi
}

localvllm_python_can_create_venv() {
  "$1" -c 'import venv, ensurepip' >/dev/null 2>&1
}

localvllm_find_compatible_python() {
  local candidate uv_bin installer uv_version uv_sha256 python_path backend="${1:-omni}"
  # Honor a deliberately configured interpreter. Plain vLLM may support a
  # newer Python than Omni; let pip validate a specific plain vLLM version.
  if [ "${LOCALVLLM_PYTHON:-python3}" != python3 ]; then
    if localvllm_python_can_create_venv "$LOCALVLLM_PYTHON" &&
      { [ "${VLLM_TARGET_DEVICE:-}" != rocm ] || localvllm_omni_python_ok "$LOCALVLLM_PYTHON"; } &&
      { { [ "$backend" = vllm ] && python_meets_minimum "$LOCALVLLM_PYTHON" "${LOCALVLLM_MIN_PYTHON:-3.10}"; } ||
        { [ "$backend" = omni ] && localvllm_omni_python_ok "$LOCALVLLM_PYTHON"; }; }; then
      command -v "$LOCALVLLM_PYTHON" || printf '%s\n' "$LOCALVLLM_PYTHON"
      return 0
    fi
    echo "Error: configured Python ($LOCALVLLM_PYTHON) is unusable or incompatible with $backend." >&2
    echo "Use Python 3.11–3.13 with venv and ensurepip for Omni; ROCm wheels require Python 3.12." >&2
    return 1
  fi
  for candidate in python3.12 python3.13 python3.11 python3; do
    if command -v "$candidate" >/dev/null 2>&1 && localvllm_omni_python_ok "$candidate" &&
      localvllm_python_can_create_venv "$candidate"; then
      command -v "$candidate"
      return 0
    fi
  done
  # Reuse a managed interpreter first. Everything stays inside the install dir.
  uv_bin="$AI_DIR/${LOCALVLLM_VENV_SUBDIR:-venv}/.localvllm-tools/uv"
  if [ ! -x "$uv_bin" ]; then
    if command -v uv >/dev/null 2>&1; then
      uv_bin="$(command -v uv)"
    else
      echo "Python 3.11–3.13 was not found. Downloading uv and an isolated Python 3.12..." >&2
      mkdir -p "$AI_DIR/${LOCALVLLM_VENV_SUBDIR:-venv}/.localvllm-tools" || return 1
      installer="$(mktemp)" || return 1
      uv_version="${LOCALVLLM_UV_VERSION:-0.13.7}"
      uv_sha256="${LOCALVLLM_UV_INSTALL_SHA256:-d263ee68314cf5bea36b08e6bd9e2c4563240d7adb73756cf33af5c199b92db4}"
      if ! curl -fsSL "https://astral.sh/uv/${uv_version}/install.sh" -o "$installer"; then
        rm -f "$installer"
        echo "Error: could not download the pinned uv installer. Install Python 3.12 and retry." >&2
        return 1
      fi
      if [ "$(sha256sum "$installer" | awk '{print $1}')" != "$uv_sha256" ]; then
        rm -f "$installer"
        echo "Error: uv installer checksum verification failed; refusing to execute it." >&2
        return 1
      fi
      if ! UV_UNMANAGED_INSTALL="$AI_DIR/${LOCALVLLM_VENV_SUBDIR:-venv}/.localvllm-tools" sh "$installer" >&2; then
        rm -f "$installer"
        echo "Error: could not install uv. Install Python 3.12 and retry." >&2
        return 1
      fi
      rm -f "$installer"
    fi
  fi
  echo "Preparing an isolated Python 3.12 in $AI_DIR/${LOCALVLLM_VENV_SUBDIR:-venv}/.localvllm-python..." >&2
  if ! UV_PYTHON_INSTALL_DIR="$AI_DIR/${LOCALVLLM_VENV_SUBDIR:-venv}/.localvllm-python" "$uv_bin" python install 3.12 --no-bin >&2; then
    echo "Error: could not download Python 3.12. Install it using your system package manager and retry." >&2
    return 1
  fi
  python_path="$(UV_PYTHON_INSTALL_DIR="$AI_DIR/${LOCALVLLM_VENV_SUBDIR:-venv}/.localvllm-python" "$uv_bin" python find 3.12 --managed-python)" || return 1
  localvllm_omni_python_ok "$python_path" || return 1
  printf '%s\n' "$python_path"
}

vllm_venv_create() {
  local venv="$1"
  local python="$2"

  if [ -x "$venv/bin/python" ]; then
    return 0
  fi

  mkdir -p "$(dirname "$venv")"
  "$python" -m venv "$venv" || {
    echo "Error: failed to create a Python virtual environment at $venv." >&2
    echo "Install the venv package for your Python (for example python3-venv) and retry." >&2
    return 1
  }
}

# installer_rerun_command [ENV]: the command a user should run to retry the
# install with optional ENV assignments. Under `curl ... | bash` the installer
# runs from a temporary checkout the bootstrap deletes on exit, so its own path
# ($0) would be useless advice; the bootstrap sets LOCALVLLM_BOOTSTRAP=1.
installer_rerun_command() {
  local env="${1:-}"
  if [ "${LOCALVLLM_BOOTSTRAP:-0}" = "1" ]; then
    printf 'curl -fsSL %s | %sbash\n' "${LOCALVLLM_BOOTSTRAP_URL:-https://hossbit.github.io/localvllm/install.sh}" "${env:+$env }"
  else
    printf '%s%s\n' "${env:+$env }" "$0"
  fi
}

# vllm_install_space_required DIR: a new environment holds PyTorch, vLLM and
# the CUDA libraries (about 15-17 GB with FlashInfer kernels). Refuse early
# instead of failing with "No space left on device" halfway through pip.
# LOCALVLLM_INSTALL_MIN_FREE_GB=0 turns the check off.
vllm_install_space_required() {
  local dir="$1"
  local min_gb="${LOCALVLLM_INSTALL_MIN_FREE_GB:-20}" available required

  [[ "$min_gb" =~ ^[0-9]+$ ]] && [ "$min_gb" -gt 0 ] || return 0
  while [ ! -d "$dir" ] && [ "$dir" != "/" ]; do dir="$(dirname "$dir")"; done
  available="$(df -PB1 "$dir" 2>/dev/null | awk 'NR == 2 { print $4 }')"
  [[ "$available" =~ ^[0-9]+$ ]] || return 0
  required=$((min_gb * 1024 * 1024 * 1024))
  if [ "$available" -lt "$required" ]; then
    echo "Error: not enough free disk space for a new vLLM environment in $dir." >&2
    echo "It needs about $(format_bytes_human "$required") free; $(format_bytes_human "$available") is available." >&2
    echo "Free space or choose another install location (LOCALVLLM_DIR=/path/with/space)." >&2
    echo "To try anyway, set LOCALVLLM_INSTALL_MIN_FREE_GB=0." >&2
    return 1
  fi
  return 0
}

vllm_venv_update_space_required() {
  local venv="$1"
  local size="" available="" required

  # The staged copy keeps the old environment until the service starts, so an
  # update can need roughly twice the venv size. Reflinks reduce this, but the
  # check errs on the side of refusing a likely out-of-space update.
  [ -d "$venv" ] || return 0
  size="$(du -sb "$venv" 2>/dev/null | awk 'NR == 1 { print $1 }')"
  [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -gt 0 ] || return 0

  required=$((size * 2))
  available="$(df -PB1 "$(dirname "$venv")" 2>/dev/null | awk 'NR == 2 { print $4 }')"
  if [[ "$available" =~ ^[0-9]+$ ]] && [ "$available" -lt "$required" ]; then
    echo "Error: not enough free disk space to update $venv." >&2
    echo "The staged update needs about $(format_bytes_human "$required") free; $(format_bytes_human "$available") is available." >&2
    echo "Free space, choose another install location, or run 'localvllm update --scripts-only'." >&2
    return 1
  fi
  return 0
}

vllm_venv_stage_update() {
  local venv="$1"
  local stage="$venv.update.$$"

  vllm_venv_update_space_required "$venv" || return 1

  rm -rf "$stage"
  if ! cp -a --reflink=auto "$venv" "$stage" 2>/dev/null; then
    rm -rf "$stage"
    cp -a "$venv" "$stage" || {
      rm -rf "$stage"
      return 1
    }
  fi
  printf '%s\n' "$stage"
}

vllm_venv_commit_update() {
  local venv="$1"
  local stage="$2"
  local old="$venv.previous.$$"

  # pip generates entry points with the staging interpreter's absolute path.
  # Rewrite them before promotion, while that interpreter still exists.
  if ! "$stage/bin/python" - "$stage" "$venv" <<'PYTHON'
import os
import pathlib
import sys

stage, destination = map(os.fsencode, sys.argv[1:])
for path in (pathlib.Path(sys.argv[1]) / "bin").iterdir():
    if path.is_symlink() or not path.is_file():
        continue
    content = path.read_bytes()
    if b"\0" not in content and stage in content:
        path.write_bytes(content.replace(stage, destination))
PYTHON
  then
    rm -rf "$stage"
    return 1
  fi

  rm -rf "$old"
  if ! mv "$venv" "$old"; then
    rm -rf "$stage"
    return 1
  fi
  if ! mv "$stage" "$venv"; then
    mv "$old" "$venv" || true
    return 1
  fi
  # Keep the previous environment until the service has started successfully.
  printf '%s\n' "$old"
  return 0
}

vllm_venv_rollback_update() {
  local venv="$1"
  local old="$2"

  [ -e "$old" ] || return 1
  rm -rf "$venv"
  mv "$old" "$venv"
}

vllm_venv_finish_update() {
  local old="$1"

  [ -n "$old" ] && [ -e "$old" ] && rm -rf "$old"
  return 0
}

# --- Rollback environment ----------------------------------------------------
# After a successful update the environment it replaced is kept beside the
# live one as "<venv>.previous" (LOCALVLLM_KEEP_PREVIOUS=1, the default), with
# its environment record, so `localvllm rollback` can switch back. Each
# backend keeps its own complete environment: a rollback never downgrades a
# single package inside a shared set. The active environment always lives at
# the original path, so pip entry points written for that path stay valid.

vllm_venv_previous_dir() {
  printf '%s.previous\n' "$1"
}

vllm_venv_has_previous() {
  [ -x "$(vllm_venv_previous_dir "$1")/bin/python" ]
}

# vllm_venv_keep_previous VENV OLD CONF_DIR: called once the updated service
# works. OLD is the replaced environment from vllm_venv_commit_update; CONF_DIR
# still holds that environment's record (written before this update).
vllm_venv_keep_previous() {
  local venv="$1" old="$2" conf_dir="$3" previous file

  [ -n "$old" ] && [ -e "$old" ] || return 0
  previous="$(vllm_venv_previous_dir "$venv")"
  if [ "${LOCALVLLM_KEEP_PREVIOUS:-1}" != "1" ]; then
    rm -rf "$old" "$previous"
    return 0
  fi
  for file in environment.txt environment.lock; do
    if [ -f "$conf_dir/$file" ]; then
      cp -p "$conf_dir/$file" "$old/.localvllm-$file" 2>/dev/null || true
    fi
  done
  rm -rf "$previous"
  mv "$old" "$previous"
}

# vllm_venv_swap_previous VENV CONF_DIR: exchange the live and previous
# environments together with their records. Running it twice is a no-op, so
# the same call both rolls back and returns to the newer environment.
vllm_venv_swap_previous() {
  local venv="$1" conf_dir="$2" previous tmp file

  previous="$(vllm_venv_previous_dir "$venv")"
  [ -x "$previous/bin/python" ] || return 1
  tmp="$venv.swap.$$"
  rm -rf "$tmp"
  mv "$venv" "$tmp" || return 1
  if ! mv "$previous" "$venv"; then
    mv "$tmp" "$venv"
    return 1
  fi
  mv "$tmp" "$previous" || return 1

  # The record in CONF_DIR described the environment now at $previous.
  for file in environment.txt environment.lock; do
    if [ -f "$conf_dir/$file" ]; then
      mv -f "$conf_dir/$file" "$tmp.$file"
    fi
    if [ -f "$venv/.localvllm-$file" ]; then
      mv -f "$venv/.localvllm-$file" "$conf_dir/$file"
    fi
    if [ -f "$tmp.$file" ]; then
      mv -f "$tmp.$file" "$previous/.localvllm-$file"
    fi
  done
  return 0
}

# vllm_pip_cache_env: keep pip from filling its download cache unless
# LOCALVLLM_PIP_CACHE=1. The wheels are several GB (PyTorch, CUDA libraries)
# and the cache would otherwise stay in ~/.cache/pip after every install and
# update. A PIP_NO_CACHE_DIR the user already exported wins.
vllm_pip_cache_env() {
  [ "${LOCALVLLM_PIP_CACHE:-0}" = "1" ] || export PIP_NO_CACHE_DIR="${PIP_NO_CACHE_DIR:-1}"
}

vllm_bootstrap_pip() {
  local venv="$1"
  local log_file="${2:-}"

  vllm_pip_cache_env

  if [ -n "$log_file" ]; then
    mkdir -p "$(dirname "$log_file")"
    if ! "$venv/bin/python" -m pip install --upgrade pip setuptools wheel >>"$log_file" 2>&1; then
      echo "Error: could not upgrade pip/setuptools/wheel in $venv." >&2
      tail -n 30 "$log_file" >&2 || true
      return 1
    fi
  else
    "$venv/bin/python" -m pip install --upgrade pip setuptools wheel || return 1
  fi
}

# `pip check`, except for the one complaint FlashInfer's GPU-only kernel
# install causes by design: its flashinfer-jit-cache shim lists every
# architecture's provider, and only this GPU's provider is installed.
vllm_pip_check() {
  local venv="$1"
  local report

  report="$("$venv/bin/python" -m pip check 2>&1)" && return 0
  report="$(printf '%s\n' "$report" | grep -Ev '^flashinfer-jit-cache [^ ]+ requires flashinfer-jit-cache-sm[0-9]+[a-z]*, which is not installed\.$' | grep -v '^[[:space:]]*$')"
  [ -z "$report" ]
}

vllm_pip_install() {
  local venv="$1"
  local version="$2"
  local pip_args="${3:-}"
  local log_file="${4:-}"
  local python="$venv/bin/python"
  local -a pip_extra=()
  local -a command=("$python" -m pip install --upgrade)
  vllm_pip_cache_env

  if [ ! -x "$python" ]; then
    echo "Error: Python is missing from $venv." >&2
    return 1
  fi

  if [ -n "$pip_args" ]; then
    read -r -a pip_extra <<< "$pip_args"
    command+=("${pip_extra[@]}")
  fi

  if [ "$version" = "latest" ]; then
    command+=(vllm)
  else
    command+=("vllm==$version")
  fi

  if [ -n "$log_file" ]; then
    mkdir -p "$(dirname "$log_file")"
    if ! "${command[@]}" 2>&1 | tee -a "$log_file"; then
      echo "Error: vLLM installation failed. Full log: $log_file" >&2
      tail -n 40 "$log_file" >&2 || true
      return 1
    fi
  else
    "${command[@]}" || return 1
  fi
}

# Install vLLM and vLLM-Omni in a single resolver transaction so pip selects a
# compatible pair instead of installing vLLM, then silently downgrading it.
vllm_pip_install_both() {
  local venv="$1"
  local vllm_version="$2"
  local omni_version="$3"
  local omni_extras="${4:-}"
  local vllm_pip_args="${5:-}"
  local omni_pip_args="${6:-}"
  local log_file="${7:-}"
  local python="$venv/bin/python"
  local omni_spec
  local -a vllm_extra=()
  local -a omni_extra=()
  local -a command=("$python" -m pip install --upgrade)
  vllm_pip_cache_env

  if [ ! -x "$python" ]; then
    echo "Error: Python is missing from $venv." >&2
    return 1
  fi

  [ -n "$vllm_pip_args" ] && read -r -a vllm_extra <<< "$vllm_pip_args"
  [ -n "$omni_pip_args" ] && read -r -a omni_extra <<< "$omni_pip_args"
  command+=("${vllm_extra[@]}" "${omni_extra[@]}")

  # Omni metadata does not always constrain vLLM, but the projects require
  # matching releases. Resolve the Omni release first instead of installing
  # an unrelated, newer vLLM release.
  if [ "$vllm_version" = "latest" ]; then
    if [ "$omni_version" = "latest" ]; then
      omni_version="$(vllm_omni_latest_version)" || {
        echo "Error: cannot determine the current vLLM-Omni release; check your network or set VLLM_OMNI_VERSION." >&2
        return 1
      }
    fi
    [[ "$omni_version" =~ ^([0-9]+)\.([0-9]+)\.[0-9]+$ ]] || {
      echo "Error: cannot automatically match vLLM to Omni version '$omni_version'; set VLLM_VERSION explicitly." >&2
      return 1
    }
    command+=("vllm>=${BASH_REMATCH[1]}.${BASH_REMATCH[2]},<${BASH_REMATCH[1]}.$((10#${BASH_REMATCH[2]} + 1))")
  else
    command+=("vllm==$vllm_version")
  fi

  omni_spec="$(vllm_omni_package_spec "$omni_version" "$omni_extras")"
  command+=("$omni_spec")

  if [ -n "$log_file" ]; then
    mkdir -p "$(dirname "$log_file")"
    if ! "${command[@]}" 2>&1 | tee -a "$log_file"; then
      echo "Error: vLLM + vLLM-Omni installation failed. Full log: $log_file" >&2
      tail -n 40 "$log_file" >&2 || true
      return 1
    fi
  else
    "${command[@]}" || return 1
  fi
}

vllm_verify_install() {
  local venv="$1"
  local version

  version="$("$venv/bin/python" -c 'import vllm; print(vllm.__version__)' 2>/dev/null)" || {
    echo "Error: vLLM was installed but could not be imported from $venv." >&2
    echo "Check that your GPU driver/runtime matches the vLLM wheel, then retry." >&2
    return 1
  }

  if [ "${VLLM_TARGET_DEVICE:-}" = rocm ]; then
    if ! "$venv/bin/python" -c 'import torch; assert torch.version.hip, "installed PyTorch is not a ROCm build"' >/dev/null 2>&1; then
      echo 'Error: ROCm was requested, but the installed PyTorch is not a working ROCm build.' >&2
      echo 'Select Python 3.12 and an exact ROCm vLLM version with its matching wheel index; a CUDA/CPU wheel may have been selected.' >&2
      return 1
    fi
  fi
  printf '%s\n' "$version"
}

vllm_omni_package_spec() {
  local version="${1:-latest}"
  local extras="${2:-}"
  local spec="vllm-omni"

  if [ -n "$extras" ]; then
    spec="vllm-omni[$extras]"
  fi
  if [ "$version" != "latest" ]; then
    spec="$spec==$version"
  fi

  printf '%s\n' "$spec"
}

vllm_omni_pip_install() {
  local venv="$1"
  local version="$2"
  local extras="${3:-}"
  local pip_args="${4:-}"
  local log_file="${5:-}"
  local python="$venv/bin/python"
  local -a pip_extra=()
  local -a command=("$python" -m pip install --upgrade)
  vllm_pip_cache_env
  local spec

  if [ ! -x "$python" ]; then
    echo "Error: Python is missing from $venv." >&2
    return 1
  fi

  spec="$(vllm_omni_package_spec "$version" "$extras")"
  if [ -n "$pip_args" ]; then
    read -r -a pip_extra <<< "$pip_args"
    command+=("${pip_extra[@]}")
  fi
  command+=("$spec")

  if [ -n "$log_file" ]; then
    mkdir -p "$(dirname "$log_file")"
    if ! "${command[@]}" 2>&1 | tee -a "$log_file"; then
      echo "Error: vLLM-Omni installation failed. Full log: $log_file" >&2
      tail -n 40 "$log_file" >&2 || true
      return 1
    fi
  else
    "${command[@]}" || return 1
  fi
}

vllm_package_version() {
  local venv="$1" package="$2"

  [ -x "$venv/bin/python" ] || return 0
  "$venv/bin/python" -c 'import sys; from importlib.metadata import version; print(version(sys.argv[1]))' \
    "$package" 2>/dev/null | head -n1 || true
}

# vllm_torch_accelerator VENV: prints e.g. "cuda 13.0", "rocm 6.3" or "cpu",
# read from torch/version.py without importing torch (fast, no GPU access).
# Precompiled FlashInfer kernels. vLLM asks for `vllm download-kernels` after
# every install or upgrade; without the kernels (and without nvcc) it disables
# FlashInfer. LOCALVLLM_DOWNLOAD_KERNELS: 1 installs the cubins plus only the
# JIT cache for this machine's GPU architectures, "all" installs every
# architecture (what `vllm download-kernels` does, about 10 GB), 0 skips it.

vllm_kernels_enabled() {
  case "${LOCALVLLM_DOWNLOAD_KERNELS:-1}" in
    0|off|no|false) return 1 ;;
  esac
  return 0
}

# FlashInfer providers are named after the CUDA architecture: sm86, sm90, ...
vllm_gpu_sm_tags() {
  command -v nvidia-smi >/dev/null 2>&1 || return 0
  nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null |
    sed -n 's/^[[:space:]]*\([0-9][0-9]*\)\.\([0-9][0-9]*\)[[:space:]]*$/sm\1\2/p' | sort -u
}

vllm_kernel_packages() {
  local venv="$1"

  "$venv/bin/python" -m pip list --format=freeze 2>/dev/null |
    sed -n 's/^\(flashinfer-cubin\|flashinfer-jit-cache[A-Za-z0-9_.-]*\)==.*/\1/p'
}

vllm_kernel_size_kb() {
  local venv="$1" site

  site="$("$venv/bin/python" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])' 2>/dev/null)" || {
    echo 0
    return 0
  }
  du -skc "$site/flashinfer_cubin" "$site/flashinfer_jit_cache" 2>/dev/null |
    awk 'END { print ($1 ~ /^[0-9]+$/) ? $1 : 0 }'
}

vllm_remove_kernel_packages() {
  local venv="$1"
  local log_file="${2:-/dev/null}"
  local site dir
  local -a packages=()

  mapfile -t packages < <(vllm_kernel_packages "$venv")
  if [ "${#packages[@]}" -gt 0 ]; then
    "$venv/bin/python" -m pip uninstall -y "${packages[@]}" >>"$log_file" 2>&1 || true
  fi
  # The per-architecture JIT cache wheels share one package directory, and pip
  # leaves its empty tree behind. Python would import that as a namespace
  # package without __version__, which makes `import flashinfer` fail.
  site="$("$venv/bin/python" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])' 2>/dev/null)" || return 0
  for dir in "$site/flashinfer_jit_cache" "$site/flashinfer_cubin"; do
    [ -d "$dir" ] && find "$dir" -depth -type d -empty -delete 2>/dev/null
  done
  return 0
}

vllm_download_kernels() {
  local venv="$1"
  local log_file="${2:-/dev/null}"
  local mode="${LOCALVLLM_DOWNLOAD_KERNELS:-1}"
  local min_free_gb="${LOCALVLLM_KERNELS_MIN_FREE_GB:-15}"
  local avail_kb sm targets=""
  local -a command=("$venv/bin/vllm" download-kernels) sm_args=()

  vllm_kernels_enabled || return 0
  [ -x "$venv/bin/vllm" ] || return 0
  case "$(vllm_torch_accelerator "$venv")" in
    "cuda "*) ;;
    *) return 0 ;;
  esac
  "$venv/bin/vllm" download-kernels --help >/dev/null 2>&1 || return 0

  avail_kb="$(df -Pk "$venv" 2>/dev/null | awk 'NR == 2 { print $4 }')"
  # Kernels already installed are replaced, so their space counts as free.
  if [[ "$avail_kb" =~ ^[0-9]+$ ]]; then
    avail_kb=$((avail_kb + $(vllm_kernel_size_kb "$venv")))
  fi
  if [[ "$avail_kb" =~ ^[0-9]+$ ]] && [[ "$min_free_gb" =~ ^[0-9]+$ ]] &&
    [ "$avail_kb" -lt $((min_free_gb * 1024 * 1024)) ]; then
    echo "Warning: skipping precompiled vLLM kernels: less than ${min_free_gb} GB free next to $venv." >&2
    echo "Free some space, then run: localvllm update" >&2
    return 0
  fi

  # Kernels built for another FlashInfer version stop FlashInfer from loading,
  # so start from none (before asking FlashInfer what it supports) rather than upgrading on top of older ones.
  vllm_remove_kernel_packages "$venv" "$log_file"

  if [ "$mode" != all ]; then
    while IFS= read -r sm; do
      [ -n "$sm" ] || continue
      sm_args+=(--sm "$sm")
      targets="${targets:+$targets }$sm"
    done < <(vllm_gpu_sm_tags)
    if [ "${#sm_args[@]}" -gt 0 ] &&
      FLASHINFER_DISABLE_VERSION_CHECK=1 "$venv/bin/python" -m flashinfer download-kernels --help 2>/dev/null | grep -q -- '--sm'; then
      command=(env FLASHINFER_DISABLE_VERSION_CHECK=1 "$venv/bin/python" -m flashinfer download-kernels "${sm_args[@]}")
      targets=" for $targets"
    elif FLASHINFER_DISABLE_VERSION_CHECK=1 "$venv/bin/python" -m flashinfer install-cubin-wheel --help >/dev/null 2>&1; then
      # This FlashInfer cannot limit the JIT cache to one GPU; the cubins alone
      # still enable FlashInfer without downloading every architecture.
      command=(env FLASHINFER_DISABLE_VERSION_CHECK=1 "$venv/bin/python" -m flashinfer install-cubin-wheel)
      targets=" (cubins only)"
    else
      targets=""
    fi
  fi
  if [ "$mode" = all ]; then
    targets=" for every GPU architecture"
  fi

  echo "Installing precompiled vLLM kernels${targets}..."
  if ! "${command[@]}" >>"$log_file" 2>&1; then
    echo "Warning: the precompiled vLLM kernel download failed; vLLM still works without them. Log: $log_file" >&2
  fi
  if ! "$venv/bin/python" -c 'import flashinfer' >/dev/null 2>&1; then
    echo "Warning: FlashInfer did not load with the downloaded kernels; removing them." >&2
    vllm_remove_kernel_packages "$venv" "$log_file"
  fi
  return 0
}

# True when vLLM offers `download-kernels` but the FlashInfer cubin package it
# installs is missing, e.g. an environment created before that command existed.
vllm_kernels_missing() {
  local venv="$1"

  vllm_kernels_enabled || return 1
  [ -x "$venv/bin/python" ] || return 1
  "$venv/bin/python" -c 'import importlib.util, sys; sys.exit(0 if importlib.util.find_spec("flashinfer_cubin") else 1)' >/dev/null 2>&1 && return 1
  case "$(vllm_torch_accelerator "$venv")" in
    "cuda "*) ;;
    *) return 1 ;;
  esac
  "$venv/bin/vllm" download-kernels --help >/dev/null 2>&1
}

vllm_torch_accelerator() {
  local venv="$1"

  [ -x "$venv/bin/python" ] || return 0
  "$venv/bin/python" - <<'PYTHON' 2>/dev/null || true
import importlib.util, os, re
spec = importlib.util.find_spec("torch")
if spec and spec.origin:
    text = open(os.path.join(os.path.dirname(spec.origin), "version.py")).read()
    def value(name):
        match = re.search(r"^%s\s*(?::[^=]*)?=\s*['\"]([^'\"]+)['\"]" % name, text, re.M)
        return match.group(1) if match else ""
    cuda, hip = value("cuda"), value("hip")
    print("rocm " + hip if hip else "cuda " + cuda if cuda else "cpu")
PYTHON
}

write_environment_manifest() {
  local venv="$1"
  local conf_dir="$2"
  local backend="$3"
  local active_id=""

  [ -d "$conf_dir" ] || return 0
  if [ -f "$conf_dir/$LOCALVLLM_ACTIVE_MODEL_FILE" ]; then
    active_id="$(<"$conf_dir/$LOCALVLLM_ACTIVE_MODEL_FILE")"
  fi

  # Package versions come from metadata, so this never imports torch or
  # touches the GPU; torch_build is the CUDA/ROCm runtime the PyTorch wheel was
  # built for. The *_policy lines record what was requested
  # (normally "latest"); the versions record what that resolved to.
  {
    printf 'backend=%s\n' "$backend"
    printf 'created=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'python=%s\n' "$(python_version "$venv/bin/python" 2>/dev/null || true)"
    printf 'vllm=%s\n' "$(vllm_installed_version "$venv" 2>/dev/null || true)"
    printf 'vllm_policy=%s\n' "${VLLM_VERSION:-latest}"
    if [ "$backend" = "omni" ]; then
      printf 'vllm_omni=%s\n' "$(vllm_omni_installed_version "$venv" 2>/dev/null || true)"
      printf 'vllm_omni_policy=%s\n' "${VLLM_OMNI_VERSION:-latest}"
    fi
    printf 'torch=%s\n' "$(vllm_package_version "$venv" torch)"
    printf 'torch_build=%s\n' "$(vllm_torch_accelerator "$venv")"
    printf 'target_device=%s\n' "${VLLM_TARGET_DEVICE:-auto}"
    printf 'os=%s\n' "$( (. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-}") || true)"
    printf 'architecture=%s\n' "$(uname -m 2>/dev/null || true)"
    if command -v nvidia-smi >/dev/null 2>&1; then
      printf 'gpu=%s\n' "$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | paste -sd', ' - || true)"
      printf 'driver=%s\n' "$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 || true)"
    fi
    printf 'model=%s\n' "$active_id"
  } > "$conf_dir/environment.txt"

  "$venv/bin/python" -m pip freeze > "$conf_dir/environment.lock" 2>/dev/null || true
  chmod 600 "$conf_dir/environment.lock" 2>/dev/null || true
}

vllm_omni_verify_install() {
  local venv="$1"
  local version

  version="$("$venv/bin/python" -c 'from importlib.metadata import version; print(version("vllm-omni"))' 2>/dev/null)" || {
    echo "Error: vLLM-Omni was installed but its package metadata could not be read from $venv." >&2
    echo "Check that its version matches the installed vLLM release, then retry." >&2
    return 1
  }

  if ! "$venv/bin/python" -c 'import vllm_omni' >/dev/null 2>&1; then
    echo "Error: vLLM-Omni is installed but cannot be imported from $venv." >&2
    echo "Check the GPU driver/runtime and the vLLM/vLLM-Omni version alignment." >&2
    return 1
  fi

  printf '%s\n' "$version"
}

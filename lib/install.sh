#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2154,SC2153

config_assignment_value() {
  local key="$1"
  local file="$2"

  [ -f "$file" ] || return 1
  awk -F= -v key="$key" '
    $1 == key {
      value = substr($0, index($0, "=") + 1)
      gsub(/^[[:space:]"'\'']+|[[:space:]"'\'']+$/, "", value)
      print value
    }
  ' "$file" | tail -n 1
}

# Preserve user-tuned runtime settings when the packaged config is refreshed.
# Literal assignments retain their original quoting across repeated refreshes.
append_runtime_tuning() {
  local installed_conf="${CONF_ROOT:-$CONF_DIR}/localvllm.conf"
  local source_conf="$1"
  local marker="$2"
  local key value
  local -a keys=(
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
    LOCALVLLM_ALLOW_INSECURE_PUBLIC
    LOCALVLLM_REQUIRE_API_KEY
    LOCALVLLM_MODELS_OVERRIDE_SUBDIR
    LOCALVLLM_SERVICE_NAME
    LOCALVLLM_CLI_NAME
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
Type=oneshot
RemainAfterExit=yes
Environment=LOCALVLLM_SYSTEMD_UNIT=1
ExecStart=$bin_dir/start.sh $backend
ExecStop=$bin_dir/stop.sh $backend
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
VLLM_MAX_MODEL_LEN="${VLLM_MAX_MODEL_LEN:-8192}"
EOF
      ;;
    omni)
      cat > "$profile" <<'EOF'
# vLLM-Omni backend profile.
# Omni models (text, image, audio, video, action) live in models/omni and in
# conf/backends/omni/models.d. Keep VLLM_VERSION and VLLM_OMNI_VERSION on the
# same release line when pinning (for example both 0.32.0).
#
# vLLM-Omni is served by the same command with --omni. Leave VLLM_MAX_MODEL_LEN
# empty to let each omni model's own deployment config decide, or set a value
# here to cap it for every omni model.

VLLM_OMNI=1
VLLM_MAX_MODEL_LEN="${VLLM_MAX_MODEL_LEN:-8192}"
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
    printf '%s\n' "$VLLM_TARGET_DEVICE"
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
      printf '%s' "CPU only. vLLM CPU is slow and may require a source build; set VLLM_ALLOW_CPU=1 to try it."
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
  [[ "$version" =~ ^3\.(11|12|13)(\.|$) ]]
}

localvllm_python_can_create_venv() {
  "$1" -c 'import venv, ensurepip' >/dev/null 2>&1
}

localvllm_find_compatible_python() {
  local candidate uv_bin installer python_path backend="${1:-omni}"
  # Honor a deliberately configured interpreter. Plain vLLM may support a
  # newer Python than Omni; let pip validate a specific plain vLLM version.
  if [ "${LOCALVLLM_PYTHON:-python3}" != python3 ]; then
    if localvllm_python_can_create_venv "$LOCALVLLM_PYTHON" &&
      { { [ "$backend" = vllm ] && python_meets_minimum "$LOCALVLLM_PYTHON" "${LOCALVLLM_MIN_PYTHON:-3.10}"; } ||
        { [ "$backend" = omni ] && localvllm_omni_python_ok "$LOCALVLLM_PYTHON"; }; }; then
      command -v "$LOCALVLLM_PYTHON" || printf '%s\n' "$LOCALVLLM_PYTHON"
      return 0
    fi
    echo "Error: configured Python ($LOCALVLLM_PYTHON) is unusable or incompatible with $backend." >&2
    echo "Use Python 3.11–3.13 with venv and ensurepip for Omni, or install Python 3.12 and retry." >&2
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
      if ! curl -fsSL https://astral.sh/uv/install.sh -o "$installer" ||
        ! UV_UNMANAGED_INSTALL="$AI_DIR/${LOCALVLLM_VENV_SUBDIR:-venv}/.localvllm-tools" sh "$installer" >&2; then
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

vllm_venv_stage_update() {
  local venv="$1"
  local stage="$venv.update.$$"

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

vllm_bootstrap_pip() {
  local venv="$1"
  local log_file="${2:-}"

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

vllm_pip_check() {
  local venv="$1"

  "$venv/bin/python" -m pip check >/dev/null 2>&1
}

vllm_pip_install() {
  local venv="$1"
  local version="$2"
  local pip_args="${3:-}"
  local log_file="${4:-}"
  local python="$venv/bin/python"
  local -a pip_extra=()
  local -a command=("$python" -m pip install --upgrade)

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

write_environment_manifest() {
  local venv="$1"
  local conf_dir="$2"
  local backend="$3"
  local active_id=""

  [ -d "$conf_dir" ] || return 0
  if [ -f "$conf_dir/$LOCALVLLM_ACTIVE_MODEL_FILE" ]; then
    active_id="$(<"$conf_dir/$LOCALVLLM_ACTIVE_MODEL_FILE")"
  fi

  {
    printf 'backend=%s\n' "$backend"
    printf 'created=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'python=%s\n' "$(python_version "$venv/bin/python" 2>/dev/null || true)"
    printf 'vllm=%s\n' "$(vllm_installed_version "$venv" 2>/dev/null || true)"
    if [ "$backend" = "omni" ]; then
      printf 'vllm_omni=%s\n' "$(vllm_omni_installed_version "$venv" 2>/dev/null || true)"
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

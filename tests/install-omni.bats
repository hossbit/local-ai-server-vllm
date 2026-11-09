#!/usr/bin/env bats
setup() {
  export LOCALVLLM_READY_WAIT=0
  REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export LOCALVLLM_DIR="$BATS_TEST_TMPDIR/ai"
  export LOCALVLLM_SYSTEMD_USER_DIR="$BATS_TEST_TMPDIR/systemd"
  export LOCALVLLM_USER_BIN_DIR="$BATS_TEST_TMPDIR/userbin"
  export VLLM_TARGET_DEVICE=cuda VLLM_OMNI_VERSION=0.32.0 VLLM_VERSION=latest
  export FAKE_PIP_LOG="$BATS_TEST_TMPDIR/pip.log" FAKE_BIN="$BATS_TEST_TMPDIR/fakebin"
  export PATH="$FAKE_BIN:$LOCALVLLM_USER_BIN_DIR:$PATH"
  mkdir -p "$FAKE_BIN" "$LOCALVLLM_DIR/bin" "$LOCALVLLM_DIR/conf" "$LOCALVLLM_DIR/lib" "$LOCALVLLM_USER_BIN_DIR"
  cp "$REPO_DIR/localvllm.conf" "$LOCALVLLM_DIR/conf/localvllm.conf"
  for f in localvllm start.sh stop.sh rebuild-config.sh update-localvllm.sh uninstall-localvllm.sh install-localvllm.sh; do cp "$REPO_DIR/$f" "$LOCALVLLM_DIR/bin/$f"; done
  cp -a "$REPO_DIR/lib/." "$LOCALVLLM_DIR/lib/"
  cat > "$FAKE_BIN/systemctl" <<'SH'
#!/usr/bin/env bash
case "${2:-}" in cat|is-active) exit 1 ;; *) exit 0 ;; esac
SH
  chmod +x "$FAKE_BIN/systemctl"
  cat > "$FAKE_BIN/pyvenv" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -c ]; then
  case "${2:-}" in *sys.version_info*) echo 3.12.8 ;; *) echo 0.32.0 ;; esac
  exit 0
fi
if [ "${1:-}" = -m ] && [ "${2:-}" = pip ]; then
  printf '%s\n' "$*" >> "$FAKE_PIP_LOG"
  case "$*" in *'vllm>=0.32,<0.33'*) [ "${FAIL_FAKE_PIP:-0}" = 0 ] || exit 42 ;; esac
  exit 0
fi
exec /usr/bin/python3 "$@"
SH
  cat > "$FAKE_BIN/python3.12" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -c ]; then echo 3.12.8; exit 0; fi
if [ "${1:-}" = -m ] && [ "${2:-}" = venv ]; then
  mkdir -p "$3/bin"
  cp "$FAKE_BIN/pyvenv" "$3/bin/python"
  printf '#!/usr/bin/env bash\necho vllm 0.32.0\n' > "$3/bin/vllm"
  chmod +x "$3/bin/"*
  exit 0
fi
exit 1
SH
  chmod +x "$FAKE_BIN/"*
}

@test "backend install omni selects Python 3.12 and matching packages" {
  run bash "$LOCALVLLM_DIR/bin/localvllm" backend install omni
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ -x "$LOCALVLLM_DIR/venv/omni/bin/python" ]
  grep -qF 'vllm>=0.32,<0.33' "$FAKE_PIP_LOG"
  grep -qF 'vllm-omni==0.32.0' "$FAKE_PIP_LOG"
  [ -f "$LOCALVLLM_SYSTEMD_USER_DIR/localvllm-omni.service" ]
}

@test "failure replacing a Python 3.14 Omni environment preserves the original" {
  mkdir -p "$LOCALVLLM_DIR/venv/omni/bin"
  printf '#!/usr/bin/env bash\necho 3.14.0\n' > "$LOCALVLLM_DIR/venv/omni/bin/python"
  chmod +x "$LOCALVLLM_DIR/venv/omni/bin/python"
  echo original > "$LOCALVLLM_DIR/venv/omni/marker"
  export FAIL_FAKE_PIP=1
  run bash "$LOCALVLLM_DIR/bin/localvllm" backend install omni
  [ "$status" -ne 0 ]
  [ "$(cat "$LOCALVLLM_DIR/venv/omni/marker")" = original ]
  [ -z "$(find "$LOCALVLLM_DIR/venv" -maxdepth 1 -name 'omni.update.*' -print -quit)" ]
}

@test "failure repairing an incomplete environment preserves existing files" {
  mkdir -p "$LOCALVLLM_DIR/venv/omni"
  echo original > "$LOCALVLLM_DIR/venv/omni/marker"
  export FAIL_FAKE_PIP=1
  run bash "$LOCALVLLM_DIR/bin/localvllm" backend install omni
  [ "$status" -ne 0 ]
  [ "$(cat "$LOCALVLLM_DIR/venv/omni/marker")" = original ]
  [ -z "$(find "$LOCALVLLM_DIR/venv" -maxdepth 1 -name 'omni.update.*' -print -quit)" ]
}

@test "update repairs an installed Omni environment on Python 3.14" {
  mkdir -p "$LOCALVLLM_DIR/venv/omni/bin" "$LOCALVLLM_DIR/conf/backends/omni"
  cat > "$LOCALVLLM_DIR/venv/omni/bin/python" <<'SH'
#!/usr/bin/env bash
case "${2:-}" in *sys.version_info*) echo 3.14.0 ;; *) echo 0.32.0 ;; esac
SH
  printf '#!/usr/bin/env bash\necho vllm 0.32.0\n' > "$LOCALVLLM_DIR/venv/omni/bin/vllm"
  chmod +x "$LOCALVLLM_DIR/venv/omni/bin/"*
  run bash "$LOCALVLLM_DIR/bin/localvllm" update --backend omni --vllm-only --no-start
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  run "$LOCALVLLM_DIR/venv/omni/bin/python" -c 'import sys; print(".".join(map(str, sys.version_info[:3])))'
  [ "$output" = 3.12.8 ]
  grep -qF 'vllm>=0.32,<0.33' "$FAKE_PIP_LOG"
}

@test "ARM64 installer path is accepted" {
  cat > "$FAKE_BIN/uname" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -m ]; then echo aarch64; else exec /usr/bin/uname "$@"; fi
SH
  chmod +x "$FAKE_BIN/uname"
  run bash "$LOCALVLLM_DIR/bin/localvllm" backend install omni
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ -x "$LOCALVLLM_DIR/venv/omni/bin/python" ]
}

@test "Red Hat family installer invokes dnf for system dependencies" {
  cat > "$FAKE_BIN/sudo" <<'SH'
#!/usr/bin/env bash
exec "$@"
SH
  cat > "$FAKE_BIN/dnf" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$FAKE_BIN/dnf.log"
SH
  cat > "$FAKE_BIN/bash-env" <<'SH'
command() {
  if [ "${1:-}" = -v ] && [ "${2:-}" = apt-get ]; then return 1; fi
  builtin command "$@"
}
SH
  chmod +x "$FAKE_BIN/sudo" "$FAKE_BIN/dnf"
  export BASH_ENV="$FAKE_BIN/bash-env"
  run bash "$LOCALVLLM_DIR/bin/install-localvllm.sh" --backend omni
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  grep -q 'install -y' "$FAKE_BIN/dnf.log"
}

@test "ROCm without a selected wheel stops before pip can install CUDA packages" {
  export VLLM_TARGET_DEVICE=rocm VLLM_PIP_ARGS=''
  run bash "$LOCALVLLM_DIR/bin/localvllm" backend install omni
  [ "$status" -ne 0 ]
  [[ "$output" == *'AMD ROCm was detected'* ]]
  [[ "$output" == *'amd-and-cpu-installation'* ]]
  [ ! -f "$FAKE_PIP_LOG" ]
}

@test "default latest Omni installation resolves the matching PyPI release" {
  cat > "$FAKE_BIN/curl" <<'SH'
#!/usr/bin/env bash
printf '{"info":{"version":"0.32.0"}}\n'
SH
  chmod +x "$FAKE_BIN/curl"
  export VLLM_OMNI_VERSION=latest
  run bash "$LOCALVLLM_DIR/bin/localvllm" backend install omni
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  grep -qF 'vllm>=0.32,<0.33' "$FAKE_PIP_LOG"
  grep -qF 'vllm-omni==0.32.0' "$FAKE_PIP_LOG"
}

@test "plain backend install uses compatible Python without changing the system" {
  run bash "$LOCALVLLM_DIR/bin/localvllm" backend install vllm
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [ -x "$LOCALVLLM_DIR/venv/vllm/bin/python" ]
  grep -q 'pip install --upgrade vllm' "$FAKE_PIP_LOG"
}

@test "failed Python selection restarts a previously running Omni service" {
  mkdir -p "$LOCALVLLM_DIR/venv/omni/bin"
  printf '#!/usr/bin/env bash\necho 3.14.0\n' > "$LOCALVLLM_DIR/venv/omni/bin/python"
  chmod +x "$LOCALVLLM_DIR/venv/omni/bin/python"
  cat > "$FAKE_BIN/systemctl" <<'SH'
#!/usr/bin/env bash
case "${2:-}" in
  cat) exit 0 ;;
  is-active) test -f "$FAKE_BIN/active" ;;
  stop) rm -f "$FAKE_BIN/active" ;;
  start) touch "$FAKE_BIN/active" ;;
esac
SH
  cat > "$FAKE_BIN/python3.14" <<'SH'
#!/usr/bin/env bash
echo 3.14.0
SH
  chmod +x "$FAKE_BIN/systemctl" "$FAKE_BIN/python3.14"
  touch "$FAKE_BIN/active"
  export LOCALVLLM_PYTHON=python3.14
  run bash "$LOCALVLLM_DIR/bin/localvllm" backend install omni
  [ "$status" -ne 0 ]
  [ -f "$FAKE_BIN/active" ]
}

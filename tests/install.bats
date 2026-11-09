#!/usr/bin/env bats

setup() {
  export LOCALVLLM_READY_WAIT=0
  REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  AI_DIR="$BATS_TEST_TMPDIR/ai"
  SYSTEMD_DIR="$BATS_TEST_TMPDIR/systemd"
  USER_BIN="$BATS_TEST_TMPDIR/userbin"
  export LOCALVLLM_DIR="$AI_DIR"
  export LOCALVLLM_DEFAULT_DIR="$AI_DIR"
  export LOCALVLLM_SYSTEMD_USER_DIR="$SYSTEMD_DIR"
  export LOCALVLLM_USER_BIN_DIR="$USER_BIN"
  export VLLM_TARGET_DEVICE=cuda
  export PATH="$USER_BIN:$PATH"

  mkdir -p "$AI_DIR/bin" "$AI_DIR/lib/cli" "$AI_DIR/conf/backends.d" \
    "$AI_DIR/venv/vllm/bin" "$AI_DIR/models/vllm" "$AI_DIR/logs" "$USER_BIN"

  # Simulate an installed copy: no localvllm.conf in bin, no source tree there.
  cp "$REPO_DIR/localvllm.conf" "$AI_DIR/conf/localvllm.conf"
  for script in localvllm start.sh stop.sh rebuild-config.sh update-localvllm.sh \
    uninstall-localvllm.sh install-localvllm.sh; do
    cp "$REPO_DIR/$script" "$AI_DIR/bin/$script"
    chmod +x "$AI_DIR/bin/$script"
  done
  cp -a "$REPO_DIR/lib/." "$AI_DIR/lib/"
  cat > "$USER_BIN/systemctl" <<'SH'
#!/usr/bin/env bash
case "${2:-}" in cat|is-active) exit 1 ;; *) exit 0 ;; esac
SH
  chmod +x "$USER_BIN/systemctl"

  cat > "$AI_DIR/venv/vllm/bin/python" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-c" ]; then
  case "${2:-}" in
    *'import vllm'*) echo "0.0-test" ;;
    *) echo "3.12.0" ;;
  esac
  exit 0
fi
if [ "${1:-}" = "-m" ] && [ "${2:-}" = "pip" ]; then
  echo "fake pip $*"
  exit 0
fi
exec /usr/bin/python3 "$@"
EOF
  cat > "$AI_DIR/venv/vllm/bin/pip" <<'EOF'
#!/usr/bin/env bash
echo "fake pip $*"
exit 0
EOF
  cat > "$AI_DIR/venv/vllm/bin/vllm" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then echo "vllm 0.0-test"; exit 0; fi
echo "fake vllm $*"
EOF
  chmod +x "$AI_DIR/venv/vllm/bin/"*
}

@test "installed installer can install a backend without a source checkout" {
  run bash "$AI_DIR/bin/install-localvllm.sh" --backend vllm --skip-system
  [ "$status" -eq 0 ] || {
    echo "$output" >&2
    false
  }
  [ -f "$AI_DIR/conf/backends/vllm/port" ]
  [ -f "$SYSTEMD_DIR/localvllm.service" ]
  [ -f "$USER_BIN/localvllm" ]
  [ "$(grep '^LOCALVLLM_DEFAULT_BACKEND=' "$AI_DIR/conf/localvllm.conf" | tail -1)" != "" ]
}

@test "installed CLI backend install works without a source checkout" {
  run bash "$AI_DIR/bin/localvllm" backend install vllm
  [ "$status" -eq 0 ] || {
    echo "$output" >&2
    false
  }
  [ -f "$AI_DIR/conf/backends/vllm/port" ]
  [ -f "$SYSTEMD_DIR/localvllm.service" ]
  [ -f "$USER_BIN/localvllm" ]
}

@test "installed installer does not truncate the installed configuration" {
  printf '\n# user marker\nLOCALVLLM_DEFAULT_BACKEND=vllm\n' >> "$AI_DIR/conf/localvllm.conf"
  run bash "$AI_DIR/bin/install-localvllm.sh" --backend vllm --skip-system
  [ "$status" -eq 0 ]
  grep -q '^# user marker$' "$AI_DIR/conf/localvllm.conf"
}

@test "runtime tuning survives repeated refreshes including empty values" {
  source "$REPO_DIR/lib/install.sh"
  CONF_ROOT="$BATS_TEST_TMPDIR/tuning"
  mkdir -p "$CONF_ROOT"
  printf "VLLM_EXTRA_ARGS='--foo hello world'\nVLLM_CHAT_TEMPLATE=''\n" > "$CONF_ROOT/localvllm.conf"
  for iteration in 1 2 3; do
    cp "$CONF_ROOT/localvllm.conf" "$BATS_TEST_TMPDIR/previous"
    : > "$CONF_ROOT/localvllm.conf"
    append_runtime_tuning "$BATS_TEST_TMPDIR/previous" test
  done
  source "$CONF_ROOT/localvllm.conf"
  [ "$VLLM_EXTRA_ARGS" = '--foo hello world' ]
  [ "$VLLM_CHAT_TEMPLATE" = '' ]
}

@test "systemd unit tracks vLLM as a simple restartable service" {
  . "$REPO_DIR/lib/common.sh"
  . "$REPO_DIR/lib/install.sh"
  local unit="$BATS_TEST_TMPDIR/localvllm.service"
  write_systemd_user_service "$unit" "/tmp/localvllm-bin" vllm
  grep -qx 'Type=simple' "$unit"
  grep -qx 'Restart=on-failure' "$unit"
  ! grep -q 'RemainAfterExit' "$unit"
  ! grep -q '^ExecStop=' "$unit"
}

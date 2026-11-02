#!/usr/bin/env bats

setup() {
  REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  AI_DIR="$BATS_TEST_TMPDIR/ai"
  export LOCALVLLM_DIR="$AI_DIR"
  export LOCALVLLM_DEFAULT_DIR="$AI_DIR"
  export LOCALVLLM_SYSTEMD_USER_DIR="$BATS_TEST_TMPDIR/systemd"
  export LOCALVLLM_USER_BIN_DIR="$BATS_TEST_TMPDIR/userbin"
  export PATH="$LOCALVLLM_USER_BIN_DIR:$PATH"

  mkdir -p "$AI_DIR/bin" "$AI_DIR/lib/cli" "$AI_DIR/conf/backends/vllm" \
    "$AI_DIR/venv/vllm/bin" "$AI_DIR/models/vllm" "$AI_DIR/logs" \
    "$LOCALVLLM_SYSTEMD_USER_DIR" "$LOCALVLLM_USER_BIN_DIR"

  cp "$REPO_DIR/localvllm.conf" "$AI_DIR/conf/localvllm.conf"
  for script in localvllm start.sh stop.sh rebuild-config.sh update-localvllm.sh \
    uninstall-localvllm.sh install-localvllm.sh; do
    cp "$REPO_DIR/$script" "$AI_DIR/bin/$script"
    chmod +x "$AI_DIR/bin/$script"
  done
  cp -a "$REPO_DIR/lib/." "$AI_DIR/lib/"
  printf '8000\n' > "$AI_DIR/conf/backends/vllm/port"

  cat > "$AI_DIR/venv/vllm/bin/python" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-c" ]; then
  case "${2:-}" in
    *'import vllm'*) echo "0.0-old" ;;
    *) echo "3.12.0" ;;
  esac
  exit 0
fi
if [ "${1:-}" = "-m" ] && [ "${2:-}" = "pip" ]; then
  exit 0
fi
exec /usr/bin/python3 "$@"
EOF
  cat > "$AI_DIR/venv/vllm/bin/pip" <<'EOF'
#!/usr/bin/env bash
echo "simulated pip failure" >&2
exit 42
EOF
  cat > "$AI_DIR/venv/vllm/bin/vllm" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then echo "vllm 0.0-old"; exit 0; fi
exit 0
EOF
  chmod +x "$AI_DIR/venv/vllm/bin/"*
}

@test "a failed package upgrade leaves the old venv intact" {
  run env VLLM_VERSION=0.0-new \
    bash "$AI_DIR/bin/update-localvllm.sh" --vllm-only --no-start
  [ "$status" -ne 0 ]
  [ -x "$AI_DIR/venv/vllm/bin/vllm" ]
  [[ "$output" == *"package update failed"* || "$output" == *"installation failed"* || "$output" == *"upgrade failed"* ]]
  [ -z "$(find "$AI_DIR/venv" -maxdepth 1 -name 'vllm.update.*' -print -quit)" ]
}

#!/usr/bin/env bats

setup() {
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

@test "installed installer does not truncate the installed configuration" {
  printf '\n# user marker\nLOCALVLLM_DEFAULT_BACKEND=vllm\n' >> "$AI_DIR/conf/localvllm.conf"
  run bash "$AI_DIR/bin/install-localvllm.sh" --backend vllm --skip-system
  [ "$status" -eq 0 ]
  grep -q '^# user marker$' "$AI_DIR/conf/localvllm.conf"
}

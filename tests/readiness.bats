#!/usr/bin/env bats

setup() {
  REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  AI_DIR="$BATS_TEST_TMPDIR/ai"
  export LOCALVLLM_DIR="$AI_DIR"
  export LOCALVLLM_DEFAULT_DIR="$AI_DIR"

  # shellcheck source=../localvllm.conf
  . "$REPO_DIR/localvllm.conf"
  # shellcheck source=../lib/common.sh
  . "$REPO_DIR/lib/common.sh"

  localvllm_capture_global_runtime
  localvllm_use_backend vllm
  mkdir -p "$CONF_DIR" "$BATS_TEST_TMPDIR/bin"

  export MOCK_STATE="$BATS_TEST_TMPDIR/unit-active"
  cat > "$BATS_TEST_TMPDIR/bin/systemctl" <<'SH'
#!/usr/bin/env bash
case "${2:-}" in
  cat) exit 0 ;;
  is-active) test -f "$MOCK_STATE" ;;
  start|restart) [ -n "${MOCK_CRASH:-}" ] || touch "$MOCK_STATE" ;;
  stop) rm -f "$MOCK_STATE" ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/systemctl"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export LOCALVLLM_READY_WAIT=1
  API_PID=""
}

teardown() {
  [ -z "$API_PID" ] || kill "$API_PID" 2>/dev/null || true
}

start_fake_api() {
  local port

  port="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
  printf '%s\n' "$port" > "$PORT_FILE"
  python3 - "$port" <<'PY' &
import http.server
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200 if self.path in ("/health", "/v1/models") else 404)
        self.end_headers()

    def log_message(self, *args):
        pass


http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
PY
  API_PID=$!
  for _ in $(seq 50); do
    curl -fsS "http://127.0.0.1:$port/health" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

@test "systemd start waits until the API answers" {
  start_fake_api
  LOCALVLLM_HEALTH_CHECK_TIMEOUT=30 run localvllm_start_service
  [ "$status" -eq 0 ]
  [ -f "$MOCK_STATE" ]
}

@test "a started unit that never answers fails after the readiness timeout" {
  printf '1\n' > "$PORT_FILE"
  LOCALVLLM_HEALTH_CHECK_TIMEOUT=2 run localvllm_start_service
  [ "$status" -ne 0 ]
  [[ "$output" == *"did not become ready"* ]]
}

@test "a unit that stops before answering is reported without waiting out the timeout" {
  export MOCK_CRASH=1
  printf '1\n' > "$PORT_FILE"
  LOCALVLLM_HEALTH_CHECK_TIMEOUT=60 run localvllm_start_service
  [ "$status" -ne 0 ]
  [[ "$output" == *"did not become ready"* ]]
}

@test "LOCALVLLM_READY_WAIT=0 returns once systemd has started the unit" {
  printf '1\n' > "$PORT_FILE"
  LOCALVLLM_READY_WAIT=0 run localvllm_start_service
  [ "$status" -eq 0 ]
}

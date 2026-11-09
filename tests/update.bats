#!/usr/bin/env bats

setup() {
  export LOCALVLLM_READY_WAIT=0
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
  cat > "$LOCALVLLM_USER_BIN_DIR/systemctl" <<'SH'
#!/usr/bin/env bash
case "${2:-}" in cat|is-active) exit 1 ;; *) exit 0 ;; esac
SH
  chmod +x "$LOCALVLLM_USER_BIN_DIR/systemctl"
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
  if [[ " $* " == *" vllm==0.0-new "* ]]; then
    echo "simulated pip failure" >&2
    exit 42
  fi
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

@test "a failed helper refresh restores installed helpers and reports failure" {
  mkdir -p "$BATS_TEST_TMPDIR/mock-bin"
  cat > "$BATS_TEST_TMPDIR/mock-bin/install" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'/rebuild-config.sh '*) echo 'simulated helper copy failure' >&2; exit 73 ;;
esac
exec /usr/bin/install "$@"
SH
  chmod +x "$BATS_TEST_TMPDIR/mock-bin/install"
  printf '\n# original helper marker\n' >> "$AI_DIR/bin/stop.sh"
  run env PATH="$BATS_TEST_TMPDIR/mock-bin:$PATH" LOCALVLLM_LOCAL_SOURCE_DIR="$REPO_DIR" \
    bash "$AI_DIR/bin/update-localvllm.sh" --scripts-only --no-start
  [ "$status" -ne 0 ]
  [[ "$output" == *"helper script refresh failed"* ]]
  grep -q '# original helper marker' "$AI_DIR/bin/stop.sh"
  [ -x "$AI_DIR/bin/localvllm" ]
}

@test "package failure preserves installed manager files and configuration" {
  printf '\n# original manager\n' >> "$AI_DIR/bin/stop.sh"
  cp "$AI_DIR/bin/stop.sh" "$BATS_TEST_TMPDIR/stop.before"
  cp "$AI_DIR/conf/localvllm.conf" "$BATS_TEST_TMPDIR/conf.before"
  run env VLLM_VERSION=0.0-new LOCALVLLM_LOCAL_SOURCE_DIR="$REPO_DIR" \
    bash "$AI_DIR/bin/update-localvllm.sh" --no-start
  [ "$status" -ne 0 ]
  cmp "$AI_DIR/bin/stop.sh" "$BATS_TEST_TMPDIR/stop.before"
  cmp "$AI_DIR/conf/localvllm.conf" "$BATS_TEST_TMPDIR/conf.before"
}

@test "failed restart restores environment reports and previous helpers" {
  mkdir -p "$BATS_TEST_TMPDIR/mock-bin"
  export MOCK_STATE="$BATS_TEST_TMPDIR/service"
  touch "$MOCK_STATE"
  cat > "$BATS_TEST_TMPDIR/mock-bin/systemctl" <<'SH'
#!/usr/bin/env bash
case "${2:-}" in
  cat) exit 0 ;;
  is-active) test -f "$MOCK_STATE" ;;
  stop) rm -f "$MOCK_STATE" ;;
  start)
    if [ ! -f "$MOCK_STATE.attempt" ]; then touch "$MOCK_STATE.attempt"; exit 1; fi
    touch "$MOCK_STATE" ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$BATS_TEST_TMPDIR/mock-bin/systemctl"
  printf 'original report\n' > "$AI_DIR/conf/backends/vllm/environment.txt"
  printf 'original lock\n' > "$AI_DIR/conf/backends/vllm/environment.lock"
  run env PATH="$BATS_TEST_TMPDIR/mock-bin:$PATH" VLLM_VERSION=0.0-good \
    bash "$AI_DIR/bin/update-localvllm.sh" --vllm-only
  [ "$status" -ne 0 ]
  [ "$(cat "$AI_DIR/conf/backends/vllm/environment.txt")" = 'original report' ]
  [ "$(cat "$AI_DIR/conf/backends/vllm/environment.lock")" = 'original lock' ]
  [ -f "$MOCK_STATE" ]
  [ -z "$(find "$AI_DIR/venv" -maxdepth 1 -name 'vllm.previous.*' -print -quit)" ]
}

@test "archive URLs support v-prefixed branches and explicit tag refs" {
  eval "$(sed -n '/^localvllm_archive_url() {/,/^}/p' "$REPO_DIR/update-localvllm.sh")"
  eval "$(sed -n '/^archive_url() {/,/^}/p' "$REPO_DIR/install.sh")"
  LOCALVLLM_TARBALL_BASE=https://example.invalid/archive
  for LOCALVLLM_REF in vllm-fixes v1.2.3 refs/tags/release refs/heads/develop; do
    [ "$(archive_url)" = "$LOCALVLLM_TARBALL_BASE/$LOCALVLLM_REF.tar.gz" ]
    [ "$(localvllm_archive_url)" = "$LOCALVLLM_TARBALL_BASE/$LOCALVLLM_REF.tar.gz" ]
  done
}

@test "late helper commit failure rolls back manager and package transaction" {
  mkdir -p "$BATS_TEST_TMPDIR/mock-bin"
  cat > "$BATS_TEST_TMPDIR/mock-bin/install" <<'SH'
#!/usr/bin/env bash
case "$*" in *'/localvllm.staged '*) exit 73 ;; esac
exec /usr/bin/install "$@"
SH
  chmod +x "$BATS_TEST_TMPDIR/mock-bin/install"
  printf '\n# original manager\n' >> "$AI_DIR/bin/stop.sh"
  cp "$AI_DIR/bin/stop.sh" "$BATS_TEST_TMPDIR/stop.before"
  cp "$AI_DIR/conf/localvllm.conf" "$BATS_TEST_TMPDIR/conf.before"
  run env PATH="$BATS_TEST_TMPDIR/mock-bin:$PATH" VLLM_VERSION=0.0-good \
    LOCALVLLM_LOCAL_SOURCE_DIR="$REPO_DIR" bash "$AI_DIR/bin/update-localvllm.sh" --no-start
  [ "$status" -ne 0 ]
  cmp "$AI_DIR/bin/stop.sh" "$BATS_TEST_TMPDIR/stop.before"
  cmp "$AI_DIR/conf/localvllm.conf" "$BATS_TEST_TMPDIR/conf.before"
  [ ! -f "$AI_DIR/conf/backends/vllm/environment.txt" ]
  [ -z "$(find "$AI_DIR/venv" -maxdepth 1 -name 'vllm.previous.*' -print -quit)" ]
}

prepare_router_assets() {
  mkdir -p "$BATS_TEST_TMPDIR/router-assets" "$BATS_TEST_TMPDIR/mock-bin"
  printf '#!/usr/bin/env bash\necho "version: v268 (old)"\n' > "$AI_DIR/bin/llama-swap"
  chmod +x "$AI_DIR/bin/llama-swap"
  cat > "$BATS_TEST_TMPDIR/router-assets/llama-swap" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in -version) echo 'version: v269 (new)' ;; *) exit 0 ;; esac
SH
  chmod +x "$BATS_TEST_TMPDIR/router-assets/llama-swap"
  tar -czf "$BATS_TEST_TMPDIR/router-assets/llama-swap_269_linux_amd64.tar.gz" -C "$BATS_TEST_TMPDIR/router-assets" llama-swap
  (cd "$BATS_TEST_TMPDIR/router-assets" && sha256sum llama-swap_269_linux_amd64.tar.gz > checksums)
  export ROUTER_ASSETS="$BATS_TEST_TMPDIR/router-assets"
  cat > "$BATS_TEST_TMPDIR/mock-bin/curl" <<'SH'
#!/usr/bin/env bash
output=""; url=""
while [ "$#" -gt 0 ]; do
  case "$1" in -o) output="$2"; shift 2 ;; https://*) url="$1"; shift ;; *) shift ;; esac
done
case "$url" in
  *checksums.txt) cp "$ROUTER_ASSETS/checksums" "$output" ;;
  *.tar.gz) cp "$ROUTER_ASSETS/llama-swap_269_linux_amd64.tar.gz" "$output" ;;
  *) exit 91 ;;
esac
SH
  chmod +x "$BATS_TEST_TMPDIR/mock-bin/curl"
  sha256sum "$REPO_DIR/localvllm.conf" | awk '{print $1}' > "$AI_DIR/conf/.localvllm-config.sha256"
}

@test "default update stages verifies and promotes an installed managed router" {
  prepare_router_assets
  run env PATH="$BATS_TEST_TMPDIR/mock-bin:$PATH" VLLM_VERSION=3.12.0 LOCALVLLM_LLAMA_SWAP_VERSION=v269 \
    LOCALVLLM_LOCAL_SOURCE_DIR="$REPO_DIR" bash "$AI_DIR/bin/update-localvllm.sh"
  [ "$status" = 0 ] || { echo "$output"; return 1; }
  [ "$("$AI_DIR/bin/llama-swap" -version)" = 'version: v269 (new)' ]
  [ ! -e "$AI_DIR/bin/llama-swap.next" ]
}
@test "failed router checksum leaves all installed files unchanged" {
  prepare_router_assets
  echo 'bad checksum' > "$ROUTER_ASSETS/checksums"
  cp "$AI_DIR/bin/llama-swap" "$BATS_TEST_TMPDIR/router.before"
  run env PATH="$BATS_TEST_TMPDIR/mock-bin:$PATH" VLLM_VERSION=3.12.0 LOCALVLLM_LLAMA_SWAP_VERSION=v269 \
    LOCALVLLM_LOCAL_SOURCE_DIR="$REPO_DIR" bash "$AI_DIR/bin/update-localvllm.sh"
  [ "$status" != 0 ]
  cmp "$AI_DIR/bin/llama-swap" "$BATS_TEST_TMPDIR/router.before"
  [[ "$output" == *'checksum verification failed'* ]]
}
@test "late transaction failure restores the previous router executable" {
  prepare_router_assets
  cat > "$BATS_TEST_TMPDIR/mock-bin/install" <<'SH'
#!/usr/bin/env bash
case "$*" in *'/localvllm.staged '*) exit 73 ;; esac
exec /usr/bin/install "$@"
SH
  chmod +x "$BATS_TEST_TMPDIR/mock-bin/install"
  echo '# changed' >> "$AI_DIR/bin/stop.sh"
  run env PATH="$BATS_TEST_TMPDIR/mock-bin:$PATH" VLLM_VERSION=3.12.0 LOCALVLLM_LLAMA_SWAP_VERSION=v269 \
    LOCALVLLM_LOCAL_SOURCE_DIR="$REPO_DIR" bash "$AI_DIR/bin/update-localvllm.sh"
  [ "$status" != 0 ]
  [ "$("$AI_DIR/bin/llama-swap" -version)" = 'version: v268 (old)' ]
}
@test "direct-only installs do not acquire an optional router during update" {
  run env VLLM_VERSION=3.12.0 LOCALVLLM_LOCAL_SOURCE_DIR="$REPO_DIR" \
    bash "$AI_DIR/bin/update-localvllm.sh"
  [ "$status" = 0 ] || { echo "$output"; return 1; }
  [ ! -e "$AI_DIR/bin/llama-swap" ]
}
@test "scripts-only and engine-only updates leave router versions alone" {
  prepare_router_assets
  local option
  for option in --scripts-only --vllm-only; do
    run env PATH="$BATS_TEST_TMPDIR/mock-bin:$PATH" VLLM_VERSION=3.12.0 LOCALVLLM_LLAMA_SWAP_VERSION=v269 \
      LOCALVLLM_LOCAL_SOURCE_DIR="$REPO_DIR" bash "$AI_DIR/bin/update-localvllm.sh" "$option"
    [ "$status" = 0 ] || { echo "$output"; return 1; }
    [ "$("$AI_DIR/bin/llama-swap" -version)" = 'version: v268 (old)' ]
  done
}

@test "shared router update restarts an unselected Omni router but not a direct vllm service" {
  prepare_router_assets
  mkdir -p "$AI_DIR/venv/omni/bin" "$AI_DIR/models/omni/model-a" "$AI_DIR/conf/backends/omni"
  cp "$AI_DIR/venv/vllm/bin/"* "$AI_DIR/venv/omni/bin/"
  echo '{}' > "$AI_DIR/models/omni/model-a/config.json"
  echo swap > "$AI_DIR/conf/backends/omni/serving-mode"
  echo model-a > "$AI_DIR/conf/backends/omni/active-model"
  export ROUTER_SERVICE_LOG="$BATS_TEST_TMPDIR/router-services"
  cat > "$BATS_TEST_TMPDIR/mock-bin/systemctl" <<'SH'
#!/usr/bin/env bash
case "${3:-}" in localvllm-omni*) name=omni ;; *) name=vllm ;; esac
case "${2:-}" in
 cat|is-active) exit 0 ;;
 stop|start) printf '%s %s\n' "$2" "$name" >> "$ROUTER_SERVICE_LOG" ;;
 *) exit 0 ;;
esac
SH
  chmod +x "$BATS_TEST_TMPDIR/mock-bin/systemctl"
  run env PATH="$BATS_TEST_TMPDIR/mock-bin:$PATH" VLLM_VERSION=3.12.0 LOCALVLLM_LLAMA_SWAP_VERSION=v269 \
    LOCALVLLM_LOCAL_SOURCE_DIR="$REPO_DIR" bash "$AI_DIR/bin/update-localvllm.sh" --backend vllm
  [ "$status" = 0 ] || { echo "$output"; return 1; }
  [ "$(cat "$ROUTER_SERVICE_LOG")" = $'stop omni\nstart omni' ]
  [ "$(cat "$AI_DIR/conf/backends/omni/serving-mode")" = swap ]
  [ "$("$AI_DIR/bin/llama-swap" -version)" = 'version: v269 (new)' ]
}
@test "external llama-swap executables are reported and never overwritten" {
  prepare_router_assets
  printf '#!/usr/bin/env bash\necho "version: v267 (external)"\n' > "$BATS_TEST_TMPDIR/external-router"
  chmod +x "$BATS_TEST_TMPDIR/external-router"
  run env PATH="$BATS_TEST_TMPDIR/mock-bin:$PATH" VLLM_VERSION=3.12.0 LOCALVLLM_LLAMA_SWAP_VERSION=v269 \
    LOCALVLLM_LLAMA_SWAP_BIN="$BATS_TEST_TMPDIR/external-router" LOCALVLLM_LOCAL_SOURCE_DIR="$REPO_DIR" \
    bash "$AI_DIR/bin/update-localvllm.sh"
  [ "$status" = 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *'External llama-swap is managed separately'* ]]
  [ "$("$BATS_TEST_TMPDIR/external-router" -version)" = 'version: v267 (external)' ]
  [ "$("$AI_DIR/bin/llama-swap" -version)" = 'version: v268 (old)' ]
}
@test "version reports the actual installed optional router" {
  prepare_router_assets
  run bash "$AI_DIR/bin/localvllm" version
  [ "$status" = 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *'llama-swap: v268'* ]]
  [[ "$output" == *'Serving mode: direct'* ]]
}
@test "failed launcher regeneration rolls back even when the backend was stopped" {
  mkdir -p "$AI_DIR/models/vllm/model-a" "$BATS_TEST_TMPDIR/source/lib"
  echo '{}' > "$AI_DIR/models/vllm/model-a/config.json"
  echo model-a > "$AI_DIR/conf/backends/vllm/active-model"
  for f in localvllm localvllm.conf start.sh stop.sh rebuild-config.sh update-localvllm.sh uninstall-localvllm.sh install-localvllm.sh; do
    cp "$REPO_DIR/$f" "$BATS_TEST_TMPDIR/source/$f"
  done
  cp -a "$REPO_DIR/lib/." "$BATS_TEST_TMPDIR/source/lib/"
  printf '#!/usr/bin/env bash\nexit 42\n' > "$BATS_TEST_TMPDIR/source/rebuild-config.sh"
  chmod +x "$BATS_TEST_TMPDIR/source/rebuild-config.sh"
  cp "$AI_DIR/bin/rebuild-config.sh" "$BATS_TEST_TMPDIR/rebuild.before"
  run env LOCALVLLM_LOCAL_SOURCE_DIR="$BATS_TEST_TMPDIR/source" \
    bash "$AI_DIR/bin/update-localvllm.sh" --scripts-only --no-start
  [ "$status" != 0 ]
  [[ "$output" == *'could not rebuild the vllm launcher'* ]]
  cmp "$AI_DIR/bin/rebuild-config.sh" "$BATS_TEST_TMPDIR/rebuild.before"
}

@test "no-start is honored on rollback as well as successful updates" {
  mkdir -p "$BATS_TEST_TMPDIR/mock-bin"
  export UPDATE_ACTIONS="$BATS_TEST_TMPDIR/update-actions"
  cat > "$BATS_TEST_TMPDIR/mock-bin/systemctl" <<'SH'
#!/usr/bin/env bash
case "${2:-}" in
 cat|is-active) exit 0 ;;
 stop|start) echo "$2" >> "$UPDATE_ACTIONS" ;;
 *) exit 0 ;;
esac
SH
  cat > "$BATS_TEST_TMPDIR/mock-bin/install" <<'SH'
#!/usr/bin/env bash
case "$*" in *'/rebuild-config.sh '*) exit 73 ;; esac
exec /usr/bin/install "$@"
SH
  chmod +x "$BATS_TEST_TMPDIR/mock-bin/"*
  echo '# different helper' >> "$AI_DIR/bin/stop.sh"
  run env PATH="$BATS_TEST_TMPDIR/mock-bin:$PATH" LOCALVLLM_LOCAL_SOURCE_DIR="$REPO_DIR" \
    bash "$AI_DIR/bin/update-localvllm.sh" --scripts-only --no-start
  [ "$status" != 0 ]
  [ -f "$UPDATE_ACTIONS" ]
  ! grep -q '^start$' "$UPDATE_ACTIONS"
}

@test "version still reports components when GPU queries or Python are broken" {
  prepare_router_assets
  printf '#!/usr/bin/env bash\nexit 1\n' > "$BATS_TEST_TMPDIR/mock-bin/nvidia-smi"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$AI_DIR/venv/vllm/bin/python"
  chmod +x "$BATS_TEST_TMPDIR/mock-bin/nvidia-smi"
  run env PATH="$BATS_TEST_TMPDIR/mock-bin:$PATH" bash "$AI_DIR/bin/localvllm" version
  [ "$status" = 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *'llama-swap: v268'* ]]
  [[ "$output" == *'NVIDIA device query unavailable'* ]]
  [[ "$output" == *'Python: unknown'* ]]
}

@test "update defaults to selected backend while all upgrades every installed backend" {
  mkdir -p "$AI_DIR/venv/omni/bin"
  cp "$AI_DIR/venv/vllm/bin/"* "$AI_DIR/venv/omni/bin/"
  export BACKEND_UPDATE_LOG="$BATS_TEST_TMPDIR/backend-updates"
  cat > "$AI_DIR/venv/omni/bin/python" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -c ]; then echo 3.12.0; exit 0; fi
if [ "${1:-}" = -m ] && [ "${2:-}" = pip ]; then
  echo "$*" >> "$BACKEND_UPDATE_LOG"
  exit 0
fi
exec /usr/bin/python3 "$@"
SH
  chmod +x "$AI_DIR/venv/omni/bin/python"
  sha256sum "$REPO_DIR/localvllm.conf" | awk '{print $1}' > "$AI_DIR/conf/.localvllm-config.sha256"
  run env VLLM_VERSION=3.12.0 VLLM_OMNI_VERSION=0.32.0 LOCALVLLM_LOCAL_SOURCE_DIR="$REPO_DIR" \
    bash "$AI_DIR/bin/localvllm" update
  [ "$status" = 0 ] || { echo "$output"; return 1; }
  [ ! -e "$BACKEND_UPDATE_LOG" ]
  run env VLLM_VERSION=3.12.0 VLLM_OMNI_VERSION=0.32.0 LOCALVLLM_LOCAL_SOURCE_DIR="$REPO_DIR" \
    bash "$AI_DIR/bin/localvllm" update --all
  [ "$status" = 0 ] || { echo "$output"; return 1; }
  [ -f "$BACKEND_UPDATE_LOG" ]
  grep -q 'vllm-omni==0.32.0' "$BACKEND_UPDATE_LOG"
}
@test "update forwards the explicitly selected Omni backend and all overrides selection" {
  local SCRIPT_DIR="$REPO_DIR" BIN_DIR="$BATS_TEST_TMPDIR/commands"
  mkdir -p "$BIN_DIR"
  cat > "$BIN_DIR/update-localvllm.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*"
SH
  chmod +x "$BIN_DIR/update-localvllm.sh"
  . "$REPO_DIR/lib/cli/lifecycle.sh"
  LOCALVLLM_BACKEND=omni
  run update_cmd --no-start
  [ "$status" = 0 ]
  [ "$output" = '--backend omni --no-start' ]
  run update_cmd --all
  [ "$status" = 0 ]
  [ "$output" = '--all' ]
}

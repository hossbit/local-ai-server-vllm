#!/usr/bin/env bats

setup() {
  REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  AI_DIR="$BATS_TEST_TMPDIR/ai"
  export LOCALVLLM_DIR="$AI_DIR"
  export LOCALVLLM_DEFAULT_DIR="$AI_DIR"
  mkdir -p "$AI_DIR"
}

# A PATH that contains only the named tools, so no system Python or uv is found.
restricted_bin() {
  local dir="$BATS_TEST_TMPDIR/restricted-bin" tool
  mkdir -p "$dir"
  for tool in bash env "$@"; do
    ln -sf "$(command -v "$tool")" "$dir/$tool"
  done
  printf '%s\n' "$dir"
}

@test "the uv installer is refused when its checksum does not match" {
  local bin
  bin="$(restricted_bin awk sha256sum sh mktemp mkdir rm cat dirname basename)"
  cat > "$bin/curl" <<'SH'
#!/usr/bin/env bash
out=""
while [ "$#" -gt 0 ]; do
  case "$1" in -o) out="$2"; shift ;; esac
  shift
done
printf 'touch "%s/executed"\n' "$BATS_TEST_TMPDIR" > "$out"
SH
  chmod +x "$bin/curl"
  run env PATH="$bin" AI_DIR="$AI_DIR" LOCALVLLM_PYTHON=python3 bash -c '
    set -u
    . "'"$REPO_DIR"'/localvllm.conf"
    . "'"$REPO_DIR"'/lib/common.sh"
    . "'"$REPO_DIR"'/lib/install.sh"
    localvllm_find_compatible_python omni
  '
  [ "$status" -ne 0 ]
  [[ "$output" == *"checksum verification failed"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/executed" ]
}

@test "a staged venv update refuses to start when free space is short" {
  local venv="$AI_DIR/venv/vllm" bin
  mkdir -p "$venv/bin"
  head -c 2000000 /dev/zero > "$venv/bin/big-package"
  bin="$(restricted_bin awk du sed cat dirname basename)"
  cat > "$bin/df" <<'SH'
#!/usr/bin/env bash
printf 'Filesystem 1B-blocks Used Available Use%% Mounted on\n'
printf 'fake 10000000 9000000 1000 90%% /\n'
SH
  chmod +x "$bin/df"
  run env PATH="$bin" bash -c '
    . "'"$REPO_DIR"'/localvllm.conf"
    . "'"$REPO_DIR"'/lib/common.sh"
    . "'"$REPO_DIR"'/lib/install.sh"
    vllm_venv_stage_update "'"$venv"'"
  '
  [ "$status" -ne 0 ]
  [[ "$output" == *"not enough free disk space"* ]]
  [ -z "$(find "$AI_DIR/venv" -maxdepth 1 -name 'vllm.update.*' -print -quit)" ]
}

@test "the API key is passed to curl through a config file, not its argument list" {
  local secret="sk-localvllm-$(printf 'a%.0s' {1..64})" bin
  mkdir -p "$AI_DIR/conf/backends/vllm"
  printf 'version\t1\naaaaaaaaaaaa\tlaptop\t2026-01-01T00:00:00Z\tactive\t%s\n' "$secret" \
    > "$AI_DIR/conf/backends/vllm/api-keys.tsv"
  bin="$(restricted_bin awk sed cat sha256sum head od tr dirname basename)"
  cat > "$bin/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/argv.txt"
cfg=""
for arg in "$@"; do
  case "$arg" in --config) cfg="next" ;; *) [ "$cfg" = next ] && { cat "$arg" > "$BATS_TEST_TMPDIR/config.txt"; cfg=""; } ;; esac
done
exit 0
SH
  chmod +x "$bin/curl"
  run env PATH="$bin" BATS_TEST_TMPDIR="$BATS_TEST_TMPDIR" bash -c '
    . "'"$REPO_DIR"'/localvllm.conf"
    . "'"$REPO_DIR"'/lib/common.sh"
    CONF_DIR="'"$AI_DIR"'/conf/backends/vllm"
    api_auth_curl_args
    curl "${AUTH_CURL_ARGS[@]}" http://127.0.0.1:1/health
  '
  [ "$status" -eq 0 ]
  ! grep -qF "$secret" "$BATS_TEST_TMPDIR/argv.txt"
  grep -qF "Authorization: Bearer $secret" "$BATS_TEST_TMPDIR/config.txt"
}

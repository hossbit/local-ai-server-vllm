#!/usr/bin/env bats
setup() {
  REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SCRIPT_DIR="$REPO_DIR"; SCRIPT_PATH="$REPO_DIR/localvllm"
  AI_DIR="$BATS_TEST_TMPDIR/ai with spaces"
  export LOCALVLLM_DIR="$AI_DIR" LOCALVLLM_DEFAULT_DIR="$AI_DIR"
  . "$REPO_DIR/localvllm.conf"
  . "$REPO_DIR/lib/common.sh"
  . "$REPO_DIR/lib/install.sh"
  . "$REPO_DIR/lib/cli/core.sh"
  . "$REPO_DIR/lib/cli/service.sh"
  . "$REPO_DIR/lib/cli/models.sh"
  . "$REPO_DIR/lib/cli/lifecycle.sh"
  . "$REPO_DIR/lib/router.sh"
  . "$REPO_DIR/lib/cli/menu.sh"
  BIN_DIR="$AI_DIR/bin"; CONF_ROOT="$AI_DIR/conf"
  mkdir -p "$BIN_DIR"
  # The generated worker is tested as a real shell script, with only vLLM mocked.
  for backend in vllm omni; do
    mkdir -p "$AI_DIR/venv/$backend/bin" "$AI_DIR/models/$backend/model-a" "$AI_DIR/models/$backend/model-b" "$AI_DIR/conf/backends/$backend/models.d"
    echo '{}' > "$AI_DIR/models/$backend/model-a/config.json"
    echo '{}' > "$AI_DIR/models/$backend/model-b/config.json"
    cat > "$AI_DIR/venv/$backend/bin/vllm" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@"
STUB
    printf '#!/usr/bin/env bash\nexit 0\n' > "$AI_DIR/venv/$backend/bin/python"
    chmod +x "$AI_DIR/venv/$backend/bin/"*
    echo model-a > "$AI_DIR/conf/backends/$backend/active-model"
  done
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN_DIR/llama-swap"
  chmod +x "$BIN_DIR/llama-swap"
  localvllm_capture_global_runtime
  localvllm_use_backend vllm
  service_is_active() { return 1; }
  has_user_service() { return 1; }
  apply_config_change() { :; }
}
@test "direct mode is the default and does not require llama-swap" {
  rm "$BIN_DIR/llama-swap"
  [ "$(localvllm_serving_mode)" = direct ]
  run bash "$REPO_DIR/rebuild-config.sh" --backend vllm
  [ "$status" = 0 ]
  ! grep -q llama-swap "$SERVE_SH"
}
@test "swap generation is isolated for vllm and Omni and keeps active selection" {
  local backend config worker
  for backend in vllm omni; do
    localvllm_use_backend "$backend"
    echo swap > "$CONF_DIR/serving-mode"
    run bash "$REPO_DIR/rebuild-config.sh" --backend "$backend"
    [ "$status" = 0 ] || { echo "$output"; return 1; }
    [ "$(cat "$ACTIVE_MODEL_FILE")" = model-a ]
    config="$(find "$CONF_DIR/router" -name '*.json' | head -1)"
    [ "$(jq '.models|length' "$config")" = 2 ]
    worker="$(find "$CONF_DIR/router" -name '*.sh' | head -1)"
    run bash "$worker" 12345
    [ "$status" = 0 ]
    [[ "$output" == *$'--host\n127.0.0.1\n--port\n12345\n'* ]]
    if [ "$backend" = omni ]; then [[ "$output" == *--omni* ]]; else [[ "$output" != *--omni* ]]; fi
    run bash "$worker" '12345; touch bad'
    [ "$status" != 0 ]
  done
}
@test "router generation is stable when model settings are unchanged" {
  echo swap > "$CONF_DIR/serving-mode"
  bash "$REPO_DIR/rebuild-config.sh" --backend vllm
  cp "$SERVE_SH" "$BATS_TEST_TMPDIR/original.sh"
  bash "$REPO_DIR/rebuild-config.sh" --backend vllm
  cmp "$SERVE_SH" "$BATS_TEST_TMPDIR/original.sh"
}
@test "router config carries auth while workers only bind loopback and clear engine keys" {
  local secret id config worker
  secret="$(api_key_generate_secret)"; id="$(api_key_generate_id "$secret")"
  printf 'version\t1\n%s\tlocal\t2026-01-01T00:00:00Z\tactive\t%s\n' "$id" "$secret" > "$CONF_DIR/api-keys.tsv"
  echo swap > "$CONF_DIR/serving-mode"
  run bash "$REPO_DIR/rebuild-config.sh" --backend vllm
  [ "$status" = 0 ] || { echo "$output"; return 1; }
  config="$(find "$CONF_DIR/router" -name '*.json' | head -1)"
  jq -e --arg key "$secret" '.apiKeys == [$key]' "$config"
  [ "$(stat -c %a "$config")" = 600 ]
  worker="$(find "$CONF_DIR/router" -name '*.sh' | head -1)"
  grep -q 'unset VLLM_API_KEY' "$worker"
  ! grep -qF "$secret" "$worker"
}
@test "failed mode generation restores the old mode and restarts prior service" {
  echo direct > "$CONF_DIR/serving-mode"
  service_is_active() { return 0; }
  service_cmd() { echo "$1" >> "$BATS_TEST_TMPDIR/actions"; }
  cat > "$BIN_DIR/rebuild-config.sh" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$BIN_DIR/rebuild-config.sh"
  run mode_cmd swap
  [ "$status" != 0 ]
  [ "$(cat "$CONF_DIR/serving-mode")" = direct ]
  [ "$(cat "$BATS_TEST_TMPDIR/actions")" = $'stop\nstart' ]
}
@test "local folder import preserves files and existing selected model" {
  run add_cmd "$AI_DIR/models/vllm/model-b"
  [ "$status" = 0 ]
  [ -f "$AI_DIR/models/vllm/model-b/config.json" ]
  [ "$(cat "$ACTIVE_MODEL_FILE")" = model-a ]
  [ -f "$OVERRIDES_DIR/model-b.conf" ]
}
@test "menu changes backend without running clients or raw engine commands" {
  menu_run() { echo "$LOCALVLLM_BACKEND:$*" >> "$BATS_TEST_TMPDIR/actions"; }
  localvllm_backend_installed() { return 0; }
  menu_loop <<< $'b\n2\n1\nq'
  grep -qF 'omni:use model-a' "$BATS_TEST_TMPDIR/actions"
  grep -qF 'omni:start' "$BATS_TEST_TMPDIR/actions"
}

@test "Omni imports complete diffusion model folders with model_index.json" {
  localvllm_use_backend omni
  mkdir -p "$MODELS_DIR/diffusion-model/transformer"
  echo '{}' > "$MODELS_DIR/diffusion-model/model_index.json"
  echo '{}' > "$MODELS_DIR/diffusion-model/transformer/config.json"
  run add_cmd "$MODELS_DIR/diffusion-model"
  [ "$status" = 0 ]
  [ "$(localvllm_detect_format "$MODELS_DIR/diffusion-model")" = hf ]
  localvllm_model_entries "$MODELS_DIR" "$OVERRIDES_DIR" | grep -q '^diffusion-model'
}
@test "automatic mode dashboard URL and unload use the selected backend" {
  localvllm_use_backend omni
  echo swap > "$CONF_DIR/serving-mode"
  run ui_cmd --dashboard
  [ "$status" = 0 ]
  [[ "$output" == *http://127.0.0.1:8091/ui* ]]
  service_is_active() { return 0; }
  curl() { printf '%s\n' "$*" > "$BATS_TEST_TMPDIR/curl"; }
  run unload_cmd
  [ "$status" = 0 ]
  grep -q '8091/api/models/unload' "$BATS_TEST_TMPDIR/curl"
}
@test "automatic mode menu uses load to select and warm the requested model" {
  echo swap > "$CONF_DIR/serving-mode"
  localvllm_backend_installed() { return 0; }
  menu_run() { echo "$*" > "$BATS_TEST_TMPDIR/action"; }
  menu_start_model model-b
  [ "$(cat "$BATS_TEST_TMPDIR/action")" = 'load model-b' ]
}

@test "pull registers a downloaded Omni pipeline without selecting it" {
  localvllm_use_backend omni
  local snapshot="$AI_DIR/hf-cache/hub/models--org--pipeline/snapshots/abc123"
  mkdir -p "$snapshot" "$(dirname "$(dirname "$snapshot")")/refs"
  echo '{}' > "$snapshot/model_index.json"
  echo abc123 > "$(dirname "$(dirname "$snapshot")")/refs/main"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" %q\n' "$snapshot" > "$VENV_DIR/bin/python"
  chmod +x "$VENV_DIR/bin/python"
  run pull_cmd org/pipeline
  [ "$status" = 0 ] || { echo "$output"; return 1; }
  [ -L "$MODELS_DIR/org__pipeline" ]
  [ -f "$OVERRIDES_DIR/org__pipeline.conf" ]
  [ "$(cat "$ACTIVE_MODEL_FILE")" = model-a ]
}
@test "failed download leaves model registry and active selection unchanged" {
  printf '#!/usr/bin/env bash\nexit 9\n' > "$VENV_DIR/bin/python"
  run pull_cmd org/failure
  [ "$status" != 0 ]
  [ ! -e "$OVERRIDES_DIR/org__failure.conf" ]
  [ "$(cat "$ACTIVE_MODEL_FILE")" = model-a ]
}

@test "automatic load warms a native health endpoint rather than unsupported server root" {
  echo swap > "$CONF_DIR/serving-mode"
  service_is_active() { return 0; }
  use_cmd() { :; }
  curl() { printf '%s\n' "$*" > "$BATS_TEST_TMPDIR/curl"; }
  run load_cmd model-b
  [ "$status" = 0 ]
  grep -q '/upstream/model-b/health' "$BATS_TEST_TMPDIR/curl"
}

@test "key lifecycle configures direct engine or swap frontend for both backends" {
  . "$REPO_DIR/lib/cli/key.sh"
  key_activate() { bash "$REPO_DIR/rebuild-config.sh" --backend "$LOCALVLLM_BACKEND" >/dev/null; }
  local backend mode registry id secret config digest
  for backend in vllm omni; do
    localvllm_use_backend "$backend"
    registry="$(api_key_registry_path)"
    for mode in direct swap; do
      rm -f "$registry"
      echo "$mode" > "$CONF_DIR/serving-mode"
      key_create_cmd example >/dev/null
      secret="$(api_key_active_secrets "$registry")"
      id="$(api_key_registry_rows "$registry" | awk -F'\t' '$4 == "active" {print $1}')"
      if [ "$mode" = swap ]; then
        digest="$(config_assignment_value LOCALVLLM_ROUTER_DIGEST "$SERVE_ENV")"
        config="$CONF_DIR/router/$digest.json"
        jq -e --arg key "$secret" '.apiKeys == [$key]' "$config"
      else
        grep -qF "$secret" "$SERVE_SH"
      fi
      key_rotate_cmd "$id" >/dev/null
      [ "$(api_key_active_secrets "$registry")" != "$secret" ]
      id="$(api_key_registry_rows "$registry" | awk -F'\t' '$4 == "active" {print $1}')"
      key_revoke_cmd "$id" >/dev/null
      [ "$(api_key_active_count "$registry")" = 0 ]
      if [ "$mode" = swap ]; then
        digest="$(config_assignment_value LOCALVLLM_ROUTER_DIGEST "$SERVE_ENV")"
        jq -e '.apiKeys == null' "$CONF_DIR/router/$digest.json"
      else
        ! grep -q -- --api-key "$SERVE_SH"
      fi
    done
  done
}

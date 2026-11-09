#!/usr/bin/env bats

setup() {
  REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SCRIPT_DIR="$REPO_DIR"
  AI_DIR="$BATS_TEST_TMPDIR/ai"
  export LOCALVLLM_DIR="$AI_DIR"
  export LOCALVLLM_DEFAULT_DIR="$AI_DIR"

  # shellcheck source=../localvllm.conf
  . "$REPO_DIR/localvllm.conf"
  # shellcheck source=../lib/common.sh
  . "$REPO_DIR/lib/common.sh"
  # shellcheck source=../lib/install.sh
  . "$REPO_DIR/lib/install.sh"
  # shellcheck source=../lib/cli/core.sh
  . "$REPO_DIR/lib/cli/core.sh"
  # shellcheck source=../lib/cli/service.sh
  . "$REPO_DIR/lib/cli/service.sh"
  # shellcheck source=../lib/cli/models.sh
  . "$REPO_DIR/lib/cli/models.sh"

  localvllm_capture_global_runtime
  localvllm_use_backend vllm

  mkdir -p "$MODELS_DIR/model-a" "$MODELS_DIR/model-b" "$OVERRIDES_DIR"
  : > "$MODELS_DIR/model-a/config.json"
  : > "$MODELS_DIR/model-b/config.json"
  printf 'model-a\n' > "$ACTIVE_MODEL_FILE"
  printf '8010\n' > "$PORT_FILE"

  service_is_active() { return 1; }
  api_models() { return 1; }
  apply_config_change() { printf 'applied\n' > "$BATS_TEST_TMPDIR/applied"; }
}

@test "models lists both models and marks the active one" {
  run models_cmd
  [ "$status" -eq 0 ]
  [[ "$output" == *"Backend: vLLM (vllm)"* ]]
  [[ "$output" == *"model-a"* ]]
  [[ "$output" == *"model-b"* ]]
  [[ "$output" == *"Selected model: model-a"* ]]
  [[ "$output" == *"Service: not running"* ]]
}

@test "use selects an existing local model and applies configuration" {
  run use_cmd model-b
  [ "$status" -eq 0 ]
  [ "$(cat "$ACTIVE_MODEL_FILE")" = "model-b" ]
  [ -f "$BATS_TEST_TMPDIR/applied" ]
  [[ "$output" == *"Selected model: model-b"* ]]
}

@test "models --json emits machine-readable model state" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  run models_cmd --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.backend == "vllm" and (.models | length) == 2' >/dev/null
  echo "$output" | jq -e '.active_model == "" and .active_models == [] and .direct_model == "model-a"' >/dev/null
}

@test "status --json emits machine-readable backend state" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  run status_cmd --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.backend == "vllm" and .installed == false' >/dev/null
}

@test "doctor --json emits machine-readable health state" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  run doctor_cmd --json vllm
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ok == false and (.backends | length) == 1' >/dev/null
}

@test "use rolls back the active model when launcher generation fails" {
  apply_config_change() { return 1; }
  run use_cmd model-b
  [ "$status" -ne 0 ]
  [ "$(cat "$ACTIVE_MODEL_FILE")" = "model-a" ]
  [[ "$output" == *"previous model and launcher were restored"* ]]
}

@test "use creates a models.d entry for a Hugging Face repo id" {
  run use_cmd 'org/model-x'
  [ "$status" -eq 0 ]
  local override="$OVERRIDES_DIR/org__model-x.conf"
  [ -f "$override" ]
  grep -qF "ID=org/model-x" "$override"
  grep -qF "MODEL=org/model-x" "$override"
  [ "$(cat "$ACTIVE_MODEL_FILE")" = "org/model-x" ]
}

@test "load all is rejected because vLLM serves one model per server" {
  run load_cmd all
  [ "$status" -ne 0 ]
  [[ "$output" == *"serves one model per server"* ]]
}

@test "unload reports a stopped service without starting anything" {
  run unload_cmd
  [ "$status" -eq 0 ]
  [[ "$output" == *"is not running"* ]]
}

@test "ui prints docs and API URLs for the selected backend" {
  run ui_cmd
  [ "$status" -eq 0 ]
  [[ "$output" == *"http://127.0.0.1:8010/docs"* ]]
  [[ "$output" == *"http://127.0.0.1:8010/v1"* ]]
}

@test "ui prints the omni backend after switching" {
  localvllm_use_backend omni
  mkdir -p "$CONF_DIR"
  printf '8091\n' > "$PORT_FILE"
  run ui_cmd
  [ "$status" -eq 0 ]
  [[ "$output" == *"Backend: vLLM-Omni (omni)"* ]]
  [[ "$output" == *"http://127.0.0.1:8091/docs"* ]]
}

@test "start without a model refuses before invoking systemd" {
  localvllm_backend_installed() { return 0; }
  rm -rf "$MODELS_DIR/model-a" "$MODELS_DIR/model-b" "$ACTIVE_MODEL_FILE"
  has_user_service() { echo called > "$BATS_TEST_TMPDIR/systemd-called"; return 0; }
  run service_cmd_one start
  [ "$status" -ne 0 ]
  [[ "$output" == *"localvllm setup"* ]]
  [[ "$output" == *"localvllm --backend vllm use MODEL"* ]]
  [ ! -f "$BATS_TEST_TMPDIR/systemd-called" ]
}

@test "Omni missing-model guidance uses the Omni backend" {
  localvllm_backend_installed() { return 0; }
  localvllm_use_backend omni
  run service_cmd_one start
  [ "$status" -ne 0 ]
  [[ "$output" == *"localvllm --backend omni use MODEL"* ]]
  [[ "$output" == *"localvllm start omni"* ]]
}

@test "restart with no model does not stop a running service" {
  rm -rf "$MODELS_DIR/model-a" "$MODELS_DIR/model-b" "$ACTIVE_MODEL_FILE"
  service_is_active() { return 0; }
  has_user_service() { echo called > "$BATS_TEST_TMPDIR/systemd-called"; return 0; }
  run service_cmd_one restart
  [ "$status" -ne 0 ]
  [ ! -f "$BATS_TEST_TMPDIR/systemd-called" ]
}

@test "swap models report actual loaded model separately from saved direct selection for both backends" {
  local backend
  for backend in vllm omni; do
    localvllm_use_backend "$backend"
    mkdir -p "$MODELS_DIR/model-a" "$MODELS_DIR/model-b" "$CONF_DIR"
    : > "$MODELS_DIR/model-a/config.json"; : > "$MODELS_DIR/model-b/config.json"
    echo model-a > "$ACTIVE_MODEL_FILE"
    echo swap > "$CONF_DIR/serving-mode"
    service_is_active() { return 0; }
    router_model_states() { printf '{"model-b":"loaded"}\n'; }
    run models_cmd --json
    [ "$status" = 0 ] || { echo "$output"; return 1; }
    jq -e '.active_model == "model-b" and .served_model == "model-b" and .direct_model == "model-a" and .active_models == ["model-b"]' <<< "$output"
    jq -e '.models[] | select(.id == "model-a") | .active == false and .state == "unloaded"' <<< "$output"
    jq -e '.models[] | select(.id == "model-b") | .active == true and .state == "loaded"' <<< "$output"
    run models_cmd
    [ "$status" = 0 ]
    [[ "$output" == *STATE* && "$output" == *'Loaded models: model-b'* ]]
    [[ "$output" != *'SIZE  ACTIVE'* ]]
  done
}
@test "unavailable router state never falls back to saved direct selection" {
  echo swap > "$CONF_DIR/serving-mode"
  service_is_active() { return 0; }
  router_model_states() { return 1; }
  run models_cmd --json
  [ "$status" = 0 ]
  jq -e '.runtime_state_available == false and .active_model == "" and .direct_model == "model-a" and all(.models[]; .active == false and .state == "unavailable")' <<< "$output"
}
@test "router states preserve loading and multiple loaded workers" {
  echo swap > "$CONF_DIR/serving-mode"
  service_is_active() { return 0; }
  router_model_states() { echo '{"model-a":"loading","model-b":"loaded"}'; }
  run models_cmd --json
  [ "$status" = 0 ]
  jq -e '.models[] | select(.id == "model-a") | .state == "loading" and .active == false' <<< "$output"
  router_model_states() { echo '{"model-a":"loaded","model-b":"loaded"}'; }
  run models_cmd --json
  [ "$status" = 0 ]
  jq -e '.active_models == ["model-a","model-b"] and .active_model == ""' <<< "$output"
}
@test "router state reader validates and normalizes the live endpoint" {
  curl() { echo '{"running":[{"model":"model-b","state":"ready"},{"model":"model-a","state":"starting"}]}'; }
  run router_model_states
  [ "$status" = 0 ]
  jq -e '. == {"model-b":"loaded","model-a":"loading"}' <<< "$output"
  curl() { echo '{"error":"denied"}'; }
  run router_model_states
  [ "$status" != 0 ]
}

@test "runtime state requests use the selected vllm or Omni API port" {
  curl() {
    printf '%s\n' "$*" > "$BATS_TEST_TMPDIR/runtime-url"
    echo '{"running":[]}'
  }
  localvllm_use_backend vllm
  router_model_states >/dev/null
  grep -qF '127.0.0.1:8010/running' "$BATS_TEST_TMPDIR/runtime-url"
  localvllm_use_backend omni
  router_model_states >/dev/null
  grep -qF '127.0.0.1:8091/running' "$BATS_TEST_TMPDIR/runtime-url"
}

@test "both backends share live state across models status version and menu" {
  . "$REPO_DIR/lib/cli/lifecycle.sh"
  . "$REPO_DIR/lib/cli/menu.sh"
  vllm_installed_version() { echo 1.0; }
  vllm_omni_installed_version() { echo 1.0; }
  local backend
  for backend in vllm omni; do
    localvllm_use_backend "$backend"
    mkdir -p "$MODELS_DIR/model-a" "$MODELS_DIR/model-b" "$CONF_DIR"
    echo '{}' > "$MODELS_DIR/model-a/config.json"
    echo '{}' > "$MODELS_DIR/model-b/config.json"
    echo model-a > "$ACTIVE_MODEL_FILE"
    echo swap > "$CONF_DIR/serving-mode"
    service_is_active() { return 0; }
    router_model_states() { echo '{"model-b":"loaded"}'; }
    run status_cmd --json
    [ "$status" = 0 ]
    jq -e '.active_model == "model-b" and .direct_model == "model-a" and .active_models == ["model-b"]' <<< "$output"
    run version_one
    [ "$status" = 0 ]
    [[ "$output" == *'Loaded models: model-b'* && "$output" == *'Selected for direct mode: model-a'* ]]
    run menu_loop <<< q
    [ "$status" = 0 ]
    [[ "$output" == *'model-b [local files, loaded]'* && "$output" == *'model-a [local files, unloaded]'* ]]
    router_model_states() { return 1; }
    run status_cmd --json
    [ "$status" = 0 ]
    jq -e '.active_model == null and .active_models == [] and .runtime_state_available == false' <<< "$output"
  done
}

@test "direct runtime reports API model only when reachable and running for both backends" {
  local backend
  for backend in vllm omni; do
    localvllm_use_backend "$backend"
    mkdir -p "$MODELS_DIR/model-a" "$CONF_DIR"
    echo '{}' > "$MODELS_DIR/model-a/config.json"
    echo model-a > "$ACTIVE_MODEL_FILE"
    echo direct > "$CONF_DIR/serving-mode"
    service_is_active() { return 1; }
    api_models() { echo model-a; }
    run models_cmd --json
    [ "$status" = 0 ]
    jq -e '.active_models == [] and .direct_model == "model-a" and all(.models[]; .active == false)' <<< "$output"
    service_is_active() { return 0; }
    run models_cmd --json
    [ "$status" = 0 ]
    jq -e '.active_models == ["model-a"] and any(.models[]; .active == true)' <<< "$output"
    api_models() { return 1; }
    run models_cmd --json
    [ "$status" = 0 ]
    jq -e '.active_models == [] and .runtime_state_available == false' <<< "$output"
  done
}

@test "empty model lists still show service status for either backend" {
  local backend
  for backend in vllm omni; do
    localvllm_use_backend "$backend"
    MODELS_DIR="$BATS_TEST_TMPDIR/empty-$backend"
    OVERRIDES_DIR="$BATS_TEST_TMPDIR/empty-overrides-$backend"
    mkdir -p "$MODELS_DIR"
    run models_cmd
    [ "$status" = 0 ]
    [[ "$output" == *'No models found'* && "$output" == *'Service:'* ]]
  done
}

@test "failed launcher restart restores old files for both backends" {
  . "$REPO_DIR/lib/cli/lifecycle.sh"
  local backend
  for backend in vllm omni; do
    localvllm_use_backend "$backend"
    mkdir -p "$CONF_DIR"
    echo old > "$SERVE_SH"; echo old > "$SERVE_ENV"
    echo new > "$BATS_TEST_TMPDIR/new.sh"; echo new > "$BATS_TEST_TMPDIR/new.env"
    service_is_active() { return 0; }
    service_cmd() { return 1; }
    run localvllm_apply_candidates "$BATS_TEST_TMPDIR/new.sh" "$BATS_TEST_TMPDIR/new.env"
    [ "$status" != 0 ]
    [ "$(cat "$SERVE_SH")" = old ]
    [ "$(cat "$SERVE_ENV")" = old ]
  done
}

@test "add never applies configuration or restarts either backend" {
  . "$REPO_DIR/lib/cli/menu.sh"
  local backend
  for backend in vllm omni; do
    localvllm_use_backend "$backend"
    mkdir -p "$BATS_TEST_TMPDIR/new-model"
    echo '{}' > "$BATS_TEST_TMPDIR/new-model/config.json"
    localvllm_serving_mode() { echo swap; }
    apply_config_change() { echo unexpected > "$BATS_TEST_TMPDIR/restarted"; return 1; }
    run add_cmd "$BATS_TEST_TMPDIR/new-model"
    [ "$status" = 0 ]
    [ ! -e "$BATS_TEST_TMPDIR/restarted" ]
  done
}

@test "direct menu avoids runtime API queries" {
  . "$REPO_DIR/lib/cli/menu.sh"
  model_runtime_info() { echo unexpected > "$BATS_TEST_TMPDIR/api-called"; return 1; }
  run menu_loop <<< q
  [ "$status" = 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/api-called" ]
}

@test "remove preserves weights and refuses running or selected models on both backends" {
  . "$REPO_DIR/lib/cli/menu.sh"
  local backend cache link
  for backend in vllm omni; do
    localvllm_use_backend "$backend"
    mkdir -p "$CONF_DIR" "$MODELS_DIR"
    cache="$AI_DIR/$LOCALVLLM_HF_CACHE_SUBDIR/hub/models--org--weights/snapshots/abc"
    mkdir -p "$cache"; echo weights > "$cache/weights"
    model_register org/weights org/weights
    link="$MODELS_DIR/org__weights"; ln -s "$cache" "$link"
    echo org/weights > "$ACTIVE_MODEL_FILE"
    run remove_cmd org/weights
    [ "$status" != 0 ]
    echo another > "$ACTIVE_MODEL_FILE"
    service_is_active() { return 0; }
    run remove_cmd org/weights
    [ "$status" != 0 ]
    service_is_active() { return 1; }
    run remove_cmd org/weights
    [ "$status" = 0 ]
    [ -f "$cache/weights" ]
    [ ! -L "$link" ]
    [ ! -f "$OVERRIDES_DIR/org__weights.conf" ]
  done
}

@test "doctor JSON reports live router model and saved direct selection for both backends" {
  local backend
  for backend in vllm omni; do
    localvllm_use_backend "$backend"
    mkdir -p "$CONF_DIR" "$MODELS_DIR/model-a"
    echo '{}' > "$MODELS_DIR/model-a/config.json"
    echo model-a > "$ACTIVE_MODEL_FILE"
    echo swap > "$CONF_DIR/serving-mode"
    service_is_active() { return 0; }
    router_model_states() { echo '{"model-b":"loaded"}'; }
    run doctor_json_one
    [ "$status" = 0 ]
    jq -e '.active_model == "model-b" and .direct_model == "model-a" and .active_models == ["model-b"] and .model == null' <<< "$output"
  done
}

@test "ui open never starts a stopped service in either mode or backend" {
  local backend mode
  export DISPLAY=:0
  service_cmd() { echo unexpected > "$BATS_TEST_TMPDIR/started"; }
  xdg-open() { echo unexpected > "$BATS_TEST_TMPDIR/opened"; }
  for backend in vllm omni; do
    localvllm_use_backend "$backend"
    mkdir -p "$CONF_DIR"
    for mode in direct swap; do
      echo "$mode" > "$CONF_DIR/serving-mode"
      run ui_cmd --open
      [ "$status" != 0 ]
      [[ "$output" == *'Service is not running'* && "$output" == *"--backend $backend start"* ]]
    done
  done
  [ ! -e "$BATS_TEST_TMPDIR/started" ]
  [ ! -e "$BATS_TEST_TMPDIR/opened" ]
}

@test "ui open checks readiness and selects docs or dashboard without changing mode" {
  local backend mode expected
  export DISPLAY=:0
  service_is_active() { return 0; }
  curl() { return 0; }
  xdg-open() { echo "$1" > "$BATS_TEST_TMPDIR/opened"; }
  for backend in vllm omni; do
    localvllm_use_backend "$backend"
    mkdir -p "$CONF_DIR"
    for mode in direct swap; do
      echo "$mode" > "$CONF_DIR/serving-mode"
      expected=docs; [ "$mode" != swap ] || expected=ui
      run ui_cmd --open
      [ "$status" = 0 ]
      [[ "$(cat "$BATS_TEST_TMPDIR/opened")" == *"/$expected" ]]
      [ "$(cat "$CONF_DIR/serving-mode")" = "$mode" ]
    done
  done
  rm "$BATS_TEST_TMPDIR/opened"
  curl() { return 1; }
  run ui_cmd --open
  [ "$status" != 0 ]
  [[ "$output" == *'API is unavailable or still loading'* ]]
  [ ! -e "$BATS_TEST_TMPDIR/opened" ]
}

@test "start without an installed engine points to that backend installation" {
  localvllm_backend_installed() { return 1; }
  run service_cmd_one start
  [ "$status" != 0 ]
  [[ "$output" == *'Next: localvllm backend install vllm'* ]]
}

@test "setup plans independent backend and mode routes without starting services" {
  . "$REPO_DIR/lib/cli/menu.sh"
  local backend selection mode selection_mode
  localvllm_acquire_global_lock() { :; }
  menu_ensure_engine() { return 0; }
  menu_run() { printf '%s %s\n' "$LOCALVLLM_BACKEND" "$*" >> "$BATS_TEST_TMPDIR/setup-commands"; }
  for selection in 1 2; do
    backend=vllm; [ "$selection" = 1 ] || backend=omni
    localvllm_use_backend "$backend"
    mkdir -p "$MODELS_DIR/model-a" "$CONF_DIR"
    echo '{}' > "$MODELS_DIR/model-a/config.json"
    for selection_mode in 1 2; do
      mode=direct; [ "$selection_mode" = 1 ] || mode=swap
      : > "$BATS_TEST_TMPDIR/setup-commands"
      run setup_flow <<< "$selection
$selection_mode
3
model-a
y"
      [ "$status" = 0 ]
      grep -q "$backend use model-a" "$BATS_TEST_TMPDIR/setup-commands"
      grep -q "$backend mode $mode" "$BATS_TEST_TMPDIR/setup-commands"
      grep -q "$backend backend default $backend" "$BATS_TEST_TMPDIR/setup-commands"
      ! grep -q ' start\| load\| restart' "$BATS_TEST_TMPDIR/setup-commands"
      [[ "$output" == *"Next: localvllm --backend $backend start"* ]]
    done
  done
}

@test "setup cancellation and running backend do not invoke mutating commands" {
  . "$REPO_DIR/lib/cli/menu.sh"
  menu_run() { echo unexpected > "$BATS_TEST_TMPDIR/changed"; }
  run setup_flow <<< $'1\n1\n1\norg/model\nn'
  [ "$status" = 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/changed" ]
  service_is_active() { return 0; }
  run setup_flow <<< 2
  [ "$status" != 0 ]
  [[ "$output" == *'setup will not restart'* || "$output" == *'Setup will not restart'* ]]
  [ ! -e "$BATS_TEST_TMPDIR/changed" ]
}

@test "failed setup step does not save a new default or start anything" {
  . "$REPO_DIR/lib/cli/menu.sh"
  localvllm_acquire_global_lock() { :; }
  menu_ensure_engine() { return 0; }
  menu_run() {
    printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/setup-failed-commands"
    [ "$1" != mode ]
  }
  run setup_flow <<< $'1\n2\n3\nmodel-a\ny'
  [ "$status" != 0 ]
  ! grep -q 'backend default\|start\|load' "$BATS_TEST_TMPDIR/setup-failed-commands"
}

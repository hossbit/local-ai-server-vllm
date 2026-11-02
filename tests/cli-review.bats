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
  [[ "$output" == *"Active model: model-a"* ]]
  [[ "$output" == *"Service: not running"* ]]
}

@test "use selects an existing local model and applies configuration" {
  run use_cmd model-b
  [ "$status" -eq 0 ]
  [ "$(cat "$ACTIVE_MODEL_FILE")" = "model-b" ]
  [ -f "$BATS_TEST_TMPDIR/applied" ]
  [[ "$output" == *"Active model: model-b"* ]]
}

@test "models --json emits machine-readable model state" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  run models_cmd --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.backend == "vllm" and (.models | length) == 2' >/dev/null
  echo "$output" | jq -e '.active_model == "model-a"' >/dev/null
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

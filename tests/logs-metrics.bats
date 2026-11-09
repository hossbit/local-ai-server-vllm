#!/usr/bin/env bats
setup() {
  REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SCRIPT_DIR="$REPO_DIR"
  AI_DIR="$BATS_TEST_TMPDIR/ai"
  . "$REPO_DIR/localvllm.conf"
  . "$REPO_DIR/lib/common.sh"
  . "$REPO_DIR/lib/cli/core.sh"
  . "$REPO_DIR/lib/cli/service.sh"
  . "$REPO_DIR/lib/cli/models.sh"
  . "$REPO_DIR/lib/cli/key.sh"
  localvllm_capture_global_runtime
  localvllm_use_backend vllm
  mkdir -p "$AI_DIR/logs"
  echo 'engine-message' > "$AI_DIR/logs/vllm.log"
  echo 'omni-message' > "$AI_DIR/logs/omni.log"
  echo 'update-message' > "$AI_DIR/logs/update.log"
  gpu_vram_total_min_bytes() { echo 0; }
  gpu_vram_free_min_bytes() { echo 0; }
  export REQUESTS="$BATS_TEST_TMPDIR/requests"
}
@test "logs lists and reads all current files and rejects traversal" {
  run logs_cmd --list
  [ "$status" = 0 ]; [[ "$output" == *'update.log'* ]]
  run logs_cmd all --no-follow --lines 5
  [ "$status" = 0 ]; [[ "$output" == *engine-message* && "$output" == *omni-message* && "$output" == *update-message* ]]
  run logs_cmd --file ../localvllm.conf --no-follow
  [ "$status" != 0 ]
  run logs_cmd --lines 0 --no-follow
  [ "$status" != 0 ]
}
@test "logs missing runtime file is actionable without an endless empty tail" {
  run logs_cmd --file absent.log --no-follow
  [ "$status" != 0 ]; [[ "$output" == *'Log not created yet'* ]]
}
@test "help topics cover models modes keys logs metrics and troubleshooting" {
  local topic
  for topic in models modes keys logs metrics troubleshoot; do
    run help_topic "$topic"
    [ "$status" = 0 ]; [ -n "$output" ]
  done
  run help_topic unknown
  [ "$status" = 2 ]
}
@test "metrics parses labels counters cache maxima and sampled speed" {
  run metrics_summary $'vllm:num_requests_running{model_name="test model"} 2\nvllm:num_requests_waiting 3\nvllm:kv_cache_usage_perc{engine="0"} 0.25\nvllm:kv_cache_usage_perc{engine="1"} 0.5\nvllm:generation_tokens_total 120\nvllm:time_to_first_token_seconds_count 2\nvllm:time_to_first_token_seconds_sum 0.5' 100 2
  [ "$status" = 0 ]
  [[ "$output" == *'Running requests: 2 | Waiting: 3'* && "$output" == *'50.0%'* && "$output" == *'10.0 tokens/s'* && "$output" == *'0.250 s'* ]]
  run metrics_summary 'vllm:generation_tokens_total 3' 100 2
  [[ "$output" == *'counter reset'* && "$output" == *'Waiting: n/a'* ]]
}
@test "swap metrics never route through upstream or wake an unloaded model on either backend" {
  curl() {
    printf '%s\n' "$*" >> "$REQUESTS"
    case "$*" in */running*) echo '{"running":[]}' ;; *) return 1 ;; esac
  }
  local backend
  for backend in vllm omni; do
    localvllm_use_backend "$backend"
    localvllm_serving_mode() { echo swap; }
    run metrics_cmd
    [ "$status" = 0 ]; [[ "$output" == *'No ready model'* ]]
  done
  ! grep -q '/upstream/' "$REQUESTS"
  [ "$(wc -l < "$REQUESTS")" = 2 ]
}
@test "swap metrics reads ready workers directly and validates proxy origins" {
  localvllm_serving_mode() { echo swap; }
  curl() {
    printf '%s\n' "$*" >> "$REQUESTS"
    case "$*" in
      */running*) echo '{"running":[{"model":"a","state":"ready","proxy":"http://127.0.0.1:5801"},{"model":"bad","state":"ready","proxy":"http://example.com"}]}' ;;
      *127.0.0.1:5801/metrics*) echo 'vllm:num_requests_running 1' ;;
      *) return 1 ;;
    esac
  }
  run metrics_cmd
  [ "$status" = 0 ]
  [[ "$output" == *'Loaded model: a'* && "$output" == *'Running requests: 1'* && "$output" == *'unsupported worker URL'* ]]
  ! grep -q 'example.com/metrics\|/upstream/' "$REQUESTS"
}
@test "rotation keeps five old sessions and event logs are private" {
  local i
  LOCALVLLM_LOG_KEEP=5
  for i in {1..7}; do echo old > "$AI_DIR/logs/install.log"; localvllm_rotate_log "$AI_DIR/logs/install.log"; done
  [ "$(find "$AI_DIR/logs" -name 'install.log.*' | wc -l)" = 5 ]
  localvllm_log_event 1 key omni
  [ "$(stat -c %a "$AI_DIR/logs/manager-events.log")" = 600 ]
  grep -q 'command=key backend=omni exit=1' "$AI_DIR/logs/manager-events.log"
}

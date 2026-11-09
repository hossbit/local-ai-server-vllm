#!/usr/bin/env bats

setup() {
  REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SCRIPT_DIR="$REPO_DIR"
  export LOCALVLLM_DIR="$BATS_TEST_TMPDIR/ai"
  export LOCALVLLM_DEFAULT_DIR="$LOCALVLLM_DIR"

  # shellcheck source=../localvllm.conf
  . "$REPO_DIR/localvllm.conf"
  # shellcheck source=../lib/common.sh
  . "$REPO_DIR/lib/common.sh"
  # shellcheck source=../lib/cli/key.sh
  . "$REPO_DIR/lib/cli/key.sh"

  localvllm_capture_global_runtime
  localvllm_use_backend vllm
  mkdir -p "$CONF_DIR"
}

# --- path helpers ---

@test "expand_path expands a bare tilde" {
  run expand_path '~'
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME" ]
}

@test "expand_path expands a tilde-prefixed path" {
  run expand_path '~/ai-vllm/models'
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/ai-vllm/models" ]
}

@test "expand_path leaves absolute paths unchanged" {
  run expand_path '/opt/ai-vllm'
  [ "$output" = "/opt/ai-vllm" ]
}

# --- backend isolation ---

@test "vllm and omni backends use separate paths, ports, services, and venvs" {
  localvllm_use_backend vllm
  [ "$LOCALVLLM_BACKEND" = "vllm" ]
  [ "$VLLM_OMNI" = "0" ]
  [ "$MODELS_DIR" = "$LOCALVLLM_DIR/models/vllm" ]
  [ "$CONF_DIR" = "$LOCALVLLM_DIR/conf/backends/vllm" ]
  [ "$VENV_DIR" = "$LOCALVLLM_DIR/venv/vllm" ]
  [ "$LOCALVLLM_DEFAULT_PORT" = "8000" ]
  [ "$LOCALVLLM_SERVICE_NAME" = "localvllm.service" ]

  localvllm_use_backend omni
  [ "$LOCALVLLM_BACKEND" = "omni" ]
  [ "$VLLM_OMNI" = "1" ]
  [ "$MODELS_DIR" = "$LOCALVLLM_DIR/models/omni" ]
  [ "$CONF_DIR" = "$LOCALVLLM_DIR/conf/backends/omni" ]
  [ "$VENV_DIR" = "$LOCALVLLM_DIR/venv/omni" ]
  [ "$LOCALVLLM_DEFAULT_PORT" = "8091" ]
  [ "$LOCALVLLM_SERVICE_NAME" = "localvllm-omni.service" ]

  localvllm_use_backend vllm
  [ "$VLLM_OMNI" = "0" ]
  [ "$MODELS_DIR" = "$LOCALVLLM_DIR/models/vllm" ]
}

@test "backend aliases resolve to canonical names" {
  run localvllm_backend_name text
  [ "$output" = "vllm" ]

  run localvllm_backend_name vllm-omni
  [ "$output" = "omni" ]

  run localvllm_backend_name omni-vllm
  [ "$output" = "omni" ]

  run localvllm_backend_name unknown
  [ "$status" -eq 1 ]
}

@test "backend list is deterministic and deduplicated" {
  run localvllm_backend_list
  [ "$status" -eq 0 ]
  [ "$output" = $'vllm\nomni' ]
}

# --- formatting ---

@test "format_bytes_gib formats bytes as GiB with one decimal" {
  run format_bytes_gib $((1024 * 1024 * 1024))
  [ "$output" = "1.0 GiB" ]

  run format_bytes_gib 0
  [ "$output" = "0.0 GiB" ]
}

@test "localvllm_safe_id keeps a readable filesystem name" {
  run localvllm_safe_id 'Qwen/Qwen3-Omni-30B'
  [ "$output" = "Qwen__Qwen3-Omni-30B" ]

  run localvllm_safe_id 'a b'
  [ "$output" = "a__b" ]
}

# --- model discovery ---

@test "localvllm_model_entries discovers HF directories, GGUF files, and overrides" {
  mkdir -p "$MODELS_DIR/hf-a" "$MODELS_DIR/gguf-dir" "$OVERRIDES_DIR"
  : > "$MODELS_DIR/hf-a/config.json"
  : > "$MODELS_DIR/gguf-dir/model.gguf"
  : > "$MODELS_DIR/direct.gguf"
  printf "ID='org/model'\nMODEL='org/model'\n" > "$OVERRIDES_DIR/org__model.conf"

  run localvllm_model_entries "$MODELS_DIR" "$OVERRIDES_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'hf-a\tlocal\t'"$MODELS_DIR/hf-a"$'\thf\t'* ]]
  [[ "$output" == *$'gguf-dir\tlocal\t'"$MODELS_DIR/gguf-dir/model.gguf"$'\tgguf\t'"$MODELS_DIR/gguf-dir"* ]]
  [[ "$output" == *$'direct\tlocal\t'"$MODELS_DIR/direct.gguf"$'\tgguf\t'* ]]
  [[ "$output" == *$'org/model\tconfigured\torg/model\tremote\t'* ]]
}

@test "localvllm_model_entries lets a configured model override a local one" {
  mkdir -p "$MODELS_DIR/model-a" "$OVERRIDES_DIR"
  : > "$MODELS_DIR/model-a/config.json"
  printf "ID='model-a'\nMODEL='other/model-a'\n" > "$OVERRIDES_DIR/model-a.conf"

  run localvllm_model_entries "$MODELS_DIR" "$OVERRIDES_DIR"
  [[ "$output" == *$'model-a\tconfigured\tother/model-a\tremote\t'* ]]
  [[ "$output" != *$'model-a\tlocal\t'* ]]
}

@test "a settings-only models.d file attaches to a discovered local model" {
  mkdir -p "$MODELS_DIR/model-a" "$OVERRIDES_DIR"
  : > "$MODELS_DIR/model-a/config.json"
  printf 'TENSOR_PARALLEL_SIZE=2\n' > "$OVERRIDES_DIR/model-a.conf"

  run localvllm_model_entries "$MODELS_DIR" "$OVERRIDES_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'model-a\tconfigured\t'"$MODELS_DIR/model-a"$'\thf\t'* ]]
  [[ "$output" != *"does not set MODEL"* ]]
}

@test "localvllm_model_entries discovers symlinked Hugging Face snapshots" {
  mkdir -p "$MODELS_DIR/hub/models--org--model/snapshots/abc" \
    "$MODELS_DIR/hub/models--org--model/blobs"
  : > "$MODELS_DIR/hub/models--org--model/blobs/config.json"
  ln -s ../../blobs/config.json "$MODELS_DIR/hub/models--org--model/snapshots/abc/config.json"

  run localvllm_model_entries "$MODELS_DIR" "$OVERRIDES_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'org/model\tlocal\t'* ]]
  [[ "$output" == *$'\thf\t'* ]]
}

@test "localvllm_model_size_bytes handles a single file" {
  printf 'abc' > "$BATS_TEST_TMPDIR/one.gguf"
  run localvllm_model_size_bytes "$BATS_TEST_TMPDIR/one.gguf"
  [ "$output" = "3" ]
}

@test "localvllm_model_type infers common embedding and reranking names" {
  run localvllm_model_type 'bge-small-en'
  [ "$output" = "embedding" ]

  run localvllm_model_type 'nomic-embed-text-v1.5'
  [ "$output" = "embedding" ]

  run localvllm_model_type 'cross-encoder-rerank'
  [ "$output" = "reranking" ]

  run localvllm_model_type 'Qwen3-8B'
  [ "$output" = "chat" ]
}

@test "localvllm_resolve_active selects the only model automatically" {
  mkdir -p "$MODELS_DIR/only-model"
  : > "$MODELS_DIR/only-model/config.json"

  localvllm_resolve_active "$MODELS_DIR" "$ACTIVE_MODEL_FILE" "$OVERRIDES_DIR"
  [ "$ACTIVE_ID" = "only-model" ]
  [ "$ACTIVE_FORMAT" = "hf" ]
}

@test "localvllm_resolve_active requires a choice when multiple models exist" {
  mkdir -p "$MODELS_DIR/a" "$MODELS_DIR/b"
  : > "$MODELS_DIR/a/config.json"
  : > "$MODELS_DIR/b/config.json"

  run localvllm_resolve_active "$MODELS_DIR" "$ACTIVE_MODEL_FILE" "$OVERRIDES_DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"multiple models"* ]]
}

@test "localvllm_resolve_active honors the active-model file" {
  mkdir -p "$MODELS_DIR/a" "$MODELS_DIR/b"
  : > "$MODELS_DIR/a/config.json"
  : > "$MODELS_DIR/b/config.json"
  mkdir -p "$CONF_DIR"
  printf 'b\n' > "$ACTIVE_MODEL_FILE"

  localvllm_resolve_active "$MODELS_DIR" "$ACTIVE_MODEL_FILE" "$OVERRIDES_DIR"
  [ "$ACTIVE_ID" = "b" ]
}

# --- API key registry ---

@test "api_key_generate_secret and id match the registry format" {
  local secret id
  secret="$(api_key_generate_secret)"
  [[ "$secret" =~ $API_KEY_SECRET_RE ]]
  id="$(api_key_generate_id "$secret")"
  [[ "$id" =~ $API_KEY_ID_RE ]]
}

@test "api_key_registry validates and reports active keys" {
  local registry secret id created row content
  registry="$CONF_DIR/api-keys.tsv"
  secret="$(api_key_generate_secret)"
  id="$(api_key_generate_id "$secret")"
  created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  row="$(printf '%s\t%s\t%s\tactive\t%s' "$id" test-key "$created" "$secret")"
  content="$(api_key_registry_content_from_rows "$row")"
  api_key_registry_write_atomic "$registry" "$content"

  api_key_registry_validate "$registry"
  [ "$(api_key_active_count "$registry")" = "1" ]
  [ "$(api_key_active_secrets "$registry")" = "$secret" ]
  [ "$(api_key_active_named_secrets "$registry")" = "$(printf 'test-key\t%s' "$secret")" ]
  [ "$(api_key_mask "$secret")" = "${secret:0:17}...${secret: -4}" ]
}

@test "global operation lock refuses a concurrent writer" {
  command -v flock >/dev/null 2>&1 || skip "flock not installed"
  local lock="$LOCALVLLM_DIR/conf/.localvllm.lock"
  mkdir -p "$(dirname "$lock")"
  flock "$lock" -c 'sleep 5' &
  local holder=$!
  sleep 0.2

  run bash -c '
    . "$1/localvllm.conf"
    . "$1/lib/common.sh"
    CONF_ROOT="$2/conf"
    localvllm_acquire_global_lock
  ' _ "$REPO_DIR" "$LOCALVLLM_DIR"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  [ "$status" -ne 0 ]
  [[ "$output" == *"another Local vLLM operation is running"* ]]
}

@test "api_key_registry rejects a missing version header" {
  local registry
  registry="$CONF_DIR/api-keys.tsv"
  printf 'not-a-header\n' > "$registry"

  run api_key_registry_validate "$registry"
  [ "$status" -eq 1 ]
  [[ "$output" == *"version header"* ]]
}

@test "downloaded models get readable links without duplicate registry entries" {
  AI_DIR="$LOCALVLLM_DIR"
  local cache="$AI_DIR/hf-cache/hub/models--org--model"
  mkdir -p "$cache/refs" "$cache/snapshots/abc123" "$OVERRIDES_DIR"
  printf 'abc123\n' > "$cache/refs/main"
  printf '{}\n' > "$cache/snapshots/abc123/config.json"
  printf 'ID=org/model\nMODEL=org/model\n' > "$OVERRIDES_DIR/org__model.conf"
  localvllm_link_cached_model org/model main
  [ -L "$MODELS_DIR/org__model" ]
  [ -f "$MODELS_DIR/org__model/config.json" ]
  run localvllm_model_entries "$MODELS_DIR" "$OVERRIDES_DIR"
  [ "$status" = 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" = 1 ]
  [[ "$output" == *$'org/model\tconfigured\torg/model\tremote\t'"$MODELS_DIR/org__model"* ]]
}
@test "cache library updates only its own symlinks and keeps user folders" {
  AI_DIR="$LOCALVLLM_DIR"
  local cache="$AI_DIR/hf-cache/hub/models--org--model"
  mkdir -p "$cache/refs" "$cache/snapshots/abc123" "$cache/snapshots/def456"
  : > "$cache/snapshots/abc123/config.json"
  : > "$cache/snapshots/def456/config.json"
  echo abc123 > "$cache/refs/main"
  localvllm_link_cached_model org/model main
  echo def456 > "$cache/refs/main"
  localvllm_link_cached_model org/model main
  [ "$(readlink "$MODELS_DIR/org__model")" = "$cache/snapshots/def456" ]
  mkdir -p "$MODELS_DIR/other__model"
  : > "$MODELS_DIR/other__model/user-file"
  localvllm_link_cached_model other/model main
  [ -f "$MODELS_DIR/other__model/user-file" ]
}

@test "a models.d file with MODEL but no ID is still discovered" {
  mkdir -p "$MODELS_DIR/model-a" "$OVERRIDES_DIR"
  : > "$MODELS_DIR/model-a/config.json"
  printf 'MODEL=%q\n' '/srv/models/a model' > "$OVERRIDES_DIR/model-a.conf"

  run localvllm_model_entries "$MODELS_DIR" "$OVERRIDES_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'model-a\tconfigured\t/srv/models/a model\tremote\t'* ]]
  [[ "$output" != *"does not set MODEL"* ]]
}

@test "model size counts one weight format instead of every copy" {
  mkdir -p "$BATS_TEST_TMPDIR/size-model"
  head -c 100 /dev/zero > "$BATS_TEST_TMPDIR/size-model/model.bin"
  head -c 200 /dev/zero > "$BATS_TEST_TMPDIR/size-model/model.safetensors"
  head -c 50 /dev/zero > "$BATS_TEST_TMPDIR/size-model/consolidated.00.pth"

  run localvllm_model_size_bytes "$BATS_TEST_TMPDIR/size-model"
  [ "$status" -eq 0 ]
  [ "$output" = "200" ]
}

@test "API URLs bracket IPv6 loopback listeners" {
  localvllm_use_backend vllm
  LOCALVLLM_LISTEN_HOST=::1
  printf '8123\n' > "$PORT_FILE"

  run api_base_url_for_port_file "$PORT_FILE"
  [ "$status" -eq 0 ]
  [ "$output" = "http://[::1]:8123" ]
}

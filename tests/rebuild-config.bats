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

  mkdir -p "$AI_DIR/models/vllm/model-a" \
    "$AI_DIR/models/omni/omni-model" \
    "$AI_DIR/conf/backends/vllm/models.d" \
    "$AI_DIR/conf/backends/omni/models.d" \
    "$AI_DIR/venv/vllm/bin" \
    "$AI_DIR/venv/omni/bin"

  : > "$AI_DIR/models/vllm/model-a/config.json"
  : > "$AI_DIR/models/omni/omni-model/config.json"
  printf 'model-a\n' > "$AI_DIR/conf/backends/vllm/active-model"
  printf 'omni-model\n' > "$AI_DIR/conf/backends/omni/active-model"
  printf '8010\n' > "$AI_DIR/conf/backends/vllm/port"
  printf '8091\n' > "$AI_DIR/conf/backends/omni/port"

  # rebuild-config only asks vLLM-Omni whether it is importable; a tiny stub is
  # enough for the generated-launcher tests.
  cat > "$AI_DIR/venv/omni/bin/python" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$AI_DIR/venv/omni/bin/python"
  : > "$AI_DIR/venv/vllm/bin/vllm"
  chmod +x "$AI_DIR/venv/vllm/bin/vllm"
  : > "$AI_DIR/venv/omni/bin/vllm"
  chmod +x "$AI_DIR/venv/omni/bin/vllm"
}

run_rebuild() {
  local backend="${1:-vllm}"
  run bash "$REPO_DIR/rebuild-config.sh" --backend "$backend" \
    "$AI_DIR/conf/backends/$backend/serve.sh" \
    "$AI_DIR/conf/backends/$backend/serve.env"
  [ "$status" -eq 0 ] || {
    echo "$output" >&2
    return 1
  }
}

@test "generates an isolated vllm launcher with expected flags" {
  run_rebuild vllm

  local script="$AI_DIR/conf/backends/vllm/serve.sh"
  [ -f "$script" ]
  grep -qF "venv/vllm/bin/vllm serve" "$script"
  grep -qF "models/vllm/model-a" "$script"
  grep -qF -- "--served-model-name model-a" "$script"
  grep -qF -- "--tensor-parallel-size 1" "$script"
  grep -qF -- "--gpu-memory-utilization 0.90" "$script"
  grep -qF -- "--max-model-len 8192" "$script"
  grep -qF -- "--port 8010" "$script"
  [ "$(stat -c '%a' "$script")" = "700" ]
  [ "$(stat -c '%a' "$AI_DIR/conf/backends/vllm/serve.env")" = "600" ]
  grep -qF "LOCALVLLM_BACKEND=vllm" "$AI_DIR/conf/backends/vllm/serve.env"
}

@test "per-model overrides replace global defaults" {
  cat > "$AI_DIR/conf/backends/vllm/models.d/model-a.conf" <<'EOF'
TENSOR_PARALLEL_SIZE=2
GPU_MEMORY_UTILIZATION=0.80
MAX_MODEL_LEN=4096
MAX_NUM_SEQS=32
MAX_NUM_BATCHED_TOKENS=1024
DTYPE=bfloat16
KV_CACHE_DTYPE=fp8
SERVED_MODEL_NAME="custom-name"
EXTRA_ARGS=(--enable-prefix-caching '--chat-template-kwargs' '{"enable_thinking":false}')
EOF

  run_rebuild vllm
  local script="$AI_DIR/conf/backends/vllm/serve.sh"
  grep -qF -- "--tensor-parallel-size 2" "$script"
  grep -qF -- "--gpu-memory-utilization 0.80" "$script"
  grep -qF -- "--max-model-len 4096" "$script"
  grep -qF -- "--max-num-seqs 32" "$script"
  grep -qF -- "--max-num-batched-tokens 1024" "$script"
  grep -qF -- "--dtype bfloat16" "$script"
  grep -qF -- "--kv-cache-dtype fp8" "$script"
  grep -qF -- "--served-model-name custom-name" "$script"
  grep -qF -- "--enable-prefix-caching" "$script"
  grep -qF -- "--chat-template-kwargs" "$script"
  grep -qF -- "enable_thinking" "$script"
}

@test "invalid settings leave the existing launcher unchanged" {
  run_rebuild vllm
  cp "$AI_DIR/conf/backends/vllm/serve.sh" "$BATS_TEST_TMPDIR/before.sh"

  printf 'TENSOR_PARALLEL_SIZE=0\n' > "$AI_DIR/conf/backends/vllm/models.d/model-a.conf"
  run bash "$REPO_DIR/rebuild-config.sh" --backend vllm \
    "$AI_DIR/conf/backends/vllm/serve.sh" \
    "$AI_DIR/conf/backends/vllm/serve.env"
  [ "$status" -ne 0 ]
  cmp "$AI_DIR/conf/backends/vllm/serve.sh" "$BATS_TEST_TMPDIR/before.sh"
}

@test "API keys are rendered into the private launcher and never into serve.env" {
  local secret id created content
  secret="$(api_key_generate_secret)"
  id="$(api_key_generate_id "$secret")"
  created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  content="$(printf 'version\t1\n%s\t%s\t%s\tactive\t%s' "$id" test "$created" "$secret")"
  printf '%s\n' "$content" > "$AI_DIR/conf/backends/vllm/api-keys.tsv"
  chmod 600 "$AI_DIR/conf/backends/vllm/api-keys.tsv"

  run_rebuild vllm
  grep -qF "export VLLM_API_KEY=$secret" "$AI_DIR/conf/backends/vllm/serve.sh"
  ! grep -qF "$secret" "$AI_DIR/conf/backends/vllm/serve.env"
  grep -qF "LOCALVLLM_API_KEY_ACTIVE=1" "$AI_DIR/conf/backends/vllm/serve.env"
}

@test "multiple active keys are rejected" {
  local secret1 secret2 id1 id2 created content
  secret1="$(api_key_generate_secret)"
  secret2="$(api_key_generate_secret)"
  id1="$(api_key_generate_id "$secret1")"
  id2="$(api_key_generate_id "$secret2")"
  created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  content="$(printf 'version\t1\n%s\tone\t%s\tactive\t%s\n%s\ttwo\t%s\tactive\t%s' \
    "$id1" "$created" "$secret1" "$id2" "$created" "$secret2")"
  printf '%s\n' "$content" > "$AI_DIR/conf/backends/vllm/api-keys.tsv"

  run bash "$REPO_DIR/rebuild-config.sh" --backend vllm \
    "$AI_DIR/conf/backends/vllm/serve.sh" \
    "$AI_DIR/conf/backends/vllm/serve.env"
  [ "$status" -ne 0 ]
  [[ "$output" == *"vLLM supports one"* ]]
}

@test "omni backend always passes --omni and uses its own paths" {
  run_rebuild omni
  local script="$AI_DIR/conf/backends/omni/serve.sh"
  grep -qF "venv/omni/bin/vllm serve" "$script"
  grep -qF "models/omni/omni-model" "$script"
  grep -qF -- "--omni" "$script"
  grep -qF -- "--port 8091" "$script"
  grep -qF "LOCALVLLM_OMNI=1" "$AI_DIR/conf/backends/omni/serve.env"
}

@test "sleep mode enables vLLM server dev mode" {
  printf 'ENABLE_SLEEP=1\n' > "$AI_DIR/conf/backends/vllm/models.d/model-a.conf"
  run_rebuild vllm
  local script="$AI_DIR/conf/backends/vllm/serve.sh"
  grep -qF -- "--enable-sleep-mode" "$script"
  grep -qF "export VLLM_SERVER_DEV_MODE=1" "$script"
}

@test "embedding and reranking model types set the right task" {
  printf 'MODEL_TYPE=embedding\n' > "$AI_DIR/conf/backends/vllm/models.d/model-a.conf"
  run_rebuild vllm
  grep -qF -- "--runner pooling" "$AI_DIR/conf/backends/vllm/serve.sh"

  printf 'MODEL_TYPE=reranking\n' > "$AI_DIR/conf/backends/vllm/models.d/model-a.conf"
  run_rebuild vllm
  grep -qF -- "--runner pooling" "$AI_DIR/conf/backends/vllm/serve.sh"
}

@test "two backends keep separate ports and launchers" {
  run_rebuild vllm
  run_rebuild omni
  [ -f "$AI_DIR/conf/backends/vllm/serve.sh" ]
  [ -f "$AI_DIR/conf/backends/omni/serve.sh" ]
  grep -qF -- "--port 8010" "$AI_DIR/conf/backends/vllm/serve.sh"
  grep -qF -- "--port 8091" "$AI_DIR/conf/backends/omni/serve.sh"
  ! grep -qF -- "--omni" "$AI_DIR/conf/backends/vllm/serve.sh"
  grep -qF -- "--omni" "$AI_DIR/conf/backends/omni/serve.sh"
}

@test "legacy swap settings do not emit removed vllm flags" {
  printf 'SWAP_SPACE=4\n' > "$AI_DIR/conf/backends/vllm/models.d/model-a.conf"
  run_rebuild vllm
  [[ "$output" == *"SWAP_SPACE is obsolete and ignored"* ]]
  ! grep -qF -- '--swap-space' "$AI_DIR/conf/backends/vllm/serve.sh"
}

@test "server model settings preserve high context batching and parallelism" {
  cat > "$AI_DIR/conf/backends/vllm/models.d/model-a.conf" <<'EOF'
TENSOR_PARALLEL_SIZE=4
MAX_MODEL_LEN=131072
MAX_NUM_SEQS=512
MAX_NUM_BATCHED_TOKENS=32768
CUDA_VISIBLE_DEVICES=0,1,2,3,4,5,6,7
EXTRA_ARGS=(--pipeline-parallel-size 2)
EOF
  run_rebuild vllm
  local script="$AI_DIR/conf/backends/vllm/serve.sh"
  grep -qF -- '--tensor-parallel-size 4' "$script"
  grep -qF -- '--max-model-len 131072' "$script"
  grep -qF -- '--max-num-seqs 512' "$script"
  grep -qF -- '--max-num-batched-tokens 32768' "$script"
  grep -qF -- '--pipeline-parallel-size 2' "$script"
  grep -qF 'export CUDA_VISIBLE_DEVICES=0\,1\,2\,3\,4\,5\,6\,7' "$script"
}

@test "native Omni deployment keeps stage configs without manager tuning defaults" {
  cat > "$AI_DIR/conf/backends/omni/models.d/omni-model.conf" <<'CONF'
ENGINE_DEFAULTS=1
EXTRA_ARGS=(--deploy-config '/srv/models/omni deploy.yaml' --strategy-config /srv/models/strategy.yaml)
CONF
  run_rebuild omni
  local script="$AI_DIR/conf/backends/omni/serve.sh"
  grep -qF -- '--omni' "$script"
  grep -qF -- '--host 127.0.0.1 --port 8091' "$script"
  grep -qF -- '--deploy-config /srv/models/omni\ deploy.yaml' "$script"
  grep -qF -- '--strategy-config /srv/models/strategy.yaml' "$script"
  ! grep -qE -- '--(tensor-parallel-size|max-model-len|max-num-seqs|gpu-memory-utilization|dtype)' "$script"
}
@test "native text tuning preserves custom distributed and expert options" {
  cat > "$AI_DIR/conf/backends/vllm/models.d/model-a.conf" <<'CONF'
ENGINE_DEFAULTS=1
EXTRA_ARGS=(--tensor-parallel-size 8 --data-parallel-size 2 --enable-expert-parallel --max-model-len 131072)
CONF
  run_rebuild vllm
  local script="$AI_DIR/conf/backends/vllm/serve.sh"
  grep -qF -- '--tensor-parallel-size 8 --data-parallel-size 2 --enable-expert-parallel --max-model-len 131072' "$script"
  ! grep -qF -- '--tensor-parallel-size 1 ' "$script"
}

@test "unprefixed environment variables do not override launcher settings" {
  export DTYPE=bfloat16 TASK=embed MODEL_TYPE=embedding OMNI=1
  run_rebuild vllm
  local script="$AI_DIR/conf/backends/vllm/serve.sh"
  grep -qF -- '--dtype auto' "$script"
  ! grep -qF -- '--runner' "$script"
  ! grep -qF -- '--omni' "$script"
}

@test "an explicitly empty max model length leaves the vLLM default" {
  export VLLM_MAX_MODEL_LEN=""
  run_rebuild vllm
  local script="$AI_DIR/conf/backends/vllm/serve.sh"
  ! grep -qF -- '--max-model-len' "$script"
}

@test "dry-run validates configuration without replacing the launcher" {
  run_rebuild vllm
  local script="$AI_DIR/conf/backends/vllm/serve.sh"
  cp "$script" "$BATS_TEST_TMPDIR/before.sh"
  run bash "$REPO_DIR/rebuild-config.sh" --backend vllm --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Configuration is valid"* ]]
  cmp "$script" "$BATS_TEST_TMPDIR/before.sh"
}

@test "config check all skips a backend with nothing installed or registered" {
  run_rebuild vllm
  rm -rf "$AI_DIR/models/omni/omni-model"
  run env LOCALVLLM_DIR="$AI_DIR" bash "$REPO_DIR/localvllm" config check all
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipped:"* ]]
  [[ "$output" == *"Configuration is valid: vllm"* ]]
}

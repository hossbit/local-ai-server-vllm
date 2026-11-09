#!/usr/bin/env bats
setup() {
  REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  . "$REPO_DIR/lib/common.sh"
  unset CUDA_VISIBLE_DEVICES LOCALVLLM_CUDA_VISIBLE_DEVICES
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  cat > "$BATS_TEST_TMPDIR/bin/nvidia-smi" <<'STUB'
#!/usr/bin/env bash
field="${1#--query-gpu=}"
case "${3:-}" in
  --id=2,3|--id=GPU-selected)
    case "$field" in
      index) printf '2\n3\n' ;;
      memory.total) printf '81920\n81920\n' ;;
      memory.free) printf '61440\n40960\n' ;;
    esac ;;
  --id=bad) exit 1 ;;
  *)
    case "$field" in
      index) printf '0\n1\n2\n3\n4\n5\n6\n7\n' ;;
      memory.total) printf 'N/A\n49152\n81920\n81920\n' ;;
      memory.free) printf 'N/A\n0\n61440\n40960\n' ;;
    esac ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/nvidia-smi"
}
@test "GPU metrics honor the selected backend devices" {
  export LOCALVLLM_CUDA_VISIBLE_DEVICES=2,3
  [ "$(gpu_count)" = 2 ]
  [ "$(gpu_vram_total_min_bytes)" = 85899345920 ]
  [ "$(gpu_vram_free_min_bytes)" = 42949672960 ]
}
@test "CUDA device mask takes precedence over manager mask" {
  export LOCALVLLM_CUDA_VISIBLE_DEVICES=bad CUDA_VISIBLE_DEVICES=GPU-selected
  [ "$(gpu_count)" = 2 ]
  [ "$(gpu_vram_total_min_bytes)" = 85899345920 ]
}
@test "disabled invalid and MIG selections never report all host GPUs" {
  local mask
  for mask in '' -1 bad MIG-example; do
    export CUDA_VISIBLE_DEVICES="$mask"
    [ "$(gpu_count)" = 0 ]
    [ "$(gpu_vram_total_min_bytes)" = 0 ]
  done
}
@test "unavailable NVIDIA values are skipped and zero free memory is retained" {
  [ "$(gpu_count)" = 8 ]
  [ "$(gpu_vram_total_min_bytes)" = 51539607552 ]
  [ "$(gpu_vram_free_min_bytes)" = 0 ]
}
@test "RAM reporting uses an integer suitable for shell arithmetic" {
  run system_ram_bytes
  [ "$status" = 0 ]
  [[ "$output" =~ ^[0-9]+$ ]]
  [ "$output" -gt 0 ]
}
@test "ROCm memory remains available when NVIDIA tooling has no devices" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "$BATS_TEST_TMPDIR/bin/nvidia-smi"
  cat > "$BATS_TEST_TMPDIR/bin/rocm-smi" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  --showmeminfo) echo 'GPU[0] : VRAM Total Memory (B): 206158430208' ;;
  --showid) echo 'GPU[0] : Device ID: example' ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/rocm-smi"
  [ "$(gpu_count)" = 1 ]
  [ "$(gpu_vram_total_min_bytes)" = 206158430208 ]
}

@test "suggestions budget memory only on GPUs assigned to the model" {
  . "$REPO_DIR/lib/cli/suggest.sh"
  export LOCALVLLM_SUGGEST_VRAM_BYTES=25769803776
  export LOCALVLLM_SUGGEST_VRAM_FREE_BYTES=25769803776
  export LOCALVLLM_SUGGEST_GPU_COUNT=8
  OVERRIDES_DIR="$BATS_TEST_TMPDIR/overrides"
  localvllm_model_size_bytes() { echo 21474836480; }
  run suggest_for_model model-a org/model hf "$BATS_TEST_TMPDIR/model"
  [ "$status" = 0 ]
  [[ "$output" == *"suggested TENSOR_PARALLEL_SIZE: 1"* ]]
  [[ "$output" == *"suggested MAX_MODEL_LEN: 4096"* ]]
}

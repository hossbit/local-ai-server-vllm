#!/usr/bin/env bats
setup() {
  REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  . "$REPO_DIR/lib/common.sh"
  . "$REPO_DIR/lib/install.sh"
  AI_DIR="$BATS_TEST_TMPDIR/ai"
  LOCALVLLM_PYTHON=python3
  mkdir -p "$BATS_TEST_TMPDIR/bin" "$AI_DIR"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "Python 3.14 is rejected for Omni while 3.12 is accepted" {
  cat > "$BATS_TEST_TMPDIR/bin/py314" <<'SH'
#!/usr/bin/env bash
printf '3.14.0\n'
SH
  cat > "$BATS_TEST_TMPDIR/bin/py312" <<'SH'
#!/usr/bin/env bash
printf '3.12.0\n'
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/"*
  ! localvllm_omni_python_ok py314
  localvllm_omni_python_ok py312
}

@test "explicit incompatible Python is rejected with a useful error" {
  cat > "$BATS_TEST_TMPDIR/bin/py314" <<'SH'
#!/usr/bin/env bash
printf '3.14.0\n'
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/py314"
  LOCALVLLM_PYTHON=py314
  run localvllm_find_compatible_python
  [ "$status" -ne 0 ]
  [[ "$output" == *'3.11'* && "$output" == *'3.13'* ]]
}

@test "latest Omni installs a matching vLLM release line" {
  mkdir -p "$AI_DIR/bin"
  cat > "$AI_DIR/bin/python" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@"
SH
  chmod +x "$AI_DIR/bin/python"
  vllm_omni_latest_version() { echo 0.32.0; }
  run vllm_pip_install_both "$AI_DIR" latest latest '' '' ''
  [ "$status" -eq 0 ]
  [[ "$output" == *'vllm>=0.32,<0.33'* ]]
  [[ "$output" == *'vllm-omni==0.32.0'* ]]
}

@test "an explicit vLLM pin is honored for Omni" {
  mkdir -p "$AI_DIR/bin"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@"\n' > "$AI_DIR/bin/python"
  chmod +x "$AI_DIR/bin/python"
  run vllm_pip_install_both "$AI_DIR" '0.30.0+rocm723' 0.30.0 '' '' ''
  [ "$status" -eq 0 ]
  [[ "$output" == *'vllm==0.30.0+rocm723'* ]]
  [[ "$output" == *'vllm-omni==0.30.0'* ]]
}

@test "a pinned Omni version selects its matching vLLM minor line" {
  mkdir -p "$AI_DIR/bin"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@"\n' > "$AI_DIR/bin/python"
  chmod +x "$AI_DIR/bin/python"
  run vllm_pip_install_both "$AI_DIR" latest 0.30.1 '' '' ''
  [ "$status" -eq 0 ]
  [[ "$output" == *'vllm>=0.30,<0.31'* ]]
  [[ "$output" == *'vllm-omni==0.30.1'* ]]
}

@test "version uses package metadata instead of a warning timestamp" {
  mkdir -p "$AI_DIR/bin"
  cat > "$AI_DIR/bin/python" <<'SH'
#!/usr/bin/env bash
echo 0.33.0
SH
  cat > "$AI_DIR/bin/vllm" <<'SH'
#!/usr/bin/env bash
echo 'W1102 20:59:05.444000 warning' >&2
echo 0.33.0
SH
  chmod +x "$AI_DIR/bin/"*
  run vllm_installed_version "$AI_DIR"
  [ "$status" -eq 0 ]
  [ "$output" = 0.33.0 ]
}

@test "an explicitly selected Python 3.14 remains available for plain vLLM" {
  cat > "$BATS_TEST_TMPDIR/bin/py314" <<'SH'
#!/usr/bin/env bash
printf '3.14.0\n'
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/py314"
  LOCALVLLM_PYTHON=py314
  run localvllm_find_compatible_python vllm
  [ "$status" -eq 0 ]
  [[ "$output" == */py314 ]]
}

@test "automatically obtains isolated Python when only 3.14 is available" {
  for name in python3.12 python3.13 python3.11 python3; do
    cat > "$BATS_TEST_TMPDIR/bin/$name" <<'SH'
#!/usr/bin/env bash
echo 3.14.0
SH
  done
  cat > "$BATS_TEST_TMPDIR/bin/uv" <<'SH'
#!/usr/bin/env bash
if [ "${2:-}" = install ]; then
  mkdir -p "$UV_PYTHON_INSTALL_DIR/bin"
  printf '#!/usr/bin/env bash\necho 3.12.8\n' > "$UV_PYTHON_INSTALL_DIR/bin/python3.12"
  chmod +x "$UV_PYTHON_INSTALL_DIR/bin/python3.12"
elif [ "${2:-}" = find ]; then
  printf '%s\n' "$UV_PYTHON_INSTALL_DIR/bin/python3.12"
fi
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/"*
  run localvllm_find_compatible_python omni
  [ "$status" -eq 0 ]
  [[ "$output" == *"$AI_DIR/venv/.localvllm-python/bin/python3.12"* ]]
  [ -x "$AI_DIR/venv/.localvllm-python/bin/python3.12" ]
}

@test "ROCm requires Python 3.12 for default and explicit backend interpreters" {
  VLLM_TARGET_DEVICE=rocm
  python_version() { case "$1" in *312*) echo 3.12.0 ;; *) echo 3.13.0 ;; esac; }
  localvllm_omni_python_ok py312
  ! localvllm_omni_python_ok py313
  localvllm_python_can_create_venv() { return 0; }
  LOCALVLLM_PYTHON=py313
  run localvllm_find_compatible_python vllm
  [ "$status" != 0 ]
  [[ "$output" == *'Python 3.12'* ]]
  run localvllm_find_compatible_python omni
  [ "$status" != 0 ]
}

@test "requested ROCm rejects a CUDA wheel after install without needing GPU hardware" {
  VLLM_TARGET_DEVICE=rocm
  mkdir -p "$AI_DIR/bin"
  cat > "$AI_DIR/bin/python" <<'SH'
#!/usr/bin/env bash
case "$*" in *torch.version.hip*) exit 1 ;; *) echo 0.32.0 ;; esac
SH
  chmod +x "$AI_DIR/bin/python"
  run vllm_verify_install "$AI_DIR"
  [ "$status" != 0 ]
  [[ "$output" == *'not a working ROCm build'* ]]
}

@test "invalid target fails rather than silently choosing a CUDA wheel" {
  VLLM_TARGET_DEVICE=typo
  run vllm_detect_target_device
  [ "$status" != 0 ]
}

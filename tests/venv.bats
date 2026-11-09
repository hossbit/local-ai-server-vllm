#!/usr/bin/env bats

setup() {
  REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  . "$REPO_DIR/lib/install.sh"
  VENV="$BATS_TEST_TMPDIR/venv"
  python3 -m venv --without-pip "$VENV"
}

@test "staged pip uses the staging interpreter and leaves the original untouched" {
  local stage
  stage="$(vllm_venv_stage_update "$VENV")"
  mkdir -p "$BATS_TEST_TMPDIR/modules/pip"
  : > "$BATS_TEST_TMPDIR/modules/pip/__init__.py"
  cat > "$BATS_TEST_TMPDIR/modules/pip/__main__.py" <<'PY'
import pathlib
import sys
assert sys.argv[1:] == ['install', '--upgrade', 'vllm==0.0-new']
pathlib.Path(sys.prefix, 'updated').touch()
PY
  # A copied console script still targets the original interpreter. It must
  # never be used for a staged install.
  printf '#!/usr/bin/env bash\nexit 77\n' > "$stage/bin/pip"
  chmod +x "$stage/bin/pip"
  run env PYTHONPATH="$BATS_TEST_TMPDIR/modules" bash -c \
    'source "$1/lib/install.sh"; vllm_pip_install "$2" 0.0-new' _ "$REPO_DIR" "$stage"
  [ "$status" -eq 0 ]
  [ -f "$stage/updated" ]
  [ ! -e "$VENV/updated" ]
}

@test "promoted entry points use the final interpreter and rollback remains usable" {
  local stage old
  stage="$(vllm_venv_stage_update "$VENV")"
  printf '#!%s/bin/python\nimport sys\nprint(sys.prefix)\n' "$stage" > "$stage/bin/vllm"
  chmod +x "$stage/bin/vllm"
  old="$(vllm_venv_commit_update "$VENV" "$stage")"
  run "$VENV/bin/vllm"
  [ "$status" -eq 0 ]
  [ "$output" = "$VENV" ]
  [ ! -e "$stage" ]
  vllm_venv_rollback_update "$VENV" "$old"
  run "$VENV/bin/python" -c 'import sys; print(sys.prefix)'
  [ "$status" -eq 0 ]
  [ "$output" = "$VENV" ]
  [ ! -e "$VENV/bin/vllm" ]
}

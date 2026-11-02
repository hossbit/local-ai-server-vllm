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
  # shellcheck source=../lib/cli/key.sh
  . "$REPO_DIR/lib/cli/key.sh"

  localvllm_capture_global_runtime
  localvllm_use_backend vllm
  mkdir -p "$CONF_DIR"
  printf '8000\n' > "$PORT_FILE"

  # vLLM key management does not need the real launcher in these tests.
  apply_config_change() { return 0; }
}

active_id() {
  awk -F'\t' '$4 == "active" {print $1; exit}' "$CONF_DIR/api-keys.tsv"
}

@test "key create stores exactly one active key and prints the secret once" {
  run key_create_cmd laptop
  [ "$status" -eq 0 ]
  [[ "$output" == *"Key created:"* ]]
  [[ "$output" == *"sk-localvllm-"* ]]
  [ "$(api_key_active_count "$CONF_DIR/api-keys.tsv")" = "1" ]
  [ "$(basename "$CONF_DIR")" = "vllm" ]
}

@test "a second active key is refused" {
  key_create_cmd first >/dev/null
  run key_create_cmd second
  [ "$status" -ne 0 ]
  [[ "$output" == *"one active API key"* ]]
  [ "$(api_key_active_count "$CONF_DIR/api-keys.tsv")" = "1" ]
}

@test "key rotate revokes the old id and creates a new active key" {
  key_create_cmd rotate-me >/dev/null
  local old_id old_secret new_id new_secret
  old_id="$(active_id)"
  old_secret="$(api_key_active_secrets "$CONF_DIR/api-keys.tsv")"

  run key_rotate_cmd "$old_id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Revoked previous key:"* ]]
  [ "$(api_key_active_count "$CONF_DIR/api-keys.tsv")" = "1" ]

  new_id="$(active_id)"
  new_secret="$(api_key_active_secrets "$CONF_DIR/api-keys.tsv")"
  [ "$new_id" != "$old_id" ]
  [ "$new_secret" != "$old_secret" ]
  awk -F'\t' -v id="$old_id" '$1 == id && $4 == "revoked" {found=1} END {exit found ? 0 : 1}' "$CONF_DIR/api-keys.tsv"
}

@test "key revoke leaves the backend unauthenticated" {
  key_create_cmd revoke-me >/dev/null
  local id
  id="$(active_id)"

  run key_revoke_cmd "$id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Revoked:"* ]]
  [ "$(api_key_active_count "$CONF_DIR/api-keys.tsv")" = "0" ]
}

@test "key list never prints a full secret" {
  key_create_cmd masked >/dev/null
  local secret
  secret="$(api_key_active_secrets "$CONF_DIR/api-keys.tsv")"

  run key_list_cmd
  [ "$status" -eq 0 ]
  [[ "$output" == *"masked"* ]]
  [[ "$output" != *"$secret"* ]]
}

@test "the omni backend keeps its keys separate from vllm" {
  key_create_cmd vllm-key >/dev/null
  local vllm_secret
  vllm_secret="$(api_key_active_secrets "$CONF_DIR/api-keys.tsv")"

  localvllm_use_backend omni
  mkdir -p "$CONF_DIR"
  key_create_cmd omni-key >/dev/null
  local omni_secret
  omni_secret="$(api_key_active_secrets "$CONF_DIR/api-keys.tsv")"

  [ "$omni_secret" != "$vllm_secret" ]
  [ "$(api_key_active_count "$CONF_DIR/api-keys.tsv")" = "1" ]
}

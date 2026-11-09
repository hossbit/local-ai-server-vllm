# shellcheck shell=bash disable=SC2154

key_usage() {
  cat <<EOF
Usage: localvllm key COMMAND [ARGS]

Commands:
  create [NAME]   Create a new API key (name defaults to "default")
  list            List keys; secrets are masked
  revoke KEY_ID   Revoke a key
  rotate KEY_ID   Create a replacement for KEY_ID, then revoke it
  help            Show this help

Keys work in direct/manual and llama-swap modes for both vLLM and Omni.
Changing a key regenerates the selected backend's launcher and may restart it.
vLLM supports one active API key per server. 'create' refuses to add a
second active key; use 'rotate' to replace the current one, or revoke it
first. A key's full secret is printed once and cannot be recovered.

With no active keys, the API stays unauthenticated (today's default).
Creating the first key turns on Bearer-token authentication for vLLM's
OpenAI-compatible endpoints under /v1, /v2, /inference, and /cohere.
vLLM's /health, /docs, and development endpoints are not protected by the
API key; keep the listener on 127.0.0.1 or put a reverse proxy in front.
EOF
}

key_cmd() {
  local sub="${1:-help}"

  [ "$#" -eq 0 ] || shift

  case "$sub" in
    create) key_create_cmd "$@" ;;
    list) key_list_cmd "$@" ;;
    revoke) key_revoke_cmd "$@" ;;
    rotate) key_rotate_cmd "$@" ;;
    help|-h|--help) key_usage ;;
    *)
      key_usage >&2
      return 2
      ;;
  esac
}

api_key_registry_content_from_rows() {
  local rows="$1"

  if [ -n "$rows" ]; then
    printf 'version\t1\n%s' "$rows"
  else
    printf 'version\t1'
  fi
}

key_activate() {
  local rebuild="$BIN_DIR/rebuild-config.sh"

  [ -x "$rebuild" ] || rebuild="$SCRIPT_DIR/rebuild-config.sh"
  if [ ! -x "$rebuild" ]; then
    echo "Error: missing helper: $BIN_DIR/rebuild-config.sh" >&2
    return 1
  fi

  apply_config_change
}

# Commit the registry only if its launcher configuration can be activated.
key_apply_registry() {
  local registry="$1" content="$2" backup existed=0
  backup="$(mktemp "$CONF_DIR/.key-rollback.XXXXXX")" || return 1
  chmod 600 "$backup"
  if [ -f "$registry" ]; then
    existed=1
    cp -p "$registry" "$backup" || { rm -f "$backup"; return 1; }
  fi
  if ! api_key_registry_write_atomic "$registry" "$content"; then
    rm -f "$backup"
    echo 'Error: failed to save key registry.' >&2
    return 1
  fi
  echo 'Applying key configuration (a running backend may restart)...'
  if ! key_activate; then
    if [ "$existed" = 1 ]; then
      mv -f "$backup" "$registry" || { echo "Error: key rollback failed; backup: $backup" >&2; return 1; }
    else
      rm -f "$registry" "$backup"
    fi
    echo 'Error: key change was not applied; previous key registry restored.' >&2
    return 1
  fi
  rm -f "$backup"
}

key_print_new_secret() {
  local name="$1"
  local id="$2"
  local created="$3"
  local secret="$4"
  local port

  port="$([ -f "$PORT_FILE" ] && cat "$PORT_FILE" || printf '%s' "$LOCALVLLM_DEFAULT_PORT")"

  echo
  echo "$(c 32 "Key created:") $name"
  echo "  id:      $(c 2 "$id")"
  echo "  created: $(c 2 "$created")"
  echo
  printf '%s\n' "$(c 33 "Save this key now - it will not be shown again:")"
  echo
  echo "    $(c 1 "$secret")"
  echo
  echo "Use it as a Bearer token:"
  echo "  curl http://$(localvllm_url_host "$LOCALVLLM_LISTEN_HOST"):${port}/v1/models \\"
  echo "    -H \"Authorization: Bearer $secret\""
  echo
  echo "Run 'localvllm key list' to see all keys (masked)."
}

key_create_cmd() {
  local name="${1:-default}"
  local registry existing_rows secret id created content attempt=0 active_count active_id

  [ "$#" -le 1 ] || fail "usage: localvllm key create [NAME]"
  api_key_validate_name "$name" ||
    fail "invalid key name: '$name' (use 1-64 letters, digits, spaces, '.', '_', '-')"

  registry="$(api_key_registry_path)"
  mkdir -p "$CONF_DIR"
  api_key_registry_validate "$registry" || fail "key registry is malformed: $registry"
  existing_rows="$(api_key_registry_rows "$registry")"

  active_count="$(api_key_active_count "$registry")"
  if [ "$active_count" -gt 0 ]; then
    active_id="$(api_key_registry_rows "$registry" | awk -F'\t' '$4 == "active" {print $1; exit}')"
    fail "vLLM supports one active API key; '$active_id' is already active. Use 'localvllm key rotate $active_id' or revoke it first."
  fi

  while :; do
    secret="$(api_key_generate_secret)" ||
      fail "no cryptographic random source available (need openssl or /dev/urandom)"
    id="$(api_key_generate_id "$secret")"
    grep -q "^${id}$(printf '\t')" <<<"$existing_rows" 2>/dev/null || break
    attempt=$((attempt + 1))
    [ "$attempt" -lt 5 ] || fail "could not generate a unique key id after $attempt attempts"
  done

  created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local new_row rows
  new_row="$(printf '%s\t%s\t%s\tactive\t%s' "$id" "$name" "$created" "$secret")"
  if [ -n "$existing_rows" ]; then
    rows="$existing_rows"$'\n'"$new_row"
  else
    rows="$new_row"
  fi

  content="$(api_key_registry_content_from_rows "$rows")"
  key_apply_registry "$registry" "$content" || return 1

  key_print_new_secret "$name" "$id" "$created" "$secret"
}

key_list_cmd() {
  local registry id name created status secret masked status_display i active_count=0
  local -a col_id=() col_name=() col_created=() col_status=() col_masked=()
  local w_id=2 w_name=4 w_created=7 w_status=6

  [ "$#" -eq 0 ] || fail "usage: localvllm key list"

  registry="$(api_key_registry_path)"
  if [ ! -f "$registry" ]; then
    echo "No API keys configured. The API is unauthenticated."
    return 0
  fi
  api_key_registry_validate "$registry" || fail "key registry is malformed: $registry"

  while IFS=$'\t' read -r id name created status secret; do
    [ -n "$id" ] || continue
    if [ "$status" = active ]; then
      masked="$(api_key_mask "$secret")"
      active_count=$((active_count + 1))
    else
      masked="-"
    fi

    col_id+=("$id")
    col_name+=("$name")
    col_created+=("$created")
    col_status+=("$status")
    col_masked+=("$masked")

    [ "${#id}" -le "$w_id" ] || w_id="${#id}"
    [ "${#name}" -le "$w_name" ] || w_name="${#name}"
    [ "${#created}" -le "$w_created" ] || w_created="${#created}"
    [ "${#status}" -le "$w_status" ] || w_status="${#status}"
  done < <(api_key_registry_rows "$registry")

  if [ "${#col_id[@]}" -eq 0 ]; then
    echo "No API keys configured. The API is unauthenticated."
    return 0
  fi

  printf "%-${w_id}s  %-${w_name}s  %-${w_created}s  %-${w_status}s  %s\n" \
    "ID" "NAME" "CREATED" "STATUS" "KEY"

  for ((i = 0; i < ${#col_id[@]}; i++)); do
    status_display="$(printf "%-${w_status}s" "${col_status[i]}")"
    if [ "${col_status[i]}" = active ]; then
      status_display="$(c 32 "$status_display")"
    else
      status_display="$(c 2 "$status_display")"
    fi
    printf "%-${w_id}s  %-${w_name}s  %-${w_created}s  %s  %s\n" \
      "${col_id[i]}" "${col_name[i]}" "${col_created[i]}" "$status_display" "${col_masked[i]}"
  done

  echo
  if [ "$active_count" -gt 1 ]; then
    echo "Error: $active_count active keys found; vLLM supports one. Revoke all but one."
  elif [ "$active_count" -eq 1 ]; then
    echo "1 active key. vLLM requires a valid Bearer token on its OpenAI-compatible endpoints."
  else
    echo "No active keys. The API is unauthenticated."
  fi
}

key_revoke_cmd() {
  local target="${1:-}"
  local registry id name created status secret found=0 revoked_name="" row rows=""

  [ -n "$target" ] || fail "usage: localvllm key revoke KEY_ID"
  [ "$#" -eq 1 ] || fail "usage: localvllm key revoke KEY_ID"

  registry="$(api_key_registry_path)"
  [ -f "$registry" ] || fail "no such key: $target"
  api_key_registry_validate "$registry" || fail "key registry is malformed: $registry"

  while IFS=$'\t' read -r id name created status secret; do
    [ -n "$id" ] || continue
    if [ "$id" = "$target" ]; then
      found=1
      [ "$status" != revoked ] || fail "key already revoked: $target"
      if [ "$status" = active ] &&
        [ "${LOCALVLLM_REQUIRE_API_KEY:-0}" = "1" ] &&
        [ "$(api_key_active_count "$registry")" -eq 1 ]; then
        fail "cannot revoke the last active key while LOCALVLLM_REQUIRE_API_KEY=1; create a replacement first"
      fi
      revoked_name="$name"
      row="$(printf '%s\t%s\t%s\trevoked\t-' "$id" "$name" "$created")"
    else
      row="$(printf '%s\t%s\t%s\t%s\t%s' "$id" "$name" "$created" "$status" "$secret")"
    fi
    rows="$rows$row"$'\n'
  done < <(api_key_registry_rows "$registry")
  rows="${rows%$'\n'}"

  [ "$found" -eq 1 ] || fail "no such key: $target"

  local content
  content="$(api_key_registry_content_from_rows "$rows")"
  key_apply_registry "$registry" "$content" || return 1

  echo "$(c 31 "Revoked:") $target ($revoked_name)"
}

key_rotate_cmd() {
  local target="${1:-}"
  local registry existing_rows id name created status secret found=0 old_name="" row rows=""
  local new_secret new_id new_created attempt=0 content

  [ -n "$target" ] || fail "usage: localvllm key rotate KEY_ID"
  [ "$#" -eq 1 ] || fail "usage: localvllm key rotate KEY_ID"

  registry="$(api_key_registry_path)"
  [ -f "$registry" ] || fail "no such key: $target"
  api_key_registry_validate "$registry" || fail "key registry is malformed: $registry"
  existing_rows="$(api_key_registry_rows "$registry")"

  local other_active
  other_active="$(awk -F'\t' -v id="$target" '$4 == "active" && $1 != id {print $1; exit}' <<<"$existing_rows")"
  [ -z "$other_active" ] ||
    fail "another active key ($other_active) exists; vLLM supports one active key"

  while IFS=$'\t' read -r id name created status secret; do
    [ -n "$id" ] || continue
    if [ "$id" = "$target" ]; then
      found=1
      [ "$status" = active ] || fail "cannot rotate a revoked key: $target"
      old_name="$name"
      row="$(printf '%s\t%s\t%s\trevoked\t-' "$id" "$name" "$created")"
    else
      row="$(printf '%s\t%s\t%s\t%s\t%s' "$id" "$name" "$created" "$status" "$secret")"
    fi
    rows="$rows$row"$'\n'
  done <<<"$existing_rows"

  [ "$found" -eq 1 ] || fail "no such key: $target"

  while :; do
    new_secret="$(api_key_generate_secret)" ||
      fail "no cryptographic random source available (need openssl or /dev/urandom)"
    new_id="$(api_key_generate_id "$new_secret")"
    grep -q "^${new_id}$(printf '\t')" <<<"$existing_rows" 2>/dev/null || break
    attempt=$((attempt + 1))
    [ "$attempt" -lt 5 ] || fail "could not generate a unique key id after $attempt attempts"
  done
  new_created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  rows="$rows$(printf '%s\t%s\t%s\tactive\t%s' "$new_id" "$old_name" "$new_created" "$new_secret")"

  content="$(api_key_registry_content_from_rows "$rows")"
  key_apply_registry "$registry" "$content" || return 1

  echo "$(c 2 "Revoked previous key:") $target"
  key_print_new_secret "$old_name" "$new_id" "$new_created" "$new_secret"
}

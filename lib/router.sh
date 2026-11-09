#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154,SC1091
source_localvllm_lib install.sh

localvllm_swap_bin() {
  if [ -n "${LOCALVLLM_LLAMA_SWAP_BIN:-}" ]; then
    [ -x "$LOCALVLLM_LLAMA_SWAP_BIN" ] || return 1
    printf '%s\n' "$LOCALVLLM_LLAMA_SWAP_BIN"
  elif [ -x "$AI_DIR/$LOCALVLLM_BIN_SUBDIR/llama-swap" ]; then
    printf '%s\n' "$AI_DIR/$LOCALVLLM_BIN_SUBDIR/llama-swap"
  else
    command -v llama-swap
  fi
}

localvllm_swap_version() {
  local binary="${1:-}" output
  [ -n "$binary" ] || binary="$(localvllm_swap_bin)" || return 1
  output="$("$binary" -version 2>/dev/null)" || return 1
  printf '%s\n' "$output" | sed -nE 's/^version: (v[0-9]+).*$/\1/p' | head -n1
}

localvllm_swap_target_version() {
  local version="${LOCALVLLM_LLAMA_SWAP_VERSION:-latest}"
  if [ "$version" = latest ]; then
    version="$(curl --connect-timeout 10 --max-time 30 -fsSL https://api.github.com/repos/mostlygeek/llama-swap/releases/latest | jq -er .tag_name)" || return 1
  fi
  [[ "$version" =~ ^v[0-9]+$ ]] || return 1
  printf '%s\n' "$version"
}

# Download only to a staging path. Never overwrite a live executable.
localvllm_download_swap() {
  local destination="$1" version="$2" arch tmp archive digest
  case "$(uname -m)" in x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) echo 'Unsupported llama-swap binary architecture.' >&2; return 1 ;; esac
  [[ "$version" =~ ^v[0-9]+$ ]] || return 1
  archive="llama-swap_${version#v}_linux_${arch}.tar.gz"
  tmp="$(mktemp -d)" || return 1
  if ! curl -fL --connect-timeout 10 --max-time 300 --retry 2 -o "$tmp/$archive" "https://github.com/mostlygeek/llama-swap/releases/download/$version/$archive" ||
     ! curl --connect-timeout 10 --max-time 30 -fsSL -o "$tmp/checksums" "https://github.com/mostlygeek/llama-swap/releases/download/$version/llama-swap_${version#v}_checksums.txt"; then
    rm -rf "$tmp"; return 1
  fi
  digest="$(awk -v f="$archive" '$2 == f {print $1}' "$tmp/checksums")"
  if ! [[ "$digest" =~ ^[a-fA-F0-9]{64}$ ]] || [ "$(sha256sum "$tmp/$archive" | awk '{print $1}')" != "$digest" ]; then
    echo 'Error: llama-swap checksum verification failed.' >&2
    rm -rf "$tmp"; return 1
  fi
  if ! tar -xzf "$tmp/$archive" -C "$tmp" llama-swap ||
     ! install -m755 "$tmp/llama-swap" "$destination"; then
    rm -rf "$tmp"; return 1
  fi
  rm -rf "$tmp"
  if [ "$(localvllm_swap_version "$destination")" != "$version" ]; then
    echo 'Error: staged llama-swap version verification failed.' >&2
    return 1
  fi
}

localvllm_install_swap() {
  local version destination
  localvllm_swap_bin >/dev/null 2>&1 && return 0
  version="$(localvllm_swap_target_version)" || return 1
  mkdir -p "$AI_DIR/$LOCALVLLM_BIN_SUBDIR"
  destination="$AI_DIR/$LOCALVLLM_BIN_SUBDIR/llama-swap"
  if ! localvllm_download_swap "$destination.next" "$version"; then
    rm -f "$destination.next"; return 1
  fi
  mv -f "$destination.next" "$destination"
}

localvllm_router_generate() (
  set -euo pipefail
  umask 077
  local output_sh="$1" output_env="$2" binary rebuild work root id source model format path
  local worker hash cmd served key port config digest temp_root="" count=0
  binary="$(localvllm_swap_bin)" || { echo 'Enable automatic switching with: localvllm mode swap' >&2; return 1; }
  case "$LOCALVLLM_LISTEN_HOST" in 127.0.0.1|localhost) ;; *) echo 'Automatic switching currently requires a loopback listener; use an authenticated reverse proxy for network access.' >&2; return 1 ;; esac
  rebuild="$SCRIPT_DIR/rebuild-config.sh"
  if [ "${LOCALVLLM_RUNTIME_CHECK:-0}" = "1" ]; then
    temp_root="$(mktemp -d "${TMPDIR:-/tmp}/localvllm-router-check.XXXXXX")" || return 1
    root="$temp_root"
  else
    root="$CONF_DIR/router"
    mkdir -p "$root"
  fi
  work="$(mktemp -d "$root/.generate.XXXXXX")"
  trap 'rm -rf "$work"; [ -z "${temp_root:-}" ] || rm -rf "$temp_root"' EXIT
  config="$work/config.json"
  api_key_registry_validate "$CONF_DIR/$LOCALVLLM_API_KEY_FILE" || return 1
  key="$(api_key_active_secrets "$CONF_DIR/$LOCALVLLM_API_KEY_FILE" | head -n1)"
  if [ "${LOCALVLLM_REQUIRE_API_KEY:-0}" = 1 ] && [ -z "$key" ]; then
    echo 'Create an API key before enabling automatic switching.' >&2; return 1
  fi
  jq -n --arg key "$key" --argjson timeout "${LOCALVLLM_HEALTH_CHECK_TIMEOUT:-900}" \
    '{healthCheckTimeout:$timeout,unloadTimeout:60,captureBuffer:0,logToStdout:"proxy,upstream,http",logTimeFormat:"rfc3339",models:{}} + (if $key == "" then {} else {apiKeys:[$key]} end)' > "$config"
  while IFS=$'\t' read -r id source model format path; do
    [ -n "$id" ] || continue
    "$rebuild" --backend "$LOCALVLLM_BACKEND" --model "$id" --worker "$work/worker.sh" "$work/worker.env" >/dev/null
    served="$(. "$work/worker.env"; printf '%s' "$LOCALVLLM_SERVED_MODEL_NAME")"
    hash="$(sha256sum "$work/worker.sh" | awk '{print $1}')"
    worker="$root/$hash.sh"
    install -m700 "$work/worker.sh" "$worker"
    # llama-swap substitutes PORT before parsing this command. Quote the path
    # for its shellwords parser rather than relying on Bash-specific %q escapes.
    cmd="$(shell_quote_token "$worker") \${PORT}"
    jq --arg id "$id" --arg cmd "$cmd" --arg served "$served" \
      '.models[$id]={cmd:$cmd,proxy:"http://127.0.0.1:${PORT}",checkEndpoint:"/health",useModelName:$served}' "$config" > "$work/next.json"
    mv "$work/next.json" "$config"
    count=$((count + 1))
  done < <(localvllm_model_entries "$MODELS_DIR" "$OVERRIDES_DIR")
  [ "$count" -gt 0 ] || { echo 'Add at least one model before enabling automatic switching.' >&2; return 1; }
  digest="$(sha256sum "$config" | awk '{print $1}')"
  config="$root/$digest.json"
  install -m600 "$work/config.json" "$config"
  "$binary" -config "$config" -validate >/dev/null || return 1
  port="$LOCALVLLM_DEFAULT_PORT"
  [ ! -f "$PORT_FILE" ] || port="$(cat "$PORT_FILE")"
  [[ "$port" =~ ^[0-9]+$ ]] && ((10#$port > 0 && 10#$port < 65536)) || return 1
  {
    echo '#!/usr/bin/env bash'
    echo 'set -euo pipefail'
    printf 'exec %q -config %q -listen %q\n' "$binary" "$config" "$LOCALVLLM_LISTEN_HOST:$port"
  } > "$work/serve.sh"
  {
    printf 'LOCALVLLM_BACKEND=%q\n' "$LOCALVLLM_BACKEND"
    echo 'LOCALVLLM_MODE=swap'
    echo 'LOCALVLLM_ACTIVE_ID=automatic'
    echo 'LOCALVLLM_MODEL=automatic'
    printf 'LOCALVLLM_PORT=%q\n' "$port"
    printf 'LOCALVLLM_ROUTER_DIGEST=%q\n' "$digest"
    printf 'LOCALVLLM_API_KEY_ACTIVE=%q\n' "$([ -n "$key" ] && echo 1 || echo 0)"
    echo 'LOCALVLLM_ENABLE_SLEEP=0'
  } > "$work/serve.env"
  install -m700 "$work/serve.sh" "$output_sh"
  install -m600 "$work/serve.env" "$output_env"
  echo "Automatic switching: $count models, $LOCALVLLM_BACKEND, http://$(localvllm_url_host "$LOCALVLLM_LISTEN_HOST"):$port/v1"
)

mode_cmd() {
  local wanted="${1:-}" previous was_active=0 rebuild
  [ "$#" -le 1 ] || fail 'usage: localvllm [--backend vllm|omni] mode [direct|swap]'
  previous="$(localvllm_serving_mode)" || return 1
  if [ -z "$wanted" ]; then echo "$LOCALVLLM_BACKEND: $previous"; return 0; fi
  case "$wanted" in direct|swap) ;; *) fail 'choose direct or swap' ;; esac
  [ "$wanted" != "$previous" ] || { echo "Already using $wanted mode."; return 0; }
  if [ "$wanted" = swap ]; then
    case "$LOCALVLLM_LISTEN_HOST" in 127.0.0.1|localhost) ;; *) echo 'Automatic switching requires a loopback listener; the current service was not changed.' >&2; return 1 ;; esac
    localvllm_has_model_entries "$MODELS_DIR" "$OVERRIDES_DIR" || fail 'Add a model first with localvllm pull ORG/MODEL or localvllm add /path/to/model'
    localvllm_install_swap || return 1
  else
    localvllm_resolve_active "$MODELS_DIR" "$ACTIVE_MODEL_FILE" "$OVERRIDES_DIR" || return 1
  fi
  service_is_active && was_active=1
  if [ "$was_active" = 1 ]; then service_cmd stop || return 1; fi
  mkdir -p "$CONF_DIR"
  printf '%s\n' "$wanted" > "$CONF_DIR/serving-mode"
  rebuild="$BIN_DIR/rebuild-config.sh"
  [ -x "$rebuild" ] || rebuild="$SCRIPT_DIR/rebuild-config.sh"
  if ! "$rebuild" --backend "$LOCALVLLM_BACKEND" ||
     { [ "$was_active" = 1 ] && ! service_cmd start; }; then
    printf '%s\n' "$previous" > "$CONF_DIR/serving-mode"
    "$rebuild" --backend "$LOCALVLLM_BACKEND" || true
    if [ "$was_active" = 1 ]; then service_cmd start || true; fi
    echo "Error: restored $previous mode." >&2
    return 1
  fi
  echo "$LOCALVLLM_BACKEND mode: $wanted"
  echo "API: $(api_base_url)/v1"
  [ "$wanted" != swap ] || echo 'Clients choose a model from /v1/models; it loads on demand. Dashboard: /ui'
}

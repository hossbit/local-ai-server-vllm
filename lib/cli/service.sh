# shellcheck shell=bash disable=SC2153,SC2154

service_cmd_one() {
  local action="$1"

  case "$action" in
    start)
      if ! service_is_active; then
        localvllm_require_start_model || return 1
      fi
      ;;
    restart) localvllm_require_start_model || return 1 ;;
  esac

  if has_user_service; then
    print_service_details "systemd user service"
    echo "Running: systemctl --user $action $SERVICE_UNIT"
    if ! systemctl --user "$action" "$SERVICE_UNIT"; then
      echo "Error: systemctl --user $action $SERVICE_UNIT failed." >&2
      echo "Details: journalctl --user -u $LOCALVLLM_SERVICE_NAME -n 30 --no-pager" >&2
      echo "Server log: $LOG_FILE" >&2
      return 1
    fi
    echo "Local $LOCALVLLM_BACKEND_LABEL service $action completed."
    return 0
  fi

  case "$action" in
    start)
      [ -x "$BIN_DIR/start.sh" ] || fail "missing helper: $BIN_DIR/start.sh"
      print_service_details "helper script"
      echo "Running: $BIN_DIR/start.sh $LOCALVLLM_BACKEND"
      if ! "$BIN_DIR/start.sh" "$LOCALVLLM_BACKEND"; then
        echo "Error: $LOCALVLLM_BACKEND_LABEL failed to start." >&2
        return 1
      fi
      ;;
    stop)
      [ -x "$BIN_DIR/stop.sh" ] || fail "missing helper: $BIN_DIR/stop.sh"
      print_service_details "helper script"
      echo "Running: $BIN_DIR/stop.sh $LOCALVLLM_BACKEND"
      if ! "$BIN_DIR/stop.sh" "$LOCALVLLM_BACKEND"; then
        echo "Error: $LOCALVLLM_BACKEND_LABEL failed to stop." >&2
        return 1
      fi
      ;;
    restart)
      service_cmd_one stop || return 1
      service_cmd_one start || return 1
      ;;
    *)
      fail "unsupported service action: $action"
      ;;
  esac
}

service_cmd() {
  local action="$1"
  local selector original_backend name status=0

  shift || true
  [ "$#" -le 1 ] || fail "usage: localvllm $action [BACKEND|all]"
  selector="$(localvllm_resolve_selector "${1:-}")" || return 1
  original_backend="$LOCALVLLM_BACKEND"

  if [ "$selector" = "all" ]; then
    while IFS= read -r name; do
      echo
      echo "== $name =="
      localvllm_use_backend "$name" || continue
      service_cmd_one "$action" || status=1
    done < <(localvllm_backend_list)
    localvllm_use_backend "$original_backend" >/dev/null 2>&1 || true
    return "$status"
  fi

  localvllm_use_backend "$selector" || return 1
  service_cmd_one "$action"
}

status_cmd() {
  local selector original_backend name json=0 selector_arg="" arg
  local tmp

  for arg in "$@"; do
    case "$arg" in
      --json) json=1 ;;
      all|vllm|omni|text|llm|vllm-omni|vllm_omni|omni-vllm) selector_arg="$arg" ;;
      *) fail "usage: localvllm status [--json] [BACKEND|all]" ;;
    esac
  done
  selector="$(localvllm_resolve_selector "$selector_arg")" || return 1
  original_backend="$LOCALVLLM_BACKEND"

  if [ "$json" -eq 1 ]; then
    command -v jq >/dev/null 2>&1 || fail "jq is required for --json output"
    tmp="$(mktemp "${TMPDIR:-/tmp}/localvllm-status.XXXXXX")" || return 1
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" RETURN
    if [ "$selector" = "all" ]; then
      while IFS= read -r name; do
        localvllm_use_backend "$name" || continue
        status_json_one >> "$tmp"
      done < <(localvllm_backend_list)
      localvllm_use_backend "$original_backend" >/dev/null 2>&1 || true
      jq -s '.' "$tmp"
    else
      localvllm_use_backend "$selector" || return 1
      status_json_one
    fi
    return 0
  fi

  if [ "$selector" = "all" ]; then
    while IFS= read -r name; do
      echo
      echo "== $name =="
      localvllm_use_backend "$name" || continue
      status_cmd_one
    done < <(localvllm_backend_list)
    localvllm_use_backend "$original_backend" >/dev/null 2>&1 || true
    return 0
  fi

  localvllm_use_backend "$selector" || return 1
  status_cmd_one
}

status_json_one() {
  local installed=false version="" omni_version="" service_state="not installed"
  local port pid active_id="" active_model="" api_key_active=0 registry runtime

  localvllm_backend_installed "$LOCALVLLM_BACKEND" && installed=true
  version="$(vllm_installed_version "$VENV_DIR")"
  if [ "$LOCALVLLM_BACKEND" = "omni" ]; then
    omni_version="$(vllm_omni_installed_version "$VENV_DIR")"
  fi
  if service_is_active; then
    service_state="running"
  elif has_user_service; then
    service_state="stopped"
  fi
  port="$([ -f "$PORT_FILE" ] && cat "$PORT_FILE" || printf '%s' "$LOCALVLLM_DEFAULT_PORT")"
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  active_id="$(serve_env_value LOCALVLLM_ACTIVE_ID)"
  active_model="$(serve_env_value LOCALVLLM_MODEL)"
  if [ -z "$active_id" ] &&
    localvllm_resolve_active "$MODELS_DIR" "$ACTIVE_MODEL_FILE" "$OVERRIDES_DIR" 2>/dev/null; then
    active_id="$ACTIVE_ID"
    active_model="$ACTIVE_MODEL"
  fi
  runtime="$(model_runtime_info)" || return 1
  registry="$(api_key_registry_path)"
  if [ -f "$registry" ] && [ "$(api_key_active_count "$registry")" -gt 0 ]; then
    api_key_active=1
  fi

  jq -n \
    --argjson runtime "$runtime" \
    --arg backend "$LOCALVLLM_BACKEND" \
    --arg mode "$(localvllm_serving_mode)" \
    --arg label "$LOCALVLLM_BACKEND_LABEL" \
    --argjson installed "$installed" \
    --arg vllm "$version" \
    --arg omni "$omni_version" \
    --arg service "$service_state" \
    --arg port "$port" \
    --arg pid "$pid" \
    --arg active "$active_id" \
    --arg model "$active_model" \
    --arg api_key_active "$api_key_active" \
    --arg log "$LOG_FILE" \
    '{
      backend: $backend,
      mode: $mode,
      label: $label,
      installed: $installed,
      vllm_version: (if $vllm == "" then null else $vllm end),
      vllm_omni_version: (if $omni == "" then null else $omni end),
      service: $service,
      port: ($port | tonumber? // null),
      pid: ($pid | tonumber? // null),
      active_model: (if $runtime.active_model == "" then null else $runtime.active_model end),
      active_models: $runtime.active_models,
      direct_model: $runtime.direct_model,
      runtime_state_available: $runtime.runtime_state_available,
      model: (if $runtime.mode == "direct" and $runtime.active_model != "" then $model else null end),
      api_key_active: ($api_key_active == "1"),
      log: $log
    }'
}

status_cmd_one() {
  local version

  if has_user_service; then
    print_service_details "systemd user service"
    echo "Systemd service:"
    systemctl --user status "$SERVICE_UNIT" --no-pager || true
    echo
    echo "Note: this service uses a helper script and may show active (exited); the process check below is authoritative."
  else
    print_service_details "helper script"
  fi
  pid_status

  version="$(vllm_installed_version "$VENV_DIR")"
  echo "vLLM: ${version:-not installed}"
  if [ "$LOCALVLLM_BACKEND" = "omni" ]; then
    version="$(vllm_omni_installed_version "$VENV_DIR")"
    echo "vLLM-Omni: ${version:-not installed}"
  fi
}

check_cmd() {
  local selector_arg="" chat=0 selector original_backend name status=0 arg

  for arg in "$@"; do
    case "$arg" in
      --chat) chat=1 ;;
      all|vllm|omni|text|llm|vllm-omni|vllm_omni|omni-vllm) selector_arg="$arg" ;;
      *) fail "usage: localvllm check [--chat] [BACKEND|all]" ;;
    esac
  done

  selector="$(localvllm_resolve_selector "$selector_arg")" || return 1
  original_backend="$LOCALVLLM_BACKEND"

  if [ "$selector" = "all" ]; then
    while IFS= read -r name; do
      echo
      echo "== $name =="
      localvllm_use_backend "$name" || continue
      check_one "$chat" || status=1
    done < <(localvllm_backend_list)
    localvllm_use_backend "$original_backend" >/dev/null 2>&1 || true
    return "$status"
  fi

  localvllm_use_backend "$selector" || return 1
  check_one "$chat"
}

check_one() {
  local chat="$1"
  local base models_json chat_response model health_ok=0

  pid_status
  require_api_tools

  base="$(api_base_url)"
  api_auth_curl_args

  echo
  echo "Health:"
  if curl "${AUTH_CURL_ARGS[@]}" --max-time 10 -fsS "$base/health" >/dev/null 2>&1; then
    health_ok=1
    echo "  /health is ready"
  elif curl "${AUTH_CURL_ARGS[@]}" --max-time 10 -fsS "$base/v1/models" >/dev/null 2>&1; then
    health_ok=1
    echo "  /health did not answer, but /v1/models is ready"
  fi
  if [ "$health_ok" -ne 1 ]; then
    echo "Error: API did not respond at $base/health or $base/v1/models" >&2
    return 1
  fi

  echo
  echo "API models:"
  if ! models_json="$(curl "${AUTH_CURL_ARGS[@]}" --max-time 10 -fsS "$base/v1/models")"; then
    echo "Error: API did not respond at $base/v1/models" >&2
    return 1
  fi
  jq -r '.data[]?.id' <<<"$models_json"

  if [ "$chat" -eq 1 ]; then
    model="$(jq -r '.data[0].id // empty' <<<"$models_json")"
    if [ -z "$model" ]; then
      echo "Error: no model is available for chat check" >&2
      return 1
    fi
    echo
    echo "Chat check ($model):"
    if ! chat_response="$(curl "${AUTH_CURL_ARGS[@]}" --max-time "$LOCALVLLM_HEALTH_CHECK_TIMEOUT" -fsS "$base/v1/chat/completions" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg model "$model" '{model: $model, messages: [{role: "user", content: "Reply with OK"}], max_tokens: 8, stream: false}')")"; then
      echo "Error: chat completion failed for $model at $base/v1/chat/completions" >&2
      return 1
    fi
    jq -r '.choices[0].message.content // .choices[0].text // .' <<<"$chat_response"
  fi
}

metrics_summary() {
  local response="$1" previous="${2:-}" elapsed="${3:-0}" key value rate='n/a (use --watch)'
  local -A values=()
  while IFS=$'\t' read -r key value; do values["$key"]="$value"; done < <(
    awk '
      /^[^#]/ {
        line=$0; sub(/\{.*\}/,"",line); split(line,a," "); name=a[1]; v=a[2]
        if (v !~ /^[-+]?[0-9]*[.]?[0-9]+([eE][-+]?[0-9]+)?$/) next
        sum[name]+=v; seen[name]=1
        if (name=="vllm:kv_cache_usage_perc" || name=="vllm:gpu_cache_usage_perc") {
          if (!cache_seen || v>cache) cache=v; cache_seen=1
        }
      }
      function metric(label,name) { printf "%s\t%s\n",label,(seen[name]?sum[name]:"n/a") }
      END {
        metric("running","vllm:num_requests_running"); metric("waiting","vllm:num_requests_waiting")
        metric("generated","vllm:generation_tokens_total"); metric("prompt","vllm:prompt_tokens_total")
        metric("requests","vllm:request_success_total")
        printf "cache\t%s\n",(cache_seen?sprintf("%.1f%%",cache*100):"n/a")
        n="vllm:time_to_first_token_seconds_count"; t="vllm:time_to_first_token_seconds_sum"
        printf "ttft\t%s\n",(sum[n]>0?sprintf("%.3f s",sum[t]/sum[n]):"n/a")
      }' <<< "$response"
  )
  METRICS_CURRENT_GENERATED="${values[generated]}"
  if [ "$elapsed" -gt 0 ] && [ -n "$previous" ] && [ "$previous" != n/a ] && [ "$METRICS_CURRENT_GENERATED" != n/a ]; then
    rate="$(awk -v old="$previous" -v now="$METRICS_CURRENT_GENERATED" -v seconds="$elapsed" 'BEGIN {if(now>=old) printf "%.1f tokens/s (sampled)",(now-old)/seconds; else printf "n/a (counter reset)"}')"
  fi
  printf '  Running requests: %s | Waiting: %s | KV cache (peak): %s\n' "${values[running]}" "${values[waiting]}" "${values[cache]}"
  printf '  Completed requests: %s | Input tokens: %s | Generated tokens: %s\n' "${values[requests]}" "${values[prompt]}" "${values[generated]}"
  printf '  Generation rate: %s | Mean first-token latency: %s\n' "$rate" "${values[ttft]}"
}

metrics_cmd() {
  local selector watch=0 raw=0 arg base response mode payload model proxy now key elapsed total free found
  local interval=2
  local -a args=()
  local -A previous=() sampled=()
  for arg in "$@"; do
    case "$arg" in
      --watch) watch=1 ;;
      --raw) raw=1 ;;
      -h|--help) help_topic metrics; return ;;
      all|vllm|omni|text|llm|vllm-omni|vllm_omni|omni-vllm) args+=("$arg") ;;
      *) fail 'usage: localvllm metrics [BACKEND] [--watch] [--raw]' ;;
    esac
  done
  [ "${#args[@]}" -le 1 ] || fail 'choose one backend'
  selector="$(localvllm_resolve_selector "${args[0]:-}")" || return 1
  [ "$selector" != all ] || fail 'choose vllm or omni for metrics'
  localvllm_use_backend "$selector" || return 1
  require_api_tools
  base="$(api_base_url)"
  api_auth_curl_args
  while :; do
    mode="$(localvllm_serving_mode)" || return 1
    if [ "$raw" = 1 ]; then
      curl "${AUTH_CURL_ARGS[@]}" --max-time 5 -fsS "$base/metrics" || return 1
    else
      if [ "$watch" = 1 ] && [ -t 1 ]; then printf '\033[H\033[2J'; fi
      echo "Local $LOCALVLLM_BACKEND_LABEL | $mode | $(date -u +%FT%TZ)"
      echo "API: $base | Observation only; no model is loaded by this command."
      total="$(gpu_vram_total_min_bytes)"; free="$(gpu_vram_free_min_bytes)"
      if [ "$total" -gt 0 ]; then echo "GPU memory (smallest visible device): total $(format_bytes_gib "$total"), free $(format_bytes_gib "$free")"; fi
      now="$(date +%s)"
      if [ "$mode" = swap ]; then
        if ! payload="$(curl "${AUTH_CURL_ARGS[@]}" --max-time 5 -fsS "$base/running" 2>/dev/null)" || ! jq -e '.running | type == "array"' >/dev/null 2>&1 <<< "$payload"; then
          echo 'Router unavailable or stopped. Check status, API key access, and logs --no-follow.' >&2
          [ "$watch" = 1 ] || return 1
        else
          found=0
          while IFS=$'\t' read -r model proxy; do
            [ -n "$model" ] || continue
            found=1; echo "Loaded model: $model"
            # Query the worker directly: /upstream/MODEL/metrics could wake it.
            if ! [[ "$proxy" =~ ^http://127\.0\.0\.1:[0-9]{1,5}$ ]]; then echo '  Worker metrics unavailable (unsupported worker URL).'; continue; fi
            key="$model|$proxy"
            if response="$(curl --max-time 3 -fsS "$proxy/metrics" 2>/dev/null)"; then
              elapsed=$((now - ${sampled[$key]:-$now}))
              metrics_summary "$response" "${previous[$key]:-}" "$elapsed"
              previous["$key"]="$METRICS_CURRENT_GENERATED"; sampled["$key"]="$now"
            else echo '  Worker metrics unavailable (loading/unloading, or endpoint unsupported).'; unset 'previous[$key]' 'sampled[$key]'; fi
          done < <(jq -r '.running[] | select(.state == "ready") | [.model,.proxy] | @tsv' <<< "$payload")
          if [ "$found" = 0 ]; then
            echo 'No ready model. Models may be unloaded or still loading; no inference was requested.'
            previous=(); sampled=()
          fi
        fi
      elif response="$(curl "${AUTH_CURL_ARGS[@]}" --max-time 5 -fsS "$base/metrics" 2>/dev/null)"; then
        echo 'Engine metrics: API reachable'
        echo "Model labels: $(grep -oE 'model_name="[^"]*"' <<< "$response" | sort -u | paste -sd ' ' - || true)"
        elapsed=$((now - ${sampled[direct]:-$now}))
        metrics_summary "$response" "${previous[direct]:-}" "$elapsed"
        previous[direct]="$METRICS_CURRENT_GENERATED"; sampled[direct]="$now"
      else
        echo 'Engine metrics unavailable. Check status, API key access, and logs --no-follow.' >&2
        [ "$watch" = 1 ] || return 1
        previous=(); sampled=()
      fi
      echo 'Counters and mean latency are cumulative per worker process. n/a means not exposed yet.'
      [ "$LOCALVLLM_BACKEND" != omni ] || echo 'Omni stage-specific audio/image/video metrics vary by model; --raw preserves the native endpoint.'
    fi
    [ "$watch" = 1 ] || return 0
    sleep "$interval"
  done
}

logs_cmd() {
  local selector="" root="$AI_DIR/${LOCALVLLM_LOGS_SUBDIR:-logs}" lines=80 follow=1 list=0 path=0 service=0 file="" arg
  local -a files=() journal_args=()
  while [ "$#" -gt 0 ]; do
    arg="$1"; shift
    case "$arg" in
      --list) list=1 ;;
      --path) path=1 ;;
      --no-follow) follow=0 ;;
      --service) service=1 ;;
      --lines|-n) [ "$#" -gt 0 ] || fail 'missing line count'; lines="$1"; shift ;;
      --file) [ "$#" -gt 0 ] || fail 'missing log filename'; file="$1"; shift ;;
      -h|--help) help_topic logs; return ;;
      vllm|omni|all) [ -z "$selector" ] || fail 'choose only one backend'; selector="$arg" ;;
      *) fail 'usage: localvllm logs [vllm|omni|all] [--list|--path|--service|--file NAME] [--no-follow] [--lines N]' ;;
    esac
  done
  if ! [[ "$lines" =~ ^[0-9]{1,5}$ ]] || ! ((10#$lines > 0 && 10#$lines <= 10000)); then fail 'line count must be 1–10000'; fi
  lines=$((10#$lines))
  [ "$path" = 0 ] || { echo "$root"; return; }
  if [ "$list" = 1 ]; then
    echo "All logs: $root"
    echo 'vllm.log / omni.log: engine and automatic-router output'
    echo 'install.log / update.log: complete installer/updater output'
    echo 'install-packages-*.log / update-packages-*.log: package resolver output'
    echo 'manager-events.log: command names, backend and exit status (no arguments)'
    echo 'service-*.log: systemd output saved by logs --service'
    echo 'browser.log: desktop browser launcher diagnostics'
    echo 'Timestamped files are earlier sessions; pip-install-*.log are legacy package logs.'
    if [ -d "$root" ]; then find "$root" -maxdepth 1 -type f -name '*.log*' -printf '%f\n' | sort; fi
    echo 'View: localvllm logs --file NAME --no-follow; live output: omit --no-follow (Ctrl+C stops).'
    return
  fi
  selector="${selector:-$LOCALVLLM_BACKEND}"
  if [ "$service" = 1 ]; then
    [ "$selector" != all ] || fail 'choose vllm or omni for --service'
    [ -z "$file" ] || fail 'use --service or --file, not both'
    localvllm_use_backend "$selector" || return 1
    command -v journalctl >/dev/null || fail 'journalctl is unavailable on this system'
    mkdir -p "$root"
    file="$root/service-$selector.log"
    localvllm_rotate_log "$file" || return 1
    (umask 077; touch "$file") || return 1
    chmod 600 "$file"
    journal_args=(--user -u "$SERVICE_UNIT" -n "$lines" --no-pager)
    [ "$follow" = 0 ] || journal_args+=(-f)
    journalctl "${journal_args[@]}" | tee "$file"
    return
  fi
  if [ -n "$file" ]; then
    [[ "$file" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.log([.][A-Za-z0-9._-]+)?$ ]] || fail 'use a filename from logs --list, without a directory'
    files=("$root/$file")
  elif [ "$selector" = all ]; then
    if [ -d "$root" ]; then mapfile -t files < <(find "$root" -maxdepth 1 -type f -name '*.log' -print | sort); fi
  else
    localvllm_use_backend "$selector" || return 1
    files=("$LOG_FILE")
  fi
  if [ "${#files[@]}" = 0 ]; then echo "No logs yet. Directory: $root"; return; fi
  for file in "${files[@]}"; do
    [ -f "$file" ] || { echo "Log not created yet: $file"; echo 'Use localvllm logs --list or logs --service to inspect startup failures.'; return 1; }
  done
  echo "Logs: $root"
  if [ "$follow" = 1 ]; then tail -n "$lines" -F -- "${files[@]}"; else tail -n "$lines" -- "${files[@]}"; fi
}

#!/usr/bin/env bash
set -Eeuo pipefail

INTERVAL=${INTERVAL:-10}
CONSECUTIVE=${CONSECUTIVE:-3}
STARTUP_GRACE=${STARTUP_GRACE:-900}
MAX_RUNNING=${MAX_RUNNING:-1}
MIN_WAITING=${MIN_WAITING:-1}
LOG_TAIL_LINES=${LOG_TAIL_LINES:-500}
MAX_CAPTURE_KB=${MAX_CAPTURE_KB:-192}
METRICS_SAMPLES=${METRICS_SAMPLES:-8}
METRICS_SAMPLE_INTERVAL=${METRICS_SAMPLE_INTERVAL:-2}
DEPLOYMENT=${DEPLOYMENT:-2xa2}
MODEL=${MODEL:-glm-5.3-flash}
OUTPUT_PARENT=${OUTPUT_PARENT:-./diagnostics}
OUTPUT_FORMAT=${OUTPUT_FORMAT:-log}
SCRIPT_PATH=${BASH_SOURCE[0]:-}
if [[ -n "$SCRIPT_PATH" ]]; then
  SCRIPT_PATH=$(cd "$(dirname "$SCRIPT_PATH")" && pwd)/$(basename "$SCRIPT_PATH")
fi
[[ "$MAX_CAPTURE_KB" =~ ^[1-9][0-9]*$ ]] || { printf 'MAX_CAPTURE_KB must be a positive integer\n' >&2; exit 2; }
[[ "$METRICS_SAMPLES" =~ ^[1-9][0-9]*$ ]] || { printf 'METRICS_SAMPLES must be a positive integer\n' >&2; exit 2; }
[[ "$METRICS_SAMPLE_INTERVAL" =~ ^[1-9][0-9]*$ ]] || { printf 'METRICS_SAMPLE_INTERVAL must be a positive integer\n' >&2; exit 2; }

usage() {
  cat <<'EOF'
Usage:
  bash scripts/collect-failure-diagnostics.sh [snapshot|watch]

Environment: INTERVAL=10 CONSECUTIVE=3 STARTUP_GRACE=900
             MAX_RUNNING=1 MIN_WAITING=1 LOG_TAIL_LINES=500 MAX_CAPTURE_KB=192
             METRICS_SAMPLES=8 METRICS_SAMPLE_INTERVAL=2
             OUTPUT_FORMAT=log|tar|dir (default: log)
watch triggers when running <= MAX_RUNNING and waiting >= MIN_WAITING, or when the
metrics endpoint is unreachable, for CONSECUTIVE observations. Before the service
has ever become reachable, endpoint failures are ignored for STARTUP_GRACE seconds.
EOF
}
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }
section() { printf '\n===== %s =====\n' "$1"; }
safe_run() { local title=$1; shift; section "$title"; timeout 20 "$@" 2>&1 || printf '[failed/timed out: %s]\n' "$*"; }
metric_sum() { awk -v n="$1" '{key=$1; sub(/\{.*/, "", key)} key == n {s += $2; f=1} END {if(f) print s}' "$2"; }

capture_metric_series() {
  local url=$1 output=$2 i sample
  : > "$output"
  for ((i = 1; i <= METRICS_SAMPLES; i++)); do
    printf '\n--- sample=%s captured_at=%s ---\n' "$i" "$(date --iso-8601=seconds 2>/dev/null || date)" >> "$output"
    sample=$(mktemp)
    if curl --fail --silent --show-error --max-time 5 "$url" > "$sample" 2>> "$output"; then
      filter_vllm_metrics "$sample" >> "$output"
    else
      printf '[metrics request failed]\n' >> "$output"
    fi
    rm -f -- "$sample"
    (( i < METRICS_SAMPLES )) && sleep "$METRICS_SAMPLE_INTERVAL"
  done
}

filter_vllm_metrics() {
  awk '
    /^vllm:/ {
      name=$1; sub(/\{.*/, "", name)
      if (name == "vllm:num_requests_running" ||
          name == "vllm:num_requests_waiting" ||
          name == "vllm:num_requests_waiting_by_reason" ||
          name == "vllm:kv_cache_usage_perc" ||
          name == "vllm:engine_sleep_state" ||
          name == "vllm:num_preemptions_total" ||
          name == "vllm:prompt_tokens_total" ||
          name == "vllm:generation_tokens_total" ||
          name == "vllm:prompt_tokens_cached_total" ||
          name == "vllm:request_success_total") print
    }
  ' "$1"
}

cap_file() {
  local file=$1 limit_kb=$2 direction=${3:-tail} tmp size limit
  [[ -f "$file" ]] || return 0
  size=$(wc -c < "$file"); limit=$((limit_kb * 1024))
  (( size <= limit )) && return 0
  tmp="${file}.capped"
  if [[ "$direction" == head ]]; then head -c "$limit" "$file" > "$tmp"
  else tail -c "$limit" "$file" > "$tmp"
  fi
  mv "$tmp" "$file"
}

compact_capture() {
  local out=$1
  cap_file "$out/manifest.txt" 2 head
  cap_file "$out/metrics.txt" 4 head
  cap_file "$out/metrics-series.txt" 24 head
  cap_file "$out/metrics-error.txt" 1 tail
  cap_file "$out/health.txt" 1 head
  cap_file "$out/docker.txt" 6 tail
  cap_file "$out/npu.txt" 8 head
  cap_file "$out/kernel-last-15m.log" 4 tail
  cap_file "$out/host.txt" 4 head
  cap_file "$out/processes.txt" 8 tail
  cap_file "$out/container-tail.log" 18 tail
  cap_file "$out/container-events.log" 24 tail
  cap_file "$out/runtime.txt" 12 head
}

collect_local() {
  local node=$1
  local trigger_metrics=${2:-}
  local env_file="deployments/$DEPLOYMENT/$node.env"
  [[ -f "$env_file" ]] || { log "missing $env_file"; return 1; }
  # shellcheck source=/dev/null
  source "$env_file"
  local container=${CONTAINER_NAME:-glm-5.3-flash} port=${PORT:-8080} probe_host
  [[ ${NODE_RANK:-0} == 0 ]] && probe_host=127.0.0.1 || probe_host=${HEAD_IP:?}
  local stamp host out result pid pids file series_pid
  stamp=$(date '+%Y%m%d-%H%M%S'); host=$(hostname 2>/dev/null || printf unknown)
  out="$OUTPUT_PARENT/vllm-failure-${node}-${host}-${stamp}"
  mkdir -p "$out"
  printf 'collected_at=%s\nnode=%s\nhost=%s\ncontainer=%s\ncollector_version=5\nlog_tail_lines=%s\nmax_capture_kb=%s\nmetrics_samples=%s\nmetrics_sample_interval=%s\n' \
    "$(date --iso-8601=seconds 2>/dev/null || date)" "$node" "$host" "$container" "$LOG_TAIL_LINES" "$MAX_CAPTURE_KB" \
    "$METRICS_SAMPLES" "$METRICS_SAMPLE_INTERVAL" > "$out/manifest.txt"

  # Start a bounded time series immediately. A single snapshot cannot
  # distinguish a slow prefill from a scheduler whose counters have stopped.
  capture_metric_series "http://$probe_host:$port/metrics" "$out/metrics-series.txt" &
  series_pid=$!

  # In watch mode, preserve the exact metrics response that met the trigger.
  # The remaining diagnostics can take tens of seconds, during which queued
  # requests may time out and disappear from a fresh metrics response.
  if [[ -n "$trigger_metrics" && -f "$trigger_metrics" ]]; then
    filter_vllm_metrics "$trigger_metrics" > "$out/metrics.txt"
    printf 'metrics_source=watch_trigger\nmetrics_captured_at=%s\n' \
      "$(date --iso-8601=seconds 2>/dev/null || date)" >> "$out/manifest.txt"
  fi

  {
    safe_run uptime uptime
    safe_run memory free -h
    safe_run load_and_vmstat vmstat 1 5
    safe_run filesystem df -h
    safe_run kernel uname -a
    safe_run processes ps -eo pid,ppid,stat,psr,pcpu,pmem,etimes,wchan:32,comm --sort=-pcpu
    have ss && safe_run sockets ss -tanp
  } > "$out/host.txt" 2>&1

  if have docker; then
    {
      safe_run docker_ps docker ps -a --no-trunc --filter "name=^/${container}$"
      safe_run docker_stats docker stats --no-stream "$container"
      section docker_inspect_summary
      timeout 20 docker inspect --format \
        'id={{.Id}} image={{.Config.Image}} status={{.State.Status}} running={{.State.Running}} restarting={{.State.Restarting}} oom_killed={{.State.OOMKilled}} exit={{.State.ExitCode}} started={{.State.StartedAt}} finished={{.State.FinishedAt}} health={{if .State.Health}}{{.State.Health.Status}}{{end}} restart_count={{.RestartCount}} pid={{.State.Pid}}' \
        "$container" 2>&1 || true
      safe_run docker_events docker events --since 30m --until "$(date --iso-8601=seconds 2>/dev/null || date)" \
        --filter "container=$container"
    } > "$out/docker.txt" 2>&1
    timeout 60 docker logs --timestamps --tail "$LOG_TAIL_LINES" "$container" > "$out/container-tail.log" 2>&1 || true
    timeout 60 docker logs --timestamps --since 30m "$container" 2>&1 | awk '
      BEGIN {IGNORECASE=1}
      /out-of-order step|running:|waiting:|capacity|scheduler|enginecore|kv cache|maximum concurrency|error|exception|traceback|timeout|oom|hccl|npu/ {print}
    ' > "$out/container-events.log" || true
    {
      section image_and_command
      timeout 20 docker inspect --format 'image={{.Config.Image}} command={{json .Config.Cmd}} entrypoint={{json .Config.Entrypoint}}' "$container" 2>&1 || true
      section package_versions
      timeout 20 docker exec "$container" python3 -c \
        'import importlib.metadata as m; print("vllm=" + m.version("vllm")); print("vllm-ascend=" + m.version("vllm-ascend"))' 2>&1 || true
      section model_config
      if [[ -f "models/$MODEL/vllm.yml" ]]; then sed -n '1,240p' "models/$MODEL/vllm.yml"; else printf '[model config unavailable]\n'; fi
    } > "$out/runtime.txt" 2>&1
    pid=$(docker inspect --format '{{.State.Pid}}' "$container" 2>/dev/null || true)
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
      {
        section container_process_tree
        timeout 20 docker top "$container" -eo pid,ppid,stat,psr,pcpu,pmem,etimes,wchan:32,comm 2>&1 || true
        pids=$(timeout 10 docker top "$container" -eo pid 2>/dev/null | awk 'NR>1 && $1 ~ /^[0-9]+$/ {print $1}')
        for pid in $pids; do
          printf '\n--- pid=%s ---\ncmdline: ' "$pid"
          tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true; printf '\nwchan: '
          cat "/proc/$pid/wchan" 2>/dev/null || true; printf '\n'
          sed -n '1,45p' "/proc/$pid/status" 2>/dev/null || true
          printf 'kernel stack:\n'; cat "/proc/$pid/stack" 2>/dev/null || true
          printf 'thread wait channels:\n'
          for task in /proc/"$pid"/task/[0-9]*; do
            [[ -d "$task" ]] || continue
            printf 'tid=%s comm=' "${task##*/}"
            cat "$task/comm" 2>/dev/null | tr '\n' ' '
            printf 'wchan='; cat "$task/wchan" 2>/dev/null || true; printf '\n'
          done
        done
      } > "$out/processes.txt" 2>&1
    fi
  fi

  if have npu-smi; then safe_run npu_smi_info npu-smi info > "$out/npu.txt" 2>&1
  elif [[ -x /usr/local/sbin/npu-smi ]]; then safe_run npu_smi_info /usr/local/sbin/npu-smi info > "$out/npu.txt" 2>&1; fi
  if [[ ! -f "$out/metrics.txt" ]]; then
    curl --silent --show-error --max-time 10 "http://$probe_host:$port/metrics" > "$out/metrics.raw" 2> "$out/metrics-error.txt" || true
    filter_vllm_metrics "$out/metrics.raw" > "$out/metrics.txt"
    rm -f "$out/metrics.raw"
    printf 'metrics_source=collection_time\n' >> "$out/manifest.txt"
  fi
  curl --silent --show-error --max-time 10 -o /dev/null -w 'health_http_code=%{http_code}\nhealth_total_seconds=%{time_total}\n' \
    "http://$probe_host:$port/health" > "$out/health.txt" 2>&1 || true
  have journalctl && timeout 20 journalctl -k --since '-15 minutes' --no-pager > "$out/kernel-last-15m.log" 2>&1 || true
  wait "$series_pid" || true
  compact_capture "$out"
  case "$OUTPUT_FORMAT" in
    log)
      result="$out.log"
      : > "$result"
      for file in "$out"/*; do
        printf '\n\n######## FILE: %s ########\n' "$(basename "$file")" >> "$result"
        cat "$file" >> "$result"
      done
      if (( $(wc -c < "$result") > MAX_CAPTURE_KB * 1024 )); then
        head -c "$((MAX_CAPTURE_KB * 1024))" "$result" > "${result}.capped"
        mv "${result}.capped" "$result"
      fi
      rm -r "$out"
      ;;
    tar)
      result="$out.tar.gz"
      tar -czf "$result" -C "$(dirname "$out")" "$(basename "$out")"
      rm -r "$out"
      ;;
    dir) result="$out" ;;
    *) log "OUTPUT_FORMAT must be log, tar, or dir"; return 2 ;;
  esac
  printf '%s\n' "$result"
}

watch_local() {
  local node=$1
  local env_file="deployments/$DEPLOYMENT/$node.env" failures=0 tmp running waiting
  local watch_started now elapsed ever_reachable=0
  # shellcheck source=/dev/null
  source "$env_file"; local port=${PORT:-8080} probe_host
  [[ ${NODE_RANK:-0} == 0 ]] && probe_host=127.0.0.1 || probe_host=${HEAD_IP:?}
  tmp=$(mktemp)
  trap 'if [[ -n ${tmp:-} ]]; then rm -f -- "$tmp"; fi' EXIT
  watch_started=$(date +%s)
  log "watching node=$node every ${INTERVAL}s (startup_grace=${STARTUP_GRACE}s, running<=${MAX_RUNNING}, waiting>=${MIN_WAITING}, consecutive=$CONSECUTIVE)"
  while true; do
    if curl --fail --silent --show-error --max-time 5 "http://$probe_host:$port/metrics" > "$tmp"; then
      ever_reachable=1
      running=$(metric_sum 'vllm:num_requests_running' "$tmp"); waiting=$(metric_sum 'vllm:num_requests_waiting' "$tmp")
      running=${running:-0}; waiting=${waiting:-0}
      if awk -v r="$running" -v w="$waiting" -v mr="$MAX_RUNNING" -v mw="$MIN_WAITING" \
        'BEGIN {exit !(r <= mr && w >= mw)}'; then
        failures=$((failures + 1)); log "suspected stall ($failures/$CONSECUTIVE): running=$running waiting=$waiting"
      elif ! curl --fail --silent --output /dev/null --max-time 5 "http://$probe_host:$port/health"; then
        failures=$((failures + 1)); log "health endpoint failed ($failures/$CONSECUTIVE)"
      else failures=0; fi
    else
      now=$(date +%s); elapsed=$((now - watch_started))
      if (( ever_reachable == 0 && elapsed < STARTUP_GRACE )); then
        failures=0
        log "metrics endpoint not ready during startup grace (${elapsed}/${STARTUP_GRACE}s)"
      else
        failures=$((failures + 1)); log "metrics endpoint unreachable ($failures/$CONSECUTIVE)"
      fi
    fi
    if (( failures >= CONSECUTIVE )); then
      log 'trigger met; preserving trigger metrics and collecting diagnostics'
      collect_local "$node" "$tmp"
      return
    fi
    sleep "$INTERVAL"
  done
}

cluster_run() {
  local action=$1 config="deployments/$DEPLOYMENT/cluster.conf" node node_ip remote_cmd result local_ips
  local -a watch_pids=()
  [[ -f "$SCRIPT_PATH" ]] || { log 'cluster mode must be started from the collector script file'; return 1; }
  [[ -f "$config" ]] || { log "missing $config"; return 1; }
  # shellcheck source=/dev/null
  source "$config"; : "${SSH_USER:?}" "${REMOTE_PROJECT_DIR:?}"
  mkdir -p "$OUTPUT_PARENT"; local_ips=$(hostname -I 2>/dev/null || true)
  for node in "${NODES[@]}"; do
    node_ip=$(sed -n 's/^NODE_IP=//p' "deployments/$DEPLOYMENT/$node.env" | tail -1)
    if [[ " $local_ips " == *" $node_ip "* ]]; then
      if [[ "$action" == watch ]]; then
        watch_local "$node" & watch_pids+=("$!")
      else
        collect_local "$node"
      fi
    else
      # Send this collector over stdin so watch/snapshot also works when the
      # remote checkout has not yet received this script.
      printf -v remote_cmd 'cd %q && DEPLOYMENT=%q MODEL=%q OUTPUT_PARENT=%q OUTPUT_FORMAT=%q INTERVAL=%q CONSECUTIVE=%q STARTUP_GRACE=%q MAX_RUNNING=%q MIN_WAITING=%q LOG_TAIL_LINES=%q MAX_CAPTURE_KB=%q METRICS_SAMPLES=%q METRICS_SAMPLE_INTERVAL=%q bash -s -- --local %q %q' \
        "$REMOTE_PROJECT_DIR" "$DEPLOYMENT" "$MODEL" "$OUTPUT_PARENT" "$OUTPUT_FORMAT" "$INTERVAL" "$CONSECUTIVE" "$STARTUP_GRACE" "$MAX_RUNNING" "$MIN_WAITING" "$LOG_TAIL_LINES" "$MAX_CAPTURE_KB" "$METRICS_SAMPLES" "$METRICS_SAMPLE_INTERVAL" "$node" "$action"
      if [[ "$action" == watch ]]; then
        ssh -p "${SSH_PORT:-22}" "${SSH_OPTIONS[@]}" "$SSH_USER@$node_ip" "$remote_cmd" < "$SCRIPT_PATH" & watch_pids+=("$!")
      else
        result=$(ssh -p "${SSH_PORT:-22}" "${SSH_OPTIONS[@]}" "$SSH_USER@$node_ip" "$remote_cmd" < "$SCRIPT_PATH")
        log "$node: $result (archive remains on $node_ip)"
      fi
    fi
  done
  if [[ "$action" == watch ]]; then
    for pid in "${watch_pids[@]}"; do wait "$pid" || true; done
  fi
}

case ${1:-snapshot} in
  snapshot|watch) cluster_run "${1:-snapshot}" ;;
  --local) [[ ${3:-snapshot} == watch ]] && watch_local "${2:?node required}" || collect_local "${2:?node required}" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac

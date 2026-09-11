#!/usr/bin/env bash
set -Eeuo pipefail

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die() { log "ERROR: $*"; exit 1; }

: "${NODE_RANK:?NODE_RANK is required}"
: "${NODE_IP:?NODE_IP is required}"
: "${HEAD_IP:?HEAD_IP is required}"
: "${MODEL_DIR:?MODEL_DIR is required}"
: "${MULTIDEPLOY_MODEL_CONFIG:?MULTIDEPLOY_MODEL_CONFIG is required; load a model compose file}"
: "${PORT:=8080}"
: "${DP_SIZE:?DP_SIZE is required}"
: "${DP_LOCAL_SIZE:?DP_LOCAL_SIZE is required}"
: "${TP_SIZE:?TP_SIZE is required}"
: "${DP_RPC_PORT:?DP_RPC_PORT is required}"
: "${API_SERVER_COUNT:=1}"
: "${SERVICE_START_TIMEOUT:=1800}"
: "${HEALTH_INTERVAL:=30}"
: "${HEALTH_FAILURE_THRESHOLD:=3}"
: "${ACTIVE_HEALTH_RESTART:=false}"
[[ "$NODE_RANK" =~ ^[0-9]+$ ]] || die "NODE_RANK must be a non-negative integer"
(( NODE_RANK < DP_SIZE )) || die "NODE_RANK must be smaller than DP_SIZE"
[[ -d "$MODEL_DIR" ]] || die "model directory does not exist: $MODEL_DIR"
command -v curl >/dev/null 2>&1 || die "curl is required for health checks"
[[ "$ACTIVE_HEALTH_RESTART" == "true" || "$ACTIVE_HEALTH_RESTART" == "false" ]] || \
  die "ACTIVE_HEALTH_RESTART must be true or false"

# NODE_IP 是宿主机通信 IP。host 网络模式下直接将它交给 HCCL/vLLM；
# 镜像不一定带 iproute2，因此显式配置网卡时不再做 IP 归属反查。
if [[ -n "${EXPECTED_NIC:-}" ]]; then
  NIC_NAME=$EXPECTED_NIC
  [[ -d "/sys/class/net/$NIC_NAME" ]] || {
    log "visible interfaces: $(find /sys/class/net -mindepth 1 -maxdepth 1 -exec basename {} \; 2>/dev/null | tr '\n' ' ')"
    die "configured NIC is not visible in container: $NIC_NAME"
  }
  log "using host network: NODE_IP=$NODE_IP, NIC=$NIC_NAME"
else
  command -v ip >/dev/null 2>&1 || die "EXPECTED_NIC is empty and 'ip' is unavailable; configure EXPECTED_NIC"
  mapfile -t matched_nics < <(
    ip -o -4 addr show | awk -v target="$NODE_IP" '
      { split($4, address, "/"); if (address[1] == target) print $2 }
    '
  )
  (( ${#matched_nics[@]} == 1 )) || die "NODE_IP=$NODE_IP must match exactly one visible interface; configure EXPECTED_NIC explicitly"
  NIC_NAME=${matched_nics[0]}
  log "network detected: $NODE_IP -> $NIC_NAME"
fi

export PYTORCH_NPU_ALLOC_CONF=expandable_segments:True
export PYTHONFAULTHANDLER=1
export HCCL_OP_EXPANSION_MODE=AIV
export HCCL_BUFFSIZE=1024
export VLLM_EXECUTE_MODEL_TIMEOUT_SECONDS=3000
export HCCL_EXEC_TIMEOUT=3600
export HCCL_CONNECT_TIMEOUT=1200
export GLOO_SOCKET_IFNAME="$NIC_NAME"
export TP_SOCKET_IFNAME="$NIC_NAME"
export HCCL_SOCKET_IFNAME="$NIC_NAME"
export HCCL_IF_IP="$NODE_IP"
export ASCEND_RT_VISIBLE_DEVICES=0,1,2,3,4,5,6,7
mkdir -p /data/logs

# 同一份输出同时进入 docker logs 和宿主机持久化目录。
LOG_FILE="/data/logs/vllm-rank${NODE_RANK}.log"
exec > >(tee -a "$LOG_FILE") 2>&1

args=(
  "$MODEL_DIR"
  --host 0.0.0.0
  --port "$PORT"
  --data-parallel-size "$DP_SIZE"
  --data-parallel-size-local "$DP_LOCAL_SIZE"
  --data-parallel-start-rank "$NODE_RANK"
  --data-parallel-address "$HEAD_IP"
  --data-parallel-rpc-port "$DP_RPC_PORT"
  --tensor-parallel-size "$TP_SIZE"
  --seed 1024
  --config "$MULTIDEPLOY_MODEL_CONFIG"
)
(( NODE_RANK > 0 )) && args+=(--headless)
(( NODE_RANK == 0 )) && args+=(--api-server-count "$API_SERVER_COUNT")

shutdown() {
  local reason=${1:-exit}
  if [[ -n "${VLLM_PID:-}" ]] && kill -0 "$VLLM_PID" 2>/dev/null; then
    log "entrypoint received $reason; forwarding SIGTERM to vLLM pid=$VLLM_PID"
    kill "$VLLM_PID" 2>/dev/null || true
  fi
}
trap 'shutdown TERM; exit 143' TERM
trap 'shutdown INT; exit 130' INT
trap 'shutdown EXIT' EXIT
log "rank=$NODE_RANK/$DP_SIZE; vllm serve $(printf '%q ' "${args[@]}")"

# Preserve stderr verbatim. In multiprocessing startup failures the last child
# often reports only "pickle data was truncated"; the parent traceback emitted
# immediately before it contains the actual cause and must not be filtered.
vllm serve "${args[@]}" &
VLLM_PID=$!

if (( NODE_RANK == 0 )); then
  HEALTH_HOST=127.0.0.1
else
  # Headless workers do not expose an API server, so they monitor node0.
  HEALTH_HOST=$HEAD_IP
fi
HEALTH_URL="http://${HEALTH_HOST}:${PORT}/health"

probe() {
  curl --fail --silent --output /dev/null --max-time 5 "$HEALTH_URL"
}

deadline=$((SECONDS + SERVICE_START_TIMEOUT))
until probe; do
  kill -0 "$VLLM_PID" 2>/dev/null || { wait "$VLLM_PID"; exit $?; }
  (( SECONDS < deadline )) || die "service readiness timed out"
  sleep 10
done
log "service ready: $HEALTH_URL"

if [[ "$ACTIVE_HEALTH_RESTART" == "true" ]]; then
  # 仅在明确开启时，才把健康探测失败升级为容器重启。跨节点 DP 场景下，
  # node0 的短暂不可达会使所有从属节点同时退出，因此默认关闭该行为。
  log "active health restart enabled: interval=${HEALTH_INTERVAL}s threshold=$HEALTH_FAILURE_THRESHOLD"
  failures=0
  while kill -0 "$VLLM_PID" 2>/dev/null; do
    sleep "$HEALTH_INTERVAL"
    if probe; then
      failures=0
    else
      failures=$((failures + 1))
      log "health check failed ($failures/$HEALTH_FAILURE_THRESHOLD)"
      (( failures < HEALTH_FAILURE_THRESHOLD )) || die "unhealthy; restarting container"
    fi
  done
else
  log "active health restart disabled; Docker healthcheck remains status-only"
  wait "$VLLM_PID"
fi

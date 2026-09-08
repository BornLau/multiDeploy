#!/usr/bin/env bash
set -Eeuo pipefail

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die() { log "ERROR: $*"; exit 1; }

: "${NODE_RANK:?NODE_RANK is required}"
: "${NODE_IP:?NODE_IP is required}"
: "${HEAD_IP:?HEAD_IP is required}"
: "${MODEL_DIR:?MODEL_DIR is required}"
: "${VLLM_MODEL_CONFIG:?VLLM_MODEL_CONFIG is required; load a model compose file}"
: "${PORT:=8080}"
: "${DP_SIZE:?DP_SIZE is required}"
: "${DP_LOCAL_SIZE:?DP_LOCAL_SIZE is required}"
: "${TP_SIZE:?TP_SIZE is required}"
: "${DP_RPC_PORT:?DP_RPC_PORT is required}"
: "${API_SERVER_COUNT:=1}"
: "${SERVICE_START_TIMEOUT:=3600}"
: "${HEALTH_INTERVAL:=30}"
: "${HEALTH_FAILURE_THRESHOLD:=3}"
[[ "$NODE_RANK" =~ ^[0-9]+$ ]] || die "NODE_RANK must be a non-negative integer"
(( NODE_RANK < DP_SIZE )) || die "NODE_RANK must be smaller than DP_SIZE"
[[ -d "$MODEL_DIR" ]] || die "model directory does not exist: $MODEL_DIR"

# host 网络模式下容器能看到宿主机网卡；根据通信 IP 精确反查接口。
command -v ip >/dev/null 2>&1 || die "'ip' command not found; cannot detect NIC for $NODE_IP"
mapfile -t matched_nics < <(
  ip -o -4 addr show | awk -v target="$NODE_IP" '
    { split($4, address, "/"); if (address[1] == target) print $2 }
  '
)
if (( ${#matched_nics[@]} == 0 )); then
  log "visible IPv4 interfaces:"
  ip -o -4 addr show >&2 || true
  die "NODE_IP=$NODE_IP does not belong to any visible network interface"
fi
(( ${#matched_nics[@]} == 1 )) || die "NODE_IP=$NODE_IP matched multiple interfaces: ${matched_nics[*]}"
NIC_NAME=${matched_nics[0]}
if [[ -n "${EXPECTED_NIC:-}" && "$NIC_NAME" != "$EXPECTED_NIC" ]]; then
  die "NODE_IP=$NODE_IP belongs to $NIC_NAME, expected $EXPECTED_NIC"
fi
log "network detected: $NODE_IP -> $NIC_NAME"

export PYTORCH_NPU_ALLOC_CONF=expandable_segments:True
export HCCL_OP_EXPANSION_MODE=AIV
export HCCL_BUFFSIZE=1024
export VLLM_RPC_TIMEOUT=3600000
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
  --config "$VLLM_MODEL_CONFIG"
)
(( NODE_RANK > 0 )) && args+=(--headless)
(( NODE_RANK == 0 )) && args+=(--api-server-count "$API_SERVER_COUNT")

shutdown() {
  if [[ -n "${VLLM_PID:-}" ]]; then
    kill "$VLLM_PID" 2>/dev/null || true
  fi
}
trap shutdown EXIT INT TERM
log "rank=$NODE_RANK/$DP_SIZE; vllm serve $(printf '%q ' "${args[@]}")"
vllm serve "${args[@]}" &
VLLM_PID=$!

probe() {
  python3 - "$HEAD_IP" "$PORT" <<'PY'
import sys, urllib.request
with urllib.request.urlopen(f"http://{sys.argv[1]}:{sys.argv[2]}/health", timeout=5) as response:
    if response.status != 200:
        raise SystemExit(1)
PY
}

deadline=$((SECONDS + SERVICE_START_TIMEOUT))
until probe; do
  kill -0 "$VLLM_PID" 2>/dev/null || { wait "$VLLM_PID"; exit $?; }
  (( SECONDS < deadline )) || die "service readiness timed out"
  sleep 10
done
log "service ready: http://${HEAD_IP}:${PORT}"

# Compose healthcheck 只展示状态；这里主动退出才会触发 restart: always。
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
wait "$VLLM_PID"

#!/usr/bin/env bash
set -Eeuo pipefail

deployment=${DEPLOYMENT:-2xa2}
model=${MODEL:-glm-5.3-flash}
cluster_config="deployments/$deployment/cluster.conf"

node_action() {
  local node=$1 action=${2:-up}
  local node_env="deployments/$deployment/$node.env"
  local topology="deployments/$deployment/topology.yml"
  local model_config="models/$model/compose.yml"
  local file

  for file in "$node_env" "$topology" "$model_config"; do
    [[ -f "$file" ]] || { echo "missing config: $file" >&2; return 1; }
  done

  local dc=(docker-compose --env-file "$node_env" -f compose.yml -f "$topology" -f "$model_config")
  case "$action" in
    up)      "${dc[@]}" up -d ;;
    down)    "${dc[@]}" down ;;
    restart) "${dc[@]}" up -d --force-recreate ;;
    logs)    "${dc[@]}" logs -f --tail=200 inference ;;
    ps)      "${dc[@]}" ps ;;
    *) echo "action must be up, down, restart, logs, or ps" >&2; return 1 ;;
  esac
}

if [[ ${1:-} == --local ]]; then
  node_action "${2:?node is required}" "${3:-up}"
  exit
fi

# 兼容原来的单节点用法。
if [[ ${1:-} == node* ]]; then
  node_action "$1" "${2:-up}"
  exit
fi

action=${1:-up}
[[ "$action" =~ ^(up|down|restart|ps)$ ]] || {
  echo "usage: bash run.sh [up|down|restart|ps]" >&2
  echo "       bash run.sh NODE [up|down|restart|logs|ps]" >&2
  exit 1
}
[[ -f "$cluster_config" ]] || { echo "missing config: $cluster_config" >&2; exit 1; }
# shellcheck source=/dev/null
source "$cluster_config"
: "${SSH_USER:?SSH_USER is required in $cluster_config}"
: "${REMOTE_PROJECT_DIR:?REMOTE_PROJECT_DIR is required in $cluster_config}"
: "${SSH_PORT:=22}"
(( ${#NODES[@]} > 0 )) || { echo "NODES is empty in $cluster_config" >&2; exit 1; }

# Recreating both nodes concurrently can let an old remote engine and its
# replacement connect to node0 with the same DP rank. Stop the whole cluster
# first so every distributed startup begins from one clean generation.
if [[ "$action" == restart ]]; then
  DEPLOYMENT="$deployment" MODEL="$model" bash "$0" down
  exec env DEPLOYMENT="$deployment" MODEL="$model" bash "$0" up
fi

pids=()
labels=()
local_ips=""
if command -v hostname >/dev/null 2>&1; then
  local_ips=$(hostname -I 2>/dev/null || true)
fi
if [[ -z "$local_ips" ]] && command -v ip >/dev/null 2>&1; then
  local_ips=$(ip -o -4 addr show 2>/dev/null | awk '{split($4,a,"/"); print a[1]}' | tr '\n' ' ')
fi
for node in "${NODES[@]}"; do
  node_env="deployments/$deployment/$node.env"
  [[ -f "$node_env" ]] || { echo "missing config: $node_env" >&2; exit 1; }
  node_ip=$(sed -n 's/^NODE_IP=//p' "$node_env" | tail -1)
  [[ -n "$node_ip" ]] || { echo "NODE_IP is missing in $node_env" >&2; exit 1; }

  echo "[$node@$node_ip] $action"
  if [[ " $local_ips " == *" $node_ip "* ]]; then
    node_action "$node" "$action" \
      > >(sed "s/^/[$node] /") 2> >(sed "s/^/[$node] /" >&2) &
  else
    printf -v remote_cmd 'cd %q && DEPLOYMENT=%q MODEL=%q bash run.sh --local %q %q' \
      "$REMOTE_PROJECT_DIR" "$deployment" "$model" "$node" "$action"
    ssh -p "$SSH_PORT" "${SSH_OPTIONS[@]}" "$SSH_USER@$node_ip" "$remote_cmd" \
      > >(sed "s/^/[$node] /") 2> >(sed "s/^/[$node] /" >&2) &
  fi
  pids+=("$!")
  labels+=("$node")
done

failed=0
for i in "${!pids[@]}"; do
  if ! wait "${pids[$i]}"; then
    echo "[${labels[$i]}] command failed" >&2
    failed=1
  fi
done
exit "$failed"

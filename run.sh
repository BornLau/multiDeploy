#!/usr/bin/env bash
set -Eeuo pipefail

node=${1:?usage: bash run.sh NODE [up|down|logs|ps|restart]}
action=${2:-up}
deployment=${DEPLOYMENT:-2xa2}
model=${MODEL:-glm-5.3-flash}
node_env="deployments/$deployment/$node.env"
topology="deployments/$deployment/topology.yml"
model_config="models/$model/compose.yml"

for file in "$node_env" "$topology" "$model_config"; do
  [[ -f "$file" ]] || { echo "missing config: $file" >&2; exit 1; }
done

dc=(docker-compose --env-file "$node_env" -f compose.yml -f "$topology" -f "$model_config")
case "$action" in
  up)      "${dc[@]}" up -d ;;
  down)    "${dc[@]}" down ;;
  restart) "${dc[@]}" up -d --force-recreate ;;
  logs)    "${dc[@]}" logs -f --tail=200 inference ;;
  ps)      "${dc[@]}" ps ;;
  *) echo "action must be up, down, restart, logs, or ps" >&2; exit 1 ;;
esac

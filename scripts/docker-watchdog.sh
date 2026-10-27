#!/usr/bin/env bash
set -Eeuo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

lock_file="/run/self-vps-docker-watchdog.lock"
exec 9>"$lock_file"
flock -n 9 || exit 0

log() {
  printf '%s self-vps-docker-watchdog: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

check_port() {
  ss -lntH "( sport = :$1 )" 2>/dev/null | grep -q .
}

check_http() {
  curl --fail --silent --show-error --max-time 5 "$1" >/dev/null 2>&1
}

docker_chain_ok() {
  iptables -S DOCKER >/dev/null 2>&1
}

uptime_compose="/opt/uptime-kuma/compose.yml"
beszel_compose="/opt/beszel/compose.yml"

if ! systemctl is-active --quiet docker; then
  log "docker is not active; starting it"
  systemctl start docker
  sleep 8
fi

chain_ok=0
docker_chain_ok && chain_ok=1
port_3001=0
port_8090=0
check_port 3001 && port_3001=1
check_port 8090 && port_8090=1

if ((chain_ok)) && ((port_3001)) && ((port_8090)); then
  if check_http http://127.0.0.1:3001/ && check_http http://127.0.0.1:8090/api/health; then
    log "healthy: DOCKER chain and monitoring ports are present"
    exit 0
  fi
fi

# If the chain is missing but the existing published ports still work, do not
# restart every container just to repair a future port-mapping problem. Log it
# and let the operator/Uptime Kuma decide; a restart can be disruptive.
if ! ((chain_ok)) && ((port_3001)) && ((port_8090)); then
  if check_http http://127.0.0.1:3001/ && check_http http://127.0.0.1:8090/api/health; then
    log "warning: DOCKER chain is missing, but existing monitoring ports are healthy"
    exit 0
  fi
fi

log "monitoring degraded: chain=$chain_ok port3001=$port_3001 port8090=$port_8090"

# The known recovery path: Docker restart recreates DOCKER, then compose
# recreates the affected container so published ports are programmed again.
if ! ((chain_ok)); then
  log "restarting docker to recreate the DOCKER chain"
  systemctl restart docker
  sleep 8
fi

if ! docker_chain_ok; then
  log "DOCKER chain is still missing after docker restart"
  exit 1
fi

if [[ -f "$uptime_compose" ]]; then
  log "ensuring uptime-kuma is up"
  docker compose -f "$uptime_compose" up -d
fi
if [[ -f "$beszel_compose" ]]; then
  log "ensuring beszel is up"
  docker compose -f "$beszel_compose" up -d
fi

if ! check_port 3001 && [[ -f "$uptime_compose" ]]; then
  log "recreating uptime-kuma to restore its published port"
  docker compose -f "$uptime_compose" up -d --force-recreate uptime-kuma
fi
if ! check_port 8090 && [[ -f "$beszel_compose" ]]; then
  log "recreating beszel to restore its published port"
  docker compose -f "$beszel_compose" up -d --force-recreate beszel
fi

sleep 5

ok=1
check_port 3001 || ok=0
check_port 8090 || ok=0
check_http http://127.0.0.1:3001/ || ok=0
check_http http://127.0.0.1:8090/api/health || ok=0

if ((ok)); then
  log "recovery completed"
  exit 0
fi

log "recovery did not restore all monitoring checks"
exit 1

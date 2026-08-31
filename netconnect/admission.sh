#!/bin/sh
# netconnect admission controller (runs in the docker:cli sidecar).
#
# Auto-attaches every traefik.enable=true container to the gateway network so
# Traefik can reach it by name — BUT enforces "at most one exporter per DB
# entrypoint" for postgres/mysql/redis/mongodb. Those TCP entrypoints route with
# HostSNI(`*`), so only one backend per port is meaningful.
#
# Policy: reject-extras. The incumbent is never evicted; a second container
# claiming an already-taken DB entrypoint is refused (not attached) and a loud
# warning tells the user to keep traefik.enable=true on only one and disable the
# rest. Self-heals on the next start/stop once labels are fixed.
#
# `admission.sh check` prints a one-shot status report (used by `make check`).
set -u

NET=traefik-gateway-net
DB_EPS="postgres mysql redis mongodb"

# entrypoints claimed by a container's TCP routers (space-separated)
claimed_eps() {
  docker inspect "$1" --format '{{json .Config.Labels}}' 2>/dev/null \
    | grep -oE '"traefik\.tcp\.routers\.[^"]*\.entrypoints":"[^"]*"' \
    | sed -E 's/.*:"([^"]*)"$/\1/' | tr ',' ' '
}

# the DB entrypoints (subset of DB_EPS) a container claims
db_eps_of() {
  for e in $(claimed_eps "$1"); do
    case " $DB_EPS " in *" $e "*) echo "$e" ;; esac
  done
}

# is the container attached to the gateway network?
attached() {
  [ -n "$(docker inspect "$1" --format "{{if index .NetworkSettings.Networks \"$NET\"}}1{{end}}" 2>/dev/null)" ]
}

# host directory of the compose project that owns $1 (so you can cd there to
# stop/adjust it). Falls back to the config file's dir, then "(non-compose)".
workdir_of() {
  d="$(docker inspect "$1" --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null)"
  if [ -z "$d" ]; then
    cf="$(docker inspect "$1" --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' 2>/dev/null)"
    [ -n "$cf" ] && d="$(dirname "${cf%%,*}")"
  fi
  [ -n "$d" ] && echo "$d" || echo "(non-compose)"
}

# name of an already-attached container holding entrypoint $1 (excluding $2)
holder_of() {
  ep="$1"; excl="$2"
  docker ps --filter label=traefik.enable=true --format '{{.Names}}' | while read n; do
    [ "$n" = "$excl" ] && continue
    attached "$n" || continue
    for e in $(db_eps_of "$n"); do
      if [ "$e" = "$ep" ]; then echo "$n"; break; fi
    done
  done | head -n1
}

warn_conflict() {   # $1=ep  $2=incumbent  $3=rejected
  echo "────────────────────────────────────────────────────────────"
  echo "⚠️  [$1] entrypoint 已被 '$2' 佔用，拒絕接入 '$3'。"
  echo "    postgres/mysql/redis/mongodb 每個 entrypoint 只能 export 一顆。"
  echo "    請保留其中一顆 traefik.enable=true，另一顆改為 false，"
  echo "    再重建該容器（改對應專案的 compose）。"
  echo "────────────────────────────────────────────────────────────"
}

# attach one container, honouring the at-most-one-per-DB-entrypoint rule
admit() {
  n="$1"
  dbeps="$(db_eps_of "$n")"
  if [ -z "$dbeps" ]; then
    docker network connect "$NET" "$n" 2>/dev/null || true   # web/other: always attach
    return
  fi
  for e in $dbeps; do
    h="$(holder_of "$e" "$n")"
    if [ -n "$h" ]; then
      warn_conflict "$e" "$h" "$n"
      return   # reject the whole container; do not attach
    fi
  done
  docker network connect "$NET" "$n" 2>/dev/null || true
}

# one-shot status report — shows the holder container and its compose directory
# (cd there to stop or fix the labels).
report() {
  echo "DB entrypoint export 狀態 (network: $NET):"
  echo "  ENTRYPOINT  CONTAINER            DIR"
  for e in $DB_EPS; do
    holders=""
    for n in $(docker ps --filter label=traefik.enable=true --format '{{.Names}}'); do
      for x in $(db_eps_of "$n"); do
        if [ "$x" = "$e" ] && attached "$n"; then holders="$holders $n"; fi
      done
    done
    # shellcheck disable=SC2086
    set -- $holders
    if [ "$#" -eq 0 ]; then
      printf '  %-11s %-20s %s\n' "$e" "-" "-"
    elif [ "$#" -eq 1 ]; then
      printf '  %-11s %-20s %s\n' "$e" "$1" "$(workdir_of "$1")"
    else
      printf '  %-11s ⚠️  衝突:\n' "$e"
      for n in "$@"; do
        printf '  %-11s   %-18s %s\n' "" "$n" "$(workdir_of "$n")"
      done
    fi
  done
}

if [ "${1:-}" = "check" ]; then
  report
  exit 0
fi

# ---- daemon ----
echo "netconnect admission controller up — reject-extras for: $DB_EPS"

# reconcile existing containers (leave already-attached incumbents untouched)
for n in $(docker ps --filter label=traefik.enable=true --format '{{.Names}}'); do
  attached "$n" && continue
  admit "$n"
done

# surface any pre-existing duplicates (not evicted, per reject-extras)
r="$(report)"
if echo "$r" | grep -q '衝突'; then
  echo "$r" | grep '衝突'
fi

# react to new container starts
docker events --filter event=start --filter label=traefik.enable=true \
  --format '{{.Actor.Attributes.name}}' | while read n; do
  admit "$n"
done

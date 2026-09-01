#!/bin/sh
# netconnect admission controller (runs in the docker:cli sidecar).
#
# Auto-attaches every traefik.enable=true container to the gateway network so
# Traefik can reach it by name. For the DB TCP entrypoints (postgres/mysql/redis/
# mongodb) only ONE backend per port is meaningful, so it also nudges toward
# one-exporter-per-entrypoint.
#
# IMPORTANT — what network attachment can and cannot do:
#   Traefik's docker provider builds a TCP router from a container's LABELS
#   regardless of network membership; attachment only decides which IP it uses.
#   So two containers both labelled for `postgres` yield two HostSNI(`*`) routers
#   of equal priority, and Traefik picks between them non-deterministically (one
#   may even point at an unreachable IP). Network gating alone therefore CANNOT
#   pin routing to a chosen backend.
#
# Deterministic pinning is done by the file provider instead: `make pin` writes
# dynamic/pin-<ep>.yaml with a high-priority router → the chosen container, which
# wins over every docker router. This controller's only pin duty is to keep the
# pinned container ATTACHED (so that file router's backend is reachable) and to
# never evict it. Pins are recorded in pins.conf (read here; written by make pin).
#
# Subcommands: `admission.sh check` prints a status report (make check);
#              `admission.sh reconcile` re-attaches pinned + pending containers.
set -u

NET=traefik-gateway-net
DB_EPS="postgres mysql redis mongodb"
PINS="$(dirname "$0")/pins.conf"   # lines: <entrypoint>=<container-name>

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

# host directory of the compose project that owns $1 (cd there to stop/adjust it)
workdir_of() {
  d="$(docker inspect "$1" --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null)"
  if [ -z "$d" ]; then
    cf="$(docker inspect "$1" --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' 2>/dev/null)"
    [ -n "$cf" ] && d="$(dirname "${cf%%,*}")"
  fi
  [ -n "$d" ] && echo "$d" || echo "(non-compose)"
}

# container pinned to entrypoint $1 (empty if none). Last matching line wins.
pinned_for() {
  [ -f "$PINS" ] || return 0
  grep -E "^[[:space:]]*$1[[:space:]]*=" "$PINS" 2>/dev/null \
    | grep -vE '^[[:space:]]*#' \
    | sed -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//; s/[[:space:]]*\$//" \
    | tail -n1
}

# running containers (enable=true) that claim entrypoint $1
claimants_of() {
  for n in $(docker ps --filter label=traefik.enable=true --format '{{.Names}}'); do
    for e in $(db_eps_of "$n"); do
      [ "$e" = "$1" ] && { echo "$n"; break; }
    done
  done
}

# name of an already-attached claimant of entrypoint $1 (excluding $2)
holder_of() {
  ep="$1"; excl="$2"
  for n in $(claimants_of "$ep"); do
    [ "$n" = "$excl" ] && continue
    attached "$n" && { echo "$n"; return; }
  done
}

warn_conflict() {   # $1=ep  $2=incumbent  $3=rejected
  echo "────────────────────────────────────────────────────────────"
  echo "⚠️  [$1] entrypoint 已被 '$2' 佔用，拒絕接入 '$3'。"
  echo "    postgres/mysql/redis/mongodb 每個 entrypoint 只能 export 一顆。"
  echo "    保留一顆、其餘 enable=false 再重建；或用 'make pin DB=$1' 指定一顆。"
  echo "────────────────────────────────────────────────────────────"
}

# attach one container: pinned containers are always admitted; otherwise the
# usual reject-extras (first claimant of a DB entrypoint wins the attach).
admit() {
  n="$1"
  dbeps="$(db_eps_of "$n")"
  if [ -z "$dbeps" ]; then
    docker network connect "$NET" "$n" 2>/dev/null || true   # web/other: always attach
    return
  fi
  for e in $dbeps; do
    if [ "$(pinned_for "$e")" = "$n" ]; then
      docker network connect "$NET" "$n" 2>/dev/null || true   # pinned: always reachable
      return
    fi
  done
  for e in $dbeps; do
    h="$(holder_of "$e" "$n")"
    if [ -n "$h" ]; then
      warn_conflict "$e" "$h" "$n"
      return
    fi
  done
  docker network connect "$NET" "$n" 2>/dev/null || true
}

# make sure every pinned container is attached (its file router needs it routable)
attach_pins() {
  [ -f "$PINS" ] || return 0
  for e in $DB_EPS; do
    p="$(pinned_for "$e")"
    [ -n "$p" ] || continue
    if docker ps --format '{{.Names}}' | grep -qx "$p"; then
      attached "$p" || { echo "  pin[$e]: 接入 '$p'"; docker network connect "$NET" "$p" 2>/dev/null || true; }
    else
      echo "  pin[$e]: ⚠️  指定的 '$p' 未在運行"
    fi
  done
}

# one-shot status report — reports what ACTUALLY determines routing, not just who
# is attached. A pin is authoritative; a lone claimant routes deterministically;
# multiple unpinned claimants mean Traefik picks non-deterministically.
report() {
  echo "DB entrypoint 路由狀態 (network: $NET):"
  echo "  ENTRYPOINT  TARGET               DIR / 說明"
  for e in $DB_EPS; do
    p="$(pinned_for "$e")"
    # shellcheck disable=SC2046
    set -- $(claimants_of "$e")
    if [ -n "$p" ]; then
      if docker ps --format '{{.Names}}' | grep -qx "$p"; then
        note="$(workdir_of "$p")"; attached "$p" || note="$note  ⚠️未接上"
        printf '  %-11s %-20s %s  (pinned)\n' "$e" "$p" "$note"
      else
        printf '  %-11s %-20s %s\n' "$e" "-" "(pinned→$p 未運行)"
      fi
    elif [ "$#" -eq 0 ]; then
      printf '  %-11s %-20s %s\n' "$e" "-" "-"
    elif [ "$#" -eq 1 ]; then
      note="$(workdir_of "$1")"; attached "$1" || note="$note  ⚠️未接上(黑洞)"
      printf '  %-11s %-20s %s\n' "$e" "$1" "$note"
    else
      printf '  %-11s %-20s %s\n' "$e" "⚠️ $# claimant" "路由不確定，請 make pin DB=$e 指定一顆："
      for n in "$@"; do
        printf '  %-11s   %-18s %s\n' "" "$n" "$(workdir_of "$n")"
      done
    fi
  done
}

# apply pins, then attach any still-unattached claimants
reconcile() {
  attach_pins
  for n in $(docker ps --filter label=traefik.enable=true --format '{{.Names}}'); do
    attached "$n" && continue
    admit "$n"
  done
}

case "${1:-}" in
  check)     report; exit 0 ;;
  reconcile) reconcile; exit 0 ;;
esac

# ---- daemon ----
echo "netconnect admission controller up — reject-extras for: $DB_EPS"

reconcile

# surface any non-deterministic (unpinned, multi-claimant) entrypoints
r="$(report)"
if echo "$r" | grep -q '路由不確定'; then
  echo "$r" | grep -A1 '路由不確定'
fi

# react to new container starts
docker events --filter event=start --filter label=traefik.enable=true \
  --format '{{.Actor.Attributes.name}}' | while read n; do
  admit "$n"
done

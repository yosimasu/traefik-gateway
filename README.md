# Local Dev Gateway (Traefik)

A local [Traefik](https://traefik.io/) reverse proxy that routes `*.lvh.me` to
your workspace containers over **local HTTPS**, so services need **no published
host ports** — only the gateway does. Meant to sit running in the background;
every project just adds `traefik.*` labels.

- `*.lvh.me` resolves to `127.0.0.1` (public DNS), so no `/etc/hosts` edits.
- TLS via a [mkcert](https://github.com/FiloSottile/mkcert)-issued wildcard cert
  for `*.lvh.me` (Let's Encrypt can't issue for a domain you don't own).
- A `netconnect` sidecar auto-attaches any `traefik.enable=true` container to
  the gateway network — projects don't declare the external network themselves.
- Opt-in only: a container is ignored unless it sets `traefik.enable=true`.

## Prerequisites

Docker runs via **[Colima](https://github.com/abiosoft/colima)** (not Docker
Desktop). `make` checks these and stops with a hint if missing:

```sh
brew install colima docker docker-compose mkcert nss
colima start
```

## Quick start

```sh
make init    # trust mkcert CA, issue the *.lvh.me cert, create the network
make up      # start the gateway
```

Dashboard: <http://localhost:8080>

## Onboarding a service

### Web (HTTP / HTTPS)

```yaml
services:
  redmine:
    image: redmine
    labels:
      - traefik.enable=true
      - traefik.http.routers.redmine.rule=Host(`redmine.lvh.me`)
      - traefik.http.routers.redmine.entrypoints=websecure
      - traefik.http.routers.redmine.tls=true
      - traefik.http.services.redmine.loadbalancer.server.port=3000
```

Then open <https://redmine.lvh.me>. Omitting the `rule` label falls back to
`Host(`<service>-<project>.lvh.me`)`. Plain HTTP is auto-redirected to HTTPS.

### Database (TCP)

Databases go over plain TCP on the matching entrypoint. Use `HostSNI(`*`)` — the
backend stays plaintext and clients connect to `localhost:<port>` normally:

```yaml
services:
  db:
    image: postgres:16
    labels:
      - traefik.enable=true
      - traefik.tcp.routers.pg.entrypoints=postgres    # postgres|mysql|redis|mongodb
      - traefik.tcp.routers.pg.rule=HostSNI(`*`)
      - traefik.tcp.services.pg.loadbalancer.server.port=5432
```

> **One instance per port.** Traefik **cannot** multiplex several
> Postgres/MySQL on one port by hostname — they use STARTTLS / server-speaks-
> first, so there is no TLS SNI to route on. If you need many DBs at once, give
> them distinct ports or use a protocol-aware proxy (pgbouncer/pgcat). Redis and
> MongoDB *can* be SNI-multiplexed if you enable implicit TLS on the client
> (`rediss://` / `tls=true`), but that isn't wired up by default here.

## Routing behaviour

| Entrypoint | Service up | Service down |
|---|---|---|
| HTTP / HTTPS (80, 443) | forwards to the container | **502 Bad Gateway** (catch-all fallback) |
| PostgreSQL (5432) | plain TCP to the DB | connection closed by server |
| MySQL (3306) | plain TCP to the DB | connection closed by server |
| Redis (6379) | plain TCP to Redis | connection closed by server |
| MongoDB (27017) | plain TCP to Mongo | connection closed by server |

The 502 (instead of Traefik's default 404) comes from a lowest-priority
catch-all router in `dynamic/fallback.yaml` pointing at a dead-end, so a typo'd
or not-yet-started `*.lvh.me` reads as "backend down", not "unknown host".

## Make targets

| Target | Does |
|---|---|
| `make init` | first-run: trust CA, issue cert, create `traefik-gateway-net` |
| `make up` | start the gateway |
| `make down` | stop it |
| `make restart` | recreate the traefik container (needed after command/entrypoint changes) |
| `make logs` | follow logs (watch the sidecar attach containers) |
| `make clean` | remove the generated certs (keeps the trusted CA) |

## Layout

```
.traefik-gateway/
├── compose.yaml           # traefik + netconnect sidecar
├── Makefile               # lifecycle + preflight checks
├── dynamic/
│   ├── tls.yaml           # mkcert wildcard as the default cert
│   └── fallback.yaml      # HTTP 502 catch-all
└── certs/                 # mkcert output (gitignored)
```

## Troubleshooting

- **`make` says docker/mkcert missing** — install per *Prerequisites*; if the
  daemon is unreachable, run `colima start`.
- **Edited `dynamic/*.yaml` but nothing changed** — macOS Colima bind-mounts
  don't reliably deliver file-watch events for *new* files. Run `make restart`.
- **A service returns 504 after moving/renaming networks** — the container is
  attached to a stale network and Traefik cached the wrong IP. Disconnect it
  from the old network and `make restart`.
- **Dashboard/API** — `curl -s localhost:8080/api/http/routers` lists routers;
  `.../api/http/services` shows the backend IP each router resolved to.

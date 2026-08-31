# Gateway verification stack

A self-contained `compose.yaml` a colleague can run to confirm the gateway works.
It declares **no** gateway network — the `netconnect` sidecar auto-attaches every
`traefik.enable=true` container, which is exactly what we want to verify.

## Prerequisites

- The gateway is up: from `~/.traefik-gateway`, `make init` once, then `make up`.
- For a green padlock (optional), `mkcert -install` was run so the local CA is
  trusted. Otherwise use `curl -k` / accept the browser warning.

## Bring it up

```bash
cd examples/verify
docker compose up -d
```

`pg-primary` starts before `pg-extra` (via `depends_on`), so `pg-primary` is the
deterministic incumbent on the `postgres` entrypoint.

## 1. HTTPS host routing — `https://demo.lvh.me`

`demo.lvh.me` resolves to `127.0.0.1`; no `/etc/hosts` edit needed.

```bash
curl -k https://demo.lvh.me
```

Expect a `whoami` dump (`Hostname: demo-web`, the request headers, etc.). A 200
through Traefik proves: TLS termination with the mkcert wildcard, Host routing,
and that netconnect attached `demo-web` without the service declaring any network.

Sanity contrast — an unrouted host returns the 502 fallback, not a hang or 404:

```bash
curl -k -o /dev/null -w '%{http_code}\n' https://nope.lvh.me   # -> 502
```

## 2. reject-extras — one exporter per DB entrypoint

Both `pg-primary` and `pg-extra` claim `entrypoints=postgres`. The incumbent wins;
the extra is refused (never attached, incumbent never evicted).

```bash
cd ~/.traefik-gateway && make check
```

Expect exactly one holder:

```
DB entrypoint export 狀態 (network: traefik-gateway-net):
  postgres  pg-primary
  mysql     -
  redis     -
  mongodb   -
```

See the refusal warning in the sidecar log:

```bash
make logs   # or: docker compose -f ~/.traefik-gateway/compose.yaml logs netconnect
```

```
⚠️  [postgres] entrypoint 已被 'pg-primary' 佔用，拒絕接入 'pg-extra'。
```

Confirm the incumbent actually routes (optional, needs a psql client):

```bash
psql -h localhost -p 5432 -U postgres -c 'select 1;'   # reaches pg-primary
```

### Prove self-heal (optional)

Disable the incumbent and restart the extra — the extra now gets the entrypoint:

```bash
cd examples/verify
docker compose stop pg-primary
docker compose restart pg-extra
cd ~/.traefik-gateway && make check    # postgres -> pg-extra
```

## Tear down

```bash
cd examples/verify
docker compose down
```

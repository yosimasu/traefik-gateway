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

## 2. Two claimants are ambiguous — pin one to make it deterministic

Both `pg-primary` and `pg-extra` claim `entrypoints=postgres`. Traefik builds a
router from each container's labels regardless of network membership, so with two
claimants routing is **non-deterministic** (Traefik may even pick an unreachable
one). `make check` reports this honestly rather than pretending one "holds" it:

```bash
cd ~/.traefik-gateway && make check
```

```
DB entrypoint 路由狀態 (network: traefik-gateway-net):
  ENTRYPOINT  TARGET               DIR / 說明
  postgres    ⚠️ 2 claimant        路由不確定，請 make pin DB=postgres 指定一顆：
                pg-extra           /path/to/examples/verify
                pg-primary         /path/to/examples/verify
  ...
```

Confirm the ambiguity — repeated connects may time out (a black-hole router).
No local `psql` needed; borrow one in a container on the host network:

```bash
for i in 1 2 3; do docker run --rm --network host postgres:16-alpine \
  psql "postgresql://postgres@db.lvh.me:5432/postgres?connect_timeout=4" \
  -tAc 'select inet_server_addr();'; done
```

Now **pin** one and it becomes deterministic:

```bash
make pin                      # pick the DB (postgres), then pick 1 or 2 (q aborts)
make check                    # postgres  <chosen>  ...  (pinned)
```

`make pin` writes a high-priority `dynamic/pin-postgres.yaml` (→ your choice) that
wins over both docker routers, and keeps that container attached. Re-run the loop
above: 3/3 now reach the pinned instance. Switch any time with `make pin` again;
`make unpin DB=postgres` returns to the ambiguous state.

## Tear down

```bash
cd examples/verify
docker compose down
```

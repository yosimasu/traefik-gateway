# Local Traefik gateway — one-command lifecycle.
# Run every target from ~/.traefik-gateway (paths in compose.yaml are relative).
#
#   make init      # first time on a machine: trust CA, issue cert, create network
#   make up        # start the gateway
#   make down      # stop it
#   make restart   # apply config changes (recreates the traefik container)
#   make logs      # follow logs (watch the netconnect sidecar attach containers)
#   make check     # show which container exports each DB entrypoint (+ conflicts)
#   make pin       # interactively pin a DB entrypoint to a chosen container
#   make unpin     # remove that pin (default DB=postgres; override e.g. DB=mysql)
#   make clean     # remove the generated certs (keeps the trusted CA)

COMPOSE := docker compose
NETWORK := traefik-gateway-net
CERT    := certs/lvh.me.pem
KEY     := certs/lvh.me-key.pem
DB      ?= postgres

.PHONY: check-docker check-mkcert init net cert up down restart logs check pin unpin clean

# Preflight: refuse to run until the required tools are installed, with a hint.
check-docker:
	@command -v docker >/dev/null 2>&1 || { \
		echo "✗ docker 未安裝。請先安裝 Colima + docker CLI："; \
		echo "    brew install colima docker docker-compose"; \
		exit 1; }
	@docker info >/dev/null 2>&1 || { \
		echo "✗ docker daemon 未啟動。請先啟動 Colima："; \
		echo "    colima start"; \
		exit 1; }

check-mkcert:
	@command -v mkcert >/dev/null 2>&1 || { \
		echo "✗ mkcert 未安裝。請先安裝（含 Firefox 需要的 nss）："; \
		echo "    brew install mkcert nss"; \
		exit 1; }

# First-run setup: trust the mkcert CA, issue the *.lvh.me wildcard cert, and
# create the external proxy network. Safe to re-run (each step is idempotent).
init: check-docker check-mkcert net cert
	@echo "Ready. Run 'make up' to start the gateway."

# The compose file declares traefik-gateway-net as external, so it must exist first.
net: check-docker
	@docker network inspect $(NETWORK) >/dev/null 2>&1 || docker network create $(NETWORK)

# Let's Encrypt cannot issue for lvh.me (you don't own it) — mkcert signs a
# locally-trusted wildcard instead. Regenerate any time by deleting certs/.
cert: check-mkcert
	@mkdir -p certs
	mkcert -install
	mkcert -cert-file $(CERT) -key-file $(KEY) "*.lvh.me" "lvh.me"
	@echo "Wildcard cert for *.lvh.me generated."

up: net
	$(COMPOSE) up -d

down: check-docker
	$(COMPOSE) down

# --force-recreate picks up entrypoint/command changes (a plain 'up' won't).
restart: net
	$(COMPOSE) up -d --force-recreate

logs: check-docker
	$(COMPOSE) logs -f

# Report which container currently exports each DB entrypoint (and any conflict).
check: check-docker
	@cid=$$($(COMPOSE) ps -q netconnect 2>/dev/null); \
	if [ -n "$$cid" ]; then docker exec "$$cid" sh /netconnect/admission.sh check; \
	else echo "netconnect 未運行，先 make up"; fi

# Pin a DB entrypoint to a specific container (overrides reject-extras). Both
# targets take an optional DB=<postgres|mysql|redis|mongodb> (default postgres).
pin: check-docker
	@sh netconnect/pin-db.sh $(DB)

unpin: check-docker
	@sh netconnect/pin-db.sh $(DB) unpin

clean:
	rm -f certs/*.pem

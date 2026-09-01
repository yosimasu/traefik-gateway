# Local Traefik gateway — one-command lifecycle.
# Run every target from ~/.traefik-gateway (paths in compose.yaml are relative).
# Run `make` (or `make help`) to list the targets.

COMPOSE := docker compose
NETWORK := traefik-gateway-net
CERT    := certs/lvh.me.pem
KEY     := certs/lvh.me-key.pem
DB      ?=

.DEFAULT_GOAL := help
.PHONY: help check-docker check-mkcert init net cert pins up down restart logs check pin unpin clean

# Self-documenting: lists every target that carries a `## ` description, in file
# order. `make` with no target lands here.
help:
	@echo "Local Traefik gateway — targets:"
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-9s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  pin/unpin 不帶參數會先讓你選 DB；也可 DB=<postgres|mysql|redis|mongodb> 直接指定。"

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
init: check-docker check-mkcert net cert pins ## 首次設定：信任 CA、簽發憑證、建立網路（可重複執行）
	@echo "Ready. Run 'make up' to start the gateway."

# The live pins.conf is per-machine (gitignored); seed it from the versioned
# template on first run so the sidecar always has a file to read.
pins:
	@[ -f netconnect/pins.conf ] || { \
		cp netconnect/pins.conf.example netconnect/pins.conf; \
		echo "seeded netconnect/pins.conf from .example"; }

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

up: net pins ## 啟動 gateway
	$(COMPOSE) up -d

down: check-docker ## 停止 gateway
	$(COMPOSE) down

# --force-recreate picks up entrypoint/command changes (a plain 'up' won't).
restart: net pins ## 套用設定變更（重建 traefik/netconnect 容器）
	$(COMPOSE) up -d --force-recreate

logs: check-docker ## 跟看 log（觀察 sidecar 接入容器）
	$(COMPOSE) logs -f

# Report which container currently exports each DB entrypoint (and any conflict).
check: check-docker ## 顯示每個 DB entrypoint 路由到哪顆容器（含歧義提示）
	@cid=$$($(COMPOSE) ps -q netconnect 2>/dev/null); \
	if [ -n "$$cid" ]; then docker exec "$$cid" sh /netconnect/admission.sh check; \
	else echo "netconnect 未運行，先 make up"; fi

# Pin a DB entrypoint to a specific container (overrides reject-extras). Both
# targets take an optional DB=<postgres|mysql|redis|mongodb> (default postgres).
pin: check-docker ## 互動式指定某個 DB entrypoint 連到哪顆容器（先選 DB 再選 instance）
	@sh netconnect/pin-db.sh pin $(DB)

unpin: check-docker ## 移除 pin（先選要解除的 DB）
	@sh netconnect/pin-db.sh unpin $(DB)

clean: ## 刪除產生的憑證（保留已信任的 CA）
	rm -f certs/*.pem

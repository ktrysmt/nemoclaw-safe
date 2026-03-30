# NemoClaw agent management
#
# Targets:
#   make install   Install NemoClaw via nemoclaw-install-safe.sh (clone + build + onboard)
#   make start     Start gateway + services (A:running / B:exited / C:missing)
#   make stop      Stop services + gateway container (sandbox state preserved)
#   make destroy   Destroy sandbox + gateway container (requires make install to recreate)
#   make status    Show sandbox and service status
#   make logs      Tail gateway + sandbox logs
#   make sync      Copy configs to NemoClaw source tree (no restart)
#   make apply     Dynamic policy apply to running sandbox (no restart)
#   make connect   Shell into the sandbox

SHELL := /bin/bash
.DEFAULT_GOAL := help

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
SANDBOX       ?= my-agent
GW_CONTAINER  ?= openshell-cluster-nemoclaw
NEMOCLAW_HOME ?= $(HOME)/.nemoclaw
SOURCE        := $(NEMOCLAW_HOME)/source
BLUEPRINT_DIR := $(SOURCE)/nemoclaw-blueprint
POLICY_DEST   := $(BLUEPRINT_DIR)/policies/openclaw-sandbox.yaml
PRESETS_DEST  := $(BLUEPRINT_DIR)/policies/presets
PROJECT_ROOT  := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

# ---------------------------------------------------------------------------
# help
# ---------------------------------------------------------------------------
.PHONY: help
help:
	@echo ""
	@echo "  NemoClaw agent management"
	@echo ""
	@echo "  make install   Install NemoClaw (nemoclaw-install-safe.sh)"
	@echo "  make start     Start gateway + services (auto-detects state)"
	@echo "  make stop      Stop services + gateway container (state preserved)"
	@echo "  make destroy   Destroy sandbox + gateway (requires make install to recreate)"
	@echo "  make status    Show sandbox and service status"
	@echo "  make logs      Tail logs (gateway + sandbox)"
	@echo "  make sync      Copy configs to NemoClaw source tree"
	@echo "  make apply     Dynamic policy apply (no restart)"
	@echo "  make connect   Shell into sandbox"
	@echo ""

# ---------------------------------------------------------------------------
# install
# ---------------------------------------------------------------------------
.PHONY: install
install:
	@echo "[nemoclaw] Installing NemoClaw..."
	bash $(PROJECT_ROOT)nemoclaw-install-safe.sh

# ---------------------------------------------------------------------------
# sync — copy configs into NemoClaw source tree
# ---------------------------------------------------------------------------
.PHONY: sync
sync:
	@if [ ! -d "$(BLUEPRINT_DIR)" ]; then \
		echo "[nemoclaw] ERROR: $(BLUEPRINT_DIR) not found. Run 'make install' first."; \
		exit 1; \
	fi
	@echo "[nemoclaw] Syncing policies..."
	cp $(PROJECT_ROOT)policies/openclaw-sandbox.yaml $(POLICY_DEST)
	cp $(PROJECT_ROOT)policies/presets/*.yaml $(PRESETS_DEST)/
	@if [ -f "$(PROJECT_ROOT)blueprint.yaml" ]; then \
		echo "[nemoclaw] Syncing blueprint.yaml..."; \
		cp $(PROJECT_ROOT)blueprint.yaml $(BLUEPRINT_DIR)/blueprint.yaml; \
	fi
	@echo "[nemoclaw] Sync complete."

# ---------------------------------------------------------------------------
# apply — dynamic policy set on running sandbox (no restart)
# ---------------------------------------------------------------------------
.PHONY: apply
apply:
	@echo "[nemoclaw] Applying policy to sandbox '$(SANDBOX)'..."
	openshell policy set --policy $(PROJECT_ROOT)policies/openclaw-sandbox.yaml --wait $(SANDBOX)
	@echo "[nemoclaw] Policy applied."

# ---------------------------------------------------------------------------
# start — resume gateway + services based on container state
#   A) running  → sync + nemoclaw start (services only)
#   B) exited   → docker start, wait for ready, sync + nemoclaw start
#   C) missing  → tell user to run make install
# ---------------------------------------------------------------------------
.PHONY: start
start:
	@state=$$(docker inspect -f '{{.State.Status}}' $(GW_CONTAINER) 2>/dev/null || echo "missing"); \
	case "$$state" in \
	  running) \
	    echo "[nemoclaw] Gateway running. Starting services..."; \
	    $(MAKE) sync; \
	    nemoclaw start; \
	    echo "[nemoclaw] Started."; \
	    ;; \
	  exited) \
	    echo "[nemoclaw] Restarting gateway container..."; \
	    docker start $(GW_CONTAINER); \
	    echo "[nemoclaw] Waiting for gateway to become ready..."; \
	    _ready=0; \
	    for i in $$(seq 1 30); do \
	      if openshell status 2>&1 | grep -q Connected; then _ready=1; break; fi; \
	      sleep 2; \
	    done; \
	    if [ "$$_ready" -ne 1 ]; then \
	      echo "[nemoclaw] ERROR: Gateway did not become ready within 60s."; \
	      exit 1; \
	    fi; \
	    $(MAKE) sync; \
	    echo "[nemoclaw] Starting services..."; \
	    nemoclaw start; \
	    echo "[nemoclaw] Started."; \
	    ;; \
	  *) \
	    echo "[nemoclaw] ERROR: Gateway container not found. Run 'make install' first."; \
	    exit 1; \
	    ;; \
	esac

# ---------------------------------------------------------------------------
# stop — stop services + gateway container (sandbox state preserved)
# ---------------------------------------------------------------------------
.PHONY: stop
stop:
	@echo "[nemoclaw] Stopping services..."
	nemoclaw stop
	@echo "[nemoclaw] Stopping gateway container..."
	docker stop $(GW_CONTAINER) 2>/dev/null || true
	@echo "[nemoclaw] Stopped."

# ---------------------------------------------------------------------------
# destroy — stop + destroy sandbox + remove gateway container
# ---------------------------------------------------------------------------
.PHONY: destroy
destroy:
	@echo "[nemoclaw] Destroying sandbox '$(SANDBOX)'..."
	nemoclaw $(SANDBOX) destroy --yes
	@echo "[nemoclaw] Removing gateway container..."
	openshell gateway destroy -g nemoclaw 2>/dev/null || true
	@echo "[nemoclaw] Destroyed. Run 'make install' to recreate."

# ---------------------------------------------------------------------------
# status / logs / connect
# ---------------------------------------------------------------------------
.PHONY: status
status:
	nemoclaw $(SANDBOX) status

.PHONY: logs
logs:
	openshell logs $(SANDBOX) --source all --level debug --tail

.PHONY: connect
connect:
	nemoclaw $(SANDBOX) connect

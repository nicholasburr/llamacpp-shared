# ============================================================================
#  Shared build system for the llama.cpp (ROCm, gfx1151) podman image.
#
#  This Makefile is the single copy for the whole family of repos — shared
#  via git submodule (symlinked into every consumer project). The same
#  targets work everywhere:
#
#     - llamacpp-shared (this repo): `make build` builds the image from the
#       Containerfile and `make sync` tags HEAD with the image tag, so
#       consumers can pin the submodule to a tagged build. There is no
#       model container here, so `deploy`/`logs`/`stop` report that.
#     - consumer projects: everything above, plus `make deploy`, which
#       deploys the model container (quadlet units + user systemd).
#
#  Per-project values (IMAGE_NAME, MODEL, versions) are read from the TAGS
#  file in the CURRENT repo — consumers keep their own TAGS; this repo's
#  TAGS describes the shared image. See TAGS for the image-tag scheme.
#
#  End-user targets (consumers):
#      make deploy     install quadlet units and start the service (user systemd)
#      make status     show container state
#      make logs       follow container logs
#      make stop       stop the service
#
#  Maintainer targets (this repo and consumers):
#      make build             build the active TAGS image
#      make parametric-build  pin a new llama.cpp tag in TAGS (TAG=<tag>)
#      make sync              rewrite the deploy files + tag HEAD
# ============================================================================

SHELL := /bin/bash
MAKEFLAGS += --no-builtin-rules
.DEFAULT_GOAL := help

# ---------------------------------------------------------------------------
#  TAGS is the single source of truth for the image contents (per repo):
#
#      IMAGE_TAG = <LLAMA_TAG>-rocm-<ROCM_VERSION>     e.g. v0.6.0-rocm-10.1.0
#
#  Read KEY=VALUE from TAGS.
# ---------------------------------------------------------------------------

TAGS := TAGS
tagvar = $(strip $(shell awk -F= -v k="$(1)" '$$1==k{print $$2; exit}' $(TAGS) 2>/dev/null))

IMAGE_NAME     := $(call tagvar,IMAGE_NAME)
LLAMA_TAG      := $(call tagvar,LLAMA_TAG)
ROCM_VERSION   := $(call tagvar,ROCM_VERSION)
FEDORA_VERSION := $(call tagvar,FEDORA_VERSION)
MODEL          := $(call tagvar,MODEL)

IMAGE_TAG    := $(LLAMA_TAG)-rocm-$(ROCM_VERSION)
TAGGED_IMAGE := $(IMAGE_NAME):$(IMAGE_TAG)

# Container name defaults to the image name's basename (e.g. qwen3.8-27b for
# localhost/qwen3.8-27b); override with: make deploy CONTAINER_NAME=<name>
CONTAINER_NAME ?= $(notdir $(IMAGE_NAME))

CONTAINERFILE := Containerfile
QUADLET_SRC   := config/containers/systemd/$(CONTAINER_NAME)
DEPLOY_FILES  := compose.yaml \
                 $(QUADLET_SRC)/$(CONTAINER_NAME).build \
                 $(QUADLET_SRC)/$(CONTAINER_NAME).container

# Context detection: consumer repos have quadlet units + a user systemd
# service; this repo has neither. The Makefile is shared, so deploy/logs/
# stop are full recipes in consumers and no-ops here.
HAS_QUADLET := $(shell test -d "$(QUADLET_SRC)" && echo yes)
HAS_SERVICE := $(shell systemctl --user cat "$(CONTAINER_NAME).service" >/dev/null 2>&1 && echo yes)

LLAMA_REPO := https://github.com/ggml-org/llama.cpp.git

.PHONY: help deploy status logs stop sync build parametric-build

help: ## Print this list.
	@echo "image:     $(TAGGED_IMAGE)"
	@echo "container: $(CONTAINER_NAME)"
	@
	@grep -hE '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | \
		awk '{ n=index($$0, ":"); h=index($$0, "## "); \
		       printf "  make %-42s %s\n", substr($$1,1,n-1), substr($$0,h+3) }'

deploy: ## Deploy the container as a systemd service.
ifeq ($(HAS_QUADLET),yes)
	@if podman ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$(CONTAINER_NAME)"; then \
		if ! systemctl --user is-active --quiet $(CONTAINER_NAME).service 2>/dev/null; then \
			echo "REFUSED: a non-systemd container named '$(CONTAINER_NAME)' is present (compose or plain podman)"; \
			echo "         stop it first — podman compose down   — then re-run make deploy"; \
			exit 1; \
		fi \
	fi
	podman quadlet install --application=$(CONTAINER_NAME) --reload-systemd --replace $(QUADLET_SRC)
	systemctl --user start $(CONTAINER_NAME)-build.service
	systemctl --user start $(CONTAINER_NAME).service
	@# Warn if linger is not enabled (services only start at login, not at boot)
	@if ! loginctl show-user "$$USER" -p Linger --value 2>/dev/null | grep -qx yes; then \
		echo; \
		echo "WARNING: linger is not enabled for '$$USER'."; \
		echo "         The services only start at login, NOT at boot."; \
		echo "         To start them at boot (no login required):"; \
		echo "             sudo loginctl enable-linger $$USER"; \
		echo; \
	fi
else
	@echo "no quadlet units in this repo ($(QUADLET_SRC)) — nothing to deploy"
endif

status: ## Display current status of environment.
	@echo "Build configuration:"
	@echo "  IMAGE_NAME : $(TAGGED_IMAGE)"
	@echo "  LLAMA_TAG      : $(LLAMA_TAG)"
	@echo "  ROCM_VERSION   : $(ROCM_VERSION)"
	@echo "  FEDORA_VERSION : $(FEDORA_VERSION)"
	@echo "  MODEL          : $(MODEL)"
	@
	@echo "Available images:"
	@podman image list --filter reference=$(CONTAINER_NAME) --format '  {{.Tag}} | {{.ID}} | {{.CreatedSince}}' | grep -v latest || true
	@
	@echo "Deployed container:"
	@podman ps -a --filter name=^/$(CONTAINER_NAME) --format '  {{.Image}} | {{.ID}} | {{.Status}}' || true

logs: ## Follow systemd logs.
ifeq ($(HAS_SERVICE),yes)
	@journalctl --user -fu $(CONTAINER_NAME).service
else
	@echo "no systemd service '$(CONTAINER_NAME).service' in this repo — nothing to follow"
endif

stop: ## Stop the service
ifeq ($(HAS_SERVICE),yes)
	@systemctl --user stop $(CONTAINER_NAME).service
else
	@echo "no systemd service '$(CONTAINER_NAME).service' in this repo — nothing to stop"
endif

sync: ## Rewrite image tag, build args and model ref; tag HEAD with the image tag.
	@files=""; \
	for f in $(DEPLOY_FILES); do \
		[ -f "$$f" ] && files="$$files $$f"; \
	done; \
	if [ -n "$$files" ]; then \
		echo "syncing deploy files -> $(TAGGED_IMAGE)"; \
		for f in $$files; do \
			sed -i -E "s|$(IMAGE_NAME):[A-Za-z0-9._-]+|$(TAGGED_IMAGE)|g" $$f; \
		done; \
		if [ -f "$(QUADLET_SRC)/$(CONTAINER_NAME).build" ]; then \
			sed -i -E \
				-e "s|^BuildArg=FEDORA_VERSION=.*|BuildArg=FEDORA_VERSION=$(FEDORA_VERSION)|" \
				-e "s|^BuildArg=ROCM_VERSION=.*|BuildArg=ROCM_VERSION=$(ROCM_VERSION)|" \
				-e "s|^BuildArg=BRANCH=.*|BuildArg=TAG=$(LLAMA_TAG)|" \
				-e "s|^BuildArg=TAG=.*|BuildArg=TAG=$(LLAMA_TAG)|" \
				"$(QUADLET_SRC)/$(CONTAINER_NAME).build"; \
		fi; \
		if [ -n "$(MODEL)" ] && [ -f compose.yaml ]; then \
			old=$$(awk -F'"' '/LLAMA_ARG_HF_REPO/{print $$2; exit}' compose.yaml); \
			if [ -n "$$old" ] && [ "$$old" != "$(MODEL)" ]; then \
				echo "syncing model ref: $$old -> $(MODEL)"; \
				for f in $$files; do \
					sed -i "s|$$old|$(MODEL)|g" $$f; \
				done; \
			else \
				echo "model ref already in sync"; \
			fi; \
		else \
			echo "no model to sync (MODEL not set in TAGS / no compose.yaml)"; \
		fi; \
	else \
		echo "no deploy files in this repo — skipping file sync"; \
	fi
	@if git rev-parse -q --verify "refs/tags/$(IMAGE_TAG)" >/dev/null 2>&1; then \
		echo "git tag $(IMAGE_TAG) already exists — leaving it untouched"; \
	else \
		git tag -a "$(IMAGE_TAG)" \
			-m "llama.cpp $(LLAMA_TAG) + ROCm $(ROCM_VERSION) — image $(TAGGED_IMAGE)"; \
		echo "tagged $$(git rev-parse --short HEAD) with $(IMAGE_TAG)"; \
	fi

build: ## Build the active TAGS image, pinned to the commit in TAGS.
	@running=$$(podman inspect "$(CONTAINER_NAME)" --format '{{.Image}}' 2>/dev/null); \
	tagid=$$(podman image inspect "$(TAGGED_IMAGE)" --format '{{.Id}}' 2>/dev/null); \
	if [ -n "$$running" ] && [ -n "$$tagid" ] && [ "$$running" = "$$tagid" ]; then \
		echo "WARNING: $(TAGGED_IMAGE) is what the running '$(CONTAINER_NAME)' container uses —"; \
		echo "         the rebuild replaces it in place (production keeps its current"; \
		echo "         binary until its next restart)."; \
	fi
	podman build -f $(CONTAINERFILE) \
		--build-arg FEDORA_VERSION=$(FEDORA_VERSION) \
		--build-arg ROCM_VERSION=$(ROCM_VERSION) \
		--build-arg TAG=$(LLAMA_TAG) \
		-t $(TAGGED_IMAGE) \
		.

parametric-build: ## Pin a new llama.cpp tag in TAGS: TAG=<v-or-b-tag> [ROCM=x.y.z] [FEDORA=n].
	@test -n "$(TAG)" || { echo "usage: make parametric-build TAG=<v-or-b-tag> [ROCM=x.y.z] [FEDORA=n]"; exit 2; }
	@{ c=$$(git ls-remote $(LLAMA_REPO) "refs/tags/$(TAG)^{}" 2>/dev/null | awk '{print $$1}' | head -1); \
	  [ -n "$$c" ] || c=$$(git ls-remote $(LLAMA_REPO) "refs/tags/$(TAG)" 2>/dev/null | awk '{print $$1}' | head -1); \
	  if [ -z "$$c" ]; then echo "ERROR: tag '$(TAG)' not found on $(LLAMA_REPO)"; exit 2; fi; \
	  sed -i "s|^LLAMA_TAG=.*|LLAMA_TAG=$(TAG)|" $(TAGS); \
	  { test -z "$(ROCM)" || sed -i "s|^ROCM_VERSION=.*|ROCM_VERSION=$(ROCM)|" $(TAGS); }; \
	  { test -z "$(FEDORA)" || sed -i "s|^FEDORA_VERSION=.*|FEDORA_VERSION=$(FEDORA)|" $(TAGS); }; \
	  echo "TAGS updated -> $(IMAGE_NAME):$(TAG)-rocm-$$(awk -F= -v k=ROCM_VERSION '$$1==k{print $$2}' $(TAGS))"; \
	  echo "next: make build && make deploy"; }
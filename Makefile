# SPDX-FileCopyrightText: 2026 Openchip and Software Technologies, S.L.
# SPDX-License-Identifier: Apache-2.0

# IME SDK — build entry point. The build graph is docker-bake.hcl; this
# file passes it the pins rendered from sdk.lock.yaml.
#
#   make                     SDK image, Apptainer image and image archive
#   make sdk                 build the SDK image from source
#   make toolchain | qemu    build one component image from source
#   make clean               delete the Apptainer image, image archive and SDK image
#
# Maintainer targets, see DEVELOPERS.md:
#
#   make lock                resolve components.yaml -> sdk.lock.yaml + build/*/pins.hcl
#   make pins                render build/*/pins.hcl from the existing lock
#   make check               run the guard checks
#   make check-refs          check that the refs still resolve to the lock
#   make hashes              print the component image tags CI looks for
#
# CI reuses component images from GHCR; `make sdk` always builds from source.
#
# Don't set DOCKER_BUILDKIT=0. The Dockerfiles fetch the component repos
# with ADD of git sources and read the components as named build contexts,
# which only BuildKit understands.

LOCK        := sdk.lock.yaml
YQ          := yq
COMPONENTS  := toolchain qemu

VERSION     := $(shell $(YQ) -r '.sdk_version' $(LOCK))
REGISTRY    ?= ghcr.io/openchip-software

# docker-bake.hcl tags the SDK image $(REGISTRY)/riscv-ime-sdk:openchip-v$(VERSION).
# Set IMAGE to use another tag.
IMAGE       ?= $(REGISTRY)/riscv-ime-sdk:openchip-v$(VERSION)

# Base name of the Apptainer image (.sif) and the image archive (.tar.xz),
# matching the default SDK image tag.
DIST        := riscv-ime-sdk-openchip-v$(VERSION)

export REGISTRY
export LOCK_DIGEST := $(shell sha256sum $(LOCK) | cut -d' ' -f1)

BAKE := docker buildx bake -f docker-bake.hcl $(foreach s,$(COMPONENTS) sdk,-f build/$(s)/pins.hcl)
TAG  := $(if $(filter command line,$(origin IMAGE)),--set sdk.tags=$(IMAGE))

.PHONY: all sdk $(COMPONENTS) lock pins check check-refs hashes print clean
.DEFAULT_GOAL := all

all: $(DIST).sif $(DIST).tar.xz

## Resolve components.yaml -> sdk.lock.yaml, then render build/*/pins.hcl
lock:
	./scripts/make-lock.sh

## Render build/*/pins.hcl from the existing lock
pins:
	./scripts/make-lock.sh --render

## Guard: no secrets, no internal hosts, no pins outside the lock, and
## manifest, lock and pins agree
check:
	./scripts/check-pins.sh
	./scripts/check-lock.sh

## Guard: every tag and the base image digest still resolve to the lock.
## Asks the component repos and Docker Hub.
check-refs:
	./scripts/check-refs.sh

sdk:
	$(BAKE) $(TAG) --set sdk.output=type=docker sdk

$(COMPONENTS):
	$(BAKE) $@

## Component image tags: the git tree hash of build/<component> at HEAD.
## Uncommitted changes are not included.
hashes:
	@for c in $(COMPONENTS); do \
	    t=$$(git rev-parse -q --verify "HEAD:build/$$c") || { echo "build/$$c is not in HEAD" >&2; exit 1; }; \
	    echo "$(REGISTRY)/riscv-ime-sdk-$$c:$$t"; \
	done

## Show the resolved bake definition
print:
	@$(BAKE) --print $(TAG) sdk

$(DIST).sif: sdk build/sdk/sdk.def
	# --build-arg templating needs apptainer >= 1.3.
	apptainer build --force --build-arg SDK_IMAGE=$(IMAGE) \
	    --build-arg SDK_VERSION=$(VERSION) $@ build/sdk/sdk.def

$(DIST).tar.xz: sdk
	docker save $(IMAGE) | xz -T0 > $@

## Delete what `make` produces: every Apptainer image and image archive in
## the repo root, and the SDK image tagged IMAGE. BuildKit's
## build cache is shared with other projects and is kept; `docker buildx
## prune` deletes it.
clean:
	rm -f riscv-ime-sdk-*.sif riscv-ime-sdk-*.tar.xz
	if docker image inspect $(IMAGE) >/dev/null 2>&1; then docker image rm $(IMAGE); fi

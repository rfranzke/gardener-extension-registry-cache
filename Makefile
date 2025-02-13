# Copyright (c) 2020 SAP SE or an SAP affiliate company. All rights reserved. This file is licensed under the Apache Software License, v. 2 except as noted otherwise in the LICENSE file
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

EXTENSION_PREFIX            := gardener-extension
NAME                        := registry-cache
ADMISSION_NAME              := $(NAME)-admission
IMAGE                       := eu.gcr.io/gardener-project/gardener/extensions/registry-cache
REPO_ROOT                   := $(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))
HACK_DIR                    := $(REPO_ROOT)/hack
VERSION                     := $(shell cat "$(REPO_ROOT)/VERSION")
LD_FLAGS                    := "-w -X github.com/gardener/$(EXTENSION_PREFIX)-$(NAME)/pkg/version.Version=$(IMAGE_TAG)"
LEADER_ELECTION             := false
IGNORE_OPERATION_ANNOTATION := true


WEBHOOK_CONFIG_PORT	:= 8444
WEBHOOK_CONFIG_MODE	:= url
WEBHOOK_CONFIG_URL	:= host.docker.internal:${WEBHOOK_CONFIG_PORT}
WEBHOOK_CERT_DIR    := ./example/admission
EXTENSION_NAMESPACE	:=

WEBHOOK_PARAM := --webhook-config-url=${WEBHOOK_CONFIG_URL}
ifeq (${WEBHOOK_CONFIG_MODE}, service)
  WEBHOOK_PARAM := --webhook-config-namespace=${EXTENSION_NAMESPACE}
endif

#########################################
# Tools                                 #
#########################################

TOOLS_DIR := hack/tools
include $(REPO_ROOT)/vendor/github.com/gardener/gardener/hack/tools.mk

#########################################
# Rules for local development scenarios #
#########################################

.PHONY: start
start:
	@LEADER_ELECTION_NAMESPACE=garden GO111MODULE=on go run \
		-mod=vendor \
		-ldflags $(LD_FLAGS) \
		./cmd/$(EXTENSION_PREFIX)-$(NAME) \
		--ignore-operation-annotation=$(IGNORE_OPERATION_ANNOTATION) \
		--leader-election=$(LEADER_ELECTION) \
		--config=./example/00-config.yaml \
		--gardener-version="v1.39.0"


.PHONY: start-admission
start-admission:
	@LEADER_ELECTION_NAMESPACE=garden GO111MODULE=on go run \
		-mod=vendor \
		-ldflags ${LD_FLAGS} \
		./cmd/${EXTENSION_PREFIX}-${ADMISSION_NAME} \
		--kubeconfig=dev/garden-kubeconfig.yaml \
		--webhook-config-server-host=0.0.0.0 \
		--webhook-config-server-port=9443 \
		--webhook-config-cert-dir=${WEBHOOK_CERT_DIR}

.PHONY: debug-admission
debug-admission:
	LEADER_ELECTION_NAMESPACE=garden dlv debug \
		./cmd/${EXTENSION_PREFIX}-${ADMISSION_NAME} -- \
		--leader-election=${LEADER_ELECTION} \
		--kubeconfig=dev/garden-kubeconfig.yaml \
		--webhook-config-server-host=0.0.0.0 \
		--webhook-config-server-port=9443 \
		--health-bind-address=:8085 \
		--webhook-config-cert-dir=${WEBHOOK_CERT_DIR}

#################################################################
# Rules related to binary build, Docker image build and release #
#################################################################

.PHONY: install
install:
	@LD_FLAGS="-w -X github.com/gardener/$(EXTENSION_PREFIX)-$(NAME)/pkg/version.Version=$(VERSION)" \
	$(REPO_ROOT)/vendor/github.com/gardener/gardener/hack/install.sh ./cmd/...

.PHONY: docker-login
docker-login:
	@gcloud auth activate-service-account --key-file .kube-secrets/gcr/gcr-readwrite.json

.PHONY: docker-images
docker-images:
	@docker build -t $(IMAGE):$(VERSION) -t $(IMAGE):latest -f Dockerfile -m 6g --target $(NAME) .
	@docker build -t $(IMAGE)-admission:$(VERSION) -t $(IMAGE)-admission:latest -f Dockerfile -m 6g --target $(ADMISSION_NAME) .

#####################################################################
# Rules for verification, formatting, linting, testing and cleaning #
#####################################################################

.PHONY: revendor
revendor:
	@GO111MODULE=on go mod tidy
	@GO111MODULE=on go mod vendor
	@chmod +x $(REPO_ROOT)/vendor/github.com/gardener/gardener/hack/*
	@chmod +x $(REPO_ROOT)/vendor/github.com/gardener/gardener/hack/.ci/*
	@$(REPO_ROOT)/hack/update-github-templates.sh
	@ln -sf ../vendor/github.com/gardener/gardener/hack/cherry-pick-pull.sh $(HACK_DIR)/cherry-pick-pull.sh

.PHONY: clean
clean:
	@$(shell find ./example -type f -name "controller-registration.yaml" -exec rm '{}' \;)
	@$(REPO_ROOT)/vendor/github.com/gardener/gardener/hack/clean.sh ./cmd/... ./pkg/...

.PHONY: check-generate
check-generate:
	@$(REPO_ROOT)/vendor/github.com/gardener/gardener/hack/check-generate.sh $(REPO_ROOT)

.PHONY: check
check: $(GOIMPORTS) $(GOLANGCI_LINT) $(HELM)
	@$(REPO_ROOT)/vendor/github.com/gardener/gardener/hack/check.sh --golangci-lint-config=./.golangci.yaml ./cmd/... ./pkg/...
	@$(REPO_ROOT)/vendor/github.com/gardener/gardener/hack/check-charts.sh ./charts

.PHONY: generate
generate: $(CONTROLLER_GEN) $(GEN_CRD_API_REFERENCE_DOCS) $(HELM) $(MOCKGEN)
	@$(REPO_ROOT)/vendor/github.com/gardener/gardener/hack/generate.sh ./charts/... ./cmd/... ./pkg/...
	$(MAKE) format

.PHONE: generate-in-docker
generate-in-docker:
	docker run --rm -it -v $(PWD):/go/src/github.com/gardener/gardener-extension-registry-cache golang:1.19 \
		sh -c "cd /go/src/github.com/gardener/gardener-extension-registry-cache \
				&& make revendor generate \
				&& chown -R $(shell id -u):$(shell id -g) ."

.PHONY: format
format: $(GOIMPORTS) $(GOIMPORTSREVISER)
	@$(REPO_ROOT)/vendor/github.com/gardener/gardener/hack/format.sh ./cmd ./pkg

.PHONY: test
test:
	@$(REPO_ROOT)/vendor/github.com/gardener/gardener/hack/test.sh ./cmd/... ./pkg/...

.PHONY: test-cov
test-cov:
	@$(REPO_ROOT)/vendor/github.com/gardener/gardener/hack/test-cover.sh ./cmd/... ./pkg/...

.PHONY: test-clean
test-clean:
	@$(REPO_ROOT)/vendor/github.com/gardener/gardener/hack/test-cover-clean.sh

.PHONY: verify
verify: check format test

.PHONY: verify-extended
verify-extended: check-generate check format test-cov test-clean

# use static label for skaffold to prevent rolling all gardener components on every `skaffold` invocation
extension-up extension-down: export SKAFFOLD_LABEL = skaffold.dev/run-id=extension-local

extension-up: $(SKAFFOLD) $(HELM)
	$(SKAFFOLD) run

extension-dev: $(SKAFFOLD) $(HELM)
	$(SKAFFOLD) dev --cleanup=false --trigger=manual

extension-down: $(SKAFFOLD) $(HELM)
	$(SKAFFOLD) delete

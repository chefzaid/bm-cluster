# Invoke from the exact patched upstream source directory with make -f PATH.
SHELL := /bin/sh
.SHELLFLAGS := -eu -c
GO ?= go
OUTPUT_DIR ?= /out
SECURITY_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ESO_MODULE := github.com/external-secrets/external-secrets
UPSTREAM_VERSION := $(shell cat "$(SECURITY_DIR)/UPSTREAM_VERSION")
APPLICATION_VERSION := $(UPSTREAM_VERSION)+security.1
# Preserve all providers while limiting compiler memory for generated Graph
# models if they enter the selected dependency graph. Other packages keep
# their usual optimizations; these flags do not disable or skip any tests.
GRAPH_GCFLAGS := -gcflags=github.com/microsoftgraph/msgraph-sdk-go/models/...=-l \
	-gcflags=github.com/microsoftgraph/msgraph-beta-sdk-go/models/...=-l

.PHONY: security-build security-unit security-controllers
security-build:
	test "$$(git rev-parse 'v$(UPSTREAM_VERSION)^{commit}')" = 279f56c84d5d4058c3bfdeeaf5b1c2febb8851c0
	mkdir -p "$(OUTPUT_DIR)"
	$(GO) build -p 1 $(GRAPH_GCFLAGS) -trimpath -tags all_providers \
		-ldflags='-w -X $(ESO_MODULE)/cmd/controller.version=$(APPLICATION_VERSION)' \
		-o "$(OUTPUT_DIR)/external-secrets" main.go
	chmod 0755 "$(OUTPUT_DIR)/external-secrets"
	$(GO) version -m "$(OUTPUT_DIR)/external-secrets" > "$(OUTPUT_DIR)/buildinfo.txt"
	"$(OUTPUT_DIR)/external-secrets" --version > "$(OUTPUT_DIR)/application-version.txt"
	$(GO) tool nm -size "$(OUTPUT_DIR)/external-secrets" > "$(OUTPUT_DIR)/symbols.txt"
	python3 "$(SECURITY_DIR)/verify-buildinfo.py" "$(OUTPUT_DIR)/buildinfo.txt" \
		"$(OUTPUT_DIR)/application-version.txt" "$(APPLICATION_VERSION)" "$(OUTPUT_DIR)/symbols.txt"

security-unit:
	$(GO) test -p 1 $(GRAPH_GCFLAGS) -short -timeout 30m -tags all_providers ./cmd/controller/... \
		$(ESO_MODULE)/apis/... $(ESO_MODULE)/runtime/... \
		$(ESO_MODULE)/providers/v1/vault/... $(ESO_MODULE)/generators/v1/vault/...

security-controllers:
	test -n "$${KUBEBUILDER_ASSETS:-}" && test -x "$$KUBEBUILDER_ASSETS/kube-apiserver" && test -x "$$KUBEBUILDER_ASSETS/etcd"
	USE_EXISTING_CLUSTER=false $(GO) test -p 1 $(GRAPH_GCFLAGS) -timeout 45m -tags all_providers ./pkg/controllers/...

# Copyright (c) 2023 The Jaeger Authors.
# SPDX-License-Identifier: Apache-2.0

SHELL := /bin/bash
JAEGER_IMPORT_PATH = github.com/jaegertracing/jaeger
STORAGE_PKGS = ./plugin/storage/integration/...
GO = go

include docker/Makefile
include crossdock/rules.mk

# TODO we can compartmentalize this Makefile better, by separting:
#  - thrift and proto builds
#  - integration tests
#  - all the binary building targets

ifeq ($(DEBUG_BINARY),)
	DISABLE_OPTIMIZATIONS =
	SUFFIX =
	TARGET = release
else
	DISABLE_OPTIMIZATIONS = -gcflags="all=-N -l"
	SUFFIX = -debug
	TARGET = debug
endif


# All .go files that are not auto-generated and should be auto-formatted and linted.
ALL_SRC = $(shell find . -name '*.go' \
				   -not -name 'doc.go' \
				   -not -name '_*' \
				   -not -name '.*' \
				   -not -name 'mocks*' \
				   -not -name 'model.pb.go' \
				   -not -name 'model_test.pb.go' \
				   -not -name 'storage_test.pb.go' \
				   -not -path './vendor/*' \
				   -not -path '*/mocks/*' \
				   -not -path '*/*-gen/*' \
				   -not -path '*/thrift-0.9.2/*' \
				   -type f | \
				sort)

# ALL_PKGS is used with 'nocover'
ALL_PKGS = $(shell echo $(dir $(ALL_SRC)) | tr ' ' '\n' | sort -u)

UNAME := $(shell uname -m)
ifeq ($(UNAME), s390x)
# go test does not support -race flag on s390x architecture
	RACE=
else
	RACE=-race
endif
GOOS ?= $(shell $(GO) env GOOS)
GOARCH ?= $(shell $(GO) env GOARCH)
GOBUILD=CGO_ENABLED=0 installsuffix=cgo $(GO) build -trimpath
GOTEST_QUIET=$(GO) test $(RACE)
GOTEST=$(GOTEST_QUIET) -v
GOFMT=gofmt
GOFUMPT=gofumpt
FMT_LOG=.fmt.log
IMPORT_LOG=.import.log
COLORIZE ?= | $(SED) 's/PASS/✅ PASS/g' | $(SED) 's/FAIL/❌ FAIL/g' | $(SED) 's/SKIP/☠️ SKIP/g'

GIT_SHA=$(shell git rev-parse HEAD)
GIT_CLOSEST_TAG=$(shell git describe --abbrev=0 --tags)
ifneq ($(GIT_CLOSEST_TAG),$(shell echo ${GIT_CLOSEST_TAG} | grep -E "$(semver_regex)"))
	$(warning GIT_CLOSEST_TAG=$(GIT_CLOSEST_TAG) is not in the semver format $(semver_regex))
endif
GIT_CLOSEST_TAG_MAJOR := $(shell echo $(GIT_CLOSEST_TAG) | sed -n 's/v\([0-9]*\)\.[0-9]*\.[0-9]/\1/p')
GIT_CLOSEST_TAG_MINOR := $(shell echo $(GIT_CLOSEST_TAG) | sed -n 's/v[0-9]*\.\([0-9]*\)\.[0-9]/\1/p')
GIT_CLOSEST_TAG_PATCH := $(shell echo $(GIT_CLOSEST_TAG) | sed -n 's/v[0-9]*\.[0-9]*\.\([0-9]\)/\1/p')
DATE=$(shell TZ=UTC0 git show --quiet --date='format-local:%Y-%m-%dT%H:%M:%SZ' --format="%cd")
BUILD_INFO_IMPORT_PATH=$(JAEGER_IMPORT_PATH)/pkg/version
BUILD_INFO=-ldflags "-X $(BUILD_INFO_IMPORT_PATH).commitSHA=$(GIT_SHA) -X $(BUILD_INFO_IMPORT_PATH).latestVersion=$(GIT_CLOSEST_TAG) -X $(BUILD_INFO_IMPORT_PATH).date=$(DATE)"

SED=sed
THRIFT_VER=0.14
THRIFT_IMG=jaegertracing/thrift:$(THRIFT_VER)
THRIFT=docker run --rm -u ${shell id -u} -v "${PWD}:/data" $(THRIFT_IMG) thrift
THRIFT_GO_ARGS=thrift_import="github.com/apache/thrift/lib/go/thrift"
THRIFT_GEN_DIR=thrift-gen

SWAGGER_VER=0.27.0
SWAGGER_IMAGE=quay.io/goswagger/swagger:v$(SWAGGER_VER)
SWAGGER=docker run --rm -it -u ${shell id -u} -v "${PWD}:/go/src/" -w /go/src/ $(SWAGGER_IMAGE)
SWAGGER_GEN_DIR=swagger-gen

JAEGER_DOCKER_PROTOBUF=jaegertracing/protobuf:0.4.0

DOCKER_NAMESPACE?=jaegertracing
DOCKER_TAG?=latest

MOCKERY=mockery
GOVERSIONINFO=goversioninfo
SYSOFILE=resource.syso

.DEFAULT_GOAL := test-and-lint

.PHONY: test-and-lint
test-and-lint: test fmt lint

echo-all-pkgs:
	@echo $(ALL_PKGS) | tr ' ' '\n' | sort

echo-all-srcs:
	@echo $(ALL_SRC) | tr ' ' '\n' | sort

.PHONY: clean
clean:
	rm -rf cover*.out .cover/ cover.html $(FMT_LOG) $(IMPORT_LOG) \
		jaeger-ui/packages/jaeger-ui/build
	find ./cmd/query/app/ui/actual -type f -name '*.gz' -delete
	GOCACHE=$(GOCACHE) go clean -cache -testcache
	find cmd -type f -executable | xargs -I{} sh -c '(git ls-files --error-unmatch {} 2>/dev/null || rm -v {})'

.PHONY: test
test:
	bash -c "set -e; set -o pipefail; $(GOTEST) -tags=memory_storage_integration ./... $(COLORIZE)"

.PHONY: all-in-one-integration-test
all-in-one-integration-test:
	TEST_MODE=integration $(GOTEST) ./cmd/all-in-one/

.PHONY: storage-integration-test
storage-integration-test:
	# Expire tests results for storage integration tests since the environment might change
	# even though the code remains the same.
	go clean -testcache
	bash -c "set -e; set -o pipefail; $(GOTEST) -coverpkg=./... -coverprofile cover.out $(STORAGE_PKGS) $(COLORIZE)"

.PHONY: badger-storage-integration-test
badger-storage-integration-test:
	bash -c "set -e; set -o pipefail; $(GOTEST) -tags=badger_storage_integration -coverpkg=./... -coverprofile cover-badger.out $(STORAGE_PKGS) $(COLORIZE)"

.PHONY: grpc-storage-integration-test
grpc-storage-integration-test:
	(cd examples/memstore-plugin/ && go build .)
	bash -c "set -e; set -o pipefail; $(GOTEST) -tags=grpc_storage_integration -coverpkg=./... -coverprofile cover.out $(STORAGE_PKGS) $(COLORIZE)"

.PHONY: index-cleaner-integration-test
index-cleaner-integration-test: docker-images-elastic
	# Expire test results for storage integration tests since the environment might change
	# even though the code remains the same.
	go clean -testcache
	bash -c "set -e; set -o pipefail; $(GOTEST) -tags index_cleaner -coverpkg=./... -coverprofile cover-index-cleaner.out $(STORAGE_PKGS) $(COLORIZE)"

.PHONY: index-rollover-integration-test
index-rollover-integration-test: docker-images-elastic
	# Expire test results for storage integration tests since the environment might change
	# even though the code remains the same.
	go clean -testcache
	bash -c "set -e; set -o pipefail; $(GOTEST) -tags index_rollover -coverpkg=./... -coverprofile cover-index-rollover.out $(STORAGE_PKGS) $(COLORIZE)"

.PHONY: cover
cover: nocover
	$(GOTEST) -tags=memory_storage_integration -timeout 5m -coverprofile cover.out ./...
	go tool cover -html=cover.out -o cover.html

.PHONY: nocover
nocover:
	@echo Verifying that all packages have test files to count in coverage
	@scripts/check-test-files.sh $(ALL_PKGS)

.PHONY: fmt
fmt:
	./scripts/import-order-cleanup.sh inplace
	@echo Running gofmt on ALL_SRC ...
	@$(GOFMT) -e -s -l -w $(ALL_SRC)
	@echo Running gofumpt on ALL_SRC ...
	@$(GOFUMPT) -e -l -w $(ALL_SRC)
	./scripts/updateLicenses.sh

.PHONY: lint
lint:
	golangci-lint -v run
	./scripts/updateLicenses.sh > $(FMT_LOG)
	./scripts/import-order-cleanup.sh stdout > $(IMPORT_LOG)
	@[ ! -s "$(FMT_LOG)" -a ! -s "$(IMPORT_LOG)" ] || (echo "License check or import ordering failures, run 'make fmt'" | cat - $(FMT_LOG) $(IMPORT_LOG) && false)
	./scripts/check-semconv-version.sh
	./scripts/check-go-version.sh

.PHONY: build-examples
build-examples:
	$(GOBUILD) -o ./examples/hotrod/hotrod-$(GOOS)-$(GOARCH) ./examples/hotrod/main.go

.PHONY: build-tracegen
build-tracegen:
	$(GOBUILD) $(BUILD_INFO) -o ./cmd/tracegen/tracegen-$(GOOS)-$(GOARCH) ./cmd/tracegen/

.PHONY: build-anonymizer
build-anonymizer:
	$(GOBUILD) $(BUILD_INFO) -o ./cmd/anonymizer/anonymizer-$(GOOS)-$(GOARCH) $(BUILD_INFO) ./cmd/anonymizer/

.PHONY: build-esmapping-generator
build-esmapping-generator:
	$(GOBUILD) -o ./plugin/storage/es/esmapping-generator-$(GOOS)-$(GOARCH) $(BUILD_INFO) ./cmd/esmapping-generator/

.PHONY: build-esmapping-generator-linux
build-esmapping-generator-linux:
	 GOOS=linux GOARCH=amd64 $(GOBUILD) -o ./plugin/storage/es/esmapping-generator $(BUILD_INFO) ./cmd/esmapping-generator/

.PHONY: build-es-index-cleaner
build-es-index-cleaner:
	$(GOBUILD) -o ./cmd/es-index-cleaner/es-index-cleaner-$(GOOS)-$(GOARCH) ./cmd/es-index-cleaner/

.PHONY: build-es-rollover
build-es-rollover:
	$(GOBUILD) -o ./cmd/es-rollover/es-rollover-$(GOOS)-$(GOARCH) ./cmd/es-rollover/

.PHONY: docker-hotrod
docker-hotrod:
	GOOS=linux $(MAKE) build-examples
	docker build -t $(DOCKER_NAMESPACE)/example-hotrod:${DOCKER_TAG} ./examples/hotrod --build-arg TARGETARCH=$(GOARCH)

.PHONY: run-all-in-one
run-all-in-one: build-ui
	go run -tags ui ./cmd/all-in-one --log-level debug

build-ui: cmd/query/app/ui/actual/index.html.gz

cmd/query/app/ui/actual/index.html.gz: jaeger-ui/packages/jaeger-ui/build/index.html
	# do not delete dot-files
	rm -rf cmd/query/app/ui/actual/*
	cp -r jaeger-ui/packages/jaeger-ui/build/* cmd/query/app/ui/actual/
	find cmd/query/app/ui/actual -type f | grep -v .gitignore | xargs gzip --no-name
	# copy the timestamp for index.html.gz from the original file
	touch -t $$(date -r jaeger-ui/packages/jaeger-ui/build/index.html '+%Y%m%d%H%M.%S') cmd/query/app/ui/actual/index.html.gz
	ls -lF cmd/query/app/ui/actual/

jaeger-ui/packages/jaeger-ui/build/index.html:
	$(MAKE) rebuild-ui

.PHONY: rebuild-ui
rebuild-ui:
	bash ./scripts/rebuild-ui.sh
	@echo "NOTE: This target only rebuilds the UI assets inside jaeger-ui/packages/jaeger-ui/build/."
	@echo "NOTE: To make them usable from query-service run 'make build-ui'."

.PHONY: build-all-in-one-linux
build-all-in-one-linux:
	GOOS=linux $(MAKE) build-all-in-one

# Requires variables: $(BIN_NAME) $(BIN_PATH) $(GO_TAGS) $(DISABLE_OPTIMIZATIONS) $(SUFFIX) $(GOOS) $(GOARCH) $(BUILD_INFO)
# Other targets can depend on this one but with a unique suffix to ensure it is always executed.
BIN_PATH = ./cmd/$(BIN_NAME)
.PHONY: _build-a-binary
_build-a-binary-%:
	$(GOBUILD) $(DISABLE_OPTIMIZATIONS) $(GO_TAGS) -o $(BIN_PATH)/$(BIN_NAME)$(SUFFIX)-$(GOOS)-$(GOARCH) $(BUILD_INFO) $(BIN_PATH)

.PHONY: build-jaeger
build-jaeger: BIN_NAME = jaeger
build-jaeger: GO_TAGS = -tags ui
build-jaeger: build-ui _build-a-binary-jaeger$(SUFFIX)-$(GOOS)-$(GOARCH)

.PHONY: build-all-in-one
build-all-in-one: BIN_NAME = all-in-one
build-all-in-one: GO_TAGS = -tags ui
build-all-in-one: build-ui _build-a-binary-all-in-one$(SUFFIX)-$(GOOS)-$(GOARCH)

.PHONY: build-agent
build-agent: BIN_NAME = agent
build-agent: _build-a-binary-agent$(SUFFIX)-$(GOOS)-$(GOARCH)

.PHONY: build-query
build-query: BIN_NAME = query
build-query: GO_TAGS = -tags ui
build-query: build-ui _build-a-binary-query$(SUFFIX)-$(GOOS)-$(GOARCH)

.PHONY: build-collector
build-collector: BIN_NAME = collector
build-collector: _build-a-binary-collector$(SUFFIX)-$(GOOS)-$(GOARCH)

.PHONY: build-ingester
build-ingester: BIN_NAME = ingester
build-ingester: _build-a-binary-ingester$(SUFFIX)-$(GOOS)-$(GOARCH)

.PHONY: build-remote-storage
build-remote-storage: BIN_NAME = remote-storage
build-remote-storage: _build-a-binary-remote-storage$(SUFFIX)-$(GOOS)-$(GOARCH)

# Magic values:
# - LangID "0409" is "US-English".
# - CharsetID "04B0" translates to decimal 1200 for "Unicode".
# - FileOS "040004" defines the Windows kernel "Windows NT".
# - FileType "01" is "Application".
define VERSIONINFO
{
    "FixedFileInfo": {
        "FileVersion": {
            "Major": $(GIT_CLOSEST_TAG_MAJOR),
            "Minor": $(GIT_CLOSEST_TAG_MINOR),
            "Patch": $(GIT_CLOSEST_TAG_PATCH),
            "Build": 0
        },
        "ProductVersion": {
            "Major": $(GIT_CLOSEST_TAG_MAJOR),
            "Minor": $(GIT_CLOSEST_TAG_MINOR),
            "Patch": $(GIT_CLOSEST_TAG_PATCH),
            "Build": 0
        },
        "FileFlagsMask": "3f",
        "FileFlags ": "00",
        "FileOS": "040004",
        "FileType": "01",
        "FileSubType": "00"
    },
    "StringFileInfo": {
        "FileDescription": "$(NAME)",
        "FileVersion": "$(GIT_CLOSEST_TAG_MAJOR).$(GIT_CLOSEST_TAG_MINOR).$(GIT_CLOSEST_TAG_PATCH).0",
        "LegalCopyright": "2015-2023 The Jaeger Project Authors",
		"ProductName": "$(NAME)",
        "ProductVersion": "$(GIT_CLOSEST_TAG_MAJOR).$(GIT_CLOSEST_TAG_MINOR).$(GIT_CLOSEST_TAG_PATCH).0"
    },
    "VarFileInfo": {
        "Translation": {
            "LangID": "0409",
            "CharsetID": "04B0"
        }
    }
}
endef

export VERSIONINFO

.PHONY: _prepare-winres
_prepare-winres:
	$(MAKE) _prepare-winres-helper NAME="Jaeger Agent"            PKGPATH="cmd/agent"
	$(MAKE) _prepare-winres-helper NAME="Jaeger Collector"        PKGPATH="cmd/collector"
	$(MAKE) _prepare-winres-helper NAME="Jaeger Query"            PKGPATH="cmd/query"
	$(MAKE) _prepare-winres-helper NAME="Jaeger Ingester"         PKGPATH="cmd/ingester"
	$(MAKE) _prepare-winres-helper NAME="Jaeger Remote Storage"   PKGPATH="cmd/remote-storage"
	$(MAKE) _prepare-winres-helper NAME="Jaeger All-In-One"       PKGPATH="cmd/all-in-one"
	$(MAKE) _prepare-winres-helper NAME="Jaeger V2"               PKGPATH="cmd/jaeger"
	$(MAKE) _prepare-winres-helper NAME="Jaeger Tracegen"         PKGPATH="cmd/tracegen"
	$(MAKE) _prepare-winres-helper NAME="Jaeger Anonymizer"       PKGPATH="cmd/anonymizer"
	$(MAKE) _prepare-winres-helper NAME="Jaeger ES-Index-Cleaner" PKGPATH="cmd/es-index-cleaner"
	$(MAKE) _prepare-winres-helper NAME="Jaeger ES-Rollover"      PKGPATH="cmd/es-rollover"

.PHONY: _prepare-winres-helper
_prepare-winres-helper:
	echo $$VERSIONINFO | $(GOVERSIONINFO) -o="$(PKGPATH)/$(SYSOFILE)" -

.PHONY: build-binaries-linux
build-binaries-linux:
	GOOS=linux GOARCH=amd64 $(MAKE) _build-platform-binaries

.PHONY: build-binaries-windows
build-binaries-windows: _prepare-winres
	GOOS=windows GOARCH=amd64 $(MAKE) _build-platform-binaries
	rm ./cmd/*/$(SYSOFILE)

.PHONY: build-binaries-darwin
build-binaries-darwin:
	GOOS=darwin GOARCH=amd64 $(MAKE) _build-platform-binaries

.PHONY: build-binaries-darwin-arm64
build-binaries-darwin-arm64:
	GOOS=darwin GOARCH=arm64 $(MAKE) _build-platform-binaries

.PHONY: build-binaries-s390x
build-binaries-s390x:
	GOOS=linux GOARCH=s390x $(MAKE) _build-platform-binaries

.PHONY: build-binaries-arm64
build-binaries-arm64:
	GOOS=linux GOARCH=arm64 $(MAKE) _build-platform-binaries

.PHONY: build-binaries-ppc64le
build-binaries-ppc64le:
	GOOS=linux GOARCH=ppc64le $(MAKE) _build-platform-binaries

# build all binaries for one specific platform GOOS/GOARCH
.PHONY: _build-platform-binaries
_build-platform-binaries: build-agent \
		build-all-in-one \
		build-collector \
		build-query \
		build-ingester \
		build-jaeger \
		build-remote-storage \
		build-examples \
		build-tracegen \
		build-anonymizer \
		build-esmapping-generator \
		build-es-index-cleaner \
		build-es-rollover
	$(MAKE) _build-platform-binaries-debug GOOS=$(GOOS) GOARCH=$(GOARCH) DEBUG_BINARY=1

# build binaries that support DEBUG release, for one specific platform GOOS/GOARCH
.PHONY: _build-platform-binaries-debug
_build-platform-binaries-debug: build-agent \
	build-collector \
	build-query \
	build-ingester \
	build-remote-storage \
	build-all-in-one \

.PHONY: build-all-platforms
build-all-platforms: \
	build-binaries-linux \
	build-binaries-windows \
	build-binaries-darwin \
	build-binaries-darwin-arm64 \
	build-binaries-s390x \
	build-binaries-arm64 \
	build-binaries-ppc64le

.PHONY: docker-images-cassandra
docker-images-cassandra:
	docker build -t $(DOCKER_NAMESPACE)/jaeger-cassandra-schema:${DOCKER_TAG} plugin/storage/cassandra/
	@echo "Finished building jaeger-cassandra-schema =============="

.PHONY: docker-images-elastic
docker-images-elastic: create-baseimg
	GOOS=linux GOARCH=$(GOARCH) $(MAKE) build-esmapping-generator
	GOOS=linux GOARCH=$(GOARCH) $(MAKE) build-es-index-cleaner
	GOOS=linux GOARCH=$(GOARCH) $(MAKE) build-es-rollover
	docker build -t $(DOCKER_NAMESPACE)/jaeger-es-index-cleaner:${DOCKER_TAG} --build-arg base_image=$(BASE_IMAGE) --build-arg TARGETARCH=$(GOARCH) cmd/es-index-cleaner
	docker build -t $(DOCKER_NAMESPACE)/jaeger-es-rollover:${DOCKER_TAG} --build-arg base_image=$(BASE_IMAGE) --build-arg TARGETARCH=$(GOARCH) cmd/es-rollover
	@echo "Finished building jaeger-es-indices-clean =============="

# TODO does this target need to exist? It's only called from crossdock, apparently.
.PHONY: docker-images-jaeger-backend
docker-images-jaeger-backend: create-baseimg create-debugimg
	for component in "jaeger-agent" "jaeger-collector" "jaeger-query" "jaeger-ingester" "all-in-one" ; do \
		regex="jaeger-(.*)"; \
		component_suffix=$$component; \
		if [[ $$component =~ $$regex ]]; then \
			component_suffix="$${BASH_REMATCH[1]}"; \
		fi; \
		docker buildx build --target $(TARGET) \
			--tag $(DOCKER_NAMESPACE)/$$component$(SUFFIX):${DOCKER_TAG} \
			--build-arg base_image=$(BASE_IMAGE) \
			--build-arg debug_image=$(DEBUG_IMAGE) \
			--build-arg TARGETARCH=$(GOARCH) \
			--load \
			cmd/$$component_suffix; \
		echo "Finished building $$component ==============" ; \
	done;

.PHONY: docker-images-tracegen
docker-images-tracegen:
	docker build -t $(DOCKER_NAMESPACE)/jaeger-tracegen:${DOCKER_TAG} cmd/tracegen/ --build-arg TARGETARCH=$(GOARCH)
	@echo "Finished building jaeger-tracegen =============="

.PHONY: docker-images-anonymizer
docker-images-anonymizer:
	docker build -t $(DOCKER_NAMESPACE)/jaeger-anonymizer:${DOCKER_TAG} cmd/anonymizer/ --build-arg TARGETARCH=$(GOARCH)
	@echo "Finished building jaeger-anonymizer =============="

.PHONY: build-crossdock-binary
build-crossdock-binary:
	$(GOBUILD) -o ./crossdock/crossdock-$(GOOS)-$(GOARCH) ./crossdock/main.go

.PHONY: build-crossdock-linux
build-crossdock-linux:
	GOOS=linux $(MAKE) build-crossdock-binary

# Crossdock tests do not require fully functioning UI, so we skip it to speed up the build.
.PHONY: build-crossdock-ui-placeholder
build-crossdock-ui-placeholder:
	mkdir -p jaeger-ui/packages/jaeger-ui/build/
	cp cmd/query/app/ui/placeholder/index.html jaeger-ui/packages/jaeger-ui/build/index.html
	$(MAKE) build-ui

.PHONY: build-crossdock
build-crossdock: build-crossdock-ui-placeholder build-binaries-linux build-crossdock-linux docker-images-cassandra docker-images-jaeger-backend
	docker build -t $(DOCKER_NAMESPACE)/test-driver:${DOCKER_TAG} --build-arg TARGETARCH=$(GOARCH) crossdock/
	@echo "Finished building test-driver ==============" ; \

.PHONY: build-and-run-crossdock
build-and-run-crossdock: build-crossdock
	make crossdock

.PHONY: build-crossdock-fresh
build-crossdock-fresh: build-crossdock-linux
	make crossdock-fresh

.PHONY: changelog
changelog:
	./scripts/release-notes.py --exclude-dependabot

.PHONY: draft-release
draft-release:
	./scripts/draft-release.py

.PHONY: install-test-tools
install-test-tools:
	$(GO) install github.com/golangci/golangci-lint/cmd/golangci-lint@v1.52.1
	$(GO) install mvdan.cc/gofumpt@latest

.PHONY: install-build-tools
install-build-tools:
	$(GO) install github.com/josephspurrier/goversioninfo/cmd/goversioninfo@v1.4.0

.PHONY: install-tools
install-tools: install-test-tools install-build-tools
	$(GO) install github.com/vektra/mockery/v2@v2.14.0

.PHONY: install-ci
install-ci: install-test-tools install-build-tools

.PHONY: test-ci
test-ci: GOTEST := $(GOTEST_QUIET)
test-ci: build-examples cover

.PHONY: thrift
thrift: idl/thrift/jaeger.thrift thrift-image
	[ -d $(THRIFT_GEN_DIR) ] || mkdir $(THRIFT_GEN_DIR)
	$(THRIFT) -o /data --gen go:$(THRIFT_GO_ARGS) --out /data/$(THRIFT_GEN_DIR) /data/idl/thrift/agent.thrift
#	TODO sed is GNU and BSD compatible
	sed -i.bak 's|"zipkincore"|"$(JAEGER_IMPORT_PATH)/thrift-gen/zipkincore"|g' $(THRIFT_GEN_DIR)/agent/*.go
	sed -i.bak 's|"jaeger"|"$(JAEGER_IMPORT_PATH)/thrift-gen/jaeger"|g' $(THRIFT_GEN_DIR)/agent/*.go
	$(THRIFT) -o /data --gen go:$(THRIFT_GO_ARGS) --out /data/$(THRIFT_GEN_DIR) /data/idl/thrift/jaeger.thrift
	$(THRIFT) -o /data --gen go:$(THRIFT_GO_ARGS) --out /data/$(THRIFT_GEN_DIR) /data/idl/thrift/sampling.thrift
	$(THRIFT) -o /data --gen go:$(THRIFT_GO_ARGS) --out /data/$(THRIFT_GEN_DIR) /data/idl/thrift/baggage.thrift
	$(THRIFT) -o /data --gen go:$(THRIFT_GO_ARGS) --out /data/$(THRIFT_GEN_DIR) /data/idl/thrift/zipkincore.thrift
	rm -rf thrift-gen/*/*-remote thrift-gen/*/*.bak

idl/thrift/jaeger.thrift:
	$(MAKE) init-submodules

.PHONY: init-submodules
init-submodules:
	git submodule update --init --recursive

.PHONY: thrift-image
thrift-image:
	$(THRIFT) -version

.PHONY: generate-zipkin-swagger
generate-zipkin-swagger: init-submodules
	$(SWAGGER) generate server -f ./idl/swagger/zipkin2-api.yaml -t $(SWAGGER_GEN_DIR) -O PostSpans --exclude-main
	rm $(SWAGGER_GEN_DIR)/restapi/operations/post_spans_urlbuilder.go $(SWAGGER_GEN_DIR)/restapi/server.go $(SWAGGER_GEN_DIR)/restapi/configure_zipkin.go $(SWAGGER_GEN_DIR)/models/trace.go $(SWAGGER_GEN_DIR)/models/list_of_traces.go $(SWAGGER_GEN_DIR)/models/dependency_link.go

.PHONY: generate-mocks
generate-mocks: install-tools
	$(MOCKERY) --all --dir ./pkg/es/ --output ./pkg/es/mocks && rm pkg/es/mocks/ClientBuilder.go
	$(MOCKERY) --all --dir ./storage/spanstore/ --output ./storage/spanstore/mocks
	$(MOCKERY) --all --dir ./proto-gen/storage_v1/ --output ./proto-gen/storage_v1/mocks

.PHONY: echo-version
echo-version:
	@echo $(GIT_CLOSEST_TAG)

PROTO_INTERMEDIATE_DIR = proto-gen/.patched-otel-proto
PROTOC := docker run --rm -u ${shell id -u} -v${PWD}:${PWD} -w${PWD} ${JAEGER_DOCKER_PROTOBUF} --proto_path=${PWD}
PROTO_INCLUDES := \
	-Iidl/proto/api_v2 \
	-Iidl/proto/api_v3 \
	-Imodel/proto/metrics \
	-I$(PROTO_INTERMEDIATE_DIR) \
	-I/usr/include/github.com/gogo/protobuf
# Remapping of std types to gogo types (must not contain spaces)
PROTO_GOGO_MAPPINGS := $(shell echo \
		Mgoogle/protobuf/descriptor.proto=github.com/gogo/protobuf/types, \
		Mgoogle/protobuf/timestamp.proto=github.com/gogo/protobuf/types, \
		Mgoogle/protobuf/duration.proto=github.com/gogo/protobuf/types, \
		Mgoogle/protobuf/empty.proto=github.com/gogo/protobuf/types, \
		Mgoogle/api/annotations.proto=github.com/gogo/googleapis/google/api, \
		Mmodel.proto=github.com/jaegertracing/jaeger/model \
	| sed 's/ //g')

.PHONY: proto
proto: proto-prepare-otel
	# Generate gogo, swagger, go-validators, gRPC-storage-plugin output.
	#
	# -I declares import folders, in order of importance
	# This is how proto resolves the protofile imports.
	# It will check for the protofile relative to each of these
	# folders and use the first one it finds.
	#
	# --gogo_out generates GoGo Protobuf output with gRPC plugin enabled.
	# --govalidators_out generates Go validation files for our messages types, if specified.
	#
	# The lines starting with Mgoogle/... are proto import replacements,
	# which cause the generated file to import the specified packages
	# instead of the go_package's declared by the imported protof files.
	#
	# $$GOPATH/src is the output directory. It is relative to the GOPATH/src directory
	# since we've specified a go_package option relative to that directory.
	#
	# model/proto/jaeger.proto is the location of the protofile we use.
	#
	$(PROTOC) \
		$(PROTO_INCLUDES) \
		--gogo_out=plugins=grpc,$(PROTO_GOGO_MAPPINGS):$(PWD)/model/ \
		idl/proto/api_v2/model.proto

	$(PROTOC) \
		$(PROTO_INCLUDES) \
		--gogo_out=plugins=grpc,$(PROTO_GOGO_MAPPINGS):$(PWD)/proto-gen/api_v2 \
		idl/proto/api_v2/query.proto
		### --swagger_out=allow_merge=true:$(PWD)/proto-gen/openapi/ \

	$(PROTOC) \
		$(PROTO_INCLUDES) \
		--gogo_out=plugins=grpc,$(PROTO_GOGO_MAPPINGS):$(PWD)/proto-gen/api_v2/metrics \
		model/proto/metrics/otelspankind.proto

	$(PROTOC) \
		$(PROTO_INCLUDES) \
		--gogo_out=plugins=grpc,$(PROTO_GOGO_MAPPINGS):$(PWD)/proto-gen/api_v2/metrics \
		model/proto/metrics/openmetrics.proto

	$(PROTOC) \
		$(PROTO_INCLUDES) \
		--gogo_out=plugins=grpc,$(PROTO_GOGO_MAPPINGS):$(PWD)/proto-gen/api_v2/metrics \
		model/proto/metrics/metricsquery.proto

	$(PROTOC) \
		$(PROTO_INCLUDES) \
		--gogo_out=plugins=grpc,$(PROTO_GOGO_MAPPINGS):$(PWD)/proto-gen/api_v2 \
		idl/proto/api_v2/collector.proto

	$(PROTOC) \
		$(PROTO_INCLUDES) \
		--gogo_out=plugins=grpc,$(PROTO_GOGO_MAPPINGS):$(PWD)/proto-gen/api_v2 \
		idl/proto/api_v2/sampling.proto

	$(PROTOC) \
		$(PROTO_INCLUDES) \
		-Iplugin/storage/grpc/proto \
		--gogo_out=plugins=grpc,$(PROTO_GOGO_MAPPINGS):$(PWD)/proto-gen/storage_v1 \
		plugin/storage/grpc/proto/storage.proto

	$(PROTOC) \
		-Imodel/proto \
		--go_out=$(PWD)/model/ \
		model/proto/model_test.proto

	$(PROTOC) \
		-Iplugin/storage/grpc/proto \
		--go_out=$(PWD)/plugin/storage/grpc/proto/ \
		plugin/storage/grpc/proto/storage_test.proto

	$(PROTOC) \
		-Iidl/proto \
		--gogo_out=plugins=grpc,$(PROTO_GOGO_MAPPINGS):$(PWD)/proto-gen/zipkin \
		idl/proto/zipkin.proto

	$(PROTOC) \
		$(PROTO_INCLUDES) \
		--gogo_out=plugins=grpc,paths=source_relative,$(PROTO_GOGO_MAPPINGS):$(PWD)/proto-gen/otel \
		$(PROTO_INTERMEDIATE_DIR)/common/v1/common.proto
	$(PROTOC) \
		$(PROTO_INCLUDES) \
		--gogo_out=plugins=grpc,paths=source_relative,$(PROTO_GOGO_MAPPINGS):$(PWD)/proto-gen/otel \
		$(PROTO_INTERMEDIATE_DIR)/resource/v1/resource.proto
	$(PROTOC) \
		$(PROTO_INCLUDES) \
		--gogo_out=plugins=grpc,paths=source_relative,$(PROTO_GOGO_MAPPINGS):$(PWD)/proto-gen/otel \
		$(PROTO_INTERMEDIATE_DIR)/trace/v1/trace.proto

	# Target  proto-prepare-otel modifies OTEL proto to use import path jaeger.proto.*
	# The modification is needed because OTEL collector already uses opentelemetry.proto.*
	# and two complied protobuf types cannot have the same import path. The root cause is that the compiled OTLP
	# in the collector is in private package, hence it cannot be used in Jaeger.
	# The following statements revert changes in OTEL proto and only modify go package.
	# This way the service will use opentelemetry.proto.trace.v1.ResourceSpans but in reality at runtime
	# it uses jaeger.proto.trace.v1.ResourceSpans which is the same type in a different package which
	# prevents panic of two equal proto types.
	rm -rf $(PROTO_INTERMEDIATE_DIR)/*
	cp -R idl/opentelemetry-proto/* $(PROTO_INTERMEDIATE_DIR)
	find $(PROTO_INTERMEDIATE_DIR) -name "*.proto" | xargs -L 1 sed -i 's+go.opentelemetry.io/proto/otlp+github.com/jaegertracing/jaeger/proto-gen/otel+g'
	$(PROTOC) \
		$(PROTO_INCLUDES) \
		--gogo_out=plugins=grpc,$(PROTO_GOGO_MAPPINGS):$(PWD)/proto-gen/api_v3 \
		idl/proto/api_v3/query_service.proto
	$(PROTOC) \
		$(PROTO_INCLUDES) \
 		--grpc-gateway_out=logtostderr=true,grpc_api_configuration=idl/proto/api_v3/query_service_http.yaml,$(PROTO_GOGO_MAPPINGS):$(PWD)/proto-gen/api_v3 \
		idl/proto/api_v3/query_service.proto
	rm -rf $(PROTO_INTERMEDIATE_DIR)

.PHONY: proto-prepare-otel
proto-prepare-otel:
	@echo --
	@echo -- Copying to $(PROTO_INTERMEDIATE_DIR)
	@echo --
	mkdir -p $(PROTO_INTERMEDIATE_DIR)
	cp -R idl/opentelemetry-proto/opentelemetry/proto/* $(PROTO_INTERMEDIATE_DIR)

	@echo --
	@echo -- Editing proto
	@echo --
	@# Change:
	@# go import from github.com/open-telemetry/opentelemetry-proto/gen/go/* to github.com/jaegertracing/jaeger/proto-gen/otel/*
	@# proto package from opentelemetry.proto.* to jaeger.proto.*
	@# remove import opentelemetry/proto
	find $(PROTO_INTERMEDIATE_DIR) -name "*.proto" | xargs -L 1 sed -i -f otel_proto_patch.sed

.PHONY: proto-hotrod
proto-hotrod:
	$(PROTOC) \
		$(PROTO_INCLUDES) \
		--gogo_out=plugins=grpc,$(PROTO_GOGO_MAPPINGS):$(PWD)/ \
		examples/hotrod/services/driver/driver.proto

.PHONY: certs
certs:
	cd pkg/config/tlscfg/testdata && ./gen-certs.sh

.PHONY: certs-dryrun
certs-dryrun:
	cd pkg/config/tlscfg/testdata && ./gen-certs.sh -d

.PHONY: repro-check
repro-check:
	# Check local reproducibility of generated executables.
	$(MAKE) clean
	$(MAKE) build-all-platforms
	# Generate checksum for all executables under ./cmd
	find cmd -type f -executable -exec shasum -b -a 256 {} \; | sort -k2 | tee sha256sum.combined.txt
	$(MAKE) clean
	$(MAKE) build-all-platforms
	shasum -b -a 256 --strict --check ./sha256sum.combined.txt

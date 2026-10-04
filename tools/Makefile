GO ?= go
export CGO_ENABLED := 0
export GOTOOLCHAIN := local
export GOPROXY := off
export GOSUMDB := off
export GOFLAGS := -mod=mod
export GOCACHE ?= /tmp/gilgamesh-gocache

.PHONY: all test vet check clean
all:
	$(GO) build -trimpath -ldflags '-s -w' -o bin/gilgamesh-dns ./cmd/gilgamesh-dns
	$(GO) build -trimpath -ldflags '-s -w' -o bin/gilgamesh-install ./cmd/gilgamesh-install

test:
	$(GO) test ./...
vet:
	$(GO) vet ./...
check: vet test all
clean:
	rm -rf bin .test-work

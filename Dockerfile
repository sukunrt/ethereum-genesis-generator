# prysmctl from the decoupled Prysm fork: it generates the Heze CL genesis
# state (see apps/prysm-genesis-state.sh) and must match that tree's
# consensus types exactly. Statically linked so the runtime stage's glibc
# does not matter. For local iteration against an unpushed Prysm tree, build
# this image and COPY a locally built prysmctl over /usr/local/bin/prysmctl.
FROM golang:1.26 AS prysmctl-builder
WORKDIR /work
ARG PRYSM_REPO=https://github.com/sukunrt/prysm.git
ARG PRYSM_BRANCH=decoupled-casper
ARG PRYSM_SHA=0280403c70d88967f49d2d4c730f4c5417dabdf5
RUN git clone -q --branch ${PRYSM_BRANCH} --single-branch ${PRYSM_REPO} prysm \
    && cd prysm \
    && git checkout -q ${PRYSM_SHA} \
    && CGO_ENABLED=1 go build -tags osusergo,netgo \
        -ldflags '-linkmode external -extldflags "-static"' \
        -o /usr/local/bin/prysmctl ./cmd/prysmctl

FROM golang:1.26 AS builder
WORKDIR /work
ARG ETH_BEACON_GENESIS_VERSION=v0.0.7
ARG ETH_BEACON_GENESIS_SHA=9bbbf55fa9603b4c2e656fe7c441a340ea61f6d6
RUN git clone -q https://github.com/ethpandaops/eth-beacon-genesis.git \
    && cd eth-beacon-genesis \
    && git checkout -q ${ETH_BEACON_GENESIS_VERSION} \
    && actual_sha=$(git rev-parse HEAD) \
    && [ "${actual_sha}" = "${ETH_BEACON_GENESIS_SHA}" ] || { \
         echo "eth-beacon-genesis ${ETH_BEACON_GENESIS_VERSION} resolved to ${actual_sha}, expected ${ETH_BEACON_GENESIS_SHA}" >&2; \
         exit 1; \
       } \
    && make \
    && go install github.com/protolambda/eth2-val-tools@latest \
    && go install github.com/miguelmota/go-ethereum-hdwallet/cmd/geth-hdwallet@latest

FROM debian:latest
WORKDIR /work
VOLUME ["/config", "/data"]
EXPOSE 8000/tcp
RUN apt-get update && \
    apt-get install --no-install-recommends -y \
    ca-certificates gettext-base yq wget curl bc && \
    apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

COPY apps /apps

# Install jq with architecture detection
RUN ARCH=$(dpkg --print-architecture) && \
    if [ "$ARCH" = "amd64" ]; then \
        curl -L https://github.com/jqlang/jq/releases/latest/download/jq-linux-amd64 -o /usr/local/bin/jq; \
    elif [ "$ARCH" = "arm64" ]; then \
        curl -L https://github.com/jqlang/jq/releases/latest/download/jq-linux-arm64 -o /usr/local/bin/jq; \
    else \
        echo "Unsupported architecture: $ARCH" && exit 1; \
    fi && \
    chmod +x /usr/local/bin/jq

ENV PATH="/root/.cargo/bin:${PATH}"
COPY --from=builder /work/eth-beacon-genesis/bin/eth-genesis-state-generator /usr/local/bin/eth-genesis-state-generator
COPY --from=builder /go/bin/eth2-val-tools /usr/local/bin/eth2-val-tools
COPY --from=builder /go/bin/geth-hdwallet /usr/local/bin/geth-hdwallet

# The CL genesis state: prysmctl, not eth-genesis-state-generator. See
# apps/prysm-genesis-state.sh for the why. Installing it under the upstream
# name leaves the stock entrypoint untouched.
COPY --from=prysmctl-builder /usr/local/bin/prysmctl /usr/local/bin/prysmctl
COPY --chmod=755 apps/prysm-genesis-state.sh /usr/local/bin/prysm-genesis-state.sh
RUN mv /usr/local/bin/eth-genesis-state-generator \
       /usr/local/bin/eth-genesis-state-generator.upstream \
    && ln -s /usr/local/bin/prysm-genesis-state.sh \
             /usr/local/bin/eth-genesis-state-generator

COPY config-example /config
COPY defaults /defaults
COPY entrypoint.sh .
ENTRYPOINT [ "/work/entrypoint.sh" ]

# codeindex as a container, for Docker's MCP catalog.
#
# The binary is already statically linked, so this image exists to satisfy hosts
# that install MCP servers as images — not because codeindex needs a runtime. It
# fetches the release asset for the target architecture and verifies it against
# the SHA256SUMS published beside it, which is the same contract the npm wrapper
# and install.sh follow.
#
# A container is a slightly awkward home for this server: codeindex indexes the
# repository it is pointed at, so the repository has to be bind-mounted in.
# CODEINDEX_WORKSPACE defaults to /workspace for exactly that reason:
#
#   docker run -i --rm -v "$PWD:/workspace:ro" munhq/codeindex
#
# Read-only is enough. codeindex never writes to the workspace; the index lives
# in the container's own filesystem.
ARG VERSION=0.3.3

FROM alpine:3.21 AS fetch
ARG VERSION
ARG TARGETARCH
RUN apk add --no-cache ca-certificates curl
WORKDIR /out
# TARGETARCH is Docker's vocabulary (amd64/arm64); the release publishes Zig
# target triples. The mapping is spelled out rather than assembled, because every
# other place this is done in this repo got it wrong once.
RUN set -eu; \
    case "$TARGETARCH" in \
      amd64) ASSET="codeindex-x86_64-linux" ;; \
      arm64) ASSET="codeindex-aarch64-linux" ;; \
      *) echo "no codeindex release build for TARGETARCH=$TARGETARCH" >&2; exit 1 ;; \
    esac; \
    BASE="https://github.com/munhq/codeindex/releases/download/v${VERSION}"; \
    curl -fsSL -o codeindex "$BASE/$ASSET"; \
    curl -fsSL -o SHA256SUMS "$BASE/SHA256SUMS"; \
    WANT="$(awk -v a="$ASSET" '$2==a{print $1}' SHA256SUMS)"; \
    [ -n "$WANT" ] || { echo "SHA256SUMS for v${VERSION} does not list $ASSET" >&2; exit 1; }; \
    printf '%s  codeindex\n' "$WANT" | sha256sum -c -; \
    chmod 0755 codeindex; \
    rm SHA256SUMS

# Nothing from the fetch stage but the binary, and nothing else in the image:
# no shell to escalate into, no package manager to drift.
FROM scratch
ARG VERSION
LABEL org.opencontainers.image.title="codeindex" \
      org.opencontainers.image.description="Structural code intelligence over MCP: symbols, callers, imports and blast radius across 40+ languages." \
      org.opencontainers.image.source="https://github.com/munhq/codeindex" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${VERSION}"
COPY --from=fetch /out/codeindex /codeindex
# The mount point the run command above uses. An unset workspace would make the
# server index the container's own root, which is empty and confusing.
ENV CODEINDEX_WORKSPACE=/workspace
WORKDIR /workspace
# stdio: the client speaks JSON-RPC over the container's stdin and stdout, so
# `docker run -i` is required and nothing may be printed to stdout but protocol.
ENTRYPOINT ["/codeindex", "--mcp"]

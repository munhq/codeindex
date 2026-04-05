# Build stage
FROM rust:1.88-bookworm AS builder

WORKDIR /build
COPY Cargo.toml Cargo.lock ./
COPY src/ src/
COPY examples/ examples/
COPY tests/ tests/

RUN cargo build --release --features mcp,db --bin codeindex-mcp

# Runtime stage
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/target/release/codeindex-mcp /usr/local/bin/codeindex-mcp

# Default workspace mount point
VOLUME /workspace
ENV CODEINDEX_WORKSPACE=/workspace
ENV CODEINDEX_PROJECT_ID=default

ENTRYPOINT ["codeindex-mcp"]

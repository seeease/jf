FROM debian:bookworm-slim AS builder
ARG TARGETARCH
ARG ZIG_VERSION=0.15.0
RUN apt-get update && apt-get install -y --no-install-recommends curl xz-utils ca-certificates && \
    if [ "$TARGETARCH" = "amd64" ]; then ZIG_ARCH=x86_64; \
    elif [ "$TARGETARCH" = "arm64" ]; then ZIG_ARCH=aarch64; fi && \
    curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz" | tar -xJ -C /opt && \
    ln -s /opt/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}/zig /usr/local/bin/zig
WORKDIR /src
COPY . .
RUN if [ "$TARGETARCH" = "amd64" ]; then ZIG_TARGET=x86_64-linux-musl; \
    elif [ "$TARGETARCH" = "arm64" ]; then ZIG_TARGET=aarch64-linux-musl; fi && \
    zig build -Doptimize=ReleaseSafe -Dtarget=$ZIG_TARGET

FROM alpine:3.20
COPY --from=builder /src/zig-out/bin/jfai /usr/local/bin/jfai
EXPOSE 8080
ENTRYPOINT ["jfai"]

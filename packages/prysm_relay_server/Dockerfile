# syntax=docker/dockerfile:1
# Base images are fully qualified (`docker.io/library/…`): Docker expands a
# short name implicitly, Podman refuses it ("short-name did not resolve to an
# alias") unless the host has a registries.conf, so an unqualified FROM breaks
# `podman build` on the first line.
# The build stage always runs on the builder's own arch and cross-compiles:
# no QEMU-emulated Dart SDK (10x slower), and dart:3.9 has no arm/v7 image
# anyway. The tag stays at the pubspec floor: package:qr is held on its 3.x
# line, which still builds on 3.9 (4.x would force the base up to 3.11).
FROM --platform=$BUILDPLATFORM docker.io/library/dart:3.9 AS build
ARG TARGETARCH TARGETVARIANT
WORKDIR /src
COPY prysm_relay_protocol /src/prysm_relay_protocol
COPY prysm_relay_server   /src/prysm_relay_server
WORKDIR /src/prysm_relay_server
RUN case "$TARGETARCH$TARGETVARIANT" in \
      amd64) DART_ARCH=x64 ;; arm64) DART_ARCH=arm64 ;; armv7) DART_ARCH=arm ;; \
      *) echo "unsupported $TARGETARCH$TARGETVARIANT" >&2; exit 1 ;; esac \
 && dart pub get \
 && dart compile exe bin/prysm_relay.dart \
      --target-os=linux --target-arch=$DART_ARCH -o /prysm-relay

FROM docker.io/library/debian:trixie-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends tor \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /prysm-relay /usr/local/bin/prysm-relay
COPY prysm_relay_server/tool/torrc         /etc/tor/torrc
COPY prysm_relay_server/tool/entrypoint.sh /entrypoint.sh
VOLUME ["/var/lib/prysm-relay", "/var/lib/tor/prysm-relay"]
ENTRYPOINT ["/entrypoint.sh"]

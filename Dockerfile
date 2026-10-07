# ZeroTier controller + zero-ui, built on upstream ZeroTierOne `dev`.
#
# Upstream ref: https://github.com/zerotier/ZeroTierOne/tree/dev
#
# Since ZeroTierOne 1.16 the controller is NO LONGER built by make-linux.mk --
# the `central-controller` target was removed in upstream commit 1f6a1fd51. It
# is now built with CMake. This Dockerfile follows that path and layers zero-ui,
# s6-overlay supervision and the optional planet patch on top.
#
# TWO FLAVOURS, selected by ZT_CONTROLLER_FLAVOR:
#
#   embedded  (default)
#     Builds ZT_NONFREE only, which is CMake's default ON and is what official
#     ZeroTier daemon packages ship. The controller stores networks and members
#     as JSON files under <home>/controller.d. No database, no migrations.
#     Needs only the header-only OpenTelemetry API, so bootstrap-deps.sh runs in
#     its fast default mode and google-cloud-cpp is never compiled.
#
#   central
#     Builds ZT1_CENTRAL_CONTROLLER=1, the hosted-controller flavour used by
#     upstream's own ext/central-controller-docker. This is NOT merely "turn on
#     the controller": ZT1_CENTRAL_CONTROLLER is a superset of ZT_NONFREE that
#     swaps FileDB for CentralDB and adds the Postgres/Redis/PubSub/BigTable
#     backends. EmbeddedNetworkController::init() then rejects any
#     controllerDbPath that is not prefixed "postgres:" and aborts at startup:
#         fatal error: ... central controller requires postgres db
#     Needs the full OpenTelemetry SDK plus google-cloud-cpp, built from source.
#
# Pick with:  docker build --build-arg ZT_CONTROLLER_FLAVOR=central .
# Bump ZEROTIER_ONE_COMMIT to move to a newer ZeroTierOne `dev` commit.
ARG BUILD_IMAGE=debian
ARG BUILD_IMAGE_VERSION=trixie
ARG NODE_MAJOR=22
ARG ZT_CONTROLLER_FLAVOR=embedded

# --------------------------------------------------
FROM ${BUILD_IMAGE}:${BUILD_IMAGE_VERSION} AS builder
ARG NODE_MAJOR
ARG ZT_CONTROLLER_FLAVOR

ENV DEBIAN_FRONTEND=noninteractive

# ZeroTierOne dev branch head (1.16.2).
ENV ZEROTIER_ONE_COMMIT=899352e38405968516bb12a770f0ac02f6058fa8
# zero-ui, myself-change-on-main branch head.
ENV ZERO_UI_COMMIT=9c1d89c2bfd02494a7d1fa5d8dea254f15be7b4e

# Pin the flavour in the image so later stages and the s6 services can see it.
ENV ZT_CONTROLLER_FLAVOR=${ZT_CONTROLLER_FLAVOR}

# Reject a typo'd flavour rather than silently building the wrong one.
RUN case "${ZT_CONTROLLER_FLAVOR}" in \
        embedded) ;; \
        central) ;; \
        *) echo "*** FAILED: ZT_CONTROLLER_FLAVOR must be 'embedded' or 'central', got '${ZT_CONTROLLER_FLAVOR}'" >&2; exit 1 ;; \
    esac && echo "ZT_CONTROLLER_FLAVOR=${ZT_CONTROLLER_FLAVOR}"

# Pinned Rust toolchain, matching upstream's central-controller Dockerfile.
ENV RUST_VERSION=1.89.0

# Prefix for the source-built controller deps (OpenTelemetry, and for the central
# flavour google-cloud-cpp too).
ENV ZT_DEPS_PREFIX=/opt/zt-deps

# Set to 1 to build a custom planet from patch/planets.json using the vendored
# mkworld, and to inject it into node/Topology.cpp before compiling. Left at 0
# so the image ships upstream's default planet. See mkworld/README.md.
ENV PATCH_ALLOW=0

ENV NODE_OPTIONS=--openssl-legacy-provider

WORKDIR /src

# ---------------------------------------------------------------------------
# 1. Toolchain + Node
# ---------------------------------------------------------------------------
# Embedded needs almost none of the controller's native deps. Determined by
# reading what each flavour's *configure* step requires, not what it links:
#
#   nlohmann-json3-dev  REQUIRED, both flavours (find_package(nlohmann_json
#                       REQUIRED) has no guard)
#   libssl-dev          REQUIRED on both: root CMakeLists sets
#                       ZT_NEED_OPENSSL for (UNIX AND NOT APPLE), not just for
#                       the controller, so find_package(OpenSSL REQUIRED) fires
#                       on embedded too. The embedded binary ends up not linking
#                       libssl because -Wl,--gc-sections drops the unreferenced
#                       bits, but configure still needs the headers.
#   libpq/libpqxx/hiredis/absl/grpc/protobuf-compiler-grpc
#                       central only; each sits behind if(ZT1_CENTRAL_CONTROLLER)
#                       in either root CMakeLists.txt or
#                       nonfree/controller/CMakeLists.txt
#   libcurl4-openssl-dev  never: find_package(CURL) is behind ZT_VAULT_SUPPORT,
#                       which defaults OFF
#
# libgtest-dev/libgmock-dev are central only, and only indirectly: they are not
# referenced by any CMakeLists in ZeroTierOne itself, but bootstrap-deps.sh
# clones google-cloud-cpp, whose cmake/FindGMockWithTargets.cmake does
# find_package(GTest) while configuring. Dropping them fails the central build
# with "Could NOT find GTest" from that file. Grepping only ZeroTierOne's tree
# is not sufficient to justify removing an apt package.
#
# libjemalloc-dev stays out entirely: nothing finds it, and the runtime image
# installs libjemalloc2 because upstream's main.sh preloads it.
#
# rustup is kept in both flavours deliberately. rustybits' only consumer is
# zeroidc/SSO, which our 0001-disable-sso patch switches off, so the resulting
# librustybits.a has no referenced symbols -- but ExternalProject_Add for it is
# unconditional and its BUILD_COMMAND is baked into a set(), with no cache
# variable to skip it. Avoiding that would mean patching upstream's CMake, and
# keeping the local patch count low is worth more here than the build time.
#
# None of these are runtime packages: the runtime stage installs the list
# derived from the binary's own ldd output, so trimming the builder has no
# effect on the published image size.
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential cmake ninja-build git pkg-config ca-certificates curl gnupg sudo quilt \
        libssl-dev nlohmann-json3-dev \
        clang jq tar make diffutils patch python3 bash \
    && if [ "${ZT_CONTROLLER_FLAVOR}" = "central" ]; then \
           apt-get install -y --no-install-recommends \
               libpq-dev libpqxx-dev libhiredis-dev \
               libabsl-dev libprotobuf-dev protobuf-compiler protobuf-compiler-grpc libgrpc++-dev \
               libgtest-dev libgmock-dev; \
       fi \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" > /etc/apt/sources.list.d/nodesource.list && \
    apt-get update && apt-get install -y --no-install-recommends nodejs && \
    rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# 2. Rust (rustybits: zeroidc)
# ---------------------------------------------------------------------------
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --default-toolchain ${RUST_VERSION} --profile minimal
ENV PATH="/root/.cargo/bin:${PATH}"

# ---------------------------------------------------------------------------
# 3. ZeroTierOne source
# ---------------------------------------------------------------------------
RUN echo "ZEROTIER_ONE_COMMIT is ${ZEROTIER_ONE_COMMIT}" && \
    curl -fsSL https://codeload.github.com/zerotier/ZeroTierOne/tar.gz/${ZEROTIER_ONE_COMMIT} --output /tmp/ZeroTierOne.tar.gz && \
    tar fxz /tmp/ZeroTierOne.tar.gz -C /src && \
    mv /src/ZeroTierOne-* /src/ZeroTierOne && \
    rm -f /tmp/ZeroTierOne.tar.gz

# ---------------------------------------------------------------------------
# 4. Local patches (quilt). Copies only the patch dir first so this cheap layer
#    stays cached when the rest of the tree moves.
# ---------------------------------------------------------------------------
ENV QUILT_PATCHES=zt_patches
COPY zt_patches /src/ZeroTierOne/zt_patches

RUN cd /src/ZeroTierOne && \
    quilt series && \
    quilt push -a && \
    echo "--- patches applied ---"

# ---------------------------------------------------------------------------
# 5. Source-built controller deps.
#
#    embedded: default mode, header-only OpenTelemetry API only. Quick -- no
#              SDK, no exporters, and google-cloud-cpp is skipped entirely.
#    central:  ZT_CONTROLLER_DEPS=1 adds the full OpenTelemetry SDK + OTLP
#              exporters and google-cloud-cpp 2.38.0, both compiled from source.
#              By far the slowest step in the whole build (~12 min in CI warm,
#              considerably longer cold). Nothing to build in the other flavour.
# ---------------------------------------------------------------------------
RUN cd /src/ZeroTierOne && \
    if [ "${ZT_CONTROLLER_FLAVOR}" = "central" ]; then \
        echo "==> flavour=central: full OpenTelemetry SDK + google-cloud-cpp"; \
        ZT_CONTROLLER_DEPS=1 bash scripts/bootstrap-deps.sh ${ZT_DEPS_PREFIX}; \
    else \
        echo "==> flavour=embedded: header-only OpenTelemetry API"; \
        bash scripts/bootstrap-deps.sh ${ZT_DEPS_PREFIX}; \
    fi

# ---------------------------------------------------------------------------
# 6. Optional custom planet (mkworld). Must run BEFORE the cmake build because
#    it rewrites node/Topology.cpp.
# ---------------------------------------------------------------------------
COPY patch /src/patch
COPY config /src/config
COPY mkworld /src/mkworld

RUN if [ "${PATCH_ALLOW}" = "1" ]; then \
        echo "PATCH_ALLOW=1 -> building custom planet"; \
        cd /src && python3 /src/patch/patch.py && \
        g++ -I/src/ZeroTierOne -I/src/ZeroTierOne/ext -o /src/mkworld/mkworld \
            /src/ZeroTierOne/node/ECC.cpp \
            /src/ZeroTierOne/node/Salsa20.cpp \
            /src/ZeroTierOne/node/SHA512.cpp \
            /src/ZeroTierOne/node/Identity.cpp \
            /src/ZeroTierOne/node/Utils.cpp \
            /src/ZeroTierOne/node/InetAddress.cpp \
            /src/ZeroTierOne/osdep/OSUtils.cpp \
            /src/mkworld/mkworld.cpp -std=c++11 -w && \
        cd /src/mkworld && ./mkworld > /src/config/world.c && \
        echo "--- custom planet: $(wc -c < /src/mkworld/world.bin) bytes ---"; \
    else \
        echo "PATCH_ALLOW=0 -> skipping planet patch (shipping upstream default planet)"; \
    fi

# ===========================================================================
# Stage break: the two flavours diverge here and never rejoin until the
# runtime stage. Everything above this point is identical for both.
#
# Why a stage boundary and not an if: `COPY` has no conditional form. With one
# flat builder, the central-only
#
#     COPY --from=builder ${ZT_DEPS_PREFIX}/lib/libopentelemetry_proto.so ...
#
# must be executed unconditionally, and on the embedded flavour those .so do
# not exist -- bootstrap-deps.sh builds opentelemetry-cpp with -DWITH_API_ONLY=ON,
# which produces headers only and never creates $PREFIX/lib at all. The build
# dies with "failed to calculate checksum ... not found".
#
# Splitting here means the runtime stage references otel-shared-libs
# unconditionally, but that stage is only ever reached in its entirety when the
# central flavour is built; on embedded the source stage is never traversed.
# ===========================================================================

# ---------------------------------------------------------------------------
# 7. Build the controller
#
#    ZT_NONFREE is CMake's default (ON) and is what official daemon packages
#    ship: the bundled FileDB controller, storing networks and members as JSON
#    under <home>/controller.d. Passing ZT1_CENTRAL_CONTROLLER=1 instead selects
#    the hosted flavour (CentralDB + Postgres/Redis/PubSub/BigTable) and forces
#    controllerDbPath to start with "postgres:".
# ---------------------------------------------------------------------------
RUN cd /src/ZeroTierOne && \
    cmake -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        $([ "${ZT_CONTROLLER_FLAVOR}" = "central" ] && echo -DZT1_CENTRAL_CONTROLLER=1) \
        -DCMAKE_PREFIX_PATH=${ZT_DEPS_PREFIX} \
        -S . -B build && \
    cmake --build build -j"$(nproc)" && \
    echo "--- built flavour=${ZT_CONTROLLER_FLAVOR} ---" && \
    ldd build/zerotier-one | head -30

# ---------------------------------------------------------------------------
# 8. Resolve the exact runtime apt packages the binary links. Robust against
#    Debian's t64 package renames; readlink -f resolves the usrmerge
#    /lib -> /usr/lib symlinks so dpkg -S can attribute each .so. The two
#    non-apt OTel proto .so's are copied explicitly in the runtime stage, so
#    dpkg-S misses there are expected.
# ---------------------------------------------------------------------------
RUN cd /src/ZeroTierOne && \
    ldd build/zerotier-one | awk '/=> \//{print $3}' | xargs -r readlink -f \
        | xargs -r dpkg -S 2>/dev/null | cut -d: -f1 | tr ',' '\n' | sort -u > /opt/runtime-pkgs.txt && \
    echo "--- runtime packages ---" && cat /opt/runtime-pkgs.txt

# ---------------------------------------------------------------------------
# 9. zero-ui (frontend + backend)
# ---------------------------------------------------------------------------
RUN echo "ZERO_UI_COMMIT is ${ZERO_UI_COMMIT}" && \
    curl -fsSL https://codeload.github.com/wongsyrone/zero-ui/tar.gz/${ZERO_UI_COMMIT} --output /tmp/zero-ui.tar.gz && \
    tar fxz /tmp/zero-ui.tar.gz -C /src && \
    mv /src/zero-ui-* /src/zero-ui && \
    rm -f /tmp/zero-ui.tar.gz

ENV GENERATE_SOURCEMAP=false

RUN cd /src/zero-ui && \
    corepack enable && \
    yarn workspaces focus frontend && \
    cd /src/zero-ui/frontend && \
    yarn build

RUN cd /src/zero-ui && \
    corepack enable && \
    yarn workspaces focus --production backend && yarn cache clean

# ===========================================================================
# golang-migrate, for the central flavour only.
#
# Upstream applies the controller schema with golang-migrate rather than by
# running the .sql files by hand. Matching that means the migrations, the applied
# set and the dirty-tracking all behave exactly as upstream intends, so there is
# nothing here to keep in step with a future upstream change.
#
# The migrations are read straight out of the ZeroTierOne source tree that the
# builder already downloaded (ext/central-controller-docker/migrations), so this
# repo vendors no SQL at all and an upstream migration added after this commit is
# picked up automatically.
#
# @latest is deliberate and matches upstream. It is not pinned deliberately:
# pinning would be the local-maintenance choice this change exists to avoid.
#
# The base image is ${BUILD_IMAGE_VERSION}, the same variable as the rest of this
# Dockerfile, and the golang:* tag for a Debian release always tracks the newest
# stable Go for it. That matters because migrate raises its minimum Go version
# between releases: v4.20.1 requires go >= 1.25.11, which golang:1.24-bookworm
# does not satisfy, and GOTOOLCHAIN=local in the golang images stops Go from
# fetching a newer toolchain on its own:
#
#   go: ...migrate/v4@v4.20.1 requires go >= 1.25.11 (running go 1.24.13;
#       GOTOOLCHAIN=local)
#
# Upstream pins golang:1.24-bookworm and therefore hits this today. Deriving the
# tag from BUILD_IMAGE_VERSION keeps @latest usable here without a second
# variable to maintain, and moving off trixie moves the Go version with it.
# ===========================================================================
FROM golang:${BUILD_IMAGE_VERSION} AS go_base
ARG ZT_CONTROLLER_FLAVOR
RUN go version && \
    GOFLAGS='-p=1' go install -tags 'postgres' github.com/golang-migrate/migrate/v4/cmd/migrate@latest
# Both flavours resolve this stage -- the runtime stage's COPY is unconditional
# and Docker has no conditional stage. Embedded simply stages nothing, so the
# COPY below yields an empty /usr/local/bin and migrate is never invoked: the
# run script only calls it when ZT_CONTROLLER_FLAVOR=central.
RUN set -eux; \
    rm -rf /opt/zt-gobin; \
    mkdir -p /opt/zt-gobin; \
    if [ "${ZT_CONTROLLER_FLAVOR}" = "central" ]; then \
        echo "==> central: staging golang-migrate"; \
        cp -v /go/bin/migrate /opt/zt-gobin/; \
    else \
        echo "==> embedded: golang-migrate not needed (FileDB creates no tables)"; \
    fi

# ===========================================================================
# Central-only artefact stage.
#
# The runtime stage below copies ${ZT_DEPS_PREFIX}/lib unconditionally, so this
# stage is always part of the dependency graph and must be valid on BOTH
# flavours. Splitting alone is therefore not enough -- what makes it safe is
# that the staging copy below is a RUN (which can be conditional) rather than a
# COPY (which cannot), combined with the directory being created unconditionally
# so the runtime stage's COPY always has something to resolve.
#
# Concretely: bootstrap-deps.sh builds opentelemetry-cpp with -DWITH_API_ONLY=ON
# in embedded mode, which produces headers only and never creates
# $PREFIX/lib at all. A flat
#
#     COPY --from=builder $PREFIX/lib/libopentelemetry_proto.so ...
#
# is therefore not a matter of style, it simply fails the build:
#     failed to calculate checksum ... "libopentelemetry_proto_grpc.so": not found
#
# With this stage, embedded ends up with an empty /opt/zt-deps/lib, the runtime
# COPY copies an empty directory (legal), and ldconfig simply finds nothing to
# register. No .so, no error, and nothing central-specific in the embedded image.
# ===========================================================================
FROM builder AS otel-shared-libs
ARG ZT_CONTROLLER_FLAVOR
RUN set -eux; \
    rm -rf /opt/zt-otlibs; \
    mkdir -p /opt/zt-otlibs; \
    if [ "${ZT_CONTROLLER_FLAVOR}" = "central" ]; then \
        echo "==> central: staging OpenTelemetry shared objects"; \
        cp -v /opt/zt-deps/lib/libopentelemetry_proto.so \
              /opt/zt-deps/lib/libopentelemetry_proto_grpc.so \
              /opt/zt-otlibs/; \
    else \
        echo "==> embedded: nothing to stage (header-only OTel API, no .so built)"; \
    fi; \
    echo "--- staged ---"; ls -la /opt/zt-otlibs/

# --------------------------------------------------

FROM ${BUILD_IMAGE}:${BUILD_IMAGE_VERSION}
ARG NODE_MAJOR
# Re-declared: an ARG set before the first FROM is global, but only the value
# is. The runtime stage needs its own ARG to see it.
ARG ZT_CONTROLLER_FLAVOR
ENV ZT_DEPS_PREFIX=/opt/zt-deps
ENV DEBIAN_FRONTEND=noninteractive

WORKDIR /app/ZeroTierOne

# Keep the flavour visible at runtime so the s6 services can adapt.
ENV ZT_CONTROLLER_FLAVOR=${ZT_CONTROLLER_FLAVOR}

# ---------------------------------------------------------------------------
# Runtime deps. The package list comes from the builder's ldd output, so this
# is exact rather than a hand-maintained guess.
# ---------------------------------------------------------------------------
COPY --from=builder /opt/runtime-pkgs.txt /tmp/runtime-pkgs.txt
RUN apt-get update && apt-get install -y --no-install-recommends \
        $(cat /tmp/runtime-pkgs.txt) \
        libjemalloc2 \
        netcat-openbsd \
        ca-certificates curl gnupg sudo jq tar make xz-utils git wget bash tree \
    && if [ "${ZT_CONTROLLER_FLAVOR}" = "central" ]; then \
           apt-get install -y --no-install-recommends postgresql-client postgresql-client-common; \
       fi \
    && rm -f /tmp/runtime-pkgs.txt \
    && rm -rf /var/lib/apt/lists/*

# NodeSource, in its own layer so the deb line survives ZeroTierOne bumps.
RUN mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" > /etc/apt/sources.list.d/nodesource.list && \
    apt-get update && apt-get install -y --no-install-recommends nodejs && \
    rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# ZeroTierOne
# ---------------------------------------------------------------------------
COPY --from=builder /src/ZeroTierOne/build/zerotier-one /app/ZeroTierOne/zerotier-one
RUN cd /app/ZeroTierOne && \
    ln -s zerotier-one zerotier-cli && \
    ln -s zerotier-one zerotier-idtool

# The only dynamically-linked from-source libs. Only the central flavour has
# any: its OpenTelemetry SDK/exporters compile down to shared objects, while
# embedded uses the header-only API and stages an empty directory instead.
# Copying the directory (not the individual .so files) is deliberate -- a COPY
# of a named file fails outright when that file does not exist, which is exactly
# how the embedded build broke before.
COPY --from=otel-shared-libs /opt/zt-otlibs/ /usr/local/lib/
RUN echo /usr/local/lib > /etc/ld.so.conf.d/zerotier.conf && \
    ldconfig && \
    echo "--- OpenTelemetry shared objects in /usr/local/lib ---" && \
    ls -la /usr/local/lib/

# jemalloc is resolved at runtime by s6-files/etc/services.d/zerotier/run
# (ldconfig + awk), matching upstream's main.sh. It cannot be baked in with a
# build-time ENV: docker's ENV parser treats the '>' in '2>/dev/null' as a
# redirect and rejects the value.

# ---------------------------------------------------------------------------
# Planet + world definition. With PATCH_ALLOW=0 /src/config/world.c is the
# committed upstream copy and /app/config/planet is the default planet file the
# daemon reads from its config dir.
# ---------------------------------------------------------------------------
COPY --from=builder /src/config/world.c /app/config/world.c
RUN mkdir -p /var/lib/zerotier-one/ && \
    ln -sf /app/config/authtoken.secret /var/lib/zerotier-one/authtoken.secret

# ---------------------------------------------------------------------------
# s6-overlay
# ---------------------------------------------------------------------------
RUN S6_OVERLAY_VERSION=$(curl --silent "https://api.github.com/repos/just-containers/s6-overlay/releases/latest" | jq -r .tag_name | sed 's/^v//') && \
    echo "S6_OVERLAY_VERSION is ${S6_OVERLAY_VERSION}" && \
    cd /tmp && \
    curl --silent --location https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz --output s6-overlay-noarch-${S6_OVERLAY_VERSION}.tar.xz && \
    curl --silent --location https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-x86_64.tar.xz --output s6-overlay-x86_64-${S6_OVERLAY_VERSION}.tar.xz && \
    tar -C / -Jxpf /tmp/s6-overlay-noarch-${S6_OVERLAY_VERSION}.tar.xz && \
    tar -C / -Jxpf /tmp/s6-overlay-x86_64-${S6_OVERLAY_VERSION}.tar.xz && \
    rm -f /tmp/*.xz

# ---------------------------------------------------------------------------
# Frontend @ zero-ui
# ---------------------------------------------------------------------------
COPY --from=builder /src/zero-ui/frontend/build /app/frontend/build/
COPY --from=builder /src/zero-ui/frontend/down_folder /app/frontend/down_folder
# - allow to download planet when logged-in
RUN ln -sf /app/config/planet /app/frontend/down_folder/planet

# ---------------------------------------------------------------------------
# Backend @ zero-ui
# ---------------------------------------------------------------------------
WORKDIR /app/backend
COPY --from=builder /src/zero-ui/backend /app/backend
COPY --from=builder /src/zero-ui/node_modules /app/backend/node_modules

# Create empty tls folder for TLS cert and key
RUN mkdir -p /app/backend/tls

# ---------------------------------------------------------------------------
# s6-overlay services + controller schema migrations
# ---------------------------------------------------------------------------
COPY ./s6-files/etc /etc/
RUN chmod +x /etc/services.d/*/run

# Controller migrations, taken from the ZeroTierOne source tree that the builder
# already unpacked (ext/central-controller-docker/migrations). Nothing is vendored
# in this repo, so migrations added upstream after the pinned commit arrive on the
# next image build without any local edit. Only the central flavour runs them.
COPY --from=builder /src/ZeroTierOne/ext/central-controller-docker/migrations /migrations

# golang-migrate, central flavour only. The staging stage leaves this empty for
# embedded, and the run script never calls it there.
COPY --from=go_base /opt/zt-gobin/ /usr/local/bin/

# show path content
RUN tree /app/config || true
RUN tree /app/ZeroTierOne
RUN tree /app/backend --filelimit 50 || true
RUN tree /app/frontend --filelimit 50 || true

# default ports
# 3000 - http
# 4000 - https
# 9993 & 9993/udp - zerotier
EXPOSE 3000 4000 9993 9993/udp
ENV S6_KEEP_ENV=1

ENTRYPOINT ["/init"]
CMD []
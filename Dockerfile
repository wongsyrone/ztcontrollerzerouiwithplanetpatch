# build image -> https://github.com/zerotier/ZeroTierOne/blob/dev/ext/central-controller-docker
ARG BUILD_IMAGE=ubuntu
ARG BUILD_IMAGE_VERSION=jammy
ARG NODE_MAJOR=20

# --------------------------------------------------
FROM ${BUILD_IMAGE}:${BUILD_IMAGE_VERSION} as builder
ARG NODE_MAJOR

# dev branch latest commit
ENV ZEROTIER_ONE_COMMIT=36b4659f77bc480fdc510304bc53f009fde5d629
# from myself-change-on-main branch
ENV ZERO_UI_COMMIT=735479130c9c4ebee90c39153adaa9d13b454a31

ENV PATCH_ALLOW=0

ENV NODE_OPTIONS=--openssl-legacy-provider

# Prepare Environment
COPY patch /src/patch
COPY config /src/config

RUN apt update && apt -y install tree ca-certificates gnupg curl sudo quilt && \
    sudo mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" | sudo tee /etc/apt/sources.list.d/nodesource.list && \
    apt update && apt upgrade -y && \
    apt -y install \
        build-essential \
        pkg-config \
        bash \
        clang \
        libpq5 \
        libpq-dev \
        openssl \
        libssl-dev \
        postgresql-client \
        postgresql-client-common \
        nodejs python3 git bash jq tar make diffutils patch protobuf-compiler

WORKDIR /src

# Downloading and build latest zero-ui from my repo

RUN echo "ZERO_UI_COMMIT is ${ZERO_UI_COMMIT}" && \
    curl https://codeload.github.com/wongsyrone/zero-ui/tar.gz/${ZERO_UI_COMMIT} --output /tmp/zero-ui.tar.gz && \
    mkdir -p /src/ && \
    cd /src && \
    tar fxz /tmp/zero-ui.tar.gz && \
    mv /src/zero-ui-* /src/zero-ui && \
    rm -rf /tmp/zero-ui.tar.gz

ENV GENERATE_SOURCEMAP=false

RUN cd /src/zero-ui && \
    corepack enable && \
	yarn workspaces focus frontend && \
	cd /src/zero-ui/frontend && \
	yarn build

RUN cd /src/zero-ui && \
    corepack enable && \
	yarn workspaces focus --production backend && yarn cache clean

RUN tree /src/zero-ui -L 2

# Downloading and build latest libpqxx
RUN LIBPQXX_VERSION=$(curl --silent "https://api.github.com/repos/jtv/libpqxx/releases" | jq -r ".[0].tag_name") && \
    echo "LIBPQXX_VERSION is ${LIBPQXX_VERSION}" && \
    curl https://codeload.github.com/jtv/libpqxx/tar.gz/refs/tags/${LIBPQXX_VERSION} --output /tmp/libpqxx.tar.gz && \
    mkdir -p /src && \
    cd /src && \
    tar fxz /tmp/libpqxx.tar.gz && \
    mv /src/libpqxx-* /src/libpqxx && \
    rm -rf /tmp/libpqxx.tar.gz && \
    cd /src/libpqxx && \
    /src/libpqxx/configure --disable-documentation --with-pic && \
    make -j4 && \
    make install

# Downloading and build latest version ZeroTierOne

RUN curl https://codeload.github.com/zerotier/ZeroTierOne/tar.gz/${ZEROTIER_ONE_COMMIT} --output /tmp/ZeroTierOne.tar.gz && \
    mkdir -p /src && \
    cd /src && \
    tar fxz /tmp/ZeroTierOne.tar.gz && \
    mv /src/ZeroTierOne-* /src/ZeroTierOne && \
    rm -rf /tmp/ZeroTierOne.tar.gz

ENV QUILT_PATCHES=zt_patches
COPY zt_patches /src/ZeroTierOne/zt_patches

RUN python3 /src/patch/patch.py

# apply my own patch to zerotier
RUN cd /src/ZeroTierOne && \
    quilt series && \
    quilt push -a

# install rust crate 'prost-wkt-types' dep
RUN apt install -y protobuf-compiler

# install Rust toolchain
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

RUN export PATH=$PATH:~/.cargo/bin && \
    cd /src/ZeroTierOne && \
    make -f make-linux.mk central-controller CPPFLAGS+=-w -j4

RUN cd /src/ZeroTierOne/attic/world && \
    bash build.sh

# --------------------------------------------------

FROM ${BUILD_IMAGE}:${BUILD_IMAGE_VERSION}
ARG NODE_MAJOR

WORKDIR /app/ZeroTierOne

# libpqxx
COPY --from=builder /usr/local/lib/libpqxx.la /usr/local/lib/libpqxx.la
COPY --from=builder /usr/local/lib/libpqxx.a /usr/local/lib/libpqxx.a

# ZeroTierOne
COPY --from=builder /src/ZeroTierOne/zerotier-one /app/ZeroTierOne/zerotier-one
RUN cd /app/ZeroTierOne && \
    ln -s zerotier-one zerotier-cli && \
    ln -s zerotier-one zerotier-idtool

# mkworld @ ZeroTierOne
COPY --from=builder /src/ZeroTierOne/attic/world/mkworld /app/ZeroTierOne/mkworld
COPY --from=builder /src/ZeroTierOne/attic/world/world.bin /app/config/planet
COPY --from=builder /src/config/world.c /app/config/world.c

# Environment

RUN apt update && apt -y install tree ca-certificates gnupg curl sudo && \
    sudo mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" | sudo tee /etc/apt/sources.list.d/nodesource.list && \
    apt update && apt upgrade -y && \
    apt -y install \
        postgresql-client \
        postgresql-client-common \
        libpq5 \
        nodejs wget git bash jq tar make xz-utils && \
    mkdir -p /var/lib/zerotier-one/ && \
    ln -s /app/config/authtoken.secret /var/lib/zerotier-one/authtoken.secret

# Installing s6-overlay
RUN S6_OVERLAY_VERSION=$(curl --silent "https://api.github.com/repos/just-containers/s6-overlay/releases/latest" | jq -r .tag_name | sed 's/^v//') && \
    echo "S6_OVERLAY_VERSION is ${S6_OVERLAY_VERSION}" && \
    cd /tmp && \
    curl --silent --location https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz --output s6-overlay-noarch-${S6_OVERLAY_VERSION}.tar.xz && \
    curl --silent --location https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-x86_64.tar.xz --output s6-overlay-x86_64-${S6_OVERLAY_VERSION}.tar.xz && \
    tar -C / -Jxpf /tmp/s6-overlay-noarch-${S6_OVERLAY_VERSION}.tar.xz && \
    tar -C / -Jxpf /tmp/s6-overlay-x86_64-${S6_OVERLAY_VERSION}.tar.xz && \
    rm -f /tmp/*.xz

# Frontend @ zero-ui
COPY --from=builder /src/zero-ui/frontend/build /app/frontend/build/
COPY --from=builder /src/zero-ui/frontend/down_folder /app/frontend/down_folder
# - allow to download planet when logged-in
RUN ln -s /app/config/planet /app/frontend/down_folder/planet

# Backend @ zero-ui
WORKDIR /app/backend
COPY --from=builder /src/zero-ui/backend /app/backend
COPY --from=builder /src/zero-ui/node_modules /app/backend/node_modules

# Create empty tls folder for TLS cert and key
RUN mkdir -p /app/backend/tls

# s6-overlay
COPY ./s6-files/etc /etc/
RUN chmod +x /etc/services.d/*/run

# schema
COPY ./schema /app/schema/

# show path content
RUN tree /app/config
RUN tree /app/ZeroTierOne
RUN tree /app/backend --filelimit 50 || true
RUN tree /app/frontend --filelimit 50 || true

# default ports
# 3000 - http
# 4000 - https
# 9993 & 9993/UDP - zerotier
EXPOSE 3000 4000 9993 9993/UDP
ENV S6_KEEP_ENV=1

ENTRYPOINT ["/init"]
CMD []

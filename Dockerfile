# build image -> https://github.com/zerotier/ZeroTierOne/blob/dev/ext/central-controller-docker
ARG BUILD_IMAGE=ubuntu
ARG BUILD_IMAGE_VERSION=jammy

FROM ${BUILD_IMAGE}:${BUILD_IMAGE_VERSION} as builder

ENV NODE_VERSION=lts.x
# dev branch latest commit
ENV ZEROTIER_ONE_COMMIT=fac212fafa9464168114a2e3e24c066e5098c185

ENV PATCH_ALLOW=0

# Prepare Environment
COPY patch /src/patch
COPY config /src/config

RUN apt update && apt -y install tree gnupg curl sudo quilt && \
    curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | sudo apt-key add - && \
    echo "deb https://dl.yarnpkg.com/debian/ stable main" | sudo tee /etc/apt/sources.list.d/yarn.list && \
    curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION} | bash - && \
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
        nodejs yarn python3 git bash jq tar make diffutils patch

WORKDIR /src

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

# install Rust toolchain
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

RUN export PATH=$PATH:~/.cargo/bin && \
    cd /src/ZeroTierOne && \
    make -f make-linux.mk central-controller CPPFLAGS+=-w -j4

RUN cd /src/ZeroTierOne/attic/world && \
    bash build.sh

# Downloading and build latest tagged zero-ui
RUN ZERO_UI_VERSION=$(curl --silent "https://api.github.com/repos/dec0dOS/zero-ui/tags" | jq -r '.[0].name') && \
    echo "ZERO_UI_VERSION is ${ZERO_UI_VERSION}" && \
    curl https://codeload.github.com/dec0dOS/zero-ui/tar.gz/refs/tags/${ZERO_UI_VERSION} --output /tmp/zero-ui.tar.gz && \
    mkdir -p /src/ && \
    cd /src && \
    tar fxz /tmp/zero-ui.tar.gz && \
    mv /src/zero-ui-* /src/zero-ui && \
    rm -rf /tmp/zero-ui.tar.gz && \
    cd /src/zero-ui && \
    yarn install && \
    yarn build

FROM ${BUILD_IMAGE}:${BUILD_IMAGE_VERSION}

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

RUN apt update && apt -y install tree gnupg curl sudo && \
    curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | sudo apt-key add - && \
    echo "deb https://dl.yarnpkg.com/debian/ stable main" | sudo tee /etc/apt/sources.list.d/yarn.list && \
    curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION} | bash - && \
    apt update && apt upgrade -y && \
    apt -y install \
        postgresql-client \
        postgresql-client-common \
        libpq5 \
        nodejs yarn wget git bash jq tar make xz-utils && \
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

# Backend @ zero-ui
WORKDIR /app/backend
COPY --from=builder /src/zero-ui/backend/package*.json /app/backend
# - allow to download planet directly
RUN yarn install && \
    ln -s /app/config/planet /app/frontend/build/static/planet
COPY --from=builder /src/zero-ui/backend /app/backend

# s6-overlay
COPY ./s6-files/etc /etc/
RUN chmod +x /etc/services.d/*/run

# schema
COPY ./schema /app/schema/

# show zerotier config path at last
RUN tree /app/config
RUN tree /app/ZeroTierOne/

# default ports
EXPOSE 4000 9993 9993/UDP
ENV S6_KEEP_ENV=1

ENTRYPOINT ["/init"]
CMD []

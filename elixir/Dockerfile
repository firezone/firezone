ARG ALPINE_VERSION="3.20.6"
ARG ERLANG_VERSION="28.3"
# curl -fsSL https://github.com/erlang/otp/releases/download/OTP-28.3/otp_src_28.3.tar.gz | sha256sum
ARG ERLANG_DOWNLOAD_SHA256="1956ad6584678b631ab4f9b8aebe2dac037cd7401abb44564a01134ff0ac5bed"
ARG ELIXIR_VERSION="1.19.4"
# curl -fsSL https://github.com/elixir-lang/elixir/archive/refs/tags/v1.19.4.tar.gz | sha256sum
ARG ELIXIR_DOWNLOAD_SHA256="a2df9d5411fc53d97ec17c069765c8fb781f8dc36c4e06ec1cd4b189340d364b"

FROM alpine:${ALPINE_VERSION} AS base

# Important!  Update this no-op ENV variable when this Dockerfile
# is updated with the current date. It will force refresh of all
# of the base images and things like `apk add` won't be using
# old cached versions when the Dockerfile is built.
ENV REFRESHED_AT=2023-10-05 \
    LANG=C.UTF-8 \
    HOME=/app/ \
    TERM=xterm

# Add tagged repos as well as the edge repo so that we can selectively install edge packages
ARG ALPINE_VERSION
RUN set -xe \
    && ALPINE_MINOR_VERSION=$(echo ${ALPINE_VERSION} | cut -d'.' -f1,2) \
    && echo "@main http://dl-cdn.alpinelinux.org/alpine/v${ALPINE_MINOR_VERSION}/main" >> /etc/apk/repositories \
    && echo "@community http://dl-cdn.alpinelinux.org/alpine/v${ALPINE_MINOR_VERSION}/community" >> /etc/apk/repositories \
    && echo "@edge http://dl-cdn.alpinelinux.org/alpine/edge/main" >> /etc/apk/repositories

RUN set -xe \
    # Upgrade Alpine and base packages
    && apk --no-cache --update-cache --available upgrade \
    # Install bash, Erlang/OTP and Elixir runtime dependencies
    && apk add --no-cache --update-cache \
    bash \
    libstdc++ \
    ca-certificates \
    ncurses \
    openssl \
    pcre \
    unixodbc \
    zlib \
    # Update ca certificates
    && update-ca-certificates --fresh

FROM base AS build_erlang

# Install bash and Erlang/OTP deps
RUN set -xe \
    && apk add --no-cache --update-cache --virtual .fetch-deps \
    curl \
    libgcc \
    lksctp-tools \
    zlib-dev

# Install Erlang/OTP build deps
RUN set -xe \
    && apk add --no-cache --virtual .build-deps \
    dpkg-dev \
    dpkg \
    gcc \
    g++ \
    libc-dev \
    linux-headers \
    make \
    autoconf \
    ncurses-dev \
    openssl-dev \
    unixodbc-dev \
    lksctp-tools-dev \
    tar

# Download OTP
ARG ERLANG_VERSION
ARG ERLANG_DOWNLOAD_SHA256
WORKDIR /tmp/erlang-build
RUN set -xe \
    && curl -fSL -o otp-src.tar.gz "https://github.com/erlang/otp/releases/download/OTP-${ERLANG_VERSION}/otp_src_${ERLANG_VERSION}.tar.gz" \
    && tar -xzf otp-src.tar.gz -C /tmp/erlang-build --strip-components=1 \
    # && sha256sum otp-src.tar.gz && exit 1 \
    && echo "${ERLANG_DOWNLOAD_SHA256}  otp-src.tar.gz" | sha256sum -c -

# Configure & Build
RUN set -xe \
    && export ERL_TOP=/tmp/erlang-build \
    && export CPPFLAGS="-D_BSD_SOURCE $CPPFLAGS" \
    && export gnuArch="$(dpkg-architecture --query DEB_HOST_GNU_TYPE)" \
    && ./configure \
    --build="$gnuArch" \
    --prefix=/usr/local \
    --sysconfdir=/etc \
    --mandir=/usr/share/man \
    --infodir=/usr/share/info \
    --without-javac \
    --without-jinterface \
    --without-wx \
    --without-debugger \
    --without-observer \
    --without-cosEvent \
    --without-cosEventDomain \
    --without-cosFileTransfer \
    --without-cosNotification \
    --without-cosProperty \
    --without-cosTime \
    --without-cosTransactions \
    --without-et \
    --without-gs \
    --without-ic \
    --without-megaco \
    --without-orber \
    --without-percept \
    --without-odbc \
    --without-typer \
    --enable-threads \
    --enable-shared-zlib \
    --enable-dynamic-ssl-lib \
    --enable-ssl=dynamic-ssl-lib \
    $(if [[ "${TARGET}" != *"amd64"* ]]; then echo "--disable-jit"; fi) \
    && $( \
    if [[ "${TARGETARCH}" == *"amd64"* ]]; \
    then export CFLAGS="-g -O2 -fstack-clash-protection -fcf-protection=full"; \
    else export CFLAGS="-g -O2 -fstack-clash-protection"; fi \
    ) \
    && make -j$(getconf _NPROCESSORS_ONLN)

# Install to temporary location, strip the install, install runtime deps and copy to the final location
RUN set -xe \
    && make DESTDIR=/tmp install \
    && cd /tmp && rm -rf /tmp/erlang-build \
    && find /tmp/usr/local -regex '/tmp/usr/local/lib/erlang/\(lib/\|erts-\).*/\(man\|doc\|obj\|c_src\|emacs\|info\|examples\)' | xargs rm -rf \
    && find /tmp/usr/local -name src | xargs -r find | grep -v '\.hrl$' | xargs rm -v || true \
    && find /tmp/usr/local -name src | xargs -r find | xargs rmdir -vp || true \
    # Strip install to reduce size
    && scanelf --nobanner -E ET_EXEC -BF '%F' --recursive /tmp/usr/local | xargs -r strip --strip-all \
    && scanelf --nobanner -E ET_DYN -BF '%F' --recursive /tmp/usr/local | xargs -r strip --strip-unneeded \
    && runDeps="$( \
    scanelf --needed --nobanner --format '%n#p' --recursive /tmp/usr/local \
    | tr ',' '\n' \
    | sort -u \
    | awk 'system("[ -e /tmp/usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
    )" \
    && ln -s /tmp/usr/local/lib/erlang /usr/local/lib/erlang \
    && /tmp/usr/local/bin/erl -eval "beam_lib:strip_release('/tmp/usr/local/lib/erlang/lib')" -s init stop > /dev/null \
    && (/usr/bin/strip /tmp/usr/local/lib/erlang/erts-*/bin/* || true) \
    && apk add --no-cache --virtual .erlang-runtime-deps $runDeps lksctp-tools ca-certificates

# Cleanup after Erlang install
RUN set -xe \
    && apk del .fetch-deps .build-deps \
    && rm -rf /var/cache/apk/*

WORKDIR ${HOME}

CMD ["erl"]

FROM base AS build_elixir

# Install Elixir build deps
RUN set -xe \
    && apk add --no-cache --virtual .build-deps \
    make \
    curl \
    tar \
    git

# Download Elixir
ARG ELIXIR_VERSION
ARG ELIXIR_DOWNLOAD_SHA256
WORKDIR /tmp/elixir-build
RUN set -xe \
    && curl -fSL -o elixir-src.tar.gz "https://github.com/elixir-lang/elixir/archive/refs/tags/v${ELIXIR_VERSION}.tar.gz" \
    && mkdir -p /tmp/usr/local/src/elixir \
    && tar -xzC /tmp/usr/local/src/elixir --strip-components=1 -f elixir-src.tar.gz \
    # && sha256sum elixir-src.tar.gz && exit 1 \
    && echo "${ELIXIR_DOWNLOAD_SHA256}  elixir-src.tar.gz" | sha256sum -c - \
    && rm elixir-src.tar.gz

COPY --from=build_erlang /tmp/usr/local /usr/local

# Compile Elixir
RUN set -xe \
    && cd /tmp/usr/local/src/elixir \
    && make DESTDIR=/tmp install clean \
    && find /tmp/usr/local/src/elixir/ -type f -not -regex "/tmp/usr/local/src/elixir/lib/[^\/]*/lib.*" -exec rm -rf {} + \
    && find /tmp/usr/local/src/elixir/ -type d -depth -empty -delete \
    && rm -rf /tmp/elixir-build \
    && apk del .build-deps

# Cleanup apk cache
RUN rm -rf /var/cache/apk/*

WORKDIR ${HOME}

CMD ["iex"]

FROM base AS elixir

WORKDIR ${HOME}

# Copy Erlang/OTP and Elixir installations
COPY --from=build_erlang /tmp/usr/local /usr/local
COPY --from=build_elixir /tmp/usr/local /usr/local

# Install hex + rebar
RUN set -xe \
    && mix local.hex --force \
    && mix local.rebar --force

CMD ["bash"]

FROM elixir AS compiler

WORKDIR /app

# Install build deps
RUN apk add --update --no-cache \
    make \
    git \
    nodejs \
    npm \
    build-base

# Add pnpm
RUN npm i -g pnpm

# Copy only the files needed to fetch the dependencies,
# to leverage Docker layer cache for them
COPY mix.exs mix.lock ./
COPY config config

# Fetch and compile the dependencies
ARG MIX_ENV="prod"
RUN mix deps.get --only ${MIX_ENV}
RUN mix deps.compile

# Copy the files needed to fetch asset deps
COPY assets/package.json ./assets/
COPY assets/pnpm-lock.yaml ./assets/

# Install npm deps and assets pipeline
RUN mix assets.setup

# Tailwind needs assets and lib directories to look for used classes,
# so we can't optimize further at this stage
COPY lib lib
COPY assets assets
COPY priv priv

# Install pipeline and compile assets
RUN mix assets.deploy

# Copy the rest of the application files and compile them
# mix doesn't know when GIT_SHA changes, so --force is needed to avoid
# pulling in a cached version.
ARG GIT_SHA
RUN mix compile --force

FROM elixir AS builder

# Install build deps
RUN apk add --update --no-cache \
    git

WORKDIR /app

# Copy the compiled dependencies from the previous step
# leveraging the possible layer cache
COPY --from=compiler /app /app

COPY rel rel

ARG APPLICATION_NAME
ARG MIX_ENV="prod"
ARG GIT_SHA
RUN mix release ${APPLICATION_NAME}
RUN mix sentry.package_source_code

# start a new build stage so that the final image will only contain
# the compiled release and other runtime necessities

FROM base AS runtime

RUN set -xe \
    # Install Firezone runtime deps
    && apk add --no-cache --update-cache \
    curl \
    jq \
    tini

# Create default user and home directory, set owner to default
RUN set -xe \
    && mkdir -p /app \
    && adduser -s /bin/sh -u 1001 -G root -h /app -S -D default \
    && chown -R 1001:0 /app

WORKDIR /app

ARG APPLICATION_NAME
ENV APPLICATION_NAME=$APPLICATION_NAME

# Only copy the final release from the build stage
ARG MIX_ENV="prod"
COPY --from=builder /app/_build/${MIX_ENV}/rel/${APPLICATION_NAME} ./

# Allow the default user to write to the priv directory of some libraries
RUN chmod -R ugo+rw /app/lib/tzdata-*/priv

# Allow the default user to write to /var/run/firezone for node draining
RUN mkdir -p /var/run/firezone \
    && chmod -R ugo+rw /var/run/firezone

# Change user to "default" to limit runtime privileges
USER default

# This is critical when you run this container in containers where
# running process would get a PID 1.
#
# BEAM is usually not started by itself but via some shell script (eg. the one generated by
# Elixir 1.9 releases or Distillery) and this script is not designed to become an init script
# for a Docker container and it DOES NOT reap zombie processes.
#
# So whenever a child process runs and terminates inside the same container it would result in memory and
# PID leak to a point where host VM would get unresponsive.
#
# A good example why you would start a process within container is the `ping` command for liveness probes.
# It starts a VM to issue an RPC command to a live node and then terminates, but would never be reaped.
#
# Tini would become an entrypoin script and would take care of zombie reaping no matter how you start the VM.
ENTRYPOINT ["/sbin/tini", "--"]

CMD ["bin/server"]

# This Dockerfile builds release packages.
# **NOTE**: This is not recommended, as it's possible the deployment
# production environment will diff from the image environment here,
# even if the OS and kernel versions match.
# As such, this script has been deprecated in favor of building the release
# in the production environment.
FROM hexpm/elixir:1.11.2-erlang-23.1.2-ubuntu-focal-20201008 AS build

# Setup to run build script
ENV DEBIAN_FRONTEND noninteractive
RUN apt-get update -q && \
    apt-get install -y --no-install-recommends \
    ca-certificates \
    build-essential \
    git \
    dpkg-dev \
    libssl-dev \
    automake \
    gnupg \
    curl \
    autoconf \
    libncurses5-dev \
    unzip \
    zlib1g-dev \
    locales && \
    apt-get clean && \
    rm -rf /tmp/* /var/tmp/*
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && \
    locale-gen
ENV LANG en_US.UTF-8
ENV LANGUAGE en_US:en
ENV LC_ALL en_US.UTF-8

RUN curl -sL https://deb.nodesource.com/setup_10.x | bash -
RUN apt-get install nodejs

ENV MIX_ENV prod
WORKDIR /build

RUN mix local.hex --force && \
    mix local.rebar --force
COPY mix.exs mix.lock ./
COPY config config
COPY apps/cf_http/mix.exs ./apps/cf_http/
COPY apps/cf_wall/mix.exs ./apps/cf_wall/
COPY apps/cf_vpn/mix.exs ./apps/cf_vpn/
RUN mix do deps.get, deps.compile

COPY apps/cf_http/assets/package.json apps/cf_http/assets/package-lock.json ./apps/cf_http/assets/
RUN cd apps/cf_http/assets && npm ci --progress=false --no-audit --loglevel=error
COPY apps/cf_http/priv apps/cf_http/priv
COPY apps/cf_http/assets apps/cf_http/assets
RUN npm run --prefix ./apps/cf_http/assets deploy && \
    cd apps/cf_http && mix phx.digest

COPY . .
RUN mix release cloudfire

RUN mkdir -p pkg/debian/opt
RUN mv _build/prod/rel/cloudfire pkg/debian/opt/cloudfire

RUN cd pkg && dpkg-deb --build debian

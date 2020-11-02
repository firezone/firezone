# This Dockerfile builds release packages
FROM hexpm/elixir:1.11.1-erlang-23.1.1-ubuntu-focal-20200703 AS build

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
COPY apps/fg_http/mix.exs ./apps/fg_http/
COPY apps/fg_wall/mix.exs ./apps/fg_wall/
COPY apps/fg_vpn/mix.exs ./apps/fg_vpn/
RUN mix do deps.get, deps.compile

COPY apps/fg_http/assets/package.json apps/fg_http/assets/package-lock.json ./apps/fg_http/assets/
RUN cd apps/fg_http/assets && npm ci --progress=false --no-audit --loglevel=error
COPY apps/fg_http/priv apps/fg_http/priv
COPY apps/fg_http/assets apps/fg_http/assets
RUN npm run --prefix ./apps/fg_http/assets deploy && \
    cd apps/fg_http && mix phx.digest

COPY . .
RUN mix release fireguard

RUN mkdir -p pkg/debian/opt
RUN mv _build/prod/rel/fireguard pkg/debian/opt/fireguard

ENV DATABASE_URL ecto://dummy@localhost/dummy
ENV SECRET_KEY_BASE dummy
RUN ./pkg/debian/opt/fireguard/bin/fireguard eval 'IO.puts "Hello World!"'

RUN cd pkg && dpkg-deb --build debian

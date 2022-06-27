FROM hexpm/elixir:1.13.4-erlang-25.0.2-ubuntu-jammy-20220428

RUN set -xe \
  && apt-get update \
  && apt-get upgrade -y \
  && apt-get install -y apt-utils curl git \
  && curl -sL https://deb.nodesource.com/setup_16.x -o setup_node_deb \
  && bash setup_node_deb \
  && apt-get install -y \
    net-tools \
    iproute2 \
    nftables \
    inotify-tools \
    ca-certificates \
    build-essential \
    sudo \
    nodejs \
  && apt-get autoremove -y \
  && apt-get clean -y \
  && rm setup_node_deb \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /var/app

ARG GIT_SHA=DEV
ARG MIX_ENV=dev
ARG DATABASE_URL

ENV GIT_SHA=$GIT_SHA
ENV MIX_ENV=$MIX_ENV
ENV DATABASE_URL=$DATABASE_URL

RUN mix local.hex --force && mix local.rebar --force

COPY apps /var/app/apps
COPY config /var/app/config
COPY mix.exs /var/app/mix.exs
COPY mix.lock /var/app/mix.lock

RUN npm install --prefix apps/fz_http/assets

RUN mix do deps.get --only $MIX_ENV, deps.compile

EXPOSE 4000 51820/udp

CMD ["mix", "start"]

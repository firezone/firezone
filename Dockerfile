FROM elixir:1.10.2-alpine AS builder

MAINTAINER docker@cloudfire.network

ARG MIX_ENV=prod
ARG PHOENIX_DIR=./apps/cloudfire

# These are used only for building and won't matter later on
# ENV DATABASE_URL=ecto://dummy:dummy@dummy/dummy
# ENV SECRET_KEY_BASE=dummy

# Install dependencies
RUN apk add npm

WORKDIR /app

RUN mix do local.hex --force, local.rebar --force

COPY config/ .
COPY mix.exs ./
COPY mix.* ./

COPY apps/cf_phx/mix.exs ./apps/cf_phx/
COPY apps/system_engine/mix.exs ./apps/system_engine/

RUN mix do deps.get --only $MIX_ENV, deps.compile

COPY . .

RUN npm install --prefix $PHOENIX_DIR/assets
RUN npm run deploy --prefix $PHOENIX_DIR/assets
RUN mix phx.digest

RUN mix release bundled

# The built application is now contained in _build/

# This is what the builder image is based on
FROM alpine:3.11

RUN apk add --no-cache \
    ncurses-dev \
    openssl-dev

EXPOSE 4000
ENV PORT=4000 \
    MIX_ENV=prod \
    SHELL=/bin/bash

WORKDIR /app
COPY --from=builder /app/_build/prod/rel/bundled .

CMD ["bin/bundled", "start"]

FROM elixir:1.10.2-alpine AS builder

MAINTAINER docker@cloudfire.network

ENV MIX_ENV=prod
ARG PHOENIX_DIR=./apps/cf_phx

# These are used only for building and won't matter later on
# ENV DATABASE_URL=ecto://dummy:dummy@dummy/dummy
# ENV SECRET_KEY_BASE=dummy

# Install dependencies
RUN apk add --update build-base npm git

WORKDIR /app

# Install hex + rebar
RUN mix local.hex --force
RUN mix local.rebar --force

COPY config config
COPY mix.* ./

COPY $PHOENIX_DIR/mix.* $PHOENIX_DIR/
COPY apps/system_engine/mix.* ./apps/system_engine/

RUN mix deps.get
RUN mix deps.compile

# Build assets
COPY $PHOENIX_DIR/assets $PHOENIX_DIR/assets
COPY $PHOENIX_DIR/priv $PHOENIX_DIR/priv
RUN npm install --prefix $PHOENIX_DIR/assets
RUN npm run deploy --prefix $PHOENIX_DIR/assets
RUN mix phx.digest

# Build project
COPY $PHOENIX_DIR/lib $PHOENIX_DIR/lib
COPY apps/system_engine/lib ./apps/system_engine/
RUN mix compile

# Build releases
RUN mix release cf_phx
RUN mix release system_engine

# The built application is now contained in _build/



# --------------------------------------------------
FROM alpine:3.11 AS app
RUN apk add --update bash openssl

EXPOSE 4000
ENV PORT=4000 \
    SHELL=/bin/bash

RUN mkdir /app
WORKDIR /app

COPY --from=builder /app/_build/prod/rel/bundled .
RUN chown -R nobody: /app
USER nobody

ENV HOME=/app

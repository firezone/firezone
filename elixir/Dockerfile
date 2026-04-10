FROM hexpm/elixir:1.19.5-erlang-28.4.1-alpine-3.23.3 AS compiler

ENV LANG=C.UTF-8

WORKDIR /app

# Pull alpine package patches that landed after the hexpm/elixir base image
# was published, then install build deps:
#   - git: required for git-sourced mix deps (openid_connect, opentelemetry_*_experimental)
#   - build-base: required for argon2_elixir's C NIF (provides gcc + make)
#   - nodejs/npm: required to install pnpm, which installs assets/package.json deps
RUN apk --no-cache upgrade \
    && apk add --no-cache \
    git \
    build-base \
    nodejs \
    npm

RUN npm i -g pnpm

# Install hex + rebar
RUN mix local.hex --force \
    && mix local.rebar --force

ARG MIX_ENV="prod"

# Copy only the files needed to fetch the dependencies,
# to leverage Docker layer cache for them
COPY mix.exs mix.lock ./
COPY config config

# Fetch and compile the dependencies
RUN mix deps.get --only ${MIX_ENV}
RUN mix deps.compile

# Install asset deps via pnpm before pulling in lib/assets/priv
COPY assets/package.json assets/pnpm-lock.yaml ./assets/
RUN mix assets.setup

COPY lib lib
COPY assets assets
COPY priv priv

# Build minified assets
RUN mix assets.deploy

# mix doesn't know when GIT_SHA changes, so --force is needed to avoid
# pulling in a cached version.
ARG GIT_SHA
RUN mix compile --force

# `compiler` stops here. It's consumed as a standalone image (target=compiler)
# by integration/perf tests and as a dev service container in docker-compose —
# i.e. an environment with deps + assets + beams compiled but no release built,
# so mix tasks (test, ecto.migrate, etc.) can run against it.

FROM compiler AS builder

COPY rel rel

ARG APPLICATION_NAME
ARG MIX_ENV="prod"
# Package source code for Sentry BEFORE building the release so sentry.map
# lands inside the release artifact (otherwise production stack traces have
# no source context). See: https://hexdocs.pm/sentry/Mix.Tasks.Sentry.PackageSourceCode.html
RUN mix sentry.package_source_code
RUN mix release ${APPLICATION_NAME}

# start a new build stage so that the final image will only contain
# the compiled release and other runtime necessities

FROM alpine:3.23.3 AS runtime

ENV LANG=C.UTF-8

# Install Erlang/OTP runtime deps + Firezone runtime deps
#   - curl, jq: used by rel/env.sh.eex for GCP/ECS metadata lookup
#   - tini: PID 1 zombie reaper for the BEAM
RUN apk --no-cache upgrade \
    && apk add --no-cache \
    libstdc++ \
    ca-certificates \
    ncurses \
    openssl \
    pcre \
    unixodbc \
    zlib \
    curl \
    jq \
    tini \
    && update-ca-certificates --fresh

# Create default user (member of root group for OpenShift-style random-uid compatibility)
# and the node-draining state directory.
RUN adduser -s /bin/sh -u 1001 -G root -h /app -S -D default \
    && mkdir -p /var/run/firezone \
    && chmod -R ugo+rw /var/run/firezone

WORKDIR /app

ARG APPLICATION_NAME
ENV APPLICATION_NAME=$APPLICATION_NAME

# Only copy the final release from the build stage
ARG MIX_ENV="prod"
COPY --from=builder --chown=1001:0 /app/_build/${MIX_ENV}/rel/${APPLICATION_NAME} ./

# Allow tzdata to write IANA timezone updates at runtime
RUN chmod -R ugo+rw /app/lib/tzdata-*/priv

USER default

# tini reaps zombies left behind by short-lived child processes (e.g. liveness
# probes that spawn a VM, RPC, then exit). Without it those accumulate as PID
# leaks under PID 1.
ENTRYPOINT ["/sbin/tini", "--"]

CMD ["bin/server"]

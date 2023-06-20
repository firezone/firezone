ARG ALPINE_VERSION=3.18.2
ARG OTP_VERSION=26.0.1
ARG ELIXIR_VERSION=1.15.0

ARG BUILDER_IMAGE="firezone/elixir:${ELIXIR_VERSION}-otp-${OTP_VERSION}"
ARG RUNNER_IMAGE="alpine:${ALPINE_VERSION}"

FROM ${BUILDER_IMAGE} as builder

# install build dependencies
RUN apk add nodejs yarn build-base git python3

# prepare build dir
WORKDIR /app

# install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# install mix dependencies
COPY mix.exs mix.lock ./
COPY apps/domain/mix.exs ./apps/domain/mix.exs
COPY apps/web/mix.exs ./apps/web/mix.exs
COPY apps/api/mix.exs ./apps/api/mix.exs
COPY config/ config/

ARG MIX_ENV="prod"
RUN mix deps.get --only ${MIX_ENV}
RUN mix deps.compile --skip-umbrella-children

COPY priv priv
COPY apps apps

ARG APPLICATION_VERSION=0.0.0-dev.docker

# Install pipeline and compile assets for Web app
RUN cd apps/web \
    && mix assets.setup \
    && mix assets.deploy \
    && cd ../../

# Compile the release
RUN mix compile

COPY rel rel

ARG APPLICATION_NAME
RUN mix release ${APPLICATION_NAME}

# start a new build stage so that the final image will only contain
# the compiled release and other runtime necessities
FROM ${RUNNER_IMAGE}

RUN apk add -u --no-cache libstdc++ ncurses-libs openssl curl

WORKDIR /app

ARG MIX_ENV="prod"

ARG APPLICATION_NAME
ARG APPLICATION_VERSION=0.0.0-dev.docker

ENV APPLICATION_NAME=$APPLICATION_NAME
ENV APPLICATION_VERSION=$APPLICATION_VERSION

# Only copy the final release from the build stage
COPY --from=builder /app/_build/${MIX_ENV}/rel/${APPLICATION_NAME} ./

# Change user to "default" to limit runtime privileges
# USER default

CMD bin/server

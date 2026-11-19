# The obs_factor release image. Modelled on marginalia's Dockerfile, minus
# Node, assets and Ecto: the frontend is plain files in priv/static (no build
# step), and there is no repo to migrate.
#
# Builder and runner are marginalia's exact pins, so the box shares their
# layers. Both were pulled before pinning (2026-11-18):
#   docker pull hexpm/elixir:1.19.5-erlang-28.3.1-debian-trixie-20260610-slim
#   docker pull debian:trixie-20260610-slim

ARG ELIXIR_VERSION=1.19.5
ARG OTP_VERSION=28.3.1
ARG DEBIAN_VERSION=trixie-20260610-slim

ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="docker.io/debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

# No NIFs in the dependency tree (phoenix, bandit, req, postgrex, jason,
# telemetry): nothing here needs a C compiler or git.
WORKDIR /app

RUN mix local.hex --force \
  && mix local.rebar --force

ENV MIX_ENV="prod"

COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# Compile-time config before deps.compile, so a config change recompiles them.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib
RUN mix compile

# Changes to config/runtime.exs don't require recompiling the code.
COPY config/runtime.exs config/

# There is no rel/ directory (marginalia's `COPY rel rel` would fail the
# build here): the default release is enough.
RUN mix release

FROM ${RUNNER_IMAGE} AS final

RUN apt-get update \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates \
  && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
  && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR "/app"
RUN chown nobody /app

ENV MIX_ENV="prod"
# No bin/server (that needs `mix phx.gen.release`, i.e. a rel/ overlay): the
# release's own start command, with the endpoint told to serve.
ENV PHX_SERVER="true"

COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/obs_factor ./

# The topology files at a path that does not carry the app's version
# (the release puts priv under lib/obs_factor-<vsn>/priv). TOPOLOGY points
# here: /app/topology/prod.exs, /app/topology/lab.exs.
COPY --from=builder --chown=nobody:root /app/priv/topology /app/topology

USER nobody

EXPOSE 4000

CMD ["/app/bin/obs_factor", "start"]

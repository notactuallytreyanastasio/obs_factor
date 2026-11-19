# obslab's LiveView app, as a release. Modelled on the repo root Dockerfile
# (same pinned builder and runner images, so the layers are shared).
#
# The app depends on packages/factory_report by path, so the build context
# is the REPO ROOT, not this directory:
#
#   docker build -f lab/liveapp/Dockerfile -t obslab-liveapp .
#
# The root .dockerignore lets exactly this app's and the package's source
# through (mix.exs, mix.lock, config/, lib/) and nothing else of lab/.

ARG ELIXIR_VERSION=1.19.5
ARG OTP_VERSION=28.3.1
ARG DEBIAN_VERSION=trixie-20260610-slim

ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="docker.io/debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

# No NIFs in the dependency tree: nothing here needs a C compiler or git.
# The same layout as the repo, so the path dependency
# (../../packages/factory_report) resolves unchanged.
WORKDIR /src/lab/liveapp

RUN mix local.hex --force \
  && mix local.rebar --force

ENV MIX_ENV="prod"

COPY packages/factory_report/mix.exs /src/packages/factory_report/mix.exs
COPY lab/liveapp/mix.exs lab/liveapp/mix.lock ./
RUN mix deps.get --only $MIX_ENV

# Compile-time config before deps.compile, so a config change recompiles them.
COPY lab/liveapp/config/config.exs config/
COPY packages/factory_report/lib /src/packages/factory_report/lib
RUN mix deps.compile

COPY lab/liveapp/lib lib
RUN mix compile

# Changes to config/runtime.exs don't require recompiling the code.
COPY lab/liveapp/config/runtime.exs config/

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

COPY --from=builder --chown=nobody:root /src/lab/liveapp/_build/${MIX_ENV}/rel/liveapp ./

USER nobody

# 4000: the app (PORT). 9568: the factory report (FACTORY_REPORT_PORT),
# for the observer only; never route it through the proxy.
EXPOSE 4000 9568

CMD ["/app/bin/liveapp", "start"]

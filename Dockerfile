# Multi-stage Dockerfile for the deflua.com website.
#
# Build context MUST be the lua/ repo root (parent of website/) so the
# `{:lua, path: ".."}` path dependency is reachable from inside the image.
#
# From the repo root:
#   docker build -t deflua .
#   fly deploy           # fly.toml lives next to this Dockerfile

ARG ELIXIR_VERSION=1.19.4
ARG OTP_VERSION=28.3.3
ARG DEBIAN_VERSION=bookworm-20260518-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update -y && apt-get install -y build-essential git curl ca-certificates gnupg \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" > /etc/apt/sources.list.d/nodesource.list \
    && apt-get update -y && apt-get install -y nodejs \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

# Mirror the on-disk layout so `{:lua, path: ".."}` in website/mix.exs
# resolves correctly: website lives at /app/website, lua at /app.
WORKDIR /app

ENV MIX_ENV="prod"

RUN mix local.hex --force && mix local.rebar --force

# Lua package: only the files mix needs to compile the dep.
# README.md is read at compile time by lib/lua.ex (@external_resource).
COPY mix.exs mix.lock README.md ./
COPY lib ./lib

# Website mix files first so deps.get is cached when only app code changes.
COPY website/mix.exs website/mix.lock ./website/
WORKDIR /app/website

RUN mix deps.get --only $MIX_ENV
RUN mkdir config

COPY website/config/config.exs website/config/${MIX_ENV}.exs config/
RUN mix deps.compile

# Install npm deps separately from app code so they cache.
# package.json references `../deps/phoenix` etc., so deps/ must already exist
# (it does — `mix deps.get` ran above).
COPY website/assets/package.json website/assets/package-lock.json assets/
RUN cd assets && npm ci --no-audit --no-fund --progress=false

COPY website/priv priv
COPY website/lib lib
COPY website/assets assets

# mix compile must run BEFORE assets.deploy because Phoenix's LiveView
# colocated-hooks compiler generates files under _build/ that esbuild
# resolves via NODE_PATH (`phoenix-colocated/website`).
RUN mix compile
RUN mix assets.deploy

COPY website/config/runtime.exs config/
COPY website/rel rel
# Belt-and-suspenders: ensure the overlay script is exec'able regardless of
# the source-tree mode it was checked out with.
RUN chmod +x rel/overlays/bin/server && mix release

# ---- Runtime image ----
FROM ${RUNNER_IMAGE}

RUN apt-get update -y && \
    apt-get install -y libstdc++6 openssl libncurses6 locales ca-certificates curl && \
    apt-get clean && rm -f /var/lib/apt/lists/*_*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8

WORKDIR /app
RUN chown nobody /app

ENV MIX_ENV="prod"

COPY --from=builder --chown=nobody:root /app/website/_build/${MIX_ENV}/rel/website ./

USER nobody

CMD ["/app/bin/server"]

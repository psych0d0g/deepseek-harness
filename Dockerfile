# syntax=docker/dockerfile:1.7

ARG NODE_IMAGE=node:24-bookworm-slim
FROM ${NODE_IMAGE} AS builder

ARG PNPM_VERSION=11.7.0

# node-pty publishes prebuilds for only some Linux architectures; esbuild,
# lefthook, koffi, and dsh-subprocess-local also run reviewed install/build
# scripts per pnpm-workspace.yaml's allowBuilds. cmake is needed for
# koffi's from-source fallback specifically (its own cnoke.cjs build
# tries a prebuilt binary first, but falls back to a real CMake build if
# that fetch fails for any reason).
RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
      build-essential \
      ca-certificates \
      cmake \
      python3 \
    && rm -rf /var/lib/apt/lists/* \
    && npm install --global --no-audit --no-fund "pnpm@${PNPM_VERSION}" \
    && test "$(pnpm --version)" = "${PNPM_VERSION}"

WORKDIR /src
COPY . .

# scripts/build.ts stamps client artifacts with the source commit hash via
# `git rev-parse HEAD` unless DSH_CLIENT_COMMIT_HASH is already set - passed
# in from the host instead, since .dockerignore excludes .git (keeps the
# build context small and avoids installing git in this stage).
ARG DSH_CLIENT_COMMIT_HASH
ENV DSH_CLIENT_COMMIT_HASH=${DSH_CLIENT_COMMIT_HASH}

# build:official: scripts/build.ts runs build:lib (tsc + tsdown for the
# host+client runtime) then build:web, and stamps the client build record
# as "official" (branding strings only) - release/pack.ts's
# verifyBuildArtifacts step requires that record to exist before packing.
#
# The install step below produces a standalone node_modules tree the same
# way `npm install -g @deepseek-ai/dsh` would from the registry, but from
# local source. `pnpm deploy` was tried first and rejected: plain deploy
# refuses without inject-workspace-packages=true, and that setting only
# covers workspace:* protocol deps - not the vendor/* link: overrides in
# pnpm-workspace.yaml (@deepseek-ai/cosmokit, /schemastery), which pnpm's
# own --legacy deploy mode also failed to resolve correctly at runtime.
# Instead this uses the repo's own sanctioned release-packing path
# (scripts/release/pack.ts, the same tooling verify-packed-install.ts uses
# to prove a real npm install works): `pnpm pack` correctly rewrites every
# workspace:/link: protocol reference to a real resolved version per
# package, for both the `vendor` family (cordis/cosmokit/schemastery etc,
# since dsh packages peer-depend on them) and the `dsh` family (every
# @deepseek-ai/dsh-* package, including apps/cli). The packed tarballs are
# then installed together via a plain `npm install` against a synthetic
# package.json listing every tarball as a file: dependency - the same
# operation a registry install would perform, just against local files.
#
# `pnpm exec tsx scripts/release/pack.ts ...` (not `pnpm run release:pack
# -- ...`): pnpm forwards the literal `--` token itself into the script's
# argv rather than stripping it, which broke pack.ts's own parseArgs (it
# saw `--family` as an unexpected positional, not a flag, since parseArgs
# treats a literal `--` as an explicit end-of-options marker).
RUN pnpm install --frozen-lockfile \
    && pnpm run build:official \
    && pnpm exec tsx scripts/release/pack.ts --family vendor --out /tmp/pack-vendor \
    && pnpm exec tsx scripts/release/pack.ts --family dsh --out /tmp/pack-dsh \
    && mkdir -p /out/dsh \
    && node -e ' \
        const fs = require("fs"); \
        const path = require("path"); \
        const { execSync } = require("child_process"); \
        const dirs = ["/tmp/pack-vendor", "/tmp/pack-dsh"]; \
        const deps = {}; \
        for (const dir of dirs) { \
          for (const f of fs.readdirSync(dir).filter(n => n.endsWith(".tgz"))) { \
            const tgz = path.join(dir, f); \
            const pkg = JSON.parse(execSync(`tar -xOf ${tgz} package/package.json`)); \
            deps[pkg.name] = `file:${tgz}`; \
          } \
        } \
        fs.writeFileSync("/out/dsh/package.json", JSON.stringify({ \
          name: "dsh-install-root", version: "0.0.0", private: true, dependencies: deps, \
        }, null, 2)); \
      ' \
    && cd /out/dsh \
    && npm install --no-audit --no-fund --package-lock=false

FROM ${NODE_IMAGE}

ARG PNPM_VERSION=11.7.0
ARG DSH_VERSION=0.1.1-rc.2

LABEL org.opencontainers.image.title="DeepSeek Harness (custom build)" \
      org.opencontainers.image.description="Custom container image built from a from-source fork of the DeepSeek Harness CLI, Web UI, and browser-accessible Chromium desktop" \
      org.opencontainers.image.source="https://github.com/psych0d0g/deepseek-harness" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${DSH_VERSION}"

# Keep the runtime useful to a coding agent without shipping a compiler
# toolchain. Chromium is installed from Debian so both linux/amd64 and
# linux/arm64 stay native. Noto CJK keeps Chinese pages and screenshots
# readable. pnpm is reinstalled here (not copied from the builder stage)
# since the `dsh plugin` subcommand shells out to pnpm at runtime, in the
# profile directory, not just at build time.
RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
      ca-certificates \
      chromium \
      fonts-liberation \
      fonts-noto-cjk \
      git \
      novnc \
      openbox \
      openssh-client \
      procps \
      python3 \
      ripgrep \
      tini \
      websockify \
      x11-utils \
      x11vnc \
      xterm \
      xvfb \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /usr/local/lib/node_modules/@deepseek-ai \
    && npm install --global --no-audit --no-fund "pnpm@${PNPM_VERSION}" \
    && test "$(pnpm --version)" = "${PNPM_VERSION}"

# The whole installed tree, not just the @deepseek-ai/dsh subfolder: a
# plain `npm install` hoists most dependencies (dsh-app-boot, dsh-base,
# etc) to the TOP-LEVEL node_modules as siblings of @deepseek-ai/dsh, not
# nested underneath it - copying only the nested subfolder discarded them.
# Node's module resolution climbs through /usr/local/lib/node_modules
# itself as a candidate directory, so hoisted siblings resolve correctly
# from dsh's own lib/bin.js once the whole tree lands at the same level.
COPY --from=builder /out/dsh/node_modules/ /usr/local/lib/node_modules/
COPY docker/scripts/chromium-docker /usr/local/bin/chromium-docker
COPY docker/scripts/deepseek-harness-entrypoint /usr/local/bin/deepseek-harness-entrypoint
COPY docker/plugins/dsh-browser-desktop /opt/deepseek-harness/plugins/dsh-browser-desktop

RUN chmod 0755 /usr/local/bin/chromium-docker \
        /usr/local/bin/deepseek-harness-entrypoint \
    && mkdir -p \
      /usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/@runzhliu \
      /opt/deepseek-harness/plugins/dsh-browser-desktop/node_modules/@deepseek-ai \
    && ln -s /opt/deepseek-harness/plugins/dsh-browser-desktop \
      /usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/@runzhliu/dsh-browser-desktop \
    && ln -s /usr/local/lib/node_modules/@deepseek-ai/schemastery \
      /opt/deepseek-harness/plugins/dsh-browser-desktop/node_modules/@deepseek-ai/schemastery \
    && ln -s ../lib/node_modules/@deepseek-ai/dsh/lib/bin.js /usr/local/bin/dsh \
    && ln -s chromium-docker /usr/local/bin/chrome \
    && ln -s chromium-docker /usr/local/bin/google-chrome \
    && ln -s chromium-docker /usr/local/bin/google-chrome-stable \
    && if [ ! -e /usr/share/novnc/index.html ]; then \
      ln -s vnc.html /usr/share/novnc/index.html; \
    fi \
    && test "$(dsh --version)" = "${DSH_VERSION}" \
    && chromium-docker --version

ENV DSH_HOME=/home/node/.dsh \
    DSH_TELEMETRY_DISABLED=1 \
    HOME=/workspace \
    NODE_ENV=production \
    DISPLAY=:99 \
    XDG_RUNTIME_DIR=/tmp/runtime-node \
    CHROME_BIN=/usr/local/bin/chromium-docker \
    CHROME_PATH=/usr/local/bin/chromium-docker \
    CHROME_USER_DATA_DIR=/home/node/.dsh/chrome-profile \
    BROWSER=/usr/local/bin/chromium-docker \
    PUPPETEER_EXECUTABLE_PATH=/usr/local/bin/chromium-docker \
    XDG_CACHE_HOME=/tmp/.cache \
    XDG_CONFIG_HOME=/tmp/.config \
    XDG_DATA_HOME=/tmp/.local/share

COPY --chown=node:node docker/web.cordis.patch.yml /opt/deepseek-harness/web.cordis.patch.yml

RUN mkdir -p "${DSH_HOME}" /workspace \
    && chown -R node:node "${DSH_HOME}" /workspace

USER node
WORKDIR /workspace

EXPOSE 3080 6080

# The CLI mounts a config-only HMR watcher after profile boot. Scope Node's
# internal-module access flag to the dsh process instead of exporting it via
# NODE_OPTIONS to every child process the agent starts.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/deepseek-harness-entrypoint"]
CMD ["web", "--patch", "/opt/deepseek-harness/web.cordis.patch.yml"]

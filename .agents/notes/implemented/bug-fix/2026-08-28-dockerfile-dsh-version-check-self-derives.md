# Agent Note: Dockerfile install-sanity check derives its expected dsh version instead of a hardcoded ARG default

Status: implemented

## Problem

The runtime stage's install-sanity check (`test "$(dsh --version)" = "${DSH_VERSION}"`, immediately after `dsh` is symlinked into place) compared the freshly-built `dsh` binary's reported version against `ARG DSH_VERSION`, whose only value came from a Dockerfile-literal default (`0.1.1-rc.2`) — no build-arg fed it, so nothing kept it in sync with `apps/cli/package.json`'s actual version. It went stale the moment that version bumped (confirmed by a real failed `:dev` build: `test "0.1.2-alpha.1" = "0.1.1-rc.2"`, after an upstream `deepseek-ai/deepseek-harness` sync merge landed a release commit), breaking the image build for a reason unrelated to anything the triggering commit actually changed.

## Decision

The check now derives its expected value from the package it just copied into the image, instead of a separately-maintained constant: `$(node -p "require('/usr/local/lib/node_modules/@deepseek-ai/dsh/package.json').version")`, read after the `COPY --from=builder /out/dsh/node_modules/ ...` step that puts it there. This keeps the check meaningful rather than making it vacuous: it still proves `dsh --version`'s runtime version-resolution logic produces a value that agrees with the package.json under this image's final relocated/symlinked layout (catching a bug where hoisting or the `@runzhliu` scope shim broke that resolution), it just no longer needs a human to keep a second copy of the version number in sync.

`ARG DSH_VERSION` stays, now documented as label-only (feeds `org.opencontainers.image.version`), bumped to `0.1.2-alpha.1` as a one-time correction. It can still go stale between releases, but a stale label is informational drift, not a build failure — the class of problem this note fixes.

## Alternatives considered

**Thread the version through as a real build-arg from Woodpecker CI** (mirroring how `CI_COMMIT_SHA` is forwarded via `build_args_from_env`), sourced from `apps/cli/package.json` at pipeline time. Rejected: adds an external CI-config dependency and a second place to keep in sync (the pipeline step deriving the value, plus the Dockerfile consuming it) for a fact the image already has direct access to once the package is copied in.

**Drop the check entirely.** Rejected: it still catches a real class of packaging bug (the binary's own version-resolution failing under the relocated layout), just not the version-string-typo class it was accidentally also catching before.

**Also self-derive the `LABEL`'s `DSH_VERSION`.** Rejected for now: `LABEL` instructions evaluate before the package is copied into this stage (`COPY --from=builder` happens later), and Dockerfile `ARG`/`ENV` cannot be assigned from a `RUN` command's output — deriving it would need either moving the `LABEL` after the `COPY` (fine on its own, but doesn't solve the ARG-from-command-output limitation) or a second `COPY --from=builder` of just the small `package.json` earlier, read via a `RUN` step into a file, with no path in plain Dockerfile syntax to feed that file's content back into a `LABEL`'s string value. Worth revisiting with a BuildKit heredoc or an external `--label` at push time if the label's staleness starts to matter in practice; it doesn't fail builds today.

## Consequences

A version bump in `apps/cli/package.json` alone no longer breaks the `:dev`/tagged image build. The OCI `image.version` label can still drift until the next Dockerfile edit that happens to touch this file, which is an accepted, lower-stakes trade-off versus the build-breaking failure this replaces.

# Agent Note: `disableAuth` config to skip browser-session authentication

Status: implemented

## Problem

`@deepseek-ai/dsh-client-connection` requires a browser-session token/cookie on `/` and every `/api` request unconditionally ([browser token authentication](../architecture/2026-08-24-browser-token-authentication.md)), with no way to opt out. That's correct for the common case, but a deployment that already authenticates every caller before traffic reaches this process — an authenticating reverse proxy in front of it, for one — gets no security benefit from the extra check, only the friction of the token-URL/cookie exchange on every new client and every browser-session expiry. There was no supported way to skip it: no CLI flag, no env var, no config field.

## Decision

`ConnectionConfig` gains `disableAuth?: boolean` (default `false`, schemastery-validated like every other field on this Config). `BrowserAuth.create` takes an explicit `disabled` argument; when true it skips `initializeSecret` entirely (no credential-store access, no signing secret created or read) and constructs an internal `AuthState` discriminated union tagged `'disabled'` instead of `'signing'`. `authorizeIndex`, `isAuthenticated`, and `authenticatedUrl` each check that tag first: disabled mode authorizes every request unconditionally and `authenticatedUrl` returns the plain root URL with no token query param, so `dsh web`'s printed/opened URL carries nothing to authenticate.

The Host/Origin trust fence (`api-request-trust.ts`) is untouched and still runs before this check either way — `disableAuth` only removes the identity check behind it, not the anti-DNS-rebinding one.

Set through the plugin's own `config`, the same as `trustedHosts` or `cookieMaxAgeDays` — a cordis patch overlay in a deployment that terminates authentication elsewhere, not a CLI flag on `dsh web` (auth policy is this plugin's own config, not the launcher's or the web app's).

## Alternatives considered

**A CLI flag on `dsh web` (`--no-auth`), mirroring `--no-open`.** Rejected: authentication policy belongs to `client-connection`'s own `Config`, which every deployment already configures through a cordis patch; a launcher flag would be a second, redundant path to the same setting and `web-startup.ts`'s flag family isn't the right owner for a security policy that also governs the `/api` gateway, not just the web app's own concerns.

**A fixed/injectable token via env var instead of a full bypass.** Rejected as solving a narrower problem than the actual one: a deployment terminating auth at a reverse proxy has no use for a token exchange at all, fixed or not, and a static token embedded in an env var is itself a weaker credential than the existing per-activation random one.

**Silently treating a missing signing secret as disabled**, i.e. inferring the mode from `secret` being absent instead of a separate flag. Rejected: conflates two different failure/config modes and makes a future bug (secret initialization failing silently) read as an intentional disable. The explicit `AuthState` discriminant keeps them distinct and makes disabled mode a real, intentional branch instead of an accident of missing data.

## Consequences

A deployment that sets `disableAuth: true` gets no browser-session check at all: every caller that passes the Host/Origin trust fence reaches `/api` and index.html, including one on an unrelated browser tab if the deployment's own perimeter (ingress auth, network isolation) doesn't stop it first. This is an intentional trade a deployment operator makes deliberately, not a default; `false` keeps every existing deployment's behavior unchanged. Disabled mode never touches the credential store, so no `client-connection/browser-session` grant record is created for a deployment that never needs one.

# Agent Note: Skip chmod on a detected CIFS/SMB mount

Status: implemented

## Problem

`writeFileAtomic` in `@deepseek-ai/dsh-fs-local` protects write-in-progress content with explicit `chmod` calls: the staging directory is chmodded `0o700` after `mkdir`, the temp file is chmodded `0o600` after `open`, and an existing target's mode is reapplied to the published file with a final `chmod`. On a CIFS/SMB mount, these calls commonly fail with `EPERM`/`EOPNOTSUPP`: SMB has no POSIX permission-bit model to set — access control lives in the server-side share ACL — so the client-side `chmod` syscall the CIFS filesystem driver forwards has nothing meaningful to do. Because these calls are unguarded, the failure propagates through the whole `writeFileAtomic` call and the `write`/`edit` tools fail outright, even though the actual content write (`open`/`writeFile`/`rename`) would otherwise have succeeded.

This is distinct from the Windows case ([Windows fs permissions Agent Note](../architecture/2026-07-05-windows-fs-permissions.md), archived): there, `chmod` is a benign no-op (it only ever toggles the read-only attribute, and every mode this package passes carries owner-write), so calling it costs nothing and that note explicitly rejected adding a skip branch for it. CIFS actively throws instead of silently no-opping, which is what justifies a guard here that was rejected there.

## Decision

`writeFileAtomic` probes the destination directory's filesystem once per call, via `fs.promises.statfs`, and skips all three `chmod` calls when the reported type is `CIFS_SUPER_MAGIC` (`0xff534d42`, the magic number Linux's `cifs.ko` reports for both `cifs` and `smb3` mounts). The probe short-circuits to `false` (attempt chmod, unchanged behavior) on Windows — its own no-op path already covers that platform, so the CIFS-specific probe stays POSIX-only — and on any `statfs` failure or non-CIFS result, so an undetermined filesystem is never silently downgraded.

When skipped, the staging directory and temp file keep whatever mode `mkdir`/`open` produced at creation time (subject to the process umask and, on CIFS, the server's own mode mapping), and an existing target's mode is not reapplied to the published file. The probe is overridable through `FsIoInternals.isChmodUnsupported`, following the file's existing test-seam pattern (`internals.platform`, `internals.copyFileDacl`, etc.), since a real CIFS mount is not obtainable in CI.

## Alternatives considered

**Catch and swallow `EPERM`/`EOPNOTSUPP` on every `chmod` call, regardless of filesystem.** Rejected: this would also mask a genuine permission bug on an ordinary POSIX filesystem, where the same errno indicates a real fault worth surfacing loudly. A positive filesystem-type check keeps the skip scoped to the one filesystem class where the failure is expected and harmless.

**Skip chmod on Windows the same way.** Already rejected by the architecture note this decision extends — Windows chmod is a benign no-op there, so guarding it adds a branch without changing behavior. The CIFS case is different because the call actively throws.

**Detect "chmod unsupported" reactively, by attempting the call and inspecting the error.** Rejected in favor of a proactive `statfs` probe: reactive detection would need every one of the three call sites to carry its own try/catch with the same errno allowlist, tripling the special-casing for one filesystem fact that only needs to be established once per write.

## Consequences

A write to a CIFS/SMB-backed target (e.g. a network-share-mounted workspace) now succeeds instead of failing on the first `chmod`. The trade-off: on such a mount, an existing file's mode is no longer preserved across a replace, and new files get whatever mode `open()`'s create-time argument produces there rather than a guaranteed `0o600` — acceptable because SMB's own server-side ACL is the actual access-control mechanism in that case, not the client-side POSIX bits this package would otherwise be asserting. The `info.type === CIFS_SUPER_MAGIC` true-branch and the `statfs`-failure catch branch are `v8 ignore`d in `fsio.ts`, since neither is reachable without a real CIFS mount or a genuine `statfs` fault in CI; the `skipChmod` *behavior* those branches drive is covered through the `internals.isChmodUnsupported` test-seam override in `fsio.spec.ts`.

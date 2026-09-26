# GitHub provider pins

The registry is just `providers.json` committed to the `labelle-registry`
GitHub repository. No registry service or publishing infrastructure is involved.
The exact schema lives in [provider contract v1](provider-contract-v1.md#4-github-manifest-and-project-integrity-lock).

## Using a declared provider

Declare the provider's exact package/repo/version in the project's `.plugins`
and ordinary `labelle.lock`. Then preview and explicitly accept integrity pins:

```text
labelle providers resolve
labelle providers resolve --accept
labelle <namespace> <command>
```

The resolve command reads the GitHub manifest, selects only versions already
declared by this project, and shows each exact commit/hash. Runtime-only packages
not in the registry are ignored; a known provider with no matching repo/version
is an error. `--accept` downloads source archives, verifies SHA-256, validates
manifests and namespace/target ownership, then atomically replaces
`labelle.providers.lock`. It does not run any provider build code.

Commit both locks. The companion JSON lock avoids having ordinary game
generation erase integrity pins when it regenerates `labelle.lock`. A changed
project declaration is rejected until both locks match. Existing provider
versions in the registry must not be repointed; publish a new version instead.

Normal commands never look for newer registry data or fetch missing archives.
They validate the compressed archive on every invocation and use a fresh
temporary extraction. Changes to the older plugin cache have no effect.
Help for a pinned remote provider also verifies/extracts its manifest, but
does not resolve a compiler or run a build script.

## Offline and recovery

```text
labelle providers resolve /path/to/registry/providers.json --offline --accept
```

Offline mode requires local metadata and archives already cached at
`<LABELLE_HOME>/provider-archives/<sha256>.tar.gz`. Otherwise resolve fails
without replacing the old lock. A hash mismatch is fatal even online; remove
the damaged archive and explicitly resolve again to fetch the same pinned
content. If GitHub serves different bytes for that commit, verification still
fails. Do not simply substitute the newly observed hash into a trusted record.

Archives must be self-contained: one directory root, regular files/directories,
no symlinks, hardlinks, path traversal or conflicting portable filenames. Entry
paths must be plain ASCII: case-insensitive filesystems also fold non-ASCII
letters (`Ä.zig` and `ä.zig` collide), the CLI only compares ASCII case, and
provider archives are source trees, so any non-ASCII byte in a path is
rejected. Paths must also be printable and free of Windows reserved device
names: an ASCII control character (bytes 1-31 and 127) is rejected, and so is
any path component whose name before the first `.` is `CON`, `PRN`, `AUX`,
`NUL`, `COM1`-`COM9`, `LPT1`-`LPT9`, `CONIN$` or `CONOUT$` in any case
(`nul.zig` and `aux/` included). Windows cannot create such files, so the
archive would resolve on Unix and fail extraction there. The CLI limits
compressed input to 128 MiB and expanded tar data to 512 MiB.

Compiler and Zig package dependencies must already be prepared. The project
compiler pin is checked and the host install step uses `--system` to disable
dependency fetching. Source extraction paths are intentionally unique; remote
providers may get less compiled-object reuse than local providers. This keeps
archive verification authoritative without another mutable source-cache index.
Provider build scripts remain trusted code, not sandboxed processes.

Shared provider settings, invocation overrides/JSON progress, hooks and
projectless bootstrap are separate remaining work. The registry starts empty;
do not publish placeholder releases for the platform-package scaffolds.

## Tests

```text
zig build
zig build test-provider-dispatch
python test/provider_dispatch_e2e.py --zig /path/to/zig
python test/provider_github_e2e.py --zig /path/to/zig
```

The GitHub test creates real compressed archives and runs the actual CLI
without network access. It covers preview/consent, archive/manifest validation,
remote command execution, tampering, temporary-source cleanup, old-cache
isolation, failed-resolution atomicity, unsafe entries, stale pins and explicit
version updates. Both subprocess suites run on all three CI hosts.

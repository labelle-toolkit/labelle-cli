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
declared by this project, and shows each exact commit, archive hash and archive
URL. Runtime-only packages not in the registry are ignored; a known provider
with no matching repo/version is an error. The preview also records exactly
what it showed, per package plus the registry source, together with a SHA-256
digest over the whole record, in the project-local file
`.labelle/providers.preview.json` (next to `labelle.providers.lock`; the
digest is printed so it can be compared against the file).

`--accept` never trusts a fresh registry fetch on its own. It first loads the
recorded preview (missing or unreadable: `ProviderPreviewMissing` /
`ProviderPreviewCorrupt`, "run `labelle providers resolve` first"), re-reads
the registry, and requires the fresh selection to equal the preview field by
field: registry source, package set, repo, version, commit, SHA-256 and
archive URL. Any difference aborts with `ProviderPreviewMismatch`, names the
package and changed field(s), writes nothing, and asks for a new preview.
Only then does it download source archives, verify SHA-256 against the
previewed hash, validate manifests and namespace/target ownership, and
atomically replace `labelle.providers.lock`. A successful accept removes the
preview file, so each accept is preceded by its own review. It does not run
any provider build code.

Commit both locks. The companion JSON lock avoids having ordinary game
generation erase integrity pins when it regenerates `labelle.lock`. A changed
project declaration is rejected until both locks match. Existing provider
versions in the registry must not be repointed; publish a new version instead.
The preview file is transient consent state, not a lock: do not commit it.

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

The same rule binds `--accept` to the preview. A registry that is repointed or
compromised between the two invocations cannot pin code nobody reviewed: the
accepting run only confirms the recorded commit/hash and prepares those exact
values, and a failed accept (mismatch, missing archive, bad manifest) keeps
both the old lock and the preview. Run `labelle providers resolve` again to
review the new entries before accepting them. Editing the preview file by
hand invalidates its digest and is treated like a missing preview.

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

[Shared provider settings](provider-configuration.md) and
[lifecycle hooks](provider-hooks.md) are now implemented. Invocation
overrides/JSON progress and projectless bootstrap remain. The registry starts empty;
do not publish placeholder releases for the platform-package scaffolds.

## Tests

```text
zig build
zig build test-provider-dispatch
python test/provider_dispatch_e2e.py --zig /path/to/zig
python test/provider_github_e2e.py --zig /path/to/zig
```

The GitHub test creates real compressed archives and runs the actual CLI
without network access. It covers preview/consent, preview-bound acceptance (a
registry changed between preview and accept, an edited preview, accept with no
preview), archive/manifest validation, remote command execution, tampering,
temporary-source cleanup, old-cache isolation, failed-resolution atomicity,
unsafe entries, stale pins and explicit version updates. Both subprocess suites
run on all three CI hosts. `zig build test-provider-dispatch` runs the
in-process twin of the preview binding against a real gzip archive.

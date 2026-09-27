# GitHub provider pins

The registry is just `providers.json` committed to the `labelle-registry`
GitHub repository. No registry service or publishing infrastructure is involved.
The exact schema lives in [provider contract v1](provider-contract-v1.md#4-github-manifest-and-project-integrity-lock).

## Using a declared provider

Declare the provider's exact package/repo/version in the project's `.plugins`
and ordinary `labelle.lock`, with the repo as `github.com/<owner>/<name>` (the
form the assembler fetches). The registry and the integrity lock spell the
same repository `<owner>/<name>`; resolve matches the two
([contract §4](provider-contract-v1.md#4-github-manifest-and-project-integrity-lock)),
also accepts `https://github.com/<owner>/<name>` and the bare form, and writes
the same lock for each. A repo on another host is refused
(`NonGitHubProviderRepository`). Then preview and explicitly accept
integrity pins:

```text
labelle providers resolve
labelle providers resolve --accept
labelle <namespace> <command>
```

The resolve command reads the GitHub manifest, selects only versions already
declared by this project, and shows each exact commit, archive hash and archive
URL. Runtime-only packages not in the registry are ignored; a known provider
with no matching repo/version is an error. For a schema-2 registry it also
shows each selected release's `namespace`/`targets` claims and the `defaults`
list, and it prints the registry schema and the SHA-256 of the normalised
registry document. The preview records exactly what it showed, per package
(pins and claims) plus the registry source, schema, defaults and normalised
document digest, together with a SHA-256 digest over the whole record, in the
project-local file
`.labelle/providers.preview.json` (next to `labelle.providers.lock`; the
digest is printed so it can be compared against the file).

`--accept` never trusts a fresh registry fetch on its own. It first loads the
recorded preview (missing or unreadable: `ProviderPreviewMissing` /
`ProviderPreviewCorrupt`, "run `labelle providers resolve` first"), re-reads
the registry, and requires it to equal the preview field by field: registry
source, registry `schema_version`, `defaults`, package set, and per selected
package repo, version, commit, SHA-256, archive URL, `namespace` and
`targets`. The rest of the document is bound too: if none of those fields
changed but the normalised document digest did, an unselected release record
changed. The choice is deliberate: "accept exactly what was shown" covers the
whole document, because an unselected record's claims still end up in the
cached ownership table used for target diagnostics, and a schema-2 document
swapped for an identical schema-1 one would silently turn the declaration
check below into a no-op. Whitespace and key order are not part of the
normalised document, so reformatting the file is not a change. Any difference
aborts with `ProviderPreviewMismatch`, names the changed field (and package),
writes nothing, and asks for a new preview. A preview written by an older CLI
(file format 1) is unreadable and asks for a new review.
Only then does it download source archives, verify SHA-256 against the
previewed hash, validate manifests and namespace/target ownership, and
atomically replace `labelle.providers.lock`. When the registry is schema 2
([contract §4](provider-contract-v1.md#registry-schema-2-ownership-tables-and-defaults)),
each release's `namespace`/`targets` claims must equal its verified
manifest's declarations. Otherwise `RegistryDeclarationMismatch` names the
release, and nothing is written. The lock itself stays schema 1. The registry kept for target diagnostics is
the normalised document the accepted preview bound (its bytes hash to the
preview's registry digest), never an unreviewed fetch. A successful accept removes the
preview file, so each accept is preceded by its own review. The lock rename is
the commit point: if the preview cannot be removed afterwards (for example a
read-only `.labelle`), the accept still exits 0 with the new lock in place and
warns that the preview must be deleted by hand. It does not run
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

## Fresh checkouts and CI: `labelle providers fetch`

A clone that has the committed `labelle.providers.lock` but an empty archive
cache cannot run normal commands: they never download, so even a desktop
`labelle generate` fails with `ProviderArchiveMissing` and a line naming the
package and `labelle providers fetch`. That command materialises exactly the
lock:

```text
labelle providers fetch            # download what is missing, verify, cache
labelle providers fetch --offline  # download nothing; verify the cache only
```

It reads the lock only (no registry, no preview, no `project.labelle`),
downloads each pin's `https://codeload.github.com/<repo>/tar.gz/<commit>`
that is not already cached and valid, and verifies it against the pinned
sha256 before caching it at `<LABELLE_HOME>/provider-archives/<sha256>.tar.gz`.
One mismatch or failed download fails the whole run, names the package and
caches nothing; the lock is never rewritten and no package code runs. An
archive that is cached and verifies is not downloaded again, so the command is
idempotent and safe to run on every CI job. A damaged cached archive is
replaced by verified bytes (normal commands report it as
`ProviderArchiveHashMismatch` and point here).

`labelle install` (no arguments, in a project) runs the same fetch after the
assembler has installed the project's packages, when the project has a
providers lock; a project without one is unaffected. So a new clone needs:

```text
labelle install
labelle generate
```

## Offline and recovery

```text
labelle providers resolve /path/to/registry/providers.json --offline --accept
```

Offline mode requires local metadata and archives already cached at
`<LABELLE_HOME>/provider-archives/<sha256>.tar.gz`. Otherwise resolve fails
without replacing the old lock. A hash mismatch is fatal even online; run
`labelle providers fetch` to replace the damaged archive with the pinned
content (for a pin not yet in the lock, remove it and resolve again). If
GitHub serves different bytes for that commit, verification still fails. Do
not simply substitute the newly observed hash into a trusted record.

The same rule binds `--accept` to the preview. A registry that is repointed or
compromised between the two invocations cannot pin code nobody reviewed: the
accepting run only confirms the recorded commit/hash and prepares those exact
values, and a failed accept (mismatch, missing archive, bad manifest) keeps
both the old lock and the preview. Run `labelle providers resolve` again to
review the new entries before accepting them. Editing the preview file by
hand invalidates its digest and is treated like a missing preview.

Archives must be self-contained: one directory root, regular files/directories,
no symlinks, hardlinks, path traversal or conflicting portable filenames.
Two paths that differ only in ASCII case are a duplicate
(`DuplicateProviderArchivePath`), and a regular file whose case-folded path is
an ancestor of another entry (`root/Foo` beside `root/foo/bar.zig`, in either
order) is rejected as `CaseFoldedProviderArchiveFileDirConflict`. Entry
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
registry changed between preview and accept, including a schema-2 to
schema-1 swap, a changed claim on a selected or unselected record and a
changed defaults list; an edited preview; accept with no preview), archive/manifest validation, remote command execution, tampering,
temporary-source cleanup, old-cache isolation, failed-resolution atomicity,
unsafe entries, stale pins and explicit version updates. It also covers the
project repo forms (`github.com/<owner>/<name>` and the bare form write the
same lock; another host is `NonGitHubProviderRepository`) and
`labelle providers fetch` on an empty cache (fail-closed hash mismatch that
caches nothing, verified fetch, idempotent re-run, `--offline`, the damaged
archive repair and `labelle install`), with a stand-in `curl` on `PATH`
serving the codeload URL from a local file on POSIX hosts. Both subprocess suites
run on all three CI hosts. `zig build test-provider-dispatch` runs the
in-process twin of the preview binding against a real gzip archive.

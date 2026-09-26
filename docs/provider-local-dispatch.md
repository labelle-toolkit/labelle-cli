# Project-local provider dispatch — phase 2, first slice

This documents the first executable part of phase 2 of CLI #406, stacked on the
[v1 contract](provider-contract-v1.md). **Phase 2 is not complete.** This slice
lets a project's explicitly declared local package expose a host command. It
does not migrate Android/web commands or change the core target/backend enums.

## Invocation and resolution

Run `labelle <namespace> <command> [arguments...]` from a project directory or
one of its descendants. Discovery walks to the nearest `project.labelle` and
reads manifests from that project's `.plugins`; it never searches global pins.
Built-ins take precedence, followed by package namespaces, then directory
shorthand. A package cannot claim a built-in namespace. Existing `android`,
`ios`, and `wasm` commands remain reserved until their extraction lands.

`labelle help`, a namespace with no command, `<namespace> --help`, and
`<namespace> <command> --help` print manifest metadata without resolving Zig,
requiring a lock, or executing a package build script. The last form requires
`--help` to be the only trailing argument; otherwise arguments are forwarded.

Provider manifests negotiate `command_contract`, require manifest version 2,
and validate command/hook records, namespace ownership and target ownership.
The assembler still owns unrelated top-level runtime fields. Nested provider
records reject unknown fields rather than silently discarding misspellings.

Execution requires an existing `labelle.lock` whose plugin name, repo and
version match the project declaration exactly. Local `local:`/`@` references
are explicit development inputs and intentionally follow local edits.
Remote commands now use the companion GitHub integrity lock described in
[GitHub provider pins](provider-github-pins.md). Commands without integrity pins
still fail with `RemoteProviderIntegrityRequired`; ordinary name/version records
alone never authorize remote execution.

## Host build and cache

The compiler must already be installed for the project's resolved Zig version.
An explicit `LABELLE_ZIG` path is supported, but its reported version must
match. Missing tools fail with installation guidance; invocation never calls
the downloader.

The runner executes the manifest's install-only step using:

```
zig build <build_step> --prefix <unique-invocation-prefix> --system <package-cache>
```

Zig's system package mode disables automatic dependency fetching and enables
system integrations; providers must support this mode. Dependencies must be
prepared beforehand in the Labelle Zig package cache. Build scripts are
trusted executable package code, not sandboxed processes.

Zig owns caching of source, imported modules, compiler, host and options. The
runner always evaluates the named install step; it does not use a shallow
timestamp check to skip dependency validation. Unchanged compiled objects are
reused and installed into a fresh isolated prefix. Only the exact declared
executable can run, with the native `.exe` suffix on Windows. Missing files,
directories and symlinks escaping the prefix fail before dispatch.

The command runs with the project root as cwd and receives trailing arguments
without shell interpolation. `LABELLE_CONTEXT` names its unique JSON context
file. This slice supplies the project's current platform, Debug optimization,
human progress, and the selected provider configuration path (or null). Output persists under
`.labelle/providers/<package>`; installation and context files are removed
after child exit, including failed builds, nonzero exits and crashes. The
provider must treat its context as read-only. Its exit status is preserved.

## Remaining phase-2 work

- GitHub archive integrity records and explicit project resolution are now
  implemented. Projectless/global pin handling remains later work.
- The shared CLI/assembler configuration schema and contained-file mapping are
  now implemented; see [provider configuration](provider-configuration.md) for
  the paired assembler requirement.
- Invocation overrides and JSON progress validation/relay. All trailing flags
  currently belong to the provider; this slice does not interpret them as CLI
  flags or claim to implement the full progress contract.
- Projectless resolution/bootstrap and global updates remain phase 5. Hook
  execution, generic target routing and platform extraction remain later work.

## Verification

`zig build test-provider-dispatch` runs focused manifest/dispatch tests; those
modules are also collected by `zig build test`. The real-process regression is:

```
zig build
python test/provider_dispatch_e2e.py --zig /path/to/zig
```

It creates a disposable project/provider, invokes the actual CLI, and verifies
safe help, lock/compiler errors, argv/context/cwd, artifact reuse, edits,
nonzero exits/crashes, cleanup, missing outputs, remote integrity refusal,
unsupported settings, ownership/contract errors and failed-build freshness.
CI runs it on Windows, macOS and Linux, including PRs stacked on another branch.

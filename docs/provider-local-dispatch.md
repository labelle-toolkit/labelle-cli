# Project-local provider dispatch — phase 2, first slice

This documents the first executable part of phase 2 of CLI #406, stacked on the
[v1 contract](provider-contract-v1.md). **Phase 2 is not complete.** This slice
lets a project's explicitly declared local package expose a host command. It
did not migrate Android/web commands or change the core target/backend enums
(Android has since moved into its provider, cli#405).

## Invocation and resolution

Run `labelle <namespace> <command> [arguments...]` from a project directory or
one of its descendants. Discovery walks to the nearest `project.labelle` and
reads manifests from that project's `.plugins`; it never searches global pins.
Built-ins take precedence, followed by package namespaces, then directory
shorthand. A package cannot claim a built-in namespace. The existing `ios`
and `wasm` commands remain reserved until their extraction lands; their
target already resolves like `--platform=<t>` does, through the pinned
provider that declares it ([provider targets](provider-targets.md)).
`android` left the reserved list with its extraction (cli#405): the
`android` package declares it as its namespace. A first word that is no
built-in, no pinned package's namespace and no directory is an unknown
command; when the cached schema-2 registry names a package declaring it as
a namespace, the diagnostic says so instead (`(registry: <package>)`).

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

## `labelle doctor` runs the providers' doctors

`labelle doctor [dir]` resolves the project root once, the way provider
commands do: the nearest `project.labelle` at or above `dir` (default: the
current directory). The core checks (backend, gamepad, Zig and emsdk
versions) and the provider doctors both read that root, so running it from a
project's subdirectory checks that project in full. It runs the core checks
first, as before. Then, inside a project, it runs the `doctor`
command of every pinned provider whose manifest declares a command named
exactly `doctor`, sorted by namespace, whatever their order in `.plugins`.
Each goes through the same path as `labelle <namespace> doctor`
(`provider_dispatch.runCommand`): the `labelle.lock` pin and the remote
integrity pin, the provider settings, the isolated tool build and the command
context, with no trailing arguments. Each provider gets a header
(`labelle <namespace> doctor  (provider '<package>')`) and an OK/FAIL line;
a closing line counts them and names the failed ones and the providers that
declare no `doctor` command.

- One provider failing (a non-zero exit, or a tool that cannot be built or
  started) does not stop the others. `labelle doctor` exits non-zero when the
  core checks or any provider doctor failed.
- A pinned provider whose archive is not cached, or does not match its pin,
  is a failed check with the `labelle providers fetch` hint. The doctor never
  downloads ([contract §4](provider-contract-v1.md#4-github-manifest-and-project-integrity-lock)).
- One package never fails the others. A pinned or local provider whose
  manifest cannot be read, parsed or matched to its name is a failed check of
  its own. An unpinned package's manifest is read only to tell a runtime-only
  package from a provider; if it is unreadable or malformed, the package is
  reported as unverified (below), the same as when it is not cached at all.
- Settings are resolved per provider: each provider's doctor opens only its
  own `provider_config` file, so a missing or invalid settings file fails
  that provider alone. The project-wide mapping (every entry names a
  resolved, verified provider) is checked once and, if broken, reported once
  as a failed `provider_config` check; the doctors still run. Entries naming
  a package the doctor could not read or verify are left out of that check,
  since the package already has a failed check of its own. Duplicate or
  undeclared entries and malformed paths are refused when `project.labelle`
  is read, which fails the provider part as a whole. `labelle <ns> <cmd>`
  and hooks keep validating every settings file before they run.
- A declared remote package with no integrity pin is a failed check with the
  `labelle providers resolve` hint, and its code is never run. The report is
  the same whether the ordinary package cache holds the package or not: an
  uncached one cannot be told apart from a provider, so it fails closed. A
  runtime-only package needs no pin; once it is in the package cache
  (`labelle install`) its manifest shows it is no provider and the check
  clears. A stale pin gets the same `providers resolve` hint.
- Outside a project only the core checks run, followed by one line saying that
  provider doctors run inside a project. Projectless provider commands are a
  later phase (decision D8).
- `--core-only` skips the provider part. `--json` (the studio capability
  report) stays core-only.

Nothing in the core names a provider: who takes part comes from the manifests.

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
  execution is now implemented; see [provider hooks](provider-hooks.md).
  Generic target routing is now implemented; see
  [provider targets](provider-targets.md). Platform extraction remains
  later work.

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

# Provider contract v1

Status: normative contract for [CLI #406](https://github.com/labelle-toolkit/labelle-cli/issues/406) and [#411](https://github.com/labelle-toolkit/labelle-cli/issues/411). Local dispatch and project GitHub integrity pins are implemented; shared settings, lifecycle hooks and provider-declared targets are implemented; progress overrides and platform extraction remain pending.

Implementation progress: [project-local dispatch](provider-local-dispatch.md)
implements the first executable slice of phase 2. Its explicit limitations
do not weaken the normative contract below; full phase-2 acceptance is pending.

This document supplies normative v1 details for [the architecture RFC](rfc-package-commands.md). Where the illustrative RFC conflicts, this contract takes precedence. Migration is breaking: no legacy forwarding or implicit provider injection. Contract negotiation checks a provider's declared semver range against the exact CLI contract version; it never warns and proceeds. The v1 context below uses the exact wire version `1.0.0`; additional wire versions require explicit decoder support.

## 1. Package declarations and installed tools

The package's existing ZON `plugin.labelle` remains the declaration source. Runtime-only packages need no command fields. A provider uses `manifest_version = 2`, declares `command_contract`, and may declare `namespace`, `commands`, `hooks`, and `targets`. Names use `[a-z][a-z0-9_-]*`; names are case-sensitive.

A command has required `name`, `build_step`, `executable`, and `help`, with optional `needs_project` (default true). A hook has required `id`, `step`, `target`, `when`, `build_step`, and `executable`, with optional `after_hooks` (default empty). Valid steps are `generate`, `build`, `bundle`, `run`; phases are `before`, `replace`, `after`. There is no separate package lifecycle step: `bundle` produces the target distributable.

```zig
.commands = .{
    .{ .name = "doctor", .build_step = "cmd-doctor", .executable = "bin/provider-doctor",
       .help = "Check platform requirements", .needs_project = false },
},
```

`build_step` is an install-only step in the package's build graph. The runner invokes `zig build <build_step> --prefix <isolated-prefix>` for the host, with resolved tool dependencies and compiler pinned in advance. The step installs exactly one executable selected by `executable`; it may install supporting data/libraries too. The runner does not guess an artifact from the step name, run the step as the command, or select the first executable found.

`executable` is a portable forward-slash path under `bin/`, without a native suffix, absolute prefix, empty component, `.` or `..`. The runner adds `.exe` on Windows. It verifies that the declared file exists and that its resolved path remains inside the install prefix, including through symlinks. Missing/non-executable outputs fail before dispatch. Provider build scripts wire their own modules; the CLI does not reconstruct module imports. Build scripts are executable code under the same consent/pinning boundary as provider execution.

Commands require a namespace and unique names. Resolve-time validation rejects reserved CLI namespaces and duplicate namespace/target owners. Core owns `desktop`; no package may claim it. Hooks may attach to it without owning it.

## 2. One command-context wire format

The CLI creates a UTF-8 JSON file and passes its absolute filename in `LABELLE_CONTEXT`. There is no argument-encoded alternative. The provider receives trailing user arguments verbatim through argv, without shell interpolation; the context path is not inserted into argv. The CLI owns the context-file lifetime through process exit and removes it afterward. Providers treat it as read-only.

Every field below is required. Nullable fields must be present as JSON null. Unknown fields, duplicate keys, malformed enums, unsupported versions and inconsistent project fields are errors. The tested decoder is `src/cli/provider_contract.zig`.

| Field | Type / rule |
| --- | --- |
| `contract_version` | Exactly `"1.0.0"` for this decoder |
| `invocation` | Object containing `kind`, `id`, `step`, `phase` |
| `invocation.kind` | `"command"` or `"hook"` |
| `invocation.id` | Command name or hook ID |
| `invocation.step`, `invocation.phase` | Null for commands; valid step/phase for hooks |
| `package_dir` | Absolute resolved provider source directory |
| `project_dir` | Absolute project directory, or null |
| `target` | Resolved target identifier, or null outside a project |
| `lock_file` | Absolute project lock filename, or null outside a project |
| `config_file` | Absolute provider-owned configuration filename, or null |
| `output_dir` | Absolute invocation output directory, including projectless runs |
| `zig_executable` | Absolute host compiler filename |
| `optimize` | `Debug`, `ReleaseSafe`, `ReleaseFast`, or `ReleaseSmall` |
| `progress` | `human`, `json`, or `off` |

Paths use host syntax and must be absolute (on Windows, drive-qualified or UNC, not current-drive-rooted). Structural validation does not perform filesystem existence/containment checks; the resolver performs those before launching.

Inside projects, `target` and `lock_file` are required and non-null. Outside projects, `project_dir`, `target`, `lock_file`, and `config_file` are null and optimize is Debug. Hooks always require a project. A projectless output directory is a per-invocation workspace, never the provider's source cache. The actual filesystem checks, allocation and cleanup are phase-2 runner responsibilities.

Progress uses standard streams rather than invented OS handles: in JSON mode stdout carries the existing CLI NDJSON progress protocol and stderr carries diagnostics; in human/off modes normal command output is permitted. The CLI parses/relays JSON events and owns the single final command outcome. Nonzero provider exit or abnormal termination is failure. No secret values belong in the context or progress stream.

There is **no credentials-helper RPC in v1**. Providers use explicitly configured environment-variable names or their own OS credential integration. Provider configuration stores references, not secret values. This avoids promising a helper endpoint before its protocol exists.

## 3. Provider-owned project settings

Introduce one generic project field mapping package identity to a provider-owned JSON file:

```zig
.provider_config = .{
    .{ .package = "labelle-android", .file = "providers/android.json" },
},
```

Each entry has exactly `package` and `file`; package entries are unique and must refer to a resolved declared provider. The file is project-relative and must resolve within the project, including through symlinks. The resolver passes its absolute path as `config_file`. Absence maps to null. The provider owns the JSON schema and rejects invalid or missing required settings before side effects. Configuration content participates in build/staging freshness; credentials values do not enter generated files.

Move the former platform-specific settings into these files in the platform migration PRs; do not silently translate or continue accepting removed fields. The schema must be accepted by the shared project parser/assembler boundary before consumer migration. The CLI and assembler now share this schema. See [provider configuration](provider-configuration.md) for validation, file containment and rollout requirements.

## 4. GitHub manifest and project integrity lock

The agreed registry is a GitHub repository, `labelle-toolkit/labelle-registry`,
containing `providers.json`. Read it directly from raw GitHub or from a local
checkout. There is no R2 endpoint, publication service or generated snapshot.
This replaces the earlier proposed index/global-lock schema.

Registry and project integrity lock use the same strict UTF-8 JSON shape:

```json
{
  "schema_version": 1,
  "providers": [
    {
      "package": "labelle-example",
      "repo": "labelle-toolkit/labelle-example",
      "version": "1.0.0",
      "commit": "<40 lowercase hex characters>",
      "sha256": "<64 lowercase hex characters>"
    }
  ]
}
```

The placeholders above must be replaced with real values. The archive URL is
constructed as `https://codeload.github.com/<repo>/tar.gz/<commit>`; arbitrary
archive hosts, tags and branch names are not accepted. SHA-256 covers the
compressed archive bytes, separately from any Zig dependency content hashes.
Duplicate JSON keys, unknown fields, duplicate package/version records,
repository conflicts and unsupported schemas are errors. A project lock
contains at most one version per package. Releases are stable exact semver.

`labelle providers resolve [providers.json]` previews the exact project-declared
versions, commits and hashes and records them, with a digest, in
`.labelle/providers.preview.json`. `--accept` requires the registry to still
equal that recorded preview (any changed field aborts with
`ProviderPreviewMismatch`; no preview aborts with `ProviderPreviewMissing`),
verifies archives against the previewed hashes and provider manifests, checks
ownership, then atomically writes `labelle.providers.lock` and removes the
preview.
Commit it alongside `labelle.lock`, which remains the ordinary dependency lock
and is not rewritten by provider resolution. No package code runs during
resolution. A failed resolve leaves the previous integrity lock intact.

Normal commands use only matching project pins and cached archives; no
registry lookup, download or pin update is implicit. Verify the archive hash
on every invocation, extract into a fresh temporary directory, and remove it
afterward. Never execute the older unverified plugin extraction cache. Missing
or corrupted archives fail closed. Repair the cached archive and explicitly
resolve again; a changed GitHub archive is not automatically accepted.

Namespace, target and command-contract declarations come from the verified
`plugin.labelle`, rather than duplicated registry metadata. Source archives
must be self-contained and have one root directory. Unsafe paths, links,
case-insensitive duplicate paths and unsupported entry types are rejected.
Compiler and Zig dependencies still require explicit preparation; host builds
use Zig system-package mode to disable dependency downloads.

`--offline` requires local metadata and cached archives. Global/projectless
bootstrap and default-package selection remain later work using GitHub data;
they do not require a separate publishing service. CLI self-update never
changes provider pins.

## 5. Default-package consent

Whether defaults come from the online index or an offline stamped scaffold, `init` presents their exact resolved package/version/source/hash records before writing pins or executing package code. Accept explicitly; noninteractive automation supplies an explicit acceptance option, otherwise fail rather than hang. Declining leaves no initialized project or provider pins. Offline initialization requires complete cached release metadata/content and compiler prerequisites for any work it executes.

Index defaults are suggestions, not automatically trusted project declarations. Initial acceptance covers the complete resolved dependency graph; changes to that graph require explicit resolution. Merely fetching/parsing metadata is allowed before consent, but compiling or executing package build scripts is not.

## 6. Hook execution

Resolve stable hook identities as `<package>/<hook-id>`. Within each target/step, execute before hooks, the core operation or unique replacement, then after hooks. Provider dependencies create ordering edges within a phase; explicit `after_hooks` refine hook ordering. Break independent ties by fully qualified hook ID. Reject missing hook references, cycles, dependencies on later phases, and multiple replacements before execution. A replacement belongs only to the target owner. Sequential execution is sufficient for v1.

Stop on any failed hook/operation; after hooks run only after success. For `run`, success means the game process itself exited with status 0: a game the `--timeout` watchdog stopped, or a simulator/device launch that returns while the app is still running, is not a success even though the CLI's own exit status is 0, and its after hooks are skipped with one diagnostic line. Hooks clean up their own temporary resources. Do not run publishing hooks after a failed build or reuse an old output as a new success. Graph construction/execution and its fixture tests belong to phase 3.

## 7. Backend agnosticism migration

Keep the mandate: backend names must also leave core. Add an explicit migration deliverable coordinated with assembler #378: replace the fixed backend enum with a resolved manifest identity, move target-support declarations out of `compatibility.zig`, and replace backend-name branches in `pipeline.zig` with declared capabilities. The shared project schema must accept the identity before consumers switch.

Keep specific existing sites on the shrinking migration allowlist until replaced; do not claim the guard is complete after moving platform commands alone. Desktop stays a core target, but its renderer is still a manifest-resolved backend. No backward aliases for removed enum/config forms.

## Delivery and evidence

Phase 1 supplies this contract, wire-context validation, installed-tool path validation, ownership conflict checks and target lookup. `zig build test-provider-contract` runs those tests; `zig build test` includes the same target, avoiding an uncollected test root.

Phase 2 implements manifest/range parsing, GitHub integrity pins, config mapping, filesystem validation, host-tool build/discovery/cache and process dispatch. Phase 3 implements hook planning and the Android provider; phase 4 consolidates packaging/Gradle; phase 5 enables projectless resolution/updates using the same GitHub repository. Registry records are ordinary reviewed commits, not a publication service.

Hook planning and execution (§6) are implemented for the four core steps; [provider hooks](provider-hooks.md) documents the ordering rules, the step output-directory layout, the hook context and the remaining limitations.

Before #411 closes, review all six decisions against the architecture RFC. Before the feature is called implemented, exercise actual provider subprocesses, artifact discovery, consent failures, hash failures, host/toolchain cache separation, offline execution and atomic-update recovery. Passing the phase-1 pure tests does not claim those later behaviors work.

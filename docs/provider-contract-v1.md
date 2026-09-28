# Provider contract v1

Status: normative contract for [CLI #406](https://github.com/labelle-toolkit/labelle-cli/issues/406) and [#411](https://github.com/labelle-toolkit/labelle-cli/issues/411). Local dispatch and project GitHub integrity pins are implemented; shared settings, lifecycle hooks and provider-declared targets are implemented; progress overrides and platform extraction remain pending.

Implementation progress: [project-local dispatch](provider-local-dispatch.md)
implements the first executable slice of phase 2. Its explicit limitations
do not weaken the normative contract below; full phase-2 acceptance is pending.

This document supplies normative v1 details for [the architecture RFC](rfc-package-commands.md). Where the illustrative RFC conflicts, this contract takes precedence. Migration is breaking: no legacy forwarding or implicit provider injection. Contract negotiation checks a provider's declared semver range against the wire versions the CLI speaks; it never warns and proceeds. See [Wire versions and negotiation](#wire-versions-and-negotiation) below: the CLI implements `1.4.0` and still speaks `1.3.0`, `1.2.0`, `1.1.0` and `1.0.0`, and every context carries the negotiated version.

## 1. Package declarations and installed tools

The package's existing ZON `plugin.labelle` remains the declaration source. Runtime-only packages need no command fields. A provider uses `manifest_version = 2`, declares `command_contract`, and may declare `namespace`, `commands`, `hooks`, `targets` and `target_defaults`. Names use `[a-z][a-z0-9_-]*`; names are case-sensitive. A target name (declared or a hook's) is additionally never a Windows reserved device name (`con`, `nul`, `prn`, `aux`, `com1`-`com9`, `lpt1`-`lpt9`), because the CLI names directories after it.

A command has required `name`, `build_step`, `executable`, and `help`, with optional `needs_project` (default true). A hook has required `id`, `step`, `target`, `when`, `build_step`, and `executable`, with optional `after_hooks` (default empty) and `watch` (default false). `watch = true` declares that a `run` replacement can run a watch session (see [Watch sessions](#watch-sessions)); it is valid only on a hook with `.step = .run, .when = .replace`, and any other hook declaring it is a manifest error (`WatchRequiresRunReplace`). Valid steps are `generate`, `build`, `bundle`, `run`; phases are `before`, `replace`, `after`. There is no separate package lifecycle step: `bundle` produces the target distributable.

```zig
.commands = .{
    .{ .name = "doctor", .build_step = "cmd-doctor", .executable = "bin/provider-doctor",
       .help = "Check platform requirements", .needs_project = false },
},
```

A command named exactly `doctor` has one extra caller: inside a project, `labelle doctor` runs it after the core checks, for every pinned provider that declares it, in namespace order, exactly as `labelle <namespace> doctor` would run it with no trailing arguments (same lock and integrity checks, settings, isolated build and `command` context with `invocation.id = "doctor"`). A non-zero exit, or a failure to build or start the tool, fails the aggregate `labelle doctor` without stopping the other providers' doctors. A provider should therefore make `doctor` side-effect free and exit non-zero only when a requirement is missing. See [project-local dispatch](provider-local-dispatch.md#labelle-doctor-runs-the-providers-doctors).

`build_step` is an install-only step in the package's build graph. The runner invokes `zig build <build_step> --prefix <isolated-prefix>` for the host, with resolved tool dependencies and compiler pinned in advance. The step installs exactly one executable selected by `executable`; it may install supporting data/libraries too. The runner does not guess an artifact from the step name, run the step as the command, or select the first executable found.

`executable` is a portable forward-slash path under `bin/`, without a native suffix, absolute prefix, empty component, `.` or `..`. The runner adds `.exe` on Windows. It verifies that the declared file exists and that its resolved path remains inside the install prefix, including through symlinks. Missing/non-executable outputs fail before dispatch. Provider build scripts wire their own modules; the CLI does not reconstruct module imports. Build scripts are executable code under the same consent/pinning boundary as provider execution.

Commands require a namespace and unique names. Resolve-time validation rejects reserved CLI namespaces and duplicate namespace/target owners. Core owns `desktop`; no package may claim it. Hooks may attach to it without owning it.

### Target defaults

A target's owner may declare defaults for the targets it declares in `.targets` (CLI 2.1.0+; manifest data, not a wire key, so any `command_contract` range may use it):

```zig
.targets = .{"sample-target"},
.target_defaults = .{ .{ .target = "sample-target", .optimize = .ReleaseSafe } },
```

Each record has exactly the keys `target` and `optimize` (`Debug`, `ReleaseSafe`, `ReleaseFast` or `ReleaseSmall`); unknown keys are a parse error. A record for a target the same manifest does not declare in `.targets` is `TargetDefaultRequiresOwnedTarget` (only the owner speaks for a target, so no two packages can disagree), and two records for one target are `DuplicateTargetDefault`, even when they agree.

The effective optimize mode of a build is, in order: an explicit `--optimize=<mode>`; else the owner's `target_defaults` entry for the resolved target; else the core's own fallback for that target, if it has one; else none (Zig's default, Debug). The chosen mode is what the core `zig build` gets as `-Doptimize=<mode>` and what every hook receives as the wire `optimize`. A watched rebuild's replan recomputes it from the providers it rediscovers, so an edited default reaches the next rebuild, and an explicit flag still wins.

## 2. One command-context wire format

The CLI creates a UTF-8 JSON file and passes its absolute filename in `LABELLE_CONTEXT`. There is no argument-encoded alternative. The provider receives trailing user arguments verbatim through argv, without shell interpolation; the context path is not inserted into argv. The CLI owns the context-file lifetime through process exit and removes it afterward. Providers treat it as read-only.

Every field below is required on the wires that define it, except the optional `build_number` and `run`. Nullable fields must be present as JSON null. A key is never emitted on a wire older than the one that added it. Unknown fields, duplicate keys, malformed enums, unsupported versions and inconsistent project fields are errors. The tested decoder is `src/cli/provider_contract.zig`.

| Field | Type / rule |
| --- | --- |
| `contract_version` | The negotiated wire version: `"1.0.0"`, `"1.1.0"`, `"1.2.0"`, `"1.3.0"` or `"1.4.0"` for this decoder |
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
| `build_number` | **Optional**, **wire `1.1.0`+**: the non-empty `labelle bundle --build-number` value, present only in a `bundle`-step hook's context when the user passed it and the negotiated wire is `1.1.0` or newer; absent (never null) otherwise, and an error on any other invocation or on a `1.0.0` context |
| `target_dir` | **Wire `1.2.0`+, required there**: on a hook, the absolute generated target directory (`.labelle/<backend>_<target>/`), the same for every step whatever `output_dir` is; null on a command. The key doesn't exist below `1.2.0`, not even as null |
| `run` | **Optional**, **wire `1.2.0`+**: present on every `run`-step hook context (any phase) and absent (never null) everywhere else. An object with the required keys `env`, `args` and `timeout_ms`, plus `watch` from wire `1.3.0` (see below) |
| `cache_dir` | **Wire `1.3.0`+, required there, never null**: the provider's persistent cache directory, on every context (commands and hooks). See [Provider cache](#provider-cache). The key doesn't exist below `1.3.0` |
| `env_file` | **Wire `1.3.0`+, required there**: on a `before generate`, `after generate` or `before build` hook, an absolute path the hook may write its environment contribution to; null on every other hook and on commands. See [Environment contributions](#environment-contributions). The key doesn't exist below `1.3.0` |
| `final_step` | **Wire `1.4.0`+, required there**: on a hook, the last lifecycle step of the CLI command that runs it (see [§6](#6-hook-execution)): `"generate"` (`labelle generate`, and the legacy `labelle ios` subcommand, which only runs the generate hooks), `"build"`, `"run"` (`labelle run`, every watched rebuild included) or `"bundle"`. It is always a step the hook's own step leads to: any value on a `generate` hook, never `"generate"` on a `build` hook, and exactly its own step on a `run` or `bundle` hook; anything else is an error. Null on a command. The key doesn't exist below `1.4.0` |

The `run` object holds the `labelle run` options for a hook that wraps or replaces the launch:

| Key | Type / rule |
| --- | --- |
| `env` | Array of `{ "name", "value" }`. These are the platform-neutral `LABELLE_*` variables the core launch sets for `--scene`, `--profile`, `--screenshot` and `--after` (`LABELLE_SCENE`, `LABELLE_PROFILE`, `LABELLE_SCREENSHOT_PATH`, `LABELLE_SCREENSHOT_AFTER_SEC`), in that order. An option the user didn't pass adds nothing. Names match `[A-Za-z_][A-Za-z0-9_]*` and are unique; values contain no NUL |
| `args` | The tokens after `--`, verbatim, as an array of strings |
| `timeout_ms` | `--timeout` in milliseconds, or null |
| `watch` | **Wire `1.3.0`+, required there; absent below.** Null outside a watch session and on every `run` hook but the replacement. On the replacement of `labelle run --watch`: `{ "generation_file": "<abs>", "output_dir": "<abs>" }` (see [Watch sessions](#watch-sessions)). Unknown keys inside it are errors |

The CLI doesn't map these to any platform. The provider decides how they reach its game, for example as launch extras on a device. A hook on another step, or a command, that carries `run` is an error, and so is a `1.2.0` `run`-step hook without it.

### Provider cache

`cache_dir` is `<LABELLE_HOME>/providers/<canonical provider id>/` (`LABELLE_HOME` defaults to `~/.labelle`). The CLI creates it before the invocation and never deletes it; it persists across provider versions and projects.

The canonical id names what the provider is, not what a project calls it, so every project that pins the same provider shares one cache:

- A pinned GitHub provider: `github.com/<owner>/<name>`, from its `.repo` normalised the way pins are compared (`git+`, a scheme, `user@`, the `github.com` host in any case, `?ref`/`#sha`, trailing slashes and `.git` dropped) and lowercased, because GitHub names are case-insensitive. A segment Windows cannot create is escaped with `~`, which no GitHub name contains, so the escape never collides with another repository: a reserved device stem gets `~` before its first dot (`con` becomes `con~`, `con.tools` becomes `con~.tools`), and a trailing `.` gets `~` after it (`name.` becomes `name.~`).
- A local provider (`local:<path>`, `@<path>`): `local/<name>-<hash>`, where `<hash>` is the first 32 hex digits of the SHA-256 of the provider directory's canonical real path (lowercased on Windows) and `<name>` is that directory's basename reduced to `[a-z0-9._-]`. Two projects pointing at one checkout share it; a moved checkout gets a new one.

The provider owns everything inside. A provider that installs toolchains there must:

- key each install by host (OS and architecture) and by SDK identity (version plus the pinned commit or hash), since one cache may serve several machines through a shared home directory and several SDK versions across projects;
- make installation safe under concurrency: two builds installing the same SDK at once must end with one valid install and no partial tree. Take a lock (for example an exclusive file lock beside the install) and install into a temporary sibling that is atomically renamed into place once complete; treat a directory without its completion marker as absent;
- version its own layout, so a later release can tell an old layout from a new one.

The CLI does not migrate, prune or garbage-collect the cache.

### Environment contributions

A `before generate`, `after generate` or `before build` hook receives `env_file` (wire `1.3.0`+): an absolute path in a fresh, private, per-invocation directory. The file does not exist when the hook starts; the hook may create it. After the hook exits 0 the CLI reads it and deletes the directory:

```json
{ "set": [ { "name": "SDK_ROOT", "value": "/abs/sdk" } ], "path_prepend": [ "/abs/sdk/bin" ] }
```

- **Format.** Strict JSON; both keys are optional; unknown keys, duplicate keys and wrong types are errors. Each `set` entry has exactly `name` and `value`.
- **Names** match `[A-Za-z_][A-Za-z0-9_]*`, appear once per file, and are not CLI-owned. The CLI-owned names are a fixed table (`config.reserved_env` in `src/cli/config.zig`), not a `LABELLE_*` prefix ban: `PATH` (extend it with `path_prepend`), `ZIG_GLOBAL_CACHE_DIR`, `ZIG_LOCAL_CACHE_DIR`, every `LABELLE_*` variable the CLI reads (`LABELLE_HOME`, `LABELLE_CONTEXT`, `LABELLE_OFFLINE`, `LABELLE_ZIG`, `LABELLE_ASSEMBLER`, …) and the `labelle run` options it sets for the game. Any other name may be set, `LABELLE_*` or not; a toolchain library directory such as `LABELLE_SDL2_LIB` stays settable. A test fails when the CLI source spells a `LABELLE_*` name the table does not classify.
- **`path_prepend`** entries are absolute paths for the host (drive-qualified or UNC on Windows) and contain no PATH separator.
- **File states.** Missing: no contribution, which is normal. Empty, malformed (including a reserved name, a bad name or a relative PATH entry) or larger than 1 MiB: the command fails right after that hook, before any later zig invocation, with `labelle: hook '<package>/<id>' wrote an invalid env_file: <reason>`. Written by a hook that then failed: ignored; the hook's failure is the outcome.

**Merge.** Contributions apply in hook execution order (phases, `after_hooks` edges, then qualified ID) and accumulate across the phases of one build:

- A contributed variable overrides the inherited environment (a provisioned toolchain must win over a stale shell value; a provider that wants to honour the user's value reads it from its own environment and writes it back).
- Two hooks setting one name to different values fail the command with `labelle: hook environment conflict: '<name>' is set to different values by hooks '<a>' and '<b>'`; the same value twice is fine.
- `path_prepend` entries go in front of the inherited `PATH` in hook order, then list order, deduplicated keeping the first occurrence. The inherited `PATH` itself is not rewritten.
- On Windows names compare case-insensitively (`Path` is `PATH`), for conflicts and overrides alike, and an inherited key keeps its spelling; PATH entries also deduplicate case-insensitively.

**Freshness.** The environment is built for each build from the inherited environment plus the contributions of the hooks that ran in that build; a watched rebuild starts over. A hook a replan removed leaves nothing behind. A watched rebuild that fails, at any stage, keeps the environment of the last successful build (the one being served, and the one the session's `after run` hooks get); only a rebuild that succeeds replaces it.

**Scope.** The merged environment reaches every later zig invocation and hook process of the same command: the generation-time fingerprint pass (`zig build --list-steps`, which configures the generated build and so is the first toolchain consumer: a `before generate` contribution reaches it, an `after generate` one does not), the core `zig build` compile, and every later hook and replacement (`after generate`, `before`/`replace`/`after build`, `bundle` and `run` hooks). It never reaches the build of a provider's own tool (`zig build <build_step>` in the provider's package), which runs on the plain inherited environment plus the CLI's cache variables, so a provider cannot change how other providers' tools are built. The game the core `labelle run` launches keeps its own environment (the inherited one plus the run options); a provider that must reach the game uses a `run` replacement. The runtime `SDL2.dll` the core stages beside a desktop exe is looked up through `LABELLE_SDL2_LIB` as the compile saw it, so a contributed value is honoured.

**No silent bypass.** A build path that cannot carry a provider's contribution or its optimize default refuses before any hook, generation or build, naming the hook or package. `--docker` builds in a container the contributions never reach, so a `build`, `run` or `bundle` (any command that reaches the container build) whose plan has a hook that may contribute (one in a contributing slot whose provider negotiates `1.3.0` or newer) is refused; `labelle generate --docker` is not, since it stops after generation and its host-side fingerprint pass gets the contributions, and neither is a build the target owner replaces, since its `replace build` hook gets them like every hook: `--docker doesn't carry provider environment contributions; build without --docker`. (`--docker` does pass the effective optimize mode as `-Doptimize`.) The legacy `labelle ios` subcommand runs its own `zig build` after generation, with neither, so it is refused when the plan has such a hook or the target's owner declares an optimize default; `labelle build --platform=ios` carries both.

### Watch sessions

`labelle run --watch` (CLI 2.1.0+) keeps a long-lived run replacement — a browser dev server, say — running while the CLI watches the project, rebuilds and publishes. The CLI owns the generic part: file watching, debouncing, rebuild orchestration with every hook phase, publication and the generation notification. The provider owns serving and reloading; the CLI has no HTTP or reload code on this path.

**Capability.** A session needs the target's `run` replacement to declare `.watch = true` **and** its provider to negotiate wire `1.3.0` or newer. Negotiating `1.3.0` alone is not enough: it means the provider can decode `run.watch`, not that its replacement stays alive and consumes it. Anything else is refused before any build, naming what is missing:

- `labelle: run --watch: target '<t>' has no run replacement to watch through` (a core target such as `desktop`, or a provider target without a replacement: native/desktop watch is not supported);
- ``labelle: run --watch: package '<p>' does not declare `.watch = true` on its run replacement '<p>/<id>' for target '<t>'``;
- `labelle: run --watch: package '<p>' speaks provider contract 1.2.0; its run replacement '<p>/<id>' needs >= 1.3.0 to receive run.watch`.

`--watch` cannot be combined with `--docker` (a usage error: exit status 2). One session runs per project and target: a second `labelle run --watch` for them is refused, before it starts its progress feed or runs any prebuild step, install, lock write or build, while the first one runs. The first session holds an OS lock (`flock` / `LockFileEx`) on `.labelle/.watch/<backend>_<target>.lock`, which records its PID for the refusal (cleared on a clean exit, so only a session that died without releasing it is reported as a stale takeover); the lock ends with its process, however it ends, so a stale lock is taken over, and by exactly one of two sessions racing for it.

**Publication.** The core builds into the ordinary staging tree (the `build` step's `output_dir`, `<target_dir>/zig-out`). Only once a rebuild has fully succeeded — every generate and build phase, the compile and every `after build` hook — does it publish:

1. the staged tree is copied into a `published-<n>/` directory the copy itself creates in the session directory (`.labelle/.watch/<backend>_<target>/`): a leftover directory of that name (a cleanup that failed) is never merged into, the copy goes to `published-<n>-<k>/` instead;
2. `run.watch.output_dir` (`<session>/current`) is switched to it atomically. On POSIX it is a relative symbolic link, replaced by renaming a new link over it. On Windows it is a directory junction (no privilege needed) whose reparse data is rewritten in place with `FSCTL_SET_REPARSE_POINT`, one filesystem operation; should the in-place rewrite be refused, the junction is recreated, which is not atomic and is reported once; if recreating it fails, the previous junction is put back;
3. only then — after the rebuild's last cancel check and the commit of its staged `labelle.lock` (below) — is `run.watch.generation_file` advanced: an ASCII decimal number and a newline, written to a temporary file and renamed over the old one. Should that write (or the lock commit) fail after the switch, `output_dir` is switched back to the previous publication (or removed, before the first one), so the generation file and the served output never disagree; only if the switch back fails too is the mismatch reported.

An entry the filesystem lists without a type (NFS, FUSE) is typed with a `stat` of the entry. The copy preserves symbolic links as links (never following them, so a link back to an ancestor cannot recurse). A link whose target lies inside the staged tree is written relative to its own directory, an absolute one included, so it names the published file rather than the mutable staging tree or a host path. A link whose target lies outside the staged tree, relative or absolute, is skipped with a warning; so is a link that cannot be created (Windows without the privilege).

The cold build is published as generation `0` before the replacement starts. A failed rebuild publishes nothing: `output_dir` and the generation keep naming the last successful output. The previous published directory is kept (a request may still be reading it); every other one is deleted after each publication, and the whole session directory when the session ends. A provider polls `generation_file`, re-resolves `output_dir` once it changes (never caching its resolved target), serves only from `output_dir` and reloads its clients; it never reads the staging tree.

**Session changes.** A script or asset change rebuilds; so does a build-only configuration change, which replans atomically. A change the running replacement depends on ends the rebuild with `labelle: restart labelle run --watch: <what> changed` and publishes nothing: the provider package, its version or its pin (for a remote provider, the commit and archive SHA-256 `labelle.providers.lock` accepts); the negotiated wire version; the replacement hook (id or tool); the `.watch` capability; the `before run` hooks (they ran once, before the replacement started); the backend; the target (when it comes from `project.labelle`); the output location; the effective optimize mode; the replacement's `provider_config` mapping or file contents; the Zig version the project requires; the `assembler_version` pin; the source of a local provider the replacement runs from (its own, or a `before run` hook's owner — the contents of its files, except its `plugin.labelle`, whose declarations are compared above, its build output, its dot directories and the project itself when the provider contains it; a file that vanishes mid-walk is absent); or the environment the rebuild's hooks contribute (the replacement keeps the one it was launched with). The `before run` identity includes each hook's owning provider (its version, verified pin, wire and settings mapping), whichever package that is. The replacement keeps the configuration it started with; the session keeps watching, and reverting the change rebuilds normally.

**Transactional rebuilds.** A rebuild re-reads `project.labelle` before its prebuild steps, so an added, removed or changed `.prebuild` step runs (or stops running) in the rebuild that sees the edit, and the watch ignore set (the steps' declared `.outputs`) is swapped together with the steps. Everything a rebuild's replan changes — providers, configuration, prebuild steps, plans, optimize mode, lock file and environment — is staged and committed only when the whole rebuild (its publication included) succeeds; any failure restores all of it. The lock of an edited project is written to `.labelle/labelle.lock.staged`, which the rebuild's hooks verify their pins against and receive as `lock_file` (a provider must use the `lock_file` it is given, never a fixed name); the project's `labelle.lock`, the path the running replacement holds, changes only at the rebuild's commit point (renamed over it), before the generation advances, so a replacement that reacts to the new generation at once finds the lock it was built with. A lock that cannot be renamed fails the rebuild, and a failure after it (the generation write) puts the previous lock back. A rebuild that changes the lock holds the project lock (`.labelle/project.lock`, which every writer of `labelle.lock` takes) from staging to its commit or rollback, so two watch sessions of one project change the lock one after the other: the second waits (interruptibly), then stages against the lock the first left. A cancellation is checked again after the publication copy and at the commit point, so a rebuild cancelled during shutdown never publishes. A rebuild runs the same generation pre-passes as the cold build (ASTC conversion, `--bake`) and gives a newly added prebuild step the same managed-Python PATH wiring. The watcher's starting baseline is the tree as it was before the cold build, so an edit saved while the cold build ran is rebuilt; the CLI's own `labelle.lock` is not a watched input. The sources of local providers (`local:` packages with a `plugin.labelle`) that the project's walk does not reach are watched with it, with the same skip rules (dot directories, `zig-out`, `zig-cache`, nested checkouts); a provider that contains the project (`local:../..`) is watched without the project, and nested providers are collapsed, so every file is watched once. The `after run` hooks at shutdown are the committed generation's.

**Shutdown.** When the replacement exits, the CLI records the terminal status (a non-zero or signal exit is `failed` with that status), stops the watcher, cancels any in-flight rebuild and reaps its child (a provisioning hook, the compile, an `after build` hook), joins the watcher and only then finishes the run. `after run` hooks run only after a clean status-0 exit of the replacement; a signal, a non-zero status or a forced stop skips them. The session directory is removed either way. Every child of the session runs supervised: on POSIX in its own process group, on Windows in a job object that kills the tree when closed. Ctrl+C / SIGTERM to the CLI is forwarded to every supervised tree (on Windows the console delivers Ctrl+C to them directly), and latched — on every host, the Windows console handler included: a child that starts after it (during session setup, between two spawns) is stopped the moment it is registered. A second one kills them. A child cancelled before it could be registered is ended with its whole tree. A child whose output is captured (the compile) cannot hang its rebuild through a descendant that keeps its pipes open: the tree ends with the child, and the output is drained for at most 500 ms after it exits. No child outlives `labelle run`. (A SIGKILL of the CLI itself cannot be forwarded on POSIX.)

### Wire versions and negotiation

The CLI implements contract `1.4.0` and speaks every wire version listed here, newest first:

| Wire | Adds |
| --- | --- |
| `1.4.0` | `final_step` on every context (additive minor, cli#443). |
| `1.3.0` | `cache_dir` and `env_file` on every context, and `watch` in the `run` object (additive minor, CLI 2.1.0). |
| `1.2.0` | `target_dir` on every context and the optional `run` key on `run`-step hooks (additive minor). |
| `1.1.0` | The optional `build_number` key (additive minor). |
| `1.0.0` | The original v1 context. |

For each invocation the CLI negotiates the **newest** wire version the provider's `command_contract` range admits and writes it as `contract_version`; a range that admits none of them is `UnsupportedContract` at discovery. Keys a wire version does not define are never emitted in it, so a provider decoding strictly (unknown fields are errors, as above) keeps working:

- `>=1.0.0 <2.0.0` admits every additive v1 minor, so it receives `1.4.0` and must accept the keys `1.1.0`, `1.2.0`, `1.3.0` and `1.4.0` add. A provider declaring such a range promises exactly that.
- `<1.4.0` (for example `>=1.0.0 <1.4.0`) receives the exact `1.3.0` wire, without `final_step`: its hooks run exactly as on `1.4.0` but cannot tell which command runs them.
- `<1.3.0` (for example `>=1.0.0 <1.3.0`) receives the exact `1.2.0` wire, without `cache_dir`, `env_file` or `run.watch`: its hooks cannot contribute an environment and its run replacement cannot run a watch session.
- `>=1.0.0 <1.2.0` receives the exact `1.1.0` wire, without `target_dir` or `run`. If one of its `run` hooks would have received run options the user passed, the CLI prints one `note:` line per hook (`run options not passed to '<package>/<id>' (provider contract 1.1.0 < 1.2.0)`) instead of dropping them silently.
- `>=1.0.0 <1.1.0` (or `1.0.0`) receives the exact `1.0.0` wire. `labelle bundle --build-number=N` is then not passed to it; the CLI prints one `note:` line saying so instead of dropping it silently. The `1.2.0` rule above applies too.

A provider that rejects unknown fields should cap its range at the newest minor it decodes. New optional keys arrive only with a new minor wire version; the major stays `1` until a key is removed or changes meaning.

Paths use host syntax and must be absolute (on Windows, drive-qualified or UNC, not current-drive-rooted). Structural validation does not perform filesystem existence/containment checks; the resolver performs those before launching.

Inside projects, `target` and `lock_file` are required and non-null. Outside projects, `project_dir`, `target`, `lock_file`, and `config_file` are null and optimize is Debug. Hooks always require a project. A projectless output directory is a per-invocation workspace, never the provider's source cache. The actual filesystem checks, allocation and cleanup are phase-2 runner responsibilities.

Progress uses standard streams rather than invented OS handles: in JSON mode stdout carries the existing CLI NDJSON progress protocol and stderr carries diagnostics; in human/off modes normal command output is permitted. The CLI parses/relays JSON events and owns the single final command outcome. Nonzero provider exit or abnormal termination is failure. No secret values belong in the context or progress stream.

The provider inherits the CLI's stdout and stderr, and when a user redirects them to a file (`labelle build > log 2>&1`) both processes share ONE open file description and its offset. A provider must therefore write both streams in streaming (append) mode — in Zig 0.16, `File.stdout().writerStreaming(...)` / `File.stderr().writerStreaming(...)` or `std.debug.print`, never the positional `File.writer(...)`, which pwrite()s at its own offset starting from 0 and overwrites what the CLI already wrote ([#446](https://github.com/labelle-toolkit/labelle-cli/issues/446)). Pipes hide the bug because they are unseekable; `test/provider_output_e2e.py` checks the redirected-file case.

There is **no credentials-helper RPC in v1**. Providers use explicitly configured environment-variable names or their own OS credential integration. Provider configuration stores references, not secret values. This avoids promising a helper endpoint before its protocol exists.

## 3. Provider-owned project settings

Introduce one generic project field mapping package identity to a provider-owned JSON file:

```zig
.provider_config = .{
    .{ .package = "android", .file = "providers/android.json" },
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

Registry and lock `repo` values are always the bare `<owner>/<name>` form.
The project's `.plugins[].repo` is compared with them after one
normalisation (`projectRepo` in `src/cli/provider_github/pin.zig`), which
accepts the spellings the assembler fetches as the same GitHub repository:
`github.com/<owner>/<name>` (the form the assembler needs, and the one to
declare), `https://github.com/<owner>/<name>` (an optional `git+`, `.git`,
trailing `/` and `?ref`/`#sha` suffix are dropped), and the bare
`<owner>/<name>`. The host is compared ASCII case-insensitively; owner and
name are compared exactly. The lock written for any accepted spelling is
byte-identical. A repository on any other host never matches a pin and fails
with `NonGitHubProviderRepository`: only GitHub archives are accepted.

`labelle providers resolve [providers.json]` previews the exact project-declared
versions, commits and hashes and records them, with a digest, in
`.labelle/providers.preview.json`. The preview binds the whole registry
document, not only the selected pins: it also records the registry
`schema_version`, the `defaults` list, each selected record's
`namespace`/`targets` claims, and the SHA-256 of the normalised document
(compact JSON of exactly the fields its schema defines, records in document
order, so whitespace and key order do not matter). `--accept` requires the
registry to still equal that recorded preview. Any changed field aborts with
`ProviderPreviewMismatch` and names it: source, `schema_version`, `defaults`,
a selected release's pin fields or claims, or, when none of those changed, an
unselected release record. No preview aborts with `ProviderPreviewMissing`.
It then verifies archives against the previewed hashes and provider manifests, checks
ownership, then atomically writes `labelle.providers.lock` and removes the
preview.
Commit it alongside `labelle.lock`, which remains the ordinary dependency lock
and is not rewritten by provider resolution. No package code runs during
resolution. A failed resolve leaves the previous integrity lock intact.

Normal commands use only matching project pins and cached archives; no
registry lookup, download or pin update is implicit. The one exception is
metadata for a diagnostic: when a requested target has no provider, the CLI
may download the public registry document (short timeout, skipped under
`LABELLE_OFFLINE`), or read the document a custom source's accept recorded,
to name the owning package and a candidate release in the error. That download is
never cached, pins nothing and runs no package code
([provider targets](provider-targets.md#resolution)). Verify the archive hash
on every invocation, extract into a fresh temporary directory, and remove it
afterward. Never execute the older unverified plugin extraction cache. Missing
or corrupted archives fail closed (`ProviderArchiveMissing`,
`ProviderArchiveHashMismatch`) and name `labelle providers fetch`; a changed
GitHub archive is not automatically accepted.

`labelle providers fetch [--offline]` is the explicit way to obtain the
archives a committed lock pins (a fresh clone, a CI runner, an emptied
cache). It runs inside a project: `project.labelle` only locates the project
root (it is not parsed), and the project's `labelle.providers.lock`, which
always sits next to it, is the one input. There is no registry lookup and no
preview. Outside a project it fails with `ProjectRequired`. It downloads each
pinned `https://codeload.github.com/<repo>/tar.gz/<commit>` that is not
already cached and valid into `<LABELLE_HOME>/provider-archives/<sha256>.tar.gz`
(`LABELLE_HOME` defaults to `~/.labelle`). The cache is per-archive atomic
and verified-only: only bytes that hash to the lock's sha256 are ever cached,
each archive by one rename of a verified temporary file. Every download is
verified before the first rename, so a mismatch or a failed download names
the package, fails, and adds nothing to the cache. A failure while moving
verified archives into place can leave the set partly fetched; that is
harmless, since every cached archive verifies, and the next run fetches the
rest. A cached archive that verifies is left alone, so a second run is a
no-op; a damaged one (wrong hash, or larger than any archive) is replaced
only by bytes that verify. It never writes the lock, extracts nothing and
runs no package code. `--offline`
downloads nothing and only verifies the cache. A bare `labelle install` in a
project that has a providers lock runs the same fetch after the assembler's
package install.

Namespace, target and command-contract declarations come from the verified
`plugin.labelle`. The registry's ownership tables (schema 2, below) are a
lookup index over those declarations, not a second authority. Source archives
must be self-contained and have one root directory. Unsafe paths, links,
case-insensitive duplicate paths and unsupported entry types are rejected.
Compiler and Zig dependencies still require explicit preparation; host builds
use Zig system-package mode to disable dependency downloads.

`--offline` requires local metadata and cached archives. Global/projectless
bootstrap and default-package selection remain later work using GitHub data;
they do not require a separate publishing service. CLI self-update never
changes provider pins.

### Registry schema 2: ownership tables and defaults

The lock stays at schema 1. The registry document may use `schema_version: 2`,
which the CLI's `src/cli/provider_registry.zig` reads alongside schema 1:

```json
{
  "schema_version": 2,
  "defaults": [ { "package": "labelle-example", "version": "1.0.0" } ],
  "providers": [
    {
      "package": "labelle-example",
      "repo": "labelle-toolkit/labelle-example",
      "version": "1.0.0",
      "commit": "<40 lowercase hex characters>",
      "sha256": "<64 lowercase hex characters>",
      "namespace": "example",
      "targets": [ "example-target" ]
    }
  ]
}
```

- **Every key is required.** `namespace` is explicitly `null` for a release
  that declares none, `targets` is `[]`, and `defaults` is `[]` when there are
  none. A schema-1 document must not carry any of these keys. Unknown keys,
  duplicate keys and schemas other than 1 and 2 are errors. All schema-1 pin
  rules still apply.
- **Each release record repeats the declarations of that release's
  `plugin.labelle`.** Names follow the manifest rules: identifiers, no
  duplicates, no Windows reserved device name as a target, and never
  `desktop`.
- **Target and namespace ownership** is the union of a package's releases.
  Two packages claiming one name is an error, because lookup must name exactly
  one package. Namespaces the running CLI reserves are not checked here, since
  one registry serves every CLI version; dispatch refuses them.
- **Lookup by target and by namespace** answers "which package provides
  `<t>`" without downloading or extracting anything. The no-provider
  diagnostic reads it from a best-effort download of the public registry,
  or from the document the project's accept of a custom source recorded
  (see [provider targets](provider-targets.md#resolution)); a schema-1
  document names no owner there. The unknown-namespace diagnostic reads the
  cached registry the last `--accept` used. That cache holds the normalised
  document bound to the accepted preview, so its bytes hash to the preview's
  registry digest; a later fetch nobody reviewed never reaches it. Projectless
  bootstrap (phase 5) uses the same table for namespaces.
- **The claims are checked, not trusted.** `labelle providers resolve --accept`
  compares every release it pins against that release's verified manifest.
  Any difference in namespace or target set fails with
  `RegistryDeclarationMismatch` before the lock is written. So a pinned
  release never disagrees with the table that pointed at it, and a wrong claim
  can only affect a diagnostic about a package that was never pinned.
- **`defaults`** lists exact releases (`package` + `version`, one entry per
  package), each matching exactly one record. It resolves to those exact
  records (`Registry.defaultPins`), which are what the §5 consent prompt shows:
  package, version, repository, commit, hash. It is never a bare name, a range
  or "latest".

## 5. Default-package consent

Whether defaults come from the online index or an offline stamped scaffold, `init` presents their exact resolved package/version/source/hash records before writing pins or executing package code. Accept explicitly; noninteractive automation supplies an explicit acceptance option, otherwise fail rather than hang. Declining leaves no initialized project or provider pins. Offline initialization requires complete cached release metadata/content and compiler prerequisites for any work it executes.

Index defaults are suggestions, not automatically trusted project declarations. Initial acceptance covers the complete resolved dependency graph; changes to that graph require explicit resolution. Merely fetching/parsing metadata is allowed before consent, but compiling or executing package build scripts is not.

The online defaults are the registry's schema-2 `defaults` list (§4), resolved to exact records. The `providers resolve` preview already binds that list together with the rest of the registry document (§4), so a defaults change between preview and accept is a mismatch there too. The offline source is the release-stamped scaffold template, which is data the assembler's `init` ships, not CLI code. Consent uses the same binding as `labelle providers resolve`: what is written is exactly what was shown. `init` presents the resolved default records. Only after explicit acceptance (interactive, or the explicit noninteractive option) does it write `.plugins` and `labelle.providers.lock` from those same records. A registry that changes in between is a mismatch, not a new default. Today `labelle init` (delegated to `labelle-assembler init`) scaffolds only the core/engine/gfx pins, and no default package is added. This section is the rule the first default package must follow; it does not describe current behaviour.

## 6. Hook execution

Resolve stable hook identities as `<package>/<hook-id>`. A command runs its steps in lifecycle order, each with all of its hooks: `labelle generate` runs `generate`; `labelle build` runs `generate` then `build`; `labelle run` runs `generate`, `build`, then `run`; `labelle bundle` runs `generate`, `build`, then `bundle`. Within each target/step, execute before hooks, the core operation or unique replacement, then after hooks. A replacement stands in for its own step's core operation and nothing else: a `bundle` replacement does not remove the `build` step's hooks, so `labelle bundle` on a target whose owner packages an installable artifact in an `after build` hook and replaces `bundle` runs that hook, then the replacement. The CLI never skips a hook by command (a hook of another package in that slot, such as a signer or a symbol upload, would be bypassed silently); a hook whose work a later step of the same command redoes reads `final_step` (§2, wire `1.4.0`+) and skips that work itself (cli#443). Provider dependencies create ordering edges within a phase; explicit `after_hooks` refine hook ordering. Break independent ties by fully qualified hook ID. Reject missing hook references, cycles, dependencies on later phases, and multiple replacements before execution. A replacement belongs only to the target owner. Sequential execution is sufficient for v1.

Stop on any failed hook/operation; after hooks run only after success. For `run`, success means the game process itself exited with status 0: a game the `--timeout` watchdog stopped, or a simulator/device launch that returns while the app is still running, is not a success even though the CLI's own exit status is 0, and its after hooks are skipped with one diagnostic line. Hooks clean up their own temporary resources. Do not run publishing hooks after a failed build or reuse an old output as a new success. Graph construction/execution and its fixture tests belong to phase 3.

## 7. Backend agnosticism migration

Keep the mandate: backend names must also leave core. The guard already flags them (`raylib`, `sokol`, `sdl`/`sdl2`, `bgfx`, `wgpu`); their current sites are allowlisted. #411 considered narrowing the mandate and guard to platform and store names until backends are manifest-declared, and rejected it. Narrowing would let new backend branches into core unflagged, and the allowlist already expresses "not yet". The deliverable is [CLI #432](https://github.com/labelle-toolkit/labelle-cli/issues/432), coordinated with assembler #378 and blocked on it: replace the fixed backend enum with a resolved manifest identity, move target-support declarations out of `compatibility.zig`, and replace backend-name branches in `pipeline.zig` with declared capabilities. The shared project schema must accept the identity before consumers switch.

Keep specific existing sites on the shrinking migration allowlist until replaced; do not claim the guard is complete after moving platform commands alone. Desktop stays a core target, but its renderer is still a manifest-resolved backend. No backward aliases for removed enum/config forms.

## Delivery and evidence

Phase 1 supplies this contract, wire-context validation, installed-tool path validation, ownership conflict checks and target lookup. `zig build test-provider-contract` runs those tests; `zig build test` includes the same target, avoiding an uncollected test root.

Phase 2 implements manifest/range parsing, GitHub integrity pins, config mapping, filesystem validation, host-tool build/discovery/cache and process dispatch. Phase 3 implements hook planning and the Android provider; phase 4 consolidates packaging/Gradle; phase 5 enables projectless resolution/updates using the same GitHub repository. Registry records are ordinary reviewed commits, not a publication service.

Hook planning and execution (§6) are implemented for the four core steps; [provider hooks](provider-hooks.md) documents the ordering rules, the step output-directory layout, the hook context and the remaining limitations.

#411's review of the six decisions against the architecture RFC: default-package consent (§5, with the §4 `defaults` list), one declared executable per `build_step` (§1), one context wire format (§2), provider-owned settings (§3, [provider configuration](provider-configuration.md)), backend names (§7, [#432](https://github.com/labelle-toolkit/labelle-cli/issues/432)), and target lookup in the index (§4 schema 2). Before the feature is called implemented, exercise actual provider subprocesses, artifact discovery, consent failures, hash failures, host/toolchain cache separation, offline execution and atomic-update recovery. Passing the phase-1 pure tests does not claim those later behaviors work.

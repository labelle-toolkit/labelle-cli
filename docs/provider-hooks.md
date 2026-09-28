# Provider lifecycle hooks — phase 3a

This documents the hook-execution slice of CLI #406, stacked on the
[v1 contract](provider-contract-v1.md) §6 and on
[project-local dispatch](provider-local-dispatch.md). A pinned provider can
now attach to the project's `generate`, `build`, `bundle` and `run` steps.
[Provider-declared targets](provider-targets.md) resolve `--platform=<t>`
to the provider that declares `<t>`; the platform packages themselves still
remain to be extracted.

## Attaching

A hook record in `plugin.labelle` names one `(step, target)` and one phase:

```zig
.hooks = .{
    .{ .id = "sign", .step = .bundle, .target = "desktop", .when = .after,
       .build_step = "hook-sign", .executable = "bin/sign",
       .after_hooks = .{ "labelle-example/stamp" } },
},
```

- `step` is `generate`, `build`, `bundle` or `run`; `when` is `before`,
  `replace` or `after`. `build_step`/`executable` follow the installed-tool
  convention of the contract (§1) exactly as commands do.
- `before` and `after` hooks attach to any target, including core-owned
  `desktop`. A `replace` hook is accepted only for a target the same package
  declares in `.targets` (`ReplaceRequiresOwnedTarget`); since no package may
  own `desktop`, the core desktop steps can never be replaced.
- `after_hooks` entries are fully qualified `<package>/<id>` references
  (`InvalidHookReference` otherwise, including a reference to the hook
  itself).

Hooks require a project. Like commands, they run only for a provider whose
`labelle.lock` entry matches the declaration and — for a remote package —
whose integrity pin is accepted (`MissingProviderPin`, `StaleProviderPin`,
`RemoteProviderIntegrityRequired`). Every hook of a phase has its pin
checked **before** the host compiler is resolved (and, like `labelle build`,
provisioned on a cache miss), exactly as a provider command does: an
unpinned remote hook is reported as the integrity failure it is, never
triggers a compiler download, and the check creates no cache directory.
`provider_config` settings are resolved the same way and passed as
`config_file`.

## Discovery and the graph

Every project command that runs the pipeline (`generate`, `build`, `run`,
`bundle`, and the legacy platform commands that share its generation)
discovers the declared providers whenever `.plugins` is non-empty. Discovery
runs **after the package cache is populated** (the assembler's `install`) and
**before generation or any compiler**: a declared remote package that is
neither pinned nor yet in the ordinary cache has no manifest to read, so
discovering ahead of the installer took every such package for runtime-only
and a cold cache silently built without its hooks while a warm cache ran
them. With the cache populated, a non-local package that is still absent
from both caches fails discovery closed (`ProviderPackageMissing`); a package
directory without a `plugin.labelle` is a runtime-only package (light packs
ship no manifest). Discovery is also where the requested target's ownership
is confirmed: the name was settled from the string alone before the
install (it names the target directory and the feed), and a name no
discovered provider declares is refused here, ahead of the lock, generation
and any compiler ([provider targets](provider-targets.md#resolution)). The
whole hook graph is validated once, at discovery, so
`labelle help` and `labelle providers resolve --accept` (which validates the
accepted remote and local manifests together before writing
`labelle.providers.lock`) fail on the same problems a build would:

| Error | Rule |
| --- | --- |
| `DuplicateReplaceHook` | two `replace` hooks for one `(step, target)` |
| `MissingHookReference` | an `after_hooks` entry names no hook |
| `HookReferenceMismatch` | it names a hook on another `(step, target)` |
| `HookPhaseOrder` | it names a hook in a later phase (`before` → `replace`/`after`, `replace` → `after`) |
| `HookCycle` | a cycle among same-phase references |

Each prints one `labelle: hooks: …` line naming the hooks involved. The
cycle check orders each distinct `(step, target, phase)` group once, so
validation stays quadratic in the size of a phase rather than cubic — a
manifest within the size limit cannot make `help` or a build hang on it.

The metadata-only callers — `labelle help` and provider command dispatch —
run before any installer, so a declared remote package that is in neither
cache has nothing to read and is simply not listed. A reference into such a
package is then **unresolved, not missing**: `MissingHookReference` is
deferred until the package can be read (the pipeline's populated discovery,
`providers resolve --accept`), and `help` keeps listing the commands of the
providers it did read. Without that, a cached provider that names a valid
hook in an uncached one lost every provider command from `help` and refused
dispatch until the second package happened to enter the cache. The deferral
is exact: a reference into a package the project never declared, or into a
declared package that *is* present but lacks the hook, is still reported at
`help` as before, and the same absent package fails the pipeline closed
(`ProviderPackageMissing`) once the install has run.

A malformed provider therefore fails a plain `labelle build` closed, with
`labelle: provider discovery failed: <error>`, exit status 1 and a `failed`
progress record, before anything is generated. For pinned remote providers,
discovery is the same verify-and-extract every provider command performs;
that cost is accepted (it is the integrity model of #414).

## Order

A command runs its steps in lifecycle order, each with every hook it has:
`labelle generate` runs `generate`; `labelle build` adds `build`; `labelle
run` adds `build` then `run`; `labelle bundle` adds `build` then `bundle`
(contract §6). A replacement stands in for its own step's core operation
only. So `labelle bundle` for a target whose owner declares an `after build`
packaging hook and a `bundle` replacement runs

    before generate → generate → after generate → before build → build →
    after build (the packaging hook) → before bundle → bundle replacement →
    after bundle

and no `run` hook. The CLI does not skip the `after build` hooks under
`bundle`: a hook of another package in that slot (a signer, a symbol
upload) would silently not run. Instead every hook's context carries
`final_step` (wire `1.4.0`+, see [Context](#context)), and a hook whose work
the bundle replacement redoes — the owner's install package, say — skips it
when `final_step` is `bundle` (cli#443).

Within one `(step, target)`: every `before` hook, then the core step or its
unique `replace` hook, then every `after` hook. For `generate`, the core step
includes its input pre-passes — the ASTC conversion of declared atlases and
the opt-in `--bake` — so a `before generate` hook runs ahead of every reader
of the generation inputs: a hook that emits a declared PNG is seen by both
pre-passes and by the assembler. (The pre-passes used to run before the
hooks; `generate --bake` then failed on a PNG the hook had not yet written.)
A `replace generate` hook stands in for the pre-passes as well as for the
assembler: whatever preprocessing its generation needs is its own to do.
Likewise for `build`, the core step ends with the command's finalization —
for `labelle build`, the Linux `.desktop` entry and, on a platform that
packages one, the installable package — so an `after build` hook sees the
final artifact and never reports success over a packaging step that has
not run yet; and a `replace build` hook owns that finalization too: the
replacement produces the artifact its target needs, packaging included.
Inside a phase the order is a
topological sort of the `after_hooks` edges that land in that phase; whenever
several hooks are ready, the lexicographically smallest fully qualified ID
runs first. A reference to an earlier phase is accepted and creates no edge.
The plan is a function of the graph alone: the order manifests are read in
(and the order of `.plugins`) never changes it.

**Dependency edges are `after_hooks` only, for now.** The contract also
derives ordering from provider dependencies, but no manifest field declares a
package-to-package dependency yet. When one exists it adds edges here; the
tie-break and everything else stays the same.

## Output layout

Every hook of a step receives the same absolute `output_dir`, which is also
where the core step puts its artifact, so hooks and core agree without any
configuration:

| Step | `output_dir` |
| --- | --- |
| `generate` | `<target_dir>` — the generated tree, `.labelle/<backend>_<target>/` |
| `build`, `run` | `<target_dir>/zig-out/` |
| `bundle` | `<target_dir>/zig-out/bundle/<target>/`, or the resolved `--output` directory |

The CLI creates the directory before the first hook of the step. As part of
this contract the default location of the desktop `.app` moved from
`<target_dir>/zig-out/<Title>.app` to
`<target_dir>/zig-out/bundle/desktop/<Title>.app`; `--output` is unchanged.

## Context

The wire context (§2) for a hook carries `invocation = { "kind": "hook",
"id": <hook id>, "step": <step>, "phase": <phase> }`, the resolved `target`
(the string `provider_targets.resolve` produced — `desktop` or a name a
pinned provider declares),
the project's `lock_file`, the provider's `config_file` or null, the step's
`output_dir`, the pinned `zig_executable`, and this invocation's `optimize`
and `progress` (the effective optimize mode, which is `--optimize` when the
user passed it and otherwise the target owner's
[`target_defaults`](provider-targets.md#optimize-defaults), and `--progress`
as the user passed it, so a hook builds what the core step builds and speaks
the mode the user asked for). The tool runs with the project root as cwd and no trailing arguments.

A `bundle` hook's context also carries `build_number` when the user passed
`labelle bundle --build-number=<N>` (validated before the build, as for the
core packager): the provider that packages its target is the one that stamps
the number, so it would otherwise be dropped. The key is **absent** — not
null — for every other step's hooks and for a `bundle` without the flag.
`build_number` is a contract `1.1.0` key: a provider whose `command_contract`
range stops below `1.1.0` receives the `1.0.0` wire without it (see
[wire versions and negotiation](provider-contract-v1.md#wire-versions-and-negotiation)).

On wire `1.2.0` every hook's context also carries **`target_dir`**: the
absolute generated target directory, `.labelle/<backend>_<target>/`. It is
the same directory for every step, whatever `output_dir` is, so a `bundle`
hook still finds the generated tree and the build output when `--output`
moves its `output_dir` somewhere else.

A **`run`**-step hook (`before`, `replace` or `after`) also gets the
**`run`** object on wire `1.2.0`. It holds the `labelle run` options that a
replacement launch needs:

```json
"run": {
  "env": [
    { "name": "LABELLE_SCENE", "value": "intro" },
    { "name": "LABELLE_SCREENSHOT_PATH", "value": "shot.png" },
    { "name": "LABELLE_SCREENSHOT_AFTER_SEC", "value": "2.000" }
  ],
  "args": ["a", "b"],
  "timeout_ms": 30000
}
```

- `env` is exactly the list the core launch sets for `--scene`, `--profile`,
  `--screenshot` and `--after`, with the same names, values and order. An
  option the user didn't pass adds nothing. The desktop-only headless knobs
  aren't run options and never appear here.
- `args` are the tokens after `--`, verbatim.
- `timeout_ms` is `--timeout` in milliseconds, or null.
- `outcome_file` (wire `1.5.0`, the `replace run` hook only; null on the
  other `run` hooks, absent below `1.5.0`) is where a replacement that
  enforced `timeout_ms` itself writes `timeout` before exiting 0. See the
  outcome table under [Failure](#failure).

The CLI maps none of this to a platform. The provider decides how the pairs
reach its game, for example as launch extras on a device.

The object is present, and possibly empty, on every `run`-step hook of a
`1.2.0` wire. It's absent on every other step.

A provider whose range stops below `1.2.0` gets the older wire, without
either key. If its `run` hook would have received options the user passed,
the CLI prints one line per hook:
`labelle: note: run options not passed to '<package>/<id>' (provider contract <wire> < 1.2.0)`.

On wire `1.3.0` every hook's context also carries **`cache_dir`**, the
provider's persistent cache directory under
`<LABELLE_HOME>/providers/<canonical provider id>/`, created by the CLI and
shared by every project that pins the same provider
([provider cache](provider-contract-v1.md#provider-cache)).

### Environment contributions

A `before generate`, `after generate` or `before build` hook also gets
**`env_file`** on wire `1.3.0` (null on every other hook): an absolute path,
in a fresh per-invocation directory, where it may write

```json
{ "set": [ { "name": "SDK_ROOT", "value": "/abs/sdk" } ], "path_prepend": [ "/abs/sdk/bin" ] }
```

to contribute to the environment of everything that runs after it in the
same command: the generation-time fingerprint pass (`zig build
--list-steps`), the core compile, and every later hook and replacement. The
build of a provider's own tool never sees it. This is how a provider that
provisions a toolchain hands it to the build without the CLI knowing the
toolchain: a `before generate` hook is early enough for the fingerprint
pass, which already configures the generated build; an `after generate` hook
(which can see the fetched dependency tree) reaches the compile onward.

- Contributions merge in hook execution order and override the inherited
  environment; two hooks setting one name to different values is an error
  naming both; `path_prepend` entries go in front of `PATH`, in hook then
  list order, deduplicated. On Windows names compare case-insensitively
  and an inherited key keeps its spelling.
- CLI-owned names (`PATH`, the Zig cache variables, the `LABELLE_*`
  variables the CLI reads or sets) can't be set; other names, `LABELLE_*`
  or not, can.
- No file is no contribution. An empty or malformed file fails the command
  right after the hook, before any later zig invocation:
  `labelle: hook '<package>/<id>' wrote an invalid env_file: <reason>`. A
  file written by a hook that then failed is ignored.
- The environment is rebuilt for every build, including every watched
  rebuild, so a hook that stops running leaves nothing behind.

The full rules are in the contract:
[environment contributions](provider-contract-v1.md#environment-contributions).
A provider capped below `1.3.0` gets neither key, so its hooks can't
contribute.

### The command's last step

On wire `1.4.0` every hook's context also carries **`final_step`**: the last
lifecycle step of the command running the hook — `generate`, `build`, `run`
(watched rebuilds included) or `bundle`. An `after build` hook sees `build`
under `labelle build`, `run` under `labelle run` and `bundle` under `labelle
bundle`; a `bundle` hook always sees `bundle`. Hook plans don't depend on it
(the same hooks run whatever the value); it only tells a hook what the rest
of the command will do. A provider capped below `1.4.0` gets the exact
`1.3.0` wire without the key.

`labelle.lock` is written before generation now — immediately after the
package cache is populated and the plugin/core compatibility check ran —
because a `before generate` hook already needs it. A generation that then
fails leaves a fresh lock reflecting the declared pins, which is harmless.

## Failure

Execution is sequential and stops at the first failure. A hook that exits
nonzero fails the command with **the hook's own exit code**, prints
`labelle: hook '<package>/<id>' failed (exit <code>)`, and marks the progress
feed `failed` with that code. Nothing later runs: a failing `before` hook
means the core step never starts, and a failing core step (or `replace`
hook) means no `after` hook runs — contract §6, so a publishing hook can
never ship a stale artifact.

For `run`, the core step has an explicit outcome and `after run` hooks run
**only when the game process itself exited 0** (`exited_clean`), before the
terminal `done` record. Every other outcome skips them and prints one
`labelle: after-run hooks skipped: <reason>` line (only when there are hooks
to skip); the CLI's exit status is unchanged by the skip:

| Outcome | When | CLI exit status |
| --- | --- | --- |
| `exited_clean` | the game exited 0 | 0, or a failing after hook's code |
| `exited_error` | the game exited nonzero or was killed by a signal | the game's (128 + signal) |
| `timed_out` | the `--timeout` watchdog stopped the game, or a `replace run` hook wrote `timeout` to its `run.outcome_file` (wire `1.5.0`, cli#473) | 0 (a genuine expiry is not a failure, cli#390) |
| `launched_detached` | `simctl launch` / `adb shell am start` returned while the app runs on | 0 |

A zero status alone was never a clean exit — the watchdog reports 0 after
killing the game, and the mobile deploy paths return as soon as the launch is
issued — so a publishing or cleanup hook used to run after a forced timeout
or immediately after a device launch. A `replace run` hook that exits 0 is a
clean end of the step unless it reported `timeout` through its
`run.outcome_file`; any other content there fails the run (exit 1) before
the `after run` hooks. A provider capped below wire `1.5.0` can't report, so
its status-0 exit is always clean (contract §2, "Run outcome";
`test/provider_run_outcome_e2e.py`).

Hooks report under the progress phase of the step they wrap (`generate`,
`compile` for `build`, `run` for `bundle` and `run`) as sub-steps named
`hook <package>/<id>`. When Zig's progress stream has already advanced the
feed from `compile` to `link`, an `after build` hook is a sub-step of `link`
(the phase never moves backward). A hook sub-step carries no `step`/`total`
counters (the compiler's are cleared), and once a `before generate` or
`before bundle` phase succeeds the feed returns to the core step's detail
(`assembler generate`, `packaging bundle`).

The shader-compiler override (`LABELLE_SHADERC`) is validated before the
package install and again right after the `before generate` hooks, since a
hook may be what creates `materials/`.

For `run`, the core build is the one and only build of the command: the
desktop run path launches the binary the `build` step (or its `replace`
hook) produced, with no warm `zig build` in between, so whatever an `after
build` hook signed, stripped or patched in `zig-out/` is what runs.

## Limitations

- No JSON progress relay or validation for hook (or command) stdout yet: the
  child's stdio is inherited exactly as for provider commands.
- The legacy `labelle ios …` subcommand handler is not a hook point for
  `build`/`run`; it only shares the `generate` hooks. It leaves with platform
  extraction (its target already goes through the resolver, so it needs the
  pinned provider like `--platform=<t>`). `labelle android …` left with
  cli#405: it is the `android` provider's namespace, and `--platform=android`
  runs the ordinary hook points.
- A provider target other than the legacy `ios` run branch must
  replace `run` (`NoRunReplacement`, [provider
  targets](provider-targets.md#labelle-run)).
- `labelle bundle` for the core `desktop` target is still refused on Linux
  and Windows — before any install or build — because the core packager is
  macOS-only and no hook can replace it (nobody may own `desktop`). A
  provider target is bundled by its provider's `replace` hook on any host,
  checked with the plans after discovery; see [provider
  targets](provider-targets.md#labelle-bundle).
- A `labelle run --watch` rebuild re-runs the `generate` and `build` hook
  phases around its core steps exactly as the cold pipeline did (the feed is
  already terminal, so the hooks' sub-step records are not emitted there); a
  failing hook stops that rebuild and keeps the replacement running, like a
  failing core step. Every
rebuild first — before its prebuild steps — re-reads `project.labelle` and
  stages the `.prebuild` steps it declares (so an edited step runs in that
  very rebuild, and the watch ignore set is swapped with it, cli#463); after
  the steps it re-runs the package install and rewrites `labelle.lock` when
  that file changed, rediscovers the providers (with the cache `.populated`,
  as the cold pipeline did), re-checks that the served target still has a
  pinned owner and replans both phases,
  so a watched edit to the project, to a provider manifest or to a
  `provider_config` file reaches the next rebuild — the plans computed at
  startup are only the initial state, never reused for a rebuild. A rebuild
  is a transaction (cli#469): what its replan changes — providers, config,
  prebuild steps, plans, optimize mode, lock and environment — is committed
  only when the whole rebuild succeeds; a replan that fails (a manifest saved
  mid-edit, say), a failing hook or a failing compile restores all of it,
  and the shutdown `after run` hooks are the committed generation's. Each
  hook phase allocates on a scratch arena freed when the phase returns, and
  each replan lives on its own arena released once the next one commits —
  only the resolved host compiler outlives them — so a long watch session
  with hooks does not grow on every saved edit. The replan's storage is
  kept until the shutdown `after run` hooks have run. A hook that writes
  into the watched tree (hooks declare no outputs) costs one follow-up
  rebuild per edit, after which the watcher takes the tree as built — it
  does not rebuild in a loop.
- A `--docker` run whose binary was cross-compiled skips the launch and
  every `run` hook with it — decided before the `before run` hooks, so none
  of them prepares (or fails) a launch that never happens. `--docker` builds
  the core `desktop` target only: a provider target is refused by name
  before anything runs (CLI 3.0, [migrating](migrating-to-3.0.md)), since
  its hooks, their environment contributions and its toolchain live on the
  host.

## Watch sessions (`labelle run --watch`)

A `replace run` hook may declare `.watch = true` (CLI 2.1.0+; only on a `run`
replacement). With it, and a provider that negotiates wire `1.3.0` or newer,
`labelle run --watch` keeps the replacement running after the cold build
while the CLI watches the project and rebuilds on every change, through the
same generate and build hook phases as the cold pipeline. The replacement's
context carries `run.watch` (`generation_file`, `output_dir`); every other
`run` hook gets `run.watch: null`. A rebuild publishes only after its
`after build` hooks succeeded; a failed rebuild publishes nothing; a change
the running replacement depends on (its provider, version or pin, the hook,
the negotiated wire, the capability, the `before run` hooks, the backend, the
target, the output location, the effective optimize mode, its settings, the
Zig version) stops the rebuild with a restart diagnostic.
When the replacement exits the CLI cancels any in-flight hook or compile and
reaps it, then runs the committed generation's `after run` hooks, only after
a clean status-0 exit. A target without such a replacement — `desktop`
included — is refused before any build. The full rules are in the contract:
[watch sessions](provider-contract-v1.md#watch-sessions).

## Verification

`zig build test-provider-dispatch` (also collected by `zig build test`)
covers manifest validation, the planner's order independence, every graph
error, that validation orders each phase group once (a call counter on the
sort), the deferral of references into an unread package (at the graph and
at discovery, against a real cache layout in both cache states), the
per-phase scratch arena (a counting allocator proves two phases on one site
leave nothing live), the pin-before-compiler order (an unpinned provider is
refused with the host resolver never reached), `target_dir` on every
hook and the `run` options on `run`-step hooks only, the `run` outcomes (only
`exited_clean` reaches the hook machinery), the output-layout contract and
the hook wire context; `zig build test` also covers the watched-rebuild
hook plumbing (the phases, and the per-rebuild replan: invoked on every
rebuild, its plans are the ones that run, a failing replan stops the
rebuild before any phase, and the production replan against a real project
follows manifest and project edits) and the `link`-phase sub-step. The real-process regression is:

```
zig build
python test/provider_hooks_e2e.py --zig /path/to/zig
```

It drives the actual CLI with a fake assembler (the `plugin_compat` pattern,
with a `.cmd` shim on Windows) and two fixture providers declared in reverse
order. It checks: order regardless of declaration order, an `after_hooks`
edge inverting the tie, the context fields, a failing `before` hook's exit
code with no core build and no `after` hook, a failing core build skipping
`after`, discovery errors (`ReplaceRequiresOwnedTarget`, `DuplicateReplaceHook`,
`MissingHookReference`, `HookPhaseOrder`) at `labelle help` before any
compiler and at `labelle build` after the install but before generation,
`generate` hooks seeing the lock, a `before generate` hook's PNG being seen
by the `--bake` pre-pass (and the same command failing on the missing PNG
without the hook), `after build` hooks seeing the finalized artifact (the
`--linux-desktop` entry is in their snapshot of `zig-out/` and not in the
before hooks'), `run` hooks around the game, a `--timeout` kill running no
`after run` hook (and printing the skip line) while a clean exit still
does, an `after build` edit to `zig-out/` reaching
the launched game intact, contract `1.2.0` on a provider target (every
hook's `target_dir` for `build`, `run` and `bundle`, including `bundle
--output` elsewhere; a `replace run` hook receiving the three `LABELLE_*`
pairs of `--scene`/`--screenshot`/`--after`, the `--` arguments and the
timeout, while a planted host-launch sentinel that the unreplaced run does
execute never runs; a provider capped below `1.2.0` getting neither key and
the one `note:` line), contract `1.3.0` environment contributions (a
`before generate` hook's `env_file` reaching the fingerprint pass — the
generated build's configure step logs what it sees, under a `labelle
generate` that runs no compile — then the compile and the later hooks,
never the provider's own tool build, which panics if it does; a hook
removed between two builds leaving nothing; a malformed, empty or reserved
contribution failing before any compile and naming the hook; a failing
hook's file ignored), the owner's `target_defaults` giving
`-Doptimize=ReleaseSafe` and wire `optimize` ReleaseSafe while an explicit
`--optimize` wins, `cache_dir` under `LABELLE_HOME/providers/` keyed by the
canonical provider id (a local provider's directory; a pinned provider's
repository, shared by two spellings of it with its contents kept), a cold package cache failing closed or running a
pinned provider's hooks (never skipping them) — with an unpinned remote hook
refused as `RemoteProviderIntegrityRequired` while `LABELLE_ZIG` points
nowhere, and the same dead compiler being the failure once the pin is
accepted — a reference into an uncached remote package leaving `help` intact
while a typo is still reported, `bundle` hooks and the `.app` location on
macOS, and the refusal elsewhere. `test/provider_github_e2e.py` checks that `--accept` refuses a
broken hook graph without writing the lock. Provider-target resolution and
bundling are covered by `test/provider_targets_e2e.py`. CI runs them on
Windows, macOS and Linux.

## Removed: the legacy browser commands

CLI 3.0 removed `labelle wasm serve|export` together with the core's browser
toolchain, serve and export (RFC cli#466 PR B). `labelle wasm` is an unknown
command now; use the pinned `web` provider through the generic pipeline
(`labelle run|bundle --platform=wasm`, `labelle run --watch --platform=wasm`)
or its namespaced commands (`labelle web serve|export|doctor|toolchain`). See
[migrating to 3.0](migrating-to-3.0.md).

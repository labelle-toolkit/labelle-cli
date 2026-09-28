# Provider-declared targets — phase 3b

This documents the target-resolution slice of CLI #406, stacked on the
[v1 contract](provider-contract-v1.md), [project-local
dispatch](provider-local-dispatch.md) and [lifecycle
hooks](provider-hooks.md). `--platform=<t>` now names a target a pinned
provider declares; the CLI keeps no list of platforms. Android is extracted:
the `android` package (labelle-android) owns target and namespace `android`
and the CLI carries no Android code (cli#405). The other platform packages
(`labelle-web`, …) still remain to be extracted.

## Resolution

Every command that runs the project pipeline (`generate`, `build`, `run`,
`bundle`, and the legacy `ios` subcommand) resolves
one target, in two halves, before anything is generated, locked or built:

1. The requested name is `--platform=<t>` when given, else the project's
   declared `.platform`. The parsers check only that it is identifier-shaped
   (`[a-z][a-z0-9_-]*`); anything else is `invalid target '<t>' (targets are
   lowercase identifiers; run 'labelle targets')`. A Windows reserved device
   name (`con`, `nul`, `prn`, `aux`, `com1`-`com9`, `lpt1`-`lpt9`) is
   identifier-shaped but names directories no Windows host can create
   (`.labelle/<backend>_<t>/`, `zig-out/bundle/<t>/`), so it is refused with
   its own reason — by the parsers, and at manifest validation for a
   declared target or a hook's target (`ReservedDeviceTarget`).
2. `desktop` is the core target and resolves without any provider.
3. Any other name resolves to the pinned provider whose `plugin.labelle`
   declares it in `.targets`. Ownership is validated at discovery, so at most
   one provider can declare a name (`TargetConflict`) and none can declare
   `desktop` (`ReservedTarget`). *Pinned* is load-bearing: a remote package
   read from the ordinary package cache without an integrity pin
   (`Provider.verified == false`) is discovered, and `labelle targets` lists
   its declaration marked `(unpinned)`, but it never resolves a target —
   owning one means generating, building or bundling for it, so the owner is
   held to the same boundary as a hook that runs, even when it declares no
   hook and nothing else would ever ask for its pin:

   ```
   labelle: target 'wasm' is declared by remote package 'labelle-web', which is unpinned; a target's provider must be pinned. Run labelle providers resolve, review the pins, then repeat with --accept.
   ```

4. A name nobody declares fails, with the steps that fix it:

   ```
   labelle: no provider for target 'wasm' in this project; add and pin the package that declares target 'wasm'
     (registry: web)
     The provider registry lists package 'web' as the provider of target 'wasm'.
     Its newest release that declares the target, 0.2.0, is a candidate: `labelle providers resolve --accept`
     checks whether this CLI supports it (on UnsupportedContract, try an older release that declares the target).
     To use it:
       1. add it to .plugins in project.labelle:
            .{ .name = "web", .repo = "github.com/labelle-toolkit/labelle-web", .version = "0.2.0" },
       2. labelle providers resolve            # preview the pin
       3. labelle providers resolve --accept   # verify it and write labelle.providers.lock (commit it;
                                               # fresh clones and CI run `labelle providers fetch`)
     Upgrading a project from CLI 1.x? See https://github.com/labelle-toolkit/labelle-cli/blob/main/docs/migrating-to-2.0.md
   ```

   The package, repository and version are registry data, never names the
   CLI knows. They come from a best-effort lookup made only on this failure
   path (`provider_github/registry_lookup.zig`). The hint is advisory and
   deliberately simple (#459): it reads **one** document, and only a
   **schema-2** document names an owner.

   - **A custom source this project accepted from.** Every `providers
     resolve --accept` records its registry source (an https URL, or the
     absolute path of a local `providers.json`), the normalised document it
     bound and that document's SHA-256 in `.labelle/providers.registry.json`,
     one file written atomically. The lookup reads it once and checks the
     document against the digest in that same snapshot. When it verifies and
     the source is not the public registry, the recorded document answers —
     nothing is downloaded or re-read — and the hint names that source. The
     source is printed on a line of its own, and steps 2 and 3 say to pass
     it to `labelle providers resolve`; it is never interpolated into a
     shell command, since quoting differs per shell (`cmd.exe` expands
     `%…%` even inside double quotes). The hint tells the user to quote or
     escape it for their own shell, because a path can contain spaces or
     special characters.
   - **A record that does not verify** (unreadable, the CLI 2.0.0 layout
     without a digest, a document that does not match its digest, a source
     with control characters) means the project's source is unknown: the
     steps are generic, and the public registry is **not** asked in its place.
   - **Otherwise the public registry**: one download of the registry
     document (`curl`, 3 s connect / 5 s total), parsed and queried by
     target. This is registry metadata only
     ([contract §4](provider-contract-v1.md)): nothing is pinned, cached,
     extracted or run. The download is never written to the registry cache.
   - **The release suggested** is the owner's newest release whose own
     record declares the target (the ownership table is the union of a
     package's releases, so the newest release may have dropped it). It is a
     **candidate**: the registry carries no command-contract metadata, so
     `labelle providers resolve --accept` is what checks that this CLI
     supports it. Contract-aware selection is tracked in #456.
   - Every download, the hint's and `providers resolve`'s, is capped at
     1 MiB by the CLI itself (the captured output), not only by curl's
     `--max-filesize`, which curl before 8.4.0 ignores for a response of
     unknown size. Oversize is a failed download.
   - **Everything else is generic**: `LABELLE_OFFLINE=1` (any value but
     empty or `0`; no download is made), a failed, oversize or unparseable
     download, a schema-1 document, a record that does not verify, or a
     schema-2 document that lists no package for the target. The steps then
     name no package, version or source; they carry a placeholder `.plugins`
     entry, the note that both resolve steps read the public registry unless
     given a `providers.json` path or URL, and one line saying why:
     `registry not consulted: LABELLE_OFFLINE is set`, `the provider registry
     could not be read`, `… does not publish target owners: registry schema
     1`, `… lists no package for this target`, or `the registry this project
     last accepted from is unknown: .labelle/providers.registry.json does not
     verify`.

   Missing information only makes the hint less specific; it never changes
   which source the hint recommends. The global registry cache (which any
   project's accept may have written) is never read for this hint, and no
   archive is scanned. The lookup never changes how the command fails: same
   first line, same exit status, same `failed` progress record, and nothing
   generated.

   Known limitation (#456): the accepted-source record lives in `.labelle/`,
   which is generated output and safe to delete. Deleting it forgets the
   custom source: the next hint asks the public registry, until the next
   `providers resolve <source> --accept` records it again.

The two halves are the **name** and the **ownership**. The name is settled
from the string alone, first thing: `desktop` is core, any other name is
*provisionally* a provider target. That is enough for everything the
pipeline needs before a provider can be read — the target directory, the
progress feed, the schema platform the pre-install steps key off — and for
two verdicts that need no provider: a project with no `.plugins` cannot own
a provider target and is refused before anything is read, written or built,
and `labelle bundle` of the core target is refused off macOS before any
install.

Ownership is decided as early as it can be. Provider discovery is
authoritative only after the assembler's `install` populated the package
cache (a declared remote package has no readable manifest before it; see
[provider hooks](provider-hooks.md#discovery-and-the-graph)) — but for a
provider target the pipeline first runs the same metadata-only discovery
`labelle targets` does (cached manifests, no installer). When that read
every declared package, the verdict it reaches is the one the post-install
check would reach, so it lands right there: an identifier-shaped typo
(`--platform=waasm`), a name no declared package owns, or an unpinned remote
owner is refused before `.prebuild`, the assembler resolution, the ASTC
prepass or the install run — nothing is read, written or built. A manifest
that fails discovery fails it closed there too: the install cannot mend a
manifest that is already readable. Only while a declared remote package is
not readable yet (cold cache, no pin) does the verdict wait for the
post-install discovery, which stays the authoritative check: a declared
package that does not declare the requested name is refused there — after
the install, before the lock, generation or any compiler, with a `failed`
progress record naming the refusal — `no provider for target`, or
`unpinned provider for target` when the declaring package is remote and
unpinned — and nothing else in the target directory. The `labelle-assembler#378` gate and the bundle-replacement check
below need the hook plans, so they land at the post-install point.

`--docker` is decided before any of this (CLI 3.0, RFC cli#466 D5): the
container build is the core `desktop` target's only, so a provider target
requested with `--docker` is refused by name, before the no-provider
verdict, the prebuild steps or the install:

```
labelle: --docker builds the `desktop` target only; target 'wasm' comes from a provider, whose hooks and toolchain run on this host
  build it without --docker (docs/migrating-to-3.0.md)
```

The resolved target is a string. It names the generated tree
(`.labelle/<backend>_<target>/`, from the provisional name, so a refused
target leaves only the `failed` record there), is passed to the assembler's
`generate`, selects the hook plans, and is the `target` every hook and
command context carries. `labelle targets` prints what a project can
resolve:

```
desktop (core)
wasm  provided by labelle-web
```

It is metadata only (like `labelle help`): a broken provider manifest is a
warning on that listing, not a failure.

## The labelle-assembler#378 boundary

`project.labelle`'s `.platform` keeps its strict schema type
(`project_config.Platform`, mirrored by the assembler), and the assembler
still parses `--platform` against that enum. The CLI therefore draws one
explicit line:

- A provider target whose name is a schema platform (`wasm`, `android`,
  `ios`) is handed to the assembler as `--platform <name>`, exactly as
  before. The legacy pipeline branch that keys on the enum (`ios`) keeps
  working for it; `android` and `wasm` have none left, so their providers
  replace `run` (see [`labelle run`](#labelle-run)).
- A provider target outside the enum can only be generated for by its
  provider's `replace` hook on `generate`. Without one the command stops
  before the assembler runs:

  ```
  labelle: target 'probe-target' is declared by 'fixture' but the pinned assembler cannot generate for it yet (labelle-assembler#378)
  ```

  With one, the provider generates; the core steps it does not replace
  (`build`, `run`) treat the target as the generic host baseline. The ASTC
  prepass is not among them: it keys on the requested target, and a target
  outside the enum has no `asset_compression` setting (standalone `labelle astc`
  can read that target's backend manifest declaration),
  so the prepass is skipped rather than run with the derived `desktop` — a
  provider owns its target's asset pipeline.

What waits for assembler#378: string-resolved platforms in `generate`, the
removal of the `Capability.{wasm,android,ios}` derivation, and the enum
leaving both schema mirrors. Nothing in `project.labelle` changes in this
slice, and `provider_settings.zig` is untouched.

## `labelle run`

The CLI launches only the core `desktop` target on this host, plus the
legacy run branch it still carries (the `ios` simulator). The core's own
browser serve left in 3.0: the `web` provider's `replace run` hook serves
`wasm` now.
Every other provider target is launched by its provider, so it must have a
`replace` hook on `run`, otherwise:

```
labelle: target '<t>' has no run replacement; package '<pkg>' must declare a `.when = .replace` hook on `run`
```

(`NoRunReplacement`). Like `NoBundleReplacement` it is decided with the hook
plans after discovery — after the install, before generation or any build —
so a run that cannot launch never builds. Without it the run would fall
through to the host launch and execute a binary built for another platform.
The legacy set (`legacyRunBranch` in `pipeline/install.zig`) only shrinks:
a platform leaves it when its launch moves into a provider (`android` left
with cli#405). The replacement receives the run options as `run.env`
(contract 1.2.0, [provider hooks](provider-hooks.md)).

`labelle run --watch` (CLI 2.1.0+) needs the target's run replacement to
declare `.watch = true` and its provider to speak wire `1.3.0` or newer; it
is refused, before any build, for a target without one — the core `desktop`
target and every native target included — naming the package and what is
missing. See the contract's
[watch sessions](provider-contract-v1.md#watch-sessions).

## Optimize defaults

The owner of a target may declare the optimize mode its builds default to,
in its manifest (CLI 2.1.0+):

```zig
.targets = .{"sample-target"},
.target_defaults = .{ .{ .target = "sample-target", .optimize = .ReleaseSafe } },
```

Only the owner may: a default for a target the same manifest doesn't declare
in `.targets` is `TargetDefaultRequiresOwnedTarget`, and two defaults for one
target are `DuplicateTargetDefault`. Both are discovery errors, reported at
`labelle help` like every manifest error.

The effective mode is an explicit `--optimize=<mode>` when given, else the
owner's default, else none: since 3.0 the core keeps no per-target default
of its own (the `wasm` ReleaseSafe default is the web provider's
`.target_defaults`). The core `zig build` gets it as `-Doptimize=<mode>`, every hook
receives it as the wire `optimize`, and a watched rebuild's replan
recomputes it from the providers it rediscovers (in a `labelle run --watch`
session a change of the effective mode stops the rebuild with a restart
diagnostic: the running replacement was started with the old one). The core `desktop` target
has no owner, so no provider can change its default. See the contract's
[target defaults](provider-contract-v1.md#target-defaults).

## `labelle bundle`

`labelle bundle [--platform=<t>]` bundles the resolved target (the old
"project platform is X; bundling the desktop target instead" override is
gone):

- `desktop` uses the core macOS packager. The host gate moved from the
  argument parser into the pipeline, right after the name is settled: off
  macOS it is still refused before any install or build, but only for the
  core target, and no hook can replace it because nobody may own `desktop`.
- A provider target must have a `replace` hook on `bundle`, otherwise
  `labelle: target '<t>' has no bundle replacement; package '<pkg>' must
  declare a `.when = .replace` hook on `bundle`` (`NoBundleReplacement`),
  decided with the hook plans after discovery (after the install, before
  any build). The hook runs on any host with `output_dir` =
  `<target_dir>/zig-out/bundle/<t>/` (or the resolved `--output`), per the
  [output layout](provider-hooks.md#output-layout). The replacement stands
  in for the core packager only: the `build` step's hooks, the owner's
  `after build` hooks included, run first, as under `labelle build`. An
  owner whose `after build` hook makes an install package that the bundle
  replacement makes again skips it when the context's `final_step` is
  `bundle` (wire `1.4.0`+, [provider hooks](provider-hooks.md#order),
  cli#443).

## Migration

This slice is breaking for every web and mobile project, as the RFC's
migration order requires — no forwarding shim, no alias, no implicit
package injection (RFC #406 "Migration", #410). The user-facing walkthrough,
with Flying Platform as the worked example, is
[Migrating a project to labelle CLI 2.0](migrating-to-2.0.md):

- A project that builds for `wasm`, `android` or `ios` — through `.platform`,
  `--platform=<t>`, or `labelle ios …` — must add the package that declares that target to
  `.plugins` (as `.repo = "github.com/<owner>/<name>"`) and pin it
  (`labelle providers resolve`, then `--accept`). Until it does, those
  commands fail with the no-provider error above. Commit
  `labelle.providers.lock`; every other checkout (a teammate, CI) then runs
  `labelle providers fetch`, or `labelle install`, once to download the
  pinned archives, since no normal command downloads them
  ([pins](provider-github-pins.md#fresh-checkouts-and-ci-labelle-providers-fetch)).
- The target name is unchanged: `--platform=wasm` stays `--platform=wasm`,
  because the web provider declares the target `wasm`. Only the pin is new.
- The legacy `labelle ios` command word stays a reserved built-in until its
  extraction lands; it routes its target through the same resolver. The
  legacy `labelle wasm serve|export` left the core in 3.0: `wasm` is no
  reserved word any more ([migrating to 3.0](migrating-to-3.0.md)).
- `labelle android …` is no built-in any more (cli#405): it is the `android`
  provider's namespace. Without that package pinned, `labelle android` is an
  unknown command — or, when the cached registry names the package that
  declares the namespace, `labelle: no provider for namespace 'android' in
  this project; add and pin the package that declares namespace 'android'`
  with a `(registry: <package>)` line. `labelle android doctor` therefore
  runs inside a project that pins the package; the projectless form is gone.
  The CLI's own packaging on `labelle build --platform=android`, the
  `.android` block it used to read (still accepted, and ignored, by the
  CLI's lenient parse; the assembler owns its strictness) and the
  raylib-to-sokol fallback for Android are removed: the provider's
  after-build hook packages the APK under `zig-out/apk/`.
- labelle-studio's web preview builds through `labelle build
  --platform=wasm` and must add and pin `labelle-web`.

## Verification

Unit tests (`zig build test-provider-dispatch`, also collected by `zig build
test`) cover `provider_targets.resolve` (core with no providers, a provider
target, an undeclared target, an unpinned remote owner, the schema-name
mapping through a provider only, the diagnostic's steps on a registry hit
(public and custom, the custom source never inside a command) and on each
kind of miss, identical past the reason line), `registry_lookup.lookupOwner` (a
public schema-2 hit naming the newest release that still declares the target,
not listed, schema 1, unreachable, unparseable, oversize, offline with no
fetch, a verified custom record answered from its document with no fetch, and
records that do not verify answered generically with no public fetch, each
asserting which URLs the fetcher was asked for), `Registry.latestDeclaring`,
`provider_github.cachedRegistryNamespaceOwner`
(schema 2 only), the `NoRunReplacement` decision table
(`pipeline/install.zig`), `provider_registry` (schema-2 parsing, ownership
conflicts, lookup by target and namespace), `provider_dispatch.discoverAll` (the
unresolved packages of a partial view), the reserved-device-name rule
(`provider_contract.targetName`, the manifest's `targets` and hook targets,
`args.parseTargetValue`) and `parseBundleArgs --platform`. The real-process
regression is:

```
zig build
python test/provider_targets_e2e.py --zig /path/to/zig
```

It drives the actual CLI with a fake assembler that records the target it
was asked for: the no-provider error for `--platform=wasm`, the declared
`.platform` and every legacy subcommand, with no assembler invocation; the
early verdict for a local provider that does not own the name, including a
typo that leaves a `.prebuild` marker step unrun (while a resolving target
runs it); a remote package on a cold cache deferring the verdict to after
the install (the `failed` record) and, unpinned, refused as an owner both
after the install and — warm — before it; the #378 message before the
assembler runs; `NoBundleReplacement`; a provider replacing
`generate`/`build`/`bundle` for `probe-target`, including `labelle bundle
--platform=probe-target` running the replacement on every host with the
contract's `output_dir`; the ASTC prepass running for `desktop` and not for
`probe-target`; a provider owning `wasm` making the assembler receive
`--platform wasm`; the `labelle targets` listing; and, on POSIX, the
no-provider registry lookup through a stand-in `curl` that logs each request
(a hit naming the package and its newest declaring release as a candidate, a
registry that lists no owner, a schema-1 registry, an unreachable or oversize
registry, and `LABELLE_OFFLINE=1` making no request),
each failing exactly as the hermetic runs do. Every other run sets
`LABELLE_OFFLINE=1`, so no suite touches the network. CI runs it on Windows,
macOS and Linux. `test/provider_android_like_e2e.py` drives an
android-shaped fixture package the same way (no NDK): the no-provider
diagnostic staying generic offline even with a cached registry, and the
no-namespace diagnostic with and without that cached hint, the
assembler receiving `--platform android`, the after-build hook seeing the
built library and the target dir, the run replacement receiving `run.env`
with no host launch, `NoRunReplacement` before any build, `labelle android
run …` reaching the tool verbatim, `bundle --build-number` and a legacy
`.android` block passing through unchanged. The Docker lane in `ci.yml`
checks the `--docker` refusal for a provider target, then cross-builds the
core `desktop` target in the container.

# Tester onboarding (Android, via Obtainium)

Short guide for sending an internal tester a game build so they can receive updates automatically. Paired with `labelle android deploy` (ticket #141), this is the v1 of labelle's OTA story — zero custom infrastructure, ships through GitHub Releases.

Since labelle-cli#405 the Android commands come from the `android` provider package ([labelle-android](https://github.com/labelle-toolkit/labelle-android)), not from the CLI itself. The project must add it to `project.labelle` `.plugins` (`.repo = "github.com/labelle-toolkit/labelle-android"`) and pin it (`labelle providers resolve`, then `labelle providers resolve --accept`, and commit `labelle.providers.lock`), and every `labelle android …` command runs inside that project. On a fresh clone or a new machine, run `labelle providers fetch` (or `labelle install`) once first: it downloads the provider archive the lock pins, which no other command does, and without it every command fails with `ProviderArchiveMissing`. Signing, `package_name` and the `deploy` defaults live in the provider's settings file (`providers/android.json`); see the labelle-android README for the schema.

## Developer side (one-time per project)

The game repo needs to be where releases live. If it already has GitHub Releases enabled, you're done. A release is two steps: bundle the APK, then publish it.

1. `labelle bundle --platform=android --optimize=ReleaseFast --build-number=<n>` builds a signed release APK (the keystore configured under `signing` in `providers/android.json`, else the debug keystore) into `.labelle/<backend>_android/zig-out/bundle/android/`, with `versionCode` = `<n>`.
2. `labelle android deploy --tag v0.3.0` attaches that APK to a new GitHub Release with auto-generated notes (commits since the last tag). It builds nothing.
3. `--channel=staging|preview|internal` marks the release as a pre-release.

Requirements on the dev's machine:
- [`gh`](https://cli.github.com/) installed and authenticated (`gh auth login`).
- Android SDK + NDK + JDK configured (see `labelle android doctor`, run inside the project; a plain `labelle doctor` there runs it too, after the core checks).
- A keystore. For internal testing, the debug keystore the provider generates on first use is fine. For production distribution, configure `signing` in `providers/android.json`; its passwords are `env:VAR` or `file:PATH` sources, never literals.

Typical deploy commands:

```bash
# Build the release APK once per release (versionCode = the build number).
labelle bundle --platform=android --optimize=ReleaseFast --build-number=42

# Stable release — public (or private-repo-gated) channel.
labelle android deploy --tag v0.3.0

# Staging / preview — marked as GitHub pre-release.
labelle android deploy --tag v0.3.0-rc1 --channel staging

# Custom release notes.
labelle android deploy --tag v0.3.0 --notes-file NOTES.md
```

APKs are arm64-v8a only for now; the multi-arch (`--all-abis`) APK is not part of the provider yet.

## Tester side (one-time per device)

1. **Install Obtainium**. It's an open-source Android app that watches a list of APK sources and installs updates.
   - Recommended: install from [F-Droid](https://f-droid.org/) for painless updates of Obtainium itself.
   - Or grab the latest APK directly from <https://github.com/ImranR98/Obtainium/releases>.

2. **Add the game repo as a source**.
   - Open Obtainium → tap **+** → paste the GitHub repo URL (e.g. `https://github.com/<org>/<game>`).
   - Obtainium detects the GitHub source, pulls the latest release, and installs the APK.
   - If the repo is private: Obtainium → Settings → Source settings → GitHub → add a [personal access token](https://github.com/settings/tokens) with `repo` scope. One token covers every private game repo the tester is invited to.

3. **Done**. New deploys show up in Obtainium's Apps tab as available updates; tap to install.

By default Obtainium checks for updates in the background on a schedule (configurable). Testers who want to poll manually can pull-to-refresh the Apps screen.

## Staging / preview channels

GitHub pre-releases (what `--channel staging` produces) are hidden from the "latest" release by default, but Obtainium's GitHub source exposes a per-app **Include pre-releases** toggle. Testers opt into pre-releases per source:

- Obtainium → tap the app → settings icon → toggle **Include pre-releases**.

That's the whole channel story in v1 — testers subscribed with pre-releases on get every build; those without only see the stable tags.

## Limits of the v1 flow

| What you give up vs the planned custom companion (#142) | Workaround |
|---|---|
| Silent auto-install | Tester taps "install" in Obtainium's notification. Still zero developer interaction. |
| Branded experience | Obtainium's UI, not labelle's. |
| Fine-grained channels beyond stable / prerelease | Separate repos or tag prefixes if needed. |
| Central revocation of access | Private repo + invite revocation. Obtainium can't fetch without a valid token. |

When any of these become real pain points, revisit #142 (silent-install companion) and #139 (centralized labelle.games service).

## Troubleshooting

- **`gh auth status` fails during deploy.** Run `gh auth login` and retry. The deploy command probes this up front so you don't build a multi-MB APK just to discover the uploader isn't available.
- **`gh release create` fails with "tag already exists".** Either pick a new tag or delete the existing release first: `gh release delete <tag> --yes`.
- **Obtainium doesn't detect the new release.** Pull-to-refresh on the Apps screen, or check Settings → Background Updates Interval.
- **Private repo, Obtainium can't authenticate.** Check the PAT is still valid (`repo` scope, not expired). Issue a new one if in doubt.

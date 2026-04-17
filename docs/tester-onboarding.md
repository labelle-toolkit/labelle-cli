# Tester onboarding (Android, via Obtainium)

Short guide for sending an internal tester a game build so they can receive updates automatically. Paired with `labelle android deploy` (ticket #141), this is the v1 of labelle's OTA story — zero custom infrastructure, ships through GitHub Releases.

## Developer side (one-time per project)

The game repo needs to be where releases live. If it already has GitHub Releases enabled, you're done. A normal `labelle android deploy --tag v0.3.0` will:

1. Build a signed release APK (uses the keystore configured in `project.labelle` / CLI flags).
2. Attach it to a new GitHub Release with auto-generated notes (commits since the last tag).
3. Mark it as a pre-release when `--channel=staging|preview|internal` is set.

Requirements on the dev's machine:
- [`gh`](https://cli.github.com/) installed and authenticated (`gh auth login`).
- Android SDK + NDK configured (see `labelle android doctor`).
- A keystore — for internal testing, the debug keystore produced by `labelle android build` is fine. For production distribution, use a real keystore and pass `--keystore`, `--keystore-pass`, `--key-alias`, `--key-pass`.

Typical deploy commands:

```bash
# Stable release — public (or private-repo-gated) channel.
labelle android deploy --tag v0.3.0

# Staging / preview — marked as GitHub pre-release.
labelle android deploy --tag v0.3.0-rc1 --channel staging

# Multi-arch APK (arm64 + x86_64), custom release notes.
labelle android deploy --tag v0.3.0 --all-abis --notes-file NOTES.md
```

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

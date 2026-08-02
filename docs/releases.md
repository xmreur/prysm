# GitHub Releases

Prysm publishes tagged releases (`v*`) to [GitHub Releases](https://github.com/xmreur/prysm/releases) via CI.

## Asset naming

Versioned assets use the release tag in the filename (e.g. tag `v0.6.1-fix`):

| Filename pattern | Platform |
|------------------|----------|
| `Prysm-android-v0.6.1-fix.apk` | Android |
| `Prysm-ios-v0.6.1-fix.ipa` | iOS (unsigned, sideload) |
| `Prysm-windows-x86_64-v0.6.1-fix.zip` | Windows |
| `Prysm-linux-x86_64-v0.6.1-fix.zip` | Linux |
| `Prysm-macos-v0.6.1-fix.zip` | macOS (contains `prysm.app`) |
| `prysm-updater-windows.exe` | Desktop updater (Windows) |
| `prysm-updater-linux` | Desktop updater (Linux) |
| `prysm-updater-macos` | Desktop updater (macOS) |

Tag format: `v0.5.1` (semver with `v` prefix).

Older releases may use legacy names (`prysm-android.apk`, `prysm-linux.tar.gz`, etc.); the in-app updater falls back to those when the versioned asset is not found.

## Android updates

The app checks `api.github.com/repos/xmreur/prysm/releases/latest`, compares the tag to the installed version, and downloads `Prysm-android-<tag>.apk` (with legacy `.apk` fallback). The APK must be signed with the same key as the installed app.

## Desktop updates

The main app spawns the external updater with CLI arguments:

```
prysm-updater-<platform> --url <package_download_url> --install-dir <app_directory>
```

- `--url`: direct download URL for the platform package (e.g. `Prysm-linux-x86_64-v0.6.1-fix.zip`).
- `--install-dir`: directory containing the running app (Windows/Linux: executable directory; macOS: `.app` bundle path).

The main app exits after launching the updater so files can be replaced.

### prysm-auto-updater requirements

The [prysm-auto-updater](https://github.com/xmreur/prysm-auto-updater) binary must:

1. Accept `--url` and `--install-dir` arguments.
2. Download the package from `--url`.
3. Extract/replace files under `--install-dir` while the main app is not running.
4. Optionally relaunch the app after installation.

Updater binaries are cached per release tag under `<Application Support>/updater/<tag>/`. SHA-256 checksums are required before execution, loaded from `prysm-resources` (`updater/manifest.json`) keyed as `<tag>/<asset-name>`, with embedded fallbacks for `v0.0.1`. When a release reuses the v0.0.1 updater binary, checksum lookup falls back to the `v0.0.1` entry. Add manifest entries when shipping new updater builds.

## Debug testing

In **debug builds only**, Settings includes a **Debug options** section with:

- **Preview update dialog** — mock `v99.0.0-debug` dialog; no network or download.
- **Test update flow** — fetches the latest GitHub release and skips the version check. On Android this runs the real download and installer intent. On desktop this is a **dry-run** (toast shows the package URL and install dir; the app does not exit).

To exercise a real desktop updater launch from a debug build, call
`AppUpdateService().debugTestUpdateFlow(context, dryRunDesktop: false)` from a one-off debug hook.

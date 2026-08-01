# GitHub Releases

Prysm publishes tagged releases (`v*`) to [GitHub Releases](https://github.com/xmreur/prysm/releases) via CI.

## Asset naming

| Filename | Platform |
|----------|----------|
| `prysm-android.apk` | Android |
| `prysm-windows.zip` | Windows |
| `prysm-linux.tar.gz` | Linux |
| `prysm-macos.zip` | macOS |
| `prysm-updater-windows.exe` | Desktop updater (Windows) |
| `prysm-updater-linux` | Desktop updater (Linux) |
| `prysm-updater-macos` | Desktop updater (macOS) |

Tag format: `v0.5.1` (semver with `v` prefix).

## Android updates

The app checks `api.github.com/repos/xmreur/prysm/releases/latest`, compares the tag to the installed version, and downloads `prysm-android.apk` (or any `.apk` asset as fallback). The APK must be signed with the same key as the installed app.

## Desktop updates

The main app spawns the external updater with CLI arguments:

```
prysm-updater-<platform> --url <package_download_url> --install-dir <app_directory>
```

- `--url`: direct download URL for the platform package (`prysm-windows.zip`, `prysm-linux.tar.gz`, or `prysm-macos.zip`).
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

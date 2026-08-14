# Bundled lyrebird (obfs4) binaries

Desktop obfs4 uses the **lyrebird** pluggable-transport client, shipped inside the
app at build time. The Prysm app never downloads these at runtime.

## Layout

```
assets/native/pt/
  linux/amd64/lyrebird
  linux/arm64/lyrebird
  macos/lyrebird
  windows/lyrebird.exe
```

Binaries are listed in `.gitignore` to keep the repo small. Populate them before
release builds with:

```bash
./tool/fetch_lyrebird.sh
```

## Build integration

| Platform | Mechanism |
|---|---|
| Linux | `cmake/bundle_lyrebird.cmake` installs into `bundle/lib/lyrebird` |
| Windows | same cmake module installs `lyrebird.exe` next to `Prysm.exe` |
| macOS | Xcode "Bundle Lyrebird" script copies into `Contents/Resources/` |
| All | Flutter assets (fallback extract via `LyrebirdLocator`) |

## Source

Repository: https://gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/lyrebird.git

`tool/fetch_lyrebird.sh` clones that repo and cross-compiles `./cmd/lyrebird`
for each desktop target. Requires **Go 1.21+** and **git**.

Mobile (Android/iOS) uses **IPtProxy** instead; no files here are needed for mobile.

# Discord Drover for macOS

A native macOS port of the behavior in
[hdrover/discord-drover](https://github.com/hdrover/discord-drover).
The referenced Windows program is a process-local Discord network shim, not a
replacement client. This project provides the same useful modes on macOS:

- **Direct mode** leaves TCP traffic direct and applies the UDP voice
  preamble behavior.
- **HTTP proxy mode** starts Discord with an HTTP proxy and supports Basic
  proxy authentication in the first CONNECT request.
- **SOCKS5 mode** starts Discord with a SOCKS5 proxy and translates HTTP
  CONNECT requests emitted by proxy-aware child traffic, without SOCKS5
  authentication.
- **Optional `drover-packet.bin`** is sent before the built-in `0`, `1`
  datagrams on a new matching voice connection, and is read fresh each time.
- Discord, Discord Canary, and Discord PTB installs are discovered in
  `/Applications` and `~/Applications`.

## Why This Is a Launcher on Mac

The Windows version can be loaded as `version.dll` beside Discord. macOS app
signing does not provide an equivalent DLL side-loading path. Discord Drover
therefore makes a private copy of the selected Discord app under:

```text
~/Library/Application Support/Discord Drover/Managed/
```

It ad-hoc signs that copy, clears inherited download-quarantine metadata from
that generated local copy, and launches it with `libdrover.dylib` inserted.
The Discord installation in `/Applications` is never modified. When the
original Discord version changes, the private copy is rebuilt automatically.

Because of this macOS design, start Discord with **Prepare and Launch Discord**
in Discord Drover whenever the shim should be active.

## Build on macOS

Requirements:

- macOS 13 or later
- Xcode Command Line Tools (`xcode-select --install`)
- An installed Discord, Discord Canary, or Discord PTB app

Build the `.app` bundle:

```bash
cd discord-drover-macos
bash Scripts/build-app.sh
open "build/Discord Drover.app"
```

The first locally built launch may require choosing **Open** from Finder's
context menu because the app is ad-hoc signed rather than notarized.

## Distribute

For a simple private share, build and zip the app on a Mac:

```bash
cd discord-drover-macos
bash Scripts/build-app.sh
bash Scripts/package-zip.sh
```

Give the resulting file to the recipient:

```text
build/Discord-Drover-macOS.zip
```

They should unzip it, move **Discord Drover.app** to `Applications`, then
Control-click the app and choose **Open** on first launch. This is needed for
an ad-hoc signed build shared outside the App Store.

For public downloads without the Control-click warning, join the Apple
Developer Program, use a Developer ID Application certificate, and notarize
the ZIP. When a signing identity is supplied, the build script enables
hardened runtime and a trusted timestamp for that distribution build. After
installing your signing certificate in Keychain, build with:

```bash
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" bash Scripts/build-app.sh
bash Scripts/package-zip.sh
xcrun notarytool store-credentials "notarytool-profile" \
  --apple-id "you@example.com" --team-id "TEAMID" \
  --password "APP-SPECIFIC-PASSWORD"
xcrun notarytool submit "build/Discord-Drover-macOS.zip" \
  --keychain-profile "notarytool-profile" --wait
xcrun stapler staple "build/Discord Drover.app"
bash Scripts/package-zip.sh
```

Upload the final ZIP to a GitHub Release, your website, or another direct
download host.

This repository also includes a GitHub Actions release workflow. Pushing a
tag such as `v0.1.0` builds the app on a GitHub-hosted Mac and publishes
`Discord-Drover-macOS.zip` as a release download. That automated build is
ad-hoc signed unless you later add a Developer ID/notarization release setup,
so downloaded copies require the Control-click **Open** step above.

Each release build executes local socket integration tests on GitHub's macOS
runner before packaging. The tests verify the Direct-mode UDP preamble and
optional packet, HTTP proxy authorization injection, and SOCKS5 CONNECT
translation. They cannot verify a real Discord voice call on a restricted
network; that last check depends on the user's Discord installation and
network path.

## Use

1. Quit any running Discord process.
2. Open `Discord Drover.app` and select the installed Discord channel.
3. Select Direct, HTTP, or SOCKS5 mode and fill proxy details if needed.
4. Optionally import a `drover-packet.bin` file.
5. Click **Prepare and Launch Discord**.

Configuration and the optional packet are stored at:

```text
~/Library/Application Support/Discord Drover/
```

Use **Remove Managed Copy** to delete only the re-signed launch copy; it does
not remove Discord itself or the saved packet/configuration.

## Troubleshooting Launches

If Discord Drover reports that Discord exited before opening, click **Show
Prepared Discord in Finder** to locate the privately prepared copy. The button
shows the file; it does not launch Discord. New builds automatically clear
quarantine from that generated local copy. If macOS still blocks it, in Finder
Control-click the revealed `Discord.app`, select **Open**, and approve it.
Quit the normal Discord window that opens, then return to Discord Drover and
click **Prepare and Launch Discord** again.

Launch diagnostics are written to:

```text
~/Library/Application Support/Discord Drover/discord-launch.log
```

## Implementation Notes

The injected dylib interposes Darwin `socket`, `send`, `sendto`, `sendmsg`,
`recv`, `write`, and `read` calls. Like the source Windows project, UDP
handling is applied only when the first outgoing datagram from a tracked UDP
socket is 74 bytes: it sends the optional packet, one byte containing `0`,
one byte containing `1`, waits 50 ms, and then allows the original packet.

This source tree must be built and exercised on a Mac; a Windows host cannot
compile or live-test the macOS dylib injection and Discord voice path.

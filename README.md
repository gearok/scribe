# Scribe

Scribe is a native macOS app for recording meetings and turning them into searchable, editable transcripts. It records your microphone and meeting audio, supports Russian and English, and keeps recordings and transcription on your Mac.

- Browse recordings by day in a simple sidebar.
- Rename speakers, merge duplicate labels, and correct transcript text.
- Play audio with the current paragraph highlighted and the transcript scrolling along.
- Import existing audio and export transcripts with timestamps and speaker names.
- Switch the interface between Russian and English in Settings.
- Check for new versions and install verified updates from GitHub Releases.

## How transcription works

1. **Record.** Scribe saves your microphone and meeting audio as separate tracks. You can also record only your microphone or import an audio file.
2. **Find speakers.** After you stop recording, Scribe detects different voices in the meeting track. Your microphone is labeled “You”.
3. **Turn speech into text.** Local models transcribe the speech in Russian, English, or automatic mixed-language mode. Speaker detection and transcription run one after another to keep memory use manageable.
4. **Review.** The transcript appears with speaker labels and timestamps. Listen, assign names to speakers, edit the text, and export it. Overlapping voices may need manual correction.

The models need a one-time internet download from Settings and several GB of free disk space. Meeting audio is never sent to a transcription service. Once the models are downloaded, processing works offline.

## Install and use

Requires an **Apple Silicon Mac with macOS 15 or newer**. Liquid Glass controls are used on macOS 26 and newer.

Download a DMG from [Releases](https://github.com/gearok/scribe/releases), open it, and drag Scribe into Applications. Current packages are ad-hoc signed and **not notarized by Apple**; macOS may require approval in **System Settings → Privacy & Security** before the first launch.

Choose **Start Recording**, allow microphone and system-audio access, and stop when the meeting ends. Download the models in Settings if prompted. Headphones help keep other participants’ speech out of your microphone track.

Settings are available from the Scribe system menu. The interface language and transcription language can be chosen separately.

## Updates

Use **Scribe → Check for Updates**, or the Updates section in Settings. Scribe checks automatically once a day by default; you can turn this off in Settings. When a newer release is available, Sparkle downloads the DMG, verifies its signature, and offers to install and relaunch. You choose when to install; recording, transcription, imports, and model setup postpone update checks and restarts.

The update feed and downloads come from this repository’s GitHub Releases over HTTPS. Both the feed and DMG are signed with a separate update key. Recordings and transcripts are never included in update requests. The first version containing the updater must be installed manually; subsequent releases can update in the app.

Recordings, transcripts, and models are stored in `~/Library/Application Support/Scribe/`. Use **Show in Finder** in Settings to open this folder. There is no cloud sync or app-specific encryption.

## Build locally

Install Xcode 26 or newer with Swift 6.2 or newer, and complete Xcode’s first-launch setup. Then run:

```sh
./scripts/run.sh
```

For tests, an optimized app, or an isolated sample library:

```sh
swift test
./scripts/build-app.sh release
./scripts/run.sh --demo
```

The app bundle is written to `build/Scribe.app`. Each packaged build is copied to a temporary location and runs a resource check before it can be released, so development build paths cannot substitute for installed resources. Demo mode uses a temporary library and does not change your recordings. The model integration test is opt-in through `SCRIBE_TEST_MODELS_DIR`; the regular test suite does not download models or record audio.

## Publish a release

Open **Actions → Release DMG → Run workflow** on GitHub and supply a new version tag such as `v1.0.0`. The workflow always builds **main**, runs tests, packages the Apple Silicon app, tags the exact commit it built, and creates a GitHub Release with the DMG, SHA-256 checksum, and signed `appcast.xml` update feed. Existing tags are rejected. App version metadata comes from the supplied tag. Publish increasing versions and leave the release marked as GitHub’s latest stable release so installed apps find it.

The workflow requires the `SPARKLE_PRIVATE_KEY` repository secret. It must match `SUPublicEDKey` in `Resources/Info.plist`; a mismatched key must not be used to publish updates. The signing key is kept in the macOS login Keychain under Sparkle’s `app.scribe.mac` account. Keep a secure backup of this key: changing or losing it breaks updates for existing installations. After `swift package resolve`, Sparkle’s `generate_keys --account app.scribe.mac -x /secure/path/scribe.key` tool in `.build/artifacts/sparkle/Sparkle/bin/` exports it for backup or configuring another release environment. Never commit the private key.

To package the same DMG locally without creating a release:

```sh
./scripts/package-dmg.sh v1.0.0
```

Outputs are `build/Scribe-v1.0.0-arm64.dmg` and its `.sha256` file. `scripts/generate-appcast.sh v1.0.0` also generates the signed feed when `SPARKLE_PRIVATE_KEY` is supplied in the environment. The existing DMG is reused for updates; no separate app archive is needed. Sparkle update signatures are independent of Apple code signing. Developer ID signing and Apple notarization are not configured.

## Built with

[SwiftUI](https://developer.apple.com/xcode/swiftui/), [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) for speech recognition, [FluidAudio](https://github.com/FluidInference/FluidAudio) for speaker detection, [GRDB](https://github.com/groue/GRDB.swift) for the local SQLite library, and [Sparkle](https://sparkle-project.org/) for signed app updates. Dependencies and model assets retain their own licenses; package versions are pinned in `Package.swift` and `Package.resolved`.

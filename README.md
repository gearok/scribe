# Scribe

Scribe is a native macOS app for recording meetings and turning them into searchable, editable transcripts. It records your microphone and meeting audio, supports Russian and English, and keeps recordings and transcription on your Mac.

- Browse recordings by day in a simple sidebar.
- Rename speakers, merge duplicate labels, and correct transcript text.
- Play audio with the current paragraph highlighted and the transcript scrolling along.
- Import existing audio and export transcripts with timestamps and speaker names.
- Switch the interface between Russian and English in Settings.

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

The app bundle is written to `build/Scribe.app`. Demo mode uses a temporary library and does not change your recordings. The model integration test is opt-in through `SCRIBE_TEST_MODELS_DIR`; the regular test suite does not download models or record audio.

## Publish a release

Open **Actions → Release DMG → Run workflow** on GitHub and supply a new version tag such as `v1.0.0`. The workflow always builds **main**, runs tests, packages the Apple Silicon app, tags the exact commit it built, and creates a GitHub Release with the DMG and a SHA-256 checksum. Existing tags are rejected. App version metadata comes from the supplied tag.

To package the same DMG locally without creating a release:

```sh
./scripts/package-dmg.sh v1.0.0
```

Outputs are `build/Scribe-v1.0.0-arm64.dmg` and its `.sha256` file. Developer ID signing and Apple notarization are not configured.

## Built with

[SwiftUI](https://developer.apple.com/xcode/swiftui/), [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) for speech recognition, [FluidAudio](https://github.com/FluidInference/FluidAudio) for speaker detection, and [GRDB](https://github.com/groue/GRDB.swift) for the local SQLite library. Dependencies and model assets retain their own licenses; package versions are pinned in `Package.swift` and `Package.resolved`.

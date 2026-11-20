# Scribe

Scribe is a native macOS app for recording meetings and turning them into searchable, editable transcripts. It records your microphone and meeting audio, supports Russian and English, and keeps recordings and transcription on your Mac.

## How transcription works

1. **Record.** Scribe saves your microphone and meeting audio as separate tracks. You can also record only your microphone or import an audio file.
2. **Find speakers.** After you stop recording, Scribe detects different voices in the meeting track. Your microphone is labeled “You”.
3. **Turn speech into text.** Local models transcribe the speech in Russian, English, or automatic mixed-language mode. Speaker detection and transcription run one after another to keep memory use manageable.
4. **Clean up overlaps.** Scribe removes matching passages recognized at overlapping times, including meeting audio picked up again by the microphone. It keeps the meeting track’s speaker-labeled copy and preserves words that do not match. Short replies and phrases repeated later are kept.
5. **Review.** The transcript appears with speaker labels and timestamps. Listen, assign names to speakers, edit the text, and export it. Overlapping voices may need manual correction.

Overlap cleanup runs during transcription. To apply it to an older recording, use **Transcribe Again**; this replaces the transcript and its manual edits after confirmation. Original audio tracks are kept.

The models need a one-time internet download from Settings and several GB of free disk space. Meeting audio is never sent to a transcription service. Once the models are downloaded, processing works offline.

## Install and use

Requires an **Apple Silicon Mac with macOS 15 or newer**.

Download a DMG from [Releases](https://github.com/gearok/scribe/releases), open it, and drag Scribe into Applications. Current packages are ad-hoc signed and **not notarized by Apple**, so macOS may block the first launch with “Apple could not verify Scribe is free of malware.”

For a release you trust from this repository:

1. Open Scribe from **Applications**. If macOS blocks it, choose **Done** rather than Move to Trash.
2. Open **System Settings → Privacy & Security**, scroll to Security, and click **Open Anyway** next to Scribe.
3. Confirm **Open** and authenticate if macOS asks. Scribe can then launch normally.

Choose **Start Recording**, allow microphone and system-audio access, and stop when the meeting ends. Download the models in Settings if prompted. Headphones help keep other participants’ speech out of your microphone track.

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

## Built with

[SwiftUI](https://developer.apple.com/xcode/swiftui/), [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) for speech recognition, [FluidAudio](https://github.com/FluidInference/FluidAudio) for speaker detection.

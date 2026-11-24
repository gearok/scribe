# Scribe

Scribe is a native macOS app for recording meetings and turning them into searchable, editable transcripts. It records your microphone and meeting audio, supports Russian and English, and keeps recordings and transcription on your Mac.

## How transcription works

1. **Record or import.** Scribe saves your microphone and meeting audio as separate tracks. You can also record only your microphone, import an audio file, or import a video and use only its audio track.
2. **Find speakers.** After you stop recording, Scribe detects different voices in the meeting track. Your microphone is labeled “You”.
3. **Turn speech into text.** Local models transcribe the speech in Russian, English, or automatic mixed-language mode. Speaker detection and transcription run one after another to keep memory use manageable.
4. **Clean up overlaps.** Scribe removes matching passages recognized at overlapping times, including meeting audio picked up again by the microphone. It keeps the meeting track’s speaker-labeled copy and preserves words that do not match. Short replies and phrases repeated later are kept.
5. **Review.** The transcript appears with speaker labels and timestamps. Listen, assign names to speakers, edit the text, and export it. Overlapping voices may need manual correction.

Overlap cleanup runs during transcription. To apply it to an older recording, use **Transcribe Again**; this replaces the transcript and its manual edits after confirmation. Saved audio tracks remain available.

## Audio storage

Scribe captures uncompressed audio so a recording is saved immediately. After the first successful transcription, it compresses each track locally to **AAC in an M4A file, 32 kb/s mono at 16 kHz**. If the models are not installed, compression runs after recording or importing instead. Microphone and meeting audio stay separate and synchronized. Playback and future transcription can read the compressed files directly.

This is lossy speech compression: it can slightly change the sound. The nominal audio data is about **14 MB per hour per track**, compared with about 230 MB for the uncompressed track; container overhead adds a little. Scribe checks the full compressed file and its sample count before removing the larger original. If compression fails or does not save space, the original is kept.

Existing recordings remain unchanged until you choose **Compress Audio** in the recording’s actions menu or context menu, or successfully transcribe them again. Their transcripts and speaker names are preserved.

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

The `ScribeCore` target contains database persistence and transcript algorithms. The `Scribe` target contains audio services, the app coordinator, and native views. Library, recording-detail, and transcript views live in separate files. Live recording meters and playback highlighting have their own observable state so frequent audio updates do not refresh the entire library.

[SwiftUI](https://developer.apple.com/xcode/swiftui/), [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) for speech recognition, [FluidAudio](https://github.com/FluidInference/FluidAudio) for speaker detection.

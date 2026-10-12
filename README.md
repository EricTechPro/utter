# Utter

Voice typing for macOS that runs on your own Mac. Press a key, talk, and your words are typed
into whatever app you're using. It also takes live meeting notes.

Speech is turned into text locally with [whisper.cpp](https://github.com/ggml-org/whisper.cpp)
and OpenAI's open Whisper model. Your voice is not sent to the internet.

## What it does

- **Dictate anywhere.** Click into a text box, press **Option+1**, talk, press **Option+1** again.
  A small pill shows it's listening (✕ or Esc cancels, ✓ finishes). Drag it to the middle of any
  screen edge; it snaps there and stays on every Space, full-screen apps included.
- **Meeting notes.** A small dock (left edge by default, drag it to any edge) starts a live
  transcript that hears you (microphone) and the other people (the Mac's audio), labelled
  **You** and **Others**. You start it yourself; it's greyed out while you dictate.
- **Menu bar.** Click the mic icon at the top of the screen for a panel with **History**
  (search, copy, play, delete with Undo), **Notes** (your meetings) and **Settings**.
  Right-click it for a short menu. The icon turns red while recording.
- **Opens at login** (switch it off in Settings). Utter lives in the menu bar; turn on
  **Show in Dock** in Settings if you also want a Dock icon.
- **Calendar card.** A few minutes before a calendar event with a Meet, Zoom, Teams or Webex
  link, a card offers to join it or start notes.
- **Setup walkthrough** on first launch for every permission it needs.

## Download

Get the latest files from the [Releases page](../../releases/latest):

| Device | File | How to install |
|---|---|---|
| Mac (Apple silicon, macOS 13+) | `Utter-macOS.zip` | Unzip, drag **Utter** to Applications. The first time, right-click it → **Open** → **Open** (the app isn't notarized by Apple). |
| Android 8+ | `Utter-Android.apk` | Open the file on your phone and allow installing from that app. Then open Utter and follow the three setup steps. |

**iPhone / iPad:** not available. iOS doesn't let apps show a floating button over other apps.

## Build and install from source (macOS 13+)

```sh
brew install cmake        # whisper.cpp is built from source and linked into the app
mkdir -p models
curl -L -o models/ggml-large-v3-turbo-q5_0.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin

./scripts/make-cert.sh   # once: a local signing identity, so macOS keeps permissions across rebuilds
./build.sh               # builds and installs /Applications/Utter.app
```

Utter asks for **Microphone** and **Accessibility** (for the shortcut and for pasting).
**Screen Recording** is optional and only used so meeting notes can hear the other people.

History and audio are stored in `~/Library/Application Support/Utter`.

## How text gets typed in

Utter saves your clipboard, puts the text on it, sends Cmd+V to the front app, then puts your
old clipboard back half a second later. It skips password fields (secure input).

## Android

`android/` has the Android version. While the keyboard is up in any app, a small dark mic button
with a red ring floats on the screen. Tap it and Utter records like a voice recorder: the screen can
go off and you can switch apps (a "Recording" notification keeps it going, with a Stop button).
Tap ✓ to stop, or it stops by itself at 10 minutes; the words are typed into the text box that is
selected when they're ready, or copied to the clipboard with a Copy pop-up if there isn't one.
✕ discards.

Speech is turned into text on the phone with whisper.cpp (the same engine as the Mac app), using
the multilingual base model. It handles English, Chinese, and both mixed in one sentence. Audio is
transcribed in short chunks while you talk, so the text is ready a moment after you stop.

Setup has three steps in the app: allow the microphone and notifications, turn on Utter in
Accessibility, and download the voice model once (about 60 MB). After that nothing leaves the phone.
The app also shows your history (copy, delete with undo) and any unfinished recordings: if the phone
restarts or transcription fails, the audio is kept and can be retried.

Sideloaded apps on Android 13+ must allow "restricted settings" before the Accessibility switch
works: Settings → Apps → Utter → ⋮ → **Allow restricted settings**.

```sh
git submodule update --init android/app/src/main/cpp/whisper.cpp   # whisper.cpp source
cd android && ./gradlew assembleRelease   # needs JDK 17, the Android SDK, NDK 27.2 and CMake 3.31.5
```

To make both download files: `./scripts/package-release.sh` (outputs to `dist/`).

## Credits and licenses

- Utter is released under the MIT License (see `LICENSE`).
- [whisper.cpp](https://github.com/ggml-org/whisper.cpp): MIT License.
- [Whisper](https://github.com/openai/whisper) model weights by OpenAI: MIT License.
- Fonts [Figtree](https://github.com/erikdkennedy/figtree) and
  [EB Garamond](https://github.com/octaviopardo/EBGaramond12): SIL Open Font License 1.1
  (license texts in `Resources/Fonts`).

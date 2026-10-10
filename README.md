# Utter

Voice typing for macOS that runs on your own Mac. Press a key, talk, and your words are typed
into whatever app you're using. It also takes live meeting notes.

Speech is turned into text locally with [whisper.cpp](https://github.com/ggml-org/whisper.cpp)
and OpenAI's open Whisper model. Your voice is not sent to the internet.

## What it does

- **Dictate anywhere.** Click into a text box, press **Option+1**, talk, press **Option+1** again.
  A small pill at the bottom of the screen shows it's listening (✕ or Esc cancels, ✓ finishes).
- **Meeting notes.** A dock on the left edge of the screen starts a live transcript that hears
  you (microphone) and the other people (the Mac's audio), labelled **You** and **Others**.
- **History.** The main window lists past dictations and meetings: play the audio, copy the text,
  see word counts.
- **Setup walkthrough** on first launch for every permission it needs.

## Download

Get the latest files from the [Releases page](../../releases/latest):

| Device | File | How to install |
|---|---|---|
| Mac (Apple silicon, macOS 13+) | `Utter-macOS.zip` | Unzip, drag **Utter** to Applications. The first time, right-click it → **Open** → **Open** (the app isn't notarized by Apple). |
| Android 8+ | `Utter-Android.apk` | Open the file on your phone and allow installing from that app. Then open Utter and follow the two setup steps. |

**iPhone / iPad:** not available. iOS doesn't let apps show a floating button over other apps.

## Build and install from source (macOS 13+)

```sh
brew install whisper-cpp
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

`android/` has the Android version: a small blue button appears when you tap a text box;
tap it, talk, and the words are typed in (✕ discards, ✓ keeps). It uses an Accessibility service
and Android's built-in speech recognizer, which runs on the phone when the offline language pack
is installed and otherwise uses Google's servers.

Sideloaded apps on Android 13+ must allow "restricted settings" before the Accessibility switch
works: Settings → Apps → Utter → ⋮ → **Allow restricted settings**.

```sh
cd android && ./gradlew assembleRelease   # needs JDK 17 and the Android SDK
```

To make both download files: `./scripts/package-release.sh` (outputs to `dist/`).

## Credits and licenses

- Utter is released under the MIT License (see `LICENSE`).
- [whisper.cpp](https://github.com/ggml-org/whisper.cpp): MIT License.
- [Whisper](https://github.com/openai/whisper) model weights by OpenAI: MIT License.
- Fonts [Figtree](https://github.com/erikdkennedy/figtree) and
  [EB Garamond](https://github.com/octaviopardo/EBGaramond12): SIL Open Font License 1.1
  (license texts in `Resources/Fonts`).

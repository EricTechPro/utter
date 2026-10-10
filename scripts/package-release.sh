#!/bin/zsh
# Makes the download files in dist/: Utter-macOS.zip and Utter-Android.apk.
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p dist

[[ -x build/whisper-cli ]] || ./scripts/build-whisper.sh
./build.sh
# Re-sign ad-hoc so the download isn't tied to this Mac's local signing identity.
rm -rf dist/Utter.app && ditto build/Utter.app dist/Utter.app
codesign --force --deep --sign - dist/Utter.app
(cd dist && rm -f Utter-macOS.zip && ditto -c -k --keepParent Utter.app Utter-macOS.zip && rm -rf Utter.app)

(cd android && JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk@17} ./gradlew assembleRelease -q)
cp android/app/build/outputs/apk/release/app-release.apk dist/Utter-Android.apk

ls -lh dist

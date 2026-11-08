#!/bin/zsh
# Build the plain (unpatched) simulator app and print its size.
set -e
cd "${0:a:h}"
APP=build/sim/a.app
rm -rf "$APP"; mkdir -p "$APP"
SDK=$(xcrun --show-sdk-path --sdk iphonesimulator)
clang -target arm64-apple-ios15.0-simulator -isysroot "$SDK" -Oz \
  -fno-unwind-tables -fno-asynchronous-unwind-tables \
  -framework UIKit -lobjc -Wl,-dead_strip -Wl,-x \
  -o "$APP/a" main.c
strip -x "$APP/a"
plutil -convert binary1 -o "$APP/Info.plist" Info.plist
codesign -f -s - "$APP" 2>/dev/null
ls -l "$APP/a" "$APP/Info.plist"

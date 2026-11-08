#!/bin/zsh
# Build the simulator app with a zero-fill __DATA_CONST and print its size.
set -e
cd "${0:a:h}"
APP=build/tiny_sim/a.app
rm -rf "$APP"; mkdir -p "$APP" build/obj
SDK=$(xcrun --show-sdk-path --sdk iphonesimulator)
clang -target arm64-apple-ios15.0-simulator -isysroot "$SDK" -Oz \
  -fno-unwind-tables -fno-asynchronous-unwind-tables \
  -framework UIKit -lobjc -Wl,-dead_strip -Wl,-x \
  -Wl,-no_fixup_chains -Wl,-no_adhoc_codesign \
  -Wl,-no_function_starts -Wl,-no_data_in_code_info -Wl,-no_source_version \
  -o build/obj/a.linked main.c
strip -x build/obj/a.linked
python3 -I shrink.py build/obj/a.linked "$APP/a"
chmod +x "$APP/a"
plutil -convert binary1 -o "$APP/Info.plist" Info.plist
codesign -f -s - "$APP/a"
ls -l "$APP/a"

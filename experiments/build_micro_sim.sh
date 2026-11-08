#!/bin/zsh
# Experimental: simulator build whose whole file fits inside one 16 KB page.
set -e
cd "${0:a:h}"
APP=build/micro_sim/a.app
rm -rf "$APP"; mkdir -p "$APP" build/obj
SDK=$(xcrun --show-sdk-path --sdk iphonesimulator)
# Trailing zeros in __TEXT push the code to the start of the page; shrink.py drops them.
head -c 13900 /dev/zero > build/obj/pad.bin
clang -target arm64-apple-ios15.0-simulator -isysroot "$SDK" -Oz \
  -fno-unwind-tables -fno-asynchronous-unwind-tables \
  -framework UIKit -lobjc -Wl,-dead_strip -Wl,-x \
  -Wl,-no_fixup_chains -Wl,-no_adhoc_codesign \
  -Wl,-no_function_starts -Wl,-no_data_in_code_info -Wl,-no_source_version \
  -Wl,-sectcreate,__TEXT,__pad,build/obj/pad.bin \
  -o build/obj/a.micro.linked main.c
strip -x build/obj/a.micro.linked
python3 -I shrink.py build/obj/a.micro.linked "$APP/a" --overlap
chmod +x "$APP/a"
plutil -convert binary1 -o "$APP/Info.plist" Info.plist
codesign -f -s - "$APP/a"
ls -l "$APP/a"

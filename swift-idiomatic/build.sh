#!/bin/zsh
# usage: swift-idiomatic/build.sh sim|dev [test]    Output: build/idiomatic-<target>[-test]/
# Standard release settings (-O, whole-module, dead stripping, symbols stripped). No size-only flags.
# Same bundle layout, Info.plist and zip command as tools/build.sh, so sizes compare directly.
set -e
cd "${0:a:h}/.."
TARGET=$1; TEST=""; [[ $2 == test ]] && TEST=1
OUT=build/idiomatic-$TARGET${TEST:+-test}; APP=$OUT/Thimble.app
rm -rf "$OUT"; mkdir -p "$APP"
if [[ $TARGET == sim ]]; then TRIPLE=arm64-apple-ios18.0-simulator; SDK=iphonesimulator; else TRIPLE=arm64-apple-ios18.0; SDK=iphoneos; fi
SYS=$(xcrun --show-sdk-path --sdk $SDK)
FLAGS=(-target $TRIPLE -sdk "$SYS" -module-name Thimble -parse-as-library -wmo ${=OPT:--O} -swift-version 5 -gnone -Xlinker -dead_strip -Xlinker -x)
OBJS=()
if [[ -n $TEST ]]; then
  clang -c -target $TRIPLE -isysroot "$SYS" -fblocks -fno-objc-arc -w -o $OUT/test.o runtime/test.m
  OBJS=($OUT/test.o); FLAGS+=(-D TEST -import-objc-header swift/test.h -framework CoreGraphics)
fi
[[ $TARGET == sim ]] && FLAGS+=(-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __entitlements -Xlinker tests/sim.entitlements)
xcrun swiftc $FLAGS -o "$APP/a" swift-idiomatic/Thimble/**/*.swift $OBJS
strip -x "$APP/a" 2>/dev/null || true
plutil -convert binary1 -o "$APP/Info.plist" app/Info.plist
codesign -f -s - "$APP" 2>/dev/null
(cd "$OUT" && rm -f app.zip && zip -qr9X app.zip Thimble.app -x '*/_CodeSignature/*')
echo "idiomatic $TARGET: Mach-O $(stat -f %z $APP/a)  zip $(stat -f %z $OUT/app.zip)"

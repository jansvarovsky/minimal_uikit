#!/bin/zsh
# usage: build.sh vm|c sim|dev [test] [file.tl ...]   (default: all of app/)
set -e
cd "${0:a:h}/.."
MODE=$1 TARGET=$2; shift 2
TEST=""; if [[ "$1" == test ]]; then TEST=1; shift; fi
FILES=("$@"); (( $#FILES )) || FILES=(app/*.tl)
OUT=build/$MODE-$TARGET${TEST:+-test}; GEN=$OUT/gen; APP=$OUT/Thimble.app
rm -rf "$OUT"; mkdir -p "$GEN" "$APP"
python3 -I tools/tlc.py "$GEN" $FILES
if [[ $TARGET == sim ]]; then TRIPLE=arm64-apple-ios18.0-simulator; SDK=iphonesimulator; else TRIPLE=arm64-apple-ios18.0; SDK=iphoneos; fi
SYS=$(xcrun --show-sdk-path --sdk $SDK)
# Every declared Objective-C signature is checked against the real SDK.
clang -x objective-c -fsyntax-only -target $TRIPLE -isysroot "$SYS" -Wno-deprecated-declarations -Wno-unguarded-availability-new \
  -Werror=objc-method-access -Werror=incompatible-pointer-types -Werror=int-conversion -Werror=float-conversion -Werror=implicit-int-float-conversion "$GEN/check.m"
DEF=(); [[ $MODE == vm ]] && DEF+=(-DVM)
SRC=(runtime/host.c)
if [[ -n $TEST ]]; then DEF+=(-DTEST); SRC+=(runtime/test.m); LINKX=(-framework CoreGraphics); fi
clang -target $TRIPLE -isysroot "$SYS" -Oz -fno-unwind-tables -fno-asynchronous-unwind-tables -fblocks -fno-objc-arc \
  -w -I"$GEN" $DEF -framework UIKit -framework Foundation -framework Security -framework AVKit -framework AVFoundation \
  -framework PhotosUI -framework AuthenticationServices -lcompression -lobjc $LINKX -Wl,-dead_strip -Wl,-x -o "$APP/a" $SRC
strip -x "$APP/a" 2>/dev/null || true
plutil -convert binary1 -o "$APP/Info.plist" app/Info.plist
codesign -f -s - "$APP" 2>/dev/null
(cd "$OUT" && rm -f app.zip && zip -qr9X app.zip Thimble.app -x '*/_CodeSignature/*')
echo "$MODE $TARGET: Mach-O $(stat -f %z $APP/a)  zip $(stat -f %z $OUT/app.zip)"

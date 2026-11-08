#!/bin/zsh
# Build signed device apps (standard and zero-fill __DATA_CONST) and print sizes.
#
# WARNING: the only profile covering the phone is for an existing app's bundle ID.
# Installing these builds would REPLACE that app. They are for measurement only.
set -e
cd "${0:a:h}"
PROFILE="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/220a8ea2-9e9a-412c-a849-d9fced2222ac.mobileprovision"
BUNDLE_ID=com.svarovsky-productions.justthemorning
TEAM=45EA3X87QM
SDK=$(xcrun --show-sdk-path --sdk iphoneos)
mkdir -p build/obj

# Pick the keychain identity whose certificate is listed in the profile.
security cms -D -i "$PROFILE" > build/obj/profile.plist
IDENTITY=$(python3 -I - <<'E'
import hashlib, plistlib, subprocess
certs = plistlib.load(open("build/obj/profile.plist", "rb"))["DeveloperCertificates"]
wanted = {hashlib.sha1(c).hexdigest().upper() for c in certs}
out = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"], capture_output=True, text=True).stdout
print(next(line.split()[1] for line in out.splitlines() if ")" in line and len(line.split()) > 1 and line.split()[1] in wanted))
E
)

cat > build/obj/ent.plist <<E
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>application-identifier</key><string>$TEAM.$BUNDLE_ID</string>
<key>com.apple.developer.team-identifier</key><string>$TEAM</string>
<key>get-task-allow</key><true/>
</dict></plist>
E

COMMON=($=EXTRA_CFLAGS -target arm64-apple-ios15.0 -isysroot "$SDK" -Oz
  -fno-unwind-tables -fno-asynchronous-unwind-tables
  -framework UIKit -lobjc -Wl,-dead_strip -Wl,-x)

# Extra codesign options for the patched build (reservation just above the CMS blob size).
SIGN_TINY=(--signature-size ${SIGSIZE:-4830} -P ${PAGESIZE:-16384})

package() { # name [codesign options...]
  local app=build/device/$1/a.app name=$1; shift
  plutil -convert binary1 -o "$app/Info.plist" build/obj/Info.device.plist
  cp "$PROFILE" "$app/embedded.mobileprovision"
  codesign -f -s "$IDENTITY" --entitlements build/obj/ent.plist --timestamp=none "$@" "$app"
  (cd build/device/$name && rm -rf Payload x.ipa && mkdir Payload && cp -R a.app Payload/ && zip -qr9X x.ipa Payload && rm -rf Payload)
  print "$name: Mach-O $(stat -f %z $app/a)  profile $(stat -f %z $app/embedded.mobileprovision)  .app files $(find $app -type f -exec stat -f %z {} + | paste -sd+ - | bc)  ipa $(stat -f %z build/device/$name/x.ipa)"
}

sed "s/org.svarovsky.tiny/$BUNDLE_ID/" Info.plist > build/obj/Info.device.plist
rm -rf build/device; mkdir -p build/device/standard/a.app build/device/zerofill/a.app

clang $COMMON -o build/device/standard/a.app/a main.c
strip -x build/device/standard/a.app/a
package standard

clang $COMMON -Wl,-no_encryption -Wl,-no_fixup_chains -Wl,-no_adhoc_codesign \
  -Wl,-no_function_starts -Wl,-no_data_in_code_info -Wl,-no_source_version \
  -o build/obj/a.device.linked main.c
strip -x build/obj/a.device.linked
python3 -I shrink.py build/obj/a.device.linked build/device/zerofill/a.app/a
chmod +x build/device/zerofill/a.app/a
package zerofill $SIGN_TINY

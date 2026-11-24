#!/bin/zsh
# Builds a signed development .app and .ipa for the paired phone.
# WARNING: the only profile covering that phone is an existing app's. Installing replaces that app.
set -e
cd "${0:a:h}/.."
PROFILE="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/220a8ea2-9e9a-412c-a849-d9fced2222ac.mobileprovision"
BUNDLE_ID=com.svarovsky-productions.justthemorning TEAM=45EA3X87QM
zsh swift-idiomatic/build.sh dev | tail -1
OUT=build/idiomatic-device; APP=$OUT/Thimble.app
rm -rf $OUT; mkdir -p $OUT; cp -R build/idiomatic-dev/Thimble.app $APP; rm -rf $APP/_CodeSignature
security cms -D -i "$PROFILE" > $OUT/profile.plist
IDENTITY=$(python3 -I - $OUT/profile.plist <<'P'
import hashlib, plistlib, subprocess, sys
wanted = {hashlib.sha1(c).hexdigest().upper() for c in plistlib.load(open(sys.argv[1], "rb"))["DeveloperCertificates"]}
out = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"], capture_output=True, text=True).stdout
print(next(l.split()[1] for l in out.splitlines() if ")" in l and len(l.split()) > 1 and l.split()[1] in wanted))
P
)
cat > $OUT/ent.plist <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>application-identifier</key><string>$TEAM.$BUNDLE_ID</string>
<key>com.apple.developer.team-identifier</key><string>$TEAM</string>
<key>get-task-allow</key><true/>
</dict></plist>
P
plutil -replace CFBundleIdentifier -string $BUNDLE_ID $APP/Info.plist
cp "$PROFILE" $APP/embedded.mobileprovision
codesign -f -s "$IDENTITY" --entitlements $OUT/ent.plist --timestamp=none --signature-size 4830 -P 16384 $APP
codesign --verify --strict $APP && echo "signature verifies"
(cd $OUT && mkdir Payload && cp -R Thimble.app Payload/ && zip -qr9X Thimble.ipa Payload && rm -rf Payload)
for f in a Info.plist embedded.mobileprovision _CodeSignature/CodeResources; do print "$(stat -f %z $APP/$f) $f"; done
print "$(stat -f %z $OUT/Thimble.ipa) Thimble.ipa"
print "$(find $APP -type f -exec stat -f %z {} + | paste -sd+ - | bc) total .app"

#!/bin/zsh
# Runs the real OAuth sign-in through the system web sheet. Uses account A from the local credentials file.
cd "${0:a:h}/.."
U=FBBC75B3-B081-4731-83C9-4DA917838361
xcrun simctl terminate $U org.svarovsky.thimble 2>/dev/null; xcrun simctl uninstall $U org.svarovsky.thimble 2>/dev/null
xcrun simctl keychain $U reset
xcrun simctl install $U build/idiomatic-sim-test/Thimble.app || exit 2
set -a; source ~/.config/tinysky/credentials; set +a
export TEST_RUNNER_A_HANDLE="$TINYSKY_A_HANDLE" TEST_RUNNER_A_PASSWORD="$TINYSKY_A_PASSWORD" TEST_RUNNER_A_APP_PASSWORD="$TINYSKY_A_APP_PASSWORD"
rm -rf build/ui.xcresult
cd tests/ui && xcodebuild test ${ONLY:+-only-testing:UITests/$ONLY} -project UI.xcodeproj -scheme UITests -destination "id=$U" -derivedDataPath ../../build/ui -resultBundlePath ../../build/ui.xcresult 2>&1 | grep -E 'LABELS|error:|\*\* TEST|Executed|XCTAssert|failed|passed' | grep -v "$TINYSKY_A_PASSWORD" | grep -v "$TINYSKY_A_APP_PASSWORD" | cut -c1-1800 | tail -14

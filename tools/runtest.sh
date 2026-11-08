#!/bin/zsh
# usage: runtest.sh vm|c script.txt   Runs a scripted UI test in the simulator. Credentials come from the local file.
cd "${0:a:h}/.."
U=FBBC75B3-B081-4731-83C9-4DA917838361
MODE=$1 SCRIPT=${2:a}
OUT=${PWD}/build/results/${${SCRIPT:t}:r}; rm -rf "$OUT"; mkdir -p "$OUT"
APP=build/$MODE-sim-test/Thimble.app
xcrun simctl boot $U 2>/dev/null; xcrun simctl bootstatus $U -b >/dev/null 2>&1
xcrun simctl terminate $U org.svarovsky.thimble 2>/dev/null
[[ -z $KEEP ]] && xcrun simctl uninstall $U org.svarovsky.thimble 2>/dev/null
xcrun simctl install $U $APP || exit 2
set -a; source ~/.config/tinysky/credentials; set +a
for v in ${(k)parameters[(R)*export*]}; do [[ $v == TINYSKY_* ]] && export SIMCTL_CHILD_$v="${(P)v}"; done
export SIMCTL_CHILD_TS_SCRIPT="$SCRIPT" SIMCTL_CHILD_TS_OUT="$OUT"
xcrun simctl launch $U org.svarovsky.thimble >/dev/null || exit 3
for i in {1..${LIMIT:-600}}; do
  if grep -qE '^(DONE|FAIL)' "$OUT/log.txt" 2>/dev/null; then break; fi
  python3 -I -c 'import time;time.sleep(0.5)'
done
grep -vE '^ok ' "$OUT/log.txt" 2>/dev/null | cut -c1-1500; grep -q '^DONE' "$OUT/log.txt" 2>/dev/null

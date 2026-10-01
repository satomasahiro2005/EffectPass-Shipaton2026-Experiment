#!/bin/bash
# EffectPass のデモ動画を、人の手なしで録る（Tests/UI/DemoWalkthroughUITests.swift を走らせながら画面を録画する）。
#
#   bash Scripts/record_demo.sh            プロジェクトを作り、建て、入れ直し、録画しながらテストを走らせる
#   BUILD_ONLY=1 bash Scripts/record_demo.sh   建てるだけ（build-for-testing まで。録画しない）
#   SKIP_PROJECT=1 bash Scripts/record_demo.sh 前回作った EffeTuneLiveSim.xcodeproj をそのまま使う
#
# **Mac では osascript 経由で GUI の Terminal から走らせる**（sshから xcodebuild を直接叩くと
# errSecInternalComponent で落ちる）。例:
#   ssh <user>@<mac> 'osascript -e "tell application \"Terminal\" to do script \"bash ~/work/effectpass/Scripts/record_demo.sh\""'
#
# 使う端末は、すでに起きている iPad Pro 13-inch (M5) だけ（何も新しく起こさない。Scripts/lib/sim.sh）。
# 起きていなければ止まる。アプリは先に消す（RevenueCat の匿名ユーザーを新しくするため）。
# 建てる時間を動画に入れないよう、build-for-testing と test-without-building を分ける。
#
# 全出力は ~/work/effectpass/demo-run.log。動画は ~/work/effectpass-demo.mp4（OUT で変えられる）。
# 場面ごとの全画面の静止画は build/demo-shots/*.png（SHOTS で変えられる）。
# 判定は demo-run.log の "** TEST SUCCEEDED **" と、末尾の "=== DEMO SCRIPT FINISHED (exit=N) ==="。
# テストは ET_DEMO=1 が無いと自分で skip するので、TEST_RUNNER_ET_DEMO=1 を xcodebuild へ渡す。
set -u
export PATH="/opt/homebrew/bin:$PATH"
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
# shellcheck source=Scripts/lib/sim.sh
. Scripts/lib/sim.sh
LOG="$ROOT/demo-run.log"
RESULT="$ROOT/build/DemoUITest.xcresult"
OUT="${OUT:-$HOME/work/effectpass-demo.mp4}"
TEST="EffeTuneLiveUITests/DemoWalkthroughUITests/testDemoWalkthrough"
REC_PID=""

say() {
  echo "$*"
  echo "$*" >> "$LOG"
}

stop_recording() {
  [ -n "$REC_PID" ] || return 0
  kill -INT "$REC_PID" 2>/dev/null
  # simctl は SIGINT を受けると mp4 を閉じてから終わる。終わるのを待つ。
  local n=0
  while kill -0 "$REC_PID" 2>/dev/null && [ "$n" -lt 60 ]; do
    sleep 1
    n=$((n + 1))
  done
  if kill -0 "$REC_PID" 2>/dev/null; then
    say "!! 録画が 60 秒たっても閉じない。強制終了する（mp4 は壊れているかもしれない）"
    kill -TERM "$REC_PID" 2>/dev/null
  fi
  wait "$REC_PID" 2>/dev/null
  REC_PID=""
}

finish() {
  stop_recording
  sim_terminate_app
  say "=== DEMO SCRIPT FINISHED (exit=$1) ==="
  exit "$1"
}
trap 'stop_recording' INT TERM

mkdir -p "$ROOT/build"
echo "=== $(date) ===" > "$LOG"

# 画面ロック中でも署名できるように（Scripts/build.sh と同じ流儀）。無ければ飛ばす。
if [ -f "$HOME/signing/kc.pw" ]; then
  security unlock-keychain -p "$(cat "$HOME/signing/kc.pw")" >> "$LOG" 2>&1
fi
# RevenueCat の鍵は追跡しない。Mac の置き場から写す。
if [ -f "$HOME/work/effectpass-secrets/Secrets.xcconfig" ]; then
  cp "$HOME/work/effectpass-secrets/Secrets.xcconfig" Config/Secrets.xcconfig
  say "--- Secrets.xcconfig copied ---"
elif [ ! -f Config/Secrets.xcconfig ]; then
  say "!! Config/Secrets.xcconfig が無い。鍵が無いとアプリは全部開いたままで、課金の場面が録れない"
fi

sim_select || finish 1
say "device: $SIM_NAME ($SIM_UDID)"
# 何も起こさない。起きていなければ止まる。
if ! sim_booted | grep -q "$SIM_UDID"; then
  say "!! $SIM_NAME は起きていない。先に起こしておくこと（このスクリプトは起こさない）"
  finish 1
fi

if [ "${SKIP_PROJECT:-0}" != "1" ]; then
  sim_project "$LOG" || finish 1
fi

ARGS=(-project EffeTuneLiveSim.xcodeproj -scheme EffeTuneLive
      -destination "id=$SIM_UDID"
      -jobs "${BUILD_JOBS:-2}"
      -derivedDataPath "$ROOT/DerivedData"
      -parallel-testing-enabled NO
      -disable-concurrent-destination-testing)

say "--- xcodebuild build-for-testing $(date) ---"
"$ET_XCODEBUILD" "${ARGS[@]}" build-for-testing >> "$LOG" 2>&1
CODE=$?
grep -E "BUILD SUCCEEDED|BUILD FAILED|TEST BUILD SUCCEEDED|TEST BUILD FAILED" "$LOG" | tail -n 1
if [ "$CODE" -ne 0 ]; then
  say "!! build-for-testing が落ちた (exit $CODE)"
  grep "error:" "$LOG" | head -20
  finish 1
fi
if [ "${BUILD_ONLY:-0}" = "1" ]; then
  say "BUILD_ONLY=1 なので録画はしない"
  finish 0
fi

# 新しい匿名ユーザーで始める。
sim_terminate_app
et_quiet xcrun simctl uninstall "$SIM_UDID" "$ET_APPID"
rm -rf "$RESULT"
rm -f "$OUT"

say "--- 録画を始める $(date) ---"
xcrun simctl io "$SIM_UDID" recordVideo --codec h264 --force "$OUT" >> "$LOG" 2>&1 &
REC_PID=$!
sleep 3
if ! kill -0 "$REC_PID" 2>/dev/null; then
  say "!! 録画が始まらない"
  REC_PID=""
  finish 1
fi

say "--- xcodebuild test-without-building $(date) ---"
# -collect-test-diagnostics never: 落ちた後に simctl diagnose で最大 10 分待つのを止める（録画が回り続ける）。
SHOTS="${SHOTS:-$ROOT/build/demo-shots}"
rm -rf "$SHOTS"
TEST_RUNNER_ET_DEMO=1 TEST_RUNNER_ET_SHOTS="$SHOTS" "$ET_XCODEBUILD" "${ARGS[@]}" -resultBundlePath "$RESULT" -collect-test-diagnostics never "-only-testing:$TEST" test-without-building >> "$LOG" 2>&1
CODE=$?
say "--- テスト終了 exit=$CODE $(date) ---"

# 最後の場面を数秒だけ余らせてから止める。
sleep 3
stop_recording

# mp4 の大きさが落ち着くのを待つ。
PREV=-1
for _ in 1 2 3 4 5 6 7 8 9 10; do
  SIZE=$(stat -f %z "$OUT" 2>/dev/null || echo 0)
  [ "$SIZE" = "$PREV" ] && break
  PREV="$SIZE"
  sleep 1
done
say "video: $OUT ($SIZE bytes)"
[ "$SIZE" -gt 0 ] || { say "!! 動画が空"; CODE=1; }

et_test_summary "$LOG" "$CODE" "$RESULT" > "$ROOT/build/demo-summary.txt"
CODE=$?
cat "$ROOT/build/demo-summary.txt"
cat "$ROOT/build/demo-summary.txt" >> "$LOG"
finish "$CODE"

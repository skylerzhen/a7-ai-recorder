#!/usr/bin/env bash
# A7 模拟器开关:  ./emu.sh [up|down|status]
# 自带 source devenv.sh,无需先配 PATH。
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/devenv.sh"

case "${1:-up}" in
  up)
    if adb devices | grep -q "emulator-"; then
      echo "模拟器已在运行:"; adb devices | grep "emulator-"
    else
      echo "启动 AVD a7_test(带窗口)..."
      nohup emulator -avd a7_test -gpu auto >/tmp/a7_emu.log 2>&1 &
      adb wait-for-device
      printf "等待开机"
      until [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do printf "."; sleep 2; done
      echo " ✓ 已开机"
    fi ;;
  down)
    adb emu kill 2>/dev/null && echo "✓ 已关闭模拟器" || echo "没有在运行的模拟器" ;;
  status)
    adb devices ;;
  *)
    echo "用法: ./emu.sh [up|down|status]"; exit 1 ;;
esac

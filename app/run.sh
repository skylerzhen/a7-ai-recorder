#!/usr/bin/env bash
# 运行 a7_recorder(热重载)。需要先有设备:  ./emu.sh up
# 透传额外参数,如 ./run.sh -d emulator-5554
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/devenv.sh"
cd "$DIR/a7_recorder"
exec flutter run "$@"

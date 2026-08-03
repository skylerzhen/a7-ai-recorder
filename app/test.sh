#!/usr/bin/env bash
# 跑全部测试:协议核心(dart test)+ app(flutter test)
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/devenv.sh"
echo "== a7_protocol: dart test =="
( cd "$DIR/a7_protocol" && dart test )
echo "== a7_recorder: flutter test =="
( cd "$DIR/a7_recorder" && flutter test )

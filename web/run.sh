#!/bin/zsh
# 固定 launcher:把 cd 写死,osascript 触发时不会再因目录错而找不到 .venv。
cd /Users/eddie/Desktop/proj/Hospital || exit 1
exec .venv/bin/python "$@"

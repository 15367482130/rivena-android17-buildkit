#!/usr/bin/env bash
#
# 把 mka / m 的日志按"错误类型"归类，只给你最该先看的那几条。
# 老 vendor 树抬新系统时，日志里 90% 的噪音是重复的同一类错误，先分类再看，省几小时。
#
#   ./analyze-build-log.sh out/build-full-1026-1013.log
#   ./analyze-build-log.sh --all out/xxx.log      # 每类最多列 20 条
#
set -uo pipefail

LIMIT=5
[[ "${1:-}" == "--all" ]] && { LIMIT=20; shift; }
LOG="${1:-}"
[[ -f "$LOG" ]] || { echo "用法: $0 [--all] <build.log>"; exit 1; }

c_r=$'\033[31m'; c_y=$'\033[33m'; c_g=$'\033[32m'; c_b=$'\033[36m'; c_0=$'\033[0m'
total=$(wc -l < "$LOG")

# 顺序 = 建议的关注优先级
declare -a NAMES=(
  "soong-config|Unknown soong config|soong config namespace|soong_config_variable"
  "missing-module|depends on undefined module|module .* not found|is not a valid module|unknown module"
  "sepolicy|neverallow|libsepol|SELinux policy"
  "vintf|checkvintf|VINTF|compatibility matrix|manifest fragment"
  "java|error: cannot find symbol|javac|\\[javac\\]|error: package .* does not exist"
  "native|error: use of undeclared identifier|error: no matching (function|constructor)|fatal error: .*No such file"
  "link|undefined reference to|ld: error|ld.lld: error"
  "ninja|ninja: build stopped|FAILED:"
  "generic|^.*error:" 
)

echo "${c_b}== 日志分析: $LOG ==="
echo "   $total 行${c_0}"
echo

for row in "${NAMES[@]}"; do
  name="${row%%|*}"; pat="${row#*|}"
  mapfile -t hits < <(grep -E -i "$pat" "$LOG" 2>/dev/null | grep -v "^--" | head -200)
  n=${#hits[@]}
  (( n == 0 )) && continue
  printf '%s%-15s %s 条%s\n' "$c_y" "$name" "$n" "$c_0"
  for ((i=0; i<n && i<LIMIT; i++)); do
    printf '   %s\n' "$(echo "${hits[$i]}" | cut -c1-160)"
  done
  (( n > LIMIT )) && echo "   … 还有 $((n-LIMIT)) 条（--all 展开）"
  echo
done

echo "${c_g}== 建议 =="
echo "1. soong-config / missing-module 优先修 —— 它们是配置层，一个错误会连带几千个编译失败"
echo "2. sepolicy 单独跑 'm sepolicy'，配合 tools/avc2sepolicy.py 生成规则草稿"
echo "3. native/link 错误数量通常只有几处，但会刷屏；按文件去重后再看"
echo "4. 修完一类就重跑，不要一次改十个地方${c_0}"

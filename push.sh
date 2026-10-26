#!/usr/bin/env bash
#
# 把两棵设备树推到你的 GitHub（需要 GITHUB_TOKEN，或有 gh 登录态）
#   用法: GITHUB_TOKEN=xxx ./push.sh <你的GitHub用户名>
#   例:   GITHUB_TOKEN=ghp_... ./push.sh eryd
#
set -euo pipefail

OWNER="${1:-}"
[[ -z "$OWNER" ]] && { echo "用法: GITHUB_TOKEN=xxx ./push.sh <GitHub用户名>"; exit 1; }
[[ -z "${GITHUB_TOKEN:-}" ]] && { echo "缺 GITHUB_TOKEN 环境变量"; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

api() { curl -sS -H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" "$@"; }

create_repo() { # $1=仓库名 $2=描述
  local name="$1" desc="$2"
  code=$(api -o /dev/null -w '%{http_code}' "https://api.github.com/repos/${OWNER}/${name}")
  if [[ "$code" == "200" ]]; then
    echo "  仓库已存在: ${OWNER}/${name}"
  else
    api -o /dev/null -w '  创建 %{http_code}\n' -X POST https://api.github.com/user/repos \
      -d "{\"name\":\"${name}\",\"description\":\"${desc}\",\"private\":false,\"has_issues\":true}"
  fi
}

push_tree() { # $1=仓库名 $2=tar.gz $3=描述
  local name="$1" tarball="$2" desc="$3"
  echo "== ${name}"
  create_repo "$name" "$desc"
  tar xzf "$HERE/$tarball" -C "$WORK"
  local dir="$WORK/${tarball%%-lineage-*}"
  git -C "$dir" remote set-url origin "https://oauth2:${GITHUB_TOKEN}@github.com/${OWNER}/${name}.git" 2>/dev/null \
    || git -C "$dir" remote add origin "https://oauth2:${GITHUB_TOKEN}@github.com/${OWNER}/${name}.git"
  git -C "$dir" push -q origin lineage-23.2 lineage-24.0
  git -C "$dir" push -q origin --tags || true
  echo "  ✔ https://github.com/${OWNER}/${name}"
}

push_tree "android_device_realme_rivena" "rivena-lineage-24.0.tar.gz" \
  "LineageOS device tree for realme GT Master Explorer Edition (RMX3366 / rivena) - Android 17 bring-up"
push_tree "android_device_oppo_sm8250-common" "sm8250-common-lineage-24.0.tar.gz" \
  "Common device tree for OPPO/realme SM8250 (kona) - Android 17 bring-up"

echo
echo "完成。两个仓库都是公开的，默认分支请到 GitHub 设置里改成 lineage-24.0（或保留 lineage-23.2）。"

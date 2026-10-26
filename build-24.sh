#!/usr/bin/env bash
#
# rivena / LineageOS 24.0 (Android 17) 构建脚本
# 与 build.sh（Android 16 用）的区别：用 rivena-24.0.xml 清单，并强制分阶段编译，
# 先把配置层和 sepolicy 过掉，再打整包 —— 老 vendor 树硬抬新版本，一把梭 brunch 只会淹死在海量报错里。
#
#   ./build-24.sh --check                 # 预检：分支、磁盘、内存
#   ./build-24.sh --install-deps          # 装依赖 + 全流程
#   ./build-24.sh --stage config          # 只跑 m nothing
#   ./build-24.sh --stage sepolicy
#   ./build-24.sh --stage boot
#   ./build-24.sh --stage full            # mka bacon
#
set -euo pipefail

BRANCH="lineage-24.0"
DEVICE="rivena"
SRC_DIR="${HOME}/android/${DEVICE}-24"
JOBS="$(nproc)"
STAGE="full"
DO_SYNC=1
DO_DEPS=0
CHECK_ONLY=0
GH_PROXY="${GH_PROXY:-}"

LOS_MANIFEST="https://mirrors.tuna.tsinghua.edu.cn/git/lineageOS/LineageOS/android.git"
REPO_URL="https://mirrors.tuna.tsinghua.edu.cn/git/git-repo"
AOSP_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/git/AOSP"
AOSP_UPSTREAM="https://android.googlesource.com"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

c_r=$'\033[31m'; c_g=$'\033[32m'; c_y=$'\033[33m'; c_b=$'\033[36m'; c_0=$'\033[0m'
log()  { printf '%s[%s]%s %s\n' "$c_b" "$(date +%H:%M:%S)" "$c_0" "$*"; }
ok()   { printf '%s  ✔%s %s\n' "$c_g" "$c_0" "$*"; }
warn() { printf '%s  !%s %s\n' "$c_y" "$c_0" "$*"; }
die()  { printf '%s  ✘ %s%s\n' "$c_r" "$*" "$c_0" >&2; exit 1; }

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--dir)        SRC_DIR="$2"; shift 2 ;;
    -j|--jobs)       JOBS="$2"; shift 2 ;;
    -s|--stage)      STAGE="$2"; shift 2 ;;
    --no-sync)       DO_SYNC=0; shift ;;
    --install-deps)  DO_DEPS=1; shift ;;
    --gh-proxy)      GH_PROXY="$2"; shift 2 ;;
    --check)         CHECK_ONLY=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
done

deps() {
  local gh="https://github.com/15367482130"
  local gl="https://gitlab.com/RMX3366-Development"
  [[ -n "$GH_PROXY" ]] && gh="${GH_PROXY}/https://github.com/15367482130"
  cat <<EOF
机型树|${gh}/android_device_realme_rivena.git|lineage-24.0
公共树|${gh}/android_device_oppo_sm8250-common.git|lineage-24.0
内核|${gh}/android_kernel_realme_sm8250.git|lineage-24.0
hardware/oplus|${gh}/android_hardware_oplus.git|lineage-24.0
Dolby|https://github.com/RMX3366-Development/android_hardware_dolby.git|16
vendor 设备|${gl}/proprietary_vendor_realme_rivena.git|lineage-23.2
vendor 公共|${gl}/proprietary_vendor_oppo_sm8250-common.git|lineage-24.0
vendor 相机|https://gitlab.com/ermyltsor/proprietary_vendor_oplus_camera.git|lineage-23.1
EOF
}

# GitHub 直连国内经常超时，失败后自动走一遍代理再试
refs_of() {
  local url="$1" out
  out="$(GIT_TERMINAL_PROMPT=0 timeout 25 git ls-remote --heads "$url" 2>/dev/null | awk '{print $2}' | sed 's#refs/heads/##' | tr '\n' ' ' || true)"
  if [[ -z "$out" && "$url" == https://github.com/* ]]; then
    out="$(GIT_TERMINAL_PROMPT=0 timeout 35 git ls-remote --heads "https://ghfast.top/${url}" 2>/dev/null | awk '{print $2}' | sed 's#refs/heads/##' | tr '\n' ' ' || true)"
  fi
  printf '%s' "$out"
}

preflight() {
  log "预检 ${BRANCH} 依赖"
  local missing=0 name url want refs
  while IFS='|' read -r name url want; do
    printf '  %-20s ' "$name"
    refs="$(refs_of "$url")"
    if grep -qw "$want" <<<"$refs"; then printf '%s✔ %s%s\n' "$c_g" "$want" "$c_0"
    else printf '%s✘ 缺 %s（有: %s）%s\n' "$c_r" "$want" "${refs:-取不到}" "$c_0"; missing=$((missing+1)); fi
  done < <(deps)

  local avail mem probe
  probe="$SRC_DIR"; [[ -d "$probe" ]] || probe="$HOME"
  avail=$(df -BG --output=avail "$probe" | tail -1 | tr -dc '0-9' || true)
  mem=$(awk '/MemTotal/{printf "%d",$2/1024/1024}' /proc/meminfo || true)
  echo
  echo "  磁盘 ${avail:-?} GB / 内存 ${mem:-?} GB / 32 核基准"
  [[ "${avail:-0}" -lt 400 ]] && warn "24.0 整树建议 ≥400 GB，当前偏紧，可加 --no-sync 复用已有树"
  [[ $missing -gt 0 ]] && warn "$missing 个仓库缺分支，先补分支再编"
}

install_deps() {
  log "安装编译依赖"
  local S=""; [[ $EUID -ne 0 ]] && S="sudo"
  $S apt-get update -qq
  $S apt-get install -y bc bison build-essential ccache curl erofs-utils flex g++-multilib \
      gcc-multilib git git-lfs gnupg gperf imagemagick kmod protobuf-compiler python3-protobuf \
      lib32readline-dev lib32z1-dev libdw-dev libelf-dev libgnutls28-dev lz4 libsdl1.2-dev \
      libssl-dev libxml2 libxml2-utils lzop pngcrush rsync schedtool squashfs-tools xsltproc \
      xxd zip zlib1g-dev python-is-python3 || warn "部分包装失败，继续"
}

prepare_source() {
  mkdir -p "$SRC_DIR"; cd "$SRC_DIR"
  if [[ ! -d .repo ]]; then
    command -v repo >/dev/null || { mkdir -p "$HOME/bin"; curl -fsSL "$REPO_URL" -o "$HOME/bin/repo"; chmod +x "$HOME/bin/repo"; }
    export PATH="$HOME/bin:$PATH"
    log "repo init ${BRANCH}（清华镜像）"
    repo init --no-repo-verify --repo-url="$REPO_URL" -u "$LOS_MANIFEST" -b "$BRANCH"
  fi
  sed -i "s#${AOSP_UPSTREAM}#${AOSP_MIRROR}#g" .repo/manifests/default.xml 2>/dev/null || true
  mkdir -p .repo/local_manifests
  rm -f .repo/local_manifests/rivena.xml        # 清掉 23.2 的旧清单，避免同一路径冲突
  cp "$SCRIPT_DIR/local_manifests/rivena-24.0.xml" .repo/local_manifests/rivena-24.0.xml
  ok "local_manifest 已就位"

  if (( DO_SYNC )); then
    log "repo sync -j${JOBS}（约 110 GB）"
    repo sync -c -j"$JOBS" --force-sync --no-clone-bundle --no-tags
  fi
}

build_stage() {
  cd "$SRC_DIR"
  export LC_ALL=C ALLOW_MISSING_DEPENDENCIES=true
  source build/envsetup.sh
  lunch "lineage_${DEVICE}-userdebug" || die "lunch 失败：先看 PRODUCT_ 变量报错"

  local logf="out/build-${STAGE}-$(date +%m%d-%H%M).log"
  mkdir -p out
  case "$STAGE" in
    config)   log "m nothing";   m nothing   2>&1 | tee "$logf" ;;
    sepolicy) log "m sepolicy";  m sepolicy  2>&1 | tee "$logf" ;;
    boot)     log "mka bootimage"; mka bootimage -j"$JOBS" 2>&1 | tee "$logf" ;;
    full)     log "mka bacon";   mka bacon -j"$JOBS" 2>&1 | tee "$logf" ;;
    *) die "未知 stage: $STAGE" ;;
  esac
  local rc=${PIPESTATUS[0]}
  echo
  if [[ $rc -ne 0 ]]; then
    warn "失败，前 15 条错误："
    grep -E "error:|neverallow|undefined module|Unknown soong" "$logf" | head -15
    echo "  完整日志：$SRC_DIR/$logf"
    exit $rc
  fi
  ok "$STAGE 通过"
  [[ "$STAGE" == "full" ]] && ls -lh out/target/product/${DEVICE}/lineage-*.zip 2>/dev/null
}

main() {
  log "rivena / ${BRANCH} / stage=${STAGE}"
  preflight
  if (( CHECK_ONLY )); then log "仅预检"; exit 0; fi
  if (( DO_DEPS )); then install_deps; fi
  prepare_source
  build_stage
  cat <<EOF

$(ok "完成")
  建议顺序：--stage config → --stage sepolicy → --stage boot → --stage full
  产物：${SRC_DIR}/out/target/product/${DEVICE}/
EOF
}

main "$@"

#!/usr/bin/env bash
# ============================================================================
#  聪聪学堂 (ChinaStudyFree) — 玩客云 / WanOS 一键部署
#
#  玩客云刷的 WanOS 底层其实是 Ubuntu 20.04.6 LTS (armhf)，带 apt + systemd，
#  所以这里复用 install/debian 的原生 nginx 方案，只额外做玩客云的前置检查：
#
#    · 无 Docker（内核/存储都不适合），所以不用容器方案
#    · 根分区只有 6.9G，部署完站点+资源后余量很紧张；
#      空间不足时建议把 --root 指到外挂 U 盘/移动硬盘
#    · 固定 IP 走 netplan、mDNS 走 avahi、远程访问走 Tailscale，这些是盒子侧
#      的额外配置，不在本脚本范围内（见 README「玩客云补充说明」）
#
#  实测环境：玩客云 S805（armhf, 1G 内存, 8G eMMC）
#    nginx-core 1.18.0（自带 --with-http_dav_module），8899 站点长期运行中
#
#  用法：
#    sudo bash install/wanos/install.sh
#    sudo bash install/wanos/install.sh --root /mnt/usb/csf
#    sudo bash install/wanos/install.sh --assets-src /mnt/nas/csf-assets   # 从本地副本装资源
#    sudo bash install/wanos/install.sh --uninstall
# ============================================================================

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$REPO_DIR/scripts/lib.sh"

[ "$(id -u)" = "0" ] || die "请用 root 运行：sudo bash $0 $*"

# ---------------------------- 玩客云前置检查 ----------------------------
echo
echo "  ── 玩客云 / WanOS 前置检查 ──"

# 1) 确认是 WanOS/玩客云 环境（不强制，只提示）
if [ -f /etc/os-release ]; then
  . /etc/os-release 2>/dev/null || true
  log "系统：${PRETTY_NAME:-未知} （架构 $(uname -m)）"
else
  warn "读不到 /etc/os-release，仍按 apt 系处理"
fi

# 2) 是否已有 docker（玩客云通常没有，有的话也可以走 nas-docker 方案）
if have docker; then
  warn "本机有 Docker，也可以直接用 install/nas-docker/install.sh（容器方案更省心）"
fi

# 3) 空间检查：站点 core ~14MB + 三大资源 ~2.1GB ≈ 2.3GB
ROOT_ARG=""
prev=""
for a in "$@"; do
  [ "$prev" = "--root" ] && ROOT_ARG="$a"
  prev="$a"
done
CHECK_DIR="${ROOT_ARG:-/srv/web}"
mkdir -p "$CHECK_DIR" 2>/dev/null || true
AVAIL_MB=$(( $(df -kP "$CHECK_DIR" 2>/dev/null | awk 'NR==2{print $4}') / 1024 ))
echo "  $CHECK_DIR 可用空间：${AVAIL_MB}MB"
if [ -f "$CHECK_DIR/out/index.html" ]; then
  log "检测到站点已部署在 $CHECK_DIR/out，将只做配置与资源补齐"
elif [ "$AVAIL_MB" -lt 3000 ]; then
  warn "可用空间不足 3GB，装不下「站点 + 全部资源」"
  warn "建议：--root /mnt/<外挂存储>/csf   或   bash scripts/fetch-assets.sh --site-dir <站点>/out --only data,textbook-pages 先装一部分"
fi

# 4) 检查 nginx dav 模块（若还没装 nginx，debian 脚本会装）
if have nginx && ! nginx -V 2>&1 | tr ' ' '\n' | grep -q 'with-http_dav_module'; then
  warn "已装的 nginx 不带 http_dav 模块，debian 脚本会尝试换成 nginx-full"
fi

log "交给 Debian/Ubuntu 安装器继续（参数原样透传）"
echo
exec bash "$REPO_DIR/install/debian/install.sh" "$@"

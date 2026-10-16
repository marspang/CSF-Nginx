#!/usr/bin/env bash
# ============================================================================
#  小猫头鹰课堂 (ChinaStudyFree) — iStoreOS / OpenWrt 一键部署
#
#  方案：Docker + nginx:alpine
#    OpenWrt 系的 opkg 源里没有现成的 nginx（而且官方 feed 的 nginx 不带
#    http_dav 模块），但 iStoreOS 自带 Docker，直接用官方 nginx:alpine 镜像
#    最省事，且和 NAS 上的部署完全同构（同一份 nginx 配置、同样跑 8899）。
#
#  实测环境：iStoreOS 24.10.8 (rockchip/armv8, aarch64) + Docker 27.3.1
#    站点 200 / 静态资源 200 / /api/progress WebDAV PUT+GET 正常
#
#  用法：
#    bash install/istoreos-openwrt/install.sh
#    bash install/istoreos-openwrt/install.sh --port 8899 --no-assets
#    bash install/istoreos-openwrt/install.sh --root /mnt/sda1/csf-nginx
#    bash install/istoreos-openwrt/install.sh --assets-src /mnt/nas/csf-assets
#    bash install/istoreos-openwrt/install.sh --uninstall --root /mnt/mmc1-4/csf-nginx
# ============================================================================

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$REPO_DIR/scripts/lib.sh"

PLATFORM="iStoreOS / OpenWrt"
CONTAINER="csf-nginx"
IMAGE="nginx:alpine"

PORT=8899
ROOT=""
WITH_ASSETS=1
ASSETS_SRC=""
UNINSTALL=0
FORCE=""
NEED_KB=$((4 * 1024 * 1024))   # 站点+资源 ~2.3GB，留点余量

usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --port)       PORT="$2"; shift 2 ;;
    --root)       ROOT="$2"; shift 2 ;;
    --no-assets)  WITH_ASSETS=0; shift ;;
    --assets-src) ASSETS_SRC="$2"; shift 2 ;;
    --uninstall)  UNINSTALL=1; shift ;;
    --force)      FORCE="--force"; shift ;;
    -h|--help)    usage ;;
    *) die "未知参数: $1（用 --help 看用法）" ;;
  esac
done

[ "$(id -u)" = "0" ] || die "请用 root 运行：sudo bash $0 $*"
have curl || have wget || die "需要 curl 或 wget"

# ============================================================ 卸载
if [ "$UNINSTALL" = 1 ]; then
  log "卸载容器 $CONTAINER"
  if have docker; then docker rm -f "$CONTAINER" 2>/dev/null || true; fi
  if [ -n "$ROOT" ]; then
    warn "删除安装目录 $ROOT"
    rm -rf "$ROOT"
  else
    warn "未指定 --root，仅删除容器；要一并删数据目录请加 --root <路径>"
  fi
  log "完成。（nginx:alpine 镜像保留，方便下次部署）"
  exit 0
fi

# ============================================================ 依赖
have docker || die "没有 docker。iStoreOS：应用中心搜「Docker」安装；纯 OpenWrt：opkg install dockerd luci-app-dockerman"
docker info >/dev/null 2>&1 || die "docker 守护进程没跑起来，先 /etc/init.d/dockerd start"

# ============================================================ 定位落盘分区
# OpenWrt 的 /overlay 往往只有几百 MB，站点必须放在有空间的挂载分区上。
command -v df >/dev/null 2>&1 || die "缺少 df 命令"
if [ -z "$ROOT" ]; then
  CAND="$(large_mounts | awk 'NR==1{print $2}')"
  [ -n "$CAND" ] || die "找不到合适的挂载点，请用 --root 手动指定"
  AVAIL="$(df -kP "$CAND" | awk 'NR==2{print $4}')"
  [ "$AVAIL" -ge "$NEED_KB" ] || die "最大可用分区 $CAND 只有 $((AVAIL/1024))MB，不足 4GB。请插入存储或用 --root 指定"
  ROOT="$CAND/csf-nginx"
fi

SITE_ROOT="$ROOT/out"
DATA_DIR="$ROOT/progress-data"
CONF_DIR="$ROOT/conf"
mkdir -p "$SITE_ROOT" "$DATA_DIR" "$CONF_DIR"

log "平台：$PLATFORM"
log "安装目录：$ROOT（该分区剩余 $(df -hP "$ROOT" | awk 'NR==2{print $4}')）"

# ============================================================ 配置 / 产物 / 资源
render_conf "$REPO_DIR/conf/studyfree.conf" "$CONF_DIR/default.conf" "$PORT" "/srv/web/out" "/srv/web/progress-data"
install_core "$SITE_ROOT" "$FORCE"

if [ "$WITH_ASSETS" = 1 ]; then
  if [ -n "$ASSETS_SRC" ]; then
    bash "$REPO_DIR/scripts/fetch-assets.sh" --site-dir "$SITE_ROOT" --src "$ASSETS_SRC"
  else
    bash "$REPO_DIR/scripts/fetch-assets.sh" --site-dir "$SITE_ROOT"
  fi
else
  warn "已跳过静态资源（音频/课本页/绘本图），之后可补："
  warn "  bash scripts/fetch-assets.sh --site-dir $SITE_ROOT"
fi

prep_progress_dir "$DATA_DIR"
chmod -R a+rX "$SITE_ROOT" 2>/dev/null || true

# ============================================================ 起容器 + 自检
log "启动容器 $CONTAINER（端口 $PORT）"
docker_run_site "$CONTAINER" "$IMAGE" "$PORT" "$CONF_DIR/default.conf" "$SITE_ROOT" "$DATA_DIR"
sleep 2

echo
if verify_site "$PORT"; then log "部署完成 ✅"; else
  warn "有检查项未通过，看日志：docker logs --tail 50 $CONTAINER"
fi

print_summary "$PORT" "$SITE_ROOT" "$DATA_DIR" "$CONF_DIR/default.conf" \
"  容器：         $CONTAINER（--restart unless-stopped，重启自动拉起）

  注意：OpenWrt 防火墙默认只放行 LAN。若要从其它网段访问，
        需在「防火墙 - 通信规则」放行 TCP $PORT。"

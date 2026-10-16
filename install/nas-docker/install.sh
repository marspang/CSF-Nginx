#!/usr/bin/env bash
# ============================================================================
#  小猫头鹰课堂 (ChinaStudyFree) — 通用 NAS / Docker 主机一键部署
#
#  适用：飞牛 fnOS、群晖 DSM、Unraid、威联通 QTS、TrueNAS、任意装了 Docker 的 Linux
#  方案：Docker + nginx:alpine（与 iStoreOS 版完全同构，容器内路径一致）
#
#  实测环境：飞牛 fnOS（站点已长期运行在 8899，进度共享正常）
#    另在 iStoreOS 24.10.8(Docker 27.3.1) 上以同一套配置实测通过
#
#  用法：
#    bash install/nas-docker/install.sh
#    bash install/nas-docker/install.sh --root /vol1/csf-nginx
#    bash install/nas-docker/install.sh --port 8899 --no-assets
#    bash install/nas-docker/install.sh --assets-src /mnt/nas/csf-assets
#    bash install/nas-docker/install.sh --uninstall --root /vol1/csf-nginx
#
#  也可以不用本脚本，直接用同目录的 docker-compose.yml（改好路径后 docker compose up -d）
# ============================================================================

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$REPO_DIR/scripts/lib.sh"

PLATFORM="NAS / Docker"
CONTAINER="csf-nginx"
IMAGE="nginx:alpine"

PORT=8899
ROOT=""
WITH_ASSETS=1
ASSETS_SRC=""
UNINSTALL=0
FORCE=""
NEED_KB=$((4 * 1024 * 1024))

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

[ "$(id -u)" = "0" ] || die "请用 root/sudo 运行：sudo bash $0 $*"
if have docker; then :; else die "没有 docker，请先在 NAS 的应用商店里安装 Docker"; fi

if [ "$UNINSTALL" = 1 ]; then
  log "卸载容器 $CONTAINER"
  docker rm -f "$CONTAINER" 2>/dev/null || true
  if [ -n "$ROOT" ]; then warn "删除安装目录 $ROOT"; rm -rf "$ROOT"
  else warn "未指定 --root，仅删除容器"; fi
  log "完成。（nginx:alpine 镜像保留）"
  exit 0
fi

docker info >/dev/null 2>&1 || die "docker 守护进程没跑起来"

# ============================================================ 定位落盘目录
if [ -z "$ROOT" ]; then
  # 常见 NAS 存储根目录按优先级尝试：飞牛 /vol1、群晖 /volume1、Unraid /mnt/user
  for c in /vol1 /volume1 /mnt/user /vol2 /volume2 /mnt; do
    [ -d "$c" ] && [ -w "$c" ] || continue
    a=$(df -kP "$c" 2>/dev/null | awk 'NR==2{print $4}')
    [ -n "$a" ] && [ "$a" -ge "$NEED_KB" ] && { ROOT="$c/csf-nginx"; break; }
  done
fi
[ -n "$ROOT" ] || ROOT="$(pick_dir "$NEED_KB")/csf-nginx"

SITE_ROOT="$ROOT/out"
DATA_DIR="$ROOT/progress-data"
CONF_DIR="$ROOT/conf"
mkdir -p "$SITE_ROOT" "$DATA_DIR" "$CONF_DIR"

log "平台：$PLATFORM"
log "安装目录：$ROOT（剩余 $(df -hP "$ROOT" | awk 'NR==2{print $4}')）"

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
  warn "已跳过静态资源，之后可补：bash scripts/fetch-assets.sh --site-dir $SITE_ROOT"
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
"  容器：         $CONTAINER（--restart unless-stopped，NAS 重启后自动拉起）
  若 NAS 自带反向代理，可再加一条 域名 -> 本机 $PORT，浏览器端直接用域名也能共享同一份进度。"

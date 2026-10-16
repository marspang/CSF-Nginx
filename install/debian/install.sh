#!/usr/bin/env bash
# ============================================================================
#  小猫头鹰课堂 (ChinaStudyFree) — Debian / Ubuntu 原生 nginx 一键部署
#
#  适用：Debian 11/12/13、Ubuntu 20.04/22.04/24.04 等 apt 系发行版
#  方案：apt 安装 nginx（含 http_dav 模块）+ 原生 systemd 服务，不用 Docker
#
#  实测环境：Ubuntu 20.04.6 LTS (armhf) —— 玩客云盒子
#    nginx-core 1.18.0 + libnginx-mod-http-dav-ext，站点 200 / 进度读写正常
#
#  用法：
#    sudo bash install/debian/install.sh
#    sudo bash install/debian/install.sh --port 8899 --root /srv/web
#    sudo bash install/debian/install.sh --no-assets
#    sudo bash install/debian/install.sh --uninstall
# ============================================================================

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$REPO_DIR/scripts/lib.sh"

PLATFORM="Debian / Ubuntu (原生 nginx)"
SITE_NAME="studyfree"
AVAIL_CONF="/etc/nginx/sites-available/$SITE_NAME"
ENABLED_CONF="/etc/nginx/sites-enabled/$SITE_NAME"
NGINX_USER="www-data"

PORT=8899
ROOT="/srv/web"
WITH_ASSETS=1
ASSETS_SRC=""
UNINSTALL=0
FORCE=""
NEED_KB=$((3 * 1024 * 1024))   # 站点+资源 ~2.3GB

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

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
have apt-get || die "这不是 apt 系系统（本脚本面向 Debian/Ubuntu）"

SITE_ROOT="$ROOT/out"
DATA_DIR="$ROOT/progress-data"

# ============================================================ 卸载
if [ "$UNINSTALL" = 1 ]; then
  log "卸载站点配置与目录"
  rm -f "$ENABLED_CONF" "$AVAIL_CONF"
  systemctl reload nginx 2>/dev/null || true
  warn "数据目录未自动删除：$ROOT （确认后手动 rm -rf $ROOT）"
  log "完成。"
  exit 0
fi

# ============================================================ 装 nginx 并确认 dav 模块
ensure_nginx() {
  if ! have nginx; then
    log "安装 nginx（apt）"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq || warn "apt-get update 失败，继续尝试安装"
    DEBIAN_FRONTEND=noninteractive apt-get install -y nginx curl tar unzip || die "apt 安装 nginx 失败"
  fi
  if nginx -V 2>&1 | tr ' ' '\n' | grep -q 'with-http_dav_module'; then
    log "nginx 已带 http_dav_module：$(nginx -v 2>&1)"
    return 0
  fi
  warn "当前 nginx 不带 http_dav 模块，尝试安装 nginx-full"
  DEBIAN_FRONTEND=noninteractive apt-get install -y nginx-full || true
  if nginx -V 2>&1 | tr ' ' '\n' | grep -q 'with-http_dav_module'; then
    log "已切换到带 dav 的 nginx：$(nginx -v 2>&1)"
    return 0
  fi
  warn "再试 nginx-extras（自带 dav-ext，功能更全）"
  DEBIAN_FRONTEND=noninteractive apt-get install -y nginx-extras || true
  nginx -V 2>&1 | tr ' ' '\n' | grep -q 'with-http_dav_module' \
    || die "nginx 仍不带 http_dav 模块，无法提供共享进度接口。请改用 Docker 方案（install/nas-docker）"
  log "已切换到带 dav 的 nginx：$(nginx -v 2>&1)"
}
ensure_nginx

# ============================================================ 空间检查
mkdir -p "$SITE_ROOT" "$DATA_DIR"
AVAIL=$(df -kP "$ROOT" | awk 'NR==2{print $4}')
if [ "$AVAIL" -lt "$NEED_KB" ]; then
  warn "目标分区 $ROOT 剩余仅 $((AVAIL/1024))MB（建议 ≥3GB）"
  if [ ! -f "$SITE_ROOT/index.html" ]; then
    die "空间不足，请换分区：--root /path/to/big/volume"
  fi
fi

log "平台：$PLATFORM"
log "站点根：$SITE_ROOT"

# ============================================================ 配置 / 产物 / 资源
render_conf "$REPO_DIR/conf/studyfree.conf" "$AVAIL_CONF" "$PORT" "$SITE_ROOT" "$DATA_DIR"
ln -sfn "$AVAIL_CONF" "$ENABLED_CONF"
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

# ============================================================ 权限
# 进度目录必须让 nginx worker（www-data）可写。
# 故意不预置 state.json：没有这个文件 = “还没有共享进度”，
# 前端会把本机已有的进度作为初始基准推上来；预置空 {} 反而会冲掉设备上已有的进度。
mkdir -p "$DATA_DIR"
chown "$NGINX_USER:$NGINX_USER" "$DATA_DIR"
chmod 775 "$DATA_DIR"
chmod -R a+rX "$SITE_ROOT" 2>/dev/null || true

# ============================================================ 语法自检 + 起服务
# 先启用再做语法检查；不通过就撤销启用，避免把该机上原有的服务打挂
ln -sfn "$AVAIL_CONF" "$ENABLED_CONF"
if ! nginx -t; then
  rm -f "$ENABLED_CONF"
  nginx -t
  die "studyfree 配置有误，已撤销启用（站点 $PORT 未生效，原有站点不受影响）"
fi

systemctl enable nginx >/dev/null 2>&1 || true
systemctl restart nginx
sleep 1
systemctl is-active nginx >/dev/null || { journalctl -u nginx -n 30 --no-pager; die "nginx 启动失败"; }

echo
if verify_site "$PORT"; then log "部署完成 ✅"; else
  warn "有检查项未通过，看日志：journalctl -u nginx -n 50 --no-pager"
fi

print_summary "$PORT" "$SITE_ROOT" "$DATA_DIR" "$AVAIL_CONF" \
"  服务：         nginx.service（已 enable，开机自启）
  说明：本配置单独 listen $PORT，不会影响该机上原有的 80 端口站点。"

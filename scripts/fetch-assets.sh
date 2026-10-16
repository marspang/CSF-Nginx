#!/usr/bin/env bash
# ============================================================================
#  fetch-assets.sh — 拉取「小猫头鹰课堂」站点所需的静态资源包
#
#  站点的构建产物（HTML / JS / CSS / data）很小（约 14MB），
#  但音频、课本扫描页、绘本插图很大（合计约 2.1GB），
#  它们由上游项目 ChinaTextbookStudyFree 以 Release 资产的形式发布。
#
#  用法：
#    # 默认：把三大资源包解到指定站点根目录
#    bash scripts/fetch-assets.sh --site-dir /srv/web/out
#
#    # 只补某几样（已有内容的目录会自动跳过）
#    bash scripts/fetch-assets.sh --site-dir /srv/web/out --only textbook-pages,story-images
#
#    # 从本地/NAS 上已有的副本拷贝（适合盒子直连 GitHub 很慢的场景）
#    bash scripts/fetch-assets.sh --site-dir /srv/web/out --src /mnt/nas/csf-assets
#
#  资源清单（与上游 ASSETS-VERSION.json 一致）：
#    audio.tar.gz        1.29GB  解到站点根，得到 audio/
#    textbook-pages.zip   212MB  解到站点根/textbook-pages/
#    story-images.zip     551MB  解到站点根/story-images/
#    data.zip             4.9MB  解到站点根/data/
# ============================================================================

set -euo pipefail

UPSTREAM_REPO="wuwangzhang1216/ChinaTextbookStudyFree"
UPSTREAM_TAG="v1.2.0-assets"
ALL_PARTS="audio,textbook-pages,story-images,data"

SITE_DIR=""
PARTS="$ALL_PARTS"
SRC=""
FORCE=0
TAG="$UPSTREAM_TAG"

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --site-dir)  SITE_DIR="$2"; shift 2 ;;
    --only)      PARTS="$2"; shift 2 ;;
    --src)       SRC="$2"; shift 2 ;;
    --tag)       TAG="$2"; shift 2 ;;
    --force)     FORCE=1; shift ;;
    -h|--help)   usage ;;
    *) die "未知参数: $1（用 --help 看用法）" ;;
  esac
done

[ -n "$SITE_DIR" ] || die "必须指定 --site-dir（站点根目录）"
mkdir -p "$SITE_DIR"
SITE_DIR="$(cd "$SITE_DIR" && pwd)"

BASE_URL="https://github.com/$UPSTREAM_REPO/releases/download/$TAG"

# ---------------------------------------------------------------- 工具检测
HAVE_PY3=0; command -v python3 >/dev/null 2>&1 && HAVE_PY3=1
HAVE_UNZIP=0; command -v unzip  >/dev/null 2>&1 && HAVE_UNZIP=1
[ "$HAVE_PY3" = 1 ] || [ "$HAVE_UNZIP" = 1 ] || \
  die "需要 python3 或 unzip 之一来解压 zip（iStoreOS 可 opkg update && opkg install python3-light；Debian 可 apt-get install -y unzip）"

have() { command -v "$1" >/dev/null 2>&1; }
have curl || have wget || die "需要 curl 或 wget"

fetch() { # fetch <url> <outfile>
  local url="$1" out="$2"
  if have curl; then
    curl -fL --retry 3 --retry-delay 3 -o "$out" "$url"
  else
    wget -q -O "$out" "$url"
  fi
}

# 上游的 zip 里用的是 Windows 反斜杠路径，必须逐条修正后再落盘
extract_zip() { # extract_zip <zip> <destdir>
  local zip="$1" dest="$2"
  mkdir -p "$dest"
  if [ "$HAVE_PY3" = 1 ]; then
    python3 - "$zip" "$dest" <<'PY'
import os, sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(src) as z:
    for name in z.namelist():
        fixed = name.replace('\\', '/')
        target = os.path.join(dst, fixed)
        if fixed.endswith('/'):
            os.makedirs(target, exist_ok=True); continue
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with z.open(name) as sf, open(target, 'wb') as df:
            while True:
                chunk = sf.read(1 << 20)
                if not chunk: break
                df.write(chunk)
PY
  else
    rm -rf "$dest.tmp"; mkdir -p "$dest.tmp"
    unzip -q -o "$zip" -d "$dest.tmp"
    # unzip 会把反斜杠当字面文件名，做一次转换
    ( cd "$dest.tmp" && find . -depth -name '*\\*' | while IFS= read -r f; do
        n="$(printf '%s' "$f" | tr '\\' '/')"
        mkdir -p "$(dirname "$n")" && mv -f "$f" "$n"
      done )
    cp -rf "$dest.tmp/." "$dest/" && rm -rf "$dest.tmp"
  fi
}

# 目标是否已经有内容了（有就跳过，避免重复下载 2GB）
already() { # already <marker-path>
  local m="$1"
  [ "$FORCE" = 0 ] && [ -e "$m" ] && [ -n "$(ls -A "$m" 2>/dev/null | head -1)" ]
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------- 逐项处理
copy_or_download() { # copy_or_download <filename> <dest-local-path> <url>
  local name="$1" out="$2" url="$3"
  if [ -n "$SRC" ]; then
    [ -e "$SRC/$name" ] || die "本地源 $SRC 里找不到 $name"
    log "从本地源拷贝 $name"
    cp -f "$SRC/$name" "$out"
  else
    log "下载 $name （$( [ "$name" = audio.tar.gz ] && echo '约 1.3GB' || echo '较大' )）"
    fetch "$url" "$out"
  fi
}

for part in $(printf '%s' "$PARTS" | tr ',' ' '); do
  case "$part" in
    audio)
      if already "$SITE_DIR/audio"; then warn "audio/ 已存在，跳过"; continue; fi
      copy_or_download audio.tar.gz "$TMP/audio.tar.gz" "$BASE_URL/audio.tar.gz"
      log "解压 audio.tar.gz -> $SITE_DIR/"
      tar xzf "$TMP/audio.tar.gz" -C "$SITE_DIR"
      ;;
    textbook-pages)
      if already "$SITE_DIR/textbook-pages"; then warn "textbook-pages/ 已存在，跳过"; continue; fi
      copy_or_download textbook-pages.zip "$TMP/textbook-pages.zip" "$BASE_URL/textbook-pages.zip"
      log "解压 textbook-pages.zip -> $SITE_DIR/textbook-pages/"
      extract_zip "$TMP/textbook-pages.zip" "$SITE_DIR/textbook-pages"
      ;;
    story-images)
      if already "$SITE_DIR/story-images"; then warn "story-images/ 已存在，跳过"; continue; fi
      copy_or_download story-images.zip "$TMP/story-images.zip" "$BASE_URL/story-images.zip"
      log "解压 story-images.zip -> $SITE_DIR/story-images/"
      extract_zip "$TMP/story-images.zip" "$SITE_DIR/story-images"
      ;;
    data)
      if already "$SITE_DIR/data"; then warn "data/ 已存在，跳过"; continue; fi
      copy_or_download data.zip "$TMP/data.zip" "$BASE_URL/data.zip"
      log "解压 data.zip -> $SITE_DIR/data/"
      extract_zip "$TMP/data.zip" "$SITE_DIR/data"
      ;;
    *) die "未知资源项: $part（可选: $ALL_PARTS）" ;;
  esac
done

log "资源就绪。"
du -sh "$SITE_DIR" 2>/dev/null || true

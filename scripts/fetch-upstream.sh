#!/usr/bin/env bash
# ============================================================================
#  fetch-upstream.sh — 全量安装上游 ChinaTextbookStudyFree 发布包
#
#  装的是上游官方构建产物 + 全部内容，不是本站点自己的构建：
#    · 页面 / JS / CSS（web-app.zip）
#    · 题库与课程数据（data.zip）
#    · 音频 100% 全量（audio-original 3 包 + audio-web 4 包）
#    · 教材扫描页（textbook-pages.zip）
#    · 绘本插图（story-images.zip）
#  合计约 9.1GB 下载、9.5GB 落盘；装完是 45 本书（1-6 年级语文 / 数学 / 科学 / 英语），
#  约 2700 个课时、1.5 万道题、11.9 万条 MP3。
#
#  为什么不会出现 “a.bimesc” 这种公式变英文的 bug：
#    这份页面是上游在构建期渲染好的成品，LaTeX 只经过一次反转义，浏览器实测公式为 × ÷；
#    而本仓库自己构建源码时，MathText 里带着 healEscapedLatex 兜底，两条路都不会出残骸。
#    装完脚本还会核对数据引用的音频是否全部落盘，缺一条就报错。
#
#  用法：
#    sudo bash scripts/fetch-upstream.sh --site-dir /srv/web/out
#    # 盒子直连 GitHub 慢：先从 NAS 把发布包下好，再用 --src 指过去
#    sudo bash scripts/fetch-upstream.sh --site-dir /srv/web/out --src /mnt/nas/csf-upstream
#    # 只装一部分（例如先跑页面与题库，音频以后再补）
#    sudo bash scripts/fetch-upstream.sh --site-dir /srv/web/out --only web,data
#    # 看看会下哪些包、要多少空间，不实际下载
#    bash scripts/fetch-upstream.sh --site-dir /srv/web/out --dry-run
# ============================================================================

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO_DIR/scripts/lib.sh"

UPSTREAM_REPO="wuwangzhang1216/ChinaTextbookStudyFree"
UPSTREAM_TAG="v1.4.3-content-restored"
KINDS="web,audio-original,audio-web,data,story-images,textbook-pages"

SITE_DIR=""
SRC=""
ONLY="$KINDS"
JOBS=3
KEEP_ZIPS=0
DRY_RUN=0
MANIFEST=""
CHECK_AUDIO=1

usage() { sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --site-dir)      SITE_DIR="$2"; shift 2 ;;
    --src)           SRC="$2"; shift 2 ;;
    --only)          ONLY="$2"; shift 2 ;;
    --jobs)          JOBS="$2"; shift 2 ;;
    --tag)           UPSTREAM_TAG="$2"; shift 2 ;;
    --manifest)      MANIFEST="$2"; shift 2 ;;
    --keep-zips)     KEEP_ZIPS=1; shift ;;
    --dry-run)       DRY_RUN=1; shift ;;
    --no-check)       CHECK_AUDIO=0; shift ;;
    -h|--help)       usage ;;
    *) die "未知参数: $1（用 --help 看用法）" ;;
  esac
done

[ -n "$SITE_DIR" ] || die "必须指定 --site-dir（站点根目录）"
have python3 || die "需要 python3 解析发布清单（Debian: apt-get install -y python3；OpenWrt: opkg install python3-light）"
[ -n "$SRC" ] || need_http_tool

BASE_URL="https://github.com/$UPSTREAM_REPO/releases/download/$UPSTREAM_TAG"
mkdir -p "$SITE_DIR"
SITE_DIR="$(cd "$SITE_DIR" && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------- 发布清单
if [ -n "$MANIFEST" ]; then
  [ -f "$MANIFEST" ] || die "找不到清单文件：$MANIFEST"
  MF="$MANIFEST"
elif [ -n "$SRC" ] && [ -f "$SRC/manifest.json" ]; then
  MF="$SRC/manifest.json"
else
  log "下载发布清单 manifest.json"
  fetch "$BASE_URL/manifest.json" "$TMP/manifest.json"
  MF="$TMP/manifest.json"
fi

# 输出：name <TAB> static 目标 <TAB> 字节 <TAB> sha256 <TAB> 文件数
PLAN="$TMP/plan.tsv"
python3 - "$MF" "$ONLY" > "$PLAN" <<'PY'
import json, sys
manifest, only = sys.argv[1], [k.strip() for k in sys.argv[2].split(",") if k.strip()]
m = json.load(open(manifest, encoding="utf-8"))
for a in m["assets"]:
    dest = (a.get("destinations") or {}).get("static")
    if dest is None or a.get("kind") not in only:
        continue
    print("\t".join([a["name"], dest, str(a["bytes"]), a["sha256"], str(a.get("files") or "")]))
PY
[ -s "$PLAN" ] || die "清单里没有匹配的资源（--only $ONLY）"

TOTAL_BYTES=$(awk -F'\t' '{s+=$3} END{print s+0}' "$PLAN")
TOTAL_FILES=$(awk -F'\t' '{s+=$5} END{print s+0}' "$PLAN")
COUNT=$(wc -l < "$PLAN" | tr -d ' ')
MAX_ZIP=$(awk -F'\t' 'BEGIN{m=0} {if($3>m)m=$3} END{print m+0}' "$PLAN")

log "计划安装 $COUNT 个发布包：$((TOTAL_BYTES/1024/1024))MB / $TOTAL_FILES 个文件"
awk -F'\t' '{printf "    %-28s -> %-16s %6.2fGB\n", $1, $2, $3/1e9}' "$PLAN"

if [ "$DRY_RUN" = 1 ]; then
  log "dry-run：只列计划，不做任何下载或写入"
  exit 0
fi

# ---------------------------------------------------------------- 空间检查
mkdir -p "$SITE_DIR"
AVAIL_KB=$(df -kP "$SITE_DIR" | awk 'NR==2{print $4}')
if [ -n "$SRC" ]; then
  # 本地源模式：压缩包不落盘，只需要解出来的空间
  NEED_KB=$(( TOTAL_BYTES / 1024 + TOTAL_BYTES / 10240 ))
else
  # 下载模式：解出的内容 + 同时在盘上的临时压缩包
  NEED_KB=$(( TOTAL_BYTES / 1024 + TOTAL_BYTES / 10240 + (JOBS < COUNT ? JOBS : COUNT) * MAX_ZIP / 1024 ))
fi
if [ "$AVAIL_KB" -lt "$NEED_KB" ]; then
  die "$SITE_DIR 所在分区只剩 $((AVAIL_KB/1024))MB，全量安装需要约 $((NEED_KB/1024))MB（含临时压缩包）。可用 --only 先装一部分，或换到更大的分区。"
fi

# ---------------------------------------------------------------- 下载 / 校验 / 解包
# 上游 zip 里混着 Windows 反斜杠路径，必须逐条修正后再落盘
extract_zip() { # extract_zip <zip> <destdir>
  local zip="$1" dest="$2"
  mkdir -p "$dest"
  python3 - "$zip" "$dest" <<'PY'
import os, sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(src) as z:
    names = z.namelist()
    for i, name in enumerate(names, 1):
        fixed = name.replace('\\', '/')
        target = os.path.join(dst, fixed)
        if fixed.endswith('/'):
            os.makedirs(target, exist_ok=True)
            continue
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with z.open(name) as sf, open(target, 'wb') as df:
            while True:
                chunk = sf.read(1 << 20)
                if not chunk:
                    break
                df.write(chunk)
        if i % 20000 == 0:
            print(f"      ... 已解出 {i}/{len(names)}", flush=True)
PY
}

download_one() { # download_one <name> <bytes>；成功时把路径写进 ZIP_PATH
  local name="$1" bytes="$2" attempt=1 size
  if [ -n "$SRC" ]; then
    [ -f "$SRC/$name" ] || { warn "本地源缺少 $name"; return 1; }
    size=$(wc -c < "$SRC/$name" 2>/dev/null || echo 0)
    [ "$size" = "$bytes" ] || { warn "$SRC/$name 大小不符（$size/$bytes）"; return 1; }
    ZIP_PATH="$SRC/$name"
    return 0
  fi
  ZIP_PATH="$TMP/$name"
  while [ "$attempt" -le 5 ]; do
    curl -fL --retry 3 --retry-delay 5 -C - -o "$ZIP_PATH" "$BASE_URL/$name" || true
    size=$(wc -c < "$ZIP_PATH" 2>/dev/null || echo 0)
    [ "$size" = "$bytes" ] && return 0
    warn "$name 大小不符（$size/$bytes），第 $attempt 次重试"
    attempt=$((attempt + 1))
    sleep 3
  done
  return 1
}

idx=0
while IFS=$'\t' read -r name dest bytes sha files; do
  idx=$((idx + 1))
  log "[$idx/$COUNT] $name （$((bytes/1024/1024))MB）"
  download_one "$name" "$bytes" || die "$name 下载失败；可先用别处下好的发布包，再用 --src 指向该目录"

  log "    校验 SHA256"
  actual="$(sha256_of "$ZIP_PATH")"
  [ "$actual" = "$sha" ] || die "$name 校验失败：期望 $sha，实际 $actual"

  log "    解压到 $SITE_DIR/${dest%/}"
  extract_zip "$ZIP_PATH" "$SITE_DIR/$dest"
  if [ -z "$SRC" ] && [ "$KEEP_ZIPS" = 0 ]; then rm -f "$ZIP_PATH"; fi
done < "$PLAN"

chmod -R a+rX "$SITE_DIR" 2>/dev/null || true

# ---------------------------------------------------------------- 安装后自检
[ -f "$SITE_DIR/index.html" ] || die "安装后没有 index.html，发布包不完整"
[ -f "$SITE_DIR/data/index.json" ] || die "安装后没有 data/index.json，数据包不完整"

if [ -d "$SITE_DIR/audio" ] && [ "$CHECK_AUDIO" = 1 ]; then
  log "核对数据引用的音频是否都在盘上"
  if ! python3 - "$SITE_DIR" <<'PY'
import glob, os, re, sys
site = sys.argv[1]
pat = re.compile(r"([0-9a-f]{40}(?:\.edge-[0-9a-f]{12})?)\.(?:mp3|opus)")
refs = set()
for jf in glob.glob(os.path.join(site, "data", "books", "*", "*.json")) + \
          glob.glob(os.path.join(site, "data", "books", "*", "lessons", "*.json")) + \
          glob.glob(os.path.join(site, "data", "*", "*.json")):
    try:
        refs.update(pat.findall(open(jf, encoding="utf-8", errors="ignore").read()))
    except OSError:
        pass
missing = [r for r in refs if not os.path.exists(os.path.join(site, "audio", r[:2], r + ".mp3"))
           and not os.path.exists(os.path.join(site, "audio", r[:2], r + ".opus"))]
print(f"     引用音频 {len(refs)} 条，缺失 {len(missing)} 条")
for m in missing[:5]:
    print(f"     缺 {m}")
sys.exit(1 if missing else 0)
PY
  then
    die "有音频引用没落盘，发布包不完整或磁盘写入中断"
  fi
elif [ ! -d "$SITE_DIR/audio" ]; then
  warn "没有 audio/ 目录（这次没装音频，页面与题库仍可用）"
fi

log "完成。"
du -sh "$SITE_DIR" 2>/dev/null || true
python3 - "$SITE_DIR/data/index.json" 2>/dev/null <<'PY' || true
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
print(f"    {len(d.get('books', []))} 本书 / {d.get('totalLessons', '?')} 课时 / {d.get('totalQuestions', '?')} 题")
PY

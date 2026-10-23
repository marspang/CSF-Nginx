#!/usr/bin/env bash
# ============================================================================
#  fetch-grades.sh — 按年级装内容，可分多次追加
#
#  从一份已经完整的站点树里挑出指定年级（教材页 / 课时页 / 题库 / 绘本 / 音频），
#  写进现有站点目录。**只增不删**，所以第一次装一年级、半年后加二年级，
#  直接再跑一次带 --grades 2 即可，已装内容不用重来、不会被覆盖删掉。
#
#  学习进度不受影响：进度存在 nginx 的共享进度目录（默认 <安装根>/progress-data，
#  站点目录之外），换站点内容、升级内容都不会动它；浏览器端 localStorage 只是缓存。
#
#  用法：
#    # 一年级先装上
#    sudo bash scripts/fetch-grades.sh --src /mnt/nas/csf-full --site-dir /srv/web/out --grades 1
#    # 之后加二年级（保留一年级）
#    sudo bash scripts/fetch-grades.sh --src /mnt/nas/csf-full --site-dir /srv/web/out --grades 2
#    # 看看要复制多少、不实际写
#    bash scripts/fetch-grades.sh --src /mnt/nas/csf-full --site-dir /srv/web/out --grades 1,2 --dry-run
#
#  --src 指向的完整站点树怎么来：在 NAS 上跑
#    bash scripts/fetch-upstream.sh --site-dir /mnt/nas/csf-full
#  一次下好，之后给每台小机器按年级挑，不用重复下载。
# ============================================================================

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO_DIR/scripts/lib.sh"

SRC=""
SITE_DIR=""
GRADES=""
WITH_OPUS=0
DRY_RUN=0

usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --src)       SRC="$2"; shift 2 ;;
    --site-dir)  SITE_DIR="$2"; shift 2 ;;
    --grades)    GRADES="$2"; shift 2 ;;
    --with-opus) WITH_OPUS=1; shift ;;
    --dry-run)   DRY_RUN=1; shift ;;
    -h|--help)   usage ;;
    *) die "未知参数: $1（用 --help 看用法）" ;;
  esac
done

[ -n "$SRC" ] || die "缺少 --src（完整站点树所在目录）"
[ -n "$SITE_DIR" ] || die "缺少 --site-dir（要写入的站点根目录）"
[ -n "$GRADES" ] || die "缺少 --grades（例：--grades 1 或 --grades 1,2）"
[ -d "$SRC/data/books" ] || die "$SRC 不像完整站点树（缺 data/books）"
have python3 || die "需要 python3"

SRC="$(cd "$SRC" && pwd)"
mkdir -p "$SITE_DIR"
SITE_DIR="$(cd "$SITE_DIR" && pwd)"

python3 - "$SRC" "$SITE_DIR" "$GRADES" "$WITH_OPUS" "$DRY_RUN" <<'PY'
import json, os, re, shutil, sys

src, dst, grades_arg, with_opus, dry = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1", sys.argv[5] == "1"
grades = {int(g) for g in re.split(r"[,\s]+", grades_arg.strip()) if g}
if not grades or any(g < 1 or g > 6 for g in grades):
    sys.exit("--grades 只能写 1~6，例如 --grades 1,2")

books = [b for b in sorted(os.listdir(os.path.join(src, "data", "books")))
         if (m := re.search(r"g(\d)", b)) and int(m.group(1)) in grades]
if not books:
    sys.exit("源里没有这些年级的书籍数据")
print(f"选中 {len(books)} 本（{', '.join(str(g) for g in sorted(grades))} 年级）")

audio_pat = re.compile(r"([0-9a-f]{40}(?:\.edge-[0-9a-f]{12})?)\.(mp3|opus)")

def copy_tree(rel):
    """整目录复制到目标，已存在的文件跳过；返回 (文件数, 字节数)。"""
    s, d = os.path.join(src, rel), os.path.join(dst, rel)
    n = size = 0
    for root, _, files in os.walk(s):
        for f in files:
            sp = os.path.join(root, f)
            dp = os.path.join(d, os.path.relpath(sp, s))
            if os.path.exists(dp):
                continue
            n += 1
            size += os.path.getsize(sp)
            if not dry:
                os.makedirs(os.path.dirname(dp), exist_ok=True)
                shutil.copy2(sp, dp)
    return n, size

added_files = added_bytes = 0

# 1) 站点骨架：首页、_next、年级页、404 等（只在缺失时补）
for name in os.listdir(src):
    p = os.path.join(src, name)
    if name in ("audio", "data", "lesson", "book", "reading", "stories", "textbook-pages", "story-images"):
        continue
    if os.path.isfile(p):
        q = os.path.join(dst, name)
        if not os.path.exists(q):
            added_files += 1
            added_bytes += os.path.getsize(p)
            if not dry:
                shutil.copy2(p, q)
    else:
        n, s = copy_tree(name)
        added_files += n
        added_bytes += s

# 2) 各年级的书本目录
for name in ("lesson", "book", "reading", "stories", "textbook-pages", "story-images", "data/books"):
    for b in books:
        if os.path.isdir(os.path.join(src, name, b)):
            n, s = copy_tree(os.path.join(name, b))
            added_files += n
            added_bytes += s

# 3) 音频：只搬这些书真正引用到的
refs = set()
for b in books:
    for sub in ("lesson", "book", "data/books"):
        root = os.path.join(src, sub, b)
        for r, _, fs in os.walk(root):
            for f in fs:
                if not f.endswith((".html", ".txt", ".json")):
                    continue
                try:
                    text = open(os.path.join(r, f), encoding="utf-8", errors="ignore").read()
                except OSError:
                    continue
                for h, ext in audio_pat.findall(text):
                    if ext == "opus" and not with_opus:
                        continue
                    refs.add(f"{h}.{ext}")

missing_audio = 0
for a in sorted(refs):
    sp = os.path.join(src, "audio", a[:2], a)
    if not os.path.exists(sp):
        missing_audio += 1
        continue
    dp = os.path.join(dst, "audio", a[:2], a)
    if os.path.exists(dp):
        continue
    added_files += 1
    added_bytes += os.path.getsize(sp)
    if not dry:
        os.makedirs(os.path.dirname(dp), exist_ok=True)
        shutil.copy2(sp, dp)

# 4) 合并 data/index.json：只保留盘上真实存在的书
idx_path = os.path.join(dst, "data", "index.json")
src_idx = json.load(open(os.path.join(src, "data", "index.json"), encoding="utf-8"))
src_books = {str(b.get("id")): b for b in src_idx.get("books", [])}
installed = []
for bdir in sorted(os.listdir(os.path.join(dst, "data", "books"))):
    if bdir in src_books:
        installed.append(src_books[bdir])
idx = dict(src_idx)
idx["books"] = installed
idx["totalLessons"] = sum(int(b.get("lessonsCount", 0)) for b in installed)
q = 0
for b in installed:
    root = os.path.join(dst, "data", "books", str(b["id"]))
    for r, _, fs in os.walk(root):
        for f in fs:
            if not f.endswith(".json"):
                continue
            try:
                d = json.load(open(os.path.join(r, f), encoding="utf-8"))
            except Exception:
                continue
            if isinstance(d, dict) and isinstance(d.get("questions"), list):
                q += len(d["questions"])
idx["totalQuestions"] = q
if not dry:
    os.makedirs(os.path.dirname(idx_path), exist_ok=True)
    json.dump(idx, open(idx_path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)

print(f"新增 {added_files} 个文件 / {added_bytes/1e9:.2f}GB" + ("（dry-run，未写入）" if dry else ""))
if missing_audio:
    print(f"警告：源里缺 {missing_audio} 条被引用的音频")
print(f"站点当前：{len(installed)} 本书 / {idx['totalLessons']} 课时 / {idx['totalQuestions']} 题")
PY

if [ "$DRY_RUN" = 0 ]; then
  chmod -R a+rX "$SITE_DIR" 2>/dev/null || true
  log "完成。学习进度在站点目录之外的 progress-data，换内容不受影响；只想加年级就再跑一次本脚本。"
fi

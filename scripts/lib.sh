#!/usr/bin/env bash
# ============================================================================
#  scripts/lib.sh — 各平台安装脚本共用的函数（下载、校验、解包、起容器、自检）
#  被 install/*/install.sh 以 source 方式引入，不要单独执行。
# ============================================================================

CORE_URL="https://github.com/marspang/CSF-Nginx/releases/download/v1.0.0/csf-core.tar.gz"
CORE_SHA256="66991ea50f6e43b9d12839da8871d95630005c1821e27a1c77493e468a8faa4a"
CORE_SIZE_HINT="约 14MB"

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

need_http_tool() {
  have curl || have wget || die "需要 curl 或 wget 来下载文件"
}

fetch() { # fetch <url> <outfile>
  if have curl; then curl -fL --retry 3 --retry-delay 3 -o "$2" "$1"
  else wget -q -O "$2" "$1"; fi
}

sha256_of() { # sha256_of <file>
  if have sha256sum; then sha256sum "$1" | awk '{print $1}'
  elif have shasum;   then shasum -a 256 "$1" | awk '{print $1}'
  else die "系统没有 sha256sum/shasum，无法校验下载"; fi
}

# 找出所有“有空间、可写”的挂载点，按剩余空间降序输出
large_mounts() { # large_mounts
  df -kP 2>/dev/null | awk 'NR>1{print $4"\t"$6}' | while IFS="$(printf '\t')" read -r avail mp; do
    case "$mp" in /|/rom|/tmp|/overlay|/boot|/dev*|/proc*|/sys*|/var*|/etc*|/usr*) continue ;; esac
    [ -d "$mp" ] && [ -w "$mp" ] || continue
    printf '%s\t%s\n' "$avail" "$mp"
  done | sort -rn
}

# pick_dir <最小需要KB> [候选根目录...] —— 无候选时按剩余空间自动挑
pick_dir() { # pick_dir <min_kb> [candidates...]
  local min_kb="$1"; shift
  local cand avail
  if [ $# -gt 0 ]; then
    for cand in "$@"; do
      [ -n "$cand" ] || continue
      [ -d "$cand" ] && [ -w "$cand" ] || continue
      avail=$(df -kP "$cand" 2>/dev/null | awk 'NR==2{print $4}')
      [ -n "$avail" ] && [ "$avail" -ge "$min_kb" ] && { echo "$cand"; return 0; }
    done
    die "指定的候选目录空间不足（需要 ≥$((min_kb/1024/1024))GB）：$*"
  fi
  while IFS="$(printf '\t')" read -r avail cand; do
    [ -n "$cand" ] || continue
    [ "$avail" -ge "$min_kb" ] && { echo "$cand"; return 0; }
  done < <(large_mounts)
  die "找不到剩余空间 ≥$((min_kb/1024/1024))GB 的可写目录，请用 --root 手动指定"
}

# render_conf <模板> <输出文件> <端口> <站点根(容器内路径)> <进度目录(容器内路径)>
render_conf() {
  local tpl="$1" out="$2" port="$3" site="$4" data="$5"
  [ -f "$tpl" ] || die "找不到配置模板：$tpl"
  sed -e "s|@@LISTEN_PORT@@|$port|g" \
      -e "s|@@SITE_ROOT@@|$site|g" \
      -e "s|@@PROGRESS_DIR@@|$data|g" \
      "$tpl" > "$out"
}

# install_core <站点根目录> [--force]
install_core() {
  local site="$1" force="${2:-}"
  if [ "$force" != "--force" ] && [ -f "$site/index.html" ]; then
    warn "站点产物已存在，跳过下载（加 --force 强制重下）"
    return 0
  fi
  log "下载站点构建产物（$CORE_SIZE_HINT）"
  local tmp; tmp="$(mktemp)"
  fetch "$CORE_URL" "$tmp"
  log "校验 SHA256"
  local actual; actual="$(sha256_of "$tmp")"
  if [ "$actual" != "$CORE_SHA256" ]; then
    rm -f "$tmp"
    die "校验失败：期望 $CORE_SHA256，实际 $actual"
  fi
  log "解压到 $site"
  tar xzf "$tmp" -C "$site"
  rm -f "$tmp"
}

# prep_progress_dir <进度目录>
prep_progress_dir() {
  local dir="$1"
  mkdir -p "$dir"
  chmod 777 "$dir"
  [ -f "$dir/state.json" ] || echo '{}' > "$dir/state.json"
  chmod 666 "$dir/state.json"
}

docker_run_site() { # docker_run_site <容器名> <镜像> <端口> <conf> <站点> <进度>
  local name="$1" image="$2" port="$3" conf="$4" site="$5" data="$6"
  docker info >/dev/null 2>&1 || die "docker 守护进程没跑起来"
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d \
    --name "$name" \
    --restart unless-stopped \
    -p "${port}:80" \
    -v "$conf:/etc/nginx/conf.d/default.conf:ro" \
    -v "$site:/srv/web/out:ro" \
    -v "$data:/srv/web/progress-data" \
    "$image" >/dev/null
}

# verify_site <端口>
verify_site() {
  local port="$1" ok=1 code path
  for path in "/" "/icon.svg" "/api/progress/state.json"; do
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}${path}" 2>/dev/null || echo 000)"
    printf '    %-30s -> %s\n' "$path" "$code"
    [ "$code" = "200" ] || ok=0
  done
  [ "$ok" = 1 ]
}

print_summary() { # print_summary <端口> <站点> <进度> <配置> <附加说明>
  cat <<EOF

  局域网访问：   http://<本机IP>:$1/
  共享进度接口： http://<本机IP>:$1/api/progress/state.json   (WebDAV)
  站点目录：     $2
  进度目录：     $3
  配置：         $4

$5
EOF
}

# 各平台脚本的固定开头：
#   REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
#   . "$REPO_DIR/scripts/lib.sh"

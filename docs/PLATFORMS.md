# 平台适配说明

同一份站点，在不同平台上“跑起来”需要的东西不一样。这里说清楚每个平台用什么方案、
为什么这么选、以及哪些地方是实测过的。

## 两条技术路线

### A. Docker 方案 —— `nginx:alpine` 容器
- 官方 nginx 镜像自带 `--with-http_dav_module`，不用操心模块被裁剪
- 站点、进度、配置都以 bind mount 挂进容器，容器内路径固定为
  `/srv/web/out`、`/srv/web/progress-data`、`/etc/nginx/conf.d/default.conf`
- 这套路径和配置**在 NAS 和 iStoreOS 上完全通用**，同一份 `conf/studyfree.conf`
- 自启：`--restart unless-stopped`

适用：iStoreOS / OpenWrt（带 Docker）、飞牛 fnOS、群晖 DSM、Unraid、威联通、TrueNAS、
任意装了 Docker 的 Linux。

### B. 原生 nginx 方案 —— apt 包 + systemd
- 不用 Docker（玩客云这类小机器跑不动，也没有必要）
- 需要确认 nginx 带 `--with-http_dav_module`：Debian/Ubuntu 的 `nginx-core` /
  `nginx-full` / `nginx-extras` 都带；装完脚本会自动 `nginx -V` 校验，不带就自动换包
- 站点直接落在 `/srv/web/out`，配置放 `/etc/nginx/sites-available/studyfree`
- 自启：`systemctl enable nginx`

适用：Debian 11/12/13、Ubuntu 20.04/22.04/24.04（含玩客云刷的 WanOS）。

## 平台矩阵

| 平台 | 路线 | 脚本 | 实测状态 |
| --- | --- | --- | --- |
| iStoreOS 24.10.8 (rockchip/armv8) | A | `install/istoreos-openwrt/install.sh` | ✅ 已实机跑通（站点 200 / 资源 200 / 进度 PUT+GET 正常），测试后已清理 |
| 飞牛 fnOS（NAS） | A | `install/nas-docker/install.sh` | ✅ 长期运行中（8899） |
| 群晖 / Unraid / 威联通 / TrueNAS | A | `install/nas-docker/install.sh` | ⚪ 同构，未逐台验证 |
| 玩客云 WanOS（Ubuntu 20.04 armhf） | B | `install/wanos/install.sh` | ✅ 长期运行中（8899） |
| Debian / Ubuntu 通用 | B | `install/debian/install.sh` | ✅ 在 Ubuntu 20.04（玩客云）上验证；Debian 同构 |
| OpenWrt（无 Docker，原生 nginx） | — | — | ❌ 不支持，见下 |

## 已知差异点

| 维度 | Docker 方案 | 原生方案 |
| --- | --- | --- |
| nginx 来源 | `nginx:alpine` 镜像（自带 dav 模块） | apt 的 nginx-core/full（需校验） |
| worker 用户 | `nginx`（uid 101） | `www-data`（uid 33） |
| 进度目录权限 | `chmod 777` | `chown www-data:www-data` + `775` |
| 站点路径 | 宿主机自定义，容器内 `/srv/web/out` | 直接 `/srv/web/out` |
| 监听端口 | `-p 宿主端口:80` | 配置里直接 `listen` |
| 开机自启 | `docker --restart unless-stopped` | `systemctl enable nginx` |
| 落盘位置 | 需要大分区（OpenWrt 的 overlay 通常很小） | 根分区或外挂存储 |

## 为什么 OpenWrt（不带 Docker）不支持

OpenWrt 官方 feed 里的 nginx 包是裁剪版，**不带 `--with-http_dav_module`**：

- 没有这个模块，站点的静态页面照样能跑，但 `/api/progress/` 的跨设备共享进度就没了
  （只剩各设备浏览器 localStorage 各自为政）
- 能装 Docker 的 OpenWrt/iStoreOS 请走 A 方案；装不了 Docker 又想用共享进度的，
  建议换一台 Debian/Ubuntu 小主机，而不是硬上

## 玩客云补充说明（不在本仓库脚本范围内）

玩客云盒子侧还有几件和“能访问到”相关的事，属于系统配置，不是站点部署：

- **固定 IP**：WanOS 走 netplan，脚本用 `ping + ip neigh` 判断占用，只追加 secondary 别名
  （`/usr/local/sbin/fixed-ip.sh` + `.service` + `.timer`，每 60s 巡检一次）
- **mDNS**：`avahi-daemon`，把 host-name 改成 `s805`，局域网内可用 `s805.local` 访问
- **异地访问**：Tailscale（armhf 官方版）；注意 WanOS 自带的 `tailscale-histb` 是坏二进制，
  装了要 `apt purge` 掉再装官方版
- **盒子直连 GitHub 很慢**：实测 `raw.githubusercontent.com` 不通、Release 资产下载只有
  ~11 B/s。所以给盒子装资源时建议用 `--assets-src` 指向 NAS/本机上的本地副本
  （见 `scripts/fetch-assets.sh` 的 `--src`）

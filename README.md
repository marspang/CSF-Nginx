![聪聪学堂 · 自托管部署套件：一份静态站点，四种平台一键部署，学习进度多设备同步。](assets/banner/banner-a.svg)

<h1 align="center">CSF-Nginx</h1>

<h3 align="center">把「聪聪学堂」搬进自家路由器 / NAS / 小盒子<br>全屋设备共用一份学习进度，装完即用、离线断网也能继续学</h3>

<p align="center">
<a href="https://github.com/marspang/CSF-Nginx/releases"><img src="https://img.shields.io/badge/%E7%89%88%E6%9C%AC-v1.0.0-f1c40f?style=for-the-badge" alt="版本"></a>
<a href="https://github.com/wuwangzhang1216/ChinaTextbookStudyFree"><img src="https://img.shields.io/badge/%E4%B8%8A%E6%B8%B8-%E8%81%AA%E8%81%AA%E5%AD%A6%E5%A0%82-2f81f7?style=for-the-badge" alt="上游"></a>
<img src="https://img.shields.io/badge/%E5%90%8C%E6%AD%A5-%E8%B7%A8%E8%AE%BE%E5%A4%87%E5%AD%A6%E4%B9%A0%E8%BF%9B%E5%BA%A6-fe7d37?style=for-the-badge" alt="同步">
<img src="https://img.shields.io/badge/%E7%A6%BB%E7%BA%BF-%E6%96%AD%E7%BD%91%E5%8F%AF%E7%94%A8-3fb950?style=for-the-badge" alt="离线">
<img src="https://img.shields.io/badge/%E8%A7%84%E6%A8%A1-44%E5%86%8C%20%C2%B7%202166%E8%AF%BE%E8%8A%82%20%C2%B7%202.1GB-e35d6a?style=for-the-badge" alt="规模">
</p>

---

[聪聪学堂](https://github.com/wuwangzhang1216/ChinaTextbookStudyFree)（ChinaStudyFree）是一个**免费、开源、纯公益**的小学全科学习平台——语文 / 数学 / 英语 / 科学，覆盖一到六年级。站点本体是 Next.js 静态导出（纯 HTML/JS/CSS，**不需要 Node 运行时**），因此随便一台能跑 nginx 的设备都能扛。

上游路线图里有两项长期未打的勾：

> - [ ] 云端学习记录与跨设备同步
> - [ ] 离线版 / 校园内网部署包

**这个仓库就是来补这两件事的**：

1. **一键部署** —— 按平台分好的安装脚本，自动搞定 nginx、站点产物、静态资源、开机自启；
2. **跨设备共享进度** —— nginx 用 WebDAV 暴露一个 `state.json`，iPad 上学到 20%，换手机 / 电脑接着学，而不是从 0 重新开始；
3. **平台适配** —— 明确区分 Docker 路线（iStoreOS / NAS）与原生 nginx 路线（Debian / WanOS），已知差异和坑都写进 [docs/PLATFORMS.md](docs/PLATFORMS.md)。

整站跑在你自己的局域网里：**不依赖外网、不上报数据、断网也能继续做题**。一个 2.1GB 的资源包 + 一个约 14MB 站点产物，装完即用。

---

## 支持的设备与实测情况

| 平台 | 部署路线 | 安装脚本 | 实测状态 |
| --- | --- | --- | --- |
| <img src="assets/icons/istore.png" width="26" align="center">&nbsp; **iStoreOS / OpenWrt（带 Docker）** | Docker（`nginx:alpine`） | `install/istoreos-openwrt/install.sh` | ✅ **实机跑通**（站点 200 / 进度 PUT+GET 一致 / 资源包解包正常），按「装完即删」清理干净 |
| <img src="assets/icons/fnos.png" width="26" align="center">&nbsp; **飞牛 fnOS（NAS）** | Docker（`nginx:alpine`） | `install/nas-docker/install.sh` | ✅ **长期运行中**（端口 8899） |
| <img src="assets/icons/wanos.png" width="26" align="center">&nbsp; **玩客云 WanOS（Ubuntu 20.04 armhf）** | 原生（apt + systemd） | `install/wanos/install.sh` | ✅ **长期运行中**，已做断电重启端到端验证 |
| <img src="assets/icons/debian.svg" width="26" align="center">&nbsp; **Debian / Ubuntu** | 原生（apt + systemd） | `install/debian/install.sh` | ✅ 在 Ubuntu 20.04（玩客云）验证；Debian 同构可用 |
| <img src="assets/icons/nas.png" width="26" align="center">&nbsp; 群晖 DSM / Unraid / 威联通 / TrueNAS | Docker（`nginx:alpine`） | `install/nas-docker/install.sh` | ⚪ 同构方案，未逐台验证 |

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/icons/nginx-dark.svg">
    <img src="assets/icons/nginx.svg" height="30" alt="nginx">
  </picture>
  <br>
  四种平台最终都跑在 <b>nginx</b> 之上。<br>
  共享进度由 nginx 的内置 WebDAV 模块提供，<b>不需要任何后端服务或数据库</b>。
</p>

- **架构无要求**：aarch64（iStoreOS / 飞牛）、armhf（玩客云）、x86_64 均已实测或同构可用。
- **纯 OpenWrt（不带 Docker）不支持**：官方 feed 的 nginx 是裁剪版、**不带 `--with-http_dav_module`**，静态页面能开但共享进度没有。能装 Docker 就走 Docker 路线。原因见 [docs/PLATFORMS.md](docs/PLATFORMS.md)。

---

## 它长什么样

部署完，局域网里任意设备打开 `http://<设备IP>:8899/` 就能开始学：

- iPad 做题做到一半 → 手机打开，进度、错题本、连续天数都是接着的
- 同一台设备换地址访问（IP 和 `xxx.local` 混用），进度也是同一份
- 服务器上存的是**权威副本**，设备本地 localStorage 只当缓存；断网时照样能继续做题（不白屏）

---

## 快速开始

先克隆（脚本之间会互相调用，建议整仓库克隆而不是单文件下载）：

```bash
git clone https://github.com/marspang/CSF-Nginx.git
cd CSF-Nginx
```

然后按你的设备选一条：

```bash
# iStoreOS / OpenWrt（带 Docker）
sudo bash install/istoreos-openwrt/install.sh

# 飞牛 fnOS / 群晖 / Unraid / 威联通 / 任何有 Docker 的 NAS
sudo bash install/nas-docker/install.sh

# Debian / Ubuntu（apt 系，原生 nginx）
sudo bash install/debian/install.sh

# 玩客云刷 WanOS（本质是 Ubuntu 20.04 armhf）
sudo bash install/wanos/install.sh
```

脚本会自动完成：装 nginx → 下站点产物 → 下静态资源 → 写 nginx 配置 → 设置进度目录权限 → 起服务并自启 → **自检**（`/`、`/icon.svg` 看状态码，再对 `/api/progress/` 做一次真实的 `PUT → GET → DELETE` 往返，确认共享进度真的可写可读）。

装完会打印访问地址。卸载：

```bash
sudo bash install/<平台>/install.sh --uninstall --root <安装目录>
```

### 常用参数

| 参数 | 说明 |
| --- | --- |
| `--port 8899` | 换监听端口（默认 8899，刻意避开路由器的 80/443） |
| `--root /mnt/sda1/csf` | 指定落盘目录（OpenWrt 的 overlay 通常很小，数据要放别的大分区） |
| `--no-assets` | 先不下 2.1GB 的音频 / 课本页 / 绘本图，只把站点跑起来 |
| `--assets-src /mnt/nas/csf-assets` | 从本地 / NAS 上已有的副本装资源（盒子直连 GitHub 很慢时用这个） |
| `--force` | 强制重新下载站点产物 |

> 站点产物只有 **~14MB**（Release 资产 `csf-core.tar.gz`，带 SHA256 校验）；
> 音频 / 课本扫描页 / 绘本插图合计 **~2.1GB**，由上游项目以 Release 资产（`v1.2.0-assets`）发布，
> 由 `scripts/fetch-assets.sh` 负责拉取与落位。

---

## 目录结构

```
CSF-Nginx/
├── assets/
│   ├── banner/                  README 首图（自包含 SVG，图标已内嵌）
│   └── icons/                   平台图标（iStoreOS / 飞牛 / WanOS / Debian / nginx）
├── conf/studyfree.conf          nginx 站点模板（含 @@占位符@@，脚本负责渲染）
├── install/
│   ├── istoreos-openwrt/        Docker 路线：iStoreOS / OpenWrt
│   ├── nas-docker/              Docker 路线：NAS（含 docker-compose.yml）
│   ├── debian/                  原生路线：Debian / Ubuntu
│   └── wanos/                   原生路线：玩客云 WanOS（+ 盒子前置检查）
├── scripts/
│   ├── lib.sh                   各安装脚本共用的函数（下载 / 校验 / 解包 / 起容器 / 自检）
│   └── fetch-assets.sh          拉取三大静态资源包（支持 --only / --src 本地源）
├── patches/                     前端「共享进度」改造（自己重新构建源码时才需要）
└── docs/PLATFORMS.md            平台矩阵、差异点、已知坑
```

---

## 共享进度是怎么实现的

前端侧（`patches/`，Release 构建产物里已包含）把 zustand 的存储后端从 `localStorage` 换成了一个远端适配器，读写都指向：

```
GET / PUT / DELETE   /api/progress/state.json
```

服务器侧就是 nginx 里这十几行：

```nginx
location /api/progress/ {
    alias @@PROGRESS_DIR@@/;       # 一个独立目录，站点重新部署也不丢进度
    dav_methods PUT DELETE;         # 靠 WebDAV 实现写入，不需要后端服务
    create_full_put_path on;
    client_max_body_size 8m;
    limit_except GET PUT DELETE HEAD OPTIONS { deny all; }   # 只放行必要的几个方法
}
```

配套的前端行为：

- 首屏先把远端进度拉回来，再挂载页面组件（`ProgressHydrationGate`），避免「先显示 0% 再跳变」
- 答题产生的写入会**防抖合并 600ms** 再推，不会每点一下发一个请求
- 关页 / 切后台时立刻补发未发出的写入（`pagehide` / `visibilitychange`）
- 服务器不可达时 **8 秒超时后退回本地缓存**，离线也能继续做题

细节和补丁怎么打，见 [patches/README.md](patches/README.md)。

---

## 上游内容规模（来自聪聪学堂）

本仓库**不改教学内容**，只负责部署与同步。站点自带的资源规模如下：

| 学科 | 版本 | 年级 | 课外故事 |
| --- | --- | --- | --- |
| 数学 | 人教版 | 一至六年级 | — |
| 语文 | 统编版 | 一至六年级 | 188 篇 |
| 英语 | 人教版 PEP | 三至六年级 | 96 篇 |
| 科学 | 教科版 | 一至六年级 | — |

**合计**：44 册教材、2,166 个课节、6,545 道单元练习、779 篇课文、284 篇故事、1,226 道故事阅读题。
（资源覆盖统计，不代表所有题目已通过教师逐题审核。）

上游还提供了**全站 TTS 语音**、**课本原页逐句听读**、**错题本 / 每日任务 / 学习报告**、**连击与成就**等完整学习体验，详见 [上游项目主页](https://github.com/wuwangzhang1216/ChinaTextbookStudyFree)。

---

## 常见问题

**Q：端口 8899 被占了怎么办？**
加 `--port 8900`（或任意空闲端口）重新跑一遍即可；确认端口占用用 `netstat -tln | grep 8899`。

**Q：换设备访问，进度没同步？**
按顺序排查：① `/api/progress/state.json` 能不能 GET 到内容（**首次使用时 404 属正常**——表示服务器上还没有进度，第一台打开的设备会把自己的进度推上去）；② 进度目录权限（Docker 方案 worker 是 uid 101，原生方案是 `www-data`）；③ 浏览器是不是开了无痕 / 隐私模式（localStorage 被禁不影响，但远端请求被拦截就会退回本地）。

**Q：进度会不会被站点升级覆盖掉？**
不会。进度目录和站点目录是分开挂载的，站点产物重装只覆盖 `out/`，`progress-data/` 不动。安装脚本也不会往进度目录里写任何初始文件，所以重复执行安装不会重置已有进度。

**Q：能不能只给 iPad 用、不要共享？**
可以。跳过前端补丁（用上游原始构建产物）就退回各设备独立进度；但本仓库的 Release 产物已经带了共享改造。

**Q：路由器上装完怎么从外网访问？**
本仓库只管局域网。外网访问方式随设备不同（OpenWrt 走端口转发 / Tailscale，NAS 走自带反代或异地组网），不属于站点部署本身。

**Q：资源包 2.1GB 下不动怎么办？**
在 NAS / 电脑上下好，用 `--assets-src /path/to/csf-assets` 指向本地副本即可。玩客云这类小盒子实测直连 GitHub Release 只有 ~11 B/s，见 [docs/PLATFORMS.md](docs/PLATFORMS.md)。

---

## 致谢与许可

- 站点内容来自上游开源项目 **[wuwangzhang1216/ChinaTextbookStudyFree](https://github.com/wuwangzhang1216/ChinaTextbookStudyFree)** —— **聪聪学堂**，一个免费、开源、纯公益的小学全科 AI 学习平台，口号「**学习，从好奇心开始**」。
  本仓库**不修改教学内容**，只做自托管部署、平台适配与进度同步。
  音频 / 课本扫描页 / 绘本插图等静态资源直接取自上游 Release（`v1.2.0-assets`），版权归上游所有（Copyright © 2026 wangzhang wu，MIT License）。
- 本仓库的部署脚本、nginx 配置、进度同步改造同样以开源方式提供，供自用与技术交流，请遵守上游项目的许可与使用条款。

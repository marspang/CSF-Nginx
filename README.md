# CSF-Nginx

**把「小猫头鹰课堂」（ChinaStudyFree）搬到自己的路由器 / NAS / 小盒子上自托管，
并且让家里所有设备共用同一份学习进度。**

站点本身是 Next.js 静态导出（纯 HTML/JS/CSS，不需要 Node 运行时），
所以随便一台能跑 nginx 的设备都能扛。这个仓库做的是三件事：

1. **一键部署** —— 按平台分好的安装脚本，自动搞定 nginx、站点产物、静态资源、开机自启；
2. **跨设备共享进度** —— nginx 用 WebDAV 暴露一个 `state.json`，
   iPad 上学到 20%，换手机/电脑接着学，而不是从 0 重新开始；
3. **平台适配** —— 明确区分 Docker 路线（iStoreOS / NAS）和原生 nginx 路线（Debian / WanOS），
   把已知差异和坑都写在 [docs/PLATFORMS.md](docs/PLATFORMS.md) 里。

---

## 它长什么样

部署完，局域网里任意设备打开 `http://<设备IP>:8899/` 就能开始学：

- iPad 做题做到一半 → 手机打开，进度、错题本、连续天数都是接着的
- 同一台设备换地址访问（IP 和 `xxx.local` 混用），进度也是同一份
- 服务器上存的是权威副本，设备本地 localStorage 只当缓存；断网时照样能继续做题（不白屏）

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

脚本会自动完成：装 nginx → 下站点产物 → 下静态资源 → 写 nginx 配置 →
设置进度目录权限 → 起服务并自启 → **自检**（`/`、`/icon.svg` 看状态码，
再对 `/api/progress/` 做一次真实的 PUT→GET→DELETE 往返，确认共享进度真的可写可读）。

装完会打印访问地址。卸载：

```bash
sudo bash install/<平台>/install.sh --uninstall --root <安装目录>
```

### 常用参数

| 参数 | 说明 |
| --- | --- |
| `--port 8899` | 换监听端口（默认 8899，刻意避开路由器的 80/443） |
| `--root /mnt/sda1/csf` | 指定落盘目录（OpenWrt 的 overlay 通常很小，数据要放别的大分区） |
| `--no-assets` | 先不下 2.1GB 的音频/课本页/绘本图，只把站点跑起来 |
| `--assets-src /mnt/nas/csf-assets` | 从本地/NAS 上已有的副本装资源（盒子直连 GitHub 很慢时用这个） |
| `--force` | 强制重新下载站点产物 |

> 站点产物只有 **~14MB**（Release 资产 `csf-core.tar.gz`，带 SHA256 校验），
> 音频/课本扫描页/绘本插图合计 **~2.1GB**，由上游项目以 Release 资产发布，
> 由 `scripts/fetch-assets.sh` 负责拉取和落位。

---

## 目录结构

```
CSF-Nginx/
├── conf/studyfree.conf          nginx 站点模板（含 @@占位符@@，脚本负责渲染）
├── install/
│   ├── istoreos-openwrt/        Docker 路线：iStoreOS / OpenWrt
│   ├── nas-docker/              Docker 路线：NAS（含 docker-compose.yml）
│   ├── debian/                  原生路线：Debian / Ubuntu
│   └── wanos/                   原生路线：玩客云 WanOS（+ 盒子前置检查）
├── scripts/
│   ├── lib.sh                   各安装脚本共用的函数（下载/校验/解包/起容器/自检）
│   └── fetch-assets.sh          拉取三大静态资源包（支持 --only / --src 本地源）
├── patches/                     前端“共享进度”改造（自己重新构建源码时才需要）
└── docs/PLATFORMS.md            平台矩阵、差异点、已知坑
```

---

## 共享进度是怎么实现的

前端侧（`patches/`，构建产物里已包含）把 zustand 的存储后端从
`localStorage` 换成了一个远端适配器，读写都指向：

```
GET / PUT / DELETE   /api/progress/state.json
```

服务器侧就是 nginx 里这十几行：

```nginx
location /api/progress/ {
    alias @@PROGRESS_DIR@@/;      # 一个独立目录，站点重新部署也不丢进度
    dav_methods PUT DELETE;        # 靠 WebDAV 实现写入，不需要后端服务
    create_full_put_path on;
    client_max_body_size 8m;
    limit_except GET PUT DELETE HEAD OPTIONS { deny all; }   # 只放行必要的几个方法
}
```

配套的前端行为：

- 首屏先把远端进度拉回来，再挂载页面组件（`ProgressHydrationGate`），避免“先显示 0% 再跳变”
- 答题产生的写入会**防抖合并 600ms** 再推，不会每点一下发一个请求
- 关页 / 切后台时立刻补发未发出的写入（`pagehide` / `visibilitychange`）
- 服务器不可达时 8 秒超时后退回本地缓存，**离线也能继续做题**

细节和补丁怎么打，见 [patches/README.md](patches/README.md)。

---

## 实测情况

| 平台 | 结果 |
| --- | --- |
| iStoreOS 24.10.8（Docker 27.3.1, aarch64） | ✅ 用本仓库的 `install/istoreos-openwrt/install.sh` **实机跑通**：站点 `GET /` = 200、进度接口 `PUT` = 201 + `GET` 回读一致（从另一台电脑写入/读取验证）、`scripts/fetch-assets.sh --only textbook-pages` 下载 201.7MB 并正确解出 1582 个文件、课本页正常显示为 `image/jpeg`。按「装完即删」流程清理干净（容器、镜像、安装目录全部移除，未留残留） |
| 玩客云 WanOS（Ubuntu 20.04 armhf, nginx-core 1.18.0） | ✅ 用 `install/wanos/install.sh` 复跑验证通过；站点长期运行（8899），已做断电重启端到端验证 |
| 飞牛 fnOS（Docker） | ✅ 长期运行（8899） |

- OpenWrt 官方 feed 的 nginx **不带 `--with-http_dav_module`**，静态站点能跑、但共享进度没有，
  所以纯 OpenWrt 不在支持范围（能装 Docker 的走 Docker 路线）。见 [docs/PLATFORMS.md](docs/PLATFORMS.md)。
- 系统架构无要求：aarch64 / armhf / x86_64 都实测或同构可用。

---

## 常见问题

**Q：端口 8899 被占了怎么办？**
加 `--port 8900`（或任意空闲端口）重新跑一遍即可；确认端口占用用 `netstat -tln | grep 8899`。

**Q：换设备访问，进度没同步？**
按顺序排查：① `/api/progress/state.json` 能不能 GET 到内容
（**首次使用时 404 属正常** —— 表示服务器上还没有进度，第一台打开的设备会把自己的进度推上去）；
② 进度目录权限（Docker 方案 worker 是 uid 101，原生方案是 www-data）；
③ 浏览器是不是开了无痕/隐私模式（localStorage 被禁不影响，但远端请求被拦截就会退回本地）。

**Q：进度会不会被站点升级覆盖掉？**
不会。进度目录和站点目录是分开挂载的，站点产物重装只覆盖 `out/`，`progress-data/` 不动。
安装脚本也不会往进度目录里写任何初始文件，所以重复执行安装不会重置已有进度。

**Q：能不能只给 iPad 用、不要共享？**
可以。跳过前端补丁（用上游原始构建产物）就退回各设备独立进度；但本仓库的 Release 产物已经带了共享改造。

**Q：路由器上装完怎么从外网访问？**
本仓库只管局域网。外网访问方式随设备不同（OpenWrt 走端口转发 / Tailscale，
NAS 走自带反代或异地组网），不属于站点部署本身。

---

## 致谢与许可

- 站点内容来自上游开源项目 **[wuwangzhang1216/ChinaTextbookStudyFree](https://github.com/wuwangzhang1216/ChinaTextbookStudyFree)**
  （小猫头鹰课堂 · 全科免费、人人可学的小学 AI 学习平台）。
  本仓库**不修改教学内容**，只做自托管部署、平台适配与进度同步。
  音频 / 课本扫描页 / 绘本插图等静态资源直接取自上游 Release（`v1.2.0-assets`），版权归上游所有。
- 本仓库的部署脚本、nginx 配置、进度同步改造同样以开源方式提供，供自用与技术交流，
  请遵守上游项目的许可与使用条款。

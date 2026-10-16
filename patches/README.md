# patches — 前端“跨设备共享进度”改动

仓库里的部署脚本解决的是**服务器侧**的问题（静态站点 + 进度读写接口）。
下面这几个文件解决的是**前端侧**的问题：让学习进度不再只躺在浏览器 localStorage 里。

如果你只是部署一份现成的站点（`install/*/install.sh` 会自动下载已经改好的构建产物
`csf-core.tar.gz`），**这一节可以完全跳过**。
只有当你打算自己从上游源码重新构建站点时，才需要把这些改动打进去。

## 为什么需要改

上游站点把学习进度存在浏览器 localStorage（键名 `csf-progress-v1`）：

- iPad 上学到 20%，换手机打开就是 0%
- 同一台设备用 `192.168.1.10:8899` 和 `nas.local:8899` 访问，也是两份互不相干的进度

改完之后，进度存在服务器上的一个 JSON 文件里（由 nginx 的 WebDAV 暴露）：

```
GET/PUT/DELETE  /api/progress/state.json
```

同一台服务器的所有设备共用这一份，换设备就是接着学。

## 改动清单

| 文件 | 类型 | 说明 |
| --- | --- | --- |
| `src/lib/remoteProgressStorage.ts` | 新增 | 远端存储适配器（合并写入防抖、离线兜底、页面隐藏时补发） |
| `src/components/ProgressHydrationGate.tsx` | 新增 | 首屏 hydration 闸门，等远端进度拉回来再挂载页面组件，避免先渲染 0% 再跳变 |
| `src/store/progress.ts` | 修改 | `createJSONStorage(() => localStorage)` → `remoteProgressStorage`，并加 `skipHydration: true` |
| `src/app/layout.tsx` | 修改 | 用 `<ProgressHydrationGate>` 包住整棵组件树 |

## 怎么应用

```bash
# 进入上游源码目录（git clone wuwangzhang1216/ChinaTextbookStudyFree 后）
cd ChinaTextbookStudyFree/apps/web

# 1) 两个新增文件直接拷进去
cp <本仓库>/patches/remoteProgressStorage.ts   src/lib/
cp <本仓库>/patches/ProgressHydrationGate.tsx  src/components/

# 2) 两处修改打补丁
patch -p0 src/store/progress.ts < <本仓库>/patches/progress-shared.diff
patch -p0 src/app/layout.tsx    < <本仓库>/patches/layout-shared.diff

# 3) 重新构建（需要 node 20+）
cd ../.. && npm install && npm run build
# 产物在 apps/web/out/
```

> 补丁基于上游 `v1.2.0-assets`（base commit `277316e`）。上游 main 若已变动，
> `patch` 可能会提示 hunk 偏移，按上下文人工确认即可 —— 改动本身很小。

## 前端行为细节

- **首次启用**：服务器上还没有 `state.json` 时，用本机已有的 localStorage 进度作为初始基准推上去，之后其它设备打开就能拿到。
- **日常写入**：先写 localStorage（立即生效、离线可用），再防抖 600ms 推到服务器，合并连续答题产生的多次写入。
- **关页兜底**：`pagehide` / 切到后台时立刻补发还没发出去的写入。
- **服务器不可达**：`fetch` 8 秒超时后静默退回本地缓存，不白屏、不阻塞做题。
- **权威副本是服务器**：本机 localStorage 仅作缓存/离线兜底。

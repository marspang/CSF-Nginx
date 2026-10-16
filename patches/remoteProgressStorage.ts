/**
 * 学习进度的「服务器共享」存储适配器。
 *
 * 原来进度只写在浏览器 localStorage 里，换设备或换访问地址就会归零。
 * 这里把进度改成"服务器上存一份、同一台服务器的所有设备共用"：
 *
 *   - 服务器上已有进度：直接用它（所有设备看到的是同一份）
 *   - 服务器上还没有（首次启用）：用本机已有的进度作为初始基准并推上去
 *   - 之后每次变化：先写本地缓存，再防抖推到服务器
 *   - 服务器不可达：退回本地缓存，保证离线也能继续做题，不白屏
 *
 * 注意：远端是权威副本，本机 localStorage 只作为缓存和离线兜底。
 */
import type { StateStorage } from "zustand/middleware";

/** 进度在服务器上的位置，由 nginx 以 WebDAV 方式读写 */
const ENDPOINT = "/api/progress/state.json";
/** 合并连续写入，避免每答题一次就发一个请求 */
const PUSH_DELAY_MS = 600;
const REQUEST_TIMEOUT_MS = 8000;

function hasWindow(): boolean {
  return typeof window !== "undefined";
}

function readLocal(name: string): string | null {
  if (!hasWindow()) return null;
  try {
    return window.localStorage.getItem(name);
  } catch {
    return null;
  }
}

function writeLocal(name: string, value: string): void {
  if (!hasWindow()) return;
  try {
    window.localStorage.setItem(name, value);
  } catch {
    /* 隐私模式 / 配额满：忽略。远端仍然是权威副本 */
  }
}

function dropLocal(name: string): void {
  if (!hasWindow()) return;
  try {
    window.localStorage.removeItem(name);
  } catch {
    /* 同上 */
  }
}

async function request(input: string, init?: RequestInit): Promise<Response> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
  try {
    return await fetch(input, { ...init, signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}

async function pullRemote(): Promise<string | null> {
  if (!hasWindow()) return null;
  try {
    const res = await request(ENDPOINT, { cache: "no-store" });
    if (!res.ok) return null;
    const text = await res.text();
    return text.trim() ? text : null;
  } catch {
    return null;
  }
}

async function pushRemote(value: string): Promise<boolean> {
  if (!hasWindow()) return false;
  try {
    const res = await request(ENDPOINT, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: value,
    });
    return res.ok;
  } catch {
    return false;
  }
}

let pendingValue: string | null = null;
let pushTimer: ReturnType<typeof setTimeout> | null = null;

function cancelPendingPush(): void {
  pendingValue = null;
  if (pushTimer) {
    clearTimeout(pushTimer);
    pushTimer = null;
  }
}

/** 把还没发出去的写入立刻补发（关页 / 切后台时用） */
function flushPendingPush(): void {
  if (pendingValue === null) return;
  const value = pendingValue;
  cancelPendingPush();
  void pushRemote(value);
}

function schedulePush(value: string): void {
  pendingValue = value;
  if (pushTimer) clearTimeout(pushTimer);
  pushTimer = setTimeout(flushPendingPush, PUSH_DELAY_MS);
}

if (hasWindow()) {
  window.addEventListener("pagehide", flushPendingPush);
  window.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "hidden") flushPendingPush();
  });
}

export const remoteProgressStorage: StateStorage = {
  getItem: async (name: string): Promise<string | null> => {
    const local = readLocal(name);
    const remote = await pullRemote();

    if (remote !== null) {
      writeLocal(name, remote);
      return remote;
    }

    // 服务器上还没有进度：把本机这份作为初始基准推上去，
    // 之后其它设备第一次打开就会拿到它
    if (local !== null) void pushRemote(local);
    return local;
  },

  setItem: async (name: string, value: string): Promise<void> => {
    writeLocal(name, value);
    schedulePush(value);
  },

  removeItem: async (name: string): Promise<void> => {
    dropLocal(name);
    cancelPendingPush();
    if (!hasWindow()) return;
    try {
      await request(ENDPOINT, { method: "DELETE" });
    } catch {
      /* 删不掉就算了，下一次写入会覆盖 */
    }
  },
};

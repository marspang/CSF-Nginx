"use client";

import { useEffect, useState } from "react";
import { useProgressStore } from "@/store/progress";

/** 服务器一旦不响应，也不能让页面卡在启动画面上 */
const HYDRATION_TIMEOUT_MS = 1500;

/**
 * 进度改成服务器共享后，首屏需要等一次网络往返才能拿到"真正"的进度。
 *
 * 这个门后面的组件全部等进度就绪后才挂载，原因是：
 * store 初始值是默认值（5 颗红心、0 金币…），如果组件在进度就绪前就渲染，
 * 不仅会显示错误数据，更危险的是 DailyRewardWatcher 这类会写 store 的组件
 * 会在默认值上做判断，把错误进度当成新进度推回服务器，覆盖掉真实进度。
 */
export function ProgressHydrationGate({ children }: { children: React.ReactNode }) {
  const [ready, setReady] = useState(false);

  useEffect(() => {
    if (useProgressStore.persist.hasHydrated()) {
      setReady(true);
      return;
    }

    let settled = false;
    const settle = () => {
      if (settled) return;
      settled = true;
      setReady(true);
    };

    const timer = setTimeout(settle, HYDRATION_TIMEOUT_MS);
    const unsubscribe = useProgressStore.persist.onFinishHydration(settle);
    void useProgressStore.persist.rehydrate();

    return () => {
      clearTimeout(timer);
      unsubscribe();
    };
  }, []);

  if (!ready) {
    // 用页面底色占位：局域网里通常只有几十毫秒，视觉上基本无感
    return <div className="min-h-screen bg-bg-soft" aria-busy="true" />;
  }

  return <>{children}</>;
}

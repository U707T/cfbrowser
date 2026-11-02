# 往返缓存（Back-Forward Cache）设计 v0.1

> 状态：规划（未实现）。本文只描述现状、目标结构、实施切片与验收口径，
> 代码改动以"阶段"为单位落地，每个阶段都能独立发版、独立回滚。

## 0. 一句话

把「**一个标签 = 一条 Flutter 路由 = 一个 WebView，切走就 dispose**」改成
「**浏览器页常驻 + 每个标签一个受池控的后台 WebView**」，再叠加 Android
原生 BFCache 开关，让切标签与后退/前进都不重新加载页面。

## 1. 现状（代码事实，不是印象）

| 事实 | 位置 |
|---|---|
| 一个 `WebViewPage` 对应一个标签；切标签用 `pushReplacement` 换掉整条路由 | `lib/pages/webview_page.dart:909-916` |
| 路由被替换 → `dispose()` → `_controller?.dispose()`，WebView 原生实例随之销毁 | `lib/pages/webview_page.dart:186-209` |
| 新页面在 `onWebViewCreated` 里用 `tab.url` 重新 `loadUrl` | `lib/pages/webview_page.dart:597-612` |
| 标签模型只保存"URL + URL 级历史"，**明确不保存**滚动位置与表单状态 | `lib/models/browser_tab.dart:1-14` |
| 标签面板底部自己写着"切回标签会重新加载页面，滚动位置暂不保留" | `lib/widgets/browser/browser_tabs_sheet.dart:166-171` |
| 会话令牌（`WebViewUse`）的生命周期是"WebViewPage 从创建到 dispose" | `lib/pages/webview_page.dart:186-208, 245-260` |
| Android WebView 的 BFCache **默认关闭**，需要应用显式打开；androidx.webkit 1.15.0 已在依赖里 | `android/app/build.gradle.kts:183` |

后果（当前版本可复现）：

1. **切标签 = 冷启动一个页面**：白屏 → 重新发请求 → 重新执行 JS，登录页/长贴滚动位置/未提交表单/视频进度全丢。
2. **同标签后退/前进也大概率重载**：Android WebView 没开 BFCache 时 `goBack()` 会重新加载；`_goBack()` 在 WebView 历史用尽后还会退化成 `loadUrl()`（`webview_page.dart:866-885`），DOM 同样丢。
3. 每次切换都在做一次"原生 view 销毁 + 新建"，和 `EmbeddedBrowserControllerPool` 已经踩过的"创建/销毁风暴"是同一类问题（`lib/services/embedded_browser_controller_pool.dart:1-30` 的注释就是这个教训）。
4. `dispose()` 不 await `_controller.dispose()`，切标签瞬间新旧两个 WebView 会短暂重叠。

## 2. 目标 / 非目标

**目标**

- 切回标签：不白屏、不重复请求，滚动位置 / 表单输入 / 媒体播放位置保留。
- 同标签后退/前进：页面不重新请求、不重新执行 JS。
- 内存可控：后台保活数量有上限、按设备内存分档，低内存时主动回收。
- 无痕标签不进保活池、不落盘。
- 不改变代理 / MITM / 加密语义（范围外仍然隧道直通）。

**非目标**

- 不做进程被杀后的状态恢复（只恢复 URL，见 L3）。
- 不做 DOM 序列化快照（成本高、还原度差）。
- 不缓存 POST 结果、下载、页面提交动作。
- 不追求"推翻 WebView 用 RenderView"这类重写。

## 3. 三层设计

### L1 · 标签保活（Flutter 层，收益最大）

```
BrowserShellPage（一条路由，常驻）
└── IndexedStack
    ├── BrowserPane(tab A)   ← InAppWebView + 页面级状态
    ├── BrowserPane(tab B)   ← 后台，pauseTimers / 媒体暂停
    └── BrowserPane(tab C)
```

- `BrowserShellPage` 只负责：标签栏、地址栏、标签面板、菜单、返回键策略。
- `BrowserPane` 只负责：一个 `InAppWebView` + 它的加载/标题/历史回调。
- `BrowserPanePool`（新文件 `lib/services/browser/browser_pane_pool.dart`）负责容量：
  - 容量 = **1 前台 + N 后台**，N 默认 2；按设备内存分档：≤4 GB → 1，6–8 GB → 2，≥12 GB → 3。
  - LRU 淘汰；淘汰前 `capturePaneState()`（scrollX/scrollY、表单焦点值、媒体时间）存进 `BrowserTab`，重建后 `restorePaneState()`。
  - 关闭标签 / 全部关闭 / `onTrimMemory` 时立即销毁，不留冷却。
- 后台 pane 的生命周期动作（必须成对）：
  - Android：`pauseTimers()`、`evaluateJavascript` 暂停 `<video>/<audio>`；
  - Windows/Linux：保持挂载但不再绘制（`IndexedStack` 只画当前 index，需实测后台 WebView 是否仍参与合成）。
  - 回到前台：`resumeTimers()`，**不** reload。
- 与"关键 WebView 独占"统一：登录、CF 验证、WebViewHttpAdapter 请求前，
  先 `BrowserPanePool.suspendAndDrain()`（复用 `EmbeddedBrowserControllerPool`
  的 750ms 冷却思路），避免多个原生 view 同时存在。

### L2 · 原生 BFCache（同标签往返）

- **Android**：`WebViewCompat.setBackForwardCacheEnabled(webView, true)`，
  先 `WebViewFeature.isFeatureSupported(WebViewFeature.BACK_FORWARD_CACHE)` 探测
  （androidx.webkit ≥ 1.9.0 提供该 API，本项目依赖 1.15.0）；
  必须在**首次 loadUrl 之前**调用。
  拿 WebView 实例有两条路：
  - **方案 A（先做，改动最小）**：`MainActivity` 注册 `com.fluxdo/bfcache`
    MethodChannel，`enable()` 时从 decorView 下找当前浏览器页的 `android.webkit.WebView`
    （按 view tag / 可见性 + 只认当前 route 顶层的那个），逐个开关。
    代价：依赖视图树遍历，多 WebView 场景要靠白名单限定；收益是当天能验证。
  - **方案 B（长期正解，成本高）**：vendor `flutter_inappwebview_android`
    并在 `InAppWebViewSettings` 里加 `useBackForwardCache`，Dart 侧透传。
    仓库已有 vendor linux/windows 插件的先例（`pubspec.yaml:169-175`），
    但要多维护一个包 + platform interface 版本对齐。
- **Windows（WebView2）**：Chromium 内核自带部分 BFCache，需实测确认
  （WebView2 没有暴露开关）；不生效时只能靠 L1 + 快照。
- **Linux（WebKitGTK）**：page cache 由引擎托管，同样需实测。
- **验证方式（必须内置，否则等于没做）**：页面注入探针

  ```js
  window.addEventListener('pageshow', e => {
    window.flutter_inappwebview.callHandler('bfcacheProbe', {
      persisted: e.persisted,
      navType: performance.getEntriesByType('navigation')[0]?.type, // back_forward
    });
  });
  ```

  Dart 侧收到后写进诊断页计数（`lib/pages/perf_diagnostics_page.dart`）。
  只有 `persisted === true` 才算 BFCache 命中。

### L3 · 冷恢复（只做诚实的那部分）

- 进程重启后恢复 `browser_tabs_v1` 里的 URL + `scrollY/scrollX`；
- 不尝试恢复 DOM、不尝试恢复 POST 结果；
- 文档与 UI 文案（标签面板那行提示）随阶段更新，别夸大。

## 4. 需要的代码改动

| 文件 | 改动 |
|---|---|
| `lib/pages/webview_page.dart`（1279 行） | 拆成 `BrowserShellPage` / `BrowserPane` / `BrowserToolbar` / `BrowserFindSheet` / `BrowserLinkInterceptor` 五个文件；这是 L1 的前置条件，也是当前最大的结构债 |
| `lib/services/browser/browser_pane_pool.dart`（新） | 容量、LRU、内存分档、suspend/drain、统计 |
| `lib/services/browser/browser_tabs_service.dart` | `create/close/closeAll` 与池联动；淘汰时回写快照 |
| `lib/models/browser_tab.dart` | 增加 `scrollX/scrollY`（持久化）；`paneState` 不进 JSON 或单独 key |
| `lib/pages/webview_page.dart` 会话令牌调用点 | `WebViewUse` 的结束边界从"页面 dispose"改为"pane 释放 / 失活超时" |
| `android/.../MainActivity.kt` 或新文件 | BFCache MethodChannel（方案 A） |
| `lib/pages/perf_diagnostics_page.dart` | 池统计 + BFCache 命中率 |
| `test/services/browser_pane_pool_test.dart`（新） | LRU / 容量 / 分档 / 淘汰顺序 |

## 5. 分阶段实施（每阶段独立可发版）

| 阶段 | 内容 | 预估 | 验收 |
|---|---|---|---|
| **P0** | Android BFCache 开关 + `pageshow` 探针 + 诊断计数，不改页面结构 | 0.5–1 天 | 后退后 `persisted === true`；站内文章页后退不重新请求 |
| **P1** | 拆 `webview_page.dart`，引入 `BrowserShellPage` + `BrowserPane`，池容量 1+1，开关默认关 | 3–5 天 | 切标签无白屏；抓包确认无第二次全量请求；内存增量 < 80 MB |
| **P2** | 滚动/表单快照、淘汰恢复、内存分档、低内存清理 | 2–3 天 | 被淘汰的标签回来能回到原滚动位置；低端机不 OOM |
| **P3** | 无痕 / 登录 / CF 验证 / 下载场景联调，默认开启 | 2–3 天 | 无痕标签不进池；登录与 CF 验证期间池内空 |

**先做 P0 的理由**：即使不做 L1，"同标签后退"也是最高频的往返场景，
而且改动面最小、可单独回滚。

## 6. 风险与对策

| 风险 | 对策 |
|---|---|
| 内存：每个后台 WebView 带独立渲染进程，低端机上 2 个后台就可能被系统杀 | 内存分档 + `onTrimMemory` 立即清池 + 默认只保 1 个后台 |
| 会话令牌悬挂：pane 常驻后 `WebViewUse` 不再随 dispose 结账，`_t` 可能长期不归还 | 结账点改到"pane 释放 / 失活 N 分钟 / 切到站外"；单测覆盖 |
| cookie 对账风暴：后台 pane 的 XHR 轮换仍会触发 `CookieStoreObserver` | 后台 pane 只对账不 sweep；对账间隔与 L1 状态绑定 |
| 多原生 view 叠加合成导致掉帧 | 后台 pane 不参与合成（需实测 IndexedStack 行为）；关键 WebView 前 suspend 池 |
| 无真机/模拟器，UI 结论无法本地验证 | 所有 L1/L2 结论标注"待真机验证"，并给出复核步骤（见下） |

## 7. 复核步骤（真机）

1. 打开 `https://linux.do` 任意长贴 → 滚到中部 → 切到另一个标签 → 切回：位置与内容应原样。
2. 在有输入框的页面输入一半 → 切标签 → 切回：输入内容还在。
3. 同一标签内点进帖子 → 后退：抓包应无新的文档请求；控制台 `pageshow.persisted === true`。
4. 打开无痕标签 → 访问站点 → 关闭 → 诊断页池计数应回到 0，且 `browser_tabs_v1` 里查不到该 URL。
5. 登录 / CF 验证期间：诊断页池内 pane 数应为 0（已 drain）。
6. 后台保活达到上限后继续开标签：最久未用的标签被淘汰，切回时按快照恢复。

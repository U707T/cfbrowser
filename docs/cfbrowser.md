# cfbrowser 移植说明

> 上游：[1molchuan/fluxdo](https://github.com/1molchuan/fluxdo)（cfluxdo，GPL-3.0）
> 本移植同样以 GPL-3.0 发布，保留原作者署名。

## 1. 这个项目是什么

cfbrowser = **把 cfluxdo 里那套「Cloudflare 边缘直连」网络层，从「论坛客户端的内部零件」
提升为「浏览器的主干」**。

上游已经把三件事做完了，且做得比任何手工配置都好：

| 能力 | 上游实现 |
|---|---|
| 干净解析 | DoH（公共 DNS 直连 IP 并发竞速，答案只保留 CF 网段） |
| 隐藏 SNI | ECH（Rust `core/doh_proxy` 自己做握手，内层 SNI = 目标域） |
| 稳定出口 | 竞速出赢家 IP 后钉死，保证 CF 看到同一个来源 IP |

问题只有一个：**ECH/MITM 范围和优选目标都被写死成 `linux.do`**，因为它的产品形态是论坛客户端。
`WebViewPage` 其实已经是个带地址栏、书签、历史的完整浏览器 —— 缺的只是「开门」。

cfbrowser 做三件事：改名、开门、把范围变成设置项。

## 2. 与上游的差异

### 2.1 项目重命名

| 位置 | 变化 |
|---|---|
| `pubspec.yaml` | `name: fluxdo` → `name: cfbrowser`；描述、版本号（1.0.0）重置 |
| Dart 导入 | 全仓 `package:fluxdo/` → `package:cfbrowser/`（1121 处） |
| Android | `android:label` → `cfbrowser`；`applicationId` → `com.github.molchuan.cfbrowser` |
| Linux | `BINARY_NAME` / `APPLICATION_ID` / 窗口标题 / `.desktop` 文件名 → cfbrowser |
| Windows | `project()` / `BINARY_NAME` → cfbrowser |

**刻意没动**（动了就会编译或运行失败）：

- MethodChannel 名：`cfluxdo/wpe_tls`、`com.fluxdo/profile_install`
- 原生源文件名：`packages/flutter_inappwebview_linux/...` 下的 `cfluxdo_*.cc`
- 深链 scheme：`fluxdo://`、`discourse://`
- `packages/fluxdo_render`：独立 workspace 包，与本次移植无关

### 2.2 首页换成浏览器

- 新增 `lib/pages/browser_home_page.dart`：地址栏 + 加速范围快捷入口 + 出口 IP 状态 + 最近访问。
- `lib/main.dart` 的 `home` 从 `MainPage()` 换成 `BrowserHomePage(onOpenForum: ...)`，
  论坛列表改为从标题栏的图标 push 进去（用回调注入，避免 pages 反向 import `main.dart`）。
- 所有跳转仍走 `WebViewPage`，因此复用同一套 `WebViewHttpAdapter`
  （请求走真 Chrome/WebKit 内核，TLS 指纹与浏览器一致）与本地网关。

### 2.3 加速范围可配置（核心改动）

| 文件 | 改动 |
|---|---|
| `lib/services/browser/browser_scope_service.dart` | **新增**。持久化 MITM/ECH 域名范围，默认 `['linux.do']`；`normalizeHost` 支持直接粘贴 URL、去掉 `*.` 前缀与端口 |
| `lib/services/network/doh_proxy/proxy_leaf_trust.dart` | `mitmHosts` 从 `static const ['linux.do']` 改成读 `BrowserScopeService`；`_preallowHosts`（Linux WPE 预放行清单）改为「已知子域 + 配置范围及其 `www.`/`cdn.` 变体」 |
| `lib/services/network/doh_proxy/doh_proxy_ffi.dart` | 下发 `mitm_hosts` 时去掉平台判断，统一走 `ProxyLeafTrust.mitmHosts`，让移动端和桌面端语义一致 |
| `lib/services/network/doh/network_settings_service.dart` | `preconnectHosts` 跟随范围；删除写死的 `_linuxDoHost` |
| `lib/pages/browser_scope_page.dart` | **新增**。编辑范围 + 固定出口 IP，保存后 `restartProxy()` |
| `lib/main.dart` | 启动序列里加 `BrowserScopeService.instance.initialize(prefs)` |

范围语义（来自 Rust `proxy.rs` 的 `in_mitm_scope`）：

- **范围内**：本地网关接管 → 设备 CA 现签叶子 → 自己发 ECH 握手 → 钉住/竞速的 CF 边缘 IP。
- **范围外**：`CONNECT` 隧道直通，端到端 TLS —— **不解密、不加速、不共享出口 IP**。
- `mitm_hosts` 为空时 Rust 视为「除 `challenges.cloudflare.com` 外全部 MITM」，
  所以本移植始终下发非空范围，避免退化成「全站解密」。

### 2.4 浏览器能力（1.1.0）

| 能力 | 实现 |
|---|---|
| 多标签页 | `BrowserTabsService` 全局保存标签与 URL 级历史；`BrowserTabsSheet` 管理切换/关闭；切标签重建 WebView，后退/前进优先走 WebView 历史，走不通时回落到标签历史 |
| 无痕标签 | `WebViewSettings` 开 `incognito`，跳过 `WebViewUse` cookie 重灌与 `CookieStoreObserver` 回写；不写 `webHistoryProvider`，不参与标签持久化 |
| 页内查找 | `FindInteractionController.findAll/findNext/clearMatches`，Android 走 `WebView.findAllAsync`，桌面映射到 WebKitGTK / WebView2 |
| 桌面版网站 | 按标签覆盖桌面 UA，并打开 `useWideViewPort` / `loadWithOverviewMode`；`setSettings` 后 reload |
| 工具栏 | 底部后退/前进/停止/刷新/主页/分享；菜单含新建标签、无痕标签、查找、桌面版、书签与历史 |

### 2.5 下载加速

`DownloadService` 优先调用 `lib/services/download/segmented_download.dart`：

- 先用 1 字节 Range 探测服务端的 `206 / Content-Range` 支持与文件总长；
- ≥ 2 MB 才分段，分段大小按 512 KB–4 MB 自适应，最多 4096 段；
- 初始 4 连接，每 2 秒按吞吐（>768 KB/s 扩容、<192 KB/s 缩容）和重试错误在 2–6 之间调整；
- 每段独立重试 2 次，带 `If-Range` 防止文件在下载中被替换；
- 服务端忽略 Range、返回 200、分段异常、文件过小时回退原来的 Dio 单连接下载；
- 临时文件仍由 `DownloadReservation` 独占创建/清理，成功后原子 rename。

### 2.6 启动器图标

- 设计：浏览器窗口 + 地球（经典）/ 闪电（现代）；纸色 `#F0F0F3`、墨色 `#1C1C1E`、琥珀 `#FFB003`
- Android：自适应前景（日/夜）、单色（Android 13 主题图标）、旧版 48–192 px mipmap
- 桌面：Windows `.ico`（16–256 px）、Linux/Flatpak 复用 256 px 预览图
- 源文件与生成脚本：`tool/launcher_icon/*.svg`、`tool/generate_launcher_icons.py`；
  改设计后重新运行脚本即可同步所有产物

### 2.7 包体

- **原生库压缩**：`android/app/build.gradle.kts` 设 `packaging.jniLibs.useLegacyPackaging = true`，
  `.so` 以 deflate 压进 APK，安装时由系统解压。仅这一步 arm64 包 105 MB → 约 61 MB；
  代价是安装后占用增加约 30 MB、首次启动多一次解压。
- **字体子集**：`tool/subset_fonts.py` 把 MiSans 从 20.1 MB 裁到 4.6 MB（GB2312 + 仓库内出现过的字符）；
  生僻字回落到系统字体。`MojianSerif` 已是 GB2312 子集，保持原样。
- 两项叠加后实测 arm64 APK **50.0 MB**（v1.0.0 为 105 MB，-52%），armv7 48.9 MB（原 97.4 MB）。
  后续若改走 AAB / Play，可去掉 `useLegacyPackaging` 让商店按设备下发原生库。

## 3. 构建

与上游一致，前置要求：Flutter 3.47 / Dart ^3.13、Android SDK、NDK 27.3、
Rust 工具链 + `cargo-ndk`（`aarch64-linux-android`、`armv7-linux-androideabi`）。

```bash
git clone --recurse-submodules <本仓库> cfbrowser
cd cfbrowser
dart run melos bootstrap
dart run tool/project_prep.dart app
dart tool/flutterw.dart build apk --release --target-platform android-arm64 \
  --build-name 1.0.0 --build-number 2026102901
```

桌面预览版（Linux）见 `tool/flatpak_build.sh`；Windows 用
`dart tool/flutterw.dart build windows --release`。

> ⚠️ Flatpak 清单（`flatpak/com.github.molchuan.cfluxdo.yml`）**尚未改名**，
> 单独打包 Linux 时需要一并改成 `...cfbrowser`。

## 4. 验证清单

编译产物拿到手后，按顺序验证（一次只改一个变量）：

1. **能编译**：`flutter analyze` 应无 error；`proxy_leaf_trust.dart` 与
   `doh_proxy_ffi.dart` 是本移植改动最集中的两处。
2. **网关起来**：设置 → 网络，状态应显示「代理运行中」并给出端口（默认 41215）。
3. **范围生效**：把 `example.com` 加进加速范围 → 保存（网关重启）→ 打开 `https://example.com`，
   应在证书列表里看到由设备 CA 现签的叶子；从范围里移除后再开，应回落到真证书。
4. **出口钉住**（关键指标，不是延迟）：
   ```bash
   for i in 1 2 3 4 5; do curl -s https://linux.do/cdn-cgi/trace | grep '^ip='; done
   ```
   5 次结果一致 = 钉住了；每次都变 = 没钉住（大概率是范围没下发或网关没重启）。
5. **ECH 真的用上**：Chrome/WebView 抓 `chrome://net-export`，看 ClientHello 外层 SNI
   是否为 `cloudflare-ech.com`；若仍是明文目标域名，说明 ECH 没生效。

## 5. 已知限制

- **只对「托管在 Cloudflare 且启用 ECH」的站点有效**。范围外的站点即使被加进来，
  只要不在 CF 上、或没开 ECH，仍然走隧道直通 —— 这不是翻墙工具。
- **同一个 IP 只服务同一个站点**：上游的竞速目标是范围里的第一个域名（默认 `linux.do`），
  多域名共用一个赢家 IP。CF 所有边缘都认任意 Host，所以大多数情况下没问题，
  但如果站点分布在不同的 CF 区域，可能不是各自最快。
- **范围越大，设备 CA 参与解密的场景越多**。默认只保留 `linux.do` 是有意的。
- **上游的 `帮助优选`（众包上报）仍然默认关闭**，打开会把测量数据与 linux.do 账号身份绑定。

## 6. 回滚

只想恢复论坛首页：把 `lib/main.dart` 的 `home` 改回
`const OnboardingGate(child: PreheatGate(child: MainPage()))`。
范围相关改动是叠加式的，回滚 `proxy_leaf_trust.dart` 的 `mitmHosts` getter
即可退回上游行为（`linux.do` 单个域）。

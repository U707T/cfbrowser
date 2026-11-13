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
- 冷启动直接进 `BrowserHomePage`，不再经过 `OnboardingGate` / `PreheatGate`；
  `AppStartup` 的 priming/预加载推迟到进入论坛或真正打开站内页面时。
- 论坛、书签、下载、加速范围、设置统一收进首页右上角菜单；首页只保留地址栏、
  加速状态、快捷访问、标签页和最近访问。
- **DoH / 优选**放在右上角（闪电按钮，另有一条菜单项）：直达 `NetworkSettingsPage`，
  本地优选、重新优选、DoH 服务器都在那一页；首页的加速状态条整行可点，进同一个页面。
- 快捷访问（Via 风格）：4 列站点图标 + 名称，末尾「添加」自定义网址；
  长按可打开/编辑/删除，最多 12 个，写入 `browser_quick_links_v1`。

### 2.3 加速范围可配置（核心改动）

| 文件 | 改动 |
|---|---|
| `lib/services/browser/browser_scope_service.dart` | **新增**。持久化 MITM/ECH 域名范围，默认 `['linux.do', 'ldstatic.com']`；`normalizeHost` 支持直接粘贴 URL、去掉 `*.` 前缀与端口；`coveredHosts` 给出交给 Rust 的覆盖域名 |
| `lib/services/network/doh_proxy/proxy_leaf_trust.dart` | `mitmHosts` 从 `static const ['linux.do']` 改成读 `BrowserScopeService`；`_preallowHosts`（Linux WPE 预放行清单）改为「已知子域 + 配置范围及其 `www.`/`cdn.` 变体」 |
| `lib/services/network/doh_proxy/doh_proxy_ffi.dart` | 下发 `mitm_hosts` 时去掉平台判断，统一走 `ProxyLeafTrust.mitmHosts`，让移动端和桌面端语义一致 |
| `lib/services/network/doh/network_settings_service.dart` | `preconnectHosts` 跟随范围；`extraCoveredHosts` 跟随范围（+ 静态资源主机 + atlas/cfhub）；删除写死的 `_linuxDoHost` |
| `lib/pages/browser_scope_page.dart` | **新增**。编辑范围 + 固定出口 IP，保存后 `restartProxy()` |
| `lib/main.dart` | 启动序列里加 `BrowserScopeService.instance.initialize(prefs)` |

范围语义（来自 Rust：`proxy.rs` 的 `in_mitm_scope` + `edge_pin.rs` 的 `is_covered`）：

- **范围内**：本地网关接管 → 设备 CA 现签叶子 → 自己发 ECH 握手 → 钉住/竞速的 CF 边缘 IP。
- **范围外**：`CONNECT` 隧道直通，端到端 TLS —— **不解密、不加速、不共享出口 IP**。
- **两套匹配语义现在一致**：`mitm_hosts` 与 `extra_covered_hosts`（决定钉哪个出口）
  都按**子域后缀**匹配（后者自 core/doh_proxy `f584d0e` 起，上游 `b45f73c`）。
  范围里写 `ldstatic.com` / `example.com` 就覆盖它们所有子域的 MITM 与钉出口，
  不用再逐个列 `cdn` / `cdn3` / `ping`。`BrowserScopeService.staticAssetHosts`
  只在桌面端 WPE 预放行证书时用（子资源证书错误不回调，只能逐主机放行）。
- **默认范围不是只有主站**：`ldstatic.com` 是 L 站的静态资源域（图片/表情/
  消息总线/直传），高墙地区对它同样是明文 SNI RST，漏掉它就表现为「站内图片
  全 502」（上游 `23e0c32b` 的实测结论）。
- `mitm_hosts` 为空时 Rust 视为「除 `challenges.cloudflare.com` 外全部 MITM」，
  所以本移植始终下发非空范围，避免退化成「全站解密」。

### 2.4 浏览器能力（1.1.0）

| 能力 | 实现 |
|---|---|
| 多标签页 | `BrowserTabsService` 全局保存标签与 URL 级历史；`BrowserTabsSheet` 管理切换/关闭；切标签重建 WebView，后退/前进优先走 WebView 历史，走不通时回落到标签历史 |
| 无痕标签 | `WebViewSettings` 开 `incognito`，跳过 `WebViewUse` cookie 重灌与 `CookieStoreObserver` 回写；不写 `webHistoryProvider`，不参与标签持久化 |
| 页内查找 | `FindInteractionController.findAll/findNext/clearMatches`，Android 走 `WebView.findAllAsync`，桌面映射到 WebKitGTK / WebView2 |
| 桌面版网站 | 按标签覆盖桌面 UA，并打开 `useWideViewPort` / `loadWithOverviewMode`；`setSettings` 后 reload |
| 多窗口 | `window.open` / `target=_blank` 叠一页内置浏览器（`WebViewPage.allowPopups`）：只认用户手势触发，不开 `javaScriptCanOpenWindowsAutomatically`；网页 `window.close()` 关掉自己那页，弹窗的标签在关闭时一并回收并把活动标签还给打开它的页面 |
| 工具栏 | 底部后退/前进/停止/刷新/主页/分享；菜单含新建标签、无痕标签、查找、桌面版、书签与历史 |

> 往返缓存（BFCache）的现状、三层设计与分阶段实施方案见
> [`docs/bfcache-design.md`](bfcache-design.md)。

### 2.5 下载加速

`DownloadService` 优先调用 `lib/services/download/segmented_download.dart`：

- 先用 1 字节 Range 探测服务端的 `206 / Content-Range` 支持与文件总长；
- ≥ 2 MB 才分段，分段大小按 512 KB–4 MB 自适应，最多 4096 段；
- 初始 2 连接，每 2 秒按吞吐（>768 KB/s 扩容、<192 KB/s 缩容）和重试错误在 1–3 之间调整；
- 每段独立重试 2 次，带 `If-Range` 防止文件在下载中被替换；
- 45 秒没有新字节就中止分段、冷却 10 分钟并回退单连接，避免大文件下到中途卡死 App；
- 服务端忽略 Range、返回 200、分段异常、文件过小时回退原来的 Dio 单连接下载；
- 临时文件仍由 `DownloadReservation` 独占创建/清理，成功后原子 rename。

### 2.6 启动器图标

- 设计：Claude 美学「Warm Orb」——暖纸/深墨渐变底 + 球体 + 轨道；
  经典为陶土球体 + 墨/奶油轨道，现代为墨色/奶油球体 + 陶土轨道
- 色板：暖纸 `#FCF8F0`→`#E7DED0`、深墨 `#2B2521`→`#191614`、陶土 `#D97757`
- Android：自适应前景（日/夜）、单色（Android 13 主题图标）、旧版 48–192 px mipmap
- 标记占比：`MARK_RATIO = 0.70`（标记 bbox 宽 ÷ 可见区宽，按定稿参照图实测）。自适应层按中央
  72/108 换算成 `FG_SCALE = 0.6669`，旧版 PNG 整张即可见区（`LEGACY_SCALE ≈ 1.0`）；0.70 距
  66dp 安全圈仍有余量，圆形遮罩不切轨道。改这个数只动 `MARK_RATIO`，脚本会重算两套 scale
- 几何：球 R223（直径占图标 43.5%）、轨道中心线 374×136、线宽 16、倾角 -22°；轨道前后分段——
  后半圈画在球体之下、前半圈补在球体之上，环/球比例不能收紧，否则后半圈被球吃掉后环会读成一道斜杠
- 轨道点：圆心压在轨道中心线上（参数角 -18°）。早期版本偏在内圈约 10 单位，看起来是浮着的
- 投影：球底下一颗独立柔影（圆 + 径向渐变 + 纵向压扁，rx248/ry76/球心下 303），矢量图没有模糊，
  直接画椭圆渐变会在上下边缘留硬边
- 桌面：Windows `.ico`（16–256 px）、Linux/Flatpak 复用 256 px 预览图
- 源文件与生成脚本：`tool/launcher_icon/*.svg`、`tool/generate_launcher_icons.py`；
  改设计后重新运行脚本即可同步所有产物

### 2.7 包体

- **原生库压缩**：`android/app/build.gradle.kts` 设 `packaging.jniLibs.useLegacyPackaging = true`，
  `.so` 以 deflate 压进 APK，安装时由系统解压。仅这一步 arm64 包 105 MB → 约 61 MB；
  代价是安装后占用增加约 30 MB、首次启动多一次解压。
- **字体子集**：`tool/subset_fonts.py` 把 MiSans 从 20.1 MB 裁到 4.6 MB（GB2312 + 仓库内出现过的字符）；
  生僻字回落到系统字体。`MojianSerif` 已是 GB2312 子集，保持原样。
- 两项叠加后实测 arm64 APK **50.4 MB**（v1.0.0 为 105 MB，-52%）。
  1.2.2 起只出 arm64 一个包（armv7 的机器已基本退出使用）。
  后续若改走 AAB / Play，可去掉 `useLegacyPackaging` 让商店按设备下发原生库。

## 2.8 签名（1.2.2 起固定）

以前的 Release 是 **CI runner 每次现生成的 debug keystore** 签的：四张证书指纹各不相同
（v1.1.6 `90a5cc8c` / v1.1.7 `6537a63b` / v1.2.0 `87a21031` / v1.2.1 `e2fa3beb`），
所以每次更新都必须卸载重装，连覆盖升级都做不到。

现在固定成一把发布密钥：

- 密钥在**仓库外** `/workspace/cfbrowser-keys/`（jks + 口令，见那里的 README）
- GitHub secrets：`KEYSTORE_B64` / `KEYSTORE_PASSWORD` / `KEY_ALIAS` / `KEY_PASSWORD`
- workflow 里 `Decode signing keystore` 解出 `android/key.properties`，
  缺 secret 直接硬失败；`Verify APK signing` 再比对两个 APK 的证书指纹，
  回落到 debug 签名就失败
- 证书 SHA-256：`33:DF:57:5B:95:F9:4A:2B:A1:06:9C:48:01:28:25:09:E0:E4:92:01:E3:24:5B:80:BA:B6:20:27:D4:3E:35:81`

> ⚠️ v1.2.1 及更早的包用的是随机 debug 证书，**装过那些版本的用户必须先卸载一次**
> 才能装 1.2.2；此后所有版本可以互相覆盖升级。
> 密钥丢失 = 永久失去覆盖升级能力，请离线备份两份。

## 3. 构建

与上游一致，前置要求：Flutter 3.47 / Dart ^3.13、Android SDK、NDK 27.3、
Rust 工具链 + `cargo-ndk`（`aarch64-linux-android`）。

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
   **再验一次钉住**：`for i in 1 2 3 4 5; do curl -s https://example.com/cdn-cgi/trace | grep '^ip='; done`
   5 次应一致 —— 只看证书只能证明「被解密」，证明不了「被加速」。
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
- **浏览器指纹只在安卓原生库带 `browser-tls` 时生效**（本仓 CI 已默认编入）。桌面端
  原生库没编这个特性，开关显示但不起作用；关掉后回到通用 TLS 握手，方便对照。
- **范围越大，设备 CA 参与解密的场景越多**。默认只留 `linux.do` + `ldstatic.com`
  是有意的：前者是主站，后者是它自己的静态资源域（图片/表情/消息总线/直传）。
- **上游的 `帮助优选`（众包上报）仍然默认关闭**，打开会把测量数据与 linux.do 账号身份绑定。

## 6. 回滚

只想恢复论坛首页：把 `lib/main.dart` 的 `home` 改回
`const OnboardingGate(child: PreheatGate(child: MainPage()))`。
范围相关改动是叠加式的，回滚 `proxy_leaf_trust.dart` 的 `mitmHosts` getter
即可退回上游行为（`linux.do` 单个域）。

## 7. 已合并的上游修复（1.1.7）

按「本仓确实有同一缺陷」挑选并 `cherry-pick -x`（保留上游作者与提交信息），
合并时只手工解冲突了 3 处：

| 上游提交 | 解决什么 | 冲突处理 |
|---|---|---|
| `865d7244` | 重定向按 RFC：跨源不再带 CSRF/User-Api-Key/Origin，303 与 POST 转 GET，保留取消令牌 | 无 |
| `ca4e6318` | POST 现取 CSRF 后按新会话重载 Cookie，不再「旧 Cookie + 新令牌」 | 无 |
| `a4426605` | WebView 渲染进程退出不再连带杀掉 App（本仓另补了浏览器页的占位与重建） | `webview_page.dart` 手工移植；测试文件依赖未移植的访客快照特性，未收 |
| `94987804` | 聊天里的非图片附件可点击下载 | 无 |
| `a8087825` | 采纳解决方案不再按对象解析响应（新版插件返回数组） | 无 |
| `86d0e730` | Linux Flatpak 外链改走 XDG 门户；点击统计失败不再弹错误 | 去掉双站相关分支 |
| `02f89f8f` / `9028b1c4` | 预测返回手势计数泄漏导致全局点击失效 | 无 |
| `4f304a9c` | 图片下载调度/缓存：头像不排在正文大图后，取消与非 200 立即放连接 | 去掉 `site_context` 引用 |
| `7643b512` | 内置 Dio 5.11.1 响应流生命周期补丁（取消真正传到适配器） | 无 |
| `0e808196` | 链接内图片可点击打开外层链接（`fluxdo_render` 子模块 → `d34e0c06`） | 无 |
| `14fc9a24` | 非默认排序下不再弹「有新话题」 | 无 |
| `5bb5da30` | 段落预热不再冻结子包兜底 handler（预热过的段落图片/emoji/链接/@ 失灵） | 测试文件手工合并 |
| `c1be3e3c` | MessageBus 订阅与话题列表状态对齐官方（新增时效探针） | 去掉不存在的 background_gate 导入 |

## 8. 已合并的上游修复（1.2.0）

上游 1.3.0 → 1.3.3 的一轮网络核心同步。子模块 `core/doh_proxy` `c18d48d` → **`f584d0e`**；
Dart 侧按顺序 cherry-pick，冲突集中在「本仓已去掉双站 / 保留 rhttp / 有浏览器待命」三处。

| 上游提交 | 解决什么 | 冲突处理 |
|---|---|---|
| `ed252f34` | 原生请求补 Client Hints 低熵三件套 | 去掉 idcflare / SiteContext 导入 |
| `e27befdf` | 网关出站照 WebView 的浏览器指纹，h2 MITM 安卓默认开 | 保留本仓可配置范围；去掉 `ipv6Auto` 参数 |
| `690c8eba` | 后台 WebView 主动采样请求头顺序 | `SiteContext.current.host` → `AppConstants.baseUrl` |
| `2ab8f953` | 渲染进程退出后刷新按钮重建 WebView | 本仓顶栏已换成占位页，改在底栏刷新按钮 |
| `1b372568` | VPN 让路后安卓仍按浏览器指纹发请求 | 手写移植：新增 `fingerprintOnlyGateway` / `routesAppThroughGateway`，保留 rhttp |
| `90c3b07c` | 让路期间连不上论坛自动恢复加速 | `isForumHost` 改单站点；保留 rhttp 上报 |
| `e5073ca0` | 让路时内置网页也经网关（可采样） | 保留待命逻辑；`mitmConnect` 不再排除指纹网关 |
| `49c18941` | 自定义节点（自填 CF IP / 优选域名） | 入口接到本仓旧版优选卡片；去掉 `ipv6Auto` |

**依赖顺序**：`1b372568` 之后的三条都建立在 `routesAppThroughGateway` 上；`49c18941`
的 FFI 字段依赖 `f584d0e` 的 `custom_nodes`。单独回退某一条时按上表从上往下看依赖。

**构建变化**：`tool/project_tasks.dart` 的安卓 Rust 特性从 `ech` 变成 `ech,browser-tls`，
需要在有 NDK（自带 libclang）的环境构建；CI 已按上游方式设置 `LIBCLANG_PATH` 回退。
arm64 原生库因此从 ~9 MB 涨到 ~15 MB，APK 约 +5.6 MB。

**未跟**：`8ebb340f` 删 rhttp（要连带改引擎选择 UI 与 18 个文件）、`856d055e` IP 三态自动
（本仓仍是布尔值，核心两种都认）、双站 / 微应用 / VS Code 主题 / 多账号。

未跟：`8ebb340f`（删 rhttp）等大重构、双站/多账号/微应用/主题等与浏览器定位无关的特性；
`core/doh_proxy` 子模块仍是 `c18d48d`——升级会同时带进浏览器指纹与 h2 MITM，
需要单独一轮构建 + 连接回归，别和 Dart 侧混在一起。

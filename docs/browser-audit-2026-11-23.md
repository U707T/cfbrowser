# cfbrowser 1.2.2 浏览器审查与验收

基线：[U707T/cfbrowser `7d313b6`](https://github.com/U707T/cfbrowser/commit/7d313b6758667cbf22ef91d794d708c3d63d4a3b)。主仓 Git 下载超时，本轮在该提交的官方源码快照实施，另取两个固定版本的子模块。项目是 Android 优先的联网浏览器，Windows/Linux 为预览；保留大量上游论坛代码。源码清单中 `lib/` 约 891 个 Dart 文件、`test/` 约 363 个；统计不等于逐文件人工阅读。

## 已修与覆盖

| 档位 | 位置 | 旧行为及影响 | 本次处理 |
|---|---|---|---|
| 🔴 | [应用更新](../lib/services/update_service.dart#L98)、[安装包下载](../lib/services/apk_download_service.dart#L40) | 更新查的是上游发布，两个产品 Android 包名不同；旧 APK 不能作为 cfbrowser 的覆盖升级。旧校验失败时仍安装。 | 改查本项目、隔离旧更新缓存和 ETag、只匹配本产品 arm64；优先用官方 API 摘要，无法取得有效校验值时不启动应用内安装。Android 签名检查仍是独立的保护。 |
| 🟡 | [收藏存储](../lib/providers/web_bookmark_provider.dart#L11)、[收藏列表](../lib/pages/my_browser_page.dart#L299)、[页面收藏](../lib/pages/webview_page.dart#L1443) | 写失败仍报成功；改名先删再加，存在中间状态；坏条目掩盖整份列表；隐私标签的星标可以写入全局书签。 | 等待持久化成功才提示、顺序写入、一次提交改名、逐条恢复、过滤非网页地址，禁止从无痕标签直接持久收藏。已有合法书签使用原存储键。 |
| 🟡 | [论坛启动](../lib/services/startup/app_startup.dart#L214) | 预加载最终失败后会话判定可无限等待，重进论坛也不重新尝试。 | 失败后独立检查已有会话，预加载错误仍交给原调用方；再次进入可重试，不重复 priming。 |
| 🟡 | [网络初始化](../lib/main.dart#L390) | 范围在网关之后加载；Windows UA 提前创建 WebView2 环境，可能等不到尚未启动的本次网关而选到旧端口。 | 恢复自定义范围后再启动网关；Windows UA 采样移到网络决策和环境创建之后。 |
| 🟡 | [结构化错误文案](../lib/services/network/discourse_error_message.dart) | JSON `error` 是对象而非字符串时强转失败，掩盖 400/429 等原始响应。 | 适配上游安全提取，恢复链与拦截器共享规则，不改变正常状态码和响应。 |
| 🔵 | [快捷访问](../lib/widgets/browser/quick_access_grid.dart#L235) | 首页渲染时主动取各站 favicon，用户不点击也会查询站点。 | 冷启动只渲染本地首字母图标；不影响配置范围的网关预连接。 |
| 🟡 | [分段下载](../lib/services/download/segmented_download.dart#L200) | 没有强验证器时也并发分段：`Last-Modified` 只有秒级精度、弱 ETag 规范上不能用于 `If-Range`，源文件短时内被替换可能拼出新旧混合文件。 | 探测阶段只接受强 ETag；缺失或弱 ETag 直接回退单连接；每个分段响应的 ETag 必须与探测一致，否则中止并回退。 |
| 🔵 | [标签页关闭栈](../lib/services/browser/browser_tabs_service.dart#L130) | 关闭或「全部关闭」后无法恢复误关的标签。 | 内存里保留最近 20 个非无痕、非空标签，可从首页菜单、页内菜单或标签面板「恢复」；当前空标签会被复用。无痕与空标签不入栈，重启后不复活。 |

## 缓存和预加载是四件事

| 类型 | 审查结论 | 验收方法 |
|---|---|---|
| HTTP 资源缓存 | [普通 WebView](../lib/services/webview_settings.dart) 开启缓存，无痕明确关闭；遵守站点缓存头，不承诺离线可打开。 | 受控网页分别设置 `Cache-Control: max-age` 与 `no-store`，观察第二次访问时源站请求计数；无痕分开验。 |
| 论坛数据预加载 | 首次进入论坛或普通站内 WebView 才开始，走原生请求或临时无头 WebView；不是通用网页 DOM 预渲染。 | 首进离线后联网、再进确认只重试一次；已有登录不因预加载失败而退出。 |
| 网关 TLS 预连 | 网关启动时后台预连配置范围，先做 TLS/连接池层工作，不是请求、缓存或渲染网页。 | 冷启分别验证默认范围、修改后范围、范围外直通及断网恢复。 |
| BFCache 与标签保活 | [设计文档](bfcache-design.md) 仍是规划。切标签重建 WebView，保留 URL 及 URL 历史，不保证滚动、表单或媒体状态。同标签引擎原生能力可能不同，项目未显式打开 Android BFCache。 | 同标签 A→B→返回，记录 `pageshow.persisted` 与源站文档请求；切标签用滚动与未提交表单做独立验收。 |

## 浏览器功能缺口与下一批顺序

- **先做恢复和数据可带走。** Android BFCache 探针 → 有上限的后台标签保活 → 冷恢复滚动位置。1.3.0 已补「重新打开关闭的标签」、书签搜索与 HTML / JSON 导入导出；剩下的是 BFCache 与滚动 / 表单状态恢复。
- **再做通用网站体验。** 1.3.0 已补搜索引擎切换（Bing / 百度 / Google / DuckDuckGo / 搜狗）与整页加载失败提示。仍未做：书签目录 / 站点组织、站点权限与站点数据管理、阅读模式、网页离线保存。对无痕至少分别实测 Android/Windows 的 Cookie、站点存储和下载；Linux 明确不提供无痕。不能从标签未落盘推断引擎完全隔离。
- **验证下载边界后再扩展。** 现版已接 WebView 下载回调及 Dio HTTP 分段/回退，不代表所有 `blob:`、POST、依赖 WebView 会话的下载都能工作；也不是跨进程断点续传。先跑受控站点的普通附件、登录附件、重定向和取消。Range 探测已改为只接受强 ETag（本次修复），无强验证器时回退单连接；跨进程续传仍未实现。
- Windows 代理只在 WebView2 环境建立时配置：修的是初始化顺序，不是运行期动态切换。验收需区分默认待命、显式启用 DoH 和保存端口已变更。
- 1.3.0 的完整发布结论见 [CHANGELOG.md](../CHANGELOG.md) 的 `1.3.0` 段与 [v1.3.0 Release](https://github.com/U707T/cfbrowser/releases/tag/v1.3.0)。

## 上游跟进

- 上游 [CFluxDo 1.3.4 默认分支](https://github.com/1molchuan/CFluxDo/compare/204cf0385b8bc80762e9e720c5913d51d11bc561...e5b8ea9ee43cd64469760fa99b99ed0c4e2f772e) 与 [1.3.5-beta.2 分支](https://github.com/1molchuan/CFluxDo/compare/e5b8ea9ee43cd64469760fa99b99ed0c4e2f772e...066504015ecabfa47a30809844a367a0ef99c637) 分别比前一个基线多 16、10 条。已适配 [结构化错误](https://github.com/1molchuan/CFluxDo/commit/4c94b57e883dab170d1b56f1c79a390adcc4b3d5)，借用了 [官方摘要思路](https://github.com/1molchuan/CFluxDo/commit/2efab8d9b2c0046289feaef3dd2c7f7a836db0ab)，没有引入公共镜像。
- 最值得单独验证的是 [Rust `f584d0e` → `e85040f`](https://github.com/1molchuan/fluxdo_doh/compare/f584d0e...e85040f) 的两条断网恢复修复。没有 FFI 字段变化，但要重编 Android 原生库，并核对断网、Wi-Fi/移动网络、前后台切换和非加速网站直通。未更新 gitlink。渲染子模块仍是 `d34e0c06`，无待跟更新。
- APK V3 签名可单独验证，签名身份不能换；VPN 让路需整组移植并按 cfbrowser 可配置范围适配。论坛专用商城、多账号、主题等不整批合并。

## 验证边界

Windows Flutter 3.47.5，Dart 3.13.4。已生成语言代码，运行 CI 对应的 10 个定向测试文件（84 个用例通过，含分段下载强验证器、途中 ETag 变更、标签恢复、版本比较四项新增回归）；其中偏好保存使用 Flutter 测试替身，下载有本地 HTTP 服务测试，不是 Android 实机浏览或签名升级。`actionlint` 校验两条 workflow 通过。源码快照的 Rust 证书资产尚未生成，Flutter 测试提示 `assets/certs` 缺失；没有据此宣称能出 APK 或验证 MITM、ECH、WebView2/Android 原生行为。

全项目 `dart analyze --no-fatal-warnings lib test` 退出 0，无 error 级诊断，但有 148 条 warning/info。额外运行 `flutter test --no-pub` 得到 **2583 通过、15 跳过、240 失败**（不是全绿）。日志确认多处编辑器/论坛测试缺 `quickjs_c_bridge.dll`，网关相关检查缺 `doh_proxy.dll`；其余断言需在补齐原生组件后用同基线对照，不能统一归为环境问题。改动涉及的 7 个源文件与 3 个测试文件单独 `dart analyze` 无问题。

此轮覆盖浏览器主链、相关上游和全项目静态检查，不宣称逐行人工审完继承的论坛模块、第三方插件或 Rust 子模块。

## 应用补丁时的注意

> 1.3.0 已把这些改动直接提交到 `main`（提交 `7a73f90`）并发布，本节仅保留给需要在其他分支重放补丁的场景。

`cfbrowser-7d313b6-browser-audit.patch` 基于 `7d313b6`，其中若干文件被本机 Dart 3.13 的 `dart format`（新版 tall 风格）重排过缩进与换行，属于纯格式差异。评审时用 `git apply --ignore-whitespace` 可以忽略空白差异快速看清真实改动；合入前建议再用项目约定的格式化器统一跑一次，避免与上游风格漂移。

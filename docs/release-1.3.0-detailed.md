# cfbrowser 1.3.0 详细更新日志

- 版本：`1.3.0+2026112601`
- 基线：`v1.2.2`（`7d313b6`）
- 发布提交：`384d0e3`（`main` HEAD）
- 发布页：<https://github.com/U707T/cfbrowser/releases/tag/v1.3.0>
- 产物：`cfbrowser-arm64-v8a.apk`，53,039,844 字节
- SHA-256：`e0abc44265c10387adee8336454102d885c09856f0edc95179a203a40a0b92e9`
- 规模：36 个文件，+2710 / −937 行

## 一、书签

### 1.1 独立书签页

新增 `lib/pages/bookmark_list_page.dart`（587 行），取代原先 `my_browser_page.dart` 里的私有 `_BookmarkListPage`。

- 顶部搜索：标题与完整 URL 双向匹配，不区分大小写；无命中时提示「没有匹配“…”的书签」，与「一条都没有」区分开。
- 每条左滑三个动作：改名、分享链接、删除。改名走 `rename`，只改标题字段，收藏时间与列表顺序都不动。
- 手动添加：输入框允许省略 scheme（自动补 `https://`），保存前用 `BrowserUrl.isWebUrl` 校验，非法地址直接拒绝并提示，不会写入。
- 打开方式不变：点击仍走 `WebViewPage.open`，与页面内收藏共用同一份数据。
- 空状态沿用 `mojianEmptyState`，主题切换后表现一致。

入口有三处：首页「更多 → 书签」、页面内「更多 → 书签」、书签页自身的手动添加入口。历史记录从原来的「书签与历史」拆出，页面内菜单改为单独的「历史记录」，避免两个功能挤在一个入口里。

### 1.2 导入 / 导出

新增 `lib/services/browser/bookmark_transfer.dart`（168 行），两种格式：

| 格式 | 用途 | 说明 |
| --- | --- | --- |
| Netscape Bookmark HTML | 与 Chrome / Edge / Firefox / Safari 互通 | 导出带 `ADD_DATE`；导入解析 `<A HREF>`，忽略文件夹层级 |
| JSON 备份 | 本应用自用，保留收藏时间 | 带 `format: cfbrowser-bookmarks` 与 `version: 1` |

导入行为：

- 只接受 `http` / `https`；`javascript:`、`chrome://`、`about:`、`ftp:` 之类一律丢弃，避免导入后点不动。
- 按 URL 去重，保留文件中首次出现的条目。
- 自动识别格式：文件名以 `.json` 结尾，或内容以 `{` / `[` 开头走 JSON 解析，其余按 HTML 解析。
- 单次上限 5000 条（`maxImportItems`），防止误选超大文件把界面卡死。
- 解析失败（空文件、坏 JSON、无链接的网页）返回空列表并提示，不抛异常、不写盘。
- 选择「合并」时只追加新网址，已存在的保留原条目（用户可能改过标题，或导入的是更旧的备份）；选择「替换」才整体覆盖。两个选项都在写入前明确确认，取消则不做任何修改。

导出行为：

- 文件名 `cfbrowser-bookmarks-YYYYMMDD.html|json`，先写进 `ShareUtils` 的待送出目录，再交给系统保存面板（桌面另存为 / Android 公共「下载」目录）。
- 没有书签时提示「还没有书签可导出」，不生成空文件。

HTML 导出示例：

```html
<DT><A HREF="https://example.com/a?x=1&amp;y=2" ADD_DATE="1763860800">A &amp; B &lt;tag&gt;</A>
```

属性与文本都做转义，标题为空时回落到域名，不会出现空的 `<A>`。

### 1.3 存储层改造

`lib/providers/web_bookmark_provider.dart` 从「改内存 → 尽力写盘」改为「写盘成功 → 再改内存」：

- 所有写操作经 `synchronized` 的 `Lock` 串行化，连点星标不会出现两次读同一份旧状态。
- `_commit` 先 `await` 写入并检查返回值，`false` 时抛 `StateError`，界面保持原状；不再出现「提示收藏成功但重启后消失」。
- 新增 `rename`（只改标题）、`importBookmarks`（返回实际新增条数）、`replaceAll`（整体替换）。
- 读取改为逐条容错：单条坏数据只丢那一条，不再让整份列表变空；加载时过滤非网页地址并按 URL 去重。
- 存储键仍是 `web_bookmarks`，已有书签原样保留，无需迁移。

页面内收藏（`webview_page.dart:1570`）同步改成异步：菜单项对无痕标签与非法地址置灰不可点，写入失败提示「未能保存书签更改，请重试」。

## 二、地址栏搜索引擎

新增 `lib/services/browser/browser_search_engine.dart`（65 行）。

| 引擎 | 模板 |
| --- | --- |
| Bing（默认） | `https://www.bing.com/search?q={query}` |
| 百度 | `https://www.baidu.com/s?wd={query}` |
| Google | `https://www.google.com/search?q={query}` |
| DuckDuckGo | `https://duckduckgo.com/?q={query}` |
| 搜狗 | `https://www.sogou.com/web?query={query}` |

- 选择写入 `browser_search_engine_v1`，冷启动在 `main.dart:399` 恢复；存储值无法识别时回退 Bing，不抛异常。
- 入口在首页「更多 → 搜索引擎」，当前项打勾，切换后 toast 提示。
- 首页地址栏（`browser_home_page.dart:77`）与页内地址输入（`webview_page.dart:1552`）共用同一模板；输入网址仍直开，只有搜索词才套模板，规则与 1.2.2 一致。
- 只放不需要额外网络条件的服务，没有把任何一家设成必须联网才能用的前置条件。

## 三、网页加载失败提示

`lib/pages/webview_page.dart` 接入 `onReceivedError`（835 行），新增 `_buildErrorPage`（1046 行）。

- 只处理主框架失败：`request.isForMainFrame == false` 直接忽略，图片、统计脚本、广告位这类子资源失败不会把整页换成错误页。
- 上一次导航的失败回调可能在新的导航开始后才到，地址与 `_currentUrl` 对不上就丢弃，避免旧错误盖住新页面。
- 新导航开始时清除错误态（`onLoadStart`）。
- 错误页显示站点域名、引擎给的原因描述，最多 3 行；提供「重试」（重新加载同一地址）与「返回上一页」（仅在有可回退历史时出现）。
- 保留原 WebView 不销毁，重试不需要重建整个标签页。

1.2.2 没有应用层错误处理：主文档失败时只能由各平台引擎自己的默认错误页兜底，文案与语言不可控，App 也不提供重试或返回上一页。

## 四、误关标签恢复

`lib/services/browser/browser_tabs_service.dart`：

- 新增内存关闭栈，上限 20 个（`maxRecentlyClosed`，30 行）。
- `close` 与 `closeAll` 都会入栈；`closeAll` 按「非当前标签先、当前标签最后」的顺序记录，所以全部关闭后逐个恢复的顺序与关闭顺序相反（后关的先回来）。
- 无痕标签与空白标签不入栈：前者不应在内存里多留一份地址，后者恢复没有意义；栈只在内存，重启即清空。
- `reopenLastClosed()`（182 行）恢复地址、标题、桌面版设置与 URL 级历史与当前指针；当前标签是空标签页时先把它移除再复用，避免恢复后多出一个空白页。

界面入口三处：首页菜单（带实时数量「重新打开关闭的标签（n）」）、页面内菜单、标签面板顶部「恢复（n）」按钮。没有可恢复项时菜单项置灰。

## 五、更新检查与安装包校验

原先 `UpdateService` 查的是上游 `1molchuan/fluxdo` 的 Release。两个产品包名不同（`com.github.molchuan.cfbrowser` 与 `com.github.molchuan.cfluxdo`），且签名不同，上游 APK 在 cfbrowser 上装不上，只会让用户下载一个失败包。

`lib/services/update_service.dart`：

- 仓库改为 `U707T/cfbrowser`，`User-Agent` 改为 `cfbrowser-App`。
- 缓存与 ETag 键加前缀（`cfbrowser_update_cache` 等），升级后不会继续展示旧缓存里的上游安装包。
- `releaseAbis` 只保留 `arm64-v8a`，与实际只发一个包一致；`abiOfFileName` 只认 `cfbrowser-` 前缀，`cfluxdo-…apk` 一律忽略。
- 新增 `_isOfficialAssetUrl`：资产下载地址必须是 `https://github.com/U707T/cfbrowser/releases/download/<tag>/<同名文件>`，拒绝其他主机、带 userinfo、非常规端口、文件名不符的资产。
- 优先取 Release API 的 `digest`（`sha256:…`），缺失时才回退同名 `.sha256` 文件；两者都拿到后统一小写规范化。
- 版本比较相关方法改为静态并暴露 `isNewerVersion` 供回归使用。

`lib/services/apk_download_service.dart`：

- 有官方摘要时直接用，不再多请求一次 `.sha256`。
- 拿不到任何有效校验值时**不启动应用内安装**，提示用户到发布页手动下载并核对；1.2.2 是「校验失败也照装」。

## 六、分段下载的验证器

`lib/services/download/segmented_download.dart`：

- 探测阶段只接受**强 ETag**。`Last-Modified` 只有秒级精度、弱 ETag（`W/` 前缀）按规范不能用于 `If-Range`，都不能保证各分段拿到同一版本。
- 没有强 ETag 时直接抛 `SegmentedDownloadUnsupported`，由 `DownloadService` 回退单连接，而不是并发拼一个可能新旧混合的文件。
- 每个分段响应的 ETag 必须与探测一致，不一致立即中止并回退。

## 七、启动序列

`lib/services/startup/app_startup.dart`：

- 新增 `_preloadSucceeded`。预加载最终失败时会话判定不再无限等待：失败分支里先 `_startStartupVerdict()` 让会话检查独立跑完，再把错误抛给等预加载的调用方（启动页仍显示错误与重试）。
- `launch()` 在已启动但预加载失败且没有进行中请求时，允许再试一次；priming 与会话接线不重复。
- 预加载首次失败、之后重试成功且带回当前用户时，推进纪元并重新判定，避免沿用「已登出」的旧结论。
- `_resolve` 改为 `Future.sync` 包装，副作用不再同步发生在调用栈里。

`lib/main.dart`：

- 「加速范围」改到网关启动之前加载（392 行），确保 `mitm_hosts` 与覆盖域名在代理起来时就已就位。
- Windows 的 UA 探测从并行初始化批次挪到「网络设置完成、WebView2 环境创建之后」（406 行）。UA 探测会创建无头 WebView，提前跑会等一个尚未确定的代理端口，只能等超时，并可能让 WebView2 整场用上次的端口。

## 八、结构化 API 错误

新增 `lib/services/network/discourse_error_message.dart`（14 行），`error_interceptor.dart` 与 `recovery/policies.dart` 共用：

- Discourse 的 `error` 字段既可能是字符串，也可能是 `{code, message}` 对象，也可能是无效值。
- 依次尝试 `error` 字符串、`error.message`、`errors` 首项，全部失效返回 `null` 走原有通用文案。
- 不改变状态码与响应对象，下游 CF 验证、网络日志、恢复策略看到的 `response` 与以前一致。

1.2.2 在 `error` 为对象时 `as String?` 抛类型错误，把原始 400/429 响应整个盖掉。

## 九、其他

- `lib/widgets/browser/quick_access_grid.dart`：首页快捷入口不再为显示图标主动请求 `https://<host>/favicon.ico`。1.2.2 在渲染每个快捷入口时会加载该站的 favicon（首次或缓存失效时真正发请求），用户没点过也会留下访问痕迹；现在只渲染本地首字母图标。
- `lib/services/browser/browser_url.dart`：`isWebUrl` 额外要求 host 非空、不含空白、不含 `%`，堵住 `https://` 这类只有 scheme 的字符串被当成合法书签。
- `lib/widgets/browser/browser_tabs_sheet.dart`：标签面板顶部新增「恢复（n）」，数量为 0 时不显示。
- `lib/pages/my_browser_page.dart`：书签实现迁出，仅保留地址栏、入口卡片与历史页；「书签」入口指向新页面。
- `README.md`：下载说明改为本项目 Release，写明 arm64 单包、1.2.1 及更早需要卸载一次、应用内更新只查正式版。
- `docs/cfbrowser.md`：更新子模块基线说明（`core/doh_proxy` 固定 `f584d0e`），并把待跟的上游断网恢复修复写清楚。
- `docs/browser-audit-2026-11-23.md`：新的审查与验收清单，逐条列出本版已修、仍未做、需要真机验证的部分。
- `highlights/v1.3.0.md`：Release / Telegram / AltStore 使用的用户视角亮点。
- `CHANGELOG.md`：新增 `1.3.0` 段。
- `.github/workflows/ci.yml`：定向测试清单从 5 个文件补到 12 个，新增的测试会进 CI。

## 十、文件清单

| 文件 | 增删 | 作用 |
| --- | --- | --- |
| `lib/pages/bookmark_list_page.dart` | +587 | 新增：书签页（搜索 / 改名 / 分享 / 删除 / 导入导出） |
| `lib/services/browser/bookmark_transfer.dart` | +168 | 新增：书签 HTML 与 JSON 的导入导出 |
| `lib/services/browser/browser_search_engine.dart` | +65 | 新增：搜索引擎枚举与持久化 |
| `lib/services/network/discourse_error_message.dart` | +14 | 新增：结构化错误文案提取 |
| `lib/pages/webview_page.dart` | +307 −165 | 失败页、书签入口、标签恢复、异步收藏、搜索模板 |
| `lib/pages/browser_home_page.dart` | +164 −66 | 书签入口、搜索引擎选择、标签恢复菜单 |
| `lib/providers/web_bookmark_provider.dart` | +111 −45 | 串行写入、写成功才更新、导入合并 / 替换 |
| `lib/services/update_service.dart` | +157 −84 | 仓库与资产来源、摘要校验、静态版本比较 |
| `lib/services/browser/browser_tabs_service.dart` | +99 −10 | 关闭栈与 `reopenLastClosed` |
| `lib/services/startup/app_startup.dart` | +42 −11 | 预加载失败不再卡住会话判定，可重试 |
| `lib/services/apk_download_service.dart` | +24 −25 | 校验值缺失不安装，优先官方摘要 |
| `lib/services/download/segmented_download.dart` | +22 −13 | 只接受强 ETag |
| `lib/widgets/browser/browser_tabs_sheet.dart` | +22 −2 | 标签面板「恢复（n）」 |
| `lib/widgets/browser/quick_access_grid.dart` | +21 −38 | 去掉 favicon 预取 |
| `lib/main.dart` | +9 −10 | 范围在网关前加载；Windows UA 延后 |
| `lib/services/browser/browser_url.dart` | +9 −8 | `isWebUrl` 收紧 |
| `lib/pages/my_browser_page.dart` | +2 −286 | 书签实现迁出 |
| `lib/services/network/interceptors/error_interceptor.dart` | +2 −9 | 复用错误文案提取 |
| `lib/services/network/recovery/policies.dart` | +2 −10 | 同上，删掉重复实现 |
| `lib/services/startup/forum_bootstrap.dart` | +2 −2 | 注释与新语义对齐 |
| `test/services/bookmark_transfer_test.dart` | +108 | 新增：6 项（导出转义、JSON 往返、导入过滤、坏输入、上限） |
| `test/services/web_bookmark_provider_test.dart` | +106 | 新增：4 项（写盘重读、坏条目、并发、导入合并 / 替换） |
| `test/services/browser_search_engine_test.dart` | +59 | 新增：3 项（默认值、坏存储值、模板编码） |
| `test/services/segmented_download_test.dart` | +101 | 新增强验证器与途中 ETag 变更两项 |
| `test/services/browser_tabs_service_test.dart` | +59 | 新增关闭栈三项 |
| `test/services/update_service_abi_test.dart` | +108 −56 | 重写来源与版本比较用例 |
| `test/services/network/interceptors/error_interceptor_test.dart` | +84 | 新增结构化错误用例 |
| `test/services/startup/app_startup_test.dart` | +58 −22 | 新增预加载失败相关用例 |
| `test/services/startup/offline_preload_resume_test.dart` | +58 −59 | 调整到新语义 |
| `.github/workflows/ci.yml` | +8 −1 | 定向测试清单补齐 |
| `CHANGELOG.md` | +42 | 1.3.0 条目 |
| `README.md` | +5 −11 | 下载与升级说明改为本项目 |
| `docs/cfbrowser.md` | +1 −3 | 子模块基线描述纠正 |
| `docs/browser-audit-2026-11-23.md` | +53 | 审查与验收清单 |
| `highlights/v1.3.0.md` | +30 | 发布亮点 |
| `pubspec.yaml` | +1 −1 | 版本号 `1.3.0+2026112601` |

## 十一、验证记录

本地（Windows，Flutter 3.47.5，Dart 3.13.4）：

```text
dart analyze lib test                          → 148 issues，无 error 级
flutter test --no-pub <12 个定向测试文件>       → 94 项全部通过
actionlint .github/workflows/ci.yml            → 通过
```

CI（GitHub Actions）：

| 运行 | 触发 | 结果 |
| --- | --- | --- |
| [45852570114](https://github.com/U707T/cfbrowser/actions/runs/45852570114) | tag `v1.3.0` | analyze-and-test ✅ / build-android ✅ / 签名校验 ✅ / 发布 ✅ |
| [45852493761](https://github.com/U707T/cfbrowser/actions/runs/45852493761) | push `main` | ✅（`Create release` 因非 tag 跳过） |
| CI（`e318254`） | push `main` | ✅ |
| [45930792475](https://github.com/U707T/cfbrowser/actions/runs/45930792475) | push `main`（`384d0e3`） | analyze-and-test ✅ / build-android ✅ |

签名校验比对的是固定发布密钥的 SHA-256，不是 debug 证书，说明这一版可以覆盖升级 1.2.2。

**未验证**（不要把这些算成通过）：

- Android 真机：书签导入真实浏览器导出文件、失败页、搜索引擎跳转、标签恢复、覆盖安装。
- 桌面：Windows WebView2 的代理与错误页、Linux WPE 的对应表现。
- 无痕标签在 Android / Windows 上的 Cookie 与站点存储隔离程度。
- 分段下载只在本地 HTTP 服务上验证，没有对真实 CDN 跑过大文件。

## 十二、升级与兼容

- 1.2.2 及之后版本可直接覆盖升级；1.2.1 及更早的包用的是临时 debug 证书，仍需先卸载一次。
- 书签存储键未变，老数据原样读取；旧的 `update_cache` / `update_etag` 不再被读取，升级后会重新拉一次 Release 信息。
- 搜索引擎偏好是新增键，未设置时默认 Bing，与 1.2.2 行为一致。
- 关闭栈只在内存，重启后不保留，也不会因为升级出现「恢复」里有旧条目。

## 十三、仍未实现

- Android BFCache 与切标签时的滚动 / 表单状态恢复（`docs/bfcache-design.md` 仍是规划）。
- 书签目录 / 站点分组、站点权限与站点数据管理、阅读模式、网页离线保存。
- 跨进程断点续传（现有分段下载是单次会话内加速，不是续传）。
- Rust 子模块 `core/doh_proxy` 仍固定在 `f584d0e`，上游 `f584d0e → e85040f` 的断网恢复修复待单独跟进并重编原生库。

## 十四、提交历史

```text
384d0e3 🎨 统一换行符为 LF
e318254 📝 审查报告同步 1.3.0 已发布状态
7a73f90 ✨ 浏览器能力补齐与书签导入导出（1.3.0）
```

`384d0e3` 说明：1.3.0 的首次提交把 8 个文件以 CRLF 写回，与仓库其余部分的 LF 不一致，会让这些文件在 diff / blame 里显示为整份重写。该提交只做换行归一，内容未变，diff 规模从 +5247 / −3474 降到 +2710 / −937。

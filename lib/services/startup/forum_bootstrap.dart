import '../network/doh/network_settings_service.dart';
import 'app_startup.dart';

/// 「论坛网络栈真正要用」的统一入口。
///
/// cfbrowser 是浏览器优先：冷启动不再 priming / 预加载（那会让开屏等网络）。
/// 但 priming、会话判定、登录后启动项不能只在 MainPage 里启动 —— 深链冷启动
/// 直接 push 话题页、或用户在站内浏览器里打开 linux.do，都不经过 MainPage，
/// 以前这些路径会一直拿不到预热过的会话。
///
/// [AppStartup.launch] 自身幂等（`_launched`），[leaveStandby] 也共享同一个
/// Future，所以三处调用（首页、站内 WebView、深链）重复触发没有副作用。
Future<void> ensureForumNetworkReady({String reason = 'browser'}) async {
  await NetworkSettingsService.instance.leaveStandby();
  AppStartup.instance.launch(reason: reason);
}

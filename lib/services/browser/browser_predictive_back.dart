import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show PredictiveBackEvent;
import 'package:flutter/widgets.dart';

/// 浏览器页的 Android 预测返回手势接管。
///
/// 为什么需要单独一份：`PopScope(canPop: false)` 会让路由的
/// `popGestureEnabled` 与 `popDisposition` 一起变成「不可 pop」，框架据此：
///
/// 1. 不给该路由挂预测返回探测器（`_PredictiveBackGestureDetectorState
///    ._isEnabled` 依赖 `popGestureEnabled`），手势没人认领；
/// 2. 项目自己的「全屏侧滑返回」探测器同样以 `popGestureEnabled` 为闸门
///    （`fullscreen_swipe_back.dart` 的 `enabledCallback`），一并失效；
/// 3. 而且它命中 WebView 平台视图时本来就主动弃权，避免抢走页面内滚动。
///
/// 结果：网页有后退历史时，右滑手势没有任何一条路径能触发「网页后退」。
/// 这里按 `PredictiveBackOverlayHandler` 的同一套 observer 协议自行认领，
/// 把系统手势映射成浏览器后退，并在提交时走与返回键相同的处理函数。
///
/// 三条约束：
/// - **只认领主框架可后退的情况**，其它情形一律返回 false 交回框架，保持
///   系统原有的整页退出动画；
/// - `isEnabled` 必须与 `_onCommit` 使用同一个判定，否则会出现「认领了却
///   什么都不做」的手势吞掉；
/// - 计数由本类配对收尾：框架只在下次 start 时清空认领者列表，中途锁屏
///   不会补发 commit/cancel，漏收尾会让 `userGestureInProgress` 一直为真。
class BrowserPredictiveBack with WidgetsBindingObserver {
  BrowserPredictiveBack({
    required this.isEnabled,
    required this.onBack,
    this.onDragUpdate,
    this.onDragCancel,
  });

  /// 当前是否由浏览器接管这次手势（有网页历史可回退）。
  final bool Function() isEnabled;

  /// 手势提交：执行一次网页后退。
  final VoidCallback onBack;

  /// 跟手进度（0 起，1 为拖满），可选，用于给页面加轻微位移反馈。
  final ValueChanged<double>? onDragUpdate;

  /// 手势取消或被打断，可选。
  final VoidCallback? onDragCancel;

  bool _active = false;

  /// 只在 Android 上挂载；其它平台当前没有预测返回管线。
  static bool get isSupported => !kIsWeb && Platform.isAndroid;

  void attach() {
    if (!isSupported) return;
    WidgetsBinding.instance.addObserver(this);
  }

  void dispose() {
    if (isSupported) WidgetsBinding.instance.removeObserver(this);
  }

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    // 返回键/三键导航发的是 button 事件，交给框架走 popRoute。
    if (backEvent.isButtonEvent || !isEnabled()) return false;
    // 同一次按压内重发 start（部分机型）：当作同一手势延续，不重复认领
    // 也不重复计数。
    _active = true;
    onDragUpdate?.call(backEvent.progress);
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    if (!_active) return;
    onDragUpdate?.call(backEvent.progress);
  }

  @override
  void handleCancelBackGesture() {
    if (!_active) return;
    _active = false;
    onDragUpdate?.call(0);
    onDragCancel?.call();
  }

  @override
  void handleCommitBackGesture() {
    if (!_active) return;
    _active = false;
    onDragUpdate?.call(0);
    // 提交后再判定一次：手势期间页面可能已经退到底，此时不该再后退。
    if (isEnabled()) onBack();
  }

  /// 手势中途进后台/锁屏：系统不补发 commit/cancel，必须自己收尾，
  /// 否则 `_active` 卡住、后续手势全部失效。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.hidden && state != AppLifecycleState.paused) {
      return;
    }
    if (!_active) return;
    _active = false;
    onDragUpdate?.call(0);
    onDragCancel?.call();
  }
}

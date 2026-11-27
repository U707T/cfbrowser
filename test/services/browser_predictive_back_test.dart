/// BrowserPredictiveBack 单元测试：手势认领门控、按钮事件放行、
/// 跟手进度、commit 只在仍可回退时执行一次后退、cancel 与生命周期收尾。
library;

import 'package:cfbrowser/services/browser/browser_predictive_back.dart';
import 'package:flutter/services.dart' show PredictiveBackEvent;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

PredictiveBackEvent _gesture(double progress) => PredictiveBackEvent.fromMap({
  'touchOffset': <Object?>[0.0, 400.0],
  'progress': progress,
  'swipeEdge': 0,
});

/// 返回键 / 三键导航：引擎报成 button 事件。
PredictiveBackEvent _button() =>
    PredictiveBackEvent.fromMap({'progress': 0.0, 'swipeEdge': 0});

class _Harness {
  _Harness({this.enabled = true});

  bool enabled;
  int backs = 0;
  final List<double> progress = <double>[];
  int cancels = 0;

  late final BrowserPredictiveBack handler = BrowserPredictiveBack(
    isEnabled: () => enabled,
    onBack: () => backs++,
    onDragUpdate: progress.add,
    onDragCancel: () => cancels++,
  );

  void dispose() => handler.dispose();
}

void main() {
  // attach() 在非 Android 测试环境下不挂 observer，但协议方法本身可直接调用。
  test('按钮事件不认领，交回框架走普通返回', () {
    final h = _Harness();
    addTearDown(h.dispose);
    expect(h.handler.handleStartBackGesture(_button()), isFalse);
    expect(h.handler.handleCommitBackGesture, returnsNormally);
    expect(h.backs, 0);
  });

  test('没有可回退历史时不认领手势', () {
    final h = _Harness(enabled: false);
    addTearDown(h.dispose);
    expect(h.handler.handleStartBackGesture(_gesture(0.1)), isFalse);
    h.handler.handleCommitBackGesture();
    expect(h.backs, 0);
  });

  test('可回退时认领手势，跟手进度透传，提交执行一次后退', () {
    final h = _Harness();
    addTearDown(h.dispose);
    expect(h.handler.handleStartBackGesture(_gesture(0.1)), isTrue);
    h.handler.handleUpdateBackGestureProgress(_gesture(0.6));
    expect(h.progress, <double>[0.1, 0.6]);

    h.handler.handleCommitBackGesture();
    expect(h.backs, 1);

    // 收尾后再次收到 commit（系统迟到事件）不应重复后退。
    h.handler.handleCommitBackGesture();
    expect(h.backs, 1);
  });

  test('手势期间页面退到底，提交时不再后退', () {
    final h = _Harness();
    addTearDown(h.dispose);
    expect(h.handler.handleStartBackGesture(_gesture(0.2)), isTrue);
    // 拖拽过程中页面已经退到首层（例如手势把它推到底）。
    h.enabled = false;
    h.handler.handleCommitBackGesture();
    expect(h.backs, 0);
  });

  test('取消手势不后退，并复位跟手进度', () {
    final h = _Harness();
    addTearDown(h.dispose);
    expect(h.handler.handleStartBackGesture(_gesture(0.3)), isTrue);
    h.handler.handleCancelBackGesture();
    expect(h.progress.last, 0);
    expect(h.cancels, 1);
    expect(h.backs, 0);

    // 取消后的迟到 commit 不应补一次后退。
    h.handler.handleCommitBackGesture();
    expect(h.backs, 0);
  });

  test('手势中途进后台会自己收尾，避免卡住后续手势', () {
    final h = _Harness();
    addTearDown(h.dispose);
    expect(h.handler.handleStartBackGesture(_gesture(0.4)), isTrue);
    h.handler.didChangeAppLifecycleState(AppLifecycleState.paused);
    expect(h.cancels, 1);

    // 收尾后可以重新认领新的一次手势。
    expect(h.handler.handleStartBackGesture(_gesture(0.2)), isTrue);
    h.handler.handleCommitBackGesture();
    expect(h.backs, 1);
  });

  test('进后台但当前没有手势时不触发取消', () {
    final h = _Harness();
    addTearDown(h.dispose);
    h.handler.didChangeAppLifecycleState(AppLifecycleState.paused);
    expect(h.cancels, 0);
  });
}

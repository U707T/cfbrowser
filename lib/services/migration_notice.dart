import 'package:flutter/material.dart';

import '../l10n/s.dart';
import '../utils/dialog_utils.dart';
import 'migration_service.dart';

/// 数据迁移导致登录态失效时，弹一次「需要重新登录」的说明。
///
/// 这段逻辑原本在 `PreheatGate._showReloginDialog` 里，而 cfbrowser 的首页
/// 不再挂载 PreheatGate → 提示变成死代码，升级用户只会表现为「无征兆掉登录」。
/// 现在改由浏览器首页首帧调用（只弹一次，内部先把标志置回 false）。
Future<void> showReloginRequiredIfNeeded(BuildContext context) async {
  if (!MigrationService.requiresRelogin) return;
  MigrationService.requiresRelogin = false; // 只弹一次
  if (!context.mounted) return;
  await showAppDialog(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: Text(S.current.migration_title),
      content: Text(S.current.migration_reloginRequired),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(S.current.common_confirm),
        ),
      ],
    ),
  );
}

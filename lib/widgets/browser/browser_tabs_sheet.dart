import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';

import '../../models/browser_tab.dart';
import '../../services/browser/browser_tabs_service.dart';

/// 打开标签页管理面板。
///
/// [onSelect] 在面板关闭后调用，调用方可以安全地 push/pushReplacement。
/// [onClose] 仅在关闭「当前标签」时调用：此时面板先关闭，调用方再决定
/// 切到哪个标签或退出浏览器页。
Future<void> showBrowserTabsSheet(
  BuildContext context, {
  required ValueChanged<BrowserTab> onSelect,
  ValueChanged<BrowserTab>? onClose,
  VoidCallback? onCloseAll,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) => _BrowserTabsSheet(
      onSelect: onSelect,
      onClose: onClose,
      onCloseAll: onCloseAll,
    ),
  );
}

class _BrowserTabsSheet extends StatelessWidget {
  const _BrowserTabsSheet({
    required this.onSelect,
    this.onClose,
    this.onCloseAll,
  });

  final ValueChanged<BrowserTab> onSelect;
  final ValueChanged<BrowserTab>? onClose;
  final VoidCallback? onCloseAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final service = BrowserTabsService.instance;

    return SizedBox(
      height: (MediaQuery.sizeOf(context).height * 0.62)
          .clamp(180.0, 520.0)
          .toDouble(),
      child: ValueListenableBuilder<List<BrowserTab>>(
        valueListenable: service.tabs,
        builder: (context, tabs, _) {
          return ValueListenableBuilder<String?>(
            valueListenable: service.activeTabId,
            builder: (context, activeId, _) {
              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
                    child: Row(
                      children: [
                        Icon(Symbols.tab_rounded, size: 20),
                        const SizedBox(width: 8),
                        Text(
                          '标签页（${tabs.length}）',
                          style: theme.textTheme.titleMedium,
                        ),
                        const Spacer(),
                        TextButton.icon(
                          onPressed: () => _createTab(context, isPrivate: false),
                          icon: const Icon(Symbols.add_rounded, size: 18),
                          label: const Text('新建'),
                        ),
                        TextButton.icon(
                          onPressed: () => _createTab(context, isPrivate: true),
                          icon: const Icon(
                            Symbols.visibility_off_rounded,
                            size: 18,
                          ),
                          label: const Text('无痕'),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: tabs.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Symbols.tab_rounded,
                                  size: 48,
                                  color: theme.colorScheme.onSurfaceVariant
                                      .withValues(alpha: 0.4),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  '没有打开的标签页',
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            itemCount: tabs.length,
                            itemBuilder: (context, index) {
                              final tab = tabs[index];
                              final selected = tab.id == activeId;
                              return ListTile(
                                selected: selected,
                                selectedTileColor: theme
                                    .colorScheme.primaryContainer
                                    .withValues(alpha: 0.35),
                                leading: Icon(
                                  tab.isPrivate
                                      ? Symbols.visibility_off_rounded
                                      : Symbols.public_rounded,
                                  color: tab.isPrivate
                                      ? theme.colorScheme.tertiary
                                      : null,
                                ),
                                title: Text(
                                  tab.displayTitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  tab.url.isEmpty ? '新标签页' : tab.url,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                trailing: IconButton(
                                  tooltip: '关闭标签页',
                                  icon: const Icon(
                                    Symbols.close_rounded,
                                    size: 20,
                                  ),
                                  onPressed: () => _closeTab(
                                    context,
                                    tab,
                                    wasActive: selected,
                                  ),
                                ),
                                onTap: () {
                                  Navigator.pop(context);
                                  if (!selected) onSelect(tab);
                                },
                              );
                            },
                          ),
                  ),
                  if (tabs.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                      child: Row(
                        children: [
                          Text(
                            '切回标签会重新加载页面，滚动位置暂不保留',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.outline,
                            ),
                          ),
                          const Spacer(),
                          TextButton(
                            onPressed: () {
                              service.closeAll();
                              Navigator.pop(context);
                              onCloseAll?.call();
                            },
                            child: const Text('全部关闭'),
                          ),
                        ],
                      ),
                    ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  void _createTab(BuildContext context, {required bool isPrivate}) {
    final tab = BrowserTabsService.instance.create(isPrivate: isPrivate);
    Navigator.pop(context);
    onSelect(tab);
  }

  void _closeTab(
    BuildContext context,
    BrowserTab tab, {
    required bool wasActive,
  }) {
    BrowserTabsService.instance.close(tab.id);
    if (wasActive) {
      Navigator.pop(context);
      onClose?.call(tab);
    }
  }
}

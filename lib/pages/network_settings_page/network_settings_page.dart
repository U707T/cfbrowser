import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/s.dart';
import '../../services/network/doh/network_settings_service.dart';
import '../../services/network/vpn_auto_toggle_service.dart';
import '../../settings/definitions/network_defs.dart';
import '../../widgets/settings/settings_group_page.dart';

/// 网络设置页面
///
/// 进页面就结束「浏览器待命」：用户主动打开网络设置，说明他要的是加速真正跑起来。
/// 以前待命只能在访问加速站点或拨动某个开关（例如设备独有证书）时结束，表现为
/// 「DoH 开着但一直是正在启动」，必须切一次开关才生效。
class NetworkSettingsPage extends StatefulWidget {
  final String? highlightId;

  const NetworkSettingsPage({super.key, this.highlightId});

  @override
  State<NetworkSettingsPage> createState() => _NetworkSettingsPageState();
}

class _NetworkSettingsPageState extends State<NetworkSettingsPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final service = NetworkSettingsService.instance;
      // VPN 接管期间不要抢着起网关：让路逻辑自己会在需要时恢复
      if (!service.current.dohEnabled ||
          VpnAutoToggleService.instance.locksAcceleration ||
          service.proxyService.isRunning) {
        return;
      }
      unawaited(service.leaveStandby());
    });
  }

  @override
  Widget build(BuildContext context) {
    return SettingsGroupPage(
      title: context.l10n.networkSettings_title,
      groupsBuilder: buildNetworkGroups,
      highlightId: widget.highlightId,
    );
  }
}

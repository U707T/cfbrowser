import 'package:flutter/material.dart';

import '../services/browser/browser_scope_service.dart';
import '../services/network/doh/network_settings_service.dart';

/// 加速范围设置页。
///
/// 上游 cfluxdo 把 ECH/MITM 范围写死成 `linux.do`，因为它只是论坛客户端。
/// cfbrowser 是浏览器，必须让用户决定「哪些域名交给本地网关做 ECH 改写」：
///
/// - 范围内的域名：走本地网关 → 钉住/竞速的 Cloudflare 边缘 IP → ECH 握手，
///   可以绕过 DNS 污染与 SNI 阻断；
/// - 范围外的域名：CONNECT 隧道直通，端到端 TLS，**不被解密也不被加速**。
///
/// 范围越大，设备 CA 参与解密的场景越多，所以默认只有 `linux.do`。
class BrowserScopePage extends StatefulWidget {
  const BrowserScopePage({super.key});

  @override
  State<BrowserScopePage> createState() => _BrowserScopePageState();
}

class _BrowserScopePageState extends State<BrowserScopePage> {
  late final TextEditingController _hostsController;
  late final TextEditingController _ipController;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _hostsController = TextEditingController(
      text: BrowserScopeService.instance.mitmHosts.join('\n'),
    );
    _ipController = TextEditingController(
      text: NetworkSettingsService.instance.current.serverIp ?? '',
    );
  }

  @override
  void dispose() {
    _hostsController.dispose();
    _ipController.dispose();
    super.dispose();
  }

  List<String> _parseHosts() => _hostsController.text
      .split(RegExp(r'[\s,;]+'))
      .where((e) => e.trim().isNotEmpty)
      .toList(growable: false);

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final hosts = await BrowserScopeService.instance.setMitmHosts(
        _parseHosts(),
      );
      final ip = _ipController.text.trim();
      await NetworkSettingsService.instance.setServerIp(
        ip.isEmpty ? null : ip,
      );
      // 范围与出口 IP 都是网关启动参数，改完必须重启才生效
      await NetworkSettingsService.instance.restartProxy();
      if (!mounted) return;
      _hostsController.text = hosts.join('\n');
      messenger?.showSnackBar(
        SnackBar(content: Text('已保存，网关已重启：${hosts.join('、')}')),
      );
    } catch (e) {
      if (!mounted) return;
      messenger?.showSnackBar(SnackBar(content: Text('保存失败：$e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _resetHosts() async {
    _hostsController.text = BrowserScopeService.defaultHosts.join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('加速范围'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('保存'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('加速域名', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            '每行一个，子域自动包含。范围内的域名会被本地网关接管（设备 CA 现签证书 + ECH 握手）；'
            '范围外的域名只做隧道直通，不解密也不加速。',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _hostsController,
            minLines: 4,
            maxLines: 10,
            autocorrect: false,
            keyboardType: TextInputType.multiline,
            decoration: const InputDecoration(
              hintText: 'linux.do',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _resetHosts,
              icon: const Icon(Icons.restore, size: 18),
              label: Text('恢复默认（${BrowserScopeService.defaultHosts.join('、')}）'),
            ),
          ),
          const Divider(height: 32),
          Text('固定出口 IP（可选）', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            '留空 = 本地优选自动竞速。填入一个 Cloudflare 边缘 IP 可钉死出口，'
            '让 CF 始终看到同一个来源 IP（减少人机验证、避免掉登录）。'
            'CF 所有边缘都认任意 Host，所以换成哪个 IP 都能回源到同一站点。',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _ipController,
            autocorrect: false,
            keyboardType: TextInputType.text,
            decoration: const InputDecoration(
              hintText: '172.64.x.x（留空为自动）',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '提示：修改会在保存时重启本地网关，正在加载的页面需要刷新一次。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }
}

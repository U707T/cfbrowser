import 'package:shared_preferences/shared_preferences.dart';

/// cfbrowser 的「浏览器域名范围」配置。
///
/// 上游 fluxdo/cfluxdo 把 MITM（ECH 改写）范围写死成 `linux.do` 一个域，
/// 因为它只是一个论坛客户端。cfbrowser 把它变成浏览器后，范围必须可配：
///
/// - [mitmHosts]：交给 Rust 网关做 MITM + ECH 的域名（后缀匹配）。
///   落在范围外的域名走 CONNECT 隧道，端到端 TLS，**不会被加速，也不会被解密**。
/// - 范围越大，设备 CA 参与解密的场景越多。默认只保留 `linux.do`，
///   新增域名由用户显式添加，避免默默扩大信任面。
///
/// 固定出口 IP（`server_ip`）沿用 [NetworkSettingsService.setServerIp]，
/// 不在这里重复存储，避免两套状态打架。
class BrowserScopeService {
  BrowserScopeService._();

  static final BrowserScopeService instance = BrowserScopeService._();

  static const String _hostsKey = 'browser_mitm_hosts';

  /// 默认范围：与上游行为一致
  static const List<String> defaultHosts = <String>['linux.do'];

  List<String> _hosts = const <String>[...defaultHosts];

  /// 当前 MITM/ECH 范围（已归一化、去重、保序）
  List<String> get mitmHosts => List<String>.unmodifiable(_hosts);

  /// 是否仍是上游默认范围（用于 UI 提示）
  bool get isDefault =>
      _hosts.length == defaultHosts.length &&
      _hosts.every(defaultHosts.contains);

  /// 启动时读一次，之后 getter 同步可用。
  ///
  /// 未初始化时 getter 返回默认值，保证网关启动路径永远不会拿到空范围
  /// （空范围 = Rust 侧「除 CF 验证域名外全部 MITM」，那是更激进的默认值）。
  Future<void> initialize(SharedPreferences prefs) async {
    final stored = prefs.getStringList(_hostsKey);
    if (stored == null) return;
    final normalized = normalizeAll(stored);
    if (normalized.isEmpty) return;
    _hosts = normalized;
  }

  /// 保存新的范围，返回归一化后的结果。
  ///
  /// 调用方负责在保存后重启网关（[NetworkSettingsService.restartProxy]）才生效。
  Future<List<String>> setMitmHosts(
    List<String> hosts, {
    SharedPreferences? prefs,
  }) async {
    final normalized = normalizeAll(hosts);
    // 不允许清空：空范围会被 Rust 解释成「全部 MITM」，反而比默认更宽
    _hosts = normalized.isEmpty ? const [...defaultHosts] : normalized;
    final p = prefs ?? await SharedPreferences.getInstance();
    await p.setStringList(_hostsKey, _hosts);
    return mitmHosts;
  }

  /// [host] 是否落在范围内（自身或子域）
  bool covers(String host) {
    final h = host.toLowerCase();
    for (final scope in _hosts) {
      if (h == scope || h.endsWith('.$scope')) return true;
    }
    return false;
  }

  /// 网关启动时预热的上游连接：范围域名本身
  List<String> get preconnectHosts => mitmHosts;

  /// 归一化：去协议、去端口、去路径、小写、去重、保序
  static List<String> normalizeAll(Iterable<String> raw) {
    final out = <String>[];
    for (final item in raw) {
      final host = normalizeHost(item);
      if (host == null) continue;
      if (!out.contains(host)) out.add(host);
    }
    return out;
  }

  /// 单个输入归一化，非法返回 null
  static String? normalizeHost(String raw) {
    var value = raw.trim().toLowerCase();
    if (value.isEmpty) return null;
    // 允许用户直接粘贴 URL
    final uri = Uri.tryParse(value.contains('://') ? value : 'https://$value');
    if (uri != null && uri.host.isNotEmpty) value = uri.host;
    // 去掉残留的端口与路径
    value = value.split('/').first.split(':').first;
    if (value.startsWith('*.')) value = value.substring(2);
    if (value.startsWith('.')) value = value.substring(1);
    if (value.isEmpty) return null;
    // 粗校验：只接受字母数字/连字符的域名标签，至少两段
    final label = RegExp(r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?$');
    final parts = value.split('.');
    if (parts.length < 2 || !parts.every(label.hasMatch)) return null;
    return value;
  }
}

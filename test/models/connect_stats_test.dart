import 'package:flutter_test/flutter_test.dart';
import 'package:cfbrowser/models/connect_stats.dart';

void main() {
  group('ConnectStats.fromHtml', () {
    test('信任要求空状态页面返回默认统计', () {
      const html = '''
<div class="dash-body">
  <main class="page-content">
    <div class="card empty-state">
      <h2 class="card-title">信任级别 3 的要求</h2>
      <p class="text-base text-secondary m-0 mb-1">当前 0 级，达到 2 级可查看 3 级进度详情。</p>
      <p class="text-sm text-tertiary m-0">继续参与社区，解锁更多功能！</p>
    </div>
  </main>
</div>
''';

      final stats = ConnectStats.fromHtml(html);

      expect(stats.daysVisited, 0);
      expect(stats.topicsRepliedTo, 0);
      expect(stats.topicsViewed, 0);
      expect(stats.postsRead, 0);
      expect(stats.likesGiven, 0);
      expect(stats.likesReceived, 0);
      expect(stats.likesReceivedDays, 0);
      expect(stats.likesReceivedUsers, 0);
      expect(stats.timePeriod, 100);
    });
  });
}

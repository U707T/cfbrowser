import 'package:flutter_test/flutter_test.dart';
import 'package:cfbrowser/utils/load_more_coordinator.dart';

void main() {
  group('LoadMoreCoordinator', () {
    test('默认只触发一次 loadMore', () async {
      final coordinator = LoadMoreCoordinator();
      var calls = 0;
      var count = 10;

      await coordinator.loadMore(
        loadMore: () async {
          calls++;
          count += 10;
        },
        hasMore: () => true,
        isActive: () => true,
        progressCount: () => count,
      );

      expect(calls, 1);
      expect(coordinator.isCoolingDown, isFalse);
    });

    test('仍有更多但没有新增时进入冷却', () async {
      final coordinator = LoadMoreCoordinator();
      var calls = 0;

      await coordinator.loadMore(
        loadMore: () async {
          calls++;
        },
        hasMore: () => true,
        isActive: () => true,
        progressCount: () => 10,
      );

      expect(calls, 1);
      expect(coordinator.isCoolingDown, isTrue);
      expect(coordinator.shouldTriggerForDistance(20), isFalse);
      expect(coordinator.shouldTriggerForDistance(250), isFalse);
      expect(coordinator.isCoolingDown, isFalse);
    });

    test('自定义 auto-continue 策略可连续加载', () async {
      final coordinator = LoadMoreCoordinator();
      var calls = 0;
      var count = 0;

      await coordinator.loadMore(
        loadMore: () async {
          calls++;
          count++;
        },
        hasMore: () => true,
        isActive: () => true,
        progressCount: () => count,
        shouldAutoLoadMore: (attempt) => attempt.attempts < 2,
        shouldCooldown: (attempt) => attempt.hasMore && attempt.attempts >= 2,
      );

      expect(calls, 3);
      expect(coordinator.isCoolingDown, isTrue);
    });
  });

  group('TopicLoadMoreCoordinator', () {
    test('空关键词时只触发一次 loadMore', () async {
      final coordinator = TopicLoadMoreCoordinator();
      var calls = 0;
      var count = 10;

      await coordinator.loadTopicPage(
        loadMore: () async {
          calls++;
          count += 10;
        },
        hasMore: () => true,
        isActive: () => true,
        itemCount: () => count,
        hasKeywordFilter: false,
      );

      expect(calls, 1);
      expect(coordinator.isCoolingDown, isFalse);
    });

    test('关键词过滤可见增量不足时最多续载三次', () async {
      final coordinator = TopicLoadMoreCoordinator();
      var calls = 0;
      var visible = 0;

      await coordinator.loadTopicPage(
        loadMore: () async {
          calls++;
          visible++;
        },
        hasMore: () => true,
        isActive: () => true,
        itemCount: () => calls,
        visibleItemCount: () => visible,
        hasKeywordFilter: true,
      );

      expect(calls, 4);
      expect(coordinator.isCoolingDown, isTrue);
    });

    test('关键词过滤可见增量足够时停止续载', () async {
      final coordinator = TopicLoadMoreCoordinator();
      var calls = 0;
      var visible = 0;

      await coordinator.loadTopicPage(
        loadMore: () async {
          calls++;
          visible += 5;
        },
        hasMore: () => true,
        isActive: () => true,
        itemCount: () => calls,
        visibleItemCount: () => visible,
        hasKeywordFilter: true,
      );

      expect(calls, 1);
      expect(coordinator.isCoolingDown, isFalse);
    });
  });
}

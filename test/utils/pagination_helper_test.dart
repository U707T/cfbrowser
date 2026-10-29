import 'package:flutter_test/flutter_test.dart';
import 'package:cfbrowser/utils/pagination_helper.dart';

void main() {
  group('PaginationHelpers.forTopics', () {
    final helper = PaginationHelpers.forTopics<int>(
      keyExtractor: (item) => item,
    );

    test('moreUrl 非空且响应非空时 hasMore=true', () {
      final state = helper.processRefresh(
        const PaginationResult(items: [1, 2], moreUrl: '/latest.json?page=1'),
      );

      expect(state.hasMore, isTrue);
    });

    test('moreUrl 非空但响应为空时 hasMore=false', () {
      final state = helper.processLoadMore(
        const PaginationState(items: [1, 2]),
        const PaginationResult(items: [], moreUrl: '/latest.json?page=2'),
      );

      expect(state.items, [1, 2]);
      expect(state.hasMore, isFalse);
    });

    test('非空重复响应仍保留 hasMore，让调用方可以推进页码', () {
      final state = helper.processLoadMore(
        const PaginationState(items: [1, 2]),
        const PaginationResult(items: [2], moreUrl: '/latest.json?page=2'),
      );

      expect(state.items, [1, 2]);
      expect(state.hasMore, isTrue);
    });
  });
}

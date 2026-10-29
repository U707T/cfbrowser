import 'package:flutter_test/flutter_test.dart';
import 'package:cfbrowser/models/topic.dart';
import 'package:cfbrowser/models/user.dart';
import 'package:cfbrowser/providers/topic_detail_provider.dart';

Boost _boost({required int id, required int userId, required String username}) {
  return Boost(
    id: id,
    cooked: '<p>Boost</p>',
    user: BoostUser(id: userId, username: username, avatarTemplate: ''),
  );
}

void main() {
  group('实时 Boost 权限合并', () {
    late User currentUser;

    setUp(() {
      currentUser = User(id: 1, username: 'alice', trustLevel: 2);
    });

    test('他人 Boost 不应消耗当前用户 canBoost', () {
      final newBoost = _boost(id: 10, userId: 2, username: 'bob');

      final canBoost = resolveCanBoostAfterRealtimeBoost(
        currentCanBoost: true,
        newBoost: newBoost,
        currentUser: currentUser,
      );

      expect(canBoost, isTrue);
    });

    test('自己的 Boost 会消耗当前用户 canBoost', () {
      final newBoost = _boost(id: 11, userId: 1, username: 'alice');

      final canBoost = resolveCanBoostAfterRealtimeBoost(
        currentCanBoost: true,
        newBoost: newBoost,
        currentUser: currentUser,
      );

      expect(canBoost, isFalse);
    });

    test('Boost 用户 id 缺失时按用户名兜底识别自己', () {
      final newBoost = _boost(id: 12, userId: 0, username: 'alice');

      expect(isRealtimeBoostFromCurrentUser(newBoost, currentUser), isTrue);
    });

    test('游客或未加载当前用户时保留原 canBoost', () {
      final newBoost = _boost(id: 13, userId: 1, username: 'alice');

      final canBoost = resolveCanBoostAfterRealtimeBoost(
        currentCanBoost: true,
        newBoost: newBoost,
        currentUser: null,
      );

      expect(canBoost, isTrue);
    });
  });
}

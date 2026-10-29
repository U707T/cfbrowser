import 'package:flutter_test/flutter_test.dart';
import 'package:cfbrowser/models/topic.dart';
import 'package:cfbrowser/widgets/post/post_boost/boost_content.dart';

void main() {
  group('BoostContentParser', () {
    test('parses adjacent emoji images into a single display string', () {
      const cooked =
          '<p><img class="emoji" title="smile" src="/images/emoji/twitter/smile.png?v=12">'
          '<img class="emoji" title="heart" src="/images/emoji/twitter/heart.png?v=12"></p>';

      final parsed = BoostContentParser.parse(cooked);

      expect(parsed.displayText, ':smile::heart:');
      expect(parsed.groupingKey, ':smile::heart:');
    });

    test('falls back to src path when tone emoji title is missing', () {
      const cooked =
          '<p><img class="emoji" src="/images/emoji/twitter/wave/t3.png?v=12"></p>';

      final parsed = BoostContentParser.parse(cooked);

      expect(parsed.displayText, ':wave:t3:');
    });
  });

  group('groupBoostsByContent', () {
    test('groups boosts with the same rendered content', () {
      final boosts = [
        Boost(
          id: 1,
          cooked:
              '<p><img class="emoji" title="smile" src="/images/emoji/twitter/smile.png?v=12"></p>',
          user: const BoostUser(
            id: 10,
            username: 'alice',
            avatarTemplate: '/user_avatar/test/alice/{size}/1.png',
          ),
        ),
        Boost(
          id: 2,
          cooked:
              '<p><img class="emoji" title="smile" src="/images/emoji/twitter/smile.png?v=12"></p>',
          user: const BoostUser(
            id: 11,
            username: 'bob',
            avatarTemplate: '/user_avatar/test/bob/{size}/1.png',
          ),
        ),
        Boost(
          id: 3,
          cooked:
              '<p><img class="emoji" title="heart" src="/images/emoji/twitter/heart.png?v=12"></p>',
          user: const BoostUser(
            id: 12,
            username: 'carol',
            avatarTemplate: '/user_avatar/test/carol/{size}/1.png',
          ),
        ),
      ];

      final groups = groupBoostsByContent(boosts);

      expect(groups, hasLength(2));
      expect(groups.first.displayText, ':smile:');
      expect(groups.first.count, 2);
      expect(groups.last.displayText, ':heart:');
      expect(groups.last.count, 1);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:cfbrowser/storage/export_history_dao.dart';

import 'bookmark_hive_test_support.dart';

ExportHistoryEntry _entry({
  required String id,
  int topicId = 1,
  String title = 'Sample',
  ExportHistoryFormat format = ExportHistoryFormat.markdown,
  ExportHistoryTarget target = ExportHistoryTarget.localFile,
  String ref = '/tmp/sample.md',
  ExportHistoryStatus status = ExportHistoryStatus.success,
  required DateTime createdAt,
  int? size,
  int? postCount,
  String? error,
}) {
  return ExportHistoryEntry(
    id: id,
    sourceType: ExportHistorySource.topic,
    sourceTopicId: topicId,
    sourceTitle: title,
    format: format,
    targetType: target,
    targetRef: ref,
    status: status,
    createdAt: createdAt,
    size: size,
    postCount: postCount,
    errorMessage: error,
  );
}

void main() {
  late BookmarkHiveTestSupport storage;
  late ExportHistoryDao dao;

  setUp(() async {
    storage = await BookmarkHiveTestSupport.create();
    dao = ExportHistoryDao(boxFactory: storage.openBox);
  });

  tearDown(() async {
    await storage.dispose();
  });

  test('readAll 按 createdAt 倒序', () async {
    await dao.upsertOne(
      'acct',
      _entry(id: 'a', createdAt: DateTime.utc(2026, 1, 1)),
    );
    await dao.upsertOne(
      'acct',
      _entry(id: 'b', createdAt: DateTime.utc(2026, 3, 1)),
    );
    await dao.upsertOne(
      'acct',
      _entry(id: 'c', createdAt: DateTime.utc(2026, 2, 1)),
    );

    final entries = await dao.readAll('acct');
    expect(entries.map((e) => e.id), ['b', 'c', 'a']);
  });

  test('账号之间隔离', () async {
    await dao.upsertOne(
      'a',
      _entry(id: '1', createdAt: DateTime.utc(2026, 1, 1)),
    );
    await dao.upsertOne(
      'b',
      _entry(id: '2', createdAt: DateTime.utc(2026, 1, 2)),
    );

    expect((await dao.readAll('a')).single.id, '1');
    expect((await dao.readAll('b')).single.id, '2');
  });

  test('upsert 同 id 覆盖', () async {
    final t = DateTime.utc(2026, 1, 1);
    await dao.upsertOne('acct', _entry(id: 'x', title: 'old', createdAt: t));
    await dao.upsertOne('acct', _entry(id: 'x', title: 'new', createdAt: t));
    final all = await dao.readAll('acct');
    expect(all, hasLength(1));
    expect(all.single.sourceTitle, 'new');
  });

  test('deleteOne 与 clearAccount', () async {
    await dao.upsertOne(
      'acct',
      _entry(id: '1', createdAt: DateTime.utc(2026, 1, 1)),
    );
    await dao.upsertOne(
      'acct',
      _entry(id: '2', createdAt: DateTime.utc(2026, 1, 2)),
    );
    await dao.deleteOne('acct', '1');
    expect((await dao.readAll('acct')).map((e) => e.id), ['2']);
    await dao.clearAccount('acct');
    expect(await dao.readAll('acct'), isEmpty);
  });

  test('反序列化保留所有字段', () async {
    await dao.upsertOne(
      'acct',
      _entry(
        id: 'x',
        topicId: 99,
        title: '示例标题',
        format: ExportHistoryFormat.html,
        target: ExportHistoryTarget.notion,
        ref: 'https://www.notion.so/abc',
        status: ExportHistoryStatus.failed,
        createdAt: DateTime.utc(2026, 5, 1),
        size: 1234,
        postCount: 5,
        error: 'boom',
      ),
    );
    final e = (await dao.readAll('acct')).single;
    expect(e.sourceTopicId, 99);
    expect(e.sourceTitle, '示例标题');
    expect(e.format, ExportHistoryFormat.html);
    expect(e.targetType, ExportHistoryTarget.notion);
    expect(e.targetRef, 'https://www.notion.so/abc');
    expect(e.status, ExportHistoryStatus.failed);
    expect(e.size, 1234);
    expect(e.postCount, 5);
    expect(e.errorMessage, 'boom');
  });
}

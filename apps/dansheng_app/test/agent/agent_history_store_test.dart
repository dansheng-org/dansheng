// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';

import 'package:dansheng_app/agent/agent_history.dart';
import 'package:dansheng_app/agent/agent_types.dart';
import 'package:dansheng_app/bridge.g.dart';
import 'package:dansheng_app/ui/campus/agent/agent_history_store.dart';
import 'package:dansheng_app/ui/core/dansheng_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = BasicMessageChannel<Object?>(
  'dev.flutter.pigeon.dansheng_app.DanshengApi.invoke',
  DanshengApi.pigeonChannelCodec,
);

const _record = <String, dynamic>{
  'id': 'chat',
  'title': '会话',
  'updated_at': 1760000000000,
  'turns': [
    {
      'question': 'question',
      'answer': 'answer',
      'notice': 'notice',
      'model': 'model',
      'destination': 'destination',
      'remember': true,
      'attachments': ['notes.txt'],
      'web_links': [
        {'title': 'Source', 'url': 'https://example.test/source'},
      ],
    },
    {
      'question': 'pending',
      'remember': false,
      'attachments': [],
      'web_links': [],
    },
  ],
};

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  late AgentHistoryStore store;

  setUp(() => store = AgentHistoryStore(DanshengClient()));
  tearDown(() => messenger.setMockDecodedMessageHandler(_channel, null));

  void replyWith(Object? Function(Json request) reply) {
    messenger.setMockDecodedMessageHandler(_channel, (message) async {
      final args = message! as List<Object?>;
      expect(args[0], HostCommand.campus);
      return reply(jsonDecode(args[1]! as String) as Json);
    });
  }

  test('history round-trips the record and exposes read-only lists', () {
    final conversation = AgentConversation.fromJson(_record);
    expect(conversation.toJson(), _record);
    expect(conversation.summary.updatedAt, 1760000000000);
    expect(conversation.turns.first.webLinks.single.uri.host, 'example.test');
    expect(conversation.turns.clear, throwsUnsupportedError);
    expect(conversation.turns.first.attachments.clear, throwsUnsupportedError);
    expect(conversation.turns.first.webLinks.clear, throwsUnsupportedError);
    expect(
      const AgentHistoryTurn(question: 'pending').toJson(),
      (_record['turns'] as List).last,
    );
  });

  test('sends explicit account IDs for every history operation', () async {
    final requests = <Json>[];
    replyWith((request) {
      requests.add(request);
      final params = request['params'] as Json;
      final result = switch (request['method']) {
        'agent.history.list' => [
          {'id': 'older', 'title': 'Older', 'updated_at': 1},
          {'id': 'chat', 'title': '会话', 'updated_at': 1760000000000},
        ],
        'agent.history.get' when params['id'] == 'chat' => _record,
        _ => null,
      };
      return [jsonEncode(result)];
    });

    final conversation = AgentConversation.fromJson(_record);
    for (final accountId in [null, 'campus-account']) {
      requests.clear();
      expect((await store.list(accountId)).map((e) => e.id), ['chat', 'older']);
      expect((await store.get(accountId, 'chat'))?.toJson(), _record);
      expect(await store.get(accountId, 'missing'), isNull);
      await store.save(accountId, conversation, create: true);
      await store.save(accountId, conversation, create: false);
      await store.rename(accountId, 'chat', 'Renamed', 1760000000001);
      await store.delete(accountId, 'chat');

      Json request(String operation, [Json params = const {}]) => {
        'method': 'agent.history.$operation',
        'params': {'account_id': accountId, ...params},
      };
      expect(requests, [
        request('list'),
        request('get', {'id': 'chat'}),
        request('get', {'id': 'missing'}),
        request('save', {'conversation': _record, 'create': true}),
        request('save', {'conversation': _record, 'create': false}),
        request('rename', {
          'id': 'chat',
          'title': 'Renamed',
          'updated_at': 1760000000001,
        }),
        request('delete', {'id': 'chat'}),
      ]);
    }
  });

  test(
    'maps storage errors without exposing host messages or details',
    () async {
      for (final entry in const {
        'AccountMismatch': '当前账号已变更',
        'AgentHistoryFull': '会话历史已满',
        'AgentConversationTooLarge': '会话内容过大',
        'ConversationMissing': '该会话已不存在',
        'UnexpectedError': '无法访问会话历史',
      }.entries) {
        replyWith((_) => [entry.key, 'private message', 'private details']);
        await expectLater(
          store.delete(null, 'chat'),
          throwsA(
            isA<AgentFailure>().having(
              (error) => error.message,
              'message',
              allOf(startsWith(entry.value), isNot(contains('private'))),
            ),
          ),
        );
      }
    },
  );

  test('rejects invalid records and attachment paths', () async {
    replyWith((_) => ['{"turns":[]}']);
    await expectLater(store.get(null, 'chat'), throwsA(isA<AgentFailure>()));

    await expectLater(
      store.save(
        null,
        const AgentConversation(
          id: 'chat',
          title: '会话',
          updatedAt: 0,
          turns: [
            AgentHistoryTurn(
              question: 'question',
              attachments: [r'C:\notes.txt'],
            ),
          ],
        ),
        create: true,
      ),
      throwsA(isA<AgentFailure>()),
    );
  });
}

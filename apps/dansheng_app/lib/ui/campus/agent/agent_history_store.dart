// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/services.dart';

import '../../../agent/agent_history.dart';
import '../../../agent/agent_types.dart';
import '../../core/dansheng_client.dart';
import '../campus_api.dart';

class AgentHistoryStore {
  AgentHistoryStore(DanshengClient client) : _api = CampusApi(client);

  final CampusApi _api;

  Future<List<AgentConversationSummary>> list(String? accountId) =>
      _withStorageErrors(() async {
        final result = await _call('list', accountId) as List<dynamic>;
        return result
            .cast<Json>()
            .map(AgentConversationSummary.fromJson)
            .toList()
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      });

  Future<AgentConversation?> get(String? accountId, String id) =>
      _withStorageErrors(() async {
        final result = await _call('get', accountId, {'id': id});
        return result == null
            ? null
            : AgentConversation.fromJson(result as Json);
      });

  Future<void> save(
    String? accountId,
    AgentConversation conversation, {
    required bool create,
  }) => _withStorageErrors(() async {
    final record = conversation.toJson();
    final result = await _call('save', accountId, {
      'conversation': record,
      'create': create,
    });
    if (create && result is Json && result['created'] == false) {
      await _call('save', accountId, {'conversation': record, 'create': false});
    }
  });

  Future<void> rename(
    String? accountId,
    String id,
    String title,
    int updatedAt,
  ) => _withStorageErrors(() async {
    await _call('rename', accountId, {
      'id': id,
      'title': title,
      'updated_at': updatedAt,
    });
  });

  Future<void> delete(String? accountId, String id) =>
      _withStorageErrors(() async {
        await _call('delete', accountId, {'id': id});
      });

  Future<dynamic> _call(
    String operation,
    String? accountId, [
    Json params = const {},
  ]) => _api.call('agent.history.$operation', {
    'account_id': accountId,
    ...params,
  });

  Future<T> _withStorageErrors<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on PlatformException catch (error) {
      throw AgentFailure(switch (error.code) {
        'AccountMismatch' ||
        'AccountChanged' ||
        'AccountRequired' => '当前账号已变更，请重新打开会话历史。',
        'AgentHistoryFull' => '会话历史已满，请删除一些旧会话后重试。',
        'AgentConversationTooLarge' => '会话内容过大，无法保存。',
        'ConversationMissing' => '该会话已不存在，请刷新会话列表。',
        _ => '无法访问会话历史，请稍后重试。',
      });
    } on FormatException {
      throw const AgentFailure('会话历史数据格式无效。');
    } on TypeError {
      throw const AgentFailure('会话历史数据格式无效。');
    }
  }
}

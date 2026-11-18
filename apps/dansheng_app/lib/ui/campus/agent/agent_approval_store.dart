// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/services.dart';

import '../../../agent/agent_types.dart';
import '../../core/dansheng_client.dart';
import '../campus_api.dart';

class AgentApprovalStore {
  AgentApprovalStore(DanshengClient client) : _api = CampusApi(client);

  static const _permissions = {
    'learning',
    'files',
    'forum',
    'campus',
    'web',
    'web_provider',
    'attachment',
  };
  final CampusApi _api;

  Future<Set<String>> get(String? accountId, String destination) async {
    final result = await _call('get', accountId, {'destination': destination});
    if (result is! List) throw const AgentFailure('授权记录格式无效。');

    final allowed = <String>{};
    for (final permission in result) {
      if (permission is! String ||
          !_permissions.contains(permission) ||
          !allowed.add(permission)) {
        throw const AgentFailure('授权记录格式无效。');
      }
    }
    return allowed;
  }

  Future<void> allow(
    String? accountId,
    String destination,
    String permission,
  ) async {
    await _call('allow', accountId, {
      'destination': destination,
      'permission': permission,
    });
  }

  Future<void> revoke(
    String? accountId,
    String destination,
    String permission,
  ) async {
    await _call('revoke', accountId, {
      'destination': destination,
      'permission': permission,
    });
  }

  Future<void> clear(String? accountId) async {
    await _call('clear', accountId);
  }

  Future<dynamic> _call(
    String operation,
    String? accountId, [
    Json params = const {},
  ]) async {
    try {
      return await _api.call('agent.approvals.$operation', {
        'account_id': accountId,
        ...params,
      });
    } on PlatformException catch (error) {
      throw AgentFailure(switch (error.code) {
        'AccountMismatch' ||
        'AccountChanged' ||
        'AccountRequired' => '当前账号已变更，请重新确认授权。',
        'AgentApprovalsFull' => '长期授权记录已满，请撤销旧授权后重试。',
        'InvalidInput' => '授权目的地址或权限无效。',
        _ => '无法访问授权记录，请稍后重试。',
      });
    } on FormatException {
      throw const AgentFailure('授权记录格式无效。');
    }
  }
}

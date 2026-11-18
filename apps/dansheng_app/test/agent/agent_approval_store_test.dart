// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';

import 'package:dansheng_app/agent/agent_types.dart';
import 'package:dansheng_app/bridge.g.dart';
import 'package:dansheng_app/ui/campus/agent/agent_approval_store.dart';
import 'package:dansheng_app/ui/core/dansheng_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _destination = 'openAi:https://example.test/v1';

void main() {
  late _Bridge bridge;
  late AgentApprovalStore store;

  setUp(() {
    bridge = _Bridge();
    store = AgentApprovalStore(DanshengClient(bridge: bridge));
  });

  test('sends exact scoped grant operations on the campus bridge', () async {
    bridge.reply = '["forum","web"]';
    expect(await store.get('account', _destination), {'forum', 'web'});
    bridge.reply = '{}';
    await store.allow('account', _destination, 'attachment');
    await store.revoke('account', _destination, 'attachment');
    await store.clear(null);

    expect(bridge.calls, [
      {
        'method': 'agent.approvals.get',
        'params': {'account_id': 'account', 'destination': _destination},
      },
      for (final operation in ['allow', 'revoke'])
        {
          'method': 'agent.approvals.$operation',
          'params': {
            'account_id': 'account',
            'destination': _destination,
            'permission': 'attachment',
          },
        },
      {
        'method': 'agent.approvals.clear',
        'params': {'account_id': null},
      },
    ]);
  });

  test('rejects malformed grants and sanitizes bridge errors', () async {
    for (final reply in ['{}', '["unknown"]', '["web","web"]', '[4]', 'x']) {
      bridge.reply = reply;
      await expectLater(
        store.get(null, _destination),
        throwsA(isA<AgentFailure>()),
      );
    }

    bridge.error = PlatformException(
      code: 'AccountMismatch',
      message: 'private bridge details',
    );
    await expectLater(
      store.allow(null, _destination, 'web'),
      throwsA(
        isA<AgentFailure>().having(
          (failure) => failure.message,
          'message',
          '当前账号已变更，请重新确认授权。',
        ),
      ),
    );
  });
}

class _Bridge implements DanshengBridge {
  final calls = <Object?>[];
  String reply = '[]';
  PlatformException? error;

  @override
  Future<String> invoke(HostCommand command, String payload) async {
    expect(command, HostCommand.campus);
    calls.add(jsonDecode(payload));
    if (error case final failure?) throw failure;
    return reply;
  }
}

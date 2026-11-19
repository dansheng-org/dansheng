// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';

import 'package:dansheng_app/agent/agent_types.dart';
import 'package:dansheng_app/bridge.g.dart';
import 'package:dansheng_app/ui/campus/agent/agent_chat_settings.dart';
import 'package:dansheng_app/ui/campus/agent/agent_settings_store.dart';
import 'package:dansheng_app/ui/core/dansheng_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'settings bridge round-trips effort and accepts older profiles',
    () async {
      final bridge = _SettingsBridge();
      final store = AgentSettingsStore(DanshengClient(bridge: bridge));
      for (final value in [null, 'off', 'default', 'unexpected', 2]) {
        if (value == null) {
          bridge.profile.remove('reasoning_effort');
        } else {
          bridge.profile['reasoning_effort'] = value;
        }
        final config = await store.load();
        expect(config?.reasoningEffort, AgentReasoningEffort.defaultEffort);
      }

      for (final effort in AgentReasoningEffort.values.skip(1)) {
        await store.save(_config(effort));
        expect(bridge.profile['reasoning_effort'], effort.name);
        expect((await store.load())?.reasoningEffort, effort);
      }
      await store.save(_config(AgentReasoningEffort.defaultEffort));
      expect(bridge.profile, isNot(contains('reasoning_effort')));
      expect(
        (await store.load())?.reasoningEffort,
        AgentReasoningEffort.defaultEffort,
      );
    },
  );

  testWidgets('saving model settings keeps the composer reasoning effort', (
    tester,
  ) async {
    _setPhoneSize(tester);
    final bridge = _SettingsBridge();
    final store = AgentSettingsStore(DanshengClient(bridge: bridge));
    await tester.pumpWidget(
      MaterialApp(
        home: AgentChatSettings(
          config: _config(AgentReasoningEffort.medium),
          canClear: false,
          onSave: store.save,
          onClear: () async {},
          loadModels: ({
            required provider,
            required baseUrl,
            required apiKey,
          }) async => [],
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pumpAndSettle();

    final save = find.text('保存配置');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(bridge.profile['reasoning_effort'], 'medium');
    expect(bridge.profile['api_key'], 'test-key');
  });

  testWidgets('switching to Responses at the same API address keeps the key', (
    tester,
  ) async {
    _setPhoneSize(tester);
    final bridge = _SettingsBridge();
    final store = AgentSettingsStore(DanshengClient(bridge: bridge));
    await tester.pumpWidget(
      MaterialApp(
        home: AgentChatSettings(
          config: AgentModelConfig(
            provider: ModelProvider.openAi,
            baseUrl: Uri.parse('https://api.deepseek.com'),
            model: 'deepseek-flash',
            apiKey: 'test-key',
          ),
          canClear: false,
          onSave: store.save,
          onClear: () async {},
          loadModels: ({
            required provider,
            required baseUrl,
            required apiKey,
          }) async => [],
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 450));
    final provider = find.byType(DropdownButtonFormField<ModelProvider>);
    await tester.tap(provider);
    await tester.pumpAndSettle();
    await tester.tap(find.text('OpenAI Responses').last);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 450));

    final save = find.text('保存配置');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    final saved = await store.load();
    expect(saved?.provider, ModelProvider.openAiResponses);
    expect(saved?.baseUrl, Uri.parse('https://api.deepseek.com'));
    expect(saved?.apiKey, 'test-key');
  });
}

void _setPhoneSize(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(430, 860);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

AgentModelConfig _config(AgentReasoningEffort effort) => AgentModelConfig(
  provider: ModelProvider.openAi,
  baseUrl: Uri.parse('https://api.openai.com/v1'),
  model: 'gpt-5.5',
  apiKey: 'test-key',
  reasoningEffort: effort,
);

class _SettingsBridge implements DanshengBridge {
  Json profile = {
    'provider': 'openAi',
    'base_url': 'https://api.openai.com/v1',
    'model': 'gpt-5.5',
    'api_key': 'test-key',
  };

  @override
  Future<String> invoke(HostCommand command, String payload) async {
    expect(command, HostCommand.campus);
    final request = jsonDecode(payload) as Json;
    switch (request['method']) {
      case 'agent.settings.get':
        return jsonEncode(profile);
      case 'agent.settings.set':
        profile = request['params'] as Json;
        return '{"saved":true}';
      default:
        throw StateError('Unexpected campus bridge method');
    }
  }
}

// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:convert';

import 'package:dansheng_app/agent/agent_types.dart';
import 'package:dansheng_app/agent/model_catalog.dart';
import 'package:dansheng_app/bridge.g.dart';
import 'package:dansheng_app/ui/campus/agent/agent_chat_page.dart';
import 'package:dansheng_app/ui/campus/agent/agent_page.dart';
import 'package:dansheng_app/ui/core/dansheng_client.dart';
import 'package:dansheng_app/ui/core/dansheng_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _endpoint = 'https://model.example.test/api/v1';
const _testKey = 'fixture-only-key';

void main() {
  testWidgets('model settings work without a campus account', (tester) async {
    _setPhoneSize(tester);
    final bridge = _Bridge();
    final controller = _Controller(bridge);
    await tester.pumpWidget(
      MaterialApp(home: AgentPage(controller: controller)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('配置模型'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(_field('API 密钥')).obscureText, isTrue);
    await tester.tap(find.text('OpenAI 兼容'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Anthropic 兼容').last);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(_field('API 地址前缀')).controller!.text,
      AgentModelConfig.defaultBaseUrl(ModelProvider.anthropic).toString(),
    );
    expect(tester.widget<TextField>(_field('模型标识')).controller!.text, isEmpty);

    await tester.enterText(_field('API 地址前缀'), 'http://model.example.test');
    await tester.enterText(_field('模型标识'), 'test-model');
    await tester.enterText(_field('API 密钥'), _testKey);
    await tester.tap(find.text('保存配置'));
    await tester.pumpAndSettle();
    expect(bridge.config, isNull);
    expect(find.textContaining('HTTPS API 地址'), findsOneWidget);

    await tester.enterText(_field('API 地址前缀'), _endpoint);
    await tester.tap(find.text('保存配置'));
    await tester.pumpAndSettle();
    expect(bridge.config?['provider'], ModelProvider.anthropic.name);
    expect(bridge.config?['base_url'], _endpoint);
    expect(find.text('发送至 model.example.test'), findsOneWidget);
    expect(find.text(_testKey), findsNothing);
    expect(tester.widget<TextField>(_field('消息')).enabled, isTrue);
    expect(find.byType(SwitchListTile), findsNothing);
    await _openComposerOptions(tester);
    expect(find.textContaining(_endpoint), findsOneWidget);
    for (final source in AgentSourceKind.values) {
      final toggle = _sourceToggle(tester, source);
      expect(toggle.value, isFalse);
      expect(toggle.onChanged, source.requiresAccount ? isNull : isNotNull);
    }
    await _closeComposerOptions(tester);

    await tester.tap(find.byTooltip('模型设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移除配置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移除'));
    await tester.pumpAndSettle();
    expect(bridge.config, isNull);
    expect(find.text('配置模型'), findsOneWidget);
  });

  testWidgets('saved key stays bound to its protocol and normalized prefix', (
    tester,
  ) async {
    final bridge = _Bridge.configured();
    await _pumpChat(tester, _Controller(bridge));
    final key = _field('API 密钥');
    final prefix = _field('API 地址前缀');

    Future<void> openSettings() async {
      await tester.tap(find.byTooltip('模型设置'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(key).controller!.text, isEmpty);
      expect(find.text('留空保留已保存密钥'), findsOneWidget);
    }

    Future<void> save() async {
      await tester.tap(find.text('保存配置'));
      await tester.pumpAndSettle();
    }

    await openSettings();
    await tester.enterText(prefix, 'https://MODEL.example.test:443/api/v1/');
    await tester.enterText(_field('模型标识'), 'updated-test-model');
    await tester.pump();
    expect(find.text('留空保留已保存密钥'), findsOneWidget);
    await save();
    expect(bridge.config?['model'], 'updated-test-model');
    expect(bridge.config?['api_key'], _testKey);

    await openSettings();
    await tester.enterText(key, 'typed-for-original-address');
    await tester.enterText(prefix, 'https://other.example.test/api/v1');
    await tester.pump();
    expect(tester.widget<TextField>(key).controller!.text, isEmpty);
    expect(find.text('留空保留已保存密钥'), findsNothing);
    await save();
    expect(find.text('请输入 API 密钥。'), findsOneWidget);
    expect(bridge.config?['api_key'], _testKey);

    await tester.enterText(key, 'typed-for-other-address');
    await save();
    expect(bridge.config?['api_key'], 'typed-for-other-address');

    await openSettings();
    await tester.tap(find.text('OpenAI 兼容'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Anthropic 兼容').last);
    await tester.pumpAndSettle();
    expect(find.text('留空保留已保存密钥'), findsNothing);
    await save();
    expect(find.text('请输入 API 密钥。'), findsOneWidget);
    expect(bridge.config?['provider'], ModelProvider.openAi.name);

    await tester.enterText(key, 'typed-for-anthropic');
    await save();
    expect(bridge.config?['provider'], ModelProvider.anthropic.name);
    expect(bridge.config?['api_key'], 'typed-for-anthropic');
  });

  testWidgets('tool results need per-source consent and stay in their turn', (
    tester,
  ) async {
    final bridge = _Bridge.configured();
    final controller = _Controller(bridge, account: 'A');
    final models = await _pumpChat(tester, controller);
    await _openComposerOptions(tester);
    final forum = _sourceToggle(tester, AgentSourceKind.forum);
    expect(forum.value, isFalse);
    expect(forum.onChanged, isNull);
    await tester.tap(find.text(AgentSourceKind.campus.label));
    await tester.pump();
    expect(_sourceToggle(tester, AgentSourceKind.campus).value, isTrue);
    await _closeComposerOptions(tester);
    expect(find.byTooltip('添加与信息源，已启用 1 项'), findsOneWidget);
    await _send(tester, '查询图书馆');
    final model = models.single;
    model.requests.single.reply.complete(
      const AgentMessage.assistant('', [
        AgentToolCall('first', 'campus_library', {}),
        AgentToolCall('second', 'campus_library', {}),
      ]),
    );
    await tester.pumpAndSettle();
    expect(find.text('允许查询校园服务？'), findsOneWidget);
    expect(find.textContaining('查询结果将发送至 $_endpoint'), findsOneWidget);
    expect(bridge.campusReads, isEmpty);

    await tester.tap(find.text('仅本轮允许'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(bridge.campusReads, ['A', 'A']);
    final toolRound = model.requests[1];
    expect(
      toolRound.messages.where((message) => message.role == AgentRole.tool),
      hasLength(2),
    );
    toolRound.onText('流式回答');
    await tester.pump();
    expect(find.text('流式回答'), findsOneWidget);
    toolRound.reply.complete(const AgentMessage.assistant('图书馆查询结果'));
    await tester.pumpAndSettle();

    await _send(tester, '继续聊天');
    expect(model.requests.last.messages.map((message) => message.text), [
      '继续聊天',
    ]);
    expect(find.text('图书馆查询结果'), findsOneWidget);
    model.requests.last.reply.complete(const AgentMessage.assistant('普通回答'));
    await tester.pumpAndSettle();
    await _send(tester, '再聊一轮');
    expect(model.requests.last.messages.map((message) => message.text), [
      '继续聊天',
      '普通回答',
      '再聊一轮',
    ]);
    model.requests.last.reply.complete(const AgentMessage.assistant('新回答'));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'account switching closes consent and clears chat across A to B to A',
    (tester) async {
      final bridge = _Bridge.configured();
      final controller = _Controller(bridge, account: 'A', forum: true);
      final models = await _pumpChat(tester, controller);
      await _enableSource(tester, AgentSourceKind.campus);
      await _send(tester, 'A 的消息');
      final model = models.single;
      model.requests.single.reply.complete(
        const AgentMessage.assistant('', [
          AgentToolCall('read', 'campus_library', {}),
        ]),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);

      controller.beginSwitch();
      expect(model.closed, isTrue);
      await tester.pumpAndSettle();
      expect(find.text('正在切换账号…'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('A 的消息'), findsNothing);
      controller.finishSwitch('B');
      controller.beginSwitch();
      controller.finishSwitch('A');
      await tester.pumpAndSettle();
      expect(bridge.campusReads, isEmpty);
      await _openComposerOptions(tester);
      expect(_sourceToggle(tester, AgentSourceKind.campus).value, isFalse);
      controller.beginSwitch();
      await tester.pumpAndSettle();
      expect(find.text('信息源'), findsNothing);
      controller.finishSwitch('A');
      await tester.pumpAndSettle();
      await _send(tester, '新对话');
      final nextRequest = models.last.requests.single;
      expect(models, hasLength(2));
      expect(nextRequest.messages.map((message) => message.text), ['新对话']);
      expect(nextRequest.tools, isEmpty);
      nextRequest.reply.complete(const AgentMessage.assistant('你好'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('stop closes the model and discards late responses', (
    tester,
  ) async {
    final models = await _pumpChat(tester, _Controller(_Bridge.configured()));
    await _send(tester, '普通问题');
    final model = models.single;
    model.requests.single.onText('已收到的文字');
    await tester.pump();
    await tester.tap(find.byTooltip('停止生成'));
    await tester.pump();
    expect(model.closed, isTrue);
    model.requests.single.reply.complete(const AgentMessage.assistant('迟到的回答'));
    await tester.pumpAndSettle();
    expect(find.text('已收到的文字'), findsOneWidget);
    expect(find.text('迟到的回答'), findsNothing);

    await _send(tester, '新问题');
    expect(models, hasLength(2));
    expect(
      models.last.requests.single.messages.map((message) => message.text),
      ['新问题'],
    );
    models.last.requests.single.reply.complete(
      const AgentMessage.assistant('正常回答'),
    );
    await tester.pumpAndSettle();
  });

  testWidgets(
    'picks a file without an account and sends it only after confirmation',
    (tester) async {
      final bridge = _Bridge.configured();
      final models = await _pumpChat(tester, _Controller(bridge));
      await _openComposerOptions(tester);
      await tester.tap(find.text('添加附件'));
      await tester.pumpAndSettle();
      expect(find.text('notes.txt'), findsOneWidget);
      await tester.tap(find.byTooltip('移除 notes.txt'));
      await tester.pumpAndSettle();
      expect(find.text('notes.txt'), findsNothing);
      await _openComposerOptions(tester);
      await tester.tap(find.text('添加附件'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('发送'));
      await tester.pumpAndSettle();
      expect(find.text('发送附件？'), findsOneWidget);
      expect(find.textContaining(_endpoint), findsWidgets);
      expect(models, isEmpty);
      await tester.tap(find.text('拒绝'));
      await tester.pumpAndSettle();
      expect(find.text('notes.txt'), findsOneWidget);

      await tester.tap(find.byTooltip('发送'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('发送附件'));
      await tester.pumpAndSettle();
      final model = models.single;
      expect(
        model.requests.single.messages.single.attachments.single.text,
        'file fixture',
      );
      model.requests.single.reply.complete(
        const AgentMessage.assistant('文件摘要'),
      );
      await tester.pumpAndSettle();
      await _send(tester, '下一轮');
      expect(model.requests.last.messages.single.text, '下一轮');
      expect(model.requests.last.messages.single.attachments, isEmpty);
      model.requests.last.reply.complete(const AgentMessage.assistant('完成'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'shows the exact Brave Search query before permitting a request',
    (tester) async {
      final bridge = _Bridge.configured();
      bridge.config!['search_api_key'] = 'fixture-search-key';
      final models = await _pumpChat(tester, _Controller(bridge));
      await _openComposerOptions(tester);
      expect(find.text('通过 Brave Search 搜索'), findsOneWidget);
      await tester.tap(find.text(AgentSourceKind.web.label));
      await _closeComposerOptions(tester);
      await _send(tester, '搜索复旦通知');
      final model = models.single;
      expect(model.requests.single.tools.map((tool) => tool.name), [
        'web_search',
      ]);
      model.requests.single.reply.complete(
        const AgentMessage.assistant('', [
          AgentToolCall('read', 'web_search', {'query': '复旦大学 通知'}),
        ]),
      );
      await tester.pumpAndSettle();
      expect(find.text('搜索这些关键词？'), findsOneWidget);
      expect(find.textContaining('复旦大学 通知'), findsOneWidget);
      expect(model.requests, hasLength(1));
      await tester.tap(find.text('拒绝'));
      await tester.pumpAndSettle();
      expect(model.requests.last.messages.last.text, contains('未授权'));
      model.requests.last.reply.complete(const AgentMessage.assistant('无需搜索'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'legacy route keeps local controls and dismisses on account change',
    (tester) async {
      _setPhoneSize(tester);
      final bridge = _Bridge();
      final controller = _Controller(bridge, account: 'A');
      await tester.pumpWidget(
        MaterialApp(home: AgentPage(controller: controller)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('本地检索与配对'));
      await tester.pumpAndSettle();
      expect(find.text('当前账号：A'), findsOneWidget);
      expect(find.text('外部 AI 助手连接'), findsOneWidget);
      expect(find.text('智能问答'), findsOneWidget);
      expect(find.text('数据检索'), findsOneWidget);
      expect(bridge.legacyAccount, 'A');

      controller.beginSwitch();
      controller.finishSwitch('B');
      bridge.mcpStatus.complete({'running': true, 'port': 19888});
      await tester.pumpAndSettle();
      expect(find.text('外部 AI 助手连接'), findsNothing);
      expect(find.text('配置模型'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reopens, renames and deletes a persisted chat after relaunch', (
    tester,
  ) async {
    final bridge = _Bridge.configured();
    final models = await _pumpChat(tester, _Controller(bridge));
    await _send(tester, '复旦历史测试');
    models.single.requests.single.reply.complete(
      const AgentMessage.assistant('已经保存的回答'),
    );
    await tester.pumpAndSettle();
    expect(bridge.histories[null]!.values.single['title'], '复旦历史测试');

    await tester.pumpWidget(const SizedBox());
    final restored = await _pumpChat(tester, _Controller(bridge));
    await tester.tap(find.byTooltip('对话历史'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('对话选项'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    await tester.enterText(_field('对话标题'), '我保存的对话');
    await tester.tap(find.text('保存标题'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('我保存的对话'));
    await tester.pumpAndSettle();
    expect(find.text('已经保存的回答'), findsOneWidget);
    await _send(tester, '继续之前的话题');
    expect(
      restored.single.requests.single.messages.map((message) => message.text),
      ['复旦历史测试', '已经保存的回答', '继续之前的话题'],
    );
    restored.single.requests.last.reply.complete(
      const AgentMessage.assistant('继续回答'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('对话历史'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('对话选项'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除对话'));
    await tester.pumpAndSettle();
    expect(find.text('还没有对话'), findsOneWidget);
    expect(bridge.histories[null], isEmpty);
  });

  testWidgets(
    'narrow composer picks a friendly model name and keeps the raw ID',
    (tester) async {
      final bridge = _Bridge.configured();
      final configs = <AgentModelConfig>[];
      final models = await _pumpChat(
        tester,
        _Controller(bridge),
        size: const Size(320, 640),
        textScale: 1.8,
        onModel: configs.add,
        loadModels:
            ({required provider, required baseUrl, required apiKey}) async => [
              const ModelCatalogEntry('test-model'),
              const ModelCatalogEntry(
                'next-model',
                label: 'Next Generation Flash',
              ),
            ],
      );
      await _openComposerOptions(tester);
      expect(find.textContaining(_endpoint), findsOneWidget);
      await tester.ensureVisible(find.text(AgentSourceKind.web.label));
      expect(
        find.text(AgentSourceKind.web.label).hitTestable(),
        findsOneWidget,
      );
      await _closeComposerOptions(tester);
      expect(tester.takeException(), isNull);
      await _send(tester, '上一条消息');
      models.single.requests.single.reply.complete(
        const AgentMessage.assistant('上一条回答'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('chat-model-picker')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Next Generation Flash'));
      await tester.pumpAndSettle();
      expect(find.text('Next Generation Flash'), findsOneWidget);
      expect(find.text('上一条回答'), findsOneWidget);
      expect(bridge.config!['model'], 'next-model');
      expect(bridge.config!['model_label'], 'Next Generation Flash');
      await _send(tester, '下一条消息');
      expect(configs.last.model, 'next-model');
      expect(
        models.last.requests.single.messages.map((message) => message.text),
        ['上一条消息', '上一条回答', '下一条消息'],
      );
      models.last.requests.single.reply.complete(
        const AgentMessage.assistant('下一条回答'),
      );
      await tester.pumpAndSettle();
    },
  );

  testWidgets('a durable grant skips repeat prompts and can be revoked', (
    tester,
  ) async {
    final bridge = _Bridge.configured();
    final models = await _pumpChat(tester, _Controller(bridge, account: 'A'));
    await _enableSource(tester, AgentSourceKind.campus);
    final toolReply = const AgentMessage.assistant('', [
      AgentToolCall('read', 'campus_library', {}),
    ]);
    Future<void> ask(String question) async {
      await _send(tester, question);
      models.single.requests.last.reply.complete(toolReply);
      await tester.pumpAndSettle();
    }

    Future<void> finish() async {
      models.single.requests.last.reply.complete(
        const AgentMessage.assistant('已读取图书馆'),
      );
      await tester.pumpAndSettle();
    }

    await ask('第一次');
    await tester.tap(find.text('始终允许'));
    await tester.pumpAndSettle();
    expect(bridge.campusReads, ['A']);
    await finish();
    await ask('第二次');
    expect(find.text('允许查询校园服务？'), findsNothing);
    expect(bridge.campusReads, ['A', 'A']);
    await finish();
    await _openComposerOptions(tester);
    await tester.tap(find.text('管理授权'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await ask('第三次');
    expect(find.text('允许查询校园服务？'), findsOneWidget);
    await tester.tap(find.text('拒绝'));
    await tester.pumpAndSettle();
    expect(bridge.campusReads, ['A', 'A']);
    await finish();
  });
}

Finder _field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

SwitchListTile _sourceToggle(WidgetTester tester, AgentSourceKind source) =>
    tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, source.label),
    );

Future<void> _openComposerOptions(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('chat-composer-options')));
  await tester.pumpAndSettle();
}

Future<void> _closeComposerOptions(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await tester.pumpAndSettle();
}

Future<void> _enableSource(WidgetTester tester, AgentSourceKind source) async {
  await _openComposerOptions(tester);
  await tester.tap(find.text(source.label));
  await _closeComposerOptions(tester);
}

void _setPhoneSize(WidgetTester tester, [Size size = const Size(430, 860)]) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<List<_Model>> _pumpChat(
  WidgetTester tester,
  _Controller controller, {
  Size size = const Size(430, 860),
  double textScale = 1,
  void Function(AgentModelConfig)? onModel,
  ModelCatalogLoader? loadModels,
}) async {
  _setPhoneSize(tester, size);
  final models = <_Model>[];
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: AgentChatPage(
        controller: controller,
        onOpenLocal: () {},
        loadModels: loadModels,
        createModel: (config) {
          onModel?.call(config);
          final model = _Model();
          models.add(model);
          return model;
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
  return models;
}

Future<void> _send(WidgetTester tester, String text) async {
  await tester.enterText(_field('消息'), text);
  await tester.pump();
  await tester.tap(find.byTooltip('发送'));
  await tester.pump();
}

class _Controller extends DanshengController {
  _Controller(_Bridge bridge, {this.account, this.forum = false})
    : super(client: DanshengClient(bridge: bridge));

  String? account;
  final bool forum;
  int _generation = 0;
  bool _changing = false;

  @override
  String? get activeAccountId => account;

  @override
  bool get forumEnabled => forum;

  @override
  int get accountGeneration => _generation;

  @override
  bool get isChangingAccount => _changing;

  void beginSwitch() {
    _generation++;
    _changing = true;
    notifyListeners();
  }

  void finishSwitch(String? account) {
    this.account = account;
    _changing = false;
    notifyListeners();
  }
}

class _Bridge implements DanshengBridge {
  _Bridge();

  _Bridge.configured()
    : config = {
        'provider': 'openAi',
        'base_url': _endpoint,
        'model': 'test-model',
        'api_key': _testKey,
      };

  Json? config;
  final histories = <String?, Map<String, Json>>{};
  final approvals = <(String?, String), Set<String>>{};
  final campusReads = <String?>[];
  String? legacyAccount;
  final mcpStatus = Completer<Json>();

  @override
  Future<String> invoke(HostCommand command, String payload) async {
    expect(command, HostCommand.campus);
    final request = jsonDecode(payload) as Json;
    final params = request['params'] as Json;
    switch (request['method']) {
      case 'agent.settings.get':
        return jsonEncode(config);
      case 'agent.settings.set':
        config = params;
        return '{}';
      case 'agent.settings.clear':
        config = null;
        return '{}';
      case 'agent.history.save':
        final history = histories.putIfAbsent(
          params['account_id'] as String?,
          () => {},
        );
        final chat = params['conversation'] as Json;
        final id = chat['id'] as String;
        final created = !history.containsKey(id);
        history[id] = chat;
        return jsonEncode({'saved': true, 'created': created});
      case 'agent.history.list':
        final history =
            histories[params['account_id']]?.values ?? const <Json>[];
        return jsonEncode([
          for (final chat in history)
            {
              'id': chat['id'],
              'title': chat['title'],
              'updated_at': chat['updated_at'],
            },
        ]);
      case 'agent.history.get':
        return jsonEncode(histories[params['account_id']]?[params['id']]);
      case 'agent.history.rename':
        histories[params['account_id']]?[params['id']]
          ?..['title'] = params['title']
          ..['updated_at'] = params['updated_at'];
        return '{}';
      case 'agent.history.delete':
        histories[params['account_id']]?.remove(params['id']);
        return '{}';
      case 'agent.approvals.get':
        return jsonEncode(
          approvals[(params['account_id'], params['destination'])]?.toList() ??
              [],
        );
      case 'agent.approvals.allow':
        approvals
            .putIfAbsent((
              params['account_id'] as String?,
              params['destination'] as String,
            ), () => {})
            .add(params['permission'] as String);
        return '{}';
      case 'agent.approvals.revoke':
        approvals[(params['account_id'], params['destination'])]?.remove(
          params['permission'],
        );
        return '{}';
      case 'agent.attachment.pick':
        expect(params, isEmpty);
        return jsonEncode({
          'name': 'notes.txt',
          'mime_type': 'text/plain',
          'data': base64Encode(utf8.encode('file fixture')),
        });
      case 'agent.mcp.status':
        legacyAccount = params['account_id'] as String?;
        return jsonEncode(await mcpStatus.future);
      case 'fudan.library.occupancy':
        campusReads.add(params['account_id'] as String?);
        return '[]';
      default:
        fail('Unexpected test host method ${request['method']}');
    }
  }
}

class _ModelRequest {
  _ModelRequest(this.messages, this.tools, this.onText);

  final List<AgentMessage> messages;
  final List<AgentToolSpec> tools;
  final void Function(String) onText;
  final reply = Completer<AgentMessage>();
}

class _Model implements AgentModel {
  final requests = <_ModelRequest>[];
  bool closed = false;

  @override
  Future<AgentMessage> complete({
    required List<AgentMessage> messages,
    required List<AgentToolSpec> tools,
    required void Function(String) onText,
  }) {
    final request = _ModelRequest(messages, tools, onText);
    requests.add(request);
    return request.reply.future;
  }

  @override
  void close() => closed = true;
}

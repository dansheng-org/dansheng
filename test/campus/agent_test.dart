// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';

import 'package:dansheng_app/bridge.g.dart';
import 'package:dansheng_app/ui/campus/agent/agent_page.dart';
import 'package:dansheng_app/ui/campus/agent/agent_service.dart';
import 'package:dansheng_app/ui/campus/campus_api.dart';
import 'package:dansheng_app/ui/core/dansheng_client.dart';
import 'package:dansheng_app/ui/core/dansheng_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class AgentMockBridge implements DanshengBridge {
  String? accountId = 'user_001';
  bool mcpRunning = false;
  int mcpPort = 19888;
  String mcpToken = 'mock_crypto_token_64_bytes_hex_value_for_testing_0123456789abcdef';
  final List<Map<String, dynamic>> campusInvocations = [];

  @override
  Future<String> invoke(HostCommand command, String payload) async {
    final Map<String, dynamic> params = payload.isNotEmpty
        ? (jsonDecode(payload) as Map<String, dynamic>)
        : <String, dynamic>{};

    switch (command) {
      case HostCommand.campus:
        final method = params['method']?.toString() ?? '';
        final methodParams = params['params'] as Map<String, dynamic>? ?? {};
        campusInvocations.add({'method': method, 'params': methodParams});

        if (method == 'agent.query') {
          return jsonEncode({
            'account_id': accountId ?? '',
            'query': methodParams['query'] ?? '',
            'hits': [
              {
                'source_id': 'official.fudan-courses',
                'external_id': 'course_101',
                'account_id': accountId ?? '',
                'kind': 'course',
                'title': '计算机体系结构',
                'snippet': '周一 3-5 节 Z2201 教室',
                'updated_at': '2026-11-08 10:00:00',
              },
              {
                'source_id': 'official.fudan.ecard.balance',
                'external_id': 'ecard-balance',
                'account_id': accountId ?? '',
                'kind': 'card',
                'title': '校园卡余额',
                'snippet': '当前余额 68.50 CNY',
                'updated_at': '2026-11-08 12:00:00',
              },
            ],
          });
        } else if (method == 'agent.ask') {
          return jsonEncode({
            'question': methodParams['question'] ?? '',
            'account_id': accountId ?? '',
            'answer': '根据当前账号（user_001）的本地离线数据，检索到以下相关证据：\n\n【证据 1】计算机体系结构\n  摘录：周一 3-5 节 Z2201 教室\n\n提示：以上回答均由本地离线证据总结生成，不含远程大模型推测。',
            'sources': [
              {
                'index': 1,
                'label': '[1] 计算机体系结构 · official.fudan-courses',
                'title': '计算机体系结构',
                'source_id': 'official.fudan-courses',
                'external_id': 'course_101',
                'kind': 'course',
                'snippet': '周一 3-5 节 Z2201 教室',
                'updated_at': '2026-11-08 10:00:00',
              },
            ],
            'evidence_count': 1,
          });
        } else if (method == 'agent.mcp.start') {
          mcpRunning = true;
          // Notice: token is NOT returned on start
          return jsonEncode({
            'running': true,
            'port': mcpPort,
            'account_id': accountId,
            'url': 'http://127.0.0.1:$mcpPort/mcp',
            'adb_command': 'adb forward tcp:$mcpPort tcp:$mcpPort',
          });
        } else if (method == 'agent.mcp.stop') {
          mcpRunning = false;
          return jsonEncode({'running': false});
        } else if (method == 'agent.mcp.status') {
          // Notice: token is NOT returned on status
          return jsonEncode({
            'running': mcpRunning,
            'port': mcpRunning ? mcpPort : 0,
            'account_id': accountId,
            'url': mcpRunning ? 'http://127.0.0.1:$mcpPort/mcp' : '',
            'adb_command': mcpRunning ? 'adb forward tcp:$mcpPort tcp:$mcpPort' : '',
          });
        } else if (method == 'agent.mcp.token') {
          // Token is returned ONLY on explicit copy command
          return jsonEncode({
            'token': mcpToken,
          });
        }
        return jsonEncode({'status': 'ok'});

      case HostCommand.account:
        return jsonEncode({'account_id': accountId});

      case HostCommand.setAccount:
        accountId = params['account_id']?.toString();
        return jsonEncode({'account_id': accountId});

      case HostCommand.info:
        return jsonEncode({'version': '0.1.0'});

      case HostCommand.plugins:
        return jsonEncode([]);

      case HostCommand.jobs:
        return jsonEncode([]);

      case HostCommand.permissions:
        return jsonEncode({'exact_available': false, 'notifications_available': false});

      case HostCommand.balance:
        return jsonEncode({'balance': '68.50', 'currency': 'CNY'});

      default:
        return jsonEncode({});
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CampusAgent Dart Service Unit Tests', () {
    late AgentMockBridge bridge;
    late DanshengClient client;
    late AgentService service;

    setUp(() {
      bridge = AgentMockBridge();
      client = DanshengClient(bridge: bridge);
      service = AgentService(CampusApi(client));
    });

    test('search sends agent.query and parses typed hits', () async {
      final hits = await service.search('体系结构', limit: 10);
      expect(hits.length, 2);
      expect(hits[0].title, '计算机体系结构');
      expect(hits[0].kind, 'course');
      expect(hits[0].sourceId, 'official.fudan-courses');
      expect(hits[1].title, '校园卡余额');
      expect(hits[1].kind, 'card');

      final lastCall = bridge.campusInvocations.last;
      expect(lastCall['method'], 'agent.query');
      expect(lastCall['params']['query'], '体系结构');
      expect(lastCall['params']['limit'], 10);
    });

    test('ask sends agent.ask and parses answer with evidence sources', () async {
      final answer = await service.ask('明天有什么课');
      expect(answer.question, '明天有什么课');
      expect(answer.accountId, 'user_001');
      expect(answer.evidenceCount, 1);
      expect(answer.sources.length, 1);
      expect(answer.sources[0].title, '计算机体系结构');
      expect(answer.sources[0].label, contains('official.fudan-courses'));
      expect(answer.sources[0].snippet, contains('Z2201'));

      final lastCall = bridge.campusInvocations.last;
      expect(lastCall['method'], 'agent.ask');
      expect(lastCall['params']['question'], '明天有什么课');
    });

    test('MCP lifecycle start, status, explicit token copy, and stop', () async {
      final initial = await service.getMcpStatus();
      expect(initial.running, false);
      expect(initial.token, isNull);

      final started = await service.startMcp(port: 19888);
      expect(started.running, true);
      expect(started.port, 19888);
      expect(started.token, isNull); // Token not returned on start
      expect(started.url, 'http://127.0.0.1:19888/mcp');
      expect(started.adbCommand, 'adb forward tcp:19888 tcp:19888');

      final current = await service.getMcpStatus();
      expect(current.running, true);
      expect(current.token, isNull); // Token not returned on status

      // Explicit copy command retrieves the token
      final token = await service.getMcpToken();
      expect(token, bridge.mcpToken);

      final stopped = await service.stopMcp();
      expect(stopped.running, false);
    });
  });

  group('CampusAgent AgentPage Widget Tests', () {
    late AgentMockBridge bridge;
    late DanshengClient client;
    late DanshengController controller;

    setUp(() async {
      bridge = AgentMockBridge();
      client = DanshengClient(bridge: bridge);
      controller = DanshengController(client: client);
      await controller.initialize();
    });

    testWidgets('Initial view renders concise UI, account bar, and MCP is OFF by default', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: AgentPage(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('校园助手'), findsOneWidget);
      expect(find.text('当前账号：user_001'), findsOneWidget);
      expect(find.text('外部 AI 助手连接'), findsOneWidget);
      expect(find.text('已停止 (未监听端口)'), findsOneWidget);

      // Verify no plain tokens exist in widget tree
      expect(find.text(bridge.mcpToken), findsNothing);

      // Mode segments
      expect(find.text('智能问答'), findsOneWidget);
      expect(find.text('数据检索'), findsOneWidget);
    });

    testWidgets('Toggling MCP starts loopback server, masks token, and enables explicit copy', (tester) async {
      String? copiedClipboardText;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall methodCall) async {
          if (methodCall.method == 'Clipboard.setData') {
            copiedClipboardText = (methodCall.arguments as Map)['text']?.toString();
            return null;
          }
          return null;
        },
      );

      await tester.pumpWidget(
        MaterialApp(
          home: AgentPage(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      // Tap Switch to enable MCP
      final switchFinder = find.byType(Switch);
      expect(switchFinder, findsOneWidget);
      await tester.tap(switchFinder);
      await tester.pumpAndSettle();

      // Verify MCP running status
      expect(find.text('服务已就绪 (端口: 19888)'), findsOneWidget);
      expect(find.text('http://127.0.0.1:19888/mcp'), findsOneWidget);

      // Verify token is masked on screen
      expect(find.text('••••••••••••••••••••••••'), findsOneWidget);
      expect(find.text(bridge.mcpToken), findsNothing);

      // Tap copy token (triggers explicit agent.mcp.token)
      final copyTokenBtn = find.widgetWithText(OutlinedButton, '复制连接凭据');
      expect(copyTokenBtn, findsOneWidget);
      await tester.tap(copyTokenBtn);
      await tester.pumpAndSettle();

      expect(copiedClipboardText, bridge.mcpToken);
      expect(find.text('已复制连接凭据，请在电脑端外部工具中配置。'), findsOneWidget);

      // Verify agent.mcp.token was explicitly called
      final tokenCall = bridge.campusInvocations.firstWhere((c) => c['method'] == 'agent.mcp.token');
      expect(tokenCall, isNotNull);

      // Tap copy ADB command
      final copyAdbBtn = find.widgetWithText(OutlinedButton, '复制电脑映射命令');
      expect(copyAdbBtn, findsOneWidget);
      await tester.tap(copyAdbBtn);
      await tester.pumpAndSettle();

      expect(copiedClipboardText, 'adb forward tcp:19888 tcp:19888');

      // Tap Switch again to stop MCP
      await tester.tap(switchFinder);
      await tester.pumpAndSettle();

      expect(find.text('已停止 (未监听端口)'), findsOneWidget);
    });

    testWidgets('Local Ask query renders evidence-based answer with readable source excerpt', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: AgentPage(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      // Enter question
      final inputFinder = find.byType(TextField);
      await tester.enterText(inputFinder, '明天有什么课');
      await tester.pumpAndSettle();

      // Tap submit
      final askButton = find.widgetWithText(FilledButton, '向助手提问');
      await tester.tap(askButton);
      await tester.pumpAndSettle();

      // Answer view
      expect(find.text('本地证据回答'), findsOneWidget);
      expect(find.text('非大模型推测'), findsOneWidget);
      expect(find.textContaining('计算机体系结构'), findsWidgets);

      // Labeled source card with readable excerpt
      expect(find.text('已引用的本地证据来源 (1)'), findsOneWidget);
      expect(find.text('[来源 1]'), findsOneWidget);
      expect(find.text('official.fudan-courses'), findsOneWidget);
      expect(find.text('课程'), findsOneWidget);
      expect(find.text('可读摘录：'), findsOneWidget);
      expect(find.text('周一 3-5 节 Z2201 教室'), findsOneWidget);
    });

    testWidgets('Local Search mode renders typed hit cards with snippets', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: AgentPage(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      // Switch to search mode
      await tester.tap(find.text('数据检索'));
      await tester.pumpAndSettle();

      // Enter search query
      final inputFinder = find.byType(TextField);
      await tester.enterText(inputFinder, '体系结构');
      await tester.pumpAndSettle();

      // Tap submit
      final searchButton = find.widgetWithText(FilledButton, '开始检索');
      await tester.tap(searchButton);
      await tester.pumpAndSettle();

      // Hits view
      expect(find.text('检索命中 (2 条记录)'), findsOneWidget);
      expect(find.text('计算机体系结构'), findsOneWidget);
      expect(find.text('校园卡余额'), findsOneWidget);
      expect(find.text('校园卡'), findsOneWidget);
      expect(find.text('周一 3-5 节 Z2201 教室'), findsOneWidget);
    });
  });
}

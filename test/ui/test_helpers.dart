import 'dart:convert';

import 'package:dansheng_app/bridge.g.dart';
import 'package:dansheng_app/ui/core/dansheng_client.dart';
import 'package:dansheng_app/ui/core/dansheng_state.dart';
import 'package:dansheng_app/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';

/// Test mock implementation of DanshengBridge.
class MockDanshengBridge implements DanshengBridge {
  List<Map<String, dynamic>> plugins = [];
  List<Map<String, dynamic>> jobs = [];
  String? accountId = 'user_001';
  Map<String, dynamic> balanceData = {
    'balance': '88.50',
    'currency': 'CNY',
    'updated_at': '2026-11-08 12:00:00',
  };
  Map<String, dynamic> permissions = {
    'exact_available': false,
    'notifications_available': false,
  };
  Map<String, dynamic> info = {
    'version': '0.1.0',
    'core': 'dansheng-core-mock',
  };
  int currentEventCursor = 0;
  List<Map<String, dynamic>> pendingEvents = [];
  bool openTasksOnPoll = false;

  final Map<String, dynamic Function(Map<String, dynamic> input)>
  actionHandlers = {};
  final List<Map<String, dynamic>> invocationLog = [];

  Future<dynamic> Function(String method, Map<String, dynamic> params)?
  campusHandler;

  dynamic _handleDefaultCampus(
    String method,
    Map<String, dynamic> methodParams,
  ) {
    switch (method) {
      case 'venues.venues':
        return [
          {'id': 900, 'name': '正大体育馆羽毛球场'},
          {'id': 901, 'name': '南区网球场'},
        ];
      case 'venues.calendar':
        return {
          'slots': [
            {
              'period_id': 71,
              'time': '10:00-11:00',
              'court_id': 101,
              'court_name': '1号场地',
              'available': true,
            },
            {
              'period_id': 72,
              'time': '11:00-12:00',
              'court_id': 102,
              'court_name': '2号场地',
              'available': false,
            },
          ],
        };
      case 'venues.appointments':
        return [
          {
            'id': 301,
            'resource_name': '正大体育馆羽毛球场',
            'date': '2026-11-08',
            'time': '10:00-11:00',
            'court_name': '1号场地',
            'status': '预约成功',
            'is_cancel': true,
          },
        ];
      case 'venues.detail':
        return {
          'id': 301,
          'resource_name': '正大体育馆羽毛球场',
          'status': '已生效',
          'code': 'VOUCHER-TEST-9988',
        };
      case 'venues.prepareManual':
        final vid = methodParams['venue_id'];
        final tdate = methodParams['target_date'];
        final pid = methodParams['period_id'];
        final cid = methodParams['court_id'];
        final time = methodParams['time'];
        return {
          'canonical_input': {
            'account_id': accountId,
            'task_id': 'manual-test-task',
            'venue_id': vid,
            'target_date': tdate,
            'period_id': pid,
            'court_id': cid,
            'time': time,
          },
          'summary': '单次预约: 场馆 #$vid, 日期 $tdate, 场地 #$cid, 时段 $time',
          'input_sha256': 'mock_sha256_hash_123',
        };
      case 'venues.reserve':
        return {'status': 'success', 'message': '预约成功'};
      case 'venues.reservePlan':
        return {'successes': methodParams['slots'], 'message': '预约成功'};
      case 'venues.reconcile':
        return {'reconciled': true};
      case 'fudan.semesters':
        return {
          'semesters': [
            {'external_id': '2026-autumn', 'name': '2026年秋季学期'},
          ],
          'default_semester_id': '2026-autumn',
        };
      case 'fudan.student_association':
        return {'student_association': 'assoc_001', 'id': 'assoc_001'};
      case 'fudan.rooms':
        return [
          {'room': 'H3101', 'available': true},
        ];
      case 'fudan.electricity':
        return {'balance': '35.5', 'unit': '度'};
      case 'fudan.library.occupancy':
        return {'total': 1000, 'used': 450};
      case 'fudan.dining.occupancy':
        return {'dining_halls': []};
      case 'fudan.bus':
        return {'buses': []};
      case 'fudan.notices':
        return [
          {'title': '校车调整通知', 'date': '2026-11-08'},
        ];
      case 'fudan.ecard.transactions':
        return {'transactions': []};
      case 'fudan.gpa':
        return {'gpa': '3.85'};
      case 'fudan.grades':
        return {'grades': []};
      case 'fudan.exams':
        return {'exams': []};
      case 'timetable.semesters':
      case 'academic.timetable':
        return {
          'semesters': [
            {'id': '2026-autumn', 'name': '2026年秋季学期'},
          ],
          'default_semester_id': '2026-autumn',
          'courses': [],
        };
      case 'canvas.courses':
      case 'canvas.activities':
      case 'canvas.folders':
      case 'canvas.files':
        return [];
      case 'agent.query':
        return {'hits': []};
      case 'agent.ask':
        return {
          'question': methodParams['question'] ?? '',
          'account_id': accountId ?? '',
          'answer': '这是本地问答模拟结果。',
          'sources': [],
          'evidence_count': 0,
        };
      case 'agent.mcp.status':
        return {'running': false, 'port': 0};
      case 'agent.mcp.start':
        return {'running': true, 'port': methodParams['port'] ?? 8080};
      case 'agent.mcp.stop':
        return {'running': false, 'port': 0};
      case 'community.tea.divisions':
        return [
          {'id': 1, 'name': '日常讨论', 'description': '校园日常'},
        ];
      case 'community.tea.holes':
        return [];
      case 'community.tea.hole':
        return null;
      case 'community.tea.floors':
        return [];
      default:
        return <String, dynamic>{};
    }
  }

  @override
  Future<String> invoke(HostCommand command, String payload) async {
    final Map<String, dynamic> params = payload.isNotEmpty
        ? (jsonDecode(payload) as Map<String, dynamic>)
        : <String, dynamic>{};

    invocationLog.add({'command': command, 'params': params});

    switch (command) {
      case HostCommand.info:
        return jsonEncode(info);

      case HostCommand.plugins:
        return jsonEncode(plugins);

      case HostCommand.importPackage:
        // Empty params {} opens native SAF picker
        final newPlugin = {
          'id': 'imported.plugin',
          'name': '导入的插件包',
          'version': '1.0.0',
          'enabled': false,
          'manifest': {
            'id': 'imported.plugin',
            'name': '导入的插件包',
            'version': '1.0.0',
            'capabilities': ['storage.read', 'http.request'],
            'network': ['https://api.example.com'],
            'ui': [
              {
                'id': 'main',
                'type': 'card',
                'title': '插件主页',
                'ui_version': 1,
                'fields': [],
                'buttons': [],
              },
            ],
          },
        };
        plugins.add(newPlugin);
        return jsonEncode({'status': 'imported', 'picker': 'saf'});

      case HostCommand.enablePlugin:
        final pid = params['plugin_id']?.toString();
        for (final p in plugins) {
          if (p['id'] == pid) {
            p['enabled'] = true;
          }
        }
        return jsonEncode({'status': 'enabled'});

      case HostCommand.disablePlugin:
        final pid = params['plugin_id']?.toString();
        for (final p in plugins) {
          if (p['id'] == pid) {
            p['enabled'] = false;
          }
        }
        return jsonEncode({'status': 'disabled'});

      case HostCommand.removePlugin:
        final pid = params['plugin_id']?.toString();
        plugins.removeWhere((p) => p['id'] == pid);
        return jsonEncode({'status': 'removed'});

      case HostCommand.component:
        final compId = params['id']?.toString() ?? '';
        return jsonEncode({
          'id': compId,
          'type': 'card',
          'title': '动态组件卡片',
          'status': '运行正常',
          'items': ['条目 A', '条目 B'],
        });

      case HostCommand.preview:
        final action = params['action']?.toString() ?? '';
        final input = params['input'] as Map<String, dynamic>? ?? {};
        // Ensure input NEVER has approved inserted
        if (input.containsKey('approved')) {
          throw Exception('Caller cannot insert approved');
        }
        return jsonEncode({
          'input_sha256': 'mock_sha256_${action}_hash',
          'summary': '操作预览: $action，影响范围 1 项',
        });

      case HostCommand.runAction:
        final action = params['action']?.toString() ?? '';
        final input = params['input'] as Map<String, dynamic>? ?? {};
        // Ensure input NEVER has approved inserted
        if (input.containsKey('approved')) {
          throw Exception('Caller cannot insert approved');
        }

        if (actionHandlers.containsKey(action)) {
          final res = actionHandlers[action]!(input);
          return jsonEncode(res);
        }

        return jsonEncode({
          'result': 'success',
          'action': action,
          'echo_account': input['account_id'],
        });

      case HostCommand.jobs:
        return jsonEncode(jobs);

      case HostCommand.events:
        final after = params['after'] as int?;
        return jsonEncode({
          'cursor': (after ?? 0) + 1,
          'events': pendingEvents,
          'open_tasks': openTasksOnPoll,
          'resync_required': false,
        });

      case HostCommand.account:
        return jsonEncode({'account_id': accountId});

      case HostCommand.setAccount:
        accountId = params['account_id']?.toString();
        return jsonEncode({'account_id': accountId});

      case HostCommand.permissions:
        return jsonEncode(permissions);

      case HostCommand.openAlarmSettings:
        permissions['exact_available'] = true;
        return jsonEncode({'opened': true});

      case HostCommand.requestNotifications:
        permissions['notifications_available'] = true;
        return jsonEncode({'granted': true});

      case HostCommand.balance:
        return jsonEncode(balanceData);

      case HostCommand.campus:
        final method = params['method']?.toString() ?? '';
        final methodParams = params['params'] as Map<String, dynamic>? ?? {};
        if (campusHandler != null) {
          final res = await campusHandler!(method, methodParams);
          return jsonEncode(res);
        }
        return jsonEncode(_handleDefaultCampus(method, methodParams));
    }
  }
}

/// Helper to wrap a widget for widget testing with Chinese locale and theme.
Widget buildTestApp({
  required Widget home,
  DanshengController? controller,
  ThemeMode themeMode = ThemeMode.light,
  double textScale = 1.0,
  Locale? locale,
  Iterable<LocalizationsDelegate<dynamic>>? localizationsDelegates,
}) {
  Widget buildApp() {
    return MaterialApp(
      title: '诞生测试',
      locale: locale,
      localizationsDelegates: localizationsDelegates,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: controller?.themeMode ?? themeMode,
      home: MediaQuery(
        data: const MediaQueryData().copyWith(
          textScaler: TextScaler.linear(controller?.textScale ?? textScale),
        ),
        child: home,
      ),
    );
  }

  if (controller != null) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => buildApp(),
    );
  }
  return buildApp();
}

// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:convert';

import 'package:dansheng_app/bridge.g.dart';
import 'package:dansheng_app/ui/campus/campus_api.dart';
import 'package:dansheng_app/ui/campus/forum/forum_page.dart';
import 'package:dansheng_app/ui/campus/forum/forum_search_page.dart';
import 'package:dansheng_app/ui/campus/forum/forum_service.dart';
import 'package:dansheng_app/ui/campus/forum/hole_detail_page.dart';
import 'package:dansheng_app/ui/core/dansheng_client.dart';
import 'package:dansheng_app/ui/core/dansheng_state.dart';
import 'package:dansheng_app/ui/theme/app_theme.dart';
import 'package:dansheng_app/ui/screens/account_balance_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Test mock bridge for offline verification of campus forum features.
class MockForumDanshengBridge implements DanshengBridge {
  final List<Map<String, dynamic>> invocationLog = [];
  final Map<String, List<Map<String, dynamic>>> responsePages = {};
  bool simulateUncertainPublish = false;
  bool simulateAuthRequired = false;
  bool consentRequired = false;
  String? loginError;
  Completer<void>? loginPending;
  String? reconcileOutcome; // 'success' | 'unresolved' | 'empty'

  @override
  Future<String> invoke(HostCommand command, String payload) async {
    final Map<String, dynamic> params = payload.isNotEmpty
        ? (jsonDecode(payload) as Map<String, dynamic>)
        : <String, dynamic>{};

    invocationLog.add({'command': command, 'params': params});

    if (command == HostCommand.campus) {
      final method = params['method']?.toString() ?? '';
      final methodParams = params['params'] as Map<String, dynamic>? ?? {};

      if (consentRequired && method != 'campus.login') {
        throw PlatformException(code: 'ForumConsentRequired');
      }
      if (simulateAuthRequired && method != 'campus.login') {
        throw PlatformException(
          code: 'AuthenticationRequired',
          message: 'Forum authentication required',
        );
      }

      final pages = responsePages[method];
      if (pages != null) {
        return jsonEncode(pages.removeAt(0));
      }

      switch (method) {
        case 'community.tea.divisions':
          return jsonEncode({
            'source': {
              'account_id': 'user_001',
              'source_id': 'community-test',
              'origin': 'https://forum.fduhole.com',
            },
            'source_revision': 'rev_test_1',
            'records': [
              {
                'external_id': 'tea-division:1',
                'payload': {
                  'division_id': 1,
                  'name': '合成分区',
                  'description': '测试分区一',
                  'pinned': [
                    {
                      'hole_id': 999,
                      'division_id': 1,
                      'time_created': '2026-11-01T08:00:00Z',
                      'time_updated': '2026-11-01T08:00:00Z',
                      'reply': 3,
                      'view': 60,
                      'floors': {
                        'first_floor': {
                          'floor_id': 901,
                          'hole_id': 999,
                          'content': '置顶公告：欢迎来到复旦树洞！',
                          'anonyname': '管理员',
                          'time_created': '2026-11-01T08:00:00Z',
                          'deleted': false,
                        },
                        'last_floor': null,
                      },
                      'tags': ['公告'],
                      'hidden': false,
                      'locked': false,
                      'token': 'LEAK_TOKEN_SECRET_999',
                    },
                  ],
                },
              },
              {
                'external_id': 'tea-division:2',
                'payload': {
                  'division_id': 2,
                  'name': '校园生活',
                  'description': '生活趣事',
                  'pinned': [],
                },
              },
            ],
            'coverage': 'Complete',
          });

        case 'community.tea.holes':
          final div = methodParams['division'] ?? methodParams['division_id'];
          final order = methodParams['order'];

          final List<Map<String, dynamic>> records = [];

          if (div == null || div == 1) {
            records.add({
              'external_id': 'tea-hole:101',
              'payload': {
                'hole_id': 101,
                'division_id': 1,
                'time_created': '2026-11-01T10:00:00Z',
                'time_updated': order == 'created'
                    ? '2026-11-01T10:00:00Z'
                    : '2026-11-02T12:00:00Z',
                'reply': 2,
                'view': 25,
                'floors': {
                  'first_floor': {
                    'floor_id': 501,
                    'hole_id': 101,
                    'content': '合成测试帖子内容 <tex>E=mc^2</tex> 包含图片 ![pic](https://img.test/1.png)',
                    'anonyname': 'Synthetic',
                    'time_created': '2026-11-01T10:00:00Z',
                    'deleted': false,
                  },
                  'last_floor': null,
                },
                'tags': ['日常', '学术'],
                'hidden': false,
                'locked': false,
                'token': 'LEAK_TOKEN_HOLE_101',
              },
            });
          }

          if (div == null || div == 2) {
            records.add({
              'external_id': 'tea-hole:102',
              'payload': {
                'hole_id': 102,
                'division_id': 2,
                'time_created': '2026-11-03T09:00:00Z',
                'time_updated': '2026-11-03T09:30:00Z',
                'reply': 1,
                'view': 10,
                'floors': {
                  'first_floor': {
                    'floor_id': 601,
                    'hole_id': 102,
                    'content': '今天北区食堂饭菜不错',
                    'anonyname': '吃货同学',
                    'time_created': '2026-11-03T09:00:00Z',
                    'deleted': false,
                  },
                  'last_floor': null,
                },
                'tags': ['美食'],
                'hidden': false,
                'locked': false,
              },
            });
          }

          return jsonEncode({
            'records': records,
            'coverage': {
              'Window': {'position': '2026-11-01T00:00:00Z'},
            },
          });

        case 'community.tea.hole':
          final holeId = methodParams['hole_id'];
          return jsonEncode({
            'external_id': 'tea-hole:$holeId',
            'payload': {
              'hole_id': holeId,
              'division_id': 1,
              'time_created': '2026-11-01T10:00:00Z',
              'time_updated': '2026-11-02T12:00:00Z',
              'reply': 2,
              'view': 25,
              'floors': {
                'first_floor': {
                  'floor_id': 501,
                  'hole_id': holeId,
                  'content': '合成测试帖子内容 <tex>E=mc^2</tex>',
                  'anonyname': 'Synthetic',
                  'time_created': '2026-11-01T10:00:00Z',
                  'deleted': false,
                },
                'last_floor': null,
              },
              'tags': ['日常'],
              'hidden': false,
              'locked': false,
              'token': 'LEAK_TOKEN_SECRET_501',
            },
          });

        case 'community.tea.floors':
          final holeId = methodParams['hole_id'];
          return jsonEncode({
            'records': [
              {
                'external_id': 'tea-floor:501',
                'payload': {
                  'floor_id': 501,
                  'hole_id': holeId,
                  'content': '首楼正文：复习微积分，欢迎讨论',
                  'anonyname': 'Synthetic',
                  'time_created': '2026-11-01T10:00:00Z',
                  'deleted': false,
                  'like': 5,
                  'dislike': 0,
                },
              },
              {
                'external_id': 'tea-floor:502',
                'payload': {
                  'floor_id': 502,
                  'hole_id': holeId,
                  'content': '第二楼回复：我也在看这门课！',
                  'anonyname': 'Alice',
                  'time_created': '2026-11-01T11:00:00Z',
                  'deleted': false,
                  'like': 2,
                  'dislike': 0,
                },
              },
              {
                'external_id': 'tea-floor:503',
                'payload': {
                  'floor_id': 503,
                  'hole_id': holeId,
                  'content': null,
                  'anonyname': null,
                  'time_created': '2026-11-01T12:00:00Z',
                  'deleted': true,
                  'like': 0,
                  'dislike': 0,
                },
              },
            ],
            'coverage': {
              'Page': {'next': null, 'total': 3},
            },
          });

        case 'forum.search':
          final query = methodParams['query']?.toString() ?? '';
          return jsonEncode({
            'items': [
              {
                'hole_id': 101,
                'floor_id': 501,
                'content': '关于 $query 的相关树洞讨论',
                'anonyname': 'Synthetic',
                'time_created': '2026-11-01T10:00:00Z',
                'tags': ['日常'],
                'deleted': false,
              },
              {
                'hole_id': 101,
                'floor_id': 502,
                'content': '已被删除的内容',
                'anonyname': 'Bob',
                'time_created': '2026-11-01T11:00:00Z',
                'tags': [],
                'deleted': true,
              },
            ],
            'offset': methodParams['offset'] ?? 0,
            'count': 2,
          });

        case 'forum.publish':
          if (simulateUncertainPublish) {
            throw PlatformException(
              code: 'NeedsReconciliation',
              message: 'Transaction outcome uncertain, please reload',
            );
          }
          return jsonEncode({'hole_id': 103, 'result': 'success'});

        case 'forum.reply':
          if (simulateUncertainPublish) {
            throw PlatformException(
              code: 'NeedsReconciliation',
              message: 'Reply uncertain',
            );
          }
          return jsonEncode({'floor_id': 504, 'result': 'success'});

        case 'forum.reconcile':
        case 'community.tea.reconcile':
          if (reconcileOutcome == 'unresolved') {
            throw PlatformException(
              code: 'NeedsReconciliation',
              message: 'own-user history does not confirm write',
            );
          }
          if (reconcileOutcome == 'empty') {
            return jsonEncode({});
          }
          final act = methodParams['action']?.toString() ?? '';
          if (act == 'publish') {
            return jsonEncode({
              'status': 'committed',
              'reconciled': true,
              'division_id': methodParams['division_id'] ?? 1,
              'hole_id': 105,
            });
          } else {
            return jsonEncode({
              'status': 'committed',
              'reconciled': true,
              'hole_id': methodParams['hole_id'] ?? 101,
              'floor_id': 506,
            });
          }

        case 'campus.login':
          await loginPending?.future;
          if (loginError != null) throw PlatformException(code: loginError!);
          consentRequired = false;
          simulateAuthRequired = false;
          return jsonEncode({'status': 'ok'});

        default:
          return jsonEncode({'status': 'unknown_method'});
      }
    }

    // Default fallback for core commands
    switch (command) {
      case HostCommand.info:
        return jsonEncode({'version': '0.1.0'});
      case HostCommand.plugins:
        return jsonEncode([]);
      case HostCommand.account:
        return jsonEncode({'account_id': 'user_001'});
      case HostCommand.jobs:
        return jsonEncode([]);
      case HostCommand.permissions:
        return jsonEncode({
          'exact_available': false,
          'notifications_available': false,
        });
      default:
        return jsonEncode({});
    }
  }
}

Widget _wrapTestWidget(Widget child) {
  return MaterialApp(theme: AppTheme.lightTheme, home: child);
}

Map<String, dynamic> _paginationPage(String method, int offset, int count) {
  final items = List.generate(count, (index) {
    final id = offset + index + 1;
    final timestamp = DateTime.utc(
      2026,
      11,
      1,
      12,
    ).subtract(Duration(minutes: id)).toIso8601String();
    final floor = <String, dynamic>{
      'floor_id': 2000 + id,
      'hole_id': 1000 + id,
      'content': 'Synthetic pagination item $id',
      'time_created': timestamp,
      'deleted': false,
    };
    if (method == 'forum.search') return floor;
    return <String, dynamic>{
      'payload': method == 'community.tea.holes'
          ? {
              'hole_id': 1000 + id,
              'division_id': 1,
              'time_created': timestamp,
              'time_updated': timestamp,
              'floors': {'first_floor': floor},
            }
          : floor,
    };
  });
  return {method == 'forum.search' ? 'items' : 'records': items};
}

List<Map<String, dynamic>> _methodParams(
  MockForumDanshengBridge bridge,
  String method,
) => bridge.invocationLog
    .where((entry) => entry['params']['method'] == method)
    .map((entry) => entry['params']['params'] as Map<String, dynamic>)
    .toList();

void main() {
  late MockForumDanshengBridge mockBridge;
  late DanshengClient client;
  late DanshengController controller;

  testWidgets('Account page keeps UIS and Canvas but no forum login', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrapTestWidget(AccountBalanceScreen(controller: controller)),
    );
    await tester.pumpAndSettle();
    expect(find.text('统一认证'), findsOneWidget);
    expect(find.text('Canvas'), findsOneWidget);
    expect(find.text('树洞账号'), findsNothing);
    expect(find.byTooltip('登录树洞账号'), findsNothing);
  });

  testWidgets(
    'Consent gate stops reads and login is single flight and replaceable',
    (tester) async {
      mockBridge.consentRequired = true;
      await tester.pumpWidget(
        _wrapTestWidget(ForumPage(controller: controller)),
      );
      await tester.pumpAndSettle();
      expect(find.text('登录论坛'), findsOneWidget);
      expect(find.textContaining('明确确认承担风险'), findsOneWidget);
      expect(
        _methodParams(mockBridge, 'community.tea.divisions'),
        hasLength(1),
      );
      expect(_methodParams(mockBridge, 'community.tea.holes'), isEmpty);

      mockBridge.loginPending = Completer<void>();
      await tester.tap(find.text('登录论坛'));
      await tester.pump();
      await tester.tap(find.byTooltip('登录树洞账号'));
      await tester.pump();
      expect(find.text('正在登录…'), findsOneWidget);
      // Saved credentials go first; the host asks only when they are rejected.
      expect(_methodParams(mockBridge, 'campus.login'), [
        {'service': 'forum'},
      ]);
      mockBridge.loginPending!.complete();
      await tester.pumpAndSettle();
      expect(find.text('已连接树洞账号'), findsOneWidget);
      expect(_methodParams(mockBridge, 'community.tea.holes'), hasLength(1));
      expect(find.text('需要登录论坛服务'), findsNothing);
      // Once signed in, the account button enters another account.
      await tester.tap(find.byTooltip('登录树洞账号'));
      await tester.pumpAndSettle();
      expect(_methodParams(mockBridge, 'campus.login'), hasLength(2));
      expect(_methodParams(mockBridge, 'campus.login').last['replace'], isTrue);
    },
  );

  testWidgets(
    'Cancelled native risk or credentials dialog stays quiet and allows retry',
    (tester) async {
      mockBridge.consentRequired = true;
      mockBridge.loginError = 'Cancelled';
      await tester.pumpWidget(
        _wrapTestWidget(ForumPage(controller: controller)),
      );
      await tester.pumpAndSettle();
      for (var attempt = 0; attempt < 2; attempt++) {
        await tester.tap(find.text('登录论坛'));
        await tester.pumpAndSettle();
        expect(find.textContaining('登录失败'), findsNothing);
        expect(find.byType(SnackBar), findsNothing);
        expect(find.text('登录论坛'), findsOneWidget);
        expect(_methodParams(mockBridge, 'community.tea.holes'), isEmpty);
      }
      expect(_methodParams(mockBridge, 'campus.login'), hasLength(2));
    },
  );

  setUp(() async {
    mockBridge = MockForumDanshengBridge();
    client = DanshengClient(bridge: mockBridge);
    controller = DanshengController(client: client);
    await controller.initialize();
  });

  test('ForumService: defaults to ten and clamps only holes', () async {
    final service = ForumService(CampusApi(client));
    await service.fetchHoles();
    await service.fetchHoles(pageSize: 20);
    await service.fetchHoles(pageSize: 2);
    await service.fetchFloors(holeId: 101);
    await service.fetchFloors(holeId: 101, size: 20);
    await service.search(query: 'pagination');
    await service.search(query: 'pagination', size: 20);

    final holes = _methodParams(mockBridge, 'community.tea.holes');
    expect(holes.map((params) => params['page_size']), [10, 10, 2]);
    expect(holes.map((params) => params['size']), [10, 10, 2]);
    final floors = _methodParams(mockBridge, 'community.tea.floors');
    expect(floors.map((params) => params['size']), [10, 20]);
    expect(floors.map((params) => params['page_size']), [10, 20]);
    expect(
      _methodParams(mockBridge, 'forum.search').map((params) => params['size']),
      [10, 20],
    );
  });

  for (final method in [
    'community.tea.holes',
    'community.tea.floors',
    'forum.search',
  ]) {
    testWidgets('$method: ten items allow next page, short page stops', (
      tester,
    ) async {
      mockBridge.responsePages[method] = [
        _paginationPage(method, 0, 10),
        _paginationPage(method, 10, 2),
      ];
      final Widget page = switch (method) {
        'community.tea.holes' => ForumPage(
          controller: controller,
          autoLoadOnScroll: false,
        ),
        'community.tea.floors' => HoleDetailPage(
          controller: controller,
          holeId: 101,
          autoLoadOnScroll: false,
        ),
        _ => ForumSearchPage(controller: controller),
      };
      await tester.pumpWidget(_wrapTestWidget(page));
      await tester.pumpAndSettle();
      if (method == 'forum.search') {
        await tester.enterText(find.byType(TextField), 'pagination');
        await tester.tap(find.byTooltip('搜索'));
        await tester.pumpAndSettle();
      }

      expect(_methodParams(mockBridge, method), hasLength(1));
      final more = find.text(
        method == 'community.tea.floors' ? '加载更多楼层' : '加载更多',
      );
      final list = find.byWidgetPredicate(
        (widget) =>
            widget is Scrollable && widget.axisDirection == AxisDirection.down,
      );
      await tester.scrollUntilVisible(more, 300, scrollable: list);
      await tester.pumpAndSettle();
      await tester.ensureVisible(more);
      await tester.pumpAndSettle();
      await tester.tap(more);
      await tester.pumpAndSettle();

      final calls = _methodParams(mockBridge, method);
      expect(calls, hasLength(2));
      expect(calls.map((params) => params['size']), [10, 10]);
      if (method == 'community.tea.holes') {
        expect(calls.first['before'], isNull);
        expect(calls.last['before'], '2026-11-01T11:50:00.000Z');
      } else {
        expect(calls.map((params) => params['offset']), [0, 10]);
      }
      await tester.scrollUntilVisible(
        find.textContaining('Synthetic pagination item 12'),
        300,
        scrollable: list,
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Synthetic pagination item 12'),
        findsOneWidget,
      );
      expect(more, findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'ForumPage: loads divisions, pinned posts, holes and handles division filter',
    (tester) async {
      await tester.pumpWidget(
        _wrapTestWidget(ForumPage(controller: controller)),
      );
      await tester.pumpAndSettle();

      // 1. Verify title and division tabs exist
      expect(find.text('复旦树洞'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, '全站'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, '合成分区'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, '校园生活'), findsOneWidget);

      // 2. Official pinned posts are NOT shown in 全站 (DanXi behavior)
      expect(find.text('置顶'), findsNothing);
      expect(find.text('#999'), findsNothing);

      // 3. Verify normal holes are shown with tags and sanitized preview
      expect(find.text('#101'), findsOneWidget);
      expect(find.text('#102'), findsOneWidget);
      expect(find.text('#日常'), findsOneWidget);
      expect(find.text('#美食'), findsOneWidget);
      expect(find.textContaining('[公式]'), findsOneWidget);
      expect(find.textContaining('[图片]'), findsOneWidget);

      // 4. Verify anonymity: NO token or secret leaked
      expect(find.textContaining('LEAK_TOKEN'), findsNothing);
      expect(find.textContaining('PII'), findsNothing);

      // 5. Switch division to "合成分区"
      await tester.tap(find.widgetWithText(ChoiceChip, '合成分区'));
      await tester.pumpAndSettle();

      // Pinned post is shown with "置顶" badge inside specific division
      expect(find.text('置顶'), findsOneWidget);
      expect(find.textContaining('置顶公告'), findsOneWidget);
      expect(find.text('#999'), findsOneWidget);

      // Verify holes fetch called with division: 1
      final lastHolesCall = mockBridge.invocationLog.lastWhere(
        (entry) =>
            entry['command'] == HostCommand.campus &&
            entry['params']['method'] == 'community.tea.holes',
      );
      expect(lastHolesCall['params']['params']['division'], 1);

      // Switch back to "全站"
      await tester.tap(find.widgetWithText(ChoiceChip, '全站'));
      await tester.pumpAndSettle();

      final allHolesCall = mockBridge.invocationLog.lastWhere(
        (entry) =>
            entry['command'] == HostCommand.campus &&
            entry['params']['method'] == 'community.tea.holes',
      );
      expect(allHolesCall['params']['params']['division'], isNull);
    },
  );

  testWidgets(
    'ForumPage: switches sort order between latest replied and latest created',
    (tester) async {
      await tester.pumpWidget(
        _wrapTestWidget(ForumPage(controller: controller)),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('最新回复'), findsWidgets);

      // Tap sort button in AppBar
      await tester.tap(find.byTooltip('最新回复'));
      await tester.pumpAndSettle();

      expect(find.textContaining('最新发布'), findsWidgets);

      final sortCall = mockBridge.invocationLog.lastWhere(
        (entry) =>
            entry['command'] == HostCommand.campus &&
            entry['params']['method'] == 'community.tea.holes',
      );
      expect(sortCall['params']['params']['order'], 'created');
    },
  );

  testWidgets(
    'HoleDetailPage: displays hole, OP badge, floors and hides deleted markup',
    (tester) async {
      await tester.pumpWidget(
        _wrapTestWidget(HoleDetailPage(controller: controller, holeId: 101)),
      );
      await tester.pumpAndSettle();

      // 1. Hole header
      expect(find.text('#101 帖子详情'), findsOneWidget);

      // 2. Floor 1 is OP (洞主), with pseudonym 'Synthetic'
      expect(find.text('洞主'), findsOneWidget);
      expect(find.text('Synthetic'), findsOneWidget);
      expect(find.textContaining('复习微积分'), findsOneWidget);

      // 3. Floor 2 is Alice
      expect(find.text('2楼'), findsOneWidget);
      expect(find.text('Alice'), findsOneWidget);
      expect(find.textContaining('我也在看这门课'), findsOneWidget);

      // 4. Floor 3 is deleted: markup must be suppressed, shows placeholder
      expect(find.text('3楼'), findsOneWidget);
      expect(find.text('该楼层已被删除'), findsOneWidget);
      expect(find.textContaining('null'), findsNothing);

      // 5. Verify floors call passes page_size and offset
      final floorsCall = mockBridge.invocationLog.lastWhere(
        (entry) =>
            entry['command'] == HostCommand.campus &&
            entry['params']['method'] == 'community.tea.floors',
      );
      expect(floorsCall['params']['params']['hole_id'], 101);
      expect(floorsCall['params']['params']['page_size'], 10);

      // 6. Anonymity check: verify no token leaked
      expect(find.textContaining('LEAK_TOKEN'), findsNothing);
    },
  );

  testWidgets(
    'Search: ForumSearchPage queries parent forum.search and renders results with deleted check',
    (tester) async {
      await tester.pumpWidget(
        _wrapTestWidget(ForumSearchPage(controller: controller)),
      );
      await tester.pumpAndSettle();

      // Type query
      await tester.enterText(find.byType(TextField), '微积分');
      await tester.tap(find.byTooltip('搜索'));
      await tester.pumpAndSettle();

      // Verify search was invoked
      final searchCall = mockBridge.invocationLog.lastWhere(
        (entry) =>
            entry['command'] == HostCommand.campus &&
            entry['params']['method'] == 'forum.search',
      );
      expect(searchCall['params']['params']['query'], '微积分');
      expect(searchCall['params']['params']['offset'], 0);

      // Verify result card displayed
      expect(find.textContaining('关于 微积分 的相关树洞讨论'), findsOneWidget);
      // Verify deleted floor in search result renders cleanly as deleted placeholder
      expect(find.text('该楼层已被删除'), findsOneWidget);
    },
  );

  testWidgets(
    'Publish: writes UI fields preview, requires confirm before forum.publish',
    (tester) async {
      await tester.pumpWidget(
        _wrapTestWidget(ForumPage(controller: controller)),
      );
      await tester.pumpAndSettle();

      // Tap "发帖" FAB
      await tester.tap(find.text('发帖'));
      await tester.pumpAndSettle();

      expect(find.text('发布新帖'), findsOneWidget);

      // Enter tags and content
      final textFields = find.byType(TextField);
      await tester.enterText(textFields.at(0), '考试, 复习');
      await tester.enterText(textFields.at(1), '大家期末一起加油！');
      await tester.pumpAndSettle();

      // Tap "预览并确认" to enter preview step
      await tester.tap(find.text('预览并确认'));
      await tester.pumpAndSettle();

      // 1. Verify preview mode is active
      expect(find.text('发帖确认与预览'), findsOneWidget);
      expect(find.text('发布分区'), findsOneWidget);
      expect(find.text('合成分区'), findsWidgets);
      expect(find.text('#考试'), findsOneWidget);
      expect(find.text('#复习'), findsOneWidget);
      expect(find.textContaining('匿名保护'), findsOneWidget);
      expect(find.text('大家期末一起加油！'), findsOneWidget);

      // Ensure publish NOT yet called before confirm
      expect(
        mockBridge.invocationLog.any(
          (entry) =>
              entry['command'] == HostCommand.campus &&
              entry['params']['method'] == 'forum.publish',
        ),
        isFalse,
      );

      // Now tap "确认发布"
      await tester.tap(find.text('确认发布'));
      await tester.pumpAndSettle();

      // Verify forum.publish invoked with typed parameters
      final pubCall = mockBridge.invocationLog.lastWhere(
        (entry) =>
            entry['command'] == HostCommand.campus &&
            entry['params']['method'] == 'forum.publish',
      );
      expect(pubCall['params']['params']['division_id'], 1);
      expect(pubCall['params']['params']['content'], '大家期末一起加油！');
      expect(pubCall['params']['params']['tags'], ['考试', '复习']);
    },
  );

  testWidgets(
    'Publish: uncertain outcome shows "核对结果", ambiguous remains pending, match authorizes published',
    (tester) async {
      mockBridge.simulateUncertainPublish = true;
      mockBridge.reconcileOutcome =
          'unresolved'; // initial reconciliation is ambiguous

      await tester.pumpWidget(
        _wrapTestWidget(ForumPage(controller: controller)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('发帖'));
      await tester.pumpAndSettle();

      final textFields = find.byType(TextField);
      await tester.enterText(textFields.at(1), '可能超时的帖子');
      await tester.tap(find.text('预览并确认'));
      await tester.pumpAndSettle();

      // Confirm publish -> throws NeedsReconciliation
      await tester.tap(find.text('确认发布'));
      await tester.pumpAndSettle();

      // Verify uncertain outcome warning and "核对结果" button
      expect(find.textContaining('提交结果待核对，请勿重复提交'), findsOneWidget);
      expect(find.text('核对结果'), findsOneWidget);
      expect(find.text('先刷新'), findsOneWidget);
      expect(
        find.text('确认发布'),
        findsNothing,
      ); // Immediate blind retry disabled!

      // 1. User taps "核对结果" when reconciliation is ambiguous/unresolved
      await tester.tap(find.text('核对结果'));
      await tester.pumpAndSettle();

      // Verify reconcile was invoked with read-only contract
      final reconcileCall = mockBridge.invocationLog.lastWhere(
        (entry) =>
            entry['command'] == HostCommand.campus &&
            entry['params']['method'] == 'forum.reconcile',
      );
      expect(reconcileCall['params']['params']['action'], 'publish');
      expect(reconcileCall['params']['params']['division_id'], 1);
      expect(reconcileCall['params']['params']['content'], '可能超时的帖子');

      // Dialog must NOT be closed, still pending, never automatically re-published!
      expect(find.text('发帖确认与预览'), findsOneWidget);
      expect(find.textContaining('状态仍为待核对'), findsOneWidget);

      // Ensure no automatic second forum.publish call occurred!
      final publishCalls = mockBridge.invocationLog
          .where(
            (entry) =>
                entry['command'] == HostCommand.campus &&
                entry['params']['method'] == 'forum.publish',
          )
          .toList();
      expect(publishCalls.length, 1);

      // 2. Now simulate reconciliation succeeding with a definitive match
      mockBridge.reconcileOutcome = 'success';
      await tester.tap(find.text('核对结果'));
      await tester.pumpAndSettle();

      // Authorizes showing published and closes dialog
      expect(find.text('发帖确认与预览'), findsNothing);
    },
  );

  testWidgets(
    'Reply: uncertain outcome reconciled with definitive match authorizes published',
    (tester) async {
      mockBridge.simulateUncertainPublish = true;
      mockBridge.reconcileOutcome = 'success';

      await tester.pumpWidget(
        _wrapTestWidget(HoleDetailPage(controller: controller, holeId: 101)),
      );
      await tester.pumpAndSettle();

      // Tap "回复" FAB
      await tester.tap(find.text('回复'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '赞同洞主的观点！');
      await tester.tap(find.text('预览并确认'));
      await tester.pumpAndSettle();

      // Confirm reply -> throws NeedsReconciliation
      await tester.tap(find.text('确认回复'));
      await tester.pumpAndSettle();

      expect(find.text('核对结果'), findsOneWidget);

      // Tap "核对结果"
      await tester.tap(find.text('核对结果'));
      await tester.pumpAndSettle();

      final reconcileCall = mockBridge.invocationLog.lastWhere(
        (entry) =>
            entry['command'] == HostCommand.campus &&
            entry['params']['method'] == 'forum.reconcile',
      );
      expect(reconcileCall['params']['params']['action'], 'reply');
      expect(reconcileCall['params']['params']['hole_id'], 101);
      expect(reconcileCall['params']['params']['content'], '赞同洞主的观点！');

      // Authorizes success and closes dialog
      expect(find.text('回复确认与预览'), findsNothing);
    },
  );

  testWidgets(
    'Authentication: prompts campus.login when AuthenticationRequired occurs',
    (tester) async {
      mockBridge.simulateAuthRequired = true;

      await tester.pumpWidget(
        _wrapTestWidget(ForumPage(controller: controller)),
      );
      await tester.pumpAndSettle();

      expect(find.text('需要登录论坛服务'), findsOneWidget);
      expect(find.text('登录论坛'), findsOneWidget);

      // Tap "登录论坛"
      await tester.tap(find.text('登录论坛'));
      await tester.pumpAndSettle();

      final loginCall = mockBridge.invocationLog.lastWhere(
        (entry) =>
            entry['command'] == HostCommand.campus &&
            entry['params']['method'] == 'campus.login',
      );
      expect(loginCall['params']['params']['service'], 'forum');
    },
  );
}

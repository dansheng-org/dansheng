// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dansheng_app/ui/campus/ehall/power_detail.dart';
import 'package:dansheng_app/ui/core/dansheng_client.dart';
import 'package:dansheng_app/ui/core/dansheng_state.dart';

import '../ui/test_helpers.dart';

void main() {
  group('PowerDetailPage Electricity & Usage History Tests', () {
    late MockDanshengBridge bridge;
    late DanshengClient client;
    late DanshengController controller;

    setUp(() async {
      bridge = MockDanshengBridge();
      bridge.accountId = 'student_test_1001';
      client = DanshengClient(bridge: bridge);
      controller = DanshengController(client: client);
      await controller.initialize();
    });

    testWidgets(
      'Does not claim zero usage or no records when user is not logged in',
      (tester) async {
        // Unauthenticated state
        final unauthBridge = MockDanshengBridge();
        unauthBridge.accountId = null;
        final unauthClient = DanshengClient(bridge: unauthBridge);
        final unauthController = DanshengController(client: unauthClient);
        await unauthController.initialize();

        final campusCalls = <String>[];
        unauthBridge.campusHandler = (method, params) async {
          campusCalls.add(method);
          return null;
        };

        await tester.pumpWidget(
          buildTestApp(
            home: PowerDetailPage(controller: unauthController),
            controller: unauthController,
          ),
        );
        await tester.pumpAndSettle();

        // No network queries dispatched without an account
        expect(campusCalls, isEmpty);

        // Shows explicit unauthenticated banner
        expect(
          find.byKey(const Key('power_no_account_banner')),
          findsOneWidget,
        );
        expect(find.text('未设置账号'), findsOneWidget);
        expect(
          find.byKey(const Key('power_set_account_button')),
          findsOneWidget,
        );

        // Must NOT falsely claim 0 kWh or "暂无用电记录"
        expect(find.text('0 kWh'), findsNothing);
        expect(find.text('0.0 kWh'), findsNothing);
        expect(find.text('暂无用电记录'), findsNothing);
      },
    );

    testWidgets(
      'Displays real balance, unit, dorm name, and last update date on top',
      (tester) async {
        final campusCalls = <Map<String, dynamic>>[];

        bridge.campusHandler = (method, params) async {
          campusCalls.add({'method': method, 'params': params});
          if (method == 'fudan.electricity') {
            return {
              'payload': {
                'campus': '邯郸校区',
                'building': '东安一号楼',
                'room': '302室',
                'remaining_kwh': 45.2,
                'used_kwh': 120.5,
                'unit': 'kWh',
                'update_time': '2026-11-08 12:00:00',
              },
            };
          }
          if (method == 'fudan.electricity.history') {
            return [
              {
                'date': '2026-11-07',
                'amount': '3.2',
                'dorm_name': '邯郸校区 东安一号楼 302室',
              },
            ];
          }
          return null;
        };

        await tester.pumpWidget(
          buildTestApp(
            home: PowerDetailPage(controller: controller),
            controller: controller,
          ),
        );
        await tester.pumpAndSettle();

        // Verify top card balance, unit, dorm, and timestamp
        expect(find.text('寝室电量'), findsWidgets);
        expect(find.text('45.2'), findsOneWidget);
        expect(find.text('kWh'), findsWidgets);
        expect(find.text('邯郸校区 东安一号楼 302室'), findsWidgets);
        expect(find.text('剩余：45.2 kWh；已用：120.5 kWh'), findsOneWidget);
        expect(find.text('最近更新：2026-11-08 12:00:00'), findsOneWidget);

        // History item
        expect(find.text('2026-11-07'), findsOneWidget);
        expect(find.text('3.2 kWh'), findsOneWidget);
      },
    );

    testWidgets(
      'Loads electricity history with pagination using offset and size',
      (tester) async {
        final historyCalls = <Map<String, dynamic>>[];

        bridge.campusHandler = (method, params) async {
          if (method == 'fudan.electricity') {
            return {
              'payload': {
                'balance': '38.0',
                'unit': '度',
                'update_time': '2026-11-08',
              },
            };
          }
          if (method == 'fudan.electricity.history') {
            historyCalls.add(Map<String, dynamic>.from(params));
            final offset = params['offset'] as int? ?? 0;
            if (offset == 0) {
              // Return full page of 20 items
              return List.generate(
                20,
                (i) => {
                  'date': '2026-11-${(20 - i).toString().padLeft(2, '0')}',
                  'amount': (2.0 + i * 0.1).toStringAsFixed(1),
                  'dorm_name': '南区15号楼101',
                },
              );
            } else {
              // Second page: 3 items (signals end of list)
              return [
                {
                  'date': '2026-10-31',
                  'amount': '5.0',
                  'dorm_name': '南区15号楼101',
                },
                {
                  'date': '2026-10-30',
                  'amount': '4.8',
                  'dorm_name': '南区15号楼101',
                },
                {
                  'date': '2026-10-29',
                  'amount': '4.5',
                  'dorm_name': '南区15号楼101',
                },
              ];
            }
          }
          return null;
        };

        await tester.pumpWidget(
          buildTestApp(
            home: PowerDetailPage(controller: controller),
            controller: controller,
          ),
        );
        await tester.pumpAndSettle();

        // First call verified with offset 0 and size 20
        expect(historyCalls.length, 1);
        expect(historyCalls.first['offset'], 0);
        expect(historyCalls.first['size'], 20);

        // Verify first page items rendered
        expect(find.text('2026-11-20'), findsOneWidget);
        expect(find.text('2.0 kWh'), findsOneWidget);

        // Load more button should be present
        final loadMoreFinder = find.byKey(const Key('power_history_load_more'));
        expect(loadMoreFinder, findsOneWidget);

        // Scroll to load more button and tap
        await tester.drag(find.byType(ListView), const Offset(0, -2000));
        await tester.pumpAndSettle();
        await tester.tap(loadMoreFinder);
        await tester.pumpAndSettle();

        // Second call verified with offset 20 and size 20
        expect(historyCalls.length, 2);
        expect(historyCalls[1]['offset'], 20);
        expect(historyCalls[1]['size'], 20);

        // Second page items now in tree
        expect(find.text('2026-10-31'), findsOneWidget);
        expect(find.text('5.0 kWh'), findsOneWidget);

        // Reached end of records
        expect(find.text('已加载全部用电记录'), findsOneWidget);
        expect(find.byKey(const Key('power_history_load_more')), findsNothing);
      },
    );

    testWidgets(
      'Parses {records:[{payload:...}]} and {items:[...]} structures correctly',
      (tester) async {
        int callCount = 0;
        bridge.campusHandler = (method, params) async {
          if (method == 'fudan.electricity') {
            return {'balance': '12.0', 'unit': 'kWh'};
          }
          if (method == 'fudan.electricity.history') {
            callCount++;
            if (callCount == 1) {
              // {records:[{payload:...}]} structure
              return {
                'records': [
                  {
                    'payload': {
                      'date': '2026-11-06',
                      'amount': '7.4',
                      'dorm_name': '江湾A栋301',
                    },
                  },
                ],
              };
            } else {
              // {items:[...]} structure
              return {
                'items': [
                  {
                    'date': '2026-11-05',
                    'amount': '6.8',
                    'dorm_name': '江湾A栋301',
                  },
                ],
              };
            }
          }
          return null;
        };

        await tester.pumpWidget(
          buildTestApp(
            home: PowerDetailPage(controller: controller),
            controller: controller,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('2026-11-06'), findsOneWidget);
        expect(find.text('7.4 kWh'), findsOneWidget);

        // Refresh to trigger second format
        final refreshBtn = find.byKey(const Key('power_refresh_button'));
        await tester.tap(refreshBtn);
        await tester.pumpAndSettle();

        expect(find.text('2026-11-05'), findsOneWidget);
        expect(find.text('6.8 kWh'), findsOneWidget);
      },
    );

    testWidgets(
      'Handles 2FA required on history using CampusApi("campus.verifyDining") and reloads',
      (tester) async {
        bool verified = false;
        final campusLog = <String>[];

        bridge.campusHandler = (method, params) async {
          campusLog.add(method);
          if (method == 'fudan.electricity') {
            return {'balance': '25.0', 'unit': 'kWh'};
          }
          if (method == 'fudan.electricity.history') {
            if (!verified) {
              // my.fudan 2FA authentication required
              throw PlatformException(
                code: 'AuthenticationRequired',
                message: 'my.fudan.edu.cn 2FA verification required',
              );
            }
            return [
              {'date': '2026-11-08', 'amount': '4.2', 'dorm_name': '枫林校区1号楼'},
            ];
          }
          if (method == 'campus.verifyDining') {
            verified = true;
            return {'verified': true};
          }
          return null;
        };

        await tester.pumpWidget(
          buildTestApp(
            home: PowerDetailPage(controller: controller),
            controller: controller,
          ),
        );
        await tester.pumpAndSettle();

        // 2FA required banner shown; must not say "暂无用电记录"
        expect(
          find.byKey(const Key('power_2fa_required_banner')),
          findsOneWidget,
        );
        expect(find.text('用电历史查询需要 2FA 身份验证'), findsOneWidget);
        expect(find.text('暂无用电记录'), findsNothing);

        // Tap the 2FA action button
        final verifyBtn = find.byKey(
          const Key('power_verify_2fa_action_button'),
        );
        expect(verifyBtn, findsOneWidget);
        await tester.ensureVisible(verifyBtn);
        await tester.pumpAndSettle();
        await tester.tap(verifyBtn);
        await tester.pumpAndSettle();

        // Verify campus.verifyDining was called
        expect(campusLog.contains('campus.verifyDining'), isTrue);

        // History successfully reloaded and records rendered
        expect(find.text('2026-11-08'), findsOneWidget);
        expect(find.text('4.2 kWh'), findsOneWidget);
        expect(
          find.byKey(const Key('power_2fa_required_banner')),
          findsNothing,
        );
      },
    );

    testWidgets(
      'Handles ZLApp power balance auth error via campus.login power and reloads',
      (tester) async {
        bool powerLoggedIn = false;
        final campusLog = <Map<String, dynamic>>[];

        bridge.campusHandler = (method, params) async {
          campusLog.add({'method': method, 'params': params});
          if (method == 'fudan.electricity') {
            if (!powerLoggedIn) {
              throw PlatformException(
                code: 'NotLoginError',
                message: 'zlapp electricity service requires login',
              );
            }
            return {
              'balance': '62.5',
              'used': '110.0',
              'unit': 'kWh',
              'update_time': '2026-11-08 20:00:00',
              'dorm_name': '张江校区2号楼202',
            };
          }
          if (method == 'fudan.electricity.history') {
            return [];
          }
          if (method == 'campus.login') {
            if (params['service'] == 'power') {
              powerLoggedIn = true;
              return {'status': 'logged_in'};
            }
          }
          return null;
        };

        await tester.pumpWidget(
          buildTestApp(
            home: PowerDetailPage(controller: controller),
            controller: controller,
          ),
        );
        await tester.pumpAndSettle();

        // Power login banner shown; must not claim 0 kWh
        expect(
          find.byKey(const Key('power_balance_auth_notice')),
          findsOneWidget,
        );
        expect(find.text('实时电量服务需要登录统一身份认证'), findsOneWidget);
        expect(find.text('0 kWh'), findsNothing);

        // Tap the power login button
        final loginBtn = find.byKey(const Key('power_login_button'));
        expect(loginBtn, findsOneWidget);
        await tester.tap(loginBtn);
        await tester.pumpAndSettle();

        // Verify campus.login called with service: 'power'
        final loginCall = campusLog.firstWhere(
          (c) => c['method'] == 'campus.login',
        );
        expect(loginCall['params']['service'], 'power');

        // Real balance rendered after login
        expect(find.text('62.5'), findsOneWidget);
        expect(find.text('张江校区2号楼202'), findsOneWidget);
        expect(
          find.byKey(const Key('power_balance_auth_notice')),
          findsNothing,
        );
      },
    );

    testWidgets(
      'Account switching resets stale state and triggers fresh query',
      (tester) async {
        String currentAccount = 'user_A';
        bridge.accountId = currentAccount;

        bridge.campusHandler = (method, params) async {
          if (method == 'fudan.electricity') {
            return {
              'balance': currentAccount == 'user_A' ? '10.0' : '90.0',
              'unit': 'kWh',
            };
          }
          if (method == 'fudan.electricity.history') {
            return [
              {
                'date': currentAccount == 'user_A'
                    ? '2026-11-01'
                    : '2026-11-08',
                'amount': currentAccount == 'user_A' ? '1.0' : '9.0',
                'dorm_name': currentAccount == 'user_A' ? 'Dorm A' : 'Dorm B',
              },
            ];
          }
          return null;
        };

        await tester.pumpWidget(
          buildTestApp(
            home: PowerDetailPage(controller: controller),
            controller: controller,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('10.0'), findsOneWidget);
        expect(find.text('Dorm A'), findsOneWidget);

        // Switch active account
        currentAccount = 'user_B';
        await controller.switchAccount('user_B');
        await tester.pumpAndSettle();

        expect(find.text('90.0'), findsOneWidget);
        expect(find.text('Dorm B'), findsOneWidget);
        expect(find.text('10.0'), findsNothing);
      },
    );

    testWidgets(
      'Parses DanXi zlapp balance format and raw DataCenter history array',
      (tester) async {
        bridge.campusHandler = (method, params) async {
          if (method == 'fudan.electricity') {
            // DanXi zlapp info format
            return {
              'd': {
                'xq': '邯郸校区',
                'ssmc': '南区15号楼',
                'fjmc': '101室',
                'fj_surplus': 33.3,
                'fj_used': 99.9,
                'fj_update_time': '2026-11-08 00:00:00',
              },
            };
          }
          if (method == 'fudan.electricity.history') {
            // DanXi DataCenter repository table format
            return {
              'data': [
                ['1', '邯郸', '15号楼', '101', '2026-11-03', '3.7'],
              ],
            };
          }
          return null;
        };

        await tester.pumpWidget(
          buildTestApp(
            home: PowerDetailPage(controller: controller),
            controller: controller,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('33.3'), findsOneWidget);
        expect(find.text('邯郸校区 南区15号楼 101室'), findsOneWidget);
        expect(find.text('剩余：33.3 kWh；已用：99.9 kWh'), findsOneWidget);
        expect(find.text('最近更新：2026-11-08 00:00:00'), findsOneWidget);

        expect(find.text('2026-11-03'), findsOneWidget);
        expect(find.text('3.7 kWh'), findsOneWidget);
        expect(find.text('邯郸/15号楼/101'), findsOneWidget);
      },
    );

    testWidgets(
      'Shows empty history card when authenticated but user has no records',
      (tester) async {
        bridge.campusHandler = (method, params) async {
          if (method == 'fudan.electricity') {
            return {'balance': '50.0', 'unit': 'kWh'};
          }
          if (method == 'fudan.electricity.history') {
            return [];
          }
          return null;
        };

        await tester.pumpWidget(
          buildTestApp(
            home: PowerDetailPage(controller: controller),
            controller: controller,
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('power_history_empty_card')),
          findsOneWidget,
        );
        expect(find.text('暂无用电记录'), findsOneWidget);
      },
    );

    testWidgets(
      'Falls back to cached power balance when live network request fails',
      (tester) async {
        bridge.campusHandler = (method, params) async {
          if (method == 'fudan.electricity') {
            throw PlatformException(
              code: 'Network',
              message: 'Failed to connect to zlapp',
            );
          }
          if (method == 'campus.cached') {
            if (params['method'] == 'fudan.electricity') {
              return {
                'payload': {
                  'balance': '42.0',
                  'unit': 'kWh',
                  'dorm_name': '本部10号楼',
                },
              };
            }
          }
          if (method == 'fudan.electricity.history') {
            return [];
          }
          return null;
        };

        await tester.pumpWidget(
          buildTestApp(
            home: PowerDetailPage(controller: controller),
            controller: controller,
          ),
        );
        await tester.pumpAndSettle();

        // Cached snapshot should be rendered
        expect(find.text('42.0'), findsOneWidget);
        expect(find.text('本部10号楼'), findsOneWidget);
        expect(find.textContaining('上次缓存数据'), findsOneWidget);
      },
    );
  });
}

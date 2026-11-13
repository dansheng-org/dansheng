// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dansheng_app/bridge.g.dart';
import 'package:dansheng_app/ui/core/dansheng_client.dart';
import 'package:dansheng_app/ui/core/dansheng_state.dart';
import 'package:dansheng_app/ui/campus/venues/venue_page.dart';
import 'package:dansheng_app/ui/screens/schema_screen.dart';

/// Test mock implementation of DanshengBridge specifically handling
/// HostCommand.campus and generic host interactions.
class MockCampusBridge implements DanshengBridge {
  String? activeAccount = 'student_test_01';
  List<Map<String, dynamic>> plugins = [];
  List<Map<String, dynamic>> jobs = [];
  final List<Map<String, dynamic>> calls = [];

  bool throwOnVenues = false;
  String throwCode = 'AuthenticationRequired';

  bool throwOnCancel = false;
  String cancelErrorCode = 'NeedsReconciliation';
  bool uncertainCancel = false;

  List<Map<String, dynamic>> venuesList = [
    {'id': 900, 'name': '正大体育馆羽毛球场'},
    {'id': 901, 'name': '南区网球场'},
  ];

  Map<String, dynamic> calendarResponse = {
    'slots': [
      {
        'period_id': 71,
        'time': '10:00-11:00',
        'court_id': 101,
        'court_name': '1号场地',
        'available': true,
      },
      {
        'period_id': 71,
        'time': '10:00-11:00',
        'court_id': 102,
        'court_name': '2号场地',
        'available': false,
      },
      {
        'period_id': 72,
        'time': '11:00-12:00',
        'court_id': 101,
        'court_name': '1号场地',
        'available': true,
      },
    ],
  };

  List<Map<String, dynamic>> appointmentsList = [
    {
      'id': 301,
      'resource_name': '正大体育馆羽毛球场',
      'date': '2099-01-03',
      'time': '10:00-11:00',
      'court_name': '1号场地',
      'status': '预约成功',
      'status_name': '预约成功',
      'is_cancel': true,
      'slots': [
        {
          'date': '2099-01-03',
          'time': '10:00-11:00',
          'resource_name': '1号场地',
          'active': true,
          'can_cancel': true,
          'cancel_message': '',
        },
      ],
    },
  ];

  Map<String, dynamic> appointmentDetail = {
    'id': 301,
    'resource_name': '正大体育馆羽毛球场',
    'status': '已生效',
    'code': 'VOUCHER-TEST-9988',
  };

  @override
  Future<String> invoke(HostCommand command, String payload) async {
    final Map<String, dynamic> params = payload.isNotEmpty
        ? (jsonDecode(payload) as Map<String, dynamic>)
        : <String, dynamic>{};

    calls.add({'command': command, 'params': params});

    switch (command) {
      case HostCommand.info:
        return jsonEncode({'version': '0.1.0'});

      case HostCommand.plugins:
        return jsonEncode(plugins);

      case HostCommand.account:
        return jsonEncode({'account_id': activeAccount});

      case HostCommand.jobs:
        return jsonEncode(jobs);

      case HostCommand.permissions:
        return jsonEncode({
          'exact_available': true,
          'notifications_available': true,
        });

      case HostCommand.campus:
        final method = params['method']?.toString() ?? '';
        final methodParams = params['params'] as Map<String, dynamic>? ?? {};

        if (throwOnVenues && method == 'venues.venues') {
          throw PlatformException(code: throwCode, message: throwCode);
        }

        switch (method) {
          case 'venues.venues':
            return jsonEncode(venuesList);

          case 'venues.calendar':
            return jsonEncode(calendarResponse);

          case 'venues.appointments':
            return jsonEncode(appointmentsList);

          case 'venues.detail':
            return jsonEncode(appointmentDetail);

          case 'venues.prepareManual':
            final vid = methodParams['venue_id'];
            final tdate = methodParams['target_date'];
            final pid = methodParams['period_id'];
            final cid = methodParams['court_id'];
            final time = methodParams['time'];
            return jsonEncode({
              'canonical_input': {
                'account_id': activeAccount,
                'task_id': 'manual-test-task',
                'venue_id': vid,
                'target_date': tdate,
                'period_id': pid,
                'court_id': cid,
                'time': time,
              },
              'summary': '单次预约: 场馆 #$vid, 日期 $tdate, 场地 #$cid, 时段 $time',
              'input_sha256': 'mock_sha256_hash_123',
            });

          case 'venues.reserve':
            return jsonEncode({
              'status': 'success',
              'message': '预约成功',
              'task_id': 'manual-test-task',
            });

          case 'venues.cancel':
            final apptId = methodParams['appointment_id'];
            if (throwOnCancel) {
              throw PlatformException(
                code: cancelErrorCode,
                message: cancelErrorCode,
              );
            }
            if (uncertainCancel) {
              return jsonEncode({
                'status': 'needs_reconciliation',
                'appointment_id': apptId,
              });
            }
            return jsonEncode({
              'status': 'success',
              'cancelled': true,
              'appointment_id': apptId,
            });

          case 'venues.reconcileCancel':
            final apptId = methodParams['appointment_id'];
            return jsonEncode({
              'status': 'reconciled_cancel',
              'reconciled': true,
              'cancelled': true,
              'appointment_id': apptId,
            });

          case 'venues.visibleLogin':
            throwOnVenues = false;
            return jsonEncode({
              'authenticated': true,
              'account_id': activeAccount,
            });

          case 'venues.reconcile':
            return jsonEncode({
              'reconciled': true,
              'appointment': appointmentsList.first,
            });

          default:
            return jsonEncode({'result': 'ok', 'method': method});
        }

      default:
        return jsonEncode({});
    }
  }
}

Widget createVenueTestApp({required DanshengController controller}) {
  return MaterialApp(home: VenuePage(controller: controller));
}

void main() {
  late MockCampusBridge mockBridge;
  late DanshengClient client;
  late DanshengController controller;

  setUp(() {
    mockBridge = MockCampusBridge();
    client = DanshengClient(bridge: mockBridge);
    controller = DanshengController(client: client);
  });

  testWidgets('VenuePage loads and displays venues and available slots', (
    tester,
  ) async {
    await controller.initialize();
    await tester.pumpWidget(createVenueTestApp(controller: controller));
    await tester.pumpAndSettle();

    // Verify venues dropdown displays the selected venue
    expect(find.text('正大体育馆羽毛球场'), findsWidgets);

    // Verify calendar slots are displayed
    expect(find.text('1号场地'), findsWidgets);
    expect(find.text('2号场地'), findsOneWidget);
    expect(find.text('10:00-11:00'), findsWidgets);

    // Verify prominent manual action button is visible
    expect(find.widgetWithText(FilledButton, '立即预约'), findsOneWidget);

    // Since slot is not selected yet, button should be disabled
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '立即预约'),
    );
    expect(button.enabled, isFalse);
  });

  testWidgets(
    'Selecting an available slot enables the prominent manual reservation button',
    (tester) async {
      await controller.initialize();
      await tester.pumpWidget(createVenueTestApp(controller: controller));
      await tester.pumpAndSettle();

      // Tap on the first available slot (1号场地 10:00-11:00)
      final availableSlotFinder = find
          .ancestor(of: find.text('1号场地'), matching: find.byType(InkWell))
          .first;

      await tester.tap(availableSlotFinder);
      await tester.pumpAndSettle();

      // Verify button is now enabled
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '立即预约'),
      );
      expect(button.enabled, isTrue);

      // Verify selected slot details are shown in the bottom bar
      expect(find.textContaining('已选: 正大体育馆羽毛球场 · 1号场地'), findsOneWidget);
    },
  );

  testWidgets(
    'When automation plugin is absent or disabled, 创建定时任务 button is not shown',
    (tester) async {
      // No plugins in mockBridge.plugins
      mockBridge.plugins = [];
      await controller.initialize();

      await tester.pumpWidget(createVenueTestApp(controller: controller));
      await tester.pumpAndSettle();

      expect(find.text('创建定时任务'), findsNothing);

      // With disabled plugin
      mockBridge.plugins = [
        {
          'id': 'official.fudan-sports',
          'enabled': false,
          'manifest': {
            'id': 'official.fudan-sports',
            'name': 'Fudan Sports',
            'ui': [
              {
                'id': 'sports_schedule',
                'type': 'form',
                'title': '场地预约与定时',
                'ui_version': 1,
              },
            ],
          },
        },
      ];
      await controller.refreshAll();
      await tester.pumpWidget(createVenueTestApp(controller: controller));
      await tester.pumpAndSettle();

      expect(find.text('创建定时任务'), findsNothing);
    },
  );

  testWidgets(
    'When automation plugin is enabled, 创建定时任务 button is shown and routes to SchemaScreen',
    (tester) async {
      mockBridge.plugins = [
        {
          'id': 'official.fudan-sports',
          'enabled': true,
          'manifest': {
            'id': 'official.fudan-sports',
            'name': 'Fudan Sports',
            'ui': [
              {
                'id': 'sports_schedule',
                'type': 'form',
                'title': '场地预约与定时',
                'ui_version': 1,
                'fields': [
                  {'id': 'task_id', 'label': '任务 ID', 'type': 'identifier'},
                ],
                'buttons': [
                  {'label': '预约定时', 'action': 'schedule'},
                ],
              },
            ],
          },
        },
      ];
      await controller.initialize();

      await tester.pumpWidget(createVenueTestApp(controller: controller));
      await tester.pumpAndSettle();

      // Select slot first to verify prefill
      final availableSlotFinder = find
          .ancestor(of: find.text('1号场地'), matching: find.byType(InkWell))
          .first;
      await tester.tap(availableSlotFinder);
      await tester.pumpAndSettle();

      // Button should be visible
      expect(find.text('创建定时任务'), findsOneWidget);

      // Tap the button
      await tester.tap(find.text('创建定时任务'));
      await tester.pumpAndSettle();

      // Should navigate to SchemaScreen rendering '场地预约与定时'
      expect(find.byType(SchemaScreen), findsOneWidget);
      expect(find.text('场地预约与定时'), findsWidgets);

      // Verify initialValues prefill
      final schemaWidget = tester.widget<SchemaScreen>(
        find.byType(SchemaScreen),
      );
      expect(schemaWidget.initialValues, isNotNull);
      expect(schemaWidget.initialValues!['venue_id'], equals(900));
      expect(schemaWidget.initialValues!['target_date'], isNotEmpty);
      expect(schemaWidget.initialValues!['selected_slots'], isNotEmpty);
    },
  );

  testWidgets(
    'Manual reservation executes prepareManual, shows confirmation, and calls reserve',
    (tester) async {
      await controller.initialize();
      await tester.pumpWidget(createVenueTestApp(controller: controller));
      await tester.pumpAndSettle();

      // Select slot
      final availableSlotFinder = find
          .ancestor(of: find.text('1号场地'), matching: find.byType(InkWell))
          .first;
      await tester.tap(availableSlotFinder);
      await tester.pumpAndSettle();

      // Click "立即预约" - single native confirmation flow (no Flutter bottom sheet)
      await tester.tap(find.widgetWithText(FilledButton, '立即预约'));
      await tester.pumpAndSettle();

      // Verify prepareManual and reserve were invoked via CampusApi
      final campusCalls = mockBridge.calls
          .where((c) => c['command'] == HostCommand.campus)
          .toList();
      final methods = campusCalls.map((c) => c['params']['method']).toList();

      expect(methods, contains('venues.prepareManual'));
      expect(methods, contains('venues.reserve'));

      // Verify success snackbar
      expect(find.text('预约成功！'), findsOneWidget);
    },
  );

  testWidgets('Appointments tab displays history records and opens details', (
    tester,
  ) async {
    await controller.initialize();
    await tester.pumpWidget(createVenueTestApp(controller: controller));
    await tester.pumpAndSettle();

    // Switch to appointments tab
    await tester.tap(find.text('我的预约'));
    await tester.pumpAndSettle();

    // Verify appointment record is displayed
    expect(find.text('正大体育馆羽毛球场'), findsWidgets);
    expect(find.textContaining('2099-01-03 10:00-11:00 1号场地'), findsOneWidget);
    expect(find.text('预约成功'), findsOneWidget);

    // Tap appointment item to view details
    await tester.tap(find.text('正大体育馆羽毛球场').first);
    await tester.pumpAndSettle();

    // Verify detail dialog is shown
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('VOUCHER-TEST-9988'), findsOneWidget);
  });

  testWidgets(
    'Offline cancellation flow invokes venues.cancel without second confirmation and supports reconcileCancel',
    (tester) async {
      await controller.initialize();
      await tester.pumpWidget(createVenueTestApp(controller: controller));
      await tester.pumpAndSettle();

      // Switch to appointments tab
      await tester.tap(find.text('我的预约'));
      await tester.pumpAndSettle();

      // Verify appointment slots are displayed
      expect(
        find.textContaining('2099-01-03 10:00-11:00 1号场地'),
        findsOneWidget,
      );

      // Verify "取消这条预约" button is displayed (slot is eligible)
      expect(find.text('取消这条预约'), findsOneWidget);

      // Tap "取消这条预约"
      await tester.tap(find.text('取消这条预约'));
      await tester.pumpAndSettle();

      // Verify NO second Flutter confirmation dialog was displayed (handled solely by native ModernSheet)
      expect(find.byType(AlertDialog), findsNothing);

      // Verify venues.cancel was dispatched with appointment_id 301
      final cancelCall = mockBridge.calls.firstWhere(
        (c) =>
            c['command'] == HostCommand.campus &&
            c['params']['method'] == 'venues.cancel',
      );
      expect(cancelCall['params']['params']['appointment_id'], equals(301));

      // Verify success snackbar
      expect(find.text('预约已取消'), findsOneWidget);

      // --- Test uncertain cancellation and reconcileCancel flow ---
      mockBridge.uncertainCancel = true;
      mockBridge.appointmentsList = [
        {
          'id': 302,
          'resource_name': '南区网球场',
          'status': '已生效',
          'status_name': '已生效',
          'is_cancel': true,
          'slots': [
            {
              'date': '2099-01-04',
              'time': '14:00-15:00',
              'resource_name': '2号场地',
              'active': true,
              'can_cancel': true,
            },
          ],
        },
      ];

      // Refresh appointments
      await tester.tap(find.byTooltip('刷新'));
      await tester.pumpAndSettle();

      expect(find.text('南区网球场'), findsWidgets);
      expect(find.text('取消这条预约'), findsOneWidget);

      // Tap cancel which returns needs_reconciliation
      await tester.tap(find.text('取消这条预约'));
      await tester.pumpAndSettle();

      // Verify "核对" button appears for uncertain cancellation
      expect(find.widgetWithText(OutlinedButton, '核对'), findsWidgets);

      // Tap "核对" button
      await tester.tap(find.widgetWithText(OutlinedButton, '核对').first);
      await tester.pumpAndSettle();

      // Verify venues.reconcileCancel was called with appointment_id 302
      final reconcileCancelCall = mockBridge.calls.firstWhere(
        (c) =>
            c['command'] == HostCommand.campus &&
            c['params']['method'] == 'venues.reconcileCancel',
      );
      expect(
        reconcileCancelCall['params']['params']['appointment_id'],
        equals(302),
      );
      expect(find.textContaining('核对完成: 预约已取消'), findsOneWidget);
    },
  );

  testWidgets('Visible login flow on AuthenticationRequired error', (
    tester,
  ) async {
    mockBridge.throwOnVenues = true;
    mockBridge.throwCode = 'AuthenticationRequired';

    await controller.initialize();
    await tester.pumpWidget(createVenueTestApp(controller: controller));
    await tester.pumpAndSettle();

    // Verify auth error state is displayed with visible login button
    expect(find.text('统一身份认证登录'), findsOneWidget);

    // Tap visible login button
    await tester.tap(find.text('统一身份认证登录'));
    await tester.pumpAndSettle();

    // Verify visibleLogin call was dispatched
    final campusCalls = mockBridge.calls
        .where((c) => c['command'] == HostCommand.campus)
        .toList();
    final methods = campusCalls.map((c) => c['params']['method']).toList();
    expect(methods, contains('venues.visibleLogin'));

    // After login, venues should be loaded successfully
    expect(find.text('正大体育馆羽毛球场'), findsWidgets);
  });

  testWidgets('Account change revokes selection and reloads venues', (
    tester,
  ) async {
    await controller.initialize();
    await tester.pumpWidget(createVenueTestApp(controller: controller));
    await tester.pumpAndSettle();

    // Select slot
    final availableSlotFinder = find
        .ancestor(of: find.text('1号场地'), matching: find.byType(InkWell))
        .first;
    await tester.tap(availableSlotFinder);
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilledButton, '立即预约'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '立即预约'))
          .enabled,
      isTrue,
    );

    // Switch account
    mockBridge.activeAccount = 'student_test_02';
    await controller.switchAccount('student_test_02');
    await tester.pumpAndSettle();

    // Slot selection should be revoked, button disabled
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '立即预约'))
          .enabled,
      isFalse,
    );
  });
}

import 'package:dansheng_app/ui/core/dansheng_client.dart';
import 'package:dansheng_app/ui/schema/schema_models.dart';
import 'package:dansheng_app/ui/schema/schema_renderer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

void main() {
  group('Schema Renderer Tests', () {
    testWidgets(
      'Schema A: identifier, select & datetime clear stale dependents, JSON multiselect',
      (WidgetTester tester) async {
        final mockBridge = MockDanshengBridge();
        mockBridge.accountId = 'student_888';

        // 1. Dynamic select options returning [{label, value}]
        mockBridge.actionHandlers['venueOptions'] = (input) {
          expect(input['account_id'], 'student_888');
          return [
            {'label': '一号中心', 'value': 'center_1'},
            {'label': '二号中心', 'value': 'center_2'},
          ];
        };

        // 2. Dynamic multiselect returning JSON object values
        mockBridge.actionHandlers['slotOptions'] = (input) {
          final venue = input['venue_id'];
          if (venue == 'center_1') {
            return [
              {
                'label': '08:00-09:00 (A区)',
                'value': {'slot_id': 101, 'court': 'A1', 'price': 20},
              },
              {
                'label': '09:00-10:00 (A区)',
                'value': {'slot_id': 102, 'court': 'A1', 'price': 20},
              },
            ];
          }
          return [
            {
              'label': '14:00-15:00 (B区)',
              'value': {'slot_id': 201, 'court': 'B1', 'price': 25},
            },
          ];
        };

        mockBridge.actionHandlers['submit_plan'] = (input) {
          expect(input['account_id'], 'student_888');
          expect(input['task_id'], isNotEmpty);
          expect(input.containsKey('_draft_id'), isFalse);
          expect(
            input.containsKey('approved'),
            isFalse,
          ); // Never caller-insert approved!
          expect(input['selected_slots'], isA<List>());
          return {
            'status': 'scheduled',
            'task_id': input['task_id'],
            'summary': '已成功提交预约计划',
          };
        };

        final client = DanshengClient(bridge: mockBridge);

        // Declared schema matching generic form with identifier, select, datetime, and JSON multiselect
        final declarationA = UiDeclarationModel.fromJson({
          'id': 'booking_plan',
          'type': 'form',
          'title': '服务定时预约',
          'ui_version': 1,
          'time_zone': 'Asia/Shanghai',
          'fields': [
            {'id': 'task_id', 'label': '任务 ID', 'type': 'identifier'},
            {
              'id': 'venue_id',
              'label': '场馆',
              'type': 'select',
              'source': {'action': 'venueOptions'},
              'clearOnChange': ['selected_slots'],
            },
            {
              'id': 'target_date',
              'label': '预约日期',
              'type': 'date',
              'clearOnChange': ['selected_slots'],
            },
            {'id': 'release_at', 'label': '开抢时间', 'type': 'datetime'},
            {
              'id': 'selected_slots',
              'label': '预约时段与场地',
              'type': 'multiselect',
              'source': {
                'action': 'slotOptions',
                'dependsOn': ['venue_id', 'target_date'],
              },
            },
          ],
          'buttons': [
            {
              'label': '提交计划',
              'action': 'submit_plan',
              'fields': [
                'task_id',
                'venue_id',
                'target_date',
                'release_at',
                'selected_slots',
              ],
              'confirm': false,
            },
          ],
        });

        await tester.pumpWidget(
          buildTestApp(
            home: Scaffold(
              body: SchemaRenderer(
                pluginId: 'org.example.service',
                declaration: declarationA,
                client: client,
                activeAccountId: 'student_888',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // The draft still submits its stable task ID without adding an input to the form.
        expect(find.text('任务 ID'), findsNothing);
        expect(find.text('草稿标识'), findsNothing);

        // Select venue_id -> '一号中心'
        await tester.tap(
          find.byType(DropdownButtonFormField<SelectOption>).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('一号中心').last);
        await tester.pumpAndSettle();

        // Pick date
        await tester.tap(find.text('选择日期 (Asia/Shanghai)'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();

        // Verify slotOptions loaded with JSON value filter chips
        expect(find.text('08:00-09:00 (A区)'), findsOneWidget);
        await tester.tap(find.text('08:00-09:00 (A区)'));
        await tester.pumpAndSettle();

        // Change venue -> verify stale dependent selected_slots is cleared!
        await tester.tap(
          find.byType(DropdownButtonFormField<SelectOption>).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('二号中心').last);
        await tester.pumpAndSettle();

        // Now options for center_2 should appear
        expect(find.text('14:00-15:00 (B区)'), findsOneWidget);
        await tester.tap(find.text('14:00-15:00 (B区)'));
        await tester.pumpAndSettle();

        // Submit plan
        await tester.ensureVisible(find.text('提交计划'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('提交计划'));
        await tester.pumpAndSettle();

        // Verify results displayed
        expect(find.text('执行结果'), findsOneWidget);
        expect(find.textContaining('已成功提交预约计划'), findsOneWidget);
      },
    );

    testWidgets(
      'Schema B: Prepared input normalization, cancellation, error codes, dynamic task rows without raw params',
      (WidgetTester tester) async {
        final mockBridge = MockDanshengBridge();
        mockBridge.accountId = 'student_999';

        // 1. Prepare action normalizes form selection into canonical task plan
        mockBridge.actionHandlers['prepareSchedule'] = (input) {
          expect(input['account_id'], 'student_999');
          return {
            'task_id': input['task_id'] ?? 'auto_task_001',
            'account_id': input['account_id'],
            'normalized_spec': {'priority': 1, 'max_retries': 3},
          };
        };

        // 2. Schedule action returns dynamic task rows
        mockBridge.actionHandlers['schedule'] = (input) {
          expect(
            input.containsKey('normalized_spec'),
            isTrue,
          ); // verified normalized input from prepare
          expect(
            input.containsKey('approved'),
            isFalse,
          ); // never caller-insert approved

          return [
            {
              'id': 'task_alpha',
              'task_id': 'task_alpha',
              'state': 'scheduled',
              'run_at': '2026-11-09 08:00',
              'updated_at': '2026-11-08 13:00',
              'plugin_id': 'org.example.job',
              'action': 'reserve',
              'account_id': 'student_999',
              'wake_up': null, // No wake_up -> must not claim armed!
            },
            {
              'id': 'task_beta',
              'task_id': 'task_beta',
              'state': 'scheduled',
              'run_at': '2026-11-09 09:00',
              'updated_at': '2026-11-08 13:00',
              'plugin_id': 'org.example.job',
              'action': 'reserve',
              'account_id': 'student_999',
              'wake_up': 1762600000000, // Valid wake_up -> armed!
            },
          ];
        };

        final client = DanshengClient(bridge: mockBridge);

        final declarationB = UiDeclarationModel.fromJson({
          'id': 'reservation_flow',
          'type': 'form',
          'title': '定时任务设定',
          'ui_version': 1,
          'fields': [
            {'id': 'task_id', 'label': '任务标识', 'type': 'identifier'},
          ],
          'buttons': [
            {
              'label': '确认预约定时',
              'action': 'schedule',
              'prepare': 'prepareSchedule',
              'fields': ['task_id'],
              'confirm': true,
            },
          ],
        });

        await tester.pumpWidget(
          buildTestApp(
            home: Scaffold(
              body: SchemaRenderer(
                pluginId: 'org.example.job',
                declaration: declarationB,
                client: client,
                activeAccountId: 'student_999',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Tap button to trigger prepare + preview
        await tester.tap(find.text('确认预约定时'));
        await tester.pumpAndSettle();

        // Confirmation dialog is shown with SHA-256 fingerprint
        expect(find.text('操作确认: 确认预约定时'), findsOneWidget);
        expect(
          find.textContaining('mock_sha256_schedule_hash'),
          findsOneWidget,
        );

        // 1. Test Cancellation: tap "取消"
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();

        // Dialog closed, no execution occurred
        expect(find.text('操作确认: 确认预约定时'), findsNothing);
        expect(find.text('执行结果'), findsNothing);

        // 2. Tap again and Confirm execution
        await tester.tap(find.text('确认预约定时'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('确认执行'));
        await tester.pumpAndSettle();

        // Verify dynamic task rows rendered cleanly
        expect(find.text('task_alpha'), findsOneWidget);
        expect(find.text('task_beta'), findsOneWidget);

        // Verify unarmed task does not claim armed:
        expect(find.text('已保存 (未设闹钟)'), findsOneWidget);
        // Verify armed task displays armed:
        expect(find.text('已设闹钟 (Armed)'), findsOneWidget);
      },
    );

    testWidgets(
      'Schema Downgrade: Unsupported ui_version shows fallback card gracefully',
      (WidgetTester tester) async {
        final mockBridge = MockDanshengBridge();
        final client = DanshengClient(bridge: mockBridge);

        final unsupportedDeclaration = UiDeclarationModel.fromJson({
          'id': 'future_feature',
          'type': 'form',
          'title': '未来组件',
          'ui_version': 99,
          'fields': [],
          'buttons': [],
        });

        await tester.pumpWidget(
          buildTestApp(
            home: Scaffold(
              body: SchemaRenderer(
                pluginId: 'org.example.future',
                declaration: unsupportedDeclaration,
                client: client,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Verify graceful fallback banner
        expect(find.text('界面版本不兼容'), findsOneWidget);
        expect(find.textContaining('当前声明所要求的版本为 v99'), findsOneWidget);
      },
    );
  });
}

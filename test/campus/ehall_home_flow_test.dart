// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dansheng_app/bridge.g.dart';
import 'package:dansheng_app/ui/core/dansheng_client.dart';
import 'package:dansheng_app/ui/core/dansheng_state.dart';
import 'package:dansheng_app/ui/campus/ehall/ehall_page.dart';
import 'package:dansheng_app/ui/campus/ehall/life_page.dart';
import 'package:dansheng_app/ui/theme/app_theme.dart';

class MockHomeFlowBridge implements DanshengBridge {
  String? activeAccount = '21307130001';
  List<Map<String, dynamic>> plugins = [];
  final List<Map<String, dynamic>> campusCalls = [];
  Map<String, dynamic> balanceData = {
    'balance': '238.50',
    'holder_name': '复旦同学',
    'currency': 'CNY',
    'updated_at': '2026-11-08T08:00:00Z',
  };

  String? throwOnMethod;
  String throwCode = 'AuthenticationRequired';
  int callDelayMs = 0;

  @override
  Future<String> invoke(HostCommand command, String payload) async {
    final Map<String, dynamic> params = payload.isNotEmpty
        ? (jsonDecode(payload) as Map<String, dynamic>)
        : <String, dynamic>{};

    switch (command) {
      case HostCommand.info:
        return jsonEncode({'version': '0.1.0'});
      case HostCommand.plugins:
        return jsonEncode(plugins);
      case HostCommand.account:
        return jsonEncode({'account_id': activeAccount});
      case HostCommand.setAccount:
        activeAccount = params['account_id']?.toString();
        return jsonEncode({'account_id': activeAccount});
      case HostCommand.jobs:
        return jsonEncode([]);
      case HostCommand.permissions:
        return jsonEncode({
          'exact_available': true,
          'notifications_available': true,
        });
      case HostCommand.balance:
        return jsonEncode(balanceData);
      case HostCommand.campus:
        final method = params['method']?.toString() ?? '';
        final methodParams = params['params'] as Map<String, dynamic>? ?? {};
        campusCalls.add({'method': method, 'params': methodParams});

        if (callDelayMs > 0) {
          await Future<void>.delayed(Duration(milliseconds: callDelayMs));
        }

        if (throwOnMethod != null && method == throwOnMethod) {
          throw PlatformException(code: throwCode, message: throwCode);
        }

        switch (method) {
          case 'campus.cached':
            final cachedMethod = methodParams['method'];
            if (cachedMethod == 'fudan.electricity') {
              return jsonEncode({
                'id': 'electricity:ROOM-201',
                'payload': {
                  'room_id': 'ROOM-201',
                  'campus': '邯郸校区',
                  'building': '东安一号楼',
                  'room': '302室',
                  'remaining_kwh': 45.2,
                  'used_kwh': 120.5,
                },
              });
            }
            if (cachedMethod == 'fudan.rooms') {
              return jsonEncode([
                {
                  'id': '501',
                  'payload': {
                    'room': 'H3101',
                    'seats': 80,
                    'available': true,
                    'busy_units': [false, false, true, true, false],
                  },
                },
              ]);
            }
            return jsonEncode(null);

          case 'fudan.electricity':
            return jsonEncode({
              'id': 'electricity:ROOM-201',
              'payload': {
                'room_id': 'ROOM-201',
                'campus': '邯郸校区',
                'building': '东安一号楼',
                'room': '302室',
                'remaining_kwh': 42.0,
                'used_kwh': 125.0,
              },
            });

          case 'fudan.library.occupancy':
            return jsonEncode({
              'records': [
                {'campus': '邯郸文科图书馆', 'inside': 142, 'capacity': 500},
                {'campus': '李兆基图书馆', 'inside': 328, 'capacity': 800},
              ].map((row) => {'payload': row}).toList(),
            });

          case 'fudan.dining.occupancy':
            return jsonEncode({
              'records': [
                {'name': '光华餐厅一楼', 'current': 210, 'capacity': 600},
                {'name': '旦苑餐厅二楼', 'current': 380, 'capacity': 800},
              ].map((row) => {'payload': row}).toList(),
            });

          case 'fudan.rooms':
            return jsonEncode([
              {
                'id': '501',
                'room': 'H3101',
                'seats': 80,
                'available': true,
                'busy_units': [false, false, true, true, false],
              },
            ]);

          case 'fudan.bus':
            return jsonEncode([
              {
                'id': 'bus-1',
                'from': '邯郸校区',
                'to': '江湾校区',
                'starts_at': '07:30',
                'ends_at': '08:10',
                'direction': 'both',
              },
            ]);

          case 'fudan.notices':
            return jsonEncode([
              {'title': '关于秋季学期选课安排的通知', 'published_on': '2026-11-01'},
            ]);

          case 'fudan.ecard.transactions':
            return jsonEncode([
              {
                'location': '旦苑第一餐厅',
                'transaction_type': '餐饮消费',
                'at': '2026-11-08 12:15',
                'amount': {'cents': 1850, 'currency': 'CNY'},
              },
            ]);

          case 'venues.venues':
            return jsonEncode([
              {'id': 900, 'name': '正大体育馆羽毛球场'},
            ]);

          case 'venues.calendar':
            return jsonEncode({
              'slots': [
                {
                  'period_id': 71,
                  'time': '10:00-11:00',
                  'court_id': 101,
                  'court_name': '1号场地',
                  'available': true,
                },
              ],
            });

          default:
            return jsonEncode({'result': 'ok'});
        }
      default:
        return jsonEncode({'result': 'ok'});
    }
  }
}

Widget buildTestApp({required Widget home}) {
  return MaterialApp(
    theme: AppTheme.lightTheme,
    darkTheme: AppTheme.darkTheme,
    home: home,
  );
}

void main() {
  late MockHomeFlowBridge bridge;
  late DanshengController controller;
  setUp(() async {
    bridge = MockHomeFlowBridge();
    controller = DanshengController(client: DanshengClient(bridge: bridge));
    await controller.initialize();
  });
  testWidgets('home entries have one title and make no campus reads', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildTestApp(home: EHallPage(controller: controller)),
    );
    await tester.pumpAndSettle();
    expect(bridge.campusCalls, isEmpty);
    for (final tile in tester.widgetList<ListTile>(find.byType(ListTile))) {
      expect(tile.subtitle, isNull);
      expect((tile.title! as Text).maxLines, 1);
    }
  });
  for (final entry in {
    '校园卡': LifeService.transactions,
    '教室空位': LifeService.rooms,
    '寝室电量': LifeService.power,
    '图书馆客流': LifeService.library,
  }.entries) {
    testWidgets('one tap opens ${entry.key}', (tester) async {
      await tester.pumpWidget(
        buildTestApp(home: EHallPage(controller: controller)),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text(entry.key));
      await tester.tap(find.text(entry.key));
      await tester.pumpAndSettle();
      expect(
        tester.widget<LifePage>(find.byType(LifePage)).service,
        entry.value,
      );
      expect(
        bridge.campusCalls.any((c) => c['method'] == entry.value.method),
        isTrue,
      );
    });
  }
  for (final width in [240.0, 360.0]) {
    testWidgets('entry list fits narrow screens with large text $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: Size(width, 900),
              textScaler: TextScaler.linear(1.8),
            ),
            child: EHallPage(controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}

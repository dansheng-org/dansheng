// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:dansheng_app/bridge.g.dart';
import 'package:dansheng_app/ui/campus/ehall/board/board_layout.dart';
import 'package:dansheng_app/ui/campus/ehall/ehall_page.dart';
import 'package:dansheng_app/ui/campus/ehall/life_page.dart';
import 'package:dansheng_app/ui/core/dansheng_client.dart';
import 'package:dansheng_app/ui/core/dansheng_state.dart';
import 'package:dansheng_app/ui/theme/app_theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A host that keeps the arrangement in memory and answers reads from
/// [cache] (local) or [live] (the services).
class BoardBridge implements DanshengBridge {
  String? account = '21307130001';
  Map<String, dynamic>? saved;
  final calls = <Map<String, dynamic>>[];
  final cache = <String, dynamic>{};
  final live = <String, dynamic>{};
  final failing = <String, String>{};

  static String key(String method, Map params) {
    final sorted = Map.fromEntries(
      params.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
    return '$method ${jsonEncode(sorted)}';
  }

  List<String> get methods => [for (final c in calls) c['method'] as String];

  @override
  Future<String> invoke(HostCommand command, String payload) async {
    final params = jsonDecode(payload) as Map<String, dynamic>;
    switch (command) {
      case HostCommand.account:
        return jsonEncode({'account_id': account});
      case HostCommand.plugins:
      case HostCommand.jobs:
        return '[]';
      case HostCommand.campus:
        final method = params['method'] as String;
        final p = Map<String, dynamic>.from(params['params'] as Map);
        calls.add({'method': method, 'params': Map<String, dynamic>.of(p)});
        if (method == 'ehall.layout.get') return jsonEncode(saved);
        if (method == 'ehall.layout.set') {
          saved = p['layout'] as Map<String, dynamic>;
          return jsonEncode({'saved': true});
        }
        if (account == null) {
          throw PlatformException(code: 'AccountRequired');
        }
        if (method == 'campus.cached') {
          final source = p.remove('method') as String;
          return jsonEncode(cache[key(source, p)]);
        }
        final failure = failing[method];
        if (failure != null) throw PlatformException(code: failure);
        final k = key(method, p);
        if (live.containsKey(k)) {
          cache[k] = live[k];
          return jsonEncode(live[k]);
        }
        return jsonEncode({'result': 'ok'});
      default:
        return '{}';
    }
  }
}

Map<String, dynamic> batch(List<Map<String, dynamic>> rows) => {
  'source': {'observed_at': DateTime.now().toUtc().toIso8601String()},
  'records': [
    for (final row in rows) {'payload': row},
  ],
  'coverage': {'state': 'complete'},
};

void main() {
  late BoardBridge bridge;
  late DanshengController controller;

  setUp(() async {
    bridge = BoardBridge();
    controller = DanshengController(client: DanshengClient(bridge: bridge));
    await controller.initialize();
  });

  Future<void> open(
    WidgetTester tester, {
    Size size = const Size(400, 1600),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: EHallPage(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
  }

  BoardLayout savedLayout() => BoardLayout.fromJson(bridge.saved);

  testWidgets('tiles show stored data and an icon tile reads nothing', (
    tester,
  ) async {
    bridge.cache[BoardBridge.key('fudan.library.occupancy', {})] = batch([
      {'campus': '文科馆', 'inside': 142},
      {'campus': '理科馆', 'inside': 328},
    ]);
    bridge.cache[BoardBridge.key('fudan.electricity', {})] = {
      'observed_at': DateTime.now().toUtc().toIso8601String(),
      'payload': {
        'campus': '邯郸校区',
        'building': '东区1号楼',
        'room': '302',
        'remaining_kwh': 42.5,
        'used_kwh': 120,
      },
    };
    await open(tester);
    expect(find.textContaining('470'), findsOneWidget);
    expect(find.textContaining('42.5'), findsOneWidget);
    // 课程成绩 starts as an icon: no read for it at all.
    expect(
      bridge.calls.where(
        (c) =>
            c['method'] == 'campus.cached' &&
            '${c['params']['method']}'.contains('grades'),
      ),
      isEmpty,
    );
    // Venues and mail are shortcuts that never read.
    expect(
      bridge.calls.where(
        (c) => '${c['params']['method']}'.startsWith('venues.'),
      ),
      isEmpty,
    );
  });

  testWidgets('the saved arrangement decides order, size and visibility', (
    tester,
  ) async {
    bridge.saved = BoardLayout.standard()
        .show(EHallTile.mail, false)
        .resize(EHallTile.bus, TileSize.icon)
        .moveShown(EHallTile.exams, 0)
        .toJson();
    await open(tester);
    expect(find.text('校园邮箱'), findsNothing);
    final exams = tester.getTopLeft(find.text('考试安排'));
    final ecard = tester.getTopLeft(find.text('校园卡'));
    expect(exams.dy, lessThan(ecard.dy));
    // A bus icon does not read the timetable.
    expect(
      bridge.calls.where((c) => c['params']['method'] == 'fudan.bus'),
      isEmpty,
    );
  });

  testWidgets('editing hides, shows and resizes tiles and saves each change', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byTooltip('编辑小组件'));
    await tester.pumpAndSettle();
    expect(find.text('编辑小组件'), findsOneWidget);
    expect(find.text('所有小组件都已显示'), findsOneWidget);

    // Hide 场馆预约 through its tile settings.
    await tester.tap(find.text('场馆预约'));
    await tester.pumpAndSettle();
    expect(find.text('在首页显示'), findsOneWidget);
    await tester.tap(find.text('在首页显示'));
    await tester.pumpAndSettle();
    expect(savedLayout().slot(EHallTile.venues).shown, isFalse);

    // Resize 校园卡 to the large size from the same kind of sheet.
    Navigator.of(tester.element(find.text('在首页显示'))).pop();
    await tester.pumpAndSettle();
    await tester.tap(find.text('校园卡'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('大 4×2'));
    await tester.pumpAndSettle();
    expect(savedLayout().slot(EHallTile.ecard).size, TileSize.large);
    Navigator.of(tester.element(find.text('大 4×2'))).pop();
    await tester.pumpAndSettle();

    // The hidden tile waits in the tray and comes back from there.
    expect(find.byTooltip('显示场馆预约'), findsOneWidget);
    await tester.tap(find.byTooltip('显示场馆预约'));
    await tester.pumpAndSettle();
    expect(savedLayout().slot(EHallTile.venues).shown, isTrue);

    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.text('eHall'), findsOneWidget);
  });

  testWidgets('content options change what a tile reads and opens', (
    tester,
  ) async {
    bridge.saved = BoardLayout.standard()
        .withOption(EHallTile.dining, 'area', 2)
        .toJson();
    await open(tester);
    expect(
      bridge.calls.any(
        (c) =>
            c['params']['method'] == 'fudan.dining.occupancy' &&
            c['params']['area_code'] == 2,
      ),
      isTrue,
    );
    await tester.tap(find.text('食堂实时客流'));
    await tester.pumpAndSettle();
    final page = tester.widget<LifePage>(find.byType(LifePage));
    expect(page.initialDiningArea, 2);
    expect(bridge.calls.last, {
      'method': 'fudan.dining.occupancy',
      'params': {'area_code': 2},
    });
  });

  testWidgets('long press and drag moves a tile', (tester) async {
    bridge.saved = BoardLayout.standard().toJson();
    await open(tester);
    // 校园卡 is first; drag it below 场馆预约.
    final from = tester.getCenter(find.text('校园卡'));
    final to = tester.getCenter(find.text('图书馆客流'));
    final gesture = await tester.startGesture(from);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    for (var i = 1; i <= 10; i++) {
      await gesture.moveTo(
        Offset.lerp(from, to + const Offset(0, 30), i / 10)!,
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    final order = [for (final s in savedLayout().shown) s.tile];
    expect(order.first, isNot(EHallTile.ecard));
    expect(order.indexOf(EHallTile.ecard), greaterThan(2));
    expect(order.toSet().length, order.length);
    // Dragging enters edit mode.
    expect(find.text('完成'), findsOneWidget);
  });

  testWidgets('pull to refresh reads the shown services and reports problems', (
    tester,
  ) async {
    bridge.live[BoardBridge.key('fudan.library.occupancy', {})] = batch([
      {'campus': '文科馆', 'inside': 99},
    ]);
    bridge.failing['fudan.electricity'] = 'AuthenticationRequired';
    await open(tester);
    expect(find.textContaining('99'), findsNothing);
    await tester.fling(find.byType(ListView), const Offset(0, 400), 1000);
    await tester.pumpAndSettle();
    expect(find.textContaining('99'), findsOneWidget);
    expect(find.text('需要登录'), findsOneWidget);
    final live = bridge.methods.where((m) => m.startsWith('fudan.')).toSet();
    expect(live, contains('fudan.library.occupancy'));
    // Icons and shortcuts are left alone.
    expect(live, isNot(contains('fudan.grades')));
    expect(bridge.methods.where((m) => m.startsWith('venues.')), isEmpty);
  });

  testWidgets('signed out the board opens without account reads', (
    tester,
  ) async {
    bridge.account = null;
    controller = DanshengController(client: DanshengClient(bridge: bridge));
    await controller.initialize();
    await open(tester);
    expect(bridge.methods.where((m) => m != 'campus.loginStatus'), [
      'ehall.layout.get',
    ]);
    expect(find.text('未设置账号'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  for (final (width, scale) in [(240.0, 1.8), (320.0, 1.3), (900.0, 1.0)]) {
    testWidgets('every size fits at $width wide, text x$scale', (tester) async {
      bridge.saved = {
        'tiles': [
          for (final (i, tile) in EHallTile.values.indexed)
            {'id': tile.id, 'size': TileSize.values[i % 5].id},
        ],
      };
      bridge.cache[BoardBridge.key('fudan.library.occupancy', {})] = batch([
        {'campus': '邯郸文科图书馆', 'inside': 142},
        {'campus': '李兆基图书馆', 'inside': 328},
      ]);
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.lightTheme,
          home: MediaQuery(
            data: MediaQueryData(
              size: Size(width, 900),
              textScaler: TextScaler.linear(scale),
            ),
            child: EHallPage(controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('编辑小组件'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}

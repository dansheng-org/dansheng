// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dansheng_app/bridge.g.dart';
import 'package:dansheng_app/ui/core/dansheng_client.dart';
import 'package:dansheng_app/ui/core/dansheng_state.dart';
import 'package:dansheng_app/ui/campus/campus_api.dart';
import 'package:dansheng_app/ui/campus/ehall/ehall_page.dart';
import 'package:dansheng_app/ui/campus/ehall/life_page.dart';
import 'package:dansheng_app/ui/campus/venues/venue_page.dart';
import 'package:dansheng_app/ui/theme/app_theme.dart';

const undergraduateNotice = '关于2026年秋季学期选课与退课安排的通知';
const graduateNotice = '关于2026年研究生学位论文送审安排的通知';
const cachedUndergraduateNotice = '上学期本科生缓存公告';
const cachedGraduateNotice = '上学期研究生缓存公告';

/// Same envelope the core returns for `fudan.notices`.
Map<String, dynamic> noticeBatch(String title, String origin) {
  final url = '$origin/2026/1101/c1a1/page.htm';
  return {
    'records': [
      {
        'external_id': url,
        'payload': {'title': title, 'url': url, 'published_on': '2026-11-01'},
      },
    ],
  };
}

/// Test mock implementation of DanshengBridge specifically handling
/// eHall campus services and venue inquiries.
class MockEHallBridge implements DanshengBridge {
  String? activeAccount = '21307130001';
  List<Map<String, dynamic>> plugins = [];
  List<Map<String, dynamic>> jobs = [];
  final List<Map<String, dynamic>> campusCalls = [];

  bool throwOnVenues = false;
  String? throwOnMethod;
  String throwCode = 'AuthenticationRequired';
  bool hasCachedRooms = true;

  /// Holds the undergraduate notices response back until completed.
  Completer<void>? undergraduateNoticesGate;

  Map<String, dynamic> balanceData = {
    'balance': '238.50',
    'holder_name': '复旦同学',
    'currency': 'CNY',
    'updated_at': '2026-11-08T08:00:00Z',
  };

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
        return jsonEncode(jobs);

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

        if (throwOnMethod != null && method == throwOnMethod) {
          throw PlatformException(code: throwCode, message: throwCode);
        }

        if (throwOnVenues &&
            method != 'venues.visibleLogin' &&
            method.startsWith('venues.')) {
          throw PlatformException(code: throwCode, message: throwCode);
        }

        switch (method) {
          case 'campus.cached':
            final cachedMethod = methodParams['method'];
            if (cachedMethod == 'fudan.electricity') {
              // Return nested payload conforming to Rust SourceRecord structure
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
            if (cachedMethod == 'fudan.rooms' && hasCachedRooms) {
              // The real cache holds the whole source batch, not a bare row list.
              return jsonEncode({
                'source': 'official.fudan',
                'records': [
                  {
                    'id': '501',
                    'payload': {
                      'room': 'H3101',
                      'seats': 80,
                      'available': true,
                      'busy_units': [false, false, true, true, false],
                    },
                  },
                ],
              });
            }
            if (cachedMethod == 'fudan.notices') {
              return jsonEncode(
                methodParams['level'] == 'graduate'
                    ? noticeBatch(
                        cachedGraduateNotice,
                        'https://gs.fudan.edu.cn',
                      )
                    : noticeBatch(
                        cachedUndergraduateNotice,
                        'https://jwc.fudan.edu.cn',
                      ),
              );
            }
            return jsonEncode(null);

          case 'venues.venues':
            return jsonEncode(venuesList);

          case 'venues.calendar':
            return jsonEncode(calendarResponse);

          case 'venues.appointments':
            return jsonEncode([]);

          case 'venues.visibleLogin':
            throwOnVenues = false;
            return jsonEncode({
              'authenticated': true,
              'account_id': activeAccount,
            });

          case 'fudan.semesters':
            return jsonEncode({
              'semesters': [
                {'external_id': '2026-autumn', 'name': '2026年秋季学期'},
              ],
              'default_semester_id': '2026-autumn',
            });

          case 'fudan.student_association':
            return jsonEncode({
              'id': 'student-association',
              'payload': '82711',
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
              {
                'id': '502',
                'room': 'H3102',
                'seats': 120,
                'available': false,
                'busy_units': [true, true, true, true, true],
              },
            ]);

          case 'fudan.electricity':
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

          case 'fudan.library.occupancy':
            return jsonEncode([
              {'campus': '邯郸文科图书馆', 'inside': 142, 'capacity': 500},
              {'campus': '李兆基图书馆', 'inside': 328, 'capacity': 800},
            ]);

          case 'fudan.dining.occupancy':
            return jsonEncode([
              {'name': '光华餐厅一楼', 'current': 210, 'capacity': 600},
              {'name': '旦苑餐厅二楼', 'current': 380, 'capacity': 800},
            ]);

          case 'fudan.bus':
            final holiday = methodParams['holiday'] == true;
            return jsonEncode([
              {
                'id': 'bus-1',
                'from': '邯郸校区',
                'to': '江湾校区',
                'starts_at': holiday ? '09:00' : '07:30',
                'ends_at': holiday ? '09:40' : '08:10',
                'direction': 'both',
                'holiday': holiday,
              },
              {
                'id': 'bus-2',
                'from': '邯郸校区',
                'to': '枫林校区',
                'starts_at': holiday ? '10:00' : '08:00',
                'ends_at': holiday ? '10:50' : '08:50',
                'direction': 'both',
                'holiday': holiday,
              },
            ]);

          case 'fudan.notices':
            if (methodParams['level'] == 'graduate') {
              return jsonEncode(
                noticeBatch(graduateNotice, 'https://gs.fudan.edu.cn'),
              );
            }
            await undergraduateNoticesGate?.future;
            return jsonEncode(
              noticeBatch(undergraduateNotice, 'https://jwc.fudan.edu.cn'),
            );

          case 'fudan.ecard.transactions':
            return jsonEncode([
              {
                'location': '旦苑第一餐厅',
                'transaction_type': '餐饮消费',
                'at': '2026-11-08 12:15',
                'amount': {'cents': 1850, 'currency': 'CNY'},
              },
            ]);

          case 'fudan.gpa':
            return jsonEncode({
              'records': [
                {
                  'payload': {
                    'student_code': '21307130001',
                    'name': '复旦同学',
                    'major': '计算机科学与技术',
                    'department': '计算机科学技术学院',
                    'gpa': 3.88,
                    'credits': 118.5,
                    'ranking': 5,
                  },
                },
              ],
            });

          case 'fudan.grades':
            return jsonEncode([
              {
                'course_name': '编译原理',
                'letter_grade': 'A',
                'credits': 4.0,
                'grade_point': 4.0,
              },
              {
                'course_name': '计算机系统结构',
                'letter_grade': 'A-',
                'credits': 3.5,
                'grade_point': 3.7,
              },
            ]);

          case 'fudan.exams':
            return jsonEncode([
              {
                'course_name': '操作系统原理',
                'on': '2026-12-20',
                'time_range': '09:00-11:00',
                'room': 'H3101',
                'exam_type': '期末考试',
              },
            ]);

          default:
            return jsonEncode({'result': 'ok'});
        }

      default:
        return jsonEncode({'result': 'ok'});
    }
  }
}

Widget buildTestApp({
  required Widget home,
  ThemeMode mode = ThemeMode.light,
  double textScale = 1.0,
}) {
  return MaterialApp(
    theme: AppTheme.lightTheme,
    darkTheme: AppTheme.darkTheme,
    themeMode: mode,
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: home,
    ),
  );
}

void main() {
  group('eHall Home & Life Services Complete Suite', () {
    late MockEHallBridge mockBridge;
    late DanshengClient client;
    late DanshengController controller;

    setUp(() async {
      mockBridge = MockEHallBridge();
      client = DanshengClient(bridge: mockBridge);
      controller = DanshengController(client: client);
      await controller.initialize();
      await controller.refreshBalance();
    });

    testWidgets(
      '1. EHallPage renders with ZERO hidden network calls on first open',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        mockBridge.campusCalls.clear();

        await tester.pumpWidget(
          buildTestApp(home: EHallPage(controller: controller)),
        );
        await tester.pumpAndSettle();

        // Verify no venues network calls happened during initial open
        final venueNetworkCalls = mockBridge.campusCalls
            .where(
              (c) =>
                  c['method'] == 'venues.venues' ||
                  c['method'] == 'venues.calendar',
            )
            .toList();
        expect(
          venueNetworkCalls,
          isEmpty,
          reason: 'Must not trigger hidden network calls on open',
        );

        // Verify concise unqueried subtitle without hardcoded venue enumeration
        expect(find.text('选场馆、看空位、预约'), findsOneWidget);
        expect(find.textContaining('正大体育馆 · 南区网球场'), findsNothing);

        // Verify key titles and sections
        expect(find.text('校园办事'), findsOneWidget);
        expect(find.text('校园卡'), findsOneWidget);
        expect(find.text('教室空位'), findsOneWidget);
        expect(find.text('寝室电量'), findsOneWidget);
        expect(find.text('场馆预约'), findsOneWidget);
        expect(find.text('生活与出行'), findsOneWidget);
        expect(find.text('教务查询'), findsOneWidget);
        expect(find.text('校园邮箱'), findsOneWidget);
        expect(find.widgetWithText(ListTile, '校园卡明细'), findsNothing);

        // Verify initial unqueried venue snapshot prompt
        expect(find.text('查询今日空位'), findsOneWidget);
      },
    );

    testWidgets(
      '2. Prominent cards display real balance, truthful seats and nested power payload',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          buildTestApp(home: EHallPage(controller: controller)),
        );
        await tester.pumpAndSettle();

        // Card balance prominent display
        expect(find.text('¥ 238.50'), findsOneWidget);
        expect(find.textContaining('复旦同学'), findsOneWidget);

        // Dorm power cached value from nested payload
        expect(find.text('45.2 kWh'), findsOneWidget);

        // Classroom cached value counts the rooms in the cached batch
        expect(find.text('1 间教室'), findsOneWidget);
      },
    );

    testWidgets(
      '3. Visibly distinguishes no-account state without fabricated zeros',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        mockBridge.activeAccount = null;
        mockBridge.balanceData = {};
        controller = DanshengController(client: client);
        await controller.initialize();

        await tester.pumpWidget(
          buildTestApp(home: EHallPage(controller: controller)),
        );
        await tester.pumpAndSettle();

        // Zero fabricated balance check
        expect(find.text('¥ 0.00'), findsNothing);
        expect(find.text('¥ 0'), findsNothing);
        expect(find.text('设置账号'), findsWidgets);

        // Room and power show pending account configuration
        expect(find.text('待设置账号'), findsNWidgets(2));

        // Trigger venue query without account -> visibly shows account prompt
        await tester.scrollUntilVisible(find.text('查询今日空位'), 200);
        await tester.tap(find.text('查询今日空位'));
        await tester.pumpAndSettle();

        expect(find.textContaining('未设置账号'), findsWidgets);
      },
    );

    testWidgets(
      '4. User-triggered venue query shows summary, slots, and manual drill-down',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          buildTestApp(home: EHallPage(controller: controller)),
        );
        await tester.pumpAndSettle();

        // Scroll and click "查询今日空位"
        await tester.scrollUntilVisible(find.text('查询今日空位'), 200);
        await tester.tap(find.text('查询今日空位'));
        await tester.pumpAndSettle();

        // Verifies venues.venues and venues.calendar are now called
        final methods = mockBridge.campusCalls.map((c) => c['method']).toList();
        expect(methods, contains('venues.venues'));
        expect(methods, contains('venues.calendar'));

        // Verifies summary of available slots
        expect(find.textContaining('正大体育馆羽毛球场'), findsWidgets);
        expect(find.textContaining('2 个时段可约'), findsOneWidget);

        // Inline slot preview chips
        expect(find.textContaining('10:00-11:00 1号场地'), findsOneWidget);
        expect(find.textContaining('11:00-12:00 1号场地'), findsOneWidget);

        // Drill down into manual VenuePage
        await tester.tap(find.widgetWithText(FilledButton, '手动预约'));
        await tester.pumpAndSettle();

        expect(find.byType(VenuePage), findsOneWidget);
      },
    );

    testWidgets(
      '5. Venue snapshot handles authentication required with login recovery',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        mockBridge.throwOnVenues = true;
        mockBridge.throwCode = 'AuthenticationRequired';

        await tester.pumpWidget(
          buildTestApp(home: EHallPage(controller: controller)),
        );
        await tester.pumpAndSettle();

        // Trigger refresh
        await tester.scrollUntilVisible(find.text('查询今日空位'), 200);
        await tester.tap(find.text('查询今日空位'));
        await tester.pumpAndSettle();

        // Visibly indicates authentication needed
        expect(find.text('需要登录校园服务'), findsWidgets);
        expect(find.text('登录并刷新'), findsOneWidget);

        // Tap login and refresh
        await tester.tap(find.text('登录并刷新'));
        await tester.pumpAndSettle();

        // Verifies venues.visibleLogin was executed and slots are now displayed
        final methods = mockBridge.campusCalls.map((c) => c['method']).toList();
        expect(methods, contains('venues.visibleLogin'));
        expect(find.textContaining('2 个时段可约'), findsOneWidget);
      },
    );

    testWidgets(
      '5b. Mistyping or cancelling the login sheet keeps the login button on the home card',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        mockBridge.throwOnVenues = true;
        mockBridge.throwCode = 'AuthenticationRequired';

        await tester.pumpWidget(
          buildTestApp(home: EHallPage(controller: controller)),
        );
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.text('查询今日空位'), 200);
        await tester.tap(find.text('查询今日空位'));
        await tester.pumpAndSettle();

        mockBridge.throwOnMethod = 'venues.visibleLogin';
        mockBridge.throwCode = 'InvalidCredentials';
        await tester.tap(find.text('登录并刷新'));
        await tester.pumpAndSettle();
        expect(find.textContaining('账号或密码错误'), findsOneWidget);
        expect(find.text('登录并刷新'), findsOneWidget);

        mockBridge.throwCode = 'Cancelled';
        await tester.tap(find.text('登录并刷新'));
        await tester.pumpAndSettle();
        expect(find.text('需要登录校园服务'), findsOneWidget);
        expect(find.text('登录并刷新'), findsOneWidget);
        expect(find.textContaining('已取消'), findsNothing);

        mockBridge.throwOnMethod = null;
      },
    );

    test(
      'A rejected password is named rather than reported as a missing login',
      () {
        expect(
          campusError(PlatformException(code: 'InvalidCredentials')),
          contains('账号或密码错误'),
        );
        expect(
          campusError(PlatformException(code: 'AuthenticationRequired')),
          '需要登录校园服务',
        );
      },
    );

    testWidgets(
      '6. Standalone manual reservation works without scheduler; plugin adds scheduling only',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        // Without scheduler plugin
        mockBridge.plugins = [];
        await controller.initialize();

        await tester.pumpWidget(
          buildTestApp(home: EHallPage(controller: controller)),
        );
        await tester.pumpAndSettle();

        expect(find.text('可定时'), findsNothing);

        // With scheduler plugin enabled
        mockBridge.plugins = [
          {'id': 'org.danxi.sports_sniper', 'name': '场馆定时调度', 'enabled': true},
        ];
        await controller.initialize();

        await tester.pumpWidget(
          buildTestApp(home: EHallPage(controller: controller)),
        );
        await tester.pumpAndSettle();

        expect(find.text('可定时'), findsOneWidget);
      },
    );

    testWidgets(
      '7. Concise campus mail shell displays sandbox status and email address',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          buildTestApp(home: EHallPage(controller: controller)),
        );
        await tester.pumpAndSettle();

        await tester.scrollUntilVisible(find.text('校园邮箱'), 200);
        await tester.tap(find.text('校园邮箱'));
        await tester.pumpAndSettle();

        expect(find.text('邮箱暂未接入'), findsOneWidget);
        expect(find.text('收件箱'), findsNothing);
      },
    );

    testWidgets(
      '8. LifePage classrooms service queries building and displays free units',
      (tester) async {
        await tester.pumpWidget(
          buildTestApp(
            home: LifePage(service: LifeService.rooms, controller: controller),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(RoomDetailPage), findsOneWidget);

        // Classrooms auto-load on open for default building H3
        final roomsCall = mockBridge.campusCalls.lastWhere(
          (c) => c['method'] == 'fudan.rooms',
        );
        expect(roomsCall['params']['building'], 'H3');

        // H3101 with 80 seats and 3 free periods
        expect(find.text('H3101'), findsOneWidget);
        expect(find.text('80 座'), findsOneWidget);
        expect(find.text('3 节空闲'), findsOneWidget);
        expect(find.byTooltip('第1节: 空闲'), findsOneWidget);

        // H3102 with 120 seats and all occupied
        expect(find.text('H3102'), findsOneWidget);
        expect(find.text('120 座'), findsOneWidget);
        expect(find.text('全天占用'), findsOneWidget);
      },
    );

    testWidgets(
      '9. LifePage bus service supports weekday and holiday schedules',
      (tester) async {
        // Monday 07:00 AM reference date ensures weekday schedule is active on open
        await tester.pumpWidget(
          buildTestApp(
            home: LifePage(
              service: LifeService.bus,
              controller: controller,
              initialDate: DateTime(2026, 11, 2, 7, 0),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(BusDetailPage), findsOneWidget);
        expect(find.text('邯郸校区'), findsWidgets);
        expect(find.text('江湾校区'), findsWidgets);
        expect(find.text('07:30'), findsOneWidget);
        expect(find.text('08:10'), findsOneWidget);

        // Toggle to holiday schedule
        await tester.tap(find.text('节假日'));
        await tester.pumpAndSettle();

        final lastBusCall = mockBridge.campusCalls.lastWhere(
          (c) => c['method'] == 'fudan.bus',
        );
        expect(lastBusCall['params']['holiday'], isTrue);
        expect(find.text('09:00'), findsOneWidget);
        expect(find.text('09:40'), findsOneWidget);
      },
    );

    testWidgets(
      '10. LifePage GPA service maps student association, major, credits and ranking',
      (tester) async {
        await tester.pumpWidget(
          buildTestApp(
            home: LifePage(service: LifeService.gpa, controller: controller),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('绩点: 3.88'), findsOneWidget);
        expect(find.textContaining('计算机科学与技术'), findsOneWidget);
        expect(find.textContaining('已获 118.5 学分'), findsOneWidget);
        expect(find.textContaining('排名第 5 名'), findsOneWidget);
      },
    );

    testWidgets(
      '11. LifePage electricity service displays remaining power and room location',
      (tester) async {
        await tester.pumpWidget(
          buildTestApp(
            home: LifePage(service: LifeService.power, controller: controller),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(PowerDetailPage), findsOneWidget);
        expect(find.text('45.2'), findsOneWidget);
        expect(find.text('kWh'), findsWidgets);
        expect(find.textContaining('邯郸校区 东安一号楼 302室'), findsOneWidget);
        expect(find.textContaining('剩余：45.2 kWh；已用：120.5 kWh'), findsOneWidget);

        final powerCall = mockBridge.campusCalls.lastWhere(
          (c) => c['method'] == 'fudan.electricity',
        );
        expect(powerCall, isNotNull);
      },
    );

    testWidgets('12. LifePage visibly distinguishes no account state', (
      tester,
    ) async {
      mockBridge.activeAccount = null;
      controller = DanshengController(client: client);
      await controller.initialize();

      await tester.pumpWidget(
        buildTestApp(
          home: LifePage(service: LifeService.power, controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('未设置账号'), findsOneWidget);
      expect(find.text('设置账号'), findsOneWidget);
    });

    testWidgets(
      '13. Dark theme and large accessibility font render without clipping or overflow',
      (tester) async {
        await tester.pumpWidget(
          buildTestApp(
            home: EHallPage(controller: controller),
            mode: ThemeMode.dark,
            textScale: 1.8,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('校园办事'), findsOneWidget);
        expect(find.text('校园卡'), findsOneWidget);
        expect(find.text('场馆预约'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '14. Account switch drops stale in-flight results and resets cached state',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          buildTestApp(home: EHallPage(controller: controller)),
        );
        await tester.pumpAndSettle();

        expect(find.text('¥ 238.50'), findsOneWidget);

        // Switch to different account: verifies previous balance is immediately dropped
        mockBridge.balanceData = {'balance': '12.00'};
        await controller.switchAccount('21307130099');
        await tester.pumpAndSettle();

        // Old balance dropped, shows fresh pending state
        expect(find.text('¥ 238.50'), findsNothing);
        expect(find.text('查看明细'), findsOneWidget);

        // Now refresh balance for new account
        await controller.refreshBalance();
        await tester.pumpAndSettle();
        expect(find.text('¥ 12.00'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '14. Tapping classroom card passes building code and parameters to LifePage',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          buildTestApp(home: EHallPage(controller: controller)),
        );
        await tester.pumpAndSettle();

        // The first tap fetches in place; the next opens the period grid.
        await tester.tap(find.text('教室空位'));
        await tester.pumpAndSettle();
        expect(find.byType(LifePage), findsNothing);
        expect(
          mockBridge.campusCalls.where((c) => c['method'] == 'fudan.rooms'),
          hasLength(1),
        );
        await tester.tap(find.text('教室空位'));
        await tester.pumpAndSettle();

        // LifePage opened with classrooms loaded using the building parameter mapped to H3 code
        expect(find.byType(LifePage), findsOneWidget);
        expect(find.text('第三教学楼'), findsWidgets);
        expect(find.text('H3101'), findsOneWidget);

        final roomsCall = mockBridge.campusCalls.lastWhere(
          (c) => c['method'] == 'fudan.rooms',
        );
        expect(roomsCall['params']['building'], 'H3');
        expect(roomsCall['params']['date'], isNotNull);

        final cacheCall = mockBridge.campusCalls.firstWhere(
          (c) =>
              c['method'] == 'campus.cached' &&
              c['params']['method'] == 'fudan.rooms',
        );
        expect(cacheCall['params']['building'], 'H3');
      },
    );

    testWidgets(
      '15. LifePage maps building display names to DanXi building codes and handles chips/fallback',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          buildTestApp(
            home: LifePage(service: LifeService.rooms, controller: controller),
          ),
        );
        await tester.pumpAndSettle();

        // Tap chip for 第二教学楼 -> maps to H2
        await tester.tap(find.text('第二教学楼'));
        await tester.pumpAndSettle();

        var roomsCall = mockBridge.campusCalls.lastWhere(
          (c) => c['method'] == 'fudan.rooms',
        );
        expect(roomsCall['params']['building'], 'H2');

        // Tap chip for 光华楼西 -> maps to HGX
        await tester.tap(find.text('光华楼西'), warnIfMissed: false);
        await tester.pumpAndSettle();

        roomsCall = mockBridge.campusCalls.lastWhere(
          (c) => c['method'] == 'fudan.rooms',
        );
        expect(roomsCall['params']['building'], 'HGX');

        // Unknown arbitrary building name falls back safely to H3, never sending arbitrary text
        await tester.pumpWidget(
          buildTestApp(
            home: LifePage(
              key: const Key('unknown_building_page'),
              service: LifeService.rooms,
              controller: controller,
              initialBuilding: '未知教学楼ABC',
            ),
          ),
        );
        await tester.pumpAndSettle();

        roomsCall = mockBridge.campusCalls.lastWhere(
          (c) => c['method'] == 'fudan.rooms',
        );
        expect(roomsCall['params']['building'], 'H3');

        // Filter classroom input keeps matching room and filters out others
        expect(find.text('H3101'), findsOneWidget);
        expect(find.text('H3102'), findsOneWidget);
        await tester.enterText(find.byType(TextField), '3101');
        await tester.pumpAndSettle();
        expect(find.text('H3101'), findsOneWidget);
        expect(find.text('H3102'), findsNothing);
      },
    );

    testWidgets(
      '16. Mail shell displays actionable auth state when account is not bound',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        mockBridge.activeAccount = null;
        controller = DanshengController(client: client);
        await controller.initialize();

        await tester.pumpWidget(
          buildTestApp(home: EHallPage(controller: controller)),
        );
        await tester.pumpAndSettle();

        await tester.scrollUntilVisible(find.text('校园邮箱'), 200);
        await tester.tap(find.text('校园邮箱'));
        await tester.pumpAndSettle();

        expect(find.text('邮箱暂未接入'), findsOneWidget);
        expect(find.text('暂无邮件'), findsNothing);
      },
    );

    testWidgets(
      '17. LifePage notices toggle switches audience and links follow the selected segment',
      (tester) async {
        Map<String, dynamic> lastCall(String method) => mockBridge.campusCalls
            .lastWhere((c) => c['method'] == method)['params'];
        String lastOpened() => lastCall('campus.openNotice')['url'];

        await tester.pumpWidget(
          buildTestApp(
            home: LifePage(
              service: LifeService.notices,
              controller: controller,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // The toggle replaces both link buttons
        expect(find.text('本科教务公告'), findsNothing);
        expect(find.text('研究生院公告'), findsNothing);
        expect(find.byKey(const Key('notices_level_toggle')), findsOneWidget);
        expect(find.text('本科生'), findsOneWidget);
        expect(find.text('研究生'), findsOneWidget);

        // First load is undergraduate and sends no level
        expect(lastCall('fudan.notices'), isNot(contains('level')));
        expect(find.text(undergraduateNotice), findsOneWidget);
        expect(find.text(graduateNotice), findsNothing);

        await tester.tap(find.text(undergraduateNotice));
        await tester.pumpAndSettle();
        expect(Uri.parse(lastOpened()).host, 'jwc.fudan.edu.cn');

        await tester.tap(find.byTooltip('打开官网公告栏'));
        await tester.pumpAndSettle();
        expect(lastOpened(), 'https://jwc.fudan.edu.cn/9397/list.htm');

        // Tapping the selected segment must not reload
        final callsBefore = mockBridge.campusCalls.length;
        await tester.tap(find.text('本科生'));
        await tester.pumpAndSettle();
        expect(mockBridge.campusCalls, hasLength(callsBefore));

        await tester.tap(find.text('研究生'));
        await tester.pumpAndSettle();
        expect(lastCall('fudan.notices')['level'], 'graduate');
        expect(find.text(graduateNotice), findsOneWidget);
        expect(find.text(undergraduateNotice), findsNothing);

        await tester.tap(find.text(graduateNotice));
        await tester.pumpAndSettle();
        expect(Uri.parse(lastOpened()).host, 'gs.fudan.edu.cn');

        await tester.tap(find.byTooltip('打开官网公告栏'));
        await tester.pumpAndSettle();
        expect(lastOpened(), 'https://gs.fudan.edu.cn/tzgg/list.htm');

        // Switching back drops the level again
        await tester.tap(find.text('本科生'));
        await tester.pumpAndSettle();
        expect(lastCall('fudan.notices'), isNot(contains('level')));
        expect(find.text(undergraduateNotice), findsOneWidget);
        expect(find.text(graduateNotice), findsNothing);
      },
    );

    for (final failing in [false, true]) {
      testWidgets(
        '17b. A slow undergraduate notices ${failing ? 'failure' : 'response'} cannot replace the graduate list',
        (tester) async {
          final gate = Completer<void>();
          mockBridge.undergraduateNoticesGate = gate;

          await tester.pumpWidget(
            buildTestApp(
              home: LifePage(
                service: LifeService.notices,
                controller: controller,
              ),
            ),
          );
          await tester.pump();
          expect(find.byType(LinearProgressIndicator), findsOneWidget);

          await tester.tap(find.text('研究生'));
          await tester.pumpAndSettle();
          expect(find.text(graduateNotice), findsOneWidget);

          if (failing) {
            gate.completeError(
              PlatformException(code: 'SourceTransportUnavailable'),
            );
          } else {
            gate.complete();
          }
          await tester.pumpAndSettle();

          expect(find.text(graduateNotice), findsOneWidget);
          expect(find.text(undergraduateNotice), findsNothing);
          expect(find.text(cachedUndergraduateNotice), findsNothing);
          expect(find.textContaining('暂时无法连接服务'), findsNothing);
        },
      );
    }

    testWidgets('17c. Notices fallback reads the selected audience cache', (
      tester,
    ) async {
      Map<String, dynamic> lastCachedCall() => mockBridge.campusCalls.lastWhere(
        (c) => c['method'] == 'campus.cached',
      )['params'];

      mockBridge.throwOnMethod = 'fudan.notices';
      mockBridge.throwCode = 'SourceTransportUnavailable';

      await tester.pumpWidget(
        buildTestApp(
          home: LifePage(service: LifeService.notices, controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      expect(lastCachedCall(), {'method': 'fudan.notices'});
      expect(find.text(cachedUndergraduateNotice), findsOneWidget);

      await tester.tap(find.text('研究生'));
      await tester.pumpAndSettle();

      expect(lastCachedCall(), {
        'method': 'fudan.notices',
        'level': 'graduate',
      });
      expect(find.text(cachedGraduateNotice), findsOneWidget);
      expect(find.text(cachedUndergraduateNotice), findsNothing);
    });

    testWidgets(
      '18. LifePage dining 2FA error triggers verification dialog and error card button calls verifyDining without login loop',
      (tester) async {
        mockBridge.throwOnMethod = 'fudan.dining.occupancy';
        mockBridge.throwCode = 'InteractiveLoginRequired';

        await tester.pumpWidget(
          buildTestApp(
            home: LifePage(service: LifeService.dining, controller: controller),
          ),
        );
        await tester.pumpAndSettle();

        // 2FA dialog popped up on InteractiveLoginRequired
        expect(find.text('需要双因素认证'), findsOneWidget);
        expect(find.text('前往验证'), findsWidgets);

        // Tap "稍后" to dismiss dialog and inspect the error card
        await tester.tap(find.text('稍后'));
        await tester.pumpAndSettle();

        expect(find.text('需要双因素认证'), findsNothing);

        // Error card is displayed with "前往验证" button, preventing login loop
        expect(find.widgetWithText(FilledButton, '前往验证'), findsOneWidget);
        expect(find.text('登录并刷新'), findsNothing);

        // Clear mock throw so that after verifyDining, retry succeeds
        mockBridge.throwOnMethod = null;

        // Tap error card "前往验证" button
        await tester.tap(find.widgetWithText(FilledButton, '前往验证'));
        await tester.pumpAndSettle();

        // Verifies campus.verifyDining was invoked and campus.login was NEVER called
        final dining2FaCalls = mockBridge.campusCalls
            .where((c) => c['method'] == 'campus.verifyDining')
            .toList();
        expect(dining2FaCalls, hasLength(1));

        final loginCalls = mockBridge.campusCalls
            .where((c) => c['method'] == 'campus.login')
            .toList();
        expect(
          loginCalls,
          isEmpty,
          reason: 'Must not trigger campus.login loop for dining 2FA',
        );

        // Dining data now rendered successfully
        expect(find.text('光华餐厅一楼'), findsOneWidget);
        expect(find.textContaining('当前就餐 210 人'), findsOneWidget);
      },
    );

    testWidgets('18b. Dining 2FA entry names the current sign-in host', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildTestApp(
          home: LifePage(service: LifeService.dining, controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('校园双因素认证'), findsOneWidget);
      expect(find.text('id.fudan.edu.cn'), findsOneWidget);
      expect(find.text('my.fudan.edu.cn'), findsNothing);
    });

    group('19. Rooms card', () {
      void useTallView(WidgetTester tester, {double width = 800}) {
        tester.view.physicalSize = Size(width, 1400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
      }

      int roomQueries() => mockBridge.campusCalls
          .where((c) => c['method'] == 'fudan.rooms')
          .length;

      Finder cardOf(String title) =>
          find.ancestor(of: find.text(title), matching: find.byType(InkWell));

      // Measured per card: the venue card's button row overflows at these
      // widths on its own, so a page-wide exception check would blame this card.
      void expectCardFits(WidgetTester tester, String title) {
        final flexes = find.descendant(
          of: cardOf(title),
          matching: find.byWidgetPredicate((w) => w is Flex),
        );
        expect(flexes, findsWidgets);
        for (final flex in tester.renderObjectList<RenderFlex>(flexes)) {
          final horizontal = flex.direction == Axis.horizontal;
          var used = 0.0;
          flex.visitChildren((child) {
            final size = (child as RenderBox).size;
            used += horizontal ? size.width : size.height;
          });
          expect(
            used,
            lessThanOrEqualTo(
              (horizontal ? flex.size.width : flex.size.height) + 0.01,
            ),
            reason: '$title card overflows',
          );
        }
      }

      testWidgets('shows no description before any query', (tester) async {
        useTallView(tester);
        mockBridge.hasCachedRooms = false;

        await tester.pumpWidget(
          buildTestApp(home: EHallPage(controller: controller)),
        );
        await tester.pumpAndSettle();

        expect(find.text('查空位节次'), findsOneWidget);
        expect(find.text('教学楼实时座位'), findsNothing);
      });

      testWidgets('shows no description over a cached room', (tester) async {
        useTallView(tester);

        await tester.pumpWidget(
          buildTestApp(home: EHallPage(controller: controller)),
        );
        await tester.pumpAndSettle();

        expect(find.text('1 间教室'), findsOneWidget);
        expect(find.text('空闲 3 节次'), findsNothing);
        expect(find.text('教学楼座位'), findsNothing);
      });

      testWidgets('keeps the metric but no description after a query', (
        tester,
      ) async {
        useTallView(tester);

        await tester.pumpWidget(
          buildTestApp(home: EHallPage(controller: controller)),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('教室空位'));
        await tester.pumpAndSettle();

        expect(find.text('2 间教室'), findsOneWidget);
        expect(find.textContaining('查看节次'), findsNothing);
        expect(find.textContaining('第三教学楼'), findsNothing);
      });

      testWidgets('shows the reason when the query fails until a retry works', (
        tester,
      ) async {
        useTallView(tester);
        const reason = '暂时无法连接服务，请检查校园网络后刷新。';
        mockBridge.throwOnMethod = 'fudan.rooms';
        mockBridge.throwCode = 'SourceTransportUnavailable';

        await tester.pumpWidget(
          buildTestApp(home: EHallPage(controller: controller)),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('教室空位'));
        await tester.pumpAndSettle();

        expect(find.text('点击重试'), findsOneWidget);
        expect(find.text(reason), findsOneWidget);
        expect(find.byType(LifePage), findsNothing);

        mockBridge.throwOnMethod = null;
        await tester.tap(find.text('教室空位'));
        await tester.pumpAndSettle();

        expect(find.text('2 间教室'), findsOneWidget);
        expect(find.text('点击重试'), findsNothing);
        expect(find.text(reason), findsNothing);
      });

      testWidgets('matches the power card height and is tappable to its edge', (
        tester,
      ) async {
        useTallView(tester);

        await tester.pumpWidget(
          buildTestApp(home: EHallPage(controller: controller)),
        );
        await tester.pumpAndSettle();

        final rooms = tester.getRect(cardOf('教室空位'));
        final power = tester.getRect(cardOf('寝室电量'));
        expect(rooms.top, power.top);
        expect(rooms.height, power.height);
        expect(rooms.width, power.width);
        expect(power.left - rooms.right, 12);

        // Below the rooms text, where only the stretched card can take the tap
        await tester.tapAt(Offset(rooms.center.dx, rooms.bottom - 4));
        await tester.pumpAndSettle();
        expect(roomQueries(), 1);
      });

      testWidgets('stacks at full width below 280 of available width', (
        tester,
      ) async {
        // 300 wide minus the page's 20 gutters leaves 260.
        useTallView(tester, width: 300);

        await tester.pumpWidget(
          buildTestApp(home: EHallPage(controller: controller)),
        );
        await tester.pumpAndSettle();

        final rooms = tester.getRect(cardOf('教室空位'));
        final power = tester.getRect(cardOf('寝室电量'));
        expect(rooms.width, 260);
        expect(power.width, 260);
        expect(power.top - rooms.bottom, 12);
        expectCardFits(tester, '教室空位');
        expectCardFits(tester, '寝室电量');

        await tester.tapAt(Offset(rooms.center.dx, rooms.bottom - 4));
        await tester.pumpAndSettle();
        expect(roomQueries(), 1);
        tester.takeException(); // The venue card's row, see expectCardFits.
      });

      // 320 leaves exactly 280 of width, the narrowest side-by-side layout.
      for (final width in [320.0, 800.0]) {
        testWidgets(
          'fits at ${width.toInt()} wide with 1.8x font, also on error',
          (tester) async {
            useTallView(tester, width: width);
            mockBridge.throwOnMethod = 'fudan.rooms';
            mockBridge.throwCode = 'SourceTransportUnavailable';

            await tester.pumpWidget(
              buildTestApp(
                home: EHallPage(controller: controller),
                textScale: 1.8,
              ),
            );
            await tester.pumpAndSettle();

            void expectPairFits() {
              final rooms = tester.getRect(cardOf('教室空位'));
              final power = tester.getRect(cardOf('寝室电量'));
              expect(rooms.height, power.height);
              expect(rooms.top, power.top);
              expectCardFits(tester, '教室空位');
              expectCardFits(tester, '寝室电量');
            }

            expectPairFits();

            await tester.tap(find.text('教室空位'));
            await tester.pumpAndSettle();
            expect(find.textContaining('暂时无法连接服务'), findsOneWidget);
            expectPairFits();
            tester.takeException(); // The venue card's row, see expectCardFits.
          },
        );
      }
    });
  });
}

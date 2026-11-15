// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:dansheng_app/ui/campus/ehall/board/board_layout.dart';
import 'package:dansheng_app/ui/campus/ehall/board/tile_data.dart';
import 'package:dansheng_app/ui/campus/ehall/life_page.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A campus wall-clock time as the instant it is.
DateTime campus(int y, int m, int d, [int h = 0, int min = 0]) =>
    DateTime.utc(y, m, d, h, min).subtract(const Duration(hours: 8));

Map<String, dynamic> batch(List<Map<String, dynamic>> rows, {String? at}) => {
  'source': {'observed_at': ?at},
  'records': [
    for (final row in rows) {'payload': row},
  ],
  'coverage': {'state': 'complete'},
};

void main() {
  group('campus clock', () {
    test('days and periods follow Shanghai time, not the device', () {
      // 23:30 UTC on Nov 13 is already Nov 14 on campus.
      expect(campusDay(DateTime.utc(2026, 11, 13, 23, 30)), '2026-11-14');
      expect(referencePeriod(campus(2026, 11, 14, 7, 10)), 1);
      expect(referencePeriod(campus(2026, 11, 14, 8, 20)), 1);
      // In the break after period 2 the next period is the one to show.
      expect(referencePeriod(campus(2026, 11, 14, 9, 45)), 3);
      expect(referencePeriod(campus(2026, 11, 14, 21, 4)), 13);
      expect(referencePeriod(campus(2026, 11, 14, 21, 5)), isNull);
    });

    test('ages read naturally', () {
      final now = campus(2026, 11, 14, 12, 0);
      expect(readAge(now.subtract(const Duration(seconds: 20)), now), '刚刚');
      expect(readAge(now.subtract(const Duration(minutes: 5)), now), '5 分钟前');
      expect(readAge(campus(2026, 11, 14, 8, 5), now), '08:05');
      expect(readAge(campus(2026, 11, 13, 22, 40), now), '昨天 22:40');
      expect(readAge(campus(2026, 11, 2, 9), now), '11-2');
    });

    test('numbers drop needless decimals', () {
      expect(plainNumber(42.0), '42');
      expect(plainNumber(3.5), '3.5');
      expect(plainNumber(45.25), '45.25');
      expect(plainNumber(-1.204), '-1.2');
      expect(yuan(1850), '18.50');
    });
  });

  group('what counts as data', () {
    test('test hosts and misses are not data', () {
      for (final junk in [
        null,
        <String, dynamic>{},
        {'result': 'ok'},
        'x',
      ]) {
        expect(libraryTile(junk), isNull);
        expect(
          busTile(
            junk,
            Campus.HANDAN_CAMPUS,
            Campus.JIANGWAN_CAMPUS,
            campus(2026, 11, 14, 8),
          ),
          isNull,
        );
        expect(powerTile(junk), isNull);
        expect(ecardTile(junk), isNull);
      }
    });

    test('an empty but real result says so instead of looking missing', () {
      final facts = libraryTile(batch([]))!.facts;
      expect(facts.note, '暂无在馆数据');
      expect(facts.value, isNull);
    });
  });

  test('power shows the remaining energy, place and the stored trend', () {
    final data = powerTile(
      {
        'observed_at': '2026-11-14T01:00:00Z',
        'payload': {
          'campus': '邯郸校区',
          'building': '东区1号楼',
          'room': '302',
          'remaining_kwh': 42.0,
          'used_kwh': 120.5,
          'updated_at': '2026-11-14T00:30:00Z',
        },
      },
      {
        'payload': {
          'buckets': [
            for (var d = 1; d <= 9; d++)
              {'start': '2026-11-0$d', 'amount_kwh': '$d.5'},
          ],
        },
      },
    )!;
    expect(data.facts.value, '42');
    expect(data.facts.unit, 'kWh');
    expect(data.facts.note, '邯郸校区 东区1号楼 302');
    expect(data.facts.rows.first.value, '120.5 kWh');
    // The meter time is shown on campus time.
    expect(data.facts.rows[1].value, '11-14 08:30');
    expect(
      [for (final b in data.facts.bars) b.label],
      [
        '11/3', '11/4', '11/5', '11/6', '11/7', '11/8', '11/9', //
      ],
    );
    expect(data.observedAt, DateTime.utc(2026, 11, 14, 1));
    final empty = powerTile({
      'payload': {'remaining_kwh': -3},
    })!;
    expect(empty.facts.note, '已用完，请及时充值');
  });

  test('card spending comes from Core statistics, labelled as spending', () {
    final data = ecardTile({
      'observed_at': '2026-11-14T02:00:00Z',
      'payload': {
        'complete': true,
        'from': '2026-11-01',
        'to': '2026-11-30',
        'record_count': 26,
        'expense_cents': 38550,
        'unclassified_count': 1,
        'by_location': [
          {'name': '旦苑餐厅', 'expense_cents': 21000},
          {'name': '', 'expense_cents': 150},
        ],
      },
    })!;
    expect(data.facts.value, '¥385.50');
    expect(data.facts.unit, '本月支出');
    expect(data.facts.note, '本月共 26 笔记录');
    expect(
      [for (final r in data.facts.rows) '${r.label} ${r.value}'],
      ['旦苑餐厅 ¥210.00', '未标注 ¥1.50', '待分类 1 笔未计入'],
    );
  });

  group('rooms', () {
    Map<String, dynamic> rooms() => batch([
      {
        'room': 'H3101',
        'seats': 80,
        'busy_units': [for (var i = 0; i < 13; i++) i == 0 || i >= 5],
      },
      {
        'room': 'H3102',
        'seats': 120,
        'busy_units': [for (var i = 0; i < 13; i++) i >= 3],
      },
      {'room': 'H3103', 'seats': 60, 'busy_units': List.filled(13, true)},
    ]);

    test('counts rooms free in the current period, longest stay first', () {
      final facts = roomsTile(rooms(), 'H3', campus(2026, 11, 14, 9, 0))!.facts;
      expect(facts.value, '2');
      expect(facts.unit, '间空闲');
      expect(facts.note, '第三教学楼 · 第2节');
      expect(
        [for (final r in facts.rows) '${r.label} ${r.value}'],
        ['H3101 空到第5节', 'H3102 空到第3节'],
      );
      expect(facts.bars.length, 13);
      expect(facts.bars[1].marked, isTrue);
    });

    test('before a period starts it says when; after the day it says so', () {
      final early = roomsTile(rooms(), 'H3', campus(2026, 11, 14, 7))!.facts;
      expect(early.note, '第三教学楼 · 第1节 08:00 起');
      final late = roomsTile(rooms(), 'H3', campus(2026, 11, 14, 22))!.facts;
      expect(late.value, isNull);
      expect(late.note, '第三教学楼 · 今日课程已结束');
    });
  });

  group('bus', () {
    final raw = batch([
      {
        'from': '邯郸校区',
        'to': '江湾校区',
        'starts_at': '07:30:00',
        'direction': 'forward',
      },
      {
        'from': '邯郸校区',
        'to': '江湾校区',
        'starts_at': '09:00:00',
        'direction': 'forward',
      },
      {
        'from': '邯郸校区',
        'to': '江湾校区',
        'starts_at': '10:00:00',
        'ends_at': '11:00:00',
        'direction': 'both',
      },
      {
        'from': '江湾校区',
        'to': '邯郸校区',
        'starts_at': '08:15:00',
        'direction': 'forward',
      },
    ]);

    test('the next departure and how long until it', () {
      final facts = busTile(
        raw,
        Campus.HANDAN_CAMPUS,
        Campus.JIANGWAN_CAMPUS,
        campus(2026, 11, 14, 8, 20),
      )!.facts;
      expect(facts.value, '09:00');
      expect(facts.note, '邯郸 → 江湾 · 40 分钟后');
      expect(
        [for (final r in facts.rows) '${r.label} ${r.value}'],
        [
          '邯郸 → 江湾 10:00',
          // A two-way row's return leg leaves at its end time.
          '江湾 → 邯郸 11:00',
        ],
      );
    });

    test('marks the last bus and the end of the day', () {
      final last = busTile(
        raw,
        Campus.HANDAN_CAMPUS,
        Campus.JIANGWAN_CAMPUS,
        campus(2026, 11, 14, 9, 30),
      )!.facts;
      expect(last.note, '邯郸 → 江湾 · 30 分钟后 · 末班');
      final done = busTile(
        raw,
        Campus.HANDAN_CAMPUS,
        Campus.JIANGWAN_CAMPUS,
        campus(2026, 11, 14, 10, 30),
      )!.facts;
      expect(done.value, isNull);
      expect(done.note, '邯郸 → 江湾 · 今日已无班次');
      final none = busTile(
        raw,
        Campus.ZHANGJIANG_CAMPUS,
        Campus.FENGLIN_CAMPUS,
        campus(2026, 11, 14, 8),
      )!.facts;
      expect(none.note, contains('无直达班次'));
    });

    test('weekends read the holiday timetable; routes come from options', () {
      expect(busHoliday(campus(2026, 11, 14, 12)), isTrue); // Saturday
      expect(busHoliday(campus(2026, 11, 16, 12)), isFalse);
      expect(busRoute(const {}), (
        Campus.HANDAN_CAMPUS,
        Campus.JIANGWAN_CAMPUS,
      ));
      expect(
        busRoute(const {'from': 'FENGLIN_CAMPUS', 'to': 'FENGLIN_CAMPUS'}),
        (Campus.FENGLIN_CAMPUS, Campus.HANDAN_CAMPUS),
      );
      expect(busRoute(const {'from': 'nowhere'}).$1, Campus.HANDAN_CAMPUS);
    });
  });

  test('dining shows how full the chosen area is, quietest hall first', () {
    final facts = diningTile(
      batch([
        {'name': '旦苑一楼', 'current': 300, 'capacity': 400},
        {'name': '光华二楼', 'current': 50, 'capacity': 200},
      ]),
      1,
    )!.facts;
    expect(facts.value, '58');
    expect(facts.unit, '%');
    expect(facts.note, '南区食堂 · 350/600 人');
    expect(facts.rows.first.label, '光华二楼');
    expect(facts.rows.first.level, 0.25);
    expect(diningArea(const {'area': 9}), 0);
    expect(diningArea(const {'area': 3}), 3);
  });

  test('exams count down on the campus calendar and skip past ones', () {
    final facts = examsTile(
      batch([
        {'course_name': '已考', 'on': '2026-11-10', 'time_range': '08:30~10:30'},
        {
          'course_name': '线性代数',
          'on': '2026-11-20',
          'time_range': '13:00~15:00',
          'room': 'H3101',
        },
        {
          'course_name': '高等数学',
          'on': '2026-11-20',
          'time_range': '08:30~10:30',
        },
        {'course_name': '结课', 'on': '2026-12-01', 'finished': true},
      ]),
      campus(2026, 11, 14, 23, 50),
    )!.facts;
    expect(facts.value, '6');
    expect(facts.unit, '天后');
    expect(facts.note, '高等数学 · 08:30');
    expect(facts.rows.first.label, '线性代数');
    final tomorrow = examsTile(
      batch([
        {'course_name': '英语', 'on': '2026-11-15'},
      ]),
      campus(2026, 11, 14, 9),
    )!.facts;
    expect(tomorrow.value, '明天');
    expect(tomorrow.unit, isNull);
  });

  test('GPA shows only the person own row', () {
    final cohort = batch([
      {'student_code': '21300000001', 'gpa': 3.9, 'name': '别人'},
      {
        'student_code': '21307130001',
        'gpa': 3.5,
        'credits': 98.0,
        'ranking': 12,
      },
    ]);
    final mine = gpaTile(cohort, '21307130001')!.facts;
    expect(mine.value, '3.50');
    expect(mine.note, '已获 98 学分');
    expect(mine.spoken, isNot(contains('别人')));
    // Without the person's own row the tile shows no one's figure.
    expect(gpaTile(cohort, 'someone-else')!.facts.value, isNull);
  });

  group('reading a tile', () {
    test(
      'the academic chain resolves from stored prerequisites once',
      () async {
        final asked = <String>[];
        final source = TileSource.cached((method, params) async {
          final source = params['method'];
          asked.add('$source');
          return switch (source) {
            'fudan.semesters' => {
              'semesters': [
                {'external_id': '502', 'name': '2026秋'},
              ],
              'default_semester_id': '502',
            },
            'fudan.student_association' => {'payload': '9988'},
            'fudan.grades' => batch([
              {'course_name': '数学', 'letter_grade': 'A'},
              {'course_name': '物理'},
            ]),
            'fudan.exams' => batch([]),
            _ => null,
          };
        });
        final now = campus(2026, 11, 14, 9);
        final grades = await readTile(
          const TileSlot(EHallTile.grades, size: TileSize.medium),
          source,
          now: now,
        );
        final exams = await readTile(
          const TileSlot(EHallTile.exams, size: TileSize.small),
          source,
          now: now,
        );
        expect(grades!.facts.value, '1');
        expect(grades.facts.note, '2026秋');
        expect(exams!.facts.note, '暂无待考科目');
        expect(asked.where((m) => m == 'fudan.semesters').length, 1);
        expect(asked.where((m) => m == 'fudan.student_association').length, 1);
      },
    );

    test('cache lookups use the exact keys the detail pages write', () async {
      final asked = <Map<String, dynamic>>[];
      final source = TileSource.cached((method, params) async {
        asked.add(params);
        return null;
      });
      final now = campus(2026, 11, 14, 9);
      for (final slot in const [
        TileSlot(EHallTile.dining, size: TileSize.small),
        TileSlot(EHallTile.notices, size: TileSize.small),
        TileSlot(
          EHallTile.notices,
          size: TileSize.small,
          options: {'graduate': true},
        ),
        TileSlot(
          EHallTile.rooms,
          size: TileSize.small,
          options: {'building': 'HGX'},
        ),
        TileSlot(EHallTile.bus, size: TileSize.small),
        TileSlot(EHallTile.ecard, size: TileSize.small),
      ]) {
        await readTile(slot, source, now: now);
      }
      expect(asked, [
        {'method': 'fudan.dining.occupancy', 'area_code': 0},
        {'method': 'fudan.notices'},
        {'method': 'fudan.notices', 'level': 'graduate'},
        {'method': 'fudan.rooms', 'building': 'HGX', 'date': '2026-11-14'},
        {'method': 'fudan.bus', 'holiday': true},
        {
          'method': 'fudan.ecard.statistics',
          'period': 'month',
          'date': '2026-11-14',
        },
        {
          'method': 'fudan.ecard.statistics',
          'period': 'month',
          'date': '2026-11-01',
        },
      ]);
    });

    test(
      'a failing cache is just no data; a failing live read is a problem',
      () async {
        final now = campus(2026, 11, 14, 9);
        const slot = TileSlot(EHallTile.library, size: TileSize.small);
        Future<dynamic> fail(String m, Map<String, dynamic> p) async =>
            throw PlatformException(code: 'AuthenticationRequired');
        expect(await readTile(slot, TileSource.cached(fail), now: now), isNull);
        await expectLater(
          readTile(slot, TileSource.live(fail), now: now),
          throwsA(isA<PlatformException>()),
        );
        expect(tileProblem(PlatformException(code: 'AuthenticationRequired')), (
          '需要登录',
          true,
        ));
        expect(
          tileProblem(PlatformException(code: 'InteractiveLoginRequired')),
          ('需要验证', true),
        );
        expect(tileProblem(PlatformException(code: 'DeadlineExceeded')), (
          '网络不可用',
          false,
        ));
        expect(tileProblem(Exception('x')), ('刷新失败', false));
      },
    );

    test('icons, venues and mail never read', () {
      for (final tile in EHallTile.values) {
        expect(tileReads(tile, TileSize.icon), isFalse);
      }
      expect(tileReads(EHallTile.venues, TileSize.large), isFalse);
      expect(tileReads(EHallTile.mail, TileSize.wide), isFalse);
      expect(tileReads(EHallTile.bus, TileSize.small), isTrue);
    });
  });
}

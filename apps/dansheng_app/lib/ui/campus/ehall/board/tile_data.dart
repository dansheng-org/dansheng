import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../learning/models/timetable_models.dart';
import '../campus_building.dart';
import '../department_notices/department_directory.dart';
import '../department_notices/department_notice_service.dart';
import '../life_page.dart';
import 'board_layout.dart';
import 'tile_facts.dart';

/// Facts derived from one read, with the time the service was asked.
@immutable
class TileData {
  const TileData(this.facts, {this.observedAt});
  final TileFacts facts;

  /// When Core read the source, or null when the result does not say.
  final DateTime? observedAt;
}

/// Reads campus results for tiles. The same derivations serve the local
/// cache, which the home reads when it opens, and live reads, which only an
/// explicit refresh makes. A pass reuses each identical read, so tiles that
/// share a prerequisite (the academic ones) ask for it once.
class TileSource {
  TileSource._(this._read, this.live);

  /// Reads what earlier live reads stored on this device. Never touches the
  /// network; a miss or any failure reads as "no data".
  factory TileSource.cached(
    Future<dynamic> Function(String, Map<String, dynamic>) call,
  ) => TileSource._((method, params) async {
    try {
      return await call('campus.cached', {'method': method, ...params});
    } catch (_) {
      return null;
    }
  }, false);

  /// Asks the services themselves. Failures propagate.
  factory TileSource.live(
    Future<dynamic> Function(String, Map<String, dynamic>) call,
  ) => TileSource._(call, true);

  final Future<dynamic> Function(String, Map<String, dynamic>) _read;
  final bool live;
  final _seen = <String, Future<dynamic>>{};

  Future<dynamic> read(
    String method, [
    Map<String, dynamic> params = const {},
  ]) => _seen.putIfAbsent(
    '$method ${jsonEncode(params)}',
    () => _read(method, params),
  );
}

/// Whether [tile] at [size] shows anything read from its service.
bool tileReads(EHallTile tile, TileSize size) =>
    size != TileSize.icon && tile != EHallTile.venues && tile != EHallTile.mail;

/// How long a reading stays current before the tile dims it.
Duration staleAfter(EHallTile tile) => switch (tile) {
  EHallTile.library || EHallTile.dining => const Duration(minutes: 30),
  EHallTile.rooms => const Duration(hours: 6),
  EHallTile.ecard || EHallTile.power => const Duration(hours: 12),
  EHallTile.notices || EHallTile.departmentNotices => const Duration(days: 3),
  _ => const Duration(days: 7),
};

/// Reads [slot]'s service and derives its facts. Returns null when the
/// service has nothing for this tile yet. With a live [source] read
/// failures are thrown.
Future<TileData?> readTile(
  TileSlot slot,
  TileSource source, {
  required DateTime now,
  String? account,
}) async {
  final options = slot.options;
  switch (slot.tile) {
    case EHallTile.ecard:
      return ecardTile(await _ecardStatistics(source, now));
    case EHallTile.power:
      final balance = await source.read('fudan.electricity');
      if (!hasRecord(balance)) return null;
      dynamic usage;
      if (slot.size == TileSize.large && !source.live) {
        // The trend needs the portal's second factor; only the detail page
        // asks for it, so the board only shows what that page stored.
        usage = await source.read('fudan.electricity.statistics', {
          'period': 'day',
        });
      }
      return powerTile(balance, usage);
    case EHallTile.rooms:
      final building = CampusBuildings.toCode(options['building'] as String?);
      final raw = await source.read('fudan.rooms', {
        'building': building,
        'date': campusDay(now),
      });
      return roomsTile(raw, building, now);
    case EHallTile.library:
      return libraryTile(await source.read('fudan.library.occupancy'));
    case EHallTile.dining:
      final area = diningArea(options);
      return diningTile(
        await source.read('fudan.dining.occupancy', {'area_code': area}),
        area,
      );
    case EHallTile.bus:
      final (from, to) = busRoute(options);
      final raw = await source.read('fudan.bus', {'holiday': busHoliday(now)});
      return busTile(raw, from, to, now);
    case EHallTile.notices:
      final graduate = options['graduate'] == true;
      return noticesTile(
        await source.read('fudan.notices', {if (graduate) 'level': 'graduate'}),
      );
    case EHallTile.departmentNotices:
      final depts = DepartmentDirectory.parseSubscribed(
        options['departments'] as String?,
      );
      return DepartmentNoticeService.instance.getTileData(
        depts,
        live: source.live,
      );
    case EHallTile.grades:
    case EHallTile.gpa:
    case EHallTile.exams:
      final term = await _academicTerm(source);
      if (term == null) return null;
      final raw = await source.read(
        switch (slot.tile) {
          EHallTile.grades => 'fudan.grades',
          EHallTile.gpa => 'fudan.gpa',
          _ => 'fudan.exams',
        },
        {'student_association': term.association, 'semester_id': term.id},
      );
      return switch (slot.tile) {
        EHallTile.grades => gradesTile(raw, term.name),
        EHallTile.gpa => gpaTile(raw, account),
        _ => examsTile(raw, now),
      };
    case EHallTile.venues:
    case EHallTile.mail:
      return null;
  }
}

/// A short status for a failed live read, and whether the person has to act.
(String, bool) tileProblem(Object error) {
  final code = error is PlatformException ? error.code : error.toString();
  bool any(List<String> keys) => keys.any(code.contains);
  if (any(['InteractiveLoginRequired'])) return ('需要验证', true);
  if (any([
    'AuthenticationRequired',
    'InvalidCredentials',
    'NotLoginError',
    'postgraduates_need_login',
  ])) {
    return ('需要登录', true);
  }
  if (any(['AccountRequired', 'AccountChanged', 'AccountMismatch'])) {
    return ('未设置账号', true);
  }
  if (any(['Network', 'Transport', 'Timeout', 'Deadline'])) {
    return ('网络不可用', false);
  }
  return ('刷新失败', false);
}

// ---------------------------------------------------------------------------
// Shared helpers.

/// Shanghai wall clock for [now]; read only its fields.
DateTime campusClock(DateTime now) => now.toUtc().add(const Duration(hours: 8));

String _two(int v) => v.toString().padLeft(2, '0');

/// The campus calendar day of [now] as 'YYYY-MM-DD'.
String campusDay(DateTime now) {
  final c = campusClock(now);
  return '${c.year.toString().padLeft(4, '0')}-${_two(c.month)}-${_two(c.day)}';
}

bool hasBatch(dynamic raw) =>
    raw is List || (raw is Map && raw['records'] is List);

bool hasRecord(dynamic raw) => raw is Map && raw['payload'] is Map;

/// Payloads of a batch, or of the bare rows some test hosts return.
List<Map> payloads(dynamic raw) {
  final list = raw is Map ? raw['records'] : raw;
  if (list is! List) return const [];
  return [
    for (final row in list)
      if (row is Map) row['payload'] is Map ? row['payload'] as Map : row,
  ];
}

/// When Core read the source, from a batch or a single record.
DateTime? observedAt(dynamic raw) {
  if (raw is! Map) return null;
  final source = raw['source'];
  final stamp = source is Map ? source['observed_at'] : raw['observed_at'];
  return stamp is String ? DateTime.tryParse(stamp)?.toUtc() : null;
}

num? _number(dynamic v) => v is num
    ? (v.isFinite ? v : null)
    : v is String
    ? num.tryParse(v.trim())
    : null;

String _text(dynamic v) => v is String ? v.trim() : '';

/// A number without trailing zeros: 42.0 as '42', 3.50 as '3.5'.
String plainNumber(num v, {int digits = 2}) {
  if (v is int || v == v.roundToDouble()) return v.round().toString();
  var s = v.toStringAsFixed(digits);
  while (s.endsWith('0')) {
    s = s.substring(0, s.length - 1);
  }
  return s.endsWith('.') ? s.substring(0, s.length - 1) : s;
}

String yuan(num cents) => (cents / 100).toStringAsFixed(2);

/// 'MM-DD' from a 'YYYY-MM-DD' calendar date, or null.
String? shortDate(dynamic raw) {
  final s = _text(raw);
  final m = RegExp(r'^\d{4}-(\d{2})-(\d{2})').firstMatch(s);
  return m == null ? null : '${m[1]}-${m[2]}';
}

DateTime? _calendarDate(dynamic raw) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(_text(raw));
  if (m == null) return null;
  return DateTime.utc(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
}

/// How long ago [at] was, the way a glance wants it.
String readAge(DateTime at, DateTime now) {
  final minutes = now.toUtc().difference(at.toUtc()).inMinutes;
  if (minutes < 1) return '刚刚';
  if (minutes < 60) return '$minutes 分钟前';
  final then = campusClock(at), today = campusClock(now);
  final days = DateTime.utc(
    today.year,
    today.month,
    today.day,
  ).difference(DateTime.utc(then.year, then.month, then.day)).inDays;
  final time = '${_two(then.hour)}:${_two(then.minute)}';
  if (days <= 0) return time;
  if (days == 1) return '昨天 $time';
  return '${then.month}-${then.day}';
}

// ---------------------------------------------------------------------------
// 校园卡: the period spending Core computed; the detail page owns the rest.

Future<dynamic> _ecardStatistics(TileSource source, DateTime now) async {
  final day = campusDay(now);
  if (source.live) {
    return source.read('fudan.ecard.statistics', {
      'period': 'month',
      'date': day,
    });
  }
  // The statistics page stores the month under the day it was opened on,
  // or under the first of the month when picked from the calendar.
  dynamic best;
  DateTime? bestAt;
  for (final date in {day, '${day.substring(0, 8)}01'}) {
    final raw = await source.read('fudan.ecard.statistics', {
      'period': 'month',
      'date': date,
    });
    if (!_currentMonth(raw, day)) continue;
    final at = observedAt(raw);
    if (best == null ||
        (at != null && (bestAt == null || at.isAfter(bestAt)))) {
      best = raw;
      bestAt = at;
    }
  }
  return best;
}

bool _currentMonth(dynamic raw, String day) {
  if (!hasRecord(raw)) return false;
  final p = raw['payload'] as Map;
  return p['complete'] == true &&
      _number(p['expense_cents']) != null &&
      _text(p['from']).compareTo(day) <= 0 &&
      day.compareTo(_text(p['to'])) <= 0;
}

TileData? ecardTile(dynamic raw) {
  if (!hasRecord(raw)) return null;
  final p = raw['payload'] as Map;
  final expense = _number(p['expense_cents']);
  if (expense == null) return null;
  final count = _number(p['record_count']);
  final unclassified = _number(p['unclassified_count']) ?? 0;
  final places = (p['by_location'] is List ? p['by_location'] as List : [])
      .whereType<Map>()
      .where((row) => _number(row['expense_cents']) != null);
  return TileData(
    TileFacts(
      value: '¥${yuan(expense)}',
      unit: '本月支出',
      note: count == null ? '本月支出' : '本月共 ${count.round()} 笔记录',
      rows: [
        for (final row in places)
          TileFact(
            _text(row['name']).isEmpty ? '未标注' : _text(row['name']),
            value: '¥${yuan(_number(row['expense_cents'])!)}',
          ),
        if (unclassified > 0)
          TileFact('待分类', value: '${unclassified.round()} 笔未计入'),
      ],
    ),
    observedAt: observedAt(raw),
  );
}

// ---------------------------------------------------------------------------
// 寝室电量.

TileData? powerTile(dynamic balance, [dynamic usage]) {
  if (!hasRecord(balance)) return null;
  final p = balance['payload'] as Map;
  final remaining = _number(p['remaining_kwh']);
  if (remaining == null) return null;
  final used = _number(p['used_kwh']);
  final place = [
    p['campus'],
    p['building'],
    p['room'],
  ].map(_text).where((s) => s.isNotEmpty).join(' ');
  final meter = DateTime.tryParse(_text(p['updated_at']));
  final bars = <TileBar>[];
  var caption = '';
  if (hasRecord(usage) && usage['payload']['buckets'] is List) {
    final buckets = (usage['payload']['buckets'] as List).whereType<Map>();
    final recent = buckets.toList().reversed.take(7).toList().reversed;
    for (final bucket in recent) {
      final kwh = _number(bucket['amount_kwh']);
      final day = _calendarDate(bucket['start']);
      if (kwh == null || kwh < 0 || day == null) {
        bars.clear();
        break;
      }
      bars.add(TileBar('${day.month}/${day.day}', kwh.toDouble()));
    }
    if (bars.isNotEmpty) {
      caption = '近 ${bars.length} 日用电 · 最新 ${plainNumber(bars.last.value)} kWh';
    }
  }
  return TileData(
    TileFacts(
      value: plainNumber(remaining),
      unit: 'kWh',
      note: remaining <= 0
          ? '已用完，请及时充值'
          : place.isEmpty
          ? '剩余电量'
          : place,
      rows: [
        if (used != null) TileFact('已用电量', value: '${plainNumber(used)} kWh'),
        if (meter != null)
          TileFact(
            '表计更新',
            value: () {
              final c = campusClock(meter);
              return '${_two(c.month)}-${_two(c.day)} ${_two(c.hour)}:${_two(c.minute)}';
            }(),
          ),
      ],
      bars: bars,
      barsCaption: bars.isEmpty ? null : caption,
    ),
    observedAt: observedAt(balance),
  );
}

// ---------------------------------------------------------------------------
// 教室空位: rooms free in the current or next teaching period.

/// The teaching period now running or next to start, or null after the last.
int? referencePeriod(DateTime now) {
  final c = campusClock(now);
  final minutes = c.hour * 60 + c.minute;
  for (final unit in TeachingUnit.all.take(13)) {
    if (unit.endHour * 60 + unit.endMinute > minutes) return unit.unit;
  }
  return null;
}

TileData? roomsTile(dynamic raw, String building, DateTime now) {
  if (!hasBatch(raw)) return null;
  final rooms = RoomDataParser.parse(raw);
  final name = CampusBuildings.toDisplayName(building);
  final period = referencePeriod(now);
  if (rooms.isEmpty) {
    return TileData(
      TileFacts(note: '$name · 今日暂无教室数据'),
      observedAt: observedAt(raw),
    );
  }
  final freeBy = [
    for (var p = 0; p < 13; p++)
      rooms.where((r) => r.periods[p] == PeriodStatus.free).length,
  ];
  final bars = [
    for (var p = 0; p < 13; p++)
      TileBar('${p + 1}', freeBy[p].toDouble(), marked: p + 1 == period),
  ];
  if (period == null) {
    return TileData(
      TileFacts(note: '$name · 今日课程已结束', bars: bars, barsCaption: '各节空闲教室数'),
      observedAt: observedAt(raw),
    );
  }
  final unit = TeachingUnit.get(period)!;
  final c = campusClock(now);
  final started =
      c.hour * 60 + c.minute >= unit.startHour * 60 + unit.startMinute;
  int freeUntil(RoomItem room) {
    var last = period - 1;
    while (last < 13 && room.periods[last] == PeriodStatus.free) {
      last++;
    }
    return last;
  }

  final free =
      rooms.where((r) => r.periods[period - 1] == PeriodStatus.free).toList()
        ..sort((a, b) {
          final byStreak = freeUntil(b).compareTo(freeUntil(a));
          if (byStreak != 0) return byStreak;
          final bySeats = (int.tryParse(b.seats ?? '') ?? -1).compareTo(
            int.tryParse(a.seats ?? '') ?? -1,
          );
          return bySeats != 0 ? bySeats : a.roomName.compareTo(b.roomName);
        });
  return TileData(
    TileFacts(
      value: '${free.length}',
      unit: '间空闲',
      note:
          '$name · 第$period节${started ? '' : ' ${unit.startTimeFormatted} 起'}',
      rows: [
        for (final room in free)
          TileFact(room.roomName, value: '空到第${freeUntil(room)}节'),
      ],
      bars: bars,
      barsCaption: '共 ${rooms.length} 间 · 各节空闲教室数',
    ),
    observedAt: observedAt(raw),
  );
}

// ---------------------------------------------------------------------------
// 图书馆、食堂客流.

TileData? libraryTile(dynamic raw) {
  if (!hasBatch(raw)) return null;
  final halls = [
    for (final p in payloads(raw))
      if (_number(p['inside']) != null) p,
  ]..sort((a, b) => _number(b['inside'])!.compareTo(_number(a['inside'])!));
  if (halls.isEmpty) {
    return TileData(
      const TileFacts(note: '暂无在馆数据'),
      observedAt: observedAt(raw),
    );
  }
  final total = halls.fold<num>(0, (sum, p) => sum + _number(p['inside'])!);
  return TileData(
    TileFacts(
      value: plainNumber(total),
      unit: '人在馆',
      note: '共 ${halls.length} 个馆区',
      rows: [
        for (final p in halls)
          TileFact(
            _text(p['campus']).isEmpty ? '图书馆' : _text(p['campus']),
            value: _number(p['capacity']) == null
                ? '${plainNumber(_number(p['inside'])!)} 人'
                : '${plainNumber(_number(p['inside'])!)}/${plainNumber(_number(p['capacity'])!)}',
            level: _share(p['inside'], p['capacity']),
          ),
      ],
    ),
    observedAt: observedAt(raw),
  );
}

double? _share(dynamic used, dynamic capacity) {
  final u = _number(used), c = _number(capacity);
  if (u == null || c == null || c <= 0) return null;
  return (u / c).toDouble();
}

int diningArea(Map<String, Object> options) {
  final area = options['area'];
  return area is num && area >= 0 && area < diningAreas.length
      ? area.toInt()
      : 0;
}

TileData? diningTile(dynamic raw, int area) {
  if (!hasBatch(raw)) return null;
  final halls = [
    for (final p in payloads(raw))
      if (_number(p['current']) != null) p,
  ];
  final name = diningAreas[area];
  if (halls.isEmpty) {
    return TileData(
      TileFacts(note: '$name · 暂无客流数据'),
      observedAt: observedAt(raw),
    );
  }
  final current = halls.fold<num>(0, (s, p) => s + _number(p['current'])!);
  final capacity = halls.fold<num>(
    0,
    (s, p) => s + (_number(p['capacity']) ?? 0),
  );
  double level(Map p) => _share(p['current'], p['capacity']) ?? double.infinity;
  final quiet = [...halls]..sort((a, b) => level(a).compareTo(level(b)));
  return TileData(
    TileFacts(
      value: capacity > 0
          ? '${(100 * current / capacity).round()}'
          : plainNumber(current),
      unit: capacity > 0 ? '%' : '人',
      note: capacity > 0
          ? '$name · ${plainNumber(current)}/${plainNumber(capacity)} 人'
          : name,
      rows: [
        for (final p in quiet)
          TileFact(
            _text(p['name']).isEmpty ? '餐厅' : _text(p['name']),
            value: _number(p['capacity']) == null
                ? '${plainNumber(_number(p['current'])!)} 人'
                : '${plainNumber(_number(p['current'])!)}/${plainNumber(_number(p['capacity'])!)}',
            level: _share(p['current'], p['capacity']),
          ),
      ],
    ),
    observedAt: observedAt(raw),
  );
}

// ---------------------------------------------------------------------------
// 校车.

(Campus, Campus) busRoute(Map<String, Object> options) {
  Campus pick(Object? name, Campus fallback) => Campus.campusValues.firstWhere(
    (c) => c.name == name,
    orElse: () => fallback,
  );
  final from = pick(options['from'], Campus.HANDAN_CAMPUS);
  var to = pick(options['to'], Campus.JIANGWAN_CAMPUS);
  if (to == from) {
    to = from == Campus.HANDAN_CAMPUS
        ? Campus.JIANGWAN_CAMPUS
        : Campus.HANDAN_CAMPUS;
  }
  return (from, to);
}

/// The bus page's rule: weekends run the holiday timetable.
bool busHoliday(DateTime now) {
  final weekday = campusClock(now).weekday;
  return weekday == DateTime.saturday || weekday == DateTime.sunday;
}

String _route(Campus from, Campus to) => '${from.shortName} → ${to.shortName}';

TileData? busTile(dynamic raw, Campus from, Campus to, DateTime now) {
  if (!hasBatch(raw)) return null;
  final items = <BusScheduleItem>[];
  for (final row in busRows(raw)) {
    try {
      items.add(BusScheduleItem.fromRawJson(row));
    } catch (_) {}
  }
  final clock = campusClock(now);
  List<BusScheduleItem> upcoming(Campus a, Campus b) => [
    for (final item in directedBuses(items, a, b))
      if (item.realStartTime?.isAfter(clock) ?? false) item,
  ];
  final route = _route(from, to);
  final ahead = upcoming(from, to);
  final back = upcoming(to, from);
  final day = busHoliday(now) ? '节假日' : '工作日';
  if (directedBuses(items, from, to).isEmpty) {
    return TileData(
      TileFacts(note: '$route · $day无直达班次'),
      observedAt: observedAt(raw),
    );
  }
  if (ahead.isEmpty) {
    return TileData(
      TileFacts(
        note: '$route · 今日已无班次',
        rows: [
          for (final item in back.take(3))
            TileFact(
              _route(to, from),
              value: item.realStartTime!.toDisplayFormat(),
            ),
        ],
      ),
      observedAt: observedAt(raw),
    );
  }
  final next = ahead.first.realStartTime!;
  final wait = next.hour * 60 + next.minute - (clock.hour * 60 + clock.minute);
  final waitText = wait < 60
      ? '$wait 分钟后'
      : '${wait ~/ 60} 小时${wait % 60 == 0 ? '' : ' ${wait % 60} 分钟'}后';
  return TileData(
    TileFacts(
      value: next.toDisplayFormat(),
      note: '$route · $waitText${ahead.length == 1 ? ' · 末班' : ''}',
      rows: [
        for (final item in ahead.skip(1).take(3))
          TileFact(route, value: item.realStartTime!.toDisplayFormat()),
        for (final item in back.take(3))
          TileFact(
            _route(to, from),
            value: item.realStartTime!.toDisplayFormat(),
          ),
      ],
    ),
    observedAt: observedAt(raw),
  );
}

// ---------------------------------------------------------------------------
// 教务公告.

TileData? noticesTile(dynamic raw) {
  if (!hasBatch(raw)) return null;
  final notices = [
    for (final p in payloads(raw))
      if (_text(p['title']).isNotEmpty) p,
  ];
  if (notices.isEmpty) {
    return TileData(const TileFacts(note: '暂无公告'), observedAt: observedAt(raw));
  }
  final first = notices.first;
  final date = shortDate(first['published_on'] ?? first['date']);
  return TileData(
    TileFacts(
      note: date == null
          ? _text(first['title'])
          : '$date ${_text(first['title'])}',
      rows: [
        for (final p in notices.skip(1))
          TileFact(
            _text(p['title']),
            value: shortDate(p['published_on'] ?? p['date']),
          ),
      ],
    ),
    observedAt: observedAt(raw),
  );
}

// ---------------------------------------------------------------------------
// 成绩、绩点、考试: resolved through the stored semester and student record.

class _Term {
  const _Term(this.id, this.name, this.association);
  final String id;
  final String? name;
  final String association;
}

Future<_Term?> _academicTerm(TileSource source) async {
  final catalog = await source.read('fudan.semesters');
  if (catalog is! Map) return null;
  final semesters =
      (catalog['semesters'] is List ? catalog['semesters'] as List : [])
          .whereType<Map>();
  var id = catalog['default_semester_id']?.toString();
  if (id == null || id.isEmpty) {
    id = semesters.isEmpty ? null : semesters.first['external_id']?.toString();
  }
  if (id == null || id.isEmpty) return null;
  final record = await source.read('fudan.student_association', {
    'semester_id': id,
  });
  final association = record is Map ? record['payload'] : null;
  if (association is! String ||
      association.isEmpty ||
      association == 'student-association') {
    return null;
  }
  String? name;
  for (final s in semesters) {
    if (s['external_id']?.toString() == id) name = _text(s['name']);
  }
  return _Term(id, name, association);
}

TileData? gradesTile(dynamic raw, String? semester) {
  if (!hasBatch(raw)) return null;
  final graded = [
    for (final p in payloads(raw))
      if (_text(p['letter_grade']).isNotEmpty) p,
  ];
  return TileData(
    TileFacts(
      value: '${graded.length}',
      unit: '门已出分',
      note: semester == null || semester.isEmpty ? '本学期' : semester,
      rows: [
        for (final p in graded)
          TileFact(
            _text(p['course_name']).isEmpty ? '课程' : _text(p['course_name']),
            value: [
              _text(p['letter_grade']),
              if (_number(p['grade_point']) != null)
                plainNumber(_number(p['grade_point'])!),
            ].join(' · '),
          ),
      ],
    ),
    observedAt: observedAt(raw),
  );
}

TileData? gpaTile(dynamic raw, String? account) {
  if (!hasBatch(raw)) return null;
  final rows = payloads(raw);
  // The list may hold other students; show only the person's own row.
  final own = rows.where(
    (p) => account != null && _text(p['student_code']) == account,
  );
  final mine = own.isNotEmpty
      ? own.first
      : (rows.length == 1 ? rows.single : null);
  final gpa = mine == null ? null : _number(mine['gpa']);
  if (mine == null || gpa == null) {
    return TileData(
      const TileFacts(note: '轻点查看绩点'),
      observedAt: observedAt(raw),
    );
  }
  final credits = _number(mine['credits']);
  final ranking = _number(mine['ranking']);
  final major = _text(mine['major']).isNotEmpty
      ? _text(mine['major'])
      : _text(mine['department']);
  return TileData(
    TileFacts(
      value: gpa.toStringAsFixed(2),
      note: credits == null ? '学业绩点' : '已获 ${plainNumber(credits)} 学分',
      rows: [
        if (ranking != null) TileFact('排名', value: '第 ${ranking.round()} 名'),
        if (major.isNotEmpty) TileFact('专业', value: major),
      ],
    ),
    observedAt: observedAt(raw),
  );
}

TileData? examsTile(dynamic raw, DateTime now) {
  if (!hasBatch(raw)) return null;
  final c = campusClock(now);
  final today = DateTime.utc(c.year, c.month, c.day);
  int start(Map p) {
    final m = RegExp(r'(\d{1,2}):(\d{2})').firstMatch(_text(p['time_range']));
    return m == null ? 24 * 60 : int.parse(m[1]!) * 60 + int.parse(m[2]!);
  }

  final upcoming =
      [
        for (final p in payloads(raw))
          if (p['finished'] != true &&
              _calendarDate(p['on']) != null &&
              !_calendarDate(p['on'])!.isBefore(today))
            p,
      ]..sort((a, b) {
        final byDay = _calendarDate(a['on'])!
            .compareTo(_calendarDate(b['on'])!);
        return byDay != 0 ? byDay : start(a).compareTo(start(b));
      });
  if (upcoming.isEmpty) {
    return TileData(
      const TileFacts(note: '暂无待考科目'),
      observedAt: observedAt(raw),
    );
  }
  final next = upcoming.first;
  final days = _calendarDate(next['on'])!.difference(today).inDays;
  final time = RegExp(r'\d{1,2}:\d{2}')
      .firstMatch(_text(next['time_range']))?[0];
  return TileData(
    TileFacts(
      value: switch (days) {
        0 => '今天',
        1 => '明天',
        _ => '$days',
      },
      unit: days > 1 ? '天后' : null,
      note: [
        _text(next['course_name']).isEmpty ? '考试' : _text(next['course_name']),
        ?time,
        if (_text(next['room']).isNotEmpty) _text(next['room']),
      ].join(' · '),
      rows: [
        for (final p in upcoming.skip(1))
          TileFact(
            _text(p['course_name']).isEmpty ? '考试' : _text(p['course_name']),
            value: shortDate(p['on']),
          ),
        if (upcoming.length > 1) TileFact('待考', value: '${upcoming.length} 场'),
      ],
    ),
    observedAt: observedAt(raw),
  );
}

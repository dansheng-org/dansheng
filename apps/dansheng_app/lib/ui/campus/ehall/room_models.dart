// SPDX-License-Identifier: GPL-3.0-or-later

import 'campus_building.dart';

/// The availability status for an academic period slot (1 through 13).
enum PeriodStatus { free, occupied, unknown }

/// Represents a classroom and its 13-period availability status.
class RoomItem {
  final String roomName;
  final String? seats;
  final List<PeriodStatus> periods;
  final bool? available;

  const RoomItem({
    required this.roomName,
    this.seats,
    required this.periods,
    this.available,
  });

  /// Total count of periods that are free.
  int get freePeriodsCount =>
      periods.where((p) => p == PeriodStatus.free).length;

  /// Total count of periods that are occupied.
  int get occupiedPeriodsCount =>
      periods.where((p) => p == PeriodStatus.occupied).length;

  /// Total count of periods where availability is unknown.
  int get unknownPeriodsCount =>
      periods.where((p) => p == PeriodStatus.unknown).length;

  /// Whether the room has at least one free period.
  bool get hasFreePeriods => freePeriodsCount > 0;

  /// Human-readable summary for quick scanning.
  String get summaryText {
    if (freePeriodsCount > 0) {
      return '$freePeriodsCount 节空闲';
    } else if (occupiedPeriodsCount > 0) {
      return '全天占用';
    } else {
      return '时段未公布';
    }
  }
}

/// Represents a campus tab and its associated building codes.
class CampusOption {
  final String campus;
  final String displayName;
  final List<String> buildingCodes;

  const CampusOption({
    required this.campus,
    required this.displayName,
    required this.buildingCodes,
  });
}

/// Campus teaching building grouping matching DanXi constant.dart
/// and Dansheng CampusBuildings.
abstract final class RoomCampuses {
  static const List<CampusOption> all = [
    CampusOption(
      campus: '邯郸',
      displayName: '邯郸校区',
      buildingCodes: ['HGD', 'HGX', 'H2', 'H3', 'H4', 'H5', 'H6'],
    ),
    CampusOption(
      campus: '枫林',
      displayName: '枫林校区',
      buildingCodes: ['F1', 'F2'],
    ),
    CampusOption(
      campus: '江湾',
      displayName: '江湾校区',
      buildingCodes: ['JA', 'JB'],
    ),
    CampusOption(campus: '张江', displayName: '张江校区', buildingCodes: ['Z2']),
  ];

  /// Resolves the campus option that contains the given building code or name.
  static CampusOption campusForBuilding(String? buildingCodeOrName) {
    final code = CampusBuildings.toCode(buildingCodeOrName);
    for (final c in all) {
      if (c.buildingCodes.contains(code)) {
        return c;
      }
    }
    return all.first;
  }
}

/// Returns the current class period slot (1 through 13) if the selected date is today,
/// or null if outside class hours or not today.
int? getCurrentPeriodSlot(DateTime date, [DateTime? testNow]) {
  final now = testNow ?? campusRoomNow();
  if (date.year != now.year || date.month != now.month || date.day != now.day) {
    return null;
  }
  final minutes = now.hour * 60 + now.minute;
  // Fudan schedule (in minutes from 00:00):
  // 1: 08:00 - 08:45 (480 - 525)
  // 2: 08:55 - 09:40 (535 - 580)
  // 3: 09:55 - 10:40 (595 - 640)
  // 4: 10:50 - 11:35 (650 - 700)
  // 5: 11:45 - 12:30 (705 - 750)
  // 6: 13:30 - 14:15 (810 - 855)
  // 7: 14:25 - 15:10 (865 - 910)
  // 8: 15:25 - 16:10 (925 - 970)
  // 9: 16:20 - 17:05 (980 - 1025)
  // 10: 17:15 - 18:00 (1035 - 1080)
  // 11: 18:30 - 19:15 (1110 - 1155)
  // 12: 19:25 - 20:10 (1165 - 1210)
  // 13: 20:20 - 21:05 (1220 - 1265)
  const slots = [
    (480, 530),
    (535, 585),
    (595, 645),
    (650, 700),
    (705, 760),
    (810, 860),
    (865, 915),
    (925, 975),
    (980, 1030),
    (1035, 1085),
    (1110, 1160),
    (1165, 1215),
    (1220, 1270),
  ];
  for (int i = 0; i < slots.length; i++) {
    if (minutes >= slots[i].$1 && minutes <= slots[i].$2) {
      return i + 1;
    }
  }
  return null;
}

DateTime campusRoomNow() =>
    DateTime.now().toUtc().add(const Duration(hours: 8));

/// Parses diverse response payloads from fudan.rooms and campus.cached.
/// Handles SourceBatch {records: [{id, payload}]}, direct List, DanXi RoomInfo,
/// and guards against false green on missing/unknown slots.
abstract final class RoomDataParser {
  static List<RoomItem> parse(dynamic data) {
    if (data == null) return [];

    final rawRecords = <Map<String, dynamic>>[];

    void collect(dynamic node) {
      if (node == null) return;
      if (node is List) {
        for (final item in node) {
          collect(item);
        }
      } else if (node is Map) {
        if (node['records'] is List) {
          collect(node['records']);
        } else if (node['payload'] is List) {
          collect(node['payload']);
        } else if (node['rooms'] is List) {
          collect(node['rooms']);
        } else if (node['data'] is List) {
          collect(node['data']);
        } else if (node['entries'] is List) {
          collect(node['entries']);
        } else if (node['list'] is List) {
          collect(node['list']);
        } else if (node['payload'] is Map) {
          final payloadMap = Map<String, dynamic>.from(node['payload'] as Map);
          if (!payloadMap.containsKey('id') && node.containsKey('id')) {
            payloadMap['id'] = node['id'];
          }
          rawRecords.add(payloadMap);
        } else {
          rawRecords.add(Map<String, dynamic>.from(node));
        }
      }
    }

    collect(data);

    final results = <RoomItem>[];
    for (final map in rawRecords) {
      final name =
          (map['room'] ??
                  map['room_name'] ??
                  map['roomName'] ??
                  map['name'] ??
                  map['id'] ??
                  '')
              .toString()
              .trim();
      if (name.isEmpty) continue;

      final rawSeats =
          map['seats'] ??
          map['capacity'] ??
          map['seat_count'] ??
          map['seatCount'];
      final seatsStr = rawSeats?.toString().trim();

      final rawBusy =
          map['busy_units'] ?? map['busy'] ?? map['units'] ?? map['periods'];

      final List<PeriodStatus> periods = [];
      for (int i = 0; i < 13; i++) {
        if (rawBusy is List && i < rawBusy.length) {
          final val = rawBusy[i];
          if (val == false || val == 0 || val == '0' || val == 'free') {
            periods.add(PeriodStatus.free);
          } else if (val == true ||
              val == 1 ||
              val == '1' ||
              val == 'busy' ||
              val == 'occupied') {
            periods.add(PeriodStatus.occupied);
          } else {
            // Explicit null or unrecognized -> unknown
            periods.add(PeriodStatus.unknown);
          }
        } else {
          // Missing / out of bounds -> unknown, never false green!
          periods.add(PeriodStatus.unknown);
        }
      }

      final bool? available = map['available'] is bool
          ? map['available'] as bool
          : null;

      results.add(
        RoomItem(
          roomName: name,
          seats: (seatsStr?.isNotEmpty ?? false) ? seatsStr : null,
          periods: periods,
          available: available,
        ),
      );
    }

    return results;
  }
}

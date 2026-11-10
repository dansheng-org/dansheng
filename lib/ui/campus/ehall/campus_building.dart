// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/foundation.dart';

/// Represents a campus teaching building with its verified DanXi building code,
/// localized Chinese display name, and campus grouping.
@immutable
class CampusBuilding {
  final String code;
  final String displayName;
  final String campus;

  const CampusBuilding({
    required this.code,
    required this.displayName,
    required this.campus,
  });

  @override
  String toString() => '$displayName ($code)';
}

/// Campus teaching building definitions, code mappings, and validation
/// aligned with DanXi `Constant.CAMPUS_VALUES.getTeachingBuildings()`.
///
/// Handan:    ['HGD', 'HGX', 'H2', 'H3', 'H4', 'H5', 'H6']
/// Fenglin:   ['F1', 'F2']
/// Jiangwan:  ['JA', 'JB']
/// Zhangjiang:['Z2']
abstract final class CampusBuildings {
  static const String defaultBuildingCode = 'H3';
  static const String defaultBuildingName = '第三教学楼';

  /// All allowed campus teaching buildings from DanXi constant.dart.
  static const List<CampusBuilding> all = [
    // 邯郸校区 (Handan)
    CampusBuilding(code: 'H3', displayName: '第三教学楼', campus: '邯郸'),
    CampusBuilding(code: 'H2', displayName: '第二教学楼', campus: '邯郸'),
    CampusBuilding(code: 'H4', displayName: '第四教学楼', campus: '邯郸'),
    CampusBuilding(code: 'H5', displayName: '第五教学楼', campus: '邯郸'),
    CampusBuilding(code: 'H6', displayName: '第六教学楼', campus: '邯郸'),
    CampusBuilding(code: 'HGD', displayName: '光华楼东', campus: '邯郸'),
    CampusBuilding(code: 'HGX', displayName: '光华楼西', campus: '邯郸'),
    // 枫林校区 (Fenglin)
    CampusBuilding(code: 'F1', displayName: '枫林一教', campus: '枫林'),
    CampusBuilding(code: 'F2', displayName: '枫林二教', campus: '枫林'),
    // 江湾校区 (Jiangwan)
    CampusBuilding(code: 'JA', displayName: '江湾A教', campus: '江湾'),
    CampusBuilding(code: 'JB', displayName: '江湾B教', campus: '江湾'),
    // 张江校区 (Zhangjiang)
    CampusBuilding(code: 'Z2', displayName: '张江二教', campus: '张江'),
  ];

  /// Set of verified campus building codes.
  static const Set<String> allowedCodes = {
    'HGD',
    'HGX',
    'H2',
    'H3',
    'H4',
    'H5',
    'H6',
    'F1',
    'F2',
    'JA',
    'JB',
    'Z2',
  };

  /// Maps display names, abbreviations, or codes to verified DanXi building codes.
  /// Guarantees that only valid building codes (like 'H3') are returned,
  /// never arbitrary display text.
  static String toCode(String? input) {
    if (input == null) return defaultBuildingCode;
    final trimmed = input.trim();
    if (trimmed.isEmpty) return defaultBuildingCode;

    final upper = trimmed.toUpperCase();
    if (allowedCodes.contains(upper)) {
      return upper;
    }

    // Direct match against known display names
    for (final b in all) {
      if (trimmed == b.displayName || upper == b.code) {
        return b.code;
      }
    }

    // Heuristics for Chinese aliases / numbers
    if (trimmed.contains('三') || trimmed.contains('3')) return 'H3';
    if (trimmed.contains('二') || trimmed.contains('2')) {
      if (trimmed.contains('枫')) return 'F2';
      if (trimmed.contains('张')) return 'Z2';
      return 'H2';
    }
    if (trimmed.contains('四') || trimmed.contains('4')) return 'H4';
    if (trimmed.contains('五') || trimmed.contains('5')) return 'H5';
    if (trimmed.contains('六') || trimmed.contains('6')) return 'H6';
    if (trimmed.contains('光华') || trimmed.contains('光')) {
      if (trimmed.contains('西')) return 'HGX';
      return 'HGD';
    }
    if (trimmed.contains('枫') || upper.startsWith('F')) {
      if (trimmed.contains('2') || trimmed.contains('二')) return 'F2';
      return 'F1';
    }
    if (trimmed.contains('江湾') || upper.startsWith('J')) {
      if (upper.contains('B') ||
          trimmed.contains('B') ||
          trimmed.contains('b')) {
        return 'JB';
      }
      return 'JA';
    }
    if (trimmed.contains('张江') || upper.startsWith('Z')) {
      return 'Z2';
    }

    // Safe fallback ensuring arbitrary display text is never sent to fudan.rooms
    return defaultBuildingCode;
  }

  /// Maps a code or name to its Chinese display title (e.g. 'H3' -> '第三教学楼').
  static String toDisplayName(String? codeOrName) {
    final code = toCode(codeOrName);
    for (final b in all) {
      if (b.code == code) return b.displayName;
    }
    return defaultBuildingName;
  }
}

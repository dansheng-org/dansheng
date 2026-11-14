// SPDX-License-Identifier: GPL-3.0-or-later

/// Represents an academic semester.
class Semester {
  final String externalId;
  final String name;
  final DateTime startsOn;

  const Semester({
    required this.externalId,
    required this.name,
    required this.startsOn,
  });

  factory Semester.fromJson(Map<String, dynamic> json) {
    final payload = (json['payload'] is Map<String, dynamic>)
        ? json['payload'] as Map<String, dynamic>
        : json;

    final id =
        payload['external_id']?.toString() ??
        payload['id']?.toString() ??
        payload['externalId']?.toString() ??
        '';
    final name = payload['name']?.toString() ?? '';
    final startsOnStr =
        payload['starts_on']?.toString() ??
        payload['startsOn']?.toString() ??
        '';

    DateTime parsedStart;
    if (startsOnStr.isNotEmpty) {
      try {
        parsedStart = DateTime.parse(startsOnStr);
      } catch (_) {
        parsedStart = DateTime.now();
      }
    } else {
      parsedStart = DateTime.now();
    }

    return Semester(
      externalId: id,
      name: name,
      startsOn: DateTime(parsedStart.year, parsedStart.month, parsedStart.day),
    );
  }

  Map<String, dynamic> toJson() => {
    'external_id': externalId,
    'name': name,
    'starts_on':
        '${startsOn.year.toString().padLeft(4, '0')}-${startsOn.month.toString().padLeft(2, '0')}-${startsOn.day.toString().padLeft(2, '0')}',
  };
}

/// Catalog of semesters returned by fudan.semesters.
class SemesterCatalog {
  final List<Semester> semesters;
  final String? defaultSemesterId;

  const SemesterCatalog({required this.semesters, this.defaultSemesterId});

  factory SemesterCatalog.fromJson(dynamic json) {
    if (json is List) {
      final list = json
          .whereType<Map<String, dynamic>>()
          .map((e) => Semester.fromJson(e))
          .toList();
      return SemesterCatalog(
        semesters: list,
        defaultSemesterId: list.isNotEmpty ? list.first.externalId : null,
      );
    }
    if (json is Map<String, dynamic>) {
      final sems =
          (json['semesters'] as List?)
              ?.whereType<Map<String, dynamic>>()
              .map((e) => Semester.fromJson(e))
              .toList() ??
          <Semester>[];
      final defId =
          json['default_semester_id']?.toString() ??
          json['defaultSemesterId']?.toString();
      return SemesterCatalog(semesters: sems, defaultSemesterId: defId);
    }
    return const SemesterCatalog(semesters: []);
  }
}

/// Standard 14 Fudan class unit times (starts and ends).
class TeachingUnit {
  final int unit;
  final int startHour;
  final int startMinute;
  final int endHour;
  final int endMinute;

  const TeachingUnit(
    this.unit,
    this.startHour,
    this.startMinute,
    this.endHour,
    this.endMinute,
  );

  String get startTimeFormatted =>
      '${startHour.toString().padLeft(2, '0')}:${startMinute.toString().padLeft(2, '0')}';
  String get endTimeFormatted =>
      '${endHour.toString().padLeft(2, '0')}:${endMinute.toString().padLeft(2, '0')}';

  static const List<TeachingUnit> all = [
    TeachingUnit(1, 8, 0, 8, 45),
    TeachingUnit(2, 8, 55, 9, 40),
    TeachingUnit(3, 9, 55, 10, 40),
    TeachingUnit(4, 10, 50, 11, 35),
    TeachingUnit(5, 11, 45, 12, 30),
    TeachingUnit(6, 13, 30, 14, 15),
    TeachingUnit(7, 14, 25, 15, 10),
    TeachingUnit(8, 15, 25, 16, 10),
    TeachingUnit(9, 16, 20, 17, 5),
    TeachingUnit(10, 17, 15, 18, 0),
    TeachingUnit(11, 18, 30, 19, 15),
    TeachingUnit(12, 19, 25, 20, 10),
    TeachingUnit(13, 20, 20, 21, 5),
    TeachingUnit(14, 21, 15, 22, 0),
  ];

  static TeachingUnit? get(int unit) {
    if (unit >= 1 && unit <= all.length) {
      return all[unit - 1];
    }
    return null;
  }
}

/// A course from the timetable.
class TimetableCourse {
  final String? lessonId;
  final String? courseCode;
  final String name;
  final List<String> teachers;
  final String? room;
  final int weekday; // 1 = Mon, 7 = Sun
  final int startUnit;
  final int endUnit;
  final List<int> weeks;

  const TimetableCourse({
    this.lessonId,
    this.courseCode,
    required this.name,
    this.teachers = const [],
    this.room,
    required this.weekday,
    required this.startUnit,
    required this.endUnit,
    this.weeks = const [],
  });

  factory TimetableCourse.fromJson(Map<String, dynamic> json) {
    final payload = (json['payload'] is Map<String, dynamic>)
        ? json['payload'] as Map<String, dynamic>
        : json;

    final teachersRaw = payload['teachers'];
    List<String> teachersList = [];
    if (teachersRaw is List) {
      teachersList = teachersRaw.map((e) => e.toString()).toList();
    }

    final weeksRaw = payload['weeks'] ?? payload['weekIndexes'];
    List<int> weeksList = [];
    if (weeksRaw is List) {
      weeksList = weeksRaw
          .map((e) => e is int ? e : int.tryParse(e.toString()) ?? 0)
          .where((w) => w >= 0)
          .toList();
    }

    final rawStart = payload['start_unit'] ?? payload['startUnit'];
    final startUnit = rawStart is int
        ? rawStart
        : int.tryParse(rawStart?.toString() ?? '1') ?? 1;

    final rawEnd = payload['end_unit'] ?? payload['endUnit'];
    final endUnit = rawEnd is int
        ? rawEnd
        : int.tryParse(rawEnd?.toString() ?? '1') ?? 1;

    final rawWeekday = payload['weekday'];
    final weekday = rawWeekday is int
        ? rawWeekday
        : int.tryParse(rawWeekday?.toString() ?? '1') ?? 1;

    return TimetableCourse(
      lessonId: (payload['lesson_id'] ?? payload['lessonId'])?.toString(),
      courseCode: (payload['course_code'] ?? payload['lessonCode'])?.toString(),
      name: (payload['name'] ?? payload['courseName'])?.toString() ?? '',
      teachers: teachersList,
      room: payload['room']?.toString(),
      weekday: weekday,
      startUnit: startUnit,
      endUnit: endUnit,
      weeks: weeksList,
    );
  }

  /// Formatted time span string e.g. "08:00 - 09:40 · 第1-2节".
  String get timeSpanFormatted {
    final start = TeachingUnit.get(startUnit);
    final end = TeachingUnit.get(endUnit) ?? start;
    if (start != null && end != null) {
      final unitStr = (startUnit == endUnit)
          ? '第$startUnit节'
          : '第$startUnit-$endUnit节';
      return '${start.startTimeFormatted} - ${end.endTimeFormatted} · $unitStr';
    }
    return '第$startUnit-$endUnit节';
  }

  /// Check whether this course occurs on a given date under a semester's startsOn Monday.
  bool occursOn(DateTime date, Semester? semester) {
    if (semester == null) {
      // Fallback: match weekday if semester date is unknown
      return weekday == date.weekday;
    }

    final semStart = DateTime.utc(
      semester.startsOn.year,
      semester.startsOn.month,
      semester.startsOn.day,
    );
    final target = DateTime.utc(date.year, date.month, date.day);
    final diffDays = target.difference(semStart).inDays;

    final int week;
    if (diffDays >= 0) {
      week = (diffDays ~/ 7) + 1;
    } else if (diffDays == -1 && target.weekday == 7) {
      // Week zero is retained for UG Sunday spillover before teaching week 1
      week = 0;
    } else {
      return false;
    }

    final dayOfWeek = target.weekday; // 1 = Monday, 7 = Sunday
    return weekday == dayOfWeek && weeks.contains(week);
  }
}

/// Collapses week numbers into ranges, e.g. `1-4, 6, 8-16`.
String formatWeeks(List<int> weeks) {
  final sorted = weeks.toSet().toList()..sort();
  final parts = <String>[];
  var i = 0;
  while (i < sorted.length) {
    var j = i;
    while (j + 1 < sorted.length && sorted[j + 1] == sorted[j] + 1) {
      j++;
    }
    parts.add(i == j ? '${sorted[i]}' : '${sorted[i]}-${sorted[j]}');
    i = j + 1;
  }
  return parts.join(', ');
}

/// Parsed Timetable containing list of courses and semester info.
class TimetableData {
  final Semester? semester;
  final List<TimetableCourse> courses;

  const TimetableData({this.semester, required this.courses});

  factory TimetableData.fromJson(dynamic json, [Semester? currentSemester]) {
    if (json == null) {
      return TimetableData(semester: currentSemester, courses: const []);
    }

    Semester? sem = currentSemester;
    final List<TimetableCourse> courses = [];

    if (json is Map<String, dynamic>) {
      if (json['semester'] is Map<String, dynamic>) {
        sem = Semester.fromJson(json['semester'] as Map<String, dynamic>);
      }

      // Check if courses is a list of SourceRecords or courses
      if (json['courses'] is List) {
        for (final item in json['courses'] as List) {
          if (item is Map<String, dynamic>) {
            courses.add(TimetableCourse.fromJson(item));
          }
        }
      } else if (json['studentTableVms'] is List) {
        // Raw crawler format (DanXi / undergraduate.json)
        for (final vm in json['studentTableVms'] as List) {
          if (vm is Map<String, dynamic> && vm['activities'] is List) {
            for (final act in vm['activities'] as List) {
              if (act is Map<String, dynamic>) {
                courses.add(TimetableCourse.fromJson(act));
              }
            }
          }
        }
      }
    } else if (json is List) {
      for (final item in json) {
        if (item is Map<String, dynamic>) {
          courses.add(TimetableCourse.fromJson(item));
        }
      }
    }

    return TimetableData(semester: sem, courses: courses);
  }

  /// Get all courses that occur on a specific date.
  List<TimetableCourse> coursesOn(DateTime date) {
    final list = courses.where((c) => c.occursOn(date, semester)).toList();
    // Sort by startUnit ascending
    list.sort((a, b) => a.startUnit.compareTo(b.startUnit));
    return list;
  }

  /// Check if there are any courses on a specific date.
  bool hasCoursesOn(DateTime date) {
    return courses.any((c) => c.occursOn(date, semester));
  }
}

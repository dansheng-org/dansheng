// SPDX-License-Identifier: GPL-3.0-or-later

Map<String, dynamic> _timetableObject(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  throw const FormatException('Invalid timetable record');
}

int _timetableInt(dynamic value, int min, int max) {
  final parsed = value is int ? value : int.tryParse(value?.toString() ?? '');
  if (parsed == null || parsed < min || parsed > max) {
    throw const FormatException('Invalid timetable number');
  }
  return parsed;
}

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

    final parsedStart = DateTime.tryParse(startsOnStr);
    // Fabricating a start date shifts every teaching week. Rust serializes
    // a date-only Monday; reject damaged cache metadata explicitly.
    if (id.isEmpty ||
        parsedStart == null ||
        !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(startsOnStr) ||
        parsedStart.toIso8601String().substring(0, 10) != startsOnStr ||
        parsedStart.weekday != DateTime.monday) {
      throw const FormatException('Invalid timetable semester');
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
          .map((e) => Semester.fromJson(_timetableObject(e)))
          .toList();
      return SemesterCatalog(
        semesters: list,
        defaultSemesterId: list.isNotEmpty ? list.first.externalId : null,
      );
    }
    if (json is Map<String, dynamic>) {
      if (json['semesters'] is! List) {
        throw const FormatException('Invalid semester catalog');
      }
      final sems = (json['semesters'] as List)
          .map((e) => Semester.fromJson(_timetableObject(e)))
          .toList();
      final defId =
          json['default_semester_id']?.toString() ??
          json['defaultSemesterId']?.toString();
      return SemesterCatalog(semesters: sems, defaultSemesterId: defId);
    }
    throw const FormatException('Invalid semester catalog');
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

    final rawStart = payload['start_unit'] ?? payload['startUnit'];
    final startUnit = _timetableInt(rawStart, 1, 15);

    final rawEnd = payload['end_unit'] ?? payload['endUnit'];
    final endUnit = _timetableInt(rawEnd, startUnit, 15);

    final rawWeekday = payload['weekday'];
    final weekday = _timetableInt(rawWeekday, 1, 7);

    final normalized = payload.containsKey('weeks');
    final weeksRaw = normalized ? payload['weeks'] : payload['weekIndexes'];
    if (weeksRaw is! List) {
      throw const FormatException('Invalid timetable weeks');
    }
    final weeksList =
        weeksRaw
            .map((value) {
              final week = _timetableInt(value, normalized ? 0 : 1, 64);
              // JWGL raw weekIndexes start on Sunday. Rust's payload.weeks already
              // uses Monday-based weeks and must never be shifted again.
              return !normalized && weekday == DateTime.sunday
                  ? week - 1
                  : week;
            })
            .toSet()
            .toList()
          ..sort();
    final name = (payload['name'] ?? payload['courseName'])?.toString() ?? '';
    if (name.trim().isEmpty) {
      throw const FormatException('Invalid timetable course name');
    }

    return TimetableCourse(
      lessonId: (payload['lesson_id'] ?? payload['lessonId'])?.toString(),
      courseCode: (payload['course_code'] ?? payload['lessonCode'])?.toString(),
      name: name,
      teachers: teachersList,
      room: payload['room']?.toString(),
      weekday: weekday,
      startUnit: startUnit,
      endUnit: endUnit,
      weeks: weeksList,
    );
  }

  /// Same course held in the same place: candidates for one merged span.
  bool isSameCourseAs(TimetableCourse other) {
    String fold(String? s) => (s ?? '').trim();
    final code = fold(courseCode), otherCode = fold(other.courseCode);
    if (code.isNotEmpty && otherCode.isNotEmpty && code != otherCode) {
      return false;
    }
    return fold(name) == fold(other.name) && fold(room) == fold(other.room);
  }

  /// One session covering this one and [other] (same weekday, adjacent).
  TimetableCourse mergedWith(TimetableCourse other) => TimetableCourse(
    lessonId: lessonId ?? other.lessonId,
    courseCode: courseCode ?? other.courseCode,
    name: name,
    teachers: [
      ...teachers,
      for (final t in other.teachers)
        if (!teachers.contains(t)) t,
    ],
    room: room ?? other.room,
    weekday: weekday,
    startUnit: startUnit < other.startUnit ? startUnit : other.startUnit,
    endUnit: endUnit > other.endUnit ? endUnit : other.endUnit,
    weeks: ({...weeks, ...other.weeks}.toList()..sort()),
  );

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

/// Merges sessions of one course that touch or overlap on the same weekday
/// into a single span. With [sameWeeks], only sessions held in exactly the
/// same teaching weeks merge (for weekly listings that are not date-bound).
/// The result is ordered by weekday, then first unit.
List<TimetableCourse> mergeCourseSessions(
  Iterable<TimetableCourse> sessions, {
  bool sameWeeks = false,
}) {
  final sorted = sessions.toList()
    ..sort(
      (a, b) => a.weekday != b.weekday
          ? a.weekday.compareTo(b.weekday)
          : a.startUnit != b.startUnit
          ? a.startUnit.compareTo(b.startUnit)
          : a.endUnit.compareTo(b.endUnit),
    );
  final merged = <TimetableCourse>[];
  for (final next in sorted) {
    var joined = false;
    for (var i = merged.length - 1; i >= 0; i--) {
      final prev = merged[i];
      if (prev.weekday != next.weekday) break;
      if (!prev.isSameCourseAs(next) ||
          next.startUnit > prev.endUnit + 1 ||
          (sameWeeks && !_sameWeeks(prev.weeks, next.weeks))) {
        continue;
      }
      merged[i] = prev.mergedWith(next);
      joined = true;
      break;
    }
    if (!joined) merged.add(next);
  }
  return merged;
}

bool _sameWeeks(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
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
    Semester? sem = currentSemester;
    final List<TimetableCourse> courses = [];

    if (json is Map<String, dynamic>) {
      if (json['semester'] is Map<String, dynamic>) {
        sem = Semester.fromJson(json['semester'] as Map<String, dynamic>);
        if (currentSemester != null &&
            sem.externalId != currentSemester.externalId) {
          throw const FormatException('Timetable semester mismatch');
        }
      } else if (json.containsKey('semester')) {
        throw const FormatException('Invalid timetable semester');
      }

      // Check if courses is a list of SourceRecords or courses
      if (json['courses'] is List) {
        for (final item in json['courses'] as List) {
          courses.add(TimetableCourse.fromJson(_timetableObject(item)));
        }
      } else if (json['studentTableVms'] is List) {
        // Raw crawler format (DanXi / undergraduate.json)
        final tables = json['studentTableVms'] as List;
        if (tables.length != 1) {
          throw const FormatException('Invalid student timetable count');
        }
        final vm = _timetableObject(tables.single);
        if (vm['activities'] is! List) {
          throw const FormatException('Invalid timetable activities');
        }
        for (final act in vm['activities'] as List) {
          courses.add(TimetableCourse.fromJson(_timetableObject(act)));
        }
      } else {
        throw const FormatException('Invalid timetable response');
      }
    } else if (json is List) {
      for (final item in json) {
        courses.add(TimetableCourse.fromJson(_timetableObject(item)));
      }
    } else {
      // A cache miss is null; a successfully empty timetable is [] or courses: [].
      throw const FormatException('Invalid timetable response');
    }

    if (courses.isNotEmpty && sem == null) {
      throw const FormatException('Missing timetable semester');
    }

    return TimetableData(semester: sem, courses: courses);
  }

  /// Get all courses that occur on a specific date. Back-to-back sessions of
  /// the same course (as JWGL often lists each teaching unit separately) are
  /// merged into one span, the way DanXi shows them.
  List<TimetableCourse> coursesOn(DateTime date) =>
      mergeCourseSessions(courses.where((c) => c.occursOn(date, semester)));

  /// Check if there are any courses on a specific date.
  bool hasCoursesOn(DateTime date) {
    return courses.any((c) => c.occursOn(date, semester));
  }
}

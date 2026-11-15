// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:io';

import 'package:dansheng_app/ui/campus/learning/models/timetable_models.dart';
import 'package:flutter_test/flutter_test.dart';

// Rust's timetable_regression test compares this same fixture to actual
// parse_* -> serde_json output, including SourceRecord and semester metadata.
Map<String, dynamic> fixture(String name) => jsonDecode(
  File('../../core/crates/dansheng-connectors/tests/fixtures/$name')
      .readAsStringSync(),
) as Map<String, dynamic>;

void main() {
  final contract = fixture('timetable-contract.json');
  final ug = contract['undergraduate'] as Map<String, dynamic>;
  final semester = Semester.fromJson(ug['semester']);
  final payload =
      (ug['courses'] as List).first['payload'] as Map<String, dynamic>;

  test('Rust semester catalog preserves its actual selected id and Monday', () {
    final catalog = SemesterCatalog.fromJson(contract['catalog']);
    expect(catalog.defaultSemesterId, '901');
    expect(catalog.semesters.map((s) => s.externalId), ['901', '900']);
    expect(catalog.semesters.first.startsOn, DateTime(2026, 3, 2));
    expect(catalog.semesters.first.toJson(), ug['semester']);
  });

  test('Rust records produce Monday, Sunday and week-zero calendar events', () {
    final table = TimetableData.fromJson(ug);
    expect(table.courses, hasLength(2));
    expect(table.courses.first.teachers, hasLength(2));
    expect(table.courses.first.courseCode, 'SYNTH101.01');
    expect(table.courses.first.timeSpanFormatted, '08:00 - 10:40 · 第1-3节');
    expect(table.courses.last.weeks, [0, 1, 2]);
    expect(table.coursesOn(DateTime(2026, 3, 1)).single.weekday, 7);
    expect(table.coursesOn(DateTime(2026, 3, 2)).single.weekday, 1);
    expect(table.coursesOn(DateTime(2026, 3, 8)).single.weekday, 7);
    expect(table.hasCoursesOn(DateTime(2026, 3, 9)), isTrue);
    expect(table.hasCoursesOn(DateTime(2026, 3, 16)), isFalse);
    expect(table.hasCoursesOn(DateTime(2026, 3, 23)), isTrue);
    expect(table.hasCoursesOn(DateTime(2026, 2, 23)), isFalse);
  });

  test(
    'raw JWGL weekIndexes agree with Rust normalized weeks on every day',
    () {
      final raw = TimetableData.fromJson(
        fixture('undergraduate.json'),
        semester,
      );
      final normalized = TimetableData.fromJson(ug);
      for (var day = -7; day <= 42; day++) {
        final date = DateTime(2026, 3, 2 + day);
        expect(
          raw.coursesOn(date).map((c) => c.lessonId),
          normalized.coursesOn(date).map((c) => c.lessonId),
          reason: 'calendar date $date',
        );
      }
    },
  );

  test('PG bitmap weeks keep Sunday in the same Monday-based week', () {
    final table = TimetableData.fromJson(contract['postgraduate']);
    expect(table.courses.first.weeks, [1, 3, 5]);
    expect(table.courses.last.weeks, [2, 3]);
    expect(table.hasCoursesOn(DateTime(2026, 3, 3)), isTrue);
    expect(table.hasCoursesOn(DateTime(2026, 3, 10)), isFalse);
    expect(table.hasCoursesOn(DateTime(2026, 3, 8)), isFalse);
    expect(table.hasCoursesOn(DateTime(2026, 3, 15)), isTrue);
  });

  test('cached Rust JSON retains semester and identical date matches', () {
    final cached = TimetableData.fromJson(jsonDecode(jsonEncode(ug)), semester);
    expect(cached.semester!.toJson(), semester.toJson());
    expect(cached.coursesOn(DateTime(2026, 3, 1)), hasLength(1));
    final other = Semester(
      externalId: '900',
      name: 'previous',
      startsOn: DateTime(2025, 9, 1),
    );
    expect(() => TimetableData.fromJson(ug, other), throwsFormatException);
  });

  test(
    'explicit empty arrays are successful while cache misses are errors',
    () {
      for (final response in [
        <dynamic>[],
        {'courses': <dynamic>[]},
        {...ug, 'courses': <dynamic>[]},
        {
          'studentTableVms': [
            {'activities': <dynamic>[]},
          ],
        },
      ]) {
        expect(TimetableData.fromJson(response).courses, isEmpty);
      }
      expect(SemesterCatalog.fromJson([]).semesters, isEmpty);
      expect(SemesterCatalog.fromJson({'semesters': []}).semesters, isEmpty);
      for (final response in [
        null,
        {},
        {'error': 'offline'},
        '',
      ]) {
        expect(() => TimetableData.fromJson(response), throwsFormatException);
        expect(() => SemesterCatalog.fromJson(response), throwsFormatException);
      }
    },
  );

  test(
    'invalid dates cannot silently become today or overflow into next month',
    () {
      for (final start in ['', '2026-03-01', '2026-02-30', 'garbage']) {
        expect(
          () => Semester.fromJson({...semester.toJson(), 'starts_on': start}),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'malformed records and missing week metadata cannot fabricate events',
    () {
      for (final patch in [
        {'weekday': 0},
        {'start_unit': 0},
        {'end_unit': 0},
        {'weeks': null},
        {
          'weeks': ['invalid'],
        },
        {
          'weeks': [-1],
        },
        {'name': ''},
      ]) {
        expect(
          () => TimetableCourse.fromJson({...payload, ...patch}),
          throwsFormatException,
        );
      }
      expect(
        () => TimetableData.fromJson({
          'courses': [null],
        }, semester),
        throwsFormatException,
      );
      expect(
        () => TimetableData.fromJson(ug['courses']),
        throwsFormatException,
      );
      final noWeeks = TimetableCourse.fromJson({...payload, 'weeks': []});
      expect(noWeeks.occursOn(DateTime(2026, 3, 2), semester), isFalse);
    },
  );
}

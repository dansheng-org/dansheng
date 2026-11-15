// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:dansheng_app/ui/campus/learning/models/timetable_models.dart';
import 'package:flutter_test/flutter_test.dart';

TimetableCourse session(
  String name,
  int start,
  int end, {
  String room = 'H3108',
  int weekday = 1,
  List<int> weeks = const [1, 2, 3],
  List<String> teachers = const ['甲'],
}) => TimetableCourse(
  name: name,
  room: room,
  weekday: weekday,
  startUnit: start,
  endUnit: end,
  weeks: weeks,
  teachers: teachers,
);

void main() {
  final semester = Semester(
    externalId: '1',
    name: 'test',
    startsOn: DateTime(2026, 9, 7),
  );

  test('adjacent units of one course merge into a single span', () {
    final table = TimetableData(
      semester: semester,
      courses: [
        session('高等数学', 4, 4, teachers: ['乙']),
        session('高等数学', 3, 3),
        session('高等数学', 5, 5),
        session('大学物理', 6, 7),
      ],
    );
    final day = table.coursesOn(DateTime(2026, 9, 7));
    expect(day.map((c) => '${c.name} ${c.startUnit}-${c.endUnit}'), [
      '高等数学 3-5',
      '大学物理 6-7',
    ]);
    expect(day.first.teachers, ['甲', '乙']);
    expect(day.first.timeSpanFormatted, '09:55 - 12:30 · 第3-5节');
  });

  test('a gap, another room or another course keeps sessions apart', () {
    final merged = mergeCourseSessions([
      session('高等数学', 1, 2),
      session('高等数学', 4, 5),
      session('高等数学', 6, 6, room: 'H2201'),
      session('线性代数', 7, 7),
      session('线性代数', 8, 8, weekday: 2),
    ]);
    expect(merged, hasLength(5));
  });

  test('weekly listings only merge sessions held in the same weeks', () {
    final weekly = mergeCourseSessions([
      session('高等数学', 1, 2, weeks: [1, 3]),
      session('高等数学', 3, 3, weeks: [2, 4]),
      session('高等数学', 1, 1, weekday: 3),
      session('高等数学', 2, 2, weekday: 3),
    ], sameWeeks: true);
    expect(weekly.map((c) => '${c.weekday}:${c.startUnit}-${c.endUnit}'), [
      '1:1-2',
      '1:3-3',
      '3:1-2',
    ]);
  });
}

// SPDX-License-Identifier: GPL-3.0-or-later
// Course-review (旦课) models adapted from DanXi lib/model/danke.
// Copyright (C) 2021 DanXi-Dev; GPL-3.0-or-later.
import '../../campus_api.dart';

int? _int(dynamic v) =>
    v is num ? v.toInt() : (v is String ? int.tryParse(v) : null);

String? _str(dynamic v) => v?.toString();

/// The four 1–5 grades of a review, as the server sends them.
class DankeRank {
  const DankeRank({this.overall, this.content, this.workload, this.assessment});
  final int? overall;
  final int? content;
  final int? workload;
  final int? assessment;

  factory DankeRank.fromJson(dynamic json) => json is Map
      ? DankeRank(
          overall: _int(json['overall']),
          content: _int(json['content']),
          workload: _int(json['workload']),
          assessment: _int(json['assessment']),
        )
      : const DankeRank();
}

class DankeReview {
  DankeReview({
    required this.id,
    this.reviewerId,
    this.title = '',
    this.content = '',
    this.timeCreated,
    this.rank = const DankeRank(),
    this.remark = 0,
    this.deleted = false,
    this.course,
    this.groupId,
  });

  final int id;
  final int? reviewerId;
  final String title;
  final String content;
  final String? timeCreated;
  final DankeRank rank;

  /// Net votes, as DanXi shows next to the thumb.
  final int remark;
  final bool deleted;

  /// The course offering the review is about (filled in from its group, or
  /// sent with a random review).
  DankeCourse? course;
  final int? groupId;

  factory DankeReview.fromJson(Map json) => DankeReview(
    id: _int(json['id']) ?? 0,
    reviewerId: _int(json['reviewer_id']),
    title: _str(json['title']) ?? '',
    content: _str(json['content']) ?? '',
    timeCreated: _str(json['timeCreated']),
    rank: DankeRank.fromJson(json['rank']),
    remark: _int(json['remark']) ?? 0,
    deleted: json['deleted'] == true,
    course: json['course'] is Map ? DankeCourse.fromJson(json['course']) : null,
    groupId: _int(json['group_id']),
  );
}

class DankeCourse {
  DankeCourse({
    required this.id,
    this.name = '',
    this.code = '',
    this.credit,
    this.department = '',
    this.teachers = '',
    this.year,
    this.semester,
    this.reviews = const [],
  });

  final int id;
  final String name;
  final String code;
  final double? credit;
  final String department;
  final String teachers;
  final int? year;
  final int? semester;
  final List<DankeReview> reviews;

  /// DanXi `Course.formatTime`: "2025~2026学年-秋季".
  String get time {
    final season = switch (semester ?? 0) {
      1 => '秋季',
      2 => '寒假',
      3 => '春季',
      4 => '暑假',
      _ => '未知',
    };
    final years = year == null ? '未知' : '$year~${year! + 1}';
    return '$years学年-$season';
  }

  factory DankeCourse.fromJson(Map json) {
    final course = DankeCourse(
      id: _int(json['id']) ?? 0,
      name: _str(json['name']) ?? '',
      code: _str(json['code']) ?? '',
      credit: (json['credit'] as num?)?.toDouble(),
      department: _str(json['department']) ?? '',
      teachers: _str(json['teachers']) ?? '',
      year: _int(json['year']),
      semester: _int(json['semester']),
      reviews: [
        for (final r in (json['review_list'] as List?) ?? const [])
          if (r is Map) DankeReview.fromJson(r),
      ],
    );
    for (final review in course.reviews) {
      review.course = course;
    }
    return course;
  }
}

class DankeCourseGroup {
  DankeCourseGroup({
    required this.id,
    this.name = '',
    this.code = '',
    this.department = '',
    this.credits = const [],
    this.courses = const [],
    this.courseCount,
    this.reviewCount,
  });

  final int id;
  final String name;
  final String code;
  final String department;
  final List<double> credits;
  final List<DankeCourse> courses;
  final int? courseCount;
  final int? reviewCount;

  /// DanXi `CourseGroup.getFullName`.
  String get fullName => '$department / $name';

  factory DankeCourseGroup.fromJson(Map json) => DankeCourseGroup(
    id: _int(json['id']) ?? 0,
    name: _str(json['name']) ?? '',
    code: _str(json['code']) ?? '',
    department: _str(json['department']) ?? '',
    credits: [
      for (final c in (json['credits'] as List?) ?? const [])
        if (c is num) c.toDouble(),
    ],
    courses: [
      for (final c in (json['course_list'] as List?) ?? const [])
        if (c is Map) DankeCourse.fromJson(c),
    ],
    courseCount: _int(json['course_count']),
    reviewCount: _int(json['review_count']),
  );
}

/// Reads DanXi's course reviews through the host, with the forum sign-in.
class DankeService {
  DankeService(this.api);
  final CampusApi api;

  static Map _payload(dynamic response) =>
      response is Map && response['payload'] is Map
      ? response['payload'] as Map
      : (response is Map ? response : const {});

  Future<DankeReview?> random() async {
    final payload = _payload(await api.call('community.danke.random'));
    return payload.isEmpty ? null : DankeReview.fromJson(payload);
  }

  /// One page of course groups; [next] is null on the last page.
  Future<({List<DankeCourseGroup> groups, int? next})> search(
    String query, {
    int page = 1,
    int pageSize = 20,
  }) async {
    final response = await api.call('community.danke.search', {
      'query': query,
      'page': page,
      'page_size': pageSize,
    });
    final records = response is Map ? response['records'] as List? : null;
    final coverage = response is Map ? response['coverage'] : null;
    final next = coverage is Map && coverage['Page'] is Map
        ? _int(coverage['Page']['next'])
        : null;
    return (
      groups: [
        for (final r in records ?? const [])
          if (r is Map && r['payload'] is Map)
            DankeCourseGroup.fromJson(r['payload'] as Map),
      ],
      next: next,
    );
  }

  Future<DankeCourseGroup> group(int id) async => DankeCourseGroup.fromJson(
    _payload(await api.call('community.danke.group', {'group_id': id})),
  );
}

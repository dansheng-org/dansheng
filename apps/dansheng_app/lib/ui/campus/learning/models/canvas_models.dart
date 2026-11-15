// SPDX-License-Identifier: GPL-3.0-or-later

/// Represents an enrolled Canvas/eLearning course.
class CanvasCourse {
  final String id;
  final String name;
  final String? courseCode;
  final String? workflowState;
  final String? termName;
  final String? termId;
  final DateTime? termStartsAt;
  final DateTime? termEndsAt;

  const CanvasCourse({
    required this.id,
    required this.name,
    this.courseCode,
    this.workflowState,
    this.termName,
    this.termId,
    this.termStartsAt,
    this.termEndsAt,
  });

  factory CanvasCourse.fromJson(Map<String, dynamic> json) {
    final payload = (json['payload'] is Map<String, dynamic>)
        ? json['payload'] as Map<String, dynamic>
        : json;

    final id =
        payload['id']?.toString() ?? payload['course_id']?.toString() ?? '';
    final name = payload['name']?.toString() ?? '未命名课程';
    final code = payload['course_code']?.toString();
    final state = payload['workflow_state']?.toString();

    final term = payload['term'] is Map<String, dynamic>
        ? payload['term'] as Map<String, dynamic>
        : const <String, dynamic>{};

    return CanvasCourse(
      id: id,
      name: name,
      courseCode: code,
      workflowState: state,
      termName: term['name']?.toString(),
      termId: term['id']?.toString(),
      termStartsAt: DateTime.tryParse(term['start_at']?.toString() ?? ''),
      termEndsAt: DateTime.tryParse(term['end_at']?.toString() ?? ''),
    );
  }

  /// Term dates take precedence; names and course codes cover undated terms.
  bool belongsToTerm(DateTime today, {String? academicTermName}) {
    final instant = DateTime.utc(
      today.year,
      today.month,
      today.day,
    ).subtract(const Duration(hours: 8));
    if (termStartsAt != null && instant.isBefore(termStartsAt!)) return false;
    if (termEndsAt != null && !instant.isBefore(termEndsAt!)) return false;
    if (termStartsAt != null && termEndsAt != null) return true;
    final key = termKey(termName) ?? termKey(courseCode) ?? termKey(name);
    final current =
        termKey(academicTermName) ??
        '${today.month >= 8 ? today.year : today.year - 1}:${today.month >= 8 || today.month == 1 ? 1 : 2}';
    return key != null && key == current;
  }

  /// Canonical academic year and semester, independent of Canvas/academic IDs.
  static String? termKey(String? value) {
    if (value == null) return null;
    final years = RegExp(r'(20\d{2})(?:\s*[-–—/]\s*(20\d{2}))?')
        .firstMatch(value);
    if (years == null) return null;
    var year = int.parse(years[1]!);
    final isYear = years[2] != null;
    int? term;
    if (RegExp(
      r'第一|第1|学年\s*1\s*学期|秋|fall|autumn',
      caseSensitive: false,
    ).hasMatch(value)) {
      term = 1;
    } else if (RegExp(
      r'第二|第2|学年\s*2\s*学期|春|spring',
      caseSensitive: false,
    ).hasMatch(value)) {
      term = 2;
    } else if (RegExp(
      r'第三|第3|学年\s*3\s*学期|夏|summer',
      caseSensitive: false,
    ).hasMatch(value)) {
      term = 3;
    } else if (isYear) {
      term = int.tryParse(
        RegExp(r'^\s*[-_/]\s*([123])(?:\D|$)')
                .firstMatch(value.substring(years.end))?[1] ??
            '',
      );
    }
    if (term == null) return null;
    if (!isYear && term != 1) year--;
    return '$year:$term';
  }
}

/// Represents a Canvas course assignment.
class CanvasAssignment {
  final String id;
  final String courseId;
  final String? courseName;
  final String name;
  final DateTime? dueAt;
  final double? pointsPossible;
  final List<String> submissionTypes;
  final bool hasSubmittedSubmissions;
  final bool lockedForUser;
  final String? description;
  final String? htmlUrl;

  const CanvasAssignment({
    required this.id,
    required this.courseId,
    this.courseName,
    required this.name,
    this.dueAt,
    this.pointsPossible,
    this.submissionTypes = const [],
    this.hasSubmittedSubmissions = false,
    this.lockedForUser = false,
    this.description,
    this.htmlUrl,
  });

  factory CanvasAssignment.fromJson(
    Map<String, dynamic> json, [
    String? defaultCourseId,
    String? defaultCourseName,
  ]) {
    final payload = (json['payload'] is Map<String, dynamic>)
        ? json['payload'] as Map<String, dynamic>
        : json;

    final id = payload['id']?.toString() ?? '';
    final courseId = payload['course_id']?.toString() ?? defaultCourseId ?? '';
    final name = payload['name']?.toString() ?? '未命名作业';

    DateTime? due;
    if (payload['due_at'] != null && payload['due_at'].toString().isNotEmpty) {
      try {
        due = DateTime.parse(payload['due_at'].toString()).toLocal();
      } catch (_) {}
    }

    double? points;
    if (payload['points_possible'] != null) {
      if (payload['points_possible'] is num) {
        points = (payload['points_possible'] as num).toDouble();
      } else {
        points = double.tryParse(payload['points_possible'].toString());
      }
    }

    List<String> subTypes = [];
    if (payload['submission_types'] is List) {
      subTypes = (payload['submission_types'] as List)
          .map((e) => e.toString())
          .toList();
    }

    final hasSub = payload['has_submitted_submissions'] == true;
    final locked = payload['locked_for_user'] == true;

    return CanvasAssignment(
      id: id,
      courseId: courseId,
      courseName: defaultCourseName,
      name: name,
      dueAt: due,
      pointsPossible: points,
      submissionTypes: subTypes,
      hasSubmittedSubmissions: hasSub,
      lockedForUser: locked,
      description: payload['description']?.toString(),
      htmlUrl: payload['html_url']?.toString(),
    );
  }

  /// Check if the assignment is due on a given local date.
  bool isDueOn(DateTime date) {
    if (dueAt == null) return false;
    final local = dueAt!.toUtc().add(const Duration(hours: 8));
    return local.year == date.year &&
        local.month == date.month &&
        local.day == date.day;
  }

  /// Concise Chinese formatted due string (e.g. "23:59 截止").
  String get dueTimeFormatted {
    if (dueAt == null) return '无截止时间';
    final local = dueAt!.toUtc().add(const Duration(hours: 8));
    final h = local.hour.toString().padLeft(2, '0');
    final m = local.minute.toString().padLeft(2, '0');
    return '$h:$m 截止';
  }

  /// Full Chinese formatted due date string (e.g. "11月8日 23:59").
  String get fullDueFormatted {
    if (dueAt == null) return '无截止时间';
    final local = dueAt!.toUtc().add(const Duration(hours: 8));
    final mo = local.month;
    final d = local.day;
    final h = local.hour.toString().padLeft(2, '0');
    final m = local.minute.toString().padLeft(2, '0');
    return '$mo月$d日 $h:$m';
  }
}

/// Represents a folder in Canvas files hierarchy.
class CanvasFolder {
  final String id;
  final String? parentFolderId;
  final String name;
  final int filesCount;
  final int foldersCount;

  const CanvasFolder({
    required this.id,
    this.parentFolderId,
    required this.name,
    this.filesCount = 0,
    this.foldersCount = 0,
  });

  factory CanvasFolder.fromJson(Map<String, dynamic> json) {
    final payload = (json['payload'] is Map<String, dynamic>)
        ? json['payload'] as Map<String, dynamic>
        : json;

    final id = payload['id']?.toString() ?? '';
    final parentId = payload['parent_folder_id']?.toString();
    final name = payload['name']?.toString() ?? '文件夹';

    final filesCount = (payload['files_count'] is int)
        ? payload['files_count'] as int
        : int.tryParse(payload['files_count']?.toString() ?? '0') ?? 0;
    final foldersCount = (payload['folders_count'] is int)
        ? payload['folders_count'] as int
        : int.tryParse(payload['folders_count']?.toString() ?? '0') ?? 0;

    return CanvasFolder(
      id: id,
      parentFolderId:
          (parentId != null && parentId.isNotEmpty && parentId != 'null')
          ? parentId
          : null,
      name: name,
      filesCount: filesCount,
      foldersCount: foldersCount,
    );
  }
}

/// Represents a downloadable file/material in Canvas.
class CanvasMaterial {
  final String id;
  final String? courseId;
  final String? folderId;
  final String displayName;
  final String filename;
  final String? contentType;
  final int? size;
  final DateTime? updatedAt;
  final bool lockedForUser;

  const CanvasMaterial({
    required this.id,
    this.courseId,
    this.folderId,
    required this.displayName,
    required this.filename,
    this.contentType,
    this.size,
    this.updatedAt,
    this.lockedForUser = false,
  });

  factory CanvasMaterial.fromJson(
    Map<String, dynamic> json, [
    String? defaultCourseId,
  ]) {
    final payload = (json['payload'] is Map<String, dynamic>)
        ? json['payload'] as Map<String, dynamic>
        : json;

    final id = payload['id']?.toString() ?? '';
    final courseId = payload['course_id']?.toString() ?? defaultCourseId;
    final folderId = payload['folder_id']?.toString();
    final displayName =
        payload['display_name']?.toString() ??
        payload['filename']?.toString() ??
        '文件';
    final filename = payload['filename']?.toString() ?? displayName;
    final contentType = (payload['content-type'] ?? payload['contentType'])
        ?.toString();

    int? size;
    if (payload['size'] != null) {
      if (payload['size'] is int) {
        size = payload['size'] as int;
      } else {
        size = int.tryParse(payload['size'].toString());
      }
    }

    DateTime? updated;
    if (payload['updated_at'] != null) {
      try {
        updated = DateTime.parse(payload['updated_at'].toString()).toLocal();
      } catch (_) {}
    }

    return CanvasMaterial(
      id: id,
      courseId: courseId,
      folderId: (folderId != null && folderId.isNotEmpty && folderId != 'null')
          ? folderId
          : null,
      displayName: displayName,
      filename: filename,
      contentType: contentType,
      size: size,
      updatedAt: updated,
      lockedForUser: payload['locked_for_user'] == true,
    );
  }

  /// Formatted size in B, KB, MB, GB.
  String get sizeFormatted {
    if (size == null) return '';
    final bytes = size!;
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

/// Represents a learning module in Canvas.
class CanvasModule {
  final String id;
  final String courseId;
  final String name;
  final int position;
  final int itemsCount;
  final String? state;

  const CanvasModule({
    required this.id,
    required this.courseId,
    required this.name,
    this.position = 0,
    this.itemsCount = 0,
    this.state,
  });

  factory CanvasModule.fromJson(
    Map<String, dynamic> json, [
    String? defaultCourseId,
  ]) {
    final payload = (json['payload'] is Map<String, dynamic>)
        ? json['payload'] as Map<String, dynamic>
        : json;

    final id = payload['id']?.toString() ?? '';
    final courseId = payload['course_id']?.toString() ?? defaultCourseId ?? '';
    final name = payload['name']?.toString() ?? '模块';
    final position = (payload['position'] is int)
        ? payload['position'] as int
        : int.tryParse(payload['position']?.toString() ?? '0') ?? 0;
    final itemsCount = (payload['items_count'] is int)
        ? payload['items_count'] as int
        : int.tryParse(payload['items_count']?.toString() ?? '0') ?? 0;
    final state =
        payload['state']?.toString() ?? payload['workflow_state']?.toString();

    return CanvasModule(
      id: id,
      courseId: courseId,
      name: name,
      position: position,
      itemsCount: itemsCount,
      state: state,
    );
  }
}

/// Represents a Canvas course announcement.
class CanvasAnnouncement {
  final String id;
  final String courseId;
  final String? courseName;
  final String title;
  final String? message;
  final DateTime? postedAt;
  final String? readState;
  final String? userName;

  const CanvasAnnouncement({
    required this.id,
    required this.courseId,
    this.courseName,
    required this.title,
    this.message,
    this.postedAt,
    this.readState,
    this.userName,
  });

  factory CanvasAnnouncement.fromJson(
    Map<String, dynamic> json, [
    String? defaultCourseId,
    String? defaultCourseName,
  ]) {
    final payload = (json['payload'] is Map<String, dynamic>)
        ? json['payload'] as Map<String, dynamic>
        : json;

    final id = payload['id']?.toString() ?? '';
    final courseId = payload['course_id']?.toString() ?? defaultCourseId ?? '';
    final title = payload['title']?.toString() ?? '无标题公告';

    DateTime? posted;
    if (payload['posted_at'] != null) {
      try {
        posted = DateTime.parse(payload['posted_at'].toString()).toLocal();
      } catch (_) {}
    }

    return CanvasAnnouncement(
      id: id,
      courseId: courseId,
      courseName: defaultCourseName,
      title: title,
      message: payload['message']?.toString(),
      postedAt: posted,
      readState: payload['read_state']?.toString(),
      userName: payload['user_name']?.toString(),
    );
  }

  /// Formatted posted date string (e.g. "11月1日 12:00").
  String get postedAtFormatted {
    if (postedAt == null) return '';
    final local = postedAt!.toLocal();
    final mo = local.month;
    final d = local.day;
    final h = local.hour.toString().padLeft(2, '0');
    final m = local.minute.toString().padLeft(2, '0');
    return '$mo月$d日 $h:$m';
  }
}

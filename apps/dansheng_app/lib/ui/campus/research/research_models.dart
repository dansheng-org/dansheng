// SPDX-License-Identifier: GPL-3.0-or-later

// A row of a department column (科研动态 or 讲座), read live from the
// department site. Many rows link to the department's WeChat article.
DateTime? _siteDate(Object? value) =>
    value is String ? DateTime.tryParse(value) : null;

String _siteDateText(Object? value) {
  final date = _siteDate(value);
  if (date == null) return '';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${date.year}-${two(date.month)}-${two(date.day)}';
}

/// A research news entry (科研动态) from a department column.
class ResearchNewsItem {
  final String id;
  final String title;
  final String department;
  final String publishDate; // yyyy-MM-dd
  final String category;
  final String url;

  const ResearchNewsItem({
    required this.id,
    required this.title,
    required this.department,
    required this.publishDate,
    required this.category,
    required this.url,
  });

  /// `{title, url, published_on}` as returned by `fudan.site.articles`.
  static ResearchNewsItem? fromSite(
    Map<String, dynamic> row, {
    required String department,
  }) {
    final title = row['title'];
    final url = row['url'];
    if (title is! String || title.isEmpty || url is! String) return null;
    return ResearchNewsItem(
      id: url,
      title: title,
      department: department,
      publishDate: _siteDateText(row['published_on']),
      category: categorize(title),
      url: url,
    );
  }

  static const categories = ['科研成果', '获奖荣誉', '学术交流', '院系动态'];

  /// A coarse topic from the headline; columns carry no category of their own.
  static String categorize(String title) {
    if (RegExp(r'喜报|荣获|获奖|获评|入选|当选|表彰|奖项|杰出|十大').hasMatch(title)) {
      return '获奖荣誉';
    }
    if (RegExp(
      r'Nature|Science|Cell|PNAS|JACS|Angew|Adv\.|Advanced|Lancet|Phys\. ?Rev|'
      r'成果|进展|突破|发表|刊发|团队|课题组|揭示|发现|实现|研制|提出|构建|首次',
    ).hasMatch(title)) {
      return '科研成果';
    }
    if (RegExp(r'讲座|论坛|会议|研讨|报告会|访问|来访|交流|学术').hasMatch(title)) {
      return '学术交流';
    }
    return '院系动态';
  }
}

/// A PI with an official homepage, listed as a research group (课题组).
class ResearchGroupItem {
  final String id;
  final String name; // 课题组名称 (the homepage's own group name if it has one)
  final String leader; // PI
  final String leaderTitle; // 职称 / 导师资格, may be empty
  final String department; // 院系 / 研究院
  final List<String> researchDirections;
  final String websiteUrl; // faculty.fudan.edu.cn homepage
  final bool isFollowed;

  const ResearchGroupItem({
    required this.id,
    required this.name,
    required this.leader,
    required this.leaderTitle,
    required this.department,
    required this.researchDirections,
    required this.websiteUrl,
    this.isFollowed = false,
  });

  /// A generated directory entry; the homepage URL identifies it.
  const ResearchGroupItem.directory({
    required this.name,
    required this.leader,
    required this.leaderTitle,
    required this.department,
    required this.researchDirections,
    required this.websiteUrl,
  }) : id = websiteUrl,
       isFollowed = false;

  ResearchGroupItem copyWith({bool? isFollowed}) => ResearchGroupItem(
    id: id,
    name: name,
    leader: leader,
    leaderTitle: leaderTitle,
    department: department,
    researchDirections: researchDirections,
    websiteUrl: websiteUrl,
    isFollowed: isFollowed ?? this.isFollowed,
  );
}

/// An academic lecture / seminar announcement from a department column.
class ResearchLectureItem {
  final String id;
  final String title;
  final String organizer; // the department publishing it
  final String publishDate; // yyyy-MM-dd
  final String category; // 人文社科 / 信息技术 / 物质前沿 / 生命健康
  final String url;
  final bool isBookmarked;

  const ResearchLectureItem({
    required this.id,
    required this.title,
    required this.organizer,
    required this.publishDate,
    required this.category,
    required this.url,
    this.isBookmarked = false,
  });

  static ResearchLectureItem? fromSite(
    Map<String, dynamic> row, {
    required String organizer,
    required String category,
  }) {
    final title = row['title'];
    final url = row['url'];
    if (title is! String || title.isEmpty || url is! String) return null;
    return ResearchLectureItem(
      id: url,
      title: title,
      organizer: organizer,
      publishDate: _siteDateText(row['published_on']),
      category: category,
      url: url,
    );
  }

  ResearchLectureItem copyWith({bool? isBookmarked}) => ResearchLectureItem(
    id: id,
    title: title,
    organizer: organizer,
    publishDate: publishDate,
    category: category,
    url: url,
    isBookmarked: isBookmarked ?? this.isBookmarked,
  );
}

/// Data model representing Fudan Undergraduate Research Opportunities Program (FDUROP) notices.
class FduropNoticeItem {
  final String id;
  final String title;
  final String program; // e.g. "望道/曦源", "莙政", "登峰", "全计划"
  final String publishDate;
  final String summary;
  final String content;
  final String source;
  final String? url;

  const FduropNoticeItem({
    required this.id,
    required this.title,
    required this.program,
    required this.publishDate,
    required this.summary,
    required this.content,
    this.source = '复旦大学本科生学术研究资助计划（FDUROP）',
    this.url,
  });

  FduropNoticeItem copyWith({
    String? id,
    String? title,
    String? program,
    String? publishDate,
    String? summary,
    String? content,
    String? source,
    String? url,
  }) {
    return FduropNoticeItem(
      id: id ?? this.id,
      title: title ?? this.title,
      program: program ?? this.program,
      publishDate: publishDate ?? this.publishDate,
      summary: summary ?? this.summary,
      content: content ?? this.content,
      source: source ?? this.source,
      url: url ?? this.url,
    );
  }
}

/// Data model representing an open research project recruitment for undergraduates (开放科研项目).
class FduropProjectItem {
  final String id;
  final String title; // 课题名称
  final String program; // 曦源项目 / 望道项目 / 莙政项目 / 登峰项目 / 开放自选课题
  final String advisor; // 指导教师
  final String advisorTitle; // 导师职称
  final String department; // 所属院系
  final String campus; // 所在校区
  final String targetGrade; // 面向年级与专业
  final int quota; // 招募人数
  final String deadline; // 申请截止时间
  final String status; // 招募中 / 已立项
  final String description; // 课题简介与研究背景
  final String requirements; // 申请要求与先修知识
  final String contactEmail; // 联系邮箱
  final String portalUrl; // 教师开放课题系统网址
  final bool isBookmarked; // 是否已收藏
  final String? tutorMobile; // 导师联系电话
  final String? tutorIntroduce; // 导师简介与成果
  final String? labIntroduce; // 实验室简介 / 主页链接
  final List<String> subjectKinds; // 学科门类
  final List<String> topicLabels; // 课题标签

  const FduropProjectItem({
    required this.id,
    required this.title,
    required this.program,
    required this.advisor,
    required this.advisorTitle,
    required this.department,
    required this.campus,
    required this.targetGrade,
    required this.quota,
    required this.deadline,
    this.status = '招募中',
    required this.description,
    required this.requirements,
    required this.contactEmail,
    this.portalUrl = 'https://paper.fudan.edu.cn/fdurop-pc/#/for-student/teacher-open-topic/index',
    this.isBookmarked = false,
    this.tutorMobile,
    this.tutorIntroduce,
    this.labIntroduce,
    this.subjectKinds = const [],
    this.topicLabels = const [],
  });

  factory FduropProjectItem.fromLiveJson(
    Map<String, dynamic> json, {
    bool isBookmarked = false,
  }) {
    final labels =
        (json['topic_labels'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        const <String>[];
    final subjects =
        (json['subject_kinds'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        const <String>[];
    final programName = labels.isNotEmpty
        ? labels.join(' / ')
        : (subjects.isNotEmpty ? subjects.join(' / ') : '开放课题');

    return FduropProjectItem(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      program: programName,
      advisor: json['teacher_name']?.toString() ?? '',
      advisorTitle:
          json['teacher_code'] != null &&
              json['teacher_code'].toString().isNotEmpty
          ? '教师编号: ${json['teacher_code']}'
          : '指导教师',
      department: json['department_name']?.toString() ?? '复旦大学',
      // The open-topic system publishes no campus, quota or deadline.
      campus: '',
      targetGrade: subjects.isNotEmpty ? subjects.join('、') : '本科各年级相关专业',
      quota: 0,
      deadline: '',
      status: '开放中',
      description: json['brief']?.toString() ?? '',
      requirements: json['requirement']?.toString() ?? '',
      contactEmail: json['tutor_email']?.toString() ?? '',
      portalUrl: 'https://paper.fudan.edu.cn/fdurop-pc/#/for-student/teacher-open-topic/index',
      isBookmarked: isBookmarked,
      tutorMobile: json['tutor_mobile']?.toString(),
      tutorIntroduce: json['tutor_introduce']?.toString(),
      labIntroduce: json['lab_introduce']?.toString(),
      subjectKinds: subjects,
      topicLabels: labels,
    );
  }

  FduropProjectItem copyWith({
    String? id,
    String? title,
    String? program,
    String? advisor,
    String? advisorTitle,
    String? department,
    String? campus,
    String? targetGrade,
    int? quota,
    String? deadline,
    String? status,
    String? description,
    String? requirements,
    String? contactEmail,
    String? portalUrl,
    bool? isBookmarked,
    String? tutorMobile,
    String? tutorIntroduce,
    String? labIntroduce,
    List<String>? subjectKinds,
    List<String>? topicLabels,
  }) {
    return FduropProjectItem(
      id: id ?? this.id,
      title: title ?? this.title,
      program: program ?? this.program,
      advisor: advisor ?? this.advisor,
      advisorTitle: advisorTitle ?? this.advisorTitle,
      department: department ?? this.department,
      campus: campus ?? this.campus,
      targetGrade: targetGrade ?? this.targetGrade,
      quota: quota ?? this.quota,
      deadline: deadline ?? this.deadline,
      status: status ?? this.status,
      description: description ?? this.description,
      requirements: requirements ?? this.requirements,
      contactEmail: contactEmail ?? this.contactEmail,
      portalUrl: portalUrl ?? this.portalUrl,
      isBookmarked: isBookmarked ?? this.isBookmarked,
      tutorMobile: tutorMobile ?? this.tutorMobile,
      tutorIntroduce: tutorIntroduce ?? this.tutorIntroduce,
      labIntroduce: labIntroduce ?? this.labIntroduce,
      subjectKinds: subjectKinds ?? this.subjectKinds,
      topicLabels: topicLabels ?? this.topicLabels,
    );
  }

  /// Check whether this project matches a given text query.
  bool matchesQuery(String? q) {
    if (q == null || q.trim().isEmpty) return true;
    final term = q.trim().toLowerCase();
    return title.toLowerCase().contains(term) ||
        advisor.toLowerCase().contains(term) ||
        advisorTitle.toLowerCase().contains(term) ||
        department.toLowerCase().contains(term) ||
        description.toLowerCase().contains(term) ||
        requirements.toLowerCase().contains(term) ||
        subjectKinds.any((s) => s.toLowerCase().contains(term)) ||
        topicLabels.any((l) => l.toLowerCase().contains(term));
  }

  /// Check whether this project matches a given subject discipline kind.
  bool matchesSubjectKind(String? kind) {
    if (kind == null || kind == '全部') return true;
    return subjectKinds.any((s) => s.contains(kind)) || program.contains(kind);
  }

  /// Check whether this project matches a given topic label / funding source.
  bool matchesTopicLabel(String? label) {
    if (label == null || label == '全部') return true;
    return topicLabels.any((l) => l.contains(label)) || program.contains(label);
  }
}

/// One page of FDUROP open topics, from paper.fudan.edu.cn or the offline seed.
class FduropProjectPage {
  final List<FduropProjectItem> items;
  final int page;
  final int pageSize;

  /// Total matching topics. For a live keyword search it is an upper bound,
  /// because the title and teacher matches are counted separately.
  final int total;
  final bool hasMore;

  /// Whether the rows came from the live open-topic system.
  final bool isLive;

  /// Why the live system could not be used, when the seed was served instead.
  final String? liveError;

  const FduropProjectPage({
    required this.items,
    required this.page,
    required this.pageSize,
    required this.total,
    required this.hasMore,
    required this.isLive,
    this.liveError,
  });
}

/// One FDUROP form or resource attached to the official AAO pages
/// (jwc.fudan.edu.cn 常用文档 · 复芏计划（FDUROP）相关表格).
class FduropDocumentItem {
  /// The attachment URL; stable across listings.
  final String id;

  /// Display title without the numbering prefix, stage tag and extension.
  final String title;

  /// Stage derived from the 【立项】/【中期】/... tag of the official name.
  final String category;

  /// Upper-case extension, e.g. DOCX / PDF / XLSX / PPTX.
  final String fileFormat;

  /// The official file name, used as the downloaded file's name.
  final String fileName;
  final String downloadUrl;

  const FduropDocumentItem({
    required this.id,
    required this.title,
    required this.category,
    required this.fileFormat,
    required this.fileName,
    required this.downloadUrl,
  });

  static const Map<String, String> _stages = {
    '立项': '立项申报',
    '中期': '中期检查',
    '结题': '结题评审',
    '财务': '经费管理',
    '资源': '学术资源',
  };

  /// Display categories in the order of the official list.
  static const List<String> categories = [
    '立项申报',
    '中期检查',
    '结题评审',
    '经费管理',
    '学术资源',
    '其他',
  ];

  /// Parses an attachment such as
  /// `1-a.【立项】䇹政项目申请书模板（2025年）.docx`.
  factory FduropDocumentItem.fromAttachment(String name, String url) {
    var rest = name.trim();
    final dot = rest.lastIndexOf('.');
    final ext = dot > 0 && rest.length - dot <= 6
        ? rest.substring(dot + 1).toUpperCase()
        : '';
    if (ext.isNotEmpty) rest = rest.substring(0, dot);
    // Leading numbering: "1-a." / "5." / "4-b、".
    rest = rest.replaceFirst(RegExp(r'^\d+(-[a-zA-Z])?[.、．]\s*'), '');
    var category = '其他';
    final tag = RegExp(r'^【([^】]{1,8})】').firstMatch(rest);
    if (tag != null) {
      category = _stages[tag.group(1)] ?? '其他';
      rest = rest.substring(tag.end).trim();
    }
    return FduropDocumentItem(
      id: url,
      title: rest.isEmpty ? name : rest,
      category: category,
      fileFormat: ext,
      fileName: name,
      downloadUrl: url,
    );
  }
}

/// A public department column read through `fudan.site.articles`.
class ResearchSiteColumn {
  final String department;
  final String url;
  final String category; // lecture category; unused for news

  const ResearchSiteColumn(this.department, this.url, [this.category = '']);
}

/// Merged rows of several columns, and how many columns could not be read.
class SiteFeedResult<T> {
  final List<T> items;
  final int failedColumns;

  const SiteFeedResult(this.items, this.failedColumns);
}

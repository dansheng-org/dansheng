// SPDX-License-Identifier: GPL-3.0-or-later

/// Data model representing a Fudan research news article or announcement.
class ResearchNewsItem {
  final String id;
  final String title;
  final String summary;
  final String content;
  final String source; // e.g. "科学技术研究院", "脑科学前沿科学中心"
  final String department; // e.g. "计算机科学技术学院", "微电子学院"
  final String publishDate; // e.g. "2026-11-15"
  final String category; // e.g. "科研突破", "项目申报", "学术讲座", "招募招生"
  final int readCount;
  final bool isPinned;
  final String? url;

  const ResearchNewsItem({
    required this.id,
    required this.title,
    required this.summary,
    required this.content,
    required this.source,
    required this.department,
    required this.publishDate,
    required this.category,
    this.readCount = 0,
    this.isPinned = false,
    this.url,
  });

  ResearchNewsItem copyWith({
    String? id,
    String? title,
    String? summary,
    String? content,
    String? source,
    String? department,
    String? publishDate,
    String? category,
    int? readCount,
    bool? isPinned,
    String? url,
  }) {
    return ResearchNewsItem(
      id: id ?? this.id,
      title: title ?? this.title,
      summary: summary ?? this.summary,
      content: content ?? this.content,
      source: source ?? this.source,
      department: department ?? this.department,
      publishDate: publishDate ?? this.publishDate,
      category: category ?? this.category,
      readCount: readCount ?? this.readCount,
      isPinned: isPinned ?? this.isPinned,
      url: url ?? this.url,
    );
  }
}

/// Data model representing a research group / lab (课题组) at Fudan.
class ResearchGroupItem {
  final String id;
  final String name; // 课题组名称
  final String leader; // PI / 导师 / 团队带头人
  final String leaderTitle; // 头衔职称
  final String department; // 院系 / 重点实验室
  final String campus; // 校区 (邯郸/江湾/枫林/张江)
  final List<String> researchDirections; // 研究方向标签
  final String description; // 课题组介绍
  final List<String> recentPapers; // 代表性论文与成果
  final String? recruitment; // 招生与招聘信息 (直博生/联培硕士/博士后)
  final String contactEmail; // 联系邮箱
  final String labLocation; // 实验室地址
  final String websiteUrl; // 课题组官方网站 / 导师主页 (复旦域名 *.fudan.edu.cn)
  final bool isFollowed; // 是否已关注

  const ResearchGroupItem({
    required this.id,
    required this.name,
    required this.leader,
    required this.leaderTitle,
    required this.department,
    required this.campus,
    required this.researchDirections,
    required this.description,
    required this.recentPapers,
    this.recruitment,
    required this.contactEmail,
    required this.labLocation,
    this.websiteUrl = '',
    this.isFollowed = false,
  });

  ResearchGroupItem copyWith({
    String? id,
    String? name,
    String? leader,
    String? leaderTitle,
    String? department,
    String? campus,
    List<String>? researchDirections,
    String? description,
    List<String>? recentPapers,
    String? recruitment,
    String? contactEmail,
    String? labLocation,
    String? websiteUrl,
    bool? isFollowed,
  }) {
    return ResearchGroupItem(
      id: id ?? this.id,
      name: name ?? this.name,
      leader: leader ?? this.leader,
      leaderTitle: leaderTitle ?? this.leaderTitle,
      department: department ?? this.department,
      campus: campus ?? this.campus,
      researchDirections: researchDirections ?? this.researchDirections,
      description: description ?? this.description,
      recentPapers: recentPapers ?? this.recentPapers,
      recruitment: recruitment ?? this.recruitment,
      contactEmail: contactEmail ?? this.contactEmail,
      labLocation: labLocation ?? this.labLocation,
      websiteUrl: websiteUrl ?? this.websiteUrl,
      isFollowed: isFollowed ?? this.isFollowed,
    );
  }
}

/// Data model representing an academic seminar or lecture.
class ResearchLectureItem {
  final String id;
  final String title;
  final String speaker;
  final String speakerTitle;
  final String time;
  final String venue;
  final String organizer;
  final String description;
  final String campus;
  final String category; // 人文社科 / 物质前沿 / 信息技术 / 生命健康 / 通识名家
  final bool isBookmarked;

  const ResearchLectureItem({
    required this.id,
    required this.title,
    required this.speaker,
    required this.speakerTitle,
    required this.time,
    required this.venue,
    required this.organizer,
    required this.description,
    this.campus = '邯郸校区',
    this.category = '通识名家',
    this.isBookmarked = false,
  });

  ResearchLectureItem copyWith({
    String? id,
    String? title,
    String? speaker,
    String? speakerTitle,
    String? time,
    String? venue,
    String? organizer,
    String? description,
    String? campus,
    String? category,
    bool? isBookmarked,
  }) {
    return ResearchLectureItem(
      id: id ?? this.id,
      title: title ?? this.title,
      speaker: speaker ?? this.speaker,
      speakerTitle: speakerTitle ?? this.speakerTitle,
      time: time ?? this.time,
      venue: venue ?? this.venue,
      organizer: organizer ?? this.organizer,
      description: description ?? this.description,
      campus: campus ?? this.campus,
      category: category ?? this.category,
      isBookmarked: isBookmarked ?? this.isBookmarked,
    );
  }
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

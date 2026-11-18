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
  });

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
    );
  }
}

/// Data model representing downloadable documents from FDUROP (相关文件下载).
class FduropDocumentItem {
  final String id;
  final String title; // 文件名
  final String category; // 申报指南 / 立项申请 / 中期检查 / 结题评审 / 经费管理
  final String fileFormat; // DOCX / PDF / ZIP / XLSX
  final String fileSize; // e.g. "340 KB"
  final String updateDate;
  final String downloadUrl;
  final bool isDownloaded;

  const FduropDocumentItem({
    required this.id,
    required this.title,
    required this.category,
    required this.fileFormat,
    required this.fileSize,
    required this.updateDate,
    required this.downloadUrl,
    this.isDownloaded = false,
  });

  FduropDocumentItem copyWith({
    String? id,
    String? title,
    String? category,
    String? fileFormat,
    String? fileSize,
    String? updateDate,
    String? downloadUrl,
    bool? isDownloaded,
  }) {
    return FduropDocumentItem(
      id: id ?? this.id,
      title: title ?? this.title,
      category: category ?? this.category,
      fileFormat: fileFormat ?? this.fileFormat,
      fileSize: fileSize ?? this.fileSize,
      updateDate: updateDate ?? this.updateDate,
      downloadUrl: downloadUrl ?? this.downloadUrl,
      isDownloaded: isDownloaded ?? this.isDownloaded,
    );
  }
}

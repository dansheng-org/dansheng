// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/foundation.dart';

import '../campus_api.dart';
import 'fdurop_seed_data.dart';
import 'research_group_directory.dart';
import 'research_models.dart';

/// Service providing Fudan University research news, research groups (课题组),
/// academic lectures, and FDUROP (本科生科研/望道/莙政/开放课题与文件下载).
class ResearchService extends ChangeNotifier {
  static final ResearchService instance = ResearchService._();
  ResearchService._();

  CampusApi? _api;

  // Live paper.fudan.edu.cn caches, scoped to the bound API (and so to the account).
  Future<Map<String, String>>? _liveSubjectIds;
  Future<Map<String, String>>? _liveLabelIds;
  final Map<String, FduropProjectItem> _fduropDetailCache = {};
  // Official FDUROP files: the listing, and the managed asset of each file
  // fetched this session (Core keeps the bytes; reopening needs no download).
  List<FduropDocumentItem>? _fduropDocuments;
  final Map<String, String> _fduropDocAssets = {};

  /// Bind or unbind the authenticated campus API port from the host session.
  void bindApi(CampusApi? api) {
    // Unbinding (sign-out) or another account drops everything read so far.
    if (api == null ||
        (!identical(api, _api) &&
            api.accountScope?.accountId != _api?.accountScope?.accountId)) {
      _fduropDocuments = null;
      _fduropDocAssets.clear();
      _news = null;
      _lectures = null;
      _newsLoad = null;
      _lectureLoad = null;
    }
    _api = api;
    _liveSubjectIds = null;
    _liveLabelIds = null;
    _fduropDetailCache.clear();
  }

  // In-memory persistent states
  final Set<String> _followedGroupIds = {};
  final Set<String> _bookmarkedLectureIds = {};
  final Set<String> _bookmarkedFduropProjectIds = {'fdurop_p1'};

  Set<String> get followedGroupIds => Set.unmodifiable(_followedGroupIds);
  Set<String> get bookmarkedLectureIds =>
      Set.unmodifiable(_bookmarkedLectureIds);
  Set<String> get bookmarkedFduropProjectIds =>
      Set.unmodifiable(_bookmarkedFduropProjectIds);

  bool isGroupFollowed(String id) => _followedGroupIds.contains(id);
  bool isLectureBookmarked(String id) => _bookmarkedLectureIds.contains(id);
  bool isFduropProjectBookmarked(String id) =>
      _bookmarkedFduropProjectIds.contains(id);

  /// Toggle follow state for a research group.
  void toggleFollowGroup(String id) {
    if (_followedGroupIds.contains(id)) {
      _followedGroupIds.remove(id);
    } else {
      _followedGroupIds.add(id);
    }
    notifyListeners();
  }

  /// Toggle bookmark state for an academic lecture.
  void toggleBookmarkLecture(String id) {
    if (_bookmarkedLectureIds.contains(id)) {
      _bookmarkedLectureIds.remove(id);
    } else {
      _bookmarkedLectureIds.add(id);
    }
    notifyListeners();
  }

  /// Toggle bookmark state for an FDUROP project.
  void toggleBookmarkFduropProject(String id) {
    if (_bookmarkedFduropProjectIds.contains(id)) {
      _bookmarkedFduropProjectIds.remove(id);
    } else {
      _bookmarkedFduropProjectIds.add(id);
    }
    notifyListeners();
  }

  // =========================================================================
  // 1–3. 科研动态 / 学术讲座 (live department columns) and 课题组 (directory)
  // =========================================================================

  /// 科研动态 columns of the department sites, read through
  /// `fudan.site.articles`. Several columns link straight to the department's
  /// WeChat article, so official-account posts arrive with them.
  static const List<ResearchSiteColumn> newsColumns = [
    ResearchSiteColumn('复旦大学', 'https://news.fudan.edu.cn/235/list.htm'),
    ResearchSiteColumn('中国语言文学系', 'https://chinese.fudan.edu.cn/kydt/list.htm'),
    ResearchSiteColumn('哲学学院', 'https://philosophy.fudan.edu.cn/kydt/list.htm'),
    ResearchSiteColumn('法学院', 'https://law.fudan.edu.cn/27189/list.htm'),
    ResearchSiteColumn('经济学院', 'https://econ.fudan.edu.cn/kxyj1/kydt1.htm'),
    ResearchSiteColumn('旅游学系', 'https://tourism.fudan.edu.cn/xsky/kycg1.htm'),
    ResearchSiteColumn('数学科学学院', 'https://math.fudan.edu.cn/30298/list.htm'),
    ResearchSiteColumn('化学系', 'https://chemistry.fudan.edu.cn/45122/list.htm'),
    ResearchSiteColumn('高分子科学系', 'https://polymer.fudan.edu.cn/31392/list.htm'),
    ResearchSiteColumn(
      '大气与海洋科学系',
      'https://aos.fudan.edu.cn/research_news/list.htm',
    ),
    ResearchSiteColumn('航空航天系', 'https://aero-mech.fudan.edu.cn/kykx/list.htm'),
    ResearchSiteColumn('微电子学院', 'https://sme.fudan.edu.cn/29431/list.htm'),
    ResearchSiteColumn(
      '集成电路与微纳电子创新学院',
      'https://icmne.fudan.edu.cn/kydt_48987/list.htm',
    ),
    ResearchSiteColumn('计算与智能创新学院', 'https://ai.fudan.edu.cn/24280/list.htm'),
    ResearchSiteColumn('未来信息创新学院', 'https://fit.fudan.edu.cn/Data/List/kycg'),
    ResearchSiteColumn(
      '智能材料与未来能源创新学院',
      'https://icome.fudan.edu.cn/49277/list.htm',
    ),
    ResearchSiteColumn('药学院', 'https://spfdu.fudan.edu.cn/41398/list.htm'),
  ];

  /// 讲座 / 学术活动 columns, with the lecture category of each department.
  static const List<ResearchSiteColumn> lectureColumns = [
    ResearchSiteColumn(
      '中国语言文学系',
      'https://chinese.fudan.edu.cn/jztg/list.htm',
      '人文社科',
    ),
    ResearchSiteColumn(
      '哲学学院',
      'https://philosophy.fudan.edu.cn/jzhy/list.htm',
      '人文社科',
    ),
    ResearchSiteColumn(
      '历史学系',
      'https://history.fudan.edu.cn/xsky/xshd.htm',
      '人文社科',
    ),
    ResearchSiteColumn(
      '外国语言文学学院',
      'https://dfll.fudan.edu.cn/27753/list.htm',
      '人文社科',
    ),
    ResearchSiteColumn(
      '国际关系与公共事务学院',
      'https://sirpa.fudan.edu.cn/35122/list.htm',
      '人文社科',
    ),
    ResearchSiteColumn(
      '经济学院',
      'https://econ.fudan.edu.cn/kxyj1/jzhyyg/xshy.htm',
      '人文社科',
    ),
    ResearchSiteColumn(
      '旅游学系',
      'https://tourism.fudan.edu.cn/xsky/hdjz.htm',
      '人文社科',
    ),
    ResearchSiteColumn(
      '现代物理研究所',
      'https://imp.fudan.edu.cn/48891/list.htm',
      '物质前沿',
    ),
    ResearchSiteColumn(
      '化学系',
      'https://chemistry.fudan.edu.cn/45457/list.htm',
      '物质前沿',
    ),
    ResearchSiteColumn(
      '航空航天系',
      'https://aero-mech.fudan.edu.cn/ghqnxzlt/list.htm',
      '物质前沿',
    ),
    ResearchSiteColumn(
      '智能材料与未来能源创新学院',
      'https://icome.fudan.edu.cn/49264/list.htm',
      '物质前沿',
    ),
    ResearchSiteColumn(
      '集成电路与微纳电子创新学院',
      'https://icmne.fudan.edu.cn/jzxx/list.htm',
      '信息技术',
    ),
    ResearchSiteColumn(
      '药学院',
      'https://spfdu.fudan.edu.cn/41399/list.htm',
      '生命健康',
    ),
  ];

  List<ResearchNewsItem>? _news;
  List<ResearchLectureItem>? _lectures;
  Future<SiteFeedResult<ResearchNewsItem>>? _newsLoad;
  Future<SiteFeedResult<ResearchLectureItem>>? _lectureLoad;
  int _newsFailedColumns = 0;
  int _lectureFailedColumns = 0;

  /// Whether the live columns have been read this session.
  bool get hasNews => _news != null;
  bool get hasLectures => _lectures != null;
  int get newsFailedColumns => _newsFailedColumns;
  int get lectureFailedColumns => _lectureFailedColumns;

  /// Read every 科研动态 column and merge them newest first. One failing site
  /// leaves the others; every site failing is an error.
  Future<SiteFeedResult<ResearchNewsItem>> fetchNews({bool refresh = false}) {
    final pending = _newsLoad;
    if (!refresh && pending != null) return pending;
    final api = _api;
    final load = _readColumns<ResearchNewsItem>(
      api,
      newsColumns,
      (row, column) =>
          ResearchNewsItem.fromSite(row, department: column.department),
    );
    _newsLoad = load;
    return load.then(
      (result) {
        if (identical(api, _api)) {
          _news = result.items;
          _newsFailedColumns = result.failedColumns;
        }
        return result;
      },
      onError: (Object e) {
        if (identical(_newsLoad, load)) _newsLoad = null;
        throw e;
      },
    );
  }

  Future<SiteFeedResult<ResearchLectureItem>> fetchLectures({
    bool refresh = false,
  }) {
    final pending = _lectureLoad;
    if (!refresh && pending != null) return pending;
    final api = _api;
    final load = _readColumns<ResearchLectureItem>(
      api,
      lectureColumns,
      (row, column) => ResearchLectureItem.fromSite(
        row,
        organizer: column.department,
        category: column.category,
      ),
    );
    _lectureLoad = load;
    return load.then(
      (result) {
        if (identical(api, _api)) {
          _lectures = result.items;
          _lectureFailedColumns = result.failedColumns;
        }
        return result;
      },
      onError: (Object e) {
        if (identical(_lectureLoad, load)) _lectureLoad = null;
        throw e;
      },
    );
  }

  /// Six sites are read at a time; rows are de-duplicated by URL.
  static Future<SiteFeedResult<T>> _readColumns<T>(
    CampusApi? api,
    List<ResearchSiteColumn> columns,
    T? Function(Map<String, dynamic> row, ResearchSiteColumn column) parse,
  ) async {
    if (api == null) throw StateError('请先登录复旦账号');
    final rows = <T>[];
    final seen = <String>{};
    var failed = 0;
    Object? lastError;
    var next = 0;
    Future<void> worker() async {
      while (next < columns.length) {
        final column = columns[next++];
        try {
          final res = await api.call('fudan.site.articles', {
            'url': column.url,
          });
          if (res is! List) throw const FormatException('column');
          for (final row in res.whereType<Map>()) {
            final item = parse(Map<String, dynamic>.from(row), column);
            if (item != null && seen.add(_idOf(item))) rows.add(item);
          }
        } catch (e) {
          failed++;
          lastError = e;
        }
      }
    }

    await Future.wait(List.generate(6, (_) => worker()));
    if (failed == columns.length) {
      throw lastError ?? StateError('无法读取院系网站');
    }
    rows.sort((a, b) => _dateOf(b).compareTo(_dateOf(a)));
    return SiteFeedResult(rows, failed);
  }

  static String _idOf(Object? item) => switch (item) {
    ResearchNewsItem(:final id) => id,
    ResearchLectureItem(:final id) => id,
    _ => '$item',
  };

  static String _dateOf(Object? item) => switch (item) {
    ResearchNewsItem(:final publishDate) => publishDate,
    ResearchLectureItem(:final publishDate) => publishDate,
    _ => '',
  };

  /// Open a department article (or the WeChat post it links) in the browser.
  Future<void> openLink(String url) async {
    final api = _api;
    if (api == null) throw StateError('请先登录复旦账号');
    await api.call('campus.openLink', {'url': url});
  }

  // =========================================================================
  // 4. FDUROP 网站通知数据 (FDUROP Notices)
  // =========================================================================
  static const List<FduropNoticeItem> _initialFduropNotices = [
    FduropNoticeItem(
      id: 'fdurop_n1',
      title: '关于启动2026-2027学年第一学期本科生学术研究资助计划（FDUROP）立项申报的通知',
      program: '望道/曦源',
      publishDate: '2026-10-18',
      summary: '涵盖“曦源项目”、“望道学者”、“登峰项目”，面向大二、大三全日制本科生开放系统填报，11月25日截止导师线上确认。',
      content: '为进一步营造浓郁本科生学术研究氛围，教务处拔尖人才培养办公室即日起启动2026-2027学年秋季学期复旦大学本科生学术研究资助计划（FDUROP）申报工作。曦源项目资助强度为每项1.0万元，望道学者项目资助强度为每项1.5万元，登峰计划每项资助最高2.5万元。申请人需在FDUROP管理系统完成《立项申请书》填报，并联系指导教师完成推荐确认。学生亦可登录 FDUROP 教师开放课题系统 (paper.fudan.edu.cn) 挑选心仪导师与课题。',
      url: 'http://www.fdurop.fudan.edu.cn/notices/20261018-declare',
    ),
    FduropNoticeItem(
      id: 'fdurop_n_portal',
      title: '关于开通“FDUROP 教师开放课题申报与学生双选系统”的温馨提示',
      program: '全计划',
      publishDate: '2026-10-20',
      summary: '指导教师可随时在线发布开放研究课题，本科生可通过统一身份认证 UIS 登录系统查看并申请课题：paper.fudan.edu.cn/fdurop-pc。',
      content: '为打破院系壁垒，强化师生科研双向互选，复旦大学教务处已全面升级“FDUROP 教师开放课题平台”（访问网址：https://paper.fudan.edu.cn/fdurop-pc/#/for-student/teacher-open-topic/index）。全校各学科教授、研究员均已陆续在平台录入最新前沿课题；有志于申报莙政、望道、曦源、登辉项目的同学请及时登录查阅，并与导师邮件联络确认。',
      url: 'https://paper.fudan.edu.cn/fdurop-pc/#/for-student/teacher-open-topic/index',
    ),
    FduropNoticeItem(
      id: 'fdurop_n2',
      title: '关于开展2026年度复旦大学“莙政学者”项目结题答辩与优秀成果评选的通知',
      program: '莙政',
      publishDate: '2026-10-25',
      summary: '定于11月28日在邯郸校区光华楼举行现场学术汇报会，评选年度“优秀莙政学者”并颁发证书。',
      content: '各莙政学者项目组：2026年度李政道先生设立的“莙政学者”科研训练项目已进入收尾结题阶段。请各项目负责人于11月20日前在系统提交结题学术论文（按要求格式排版）、查重报告及财务报销明细表。各学科评审组将安排现场答辩与墙报展示，欢迎全校师生观摩旁听。',
      url: 'http://www.fdurop.fudan.edu.cn/notices/20261025-junzheng',
    ),
    FduropNoticeItem(
      id: 'fdurop_n3',
      title: '第十四届复旦大学本科生学术研究论坛暨FDUROP年会征文与报告通知',
      program: '全计划',
      publishDate: '2026-11-02',
      summary: '大会设自然科学、工程技术、人文社科、医学交叉4个分论坛，优秀论文将汇编成册入选校史文献库。',
      content: '复旦大学本科生学术研究论坛每年举办一届，旨在为广大致力于前沿探索的本科生搭建跨校区、跨学科的高水平学术交流舞台。征文范围覆盖所有正在执行或已结题的FDUROP项目研究成果，入选口头报告者将获颁优秀学术演讲证书。',
      url: 'http://www.fdurop.fudan.edu.cn/forum/2026-annual',
    ),
    FduropNoticeItem(
      id: 'fdurop_n4',
      title: '关于组织2026年秋季学期“望道项目”中期进展报告提交与核查的通知',
      program: '望道',
      publishDate: '2026-11-06',
      summary: '请各项目负责人登录系统下载并填写《中期进展检查表》，由导师签署进展评估意见后扫描上传。',
      content: '望道学者项目执行期过半，中期考核是保证科研质量的关键环节。教务处将对实验进度缓慢、阶段成果不足的项目安排学术督导沟通。请于11月30日前完成系统提交。',
      url: 'http://www.fdurop.fudan.edu.cn/notices/20261106-midterm',
    ),
    FduropNoticeItem(
      id: 'fdurop_n5',
      title: '2026年度FDUROP交叉学科专项与登峰新工科计划立项评审结果公示',
      program: '登峰',
      publishDate: '2026-11-12',
      summary: '经专家委员会初审与现场双盲评审，共计42项交叉创新课题获得立项资助，现予以校内公示。',
      content: '本次交叉学科专项聚焦“人工智能赋能人文社科”与“医工交叉诊疗技术”两大前沿领域，共有来自18个院系的本科生团队脱颖而出。公示期为5个工作日。',
      url: 'http://www.fdurop.fudan.edu.cn/results/2026-interdisciplinary',
    ),
  ];

  // =========================================================================
  // 5. 开放科研项目数据 (Open Research Projects - 来源于 paper.fudan.edu.cn 教师开放课题系统与院系招募)
  // =========================================================================
  static const List<FduropProjectItem> _initialFduropProjects =
      initialFduropProjects;

  // =========================================================================
  // Query APIs
  // =========================================================================

  static bool _matches(String query, Iterable<String> fields) {
    final q = query.trim().toLowerCase();
    return q.isEmpty || fields.any((f) => f.toLowerCase().contains(q));
  }

  /// The loaded 科研动态, filtered by topic and keyword.
  List<ResearchNewsItem> getNews({String? category, String query = ''}) =>
      (_news ?? const <ResearchNewsItem>[])
          .where(
            (item) =>
                (category == null ||
                    category == '全部' ||
                    item.category == category) &&
                _matches(query, [item.title, item.department]),
          )
          .toList();

  /// The 课题组 directory with follow state, filtered.
  List<ResearchGroupItem> getGroups({
    bool followedOnly = false,
    String? department,
    String query = '',
  }) => [
    for (final group in researchGroupDirectory)
      if ((!followedOnly || _followedGroupIds.contains(group.id)) &&
          (department == null ||
              department == '全部' ||
              group.department == department) &&
          _matches(query, [
            group.name,
            group.leader,
            group.department,
            ...group.researchDirections,
          ]))
        group.copyWith(isFollowed: _followedGroupIds.contains(group.id)),
  ];

  /// The loaded lectures with bookmark state, filtered.
  List<ResearchLectureItem> getLectures({
    String query = '',
    String? category,
    bool bookmarkedOnly = false,
  }) => [
    for (final lec in _lectures ?? const <ResearchLectureItem>[])
      if ((!bookmarkedOnly || _bookmarkedLectureIds.contains(lec.id)) &&
          (category == null || category == '全部' || lec.category == category) &&
          _matches(query, [lec.title, lec.organizer]))
        lec.copyWith(isBookmarked: _bookmarkedLectureIds.contains(lec.id)),
  ];

  /// Get FDUROP website notices.
  Future<List<FduropNoticeItem>> getFduropNotices({
    String? program,
    String? query,
  }) async {
    return _initialFduropNotices.where((notice) {
      if (program != null &&
          program != '全部' &&
          !notice.program.contains(program)) {
        return false;
      }
      if (query != null && query.trim().isNotEmpty) {
        final q = query.trim().toLowerCase();
        final matchTitle = notice.title.toLowerCase().contains(q);
        final matchSummary = notice.summary.toLowerCase().contains(q);
        if (!matchTitle && !matchSummary) {
          return false;
        }
      }
      return true;
    }).toList();
  }

  /// Default number of open topics fetched per page.
  static const int fduropPageSize = 20;

  static final Map<String, FduropProjectItem> _seedProjectsById = {
    for (final p in _initialFduropProjects) p.id: p,
  };

  /// Fetch one page of FDUROP open topics.
  ///
  /// With a bound campus API the filters are sent to paper.fudan.edu.cn, so
  /// paging covers the whole live catalogue. When the live system is not
  /// reachable (not signed in, offline) the bundled seed is filtered and paged
  /// locally, and [FduropProjectPage.liveError] says why.
  Future<FduropProjectPage> fetchFduropProjectPage({
    int page = 1,
    int pageSize = fduropPageSize,
    String? query,
    String? subjectKind,
    String? topicLabel,
  }) async {
    final q = query?.trim() ?? '';
    final subject = _activeFilter(subjectKind);
    final label = _activeFilter(topicLabel);
    String? liveError;

    final api = _api;
    if (api != null) {
      try {
        final subjectId = subject == null
            ? null
            : (await _liveSubjectIdMap())[subject];
        final labelId = label == null ? null : (await _liveLabelIdMap())[label];
        final res = await api.call('fudan.fdurop.topics', {
          'page': page,
          'page_size': pageSize,
          if (q.isNotEmpty) 'keyword': q,
          'subject_kind_id': ?subjectId,
          'topic_label_id': ?labelId,
        });
        final live = _parseLivePage(res, page, pageSize);
        if (live != null) {
          // A filter the server could not resolve to an id is applied locally.
          final items = live.items.where((item) {
            if (subject != null &&
                subjectId == null &&
                !item.matchesSubjectKind(subject)) {
              return false;
            }
            if (label != null &&
                labelId == null &&
                !item.matchesTopicLabel(label)) {
              return false;
            }
            return true;
          }).toList();
          return FduropProjectPage(
            items: items,
            page: page,
            pageSize: pageSize,
            total: live.total,
            hasMore: live.hasMore,
            isLive: true,
          );
        }
        liveError = '开放课题系统返回了无法识别的数据';
      } catch (e) {
        liveError = campusError(e);
      }
    }

    final filtered = _initialFduropProjects.where((item) {
      if (subject != null && !item.matchesSubjectKind(subject)) return false;
      if (label != null && !item.matchesTopicLabel(label)) return false;
      return item.matchesQuery(q);
    }).toList();
    final start = (page - 1) * pageSize;
    final items = start >= filtered.length
        ? const <FduropProjectItem>[]
        : filtered
              .sublist(start, (start + pageSize).clamp(0, filtered.length))
              .map(_withBookmark)
              .toList();
    return FduropProjectPage(
      items: items,
      page: page,
      pageSize: pageSize,
      total: filtered.length,
      hasMore: start + items.length < filtered.length,
      isLive: false,
      liveError: liveError,
    );
  }

  /// Get detailed profile of an FDUROP topic including tutor and lab details.
  /// Live details are cached for the lifetime of the bound API.
  Future<FduropProjectItem?> getFduropProjectDetail(String id) async {
    final seed = _seedProjectsById[id];
    if (seed != null) return _withBookmark(seed);
    final cached = _fduropDetailCache[id];
    if (cached != null) return _withBookmark(cached);
    final api = _api;
    if (api == null) return null;
    try {
      final res = await api.call('fudan.fdurop.topic.detail', {'id': id});
      if (res is Map && (res['title']?.toString() ?? '').isNotEmpty) {
        final item = FduropProjectItem.fromLiveJson(
          Map<String, dynamic>.from(res),
        );
        if (identical(api, _api)) _fduropDetailCache[id] = item;
        return _withBookmark(item);
      }
    } catch (_) {
      // The caller keeps the summary row it already shows.
    }
    return null;
  }

  FduropProjectItem _withBookmark(FduropProjectItem item) => item.copyWith(
    isBookmarked: _bookmarkedFduropProjectIds.contains(item.id),
  );

  static String? _activeFilter(String? value) {
    final v = value?.trim();
    return v == null || v.isEmpty || v == '全部' ? null : v;
  }

  FduropProjectPage? _parseLivePage(Object? res, int page, int pageSize) {
    List<dynamic>? rows;
    int? total;
    bool? hasMore;
    if (res is Map && res['items'] is List) {
      rows = res['items'] as List;
      total = (res['total'] as num?)?.toInt();
      hasMore = res['has_more'] as bool?;
    } else if (res is List) {
      rows = res;
    }
    if (rows == null) return null;
    final items = [
      for (final row in rows)
        if (row is Map)
          _withBookmark(
            FduropProjectItem.fromLiveJson(Map<String, dynamic>.from(row)),
          ),
    ];
    return FduropProjectPage(
      items: items,
      page: page,
      pageSize: pageSize,
      total: total ?? (page - 1) * pageSize + items.length,
      hasMore: hasMore ?? false,
      isLive: true,
    );
  }

  /// The official AAO pages carrying the FDUROP forms and resources. Both are
  /// shown to signed-in members only; the host signs in to jwc on demand.
  static const List<String> fduropDocumentPages = [
    'https://jwc.fudan.edu.cn/0e/07/c27281a724487/page.psp',
    'https://jwc.fudan.edu.cn/fb/f7/c27281a457719/page.psp',
  ];

  /// The listing loaded this session, if any.
  List<FduropDocumentItem>? get cachedFduropDocuments => _fduropDocuments;

  bool isFduropDocumentDownloaded(String id) =>
      _fduropDocAssets.containsKey(id);

  /// The official FDUROP files (via `fudan.notice.attachments`). Pages that
  /// fail are skipped while another succeeds; if none does, the error is thrown.
  Future<List<FduropDocumentItem>> fetchFduropDocuments({
    bool refresh = false,
  }) async {
    final cached = _fduropDocuments;
    if (!refresh && cached != null) return cached;
    final api = _api;
    if (api == null) throw StateError('campus api unbound');
    Object? failure;
    final pages = await Future.wait([
      for (final page in fduropDocumentPages)
        api
            .call('fudan.notice.attachments', {'url': page})
            .then<Object?>((v) => v)
            .catchError((Object e) {
              failure ??= e;
              return null;
            }),
    ]);
    if (pages.every((p) => p is! List)) {
      throw failure ?? StateError('unexpected attachment payload');
    }
    final seen = <String>{};
    final items = [
      for (final page in pages.whereType<List>())
        for (final row in page.whereType<Map>())
          if (row['url'] is String && seen.add(row['url'] as String))
            FduropDocumentItem.fromAttachment(
              row['name']?.toString() ?? '附件',
              row['url'] as String,
            ),
    ];
    _fduropDocuments = items;
    return items;
  }

  /// Fetch the file into Core's managed asset store (reused within the session).
  Future<String> _fduropDocumentAsset(
    FduropDocumentItem doc, {
    bool fresh = false,
  }) async {
    final known = _fduropDocAssets[doc.id];
    if (known != null && !fresh) return known;
    final api = _api;
    if (api == null) throw StateError('campus api unbound');
    final result = await api.call('fudan.notice.attachment.download', {
      'url': doc.downloadUrl,
      'name': doc.fileName,
    });
    final id = result is Map ? result['asset_id']?.toString() : null;
    if (id == null || id.isEmpty) throw StateError('FileUnavailable');
    _fduropDocAssets[doc.id] = id;
    notifyListeners();
    return id;
  }

  /// Download (once per session) and open with the system viewer.
  Future<void> openFduropDocument(FduropDocumentItem doc) =>
      _withFduropAsset(doc, 'campus.openFile');

  /// Download (once per session) and save a copy where the person picks.
  Future<void> saveFduropDocument(FduropDocumentItem doc) =>
      _withFduropAsset(doc, 'campus.saveFile');

  Future<void> _withFduropAsset(FduropDocumentItem doc, String method) async {
    final cached = _fduropDocAssets.containsKey(doc.id);
    var id = await _fduropDocumentAsset(doc);
    try {
      await _api!.call(method, {'asset_id': id});
    } catch (e) {
      // A cached asset may have been evicted; fetch it again once.
      if (!cached || e.toString().contains('Cancelled')) rethrow;
      _fduropDocAssets.remove(doc.id);
      id = await _fduropDocumentAsset(doc, fresh: true);
      await _api!.call(method, {'asset_id': id});
    }
  }

  /// List of distinct departments for filtering groups.
  List<String> get availableDepartments {
    final depts =
        researchGroupDirectory.map((g) => g.department).toSet().toList()
          ..sort();
    return ['全部', ...depts];
  }

  /// List of lecture categories for filtering.
  List<String> get availableLectureCategories => [
    '全部',
    '人文社科',
    '信息技术',
    '物质前沿',
    '生命健康',
  ];

  /// Fallback academic subject kinds (学科门类) of paper.fudan.edu.cn.
  static const List<String> _fallbackSubjectKinds = [
    '全部',
    '交叉学科',
    '医学',
    '工学',
    '理学',
    '文学',
    '法学',
    '经济学',
    '管理学',
    '历史学',
    '哲学',
    '教育学',
    '艺术学',
  ];

  /// Fallback topic labels / funding sources (课题标签) of paper.fudan.edu.cn.
  static const List<String> _fallbackTopicLabels = [
    '全部',
    '国家自然科学基金项目',
    '国家科技重大专项',
    '国家社科基金项目',
    '省（市）级基金项目',
    '企事业单位委托项目',
    '国际合作项目',
    '其它项目',
  ];

  /// Subject kind filter options: the live list when reachable, else the fallback.
  Future<List<String>> fduropSubjectKindOptions() async {
    try {
      final live = await _liveSubjectIdMap();
      if (live.isNotEmpty) return ['全部', ...live.keys];
    } catch (_) {}
    return _fallbackSubjectKinds;
  }

  /// Topic label filter options: the live list when reachable, else the fallback.
  Future<List<String>> fduropTopicLabelOptions() async {
    try {
      final live = await _liveLabelIdMap();
      if (live.isNotEmpty) return ['全部', ...live.keys];
    } catch (_) {}
    return _fallbackTopicLabels;
  }

  /// `name_zh -> id` of live subject kinds; loaded once per bound API, retried after a failure.
  Future<Map<String, String>> _liveSubjectIdMap() {
    final pending = _liveSubjectIds ??= _loadLiveDictionary(
      'fudan.fdurop.subjects',
    );
    return pending.catchError((Object e) {
      if (identical(_liveSubjectIds, pending)) _liveSubjectIds = null;
      throw e;
    });
  }

  /// `name_zh -> id` of live topic labels; loaded once per bound API, retried after a failure.
  Future<Map<String, String>> _liveLabelIdMap() {
    final pending = _liveLabelIds ??= _loadLiveDictionary(
      'fudan.fdurop.labels',
    );
    return pending.catchError((Object e) {
      if (identical(_liveLabelIds, pending)) _liveLabelIds = null;
      throw e;
    });
  }

  Future<Map<String, String>> _loadLiveDictionary(String method) async {
    final api = _api;
    if (api == null) throw StateError('campus api unbound');
    final res = await api.call(method, const <String, dynamic>{});
    if (res is! List) throw StateError('unexpected $method payload');
    return {
      for (final row in res)
        if (row is Map &&
            (row['name_zh']?.toString() ?? '').isNotEmpty &&
            (row['id']?.toString() ?? '').isNotEmpty)
          row['name_zh'].toString(): row['id'].toString(),
    };
  }
}

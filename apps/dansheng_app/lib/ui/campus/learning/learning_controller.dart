// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:dansheng_app/ui/core/dansheng_state.dart';

import '../campus_api.dart';
import 'models/canvas_models.dart';
import 'models/timetable_models.dart';

/// State coordinator for the eLearning & Timetable view.
/// Enforces per-source isolation, race/account-change safety, and cached fallbacks.
class LearningController extends ChangeNotifier {
  final DanshengController appController;
  late CampusApi api;

  final DateTime Function() currentTime;
  LearningController({required this.appController, DateTime Function()? now})
    : currentTime = now ?? DateTime.now {
    api = CampusApi.forAccount(appController);
    _currentAccountId = appController.activeAccountId;
    final now = currentTime().toUtc().add(const Duration(hours: 8));
    _selectedDate = DateTime(now.year, now.month, now.day);
    _calendarMonth = DateTime(now.year, now.month, 1);
  }

  // --- Account & Request Tracking ---
  String? _currentAccountId;
  int _requestToken = 0;
  int _academicRequest = 0;
  int _canvasRequest = 0;

  // --- Calendar & Navigation State ---
  late DateTime _selectedDate;
  DateTime get selectedDate => _selectedDate;

  late DateTime _calendarMonth;
  DateTime get calendarMonth => _calendarMonth;

  String _calendarViewMode = 'week'; // 'week' | 'month'
  String get calendarViewMode => _calendarViewMode;

  // --- Academic (Timetable) State ---
  /// Fudan student category is the third digit of the active student number.
  static bool? undergraduateForAccount(String? account) {
    final id = account?.trim() ?? '';
    if (!RegExp(r'^\d{3,}$').hasMatch(id)) return null;
    return switch (id[2]) {
      '1' || '2' => false,
      '3' => true,
      _ => null,
    };
  }

  bool get isUndergraduate =>
      undergraduateForAccount(_currentAccountId) == true;
  bool get hasAcademicIdentity =>
      undergraduateForAccount(_currentAccountId) != null;

  List<Semester> _semesters = [];
  List<Semester> get semesters => _semesters;

  Semester? _selectedSemester;
  Semester? get selectedSemester => _selectedSemester;
  Semester? _currentSemester;
  Semester? get currentSemester => _currentSemester;

  TimetableData? _timetableData;
  TimetableData? get timetableData => _timetableData;

  bool _academicLoading = false;
  bool get academicLoading => _academicLoading;

  bool _academicAuthRequired = false;
  bool get academicAuthRequired => _academicAuthRequired;

  String? _academicError;
  String? get academicError => _academicError;

  bool _academicFromCache = false;
  bool get academicFromCache => _academicFromCache;

  // --- Canvas (eLearning) State ---
  List<CanvasCourse> _courses = [];
  List<CanvasCourse> get courses => _courses
      .where(
        (c) => c.belongsToTerm(today, academicTermName: _currentSemester?.name),
      )
      .toList();
  List<CanvasCourse> get archivedCourses {
    final currentIds = courses.map((c) => c.id).toSet();
    return _courses.where((c) => !currentIds.contains(c.id)).toList();
  }

  String? _selectedCourseId;
  String? get selectedCourseId => _selectedCourseId;

  bool _canvasLoading = false;
  bool get canvasLoading => _canvasLoading;

  bool _canvasAuthRequired = false;
  bool get canvasAuthRequired => _canvasAuthRequired;

  String? _canvasError;
  String? get canvasError => _canvasError;
  final Map<String, String> _detailErrors = {};
  String? get assignmentError => _detailErrors.entries
      .where(
        (e) =>
            e.key.startsWith('canvas.assignments.sync:') &&
            courses.any((c) => e.key == 'canvas.assignments.sync:${c.id}'),
      )
      .firstOrNull
      ?.value;
  String? detailsError(String id) => _detailErrors.entries
      .where((e) => e.key.endsWith(':$id'))
      .firstOrNull
      ?.value;

  bool _canvasFromCache = false;
  bool get canvasFromCache => _canvasFromCache;

  // Keyed by courseId
  final Map<String, List<CanvasAssignment>> _assignments = {};
  Map<String, List<CanvasAssignment>> get assignments => _assignments;

  final Map<String, List<CanvasAnnouncement>> _announcements = {};
  Map<String, List<CanvasAnnouncement>> get announcements => _announcements;

  final Map<String, List<CanvasFolder>> _folders = {};
  Map<String, List<CanvasFolder>> get folders => _folders;

  final Map<String, List<CanvasMaterial>> _materials = {};
  Map<String, List<CanvasMaterial>> get materials => _materials;

  final Map<String, List<CanvasModule>> _modules = {};
  Map<String, List<CanvasModule>> get modules => _modules;

  /// Standalone quizzes (no assignment of their own), keyed by courseId.
  final Map<String, List<CanvasAssignment>> _quizzes = {};
  Map<String, List<CanvasAssignment>> get quizzes => _quizzes;

  /// The student's own submissions, keyed by `courseId:assignmentId`.
  final Map<String, CanvasSubmission> _submissions = {};
  final Set<String> _loadingSubmissions = {};

  final Map<String, CanvasGradeSummary> _grades = {};
  final Map<String, List<CanvasAssignmentGroup>> _assignmentGroups = {};
  final Map<String, List<CanvasDiscussionTopic>> _discussions = {};
  final Map<String, List<CanvasPageSummary>> _pages = {};

  /// Module contents, keyed by `courseId:moduleId`.
  final Map<String, List<CanvasModuleItem>> _moduleItems = {};
  final Set<String> _loadingModules = {};

  /// Failures of supplementary reads (quizzes, pages, discussions, grades…).
  /// A course may simply have those tools disabled, so these never raise the
  /// sign-in prompt or the course-wide error banner.
  final Map<String, String> _optionalErrors = {};

  final Set<String> _downloadingFileIds = {};
  Set<String> get downloadingFileIds => _downloadingFileIds;

  final Set<String> _downloadedFileIds = {};
  Set<String> get downloadedFileIds => _downloadedFileIds;

  final Set<String> _loadingCourseIds = {};

  /// Whether the details of a Canvas course are being fetched right now.
  bool isCourseLoading(String courseId) => _loadingCourseIds.contains(courseId);

  /// Assignments plus standalone quizzes of one course.
  List<CanvasAssignment> courseWork(String courseId) => [
    ...?_assignments[courseId],
    ...?_quizzes[courseId],
  ];

  String _submissionKey(CanvasAssignment a) => '${a.courseId}:${a.id}';

  /// The student's own submission, once fetched. Quizzes without an
  /// assignment have none.
  CanvasSubmission? submissionFor(CanvasAssignment a) =>
      a.isQuiz ? null : _submissions[_submissionKey(a)];

  bool isSubmissionLoading(CanvasAssignment a) =>
      _loadingSubmissions.contains(_submissionKey(a));

  /// Still owed: not handed in, graded or excused. Unknown counts as owed so
  /// a missing status never hides a deadline.
  bool isOutstanding(CanvasAssignment a) => submissionFor(a)?.isDone != true;

  CanvasGradeSummary? gradeFor(String courseId) => _grades[courseId];
  List<CanvasAssignmentGroup> assignmentGroupsFor(String courseId) =>
      _assignmentGroups[courseId] ?? const [];
  List<CanvasDiscussionTopic>? discussionsFor(String courseId) =>
      _discussions[courseId];
  List<CanvasPageSummary> pagesFor(String courseId) =>
      _pages[courseId] ?? const [];

  List<CanvasModuleItem>? moduleItems(String courseId, String moduleId) =>
      _moduleItems['$courseId:$moduleId'];
  bool isModuleLoading(String courseId, String moduleId) =>
      _loadingModules.contains('$courseId:$moduleId');

  /// Failure of a supplementary read such as `canvas.discussions.sync`.
  String? optionalError(String method, String id) =>
      _optionalErrors['$method:$id'];

  // --- Computed Queries ---

  /// Today's date in campus time (UTC+8).
  DateTime get today {
    final now = currentTime().toUtc().add(const Duration(hours: 8));
    return DateTime(now.year, now.month, now.day);
  }

  /// Monday of the week that contains the selected date.
  DateTime get weekStart => DateTime(
    _selectedDate.year,
    _selectedDate.month,
    _selectedDate.day - (_selectedDate.weekday - 1),
  );

  /// Teaching week of a date in the shown semester, or null outside of it.
  int? weekOf(DateTime date) {
    final semester = _timetableData?.semester ?? _selectedSemester;
    if (semester == null) return null;
    final start = DateTime.utc(
      semester.startsOn.year,
      semester.startsOn.month,
      semester.startsOn.day,
    );
    final days = DateTime.utc(
      date.year,
      date.month,
      date.day,
    ).difference(start).inDays;
    final week = (days / 7).floor() + 1;
    return week >= 1 && week <= 30 ? week : null;
  }

  /// Timetable courses on any date, ordered by their first unit.
  List<TimetableCourse> coursesOn(DateTime date) =>
      _timetableData?.coursesOn(date) ?? const [];

  /// Number of teaching units the week grid has to show.
  int get visibleUnits {
    var last = 8;
    for (final course in _timetableData?.courses ?? const <TimetableCourse>[]) {
      if (course.endUnit > last) last = course.endUnit;
    }
    return last.clamp(8, TeachingUnit.all.length);
  }

  CanvasCourse? courseById(String? id) {
    if (id == null) return null;
    for (final course in _courses) {
      if (course.id == id) return course;
    }
    return null;
  }

  static final RegExp _noise = RegExp(r'[\s()（）\[\]【】·\-_.:：,，]');
  static String _fold(String? raw) =>
      (raw ?? '').toLowerCase().replaceAll(_noise, '');

  /// The eLearning course that belongs to a timetable course, matched by
  /// course code first and by name second.
  CanvasCourse? canvasCourseFor(TimetableCourse course) {
    final name = _fold(course.name);
    final code = _fold(course.courseCode);
    CanvasCourse? partial;
    for (final candidate in courses) {
      final otherName = _fold(candidate.name);
      final otherCode = _fold(candidate.courseCode);
      if (code.length >= 4 &&
          (otherCode == code ||
              otherCode.contains(code) ||
              otherName.contains(code) ||
              (otherCode.length >= 6 && code.startsWith(otherCode)))) {
        return candidate;
      }
      if (name.isNotEmpty && otherName == name) return candidate;
      if (partial == null &&
          name.length >= 2 &&
          otherName.length >= 2 &&
          (otherName.contains(name) || name.contains(otherName))) {
        partial = candidate;
      }
    }
    return partial;
  }

  /// Every weekly session of the timetable course with this name.
  List<TimetableCourse> sessionsNamed(String name) {
    final list = [
      for (final course in _timetableData?.courses ?? const <TimetableCourse>[])
        if (course.name == name) course,
    ];
    list.sort(
      (a, b) => a.weekday != b.weekday
          ? a.weekday.compareTo(b.weekday)
          : a.startUnit.compareTo(b.startUnit),
    );
    return list;
  }

  /// Weekly sessions of the timetable course matched to an eLearning course.
  List<TimetableCourse> sessionsFor(CanvasCourse course) {
    for (final item in _timetableData?.courses ?? const <TimetableCourse>[]) {
      if (canvasCourseFor(item)?.id == course.id) {
        return sessionsNamed(item.name);
      }
    }
    return const [];
  }

  /// Courses occurring on the currently selected date.
  List<TimetableCourse> get coursesOnSelectedDate {
    if (_timetableData == null) return const [];
    return _timetableData!.coursesOn(_selectedDate);
  }

  /// All assignments flattened across all enrolled courses.
  List<CanvasAssignment> get allAssignments {
    final list = <CanvasAssignment>[];
    for (final course in courses) {
      list.addAll(courseWork(course.id));
    }
    return list;
  }

  /// Every assignment with a deadline: upcoming ones soonest first, then
  /// past deadlines most recent first.
  List<CanvasAssignment> get deadlineAssignments {
    final now = currentTime();
    final dated = allAssignments.where((a) => a.dueAt != null).toList();
    final upcoming = dated.where((a) => !a.dueAt!.isBefore(now)).toList()
      ..sort((a, b) => a.dueAt!.compareTo(b.dueAt!));
    final past = dated.where((a) => a.dueAt!.isBefore(now)).toList()
      ..sort((a, b) => b.dueAt!.compareTo(a.dueAt!));
    return [...upcoming, ...past];
  }

  /// Assignments due on the currently selected date.
  List<CanvasAssignment> get assignmentsOnSelectedDate {
    return allAssignments.where((a) => a.isDueOn(_selectedDate)).toList();
  }

  /// Check whether any timetable courses occur on a given date.
  bool hasCoursesOn(DateTime date) {
    if (_timetableData == null) return false;
    return _timetableData!.hasCoursesOn(date);
  }

  /// Check whether any assignments are due on a given date.
  bool hasAssignmentsOn(DateTime date) {
    return allAssignments.any((a) => a.isDueOn(date));
  }

  /// Check whether any courses or assignments occur on a given date.
  bool hasEventsOn(DateTime date) {
    return hasCoursesOn(date) || hasAssignmentsOn(date);
  }

  // --- Account Change Safety ---
  void checkAccountChange() {
    if (appController.isChangingAccount) return;
    final newId = appController.activeAccountId;
    if (newId != _currentAccountId || !api.isCurrent) {
      api.accountScope?.dispose();
      api = CampusApi.forAccount(appController);
      _currentAccountId = newId;
      _requestToken++;
      _resetState();
      notifyListeners();
      loadAll();
    }
  }

  void _resetState() {
    _semesters = [];
    _selectedSemester = null;
    _currentSemester = null;
    _timetableData = null;
    _academicError = null;
    _academicAuthRequired = false;
    _academicFromCache = false;

    _courses = [];
    _selectedCourseId = null;
    _canvasError = null;
    _detailErrors.clear();
    _canvasAuthRequired = false;
    _canvasFromCache = false;

    _assignments.clear();
    _announcements.clear();
    _folders.clear();
    _materials.clear();
    _modules.clear();
    _quizzes.clear();
    _submissions.clear();
    _loadingSubmissions.clear();
    _grades.clear();
    _assignmentGroups.clear();
    _discussions.clear();
    _pages.clear();
    _moduleItems.clear();
    _loadingModules.clear();
    _optionalErrors.clear();
    _loadingCourseIds.clear();
    _downloadingFileIds.clear();
    _downloadedFileIds.clear();
  }

  // --- Calendar Navigation ---
  void selectDate(DateTime date) {
    _selectedDate = DateTime(date.year, date.month, date.day);
    if (_selectedDate.year != _calendarMonth.year ||
        _selectedDate.month != _calendarMonth.month) {
      _calendarMonth = DateTime(_selectedDate.year, _selectedDate.month, 1);
    }
    notifyListeners();
  }

  void setCalendarViewMode(String mode) {
    if (_calendarViewMode != mode) {
      _calendarViewMode = mode;
      notifyListeners();
    }
  }

  void nextCalendarPeriod() {
    if (_calendarViewMode == 'week') {
      _selectedDate = _selectedDate.add(const Duration(days: 7));
      _calendarMonth = DateTime(_selectedDate.year, _selectedDate.month, 1);
    } else {
      _calendarMonth = DateTime(
        _calendarMonth.year,
        _calendarMonth.month + 1,
        1,
      );
      _selectedDate = DateTime(_calendarMonth.year, _calendarMonth.month, 1);
    }
    notifyListeners();
  }

  void prevCalendarPeriod() {
    if (_calendarViewMode == 'week') {
      _selectedDate = _selectedDate.subtract(const Duration(days: 7));
      _calendarMonth = DateTime(_selectedDate.year, _selectedDate.month, 1);
    } else {
      _calendarMonth = DateTime(
        _calendarMonth.year,
        _calendarMonth.month - 1,
        1,
      );
      _selectedDate = DateTime(_calendarMonth.year, _calendarMonth.month, 1);
    }
    notifyListeners();
  }

  void jumpToToday() {
    final now = currentTime().toUtc().add(const Duration(hours: 8));
    _selectedDate = DateTime(now.year, now.month, now.day);
    _calendarMonth = DateTime(now.year, now.month, 1);
    notifyListeners();
  }

  // --- Academic Settings & Actions ---
  void selectSemester(Semester semester) {
    if (_selectedSemester?.externalId != semester.externalId) {
      _selectedSemester = semester;
      _timetableData = null;
      selectDate(
        semester.externalId == _currentSemester?.externalId
            ? today
            : semester.startsOn,
      );
      notifyListeners();
      loadAcademicTimetable();
    }
  }

  void selectCourse(String courseId) {
    _selectedCourseId = courseId;
    notifyListeners();
    loadCourseDetails(courseId);
  }

  // --- Data Loading Orchestration ---
  Future<void> loadAll() async {
    final token = _requestToken;
    await Future.wait([loadAcademic(), loadCanvas()]);
    // The academic catalog can arrive after Canvas. Fill summaries newly
    // classified as current (e.g. a dated summer term), without loading archives.
    if (token != _requestToken) return;
    for (final course in courses) {
      if (!_assignments.containsKey(course.id) &&
          !_loadingCourseIds.contains(course.id)) {
        await loadCourseDetails(course.id, token: token);
        if (token != _requestToken) return;
      }
    }
  }

  bool _isAuthError(Object e) {
    final s = e.toString();
    return s.contains('AuthenticationRequired') ||
        s.contains('InteractiveLoginRequired') ||
        s.contains('NotLoginError') ||
        s.contains('ConfigurationRequired') ||
        s.contains('401');
  }

  /// A missing cache preserves the original failure instead of an empty table.
  Future<(dynamic, bool)> _readSource(
    String method,
    Map<String, dynamic> params,
  ) async {
    try {
      final value = await api.call(method, params);
      if (value == null) throw const FormatException('SourceSchemaChanged');
      return (value, false);
    } catch (error) {
      // The PG calendar endpoint checks the current term's validity interval.
      // Reusing an old response could bypass that check after a semester ends.
      if (_isAuthError(error) || method == 'fudan.postgraduate.semester') {
        rethrow;
      }
      dynamic cached;
      try {
        cached = await api.call('campus.cached', {...params, 'method': method});
      } catch (_) {}
      if (cached == null) rethrow;
      return (cached, true);
    }
  }

  Semester? _semesterForToday(List<Semester> semesters) {
    final started =
        semesters
            .where(
              (s) =>
                  !s.startsOn.isAfter(today) &&
                  today.difference(s.startsOn).inDays < 210,
            )
            .toList()
          ..sort((a, b) => b.startsOn.compareTo(a.startsOn));
    return started.firstOrNull;
  }

  Future<void> loadAcademic() async {
    final token = _requestToken;
    final request = ++_academicRequest;
    bool active() => token == _requestToken && request == _academicRequest;
    _academicLoading = true;
    _academicError = null;
    _academicAuthRequired = false;
    _academicFromCache = false;
    if (!hasAcademicIdentity) {
      _academicLoading = false;
      _academicError = '请在账号与校园卡中设置有效学号后同步课表';
      notifyListeners();
      return;
    }
    notifyListeners();
    try {
      final (response, cached) = await _readSource(
        isUndergraduate ? 'fudan.semesters' : 'fudan.postgraduate.semester',
        {},
      );
      if (!active()) return;
      _semesters = isUndergraduate
          ? SemesterCatalog.fromJson(response).semesters
          : [Semester.fromJson(response as Map<String, dynamic>)];
      // PG metadata already validates the full semester, including week zero
      // before teaching week one's Monday. Do not reject that future Monday.
      _currentSemester = isUndergraduate
          ? _semesterForToday(_semesters)
          : _semesters.single;
      final previousId = _selectedSemester?.externalId;
      _selectedSemester =
          _semesters.where((s) => s.externalId == previousId).firstOrNull ??
          _currentSemester;
      _academicFromCache = cached;
    } catch (e) {
      // UG can resolve its own semester after a transient catalog failure.
      // PG metadata must be explicitly verified before interpreting week bits.
      if (active() && !isUndergraduate) {
        _academicError = e.toString().contains('SemesterCalendarUnavailable')
            ? '本学期校历尚未确认，暂时无法显示课表'
            : campusError(e);
        _academicAuthRequired = _isAuthError(e);
        _academicLoading = false;
        notifyListeners();
        return;
      }
      if (active() && isUndergraduate && _isAuthError(e)) {
        _academicError = campusError(e);
        _academicAuthRequired = true;
        _academicLoading = false;
        notifyListeners();
        return;
      }
    }
    if (!active()) return;
    await loadAcademicTimetable(token: token);
  }

  Future<void> loadAcademicTimetable({int? token}) async {
    final curToken = token ?? _requestToken;
    final request = ++_academicRequest;
    bool active() => curToken == _requestToken && request == _academicRequest;
    final undergraduate = isUndergraduate;
    final semester = undergraduate ? _selectedSemester : _currentSemester;
    _academicLoading = true;
    _academicError = null;
    _academicAuthRequired = false;
    _academicFromCache = false;
    notifyListeners();
    final method = undergraduate
        ? 'fudan.timetable.sync'
        : 'fudan.postgraduate.sync';
    final params = <String, dynamic>{
      if (semester != null) 'semester': semester.toJson(),
      if (!undergraduate) 'endpoint': 'primary',
    };
    try {
      if (!hasAcademicIdentity) {
        _academicError = '请在账号与校园卡中设置有效学号后同步课表';
        return;
      }
      if (!undergraduate && semester == null) {
        _academicError = '暂未获取到本学期开学日期，请先同步学期信息后重试';
        return;
      }
      final (response, cached) = await _readSource(method, params);
      if (!active()) return;
      final table = TimetableData.fromJson(response, semester);
      _timetableData = table;
      _selectedSemester = table.semester ?? semester;
      final receivedSemester = table.semester;
      if (_currentSemester == null &&
          receivedSemester != null &&
          !receivedSemester.startsOn.isAfter(today) &&
          today.difference(receivedSemester.startsOn).inDays < 210) {
        // A server's future default must not reclassify Canvas courses.
        _currentSemester = receivedSemester;
      }
      _academicFromCache = cached;
    } catch (e) {
      if (!active()) return;
      _academicError = campusError(e);
      _academicAuthRequired = _isAuthError(e) || _academicError!.contains('登录');
    } finally {
      if (active()) {
        _academicLoading = false;
        notifyListeners();
      }
    }
  }

  /// Load Canvas courses with cache fallback.
  Future<void> loadCanvas() async {
    final token = _requestToken;
    final request = ++_canvasRequest;
    bool active() => token == _requestToken && request == _canvasRequest;
    _canvasLoading = true;
    _canvasError = null;
    _canvasAuthRequired = false;
    _canvasFromCache = false;
    notifyListeners();

    try {
      final (coursesResponse, cached) = await _readSource(
        'canvas.courses.sync',
        {},
      );
      if (!active()) return;
      if (coursesResponse is! List) {
        throw const FormatException('SourceSchemaChanged');
      }
      _canvasFromCache = cached;

      final List<CanvasCourse> courseList = [];
      for (final item in coursesResponse) {
        if (item is Map<String, dynamic>) {
          courseList.add(CanvasCourse.fromJson(item));
        }
      }

      _courses = courseList;

      // Load assignments and details for enrolled courses
      final enrolled = List<CanvasCourse>.of(courses);
      for (var offset = 0; offset < enrolled.length && active(); offset += 3) {
        await Future.wait(
          enrolled
              .skip(offset)
              .take(3)
              .map((c) => loadCourseDetails(c.id, token: token)),
        );
      }
    } catch (e) {
      if (!active()) return;
      _canvasError = campusError(e);
      _canvasAuthRequired =
          _isAuthError(e) ||
          _canvasError!.contains('登录') ||
          _canvasError!.contains('绑定');
    } finally {
      if (active()) {
        _canvasLoading = false;
        notifyListeners();
      }
    }
  }

  /// Load assignments, folders, materials, announcements for a specific course.
  Future<void> loadCourseDetails(String courseId, {int? token}) async {
    final curToken = token ?? _requestToken;
    _loadingCourseIds.add(courseId);
    try {
      await _loadCourseDetails(courseId, curToken);
    } finally {
      if (curToken == _requestToken) {
        _loadingCourseIds.remove(courseId);
        notifyListeners();
      }
    }
  }

  Future<void> _loadCourseDetails(String courseId, int curToken) async {
    final course = _courses.firstWhere(
      (c) => c.id == courseId,
      orElse: () => CanvasCourse(id: courseId, name: ''),
    );

    Future<List?> read(String method, {bool optional = false}) => _readCanvas(
      method,
      {'course_id': courseId},
      curToken,
      errorKey: '$method:$courseId',
      label: course.name,
      optional: optional,
    );
    List<Map<String, dynamic>> rows(List? data) =>
        data!.whereType<Map<String, dynamic>>().toList();

    final results = await Future.wait([
      read('canvas.assignments.sync'),
      read('canvas.announcements.sync'),
      read('canvas.quizzes.sync', optional: true),
    ]);
    if (curToken != _requestToken) return;
    if (results[0] != null) {
      _assignments[courseId] = rows(results[0])
          .map((r) => CanvasAssignment.fromJson(r, courseId, course.name))
          .toList();
    }
    if (results[1] != null) {
      _announcements[courseId] = rows(results[1])
          .map((r) => CanvasAnnouncement.fromJson(r, courseId, course.name))
          .toList();
    }
    if (results[2] != null) {
      // A graded quiz is already listed as an assignment.
      _quizzes[courseId] = [
        for (final r in rows(results[2]))
          if (CanvasAssignment.quizAssignmentId(r) == null &&
              CanvasAssignment.quizPublished(r))
            CanvasAssignment.fromQuiz(r, courseId, course.name),
      ];
    }
    notifyListeners();
    if (courseId == _selectedCourseId) {
      final assets = await Future.wait([
        read('canvas.folders.sync'),
        read('canvas.materials.sync'),
        read('canvas.modules.sync'),
        read('canvas.pages.sync', optional: true),
        read('canvas.discussions.sync', optional: true),
        read('canvas.assignment_groups.sync', optional: true),
        read('canvas.grades.self', optional: true),
      ]);
      if (curToken != _requestToken) return;
      if (assets[0] != null) {
        _folders[courseId] = rows(assets[0])
            .map(CanvasFolder.fromJson)
            .toList();
      }
      if (assets[1] != null) {
        _materials[courseId] = rows(assets[1])
            .map((r) => CanvasMaterial.fromJson(r, courseId))
            .toList();
      }
      if (assets[2] != null) {
        _modules[courseId] = rows(assets[2]).map(CanvasModule.fromJson).toList()
          ..sort((a, b) => a.position.compareTo(b.position));
      }
      if (assets[3] != null) {
        _pages[courseId] =
            rows(assets[3])
                .map(CanvasPageSummary.fromJson)
                .where((p) => p.slug.isNotEmpty)
                .toList()
              ..sort((a, b) {
                if (a.frontPage != b.frontPage) return a.frontPage ? -1 : 1;
                return a.title.compareTo(b.title);
              });
      }
      if (assets[4] != null) {
        _discussions[courseId] =
            rows(assets[4]).map(CanvasDiscussionTopic.fromJson).toList()
              ..sort((a, b) {
                final x = a.activityAt, y = b.activityAt;
                if (x == null || y == null) return x == null ? 1 : -1;
                return y.compareTo(x);
              });
      }
      if (assets[5] != null) {
        _assignmentGroups[courseId] =
            rows(assets[5]).map(CanvasAssignmentGroup.fromJson).toList()
              ..sort((a, b) => a.position.compareTo(b.position));
      }
      if (assets[6] != null) {
        final grades = rows(assets[6]).map(CanvasGradeSummary.fromJson);
        final summary = grades.where((g) => !g.isEmpty).firstOrNull;
        if (summary != null) {
          _grades[courseId] = summary;
        } else {
          _grades.remove(courseId);
        }
      }
      notifyListeners();
    }
    // Own status of current deadlines, including ones that just passed.
    final since = currentTime().subtract(const Duration(days: 14));
    await loadSubmissions(
      [
        for (final a in _assignments[courseId] ?? const <CanvasAssignment>[])
          if ((a.dueAt != null && a.dueAt!.isAfter(since)) ||
              _submissions.containsKey(_submissionKey(a)))
            a,
      ],
      token: curToken,
      refresh: true,
    );
  }

  /// Reads a Canvas list with cache fallback. A required read records its
  /// failure as a course error and may raise the sign-in prompt; an optional
  /// one only notes the failure for its own section.
  Future<List?> _readCanvas(
    String method,
    Map<String, dynamic> params,
    int token, {
    required String errorKey,
    String label = '',
    bool optional = false,
  }) async {
    try {
      final data = await api.call(method, params);
      if (data is! List) throw const FormatException('Invalid records');
      if (token == _requestToken) {
        _detailErrors.remove(errorKey);
        _optionalErrors.remove(errorKey);
      }
      return data;
    } catch (failure) {
      if (token != _requestToken) return null;
      dynamic cached;
      try {
        cached = await api.call('campus.cached', {...params, 'method': method});
      } catch (_) {}
      if (token != _requestToken) return null;
      if (cached is List) {
        _canvasFromCache = true;
        return cached;
      }
      final message = campusError(failure);
      if (optional) {
        _optionalErrors[errorKey] = message;
      } else {
        _detailErrors[errorKey] = label.isEmpty ? message : '$label：$message';
        _canvasAuthRequired = _canvasAuthRequired || _isAuthError(failure);
      }
      return null;
    }
  }

  /// A single record (page, discussion thread, syllabus…) with cache fallback.
  /// Failures are thrown to the caller, which shows them in place.
  Future<Map<String, dynamic>> _readRecord(
    String method,
    Map<String, dynamic> params,
  ) async {
    final requestApi = api;
    final token = _requestToken;
    void check() {
      if (token != _requestToken) {
        throw PlatformException(code: 'AccountChanged');
      }
      requestApi.accountScope?.check();
    }

    dynamic value;
    try {
      value = await requestApi.call(method, params);
      check();
      if (rowsOf(value).isEmpty) {
        throw const FormatException('SourceSchemaChanged');
      }
    } catch (error) {
      if (isAccountChange(error)) rethrow;
      check();
      dynamic cached;
      try {
        cached = await requestApi.call('campus.cached', {
          ...params,
          'method': method,
        });
      } catch (error) {
        if (isAccountChange(error)) rethrow;
      }
      check();
      if (rowsOf(cached).isEmpty) rethrow;
      value = cached;
    }
    return rowsOf(value).first;
  }

  // --- Own submissions ---

  /// Fetches the student's own submission of each assignment, three at a time.
  Future<void> loadSubmissions(
    Iterable<CanvasAssignment> assignments, {
    int? token,
    bool refresh = false,
  }) async {
    final t = token ?? _requestToken;
    final todo = [
      for (final a in assignments)
        if (!a.isQuiz &&
            (refresh || !_submissions.containsKey(_submissionKey(a))))
          a,
    ];
    for (var i = 0; i < todo.length && t == _requestToken; i += 3) {
      await Future.wait(
        todo.skip(i).take(3).map((a) => loadSubmission(a, token: t)),
      );
    }
  }

  Future<void> loadSubmission(CanvasAssignment a, {int? token}) async {
    final t = token ?? _requestToken;
    final key = _submissionKey(a);
    if (a.isQuiz || a.id.isEmpty || !_loadingSubmissions.add(key)) return;
    try {
      final data = await _readCanvas(
        'canvas.submission.self',
        {'course_id': a.courseId, 'assignment_id': a.id},
        t,
        errorKey: 'canvas.submission.self:$key',
        optional: true,
      );
      final row = rowsOf(data).firstOrNull;
      if (t == _requestToken && row != null) {
        _submissions[key] = CanvasSubmission.fromJson(row);
      }
    } finally {
      if (t == _requestToken) {
        _loadingSubmissions.remove(key);
        notifyListeners();
      }
    }
  }

  // --- On-demand course content ---

  Future<void> loadModuleItems(String courseId, String moduleId) async {
    final key = '$courseId:$moduleId';
    final t = _requestToken;
    if (!_loadingModules.add(key)) return;
    notifyListeners();
    try {
      final data = await _readCanvas(
        'canvas.module_items.sync',
        {'course_id': courseId, 'module_id': moduleId},
        t,
        errorKey: 'canvas.module_items.sync:$key',
        optional: true,
      );
      if (t == _requestToken && data != null) {
        _moduleItems[key] = rowsOf(data).map(CanvasModuleItem.fromJson).toList()
          ..sort((a, b) => a.position.compareTo(b.position));
      }
    } finally {
      if (t == _requestToken) {
        _loadingModules.remove(key);
        notifyListeners();
      }
    }
  }

  Future<CanvasPage> readPage(String courseId, String slug) async =>
      CanvasPage.fromJson(
        await _readRecord('canvas.page.read', {
          'course_id': courseId,
          'page_slug': slug,
        }),
      );

  Future<CanvasDiscussionTopic> readDiscussion(
    String courseId,
    String topicId,
  ) async => CanvasDiscussionTopic.fromJson(
    await _readRecord('canvas.discussion.read', {
      'course_id': courseId,
      'topic_id': topicId,
    }),
  );

  Future<CanvasDiscussionView> readDiscussionThread(
    String courseId,
    String topicId,
  ) async => CanvasDiscussionView.fromJson(
    await _readRecord('canvas.discussion.view', {
      'course_id': courseId,
      'topic_id': topicId,
    }),
  );

  /// Fresh quiz metadata. Never requests questions or starts an attempt.
  Future<CanvasAssignment> readQuiz(CanvasAssignment quiz) async =>
      CanvasAssignment.fromQuiz(
        await _readRecord('canvas.quiz.read', {
          'course_id': quiz.courseId,
          'quiz_id': quiz.id,
        }),
        quiz.courseId,
        quiz.courseName,
      );

  /// The public academic syllabus; only undergraduate lessons carry an id.
  bool hasSyllabus(TimetableCourse course) =>
      isUndergraduate && RegExp(r'^\d{1,20}$').hasMatch(course.lessonId ?? '');

  Future<CourseSyllabus> readSyllabus(TimetableCourse course) async =>
      CourseSyllabus.fromJson(
        await _readRecord('fudan.catalog.syllabus', {
          'lesson_id': course.lessonId,
        }),
      );

  @override
  void dispose() {
    _requestToken++;
    api.accountScope?.dispose();
    super.dispose();
  }

  /// Download file then open it via parent bridge.
  /// Passes course_id and file_id, captures returned asset_id, and invokes campus.openFile.
  Future<void> downloadAndOpenFile({
    required String courseId,
    required String fileId,
    required String fileName,
    required void Function(String message, {bool isError}) showFeedback,
  }) async {
    if (_downloadingFileIds.contains(fileId)) return;

    _downloadingFileIds.add(fileId);
    notifyListeners();

    try {
      // 1. Download requires course_id and file_id
      final res = await api.call('canvas.material.download', {
        'course_id': courseId,
        'file_id': fileId,
      });

      // 2. Capture actual returned asset_id
      String? assetId;
      if (res is Map) {
        assetId = res['asset_id']?.toString();
      }

      _downloadedFileIds.add(fileId);
      _downloadingFileIds.remove(fileId);
      notifyListeners();

      // 3. Open file via parent bridge passing actual asset_id
      await api.call('campus.openFile', {
        'asset_id': assetId ?? fileId,
        'file_id': fileId,
        'course_id': courseId,
      });
      showFeedback('已打开文件: $fileName');
    } catch (e) {
      _downloadingFileIds.remove(fileId);
      notifyListeners();
      showFeedback(campusError(e), isError: true);
    }
  }

  // --- Auth Actions ---
  Future<void> loginAcademic() async {
    try {
      await api.call('campus.login', {'service': 'academic'});
      _academicAuthRequired = false;
      notifyListeners();
      await loadAcademic();
    } catch (e) {
      _academicError = campusError(e);
      notifyListeners();
    }
  }

  Future<void> loginCanvas() async {
    try {
      await api.call('campus.login', {'service': 'canvas'});
      _canvasAuthRequired = false;
      notifyListeners();
      await loadCanvas();
    } catch (e) {
      _canvasError = campusError(e);
      notifyListeners();
    }
  }
}

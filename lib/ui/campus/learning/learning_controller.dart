// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'package:flutter/material.dart';

import 'package:dansheng_app/ui/core/dansheng_state.dart';

import '../campus_api.dart';
import 'models/canvas_models.dart';
import 'models/timetable_models.dart';

/// State coordinator for the eLearning & Timetable view.
/// Enforces per-source isolation, race/account-change safety, and cached fallbacks.
class LearningController extends ChangeNotifier {
  final DanshengController appController;
  late final CampusApi api;

  final DateTime Function() currentTime;
  LearningController({required this.appController, DateTime Function()? now})
    : currentTime = now ?? DateTime.now {
    api = CampusApi(appController.client);
    _currentAccountId = appController.activeAccountId;
    final now = currentTime().toUtc().add(const Duration(hours: 8));
    _selectedDate = DateTime(now.year, now.month, now.day);
    _calendarMonth = DateTime(now.year, now.month, 1);
  }

  // --- Account & Request Tracking ---
  String? _currentAccountId;
  int _requestToken = 0;

  // --- Calendar & Navigation State ---
  late DateTime _selectedDate;
  DateTime get selectedDate => _selectedDate;

  late DateTime _calendarMonth;
  DateTime get calendarMonth => _calendarMonth;

  String _calendarViewMode = 'week'; // 'week' | 'month'
  String get calendarViewMode => _calendarViewMode;

  // --- Academic (Timetable) State ---
  bool _isUndergraduate = true;
  bool get isUndergraduate => _isUndergraduate;

  String _pgEndpoint = 'primary'; // 'primary' | 'secondary'
  String get pgEndpoint => _pgEndpoint;

  List<Semester> _semesters = [];
  List<Semester> get semesters => _semesters;

  Semester? _selectedSemester;
  Semester? get selectedSemester => _selectedSemester;

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
  List<CanvasCourse> get courses => _courses;

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
      .where((e) => e.key.startsWith('canvas.assignments.sync:'))
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

  final Set<String> _downloadingFileIds = {};
  Set<String> get downloadingFileIds => _downloadingFileIds;

  final Set<String> _downloadedFileIds = {};
  Set<String> get downloadedFileIds => _downloadedFileIds;

  // --- Computed Queries ---

  /// Courses occurring on the currently selected date.
  List<TimetableCourse> get coursesOnSelectedDate {
    if (_timetableData == null) return const [];
    return _timetableData!.coursesOn(_selectedDate);
  }

  /// All assignments flattened across all enrolled courses.
  List<CanvasAssignment> get allAssignments {
    final list = <CanvasAssignment>[];
    for (final sublist in _assignments.values) {
      list.addAll(sublist);
    }
    return list;
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
    final newId = appController.activeAccountId;
    if (newId != _currentAccountId) {
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
  void setUndergraduate(bool value) {
    if (_isUndergraduate != value) {
      _isUndergraduate = value;
      notifyListeners();
      loadAcademicTimetable();
    }
  }

  void setPgEndpoint(String endpoint) {
    if (_pgEndpoint != endpoint) {
      _pgEndpoint = endpoint;
      notifyListeners();
      loadAcademicTimetable();
    }
  }

  void selectSemester(Semester semester) {
    if (_selectedSemester?.externalId != semester.externalId) {
      _selectedSemester = semester;
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
    await Future.wait([loadAcademic(), loadCanvas()]);
  }

  bool _isAuthError(Object e) {
    final s = e.toString();
    return s.contains('AuthenticationRequired') ||
        s.contains('InteractiveLoginRequired') ||
        s.contains('NotLoginError') ||
        s.contains('ConfigurationRequired') ||
        s.contains('401');
  }

  /// Load academic semesters and timetable with cache fallback.
  Future<void> loadAcademic() async {
    final token = _requestToken;
    _academicLoading = true;
    _academicError = null;
    _academicAuthRequired = false;
    _academicFromCache = false;
    notifyListeners();

    try {
      dynamic semResponse;
      try {
        semResponse = await api.call('fudan.semesters');
      } catch (e) {
        if (_isAuthError(e)) rethrow;
        // Try cached semesters
        semResponse = await api.call('campus.cached', {
          'method': 'fudan.semesters',
        });
        _academicFromCache = true;
      }

      if (token != _requestToken) return;

      final catalog = SemesterCatalog.fromJson(semResponse);
      _semesters = catalog.semesters;
      if (_semesters.isNotEmpty) {
        if (catalog.defaultSemesterId != null) {
          _selectedSemester = _semesters.firstWhere(
            (s) => s.externalId == catalog.defaultSemesterId,
            orElse: () => _semesters.first,
          );
        } else {
          _selectedSemester = _semesters.first;
        }
      }

      await loadAcademicTimetable(token: token);
    } catch (e) {
      if (token != _requestToken) return;
      _academicError = campusError(e);
      _academicAuthRequired = _isAuthError(e) || _academicError!.contains('登录');
    } finally {
      if (token == _requestToken) {
        _academicLoading = false;
        notifyListeners();
      }
    }
  }

  /// Load timetable for the currently selected semester/mode.
  Future<void> loadAcademicTimetable({int? token}) async {
    final curToken = token ?? _requestToken;
    _academicLoading = true;
    _academicError = null;
    notifyListeners();

    final method = _isUndergraduate
        ? 'fudan.timetable.sync'
        : 'fudan.postgraduate.sync';
    final params = <String, dynamic>{};
    if (_selectedSemester != null) {
      params['semester'] = _selectedSemester!.toJson();
    }
    if (!_isUndergraduate) {
      params['endpoint'] = _pgEndpoint;
    }

    try {
      dynamic tableResponse;
      try {
        tableResponse = await api.call(method, params);
      } catch (e) {
        if (_isAuthError(e)) rethrow;
        // Fallback to cached timetable
        final cachedParams = Map<String, dynamic>.from(params)
          ..['method'] = method;
        tableResponse = await api.call('campus.cached', cachedParams);
        _academicFromCache = true;
      }

      if (curToken != _requestToken) return;

      _timetableData = TimetableData.fromJson(tableResponse, _selectedSemester);
      _academicError = null;
      _academicAuthRequired = false;
    } catch (e) {
      if (curToken != _requestToken) return;
      _academicError = campusError(e);
      _academicAuthRequired = _isAuthError(e) || _academicError!.contains('登录');
    } finally {
      if (curToken == _requestToken) {
        _academicLoading = false;
        notifyListeners();
      }
    }
  }

  /// Load Canvas courses with cache fallback.
  Future<void> loadCanvas() async {
    final token = _requestToken;
    _canvasLoading = true;
    _canvasError = null;
    _canvasAuthRequired = false;
    _canvasFromCache = false;
    notifyListeners();

    try {
      dynamic coursesResponse;
      try {
        coursesResponse = await api.call('canvas.courses.sync');
      } catch (e) {
        if (_isAuthError(e)) rethrow;
        // Try cached courses
        coursesResponse = await api.call('campus.cached', {
          'method': 'canvas.courses.sync',
        });
        _canvasFromCache = true;
      }

      if (token != _requestToken) return;

      final List<CanvasCourse> courseList = [];
      if (coursesResponse is List) {
        for (final item in coursesResponse) {
          if (item is Map<String, dynamic>) {
            courseList.add(CanvasCourse.fromJson(item));
          }
        }
      }

      _courses = courseList;
      if (_courses.isNotEmpty && _selectedCourseId == null) {
        _selectedCourseId = _courses.first.id;
      }

      // Load assignments and details for enrolled courses
      final enrolled = List<CanvasCourse>.of(_courses);
      for (
        var offset = 0;
        offset < enrolled.length && token == _requestToken;
        offset += 3
      ) {
        await Future.wait(
          enrolled
              .skip(offset)
              .take(3)
              .map((c) => loadCourseDetails(c.id, token: token)),
        );
      }
    } catch (e) {
      if (token != _requestToken) return;
      _canvasError = campusError(e);
      _canvasAuthRequired =
          _isAuthError(e) ||
          _canvasError!.contains('登录') ||
          _canvasError!.contains('绑定');
    } finally {
      if (token == _requestToken) {
        _canvasLoading = false;
        notifyListeners();
      }
    }
  }

  /// Load assignments, folders, materials, announcements for a specific course.
  Future<void> loadCourseDetails(String courseId, {int? token}) async {
    final curToken = token ?? _requestToken;
    final course = _courses.firstWhere(
      (c) => c.id == courseId,
      orElse: () => CanvasCourse(id: courseId, name: ''),
    );

    Future<List?> read(String method) async {
      try {
        final data = await api.call(method, {'course_id': courseId});
        if (data is! List) throw const FormatException('Invalid records');
        if (curToken == _requestToken) {
          _detailErrors.remove('$method:$courseId');
        }
        return data;
      } catch (failure) {
        if (curToken != _requestToken) return null;
        dynamic cached;
        try {
          cached = await api.call('campus.cached', {
            'method': method,
            'course_id': courseId,
          });
        } catch (_) {}
        if (curToken != _requestToken) return null;
        if (cached is List) {
          _canvasFromCache = true;
          return cached;
        }
        _detailErrors['$method:$courseId'] =
            '${course.name}：${campusError(failure)}';
        _canvasAuthRequired = _canvasAuthRequired || _isAuthError(failure);
        return null;
      }
    }

    final results = await Future.wait([
      read('canvas.assignments.sync'),
      read('canvas.announcements.sync'),
    ]);
    if (curToken != _requestToken) return;
    if (results[0] != null) {
      _assignments[courseId] = results[0]!
          .whereType<Map<String, dynamic>>()
          .map((r) => CanvasAssignment.fromJson(r, courseId, course.name))
          .toList();
    }
    if (results[1] != null) {
      _announcements[courseId] = results[1]!
          .whereType<Map<String, dynamic>>()
          .map((r) => CanvasAnnouncement.fromJson(r, courseId, course.name))
          .toList();
    }
    notifyListeners();
    if (courseId != _selectedCourseId) return;
    final assets = await Future.wait([
      read('canvas.folders.sync'),
      read('canvas.materials.sync'),
      read('canvas.modules.sync'),
    ]);
    if (curToken != _requestToken) return;
    if (assets[0] != null) {
      _folders[courseId] = assets[0]!
          .whereType<Map<String, dynamic>>()
          .map(CanvasFolder.fromJson)
          .toList();
    }
    if (assets[1] != null) {
      _materials[courseId] = assets[1]!
          .whereType<Map<String, dynamic>>()
          .map((r) => CanvasMaterial.fromJson(r, courseId))
          .toList();
    }
    if (assets[2] != null) {
      _modules[courseId] = assets[2]!
          .whereType<Map<String, dynamic>>()
          .map(CanvasModule.fromJson)
          .toList();
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _requestToken++;
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

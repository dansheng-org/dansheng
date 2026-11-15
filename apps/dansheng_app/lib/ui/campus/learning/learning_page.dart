// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import 'package:dansheng_app/ui/core/dansheng_state.dart';

import '../../widgets/campus_account_actions.dart';

import '../campus_api.dart';
import 'course_page.dart';
import 'cloud/drive_picker.dart';
import 'chat/learning_chat_page.dart';
import 'models/canvas_models.dart';
import 'learning_controller.dart';
import 'personal_agenda.dart';
import 'models/timetable_models.dart';
import 'widgets/calendar_header.dart';
import 'widgets/course_list_view.dart';
import 'widgets/day_schedule_view.dart';

/// Main eLearning & Timetable tab view.
/// Shows the week timetable grid (or a month calendar), the schedule of the selected day and
/// every enrolled eLearning course; a timetable block or a course row opens that course's page.
class LearningPage extends StatefulWidget {
  final DanshengController controller;

  final DateTime Function()? now;
  const LearningPage({super.key, required this.controller, this.now});

  @override
  State<LearningPage> createState() => _LearningPageState();
}

class _LearningPageState extends State<LearningPage> {
  late final LearningController _learningController;
  late final CampusApi _campusApi;
  CampusApi get campusApi => _campusApi;
  bool _hasInitialLoaded = false;

  @override
  void initState() {
    super.initState();
    _campusApi = CampusApi(widget.controller.client);
    _learningController = LearningController(
      appController: widget.controller,
      now: widget.now,
    );
    widget.controller.addListener(_onAppControllerChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Enforce "no network on tab hidden": only sync when visible (TickerMode is true).
    final isVisible = TickerMode.valuesOf(context).enabled;
    if (isVisible && !_hasInitialLoaded) {
      _hasInitialLoaded = true;
      _learningController.loadAll();
    }
  }

  void _onAppControllerChanged() {
    _learningController.checkAccountChange();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onAppControllerChanged);
    _learningController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _learningController,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            title: const Text(
              '课程学习',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 18),
            ),
            elevation: 0,
            scrolledUnderElevation: 1,
            actions: [CampusAccountActions(controller: widget.controller)],
          ),
          body: RefreshIndicator(
            onRefresh: () => _learningController.loadAll(),
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Wrap(
                    spacing: 8,
                    children: [
                      TextButton.icon(
                        icon: const Icon(
                          Icons.chat_bubble_outline_rounded,
                          size: 18,
                        ),
                        label: const Text('课程消息'),
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => LearningChatPage(
                              controller: _learningController,
                            ),
                          ),
                        ),
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.event_note_outlined, size: 18),
                        label: const Text('个人日程'),
                        onPressed: _openAgenda,
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.cloud_outlined, size: 18),
                        label: const Text('云盘'),
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                DriveHubPage(api: _learningController.api),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // Week timetable grid / month calendar
                CalendarHeader(
                  controller: _learningController,
                  onOpenCourses: _openTimetableCourses,
                ),
                const SizedBox(height: 6),

                // Schedule of the selected day: courses + due assignments
                DayScheduleView(
                  controller: _learningController,
                  onOpenCourse: (course) => _openTimetableCourses([course]),
                ),
                const SizedBox(height: 8),

                // Every enrolled eLearning course
                CourseListView(
                  controller: _learningController,
                  onOpenArchive: _openArchive,
                  onOpen: (course) => _openCourse(canvasCourseId: course.id),
                ),

                const SizedBox(height: 32),
              ],
            ),
          ),
        );
      },
    );
  }

  void _openAgenda() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => Scaffold(
          appBar: AppBar(title: const Text('个人日程')),
          body: ListenableBuilder(
            listenable: _learningController,
            builder: (_, _) => ListView(
              padding: const EdgeInsets.all(16),
              children: [
                PersonalAgenda(
                  api: _campusApi,
                  day: _learningController.selectedDate,
                  account: widget.controller.activeAccountId,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openArchive() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => Scaffold(
          appBar: AppBar(title: const Text('过往学期与其他课程')),
          body: ListenableBuilder(
            listenable: _learningController,
            builder: (context, _) {
              final groups = <String, List<CanvasCourse>>{};
              for (final course in _learningController.archivedCourses) {
                final term = course.termName?.trim();
                final name = term == null || term.isEmpty ? '未标明学期' : term;
                groups.putIfAbsent(name, () => []).add(course);
              }
              final terms = groups.keys.toList()
                ..sort((a, b) => b.compareTo(a));
              return ListView(
                children: [
                  if (terms.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('暂无其他学期课程'),
                    ),
                  for (final term in terms)
                    CourseListView(
                      controller: _learningController,
                      courses: groups[term],
                      title: term,
                      onOpen: (course) =>
                          _openCourse(canvasCourseId: course.id),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// Opens the course behind a timetable block; a slot shared by several
  /// courses asks which one first.
  Future<void> _openTimetableCourses(List<TimetableCourse> courses) async {
    if (courses.isEmpty) return;
    var course = courses.first;
    if (courses.length > 1) {
      final picked = await showModalBottomSheet<TimetableCourse>(
        context: context,
        showDragHandle: true,
        builder: (sheet) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final item in courses)
                ListTile(
                  leading: const Icon(Icons.menu_book_outlined),
                  title: Text(item.name),
                  subtitle: Text(
                    [
                      item.timeSpanFormatted,
                      if ((item.room ?? '').isNotEmpty) item.room!,
                    ].join(' · '),
                  ),
                  onTap: () => Navigator.pop(sheet, item),
                ),
            ],
          ),
        ),
      );
      if (picked == null || !mounted) return;
      course = picked;
    }
    _openCourse(
      session: course,
      canvasCourseId: _learningController.canvasCourseFor(course)?.id,
    );
  }

  void _openCourse({TimetableCourse? session, String? canvasCourseId}) {
    // Selecting here (not inside the new route's build) starts the fetch of
    // the course files before the page appears.
    if (canvasCourseId != null) {
      _learningController.selectCourse(canvasCourseId);
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CoursePage(
          controller: _learningController,
          session: session,
          canvasCourseId: canvasCourseId,
        ),
      ),
    );
  }
}

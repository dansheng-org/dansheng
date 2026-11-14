// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import 'package:dansheng_app/ui/core/dansheng_state.dart';
import 'package:dansheng_app/ui/screens/account_balance_screen.dart';

import '../campus_api.dart';
import 'course_page.dart';
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
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

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
            actions: [
              // Manual Refresh
              IconButton(
                icon: const Icon(Icons.refresh_rounded),
                tooltip: '刷新',
                onPressed: () => _learningController.loadAll(),
              ),
              // Account & Sign-in actions menu
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert_rounded),
                tooltip: '服务选项',
                onSelected: (val) {
                  if (val == 'login_academic') {
                    _learningController.loginAcademic();
                  } else if (val == 'login_canvas') {
                    _learningController.loginCanvas();
                  } else if (val == 'account') {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            AccountBalanceScreen(controller: widget.controller),
                      ),
                    );
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'account',
                    child: Row(
                      children: [
                        Icon(Icons.account_circle_outlined, size: 18),
                        SizedBox(width: 8),
                        Text('账号与卡包'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'login_academic',
                    child: Row(
                      children: [
                        Icon(Icons.school_outlined, size: 18),
                        SizedBox(width: 8),
                        Text('登录教务系统'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'login_canvas',
                    child: Row(
                      children: [
                        Icon(Icons.computer_outlined, size: 18),
                        SizedBox(width: 8),
                        Text('登录 Canvas 平台'),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
          body: RefreshIndicator(
            onRefresh: () => _learningController.loadAll(),
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                // Week timetable grid / month calendar
                CalendarHeader(
                  controller: _learningController,
                  onOpenCourses: _openTimetableCourses,
                ),
                _buildFilterBar(context, colorScheme),
                const SizedBox(height: 6),

                // Schedule of the selected day: courses + due assignments
                DayScheduleView(
                  controller: _learningController,
                  onOpenCourse: (course) => _openTimetableCourses([course]),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: PersonalAgenda(
                    api: _campusApi,
                    day: _learningController.selectedDate,
                    account: widget.controller.activeAccountId,
                  ),
                ),

                const SizedBox(height: 8),

                // Every enrolled eLearning course
                CourseListView(
                  controller: _learningController,
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

  /// Compact bar displaying academic level toggle (UG/PG) and Semester selector.
  Widget _buildFilterBar(BuildContext context, ColorScheme colorScheme) {
    final ctrl = _learningController;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          // UG / PG toggle
          SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: true,
                label: Text('本科生', style: TextStyle(fontSize: 12)),
              ),
              ButtonSegment(
                value: false,
                label: Text('研究生', style: TextStyle(fontSize: 12)),
              ),
            ],
            selected: {ctrl.isUndergraduate},
            onSelectionChanged: (set) {
              if (set.isNotEmpty) {
                ctrl.setUndergraduate(set.first);
              }
            },
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              padding: WidgetStateProperty.all(
                const EdgeInsets.symmetric(horizontal: 6, vertical: 0),
              ),
            ),
          ),

          // Semester Dropdown
          if (ctrl.semesters.isNotEmpty)
            SizedBox(
              width: 154,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: colorScheme.outlineVariant.withValues(alpha: 0.4),
                  ),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: ctrl.selectedSemester?.externalId,
                    isExpanded: true,
                    icon: const Icon(Icons.arrow_drop_down, size: 20),
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onSurface,
                      fontWeight: FontWeight.w500,
                    ),
                    items: ctrl.semesters.map((Semester s) {
                      return DropdownMenuItem<String>(
                        value: s.externalId,
                        child: Text(
                          s.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      );
                    }).toList(),
                    onChanged: (newId) {
                      if (newId != null) {
                        final found = ctrl.semesters.firstWhere(
                          (s) => s.externalId == newId,
                        );
                        ctrl.selectSemester(found);
                      }
                    },
                  ),
                ),
              ),
            )
          else
            SizedBox(
              width: 100,
              child: Text(
                '暂无学期列表',
                style: TextStyle(fontSize: 12, color: colorScheme.outline),
              ),
            ),

          // PG Endpoint Toggle (if postgraduate)
          if (!ctrl.isUndergraduate) ...[
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: 'primary',
                  label: Text('主端', style: TextStyle(fontSize: 11)),
                ),
                ButtonSegment(
                  value: 'secondary',
                  label: Text('次端', style: TextStyle(fontSize: 11)),
                ),
              ],
              selected: {ctrl.pgEndpoint},
              onSelectionChanged: (set) {
                if (set.isNotEmpty) {
                  ctrl.setPgEndpoint(set.first);
                }
              },
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                padding: WidgetStateProperty.all(
                  const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
                ),
              ),
            ),
          ],
        ],
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

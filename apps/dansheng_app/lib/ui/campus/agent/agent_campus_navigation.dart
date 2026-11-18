// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../agent/agent_campus_link.dart';
import '../../../bridge.g.dart';
import '../../core/dansheng_client.dart';
import '../../core/dansheng_state.dart';
import '../campus_account_boundary.dart';
import '../campus_api.dart';
import '../ehall/life_page.dart';
import '../ehall/notice_sheet.dart';
import '../forum/hole_detail_page.dart';
import '../learning/course_page.dart';
import '../learning/learning_controller.dart';
import '../learning/models/canvas_models.dart';
import '../learning/widgets/assignment_widgets.dart';

/// Opens a campus destination above the current Agent conversation.
Future<void> openAgentCampusLink(
  BuildContext context,
  DanshengController controller,
  AgentCampusLink link,
) async {
  if (!context.mounted) return;
  try {
    switch (link) {
      case AgentCourseLink() || AgentAssignmentLink():
        await _openLearning(context, controller, link);
      case AgentForumLink() || AgentLibraryLink() || AgentNoticeLink():
        await _openCampusPage(context, controller, link);
    }
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(campusError(error))));
    }
  }
}

Future<void> _openLearning(
  BuildContext context,
  DanshengController controller,
  AgentCampusLink link,
) async {
  final learning = LearningController(appController: controller);
  try {
    learning.api.accountScope!.check();
    if (link is AgentCourseLink) {
      unawaited(learning.loadCanvas());
      await _push(
        context,
        CoursePage(controller: learning, canvasCourseId: link.courseId),
      );
    } else if (link is AgentAssignmentLink) {
      final result = await learning.api.call('canvas.assignments.sync', {
        'course_id': link.courseId,
      });
      if (!context.mounted || ModalRoute.of(context)?.isCurrent == false) {
        return;
      }
      final assignment = rowsOf(result)
          .where((row) => payloadOf(row)['published'] != false)
          .map((row) => CanvasAssignment.fromJson(row, link.courseId))
          .where(
            (item) =>
                item.courseId == link.courseId && item.id == link.assignmentId,
          )
          .firstOrNull;
      if (assignment == null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('当前账号未找到该 Canvas 作业。')));
        return;
      }

      final navigator = Navigator.of(context);
      showAssignmentDetails(context, learning, assignment);
      // The existing sheet helper returns void. Capture its route without popping
      // so the controller can outlive the sheet's dismissal transition.
      Route<dynamic>? sheet;
      navigator.popUntil((route) {
        sheet = route;
        return true;
      });
      if (sheet case final TransitionRoute<dynamic> route) {
        await route.completed;
      }
    }
  } finally {
    learning.dispose();
  }
}

Future<void> _openCampusPage(
  BuildContext context,
  DanshengController controller,
  AgentCampusLink link,
) async {
  final api = CampusApi.forAccount(controller);
  _ScopedPageController? pageController;
  try {
    api.accountScope!.check();
    if (link is AgentNoticeLink) {
      await showNoticeSheet(
        context,
        api,
        title: link.title,
        url: link.noticeUrl.toString(),
      );
      return;
    }
    if (link is AgentForumLink && !controller.forumEnabled) {
      throw PlatformException(code: 'ForumConsentRequired');
    }
    final scopedController = pageController = _ScopedPageController(api);
    await _push(
      context,
      CampusAccountBoundary(
        api: api,
        child: link is AgentForumLink
            ? HoleDetailPage(
                controller: scopedController,
                holeId: link.holeId,
                initialFloorId: link.floorId,
              )
            : LifePage(
                controller: scopedController,
                service: LifeService.library,
              ),
      ),
    );
  } finally {
    pageController?.dispose();
    api.accountScope?.dispose();
  }
}

Future<void> _push(BuildContext context, Widget page) async {
  final route = MaterialPageRoute<void>(builder: (_) => page);
  await Navigator.of(context).push(route);
  await route.completed;
}

// Forum and library pages construct CampusApi from their controller's client.
// Keep those calls bound to this route's account, including any nested pages.
class _ScopedPageController extends DanshengController {
  _ScopedPageController(this.api)
    : super(client: DanshengClient(bridge: _ScopedCampusBridge(api)));

  final CampusApi api;

  @override
  String? get activeAccountId => api.accountScope!.accountId;
}

class _ScopedCampusBridge implements DanshengBridge {
  const _ScopedCampusBridge(this.api);

  final CampusApi api;

  @override
  Future<String> invoke(HostCommand command, String payload) async {
    if (command != HostCommand.campus) {
      throw PlatformException(code: 'CapabilityUnavailable');
    }
    final request = jsonDecode(payload) as Map<String, dynamic>;
    final result = await api.call(
      request['method'] as String,
      request['params'] as Map<String, dynamic>,
    );
    return jsonEncode(result);
  }
}

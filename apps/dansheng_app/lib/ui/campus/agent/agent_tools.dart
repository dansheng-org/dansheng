// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/services.dart';

import '../../../agent/agent_session.dart';
import '../../../agent/agent_types.dart';
import '../../../agent/campus_tools.dart';
import '../campus_api.dart';
import 'agent_course_files.dart';
import 'agent_public_campus.dart';
import 'agent_remote_files.dart';

AgentToolRegistry campusAgentTools(
  CampusApi api, {
  required String? Function() activeAccount,
  required bool Function() forumEnabled,
  AgentTool? webTool,
}) => campusToolRegistry(
  activeAccount: activeAccount,
  forumEnabled: forumEnabled,
  webTool: webTool,
  extraTools: [
    ...publicCampusAgentTools(),
    ...courseFileAgentTools(api),
    ...cloudFileAgentTools(api),
  ],
  read: (method, params) async {
    final forumSearch = method == 'community.tea.search';
    try {
      final result = await api.call(
        forumSearch ? 'forum.search' : method,
        params,
      );
      if (result != null) return (result, false);
      throw PlatformException(code: 'SourceSchemaChanged');
    } on PlatformException catch (error) {
      if (!forumSearch && !isAccountChange(error)) {
        try {
          final cached = await api.call('campus.cached', {
            ...params,
            'method': method,
          });
          if (cached != null) return (cached, true);
        } on PlatformException catch (cacheError) {
          if (isAccountChange(cacheError)) {
            throw AgentFailure(campusError(cacheError));
          }
        }
      }
      throw AgentFailure(campusError(error));
    }
  },
);

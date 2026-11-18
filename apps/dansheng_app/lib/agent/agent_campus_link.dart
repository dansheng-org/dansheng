// SPDX-License-Identifier: GPL-3.0-or-later

import 'agent_types.dart';

const _origin = 'dansheng://agent';
const _noticeHosts = {'jwc': 'jwc.fudan.edu.cn', 'gs': 'gs.fudan.edu.cn'};
final _idPattern = RegExp(r'^[1-9][0-9]{0,23}$');
final _safePath = RegExp(r'^/[A-Za-z0-9_./-]+$');
final _noticePath = RegExp(r'^/(?:[A-Za-z0-9_-]+/)*[A-Za-z0-9_-]+\.(htm|psp)$');

/// A validated, native destination that can be stored in the Agent transcript.
sealed class AgentCampusLink {
  const AgentCampusLink._(this.title, this.uri);

  final String title;
  final Uri uri;

  static bool isCanvasId(String value) =>
      _idPattern.stringMatch(value) == value;

  static AgentCampusLink? fromJson(Json json) {
    final title = json['title'];
    final url = json['url'];
    if (title is! String ||
        title.trim().isEmpty ||
        title.length > 512 ||
        url is! String ||
        url.length > 2048 ||
        !url.startsWith('$_origin/')) {
      return null;
    }
    final path = url.substring(_origin.length);
    if (_safePath.stringMatch(path) != path) return null;
    final uri = Uri.tryParse(url);
    if (uri == null || uri.toString() != url) {
      return null;
    }
    final parts = uri.pathSegments;

    return switch (parts) {
      ['forum', final hole] when _forumId(hole) != null => AgentForumLink._(
        title,
        uri,
        _forumId(hole)!,
        null,
      ),
      ['forum', final hole, final floor]
          when _forumId(hole) != null && _forumId(floor) != null =>
        AgentForumLink._(title, uri, _forumId(hole)!, _forumId(floor)),
      ['course', final id] when isCanvasId(id) => AgentCourseLink._(
        title,
        uri,
        id,
      ),
      ['assignment', final course, final id]
          when isCanvasId(course) && isCanvasId(id) =>
        AgentAssignmentLink._(title, uri, course, id),
      ['library'] => AgentLibraryLink._(title, uri),
      ['notice', final site, ...final path] => _notice(
        title,
        uri,
        site,
        '/${path.join('/')}',
      ),
      _ => null,
    };
  }

  /// Wrap a notice returned by Fudan's official undergraduate or graduate site.
  static AgentCampusLink? fromNotice(String title, String url) {
    if (url.length > 2048) return null;
    final uri = Uri.tryParse(url);
    if (uri == null || url != 'https://${uri.host}${uri.path}') return null;
    final site = _noticeHosts.entries
        .where((entry) => entry.value == uri.host)
        .firstOrNull
        ?.key;
    if (site == null) return null;
    return fromJson({
      'title': title,
      'url': '$_origin/notice/$site${uri.path}',
    });
  }

  static int? _forumId(String value) {
    if (!isCanvasId(value)) return null;
    final id = int.tryParse(value);
    return id?.toString() == value ? id : null;
  }

  static AgentNoticeLink? _notice(
    String title,
    Uri uri,
    String site,
    String path,
  ) {
    final host = _noticeHosts[site];
    if (host == null || _noticePath.stringMatch(path) != path) return null;
    return AgentNoticeLink._(title, uri, Uri.https(host, path));
  }

  Json toJson() => {'title': title, 'url': uri.toString()};
}

final class AgentForumLink extends AgentCampusLink {
  const AgentForumLink._(super.title, super.uri, this.holeId, this.floorId)
    : super._();

  final int holeId;
  final int? floorId;
}

final class AgentCourseLink extends AgentCampusLink {
  const AgentCourseLink._(super.title, super.uri, this.courseId) : super._();

  final String courseId;
}

final class AgentAssignmentLink extends AgentCampusLink {
  const AgentAssignmentLink._(
    super.title,
    super.uri,
    this.courseId,
    this.assignmentId,
  ) : super._();

  final String courseId;
  final String assignmentId;
}

final class AgentLibraryLink extends AgentCampusLink {
  const AgentLibraryLink._(super.title, super.uri) : super._();
}

final class AgentNoticeLink extends AgentCampusLink {
  const AgentNoticeLink._(super.title, super.uri, this.noticeUrl) : super._();

  final Uri noticeUrl;
}

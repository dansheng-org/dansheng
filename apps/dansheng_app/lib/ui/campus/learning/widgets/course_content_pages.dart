// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../campus_api.dart';
import '../../campus_account_boundary.dart';
import '../learning_controller.dart';
import '../models/canvas_models.dart';
import '../models/timetable_models.dart';
import 'learning_common.dart';

/// Loads one record on open and shows it, with retry on failure.
class _LoadingScaffold<T> extends StatefulWidget {
  final CampusApi api;
  final String title;
  final Future<T> Function() load;
  final Widget Function(BuildContext context, T value) builder;

  const _LoadingScaffold({
    super.key,
    required this.api,
    required this.title,
    required this.load,
    required this.builder,
  });

  @override
  State<_LoadingScaffold<T>> createState() => _LoadingScaffoldState<T>();
}

class _LoadingScaffoldState<T> extends State<_LoadingScaffold<T>> {
  late final CampusApi _api = widget.api;
  late Future<T> _future = Future.sync(() {
    _api.accountScope?.check();
    return widget.load();
  });

  void _retry() {
    if (_api.isCurrent) setState(() => _future = widget.load());
  }

  @override
  Widget build(BuildContext context) {
    return CampusAccountBoundary(
      api: _api,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            widget.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 18),
          ),
          actions: [
            IconButton(
              tooltip: '刷新',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: _retry,
            ),
          ],
        ),
        body: FutureBuilder<T>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError || !snapshot.hasData) {
              return ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  InfoBanner(
                    message: campusErrorText(snapshot.error),
                    actionLabel: '重试',
                    onAction: _retry,
                  ),
                ],
              );
            }
            return widget.builder(context, snapshot.data as T);
          },
        ),
      ),
    );
  }
}

String campusErrorText(Object? error) =>
    error == null ? '内容暂时无法显示' : campusError(error);

Widget _bodyText(BuildContext context, String text, {String empty = '暂无内容'}) {
  final cs = Theme.of(context).colorScheme;
  return SelectableText(
    text.isEmpty ? empty : text,
    style: TextStyle(
      fontSize: 14,
      height: 1.55,
      color: text.isEmpty ? cs.outline : cs.onSurface,
    ),
  );
}

/// A Canvas wiki page rendered as plain text.
class CanvasPageScreen extends StatelessWidget {
  final LearningController controller;
  final String courseId;
  final String slug;
  final String title;

  const CanvasPageScreen({
    super.key,
    required this.controller,
    required this.courseId,
    required this.slug,
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    return _LoadingScaffold<CanvasPage>(
      api: controller.api,
      title: title,
      load: () => controller.readPage(courseId, slug),
      builder: (context, page) {
        final cs = Theme.of(context).colorScheme;
        return ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          children: [
            Text(
              page.title,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: cs.onSurface,
              ),
            ),
            if (page.updatedAt != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '更新于 ${formatCampusTime(page.updatedAt)}',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ),
            const Divider(height: 24),
            _bodyText(context, page.text, empty: '此页面没有文字内容'),
          ],
        );
      },
    );
  }
}

/// A discussion topic and its reply tree. Read-only: nothing is posted and
/// no read state is changed.
class DiscussionScreen extends StatelessWidget {
  final LearningController controller;
  final String courseId;
  final CanvasDiscussionTopic topic;

  const DiscussionScreen({
    super.key,
    required this.controller,
    required this.courseId,
    required this.topic,
  });

  Future<(CanvasDiscussionTopic, CanvasDiscussionView?, Object?)>
  _load() async {
    final api = controller.api;
    final fresh = await controller
        .readDiscussion(courseId, topic.id)
        .catchError((Object error) {
          if (isAccountChange(error)) throw error;
          return topic;
        });
    api.accountScope?.check();
    if (!fresh.canSeePosts || fresh.locked && fresh.requireInitialPost) {
      return (fresh, null, null);
    }
    try {
      return (
        fresh,
        await controller.readDiscussionThread(courseId, topic.id),
        null,
      );
    } catch (error) {
      return (fresh, null, error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _LoadingScaffold<
      (CanvasDiscussionTopic, CanvasDiscussionView?, Object?)
    >(
      api: controller.api,
      title: topic.title,
      load: _load,
      builder: (context, value) {
        final (t, view, error) = value;
        final cs = Theme.of(context).colorScheme;
        final message = plainText(t.message);
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            Text(
              t.title,
              style: TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w700,
                color: cs.onSurface,
              ),
            ),
            if (t.postedAt != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '发布于 ${formatCampusTime(t.postedAt)}',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ),
            const SizedBox(height: 12),
            _bodyText(context, message, empty: '主题没有正文'),
            if (t.attachmentNames.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final name in t.attachmentNames)
                Row(
                  children: [
                    Icon(
                      Icons.attach_file_rounded,
                      size: 14,
                      color: cs.primary,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        name,
                        style: TextStyle(fontSize: 12, color: cs.primary),
                      ),
                    ),
                  ],
                ),
            ],
            const Divider(height: 28),
            if (view == null && error == null)
              const EmptyHint(
                icon: Icons.lock_outline_rounded,
                text: '需要先在 eLearning 中发表回复才能查看其他人的回复',
              )
            else if (view == null)
              InfoBanner(message: campusErrorText(error))
            else if (view.entries.isEmpty)
              const EmptyHint(icon: Icons.forum_outlined, text: '还没有回复')
            else ...[
              Text(
                '${view.count} 条回复',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              for (final entry in view.entries) _entry(context, view, entry, 0),
            ],
          ],
        );
      },
    );
  }

  Widget _entry(
    BuildContext context,
    CanvasDiscussionView view,
    CanvasDiscussionEntry entry,
    int depth,
  ) {
    final cs = Theme.of(context).colorScheme;
    final unread = view.unreadIds.contains(entry.id);
    final author = entry.deleted
        ? '已删除'
        : view.participants[entry.userId] ?? '课程成员';
    return Padding(
      padding: EdgeInsets.only(left: (depth.clamp(0, 4)) * 14.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: cs.surfaceContainerLow,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: unread
                    ? cs.primary.withValues(alpha: 0.5)
                    : cs.outlineVariant.withValues(alpha: 0.4),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        author,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: cs.onSurface,
                        ),
                      ),
                    ),
                    if (unread) const SoftBadge('未读'),
                    if (entry.createdAt != null)
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: Text(
                          formatCampusTime(entry.createdAt),
                          style: TextStyle(
                            fontSize: 11,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                SelectableText(
                  entry.deleted ? '此回复已删除' : entry.text,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.45,
                    color: entry.deleted ? cs.outline : cs.onSurface,
                  ),
                ),
              ],
            ),
          ),
          for (final reply in entry.replies)
            _entry(context, view, reply, depth + 1),
        ],
      ),
    );
  }
}

/// The public syllabus of an undergraduate lesson from the academic system.
class SyllabusScreen extends StatelessWidget {
  final LearningController controller;
  final TimetableCourse course;

  const SyllabusScreen({
    super.key,
    required this.controller,
    required this.course,
  });

  @override
  Widget build(BuildContext context) {
    return _LoadingScaffold<CourseSyllabus>(
      api: controller.api,
      title: '${course.name} · 教学大纲',
      load: () => controller.readSyllabus(course),
      builder: (context, syllabus) {
        final cs = Theme.of(context).colorScheme;
        if (syllabus.sections.isEmpty) {
          return ListView(
            padding: const EdgeInsets.all(16),
            children: const [
              EmptyHint(
                icon: Icons.menu_book_outlined,
                text: '教务系统暂未公开这门课的教学大纲',
              ),
            ],
          );
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          children: [
            for (final (title, text) in syllabus.sections) ...[
              if (title.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12, bottom: 6),
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: cs.primary,
                    ),
                  ),
                ),
              _bodyText(context, text),
            ],
          ],
        );
      },
    );
  }
}

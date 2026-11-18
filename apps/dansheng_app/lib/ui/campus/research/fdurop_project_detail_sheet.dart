// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'research_models.dart';
import 'research_service.dart';

/// Modal bottom sheet displaying detailed profile of an FDUROP open research project.
Future<void> showFduropProjectDetailSheet(
  BuildContext context,
  FduropProjectItem project,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (ctx) => _FduropProjectDetailView(initialProject: project),
  );
}

class _FduropProjectDetailView extends StatefulWidget {
  final FduropProjectItem initialProject;

  const _FduropProjectDetailView({required this.initialProject});

  @override
  State<_FduropProjectDetailView> createState() =>
      _FduropProjectDetailViewState();
}

class _FduropProjectDetailViewState extends State<_FduropProjectDetailView> {
  late FduropProjectItem _project;
  final ResearchService _service = ResearchService.instance;

  @override
  void initState() {
    super.initState();
    _project = widget.initialProject.copyWith(
      isBookmarked: _service.isFduropProjectBookmarked(
        widget.initialProject.id,
      ),
    );
  }

  void _toggleBookmark() {
    _service.toggleBookmarkFduropProject(_project.id);
    setState(() {
      _project = _project.copyWith(
        isBookmarked: _service.isFduropProjectBookmarked(_project.id),
      );
    });
    final msg = _project.isBookmarked
        ? '已收藏课题「${_project.title}」'
        : '已取消收藏「${_project.title}」';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _copyContact() async {
    await Clipboard.setData(ClipboardData(text: _project.contactEmail));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已复制导师邮箱：${_project.contactEmail}'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, scrollController) {
        return ListView(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            // Header: Program & Status
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    _project.program,
                    style: TextStyle(
                      color: colorScheme.onPrimaryContainer,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    _project.status,
                    style: TextStyle(
                      color: colorScheme.onSecondaryContainer,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: _project.isBookmarked ? '取消收藏' : '收藏课题',
                  icon: Icon(
                    _project.isBookmarked
                        ? Icons.bookmark
                        : Icons.bookmark_border,
                    color: _project.isBookmarked
                        ? colorScheme.primary
                        : colorScheme.outline,
                  ),
                  onPressed: _toggleBookmark,
                ),
              ],
            ),
            const SizedBox(height: 10),

            // Title
            Text(
              _project.title,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
                height: 1.3,
              ),
            ),
            const SizedBox(height: 12),

            // Mentor & Dept badges
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                Chip(
                  avatar: const Icon(Icons.person_outline, size: 16),
                  label: Text('${_project.advisor} (${_project.advisorTitle})'),
                  visualDensity: VisualDensity.compact,
                ),
                Chip(
                  avatar: const Icon(Icons.apartment, size: 16),
                  label: Text('${_project.department} · ${_project.campus}'),
                  visualDensity: VisualDensity.compact,
                ),
                Chip(
                  avatar: const Icon(Icons.people_outline, size: 16),
                  label: Text('名额 ${_project.quota} 人'),
                  visualDensity: VisualDensity.compact,
                ),
                Chip(
                  avatar: const Icon(Icons.event_outlined, size: 16),
                  label: Text('截止 ${_project.deadline}'),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Target Grade Card
            Card(
              color: colorScheme.surfaceContainerHighest.withAlpha(120),
              elevation: 0,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.school, size: 18, color: colorScheme.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '面向对象：${_project.targetGrade}',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Description
            Text(
              '课题内容与研究目标',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _project.description,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.55),
            ),
            const SizedBox(height: 18),

            // Requirements
            Text(
              '申请要求与先修知识',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _project.requirements,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
            ),
            const SizedBox(height: 24),

            // Contact & Action
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.email_outlined),
              title: const Text('导师联系邮箱'),
              subtitle: Text(_project.contactEmail),
              trailing: IconButton(
                icon: const Icon(Icons.copy),
                tooltip: '复制邮箱',
                onPressed: _copyContact,
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _copyContact,
              icon: const Icon(Icons.send_outlined),
              label: const Text('联系导师申请课题'),
            ),
          ],
        );
      },
    );
  }
}

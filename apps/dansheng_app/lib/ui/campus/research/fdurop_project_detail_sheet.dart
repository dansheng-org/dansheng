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
  bool _isLoadingDetail = false;

  @override
  void initState() {
    super.initState();
    _project = widget.initialProject.copyWith(
      isBookmarked: _service.isFduropProjectBookmarked(
        widget.initialProject.id,
      ),
    );
    _loadDetail();
  }

  Future<void> _loadDetail() async {
    if (_project.id.isEmpty) return;
    setState(() => _isLoadingDetail = true);
    try {
      final detail = await _service.getFduropProjectDetail(_project.id);
      if (detail != null && mounted) {
        setState(() {
          _project = detail.copyWith(
            isBookmarked: _service.isFduropProjectBookmarked(detail.id),
          );
        });
      }
    } catch (_) {
      // Keep initial project info
    } finally {
      if (mounted) {
        setState(() => _isLoadingDetail = false);
      }
    }
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
    if (_project.contactEmail.trim().isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('暂无公开导师邮箱，可前往平台查询或直接联系院系'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }
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

  Future<void> _copyPhone() async {
    final phone = _project.tutorMobile;
    if (phone == null || phone.trim().isEmpty) return;
    await Clipboard.setData(ClipboardData(text: phone));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已复制导师电话：$phone'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _copyPortalUrl() async {
    await Clipboard.setData(ClipboardData(text: _project.portalUrl));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已复制教师开放课题平台网址：${_project.portalUrl}'),
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
            if (_isLoadingDetail) ...[
              const LinearProgressIndicator(minHeight: 2),
              const SizedBox(height: 8),
            ],
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

            // Topic Labels & Subject Kinds tags if present
            if (_project.topicLabels.isNotEmpty ||
                _project.subjectKinds.isNotEmpty) ...[
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  ..._project.topicLabels.map(
                    (tag) => Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.primaryContainer.withAlpha(120),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        tag,
                        style: TextStyle(
                          fontSize: 11,
                          color: colorScheme.onPrimaryContainer,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                  ..._project.subjectKinds.map(
                    (sub) => Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.tertiaryContainer.withAlpha(120),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        sub,
                        style: TextStyle(
                          fontSize: 11,
                          color: colorScheme.onTertiaryContainer,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
            ],

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
              _project.description.isNotEmpty ? _project.description : '暂无详细描述',
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
              _project.requirements.isNotEmpty
                  ? _project.requirements
                  : '暂无特殊先修要求',
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
            ),
            const SizedBox(height: 18),

            // Tutor Introduce (if present)
            if (_project.tutorIntroduce != null &&
                _project.tutorIntroduce!.trim().isNotEmpty) ...[
              Text(
                '指导教师简介',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _project.tutorIntroduce!,
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.55),
              ),
              const SizedBox(height: 18),
            ],

            // Lab Introduce (if present)
            if (_project.labIntroduce != null &&
                _project.labIntroduce!.trim().isNotEmpty) ...[
              Text(
                '课题组与实验室介绍',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _project.labIntroduce!,
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.55),
              ),
              const SizedBox(height: 18),
            ],

            // FDUROP Teacher Open Topic Portal Card
            Card(
              color: colorScheme.surfaceContainerHighest.withAlpha(120),
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: BorderSide(color: colorScheme.outlineVariant),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.open_in_browser,
                          size: 18,
                          color: colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'FDUROP 教师开放课题系统',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: colorScheme.primary,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.copy, size: 18),
                          tooltip: '复制申报网址',
                          onPressed: _copyPortalUrl,
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _project.portalUrl,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontSize: 11,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Contact & Action
            if (_project.tutorMobile != null &&
                _project.tutorMobile!.trim().isNotEmpty)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.phone_outlined),
                title: const Text('导师联系电话'),
                subtitle: Text(_project.tutorMobile!),
                trailing: IconButton(
                  icon: const Icon(Icons.copy),
                  tooltip: '复制电话',
                  onPressed: _copyPhone,
                ),
              ),
            if (_project.contactEmail.isNotEmpty)
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
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _copyPortalUrl,
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: const Text('复制平台网址'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _copyContact,
                    icon: const Icon(Icons.send_outlined, size: 18),
                    label: const Text('联系导师申请'),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

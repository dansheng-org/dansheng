// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../campus_api.dart';
import 'forum_format.dart';
import 'forum_models.dart';
import 'forum_service.dart';

/// Modal dialog for publishing a new post with mandatory preview & confirmation.
class ForumPublishDialog extends StatefulWidget {
  final List<TeaDivision> divisions;
  final int? initialDivisionId;
  final Future<int?> Function({
    required int divisionId,
    required String content,
    required List<String> tags,
  })
  onPublish;
  final Future<Map<String, dynamic>?> Function({
    required String action,
    int? divisionId,
    required String content,
  })?
  onReconcile;

  const ForumPublishDialog({
    super.key,
    required this.divisions,
    this.initialDivisionId,
    required this.onPublish,
    this.onReconcile,
  });

  @override
  State<ForumPublishDialog> createState() => _ForumPublishDialogState();
}

class _ForumPublishDialogState extends State<ForumPublishDialog> {
  late int _selectedDivisionId;
  final _contentController = TextEditingController();
  final _tagsController = TextEditingController();

  bool _isPreviewMode = false;
  bool _isSubmitting = false;
  bool _isReconciling = false;
  String? _errorMessage;
  String? _successMessage;
  bool _isUncertainOutcome = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialDivisionId != null &&
        widget.divisions.any((d) => d.divisionId == widget.initialDivisionId)) {
      _selectedDivisionId = widget.initialDivisionId!;
    } else if (widget.divisions.isNotEmpty) {
      _selectedDivisionId = widget.divisions.first.divisionId;
    } else {
      _selectedDivisionId = 1;
    }
  }

  @override
  void dispose() {
    _contentController.dispose();
    _tagsController.dispose();
    super.dispose();
  }

  List<String> get _parsedTags {
    final raw = _tagsController.text.trim();
    if (raw.isEmpty) return [];
    return raw
        .split(RegExp(r'[,，\s]+'))
        .where((t) => t.trim().isNotEmpty)
        .map((t) => t.trim().replaceAll('#', ''))
        .toList();
  }

  TeaDivision get _currentDivision {
    return widget.divisions.firstWhere(
      (d) => d.divisionId == _selectedDivisionId,
      orElse: () => TeaDivision(
        divisionId: _selectedDivisionId,
        name: '分区 $_selectedDivisionId',
      ),
    );
  }

  void _goToPreview() {
    final content = _contentController.text.trim();
    if (content.isEmpty) {
      setState(() {
        _errorMessage = '帖子内容不能为空';
      });
      return;
    }
    setState(() {
      _errorMessage = null;
      _isPreviewMode = true;
      _isUncertainOutcome = false;
    });
  }

  Future<void> _handleConfirmPublish() async {
    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
      _isUncertainOutcome = false;
    });

    try {
      final holeId = await widget.onPublish(
        divisionId: _selectedDivisionId,
        content: _contentController.text.trim(),
        tags: _parsedTags,
      );
      if (mounted) {
        Navigator.of(context).pop(holeId ?? true);
      }
    } catch (e) {
      if (mounted) {
        final errText = campusError(e);
        final isUncertain =
            e.toString().contains('NeedsReconciliation') ||
            errText.contains('待核对') ||
            e.toString().contains('Timeout') ||
            e.toString().contains('DeadlineExceeded');
        setState(() {
          _isSubmitting = false;
          _errorMessage = isUncertain ? '提交结果待核对，请勿重复提交。' : errText;
          _isUncertainOutcome = isUncertain;
        });
      }
    }
  }

  /// Read-only reconciliation of uncertain publish.
  /// Never re-submits automatically. Only definitive matched result authorizes published.
  Future<void> _handleReconcile() async {
    if (widget.onReconcile == null) return;

    setState(() {
      _isReconciling = true;
      _errorMessage = null;
      _successMessage = null;
    });

    try {
      final result = await widget.onReconcile!(
        action: 'publish',
        divisionId: _selectedDivisionId,
        content: _contentController.text.trim(),
      );

      if (!mounted) return;

      if (ForumService.isDefinitiveMatch(result)) {
        // Authoritative confirmation: show published and return success
        final resolvedId =
            result?['hole_id'] ?? result?['response']?['hole_id'];
        setState(() {
          _isReconciling = false;
          _isUncertainOutcome = false;
          _successMessage = resolvedId != null
              ? '核对确认：已成功发布（#$resolvedId）'
              : '核对确认：已成功发布！';
        });
        await Future.delayed(const Duration(milliseconds: 600));
        if (mounted) {
          Navigator.of(context).pop(resolvedId ?? true);
        }
      } else {
        // Empty or ambiguous outcome: remains pending, never re-submit
        setState(() {
          _isReconciling = false;
          _errorMessage = '核对结果：未在最新发布记录中确认匹配。状态仍为待核对，请稍后再次核对或先刷新列表，切勿重复提交。';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isReconciling = false;
          _errorMessage = '核对结果：未在最新发布记录中确认匹配。状态仍为待核对，请稍后再次核对或先刷新列表，切勿重复提交。';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 500, maxHeight: 600),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Row(
                children: [
                  Icon(
                    _isPreviewMode
                        ? Icons.visibility_outlined
                        : Icons.edit_note_rounded,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _isPreviewMode ? '发帖确认与预览' : '发布新帖',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: (_isSubmitting || _isReconciling)
                        ? null
                        : () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const Divider(height: 16),

              Expanded(
                child: SingleChildScrollView(
                  child: _isPreviewMode
                      ? _buildPreviewView()
                      : _buildInputView(),
                ),
              ),

              const SizedBox(height: 12),
              _buildActions(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInputView() {
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_errorMessage != null) ...[
          Container(
            padding: const EdgeInsets.all(10),
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              _errorMessage!,
              style: TextStyle(
                color: colorScheme.onErrorContainer,
                fontSize: 13,
              ),
            ),
          ),
        ],

        // Division selector
        const Text(
          '选择分区',
          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
        ),
        const SizedBox(height: 6),
        DropdownButtonFormField<int>(
          initialValue: _selectedDivisionId,
          decoration: InputDecoration(
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 10,
            ),
          ),
          items: widget.divisions.map((d) {
            return DropdownMenuItem<int>(
              value: d.divisionId,
              child: Text(d.name),
            );
          }).toList(),
          onChanged: (val) {
            if (val != null) setState(() => _selectedDivisionId = val);
          },
        ),

        const SizedBox(height: 14),

        // Tags input
        const Text(
          '标签 (可选)',
          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: _tagsController,
          decoration: InputDecoration(
            hintText: '多个标签用逗号或空格隔开',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 10,
            ),
          ),
        ),

        const SizedBox(height: 14),

        // Content
        const Text(
          '帖子正文',
          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: _contentController,
          maxLines: 6,
          minLines: 4,
          decoration: InputDecoration(
            hintText: '写下你想交流的内容（将以匿名身份发布）...',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            contentPadding: const EdgeInsets.all(12),
          ),
        ),
      ],
    );
  }

  Widget _buildPreviewView() {
    final colorScheme = Theme.of(context).colorScheme;
    final tags = _parsedTags;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_successMessage != null) ...[
          Container(
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: colorScheme.primary),
            ),
            child: Row(
              children: [
                Icon(Icons.check_circle_outline, color: colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _successMessage!,
                    style: TextStyle(
                      color: colorScheme.onPrimaryContainer,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],

        if (_errorMessage != null) ...[
          Container(
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: colorScheme.error),
            ),
            child: Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: colorScheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _errorMessage!,
                    style: TextStyle(
                      color: colorScheme.onErrorContainer,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],

        // Division preview
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.category_outlined, size: 20),
          title: const Text('发布分区', style: TextStyle(fontSize: 12)),
          subtitle: Text(
            _currentDivision.name,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
          ),
        ),

        // Tags preview
        if (tags.isNotEmpty) ...[
          const SizedBox(height: 6),
          const Text('标签', style: TextStyle(fontSize: 12)),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: tags.map((t) {
              return Chip(
                label: Text('#$t'),
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
              );
            }).toList(),
          ),
        ],

        const SizedBox(height: 8),

        // Anonymity reminder
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              Icon(
                Icons.security_rounded,
                size: 16,
                color: colorScheme.primary,
              ),
              const SizedBox(width: 6),
              const Expanded(
                child: Text(
                  '匿名保护：将自动生成匿名代号，不公开个人信息',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 12),

        // Content preview
        const Text(
          '正文',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerLowest,
            border: Border.all(color: colorScheme.outlineVariant),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            cleanPreviewText(_contentController.text.trim()),
            style: const TextStyle(fontSize: 14, height: 1.4),
          ),
        ),
      ],
    );
  }

  Widget _buildActions() {
    if (_isPreviewMode) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          OutlinedButton(
            onPressed: (_isSubmitting || _isReconciling)
                ? null
                : () {
                    setState(() {
                      _isPreviewMode = false;
                      _errorMessage = null;
                      _isUncertainOutcome = false;
                    });
                  },
            child: const Text('返回修改'),
          ),
          const SizedBox(width: 10),
          if (_isUncertainOutcome) ...[
            TextButton(
              onPressed: () {
                Navigator.of(context).pop('reload_required');
              },
              child: const Text('先刷新'),
            ),
            const SizedBox(width: 6),
            FilledButton.icon(
              onPressed: _isReconciling ? null : _handleReconcile,
              icon: _isReconciling
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.fact_check_outlined, size: 18),
              label: const Text('核对结果'),
            ),
          ] else ...[
            FilledButton(
              onPressed: _isSubmitting ? null : _handleConfirmPublish,
              child: _isSubmitting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('确认发布'),
            ),
          ],
        ],
      );
    } else {
      return Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          const SizedBox(width: 10),
          FilledButton(onPressed: _goToPreview, child: const Text('预览并确认')),
        ],
      );
    }
  }
}

/// Modal dialog for replying to a hole with preview & confirmation.
class ForumReplyDialog extends StatefulWidget {
  final int holeId;
  final Future<int?> Function({required int holeId, required String content})
  onReply;
  final Future<Map<String, dynamic>?> Function({
    required String action,
    int? holeId,
    required String content,
  })?
  onReconcile;

  const ForumReplyDialog({
    super.key,
    required this.holeId,
    required this.onReply,
    this.onReconcile,
  });

  @override
  State<ForumReplyDialog> createState() => _ForumReplyDialogState();
}

class _ForumReplyDialogState extends State<ForumReplyDialog> {
  final _contentController = TextEditingController();
  bool _isPreviewMode = false;
  bool _isSubmitting = false;
  bool _isReconciling = false;
  String? _errorMessage;
  String? _successMessage;
  bool _isUncertainOutcome = false;

  @override
  void dispose() {
    _contentController.dispose();
    super.dispose();
  }

  void _goToPreview() {
    final content = _contentController.text.trim();
    if (content.isEmpty) {
      setState(() => _errorMessage = '回复内容不能为空');
      return;
    }
    setState(() {
      _errorMessage = null;
      _isPreviewMode = true;
      _isUncertainOutcome = false;
    });
  }

  Future<void> _handleConfirmReply() async {
    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
      _isUncertainOutcome = false;
    });

    try {
      final floorId = await widget.onReply(
        holeId: widget.holeId,
        content: _contentController.text.trim(),
      );
      if (mounted) {
        Navigator.of(context).pop(floorId ?? true);
      }
    } catch (e) {
      if (mounted) {
        final errText = campusError(e);
        final isUncertain =
            e.toString().contains('NeedsReconciliation') ||
            errText.contains('待核对') ||
            e.toString().contains('Timeout') ||
            e.toString().contains('DeadlineExceeded');
        setState(() {
          _isSubmitting = false;
          _errorMessage = isUncertain ? '提交结果待核对，请勿重复提交。' : errText;
          _isUncertainOutcome = isUncertain;
        });
      }
    }
  }

  /// Read-only reconciliation of uncertain reply.
  /// Never re-submits automatically. Only definitive matched result authorizes published.
  Future<void> _handleReconcile() async {
    if (widget.onReconcile == null) return;

    setState(() {
      _isReconciling = true;
      _errorMessage = null;
      _successMessage = null;
    });

    try {
      final result = await widget.onReconcile!(
        action: 'reply',
        holeId: widget.holeId,
        content: _contentController.text.trim(),
      );

      if (!mounted) return;

      if (ForumService.isDefinitiveMatch(result)) {
        final resolvedFloorId =
            result?['floor_id'] ?? result?['response']?['floor_id'];
        setState(() {
          _isReconciling = false;
          _isUncertainOutcome = false;
          _successMessage = resolvedFloorId != null
              ? '核对确认：已成功回复（#$resolvedFloorId）'
              : '核对确认：已成功回复！';
        });
        await Future.delayed(const Duration(milliseconds: 600));
        if (mounted) {
          Navigator.of(context).pop(resolvedFloorId ?? true);
        }
      } else {
        setState(() {
          _isReconciling = false;
          _errorMessage = '核对结果：未在最新回复记录中确认匹配。状态仍为待核对，请稍后再次核对或先刷新，切勿重复提交。';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isReconciling = false;
          _errorMessage = '核对结果：未在最新回复记录中确认匹配。状态仍为待核对，请稍后再次核对或先刷新，切勿重复提交。';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 520),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.reply_rounded, color: colorScheme.primary),
                  const SizedBox(width: 8),
                  Text(
                    _isPreviewMode ? '回复确认与预览' : '回复 #${widget.holeId}',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: (_isSubmitting || _isReconciling)
                        ? null
                        : () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const Divider(height: 16),

              Expanded(
                child: SingleChildScrollView(
                  child: _isPreviewMode
                      ? _buildPreviewView()
                      : _buildInputView(),
                ),
              ),

              const SizedBox(height: 12),
              _buildActions(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInputView() {
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_errorMessage != null) ...[
          Container(
            padding: const EdgeInsets.all(10),
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              _errorMessage!,
              style: TextStyle(
                color: colorScheme.onErrorContainer,
                fontSize: 13,
              ),
            ),
          ),
        ],

        const Text(
          '回复内容',
          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: _contentController,
          maxLines: 5,
          minLines: 3,
          decoration: InputDecoration(
            hintText: '写下你的回复（将以匿名身份发布）...',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            contentPadding: const EdgeInsets.all(12),
          ),
        ),
      ],
    );
  }

  Widget _buildPreviewView() {
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_successMessage != null) ...[
          Container(
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: colorScheme.primary),
            ),
            child: Row(
              children: [
                Icon(Icons.check_circle_outline, color: colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _successMessage!,
                    style: TextStyle(
                      color: colorScheme.onPrimaryContainer,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],

        if (_errorMessage != null) ...[
          Container(
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: colorScheme.error),
            ),
            child: Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: colorScheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _errorMessage!,
                    style: TextStyle(
                      color: colorScheme.onErrorContainer,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],

        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.tag, size: 20),
          title: const Text('帖子', style: TextStyle(fontSize: 12)),
          subtitle: Text(
            '#${widget.holeId}',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
          ),
        ),

        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              Icon(
                Icons.security_rounded,
                size: 16,
                color: colorScheme.primary,
              ),
              const SizedBox(width: 6),
              const Expanded(
                child: Text('匿名保护：将自动分配随机匿名代号', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),

        const SizedBox(height: 12),
        const Text(
          '回复预览',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerLowest,
            border: Border.all(color: colorScheme.outlineVariant),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            cleanPreviewText(_contentController.text.trim()),
            style: const TextStyle(fontSize: 14, height: 1.4),
          ),
        ),
      ],
    );
  }

  Widget _buildActions() {
    if (_isPreviewMode) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          OutlinedButton(
            onPressed: (_isSubmitting || _isReconciling)
                ? null
                : () {
                    setState(() {
                      _isPreviewMode = false;
                      _errorMessage = null;
                      _isUncertainOutcome = false;
                    });
                  },
            child: const Text('返回修改'),
          ),
          const SizedBox(width: 10),
          if (_isUncertainOutcome) ...[
            TextButton(
              onPressed: () {
                Navigator.of(context).pop('reload_required');
              },
              child: const Text('先刷新'),
            ),
            const SizedBox(width: 6),
            FilledButton.icon(
              onPressed: _isReconciling ? null : _handleReconcile,
              icon: _isReconciling
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.fact_check_outlined, size: 18),
              label: const Text('核对结果'),
            ),
          ] else ...[
            FilledButton(
              onPressed: _isSubmitting ? null : _handleConfirmReply,
              child: _isSubmitting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('确认回复'),
            ),
          ],
        ],
      );
    } else {
      return Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          const SizedBox(width: 10),
          FilledButton(onPressed: _goToPreview, child: const Text('预览并确认')),
        ],
      );
    }
  }
}

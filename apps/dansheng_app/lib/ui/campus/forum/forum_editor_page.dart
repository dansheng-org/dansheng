// SPDX-License-Identifier: GPL-3.0-or-later
// Editor flow adapted from DanXi lib/page/forum/hole_editor.dart
// (OTEditor, BBSEditorWidget, BBSEditorPage). Copyright (C) 2021 DanXi-Dev;
// GPL-3.0-or-later.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../campus_api.dart';
import 'forum_content.dart';
import 'forum_format.dart';
import 'forum_models.dart';
import 'forum_service.dart';

enum ForumEditorMode { publish, reply, modify }

/// What the person wrote. [divisionId] and [tags] only matter for a new post.
class ForumEditorText {
  const ForumEditorText(this.content, {this.divisionId, this.tags = const []});
  final String content;
  final int? divisionId;
  final List<String> tags;
}

/// How the editor closed after sending.
class ForumEditorResult {
  const ForumEditorResult({this.id, this.floor, this.uncertain = false});

  /// The new hole or floor, when the forum said.
  final int? id;

  /// The floor as the forum now has it, after an edit.
  final TeaFloor? floor;

  /// The forum gave no answer and the check that followed found nothing yet.
  /// The caller refreshes; the draft is kept so nothing typed is lost.
  final bool uncertain;
}

/// Unsent text kept per target while the app runs, as DanXi's `editorCache`.
class ForumDrafts {
  ForumDrafts._();
  static final _texts = <String, String>{};
  static final _tags = <String, List<String>>{};
  static final _divisions = <String, int>{};

  static String? text(String key) => _texts[key];
  static void clear(String key) {
    _texts.remove(key);
    _tags.remove(key);
    _divisions.remove(key);
  }
}

/// Full-screen editor for a new post, a reply or an edit of one's own floor.
class ForumEditorPage extends StatefulWidget {
  const ForumEditorPage({
    super.key,
    required this.mode,
    required this.onSubmit,
    this.onReconcile,
    this.divisions = const [],
    this.initialDivisionId,
    this.holeId,
    this.quoteFloor,
    this.editFloor,
    this.onOpenLink,
  });

  final ForumEditorMode mode;
  final List<TeaDivision> divisions;
  final int? initialDivisionId;
  final int? holeId;

  /// The floor being answered; its `##id` starts the reply, as in DanXi.
  final TeaFloor? quoteFloor;

  /// The own floor being edited.
  final TeaFloor? editFloor;

  /// Sends the text; returns the new hole or floor id when known.
  final Future<Object?> Function(ForumEditorText text) onSubmit;

  /// Read-only check whether an unanswered post or reply arrived.
  final Future<Map<String, dynamic>?> Function(ForumEditorText text)?
  onReconcile;

  final ValueChanged<Uri>? onOpenLink;

  String get draftKey => switch (mode) {
    ForumEditorMode.publish => 'publish',
    ForumEditorMode.reply => 'reply:$holeId:${quoteFloor?.floorId ?? ''}',
    ForumEditorMode.modify => 'modify:${editFloor?.floorId}',
  };

  @override
  State<ForumEditorPage> createState() => _ForumEditorPageState();
}

class _ForumEditorPageState extends State<ForumEditorPage> {
  late final TextEditingController _content;
  final _tagInput = TextEditingController();
  late List<String> _tags;
  int? _divisionId;
  bool _fullscreen = false;
  bool _sending = false;
  String? _status;
  String? _error;

  static const _maxTags = 10;

  @override
  void initState() {
    super.initState();
    final key = widget.draftKey;
    final initial = switch (widget.mode) {
      ForumEditorMode.modify => widget.editFloor?.content ?? '',
      ForumEditorMode.reply when widget.quoteFloor != null =>
        '##${widget.quoteFloor!.floorId}\n',
      _ => '',
    };
    _content = TextEditingController(text: ForumDrafts._texts[key] ?? initial)
      ..addListener(() => ForumDrafts._texts[key] = _content.text);
    _tags = [...?ForumDrafts._tags[key]];
    final ids = widget.divisions.map((d) => d.divisionId);
    final wanted = ForumDrafts._divisions[key] ?? widget.initialDivisionId;
    _divisionId = ids.contains(wanted)
        ? wanted
        : (ids.isEmpty ? widget.initialDivisionId : ids.first);
  }

  @override
  void dispose() {
    _content.dispose();
    _tagInput.dispose();
    super.dispose();
  }

  String get _title => switch (widget.mode) {
    ForumEditorMode.publish => '发布新帖',
    ForumEditorMode.reply when widget.quoteFloor != null =>
      '回复 ##${widget.quoteFloor!.floorId}',
    ForumEditorMode.reply => '回复 #${widget.holeId}',
    ForumEditorMode.modify => '修改 ##${widget.editFloor?.floorId}',
  };

  /// A reply that is only the `##id` it started with says nothing yet.
  bool get _hasText {
    final text = _content.text.trim();
    if (text.isEmpty) return false;
    final quote = widget.quoteFloor;
    return quote == null || text != '##${quote.floorId}';
  }

  void _addTag([String? raw]) {
    final parts = (raw ?? _tagInput.text)
        .split(RegExp(r'[,，\s]+'))
        .map((t) => t.trim().replaceAll('#', ''))
        .where((t) => t.isNotEmpty && t.length <= 32);
    setState(() {
      for (final tag in parts) {
        if (_tags.length >= _maxTags) break;
        if (!_tags.contains(tag)) _tags.add(tag);
      }
      ForumDrafts._tags[widget.draftKey] = [..._tags];
      _tagInput.clear();
    });
  }

  ForumEditorText get _text => ForumEditorText(
    _content.text.trim(),
    divisionId: _divisionId,
    tags: [..._tags],
  );

  Future<void> _send() async {
    if (_sending) return;
    if (_tagInput.text.trim().isNotEmpty) _addTag();
    if (!_hasText) {
      setState(
        () => _error = widget.mode == ForumEditorMode.publish
            ? '帖子内容不能为空'
            : '回复内容不能为空',
      );
      return;
    }
    if (widget.mode == ForumEditorMode.publish && _divisionId == null) {
      setState(() => _error = '请选择分区');
      return;
    }
    final text = _text;
    setState(() {
      _sending = true;
      _error = null;
      _status = null;
    });
    try {
      final answer = await widget.onSubmit(text);
      ForumDrafts.clear(widget.draftKey);
      if (!mounted) return;
      Navigator.of(context).pop(
        ForumEditorResult(
          id: answer is int ? answer : null,
          floor: answer is TeaFloor ? answer : null,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      final code = e is PlatformException ? e.code : e.toString();
      if (code.contains('Cancelled')) {
        setState(() => _sending = false);
        return;
      }
      final unanswered = const [
        'NeedsReconciliation',
        'Timeout',
        'Deadline',
      ].any(code.contains);
      if (unanswered && widget.onReconcile != null) {
        await _settle(text);
        return;
      }
      setState(() {
        _sending = false;
        _error = campusError(e);
      });
    }
  }

  /// The forum did not answer. Nothing is sent again: the account's own latest
  /// posts are read a few times, and the page closes either way so the caller
  /// can refresh and show what is actually there.
  Future<void> _settle(ForumEditorText text) async {
    setState(() => _status = '正在确认是否已发出…');
    for (var attempt = 0; attempt < 3; attempt++) {
      await Future<void>.delayed(Duration(milliseconds: 800 * (attempt + 1)));
      if (!mounted) return;
      try {
        final result = await widget.onReconcile!(text);
        if (ForumService.isDefinitiveMatch(result)) {
          ForumDrafts.clear(widget.draftKey);
          if (!mounted) return;
          final key = widget.mode == ForumEditorMode.publish
              ? 'hole_id'
              : 'floor_id';
          final id = result?[key] ?? result?['outcome']?[key];
          Navigator.of(context)
              .pop(ForumEditorResult(id: id is int ? id : null));
          return;
        }
      } catch (_) {
        // A failed check says nothing either way; try again.
      }
    }
    if (mounted) {
      Navigator.of(context).pop(const ForumEditorResult(uncertain: true));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !_sending,
      child: Scaffold(
        appBar: AppBar(
          title: Text(_title),
          actions: [
            IconButton(
              tooltip: _fullscreen ? '退出全屏' : '全屏编辑',
              icon: Icon(
                _fullscreen ? Icons.close_fullscreen : Icons.fullscreen,
              ),
              onPressed: () => setState(() => _fullscreen = !_fullscreen),
            ),
            IconButton(
              key: const Key('forum-editor-send'),
              tooltip: '发送',
              onPressed: _sending ? null : _send,
              icon: _sending
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send_rounded),
            ),
          ],
        ),
        body: SafeArea(
          child: _fullscreen
              ? Padding(padding: const EdgeInsets.all(12), child: _field(true))
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  children: [
                    if (_status != null || _error != null)
                      _banner(
                        _error ?? _status!,
                        _error != null
                            ? colors.errorContainer
                            : colors.secondaryContainer,
                        _error != null
                            ? colors.onErrorContainer
                            : colors.onSecondaryContainer,
                      ),
                    if (widget.mode == ForumEditorMode.publish) ...[
                      _divisionPicker(),
                      const SizedBox(height: 8),
                      _tagEditor(),
                      const SizedBox(height: 8),
                    ],
                    if (widget.quoteFloor != null) _quote(widget.quoteFloor!),
                    _toolbar(),
                    _field(false),
                    const SizedBox(height: 12),
                    const Divider(),
                    Text('预览', style: TextStyle(color: colors.outline)),
                    const SizedBox(height: 4),
                    ValueListenableBuilder<TextEditingValue>(
                      valueListenable: _content,
                      builder: (context, value, _) => value.text.trim().isEmpty
                          ? Text(
                              '输入内容后在此预览',
                              style: TextStyle(color: colors.outline),
                            )
                          : ForumContent(
                              content: value.text,
                              selectable: false,
                            ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _banner(String text, Color background, Color foreground) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      children: [
        if (_status != null && _error == null) ...[
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: Text(text, style: TextStyle(color: foreground, fontSize: 13)),
        ),
      ],
    ),
  );

  Widget _field(bool expands) => TextField(
    key: const Key('forum-editor-content'),
    controller: _content,
    autofocus: true,
    enabled: !_sending,
    keyboardType: TextInputType.multiline,
    textAlignVertical: TextAlignVertical.top,
    maxLines: expands ? null : 12,
    minLines: expands ? null : 6,
    expands: expands,
    decoration: InputDecoration(
      hintText: widget.mode == ForumEditorMode.publish
          ? '写下你想交流的内容，将以匿名身份发布'
          : '友善发言，将以匿名身份回复',
      border: expands ? InputBorder.none : const OutlineInputBorder(),
    ),
  );

  Widget _divisionPicker() {
    if (widget.divisions.isEmpty) return const SizedBox.shrink();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final d in widget.divisions)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                label: Text(d.name),
                selected: d.divisionId == _divisionId,
                onSelected: _sending
                    ? null
                    : (_) => setState(() {
                        _divisionId = d.divisionId;
                        ForumDrafts._divisions[widget.draftKey] = d.divisionId;
                      }),
              ),
            ),
        ],
      ),
    );
  }

  Widget _tagEditor() => Wrap(
    spacing: 6,
    runSpacing: 4,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      for (final tag in _tags)
        InputChip(
          label: Text('#$tag'),
          onDeleted: _sending
              ? null
              : () => setState(() {
                  _tags.remove(tag);
                  ForumDrafts._tags[widget.draftKey] = [..._tags];
                }),
        ),
      if (_tags.length < _maxTags)
        SizedBox(
          width: 160,
          child: TextField(
            key: const Key('forum-editor-tag'),
            controller: _tagInput,
            enabled: !_sending,
            decoration: const InputDecoration(
              isDense: true,
              hintText: '添加标签，回车确认',
              prefixIcon: Icon(Icons.sell_outlined, size: 18),
              border: InputBorder.none,
            ),
            onSubmitted: _addTag,
          ),
        ),
    ],
  );

  Widget _quote(TeaFloor floor) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: colors.primary, width: 3)),
        color: colors.surfaceContainerHighest,
      ),
      child: Text(
        '${floor.anonyname ?? '热心同学'}：${cleanPreviewText(floor.content ?? '')}',
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
      ),
    );
  }

  Widget _toolbar() => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Row(
      children: [
        _help(
          Icons.code_rounded,
          'Markdown',
          '支持 Markdown 语法：**粗体**、*斜体*、`代码`、> 引用、- 列表、[链接](https://…)。\n'
              '输入 #帖子号 或 ##楼层号 可以链接到对应的帖子或楼层。',
        ),
        _help(
          Icons.functions_rounded,
          'LaTeX',
          r'支持 LaTeX 公式：行内用 $公式$，独立成行用 $$公式$$，例如 $\frac{a}{b}$。',
        ),
        TextButton(
          onPressed: widget.onOpenLink == null
              ? null
              : () => widget.onOpenLink!(
                  Uri.parse('https://www.fduhole.com/doc'),
                ),
          child: const Text('社区公约'),
        ),
      ],
    ),
  );

  Widget _help(IconData icon, String title, String body) => TextButton.icon(
    icon: Icon(icon, size: 18),
    label: Text(title),
    onPressed: () => showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(ctx).textTheme.titleMedium),
              const SizedBox(height: 12),
              Text(body),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Opens the editor as a page and returns how it closed, or null when left.
Future<ForumEditorResult?> openForumEditor(
  BuildContext context,
  ForumEditorPage page,
) => Navigator.of(context).push<ForumEditorResult>(
  MaterialPageRoute(builder: (_) => page, fullscreenDialog: true),
);

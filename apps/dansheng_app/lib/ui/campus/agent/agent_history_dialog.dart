// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';

import '../../../agent/agent_history.dart';
import '../../../agent/agent_types.dart';

class AgentHistoryDialog extends StatefulWidget {
  const AgentHistoryDialog({
    super.key,
    required this.load,
    required this.rename,
    required this.delete,
    this.selectedId,
  });

  final Future<List<AgentConversationSummary>> Function() load;
  final Future<void> Function(AgentConversationSummary chat, String title)
  rename;
  final Future<void> Function(AgentConversationSummary chat) delete;
  final String? selectedId;

  @override
  State<AgentHistoryDialog> createState() => _AgentHistoryDialogState();
}

enum _HistoryAction { rename, delete }

class _AgentHistoryDialogState extends State<AgentHistoryDialog> {
  final _title = TextEditingController();
  List<AgentConversationSummary>? _history;
  AgentConversationSummary? _editing;
  _HistoryAction? _action;
  String _query = '';
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final history = await widget.load();
      if (mounted) setState(() => _history = history);
    } on AgentFailure catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = '无法读取对话历史。');
    }
  }

  void _edit(AgentConversationSummary chat, _HistoryAction action) {
    _title.text = chat.title;
    setState(() {
      _editing = chat;
      _action = action;
      _error = null;
    });
  }

  void _cancelEdit() {
    setState(() {
      _editing = null;
      _action = null;
      _error = null;
    });
  }

  Future<void> _commitEdit() async {
    final chat = _editing!;
    final title = _title.text.trim();
    if (_action == _HistoryAction.rename &&
        (title.isEmpty || title.length > 72)) {
      setState(() => _error = '请输入 1 至 72 个字符的标题。');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_action == _HistoryAction.rename) {
        await widget.rename(chat, title);
      } else {
        await widget.delete(chat);
      }
      if (!mounted) return;
      _cancelEdit();
      await _load();
    } on AgentFailure catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = '无法更新对话历史。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final editing = _editing;
    if (editing != null) {
      final renaming = _action == _HistoryAction.rename;
      return AlertDialog(
        title: Text(renaming ? '重命名对话' : '删除对话？'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (renaming)
                TextField(
                  autofocus: true,
                  controller: _title,
                  maxLength: 72,
                  decoration: const InputDecoration(labelText: '对话标题'),
                  enabled: !_busy,
                  onSubmitted: (_) {
                    if (!_busy) _commitEdit();
                  },
                )
              else
                Text('将永久删除「${editing.title}」和其中的消息。'),
              if (_error case final String error)
                Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : _cancelEdit,
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: _busy ? null : _commitEdit,
            child: Text(renaming ? '保存标题' : '删除对话'),
          ),
        ],
      );
    }
    final history = _history;
    final visible = history
        ?.where((chat) => chat.title.toLowerCase().contains(_query))
        .toList();
    final l10n = MaterialLocalizations.of(context);
    return AlertDialog(
      title: const Text('对话历史'),
      content: SizedBox(
        width: 440,
        height: (MediaQuery.sizeOf(context).height * .48)
            .clamp(132.0, 410.0)
            .toDouble(),
        child: Column(
          children: [
            if (history?.isNotEmpty ?? false)
              TextField(
                decoration: const InputDecoration(
                  labelText: '搜索对话标题',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: (text) =>
                    setState(() => _query = text.trim().toLowerCase()),
              ),
            if (_error case final String error)
              Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (visible == null)
              Expanded(
                child: Center(
                  child: _error == null
                      ? const Text('正在读取对话…')
                      : TextButton(
                          onPressed: () {
                            setState(() => _error = null);
                            _load();
                          },
                          child: const Text('重试'),
                        ),
                ),
              )
            else if (visible.isEmpty)
              Expanded(
                child: Center(
                  child: Text(history!.isEmpty ? '还没有对话' : '没有匹配的对话'),
                ),
              )
            else
              Expanded(
                child: ListView.builder(
                  itemCount: visible.length,
                  itemBuilder: (context, index) {
                    final chat = visible[index];
                    final updated = DateTime.fromMillisecondsSinceEpoch(
                      chat.updatedAt,
                    );
                    return ListTile(
                      selected: widget.selectedId == chat.id,
                      title: Text(
                        chat.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(l10n.formatShortDate(updated)),
                      onTap: _busy
                          ? null
                          : () => Navigator.of(context).pop(chat.id),
                      trailing: PopupMenuButton<_HistoryAction>(
                        tooltip: '对话选项',
                        enabled: !_busy,
                        onSelected: (action) => _edit(chat, action),
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: _HistoryAction.rename,
                            child: Text('重命名'),
                          ),
                          PopupMenuItem(
                            value: _HistoryAction.delete,
                            child: Text('删除'),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

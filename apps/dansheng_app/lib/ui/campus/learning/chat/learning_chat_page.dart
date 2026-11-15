// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../campus_api.dart';
import '../learning_controller.dart';
import '../models/canvas_models.dart';
import 'chat_data.dart';

class LearningChatPage extends StatefulWidget {
  const LearningChatPage({
    super.key,
    required this.controller,
    this.course,
    this.initialRecipient,
  });
  final LearningController controller;
  final CanvasCourse? course;
  final ChatRecipient? initialRecipient;

  @override
  State<LearningChatPage> createState() => _LearningChatPageState();
}

class _LearningChatPageState extends State<LearningChatPage> {
  final _body = TextEditingController();
  final _subject = TextEditingController();
  final _search = TextEditingController();
  final _recipients = <String, String>{};
  List<Map<String, dynamic>> _conversations = [], _people = [];
  Map<String, dynamic>? _conversation;
  CanvasCourse? _course;
  String? _account, _error;
  int _generation = 0, _searchGeneration = 0;
  bool _busy = false, _sending = false, _searching = false;
  bool _compose = false, _auth = false, _accountChanged = false;
  bool _tokenRequired = false;
  bool _csrfRequired = false;
  // An ambiguous transport failure must not make a second send automatic.
  bool _uncertainSend = false;

  @override
  void initState() {
    super.initState();
    _account = widget.controller.appController.activeAccountId;
    _course = widget.course ?? widget.controller.courses.firstOrNull;
    widget.controller.appController.addListener(_accountListener);
    widget.controller.addListener(_coursesListener);
    final recipient = widget.initialRecipient;
    if (widget.course != null && recipient != null && recipient.id.isNotEmpty) {
      _compose = true;
      _recipients[recipient.id] = recipient.name;
    } else {
      _load();
    }
  }

  @override
  void didUpdateWidget(covariant LearningChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.appController.removeListener(_accountListener);
      oldWidget.controller.removeListener(_coursesListener);
      widget.controller.appController.addListener(_accountListener);
      widget.controller.addListener(_coursesListener);
      _invalidate();
    } else if (oldWidget.course?.id != widget.course?.id) {
      _invalidate();
    }
  }

  void _accountListener() {
    if (_account != widget.controller.appController.activeAccountId) {
      _invalidate();
    }
  }

  void _invalidate() {
    _generation++;
    _searchGeneration++;
    _body.clear();
    _subject.clear();
    _search.clear();
    setState(() {
      _accountChanged = true;
      _conversations = [];
      _people = [];
      _recipients.clear();
      _conversation = null;
      _course = null;
      _compose = false;
      _busy = _sending = _searching = false;
      _error = null;
    });
  }

  void _coursesListener() {
    _accountListener();
    if (_accountChanged) return;
    if (widget.course == null &&
        !widget.controller.courses.any((course) => course.id == _course?.id)) {
      _generation++;
      _searchGeneration++;
      _course = widget.controller.courses.firstOrNull;
      _conversations = [];
      _conversation = null;
      _people = [];
      _recipients.clear();
      _body.clear();
      _subject.clear();
      _search.clear();
      _compose = _busy = _sending = _searching = _uncertainSend = false;
      _error = null;
      _load();
    }
    if (mounted) setState(() {});
  }

  bool get _valid =>
      mounted &&
      !_accountChanged &&
      _account == widget.controller.appController.activeAccountId;
  bool _current(int version) => _valid && version == _generation;

  void _failure(Object error) {
    _tokenRequired = error.toString().contains('CanvasTokenRequired');
    _csrfRequired = error.toString().contains('CanvasCsrfRequired');
    _auth = [
      'AuthenticationRequired',
      'InteractiveLoginRequired',
      'NotLoginError',
      'ConfigurationRequired',
      '401',
    ].any(error.toString().contains);
    _error = campusError(error);
    if (_tokenRequired) {
      _error = '当前会话需要绑定 Canvas 个人访问令牌才能发送消息。';
    } else if (_csrfRequired) {
      _error = '消息尚未发送，请刷新 Canvas 统一登录后手动发送。';
    }
  }

  Future<void> _load() async {
    if (!_valid || _course == null || _sending) return;
    final version = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
      _auth = false;
    });
    try {
      final result = await widget.controller.api.call(
        'canvas.conversations.sync',
        {'course_id': _course!.id},
      );
      if (!_current(version)) return;
      final list = chatList(result, 'conversations');
      setState(() => _conversations = list);
    } catch (e) {
      if (_current(version)) setState(() => _failure(e));
    } finally {
      if (_current(version)) setState(() => _busy = false);
    }
  }

  Future<void> _read(String id) async {
    if (!_valid || _sending || id.isEmpty) return;
    final version = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
      _auth = false;
      _conversation = null;
    });
    try {
      final result = await widget.controller.api.call(
        'canvas.conversation.read',
        {'conversation_id': id},
      );
      if (!_current(version)) return;
      setState(() {
        _conversation = chatConversation(result);
        _body.clear();
      });
    } catch (e) {
      if (_current(version)) setState(() => _failure(e));
    } finally {
      if (_current(version)) setState(() => _busy = false);
    }
  }

  Future<void> _findRecipients() async {
    if (!_valid || _course == null || _sending) return;
    final version = _generation, searchVersion = ++_searchGeneration;
    setState(() {
      _searching = true;
      _people = [];
      _error = null;
    });
    try {
      final result = await widget.controller.api.call(
        'canvas.recipients.search',
        {'course_id': _course!.id, 'search': _search.text.trim()},
      );
      if (!_current(version) || searchVersion != _searchGeneration) return;
      setState(() => _people = chatList(result, 'recipients'));
    } catch (e) {
      if (_current(version) && searchVersion == _searchGeneration) {
        setState(() => _failure(e));
      }
    } finally {
      if (_current(version) && searchVersion == _searchGeneration) {
        setState(() => _searching = false);
      }
    }
  }

  Future<void> _send() async {
    if (!_valid ||
        _sending ||
        _busy ||
        _uncertainSend ||
        _body.text.trim().isEmpty) {
      return;
    }
    if (_compose &&
        (_course == null ||
            _recipients.isEmpty ||
            _subject.text.trim().isEmpty)) {
      return;
    }
    if (!_compose && _conversation == null) return;
    final version = _generation;
    final creating = _compose;
    final params = <String, dynamic>{
      'body': _body.text.trim(),
      if (creating) ...{
        'course_id': _course!.id,
        'recipients': _recipients.keys.toList(),
        'subject': _subject.text.trim(),
      } else
        'conversation_id': _conversation!['id'].toString(),
    };
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final result = await widget.controller.api.call(
        creating ? 'canvas.conversation.create' : 'canvas.conversation.reply',
        params,
      );
      if (!_current(version)) return;
      // Sending succeeded even if the response cannot be rendered. Never retain
      // an already-sent draft merely because the follow-up read fails.
      _body.clear();
      _subject.clear();
      _recipients.clear();
      _compose = false;
      _sending = false;
      String? id;
      try {
        id = chatConversation(result)['id'].toString();
      } catch (_) {
        /* Refresh below. */
      }
      id ??= params['conversation_id'] as String?;
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('消息已发送')));
      if (id != null) {
        await _read(id);
      } else {
        await _load();
      }
    } catch (e) {
      if (_current(version)) {
        setState(() {
          _failure(e);
          final message = e.toString();
          _uncertainSend =
              !_auth &&
              !_csrfRequired &&
              !_tokenRequired &&
              [
                'NeedsReconciliation',
                'Network',
                'Transport',
                'Timeout',
                'Deadline',
                'SocketException',
                'Connection',
              ].any(message.contains);
          if (_uncertainSend) _error = '发送结果未确认，请返回会话列表刷新核对，避免重复发送。';
        });
      }
    } finally {
      if (_current(version)) setState(() => _sending = false);
    }
  }

  Future<void> _login() async {
    if (!_valid || _busy || _sending) return;
    final version = _generation;
    setState(() => _busy = true);
    try {
      await widget.controller.api.call('campus.login', {
        'service': 'canvas',
        if (_tokenRequired) 'replace': true,
      });
      if (!_current(version)) return;
      setState(() {
        _auth = false;
        _tokenRequired = false;
        _csrfRequired = false;
        _error = null;
      });
      if (_course == null) await widget.controller.loadCanvas();
      if (!_current(version)) return;
      if (!_compose && _conversation == null) await _load();
    } catch (e) {
      if (_current(version)) setState(() => _failure(e));
    } finally {
      if (_current(version)) setState(() => _busy = false);
    }
  }

  void _backToList() {
    if (_sending) return;
    _generation++;
    _searchGeneration++;
    setState(() {
      _conversation = null;
      _compose = false;
      _people = [];
      _recipients.clear();
      _body.clear();
      _subject.clear();
      _search.clear();
      _uncertainSend = false;
      _searching = false;
    });
    _load();
  }

  @override
  void dispose() {
    _generation++;
    widget.controller.appController.removeListener(_accountListener);
    widget.controller.removeListener(_coursesListener);
    _body.dispose();
    _subject.dispose();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    final detail = _compose || _conversation != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(_compose ? '新建消息' : '课程站内消息'),
        actions: [
          if (detail)
            TextButton(
              onPressed: _sending ? null : _backToList,
              child: const Text('会话列表'),
            ),
          if (!detail && !_accountChanged)
            IconButton(
              tooltip: '刷新消息',
              onPressed: _busy ? null : _load,
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      body: SafeArea(
        child: _accountChanged
            ? const Center(child: Text('账号已切换，请返回并重新打开站内消息。'))
            : Column(
                children: [
                  if (widget.course == null && ctrl.courses.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: DropdownButtonFormField<String>(
                        key: ValueKey(_course?.id),
                        initialValue: _course?.id,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: '当前学期课程'),
                        items: [
                          for (final course in ctrl.courses)
                            DropdownMenuItem(
                              value: course.id,
                              child: Text(
                                course.name,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: detail || _sending
                            ? null
                            : (id) {
                                _course = ctrl.courses.firstWhere(
                                  (c) => c.id == id,
                                );
                                _conversations = [];
                                _load();
                              },
                      ),
                    )
                  else if (_course != null)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(_course!.name),
                    ),
                  if (_busy) const LinearProgressIndicator(),
                  if (_error != null ||
                      ctrl.canvasAuthRequired ||
                      (_course == null && ctrl.canvasError != null))
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        children: [
                          Text(_error ?? ctrl.canvasError ?? '需要登录 Canvas'),
                          if (_auth ||
                              _tokenRequired ||
                              _csrfRequired ||
                              ctrl.canvasAuthRequired)
                            TextButton(
                              onPressed: _busy ? null : _login,
                              child: Text(
                                _tokenRequired
                                    ? '绑定 Canvas 令牌'
                                    : _csrfRequired
                                    ? '刷新 Canvas 统一登录'
                                    : '登录 Canvas',
                              ),
                            )
                          else if (!detail)
                            TextButton(
                              onPressed: _busy
                                  ? null
                                  : _course == null
                                  ? ctrl.loadCanvas
                                  : _load,
                              child: const Text('重试'),
                            ),
                        ],
                      ),
                    ),
                  Expanded(
                    child: _compose
                        ? _composeView()
                        : _conversation != null
                        ? _messagesView()
                        : _listView(),
                  ),
                  if (detail)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Expanded(
                            child: TextField(
                              key: const Key('chat-body'),
                              controller: _body,
                              enabled: !_sending && !_uncertainSend,
                              minLines: 1,
                              maxLines: 5,
                              decoration: InputDecoration(
                                labelText: _compose ? '消息正文' : '回复消息',
                                border: const OutlineInputBorder(),
                              ),
                              onChanged: (_) => setState(() {}),
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed:
                                _sending ||
                                    _busy ||
                                    _uncertainSend ||
                                    _body.text.trim().isEmpty ||
                                    (_compose &&
                                        (_recipients.isEmpty ||
                                            _subject.text.trim().isEmpty))
                                ? null
                                : _send,
                            child: Text(_sending ? '发送中…' : '发送'),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
      ),
      floatingActionButton:
          !detail && !_accountChanged && _course != null && !_busy
          ? FloatingActionButton.extended(
              onPressed: () => setState(() {
                _compose = true;
                _error = null;
              }),
              icon: const Icon(Icons.edit_outlined),
              label: const Text('新建消息'),
            )
          : null,
    );
  }

  Widget _listView() {
    if (_course == null) {
      return Center(
        child: widget.controller.canvasLoading
            ? const CircularProgressIndicator()
            : const Text('暂无当前学期课程，请先同步课程。'),
      );
    }
    if (_conversations.isEmpty) {
      return Center(
        child: Text(
          _busy
              ? '正在加载消息…'
              : _error == null
              ? '这门课程暂无站内消息'
              : '消息未能加载',
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 88),
      itemCount: _conversations.length,
      itemBuilder: (context, index) {
        final item = _conversations[index];
        final unread = item['workflow_state'] == 'unread';
        return ListTile(
          leading: Icon(
            unread ? Icons.mark_email_unread_outlined : Icons.mail_outline,
          ),
          title: Text(
            item['subject']?.toString() ?? '无主题',
            style: TextStyle(
              fontWeight: unread ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          subtitle: Text(
            item['last_message']?.toString() ?? '',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: _busy ? null : () => _read(item['id']?.toString() ?? ''),
        );
      },
    );
  }

  Widget _messagesView() {
    final conversation = _conversation!;
    final participants = {
      for (final p in chatList(
        conversation['participants'] ?? [],
        'participants',
      ))
        p['id'].toString(): p['name']?.toString() ?? '参与者',
    };
    final messages = chatList(conversation['messages'] ?? [], 'messages');
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          conversation['subject']?.toString() ?? '无主题',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        Text(participants.values.join('、')),
        if (messages.isEmpty)
          const Padding(padding: EdgeInsets.all(16), child: Text('暂无消息正文')),
        for (final message in messages)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(participants[message['author_id']?.toString()] ?? '参与者'),
                  if (message['created_at'] != null)
                    Text(
                      message['created_at'].toString(),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  const SizedBox(height: 8),
                  SelectableText(message['body']?.toString() ?? ''),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _composeView() => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      TextField(
        key: const Key('chat-subject'),
        controller: _subject,
        enabled: !_sending,
        decoration: const InputDecoration(labelText: '主题'),
        onChanged: (_) => setState(() {}),
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: TextField(
              key: const Key('chat-search'),
              controller: _search,
              enabled: !_sending,
              decoration: const InputDecoration(labelText: '搜索课程收件人'),
              onChanged: (_) {
                _searchGeneration++;
                setState(() {
                  _people = [];
                  _searching = false;
                });
              },
              onSubmitted: (_) => _findRecipients(),
            ),
          ),
          TextButton(
            onPressed: _searching || _sending ? null : _findRecipients,
            child: const Text('搜索'),
          ),
        ],
      ),
      Wrap(
        spacing: 8,
        children: [
          for (final entry in _recipients.entries)
            InputChip(
              label: Text(
                entry.value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onDeleted: _sending
                  ? null
                  : () => setState(() => _recipients.remove(entry.key)),
            ),
        ],
      ),
      if (_searching) const LinearProgressIndicator(),
      for (final person in _people)
        if ((person['id']?.toString() ?? '').isNotEmpty)
          CheckboxListTile(
            title: Text(chatPersonName(person)),
            value: _recipients.containsKey(person['id'].toString()),
            onChanged: _sending
                ? null
                : (selected) => setState(() {
                    final id = person['id'].toString();
                    if (selected == true) {
                      _recipients[id] = chatPersonName(person);
                    } else {
                      _recipients.remove(id);
                    }
                  }),
          ),
    ],
  );
}

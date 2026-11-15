// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../chat/chat_data.dart';
import '../chat/learning_chat_page.dart';
import '../learning_controller.dart';
import '../models/canvas_models.dart';

String courseMemberRole(Map<String, dynamic> person) {
  final enrollments = person['enrollments'];
  final roles = <String>{};
  if (enrollments is List) {
    for (final enrollment in enrollments.whereType<Map>()) {
      for (final key in ['type', 'role']) {
        switch (enrollment[key]?.toString().toLowerCase()) {
          case 'teacherenrollment':
          case 'teacher':
            roles.add('老师');
          case 'taenrollment':
          case 'ta':
            roles.add('助教');
          case 'studentenrollment':
          case 'student':
            roles.add('学生');
        }
      }
    }
  }
  return roles.isEmpty ? '成员' : roles.join('、');
}

class CoursePeoplePage extends StatefulWidget {
  const CoursePeoplePage({
    super.key,
    required this.controller,
    required this.course,
  });
  final LearningController controller;
  final CanvasCourse course;

  @override
  State<CoursePeoplePage> createState() => _CoursePeoplePageState();
}

class _CoursePeoplePageState extends State<CoursePeoplePage> {
  final _search = TextEditingController();
  List<Map<String, dynamic>> _people = [];
  String? _account, _error;
  int _generation = 0;
  bool _loading = false, _accountChanged = false;

  @override
  void initState() {
    super.initState();
    _account = widget.controller.appController.activeAccountId;
    widget.controller.appController.addListener(_accountListener);
    _load();
  }

  @override
  void didUpdateWidget(covariant CoursePeoplePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.appController.removeListener(_accountListener);
      widget.controller.appController.addListener(_accountListener);
      _clearAccount();
    } else if (oldWidget.course.id != widget.course.id) {
      _search.clear();
      _load();
    }
  }

  void _accountListener() {
    if (_account != widget.controller.appController.activeAccountId) {
      _clearAccount();
    }
  }

  void _clearAccount() {
    _generation++;
    _search.clear();
    setState(() {
      _accountChanged = true;
      _people = [];
      _error = null;
      _loading = false;
    });
  }

  bool _current(int generation) =>
      mounted &&
      !_accountChanged &&
      generation == _generation &&
      _account == widget.controller.appController.activeAccountId;

  Future<void> _load() async {
    if (_accountChanged) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _people = [];
      _error = null;
    });
    try {
      final result = await widget.controller.api.call(
        'canvas.course_users.sync',
        {
          'course_id': widget.course.id,
          if (_search.text.trim().isNotEmpty) 'search': _search.text.trim(),
        },
      );
      if (!_current(generation)) return;
      setState(() => _people = chatList(result, 'users'));
    } catch (error) {
      if (!_current(generation)) return;
      final detail = error.toString().toLowerCase();
      setState(
        () => _error =
            [
              'permission',
              'forbidden',
              '403',
              '401',
              'authentication',
              'notlogin',
              'interactivelogin',
            ].any(detail.contains)
            ? '无法查看课程人员，请确认已登录且有课程访问权限。'
            : '课程人员加载失败，请稍后重试。',
      );
    } finally {
      if (_current(generation)) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _generation++;
    widget.controller.appController.removeListener(_accountListener);
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('课程人员')),
    body: SafeArea(
      child: _accountChanged
          ? const Center(child: Text('账号已切换，请返回并重新打开课程人员。'))
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Text(
                    widget.course.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: TextField(
                    key: const Key('people-search'),
                    controller: _search,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      labelText: '搜索课程人员',
                      suffixIcon: IconButton(
                        tooltip: '搜索',
                        icon: const Icon(Icons.search),
                        onPressed: _load,
                      ),
                    ),
                    onSubmitted: (_) => _load(),
                  ),
                ),
                if (_loading) const LinearProgressIndicator(),
                Expanded(
                  child: _loading
                      ? const Center(child: Text('正在加载课程人员…'))
                      : _error != null
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(_error!, textAlign: TextAlign.center),
                                TextButton(
                                  onPressed: _load,
                                  child: const Text('重试'),
                                ),
                              ],
                            ),
                          ),
                        )
                      : RefreshIndicator(
                          onRefresh: _load,
                          child: ListView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            children: [
                              if (_people.isEmpty)
                                Padding(
                                  padding: const EdgeInsets.all(24),
                                  child: Text(
                                    _search.text.trim().isEmpty
                                        ? '暂无课程人员'
                                        : '未找到匹配的课程人员',
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              for (final person in _people)
                                ListTile(
                                  title: Text(
                                    chatPersonName(person),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(courseMemberRole(person)),
                                  trailing: TextButton(
                                    onPressed:
                                        (person['id']?.toString() ?? '').isEmpty
                                        ? null
                                        : () {
                                            if (!_current(_generation)) return;
                                            Navigator.of(context).push(
                                              MaterialPageRoute<void>(
                                                builder: (_) => LearningChatPage(
                                                  controller: widget.controller,
                                                  course: widget.course,
                                                  initialRecipient:
                                                      ChatRecipient.fromJson(
                                                        person,
                                                      ),
                                                ),
                                              ),
                                            );
                                          },
                                    child: const Text('发消息'),
                                  ),
                                ),
                            ],
                          ),
                        ),
                ),
              ],
            ),
    ),
  );
}

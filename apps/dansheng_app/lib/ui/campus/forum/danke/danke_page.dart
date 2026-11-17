// SPDX-License-Identifier: GPL-3.0-or-later
// Course-review home and course detail adapted from DanXi
// lib/page/subpage_danke.dart and lib/page/danke/course_group_detail.dart.
// Copyright (C) 2021 DanXi-Dev; GPL-3.0-or-later.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../campus_api.dart';
import 'danke_models.dart';
import 'danke_widgets.dart';

/// DanXi's 旦课 home: a search bar; while it is empty, a random review.
class DankePage extends StatefulWidget {
  const DankePage({super.key, required this.api});
  final CampusApi api;

  @override
  State<DankePage> createState() => _DankePageState();
}

class _DankePageState extends State<DankePage> {
  late final DankeService _service = DankeService(widget.api);
  final _query = TextEditingController();
  Timer? _debounce;

  DankeReview? _random;
  String? _randomError;
  bool _loadingRandom = false;

  String _searched = '';
  final _groups = <DankeCourseGroup>[];
  int? _nextPage;
  bool _searching = false;
  String? _searchError;

  @override
  void initState() {
    super.initState();
    _loadRandom();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  Future<void> _loadRandom() async {
    setState(() {
      _loadingRandom = true;
      _randomError = null;
    });
    try {
      final review = await _service.random();
      if (mounted) setState(() => _random = review);
    } catch (e) {
      if (mounted) setState(() => _randomError = campusError(e));
    } finally {
      if (mounted) setState(() => _loadingRandom = false);
    }
  }

  void _onQueryChanged(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      final query = text.trim();
      if (query == _searched) return;
      _search(query);
    });
  }

  Future<void> _search(String query, {bool more = false}) async {
    setState(() {
      if (!more) {
        _searched = query;
        _groups.clear();
        _nextPage = null;
      }
      _searchError = null;
      _searching = query.isNotEmpty;
    });
    if (query.isEmpty) return;
    try {
      final page = await _service.search(query, page: more ? _nextPage! : 1);
      if (!mounted || query != _searched) return;
      setState(() {
        _groups.addAll(page.groups);
        _nextPage = page.next;
      });
    } catch (e) {
      if (mounted && query == _searched) {
        setState(() => _searchError = campusError(e));
      }
    } finally {
      if (mounted && query == _searched) setState(() => _searching = false);
    }
  }

  void _open(int groupId, {int? reviewId}) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => DankeCoursePage(
        service: _service,
        groupId: groupId,
        locateReviewId: reviewId,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final idle = _searched.isEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('旦课 · 课程评价')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              key: const Key('danke-search'),
              controller: _query,
              textInputAction: TextInputAction.search,
              onChanged: _onQueryChanged,
              onSubmitted: (text) => _search(text.trim()),
              decoration: InputDecoration(
                hintText: '搜索课程名、课程代码',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清除',
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _query.clear();
                          _search('');
                        },
                      ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
                isDense: true,
              ),
            ),
          ),
          Expanded(child: idle ? _randomView() : _resultsView()),
        ],
      ),
    );
  }

  Widget _randomView() => RefreshIndicator(
    onRefresh: _loadRandom,
    child: ListView(
      padding: const EdgeInsets.all(10),
      children: [
        if (_loadingRandom && _random == null)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_randomError != null && _random == null)
          _message(_randomError!, onRetry: _loadRandom)
        else if (_random != null) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
            child: Text(
              '随机评价 · 下拉换一条',
              style: TextStyle(color: Theme.of(context).hintColor),
            ),
          ),
          DankeRandomCard(
            review: _random!,
            onTap: _random!.groupId == null
                ? null
                : () => _open(_random!.groupId!, reviewId: _random!.id),
          ),
        ],
      ],
    ),
  );

  Widget _resultsView() {
    if (_groups.isEmpty) {
      if (_searching) return const Center(child: CircularProgressIndicator());
      if (_searchError != null) {
        return _message(_searchError!, onRetry: () => _search(_searched));
      }
      return _message('没有找到相关课程');
    }
    return ListView.builder(
      padding: const EdgeInsets.all(10),
      itemCount: _groups.length + 1,
      itemBuilder: (context, i) {
        if (i < _groups.length) {
          final group = _groups[i];
          return DankeGroupCard(group: group, onTap: () => _open(group.id));
        }
        if (_nextPage == null) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: Text('已经到底了')),
          );
        }
        return Center(
          child: _searching
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: CircularProgressIndicator(),
                )
              : TextButton(
                  onPressed: () => _search(_searched, more: true),
                  child: const Text('加载更多'),
                ),
        );
      },
    );
  }

  Widget _message(String text, {VoidCallback? onRetry}) => Padding(
    padding: const EdgeInsets.all(32),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(text, textAlign: TextAlign.center),
        if (onRetry != null) ...[
          const SizedBox(height: 12),
          FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
        ],
      ],
    ),
  );
}

/// DanXi `CourseGroupDetail` (read-only): the course, its average grade,
/// teacher and semester filters, and every review.
class DankeCoursePage extends StatefulWidget {
  const DankeCoursePage({
    super.key,
    required this.service,
    required this.groupId,
    this.locateReviewId,
  });

  final DankeService service;
  final int groupId;

  /// Scrolled to and outlined once loaded (the random review opened from home).
  final int? locateReviewId;

  @override
  State<DankeCoursePage> createState() => _DankeCoursePageState();
}

class _DankeCoursePageState extends State<DankeCoursePage> {
  DankeCourseGroup? _group;
  String? _error;
  String _teacher = '*';
  String _time = '*';
  final _locate = GlobalKey();
  bool _located = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final group = await widget.service.group(widget.groupId);
      if (mounted) setState(() => _group = group);
      if (!_located && widget.locateReviewId != null) {
        _located = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final target = _locate.currentContext;
          if (target != null && target.mounted) {
            Scrollable.ensureVisible(
              target,
              duration: const Duration(milliseconds: 300),
            );
          }
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = campusError(e));
    }
  }

  List<DankeReview> get _reviews => [
    for (final course in _group?.courses ?? const <DankeCourse>[])
      if ((_teacher == '*' || course.teachers == _teacher) &&
          (_time == '*' || course.time == _time))
        for (final review in course.reviews)
          if (!review.deleted) review,
  ];

  /// DanXi: whole-number mean of the overall grades, as a word.
  int? get _average {
    final grades = [
      for (final c in _group?.courses ?? const <DankeCourse>[])
        for (final r in c.reviews)
          if (r.rank.overall != null) r.rank.overall!,
    ];
    if (grades.isEmpty) return null;
    return grades.reduce((a, b) => a + b) ~/ grades.length;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('课程详情')),
    body: _group == null
        ? (_error == null
              ? const Center(child: CircularProgressIndicator())
              : Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!),
                      const SizedBox(height: 12),
                      FilledButton.tonal(
                        onPressed: _load,
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                ))
        : RefreshIndicator(
            onRefresh: _load,
            // Built in full (a course has at most a few dozen reviews), so the
            // review to locate exists before scrolling to it.
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _head(_group!),
                  if (_reviews.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: Text('该课程还没有评论')),
                    )
                  else
                    for (final review in _reviews)
                      DankeReviewCard(
                        key: review.id == widget.locateReviewId
                            ? _locate
                            : null,
                        review: review,
                        highlight: review.id == widget.locateReviewId,
                      ),
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: Text('已经到底了')),
                  ),
                ],
              ),
            ),
          ),
  );

  Widget _head(DankeCourseGroup group) {
    final teachers = {for (final c in group.courses) c.teachers}.toList();
    final times = {for (final c in group.courses) c.time}.toList();
    Widget filters(
      List<String> values,
      String selected,
      ValueChanged<String> pick,
    ) => Wrap(
      spacing: 6,
      runSpacing: 4,
      alignment: WrapAlignment.center,
      children: [
        for (final value in ['*', ...values])
          ChoiceChip(
            label: Text(value == '*' ? '全部' : value),
            selected: value == selected,
            onSelected: (_) => setState(() => pick(value)),
          ),
      ],
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        child: Column(
          children: [
            Text(
              group.fullName,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                children: [
                  Text(
                    group.code,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.grey,
                    ),
                  ),
                  for (final c in group.credits)
                    DankeChip(
                      label: '${c.toStringAsFixed(1)} 学分',
                      color: Colors.orange,
                    ),
                ],
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '平均评价',
                  style: TextStyle(color: Colors.grey, fontSize: 15),
                ),
                const SizedBox(width: 6),
                dankeGrade(dankeOverallWords, _average, fontSize: 15),
              ],
            ),
            const Divider(height: 12, thickness: 1),
            const Text('教师姓名', style: TextStyle(fontWeight: FontWeight.bold)),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: filters(teachers, _teacher, (v) => _teacher = v),
            ),
            const Divider(height: 12, thickness: 1),
            const Text('上课时间', style: TextStyle(fontWeight: FontWeight.bold)),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: filters(times, _time, (v) => _time = v),
            ),
          ],
        ),
      ),
    );
  }
}

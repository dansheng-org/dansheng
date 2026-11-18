// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';

import '../../../agent/agent_types.dart';

class AgentApprovalsDialog extends StatefulWidget {
  const AgentApprovalsDialog({
    super.key,
    required this.baseUrl,
    required this.load,
    required this.revoke,
    required this.clear,
  });

  final Uri baseUrl;
  final Future<Set<String>> Function() load;
  final Future<void> Function(String permission) revoke;
  final Future<void> Function() clear;

  @override
  State<AgentApprovalsDialog> createState() => _AgentApprovalsDialogState();
}

class _AgentApprovalsDialogState extends State<AgentApprovalsDialog> {
  static final _labels = {
    for (final source in AgentSourceKind.values) source.name: source.label,
    'web': 'Brave 网页搜索',
    'web_provider': '模型联网搜索',
    'attachment': '发送附件',
  };
  Set<String>? _grants;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh([Future<void> Function()? edit]) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (edit != null) await edit();
      final grants = await widget.load();
      if (mounted) setState(() => _grants = grants);
    } on AgentFailure catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = '无法更新长期授权。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('管理授权'),
    scrollable: true,
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(widget.baseUrl.toString()),
        const SizedBox(height: 12),
        if (_grants case final grants?)
          if (grants.isEmpty)
            const Text('当前模型地址没有长期授权。')
          else
            for (final permission in grants)
              Row(
                children: [
                  Expanded(child: Text(_labels[permission] ?? permission)),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => _refresh(() => widget.revoke(permission)),
                    child: const Text('撤销'),
                  ),
                ],
              )
        else if (_busy)
          const Text('正在读取长期授权…'),
        if (_error case final String error)
          Text(
            error,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => _refresh(widget.clear),
        child: const Text('撤销此账号全部授权'),
      ),
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('关闭'),
      ),
    ],
  );
}

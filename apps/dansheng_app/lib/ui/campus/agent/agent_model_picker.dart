// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../agent/model_catalog.dart';

class AgentModelPicker extends StatefulWidget {
  const AgentModelPicker({
    super.key,
    required this.selectedId,
    required this.load,
    this.initialModels,
  });

  final String selectedId;
  final Future<List<ModelCatalogEntry>> Function() load;
  final List<ModelCatalogEntry>? initialModels;

  @override
  State<AgentModelPicker> createState() => _AgentModelPickerState();
}

class _AgentModelPickerState extends State<AgentModelPicker> {
  final _search = TextEditingController();
  final _manualForm = GlobalKey<FormState>();
  late final TextEditingController _manualId;
  late List<ModelCatalogEntry> _models;
  bool _loading = false;
  bool _loadFailed = false;
  bool _enterManually = false;

  @override
  void initState() {
    super.initState();
    _manualId = TextEditingController(text: widget.selectedId);
    _models = widget.initialModels ?? const [];
    if (widget.initialModels == null) unawaited(_load());
  }

  @override
  void dispose() {
    _search.dispose();
    _manualId.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    try {
      final models = await widget.load();
      if (!mounted) return;
      setState(() {
        _models = models;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadFailed = true;
      });
    }
  }

  void _submitManualId() {
    if (_manualForm.currentState!.validate()) {
      final id = _manualId.text.trim();
      Navigator.of(context).pop(
        _models.where((model) => model.id == id).firstOrNull ??
            ModelCatalogEntry(id),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cancel = TextButton(
      onPressed: () => Navigator.of(context).pop(),
      child: const Text('取消'),
    );
    if (_enterManually) {
      return AlertDialog(
        title: const Text('手动输入模型标识'),
        scrollable: true,
        content: SizedBox(
          width: 400,
          child: Form(
            key: _manualForm,
            child: TextFormField(
              controller: _manualId,
              autocorrect: false,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: '模型标识',
                border: OutlineInputBorder(),
              ),
              validator: (value) {
                final id = value?.trim() ?? '';
                if (id.isEmpty) return '请输入服务商提供的模型标识。';
                if (id.length > 256) return '模型标识最多可输入 256 个字符。';
                return null;
              },
              onFieldSubmitted: (_) => _submitManualId(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => setState(() => _enterManually = false),
            child: const Text('返回列表'),
          ),
          cancel,
          FilledButton(onPressed: _submitManualId, child: const Text('选择')),
        ],
      );
    }

    final query = _search.text.trim().toLowerCase();
    final matching = _models.where((model) {
      return model.id.toLowerCase().contains(query) ||
          (model.label?.toLowerCase().contains(query) ?? false);
    }).toList();

    return AlertDialog(
      title: const Text('选择模型'),
      content: SizedBox(
        width: 400,
        height: 320,
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Column(
                children: [
                  TextField(
                    controller: _search,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: '搜索模型标识或名称',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: IconButton(
                        tooltip: _loadFailed ? '重试读取模型列表' : '刷新模型列表',
                        onPressed: _loading ? null : _load,
                        icon: const Icon(Icons.refresh),
                      ),
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 8),
                  if (_loading)
                    const LinearProgressIndicator(semanticsLabel: '正在读取模型列表'),
                  if (_loadFailed) const Text('无法读取模型列表。'),
                ],
              ),
            ),
            if (matching.isEmpty && !_loading && !_loadFailed)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Text(_models.isEmpty ? '模型列表为空。' : '没有匹配的模型。'),
                ),
              ),
            SliverList.builder(
              itemCount: matching.length,
              itemBuilder: (context, index) {
                final model = matching[index];
                final label = model.displayName;
                final current = model.id == widget.selectedId;
                return ListTile(
                  title: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: label == model.id
                      ? null
                      : Text(
                          model.id,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                  selected: current,
                  trailing: current ? const Chip(label: Text('当前')) : null,
                  onTap: () => Navigator.of(context).pop(model),
                );
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => setState(() => _enterManually = true),
          child: const Text('手动输入'),
        ),
        cancel,
      ],
    );
  }
}

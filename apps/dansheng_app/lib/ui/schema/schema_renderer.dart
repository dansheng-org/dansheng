import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/dansheng_client.dart';
import 'schema_models.dart';

/// Material 3 Schema Renderer supporting Grade 1 (reactive forms),
/// Grade 0 (legacy published component cards), and Unknown Grade (graceful fallback).
class SchemaRenderer extends StatefulWidget {
  final String pluginId;
  final UiDeclarationModel declaration;
  final DanshengClient client;
  final String? activeAccountId;
  final VoidCallback? onActionCompleted;
  final Stream<String>? componentChanges;
  final Map<String, dynamic>? initialValues;

  const SchemaRenderer({
    super.key,
    required this.pluginId,
    required this.declaration,
    required this.client,
    this.activeAccountId,
    this.onActionCompleted,
    this.componentChanges,
    this.initialValues,
  });

  @override
  State<SchemaRenderer> createState() => _SchemaRendererState();
}

class _SchemaRendererState extends State<SchemaRenderer> {
  StreamSubscription<String>? _updates;
  late SchemaDraft _draft;
  final Map<String, List<SelectOption>> _fieldOptions = {};
  final Map<String, bool> _fieldLoading = {};
  final Map<String, String?> _fieldErrors = {};
  final _optionVersions = <String, int>{};
  bool get _published =>
      widget.declaration.fields.isEmpty && widget.declaration.buttons.isEmpty;

  bool _isActionRunning = false;
  String? _globalError;
  dynamic _actionResult;

  // For Grade 0 legacy component
  bool _isComponentLoading = false;
  Map<String, dynamic>? _legacyComponentData;

  @override
  void initState() {
    super.initState();
    _updates = widget.componentChanges?.listen((key) {
      if (mounted &&
          _published &&
          (key == '*' ||
              key == 'plugin:${widget.pluginId}:${widget.declaration.id}')) {
        _loadLegacyComponent();
      }
    });
    _draft = SchemaDraft(declaration: widget.declaration);
    for (final field in widget.declaration.fields) {
      if (field.type != 'identifier' &&
          widget.initialValues?.containsKey(field.id) == true) {
        _draft.values[field.id] = widget.initialValues![field.id];
      }
    }
    if (widget.declaration.uiVersion <= 0 ||
        (_published && widget.declaration.uiVersion == 1)) {
      _loadLegacyComponent();
    } else if (widget.declaration.uiVersion == 1) {
      _loadInitialSources();
    }
  }

  @override
  void dispose() {
    _updates?.cancel();
    super.dispose();
  }

  /// Load options for all fields with a source
  Future<void> _loadInitialSources() async {
    for (final field in widget.declaration.fields) {
      if (field.source != null) {
        await _fetchFieldOptions(field);
      }
    }
  }

  /// Fetch dynamic options for a specific field
  Future<void> _fetchFieldOptions(UiFieldModel field) async {
    if (field.source == null) return;
    final source = field.source!;
    final generation = (_optionVersions[field.id] ?? 0) + 1;
    _optionVersions[field.id] = generation;
    if (source.dependsOn.any(
      (id) => _draft.values[id] == null || _draft.values[id] == '',
    )) {
      setState(() {
        _fieldOptions[field.id] = [];
        _fieldErrors[field.id] = null;
        _fieldLoading[field.id] = false;
      });
      return;
    }

    setState(() {
      _fieldLoading[field.id] = true;
      _fieldErrors[field.id] = null;
    });

    try {
      final input = _draft.buildActionInput(
        fieldIds: source.dependsOn,
        accountId: widget.activeAccountId,
      );

      final res = await widget.client.runAction(
        pluginId: widget.pluginId,
        action: source.action,
        input: input,
      );
      if (!mounted || _optionVersions[field.id] != generation) return;

      List<SelectOption> options = [];
      if (res is List) {
        options = res.map((item) => SelectOption.fromJson(item)).toList();
      } else if (res is Map && res['options'] is List) {
        options = (res['options'] as List)
            .map((item) => SelectOption.fromJson(item))
            .toList();
      }

      if (mounted && _optionVersions[field.id] == generation) {
        setState(() {
          _fieldOptions[field.id] = options;
          _fieldLoading[field.id] = false;
        });
      }
    } catch (e) {
      if (mounted && _optionVersions[field.id] == generation) {
        setState(() {
          _fieldLoading[field.id] = false;
          _fieldErrors[field.id] = '加载选项失败: $e';
        });
      }
    }
  }

  /// Load Grade 0 legacy published component
  Future<void> _loadLegacyComponent() async {
    setState(() {
      _isComponentLoading = true;
    });

    try {
      final res = await widget.client.getComponent(
        widget.pluginId,
        widget.declaration.id,
      );
      if (mounted) {
        setState(() {
          _legacyComponentData = res;
          _isComponentLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _legacyComponentData = {'error': e.toString()};
          _isComponentLoading = false;
        });
      }
    }
  }

  void _onFieldValueChanged(String fieldId, dynamic value) {
    setState(() {
      final reloadFields = _draft.setValue(fieldId, value);
      for (final rfid in reloadFields) {
        final f = widget.declaration.fields.firstWhere((x) => x.id == rfid);
        _fetchFieldOptions(f);
      }
    });
  }

  /// Handle button execution with prepare, preview and confirmation if required
  Future<void> _handleButtonPress(UiButtonModel button) async {
    setState(() {
      _isActionRunning = true;
      _globalError = null;
      _actionResult = null;
    });

    try {
      Map<String, dynamic> actionInput = _draft.buildActionInput(
        fieldIds: button.fields,
        accountId: widget.activeAccountId,
      );

      // 1. Prepare action if defined - normalize returned input from external plugin
      if (button.prepare != null && button.prepare!.isNotEmpty) {
        final prepRes = await widget.client.runAction(
          pluginId: widget.pluginId,
          action: button.prepare!,
          input: actionInput,
        );
        if (prepRes is Map<String, dynamic>) {
          actionInput = Map<String, dynamic>.from(prepRes);
          if (widget.activeAccountId != null &&
              !actionInput.containsKey('account_id')) {
            actionInput['account_id'] = widget.activeAccountId;
          }
          actionInput.remove('approved');
        }
      }

      String? inputSha256;

      // 2. Preview & confirm if button requests confirmation
      if (button.confirm) {
        final previewRes = await widget.client.previewAction(
          pluginId: widget.pluginId,
          action: button.action,
          input: actionInput,
        );

        inputSha256 =
            previewRes['input_sha256']?.toString() ??
            previewRes['sha256']?.toString() ??
            previewRes['hash']?.toString();

        if (!mounted) return;

        setState(() {
          _isActionRunning = false;
        });

        final confirmed = await _showConfirmationDialog(
          context: context,
          button: button,
          preview: previewRes,
          inputSha256: inputSha256,
          input: actionInput,
        );

        if (confirmed != true) {
          // Action explicitly cancelled by user
          return;
        }

        setState(() {
          _isActionRunning = true;
        });
      }

      // 3. Execute action (NEVER inserting approved)
      final res = await widget.client.runAction(
        pluginId: widget.pluginId,
        action: button.action,
        input: actionInput,
        inputSha256: inputSha256,
      );

      if (mounted) {
        setState(() {
          _actionResult = res;
          _isActionRunning = false;
        });
        widget.onActionCompleted?.call();
      }
    } catch (e) {
      if (mounted) {
        String msg = e.toString();
        if (e is PlatformException) {
          msg = '[${e.code}] ${e.message ?? e.toString()}';
        }
        setState(() {
          _globalError = '执行失败: $msg';
          _isActionRunning = false;
        });
      }
    }
  }

  Future<bool?> _showConfirmationDialog({
    required BuildContext context,
    required UiButtonModel button,
    required Map<String, dynamic> preview,
    required String? inputSha256,
    required Map<String, dynamic> input,
  }) {
    final summary =
        preview['summary']?.toString() ??
        preview['description']?.toString() ??
        '请确认是否执行此操作。';

    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          title: Text('操作确认: ${button.label}'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(summary, style: Theme.of(ctx).textTheme.bodyLarge),
                const SizedBox(height: 16),
                if (inputSha256 != null && inputSha256.isNotEmpty) ...[
                  Text(
                    '安全指纹 (SHA-256):',
                    style: Theme.of(ctx).textTheme.labelMedium
                        ?.copyWith(color: Theme.of(ctx).colorScheme.primary),
                  ),
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SelectableText(
                      inputSha256,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                const Text(
                  '提交参数摘要:',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                ...input.entries
                    .where((e) => !e.key.startsWith('_'))
                    .map(
                      (e) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text('${e.key}: ${e.value}'),
                      ),
                    ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('确认执行'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // 1. Grade check: Unknown grade fallback
    if (widget.declaration.uiVersion > 1) {
      return _buildUnsupportedGradeCard();
    }

    // 2. Grade 0 / Legacy component check
    if (widget.declaration.uiVersion <= 0 || _published) {
      return _buildLegacyComponentView();
    }

    // 3. Grade 1: Reactive schema form & dynamic results
    return _buildGrade1Form();
  }

  Widget _buildUnsupportedGradeCard() {
    return Card(
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  color: Theme.of(context).colorScheme.onErrorContainer,
                  size: 28,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '界面版本不兼容',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '当前声明所要求的版本为 v${widget.declaration.uiVersion}，此客户端仅支持 v1。'
              '该组件暂时无法渲染，请升级应用或联系插件维护者。',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onErrorContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLegacyComponentView() {
    if (_isComponentLoading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32.0),
          child: CircularProgressIndicator(),
        ),
      );
    }

    final data = _legacyComponentData;
    if (data == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Text('无可用组件数据 (${widget.declaration.title})'),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.declaration.title,
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            _buildDynamicDataDisplay(data),
          ],
        ),
      ),
    );
  }

  Widget _buildGrade1Form() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header / Title
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.declaration.title,
                    style: Theme.of(context).textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '类型: ${widget.declaration.type}',
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context)
                                .colorScheme
                                .onPrimaryContainer,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '时区: ${widget.declaration.timeZone}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Fields
          for (final field in widget.declaration.fields)
            if (field.type != 'identifier') _buildFieldWidget(field),

          if (_globalError != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _globalError!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
              ),
            ),
          ],

          const SizedBox(height: 16),

          // Action Buttons
          if (widget.declaration.buttons.isNotEmpty) ...[
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: widget.declaration.buttons.map((btn) {
                return FilledButton.icon(
                  onPressed: _isActionRunning
                      ? null
                      : () => _handleButtonPress(btn),
                  icon: _isActionRunning
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.play_arrow_rounded),
                  label: Text(btn.label),
                );
              }).toList(),
            ),
          ],

          // Dynamic Result Card / List
          if (_actionResult != null) ...[
            const SizedBox(height: 24),
            Text(
              '执行结果',
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: _buildDynamicDataDisplay(_actionResult),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFieldWidget(UiFieldModel field) {
    final value = _draft.values[field.id];
    final isLoading = _fieldLoading[field.id] == true;
    final error = _fieldErrors[field.id];

    return Padding(
      padding: const EdgeInsets.only(bottom: 16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                field.label,
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              if (isLoading) ...[
                const SizedBox(width: 8),
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          _buildFieldControl(field, value),
          if (error != null) ...[
            const SizedBox(height: 4),
            Text(
              error,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 12,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFieldControl(UiFieldModel field, dynamic value) {
    switch (field.type) {
      case 'date':
        return _buildDatePicker(field, value);
      case 'datetime':
        return _buildDateTimePicker(field, value);
      case 'time':
        return _buildTimePicker(field, value);
      case 'select':
        return _buildSelectDropdown(field, value);
      case 'multiselect':
        return _buildMultiSelect(field, value);
      case 'boolean':
        return _buildBooleanSwitch(field, value);
      case 'identifier':
        return _buildIdentifierField(field, value);
      case 'number':
        return _buildTextField(field, value, isNumber: true);
      case 'text':
      default:
        return _buildTextField(field, value, isNumber: false);
    }
  }

  Widget _buildIdentifierField(UiFieldModel field, dynamic value) {
    final strVal = (value ?? _draft.draftId).toString();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest
            .withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Row(
        children: [
          const Icon(Icons.fingerprint, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              strVal,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              '草稿标识',
              style: TextStyle(
                fontSize: 10,
                color: Theme.of(context).colorScheme.onPrimaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTextField(
    UiFieldModel field,
    dynamic value, {
    required bool isNumber,
  }) {
    return TextFormField(
      initialValue: value?.toString() ?? '',
      keyboardType: isNumber ? TextInputType.number : TextInputType.text,
      decoration: InputDecoration(hintText: '请输入${field.label}'),
      onChanged: (text) {
        if (isNumber) {
          final numVal = num.tryParse(text);
          _onFieldValueChanged(field.id, numVal ?? text);
        } else {
          _onFieldValueChanged(field.id, text);
        }
      },
    );
  }

  Widget _buildDatePicker(UiFieldModel field, dynamic value) {
    final strValue = value?.toString() ?? '';
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      icon: const Icon(Icons.calendar_today_outlined),
      label: Text(
        strValue.isNotEmpty
            ? strValue
            : '选择日期 (${widget.declaration.timeZone})',
        style: TextStyle(
          color: strValue.isNotEmpty
              ? Theme.of(context).colorScheme.onSurface
              : Theme.of(context).hintColor,
        ),
      ),
      onPressed: () async {
        final now = DateTime.now();
        final picked = await showDatePicker(
          context: context,
          initialDate: now,
          firstDate: now.subtract(const Duration(days: 365)),
          lastDate: now.add(const Duration(days: 365 * 2)),
        );
        if (picked != null) {
          // Format as YYYY-MM-DD
          final y = picked.year.toString().padLeft(4, '0');
          final m = picked.month.toString().padLeft(2, '0');
          final d = picked.day.toString().padLeft(2, '0');
          final formatted = '$y-$m-$d';
          _onFieldValueChanged(field.id, formatted);
        }
      },
    );
  }

  Widget _buildDateTimePicker(UiFieldModel field, dynamic value) {
    final strValue = value?.toString() ?? '';
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      icon: const Icon(Icons.access_time_outlined),
      label: Text(
        strValue.isNotEmpty
            ? strValue
            : '选择日期与时间 (${widget.declaration.timeZone})',
        style: TextStyle(
          color: strValue.isNotEmpty
              ? Theme.of(context).colorScheme.onSurface
              : Theme.of(context).hintColor,
        ),
      ),
      onPressed: () async {
        final now = DateTime.now();
        final pickedDate = await showDatePicker(
          context: context,
          initialDate: now,
          firstDate: now.subtract(const Duration(days: 365)),
          lastDate: now.add(const Duration(days: 365 * 2)),
        );
        if (pickedDate == null || !mounted) return;

        final pickedTime = await showTimePicker(
          context: context,
          initialTime: TimeOfDay.now(),
        );
        if (pickedTime == null) return;

        final y = pickedDate.year.toString().padLeft(4, '0');
        final m = pickedDate.month.toString().padLeft(2, '0');
        final d = pickedDate.day.toString().padLeft(2, '0');
        final hh = pickedTime.hour.toString().padLeft(2, '0');
        final mm = pickedTime.minute.toString().padLeft(2, '0');
        // Asia/Shanghai ISO timestamp with +08:00
        final formatted = '$y-$m-${d}T$hh:$mm:00+08:00';
        _onFieldValueChanged(field.id, formatted);
      },
    );
  }

  Widget _buildTimePicker(UiFieldModel field, dynamic value) {
    final strValue = value?.toString() ?? '';
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      icon: const Icon(Icons.schedule),
      label: Text(
        strValue.isNotEmpty
            ? strValue
            : '选择时间 (${widget.declaration.timeZone})',
        style: TextStyle(
          color: strValue.isNotEmpty
              ? Theme.of(context).colorScheme.onSurface
              : Theme.of(context).hintColor,
        ),
      ),
      onPressed: () async {
        final pickedTime = await showTimePicker(
          context: context,
          initialTime: TimeOfDay.now(),
        );
        if (pickedTime != null) {
          final hh = pickedTime.hour.toString().padLeft(2, '0');
          final mm = pickedTime.minute.toString().padLeft(2, '0');
          _onFieldValueChanged(field.id, '$hh:$mm');
        }
      },
    );
  }

  Widget _buildSelectDropdown(UiFieldModel field, dynamic value) {
    final options = _fieldOptions[field.id] ?? [];

    // Find current matching option
    SelectOption? currentOption;
    for (final opt in options) {
      if (jsonEncode(opt.value) == jsonEncode(value)) {
        currentOption = opt;
        break;
      }
    }

    return DropdownButtonFormField<SelectOption>(
      initialValue: currentOption,
      isExpanded: true,
      decoration: InputDecoration(
        hintText: options.isEmpty ? '暂无可选项' : '请选择${field.label}',
      ),
      items: options.map((opt) {
        return DropdownMenuItem<SelectOption>(
          value: opt,
          child: Text(opt.label, overflow: TextOverflow.ellipsis),
        );
      }).toList(),
      onChanged: (selected) {
        if (selected != null) {
          _onFieldValueChanged(field.id, selected.value);
        }
      },
    );
  }

  Widget _buildMultiSelect(UiFieldModel field, dynamic value) {
    final options = _fieldOptions[field.id] ?? [];
    final currentSelectedValues = (value is List) ? value : <dynamic>[];

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: options.map((opt) {
        final isSelected = currentSelectedValues.any(
          (v) => jsonEncode(v) == jsonEncode(opt.value),
        );

        int? priority;
        if (isSelected && field.id == 'selected_slots') {
          String? time(dynamic raw) {
            try {
              final slot = raw is String ? jsonDecode(raw) : raw;
              return slot is Map ? slot['time']?.toString() : null;
            } on FormatException {
              return null;
            }
          }

          final group = time(opt.value);
          if (group != null) {
            var order = 0;
            for (final selected in currentSelectedValues) {
              if (time(selected) == group) order++;
              if (jsonEncode(selected) == jsonEncode(opt.value)) {
                priority = order;
                break;
              }
            }
          }
        }
        return FilterChip(
          avatar: priority == null
              ? null
              : CircleAvatar(child: Text('$priority')),
          label: Text(opt.label),
          selected: isSelected,
          onSelected: (selected) {
            final nextList = List<dynamic>.from(currentSelectedValues);
            if (selected) {
              nextList.add(opt.value);
            } else {
              nextList.removeWhere(
                (v) => jsonEncode(v) == jsonEncode(opt.value),
              );
            }
            _onFieldValueChanged(field.id, nextList);
          },
        );
      }).toList(),
    );
  }

  Widget _buildBooleanSwitch(UiFieldModel field, dynamic value) {
    final boolVal = value == true;
    return SwitchListTile(
      title: Text(field.label),
      value: boolVal,
      onChanged: (val) {
        _onFieldValueChanged(field.id, val);
      },
    );
  }

  Widget _buildDynamicDataDisplay(dynamic data) {
    if (data == null) {
      return const Text('无数据');
    }

    if (data is List) {
      if (data.isEmpty) {
        return const Text('结果列表为空');
      }
      return ListView.separated(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: data.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (ctx, i) {
          final item = data[i];
          if (item is Map) {
            final taskId =
                item['task_id'] ??
                item['id'] ??
                item['title'] ??
                item['name'] ??
                '任务 #${i + 1}';
            final state = (item['state'] ?? item['status'] ?? '').toString();
            final action = (item['action'] ?? item['description'] ?? '')
                .toString();
            final runAt =
                item['run_at'] ?? item['scheduled_time'] ?? item['date'] ?? '';
            final wakeUp = item['wake_up'];
            final isArmed =
                (wakeUp != null &&
                    wakeUp.toString().isNotEmpty &&
                    wakeUp != 0) ||
                item['wake.scheduled'] == true ||
                item['wake_scheduled'] == true;

            final subtitleParts = <String>[];
            if (action.isNotEmpty) subtitleParts.add('动作: $action');
            if (runAt.toString().isNotEmpty) subtitleParts.add('计划: $runAt');
            if (wakeUp != null) subtitleParts.add('唤醒: $wakeUp');

            String badgeText = state;
            if (state == 'scheduled' || state == 'waiting_wake') {
              badgeText = isArmed ? '已设闹钟 (Armed)' : '已保存 (未设闹钟)';
            }

            return ListTile(
              title: Text(
                '$taskId',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                ),
              ),
              subtitle: subtitleParts.isNotEmpty
                  ? Text(subtitleParts.join('  •  '))
                  : null,
              trailing: badgeText.isNotEmpty
                  ? Chip(
                      label: Text(
                        badgeText,
                        style: const TextStyle(fontSize: 12),
                      ),
                      visualDensity: VisualDensity.compact,
                    )
                  : null,
            );
          }
          return ListTile(title: Text(item.toString()));
        },
      );
    }

    if (data is Map) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: data.entries.map((e) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 4.0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 120,
                  child: Text(
                    '${e.key}:',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
                Expanded(
                  child: SelectableText(
                    e.value is Map || e.value is List
                        ? const JsonEncoder.withIndent('  ').convert(e.value)
                        : '${e.value}',
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      );
    }

    return SelectableText('$data');
  }
}

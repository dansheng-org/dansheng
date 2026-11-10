import 'dart:convert';
import 'dart:math';

/// Representation of a generic select/multiselect option.
class SelectOption {
  final String label;
  final dynamic value;

  const SelectOption({required this.label, required this.value});

  factory SelectOption.fromJson(dynamic json) {
    if (json is Map) {
      final label =
          json['label']?.toString() ??
          json['title']?.toString() ??
          json['name']?.toString() ??
          json.toString();
      final val = json.containsKey('value')
          ? json['value']
          : json['id'] ?? json;
      return SelectOption(label: label, value: val);
    }
    final str = json?.toString() ?? '';
    return SelectOption(label: str, value: json);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SelectOption &&
          runtimeType == other.runtimeType &&
          label == other.label &&
          jsonEncode(value) == jsonEncode(other.value);

  @override
  int get hashCode => label.hashCode ^ jsonEncode(value).hashCode;
}

/// Dynamic source definition for field options.
class UiSourceModel {
  final String action;
  final List<String> dependsOn;

  UiSourceModel({required this.action, required this.dependsOn});

  factory UiSourceModel.fromJson(Map<String, dynamic> json) {
    final action = json['action']?.toString() ?? '';
    final deps =
        (json['dependsOn'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        <String>[];
    return UiSourceModel(action: action, dependsOn: deps);
  }
}

/// Field definition in manifest.ui entry.
class UiFieldModel {
  final String id;
  final String label;
  final String
  type; // text, number, date, datetime, time, select, multiselect, boolean
  final UiSourceModel? source;
  final List<String> clearOnChange;
  final dynamic defaultValue;

  UiFieldModel({
    required this.id,
    required this.label,
    required this.type,
    this.source,
    this.clearOnChange = const [],
    this.defaultValue,
  });

  factory UiFieldModel.fromJson(Map<String, dynamic> json) {
    final id = json['id']?.toString() ?? '';
    final label = json['label']?.toString() ?? id;
    final type = json['type']?.toString().toLowerCase() ?? 'text';
    final source = json['source'] is Map<String, dynamic>
        ? UiSourceModel.fromJson(json['source'] as Map<String, dynamic>)
        : null;
    final clearOnChange =
        (json['clearOnChange'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        <String>[];

    return UiFieldModel(
      id: id,
      label: label,
      type: type,
      source: source,
      clearOnChange: clearOnChange,
      defaultValue: json['defaultValue'],
    );
  }
}

/// Button definition in manifest.ui entry.
class UiButtonModel {
  final String label;
  final String action;
  final List<String> fields;
  final bool confirm;
  final String? prepare;

  UiButtonModel({
    required this.label,
    required this.action,
    required this.fields,
    this.confirm = false,
    this.prepare,
  });

  factory UiButtonModel.fromJson(Map<String, dynamic> json) {
    return UiButtonModel(
      label: json['label']?.toString() ?? '执行',
      action: json['action']?.toString() ?? '',
      fields:
          (json['fields'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          <String>[],
      confirm: json['confirm'] == true,
      prepare: json['prepare']?.toString(),
    );
  }
}

/// Declaration model from manifest.ui entry.
class UiDeclarationModel {
  final String id;
  final String type; // form, card, list, detail, action, settings
  final String title;
  final int uiVersion;
  final String timeZone;
  final List<UiFieldModel> fields;
  final List<UiButtonModel> buttons;
  final Map<String, dynamic> raw;

  UiDeclarationModel({
    required this.id,
    required this.type,
    required this.title,
    this.uiVersion = 1,
    this.timeZone = 'Asia/Shanghai',
    this.fields = const [],
    this.buttons = const [],
    required this.raw,
  });

  factory UiDeclarationModel.fromJson(Map<String, dynamic> json) {
    final id = json['id']?.toString() ?? '';
    final type = json['type']?.toString().toLowerCase() ?? 'card';
    final title = json['title']?.toString() ?? id;
    final uiVersion = json['ui_version'] is int ? json['ui_version'] as int : 1;
    final timeZone = json['time_zone']?.toString() ?? 'Asia/Shanghai';

    final fields =
        (json['fields'] as List<dynamic>?)
            ?.whereType<Map<String, dynamic>>()
            .map((f) => UiFieldModel.fromJson(f))
            .toList() ??
        <UiFieldModel>[];

    final buttons =
        (json['buttons'] as List<dynamic>?)
            ?.whereType<Map<String, dynamic>>()
            .map((b) => UiButtonModel.fromJson(b))
            .toList() ??
        <UiButtonModel>[];

    return UiDeclarationModel(
      id: id,
      type: type,
      title: title,
      uiVersion: uiVersion,
      timeZone: timeZone,
      fields: fields,
      buttons: buttons,
      raw: json,
    );
  }
}

/// A stable editing draft session for a declaration form.
class SchemaDraft {
  final String draftId;
  final UiDeclarationModel declaration;
  final Map<String, dynamic> values = {};

  SchemaDraft({required this.declaration, String? draftId})
    : draftId = draftId ?? _generateDraftId() {
    for (final field in declaration.fields) {
      if (field.defaultValue != null) {
        values[field.id] = field.defaultValue;
      } else if (field.type == 'identifier') {
        values[field.id] = this.draftId;
      }
    }
  }

  static String _generateDraftId() {
    final rnd = Random();
    final ts = DateTime.now().millisecondsSinceEpoch;
    final suffix = rnd.nextInt(999999).toString().padLeft(6, '0');
    return 'draft_${ts}_$suffix';
  }

  /// Update field value and perform cascading clears. Returns dependent field IDs that must reload.
  List<String> setValue(String fieldId, dynamic value) {
    values[fieldId] = value;

    final field = declaration.fields.firstWhere(
      (f) => f.id == fieldId,
      orElse: () => UiFieldModel(id: fieldId, label: '', type: 'text'),
    );

    // Clear dependents specified in clearOnChange
    for (final clearId in field.clearOnChange) {
      values.remove(clearId);
    }

    // Find fields whose source.dependsOn contains fieldId, and clear them as stale dependents
    final reloadFields = declaration.fields
        .where((f) => f.source != null && f.source!.dependsOn.contains(fieldId))
        .map((f) => f.id)
        .toList();

    for (final rfid in reloadFields) {
      values.remove(rfid);
    }

    return reloadFields;
  }

  /// Build action payload containing specified fields and active account_id
  Map<String, dynamic> buildActionInput({
    required List<String> fieldIds,
    required String? accountId,
  }) {
    final input = <String, dynamic>{};

    for (final fid in fieldIds) {
      if (values.containsKey(fid)) {
        input[fid] = values[fid];
      }
    }

    if (accountId != null && accountId.isNotEmpty) {
      input['account_id'] = accountId;
    }

    // NEVER caller-insert approved
    input.remove('approved');

    return input;
  }
}

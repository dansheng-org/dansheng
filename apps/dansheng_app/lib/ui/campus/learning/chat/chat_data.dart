// SPDX-License-Identifier: GPL-3.0-or-later
/// Accept Canvas objects and the core's source-record envelope.
Map<String, dynamic> chatObject(dynamic value) {
  if (value is! Map) throw const FormatException('Invalid Canvas object');
  final map = Map<String, dynamic>.from(value);
  return map['payload'] is Map ? chatObject(map['payload']) : map;
}

List<Map<String, dynamic>> chatList(dynamic value, String key) {
  if (value is Map) {
    final map = chatObject(value);
    value = map[key] ?? map['records'] ?? map['data'];
  }
  if (value is! List) throw const FormatException('Invalid Canvas list');
  return value.map(chatObject).toList();
}

Map<String, dynamic> chatConversation(dynamic value) {
  if (value is List && value.isNotEmpty) value = value.first;
  final map = chatObject(value);
  final result = map['conversation'] is Map
      ? chatObject(map['conversation'])
      : map;
  if ((result['id']?.toString() ?? '').isEmpty) {
    throw const FormatException('Missing conversation id');
  }
  return result;
}

/// A course member selected for a new message.
class ChatRecipient {
  const ChatRecipient({required this.id, required this.name});
  final String id;
  final String name;

  factory ChatRecipient.fromJson(Map<String, dynamic> json) => ChatRecipient(
    id: json['id']?.toString() ?? '',
    name: chatPersonName(json),
  );
}

String chatPersonName(Map<String, dynamic> json) {
  for (final key in ['name', 'short_name']) {
    final value = json[key]?.toString().trim() ?? '';
    if (value.isNotEmpty) return value;
  }
  return '课程成员';
}

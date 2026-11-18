// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:collection';

import 'agent_campus_link.dart';
import 'agent_types.dart';

class AgentConversationSummary {
  const AgentConversationSummary({
    required this.id,
    required this.title,
    required this.updatedAt,
  });

  factory AgentConversationSummary.fromJson(Json json) =>
      AgentConversationSummary(
        id: json['id'] as String,
        title: json['title'] as String,
        updatedAt: json['updated_at'] as int,
      );

  final String id;
  final String title;
  final int updatedAt;
}

class AgentConversation {
  const AgentConversation({
    required this.id,
    required this.title,
    required this.updatedAt,
    required this._turns,
  });

  factory AgentConversation.fromJson(Json json) {
    final summary = AgentConversationSummary.fromJson(json);
    return AgentConversation(
      id: summary.id,
      title: summary.title,
      updatedAt: summary.updatedAt,
      turns: List.unmodifiable(
        (json['turns'] as List<dynamic>).cast<Json>().map(
          AgentHistoryTurn.fromJson,
        ),
      ),
    );
  }

  final String id;
  final String title;
  final int updatedAt;
  final List<AgentHistoryTurn> _turns;

  List<AgentHistoryTurn> get turns => UnmodifiableListView(_turns);

  AgentConversationSummary get summary =>
      AgentConversationSummary(id: id, title: title, updatedAt: updatedAt);

  Json toJson() => {
    'id': id,
    'title': title,
    'updated_at': updatedAt,
    'turns': _turns.map((turn) => turn.toJson()).toList(),
  };
}

class AgentHistoryTurn {
  const AgentHistoryTurn({
    required this.question,
    this.answer,
    this.notice,
    this.model,
    this.destination,
    this.remember = false,
    this._attachments = const [],
    this._webLinks = const [],
    this._campusLinks = const [],
  });

  factory AgentHistoryTurn.fromJson(Json json) => AgentHistoryTurn(
    question: json['question'] as String,
    answer: json['answer'] as String?,
    notice: json['notice'] as String?,
    model: json['model'] as String?,
    destination: json['destination'] as String?,
    remember: json['remember'] as bool,
    attachments: List.unmodifiable(
      (json['attachments'] as List<dynamic>).cast<String>().map(_filename),
    ),
    webLinks: List.unmodifiable(
      (json['web_links'] as List<dynamic>).cast<Json>().map(
        (link) =>
            AgentWebLink.fromJson(link) ??
            (throw const FormatException('Invalid history web link')),
      ),
    ),
    campusLinks: List.unmodifiable(
      ((json['campus_links'] as List<dynamic>?) ?? const []).cast<Json>().map(
        (link) =>
            AgentCampusLink.fromJson(link) ??
            (throw const FormatException('Invalid history campus link')),
      ),
    ),
  );

  final String question;
  final String? answer;
  final String? notice;
  final String? model;
  final String? destination;
  final bool remember;
  final List<String> _attachments;
  final List<AgentWebLink> _webLinks;
  final List<AgentCampusLink> _campusLinks;

  List<String> get attachments => UnmodifiableListView(_attachments);
  List<AgentWebLink> get webLinks => UnmodifiableListView(_webLinks);
  List<AgentCampusLink> get campusLinks => UnmodifiableListView(_campusLinks);

  Json toJson() => {
    'question': question,
    if (answer case final String value) 'answer': value,
    if (notice case final String value) 'notice': value,
    if (model case final String value) 'model': value,
    if (destination case final String value) 'destination': value,
    'remember': remember,
    'attachments': _attachments.map(_filename).toList(),
    'web_links': [
      for (final link in _webLinks)
        {'title': link.title, 'url': link.uri.toString()},
    ],
    if (_campusLinks.isNotEmpty)
      'campus_links': [for (final link in _campusLinks) link.toJson()],
  };
}

final _pathSeparator = RegExp(r'[/\\]');

String _filename(String value) {
  if (value.isEmpty ||
      value == '.' ||
      value == '..' ||
      value.contains(_pathSeparator)) {
    throw const FormatException('Invalid history attachment filename');
  }
  return value;
}

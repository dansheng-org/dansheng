// SPDX-License-Identifier: GPL-3.0-or-later

/// Typed hit from local account-scoped Rust search.
class AgentHit {
  final String sourceId;
  final String externalId;
  final String accountId;
  final String kind;
  final String title;
  final String snippet;
  final Map<String, dynamic> data;
  final String updatedAt;

  const AgentHit({
    required this.sourceId,
    required this.externalId,
    required this.accountId,
    required this.kind,
    required this.title,
    required this.snippet,
    required this.data,
    required this.updatedAt,
  });

  factory AgentHit.fromJson(Map<String, dynamic> json) {
    return AgentHit(
      sourceId: json['source_id']?.toString() ?? '',
      externalId: json['external_id']?.toString() ?? '',
      accountId: json['account_id']?.toString() ?? '',
      kind: json['kind']?.toString() ?? 'record',
      title: json['title']?.toString() ?? '',
      snippet: json['snippet']?.toString() ?? '',
      data: json['data'] is Map<String, dynamic>
          ? json['data'] as Map<String, dynamic>
          : <String, dynamic>{},
      updatedAt: json['updated_at']?.toString() ?? '',
    );
  }
}

/// Labeled evidence source reference with readable excerpt.
class AgentSource {
  final int index;
  final String label;
  final String title;
  final String sourceId;
  final String externalId;
  final String kind;
  final String snippet;
  final String updatedAt;

  const AgentSource({
    required this.index,
    required this.label,
    required this.title,
    required this.sourceId,
    required this.externalId,
    required this.kind,
    required this.snippet,
    required this.updatedAt,
  });

  factory AgentSource.fromJson(Map<String, dynamic> json) {
    return AgentSource(
      index: (json['index'] as num?)?.toInt() ?? 1,
      label: json['label']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      sourceId: json['source_id']?.toString() ?? '',
      externalId: json['external_id']?.toString() ?? '',
      kind: json['kind']?.toString() ?? '',
      snippet: json['snippet']?.toString() ?? '',
      updatedAt: json['updated_at']?.toString() ?? '',
    );
  }
}

/// Practical 'ask' response based strictly on local evidence.
class AgentAnswer {
  final String question;
  final String accountId;
  final String answer;
  final List<AgentSource> sources;
  final int evidenceCount;

  const AgentAnswer({
    required this.question,
    required this.accountId,
    required this.answer,
    required this.sources,
    required this.evidenceCount,
  });

  factory AgentAnswer.fromJson(Map<String, dynamic> json) {
    final rawSources = json['sources'];
    final sourcesList = (rawSources is List)
        ? rawSources
              .whereType<Map<String, dynamic>>()
              .map(AgentSource.fromJson)
              .toList()
        : <AgentSource>[];

    return AgentAnswer(
      question: json['question']?.toString() ?? '',
      accountId: json['account_id']?.toString() ?? '',
      answer: json['answer']?.toString() ?? '',
      sources: sourcesList,
      evidenceCount:
          (json['evidence_count'] as num?)?.toInt() ?? sourcesList.length,
    );
  }
}

/// Loopback HTTP MCP Server pairing and status representation.
/// Bearer token is NOT returned on routine start/status; it is only retrieved on explicit copy.
class McpServerStatus {
  final bool running;
  final int port;
  final String? accountId;
  final String? token;
  final String? url;
  final String? adbCommand;

  const McpServerStatus({
    required this.running,
    required this.port,
    this.accountId,
    this.token,
    this.url,
    this.adbCommand,
  });

  factory McpServerStatus.fromJson(Map<String, dynamic> json) {
    return McpServerStatus(
      running: json['running'] == true,
      port: (json['port'] as num?)?.toInt() ?? 0,
      accountId: json['account_id']?.toString(),
      token: json['token']?.toString(),
      url: json['url']?.toString(),
      adbCommand: json['adb_command']?.toString(),
    );
  }
}

// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'agent_types.dart';

class ModelCatalogEntry {
  const ModelCatalogEntry(this.id, {this.label});

  final String id;
  final String? label;

  String get displayName => formatAgentModelName(id, label);
}

typedef ModelCatalogLoader = Future<List<ModelCatalogEntry>> Function({
  required ModelProvider provider,
  required Uri baseUrl,
  required String apiKey,
});

// Like the model client, append the protocol path after stripping trailing
// slashes from the configured prefix.
Uri normalizeModelApiPrefix(Uri address) {
  final segments = address.pathSegments.toList();
  while (segments.isNotEmpty && segments.last.isEmpty) {
    segments.removeLast();
  }
  return address.replace(pathSegments: segments);
}

/// A single catalog load. Closing it aborts the connection and any pagination.
class ModelCatalog {
  ModelCatalog({HttpClient? client}) : _client = client ?? HttpClient();

  static const _maxPages = 5;
  static const _maxPageBytes = 1024 * 1024;
  static const _maxLabelLength = 120;
  static final _unsafeDisplayCharacters = RegExp(
    r'[\x00-\x1f\x7f-\x9f\u061c\u200e\u200f\u2028-\u202e\u2066-\u2069]',
  );
  static const _timeout = Duration(seconds: 15);
  static const _cancelled = AgentFailure('模型列表读取已取消。');

  final HttpClient _client;
  final _closed = Completer<void>();

  Future<List<ModelCatalogEntry>> load({
    required ModelProvider provider,
    required Uri baseUrl,
    required String apiKey,
  }) async {
    try {
      final prefix = normalizeModelApiPrefix(
        AgentModelConfig.parseBaseUrl(baseUrl.toString()),
      );
      final endpoint = prefix.replace(
        pathSegments: [...prefix.pathSegments, 'models'],
      );
      return await Future.any([
        _loadPages(endpoint, provider, apiKey),
        _closed.future.then<List<ModelCatalogEntry>>((_) => throw _cancelled),
      ]).timeout(_timeout);
    } on AgentFailure {
      rethrow;
    } on TimeoutException {
      throw const AgentFailure('读取模型列表超时。');
    } catch (_) {
      throw const AgentFailure('无法读取模型列表。');
    } finally {
      close();
    }
  }

  void close() {
    if (_closed.isCompleted) return;
    _closed.complete();
    _client.close(force: true);
  }

  Future<List<ModelCatalogEntry>> _loadPages(
    Uri endpoint,
    ModelProvider provider,
    String apiKey,
  ) async {
    final entries = <String, ModelCatalogEntry>{};
    final cursors = <String>{};
    var url = endpoint;
    for (var page = 0; page < _maxPages; page++) {
      final payload = await _getPage(url, provider, apiKey);
      if (payload case {'data': final List<Object?> rows}) {
        for (final row in rows) {
          if (row case {'id': final String rawId}) {
            final id = rawId.trim();
            if (id.isEmpty ||
                id.length > 256 ||
                _unsafeDisplayCharacters.hasMatch(rawId)) {
              continue;
            }
            final rawLabel = switch (row) {
              {'display_name': final String value} => value,
              {'name': final String value} => value,
              _ => '',
            };
            entries.putIfAbsent(id, () {
              final label = rawLabel
                  .replaceAll(_unsafeDisplayCharacters, ' ')
                  .trim();
              final shortened = String.fromCharCodes(
                label.runes.take(_maxLabelLength),
              );
              return ModelCatalogEntry(
                id,
                label: shortened.isEmpty ? null : shortened,
              );
            });
          }
        }
      } else {
        throw const AgentFailure('模型服务返回的列表格式无效。');
      }

      if (provider != ModelProvider.anthropic) break;
      final cursor = switch (payload) {
        {'has_more': true, 'last_id': final String value} => value,
        _ => '',
      };
      if (cursor.trim().isEmpty || !cursors.add(cursor)) break;
      url = endpoint.replace(queryParameters: {'after_id': cursor});
    }
    return List.unmodifiable(entries.values);
  }

  Future<Object?> _getPage(
    Uri url,
    ModelProvider provider,
    String apiKey,
  ) async {
    if (_closed.isCompleted) throw _cancelled;
    final request = await _client.getUrl(url);
    if (_closed.isCompleted) {
      request.abort();
      throw _cancelled;
    }
    request.followRedirects = false;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    switch (provider) {
      case ModelProvider.openAi:
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
      case ModelProvider.anthropic:
        request.headers.set('x-api-key', apiKey);
        request.headers.set('anthropic-version', '2023-06-01');
    }
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      await response.listen(null).cancel();
      throw const AgentFailure('模型服务未返回列表。');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response) {
      if (bytes.length + chunk.length > _maxPageBytes) {
        throw const AgentFailure('模型服务返回的列表过大。');
      }
      bytes.add(chunk);
    }
    return jsonDecode(utf8.decode(bytes.takeBytes()));
  }
}

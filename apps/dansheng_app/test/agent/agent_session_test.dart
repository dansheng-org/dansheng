// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dansheng_app/agent/agent_session.dart';
import 'package:dansheng_app/agent/agent_types.dart';
import 'package:dansheng_app/agent/campus_tools.dart';
import 'package:dansheng_app/agent/web_search.dart';
import 'package:flutter_test/flutter_test.dart';

const _learning = {AgentSourceKind.learning};
const _forum = {AgentSourceKind.forum};
const _courseCall = AgentToolCall('courses', 'campus_courses', {
  'include_archive': true,
});
const _assignmentCall = AgentToolCall('assignments', 'campus_assignments', {
  'course_id': '42',
});

class _Model implements AgentModel {
  _Model(this.replies);

  final List<AgentMessage> replies;
  final requests = <List<AgentMessage>>[];
  final toolsOffered = <List<String>>[];
  bool closed = false;

  @override
  Future<AgentMessage> complete({
    required List<AgentMessage> messages,
    required List<AgentToolSpec> tools,
    required void Function(String) onText,
  }) async {
    toolsOffered.add(tools.map((tool) => tool.name).toList());
    requests.add(messages);
    final reply = replies[requests.length - 1];
    if (reply.text.isNotEmpty) onText(reply.text);
    return reply;
  }

  @override
  void close() => closed = true;
}

Future<String> _send(
  AgentSession session, {
  Set<AgentSourceKind> sources = const {},
  required Future<bool> Function(AgentSourceKind) approve,
}) => session.send(
  '有哪些作业？',
  sources: sources,
  approve: approve,
  onText: (_) {},
  onTool: (_) {},
);

void main() {
  test(
    'only approved, projected campus data leaves the app in this turn',
    () async {
      final model = _Model([
        const AgentMessage.assistant(''),
        const AgentMessage.assistant('', [_courseCall, _assignmentCall]),
        const AgentMessage.assistant('有一门课布置了作业'),
        const AgentMessage.assistant('继续聊天'),
      ]);
      final calls = <String>[];
      final registry = campusToolRegistry(
        activeAccount: () => 'account',
        forumEnabled: () => true,
        read: (method, params) async {
          calls.add(method);
          if (method == 'canvas.courses.sync') {
            return (
              [
                {
                  'payload': {
                    'id': 42,
                    'name': '计算机',
                    'private_field': 'fixture-secret',
                  },
                },
              ],
              true,
            );
          }
          expect(params, {'course_id': '42'});
          return (
            [
              {'name': '第一次作业', 'due_at': '2099-01-01T10:00:00Z'},
            ],
            false,
          );
        },
      );
      final session = AgentSession(model: model, registry: registry);
      addTearDown(session.close);
      await _send(
        session,
        approve: (_) async => throw StateError('unexpected approval'),
      );
      var approvals = 0;
      expect(
        await _send(
          session,
          sources: _learning,
          approve: (source) async {
            expect(source, AgentSourceKind.learning);
            approvals++;
            return true;
          },
        ),
        '有一门课布置了作业',
      );
      await _send(
        session,
        approve: (_) async => throw StateError('unexpected approval'),
      );
      expect(approvals, 1);
      expect(model.toolsOffered.first, isEmpty);
      expect(model.toolsOffered[1], ['campus_courses', 'campus_assignments']);
      expect(calls, ['canvas.courses.sync', 'canvas.assignments.sync']);
      final results = model.requests[2]
          .where((message) => message.role == AgentRole.tool)
          .toList();
      expect(jsonDecode(results[0].text), {
        'source': 'Canvas 课程',
        'cached': true,
        'truncated': false,
        'records': [
          {
            'course_id': '42',
            'name': '计算机',
            'link': 'dansheng://agent/course/42',
          },
        ],
        'campus_links': [
          {'title': '计算机', 'url': 'dansheng://agent/course/42'},
        ],
      });
      expect(results[1].text, contains('2099-01-01T18:00:00+08:00'));
      expect(model.requests.last, hasLength(3));
      expect(
        model.requests.last.every((message) => message.role != AgentRole.tool),
        isTrue,
      );
      expect(
        model.requests.last.any((message) => message.text.contains('有一门课')),
        isFalse,
      );
    },
  );

  test(
    'rejects source denial, extra arguments and tools outside the allowlist',
    () async {
      final model = _Model([
        const AgentMessage.assistant('', [
          AgentToolCall('foreign', 'forum_publish', {'text': 'hi'}),
          AgentToolCall('wrong', 'campus_forum_search', {
            'query': 'x',
            'account_id': 'other',
          }),
          AgentToolCall('denied', 'campus_forum_search', {'query': 'x'}),
          AgentToolCall('denied2', 'campus_forum_search', {'query': 'y'}),
        ]),
        const AgentMessage.assistant('未获得校园数据'),
      ]);
      var approvals = 0;
      var reads = 0;
      final session = AgentSession(
        model: model,
        registry: campusToolRegistry(
          activeAccount: () => 'account',
          forumEnabled: () => true,
          read: (_, _) async {
            reads++;
            return ([], false);
          },
        ),
      );
      addTearDown(session.close);
      await _send(
        session,
        sources: _forum,
        approve: (_) async {
          approvals++;
          return false;
        },
      );
      expect(approvals, 1);
      expect(reads, 0);
      final results = model.requests.last
          .where((message) => message.role == AgentRole.tool)
          .toList();
      expect(results, hasLength(4));
      expect(results[0].text, contains('本轮没有启用此工具'));
      expect(results[1].text, contains('工具参数无效'));
      expect(results[2].text, results[3].text);
    },
  );

  test('drops the result of a campus read when the account changes', () async {
    final model = _Model([
      const AgentMessage.assistant('', [_courseCall]),
    ]);
    final started = Completer<void>();
    final result = Completer<(dynamic, bool)>();
    String? account = 'account';
    final session = AgentSession(
      model: model,
      registry: campusToolRegistry(
        activeAccount: () => account,
        forumEnabled: () => true,
        read: (_, _) async {
          started.complete();
          return result.future;
        },
      ),
    );
    addTearDown(session.close);
    final turn = _send(session, sources: _learning, approve: (_) async => true);
    final assertion = expectLater(turn, throwsA(isA<AgentFailure>()));
    await started.future;
    account = 'other';
    result.complete(([], false));
    await assertion;
    expect(model.requests, hasLength(1));
  });

  test('remote course PDF reaches the model as an attachment without persisting it', () async {
    final model = _Model([
      const AgentMessage.assistant('', [
        AgentToolCall('pdf', 'read_course_pdf', {}),
      ]),
      const AgentMessage.assistant('概括了文件'),
      const AgentMessage.assistant('下一轮'),
    ]);
    final pdf = AgentAttachment(
      name: '作业说明.pdf',
      mimeType: 'application/pdf',
      base64Data: base64Encode(utf8.encode('%PDF-fixture')),
    );
    final session = AgentSession(
      model: model,
      registry: AgentToolRegistry(
        tools: [
          AgentTool(
            spec: const AgentToolSpec('read_course_pdf', 'test', {
              'properties': <String, dynamic>{},
              'required': [],
            }),
            source: AgentSourceKind.files,
            label: '读取 PDF',
            read: (_) async => {'attachment': pdf, 'file': pdf.name},
          ),
        ],
        activeAccount: () => 'test-account',
        sourceAvailable: (_) => true,
      ),
    );
    addTearDown(session.close);
    final sentFiles = <AgentAttachment>[];
    await session.send(
      '概括作业说明',
      sources: {AgentSourceKind.files},
      approve: (_) async => true,
      onText: (_) {},
      onTool: (_) {},
      onRemoteAttachment: sentFiles.add,
    );
    expect(sentFiles, [pdf]);
    final tool = model.requests[1].firstWhere(
      (message) => message.role == AgentRole.tool,
    );
    expect(jsonDecode(tool.text), {'file': pdf.name});
    expect(model.requests[1].last.attachments, [pdf]);
    await _send(session, approve: (_) async => false);
    expect(model.requests.last, hasLength(1));
    expect(model.requests.last.single.attachments, isEmpty);
  });

  test(
    'only approved typed remote attachments reach model content blocks',
    () async {
      final png = AgentAttachment.fromHost(
        name: '图.png',
        mimeType: 'image/png',
        data: base64Encode([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
      );
      final extracted = AgentAttachment.fromHost(
        name: '讲义.pdf.txt',
        mimeType: 'text/plain',
        data: base64Encode(utf8.encode('这段内容只进入附件')),
      );
      final largePdf = Uint8List(agentMaxCampusPdfBytes)
        ..setAll(0, utf8.encode('%PDF-'));
      final binary = AgentAttachment(
        name: 'large.pdf',
        mimeType: 'application/pdf',
        base64Data: base64Encode(largePdf),
        isCampusFile: true,
      );
      final model = _Model([
        const AgentMessage.assistant('', [
          AgentToolCall('too-large', 'canvas_file', {'kind': 'large'}),
          AgentToolCall('invalid-text', 'cloud_file', {'kind': 'invalid'}),
          AgentToolCall('untyped', 'cloud_file', {'kind': 'untyped'}),
          AgentToolCall('extracted', 'canvas_file', {'kind': 'text'}),
          AgentToolCall('image', 'cloud_file', {'kind': 'image'}),
          AgentToolCall('fourth', 'cloud_file', {'kind': 'image'}),
        ]),
        const AgentMessage.assistant('已读取'),
      ]);
      AgentTool tool(String name, AgentSourceKind source) => AgentTool(
        spec: AgentToolSpec(name, name, const {
          'properties': {
            'kind': {'type': 'string'},
          },
          'required': ['kind'],
        }),
        source: source,
        label: name,
        read: (args) async => {
          'attachment': switch (args['kind']) {
            'large' => binary,
            'invalid' => AgentAttachment(
              name: 'invalid.txt',
              mimeType: 'text/plain',
              base64Data: extracted.base64Data,
              text: '字' * (agentMaxTextAttachmentBytes ~/ 3 + 1),
            ),
            'untyped' => {'data': 'base64-is-private'},
            'text' => extracted,
            _ => png,
          },
          if (args['kind'] == 'text') 'extracted': true,
          if (args['kind'] == 'text') 'truncated': true,
        },
      );
      final registry = AgentToolRegistry(
        tools: [
          tool('canvas_file', AgentSourceKind.files),
          tool('cloud_file', AgentSourceKind.cloudFiles),
        ],
        activeAccount: () => 'account',
        sourceAvailable: (_) => true,
      );
      final session = AgentSession(model: model, registry: registry);
      addTearDown(session.close);
      expect(
        registry
            .forSources({AgentSourceKind.files})
            .map((tool) => tool.spec.name),
        ['canvas_file'],
      );
      final approvals = <AgentSourceKind>[];
      final sent = <AgentAttachment>[];
      await session.send(
        '比较这些文件',
        sources: {AgentSourceKind.files, AgentSourceKind.cloudFiles},
        attachments: [png],
        approve: (source) async {
          approvals.add(source);
          return true;
        },
        onText: (_) {},
        onTool: (_) {},
        onRemoteAttachment: sent.add,
      );
      expect(approvals, [AgentSourceKind.files, AgentSourceKind.cloudFiles]);
      expect(sent, [extracted, png]);
      final response = model.requests.last;
      expect(response.last.role, AgentRole.user);
      expect(response.last.attachments, [extracted, png]);
      final results = {
        for (final message in response.where((m) => m.role == AgentRole.tool))
          message.toolCallId: jsonDecode(message.text) as Json,
      };
      expect(results['extracted'], {'extracted': true, 'truncated': true});
      for (final id in ['too-large', 'invalid-text', 'untyped', 'fourth']) {
        expect(results[id], contains('error'));
      }
      final encoded = jsonEncode(results);
      expect(encoded, isNot(contains(extracted.base64Data)));
      expect(encoded, isNot(contains(extracted.text!)));
      expect(encoded, isNot(contains('base64-is-private')));
    },
  );

  test('web search asks about each distinct query and works without a campus account', () async {
    final model = _Model([
      const AgentMessage.assistant('', [
        AgentToolCall('one', 'web_search', {'query': '公开公告'}),
        AgentToolCall('repeat', 'web_search', {'query': '公开公告'}),
        AgentToolCall('private', 'web_search', {'query': '私密关键词'}),
        _courseCall,
      ]),
      const AgentMessage.assistant('找到公开公告'),
    ]);
    final queries = <String>[];
    final approvals = <String>[];
    final links = <AgentWebLink>[];
    final session = AgentSession(
      model: model,
      registry: campusToolRegistry(
        activeAccount: () => null,
        forumEnabled: () => false,
        read: (_, _) async => throw StateError('unexpected campus read'),
        webTool: AgentTool(
          spec: BraveWebSearch('fixture-key').tool.spec,
          source: AgentSourceKind.web,
          label: '搜索网页',
          read: (args) async {
            queries.add(args['query'] as String);
            return {
              'records': [
                {'title': '公告', 'url': 'https://example.test/notice'},
              ],
            };
          },
        ),
      ),
    );
    addTearDown(session.close);
    await session.send(
      '搜索公开公告',
      sources: {AgentSourceKind.web, AgentSourceKind.learning},
      approve: (_) async => throw StateError('unexpected campus approval'),
      approveWebSearch: (query) async {
        approvals.add(query);
        return query == '公开公告';
      },
      onWebLinks: links.addAll,
      onText: (_) {},
      onTool: (_) {},
    );
    expect(model.toolsOffered.first, ['web_search']);
    expect(approvals, ['公开公告', '私密关键词']);
    expect(queries, ['公开公告']);
    expect(links.single.uri.toString(), 'https://example.test/notice');
    final results = model.requests.last
        .where((message) => message.role == AgentRole.tool)
        .toList();
    expect(results.first.text, results[1].text);
    expect(results[2].text, contains('未授权'));
    expect(results.last.text, contains('没有启用此工具'));
  });
}

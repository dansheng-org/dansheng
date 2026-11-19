// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';

import 'package:dansheng_app/agent/agent_session.dart';
import 'package:dansheng_app/agent/agent_types.dart';
import 'package:dansheng_app/bridge.g.dart';
import 'package:dansheng_app/ui/campus/agent/agent_course_files.dart';
import 'package:dansheng_app/ui/campus/agent/agent_tools.dart';
import 'package:dansheng_app/ui/campus/campus_api.dart';
import 'package:dansheng_app/ui/core/dansheng_client.dart';
import 'package:dansheng_app/ui/core/dansheng_state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Bridge implements DanshengBridge {
  final calls = <(String, Json)>[];
  Object? Function(String, Json) respond = (method, _) =>
      throw StateError('Unexpected method $method');

  @override
  Future<String> invoke(HostCommand command, String payload) async {
    expect(command, HostCommand.campus);
    final request = jsonDecode(payload) as Json;
    final method = request['method'] as String;
    final params = request['params'] as Json;
    expect(params.remove('account_id'), 'fixture-account');
    calls.add((method, params));
    return jsonEncode(respond(method, params));
  }
}

class _Controller extends DanshengController {
  _Controller(_Bridge bridge) : super(client: DanshengClient(bridge: bridge));

  @override
  String get activeAccountId => 'fixture-account';
}

class _ConversationModel implements AgentModel {
  _ConversationModel(this.replies);

  final List<AgentMessage> replies;
  final requests = <List<AgentMessage>>[];

  @override
  Future<AgentMessage> complete({
    required List<AgentMessage> messages,
    required List<AgentToolSpec> tools,
    required void Function(String) onText,
  }) async {
    final reply = replies[requests.length];
    requests.add(messages);
    for (final call in reply.calls) {
      expect(tools.map((tool) => tool.name), contains(call.name));
    }
    if (reply.text.isNotEmpty) onText(reply.text);
    return reply;
  }

  @override
  void close() {}
}

Json _cloudItem(String name, String path, {bool folder = false}) => {
  'name': name,
  'path': path,
  'is_folder': folder,
  'downloadable': !folder,
  'private': 'internal field',
};

void main() {
  late _Bridge bridge;
  late CampusApi api;
  late Map<String, AgentTool> canvas;
  late Map<String, AgentTool> cloud;

  setUp(() {
    bridge = _Bridge();
    final controller = _Controller(bridge);
    api = CampusApi.forAccount(controller);
    addTearDown(() {
      api.accountScope!.dispose();
      controller.dispose();
    });
    final registry = campusAgentTools(
      api,
      activeAccount: () => controller.activeAccountId,
      forumEnabled: () => true,
    );
    canvas = {
      for (final tool in registry.forSources({AgentSourceKind.files}))
        tool.spec.name: tool,
    };
    cloud = {
      for (final tool in registry.forSources({AgentSourceKind.cloudFiles}))
        tool.spec.name: tool,
    };
  });

  test(
    'answers Assignment 1 from its PDF and continues the conversation',
    () async {
      const question = '检查我芯片导论的assignment1的第一题，给出解答';
      const firstQuestion = '第 1 题（合成夹具）：求给定模块的输出。';
      const firstPart = '第一题的解法如下。先列出题设关系。';
      const secondPart = '代入题设数值后得到结果，再做一次核对。';
      bridge.respond = (method, params) => switch (method) {
        'canvas.courses.sync' => [
          {'id': '42', 'name': '芯片导论'},
          {'id': '50', 'name': '其他课程'},
        ],
        'canvas.assignments.sync' => [
          {
            'id': '7',
            'course_id': '42',
            'name': 'Assignment 1',
            'due_at': '2020-01-01T00:00:00Z',
            'description':
                '<p>题目见附件。</p>'
                '<a href="/courses/42/files/20?verifier=fixture-secret">说明.pdf</a>',
          },
          {
            'id': '70',
            'course_id': '42',
            'name': 'Assignment 10',
            'description': '错误匹配',
          },
        ],
        'canvas.materials.sync' => [],
        'agent.remoteFile.read' => {
          'name': '说明.pdf.txt',
          'mime_type': 'text/plain',
          'data': base64Encode(utf8.encode(firstQuestion)),
          'extracted': true,
        },
        _ => throw StateError('Unexpected route: $method'),
      };
      final registry = campusAgentTools(
        api,
        activeAccount: () => api.accountScope!.accountId,
        forumEnabled: () => true,
      );
      final model = _ConversationModel([
        const AgentMessage.assistant('', [
          AgentToolCall('course', 'campus_courses', {'query': '芯片导论'}),
        ]),
        const AgentMessage.assistant('', [
          AgentToolCall('assignment', 'campus_assignments', {
            'course_id': '42',
            'query': 'Assignment1',
          }),
        ]),
        const AgentMessage.assistant('', [
          AgentToolCall('list', 'campus_course_files', {
            'course_id': '42',
            'assignment_id': '7',
          }),
        ]),
        const AgentMessage.assistant('', [
          AgentToolCall('read', 'campus_read_course_file', {
            'course_id': '42',
            'assignment_id': '7',
            'file_id': '20',
          }),
        ]),
        const AgentMessage.assistant('', [
          AgentToolCall('page', 'campus_read_course_file', {
            'course_id': '42',
            'assignment_id': '7',
            'file_id': '20',
            'page': 1,
          }),
        ]),
        const AgentMessage.assistantTruncated(firstPart),
        const AgentMessage.assistant(secondPart),
        const AgentMessage.assistant('沿用上一题的推导。'),
      ]);
      final session = AgentSession(model: model, registry: registry);
      addTearDown(session.close);
      final approvals = <AgentSourceKind>[];
      Future<String> send(String question) => session.send(
        question,
        sources: {AgentSourceKind.learning, AgentSourceKind.files},
        approve: (source) async {
          approvals.add(source);
          return true;
        },
        onText: (_) {},
        onTool: (_) {},
      );
      expect(await send(question), '$firstPart\n\n$secondPart');
      expect(approvals, [AgentSourceKind.learning, AgentSourceKind.files]);
      final outgoing = model.requests[5];
      final toolText = outgoing
          .where((entry) => entry.role == AgentRole.tool)
          .map((entry) => entry.text)
          .join();
      expect(toolText, contains('题目见附件'));
      expect(toolText, isNot(contains('Assignment 10')));
      expect(toolText, isNot(contains('fixture-secret')));
      expect(outgoing.last.attachments.single.text, firstQuestion);
      expect(model.requests[6].any((entry) => entry.text == firstPart), isTrue);
      expect(await send('为什么用刚才那个公式？'), '沿用上一题的推导。');
      final followup = model.requests.last;
      expect(followup.map((entry) => entry.text), [
        question,
        '$firstPart\n\n$secondPart',
        '为什么用刚才那个公式？',
      ]);
      expect(
        followup.every(
          (entry) => entry.attachments.isEmpty && entry.role != AgentRole.tool,
        ),
        isTrue,
      );
    },
  );

  test(
    'enabling course files alone can resolve course and assignment names',
    () async {
      bridge.respond = (method, params) => switch (method) {
        'canvas.courses.sync' => [
          {'id': 42, 'name': '物理实验'},
          {'id': 51, 'name': '综合英语'},
        ],
        'canvas.assignments.sync' when params['course_id'] == '42' => [
          {'id': 7, 'name': '报告一'},
          {'id': 8, 'name': '未发布报告', 'published': false},
        ],
        _ => throw StateError('Unexpected lookup $method'),
      };
      final lookup = canvas['campus_file_context']!;
      expect(lookup.accepts({'query': '物理'}), isTrue);
      final courses = await lookup.read({'query': '物理'});
      expect(courses['records'], [
        {
          'course_id': '42',
          'name': '物理实验',
          'url': 'dansheng://agent/course/42',
        },
      ]);
      final assignments = await lookup.read({'course_id': '42', 'query': '报告'});
      expect(assignments['records'], [
        {
          'course_id': '42',
          'assignment_id': '7',
          'name': '报告一',
          'url': 'dansheng://agent/assignment/42/7',
        },
      ]);
    },
  );

  test('Canvas filename matching respects type, size and visibility', () async {
    bridge.respond = (method, _) {
      expect(method, 'canvas.materials.sync');
      return [
        {'id': 1, 'filename': 'Week-One.PNG', 'display_name': '图表'},
        {'id': 2, 'filename': 'week-two.pdf', 'size': agentMaxCampusFileBytes},
        {
          'id': 3,
          'filename': 'week-three.pdf',
          'size': agentMaxCampusFileBytes + 1,
        },
        {'id': 4, 'filename': 'week-four.docx'},
        {'id': 5, 'filename': 'week-five.txt', 'hidden_for_user': true},
        {'id': 6, 'filename': 'private.txt'},
        {'id': 7, 'filename': 'week-seven.csv', 'size': 24 * 1024 + 1},
        {'id': 8, 'filename': 'week-eight.jpeg', 'size': 2 * 1024 * 1024 + 1},
        {'id': 9, 'filename': 'week-nine.md', 'size': -1},
      ];
    };
    final result = await canvas['campus_course_files']!.read({
      'course_id': '42',
      'query': ' WEEK ',
    });
    expect(result['records'], [
      {'file_id': '1', 'name': '图表', 'mime_type': 'image/png'},
      {
        'file_id': '2',
        'name': 'week-two.pdf',
        'mime_type': 'application/pdf',
        'size': agentMaxCampusFileBytes,
      },
      {
        'file_id': '7',
        'name': 'week-seven.csv',
        'mime_type': 'text/csv',
        'size': 24 * 1024 + 1,
      },
      {'file_id': '9', 'name': 'week-nine.md', 'mime_type': 'text/markdown'},
    ]);
  });

  test(
    'assignment-only files retain exact IDs without leaking link URLs',
    () async {
      bridge.respond = (method, _) => switch (method) {
        'canvas.assignments.sync' => [
          {
            'payload': {
              'id': 7,
              'course_id': 42,
              'description': '''
              <a href="/courses/42/files/12/download?verifier=fixture-private"
                 data-api-endpoint="https://elearning.fudan.edu.cn/api/v1/files/12">
                 <strong>研究 &amp; 讲义.pdf</strong></a>
              <a href="/courses/42/files/13">锁定.pdf</a>
              <a href="https://other.example/files/14">外链.pdf</a>
              <a href="/courses/41/files/15">其他课程.pdf</a>
              <a href="https://guest@elearning.fudan.edu.cn/files/16">认证.pdf</a>
              <a href="https://elearning.fudan.edu.cn:8080/files/17">端口.pdf</a>
              <!-- <a href="/files/18">注释.pdf</a> -->
              <script>const entry = '<a href="/files/19">脚本.pdf</a>';</script>
              <a href="/files/20?verifier=fixture-private">/files/20?verifier=fixture-private</a>
            ''',
            },
          },
        ],
        'canvas.materials.sync' => [
          {'id': 13, 'filename': '锁定.pdf', 'locked_for_user': true},
          {'id': 21, 'filename': '未被链接.pdf'},
        ],
        'agent.remoteFile.read' => {
          'name': '研究 & 讲义.pdf.txt',
          'mime_type': 'text/plain',
          'data': base64Encode(utf8.encode('提取的中文内容')),
          'extracted': true,
          'truncated': false,
        },
        _ => throw StateError('Unexpected method $method'),
      };
      final listing = await canvas['campus_course_files']!.read({
        'course_id': '42',
        'assignment_id': '7',
      });
      expect(listing['records'], [
        {
          'file_id': '12',
          'assignment_id': '7',
          'name': '研究 & 讲义.pdf',
          'mime_type': 'application/pdf',
        },
        {'file_id': '20', 'assignment_id': '7', 'name': '作业附件'},
      ]);
      expect(jsonEncode(listing), isNot(contains('fixture-private')));
      final result = await canvas['campus_read_course_file']!.read({
        'course_id': '42',
        'assignment_id': '7',
        'file_id': '12',
      });
      expect(bridge.calls.last.$1, 'agent.remoteFile.read');
      expect(bridge.calls.last.$2, {
        'source': 'canvas',
        'course_id': '42',
        'assignment_id': '7',
        'file_id': '12',
      });
      expect(result['extracted'], isTrue);
      expect(result['truncated'], isFalse);
      expect(result['data'], isNull);
      expect((result['attachment'] as AgentAttachment).text, '提取的中文内容');
    },
  );

  test(
    'Cloud scopes roots and listings by name and forwards exact handles',
    () async {
      const root = '3/42/directory/课程';
      const exact = '3/42/directory/课程/复习%图表.png ';
      bridge.respond = (method, _) => switch (method) {
        'fudan.cloud.roots' => [
          {'name': '课程', 'path': root},
          {'name': '个人隐私根目录', 'path': 'private-root'},
        ],
        'fudan.cloud.list' => {
          'items': [
            _cloudItem('复习图表.png', exact),
            _cloudItem('私人记录.pdf', '$root/私人记录.pdf'),
          ],
        },
        'agent.remoteFile.read' => {
          'name': '复习图表.png',
          'mime_type': 'image/png',
          'data': base64Encode([
            0x89,
            0x50,
            0x4e,
            0x47,
            0x0d,
            0x0a,
            0x1a,
            0x0a,
          ]),
        },
        _ => throw StateError('Unexpected method $method'),
      };
      final roots = await cloud['campus_cloud_roots']!.read({'query': '课程'});
      expect(roots['records'], [
        {'name': '课程', 'path': root, 'kind': 'personal', 'is_folder': true},
      ]);
      final list = cloud['campus_cloud_list']!;
      final result = await list.read({'path': root, 'query': '复习'});
      expect(result['records'], [
        {
          'name': '复习图表.png',
          'path': exact,
          'is_folder': false,
          'readable': true,
          'mime_type': 'image/png',
        },
      ]);
      // Ancestor names in the opaque path do not make every filename a match.
      expect(
        (await list.read({'path': root, 'query': '课程'}))['records'],
        isEmpty,
      );
      final read = cloud['campus_cloud_read']!;
      expect(read.accepts({'query': '复习'}), isFalse);
      expect(
        read.accepts({'path': exact, 'url': 'https://example.test'}),
        isFalse,
      );
      final file = await read.read({'path': exact});
      expect(file['extracted'], isNull);
      expect((file['attachment'] as AgentAttachment).mimeType, 'image/png');
      expect(bridge.calls.last.$1, 'agent.remoteFile.read');
      expect(bridge.calls.last.$2, {'source': 'cloud', 'path': exact});
    },
  );

  test(
    'Cloud search bounds traversal, result count and repeated folders',
    () async {
      const root = 'root';
      const target = 'first';
      bridge.respond = (method, params) {
        expect(method, 'fudan.cloud.list');
        return {
          'items': switch (params['path']) {
            root => [
              _cloudItem('资料目录', target, folder: true),
              _cloudItem('重复目录', target, folder: true),
              for (var i = 0; i < 20; i++)
                _cloudItem('其他目录$i', 'other-$i', folder: true),
            ],
            target => [
              _cloudItem('循环目录', root, folder: true),
              _cloudItem('隐私文件.txt', 'private'),
              _cloudItem('讲义.pdf', 'found'),
            ],
            _ => [],
          },
        };
      };
      final search = cloud['campus_cloud_search']!;
      expect(search.accepts({'query': '讲义'}), isFalse);
      final result = await search.read({'path': root, 'query': '讲义'});
      expect(result['records'], [
        {
          'name': '讲义.pdf',
          'path': 'found',
          'is_folder': false,
          'readable': true,
          'mime_type': 'application/pdf',
        },
      ]);
      expect(result['truncated'], isTrue);
      final paths = bridge.calls.map((call) => call.$2['path']).toList();
      expect(paths, [root, target, for (var i = 0; i < 6; i++) 'other-$i']);

      bridge.calls.clear();
      bridge.respond = (_, params) {
        final path = params['path'] as String;
        return {
          'items': [
            _cloudItem('子目录', '$path/child', folder: true),
            if (path == 'root/child/child')
              for (var i = 0; i < 21; i++) _cloudItem('讲义$i.pdf', 'file-$i'),
          ],
        };
      };
      final nested = await search.read({'path': root, 'query': '讲义'});
      expect(nested['records'], hasLength(20));
      expect(nested['truncated'], isTrue);
      expect(bridge.calls.map((call) => call.$2['path']), [
        'root',
        'root/child',
        'root/child/child',
      ]);
    },
  );

  test(
    'file failures are sanitized and clear reads a combined deleted count',
    () async {
      bridge.respond = (method, _) {
        if (method == 'agent.remoteFile.clear') return {'deleted': 3};
        throw PlatformException(
          code: 'AssetTooLarge',
          message: 'fixture-private',
        );
      };
      expect(await clearAgentRemoteFiles(api), 3);
      expect(bridge.calls.single.$1, 'agent.remoteFile.clear');
      expect(bridge.calls.single.$2, isEmpty);
      final read = cloud['campus_cloud_read']!;
      await expectLater(
        read.read({'path': 'fixture'}),
        throwsA(
          isA<AgentFailure>().having(
            (e) => e.message,
            'message',
            allOf(contains('200 MiB'), isNot(contains('fixture-private'))),
          ),
        ),
      );
      bridge.respond = (_, _) => {
        'name': 'invalid.txt',
        'mime_type': 'text/plain',
        'data': base64Encode([0xc3, 0x28]),
      };
      await expectLater(
        read.read({'path': 'fixture'}),
        throwsA(isA<AgentFailure>()),
      );
    },
  );

  test(
    'large PDFs can be read by page without forwarding the raw file',
    () async {
      final read = cloud['campus_cloud_read']!;
      expect(read.accepts({'path': 'fixture', 'page': 12}), isTrue);
      expect(read.accepts({'path': 'fixture', 'page': 0}), isFalse);
      expect(read.accepts({'path': 'fixture', 'page': '12'}), isFalse);
      bridge.respond = (method, params) {
        expect(method, 'agent.remoteFile.read');
        expect(params, {'source': 'cloud', 'path': 'fixture', 'page': 12});
        return {
          'name': '课程讲义.pdf.txt',
          'mime_type': 'text/plain',
          'data': base64Encode(utf8.encode('这是指定页的文字。')),
          'page': 12,
          'page_count': 103,
          'preview': 'page_text',
          'truncated': true,
        };
      };
      final result = await read.read({'path': 'fixture', 'page': 12});
      expect(result['page'], 12);
      expect(result['page_count'], 103);
      expect(result['preview'], 'page_text');
      expect(result['truncated'], isTrue);
      expect((result['attachment'] as AgentAttachment).text, '这是指定页的文字。');
      expect(result.containsKey('data'), isFalse);
    },
  );
}

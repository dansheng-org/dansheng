import 'dart:convert';

import 'package:dansheng_app/bridge.g.dart';
import 'package:dansheng_app/ui/campus/campus_api.dart';
import 'package:dansheng_app/ui/campus/ehall/notice_sheet.dart';
import 'package:dansheng_app/ui/campus/learning/cloud/cloud_drive_page.dart';
import 'package:dansheng_app/ui/campus/learning/cloud/drive_backend.dart';
import 'package:dansheng_app/ui/campus/learning/cloud/drive_picker.dart';
import 'package:dansheng_app/ui/core/dansheng_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Bridge implements DanshengBridge {
  final calls = <(String, Map)>[];
  List<Map<String, dynamic>> servers = [];

  Map<String, dynamic> _item(
    String name,
    String path, {
    bool folder = false,
    bool share = false,
  }) => {
    'name': name,
    'path': path,
    'is_folder': folder,
    'size': folder ? null : 10,
    'downloadable': !folder,
    'can_rename': true,
    'can_delete': true,
    'can_share': share,
  };

  @override
  Future<String> invoke(HostCommand command, String payload) async {
    final request = jsonDecode(payload) as Map;
    final method = request['method'] as String;
    final params = request['params'] as Map;
    calls.add((method, params));
    if (method == 'campus.cached') return 'null';
    return jsonEncode(switch (method) {
      'fudan.cloud.roots' => [
        {'kind': 'personal', 'name': '个人文件', 'path': '3/42/directory/'},
      ],
      'fudan.cloud.list' => {
        'path': params['path'],
        'can_create': true,
        'items': params['path'] == '3/42/directory/'
            ? [
                _item('资料', '3/42/directory/资料', folder: true),
                _item('a.txt', '3/42/directory/a.txt'),
              ]
            : [],
      },
      'webdav.servers' => servers,
      'webdav.server.add' => {
        'id': 'abcdef012345',
        'name': '坚果云',
        'url': params['url'],
      },
      'webdav.list' => {'path': params['path'], 'items': []},
      'fudan.notice.attachments' => [
        {
          'name': '报名表.docx',
          'url': 'https://gs.fudan.edu.cn/_upload/article/files/a/b.docx',
        },
      ],
      'fudan.notice.attachment.download' ||
      'fudan.cloud.download' ||
      'webdav.download' => {'asset_id': 'asset-9'},
      'fudan.cloud.mkdir' ||
      'fudan.cloud.rename' ||
      'fudan.cloud.delete' ||
      'fudan.cloud.upload' ||
      'webdav.upload' ||
      'webdav.server.remove' ||
      'campus.uploadLocalFile' ||
      'campus.login' ||
      'campus.openFile' ||
      'campus.openNotice' => {'ok': true},
      _ => throw PlatformException(code: 'MethodUnavailable'),
    });
  }

  Map last(String method) => calls.lastWhere((c) => c.$1 == method).$2;
  bool called(String method) => calls.any((c) => c.$1 == method);
}

(CampusApi, _Bridge) _api() {
  final bridge = _Bridge();
  return (CampusApi(DanshengClient(bridge: bridge)), bridge);
}

void main() {
  testWidgets(
    'new folder, rename, delete and local upload go to the host once each',
    (tester) async {
      final (api, bridge) = _api();
      await tester.pumpWidget(
        MaterialApp(home: CloudDrivePage(drive: FudanCloudBackend(api))),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('新建文件夹'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '作业');
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(bridge.last('fudan.cloud.mkdir'), {
        'path': '3/42/directory/',
        'name': '作业',
      });

      await tester.tap(find.byTooltip('更多操作').last);
      await tester.pumpAndSettle();
      // This account cannot share, so the share action is not offered.
      expect(find.text('创建分享链接'), findsNothing);
      await tester.tap(find.text('重命名'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'b.txt');
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(bridge.last('fudan.cloud.rename'), {
        'path': '3/42/directory/a.txt',
        'name': 'b.txt',
      });

      await tester.tap(find.byTooltip('更多操作').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(find.textContaining('回收站'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();
      expect(bridge.last('fudan.cloud.delete'), {
        'path': '3/42/directory/a.txt',
      });

      await tester.tap(find.text('上传文件'));
      await tester.pumpAndSettle();
      expect(bridge.last('campus.uploadLocalFile'), {
        'target': 'fudan.cloud.upload',
        'path': '3/42/directory/',
      });
      expect(
        bridge.calls.where((c) => c.$1 == 'fudan.cloud.delete'),
        hasLength(1),
      );
    },
  );

  testWidgets('a notice attachment is saved into a chosen drive folder', (
    tester,
  ) async {
    final (api, bridge) = _api();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showNoticeSheet(
                  context,
                  api,
                  title: '报名通知',
                  url: 'https://gs.fudan.edu.cn/0d/ac/c1a2/page.htm',
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('报名表.docx'), findsOneWidget);

    await tester.tap(find.byTooltip('存到云盘'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('复旦云盘'));
    await tester.pumpAndSettle();
    // Only folders are offered while picking.
    expect(find.text('a.txt'), findsNothing);
    await tester.tap(find.text('资料'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('存到这里'));
    await tester.pumpAndSettle();
    expect(bridge.last('fudan.notice.attachment.download')['name'], '报名表.docx');
    expect(bridge.last('fudan.cloud.upload'), {
      'path': '3/42/directory/资料',
      'asset_id': 'asset-9',
      'name': '报名表.docx',
    });
    expect(find.textContaining('已保存到'), findsOneWidget);
  });

  testWidgets('adding a WebDAV server asks the host for credentials', (
    tester,
  ) async {
    final (api, bridge) = _api();
    await tester.pumpWidget(MaterialApp(home: DriveHubPage(api: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加 WebDAV 云盘'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), '坚果云');
    await tester.enterText(
      find.byType(TextField).at(1),
      'https://dav.jianguoyun.com/dav/',
    );
    bridge.servers = [
      {
        'id': 'abcdef012345',
        'name': '坚果云',
        'url': 'https://dav.jianguoyun.com/dav/',
        'connected': true,
      },
    ];
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(bridge.last('webdav.server.add'), {
      'url': 'https://dav.jianguoyun.com/dav/',
      'name': '坚果云',
    });
    expect(bridge.last('campus.login'), {'service': 'webdav:abcdef012345'});
    expect(find.text('坚果云'), findsOneWidget);

    await tester.tap(find.byTooltip('移除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '移除'));
    await tester.pumpAndSettle();
    expect(bridge.last('webdav.server.remove'), {'id': 'abcdef012345'});
  });

  test('WebDAV backend sends server-scoped parameters', () async {
    final (api, bridge) = _api();
    final drive = WebDavBackend(
      api,
      const WebDavServer('abcdef012345', '坚果云', 'https://d/', true),
    );
    await drive.uploadAsset('/资料', 'asset-1', name: 'x.pdf');
    expect(bridge.last('webdav.upload'), {
      'id': 'abcdef012345',
      'path': '/资料',
      'asset_id': 'asset-1',
      'name': 'x.pdf',
    });
    await drive.uploadLocal('/');
    expect(bridge.last('campus.uploadLocalFile'), {
      'target': 'webdav.upload',
      'id': 'abcdef012345',
      'path': '/',
    });
    expect(bridge.called('fudan.cloud.upload'), isFalse);
  });
}

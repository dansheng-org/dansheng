// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/services.dart';

import '../../../agent/agent_types.dart';
import '../../core/dansheng_client.dart';
import '../campus_api.dart';

class AgentAttachmentPicker {
  AgentAttachmentPicker(DanshengClient client) : _api = CampusApi(client);

  final CampusApi _api;

  Future<AgentAttachment?> pick() async {
    try {
      final response = await _api.call('agent.attachment.pick');
      if (response case {
        'name': final String name,
        'mime_type': final String mimeType,
        'data': final String data,
      }) {
        return AgentAttachment.fromHost(
          name: name,
          mimeType: mimeType,
          data: data,
        );
      }
      throw const FormatException();
    } on PlatformException catch (error) {
      if (error.code == 'Cancelled') return null;
      throw AgentFailure(switch (error.code) {
        'AttachmentUnsupportedType' => '请选择 PDF、PNG、JPEG、WebP 或 UTF-8 文本文件。',
        'AttachmentTooLarge' => '附件不能超过 2 MiB。',
        'AttachmentTextTooLarge' => '文本附件不能超过 24 KiB。',
        'AttachmentInvalidContent' => '附件为空、内容与类型不匹配，或文本不是有效的 UTF-8。',
        'PickerBusy' => '文件选择器已打开，请稍候。',
        _ => '无法读取附件，请重新选择文件。',
      });
    } on FormatException {
      throw const AgentFailure('无法读取附件，文件数据无效。');
    } on AgentFailure {
      rethrow;
    } catch (_) {
      throw const AgentFailure('无法读取附件，请重新选择文件。');
    }
  }
}

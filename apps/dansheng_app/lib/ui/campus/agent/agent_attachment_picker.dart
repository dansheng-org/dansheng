// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';

import 'package:flutter/services.dart';

import '../../../agent/agent_types.dart';
import '../../core/dansheng_client.dart';
import '../campus_api.dart';

class AgentAttachmentPicker {
  AgentAttachmentPicker(DanshengClient client) : _api = CampusApi(client);

  final CampusApi _api;

  static const _textMimeTypes = {
    'text/plain',
    'text/markdown',
    'text/csv',
    'application/json',
  };
  static const _binaryMimeTypes = {
    'application/pdf',
    'image/png',
    'image/jpeg',
    'image/webp',
  };
  static final _unsafeName = RegExp(r'[\p{Cc}\p{Cf}<>:"/\\|?*]', unicode: true);
  static final _nonTextControls = RegExp(
    r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F]',
  );

  Future<AgentAttachment?> pick() async {
    try {
      final response = await _api.call('agent.attachment.pick');
      if (response case {
        'name': final String name,
        'mime_type': final String mimeType,
        'data': final String data,
      }) {
        return _decode(name, mimeType, data);
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

  static AgentAttachment _decode(String name, String mimeType, String data) {
    final isText = _textMimeTypes.contains(mimeType);
    if ((!isText && !_binaryMimeTypes.contains(mimeType)) ||
        name.isEmpty ||
        name.length > 120 ||
        name.trim() != name ||
        name == '.' ||
        name == '..' ||
        _unsafeName.hasMatch(name)) {
      throw const FormatException();
    }

    final limit = isText
        ? agentMaxTextAttachmentBytes
        : agentMaxAttachmentBytes;
    final sizeFailure = AgentFailure(
      isText ? '文本附件不能超过 24 KiB。' : '附件不能超过 2 MiB。',
    );
    if (data.length > ((limit + 2) ~/ 3) * 4) throw sizeFailure;
    final bytes = base64Decode(data);
    if (bytes.length > limit) throw sizeFailure;
    if (bytes.isEmpty) throw const AgentFailure('附件为空，请选择包含内容的文件。');
    final text = isText ? utf8.decode(bytes) : null;
    if (text != null && _nonTextControls.hasMatch(text)) {
      throw const FormatException();
    }
    return AgentAttachment(
      name: name,
      mimeType: mimeType,
      base64Data: data,
      text: text,
    );
  }
}

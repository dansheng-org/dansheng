// SPDX-License-Identifier: GPL-3.0-or-later
// Forum notifications and messages page adapted from DanXi lib/page/forum/hole_messages.dart.
// Copyright (C) 2021 DanXi-Dev; adaptation (C) 2026 Dansheng contributors.
import 'package:flutter/material.dart';

import '../../core/dansheng_state.dart';
import '../campus_api.dart';
import 'forum_format.dart';
import 'hole_detail_page.dart';

/// Notification model matching DanXi OTMessage.
class ForumNotificationMessage {
  final int messageId;
  final String? message;
  final String? code;
  final int? holeId;
  final int? floorId;
  final String? timeCreated;
  bool hasRead;

  ForumNotificationMessage({
    required this.messageId,
    this.message,
    this.code,
    this.holeId,
    this.floorId,
    this.timeCreated,
    this.hasRead = false,
  });

  factory ForumNotificationMessage.fromJson(Map<String, dynamic> json) {
    int? holeId;
    int? floorId;
    final data = json['data'];
    if (data is Map) {
      if (data['hole_id'] is num) holeId = (data['hole_id'] as num).toInt();
      if (data['floor_id'] is num) floorId = (data['floor_id'] as num).toInt();
    }
    if (holeId == null && json['hole_id'] is num) {
      holeId = (json['hole_id'] as num).toInt();
    }
    if (floorId == null && json['floor_id'] is num) {
      floorId = (json['floor_id'] as num).toInt();
    }

    return ForumNotificationMessage(
      messageId: json['message_id'] is num
          ? (json['message_id'] as num).toInt()
          : (json['id'] is num ? (json['id'] as num).toInt() : 0),
      message: json['message']?.toString() ?? json['description']?.toString(),
      code: json['code']?.toString(),
      holeId: holeId,
      floorId: floorId,
      timeCreated:
          json['time_created']?.toString() ?? json['created_at']?.toString(),
      hasRead: json['has_read'] == true,
    );
  }
}

/// Forum messages and notifications page matching DanXi's `OTMessagesPage`.
class ForumMessagesPage extends StatefulWidget {
  final DanshengController controller;

  const ForumMessagesPage({super.key, required this.controller});

  @override
  State<ForumMessagesPage> createState() => _ForumMessagesPageState();
}

class _ForumMessagesPageState extends State<ForumMessagesPage> {
  late final CampusApi _api;
  final List<ForumNotificationMessage> _messages = [];
  bool _isLoading = true;
  bool _unreadOnly = false;

  @override
  void initState() {
    super.initState();
    _api = CampusApi(widget.controller.client);
    _loadMessages();
  }

  Future<void> _loadMessages() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final res = await _api.call('community.tea.messages', {
        'unread_only': _unreadOnly,
      });

      final List<ForumNotificationMessage> parsed = [];
      if (res is List) {
        for (final item in res) {
          if (item is Map) {
            parsed.add(
              ForumNotificationMessage.fromJson(
                Map<String, dynamic>.from(item),
              ),
            );
          }
        }
      } else if (res is Map && res['items'] is List) {
        for (final item in res['items'] as List) {
          if (item is Map) {
            parsed.add(
              ForumNotificationMessage.fromJson(
                Map<String, dynamic>.from(item),
              ),
            );
          }
        }
      }

      if (mounted) {
        setState(() {
          _messages
            ..clear()
            ..addAll(parsed);
          _isLoading = false;
        });
      }
    } catch (e) {
      // If server does not have messages endpoint, show clean zero-state without error
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _markAllAsRead() {
    setState(() {
      for (final m in _messages) {
        m.hasRead = true;
      }
    });
    try {
      _api.call('community.tea.clearMessages');
    } catch (_) {}
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('已全部标为已读')));
  }

  void _handleMessageTap(ForumNotificationMessage msg) {
    setState(() => msg.hasRead = true);
    if (msg.holeId != null && msg.holeId! > 0) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (ctx) => HoleDetailPage(
            controller: widget.controller,
            holeId: msg.holeId!,
            initialFloorId: msg.floorId,
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    final displayMessages = _unreadOnly
        ? _messages.where((m) => !m.hasRead).toList()
        : _messages;

    return Scaffold(
      appBar: AppBar(
        title: const Text('消息通知'),
        actions: [
          TextButton(
            onPressed: () {
              setState(() => _unreadOnly = !_unreadOnly);
              _loadMessages();
            },
            child: Text(
              _unreadOnly ? '查看全部' : '仅看未读',
              style: TextStyle(color: colors.primary),
            ),
          ),
          if (_messages.any((m) => !m.hasRead))
            IconButton(
              icon: const Icon(Icons.done_all_rounded),
              tooltip: '全部标为已读',
              onPressed: _markAllAsRead,
            ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新',
            onPressed: _loadMessages,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : displayMessages.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.notifications_off_outlined,
                    size: 56,
                    color: colors.onSurfaceVariant.withValues(alpha: 0.5),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _unreadOnly ? '暂无未读消息' : '暂无消息通知',
                    style: TextStyle(
                      fontSize: 15,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            )
          : RefreshIndicator(
              onRefresh: _loadMessages,
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                itemCount: displayMessages.length,
                separatorBuilder: (_, index) => const SizedBox(height: 6),
                itemBuilder: (context, index) {
                  final msg = displayMessages[index];
                  return Card(
                    elevation: 0,
                    color: msg.hasRead
                        ? null
                        : colors.primaryContainer.withValues(alpha: 0.25),
                    child: ListTile(
                      leading: Icon(
                        msg.hasRead
                            ? Icons.mail_outline_rounded
                            : Icons.mark_email_unread_rounded,
                        color: msg.hasRead ? colors.outline : colors.primary,
                      ),
                      title: Text(
                        msg.message ?? '论坛消息通知',
                        style: TextStyle(
                          fontWeight: msg.hasRead
                              ? FontWeight.normal
                              : FontWeight.bold,
                          color: msg.hasRead ? null : colors.primary,
                        ),
                      ),
                      subtitle: msg.timeCreated != null
                          ? Text(
                              formatFriendlyTime(msg.timeCreated),
                              style: TextStyle(
                                fontSize: 12,
                                color: colors.onSurfaceVariant,
                              ),
                            )
                          : null,
                      trailing: const Icon(
                        Icons.chevron_right_rounded,
                        size: 20,
                      ),
                      onTap: () => _handleMessageTap(msg),
                    ),
                  );
                },
              ),
            ),
    );
  }
}

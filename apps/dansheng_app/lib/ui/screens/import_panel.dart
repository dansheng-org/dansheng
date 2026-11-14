// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/dansheng_state.dart';

/// Flagship modern Material 3 extension import modal sheet.
///
/// Presents a warm paper & teal aesthetic with an extension icon, concise
/// Chinese guidance, a selected .dspack file affordance, and a prominent CTA.
/// Launches [controller.importPackage()] using native SAF and handles
/// cancellation gracefully without duplicate prompts.
Future<void> showPluginImporter(
  BuildContext context,
  DanshengController controller,
) async {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final surfaceColor = isDark
      ? const Color(0xFF1A1C1E)
      : const Color(0xFFFAF8F5);

  final shouldImport = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: surfaceColor,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (sheetContext) {
      return ImportPanelSheet(
        onImport: () => Navigator.of(sheetContext).pop(true),
        onCancel: () => Navigator.of(sheetContext).pop(false),
      );
    },
  );

  if (shouldImport == true) {
    try {
      await controller.importPackage();
    } catch (e) {
      // Handle native SAF cancellation or sheet dismissal gracefully
      final errText = e.toString().toLowerCase();
      final isCancelled =
          (e is PlatformException && e.code.toLowerCase() == 'cancelled') ||
          errText.contains('cancelled') ||
          errText.contains('取消');
      if (isCancelled) {
        controller.clearError();
      }
      // Real errors are already preserved in controller.errorMessage;
      // no duplicate alert prompts are raised.
    }
  }
}

/// Content widget for extension import bottom sheet.
class ImportPanelSheet extends StatelessWidget {
  final VoidCallback onImport;
  final VoidCallback onCancel;

  const ImportPanelSheet({
    super.key,
    required this.onImport,
    required this.onCancel,
  });

  // Palette: Warm paper and deep/accessible teal
  static const Color tealLight = Color(0xFF006A72);
  static const Color tealDark = Color(0xFF4DD0E1);
  static const Color tealContainerLight = Color(0xFFCCE8E8);
  static const Color tealContainerDark = Color(0xFF004F55);

  static const Color cardBgLight = Color(0xFFF3EFEA);
  static const Color cardBgDark = Color(0xFF242729);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final primaryTeal = isDark ? tealDark : tealLight;
    final containerTeal = isDark ? tealContainerDark : tealContainerLight;
    final cardColor = isDark ? cardBgDark : cardBgLight;
    final textPrimary = isDark
        ? const Color(0xFFE1E3E3)
        : const Color(0xFF191C1D);
    final textSecondary = isDark
        ? const Color(0xFFBFC8C7)
        : const Color(0xFF404848);

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Extension icon and title header
            Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: containerTeal,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(
                    Icons.extension_rounded,
                    size: 30,
                    color: primaryTeal,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '导入扩展包',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '安装后默认关闭，由你启用。',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Selected .dspack file source affordance card
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: cardColor,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isDark
                      ? const Color(0xFF3F4948)
                      : const Color(0xFFDDE4E3),
                  width: 1,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: containerTeal,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.file_present_rounded,
                      size: 24,
                      color: primaryTeal,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                '本地插件包',
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: textPrimary,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: isDark
                                    ? const Color(0xFF00363A)
                                    : const Color(0xFFE0F2F1),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: isDark
                                      ? const Color(0x664DD0E1)
                                      : const Color(0x66006A72),
                                  width: 0.8,
                                ),
                              ),
                              child: Text(
                                '.dspack',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: primaryTeal,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '从下载目录或文件应用中选择',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Clear CTA Button
            FilledButton.icon(
              onPressed: onImport,
              icon: const Icon(Icons.file_open_rounded, size: 20),
              label: const Text(
                '浏览并导入',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: primaryTeal,
                foregroundColor: isDark
                    ? const Color(0xFF002022)
                    : Colors.white,
                minimumSize: const Size.fromHeight(50),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                elevation: 0,
              ),
            ),
            const SizedBox(height: 8),

            // Dismiss Button
            TextButton(
              onPressed: onCancel,
              style: TextButton.styleFrom(
                foregroundColor: textSecondary,
                minimumSize: const Size.fromHeight(44),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text('取消'),
            ),
          ],
        ),
      ),
    );
  }
}

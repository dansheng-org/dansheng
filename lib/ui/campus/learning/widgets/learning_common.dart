// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

/// Stable soft tint of a course, shared by the week grid, the day list and
/// the course pages so one course keeps one colour everywhere.
({Color background, Color foreground, Color accent}) courseTint(
  String name,
  ColorScheme scheme,
) {
  const hues = <double>[162, 204, 258, 322, 18, 42, 96, 184, 230, 288];
  var hash = 0;
  for (final unit in name.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  final hue = hues[hash % hues.length];
  final dark = scheme.brightness == Brightness.dark;
  return (
    background: HSLColor.fromAHSL(
      1,
      hue,
      dark ? 0.30 : 0.46,
      dark ? 0.26 : 0.88,
    ).toColor(),
    foreground: HSLColor.fromAHSL(
      1,
      hue,
      dark ? 0.45 : 0.50,
      dark ? 0.88 : 0.20,
    ).toColor(),
    accent: HSLColor.fromAHSL(
      1,
      hue,
      dark ? 0.45 : 0.48,
      dark ? 0.62 : 0.42,
    ).toColor(),
  );
}

/// Icon + title row that opens a section of the learning tab.
class SectionHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final List<Widget> trailing;

  const SectionHeader({
    super.key,
    required this.icon,
    required this.title,
    this.trailing = const [],
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, size: 18, color: scheme.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
              ),
              ...trailing,
            ],
          ),
        ),
      ],
    );
  }
}

/// Small neutral pill, e.g. the offline marker or a count.
class SoftBadge extends StatelessWidget {
  final String label;
  final Color? background;
  final Color? foreground;

  const SoftBadge(this.label, {super.key, this.background, this.foreground});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: background ?? scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w500,
          color: foreground ?? scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// Inline notice with one action: a sign-in prompt or a retryable failure.
class InfoBanner extends StatelessWidget {
  final String message;
  final String actionLabel;
  final VoidCallback onAction;
  final bool signIn;

  const InfoBanner({
    super.key,
    required this.message,
    required this.actionLabel,
    required this.onAction,
    this.signIn = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: signIn
            ? scheme.errorContainer.withValues(alpha: 0.4)
            : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: signIn
            ? Border.all(color: scheme.error.withValues(alpha: 0.3))
            : null,
      ),
      child: Row(
        children: [
          Icon(
            signIn ? Icons.lock_outline_rounded : Icons.info_outline_rounded,
            size: signIn ? 20 : 18,
            color: signIn ? scheme.error : scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: 13,
                color: signIn ? scheme.onErrorContainer : scheme.onSurface,
              ),
            ),
          ),
          if (signIn)
            FilledButton.tonal(
              onPressed: onAction,
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              child: Text(actionLabel),
            )
          else
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              child: Text(actionLabel),
            ),
        ],
      ),
    );
  }
}

/// Quiet placeholder for a section that has nothing to show.
class EmptyHint extends StatelessWidget {
  final IconData icon;
  final String text;

  const EmptyHint({super.key, required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.3)),
      ),
      child: Column(
        children: [
          Icon(icon, size: 24, color: scheme.outline),
          const SizedBox(height: 4),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: scheme.outline),
          ),
        ],
      ),
    );
  }
}

/// Centered spinner used while a section loads its first data.
class SectionSpinner extends StatelessWidget {
  const SectionSpinner({super.key});

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: 16),
    child: Center(
      child: SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    ),
  );
}

// SPDX-License-Identifier: GPL-3.0-or-later
// DanXi-style rectangular and leading chips adapted from DanXi
// lib/widget/libraries/chip_widgets.dart and lib/util/public_extension_methods.dart.
// Copyright (C) 2021 DanXi-Dev; GPL-3.0-or-later.
import 'package:flutter/material.dart';

/// 18-color palette from DanXi Constant.TAG_COLOR_LIST.
const List<MaterialColor> _tagColorPalette = [
  Colors.red,
  Colors.pink,
  Colors.purple,
  Colors.deepPurple,
  Colors.indigo,
  Colors.blue,
  Colors.lightBlue,
  Colors.cyan,
  Colors.teal,
  Colors.green,
  Colors.lightGreen,
  Colors.lime,
  Colors.yellow,
  Colors.amber,
  Colors.orange,
  Colors.deepOrange,
  Colors.brown,
  Colors.blueGrey,
];

/// Computes consistent hash color for tags and anonymous names matching DanXi.
Color getHashColor(String text, {bool isDark = false}) {
  if (text.isEmpty || text.startsWith('*')) return Colors.red;
  var sum = 0;
  for (final code in text.runes) {
    sum += code;
  }
  final materialColor = _tagColorPalette[sum % _tagColorPalette.length];
  return isDark
      ? (materialColor[300] ?? materialColor)
      : (materialColor[800] ?? materialColor);
}

/// Leading badge chip for forum status markers (OP/LZ, Pinned, Hidden, Locked, Frozen, Special Tag).
class LeadingChip extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback? onTap;

  const LeadingChip({
    super.key,
    required this.label,
    required this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final textColor = color.computeLuminance() <= 0.5
        ? Colors.white
        : Colors.black;
    final container = Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.85),
        borderRadius: const BorderRadius.all(Radius.circular(2.0)),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: FontWeight.bold,
          color: textColor,
          fontSize: 12,
        ),
      ),
    );

    if (onTap == null) return container;
    return GestureDetector(onTap: onTap, child: container);
  }
}

/// Rectangular tag chip matching DanXi's forum tag design.
class RectangularChip extends StatelessWidget {
  final String label;
  final Color? color;
  final VoidCallback? onTap;

  const RectangularChip({
    super.key,
    required this.label,
    this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final effectiveColor = color ?? getHashColor(label, isDark: isDark);

    final container = Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
      decoration: BoxDecoration(
        color: effectiveColor.withValues(alpha: isDark ? 0.25 : 0.15),
        borderRadius: const BorderRadius.all(Radius.circular(2.0)),
      ),
      child: Text(
        label.startsWith('#') ? label : '#$label',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: FontWeight.w600,
          color: effectiveColor,
          fontSize: 12,
        ),
      ),
    );

    if (onTap == null) return container;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(2.0),
      child: container,
    );
  }
}

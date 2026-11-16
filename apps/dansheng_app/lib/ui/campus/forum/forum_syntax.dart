// SPDX-License-Identifier: GPL-3.0-or-later
// Custom forum syntax adapted from DanXi-Dev/DanXi lib/widget/forum/render/render_impl.dart.
// Copyright (C) 2021 DanXi-Dev; adaptation (C) 2026 Dansheng contributors.
import 'package:markdown/markdown.dart' as md;

List<md.InlineSyntax> forumInlineSyntaxes() => [
  ForumMathSyntax(),
  ForumMentionSyntax(),
  ForumAuditSyntax(),
];

class ForumMathSyntax extends md.InlineSyntax {
  ForumMathSyntax()
    : super(
        r'\$\$([\s\S]+?)\$\$|(?<!\$)\$([^$\n]+?)\$(?!\$)|<(tex|texLine)>([\s\S]*?)</\3>',
      );

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final block = match[1] != null || match[3] == 'texLine';
    parser.addNode(
      md.Element.text(
        block ? 'forum-math-block' : 'forum-math',
        match[1] ?? match[2] ?? match[4] ?? '',
      ),
    );
    return true;
  }
}

class ForumMentionSyntax extends md.InlineSyntax {
  ForumMentionSyntax()
    : super(
        r'(?<![\w#])(#{1,2})([1-9][0-9]*)\b|<(holeMention|floorMention)>([1-9][0-9]*)</\3>',
      );

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final floor = match[1] == '##' || match[3] == 'floorMention';
    final id = match[2] ?? match[4]!;
    parser.addNode(md.Element.text(floor ? 'floorMention' : 'holeMention', id));
    return true;
  }
}

class ForumAuditSyntax extends md.InlineSyntax {
  ForumAuditSyntax() : super(r'<audit>([\s\S]*?)</audit>');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.text('forum-audit', match[1]!));
    return true;
  }
}

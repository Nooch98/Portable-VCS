class IgnoreRule {
  final String original;
  final String pattern;
  final bool negated;
  final bool directoryOnly;
  final bool anchoredToRoot;
  final RegExp regex;

  IgnoreRule({
    required this.original,
    required this.pattern,
    required this.negated,
    required this.directoryOnly,
    required this.anchoredToRoot,
    required this.regex,
  });

  static IgnoreRule? parse(String line) {
    var raw = line.trim();

    if (raw.isEmpty) return null;
    if (raw.startsWith('#')) return null;

    var negated = false;
    if (raw.startsWith('!')) {
      negated = true;
      raw = raw.substring(1).trim();
      if (raw.isEmpty) return null;
    }

    var directoryOnly = false;
    if (raw.endsWith('/')) {
      directoryOnly = true;
      raw = raw.substring(0, raw.length - 1);
      if (raw.isEmpty) return null;
    }

    var anchoredToRoot = false;
    if (raw.startsWith('/')) {
      anchoredToRoot = true;
      raw = raw.substring(1);
      if (raw.isEmpty) return null;
    }

    final regex = _buildRegex(
      raw,
      directoryOnly: directoryOnly,
      anchoredToRoot: anchoredToRoot,
    );

    return IgnoreRule(
      original: line,
      pattern: raw,
      negated: negated,
      directoryOnly: directoryOnly,
      anchoredToRoot: anchoredToRoot,
      regex: regex,
    );
  }

  bool matches(String normalizedPath, String basename) {
    if (directoryOnly) {
      if (regex.hasMatch(normalizedPath)) return true;
      final parts = normalizedPath.split('/');
      for (var i = 0; i < parts.length - 1; i++) {
        final partial = parts.sublist(0, i + 1).join('/');
        if (regex.hasMatch(partial)) return true;
      }
      return false;
    }

    if (regex.hasMatch(normalizedPath)) return true;

    if (!pattern.contains('/')) {
      return regex.hasMatch(basename);
    }

    return false;
  }

  static RegExp _buildRegex(
    String pattern, {
    required bool directoryOnly,
    required bool anchoredToRoot,
  }) {
    final escaped = _globToRegex(pattern);

    String body;
    if (anchoredToRoot) {
      body = '^$escaped';
    } else {
      body = '(^|.*/)$escaped';
    }

    if (directoryOnly) {
      body = '$body(\$|/.*)';
    } else {
      body = '$body\$';
    }

    return RegExp(body);
  }

  static String _globToRegex(String input) {
    final buffer = StringBuffer();
    for (var i = 0; i < input.length; i++) {
      final ch = input[i];
      switch (ch) {
        case '*':
          buffer.write('[^/]*');
          break;
        case '?':
          buffer.write('[^/]');
          break;
        case '.':
        case r'\':
        case '+':
        case '(':
        case ')':
        case '[':
        case ']':
        case '{':
        case '}':
        case '^':
        case r'$':
        case '|':
          buffer.write('\\$ch');
          break;
        default:
          buffer.write(ch);
      }
    }
    return buffer.toString();
  }
}

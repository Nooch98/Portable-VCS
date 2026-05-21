import 'dart:io';

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
    } else if (raw.contains('/') && !raw.startsWith('**')) {
      anchoredToRoot = true;
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
    final path = normalizedPath.replaceAll(r'\', '/');

    if (directoryOnly) {
      return regex.hasMatch(path);
    }

    if (regex.hasMatch(path)) return true;

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
      body = '$body(\$|/.*)';
    }

    return RegExp(
      body, 
      caseSensitive: !Platform.isWindows && !Platform.isMacOS
    );
  }

  static String _globToRegex(String input) {
    final buffer = StringBuffer();
    var i = 0;

    while (i < input.length) {
      if (i + 1 < input.length && input[i] == '*' && input[i + 1] == '*') {
        bool startWithSlash = (i == 0 || input[i - 1] == '/');
        bool endWithSlash = (i + 2 == input.length || input[i + 2] == '/');

        if (startWithSlash && endWithSlash) {
          if (i == 0 && i + 2 < input.length) {
            buffer.write('(.*)?');
            i += 3;
            continue;
          } else if (i > 0 && i + 2 < input.length) {
            buffer.write('(/.*)?');
            i += 2;
            continue;
          } else {
            buffer.write('.*');
            i += 2;
            continue;
          }
        } else {
          buffer.write('.*');
          i += 2;
          continue;
        }
      }

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
      i++;
    }
    return buffer.toString();
  }
}

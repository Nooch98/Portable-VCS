import 'dart:io';

class DoctorReporter {
  final List<String> _lines = [];
  
  void log(String message) => _lines.add(message);
  
  Future<void> save(String path) async {
    final report = [
      '# VCS Diagnostic Report - ${DateTime.now().toIso8601String()}',
      '',
      ..._lines,
    ].join('\n');
    await File(path).writeAsString(report);
  }
}

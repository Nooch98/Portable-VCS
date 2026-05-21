import 'dart:async';
import 'dart:io';

class ProgressVisualizer {
  final String label;
  final int totalBytes;
  final int barWidth;
  
  int _processedBytes = 0;
  final DateTime _startTime = DateTime.now();

  ProgressVisualizer({
    required this.label,
    required this.totalBytes,
    this.barWidth = 30,
  }) {
    if (totalBytes > 0) _render();
  }

  void update(int chunkSize) {
    _processedBytes += chunkSize;
    if (_processedBytes > totalBytes) _processedBytes = totalBytes;
    _render();
  }

  void complete() {
    _processedBytes = totalBytes;
    _render();
    stdout.writeln();
  }

  void _render() {
    if (totalBytes == 0) return;
    
    final double progress = _processedBytes / totalBytes;
    final int filled = (progress * barWidth).round();
    final int empty = barWidth - filled;

    final bar = '█' * filled + '░' * empty;
    final percent = (progress * 100).toStringAsFixed(1).padLeft(5);
    
    final elapsed = DateTime.now().difference(_startTime).inMilliseconds;
    final speed = elapsed > 500 
        ? ((_processedBytes / 1024 / 1024) / (elapsed / 1000)).toStringAsFixed(2)
        : '...';

    final output = '\r⚡ $label: [$bar] $percent% | $speed MB/s';

    stdout.write(output.padRight(stdout.hasTerminal ? stdout.terminalColumns : 80));
  }
}

extension ProgressStream<T extends List<int>> on Stream<T> {
  Stream<T> withProgress(ProgressVisualizer visualizer) {
    return transform(
      StreamTransformer<T, T>.fromHandlers(
        handleData: (chunk, sink) {
          visualizer.update(chunk.length);
          sink.add(chunk);
        },
        handleDone: (sink) {
          visualizer.complete();
          sink.close();
        },
      ),
    );
  }
}

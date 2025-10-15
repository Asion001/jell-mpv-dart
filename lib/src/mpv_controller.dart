import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'config.dart';

/// Manages an mpv process through its JSON IPC interface.
class MpvController {
  MpvController(this.config);

  final JellyfinConfig config;
  final _log = Logger('MpvController');
  final _exitController = StreamController<int>.broadcast();
  final Map<int, Completer<dynamic>> _pendingRequests = {};

  Process? _process;
  Socket? _ipcSocket;
  StreamSubscription<String>? _ipcSubscription;
  String? _ipcPath;
  int _nextRequestId = 1;

  Stream<int> get onExit => _exitController.stream;

  bool get isRunning => _process != null;

  Future<void> play(
    Uri mediaUrl, {
    String? title,
    Duration? startPosition,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
  }) async {
    await stop();
    final ipcPath = await _prepareIpcPath();
    final args = <String>[
      '--input-ipc-server=$ipcPath',
      if (title != null) '--title=$title',
      if (startPosition != null)
        '--start=${startPosition.inMilliseconds / 1000}',
      if (audioStreamIndex != null) '--aid=${audioStreamIndex + 1}',
      if (subtitleStreamIndex != null) '--sid=${subtitleStreamIndex + 1}',
      ...config.mpvArgs,
      mediaUrl.toString(),
    ];
    _log.info('Starting mpv with ${args.join(' ')}');
    _process = await Process.start(config.mpvExecutable, args);
    _process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => _log.fine('mpv stdout: $line'));
    _process!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => _log.warning('mpv stderr: $line'));

    _process!.exitCode.then((code) {
      _log.info('mpv exited with code $code');
      _exitController.add(code);
      _cleanup();
    });

    await _attachIpc(ipcPath);
  }

  Future<void> stop() async {
    final process = _process;
    if (process == null) {
      return;
    }
    try {
      await _sendCommand(['quit']);
      await process.exitCode.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      _log.warning('mpv quit timeout, sending SIGTERM');
      process.kill(ProcessSignal.sigterm);
      await process.exitCode;
    } finally {
      _cleanup();
    }
  }

  Future<Duration?> queryPosition() async {
    final response = await _sendCommand(['get_property', 'time-pos']);
    if (response is num) {
      return Duration(milliseconds: (response * 1000).round());
    }
    return null;
  }

  Future<void> setPause(bool value) async {
    await _sendCommand(['set_property', 'pause', value]);
  }

  Future<void> seek(Duration position) async {
    await _sendCommand([
      'set_property',
      'time-pos',
      position.inMilliseconds / 1000,
    ]);
  }

  Future<dynamic> _sendCommand(List<dynamic> command) async {
    final socket = _ipcSocket;
    if (socket == null) {
      throw StateError('mpv IPC socket is not ready.');
    }
    final requestId = _nextRequestId++;
    final payload = jsonEncode({'command': command, 'request_id': requestId});
    final completer = Completer<dynamic>();
    _pendingRequests[requestId] = completer;
    socket.write('$payload\n');
    return completer.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        _pendingRequests.remove(requestId);
        throw TimeoutException('mpv command timeout');
      },
    );
  }

  Future<String> _prepareIpcPath() async {
    final dir = await Directory.systemTemp.createTemp('jell_mpv_');
    _ipcPath = p.join(dir.path, 'mpv.sock');
    return _ipcPath!;
  }

  Future<void> _attachIpc(String socketPath) async {
    final address = InternetAddress(socketPath, type: InternetAddressType.unix);
    final stopwatch = Stopwatch()..start();
    while (stopwatch.elapsed < const Duration(seconds: 5)) {
      if (await File(socketPath).exists()) {
        try {
          _ipcSocket = await Socket.connect(address, 0);
          break;
        } catch (_) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      } else {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    if (_ipcSocket == null) {
      throw StateError('Failed to connect to mpv IPC socket.');
    }
    _ipcSubscription = utf8.decoder
        .bind(_ipcSocket!)
        .transform(const LineSplitter())
        .listen(_handleIpcMessage);
  }

  void _handleIpcMessage(String line) {
    if (line.isEmpty) {
      return;
    }
    try {
      final decoded = jsonDecode(line);
      if (decoded is Map<String, dynamic>) {
        final requestId = decoded['request_id'];
        if (requestId is int) {
          final completer = _pendingRequests.remove(requestId);
          completer?.complete(decoded['data']);
          return;
        }
      }
      _log.fine('mpv IPC: $decoded');
    } catch (error, stackTrace) {
      _log.severe('Failed to parse mpv IPC message: $line', error, stackTrace);
    }
  }

  void _cleanup() {
    _ipcSubscription?.cancel();
    _ipcSubscription = null;
    _ipcSocket?.destroy();
    _ipcSocket = null;
    _process = null;
    if (_ipcPath != null) {
      final sockFile = File(_ipcPath!);
      if (sockFile.existsSync()) {
        sockFile.deleteSync();
      }
      final parentDir = Directory(p.dirname(_ipcPath!));
      if (parentDir.existsSync()) {
        parentDir.deleteSync(recursive: true);
      }
      _ipcPath = null;
    }
    for (final completer in _pendingRequests.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('mpv stopped'));
      }
    }
    _pendingRequests.clear();
  }
}

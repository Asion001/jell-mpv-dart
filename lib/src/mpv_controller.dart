import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'config.dart';

/// Represents a property change event from mpv.
class MpvPropertyChange {
  MpvPropertyChange(this.property, this.value);

  final String property;
  final dynamic value;
}

/// Manages an mpv process through its JSON IPC interface.
class MpvController {
  MpvController(this.config);

  final JellyfinConfig config;
  final _log = Logger('MpvController');
  final _exitController = StreamController<int>.broadcast();
  final _propertyChangeController =
      StreamController<MpvPropertyChange>.broadcast();
  final Map<int, Completer<dynamic>> _pendingRequests = {};

  Process? _process;
  Socket? _ipcSocket;
  StreamSubscription<String>? _ipcSubscription;
  String? _ipcPath;
  int _nextRequestId = 1;

  Stream<int> get onExit => _exitController.stream;
  Stream<MpvPropertyChange> get onPropertyChange =>
      _propertyChangeController.stream;

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
      // Jellyfin sends absolute container stream indices
      // Pass them directly to mpv
      if (audioStreamIndex != null) '--aid=$audioStreamIndex',
      if (subtitleStreamIndex != null) '--sid=$subtitleStreamIndex',
      ...config.mpvArgs,
      mediaUrl.toString(),
    ];
    _log.info('Starting mpv with ${args.join(' ')}');
    final process = await Process.start(config.mpvExecutable, args);
    _process = process;

    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => _log.fine('mpv stdout: $line'));
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => _log.warning('mpv stderr: $line'));

    // Capture the process reference to avoid race condition with stop()
    process.exitCode.then((code) {
      _log.info('mpv process exited with code $code');
      _exitController.add(code);
      // Only cleanup if this is still the active process
      if (_process == process) {
        _log.fine('Cleaning up after mpv exit');
        _cleanup();
      } else {
        _log.fine('Skipping cleanup - different process is now active');
      }
    });

    await _attachIpc(ipcPath);

    // Observe properties for real-time change notifications
    await _observeProperty('pause');
    await _observeProperty('time-pos');
    await _observeProperty('volume');
    await _observeProperty('mute');
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

  Future<bool> queryPaused() async {
    final response = await _sendCommand(['get_property', 'pause']);
    if (response is bool) {
      return response;
    }
    return false;
  }

  Future<bool> queryMuted() async {
    final response = await _sendCommand(['get_property', 'mute']);
    if (response is bool) {
      return response;
    }
    return false;
  }

  Future<int?> queryVolume() async {
    final response = await _sendCommand(['get_property', 'volume']);
    if (response is num) {
      return response.round();
    }
    return null;
  }

  Future<int?> queryAudioTrack() async {
    final response = await _sendCommand(['get_property', 'aid']);
    if (response == 'no' || response == false) {
      return null; // No audio track selected
    }
    if (response is num) {
      // mpv returns the absolute stream ID from the container
      // Pass through directly to Jellyfin
      return response.round();
    }
    return null;
  }

  Future<int?> querySubtitleTrack() async {
    final response = await _sendCommand(['get_property', 'sid']);
    if (response == 'no' || response == false) {
      return null; // No subtitle track selected
    }
    if (response is num) {
      // mpv returns the absolute stream ID from the container
      // Pass through directly to Jellyfin
      return response.round();
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

  Future<void> setVolume(int value) async {
    final clampedValue = value.clamp(0, 100);
    _log.info('MpvController.setVolume: Setting volume to $clampedValue');
    await _sendCommand(['set_property', 'volume', clampedValue]);
    _log.info('MpvController.setVolume: Command sent');
  }

  Future<void> setMute(bool value) async {
    await _sendCommand(['set_property', 'mute', value]);
  }

  Future<void> adjustVolume(int delta) async {
    final current = await queryVolume() ?? 100;
    await setVolume((current + delta).clamp(0, 100));
  }

  Future<void> setAudioTrack(int index) async {
    _log.info('Setting audio track to Jellyfin stream index: $index');

    if (index < 0) {
      await _sendCommand(['set_property', 'aid', 'no']);
      _log.info('Audio track disabled');
      return;
    }

    // Jellyfin sends absolute container stream indices
    // mpv's set_property aid can accept absolute stream IDs directly
    // Pass through without conversion
    _log.info('Setting mpv aid=$index (absolute stream ID from container)');
    await _sendCommand(['set_property', 'aid', index]);
    _log.info('Audio track set to aid=$index');
  }

  Future<void> setSubtitleTrack(int index) async {
    _log.info('Setting subtitle track to Jellyfin stream index: $index');

    if (index < 0) {
      await _sendCommand(['set_property', 'sid', 'no']);
      _log.info('Subtitle track disabled');
      return;
    }

    // Jellyfin sends absolute container stream indices
    // mpv's set_property sid can accept absolute stream IDs directly
    // Pass through without conversion
    _log.info('Setting mpv sid=$index (absolute stream ID from container)');
    await _sendCommand(['set_property', 'sid', index]);
    _log.info('Subtitle track set to sid=$index');
  }

  Future<void> setFullscreen(bool value) async {
    await _sendCommand(['set_property', 'fullscreen', value]);
  }

  Future<void> toggleFullscreen() async {
    await _sendCommand(['cycle', 'fullscreen']);
  }

  Future<void> _observeProperty(String property) async {
    await _sendCommand(['observe_property', _nextRequestId++, property]);
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
        // Handle command responses
        final requestId = decoded['request_id'];
        if (requestId is int) {
          final completer = _pendingRequests.remove(requestId);
          completer?.complete(decoded['data']);
          return;
        }

        // Handle property change events
        final event = decoded['event'];
        if (event == 'property-change') {
          final property = decoded['name'] as String?;
          final data = decoded['data'];
          if (property != null) {
            _propertyChangeController.add(MpvPropertyChange(property, data));
          }
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

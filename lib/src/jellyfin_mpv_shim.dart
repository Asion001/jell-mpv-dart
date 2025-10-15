import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

import 'config.dart';
import 'jellyfin_api.dart';
import 'jellyfin_websocket.dart';
import 'models.dart';
import 'mpv_controller.dart';

class JellyfinMpvShim {
  JellyfinMpvShim({
    required this.config,
    JellyfinApi? api,
    JellyfinWebSocket? websocket,
    MpvController? mpv,
  }) : api = api ?? JellyfinApi(config),
       websocket = websocket ?? JellyfinWebSocket(config),
       mpv = mpv ?? MpvController(config);

  final JellyfinConfig config;
  final JellyfinApi api;
  final JellyfinWebSocket websocket;
  final MpvController mpv;
  final _log = Logger('JellyfinMpvShim');
  final _uuid = const Uuid();

  StreamSubscription? _wsSubscription;
  StreamSubscription<int>? _mpvSubscription;
  Timer? _progressTimer;
  final Completer<void> _done = Completer<void>();
  Future<void> _lastPlaybackClose = Future<void>.value();

  String? _currentItemId;
  String? _currentMediaSourceId;
  String? _currentPlaySessionId;
  Duration _lastKnownPosition = Duration.zero;

  Future<void> run() async {
    _log.info('Starting Jellyfin → mpv shim.');

    // Authenticate if username/password provided
    String? sessionToken;
    if (config.username != null && config.password != null) {
      _log.info('Authenticating with username/password...');
      try {
        sessionToken = await api.authenticateByName(
          config.username!,
          config.password!,
        );
        _log.info('Authentication successful.');
      } catch (error, stackTrace) {
        _log.severe('Authentication failed', error, stackTrace);
        rethrow;
      }
    }

    _mpvSubscription = mpv.onExit.listen((code) {
      final future = _handleMpvExit(code);
      _lastPlaybackClose = future;
      future.catchError((error, stackTrace) {
        _log.warning('Error during mpv exit handling', error, stackTrace);
      });
    });
    await websocket.start(token: sessionToken);
    _wsSubscription = websocket.messages.listen(
      _handleSocketMessage,
      onError: (error, stackTrace) {
        _log.severe('WebSocket stream error', error, stackTrace);
      },
    );
    await websocket.ready;
    _log.info('Connected to Jellyfin WebSocket. Announcing capabilities...');

    // Announce capabilities so Jellyfin shows this client in "Play on" dialog
    try {
      await api.announceCapabilities();
      _log.info(
        'Capabilities announced. Client should appear in "Play on" dialog.',
      );
    } catch (error, stackTrace) {
      _log.warning('Failed to announce capabilities', error, stackTrace);
    }

    await _done.future;
  }

  Future<void> shutdown() async {
    if (_done.isCompleted) {
      return;
    }
    _log.info('Shutting down Jellyfin → mpv shim.');
    _progressTimer?.cancel();
    _progressTimer = null;
    await _wsSubscription?.cancel();
    await websocket.close();
    await mpv.stop();
    await _lastPlaybackClose;
    await api.close();
    _mpvSubscription?.cancel();
    if (!_done.isCompleted) {
      _done.complete();
    }
    exit(0);
  }

  void _handleSocketMessage(JellyfinSocketMessage message) {
    switch (message.type) {
      case 'Play':
        final data = message.tryDecodeData();
        if (data == null) {
          _log.warning('Play message missing payload.');
          return;
        }
        final request = PlayRequest.fromJson(data);
        unawaited(_handlePlay(request));
        break;
      case 'Playstate':
        final data = message.tryDecodeData();
        if (data == null) {
          return;
        }
        unawaited(_handlePlaystate(data));
        break;
      default:
        _log.fine('Ignoring message ${message.type}');
    }
  }

  Future<void> _handlePlay(PlayRequest request) async {
    try {
      await mpv.stop();
      await _lastPlaybackClose;
    } catch (error, stackTrace) {
      _log.warning(
        'Failed to stop active playback before starting new.',
        error,
        stackTrace,
      );
    }

    final itemId = request.chooseItemId();
    _log.info('Starting playback for item $itemId');
    Map<String, dynamic> item;
    try {
      item = await api.getItem(itemId);
    } catch (error, stackTrace) {
      _log.severe(
        'Failed to fetch item metadata for $itemId',
        error,
        stackTrace,
      );
      return;
    }

    final mediaSource = _selectMediaSource(item, request.mediaSourceId);
    final mediaSourceId = mediaSource['Id']?.toString() ?? itemId;
    final playSessionId = request.playSessionId ?? _uuid.v4();
    final streamUrl = api.buildStreamUrl(
      itemId,
      mediaSourceId: mediaSourceId,
      startPosition: request.startPosition,
      audioStreamIndex: request.audioStreamIndex?.toString(),
      subtitleStreamIndex: request.subtitleStreamIndex?.toString(),
    );

    _currentItemId = itemId;
    _currentMediaSourceId = mediaSourceId;
    _currentPlaySessionId = playSessionId;
    _lastKnownPosition = request.startPosition ?? Duration.zero;

    try {
      await mpv.play(
        streamUrl,
        title: item['Name']?.toString(),
        startPosition: request.startPosition,
        audioStreamIndex: request.audioStreamIndex,
        subtitleStreamIndex: request.subtitleStreamIndex,
      );
    } catch (error, stackTrace) {
      _log.severe('Failed to launch mpv', error, stackTrace);
      return;
    }

    try {
      await api.reportPlaybackStart(
        PlaybackStartRequest(
          itemId: itemId,
          mediaSourceId: mediaSourceId,
          playSessionId: playSessionId,
          position: request.startPosition ?? Duration.zero,
          isPaused: false,
          canSeek: true,
        ),
      );
    } catch (error, stackTrace) {
      _log.warning('Failed to report playback start', error, stackTrace);
    }

    _startProgressTimer(immediate: true);
  }

  Future<void> _handlePlaystate(Map<String, dynamic> payload) async {
    if (!mpv.isRunning) {
      return;
    }
    final command = payload['Command']?.toString();
    switch (command) {
      case 'Pause':
        await mpv.setPause(true);
        break;
      case 'Unpause':
      case 'Play':
        await mpv.setPause(false);
        break;
      case 'Stop':
        await mpv.stop();
        break;
      case 'Seek':
        final position = durationFromTicks(payload['SeekPositionTicks']);
        if (position != null) {
          await mpv.seek(position);
          _lastKnownPosition = position;
          await _reportProgress(forcePosition: position);
        }
        break;
      default:
        _log.fine('Unhandled playstate command: $command');
    }
  }

  Future<void> _handleMpvExit(int exitCode) async {
    _log.info('mpv exited with code $exitCode');
    _progressTimer?.cancel();
    _progressTimer = null;
    if (_currentItemId == null ||
        _currentMediaSourceId == null ||
        _currentPlaySessionId == null) {
      _resetPlaybackContext();
      return;
    }
    try {
      await api.reportPlaybackStopped(
        PlaybackStopRequest(
          itemId: _currentItemId!,
          mediaSourceId: _currentMediaSourceId!,
          playSessionId: _currentPlaySessionId!,
          position: _lastKnownPosition,
        ),
      );
    } catch (error, stackTrace) {
      _log.warning('Failed to report playback stop', error, stackTrace);
    } finally {
      _resetPlaybackContext();
    }
  }

  void _startProgressTimer({bool immediate = false}) {
    _progressTimer?.cancel();
    if (immediate) {
      unawaited(_reportProgress());
    }
    _progressTimer = Timer.periodic(
      config.playbackProgressInterval,
      (_) => unawaited(_reportProgress()),
    );
  }

  Future<void> _reportProgress({Duration? forcePosition}) async {
    if (!mpv.isRunning) {
      return;
    }
    if (_currentItemId == null ||
        _currentMediaSourceId == null ||
        _currentPlaySessionId == null) {
      return;
    }
    Duration? position = forcePosition;
    if (position == null) {
      try {
        position = await mpv.queryPosition();
      } catch (error, stackTrace) {
        _log.fine('Failed to query mpv position', error, stackTrace);
        return;
      }
    }
    if (position == null) {
      return;
    }
    _lastKnownPosition = position;
    try {
      await api.reportPlaybackProgress(
        PlaybackProgressRequest(
          itemId: _currentItemId!,
          mediaSourceId: _currentMediaSourceId!,
          playSessionId: _currentPlaySessionId!,
          position: position,
        ),
      );
    } catch (error, stackTrace) {
      _log.fine('Failed to report playback progress', error, stackTrace);
    }
  }

  void _resetPlaybackContext() {
    _currentItemId = null;
    _currentMediaSourceId = null;
    _currentPlaySessionId = null;
    _lastKnownPosition = Duration.zero;
  }

  Map<String, dynamic> _selectMediaSource(
    Map<String, dynamic> item,
    String? requestedId,
  ) {
    final mediaSources = item['MediaSources'];
    if (mediaSources is Iterable) {
      if (requestedId != null) {
        for (final source in mediaSources) {
          if (source is Map && source['Id']?.toString() == requestedId) {
            return Map<String, dynamic>.from(source);
          }
        }
      }
      for (final source in mediaSources) {
        if (source is Map) {
          return Map<String, dynamic>.from(source);
        }
      }
    }
    return item;
  }
}

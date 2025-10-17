import 'dart:async';
import 'dart:io';

import 'package:jell_mpv_dart/src/config.dart';
import 'package:jell_mpv_dart/src/jellyfin_api.dart';
import 'package:jell_mpv_dart/src/jellyfin_websocket.dart';
import 'package:jell_mpv_dart/src/models.dart';
import 'package:jell_mpv_dart/src/mpv_controller.dart';
import 'package:talker/talker.dart';
import 'package:uuid/uuid.dart';

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
  final _log = Talker(
    logger: TalkerLogger(
      settings: TalkerLoggerSettings(defaultTitle: 'JellyfinMpvShim'),
    ),
  );
  final _uuid = const Uuid();

  StreamSubscription<JellyfinSocketMessage>? _wsSubscription;
  StreamSubscription<int>? _mpvSubscription;
  StreamSubscription<MpvPropertyChange>? _mpvPropertySubscription;
  Timer? _progressTimer;
  final Completer<void> _done = Completer<void>();
  Future<void> _lastPlaybackClose = Future<void>.value();

  String? _currentItemId;
  String? _currentMediaSourceId;
  String? _currentPlaySessionId;
  Duration _lastKnownPosition = Duration.zero;
  DateTime _lastProgressReport = DateTime.now();

  // Playlist/queue management
  List<String> _playlist = [];
  int _currentPlaylistIndex = 0;
  bool _isManualTrackChange = false;

  // Track the current media streams for index mapping
  List<Map<String, dynamic>> _currentMediaStreams = [];

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
        _log.critical('Authentication failed', error, stackTrace);
        rethrow;
      }
    }

    _mpvSubscription = mpv.onExit.listen((code) async {
      final future = _handleMpvExit(code);
      _lastPlaybackClose = future;
      await future.catchError((Object error, StackTrace stackTrace) {
        _log.warning('Error during mpv exit handling', error, stackTrace);
      });
    });

    // Listen for property changes from mpv for immediate updates
    _mpvPropertySubscription = mpv.onPropertyChange.listen(
      _handlePropertyChange,
    );

    await websocket.start(token: sessionToken);
    _wsSubscription = websocket.messages.listen(
      _handleSocketMessage,
      onError: (Object error, StackTrace stackTrace) {
        _log.critical('WebSocket stream error', error, stackTrace);
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
    await _mpvPropertySubscription?.cancel();
    await websocket.close();
    await mpv.stop();
    await _lastPlaybackClose;
    await api.close();
    await _mpvSubscription?.cancel();
    if (!_done.isCompleted) {
      _done.complete();
    }
    exit(0);
  }

  void _handlePropertyChange(MpvPropertyChange change) {
    // Debounce rapid property changes - only report if > 2 seconds
    // since last report
    // This prevents flooding Jellyfin with updates while still
    // being responsive
    final now = DateTime.now();
    final timeSinceLastReport = now.difference(_lastProgressReport);

    if (timeSinceLastReport.inSeconds >= 2) {
      _log.debug('Property changed: ${change.property} = ${change.value}');
      _lastProgressReport = now;
      unawaited(_reportProgress());
    }
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
      case 'Playstate':
        final data = message.tryDecodeData();
        if (data == null) {
          _log.warning('Playstate message missing payload. ${message.rawData}');
          return;
        }
        _log.debug('Playstate command: ${data['Command']}, payload: $data');
        unawaited(_handlePlaystate(data));
      case 'GeneralCommand':
        final data = message.tryDecodeData();
        if (data != null) {
          _log.info('GeneralCommand received: ${data['Name']}, payload: $data');
          unawaited(_handleGeneralCommand(data));
        }
      default:
        _log.verbose('Ignoring message ${message.type}');
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

    // Store the full playlist
    _playlist = request.itemIds;
    _currentPlaylistIndex = request.startIndex ?? 0;

    final itemId = request.chooseItemId();
    _log.info(
      'Starting playback for item $itemId (${_currentPlaylistIndex + 1}/${_playlist.length} in queue)',
    );
    Map<String, dynamic> item;
    try {
      item = await api.getItem(itemId);
    } catch (error, stackTrace) {
      _log.debug(
        'Failed to fetch item metadata for $itemId',
        error,
        stackTrace,
      );
      return;
    }

    final mediaSource = _selectMediaSource(item, request.mediaSourceId);
    final mediaSourceId = mediaSource['Id']?.toString() ?? itemId;
    final playSessionId = request.playSessionId ?? _uuid.v4();

    // Store media streams for index mapping
    final mediaStreamsRaw = mediaSource['MediaStreams'];
    if (mediaStreamsRaw is List) {
      _currentMediaStreams = mediaStreamsRaw
          .whereType<Map<String, dynamic>>()
          .toList();

      // Log all media streams for debugging
      _log.info('Media has ${_currentMediaStreams.length} streams:');
      for (var i = 0; i < _currentMediaStreams.length; i++) {
        final stream = _currentMediaStreams[i];
        final type = stream['Type'];
        final index = stream['Index'];
        final lang = stream['Language'] ?? '';
        final title = stream['DisplayTitle'] ?? '';
        final codec = stream['Codec'] ?? '';
        _log.info(
          '  [$i] Type=$type, Index=$index'
          ' Lang=$lang, Codec=$codec, Title=$title',
        );
      }
    } else {
      _currentMediaStreams = [];
    }

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

    // Map subtitle stream index from Jellyfin to mpv
    int? mpvSubtitleStreamIndex;
    if (request.subtitleStreamIndex != null) {
      mpvSubtitleStreamIndex = _mapJellyfinSubtitleIndexToMpvSid(
        request.subtitleStreamIndex!,
      );
      if (mpvSubtitleStreamIndex != null) {
        _log.info(
          'Initial playback: mapped Jellyfin subtitle index '
          '${request.subtitleStreamIndex} to mpv sid=$mpvSubtitleStreamIndex',
        );
      }
    }

    try {
      await mpv.play(
        streamUrl,
        title: item['Name']?.toString(),
        startPosition: request.startPosition,
        audioStreamIndex: request.audioStreamIndex,
        subtitleStreamIndex: mpvSubtitleStreamIndex,
      );
    } catch (error, stackTrace) {
      _log.debug('Failed to launch mpv', error, stackTrace);
      return;
    }

    // Build the queue for Jellyfin web UI
    List<QueueItem>? nowPlayingQueue;
    if (_playlist.isNotEmpty) {
      nowPlayingQueue = _playlist
          .map((itemId) => QueueItem(id: itemId))
          .toList();
    }

    try {
      await api.reportPlaybackStart(
        PlaybackStartRequest(
          itemId: itemId,
          mediaSourceId: mediaSourceId,
          playSessionId: playSessionId,
          position: request.startPosition ?? Duration.zero,
          nowPlayingQueue: nowPlayingQueue,
        ),
      );
    } catch (error, stackTrace) {
      _log.warning('Failed to report playback start', error, stackTrace);
    }

    _startProgressTimer(immediate: true);
  }

  Future<void> _handlePlaystate(Map<String, dynamic> payload) async {
    final command = payload['Command']?.toString();
    _log.info('Playstate command: $command (mpv running: ${mpv.isRunning})');

    // If mpv is not running and we get Play/Unpause/Seek, we need to resume playback
    if (!mpv.isRunning &&
        (command == 'Play' || command == 'Unpause' || command == 'Seek')) {
      // Resume the last known item
      if (_currentItemId != null && _playlist.isNotEmpty) {
        _log.info('Resuming playback - mpv was closed');
        await _handlePlay(
          PlayRequest(
            itemIds: _playlist,
            playSessionId: _currentPlaySessionId,
            startIndex: _currentPlaylistIndex,
            startPosition: command == 'Seek'
                ? durationFromTicks(payload['SeekPositionTicks'])
                : _lastKnownPosition,
          ),
        );
        return;
      }
    }

    // For all other commands, mpv must be running
    if (!mpv.isRunning) {
      _log.warning('Ignoring command $command - mpv is not running');
      return;
    }

    switch (command) {
      case 'PlayPause':
        // Toggle pause state
        final isPaused = await mpv.queryPaused();
        await mpv.setPause(!isPaused);
        await _reportProgress();
      case 'Pause':
        await mpv.setPause(true);
        await _reportProgress();
      case 'Unpause':
      case 'Play':
        await mpv.setPause(false);
        await _reportProgress();
      case 'Stop':
        await mpv.stop();
      case 'Seek':
        final position = durationFromTicks(payload['SeekPositionTicks']);
        _log.info('Seek to position: $position');
        if (position != null) {
          await mpv.seek(position);
          _lastKnownPosition = position;
          await _reportProgress(forcePosition: position);
        }
      case 'SetVolume':
        final volume = payload['Volume'];
        _log.info('SetVolume to: $volume');
        if (volume is num) {
          await mpv.setVolume(volume.round());
          await _reportProgress();
        }
      case 'VolumeUp':
        await mpv.adjustVolume(5);
        await _reportProgress();
      case 'VolumeDown':
        await mpv.adjustVolume(-5);
        await _reportProgress();
      case 'Mute':
        await mpv.setMute(true);
        await _reportProgress();
      case 'Unmute':
        await mpv.setMute(false);
        await _reportProgress();
      case 'ToggleMute':
        final currentlyMuted = await mpv.queryMuted();
        await mpv.setMute(!currentlyMuted);
        await _reportProgress();
      case 'SetAudioStreamIndex':
        final index = payload['Index'];
        if (index is num) {
          await mpv.setAudioTrack(index.round());
        }
      case 'SetSubtitleStreamIndex':
        final index = payload['Index'];
        if (index is num) {
          final jellyfinIndex = index.round();
          _log.info(
            'PlayState SetSubtitleStreamIndex to: $jellyfinIndex'
            ' (Jellyfin stream index)',
          );

          // Map Jellyfin's absolute stream index to mpv's
          // subtitle track ID (sid)
          final mpvSid = _mapJellyfinSubtitleIndexToMpvSid(jellyfinIndex);
          if (mpvSid != null) {
            _log.info(
              'Mapped Jellyfin subtitle index $jellyfinIndex'
              ' to mpv sid=$mpvSid',
            );
            await mpv.setSubtitleTrack(mpvSid);
          } else {
            _log.warning(
              'Failed to map Jellyfin subtitle index $jellyfinIndex to mpv sid',
            );
          }
        }
      case 'NextTrack':
      case 'PlayNext':
        await _playNext();
      case 'PreviousTrack':
        await _playPrevious();
      default:
        _log.debug('Unhandled playstate command: $command');
    }
  }

  Future<void> _handleGeneralCommand(Map<String, dynamic> payload) async {
    final commandName = payload['Name']?.toString();
    final arguments = payload['Arguments'] as Map<String, dynamic>?;

    if (!mpv.isRunning) {
      _log.warning('Ignoring GeneralCommand $commandName - mpv is not running');
      return;
    }

    switch (commandName) {
      case 'SetVolume':
        final volume = arguments?['Volume'];
        _log.info(
          'GeneralCommand SetVolume to: $volume (${volume.runtimeType})',
        );
        final volumeInt = volume is num
            ? volume.round()
            : (volume is String ? int.tryParse(volume) : null);
        if (volumeInt != null) {
          try {
            _log.info('Calling mpv.setVolume($volumeInt)');
            await mpv.setVolume(volumeInt);
            _log.info('Volume set successfully, reporting progress');
            await _reportProgress();
          } catch (error, stackTrace) {
            _log.warning('Failed to set volume', error, stackTrace);
          }
        } else {
          _log.warning('Could not parse volume value: $volume');
        }
      case 'SetAudioStreamIndex':
        final index = arguments?['Index'];
        final indexInt = index is num
            ? index.round()
            : (index is String ? int.tryParse(index) : null);
        if (indexInt != null) {
          _log.info(
            'GeneralCommand SetAudioStreamIndex '
            'to: $indexInt (raw from Jellyfin)',
          );
          await mpv.setAudioTrack(indexInt);
          await _reportProgress();
        }
      case 'SetSubtitleStreamIndex':
        final index = arguments?['Index'];
        final indexInt = index is num
            ? index.round()
            : (index is String ? int.tryParse(index) : null);
        if (indexInt != null) {
          _log.info(
            'GeneralCommand SetSubtitleStreamIndex '
            'to: $indexInt (Jellyfin stream index)',
          );

          // Map Jellyfin's absolute stream index
          // to mpv's subtitle track ID (sid)
          final mpvSid = _mapJellyfinSubtitleIndexToMpvSid(indexInt);
          if (mpvSid != null) {
            _log.info(
              'Mapped Jellyfin subtitle index $indexInt to mpv sid=$mpvSid',
            );
            await mpv.setSubtitleTrack(mpvSid);
          } else {
            _log.warning(
              'Failed to map Jellyfin subtitle index $indexInt to mpv sid',
            );
          }
          await _reportProgress();
        }
      case 'Seek':
        // Seek command in GeneralCommand has position in ticks
        final positionTicks = arguments?['SeekPositionTicks'];
        if (positionTicks != null) {
          final position = durationFromTicks(positionTicks);
          if (position != null) {
            _log.info('GeneralCommand Seek to: $position');
            await mpv.seek(position);
            _lastKnownPosition = position;
            await _reportProgress(forcePosition: position);
          }
        }
      case 'Mute':
        _log.info('GeneralCommand Mute');
        await mpv.setMute(true);
        await _reportProgress();
      case 'Unmute':
        _log.info('GeneralCommand Unmute');
        await mpv.setMute(false);
        await _reportProgress();
      case 'ToggleMute':
        _log.info('GeneralCommand ToggleMute');
        final currentlyMuted = await mpv.queryMuted();
        await mpv.setMute(!currentlyMuted);
        await _reportProgress();
      case 'ToggleFullscreen':
        _log.info('GeneralCommand ToggleFullscreen');
        await mpv.toggleFullscreen();
      case 'SetFullscreen':
        final fullscreen = arguments?['Fullscreen'];
        if (fullscreen is bool) {
          _log.info('GeneralCommand SetFullscreen to: $fullscreen');
          await mpv.setFullscreen(fullscreen);
        }
      default:
        _log.debug('Unhandled general command: $commandName');
    }
  }

  Future<void> _playNext() async {
    if (_playlist.isEmpty) {
      _log.info('PlayNext: No playlist, stopping');
      _isManualTrackChange = true;
      await mpv.stop();
      return;
    }

    _currentPlaylistIndex++;
    if (_currentPlaylistIndex >= _playlist.length) {
      _log.info('PlayNext: End of playlist, stopping');
      _isManualTrackChange = true;
      await mpv.stop();
      return;
    }

    final nextItemId = _playlist[_currentPlaylistIndex];
    _log.info(
      'PlayNext: Playing item $nextItemId (${_currentPlaylistIndex + 1}/${_playlist.length})',
    );

    // Set flag to prevent auto-play from triggering
    _isManualTrackChange = true;

    // Create a synthetic play request for the next item
    await _handlePlay(
      PlayRequest(
        itemIds: _playlist,
        playSessionId: _currentPlaySessionId,
        startIndex: _currentPlaylistIndex,
      ),
    );
  }

  Future<void> _playPrevious() async {
    if (_playlist.isEmpty) {
      _log.info('PlayPrevious: No playlist, stopping');
      _isManualTrackChange = true;
      await mpv.stop();
      return;
    }

    _currentPlaylistIndex--;
    if (_currentPlaylistIndex < 0) {
      _log.info('PlayPrevious: At start of playlist, restarting first track');
      _currentPlaylistIndex = 0;
    }

    final prevItemId = _playlist[_currentPlaylistIndex];
    _log.info(
      'PlayPrevious: Playing item $prevItemId (${_currentPlaylistIndex + 1}/${_playlist.length})',
    );

    // Set flag to prevent auto-play from triggering
    _isManualTrackChange = true;

    // Create a synthetic play request for the previous item
    await _handlePlay(
      PlayRequest(
        itemIds: _playlist,
        playSessionId: _currentPlaySessionId,
        startIndex: _currentPlaylistIndex,
      ),
    );
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

    // If exit code is 0 (normal exit) and we have more items in the playlist,
    // automatically play the next one (but only
    // if it wasn't a manual track change)
    if (exitCode == 0 &&
        !_isManualTrackChange &&
        _currentPlaylistIndex < _playlist.length - 1) {
      _log.info('Track finished naturally, auto-playing next track');
      await _playNext();
    } else if (_isManualTrackChange) {
      _log.info('Manual track change, not auto-playing');
      _isManualTrackChange = false; // Reset flag
    } else if (_playlist.isNotEmpty) {
      _log.info('End of playlist reached');
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

    // Query current state from mpv
    var position = forcePosition;
    var isPaused = false;
    var isMuted = false;
    int? volumeLevel;
    int? audioStreamIndex;
    int? subtitleStreamIndex;

    try {
      position ??= await mpv.queryPosition();
      isPaused = await mpv.queryPaused();
      isMuted = await mpv.queryMuted();
      volumeLevel = await mpv.queryVolume();
      audioStreamIndex = await mpv.queryAudioTrack();

      // Query mpv's subtitle track ID and map it
      // back to Jellyfin's MediaStreams array index
      final mpvSid = await mpv.querySubtitleTrack();
      if (mpvSid != null) {
        subtitleStreamIndex = _mapMpvSidToJellyfinStreamIndex(mpvSid);
        if (subtitleStreamIndex == null) {
          _log.debug(
            'Could not map mpv sid=$mpvSid back to Jellyfin MediaStreams index'
            ' using mpv sid directly',
          );
          subtitleStreamIndex = mpvSid;
        }
      }
    } catch (error, stackTrace) {
      _log.debug('Failed to query mpv state', error, stackTrace);
      return;
    }

    if (position == null) {
      return;
    }
    _lastKnownPosition = position;

    // Build the queue for Jellyfin web UI
    List<QueueItem>? nowPlayingQueue;
    if (_playlist.isNotEmpty) {
      nowPlayingQueue = _playlist
          .map((itemId) => QueueItem(id: itemId))
          .toList();
    }

    try {
      await api.reportPlaybackProgress(
        PlaybackProgressRequest(
          itemId: _currentItemId!,
          mediaSourceId: _currentMediaSourceId!,
          playSessionId: _currentPlaySessionId!,
          position: position,
          isPaused: isPaused,
          isMuted: isMuted,
          volumeLevel: volumeLevel,
          audioStreamIndex: audioStreamIndex,
          subtitleStreamIndex: subtitleStreamIndex,
          nowPlayingQueue: nowPlayingQueue,
        ),
      );
    } catch (error, stackTrace) {
      _log.debug('Failed to report playback progress', error, stackTrace);
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

  /// Maps Jellyfin's subtitle stream index to mpv's subtitle track ID (sid).
  ///
  /// Jellyfin sends indices referring to positions in the MediaStreams array.
  /// mpv uses sequential subtitle track IDs (sid=1, 2, 3...)
  /// for subtitle streams only.
  /// We count how many subtitle streams appear before the selected one
  /// to get the mpv sid.
  int? _mapJellyfinSubtitleIndexToMpvSid(int jellyfinStreamIndex) {
    if (_currentMediaStreams.isEmpty) {
      _log.warning(
        'No media streams available for mapping subtitle'
        ' index $jellyfinStreamIndex',
      );
      return null;
    }

    if (jellyfinStreamIndex < 0 ||
        jellyfinStreamIndex >= _currentMediaStreams.length) {
      _log.warning(
        'Jellyfin stream index $jellyfinStreamIndex is out of bounds'
        ' (MediaStreams length=${_currentMediaStreams.length})',
      );
      return null;
    }

    final stream = _currentMediaStreams[jellyfinStreamIndex];
    final type = stream['Type']?.toString();

    if (type != 'Subtitle') {
      _log.warning(
        'Jellyfin MediaStreams[$jellyfinStreamIndex] is not'
        ' a subtitle (type=$type)',
      );
      return null;
    }

    // Count how many subtitle streams come before this one in the array
    // That count + 1 = mpv's sid (since mpv starts counting at 1)
    var mpvSid = 1;
    for (var i = 0; i < jellyfinStreamIndex; i++) {
      if (_currentMediaStreams[i]['Type']?.toString() == 'Subtitle') {
        mpvSid++;
      }
    }

    final lang = stream['Language']?.toString() ?? 'unknown';
    final displayTitle = stream['DisplayTitle']?.toString() ?? '';
    final jellyfinIndex = stream['Index'];
    _log.info(
      'Mapped Jellyfin MediaStreams[$jellyfinStreamIndex]'
      ' (JF Index=$jellyfinIndex, $lang - $displayTitle) to mpv sid=$mpvSid',
    );

    return mpvSid;
  }

  /// Maps mpv's subtitle track ID (sid) back to Jellyfin's
  /// MediaStreams array index.
  ///
  /// This is the reverse of _mapJellyfinSubtitleIndexToMpvSid and is used
  /// when reporting playback progress to Jellyfin. We find the Nth
  ///  subtitle stream
  /// in the array (where N = mpvSid) and return its array position.
  int? _mapMpvSidToJellyfinStreamIndex(int mpvSid) {
    if (_currentMediaStreams.isEmpty) {
      return null;
    }

    var currentSubtitleCount = 0;
    for (var i = 0; i < _currentMediaStreams.length; i++) {
      final stream = _currentMediaStreams[i];
      final type = stream['Type']?.toString();

      if (type == 'Subtitle') {
        currentSubtitleCount++;
        if (currentSubtitleCount == mpvSid) {
          final lang = stream['Language']?.toString() ?? 'unknown';
          _log.debug(
            'Reverse subtitle mapping: mpv sid=$mpvSid ->'
            ' Jellyfin MediaStreams[$i] ($lang)',
          );
          return i;
        }
      }
    }

    _log.debug('Could not find subtitle #$mpvSid in MediaStreams');
    return null;
  }
}

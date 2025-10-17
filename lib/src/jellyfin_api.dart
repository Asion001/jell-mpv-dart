import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:jell_mpv_dart/src/config.dart';
import 'package:jell_mpv_dart/src/models.dart';
import 'package:talker/talker.dart';

/// Lightweight Jellyfin REST client focused on playback coordination.
class JellyfinApi {
  JellyfinApi(this.config, {http.Client? httpClient})
    : client = httpClient ?? http.Client();

  final JellyfinConfig config;
  final http.Client client;
  final Talker _log = Talker(
    logger: TalkerLogger(
      settings: TalkerLoggerSettings(defaultTitle: 'JellyfinApi'),
    ),
  );
  String? _sessionToken;

  /// Get authentication headers including session token if authenticated.
  Map<String, String> get authHeaders => _getHeaders();

  /// Authenticate with username/password and get session token.
  /// Returns the access token to use for subsequent requests.
  Future<String> authenticateByName(String username, String password) async {
    final response = await client.post(
      config.buildUri('Users/AuthenticateByName'),
      headers: {...config.authHeaders, 'Content-Type': 'application/json'},
      body: jsonEncode({'Username': username, 'Pw': password}),
    );
    _ensureSuccess(response, 'POST Users/AuthenticateByName');

    final result = jsonDecode(response.body) as Map<String, dynamic>;
    final token = result['AccessToken'] as String?;
    if (token == null) {
      throw JellyfinApiException(
        'Authentication succeeded but no token returned',
      );
    }

    _sessionToken = token;
    return token;
  }

  Future<Map<String, dynamic>> getItem(String itemId) async {
    final response = await client.get(
      config.buildUri(
        'Items/$itemId',
        queryParameters: {'fields': 'MediaStreams'},
      ),
      headers: _getHeaders(),
    );
    _ensureSuccess(response, 'GET Items/$itemId');
    final decoded = jsonDecode(response.body);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    throw FormatException('Unexpected payload for item $itemId');
  }

  Map<String, String> _getHeaders() {
    final headers = <String, String>{...config.authHeaders};
    if (_sessionToken != null) {
      headers['X-Emby-Token'] = _sessionToken!;
    }
    return headers;
  }

  /// Produces a direct stream URL that mpv can consume without custom headers.
  Uri buildStreamUrl(
    String itemId, {
    String? mediaSourceId,
    Duration? startPosition,
    String? audioStreamIndex,
    String? subtitleStreamIndex,
  }) {
    final token = _sessionToken ?? config.accessToken;
    final query = <String, dynamic>{
      'api_key': token,
      'mediaSourceId': ?mediaSourceId,
      if (startPosition != null)
        'startTimeTicks': durationToTicks(startPosition),
      'audioStreamIndex': ?audioStreamIndex,
      'subtitleStreamIndex': ?subtitleStreamIndex,
    };
    return config.buildUri('Items/$itemId/Download', queryParameters: query);
  }

  Future<void> reportPlaybackStart(PlaybackStartRequest req) async {
    final response = await client.post(
      config.buildUri('Sessions/Playing'),
      headers: {..._getHeaders(), 'Content-Type': 'application/json'},
      body: jsonEncode(req.toJellyfinJson()),
    );
    _ensureSuccess(response, 'POST Sessions/Playing');
  }

  Future<void> reportPlaybackProgress(PlaybackProgressRequest req) async {
    final response = await client.post(
      config.buildUri('Sessions/Playing/Progress'),
      headers: {..._getHeaders(), 'Content-Type': 'application/json'},
      body: jsonEncode(req.toJellyfinJson()),
    );
    _ensureSuccess(response, 'POST Sessions/Playing/Progress');
  }

  Future<void> reportPlaybackStopped(PlaybackStopRequest req) async {
    final response = await client.post(
      config.buildUri('Sessions/Playing/Stopped'),
      headers: {..._getHeaders(), 'Content-Type': 'application/json'},
      body: jsonEncode(req.toJellyfinJson()),
    );
    _ensureSuccess(response, 'POST Sessions/Playing/Stopped');
  }

  Map<String, dynamic> _getCapabilities() {
    return {
      'PlayableMediaTypes': ['Video', 'Audio'],
      'SupportedCommands': [
        'Play',
        'PlayState',
        'PlayNext',
        'SetAudioStreamIndex',
        'SetSubtitleStreamIndex',
        'SetVolume',
        'Mute',
        'Unmute',
        'ToggleMute',
        'ToggleFullscreen',
        'VolumeUp',
        'VolumeDown',
      ],
      'SupportsMediaControl': true,
      'SupportsPersistentIdentifier': true,
    };
  }

  Future<void> announceCapabilities() async {
    final capabilities = _getCapabilities();
    final body = jsonEncode(capabilities);
    _log.debug('Announcing capabilities: $body');

    final response = await client.post(
      config.buildUri('Sessions/Capabilities/Full'),
      headers: {..._getHeaders(), 'Content-Type': 'application/json'},
      body: body,
    );

    _log.debug(
      'Capabilities response: ${response.statusCode}'
      'Response body: ${response.body}',
    );

    _ensureSuccess(response, 'POST Sessions/Capabilities/Full');
  }

  Future<void> sendKeepAlive() async {
    await client.post(
      config.buildUri('Sessions/Capabilities/Full'),
      headers: {..._getHeaders(), 'Content-Type': 'application/json'},
      body: jsonEncode(_getCapabilities()),
    );
  }

  Future<void> close() async {
    client.close();
  }

  void _ensureSuccess(http.Response response, String context) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw JellyfinApiException(
        '$context failed with ${response.statusCode}: ${response.body}',
      );
    }
  }
}

class JellyfinApiException implements Exception {
  JellyfinApiException(this.message);

  final String message;

  @override
  String toString() => 'JellyfinApiException: $message';
}

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'config.dart';
import 'models.dart';

/// Lightweight Jellyfin REST client focused on playback coordination.
class JellyfinApi {
  JellyfinApi(this.config, {http.Client? httpClient})
    : client = httpClient ?? http.Client();

  final JellyfinConfig config;
  final http.Client client;
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
      config.buildUri('Items/$itemId'),
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
      if (mediaSourceId != null) 'mediaSourceId': mediaSourceId,
      if (startPosition != null)
        'startTimeTicks': durationToTicks(startPosition),
      if (audioStreamIndex != null) 'audioStreamIndex': audioStreamIndex,
      if (subtitleStreamIndex != null)
        'subtitleStreamIndex': subtitleStreamIndex,
    };
    return config.buildUri('Items/$itemId/Download', queryParameters: query);
  }

  Future<void> reportPlaybackStart(PlaybackStartRequest req) async {
    final response = await client.post(
      config.buildUri('Sessions/Playing'),
      headers: {..._getHeaders(), 'Content-Type': 'application/json'},
      body: jsonEncode(req.toJson()),
    );
    _ensureSuccess(response, 'POST Sessions/Playing');
  }

  Future<void> reportPlaybackProgress(PlaybackProgressRequest req) async {
    final response = await client.post(
      config.buildUri('Sessions/Playing/Progress'),
      headers: {..._getHeaders(), 'Content-Type': 'application/json'},
      body: jsonEncode(req.toJson()),
    );
    _ensureSuccess(response, 'POST Sessions/Playing/Progress');
  }

  Future<void> reportPlaybackStopped(PlaybackStopRequest req) async {
    final response = await client.post(
      config.buildUri('Sessions/Playing/Stopped'),
      headers: {..._getHeaders(), 'Content-Type': 'application/json'},
      body: jsonEncode(req.toJson()),
    );
    _ensureSuccess(response, 'POST Sessions/Playing/Stopped');
  }

  Future<void> announceCapabilities() async {
    final capabilities = {
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
        'VolumeUp',
        'VolumeDown',
      ],
      'SupportsMediaControl': true,
      'SupportsPersistentIdentifier': true,
    };

    final body = jsonEncode(capabilities);
    print('DEBUG: Announcing capabilities: $body');

    final response = await client.post(
      config.buildUri('Sessions/Capabilities/Full'),
      headers: {..._getHeaders(), 'Content-Type': 'application/json'},
      body: body,
    );

    print('DEBUG: Capabilities response: ${response.statusCode}');
    print('DEBUG: Response body: ${response.body}');

    _ensureSuccess(response, 'POST Sessions/Capabilities/Full');
  }

  Future<void> sendKeepAlive() async {
    await client.post(
      config.buildUri('Sessions/Capabilities/Full'),
      headers: {..._getHeaders(), 'Content-Type': 'application/json'},
      body: jsonEncode({
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
          'VolumeUp',
          'VolumeDown',
        ],
        'SupportsMediaControl': true,
        'SupportsPersistentIdentifier': true,
      }),
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

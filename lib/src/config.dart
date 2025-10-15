import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// Strongly typed configuration for the Jellyfin → mpv shim.
class JellyfinConfig {
  JellyfinConfig({
    required this.server,
    required this.userId,
    required this.deviceId,
    required this.deviceName,
    this.accessToken,
    this.username,
    this.password,
    this.clientName = 'Jellyfin MPV Shim',
    this.clientVersion = '0.1.0',
    String? mpvExecutable,
    List<String>? mpvArgs,
    Duration? keepAliveInterval,
    Duration? playbackProgressInterval,
    this.startupReconnectBackoff = const Duration(seconds: 5),
  }) : mpvExecutable = mpvExecutable ?? 'mpv',
       mpvArgs = List.unmodifiable(mpvArgs ?? const <String>[]),
       keepAliveInterval = keepAliveInterval ?? const Duration(seconds: 15),
       playbackProgressInterval =
           playbackProgressInterval ?? const Duration(seconds: 30) {
    // Validate that either accessToken or (username + password) is provided
    if (accessToken == null && (username == null || password == null)) {
      throw ArgumentError(
        'Either accessToken or both username and password must be provided',
      );
    }
  }

  /// Base Jellyfin server URI (http or https).
  final Uri server;

  /// Jellyfin UserId that owns the session.
  final String userId;

  /// Unique identifier for this device as seen by Jellyfin.
  final String deviceId;

  /// Human friendly name for the device.
  final String deviceName;

  /// Access token with play permissions (if using token auth).
  final String? accessToken;

  /// Username for password authentication (alternative to accessToken).
  final String? username;

  /// Password for password authentication (alternative to accessToken).
  final String? password;

  /// Client name included in Jellyfin auth headers.
  final String clientName;

  /// Client version included in Jellyfin auth headers.
  final String clientVersion;

  /// mpv executable path/binary name.
  final String mpvExecutable;

  /// Extra mpv arguments defined by the user.
  final List<String> mpvArgs;

  /// Interval for WebSocket keep-alives.
  final Duration keepAliveInterval;

  /// Interval to report playback progress to Jellyfin.
  final Duration playbackProgressInterval;

  /// Base reconnect backoff for startup connection loops.
  final Duration startupReconnectBackoff;

  static JellyfinConfig fromMap(Map<String, dynamic> map) {
    final server = _parseServer(map['server']);
    return JellyfinConfig(
      server: server,
      userId: _requireString(map, 'userId'),
      deviceId: _requireString(map, 'deviceId'),
      deviceName: _requireString(map, 'deviceName'),
      accessToken: map['accessToken']?.toString(),
      username: map['username']?.toString(),
      password: map['password']?.toString(),
      clientName: map['clientName']?.toString() ?? 'Jellyfin MPV Shim',
      clientVersion: map['clientVersion']?.toString() ?? '0.1.0',
      mpvExecutable: map['mpvExecutable']?.toString(),
      mpvArgs: _parseStringList(map['mpvArgs']),
      keepAliveInterval: _parseDuration(
        map['keepAliveInterval'],
        defaultSeconds: 15,
      ),
      playbackProgressInterval: _parseDuration(
        map['playbackProgressInterval'],
        defaultSeconds: 30,
      ),
      startupReconnectBackoff: _parseDuration(
        map['startupReconnectBackoff'],
        defaultSeconds: 5,
      ),
    );
  }

  static Future<JellyfinConfig> fromYamlFile(File file) async {
    final contents = await file.readAsString();
    final yaml = loadYaml(contents);
    if (yaml is! YamlMap) {
      throw FormatException('Invalid YAML configuration.');
    }
    return fromMap(_yamlToMap(yaml));
  }

  JellyfinConfig copyWith({
    Uri? server,
    String? userId,
    String? deviceId,
    String? deviceName,
    String? accessToken,
    String? username,
    String? password,
    String? clientName,
    String? clientVersion,
    String? mpvExecutable,
    List<String>? mpvArgs,
    Duration? keepAliveInterval,
    Duration? playbackProgressInterval,
    Duration? startupReconnectBackoff,
  }) {
    return JellyfinConfig(
      server: server ?? this.server,
      userId: userId ?? this.userId,
      deviceId: deviceId ?? this.deviceId,
      deviceName: deviceName ?? this.deviceName,
      accessToken: accessToken ?? this.accessToken,
      username: username ?? this.username,
      password: password ?? this.password,
      clientName: clientName ?? this.clientName,
      clientVersion: clientVersion ?? this.clientVersion,
      mpvExecutable: mpvExecutable ?? this.mpvExecutable,
      mpvArgs: mpvArgs ?? this.mpvArgs,
      keepAliveInterval: keepAliveInterval ?? this.keepAliveInterval,
      playbackProgressInterval:
          playbackProgressInterval ?? this.playbackProgressInterval,
      startupReconnectBackoff:
          startupReconnectBackoff ?? this.startupReconnectBackoff,
    );
  }

  Map<String, String> get authHeaders {
    final headers = <String, String>{};
    if (accessToken != null) {
      headers['X-Emby-Token'] = accessToken!;
    }
    headers['X-Emby-Authorization'] =
        'MediaBrowser Client="$clientName", Device="$deviceName", DeviceId="$deviceId", Version="$clientVersion", UserId="$userId"';
    return headers;
  }

  Uri websocketUri({String? token}) {
    final wsScheme = server.scheme == 'https' ? 'wss' : 'ws';
    final basePath = _trimTrailingSlash(server.path);
    final socketPath = p.join(basePath.isEmpty ? '/' : basePath, 'socket');
    return server.replace(
      scheme: wsScheme,
      path: socketPath,
      queryParameters: {
        'api_key': token ?? accessToken,
        'deviceId': deviceId,
        'deviceName': deviceName,
        'client': clientName,
        'version': clientVersion,
        'userId': userId,
      },
    );
  }

  Uri buildUri(String apiPath, {Map<String, dynamic>? queryParameters}) {
    final basePath = _trimTrailingSlash(server.path);
    final combinedPath = p.join(basePath.isEmpty ? '/' : basePath, apiPath);
    final normalizedQuery = <String, String>{};
    queryParameters?.forEach((key, value) {
      if (value == null) {
        return;
      }
      normalizedQuery[key] = value.toString();
    });
    return server.replace(
      path: combinedPath,
      queryParameters: normalizedQuery.isEmpty ? null : normalizedQuery,
    );
  }

  static Uri _parseServer(Object? value) {
    if (value == null) {
      throw ArgumentError('Configuration is missing "server".');
    }
    final uri = Uri.parse(value.toString());
    if (!uri.hasScheme || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw ArgumentError('"server" must include http or https scheme.');
    }
    return uri;
  }

  static String _requireString(Map<String, dynamic> map, String key) {
    final value = map[key];
    if (value == null || value.toString().isEmpty) {
      throw ArgumentError('Configuration is missing "$key".');
    }
    return value.toString();
  }

  static List<String> _parseStringList(Object? value) {
    if (value == null) {
      return const <String>[];
    }
    if (value is Iterable) {
      return value.map((dynamic e) => e.toString()).toList();
    }
    return value.toString().split(',');
  }

  static Duration _parseDuration(Object? value, {required int defaultSeconds}) {
    if (value == null) {
      return Duration(seconds: defaultSeconds);
    }
    if (value is int) {
      return Duration(seconds: value);
    }
    if (value is String) {
      if (value.endsWith('ms')) {
        final asInt = int.parse(value.substring(0, value.length - 2));
        return Duration(milliseconds: asInt);
      }
      if (value.endsWith('s')) {
        final asInt = int.parse(value.substring(0, value.length - 1));
        return Duration(seconds: asInt);
      }
      if (value.endsWith('m')) {
        final asInt = int.parse(value.substring(0, value.length - 1));
        return Duration(minutes: asInt);
      }
      final asInt = int.parse(value);
      return Duration(seconds: asInt);
    }
    throw ArgumentError('Invalid duration value "$value".');
  }

  static Map<String, dynamic> _yamlToMap(YamlMap yaml) {
    return yaml.map(
      (dynamic key, dynamic value) => MapEntry(
        key.toString(),
        value is YamlMap
            ? _yamlToMap(value)
            : value is YamlList
            ? value.toList()
            : value,
      ),
    );
  }

  static String _trimTrailingSlash(String value) {
    if (value.endsWith('/')) {
      return value.substring(0, value.length - 1);
    }
    return value;
  }
}

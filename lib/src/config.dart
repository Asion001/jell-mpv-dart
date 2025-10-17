import 'dart:io';

import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

part 'config.freezed.dart';
part 'config.g.dart';

/// Strongly typed configuration for the Jellyfin → mpv shim.
@freezed
class JellyfinConfig with _$JellyfinConfig {
  const factory JellyfinConfig({
    @JsonKey(fromJson: JellyfinConfig.parseServer) required Uri server,
    required String userId,
    required String deviceId,
    required String deviceName,
    String? accessToken,
    String? username,
    String? password,
    @Default('Jellyfin MPV Shim') String clientName,
    @Default('0.1.0') String clientVersion,
    @Default('mpv') String mpvExecutable,
    @JsonKey(fromJson: JellyfinConfig.parseStringList)
    @Default(<String>[])
    List<String> mpvArgs,
    @JsonKey(fromJson: JellyfinConfig.parseDuration)
    @Default(Duration(seconds: 15))
    Duration keepAliveInterval,
    @JsonKey(fromJson: JellyfinConfig.parseDuration)
    @Default(Duration(seconds: 30))
    Duration playbackProgressInterval,
    @JsonKey(fromJson: JellyfinConfig.parseDuration)
    @Default(Duration(seconds: 5))
    Duration startupReconnectBackoff,
  }) = _JellyfinConfig;

  const JellyfinConfig._();

  factory JellyfinConfig.fromJson(Map<String, dynamic> json) =>
      _$JellyfinConfigFromJson(json);

  static Future<JellyfinConfig> fromYamlFile(File file) async {
    final contents = await file.readAsString();
    final yaml = loadYaml(contents);
    if (yaml is! YamlMap) {
      throw const FormatException('Invalid YAML configuration.');
    }
    return JellyfinConfig.fromJson(_yamlToMap(yaml));
  }

  Map<String, String> get authHeaders {
    final headers = <String, String>{};
    if (accessToken != null) {
      headers['X-Emby-Token'] = accessToken!;
    }
    headers['X-Emby-Authorization'] =
        'MediaBrowser Client="$clientName", '
        'Device="$deviceName", '
        'DeviceId="$deviceId", '
        'Version="$clientVersion", '
        'UserId="$userId"';
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

  static Uri parseServer(Object? value) {
    if (value == null) {
      throw ArgumentError('Configuration is missing "server".');
    }
    final uri = Uri.parse(value.toString());
    if (!uri.hasScheme || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw ArgumentError('"server" must include http or https scheme.');
    }
    return uri;
  }

  static List<String> parseStringList(Object? value) {
    if (value == null) {
      return const <String>[];
    }
    if (value is Iterable) {
      return value.map((dynamic e) => e.toString()).toList();
    }
    return value.toString().split(',');
  }

  static Duration parseDuration(Object? value) {
    if (value == null) {
      throw ArgumentError('Duration value cannot be null.');
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

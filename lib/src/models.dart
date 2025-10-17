import 'dart:convert';

import 'package:freezed_annotation/freezed_annotation.dart';

part 'models.freezed.dart';
part 'models.g.dart';

/// Utility to convert ticks (100ns units) into a [Duration].
Duration? durationFromTicks(Object? value) {
  if (value == null) {
    return null;
  }
  final ticks = value is num ? value.toInt() : int.tryParse(value.toString());
  if (ticks == null) {
    return null;
  }
  if (ticks == 0) {
    return Duration.zero;
  }
  return Duration(microseconds: ticks ~/ 10);
}

int durationToTicks(Duration duration) => duration.inMicroseconds * 10;

/// Converter for Duration to/from ticks for JSON serialization.
class DurationTicksConverter implements JsonConverter<Duration, int> {
  const DurationTicksConverter();

  @override
  Duration fromJson(int json) => Duration(microseconds: json ~/ 10);

  @override
  int toJson(Duration object) => object.inMicroseconds * 10;
}

/// Message envelope emitted by the Jellyfin WebSocket.
@freezed
class JellyfinSocketMessage with _$JellyfinSocketMessage {
  const factory JellyfinSocketMessage({
    required String type,
    required Object? rawData,
  }) = _JellyfinSocketMessage;

  const JellyfinSocketMessage._();

  Map<String, dynamic>? tryDecodeData() {
    if (rawData == null) {
      return null;
    }
    if (rawData is Map<String, dynamic>) {
      return rawData! as Map<String, dynamic>;
    }
    if (rawData is String) {
      final decoded = jsonDecode(rawData! as String);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    }
    return null;
  }
}

/// Jellyfin "Play" directive payload.
@freezed
abstract class PlayRequest with _$PlayRequest {
  @JsonSerializable(
    explicitToJson: true,
    includeIfNull: false,
    fieldRename: FieldRename.pascal,
  )
  const factory PlayRequest({
    required List<String> itemIds,
    @Default('PlayNow') String playCommand,
    String? playSessionId,
    int? startIndex,
    Duration? startPosition,
    String? mediaSourceId,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
    String? controllingUserId,
  }) = _PlayRequest;

  const PlayRequest._();

  factory PlayRequest.fromJson(Map<String, dynamic> json) =>
      _$PlayRequestFromJson(json);

  String chooseItemId() {
    if (itemIds.isEmpty) {
      throw StateError('PlayRequest does not include any items.');
    }
    if (startIndex != null &&
        startIndex! >= 0 &&
        startIndex! < itemIds.length) {
      return itemIds[startIndex!];
    }
    return itemIds.first;
  }
}

/// Payload for POST /Sessions/Playing.
@freezed
class PlaybackStartRequest with _$PlaybackStartRequest {
  @JsonSerializable(
    explicitToJson: true,
    includeIfNull: false,
    fieldRename: FieldRename.pascal,
  )
  const factory PlaybackStartRequest({
    required String itemId,
    required String mediaSourceId,
    required String playSessionId,
    @Default(Duration.zero) Duration position,
    @Default(false) bool isPaused,
    @Default(true) bool canSeek,
    List<QueueItem>? nowPlayingQueue,
  }) = _PlaybackStartRequest;

  factory PlaybackStartRequest.fromJson(Map<String, dynamic> json) =>
      _$PlaybackStartRequestFromJson(json);
}

/// Represents a queue item in the playlist.
@freezed
class QueueItem with _$QueueItem {
  const factory QueueItem({
    required String id,
    String? playlistItemId,
  }) = _QueueItem;

  factory QueueItem.fromJson(Map<String, dynamic> json) =>
      _$QueueItemFromJson(json);
}

/// Payload for POST /Sessions/Playing/Progress.
@freezed
class PlaybackProgressRequest with _$PlaybackProgressRequest {
  @JsonSerializable(
    explicitToJson: true,
    includeIfNull: false,
    fieldRename: FieldRename.pascal,
  )
  const factory PlaybackProgressRequest({
    required String itemId,
    required String mediaSourceId,
    required String playSessionId,
    required Duration position,
    @Default(false) bool isPaused,
    @Default(false) bool isMuted,
    int? volumeLevel,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
    List<QueueItem>? nowPlayingQueue,
  }) = _PlaybackProgressRequest;

  factory PlaybackProgressRequest.fromJson(Map<String, dynamic> json) =>
      _$PlaybackProgressRequestFromJson(json);
}

/// Payload for POST /Sessions/Playing/Stopped.
@freezed
class PlaybackStopRequest with _$PlaybackStopRequest {
  @JsonSerializable(
    explicitToJson: true,
    includeIfNull: false,
    fieldRename: FieldRename.pascal,
  )
  const factory PlaybackStopRequest({
    required String itemId,
    required String mediaSourceId,
    required String playSessionId,
    required Duration position,
  }) = _PlaybackStopRequest;

  factory PlaybackStopRequest.fromJson(Map<String, dynamic> json) =>
      _$PlaybackStopRequestFromJson(json);
}

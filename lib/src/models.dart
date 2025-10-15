import 'dart:convert';

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
  return Duration(microseconds: (ticks ~/ 10));
}

int durationToTicks(Duration duration) => duration.inMicroseconds * 10;

/// Message envelope emitted by the Jellyfin WebSocket.
class JellyfinSocketMessage {
  JellyfinSocketMessage({required this.type, required this.rawData});

  final String type;
  final Object? rawData;

  Map<String, dynamic>? tryDecodeData() {
    if (rawData == null) {
      return null;
    }
    if (rawData is Map<String, dynamic>) {
      return rawData as Map<String, dynamic>;
    }
    if (rawData is String) {
      final decoded = jsonDecode(rawData as String);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    }
    return null;
  }
}

/// Jellyfin "Play" directive payload.
class PlayRequest {
  PlayRequest({
    required this.itemIds,
    required this.playCommand,
    required this.playSessionId,
    this.startIndex,
    this.startPosition,
    this.mediaSourceId,
    this.audioStreamIndex,
    this.subtitleStreamIndex,
    this.controllingUserId,
  });

  factory PlayRequest.fromJson(Map<String, dynamic> json) {
    final rawItems = json['ItemIds'];
    final ids = <String>[];
    if (rawItems is Iterable) {
      for (final item in rawItems) {
        ids.add(item.toString());
      }
    } else if (rawItems != null) {
      ids.add(rawItems.toString());
    }
    return PlayRequest(
      itemIds: ids,
      playCommand: json['PlayCommand']?.toString() ?? 'PlayNow',
      playSessionId: json['PlaySessionId']?.toString(),
      startIndex: (json['StartPlaylistIndex'] ?? json['StartIndex']) is num
          ? (json['StartPlaylistIndex'] ?? json['StartIndex']).toInt()
          : null,
      startPosition: durationFromTicks(json['StartPositionTicks']),
      mediaSourceId: json['MediaSourceId']?.toString(),
      audioStreamIndex: json['AudioStreamIndex'] is num
          ? (json['AudioStreamIndex'] as num).toInt()
          : null,
      subtitleStreamIndex: json['SubtitleStreamIndex'] is num
          ? (json['SubtitleStreamIndex'] as num).toInt()
          : null,
      controllingUserId: json['ControllingUserId']?.toString(),
    );
  }

  final List<String> itemIds;
  final String playCommand;
  final String? playSessionId;
  final int? startIndex;
  final Duration? startPosition;
  final String? mediaSourceId;
  final int? audioStreamIndex;
  final int? subtitleStreamIndex;
  final String? controllingUserId;

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
class PlaybackStartRequest {
  PlaybackStartRequest({
    required this.itemId,
    required this.mediaSourceId,
    required this.playSessionId,
    this.position = Duration.zero,
    this.isPaused = false,
    this.canSeek = true,
  });

  final String itemId;
  final String mediaSourceId;
  final String playSessionId;
  final Duration position;
  final bool isPaused;
  final bool canSeek;

  Map<String, dynamic> toJson() {
    return {
      'ItemId': itemId,
      'MediaSourceId': mediaSourceId,
      'PlaySessionId': playSessionId,
      'IsPaused': isPaused,
      'CanSeek': canSeek,
      'PositionTicks': durationToTicks(position),
    };
  }
}

/// Payload for POST /Sessions/Playing/Progress.
class PlaybackProgressRequest {
  PlaybackProgressRequest({
    required this.itemId,
    required this.mediaSourceId,
    required this.playSessionId,
    required this.position,
    this.isPaused = false,
    this.isMuted = false,
  });

  final String itemId;
  final String mediaSourceId;
  final String playSessionId;
  final Duration position;
  final bool isPaused;
  final bool isMuted;

  Map<String, dynamic> toJson() {
    return {
      'ItemId': itemId,
      'MediaSourceId': mediaSourceId,
      'PlaySessionId': playSessionId,
      'IsPaused': isPaused,
      'IsMuted': isMuted,
      'PositionTicks': durationToTicks(position),
    };
  }
}

/// Payload for POST /Sessions/Playing/Stopped.
class PlaybackStopRequest {
  PlaybackStopRequest({
    required this.itemId,
    required this.mediaSourceId,
    required this.playSessionId,
    required this.position,
  });

  final String itemId;
  final String mediaSourceId;
  final String playSessionId;
  final Duration position;

  Map<String, dynamic> toJson() {
    return {
      'ItemId': itemId,
      'MediaSourceId': mediaSourceId,
      'PlaySessionId': playSessionId,
      'PositionTicks': durationToTicks(position),
    };
  }
}

#!/usr/bin/env dart
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:jell_mpv_dart/jell_mpv_dart.dart';
import 'package:jell_mpv_dart/src/models.dart';

/// Test script to send remote control commands to the mpv player
Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
      'Usage: dart run test_remote_control.dart <command> [args...]'
      ' '
      'Commands:'
      '  sessions              - List all active sessions'
      '  play <itemId>         - Start playing an item'
      '  pause                 - Pause playback'
      '  unpause               - Resume playback'
      '  stop                  - Stop playback'
      '  seek <seconds>        - Seek to position'
      '  volume <0-100>        - Set volume'
      '  volume-up             - Increase volume'
      '  volume-down           - Decrease volume'
      '  mute                  - Mute audio'
      '  unmute                - Unmute audio'
      '  toggle-mute           - Toggle mute'
      '  audio <index>         - Switch audio track'
      '  subtitle <index>      - Switch subtitle track',
    );
    exit(1);
  }

  // Load config
  final configFile = File('config.yaml');
  if (!configFile.existsSync()) {
    stderr.writeln('Error: config.yaml not found');
    exit(1);
  }

  final config = await JellyfinConfig.fromYamlFile(configFile);
  final client = http.Client();
  final api = JellyfinApi(config, httpClient: client);

  // Authenticate if needed
  if (config.username != null && config.password != null) {
    await api.authenticateByName(config.username!, config.password!);
  }

  final command = args[0];

  try {
    switch (command) {
      case 'sessions':
        await _listSessions(config, api, client);
      case 'play':
        if (args.length < 2) {
          stderr.writeln('Error: play command requires itemId');
          exit(1);
        }
        await _sendPlayCommand(config, api, client, args[1]);
      case 'pause':
        await _sendPlaystateCommand(config, api, client, 'Pause');
      case 'unpause':
        await _sendPlaystateCommand(config, api, client, 'Unpause');
      case 'stop':
        await _sendPlaystateCommand(config, api, client, 'Stop');
      case 'seek':
        if (args.length < 2) {
          stderr.writeln('Error: seek command requires seconds');
          exit(1);
        }
        final seconds = int.tryParse(args[1]);
        if (seconds == null) {
          stderr.writeln('Error: invalid seconds value');
          exit(1);
        }
        await _sendSeekCommand(config, api, client, Duration(seconds: seconds));
      case 'volume':
        if (args.length < 2) {
          stderr.writeln('Error: volume command requires value (0-100)');
          exit(1);
        }
        final volume = int.tryParse(args[1]);
        if (volume == null || volume < 0 || volume > 100) {
          stderr.writeln('Error: invalid volume value (must be 0-100)');
          exit(1);
        }
        await _sendVolumeCommand(config, api, client, volume);
      case 'volume-up':
        await _sendPlaystateCommand(config, api, client, 'VolumeUp');
      case 'volume-down':
        await _sendPlaystateCommand(config, api, client, 'VolumeDown');
      case 'mute':
        await _sendPlaystateCommand(config, api, client, 'Mute');
      case 'unmute':
        await _sendPlaystateCommand(config, api, client, 'Unmute');
      case 'toggle-mute':
        await _sendPlaystateCommand(config, api, client, 'ToggleMute');
      case 'audio':
        if (args.length < 2) {
          stderr.writeln('Error: audio command requires track index');
          exit(1);
        }
        final index = int.tryParse(args[1]);
        if (index == null) {
          stderr.writeln('Error: invalid track index');
          exit(1);
        }
        await _sendSetStreamCommand(
          config,
          api,
          client,
          'SetAudioStreamIndex',
          index,
        );
      case 'subtitle':
        if (args.length < 2) {
          stderr.writeln('Error: subtitle command requires track index');
          exit(1);
        }
        final index = int.tryParse(args[1]);
        if (index == null) {
          stderr.writeln('Error: invalid track index');
          exit(1);
        }
        await _sendSetStreamCommand(
          config,
          api,
          client,
          'SetSubtitleStreamIndex',
          index,
        );
      default:
        stderr.writeln('Unknown command: $command');
        exit(1);
    }
  } finally {
    client.close();
  }
}

Future<void> _listSessions(
  JellyfinConfig config,
  JellyfinApi api,
  http.Client client,
) async {
  final uri = config.buildUri('Sessions');
  final response = await client.get(uri, headers: api.authHeaders);

  if (response.statusCode != 200) {
    stderr
      ..writeln('Error: ${response.statusCode}')
      ..writeln(response.body);
    exit(1);
  }

  final sessions = jsonDecode(response.body) as List;
  print('Active sessions:');
  for (final session in sessions) {
    if (session is! Map) continue;
    print('  ${session['DeviceName']} (${session['DeviceId']})');
    print('    Client: ${session['Client']}');
    print('    Remote Control: ${session['SupportsRemoteControl']}');
    if (session['NowPlayingItem'] != null) {
      final item = session['NowPlayingItem'] as Map;
      print('    Now Playing: ${item['Name']}');
    }
  }
}

Future<void> _sendPlayCommand(
  JellyfinConfig config,
  JellyfinApi api,
  http.Client client,
  String itemId,
) async {
  final session = await _findMpvSession(config, api, client);
  if (session == null) {
    stderr.writeln('Error: MPV session not found');
    exit(1);
  }

  final sessionId = session['Id'] as String;
  final uri = config.buildUri('Sessions/$sessionId/Playing');
  final response = await client.post(
    uri,
    headers: {...api.authHeaders, 'Content-Type': 'application/json'},
    body: jsonEncode({
      'ItemIds': [itemId],
      'PlayCommand': 'PlayNow',
    }),
  );

  if (response.statusCode == 204) {
    print('✅ Play command sent');
  } else {
    stderr
      ..writeln('Error: ${response.statusCode}')
      ..writeln(response.body);
    exit(1);
  }
}

Future<void> _sendPlaystateCommand(
  JellyfinConfig config,
  JellyfinApi api,
  http.Client client,
  String command,
) async {
  final session = await _findMpvSession(config, api, client);
  if (session == null) {
    stderr.writeln('Error: MPV session not found');
    exit(1);
  }

  final sessionId = session['Id'] as String;
  final uri = config.buildUri('Sessions/$sessionId/Playing/$command');
  final response = await client.post(uri, headers: api.authHeaders);

  if (response.statusCode == 204) {
    print('✅ $command command sent');
  } else {
    stderr
      ..writeln('Error: ${response.statusCode}')
      ..writeln(response.body);
    exit(1);
  }
}

Future<void> _sendSeekCommand(
  JellyfinConfig config,
  JellyfinApi api,
  http.Client client,
  Duration position,
) async {
  final session = await _findMpvSession(config, api, client);
  if (session == null) {
    stderr.writeln('Error: MPV session not found');
    exit(1);
  }

  final sessionId = session['Id'] as String;
  final ticks = durationToTicks(position);
  final uri = config.buildUri('Sessions/$sessionId/Playing/Seek');
  final response = await client.post(
    uri,
    headers: {...api.authHeaders, 'Content-Type': 'application/json'},
    body: jsonEncode({'SeekPositionTicks': ticks}),
  );

  if (response.statusCode == 204) {
    print('✅ Seek command sent to $position');
  } else {
    stderr
      ..writeln('Error: ${response.statusCode}')
      ..writeln(response.body);
    exit(1);
  }
}

Future<void> _sendVolumeCommand(
  JellyfinConfig config,
  JellyfinApi api,
  http.Client client,
  int volume,
) async {
  final session = await _findMpvSession(config, api, client);
  if (session == null) {
    stderr.writeln('Error: MPV session not found');
    exit(1);
  }

  final sessionId = session['Id'] as String;
  final uri = config.buildUri('Sessions/$sessionId/Playing/SetVolume');
  final response = await client.post(
    uri,
    headers: {...api.authHeaders, 'Content-Type': 'application/json'},
    body: jsonEncode({'Volume': volume}),
  );

  if (response.statusCode == 204) {
    print('✅ Volume set to $volume');
  } else {
    stderr
      ..writeln('Error: ${response.statusCode}')
      ..writeln(response.body);
    exit(1);
  }
}

Future<void> _sendSetStreamCommand(
  JellyfinConfig config,
  JellyfinApi api,
  http.Client client,
  String command,
  int index,
) async {
  final session = await _findMpvSession(config, api, client);
  if (session == null) {
    stderr.writeln('Error: MPV session not found');
    exit(1);
  }

  final sessionId = session['Id'] as String;
  final uri = config.buildUri('Sessions/$sessionId/Playing/$command');
  final response = await client.post(
    uri,
    headers: {...api.authHeaders, 'Content-Type': 'application/json'},
    body: jsonEncode({'Index': index}),
  );

  if (response.statusCode == 204) {
    print('✅ $command sent with index $index');
  } else {
    stderr
      ..writeln('Error: ${response.statusCode}')
      ..writeln(response.body);
    exit(1);
  }
}

Future<Map<String, dynamic>?> _findMpvSession(
  JellyfinConfig config,
  JellyfinApi api,
  http.Client client,
) async {
  final uri = config.buildUri('Sessions');
  final response = await client.get(uri, headers: api.authHeaders);

  if (response.statusCode != 200) {
    return null;
  }

  final sessions = jsonDecode(response.body) as List;
  for (final session in sessions) {
    if (session is! Map<String, dynamic>) continue;
    if (session['DeviceId'] == config.deviceId) {
      return session;
    }
  }
  return null;
}

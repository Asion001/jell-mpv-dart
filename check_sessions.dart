#!/usr/bin/env dart

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:jell_mpv_dart/jell_mpv_dart.dart';

/// Quick script to check current Jellyfin sessions
Future<void> main() async {
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
    print('Authenticating with username/password...');
    await api.authenticateByName(config.username!, config.password!);
    print('✅ Authentication successful\n');
  }

  // Query all sessions
  final sessionsUri = config.buildUri('Sessions');
  print('Querying: $sessionsUri\n');

  final response = await client.get(sessionsUri, headers: api.authHeaders);

  if (response.statusCode != 200) {
    stderr.writeln('Error: ${response.statusCode}');
    stderr.writeln(response.body);
    exit(1);
  }

  final sessions = jsonDecode(response.body) as List;
  print('Found ${sessions.length} active session(s):\n');

  for (final session in sessions) {
    if (session is! Map) continue;

    final deviceName = session['DeviceName'] ?? 'Unknown';
    final client = session['Client'] ?? 'Unknown';
    final supportsRemoteControl = session['SupportsRemoteControl'] ?? false;
    final userId = session['UserId'] ?? 'N/A';
    final playableMedia = session['PlayableMediaTypes'] ?? [];

    print('📱 $deviceName');
    print('   Client: $client');
    print('   UserId: $userId');
    print('   Remote Control: ${supportsRemoteControl ? "✅" : "❌"}');
    print('   Media: $playableMedia');
    print('');
  }

  // Query controllable sessions
  final controllableUri = config.buildUri(
    'Sessions',
    queryParameters: {'ControllableByUserId': config.userId},
  );
  print('\nQuerying controllable sessions for ${config.userId}...');

  final controllableResponse = await client.get(
    controllableUri,
    headers: api.authHeaders,
  );

  if (controllableResponse.statusCode == 200) {
    final controllable = jsonDecode(controllableResponse.body) as List;
    print('Found ${controllable.length} controllable session(s)');

    for (final session in controllable) {
      if (session is! Map) continue;
      print('  - ${session['DeviceName']} (${session['Client']})');
    }
  }

  client.close();
}

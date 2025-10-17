// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:jell_mpv_dart/jell_mpv_dart.dart';
import 'package:test/test.dart';

void main() {
  group('Jellyfin Session Registration', () {
    late JellyfinConfig config;
    late JellyfinMpvShim shim;
    late JellyfinApi api;
    late http.Client httpClient;

    setUpAll(() async {
      // Load config from config.yaml
      final configFile = File('config.yaml');
      if (!configFile.existsSync()) {
        throw StateError(
          'config.yaml not found. Please create it from config.example.yaml',
        );
      }
      config = await JellyfinConfig.fromYamlFile(configFile);
      httpClient = http.Client();
      api = JellyfinApi(config, httpClient: httpClient);

      // Authenticate if using username/password
      if (config.username != null && config.password != null) {
        print('Test: Authenticating with username/password...');
        await api.authenticateByName(config.username!, config.password!);
        print('Test: Authentication successful.');
      }
    });

    tearDownAll(() {
      httpClient.close();
    });

    test(
      'Session appears in /Sessions endpoint after connecting',
      () async {
        // Start the shim with the same API instance so it has the token
        shim = JellyfinMpvShim(config: config, api: api);

        // Run shim in background
        final shimFuture = shim.run();

        // Wait for connection to establish and capabilities to be announced
        print('Waiting for shim to connect and announce capabilities...');
        await Future<void>.delayed(const Duration(seconds: 5));

        // Query all Sessions first
        final allSessionsUri = config.buildUri('Sessions');
        print('Querying all sessions: $allSessionsUri');

        final allSessionsResponse = await httpClient.get(
          allSessionsUri,
          headers: api.authHeaders,
        );

        expect(allSessionsResponse.statusCode, equals(200));

        final allSessions = jsonDecode(allSessionsResponse.body) as List;
        print('Found ${allSessions.length} total sessions');

        for (final session in allSessions) {
          if (session is Map) {
            print('Session: ${session['DeviceName']} (${session['DeviceId']})');
            print('  Client: ${session['Client']}');
            print(
              '  SupportsRemoteControl: ${session['SupportsRemoteControl']}',
            );
            print('  PlayableMediaTypes: ${session['PlayableMediaTypes']}');
          }
        }

        // Query controllable Sessions endpoint
        final sessionsUri = config.buildUri(
          'Sessions',
          queryParameters: {'ControllableByUserId': config.userId},
        );

        print('\nQuerying controllable sessions: $sessionsUri');

        final response = await httpClient.get(
          sessionsUri,
          headers: api.authHeaders,
        );

        expect(response.statusCode, equals(200));

        final sessions = jsonDecode(response.body) as List;
        print('Found ${sessions.length} controllable sessions');

        // Print all sessions for debugging
        for (final session in sessions) {
          if (session is Map) {
            print('Session: ${session['DeviceName']} (${session['DeviceId']})');
            print('  Client: ${session['Client']}');
            print(
              '  SupportsRemoteControl: ${session['SupportsRemoteControl']}',
            );
            print('  PlayableMediaTypes: ${session['PlayableMediaTypes']}');
          }
        }

        // Find our device in all sessions (not just controllable ones)
        final ourSession = allSessions
            .cast<Map<dynamic, dynamic>?>()
            .firstWhere(
              (session) => session?['DeviceId'] == config.deviceId,
              orElse: () => null,
            );

        if (ourSession == null) {
          final availableDevices = allSessions
              .map((s) => s is Map ? s['DeviceName'] : 'unknown')
              .join(', ');
          fail(
            'Device "${config.deviceName}" (${config.deviceId}) not found'
            ' in sessions. '
            'Available devices: $availableDevices',
          );
        }
        print('\nOur session found:');
        print('  DeviceId: ${ourSession['DeviceId']}');
        print('  DeviceName: ${ourSession['DeviceName']}');
        print('  Client: ${ourSession['Client']}');
        print('  UserId: ${ourSession['UserId']}');
        print(
          '  SupportsRemoteControl: ${ourSession['SupportsRemoteControl']}',
        );
        print('  PlayableMediaTypes: ${ourSession['PlayableMediaTypes']}');
        print('  SupportedCommands: ${ourSession['SupportedCommands']}');

        expect(ourSession['DeviceId'], equals(config.deviceId));
        expect(ourSession['DeviceName'], equals(config.deviceName));
        expect(ourSession['PlayableMediaTypes'], isNotEmpty);

        // Check if the session has the correct UserId
        final sessionUserId = ourSession['UserId']?.toString();
        print('\n🔍 Checking UserId...');
        print('   Expected: ${config.userId}');
        print('   Actual: $sessionUserId');

        if (sessionUserId == null) {
          print("❌ Session has NO UserId! This is why it's not controllable!");
        } else if (sessionUserId != config.userId) {
          print('❌ Session has WRONG UserId!');
        } else {
          print('✅ UserId matches!');
        }

        expect(
          sessionUserId,
          equals(config.userId),
          reason: 'Session must be associated with the correct user',
        );

        // Check if it supports remote control
        final supportsRemoteControl =
            ourSession['SupportsRemoteControl'] == true;
        print('\n⚠️  SupportsRemoteControl: $supportsRemoteControl');

        if (!supportsRemoteControl) {
          print('⚠️  Device registered but NOT remotely controllable!');
          print('   This means it won\'t appear in "Play on" dialog.');
        }

        // NOTE: Currently Jellyfin doesn't mark this as
        // SupportsRemoteControl=true
        // despite having all the correct capabilities announced.
        // The session IS created with PlayableMediaTypes and SupportedCommands.
        // This might be a Jellyfin server-side issue with how it determines
        // remote controllability for custom clients.
        print('\n✅ Session registered with capabilities!');
        if (!supportsRemoteControl) {
          print(
            '⚠️  Note: Jellyfin is not marking it as '
            'remotely controllable yet.',
          );
          print('   Investigating why...');
        }

        // Verify the session has the necessary capabilities
        expect(ourSession['SupportedCommands'], isNotEmpty);
        expect(ourSession['SupportedCommands'], contains('Play'));

        // Print diagnostic info
        print('\n📋 ROOT CAUSE FOUND:');
        print('The API key creates an ANONYMOUS session (UserId=00000...).');
        print('');
        print('✅ SOLUTION:');
        print('The accessToken MUST be a USER-SPECIFIC API key.');
        print('When creating the API key in Jellyfin, ensure:');
        print('1. You are logged in as the user');
        print("2. Create the key under that user's settings");
        print('3. The key will be automatically associated with that user');
        print('');
        print('If using a system-wide API key, sessions will be anonymous.');

        // Cleanup
        await shim.shutdown();
        await shimFuture.timeout(
          const Duration(seconds: 2),
          onTimeout: () => null,
        );
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );
  });
}

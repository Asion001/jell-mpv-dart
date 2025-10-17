import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:jell_mpv_dart/jell_mpv_dart.dart';
import 'package:talker/talker.dart';

const _cliVersion = '0.1.0';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Display usage information.',
    )
    ..addFlag('version', negatable: false, help: 'Print the CLI version.')
    ..addOption(
      'config',
      abbr: 'c',
      help: 'Path to a YAML configuration file.',
      valueHelp: 'file',
    )
    ..addOption(
      'server',
      abbr: 's',
      help: 'Base Jellyfin server URL (e.g. https://server:8096).',
      valueHelp: 'url',
    )
    ..addOption('user-id', help: 'Jellyfin UserId to control.', valueHelp: 'id')
    ..addOption(
      'token',
      abbr: 't',
      help: 'Jellyfin access token with playback privileges.',
      valueHelp: 'token',
    )
    ..addOption(
      'username',
      abbr: 'u',
      help: 'Jellyfin username (alternative to access token).',
      valueHelp: 'username',
    )
    ..addOption(
      'password',
      abbr: 'p',
      help: 'Jellyfin password (required with username).',
      valueHelp: 'password',
    )
    ..addOption(
      'device-id',
      help: 'Device identifier reported to Jellyfin.',
      valueHelp: 'id',
    )
    ..addOption(
      'device-name',
      help: 'Human readable device name.',
      valueHelp: 'name',
    )
    ..addOption(
      'mpv-binary',
      help: 'mpv executable to launch.',
      valueHelp: 'path',
    )
    ..addMultiOption(
      'mpv-arg',
      help: 'Additional mpv argument (may be supplied multiple times).',
      splitCommas: false,
      valueHelp: 'arg',
    )
    ..addOption(
      'keep-alive',
      help: 'WebSocket keep-alive interval (e.g. 15s, 1m).',
      valueHelp: 'duration',
    )
    ..addOption(
      'progress-interval',
      help: 'Playback progress reporting interval (e.g. 30s).',
      valueHelp: 'duration',
    )
    ..addFlag(
      'verbose',
      abbr: 'v',
      negatable: false,
      help: 'Enable verbose logging.',
    );

  ArgResults argResults;
  try {
    argResults = parser.parse(arguments);
  } on FormatException catch (error) {
    stderr.writeln('Argument error: ${error.message}\n');
    _printUsage(parser);
    exitCode = 64; // EX_USAGE
    return;
  }

  if (_getFlag(argResults, 'help')) {
    _printUsage(parser);
    return;
  }
  if (_getFlag(argResults, 'version')) {
    stdout.writeln('jell_mpv_dart $_cliVersion');
    return;
  }

  final settings = _configureLogging(verbose: _getFlag(argResults, 'verbose'));
  final log = Talker(
    logger: TalkerLogger(settings: settings),
  );

  JellyfinConfig config;
  try {
    config = await _loadConfig(argResults);
  } catch (error, stackTrace) {
    log.critical('Failed to load configuration', error, stackTrace);
    exitCode = 78; // EX_CONFIG
    return;
  }

  final shim = JellyfinMpvShim(config: config);
  _registerSignalHandlers(shim, log);

  try {
    await shim.run();
  } catch (error, stackTrace) {
    log.critical('An unrecoverable error occurred', error, stackTrace);
    exitCode = 1;
  }
}

void _printUsage(ArgParser parser) {
  stdout
    ..writeln('Usage: jell_mpv_dart [options]\n')
    ..writeln(parser.usage);
}

TalkerLoggerSettings _configureLogging({required bool verbose}) {
  return TalkerLoggerSettings(
    defaultTitle: 'CLI',
    level: verbose ? LogLevel.verbose : LogLevel.info,
  );
}

Future<JellyfinConfig> _loadConfig(ArgResults args) async {
  JellyfinConfig? base;
  final configPath = _getOption(args, 'config');
  if (configPath != null) {
    base = await JellyfinConfig.fromYamlFile(File(configPath));
  }

  final server = _getOption(args, 'server');
  final userId = _getOption(args, 'user-id');
  final token = _getOption(args, 'token');
  final username = _getOption(args, 'username');
  final password = _getOption(args, 'password');
  final deviceId = _getOption(args, 'device-id');
  final deviceName = _getOption(args, 'device-name');
  final keepAlive = _getOption(args, 'keep-alive');
  final progress = _getOption(args, 'progress-interval');
  final mpvBinary = _getOption(args, 'mpv-binary');
  final mpvArgs = _getMultiOption(args, 'mpv-arg');

  if (base == null) {
    final missing = <String>[];
    if (server == null) missing.add('--server');
    if (userId == null) missing.add('--user-id');

    // Require either token OR (username + password)
    if (token == null && (username == null || password == null)) {
      missing.add('--token OR (--username + --password)');
    }

    final resolvedDeviceId = deviceId ?? _defaultDeviceId();
    final resolvedDeviceName = deviceName ?? _defaultDeviceName();
    if (missing.isNotEmpty) {
      throw ArgumentError('Missing required options: ${missing.join(', ')}');
    }
    return JellyfinConfig(
      server: Uri.parse(server!),
      userId: userId!,
      deviceId: resolvedDeviceId,
      deviceName: resolvedDeviceName,
      accessToken: token,
      username: username,
      password: password,
      mpvExecutable: mpvBinary ?? 'mpv',
      mpvArgs: mpvArgs.isNotEmpty ? mpvArgs : const <String>[],
      keepAliveInterval: keepAlive != null
          ? _parseDuration(keepAlive)
          : const Duration(seconds: 15),
      playbackProgressInterval: progress != null
          ? _parseDuration(progress)
          : const Duration(seconds: 30),
    );
  }

  return base.copyWith(
    server: server != null ? Uri.parse(server) : base.server,
    userId: userId ?? base.userId,
    deviceId: deviceId ?? base.deviceId,
    deviceName: deviceName ?? base.deviceName,
    accessToken: token ?? base.accessToken,
    username: username ?? base.username,
    password: password ?? base.password,
    mpvExecutable: mpvBinary ?? base.mpvExecutable,
    mpvArgs: mpvArgs.isNotEmpty ? mpvArgs : base.mpvArgs,
    keepAliveInterval: keepAlive != null
        ? _parseDuration(keepAlive)
        : base.keepAliveInterval,
    playbackProgressInterval: progress != null
        ? _parseDuration(progress)
        : base.playbackProgressInterval,
  );
}

String? _getOption(ArgResults args, String name) {
  final value = args[name];
  if (value is String && value.isNotEmpty) {
    return value;
  }
  return null;
}

bool _getFlag(ArgResults args, String name) {
  final value = args[name];
  if (value is bool) {
    return value;
  }
  return false;
}

List<String> _getMultiOption(ArgResults args, String name) {
  final value = args[name];
  if (value is List) {
    return value.cast<String>();
  }
  return const <String>[];
}

Duration _parseDuration(String value) {
  if (value.endsWith('ms')) {
    return Duration(milliseconds: int.parse(value.replaceAll('ms', '')));
  }
  if (value.endsWith('s')) {
    return Duration(seconds: int.parse(value.replaceAll('s', '')));
  }
  if (value.endsWith('m')) {
    return Duration(minutes: int.parse(value.replaceAll('m', '')));
  }
  if (value.endsWith('h')) {
    return Duration(hours: int.parse(value.replaceAll('h', '')));
  }
  return Duration(seconds: int.parse(value));
}

void _registerSignalHandlers(JellyfinMpvShim shim, Talker log) {
  var shuttingDown = false;

  void handle(ProcessSignal signal) {
    if (shuttingDown) {
      return;
    }
    shuttingDown = true;
    log.info('Received $signal, shutting down.');
    unawaited(shim.shutdown());
  }

  ProcessSignal.sigint.watch().listen(handle);
  ProcessSignal.sigterm.watch().listen(handle);
}

String _defaultDeviceId() {
  final hostname = Platform.localHostname;
  if (hostname.isNotEmpty) {
    return hostname.replaceAll(RegExp('[^a-zA-Z0-9_-]'), '_');
  }
  return 'jell_mpv_dart_cli';
}

String _defaultDeviceName() {
  final hostname = Platform.localHostname;
  if (hostname.isNotEmpty) {
    return hostname;
  }
  return 'Jellyfin Dart mpv shim';
}

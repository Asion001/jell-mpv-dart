import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:jell_mpv_dart/src/config.dart';
import 'package:jell_mpv_dart/src/models.dart';
import 'package:retry/retry.dart';
import 'package:talker/talker.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class JellyfinWebSocket {
  JellyfinWebSocket(this.config)
    : _retry = RetryOptions(
        delayFactor: config.startupReconnectBackoff,
      );

  final JellyfinConfig config;
  final _log = Talker(
    logger: TalkerLogger(
      settings: TalkerLoggerSettings(defaultTitle: 'JellyfinWebSocket'),
    ),
  );
  final _controller = StreamController<JellyfinSocketMessage>.broadcast();
  final RetryOptions _retry;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _keepAlive;
  bool _closed = false;
  final Completer<void> _readyCompleter = Completer<void>();

  Stream<JellyfinSocketMessage> get messages => _controller.stream;
  Future<void> get ready => _readyCompleter.future;

  String? _token;

  Future<void> start({String? token}) async {
    _token = token;
    _closed = false;
    await _connectWithRetry();
  }

  Future<void> close() async {
    _closed = true;
    _keepAlive?.cancel();
    await _subscription?.cancel();
    await _channel?.sink.close();
    await _controller.close();
  }

  Future<void> _connectWithRetry() async {
    await _retry.retry(
      _connectOnce,
      retryIf: (error) =>
          error is SocketException ||
          error is HandshakeException ||
          error is HttpException ||
          error is WebSocketChannelException,
      onRetry: (error) {
        _log.warning('WebSocket reconnect due to error: $error');
      },
    );
  }

  Future<void> _connectOnce() async {
    final uri = config.websocketUri(token: _token);
    _log.info('Connecting to Jellyfin WebSocket: $uri');
    final channel = IOWebSocketChannel.connect(
      uri,
      headers: config.authHeaders,
      pingInterval: config.keepAliveInterval,
    );
    _channel = channel;
    _subscription = channel.stream.listen(
      _handleMessage,
      onDone: _handleDone,
      onError: _handleError,
      cancelOnError: true,
    );
    _startKeepAlive();
    if (!_readyCompleter.isCompleted) {
      _readyCompleter.complete();
    }
  }

  void _handleMessage(dynamic payload) {
    try {
      final message = _decodeMessage(payload);
      if (message != null) {
        _controller.add(message);
      }
    } catch (error, stackTrace) {
      _log.critical('Failed to decode WebSocket message', error, stackTrace);
    }
  }

  Future<void> _handleError(Object error, StackTrace stackTrace) async {
    _log.critical('WebSocket error', error, stackTrace);
    await _teardownChannel();
    if (!_closed) {
      unawaited(_connectWithRetry());
    }
  }

  Future<void> _handleDone() async {
    _log.warning('WebSocket connection closed.');
    await _teardownChannel();
    if (!_closed) {
      unawaited(_connectWithRetry());
    }
  }

  Future<void> _teardownChannel() async {
    _keepAlive?.cancel();
    _keepAlive = null;
    await _subscription?.cancel();
    _subscription = null;
    _channel = null;
  }

  void _startKeepAlive() {
    _keepAlive?.cancel();
    _keepAlive = Timer.periodic(config.keepAliveInterval, (_) {
      try {
        _channel?.sink.add(jsonEncode({'MessageType': 'KeepAlive'}));
      } catch (error) {
        _log.warning('Failed to send keep-alive: $error');
      }
    });
  }

  JellyfinSocketMessage? _decodeMessage(dynamic payload) {
    Map<String, dynamic>? decoded;
    if (payload is List<int>) {
      decoded = jsonDecode(utf8.decode(payload)) as Map<String, dynamic>?;
    } else if (payload is String) {
      decoded = jsonDecode(payload) as Map<String, dynamic>?;
    }
    if (decoded == null) {
      _log.critical('Dropping non-JSON message: $payload');
      return null;
    }
    final type = decoded['MessageType']?.toString();
    if (type == null) {
      _log.critical('Message without MessageType: $decoded');
      return null;
    }
    return JellyfinSocketMessage(type: type, rawData: decoded['Data']);
  }
}

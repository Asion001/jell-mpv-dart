import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:retry/retry.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'config.dart';
import 'models.dart';

class JellyfinWebSocket {
  JellyfinWebSocket(this.config)
    : _retry = RetryOptions(
        maxAttempts: 8,
        delayFactor: config.startupReconnectBackoff,
      );

  final JellyfinConfig config;
  final _log = Logger('JellyfinWebSocket');
  final _controller = StreamController<JellyfinSocketMessage>.broadcast();
  final RetryOptions _retry;

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
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
      _log.severe('Failed to decode WebSocket message', error, stackTrace);
    }
  }

  void _handleError(Object error, StackTrace stackTrace) {
    _log.severe('WebSocket error', error, stackTrace);
    _teardownChannel();
    if (!_closed) {
      unawaited(_connectWithRetry());
    }
  }

  void _handleDone() {
    _log.warning('WebSocket connection closed.');
    _teardownChannel();
    if (!_closed) {
      unawaited(_connectWithRetry());
    }
  }

  void _teardownChannel() {
    _keepAlive?.cancel();
    _keepAlive = null;
    _subscription?.cancel();
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
      _log.fine('Dropping non-JSON message: $payload');
      return null;
    }
    final type = decoded['MessageType']?.toString();
    if (type == null) {
      _log.fine('Message without MessageType: $decoded');
      return null;
    }
    return JellyfinSocketMessage(type: type, rawData: decoded['Data']);
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants.dart';
import '../local/secure_storage.dart';
import '../max/device_profile.dart';
import '../max/lz4_block.dart';
import '../max/max_codec.dart';

/// Состояние одного исходящего голосового звонка MAX.
enum MaxAudioCallPhase {
  idle,
  preparing,
  ringing,
  connecting,
  connected,
  ended,
  failed,
}

class MaxAudioCallStatus {
  const MaxAudioCallStatus({
    required this.phase,
    required this.message,
    this.muted = false,
    this.speaker = false,
  });

  final MaxAudioCallPhase phase;
  final String message;
  final bool muted;
  final bool speaker;

  MaxAudioCallStatus copyWith({
    MaxAudioCallPhase? phase,
    String? message,
    bool? muted,
    bool? speaker,
  }) {
    return MaxAudioCallStatus(
      phase: phase ?? this.phase,
      message: message ?? this.message,
      muted: muted ?? this.muted,
      speaker: speaker ?? this.speaker,
    );
  }
}

/// Результат звонка для локального журнала.
class MaxAudioCallResult {
  const MaxAudioCallResult({
    required this.startedAtMs,
    required this.durationMs,
    required this.connected,
  });

  final int startedAtMs;
  final int durationMs;
  final bool connected;
}

/// Минимальная реализация исходящего аудиозвонка в официальный MAX.
///
/// Поток:
/// 1) короткое второе MAX-соединение -> opcode 158 (call token),
/// 2) calls.okcdn.ru auth.anonymLogin,
/// 3) vchat.startConversation,
/// 4) WebSocket signaling,
/// 5) WebRTC audio (Opus / DTLS-SRTP).
///
/// Входящие звонки здесь намеренно не реализованы: сначала проверяем самый
/// маленький end-to-end сценарий «iPhone 5s -> официальный MAX».
class MaxAudioCall {
  MaxAudioCall({
    required this.peerUserId,
    required this.storage,
    required this.logger,
  });

  static const _callsEndpoint = 'https://calls.okcdn.ru/fb.do';
  static const _applicationKey = 'CNHIJPLGDIHBABABA';

  final int peerUserId;
  final SecureStorage storage;
  final Logger logger;

  final _statusController = StreamController<MaxAudioCallStatus>.broadcast();
  Stream<MaxAudioCallStatus> get statusStream => _statusController.stream;

  MaxAudioCallStatus _status = const MaxAudioCallStatus(
    phase: MaxAudioCallPhase.idle,
    message: 'Готово',
  );
  MaxAudioCallStatus get status => _status;

  WebSocket? _ws;
  StreamIterator<dynamic>? _wsIterator;
  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  http.Client? _http;

  String? _conversationId;
  String? _sessionKey;
  int? _participantId;
  int _signalSequence = 0;

  bool _disposed = false;
  bool _finished = false;
  bool _everConnected = false;
  int _startedAtMs = 0;
  int? _connectedAtMs;
  int _durationMs = 0;

  Future<void> start() async {
    if (_disposed || _status.phase != MaxAudioCallPhase.idle) return;
    _startedAtMs = DateTime.now().millisecondsSinceEpoch;
    _emit(MaxAudioCallPhase.preparing, 'Подготовка звонка…');

    try {
      final savedToken = await storage.readToken();
      if (savedToken == null || savedToken.isEmpty) {
        throw StateError('Сначала войдите в MAX');
      }
      final tokenKind = await storage.readTokenKind() ?? 'android';
      final deviceType = tokenKind == 'web' ? 'WEB' : 'ANDROID';
      final deviceId = await storage.readOrCreateDeviceId();
      final userAgent = await DeviceProfile.userAgent(deviceType);

      final tokenClient = _CallTokenClient(logger: logger);
      final callToken = await tokenClient.getCallToken(
        authToken: savedToken,
        deviceId: deviceId,
        userAgent: userAgent,
      );

      _http = http.Client();
      final login = await _callApi(<String, String>{
        'method': 'auth.anonymLogin',
        'format': 'JSON',
        'application_key': _applicationKey,
        'session_data': jsonEncode(<String, Object?>{
          'auth_token': callToken,
          'client_type': 'SDK_JS',
          'client_version': '1.1',
          'device_id': deviceId,
          'version': 3,
        }),
      });

      final sessionKey = login['session_key']?.toString();
      if (sessionKey == null || sessionKey.isEmpty) {
        throw StateError('MAX не выдал session_key для звонка');
      }
      _sessionKey = sessionKey;

      final conversationId = const Uuid().v4();
      _conversationId = conversationId;
      final start = await _callApi(<String, String>{
        'method': 'vchat.startConversation',
        'format': 'JSON',
        'application_key': _applicationKey,
        'conversationId': conversationId,
        'isVideo': 'false',
        'protocolVersion': '5',
        'payload': jsonEncode(const <String, Object?>{'is_video': false}),
        'externalIds': '$peerUserId',
        'session_key': sessionKey,
      });

      _emit(MaxAudioCallPhase.ringing, 'Вызов…');

      final endpoint = start['endpoint']?.toString();
      if (endpoint == null || endpoint.isEmpty) {
        throw StateError('MAX не выдал signaling endpoint');
      }

      final wsUri = _outgoingSignalingUri(Uri.parse(endpoint));
      final ws = await WebSocket.connect(wsUri.toString())
          .timeout(const Duration(seconds: 20));
      _ws = ws;
      final iterator = StreamIterator<dynamic>(ws);
      _wsIterator = iterator;

      final hello = await _readServerHello(iterator)
          .timeout(const Duration(seconds: 20));
      _participantId = _findPeerParticipantId(hello, peerUserId);
      if (_participantId == null) {
        throw StateError('Собеседник не найден в signaling-сессии');
      }

      await _preparePeerConnection(start, hello);
      _emit(MaxAudioCallPhase.connecting, 'Соединение…');

      // После ServerHello весь дальнейший signaling читает один цикл.
      unawaited(_readSignalingLoop(iterator));

      final offer = await _pc!.createOffer(<String, dynamic>{
        'mandatory': <String, dynamic>{
          'OfferToReceiveAudio': true,
          'OfferToReceiveVideo': false,
        },
        'optional': <dynamic>[],
      });
      await _pc!.setLocalDescription(offer);
      await _sendSignal(<String, Object?>{
        'sdp': <String, Object?>{
          'type': offer.type,
          'sdp': offer.sdp,
        },
      });
    } catch (e, st) {
      logger.e('MAX audio call failed', error: e, stackTrace: st);
      if (!_finished) {
        _emit(MaxAudioCallPhase.failed, _friendlyError(e));
      }
      await _cleanupMedia();
    }
  }

  Uri _outgoingSignalingUri(Uri base) {
    final q = <String, String>{
      ...base.queryParameters,
      'deviceIdx': '0',
      'platform': 'WEB',
      'appVersion': '1.1',
      'version': '5',
      'device': 'browser',
      'capabilities': '603F',
      'clientType': 'ONE_ME',
      'tgt': 'start',
    };
    return base.replace(queryParameters: q);
  }

  Future<Map<String, dynamic>> _readServerHello(
    StreamIterator<dynamic> iterator,
  ) async {
    while (await iterator.moveNext()) {
      final raw = iterator.current;
      if (raw is String && raw == 'ping') {
        _ws?.add('pong');
        continue;
      }
      if (raw is! String) continue;
      final decoded = _tryJson(raw);
      if (decoded == null) continue;
      if (decoded['type'] == 'error') {
        throw StateError(decoded['message']?.toString() ?? 'signaling error');
      }
      if (decoded['notification'] == 'connection') return decoded;
    }
    throw StateError('Signaling закрыт до ServerHello');
  }

  int? _findPeerParticipantId(Map<String, dynamic> hello, int externalId) {
    final conversation = hello['conversation'];
    if (conversation is! Map) return null;
    final participants = conversation['participants'];
    if (participants is! List) return null;
    for (final item in participants) {
      if (item is! Map) continue;
      final external = item['externalId'];
      if (external is! Map) continue;
      if (external['id']?.toString() != '$externalId') continue;
      final id = item['id'];
      if (id is num) return id.toInt();
      return int.tryParse(id?.toString() ?? '');
    }
    return null;
  }

  Future<void> _preparePeerConnection(
    Map<String, dynamic> start,
    Map<String, dynamic> hello,
  ) async {
    final iceServers = <Map<String, dynamic>>[];

    Map<String, dynamic>? turn;
    Map<String, dynamic>? stun;
    final cp = hello['conversationParams'];
    if (cp is Map) {
      if (cp['turn'] is Map) turn = _stringMap(cp['turn'] as Map);
      if (cp['stun'] is Map) stun = _stringMap(cp['stun'] as Map);
    }
    if (turn == null && start['turn_server'] is Map) {
      turn = _stringMap(start['turn_server'] as Map);
    }
    if (stun == null && start['stun_server'] is Map) {
      stun = _stringMap(start['stun_server'] as Map);
    }

    if (turn != null) {
      iceServers.add(<String, dynamic>{
        'urls': turn['urls'],
        'username': turn['username'],
        'credential': turn['credential'],
      });
    }
    if (stun != null) {
      iceServers.add(<String, dynamic>{'urls': stun['urls']});
    }

    try {
      await Helper.ensureAudioSession();
    } catch (e) {
      logger.d('ensureAudioSession: $e');
    }

    _localStream = await navigator.mediaDevices.getUserMedia(<String, dynamic>{
      'audio': true,
      'video': false,
    });

    final pc = await createPeerConnection(<String, dynamic>{
      'iceServers': iceServers,
      'sdpSemantics': 'unified-plan',
    });
    _pc = pc;

    for (final track in _localStream!.getAudioTracks()) {
      await pc.addTrack(track, _localStream!);
    }

    pc.onIceCandidate = (candidate) {
      final value = candidate.candidate;
      if (value == null || value.isEmpty || _finished) return;
      final ufrag = _candidateUfrag(value);
      unawaited(_sendSignal(<String, Object?>{
        'candidate': <String, Object?>{
          'candidate': value,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
          if (ufrag != null) 'usernameFragment': ufrag,
        },
      }));
    };

    pc.onIceConnectionState = (state) {
      final s = state.toString().toLowerCase();
      if (s.contains('connected') || s.contains('completed')) {
        _markConnected();
      } else if (s.contains('failed')) {
        _emit(MaxAudioCallPhase.failed, 'Не удалось установить аудиосвязь');
      }
    };

    pc.onConnectionState = (state) {
      final s = state.toString().toLowerCase();
      if (s.contains('connected')) {
        _markConnected();
      } else if (s.contains('failed')) {
        _emit(MaxAudioCallPhase.failed, 'WebRTC-соединение не установлено');
      }
    };
  }

  Future<void> _readSignalingLoop(StreamIterator<dynamic> iterator) async {
    try {
      while (!_finished && await iterator.moveNext()) {
        final raw = iterator.current;
        if (raw is String && raw == 'ping') {
          _ws?.add('pong');
          continue;
        }
        if (raw is! String) continue;
        final msg = _tryJson(raw);
        if (msg == null) continue;

        if (msg['notification'] == 'transmitted-data') {
          final data = msg['data'];
          if (data is Map) await _handleRemoteSignal(_stringMap(data));
          continue;
        }

        final notification = msg['notification']?.toString();
        if (notification == 'hungup' || notification == 'closed-conversation') {
          await _finishRemote();
          return;
        }
        if (msg['type'] == 'error' &&
            msg['message']?.toString() == 'conversation-ended') {
          await _finishRemote();
          return;
        }
      }
      if (!_finished) await _finishRemote();
    } catch (e, st) {
      logger.w('signaling loop failed', error: e, stackTrace: st);
      if (!_finished) {
        _emit(MaxAudioCallPhase.failed, 'Сигналинг звонка прерван');
        await _cleanupMedia();
      }
    }
  }

  Future<void> _handleRemoteSignal(Map<String, dynamic> data) async {
    final sdp = data['sdp'];
    if (sdp is Map) {
      final type = sdp['type']?.toString();
      final value = sdp['sdp']?.toString();
      if (type != null && value != null) {
        await _pc?.setRemoteDescription(RTCSessionDescription(value, type));
      }
    }

    final candidate = data['candidate'];
    if (candidate is Map) {
      final value = candidate['candidate']?.toString();
      if (value != null && value.isNotEmpty) {
        final index = candidate['sdpMLineIndex'];
        await _pc?.addCandidate(RTCIceCandidate(
          value,
          candidate['sdpMid']?.toString(),
          index is num ? index.toInt() : int.tryParse('$index'),
        ));
      }
    }
  }

  Future<void> _sendSignal(Map<String, Object?> data) async {
    final ws = _ws;
    final participantId = _participantId;
    if (ws == null || participantId == null || _finished) return;
    _signalSequence++;
    ws.add(jsonEncode(<String, Object?>{
      'command': 'transmit-data',
      'sequence': _signalSequence,
      'participantId': participantId,
      'data': data,
      'participantType': 'USER',
    }));
  }

  void _markConnected() {
    if (_finished || _everConnected) return;
    _everConnected = true;
    _connectedAtMs = DateTime.now().millisecondsSinceEpoch;
    _emit(MaxAudioCallPhase.connected, 'Соединено');
  }

  Future<void> setMuted(bool muted) async {
    for (final track in _localStream?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      track.enabled = !muted;
    }
    _status = _status.copyWith(muted: muted);
    _publish();
  }

  Future<void> setSpeaker(bool speaker) async {
    await Helper.setSpeakerphoneOn(speaker);
    _status = _status.copyWith(speaker: speaker);
    _publish();
  }

  Future<MaxAudioCallResult> hangUp() async {
    if (!_finished) {
      await _hangupApi('HUNGUP');
      _finishDuration();
      _finished = true;
      _emit(MaxAudioCallPhase.ended, 'Звонок завершён');
      await _cleanupMedia();
    }
    return result;
  }

  Future<void> _finishRemote() async {
    if (_finished) return;
    _finishDuration();
    _finished = true;
    _emit(MaxAudioCallPhase.ended, 'Собеседник завершил звонок');
    await _cleanupMedia();
  }

  void _finishDuration() {
    final connectedAt = _connectedAtMs;
    if (connectedAt != null) {
      _durationMs = DateTime.now().millisecondsSinceEpoch - connectedAt;
    }
  }

  MaxAudioCallResult get result => MaxAudioCallResult(
        startedAtMs: _startedAtMs,
        durationMs: _durationMs,
        connected: _everConnected,
      );

  Future<void> _hangupApi(String reason) async {
    final conversationId = _conversationId;
    final sessionKey = _sessionKey;
    if (conversationId == null || sessionKey == null) return;
    try {
      await _callApi(<String, String>{
        'method': 'vchat.hangupConversation',
        'format': 'JSON',
        'application_key': _applicationKey,
        'conversationId': conversationId,
        'session_key': sessionKey,
        'reason': reason,
      });
    } catch (e) {
      logger.d('hangup API ignored: $e');
    }
  }

  Future<Map<String, dynamic>> _callApi(Map<String, String> form) async {
    final client = _http ??= http.Client();
    final response = await client
        .post(Uri.parse(_callsEndpoint), body: form)
        .timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('calls API HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) throw const FormatException('calls API: not an object');
    final map = decoded.map((k, v) => MapEntry(k.toString(), v));
    final error = map['error_msg'] ?? map['error'] ?? map['message'];
    if (map['error_code'] != null ||
        (error != null && map['session_key'] == null && map['endpoint'] == null)) {
      // У некоторых успешных методов есть служебные message-поля, поэтому
      // error без error_code считаем ошибкой лишь когда отсутствуют ожидаемые
      // ключи успеха. Пустой {} у hangup допустим.
      if (map.isNotEmpty) throw StateError('MAX calls API: $error');
    }
    return map;
  }

  Future<void> _cleanupMedia() async {
    final wsIterator = _wsIterator;
    _wsIterator = null;
    try {
      await wsIterator?.cancel();
    } catch (_) {}
    try {
      await _ws?.close();
    } catch (_) {}
    _ws = null;

    final pc = _pc;
    _pc = null;
    try {
      await pc?.close();
      await pc?.dispose();
    } catch (_) {}

    final local = _localStream;
    _localStream = null;
    if (local != null) {
      for (final track in local.getTracks()) {
        try {
          await track.stop();
        } catch (_) {}
      }
      try {
        await local.dispose();
      } catch (_) {}
    }

    try {
      await Helper.setSpeakerphoneOn(false);
    } catch (_) {}
    _http?.close();
    _http = null;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (!_finished && _status.phase != MaxAudioCallPhase.idle) {
      await _hangupApi(_everConnected ? 'HUNGUP' : 'CANCELED');
      _finishDuration();
      _finished = true;
    }
    await _cleanupMedia();
    await _statusController.close();
  }

  void _emit(MaxAudioCallPhase phase, String message) {
    _status = _status.copyWith(phase: phase, message: message);
    _publish();
  }

  void _publish() {
    if (!_statusController.isClosed) _statusController.add(_status);
  }

  static Map<String, dynamic>? _tryJson(String raw) {
    try {
      final d = jsonDecode(raw);
      if (d is Map) return d.map((k, v) => MapEntry(k.toString(), v));
    } catch (_) {}
    return null;
  }

  static Map<String, dynamic> _stringMap(Map<dynamic, dynamic> m) =>
      m.map((k, v) => MapEntry(k.toString(), v));

  static String? _candidateUfrag(String candidate) {
    final m = RegExp(r'(?:^|\s)ufrag\s+([^\s]+)').firstMatch(candidate);
    return m?.group(1);
  }

  static String _friendlyError(Object e) {
    final s = e.toString();
    if (s.contains('Permission') || s.contains('permission')) {
      return 'Нет доступа к микрофону';
    }
    if (s.contains('timeout') || s.contains('Timeout')) {
      return 'Сервер MAX не ответил вовремя';
    }
    return s.replaceFirst('Bad state: ', '').replaceFirst('StateError: ', '');
  }
}

/// Одноразовый транспорт только для получения opcode 158.
/// Использует тот же auth-token и стабильный deviceId, но не вмешивается в
/// основной MaxClient приложения и не запускает reconnect/keepalive.
class _CallTokenClient {
  _CallTokenClient({required this.logger});

  final Logger logger;
  SecureSocket? _socket;
  StreamSubscription<Uint8List>? _subscription;
  final _buffer = BytesBuilder(copy: false);
  final _pending = <int, Completer<MaxFrame>>{};
  int _seq = 0;

  Future<String> getCallToken({
    required String authToken,
    required String deviceId,
    required Map<String, Object?> userAgent,
  }) async {
    try {
      final socket = await SecureSocket.connect(
        MaxProto.host,
        MaxProto.port,
        timeout: const Duration(seconds: 15),
      );
      socket.setOption(SocketOption.tcpNoDelay, true);
      _socket = socket;
      _subscription = socket.listen(
        _onData,
        onError: _onError,
        onDone: _onDone,
        cancelOnError: false,
      );

      var frame = await _request(6, <String, Object?>{
        'userAgent': userAgent,
        'deviceId': deviceId,
      });
      if (frame.cmd != 1) throw StateError('INIT cmd=${frame.cmd}');

      frame = await _request(19, <String, Object?>{
        'token': authToken,
        'interactive': false,
        'chatsCount': 40,
        'chatsSync': 0,
        'contactsSync': 0,
        'presenceSync': 0,
        'draftsSync': 0,
      });
      if (frame.cmd != 1) throw StateError('LOGIN cmd=${frame.cmd}');

      frame = await _request(158, const <String, Object?>{});
      if (frame.cmd != 1) throw StateError('CALL_TOKEN cmd=${frame.cmd}');
      final d = frame.decoded;
      if (d is Map) {
        final token = d['token']?.toString();
        if (token != null && token.startsWith(r'$')) return token;
      }
      throw StateError('Call token отсутствует в ответе MAX');
    } finally {
      await _close();
    }
  }

  Future<MaxFrame> _request(int opcode, Map<String, Object?> payload) async {
    final socket = _socket;
    if (socket == null) throw StateError('MAX socket is null');
    final seq = _seq;
    _seq = (_seq + 1) & 0xffff;
    final completer = Completer<MaxFrame>();
    _pending[seq] = completer;
    socket.add(MaxCodec.frame(seq: seq, opcode: opcode, payload: payload));
    await socket.flush();
    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _pending.remove(seq);
        throw TimeoutException('MAX opcode $opcode timeout');
      },
    );
  }

  void _onData(Uint8List chunk) {
    _buffer.add(chunk);
    while (true) {
      final buf = _buffer.toBytes();
      if (buf.length < 10) {
        _buffer
          ..clear()
          ..add(buf);
        return;
      }
      final cmd = buf[1];
      final seq = (buf[2] << 8) | buf[3];
      final opcode = (buf[4] << 8) | buf[5];
      final lenRaw =
          (buf[6] << 24) | (buf[7] << 16) | (buf[8] << 8) | buf[9];
      final compression = (lenRaw >> 24) & 0xff;
      final payloadLen = lenRaw & 0x00ffffff;
      final total = 10 + payloadLen;
      if (buf.length < total) {
        _buffer
          ..clear()
          ..add(buf);
        return;
      }

      final rawBody = Uint8List.sublistView(buf, 10, total);
      Uint8List body;
      if (compression == 0) {
        body = rawBody;
      } else if (compression == 0xff) {
        _failAll(StateError('zstd response is not supported'));
        return;
      } else {
        body = Lz4Block.decompress(rawBody, payloadLen * compression);
      }
      final frame = MaxFrame(
        cmd: cmd,
        seq: seq,
        opcode: opcode,
        body: body,
        decoded: MaxCodec.tryUnpack(body),
      );

      _buffer.clear();
      if (buf.length > total) _buffer.add(Uint8List.sublistView(buf, total));
      final waiter = _pending.remove(seq);
      if (waiter != null && !waiter.isCompleted) waiter.complete(frame);
    }
  }

  void _onError(Object error, StackTrace stackTrace) {
    logger.d('call-token socket error: $error');
    _failAll(error);
  }

  void _onDone() => _failAll(StateError('call-token socket closed'));

  void _failAll(Object error) {
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(error);
    }
    _pending.clear();
  }

  Future<void> _close() async {
    await _subscription?.cancel();
    _subscription = null;
    try {
      await _socket?.close();
    } catch (_) {}
    _socket = null;
    _failAll(StateError('call-token client closed'));
  }
}

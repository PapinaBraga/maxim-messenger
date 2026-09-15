from pathlib import Path

p = Path('lib/data/calls/max_audio_call.dart')
text = p.read_text()


def replace_once(old: str, new: str, label: str) -> None:
    global text
    if old not in text:
        raise SystemExit(f'{label} not found')
    text = text.replace(old, new, 1)


replace_once(
    """      final ws = await WebSocket.connect(wsUri.toString())
          .timeout(const Duration(seconds: 20));""",
    """      final ws = await WebSocket.connect(
        wsUri.toString(),
        headers: const <String, dynamic>{'Origin': 'https://web.max.ru'},
      ).timeout(const Duration(seconds: 20));""",
    'WebSocket connect block',
)

replace_once(
    """      _participantId = _findPeerParticipantId(hello, peerUserId);
      if (_participantId == null) {
        throw StateError('Собеседник не найден в signaling-сессии');
      }

      await _preparePeerConnection(start, hello);""",
    """      _participantId = _findPeerParticipantId(hello, peerUserId);
      if (_participantId == null) {
        throw StateError('Собеседник не найден в signaling-сессии');
      }
      final peerState = _findPeerParticipantState(hello, peerUserId) ?? 'UNKNOWN';
      final participantCount = _participantCount(hello);

      await _preparePeerConnection(start, hello);""",
    'peer lookup block',
)

replace_once(
    """    pc.onIceCandidate = (candidate) {
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
    };""",
    """    pc.onIceCandidate = (candidate) {
      if (_finished) return;
      final value = candidate.candidate;
      if (value == null || value.isEmpty) {
        unawaited(_sendSignal(const <String, Object?>{'Candidate': ''}));
        return;
      }
      unawaited(_sendSignal(<String, Object?>{'Candidate': value}));
    };""",
    'ICE candidate block',
)

replace_once(
    """      final offer = await _pc!.createOffer(<String, dynamic>{
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
      });""",
    """      final offer = await _pc!.createOffer(<String, dynamic>{
        'mandatory': <String, dynamic>{
          'OfferToReceiveAudio': true,
          'OfferToReceiveVideo': false,
        },
        'optional': <dynamic>[],
      });
      await _pc!.setLocalDescription(offer);

      final localDescription = await _pc!.getLocalDescription();
      final localSdp = localDescription?.sdp ?? offer.sdp ?? '';
      final ufrag = _sdpAttribute(localSdp, 'ice-ufrag');
      final password = _sdpAttribute(localSdp, 'ice-pwd');
      if (ufrag == null || password == null) {
        throw StateError('Не удалось получить ICE credentials');
      }
      await _sendSignal(<String, Object?>{
        'UFrag': ufrag,
        'Password': password,
      });
      _emit(
        MaxAudioCallPhase.ringing,
        'MAX: peer=$peerUserId, state=$peerState, participants=$participantCount\\nВызов отправлен…',
      );""",
    'offer block',
)

participant_marker = """  int? _findPeerParticipantId(Map<String, dynamic> hello, int externalId) {
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
"""
participant_helpers = participant_marker + """

  String? _findPeerParticipantState(
    Map<String, dynamic> hello,
    int externalId,
  ) {
    final conversation = hello['conversation'];
    if (conversation is! Map) return null;
    final participants = conversation['participants'];
    if (participants is! List) return null;
    for (final item in participants) {
      if (item is! Map) continue;
      final external = item['externalId'];
      if (external is! Map) continue;
      if (external['id']?.toString() != '$externalId') continue;
      return item['state']?.toString();
    }
    return null;
  }

  int _participantCount(Map<String, dynamic> hello) {
    final conversation = hello['conversation'];
    if (conversation is! Map) return 0;
    final participants = conversation['participants'];
    return participants is List ? participants.length : 0;
  }
"""
replace_once(participant_marker, participant_helpers, 'participant helper insertion point')

candidate_helper = """  static String? _candidateUfrag(String candidate) {
    final m = RegExp(r'(?:^|\\s)ufrag\\s+([^\\s]+)').firstMatch(candidate);
    return m?.group(1);
  }
"""
sdp_helper = candidate_helper + """

  static String? _sdpAttribute(String sdp, String name) {
    final m = RegExp(
      '^a=' + RegExp.escape(name) + r':([^\\r\\n]+)',
      multiLine: true,
    ).firstMatch(sdp);
    return m?.group(1)?.trim();
  }
"""
replace_once(candidate_helper, sdp_helper, 'SDP helper insertion point')

p.write_text(text)

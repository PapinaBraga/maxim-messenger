import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/calls/max_audio_call.dart';
import '../../state/providers.dart';

class AudioCallScreen extends ConsumerStatefulWidget {
  const AudioCallScreen({
    super.key,
    required this.peerUserId,
    required this.peerName,
  });

  final int peerUserId;
  final String peerName;

  @override
  ConsumerState<AudioCallScreen> createState() => _AudioCallScreenState();
}

class _AudioCallScreenState extends ConsumerState<AudioCallScreen> {
  late final MaxAudioCall _call;
  StreamSubscription<MaxAudioCallStatus>? _subscription;
  Timer? _clock;

  MaxAudioCallStatus _status = const MaxAudioCallStatus(
    phase: MaxAudioCallPhase.preparing,
    message: 'Подготовка звонка…',
  );
  int _elapsedSeconds = 0;
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    _call = MaxAudioCall(
      peerUserId: widget.peerUserId,
      storage: ref.read(secureStorageProvider),
      logger: ref.read(loggerProvider),
    );
    _subscription = _call.statusStream.listen((status) {
      if (!mounted) return;
      setState(() => _status = status);
      if (status.phase == MaxAudioCallPhase.connected && _clock == null) {
        _clock = Timer.periodic(const Duration(seconds: 1), (_) {
          if (mounted) setState(() => _elapsedSeconds++);
        });
      }
      if (status.phase == MaxAudioCallPhase.ended ||
          status.phase == MaxAudioCallPhase.failed) {
        _clock?.cancel();
        _clock = null;
      }
    });
    unawaited(_call.start());
  }

  @override
  void dispose() {
    _clock?.cancel();
    _subscription?.cancel();
    unawaited(_call.dispose());
    super.dispose();
  }

  Future<bool> _onWillPop() async {
    await _leave();
    return false;
  }

  Future<void> _leave() async {
    if (_leaving) return;
    _leaving = true;
    MaxAudioCallResult result;
    if (_status.phase == MaxAudioCallPhase.ended ||
        _status.phase == MaxAudioCallPhase.failed) {
      result = _call.result;
    } else {
      result = await _call.hangUp();
    }
    if (!mounted) return;
    Navigator.of(context).pop(result);
  }

  Future<void> _toggleMute() async {
    try {
      await _call.setMuted(!_status.muted);
    } catch (e) {
      _showError('Не удалось переключить микрофон: $e');
    }
  }

  Future<void> _toggleSpeaker() async {
    try {
      await _call.setSpeaker(!_status.speaker);
    } catch (e) {
      _showError('Не удалось переключить динамик: $e');
    }
  }

  void _showError(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  String get _initial {
    final name = widget.peerName.trim();
    return name.isEmpty ? '?' : name.characters.first.toUpperCase();
  }

  String get _timeText {
    if (_status.phase != MaxAudioCallPhase.connected && _elapsedSeconds == 0) {
      return _status.message;
    }
    final minutes = _elapsedSeconds ~/ 60;
    final seconds = _elapsedSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  bool get _controlsEnabled =>
      _status.phase == MaxAudioCallPhase.ringing ||
      _status.phase == MaxAudioCallPhase.connecting ||
      _status.phase == MaxAudioCallPhase.connected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final finished = _status.phase == MaxAudioCallPhase.ended ||
        _status.phase == MaxAudioCallPhase.failed;

    return WillPopScope(
      onWillPop: _onWillPop,
      child: Scaffold(
        backgroundColor: scheme.surface,
        body: SafeArea(
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  tooltip: 'Назад',
                  onPressed: _leave,
                  icon: const Icon(Icons.keyboard_arrow_down, size: 32),
                ),
              ),
              const Spacer(flex: 2),
              CircleAvatar(
                radius: 58,
                backgroundColor: scheme.primaryContainer,
                foregroundColor: scheme.onPrimaryContainer,
                child: Text(
                  _initial,
                  style: const TextStyle(
                    fontSize: 44,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  widget.peerName,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _timeText,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: _status.phase == MaxAudioCallPhase.failed
                          ? scheme.error
                          : scheme.onSurfaceVariant,
                    ),
              ),
              const Spacer(flex: 3),
              if (!finished)
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _RoundControl(
                      icon: _status.muted ? Icons.mic_off : Icons.mic_none,
                      label: 'Микрофон',
                      selected: _status.muted,
                      enabled: _controlsEnabled,
                      onPressed: _toggleMute,
                    ),
                    _RoundControl(
                      icon: _status.speaker
                          ? Icons.volume_up
                          : Icons.volume_down,
                      label: 'Динамик',
                      selected: _status.speaker,
                      enabled: _controlsEnabled,
                      onPressed: _toggleSpeaker,
                    ),
                  ],
                ),
              const SizedBox(height: 38),
              if (finished)
                FilledButton.icon(
                  onPressed: _leave,
                  icon: const Icon(Icons.close),
                  label: const Text('Закрыть'),
                )
              else
                FloatingActionButton.large(
                  heroTag: 'hangup',
                  backgroundColor: scheme.error,
                  foregroundColor: scheme.onError,
                  onPressed: _leave,
                  child: const Icon(Icons.call_end, size: 34),
                ),
              const Spacer(flex: 2),
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  'Аудиозвонок MAX',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoundControl extends StatelessWidget {
  const _RoundControl({
    required this.icon,
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Material(
          color: selected
              ? scheme.primaryContainer
              : scheme.surfaceContainerHighest,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: enabled ? onPressed : null,
            child: SizedBox(
              width: 70,
              height: 70,
              child: Icon(
                icon,
                size: 30,
                color: enabled
                    ? scheme.onSurface
                    : scheme.onSurface.withOpacity(0.35),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(label),
      ],
    );
  }
}

import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_toast.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:prysm/models/chat/prysm_message.dart';
import 'package:prysm/ui/chat/prysm_chat_message_list.dart';
import 'package:path_provider/path_provider.dart';
import 'package:prysm/screens/widgets/voice_waveform_scrubber.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/services/voice_transcription_service.dart';
import 'package:prysm/util/stt_model_manager.dart';
import 'package:prysm/util/voice_playback_coordinator.dart';
import 'package:prysm/util/voice_player.dart';
import 'package:prysm/util/waveform_extractor.dart';
import 'package:prysm/ui/chat/prysm_bubble_renderer.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm/ui/core/prysm_divider.dart';
import 'package:prysm/ui/core/prysm_progress.dart';
import 'package:prysm/ui/core/prysm_linear_progress.dart';

/// Shared voice message bubble with waveform scrubbing (1:1 and group chats).
class VoiceMessageBubble extends StatefulWidget {
  final FileMessage message;
  final bool isSentByMe;
  final String timeString;
  final Widget tickWidget;

  /// Decrypt encrypted audio payload to WAV bytes (1:1 received messages).
  final Future<Uint8List?> Function(String encryptedSource)? decryptAudio;

  const VoiceMessageBubble({
    required this.message,
    required this.isSentByMe,
    required this.timeString,
    required this.tickWidget,
    this.decryptAudio,
    super.key,
  });

  @override
  State<VoiceMessageBubble> createState() => _VoiceMessageBubbleState();
}

class _VoiceMessageBubbleState extends State<VoiceMessageBubble> {
  late final VoicePlayer _player;
  bool _isPlaying = false;
  bool _isLoading = false;
  bool _hasCompleted = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  List<double> _peaks = const [];
  String? _resolvedPath;
  Uint8List? _audioBytes;
  double? _scrubFraction;
  String? _cachedTranscript;
  bool _showTranscript = false;
  bool _isTranscribing = false;
  bool _batterySavingHintShown = false;

  bool get _sttSupported =>
      !kIsWeb && VoiceTranscriptionService.instance.isSupported;

  @override
  void initState() {
    super.initState();
    _player = createVoicePlayer();
    VoicePlaybackCoordinator.instance;

    _loadDurationFromSource();
    _loadPeaksFromMetadata();
    _syncDurationToPlayer();
    if (_sttSupported) {
      unawaited(_loadCachedTranscript());
    }

    _player.playingStream.listen((playing) {
      if (!mounted) return;
      setState(() => _isPlaying = playing);
    });
    _player.positionStream.listen((pos) {
      if (!mounted || _scrubFraction != null) return;
      setState(() => _position = pos);
    });
    _player.durationStream.listen((dur) {
      if (!mounted || dur <= Duration.zero) return;
      setState(() => _duration = dur);
    });
    _player.completeStream.listen((_) {
      if (!mounted) return;
      setState(() {
        _isPlaying = false;
        _hasCompleted = true;
        _position = Duration.zero;
        _scrubFraction = null;
      });
    });

    unawaited(_prepareWaveform());
  }

  Future<void> _loadCachedTranscript() async {
    final cached = await VoiceTranscriptionService.instance
        .getCachedTranscript(widget.message.id);
    if (!mounted || cached == null) return;
    setState(() {
      _cachedTranscript = cached;
    });
  }

  Future<void> _onTranscribeTap() async {
    if (!_sttSupported) return;

    if (!SettingsService().enableVoiceTranscription) {
      if (mounted) {
        showPrysmToast(context, 
              'Enable Voice transcription in Settings → Data to transcribe locally',
            );
      }
      return;
    }

    if (_cachedTranscript != null) {
      setState(() => _showTranscript = !_showTranscript);
      return;
    }

    if (_isTranscribing) return;

    if (SettingsService().enableBatterySaving && !_batterySavingHintShown) {
      _batterySavingHintShown = true;
      if (mounted) {
        showPrysmToast(context, 
              'Transcription uses extra CPU while battery saving is on',
            );
      }
    }

    setState(() => _isTranscribing = true);
    try {
      final wavPath = await _resolvePath();
      if (wavPath == null) {
        if (mounted) {
          showPrysmToast(context, 'Voice message cache expired');
        }
        return;
      }

      final transcript = await VoiceTranscriptionService.instance.transcribe(
        messageId: widget.message.id,
        wavPath: wavPath,
      );

      if (!mounted) return;
      if (transcript == null || transcript.isEmpty) {
        showPrysmToast(context, 'Could not transcribe voice message');
        return;
      }

      setState(() {
        _cachedTranscript = transcript;
        _showTranscript = true;
      });
    } on VoiceTranscriptionException catch (e) {
      if (mounted) {
        showPrysmToast(context, e.message);
      }
    } catch (err) {
      debugPrint('Voice transcription error: $err');
      if (mounted) {
        showPrysmToast(context, 'Failed to transcribe voice message');
      }
    } finally {
      if (mounted) setState(() => _isTranscribing = false);
    }
  }

  void _syncDurationToPlayer() {
    if (_duration > Duration.zero) {
      _player.setExpectedDuration(_duration);
    }
  }

  void _loadDurationFromSource() {
    if (!widget.message.source.startsWith('audio:')) return;
    final parts = widget.message.source.split(':');
    if (parts.length >= 2) {
      final ms = int.tryParse(parts[1]) ?? 0;
      if (ms > 0) {
        _duration = Duration(milliseconds: ms);
      }
    }
  }

  void _loadPeaksFromMetadata() {
    final meta = widget.message.metadata;
    if (meta == null) return;
    final encoded = meta['waveform'] as String?;
    final decoded = WaveformExtractor.decodePeaks(encoded);
    if (decoded != null && decoded.isNotEmpty) {
      _peaks = decoded;
    }
  }

  Future<void> _prepareWaveform() async {
    final bytes = await _loadWavBytes();
    if (bytes == null || !mounted) return;
    setState(() {
      _peaks = WaveformExtractor.extractPeaks(bytes);
      if (_duration == Duration.zero) {
        final ms = WaveformExtractor.estimateDurationMs(bytes);
        if (ms > 0) {
          _duration = Duration(milliseconds: ms);
          _syncDurationToPlayer();
        }
      }
    });
  }

  Future<Uint8List?> _loadWavBytes() async {
    if (_audioBytes != null && _audioBytes!.isNotEmpty) {
      return _audioBytes;
    }

    if (widget.message.source.startsWith('audio:')) {
      final parts = widget.message.source.split(':');
      if (parts.length >= 3) {
        final filePath = parts.sublist(2).join(':');
        final file = File(filePath);
        if (await file.exists()) {
          _audioBytes = await file.readAsBytes();
          return _audioBytes;
        }
      }
      return null;
    }

    if (widget.decryptAudio != null) {
      _audioBytes = await widget.decryptAudio!(widget.message.source);
      return _audioBytes;
    }
    return null;
  }

  Future<String?> _resolvePath() async {
    if (_resolvedPath != null) return _resolvedPath;

    if (widget.message.source.startsWith('audio:')) {
      final parts = widget.message.source.split(':');
      if (parts.length >= 3) {
        final filePath = parts.sublist(2).join(':');
        if (await File(filePath).exists()) {
          _resolvedPath = filePath;
          return _resolvedPath;
        }
      }
      return null;
    }

    final bytes = await _loadWavBytes();
    if (bytes == null || bytes.isEmpty) return null;

    if (_duration == Duration.zero) {
      final ms = WaveformExtractor.estimateDurationMs(bytes);
      if (ms > 0) {
        _duration = Duration(milliseconds: ms);
        _syncDurationToPlayer();
      }
    }

    final dir = await getTemporaryDirectory();
    final ext = widget.message.name.split('.').last;
    final tmpFile = File('${dir.path}/voice_${widget.message.id}.$ext');
    await tmpFile.writeAsBytes(bytes);
    _resolvedPath = tmpFile.path;
    return _resolvedPath;
  }

  Future<void> _seekTo(Duration position) async {
    var clamped = position;
    if (_duration > Duration.zero && clamped > _duration) {
      clamped = _duration;
    }
    if (clamped.isNegative) clamped = Duration.zero;

    await _player.seek(clamped);
    if (mounted) {
      setState(() {
        _position = clamped;
        _scrubFraction = null;
        _hasCompleted = false;
      });
    }
  }

  Future<void> _seekToFraction(double fraction) async {
    if (_duration <= Duration.zero) return;
    final ms = (fraction * _duration.inMilliseconds).round();
    await _seekTo(Duration(milliseconds: ms));
  }

  Future<void> _playFromFile() async {
    final playPath = await _resolvePath();
    if (playPath == null) {
      if (mounted) {
        showPrysmToast(context, 'Voice message cache expired');
      }
      return;
    }

    await VoicePlaybackCoordinator.instance.requestPlay(
      messageId: widget.message.id,
      player: _player,
    );

    _syncDurationToPlayer();
    final startPos = _hasCompleted ? Duration.zero : _position;
    _hasCompleted = false;
    await _player.playFile(playPath, start: startPos);
  }

  Future<void> _togglePlayback() async {
    if (_isPlaying) {
      await _player.pause();
      return;
    }

    if (!_hasCompleted && _position > Duration.zero && _resolvedPath != null) {
      await VoicePlaybackCoordinator.instance.requestPlay(
        messageId: widget.message.id,
        player: _player,
      );
      await _player.resume();
      return;
    }

    if (_hasCompleted) {
      _position = Duration.zero;
      _hasCompleted = false;
    }

    setState(() => _isLoading = true);
    try {
      await _playFromFile();
    } catch (err) {
      debugPrint('Voice playback error: $err');
      if (mounted) {
        showPrysmToast(context, 'Failed to play voice message');
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    VoicePlaybackCoordinator.instance.release(widget.message.id, _player);
    unawaited(_player.dispose());
    super.dispose();
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  double get _progress {
    if (_scrubFraction != null) return _scrubFraction!;
    if (_duration.inMilliseconds <= 0) return 0;
    return _position.inMilliseconds / _duration.inMilliseconds;
  }

  Duration get _displayPosition {
    if (_scrubFraction != null && _duration > Duration.zero) {
      return Duration(
        milliseconds: (_scrubFraction! * _duration.inMilliseconds).round(),
      );
    }
    if (_isPlaying || _position > Duration.zero) return _position;
    return Duration.zero;
  }

  @override
  Widget build(BuildContext context) {
    final maxWidth = math.min(MediaQuery.of(context).size.width * 0.52, 220.0);
    final bubbleColor = prysmBubbleBackground(
      context,
      isSentByMe: widget.isSentByMe,
    );
    final contentColor = prysmBubbleTextColor(
      context,
      isSentByMe: widget.isSentByMe,
    );
    final metaStyle = TextStyle(
      fontSize: 9,
      color: contentColor.withAlpha(170),
      height: 1.1,
    );
    final transcriptStyle = TextStyle(
      fontSize: 11,
      color: contentColor.withAlpha(220),
      height: 1.3,
    );

    return Column(
      crossAxisAlignment:
          widget.isSentByMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Container(
            padding: const EdgeInsets.fromLTRB(6, 5, 8, 5),
            decoration: BoxDecoration(
              color: bubbleColor,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _isLoading
                    ? const SizedBox(
                        width: 26,
                        height: 26,
                        child: PrysmProgressIndicator(size: 20),
                      )
                    : PrysmIconButton(
                        icon: _isPlaying
                            ? PrysmIcons.pauseRounded
                            : PrysmIcons.playArrowRounded,
                        color: contentColor,
                        onPressed: _togglePlayback,
                      ),
                const SizedBox(width: 4),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      VoiceWaveformScrubber(
                        peaks: _peaks,
                        progress: _progress,
                        height: 18,
                        activeColor: contentColor.withAlpha(210),
                        inactiveColor: contentColor.withAlpha(55),
                        onScrubUpdate: (fraction) {
                          setState(() => _scrubFraction = fraction);
                        },
                        onSeek: (fraction) async {
                          if (_duration <= Duration.zero &&
                              _resolvedPath == null) {
                            await _prepareWaveform();
                            await _resolvePath();
                          }
                          if (_duration <= Duration.zero) return;
                          await _seekToFraction(fraction);
                        },
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Text(
                            _formatDuration(_displayPosition),
                            style: metaStyle,
                          ),
                          Text(' / ', style: metaStyle),
                          Text(
                            _duration > Duration.zero
                                ? _formatDuration(_duration)
                                : '--:--',
                            style: metaStyle,
                          ),
                          const Spacer(),
                          Text(widget.timeString, style: metaStyle),
                          if (widget.isSentByMe) ...[
                            const SizedBox(width: 3),
                            widget.tickWidget,
                          ],
                        ],
                      ),
                      if (_sttSupported) ...[
                        const SizedBox(height: 4),
                        Align(
                          alignment: widget.isSentByMe
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: PrysmLinkButton(
                            onPressed:
                                _isTranscribing ? null : _onTranscribeTap,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  PrysmIcons.subtitlesOutlined,
                                  size: 14,
                                  color: contentColor.withValues(alpha: 0.82),
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  _cachedTranscript != null
                                      ? (_showTranscript
                                          ? 'Hide transcript'
                                          : 'Show transcript')
                                      : 'Transcribe (${SttModelManager.supportedLanguageLabel})',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: contentColor.withValues(alpha: 0.82),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (_isTranscribing)
                          Padding(
                            padding: const EdgeInsets.only(top: 2, bottom: 2),
                            child: const PrysmLinearProgressIndicator(
                              minHeight: 2,
                            ),
                          ),
                        if (_showTranscript && _cachedTranscript != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 2, bottom: 2),
                            child: Text(
                              _cachedTranscript!,
                              style: transcriptStyle,
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

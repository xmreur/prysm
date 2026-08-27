import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:prysm/services/call/call_capture_source.dart';
import 'package:prysm/services/call/call_pcm_playback.dart';
import 'package:prysm/services/call/group_audio_mixer.dart';
import 'package:prysm/services/call/group_call_session.dart';
import 'package:prysm/services/call/opus_codec.dart';
import 'package:prysm/services/call/pcm_gain_normalizer.dart';
import 'package:prysm/util/logging.dart';
import 'package:prysm/util/tor_service.dart';
import 'package:record/record.dart';

typedef GroupAudioSendCallback = void Function(String peerOnion, Uint8List frame);

abstract class GroupCallAudio {
  Future<bool> start({required bool listenOnly});
  Future<void> stop();
  void handleIncoming(String peerOnion, Uint8List encryptedFrame);
  void setMuted(bool muted);
  void setSpeakAllowed(bool allowed);
  void setSendTargets(Set<String> peers);
  void addRemote(String peerOnion);
  void removeRemote(String peerOnion);
  bool get isRunning;
  bool get isMuted;
}

class GroupAudioEngine implements GroupCallAudio {
  GroupAudioEngine({
    required this.session,
    required this.onSendFrame,
    OpusCodec? codec,
    CallPcmPlayback? playback,
    this.dropIncomingFrom,
  })  : _codec = codec,
        _playback = playback ?? createCallPcmPlayback();

  static String? lastStartError;

  final GroupCallSession session;
  final GroupAudioSendCallback onSendFrame;
  final bool Function(String peerOnion)? dropIncomingFrom;

  OpusCodec? _codec;
  final CallPcmPlayback _playback;
  GroupAudioMixer? _mixer;
  CallCaptureSource? _capture;
  final Map<int, OpusStreamDecoder> _decoders = {};
  final PcmGainNormalizer _playbackGain = PcmGainNormalizer();
  bool _running = false;
  bool _muted = false;
  bool _speakAllowed = true;
  Set<String> _targets = {};
  Future<void> _sendChain = Future.value();

  @override
  bool get isRunning => _running;

  @override
  bool get isMuted => _muted;

  @override
  Future<bool> start({required bool listenOnly}) async {
    if (_running) return true;
    _speakAllowed = !listenOnly;
    try {
      _codec ??= await OpusCodec.create(
        sampleRate: session.codec.sampleRate,
        channels: session.codec.channels,
        frameDurationMs: session.codec.frameDurationMs,
      );
      final codec = _codec;
      if (codec == null) {
        lastStartError = OpusCodec.lastLoadError ?? 'Opus codec unavailable';
        return false;
      }

      if (!kIsWeb && Platform.isIOS) {
        await TorManager.setIosCallAudioActive(true);
        await _configureIosCallAudioSession();
        await AudioRecorder().ios?.manageAudioSession(false);
      }

      final mixer = GroupAudioMixer(
        sampleRate: codec.sampleRate,
        channels: codec.channels,
        playback: _playback,
      );
      await mixer.start();
      _mixer = mixer;

      if (_speakAllowed) {
        final capture = CallCaptureSource(
          sampleRate: codec.sampleRate,
          channels: codec.channels,
          frameSamples: codec.frameSamples,
          onFrame: _onCaptureFrame,
        );
        capture.setMuted(_muted);
        final started = await capture.start();
        if (!started) {
          lastStartError = CallCaptureSource.lastStartError;
          await mixer.stop();
          _mixer = null;
          return false;
        }
        _capture = capture;
      }

      _running = true;
      lastStartError = null;
      return true;
    } catch (e) {
      lastStartError = e.toString();
      await stop();
      return false;
    }
  }

  void _onCaptureFrame(CallCaptureFrame frame) {
    if (!_running || _muted || !_speakAllowed) return;
    if (!frame.gateOpen) return;
    final codec = _codec;
    if (codec == null) return;
    try {
      final opus = codec.encodeFrame(frame.pcm);
      _sendChain = _sendChain.then((_) async {
        final encrypted = await session.encryptAudioFrame(opus);
        for (final peer in _targets) {
          onSendFrame(peer, encrypted);
        }
      });
    } catch (e) {
      if (kDebugMode) {
        Logging.error('group encode failed: $e', 'GroupAudioEngine');
      }
    }
  }

  @override
  void handleIncoming(String peerOnion, Uint8List encryptedFrame) {
    if (!_running) return;
    if (dropIncomingFrom?.call(peerOnion) == true) return;
    final slot = session.slotOf(peerOnion);
    if (slot == null || slot == session.localSlot) return;
    unawaited(() async {
      final opus = await session.decryptAudioFrame(
        encryptedFrame,
        senderSlot: slot,
      );
      if (opus == null || !_running) return;
      try {
        final decoder = await _decoderFor(slot);
        if (decoder == null || !_running) return;
        final pcm = decoder.decodeFrame(opus);
        final normalized = _playbackGain.normalize(pcm);
        final bytes = normalized.buffer.asUint8List(
          normalized.offsetInBytes,
          normalized.lengthInBytes,
        );
        _mixer?.pushPcm(slot, bytes);
      } catch (e) {
        if (kDebugMode) {
          Logging.error('group decode failed: $e', 'GroupAudioEngine');
        }
      }
    }());
  }

  Future<OpusStreamDecoder?> _decoderFor(int slot) async {
    final existing = _decoders[slot];
    if (existing != null) return existing;
    final created = await OpusStreamDecoder.create(
      sampleRate: session.codec.sampleRate,
      channels: session.codec.channels,
    );
    if (created == null) return null;
    _decoders[slot] = created;
    return created;
  }

  @override
  void setMuted(bool muted) {
    _muted = muted;
    _capture?.setMuted(muted || !_speakAllowed);
  }

  @override
  void setSpeakAllowed(bool allowed) {
    _speakAllowed = allowed;
    _capture?.setMuted(_muted || !allowed);
  }

  @override
  void setSendTargets(Set<String> peers) {
    _targets = Set<String>.from(peers);
  }

  @override
  void addRemote(String peerOnion) {
    final slot = session.slotOf(peerOnion);
    if (slot == null) return;
    _mixer?.addSender(slot);
    unawaited(_decoderFor(slot));
  }

  @override
  void removeRemote(String peerOnion) {
    final slot = session.slotOf(peerOnion);
    if (slot == null) return;
    _mixer?.removeSender(slot);
    _decoders.remove(slot)?.dispose();
  }

  Future<void> _configureIosCallAudioSession() async {
    final audioSession = await AudioSession.instance;
    await audioSession.configure(
      AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
        avAudioSessionCategoryOptions:
            AVAudioSessionCategoryOptions.defaultToSpeaker |
            AVAudioSessionCategoryOptions.allowBluetooth,
        avAudioSessionMode: AVAudioSessionMode.voiceChat,
      ),
    );
    await audioSession.setActive(true);
  }

  @override
  Future<void> stop() async {
    _running = false;
    _sendChain = Future.value();
    await _capture?.stop();
    _capture = null;
    await _mixer?.stop();
    _mixer = null;
    for (final decoder in _decoders.values) {
      decoder.dispose();
    }
    _decoders.clear();
    _playbackGain.reset();
    if (!kIsWeb && Platform.isIOS) {
      await AudioRecorder().ios?.manageAudioSession(true);
      await TorManager.setIosCallAudioActive(false);
    }
    _codec?.dispose();
    _codec = null;
  }
}

GroupCallAudio createGroupCallAudio({
  required GroupCallSession session,
  required GroupAudioSendCallback onSendFrame,
  bool Function(String peerOnion)? dropIncomingFrom,
}) =>
    GroupAudioEngine(
      session: session,
      onSendFrame: onSendFrame,
      dropIncomingFrom: dropIncomingFrom,
    );

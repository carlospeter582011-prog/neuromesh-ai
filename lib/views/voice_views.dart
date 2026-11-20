import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../controllers/settings_controller.dart';
import '../controllers/chat_controller.dart';
import '../controllers/home_controller.dart';
import '../models/chat_message.dart';
import '../utils/thought_parser.dart';
import '../utils/spoken_answer.dart';
import 'voice_clone_view.dart';
import 'chat_tools.dart';
import '../core/ui.dart';
import '../services/agent_service.dart';
import '../services/skills_service.dart';
import '../utils/skill_context.dart';
import '../services/hive_service.dart';
import '../services/model_transfer_service.dart';
import 'model_transfer_view.dart';
import '../widgets/agent_steps.dart';
import '../widgets/chat_bubble.dart';
import '../widgets/image_viewer.dart';
import '../widgets/tool_confirm.dart';
import '../services/inference_service.dart';
import '../services/voice_clone_store.dart';
import '../services/voice_models.dart';
import '../services/voice_service.dart';
import '../services/workload_placement.dart';

const _kLang = 'voice_lang';
const _kSystemTts = 'voice_system_tts';
const _kBargeIn = 'voice_barge_in';
const _kWakePhrase = 'voice_wake_phrase';
const _kSttId = 'voice_stt_id';
const _kTtsId = 'voice_tts_id';
const _kSpeed = 'voice_speed';

class VoiceModelsView extends StatelessWidget {
  const VoiceModelsView({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: AppTokens.of(context).bg,
        appBar: appScreenBar(context, title: 'Voice models'),
        body: ListView(
          padding: kPagePadding,
          children: const [VoiceModelCatalog()],
        ),
      );
}

/// Downloads, model selection, and voice options shared by both entry points.
class VoiceModelCatalog extends StatefulWidget {
  const VoiceModelCatalog({super.key});

  @override
  State<VoiceModelCatalog> createState() => _VoiceModelCatalogState();
}

class _VoiceModelCatalogState extends State<VoiceModelCatalog> {
  final _hive = Get.find<HiveService>();
  final _store = Get.find<VoiceModelStore>();
  bool _previewing = false;
  bool _importingVoiceModels = false;
  String? _voiceImportProgress;
  String? _exportingModel;

  String get _sttId => _hive.getSetting<String>(_kSttId) ?? '';
  String get _ttsId => _hive.getSetting<String>(_kTtsId) ?? '';
  double get _speed => _hive.getSetting<double>(_kSpeed) ?? 1.0;

  /// The model that will actually be used for [kind]: the picked one if it is
  /// installed, otherwise the first installed one.
  VoiceModelInfo? _effective(VoiceKind kind, String picked) {
    final list = kVoiceModels
        .where((m) =>
            m.kind == kind && !m.clone && _store.installed.contains(m.id))
        .toList();
    for (final m in list) {
      if (m.id == picked) return m;
    }
    return list.isEmpty ? null : list.first;
  }

  Future<void> _preview(VoiceModelInfo m) async {
    setState(() => _previewing = true);
    try {
      final v = Get.find<VoiceService>();
      v.speed = _speed;
      if (!v.ttsLoadedFor(m)) await v.loadTts(m);
      await v.speak(
          m.lang == 'ar'
              ? 'مرحباً، هذا صوتي. كيف يبدو؟'
              : 'Hello, this is how I sound. Do you like this voice?',
          localModel: m,
          preferLocal: true);
    } catch (e) {
      Get.snackbar('Could not play the voice', '$e');
    } finally {
      if (mounted) setState(() => _previewing = false);
    }
  }

  Future<void> _importVoiceModels() async {
    setState(() => _importingVoiceModels = true);
    final imported = <String>[];
    final failed = <String>[];
    try {
      final selection = await FilePicker.pickFiles(
          type: FileType.custom,
          allowedExtensions: ['zip'],
          allowMultiple: true);
      final files = selection?.files ?? [];
      for (var index = 0; index < files.length; index++) {
        final file = files[index];
        if (mounted) {
          setState(() => _voiceImportProgress =
              'Importing ${index + 1} of ${files.length}');
        }
        try {
          final path = file.path;
          if (path == null)
            throw const FormatException('Couldn’t open this file.');
          final model = await _store.importZip(path);
          imported.add(model.title);
        } catch (error) {
          failed.add('${file.name}: $error');
        }
      }
    } catch (error) {
      failed.add('$error');
    } finally {
      if (mounted) {
        setState(() {
          _importingVoiceModels = false;
          _voiceImportProgress = null;
        });
      }
    }
    if (!mounted || (imported.isEmpty && failed.isEmpty)) return;
    if (failed.isEmpty) {
      Get.snackbar('Voice models imported', imported.join(', '));
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Voice import results'),
        content: SingleChildScrollView(
          child: Text([
            if (imported.isNotEmpty) '${imported.length} imported',
            ...failed,
          ].join('\n\n')),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Done')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      _store.installed.length; // rebuild when downloads finish / are removed
      _store.progress.length;
      Widget group(VoiceKind k) => AppGroup(children: [
            for (final m in kVoiceModels.where((m) => m.kind == k))
              _row(context, m),
          ]);
      final tts = _effective(VoiceKind.tts, _ttsId);
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Padding(
          padding: EdgeInsets.all(8),
          child: Text(
              'Download a listening or speaking model, then tap it to select it.'),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.file_open_rounded),
              label: Text(_voiceImportProgress ?? 'Import voice models (.zip)'),
              onPressed: _importingVoiceModels ? null : _importVoiceModels,
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.swap_horiz_rounded),
              label: const Text('Send / receive on Wi-Fi'),
              onPressed: () => Get.to(() => const ModelTransferView()),
            ),
          ]),
        ),
        const SectionHeader('Listening (speech to text)'),
        group(VoiceKind.stt),
        const SectionHeader('Speaking (text to speech)'),
        group(VoiceKind.tts),
        if (tts != null) ...[
          const SectionHeader('Voice options'),
          _voiceOptions(tts),
        ],
        const SectionHeader('Better turn-taking (recommended)'),
        group(VoiceKind.vad),
      ]);
    });
  }

  Widget _voiceOptions(VoiceModelInfo tts) {
    final sp = tts.speakers;
    final sid = VoiceService.savedSpeaker(tts);
    return AppGroup(children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Using: ${tts.title}',
              style: const TextStyle(fontWeight: FontWeight.w600)),
          if (sp.isNotEmpty) ...[
            const SizedBox(height: 8),
            DropdownButton<int>(
              isExpanded: true,
              value: sid,
              items: [
                for (var i = 0; i < sp.length; i++)
                  DropdownMenuItem(value: i, child: Text(sp[i])),
              ],
              onChanged: (v) async {
                await VoiceService.saveSpeaker(tts, v ?? 0);
                if (mounted) setState(() {});
              },
            ),
          ] else
            const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text('This model has a single voice.')),
          Row(children: [
            const Text('Speed'),
            Expanded(
              child: Slider(
                min: 0.6,
                max: 1.6,
                divisions: 10,
                label: '${_speed.toStringAsFixed(1)}x',
                value: _speed.clamp(0.6, 1.6),
                onChanged: (v) {
                  _hive.setSetting(_kSpeed, v);
                  setState(() {});
                },
              ),
            ),
          ]),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: _previewing ? null : () => _preview(tts),
              icon: _previewing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.play_arrow_rounded),
              label: const Text('Try this voice'),
            ),
          ),
        ]),
      ),
    ]);
  }

  Widget _row(BuildContext c, VoiceModelInfo m) {
    final store = _store;
    final p = store.progress[m.id];
    final err = store.errors[m.id];
    final has = store.installed.contains(m.id);
    final picked = !m.clone &&
        has &&
        (m.kind == VoiceKind.stt
            ? _effective(VoiceKind.stt, _sttId)?.id == m.id
            : m.kind == VoiceKind.tts
                ? _effective(VoiceKind.tts, _ttsId)?.id == m.id
                : false);
    return AppRow(
      icon: m.kind == VoiceKind.stt
          ? Icons.hearing_rounded
          : Icons.record_voice_over_rounded,
      title: m.title,
      subtitle: err ??
          (p == null
              ? '${m.sizeLabel}${has ? ' · installed' : ''}${picked ? ' · in use' : ''}'
              : p < 0
                  ? 'Unpacking…'
                  : 'Downloading ${(p * 100).round()}%'),
      onTap: has && !m.clone && m.kind != VoiceKind.vad
          ? () {
              _hive.setSetting(
                  m.kind == VoiceKind.stt ? _kSttId : _kTtsId, m.id);
              setState(() {});
            }
          : null,
      trailing: p != null
          ? Row(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, value: p > 0 ? p : null)),
              if (p >= 0)
                IconButton(
                    tooltip: 'Cancel download',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => store.cancel(m.id)),
            ])
          : has
              ? Row(mainAxisSize: MainAxisSize.min, children: [
                  if (picked) const Icon(Icons.check_circle_rounded, size: 20),
                  if (!m.clone && m.kind != VoiceKind.vad)
                    IconButton(
                        tooltip: 'Export as .zip (save or send)',
                        icon: _exportingModel == m.id
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.ios_share_rounded),
                        onPressed: _exportingModel != null
                            ? null
                            : () async {
                                setState(() => _exportingModel = m.id);
                                try {
                                  final msg = await store.exportZip(m);
                                  if (mounted) Get.snackbar('Export', msg);
                                } catch (e) {
                                  if (mounted)
                                    Get.snackbar('Export failed', '$e');
                                } finally {
                                  if (mounted)
                                    setState(() => _exportingModel = null);
                                }
                              }),
                  IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: _exportingModel == m.id
                          ? null
                          : () {
                              store.remove(m);
                              setState(() {});
                            }),
                ])
              : IconButton(
                  icon: const Icon(Icons.download_rounded),
                  onPressed: () => store.download(m)),
    );
  }
}

enum _CallState { starting, listening, thinking, speaking, error }

/// Hands-free voice conversation with the loaded local model.
class VoiceCallView extends StatefulWidget {
  final bool useSelectedClone;
  const VoiceCallView({super.key, this.useSelectedClone = false});

  @override
  State<VoiceCallView> createState() => _VoiceCallViewState();
}

class _VoiceCallViewState extends State<VoiceCallView> {
  final _voice = Get.find<VoiceService>();
  final _store = Get.find<VoiceModelStore>();
  final _hive = Get.find<HiveService>();
  final _rec = AudioRecorder();
  final _history = <Map<String, String>>[];
  final _chat = Get.find<ChatController>();
  String _sessionId = '';
  List<AgentStep> _steps = [];
  int _turnNumber = 0;
  bool _addingFile = false;
  String? _attachedFile;
  String? _attachmentProject;
  final _bargeAudio = <double>[];
  final _callScroll = ScrollController();
  final _interruptionAudio = <double>[];
  final _lines = <({bool me, String text})>[];

  _CallState _state = _CallState.starting;
  String _status = 'Getting ready…';
  String _lang = 'en';
  bool _muted = false;
  CameraController? _cam;
  bool _camBusy = false;

  CameraLensDirection _cameraDirection = CameraLensDirection.front;
  List<CameraDescription> _callCameras = const [];

  /// The vision model receives a camera frame with the next spoken turn.
  Future<void> _toggleCamera() async {
    if (_camBusy) return;
    if (_cam case final active?) {
      setState(() {
        _cam = null;
        _camBusy = true;
      });
      try {
        await active.dispose();
      } finally {
        if (mounted) setState(() => _camBusy = false);
      }
      return;
    }
    if (!Get.find<InferenceService>().isVisionLoaded.value) {
      Get.snackbar('Video call needs a vision model',
          'Load a model with a matching vision helper and try again.');
      return;
    }
    await _openCallCamera(_cameraDirection);
  }

  Future<void> _openCallCamera(CameraLensDirection direction) async {
    final previous = _cam;
    setState(() {
      _camBusy = true;
      _cam = null;
    });
    CameraController? next;
    try {
      await previous?.dispose();
      if (_callCameras.isEmpty) _callCameras = await availableCameras();
      if (_callCameras.isEmpty) throw StateError('No camera found.');
      final camera = _callCameras.firstWhere(
          (camera) => camera.lensDirection == direction,
          orElse: () => _callCameras.first);
      next = CameraController(camera, ResolutionPreset.low, enableAudio: false);
      await next.initialize();
      if (!mounted) return;
      setState(() {
        _cameraDirection = camera.lensDirection;
        _cam = next;
      });
      next = null;
    } catch (error) {
      if (mounted) Get.snackbar('Camera unavailable', '$error');
    } finally {
      await next?.dispose();
      if (mounted) setState(() => _camBusy = false);
    }
  }

  CameraLensDirection get _otherCamera =>
      _cameraDirection == CameraLensDirection.front
          ? CameraLensDirection.back
          : CameraLensDirection.front;

  Future<String?> _snap() async {
    final c = _cam;
    if (c == null || !c.value.isInitialized) return null;
    try {
      return (await c.takePicture()).path;
    } catch (_) {
      return null;
    }
  }

  bool _ended = false;
  bool _bargeIn = false;
  String _wake = '';
  StreamSubscription<Uint8List>? _sub;

  // Smart detector (Silero) when installed; otherwise a simple energy gate.
  sherpa.VoiceActivityDetector? _vad;
  final _vadBuf = <double>[];

  final _speech = <double>[];
  final _preRoll = <double>[];
  bool _inSpeech = false;
  int _silentSamples = 0;
  double _noise = 0.01;
  int _calib = 0;

  bool _busy = false; // transcribing / thinking
  bool _speaking = false;
  VoiceModelInfo? _callVoice;
  int _bargeFrames = 0;
  final _pending = <Float32List>[]; // utterances that arrive while busy
  bool _interrupted = false;

  static const _rate = 16000;

  @override
  void initState() {
    super.initState();
    _sessionId = _chat.currentSessionId.value;
    for (final ChatMessage message in _chat.messages) {
      if (message.role != 'user' && message.role != 'assistant') continue;
      final me = message.role == 'user';
      final text = me
          ? message.visibleUserText
          : stripToolTrace(splitThoughtTags(message.content).answer);
      _history
          .add({'role': message.role, 'content': me ? message.content : text});
      if (text.trim().isNotEmpty) {
        _lines.add((me: me, text: text));
      }
    }
    _lang = _hive.getSetting<String>(_kLang) ?? 'en';
    if (widget.useSelectedClone) {
      _lang = 'en';
      _callVoice = voiceModelById('pocket-tts-clone');
    } else {
      final model = _hive.getSetting<String>(_kTtsId);
      if (model == 'pocket-tts-clone' && _store.installed.contains(model)) {
        _callVoice = voiceModelById('pocket-tts-clone');
      }
    }
    _bargeIn = _hive.getSetting<bool>(_kBargeIn, defaultValue: true) ?? true;
    _wake = (_hive.getSetting<String>(_kWakePhrase) ?? '').trim().toLowerCase();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _ended = true;
    _micWatchdog?.cancel();
    _cam?.dispose();
    _callScroll.dispose();
    _sub?.cancel();
    _rec.dispose();
    _vad?.free();
    _voice.stopSpeaking();
    final inference = Get.find<InferenceService>();
    if (inference.generationSource.value == 'voice') {
      unawaited(inference.stopGeneration());
    }
    super.dispose();
  }

  void _scrollCall() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _callScroll.hasClients) {
        _callScroll.jumpTo(_callScroll.position.maxScrollExtent);
      }
    });
  }

  void _set(_CallState s, String text) {
    if (!mounted) return;
    setState(() {
      _state = s;
      _status = text;
    });
    _scrollCall();
  }

  VoiceModelInfo? _installed(VoiceKind k, {String? lang}) {
    final picked =
        _hive.getSetting<String>(k == VoiceKind.stt ? _kSttId : _kTtsId) ?? '';
    if (picked.isNotEmpty && (k == VoiceKind.stt || k == VoiceKind.tts)) {
      final m = voiceModelById(picked);
      if (m != null &&
          m.kind == k &&
          !m.clone &&
          _store.installed.contains(m.id) &&
          (lang == null || m.lang == lang || m.lang == 'multi')) {
        return m;
      }
    }
    for (final m in kVoiceModels) {
      if (m.kind != k || !_store.installed.contains(m.id)) continue;
      if (m.clone) continue; // chosen separately by _ttsChoice
      if (lang == null || m.lang == lang || m.lang == 'multi') return m;
    }
    return null;
  }

  /// The cloning voice when you picked one (English only), else a normal voice.
  VoiceModelInfo? _ttsChoice(String lang) {
    final chosen = _callVoice;
    if (chosen != null &&
        _store.installed.contains(chosen.id) &&
        (chosen.lang == lang || chosen.lang == 'multi') &&
        (!chosen.clone ||
            Get.find<VoiceCloneStore>().active.value.isNotEmpty)) {
      return chosen;
    }
    return _installed(VoiceKind.tts, lang: lang);
  }

  Future<void> _start() async {
    if (_ended) return;
    if (!Get.find<InferenceService>().isModelLoaded.value) {
      _set(_CallState.error, 'Load a chat model first (Models tab).');
      return;
    }
    _voice.speed = _hive.getSetting<double>(_kSpeed) ?? 1.0;
    final stt = _installed(VoiceKind.stt);
    final remoteStt =
        WorkloadPlacement.forWorkload(PhoneWorkload.transcription);
    if (stt == null && remoteStt == null) {
      _set(_CallState.error,
          'Download a listening model or assign a phone worker.');
      return;
    }
    if (!await Permission.microphone.request().isGranted) {
      _set(_CallState.error, 'Microphone permission is needed for calls.');
      return;
    }
    try {
      _set(_CallState.starting, 'Loading voice…');
      if (remoteStt == null &&
          stt != null &&
          !_voice.sttLoadedFor(stt, _lang)) {
        await _voice.loadStt(stt, language: _lang);
      }
      final tts = _ttsChoice(_lang);
      if (tts != null &&
          WorkloadPlacement.forWorkload(PhoneWorkload.speech) == null &&
          !_hive.getSetting<bool>(_kSystemTts, defaultValue: false)!) {
        if (!_voice.ttsLoadedFor(tts)) await _voice.loadTts(tts);
        if (tts.clone && !_voice.hasCloneVoice) {
          await Get.find<VoiceCloneStore>().restoreActive();
        }
      }
      _voice.loadWorkerSettings();
      final detector = await _voice.createVad();
      if (_ended) {
        detector?.free();
        return;
      }
      _vad = detector;
      final stream = await _rec.startStream(_recConfig);
      if (_ended) return;
      _lastAudio = DateTime.now();
      _sub = stream.listen(_onAudio);
      _startMicWatchdog();
      _set(_CallState.listening, _listeningText());
    } catch (e) {
      _set(_CallState.error, 'Could not start the call: $e');
    }
  }

  String _listeningText() =>
      _wake.isEmpty ? 'Listening…' : 'Say "$_wake" to talk';

  Float64List _toFloat(Uint8List bytes) {
    final n = bytes.length ~/ 2;
    final bd = ByteData.sublistView(bytes);
    final out = Float64List(n);
    for (var i = 0; i < n; i++) {
      out[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return out;
  }

  void _onAudio(Uint8List bytes) {
    _lastAudio = DateTime.now();
    if (_ended || _muted) return;
    final chunk = _toFloat(bytes);

    if (_interrupted && _busy) {
      if (_interruptionAudio.length < _rate * 5) {
        _interruptionAudio.addAll(chunk);
      }
      return;
    }
    // While the model is speaking, only look for the user interrupting.
    if (_speaking) {
      if (!_bargeIn) return;
      _bargeCheck(chunk);
      return;
    }
    if (_busy) return;
    if (_vad != null) {
      _onAudioVad(chunk);
    } else {
      _onAudioEnergy(chunk);
    }
  }

  void _bargeCheck(Float64List chunk) {
    var sum = 0.0;
    for (final v in chunk) {
      sum += v * v;
    }
    final rms = math.sqrt(sum / math.max(chunk.length, 1));
    // Needs clearly louder than background, for ~0.4 s in a row.
    if (rms > math.max(0.065, _noise * 6)) {
      _bargeFrames += chunk.length;
      _bargeAudio.addAll(chunk);
      if (_bargeFrames >= _rate * 0.46) {
        final vad = _vad;
        if (vad == null) {
          _interrupt();
        } else {
          vad.reset();
          for (var i = 0; i + 512 <= _bargeAudio.length; i += 512) {
            vad.acceptWaveform(
                Float32List.fromList(_bargeAudio.sublist(i, i + 512)));
          }
          if (vad.isDetected() || !vad.isEmpty()) _interrupt();
          vad.reset();
        }
        _bargeAudio.clear();
        _bargeFrames = 0;
      }
    } else {
      _bargeFrames = 0;
      _bargeAudio.clear();
    }
  }

  void _interrupt() {
    if (!_speaking || _interrupted) return;
    _interrupted = true;
    _interruptionAudio.addAll(_bargeAudio);
    _bargeAudio.clear();
    _set(_CallState.listening, 'Listening to your interruption…');
    unawaited(_voice.stopSpeaking());
    final inference = Get.find<InferenceService>();
    if (inference.generationSource.value == 'voice') {
      unawaited(inference.stopGeneration());
    }
  }

  void _onAudioVad(Float64List chunk) {
    _vadBuf.addAll(chunk);
    while (_vadBuf.length >= 512) {
      final win = Float32List.fromList(_vadBuf.sublist(0, 512));
      _vadBuf.removeRange(0, 512);
      _vad!.acceptWaveform(win);
    }
    while (!_vad!.isEmpty()) {
      final seg = _vad!.front();
      _vad!.pop();
      if (seg.samples.length > _rate * 0.4) _turn(seg.samples);
    }
  }

  void _onAudioEnergy(Float64List chunk) {
    final n = chunk.length;
    var sum = 0.0;
    for (final v in chunk) {
      sum += v * v;
    }
    final rms = math.sqrt(sum / math.max(n, 1));
    if (_calib < 8) {
      _noise = (_noise * _calib + rms) / (_calib + 1);
      _calib++;
      return;
    }
    final thr = math.max(0.02, _noise * 3);
    if (rms > thr) {
      if (!_inSpeech) {
        _inSpeech = true;
        _speech
          ..clear()
          ..addAll(_preRoll);
      }
      _silentSamples = 0;
      _speech.addAll(chunk);
    } else if (_inSpeech) {
      _speech.addAll(chunk);
      _silentSamples += n;
      final long = _speech.length > _rate * 20;
      if (_silentSamples > _rate * 0.9 || long) {
        final ok = _speech.length > _rate * 0.5;
        final samples = Float32List.fromList(_speech);
        _inSpeech = false;
        _speech.clear();
        _silentSamples = 0;
        if (ok) _turn(samples);
      }
    } else {
      _preRoll.addAll(chunk);
      final keep = (_rate * 0.3).round();
      if (_preRoll.length > keep)
        _preRoll.removeRange(0, _preRoll.length - keep);
    }
  }

  /// Speaks sentences as the model writes them, one after another.
  Future<void> _speakQueue(
    Stream<String> sentences,
    String? sysLang, {
    required void Function(String) caption,
    required bool Function() shouldStop,
  }) async {
    var language = _callVoice == null ? sysLang : null;
    final fallbackLanguage = _lang == 'ar' ? 'ar' : 'en-US';

    void playback(bool playing) {
      _speaking = playing;
      if (shouldStop()) return;
      if (!playing) {
        _bargeFrames = 0;
        _bargeAudio.clear();
      }
      _set(playing ? _CallState.speaking : _CallState.thinking,
          playing ? 'Speaking…' : 'Thinking…');
    }

    await for (final sentence in sentences) {
      if (shouldStop()) break;
      caption(sentence);
      _set(_CallState.thinking, 'Preparing voice…');
      try {
        await _voice.speak(
          sentence,
          systemLang: language,
          workerLanguage: _lang,
          localModel: _ttsChoice(_lang),
          preferLocal: _callVoice != null,
          onPlayback: playback,
        );
      } catch (error) {
        if (shouldStop()) break;
        if (language == null) {
          language = fallbackLanguage;
          _set(_CallState.thinking, 'Switching to system voice…');
          try {
            await _voice.speak(sentence,
                systemLang: language, onPlayback: playback);
            if (!shouldStop() && mounted) {
              ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(
                content: Text('Call audio switched to the system voice.'),
              ));
            }
            continue;
          } catch (_) {
            if (shouldStop()) break;
          }
        }
        if (mounted) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(
            content:
                Text('A sentence could not play. It is in the transcript.'),
          ));
        }
      }
    }
  }

  static String _spoken(String text) => spokenAnswer(text);

  final _shots = <File>[];

  Future<void> _turn(Float32List samples) async {
    if (_busy) {
      if (_pending.length < 2) _pending.add(samples);
      return;
    }
    _busy = true;
    try {
      _set(_CallState.thinking, 'Thinking…');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      var heard = await _voice.transcribeSamples(samples, language: _lang);
      if (heard.isNotEmpty && _wake.isNotEmpty) {
        final low = heard.toLowerCase();
        final at = low.indexOf(_wake);
        if (at < 0) {
          _afterTurn();
          return;
        }
        heard = heard
            .substring(at + _wake.length)
            .replaceFirst(RegExp(r'^[\s,.!?]+'), '');
      }
      if (heard.isEmpty) {
        _afterTurn();
        return;
      }
      if (!_ended) await _respond(heard);
    } catch (e) {
      if (mounted) setState(() => _lines.add((me: false, text: '⚠️ $e')));
    } finally {
      _finishTurn();
    }
  }

  Future<void> _attachFile() async {
    if (_addingFile || _busy) return;
    if (Get.find<AgentService>().mode.value == AgentChatMode.off) {
      showToast('Agent tools are off',
          'Enable tools to use workspace files in the call.');
      return;
    }
    setState(() => _addingFile = true);
    try {
      final result = await FilePicker.pickFiles();
      final file = result?.files.single;
      if (_ended || file?.path == null) return;
      if (_sessionId.isEmpty) {
        _chat.createNewChat();
        _sessionId = _chat.currentSessionId.value;
      }
      final agent = Get.find<AgentService>();
      final project = agent.projectForChat(_sessionId);
      final name = await agent.inProject(
          project, () => agent.importToWorkspace(file!.path!, file.name));
      if (mounted)
        setState(() {
          _attachedFile = name;
          _attachmentProject = project;
        });
    } catch (_) {
      if (mounted)
        showToast('Could not attach this file', 'Choose the file again.');
    } finally {
      if (mounted) setState(() => _addingFile = false);
    }
  }

  Future<void> _sendAttachment() async {
    if (_busy || _attachedFile == null) return;
    _busy = true;
    try {
      await _respond('Please inspect the attached file and summarize it.');
    } catch (e) {
      if (mounted) setState(() => _lines.add((me: false, text: '⚠️ $e')));
    } finally {
      _finishTurn();
    }
  }

  Future<void> _respond(String heard) async {
    if (_ended) return;
    _set(_CallState.thinking, 'Thinking…');
    final file = _attachedFile;
    final message = file == null
        ? heard
        : '$heard\n\nAttached file: $file\nUse the workspace file tools to read it.';
    if (_sessionId.isEmpty) {
      _chat.createNewChat();
      _sessionId = _chat.currentSessionId.value;
    }
    final sessionId = _sessionId;
    final project = (file == null ? null : _attachmentProject) ??
        Get.find<AgentService>().projectForChat(sessionId);
    await _chat.saveVoiceMessage(sessionId, 'user', message,
        fileName: file, workspaceProject: project);
    _history.add({'role': 'user', 'content': message});
    if (_ended) return;
    setState(() {
      _steps = [];
      _turnNumber++;
      _attachedFile = null;
      _attachmentProject = null;
      _lines.add((me: true, text: file == null ? heard : '$heard\n📎 $file'));
    });

    final settings = Get.find<SettingsController>();
    final canSpeakRemotely =
        WorkloadPlacement.forWorkload(PhoneWorkload.speech) != null ||
            (_voice.workerUrl.isNotEmpty && _lang == 'en');
    final sys = ((_ttsChoice(_lang) == null && !canSpeakRemotely) ||
            _hive.getSetting<bool>(_kSystemTts, defaultValue: false)!)
        ? (_lang == 'ar' ? 'ar' : 'en-US')
        : null;

    _interrupted = false;
    final ctl = StreamController<String>();
    try {
      var read = 0;
      var speechExpired = false;
      int? liveIdx;
      void caption(String sentence) {
        if (!mounted) return;
        setState(() {
          if (liveIdx == null) {
            _lines.add((me: false, text: sentence));
            liveIdx = _lines.length - 1;
          } else {
            _lines[liveIdx!] = (
              me: false,
              text: '${_lines[liveIdx!].text} $sentence',
            );
          }
        });
      }

      bool shouldStopSpeaking() => _ended || _interrupted || speechExpired;

      final speakingDone = _speakQueue(ctl.stream, sys,
          caption: caption, shouldStop: shouldStopSpeaking);

      void feed(String text, {bool flush = false}) {
        if (_ended || _interrupted) return;
        final v = _spoken(text);
        if (v.length < read) read = 0; // a new segment after a tool step
        final r = nextSentences(v, read, flush: flush);
        read = r.next;
        for (final sentence in r.sentences) {
          ctl.add(sentence);
        }
      }

      final shot = await _snap();
      if (_ended) return;
      final agent = Get.find<AgentService>();
      final inference = Get.find<InferenceService>();
      final session = _chat.currentSession;
      final basePrompt =
          session?.id == sessionId ? session?.systemPrompt : null;
      final skillContext = Get.isRegistered<SkillsService>()
          ? await Get.find<SkillsService>().prepare(
              heard, await agent.inProject(project, agent.filesDir),
              activeSkills: previouslyMentionedSkills(_chat.messages
                  .where((m) => m.chatId == sessionId && m.role == 'user')
                  .map((m) => m.content)))
          : null;
      final contextSize = inference.contextTokensTotal.value > 0
          ? inference.contextTokensTotal.value
          : 2048;
      final useTools = agent.wantsTools(heard,
          hasFile:
              file != null || (skillContext?.documents.isNotEmpty ?? false));
      final voiceSystem = '${basePrompt ?? settings.globalSystemPrompt.value}\n'
          'You are on a voice call. Speak naturally in one to three short sentences. No markdown, lists or emoji. '
          'If you used tools, just say the result.';
      String buildSystem([String latestContext = '']) =>
          agent.composeSystem(
            voiceSystem,
            withTools: useTools,
            request: heard,
            withFiles: file != null,
            contextSize: contextSize,
          ) +
          (skillContext == null || skillContext.documents.isEmpty
              ? ''
              : '\n\n${skillContext.prompt(contextSize ~/ 4, alreadyIncluded: latestContext)}');
      Future<String> gen(
        String prompt,
        List<Map<String, String>> hist,
        void Function(String) onTok,
      ) {
        final turn = AgentService.fitTurn(
          baseSystem: voiceSystem,
          system: buildSystem(hist.lastOrNull?['content'] ?? ''),
          prompt: prompt,
          history: hist,
          contextSize: contextSize,
          request: heard,
          continuationRequest:
              prompt == message ? null : 'Current user request: $heard',
          compactTools: !useTools
              ? null
              : (budget) => agent.toolPrompt(
                  request: heard,
                  withFiles: file != null,
                  contextSize: contextSize,
                  maxTokens: budget),
        );
        return inference.generate(
          prompt: turn.prompt,
          systemPrompt: turn.system,
          conversationHistory: turn.history,
          source: 'voice',
          imagePath: shot,
          maxTokens: useTools ? 500 : 160,
          onToken: onTok,
        );
      }

      String finalText;
      if (!useTools) {
        var raw = '';
        final reply = await gen(message, List.of(_history), (t) {
          raw += t;
          feed(raw);
        });
        finalText = raw.isEmpty ? reply : raw;
        feed(finalText, flush: true);
      } else {
        Future<ToolLoopResult> runAgentLoop() => agent.runToolLoop(
              generate: gen,
              allowDirectActions:
                  skillContext == null || skillContext.documents.isEmpty,
              prompt: message,
              history: List.of(_history),
              confirm: confirmToolCall,
              userText: heard,
              researchQuestion: agent.needsResearch(heard) ? heard : null,
              cancelled: () => _ended || _interrupted,
              onVisible: (v) => feed(v),
              onTrace: (trace) {
                if (mounted) {
                  setState(() => _steps = splitSteps(trace.join('\n')).$1);
                  _scrollCall();
                }
              },
              onStatus: (st) {
                if (!_speaking) _set(_CallState.thinking, st);
              },
            );
        final result = await agent.inProject(
            project,
            () => skillContext == null
                ? runAgentLoop()
                : SkillsService.inTurn(skillContext, runAgentLoop));
        finalText = result.markdown;
        feed(_spoken(finalText), flush: true);
        for (final m in RegExp(
          r'!\[[^\]]*\]\(nmfile:([^)]+)\)',
        ).allMatches(finalText)) {
          final f =
              await agent.inProject(project, () => agentFile(m.group(1)!));
          if (f != null && mounted) setState(() => _shots.add(f));
        }
      }
      unawaited(ctl.close());
      await speakingDone.timeout(
        const Duration(seconds: 180),
        onTimeout: () async {
          speechExpired = true;
          _speaking = false;
          await _voice.stopSpeaking();
        },
      );
      final clean = (_ended || _interrupted)
          ? (liveIdx == null ? '' : _lines[liveIdx!].text)
          : finalText;
      if (clean.trim().isNotEmpty) {
        await _chat.saveVoiceMessage(sessionId, 'assistant', clean,
            workspaceProject: project);
        _history.add({'role': 'assistant', 'content': stripToolTrace(clean)});
      }
      if (clean.trim().isNotEmpty && mounted) {
        setState(() {
          final line =
              (me: false, text: stripToolTrace(splitThoughtTags(clean).answer));
          if (liveIdx == null) {
            _lines.add(line);
          } else {
            _lines[liveIdx!] = line;
          }
        });
      }
    } finally {
      if (!ctl.isClosed) unawaited(ctl.close());
    }
  }

  void _finishTurn() {
    final continuation = Float64List.fromList(_interruptionAudio);
    _interruptionAudio.clear();
    _afterTurn();
    if (_ended) return;
    if (continuation.isNotEmpty) {
      if (_vad != null) {
        _onAudioVad(continuation);
      } else {
        _inSpeech = true;
        _speech.addAll(continuation);
      }
    } else if (_pending.isNotEmpty) {
      unawaited(_turn(_pending.removeAt(0)));
    }
  }

  /// Gets the call ready to hear the next question: clears every buffer and
  /// detector state left over from the last one.
  void _afterTurn() {
    _speaking = false;
    _busy = false;
    _interrupted = false;
    _inSpeech = false;
    _silentSamples = 0;
    _bargeFrames = 0;
    _bargeAudio.clear();
    _speech.clear();
    _preRoll.clear();
    _vadBuf.clear();
    try {
      _vad?.reset();
    } catch (_) {}
    _set(_CallState.listening, _listeningText());
  }

  static const _recConfig = RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: _rate,
      numChannels: 1,
      echoCancel: true,
      noiseSuppress: true);
  DateTime _lastAudio = DateTime.now();
  Timer? _micWatchdog;
  bool _micRestarting = false;

  /// Android can silently stop the microphone when the voice starts playing.
  /// If no audio arrives for a few seconds, open the microphone again.
  void _startMicWatchdog() {
    _micWatchdog?.cancel();
    _micWatchdog = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (_ended || _muted || _micRestarting) return;
      if (DateTime.now().difference(_lastAudio) < const Duration(seconds: 4))
        return;
      _micRestarting = true;
      try {
        await _sub?.cancel();
        if (_ended) return;
        await _rec.stop();
        if (_ended) return;
        final stream = await _rec.startStream(_recConfig);
        if (_ended) return;
        _lastAudio = DateTime.now();
        _sub = stream.listen(_onAudio);
      } catch (_) {
      } finally {
        _micRestarting = false;
      }
    });
  }

  Future<void> _toggleLang() async {
    final next = _lang == 'en' ? 'ar' : 'en';
    await _hive.setSetting(_kLang, next);
    if (!mounted) return;
    setState(() {
      _lang = next;
      _callVoice = null;
    });
    final stt = _installed(VoiceKind.stt);
    if (stt != null &&
        WorkloadPlacement.forWorkload(PhoneWorkload.transcription) == null) {
      _busy = true;
      _set(_CallState.starting, 'Switching language…');
      try {
        await _voice.loadStt(stt, language: next);
        final tts = _ttsChoice(next);
        if (tts != null && !_voice.ttsLoadedFor(tts)) await _voice.loadTts(tts);
      } catch (_) {}
      _busy = false;
      _set(_CallState.listening, _listeningText());
    }
  }

  Future<void> _chooseCallVoice() async {
    final clones = Get.find<VoiceCloneStore>();
    await clones.scan();
    if (!mounted) return;
    final voices = kVoiceModels
        .where(
          (model) =>
              model.kind == VoiceKind.tts &&
              !model.clone &&
              _store.installed.contains(model.id) &&
              (model.lang == _lang || model.lang == 'multi'),
        )
        .toList();
    final cloneModel = voiceModelById('pocket-tts-clone');
    final canClone =
        cloneModel != null && _store.installed.contains(cloneModel.id);
    if (voices.isEmpty && _lang != 'en') {
      await Get.to(() => const VoiceModelsView());
      return;
    }
    final current = _ttsChoice(_lang);
    var model = voices.contains(current) ? current! : voices.firstOrNull;
    var speaker = model == null ? 0 : VoiceService.savedSpeaker(model);
    final selected = await showAppSheet<(VoiceModelInfo, int)>(
      context,
      title: 'Speaking voice',
      builder: (context) => StatefulBuilder(
        builder: (context, update) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (clones.voices.isNotEmpty && canClone) ...[
              for (final name in clones.voices)
                ListTile(
                  leading: const Icon(Icons.record_voice_over_outlined),
                  title: Text(name),
                  subtitle: const Text('Cloned voice'),
                  selected:
                      clones.active.value == name && current == cloneModel,
                  onTap: () async {
                    await clones.select(name);
                    if (context.mounted) {
                      Navigator.of(context).pop((cloneModel, 0));
                    }
                  },
                ),
            ],
            TextButton.icon(
              icon: const Icon(Icons.graphic_eq),
              label: const Text('Open voice cloner'),
              onPressed: () {
                Navigator.of(context).pop();
                Get.to(() => const VoiceCloneView(allowCall: false));
              },
            ),
            if (voices.isNotEmpty)
              DropdownButtonFormField<VoiceModelInfo>(
                initialValue: model,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Model'),
                items: [
                  for (final choice in voices)
                    DropdownMenuItem(value: choice, child: Text(choice.title)),
                ],
                onChanged: (choice) {
                  if (choice != null)
                    update(() {
                      model = choice;
                      speaker = VoiceService.savedSpeaker(choice);
                    });
                },
              ),
            if (model?.speakers.isNotEmpty == true)
              DropdownButtonFormField<int>(
                key: ValueKey(model!.id),
                initialValue: speaker,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Speaker'),
                items: [
                  for (var i = 0; i < model!.speakers.length; i++)
                    DropdownMenuItem(value: i, child: Text(model!.speakers[i])),
                ],
                onChanged: (value) => update(() => speaker = value ?? 0),
              ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: model == null
                  ? null
                  : () => Navigator.of(context).pop((model!, speaker)),
              child: const Text('Use this voice'),
            ),
          ],
        ),
      ),
    );
    if (selected == null || !mounted) return;
    final (chosen, index) = selected;
    await VoiceService.saveSpeaker(chosen, index);
    await _hive.setSetting(_kTtsId, chosen.id);
    if (!mounted) return;
    final switchedLanguage = chosen.clone && _lang != 'en';
    if (switchedLanguage) {
      await _toggleLang();
    }
    if (mounted) setState(() => _callVoice = chosen);
  }

  Future<void> _editWake() async {
    final ctl = TextEditingController(text: _wake);
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Wake phrase'),
        content: TextField(
            controller: ctl,
            autofocus: true,
            decoration: const InputDecoration(
                hintText: 'e.g. hey neuro. Empty = answer everything')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, ctl.text),
              child: const Text('Save')),
        ],
      ),
    );
    if (r == null) return;
    await _hive.setSetting(_kWakePhrase, r.trim());
    setState(() => _wake = r.trim().toLowerCase());
    if (_state == _CallState.listening)
      _set(_CallState.listening, _listeningText());
  }

  @override
  Widget build(BuildContext context) {
    final color = switch (_state) {
      _CallState.listening => Colors.green,
      _CallState.thinking => Colors.orange,
      _CallState.speaking => Colors.blue,
      _CallState.error => Colors.red,
      _ => Colors.grey,
    };
    return Scaffold(
      appBar: AppBar(
          title: Text(_chat.currentSession?.title ?? 'Voice call',
              maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(
              tooltip: 'End call and open text chat',
              icon: const Icon(Icons.chat_bubble_outline),
              onPressed: () {
                Get.find<HomeController>().changeTab(0);
                Get.back<void>();
              },
            ),
            IconButton(
              tooltip: 'Agent workspace',
              icon: const Icon(Icons.folder_open_outlined),
              onPressed: () => Get.to(() => const AgentWorkspaceView()),
            ),
            IconButton(
              tooltip: 'Choose speaking voice',
              icon: const Icon(Icons.record_voice_over_outlined),
              onPressed: _busy || _speaking ? null : _chooseCallVoice,
            ),
            IconButton(
                tooltip: 'Wake phrase',
                icon: Icon(_wake.isEmpty
                    ? Icons.hearing_disabled_outlined
                    : Icons.hearing),
                onPressed: _editWake),
            IconButton(
                tooltip: _bargeIn
                    ? 'Interrupting: on (use headphones)'
                    : 'Interrupting: off',
                icon: Icon(
                    _bargeIn ? Icons.front_hand : Icons.front_hand_outlined),
                onPressed: () async {
                  setState(() => _bargeIn = !_bargeIn);
                  await _hive.setSetting(_kBargeIn, _bargeIn);
                }),
            TextButton(
                onPressed: _busy ? null : _toggleLang,
                child: Text(_lang == 'en' ? 'English' : 'العربية')),
          ]),
      body: SafeArea(
        child: Column(children: [
          ListTile(
            dense: true,
            leading: const Icon(Icons.call_outlined),
            title: Text(
                Get.find<InferenceService>().loadedModelName.value.isEmpty
                    ? 'NeuroMesh AI'
                    : Get.find<InferenceService>().loadedModelName.value),
            subtitle: Text(_ttsChoice(_lang)?.clone == true
                ? Get.find<VoiceCloneStore>().active.value
                : _ttsChoice(_lang)?.title ?? 'Voice call'),
          ),
          if (_cam != null && _cam!.value.isInitialized)
            SizedBox(
                height: 150,
                child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: CameraPreview(_cam!))),
          Expanded(
            child: ListView(
                controller: _callScroll,
                padding: const EdgeInsets.all(16),
                children: [
                  if (_vad == null && _state == _CallState.listening)
                    const Padding(
                        padding: EdgeInsets.only(bottom: 8),
                        child: Text(
                            'Tip: install the smart speech detector (Toolbox → Voice models) for better turn-taking.',
                            style: TextStyle(fontSize: 12))),
                  for (final l in _lines)
                    Align(
                      alignment:
                          l.me ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                            color: color.withValues(alpha: l.me ? 0.15 : 0.07),
                            borderRadius: BorderRadius.circular(14)),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(l.me ? 'You' : 'AI',
                                style: Theme.of(context).textTheme.labelSmall),
                            if (l.me)
                              SelectableText(l.text)
                            else
                              _VoiceAnswer(
                                text: l.text,
                                workspaceProject: Get.find<AgentService>()
                                    .projectForChat(_sessionId),
                              ),
                          ],
                        ),
                      ),
                    ),
                  if (_steps.isNotEmpty)
                    AgentStepsView(
                        steps: _steps,
                        messageId: 'voice-$_turnNumber',
                        live: _busy),
                  if (_shots.isNotEmpty)
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      for (final f in _shots)
                        GestureDetector(
                          onTap: () => ImageViewer.showFile(context, f),
                          child: ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: Image.file(f,
                                  height: 160, fit: BoxFit.cover)),
                        ),
                    ]),
                ]),
          ),
          if (_attachedFile case final name?)
            InputChip(
              avatar: const Icon(Icons.attach_file),
              label: Text(name, overflow: TextOverflow.ellipsis),
              onPressed: _busy ? null : _sendAttachment,
              onDeleted:
                  _busy ? null : () => setState(() => _attachedFile = null),
            ),
          if (_speaking && !_interrupted)
            TextButton.icon(
              icon: const Icon(Icons.mic),
              label: const Text('Interrupt and talk'),
              onPressed: _interrupt,
            ),
          Icon(Icons.graphic_eq_rounded, size: 48, color: color),
          Padding(
              padding: const EdgeInsets.all(8),
              child: Text(_status, textAlign: TextAlign.center)),
          Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              IconButton.filledTonal(
                  iconSize: 28,
                  onPressed: () => setState(() => _muted = !_muted),
                  icon: Icon(_muted ? Icons.mic_off : Icons.mic)),
              const SizedBox(width: 16),
              IconButton.filledTonal(
                  tooltip: 'Attach a file',
                  onPressed: _busy || _addingFile ? null : _attachFile,
                  icon: const Icon(Icons.attach_file)),
              const SizedBox(width: 12),
              IconButton.filledTonal(
                  iconSize: 28,
                  tooltip: 'Video call (vision models)',
                  onPressed: _camBusy ? null : _toggleCamera,
                  icon: Icon(_cam != null
                      ? Icons.videocam
                      : Icons.videocam_off_outlined)),
              if (_cam != null &&
                  _callCameras
                      .any((camera) => camera.lensDirection == _otherCamera))
                IconButton(
                  tooltip: 'Switch camera',
                  onPressed: _camBusy || _cam!.value.isTakingPicture
                      ? null
                      : () => _openCallCamera(_otherCamera),
                  icon: const Icon(Icons.cameraswitch_outlined),
                ),
              const SizedBox(width: 16),
              IconButton.filled(
                  iconSize: 28,
                  style: IconButton.styleFrom(backgroundColor: Colors.red),
                  onPressed: () => Get.back(),
                  icon: const Icon(Icons.call_end_rounded)),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _VoiceAnswer extends StatelessWidget {
  const _VoiceAnswer({required this.text, required this.workspaceProject});
  final String text;
  final String workspaceProject;

  @override
  Widget build(BuildContext context) {
    final clean = splitThoughtTags(stripToolTrace(text)).answer;
    final (answer, sources) = ChatBubble.splitSources(clean);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (answer.trim().isNotEmpty)
          AssistantMarkdown(text: answer, workspaceProject: workspaceProject),
        if (sources.isNotEmpty)
          ChatSourcesList(sources: sources, muted: Theme.of(context).hintColor),
      ],
    );
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';

import '../controllers/settings_controller.dart';
import '../core/constants.dart';
import 'agent_service.dart';
import 'inference_service.dart';
import 'opencode_tools.dart';
import 'voice_service.dart';

class OpenAiServerService {
  OpenAiServerService()
      : _agentModel = null,
        _allowTools = false,
        _workspace = null;

  /// A restricted, authenticated listener for a single local agent session.
  OpenAiServerService.forAgentModel(String modelName,
      {bool allowTools = false, Directory? workspace})
      : _agentModel = modelName,
        _allowTools = allowTools,
        _workspace = workspace;

  static const agentModelId = 'loaded';
  final String? _agentModel;
  final bool _allowTools;
  final Directory? _workspace;
  int? _agentModelRevision;
  late final String _generationSource =
      _agentModel == null ? 'server' : 'agentBridge-${_id()}';
  _SseStream? _agentStream;
  void Function(String)? onAgentText;

  HttpServer? _server;
  bool _busy = false;
  String? _apiKey;
  void Function(String)? _onLog;

  bool get isRunning => _server != null;
  String? get localUrl {
    final port = _server?.port;
    if (port == null) return null;
    final host = _lastReachableAddress;
    return 'http://${host ?? '127.0.0.1'}:$port';
  }

  String? _lastReachableAddress;

  static const int maxBodyBytes = 18 * 1024 * 1024;
  static const int maxDecodedAttachmentBytes = 12 * 1024 * 1024;

  /// When [allowNetwork] is false the server only listens on loopback, so it
  /// is reachable from this device only. Network mode must be paired with an
  /// API key; the caller is responsible for supplying one.
  Future<void> start({
    int port = 8080,
    String? apiKey,
    bool allowNetwork = false,
    void Function(String)? onLog,
  }) async {
    if (_server != null) return;
    if (_agentModel != null) {
      if (allowNetwork || (apiKey?.trim().isEmpty ?? true)) {
        throw ArgumentError(
            'The agent bridge requires a key and loopback access.');
      }
      final inference = Get.find<InferenceService>();
      if (!inference.isModelLoaded.value ||
          inference.loadedModelName.value != _agentModel) {
        throw StateError('Load the selected model before opening the bridge.');
      }
      _agentModelRevision = inference.modelRevision;
    }
    if (allowNetwork && (apiKey == null || apiKey.trim().isEmpty)) {
      throw ArgumentError('An API key is required for network access.');
    }
    updateApiKey(apiKey);
    _onLog = onLog;
    _lastReachableAddress = allowNetwork ? await _reachableIpv4Address() : null;
    _server = await HttpServer.bind(
      allowNetwork ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4,
      port,
    );
    _onLog?.call('Server listening on ${localUrl ?? 'http://localhost:$port'}');
    unawaited(_serve(_server!));
  }

  /// Applies a new API key to the running server without a restart.
  void updateApiKey(String? apiKey) {
    final key = apiKey?.trim();
    if (_agentModel != null && (key == null || key.isEmpty)) {
      throw ArgumentError('The agent bridge requires an API key.');
    }
    _apiKey = (key == null || key.isEmpty) ? null : key;
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
    if (_agentModel != null && Get.isRegistered<InferenceService>()) {
      final inference = Get.find<InferenceService>();
      if (inference.generationSource.value == _generationSource) {
        await inference.stopGeneration();
      }
    }
    await _agentStream?.close();
    _busy = false;
    _onLog?.call('Server stopped');
  }

  Future<void> _serve(HttpServer server) async {
    await for (final request in server) {
      unawaited(_handle(request));
    }
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      final path = request.uri.path;
      if (_agentModel != null) {
        if (!_isAuthorized(request)) {
          await _bridgeError(request, 'Unauthorized', HttpStatus.unauthorized);
          return;
        }
        final allowed = (request.method == 'GET' && path == '/v1/models') ||
            (request.method == 'POST' && path == '/v1/chat/completions');
        if (!allowed) {
          await _bridgeError(request, 'Not found', HttpStatus.notFound);
          return;
        }
      }
      _addCorsHeaders(request.response);
      if (request.method == 'OPTIONS') {
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
        return;
      }

      if (request.method == 'GET' && path == '/health') {
        await _json(request, {'status': 'ok'});
        return;
      }

      if (path.startsWith('/v1/') && !_isAuthorized(request)) {
        await _json(request, {'error': 'Unauthorized'},
            status: HttpStatus.unauthorized);
        return;
      }

      // Requiring a JSON content type forces browsers to send a CORS
      // preflight, so web pages can't fire "simple" cross-origin requests.
      if (path.startsWith('/v1/files') && request.method == 'GET') {
        await _handleFilesGet(request, path);
        return;
      }

      if (request.method == 'POST' &&
          request.headers.contentType?.mimeType != ContentType.json.mimeType) {
        await _json(request, {'error': 'Content-Type must be application/json'},
            status: HttpStatus.unsupportedMediaType);
        return;
      }

      if (request.method == 'GET' && path == '/v1/models') {
        await _handleModels(request);
        return;
      }
      if (request.method == 'GET' && path == '/v1/server/capabilities') {
        await _handleCapabilities(request);
        return;
      }
      if (request.method == 'POST' && path == '/v1/chat/completions') {
        await _handleChatCompletions(request);
        return;
      }
      if (request.method == 'POST' && path == '/v1/audio/transcriptions') {
        await _handleTranscribe(request);
        return;
      }
      if (request.method == 'POST' && path == '/v1/audio/speech') {
        await _handleSpeech(request);
        return;
      }
      if (request.method == 'POST' && path == '/v1/images/generations') {
        await _handleImages(request);
        return;
      }
      if (request.method == 'POST' && path == '/v1/files') {
        await _handleFilePost(request);
        return;
      }
      if (request.method == 'POST' && path == '/v1/completions') {
        await _handleCompletions(request);
        return;
      }

      await _json(request, {'error': 'Not found'}, status: HttpStatus.notFound);
    } catch (error) {
      _onLog?.call('Request failed: $error');
      try {
        await _json(
          request,
          {'error': 'Internal server error'},
          status: HttpStatus.internalServerError,
        );
      } catch (_) {
        // The response may already be closed or detached (streaming).
        try {
          await request.response.close();
        } catch (_) {}
      }
    }
  }

  bool _isAuthorized(HttpRequest request) {
    final key = _apiKey;
    if (key == null || key.isEmpty) return true;
    final header = request.headers.value(HttpHeaders.authorizationHeader) ?? '';
    return _constantTimeEquals(header.trim(), 'Bearer $key');
  }

  static bool _constantTimeEquals(String a, String b) {
    final x = utf8.encode(a);
    final y = utf8.encode(b);
    var diff = x.length ^ y.length;
    for (var i = 0; i < x.length && i < y.length; i++) {
      diff |= x[i] ^ y[i];
    }
    return diff == 0;
  }

  // ── Outputs: files, audio and images ──────────────────────────────────

  Future<void> _handleFilesGet(HttpRequest request, String path) async {
    final agent = Get.find<AgentService>();
    if (path == '/v1/files') {
      await _json(
          request, {'object': 'list', 'data': await agent.listWorkspace()});
      return;
    }
    final name = Uri.decodeComponent(path.substring('/v1/files/'.length))
        .replaceAll('/content', '');
    final f = await agent.workspaceFile(name);
    if (f == null) {
      await _json(request, {'error': 'File not found'},
          status: HttpStatus.notFound);
      return;
    }
    final ext = name.split('.').last.toLowerCase();
    const types = {
      'png': 'image/png',
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'wav': 'audio/wav',
      'mp3': 'audio/mpeg',
      'txt': 'text/plain; charset=utf-8',
      'md': 'text/markdown; charset=utf-8',
      'json': 'application/json',
      'csv': 'text/csv; charset=utf-8',
      'html': 'text/html; charset=utf-8',
      'pdf': 'application/pdf',
    };
    _addCorsHeaders(request.response);
    request.response.headers.set(HttpHeaders.contentTypeHeader,
        types[ext] ?? 'application/octet-stream');
    request.response.headers.set('Content-Disposition',
        'attachment; filename="${f.path.split('/').last}"');
    await request.response.addStream(f.openRead());
    await request.response.close();
  }

  Future<void> _handleFilePost(HttpRequest request) async {
    final body = await _readJson(request);
    final name = '${body['name'] ?? ''}';
    final b64 = '${body['content_base64'] ?? ''}';
    if (name.isEmpty || b64.isEmpty) {
      await _json(request, {'error': 'name and content_base64 are required'},
          status: HttpStatus.badRequest);
      return;
    }
    final f = await Get.find<AgentService>().newWorkspaceFile(name);
    await f.writeAsBytes(base64Decode(b64));
    await _json(
        request, {'name': f.path.split('/').last, 'bytes': await f.length()});
  }

  /// JSON body: {"audio_base64": "...", "file_name": "voice.mp3", "language": "en"}
  Future<void> _handleTranscribe(HttpRequest request) async {
    final body = await _readJson(request);
    final b64 = '${body['audio_base64'] ?? body['file'] ?? ''}';
    if (b64.isEmpty) {
      await _json(request, {'error': 'audio_base64 is required'},
          status: HttpStatus.badRequest);
      return;
    }
    final agent = Get.find<AgentService>();
    final ext = '${body['file_name'] ?? 'audio.wav'}'.split('.').last;
    final tmp = await agent.newWorkspaceFile(
        'api_upload_${DateTime.now().millisecondsSinceEpoch}.$ext');
    try {
      await tmp.writeAsBytes(base64Decode(b64));
      final text = await Get.find<VoiceService>()
          .transcribeFile(tmp.path, language: '${body['language'] ?? ''}');
      await _json(request, {'text': text});
    } catch (e) {
      await _json(request, {'error': '$e'},
          status: HttpStatus.internalServerError);
    } finally {
      if (await tmp.exists()) await tmp.delete();
    }
  }

  /// JSON body: {"input": "text to speak"} → audio/wav
  Future<void> _handleSpeech(HttpRequest request) async {
    final body = await _readJson(request);
    final text = '${body['input'] ?? ''}'.trim();
    if (text.isEmpty) {
      await _json(request, {'error': 'input is required'},
          status: HttpStatus.badRequest);
      return;
    }
    try {
      final wav = await Get.find<VoiceService>().synthesizeToWav(text);
      _addCorsHeaders(request.response);
      request.response.headers.set(HttpHeaders.contentTypeHeader, 'audio/wav');
      request.response.add(wav);
      await request.response.close();
    } catch (e) {
      await _json(request, {'error': '$e'},
          status: HttpStatus.internalServerError);
    }
  }

  /// JSON body: {"prompt": "..."} → {"data":[{"b64_json":"..."}]}
  Future<void> _handleImages(HttpRequest request) async {
    final body = await _readJson(request);
    final prompt = '${body['prompt'] ?? ''}'.trim();
    if (prompt.isEmpty) {
      await _json(request, {'error': 'prompt is required'},
          status: HttpStatus.badRequest);
      return;
    }
    final agent = Get.find<AgentService>();
    final name = 'api_image_${DateTime.now().millisecondsSinceEpoch}.png';
    final r = await agent
        .callTool('generate_image', {'prompt': prompt, 'name': name});
    final f = await agent.workspaceFile(name);
    if (f == null) {
      await _json(request, {'error': r},
          status: HttpStatus.internalServerError);
      return;
    }
    await _json(request, {
      'created': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'data': [
        {'b64_json': base64Encode(await f.readAsBytes()), 'file': name}
      ],
    });
  }

  Future<void> _handleModels(HttpRequest request) async {
    final inference = Get.find<InferenceService>();
    final hasModel = _localModelError(inference) == null;
    await _json(request, {
      'object': 'list',
      'data': [
        if (hasModel)
          {
            'id': _responseModel(inference),
            if (_agentModel != null) 'name': _agentModel,
            if (_agentModel != null) 'tool_calling': _allowTools,
            'object': 'model',
            'created': DateTime.now().millisecondsSinceEpoch ~/ 1000,
            'owned_by': 'local',
          }
      ],
    });
  }

  Future<void> _handleCapabilities(HttpRequest request) async {
    final inference = Get.find<InferenceService>();
    final hasModel = inference.isModelLoaded.value;
    final isLiteRt = hasModel && inference.loadedModelRuntime.value == 'litert';
    await _json(request, {
      'server': 'AI Chat Local OpenAI API',
      'running': true,
      'model': hasModel ? inference.loadedModelName.value : null,
      'runtime': inference.loadedModelRuntime.value,
      'requires_litert': false,
      'capabilities': {
        'text': hasModel,
        'image': isLiteRt && inference.isVisionLoaded.value,
        'audio': isLiteRt,
        'streaming': hasModel,
        'gguf': hasModel && !isLiteRt,
      },
    });
  }

  Future<void> _handleChatCompletions(HttpRequest request) async {
    final inference = Get.find<InferenceService>();
    if (!await _acquire(request, inference)) return;
    final tempFiles = <File>[];
    try {
      final body = await _readJson(request);
      if (_agentModel != null) {
        final error = _agentRequestError(body);
        if (error != null) {
          await _bridgeError(request, error, HttpStatus.badRequest);
          return;
        }
      }
      // One model is loaded at a time, and clients (PC chat apps, editors)
      // often send their own model name: serve the loaded model regardless,
      // as llama-server and LM Studio do.
      final model = (body['model'] as String?)?.trim();
      if (_agentModel == null &&
          model != null &&
          model.isNotEmpty &&
          model != inference.loadedModelName.value) {
        _onLog?.call(
            'Request for "$model"; serving ${inference.loadedModelName.value}');
      }

      final tools = OpenCodeTools(_allowTools ? body['tools'] : null,
          workspace: _workspace);
      final parsed = await _parseChatRequest(body, tempFiles, tools: tools);
      if (parsed.error != null) {
        await _json(request, {'error': parsed.error},
            status: HttpStatus.badRequest);
        return;
      }

      if (_agentModel != null) {
        if (!isRunning) return;
        final error = _localModelError(inference);
        if (error != null) {
          await _bridgeError(request, error, HttpStatus.conflict);
          return;
        }
        if (inference.isGenerating.value) {
          await _bridgeError(request, 'Model is busy', 429);
          return;
        }
      }

      final maxTokens = _maxTokens(body);
      final stop = _stop(body);
      if (body['stream'] == true) {
        await _streamChatResponse(
            request, inference, parsed, maxTokens, stop, tools);
      } else {
        final stopsBefore = inference.stopCount;
        final text = await inference.generate(
          prompt: parsed.prompt,
          systemPrompt: parsed.systemPrompt ??
              _defaultSystemPrompt(inference.loadedModelName.value),
          conversationHistory: parsed.history,
          source: _generationSource,
          imagePath: parsed.imagePath,
          audioPath: parsed.audioPath,
          maxTokens: maxTokens,
          stopSequences: stop,
        );
        if (inference.stopCount != stopsBefore) {
          await _interrupted(request);
          return;
        }
        if (_agentModel != null && text.startsWith('ERROR:')) {
          await _bridgeError(request, text, HttpStatus.badGateway);
          return;
        }
        await _json(
            request,
            _chatResponse(_responseModel(inference), text,
                toolCall: tools.parse(text, _id())));
      }
    } finally {
      await _agentStream?.close();
      _agentStream = null;
      _busy = false;
      await _deleteFiles(tempFiles);
    }
  }

  /// Claims the model for one request. Rejects before the body is read when
  /// a server request or an in-app generation is already running, and marks
  /// the server busy synchronously so concurrent requests can't both pass.
  Future<bool> _acquire(HttpRequest request, InferenceService inference) async {
    final modelError = _localModelError(inference);
    if (modelError != null) {
      if (_agentModel != null) {
        await _bridgeError(request, modelError, HttpStatus.conflict);
      } else {
        await _json(request, {'error': modelError},
            status: HttpStatus.badRequest);
      }
      return false;
    }
    if (_busy || inference.isGenerating.value) {
      if (_agentModel != null) {
        await _bridgeError(request, 'Model is busy', 429);
      } else {
        await _json(request, {'error': 'Model is busy'}, status: 429);
      }
      return false;
    }
    _busy = true;
    return true;
  }

  Future<void> _interrupted(HttpRequest request) => _json(
        request,
        {
          'error':
              'Generation was interrupted (the app started its own response)'
        },
        status: HttpStatus.serviceUnavailable,
      );

  /// OpenAI `stop`: a string or a list of up to 4 strings.
  List<String> _stop(Map<String, dynamic> body) {
    final raw = body['stop'];
    if (raw is String) return raw.isEmpty ? const [] : [raw];
    if (raw is List) {
      return raw
          .whereType<String>()
          .where((s) => s.isNotEmpty)
          .take(4)
          .toList();
    }
    return const [];
  }

  int? _maxTokens(Map<String, dynamic> body) {
    final raw = body['max_completion_tokens'] ?? body['max_tokens'];
    return raw is num && raw > 0 ? raw.toInt() : null;
  }

  Future<void> _deleteFiles(List<File> files) async {
    for (final file in files) {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
  }

  Future<void> _handleCompletions(HttpRequest request) async {
    final inference = Get.find<InferenceService>();
    if (!await _acquire(request, inference)) return;
    try {
      final body = await _readJson(request);
      final prompt = body['prompt'];
      if (prompt is! String || prompt.trim().isEmpty) {
        await _json(request, {'error': 'prompt is required'},
            status: HttpStatus.badRequest);
        return;
      }

      final maxTokens = _maxTokens(body);
      final stop = _stop(body);
      if (body['stream'] == true) {
        await _streamCompletionResponse(
            request, inference, prompt, maxTokens, stop);
      } else {
        final stopsBefore = inference.stopCount;
        final text = await inference.generate(
          prompt: prompt,
          systemPrompt: _defaultSystemPrompt(inference.loadedModelName.value),
          source: 'server',
          maxTokens: maxTokens,
          stopSequences: stop,
        );
        if (inference.stopCount != stopsBefore) {
          await _interrupted(request);
          return;
        }
        await _json(request, {
          'id': 'cmpl-${_id()}',
          'object': 'text_completion',
          'created': DateTime.now().millisecondsSinceEpoch ~/ 1000,
          'model': inference.loadedModelName.value,
          'choices': [
            {'index': 0, 'text': text, 'finish_reason': 'stop'}
          ],
        });
      }
    } finally {
      _busy = false;
    }
  }

  String? _localModelError(InferenceService inference) {
    if (_agentModel != null &&
        (!inference.isModelLoaded.value ||
            inference.loadedModelName.value != _agentModel ||
            inference.modelRevision != _agentModelRevision)) {
      return 'The linked model changed. Disconnect and reconnect OpenCode.';
    }
    if (!inference.isModelLoaded.value) {
      return 'No local model loaded. Load a GGUF or LiteRT-LM model first.';
    }
    return null;
  }

  String? _agentRequestError(Map<String, dynamic> body) {
    if (body['model'] != agentModelId) {
      return 'Select the linked NeuroMesh model.';
    }
    final tools = body['tools'];
    if ((!_allowTools &&
            tools != null &&
            (tools is! List || tools.isNotEmpty)) ||
        body['tool_choice'] is Map ||
        body['tool_choice'] == 'required' ||
        body['functions'] != null ||
        body['function_call'] != null) {
      return 'Tool calling is unavailable on this bridge.';
    }
    final messages = body['messages'];
    if (messages is List) {
      for (final message in messages.whereType<Map>()) {
        final content = message['content'];
        if (!_allowTools &&
            (message['tool_calls'] != null || message['role'] == 'tool')) {
          return 'Tool calling is unavailable on this bridge.';
        }
        if (content is List &&
            content.any((part) => part is! Map || part['type'] != 'text')) {
          return 'Only text messages are supported on this bridge.';
        }
      }
    }
    return null;
  }

  Future<void> _bridgeError(HttpRequest request, String message, int status) =>
      _json(
          request,
          {
            'error': {'message': message}
          },
          status: status);

  String _responseModel(InferenceService inference) =>
      _agentModel == null ? inference.loadedModelName.value : agentModelId;

  /// Temp files are appended to [tempFiles] as they're written so the caller
  /// can always delete them, including when parsing fails part-way.
  Future<_ParsedChatRequest> _parseChatRequest(
      Map<String, dynamic> body, List<File> tempFiles,
      {required OpenCodeTools tools}) async {
    final rawMessages = body['messages'];
    if (rawMessages is! List || rawMessages.isEmpty) {
      return _ParsedChatRequest.error('messages must be a non-empty array');
    }

    final systemParts = <String>[];
    final history = <Map<String, String>>[];
    var lastUserText = '';
    String? imagePath;
    String? audioPath;

    for (var i = 0; i < rawMessages.length; i++) {
      final raw = rawMessages[i];
      if (raw is! Map) {
        return _ParsedChatRequest.error('message[$i] must be an object');
      }
      final rawRole = '${raw['role'] ?? ''}';
      final role = _allowTools && rawRole == 'tool' ? 'user' : rawRole;
      if (role != 'system' && role != 'user' && role != 'assistant') {
        return _ParsedChatRequest.error('message[$i].role is unsupported');
      }
      final content =
          _allowTools && (rawRole == 'tool' || raw['tool_calls'] != null)
              ? OpenCodeTools.textForMessage(raw)
              : raw['content'];
      final contentResult = await _parseContent(content, tempFiles);
      if (contentResult.error != null) {
        return _ParsedChatRequest.error(contentResult.error!);
      }
      imagePath ??= contentResult.imagePath;
      audioPath ??= contentResult.audioPath;

      if (role == 'system') {
        if (contentResult.text.trim().isNotEmpty) {
          systemParts.add(contentResult.text.trim());
        }
        continue;
      }
      if (i == rawMessages.length - 1 && role == 'user') {
        lastUserText = contentResult.text.trim();
      } else {
        history.add({'role': role, 'content': contentResult.text});
      }
    }

    if (lastUserText.isEmpty && imagePath == null && audioPath == null) {
      return _ParsedChatRequest.error(
          'last user message must contain text, image, or audio');
    }

    if (!tools.isEmpty) systemParts.add(tools.instructions);
    return _ParsedChatRequest(
      prompt: lastUserText.isEmpty ? 'Describe this attachment.' : lastUserText,
      systemPrompt: systemParts.isEmpty ? null : systemParts.join('\n'),
      history: history,
      imagePath: imagePath,
      audioPath: audioPath,
    );
  }

  Future<_ContentResult> _parseContent(
      dynamic content, List<File> tempFiles) async {
    if (content is String) return _ContentResult(text: content);
    if (content is! List) {
      return _ContentResult.error(
          'message.content must be a string or content array');
    }

    final text = StringBuffer();
    String? imagePath;
    String? audioPath;

    for (final part in content) {
      if (part is! Map) {
        return _ContentResult.error('content part must be an object');
      }
      final type = '${part['type'] ?? ''}';
      if (type == 'text') {
        text.write('${part['text'] ?? ''}');
      } else if (type == 'image_url') {
        if (imagePath != null) {
          return _ContentResult.error(
              'only one image is supported per request');
        }
        final imageUrl = part['image_url'];
        final url = imageUrl is Map ? '${imageUrl['url'] ?? ''}' : '';
        final file = await _dataUrlToTempFile(url, 'image');
        if (file.error != null) return _ContentResult.error(file.error!);
        imagePath = file.path;
        tempFiles.add(file.file!);
      } else if (type == 'input_audio' || type == 'audio_url') {
        if (audioPath != null) {
          return _ContentResult.error(
              'only one audio file is supported per request');
        }
        final raw = part[type == 'input_audio' ? 'input_audio' : 'audio_url'];
        final data = raw is Map ? '${raw['data'] ?? raw['url'] ?? ''}' : '';
        final file = await _dataUrlToTempFile(data, 'audio');
        if (file.error != null) return _ContentResult.error(file.error!);
        audioPath = file.path;
        tempFiles.add(file.file!);
      } else {
        return _ContentResult.error('unsupported content part type: $type');
      }
    }

    return _ContentResult(
      text: text.toString(),
      imagePath: imagePath,
      audioPath: audioPath,
    );
  }

  Future<_TempFileResult> _dataUrlToTempFile(String value, String kind) async {
    if (!value.startsWith('data:')) {
      return _TempFileResult.error(
          'Only base64 data URLs are accepted for $kind input');
    }
    final comma = value.indexOf(',');
    if (comma <= 0 || !value.substring(0, comma).contains(';base64')) {
      return _TempFileResult.error('$kind input must be a base64 data URL');
    }
    final meta = value.substring(5, comma).toLowerCase();
    final encoded = value.substring(comma + 1);
    if (encoded.length > maxDecodedAttachmentBytes * 2) {
      return _TempFileResult.error('$kind input is too large');
    }
    late List<int> bytes;
    try {
      bytes = base64Decode(encoded);
    } catch (_) {
      return _TempFileResult.error('$kind input has invalid base64');
    }
    if (bytes.length > maxDecodedAttachmentBytes) {
      return _TempFileResult.error('$kind input is too large');
    }
    final ext = _extensionForMime(meta, kind);
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/server_${kind}_${_id()}.$ext');
    await file.writeAsBytes(bytes, flush: true);
    return _TempFileResult(file);
  }

  String _extensionForMime(String mime, String kind) {
    if (mime.contains('png')) return 'png';
    if (mime.contains('webp')) return 'webp';
    if (mime.contains('jpg') || mime.contains('jpeg')) return 'jpg';
    if (mime.contains('wav')) return 'wav';
    if (mime.contains('mp3') || mime.contains('mpeg')) return 'mp3';
    if (mime.contains('m4a') || mime.contains('mp4')) return 'm4a';
    return kind == 'image' ? 'png' : 'wav';
  }

  Future<void> _streamChatResponse(
    HttpRequest request,
    InferenceService inference,
    _ParsedChatRequest parsed,
    int? maxTokens,
    List<String> stop,
    OpenCodeTools tools,
  ) async {
    final response = request.response;
    _addCorsHeaders(response);
    final id = 'chatcmpl-${_id()}';
    final created = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    var emitted = false;
    final sse = await _SseStream.open(response, onDisconnect: () {
      if (inference.generationSource.value == _generationSource) {
        unawaited(inference.stopGeneration());
      }
    });

    void chunk(Map<String, dynamic> delta, {String? finishReason}) {
      sse.event({
        'id': id,
        'object': 'chat.completion.chunk',
        'created': created,
        'model': _responseModel(inference),
        'choices': [
          {
            'index': 0,
            'delta': delta,
            'finish_reason': finishReason,
          }
        ],
      });
    }

    void emit(String token) {
      emitted = true;
      chunk({'content': token});
      onAgentText?.call(token);
    }

    const toolPrefix = '<tool_call>';
    var undecided = '';
    bool? plainText;
    void emitUnlessTool(String token) {
      if (plainText == true) {
        emit(token);
        return;
      }
      if (plainText == false) return;
      undecided += token;
      final start = undecided.trimLeft();
      if (start.startsWith(toolPrefix)) {
        plainText = false;
      } else if (!toolPrefix.startsWith(start)) {
        plainText = true;
        emit(undecided);
      }
    }

    if (_agentModel != null) {
      _agentStream = sse;
      final error = _localModelError(inference);
      if (!isRunning || error != null || inference.isGenerating.value) {
        sse.event({
          'error': {'message': error ?? 'Model is busy or disconnected'},
        });
        await sse.close();
        return;
      }
      chunk({'role': 'assistant'});
    }
    final stopsBefore = inference.stopCount;
    final result = await inference.generate(
      prompt: parsed.prompt,
      systemPrompt: parsed.systemPrompt ??
          _defaultSystemPrompt(inference.loadedModelName.value),
      conversationHistory: parsed.history,
      source: _generationSource,
      imagePath: parsed.imagePath,
      audioPath: parsed.audioPath,
      maxTokens: maxTokens,
      stopSequences: stop,
      onToken: tools.isEmpty ? emit : emitUnlessTool,
    );
    if (_agentModel != null && result.startsWith('ERROR:')) {
      sse.event({
        'error': {'message': result}
      });
      await sse.close();
      return;
    }
    final toolCall = tools.parse(result, _id());
    if (toolCall != null && inference.stopCount == stopsBefore) {
      chunk({
        'tool_calls': [
          {'index': 0, ...toolCall}
        ]
      });
      chunk({}, finishReason: 'tool_calls');
      sse.raw('data: [DONE]\n\n');
      await sse.close();
      return;
    }
    if (!tools.isEmpty && result.trimLeft().startsWith(toolPrefix)) {
      sse.event({
        'error': {
          'message': 'The model returned an invalid workspace tool call.'
        },
      });
      await sse.close();
      return;
    }
    await _finishStream(
      sse,
      inference,
      stopsBefore,
      emitted ? null : result,
      emit,
      beforeDone:
          _agentModel == null ? null : () => chunk({}, finishReason: 'stop'),
    );
  }

  /// Ends an SSE stream: reports an interruption as an error event rather
  /// than a normal [DONE], so clients don't mistake a partial answer for a
  /// complete one.
  Future<void> _finishStream(
    _SseStream sse,
    InferenceService inference,
    int stopsBefore,
    String? unemittedResult,
    void Function(String) emit, {
    void Function()? beforeDone,
  }) async {
    if (inference.stopCount != stopsBefore) {
      sse.event({
        'error': {
          'message': 'Generation was interrupted',
          'type': 'interrupted',
        }
      });
    } else {
      if (unemittedResult != null && unemittedResult.isNotEmpty) {
        emit(unemittedResult);
      }
      beforeDone?.call();
      sse.raw('data: [DONE]\n\n');
    }
    await sse.close();
  }

  Future<void> _streamCompletionResponse(
    HttpRequest request,
    InferenceService inference,
    String prompt,
    int? maxTokens,
    List<String> stop,
  ) async {
    final response = request.response;
    _addCorsHeaders(response);
    final id = 'cmpl-${_id()}';
    final created = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    var emitted = false;
    final sse = await _SseStream.open(response, onDisconnect: () {
      if (inference.generationSource.value == 'server') {
        unawaited(inference.stopGeneration());
      }
    });

    void emit(String token) {
      emitted = true;
      sse.event({
        'id': id,
        'object': 'text_completion',
        'created': created,
        'model': inference.loadedModelName.value,
        'choices': [
          {'index': 0, 'text': token, 'finish_reason': null}
        ],
      });
    }

    final stopsBefore = inference.stopCount;
    final result = await inference.generate(
      prompt: prompt,
      systemPrompt: _defaultSystemPrompt(inference.loadedModelName.value),
      source: 'server',
      maxTokens: maxTokens,
      stopSequences: stop,
      onToken: emit,
    );
    await _finishStream(
        sse, inference, stopsBefore, emitted ? null : result, emit);
  }

  Map<String, dynamic> _chatResponse(String model, String text,
      {Map<String, dynamic>? toolCall}) {
    return {
      'id': 'chatcmpl-${_id()}',
      'object': 'chat.completion',
      'created': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'model': model,
      'choices': [
        {
          'index': 0,
          'message': {
            'role': 'assistant',
            'content': toolCall == null ? text : null,
            if (toolCall != null) 'tool_calls': [toolCall],
          },
          'finish_reason': toolCall == null ? 'stop' : 'tool_calls',
        }
      ],
    };
  }

  Future<Map<String, dynamic>> _readJson(HttpRequest request) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in request) {
      builder.add(chunk);
      if (builder.length > maxBodyBytes) {
        throw const HttpException('Request body is too large');
      }
    }
    final body = utf8.decode(builder.takeBytes());
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('JSON body must be an object');
    }
    return decoded;
  }

  Future<void> _json(
    HttpRequest request,
    Map<String, dynamic> data, {
    int status = HttpStatus.ok,
  }) async {
    _addCorsHeaders(request.response);
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(data));
    await request.response.close();
  }

  void _addCorsHeaders(HttpResponse response) {
    // Only allow browser access when a key is required, so an arbitrary web
    // page can't read model output from an open server.
    if (_apiKey == null || _agentModel != null) return;
    response.headers.set(HttpHeaders.accessControlAllowOriginHeader, '*');
    response.headers
        .set(HttpHeaders.accessControlAllowMethodsHeader, 'GET,POST,OPTIONS');
    response.headers.set(
      HttpHeaders.accessControlAllowHeadersHeader,
      'Content-Type, Authorization',
    );
  }

  Future<String?> _reachableIpv4Address() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (!address.isLoopback) return address.address;
        }
      }
    } catch (_) {}
    return null;
  }

  String _id() {
    final rng = Random.secure();
    return List.generate(12, (_) => rng.nextInt(16).toRadixString(16)).join();
  }

  String _defaultSystemPrompt(String modelName) {
    if (Get.isRegistered<SettingsController>()) {
      return Get.find<SettingsController>().effectiveSystemPromptForModel(
        modelName,
      );
    }
    if (AppConstants.isUncensoredModelName(modelName)) {
      return AppConstants.uncensoredSystemPrompt;
    }
    return AppConstants.systemPrompt;
  }
}

/// Streams server-sent events over the raw socket.
///
/// dart:io's HttpServer never reports a client that hangs up mid-response
/// (flush() keeps succeeding and `done` never errors), so the response is
/// detached and the socket itself is watched: it closes the moment the client
/// goes away. Writes are fire-and-forget, so nothing here can block the
/// request handler (and leave the server stuck busy).
class _SseStream {
  _SseStream._(this._socket, this._onDisconnect) {
    _socket.listen(
      (_) {},
      onDone: _disconnect,
      onError: (_) => _disconnect(),
      cancelOnError: true,
    );
  }

  static Future<_SseStream> open(
    HttpResponse response, {
    required void Function() onDisconnect,
  }) async {
    response.statusCode = HttpStatus.ok;
    response.headers.contentType =
        ContentType('text', 'event-stream', charset: 'utf-8');
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
    // The body ends when the connection closes; no chunked framing needed.
    response.headers.chunkedTransferEncoding = false;
    response.headers.set(HttpHeaders.connectionHeader, 'close');
    final socket = await response.detachSocket(writeHeaders: true);
    return _SseStream._(socket, onDisconnect);
  }

  final Socket _socket;
  final void Function() _onDisconnect;
  bool _disconnected = false;
  bool _closed = false;

  void event(Object payload) => raw('data: ${jsonEncode(payload)}\n\n');

  void raw(String chunk) {
    if (_disconnected || _closed) return;
    try {
      _socket.write(chunk);
    } catch (_) {
      _disconnect();
    }
  }

  void _disconnect() {
    if (_disconnected) return;
    _disconnected = true;
    if (!_closed) _onDisconnect();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _socket.close().timeout(const Duration(seconds: 2));
    } catch (_) {
      _socket.destroy();
    }
  }
}

class _ParsedChatRequest {
  final String prompt;
  final String? systemPrompt;
  final List<Map<String, String>> history;
  final String? imagePath;
  final String? audioPath;
  final String? error;

  _ParsedChatRequest({
    required this.prompt,
    required this.systemPrompt,
    required this.history,
    required this.imagePath,
    required this.audioPath,
  }) : error = null;

  _ParsedChatRequest.error(this.error)
      : prompt = '',
        systemPrompt = null,
        history = const [],
        imagePath = null,
        audioPath = null;
}

class _ContentResult {
  final String text;
  final String? imagePath;
  final String? audioPath;
  final String? error;

  _ContentResult({
    required this.text,
    this.imagePath,
    this.audioPath,
  }) : error = null;

  _ContentResult.error(this.error)
      : text = '',
        imagePath = null,
        audioPath = null;
}

class _TempFileResult {
  final File? file;
  final String? error;

  _TempFileResult(this.file) : error = null;
  _TempFileResult.error(this.error) : file = null;

  String get path => file!.path;
}

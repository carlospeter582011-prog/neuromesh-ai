import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;

import '../core/build_flavor.dart';
import 'agent_service.dart';
import 'openai_server_service_io.dart';
import 'opencode_tools.dart';
import 'sandbox_service.dart';

bool get showAndroidAgentHub =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android && !kPlayBuild;

typedef OpenCodeMessage = ({String role, String text});

class AndroidOpenCode {
  AndroidOpenCode(this.sandbox);

  static const version = '1.19.6';
  static const _guest = '/opt/neuromesh-opencode';
  static const _cli = '$_guest/opencode';
  static const _model = 'neuromesh/${OpenAiServerService.agentModelId}';
  static const _asset =
      'https://github.com/anomalyco/opencode/releases/download/'
      'v$version/opencode-linux-arm64-musl.tar.gz';
  static const _sha256 =
      '45407388777dfc1894591c9727c169f202ad92c75757038950630a0fbb12ca97';
  static const downloadBytes = 78461019;
  // OpenCode 1.19.6 can exit before a large export drains a pipe.
  static const exportToFile = r'exec "$1" export "$2" --pure > "$3"';

  final SandboxService sandbox;
  OpenAiServerService? _bridge;
  http.Client? _download;
  Map<String, String> _environment = {};
  Process? _active;
  bool _working = false;
  bool _installCancelled = false;
  bool _installingAlpine = false;
  String? sessionId;

  bool get compatible =>
      showAndroidAgentHub && Abi.current() == Abi.androidArm64;

  Future<String> discover() async {
    if (!compatible || !await sandbox.runtimeAvailable()) {
      return 'Requires a standalone ARM64 Android APK with the Alpine launcher.';
    }
    if (!sandbox.installed.value) return 'Alpine Linux is required.';
    final directory = await sandbox.openCodeDirectory();
    if (!await File('${directory.path}/opencode').exists()) {
      return 'OpenCode is available to install.';
    }
    final versionResult = await _capture([_cli, '--version']);
    if (versionResult != version) {
      return 'OpenCode version check failed. Reinstall to repair it.';
    }
    if (!await _hasTerminal())
      return 'OpenCode $version is installed. Repair the terminal dependency.';
    return 'OpenCode $version is installed.';
  }

  Future<bool> installed() async {
    if (!compatible || !sandbox.installed.value) return false;
    return File('${(await sandbox.openCodeDirectory()).path}/opencode')
        .exists();
  }

  Future<void> install(void Function(String, double?) progress) async {
    if (!compatible || !await sandbox.runtimeAvailable()) {
      throw UnsupportedError(
          'OpenCode requires the standalone ARM64 Android APK.');
    }
    if (_working || _active != null || _bridge != null) {
      throw StateError('Disconnect the current OpenCode session first.');
    }
    _working = true;
    _installCancelled = false;
    final client = _download = http.Client();
    Directory? staging;
    try {
      if (!sandbox.installed.value) {
        progress('Installing Alpine Linux…', null);
        _installingAlpine = true;
        final worker = ever(sandbox.status,
            (text) => progress(text, sandbox.downloadProgress.value));
        try {
          await sandbox.install();
        } finally {
          worker.dispose();
          _installingAlpine = false;
        }
      }
      _checkInstallationCancellation();
      if (!await _hasTerminal()) {
        progress('Installing Alpine terminal tools…', null);
        await _capture(['/sbin/apk', 'add', '--no-cache', 'util-linux-misc'],
            limit: const Duration(minutes: 4));
      }
      if (!await _hasTerminal())
        throw StateError('Alpine terminal tools could not be installed.');
      final directory = await sandbox.openCodeDirectory();
      await directory.create(recursive: true);
      staging = await directory.createTemp('download-');
      final archive = File('${staging.path}/opencode.tar.gz');
      final response = await client
          .send(http.Request('GET', Uri.parse(_asset)))
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200)
        throw HttpException('OpenCode download failed.');
      final sink = archive.openWrite();
      var received = 0;
      try {
        await for (final part
            in response.stream.timeout(const Duration(seconds: 30))) {
          received += part.length;
          if (received > downloadBytes)
            throw const FormatException('Unexpected download size.');
          sink.add(part);
          progress('Downloading OpenCode $version…', received / downloadBytes);
        }
      } finally {
        await sink.close();
      }
      if (received != downloadBytes ||
          (await sha256.bind(archive.openRead()).first).toString() != _sha256) {
        throw const FormatException('OpenCode download failed verification.');
      }
      progress('Verifying OpenCode…', null);
      final unpack = await Process.run('/system/bin/toybox', [
        'tar',
        '-xzf',
        archive.path,
        '-C',
        staging.path,
        'opencode',
      ]);
      if (unpack.exitCode != 0)
        throw StateError('OpenCode could not be unpacked.');
      final executable = File('${staging.path}/opencode');
      final guestStaged = '$_guest/${staging.path.split('/').last}/opencode';
      _checkInstallationCancellation();
      if (await _capture([guestStaged, '--version']) != version) {
        throw StateError('OpenCode could not run in this Alpine installation.');
      }
      _checkInstallationCancellation();
      await executable.rename('${directory.path}/opencode');
    } catch (_) {
      _checkInstallationCancellation();
      rethrow;
    } finally {
      client.close();
      if (identical(_download, client)) _download = null;
      _working = false;
      if (staging != null && await staging.exists()) {
        await staging.delete(recursive: true);
      }
    }
  }

  void _checkInstallationCancellation() {
    if (_installCancelled) throw StateError('OpenCode installation cancelled.');
  }

  Future<bool> _hasTerminal() async {
    try {
      await _capture(['/usr/bin/script', '--version']);
      return true;
    } on StateError {
      return false;
    }
  }

  Future<void> remove() async {
    if (_working || _active != null || _bridge != null) {
      throw StateError('Disconnect the OpenCode session first.');
    }
    final directory = await sandbox.openCodeDirectory();
    if (await directory.exists()) await directory.delete(recursive: true);
    sessionId = null;
  }

  Future<void> connect(String name, int context,
      {required bool allowWorkspaceReads}) async {
    if (_bridge != null) return;
    if (!compatible || !await installed() || context < 2048) {
      throw StateError(
          'Install OpenCode and load a local model with 2048 context tokens or more.');
    }
    final directory = await sandbox.openCodeDirectory();
    await Directory('${directory.path}/home').create(recursive: true);
    final bridge = OpenAiServerService.forAgentModel(name,
        allowTools: allowWorkspaceReads,
        workspace: await Get.find<AgentService>().filesDir());
    final random = Random.secure();
    final token =
        base64UrlEncode(List.generate(32, (_) => random.nextInt(256)));
    await bridge.start(port: 0, apiKey: token);
    _environment = {
      'HOME': '$_guest/home',
      'XDG_CONFIG_HOME': '$_guest/home/.config',
      'XDG_DATA_HOME': '$_guest/home/.local/share',
      'XDG_STATE_HOME': '$_guest/home/.local/state',
      'XDG_CACHE_HOME': '$_guest/home/.cache',
      'TMPDIR': '/tmp',
      'PATH': '/usr/local/bin:/usr/bin:/bin',
      'OPENCODE_DISABLE_PROJECT_CONFIG': 'true',
      'OPENCODE_DISABLE_DEFAULT_PLUGINS': 'true',
      'OPENCODE_DISABLE_EXTERNAL_SKILLS': 'true',
      'OPENCODE_DISABLE_LSP_DOWNLOAD': 'true',
      'OPENCODE_DISABLE_MODELS_FETCH': 'true',
      'OPENCODE_DISABLE_AUTOUPDATE': 'true',
      'NEUROMESH_BRIDGE_KEY': token,
      'OPENCODE_CONFIG_CONTENT': localProviderConfig(
        name: name,
        context: context,
        endpoint: '${bridge.localUrl}/v1',
        allowTools: allowWorkspaceReads,
      ),
    };
    _bridge = bridge;
    try {
      final models = await _capture([_cli, 'models', 'neuromesh', '--pure']);
      if (models != _model) {
        throw StateError('OpenCode could not validate the local provider.');
      }
      final saved = File('${directory.path}/session-id');
      final id =
          await saved.exists() ? (await saved.readAsString()).trim() : '';
      sessionId = _validSession(id) ? id : null;
    } catch (_) {
      await disconnect();
      rethrow;
    }
  }

  static String localProviderConfig({
    required String name,
    required int context,
    required String endpoint,
    bool allowTools = true,
  }) =>
      jsonEncode({
        'enabled_providers': ['neuromesh'],
        'model': _model,
        'small_model': _model,
        'default_agent': 'neuromesh',
        'agent': {
          'neuromesh': {
            'mode': 'primary',
            'prompt': allowTools
                ? 'Help the user understand their project. Read workspace files before describing their contents.'
                : 'Help the user understand their project. Answer from the chat context.',
          },
          'title': {'disable': true},
        },
        'share': 'disabled',
        'autoupdate': false,
        'lsp': false,
        'permission': {
          '*': 'deny',
          if (allowTools)
            for (final tool in openCodeReadTools) tool: 'allow',
        },
        'provider': {
          'neuromesh': {
            'name': 'NeuroMesh local',
            'npm': '@ai-sdk/openai-compatible',
            'env': ['NEUROMESH_BRIDGE_KEY'],
            'options': {'baseURL': endpoint},
            'models': {
              OpenAiServerService.agentModelId: {
                'name': name,
                'tool_call': allowTools,
                'attachment': false,
                'limit': {
                  'context': context,
                  'output': min(1024, context ~/ 4)
                },
              },
            },
          },
        },
      });

  static bool _validSession(String id) =>
      RegExp(r'^ses_[a-zA-Z0-9_-]{1,100}$').hasMatch(id);

  Future<Process> _start(List<String> command) async {
    if (_active != null)
      throw StateError('An OpenCode process is already running.');
    final process =
        await sandbox.startOpenCodeProcess(command, environment: _environment);
    _active = process;
    unawaited(process.exitCode.then((_) {
      if (identical(_active, process)) _active = null;
    }));
    return process;
  }

  Future<String> _capture(List<String> args,
      {Duration limit = const Duration(seconds: 30)}) async {
    final process = await _start(args);
    unawaited(process.stdin.close());
    final output = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    final errors = process.stderr.drain<void>();
    try {
      final code = await process.exitCode.timeout(limit);
      final text = await output;
      await errors;
      if (code != 0)
        throw StateError('Linux command exited with status $code.');
      return text.trim();
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      rethrow;
    }
  }

  Future<Map<String, String>> sessions() async {
    final output = await _capture([
      _cli,
      'session',
      'list',
      '--pure',
      '--format',
      'json',
      '--max-count',
      '30'
    ]);
    final data = jsonDecode(output);
    if (data is! List) return {};
    return {
      for (final item in data.whereType<Map>())
        if (item['id'] is String && _validSession(item['id'] as String))
          item['id'] as String: item['title'] is String
              ? item['title'] as String
              : 'OpenCode session',
    };
  }

  Future<void> selectSession(String id) async {
    if (!_validSession(id) || _active != null) {
      throw StateError('This OpenCode session is unavailable.');
    }
    sessionId = id;
    final directory = await sandbox.openCodeDirectory();
    await File('${directory.path}/session-id').writeAsString(id, flush: true);
  }

  Future<List<OpenCodeMessage>> history() async {
    final id = sessionId;
    if (id == null) return [];
    final directory = await sandbox.openCodeDirectory();
    final temporary = await directory.createTemp('history-');
    try {
      final file = File('${temporary.path}/session.json');
      await _capture([
        '/bin/sh',
        '-c',
        exportToFile,
        'neuromesh-export',
        _cli,
        id,
        '$_guest/${temporary.path.split('/').last}/session.json',
      ]);
      if (await file.length() > 32 * 1024 * 1024) {
        throw StateError(
            'This OpenCode session is too large to display in Chat.');
      }
      return parseHistory(await file.readAsString());
    } finally {
      await temporary.delete(recursive: true);
    }
  }

  static List<OpenCodeMessage> parseHistory(String output) {
    final data = jsonDecode(output);
    if (data is! Map || data['messages'] is! List) return [];
    final messages = <OpenCodeMessage>[];
    for (final message in (data['messages'] as List).whereType<Map>()) {
      final info = message['info'];
      final parts = message['parts'];
      final role = info is Map ? info['role'] : null;
      if ((role != 'user' && role != 'assistant') || parts is! List) continue;
      final text = parts
          .whereType<Map>()
          .where((part) => part['type'] == 'text')
          .map((part) => part['text'])
          .whereType<String>()
          .join('\n');
      if (text.isNotEmpty) messages.add((role: role as String, text: text));
    }
    return messages;
  }

  Future<void> send(String prompt, void Function(String) onText,
      void Function(String) onTool) async {
    final bridge = _bridge;
    if (bridge == null) throw StateError('Connect a local model first.');
    var streamed = false;
    bridge.onAgentText = (text) {
      streamed = true;
      onText(text);
    };
    try {
      await _send(prompt, (text) {
        if (!streamed) onText(text);
        streamed = false;
      }, onTool);
    } finally {
      bridge.onAgentText = null;
    }
  }

  Future<void> _send(String prompt, void Function(String) onText,
      void Function(String) onTool) async {
    final process = await _start([
      _cli,
      'run',
      '--pure',
      '--format',
      'json',
      '--model',
      _model,
      if (sessionId != null) ...['--session', sessionId!],
    ]);
    process.stdin.write(prompt);
    unawaited(process.stdin.close());
    final stderr = process.stderr.drain<void>();
    String? eventError;
    await for (final line in process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())) {
      final event = parseEvent(line);
      if (event == null) continue;
      final id = event['sessionID'];
      if (id is String && _validSession(id) && id != sessionId) {
        sessionId = id;
        final directory = await sandbox.openCodeDirectory();
        await File('${directory.path}/session-id')
            .writeAsString(id, flush: true);
      }
      final part = event['part'];
      if (event['type'] == 'text' && part is Map && part['text'] is String) {
        onText(part['text'] as String);
      } else if (event['type'] == 'tool_use' &&
          part is Map &&
          part['tool'] is String) {
        final state = part['state'];
        onTool(
            '${part['tool']} · ${state is Map ? state['status'] ?? 'finished' : 'finished'}');
      } else if (event['type'] == 'error') {
        eventError =
            'OpenCode reported an error. Check that the linked model is still loaded.';
      }
    }
    final code = await process.exitCode;
    await stderr;
    if (eventError != null) throw StateError(eventError);
    if (code != 0) throw StateError('OpenCode stopped with status $code.');
  }

  static Map? parseEvent(String line) {
    try {
      final value = jsonDecode(line);
      return value is Map && value['type'] is String ? value : null;
    } on FormatException {
      return null;
    }
  }

  Future<Process> terminal({required int width, required int height}) {
    if (_bridge == null) throw StateError('Connect a local model first.');
    final resume = sessionId == null ? '' : ' --session ${sessionId!}';
    return _start([
      '/usr/bin/script',
      '-qefc',
      '/bin/busybox stty rows ${height.clamp(12, 160)} cols ${width.clamp(24, 240)}; '
          'exec $_cli /workspace --pure --model $_model$resume',
      '/dev/null',
    ]);
  }

  Future<void> newChat() async {
    if (_active != null) throw StateError('Wait for the current turn.');
    sessionId = null;
    final file = File('${(await sandbox.openCodeDirectory()).path}/session-id');
    if (await file.exists()) await file.delete();
  }

  void cancel() {
    if (_working) _installCancelled = true;
    if (_installingAlpine) sandbox.cancelInstallation();
    _download?.close();
    _active?.kill(ProcessSignal.sigkill);
  }

  Future<void> stopProcess() async {
    final running = _active;
    if (running == null) return;
    running.kill(ProcessSignal.sigkill);
    await running.exitCode.timeout(const Duration(seconds: 5));
  }

  Future<void> disconnect() async {
    cancel();
    final bridge = _bridge;
    _bridge = null;
    _environment = {};
    try {
      await stopProcess();
    } finally {
      await bridge?.stop();
    }
  }
}

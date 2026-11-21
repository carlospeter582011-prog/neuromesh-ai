import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:neuromesh_ai/core/constants.dart';
import 'package:neuromesh_ai/services/android_opencode.dart';
import 'package:neuromesh_ai/services/app_log_service.dart';
import 'package:neuromesh_ai/services/hive_service.dart';
import 'package:neuromesh_ai/services/inference_service.dart';
import 'package:neuromesh_ai/services/openai_server_service_io.dart';

void main() {
  final modelPath = Platform.environment['NEUROMESH_TEST_OPENCODE_MODEL'];
  final cliPath = Platform.environment['NEUROMESH_TEST_OPENCODE_CLI'];
  test('OpenCode Android profile calls a real local GGUF on Linux', () async {
    final root = await Directory.systemTemp.createTemp('opencode-gguf-');
    final workspace = await root.createTemp('workspace-');
    final fixture = File('${workspace.path}/fixture.txt');
    await fixture.writeAsString('pineapple-47');
    Hive.init(root.path);
    final hive = Get.put(await HiveService().init());
    Get.put(AppLogService());
    final inference = Get.put(InferenceService());
    await hive.setSetting(AppConstants.keyContextSize, 8192);
    final loaded = await inference.loadModel(modelPath!, modelName: 'Artemis');
    expect(inference.isModelLoaded.value, isTrue, reason: loaded);
    final bridge =
        OpenAiServerService.forAgentModel('Artemis', allowTools: true);
    addTearDown(() async {
      await bridge.stop();
      await inference.unloadModel();
      await Hive.close();
      Get.reset();
      await root.delete(recursive: true);
    });
    final buffer = StringBuffer();
    bridge.onAgentText = buffer.write;
    await bridge.start(port: 0, apiKey: 'local-gguf-test');
    final environment = {
      'HOME': '${root.path}/opencode-home',
      'PATH': '/usr/local/bin:/usr/bin:/bin',
      'OPENCODE_DISABLE_PROJECT_CONFIG': 'true',
      'OPENCODE_DISABLE_DEFAULT_PLUGINS': 'true',
      'OPENCODE_DISABLE_EXTERNAL_SKILLS': 'true',
      'OPENCODE_DISABLE_LSP_DOWNLOAD': 'true',
      'OPENCODE_DISABLE_MODELS_FETCH': 'true',
      'OPENCODE_DISABLE_AUTOUPDATE': 'true',
      'NEUROMESH_BRIDGE_KEY': 'local-gguf-test',
      'OPENCODE_CONFIG_CONTENT': AndroidOpenCode.localProviderConfig(
          name: 'Artemis', context: 8192, endpoint: '${bridge.localUrl}/v1'),
    };
    Future<List<Map>> run(String text) async {
      final child = await Process.start(cliPath!,
          ['run', '--pure', '--format', 'json', '--model', 'neuromesh/loaded'],
          workingDirectory: workspace.path,
          includeParentEnvironment: false,
          environment: environment);
      final stdout = child.stdout.transform(utf8.decoder).join();
      final stderr = child.stderr.transform(utf8.decoder).join();
      child.stdin.write(text);
      await child.stdin.close();
      final output = await stdout;
      expect(await child.exitCode.timeout(const Duration(seconds: 55)), 0,
          reason: "${await stderr}\n$output");
      return output
          .split('\n')
          .map(AndroidOpenCode.parseEvent)
          .whereType<Map>()
          .toList();
    }

    final chat = await run('Reply with exactly the word seven.');
    expect(chat.any((x) => x['type'] == 'text'), isTrue, reason: '$chat');
    expect(buffer.toString().toLowerCase(), contains('seven'));
    final tool = await run(
        'Use the read tool to read ${fixture.path} and tell me exactly what it contains.');
    expect(tool.any((x) => x['type'] == 'tool_use'), isTrue, reason: '$tool');
    expect(buffer.toString(), contains('pineapple-47'));
  },
      skip: !Platform.isLinux || modelPath == null || cliPath == null
          ? 'Requires Linux, OpenCode v1.19.6 and a local GGUF.'
          : false,
      timeout: const Timeout(Duration(minutes: 2)));
}

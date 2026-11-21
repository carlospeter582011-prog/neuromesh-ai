import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:neuromesh_ai/services/android_opencode.dart';
import 'package:neuromesh_ai/services/inference_service.dart';
import 'package:neuromesh_ai/services/openai_server_service_io.dart';
import 'package:neuromesh_ai/services/opencode_tools.dart';

void main() {
  late OpenAiServerService server;
  late HttpClient client;
  const port = 18765;

  setUp(() {
    server = OpenAiServerService();
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await server.stop();
  });

  Future<HttpClientResponse> send(
    String method,
    String path, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    final req =
        await client.openUrl(method, Uri.parse('http://127.0.0.1:$port$path'));
    req.persistentConnection = false;
    headers.forEach(req.headers.set);
    if (body != null) req.write(body);
    final res = await req.close();
    await res.drain<void>();
    return res;
  }

  test('binds to loopback only by default', () async {
    await server.start(port: port);
    expect(server.localUrl, 'http://127.0.0.1:$port');
  });

  test('network mode refuses to start without an API key', () async {
    expect(
      () => server.start(port: port, allowNetwork: true),
      throwsArgumentError,
    );
    expect(server.isRunning, isFalse);
  });

  test('enforces the API key and applies key changes live', () async {
    await server.start(port: port, apiKey: 'first');

    expect((await send('GET', '/v1/models')).statusCode, 401);
    expect(
      (await send('GET', '/health')).statusCode,
      200,
      reason: 'health check stays public',
    );

    server.updateApiKey('second');
    expect(
      (await send('GET', '/v1/server/capabilities',
              headers: {'Authorization': 'Bearer first'}))
          .statusCode,
      401,
    );
  });

  test('rejects POST bodies that are not JSON', () async {
    await server.start(port: port);
    final res = await send('POST', '/v1/chat/completions',
        headers: {'Content-Type': 'text/plain'},
        body: jsonEncode({'messages': []}));
    expect(res.statusCode, HttpStatus.unsupportedMediaType);
  });

  test('only sends CORS headers when a key is required', () async {
    await server.start(port: port);
    var res = await send('GET', '/health');
    expect(res.headers.value('access-control-allow-origin'), isNull);
    await server.stop();

    await server.start(port: port, apiKey: 'k');
    res = await send('GET', '/health');
    expect(res.headers.value('access-control-allow-origin'), '*');
  });

  group('generation', () {
    late FakeInference fake;
    const json = {'Content-Type': 'application/json'};
    String chatBody({bool stream = false, int? maxTokens}) => jsonEncode({
          'messages': [
            {'role': 'user', 'content': 'hi'}
          ],
          if (stream) 'stream': true,
          if (maxTokens != null) 'max_tokens': maxTokens,
        });

    setUp(() async {
      fake = FakeInference();
      Get.put<InferenceService>(fake);
      await server.start(port: port);
    });

    tearDown(Get.reset);

    test('passes max_tokens through to the model', () async {
      final res = await send('POST', '/v1/chat/completions',
          headers: json, body: chatBody(maxTokens: 7));
      expect(res.statusCode, 200);
      expect(fake.lastMaxTokens, 7);
    });

    test('passes OpenAI stop (string or list) through to the model', () async {
      var res = await send('POST', '/v1/chat/completions',
          headers: json,
          body: jsonEncode({
            'messages': [
              {'role': 'user', 'content': 'hi'}
            ],
            'stop': '###',
          }));
      expect(res.statusCode, 200);
      expect(fake.lastStop, ['###']);
      res = await send('POST', '/v1/completions',
          headers: json,
          body: jsonEncode({
            'prompt': 'hi',
            'stop': ['a', 'b', 7, 'c', 'd', 'e'],
          }));
      expect(res.statusCode, 200);
      expect(fake.lastStop, ['a', 'b', 'c', 'd'],
          reason: 'non-strings dropped, at most 4 like OpenAI');
    });

    test('rejects with 429 while the app is generating', () async {
      fake.isGenerating.value = true;
      final res = await send('POST', '/v1/chat/completions',
          headers: json, body: chatBody());
      expect(res.statusCode, 429);
    });

    test('reports 503 when the generation is interrupted', () async {
      fake.tokensToEmit = 50;
      final pending =
          send('POST', '/v1/chat/completions', headers: json, body: chatBody());
      await Future.delayed(const Duration(milliseconds: 100));
      await fake.stopGeneration(); // e.g. the user started a chat reply
      expect((await pending).statusCode, HttpStatus.serviceUnavailable);
    });

    test('streams live and stops the model when the client disconnects',
        () async {
      fake.tokensToEmit = 1000;
      final req = await client.openUrl(
          'POST', Uri.parse('http://127.0.0.1:$port/v1/chat/completions'));
      req.headers.contentType = ContentType.json;
      req.write(chatBody(stream: true));
      final res = await req.close();
      final firstChunk = Completer<void>();
      final sub = res.listen((_) {
        if (!firstChunk.isCompleted) firstChunk.complete();
      });
      await firstChunk.future.timeout(const Duration(seconds: 2));
      await sub.cancel();
      client.close(force: true);
      client = HttpClient();

      // The server must notice, stop the model, and free itself up.
      for (var i = 0; i < 40 && fake.stops == 0; i++) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      expect(fake.stops, 1);
      await Future.delayed(const Duration(milliseconds: 100));
      fake.tokensToEmit = 1;
      final next = await send('POST', '/v1/chat/completions',
          headers: json, body: chatBody());
      expect(next.statusCode, 200, reason: 'server must not stay busy');
    });
  });

  group('agent bridge', () {
    late FakeInference fake;
    const auth = {'Authorization': 'Bearer agent-test'};
    const json = {...auth, 'Content-Type': 'application/json'};
    const completion = '/v1/chat/completions';
    const body = {
      'model': OpenAiServerService.agentModelId,
      'messages': [
        {'role': 'user', 'content': 'hello'}
      ],
    };

    setUp(() async {
      fake = Get.put<InferenceService>(FakeInference()) as FakeInference;
      server = OpenAiServerService.forAgentModel(fake.loadedModelName.value);
      await server.start(port: port, apiKey: 'agent-test');
    });

    tearDown(Get.reset);

    test('requires a key, stays on loopback and exposes only model calls',
        () async {
      final restricted = OpenAiServerService.forAgentModel('fake-model');
      await expectLater(restricted.start(port: 0), throwsArgumentError);
      await expectLater(
          restricted.start(port: 0, allowNetwork: true, apiKey: 'another'),
          throwsArgumentError);
      expect(server.localUrl, 'http://127.0.0.1:$port');
      expect((await send('GET', '/v1/models')).statusCode, 401);
      expect((await send('GET', '/v1/files', headers: auth)).statusCode, 404);
      expect(
          (await send('OPTIONS', completion, headers: auth)).statusCode, 404);
      final request =
          await client.getUrl(Uri.parse('${server.localUrl}/v1/models'));
      auth.forEach(request.headers.set);
      final response = await request.close();
      expect(response.headers.value('access-control-allow-origin'), isNull);
      final models = jsonDecode(await response.transform(utf8.decoder).join());
      expect(models['data'].single, containsPair('tool_calling', false));
      expect(models['data'].single,
          containsPair('id', OpenAiServerService.agentModelId));
    });

    test('rejects tools, wrong model IDs and a reloaded model of the same name',
        () async {
      for (final payload in [
        {
          ...body,
          'tools': [
            {'type': 'function'}
          ]
        },
        {...body, 'model': 'another-model'},
      ]) {
        expect(
            (await send('POST', completion,
                    headers: json, body: jsonEncode(payload)))
                .statusCode,
            400);
      }
      fake.modelRevision++;
      expect(
          (await send('POST', completion,
                  headers: json, body: jsonEncode(body)))
              .statusCode,
          409);
      expect(fake.isGenerating.value, isFalse);
    });

    test('streams an OpenAI finish chunk before DONE', () async {
      final request =
          await client.postUrl(Uri.parse('${server.localUrl}$completion'));
      json.forEach(request.headers.set);
      request.write(jsonEncode({...body, 'stream': true}));
      final response = await request.close();
      expect(response.statusCode, 200);
      final data = await response.transform(utf8.decoder).join();
      expect(data, contains('"delta":{"role":"assistant"}'));
      expect(data, contains('"delta":{"content":"t0 "}'));
      expect(data, endsWith('"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n'));
    });

    test('disconnect stops an active bridge generation and revokes access',
        () async {
      fake.tokensToEmit = 500;
      final uri = Uri.parse('${server.localUrl}$completion');
      final request = await client.postUrl(uri);
      json.forEach(request.headers.set);
      request.write(jsonEncode({...body, 'stream': true}));
      final response = await request.close();
      final drain = response.drain<void>();
      expect(fake.isGenerating.value, isTrue);
      await server.stop();
      await drain;
      expect(fake.stops, 1);
      await expectLater(client.postUrl(uri), throwsA(isA<SocketException>()));
    });
  });

  test('only emits workspace tools offered by the agent with valid keys', () {
    final tools = OpenCodeTools([
      {
        'type': 'function',
        'function': {
          'name': 'read',
          'parameters': {
            'properties': {
              'filePath': {'type': 'string'}
            },
            'required': ['filePath'],
          },
        },
      },
    ]);
    expect(
        tools.parse(
            '<tool_call>{"name":"read","arguments":{"filePath":"README"}}</tool_call>',
            '1'),
        containsPair('id', 'call_1'));
    for (final body in [
      '{"name":"write","arguments":{"filePath":"README"}}',
      '{"name":"read","arguments":{}}',
      '{"name":"read","arguments":{"filePath":"README","command":"ls"}}',
    ]) {
      expect(tools.parse('<tool_call>$body</tool_call>', '1'), isNull);
    }
  });

  final openCodePath = Platform.environment['NEUROMESH_TEST_OPENCODE_CLI'];
  test('real OpenCode runs a local workspace tool and resumes the session',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('neuromesh-opencode');
    addTearDown(() => directory.delete(recursive: true));
    final fixture = await File('${directory.path}/fixture.txt')
        .writeAsString('NEUROMESH_LOCAL_TOOL_TEST');
    await Process.run('git', ['init', directory.path]);
    final fake = Get.put<InferenceService>(FakeInference()) as FakeInference;
    addTearDown(Get.reset);
    var read = false;
    fake.reply = (prompt, history) {
      if (prompt.contains('NEUROMESH_LOCAL_TOOL_TEST') ||
          history.toString().contains('NEUROMESH_LOCAL_TOOL_TEST')) {
        read = true;
      }
      return read
          ? 'Local file verified.'
          : '<tool_call>${jsonEncode({
                  'name': 'read',
                  'arguments': {'filePath': fixture.path},
                })}</tool_call>';
    };
    server = OpenAiServerService.forAgentModel('fake-model', allowTools: true);
    final liveText = StringBuffer();
    server.onAgentText = liveText.write;
    await server.start(port: 0, apiKey: 'local-test');
    Future<ProcessResult> run(List<String> args,
        {String? executable, String? prompt}) async {
      final process = await Process.start(
        executable ?? openCodePath!,
        args,
        workingDirectory: directory.path,
        includeParentEnvironment: false,
        environment: {
          'PATH': '/usr/bin:/bin',
          'HOME': '${directory.path}/home',
          'OPENCODE_DISABLE_PROJECT_CONFIG': 'true',
          'OPENCODE_DISABLE_DEFAULT_PLUGINS': 'true',
          'OPENCODE_DISABLE_EXTERNAL_SKILLS': 'true',
          'OPENCODE_DISABLE_LSP_DOWNLOAD': 'true',
          'OPENCODE_DISABLE_MODELS_FETCH': 'true',
          'OPENCODE_DISABLE_AUTOUPDATE': 'true',
          'NEUROMESH_BRIDGE_KEY': 'local-test',
          'OPENCODE_CONFIG_CONTENT': AndroidOpenCode.localProviderConfig(
            name: 'fake-model',
            context: 8192,
            endpoint: '${server.localUrl}/v1',
          ),
        },
      );
      final stdout = process.stdout.transform(utf8.decoder).join();
      final stderr = process.stderr.transform(utf8.decoder).join();
      if (prompt != null) process.stdin.write(prompt);
      await process.stdin.close();
      return ProcessResult(
          process.pid, await process.exitCode, await stdout, await stderr);
    }

    final listed = await run(['models', 'neuromesh', '--pure']);
    expect(listed.exitCode, 0, reason: '${listed.stderr}');
    expect(listed.stdout.trim(), 'neuromesh/loaded');
    const args = [
      'run',
      '--pure',
      '--format',
      'json',
      '--model',
      'neuromesh/loaded'
    ];
    final result = await run(args, prompt: 'Read the test fixture.');
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(read, isTrue, reason: '${result.stdout}');
    final events = (result.stdout as String)
        .split('\n')
        .map(AndroidOpenCode.parseEvent)
        .whereType<Map>()
        .toList();
    expect(events.any((event) => event['type'] == 'tool_use'), isTrue);
    final session = events.first['sessionID'] as String;
    final resumed =
        await run([...args, '--session', session], prompt: 'Continue.');
    expect(resumed.exitCode, 0, reason: '${resumed.stdout}\n${resumed.stderr}');
    final sessionFile = File('${directory.path}/session.json');
    final exported = await run([
      '-c',
      AndroidOpenCode.exportToFile,
      'neuromesh-export',
      openCodePath!,
      session,
      sessionFile.path,
    ], executable: '/bin/sh');
    expect(exported.exitCode, 0, reason: '${exported.stderr}');
    expect(
        AndroidOpenCode.parseHistory(await sessionFile.readAsString()),
        containsAllInOrder([
          (role: 'user', text: 'Read the test fixture.'),
          (role: 'assistant', text: 'Local file verified.'),
          (role: 'user', text: 'Continue.'),
        ]));
    expect(liveText.toString(), contains('Local file verified.'));
    expect(liveText.toString(), isNot(contains('<tool_call>')));
  },
      skip: openCodePath == null
          ? 'Set NEUROMESH_TEST_OPENCODE_CLI to OpenCode v1.19.6'
          : false,
      timeout: const Timeout(Duration(minutes: 2)));
}

/// Minimal stand-in for InferenceService: tokens are emitted on a timer until
/// stopped, so tests can observe busy/stop/interrupt behaviour.
class FakeInference extends GetxService implements InferenceService {
  @override
  final isModelLoaded = true.obs;
  @override
  final isGenerating = false.obs;
  @override
  final loadedModelName = 'fake-model'.obs;
  @override
  int modelRevision = 1;
  @override
  final generationSource = ''.obs;
  @override
  final isVisionLoaded = false.obs;
  @override
  final loadedModelRuntime = 'litert'.obs;

  int? lastMaxTokens;
  List<String> lastStop = const [];
  int stops = 0;
  Duration tokenInterval = const Duration(milliseconds: 20);
  int tokensToEmit = 3;
  String Function(String, List<Map<String, String>>?)? reply;
  Completer<void>? _stopped;

  @override
  int get stopCount => stops;

  @override
  Future<String> generate({
    required String prompt,
    String? systemPrompt,
    List<Map<String, String>>? conversationHistory,
    String source = 'chat',
    String? imagePath,
    String? audioPath,
    int? maxTokens,
    List<String> stopSequences = const [],
    void Function(String token)? onToken,
  }) async {
    lastMaxTokens = maxTokens;
    lastStop = stopSequences;
    isGenerating.value = true;
    generationSource.value = source;
    final stopped = _stopped = Completer<void>();
    final out = StringBuffer();
    final scripted = reply?.call(prompt, conversationHistory);
    final tokens = scripted
            ?.splitMapJoin(RegExp(r'.{1,5}'),
                onMatch: (match) => '${match[0]}\u0000')
            .split('\u0000') ??
        List.generate(tokensToEmit, (index) => 't$index ');
    for (final token in tokens) {
      await Future.any([Future.delayed(tokenInterval), stopped.future]);
      if (stopped.isCompleted) break;
      out.write(token);
      onToken?.call(token);
    }
    isGenerating.value = false;
    generationSource.value = '';
    return out.toString();
  }

  @override
  Future<void> stopGeneration() async {
    stops++;
    isGenerating.value = false;
    generationSource.value = '';
    if (_stopped != null && !_stopped!.isCompleted) _stopped!.complete();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

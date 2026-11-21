import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../core/build_flavor.dart';
import 'agent_service.dart';
import 'device_bridge.dart';
import 'hive_service.dart';

/// A small Alpine Linux that the AI can run commands in (optional download).
/// It runs through proot, with no root and no extra Android permissions.
/// The root filesystem is downloaded only after the user chooses Install.
class SandboxService extends GetxService {
  static const basicToolsInstalledKey = 'alpine_basic_tools_installed';
  static const rootfsUrl =
      'https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/alpine-minirootfs-3.21.9-aarch64.tar.gz';

  static const rootfsSha256 =
      'a389940ee42579ead202fb91607fb25698a58a3a5b55c15b4603e5d39cfa4492';

  final installed = false.obs;
  final downloadProgress = Rx<double?>(null);
  Future<void>? _initializing;
  Future<void>? _installation;
  http.Client? _installationClient;
  int _commands = 0;
  final busy = false.obs;
  final status = ''.obs;

  String _libDir = '';

  static bool get supported => !kIsWeb && Platform.isAndroid && !kPlayBuild;

  Future<Directory> _root() async {
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}/alpine');
  }

  @override
  void onInit() {
    super.onInit();
    if (supported) {
      _initializing = _initialize().catchError((Object error) {
        status.value = 'Could not initialize Linux: $error';
      });
    }
  }

  Future<void> _initialize() async {
    _libDir = await Get.find<DeviceBridge>().nativeLibDir();
    installed.value =
        await File('${(await _root()).path}/rootfs/bin/busybox').exists();
  }

  bool get hasProot =>
      _libDir.isNotEmpty &&
      [
        'libproot.so',
        'libproot_loader.so',
        'libtalloc.so',
        'libandroid-shmem.so'
      ].every((name) => File('$_libDir/$name').existsSync());

  Future<bool> runtimeAvailable() async {
    if (!supported) return false;
    await _initializing;
    return hasProot;
  }

  /// Alpine is downloaded only after the user chooses Install.
  Future<void> install() {
    if (_installation != null) return _installation!;
    final task = _install();
    _installation = task;
    return task.whenComplete(() => _installation = null);
  }

  void cancelInstallation() => _installationClient?.close();

  Future<void> _install() async {
    if (!supported)
      throw Exception('The Linux sandbox requires the full Android build.');
    await _initializing;
    if (_libDir.isEmpty) await _initialize();
    if (!hasProot)
      throw Exception('The Linux runtime is missing from this build.');
    if (installed.value) return;
    if (busy.value || _commands > 0)
      throw StateError('Wait for the current sandbox operation.');
    busy.value = true;
    downloadProgress.value = null;
    final client = _installationClient = http.Client();
    Directory? staging;
    File? archive;
    try {
      final root = await _root();
      await root.create(recursive: true);
      staging = Directory('${root.path}/rootfs.installing');
      if (await staging.exists()) await staging.delete(recursive: true);
      await staging.create(recursive: true);
      status.value = 'Downloading Alpine Linux…';
      archive = File('${root.path}/rootfs.tar.gz.part');
      final response = await client
          .send(http.Request('GET', Uri.parse(rootfsUrl)))
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw HttpException(
            'Alpine download failed (HTTP ${response.statusCode}).');
      }
      final expected = response.contentLength;
      const maxBytes = 16 * 1024 * 1024;
      if (expected != null && expected > maxBytes) {
        throw const FormatException(
            'The Alpine download is unexpectedly large.');
      }
      final sink = archive.openWrite();
      var received = 0;
      final clock = Stopwatch()..start();
      try {
        await for (final chunk
            in response.stream.timeout(const Duration(seconds: 30))) {
          received += chunk.length;
          if (received > maxBytes ||
              clock.elapsed > const Duration(minutes: 5)) {
            throw const FormatException(
                'Alpine download exceeded its size or time limit.');
          }
          sink.add(chunk);
          if (expected != null && expected > 0) {
            downloadProgress.value = received / expected;
            status.value =
                'Downloading Alpine Linux · ${(received * 100 / expected).round()}%';
          }
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (expected != null && received != expected) {
        throw const FormatException(
            'Alpine download is incomplete. Retry installation.');
      }
      status.value = 'Checking download…';
      final digest = await sha256.bind(archive.openRead()).first;
      if (digest.toString() != rootfsSha256) {
        throw const FormatException(
            'Alpine checksum did not match. Retry installation.');
      }
      downloadProgress.value = null;
      status.value = 'Unpacking Alpine Linux…';
      final process = await Process.start('/system/bin/toybox',
          ['tar', '-xzf', archive.path, '-C', staging.path]);
      final output = process.stdout.drain<void>();
      final errors = process.stderr.transform(utf8.decoder).join();
      final exitCode = await process.exitCode
          .timeout(const Duration(minutes: 2), onTimeout: () async {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
        return -1;
      });
      await output;
      final errorText = await errors;
      if (exitCode != 0) throw Exception('Alpine unpack failed: $errorText');
      if (!await File('${staging.path}/bin/busybox').exists() ||
          !await File('${staging.path}/etc/alpine-release').exists()) {
        throw const FormatException('The Alpine installation is incomplete.');
      }
      await File('${staging.path}/etc/resolv.conf')
          .writeAsString('nameserver 1.1.1.1\nnameserver 8.8.8.8\n');
      await Directory('${root.path}/tmp').create(recursive: true);
      final destination = Directory('${root.path}/rootfs');
      if (await destination.exists()) await destination.delete(recursive: true);
      await staging.rename(destination.path);
      staging = null;
      installed.value = true;
      status.value = 'Ready';
    } catch (_) {
      status.value = 'Installation failed. Retry to download Alpine again.';
      rethrow;
    } finally {
      client.close();
      _installationClient = null;
      if (archive != null && await archive.exists()) await archive.delete();
      if (staging != null && await staging.exists())
        await staging.delete(recursive: true);
      downloadProgress.value = null;
      busy.value = false;
    }
  }

  Future<void> uninstall() async {
    await _initializing;
    if (_installation != null || busy.value || _commands > 0) {
      throw StateError(
          'Wait for the current sandbox operation before removing Linux.');
    }
    final root = await _root();
    if (await root.exists()) await root.delete(recursive: true);
    installed.value = false;
    status.value = '';
    await Get.find<HiveService>().setSetting(basicToolsInstalledKey, false);
  }

  Future<void> _lock = Future.value();

  /// Runs [command] inside Alpine. The AI's workspace is /workspace.
  /// One sandbox is shared by every chat; commands run one at a time so
  /// package installs never collide.
  Future<String> run(String command,
      {int timeoutSec = 120, String workingDirectory = '/workspace'}) {
    final done = Completer<String>();
    _commands++;
    final prev = _lock;
    _lock = done.future.catchError((_) => '');
    prev.whenComplete(() async {
      try {
        done.complete(await _run(command,
            timeoutSec: timeoutSec.clamp(5, 1800),
            workingDirectory: workingDirectory));
      } catch (e) {
        done.complete('Error: $e');
      } finally {
        _commands--;
      }
    });
    return done.future;
  }

  Future<String> _run(String command,
      {required int timeoutSec, required String workingDirectory}) async {
    final p = await _start(['/bin/sh', '-c', command],
        workingDirectory: workingDirectory);
    final out = StringBuffer();
    void add(List<int> b) {
      if (out.length < 60000) out.write(utf8.decode(b, allowMalformed: true));
    }

    p.stdin.close();
    final streams = [p.stdout.forEach(add), p.stderr.forEach(add)];
    var timedOut = false;
    final code =
        await p.exitCode.timeout(Duration(seconds: timeoutSec), onTimeout: () {
      timedOut = true;
      p.kill(ProcessSignal.sigkill);
      return -1;
    });
    await Future.wait(streams)
        .timeout(const Duration(seconds: 2), onTimeout: () => []);
    var text = out.toString().trim();
    if (text.length > 6000) {
      text =
          '${text.substring(0, 2500)}\n… (output cut) …\n${text.substring(text.length - 3200)}';
    }
    return '${timedOut ? '[timed out after $timeoutSec s]\n' : ''}${text.isEmpty ? '(no output)' : text}\n[exit code $code]';
  }

  Future<Directory> openCodeDirectory() async {
    if (!supported)
      throw UnsupportedError('OpenCode requires the standalone Android APK.');
    return Directory('${(await _root()).path}/rootfs/opt/neuromesh-opencode');
  }

  Future<Process> startOpenCodeProcess(List<String> command,
      {Map<String, String> environment = const {}}) async {
    if (busy.value || _commands > 0) {
      throw StateError('Wait for the current Linux operation.');
    }
    _commands++;
    final finished = Completer<void>();
    _lock = finished.future;
    try {
      final process = await _start(command,
          workingDirectory: '/workspace', environment: environment);
      unawaited(process.exitCode.whenComplete(() {
        _commands--;
        finished.complete();
      }));
      return process;
    } catch (_) {
      _commands--;
      finished.complete();
      rethrow;
    }
  }

  Future<Process> _start(List<String> command,
      {required String workingDirectory,
      Map<String, String> environment = const {}}) async {
    await _initializing;
    if (!supported || !installed.value || !hasProot) {
      throw StateError('Install the Alpine runtime before using its commands.');
    }
    final root = await _root();
    final work = (await Get.find<AgentService>().filesDir()).path;
    final libs = '${root.path}/lib';
    await Directory(libs).create(recursive: true);
    // proot needs libtalloc.so.2; the APK can only carry names ending in .so.
    final talloc = File('$libs/libtalloc.so.2');
    if (!await talloc.exists() && File('$_libDir/libtalloc.so').existsSync()) {
      await File('$_libDir/libtalloc.so').copy(talloc.path);
    }
    final args = [
      '-r',
      '${root.path}/rootfs',
      '-0',
      '--link2symlink',
      '-w',
      workingDirectory,
      '-b',
      '/dev',
      '-b',
      '/proc',
      '-b',
      '/sys',
      '-b',
      '$work:/workspace',
      ...command,
    ];
    final env = {
      'PROOT_LOADER': '$_libDir/libproot_loader.so',
      'PROOT_TMP_DIR': '${root.path}/tmp',
      'LD_LIBRARY_PATH': '$libs:$_libDir',
      'HOME': '/root',
      'PATH':
          '/workspace/_bin:/root/.npm-global/bin:/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
      'TERM': 'xterm',
      'LANG': 'C.UTF-8',
      'PIP_BREAK_SYSTEM_PACKAGES': '1',
      'PIP_ROOT_USER_ACTION': 'ignore',
      'PIP_DISABLE_PIP_VERSION_CHECK': '1',
      'NPM_CONFIG_PREFIX': '/root/.npm-global',
    };
    return Process.start('$_libDir/libproot.so', args,
        environment: {...env, ...environment}, includeParentEnvironment: false);
  }
}

/// Package sets for [sandbox_setup].
const sandboxProfiles = <String, String>{
  'basic': 'python3 py3-pip nodejs npm git curl wget unzip zip jq',
  'full': 'python3 py3-pip nodejs npm git curl wget unzip zip jq ffmpeg imagemagick pandoc poppler-utils sqlite '
      'ripgrep tree nano openssh-client rsync make gcc g++ musl-dev python3-dev tesseract-ocr',
};

/// One tool the AI wrote for itself. Its code lives in the shared sandbox.
class CustomTool {
  final String name; // without the "x_" prefix
  final String description;
  final String params;
  final String language; // python, node or sh
  final String code;
  const CustomTool(
      this.name, this.description, this.params, this.language, this.code);

  Map<String, dynamic> toMap() => {
        'name': name,
        'description': description,
        'params': params,
        'language': language,
        'code': code
      };

  static CustomTool fromMap(Map m) => CustomTool(
      '${m['name']}',
      '${m['description']}',
      '${m['params']}',
      '${m['language']}',
      '${m['code']}');

  String get toolName => 'x_$name';
  String get ext => language == 'python'
      ? 'py'
      : language == 'node'
          ? 'js'
          : 'sh';
}

extension SandboxAgentTools on SandboxService {
  static const _customKey = 'sandbox_custom_tools';

  List<CustomTool> loadCustomTools() {
    final raw =
        Get.find<HiveService>().getSetting<List>(_customKey) ?? const [];
    return raw.whereType<Map>().map(CustomTool.fromMap).toList();
  }

  Future<void> saveCustomTools(List<CustomTool> l) => Get.find<HiveService>()
      .setSetting(_customKey, [for (final t in l) t.toMap()]);

  /// Command that makes sure the language runtime exists, then runs [file].
  String runnerFor(String lang, String file, [String args = '']) {
    switch (lang) {
      case 'python':
        return 'command -v python3 >/dev/null 2>&1 || apk add --no-cache python3 py3-pip >&2; python3 $file $args';
      case 'node':
        return 'command -v node >/dev/null 2>&1 || apk add --no-cache nodejs npm >&2; node $file $args';
      default:
        return 'sh $file $args';
    }
  }

  /// Installs packages: plain or "apk:" names use apk, "pip:" pip, "npm:" npm.
  Future<String> installPackages(String spec) async {
    final apk = <String>[], pip = <String>[], npm = <String>[];
    for (final w in spec.split(RegExp(r'[\s,]+')).where((e) => e.isNotEmpty)) {
      if (!RegExp(r'^[A-Za-z0-9_.@/:+=<>~\-]+$').hasMatch(w))
        return 'Error: invalid package name "$w".';
      if (w.startsWith('pip:')) {
        pip.add(w.substring(4));
      } else if (w.startsWith('npm:')) {
        npm.add(w.substring(4));
      } else {
        apk.add(w.startsWith('apk:') ? w.substring(4) : w);
      }
    }
    final out = StringBuffer();
    if (apk.isNotEmpty)
      out.writeln(
          await run('apk add --no-cache ${apk.join(' ')}', timeoutSec: 900));
    if (pip.isNotEmpty) {
      out.writeln(await run(
          'command -v pip3 >/dev/null 2>&1 || apk add --no-cache python3 py3-pip; pip3 install ${pip.join(' ')}',
          timeoutSec: 900));
    }
    if (npm.isNotEmpty) {
      out.writeln(await run(
          'command -v npm >/dev/null 2>&1 || apk add --no-cache nodejs npm; npm install -g ${npm.join(' ')}',
          timeoutSec: 900));
    }
    return out.toString().trim();
  }

  Future<String> toolsDir() async {
    final d =
        Directory('${(await Get.find<AgentService>().filesDir()).path}/_tools');
    if (!await d.exists()) await d.create(recursive: true);
    return d.path;
  }

  Future<void> writeToolFile(CustomTool t) async {
    await File('${await toolsDir()}/${t.name}.${t.ext}').writeAsString(t.code);
  }

  AgentTool asAgentTool(CustomTool t) => AgentTool(
        t.toolName,
        '[your own tool] ${t.description}',
        t.params,
        (args) async {
          if (!installed.value)
            return 'Error: the sandbox is not installed. Call sandbox_setup.';
          await writeToolFile(t);
          final dir = await toolsDir();
          await File('$dir/${t.name}.args.json')
              .writeAsString(jsonEncode(args));
          return run(
              'cd /workspace && ${runnerFor(t.language, '/workspace/_tools/${t.name}.${t.ext}', '/workspace/_tools/${t.name}.args.json')}',
              timeoutSec: 300);
        },
      );

  /// Registers every saved custom tool with the agent (called at start-up).
  void registerCustomTools(AgentService agent) {
    for (final t in loadCustomTools()) {
      agent.addTool(asAgentTool(t));
    }
  }
}

/// Gives the AI the sandbox: shell, installers, scripts, file conversion and
/// the ability to write, save and reuse its own tools. The sandbox is ONE
/// shared Linux for every chat, so what it installs stays installed.
void registerSandboxShell(AgentService agent) {
  if (!SandboxService.supported) return;
  SandboxService sb() => Get.find<SandboxService>();

  agent.addTool(AgentTool(
    'run_shell',
    'Run a shell command in the shared Alpine Linux sandbox. Waits for it to finish and returns output and exit code. /workspace is your workspace folder. Installed tools stay for every chat. Default timeout 120 s; set "timeout" (max 1800) for long jobs.',
    '{"command":"string","timeout":"optional seconds"}',
    (args) async => sb().run((args['command'] ?? '').toString(),
        timeoutSec: int.tryParse('${args['timeout'] ?? ''}') ?? 120),
    needsConfirm: true,
  ));

  agent.addTool(AgentTool(
    'sandbox_setup',
    'Install or complete the sandbox. profile "basic" = python, node, git, curl, jq, zip. "full" = basic + ffmpeg, imagemagick, pandoc, pdf tools, sqlite, gcc, OCR. Safe to repeat. Takes minutes.',
    '{"profile":"basic or full"}',
    (args) async {
      final s = sb();
      if (!s.installed.value) {
        try {
          await s.install();
        } catch (e) {
          return 'Error: $e';
        }
      }
      final p = (args['profile'] ?? 'full').toString();
      final pk = sandboxProfiles[p] ?? sandboxProfiles['full']!;
      s.busy.value = true;
      s.status.value = 'Installing tools…';
      try {
        final out = await s.run(
            'apk update >/dev/null 2>&1; apk add --no-cache $pk',
            timeoutSec: 1500);
        final ok = out.endsWith('[exit code 0]');
        return '${ok ? 'Sandbox profile installed' : 'Sandbox package setup failed'}.\n${out.length > 800 ? out.substring(out.length - 800) : out}';
      } finally {
        s.busy.value = false;
        s.status.value = 'Ready';
      }
    },
    needsConfirm: true,
  ));

  agent.addTool(AgentTool(
    'install_packages',
    'Install software in the sandbox. Plain names or "apk:x" use Alpine apk, "pip:x" pip, "npm:x" a global npm package. Example: "ffmpeg pip:requests npm:typescript".',
    '{"packages":"space-separated list"}',
    (args) => sb().installPackages((args['packages'] ?? '').toString()),
    needsConfirm: true,
  ));

  agent.addTool(AgentTool(
    'run_script',
    'Write a script and run it in the sandbox. For data work, conversions, API calls, anything beyond one command. Missing runtimes install themselves.',
    '{"language":"python|node|sh","code":"full script","name":"optional file name","args":"optional arguments"}',
    (args) async {
      final lang = (args['language'] ?? 'python').toString().toLowerCase();
      if (!const ['python', 'node', 'sh'].contains(lang))
        return 'Error: language must be python, node or sh.';
      final code = (args['code'] ?? '').toString();
      if (code.trim().isEmpty) return 'Error: "code" is empty.';
      final base = (args['name'] ?? '')
          .toString()
          .replaceAll(RegExp(r'[^\w\-]'), '')
          .trim();
      final ext = lang == 'python'
          ? 'py'
          : lang == 'node'
              ? 'js'
              : 'sh';
      final dir = Directory(
          '${(await Get.find<AgentService>().filesDir()).path}/scripts');
      if (!await dir.exists()) await dir.create(recursive: true);
      final fname =
          '${base.isEmpty ? 'script_${DateTime.now().millisecondsSinceEpoch}' : base}.$ext';
      await File('${dir.path}/$fname').writeAsString(code);
      return sb().run(
          'cd /workspace && ${sb().runnerFor(lang, '/workspace/scripts/$fname', (args['args'] ?? '').toString())}',
          timeoutSec: 300);
    },
    needsConfirm: true,
  ));

  agent.addTool(AgentTool(
    'convert_file',
    'Convert a workspace file with Linux tools (auto-installed): mp3/wav/mp4 audio-video, png/jpg images, pdf to text, docx/md/html documents, csv to json.',
    '{"name":"input file","output":"output file name with the target extension","options":"optional extra flags"}',
    (args) async {
      final inName = (args['name'] ?? '').toString().split('/').last;
      final outName = (args['output'] ?? '').toString().split('/').last;
      final f = await agent.workspaceFile(inName);
      if (f == null) return 'Error: no such file. Use list_files.';
      final out = await agent.newWorkspaceFile(outName);
      String q(String x) => "'${x.replaceAll("'", "'\\''")}'";
      final i = q('/workspace/$inName'), o = q('/workspace/$outName');
      final ie = inName.split('.').last.toLowerCase(),
          oe = outName.split('.').last.toLowerCase();
      final opts = (args['options'] ?? '').toString();
      const media = {
        'mp3',
        'wav',
        'm4a',
        'ogg',
        'flac',
        'aac',
        'mp4',
        'mkv',
        'webm',
        'mov',
        'avi',
        'gif'
      };
      const img = {'png', 'jpg', 'jpeg', 'webp', 'bmp', 'gif', 'tiff'};
      const docs = {'docx', 'md', 'html', 'txt', 'odt', 'rtf', 'epub'};
      String cmd;
      if (ie == 'pdf' && (oe == 'txt' || oe == 'md')) {
        cmd =
            'command -v pdftotext >/dev/null || apk add --no-cache poppler-utils; pdftotext -layout $opts $i $o';
      } else if (media.contains(ie) && media.contains(oe)) {
        cmd =
            'command -v ffmpeg >/dev/null || apk add --no-cache ffmpeg; ffmpeg -y -i $i $opts $o';
      } else if (img.contains(ie) && (img.contains(oe) || oe == 'pdf')) {
        cmd =
            'command -v convert >/dev/null || apk add --no-cache imagemagick; convert $i $opts $o';
      } else if ((docs.contains(ie) || ie == 'pdf') &&
          (docs.contains(oe) || oe == 'pdf')) {
        cmd =
            'command -v pandoc >/dev/null || apk add --no-cache pandoc; pandoc $i $opts -o $o';
      } else if (ie == 'csv' && oe == 'json') {
        cmd = 'command -v python3 >/dev/null || apk add --no-cache python3; '
            'python3 -c "import csv,json,sys;print(json.dumps(list(csv.DictReader(open(sys.argv[1],encoding=\'utf-8-sig\'))),ensure_ascii=False,indent=1))" $i > $o';
      } else {
        return 'Error: no converter for .$ie to .$oe. Use run_shell or run_script with the right tool.';
      }
      final res = await sb().run(cmd, timeoutSec: 600);
      if (!await out.exists()) return 'Conversion failed:\n$res';
      return 'Created $outName (${out.lengthSync() ~/ 1024} KB). Show it with [📎 $outName](nmfile:$outName).';
    },
    needsConfirm: true,
  ));

  agent.addTool(AgentTool(
    'sandbox_status',
    'Show what the sandbox has: Alpine version, free disk, which languages and tools are installed, and your own tools.',
    '{}',
    (args) async {
      final s = sb();
      if (!s.installed.value)
        return 'The sandbox is NOT installed yet. Call sandbox_setup.';
      final r = await s.run(
          'cat /etc/alpine-release; df -h /workspace | tail -1; for c in python3 pip3 node npm git curl ffmpeg convert pandoc pdftotext sqlite3 gcc rg tesseract; do command -v \$c >/dev/null 2>&1 && echo "have: \$c" || echo "missing: \$c"; done',
          timeoutSec: 60);
      final mine = s.loadCustomTools();
      return '$r\nYour own tools: ${mine.isEmpty ? 'none yet' : mine.map((t) => t.toolName).join(', ')}';
    },
  ));

  agent.addTool(AgentTool(
    'create_tool',
    'Make a NEW reusable tool for yourself. Write a script (python, node or sh) that reads its arguments from the JSON file whose path is its first command-line argument (python: json.load(open(sys.argv[1]))) and prints the result. It is saved for every chat and you call it as x_<name> from the next step.',
    '{"name":"lowercase_with_underscores","description":"what it does","params":"example JSON of its arguments","language":"python|node|sh","code":"full script","requires":"optional packages, e.g. pip:requests ffmpeg"}',
    (args) async {
      final s = sb();
      if (!s.installed.value)
        return 'Error: the sandbox is not installed. Call sandbox_setup first.';
      final name = (args['name'] ?? '')
          .toString()
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-z0-9_]'), '_');
      if (name.isEmpty || name.length > 40)
        return 'Error: give a short "name" (letters, digits, underscore).';
      final lang = (args['language'] ?? 'python').toString().toLowerCase();
      if (!const ['python', 'node', 'sh'].contains(lang))
        return 'Error: language must be python, node or sh.';
      final code = (args['code'] ?? '').toString();
      if (code.trim().isEmpty) return 'Error: "code" is empty.';
      final desc = (args['description'] ?? '').toString().trim();
      if (desc.isEmpty) return 'Error: add a "description".';
      final req = (args['requires'] ?? '').toString().trim();
      var note = '';
      if (req.isNotEmpty)
        note =
            '\nInstalled: ${(await s.installPackages(req)).split('\n').last}';
      final t = CustomTool(
          name, desc, (args['params'] ?? '{}').toString(), lang, code);
      await s.writeToolFile(t);
      final all = s.loadCustomTools()..removeWhere((e) => e.name == name);
      all.add(t);
      await s.saveCustomTools(all);
      agent.addTool(s.asAgentTool(t));
      final test = await s.asAgentTool(t).run(<String, dynamic>{});
      return 'Tool saved as ${t.toolName}. Call it now.$note\nTest run with empty arguments:\n$test';
    },
    needsConfirm: true,
  ));

  agent.addTool(AgentTool(
    'list_my_tools',
    'List the tools you created earlier with create_tool.',
    '{}',
    (args) async {
      final l = sb().loadCustomTools();
      if (l.isEmpty) return 'You have not created any tools yet.';
      return l
          .map((t) =>
              '${t.toolName} [${t.language}] ${t.description}  arguments: ${t.params}')
          .join('\n');
    },
  ));

  agent.addTool(AgentTool(
    'delete_my_tool',
    'Delete a tool you created earlier.',
    '{"name":"tool name"}',
    (args) async {
      final s = sb();
      final n =
          (args['name'] ?? '').toString().replaceFirst(RegExp(r'^x_'), '');
      final all = s.loadCustomTools();
      if (!all.any((t) => t.name == n))
        return 'Error: no such tool. Use list_my_tools.';
      all.removeWhere((t) => t.name == n);
      await s.saveCustomTools(all);
      agent.removeTool('x_$n');
      return 'Deleted x_$n.';
    },
  ));

  sb().registerCustomTools(agent);
}

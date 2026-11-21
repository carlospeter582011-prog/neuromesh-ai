import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:get/get.dart';
import 'package:xterm/xterm.dart';

import '../core/ui.dart';
import '../services/android_opencode.dart';
import '../services/inference_service.dart';
import '../services/sandbox_service.dart';

class AndroidAgentHubView extends StatefulWidget {
  const AndroidAgentHubView({super.key});

  @override
  State<AndroidAgentHubView> createState() => _AndroidAgentHubViewState();
}

class _AndroidAgentHubViewState extends State<AndroidAgentHubView> {
  final _agent = AndroidOpenCode(Get.find<SandboxService>());
  final _inference = Get.find<InferenceService>();
  final _input = TextEditingController();
  final _scroll = ScrollController();
  List<OpenCodeMessage> _messages = [];
  String _status = '';
  String _tool = '';
  String _reply = '';
  String? _error;
  double? _progress;
  bool _busy = false;
  bool _installed = false;
  bool _connected = false;
  bool _allowWorkspaceReads = false;

  @override
  void initState() {
    super.initState();
    unawaited(_act(_discover));
  }

  Future<void> _discover() async {
    final status = await _agent.discover();
    final installed = await _agent.installed();
    if (mounted) {
      setState(() {
        _status = status;
        _installed = installed;
      });
    }
  }

  Future<void> _act(Future<void> Function() work) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await work();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted)
        setState(() {
          _progress = null;
          _busy = false;
        });
    }
  }

  Future<bool> _confirm(String title, String detail, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(title),
          content: Text(detail),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialog, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(dialog, true),
                child: Text(action)),
          ],
        ),
      ) ??
      false;

  Future<void> _install() async {
    if (!await _confirm(
        'Set up OpenCode',
        'OpenCode downloads about 79 MB. Allow around 400 MB for installation, '
            'temporary files and Alpine terminal tools. Alpine is installed if needed.',
        _installed ? 'Repair installation' : 'Install')) return;
    if (!mounted) return;
    await _act(() async {
      await _agent.install((text, value) {
        if (mounted)
          setState(() {
            _status = text;
            _progress = value;
          });
      });
      await _discover();
    });
  }

  Future<void> _connect({required bool terminal}) async {
    final model = _inference.loadedModelName.value;
    if (!await _confirm(
        'Connect OpenCode to $model',
        _allowWorkspaceReads
            ? 'Allow OpenCode to read files in the default workspace using the local model.'
            : 'Link OpenCode to the currently loaded model for text responses.',
        'Connect')) return;
    if (!mounted) return;
    await _act(() async {
      await _agent.connect(model, _inference.contextTokensTotal.value,
          allowWorkspaceReads: _allowWorkspaceReads);
      if (mounted) setState(() => _connected = true);
      await _history();
    });
    if (terminal && mounted && _connected) await _terminal();
  }

  Future<void> _history() async {
    final messages = await _agent.history();
    if (mounted) setState(() => _messages = messages);
    _toEnd();
  }

  void _toEnd() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });

  Future<void> _send() async {
    final text = _input.text.trim();
    if (_busy || !_connected || text.isEmpty) return;
    _input.clear();
    setState(() {
      _messages.add((role: 'user', text: text));
      _reply = '';
      _tool = '';
    });
    _toEnd();
    await _act(() async {
      try {
        await _agent.send(text, (reply) {
          if (mounted) setState(() => _reply += reply);
          _toEnd();
        }, (tool) {
          if (mounted) setState(() => _tool = tool);
        });
      } finally {
        if (mounted) {
          if (_reply.isNotEmpty)
            _messages.add((role: 'assistant', text: _reply));
          setState(() => _reply = '');
        }
      }
    });
  }

  Future<void> _sessions() => _act(() async {
        final sessions = await _agent.sessions();
        if (!mounted) return;
        final id = await showDialog<String>(
          context: context,
          builder: (dialog) => SimpleDialog(
            title: const Text('OpenCode sessions'),
            children: [
              for (final session in sessions.entries)
                SimpleDialogOption(
                    onPressed: () => Navigator.pop(dialog, session.key),
                    child: Text(session.value)),
              if (sessions.isEmpty)
                const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('No sessions yet.')),
            ],
          ),
        );
        if (id != null) {
          await _agent.selectSession(id);
          await _history();
        }
      });

  Future<void> _terminal() => _act(() async {
        await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => _OpenCodeTerminal(agent: _agent),
        ));
        await _agent.stopProcess();
        final sessions = await _agent.sessions();
        if (_agent.sessionId == null && sessions.isNotEmpty) {
          await _agent.selectSession(sessions.keys.first);
        }
        await _history();
      });

  @override
  void dispose() {
    unawaited(_agent.disconnect());
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: appScreenBar(context, title: 'Agent Hub'),
        body: SafeArea(
          child: Column(children: [
            ListTile(
              title: const Text('OpenCode · Android ARM64 preview'),
              subtitle: Text(_error ?? _status),
            ),
            if (_busy) LinearProgressIndicator(value: _progress),
            if (!_connected) ...[
              Wrap(
                spacing: 8,
                children: [
                  FilledButton(
                    onPressed: _agent.compatible && !_busy ? _install : null,
                    child: Text(
                        _installed ? 'Repair OpenCode' : 'Install OpenCode'),
                  ),
                  if (_installed)
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () async {
                              if (!await _confirm(
                                  'Remove OpenCode',
                                  'This removes OpenCode and its local sessions. Alpine and your workspace files stay installed.',
                                  'Remove')) return;
                              if (!mounted) return;
                              await _act(() async {
                                await _agent.remove();
                                await _discover();
                              });
                            },
                      child: const Text('Remove'),
                    ),
                  if (_busy)
                    TextButton(
                        onPressed: _agent.cancel, child: const Text('Cancel')),
                ],
              ),
              Obx(() {
                final model = _inference.loadedModelName.value;
                final ready = _inference.isModelLoaded.value &&
                    _inference.contextTokensTotal.value >= 2048;
                final canConnect = _installed && ready && !_busy;
                return Column(
                  children: [
                    Text(ready
                        ? 'Local model: $model'
                        : 'Load a local model with at least 2048 context tokens'),
                    Wrap(spacing: 8, children: [
                      OutlinedButton.icon(
                        onPressed:
                            canConnect ? () => _connect(terminal: false) : null,
                        icon: const Icon(Icons.chat_outlined),
                        label: const Text('Chat'),
                      ),
                      OutlinedButton.icon(
                        onPressed:
                            canConnect ? () => _connect(terminal: true) : null,
                        icon: const Icon(Icons.terminal),
                        label: const Text('Terminal'),
                      ),
                    ]),
                  ],
                );
              }),
              SwitchListTile(
                title: const Text('Allow workspace reads'),
                subtitle: const Text(
                    'Experimental. Requires a model that follows tool instructions.'),
                value: _allowWorkspaceReads,
                onChanged: _installed && !_busy
                    ? (value) => setState(() => _allowWorkspaceReads = value)
                    : null,
              ),
              const ListTile(
                title: Text('Codex CLI and Claude Code'),
                subtitle: Text('Unsupported in this Android preview.'),
              ),
            ] else ...[
              Wrap(
                children: [
                  const Chip(label: Text('Chat')),
                  TextButton(
                      onPressed: _busy ? null : _sessions,
                      child: const Text('Sessions')),
                  TextButton(
                      onPressed: _busy
                          ? null
                          : () => _act(() async {
                                await _agent.newChat();
                                await _history();
                              }),
                      child: const Text('New chat')),
                  TextButton(
                      onPressed: _busy ? null : _terminal,
                      child: const Text('Terminal')),
                  TextButton(
                      onPressed: _busy
                          ? null
                          : () => _act(() async {
                                await _agent.disconnect();
                                if (mounted) setState(() => _connected = false);
                              }),
                      child: const Text('Disconnect')),
                ],
              ),
              Expanded(
                  child: ListView(
                controller: _scroll,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  for (final message in _messages) _message(context, message),
                  if (_reply.isNotEmpty)
                    _message(context, (role: 'assistant', text: _reply)),
                  if (_tool.isNotEmpty)
                    ListTile(
                      leading: const Icon(Icons.build_outlined),
                      title: Text(_tool),
                    ),
                ],
              )),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Row(children: [
                  Expanded(
                      child: TextField(
                    controller: _input,
                    onSubmitted: (_) => _send(),
                    decoration: const InputDecoration(hintText: 'Ask OpenCode'),
                  )),
                  IconButton(
                    tooltip: _busy ? 'Stop' : 'Send',
                    onPressed: _busy ? _agent.cancel : _send,
                    icon: Icon(_busy ? Icons.stop_circle_outlined : Icons.send),
                  ),
                ]),
              ),
            ],
          ]),
        ),
      );

  Widget _message(BuildContext context, OpenCodeMessage message) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(message.role == 'user' ? 'You' : 'OpenCode',
              style: Theme.of(context).textTheme.labelLarge),
          if (message.role == 'user')
            SelectableText(message.text)
          else
            MarkdownBody(data: message.text, selectable: true),
        ]),
      );
}

class _OpenCodeTerminal extends StatefulWidget {
  const _OpenCodeTerminal({required this.agent});
  final AndroidOpenCode agent;

  @override
  State<_OpenCodeTerminal> createState() => _OpenCodeTerminalState();
}

class _OpenCodeTerminalState extends State<_OpenCodeTerminal> {
  final _terminal = Terminal(maxLines: 1500);
  Process? _process;
  String _status = 'Opening OpenCode…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    if (!mounted) return;
    try {
      final process = await widget.agent.terminal(
        width: _terminal.viewWidth,
        height: _terminal.viewHeight,
      );
      if (!mounted) {
        await widget.agent.stopProcess();
        return;
      }
      _process = process;
      _terminal.onOutput = (text) => _process?.stdin.add(utf8.encode(text));
      setState(() => _status = '');
      await Future.wait([
        process.stdout
            .transform(const Utf8Decoder(allowMalformed: true))
            .forEach(_terminal.write),
        process.stderr
            .transform(const Utf8Decoder(allowMalformed: true))
            .forEach(_terminal.write),
      ]);
      final code = await process.exitCode;
      _process = null;
      if (mounted) setState(() => _status = 'OpenCode exited ($code)');
    } catch (error) {
      if (mounted) setState(() => _status = '$error');
    }
  }

  @override
  void dispose() {
    widget.agent.cancel();
    _terminal.onOutput = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar:
            appScreenBar(context, title: 'OpenCode Terminal', showBack: true),
        body: SafeArea(
            child: Column(children: [
          if (_status.isNotEmpty)
            Padding(padding: const EdgeInsets.all(8), child: Text(_status)),
          Expanded(
              child: TerminalView(_terminal,
                  autofocus: true, keyboardType: TextInputType.text)),
        ])),
      );
}

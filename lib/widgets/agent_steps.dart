import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:share_plus/share_plus.dart';

import '../services/agent_service.dart';
import 'image_viewer.dart';

/// One tool step the agent took, parsed from a saved trace line.
class AgentStep {
  final String name;
  final String label;
  final Map<String, dynamic> args;
  final String result;
  final bool running;
  final int ms;
  const AgentStep(
      this.name, this.label, this.args, this.result, this.running, this.ms);

  static AgentStep? parse(String line) {
    if (!line.startsWith(ToolLoopResult.traceMark)) return null;
    try {
      final j = jsonDecode(line.substring(ToolLoopResult.traceMark.length));
      if (j is! Map) return null;
      return AgentStep(
        '${j['n'] ?? ''}',
        '${j['l'] ?? j['n'] ?? ''}',
        (j['a'] is Map)
            ? Map<String, dynamic>.from(j['a'] as Map)
            : <String, dynamic>{},
        '${j['r'] ?? ''}',
        j['run'] == true,
        (j['ms'] is num) ? (j['ms'] as num).toInt() : 0,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Splits a message into its structured steps and the rest of the text.
/// Old-style trace lines (plain markdown) stay in the text.
(List<AgentStep>, String) splitSteps(String content) {
  if (!content.contains(ToolLoopResult.traceMark)) return (const [], content);
  final steps = <AgentStep>[];
  final rest = <String>[];
  for (final l in content.split('\n')) {
    final s = AgentStep.parse(l);
    if (s != null) {
      steps.add(s);
    } else {
      rest.add(l);
    }
  }
  return (steps, rest.join('\n').trimLeft());
}

IconData _iconFor(String n) {
  switch (n) {
    case 'web_search':
      return Icons.travel_explore_rounded;
    case 'fetch_url':
      return Icons.public_rounded;
    case 'run_shell':
      return Icons.terminal_rounded;
    case 'read_file':
    case 'read_user_file':
    case 'search_in_file':
    case 'list_files':
    case 'list_folder':
    case 'file_info':
      return Icons.description_outlined;
    case 'write_file':
    case 'write_user_file':
      return Icons.edit_note_rounded;
    case 'transcribe_audio':
      return Icons.hearing_rounded;
    case 'text_to_speech':
      return Icons.record_voice_over_rounded;
    case 'generate_image':
      return Icons.image_outlined;
    case 'device_status':
      return Icons.battery_charging_full_rounded;
    case 'remember':
    case 'forget':
      return Icons.psychology_alt_outlined;
    case 'ask_user':
      return Icons.help_outline_rounded;
    default:
      return Icons.build_circle_outlined;
  }
}

/// A collapsible "what the agent did" list; tap a step for its details.
class AgentStepsView extends StatefulWidget {
  final List<AgentStep> steps;
  final String messageId;
  final bool live;
  final RxString? traceSource;
  const AgentStepsView(
      {super.key,
      required this.steps,
      required this.messageId,
      this.live = false,
      this.traceSource});
  @override
  State<AgentStepsView> createState() => _AgentStepsViewState();
}

class _AgentStepsViewState extends State<AgentStepsView> {
  late final ValueNotifier<List<AgentStep>> changes =
      ValueNotifier(widget.steps);
  bool open = false;
  @override
  void didUpdateWidget(covariant AgentStepsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) changes.value = widget.steps;
    });
  }

  @override
  void dispose() {
    if (!open) changes.dispose();
    super.dispose();
  }

  Future<void> showSteps() async {
    if (open) return;
    open = true;
    final source = widget.traceSource;
    final worker = source == null
        ? null
        : ever<String>(source, (text) {
            final current = splitSteps(text).$1;
            if (current.isNotEmpty) changes.value = current;
          });
    await showDialog<void>(
        context: context,
        builder: (ctx) => Dialog(
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                    maxWidth: 600,
                    maxHeight: MediaQuery.sizeOf(ctx).height * .75),
                child: ValueListenableBuilder<List<AgentStep>>(
                    valueListenable: changes,
                    builder: (ctx, steps, _) =>
                        Column(mainAxisSize: MainAxisSize.min, children: [
                          ListTile(
                              title: Text(
                                  'Agent activity · ${steps.length} steps'),
                              trailing: IconButton(
                                  tooltip: 'Close',
                                  icon: const Icon(Icons.close),
                                  onPressed: () => Navigator.pop(ctx))),
                          const Divider(height: 1),
                          Flexible(
                              child: ListView.builder(
                                  shrinkWrap: true,
                                  padding: const EdgeInsets.all(12),
                                  itemCount: steps.length,
                                  itemBuilder: (ctx, i) => _StepTile(
                                      step: steps[i],
                                      updates: changes,
                                      index: i))),
                        ])),
              ),
            ));
    worker?.dispose();
    open = false;
    if (!mounted) changes.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final steps = widget.steps;
    if (steps.isEmpty) return const SizedBox.shrink();
    final running = steps.any((s) => s.running);
    final total = steps.fold<int>(0, (a, s) => a + s.ms);
    return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: showSteps,
              icon: running
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.terminal_rounded, size: 17),
              label: Row(mainAxisSize: MainAxisSize.min, children: [
                Flexible(
                    child: Text(
                        running
                            ? 'Working… ${steps.lastWhere((s) => s.running).label}'
                            : '${steps.length} step${steps.length == 1 ? '' : 's'}${total > 0 ? ' · ${(total / 1000).toStringAsFixed(1)}s' : ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis)),
                const Icon(Icons.chevron_right, size: 17)
              ]),
              style: TextButton.styleFrom(
                  foregroundColor:
                      Theme.of(context).colorScheme.onSurfaceVariant),
            )));
  }
}

class _StepTile extends StatelessWidget {
  final AgentStep step;
  final ValueNotifier<List<AgentStep>> updates;
  final int index;
  const _StepTile(
      {required this.step, required this.updates, required this.index});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 6),
      leading: step.running
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(_iconFor(step.name), size: 18),
      title: Text(step.label,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13)),
      subtitle: Text(
        step.running
            ? 'Working…'
            : '${step.name}${step.ms > 0 ? ' · ${(step.ms / 1000).toStringAsFixed(1)}s' : ''}',
        style: const TextStyle(fontSize: 11.5),
      ),
      trailing: const Icon(Icons.chevron_right_rounded, size: 18),
      onTap: () => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        useSafeArea: true,
        builder: (context) => ValueListenableBuilder<List<AgentStep>>(
          valueListenable: updates,
          builder: (context, current, _) => _StepDetails(
              step: index < current.length ? current[index] : step),
        ),
      ),
    );
  }
}

class _StepDetails extends StatelessWidget {
  final AgentStep step;
  const _StepDetails({required this.step});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textStyle = theme.textTheme.bodyMedium;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.65),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(step.label, style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                  '${step.name}${step.ms > 0 ? ' · ${(step.ms / 1000).toStringAsFixed(1)}s' : ''}',
                  style: theme.textTheme.bodySmall),
              if (step.args.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('Input', style: theme.textTheme.titleSmall),
                for (final entry in step.args.entries) ...[
                  const SizedBox(height: 8),
                  Text(_fieldLabel(entry.key),
                      style: theme.textTheme.labelLarge),
                  SelectableText(_fieldValue(entry.value), style: textStyle),
                ],
              ],
              const SizedBox(height: 12),
              Text(step.running ? 'Working…' : 'Result',
                  style: theme.textTheme.labelLarge),
              if (!step.running)
                SelectableText(_readableResult(step.result), style: textStyle),
            ],
          ),
        ),
      ),
    );
  }
}

String _readableResult(String result) {
  if (result.isEmpty) return '(empty)';
  final text = result.trimLeft();
  if (text.startsWith('{') || text.startsWith('[')) {
    try {
      return _fieldValue(jsonDecode(text));
    } on FormatException {
      return result;
    }
  }
  return result;
}

String _fieldLabel(String key) {
  if (key.isEmpty) return 'Value';
  if (key == 'model_id') return 'Model ID';
  final words = key.replaceAll('_', ' ');
  return words[0].toUpperCase() + words.substring(1);
}

String _fieldValue(Object? value) {
  if (value is Map) {
    return value.entries
        .map((entry) =>
            '${_fieldLabel(entry.key.toString())} — ${_fieldValue(entry.value)}')
        .join('\n');
  }
  if (value is List) {
    return value.map((item) => '• ${_fieldValue(item)}').join('\n');
  }
  if (value == null) return '—';
  if (value is bool) return value ? 'Yes' : 'No';
  return value.toString();
}

// ── Files the agent produced: ![alt](nmfile:name) and [📎 name](nmfile:name) ──

const nmFileScheme = 'nmfile:';

Future<File?> agentFile(String name) async {
  final dir = await Get.find<AgentService>().filesDir();
  final n = name.split('/').last.split('\\').last;
  final f = File('${dir.path}/$n');
  return await f.exists() ? f : null;
}

/// Inline image for `![alt](nmfile:name)`.
Widget agentImage(Uri uri, String? alt, {String? project}) {
  final name =
      Uri.decodeComponent(uri.toString().substring(nmFileScheme.length));
  return FutureBuilder<File?>(
    future: project == null
        ? agentFile(name)
        : Get.find<AgentService>().inProject(project, () => agentFile(name)),
    builder: (c, snap) {
      final f = snap.data;
      if (f == null)
        return Text(snap.connectionState == ConnectionState.done
            ? '[missing: $name]'
            : '');
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: GestureDetector(
          onTap: () => ImageViewer.showFile(c, f),
          child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.file(f, fit: BoxFit.contain, height: 320)),
        ),
      );
    },
  );
}

/// Opens a preview for a produced file.
Future<void> openAgentFile(BuildContext context, String name) async {
  final f = await agentFile(Uri.decodeComponent(name));
  if (f == null) {
    Get.snackbar('File not found', name);
    return;
  }
  if (!context.mounted) return;
  final ext = f.path.split('.').last.toLowerCase();
  if (_imageExts.contains(ext)) {
    await ImageViewer.showFile(context, f);
    return;
  }
  if (['wav', 'mp3', 'm4a', 'ogg', 'aac', 'flac'].contains(ext)) {
    await showModalBottomSheet(
        context: context, builder: (_) => _AudioSheet(file: f));
    return;
  }
  await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _FileSheet(file: f));
}

const _textExts = {
  'txt',
  'md',
  'csv',
  'tsv',
  'json',
  'html',
  'htm',
  'xml',
  'yaml',
  'yml',
  'log',
  'py',
  'js',
  'ts',
  'dart',
  'kt',
  'java',
  'c',
  'cpp',
  'h',
  'sh',
  'sql',
  'css',
  'ini',
  'toml',
  'conf',
  'srt',
  'vtt',
  'tex'
};
const _imageExts = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'};

/// Preview of a file the agent made, with copy, save to the phone, and share.
class _FileSheet extends StatefulWidget {
  final File file;
  const _FileSheet({required this.file});

  @override
  State<_FileSheet> createState() => _FileSheetState();
}

class _FileSheetState extends State<_FileSheet> {
  String? _text;
  bool _truncated = false;
  late final String _name = widget.file.path.split('/').last;
  late final String _ext =
      _name.contains('.') ? _name.split('.').last.toLowerCase() : '';

  @override
  void initState() {
    super.initState();
    if (_textExts.contains(_ext)) _load();
  }

  Future<void> _load() async {
    try {
      final bytes = await widget.file.readAsBytes();
      final cut = bytes.length > 60000;
      final t = utf8.decode(cut ? bytes.sublist(0, 60000) : bytes,
          allowMalformed: true);
      if (mounted)
        setState(() {
          _text = t;
          _truncated = cut;
        });
    } catch (e) {
      if (mounted) setState(() => _text = 'Could not read this file: $e');
    }
  }

  Future<void> _save() async {
    try {
      final bytes = await widget.file.readAsBytes();
      final path = await FilePicker.saveFile(
          dialogTitle: 'Save $_name', fileName: _name, bytes: bytes);
      if (path != null) Get.snackbar('Saved', _name);
    } catch (e) {
      Get.snackbar('Could not save', '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.file.lengthSync();
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.85),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_name,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 16)),
                Text(
                    '${(size / 1024).toStringAsFixed(size < 10240 ? 1 : 0)} KB',
                    style: TextStyle(
                        color: Theme.of(context).hintColor, fontSize: 12)),
                const SizedBox(height: 10),
                Flexible(
                  child: _text != null
                      ? Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                              color: Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest
                                  .withValues(alpha: 0.5),
                              borderRadius: BorderRadius.circular(12)),
                          child: SingleChildScrollView(
                              child: SelectableText(
                                  _truncated
                                      ? '$_text\n… (preview cut; save the file for everything)'
                                      : _text!,
                                  style: const TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 12.5,
                                      height: 1.45))))
                      : Padding(
                          padding: const EdgeInsets.symmetric(vertical: 24),
                          child: Text(_textExts.contains(_ext)
                              ? 'Loading…'
                              : 'No preview for .$_ext files. Save or share it instead.')),
                ),
                const SizedBox(height: 12),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  FilledButton.icon(
                      onPressed: _save,
                      icon: const Icon(Icons.download_rounded),
                      label: const Text('Save to phone')),
                  OutlinedButton.icon(
                      onPressed: () =>
                          Share.shareXFiles([XFile(widget.file.path)]),
                      icon: const Icon(Icons.ios_share_rounded),
                      label: const Text('Share')),
                  if (_text != null)
                    OutlinedButton.icon(
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: _text!));
                          Get.snackbar('Copied', _name);
                        },
                        icon: const Icon(Icons.copy_rounded),
                        label: const Text('Copy text')),
                ]),
              ]),
        ),
      ),
    );
  }
}

class _AudioSheet extends StatefulWidget {
  final File file;
  const _AudioSheet({required this.file});

  @override
  State<_AudioSheet> createState() => _AudioSheetState();
}

class _AudioSheetState extends State<_AudioSheet> {
  final _p = AudioPlayer();
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    _p.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _playing = false);
    });
  }

  @override
  void dispose() {
    _p.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_playing) {
      await _p.pause();
    } else {
      await _p.play(DeviceFileSource(widget.file.path));
    }
    if (mounted) setState(() => _playing = !_playing);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(widget.file.path.split('/').last,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            FilledButton.icon(
              onPressed: _toggle,
              icon: Icon(
                  _playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
              label: Text(_playing ? 'Pause' : 'Play'),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: () => Share.shareXFiles([XFile(widget.file.path)]),
              icon: const Icon(Icons.ios_share_rounded),
              label: const Text('Share / save'),
            ),
          ]),
        ]),
      ),
    );
  }
}

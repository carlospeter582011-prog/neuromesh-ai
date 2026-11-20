import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../controllers/settings_controller.dart';
import '../core/constants.dart';
import '../core/ui.dart';
import '../widgets/home_empty_state.dart' show providerLabel;
import '../services/inference_service.dart';
import '../services/hive_service.dart';
import '../services/update_service.dart';
import '../services/device_info_service.dart';
import '../services/device_info_native.dart' as platform_info;
import '../services/cluster_service.dart';
import 'cluster_view.dart';
import 'log_view.dart';
import 'toolbox_view.dart';
import '../core/haptics.dart';
import 'diagnostics_view.dart';
import 'memory_view.dart';
import 'workload_placement_view.dart';
import 'model_transfer_view.dart';
import 'pollinations_view.dart';

const _tabular = [FontFeature.tabularFigures()];

class SettingsView extends StatefulWidget {
  const SettingsView({super.key});

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  final _search = TextEditingController();
  String _query = '';
  SettingsController get controller => Get.find<SettingsController>();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  static const _keywords = <String, String>{
    'Appearance': 'theme dark light font text size',
    'Inference mode': 'local cloud ollama provider',
    'Model parameters':
        'thinking reasoning temperature context size max tokens seed stop sequences top p top k',
    'GGUF & LiteRT':
        'performance cpu gpu vulkan threads hardware acceleration ram',
    'Image generation': 'pollinations online image photo editing key',
    'Memory': 'preferences facts remember automatic learning personal',
    'Workload placement':
        'voice tts stt speech audio transcribe image device cluster',
    'Phone cluster': 'pair devices master worker server',
    'Report an error': 'diagnostics zip crash bug upload report delivery',
    'Device transfer':
        'move backup migrate restore chats models settings Wi-Fi',
    'Toolbox': 'backup export import files profiles roles prompts',
    'Device': 'free ram storage battery hardware',
    'App updates': 'version release upgrade',
  };

  List<Widget> _filter(List<Widget> sections) {
    if (_query.isEmpty) return sections;
    final terms = _query.split(RegExp(r'\s+'));
    final matches = <Widget>[];
    for (var i = 0; i < sections.length; i += 2) {
      final header = sections[i] as SectionHeader;
      final group = sections[i + 1] as AppGroup;
      final rows = group.children.whereType<AppRow>().where((row) {
        final text = '${header.title} ${row.title} ${row.subtitle ?? ''} '
            '${_keywords[row.title] ?? ''}';
        return terms.every(text.toLowerCase().contains);
      }).toList();
      if (rows.isNotEmpty) {
        matches.addAll([
          header,
          AppGroup(dividerIndent: group.dividerIndent, children: rows)
        ]);
      }
    }
    return matches;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Scaffold(
      backgroundColor: t.bg,
      appBar: appScreenBar(context, title: 'Settings'),
      body: Obx(() {
        final device = Get.find<DeviceInfoService>();
        final showUpdates =
            UpdateService.isSupported && Get.isRegistered<UpdateService>();
        final sections = _filter([
          const SectionHeader('Appearance & feedback',
              padding: EdgeInsets.fromLTRB(4, 8, 4, 8)),
          AppGroup(dividerIndent: 60, children: [
            _navRow(
              context,
              icon: Icons.palette_outlined,
              title: 'Appearance',
              value: _themeLabel(),
              builder: (ctx) => _buildAppearanceGroup(ctx),
            ),
            AppRow(
              icon: Icons.vibration_rounded,
              title: 'Haptic feedback',
              trailing: Switch(
                value: controller.hapticsEnabled.value,
                onChanged: controller.setHapticsEnabled,
              ),
              onTap: () => controller
                  .setHapticsEnabled(!controller.hapticsEnabled.value),
            ),
          ]),
          const SectionHeader('Chat & model defaults'),
          AppGroup(dividerIndent: 60, children: [
            AppRow(
              icon: Icons.psychology_alt_outlined,
              title: 'Memory',
              subtitle: 'Review saved facts and preferences',
              chevron: true,
              onTap: () => Get.to(() => const MemoryView()),
            ),
            _navRow(
              context,
              icon: Icons.memory_rounded,
              title: 'Inference mode',
              value:
                  controller.inferenceMode.value == 'local' ? 'Local' : 'Cloud',
              builder: (ctx) => _buildInferenceGroup(ctx),
            ),
            _navRow(
              context,
              icon: Icons.chat_bubble_outline_rounded,
              title: 'System prompt',
              value: controller.globalSystemPrompt.value.trim().isEmpty
                  ? 'Default'
                  : 'Custom',
              builder: (ctx) => _buildSystemPromptGroup(ctx),
              reactive: false,
            ),
            _navRow(
              context,
              icon: Icons.tune_rounded,
              title: 'Model parameters',
              value: controller.temperature.value.toStringAsFixed(2),
              builder: (ctx) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildModelParametersGroup(ctx),
                    const SectionHeader('Stop sequences'),
                    _buildStopSequencesGroup(ctx),
                  ]),
            ),
          ]),
          const SectionHeader('On-device performance'),
          AppGroup(dividerIndent: 60, children: [
            _navRow(
              context,
              icon: Icons.speed_rounded,
              title: 'GGUF & LiteRT',
              value: switch (controller.liteRtPerformanceMode.value) {
                'gpu_fast' => 'GPU fast',
                'cpu_safe' => 'CPU safe',
                _ => 'Auto fast',
              },
              builder: (ctx) => _buildLiteRtGroup(ctx),
            ),
            _navRow(
              context,
              icon: Icons.image_outlined,
              title: 'Image generation',
              value: 'Pollinations · Online',
              reactive: false,
              builder: (ctx) => const PollinationsPanel(),
            ),
          ]),
          const SectionHeader('Connected devices'),
          AppGroup(dividerIndent: 60, children: [
            if (Get.isRegistered<ClusterService>())
              AppRow(
                icon: Icons.hub_outlined,
                title: 'Phone cluster',
                trailing: Text(
                    switch (Get.find<ClusterService>().role) {
                      ClusterRole.master => 'Master',
                      ClusterRole.worker => 'Worker',
                      ClusterRole.off => 'Off',
                    },
                    style:
                        AppTokens.of(context).caption.copyWith(fontSize: 14)),
                chevron: true,
                onTap: () => Get.to(() => const ClusterView()),
              ),
            AppRow(
              icon: Icons.devices_other_rounded,
              title: 'Workload placement',
              subtitle: 'Choose phones for speech, recognition and images',
              chevron: true,
              onTap: () => Get.to(() => const WorkloadPlacementView()),
            ),
          ]),
          const SectionHeader('Utilities'),
          AppGroup(dividerIndent: 60, children: [
            AppRow(
              icon: Icons.handyman_outlined,
              title: 'Toolbox',
              subtitle: 'Roles, prompts, profiles, export, backup',
              chevron: true,
              onTap: () => Get.to(() => const ToolboxView()),
            ),
            AppRow(
              icon: Icons.swap_horiz_rounded,
              title: 'Device transfer',
              subtitle: 'Move models and app data over Wi-Fi',
              chevron: true,
              onTap: () =>
                  Get.to(() => const ModelTransferView(clusterBackup: true)),
            ),
          ]),
          const SectionHeader('Support & app info'),
          AppGroup(dividerIndent: 60, children: [
            if (showUpdates) _buildUpdatesRow(context),
            _navRow(
              context,
              icon: Icons.smartphone_rounded,
              title: 'Device',
              value: '${device.totalRamGB.value.toStringAsFixed(1)} GB RAM',
              builder: (ctx) => AppGroup(children: [_buildDeviceCard(ctx)]),
              reactive: false,
            ),
            AppRow(
              icon: Icons.bug_report_outlined,
              title: 'Report an error',
              chevron: true,
              onTap: () => Get.to(() => const DiagnosticsView()),
            ),
            AppRow(
              icon: Icons.article_outlined,
              title: 'Logs',
              chevron: true,
              onTap: () => Get.to(() => const LogView()),
            ),
            AppRow(
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.asset('assets/icons/appicon.png',
                    width: 32, height: 32),
              ),
              title: 'NeuroMesh AI',
              subtitle: controller.appVersion.value.isEmpty
                  ? 'Connect Devices. Multiply Intelligence.'
                  : 'Version ${controller.appVersion.value}',
            ),
          ]),
        ]);
        return ListView(
          padding: kPagePadding,
          children: [
            TextField(
              controller: _search,
              onChanged: (value) =>
                  setState(() => _query = value.trim().toLowerCase()),
              textInputAction: TextInputAction.search,
              decoration:
                  appInputDecoration(context, hint: 'Search settings').copyWith(
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear search',
                        onPressed: () {
                          _search.clear();
                          setState(() => _query = '');
                        },
                        icon: const Icon(Icons.close_rounded),
                      ),
              ),
            ),
            if (sections.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 36),
                child: Center(child: Text('No settings match your search.')),
              ),
            ...sections,
          ],
        );
      }),
    );
  }

  /// Row on the main page: icon, title, current value and a chevron that
  /// opens the section on its own page.
  Widget _navRow(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String value,
    required WidgetBuilder builder,
    bool reactive = true,
  }) {
    final t = AppTokens.of(context);
    return AppRow(
      icon: icon,
      title: title,
      trailing: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 140),
        child: Text(value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: t.caption.copyWith(fontSize: 14)),
      ),
      chevron: true,
      onTap: () => Get.to(() =>
          _SettingsPage(title: title, builder: builder, reactive: reactive)),
    );
  }

  String _themeLabel() => switch (controller.themeMode.value) {
        ThemeMode.light => 'Light',
        ThemeMode.dark => 'Dark',
        ThemeMode.system => 'System',
      };

  Widget _buildAppearanceGroup(BuildContext context) {
    final t = AppTokens.of(context);
    return AppGroup(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Theme', style: t.body),
          const SizedBox(height: 10),
          AppSegmented<ThemeMode>(
            items: const [
              (ThemeMode.light, 'Light'),
              (ThemeMode.dark, 'Dark'),
              (ThemeMode.system, 'System'),
            ],
            selected: controller.themeMode.value,
            onChanged: (mode) {
              if (mode != controller.themeMode.value) {
                controller.setThemeMode(mode);
              }
            },
          ),
        ]),
      ),
      _buildFontSizeRow(context),
    ]);
  }

  Widget _buildInferenceGroup(BuildContext context) {
    return AppGroup(dividerIndent: 60, children: [
      AppRow(
        icon: Icons.phone_iphone_rounded,
        title: 'Local (on-device)',
        subtitle: _localSubtitle(),
        selected: controller.inferenceMode.value == 'local',
        onTap: () => controller.setInferenceMode('local'),
      ),
      AppRow(
        icon: Icons.cloud_outlined,
        title: 'Cloud API',
        subtitle: providerLabel(controller),
        selected: controller.inferenceMode.value == 'cloud',
        onTap: () => controller.setInferenceMode('cloud'),
      ),
    ]);
  }

  Widget _buildSystemPromptGroup(BuildContext context) {
    final t = AppTokens.of(context);
    return Column(children: [
      TextField(
        controller: controller.globalSystemPromptController,
        minLines: 5,
        maxLines: 12,
        style: t.body,
        decoration:
            appInputDecoration(context, hint: AppConstants.systemPrompt),
        onSubmitted: (v) => controller.setGlobalSystemPrompt(v),
      ),
      _fieldFooter(
        context,
        note: 'Applies to local and cloud models.',
        onSave: () async {
          await controller.setGlobalSystemPrompt(
              controller.globalSystemPromptController.text);
          if (context.mounted) {
            _confirmSaved(context, 'System prompt saved');
          }
        },
      ),
    ]);
  }

  Widget _buildStopSequencesGroup(BuildContext context) {
    final t = AppTokens.of(context);
    return Column(children: [
      TextField(
        controller: controller.stopSequencesController,
        minLines: 2,
        maxLines: 5,
        style: t.mono.copyWith(fontSize: 13.5),
        decoration: appInputDecoration(context, hint: '###\n\\nUser:'),
      ),
      _fieldFooter(
        context,
        note: 'Local models stop when they write one of these. '
            'One per line; use \\n for a newline.',
        onSave: () async {
          await controller
              .setStopSequences(controller.stopSequencesController.text);
          if (context.mounted) {
            _confirmSaved(context, 'Stop sequences saved');
          }
        },
      ),
    ]);
  }

  Widget _buildUpdatesRow(BuildContext context) {
    final updates = Get.find<UpdateService>();
    final t = AppTokens.of(context);
    final update = updates.availableUpdate.value;
    final downloading = updates.state.value == UpdateState.downloading;
    return AppRow(
      icon: Icons.system_update_rounded,
      title: 'App updates',
      trailing: update != null
          ? AppTag(
              downloading
                  ? '${(updates.progress.value * 100).round()}%'
                  : '${update.version} available',
              color: t.accent)
          : Text('Up to date', style: t.caption.copyWith(fontSize: 14)),
      chevron: true,
      onTap: () => Get.to(() => _SettingsPage(
          title: 'App updates', builder: (ctx) => _buildUpdatesGroup(ctx))),
    );
  }

  Widget _buildUpdatesGroup(BuildContext context) {
    final updates = Get.find<UpdateService>();
    final update = updates.availableUpdate.value;
    final checking = updates.state.value == UpdateState.checking;
    final checked = updates.lastCheck.value;
    final current = updates.currentVersion.value;
    final String status;
    if (update != null) {
      status = 'You have $current · see what\'s new';
    } else if (checked != null) {
      status = 'Up to date · checked ${_ago(checked)}';
    } else {
      status = 'Not checked yet';
    }
    return AppGroup(dividerIndent: 60, children: [
      AppRow(
        icon: update != null ? Icons.download_rounded : Icons.refresh_rounded,
        title: update != null
            ? 'Update to ${update.version}'
            : 'Check for updates',
        subtitle: status,
        trailing: checking
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2))
            : null,
        chevron: !checking,
        onTap: checking
            ? null
            : () async {
                if (update != null) {
                  updates.showUpdateSheet(context);
                  return;
                }
                final found = await updates.checkForUpdate(manual: true);
                if (found != null && context.mounted) {
                  updates.showUpdateSheet(context);
                }
              },
      ),
      AppRow(
        icon: Icons.schedule_rounded,
        title: 'Check automatically',
        subtitle: 'Look for a new release once a day',
        trailing: Switch(
          value: updates.autoCheck.value,
          onChanged: updates.setAutoCheck,
        ),
        onTap: () => updates.setAutoCheck(!updates.autoCheck.value),
      ),
    ]);
  }

  static String _ago(DateTime time) {
    final d = DateTime.now().difference(time);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes}m ago';
    if (d.inDays < 1) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }

  // ── Building blocks ─────────────────────────────────────────────────────

  /// Note on the left, explicit Save on the right, under a text field.
  Widget _fieldFooter(BuildContext context,
      {required String note, required VoidCallback onSave}) {
    final t = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 0, 0),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(note, style: t.small),
          ),
        ),
        const SizedBox(width: 12),
        PillButton(label: 'Save', primary: true, onPressed: onSave),
      ]),
    );
  }

  void _confirmSaved(BuildContext context, String message) {
    FocusScope.of(context).unfocus();
    showToast('Saved', message, tone: ToastTone.success);
  }

  /// Consistent slider row: label left, value right, slider below, then an
  /// optional caption and trailing widget (e.g. a warning notice).
  Widget _sliderRow(
    BuildContext context, {
    required String label,
    required String valueLabel,
    required double value,
    required double min,
    required double max,
    int? divisions,
    required ValueChanged<double> onChanged,
    Color? color,
    String? caption,
    List<Widget> below = const [],
  }) {
    final t = AppTokens.of(context);
    final c = color ?? t.accent;
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            Expanded(child: Text(label, style: t.body)),
            const SizedBox(width: 12),
            Text(valueLabel,
                style: t.body.copyWith(
                    color: color ?? t.muted,
                    fontWeight: color != null ? FontWeight.w600 : null,
                    fontFeatures: _tabular)),
          ]),
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 4,
            activeTrackColor: c,
            inactiveTrackColor: t.fill,
            thumbColor: Colors.white,
            overlayColor: c.withValues(alpha: 0.12),
            trackShape: const RoundedRectSliderTrackShape(),
            thumbShape: const RoundSliderThumbShape(
                enabledThumbRadius: 10, elevation: 2),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
            tickMarkShape: SliderTickMarkShape.noTickMark,
            showValueIndicator: ShowValueIndicator.never,
          ),
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
        if (caption != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(caption, style: t.small),
          ),
        for (final w in below)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: w,
          ),
      ]),
    );
  }

  // ── Sections ────────────────────────────────────────────────────────────

  String _localSubtitle() {
    final inf = Get.find<InferenceService>();
    if (inf.isModelLoaded.value) {
      return 'Active: ${inf.loadedModelName.value}';
    }
    return 'No model loaded';
  }

  Widget _buildFontSizeRow(BuildContext context) {
    final t = AppTokens.of(context);
    const min = 0.8;
    const max = 1.4;
    final v = controller.fontScale.value;

    String scaleLabel(double v) {
      if (v <= 0.85) return 'XS';
      if (v <= 0.95) return 'Small';
      if (v <= 1.05) return 'Recommended';
      if (v <= 1.15) return 'Large';
      if (v <= 1.25) return 'XL';
      return 'XXL';
    }

    final isDefault = v >= 0.9 && v <= 0.95;
    Widget marker(String s, {bool on = false}) => Text(s,
        style: t.small.copyWith(
            fontSize: 11,
            color: on ? t.text : t.faint,
            fontWeight: on ? FontWeight.w600 : FontWeight.w400));

    return _sliderRow(
      context,
      label: 'Text size',
      valueLabel: scaleLabel(v),
      value: v,
      min: min,
      max: max,
      divisions: 12,
      onChanged: (v) => controller.setFontScale(v),
      below: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          marker('XS'),
          marker('Small (default)', on: isDefault),
          marker('Large'),
        ]),
      ],
    );
  }

  Widget _buildDeviceCard(BuildContext context) {
    return Obx(() {
      final t = AppTokens.of(context);
      final device = Get.find<DeviceInfoService>();
      final ram = device.totalRamGB.value.toStringAsFixed(1);
      final (String tierName, String tierHint) =
          switch (device.deviceTier.value) {
        'low' => ('Low RAM', 'Use small models only'),
        'mid' => ('Mid-range', 'Good for 1–3B models'),
        'high' => ('High-end', 'Can run 3–7B models'),
        'ultra' => ('Ultra', 'Full performance mode'),
        _ => ('', ''),
      };
      final isLow = device.deviceTier.value == 'low';

      final soc = device.socFamily.value;
      final quantWarning = soc.quantWarning;

      Widget kv(String k, String v, {Color? color}) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(children: [
              Text(k, style: t.caption.copyWith(fontSize: 14)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(v,
                    textAlign: TextAlign.right,
                    overflow: TextOverflow.ellipsis,
                    style: t.body.copyWith(
                        fontSize: 14,
                        color: color ?? t.text,
                        fontFeatures: _tabular)),
              ),
            ]),
          );

      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const IconBadge(Icons.smartphone_rounded),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('$ram GB RAM',
                        style: t.bodyStrong.copyWith(fontFeatures: _tabular)),
                    if (tierHint.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(tierHint, style: t.caption),
                    ],
                  ]),
            ),
            if (tierName.isNotEmpty) ...[
              const SizedBox(width: 10),
              AppTag(tierName, color: isLow ? t.orange : null),
            ],
          ]),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Container(height: 0.5, color: t.hairline),
          ),
          kv('Available memory',
              '${device.availableRamGB.value.toStringAsFixed(1)} GB'),
          kv('Recommended context', '${device.recommendedContextSize}'),
          kv('Recommended max tokens', '${device.recommendedMaxTokens}'),
          if (soc != platform_info.SocFamily.unknown) ...[
            kv('Chipset', soc.displayName),
            kv('Recommended quant', soc.recommendedQuant,
                color: quantWarning != null ? t.orange : null),
          ],
          if (quantWarning != null) ...[
            const SizedBox(height: 10),
            AppNotice(quantWarning,
                icon: Icons.warning_amber_rounded, color: t.orange),
          ],
        ]),
      );
    });
  }

  Widget _buildLiteRtGroup(BuildContext context) {
    final modes = [
      (
        value: 'auto_fast',
        title: 'Auto fast',
        subtitle:
            "Uses the GPU when supported, CPU if the GPU can't load the model",
        icon: Icons.auto_awesome_outlined
      ),
      (
        value: 'gpu_fast',
        title: 'GPU fast',
        subtitle: 'Always tries the GPU. Fastest, may crash on some devices',
        icon: Icons.bolt_rounded
      ),
      (
        value: 'cpu_safe',
        title: 'CPU safe',
        subtitle: 'CPU only. Most stable, slower',
        icon: Icons.shield_outlined
      ),
    ];
    final t = AppTokens.of(context);
    return AppGroup(dividerIndent: 60, children: [
      for (final m in modes)
        AppRow(
          icon: m.icon,
          title: m.title,
          subtitle: m.subtitle,
          selected: controller.liteRtPerformanceMode.value == m.value,
          onTap: () => controller.setLiteRtPerformanceMode(m.value),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: Text(
            'Applies to both GGUF and LiteRT models. Takes effect the next '
            'time a model is loaded.',
            style: t.small),
      ),
    ]);
  }

  Widget _buildModelParametersGroup(BuildContext context) {
    return AppGroup(children: [
      AppRow(
        icon: Icons.psychology_outlined,
        title: 'Local model thinking',
        subtitle: controller.normalThinking.value
            ? 'Think normally on supported models'
            : 'Answer directly on supported models',
        trailing: Switch(
          value: controller.normalThinking.value,
          onChanged: controller.setNormalThinking,
        ),
      ),
      _modelParameterSlider(
        context,
        label: 'Temperature',
        value: controller.temperature.value,
        min: 0.0,
        max: 2.0,
        divisions: 20,
        safeMax: 1.0,
        onChanged: (v) => controller.setTemperature(v),
        warning: 'High temperature = unpredictable output!',
      ),
      _modelParameterSlider(
        context,
        label: 'Max tokens',
        value: controller.maxTokens.value.toDouble(),
        min: 64,
        max: 4096,
        divisions: 63,
        safeMax: Get.find<DeviceInfoService>().maxSafeTokens.toDouble(),
        onChanged: (v) => controller.setMaxTokens(v.toInt()),
        displayValue: controller.maxTokens.value.toString(),
        warning: 'Your phone may crash with this value!',
      ),
      (() {
        final inference = Get.find<InferenceService>();
        final savedRuntime = Get.find<HiveService>()
                .getSetting<String>(AppConstants.keyLocalModelRuntime) ??
            '';
        final isLiteRtActive = (inference.isModelLoaded.value &&
                inference.loadedModelRuntime.value == 'litert') ||
            (!inference.isModelLoaded.value &&
                savedRuntime.toLowerCase() == 'litert');
        final maxContext = isLiteRtActive ? 4096.0 : 8192.0;
        final divisions = isLiteRtActive ? 7 : 15;
        final currentValue =
            controller.contextSize.value.toDouble().clamp(512.0, maxContext);

        if (currentValue != controller.contextSize.value.toDouble()) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            controller.setContextSize(currentValue.toInt());
          });
        }

        return _modelParameterSlider(
          context,
          label: 'Context size',
          value: currentValue,
          min: 512,
          max: maxContext,
          divisions: divisions,
          safeMax: Get.find<DeviceInfoService>().maxSafeContextSize.toDouble(),
          onChanged: (v) => controller.setContextSize(v.toInt()),
          displayValue: currentValue.toInt().toString(),
          warning: isLiteRtActive
              ? 'Context capped at 4096 to prevent driver memory crash for LiteRT models.'
              : 'Context this large will eat all your RAM!',
        );
      })(),
    ]);
  }

  Widget _modelParameterSlider(
    BuildContext context, {
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required double safeMax,
    required ValueChanged<double> onChanged,
    required String warning,
    String? displayValue,
  }) {
    final t = AppTokens.of(context);
    final isOver = value > safeMax;
    final danger = safeMax < max
        ? ((value - safeMax) / (max - safeMax)).clamp(0.0, 1.0)
        : 0.0;
    final warnColor = isOver ? Color.lerp(t.orange, t.red, danger)! : null;

    return _sliderRow(
      context,
      label: label,
      valueLabel: displayValue ?? value.toStringAsFixed(2),
      value: value,
      min: min,
      max: max,
      divisions: divisions,
      color: warnColor,
      caption: safeMax < max
          ? 'Recommended max: ${safeMax.toInt() > 0 ? safeMax.toInt().toString() : safeMax.toStringAsFixed(1)}'
          : null,
      onChanged: (v) {
        if (v > safeMax && value <= safeMax) {
          Haptics.heavyImpact();
          showToast('Above recommended', warning, tone: ToastTone.warning);
        } else if (v > safeMax) {
          Haptics.mediumImpact();
        }
        onChanged(v);
      },
      below: [
        if (isOver)
          AppNotice(warning,
              icon: Icons.warning_amber_rounded, color: warnColor),
      ],
    );
  }
}

class _SettingsPage extends StatelessWidget {
  final String title;
  final WidgetBuilder builder;

  /// Rebuild on controller changes. Off for pages that read no observables
  /// (or manage their own Obx), which GetX would otherwise reject.
  final bool reactive;
  const _SettingsPage(
      {required this.title, required this.builder, this.reactive = true});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Scaffold(
      backgroundColor: t.bg,
      appBar: appScreenBar(context, title: title, showBack: true),
      body: reactive ? Obx(() => _list(context)) : _list(context),
    );
  }

  Widget _list(BuildContext context) => ListView(
        padding: kPagePadding,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        children: [const SizedBox(height: 8), builder(context)],
      );
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import '../controllers/home_controller.dart';
import '../services/opencode_adapter.dart';
import '../services/android_opencode.dart';
import 'android_agent_hub_view.dart';
import '../widgets/chat_drawer.dart';
import 'agent_hub_view.dart';
import 'chat_view.dart';
import 'model_view.dart';
import 'server_view.dart';
import 'settings_view.dart';
import '../core/haptics.dart';

final homeRouteObserver = RouteObserver<PageRoute<dynamic>>();

class HomeView extends StatefulWidget {
  const HomeView({super.key});

  @override
  State<HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends State<HomeView> with RouteAware {
  final controller = Get.find<HomeController>();
  bool _exitDialogOpen = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute<dynamic>) homeRouteObserver.subscribe(this, route);
  }

  @override
  void didPopNext() {
    if (controller.currentTab.value == 1) controller.modelsToTop();
  }

  @override
  void dispose() {
    homeRouteObserver.unsubscribe(this);
    super.dispose();
  }

  Future<void> _back() async {
    if (_exitDialogOpen || controller.goBack()) return;
    _exitDialogOpen = true;
    try {
      final exit = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Exit NeuroMesh AI?'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Stay')),
            TextButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Exit')),
          ],
        ),
      );
      if (exit == true && mounted) await SystemNavigator.pop();
    } finally {
      _exitDialogOpen = false;
    }
  }

  static const _tabs = [
    _NavItem(
        icon: Icons.chat_bubble_outline_rounded,
        activeIcon: Icons.chat_bubble_rounded,
        label: 'Chat'),
    _NavItem(
        icon: Icons.layers_outlined,
        activeIcon: Icons.layers_rounded,
        label: 'Models'),
    _NavItem(
        icon: Icons.lan_outlined,
        activeIcon: Icons.lan_rounded,
        label: 'Server'),
    _NavItem(
        icon: Icons.settings_outlined,
        activeIcon: Icons.settings,
        label: 'Settings'),
  ];

  List<_NavItem> _navigationItems(BuildContext context) => [
        ..._tabs,
        if (hasDesktopAgents || showAndroidAgentHub)
          _NavItem(
            icon: Icons.terminal_outlined,
            activeIcon: Icons.terminal_rounded,
            label: agentHubUsesArabic(context) ? 'الوكلاء' : 'Agents',
          ),
      ];

  bool get _isWide {
    // Force bottom navbar for all layouts per user request
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _back();
        },
        child: Obx(() => Scaffold(
              key: controller.scaffoldKey,
              backgroundColor: isDark ? Colors.black : Colors.white,
              drawer: const ChatDrawer(),
              drawerScrimColor:
                  Colors.black.withValues(alpha: isDark ? 0.6 : 0.32),
              // Edge-swipe only where the sidebar makes sense.
              drawerEnableOpenDragGesture: controller.currentTab.value == 0,
              drawerEdgeDragWidth: 28,
              body: Obx(() {
                final content = IndexedStack(
                  index: controller.currentTab.value,
                  children: [
                    const ChatView(),
                    const ModelView(),
                    const ServerView(),
                    const SettingsView(),
                    if (hasDesktopAgents) const AgentHubView(),
                    if (showAndroidAgentHub) const AndroidAgentHubView(),
                  ],
                );
                if (_isWide) {
                  return Row(children: [
                    _buildSidebar(context, isDark),
                    VerticalDivider(
                        width: 0.5,
                        thickness: 0.5,
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.08)
                            : Colors.black.withValues(alpha: 0.08)),
                    Expanded(child: content),
                  ]);
                }
                return content;
              }),
              bottomNavigationBar:
                  _isWide ? null : _buildBottomNav(context, isDark),
            )));
  }

  Widget _buildBottomNav(BuildContext context, bool isDark) {
    final accent = isDark ? const Color(0xFF0A84FF) : const Color(0xFF007AFF);
    final muted = isDark ? const Color(0xFF7C7C80) : const Color(0xFF8E8E93);
    final current = controller.currentTab.value;
    final tabs = _navigationItems(context);
    return Container(
      decoration: BoxDecoration(
        color: isDark ? Colors.black : Colors.white,
        border: Border(
            top: BorderSide(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : Colors.black.withValues(alpha: 0.08),
          width: 0.5,
        )),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 54,
          child: Row(children: [
            for (var i = 0; i < tabs.length; i++)
              Expanded(
                child: Semantics(
                  selected: current == i,
                  button: true,
                  label: tabs[i].label,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      if (current != i) Haptics.selectionClick();
                      controller.changeTab(i);
                    },
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 160),
                          child: Icon(
                            current == i ? tabs[i].activeIcon : tabs[i].icon,
                            key: ValueKey(current == i),
                            size: 23,
                            color: current == i ? accent : muted,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(tabs[i].label,
                            style: GoogleFonts.inter(
                                fontSize: 10.5,
                                letterSpacing: 0.1,
                                fontWeight: current == i
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                                color: current == i ? accent : muted)),
                      ],
                    ),
                  ),
                ),
              ),
          ]),
        ),
      ),
    );
  }

  Widget _buildSidebar(BuildContext context, bool isDark) {
    final accent = isDark ? const Color(0xFF0A84FF) : const Color(0xFF007AFF);
    final muted = Theme.of(context).hintColor;
    final tabs = _navigationItems(context);

    return Container(
      width: 76,
      color: isDark ? Colors.black : Colors.white,
      child: Column(children: [
        // const SizedBox(height: 20),
        // Image.asset(
        //   'assets/icons/appicon.png',
        //   width: 40,
        //   height: 40,
        // ),
        // const SizedBox(height: 20),
        Expanded(child: Obx(() {
          final current = controller.currentTab.value;
          return ListView.builder(
            itemCount: tabs.length,
            itemBuilder: (_, i) {
              final tab = tabs[i];
              final sel = current == i;
              return Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                child: Material(
                  color:
                      sel ? accent.withValues(alpha: 0.12) : Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => controller.changeTab(i),
                    child: SizedBox(
                      height: 52,
                      child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(sel ? tab.activeIcon : tab.icon,
                                color: sel ? accent : muted, size: 20),
                            const SizedBox(height: 3),
                            Text(tab.label,
                                style: GoogleFonts.inter(
                                    fontSize: 10,
                                    fontWeight:
                                        sel ? FontWeight.w600 : FontWeight.w400,
                                    color: sel ? accent : muted)),
                          ]),
                    ),
                  ),
                ),
              );
            },
          );
        })),
        const SizedBox(height: 16),
      ]),
    );
  }
}

class _NavItem {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  const _NavItem(
      {required this.icon, required this.activeIcon, required this.label});
}

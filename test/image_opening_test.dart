import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive/hive.dart';
import 'package:neuromesh_ai/controllers/settings_controller.dart';
import 'package:neuromesh_ai/services/agent_service.dart';
import 'package:neuromesh_ai/services/device_info_service.dart';
import 'package:neuromesh_ai/services/hive_service.dart';
import 'package:neuromesh_ai/services/inference_service.dart';
import 'package:neuromesh_ai/views/settings_view.dart';
import 'package:neuromesh_ai/widgets/agent_steps.dart';
import 'package:neuromesh_ai/widgets/image_viewer.dart';

class _ImageAgent extends AgentService {
  _ImageAgent(this.directory);

  final Directory directory;

  @override
  Future<Directory> filesDir() async => directory;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  late Directory directory;

  setUp(() async {
    Get.testMode = true;
    directory = await Directory.systemTemp.createTemp('image_opening_');
    Hive.init(directory.path);
    Get.put(await HiveService().init());
  });

  tearDown(() async {
    Get.reset();
    await Hive.close();
    await directory.delete(recursive: true);
  });

  testWidgets('Image generation settings show the Pollinations controls',
      (tester) async {
    Get.put(SettingsController());
    Get.put(DeviceInfoService());
    Get.put(InferenceService());

    await tester.pumpWidget(const GetMaterialApp(home: SettingsView()));
    await tester.enterText(find.byType(TextField), 'image generation');
    await tester.pumpAndSettle();
    final row = find.text('Image generation');
    await tester.tap(row);
    await tester.pumpAndSettle();

    expect(find.text('Pollinations'), findsOneWidget);
    expect(find.text('Save key'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping a generated image opens a zoomable preview with Share',
      (tester) async {
    final file = File('${directory.path}/generated.png');
    file.writeAsBytesSync(base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAFElEQVR4nGNUnPaVARtgwio6aCUAUUsBvA6J8zUAAAAASUVORK5CYII=',
    ));
    Get.put<AgentService>(_ImageAgent(directory));

    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              child: agentImage(
                  Uri.parse('nmfile:generated.png'), 'Generated image'),
            ),
          ),
        ),
      ));
      await precacheImage(
          FileImage(file), tester.element(find.byType(Scaffold)));
    });
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Image));
    await tester.pumpAndSettle();

    expect(find.byType(ImageViewer), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.byTooltip('Share'), findsOneWidget);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewer), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

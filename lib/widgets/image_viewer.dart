import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/ui.dart';

class ImageViewer extends StatefulWidget {
  final String? base64Image;
  final File? file;

  const ImageViewer._({this.base64Image, this.file});

  static Future<void> show(BuildContext context, String base64Image) =>
      _show(context, ImageViewer._(base64Image: base64Image));

  static Future<void> showFile(BuildContext context, File file) =>
      _show(context, ImageViewer._(file: file));

  static Future<void> _show(BuildContext context, ImageViewer viewer) {
    return showDialog(
      context: context,
      useSafeArea: false,
      barrierDismissible: true,
      barrierColor: Colors.black,
      builder: (_) => viewer,
    );
  }

  @override
  State<ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<ImageViewer> {
  late final Uint8List? _bytes;
  bool _isSaving = false;
  bool _isSharing = false;

  @override
  void initState() {
    super.initState();
    try {
      _bytes =
          widget.base64Image == null ? null : base64Decode(widget.base64Image!);
    } on FormatException {
      _bytes = null;
    }
  }

  Future<void> _download() async {
    setState(() => _isSaving = true);
    try {
      // Request permission if needed
      final hasAccess = await Gal.hasAccess();
      if (!hasAccess) {
        await Gal.requestAccess();
      }
      if (widget.file case final file?) {
        await Gal.putImage(file.path);
      } else {
        await Gal.putImageBytes(_bytes!);
      }
      if (mounted) {
        showToast('Saved', 'Image saved to gallery',
            tone: ToastTone.success, duration: const Duration(seconds: 2));
      }
    } on GalException catch (e) {
      if (mounted) {
        showToast('Not saved', 'Failed to save image: ${e.type.message}',
            tone: ToastTone.error);
      }
    } catch (e) {
      if (mounted) {
        showToast('Not saved', 'Error saving image: $e', tone: ToastTone.error);
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _share() async {
    setState(() => _isSharing = true);
    try {
      var file = widget.file;
      if (file == null) {
        final tempDir = await getTemporaryDirectory();
        final name = 'neuromesh_${DateTime.now().millisecondsSinceEpoch}.png';
        file = await File('${tempDir.path}/$name').writeAsBytes(_bytes!);
      }
      await Share.shareXFiles([XFile(file.path)]);
    } catch (e) {
      if (mounted) {
        showToast('Not shared', 'Error sharing image: $e',
            tone: ToastTone.error);
      }
    } finally {
      if (mounted) setState(() => _isSharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ImageProvider<Object>? image;
    if (widget.file case final file?) {
      image = FileImage(file);
    } else if (_bytes case final bytes?) {
      image = MemoryImage(bytes);
    } else {
      image = null;
    }
    const unavailable = Text('Couldn’t open this image.',
        style: TextStyle(color: Colors.white70));
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Image with zoom/pan
          InteractiveViewer(
            minScale: 0.5,
            maxScale: 5.0,
            child: Center(
              child: image == null
                  ? unavailable
                  : Image(
                      image: image,
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => unavailable,
                    ),
            ),
          ),

          // Minimal top chrome: close on the left, save / share on the right.
          SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Row(
                  children: [
                    _ChromeButton(
                      icon: Icons.close_rounded,
                      tooltip: 'Close',
                      onTap: () => Navigator.of(context).pop(),
                    ),
                    const Spacer(),
                    if (image != null) ...[
                      _ChromeButton(
                        icon: Icons.file_download_outlined,
                        tooltip: 'Download',
                        isLoading: _isSaving,
                        onTap: _download,
                      ),
                      const SizedBox(width: 10),
                      _ChromeButton(
                        icon: Icons.ios_share_rounded,
                        tooltip: 'Share',
                        isLoading: _isSharing,
                        onTap: _share,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Small white icon on a subtle dark circle — floats over any image.
class _ChromeButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool isLoading;
  final VoidCallback onTap;

  const _ChromeButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.isLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.white.withValues(alpha: 0.12),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: isLoading ? null : onTap,
          child: SizedBox(
            width: 40,
            height: 40,
            child: Center(
              child: isLoading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Icon(icon, color: Colors.white, size: 21),
            ),
          ),
        ),
      ),
    );
  }
}

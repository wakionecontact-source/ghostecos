import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../theme.dart';

/// Небольшой нативный экран камеры Ghost вместо системного intent камеры.
/// Возвращает снятый файл, а отправку выполняет вызывающий чат/список.
class GhostCameraScreen extends StatefulWidget {
  const GhostCameraScreen({super.key});

  @override
  State<GhostCameraScreen> createState() => _GhostCameraScreenState();
}

class _GhostCameraScreenState extends State<GhostCameraScreen> {
  CameraController? _controller;
  String? _error;
  bool _busy = false;
  FlashMode _flash = FlashMode.off;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) throw StateError('Камера не найдена');
      final back = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        back,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await controller.initialize();
      await controller.setFlashMode(_flash);
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _controller = controller);
    } catch (e) {
      if (mounted) setState(() => _error = 'Камера недоступна: $e');
    }
  }

  Future<void> _toggleFlash() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final next = _flash == FlashMode.off ? FlashMode.auto : FlashMode.off;
    await controller.setFlashMode(next);
    if (mounted) setState(() => _flash = next);
  }

  Future<void> _takePhoto() async {
    final controller = _controller;
    if (_busy || controller == null || !controller.value.isInitialized) return;
    setState(() => _busy = true);
    try {
      final shot = await controller.takePicture();
      if (!mounted) return;
      Navigator.of(context).pop(File(shot.path));
    } catch (e) {
      if (mounted) setState(() => _error = 'Не удалось сделать фото: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      backgroundColor: GE.shadow,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (controller != null && controller.value.isInitialized)
              Center(child: CameraPreview(controller))
            else
              Center(
                child: _error == null
                    ? const CircularProgressIndicator(color: GE.text)
                    : Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: GE.text),
                        ),
                      ),
              ),
            Positioned(
              top: 8,
              left: 8,
              right: 8,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _controlButton(
                    CupertinoIcons.xmark,
                    () => Navigator.of(context).maybePop(),
                  ),
                  _controlButton(
                    _flash == FlashMode.off
                        ? CupertinoIcons.bolt_slash
                        : CupertinoIcons.bolt_fill,
                    _toggleFlash,
                  ),
                ],
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 20,
              child: Center(
                child: GestureDetector(
                  onTap: _takePhoto,
                  child: Container(
                    width: 76,
                    height: 76,
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: GE.text, width: 3),
                    ),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: _busy ? GE.sub : GE.text,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _controlButton(IconData icon, VoidCallback onTap) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: GE.shadow.withValues(alpha: 0.45),
        shape: BoxShape.circle,
      ),
      child: IconButton(
        onPressed: onTap,
        icon: Icon(icon, color: GE.text),
      ),
    );
  }
}

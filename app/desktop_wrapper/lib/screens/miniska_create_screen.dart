// MiniskaCreateScreen — записать/выбрать видео + caption + публикация.
// Endpoints: POST /upload (file → {url, type}), POST /miniska/new {caption, video_url}
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import '../theme.dart';
import '../services/api_client.dart';
import '../widgets/glass.dart';

class MiniskaCreateScreen extends StatefulWidget {
  const MiniskaCreateScreen({super.key});
  @override
  State<MiniskaCreateScreen> createState() => _MiniskaCreateScreenState();
}

class _MiniskaCreateScreenState extends State<MiniskaCreateScreen> {
  final _api = ApiClient();
  final _captionCtrl = TextEditingController();
  final _picker = ImagePicker();
  String? _videoUrl;
  String? _videoName;
  bool _uploading = false;
  bool _publishing = false;
  String? _error;

  Future<void> _pickFromGallery() async => _pickVideo(ImageSource.gallery);
  Future<void> _pickFromCamera() async => _pickVideo(ImageSource.camera);

  Future<void> _pickVideo(ImageSource src) async {
    try {
      final x = await _picker.pickVideo(
        source: src,
        maxDuration: const Duration(seconds: 30),
      );
      if (x == null) return;
      setState(() {
        _uploading = true;
        _error = null;
      });
      final bytes = await x.readAsBytes();
      final mime = x.name.endsWith('.webm') ? 'video/webm' : 'video/mp4';
      final r = await _api.uploadSocFile(
          bytes: bytes, filename: x.name, mime: mime);
      if (!mounted) return;
      final url = r['url'] as String?;
      if (url == null) throw Exception('Сервер не вернул URL');
      setState(() {
        _videoUrl = url;
        _videoName = x.name;
        _uploading = false;
      });
      HapticFeedback.lightImpact();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _error = 'Не загрузилось: $e';
      });
    }
  }

  Future<void> _publish() async {
    if (_videoUrl == null || _publishing) return;
    setState(() => _publishing = true);
    try {
      await _api.socPost('/miniska/new', {
        'caption': _captionCtrl.text.trim(),
        'video_url': _videoUrl,
      });
      if (!mounted) return;
      Navigator.pop(context, true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Миниска опубликована')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _publishing = false;
        _error = 'Не опубликовалось: $e';
      });
    }
  }

  @override
  void dispose() {
    _captionCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      resizeToAvoidBottomInset: true,
      appBar: GlassAppBar(showBack: true, titleText: 'Новая миниска'),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            GlassCard(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  if (_videoUrl == null) ...[
                    Icon(Icons.movie_outlined, color: GE.sub, size: 48),
                    const SizedBox(height: 8),
                    Text('Видео до 30 секунд',
                        style: TextStyle(
                            color: GE.text,
                            fontWeight: FontWeight.w600,
                            fontSize: 14)),
                    Text('Камера или галерея',
                        style: TextStyle(color: GE.sub, fontSize: 12)),
                    const SizedBox(height: 16),
                    Row(children: [
                      Expanded(
                        child: GlassButton(
                          label: 'Камера',
                          icon: Icons.videocam,
                          primary: true,
                          loading: _uploading,
                          onTap: _uploading ? null : _pickFromCamera,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: GlassButton(
                          label: 'Галерея',
                          icon: Icons.photo_library,
                          loading: _uploading,
                          onTap: _uploading ? null : _pickFromGallery,
                        ),
                      ),
                    ]),
                  ] else ...[
                    Container(
                      height: 200,
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.play_circle_fill,
                              color: Colors.white70, size: 56),
                          const SizedBox(height: 6),
                          Text(_videoName ?? 'video',
                              style: TextStyle(color: GE.sub, fontSize: 11)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextButton.icon(
                      icon: Icon(Icons.refresh, color: GE.primary, size: 16),
                      label: const Text('Выбрать другое'),
                      onPressed: _uploading
                          ? null
                          : () => setState(() {
                                _videoUrl = null;
                                _videoName = null;
                              }),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            GlassCard(
              padding: const EdgeInsets.all(12),
              child: TextField(
                controller: _captionCtrl,
                maxLines: 3,
                minLines: 2,
                maxLength: 200,
                style: TextStyle(color: GE.text),
                cursorColor: GE.primary,
                decoration: InputDecoration(
                  hintText: 'Подпись (опционально)',
                  hintStyle: TextStyle(color: GE.sub),
                  border: InputBorder.none,
                  counterStyle: TextStyle(color: GE.sub, fontSize: 10),
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: GE.red.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: GE.red.withValues(alpha: 0.4)),
                ),
                child: Row(children: [
                  Icon(Icons.error_outline, color: GE.red, size: 16),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(_error!,
                        style: TextStyle(color: GE.red, fontSize: 12)),
                  ),
                ]),
              ),
            ],
            const SizedBox(height: 16),
            GlassButton(
              label: 'Опубликовать',
              icon: Icons.send,
              primary: true,
              fullWidth: true,
              loading: _publishing,
              onTap: (_videoUrl == null || _publishing) ? null : _publish,
            ),
          ],
        ),
      ),
    );
  }
}

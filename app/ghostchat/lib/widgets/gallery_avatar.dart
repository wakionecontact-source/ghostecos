import 'package:flutter/cupertino.dart';

import '../theme.dart';

/// Аватарка расширения: сетевая картинка с мягким фолбэком-иконкой.
class GalleryAvatar extends StatelessWidget {
  const GalleryAvatar({
    super.key,
    this.url,
    this.size = 56,
    this.iconSize,
  });

  /// Абсолютный URL или путь от корня (`/api/gallery/v1/...`).
  final String? url;
  final double size;
  final double? iconSize;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(size * 0.30);
    final resolved = url == null
        ? null
        : (url!.startsWith('http') ? url! : '${GE.baseUrl}$url');
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: GE.surfaceElevated,
        borderRadius: radius,
        border: Border.all(color: GE.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: resolved == null
          ? Center(
              child: Icon(
                CupertinoIcons.paintbrush_fill,
                color: GE.primary,
                size: iconSize ?? size * 0.42,
              ),
            )
          : Image.network(
              resolved,
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => Center(
                child: Icon(
                  CupertinoIcons.paintbrush_fill,
                  color: GE.muted,
                  size: iconSize ?? size * 0.42,
                ),
              ),
            ),
    );
  }
}

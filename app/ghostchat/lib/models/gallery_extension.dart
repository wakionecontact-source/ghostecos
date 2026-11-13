/// Расширение GhostGallery, как его отдаёт `/api/gallery/v1`.
class GalleryExtension {
  const GalleryExtension({
    required this.id,
    required this.name,
    required this.description,
    required this.author,
    required this.authorId,
    required this.version,
    required this.sizeBytes,
    required this.isDefault,
    required this.avatarUrl,
    required this.fileUrl,
    required this.manifest,
    required this.signature,
  });

  final String id;
  final String name;
  final String description;
  final String author;
  final int authorId;
  final String version;
  final int sizeBytes;
  final bool isDefault;

  /// Относительный путь (`/api/gallery/v1/...`) или null.
  final String? avatarUrl;
  final String fileUrl;

  /// Заполняется только карточкой `/extensions/{id}`.
  final Map<String, dynamic> manifest;
  final String signature;

  bool get hasSignature => signature.isNotEmpty && manifest.isNotEmpty;

  factory GalleryExtension.fromJson(Map<String, dynamic> json) {
    Map<String, dynamic> manifest = const <String, dynamic>{};
    final rawManifest = json['manifest'];
    if (rawManifest is Map) {
      manifest = Map<String, dynamic>.from(rawManifest);
    }
    final rawAvatar = json['avatar_url'];
    return GalleryExtension(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      description: (json['description'] ?? '').toString(),
      author: (json['author'] ?? '').toString(),
      authorId: (json['author_id'] as num?)?.toInt() ?? 0,
      version: (json['version'] ?? '1.0.0').toString(),
      sizeBytes: (json['size_bytes'] as num?)?.toInt() ?? 0,
      isDefault: json['is_default'] == true,
      avatarUrl: rawAvatar is String && rawAvatar.isNotEmpty ? rawAvatar : null,
      fileUrl: (json['file_url'] ?? '').toString(),
      manifest: manifest,
      signature: (json['signature'] ?? '').toString(),
    );
  }

  String get sizeLabel {
    if (sizeBytes <= 0) return '—';
    if (sizeBytes < 1024) return '$sizeBytes Б';
    final kb = sizeBytes / 1024;
    if (kb < 1024) {
      return '${kb.toStringAsFixed(kb < 10 ? 1 : 0)} КБ';
    }
    return '${(kb / 1024).toStringAsFixed(1)} МБ';
  }
}

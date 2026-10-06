/// A small author-defined action attached to a chat message.
///
/// Text actions send their visible label as a regular chat message only after
/// the recipient taps them. Link actions open an HTTPS page through the
/// app-wide external-link confirmation boundary.
enum MessageButtonKind { text, link }

class MessageButton {
  final MessageButtonKind kind;
  final String label;
  final String? url;

  const MessageButton._({required this.kind, required this.label, this.url});

  factory MessageButton.text(String text) =>
      MessageButton._(kind: MessageButtonKind.text, label: text.trim());

  factory MessageButton.link({required String label, required String url}) =>
      MessageButton._(
        kind: MessageButtonKind.link,
        label: label.trim(),
        url: url.trim(),
      );

  bool get isValid {
    if (label.isEmpty || label.length > 80) return false;
    if (kind == MessageButtonKind.text) return url == null;
    final target = url?.trim() ?? '';
    if (target.isEmpty || target.length > 4096) return false;
    final value = target.contains('://') ? target : 'https://$target';
    final uri = Uri.tryParse(value);
    return uri != null &&
        uri.scheme.toLowerCase() == 'https' &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty;
  }

  Map<String, dynamic> toJson() => {
    'type': kind.name,
    'label': label,
    if (url != null) 'url': url,
  };

  static const maxCount = 8;

  static MessageButton? tryParse(Object? value) {
    if (value is! Map) return null;
    final map = Map<String, dynamic>.from(value);
    final label = map['label']?.toString().trim() ?? '';
    switch (map['type']?.toString()) {
      case 'text':
        final button = MessageButton.text(label);
        return button.isValid ? button : null;
      case 'link':
        final button = MessageButton.link(
          label: label,
          url: map['url']?.toString() ?? '',
        );
        return button.isValid ? button : null;
      default:
        return null;
    }
  }

  static List<MessageButton> parseList(Object? value) {
    if (value is! List) return const [];
    return value
        .take(maxCount)
        .map(tryParse)
        .whereType<MessageButton>()
        .toList(growable: false);
  }

  static List<Map<String, dynamic>> encodeList(Iterable<MessageButton> value) =>
      value
          .where((button) => button.isValid)
          .take(maxCount)
          .map((button) => button.toJson())
          .toList(growable: false);

  @override
  bool operator ==(Object other) =>
      other is MessageButton &&
      other.kind == kind &&
      other.label == label &&
      other.url == url;

  @override
  int get hashCode => Object.hash(kind, label, url);
}

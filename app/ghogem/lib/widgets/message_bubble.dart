import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:open_filex/open_filex.dart';
import '../theme.dart';

String _formatBytes(int bytes){
  if (bytes < 1024) return '$bytes Б';
  if (bytes < 1024*1024) return '${(bytes/1024).toStringAsFixed(1)} КБ';
  return '${(bytes/1024/1024).toStringAsFixed(1)} МБ';
}

class ThinkingBlock extends StatefulWidget {
  final String text;
  final bool initiallyExpanded;
  const ThinkingBlock({super.key, required this.text, this.initiallyExpanded=false});
  @override State<ThinkingBlock> createState()=>_ThinkingBlockState();
}

class _ThinkingBlockState extends State<ThinkingBlock> {
  late bool _expanded = widget.initiallyExpanded;
  @override void didUpdateWidget(ThinkingBlock old){
    super.didUpdateWidget(old);
    if (widget.initiallyExpanded != old.initiallyExpanded) _expanded = widget.initiallyExpanded;
  }
  @override Widget build(BuildContext context){
    if (widget.text.trim().isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(color: GG.bgCard, borderRadius: BorderRadius.circular(10)),
      child: Column(children: [
        InkWell(
          onTap: ()=>setState(()=>_expanded=!_expanded),
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(children: [
              Icon(_expanded ? Icons.expand_less : Icons.expand_more, size: 16, color: GG.iris),
              const SizedBox(width: 6),
              Text('Размышления', style: TextStyle(color: GG.iris, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.8)),
              const Spacer(),
              Text(_expanded ? 'свернуть' : 'развернуть', style: TextStyle(color: GG.faint, fontSize: 10)),
            ]),
          ),
        ),
        if (_expanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: SelectableText(widget.text, style: TextStyle(color: GG.muted, fontSize: 12, height: 1.45, fontStyle: FontStyle.italic)),
          ),
      ]),
    );
  }
}

// Beautiful attachment views
class AttachmentView extends StatelessWidget {
  final List<Map<String,dynamic>> attachments;
  const AttachmentView({super.key, required this.attachments});

  @override Widget build(BuildContext context){
    if (attachments.isEmpty) return const SizedBox.shrink();
    final images = attachments.where((a)=> (a['isImage'] as bool? ?? false) || (a['mime'] as String? ?? '').startsWith('image/')).toList();
    final videos = attachments.where((a)=> a['isVideo']==true).toList();
    final audios = attachments.where((a)=> a['isAudio']==true).toList();
    final files = attachments.where((a)=> !(a['isImage']==true) && a['isVideo']!=true && a['isAudio']!=true).toList();

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (images.isNotEmpty) _ImageGrid(images: images),
      if (videos.isNotEmpty) ...videos.map((v)=> _MediaCard(att: v, icon: CupertinoIcons.videocam_fill, color: GG.blue)),
      if (audios.isNotEmpty) ...audios.map((a)=> _MediaCard(att: a, icon: CupertinoIcons.music_note_2, color: GG.green)),
      if (files.isNotEmpty) ...files.map((f)=> _FileCard(att: f)),
    ]);
  }
}

class _ImageGrid extends StatelessWidget {
  final List<Map<String,dynamic>> images;
  const _ImageGrid({required this.images});
  @override Widget build(BuildContext context){
    final count = images.length;
    if (count==1) {
      return _ImageTile(att: images[0], height: 220, rounded: 12);
    }
    if (count==2) {
      return Row(children: images.map((e)=> Expanded(child: Padding(padding: const EdgeInsets.only(right: 6), child: _ImageTile(att: e, height: 140, rounded: 12)))).toList());
    }
    if (count==3) {
      return Column(children: [
        _ImageTile(att: images[0], height: 160, rounded: 12),
        const SizedBox(height: 6),
        Row(children: images.sublist(1).map((e)=> Expanded(child: Padding(padding: const EdgeInsets.only(right: 6), child: _ImageTile(att: e, height: 110, rounded: 10)))).toList()),
      ]);
    }
    // 4+ grid 2x2
    return Wrap(spacing: 6, runSpacing: 6, children: images.take(6).map((e)=> SizedBox(width: (MediaQuery.of(context).size.width-64)/2, height: 120, child: _ImageTile(att: e, rounded: 10))).toList());
  }
}

class _ImageTile extends StatelessWidget {
  final Map<String,dynamic> att;
  final double height;
  final double rounded;
  const _ImageTile({required this.att, this.height=160, this.rounded=12});
  @override Widget build(BuildContext context){
    final path = att['path'] as String?;
    final name = att['name'] as String? ?? 'image';
    final size = att['size'] as int? ?? 0;
    Widget img;
    if (path!=null && File(path).existsSync()) {
      img = Image.file(File(path), fit: BoxFit.cover, width: double.infinity, height: height);
    } else {
      img = Container(color: GG.surface2, child: Center(child: Icon(CupertinoIcons.photo, color: GG.muted, size: 32)));
    }
    return InkWell(
      onTap: (){
        if (path!=null && File(path).existsSync()) {
          Navigator.push(context, MaterialPageRoute(builder: (_)=> Scaffold(backgroundColor: Colors.black, appBar: AppBar(backgroundColor: Colors.black, iconTheme: const IconThemeData(color: Colors.white), title: Text(name, style: const TextStyle(color: Colors.white, fontSize: 14))), body: Center(child: Image.file(File(path))))));
        }
      },
      borderRadius: BorderRadius.circular(rounded),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(rounded),
        child: Stack(children: [
          SizedBox(height: height, width: double.infinity, child: img),
          Positioned(bottom: 0, left: 0, right: 0, child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Colors.black.withValues(alpha: 0.6)])),
            child: Row(children: [
              Expanded(child: Text(name, style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis)),
              Text(_formatBytes(size), style: const TextStyle(color: Colors.white70, fontSize: 9)),
            ]),
          )),
        ]),
      ),
    );
  }
}

class _MediaCard extends StatelessWidget {
  final Map<String,dynamic> att;
  final IconData icon;
  final Color color;
  const _MediaCard({required this.att, required this.icon, required this.color});
  @override Widget build(BuildContext context){
    final name = att['name'] as String? ?? 'media';
    final size = att['size'] as int? ?? 0;
    final path = att['path'] as String?;
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: GG.surface2, borderRadius: BorderRadius.circular(10)),
      child: Row(children: [
        Container(width: 40, height: 40, decoration: BoxDecoration(color: color.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(8)), child: Icon(icon, color: color, size: 20)),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(name, style: TextStyle(color: GG.paper, fontSize: 13, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
          Text(_formatBytes(size), style: TextStyle(color: GG.muted, fontSize: 11)),
        ])),
        IconButton(icon: Icon(CupertinoIcons.play_fill, color: GG.paper, size: 18), onPressed: (){ if(path!=null) OpenFilex.open(path); }),
      ]),
    );
  }
}

class _FileCard extends StatelessWidget {
  final Map<String,dynamic> att;
  const _FileCard({required this.att});
  @override Widget build(BuildContext context){
    final name = att['name'] as String? ?? 'file';
    final size = att['size'] as int? ?? 0;
    final mime = att['mime'] as String? ?? '';
    final ext = name.contains('.') ? name.split('.').last.toUpperCase() : 'FILE';
    final path = att['path'] as String?;
    IconData icon = CupertinoIcons.doc_fill;
    Color col = GG.iris;
    if (mime.contains('pdf')) { icon = CupertinoIcons.doc_text_fill; col = GG.red; }
    else if (mime.contains('zip') || mime.contains('archive')) { icon = CupertinoIcons.archivebox; col = GG.yellow; }
    else if (mime.contains('text')) { icon = CupertinoIcons.doc_text; col = GG.blue; }
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: GG.surface2, borderRadius: BorderRadius.circular(10)),
      child: Row(children: [
        Container(width: 40, height: 40, decoration: BoxDecoration(color: col.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)), child: Stack(alignment: Alignment.center, children: [Icon(icon, color: col, size: 22), Positioned(bottom: 4, child: Text(ext, style: TextStyle(color: col, fontSize: 7, fontWeight: FontWeight.w800)))])),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(name, style: TextStyle(color: GG.paper, fontSize: 13, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
          Text('${ext} • ${_formatBytes(size)}', style: TextStyle(color: GG.muted, fontSize: 11)),
        ])),
        IconButton(icon: Icon(CupertinoIcons.arrow_down_circle, color: GG.muted, size: 20), onPressed: (){ if(path!=null) OpenFilex.open(path); }),
      ]),
    );
  }
}

class MessageBubble extends StatelessWidget {
  final String role; final String content; final String? thinking; final String? modelKey; final List<Map<String,dynamic>>? attachments;
  const MessageBubble({super.key, required this.role, required this.content, this.thinking, this.modelKey, this.attachments});

  bool get isUser => role=='user';

  @override Widget build(BuildContext context) {
    if (isUser) {
      final hasAtt = attachments!=null && attachments!.isNotEmpty;
      final hasText = content.trim().isNotEmpty;
      return Align(
        alignment: Alignment.centerRight,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
            decoration: BoxDecoration(color: GG.violet, borderRadius: BorderRadius.circular(16)),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (hasAtt) ClipRRect(
                borderRadius: BorderRadius.vertical(top: const Radius.circular(16), bottom: Radius.circular(hasText ? 0 : 16)),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  color: Colors.black.withValues(alpha: 0.12),
                  child: AttachmentView(attachments: attachments!),
                ),
              ),
              if (hasText) Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: SelectableText(content, style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.45)),
              ),
              if (!hasText && !hasAtt) const Padding(padding: EdgeInsets.all(12), child: Text('…', style: TextStyle(color: Colors.white))),
            ]),
          ),
        ),
      );
    }
    final hasAtt = attachments!=null && attachments!.isNotEmpty;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (modelKey!=null) Padding(
          padding: const EdgeInsets.only(bottom: 6, left: 4),
          child: Text(modelKey!.split(':').last, style: TextStyle(color: GG.faint, fontSize: 11, letterSpacing: 0.8, fontFamily: 'monospace')),
        ),
        if (thinking!=null && thinking!.trim().isNotEmpty)
          ThinkingBlock(text: thinking!, initiallyExpanded: false),
        if (hasAtt)
          Container(
            constraints: const BoxConstraints(maxWidth: 520),
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: GG.surface, borderRadius: BorderRadius.circular(12)),
            child: AttachmentView(attachments: attachments!),
          ),
        Container(
          constraints: const BoxConstraints(maxWidth: 780),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(color: GG.surface, borderRadius: BorderRadius.circular(12)),
          child: MarkdownBody(
            data: content.isEmpty ? '…' : content,
            selectable: true,
            styleSheet: MarkdownStyleSheet(
              p: TextStyle(color: GG.paper, fontSize: 14, height: 1.55),
              code: TextStyle(color: GG.iris, fontSize: 13, fontFamily: 'monospace', backgroundColor: GG.bgDeep),
              codeblockDecoration: BoxDecoration(color: GG.bgDeep, borderRadius: BorderRadius.circular(8)),
              blockquoteDecoration: BoxDecoration(border: Border(left: BorderSide(color: GG.violet, width: 3)), color: Colors.transparent),
              h1: TextStyle(color: GG.paper, fontSize: 20, fontWeight: FontWeight.w700),
              h2: TextStyle(color: GG.paper, fontSize: 17, fontWeight: FontWeight.w700),
              h3: TextStyle(color: GG.paper, fontSize: 15, fontWeight: FontWeight.w600),
              listBullet: TextStyle(color: GG.iris),
              a: TextStyle(color: GG.iris, decoration: TextDecoration.underline),
            ),
            onTapLink: (t,h,l){},
          ),
        ),
      ]),
    );
  }
}

// Таймлайн для стрима
class TimelineEntry {
  final String type;
  String text;
  bool expanded;
  TimelineEntry({required this.type, required this.text, this.expanded=true});
}

class TimelineBubble extends StatefulWidget {
  final List<TimelineEntry> entries;
  final String? modelKey;
  const TimelineBubble({super.key, required this.entries, this.modelKey});
  @override State<TimelineBubble> createState()=>_TimelineBubbleState();
}

class _TimelineBubbleState extends State<TimelineBubble> {
  @override Widget build(BuildContext context){
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (widget.modelKey!=null) Padding(
          padding: const EdgeInsets.only(bottom: 6, left: 4),
          child: Text(widget.modelKey!.split(':').last, style: TextStyle(color: GG.faint, fontSize: 11, letterSpacing: 0.8, fontFamily: 'monospace')),
        ),
        ...widget.entries.map((e){
          if (e.type=='thinking') {
            return ThinkingBlock(text: e.text, initiallyExpanded: e.expanded);
          } else if (e.type=='action') {
            return Container(
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(color: GG.surface2, borderRadius: BorderRadius.circular(8)),
              child: Row(children: [Icon(CupertinoIcons.wrench, size: 12, color: GG.muted), const SizedBox(width: 6), Expanded(child: Text(e.text, style: TextStyle(color: GG.muted, fontSize: 11)))]),
            );
          } else {
            return Container(
              constraints: const BoxConstraints(maxWidth: 780),
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(color: GG.surface, borderRadius: BorderRadius.circular(12)),
              child: MarkdownBody(data: e.text.isEmpty ? '▌' : e.text, selectable: true, styleSheet: MarkdownStyleSheet(
                p: TextStyle(color: GG.paper, fontSize: 14, height: 1.55),
                code: TextStyle(color: GG.iris, fontSize: 13, fontFamily: 'monospace', backgroundColor: GG.bgDeep),
                codeblockDecoration: BoxDecoration(color: GG.bgDeep, borderRadius: BorderRadius.circular(8)),
                h1: TextStyle(color: GG.paper, fontSize: 20, fontWeight: FontWeight.w700),
                a: TextStyle(color: GG.iris, decoration: TextDecoration.underline),
              )),
            );
          }
        }),
      ]),
    );
  }
}

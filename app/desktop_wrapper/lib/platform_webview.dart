// Кросс-платформенный WebView wrapper.
// Windows → webview_windows (WebView2)
// Android → webview_flutter (Android WebView)
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:webview_windows/webview_windows.dart' as ww;
import 'package:webview_flutter/webview_flutter.dart' as wf;

class GeWebView extends StatefulWidget {
  final String url;
  // JS-инжект который выполняется до загрузки страницы (для token и т.п.)
  final String? injectScript;
  const GeWebView({super.key, required this.url, this.injectScript});

  @override
  State<GeWebView> createState() => _GeWebViewState();
}

class _GeWebViewState extends State<GeWebView> {
  ww.WebviewController? _winCtrl;
  late final wf.WebViewController _androidCtrl;
  bool _ready = false;
  String? _err;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      if (Platform.isWindows) {
        final c = ww.WebviewController();
        await c.initialize();
        if (widget.injectScript != null && widget.injectScript!.isNotEmpty) {
          await c.addScriptToExecuteOnDocumentCreated(widget.injectScript!);
        }
        await c.loadUrl(widget.url);
        _winCtrl = c;
      } else {
        // Android / iOS / Linux / macOS
        final c = wf.WebViewController()
          ..setJavaScriptMode(wf.JavaScriptMode.unrestricted)
          ..setBackgroundColor(const Color(0xFF020617));
        if (widget.injectScript != null && widget.injectScript!.isNotEmpty) {
          c.setNavigationDelegate(wf.NavigationDelegate(
            onPageStarted: (_) async {
              try {
                await c.runJavaScript(widget.injectScript!);
              } catch (_) {}
            },
          ));
        }
        await c.loadRequest(Uri.parse(widget.url));
        _androidCtrl = c;
      }
      setState(() => _ready = true);
    } catch (e) {
      setState(() => _err = e.toString());
    }
  }

  @override
  void dispose() {
    _winCtrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_err != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('WebView недоступен:\n$_err',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFFF87171))),
        ),
      );
    }
    if (!_ready) {
      return const Center(child: CircularProgressIndicator(color: Color(0xFFA855F7)));
    }
    if (Platform.isWindows && _winCtrl != null) {
      return ww.Webview(_winCtrl!);
    }
    return wf.WebViewWidget(controller: _androidCtrl);
  }
}

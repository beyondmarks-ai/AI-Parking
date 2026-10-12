import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'camera_discovery.dart';
import 'camera_stream_session.dart';

class LiveCameraStream extends StatefulWidget {
  const LiveCameraStream({
    super.key,
    required this.url,
    required this.onFrame,
    required this.onUnavailable,
  });
  final String url;
  final ValueChanged<List<int>> onFrame;
  final VoidCallback onUnavailable;

  @override
  State<LiveCameraStream> createState() => _LiveCameraStreamState();
}

class _LiveCameraStreamState extends State<LiveCameraStream>
    with WidgetsBindingObserver {
  CameraStreamSession? _session;
  Uint8List? _frame;
  bool _reconnecting = false;
  DateTime? _lastDisplay;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  void _start() {
    _session = CameraStreamSession(
      url: widget.url,
      clientFactory: createCameraHttpClient,
      onFrame: (frame) {
        if (!mounted) return;
        final now = DateTime.now();
        if (!_reconnecting &&
            _lastDisplay != null &&
            now.difference(_lastDisplay!) < const Duration(milliseconds: 100)) {
          return;
        }
        _lastDisplay = now;
        final previous = _frame;
        setState(() {
          _frame = frame;
          _reconnecting = false;
        });
        if (previous != null) {
          PaintingBinding.instance.imageCache.evict(MemoryImage(previous));
        }
        widget.onFrame(frame);
      },
      onReconnecting: () {
        if (!mounted) return;
        setState(() => _reconnecting = true);
        widget.onUnavailable();
      },
    )..start();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _session == null) {
      _start();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _session?.dispose();
      _session = null;
      setState(() {
        _frame = null;
        _reconnecting = true;
      });
      widget.onUnavailable();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _session?.dispose();
    final frame = _frame;
    if (frame != null) {
      PaintingBinding.instance.imageCache.evict(MemoryImage(frame));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      if (_frame != null)
        Image.memory(
          _frame!,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          errorBuilder: (_, error, stack) => const SizedBox(),
        ),
      if (_frame == null || _reconnecting)
        ColoredBox(
          color: const Color(0xBB000000),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(color: Colors.white),
                const SizedBox(height: 14),
                Text(
                  _reconnecting
                      ? 'Reconnecting to camera…'
                      : 'Connecting to camera…',
                  style: const TextStyle(color: Colors.white),
                ),
              ],
            ),
          ),
        ),
    ],
  );
}

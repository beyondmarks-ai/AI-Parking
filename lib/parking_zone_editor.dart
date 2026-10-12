import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'parking_zone.dart';

Rect containedImageRect(Size viewport, double aspect) {
  final fitted = applyBoxFit(
    BoxFit.contain,
    Size(aspect, 1),
    viewport,
  ).destination;
  return Alignment.center.inscribe(fitted, Offset.zero & viewport);
}

class ParkingZonePainter extends CustomPainter {
  ParkingZonePainter(this.points, this.aspect);
  final List<List<double>> points;
  final double aspect;
  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    final rect = containedImageRect(size, aspect);
    final mapped = points
        .map(
          (p) => Offset(
            rect.left + p[0] * rect.width,
            rect.top + p[1] * rect.height,
          ),
        )
        .toList();
    final path = Path()..moveTo(mapped.first.dx, mapped.first.dy);
    for (final p in mapped.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    if (points.length == 4) {
      path.close();
      canvas.drawPath(
        path,
        Paint()..color = Colors.amber.withValues(alpha: .12),
      );
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.amber
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke,
    );
    for (var i = 0; i < mapped.length; i++) {
      canvas.drawCircle(mapped[i], 8, Paint()..color = Colors.amber);
      final text = TextPainter(
        text: TextSpan(
          text: '${i + 1}',
          style: const TextStyle(color: Colors.black, fontSize: 11),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      text.paint(canvas, mapped[i] - Offset(text.width / 2, text.height / 2));
    }
  }

  @override
  bool shouldRepaint(covariant ParkingZonePainter old) =>
      old.points != points || old.aspect != aspect;
}

/// Edits a frozen frame while the underlying live stream stays mounted.
class ParkingZoneEditor extends StatefulWidget {
  const ParkingZoneEditor({
    super.key,
    required this.jpeg,
    required this.aspect,
  });
  final Uint8List jpeg;
  final double aspect;
  @override
  State<ParkingZoneEditor> createState() => _ParkingZoneEditorState();
}

class _ParkingZoneEditorState extends State<ParkingZoneEditor> {
  List<List<double>> _points = [];
  String? _error;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Mark no-parking bay')),
    body: SafeArea(
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Tap the 4 corners of the whole bay, in order around its boundary. '
              'Use the outer boundary, not the red strips. All corners must be visible.',
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => GestureDetector(
                key: const ValueKey('zone-image'),
                behavior: HitTestBehavior.opaque,
                onTapUp: (details) {
                  final rect = containedImageRect(
                    constraints.biggest,
                    widget.aspect,
                  );
                  if (!rect.contains(details.localPosition) ||
                      _points.length == 4) {
                    return;
                  }
                  setState(() {
                    _error = null;
                    _points = [
                      ..._points,
                      [
                        (details.localPosition.dx - rect.left) / rect.width,
                        (details.localPosition.dy - rect.top) / rect.height,
                      ],
                    ];
                  });
                },
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ColoredBox(
                      color: Colors.black,
                      child: Image.memory(widget.jpeg, fit: BoxFit.contain),
                    ),
                    CustomPaint(
                      painter: ParkingZonePainter(_points, widget.aspect),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Text(
                  _error ??
                      '${_points.length}/4 corners. Redraw if the camera moves.',
                ),
                Wrap(
                  spacing: 12,
                  children: [
                    TextButton(
                      onPressed: () => setState(() {
                        _points = [];
                        _error = null;
                      }),
                      child: const Text('Start again'),
                    ),
                    FilledButton(
                      onPressed: _points.length != 4
                          ? null
                          : () {
                              try {
                                Navigator.pop(
                                  context,
                                  ParkingZone(_points, widget.aspect),
                                );
                              } on FormatException catch (e) {
                                setState(() => _error = e.message);
                              }
                            },
                      child: const Text('Use whole bay'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

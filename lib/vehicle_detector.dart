import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as image_lib;
import 'package:tflite_flutter/tflite_flutter.dart';

class VehicleDetection {
  const VehicleDetection({
    required this.label,
    required this.confidence,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final String label;
  final double confidence;
  final double left;
  final double top;
  final double right;
  final double bottom;
}

class VehicleDetectionResult {
  const VehicleDetectionResult({
    required this.detections,
    required this.inferenceMilliseconds,
  });

  final List<VehicleDetection> detections;
  final int inferenceMilliseconds;
}

class VehicleDetector {
  VehicleDetector._(this._interpreter);

  static const _modelPath = 'assets/models/vehicle_detector.tflite';
  static const _vehicleLabels = <int, String>{
    1: 'Bicycle',
    2: 'Car',
    3: 'Motorcycle',
    5: 'Bus',
    7: 'Truck',
  };

  final Interpreter _interpreter;

  static VehicleDetector fromBytes(Uint8List model) {
    final options = InterpreterOptions()..threads = 2;
    return VehicleDetector._(Interpreter.fromBuffer(model, options: options));
  }

  static Future<VehicleDetector> load() async {
    final options = InterpreterOptions()..threads = 4;
    if (Platform.isAndroid) options.addDelegate(XNNPackDelegate());
    final interpreter = await Interpreter.fromAsset(
      _modelPath,
      options: options,
    );
    return VehicleDetector._(interpreter);
  }

  VehicleDetectionResult detect(List<int> jpegBytes) {
    final startedAt = DateTime.now();
    final decoded = image_lib.decodeImage(Uint8List.fromList(jpegBytes));
    if (decoded == null) {
      return const VehicleDetectionResult(
        detections: [],
        inferenceMilliseconds: 0,
      );
    }

    final inputTensor = _interpreter.getInputTensor(0);
    final inputHeight = inputTensor.shape[1];
    final inputWidth = inputTensor.shape[2];
    final resized = image_lib.copyResize(
      decoded,
      width: inputWidth,
      height: inputHeight,
      interpolation: image_lib.Interpolation.linear,
    );
    final isFloatInput = inputTensor.type == TensorType.float32;
    final imageMatrix = List.generate(
      inputHeight,
      (y) => List.generate(inputWidth, (x) {
        final pixel = resized.getPixel(x, y);
        if (isFloatInput) {
          return <double>[
            (pixel.r.toDouble() - 127.5) / 127.5,
            (pixel.g.toDouble() - 127.5) / 127.5,
            (pixel.b.toDouble() - 127.5) / 127.5,
          ];
        }
        return <int>[pixel.r.toInt(), pixel.g.toInt(), pixel.b.toInt()];
      }),
    );

    final outputTensors = _interpreter.getOutputTensors();
    final outputs = <int, Object>{};
    for (var index = 0; index < outputTensors.length; index++) {
      outputs[index] = _zeroTensor(outputTensors[index].shape);
    }
    _interpreter.runForMultipleInputs(<Object>[
      <Object>[imageMatrix],
    ], outputs);

    final boxes = (outputs[0] as List).first as List;
    final classes = (outputs[1] as List).first as List;
    final scores = (outputs[2] as List).first as List;
    final countValue = (outputs[3] as List).first as num;
    final count = countValue.toInt().clamp(0, boxes.length);
    final detections = <VehicleDetection>[];
    for (var index = 0; index < count; index++) {
      final confidence = (scores[index] as num).toDouble();
      final classIndex = (classes[index] as num).toInt();
      final label = _vehicleLabels[classIndex];
      if (label == null || confidence < .45) continue;
      final box = boxes[index] as List;
      detections.add(
        VehicleDetection(
          label: label,
          confidence: confidence,
          left: _normalized(box[1]),
          top: _normalized(box[0]),
          right: _normalized(box[3]),
          bottom: _normalized(box[2]),
        ),
      );
    }

    return VehicleDetectionResult(
      detections: detections,
      inferenceMilliseconds: DateTime.now()
          .difference(startedAt)
          .inMilliseconds,
    );
  }

  void close() => _interpreter.close();

  static Object _zeroTensor(List<int> shape, [int dimension = 0]) {
    if (dimension == shape.length - 1) {
      return List<double>.filled(shape[dimension], 0);
    }
    return List<Object>.generate(
      shape[dimension],
      (_) => _zeroTensor(shape, dimension + 1),
    );
  }

  static double _normalized(Object value) =>
      ((value as num).toDouble()).clamp(0, 1);
}

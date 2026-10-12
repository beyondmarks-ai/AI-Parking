import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'camera_discovery.dart';
import 'camera_wifi_config.dart';
import 'live_camera_stream.dart';
import 'motion_trigger.dart';
import 'plate_ocr.dart';
import 'image_parking_analyzer.dart';
import 'image_scan_policy.dart';
import 'snapshot_archive.dart';
import 'parking_zone.dart';
import 'parking_zone_editor.dart';

void main() => runApp(const ParkGuardApp());

class ParkGuardApp extends StatelessWidget {
  const ParkGuardApp({super.key, this.autoDiscoverCamera = true});

  final bool autoDiscoverCamera;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'ParkGuard AI',
    theme: ThemeData(
      useMaterial3: true,
      fontFamily: 'Roboto',
      scaffoldBackgroundColor: const Color(0xFFF4F7FB),
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF2155D9),
        brightness: Brightness.light,
      ),
    ),
    home: OperatorHome(autoDiscoverCamera: autoDiscoverCamera),
  );
}

class OperatorHome extends StatefulWidget {
  const OperatorHome({super.key, this.autoDiscoverCamera = true});

  final bool autoDiscoverCamera;
  @override
  State<OperatorHome> createState() => _OperatorHomeState();
}

class _OperatorHomeState extends State<OperatorHome> {
  static const _videoPicker = MethodChannel('parkguard/video_picker');
  int _tab = 0;
  String? _videoName;
  bool _analysing = false;
  bool _hasResult = false;
  bool _discoveringCamera = false;
  bool _updatingCameraWifi = false;
  String? _liveStreamUrl;
  int _cameraConnectionId = 0;
  CameraFrame? _latestCameraFrame;
  PlateOcrResult? _plateOcrResult;
  bool _readingPlate = false;
  String _scanStatus = 'Live — watching for movement';
  bool _autoScanning = true;
  var _scanPolicy = ImageScanPolicy();
  String _lcdStatus = 'Waiting for a confirmed number';
  final _snapshotArchive = SnapshotArchive();
  PlateSnapshot? _archiveSnapshot;
  String? _archiveKey;
  DateTime? _archiveAttemptAt;
  bool _archiveBusy = false;
  bool _archiveSaved = false;
  String _archiveStatus = 'No snapshot saved yet';
  final List<CameraFrame> _burstFrames = [];
  DateTime? _burstStartsAt;
  int _scanGeneration = 0;
  final _motionTrigger = MotionTrigger(cooldown: Duration.zero);
  ImageParkingAnalyzer? _activeRecognizer;
  final _rtspController = TextEditingController();
  final _zoneStore = ParkingZoneStore();
  ParkingZone? _parkingZone;
  bool _editingZone = false;
  int _zoneLoadId = 0;

  Future<void> _loadParkingZone(String camera) async {
    final id = ++_zoneLoadId;
    setState(() {
      _parkingZone = null;
      _scanStatus = 'Mark the no-parking bay to enable scanning';
    });
    final zone = await _zoneStore.load(camera);
    if (!mounted || id != _zoneLoadId || camera != _liveStreamUrl) return;
    setState(() {
      _parkingZone = zone;
      if (zone != null) {
        _scanStatus = 'Bay loaded - image analysis ready';
      }
    });
  }

  Future<void> _markParkingZone() async {
    final frame = _latestCameraFrame;
    final camera = _liveStreamUrl;
    if (_editingZone || frame == null || !frame.isFresh || camera == null) {
      return;
    }
    final aspect = jpegAspectRatio(frame.jpeg);
    if (aspect == null) return;
    _zoneLoadId++;
    _cancelPlateScan();
    setState(() => _editingZone = true);
    final zone = await Navigator.of(context).push<ParkingZone>(
      MaterialPageRoute(
        builder: (_) => ParkingZoneEditor(jpeg: frame.jpeg, aspect: aspect),
      ),
    );
    if (!mounted) return;
    try {
      if (zone != null && camera == _liveStreamUrl) {
        await _zoneStore.save(camera, zone);
        if (!mounted || camera != _liveStreamUrl) return;
        setState(() {
          _parkingZone = zone;
          // A new calibration starts a new archive/alert encounter.
          _scanPolicy = ImageScanPolicy();
          _archiveKey = null;
        });
        _showMessage('Whole bay saved. No red strips needed.');
      }
    } on Object {
      if (mounted) _showMessage('Could not save the bay. Please try again.');
    } finally {
      if (mounted) {
        _motionTrigger.reset();
        setState(() {
          _editingZone = false;
          _scanStatus = _parkingZone == null
              ? 'Mark the no-parking bay to enable scanning'
              : 'Image checks on movement and every 30 seconds';
        });
      }
    }
  }

  @override
  void initState() {
    super.initState();
    if (widget.autoDiscoverCamera) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _discoverCamera(true),
      );
    }
  }

  @override
  void dispose() {
    _snapshotArchive.close();
    _activeRecognizer?.close();
    _scanGeneration++;
    _rtspController.dispose();
    super.dispose();
  }

  Future<void> _chooseVideo() async {
    String? name;
    try {
      name = await _videoPicker.invokeMethod<String>('pickVideo');
    } on PlatformException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not open video picker: ${error.message}'),
          ),
        );
      }
      return;
    }
    if (name == null || name.isEmpty) return;
    setState(() {
      _videoName = name;
      _hasResult = false;
    });
  }

  Future<void> _analyse() async {
    if (_videoName == null) {
      await _chooseVideo();
      if (_videoName == null) return;
    }
    setState(() {
      _analysing = true;
      _hasResult = false;
    });
    await Future<void>.delayed(const Duration(seconds: 2));
    if (!mounted) return;
    setState(() {
      _analysing = false;
      _hasResult = true;
      if (_liveStreamUrl == null) _tab = 1;
    });
  }

  void _connectCamera() {
    var value = _rtspController.text.trim();
    if (value.isEmpty) {
      _showMessage('Enter the ESP32-CAM IP address or stream URL.');
      return;
    }
    if (!value.contains('://')) value = 'http://$value';

    final uri = Uri.tryParse(value);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      _showMessage('Use an HTTP URL such as http://192.168.1.50:81/stream');
      return;
    }

    // CameraWebServer uses port 80 for controls and port 81 for MJPEG.
    if ((uri.path.isEmpty || uri.path == '/') && !uri.hasPort) {
      value = uri.replace(port: 81, path: '/stream').toString();
    } else if (uri.path.isEmpty || uri.path == '/') {
      value = uri.replace(path: '/stream').toString();
    }

    _rtspController.text = value;
    _cancelPlateScan();
    _motionTrigger.reset();
    setState(() {
      _latestCameraFrame = null;
      _liveStreamUrl = value;
      _cameraConnectionId++;
      _tab = 2;
    });
    _showMessage('Connecting to ESP32-CAM on $value');
    unawaited(_loadParkingZone(value));
  }

  void _disconnectCamera() {
    _cancelPlateScan();
    _motionTrigger.reset();
    setState(() {
      _liveStreamUrl = null;
      _latestCameraFrame = null;
      _parkingZone = null;
      _zoneLoadId++;
    });
  }

  void _rememberCameraFrame(List<int> bytes) {
    if (!mounted || _liveStreamUrl == null) return;
    if (bytes.isEmpty) {
      _cancelPlateScan();
      _motionTrigger.reset();
      if (_latestCameraFrame != null) setState(() => _latestCameraFrame = null);
      return;
    }
    final firstFrame = _latestCameraFrame == null;
    final frame = CameraFrame(bytes);
    _latestCameraFrame = frame;
    final startsAt = _burstStartsAt;
    if (startsAt != null &&
        !frame.capturedAt.isBefore(startsAt) &&
        (_burstFrames.isEmpty ||
            frame.capturedAt.difference(_burstFrames.last.capturedAt) >=
                const Duration(milliseconds: 150))) {
      if (_burstFrames.length < 8) _burstFrames.add(frame);
    }
    if (firstFrame) setState(() {});

    final zone = _parkingZone;
    if (zone == null || _editingZone) return;
    final aspect = jpegAspectRatio(frame.jpeg);
    if (aspect == null) return;
    if (!zone.matchesAspect(aspect)) {
      _cancelPlateScan();
      _motionTrigger.reset();
      setState(() {
        _parkingZone = null;
        _scanStatus = 'Camera image changed - mark the bay again';
      });
      return;
    }
    if (!_autoScanning) return;
    final motion = _motionTrigger.addFrame(bytes, capturedAt: frame.capturedAt);
    _scanPolicy.frame(frame.capturedAt, motion: motion);
    if (!_readingPlate && _scanPolicy.shouldScan(frame.capturedAt)) {
      unawaited(_readVehicleNumber(automatic: true));
    }
  }

  void _cancelPlateScan() {
    _scanGeneration++;
    _activeRecognizer?.close();
    _activeRecognizer = null;
    _scanPolicy.suspend();
    _burstStartsAt = null;
    _burstFrames.clear();
    _readingPlate = false;
  }

  Future<void> _readVehicleNumber({bool automatic = false}) async {
    if (_readingPlate) return;
    final zone = _parkingZone;
    if (zone == null || _editingZone) {
      if (!automatic) _showMessage('Mark the no-parking bay first.');
      return;
    }
    final frame = _latestCameraFrame;
    if (_liveStreamUrl == null || frame == null || !frame.isFresh) {
      _showMessage('Wait for a live camera image, then try again.');
      return;
    }
    final generation = _scanGeneration;
    if (!_scanPolicy.start(DateTime.now())) {
      if (!automatic) {
        _showMessage(
          'Image analyzer is cooling down briefly. Automatic checks continue.',
        );
      }
      return;
    }
    final streamUrl = _liveStreamUrl!;
    bool active() =>
        mounted && generation == _scanGeneration && _liveStreamUrl == streamUrl;
    setState(() {
      _readingPlate = true;
      _scanStatus = 'Capturing in background — live video continues';
    });
    final recognizer = ImageParkingAnalyzer();
    _activeRecognizer = recognizer;
    var failed = false;
    try {
      _burstFrames.clear();
      _burstStartsAt = DateTime.now();
      await Future<void>.delayed(const Duration(milliseconds: 650));
      if (!active()) return;
      _burstStartsAt = null;
      final burst = _burstFrames.isEmpty
          ? [frame]
          : List<CameraFrame>.from(_burstFrames);
      setState(
        () => _scanStatus = 'Analyzing image: vehicle, plate and bay position',
      );
      final observation = await recognizer.analyze(
        burst,
        zone: zone,
        isActive: active,
      );
      if (!active()) return;
      final result = observation.result;
      if (result == null) {
        if (observation.status == 'empty') _scanPolicy.observeEmpty();
        setState(
          () => _scanStatus = observation.status == 'empty'
              ? 'No vehicle visible - image checks continue automatically'
              : 'Image unclear: plate or bay position uncertain - retrying automatically',
        );
        return;
      }
      final candidates = result.candidates;
      String? lcdError;
      final plate = candidates.isEmpty ? null : candidates.first;
      if (plate != null) _saveSnapshotInBackground(result);
      final decisionKey =
          '$plate:${result.parkingPosition}:${result.fineAmount}';
      final decisionText = result.noParkingViolation
          ? 'FINE Rs ${result.fineAmount}'
          : 'NO FINE';
      final isRepeatedAlert =
          plate != null && !_scanPolicy.shouldRelay(decisionKey);
      setState(() => _plateOcrResult = result);
      if (isRepeatedAlert) {
        setState(
          () => _scanStatus =
              '$plate - $decisionText - live image checks continue',
        );
        return;
      }
      setState(() {
        _plateOcrResult = result;
        _scanStatus = '$plate - $decisionText - camera stays live';
        _lcdStatus = 'Sending number to LCD relay...';
      });
      if (_liveStreamUrl != null && plate != null && !isRepeatedAlert) {
        try {
          await sendParkingResultToCamera(
            streamUrl: streamUrl,
            plate: plate,
            fineAmount: result.fineAmount,
          );
          if (!active()) return;
          _scanPolicy.acknowledge(decisionKey);
        } on Object catch (error) {
          lcdError = '$error';
        }
      }
      if (!active()) return;
      setState(() {
        _lcdStatus = lcdError == null
            ? 'LCD relay accepted $plate / $decisionText (screen receipt unverified)'
            : 'LCD relay failed — retrying automatically';
      });
      if (lcdError != null) {
        _showMessage('Number detected, but LCD update failed: $lcdError');
      } else if (automatic && plate != null && !isRepeatedAlert) {
        _showMessage(
          result.noParkingViolation
              ? '$plate: inside bay - Fine Rs ${result.fineAmount}'
              : '$plate: outside bay - NO FINE',
        );
      }
      // This is the user's display-only demo rule, not a legal fine notice.
    } on Object catch (error) {
      failed = true;
      if (active()) {
        setState(
          () => _scanStatus =
              'Image analyzer unavailable - retrying in 30 seconds',
        );
        if (!automatic) _showMessage('Could not confirm the number: $error');
      }
    } finally {
      recognizer.close();
      if (active()) {
        _activeRecognizer = null;
        _scanPolicy.completed(DateTime.now(), failed: failed);
        setState(() => _readingPlate = false);
      }
    }
  }

  Future<void> _discoverCamera([bool silent = false]) async {
    if (_discoveringCamera) return;
    _cancelPlateScan();
    _motionTrigger.reset();
    setState(() {
      _discoveringCamera = true;
      // Release the ESP32's active stream before probing its capture endpoint.
      // Some firmware cannot serve captures reliably while video is running.
      _liveStreamUrl = null;
      _latestCameraFrame = null;
    });
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final streamUrl = await discoverParkGuardCamera();
    if (!mounted) return;
    setState(() {
      _discoveringCamera = false;
      if (streamUrl != null) {
        // A failed MJPEG connection does not retry by itself. Recreate the
        // camera page even when discovery returns the same URL after recovery.
        _cameraConnectionId++;
        _latestCameraFrame = null;
        _rtspController.text = streamUrl;
        _liveStreamUrl = streamUrl;
        _tab = 2;
      }
    });
    if (streamUrl != null) {
      unawaited(_loadParkingZone(streamUrl));
      _showMessage('ESP32-CAM found. Starting live video.');
    } else if (!silent) {
      _showMessage(
        'No ParkGuard camera found. Check Wi-Fi and the ESP32 mDNS setup.',
      );
    }
  }

  Future<void> _configureCameraWifi() async {
    final streamUrl = _liveStreamUrl;
    if (streamUrl == null) {
      _showMessage('Connect to the ESP32-CAM before changing its Wi-Fi.');
      return;
    }
    final credentials = await showDialog<_WifiCredentials>(
      context: context,
      builder: (_) => const _WifiCredentialsDialog(),
    );
    if (credentials == null || !mounted) return;

    setState(() => _updatingCameraWifi = true);
    try {
      await updateCameraWifi(
        streamUrl: streamUrl,
        ssid: credentials.ssid,
        password: credentials.password,
      );
      if (!mounted) return;
      _cancelPlateScan();
      setState(() {
        _updatingCameraWifi = false;
        _liveStreamUrl = null;
        _rtspController.clear();
      });
      _showMessage(
        'Wi-Fi saved. The camera is restarting. Connect this phone to the new network, then tap Find automatically.',
      );
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _updatingCameraWifi = false);
      _showMessage('Could not update camera Wi-Fi: $error');
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  void _toggleAutoScanning(bool enabled) {
    _cancelPlateScan();
    _motionTrigger.reset();
    setState(() {
      _autoScanning = enabled;
      _scanStatus = enabled
          ? (_parkingZone == null
                ? 'Mark the no-parking bay to enable scanning'
                : 'Image checks on movement and every 30 seconds')
          : 'Automatic scanning paused';
    });
  }

  void _saveSnapshotInBackground(PlateOcrResult result) {
    final key =
        '$_cameraConnectionId:${_scanPolicy.encounter}:${result.candidates.single}:${result.parkingPosition}:${result.fineAmount}';
    if (_archiveKey != key) {
      _archiveKey = key;
      _archiveSnapshot = PlateSnapshot(result);
      _archiveBusy = false;
      _archiveSaved = false;
      _archiveAttemptAt = null;
    }
    if (_archiveBusy ||
        _archiveSaved ||
        (_archiveAttemptAt != null &&
            DateTime.now().difference(_archiveAttemptAt!).inSeconds < 30)) {
      return;
    }
    final snapshot = _archiveSnapshot!;
    _archiveAttemptAt = DateTime.now();
    _archiveBusy = true;
    setState(
      () => _archiveStatus = 'Saving snapshot + ${snapshot.plate} to Azure...',
    );
    unawaited(
      _snapshotArchive
          .save(snapshot)
          .then((_) {
            if (!mounted || !identical(_archiveSnapshot, snapshot)) return;
            setState(() {
              _archiveBusy = false;
              _archiveSaved = true;
              _archiveStatus =
                  'Snapshot + ${snapshot.plate} saved privately in Azure';
            });
          })
          .catchError((Object error) {
            if (!mounted || !identical(_archiveSnapshot, snapshot)) return;
            setState(() {
              _archiveBusy = false;
              _archiveStatus =
                  'Snapshot not saved — will retry on next confirmation';
            });
          }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.sizeOf(context).width >= 860;
    final pages = [
      _WorkSpace(
        key: ValueKey('workspace-$_cameraConnectionId'),
        onOpenCamera: () => setState(() => _tab = 2),
        videoName: _videoName,
        analysing: _analysing,
        onPick: _chooseVideo,
        onAnalyse: _analyse,
        rtspController: _rtspController,
        liveStreamUrl: _liveStreamUrl,
        discoveringCamera: _discoveringCamera,
        onConnectCamera: _connectCamera,
        onDisconnectCamera: _disconnectCamera,
        onDiscoverCamera: _discoverCamera,
        updatingCameraWifi: _updatingCameraWifi,
        onConfigureCameraWifi: _configureCameraWifi,
        onFrame: _rememberCameraFrame,
      ),
      _ResultsPage(
        showResult: _hasResult,
        ocrResult: _plateOcrResult,
        onRetryOcr: () => setState(() => _tab = 2),
      ),
      _CamerasPage(
        key: ValueKey('camera-$_cameraConnectionId'),
        zone: _parkingZone,
        onMarkZone: _markParkingZone,
        autoScanning: _autoScanning,
        onAutoScanningChanged: _toggleAutoScanning,
        lastPlate: _plateOcrResult?.candidates.firstOrNull,
        lcdStatus: _lcdStatus,
        archiveStatus: _archiveStatus,
        onFrame: _rememberCameraFrame,
        cameraReady: _latestCameraFrame != null,
        readingPlate: _readingPlate,
        scanStatus: _scanStatus,
        onReadPlate: () => _readVehicleNumber(),
        controller: _rtspController,
        streamUrl: _liveStreamUrl,
        discovering: _discoveringCamera,
        onConnect: _connectCamera,
        onDisconnect: _disconnectCamera,
        onDiscover: _discoverCamera,
        updatingWifi: _updatingCameraWifi,
        onConfigureWifi: _configureCameraWifi,
      ),
    ];
    return Scaffold(
      appBar: AppBar(
        bottom: _liveStreamUrl == null
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(42),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                  child: Text(
                    _scanStatus,
                    maxLines: 2,
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        title: const Row(
          children: [
            _LogoMark(),
            SizedBox(width: 10),
            Expanded(
              child: Text.rich(
                TextSpan(
                  text: 'ParkGuard',
                  children: [
                    TextSpan(
                      text: ' AI',
                      style: TextStyle(color: Color(0xFF2155D9)),
                    ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  letterSpacing: -.4,
                ),
              ),
            ),
          ],
        ),
        actions: [
          _OnlineBadge(compact: MediaQuery.sizeOf(context).width < 420),
          const SizedBox(width: 12),
          const CircleAvatar(
            radius: 17,
            backgroundColor: Color(0xFFE8EEFF),
            child: Text(
              'A',
              style: TextStyle(
                color: Color(0xFF2155D9),
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: isWide
          ? Row(
              children: [
                _SideRail(
                  selected: _tab,
                  onSelected: (value) => setState(() => _tab = value),
                ),
                Expanded(
                  child: IndexedStack(index: _tab, children: pages),
                ),
              ],
            )
          : IndexedStack(index: _tab, children: pages),
      bottomNavigationBar: isWide
          ? null
          : NavigationBar(
              selectedIndex: _tab,
              onDestinationSelected: (value) => setState(() => _tab = value),
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.add_circle_outline),
                  selectedIcon: Icon(Icons.add_circle),
                  label: 'Analyse',
                ),
                NavigationDestination(
                  icon: Icon(Icons.warning_amber_outlined),
                  selectedIcon: Icon(Icons.warning_amber),
                  label: 'Results',
                ),
                NavigationDestination(
                  icon: Icon(Icons.videocam_outlined),
                  selectedIcon: Icon(Icons.videocam),
                  label: 'Cameras',
                ),
              ],
            ),
    );
  }
}

class _WorkSpace extends StatelessWidget {
  const _WorkSpace({
    super.key,
    required this.videoName,
    required this.analysing,
    required this.onPick,
    required this.onAnalyse,
    required this.rtspController,
    required this.liveStreamUrl,
    required this.discoveringCamera,
    required this.onConnectCamera,
    required this.onDisconnectCamera,
    required this.onDiscoverCamera,
    required this.updatingCameraWifi,
    required this.onConfigureCameraWifi,
    required this.onFrame,
    required this.onOpenCamera,
  });
  final String? videoName;
  final bool analysing;
  final VoidCallback onPick;
  final VoidCallback onAnalyse;
  final TextEditingController rtspController;
  final String? liveStreamUrl;
  final bool discoveringCamera;
  final VoidCallback onConnectCamera;
  final VoidCallback onDisconnectCamera;
  final VoidCallback onDiscoverCamera;
  final bool updatingCameraWifi;
  final VoidCallback onConfigureCameraWifi;
  final ValueChanged<List<int>> onFrame;
  final VoidCallback onOpenCamera;

  @override
  Widget build(BuildContext context) => _Page(
    child: ListView(
      children: [
        const Text(
          'Analyse parking activity',
          style: TextStyle(
            fontSize: 29,
            fontWeight: FontWeight.w800,
            letterSpacing: -.7,
          ),
        ),
        const SizedBox(height: 7),
        const Text(
          'Upload recorded footage or connect a camera. ParkGuard detects vehicles, tracks dwell time, and records reviewable evidence.',
        ),
        const SizedBox(height: 28),
        LayoutBuilder(
          builder: (context, c) => c.maxWidth > 780
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: _UploadCard(
                        videoName: videoName,
                        analysing: analysing,
                        onPick: onPick,
                        onAnalyse: onAnalyse,
                      ),
                    ),
                    const SizedBox(width: 18),
                    Expanded(
                      child: _RtspCard(
                        onOpenCamera: onOpenCamera,
                        onFrame: onFrame,
                        controller: rtspController,
                        streamUrl: liveStreamUrl,
                        discovering: discoveringCamera,
                        onConnect: onConnectCamera,
                        onDisconnect: onDisconnectCamera,
                        onDiscover: onDiscoverCamera,
                        updatingWifi: updatingCameraWifi,
                        onConfigureWifi: onConfigureCameraWifi,
                      ),
                    ),
                  ],
                )
              : Column(
                  children: [
                    _UploadCard(
                      videoName: videoName,
                      analysing: analysing,
                      onPick: onPick,
                      onAnalyse: onAnalyse,
                    ),
                    const SizedBox(height: 18),
                    _RtspCard(
                      onOpenCamera: onOpenCamera,
                      onFrame: onFrame,
                      controller: rtspController,
                      streamUrl: liveStreamUrl,
                      discovering: discoveringCamera,
                      onConnect: onConnectCamera,
                      onDisconnect: onDisconnectCamera,
                      onDiscover: onDiscoverCamera,
                      updatingWifi: updatingCameraWifi,
                      onConfigureWifi: onConfigureCameraWifi,
                    ),
                  ],
                ),
        ),
        const SizedBox(height: 26),
        const Text(
          'How a violation is created',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, c) => GridView.count(
            crossAxisCount: c.maxWidth > 720 ? 4 : 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            childAspectRatio: 1.22,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            children: const [
              _Step(
                '1',
                Icons.directions_car_outlined,
                'Detect vehicle',
                'Cars, trucks, buses and bikes',
              ),
              _Step(
                '2',
                Icons.crop_free_outlined,
                'Check zone',
                'Compare with your restricted zone',
              ),
              _Step(
                '3',
                Icons.timer_outlined,
                'Track duration',
                'Wait for your configured time',
              ),
              _Step(
                '4',
                Icons.camera_alt_outlined,
                'Save evidence',
                'Snapshot, clip and AI confidence',
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _UploadCard extends StatelessWidget {
  const _UploadCard({
    required this.videoName,
    required this.analysing,
    required this.onPick,
    required this.onAnalyse,
  });
  final String? videoName;
  final bool analysing;
  final VoidCallback onPick, onAnalyse;
  @override
  Widget build(BuildContext context) => _Panel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _PanelTitle(
          icon: Icons.upload_file_outlined,
          title: 'Recorded video',
          subtitle: 'MP4, MOV or AVI · up to 2 GB',
        ),
        const SizedBox(height: 18),
        InkWell(
          onTap: analysing ? null : onPick,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            constraints: const BoxConstraints(minHeight: 170),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
            width: double.infinity,
            decoration: BoxDecoration(
              color: const Color(0xFFF6F8FF),
              border: Border.all(color: const Color(0xFFB7C8FF), width: 1.4),
              borderRadius: BorderRadius.circular(14),
            ),
            child: videoName == null
                ? const Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      CircleAvatar(
                        radius: 25,
                        backgroundColor: Color(0xFFE3EAFF),
                        child: Icon(
                          Icons.cloud_upload_outlined,
                          color: Color(0xFF2155D9),
                          size: 28,
                        ),
                      ),
                      SizedBox(height: 12),
                      Text(
                        'Tap to select parking footage',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'Your file stays in your secure evidence storage',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xFF64748B),
                        ),
                      ),
                    ],
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const CircleAvatar(
                        radius: 25,
                        backgroundColor: Color(0xFFE6F8EE),
                        child: Icon(
                          Icons.movie_outlined,
                          color: Color(0xFF16834A),
                          size: 27,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Text(
                          videoName!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      const SizedBox(height: 5),
                      TextButton(
                        onPressed: onPick,
                        child: const Text('Choose a different video'),
                      ),
                    ],
                  ),
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: analysing ? null : onAnalyse,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          icon: analysing
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.play_arrow_rounded),
          label: Text(
            analysing ? 'Analysing vehicle activity...' : 'Start analysis',
          ),
        ),
        const SizedBox(height: 9),
        const Text(
          'Demo mode shows a simulated evidence result. Connect the Azure processing API for real analysis.',
          style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
        ),
      ],
    ),
  );
}

class _RtspCard extends StatelessWidget {
  const _RtspCard({
    required this.controller,
    required this.streamUrl,
    required this.discovering,
    required this.onConnect,
    required this.onDisconnect,
    required this.onDiscover,
    required this.updatingWifi,
    required this.onConfigureWifi,
    this.onFrame,
    this.onOpenCamera,
    this.zone,
  });
  final TextEditingController controller;
  final String? streamUrl;
  final bool discovering;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;
  final VoidCallback onDiscover;
  final bool updatingWifi;
  final VoidCallback onConfigureWifi;
  final ValueChanged<List<int>>? onFrame;
  final VoidCallback? onOpenCamera;
  final ParkingZone? zone;
  @override
  Widget build(BuildContext context) => _Panel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _PanelTitle(
          icon: Icons.sensors_outlined,
          title: 'Live ESP32-CAM',
          subtitle: 'Play the camera\'s HTTP MJPEG stream',
        ),
        const SizedBox(height: 18),
        if (onOpenCamera != null) ...[
          OutlinedButton.icon(
            onPressed: onOpenCamera,
            icon: const Icon(Icons.videocam),
            label: Text(
              streamUrl == null
                  ? 'Open automatic scanner'
                  : 'View live automatic scanner',
            ),
          ),
          const SizedBox(height: 14),
        ],
        if (streamUrl != null && onOpenCamera == null) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: AspectRatio(
              aspectRatio: 4 / 3,
              child: ColoredBox(
                color: Colors.black,
                child: _LiveCameraView(
                  key: ValueKey(streamUrl),
                  streamUrl: streamUrl!,
                  onFrame: onFrame,
                  zone: zone,
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
        ],
        TextField(
          controller: controller,
          keyboardType: TextInputType.url,
          onSubmitted: (_) => onConnect(),
          decoration: const InputDecoration(
            labelText: 'ESP32-CAM address',
            hintText: '192.168.1.50 or http://192.168.1.50:81/stream',
            prefixIcon: Icon(Icons.link),
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 13),
        FilledButton.icon(
          onPressed: streamUrl == null ? onConnect : onDisconnect,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          icon: Icon(streamUrl == null ? Icons.play_arrow : Icons.stop),
          label: Text(
            streamUrl == null ? 'Start live video' : 'Stop live video',
          ),
        ),
        const SizedBox(height: 9),
        OutlinedButton.icon(
          onPressed: discovering ? null : onDiscover,
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(44),
          ),
          icon: discovering
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.wifi_find),
          label: Text(
            discovering ? 'Searching nearby cameras...' : 'Find automatically',
          ),
        ),
        const SizedBox(height: 9),
        OutlinedButton.icon(
          onPressed: streamUrl == null || updatingWifi ? null : onConfigureWifi,
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(44),
          ),
          icon: updatingWifi
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.wifi_password_outlined),
          label: Text(
            updatingWifi ? 'Saving Wi-Fi settings...' : 'Change camera Wi-Fi',
          ),
        ),
        const SizedBox(height: 20),
        const Divider(),
        const SizedBox(height: 9),
        const Row(
          children: [
            Icon(Icons.shield_outlined, size: 17, color: Color(0xFF64748B)),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'The phone and ESP32-CAM must be on the same Wi-Fi network. Image analysis runs in Azure; keep this app open.',
                style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

class _ResultsPage extends StatelessWidget {
  const _ResultsPage({
    required this.showResult,
    this.ocrResult,
    this.onRetryOcr,
  });
  final bool showResult;
  final PlateOcrResult? ocrResult;
  final VoidCallback? onRetryOcr;
  @override
  Widget build(BuildContext context) => _Page(
    child: ListView(
      children: [
        const Text(
          'Review results',
          style: TextStyle(
            fontSize: 29,
            fontWeight: FontWeight.w800,
            letterSpacing: -.7,
          ),
        ),
        const SizedBox(height: 7),
        Text(
          ocrResult != null
              ? 'Vehicle number OCR demo from your ESP32-CAM.'
              : showResult
              ? 'One simulated review item was created from your selected video.'
              : 'Your completed analyses and live-camera alerts will appear here.',
        ),
        const SizedBox(height: 24),
        if (ocrResult != null)
          _PlateOcrEvidence(result: ocrResult!, onRetry: onRetryOcr)
        else if (showResult)
          const _ViolationEvidence()
        else
          const _EmptyResults(),
      ],
    ),
  );
}

class _PlateOcrEvidence extends StatelessWidget {
  const _PlateOcrEvidence({required this.result, this.onRetry});
  final PlateOcrResult result;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final candidates = result.candidates;
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Vehicle number · OCR demo',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 14),
          SelectableText(
            candidates.isNotEmpty
                ? candidates.join(' / ')
                : result.rawText.isEmpty
                ? 'No text detected'
                : 'Text detected — check the reading below',
            style: const TextStyle(
              fontSize: 27,
              fontWeight: FontWeight.w800,
              color: Color(0xFF2155D9),
            ),
          ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: result.parkingZone != null
                  ? const Color(0xFFFFF4CE)
                  : result.noParkingViolation
                  ? const Color(0xFFFFE8E7)
                  : const Color(0xFFE6F8EE),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              result.parkingPosition != null
                  ? (result.noParkingViolation
                        ? 'INSIDE BAY - Fine Rs ${result.fineAmount}'
                        : 'OUTSIDE BAY - NO FINE')
                  : result.parkingZone != null
                  ? 'Plate observed in no-parking bay - review required'
                  : result.noParkingViolation
                  ? 'NO PARKING VIOLATION · Fine Rs ${result.fineAmount}'
                  : result.redZoneDetected
                  ? 'NORMAL PARKING · No fine'
                  : 'Parking status not confirmed',
              style: TextStyle(
                color: result.parkingZone != null
                    ? const Color(0xFF795500)
                    : result.noParkingViolation
                    ? const Color(0xFFB42318)
                    : const Color(0xFF16834A),
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            result.rawText.isEmpty
                ? 'Move the page closer, use good lighting and keep the letters upright. Then try again.'
                : 'Image-analyzer demo decision. Verify the image; this does not issue a legal fine or verify registration.',
          ),
          const SizedBox(height: 18),
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.memory(
              result.frame.jpeg,
              fit: BoxFit.contain,
              width: double.infinity,
              height: 260,
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            'Recognized text',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          SelectableText(
            result.rawText.isEmpty
                ? 'No readable text in this frame.'
                : result.rawText,
          ),
          const SizedBox(height: 8),
          Text(
            'Captured: ${result.frame.capturedAt.toLocal().toString().split('.').first}',
            style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
          ),
          const SizedBox(height: 4),
          Text(
            'OCR: ${result.provider}',
            style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.camera_alt_outlined),
            label: const Text('Scan another number'),
          ),
        ],
      ),
    );
  }
}

class _ViolationEvidence extends StatelessWidget {
  const _ViolationEvidence();
  @override
  Widget build(BuildContext context) => _Panel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const CircleAvatar(
              backgroundColor: Color(0xFFFFE8E7),
              child: Icon(
                Icons.warning_amber_rounded,
                color: Color(0xFFD92D20),
              ),
            ),
            const SizedBox(width: 11),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'AI vehicle review',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                  ),
                  Text(
                    'Demo result · awaiting review',
                    style: TextStyle(color: Color(0xFF64748B), fontSize: 12),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFFFFE8E7),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Text(
                'REVIEW',
                style: TextStyle(
                  color: Color(0xFFB42318),
                  fontWeight: FontWeight.w800,
                  fontSize: 11,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        Container(
          height: 0,
          width: double.infinity,
          decoration: BoxDecoration(
            color: const Color(0xFF172033),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Stack(
            children: [
              Positioned.fill(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Image.asset(
                    '.test_frames/frame_150s.jpg',
                    fit: BoxFit.cover,
                  ),
                ),
              ),
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: .14),
                  ),
                ),
              ),
              Positioned(
                left: 18,
                top: 18,
                child: Container(
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: const Color(0xFFFF4438),
                      width: 3,
                    ),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const SizedBox(width: 130, height: 90),
                ),
              ),
              Positioned(
                left: 20,
                top: 119,
                child: Container(
                  color: const Color(0xFFFF4438),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: const Text(
                    'Vehicle #12 · 94%',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 11,
                    ),
                  ),
                ),
              ),
              const Positioned(
                top: 12,
                right: 12,
                child: _VideoChip('00:01:43'),
              ),
              const Positioned(
                bottom: 12,
                left: 12,
                child: _VideoChip('Restricted zone A'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        const Text(
          'Detected vehicles',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, constraints) => GridView.count(
            crossAxisCount: constraints.maxWidth > 720 ? 4 : 2,
            childAspectRatio: .66,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            children: [
              _VehicleCard(
                asset: '.test_frames/vehicles/utility_truck.jpg',
                id: '#01',
                type: 'Utility truck',
                colour: 'White',
                confidence: '96%',
                review: false,
              ),
              _VehicleCard(
                asset: '.test_frames/vehicles/red_pickup.jpg',
                id: '#12',
                type: 'Pickup truck',
                colour: 'Red',
                confidence: '94%',
                review: true,
              ),
              _VehicleCard(
                asset: '.test_frames/vehicles/silver_sedan.jpg',
                id: '#08',
                type: 'Sedan',
                colour: 'Silver',
                confidence: '92%',
                review: false,
              ),
              _VehicleCard(
                asset: '.test_frames/vehicles/black_suv.jpg',
                id: '#05',
                type: 'SUV',
                colour: 'Black',
                confidence: '91%',
                review: false,
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        const Wrap(
          spacing: 26,
          runSpacing: 12,
          children: [
            _Detail(label: 'Vehicle', value: 'Car · ID #12'),
            _Detail(label: 'Time in zone', value: '01:43'),
            _Detail(label: 'Plate OCR', value: 'Needs review'),
            _Detail(label: 'Confidence', value: '94%'),
            _Detail(label: 'Demo fine', value: 'Rs 500'),
          ],
        ),
        const SizedBox(height: 18),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            FilledButton.icon(
              onPressed: () {},
              icon: const Icon(Icons.check),
              label: const Text('Confirm violation'),
            ),
            OutlinedButton.icon(
              onPressed: () {},
              icon: const Icon(Icons.close),
              label: const Text('Dismiss'),
            ),
          ],
        ),
      ],
    ),
  );
}

class _VehicleCard extends StatelessWidget {
  const _VehicleCard({
    required this.asset,
    required this.id,
    required this.type,
    required this.colour,
    required this.confidence,
    required this.review,
  });
  final String asset, id, type, colour, confidence;
  final bool review;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: () => _openDetail(context),
    borderRadius: BorderRadius.circular(18),
    child: _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: AspectRatio(
              aspectRatio: 1.42,
              child: Image.asset(asset, fit: BoxFit.cover),
            ),
          ),
          const SizedBox(height: 9),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Vehicle $id',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              Icon(
                review ? Icons.warning_amber_rounded : Icons.check_circle,
                color: review
                    ? const Color(0xFFD92D20)
                    : const Color(0xFF16834A),
                size: 18,
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            type,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          ),
          Text(
            '$colour · $confidence',
            style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)),
          ),
          const Spacer(),
          Text(
            review ? 'REVIEW ZONE A' : 'NO VIOLATION',
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w800,
              color: review ? const Color(0xFFB42318) : const Color(0xFF16834A),
            ),
          ),
        ],
      ),
    ),
  );

  void _openDetail(BuildContext context) => showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
    ),
    builder: (_) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 12, 22, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFCBD5E1),
                  borderRadius: BorderRadius.circular(9),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Vehicle $id details',
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Image.asset(
                asset,
                height: 230,
                width: double.infinity,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(height: 18),
            Wrap(
              spacing: 32,
              runSpacing: 16,
              children: [
                _Detail(label: 'Vehicle type', value: type),
                _Detail(label: 'Estimated colour', value: colour),
                _Detail(label: 'AI confidence', value: confidence),
                _Detail(
                  label: 'Status',
                  value: review ? 'Review zone A' : 'No violation',
                ),
              ],
            ),
            const SizedBox(height: 20),
            if (review)
              FilledButton.icon(
                onPressed: () => Navigator.pop(context),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                icon: const Icon(Icons.check),
                label: const Text('Confirm parking violation'),
              )
            else
              OutlinedButton(
                onPressed: () => Navigator.pop(context),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                child: const Text('Close vehicle details'),
              ),
          ],
        ),
      ),
    ),
  );
}

class _CamerasPage extends StatelessWidget {
  const _CamerasPage({
    super.key,
    required this.controller,
    required this.streamUrl,
    required this.discovering,
    required this.onConnect,
    required this.onDisconnect,
    required this.onDiscover,
    required this.updatingWifi,
    required this.onConfigureWifi,
    required this.onFrame,
    required this.cameraReady,
    required this.readingPlate,
    required this.scanStatus,
    required this.onReadPlate,
    required this.autoScanning,
    required this.onAutoScanningChanged,
    required this.lastPlate,
    required this.lcdStatus,
    required this.archiveStatus,
    required this.zone,
    required this.onMarkZone,
  });
  final TextEditingController controller;
  final String? streamUrl;
  final bool discovering;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;
  final VoidCallback onDiscover;
  final bool updatingWifi;
  final VoidCallback onConfigureWifi;
  final ValueChanged<List<int>> onFrame;
  final bool cameraReady;
  final bool readingPlate;
  final String scanStatus;
  final VoidCallback onReadPlate;
  final bool autoScanning;
  final ValueChanged<bool> onAutoScanningChanged;
  final String? lastPlate;
  final String lcdStatus;
  final String archiveStatus;
  final ParkingZone? zone;
  final VoidCallback onMarkZone;
  @override
  Widget build(BuildContext context) => _Page(
    child: ListView(
      children: [
        const Text(
          'Cameras',
          style: TextStyle(fontSize: 29, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 7),
        const Text(
          'Connect an ESP32-CAM to watch its live MJPEG feed in ParkGuard.',
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: cameraReady ? onMarkZone : null,
          icon: const Icon(Icons.crop_free),
          label: Text(
            zone == null ? 'Mark no-parking bay' : 'Redraw no-parking bay',
          ),
        ),
        Text(
          zone == null
              ? 'Mark all 4 corners once. Scanning waits until the bay is saved.'
              : 'Vehicle overlaps bay: fine. Completely outside: no fine. Redraw if the camera moves.',
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Automatic image analysis'),
          subtitle: const Text(
            'Checks on movement and every 30 seconds, even when still. Live video continues.',
          ),
          value: autoScanning,
          onChanged: onAutoScanningChanged,
        ),
        // Keep the camera panel's list index stable when the first result arrives.
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (lastPlate != null) ...[
              Text(
                'Last confirmed: $lastPlate',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(lcdStatus),
              Text(archiveStatus),
              const SizedBox(height: 10),
            ],
          ],
        ),
        Text(
          cameraReady
              ? '$scanStatus. Only confirmed numbers are sent to Results and the LCD.'
              : 'Waiting for the live camera. Connect it below before scanning.',
        ),
        const SizedBox(height: 10),
        FilledButton.icon(
          onPressed: cameraReady && zone != null && !readingPlate
              ? onReadPlate
              : null,
          icon: const Icon(Icons.document_scanner_outlined),
          label: Text(
            readingPlate ? 'Analyzing image...' : 'Analyze vehicle image',
          ),
        ),
        const SizedBox(height: 20),
        _RtspCard(
          onFrame: onFrame,
          zone: zone,
          controller: controller,
          streamUrl: streamUrl,
          discovering: discovering,
          onConnect: onConnect,
          onDisconnect: onDisconnect,
          onDiscover: onDiscover,
          updatingWifi: updatingWifi,
          onConfigureWifi: onConfigureWifi,
        ),
      ],
    ),
  );
}

class _WifiCredentials {
  const _WifiCredentials(this.ssid, this.password);

  final String ssid;
  final String password;
}

class _WifiCredentialsDialog extends StatefulWidget {
  const _WifiCredentialsDialog();

  @override
  State<_WifiCredentialsDialog> createState() => _WifiCredentialsDialogState();
}

class _WifiCredentialsDialogState extends State<_WifiCredentialsDialog> {
  final _formKey = GlobalKey<FormState>();
  final _ssidController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _showPassword = false;

  @override
  void dispose() {
    _ssidController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(
      context,
      _WifiCredentials(_ssidController.text.trim(), _passwordController.text),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Change camera Wi-Fi'),
    content: Form(
      key: _formKey,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter the network the ESP32-CAM should use. The camera will restart after saving.',
            ),
            const SizedBox(height: 18),
            TextFormField(
              controller: _ssidController,
              autofocus: true,
              maxLength: 32,
              decoration: const InputDecoration(
                labelText: 'Wi-Fi name (SSID)',
                prefixIcon: Icon(Icons.wifi),
                border: OutlineInputBorder(),
              ),
              validator: (value) => value == null || value.trim().isEmpty
                  ? 'Enter the Wi-Fi name.'
                  : null,
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _passwordController,
              obscureText: !_showPassword,
              maxLength: 63,
              decoration: InputDecoration(
                labelText: 'Wi-Fi password',
                helperText:
                    'Use 8-63 characters, or leave empty for open Wi-Fi.',
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  onPressed: () =>
                      setState(() => _showPassword = !_showPassword),
                  icon: Icon(
                    _showPassword ? Icons.visibility_off : Icons.visibility,
                  ),
                ),
                border: const OutlineInputBorder(),
              ),
              validator: (value) =>
                  value != null && value.isNotEmpty && value.length < 8
                  ? 'Password must contain at least 8 characters.'
                  : null,
              onFieldSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 8),
            const Text(
              'If connection fails, join ParkGuard-Setup (password: parkguard123) and use 192.168.4.1 to recover.',
              style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _save, child: const Text('Save and restart')),
    ],
  );
}

class _LiveBadge extends StatelessWidget {
  const _LiveBadge();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(
      color: const Color(0xFFD92D20),
      borderRadius: BorderRadius.circular(5),
    ),
    child: const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.circle, color: Colors.white, size: 8),
        SizedBox(width: 5),
        Text(
          'LIVE',
          style: TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    ),
  );
}

class _LiveCameraView extends StatefulWidget {
  const _LiveCameraView({
    super.key,
    required this.streamUrl,
    this.onFrame,
    this.zone,
  });

  final String streamUrl;
  final ValueChanged<List<int>>? onFrame;
  final ParkingZone? zone;

  @override
  State<_LiveCameraView> createState() => _LiveCameraViewState();
}

class _LiveCameraViewState extends State<_LiveCameraView>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        LiveCameraStream(
          url: widget.streamUrl,
          onFrame: (frame) => widget.onFrame?.call(frame),
          onUnavailable: () => widget.onFrame?.call(const []),
        ),
        if (widget.zone case final zone?)
          IgnorePointer(
            child: CustomPaint(
              painter: ParkingZonePainter(zone.points, zone.aspectRatio),
            ),
          ),
        const Positioned(top: 10, left: 10, child: _LiveBadge()),
        Positioned(
          top: 10,
          right: 10,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 190),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: .68),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(
              'Image analyzer',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SideRail extends StatelessWidget {
  const _SideRail({required this.selected, required this.onSelected});
  final int selected;
  final ValueChanged<int> onSelected;
  @override
  Widget build(BuildContext context) => Container(
    width: 230,
    color: Colors.white,
    child: Column(
      children: [
        const SizedBox(height: 20),
        _NavItem(
          icon: Icons.add_circle_outline,
          label: 'New analysis',
          active: selected == 0,
          onTap: () => onSelected(0),
        ),
        _NavItem(
          icon: Icons.warning_amber_outlined,
          label: 'Review results',
          active: selected == 1,
          onTap: () => onSelected(1),
        ),
        _NavItem(
          icon: Icons.videocam_outlined,
          label: 'Cameras',
          active: selected == 2,
          onTap: () => onSelected(2),
        ),
        const Spacer(),
        const Padding(padding: EdgeInsets.all(18), child: _HelpCard()),
      ],
    ),
  );
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
    child: ListTile(
      onTap: onTap,
      selected: active,
      selectedTileColor: const Color(0xFFE8EEFF),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      leading: Icon(
        icon,
        color: active ? const Color(0xFF2155D9) : const Color(0xFF53627C),
      ),
      title: Text(
        label,
        style: TextStyle(
          fontWeight: active ? FontWeight.w800 : FontWeight.w500,
        ),
      ),
    ),
  );
}

class _LogoMark extends StatelessWidget {
  const _LogoMark();
  @override
  Widget build(BuildContext context) => const CircleAvatar(
    radius: 17,
    backgroundColor: Color(0xFF2155D9),
    child: Icon(Icons.local_parking_rounded, color: Colors.white),
  );
}

class _OnlineBadge extends StatelessWidget {
  const _OnlineBadge({this.compact = false});
  final bool compact;
  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'System online',
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFFE6F8EE),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.circle, size: 8, color: Color(0xFF16834A)),
          if (!compact) ...[
            const SizedBox(width: 5),
            const Text(
              'System online',
              style: TextStyle(
                fontSize: 11,
                color: Color(0xFF16834A),
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ],
      ),
    ),
  );
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Card(
    elevation: 0,
    color: Colors.white,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(18),
      side: const BorderSide(color: Color(0xFFE3E8F1)),
    ),
    child: Padding(padding: const EdgeInsets.all(20), child: child),
  );
}

class _PanelTitle extends StatelessWidget {
  const _PanelTitle({
    required this.icon,
    required this.title,
    required this.subtitle,
  });
  final IconData icon;
  final String title, subtitle;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      CircleAvatar(
        backgroundColor: const Color(0xFFE8EEFF),
        child: Icon(icon, color: const Color(0xFF2155D9)),
      ),
      const SizedBox(width: 11),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
            ),
            Text(
              subtitle,
              style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
            ),
          ],
        ),
      ),
    ],
  );
}

class _Step extends StatelessWidget {
  const _Step(this.number, this.icon, this.title, this.subtitle);
  final String number, title, subtitle;
  final IconData icon;
  @override
  Widget build(BuildContext context) => _Panel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          number,
          style: const TextStyle(
            color: Color(0xFF2155D9),
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 7),
        Icon(icon, color: const Color(0xFF2155D9)),
        const Spacer(),
        Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(height: 3),
        Text(
          subtitle,
          style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)),
        ),
      ],
    ),
  );
}

class _VideoChip extends StatelessWidget {
  const _VideoChip(this.label);
  final String label;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
    decoration: BoxDecoration(
      color: Colors.black54,
      borderRadius: BorderRadius.circular(5),
    ),
    child: Text(
      label,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 11,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

class _Detail extends StatelessWidget {
  const _Detail({required this.label, required this.value});
  final String label, value;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label.toUpperCase(),
        style: const TextStyle(
          fontSize: 10,
          color: Color(0xFF64748B),
          fontWeight: FontWeight.w700,
        ),
      ),
      const SizedBox(height: 3),
      Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
    ],
  );
}

class _EmptyResults extends StatelessWidget {
  const _EmptyResults();
  @override
  Widget build(BuildContext context) => _Panel(
    child: SizedBox(
      height: 240,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: const [
          CircleAvatar(
            radius: 31,
            backgroundColor: Color(0xFFE8EEFF),
            child: Icon(
              Icons.inbox_outlined,
              size: 33,
              color: Color(0xFF2155D9),
            ),
          ),
          SizedBox(height: 14),
          Text(
            'No results yet',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          SizedBox(height: 5),
          Text('Upload a video or connect a camera to begin.'),
        ],
      ),
    ),
  );
}

class _HelpCard extends StatelessWidget {
  const _HelpCard();
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: const Color(0xFFF2F5FF),
      borderRadius: BorderRadius.circular(14),
    ),
    child: const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.tips_and_updates_outlined, color: Color(0xFF2155D9)),
        SizedBox(height: 8),
        Text('Operator tip', style: TextStyle(fontWeight: FontWeight.w800)),
        SizedBox(height: 4),
        Text(
          'Draw a restricted zone before enabling enforcement.',
          style: TextStyle(fontSize: 11, color: Color(0xFF53627C)),
        ),
      ],
    ),
  );
}

class _Page extends StatelessWidget {
  const _Page({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.all(28), child: child);
}

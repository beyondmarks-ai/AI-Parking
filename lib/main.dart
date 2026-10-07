import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() => runApp(const ParkGuardApp());

class ParkGuardApp extends StatelessWidget {
  const ParkGuardApp({super.key});

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
    home: const OperatorHome(),
  );
}

class OperatorHome extends StatefulWidget {
  const OperatorHome({super.key});
  @override
  State<OperatorHome> createState() => _OperatorHomeState();
}

class _OperatorHomeState extends State<OperatorHome> {
  static const _videoPicker = MethodChannel('parkguard/video_picker');
  int _tab = 0;
  String? _videoName;
  bool _analysing = false;
  bool _hasResult = false;
  final _rtspController = TextEditingController();

  @override
  void dispose() {
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
      _tab = 1;
    });
  }

  void _testRtsp() {
    final value = _rtspController.text.trim();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          value.startsWith('rtsp://') || value.startsWith('rtsps://')
              ? 'RTSP URL saved. Connect the video worker to test the live feed.'
              : 'Enter a valid RTSP URL beginning with rtsp:// or rtsps://',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.sizeOf(context).width >= 860;
    final pages = [
      _WorkSpace(
        videoName: _videoName,
        analysing: _analysing,
        onPick: _chooseVideo,
        onAnalyse: _analyse,
        rtspController: _rtspController,
        onTestRtsp: _testRtsp,
      ),
      _ResultsPage(showResult: _hasResult),
      _CamerasPage(controller: _rtspController, onTest: _testRtsp),
    ];
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        title: const Row(
          children: [
            _LogoMark(),
            SizedBox(width: 10),
            Text(
              'ParkGuard',
              style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: -.4),
            ),
            Text(
              ' AI',
              style: TextStyle(
                color: Color(0xFF2155D9),
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
        actions: const [
          _OnlineBadge(),
          SizedBox(width: 16),
          CircleAvatar(
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
          SizedBox(width: 20),
        ],
      ),
      body: isWide
          ? Row(
              children: [
                _SideRail(
                  selected: _tab,
                  onSelected: (value) => setState(() => _tab = value),
                ),
                Expanded(child: pages[_tab]),
              ],
            )
          : pages[_tab],
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
    required this.videoName,
    required this.analysing,
    required this.onPick,
    required this.onAnalyse,
    required this.rtspController,
    required this.onTestRtsp,
  });
  final String? videoName;
  final bool analysing;
  final VoidCallback onPick;
  final VoidCallback onAnalyse;
  final TextEditingController rtspController;
  final VoidCallback onTestRtsp;

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
                        controller: rtspController,
                        onTest: onTestRtsp,
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
                    _RtspCard(controller: rtspController, onTest: onTestRtsp),
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
            height: 170,
            width: double.infinity,
            decoration: BoxDecoration(
              color: const Color(0xFFF6F8FF),
              border: Border.all(color: const Color(0xFFB7C8FF), width: 1.4),
              borderRadius: BorderRadius.circular(14),
            ),
            child: videoName == null
                ? const Column(
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
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'Your file stays in your secure evidence storage',
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xFF64748B),
                        ),
                      ),
                    ],
                  )
                : Column(
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
  const _RtspCard({required this.controller, required this.onTest});
  final TextEditingController controller;
  final VoidCallback onTest;
  @override
  Widget build(BuildContext context) => _Panel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _PanelTitle(
          icon: Icons.sensors_outlined,
          title: 'Live RTSP camera',
          subtitle: 'Connect an IP camera or NVR stream',
        ),
        const SizedBox(height: 25),
        TextField(
          controller: controller,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: 'RTSP stream URL',
            hintText: 'rtsp://user:password@camera-ip:554/stream',
            prefixIcon: Icon(Icons.link),
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 13),
        OutlinedButton.icon(
          onPressed: onTest,
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
          ),
          icon: const Icon(Icons.network_ping_outlined),
          label: const Text('Test camera connection'),
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
                'RTSP credentials are stored securely and are never shown in reports.',
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
  const _ResultsPage({required this.showResult});
  final bool showResult;
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
          showResult
              ? 'One simulated review item was created from your selected video.'
              : 'Your completed analyses and live-camera alerts will appear here.',
        ),
        const SizedBox(height: 24),
        if (showResult) const _ViolationEvidence() else const _EmptyResults(),
      ],
    ),
  );
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
  const _CamerasPage({required this.controller, required this.onTest});
  final TextEditingController controller;
  final VoidCallback onTest;
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
          'Add an RTSP-compatible IP camera to begin live monitoring.',
        ),
        const SizedBox(height: 24),
        _RtspCard(controller: controller, onTest: onTest),
      ],
    ),
  );
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
  const _OnlineBadge();
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(
      color: const Color(0xFFE6F8EE),
      borderRadius: BorderRadius.circular(14),
    ),
    child: const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.circle, size: 8, color: Color(0xFF16834A)),
        SizedBox(width: 5),
        Text(
          'System online',
          style: TextStyle(
            fontSize: 11,
            color: Color(0xFF16834A),
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
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
      Column(
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

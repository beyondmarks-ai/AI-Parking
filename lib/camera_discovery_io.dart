import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart';
import 'package:http/io_client.dart';
import 'package:multicast_dns/multicast_dns.dart';

const _serviceName = '_parkguard-cam._tcp.local';
InternetAddress? _cameraSourceAddress;

InternetAddress? selectCameraSourceAddress(
  String host,
  Iterable<InternetAddress> localAddresses, {
  InternetAddress? advertisedSource,
}) {
  final addresses = localAddresses
      .where((address) => address.type == InternetAddressType.IPv4)
      .toList();
  for (final address in addresses) {
    if (address.address == advertisedSource?.address) return address;
  }
  final target = InternetAddress.tryParse(host);
  if (target?.type != InternetAddressType.IPv4 ||
      !_isPrivateAddress(target!.address.split('.'))) {
    return null;
  }
  // ESP32 phone hotspots use /24 networks. Prefer this phone's own address
  // on that network, including for standard firmware with no announcements.
  // Other subnet layouts keep the OS-selected route unless advertised above.
  for (final address in addresses) {
    if (address.rawAddress[0] == target.rawAddress[0] &&
        address.rawAddress[1] == target.rawAddress[1] &&
        address.rawAddress[2] == target.rawAddress[2]) {
      return address;
    }
  }
  return null;
}

Client createCameraHttpClient() {
  final ioClient = HttpClient()..findProxy = (_) => 'DIRECT';
  ioClient.connectionFactory = (uri, proxyHost, proxyPort) async {
    // The announcement contains the camera's gateway. Only the phone hosting
    // that hotspot owns this address; other phones must use their normal route.
    // Check at connection time so a Wi-Fi change cannot leave a stale binding.
    final advertisedSource = _cameraSourceAddress;
    InternetAddress? sourceAddress;
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: true,
      );
      sourceAddress = selectCameraSourceAddress(
        uri.host,
        interfaces.expand((interface) => interface.addresses),
        advertisedSource: advertisedSource,
      );
    } on SocketException {
      // If interface inspection is unavailable, let the OS select the route.
    }
    return Socket.startConnect(
      uri.host,
      uri.port,
      sourceAddress: sourceAddress,
    );
  };
  return IOClient(ioClient);
}

Future<String?> discoverParkGuardCamera() async {
  _cameraSourceAddress = null;
  final announcementResult = await _waitForCameraAnnouncement();
  if (announcementResult != null) return announcementResult;

  final broadcastResult = await _discoverWithBroadcast();
  if (broadcastResult != null) return broadcastResult;

  final scanResult = await _discoverOnLocalSubnets();
  if (scanResult != null) return scanResult;

  final client = MDnsClient();
  try {
    await client.start();
    final pointer = await client
        .lookup<PtrResourceRecord>(
          ResourceRecordQuery.serverPointer(_serviceName),
          timeout: const Duration(seconds: 4),
        )
        .first;
    final service = await client
        .lookup<SrvResourceRecord>(
          ResourceRecordQuery.service(pointer.domainName),
          timeout: const Duration(seconds: 3),
        )
        .first;
    final address = await client
        .lookup<IPAddressResourceRecord>(
          ResourceRecordQuery.addressIPv4(service.target),
          timeout: const Duration(seconds: 3),
        )
        .first;
    return Uri(
      scheme: 'http',
      host: address.address.address,
      port: service.port,
      path: '/stream',
    ).toString();
  } on Object {
    return null;
  } finally {
    client.stop();
  }
}

Future<String?> _waitForCameraAnnouncement() async {
  RawDatagramSocket? socket;
  StreamSubscription<RawSocketEvent>? subscription;
  try {
    socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      4211,
      reuseAddress: true,
    );
    final result = Completer<String?>();
    subscription = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? datagram;
      while ((datagram = socket?.receive()) != null) {
        final url = _cameraUrlFromPacket(datagram!.data);
        if (url != null && !result.isCompleted) result.complete(url);
      }
    });
    return await result.future.timeout(
      const Duration(seconds: 3),
      onTimeout: () => null,
    );
  } on Object {
    return null;
  } finally {
    await subscription?.cancel();
    socket?.close();
  }
}

String? _cameraUrlFromPacket(List<int> data) {
  final message = utf8.decode(data, allowMalformed: true).trim();
  const prefix = 'PARKGUARD_CAM ';
  if (!message.startsWith(prefix)) return null;
  final values = message.substring(prefix.length).trim().split(RegExp(r'\s+'));
  final uri = Uri.tryParse(values.first);
  if (uri == null ||
      uri.host.isEmpty ||
      (uri.scheme != 'http' && uri.scheme != 'https')) {
    return null;
  }
  final source = values.length > 1 ? InternetAddress.tryParse(values[1]) : null;
  _cameraSourceAddress = source?.type == InternetAddressType.IPv4
      ? source
      : null;
  // ESP32 CameraWebServer exposes controls on port 80 and MJPEG on 81.
  // Some custom announcements omit the stream port even though they retain
  // this standard split, which otherwise causes an endless reconnect loop.
  return uri.path == '/stream' && !uri.hasPort
      ? uri.replace(port: 81).toString()
      : uri.toString();
}

Future<String?> _discoverOnLocalSubnets() async {
  final prefixes = <String>{};
  try {
    for (final interface in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    )) {
      for (final address in interface.addresses) {
        final octets = address.address.split('.');
        if (octets.length != 4 || !_isPrivateAddress(octets)) continue;
        prefixes.add('${octets[0]}.${octets[1]}.${octets[2]}');
      }
    }

    final orderedPrefixes = prefixes.toList()
      ..sort(
        (a, b) => a.startsWith('10.')
            ? -1
            : (b.startsWith('10.') ? 1 : a.compareTo(b)),
      );
    final candidates = <String>[
      for (final prefix in orderedPrefixes)
        for (var host = 1; host < 255; host++) '$prefix.$host',
    ];
    const batchSize = 128;
    for (var start = 0; start < candidates.length; start += batchSize) {
      final end = (start + batchSize).clamp(0, candidates.length);
      final results = await Future.wait(
        candidates.sublist(start, end).map(_probeEsp32Camera),
      );
      for (final result in results) {
        if (result != null) return result;
      }
    }
  } on Object {
    return null;
  }
  return null;
}

bool _isPrivateAddress(List<String> octets) {
  final first = int.tryParse(octets[0]);
  final second = int.tryParse(octets[1]);
  return first == 10 ||
      (first == 192 && second == 168) ||
      (first == 172 && second != null && second >= 16 && second <= 31);
}

Future<String?> _probeEsp32Camera(String address) async {
  final client = createCameraHttpClient();
  try {
    final response = await client
        .send(
          Request('GET', Uri(scheme: 'http', host: address, path: '/capture')),
        )
        .timeout(const Duration(seconds: 3));
    if (response.statusCode == HttpStatus.ok &&
        response.headers['content-type']?.split(';').first.trim() ==
            'image/jpeg') {
      // Cameras found through the standard capture endpoint use port 81 for
      // MJPEG. Custom firmware can advertise a different URL via UDP or mDNS.
      return 'http://$address:81/stream';
    }
  } on Object {
    return null;
  } finally {
    client.close();
  }
  return null;
}

Future<String?> _discoverWithBroadcast() async {
  RawDatagramSocket? socket;
  StreamSubscription<RawSocketEvent>? subscription;
  try {
    socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.broadcastEnabled = true;
    final result = Completer<String?>();
    subscription = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? datagram;
      while ((datagram = socket?.receive()) != null) {
        final url = _cameraUrlFromPacket(datagram!.data);
        if (url != null && !result.isCompleted) result.complete(url);
      }
    });

    final targets = <String>{'255.255.255.255'};
    for (final interface in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    )) {
      for (final address in interface.addresses) {
        final octets = address.address.split('.');
        if (octets.length == 4) {
          octets[3] = '255';
          targets.add(octets.join('.'));
        }
      }
    }

    final request = utf8.encode('PARKGUARD_DISCOVER');
    for (final target in targets) {
      socket.send(request, InternetAddress(target), 4210);
    }
    return await result.future.timeout(
      const Duration(seconds: 3),
      onTimeout: () => null,
    );
  } on Object {
    return null;
  } finally {
    await subscription?.cancel();
    socket?.close();
  }
}

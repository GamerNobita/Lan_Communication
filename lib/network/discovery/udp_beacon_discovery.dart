import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

class Peer {
  final String id;
  String name;
  InternetAddress address;
  int port;
  DateTime lastSeen;

  Peer(this.id, this.name, this.address, this.port) : lastSeen = DateTime.now();
}

class UdpBeaconDiscovery {
  static const int discoveryPort = 45454;
  static const Duration beaconInterval = Duration(seconds: 3);
  static const Duration peerTimeout = Duration(seconds: 10);

  final String selfId;
  String selfName;
  final int tcpPort;

  /// IPs of known contacts. They also get our beacon directly (unicast),
  /// which still works when the Wi-Fi drops broadcast packets.
  final Set<String> extraTargets = <String>{};

  RawDatagramSocket? _socket;
  Timer? _beaconTimer;
  Timer? _sweepTimer;
  DateTime _lastSweep = DateTime.now();
  final Map<String, Peer> _peers = {};

  /// Live list of nearby devices (UI listens to this).
  final ValueNotifier<List<Peer>> peers = ValueNotifier<List<Peer>>([]);

  /// Newest-first debug log, shown inside the app.
  final ValueNotifier<List<String>> logs = ValueNotifier<List<String>>([]);

  UdpBeaconDiscovery({
    required this.selfId,
    required this.selfName,
    required this.tcpPort,
  });

  void _log(String msg) {
    final t = DateTime.now().toIso8601String().substring(11, 19);
    logs.value = ['$t  $msg', ...logs.value].take(60).toList();
  }

  Future<List<String>> localIps() async {
    final result = <String>[];
    try {
      final ifaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (final i in ifaces) {
        for (final a in i.addresses) {
          if (!a.isLoopback) result.add('${a.address} (${i.name})');
        }
      }
    } catch (e) {
      _log('could not read IPs: $e');
    }
    return result;
  }

  Future<void> start() async {
    try {
      _socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        discoveryPort,
        reuseAddress: true,
      );
      _socket!
        ..broadcastEnabled = true
        ..listen(_onEvent);
      _log('listening on UDP $discoveryPort');
    } catch (e) {
      _log('FAILED to open UDP socket: $e');
      return;
    }

    _beaconTimer = Timer.periodic(beaconInterval, (_) => _announce());
    _sweepTimer = Timer.periodic(const Duration(seconds: 4), (_) => _sweep());
    _announce();
  }

  Future<void> _announce() async {
    final socket = _socket;
    if (socket == null) return;

    final data = utf8.encode(jsonEncode({
      'v': 1,
      'type': 'hello',
      'id': selfId,
      'name': selfName,
      'port': tcpPort,
    }));

    final targets = <String>{'255.255.255.255', ...extraTargets};
    try {
      final ifaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (final i in ifaces) {
        for (final a in i.addresses) {
          if (a.isLoopback) continue;
          final p = a.address.split('.');
          if (p.length == 4) targets.add('${p[0]}.${p[1]}.${p[2]}.255');
        }
      }
    } catch (e) {
      _log('interface scan failed: $e');
    }

    for (final t in targets) {
      try {
        socket.send(data, InternetAddress(t), discoveryPort);
      } catch (e) {
        _log('send to $t failed: $e');
      }
    }
  }

  void _onEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final dg = _socket?.receive();
    if (dg == null) return;

    try {
      final msg = jsonDecode(utf8.decode(dg.data)) as Map<String, dynamic>;
      if (msg['type'] != 'hello' || msg['v'] != 1) return;

      final id = msg['id'] as String;
      if (id == selfId) return; // our own beacon

      final name = msg['name'] as String;
      final port = msg['port'] as int;
      final existing = _peers[id];

      if (existing != null) {
        existing.lastSeen = DateTime.now();
        if (existing.name != name ||
            existing.port != port ||
            existing.address.address != dg.address.address) {
          existing.name = name;
          existing.port = port;
          existing.address = dg.address;
          _publish();
        }
      } else {
        _peers[id] = Peer(id, name, dg.address, port);
        _log('found $name at ${dg.address.address}');
        _publish();
        _announce(); // answer quickly so the other side sees us fast
      }
    } catch (_) {
      // not our packet, ignore
    }
  }

  void _sweep() {
    final now = DateTime.now();
    final slept = now.difference(_lastSweep) > const Duration(seconds: 12);
    _lastSweep = now;
    if (slept) {
      // The phone was asleep: give everyone a fresh chance instead of dropping them.
      for (final p in _peers.values) {
        p.lastSeen = now;
      }
      return;
    }

    final cutoff = now.subtract(peerTimeout);
    final before = _peers.length;
    _peers.removeWhere((_, p) {
      final gone = p.lastSeen.isBefore(cutoff);
      if (gone) _log('lost ${p.name}');
      return gone;
    });
    if (_peers.length != before) _publish();
  }

  void _publish() => peers.value = List<Peer>.of(_peers.values);

  Future<void> stop() async {
    _beaconTimer?.cancel();
    _sweepTimer?.cancel();
    _socket?.close();
  }
}

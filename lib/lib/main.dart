import 'dart:math';

import 'package:flutter/material.dart';

import 'core/multicast_lock.dart';
import 'network/discovery/udp_beacon_discovery.dart';
import 'presentation/peers_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Android needs this lock to receive UDP broadcast packets.
  await MulticastLock.acquire();

  final rnd = Random.secure();
  final id = List.generate(
    16,
    (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  final name = 'Phone-${id.substring(0, 4)}';

  // tcpPort is 0 for now; the chat server comes in the next step.
  final discovery = UdpBeaconDiscovery(
    selfId: id,
    selfName: name,
    tcpPort: 0,
  );
  await discovery.start();

  runApp(MyApp(discovery: discovery, selfName: name));
}

class MyApp extends StatelessWidget {
  final UdpBeaconDiscovery discovery;
  final String selfName;

  const MyApp({super.key, required this.discovery, required this.selfName});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LAN Messenger',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
      home: PeersScreen(discovery: discovery, selfName: selfName),
    );
  }
}

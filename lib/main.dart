import 'dart:math';

import 'package:flutter/material.dart';

import 'core/multicast_lock.dart';
import 'network/transport/connection_manager.dart';
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

  final manager = ConnectionManager(selfId: id, selfName: name);
  await manager.start();

  runApp(MyApp(manager: manager, selfName: name));
}

class MyApp extends StatelessWidget {
  final ConnectionManager manager;
  final String selfName;

  const MyApp({super.key, required this.manager, required this.selfName});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LAN Messenger',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
      home: PeersScreen(manager: manager, selfName: selfName),
    );
  }
}

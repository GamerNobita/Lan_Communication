import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'core/multicast_lock.dart';
import 'core/native_bridge.dart';
import 'data/chat_store.dart';
import 'network/transport/connection_manager.dart';
import 'presentation/peers_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Android needs this lock to receive UDP broadcast packets.
  await MulticastLock.acquire();

  final dir = await getApplicationDocumentsDirectory();
  final store = await ChatStore.open(dir);

  final manager = ConnectionManager(store: store);
  await manager.start();

  if (store.backgroundEnabled) {
    await NativeBridge.startService();
  }

  runApp(MyApp(manager: manager));
}

class MyApp extends StatelessWidget {
  final ConnectionManager manager;

  const MyApp({super.key, required this.manager});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LAN Messenger',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
      home: PeersScreen(manager: manager),
    );
  }
}

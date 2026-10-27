import 'package:flutter/material.dart';

import '../network/discovery/udp_beacon_discovery.dart';
import '../network/transport/connection_manager.dart';
import 'chat_screen.dart';

class PeersScreen extends StatelessWidget {
  final ConnectionManager manager;
  final String selfName;

  const PeersScreen({super.key, required this.manager, required this.selfName});

  @override
  Widget build(BuildContext context) {
    final discovery = manager.discovery;

    return Scaffold(
      appBar: AppBar(title: const Text('Nearby devices')),
      body: Column(
        children: [
          Card(
            margin: const EdgeInsets.all(12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('You: $selfName',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  FutureBuilder<List<String>>(
                    future: discovery.localIps(),
                    builder: (context, snap) {
                      final ips = snap.data ?? [];
                      return Text(
                        ips.isEmpty ? 'My IP: (not found)' : 'My IP: ${ips.join(', ')}',
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: ValueListenableBuilder<List<Peer>>(
              valueListenable: discovery.peers,
              builder: (context, peers, child) {
                if (peers.isEmpty) {
                  return const Center(child: Text('Searching for devices...'));
                }
                return ListView.builder(
                  itemCount: peers.length,
                  itemBuilder: (context, i) {
                    final p = peers[i];
                    return ListTile(
                      leading: const Icon(Icons.smartphone),
                      title: Text(p.name),
                      subtitle: Text(p.address.address),
                      trailing: ValueListenableBuilder<Set<String>>(
                        valueListenable: manager.connected,
                        builder: (context, ids, child) => Icon(
                          Icons.circle,
                          size: 14,
                          color: ids.contains(p.id) ? Colors.green : Colors.grey,
                        ),
                      ),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => ChatScreen(
                            manager: manager,
                            peerId: p.id,
                            peerName: p.name,
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          ExpansionTile(
            title: const Text('Debug log'),
            children: [
              _LogBox(title: 'Discovery', logs: discovery.logs),
              _LogBox(title: 'Connections', logs: manager.logs),
            ],
          ),
        ],
      ),
    );
  }
}

class _LogBox extends StatelessWidget {
  final String title;
  final ValueNotifier<List<String>> logs;

  const _LogBox({required this.title, required this.logs});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
          SizedBox(
            height: 100,
            child: ValueListenableBuilder<List<String>>(
              valueListenable: logs,
              builder: (context, list, child) =>
                  ListView(children: [for (final l in list) Text(l)]),
            ),
          ),
        ],
      ),
    );
  }
}

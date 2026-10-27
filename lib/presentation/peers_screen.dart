import 'package:flutter/material.dart';

import '../network/discovery/udp_beacon_discovery.dart';

class PeersScreen extends StatelessWidget {
  final UdpBeaconDiscovery discovery;
  final String selfName;

  const PeersScreen({super.key, required this.discovery, required this.selfName});

  @override
  Widget build(BuildContext context) {
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
              builder: (context, peers, _) {
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
                    );
                  },
                );
              },
            ),
          ),
          ExpansionTile(
            title: const Text('Debug log'),
            children: [
              SizedBox(
                height: 200,
                child: ValueListenableBuilder<List<String>>(
                  valueListenable: discovery.logs,
                  builder: (context, logs, _) => ListView(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    children: [for (final l in logs) Text(l)],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

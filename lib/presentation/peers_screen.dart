import 'package:flutter/material.dart';

import '../core/native_bridge.dart';
import '../network/transport/connection_manager.dart';
import 'chat_screen.dart';
import 'settings_screen.dart';

class PeersScreen extends StatefulWidget {
  final ConnectionManager manager;

  const PeersScreen({super.key, required this.manager});

  @override
  State<PeersScreen> createState() => _PeersScreenState();
}

class _PeersScreenState extends State<PeersScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _firstRun());
  }

  Future<void> _firstRun() async {
    final manager = widget.manager;
    if (!manager.hasNickname) {
      final name = await _askNickname();
      if (name != null) manager.setNickname(name);
    }
    await NativeBridge.requestNotificationPermission();
  }

  Future<String?> _askNickname() {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Choose a nickname'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 24,
          decoration: const InputDecoration(hintText: 'Your name'),
        ),
        actions: [
          FilledButton(
            onPressed: () {
              final t = controller.text.trim();
              if (t.isNotEmpty) Navigator.of(ctx).pop(t);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final manager = widget.manager;

    return Scaffold(
      appBar: AppBar(
        title: const Text('LAN Messenger'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => SettingsScreen(manager: manager),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          ValueListenableBuilder<String>(
            valueListenable: manager.myName,
            builder: (context, name, _) => ListTile(
              leading: const CircleAvatar(child: Icon(Icons.person)),
              title: Text('You: $name'),
              subtitle: FutureBuilder<List<String>>(
                future: manager.discovery.localIps(),
                builder: (context, snap) {
                  final ips = snap.data ?? [];
                  return Text(ips.isEmpty ? 'IP: (not found)' : ips.join(', '));
                },
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ValueListenableBuilder<List<ContactInfo>>(
              valueListenable: manager.contacts,
              builder: (context, list, _) {
                if (list.isEmpty) {
                  return const Center(child: Text('Searching for devices...'));
                }
                return ListView.builder(
                  itemCount: list.length,
                  itemBuilder: (context, i) {
                    final c = list[i];
                    final initial = c.name.isEmpty
                        ? '?'
                        : String.fromCharCode(c.name.runes.first).toUpperCase();
                    return ListTile(
                      leading: CircleAvatar(child: Text(initial)),
                      title: Text(c.name),
                      subtitle: Text(
                        c.lastText.isNotEmpty
                            ? c.lastText
                            : (c.nearby ? 'Nearby' : 'Offline'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (c.unread > 0) Badge(label: Text('${c.unread}')),
                          const SizedBox(width: 8),
                          Icon(
                            Icons.circle,
                            size: 14,
                            color: c.connected
                                ? Colors.green
                                : (c.nearby ? Colors.orange : Colors.grey),
                          ),
                        ],
                      ),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => ChatScreen(
                            manager: manager,
                            peerId: c.id,
                            peerName: c.name,
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

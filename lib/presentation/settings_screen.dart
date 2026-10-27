import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/native_bridge.dart';
import '../network/transport/connection_manager.dart';

class SettingsScreen extends StatefulWidget {
  final ConnectionManager manager;

  const SettingsScreen({super.key, required this.manager});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  late final TextEditingController _name =
      TextEditingController(text: widget.manager.selfName);
  late bool _bg = widget.manager.store.backgroundEnabled;
  bool? _battery;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadBattery();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _loadBattery();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _name.dispose();
    super.dispose();
  }

  Future<void> _loadBattery() async {
    final v = await NativeBridge.isBatteryExempt();
    if (mounted) setState(() => _battery = v);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _export() async {
    final json = widget.manager.exportBackup();
    final bytes = Uint8List.fromList(utf8.encode(json));
    final date = DateTime.now().toIso8601String().substring(0, 10);
    try {
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Save chat backup',
        fileName: 'lan_messenger_backup_$date.json',
        bytes: bytes,
      );
      _toast(path == null ? 'Export cancelled' : 'Backup saved');
    } catch (e) {
      _toast('Export failed: $e');
    }
  }

  Future<void> _import() async {
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.any);
      final path = result?.files.single.path;
      if (path == null) return;
      final text = await File(path).readAsString();
      final added = widget.manager.importBackup(text);
      _toast(added < 0
          ? 'This is not a valid backup file'
          : 'Imported $added new messages');
    } catch (e) {
      _toast('Import failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.manager;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          const _Header('Nickname'),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _name,
                  maxLength: 24,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () {
                  m.setNickname(_name.text);
                  _toast('Nickname saved');
                },
                child: const Text('Save'),
              ),
            ],
          ),
          const _Header('Background'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Keep running in background'),
            subtitle: const Text(
              'Shows a small notification so Android keeps the app alive '
              'and you get message alerts',
            ),
            value: _bg,
            onChanged: (v) {
              setState(() => _bg = v);
              m.setBackground(v);
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.battery_saver),
            title: const Text('Battery optimization'),
            subtitle: Text(
              _battery == null
                  ? 'Checking...'
                  : (_battery! ? 'Already allowed' : 'Tap to allow (recommended)'),
            ),
            onTap: () async {
              await NativeBridge.requestBatteryExemption();
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.notifications),
            title: const Text('Allow notifications'),
            onTap: () => NativeBridge.requestNotificationPermission(),
          ),
          const _Header('Chat backup'),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.upload_file),
            title: const Text('Export chats'),
            subtitle: const Text('Save all chats as a .json file'),
            onTap: _export,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.download),
            title: const Text('Import chats'),
            subtitle: const Text('Restore from a backup (no duplicates)'),
            onTap: _import,
          ),
          const _Header('Received files folder'),
          SelectableText(m.receivedPath.isEmpty ? '-' : m.receivedPath),
          const SizedBox(height: 12),
          ExpansionTile(
            title: const Text('Debug log'),
            children: [
              _LogBox(title: 'Discovery', logs: m.discovery.logs),
              _LogBox(title: 'Connections', logs: m.logs),
            ],
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String text;
  const _Header(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 6),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
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
            height: 120,
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

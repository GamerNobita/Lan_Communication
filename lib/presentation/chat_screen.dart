import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';

import '../network/transfer/file_transfer.dart';
import '../network/transport/connection_manager.dart';

class ChatScreen extends StatefulWidget {
  final ConnectionManager manager;
  final String peerId;
  final String peerName;

  const ChatScreen({
    super.key,
    required this.manager,
    required this.peerId,
    required this.peerName,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final TextEditingController _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // After the first frame, so we never update other screens while building.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.manager.openChat(widget.peerId);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      widget.manager.openChat(widget.peerId);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.manager.closeChat(widget.peerId);
    _controller.dispose();
    super.dispose();
  }

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    widget.manager.sendText(widget.peerId, text);
    _controller.clear();
  }

  Future<void> _pickFile() async {
    if (!widget.manager.isConnected(widget.peerId)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Not connected yet')),
      );
      return;
    }
    final result = await FilePicker.platform.pickFiles();
    final path = result?.files.single.path;
    if (path == null) return;
    await widget.manager.sendFile(widget.peerId, path);
  }

  @override
  Widget build(BuildContext context) {
    final messages = widget.manager.chatFor(widget.peerId);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.peerName),
            ValueListenableBuilder<Set<String>>(
              valueListenable: widget.manager.connected,
              builder: (context, ids, child) => Text(
                ids.contains(widget.peerId) ? 'Connected' : 'Not connected',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ValueListenableBuilder<List<ChatMessage>>(
              valueListenable: messages,
              builder: (context, list, child) {
                final items = list.reversed.toList();
                return ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.all(12),
                  itemCount: items.length,
                  itemBuilder: (context, i) => _Bubble(msg: items[i]),
                );
              },
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.attach_file),
                    onPressed: _pickFile,
                  ),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: const InputDecoration(
                        hintText: 'Message',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  IconButton(icon: const Icon(Icons.send), onPressed: _send),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final ChatMessage msg;
  const _Bubble({required this.msg});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final file = msg.file;

    return Align(
      alignment: msg.mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        decoration: BoxDecoration(
          color: msg.mine ? scheme.primaryContainer : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: file != null
            ? _FileTile(t: file)
            : Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(msg.text),
                  if (msg.mine)
                    Icon(
                      msg.delivered ? Icons.done_all : Icons.access_time,
                      size: 14,
                    ),
                ],
              ),
      ),
    );
  }
}

class _FileTile extends StatelessWidget {
  final FileTransfer t;
  const _FileTile({required this.t});

  String _fmt(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String _statusText() {
    switch (t.status) {
      case TransferStatus.waiting:
        return t.outgoing ? 'Waiting for the other phone...' : 'Starting...';
      case TransferStatus.active:
        return '${(t.progress * 100).toStringAsFixed(0)}%';
      case TransferStatus.done:
        return t.outgoing ? 'Sent' : 'Received - tap to open';
      case TransferStatus.failed:
        return 'Failed: ${t.error ?? 'unknown error'}';
    }
  }

  @override
  Widget build(BuildContext context) {
    final canOpen = t.status == TransferStatus.done && t.path != null;

    return InkWell(
      onTap: canOpen ? () => OpenFilex.open(t.path!) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.insert_drive_file),
              const SizedBox(width: 8),
              Flexible(
                child: Text(t.name, maxLines: 2, overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${_fmt(t.size)}  -  ${_statusText()}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (t.status == TransferStatus.active) ...[
            const SizedBox(height: 6),
            LinearProgressIndicator(value: t.progress),
          ],
        ],
      ),
    );
  }
}

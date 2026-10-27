import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/native_bridge.dart';
import '../../data/chat_store.dart';
import '../discovery/udp_beacon_discovery.dart';
import '../transfer/file_transfer.dart';
import 'peer_connection.dart';

class ChatMessage {
  final String id;
  final String peerId;
  final bool mine;
  final String text;
  final DateTime time;
  final FileTransfer? file;
  bool delivered;

  ChatMessage({
    required this.id,
    required this.peerId,
    required this.mine,
    required this.text,
    DateTime? time,
    this.file,
    this.delivered = false,
  }) : time = time ?? DateTime.now();
}

/// One row in the people list.
class ContactInfo {
  final String id;
  final String name;
  final String? ip;
  final bool connected;
  final bool nearby;
  final int unread;
  final String lastText;
  final int lastTs;

  const ContactInfo({
    required this.id,
    required this.name,
    required this.ip,
    required this.connected,
    required this.nearby,
    required this.unread,
    required this.lastText,
    required this.lastTs,
  });
}

/// Owns the TCP server, the discovery service and all peer connections.
class ConnectionManager {
  final ChatStore store;
  late final ValueNotifier<String> myName;

  late final UdpBeaconDiscovery discovery;
  late final FileTransferService _files;
  ServerSocket? _server;
  Timer? _retryTimer;
  final Random _rnd = Random();

  String receivedPath = '';
  String? openChatPeerId;

  final Map<String, PeerConnection> _conns = {};
  final Map<String, InternetAddress> _addrs = {};
  final Set<String> _dialing = {};
  final Set<String> _seenIds = {};
  final Map<String, FileTransfer> _outgoing = {};
  final Map<String, DateTime> _lastTouch = {};
  final Map<String, ValueNotifier<List<ChatMessage>>> _chats = {};

  /// Ids of peers we currently have a live connection with.
  final ValueNotifier<Set<String>> connected = ValueNotifier<Set<String>>({});
  final ValueNotifier<List<ContactInfo>> contacts =
      ValueNotifier<List<ContactInfo>>([]);
  final ValueNotifier<List<String>> logs = ValueNotifier<List<String>>([]);

  ConnectionManager({required this.store}) {
    myName = ValueNotifier<String>(selfName);
  }

  String get selfId => store.deviceId;
  String get selfName => store.nickname ?? 'Phone-${selfId.substring(0, 4)}';
  bool get hasNickname => store.nickname != null;

  void _log(String msg) {
    final t = DateTime.now().toIso8601String().substring(11, 19);
    logs.value = ['$t  $msg', ...logs.value].take(60).toList();
  }

  Future<void> start() async {
    _loadAllChats();

    // Folder where received files are stored (no permission needed).
    Directory base;
    try {
      base = (await getExternalStorageDirectory()) ??
          await getApplicationDocumentsDirectory();
    } catch (_) {
      base = await getApplicationDocumentsDirectory();
    }
    final dir = Directory('${base.path}/received');
    await dir.create(recursive: true);
    receivedPath = dir.path;

    _files = FileTransferService(
      receiveDir: dir,
      onChanged: _fileChanged,
      log: _log,
    );
    await _files.start();

    final server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    _server = server;
    server.listen(_setup);
    _log('chat server on port ${server.port}');

    discovery = UdpBeaconDiscovery(
      selfId: selfId,
      selfName: selfName,
      tcpPort: server.port,
    );
    for (final id in store.contactIds) {
      final ip = store.contactIp(id);
      if (ip != null) discovery.extraTargets.add(ip);
    }
    await discovery.start();

    discovery.peers.addListener(_onPeersChanged);
    _retryTimer =
        Timer.periodic(const Duration(seconds: 4), (_) => _ensureConnections());
    _refreshContacts();
  }

  void _onPeersChanged() {
    for (final p in discovery.peers.value) {
      store.upsertContact(p.id, p.name, p.address.address);
      discovery.extraTargets.add(p.address.address);
    }
    _ensureConnections();
    _refreshContacts();
  }

  /// Only the peer with the smaller id dials, so a pair never gets two sockets.
  void _ensureConnections() {
    for (final p in discovery.peers.value) {
      if (p.port == 0) continue;
      if (_conns.containsKey(p.id) || _dialing.contains(p.id)) continue;
      if (selfId.compareTo(p.id) < 0) _dial(p);
    }
  }

  Future<void> _dial(Peer p) async {
    _dialing.add(p.id);
    try {
      final socket = await Socket.connect(
        p.address,
        p.port,
        timeout: const Duration(seconds: 5),
      );
      _setup(socket);
    } catch (e) {
      _log('connect to ${p.name} failed: $e');
    } finally {
      _dialing.remove(p.id);
    }
  }

  void _setup(Socket socket) {
    final conn = PeerConnection(socket);
    String? peerId;

    conn.send({'t': 'hello', 'id': selfId, 'name': selfName});

    conn.frames.listen((m) {
      final t = m['t'];

      // The first frame must be the hello.
      if (peerId == null) {
        final String? id = m['id'] is String ? m['id'] as String : null;
        if (t != 'hello' || id == null || id == selfId) {
          conn.close();
          return;
        }
        peerId = id;
        final name = m['name'] is String
            ? m['name'] as String
            : (id.length >= 4 ? id.substring(0, 4) : id);

        final old = _conns[id];
        _conns[id] = conn;
        _addrs[id] = socket.remoteAddress;
        old?.close();
        store.upsertContact(id, name, socket.remoteAddress.address);
        _publishConnected();
        _log('connected with $name');
        _flush(id);
        return;
      }

      final id = peerId!;
      if (t == 'chat') {
        _onChat(conn, id, m);
      } else if (t == 'ack') {
        _onAck(id, m);
      } else if (t == 'name') {
        final n = m['name'];
        if (n is String && n.trim().isNotEmpty) {
          store.upsertContact(id, n, null);
          _refreshContacts();
        }
      } else if (t == 'file_offer') {
        _onFileOffer(conn, id, m);
      } else if (t == 'file_accept') {
        _onFileAccept(id, m);
      }
    });

    conn.done.then((_) {
      final id = peerId;
      if (id != null && identical(_conns[id], conn)) {
        _conns.remove(id);
        _publishConnected();
        _log('disconnected from ${_nameOf(id)}');
      }
    });
  }

  void _publishConnected() {
    connected.value = _conns.keys.toSet();
    _refreshContacts();
  }

  // --------------------------------------------------------------- nickname

  void setNickname(String name) {
    final n = name.trim();
    if (n.isEmpty) return;
    store.nickname = n;
    myName.value = n;
    discovery.selfName = n;
    for (final c in _conns.values) {
      c.send({'t': 'name', 'name': n});
    }
  }

  void setBackground(bool on) {
    store.backgroundEnabled = on;
    if (on) {
      NativeBridge.startService();
    } else {
      NativeBridge.stopService();
    }
  }

  String _nameOf(String id) => store.contactName(id) ?? 'Someone';

  // ---------------------------------------------------------------- storage

  Map<String, dynamic> _toRecord(ChatMessage m) {
    final f = m.file;
    return {
      'id': m.id,
      'mine': m.mine,
      'text': m.text,
      'ts': m.time.millisecondsSinceEpoch,
      'delivered': m.delivered,
      if (f != null)
        'file': {
          'name': f.name,
          'size': f.size,
          'path': f.path,
          'status': f.status.name,
          'out': f.outgoing,
          'err': f.error,
        },
    };
  }

  ChatMessage _fromRecord(String peerId, Map<String, dynamic> r) {
    final id = r['id'] as String;
    FileTransfer? file;
    final f = r['file'];
    if (f is Map) {
      final size = (f['size'] as int?) ?? 0;
      var status = TransferStatus.values.firstWhere(
        (s) => s.name == f['status'],
        orElse: () => TransferStatus.failed,
      );
      String? err = f['err'] as String?;
      if (status == TransferStatus.waiting || status == TransferStatus.active) {
        status = TransferStatus.failed;
        err = 'interrupted';
      }
      file = FileTransfer(
        id: id,
        peerId: peerId,
        name: (f['name'] as String?) ?? 'file',
        size: size,
        outgoing: (f['out'] as bool?) ?? false,
        path: f['path'] as String?,
      );
      file.status = status;
      file.error = err;
      file.transferred = status == TransferStatus.done ? size : 0;
    }
    return ChatMessage(
      id: id,
      peerId: peerId,
      mine: (r['mine'] as bool?) ?? false,
      text: (r['text'] as String?) ?? '',
      time: DateTime.fromMillisecondsSinceEpoch((r['ts'] as int?) ?? 0),
      file: file,
      delivered: (r['delivered'] as bool?) ?? false,
    );
  }

  void _persist(ChatMessage m) => store.putMessage(m.peerId, _toRecord(m));

  void _loadAllChats() {
    _seenIds.clear();
    for (final peerId in store.chatPeerIds.toList()) {
      final list = <ChatMessage>[];
      for (final r in store.messagesOf(peerId)) {
        final m = _fromRecord(peerId, r);
        list.add(m);
        if (!m.mine) _seenIds.add(m.file != null ? 'file-${m.id}' : m.id);
      }
      chatFor(peerId).value = list;
    }
  }

  String exportBackup() => store.exportJson();

  int importBackup(String json) {
    final added = store.importJson(json);
    if (added >= 0) {
      _loadAllChats();
      for (final id in store.contactIds) {
        final ip = store.contactIp(id);
        if (ip != null) discovery.extraTargets.add(ip);
      }
      _refreshContacts();
    }
    return added;
  }

  // --------------------------------------------------------------- contacts

  void _refreshContacts() {
    final nearby = <String, Peer>{for (final p in discovery.peers.value) p.id: p};
    final ids = <String>{
      ...store.contactIds,
      ...store.chatPeerIds,
      ...nearby.keys,
      ..._conns.keys,
    };

    final list = <ContactInfo>[];
    for (final id in ids) {
      if (id == selfId) continue;
      final msgs = _chats[id]?.value ?? const <ChatMessage>[];
      final lastRead = store.lastRead(id);
      var unread = 0;
      for (final m in msgs) {
        if (!m.mine && m.time.millisecondsSinceEpoch > lastRead) unread++;
      }
      final last = msgs.isEmpty ? null : msgs.last;
      list.add(ContactInfo(
        id: id,
        name: nearby[id]?.name ?? store.contactName(id) ?? 'Unknown',
        ip: nearby[id]?.address.address ?? store.contactIp(id),
        connected: _conns.containsKey(id),
        nearby: nearby.containsKey(id),
        unread: unread,
        lastText: last == null
            ? ''
            : (last.file != null ? 'File: ${last.text}' : last.text),
        lastTs: last?.time.millisecondsSinceEpoch ?? 0,
      ));
    }
    list.sort((a, b) {
      if (a.lastTs != b.lastTs) return b.lastTs.compareTo(a.lastTs);
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    contacts.value = list;
  }

  // ------------------------------------------------------------- open chats

  int _notifId(String peerId) => peerId.hashCode & 0x7fffffff;

  void openChat(String peerId) {
    openChatPeerId = peerId;
    markRead(peerId);
  }

  void closeChat(String peerId) {
    if (openChatPeerId == peerId) openChatPeerId = null;
  }

  void markRead(String peerId) {
    store.setLastRead(peerId, DateTime.now().millisecondsSinceEpoch);
    NativeBridge.cancelNotification(_notifId(peerId));
    _refreshContacts();
  }

  bool get _appVisible =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  /// Shows a notification unless the user is looking at the app right now.
  void _notifyIncoming(String peerId, String body) {
    if (_appVisible) {
      if (openChatPeerId == peerId) markRead(peerId);
      return;
    }
    final text = body.length > 120 ? '${body.substring(0, 120)}...' : body;
    NativeBridge.notify(_notifId(peerId), _nameOf(peerId), text);
  }

  // ------------------------------------------------------------------- chat

  ValueNotifier<List<ChatMessage>> chatFor(String peerId) =>
      _chats.putIfAbsent(peerId, () => ValueNotifier<List<ChatMessage>>([]));

  void _addMessage(ChatMessage msg) {
    final n = chatFor(msg.peerId);
    n.value = [...n.value, msg];
    _persist(msg);
    _refreshContacts();
  }

  String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${_rnd.nextInt(1 << 30)}';

  void sendText(String peerId, String text) {
    final msg = ChatMessage(id: _newId(), peerId: peerId, mine: true, text: text);
    _addMessage(msg);
    final conn = _conns[peerId];
    if (conn != null) _sendChat(conn, msg);
    // If there is no connection the message waits and is sent by _flush.
  }

  void _sendChat(PeerConnection conn, ChatMessage msg) {
    conn.send({
      't': 'chat',
      'id': msg.id,
      'text': msg.text,
      'ts': msg.time.millisecondsSinceEpoch,
    });
  }

  /// Re-send every text message of ours that was never acknowledged.
  void _flush(String peerId) {
    final conn = _conns[peerId];
    if (conn == null) return;
    for (final msg in chatFor(peerId).value) {
      if (msg.mine && !msg.delivered && msg.file == null) {
        _sendChat(conn, msg);
      }
    }
  }

  void _onChat(PeerConnection conn, String peerId, Map<String, dynamic> m) {
    final id = m['id'];
    final text = m['text'];
    if (id is! String || text is! String) return;

    conn.send({'t': 'ack', 'id': id}); // always ack, even duplicates
    if (!_seenIds.add(id)) return; // duplicate from a re-send
    _addMessage(ChatMessage(id: id, peerId: peerId, mine: false, text: text));
    _notifyIncoming(peerId, text);
  }

  void _onAck(String peerId, Map<String, dynamic> m) {
    final n = chatFor(peerId);
    for (final msg in n.value) {
      if (msg.mine && msg.id == m['id'] && !msg.delivered) {
        msg.delivered = true;
        _persist(msg);
      }
    }
    n.value = List<ChatMessage>.of(n.value);
  }

  // ------------------------------------------------------------------ files

  bool isConnected(String peerId) => _conns.containsKey(peerId);

  /// Sender: announce the file; the data flows after the other side accepts.
  Future<void> sendFile(String peerId, String path) async {
    final conn = _conns[peerId];
    if (conn == null) {
      _log('cannot send file: not connected');
      return;
    }
    final size = await File(path).length();
    final name = path.split(RegExp(r'[\\/]')).last;

    final t = FileTransfer(
      id: _newId(),
      peerId: peerId,
      name: name,
      size: size,
      outgoing: true,
      path: path,
    );
    _outgoing[t.id] = t;
    _addMessage(ChatMessage(
      id: t.id,
      peerId: peerId,
      mine: true,
      text: name,
      file: t,
    ));
    conn.send({'t': 'file_offer', 'tid': t.id, 'name': name, 'size': size});
  }

  /// Receiver: reserve a file name, expect the data connection, accept.
  Future<void> _onFileOffer(
    PeerConnection conn,
    String peerId,
    Map<String, dynamic> m,
  ) async {
    final tid = m['tid'];
    final name = m['name'];
    final size = m['size'];
    if (tid is! String || name is! String || size is! int) return;
    if (!_seenIds.add('file-$tid')) return; // already handled

    final path = await _files.reserveFile(name);
    final t = FileTransfer(
      id: tid,
      peerId: peerId,
      name: name,
      size: size,
      outgoing: false,
      path: path,
    );
    _files.expect(t);
    _addMessage(ChatMessage(
      id: tid,
      peerId: peerId,
      mine: false,
      text: name,
      file: t,
    ));
    conn.send({'t': 'file_accept', 'tid': tid, 'port': _files.port});
  }

  /// Sender: the other side said yes, open the data connection.
  void _onFileAccept(String peerId, Map<String, dynamic> m) {
    final tid = m['tid'];
    final port = m['port'];
    if (tid is! String || port is! int) return;

    final t = _outgoing[tid];
    final addr = _addrs[peerId];
    if (t == null || addr == null || t.peerId != peerId) return;
    _files.send(t, addr, port);
  }

  /// Called often during a transfer; refresh the UI at most ~6 times/second.
  void _fileChanged(FileTransfer t, bool force) {
    final now = DateTime.now();
    final last = _lastTouch[t.id];
    if (!force &&
        last != null &&
        now.difference(last) < const Duration(milliseconds: 150)) {
      return;
    }
    _lastTouch[t.id] = now;

    final n = chatFor(t.peerId);
    n.value = List<ChatMessage>.of(n.value);

    if (force) {
      for (final m in n.value) {
        if (m.id == t.id) {
          _persist(m);
          break;
        }
      }
      if (t.status == TransferStatus.done && !t.outgoing) {
        _notifyIncoming(t.peerId, 'Sent you a file: ${t.name}');
      }
    }
  }
}

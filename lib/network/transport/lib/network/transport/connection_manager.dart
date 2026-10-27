import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../discovery/udp_beacon_discovery.dart';
import 'peer_connection.dart';

class ChatMessage {
  final String id;
  final String peerId;
  final bool mine;
  final String text;
  final DateTime time;
  bool delivered;

  ChatMessage({
    required this.id,
    required this.peerId,
    required this.mine,
    required this.text,
    DateTime? time,
    this.delivered = false,
  }) : time = time ?? DateTime.now();
}

/// Owns the TCP server, the discovery service and all peer connections.
class ConnectionManager {
  final String selfId;
  final String selfName;

  late final UdpBeaconDiscovery discovery;
  ServerSocket? _server;
  Timer? _retryTimer;
  final Random _rnd = Random();

  final Map<String, PeerConnection> _conns = {};
  final Set<String> _dialing = {};
  final Set<String> _seenIds = {};
  final Map<String, ValueNotifier<List<ChatMessage>>> _chats = {};

  /// Ids of peers we currently have a live connection with.
  final ValueNotifier<Set<String>> connected = ValueNotifier<Set<String>>({});
  final ValueNotifier<List<String>> logs = ValueNotifier<List<String>>([]);

  ConnectionManager({required this.selfId, required this.selfName});

  void _log(String msg) {
    final t = DateTime.now().toIso8601String().substring(11, 19);
    logs.value = ['$t  $msg', ...logs.value].take(60).toList();
  }

  Future<void> start() async {
    final server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    _server = server;
    server.listen(_setup);
    _log('chat server on port ${server.port}');

    discovery = UdpBeaconDiscovery(
      selfId: selfId,
      selfName: selfName,
      tcpPort: server.port,
    );
    await discovery.start();

    discovery.peers.addListener(_ensureConnections);
    _retryTimer =
        Timer.periodic(const Duration(seconds: 4), (_) => _ensureConnections());
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
        final old = _conns[id];
        _conns[id] = conn;
        old?.close();
        _publishConnected();
        _log('connected with ${m['name'] ?? id}');
        _flush(id);
        return;
      }

      final id = peerId!;
      if (t == 'chat') {
        _onChat(conn, id, m);
      } else if (t == 'ack') {
        _onAck(id, m);
      }
    });

    conn.done.then((_) {
      final id = peerId;
      if (id != null && identical(_conns[id], conn)) {
        _conns.remove(id);
        _publishConnected();
        _log('disconnected from $id');
      }
    });
  }

  void _publishConnected() => connected.value = _conns.keys.toSet();

  ValueNotifier<List<ChatMessage>> chatFor(String peerId) =>
      _chats.putIfAbsent(peerId, () => ValueNotifier<List<ChatMessage>>([]));

  void _addMessage(ChatMessage msg) {
    final n = chatFor(msg.peerId);
    n.value = [...n.value, msg];
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

  /// Re-send every message of ours that was never acknowledged.
  void _flush(String peerId) {
    final conn = _conns[peerId];
    if (conn == null) return;
    for (final msg in chatFor(peerId).value) {
      if (msg.mine && !msg.delivered) _sendChat(conn, msg);
    }
  }

  void _onChat(PeerConnection conn, String peerId, Map<String, dynamic> m) {
    final id = m['id'];
    final text = m['text'];
    if (id is! String || text is! String) return;

    conn.send({'t': 'ack', 'id': id}); // always ack, even duplicates
    if (!_seenIds.add(id)) return; // duplicate from a re-send
    _addMessage(ChatMessage(id: id, peerId: peerId, mine: false, text: text));
  }

  void _onAck(String peerId, Map<String, dynamic> m) {
    final n = chatFor(peerId);
    for (final msg in n.value) {
      if (msg.mine && msg.id == m['id']) msg.delivered = true;
    }
    n.value = List<ChatMessage>.of(n.value);
  }
}

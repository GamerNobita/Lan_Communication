import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

String _randomId() {
  final rnd = Random.secure();
  return List.generate(
    16,
    (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

int _tsOf(dynamic e) {
  final v = (e as Map)['ts'];
  return v is int ? v : 0;
}

/// Keeps identity, nickname, contacts and all chats in one JSON file.
class ChatStore {
  final File _file;
  final Map<String, dynamic> _data;
  Timer? _saveTimer;

  ChatStore._(this._file, this._data);

  static Future<ChatStore> open(Directory dir) async {
    final file = File('${dir.path}/store.json');
    Map<String, dynamic> data = {};
    try {
      if (await file.exists()) {
        data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      }
    } catch (_) {
      // Damaged file: keep a copy and start fresh instead of crashing.
      try {
        await file.rename('${file.path}.broken');
      } catch (_) {}
      data = {};
    }
    final store = ChatStore._(file, data);
    if (store.deviceId.isEmpty) {
      store._data['deviceId'] = _randomId();
      store.scheduleSave();
    }
    return store;
  }

  // --------------------------------------------------------------- identity

  String get deviceId => (_data['deviceId'] as String?) ?? '';

  String? get nickname {
    final n = _data['nickname'];
    return (n is String && n.trim().isNotEmpty) ? n : null;
  }

  set nickname(String? v) {
    _data['nickname'] = v;
    scheduleSave();
  }

  bool get backgroundEnabled => (_data['bg'] as bool?) ?? true;

  set backgroundEnabled(bool v) {
    _data['bg'] = v;
    scheduleSave();
  }

  // --------------------------------------------------------------- contacts

  Map<String, dynamic> get _contacts =>
      (_data['contacts'] ??= <String, dynamic>{}) as Map<String, dynamic>;

  Iterable<String> get contactIds => _contacts.keys;

  String? contactName(String id) => (_contacts[id] as Map?)?['name'] as String?;

  String? contactIp(String id) => (_contacts[id] as Map?)?['ip'] as String?;

  void upsertContact(String id, String name, String? ip) {
    final c = (_contacts[id] as Map<String, dynamic>?) ?? <String, dynamic>{};
    var changed = c.isEmpty;
    if (c['name'] != name) {
      c['name'] = name;
      changed = true;
    }
    if (ip != null && c['ip'] != ip) {
      c['ip'] = ip;
      changed = true;
    }
    if (changed) {
      _contacts[id] = c;
      scheduleSave();
    }
  }

  int lastRead(String peerId) {
    final m = _data['lastRead'];
    if (m is Map) {
      final v = m[peerId];
      if (v is int) return v;
    }
    return 0;
  }

  void setLastRead(String peerId, int ts) {
    final m = (_data['lastRead'] ??= <String, dynamic>{}) as Map<String, dynamic>;
    m[peerId] = ts;
    scheduleSave();
  }

  // --------------------------------------------------------------- messages

  Map<String, dynamic> get _messages =>
      (_data['messages'] ??= <String, dynamic>{}) as Map<String, dynamic>;

  Iterable<String> get chatPeerIds => _messages.keys;

  List<Map<String, dynamic>> messagesOf(String peerId) {
    final list = _messages[peerId];
    if (list is! List) return [];
    return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  /// Insert a message, or replace the one with the same id.
  void putMessage(String peerId, Map<String, dynamic> record) {
    final list = (_messages[peerId] ??= <dynamic>[]) as List<dynamic>;
    final id = record['id'];
    final i = list.indexWhere((e) => (e as Map)['id'] == id);
    if (i >= 0) {
      list[i] = record;
    } else {
      list.add(record);
    }
    scheduleSave();
  }

  // ------------------------------------------------------------ export/import

  String exportJson() {
    return const JsonEncoder.withIndent('  ').convert({
      'app': 'lan_messenger',
      'version': 1,
      'exportedAt': DateTime.now().toIso8601String(),
      'contacts': _contacts,
      'messages': _messages,
    });
  }

  /// Merges a backup into this store.
  /// Returns the number of new messages, or -1 if the file is not a backup.
  int importJson(String text) {
    try {
      final data = jsonDecode(text);
      if (data is! Map || data['app'] != 'lan_messenger') return -1;
      var added = 0;

      final contacts = data['contacts'];
      if (contacts is Map) {
        contacts.forEach((k, v) {
          if (k is String && v is Map && !_contacts.containsKey(k)) {
            _contacts[k] = Map<String, dynamic>.from(v);
          }
        });
      }

      final messages = data['messages'];
      if (messages is Map) {
        messages.forEach((peerId, list) {
          if (peerId is! String || list is! List) return;
          final existing = messagesOf(peerId).map((m) => m['id']).toSet();
          for (final item in list) {
            if (item is! Map) continue;
            final rec = Map<String, dynamic>.from(item);
            final id = rec['id'];
            if (id is! String || existing.contains(id)) continue;
            putMessage(peerId, rec);
            added++;
          }
          final l = _messages[peerId];
          if (l is List) l.sort((a, b) => _tsOf(a).compareTo(_tsOf(b)));
        });
      }
      scheduleSave();
      return added;
    } catch (_) {
      return -1;
    }
  }

  // ------------------------------------------------------------------- save

  void scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 800), () {
      flush();
    });
  }

  Future<void> flush() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    try {
      final tmp = File('${_file.path}.tmp');
      await tmp.writeAsString(jsonEncode(_data), flush: true);
      await tmp.rename(_file.path);
    } catch (_) {}
  }
}

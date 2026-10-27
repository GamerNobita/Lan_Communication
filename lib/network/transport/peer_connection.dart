import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// One TCP connection. Frames are: [4-byte length][JSON bytes].
class PeerConnection {
  static const int _maxFrame = 4 * 1024 * 1024;

  final Socket _socket;
  final StreamController<Map<String, dynamic>> _controller =
      StreamController<Map<String, dynamic>>.broadcast();
  final Completer<void> _done = Completer<void>();
  final BytesBuilder _buffer = BytesBuilder(copy: false);
  Timer? _heartbeat;
  DateTime _lastRx = DateTime.now();
  bool _closed = false;

  PeerConnection(this._socket) {
    _socket.setOption(SocketOption.tcpNoDelay, true);
    _socket.listen(
      _onData,
      onError: (Object e) => close(),
      onDone: close,
      cancelOnError: true,
    );
    _heartbeat = Timer.periodic(const Duration(seconds: 5), (_) {
      if (DateTime.now().difference(_lastRx) > const Duration(seconds: 15)) {
        close();
      } else {
        send({'t': 'ping'});
      }
    });
  }

  Stream<Map<String, dynamic>> get frames => _controller.stream;
  Future<void> get done => _done.future;

  void send(Map<String, dynamic> message) {
    if (_closed) return;
    try {
      final payload = utf8.encode(jsonEncode(message));
      final header = ByteData(4)..setUint32(0, payload.length);
      _socket.add(header.buffer.asUint8List());
      _socket.add(payload);
    } catch (_) {
      close();
    }
  }

  void _onData(List<int> chunk) {
    _lastRx = DateTime.now();
    _buffer.add(chunk);
    final data = _buffer.takeBytes();
    var offset = 0;

    // One read can hold half a frame or several frames.
    while (data.length - offset >= 4) {
      final len = ByteData.sublistView(data, offset, offset + 4).getUint32(0);
      if (len == 0 || len > _maxFrame) {
        close();
        return;
      }
      if (data.length - offset - 4 < len) break; // wait for the rest

      final body = data.sublist(offset + 4, offset + 4 + len);
      offset += 4 + len;

      try {
        final map = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
        if (map['t'] == 'ping') {
          send({'t': 'pong'});
          continue;
        }
        if (map['t'] == 'pong') continue;
        if (!_controller.isClosed) _controller.add(map);
      } catch (_) {
        close();
        return;
      }
    }

    if (offset < data.length) {
      _buffer.add(data.sublist(offset));
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _heartbeat?.cancel();
    _controller.close();
    try {
      _socket.destroy();
    } catch (_) {}
    if (!_done.isCompleted) _done.complete();
  }
}

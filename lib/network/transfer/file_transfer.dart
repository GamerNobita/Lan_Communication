import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

enum TransferStatus { waiting, active, done, failed }

class FileTransfer {
  final String id;
  final String peerId;
  final String name;
  final int size;
  final bool outgoing;
  int transferred = 0;
  TransferStatus status = TransferStatus.waiting;
  String? path; // where the file lives on this phone
  String? error;

  FileTransfer({
    required this.id,
    required this.peerId,
    required this.name,
    required this.size,
    required this.outgoing,
    this.path,
  });

  double get progress => size == 0 ? 1.0 : (transferred / size).clamp(0.0, 1.0);
}

class _RecvState {
  FileTransfer? transfer;
  RandomAccessFile? raf;
  bool finished = false;
}

/// Sends and receives files over their own raw TCP connections.
/// Data connection layout: [1 byte: id length][id bytes][raw file bytes...]
class FileTransferService {
  final Directory receiveDir;
  final void Function(FileTransfer t, bool force) onChanged;
  final void Function(String msg) log;

  ServerSocket? _server;
  final Map<String, FileTransfer> _expected = {};

  FileTransferService({
    required this.receiveDir,
    required this.onChanged,
    required this.log,
  });

  int get port => _server!.port;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    _server!.listen(_onDataSocket);
    log('file server on port ${_server!.port}');
  }

  /// Picks a free file name inside receiveDir and creates an empty file.
  Future<String> reserveFile(String rawName) async {
    var name = rawName.split(RegExp(r'[\\/]')).last.trim();
    if (name.isEmpty) name = 'file';

    var candidate = File('${receiveDir.path}/$name');
    if (await candidate.exists()) {
      final dot = name.lastIndexOf('.');
      final base = dot > 0 ? name.substring(0, dot) : name;
      final ext = dot > 0 ? name.substring(dot) : '';
      var i = 1;
      while (await candidate.exists()) {
        candidate = File('${receiveDir.path}/$base ($i)$ext');
        i++;
      }
    }
    await candidate.create();
    return candidate.path;
  }

  /// Receiver side: remember that a data connection for this id is coming.
  void expect(FileTransfer t) => _expected[t.id] = t;

  // ---------------------------------------------------------------- receive

  void _onDataSocket(Socket socket) {
    final s = _RecvState();
    final header = BytesBuilder(copy: false);
    late final StreamSubscription<Uint8List> sub;

    Future<void> finish(bool ok, [String? err]) async {
      if (s.finished) return;
      s.finished = true;
      try {
        await s.raf?.close();
      } catch (_) {}
      final tr = s.transfer;
      if (tr != null) {
        if (ok && tr.transferred == tr.size) {
          tr.status = TransferStatus.done;
        } else {
          tr.status = TransferStatus.failed;
          tr.error = err ?? 'incomplete';
        }
        onChanged(tr, true);
      }
      socket.destroy();
    }

    sub = socket.listen(
      (Uint8List chunk) async {
        sub.pause(); // backpressure: no new data while we write to disk
        try {
          var data = chunk;

          if (s.transfer == null) {
            header.add(chunk);
            final buf = header.toBytes();
            final n = buf[0];
            if (buf.length < 1 + n) {
              header.clear();
              header.add(buf);
              sub.resume();
              return;
            }
            final tid = utf8.decode(buf.sublist(1, 1 + n));
            final tr = _expected.remove(tid);
            if (tr == null) {
              await finish(false, 'unknown transfer');
              return;
            }
            s.transfer = tr;
            s.raf = await File(tr.path!).open(mode: FileMode.write);
            tr.status = TransferStatus.active;
            onChanged(tr, true);
            data = Uint8List.sublistView(buf, 1 + n);
          }

          final tr = s.transfer!;
          if (data.isNotEmpty) {
            final remaining = tr.size - tr.transferred;
            final slice = data.length > remaining
                ? Uint8List.sublistView(data, 0, remaining)
                : data;
            await s.raf!.writeFrom(slice);
            tr.transferred += slice.length;
            onChanged(tr, false);
          }

          if (tr.transferred >= tr.size) {
            await finish(true);
            return;
          }
        } catch (e) {
          await finish(false, '$e');
          return;
        }
        sub.resume();
      },
      onError: (Object e) {
        finish(false, '$e');
      },
      onDone: () {
        finish(false, 'connection closed early');
      },
      cancelOnError: true,
    );
  }

  // ------------------------------------------------------------------- send

  Future<void> send(FileTransfer t, InternetAddress addr, int port) async {
    Socket? socket;
    try {
      t.status = TransferStatus.active;
      onChanged(t, true);

      socket = await Socket.connect(addr, port,
          timeout: const Duration(seconds: 5));

      final idBytes = utf8.encode(t.id);
      socket.add([idBytes.length, ...idBytes]);

      final stream = File(t.path!).openRead().map((chunk) {
        t.transferred += chunk.length;
        onChanged(t, false);
        return chunk;
      });
      await socket.addStream(stream); // respects backpressure
      await socket.flush();
      await socket.close();

      t.transferred = t.size;
      t.status = TransferStatus.done;
    } catch (e) {
      t.status = TransferStatus.failed;
      t.error = '$e';
      socket?.destroy();
    }
    onChanged(t, true);
  }
}

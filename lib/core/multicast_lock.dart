import 'dart:io';

import 'package:flutter/services.dart';

/// Talks to the small Kotlin code that the GitHub workflow adds to MainActivity.
class MulticastLock {
  static const MethodChannel _channel = MethodChannel('lan_messenger/multicast');

  static Future<void> acquire() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('acquire');
    } catch (_) {}
  }

  static Future<void> release() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('release');
    } catch (_) {}
  }
}

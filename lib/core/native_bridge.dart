import 'dart:io';

import 'package:flutter/services.dart';

/// Calls into the Android code (background service, notifications...).
/// If the Android side does not know a method yet, the call is ignored.
class NativeBridge {
  static const MethodChannel _ch = MethodChannel('lan_messenger/native');

  static Future<T?> _call<T>(String method, [Map<String, dynamic>? args]) async {
    if (!Platform.isAndroid) return null;
    try {
      return await _ch.invokeMethod<T>(method, args);
    } catch (_) {
      return null;
    }
  }

  static Future<void> startService() async {
    await _call<bool>('startService');
  }

  static Future<void> stopService() async {
    await _call<bool>('stopService');
  }

  static Future<void> notify(int id, String title, String body) async {
    await _call<bool>('notify', {'id': id, 'title': title, 'body': body});
  }

  static Future<void> cancelNotification(int id) async {
    await _call<bool>('cancelNotification', {'id': id});
  }

  static Future<void> requestNotificationPermission() async {
    await _call<bool>('requestNotificationPermission');
  }

  static Future<void> requestBatteryExemption() async {
    await _call<bool>('requestBatteryExemption');
  }

  static Future<bool> isBatteryExempt() async {
    return (await _call<bool>('isBatteryExempt')) ?? false;
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

final FlutterLocalNotificationsPlugin notif = FlutterLocalNotificationsPlugin();

const AndroidNotificationChannel chatChannel = AndroidNotificationChannel(
  'payam_messages',
  'پیام‌های جدید',
  description: 'اعلان دریافت پیام',
  importance: Importance.high,
);

const AndroidNotificationChannel serviceChannel = AndroidNotificationChannel(
  'payam_service',
  'اتصال پیام‌رسان',
  description: 'نگه‌داشتن اتصال برای دریافت پیام در پس‌زمینه',
  importance: Importance.low,
);

Future<void> initNotifications() async {
  await notif.initialize(
    const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
  );
  final a = notif.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
  await a?.createNotificationChannel(chatChannel);
  await a?.createNotificationChannel(serviceChannel);
}

Future<void> requestNotificationPermission() async {
  final a = notif.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
  await a?.requestNotificationsPermission();
}

/// کنترل سرویس پس‌زمینه از داخل اپ
class Bg {
  static bool appInForeground = true;
  static bool _configured = false;

  static Future<void> start() async {
    final s = FlutterBackgroundService();
    if (!_configured) {
      _configured = true;
      await s.configure(
        androidConfiguration: AndroidConfiguration(
          onStart: onStart,
          autoStart: false,
          autoStartOnBoot: false,
          isForegroundMode: true,
          notificationChannelId: 'payam_service',
          initialNotificationTitle: 'پیام',
          initialNotificationContent: 'آماده دریافت پیام‌ها',
          foregroundServiceNotificationId: 888,
        ),
        iosConfiguration: IosConfiguration(),
      );
      // وقتی سرویس بالا آمد، وضعیت جلو/پس‌زمینه بودن اپ را بفرست
      s.on('ready').listen((_) => s.invoke('fg', {'v': appInForeground}));
    }
    if (await s.isRunning()) {
      s.invoke('reload');
    } else {
      await s.startService();
    }
  }

  static void setForeground(bool v) {
    appInForeground = v;
    FlutterBackgroundService().invoke('fg', {'v': v});
  }

  static void stop() {
    FlutterBackgroundService().invoke('stop');
  }
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  await initNotifications();

  bool fg = false;
  bool run = true;
  String? myId;
  WebSocketChannel? ch;
  Timer? retry;

  Future<void> connect() async {
    retry?.cancel();
    final old = ch;
    ch = null;
    old?.sink.close();
    final p = await SharedPreferences.getInstance();
    await p.reload();
    final base = p.getString('base') ?? '';
    final token = p.getString('token') ?? '';
    final meStr = p.getString('me');
    if (token.isEmpty || meStr == null || base.isEmpty) return;
    myId = jsonDecode(meStr)['id'];
    final u = base.replaceFirst('http', 'ws');
    try {
      final c = WebSocketChannel.connect(Uri.parse('$u/ws?token=$token'));
      ch = c;
      c.stream.listen(
        (d) {
          final e = jsonDecode(d);
          if (e['type'] == 'msg') {
            final m = e['message'];
            if (m['to'] == myId && !fg) {
              final id = (m['id'].toString().hashCode) & 0x7fffffff;
              notif.show(
                id,
                (e['fromName'] ?? 'پیام جدید').toString(),
                m['text'].toString(),
                const NotificationDetails(
                  android: AndroidNotificationDetails(
                    'payam_messages',
                    'پیام‌های جدید',
                    importance: Importance.high,
                    priority: Priority.high,
                  ),
                ),
              );
            }
          }
        },
        onDone: () {
          if (run && identical(ch, c)) retry = Timer(const Duration(seconds: 3), connect);
        },
        onError: (_) {},
      );
    } catch (_) {
      retry = Timer(const Duration(seconds: 3), connect);
    }
  }

  service.on('fg').listen((e) {
    fg = e?['v'] == true;
  });
  service.on('reload').listen((_) => connect());
  service.on('stop').listen((_) {
    run = false;
    retry?.cancel();
    ch?.sink.close();
    service.stopSelf();
  });

  await connect();
  service.invoke('ready');
}

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'bg.dart';

const kRed = Color(0xFFFD1D3F);
const kDark = Color(0xFF20222F);
const kDarker = Color(0xFF181A25);
const kCard = Color(0xFF2A2D3E);

class Api {
  static String base = 'http://10.0.2.2:3000';
  static String token = '';
  static Map? me;
  static final events = StreamController<Map>.broadcast();
  static WebSocketChannel? _ch;
  static bool _run = false;

  static Map<String, String> get _h => {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      };

  static Future<dynamic> post(String p, Map b) async {
    final r = await http.post(Uri.parse('$base$p'), headers: _h, body: jsonEncode(b));
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    if (r.statusCode >= 400) throw (j['error'] ?? 'خطا');
    return j;
  }

  static Future<dynamic> get(String p) async {
    final r = await http.get(Uri.parse('$base$p'), headers: _h);
    if (r.statusCode == 401) throw 'نیاز به ورود مجدد';
    return jsonDecode(utf8.decode(r.bodyBytes));
  }

  static dynamic _out(http.Response r) {
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    if (r.statusCode >= 400) throw (j['error'] ?? 'خطا');
    return j;
  }

  static Future<dynamic> patch(String p, Map b) async =>
      _out(await http.patch(Uri.parse('$base$p'), headers: _h, body: jsonEncode(b)));

  static Future<dynamic> del(String p) async =>
      _out(await http.delete(Uri.parse('$base$p'), headers: _h));

  static Future<bool> load() async {
    final p = await SharedPreferences.getInstance();
    base = p.getString('base') ?? base;
    token = p.getString('token') ?? '';
    final m = p.getString('me');
    if (m != null) me = jsonDecode(m);
    return token.isNotEmpty && me != null;
  }

  static Future<void> store() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('base', base);
    await p.setString('token', token);
    if (me != null) await p.setString('me', jsonEncode(me));
  }

  static Future<void> logout() async {
    Bg.stop();
    _run = false;
    _ch?.sink.close();
    final p = await SharedPreferences.getInstance();
    await p.clear();
    token = '';
    me = null;
  }

  static void connect() {
    if (_run) return;
    _run = true;
    _open();
  }

  static void _open() {
    if (!_run) return;
    final u = base.replaceFirst('http', 'ws');
    try {
      _ch = WebSocketChannel.connect(Uri.parse('$u/ws?token=$token'));
      _ch!.stream.listen(
        (d) => events.add(jsonDecode(d)),
        onDone: () => Future.delayed(const Duration(seconds: 3), _open),
        onError: (_) {},
      );
    } catch (_) {
      Future.delayed(const Duration(seconds: 3), _open);
    }
  }

  static void send(Map m) => _ch?.sink.add(jsonEncode(m));
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initNotifications();
  runApp(const PayamApp());
}

class PayamApp extends StatefulWidget {
  const PayamApp({super.key});
  @override
  State<PayamApp> createState() => _PayamAppState();
}

class _PayamAppState extends State<PayamApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    Bg.setForeground(state == AppLifecycleState.resumed);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'پیام',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: kDark,
        colorScheme: const ColorScheme.dark(primary: kRed, secondary: kRed, surface: kDark),
        appBarTheme: const AppBarTheme(backgroundColor: kDarker, elevation: 0),
        floatingActionButtonTheme: const FloatingActionButtonThemeData(backgroundColor: kRed, foregroundColor: Colors.white),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: kCard,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: kRed,
            foregroundColor: Colors.white,
            minimumSize: const Size.fromHeight(50),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
      ),
      builder: (c, child) => Directionality(textDirection: TextDirection.rtl, child: child!),
      home: const Splash(),
    );
  }
}

class Splash extends StatefulWidget {
  const Splash({super.key});
  @override
  State<Splash> createState() => _SplashState();
}

class _SplashState extends State<Splash> {
  @override
  void initState() {
    super.initState();
    Api.load().then((ok) {
      if (ok) Api.connect();
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => ok ? const ChatsScreen() : const LoginScreen()));
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: Center(child: CircularProgressIndicator(color: kRed)));
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final server = TextEditingController(text: Api.base);
  final phone = TextEditingController();
  final name = TextEditingController();
  final code = TextEditingController();
  bool codeStep = false, busy = false;
  String? msg;

  Future<void> go() async {
    setState(() { busy = true; msg = null; });
    try {
      Api.base = server.text.trim().replaceAll(RegExp(r'/+$'), '');
      if (!codeStep) {
        final r = await Api.post('/auth/request', {'phone': phone.text.trim()});
        setState(() { codeStep = true; msg = r['hint']; });
      } else {
        final r = await Api.post('/auth/verify', {'phone': phone.text.trim(), 'code': code.text.trim(), 'name': name.text.trim()});
        Api.token = r['token'];
        Api.me = r['user'];
        await Api.store();
        Api.connect();
        if (!mounted) return;
        Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const ChatsScreen()));
      }
    } catch (e) {
      setState(() => msg = e.toString());
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(24), children: [
          const SizedBox(height: 40),
          Center(
            child: Container(
              width: 90, height: 90,
              decoration: BoxDecoration(color: kRed, borderRadius: BorderRadius.circular(28)),
              child: const Icon(Icons.chat_bubble_rounded, size: 48, color: Colors.white),
            ),
          ),
          const SizedBox(height: 16),
          const Center(child: Text('پیام', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold))),
          const SizedBox(height: 32),
          TextField(controller: server, textDirection: TextDirection.ltr, decoration: const InputDecoration(labelText: 'آدرس سرور')),
          const SizedBox(height: 12),
          TextField(controller: phone, keyboardType: TextInputType.phone, enabled: !codeStep, textDirection: TextDirection.ltr, decoration: const InputDecoration(labelText: 'شماره تلفن')),
          if (codeStep) ...[
            const SizedBox(height: 12),
            TextField(controller: name, decoration: const InputDecoration(labelText: 'نام (فقط بار اول)')),
            const SizedBox(height: 12),
            TextField(controller: code, keyboardType: TextInputType.number, textDirection: TextDirection.ltr, decoration: const InputDecoration(labelText: 'کد تأیید')),
          ],
          if (msg != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(msg!, style: const TextStyle(color: Colors.white70))),
          const SizedBox(height: 20),
          ElevatedButton(onPressed: busy ? null : go, child: Text(codeStep ? 'ورود' : 'دریافت کد')),
        ]),
      ),
    );
  }
}

String hhmm(int t) {
  final d = DateTime.fromMillisecondsSinceEpoch(t);
  return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

class ChatsScreen extends StatefulWidget {
  const ChatsScreen({super.key});
  @override
  State<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends State<ChatsScreen> with WidgetsBindingObserver {
  List chats = [];
  StreamSubscription? sub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    load();
    sub = Api.events.stream.listen((e) {
      if (['msg', 'status', 'edit', 'delete'].contains(e['type'])) load();
    });
    requestNotificationPermission().whenComplete(Bg.start);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    sub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) load();
  }

  Future<void> load() async {
    try {
      final r = await Api.get('/chats');
      if (mounted) setState(() => chats = r);
    } catch (_) {}
  }

  void open(Map peer) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(peer: peer)));
    load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('پیام', style: TextStyle(color: kRed, fontWeight: FontWeight.bold, fontSize: 24)),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () async {
              await Api.logout();
              if (!mounted) return;
              Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const LoginScreen()));
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        child: const Icon(Icons.edit),
        onPressed: () async {
          final p = await Navigator.push(context, MaterialPageRoute(builder: (_) => const UserSearch()));
          if (p != null) open(p);
        },
      ),
      body: chats.isEmpty
          ? const Center(child: Text('هنوز گفتگویی ندارید.\nبا دکمه قرمز یک مخاطب پیدا کنید.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white54)))
          : ListView.separated(
              itemCount: chats.length,
              separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.white10),
              itemBuilder: (_, i) {
                final c = chats[i];
                final peer = c['peer'];
                return ListTile(
                  leading: CircleAvatar(backgroundColor: kRed, child: Text(peer['name'].toString().characters.first, style: const TextStyle(color: Colors.white))),
                  title: Text(peer['name']),
                  subtitle: Text(c['last']['deleted'] == true ? '🚫 این پیام حذف شد' : c['last']['text'], maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white54)),
                  trailing: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Text(hhmm(c['last']['time']), style: const TextStyle(fontSize: 12, color: Colors.white54)),
                    if (c['unread'] > 0)
                      Container(
                        margin: const EdgeInsets.only(top: 4),
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(color: kRed, borderRadius: BorderRadius.circular(10)),
                        child: Text('${c['unread']}', style: const TextStyle(fontSize: 12)),
                      ),
                  ]),
                  onTap: () => open(peer),
                );
              },
            ),
    );
  }
}

class UserSearch extends StatefulWidget {
  const UserSearch({super.key});
  @override
  State<UserSearch> createState() => _UserSearchState();
}

class _UserSearchState extends State<UserSearch> {
  List users = [];
  @override
  void initState() { super.initState(); search(''); }

  Future<void> search(String q) async {
    try {
      final r = await Api.get('/users?q=${Uri.encodeQueryComponent(q)}');
      if (mounted) setState(() => users = r);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('مخاطب جدید')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(onChanged: search, decoration: const InputDecoration(hintText: 'جستجوی نام یا شماره', prefixIcon: Icon(Icons.search))),
        ),
        Expanded(
          child: ListView(children: [
            for (final u in users)
              ListTile(
                leading: CircleAvatar(backgroundColor: kRed, child: Text(u['name'].toString().characters.first, style: const TextStyle(color: Colors.white))),
                title: Text(u['name']),
                subtitle: Text(u['phone'], textDirection: TextDirection.ltr, textAlign: TextAlign.right),
                onTap: () => Navigator.pop(context, u),
              ),
          ]),
        ),
      ]),
    );
  }
}

class ChatScreen extends StatefulWidget {
  final Map peer;
  const ChatScreen({super.key, required this.peer});
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  static const int editMs = 15 * 60 * 1000;
  static const int deleteAllMs = 48 * 3600 * 1000;

  List<Map> msgs = [];
  final input = TextEditingController();
  StreamSubscription? sub;
  bool typing = false;
  Timer? typingTimer;
  DateTime lastSent = DateTime.fromMillisecondsSinceEpoch(0);
  Map? editing;

  String get pid => widget.peer['id'];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    load();
    sub = Api.events.stream.listen(onEvent);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    sub?.cancel();
    typingTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) load();
  }

  void toast(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  Future<void> load() async {
    try {
      final r = await Api.get('/messages/$pid');
      if (!mounted) return;
      setState(() => msgs = List<Map>.from(r));
      Api.send({'type': 'read', 'peer': pid});
    } catch (_) {}
  }

  void onEvent(Map e) {
    if (!mounted) return;
    final t = e['type'];
    if (t == 'msg') {
      final m = Map.from(e['message']);
      if (m['from'] == pid || m['to'] == pid) {
        setState(() => msgs.add(m));
        if (m['from'] == pid) Api.send({'type': 'read', 'peer': pid});
      }
    } else if (t == 'status') {
      setState(() {
        for (final m in msgs) {
          if (m['id'] == e['id']) m['status'] = e['status'];
        }
      });
    } else if (t == 'edit') {
      final m = Map.from(e['message']);
      setState(() {
        final i = msgs.indexWhere((x) => x['id'] == m['id']);
        if (i >= 0) msgs[i] = m;
      });
    } else if (t == 'delete') {
      applyDelete(e['id'], e['scope'] == 'all');
    } else if (t == 'typing' && e['from'] == pid) {
      setState(() => typing = true);
      typingTimer?.cancel();
      typingTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) setState(() => typing = false);
      });
    }
  }

  void applyDelete(dynamic id, bool all) {
    setState(() {
      if (all) {
        for (final m in msgs) {
          if (m['id'] == id) {
            m['deleted'] = true;
            m['text'] = '';
          }
        }
      } else {
        msgs.removeWhere((x) => x['id'] == id);
      }
      if (editing != null && editing!['id'] == id) {
        editing = null;
        input.clear();
      }
    });
  }

  Future<void> send() async {
    final t = input.text.trim();
    if (t.isEmpty) return;
    if (editing != null) {
      final m = editing!;
      if (t == m['text']) {
        cancelEdit();
        return;
      }
      try {
        final r = await Api.patch('/messages/${m['id']}', {'text': t});
        if (!mounted) return;
        setState(() {
          final i = msgs.indexWhere((x) => x['id'] == m['id']);
          if (i >= 0) msgs[i] = Map.from(r);
        });
        cancelEdit();
      } catch (err) {
        toast(err.toString());
      }
      return;
    }
    Api.send({'type': 'msg', 'to': pid, 'text': t});
    input.clear();
  }

  void cancelEdit() {
    setState(() => editing = null);
    input.clear();
  }

  Future<void> delMsg(Map m, bool all) async {
    Navigator.pop(context);
    try {
      await Api.del('/messages/${m['id']}${all ? '?all=1' : ''}');
      if (mounted) applyDelete(m['id'], all);
    } catch (err) {
      toast(err.toString());
    }
  }

  void openMenu(Map m) {
    final mine = m['from'] == Api.me!['id'];
    final age = DateTime.now().millisecondsSinceEpoch - (m['time'] as int);
    final deleted = m['deleted'] == true;
    showModalBottomSheet(
      context: context,
      backgroundColor: kDarker,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (!deleted)
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('کپی'),
              onTap: () {
                Navigator.pop(context);
                Clipboard.setData(ClipboardData(text: m['text']));
              },
            ),
          if (!deleted && mine && age < editMs)
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('ویرایش'),
              onTap: () {
                Navigator.pop(context);
                setState(() => editing = m);
                input.text = m['text'];
              },
            ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('حذف برای من'),
            onTap: () => delMsg(m, false),
          ),
          if (!deleted && mine && age < deleteAllMs)
            ListTile(
              leading: const Icon(Icons.delete_forever, color: kRed),
              title: const Text('حذف برای همه', style: TextStyle(color: kRed)),
              onTap: () => delMsg(m, true),
            ),
        ]),
      ),
    );
  }

  void onChanged(String _) {
    if (editing != null) return;
    if (DateTime.now().difference(lastSent).inSeconds >= 2) {
      lastSent = DateTime.now();
      Api.send({'type': 'typing', 'to': pid});
    }
  }

  Widget tick(String s) {
    if (s == 'sent') return const Icon(Icons.done, size: 15, color: Colors.white70);
    return Icon(Icons.done_all, size: 15, color: s == 'read' ? Colors.lightBlueAccent : Colors.white70);
  }

  @override
  Widget build(BuildContext context) {
    final myId = Api.me!['id'];
    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          CircleAvatar(radius: 18, backgroundColor: kRed, child: Text(widget.peer['name'].toString().characters.first, style: const TextStyle(color: Colors.white))),
          const SizedBox(width: 10),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.peer['name'], style: const TextStyle(fontSize: 16)),
            if (typing) const Text('در حال تایپ…', style: TextStyle(fontSize: 12, color: kRed)),
          ]),
        ]),
      ),
      body: Column(children: [
        Expanded(
          child: ListView.builder(
            reverse: true,
            padding: const EdgeInsets.all(10),
            itemCount: msgs.length,
            itemBuilder: (_, i) {
              final m = msgs[msgs.length - 1 - i];
              final mine = m['from'] == myId;
              final deleted = m['deleted'] == true;
              return Align(
                alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                child: GestureDetector(
                  onLongPress: () => openMenu(m),
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 3),
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
                    constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
                    decoration: BoxDecoration(
                      color: deleted ? kCard : (mine ? kRed : kCard),
                      borderRadius: BorderRadius.only(
                        topLeft: const Radius.circular(16), topRight: const Radius.circular(16),
                        bottomRight: Radius.circular(mine ? 4 : 16), bottomLeft: Radius.circular(mine ? 16 : 4),
                      ),
                    ),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                      deleted
                          ? const Text('🚫 این پیام حذف شد', style: TextStyle(fontSize: 15, fontStyle: FontStyle.italic, color: Colors.white60))
                          : Text(m['text'], style: const TextStyle(fontSize: 16)),
                      const SizedBox(height: 2),
                      Row(mainAxisSize: MainAxisSize.min, children: [
                        if (m['edited'] == true && !deleted) ...[
                          const Text('ویرایش‌شده', style: TextStyle(fontSize: 11, color: Colors.white70)),
                          const SizedBox(width: 6),
                        ],
                        Text(hhmm(m['time']), style: const TextStyle(fontSize: 11, color: Colors.white70)),
                        if (mine && !deleted) ...[const SizedBox(width: 4), tick(m['status'])],
                      ]),
                    ]),
                  ),
                ),
              );
            },
          ),
        ),
        if (editing != null)
          Container(
            color: kCard,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(children: [
              const Icon(Icons.edit, size: 18, color: kRed),
              const SizedBox(width: 8),
              Expanded(child: Text('ویرایش پیام: ${editing!['text']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70))),
              IconButton(icon: const Icon(Icons.close), onPressed: cancelEdit),
            ]),
          ),
        SafeArea(
          child: Container(
            color: kDarker,
            padding: const EdgeInsets.all(8),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: input,
                  onChanged: onChanged,
                  minLines: 1,
                  maxLines: 5,
                  decoration: InputDecoration(hintText: editing != null ? 'متن جدید...' : 'پیام...', contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
                ),
              ),
              const SizedBox(width: 8),
              CircleAvatar(
                backgroundColor: kRed,
                child: IconButton(icon: Icon(editing != null ? Icons.check : Icons.send, color: Colors.white), onPressed: send),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}

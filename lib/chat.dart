// ══════════════════════════════════════════════════════════════
// chat.dart — Chat module (Supabase REST, reply, multi-delete)
// ══════════════════════════════════════════════════════════════
import 'dart:async';
import 'dart:convert';
import 'nft_chat.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
//
// Подключение в wallet.dart (_MainShell):
//
//   ChatPage(
//     walletAddress: widget.address ?? "0x...",
//     privateKeyHex: widget.privateKeyHex ?? '',
//     tokens: walletState?._tokens ?? [],  // List<TokenBalance>
//   ),
//
// Адрес кошелька: widget.address из _MainShell (String? _address в _WalletPageState)
// Стейкинг: ChatPage сам загружает через Aptos REST API (логика из staking.dart)
// Ники: основной источник — таблица `nicknames` (addr, nick)
//       при presence-update также пишется в chat_presence.nick
// Рейтинг (chatScore) = meeWallet + meeStaked + megaWallet + megaStaked
//   (все единицы в «монетах», decimals уже применены)
// ══════════════════════════════════════════════════════════════

// ── Форматирование рейтинга ─────────────────────────────────
String _formatRating(double score) {
  if (score >= 1000000) return "${(score/1000000).toStringAsFixed(score>=10000000?0:1)}M";
  if (score >= 1000)    return "${(score/1000).toStringAsFixed(score>=10000?0:1)}k";
  if (score >= 1)       return score.toStringAsFixed(0);
  if (score > 0)        return score.toStringAsFixed(1);
  return "0";
}

Color _ratingColor(double score) {
  if (score >= 1000) return const Color(0xFFCE93D8);
  if (score >= 100)  return const Color(0xFFFFD54F);
  if (score >= 10)   return const Color(0xFF4FC3F7);
  if (score >= 1)    return const Color(0xFF81C784);
  return const Color(0xFF78909C);
}

Widget _rankDot(double score, bool isAdmin) {
  if (isAdmin) {
    return Padding(
        padding: EdgeInsets.symmetric(horizontal: 3),
        child: Icon(Icons.star_rounded, color: Colors.orangeAccent, size: 13));
  }
  if (score >= 1000) {
    return Padding(
        padding: EdgeInsets.symmetric(horizontal: 3),
        child: Text("🐋", style: TextStyle(fontSize: 11)));
  }
  final double sz = score >= 100 ? 10 : score >= 1 ? 7 : 5;
  final Color c = _ratingColor(score);
  return Container(
      width: sz, height: sz,
      margin: EdgeInsets.symmetric(horizontal: 3),
      decoration: BoxDecoration(
          shape: BoxShape.circle, color: c,
          boxShadow: [BoxShadow(color: c.withOpacity(0.5), blurRadius: 3)]));
}

// Медали для топ-3
String _medalEmoji(int rank) {
  if (rank == 0) return "🥇";
  if (rank == 1) return "🥈";
  if (rank == 2) return "🥉";
  return "";
}

// ── Доступные реакции ────────────────────────────────────────
const List<String> kReactions = ['👍', '👎', '🔥', '💯', '😊', '🤔'];

// ── Модель сообщения ────────────────────────────────────────
class ChatMsg {
  final int id;
  final String sender;      // короткий адрес (для совместимости)
  final String fullSender;  // полный адрес
  final String text;
  final DateTime time;
  final bool isOwn;
  final double rating;
  final int? replyToId;
  final String? replyToText;
  final String? replyToSender; // полный адрес отправителя оригинала (для резолва ника)
  // emoji -> количество (загружается из chat_reactions)
  final Map<String, int> reactions;

  ChatMsg({
    required this.id, required this.sender, required this.fullSender,
    required this.text, required this.time, required this.isOwn,
    this.rating = 0, this.replyToId, this.replyToText, this.replyToSender,
    Map<String, int>? reactions,
  }) : reactions = reactions ?? {};
}

// ── Модель для presence/топа ─────────────────────────────────
class ChatUser {
  final String addr;
  final String? nick;
  final double rating;
  final DateTime lastSeen;
  final double meeWallet;
  final double meeStaked;
  final double megaWallet;
  final double megaStaked;

  ChatUser({
    required this.addr, this.nick, required this.rating, required this.lastSeen,
    this.meeWallet = 0, this.meeStaked = 0, this.megaWallet = 0, this.megaStaked = 0,
  });

  // Ник из таблицы nicknames (передаётся снаружи) или из presence, или короткий адрес
  String displayName(Map<String, String> nicksCache) {
    final cached = nicksCache[addr.toLowerCase()];
    if (cached != null && cached.isNotEmpty) return cached;
    if (nick != null && nick!.isNotEmpty) return nick!;
    return addr.length >= 10
        ? "${addr.substring(0,6)}...${addr.substring(addr.length-4)}"
        : addr;
  }
}

// ══════════════════════════════════════════════════════════════
// ChatPage — обёртка, которая подгружает стейкинг и передаёт
// все данные в NostrChatScreen.
//
// Вызов из _MainShellState (wallet.dart):
//   ChatPage(walletAddress: widget.address ?? "0x...", tokens: walletTokens)
//
// walletTokens — List<TokenBalance> из _WalletPageState._tokens
// (берётся через context.findAncestorStateOfType<_WalletPageState>()
//  так же, как это делает _MainShellState сейчас для chatScore)
// ══════════════════════════════════════════════════════════════
class ChatPage extends StatefulWidget {
  final String walletAddress;
  // Балансы токенов в кошельке (MEE, MEGA) — из _WalletPageState._tokens
  final double meeWallet;
  final double megaWallet;

 final VoidCallback? onBack;

  const ChatPage({
    super.key,
    required this.walletAddress,
    this.meeWallet = 0,
    this.megaWallet = 0,
    this.onBack,
  });

 /* 
  const ChatPage({
    super.key,
    required this.walletAddress,
    this.meeWallet = 0,
    this.megaWallet = 0,
  });*/

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  // Стейкинг загружается самостоятельно (логика из staking.dart)
  double _meeStaked = 0.0;
  double _megaStaked = 0.0;
  bool _stakingLoaded = false;

  // ── Aptos REST константы (из staking.dart) ─────────────────
  static const String _aptosNode = "https://fullnode.mainnet.aptoslabs.com/v1";
  static const String _meeCoin =
      "0xe9c192ff55cffab3963c695cff6dbf9dad6aff2bb5ac19a6415cad26a81860d9::mee_coin::MeeCoin";
  static const String _meeStakingResource =
      "0x514cfb77665f99a2e4c65a5614039c66d13e00e98daf4c86305651d29fd953e5::Staking::StakeInfo<$_meeCoin,$_meeCoin>";
  static const String _megaStakingResource =
      "0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3::mega_coin::StakePosition";

  @override
  void initState() {
    super.initState();
    _loadStaking();
  }

  @override
  void didUpdateWidget(ChatPage old) {
    super.didUpdateWidget(old);
    // Перегружаем стейкинг если изменился адрес кошелька
    if (old.walletAddress != widget.walletAddress) {
      _loadStaking();
    }
  }

  // Загружает MEE + MEGA стейкинг параллельно (логика из _StakingPageState)
  Future<void> _loadStaking() async {
    final addr = widget.walletAddress;
    if (addr.isEmpty || addr == "0x0000000000000000000000000000000000000000") {
      setState(() { _meeStaked = 0; _megaStaked = 0; _stakingLoaded = true; });
      return;
    }
    try {
      await Future.wait([_fetchMeeStake(addr), _fetchMegaStake(addr)]);
    } catch (_) {}
    if (mounted) setState(() => _stakingLoaded = true);
  }

  // Стейкинг MEE (из staking.dart _fetchMeeStake)
  // Decimals: amount / 1_000_000 (6 знаков)
  Future<void> _fetchMeeStake(String addr) async {
    try {
      final url = Uri.parse(
          "$_aptosNode/accounts/$addr/resource/${Uri.encodeComponent(_meeStakingResource)}");
      final resp = await http.get(url).timeout(const Duration(seconds: 6));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body)['data'];
        final amount = int.tryParse(data['amount'].toString()) ?? 0;
        _meeStaked = amount / 1000000; // 6 decimals (как в staking.dart)
      } else {
        _meeStaked = 0.0;
      }
    } catch (_) {
      _meeStaked = 0.0;
    }
  }

  // Стейкинг MEGA (из staking.dart _fetchMegaStake)
  // Decimals: amount / 100_000_000 (8 знаков)
  Future<void> _fetchMegaStake(String addr) async {
    try {
      final url = Uri.parse(
          "$_aptosNode/accounts/$addr/resource/${Uri.encodeComponent(_megaStakingResource)}");
      final resp = await http.get(url).timeout(const Duration(seconds: 6));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        final amount = int.tryParse(data['data']['amount'].toString()) ?? 0;
        _megaStaked = amount / 100000000; // 8 decimals
      } else {
        _megaStaked = 0.0;
      }
    } catch (_) {
      _megaStaked = 0.0;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Рейтинг = кошелёк + стейкинг (MEE + MEGA, все в «монетах»)
    final myScore = widget.meeWallet + _meeStaked + widget.megaWallet + _megaStaked;

    return NostrChatScreen(
      walletAddress: widget.walletAddress,
      myScore: myScore,
      meeWallet: widget.meeWallet,
      meeStakedAmt: _meeStaked,
      megaWallet: widget.megaWallet,
      megaStakedAmt: _megaStaked,
      onBack: widget.onBack,
    );
  }
}

// ── Экран чата ──────────────────────────────────────────────
class NostrChatScreen extends StatefulWidget {
  final String walletAddress;
  final double myScore;
  final double meeWallet;
  final double meeStakedAmt;
  final double megaWallet;
  final double megaStakedAmt;

  final VoidCallback? onBack;

  const NostrChatScreen({
    super.key,
    required this.walletAddress,
    this.myScore = 0,
    this.meeWallet = 0,
    this.meeStakedAmt = 0,
    this.megaWallet = 0,
    this.megaStakedAmt = 0,
    this.onBack,
  });

  @override
  State<NostrChatScreen> createState() => _NostrChatScreenState();
}

class _NostrChatScreenState extends State<NostrChatScreen> {
  final TextEditingController _msgCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();

  final Map<int, ChatMsg> _msgMap = {};
  List<ChatMsg> get _msgs {
    final all = _msgMap.values.toList()..sort((a,b) => a.time.compareTo(b.time));
    if (all.length > 200) return all.sublist(all.length - 200);
    return all;
  }

  bool _connected = false, _connecting = true;
  String _statusText = "Подключение...", _lastError = "";
  Timer? _pollTimer, _presenceTimer;
  bool _sending = false;
  ChatMsg? _replyTo;

  // Реакции: msgId -> Set<emoji> (мои реакции на это сообщение)
  final Map<int, Set<String>> _myReactions = {};

  final Set<String> _blockedAddrs = {};

  // ── Ники ──────────────────────────────────────────────────
  // Основной источник: таблица `nicknames` (addr -> nick).
  // Ключ: addr.toLowerCase()
  // При отображении: _nicks[addr.lower] ?? shortAddr
  final Map<String, String> _nicks = {};

  final Map<String, double> _ratings = {};  // addr.lower -> rating (кэш из сообщений)
  List<String> _topAddrs = [];              // топ-3 адреса по рейтингу (для медалей)
  int _onlineCount = 0;

  bool _hasMore = false, _loadingMore = false;
  bool _isAtBottom = true;

  // Оптимизация:
  // _pageSize=50  — начальная загрузка
  // _loadMore=20  — при скролле вверх
  // _maxHistory=500 — хранить в БД
  // UI: макс 200 последних сообщений
  static const int _pageSize = 50, _maxHistory = 500, _maxMsgLength = 4096;

 
  


  bool get _isAdmin => widget.walletAddress.toLowerCase() == _adminWallet.toLowerCase();
  bool _isAdminAddr(String a) => a.toLowerCase() == _adminWallet.toLowerCase();
  bool _isBlocked(String a) => _blockedAddrs.contains(a.toLowerCase());
  bool get _iAmBlocked => _isBlocked(widget.walletAddress);

  String get _shortAddr => _shortOf(widget.walletAddress);

  String _shortOf(String a) =>
      a.length >= 10 ? "${a.substring(0,6)}...${a.substring(a.length-4)}" : a;

  // ── Резолв ника ───────────────────────────────────────────
  // 1. Ищем в таблице nicknames (_nicks, загружается при старте и обновляется)
  // 2. Если нет — короткий адрес
  String _displayName(String addr) =>
      _nicks[addr.toLowerCase()]?.isNotEmpty == true
          ? _nicks[addr.toLowerCase()]!
          : _shortOf(addr);

  String get _myDisplayName => _displayName(widget.walletAddress);

  // Медаль адреса (пустая строка если не в топ-3)
  String _medal(String addr) {
    final i = _topAddrs.indexOf(addr.toLowerCase());
    return i >= 0 && i < 3 ? _medalEmoji(i) : "";
  }

  static String _san(String s) {
    final b = StringBuffer();
    for (final r in s.runes) {
      if (r >= 0xD800 && r <= 0xDFFF) continue;
      if (r > 0x10FFFF) continue;
      b.writeCharCode(r);
    }
    return b.toString();
  }

  // Ники, зарезервированные для администратора
  static bool _isAdminNick(String n) {
    final l = n.toLowerCase();
    return l.startsWith('adm') || l.startsWith('адм');
  }

  void _toast(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: TextStyle(color: Colors.white, fontSize: 13)),
      backgroundColor: isError ? Colors.redAccent.shade700 : Color(0xFF1E1E1E),
      duration: const Duration(seconds: 1), behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      margin: EdgeInsets.all(12),
    ));
  }

  // ── Lifecycle ──────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _loadBlocked();
    // Загружаем ники из nicknames ДО инициализации чата
    _loadNicks().then((_) {
      if (mounted) _initChat();
    });
    _scrollCtrl.addListener(_onScroll);
    _updatePresence();
    _presenceTimer = Timer.periodic(const Duration(seconds: 20), (_) => _updatePresence());
  }

  @override
  void dispose() {
    _pollTimer?.cancel(); _presenceTimer?.cancel();
    _msgCtrl.dispose();
    _scrollCtrl.removeListener(_onScroll); _scrollCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollCtrl.hasClients) return;
    final pos = _scrollCtrl.position;
    _isAtBottom = pos.maxScrollExtent - pos.pixels < 80;
    if (pos.pixels < 150 && _hasMore && !_loadingMore) _loadOlderMessages();
  }

  // ── Presence (онлайн + топ) ────────────────────────────────

  Future<void> _updatePresence() async {
    // Записываем своё присутствие (обновляем или вставляем)
    // В chat_presence.nick дублируем ник из _nicks (для удобства топа),
    // но основным источником для отображения всегда является таблица nicknames.
    final myNick = _nicks[widget.walletAddress.toLowerCase()];
    try {
      await http.post(
        Uri.parse("$_supabaseUrl/rest/v1/chat_presence"),
        headers: {..._h, "Prefer": "resolution=merge-duplicates,return=minimal"},
        body: jsonEncode({
          "addr": widget.walletAddress,
          "nick": (myNick != null && myNick.isNotEmpty) ? myNick : null,
          "rating": widget.myScore,
          "mee_wallet": widget.meeWallet,
          "mee_staked": widget.meeStakedAmt,
          "mega_wallet": widget.megaWallet,
          "mega_staked": widget.megaStakedAmt,
          "last_seen": DateTime.now().toUtc().toIso8601String(),
        }),
      ).timeout(const Duration(seconds: 5));
    } catch (_) {}

    // Считаем онлайн (активны последние 2 минуты)
    try {
      final twoMinsAgo = DateTime.now().toUtc()
          .subtract(const Duration(minutes: 2)).toIso8601String();
      final onlineResp = await http.get(
        Uri.parse("$_supabaseUrl/rest/v1/chat_presence?last_seen=gte.$twoMinsAgo&select=addr"),
        headers: {..._h, "Prefer": "count=exact"},
      ).timeout(const Duration(seconds: 5));
      final countStr = onlineResp.headers['content-range'] ?? '';
      final cnt = int.tryParse(countStr.split('/').last) ?? 0;
      if (mounted) setState(() => _onlineCount = cnt);
    } catch (_) {}

    // Топ-3 адреса по рейтингу (для медалей 🥇🥈🥉)
    try {
      final topResp = await http.get(
        Uri.parse("$_supabaseUrl/rest/v1/chat_presence?select=addr,rating&order=rating.desc&limit=3"),
        headers: _h,
      ).timeout(const Duration(seconds: 5));
      if (topResp.statusCode == 200) {
        final List data = jsonDecode(topResp.body);
        if (mounted) {
          setState(() {
            _topAddrs = data.map((r) => (r['addr'] as String).toLowerCase()).toList();
          });
        }
      }
    } catch (_) {}
  }

  // ── Топ участников (диалог) ────────────────────────────────

  Future<void> _showTopList() async {
    List<ChatUser> users = [];
    try {
      final resp = await http.get(
        Uri.parse("$_supabaseUrl/rest/v1/chat_presence"
            "?select=addr,nick,rating,last_seen,mee_wallet,mee_staked,mega_wallet,mega_staked"
            "&order=rating.desc"),
        headers: _h,
      ).timeout(const Duration(seconds: 8));
      if (resp.statusCode == 200) {
        final List data = jsonDecode(resp.body);
        users = data.map((r) => ChatUser(
          addr: r['addr'] as String,
          nick: r['nick'] as String?,          // ник из chat_presence (дублируется из nicknames)
          rating: (r['rating'] as num?)?.toDouble() ?? 0,
          lastSeen: DateTime.tryParse(r['last_seen'] as String? ?? '') ?? DateTime(2000),
          meeWallet:  (r['mee_wallet']  as num?)?.toDouble() ?? 0,
          meeStaked:  (r['mee_staked']  as num?)?.toDouble() ?? 0,
          megaWallet: (r['mega_wallet'] as num?)?.toDouble() ?? 0,
          megaStaked: (r['mega_staked'] as num?)?.toDouble() ?? 0,
        )).toList();
      }
    } catch (_) {}

    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Color(0xFF0D0D0D),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: Colors.cyanAccent.withOpacity(0.3))),
        titlePadding: EdgeInsets.fromLTRB(20, 16, 20, 0),
        contentPadding: EdgeInsets.fromLTRB(12, 10, 12, 0),
        title: const Text("🏆 ТОП участников",
            style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
        content: SizedBox(
          width: double.maxFinite,
          height: 400,
          child: users.isEmpty
              ? Center(child: Text("Нет данных", style: TextStyle(color: Colors.white54)))
              : ListView.builder(
                  itemCount: users.length,
                  itemBuilder: (_, i) {
                    final u = users[i];
                    final medal = i < 3 ? _medalEmoji(i) : "";
                    final rColor = _ratingColor(u.rating);
                    final isMe = u.addr.toLowerCase() == widget.walletAddress.toLowerCase();
                    // Приоритет: nicknames (_nicks) → chat_presence.nick → shortAddr
                    final name = u.displayName(_nicks);
                    return GestureDetector(
                      onTap: _isAdmin ? () => _showUserDetail(ctx, u, i) : null,
                      child: Container(
                        margin: EdgeInsets.symmetric(vertical: 3, horizontal: 4),
                        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: isMe
                              ? Colors.cyanAccent.withOpacity(0.08)
                              : i < 3 ? Colors.white.withOpacity(0.04) : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: isMe ? Colors.cyanAccent.withOpacity(0.3)
                                : i < 3 ? Colors.white.withOpacity(0.08) : Colors.transparent,
                          ),
                        ),
                        child: Row(children: [
                          SizedBox(width: 28,
                              child: Text(medal.isNotEmpty ? medal : "${i+1}",
                                  style: TextStyle(
                                      fontSize: medal.isNotEmpty ? 16 : 12,
                                      color: Colors.white38),
                                  textAlign: TextAlign.center)),
                          SizedBox(width: 8),
                          _rankDot(u.rating, _isAdminAddr(u.addr)),
                          SizedBox(width: 6),
                          Expanded(child: Text(name,
                              style: TextStyle(
                                  color: isMe ? Colors.cyanAccent : Colors.white70,
                                  fontSize: 13, fontWeight: FontWeight.w600),
                              overflow: TextOverflow.ellipsis)),
                          Text(_formatRating(u.rating),
                              style: TextStyle(color: rColor, fontSize: 13,
                                  fontWeight: FontWeight.bold)),
                          if (_isAdmin)
                            Padding(
                              padding: EdgeInsets.only(left: 6),
                              child: Icon(Icons.info_outline, size: 14, color: Colors.white24),
                            ),
                        ]),
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx),
              child: Text("Закрыть", style: TextStyle(color: Colors.cyanAccent))),
        ],
      ),
    );
  }

  // ── Детальная информация по пользователю (только для админа) ─

  void _showUserDetail(BuildContext parentCtx, ChatUser u, int rank) {
    final medal = rank < 3 ? _medalEmoji(rank) : "";
    final name = u.displayName(_nicks);
    showDialog(
      context: parentCtx,
      builder: (ctx) => AlertDialog(
        backgroundColor: Color(0xFF111111),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.orangeAccent.withOpacity(0.4)),
        ),
        titlePadding: EdgeInsets.fromLTRB(20, 16, 20, 8),
        contentPadding: EdgeInsets.fromLTRB(20, 0, 20, 8),
        title: Row(children: [
          if (medal.isNotEmpty)
            Padding(padding: EdgeInsets.only(right: 6),
                child: Text(medal, style: TextStyle(fontSize: 18))),
          _rankDot(u.rating, _isAdminAddr(u.addr)),
          SizedBox(width: 6),
          Expanded(child: Text(name,
              style: TextStyle(color: Colors.white, fontSize: 15,
                  fontWeight: FontWeight.bold),
              overflow: TextOverflow.ellipsis)),
        ]),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          // Полный адрес кошелька
          Container(
            padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.04),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(children: [
              Icon(Icons.account_balance_wallet_outlined, size: 14, color: Colors.white38),
              SizedBox(width: 6),
              Expanded(child: Text(u.addr,
                  style: TextStyle(color: Colors.white38, fontSize: 10),
                  overflow: TextOverflow.ellipsis)),
              IconButton(
                icon: Icon(Icons.copy, size: 12, color: Colors.white24),
                padding: EdgeInsets.zero,
                constraints: BoxConstraints(),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: u.addr));
                  Navigator.pop(ctx);
                  _toast("Адрес скопирован");
                },
              ),
            ]),
          ),
          SizedBox(height: 14),
          // Суммарный рейтинг
          _detailRow("📊 Суммарный рейтинг", _formatRating(u.rating),
              _ratingColor(u.rating), large: true),
          Divider(color: Colors.white12, height: 20),
          // MEE
          Align(alignment: Alignment.centerLeft,
              child: Text("MEE",
                  style: TextStyle(color: Colors.cyanAccent, fontSize: 11,
                      fontWeight: FontWeight.bold, letterSpacing: 1))),
          SizedBox(height: 6),
          _detailRow("💼 В кошельке",
              "${u.meeWallet.toStringAsFixed(2)} MEE", Colors.white70),
          SizedBox(height: 4),
          _detailRow("🔒 В стейкинге",
              "${u.meeStaked.toStringAsFixed(2)} MEE", Colors.cyanAccent),
          _detailRow("  Итого MEE",
              "${(u.meeWallet + u.meeStaked).toStringAsFixed(2)}", Colors.white54,
              small: true),
          Divider(color: Colors.white12, height: 20),
          // MEGA
          Align(alignment: Alignment.centerLeft,
              child: Text("MEGA",
                  style: TextStyle(color: Colors.greenAccent, fontSize: 11,
                      fontWeight: FontWeight.bold, letterSpacing: 1))),
          SizedBox(height: 6),
          _detailRow("💼 В кошельке",
              "${u.megaWallet.toStringAsFixed(4)} MEGA", Colors.white70),
          SizedBox(height: 4),
          _detailRow("🔒 В стейкинге",
              "${u.megaStaked.toStringAsFixed(4)} MEGA", Colors.greenAccent),
          _detailRow("  Итого MEGA",
              "${(u.megaWallet + u.megaStaked).toStringAsFixed(4)}", Colors.white54,
              small: true),
          SizedBox(height: 8),
          // Последний визит
          Align(alignment: Alignment.centerRight,
              child: Text(
                "Последний визит: ${_formatPresenceTime(u.lastSeen)}",
                style: TextStyle(color: Colors.white24, fontSize: 10),
              )),
          // Кнопки управления (только для не-admin пользователей)
          if (!_isAdminAddr(u.addr)) ...[
            Divider(color: Colors.white12, height: 20),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton.icon(
                icon: Icon(
                  _isBlocked(u.addr) ? Icons.lock_open : Icons.block,
                  size: 14,
                  color: _isBlocked(u.addr) ? Colors.greenAccent : Colors.redAccent,
                ),
                label: Text(
                  _isBlocked(u.addr) ? "Разблокировать" : "Заблокировать",
                  style: TextStyle(
                    color: _isBlocked(u.addr) ? Colors.greenAccent : Colors.redAccent,
                    fontSize: 12,
                  ),
                ),
                onPressed: () async {
                  Navigator.pop(ctx);
                  if (_isBlocked(u.addr)) {
                    await _unblockUser(u.addr);
                    _toast("Разблокировано: ${_shortOf(u.addr)}");
                  } else {
                    await _blockUser(u.addr);
                    _toast("Заблокировано: ${_shortOf(u.addr)}", isError: true);
                  }
                },
              ),
            ]),
          ],
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx),
              child: Text("Закрыть", style: TextStyle(color: Colors.white54))),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value, Color valueColor,
      {bool large = false, bool small = false}) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: small ? 1 : 2),
      child: Row(children: [
        Expanded(child: Text(label,
            style: TextStyle(
                color: small ? Colors.white24 : Colors.white54,
                fontSize: small ? 10 : 12))),
        Text(value,
            style: TextStyle(
                color: valueColor,
                fontSize: large ? 16 : small ? 10 : 13,
                fontWeight: large ? FontWeight.bold : FontWeight.w600)),
      ]),
    );
  }

  String _formatPresenceTime(DateTime t) {
    final now = DateTime.now().toUtc();
    final diff = now.difference(t.toUtc());
    if (diff.inMinutes < 2) return "только что";
    if (diff.inMinutes < 60) return "${diff.inMinutes} мин. назад";
    if (diff.inHours < 24) return "${diff.inHours} ч. назад";
    return "${diff.inDays} дн. назад";
  }

  // ── Парсинг сообщения ────────────────────────────────────

  ChatMsg? _parseRow(dynamic raw) {
    try {
      final m = raw as Map;
      final id = m['id'] as int? ?? 0;
      final addr = _san(m['addr'] as String? ?? '');
      if (_isBlocked(addr)) return null;
      final text = _san(m['text'] as String? ?? '');
      if (text.isEmpty) return null;
      final ratingRaw = m['rating'];
      final rating = ratingRaw is num ? ratingRaw.toDouble() : 0.0;
      // Кэшируем рейтинг из сообщений (запасной вариант, если нет presence)
      _ratings[addr.toLowerCase()] = rating;
      return ChatMsg(
        id: id, sender: _shortOf(addr), fullSender: addr, text: text,
        time: DateTime.fromMillisecondsSinceEpoch(m['ts'] as int? ?? 0),
        isOwn: addr.toLowerCase() == widget.walletAddress.toLowerCase(),
        rating: rating,
        replyToId: m['reply_to_id'] as int?,
        replyToText: m['reply_to_text'] != null ? _san(m['reply_to_text'] as String) : null,
        // reply_to_sender хранит полный адрес оригинала — для резолва ника
        replyToSender: m['reply_to_sender'] as String?,
      );
    } catch (_) { return null; }
  }

  bool _addMessages(List<ChatMsg> msgs) {
    bool added = false;
    for (final msg in msgs) {
      if (!_msgMap.containsKey(msg.id)) { _msgMap[msg.id] = msg; added = true; }
    }
    return added;
  }

  // ── Загрузка ────────────────────────────────────────────

  Future<void> _initChat() async {
    if (!mounted) return;
    setState(() { _connecting = true; _statusText = "Загрузка..."; });
    try {
      final resp = await http.get(
        Uri.parse("$_supabaseUrl/rest/v1/messages?select=*&order=id.desc&limit=$_pageSize"),
        headers: _h,
      ).timeout(const Duration(seconds: 8));
      if (!mounted) return;
      if (resp.statusCode == 200) {
        final List data = jsonDecode(resp.body);
        final msgs = data.map(_parseRow).whereType<ChatMsg>().toList();
        _hasMore = data.length >= _pageSize;
        setState(() {
          _msgMap.clear();
          for (final m in msgs) { _msgMap[m.id] = m; }
          _connected = true; _connecting = false; _statusText = "В сети"; _lastError = "";
        });

        // Повторяем скролл пока список не построится полностью
        _scrollToBottomWithRetry();

        // Загружаем реакции для начальных сообщений
        _loadReactions(_msgMap.keys.toList());
      } else { _setError("Ошибка ${resp.statusCode}"); }
    } catch (e) { _setError(e.toString().split(':').first); }
    _pollTimer = Timer.periodic(const Duration(seconds: 4), (_) => _fetchNew());
  }

  Future<void> _fetchNew() async {
    if (_msgMap.isEmpty) return;
    final maxId = _msgMap.keys.reduce((a,b) => a>b?a:b);
    try {
      final resp = await http.get(
        Uri.parse("$_supabaseUrl/rest/v1/messages?select=*&id=gt.$maxId&order=id.asc&limit=20"),
        headers: _h,
      ).timeout(const Duration(seconds: 6));
      if (!mounted || resp.statusCode != 200) return;
      final List data = jsonDecode(resp.body);
      if (data.isEmpty) return;
      final msgs = data.map(_parseRow).whereType<ChatMsg>().toList();
      final added = _addMessages(msgs);
      if (added && mounted) {
        setState(() {});
        if (_isAtBottom) Future.delayed(const Duration(milliseconds: 100), _scrollToBottom);
      }
      if (!_connected && mounted) setState(() { _connected = true; _statusText = "В сети"; });
    } catch (_) {}
  }

  Future<void> _loadOlderMessages() async {
    if (_loadingMore || !_hasMore || _msgMap.isEmpty) return;
    setState(() => _loadingMore = true);
    final minId = _msgMap.keys.reduce((a,b) => a<b?a:b);
    final prevExtent = _scrollCtrl.hasClients ? _scrollCtrl.position.maxScrollExtent : 0.0;
    try {
      final resp = await http.get(
        Uri.parse("$_supabaseUrl/rest/v1/messages?select=*&id=lt.$minId&order=id.desc&limit=20"),
        headers: _h,
      ).timeout(const Duration(seconds: 8));
      if (!mounted) return;
      if (resp.statusCode == 200) {
        final List data = jsonDecode(resp.body);
        final msgs = data.map(_parseRow).whereType<ChatMsg>().toList();
        _hasMore = data.length >= 20;
        _addMessages(msgs);
        // Очищаем из памяти если слишком много
        if (_msgMap.length > 300) {
          final sortedIds = _msgMap.keys.toList()..sort();
          for (final id in sortedIds.take(_msgMap.length - 250)) {
            _msgMap.remove(id);
          }
        }
        setState(() {});
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollCtrl.hasClients) {
            final diff = _scrollCtrl.position.maxScrollExtent - prevExtent;
            if (diff > 0) _scrollCtrl.jumpTo(_scrollCtrl.offset + diff);
          }
        });
      }
    } catch (_) {}
    if (mounted) setState(() => _loadingMore = false);
  }

  void _setError(String msg) {
    if (!mounted) return;
    setState(() {
      _lastError = msg;
      if (_connecting) { _connected = false; _connecting = false; _statusText = "Ошибка"; }
    });
  }

  Future<void> _trimHistory() async {
    try {
      final countResp = await http.get(
        Uri.parse("$_supabaseUrl/rest/v1/messages?select=id&order=id.asc"),
        headers: {..._h, "Prefer": "count=exact"},
      ).timeout(const Duration(seconds: 6));
      final total = int.tryParse(
          (countResp.headers['content-range'] ?? '').split('/').last) ?? 0;
      if (total <= _maxHistory) return;
      final toDelete = total - _maxHistory;
      final oldResp = await http.get(
          Uri.parse("$_supabaseUrl/rest/v1/messages?select=id&order=id.asc&limit=$toDelete"),
          headers: _h).timeout(const Duration(seconds: 6));
      if (oldResp.statusCode == 200) {
        final ids = (jsonDecode(oldResp.body) as List).map((m) => m['id']).toList();
        if (ids.isNotEmpty) {
          await http.delete(
              Uri.parse("$_supabaseUrl/rest/v1/messages?id=in.(${ids.join(',')})"),
              headers: {..._h, "Prefer": "return=minimal"}).timeout(const Duration(seconds: 8));
        }
      }
    } catch (_) {}
  }

  // ── Отправка ────────────────────────────────────────────

  Future<void> _sendMessage() async {
    if (_iAmBlocked) { _toast("🚫 Вы заблокированы за спам.", isError: true); return; }
    final raw = _msgCtrl.text.trim();
    if (raw.isEmpty || _sending) return;
    if (raw.length > _maxMsgLength) {
      _toast("Сообщение слишком длинное (макс. $_maxMsgLength)", isError: true); return;
    }
    final text = _san(raw);
    if (text.isEmpty) return;
    _msgCtrl.clear();
    final reply = _replyTo;
    setState(() { _sending = true; _replyTo = null; });

    try {
      final body = <String, dynamic>{
        "addr": widget.walletAddress,
        "text": text,
        "ts": DateTime.now().millisecondsSinceEpoch,
        "rating": widget.myScore,
        if (reply != null) ...{
          "reply_to_id": reply.id,
          "reply_to_text": reply.text.length > 80
              ? reply.text.substring(0,80)+"..." : reply.text,
          // Сохраняем полный адрес оригинала — для резолва ника при отображении
          "reply_to_sender": reply.fullSender,
        },
      };
      final resp = await http.post(
          Uri.parse("$_supabaseUrl/rest/v1/messages"),
          headers: _h, body: jsonEncode(body)).timeout(const Duration(seconds: 8));

      if (resp.statusCode == 400 || resp.statusCode == 500) {
        if (resp.body.contains('rate_limit')) {
          _toast("Слишком часто! Подождите 3 секунды.", isError: true);
          _msgCtrl.text = text;
        }
      }
      if (DateTime.now().second % 20 == 0) _trimHistory();
    } catch (_) {}
    finally { if (mounted) setState(() => _sending = false); }
    await _fetchNew();
  }

  // ── Контекстное меню (Telegram-стиль) ─────────────────────

  void _showMessageMenu(BuildContext context, ChatMsg msg, Offset tapPosition) {
    final canDelete = msg.isOwn || _isAdmin;
    final RenderBox overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final screenH = overlay.size.height;
    final showBelow = tapPosition.dy < screenH * 0.6;

    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 180),
      transitionBuilder: (ctx, anim, _, child) => FadeTransition(
        opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut),
        child: ScaleTransition(
          scale: CurvedAnimation(parent: anim, curve: Curves.easeOutBack),
          alignment: showBelow ? Alignment.topCenter : Alignment.bottomCenter,
          child: child,
        ),
      ),
      pageBuilder: (ctx, _, __) {
        return Align(
          alignment: showBelow ? Alignment.topCenter : Alignment.bottomCenter,
          child: Padding(
            padding: EdgeInsets.only(
              top: showBelow ? tapPosition.dy + 8 : 0,
              bottom: showBelow ? 0 : screenH - tapPosition.dy + 8,
              left: 16, right: 16,
            ),
            child: Material(
              color: Colors.transparent,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: msg.isOwn
                    ? CrossAxisAlignment.end
                    : CrossAxisAlignment.start,
                children: [
                  // ── Панель реакций ──────────────────────────
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E1E1E),
                      borderRadius: BorderRadius.circular(28),
                      border: Border.all(color: Colors.white.withOpacity(0.08)),
                      boxShadow: [BoxShadow(color: Colors.black54, blurRadius: 16)],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: kReactions.map((emoji) {
                        final mySet = _myReactions[msg.id] ?? {};
                        final alreadyReacted = mySet.contains(emoji);
                        final count = msg.reactions[emoji] ?? 0;
                        return GestureDetector(
                          onTap: () {
                            Navigator.pop(ctx);
                            _toggleReaction(msg, emoji);
                          },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                            margin: const EdgeInsets.symmetric(horizontal: 2),
                            decoration: BoxDecoration(
                              color: alreadyReacted
                                  ? Colors.cyanAccent.withOpacity(0.18)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Column(mainAxisSize: MainAxisSize.min, children: [
                              Text(emoji, style: const TextStyle(fontSize: 22)),
                              if (count > 0)
                                Text('$count',
                                    style: TextStyle(
                                        color: alreadyReacted
                                            ? Colors.cyanAccent
                                            : Colors.white38,
                                        fontSize: 9)),
                            ]),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                  const SizedBox(height: 6),
                  // ── Пункты меню ─────────────────────────────
                  Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E1E1E),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Colors.white.withOpacity(0.08)),
                      boxShadow: [BoxShadow(color: Colors.black54, blurRadius: 16)],
                    ),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      if (!_iAmBlocked)
                        _menuItem(ctx, Icons.reply_rounded, 'Ответить',
                            Colors.cyanAccent, () {
                          setState(() => _replyTo = msg);
                        }),
                      _menuItem(ctx, Icons.copy_rounded, 'Копировать',
                          Colors.white70, () {
                        Clipboard.setData(ClipboardData(text: msg.text));
                        _toast('Скопировано');
                      }),
                      if (canDelete) ...[
                        Divider(color: Colors.white.withOpacity(0.07), height: 1),
                        _menuItem(ctx, Icons.delete_outline_rounded, 'Удалить',
                            Colors.redAccent, () async {
                          final ok = await showDialog<bool>(
                            context: context,
                            builder: (d) => AlertDialog(
                              backgroundColor: const Color(0xFF1A1A1A),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  side: BorderSide(color: Colors.redAccent.withOpacity(0.5))),
                              title: const Text('Удалить сообщение?',
                                  style: TextStyle(color: Colors.white, fontSize: 15)),
                              actions: [
                                TextButton(onPressed: () => Navigator.pop(d, false),
                                    child: const Text('Отмена',
                                        style: TextStyle(color: Colors.white54))),
                                TextButton(onPressed: () => Navigator.pop(d, true),
                                    child: const Text('Удалить',
                                        style: TextStyle(
                                            color: Colors.redAccent,
                                            fontWeight: FontWeight.bold))),
                              ],
                            ),
                          );
                          if (ok == true) _deleteSingle(msg.id);
                        }),
                      ],
                      if (_isAdmin && !msg.isOwn) ...[
                        Divider(color: Colors.white.withOpacity(0.07), height: 1),
                        _menuItem(
                          ctx,
                          _isBlocked(msg.fullSender) ? Icons.lock_open : Icons.block,
                          _isBlocked(msg.fullSender) ? 'Разблокировать' : 'Заблокировать',
                          _isBlocked(msg.fullSender)
                              ? Colors.greenAccent
                              : Colors.orangeAccent,
                          () => _confirmBlock(msg),
                        ),
                      ],
                    ]),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _menuItem(BuildContext ctx, IconData icon, String label,
      Color color, VoidCallback action) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () { Navigator.pop(ctx); action(); },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 12),
          Text(label, style: TextStyle(color: color, fontSize: 15)),
        ]),
      ),
    );
  }

  // ── Реакции ──────────────────────────────────────────────

  Future<void> _toggleReaction(ChatMsg msg, String emoji) async {
    final addr = widget.walletAddress.toLowerCase();
    final mySet = Set<String>.from(_myReactions[msg.id] ?? {});
    final adding = !mySet.contains(emoji);

    setState(() {
      if (adding) {
        mySet.add(emoji);
      } else {
        mySet.remove(emoji);
      }
      _myReactions[msg.id] = mySet;
      final updated = Map<String, int>.from(msg.reactions);
      if (adding) {
        updated[emoji] = (updated[emoji] ?? 0) + 1;
      } else {
        final cur = (updated[emoji] ?? 1) - 1;
        if (cur <= 0) updated.remove(emoji); else updated[emoji] = cur;
      }
      _msgMap[msg.id] = ChatMsg(
        id: msg.id, sender: msg.sender, fullSender: msg.fullSender,
        text: msg.text, time: msg.time, isOwn: msg.isOwn, rating: msg.rating,
        replyToId: msg.replyToId, replyToText: msg.replyToText,
        replyToSender: msg.replyToSender, reactions: updated,
      );
    });

    try {
      if (adding) {
        await http.post(
          Uri.parse("$_supabaseUrl/rest/v1/chat_reactions"),
          headers: {..._h, "Prefer": "resolution=merge-duplicates,return=minimal"},
          body: jsonEncode({"msg_id": msg.id, "addr": addr, "emoji": emoji}),
        ).timeout(const Duration(seconds: 5));
      } else {
        await http.delete(
          Uri.parse("$_supabaseUrl/rest/v1/chat_reactions"
              "?msg_id=eq.${msg.id}"
              "&addr=eq.${Uri.encodeComponent(addr)}"
              "&emoji=eq.${Uri.encodeComponent(emoji)}"),
          headers: {..._h, "Prefer": "return=minimal"},
        ).timeout(const Duration(seconds: 5));
      }
    } catch (_) {}
  }

  Future<void> _loadReactions(List<int> msgIds) async {
    if (msgIds.isEmpty) return;
    try {
      final ids = msgIds.join(',');
      final resp = await http.get(
        Uri.parse("$_supabaseUrl/rest/v1/chat_reactions"
            "?msg_id=in.($ids)&select=msg_id,addr,emoji"),
        headers: _h,
      ).timeout(const Duration(seconds: 6));
      if (resp.statusCode != 200) return;
      final List data = jsonDecode(resp.body);
      final myAddr = widget.walletAddress.toLowerCase();
      final Map<int, Map<String, int>> reactionMap = {};
      final Map<int, Set<String>> myMap = {};
      for (final r in data) {
        final mid = r['msg_id'] as int;
        final emoji = r['emoji'] as String;
        final addr = (r['addr'] as String).toLowerCase();
        reactionMap.putIfAbsent(mid, () => {})[emoji] =
            (reactionMap[mid]![emoji] ?? 0) + 1;
        if (addr == myAddr) myMap.putIfAbsent(mid, () => {}).add(emoji);
      }
      if (!mounted) return;
      setState(() {
        _myReactions.addAll(myMap);
        for (final mid in reactionMap.keys) {
          final msg = _msgMap[mid];
          if (msg == null) continue;
          _msgMap[mid] = ChatMsg(
            id: msg.id, sender: msg.sender, fullSender: msg.fullSender,
            text: msg.text, time: msg.time, isOwn: msg.isOwn, rating: msg.rating,
            replyToId: msg.replyToId, replyToText: msg.replyToText,
            replyToSender: msg.replyToSender, reactions: reactionMap[mid]!,
          );
        }
      });
    } catch (_) {}
  }

  // ── Удаление одного сообщения ─────────────────────────────

  Future<void> _deleteSingle(int id) async {
    setState(() => _msgMap.remove(id));
    _pollTimer?.cancel();
    try {
      await http.delete(
          Uri.parse("$_supabaseUrl/rest/v1/messages?id=eq.$id"),
          headers: {..._h, "Prefer": "return=minimal"}).timeout(const Duration(seconds: 8));
    } catch (_) {}
    await Future.delayed(const Duration(milliseconds: 300));
    _pollTimer = Timer.periodic(const Duration(seconds: 4), (_) => _fetchNew());
  }

  // ── Удаление ────────────────────────────────────────────


  Future<void> _loadBlocked() async {
    try {
      final resp = await http.get(
          Uri.parse("$_supabaseUrl/rest/v1/blocked_wallets?select=addr"), headers: _h)
          .timeout(const Duration(seconds: 6));
      if (resp.statusCode == 200) {
        final List data = jsonDecode(resp.body);
        if (mounted) {
          setState(() {
            _blockedAddrs.clear();
            for (final r in data) { _blockedAddrs.add((r['addr'] as String).toLowerCase()); }
          });
        }
      }
    } catch (_) {}
    Future.delayed(const Duration(seconds: 30), () { if (mounted) _loadBlocked(); });
  }

  Future<void> _blockUser(String addr) async {
    final lower = addr.toLowerCase();
    final ids = _msgMap.values.where((m) => m.fullSender.toLowerCase() == lower)
        .map((m) => m.id).toList();
    setState(() { _blockedAddrs.add(lower); for (final id in ids) { _msgMap.remove(id); } });
    try {
      await http.post(Uri.parse("$_supabaseUrl/rest/v1/blocked_wallets"),
          headers: {..._h, "Prefer": "return=minimal"},
          body: jsonEncode({"addr": lower})).timeout(const Duration(seconds: 6));
    } catch (_) {}
    if (ids.isNotEmpty) {
      try {
        await http.delete(
            Uri.parse("$_supabaseUrl/rest/v1/messages?id=in.(${ids.join(',')})"),
            headers: {..._h, "Prefer": "return=minimal"}).timeout(const Duration(seconds: 8));
      } catch (_) {}
    }
  }

  Future<void> _unblockUser(String addr) async {
    final lower = addr.toLowerCase();
    setState(() => _blockedAddrs.remove(lower));
    try {
      await http.delete(
          Uri.parse("$_supabaseUrl/rest/v1/blocked_wallets?addr=eq.${Uri.encodeComponent(lower)}"),
          headers: {..._h, "Prefer": "return=minimal"}).timeout(const Duration(seconds: 6));
    } catch (_) {}
  }

  void _showBlockedList() {
    showDialog(context: context,
      builder: (ctx) => StatefulBuilder(builder: (c2, setDlg) => AlertDialog(
        backgroundColor: Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: Colors.redAccent.withOpacity(0.4))),
        title: const Text("🚫 Заблокированные",
            style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
        content: _blockedAddrs.isEmpty
            ? Text("Список пуст", style: TextStyle(color: Colors.white54))
            : SizedBox(width: double.maxFinite,
                child: ListView(shrinkWrap: true, children: _blockedAddrs.map((a) =>
                  ListTile(dense: true,
                    title: Text(
                      // Показываем ник если есть, иначе короткий адрес
                      _nicks[a]?.isNotEmpty == true ? "${_nicks[a]} (${_shortOf(a)})" : _shortOf(a),
                      style: TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                    trailing: TextButton(
                      onPressed: () async {
                        await _unblockUser(a); setDlg(() {});
                        _toast("Разблокировано: ${_shortOf(a)}");
                      },
                      child: const Text("Разблокировать",
                          style: TextStyle(color: Colors.greenAccent, fontSize: 12)),
                    ),
                  )
                ).toList())),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx),
            child: Text("Закрыть", style: TextStyle(color: Colors.white54)))],
      )),
    );
  }

  Future<void> _confirmBlock(ChatMsg msg) async {
    final blocked = _isBlocked(msg.fullSender);
    final ok = await showDialog<bool>(context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: (blocked?Colors.greenAccent:Colors.redAccent).withOpacity(0.5))),
        title: Text(blocked ? "Разблокировать?" : "Заблокировать?",
            style: TextStyle(color: blocked?Colors.greenAccent:Colors.redAccent,
                fontSize: 15, fontWeight: FontWeight.bold)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(_displayName(msg.fullSender),
              style: TextStyle(color: Colors.white70, fontSize: 13)),
          Text(_shortOf(msg.fullSender),
              style: TextStyle(color: Colors.white30, fontSize: 10)),
          if (!blocked) ...[SizedBox(height:8),
            const Text("Все сообщения пользователя будут удалены.",
                style: TextStyle(color: Colors.white38, fontSize: 12), textAlign: TextAlign.center)],
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: Text("Отмена", style: TextStyle(color: Colors.white54))),
          TextButton(onPressed: () => Navigator.pop(ctx, true),
              child: Text(blocked?"Разблокировать":"Заблокировать",
                  style: TextStyle(color: blocked?Colors.greenAccent:Colors.redAccent,
                      fontWeight: FontWeight.bold))),
        ],
      ),
    );
    if (ok != true) return;
    if (blocked) {
      await _unblockUser(msg.fullSender);
      _toast("Разблокировано: ${_displayName(msg.fullSender)}");
    } else {
      await _blockUser(msg.fullSender);
      _toast("Заблокировано: ${_displayName(msg.fullSender)}", isError: true);
    }
  }

  // ── Ники ──────────────────────────────────────────────────
  // Загружает ВСЕ ники из таблицы `nicknames`.
  // Схема таблицы: addr (text PK), nick (text), updated_at (timestamptz)
  // Это основной и единственный источник правды для имён пользователей.
  Future<void> _loadNicks() async {
    try {
      final resp = await http.get(
          Uri.parse("$_supabaseUrl/rest/v1/nicknames?select=addr,nick"), headers: _h)
          .timeout(const Duration(seconds: 6));
      if (resp.statusCode == 200) {
        final List data = jsonDecode(resp.body);
        if (mounted) {
          setState(() {
            for (final r in data) {
              final addr = (r['addr'] as String).toLowerCase();
              final nick = r['nick'] as String? ?? '';
              if (nick.isNotEmpty) {
                _nicks[addr] = nick;
              } else {
                _nicks.remove(addr);
              }
            }
          });
        }
      }
    } catch (_) {}
  }

  void _showChangeNickDialog() {
    final ctrl = TextEditingController(
        text: _nicks[widget.walletAddress.toLowerCase()] ?? '');
    showDialog(context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: Colors.cyanAccent.withOpacity(0.4))),
        title: const Text("Изменить ник",
            style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text("Ник виден всем вместо адреса кошелька.",
              style: TextStyle(color: Colors.white54, fontSize: 12)),
          SizedBox(height: 4),
          const Text("Ники на «adm/адм» зарезервированы для администратора.",
              style: TextStyle(color: Colors.white38, fontSize: 11)),
          SizedBox(height: 12),
          TextField(controller: ctrl, maxLength: 20,
            style: TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: "Введите ник...", hintStyle: TextStyle(color: Colors.white38),
              filled: true, fillColor: Color(0xFF252525),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: Colors.cyanAccent.withOpacity(0.3))),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: Colors.cyanAccent.withOpacity(0.3))),
              counterStyle: TextStyle(color: Colors.white38),
            )),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx),
              child: Text("Отмена", style: TextStyle(color: Colors.white54))),
          TextButton(
            onPressed: () async {
              final nick = ctrl.text.trim();
              if (nick.isNotEmpty && _isAdminNick(nick) && !_isAdmin) {
                Navigator.pop(ctx);
                _toast("Этот ник зарезервирован для администратора", isError: true);
                return;
              }
              Navigator.pop(ctx);
              await _saveNick(nick);
            },
            child: const Text("Сохранить",
                style: TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Future<void> _saveNick(String nick) async {
    // Ключ в nicknames — оригинальный адрес (не lower), nick — строка
    final addr = widget.walletAddress;
    final addrLower = addr.toLowerCase();
    try {
      if (nick.isEmpty) {
        // Удаляем ник
        await http.delete(
            Uri.parse("$_supabaseUrl/rest/v1/nicknames?addr=eq.${Uri.encodeComponent(addrLower)}"),
            headers: {..._h, "Prefer": "return=minimal"}).timeout(const Duration(seconds: 6));
        if (mounted) setState(() => _nicks.remove(addrLower));
        _toast("Ник удалён");
      } else {
        // Проверяем уникальность (ник не занят другим адресом)
        final checkResp = await http.get(
          Uri.parse("$_supabaseUrl/rest/v1/nicknames"
              "?nick=eq.${Uri.encodeComponent(nick)}"
              "&addr=neq.${Uri.encodeComponent(addrLower)}"),
          headers: _h).timeout(const Duration(seconds: 5));
        if (checkResp.statusCode == 200) {
          final List existing = jsonDecode(checkResp.body);
          if (existing.isNotEmpty) {
            _toast("Ник '$nick' уже занят, выберите другой", isError: true);
            return;
          }
        }
        // Сохраняем (upsert по addr)
        final resp = await http.post(
            Uri.parse("$_supabaseUrl/rest/v1/nicknames"),
            headers: {..._h, "Prefer": "resolution=merge-duplicates,return=minimal"},
            body: jsonEncode({
              "addr": addrLower,
              "nick": nick,
              "updated_at": DateTime.now().toIso8601String(),
            })).timeout(const Duration(seconds: 6));
        if (resp.statusCode == 409) {
          _toast("Ник '$nick' уже занят, выберите другой", isError: true);
          return;
        }
        if (mounted) setState(() => _nicks[addrLower] = nick);
        _toast("Ник сохранён: $nick");
        // Обновляем кэш всех ников
        _loadNicks();
      }
    } catch (_) { _toast("Ошибка сохранения ника", isError: true); }
  }

  // ── Helpers ─────────────────────────────────────────────

  void _scrollToBottom() {
    if (_scrollCtrl.hasClients) {
      _scrollCtrl.animateTo(_scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }
  }

  // Повторяет скролл каждые 500мс пока не достигнет конца (макс 10 раз)
  void _scrollToBottomWithRetry([int attempt = 0]) {
    if (attempt >= 10) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) {
        Future.delayed(const Duration(milliseconds: 500), () => _scrollToBottomWithRetry(attempt + 1));
        return;
      }
      final max = _scrollCtrl.position.maxScrollExtent;
      final current = _scrollCtrl.offset;
      if (max > 0 && current < max - 50) {
        _scrollCtrl.jumpTo(max);
        // Проверяем ещё раз через 300мс — вдруг список ещё догружается
        Future.delayed(const Duration(milliseconds: 300), () => _scrollToBottomWithRetry(attempt + 1));
      }
    });
  }

  String _formatTime(DateTime t) =>
      "${t.hour.toString().padLeft(2,'0')}:${t.minute.toString().padLeft(2,'0')}";

  // ── UI ──────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final msgs = _msgs;

    return Scaffold(
      backgroundColor: Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: Color(0xFF111111),
        elevation: 0,
        leadingWidth: 40,
        leading: IconButton(
            icon: Icon(Icons.arrow_back_ios, color: Colors.cyanAccent, size: 16),
            //onPressed: () => Navigator.pop(context),
            onPressed: () => widget.onBack != null ? widget.onBack!() : Navigator.pop(context),
            padding: EdgeInsets.zero),
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            const Text("ЧАТ",
                style: TextStyle(color: Colors.cyanAccent, fontSize: 14,
                    fontWeight: FontWeight.bold, letterSpacing: 1.5)),
            Row(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 5, height: 5, margin: EdgeInsets.only(right: 4),
                  decoration: BoxDecoration(shape: BoxShape.circle,
                      color: _connected ? Colors.greenAccent : Colors.redAccent)),
              Flexible(child: Text(
                _iAmBlocked
                    ? "🚫 Заблок. · $_myDisplayName"
                    : "${_connected ? 'В сети' : _statusText} · $_myDisplayName",
                style: TextStyle(
                    color: _iAmBlocked ? Colors.redAccent
                        : _connected ? Colors.greenAccent.withOpacity(0.8) : Colors.redAccent,
                    fontSize: 9),
                overflow: TextOverflow.ellipsis, maxLines: 1,
              )),
            ]),
          ]),
        actions: [
            // Счётчик онлайн
            if (_onlineCount > 0)
              Padding(
                padding: EdgeInsets.only(right: 2),
                child: Center(child: Container(
                  padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.greenAccent.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.greenAccent.withOpacity(0.3)),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Container(width: 5, height: 5,
                        decoration: BoxDecoration(shape: BoxShape.circle,
                            color: Colors.greenAccent)),
                    SizedBox(width: 3),
                    Text("$_onlineCount",
                        style: TextStyle(color: Colors.greenAccent, fontSize: 10,
                            fontWeight: FontWeight.bold)),
                  ]),
                )),
              ),
            // Топ участников
            IconButton(
                icon: Icon(Icons.leaderboard_rounded, color: Colors.amberAccent, size: 20),
                tooltip: "ТОП участников", onPressed: _showTopList,
                padding: EdgeInsets.zero,
                constraints: BoxConstraints(minWidth: 36, minHeight: 36)),
            // Изменить ник
            if (!_iAmBlocked)
              IconButton(
                  icon: Icon(Icons.badge_outlined, color: Colors.cyanAccent, size: 20),
                  tooltip: "Изменить ник", onPressed: _showChangeNickDialog,
                  padding: EdgeInsets.zero,
                  constraints: BoxConstraints(minWidth: 36, minHeight: 36)),
            // Список заблокированных (только для админа)
            if (_isAdmin)
              IconButton(
                  icon: Icon(Icons.block, color: Colors.redAccent, size: 20),
                  tooltip: "Заблокированные", onPressed: _showBlockedList,
                  padding: EdgeInsets.zero,
                  constraints: BoxConstraints(minWidth: 36, minHeight: 36)),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: Colors.cyanAccent.withOpacity(0.2)),
        ),
      ),
      body: Column(children: [
        if (_loadingMore)
          Container(
              padding: EdgeInsets.symmetric(vertical: 5),
              color: Color(0xFF111111),
              child: const Center(child: SizedBox(width: 14, height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.cyanAccent))))),

        Expanded(child: _buildList(msgs)),

        // Preview ответа
        if (_replyTo != null && !_iAmBlocked)
          Container(
            color: Color(0xFF1A1A1A),
            padding: EdgeInsets.fromLTRB(12, 5, 8, 5),
            child: Row(children: [
              Container(width: 3, height: 32, color: Colors.cyanAccent,
                  margin: EdgeInsets.only(right: 8)),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min, children: [
                Row(children: [
                  Text(_displayName(_replyTo!.fullSender),
                      style: TextStyle(color: Colors.cyanAccent, fontSize: 11,
                          fontWeight: FontWeight.bold)),
                  SizedBox(width: 5),
                  Text(_formatRating(_replyTo!.rating),
                      style: TextStyle(color: _ratingColor(_replyTo!.rating), fontSize: 10)),
                ]),
                Text(_replyTo!.text.length > 60
                    ? _replyTo!.text.substring(0,60)+"..." : _replyTo!.text,
                    style: TextStyle(color: Colors.white54, fontSize: 12),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ])),
              IconButton(
                  icon: Icon(Icons.close, color: Colors.white38, size: 16),
                  onPressed: () => setState(() => _replyTo = null),
                  padding: EdgeInsets.zero, constraints: BoxConstraints()),
            ]),
          ),

        Container(height: 1, color: Colors.cyanAccent.withOpacity(0.15)),

        // Поле ввода
        Container(
          color: Color(0xFF111111),
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(children: [
            Expanded(child: Container(
              decoration: BoxDecoration(
                color: Color(0xFF1A1A1A),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: _iAmBlocked
                      ? Colors.redAccent.withOpacity(0.4)
                      : Colors.cyanAccent.withOpacity(0.3),
                  width: 0.8),
              ),
              child: TextField(
                controller: _msgCtrl,
                enabled: !_iAmBlocked,
                style: TextStyle(color: Colors.white, fontSize: 14),
                maxLines: null, maxLength: _maxMsgLength,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _sendMessage(),
                decoration: InputDecoration(
                  hintText: _iAmBlocked ? "🚫 Заблокировано за спам"
                      : _sending ? "Отправка..." : "Написать...",
                  hintStyle: TextStyle(
                      color: _iAmBlocked ? Colors.redAccent.withOpacity(0.7) : Colors.white30,
                      fontSize: 13),
                  contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  border: InputBorder.none, counterText: "",
                ),
              ),
            )),
            SizedBox(width: 6),
            // Кнопка отправки NFT
            if (!_iAmBlocked)
              GestureDetector(
                onTap: () => showModalBottomSheet(
                  context: context,
                  isScrollControlled: true,
                  backgroundColor: Colors.transparent,
                  builder: (_) => NftPickerSheet(
                    walletAddress: widget.walletAddress,
                    onSelected: (nft) {
                      final existing = _msgCtrl.text.trim();
                      _msgCtrl.text = existing.isEmpty
                        ? nft.encode()
                        : '$existing ${nft.encode()}';
                      _sendMessage();
                    },
                  ),
                ),
                child: Container(
                  width: 38, height: 38,
                  margin: const EdgeInsets.only(right: 6),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.cyanAccent.withOpacity(0.1),
                    border: Border.all(color: Colors.cyanAccent.withOpacity(0.3)),
                  ),
                  child: const Icon(Icons.image_outlined, color: Colors.cyanAccent, size: 18),
                ),
              ),
            GestureDetector(
              onTap: _iAmBlocked ? null : _sendMessage,
              child: Container(
                width: 44, height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: (_iAmBlocked || _sending) ? Colors.grey.shade700 : Colors.cyanAccent,
                  boxShadow: (!_iAmBlocked && !_sending)
                      ? [BoxShadow(color: Colors.cyanAccent.withOpacity(0.4), blurRadius: 8)]
                      : null,
                ),
                child: Icon(
                  _iAmBlocked ? Icons.block : Icons.send_rounded,
                  color: (_iAmBlocked || _sending) ? Colors.white30 : Colors.black,
                  size: 20,
                ),
              ),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _buildList(List<ChatMsg> msgs) {
    if (_connecting) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        CircularProgressIndicator(
            valueColor: AlwaysStoppedAnimation<Color>(Colors.cyanAccent), strokeWidth: 2),
        SizedBox(height: 16),
        Text(_statusText, style: TextStyle(color: Colors.white54, fontSize: 13)),
      ]));
    }
    if (!_connected && msgs.isEmpty) {
      return Center(child: Padding(padding: EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.wifi_off_rounded, color: Colors.redAccent.withOpacity(0.6), size: 48),
          SizedBox(height: 16),
          Text(_statusText, textAlign: TextAlign.center,
              style: TextStyle(color: Colors.redAccent, fontSize: 14, fontWeight: FontWeight.bold)),
          if (_lastError.isNotEmpty) ...[
            SizedBox(height: 8),
            Text(_lastError, textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white30, fontSize: 10), maxLines: 3),
          ],
          SizedBox(height: 20),
          TextButton.icon(
              onPressed: () { _pollTimer?.cancel(); _initChat(); },
              icon: Icon(Icons.refresh, color: Colors.cyanAccent, size: 18),
              label: Text("Попробовать снова", style: TextStyle(color: Colors.cyanAccent))),
        ]),
      ));
    }
    if (msgs.isEmpty) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.chat_bubble_outline, color: Colors.cyanAccent.withOpacity(0.3), size: 48),
        SizedBox(height: 12),
        const Text("Пока сообщений нет.\nБудь первым!",
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white38, fontSize: 14, height: 1.5)),
      ]));
    }
    return ListView.builder(
      controller: _scrollCtrl,
      padding: EdgeInsets.symmetric(vertical: 8, horizontal: 10),
      itemCount: msgs.length,
      itemBuilder: (ctx, i) => _buildMessage(msgs[i], i, msgs),
    );
  }

  Widget _buildMessage(ChatMsg msg, int index, List<ChatMsg> msgs) {
    final isOwn = msg.isOwn;
    final rColor = isOwn ? _ratingColor(widget.myScore) : _ratingColor(msg.rating);
    final ratingVal = isOwn ? widget.myScore : msg.rating;
    final senderIsAdmin = _isAdminAddr(msg.fullSender);
    final senderLabel = _displayName(msg.fullSender);
    final medal = _medal(msg.fullSender);
    final showHeader = index == 0 ||
        msgs[index-1].fullSender != msg.fullSender ||
        msg.time.difference(msgs[index-1].time).inMinutes > 5;
    final hasReactions = msg.reactions.isNotEmpty;

    return GestureDetector(
      onLongPress: () {
        final RenderBox box = context.findRenderObject() as RenderBox;
        final pos = box.localToGlobal(Offset(
          isOwn ? box.size.width - 60 : 60,
          box.size.height * 0.45,
        ));
        _showMessageMenu(context, msg, pos);
      },
      onTap: _iAmBlocked ? null : () => setState(() => _replyTo = msg),
      child: Container(
        color: Colors.transparent,
        padding: EdgeInsets.only(
          top: showHeader ? 8 : 2, bottom: 2,
          left: isOwn ? 44 : 0, right: isOwn ? 0 : 44,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisAlignment: isOwn ? MainAxisAlignment.end : MainAxisAlignment.start,
          children: [
            Flexible(child: Column(
              crossAxisAlignment: isOwn ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                if (showHeader)
                  Padding(
                    padding: EdgeInsets.only(
                        left: isOwn ? 0 : 2, right: isOwn ? 2 : 0, bottom: 3),
                    child: Row(mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.center, children: [
                      if (medal.isNotEmpty)
                        Padding(padding: EdgeInsets.only(right: 3),
                            child: Text(medal, style: TextStyle(fontSize: 12))),
                      Text(senderLabel,
                          style: TextStyle(
                              color: senderIsAdmin ? Colors.orangeAccent
                                  : isOwn ? Colors.cyanAccent.withOpacity(0.8) : Colors.white60,
                              fontSize: 11, fontWeight: FontWeight.w600)),
                      _rankDot(ratingVal, senderIsAdmin),
                      Text(_formatRating(ratingVal),
                          style: TextStyle(color: rColor, fontSize: 11, fontWeight: FontWeight.bold)),
                    ]),
                  ),

                // Пузырь сообщения
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 11, vertical: 7),
                  decoration: BoxDecoration(
                    color: isOwn ? Color(0xFF0D3D3D) : Color(0xFF1C1C1C),
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(14),
                      topRight: Radius.circular(14),
                      bottomLeft: Radius.circular(isOwn ? 14 : 3),
                      bottomRight: Radius.circular(isOwn ? 3 : 14),
                    ),
                    border: Border.all(
                        color: isOwn
                            ? Colors.cyanAccent.withOpacity(0.2)
                            : Colors.white.withOpacity(0.06),
                        width: 0.5),
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min, children: [
                    if (msg.replyToText != null)
                      Container(
                        margin: EdgeInsets.only(bottom: 5),
                        padding: EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.05),
                          borderRadius: BorderRadius.circular(6),
                          border: Border(left: BorderSide(
                              color: Colors.cyanAccent.withOpacity(0.5), width: 2)),
                        ),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          if (msg.replyToSender != null)
                            Text(
                              _displayName(msg.replyToSender!),
                              style: TextStyle(color: Colors.cyanAccent,
                                  fontSize: 10, fontWeight: FontWeight.bold),
                            ),
                          Text(msg.replyToText!,
                              style: TextStyle(color: Colors.white54, fontSize: 11),
                              maxLines: 2, overflow: TextOverflow.ellipsis),
                        ]),
                      ),
                    Row(mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.end, children: [
                      /*
                      Flexible(child: NftMessageData.isNftMessage(msg.text)
                        ? NftChatBubble(
                            nft: NftMessageData.decode(msg.text)!,
                            isOwn: isOwn,
                          )
                        : _buildTextWithLinks(msg.text)),
                      */  

                      Flexible(child: NftMessageData.containsNft(msg.text)
                        ? Column(
                            crossAxisAlignment: isOwn ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: NftMessageData.parseMessage(msg.text).map((part) {
                              if (part is NftMessageData) {
                                return Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: NftChatBubble(nft: part, isOwn: isOwn),
                                );
                              }
                              return _buildTextWithLinks(part as String);
                            }).toList(),
                          )
                        : _buildTextWithLinks(msg.text)),

                      SizedBox(width: 6),
                      Text(_formatTime(msg.time),
                          style: TextStyle(color: Colors.white30, fontSize: 9, height: 1)),
                    ]),
                  ]),
                ),

                // Реакции под пузырём
                if (hasReactions)
                  Padding(
                    padding: EdgeInsets.only(
                        top: 3, left: isOwn ? 0 : 4, right: isOwn ? 4 : 0),
                    child: Wrap(
                      spacing: 4, runSpacing: 4,
                      alignment: isOwn ? WrapAlignment.end : WrapAlignment.start,
                      children: msg.reactions.entries.map((e) {
                        final isMine = (_myReactions[msg.id] ?? {}).contains(e.key);
                        return GestureDetector(
                          onTap: () => _toggleReaction(msg, e.key),
                          child: AnimatedContainer(
                            duration: Duration(milliseconds: 150),
                            padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: isMine
                                  ? Colors.cyanAccent.withOpacity(0.18)
                                  : Colors.white.withOpacity(0.07),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                  color: isMine
                                      ? Colors.cyanAccent.withOpacity(0.5)
                                      : Colors.white.withOpacity(0.1)),
                            ),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              Text(e.key, style: TextStyle(fontSize: 13)),
                              SizedBox(width: 3),
                              Text('${e.value}',
                                  style: TextStyle(
                                      color: isMine ? Colors.cyanAccent : Colors.white54,
                                      fontSize: 11, fontWeight: FontWeight.bold)),
                            ]),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
              ],
            )),
          ],
        ),
      ),
    );
  }

  Widget _buildTextWithLinks(String text) {
    final urlRegex = RegExp(r'(https?://[^\s]+)', caseSensitive: false);
    final matches = urlRegex.allMatches(text);
    if (matches.isEmpty) {
      return Text(text, style: TextStyle(color: Colors.white, fontSize: 13.5, height: 1.35));
    }
    final spans = <InlineSpan>[];
    int last = 0;
    for (final m in matches) {
      if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start)));
      final url = m.group(0)!;
      spans.add(TextSpan(
        text: url,
        style: TextStyle(color: Colors.lightBlueAccent,
            decoration: TextDecoration.underline, decorationColor: Colors.lightBlueAccent),
        recognizer: TapGestureRecognizer()
          ..onTap = () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
      ));
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return RichText(
      text: TextSpan(
          style: TextStyle(color: Colors.white, fontSize: 13.5, height: 1.35),
          children: spans),
    );
  }
}

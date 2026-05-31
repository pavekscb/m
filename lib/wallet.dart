import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:convert/convert.dart' as convert;
import 'package:pointycastle/export.dart' as pc;
import 'main.dart';
import 'token_manager.dart';
import 'token_settings.dart';
import 'withdraw.dart';
import 'deposit.dart';
import 'swap.dart';
import 'staking.dart';
import 'airdrop.dart';
import 'about.dart';
import 'chat.dart';
import 'send_page.dart';
import 'update.dart';
import 'price_service.dart';
import 'package:shared_preferences/shared_preferences.dart';


// ── Страница кошелька ─────────────────────────────────────────
import 'account_manager.dart';
import 'qr_scanner.dart';

class WalletPage extends StatefulWidget {
  final String? privateKeyHex;
  final VoidCallback onChangeKey;
  final VoidCallback onCreateWallet;
  final VoidCallback onShowPrivateKey;
  final VoidCallback onRequestKeyInput;
  final Function(WalletAccount)? onAccountSwitch;
  final String accountName;

  const WalletPage({
    super.key,
    required this.privateKeyHex,
    required this.onChangeKey,
    required this.onCreateWallet,
    required this.onShowPrivateKey,
    required this.onRequestKeyInput,
    this.onAccountSwitch,
    this.accountName = '',
  });

  @override
  State<WalletPage> createState() => _WalletPageState();
}

class _WalletPageState extends State<WalletPage> {
  String? _address;
  String? _aptBalance;
  List<TokenBalance> _allTokens = [];
  List<TokenBalance> _tokens = [];
  String? _error;
  bool _loading = true;
  String _accountName = ''; // имя активного кошелька

  // ── Ed25519 математика ────────────────────────────────────────
  static final BigInt _q = (BigInt.from(2).pow(255)) - BigInt.from(19);
  static final BigInt _d = (BigInt.parse('-121665') *
      BigInt.parse('121666').modInverse(_q)) % _q;
  static final BigInt _I = BigInt.from(2).modPow(
      (_q - BigInt.one) ~/ BigInt.from(4), _q);

  static List<BigInt> _recoverX(BigInt y) {
    final y2 = y * y % _q;
    final x2 = ((y2 - BigInt.one) *
        (_d * y2 + BigInt.one).modInverse(_q)) % _q;
    if (x2 == BigInt.zero) return [BigInt.zero, BigInt.zero];
    BigInt x = x2.modPow((_q + BigInt.from(3)) ~/ BigInt.from(8), _q);
    if ((x * x - x2) % _q != BigInt.zero) x = x * _I % _q;
    if (x.isOdd) x = _q - x;
    return [x, y];
  }

  static List<BigInt> _basePoint() {
    final y = BigInt.from(4) * BigInt.from(5).modInverse(_q) % _q;
    final x = _recoverX(y)[0];
    return [x, y, BigInt.one, x * y % _q];
  }

  static List<BigInt> _edAdd(List<BigInt> P, List<BigInt> Q) {
    final a = (P[1] - P[0]) * (Q[1] - Q[0]) % _q;
    final b = (P[1] + P[0]) * (Q[1] + Q[0]) % _q;
    final c = BigInt.from(2) * P[3] * Q[3] % _q * _d % _q;
    final dd = BigInt.from(2) * P[2] * Q[2] % _q;
    final e = b - a;
    final f = dd - c;
    final g = dd + c;
    final h = b + a;
    return [e * f % _q, g * h % _q, f * g % _q, e * h % _q];
  }

  static List<BigInt> _scalarMult(List<BigInt> P, BigInt n) {
    if (n == BigInt.zero) {
      return [BigInt.zero, BigInt.one, BigInt.one, BigInt.zero];
    }
    var Q = _scalarMult(P, n ~/ BigInt.two);
    Q = _edAdd(Q, Q);
    if (n.isOdd) Q = _edAdd(Q, P);
    return Q;
  }

  static Uint8List _encodePoint(List<BigInt> P) {
    final zinv = P[2].modInverse(_q);
    final x = P[0] * zinv % _q;
    final y = P[1] * zinv % _q;
    final out = Uint8List(32);
    BigInt v = y;
    for (int i = 0; i < 32; i++) {
      out[i] = (v & BigInt.from(0xFF)).toInt();
      v = v >> 8;
    }
    if (x.isOdd) out[31] |= 0x80;
    return out;
  }

  Uint8List _getPublicKey(Uint8List seed32) {
    final sha512 = pc.SHA512Digest();
    final h = Uint8List(64);
    sha512.update(seed32, 0, 32);
    sha512.doFinal(h, 0);
    h[0] &= 248;
    h[31] &= 127;
    h[31] |= 64;
    BigInt a = BigInt.zero;
    for (int i = 0; i < 32; i++) {
      a += BigInt.from(h[i]) << (8 * i);
    }
    final B = _basePoint();
    final A = _scalarMult(B, a);
    return _encodePoint(A);
  }

  String _pubKeyToAddress(Uint8List pubKey32) {
    final input = Uint8List(33);
    input.setRange(0, 32, pubKey32);
    input[32] = 0x00;
    final sha3 = pc.SHA3Digest(256);
    sha3.update(input, 0, 33);
    final output = Uint8List(32);
    sha3.doFinal(output, 0);
    return '0x${convert.hex.encode(output)}';
  }

  Future<String> _fetchAptBalance(String address) async {
    final url = Uri.parse(
      'https://fullnode.mainnet.aptoslabs.com/v1/accounts/$address/balance/0x1::aptos_coin::AptosCoin',
    );
    final response = await http
        .get(url, headers: {'Accept': 'application/json'})
        .timeout(const Duration(seconds: 15));
    if (response.statusCode == 404) return '0.00000000 APT';
    if (response.statusCode != 200) {
      throw Exception('Ошибка сети: HTTP ${response.statusCode}');
    }
    final raw = int.parse(response.body.trim().replaceAll('"', ''));
    final apt = raw / 100000000;
    return '${apt.toStringAsFixed(8)} APT';
  }

  Future<List<TokenBalance>> _fetchAllTokens(String address) async {
    const url = 'https://api.mainnet.aptoslabs.com/v1/graphql';
    final query = '''
    {
      current_fungible_asset_balances(
        where: {
          owner_address: {_eq: "$address"},
          amount: {_gt: "0"}
        }
      ) {
        asset_type
        amount
        metadata {
          name
          symbol
          decimals
        }
      }
    }
    ''';
    final response = await http.post(
      Uri.parse(url),
      headers: {'Content-Type': 'application/json',
        'Accept': 'application/json'},
      body: jsonEncode({'query': query}),
    ).timeout(const Duration(seconds: 15));

    if (response.statusCode != 200) {
      throw Exception('Indexer ошибка: HTTP ${response.statusCode}');
    }

    final data = jsonDecode(response.body);
    final List<dynamic> balances =
        data['data']['current_fungible_asset_balances'] ?? [];

    final List<TokenBalance> tokens = [];
    for (final item in balances) {
      final meta = item['metadata'];
      if (meta == null) continue;
      final decimals = (meta['decimals'] as num?)?.toInt() ?? 8;
      final rawAmount = double.tryParse(item['amount'].toString()) ?? 0;
      final amount = rawAmount / _pow10(decimals);
      if (amount <= 0) continue;
      tokens.add(TokenBalance(
        name: meta['name'] ?? 'Unknown',
        symbol: meta['symbol'] ?? '???',
        amount: amount,
        decimals: decimals,
        assetType: item['asset_type'] ?? '',
      ));
    }

    // Закреплённые токены — показываем всегда, даже с нулевым балансом
    const List<Map<String,dynamic>> pinned = [
      {'assetType': '0xe9c192ff55cffab3963c695cff6dbf9dad6aff2bb5ac19a6415cad26a81860d9::mee_coin::MeeCoin',
       'name': 'MEE Coin', 'symbol': 'MEE', 'decimals': 6},
      {'assetType': '0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3::mega_coin::MEGA',
       'name': 'MEGA', 'symbol': 'MEGA', 'decimals': 8},
      {'assetType': '0x357b0b74bc833e95a115ad22604854d6b0fca151cecd94111770e5d6ffc9dc2b',
       'name': 'Tether USD', 'symbol': 'USDT', 'decimals': 6},
      {'assetType': '0xbae207659db88bea0cbead6da0ed00aac12edcdda169e591cd41c94180b46f3b',
       'name': 'USD Coin', 'symbol': 'USDC', 'decimals': 6},
    ];
    for (final p in pinned) {
      final exists = tokens.any((t) => t.assetType == p['assetType']);
      if (!exists) {
        tokens.add(TokenBalance(
          name: p['name']!, symbol: p['symbol']!,
          amount: 0, decimals: p['decimals']!, assetType: p['assetType']!,
        ));
      }
    }
    tokens.sort((a, b) {
      if (a.symbol == 'APT') return -1;
      if (b.symbol == 'APT') return 1;
      return b.amount.compareTo(a.amount);
    });
    return tokens;
  }

  double _pow10(int exp) {
    double result = 1.0;
    for (int i = 0; i < exp; i++) result *= 10;
    return result;
  }

  String _shortAddress(String address) {
    if (address.length <= 12) return address;
    return '${address.substring(0, 6)}...${address.substring(address.length - 6)}';
  }

  bool get _hasWallet => widget.privateKeyHex != null && widget.privateKeyHex!.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _accountName = widget.accountName;
    if (_hasWallet) {
      _loadWallet();
    } else {
      _setDefaultState();
    }
  }

  @override
  void didUpdateWidget(covariant WalletPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Обновляем имя если изменилось снаружи
    if (widget.accountName != oldWidget.accountName) {
      setState(() => _accountName = widget.accountName);
    }
    if (widget.privateKeyHex != oldWidget.privateKeyHex) {
      if (_hasWallet) {
        _loadWallet();
      } else {
        _setDefaultState();
      }
    }
  }

  void _setDefaultState() {
    final defaultTokens = _buildDefaultTokens();
    setState(() {
      _address = null;
      _aptBalance = '0.00000000 APT';
      _allTokens = defaultTokens;
      _tokens = defaultTokens;
      _loading = false;
      _error = null;
    });
  }

  Future<void> _loadWallet() async {
    if (!_hasWallet) return;
    setState(() { _loading = true; _error = null; });
    try {
      final privBytes = Uint8List.fromList(
          convert.hex.decode(widget.privateKeyHex!));
      final pubBytes = _getPublicKey(privBytes);
      final address = _pubKeyToAddress(pubBytes);
      setState(() => _address = address);

      final results = await Future.wait([
        _fetchAptBalance(address),
        _fetchAllTokens(address),
      ]);

      final allTokens = results[1] as List<TokenBalance>;
      
      // Инициализируем настройки для новых токенов
      await TokenManager.initializeNewTokens(allTokens);
      
      // Применяем сохраненные настройки (фильтр и сортировка)
      final visibleTokens = await TokenManager.applySettings(allTokens);

      setState(() {
        _aptBalance = results[0] as String;
        _allTokens = allTokens;
        _tokens = visibleTokens;
        _loading = false;
      });

     
      Map<String, double> _prices = {};

      
      PriceService.instance.fetchPrices().then((p) {
        if (mounted) setState(() => _prices = p);
      });


    } catch (e) {
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  Future<void> _reloadTokenSettings() async {
    try {
      if (_allTokens.isEmpty && _address != null) {
        _allTokens = await _fetchAllTokens(_address!);
      }
      final filtered = await TokenManager.applySettings(_allTokens);
      setState(() => _tokens = filtered);
    } catch (e) {
      // Handle error silently
    }
  }

  List<TokenBalance> _buildDefaultTokens() {
    return [
      TokenBalance(
        name: 'Aptos',
        symbol: 'APT',
        amount: 0,
        decimals: 8,
        assetType: '0x1::aptos_coin::AptosCoin',
      ),
      TokenBalance(
        name: 'Mee Token',
        symbol: 'MEE',
        amount: 0,
        decimals: 8,
        assetType: '0x1::mee::MEE',
      ),
      TokenBalance(
        name: 'Mega Token',
        symbol: 'MEGA',
        amount: 0,
        decimals: 8,
        assetType: '0x1::mega::MEGA',
      ),
      TokenBalance(
        name: 'Tether USD',
        symbol: 'USDT',
        amount: 0,
        decimals: 6,
        assetType: '0x1::usdt::USDT',
      ),
    ];
  }

  String _formatAmount(double amount, int decimals) {
    if (amount >= 1000000) return '${(amount / 1000000).toStringAsFixed(2)}M';
    if (amount >= 1000) return '${(amount / 1000).toStringAsFixed(2)}K';
    if (decimals <= 2) return amount.toStringAsFixed(2);
    return amount.toStringAsFixed(decimals > 6 ? 6 : decimals);
  }

  // Меню настроек
  Future<void> _showSettingsMenu() async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF131929),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      isScrollControlled: true, // Позволяет BottomSheet занимать больше места
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(24),
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(ctx).size.height * 0.8, // Максимум 80% экрана
        ),
        child: SingleChildScrollView( // Добавляем прокрутку
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Настройки кошелька',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 24),
              _SettingsButton(
                icon: Icons.key,
                title: 'Ввести приватный ключ',
                subtitle: 'Ввести новый ключ или заменить существующий',
                onTap: () {
                  Navigator.pop(ctx);
                  widget.onRequestKeyInput();
                },
              ),
              const SizedBox(height: 16),
              _SettingsButton(
                icon: Icons.add_circle_outline,
                title: 'Создать новый кошелек',
                subtitle: 'Сгенерировать новый ключ',
                onTap: () {
                  Navigator.pop(ctx);
                  widget.onCreateWallet();
                },
              ),
              const SizedBox(height: 16),
              if (_hasWallet)
                const SizedBox(height: 16),
              if (_hasWallet)
                _SettingsButton(
                  icon: Icons.visibility,
                  title: 'Показать приватный ключ',
                  subtitle: 'Просмотреть и скопировать ключ',
                  onTap: () {
                    Navigator.pop(ctx);
                    widget.onShowPrivateKey();
                  },
                ),

              // ── НАЧАЛО ВСТАВКИ: НОВЫЙ ПУНКТ «О ПРИЛОЖЕНИИ» ──
              const SizedBox(height: 16),
              _SettingsButton(
                icon: Icons.info_outline,
                title: 'О приложении',
                subtitle: 'Проверить обновления и информация',
                onTap: () {
                  Navigator.pop(ctx); // Закрываем шторку настроек
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const UpdatePage()),
                  );
                },
              ),
              const SizedBox(height: 16),
              const Text(
                'Версия: v1.1.3',
                style: TextStyle(
                  color: Colors.white24,
                  fontSize: 12,
                  fontFamily: 'monospace',
                ),
              ),
              // ── КОНЕЦ ВСТАВКИ ──


              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text(
                    'Закрыть',
                    style: TextStyle(color: Colors.white38, fontSize: 16),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStickyHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 14),
      decoration: BoxDecoration(
        color: const Color(0xFF0A0E1A),
        border: Border(
          bottom: BorderSide(color: Colors.white.withOpacity(0.08), width: 0.5),
        ),
      ),
      child: Row(
        children: [
          // QR сканер вместо иконки кошелька
          GestureDetector(
            onTap: () async {
              final result = await Navigator.push<String>(
                context,
                MaterialPageRoute(builder: (_) => const QrScannerPage()),
              );
              if (result != null && result.isNotEmpty && mounted) {
                // Показываем результат — адрес из QR
                showDialog(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    backgroundColor: const Color(0xFF131929),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                    title: const Text('Адрес из QR',
                        style: TextStyle(color: Colors.white, fontSize: 16)),
                    content: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SelectableText(result,
                            style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                                fontFamily: 'monospace')),
                        const SizedBox(height: 12),
                        const Text('Адрес скопирован в буфер',
                            style: TextStyle(
                                color: Colors.white38, fontSize: 12)),
                      ],
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Закрыть',
                            style: TextStyle(color: Colors.white38)),
                      ),
                      TextButton(
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: result));
                          Navigator.pop(ctx);
                        },
                        child: const Text('Копировать',
                            style: TextStyle(color: Color(0xFF00D4AA))),
                      ),
                    ],
                  ),
                );
              }
            },
            child: Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                color: const Color(0xFF00D4AA).withOpacity(0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: const Color(0xFF00D4AA).withOpacity(0.3)),
              ),
              child: const Icon(Icons.qr_code_scanner,
                  color: Color(0xFF00D4AA), size: 22),
            ),
          ),
          const SizedBox(width: 14),
          // Название + адрес — тапаются для switcher
          Expanded(
            child: GestureDetector(
              onTap: _address != null
                  ? () => showAccountSwitcher(
                        context: context,
                        activeAddress: _address!,
                        onSwitch: (account) {
                          widget.onAccountSwitch?.call(account);
                          setState(() => _accountName = account.name);
                        },
                      )
                  : null,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_accountName.isNotEmpty)
                    Text(
                      _accountName,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.white38,
                        fontWeight: FontWeight.w500,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  _address != null
                      ? Text(
                          _shortAddress(_address!),
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: Colors.white,
                            fontFamily: 'monospace',
                          ),
                          overflow: TextOverflow.ellipsis,
                        )
                      : const Text(
                          'Кошелёк',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                ],
              ),
            ),
          ),
          if (_address != null)
            IconButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _address!));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Адрес скопирован'),
                    duration: Duration(seconds: 2),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              },
              icon: const Icon(Icons.copy, color: Colors.white38, size: 18),
            ),
          IconButton(
            onPressed: _showSettingsMenu,
            icon: const Icon(Icons.settings_outlined,
                color: Colors.white38, size: 20),
            tooltip: 'Настройки',
          ),
        ],
      ),
    );
  }

  List<Widget> _buildBodyContent() {
    return [
      const SizedBox(height: 16),
      if (!_hasWallet) ...[
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1F2E),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withOpacity(0.08)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              Text('Кошелёк не подключён',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  )),
              SizedBox(height: 10),
              Text(
                'Введите приватный ключ через настройки, или создайте новый кошелёк. До этого адрес не определён, баланс и токены будут равны нулю.',
                style: TextStyle(color: Colors.white54, fontSize: 13, height: 1.5),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _showSettingsMenu,
            icon: const Icon(Icons.settings_outlined),
            label: const Text('Настроить кошелёк'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              backgroundColor: const Color(0xFF00D4AA),
            ),
          ),
        ),
        const SizedBox(height: 24),
      ],

      if (_loading && _aptBalance == null)
        const Center(
          child: Padding(
            padding: EdgeInsets.all(32),
            child: Column(
              children: [
                CircularProgressIndicator(color: Color(0xFF00D4AA)),
                SizedBox(height: 16),
                Text('Загружаем балансы...',
                    style: TextStyle(color: Colors.white38, fontSize: 13)),
              ],
            ),
          ),
        ),

      if (_aptBalance != null) ...[
        _InfoCard(
          label: 'БАЛАНС APT',
          value: _aptBalance!,
          icon: Icons.toll_outlined,
          accent: const Color(0xFF00D4AA),
        ),
        const SizedBox(height: 20),
      ],

      if (_hasWallet)
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [

            _ActionButton(
              icon: Icons.arrow_upward,
              label: 'Вывести',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => SendPage(
                    privateKeyHex: widget.privateKeyHex ?? '',
                    tokens: _tokens, // <- Передаем только отфильтрованные токены (фавориты)
                  ),
                ),
              ),
            ), 

           // _ActionButton(
           //   icon: Icons.arrow_upward,
           //   label: 'Вывести',
           //   onTap: () => Navigator.push(context,
           //       MaterialPageRoute(builder: (_) => const WithdrawPage())),
           // ),



            _ActionButton(
              icon: Icons.arrow_downward,
              label: 'Пополнить',
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => DepositPage(privateKeyHex: widget.privateKeyHex ?? ''))),
            ),

            _ActionButton(
              icon: Icons.swap_vert,
              label: 'Своп',
              onTap: () {
                // 1. Проверяем, есть ли у нас приватный ключ в виджете
                if (widget.privateKeyHex == null || widget.privateKeyHex!.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text("Ошибка: Кошелёк не подключён или приватный ключ отсутствует"), 
                      backgroundColor: Colors.redAccent
                    ),
                  );
                  return;
                }

                // 2. Вытаскиваем актуальные балансы токенов из твоего списка _tokens
                double aptAmt = 0.0;
                double meeAmt = 0.0;
                double megaAmt = 0.0;
                double usdtAmt = 0.0;
                double usdcAmt = 0.0;

                for (var t in _tokens) {
                  if (t.symbol.toUpperCase() == 'APT') aptAmt = t.amount;
                  if (t.symbol.toUpperCase() == 'MEE') meeAmt = t.amount;
                  if (t.symbol.toUpperCase() == 'MEGA') megaAmt = t.amount;
                  if (t.symbol.toUpperCase() == 'USDT') usdtAmt = t.amount;
                  if (t.symbol.toUpperCase() == 'USDC') usdcAmt = t.amount;
                }
                
                // 3. Открываем страницу свопа, передавая уже имеющийся widget.privateKeyHex
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => SwapPage(
                      currentAddress: _address ?? '', // Твоя переменная адреса из _WalletPageState
                      privateKeyHex: widget.privateKeyHex!,          
                      aptBalance: aptAmt,       
                      meeBalance: meeAmt,       
                      megaBalance: megaAmt, 
                      usdtBalance: usdtAmt,
                      usdcBalance: usdcAmt,    
                      onSwapSuccess: () {
                        // Автоматически обновляем балансы в кошельке после успешного обмена
                        _loadWallet();
                      },
                    ),
                  ),
                );
              },
            ),


            /*
            _ActionButton(
              icon: Icons.swap_vert,
              label: 'Своп',
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const SwapPage())),
            ),
            */

            _ActionButton(
              icon: Icons.trending_up,
              label: 'Стейк',
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => StakingPage(address: _address, privateKeyHex: widget.privateKeyHex ?? ''))),
            ),
          ],
        ),
      if (_hasWallet) const SizedBox(height: 24),

      if (_tokens.isNotEmpty) ...[
        Row(
          children: [
            const Text('ВСЕ ТОКЕНЫ',
                style: TextStyle(fontSize: 11,
                    color: Colors.white38, letterSpacing: 1.2)),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF00D4AA).withOpacity(0.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text('${_tokens.length}',
                  style: const TextStyle(fontSize: 10,
                      color: Color(0xFF00D4AA))),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          decoration: BoxDecoration(
            color: const Color(0xFF131929),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withOpacity(0.06)),
          ),
          child: Column(
            children: _tokens.asMap().entries.map((entry) {
              final i = entry.key;
              final token = entry.value;
              return _TokenRow(
                token: token,
                isLast: i == _tokens.length - 1,
                formatAmount: _formatAmount,
              );
            }).toList(),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () async {
              await showDialog(
                context: context,
                builder: (ctx) => TokenSettingsDialog(
                  tokens: _allTokens,
                  onSettingsChanged: _reloadTokenSettings,
                ),
              );
              await _reloadTokenSettings();
            },
            icon: const Icon(Icons.tune, color: Colors.white54, size: 16),
            label: const Text('Управление токенами',
                style: TextStyle(color: Colors.white54, fontSize: 13)),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 12),
              side: BorderSide(color: Colors.white.withOpacity(0.1)),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
      ],

      if (_error != null) ...[
        const SizedBox(height: 16),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.redAccent.withOpacity(0.07),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.redAccent.withOpacity(0.25)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.error_outline, color: Colors.redAccent, size: 16),
              const SizedBox(width: 10),
              Expanded(child: Text(_error!,
                  style: const TextStyle(
                      color: Colors.redAccent, fontSize: 13, height: 1.5))),
            ],
          ),
        ),
      ],

      const SizedBox(height: 32),
      if (!_loading && _aptBalance != null)
        const Center(
          child: Text('↓ потяните вниз для обновления',
              style: TextStyle(color: Colors.white24, fontSize: 11)),
        ),
      const SizedBox(height: 24),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return _MainShell(
      privateKeyHex: widget.privateKeyHex,
      address: _address,
      child: Scaffold(
        body: SafeArea(
          child: RefreshIndicator(
            color: const Color(0xFF00D4AA),
            backgroundColor: const Color(0xFF131929),
            onRefresh: _loadWallet,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverPersistentHeader(
                  pinned: true,
                  delegate: _WalletHeaderDelegate(child: _buildStickyHeader()),
                ),
                SliverList(
                  delegate: SliverChildListDelegate(_buildBodyContent()),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _WalletHeaderDelegate extends SliverPersistentHeaderDelegate {
  final Widget child;

  _WalletHeaderDelegate({required this.child});

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return child;
  }

  @override
  double get maxExtent => 82;

  @override
  double get minExtent => 82;

  @override
  bool shouldRebuild(covariant _WalletHeaderDelegate oldDelegate) {
    return oldDelegate.child != child;
  }
}

// ── Строка токена ─────────────────────────────────────────────
class _TokenRow extends StatelessWidget {
  final TokenBalance token;
  final bool isLast;
  final String Function(double, int) formatAmount;
  final Map<String, double> prices;

  const _TokenRow({
    required this.token,
    required this.isLast,
    required this.formatAmount,
    this.prices = const {},
  });

  

  Color _tokenColor() {
    switch (token.symbol.toUpperCase()) {
      case 'APT': return const Color(0xFF00D4AA);
      case 'MEE': return const Color(0xFF6C63FF);
      case 'MEGA': return const Color(0xFFFF6B6B);
      case 'USDT':
      case 'USDC':
      case 'USD1': return const Color(0xFF26A17B);
      default: return const Color(0xFF8899AA);
    }
  }

  // Маппинг контракт → иконка (по assetType)
  static const Map<String, String> _assetIcons = {
    // APT
    '0x1::aptos_coin::AptosCoin':
        'assets/apt.png',
    // MEE
    '0xe9c192ff55cffab3963c695cff6dbf9dad6aff2bb5ac19a6415cad26a81860d9::mee_coin::MeeCoin':
        'assets/mee.png',
    // MEGA
    '0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3::mega_coin::MEGA':
        'assets/mega.png',
    // USDT — LayerZero (старый coin standard)
    '0xf22bede237a07e121b56d91a491eb7bcdfd1f5907926a9e58338f964a01b17fa::asset::USDT':
        'assets/usdt.png',
    // USDT — нативный Tether FA
    '0x357b0b74bc833e95a115ad22604854d6b0fca151cecd94111770e5d6ffc9dc2b':
        'assets/usdt.png',
    // USDC — Circle
    '0xbae207659db88bea0cbead6da0ed00aac12edcdda169e591cd41c94180b46f3b':
        'assets/usdc.png',
  };

  // Метод для отрисовки иконки из ассетов
  Widget _buildTokenIcon(String symbol) {
    // Ищем по assetType (контракту) — точно и без путаницы
    final assetPath = _assetIcons[token.assetType];

    if (assetPath != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.asset(
          assetPath,
          width: 36,
          height: 36,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) => _buildFallbackIcon(symbol),
        ),
      );
    }
    return _buildFallbackIcon(symbol);
  }

  // Заглушка, если иконки нет в assets
  Widget _buildFallbackIcon(String symbol) {
    final color = _tokenColor();
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Center(
        child: Text(
          symbol.length > 2 ? symbol.substring(0, 2) : symbol,
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final color = _tokenColor();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              // Вывод иконки (картинка или текстовая заглушка)
              _buildTokenIcon(token.symbol),
              
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(token.name,
                        style: const TextStyle(color: Colors.white,
                            fontSize: 14, fontWeight: FontWeight.w500),
                        overflow: TextOverflow.ellipsis),
                    Text(token.symbol,
                        style: TextStyle(
                            color: color.withOpacity(0.7), fontSize: 11)),
                  ],
                ),
              ),
              
              /*
              Text(
                '${formatAmount(token.amount, token.decimals)} ${token.symbol}',
                style: const TextStyle(color: Colors.white, fontSize: 14,
                    fontWeight: FontWeight.w600),
              ),*/
 

              Text(
                '${formatAmount(token.amount, token.decimals)} ${token.symbol}',
                style: const TextStyle(color: Colors.white, fontSize: 14,
                    fontWeight: FontWeight.w600),
              ),
              Builder(builder: (_) {
                final price = prices[token.symbol.toUpperCase()] ?? 0;
                final usd = token.amount * price;
                if (usd == 0) return const SizedBox.shrink();
                return Text(
                  formatUsd(usd),
                  style: const TextStyle(color: Colors.white38, fontSize: 11),
                );
              }),   



            ],
          ),
        ),
        if (!isLast)
          Divider(height: 1, color: Colors.white.withOpacity(0.05),
              indent: 64),
      ],
    );
  }
}

// ── Кнопка настроек ───────────────────────────────────────────
class _SettingsButton extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _SettingsButton({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1F2E),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: Colors.white.withOpacity(0.06),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: const Color(0xFF00D4AA).withOpacity(0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                icon,
                color: const Color(0xFF00D4AA),
                size: 20,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.6),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right,
              color: Colors.white.withOpacity(0.4),
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Карточка результата ───────────────────────────────────────
class _InfoCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color? accent;
  final VoidCallback? onCopy;

  const _InfoCard({required this.label, required this.value,
    required this.icon, this.accent, this.onCopy});

  @override
  Widget build(BuildContext context) {
    final color = accent ?? Colors.white60;
    return Container(
      width: double.infinity, padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF131929),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: (accent ?? Colors.white).withOpacity(0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color.withOpacity(0.6), size: 13),
              const SizedBox(width: 6),
              Text(label, style: TextStyle(color: color.withOpacity(0.5),
                  fontSize: 10, letterSpacing: 1.0)),
              if (onCopy != null) ...[
                const Spacer(),
                GestureDetector(
                  onTap: onCopy,
                  child: const Row(children: [
                    Icon(Icons.copy, color: Colors.white24, size: 13),
                    SizedBox(width: 4),
                    Text('копировать',
                        style: TextStyle(color: Colors.white24,
                            fontSize: 10)),
                  ]),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          Text(value, style: TextStyle(
            color: color,
            fontSize: accent != null ? 22 : 12,
            fontWeight: accent != null ? FontWeight.bold : FontWeight.normal,
            fontFamily: accent == null ? 'monospace' : null,
            height: 1.4,
          )),
        ],
      ),
    );
  }
}

// ── Круглая кнопка действия ──────────────────────────────────
class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: const Color(0xFF00D4AA).withOpacity(0.12),
              shape: BoxShape.circle,
              border: Border.all(
                color: const Color(0xFF00D4AA).withOpacity(0.3),
              ),
            ),
            child: Icon(
              icon,
              color: const Color(0xFF00D4AA),
              size: 24,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Главная оболочка с нижней навигацией ─────────────────────
class _MainShell extends StatefulWidget {
  final String? privateKeyHex;
  final String? address;
  final Widget child;

  const _MainShell({
    required this.privateKeyHex,
    required this.address,
    required this.child,
  });

  @override
  State<_MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<_MainShell> {
  int _idx = 0;

@override
  Widget build(BuildContext context) {
    // 1. Считаем сумму MEE и MEGA для рейтинга и ранга в чате
    double chatScore = 0.0;
    
    // Ищем состояние страницы кошелька, чтобы забрать текущие балансы токенов
    double meeWallet = 0.0;
    double megaWallet = 0.0;
    final walletState = context.findAncestorStateOfType<_WalletPageState>();
    if (walletState != null) {
      for (var t in walletState._tokens) {
        final symbol = t.symbol.toUpperCase();
        if (symbol == 'MEE')  { meeWallet  = t.amount; chatScore += t.amount; }
        if (symbol == 'MEGA') { megaWallet = t.amount; chatScore += t.amount; }
      }
    }

    return Scaffold(
      body: IndexedStack(
        index: _idx,
        children: [
          widget.child,
          AirdropPage(
            privateKeyHex: widget.privateKeyHex,
            address: widget.address,
            onBack: () => setState(() => _idx = 0),
          ),
          

          AboutPage(privateKeyHex: widget.privateKeyHex),
          
          /*
          // 2. Передаем реальный адрес кошелька и посчитанный баланс токенов
          ChatPage(
            walletAddress: widget.address ?? "0x0000000000000000000000000000000000000000",
            meeWallet: meeWallet,
            megaWallet: megaWallet,
          ), */

          ChatPage(
            walletAddress: widget.address ?? "0x0000000000000000000000000000000000000000",
            meeWallet: meeWallet,
            megaWallet: megaWallet,
            onBack: () => setState(() => _idx = 0),
          ),




        ],
      ),
      bottomNavigationBar: _BottomNav(
        currentIndex: _idx,
        onTap: (i) => setState(() => _idx = i),
      ),
    );
  }

/*
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _idx,
        children: [
          widget.child,
          AirdropPage(
            privateKeyHex: widget.privateKeyHex,
            address: widget.address,
            onBack: () => setState(() => _idx = 0), // Возвращаем на вкладку кошелька
          ),
          const AboutPage(),
          const ChatPage(),
        ],
      ),
      bottomNavigationBar: _BottomNav(
        currentIndex: _idx,
        onTap: (i) => setState(() => _idx = i),
      ),
    );
  }
*/



}

// ── Нижняя панель навигации ───────────────────────────────────
class _BottomNav extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;

  const _BottomNav({required this.currentIndex, required this.onTap});

  @override
  Widget build(BuildContext context) {
    const tabs = [
      (icon: Icons.account_balance_wallet_outlined, label: 'Кошелёк'),
      (icon: Icons.card_giftcard_outlined,          label: 'Аирдроп'),
      (icon: Icons.token_outlined,            label: 'Nft'),
      (icon: Icons.forum_outlined,                  label: 'Чат'),
    ];

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0A0E1A),
        border: Border(
          top: BorderSide(color: Colors.white.withOpacity(0.08), width: 0.5),
        ),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 62,
          child: Row(
            children: List.generate(tabs.length, (i) {
              final tab = tabs[i];
              final selected = i == currentIndex;
              return Expanded(
                child: InkWell(
                  onTap: () => onTap(i),
                  splashColor: Colors.transparent,
                  highlightColor: Colors.transparent,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(tab.icon, size: 22,
                          color: selected
                              ? const Color(0xFF00D4AA)
                              : Colors.white38),
                      const SizedBox(height: 3),
                      Text(
                        tab.label,
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: 10,
                          color: selected
                              ? const Color(0xFF00D4AA)
                              : Colors.white38,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}

import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointycastle/export.dart' as pc;
import 'package:convert/convert.dart' as convert;

// ─────────────────────────────────────────────────────────────
// Модель аккаунта
// ─────────────────────────────────────────────────────────────
class WalletAccount {
  final String address;
  final String privateKeyHex;
  final String name;

  const WalletAccount({
    required this.address,
    required this.privateKeyHex,
    required this.name,
  });

  Map<String, dynamic> toJson() => {
    'address': address,
    'privateKeyHex': privateKeyHex,
    'name': name,
  };

  factory WalletAccount.fromJson(Map<String, dynamic> j) => WalletAccount(
    address: j['address'] as String,
    privateKeyHex: j['privateKeyHex'] as String,
    name: (j['name'] as String?) ?? 'Кошелёк',
  );

  String get shortAddress =>
      '${address.substring(0, 6)}...${address.substring(address.length - 4)}';
}

// ─────────────────────────────────────────────────────────────
// Хранилище — работает через колбеки (SharedPreferences в main.dart)
// ─────────────────────────────────────────────────────────────
class AccountStorage {
  static const _accountsKey = 'mee_wallet_accounts';
  static const _activeKey   = 'mee_wallet_active_address';

  // Колбеки устанавливаются из main.dart при старте
  static Future<String?> Function(String key)? _read;
  static Future<void> Function(String key, String value)? _write;

  static void init({
    required Future<String?> Function(String key) read,
    required Future<void> Function(String key, String value) write,
  }) {
    _read  = read;
    _write = write;
  }

  static Future<List<WalletAccount>> loadAll() async {
    final raw = await _read?.call(_accountsKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list.map((e) => WalletAccount.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) { return []; }
  }

  static Future<void> saveAll(List<WalletAccount> accounts) async {
    await _write?.call(_accountsKey,
        jsonEncode(accounts.map((a) => a.toJson()).toList()));
  }

  static Future<String?> getActiveAddress() async =>
      _read?.call(_activeKey);

  static Future<void> setActiveAddress(String address) async {
    await _write?.call(_activeKey, address);
    await _write?.call('petra_saved_address', address);
  }

  static Future<void> addAccount(WalletAccount account) async {
    final accounts = await loadAll();
    if (!accounts.any((a) => a.address == account.address)) {
      accounts.add(account);
    }
    await saveAll(accounts);
    await setActiveAddress(account.address);
  }

  static Future<void> removeAccount(String address) async {
    var accounts = await loadAll();
    accounts.removeWhere((a) => a.address == address);
    await saveAll(accounts);
    final active = await getActiveAddress();
    if (active == address && accounts.isNotEmpty) {
      await setActiveAddress(accounts.first.address);
    }
  }

  static Future<WalletAccount?> getActive() async {
    final accounts = await loadAll();
    if (accounts.isEmpty) return null;
    final activeAddr = await getActiveAddress();
    try {
      return accounts.firstWhere((a) => a.address == activeAddr);
    } catch (_) {
      return accounts.first;
    }
  }
}

// ─────────────────────────────────────────────────────────────
// Ed25519: приватный ключ → адрес Aptos
// ─────────────────────────────────────────────────────────────
String deriveAptosAddress(String privateKeyHex) {
  final seed = Uint8List.fromList(
      convert.hex.decode(privateKeyHex.replaceFirst('0x', '')));

  final q = (BigInt.from(2).pow(255)) - BigInt.from(19);
  final d = (BigInt.parse('-121665') *
      BigInt.parse('121666').modInverse(q)) % q;
  final II = BigInt.from(2).modPow((q - BigInt.one) ~/ BigInt.from(4), q);

  List<BigInt> recoverX(BigInt y) {
    final y2 = y * y % q;
    final x2 = ((y2 - BigInt.one) *
        (d * y2 + BigInt.one).modInverse(q)) % q;
    if (x2 == BigInt.zero) return [BigInt.zero, BigInt.zero];
    BigInt x = x2.modPow((q + BigInt.from(3)) ~/ BigInt.from(8), q);
    if ((x * x - x2) % q != BigInt.zero) x = x * II % q;
    if (x.isOdd) x = q - x;
    return [x, y];
  }

  final by = BigInt.from(4) * BigInt.from(5).modInverse(q) % q;
  final bx = recoverX(by)[0];
  final base = [bx, by, BigInt.one, bx * by % q];

  List<BigInt> edAdd(List<BigInt> P, List<BigInt> Q) {
    final a = (P[1] - P[0]) * (Q[1] - Q[0]) % q;
    final b = (P[1] + P[0]) * (Q[1] + Q[0]) % q;
    final c = BigInt.from(2) * P[3] * Q[3] % q * d % q;
    final dd = BigInt.from(2) * P[2] * Q[2] % q;
    final e = b - a; final f = dd - c;
    final g2 = dd + c; final h = b + a;
    return [e * f % q, g2 * h % q, f * g2 % q, e * h % q];
  }

  List<BigInt> scalarMult(List<BigInt> P, BigInt n) {
    if (n == BigInt.zero) return [BigInt.zero, BigInt.one, BigInt.one, BigInt.zero];
    var Q = scalarMult(P, n ~/ BigInt.two);
    Q = edAdd(Q, Q);
    if (n.isOdd) Q = edAdd(Q, P);
    return Q;
  }

  Uint8List encodePoint(List<BigInt> P) {
    final zinv = P[2].modInverse(q);
    final x = P[0] * zinv % q;
    final y = P[1] * zinv % q;
    final out = Uint8List(32);
    BigInt v = y;
    for (int i = 0; i < 32; i++) {
      out[i] = (v & BigInt.from(0xFF)).toInt(); v = v >> 8;
    }
    if (x.isOdd) out[31] |= 0x80;
    return out;
  }

  final sha512 = pc.SHA512Digest();
  final h = Uint8List(64);
  sha512.update(seed, 0, 32); sha512.doFinal(h, 0);
  h[0] &= 248; h[31] &= 127; h[31] |= 64;
  BigInt a = BigInt.zero;
  for (int i = 0; i < 32; i++) a += BigInt.from(h[i]) << (8 * i);
  final pubKey = encodePoint(scalarMult(base, a));

  final input = Uint8List(33);
  input.setRange(0, 32, pubKey); input[32] = 0x00;
  final sha3 = pc.SHA3Digest(256);
  sha3.update(input, 0, 33);
  final out = Uint8List(32); sha3.doFinal(out, 0);
  return '0x${convert.hex.encode(out)}';
}

// ─────────────────────────────────────────────────────────────
// Страница управления аккаунтами
// ─────────────────────────────────────────────────────────────
class AccountManagerPage extends StatefulWidget {
  final String activeAddress;
  final Function(WalletAccount) onSwitch;

  const AccountManagerPage({
    super.key,
    required this.activeAddress,
    required this.onSwitch,
  });

  @override
  State<AccountManagerPage> createState() => _AccountManagerPageState();
}

class _AccountManagerPageState extends State<AccountManagerPage> {
  List<WalletAccount> _accounts = [];
  bool _loading = true;
  bool _showAddForm = false;
  final _keyController  = TextEditingController();
  final _nameController = TextEditingController();
  String? _addError;
  bool _adding = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _keyController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final accounts = await AccountStorage.loadAll();
    if (mounted) setState(() { _accounts = accounts; _loading = false; });
  }

  Future<void> _addAccount() async {
    final keyRaw = _keyController.text.trim();
    final name   = _nameController.text.trim();
    if (keyRaw.isEmpty) {
      setState(() => _addError = 'Введите приватный ключ'); return;
    }

    // Нормализация — принимаем любой формат:
    // ed25519-priv-0xABC..., ed25519-priv-ABC..., 0xABC..., ABC...
    String clean = keyRaw;
    // Убираем префиксы ed25519-priv-, ed25519-, private-key-
    for (final prefix in ['ed25519-priv-', 'ed25519-', 'private-key-']) {
      if (clean.startsWith(prefix)) {
        clean = clean.substring(prefix.length);
        break;
      }
    }
    // Убираем 0x
    if (clean.startsWith('0x') || clean.startsWith('0X')) {
      clean = clean.substring(2);
    }
    // Если 128 символов (full keypair) — берём первые 64
    if (clean.length == 128) clean = clean.substring(0, 64);

    if (clean.length != 64 || !RegExp(r'^[0-9a-fA-F]+$').hasMatch(clean)) {
      setState(() => _addError = 'Неверный формат ключа.\nПоддерживается: ed25519-priv-0x..., 0x..., или 64 hex символа');
      return;
    }

    setState(() { _adding = true; _addError = null; });
    try {
      final address = deriveAptosAddress(clean);
      final account = WalletAccount(
        address: address,
        privateKeyHex: clean,
        name: name.isEmpty ? 'Кошелёк ${_accounts.length + 1}' : name,
      );
      await AccountStorage.addAccount(account);
      await _load();
      _keyController.clear();
      _nameController.clear();
      setState(() { _showAddForm = false; _adding = false; });
    } catch (e) {
      setState(() { _addError = 'Ошибка: $e'; _adding = false; });
    }
  }

  Future<void> _switchTo(WalletAccount account) async {
    await AccountStorage.setActiveAddress(account.address);
    widget.onSwitch(account);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _renameAccount(WalletAccount account) async {
    final ctrl = TextEditingController(text: account.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E2A3A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Переименовать кошелёк',
            style: TextStyle(color: Colors.white, fontSize: 17)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'Название кошелька',
            hintStyle: const TextStyle(color: Colors.white38),
            filled: true,
            fillColor: const Color(0xFF131929),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide.none,
            ),
            contentPadding: const EdgeInsets.symmetric(
                horizontal: 14, vertical: 12),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена',
                style: TextStyle(color: Colors.white38)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Сохранить',
                style: TextStyle(color: Color(0xFF6C63FF),
                    fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (newName == null || newName.isEmpty || newName == account.name) return;

    final accounts = await AccountStorage.loadAll();
    final idx = accounts.indexWhere((a) => a.address == account.address);
    if (idx != -1) {
      accounts[idx] = WalletAccount(
        address: account.address,
        privateKeyHex: account.privateKeyHex,
        name: newName,
      );
      await AccountStorage.saveAll(accounts);
      await _load();
    }
  }

  Future<void> _deleteAccount(WalletAccount account) async {
    final isActive = account.address == widget.activeAddress;
    final accounts = await AccountStorage.loadAll();
    final isLast = accounts.length == 1;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E2A3A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(children: [
          const Icon(Icons.warning_rounded, color: Colors.redAccent, size: 22),
          const SizedBox(width: 10),
          const Text('Удалить кошелёк?',
              style: TextStyle(color: Colors.white, fontSize: 17)),
        ]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF131929),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(children: [
                Container(
                  width: 36, height: 36,
                  decoration: BoxDecoration(
                    color: Colors.redAccent.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Center(child: Text(
                    account.name.isNotEmpty
                        ? account.name[0].toUpperCase() : 'W',
                    style: const TextStyle(color: Colors.redAccent,
                        fontSize: 16, fontWeight: FontWeight.bold),
                  )),
                ),
                const SizedBox(width: 10),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(account.name,
                      style: const TextStyle(color: Colors.white,
                          fontSize: 13, fontWeight: FontWeight.w600)),
                  Text(account.shortAddress,
                      style: const TextStyle(color: Colors.white38,
                          fontSize: 11, fontFamily: 'monospace')),
                ]),
              ]),
            ),
            const SizedBox(height: 12),
            const Text('⚠️ Убедитесь что сохранили приватный ключ!',
                style: TextStyle(color: Colors.amber,
                    fontSize: 12, height: 1.5)),
            if (isActive) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.redAccent.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  '🔴 Это активный кошелёк. После удаления приложение '
                  'переключится на другой кошелёк из списка.',
                  style: TextStyle(color: Colors.redAccent,
                      fontSize: 11, height: 1.4),
                ),
              ),
            ],
            if (isLast) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  '⚠️ Это единственный кошелёк. После удаления '
                  'потребуется добавить новый.',
                  style: TextStyle(color: Colors.orange,
                      fontSize: 11, height: 1.4),
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена',
                style: TextStyle(color: Colors.white38)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.redAccent,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Удалить',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await AccountStorage.removeAccount(account.address);
      await _load();
      // Если удалили активный — уведомляем родителя
      if (isActive) {
        final remaining = await AccountStorage.getActive();
        if (remaining != null && mounted) {
          widget.onSwitch(remaining);
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      body: SafeArea(
        child: Column(
          children: [
            Container(
              color: const Color(0xFF131929),
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    onPressed: () => Navigator.pop(context),
                  ),
                  const Expanded(
                    child: Text('Мои кошельки',
                        style: TextStyle(color: Colors.white, fontSize: 18,
                            fontWeight: FontWeight.bold),
                        textAlign: TextAlign.center),
                  ),
                  IconButton(
                    icon: Icon(_showAddForm ? Icons.close : Icons.add,
                        color: const Color(0xFF6C63FF)),
                    onPressed: () => setState(() {
                      _showAddForm = !_showAddForm; _addError = null;
                    }),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator(
                      color: Color(0xFF6C63FF)))
                  : ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        if (_showAddForm) ...[
                          _buildAddForm(),
                          const SizedBox(height: 20),
                        ],
                        if (_accounts.isEmpty && !_showAddForm)
                          _buildEmptyState()
                        else
                          ..._accounts.map((a) => _buildAccountCard(a)),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Container(
      padding: const EdgeInsets.all(32),
      decoration: BoxDecoration(color: const Color(0xFF131929),
          borderRadius: BorderRadius.circular(12)),
      child: Column(children: [
        const Icon(Icons.account_balance_wallet_outlined,
            color: Colors.white24, size: 48),
        const SizedBox(height: 16),
        const Text('Нет сохранённых кошельков',
            style: TextStyle(color: Colors.white38, fontSize: 14)),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: () => setState(() => _showAddForm = true),
          style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF6C63FF)),
          icon: const Icon(Icons.add),
          label: const Text('Добавить кошелёк'),
        ),
      ]),
    );
  }

  Widget _buildAddForm() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF131929),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF6C63FF).withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Добавить кошелёк',
              style: TextStyle(color: Colors.white, fontSize: 15,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          _buildTextField(_nameController, 'Название (необязательно)',
              obscure: false),
          const SizedBox(height: 12),
          _buildTextField(_keyController, 'Приватный ключ (любой формат)',
              obscure: true,
              suffix: IconButton(
                icon: const Icon(Icons.paste, color: Colors.white38, size: 18),
                onPressed: () async {
                  final d = await Clipboard.getData('text/plain');
                  if (d?.text != null) _keyController.text = d!.text!.trim();
                },
              )),
          if (_addError != null) ...[
            const SizedBox(height: 8),
            Text(_addError!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
          ],
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.orange.withOpacity(0.08),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.orange.withOpacity(0.2)),
            ),
            child: const Row(children: [
              Icon(Icons.warning_outlined, color: Colors.orange, size: 14),
              SizedBox(width: 8),
              Expanded(child: Text(
                'Приватный ключ хранится локально на устройстве.',
                style: TextStyle(color: Colors.orange, fontSize: 11, height: 1.4),
              )),
            ]),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _adding ? null : _addAccount,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF6C63FF),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: _adding
                  ? const SizedBox(width: 20, height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Text('Добавить',
                      style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTextField(TextEditingController ctrl, String label,
      {required bool obscure, Widget? suffix}) {
    return TextField(
      controller: ctrl,
      obscureText: obscure,
      style: TextStyle(
          color: Colors.white,
          fontFamily: obscure ? 'monospace' : null,
          fontSize: obscure ? 12 : 14),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white38),
        filled: true,
        fillColor: const Color(0xFF0A0E1A),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none),
        contentPadding: const EdgeInsets.symmetric(
            horizontal: 14, vertical: 12),
        suffixIcon: suffix,
      ),
    );
  }

  Widget _buildAccountCard(WalletAccount account) {
    final isActive = account.address == widget.activeAddress;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF131929),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isActive
              ? const Color(0xFF6C63FF).withOpacity(0.5)
              : Colors.white.withOpacity(0.07),
          width: isActive ? 1.5 : 1,
        ),
      ),
      child: Row(children: [
        // Аватар — кликабельный для переключения
        GestureDetector(
          onTap: isActive ? null : () => _switchTo(account),
          child: Container(
            width: 44, height: 44,
            decoration: BoxDecoration(
              color: isActive
                  ? const Color(0xFF6C63FF).withOpacity(0.15)
                  : Colors.white.withOpacity(0.05),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Center(child: Text(
              account.name.isNotEmpty ? account.name[0].toUpperCase() : 'W',
              style: TextStyle(
                color: isActive ? const Color(0xFF6C63FF) : Colors.white38,
                fontSize: 18, fontWeight: FontWeight.bold,
              ),
            )),
          ),
        ),
        const SizedBox(width: 12),
        // Инфо — кликабельно для переключения
        Expanded(
          child: GestureDetector(
            onTap: isActive ? null : () => _switchTo(account),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Flexible(child: Text(account.name,
                      style: const TextStyle(color: Colors.white,
                          fontSize: 14, fontWeight: FontWeight.w600))),
                  if (isActive) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFF6C63FF).withOpacity(0.15),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text('активный',
                          style: TextStyle(color: Color(0xFF6C63FF),
                              fontSize: 9, fontWeight: FontWeight.w600)),
                    ),
                  ],
                ]),
                const SizedBox(height: 3),
                Text(account.shortAddress,
                    style: const TextStyle(color: Colors.white38,
                        fontSize: 12, fontFamily: 'monospace')),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        // Кнопка Выбрать (не активный)
        if (!isActive)
          TextButton(
            onPressed: () => _switchTo(account),
            style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 6)),
            child: const Text('Выбрать',
                style: TextStyle(color: Color(0xFF6C63FF), fontSize: 12)),
          ),
        // Кнопка переименования
        GestureDetector(
          onTap: () => _renameAccount(account),
          child: Container(
            width: 32, height: 32,
            margin: const EdgeInsets.only(right: 6),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.06),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white.withOpacity(0.12)),
            ),
            child: const Icon(Icons.edit_outlined,
                color: Colors.white38, size: 15),
          ),
        ),
        // Кнопка удаления — красная, для всех
        GestureDetector(
          onTap: () => _deleteAccount(account),
          child: Container(
            width: 32, height: 32,
            decoration: BoxDecoration(
              color: Colors.redAccent.withOpacity(0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.redAccent.withOpacity(0.3)),
            ),
            child: const Icon(Icons.close,
                color: Colors.redAccent, size: 16),
          ),
        ),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Bottom sheet — быстрое переключение
// ─────────────────────────────────────────────────────────────
Future<void> showAccountSwitcher({
  required BuildContext context,
  required String activeAddress,
  required Function(WalletAccount) onSwitch,
}) async {
  final accounts = await AccountStorage.loadAll();
  if (!context.mounted) return;

  if (accounts.length <= 1) {
    await Navigator.push(context, MaterialPageRoute(
      builder: (_) => AccountManagerPage(
        activeAddress: activeAddress,
        onSwitch: onSwitch,
      ),
    ));
    return;
  }

  await showModalBottomSheet(
    context: context,
    backgroundColor: const Color(0xFF131929),
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (ctx) => _AccountSwitcherSheet(
      accounts: accounts,
      activeAddress: activeAddress,
      onSwitch: onSwitch,
      onManage: () {
        Navigator.pop(ctx);
        Navigator.push(context, MaterialPageRoute(
          builder: (_) => AccountManagerPage(
            activeAddress: activeAddress,
            onSwitch: onSwitch,
          ),
        ));
      },
    ),
  );
}

class _AccountSwitcherSheet extends StatelessWidget {
  final List<WalletAccount> accounts;
  final String activeAddress;
  final Function(WalletAccount) onSwitch;
  final VoidCallback onManage;

  const _AccountSwitcherSheet({
    required this.accounts,
    required this.activeAddress,
    required this.onSwitch,
    required this.onManage,
  });

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.of(context).size.height * 0.75;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 40, height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(color: Colors.white24,
                    borderRadius: BorderRadius.circular(2))),
            const Text('Выберите кошелёк',
                style: TextStyle(color: Colors.white, fontSize: 16,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            // Список со скроллом
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: accounts.map((account) {
                  final isActive = account.address == activeAddress;
                  return GestureDetector(
                    onTap: () {
                      Navigator.pop(context);
                      if (!isActive) onSwitch(account);
                    },
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: isActive
                            ? const Color(0xFF6C63FF).withOpacity(0.10)
                            : const Color(0xFF0A0E1A),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isActive
                              ? const Color(0xFF6C63FF).withOpacity(0.4)
                              : Colors.white.withOpacity(0.07),
                        ),
                      ),
                      child: Row(children: [
                        Container(
                          width: 38, height: 38,
                          decoration: BoxDecoration(
                            color: isActive
                                ? const Color(0xFF6C63FF).withOpacity(0.2)
                                : Colors.white.withOpacity(0.05),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Center(child: Text(
                            account.name.isNotEmpty
                                ? account.name[0].toUpperCase() : 'W',
                            style: TextStyle(
                              color: isActive
                                  ? const Color(0xFF6C63FF) : Colors.white38,
                              fontSize: 16, fontWeight: FontWeight.bold,
                            ),
                          )),
                        ),
                        const SizedBox(width: 12),


                        /*
                        Expanded(child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(account.name,
                                style: TextStyle(
                                  color: isActive ? Colors.white : Colors.white70,
                                  fontSize: 13, fontWeight: FontWeight.w600,
                                )),
                            const SizedBox(height: 2),
                            Text(account.shortAddress,
                                style: const TextStyle(color: Colors.white38,
                                    fontSize: 11, fontFamily: 'monospace')),
                          ],
                        )),
                        if (isActive)
                          const Icon(Icons.check_circle,
                              color: Color(0xFF6C63FF), size: 18)
                        else
                          const Icon(Icons.arrow_forward_ios,
                              color: Colors.white24, size: 14),
                        */  

                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(account.name,
                                  style: const TextStyle(color: Colors.white,
                                      fontSize: 14, fontWeight: FontWeight.w500)),
                              const SizedBox(height: 2),
                              Text(account.shortAddress,
                                  style: const TextStyle(color: Colors.white38,
                                      fontSize: 11, fontFamily: 'monospace')),
                            ],
                          ),
                        ),
                        // НАЧАЛО ИЗМЕНЕНИЙ: Кнопка копирования перед стрелочкой/галочкой
                        GestureDetector(
                          onTap: () {}, // Перехватываем тап, чтобы строка под кнопкой не кликалась
                          child: IconButton(
                            icon: const Icon(Icons.copy, color: Colors.white38, size: 16),
                            constraints: const BoxConstraints(),
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            onPressed: () {
                              // 1. Копируем в буфер обмена
                              Clipboard.setData(ClipboardData(text: account.address));
                              
                              // 2. Создаем всплывающее уведомление поверх всех окон через Overlay
                              final overlay = Overlay.of(context);
                              final entry = OverlayEntry(
                                builder: (context) => Positioned(
                                  bottom: 50, // Высота от нижнего края экрана
                                  left: 20,
                                  right: 20,
                                  child: Material(
                                    color: Colors.transparent,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF131929), // Твой цвет фона
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(color: Colors.white10),
                                        boxShadow: [
                                          BoxShadow(
                                            color: Colors.black.withOpacity(0.3),
                                            blurRadius: 10,
                                            offset: const Offset(0, 4),
                                          ),
                                        ],
                                      ),
                                      child: Row(
                                        children: [
                                          const Icon(Icons.check_circle, color: Color(0xFF00D4AA), size: 20),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Text(
                                              'Адрес "${account.name}" скопирован!',
                                              style: const TextStyle(color: Colors.white, fontSize: 13),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              );

                              // Вставляем уведомление на экран
                              overlay.insert(entry);

                              // Через 2 секунды автоматически его удаляем
                              Future.delayed(const Duration(seconds: 2), () {
                                entry.remove();
                              });
                            },
                          ),
                        ),
                        // Родные иконки переключения остаются нетронутыми справа
                        if (isActive)
                          const Icon(Icons.check_circle,
                              color: Color(0xFF6C63FF), size: 18)
                        else
                          const Icon(Icons.arrow_forward_ios,
                              color: Colors.white24, size: 14),
                        // КОНЕЦ ИЗМЕНЕНИЙ



                      ]),
                    ),
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: onManage,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  side: BorderSide(color: Colors.white.withOpacity(0.15)),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                icon: const Icon(Icons.manage_accounts,
                    color: Colors.white38, size: 16),
                label: const Text('Управление кошельками',
                  style: TextStyle(color: Colors.white38, fontSize: 13)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

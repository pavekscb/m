// price_service.dart — курсы токенов в USD
// APT/USDT/USDC → Binance | MEE → пул Hyperion | MEGA → линейная формула
import 'dart:convert';
import 'package:http/http.dart' as http;

// ── MEGA формула (из swap.dart) ───────────────────────────────
const int    _megaStartSec   = 1767623400;
const int    _megaEndSec     = 1795075200;
const double _megaStartPrice = 0.001; // в APT
const double _megaEndPrice   = 0.1;   // в APT

double _megaPriceInApt() {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  if (now <= _megaStartSec) return _megaStartPrice;
  if (now >= _megaEndSec)   return _megaEndPrice;
  return _megaStartPrice +
    (_megaEndPrice - _megaStartPrice) *
    (now - _megaStartSec) / (_megaEndSec - _megaStartSec);
}

// ── Пул MEE/APT на Hyperion ───────────────────────────────────
const String _aptNode = 'https://fullnode.mainnet.aptoslabs.com/v1';
const String _aptCoin = '0x1::aptos_coin::AptosCoin';
const String _meeCoin = '0xe9c192ff55cffab3963c695cff6dbf9dad6aff2bb5ac19a6415cad26a81860d9::mee_coin::MeeCoin';
const String _poolAddr = '0xc7efb4076dbe143cbcd98cfaaa929ecfc8f299203dfff63b95ccb6bfe19850fa';

// ══════════════════════════════════════════════════════════════
// PriceService — синглтон с кэшем 60 секунд
// ══════════════════════════════════════════════════════════════
class PriceService {
  PriceService._();
  static final PriceService instance = PriceService._();

  Map<String, double> _prices = {}; // символ → цена USD
  DateTime? _lastFetch;
  bool _fetching = false;

  // Получить цену символа в USD (0 если неизвестна)
  double priceOf(String symbol) => _prices[symbol.toUpperCase()] ?? 0;

  // Все цены
  Map<String, double> get prices => Map.unmodifiable(_prices);

  bool get hasData => _prices.isNotEmpty;

  // Загрузить/обновить курсы (кэш 60 сек)
  Future<Map<String, double>> fetchPrices({bool force = false}) async {
    if (_fetching) return _prices;
    final now = DateTime.now();
    if (!force && _lastFetch != null &&
        now.difference(_lastFetch!).inSeconds < 60) {
      return _prices;
    }
    _fetching = true;
    try {
      final results = await Future.wait([
        _fetchBinancePrices(),
        _fetchMeePrice(),
      ], eagerError: false).catchError((_) => [<String,double>{}, 0.0]);

      final binance = results[0] as Map<String, double>;
      final meeUsd  = results[1] as double;
      final aptUsd  = binance['APT'] ?? 0;
      final megaUsd = _megaPriceInApt() * aptUsd;

      _prices = {
        ...binance,
        'MEE':  meeUsd,
        'MEGA': megaUsd,
      };
      _lastFetch = now;
    } catch(_) {}
    _fetching = false;
    return _prices;
  }

  // ── Binance: APT, USDT, USDC ─────────────────────────────
  Future<Map<String, double>> _fetchBinancePrices() async {
    try {
      final symbols = ['APTUSDT'];
      final results = await Future.wait(
        symbols.map((s) => http.get(
          Uri.parse('https://api.binance.com/api/v3/ticker/price?symbol=$s'),
          headers: {'Accept': 'application/json'},
        ).timeout(const Duration(seconds: 8)))
      );

      final map = <String, double>{
        'USDT': 1.0,
        'USDC': 1.0,
      };

      for (int i = 0; i < symbols.length; i++) {
        if (results[i].statusCode == 200) {
          final data = jsonDecode(results[i].body);
          final price = double.tryParse(data['price'].toString()) ?? 0;
          final symbol = symbols[i].replaceAll('USDT', '');
          map[symbol] = price;
        }
      }
      return map;
    } catch(_) {
      return {'USDT': 1.0, 'USDC': 1.0};
    }
  }

  // ── MEE: из резервов пула APT/MEE × курс APT ─────────────
  Future<double> _fetchMeePrice() async {
    try {
      final poolUri = Uri.parse(
        '$_aptNode/accounts/$_poolAddr/resource/'
        '$_poolAddr::swap::TokenPairMetadata<$_aptCoin,$_meeCoin>'
      );
      final resp = await http.get(poolUri)
        .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return 0;

      final data = jsonDecode(resp.body);
      final reserveApt = double.parse(
        data['data']['balance_x']['value'].toString()) / 1e8;
      final reserveMee = double.parse(
        data['data']['balance_y']['value'].toString()) / 1e8;
      if (reserveMee == 0) return 0;

      final aptUsd = _prices['APT'] ?? 0;
      if (aptUsd == 0) {
        // Если APT ещё не загружен — грузим отдельно
        final aptResp = await http.get(
          Uri.parse('https://api.binance.com/api/v3/ticker/price?symbol=APTUSDT'))
          .timeout(const Duration(seconds: 8));
        if (aptResp.statusCode == 200) {
          final aptPrice = double.tryParse(
            jsonDecode(aptResp.body)['price'].toString()) ?? 0;
          final meeInApt = reserveApt / reserveMee;
          return meeInApt * aptPrice;
        }
        return 0;
      }

      final meeInApt = reserveApt / reserveMee;
      return meeInApt * aptUsd;
    } catch(_) {
      return 0;
    }
  }
}

// ── Хелперы форматирования ────────────────────────────────────
String formatUsd(double usd) {
  if (usd == 0) return '';
  if (usd < 0.001) return '<\$0.001';
  if (usd < 1) return '\$${usd.toStringAsFixed(4)}';
  if (usd < 1000) return '\$${usd.toStringAsFixed(2)}';
  if (usd < 1000000) return '\$${(usd / 1000).toStringAsFixed(2)}K';
  return '\$${(usd / 1000000).toStringAsFixed(2)}M';
}

String formatUsdPrice(double usd) {
  if (usd == 0) return '';
  if (usd < 0.0001) return '<\$0.0001';
  if (usd < 0.01) return '\$${usd.toStringAsFixed(6)}';
  if (usd < 1) return '\$${usd.toStringAsFixed(4)}';
  return '\$${usd.toStringAsFixed(2)}';
}

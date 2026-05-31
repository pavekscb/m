import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:convert/convert.dart' as convert;
import 'package:pointycastle/export.dart' as pc;
import 'panora.dart';

// --- КОНСТАНТЫ СЕТИ И ТОКЕНОВ ---
const String aptCoinType  = "0x1::aptos_coin::AptosCoin";
const String meeCoinType  = "0xe9c192ff55cffab3963c695cff6dbf9dad6aff2bb5ac19a6415cad26a81860d9::mee_coin::MeeCoin";
const String megaCoinType = "0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3::mega_coin::MEGA";
const String usdtCoinType = "0x357b0b74bc833e95a115ad22604854d6b0fca151cecd94111770e5d6ffc9dc2b";
const String usdcCoinType = "0xbae207659db88bea0cbead6da0ed00aac12edcdda169e591cd41c94180b46f3b";
const String aptNodeUrl   = "https://fullnode.mainnet.aptoslabs.com/v1";


const int    _startTimeSec = 1767623400;
const int    _endTimeSec   = 1795075200;
const double _startPrice   = 0.001;
const double _endPrice     = 0.1;

const int    _listingTimeSec = 1795046400;

const Map<String, String> _tokenIcons = {
  'APT':  'assets/apt.png',
  'MEE':  'assets/mee.png',
  'MEGA': 'assets/mega.png',
  'USDT': 'assets/usdt.png',
  'USDC': 'assets/usdc.png',
};

double _getMegaCurrentPrice() {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  if (now <= _startTimeSec) return _startPrice;
  if (now >= _endTimeSec)   return _endPrice;
  return _startPrice + (_endPrice - _startPrice) * (now - _startTimeSec) / (_endTimeSec - _startTimeSec);
}

enum _SwapStatus { idle, loading, success, error }

class SwapPage extends StatefulWidget {
  final String currentAddress;
  final String privateKeyHex;
  final double aptBalance;
  final double meeBalance;
  final double megaBalance;
  final double usdtBalance;
  final double usdcBalance;
  final Function() onSwapSuccess;

  const SwapPage({
    super.key,
    required this.currentAddress,
    required this.privateKeyHex,
    required this.aptBalance,
    required this.meeBalance,
    required this.megaBalance,
    this.usdtBalance = 0,
    this.usdcBalance = 0,
    required this.onSwapSuccess,
  });

  @override
  State<SwapPage> createState() => _SwapPageState();
}

class _SwapPageState extends State<SwapPage> {
  final TextEditingController _inputController = TextEditingController();
  final TextEditingController _outputController = TextEditingController();

  String _fromToken = "APT";
  String _toToken = "MEE";
  
  _SwapStatus _status = _SwapStatus.idle;
  String? _errorMsg;
  String? _txHash;

  BigInt _reserveApt = BigInt.zero;
  BigInt _reserveMee = BigInt.zero;
  double _exchangeRate = 0.0;
  HyperionQuote? _hyperionQuote;
  bool _hyperionLoading = false;
  int _hyperionRequestId = 0; // для отмены устаревших запросов

  // --- Встроенный Ed25519 крипто-движок из mee_claim_reward.dart ---
  final BigInt _q = (BigInt.from(2).pow(255)) - BigInt.from(19);
  final BigInt _d = (BigInt.parse('-121665') * BigInt.parse('121666').modInverse((BigInt.from(2).pow(255)) - BigInt.from(19))) % ((BigInt.from(2).pow(255)) - BigInt.from(19));
  final BigInt _I = BigInt.from(2).modPow(((BigInt.from(2).pow(255)) - BigInt.from(19) - BigInt.one) ~/ BigInt.from(4), (BigInt.from(2).pow(255)) - BigInt.from(19));

  List<BigInt> _recoverX(BigInt y) {
    final y2 = y * y % _q;
    final x2 = ((y2 - BigInt.one) * (_d * y2 + BigInt.one).modInverse(_q)) % _q;
    if (x2 == BigInt.zero) return [BigInt.zero, BigInt.zero];
    BigInt x = x2.modPow((_q + BigInt.from(3)) ~/ BigInt.from(8), _q);
    if ((x * x - x2) % _q != BigInt.zero) x = x * _I % _q;
    if (x.isOdd) x = _q - x;
    return [x, y];
  }

  List<BigInt> _basePoint() {
    final y = BigInt.from(4) * BigInt.from(5).modInverse(_q) % _q;
    return [_recoverX(y)[0], y, BigInt.one, _recoverX(y)[0] * y % _q];
  }

  List<BigInt> _edAdd(List<BigInt> P, List<BigInt> Q) {
    final a = (P[1] - P[0]) * (Q[1] - Q[0]) % _q;
    final b = (P[1] + P[0]) * (Q[1] + Q[0]) % _q;
    final c = BigInt.from(2) * P[3] * Q[3] % _q * _d % _q;
    final dd = BigInt.from(2) * P[2] * Q[2] % _q;
    final e = b - a; final f = dd - c;
    final g = dd + c; final h = b + a;
    return [e * f % _q, g * h % _q, f * g % _q, e * h % _q];
  }

  List<BigInt> _scalarMult(List<BigInt> P, BigInt n) {
    if (n == BigInt.zero) return [BigInt.zero, BigInt.one, BigInt.one, BigInt.zero];
    var Q = _scalarMult(P, n ~/ BigInt.two);
    Q = _edAdd(Q, Q);
    if (n.isOdd) Q = _edAdd(Q, P);
    return Q;
  }

  Uint8List _encodePoint(List<BigInt> P) {
    final zinv = P[2].modInverse(_q);
    final x = P[0] * zinv % _q;
    final y = P[1] * zinv % _q;
    final out = Uint8List(32);
    BigInt v = y;
    for (int i = 0; i < 32; i++) { out[i] = (v & BigInt.from(0xFF)).toInt(); v = v >> 8; }
    if (x.isOdd) out[31] |= 0x80;
    return out;
  }

  Uint8List _getPublicKey(Uint8List seed32) {
    final sha512 = pc.SHA512Digest();
    final h = Uint8List(64);
    sha512.update(seed32, 0, 32);
    sha512.doFinal(h, 0);
    h[0] &= 248; h[31] &= 127; h[31] |= 64;
    BigInt a = BigInt.zero;
    for (int i = 0; i < 32; i++) a += BigInt.from(h[i]) << (8 * i);
    return _encodePoint(_scalarMult(_basePoint(), a));
  }

  Uint8List _signMessage(Uint8List message, Uint8List seed32) {
    final sha512 = pc.SHA512Digest();
    final h = Uint8List(64);
    sha512.update(seed32, 0, 32);
    sha512.doFinal(h, 0);
    h[0] &= 248; h[31] &= 127; h[31] |= 64;

    BigInt a = BigInt.zero;
    for (int i = 0; i < 32; i++) a += BigInt.from(h[i]) << (8 * i);
    final pubKey = _encodePoint(_scalarMult(_basePoint(), a));

    final rHash = Uint8List(64);
    final rInput = Uint8List(32 + message.length);
    rInput.setRange(0, 32, h.sublist(32));
    rInput.setRange(32, rInput.length, message);
    sha512.reset();
    sha512.update(rInput, 0, rInput.length);
    sha512.doFinal(rHash, 0);

    BigInt r = BigInt.zero;
    for (int i = 0; i < 64; i++) r += BigInt.from(rHash[i]) << (8 * i);
    final BigInt l = BigInt.parse('7237005577332262213973186563042994240857116359379907606001950938285454250989');
    r = r % l;

    final R = _encodePoint(_scalarMult(_basePoint(), r));
    final kInput = Uint8List(32 + 32 + message.length);
    kInput.setRange(0, 32, R);
    kInput.setRange(32, 64, pubKey);
    kInput.setRange(64, kInput.length, message);
    final kHash = Uint8List(64);
    sha512.reset();
    sha512.update(kInput, 0, kInput.length);
    sha512.doFinal(kHash, 0);

    BigInt k = BigInt.zero;
    for (int i = 0; i < 64; i++) k += BigInt.from(kHash[i]) << (8 * i);
    k = k % l;

    final BigInt S = (r + k * a) % l;
    final sBytes = Uint8List(32);
    BigInt sv = S;
    for (int i = 0; i < 32; i++) { sBytes[i] = (sv & BigInt.from(0xFF)).toInt(); sv = sv >> 8; }
    return Uint8List.fromList([...R, ...sBytes]);
  }

  @override
  void initState() {
    super.initState();
    _fetchPoolReserves();
  }

  @override
  void dispose() {
    _inputController.dispose();
    _outputController.dispose();
    super.dispose();
  }

  Future<void> _fetchPoolReserves() async {
    try {
      final poolUri = Uri.parse(
          "$aptNodeUrl/accounts/0xc7efb4076dbe143cbcd98cfaaa929ecfc8f299203dfff63b95ccb6bfe19850fa/resource/0xc7efb4076dbe143cbcd98cfaaa929ecfc8f299203dfff63b95ccb6bfe19850fa::swap::TokenPairMetadata<$aptCoinType,$meeCoinType>");
      final response = await http.get(poolUri);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body)['data'];
        setState(() {
          _reserveApt = BigInt.parse(data['balance_x']['value'].toString());
          _reserveMee = BigInt.parse(data['balance_y']['value'].toString());
        });
      }
      _recalculateOutput();
    } catch (_) {}
  }

  void _recalculateOutput() {
    final text = _inputController.text.trim().replaceAll(',', '.');
    if (text.isEmpty || double.tryParse(text) == null || double.parse(text) <= 0) {
      _outputController.text = "";
      return;
    }

    final double amountIn = double.parse(text);
    double amountOut = 0.0;

    // Получаем динамическую цену MEGA в APT на текущую секунду
    final double currentMegaPrice = _getMegaCurrentPrice();

    if (_fromToken == "MEGA" && _toToken == "APT") {
      // 1. Продажа MEGA за APT
      amountOut = amountIn * currentMegaPrice;
    } else if (_fromToken == "APT" && _toToken == "MEGA") {
      // 2. Покупка MEGA за APT
      amountOut = amountIn / currentMegaPrice;
    } 
    // --- КРОСС-КУРСЫ MEGA <-> MEE ЧЕРЕЗ APT ---
    else if (_fromToken == "MEGA" && _toToken == "MEE" && _reserveApt > BigInt.zero) {
      // 3. Сначала переводим MEGA в эквивалент APT
      double virtualAptIn = amountIn * currentMegaPrice;
      // Затем этот APT меняем на MEE через формулу пула
      BigInt amountInRaw = BigInt.from((virtualAptIn * pow(10, 8)).round());
      BigInt amountInWithFee = amountInRaw * BigInt.from(997); 
      BigInt numerator = amountInWithFee * _reserveMee;
      BigInt denominator = _reserveApt * BigInt.from(1000) + amountInWithFee;
      amountOut = numerator.toDouble() / denominator.toDouble() / pow(10, 6);
    } else if (_fromToken == "MEE" && _toToken == "MEGA" && _reserveMee > BigInt.zero) {
      // 4. Сначала переводим MEE в эквивалент APT через пул
      BigInt amountInRaw = BigInt.from((amountIn * pow(10, 6)).round());
      BigInt amountInWithFee = amountInRaw * BigInt.from(997);
      BigInt numerator = amountInWithFee * _reserveApt;
      BigInt denominator = _reserveMee * BigInt.from(1000) + amountInWithFee;
      double virtualAptOut = numerator.toDouble() / denominator.toDouble() / pow(10, 8);
      // Затем полученный APT делим на FOMO-цену MEGA
      amountOut = virtualAptOut / currentMegaPrice;
    }
    // --- ОБЫЧНЫЙ ОБМЕН APT <-> MEE ЧЕРЕЗ АММ ПУЛ ---
    else if (_fromToken == "APT" && _toToken == "MEE" && _reserveApt > BigInt.zero) {
      BigInt amountInRaw = BigInt.from((amountIn * pow(10, 8)).round());
      BigInt amountInWithFee = amountInRaw * BigInt.from(997); 
      BigInt numerator = amountInWithFee * _reserveMee;
      BigInt denominator = _reserveApt * BigInt.from(1000) + amountInWithFee;
      amountOut = numerator.toDouble() / denominator.toDouble() / pow(10, 6);
    } else if (_fromToken == "MEE" && _toToken == "APT" && _reserveMee > BigInt.zero) {
      BigInt amountInRaw = BigInt.from((amountIn * pow(10, 6)).round());
      BigInt amountInWithFee = amountInRaw * BigInt.from(997);
      BigInt numerator = amountInWithFee * _reserveApt;
      BigInt denominator = _reserveMee * BigInt.from(1000) + amountInWithFee;
      amountOut = numerator.toDouble() / denominator.toDouble() / pow(10, 8);
    }

    // USDT/USDC — курс будет получен от Hyperion DEX
    // Пока котировка грузится — поле остаётся пустым
    if (needsHyperion(_fromToken, _toToken)) {
      // amountOut остаётся 0 — Hyperion заполнит через _fetchHyperionQuote
    }

    // Вычисляем курс обмена
    if (amountIn > 0 && amountOut > 0) {
      _exchangeRate = amountOut / amountIn;
    } else {
      _exchangeRate = 0;
    }

    setState(() {
      _outputController.text = amountOut.toStringAsFixed(6);
    });

    // Если пара требует Hyperion — загружаем котировку асинхронно
    if (needsHyperion(_fromToken, _toToken) && amountIn > 0) {
      _fetchHyperionQuote(amountIn);
    }
  }

  // Запрос котировки Hyperion с отменой устаревших запросов
  Future<void> _fetchHyperionQuote(double amount) async {
    // Отменяем предыдущий запрос — увеличиваем счётчик
    _hyperionRequestId++;
    final myId = _hyperionRequestId;

    setState(() { _hyperionLoading = true; _hyperionQuote = null; });
    try {
      print('[SWAP] Котировка Hyperion #$myId: $_fromToken -> $_toToken, amount=$amount');
      final quote = await hyperionGetQuote(
        fromSymbol: _fromToken,
        toSymbol: _toToken,
        fromAmount: amount,
        walletAddress: widget.currentAddress,
        privateKeyHex: widget.privateKeyHex,
      );
      // Если пока грузились — пришёл новый запрос, игнорируем
      if (myId != _hyperionRequestId) {
        print('[SWAP] Котировка #$myId отменена (пришёл запрос #$_hyperionRequestId)');
        return;
      }
      print('[SWAP] Котировка #$myId: ${quote.toTokenAmount} $_toToken');
      if (!mounted) return;
      setState(() {
        _hyperionQuote = quote;
        _hyperionLoading = false;
        _outputController.text = quote.toTokenAmount.toStringAsFixed(6);
        if (amount > 0 && quote.toTokenAmount > 0) {
          _exchangeRate = quote.toTokenAmount / amount;
        }
      });
    } catch (e) {
      if (myId != _hyperionRequestId) return; // устаревший запрос
      print('[SWAP] Ошибка котировки Hyperion #$myId: $e');
      if (!mounted) return;
      setState(() { _hyperionLoading = false; _hyperionQuote = null; });
    }
  }

  Future<void> _executeEd25519RESTSwap() async {
    final text = _inputController.text.trim().replaceAll(',', '.');
    if (text.isEmpty || double.tryParse(text) == null || double.parse(text) <= 0) return;
    
    // Проверка лимитов баланса перед отправкой
    final double amountIn = double.parse(text);
    if (amountIn > _getAvailableBalance(_fromToken)) {
      setState(() {
        _status = _SwapStatus.error;
        _errorMsg = "Недостаточно баланса $_fromToken для совершения сделки.";
      });
      return;
    }

    setState(() {
      _status = _SwapStatus.loading;
      _errorMsg = null;
      _txHash = null;
    });

    // USDT/USDC — обмен через Hyperion DEX
    if (needsHyperion(_fromToken, _toToken)) {
      if (_hyperionQuote == null) {
        setState(() {
          _status = _SwapStatus.error;
          _errorMsg = 'Сначала получите котировку — введите сумму и подождите загрузки курса.';
        });
        return;
      }
      try {
        final result = await hyperionExecuteSwap(
          privateKeyHex: widget.privateKeyHex,
          walletAddress: widget.currentAddress,
          fromSymbol: _fromToken,
          toSymbol: _toToken,
          fromAmount: double.parse(_inputController.text.trim().replaceAll(',', '.')),
          minOutRaw: _hyperionQuote!.amountOutRaw,
        );
        if (!mounted) return;
        if (result['success'] == true) {
          setState(() { _status = _SwapStatus.success; _txHash = result['hash']; });
          widget.onSwapSuccess();
        } else {
          setState(() { _status = _SwapStatus.error; _errorMsg = result['error']; });
        }
      } catch (e) {
        if (!mounted) return;
        setState(() { _status = _SwapStatus.error; _errorMsg = e.toString(); });
      }
      return;
    }

    try {
      final accUri = Uri.parse("$aptNodeUrl/accounts/${widget.currentAddress}");
      final accRes = await http.get(accUri);
      if (accRes.statusCode != 200) throw "Не удалось получить данные аккаунта с ноды";
      final accountData = jsonDecode(accRes.body);
      final String sequenceNumber = accountData['sequence_number'];


      ///  

      Map<String, dynamic> payload;

      if (_fromToken == "MEGA" || _toToken == "MEGA") {
        if (_fromToken == "APT" && _toToken == "MEGA") {
          // --- ПОКУПКА MEGA ЗА APT (Участвуем в Airdrop по растущей цене) ---
          final int totalAptWithDecimals = (amountIn * pow(10, 8)).round();

          payload = {
            "type": "entry_function_payload",
            "function": "0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3::mega_coin::harvest_any",
            "type_arguments": [],
            "arguments": [
              totalAptWithDecimals.toString() // Передаем ВСЮ сумму введенных APT
            ]
          };
        } else {
          // --- ОБРАТНЫЙ ОБМЕН (MEGA на APT, если контракт поддерживает) ---
          payload = {
            "type": "entry_function_payload",
            "function": "0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3::mega_coin::swap_mega_direct",
            "type_arguments": [],
            "arguments": [
              (amountIn * pow(10, 8)).round().toString(),
              true
            ]
          };
        }
      } else {
        // ОБЫЧНЫЙ ОБМЕН APT <-> MEE ЧЕРЕЗ АММ РУТЕР (БЕЗ ИЗМЕНЕНИЙ)
        String firstCoin = _fromToken == "APT" ? aptCoinType : meeCoinType;
        String secondCoin = _fromToken == "APT" ? meeCoinType : aptCoinType;
        int inDecimals = _fromToken == "APT" ? 8 : 6;

        payload = {
          "type": "entry_function_payload",
          "function": "0xc7efb4076dbe143cbcd98cfaaa929ecfc8f299203dfff63b95ccb6bfe19850fa::router::swap_exact_input",
          "type_arguments": [firstCoin, secondCoin],
          "arguments": [
            (amountIn * pow(10, inDecimals)).round().toString(),
            "0"
          ]
        };
      }

      final txRequest = {
        "sender": widget.currentAddress,
        "sequence_number": sequenceNumber,
        "max_gas_amount": "200000",
        "gas_unit_price": "100",
        "expiration_timestamp_secs": (DateTime.now().millisecondsSinceEpoch ~/ 1000 + 600).toString(),
        "payload": payload
      };

      final encodeUri = Uri.parse("$aptNodeUrl/transactions/encode_submission");
      final encodeRes = await http.post(
        encodeUri, 
        headers: {"Content-Type": "application/json"},
        body: jsonEncode(txRequest)
      );
      if (encodeRes.statusCode != 200) throw "Ошибка подготовки подписи: ${encodeRes.body}";
      
      final String signingMessageHex = jsonDecode(encodeRes.body);
      final Uint8List signingBytes = Uint8List.fromList(convert.hex.decode(signingMessageHex.substring(2)));

      final Uint8List privateKeyBytes = Uint8List.fromList(convert.hex.decode(widget.privateKeyHex.replaceAll("0x", "")));
      final Uint8List pubBytes = _getPublicKey(privateKeyBytes);
      final Uint8List sigBytes = _signMessage(signingBytes, privateKeyBytes);

      final broadcastPayload = {
        "sender": widget.currentAddress,
        "sequence_number": sequenceNumber,
        "max_gas_amount": "200000",
        "gas_unit_price": "100",
        "expiration_timestamp_secs": txRequest["expiration_timestamp_secs"],
        "payload": payload,
        "signature": {
          "type": "ed25519_signature",
          "public_key": "0x${convert.hex.encode(pubBytes)}",
          "signature": "0x${convert.hex.encode(sigBytes)}"
        }
      };

      final submitUri = Uri.parse("$aptNodeUrl/transactions");
      final submitRes = await http.post(
        submitUri, 
        headers: {"Content-Type": "application/json"},
        body: jsonEncode(broadcastPayload)
      );

      final responseData = jsonDecode(submitRes.body);
      if (submitRes.statusCode == 202 || submitRes.statusCode == 200) {
        setState(() {
          _status = _SwapStatus.success;
          _txHash = responseData['hash'];
        });
        widget.onSwapSuccess(); 
      } else {
        throw responseData['message'] ?? "Нода отклонила транзакцию пакета";
      }
    } catch (e) {
      setState(() {
        _status = _SwapStatus.error;
        _errorMsg = e.toString();
      });
    }
  }

  // Поддерживаемые пары для обмена
  bool _isPairSupported(String from, String to) {
    if (from == to) return false;
    // Нормализуем пару — порядок не важен
    final pair = {from, to};
    const supported = [
      {'APT', 'MEE'},
      {'APT', 'MEGA'},
      {'MEE', 'MEGA'},
      {'APT', 'USDC'},
      {'APT', 'USDT'},
    ];
    return supported.any((p) => p.containsAll(pair));
  }

  double _getAvailableBalance(String token) {
    if (token == "APT")  return widget.aptBalance;
    if (token == "MEE")  return widget.meeBalance;
    if (token == "MEGA") return widget.megaBalance;
    if (token == "USDT") return widget.usdtBalance;
    if (token == "USDC") return widget.usdcBalance;
    return 0.0;
  }

  @override
  Widget build(BuildContext context) {
    // Выбираем разметку в зависимости от текущего стейта транзакции (как в airdrop.dart)
    Widget currentBody;
    switch (_status) {
      case _SwapStatus.loading:
        currentBody = _buildLoadingState();
        break;
      case _SwapStatus.success:
        currentBody = _buildSuccessState();
        break;
      case _SwapStatus.error:
        currentBody = _buildErrorState();
        break;
      case _SwapStatus.idle:
        currentBody = _buildIdleState();
        break;
    }

    return Scaffold(
      backgroundColor: const Color(0xFF131929),
      appBar: AppBar(
        title: const Text("Обмен монет", style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
        backgroundColor: const Color(0xFF1A2238),
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white70),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: currentBody,
        ),
      ),
    );
  }

  // --- СТЕЙТ 1: Форма ввода и настройки обмена ---
  Widget _buildIdleState() {
    // Проверяем, выбрана ли монета MEGA для продажи
    final bool isSellingMega = (_fromToken == "MEGA");
    final int nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final bool isBeforeListing = nowSec < _listingTimeSec;
    final bool isMegaSellBlocked = isSellingMega && isBeforeListing;
    final bool isPairSupported = _isPairSupported(_fromToken, _toToken);
    final bool isSwapDisabled = isMegaSellBlocked || !isPairSupported;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          const SizedBox(height: 8),
          _buildCoinInputCard("Вы отдаете", _fromToken, _inputController, (val) {
            setState(() => _fromToken = val!);
            _recalculateOutput();
          }),
          const SizedBox(height: 12),
          // Кнопка swap + курс обмена
          Row(
            children: [
              Expanded(
                child: _exchangeRate > 0 || _hyperionLoading
                    ? Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.03),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (_hyperionLoading)
                              const Row(children: [
                                SizedBox(width: 10, height: 10,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 1.5, color: Color(0xFF00D4AA))),
                                SizedBox(width: 8),
                                Text('Получаю курс Hyperion DEX...',
                                    style: TextStyle(color: Colors.white54, fontSize: 11)),
                              ])
                            else ...[
                              Text('1 $_fromToken = ${_exchangeRate.toStringAsFixed(6)} $_toToken',
                                  style: const TextStyle(color: Colors.white70,
                                      fontSize: 12, fontWeight: FontWeight.w500)),
                              const SizedBox(height: 2),
                              if (needsHyperion(_fromToken, _toToken)) ...[
                                Row(children: [
                                  const Text('⚡ Powered by ',
                                      style: TextStyle(color: Colors.white38, fontSize: 10)),
                                  const Text('Hyperion DEX',
                                      style: TextStyle(color: Color(0xFF00D4AA),
                                          fontSize: 10, fontWeight: FontWeight.bold)),
                                  if (_hyperionQuote != null && _hyperionQuote!.priceImpact > 0) ...[
                                    const Text('  •  Impact: ',
                                        style: TextStyle(color: Colors.white24, fontSize: 10)),
                                    Text('${_hyperionQuote!.priceImpact.toStringAsFixed(2)}%',
                                        style: TextStyle(
                                            color: (_hyperionQuote!.priceImpact > 3)
                                                ? Colors.orange : Colors.white38,
                                            fontSize: 10)),
                                  ],
                                ]),
                              ] else if (_fromToken != 'MEGA' && _toToken != 'MEGA')
                                const Text('Комиссия пула: 0.3%',
                                    style: TextStyle(color: Colors.white24, fontSize: 10))
                              else
                                Text('Цена MEGA: ${_getMegaCurrentPrice().toStringAsFixed(6)} APT',
                                    style: const TextStyle(color: Colors.orange, fontSize: 10)),
                            ],
                          ],
                        ),
                      )
                    : const SizedBox(),
              ),
              IconButton(
                icon: const Icon(Icons.swap_vert, color: Color(0xFF00D4AA), size: 32),
                onPressed: () {
                  final temp = _fromToken;
                  setState(() { _fromToken = _toToken; _toToken = temp; });
                  _recalculateOutput();
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          _buildCoinInputCard(
            "Вы получаете: ", 
            _toToken, 
            _outputController, 
            (val) {
              setState(() => _toToken = val!);
              _recalculateOutput();
            }, 
            enabled: true // Поля ввода всегда активны, чтобы расчеты работали!
          ),
          const SizedBox(height: 16),

          // Предупреждение о недоступной паре
          if (!isPairSupported)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(0.08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.orange.withOpacity(0.3)),
              ),
              child: Row(children: [
                const Icon(Icons.info_outline, color: Colors.orange, size: 16),
                const SizedBox(width: 8),
                Expanded(child: Text(
                  'Пара $_fromToken → $_toToken недоступна.\nДоступно: APT↔MEE, APT↔MEGA, MEE↔MEGA, APT↔USDC, APT↔USDT',
                  style: const TextStyle(color: Colors.orange, fontSize: 11, height: 1.4),
                )),
              ]),
            ),

          const SizedBox(height: 16),

          SizedBox(
            width: double.infinity,
            height: 50,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: isSwapDisabled
                    ? Colors.grey.withOpacity(0.3)
                    : const Color(0xFF00D4AA),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: () {
                if (!isPairSupported) {
                  showDialog(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      backgroundColor: const Color(0xFF1A2238),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      title: const Text('Пара недоступна',
                          style: TextStyle(color: Colors.white, fontSize: 16),
                          textAlign: TextAlign.center),
                      content: Text(
                        'Обмен $_fromToken → $_toToken пока не поддерживается.\n\nДоступные пары:\nAPT ↔ MEE\nAPT ↔ MEGA\nMEE ↔ MEGA\nAPT ↔ USDC\nAPT ↔ USDT',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.5),
                      ),
                      actionsAlignment: MainAxisAlignment.center,
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('Ок',
                              style: TextStyle(color: Color(0xFF00D4AA),
                                  fontSize: 16, fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ),
                  );
                } else if (isMegaSellBlocked) {
                  showDialog(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      backgroundColor: const Color(0xFF1A2238),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      content: const Text(
                        "Будет доступно 19.11.2026",
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500),
                      ),
                      actionsAlignment: MainAxisAlignment.center,
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text("Ок",
                              style: TextStyle(color: Color(0xFF00D4AA),
                                  fontSize: 16, fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ),
                  );
                } else {
                  _executeEd25519RESTSwap();
                }
              },
              child: Text(
                !isPairSupported ? 'НЕДОСТУПНО' : 'ОБМЕН',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                  color: isSwapDisabled ? Colors.white38 : Colors.black,
                ),
              ),
            ),
          )
        ],
      ),
    );
  }

  // --- СТЕЙТ 2: Крутилка загрузки транзакции ---
  Widget _buildLoadingState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 44, height: 44,
            child: CircularProgressIndicator(strokeWidth: 3, color: Color(0xFF00D4AA)),
          ),
          const SizedBox(height: 24),
          const Text(
            "Сборка и подпись транзакции...",
            style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            "Делаем обмен.",
            style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 12),
          ),
        ],
      ),
    );
  }

  // --- СТЕЙТ 3: Окно Успеха с деталями хэша ---
  Widget _buildSuccessState() {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.check_circle_rounded, color: Color(0xFF00D4AA), size: 64),
          const SizedBox(height: 20),
          const Text(
            "Обмен успешно завершен!",
            style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 10),
          Text(
            "Транзакция успешно обработана блокчейном.",
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 24),
          
          if (_txHash != null)
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF0A0E1A),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withOpacity(0.05)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("Хэш транзакции (TX HASH):", style: TextStyle(color: Colors.white38, fontSize: 11)),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _txHash!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontSize: 12, fontFamily: 'monospace'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () {
                          Clipboard.setData(ClipboardData(text: _txHash!));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text("Хэш скопирован в буфер обмена")),
                          );
                        },
                        child: const Icon(Icons.copy, color: Color(0xFF00D4AA), size: 16),
                      )
                    ],
                  ),
                ],
              ),
            ),
            
          const SizedBox(height: 40),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: OutlinedButton(
              onPressed: () => Navigator.pop(context),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: Colors.white.withOpacity(0.15)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text("Закрыть", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }

  // --- СТЕЙТ 4: Окно Ошибки с кнопкой «Повторить» ---
  Widget _buildErrorState() {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 64),
          const SizedBox(height: 20),
          const Text(
            "Ошибка проведения Свопа",
            style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.redAccent.withOpacity(0.05),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.redAccent.withOpacity(0.15)),
            ),
            child: Text(
              _errorMsg ?? "Неизвестная ошибка сети при симуляции транзакции.",
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.redAccent, fontSize: 13, height: 1.4),
            ),
          ),
          const SizedBox(height: 40),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: Colors.white.withOpacity(0.15)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text("Закрыть", style: TextStyle(color: Colors.white54)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: () {
                    setState(() {
                      _status = _SwapStatus.idle;
                      _errorMsg = null;
                    });
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.redAccent,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text("Повторить", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _tokenIcon(String symbol, {double size = 28}) {
    final path = _tokenIcons[symbol];
    if (path != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(size / 3),
        child: Image.asset(path, width: size, height: size, fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _tokenFallback(symbol, size)),
      );
    }
    return _tokenFallback(symbol, size);
  }

  Widget _tokenFallback(String symbol, double size) {
    return Container(
      width: size, height: size,
      decoration: BoxDecoration(
        color: const Color(0xFF00D4AA).withOpacity(0.15),
        borderRadius: BorderRadius.circular(size / 3),
      ),
      child: Center(child: Text(symbol[0],
          style: TextStyle(color: const Color(0xFF00D4AA),
              fontWeight: FontWeight.bold, fontSize: size * 0.4))),
    );
  }

  Widget _buildCoinInputCard(String label, String tokenValue,
      TextEditingController ctrl, ValueChanged<String?> onChanged,
      {bool enabled = true}) {
    final double maxBalance = _getAvailableBalance(tokenValue);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A2238),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: const TextStyle(color: Colors.white54, fontSize: 13)),
              GestureDetector(
                /*
                onTap: () {
                  if (enabled) {
                    final val = maxBalance.toStringAsFixed(6)
                        .replaceAll(RegExp(r'0+$'), '')
                        .replaceAll(RegExp(r'\.$'), '');
                    ctrl.text = val;
                    _recalculateOutput();
                    // Для Hyperion пар сразу запрашиваем котировку без дебаунса
                    if (needsHyperion(_fromToken, _toToken) && maxBalance > 0) {
                      _fetchHyperionQuote(maxBalance);
                    }
                  }
                },*/
                
                onTap: () {
                  if (enabled) {
                    // Сдвигаем запятую на 2 знака, отбрасываем дробь, и двигаем обратно
                    final truncated = (maxBalance * 100).truncateToDouble() / 100;
                    
                    // Переводим в строку без лишних нулей (например, 0.45)
                    final val = truncated.toStringAsFixed(2)
                        .replaceAll(RegExp(r'0+$'), '')
                        .replaceAll(RegExp(r'\.$'), '');

                    ctrl.text = val;
                    _recalculateOutput();
                    
                    if (needsHyperion(_fromToken, _toToken) && truncated > 0) {
                      _fetchHyperionQuote(truncated);
                    }
                  }
                },


                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.02),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'Баланс: ${maxBalance.toStringAsFixed(4)}',
                    style: const TextStyle(color: Color(0xFF00D4AA),
                        fontSize: 13, fontWeight: FontWeight.w500),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              // Dropdown с иконкой
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: DropdownButton<String>(
                  value: tokenValue,
                  dropdownColor: const Color(0xFF1A2238),
                  icon: const Icon(Icons.arrow_drop_down, color: Colors.white54, size: 20),
                  underline: const SizedBox(),
                  isDense: true,
                  items: ['APT', 'MEE', 'MEGA', 'USDT', 'USDC'].map((t) => DropdownMenuItem(
                    value: t,
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      _tokenIcon(t, size: 24),
                      const SizedBox(width: 8),
                      Text(t, style: const TextStyle(
                          color: Colors.white, fontSize: 16,
                          fontWeight: FontWeight.bold)),
                    ]),
                  )).toList(),
                  onChanged: onChanged,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: ctrl,
                  enabled: enabled,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  textAlign: TextAlign.end,
                  style: const TextStyle(fontSize: 22,
                      color: Color(0xFF00D4AA), fontWeight: FontWeight.bold),
                  onChanged: (_) => _recalculateOutput(),
                  decoration: const InputDecoration(
                    hintText: '0.0',
                    hintStyle: TextStyle(color: Colors.white12),
                    border: InputBorder.none,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
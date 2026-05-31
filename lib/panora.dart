import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:convert/convert.dart' as convert;
import 'package:pointycastle/export.dart' as pc;

// ── Hyperion DEX константы ────────────────────────────────────
const String _aptNode         = 'https://fullnode.mainnet.aptoslabs.com/v1';
const String _hyperionRouter  = '0x8b4a2c4bb53857c718a04c020b98f8c2e1f99a68b0f57389a8bf5434cd22e05c';
const String _hyperionPool    = '0x925660b8618394809f89f8002e2926600c775221f43bf1919782b297a79400d8'; // APT/USDC
const String _hyperionPoolUSDT = '0x18269b1090d668fbbc01902fa6a5ac6e75565d61860ddae636ac89741c883cbc'; // APT/USDT
const String _aptMetaHex = '000000000000000000000000000000000000000000000000000000000000000a';
const String _usdcMeta        = '0xbae207659db88bea0cbead6da0ed00aac12edcdda169e591cd41c94180b46f3b';
const String _usdtMeta        = '0x357b0b74bc833e95a115ad22604854d6b0fca151cecd94111770e5d6ffc9dc2b';

// Токены которые поддерживает Hyperion (через APT пул)
const Map<String, String> hyperionTokenMeta = {
  'APT':  _aptMetaHex,
  'USDC': _usdcMeta,
  'USDT': _usdtMeta,
};

const Map<String, int> hyperionTokenDecimals = {
  'APT':  8,
  'USDC': 6,
  'USDT': 6,
};

// ── Ed25519 ───────────────────────────────────────────────────
final BigInt _q = (BigInt.from(2).pow(255)) - BigInt.from(19);
final BigInt _d = (BigInt.parse('-121665') * BigInt.parse('121666').modInverse(_q)) % _q;
final BigInt _I = BigInt.from(2).modPow((_q - BigInt.one) ~/ BigInt.from(4), _q);

List<BigInt> _rx(BigInt y) {
  final y2=y*y%_q; final x2=((y2-BigInt.one)*(_d*y2+BigInt.one).modInverse(_q))%_q;
  if(x2==BigInt.zero) return [BigInt.zero,BigInt.zero];
  BigInt x=x2.modPow((_q+BigInt.from(3))~/BigInt.from(8),_q);
  if((x*x-x2)%_q!=BigInt.zero) x=x*_I%_q;
  if(x.isOdd) x=_q-x; return [x,y];
}
List<BigInt> _bp(){final y=BigInt.from(4)*BigInt.from(5).modInverse(_q)%_q;return [_rx(y)[0],y,BigInt.one,_rx(y)[0]*y%_q];}
List<BigInt> _ea(List<BigInt> P,List<BigInt> Q){final a=(P[1]-P[0])*(Q[1]-Q[0])%_q;final b=(P[1]+P[0])*(Q[1]+Q[0])%_q;final c=BigInt.from(2)*P[3]*Q[3]%_q*_d%_q;final dd=BigInt.from(2)*P[2]*Q[2]%_q;return [(b-a)*(dd-c)%_q,(dd+c)*(b+a)%_q,(dd-c)*(dd+c)%_q,(b-a)*(b+a)%_q];}
List<BigInt> _sm(List<BigInt> P,BigInt n){if(n==BigInt.zero)return [BigInt.zero,BigInt.one,BigInt.one,BigInt.zero];var Q=_sm(P,n~/BigInt.two);Q=_ea(Q,Q);if(n.isOdd)Q=_ea(Q,P);return Q;}
Uint8List _ep(List<BigInt> P){final z=P[2].modInverse(_q);final x=P[0]*z%_q;final y=P[1]*z%_q;final o=Uint8List(32);BigInt v=y;for(int i=0;i<32;i++){o[i]=(v&BigInt.from(0xFF)).toInt();v=v>>8;}if(x.isOdd)o[31]|=0x80;return o;}

Uint8List hyperionGetPublicKey(Uint8List seed) {
  final s=pc.SHA512Digest();final h=Uint8List(64);
  s.update(seed,0,32);s.doFinal(h,0);
  h[0]&=248;h[31]&=127;h[31]|=64;
  BigInt a=BigInt.zero;for(int i=0;i<32;i++)a+=BigInt.from(h[i])<<(8*i);
  return _ep(_sm(_bp(),a));
}

Uint8List hyperionSign(Uint8List msg,Uint8List seed) {
  final s=pc.SHA512Digest();final h=Uint8List(64);
  s.update(seed,0,32);s.doFinal(h,0);
  h[0]&=248;h[31]&=127;h[31]|=64;
  BigInt a=BigInt.zero;for(int i=0;i<32;i++)a+=BigInt.from(h[i])<<(8*i);
  final pub=_ep(_sm(_bp(),a));
  final ri=Uint8List(32+msg.length);ri.setRange(0,32,h.sublist(32));ri.setRange(32,ri.length,msg);
  final rh=Uint8List(64);s.reset();s.update(ri,0,ri.length);s.doFinal(rh,0);
  BigInt r=BigInt.zero;for(int i=0;i<64;i++)r+=BigInt.from(rh[i])<<(8*i);
  final BigInt l=BigInt.parse('7237005577332262213973186563042994240857116359379907606001950938285454250989');
  r=r%l;final R=_ep(_sm(_bp(),r));
  final ki=Uint8List(64+msg.length);ki.setRange(0,32,R);ki.setRange(32,64,pub);ki.setRange(64,ki.length,msg);
  final kh=Uint8List(64);s.reset();s.update(ki,0,ki.length);s.doFinal(kh,0);
  BigInt k=BigInt.zero;for(int i=0;i<64;i++)k+=BigInt.from(kh[i])<<(8*i);
  k=k%l;final S=(r+k*a)%l;final sb=Uint8List(32);BigInt sv=S;
  for(int i=0;i<32;i++){sb[i]=(sv&BigInt.from(0xFF)).toInt();sv=sv>>8;}
  return Uint8List.fromList([...R,...sb]);
}

// ── Результат котировки ───────────────────────────────────────
class HyperionQuote {
  final double toTokenAmount;
  final double priceImpact;
  final int amountOutRaw;

  HyperionQuote({
    required this.toTokenAmount,
    required this.priceImpact,
    required this.amountOutRaw,
  });
}

// ── Получение котировки через симуляцию ───────────────────────
Future<HyperionQuote> hyperionGetQuote({
  required String fromSymbol,
  required String toSymbol,
  required double fromAmount,
  required String walletAddress,
  required String privateKeyHex,
}) async {
  final fromMeta = hyperionTokenMeta[fromSymbol];
  final toMeta   = hyperionTokenMeta[toSymbol];
  final fromDec  = hyperionTokenDecimals[fromSymbol] ?? 8;
  final toDec    = hyperionTokenDecimals[toSymbol]   ?? 6;

  if (fromMeta == null || toMeta == null) {
    throw Exception('Неизвестный токен: $fromSymbol или $toSymbol');
  }

  final amountRaw = (fromAmount * _pow10(fromDec)).round();

  // Строим payload для simulate
  final payload = _buildHyperionPayload(
    fromMeta:   fromMeta,
    toMeta:     toMeta,
    fromSymbol: fromSymbol,
    toSymbol:   toSymbol,
    amountIn:   amountRaw,
    minOut:     0,
    recipient:  walletAddress,
  );

  // Получаем account info для sequence_number
  final accResp = await http.get(
    Uri.parse('$_aptNode/accounts/$walletAddress'),
    headers: {'Accept': 'application/json'},
  ).timeout(const Duration(seconds: 10));

  if (accResp.statusCode != 200) throw Exception('Не удалось получить аккаунт');
  final seqNum = int.parse(jsonDecode(accResp.body)['sequence_number'].toString());
  final exp = (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 600;

  // simulate
  // Реальный pubkey для симуляции (нулевая подпись, но реальный ключ)
  final priv = Uint8List.fromList(
      convert.hex.decode(privateKeyHex.replaceFirst('0x', '')));
  final pubKey = hyperionGetPublicKey(priv);
  final pubKeyHex = '0x${convert.hex.encode(pubKey)}';

  final simBody = jsonEncode({
    'sender': walletAddress,
    'sequence_number': seqNum.toString(),
    'max_gas_amount': '200000',
    'gas_unit_price': '100',
    'expiration_timestamp_secs': exp.toString(),
    'payload': payload,
    'signature': {
      'type': 'ed25519_signature',
      'public_key': pubKeyHex,
      'signature': '0x${'00' * 64}', // нулевая подпись — достаточно для simulate
    },
  });

  final simResp = await http.post(
    Uri.parse('$_aptNode/transactions/simulate'),
    headers: {'Content-Type': 'application/json', 'Accept': 'application/json'},
    body: simBody,
  ).timeout(const Duration(seconds: 15));

  print('[HYPERION] Simulate status: ${simResp.statusCode}');

  if (simResp.statusCode != 200) {
    throw Exception('Simulate error: ${simResp.body}');
  }

  final simData = jsonDecode(simResp.body);
  final sim = simData is List ? simData[0] : simData;

  print('[HYPERION] success: ${sim['success']}');
  print('[HYPERION] vm_status: ${sim['vm_status']}');

  if (sim['success'] != true) {
    throw Exception('Симуляция не прошла: ${sim['vm_status']}');
  }

  // Ищем amount_out в событиях
  int amountOut = 0;
  final events = sim['events'] as List? ?? [];
  for (final ev in events) {
    final type = ev['type']?.toString() ?? '';
    final data = ev['data'] as Map? ?? {};
    print('[HYPERION] event: $type data: $data');
    if ((type.contains('SwapEvent') || type.contains('Swapped')) &&
        data.containsKey('amount_out')) {
      amountOut = int.tryParse(data['amount_out'].toString()) ?? 0;
      break;
    }
    // Также ищем в changes
    if (data.containsKey('coin') || data.containsKey('value')) {
      final val = data['value'] ?? data['coin']?['value'];
      if (val != null) {
        final parsed = int.tryParse(val.toString()) ?? 0;
        if (parsed > 0) amountOut = parsed;
      }
    }
  }

  print('[HYPERION] amountOut raw: $amountOut');

  final toAmount = amountOut / _pow10(toDec);
  final impact = amountOut > 0
      ? ((fromAmount - toAmount) / fromAmount * 100).abs()
      : 0.0;

  return HyperionQuote(
    toTokenAmount: toAmount,
    priceImpact: impact,
    amountOutRaw: amountOut,
  );
}

// ── Выполнение свопа через Hyperion ──────────────────────────
Future<Map<String, dynamic>> hyperionExecuteSwap({
  required String privateKeyHex,
  required String walletAddress,
  required String fromSymbol,
  required String toSymbol,
  required double fromAmount,
  required int minOutRaw,
  double slippagePct = 1.0,
}) async {
  final fromMeta = hyperionTokenMeta[fromSymbol]!;
  final toMeta   = hyperionTokenMeta[toSymbol]!;
  final fromDec  = hyperionTokenDecimals[fromSymbol] ?? 8;
  final amountRaw = (fromAmount * _pow10(fromDec)).round();
  final minOut = (minOutRaw * (1 - slippagePct / 100)).round();

  final priv   = Uint8List.fromList(convert.hex.decode(privateKeyHex.replaceFirst('0x', '')));
  final pubKey = hyperionGetPublicKey(priv);

  // Получаем sequence_number и chain_id
  final results = await Future.wait([
    http.get(Uri.parse('$_aptNode/accounts/$walletAddress'), headers: {'Accept': 'application/json'}).timeout(const Duration(seconds: 15)),
    http.get(Uri.parse(_aptNode), headers: {'Accept': 'application/json'}).timeout(const Duration(seconds: 10)),
  ]);

  final accR = results[0] as http.Response;
  final ledR = results[1] as http.Response;
  if (accR.statusCode != 200) throw Exception('HTTP ${accR.statusCode}');

  final seqNum  = int.parse(jsonDecode(accR.body)['sequence_number'].toString());
  final chainId = int.parse(jsonDecode(ledR.body)['chain_id'].toString());
  final exp     = (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 600;

  final payload = _buildHyperionPayload(
    fromMeta:   fromMeta,
    toMeta:     toMeta,
    fromSymbol: fromSymbol,
    toSymbol:   toSymbol,
    amountIn:   amountRaw,
    minOut:     minOut,
    recipient:  walletAddress,
  );

  // encode_submission
  final txRequest = {
    'sender': walletAddress,
    'sequence_number': seqNum.toString(),
    'max_gas_amount': '200000',
    'gas_unit_price': '100',
    'expiration_timestamp_secs': exp.toString(),
    'payload': payload,
  };

  final encodeResp = await http.post(
    Uri.parse('$_aptNode/transactions/encode_submission'),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode(txRequest),
  ).timeout(const Duration(seconds: 15));

  if (encodeResp.statusCode != 200) {
    throw Exception('encode_submission error: ${encodeResp.body}');
  }

  final signingHex   = jsonDecode(encodeResp.body) as String;
  final signingBytes = Uint8List.fromList(
      convert.hex.decode(signingHex.replaceFirst('0x', '')));
  final signature    = hyperionSign(signingBytes, priv);

  final broadcastBody = jsonEncode({
    ...txRequest,
    'signature': {
      'type':       'ed25519_signature',
      'public_key': '0x${convert.hex.encode(pubKey)}',
      'signature':  '0x${convert.hex.encode(signature)}',
    },
  });

  final submitResp = await http.post(
    Uri.parse('$_aptNode/transactions'),
    headers: {'Content-Type': 'application/json', 'Accept': 'application/json'},
    body: broadcastBody,
  ).timeout(const Duration(seconds: 20));

  final submitData = jsonDecode(submitResp.body);
  print('[HYPERION] Submit status: ${submitResp.statusCode}');
  print('[HYPERION] Submit response: ${submitResp.body.substring(0, submitResp.body.length.clamp(0, 200))}');

  if (submitResp.statusCode == 202) {
    final hash = submitData['hash']?.toString() ?? '';
    for (int i = 0; i < 10; i++) {
      await Future.delayed(const Duration(seconds: 1));
      try {
        final check = await http.get(
          Uri.parse('$_aptNode/transactions/by_hash/$hash'),
          headers: {'Accept': 'application/json'},
        ).timeout(const Duration(seconds: 5));
        if (check.statusCode == 200) {
          final tx = jsonDecode(check.body);
          if (tx['success'] == true) return {'success': true, 'hash': hash};
          final vm = tx['vm_status']?.toString() ?? '';
          if (vm.isNotEmpty && vm != 'pending') return {'success': false, 'error': 'VM: $vm'};
        }
      } catch (_) {}
    }
    return {'success': true, 'hash': hash};
  }

  return {'success': false, 'error': submitData['message']?.toString() ?? 'Ошибка'};
}

// ── Билдер payload ────────────────────────────────────────────
Map<String, dynamic> _buildHyperionPayload({
  required String fromMeta,
  required String toMeta,
  required String fromSymbol,
  required String toSymbol,
  required int amountIn,
  required int minOut,
  required String recipient,
}) {
  // Выбираем пул по паре токенов
  final bool isUsdt = fromSymbol == 'USDT' || toSymbol == 'USDT';
  final poolAddr = isUsdt ? _hyperionPoolUSDT : _hyperionPool;

  // APT meta — специальный адрес 0x000...a (64 символа)
  String normMeta(String m) {
    if (m == _aptMetaHex) {
      return '0x000000000000000000000000000000000000000000000000000000000000000a';
    }
    // FA токены — уже в правильном формате
    if (m.startsWith('0x')) return m;
    return '0x${m.padLeft(64, '0')}';
  }

  final inMeta  = normMeta(fromMeta);
  final outMeta = normMeta(toMeta);

  print('[HYPERION] payload pool=$poolAddr');
  print('[HYPERION] payload inMeta=$inMeta');
  print('[HYPERION] payload outMeta=$outMeta');
  print('[HYPERION] payload amountIn=$amountIn minOut=$minOut');

  return {
    'type': 'entry_function_payload',
    'function': '$_hyperionRouter::router_v3::swap_batch_coin_entry',
    'type_arguments': ['0x1::aptos_coin::AptosCoin'],
    'arguments': [
      [poolAddr],            // vector<address>
      inMeta,               // address in_meta
      outMeta,              // address out_meta
      amountIn.toString(),  // u64 amount_in
      minOut.toString(),    // u64 min_out
      recipient,            // address recipient
    ],
  };
}

// ── Хелперы ───────────────────────────────────────────────────
double _pow10(int exp) {
  double r = 1.0;
  for (int i = 0; i < exp; i++) r *= 10;
  return r;
}

bool needsHyperion(String fromToken, String toToken) {
  const supported = {'USDT', 'USDC'};
  return supported.contains(fromToken) || supported.contains(toToken);
}

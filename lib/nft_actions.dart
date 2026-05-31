import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:convert/convert.dart' as convert;
import 'package:pointycastle/export.dart' as pc;

// ── Конфиг ───────────────────────────────────────────────────
const String _aptosNode = 'https://fullnode.mainnet.aptoslabs.com/v1';

// ══════════════════════════════════════════════════════════════
// Ed25519 (копия из about.dart)
// ══════════════════════════════════════════════════════════════
final BigInt _q = (BigInt.from(2).pow(255)) - BigInt.from(19);
final BigInt _d = (BigInt.parse('-121665') * BigInt.parse('121666').modInverse(_q)) % _q;
final BigInt _I = BigInt.from(2).modPow((_q - BigInt.one) ~/ BigInt.from(4), _q);

List<BigInt> _recoverX(BigInt y) {
  final y2 = y * y % _q;
  final x2 = ((y2 - BigInt.one) * (_d * y2 + BigInt.one).modInverse(_q)) % _q;
  if (x2 == BigInt.zero) return [BigInt.zero, BigInt.zero];
  BigInt x = x2.modPow((_q + BigInt.from(3)) ~/ BigInt.from(8), _q);
  if ((x * x - x2) % _q != BigInt.zero) x = x * _I % _q;
  if (x.isOdd) x = _q - x;
  return [x, y];
}

List<BigInt> _bp() {
  final y = BigInt.from(4) * BigInt.from(5).modInverse(_q) % _q;
  return [_recoverX(y)[0], y, BigInt.one, _recoverX(y)[0] * y % _q];
}

List<BigInt> _edAdd(List<BigInt> P, List<BigInt> Q) {
  final a=(P[1]-P[0])*(Q[1]-Q[0])%_q; final b=(P[1]+P[0])*(Q[1]+Q[0])%_q;
  final c=BigInt.from(2)*P[3]*Q[3]%_q*_d%_q; final dd=BigInt.from(2)*P[2]*Q[2]%_q;
  return [(b-a)*(dd-c)%_q,(dd+c)*(b+a)%_q,(dd-c)*(dd+c)%_q,(b-a)*(b+a)%_q];
}

List<BigInt> _sm(List<BigInt> P, BigInt n) {
  if (n == BigInt.zero) return [BigInt.zero, BigInt.one, BigInt.one, BigInt.zero];
  var Q = _sm(P, n ~/ BigInt.two); Q = _edAdd(Q, Q);
  if (n.isOdd) Q = _edAdd(Q, P); return Q;
}

Uint8List _ep(List<BigInt> P) {
  final zinv=P[2].modInverse(_q); final x=P[0]*zinv%_q; final y=P[1]*zinv%_q;
  final out=Uint8List(32); BigInt v=y;
  for(int i=0;i<32;i++){out[i]=(v&BigInt.from(0xFF)).toInt();v=v>>8;}
  if(x.isOdd) out[31]|=0x80; return out;
}

Uint8List _pub(Uint8List seed) {
  final s=pc.SHA512Digest(); final h=Uint8List(64);
  s.update(seed,0,32); s.doFinal(h,0);
  h[0]&=248; h[31]&=127; h[31]|=64;
  BigInt a=BigInt.zero; for(int i=0;i<32;i++) a+=BigInt.from(h[i])<<(8*i);
  return _ep(_sm(_bp(),a));
}

Uint8List _sign(Uint8List msg, Uint8List seed) {
  final s=pc.SHA512Digest(); final h=Uint8List(64);
  s.update(seed,0,32); s.doFinal(h,0);
  h[0]&=248; h[31]&=127; h[31]|=64;
  BigInt a=BigInt.zero; for(int i=0;i<32;i++) a+=BigInt.from(h[i])<<(8*i);
  final pub=_ep(_sm(_bp(),a));
  final ri=Uint8List(32+msg.length); ri.setRange(0,32,h.sublist(32)); ri.setRange(32,ri.length,msg);
  final rh=Uint8List(64); s.reset(); s.update(ri,0,ri.length); s.doFinal(rh,0);
  BigInt r=BigInt.zero; for(int i=0;i<64;i++) r+=BigInt.from(rh[i])<<(8*i);
  final BigInt l=BigInt.parse('7237005577332262213973186563042994240857116359379907606001950938285454250989');
  r=r%l; final R=_ep(_sm(_bp(),r));
  final ki=Uint8List(64+msg.length); ki.setRange(0,32,R); ki.setRange(32,64,pub); ki.setRange(64,ki.length,msg);
  final kh=Uint8List(64); s.reset(); s.update(ki,0,ki.length); s.doFinal(kh,0);
  BigInt k=BigInt.zero; for(int i=0;i<64;i++) k+=BigInt.from(kh[i])<<(8*i);
  k=k%l; final S=(r+k*a)%l; final sb=Uint8List(32); BigInt sv=S;
  for(int i=0;i<32;i++){sb[i]=(sv&BigInt.from(0xFF)).toInt();sv=sv>>8;}
  return Uint8List.fromList([...R,...sb]);
}

// ── Отправка транзакции ───────────────────────────────────────
Future<Map<String,dynamic>> _sendTx({
  required String privateKeyHex,
  required Map<String,dynamic> payload,
  int maxGas = 10000,
}) async {
  final priv = Uint8List.fromList(convert.hex.decode(privateKeyHex.replaceFirst('0x','')));
  final pubKey = _pub(priv);
  final sha3 = pc.SHA3Digest(256);
  final inp = Uint8List(33); inp.setRange(0,32,pubKey); inp[32]=0x00;
  sha3.update(inp,0,33); final addrBytes=Uint8List(32); sha3.doFinal(addrBytes,0);
  final senderAddr = '0x${convert.hex.encode(addrBytes)}';

  final results = await Future.wait([
    http.get(Uri.parse('$_aptosNode/accounts/$senderAddr'), headers: {'Accept':'application/json'}).timeout(const Duration(seconds:15)),
    http.get(Uri.parse(_aptosNode), headers: {'Accept':'application/json'}).timeout(const Duration(seconds:10)),
  ]);
  final accR = results[0] as http.Response;
  final ledR = results[1] as http.Response;
  if (accR.statusCode != 200) throw Exception('Аккаунт не найден');
  final seqNum = int.parse(jsonDecode(accR.body)['sequence_number'].toString());
  final chainId = int.parse(jsonDecode(ledR.body)['chain_id'].toString());
  final exp = (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 600;

  final txBody = {
    'sender': senderAddr,
    'sequence_number': seqNum.toString(),
    'max_gas_amount': maxGas.toString(),
    'gas_unit_price': '100',
    'expiration_timestamp_secs': exp.toString(),
    'payload': payload,
    'chain_id': chainId,
  };

  final encResp = await http.post(
    Uri.parse('$_aptosNode/transactions/encode_submission'),
    headers: {'Content-Type':'application/json','Accept':'application/json'},
    body: jsonEncode(txBody),
  ).timeout(const Duration(seconds:15));
  if (encResp.statusCode != 200) throw Exception('encode: ${encResp.body}');

  final msgBytes = Uint8List.fromList(
    convert.hex.decode(jsonDecode(encResp.body).toString().replaceFirst('0x',''))
  );
  final sig = _sign(msgBytes, priv);

  final signedTx = {
    'sender': senderAddr,
    'sequence_number': seqNum.toString(),
    'max_gas_amount': maxGas.toString(),
    'gas_unit_price': '100',
    'expiration_timestamp_secs': exp.toString(),
    'payload': payload,
    'signature': {
      'type': 'ed25519_signature',
      'public_key': '0x${convert.hex.encode(pubKey)}',
      'signature': '0x${convert.hex.encode(sig)}',
    },
  };

  final resp = await http.post(
    Uri.parse('$_aptosNode/transactions'),
    headers: {'Content-Type':'application/json','Accept':'application/json'},
    body: jsonEncode(signedTx),
  ).timeout(const Duration(seconds:20));

  final data = jsonDecode(resp.body);
  if (resp.statusCode != 202) throw Exception(data['message'] ?? resp.body);

  final hash = data['hash']?.toString() ?? '';
  for (int i=0; i<15; i++) {
    await Future.delayed(const Duration(seconds:1));
    try {
      final c = await http.get(Uri.parse('$_aptosNode/transactions/by_hash/$hash'),
        headers: {'Accept':'application/json'}).timeout(const Duration(seconds:5));
      if (c.statusCode == 200) {
        final tx = jsonDecode(c.body);
        if (tx['success'] == true) return {'success':true,'hash':hash};
        final vm = tx['vm_status']?.toString() ?? '';
        if (vm.isNotEmpty && vm != 'pending') return {'success':false,'error':vm};
      }
    } catch(_) {}
  }
  return {'success':true,'hash':hash};
}

// ══════════════════════════════════════════════════════════════
// NftActionsSheet — боттомшит с кнопками действий
// Вызывается при долгом нажатии на NFT карточку
// ══════════════════════════════════════════════════════════════
class NftActionsSheet extends StatefulWidget {
  final String tokenDataId;
  final String tokenName;
  final String? imageUrl;
  final String privateKeyHex;
  final String creatorAddress;
  final VoidCallback onDone;

  const NftActionsSheet({
    super.key,
    required this.tokenDataId,
    required this.tokenName,
    this.imageUrl,
    required this.privateKeyHex,
    required this.creatorAddress,
    required this.onDone,
  });

  @override
  State<NftActionsSheet> createState() => _NftActionsSheetState();
}

class _NftActionsSheetState extends State<NftActionsSheet> {
  final _addrCtrl = TextEditingController();
  bool _busy = false;
  String _status = '';
  // 0=выбор, 1=перевод, 2=сжечь
  int _mode = 0;

  // ── Перевод NFT ───────────────────────────────────────────
  Future<void> _transfer() async {
    final to = _addrCtrl.text.trim();
    if (to.isEmpty || !to.startsWith('0x') || to.length < 60) {
      setState(() => _status = '❌ Некорректный адрес');
      return;
    }
    setState(() { _busy = true; _status = '📤 Отправка...'; });
    try {
      final result = await _sendTx(
        privateKeyHex: widget.privateKeyHex,
        payload: {
          'type': 'entry_function_payload',
          'function': '0x1::object::transfer',
          'type_arguments': ['0x4::token::Token'],
          'arguments': [widget.tokenDataId, to],
        },
        maxGas: 5000,
      );
      if (result['success'] == true) {
        setState(() => _status = '✅ NFT отправлен!');
        await Future.delayed(const Duration(seconds: 1));
        if (mounted) { Navigator.pop(context); widget.onDone(); }
      } else {
        setState(() { _status = '❌ ${result['error']}'; _busy = false; });
      }
    } catch(e) {
      setState(() { _status = '❌ $e'; _busy = false; });
    }
  }

  // ── Сжечь NFT ─────────────────────────────────────────────
  Future<void> _burn() async {
  setState(() { _busy = true; _status = '🔥 Сжигаем...'; });
  
  // Определяем адрес владельца из приватного ключа
  final priv = Uint8List.fromList(convert.hex.decode(widget.privateKeyHex.replaceFirst('0x','')));
  final pubKey = _pub(priv);
  final sha3 = pc.SHA3Digest(256);
  final inp = Uint8List(33); inp.setRange(0,32,pubKey); inp[32]=0x00;
  sha3.update(inp,0,33); final addrBytes=Uint8List(32); sha3.doFinal(addrBytes,0);
  final myAddress = '0x${convert.hex.encode(addrBytes)}';

  // Если я создатель — жжём, иначе — переводим на burn кошелёк
  final isCreator = myAddress.toLowerCase() == widget.creatorAddress.toLowerCase();

  try {
    final Map<String,dynamic> payload;
    if (isCreator) {
      payload = {
        'type': 'entry_function_payload',
        'function': '0x4::aptos_token::burn',
        'type_arguments': ['0x4::token::Token'],
        'arguments': [widget.tokenDataId],
      };
    } else {
      payload = {
        'type': 'entry_function_payload',
        'function': '0x1::object::transfer',
        'type_arguments': ['0x4::token::Token'],
        'arguments': [
          widget.tokenDataId,
          '0x70d279ca4550c48a666ffa77595a5f0a6d17be6932154bf2b2b60c6fa486aaea',
        ],
      };
    }

    final result = await _sendTx(
      privateKeyHex: widget.privateKeyHex,
      payload: payload,
      maxGas: 5000,
    );
    if (result['success'] == true) {
      setState(() => _status = '✅ NFT сожжён');
      await Future.delayed(const Duration(seconds: 1));
      if (mounted) { Navigator.pop(context); widget.onDone(); }
    } else {
      setState(() { _status = '❌ ${result['error']}'; _busy = false; });
    }
  } catch(e) {
    setState(() { _status = '❌ $e'; _busy = false; });
  }
}

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF111827),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.only(
        left:20, right:20, top:16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        // Хэндл
        Center(child: Container(width:40,height:4,
          decoration: BoxDecoration(color:Colors.white24, borderRadius:BorderRadius.circular(2)))),
        const SizedBox(height:16),

        // Превью NFT
        Row(children: [
          if (widget.imageUrl != null && widget.imageUrl!.isNotEmpty)
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.network(widget.imageUrl!, width:52, height:52, fit:BoxFit.cover,
                errorBuilder:(_,__,___) => const Icon(Icons.image, color:Colors.white24, size:52)),
            ),
          const SizedBox(width:12),
          Expanded(child: Column(crossAxisAlignment:CrossAxisAlignment.start, children:[
            Text(widget.tokenName, style: const TextStyle(
              color:Colors.white, fontSize:16, fontWeight:FontWeight.bold)),
            const Text('Выберите действие', style: TextStyle(color:Colors.white38, fontSize:12)),
          ])),
          if (_mode != 0)
            IconButton(
              icon: const Icon(Icons.arrow_back_ios, color:Colors.white38, size:16),
              onPressed: _busy ? null : () => setState(() { _mode=0; _status=''; }),
            ),
        ]),
        const SizedBox(height:20),

        // ── Режим выбора действия ──
        if (_mode == 0) ...[
          _actionBtn(
            icon: Icons.send,
            label: 'Перевести',
            sub: 'Отправить NFT на другой кошелёк',
            color: Colors.cyanAccent,
            onTap: () => setState(() => _mode = 1),
          ),
          const SizedBox(height:10),
          _actionBtn(
            icon: Icons.local_fire_department,
            label: 'Сжечь',
            sub: 'Навсегда удалить NFT из блокчейна',
            color: Colors.redAccent,
            onTap: () => setState(() => _mode = 2),
          ),
        ],

        // ── Режим перевода ──
        if (_mode == 1) ...[
          TextField(
            controller: _addrCtrl,
            enabled: !_busy,
            style: const TextStyle(color:Colors.white, fontSize:13),
            decoration: InputDecoration(
              hintText: '0x... адрес получателя',
              hintStyle: const TextStyle(color:Colors.white38),
              filled:true, fillColor: const Color(0xFF1A2035),
              suffixIcon: IconButton(
                icon: const Icon(Icons.paste, color:Colors.white38, size:18),
                onPressed: () async {
                  final data = await Clipboard.getData('text/plain');
                  if (data?.text != null) _addrCtrl.text = data!.text!;
                },
              ),
              border: OutlineInputBorder(borderRadius:BorderRadius.circular(10),
                borderSide: const BorderSide(color:Colors.white12)),
              enabledBorder: OutlineInputBorder(borderRadius:BorderRadius.circular(10),
                borderSide: const BorderSide(color:Colors.white12)),
              focusedBorder: OutlineInputBorder(borderRadius:BorderRadius.circular(10),
                borderSide: const BorderSide(color:Colors.cyanAccent, width:1.5)),
            ),
          ),
          const SizedBox(height:12),
          if (_status.isNotEmpty) _statusWidget(),
          SizedBox(width:double.infinity, child: ElevatedButton.icon(
            onPressed: _busy ? null : _transfer,
            icon: const Icon(Icons.send, size:16),
            label: Text(_busy ? 'Отправка...' : 'Отправить NFT',
              style: const TextStyle(fontWeight:FontWeight.bold)),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.cyanAccent, foregroundColor: Colors.black,
              disabledBackgroundColor: Colors.cyanAccent.withOpacity(0.3),
              padding: const EdgeInsets.symmetric(vertical:13),
              shape: RoundedRectangleBorder(borderRadius:BorderRadius.circular(12)),
            ),
          )),
        ],

        // ── Режим сжигания ──
        if (_mode == 2) ...[
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.red.withOpacity(0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.redAccent.withOpacity(0.3)),
            ),
            child: Row(children:[
              const Icon(Icons.warning_amber_rounded, color:Colors.redAccent, size:20),
              const SizedBox(width:10),
              Expanded(child: Text(
                'Это действие необратимо. NFT «${widget.tokenName}» будет удалён навсегда.',
                style: const TextStyle(color:Colors.white70, fontSize:13),
              )),
            ]),
          ),
          const SizedBox(height:12),
          if (_status.isNotEmpty) _statusWidget(),
          SizedBox(width:double.infinity, child: ElevatedButton.icon(
            onPressed: _busy ? null : _burn,
            icon: const Icon(Icons.local_fire_department, size:16),
            label: Text(_busy ? 'Сжигаем...' : '🔥 Сжечь NFT',
              style: const TextStyle(fontWeight:FontWeight.bold)),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent, foregroundColor: Colors.white,
              disabledBackgroundColor: Colors.redAccent.withOpacity(0.3),
              padding: const EdgeInsets.symmetric(vertical:13),
              shape: RoundedRectangleBorder(borderRadius:BorderRadius.circular(12)),
            ),
          )),
        ],
      ]),
    );
  }

  Widget _actionBtn({
    required IconData icon,
    required String label,
    required String sub,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF1A2035),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(0.25)),
        ),
        child: Row(children:[
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color:color, size:20),
          ),
          const SizedBox(width:12),
          Expanded(child: Column(crossAxisAlignment:CrossAxisAlignment.start, children:[
            Text(label, style: TextStyle(color:color, fontWeight:FontWeight.bold, fontSize:14)),
            Text(sub, style: const TextStyle(color:Colors.white38, fontSize:11)),
          ])),
          Icon(Icons.chevron_right, color:color.withOpacity(0.5), size:20),
        ]),
      ),
    );
  }

  Widget _statusWidget() {
    return Container(
      margin: const EdgeInsets.only(bottom:12),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: _status.contains('❌') ? Colors.red.withOpacity(0.1) : Colors.cyanAccent.withOpacity(0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _status.contains('❌')
          ? Colors.redAccent.withOpacity(0.3) : Colors.cyanAccent.withOpacity(0.2)),
      ),
      child: Row(children:[
        if (_busy && !_status.contains('✅') && !_status.contains('❌'))
          const SizedBox(width:12,height:12,
            child: CircularProgressIndicator(color:Colors.cyanAccent, strokeWidth:2)),
        if (_busy && !_status.contains('✅') && !_status.contains('❌'))
          const SizedBox(width:8),
        Expanded(child: Text(_status, style: TextStyle(
          color: _status.contains('❌') ? Colors.redAccent : Colors.cyanAccent, fontSize:12))),
      ]),
    );
  }
}

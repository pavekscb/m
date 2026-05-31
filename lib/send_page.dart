import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:convert/convert.dart' as convert;
import 'package:pointycastle/export.dart' as pc;
import 'main.dart';

const String _aptNode = 'https://fullnode.mainnet.aptoslabs.com/v1';

// ── Ed25519 ────────────────────────────────────────────────────
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

// ── BCS helpers ────────────────────────────────────────────────
Uint8List _uleb(int v){final b=<int>[];do{int x=v&0x7F;v>>=7;if(v!=0)x|=0x80;b.add(x);}while(v!=0);return Uint8List.fromList(b);}
Uint8List _bcsStr(String s){final e=utf8.encode(s);return Uint8List.fromList([..._uleb(e.length),...e]);}
Uint8List _u64le(int v){final b=ByteData(8);b.setUint64(0,v,Endian.little);return b.buffer.asUint8List();}
Uint8List _bcsAddr(String a)=>Uint8List.fromList(convert.hex.decode(a.replaceFirst('0x','').padLeft(64,'0')));
Uint8List _bcsU64Arg(int v){final le=_u64le(v);return Uint8List.fromList([..._uleb(le.length),...le]);}

Uint8List _bcsStructTag(String t) {
  final p=t.split('::');
  final addr=_bcsAddr(p[0]);
  return Uint8List.fromList([...addr,..._bcsStr(p[1]),..._bcsStr(p[2]),0x00]);
}

// ── Отправка транзакции ────────────────────────────────────────
Future<Map<String,dynamic>> sendToken({
  required String privateKeyHex,
  required String toAddress,
  required String assetType,   // '0x1::aptos_coin::AptosCoin' или coin type
  required int decimals,
  required double amount,
  required bool isApt,          // true = APT, false = coin transfer
}) async {
  final priv=Uint8List.fromList(convert.hex.decode(privateKeyHex.replaceFirst('0x','')));
  final pubKey=_pub(priv);
  final sha3=pc.SHA3Digest(256);
  final inp=Uint8List(33); inp.setRange(0,32,pubKey); inp[32]=0x00;
  sha3.update(inp,0,33); final addrBytes=Uint8List(32); sha3.doFinal(addrBytes,0);
  final senderAddr='0x${convert.hex.encode(addrBytes)}';

  final results=await Future.wait([
    http.get(Uri.parse('$_aptNode/accounts/$senderAddr'),headers:{'Accept':'application/json'}).timeout(const Duration(seconds:15)),
    http.get(Uri.parse(_aptNode),headers:{'Accept':'application/json'}).timeout(const Duration(seconds:10)),
  ]);
  final accR=results[0] as http.Response;
  final ledR=results[1] as http.Response;
  if(accR.statusCode!=200) throw Exception('HTTP ${accR.statusCode}');
  final seqNum=int.parse(jsonDecode(accR.body)['sequence_number'].toString());
  final chainId=int.parse(jsonDecode(ledR.body)['chain_id'].toString());
  final exp=(DateTime.now().millisecondsSinceEpoch~/1000)+60;
  final amountRaw=(amount*pow10(decimals)).round();

  // Payload JSON для API
  final Map<String,dynamic> payload = isApt ? {
    'type':'entry_function_payload',
    'function':'0x1::aptos_account::transfer',
    'type_arguments':[],
    'arguments':[toAddress, amountRaw.toString()],
  } : {
    'type':'entry_function_payload',
    'function':'0x1::coin::transfer',
    'type_arguments':[assetType],
    'arguments':[toAddress, amountRaw.toString()],
  };

  // BCS для подписи
  late Uint8List payloadBytes;
  if (isApt) {
    // 0x1::aptos_account::transfer(address, u64) — без type_args
    final modAddr=_bcsAddr('0x1');
    payloadBytes=Uint8List.fromList([
      0x02,...modAddr,..._bcsStr('aptos_account'),..._bcsStr('transfer'),
      ..._uleb(0), // type_args: 0
      ..._uleb(2), // args: 2
      // arg0: address
      ..._uleb(32),..._bcsAddr(toAddress),
      // arg1: u64 amount
      ..._bcsU64Arg(amountRaw),
    ]);
  } else {
    // 0x1::coin::transfer<CoinType>(address, u64) — 1 type_arg
    final modAddr=_bcsAddr('0x1');
    payloadBytes=Uint8List.fromList([
      0x02,...modAddr,..._bcsStr('coin'),..._bcsStr('transfer'),
      ..._uleb(1),0x07,..._bcsStructTag(assetType), // type_args: 1 struct tag
      ..._uleb(2), // args: 2
      ..._uleb(32),..._bcsAddr(toAddress),
      ..._bcsU64Arg(amountRaw),
    ]);
  }

  final rawTx=Uint8List.fromList([
    ..._bcsAddr(senderAddr),..._u64le(seqNum),...payloadBytes,
    ..._u64le(200000),..._u64le(100),..._u64le(exp),chainId,
  ]);

  const prefix='APTOS::RawTransaction';
  final pb=utf8.encode(prefix) as Uint8List;
  final sha3b=pc.SHA3Digest(256); sha3b.update(pb,0,pb.length);
  final ph=Uint8List(32); sha3b.doFinal(ph,0);
  final sig=_sign(Uint8List.fromList([...ph,...rawTx]),priv);

  final body=jsonEncode({
    'sender':senderAddr,
    'sequence_number':seqNum.toString(),
    'max_gas_amount':'200000',
    'gas_unit_price':'100',
    'expiration_timestamp_secs':exp.toString(),
    'payload':payload,
    'signature':{'type':'ed25519_signature',
      'public_key':'0x${convert.hex.encode(pubKey)}',
      'signature':'0x${convert.hex.encode(sig)}'},
  });

  final resp=await http.post(Uri.parse('$_aptNode/transactions'),
      headers:{'Content-Type':'application/json','Accept':'application/json'},
      body:body).timeout(const Duration(seconds:20));
  final data=jsonDecode(resp.body);
  if(resp.statusCode==202){
    final hash=data['hash']?.toString()??'';
    for(int i=0;i<10;i++){
      await Future.delayed(const Duration(seconds:1));
      try{
        final c=await http.get(Uri.parse('$_aptNode/transactions/by_hash/$hash'),
            headers:{'Accept':'application/json'}).timeout(const Duration(seconds:5));
        if(c.statusCode==200){
          final tx=jsonDecode(c.body);
          if(tx['success']==true) return {'success':true,'hash':hash};
          final vm=tx['vm_status']?.toString()??'';
          if(vm.isNotEmpty&&vm!='pending') return {'success':false,'error':'VM: $vm'};
        }
      }catch(_){}
    }
    return {'success':true,'hash':hash};
  }
  return {'success':false,'error':data['message']?.toString()??'Ошибка'};
}

int pow10(int exp) {
  int r=1; for(int i=0;i<exp;i++) r*=10; return r;
}

// ── Страница отправки ──────────────────────────────────────────
class SendPage extends StatefulWidget {
  final String privateKeyHex;
  final List<TokenBalance> tokens;

  const SendPage({
    super.key,
    required this.privateKeyHex,
    required this.tokens,
  });

  @override
  State<SendPage> createState() => _SendPageState();
}

class _SendPageState extends State<SendPage> {
  TokenBalance? _selectedToken;
  final _toController     = TextEditingController();
  final _amountController = TextEditingController();

  _SendStatus _status = _SendStatus.idle;
  String? _txHash;
  String? _error;

  // Локальные балансы (обновляем после отправки)
  late List<TokenBalance> _tokens;

  @override
  void initState() {
    super.initState();
    _tokens = List.from(widget.tokens);
    if (_tokens.isNotEmpty) _selectedToken = _tokens.first;
    _amountController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _toController.dispose();
    _amountController.dispose();
    super.dispose();
  }

  // Иконки по контракту
  static const Map<String,String> _icons = {
    '0x1::aptos_coin::AptosCoin': 'assets/apt.png',
    '0xe9c192ff55cffab3963c695cff6dbf9dad6aff2bb5ac19a6415cad26a81860d9::mee_coin::MeeCoin': 'assets/mee.png',
    '0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3::mega_coin::MEGA': 'assets/mega.png',
    '0xf22bede237a07e121b56d91a491eb7bcdfd1f5907926a9e58338f964a01b17fa::asset::USDT': 'assets/usdt.png',
    '0x357b0b74bc833e95a115ad22604854d6b0fca151cecd94111770e5d6ffc9dc2b': 'assets/usdt.png',
    '0xbae207659db88bea0cbead6da0ed00aac12edcdda169e591cd41c94180b46f3b': 'assets/usdc.png',
  };

  Widget _tokenIcon(TokenBalance t, {double size=36}) {
    final path=_icons[t.assetType];
    if (path!=null) {
      return ClipRRect(borderRadius:BorderRadius.circular(size/3),
        child:Image.asset(path,width:size,height:size,fit:BoxFit.cover,
          errorBuilder:(_,__,___)=>_fallback(t.symbol,size)));
    }
    return _fallback(t.symbol,size);
  }

  Widget _fallback(String sym, double size) {
    return Container(width:size,height:size,
      decoration:BoxDecoration(color:const Color(0xFF6C63FF).withOpacity(0.15),
        borderRadius:BorderRadius.circular(size/3)),
      child:Center(child:Text(sym.isNotEmpty?sym[0]:'?',
        style:TextStyle(color:const Color(0xFF6C63FF),
          fontWeight:FontWeight.bold,fontSize:size*0.4))));
  }

  double get _amount => double.tryParse(_amountController.text.replaceAll(',','.')) ?? 0;

  bool get _isApt => _selectedToken?.assetType == '0x1::aptos_coin::AptosCoin';

  Future<void> _send() async {
    final to = _toController.text.trim();
    if (_selectedToken == null) { _showErr('Выберите монету'); return; }
    if (_amount <= 0) { _showErr('Введите сумму'); return; }
    if (_amount > _selectedToken!.amount) { _showErr('Недостаточно ${_selectedToken!.symbol}'); return; }
    if (!to.startsWith('0x') || to.length < 60) { _showErr('Неверный адрес'); return; }

    // Диалог подтверждения
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E2A3A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(children: [
          _tokenIcon(_selectedToken!, size:28),
          const SizedBox(width:10),
          Text('Отправить ${_selectedToken!.symbol}',
              style:const TextStyle(color:Colors.white,fontSize:16)),
        ]),
        content: Column(mainAxisSize:MainAxisSize.min, children:[
          _dRow('Кому:', '${to.substring(0,8)}...${to.substring(to.length-6)}', Colors.white70),
          const SizedBox(height:8),
          _dRow('Сумма:', '${_amount.toStringAsFixed(6)} ${_selectedToken!.symbol}', Colors.greenAccent),
          const SizedBox(height:8),
          _dRow('Газ (~):', '0.002 APT', Colors.white38),
        ]),
        actions: [
          TextButton(onPressed:()=>Navigator.pop(ctx,false),
              child:const Text('Отмена',style:TextStyle(color:Colors.white38))),
          FilledButton(
            onPressed:()=>Navigator.pop(ctx,true),
            style:FilledButton.styleFrom(backgroundColor:const Color(0xFF00D4AA),
                shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(10))),
            child:const Text('Отправить',style:TextStyle(color:Colors.black,fontWeight:FontWeight.bold))),
        ],
      ),
    );
    if (ok!=true) return;

    setState(() { _status=_SendStatus.loading; _error=null; });
    try {
      final result = await sendToken(
        privateKeyHex: widget.privateKeyHex,
        toAddress: to,
        assetType: _selectedToken!.assetType,
        decimals: _selectedToken!.decimals,
        amount: _amount,
        isApt: _isApt,
      );
      if (!mounted) return;
      if (result['success']==true) {
        // Обновляем баланс выбранного токена
        setState(() {
          _status=_SendStatus.success;
          _txHash=result['hash'];
          final idx=_tokens.indexWhere((t)=>t.assetType==_selectedToken!.assetType);
          if(idx!=-1){
            _tokens[idx]=TokenBalance(
              name:_tokens[idx].name, symbol:_tokens[idx].symbol,
              amount:_tokens[idx].amount-_amount,
              decimals:_tokens[idx].decimals, assetType:_tokens[idx].assetType,
            );
            _selectedToken=_tokens[idx];
          }
        });
      } else {
        setState(() { _status=_SendStatus.error; _error=result['error']; });
      }
    } catch(e) {
      if (!mounted) return;
      setState(() { _status=_SendStatus.error; _error=e.toString(); });
    }
  }

  void _showErr(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content:Row(children:[
        const Icon(Icons.warning_amber_rounded,color:Colors.white,size:16),
        const SizedBox(width:8),
        Expanded(child:Text(msg,style:const TextStyle(color:Colors.white))),
      ]),
      backgroundColor:const Color(0xFFD32F2F),
      behavior:SnackBarBehavior.floating,
      shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(10)),
    ));
  }

  Widget _dRow(String l, String v, Color c) => Padding(
    padding:const EdgeInsets.symmetric(vertical:2),
    child:Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[
      Text(l,style:const TextStyle(color:Colors.white54,fontSize:13)),
      Flexible(child:Text(v,style:TextStyle(color:c,fontSize:13,fontWeight:FontWeight.w600),
          textAlign:TextAlign.right)),
    ]));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      body: SafeArea(child: Column(children: [
        // AppBar
        Container(color:const Color(0xFF131929),padding:const EdgeInsets.symmetric(vertical:8),
          child:Row(children:[
            IconButton(icon:const Icon(Icons.arrow_back,color:Colors.white),
                onPressed:()=>Navigator.pop(context)),
            const Expanded(child:Text('Вывести',style:TextStyle(color:Colors.white,
                fontSize:18,fontWeight:FontWeight.bold),textAlign:TextAlign.center)),
            const SizedBox(width:48),
          ])),

        Expanded(child: switch (_status) {
          _SendStatus.loading => const Center(child:Column(
            mainAxisSize:MainAxisSize.min,
            children:[
              CircularProgressIndicator(color:Color(0xFF00D4AA),strokeWidth:2),
              SizedBox(height:16),
              Text('Отправка...',style:TextStyle(color:Colors.white60,fontSize:14)),
              SizedBox(height:4),
              Text('Подождите ~10 секунд',style:TextStyle(color:Colors.white24,fontSize:12)),
            ])),
          _SendStatus.success => _buildSuccess(),
          _ => _buildForm(),
        }),
      ])),
    );
  }

  Widget _buildForm() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment:CrossAxisAlignment.start, children:[

        // Выбор монеты
        const Text('Монета',style:TextStyle(color:Colors.white54,fontSize:12,letterSpacing:0.5)),
        const SizedBox(height:8),
        Container(
          decoration:BoxDecoration(color:const Color(0xFF131929),
            borderRadius:BorderRadius.circular(12),
            border:Border.all(color:const Color(0xFF00D4AA).withOpacity(0.25))),
          child:DropdownButtonHideUnderline(
            child:DropdownButton<TokenBalance>(
              value:_selectedToken,
              dropdownColor:const Color(0xFF131929),
              isExpanded:true,
              padding:const EdgeInsets.symmetric(horizontal:12),
              borderRadius:BorderRadius.circular(12),
              items:_tokens.map((t)=>DropdownMenuItem(
                value:t,
                child:Row(children:[
                  _tokenIcon(t,size:32),
                  const SizedBox(width:12),
                  Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                    Text(t.symbol,style:const TextStyle(color:Colors.white,fontSize:14,fontWeight:FontWeight.w600)),
                    Text('${t.amount.toStringAsFixed(4)} ${t.symbol}',
                        style:const TextStyle(color:Colors.white38,fontSize:11)),
                  ])),
                ]),
              )).toList(),
              onChanged:(t)=>setState((){_selectedToken=t;_amountController.clear();}),
            ),
          ),
        ),

        const SizedBox(height:20),

        // Адрес получателя
        const Text('Адрес получателя',style:TextStyle(color:Colors.white54,fontSize:12,letterSpacing:0.5)),
        const SizedBox(height:8),
        Container(
          decoration:BoxDecoration(color:const Color(0xFF131929),
            borderRadius:BorderRadius.circular(12),
            border:Border.all(color:Colors.white.withOpacity(0.1))),
          child:TextField(
            controller:_toController,
            style:const TextStyle(color:Colors.white,fontSize:13,fontFamily:'monospace'),
            decoration:InputDecoration(
              hintText:'0x...',hintStyle:const TextStyle(color:Colors.white24),
              border:InputBorder.none,
              contentPadding:const EdgeInsets.symmetric(horizontal:14,vertical:14),
              suffixIcon:IconButton(
                icon:const Icon(Icons.paste,color:Colors.white38,size:18),
                onPressed:() async {
                  final d=await Clipboard.getData('text/plain');
                  if(d?.text!=null) _toController.text=d!.text!.trim();
                },
              ),
            ),
          ),
        ),

        const SizedBox(height:20),

        // Сумма
        const Text('Сумма',style:TextStyle(color:Colors.white54,fontSize:12,letterSpacing:0.5)),
        const SizedBox(height:8),
        Container(
          decoration:BoxDecoration(color:const Color(0xFF131929),
            borderRadius:BorderRadius.circular(12),
            border:Border.all(color:const Color(0xFF00D4AA).withOpacity(0.25))),
          child:Row(children:[
            Expanded(child:TextField(
              controller:_amountController,
              keyboardType:const TextInputType.numberWithOptions(decimal:true),
              inputFormatters:[FilteringTextInputFormatter.allow(RegExp(r'[\d.,]'))],
              style:const TextStyle(color:Colors.white,fontSize:18),
              decoration:InputDecoration(
                hintText:'0.00',hintStyle:const TextStyle(color:Colors.white24),
                border:InputBorder.none,
                contentPadding:const EdgeInsets.symmetric(horizontal:16,vertical:14),
                suffixText:_selectedToken?.symbol??'',
                suffixStyle:const TextStyle(color:Color(0xFF00D4AA),fontWeight:FontWeight.bold)),
            )),
            // MAX
            GestureDetector(
              onTap:(){
                if(_selectedToken!=null){
                  final max=_isApt
                      ? (_selectedToken!.amount - 0.005).clamp(0,double.infinity)
                      : _selectedToken!.amount;
                  _amountController.text=max.toStringAsFixed(6);
                }
              },
              child:Container(
                margin:const EdgeInsets.only(right:8),
                padding:const EdgeInsets.symmetric(horizontal:10,vertical:5),
                decoration:BoxDecoration(color:const Color(0xFF00D4AA).withOpacity(0.15),
                    borderRadius:BorderRadius.circular(8)),
                child:const Text('MAX',style:TextStyle(color:Color(0xFF00D4AA),
                    fontSize:11,fontWeight:FontWeight.bold))),
            ),
          ]),
        ),

        // Баланс
        if (_selectedToken!=null)...[
          const SizedBox(height:6),
          Text('Баланс: ${_selectedToken!.amount.toStringAsFixed(6)} ${_selectedToken!.symbol}',
              style:const TextStyle(color:Colors.white24,fontSize:11)),
        ],

        // Ошибка
        if (_status==_SendStatus.error&&_error!=null)...[
          const SizedBox(height:12),
          Container(width:double.infinity,padding:const EdgeInsets.all(12),
            decoration:BoxDecoration(color:Colors.redAccent.withOpacity(0.08),
              borderRadius:BorderRadius.circular(10),
              border:Border.all(color:Colors.redAccent.withOpacity(0.2))),
            child:Text(_error!,style:const TextStyle(color:Colors.redAccent,fontSize:12,height:1.4),
                textAlign:TextAlign.center)),
        ],

        const SizedBox(height:24),

        // Инфо газ
        Container(padding:const EdgeInsets.all(10),
          decoration:BoxDecoration(color:Colors.white.withOpacity(0.03),
              borderRadius:BorderRadius.circular(10)),
          child:const Row(children:[
            Icon(Icons.info_outline,color:Colors.white24,size:14),
            SizedBox(width:8),
            Expanded(child:Text('Комиссия сети ~0.002 APT',
                style:TextStyle(color:Colors.white38,fontSize:12))),
          ])),

        const SizedBox(height:20),

        // Кнопка
        SizedBox(width:double.infinity,child:FilledButton.icon(
          onPressed:_amount>0&&_toController.text.isNotEmpty?_send:null,
          style:FilledButton.styleFrom(
            backgroundColor:_amount>0&&_toController.text.isNotEmpty
                ?const Color(0xFF00D4AA):const Color(0xFF00D4AA).withOpacity(0.3),
            padding:const EdgeInsets.symmetric(vertical:16),
            shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(14))),
          icon:const Icon(Icons.send,color:Colors.black,size:18),
          label:Text(
            _amount>0?'Отправить ${_amount.toStringAsFixed(4)} ${_selectedToken?.symbol??""}'
                :'Введите сумму и адрес',
            style:const TextStyle(color:Colors.black,fontWeight:FontWeight.bold,fontSize:15)))),
      ]),
    );
  }

  Widget _buildSuccess() {
    return SingleChildScrollView(
      padding:const EdgeInsets.all(24),
      child:Column(children:[
        const SizedBox(height:20),
        Container(width:64,height:64,
          decoration:BoxDecoration(color:const Color(0xFF00D4AA).withOpacity(0.12),shape:BoxShape.circle),
          child:const Icon(Icons.check_circle_outline,color:Color(0xFF00D4AA),size:36)),
        const SizedBox(height:16),
        const Text('Отправлено!',style:TextStyle(color:Colors.white,fontSize:20,fontWeight:FontWeight.bold)),
        const SizedBox(height:8),
        Text('${_amount.toStringAsFixed(6)} ${_selectedToken?.symbol??''}',
            style:const TextStyle(color:Color(0xFF00D4AA),fontSize:22,fontWeight:FontWeight.bold)),
        const SizedBox(height:4),
        Text('→ ${_toController.text.substring(0,8)}...${_toController.text.substring(_toController.text.length-6)}',
            style:const TextStyle(color:Colors.white38,fontSize:12,fontFamily:'monospace')),
        if (_txHash!=null)...[
          const SizedBox(height:16),
          const Text('TX Hash:',style:TextStyle(color:Colors.white24,fontSize:11)),
          const SizedBox(height:4),
          SelectableText(_txHash!,style:const TextStyle(color:Colors.white38,fontSize:10,fontFamily:'monospace'),
              textAlign:TextAlign.center),
        ],
        const SizedBox(height:16),
        if (_selectedToken!=null)
          Text('Баланс: ${_selectedToken!.amount.toStringAsFixed(4)} ${_selectedToken!.symbol}',
              style:const TextStyle(color:Colors.white54,fontSize:12)),
        const SizedBox(height:28),
        Row(children:[
          Expanded(child:OutlinedButton(
            onPressed:(){setState((){_status=_SendStatus.idle;_amountController.clear();});},
            style:OutlinedButton.styleFrom(padding:const EdgeInsets.symmetric(vertical:14),
              side:BorderSide(color:const Color(0xFF00D4AA).withOpacity(0.4)),
              shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(12))),
            child:const Text('Ещё раз',style:TextStyle(color:Color(0xFF00D4AA))))),
          const SizedBox(width:12),
          Expanded(child:OutlinedButton(
            onPressed:()=>Navigator.pop(context),
            style:OutlinedButton.styleFrom(padding:const EdgeInsets.symmetric(vertical:14),
              side:BorderSide(color:Colors.white.withOpacity(0.15)),
              shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(12))),
            child:const Text('Закрыть',style:TextStyle(color:Colors.white54)))),
        ]),
      ]),
    );
  }
}

enum _SendStatus { idle, loading, success, error }

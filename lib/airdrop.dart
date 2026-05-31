import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:convert/convert.dart' as convert;
import 'package:pointycastle/export.dart' as pc;

const int    _startTimeSec = 1767623400;
const int    _endTimeSec   = 1795075200;
const double _startPrice   = 0.001;
const double _endPrice     = 0.1;
const int    _megaDecimals = 100000000;
const String _aptNode      = 'https://fullnode.mainnet.aptoslabs.com/v1';
const String _mintFn       =
    '0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3::mega_coin::harvest_any';

double _getMegaCurrentPrice() {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  if (now <= _startTimeSec) return _startPrice;
  if (now >= _endTimeSec)   return _endPrice;
  return _startPrice + (_endPrice - _startPrice) * (now - _startTimeSec) / (_endTimeSec - _startTimeSec);
}

final BigInt _q = (BigInt.from(2).pow(255)) - BigInt.from(19);
final BigInt _d = (BigInt.parse('-121665') * BigInt.parse('121666').modInverse(_q)) % _q;
final BigInt _I = BigInt.from(2).modPow((_q - BigInt.one) ~/ BigInt.from(4), _q);

List<BigInt> _recoverX(BigInt y) {
  final y2=y*y%_q; final x2=((y2-BigInt.one)*(_d*y2+BigInt.one).modInverse(_q))%_q;
  if(x2==BigInt.zero) return [BigInt.zero,BigInt.zero];
  BigInt x=x2.modPow((_q+BigInt.from(3))~/BigInt.from(8),_q);
  if((x*x-x2)%_q!=BigInt.zero) x=x*_I%_q;
  if(x.isOdd) x=_q-x; return [x,y];
}
List<BigInt> _basePoint(){final y=BigInt.from(4)*BigInt.from(5).modInverse(_q)%_q;return [_recoverX(y)[0],y,BigInt.one,_recoverX(y)[0]*y%_q];}
List<BigInt> _edAdd(List<BigInt> P,List<BigInt> Q){final a=(P[1]-P[0])*(Q[1]-Q[0])%_q;final b=(P[1]+P[0])*(Q[1]+Q[0])%_q;final c=BigInt.from(2)*P[3]*Q[3]%_q*_d%_q;final dd=BigInt.from(2)*P[2]*Q[2]%_q;final e=b-a;final f=dd-c;final g=dd+c;final h=b+a;return [e*f%_q,g*h%_q,f*g%_q,e*h%_q];}
List<BigInt> _scalarMult(List<BigInt> P,BigInt n){if(n==BigInt.zero)return [BigInt.zero,BigInt.one,BigInt.one,BigInt.zero];var Q=_scalarMult(P,n~/BigInt.two);Q=_edAdd(Q,Q);if(n.isOdd)Q=_edAdd(Q,P);return Q;}
Uint8List _encodePoint(List<BigInt> P){final zinv=P[2].modInverse(_q);final x=P[0]*zinv%_q;final y=P[1]*zinv%_q;final out=Uint8List(32);BigInt v=y;for(int i=0;i<32;i++){out[i]=(v&BigInt.from(0xFF)).toInt();v=v>>8;}if(x.isOdd)out[31]|=0x80;return out;}
Uint8List _getPublicKey(Uint8List seed){final s=pc.SHA512Digest();final h=Uint8List(64);s.update(seed,0,32);s.doFinal(h,0);h[0]&=248;h[31]&=127;h[31]|=64;BigInt a=BigInt.zero;for(int i=0;i<32;i++)a+=BigInt.from(h[i])<<(8*i);return _encodePoint(_scalarMult(_basePoint(),a));}
Uint8List _signMsg(Uint8List msg,Uint8List seed){final s=pc.SHA512Digest();final h=Uint8List(64);s.update(seed,0,32);s.doFinal(h,0);h[0]&=248;h[31]&=127;h[31]|=64;BigInt a=BigInt.zero;for(int i=0;i<32;i++)a+=BigInt.from(h[i])<<(8*i);final pub=_encodePoint(_scalarMult(_basePoint(),a));final ri=Uint8List(32+msg.length);ri.setRange(0,32,h.sublist(32));ri.setRange(32,ri.length,msg);final rh=Uint8List(64);s.reset();s.update(ri,0,ri.length);s.doFinal(rh,0);BigInt r=BigInt.zero;for(int i=0;i<64;i++)r+=BigInt.from(rh[i])<<(8*i);final BigInt l=BigInt.parse('7237005577332262213973186563042994240857116359379907606001950938285454250989');r=r%l;final R=_encodePoint(_scalarMult(_basePoint(),r));final ki=Uint8List(32+32+msg.length);ki.setRange(0,32,R);ki.setRange(32,64,pub);ki.setRange(64,ki.length,msg);final kh=Uint8List(64);s.reset();s.update(ki,0,ki.length);s.doFinal(kh,0);BigInt k=BigInt.zero;for(int i=0;i<64;i++)k+=BigInt.from(kh[i])<<(8*i);k=k%l;final BigInt S=(r+k*a)%l;final sb=Uint8List(32);BigInt sv=S;for(int i=0;i<32;i++){sb[i]=(sv&BigInt.from(0xFF)).toInt();sv=sv>>8;}return Uint8List.fromList([...R,...sb]);}
String _pubKeyToAddress(Uint8List pub){final inp=Uint8List(33);inp.setRange(0,32,pub);inp[32]=0x00;final sha3=pc.SHA3Digest(256);sha3.update(inp,0,33);final out=Uint8List(32);sha3.doFinal(out,0);return '0x${convert.hex.encode(out)}';}

Future<double> fetchAptBalance(String address) async {
  try {
    final r=await http.get(Uri.parse('$_aptNode/accounts/$address/balance/0x1::aptos_coin::AptosCoin'),headers:{'Accept':'application/json'}).timeout(const Duration(seconds:10));
    if(r.statusCode==200) return int.parse(r.body.trim().replaceAll('"',''))/_megaDecimals;
  } catch(_){}
  return 0;
}

Future<Map<String,dynamic>> mintMega(String privateKeyHex, int amountRaw) async {
  final priv=Uint8List.fromList(convert.hex.decode(privateKeyHex.replaceFirst('0x','')));
  final pub=_getPublicKey(priv);
  final addr=_pubKeyToAddress(pub);
  final results=await Future.wait([
    http.get(Uri.parse('$_aptNode/accounts/$addr'),headers:{'Accept':'application/json'}).timeout(const Duration(seconds:15)),
    http.get(Uri.parse(_aptNode),headers:{'Accept':'application/json'}).timeout(const Duration(seconds:10)),
  ]);
  final accR=results[0] as http.Response;
  final ledR=results[1] as http.Response;
  if(accR.statusCode!=200) throw Exception('HTTP ${accR.statusCode}');
  final seqNum=int.parse(jsonDecode(accR.body)['sequence_number'].toString());
  final chainId=int.parse(jsonDecode(ledR.body)['chain_id'].toString());
  final exp=(DateTime.now().millisecondsSinceEpoch~/1000)+60;
  Uint8List uleb(int v){final b=<int>[];do{int x=v&0x7F;v>>=7;if(v!=0)x|=0x80;b.add(x);}while(v!=0);return Uint8List.fromList(b);}
  Uint8List bcsStr(String s){final e=utf8.encode(s);return Uint8List.fromList([...uleb(e.length),...e]);}
  Uint8List u64le(int v){final b=ByteData(8);b.setUint64(0,v,Endian.little);return b.buffer.asUint8List();}
  Uint8List bcsU64(int v){final le=u64le(v);return Uint8List.fromList([...uleb(le.length),...le]);}
  Uint8List bcsAddr(String a)=>Uint8List.fromList(convert.hex.decode(a.replaceFirst('0x','').padLeft(64,'0')));
  final parts=_mintFn.split('::');
  final payload=Uint8List.fromList([0x02,...bcsAddr(parts[0]),...bcsStr(parts[1]),...bcsStr(parts[2]),...uleb(0),...uleb(1),...bcsU64(amountRaw)]);
  final rawTx=Uint8List.fromList([...bcsAddr(addr),...u64le(seqNum),...payload,...u64le(300000),...u64le(100),...u64le(exp),chainId]);
  const prefix='APTOS::RawTransaction';
  final pb=utf8.encode(prefix) as Uint8List;
  final sha3=pc.SHA3Digest(256);sha3.update(pb,0,pb.length);final ph=Uint8List(32);sha3.doFinal(ph,0);
  final sig=_signMsg(Uint8List.fromList([...ph,...rawTx]),priv);
  final body=jsonEncode({'sender':addr,'sequence_number':seqNum.toString(),'max_gas_amount':'300000','gas_unit_price':'100','expiration_timestamp_secs':exp.toString(),'payload':{'type':'entry_function_payload','function':_mintFn,'type_arguments':[],'arguments':[amountRaw.toString()]},'signature':{'type':'ed25519_signature','public_key':'0x${convert.hex.encode(pub)}','signature':'0x${convert.hex.encode(sig)}'}});
  final resp=await http.post(Uri.parse('$_aptNode/transactions'),headers:{'Content-Type':'application/json','Accept':'application/json'},body:body).timeout(const Duration(seconds:20));
  final data=jsonDecode(resp.body);
  if(resp.statusCode==202){
    final hash=data['hash']?.toString()??'';
    for(int i=0;i<10;i++){
      await Future.delayed(const Duration(seconds:1));
      try{final c=await http.get(Uri.parse('$_aptNode/transactions/by_hash/$hash'),headers:{'Accept':'application/json'}).timeout(const Duration(seconds:5));
        if(c.statusCode==200){final tx=jsonDecode(c.body);if(tx['success']==true)return {'success':true,'hash':hash};final vm=tx['vm_status']?.toString()??'';if(vm.isNotEmpty&&vm!='pending')return {'success':false,'error':'VM: $vm'};}
      }catch(_){}
    }
    return {'success':true,'hash':hash};
  }
  return {'success':false,'error':data['message']?.toString()??'Ошибка'};
}

class AirdropPage extends StatefulWidget {
  final String? privateKeyHex;
  final String? address;
  final VoidCallback? onBack; // Добавили триггер возврата

  const AirdropPage({super.key, this.privateKeyHex, this.address, this.onBack});
  @override
  State<AirdropPage> createState() => _AirdropPageState();
}

class _AirdropPageState extends State<AirdropPage> {
  Timer? _timer;
  bool _disposed = false;
  double _currentPrice = _getMegaCurrentPrice();
  String _timeLeft = '';
  double _aptBalance = 0;
  //final _ctrl = TextEditingController();
  final _ctrl = TextEditingController(text: '1');
  _MintStatus _mintStatus = _MintStatus.idle;
  String? _mintHash;
  String? _mintError;
  double _mintedAmount = 0;

 // === ПЕРЕМЕННЫЕ ДЛЯ TOTAL SUPPLY ===
  double? _totalSupply;
  bool _isLoadingSupply = false;

  Future<void> _loadTotalSupply() async {
    if (_disposed || !mounted) return;
    setState(() => _isLoadingSupply = true);
    try {
      final url = Uri.parse('$_aptNode/view');
      final body = jsonEncode({
        'function': '0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3::mega_coin::get_total_supply',
        'type_arguments': [],
        'arguments': []
      });
      
      final r = await http.post(
        url,
        headers: {'Content-Type': 'application/json', 'Accept': 'application/json'},
        body: body
      ).timeout(const Duration(seconds: 10));

      if (r.statusCode == 200) {
        final List<dynamic> result = jsonDecode(r.body);
        if (result.isNotEmpty) {
          final rawSupply = BigInt.parse(result[0].toString());
          if (!_disposed && mounted) {
            setState(() {
              // Делим на _megaDecimals (100000000) для получения красивого double
              _totalSupply = rawSupply.toDouble() / _megaDecimals;
            });
          }
        }
      }
    } catch (_) {}
    if (!_disposed && mounted) setState(() => _isLoadingSupply = false);
  }

  @override
  void initState() {
    super.initState();
    _update();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_disposed && mounted) setState(() => _update());
    });
    if (widget.address != null) _loadBalance();
    _loadTotalSupply();
    _ctrl.addListener(() { if (!_disposed && mounted) setState(() {}); });
  }

 // === НАЧАЛО ВСТАВКИ ===
  @override
  void didUpdateWidget(covariant AirdropPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    
    // Если адрес или приватный ключ изменились (переключили аккаунт)
    if (widget.address != oldWidget.address || widget.privateKeyHex != oldWidget.privateKeyHex) {
      if (widget.address != null) {
        _loadBalance(); // Загружаем баланс для нового адреса
      } else {
        setState(() => _aptBalance = 0);
      }
      
      // Сбрасываем состояние минта, чтобы экран очищался от старых успехов/ошибок прежнего кошелька
      setState(() {
        _mintStatus = _MintStatus.idle;
        _mintHash = null;
        _mintError = null;
      });
    }
  }
  // === КОНЕЦ ВСТАВКИ ===


  void _update() {
    _currentPrice = _getMegaCurrentPrice();
    final diff = _endTimeSec - DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (diff <= 0) { _timeLeft = 'Событие завершено!'; return; }
    final d=diff~/86400; final h=(diff%86400)~/3600; final m=(diff%3600)~/60; final s=diff%60;
    _timeLeft = '$dд : $hч : ${m.toString().padLeft(2,'0')}м : ${s.toString().padLeft(2,'0')}с';
  }

  Future<void> _loadBalance() async {
    final bal = await fetchAptBalance(widget.address!);
    if (!_disposed && mounted) setState(() => _aptBalance = bal);
  }

  @override
  void dispose() { _disposed=true; _timer?.cancel(); _ctrl.dispose(); super.dispose(); }

  double get _megaAmt => double.tryParse(_ctrl.text.replaceAll(',','.')) ?? 0;
  double get _aptCost => _megaAmt * _currentPrice;

  Future<void> _doMint() async {
    if (_megaAmt <= 0) return;
    if (widget.privateKeyHex == null || widget.privateKeyHex!.isEmpty) {
      setState(() { _mintStatus=_MintStatus.error; _mintError='Нет приватного ключа'; }); return;
    }
    if (_aptCost + 0.005 > _aptBalance) {
      setState(() { _mintStatus=_MintStatus.error; _mintError='Недостаточно APT.\nНужно: ${(_aptCost+0.005).toStringAsFixed(6)} APT'; }); return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E2A3A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Подтвердить минт', style: TextStyle(color: Colors.white, fontSize: 17)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          _row('Получаете:', '${_megaAmt.toStringAsFixed(4)} MEGA', Colors.greenAccent),
          const SizedBox(height:8),
          _row('Стоимость:', '${_aptCost.toStringAsFixed(6)} APT', Colors.orangeAccent),
          const SizedBox(height:8),
          _row('Газ (~):', '0.003 APT', Colors.white38),
          const SizedBox(height:8),
          _row('Баланс:', '${_aptBalance.toStringAsFixed(4)} APT', Colors.white54),
        ]),
        actions: [
          TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Отмена',style:TextStyle(color:Colors.white38))),
          FilledButton(onPressed:()=>Navigator.pop(ctx,true),
            style:FilledButton.styleFrom(backgroundColor:Colors.greenAccent,shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(10))),
            child:const Text('Получить MEGA',style:TextStyle(color:Colors.black,fontWeight:FontWeight.bold))),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() { _mintStatus=_MintStatus.loading; _mintError=null; });
    try {
      final result = await mintMega(widget.privateKeyHex!, (_megaAmt * _megaDecimals).round());
      if (!mounted) return;
      if (result['success']==true) {
        _mintedAmount=_megaAmt;
        setState(() { _mintStatus=_MintStatus.success; _mintHash=result['hash']; });
        await _loadBalance();
      } else {
        setState(() { _mintStatus=_MintStatus.error; _mintError=result['error']; });
      }
    } catch(e) {
      if (!mounted) return;
      setState(() { _mintStatus=_MintStatus.error; _mintError=e.toString(); });
    }
  }

  Widget _row(String l, String v, Color c) => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [Text(l,style:const TextStyle(color:Colors.white54,fontSize:13)),
               Text(v,style:TextStyle(color:c,fontSize:13,fontWeight:FontWeight.w600))]);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      body: SafeArea(child: Column(children: [
        Container(color:const Color(0xFF131929),padding:const EdgeInsets.symmetric(vertical:8),

          //child:Row(children:[
          //  IconButton(icon:const Icon(Icons.arrow_back,color:Colors.white),onPressed:()=>Navigator.pop(context)),
          //  const Expanded(child:Text('Аирдроп',style:TextStyle(color:Colors.white,fontSize:18,fontWeight:FontWeight.bold),textAlign:TextAlign.center)),
          //  const SizedBox(width:48),
          // ])),

          child:Row(children:[
            IconButton(
              icon:const Icon(Icons.arrow_back,color:Colors.white),
              onPressed:() {
                if (widget.onBack != null) {
                  widget.onBack!(); // Если открыто во вкладке — меняем индекс на кошелек
                } else if (Navigator.canPop(context)) {
                  Navigator.pop(context); // Если открыто как отдельная страница — закрываем стандартно
                }
              },
            ),
            const Expanded(child:Text('Аирдроп',style:TextStyle(color:Colors.white,fontSize:18,fontWeight:FontWeight.bold),textAlign:TextAlign.center)),
            const SizedBox(width:48),
          ])),



        Expanded(child: SingleChildScrollView(padding:const EdgeInsets.all(16),child:Column(children:[
          // Заголовок
          Container(width:double.infinity,padding:const EdgeInsets.symmetric(horizontal:14,vertical:10),
            decoration:BoxDecoration(color:Colors.black38,borderRadius:BorderRadius.circular(12),
              border:Border.all(color:Colors.greenAccent.withOpacity(0.3),width:1.5)),
            child:Column(children:[
              const Text('🚀 MEGA EVENT: GTA 6',style:TextStyle(fontSize:13,fontWeight:FontWeight.bold,color:Colors.cyanAccent)),
              const SizedBox(height:6),
              Text(_timeLeft,style:const TextStyle(fontSize:16,fontWeight:FontWeight.bold,color:Colors.orangeAccent,fontFamily:'monospace',letterSpacing:1.5)),
              const SizedBox(height:8),
              Row(mainAxisAlignment:MainAxisAlignment.center,children:[
                const Text('1 \$MEGA = ',style:TextStyle(color:Colors.cyanAccent,fontSize:11)),
                Image.asset('assets/mega.png',width:16,height:16,errorBuilder:(_,__,___)=>const SizedBox()),
                const SizedBox(width:4),
                Text('${_currentPrice.toStringAsFixed(6)} APT',style:const TextStyle(color:Colors.white,fontSize:14,fontWeight:FontWeight.bold)),
                const SizedBox(width:8),

                const Text('→ 0.1 APT',style:TextStyle(color:Colors.orangeAccent,fontSize:10)),
              ]),
              // === НАЧАЛО ДИЗАЙНА TOTAL SUPPLY ===
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('total_supply: ', style: TextStyle(color: Colors.orangeAccent, fontSize: 11)),
                  if (_isLoadingSupply && _totalSupply == null)
                    const SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.cyanAccent))
                  else
                    Text(
                      '${_totalSupply?.toStringAsFixed(2) ?? "0.00"} MEGA',
                      style: const TextStyle(color: Colors.cyanAccent, fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                ],
              ),
              // === КОНЕЦ ДИЗАЙНА TOTAL SUPPLY ===
            ])), 
          const SizedBox(height:12),



          // График
          _AnimatedMegaChart(currentPrice:_currentPrice),
          const SizedBox(height:20),
          // Минт
          if (_mintStatus==_MintStatus.idle||_mintStatus==_MintStatus.error)...[
            Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[
              const Text('Баланс APT:',style:TextStyle(color:Colors.white54,fontSize:13)),
              Text('${_aptBalance.toStringAsFixed(4)} APT',style:const TextStyle(color:Colors.white,fontSize:13,fontWeight:FontWeight.w600)),
            ]),
            const SizedBox(height:12),
            Container(decoration:BoxDecoration(color:const Color(0xFF131929),borderRadius:BorderRadius.circular(12),
              border:Border.all(color:const Color(0xFFFF6B6B).withOpacity(0.3))),
              child:TextField(controller:_ctrl,
                keyboardType:const TextInputType.numberWithOptions(decimal:true),
                inputFormatters:[FilteringTextInputFormatter.allow(RegExp(r'[\d.,]'))],
                style:const TextStyle(color:Colors.white,fontSize:18),
                decoration:InputDecoration(hintText:'0.00',hintStyle:const TextStyle(color:Colors.white24),
                  border:InputBorder.none,contentPadding:const EdgeInsets.symmetric(horizontal:16,vertical:14),
                  prefixIcon:Padding(padding:const EdgeInsets.all(10),
                    child:Image.asset('assets/mega.png',width:24,height:24,errorBuilder:(_,__,___)=>const Icon(Icons.token,color:Color(0xFFFF6B6B)))),
                  suffixText:'MEGA',suffixStyle:const TextStyle(color:Color(0xFFFF6B6B),fontWeight:FontWeight.bold)))),
            if (_megaAmt>0)...[
              const SizedBox(height:8),
              Container(padding:const EdgeInsets.all(10),decoration:BoxDecoration(color:Colors.white.withOpacity(0.04),borderRadius:BorderRadius.circular(10)),
                child:Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[
                  const Text('Стоимость:',style:TextStyle(color:Colors.white38,fontSize:12)),
                  Text('${_aptCost.toStringAsFixed(6)} APT',style:const TextStyle(color:Colors.orangeAccent,fontSize:14,fontWeight:FontWeight.bold)),
                ])),
            ],
            if (_mintStatus==_MintStatus.error&&_mintError!=null)...[
              const SizedBox(height:10),
              Container(width:double.infinity,padding:const EdgeInsets.all(12),
                decoration:BoxDecoration(color:Colors.redAccent.withOpacity(0.08),borderRadius:BorderRadius.circular(10),
                  border:Border.all(color:Colors.redAccent.withOpacity(0.2))),
                child:Text(_mintError!,style:const TextStyle(color:Colors.redAccent,fontSize:12,height:1.4),textAlign:TextAlign.center)),
            ],
            const SizedBox(height:16),
            SizedBox(width:double.infinity,child:FilledButton.icon(
              onPressed:_megaAmt>0?_doMint:null,
              style:FilledButton.styleFrom(backgroundColor:_megaAmt>0?Colors.greenAccent:Colors.greenAccent.withOpacity(0.3),
                padding:const EdgeInsets.symmetric(vertical:16),shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(14))),
              icon:const Icon(Icons.download_rounded,color:Colors.black,size:20),
              label:Text(_megaAmt>0?'Получить ${_megaAmt.toStringAsFixed(4)} MEGA':'Введите количество MEGA',
                style:const TextStyle(color:Colors.black,fontWeight:FontWeight.bold,fontSize:15)))),
          ] else if (_mintStatus==_MintStatus.loading)...[
            const Padding(padding:EdgeInsets.symmetric(vertical:32),child:Column(children:[
              CircularProgressIndicator(color:Colors.greenAccent,strokeWidth:2),
              SizedBox(height:16),
              Text('Минт MEGA...',style:TextStyle(color:Colors.white60,fontSize:14)),
              SizedBox(height:4),
              Text('Подождите ~10 секунд',style:TextStyle(color:Colors.white24,fontSize:12)),
            ])),
          ] else if (_mintStatus==_MintStatus.success)...[
            Container(width:double.infinity,padding:const EdgeInsets.all(20),
              decoration:BoxDecoration(color:Colors.greenAccent.withOpacity(0.06),borderRadius:BorderRadius.circular(14),
                border:Border.all(color:Colors.greenAccent.withOpacity(0.3))),
              child:Column(children:[
                const Icon(Icons.check_circle_outline,color:Colors.greenAccent,size:48),
                const SizedBox(height:12),
                const Text('Минт выполнен!',style:TextStyle(color:Colors.white,fontSize:18,fontWeight:FontWeight.bold)),
                const SizedBox(height:8),
                Text('${_mintedAmount.toStringAsFixed(4)} MEGA',style:const TextStyle(color:Colors.greenAccent,fontSize:24,fontWeight:FontWeight.bold)),
                const SizedBox(height:4),
                const Text('монеты на вашем кошельке',style:TextStyle(color:Colors.white38,fontSize:12)),
                if (_mintHash!=null)...[
                  const SizedBox(height:12),
                  const Text('TX Hash:',style:TextStyle(color:Colors.white24,fontSize:11)),
                  const SizedBox(height:4),
                  SelectableText(_mintHash!,style:const TextStyle(color:Colors.white38,fontSize:10,fontFamily:'monospace'),textAlign:TextAlign.center),
                ],
                const SizedBox(height:12),
                Text('Баланс APT: ${_aptBalance.toStringAsFixed(4)} APT',style:const TextStyle(color:Colors.white54,fontSize:12)),
                const SizedBox(height:16),



                Row(children:[
                  Expanded(child:OutlinedButton(
                    onPressed:() => setState(() {
                      _mintStatus = _MintStatus.idle;
                      _ctrl.text = '1'; // Вместо clear() возвращаем дефолтную единицу
                    }),
                    style:OutlinedButton.styleFrom(padding:const EdgeInsets.symmetric(vertical:12),
                      side:BorderSide(color:Colors.greenAccent.withOpacity(0.4)),shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(12))),
                    child:const Text('Ещё раз',style:TextStyle(color:Colors.greenAccent)))),
                  const SizedBox(width:12),
                  Expanded(child: OutlinedButton(
                    onPressed:() {
                      // Кнопка «Закрыть» теперь тоже просто сбрасывает статус экрана 
                      // и оставляет пользователя на странице аирдропа с цифрой 1
                      setState(() {
                        _mintStatus = _MintStatus.idle;
                        _mintHash = null;
                        _mintError = null;
                        _ctrl.text = '1'; // Устанавливаем дефолтную единицу
                      });
                    },
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical:12),
                      side: BorderSide(color: Colors.white.withOpacity(0.15)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))
                    ),
                    child: const Text('Закрыть', style: TextStyle(color: Colors.white54))
                  )),
                ]),


              ])),
          ],
          const SizedBox(height:32),
        ]))),
      ])),
    );
  }
}

enum _MintStatus { idle, loading, success, error }

class _AnimatedMegaChart extends StatefulWidget {
  final double currentPrice;
  const _AnimatedMegaChart({required this.currentPrice});
  @override
  State<_AnimatedMegaChart> createState() => _AnimatedMegaChartState();
}

class _AnimatedMegaChartState extends State<_AnimatedMegaChart> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  @override
  void initState(){super.initState();_ctrl=AnimationController(vsync:this,duration:const Duration(seconds:12))..repeat();}
  @override
  void dispose(){_ctrl.dispose();super.dispose();}
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(animation:_ctrl,builder:(_,__)=>Container(
      width:double.infinity,height:200,
      decoration:BoxDecoration(color:Colors.black,borderRadius:BorderRadius.circular(15),
        border:Border.all(color:Colors.greenAccent.withOpacity(0.2))),
      child:CustomPaint(painter:_MegaChartPainter(_ctrl.value,widget.currentPrice))));
  }
}

class _MegaChartPainter extends CustomPainter {
  final double anim; final double currentPrice;
  _MegaChartPainter(this.anim,this.currentPrice);
  @override
  void paint(Canvas canvas,Size size){
    final w=size.width;final h=size.height-40;const px=35.0;final cw=w-px*2;final ch=h-60;
    Offset pos(double t)=>Offset(px+t*cw,(h-20)-(t*ch));
    void txt(String s,Offset o,Color c,{double fs=10,bool bold=false}){
      final tp=TextPainter(text:TextSpan(text:s,style:TextStyle(color:c,fontSize:fs,fontWeight:bold?FontWeight.bold:FontWeight.normal,fontFamily:'monospace')),textDirection:TextDirection.ltr)..layout();
      tp.paint(canvas,o);
    }
    final grid=Paint()..color=Colors.white.withOpacity(0.2)..strokeWidth=0.8;
    for(int i=0;i<=3;i++){final y=(h-20)-(i*ch/3);canvas.drawLine(Offset(px,y),Offset(w-px,y),grid);}
    txt('0.001',const Offset(10,10),Colors.greenAccent.withOpacity(0.6));
    txt('0.1',Offset(w-35,10),Colors.greenAccent,bold:true);
    final prog=((currentPrice-_startPrice)/(_endPrice-_startPrice)).clamp(0.0,1.0);
    final cp=pos(prog);final pulse=math.sin(anim*math.pi*2*3);
    canvas.drawLine(pos(0),pos(1),Paint()..color=Colors.white.withOpacity(0.12)..strokeWidth=2);
    for(int i=1;i<=3;i++){canvas.drawCircle(cp,(12+pulse*8)*i,Paint()..color=Colors.greenAccent.withOpacity((0.3/i).clamp(0.0,1.0))..maskFilter=MaskFilter.blur(BlurStyle.normal,10*i.toDouble()));}
    canvas.drawCircle(cp,8+pulse*4,Paint()..color=Colors.greenAccent..maskFilter=const MaskFilter.blur(BlurStyle.normal,5));
    canvas.drawCircle(cp,4,Paint()..color=Colors.white);
    txt('${currentPrice.toStringAsFixed(6)} APT',Offset(cp.dx-35,cp.dy-42),Colors.greenAccent,fs:11,bold:true);
    final ct=prog+(anim*(1.0-prog));final cp2=pos(ct);
    canvas.drawLine(cp,cp2,Paint()..shader=LinearGradient(colors:[Colors.greenAccent.withOpacity(0),Colors.greenAccent.withOpacity(0.5)]).createShader(Rect.fromPoints(cp,cp2))..strokeWidth=12..maskFilter=const MaskFilter.blur(BlurStyle.normal,8));
    canvas.drawLine(cp,cp2,Paint()..shader=LinearGradient(colors:[Colors.greenAccent.withOpacity(0),Colors.greenAccent,Colors.white],stops:const[0.0,0.8,1.0]).createShader(Rect.fromPoints(cp,cp2))..strokeWidth=4.5..strokeCap=StrokeCap.round);
    canvas.drawCircle(cp2,12+pulse*8,Paint()..color=Colors.greenAccent.withOpacity(0.6)..maskFilter=const MaskFilter.blur(BlurStyle.normal,8));
    canvas.drawCircle(cp2,4,Paint()..color=Colors.white);
    final months=['Янв','Мар','Май','Июл','Сен','Ноя'];
    for(int i=0;i<months.length;i++){final t=i/(months.length-1);final x=px+t*cw;canvas.drawLine(Offset(x,h-20),Offset(x,h-20-ch),grid);txt(months[i],Offset(x-12,h+8),Colors.white.withOpacity(0.7),fs:10);}
  }
  @override
  bool shouldRepaint(covariant _MegaChartPainter old)=>true;
}

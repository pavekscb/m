import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:convert/convert.dart' as convert;
import 'package:pointycastle/export.dart' as pc;
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'nft_spisok.dart';

// ── Конфиг ───────────────────────────────────────────────────
const String _aptosNode     = 'https://fullnode.mainnet.aptoslabs.com/v1';
const String _aptosIndexer  = 'https://api.mainnet.aptoslabs.com/v1/graphql';
const String _adminAddress  = '0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3';
const String _megaCoin      = '0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3::mega_coin::MEGA';
const double _mintFee       = 0.01;
const int    _megaDecimals  = 8;
const int    _maxFileBytes  = 100 * 1024;
const String _nftCollection = 'MEGA Wallet NFT';

// ══════════════════════════════════════════════════════════════
// Ed25519
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

int pow10(int n) { int r=1; for(int i=0;i<n;i++) r*=10; return r; }

// ── Получить адрес из приватного ключа ───────────────────────
String _addrFromPriv(String privateKeyHex) {
  final priv = Uint8List.fromList(convert.hex.decode(privateKeyHex.replaceFirst('0x','')));
  final pubKey = _pub(priv);
  final sha3 = pc.SHA3Digest(256);
  final inp = Uint8List(33); inp.setRange(0,32,pubKey); inp[32]=0x00;
  sha3.update(inp,0,33); final addrBytes=Uint8List(32); sha3.doFinal(addrBytes,0);
  return '0x${convert.hex.encode(addrBytes)}';
}

// ══════════════════════════════════════════════════════════════
// Универсальная отправка транзакции через encode_submission
// ══════════════════════════════════════════════════════════════
Future<Map<String,dynamic>> _sendTx({
  required String privateKeyHex,
  required Map<String,dynamic> payload,
  int maxGas = 10000,
}) async {
  final priv = Uint8List.fromList(convert.hex.decode(privateKeyHex.replaceFirst('0x','')));
  final pubKey = _pub(priv);
  final senderAddr = _addrFromPriv(privateKeyHex);

  final results = await Future.wait([
    http.get(Uri.parse('$_aptosNode/accounts/$senderAddr'), headers: {'Accept':'application/json'}).timeout(const Duration(seconds:15)),
    http.get(Uri.parse(_aptosNode), headers: {'Accept':'application/json'}).timeout(const Duration(seconds:10)),
  ]);
  final accR = results[0] as http.Response;
  final ledR = results[1] as http.Response;
  if (accR.statusCode != 200) throw Exception('Аккаунт не найден (${accR.statusCode})');
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

  if (encResp.statusCode != 200) throw Exception('encode_submission: ${encResp.body}');

  final msgHex = jsonDecode(encResp.body).toString();
  final msgBytes = Uint8List.fromList(convert.hex.decode(msgHex.replaceFirst('0x','')));
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
  if (resp.statusCode != 202) {
    debugPrint('TX ERROR: ${resp.body}');
    throw Exception(data['message'] ?? data['error_code'] ?? resp.body);
  }

  final hash = data['hash']?.toString() ?? '';
  for (int i=0; i<15; i++) {
    await Future.delayed(const Duration(seconds:1));
    try {
      final c = await http.get(Uri.parse('$_aptosNode/transactions/by_hash/$hash'),
        headers: {'Accept':'application/json'}).timeout(const Duration(seconds:5));
      if (c.statusCode == 200) {
        final tx = jsonDecode(c.body);
        debugPrint('TX STATUS: ${tx['vm_status']}');
        if (tx['success'] == true) return {'success':true,'hash':hash};
        final vm = tx['vm_status']?.toString() ?? '';
        if (vm.isNotEmpty && vm != 'pending') return {'success':false,'error':vm};
      }
    } catch(_) {}
  }
  return {'success':true,'hash':hash};
}

// ── Проверка и автосоздание коллекции ────────────────────────
Future<bool> _collectionExists(String ownerAddress) async {
  try {
    const query = r'''
      query CheckCollection($owner: String!, $name: String!) {
        current_collections_v2(
          where: {
            creator_address: {_eq: $owner},
            collection_name: {_eq: $name}
          }
          limit: 1
        ) {
          collection_id
        }
      }
    ''';
    final resp = await http.post(
      Uri.parse(_aptosIndexer),
      headers: {'Content-Type':'application/json'},
      body: jsonEncode({
        'query': query,
        'variables': {'owner': ownerAddress, 'name': _nftCollection},
      }),
    ).timeout(const Duration(seconds:10));
    if (resp.statusCode != 200) return false;
    final data = jsonDecode(resp.body);
    final cols = data['data']['current_collections_v2'] as List;
    return cols.isNotEmpty;
  } catch(_) {
    return false;
  }
}

Future<void> _ensureCollection(String privateKeyHex) async {
  final ownerAddr = _addrFromPriv(privateKeyHex);
  final exists = await _collectionExists(ownerAddr);
  if (exists) return;

  // Создаём коллекцию автоматически
  final result = await _sendTx(
    privateKeyHex: privateKeyHex,
    payload: {
      'type': 'entry_function_payload',
      'function': '0x4::aptos_token::create_collection',
      'type_arguments': [],
      'arguments': [
        'MEGA Wallet NFT Collection', // description
        '10',                      // max_supply
        _nftCollection,               // name
        'https://megawallet.io',       // uri
        true,  // mutable_description
        true,  // mutable_royalty
        true,  // mutable_uri
        true,  // mutable_token_description
        false, // mutable_token_name
        true,  // mutable_token_properties
        true,  // mutable_token_uri
        true,  // tokens_burnable_by_creator
        false, // tokens_freezable_by_creator
        '0',   // royalty_numerator
        '1',   // royalty_denominator
      ],
    },
    maxGas: 15000,
  );
  if (result['success'] != true) {
    throw Exception('Не удалось создать коллекцию: ${result['error']}');
  }
  // Ждём немного чтобы коллекция проиндексировалась
  await Future.delayed(const Duration(seconds: 2));
}

// ══════════════════════════════════════════════════════════════
// AboutPage
// ══════════════════════════════════════════════════════════════
class AboutPage extends StatefulWidget {
  final String? privateKeyHex;
  const AboutPage({super.key, this.privateKeyHex});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  File? _image;
  int _imageBytes = 0;
  final _nameCtrl = TextEditingController();
  bool _minting = false;
  String _status = '';
  String? _txHash;
  int _nftListKey = 0;

  String? get _userAddress {
    if (widget.privateKeyHex == null || widget.privateKeyHex!.isEmpty) return null;
    try { return _addrFromPriv(widget.privateKeyHex!); } catch(_) { return null; }
  }

  // ── Выбор и сжатие фото ──────────────────────────────────
  Future<void> _pick() async {
    const typeGroup = XTypeGroup(
      label: 'images',
      extensions: ['jpg', 'jpeg', 'png', 'webp'],
    );
    final file = await openFile(acceptedTypeGroups: [typeGroup]);
    if (file == null) return;

    final isGif = file.path.toLowerCase().endsWith('.gif');

    if (isGif) {
      // GIF не сжимаем — просто проверяем размер
      final f = File(file.path);
      final size = await f.length();
      if (size > _maxFileBytes) {
        _show('❌ GIF слишком большой: ${(size/1024).toStringAsFixed(1)} КБ. Максимум 100 КБ.');
        setState(() { _image = null; _imageBytes = 0; });
        return;
      }
      setState(() { _image = f; _imageBytes = size; _status = ''; _txHash = null; });
      return;
    }

    // Для JPG/PNG/WEBP — сжатие
    _show('🗜 Сжатие изображения...');
    final compressed = await FlutterImageCompress.compressWithFile(
      file.path, minWidth: 512, minHeight: 512, quality: 70,
    );
    if (compressed == null) { _show('❌ Не удалось сжать файл'); return; }

    final tmpFile = File('${Directory.systemTemp.path}/nft_compressed.jpg');
    await tmpFile.writeAsBytes(compressed);

    final size = compressed.length;
    if (size > _maxFileBytes) {
      _show('❌ После сжатия: ${(size/1024).toStringAsFixed(1)} КБ > 100 КБ. Выберите другое фото.');
      setState(() { _image = null; _imageBytes = 0; });
      return;
    }
    setState(() { _image = tmpFile; _imageBytes = size; _status = ''; _txHash = null; });
  }

  // ── Минт ─────────────────────────────────────────────────
  Future<void> _mint() async {
    if (_image == null) { _show('❌ Выберите изображение'); return; }
    if (_nameCtrl.text.trim().isEmpty) { _show('❌ Введите название NFT'); return; }
    if (widget.privateKeyHex == null || widget.privateKeyHex!.isEmpty) {
      _show('❌ Приватный ключ не передан'); return;
    }
    setState(() { _minting = true; _txHash = null; });
    try {
      // 1. Оплата ПЕРВОЙ — защита от спама
      _show('💸 Оплата минта (0.01 MEGA)...');
      await _payFee();

      // 2. Загрузка картинки после успешной оплаты
      _show('⬆ Загрузка картинки на IPFS...');
      final imageIpfs = await _uploadFile(_image!);

      // 3. Метадата
      _show('📄 Загрузка метадаты...');
      final metaUrl = await _uploadMeta(
        name: _nameCtrl.text.trim(),
        imageIpfs: imageIpfs,
      );

      // 4. Автосоздание коллекции если нет
      _show('📁 Проверка коллекции...');
      await _ensureCollection(widget.privateKeyHex!);

      // 5. Минт
      _show('⛏ Минт NFT на Aptos...');
      final result = await _sendTx(
        privateKeyHex: widget.privateKeyHex!,
        payload: {
          'type': 'entry_function_payload',
          'function': '0x4::aptos_token::mint',
          'type_arguments': [],
          'arguments': [
            _nftCollection,
            '',
            _nameCtrl.text.trim(),
            metaUrl,
            <String>[],
            <String>[],
            <String>[],
          ],
        },
        maxGas: 10000,
      );

      if (result['success'] == true) {
        setState(() {
          _txHash = result['hash'];
          _status = '✅ NFT успешно создан!';
          _minting = false;
          _image = null;
          _imageBytes = 0;
          _nameCtrl.clear();
        });
        await Future.delayed(const Duration(seconds: 4));
        if (mounted) setState(() { _status = ''; _txHash = null; _nftListKey++; });
      } else {
        _show('❌ ${result['error']}');
        setState(() => _minting = false);
      }
    } catch(e) {
      _show('❌ $e');
      setState(() => _minting = false);
    }
  }

  // ── Оплата 0.01 MEGA ──────────────────────────────────────
  Future<void> _payFee() async {
    final amountRaw = (_mintFee * pow10(_megaDecimals)).round();
    final result = await _sendTx(
      privateKeyHex: widget.privateKeyHex!,
      payload: {
        'type': 'entry_function_payload',
        'function': '0x1::coin::transfer',
        'type_arguments': [_megaCoin],
        'arguments': [_adminAddress, amountRaw.toString()],
      },
      maxGas: 5000,
    );
    if (result['success'] != true) throw Exception('Ошибка оплаты: ${result['error']}');
  }

  void _show(String s) => setState(() => _status = s);

  // ── Pinata ────────────────────────────────────────────────
  Future<String> _uploadFile(File file) async {
    final isGif = file.path.toLowerCase().endsWith('.gif');
    final ext = isGif ? 'gif' : 'jpeg';
    final req = http.MultipartRequest('POST',
      Uri.parse('https://api.pinata.cloud/pinning/pinFileToIPFS'))
      ..headers['Authorization'] = 'Bearer $_pinataJwt'
      ..files.add(await http.MultipartFile.fromPath('file', file.path,
        contentType: MediaType('image', ext)));
    final resp = await req.send();
    final body = await resp.stream.bytesToString();
    if (resp.statusCode != 200) throw Exception('Pinata upload: $body');
    return 'ipfs://${jsonDecode(body)['IpfsHash']}';
  }

  Future<String> _uploadMeta({required String name, required String imageIpfs}) async {
    final isGif = imageIpfs.toLowerCase().contains('.gif') ||
                  _image?.path.toLowerCase().endsWith('.gif') == true;
    final mimeType = isGif ? 'image/gif' : 'image/jpeg';
    final resp = await http.post(
      Uri.parse('https://api.pinata.cloud/pinning/pinJSONToIPFS'),
      headers: {'Authorization':'Bearer $_pinataJwt','Content-Type':'application/json'},
      body: jsonEncode({
        'pinataContent': {
          'name': name,
          'description': '',
          'image': imageIpfs,
          'attributes': [],
          'properties': {'files':[{'uri':imageIpfs,'type':mimeType}],'category':'image'},
        },
        'pinataMetadata': {'name':'$name.json'},
      }),
    );
    if (resp.statusCode != 200) throw Exception('Pinata meta: ${resp.body}');
    // return 'https://gateway.pinata.cloud/ipfs/${jsonDecode(resp.body)['IpfsHash']}';
    return 'https://ipfs.io/ipfs/${jsonDecode(resp.body)['IpfsHash']}';
  }

  // ── UI ────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20,60,20,16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

          // Заголовок
          Row(children: [
            const Text('NFT', style: TextStyle(
              color: Colors.cyanAccent, fontSize: 22,
              fontWeight: FontWeight.bold, letterSpacing: 2,
            )),
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal:8,vertical:3),
              decoration: BoxDecoration(
                color: Colors.cyanAccent.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.cyanAccent.withOpacity(0.3)),
              ),
              child: const Text('Aptos · IPFS', style: TextStyle(color: Colors.cyanAccent, fontSize:10)),
            ),
          ]),
          const SizedBox(height:4),
          const Text('Минт NFT · 0.01 MEGA · авто-сжатие',
            style: TextStyle(color: Colors.white38, fontSize:12)),
          const SizedBox(height:20),

          // Фото
          GestureDetector(
            onTap: _minting ? null : _pick,
            child: Container(
              height:110, width:double.infinity,
              decoration: BoxDecoration(
                color: const Color(0xFF151B2E),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: _image!=null ? Colors.cyanAccent.withOpacity(0.5) : Colors.white12,
                  width:1.5,
                ),
              ),
              child: _image!=null
                ? Stack(children:[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(13),
                      child: Image.file(_image!, fit:BoxFit.cover,
                        width:double.infinity, height:double.infinity),
                    ),
                    Positioned(bottom:6,right:6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal:7,vertical:3),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.65),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text('${(_imageBytes/1024).toStringAsFixed(1)} КБ',
                          style: const TextStyle(color:Colors.white70, fontSize:10)),
                      ),
                    ),
                  ])
                : const Column(mainAxisAlignment:MainAxisAlignment.center, children:[
                    Icon(Icons.add_photo_alternate_outlined, color:Colors.cyanAccent, size:32),
                    SizedBox(height:6),
                    Text('Нажмите чтобы выбрать фото',
                      style:TextStyle(color:Colors.white38, fontSize:12)),
                    SizedBox(height:2),
                    Text('JPG / PNG / WEBP · авто-сжатие до 100 КБ',
                      style:TextStyle(color:Colors.white24, fontSize:10)),
                  ]),
            ),
          ),
          const SizedBox(height:12),

          _field(_nameCtrl, 'Название NFT'),
          const SizedBox(height:12),

          

          // Статус
          if (_status.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(bottom:12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _status.contains('❌')
                  ? Colors.red.withOpacity(0.1)
                  : Colors.cyanAccent.withOpacity(0.08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: _status.contains('❌')
                  ? Colors.redAccent.withOpacity(0.3)
                  : Colors.cyanAccent.withOpacity(0.2)),
              ),
              child: Row(children:[
                if (_minting && !_status.contains('✅') && !_status.contains('❌'))
                  const SizedBox(width:14,height:14,
                    child: CircularProgressIndicator(color:Colors.cyanAccent, strokeWidth:2)),
                if (_minting && !_status.contains('✅') && !_status.contains('❌'))
                  const SizedBox(width:10),
                Expanded(child: Text(_status, style: TextStyle(
                  color: _status.contains('❌') ? Colors.redAccent : Colors.cyanAccent,
                  fontSize:13,
                ))),
              ]),
            ),

          

          // Кнопка
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _minting ? null : _mint,
              icon: const Icon(Icons.rocket_launch, size:18),
              label: Text(_minting ? 'Минтинг...' : '⛏  Минт NFT  (0.01 MEGA)',
                style: const TextStyle(fontWeight:FontWeight.bold, fontSize:14)),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.cyanAccent,
                foregroundColor: Colors.black,
                disabledBackgroundColor: Colors.cyanAccent.withOpacity(0.3),
                padding: const EdgeInsets.symmetric(vertical:13),
                shape: RoundedRectangleBorder(borderRadius:BorderRadius.circular(12)),
              ),
            ),
          ),

          const SizedBox(height:16),
          NftSpisok(
            key: ValueKey(_nftListKey),
            address: _userAddress,
            privateKeyHex: widget.privateKeyHex,
          ),
        ]),
      ),
    );
  }

  Widget _field(TextEditingController ctrl, String hint, {int maxLines=1}) {
    return TextField(
      controller: ctrl, maxLines:maxLines, enabled:!_minting,
      style: const TextStyle(color:Colors.white),
      decoration: InputDecoration(
        hintText: hint, hintStyle: const TextStyle(color:Colors.white38),
        filled:true, fillColor: const Color(0xFF151B2E),
        border: OutlineInputBorder(borderRadius:BorderRadius.circular(10),
          borderSide: const BorderSide(color:Colors.white12)),
        enabledBorder: OutlineInputBorder(borderRadius:BorderRadius.circular(10),
          borderSide: const BorderSide(color:Colors.white12)),
        focusedBorder: OutlineInputBorder(borderRadius:BorderRadius.circular(10),
          borderSide: const BorderSide(color:Colors.cyanAccent, width:1.5)),
        disabledBorder: OutlineInputBorder(borderRadius:BorderRadius.circular(10),
          borderSide: const BorderSide(color:Colors.white12)),
      ),
    );
  }
}

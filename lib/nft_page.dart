// ══════════════════════════════════════════════════════════════
// nft_page.dart — NFT вкладка: просмотр, минт, отправка
// Хранилище: Pinata IPFS | Блокчейн: Aptos Digital Asset standard
// ══════════════════════════════════════════════════════════════
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:image_picker/image_picker.dart';
import 'package:convert/convert.dart' as convert;
import 'package:pointycastle/export.dart' as pc;

// ── Конфиг ───────────────────────────────────────────────────
const String _pinataJwt   = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJ1c2VySW5mb3JtYXRpb24iOnsiaWQiOiIzMTNiNWIxMC05ZDA1LTRkZGMtYTkzYi0xZjRiYTZkMWFjNmMiLCJlbWFpbCI6InBhdmVrc2NiQGdtYWlsLmNvbSIsImVtYWlsX3ZlcmlmaWVkIjp0cnVlLCJwaW5fcG9saWN5Ijp7InJlZ2lvbnMiOlt7ImRlc2lyZWRSZXBsaWNhdGlvbkNvdW50IjoxLCJpZCI6IkZSQTEifSx7ImRlc2lyZWRSZXBsaWNhdGlvbkNvdW50IjoxLCJpZCI6Ik5ZQzEifV0sInZlcnNpb24iOjF9LCJtZmFfZW5hYmxlZCI6ZmFsc2UsInN0YXR1cyI6IkFDVElWRSJ9LCJhdXRoZW50aWNhdGlvblR5cGUiOiJzY29wZWRLZXkiLCJzY29wZWRLZXlLZXkiOiIwM2EzOTUzNWFkMDYxNzdkYjlhOSIsInNjb3BlZEtleVNlY3JldCI6IjZjZGRhYmU1Yzc4ZWY3MWMwYzk4MTA4MTllNzVjMWM4OGZhMDhhMmRhZTkyYjdkZDM4MzBlMzU2NmQ3Nzk2MjciLCJleHAiOjE4MTEyMjAxODF9.bT3zxoaFukdcFA66--bheRkOhwbUQpVwB8NT2EZrhaY';
const String _aptosNode   = 'https://fullnode.mainnet.aptoslabs.com/v1';
const String _aptosIndexer= 'https://api.mainnet.aptoslabs.com/v1/graphql';
const String _nftCollection = 'MEGA Wallet NFT'; // имя коллекции

// ══════════════════════════════════════════════════════════════
// Ed25519 (скопировано из send_page.dart)
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

Uint8List _nftPub(Uint8List seed) {
  final s=pc.SHA512Digest(); final h=Uint8List(64);
  s.update(seed,0,32); s.doFinal(h,0);
  h[0]&=248; h[31]&=127; h[31]|=64;
  BigInt a=BigInt.zero; for(int i=0;i<32;i++) a+=BigInt.from(h[i])<<(8*i);
  return _ep(_sm(_bp(),a));
}

Uint8List _nftSign(Uint8List msg, Uint8List seed) {
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

// ── BCS helpers (из send_page.dart) ──────────────────────────
Uint8List _uleb(int v){final b=<int>[];do{int x=v&0x7F;v>>=7;if(v!=0)x|=0x80;b.add(x);}while(v!=0);return Uint8List.fromList(b);}
Uint8List _bcsStr(String s){final e=utf8.encode(s);return Uint8List.fromList([..._uleb(e.length),...e]);}
Uint8List _u64le(int v){final b=ByteData(8);b.setUint64(0,v,Endian.little);return b.buffer.asUint8List();}
Uint8List _bcsAddr(String a)=>Uint8List.fromList(convert.hex.decode(a.replaceFirst('0x','').padLeft(64,'0')));

// ── Отправка произвольной транзакции (BCS подпись) ────────────
Future<Map<String,dynamic>> _submitTx({
  required String privateKeyHex,
  required Map<String,dynamic> payload,
  required Uint8List payloadBytes,
  int maxGas = 10000,
}) async {
  final priv = Uint8List.fromList(convert.hex.decode(privateKeyHex.replaceFirst('0x','')));
  final pubKey = _nftPub(priv);
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
  if (accR.statusCode != 200) throw Exception('Аккаунт не найден: ${accR.statusCode}');
  final seqNum = int.parse(jsonDecode(accR.body)['sequence_number'].toString());
  final chainId = int.parse(jsonDecode(ledR.body)['chain_id'].toString());
  final exp = (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 600;

  final rawTx = Uint8List.fromList([
    ..._bcsAddr(senderAddr), ..._u64le(seqNum), ...payloadBytes,
    ..._u64le(maxGas), ..._u64le(100), ..._u64le(exp), chainId,
  ]);

  const prefix = 'APTOS::RawTransaction';
  final pb = utf8.encode(prefix) as Uint8List;
  final sha3b = pc.SHA3Digest(256); sha3b.update(pb,0,pb.length);
  final ph = Uint8List(32); sha3b.doFinal(ph,0);
  final sig = _nftSign(Uint8List.fromList([...ph,...rawTx]), priv);

  final body = jsonEncode({
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
  });

  final resp = await http.post(
    Uri.parse('$_aptosNode/transactions'),
    headers: {'Content-Type':'application/json','Accept':'application/json'},
    body: body,
  ).timeout(const Duration(seconds:20));
  final data = jsonDecode(resp.body);
  if (resp.statusCode == 202) {
    final hash = data['hash']?.toString() ?? '';
    for (int i=0; i<10; i++) {
      await Future.delayed(const Duration(seconds:1));
      try {
        final c = await http.get(Uri.parse('$_aptosNode/transactions/by_hash/$hash'),
          headers: {'Accept':'application/json'}).timeout(const Duration(seconds:5));
        if (c.statusCode == 200) {
          final tx = jsonDecode(c.body);
          if (tx['success'] == true) return {'success':true,'hash':hash};
          final vm = tx['vm_status']?.toString() ?? '';
          if (vm.isNotEmpty && vm != 'pending') return {'success':false,'error':'VM: $vm'};
        }
      } catch(_) {}
    }
    return {'success':true,'hash':hash};
  }
  final msg = data['message'] ?? data['error_code'] ?? resp.body;
  throw Exception(msg);
}

// ══════════════════════════════════════════════════════════════
// Модель NFT
// ══════════════════════════════════════════════════════════════
class NftItem {
  final String tokenDataId; // объект address для DA standard
  final String name;
  final String description;
  final String imageUrl;
  final String collectionName;

  NftItem({
    required this.tokenDataId,
    required this.name,
    required this.description,
    required this.imageUrl,
    required this.collectionName,
  });
}

// ══════════════════════════════════════════════════════════════
// NftPage
// ══════════════════════════════════════════════════════════════
class NftPage extends StatefulWidget {
  final String walletAddress;
  final String privateKeyHex;

  const NftPage({
    super.key,
    required this.walletAddress,
    required this.privateKeyHex,
  });

  @override
  State<NftPage> createState() => _NftPageState();
}

class _NftPageState extends State<NftPage> {
  List<NftItem> _nfts = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadNfts();
  }

  Future<void> _loadNfts() async {
    setState(() { _loading = true; _error = null; });
    try {
      const query = r'''
        query GetNFTs($owner: String!) {
          current_token_ownerships_v2(
            where: {owner_address: {_eq: $owner}, amount: {_gt: "0"}}
            limit: 50
          ) {
            current_token_data {
              token_data_id
              token_name
              description
              token_uri
              current_collection { collection_name }
            }
          }
        }
      ''';
      final resp = await http.post(
        Uri.parse(_aptosIndexer),
        headers: {'Content-Type':'application/json'},
        body: jsonEncode({'query': query, 'variables': {'owner': widget.walletAddress}}),
      ).timeout(const Duration(seconds: 15));

      if (resp.statusCode != 200) throw Exception('Indexer: ${resp.statusCode}');
      final data = jsonDecode(resp.body);
      final ownerships = data['data']['current_token_ownerships_v2'] as List;

      final nfts = <NftItem>[];
      for (final item in ownerships) {
        final td = item['current_token_data'];
        if (td == null) continue;
        String uri = td['token_uri'] ?? '';
        // IPFS → gateway
        if (uri.startsWith('ipfs://')) {
          uri = uri.replaceFirst('ipfs://', 'https://gateway.pinata.cloud/ipfs/');
        }
        // Если это метадата JSON — резолвим image
        String imageUrl = uri;
        if (uri.startsWith('http') && !_isImageUrl(uri)) {
          imageUrl = await _resolveImage(uri);
        }
        nfts.add(NftItem(
          tokenDataId: td['token_data_id'] ?? '',
          name: td['token_name'] ?? 'Без названия',
          description: td['description'] ?? '',
          imageUrl: imageUrl,
          collectionName: td['current_collection']?['collection_name'] ?? '',
        ));
      }
      setState(() { _nfts = nfts; _loading = false; });
    } catch(e) {
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  bool _isImageUrl(String url) {
    final l = url.toLowerCase().split('?')[0];
    return l.endsWith('.png')||l.endsWith('.jpg')||l.endsWith('.jpeg')||
           l.endsWith('.gif')||l.endsWith('.webp')||l.endsWith('.svg');
  }

  Future<String> _resolveImage(String metaUrl) async {
    try {
      final r = await http.get(Uri.parse(metaUrl)).timeout(const Duration(seconds:6));
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body);
        String img = j['image'] ?? metaUrl;
        if (img.startsWith('ipfs://')) {
          img = img.replaceFirst('ipfs://', 'https://gateway.pinata.cloud/ipfs/');
        }
        return img;
      }
    } catch(_) {}
    return metaUrl;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      body: Column(children: [
        _buildHeader(),
        Expanded(child: _buildBody()),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openMint(context),
        backgroundColor: Colors.cyanAccent,
        foregroundColor: Colors.black,
        icon: const Icon(Icons.add_photo_alternate),
        label: const Text('Создать NFT', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16,50,16,12),
      color: const Color(0xFF111111),
      child: Row(children: [
        const Text('NFT', style: TextStyle(
          color: Colors.cyanAccent, fontSize: 18,
          fontWeight: FontWeight.bold, letterSpacing: 2,
        )),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal:8,vertical:2),
          decoration: BoxDecoration(
            color: Colors.cyanAccent.withOpacity(0.1),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.cyanAccent.withOpacity(0.3)),
          ),
          child: const Text('IPFS · Pinata', style: TextStyle(color: Colors.cyanAccent, fontSize: 10)),
        ),
        const Spacer(),
        if (_nfts.isNotEmpty)
          Text('${_nfts.length} NFT', style: const TextStyle(color: Colors.white38, fontSize: 12)),
        const SizedBox(width: 8),
        IconButton(
          icon: const Icon(Icons.refresh, color: Colors.cyanAccent, size: 20),
          onPressed: _loadNfts, padding: EdgeInsets.zero,
        ),
      ]),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator(color: Colors.cyanAccent));
    if (_error != null) return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
      const SizedBox(height:12),
      const Text('Ошибка загрузки', style: TextStyle(color: Colors.white70)),
      TextButton(onPressed: _loadNfts, child: const Text('Повторить')),
    ]));
    if (_nfts.isEmpty) return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.image_not_supported_outlined, color: Colors.white24, size: 64),
      const SizedBox(height:16),
      const Text('NFT не найдены', style: TextStyle(color: Colors.white38, fontSize: 16)),
      const SizedBox(height:8),
      const Text('Нажмите «Создать NFT» чтобы минтнуть первый',
        style: TextStyle(color: Colors.white24, fontSize: 12), textAlign: TextAlign.center),
    ]));
    return RefreshIndicator(
      color: Colors.cyanAccent, backgroundColor: const Color(0xFF1A1F2E),
      onRefresh: _loadNfts,
      child: GridView.builder(
        padding: const EdgeInsets.fromLTRB(12,12,12,80),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2, crossAxisSpacing: 10, mainAxisSpacing: 10, childAspectRatio: 0.78,
        ),
        itemCount: _nfts.length,
        itemBuilder: (_,i) => _NftCard(
          nft: _nfts[i],
          onSend: () => _openSend(context, _nfts[i]),
        ),
      ),
    );
  }

  void _openMint(BuildContext context) {
    showModalBottomSheet(
      context: context, isScrollControlled: true, backgroundColor: Colors.transparent,
      builder: (_) => _MintSheet(
        privateKeyHex: widget.privateKeyHex,
        onMinted: () { Navigator.pop(context); Future.delayed(const Duration(seconds:3), _loadNfts); },
      ),
    );
  }

  void _openSend(BuildContext context, NftItem nft) {
    showModalBottomSheet(
      context: context, isScrollControlled: true, backgroundColor: Colors.transparent,
      builder: (_) => _SendSheet(
        nft: nft, privateKeyHex: widget.privateKeyHex,
        onSent: () { Navigator.pop(context); Future.delayed(const Duration(seconds:3), _loadNfts); },
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
// _NftCard
// ══════════════════════════════════════════════════════════════
class _NftCard extends StatelessWidget {
  final NftItem nft;
  final VoidCallback onSend;
  const _NftCard({required this.nft, required this.onSend});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF151B2E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.cyanAccent.withOpacity(0.15)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
          child: nft.imageUrl.isNotEmpty
            ? Image.network(nft.imageUrl, fit: BoxFit.cover, width: double.infinity,
                errorBuilder: (_,__,___) => _placeholder(),
                loadingBuilder: (_,child,prog) => prog==null ? child
                  : Container(color: const Color(0xFF1A2035),
                      child: const Center(child: CircularProgressIndicator(color: Colors.cyanAccent, strokeWidth:2))),
              )
            : _placeholder(),
        )),
        Padding(padding: const EdgeInsets.all(8), child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(nft.name, style: const TextStyle(color: Colors.white, fontSize:12, fontWeight: FontWeight.bold),
              maxLines:1, overflow: TextOverflow.ellipsis),
            if (nft.collectionName.isNotEmpty)
              Text(nft.collectionName, style: const TextStyle(color: Colors.white38, fontSize:10),
                maxLines:1, overflow: TextOverflow.ellipsis),
            const SizedBox(height:4),
            GestureDetector(
              onTap: onSend,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal:8,vertical:3),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.cyanAccent.withOpacity(0.4)),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.send, color: Colors.cyanAccent, size:10),
                  SizedBox(width:4),
                  Text('Отправить', style: TextStyle(color: Colors.cyanAccent, fontSize:10)),
                ]),
              ),
            ),
          ],
        )),
      ]),
    );
  }

  Widget _placeholder() => Container(
    color: const Color(0xFF1A2035),
    child: const Center(child: Icon(Icons.image_outlined, color: Colors.white24, size:40)),
  );
}

// ══════════════════════════════════════════════════════════════
// _MintSheet
// ══════════════════════════════════════════════════════════════
class _MintSheet extends StatefulWidget {
  final String privateKeyHex;
  final VoidCallback onMinted;
  const _MintSheet({required this.privateKeyHex, required this.onMinted});

  @override
  State<_MintSheet> createState() => _MintSheetState();
}

class _MintSheetState extends State<_MintSheet> {
  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  File? _imageFile;
  bool _minting = false;
  String _status = '';

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery, maxWidth:1024, maxHeight:1024, imageQuality:85,
    );
    if (picked != null) setState(() => _imageFile = File(picked.path));
  }

  Future<void> _mint() async {
    if (_imageFile == null) { _show('Выберите изображение'); return; }
    if (_nameCtrl.text.trim().isEmpty) { _show('Введите название'); return; }
    setState(() { _minting = true; _status = '⬆ Загрузка картинки на IPFS...'; });
    try {
      // 1. Загрузка картинки
      final imageIpfs = await _uploadFile(_imageFile!);
      _show('📄 Загрузка метадаты...');

      // 2. Загрузка JSON метадаты
      final metaUrl = await _uploadMeta(
        name: _nameCtrl.text.trim(),
        description: _descCtrl.text.trim(),
        imageIpfs: imageIpfs,
      );
      _show('⛏ Минт на Aptos...');

      // 3. Минт
      final result = await _mintOnAptos(
        name: _nameCtrl.text.trim(),
        description: _descCtrl.text.trim(),
        uri: metaUrl,
      );
      if (result['success'] == true) {
        _show('✅ NFT создан! tx: ${(result['hash']??'').toString().substring(0,10)}...');
        await Future.delayed(const Duration(seconds:2));
        widget.onMinted();
      } else {
        _show('❌ ${result['error']}');
        setState(() => _minting = false);
      }
    } catch(e) {
      _show('❌ $e');
      setState(() => _minting = false);
    }
  }

  void _show(String s) => setState(() => _status = s);

  Future<String> _uploadFile(File file) async {
    final req = http.MultipartRequest('POST',
      Uri.parse('https://api.pinata.cloud/pinning/pinFileToIPFS'))
      ..headers['Authorization'] = 'Bearer $_pinataJwt'
      ..files.add(await http.MultipartFile.fromPath('file', file.path,
        contentType: MediaType('image','jpeg')));
    final resp = await req.send();
    final body = await resp.stream.bytesToString();
    if (resp.statusCode != 200) throw Exception('Pinata: $body');
    final hash = jsonDecode(body)['IpfsHash'];
    return 'ipfs://$hash';
  }

  Future<String> _uploadMeta({
    required String name, required String description, required String imageIpfs,
  }) async {
    final meta = {
      'name': name, 'description': description, 'image': imageIpfs,
      'attributes': [],
      'properties': {
        'files': [{'uri': imageIpfs, 'type':'image/jpeg'}],
        'category': 'image',
      },
    };
    final resp = await http.post(
      Uri.parse('https://api.pinata.cloud/pinning/pinJSONToIPFS'),
      headers: {'Authorization':'Bearer $_pinataJwt','Content-Type':'application/json'},
      body: jsonEncode({'pinataContent': meta, 'pinataMetadata': {'name':'$name.json'}}),
    );
    if (resp.statusCode != 200) throw Exception('Pinata JSON: ${resp.body}');
    final hash = jsonDecode(resp.body)['IpfsHash'];
    return 'https://gateway.pinata.cloud/ipfs/$hash';
  }

  Future<Map<String,dynamic>> _mintOnAptos({
    required String name, required String description, required String uri,
  }) async {
    // Payload JSON
    final payload = {
      'type': 'entry_function_payload',
      'function': '0x4::aptos_token::mint',
      'type_arguments': [],
      'arguments': [_nftCollection, description, name, uri, [], [], []],
    };

    // BCS payload для подписи
    final modAddr = _bcsAddr('0x4');
    final payloadBytes = Uint8List.fromList([
      0x02, ...modAddr, ..._bcsStr('aptos_token'), ..._bcsStr('mint'),
      ..._uleb(0), // type_args: 0
      ..._uleb(7), // 7 аргументов
      // collection name
      ..._uleb(_bcsStr(_nftCollection).length), ..._bcsStr(_nftCollection),
      // description
      ..._uleb(_bcsStr(description).length), ..._bcsStr(description),
      // name
      ..._uleb(_bcsStr(name).length), ..._bcsStr(name),
      // uri
      ..._uleb(_bcsStr(uri).length), ..._bcsStr(uri),
      // property_keys [] property_types [] property_values []
      ..._uleb(1),0x00, ..._uleb(1),0x00, ..._uleb(1),0x00,
    ]);

    return _submitTx(
      privateKeyHex: widget.privateKeyHex,
      payload: payload,
      payloadBytes: payloadBytes,
      maxGas: 10000,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF111827),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.only(
        left:20, right:20, top:20,
        bottom: MediaQuery.of(context).viewInsets.bottom+24,
      ),
      child: SingleChildScrollView(child: Column(
        mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(child: Container(width:40,height:4,
            decoration: BoxDecoration(color:Colors.white24, borderRadius:BorderRadius.circular(2)))),
          const SizedBox(height:16),
          const Text('Создать NFT', style: TextStyle(color:Colors.white,fontSize:18,fontWeight:FontWeight.bold)),
          const SizedBox(height:4),
          const Text('Картинка → IPFS (Pinata) → минт на Aptos',
            style: TextStyle(color:Colors.white38, fontSize:11)),
          const SizedBox(height:20),

          // Выбор фото
          GestureDetector(
            onTap: _minting ? null : _pickImage,
            child: Container(
              height:160, width:double.infinity,
              decoration: BoxDecoration(
                color: const Color(0xFF1A2035),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _imageFile!=null ? Colors.cyanAccent.withOpacity(0.5) : Colors.white12,
                  width:1.5),
              ),
              child: _imageFile!=null
                ? ClipRRect(borderRadius:BorderRadius.circular(11),
                    child: Image.file(_imageFile!, fit:BoxFit.cover))
                : const Column(mainAxisAlignment:MainAxisAlignment.center, children:[
                    Icon(Icons.add_photo_alternate_outlined, color:Colors.cyanAccent, size:48),
                    SizedBox(height:8),
                    Text('Выбрать из галереи', style:TextStyle(color:Colors.white54, fontSize:13)),
                  ]),
            ),
          ),
          const SizedBox(height:16),
          _field(_nameCtrl, 'Название NFT'),
          const SizedBox(height:12),
          _field(_descCtrl, 'Описание (необязательно)', maxLines:2),
          const SizedBox(height:20),

          // Статус
          if (_status.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(bottom:12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _status.contains('❌') ? Colors.red.withOpacity(0.1) : Colors.cyanAccent.withOpacity(0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _status.contains('❌')
                  ? Colors.redAccent.withOpacity(0.3) : Colors.cyanAccent.withOpacity(0.2)),
              ),
              child: Row(children:[
                if (_minting && !_status.contains('✅') && !_status.contains('❌'))
                  const SizedBox(width:14,height:14,
                    child: CircularProgressIndicator(color:Colors.cyanAccent, strokeWidth:2)),
                if (_minting && !_status.contains('✅') && !_status.contains('❌'))
                  const SizedBox(width:10),
                Expanded(child: Text(_status, style: TextStyle(
                  color: _status.contains('❌') ? Colors.redAccent : Colors.cyanAccent, fontSize:13))),
              ]),
            ),

          SizedBox(width:double.infinity, child: ElevatedButton(
            onPressed: _minting ? null : _mint,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.cyanAccent, foregroundColor: Colors.black,
              disabledBackgroundColor: Colors.cyanAccent.withOpacity(0.3),
              padding: const EdgeInsets.symmetric(vertical:14),
              shape: RoundedRectangleBorder(borderRadius:BorderRadius.circular(12)),
            ),
            child: Text(_minting ? 'Минтинг...' : '⛏ Минт NFT',
              style: const TextStyle(fontWeight:FontWeight.bold, fontSize:15)),
          )),
        ],
      )),
    );
  }

  Widget _field(TextEditingController ctrl, String hint, {int maxLines=1}) {
    return TextField(
      controller: ctrl, maxLines: maxLines, enabled: !_minting,
      style: const TextStyle(color:Colors.white),
      decoration: InputDecoration(
        hintText: hint, hintStyle: const TextStyle(color:Colors.white38),
        filled: true, fillColor: const Color(0xFF1A2035),
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

// ══════════════════════════════════════════════════════════════
// _SendSheet
// ══════════════════════════════════════════════════════════════
class _SendSheet extends StatefulWidget {
  final NftItem nft;
  final String privateKeyHex;
  final VoidCallback onSent;
  const _SendSheet({required this.nft, required this.privateKeyHex, required this.onSent});

  @override
  State<_SendSheet> createState() => _SendSheetState();
}

class _SendSheetState extends State<_SendSheet> {
  final _addrCtrl = TextEditingController();
  bool _sending = false;
  String _status = '';

  Future<void> _send() async {
    final to = _addrCtrl.text.trim();
    if (to.isEmpty || !to.startsWith('0x') || to.length < 60) {
      setState(() => _status = '❌ Введите корректный адрес Aptos');
      return;
    }
    setState(() { _sending = true; _status = '📤 Отправка...'; });
    try {
      // object::transfer для Digital Asset standard
      final payload = {
        'type': 'entry_function_payload',
        'function': '0x1::object::transfer',
        'type_arguments': ['0x4::token::Token'],
        'arguments': [widget.nft.tokenDataId, to],
      };

      // BCS payload
      final modAddr = _bcsAddr('0x1');
      final toBytes = _bcsAddr(to);
      final objBytes = _bcsAddr(widget.nft.tokenDataId);
      final typeTag = Uint8List.fromList([
        0x07, ..._bcsAddr('0x4'), ..._bcsStr('token'), ..._bcsStr('Token'), 0x00,
      ]);
      final payloadBytes = Uint8List.fromList([
        0x02, ...modAddr, ..._bcsStr('object'), ..._bcsStr('transfer'),
        ..._uleb(1), ...typeTag,   // 1 type_arg
        ..._uleb(2),               // 2 args
        ..._uleb(32), ...objBytes, // object address
        ..._uleb(32), ...toBytes,  // recipient
      ]);

      final result = await _submitTx(
        privateKeyHex: widget.privateKeyHex,
        payload: payload,
        payloadBytes: payloadBytes,
        maxGas: 5000,
      );
      if (result['success'] == true) {
        setState(() => _status = '✅ NFT отправлен!');
        await Future.delayed(const Duration(seconds:2));
        widget.onSent();
      } else {
        setState(() { _status = '❌ ${result['error']}'; _sending = false; });
      }
    } catch(e) {
      setState(() { _status = '❌ $e'; _sending = false; });
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
        left:20, right:20, top:20,
        bottom: MediaQuery.of(context).viewInsets.bottom+24,
      ),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children:[
        Center(child: Container(width:40,height:4,
          decoration: BoxDecoration(color:Colors.white24, borderRadius:BorderRadius.circular(2)))),
        const SizedBox(height:16),
        Row(children:[
          if (widget.nft.imageUrl.isNotEmpty)
            ClipRRect(borderRadius:BorderRadius.circular(8),
              child: Image.network(widget.nft.imageUrl, width:48, height:48, fit:BoxFit.cover,
                errorBuilder:(_,__,___) => const Icon(Icons.image, color:Colors.white24, size:48))),
          const SizedBox(width:12),
          Expanded(child: Column(crossAxisAlignment:CrossAxisAlignment.start, children:[
            Text(widget.nft.name,
              style: const TextStyle(color:Colors.white, fontSize:16, fontWeight:FontWeight.bold)),
            const Text('Отправить NFT', style: TextStyle(color:Colors.white38, fontSize:12)),
          ])),
        ]),
        const SizedBox(height:20),
        TextField(
          controller: _addrCtrl, enabled: !_sending,
          style: const TextStyle(color:Colors.white, fontSize:13),
          decoration: InputDecoration(
            hintText: '0x... адрес получателя',
            hintStyle: const TextStyle(color:Colors.white38),
            filled:true, fillColor: const Color(0xFF1A2035),
            border: OutlineInputBorder(borderRadius:BorderRadius.circular(10),
              borderSide: const BorderSide(color:Colors.white12)),
            enabledBorder: OutlineInputBorder(borderRadius:BorderRadius.circular(10),
              borderSide: const BorderSide(color:Colors.white12)),
            focusedBorder: OutlineInputBorder(borderRadius:BorderRadius.circular(10),
              borderSide: const BorderSide(color:Colors.cyanAccent, width:1.5)),
          ),
        ),
        const SizedBox(height:12),
        if (_status.isNotEmpty)
          Padding(padding: const EdgeInsets.only(bottom:12),
            child: Text(_status, style: TextStyle(
              color: _status.contains('❌') ? Colors.redAccent : Colors.cyanAccent, fontSize:13))),
        SizedBox(width:double.infinity, child: ElevatedButton(
          onPressed: _sending ? null : _send,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.cyanAccent, foregroundColor: Colors.black,
            padding: const EdgeInsets.symmetric(vertical:14),
            shape: RoundedRectangleBorder(borderRadius:BorderRadius.circular(12)),
          ),
          child: Text(_sending ? 'Отправка...' : '📤 Отправить',
            style: const TextStyle(fontWeight:FontWeight.bold, fontSize:15)),
        )),
      ]),
    );
  }
}

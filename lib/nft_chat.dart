// nft_chat.dart — отправка и отображение NFT в чате
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

// ── Формат NFT сообщения ──────────────────────────────────────
// Текст сообщения: [NFT:tokenDataId:tokenName:imageUrl]
// Пример: [NFT:0xabc123:My Cat:https://ipfs.io/ipfs/Qm...]

const String _nftPrefix = '[NFT:';
const String _nftSuffix = ']';
const String _aptosIndexer = 'https://api.mainnet.aptoslabs.com/v1/graphql';

// ── Парсинг NFT из текста сообщения ──────────────────────────
class NftMessageData {
  final String tokenDataId;
  final String tokenName;
  final String imageUrl;

  NftMessageData({
    required this.tokenDataId,
    required this.tokenName,
    required this.imageUrl,
  });

  // Кодирование в текст сообщения
  String encode() => '$_nftPrefix$tokenDataId:$tokenName:$imageUrl$_nftSuffix';

  // Декодирование из текста
  static NftMessageData? decode(String text) {
    if (!text.startsWith(_nftPrefix) || !text.endsWith(_nftSuffix)) return null;
    final inner = text.substring(_nftPrefix.length, text.length - _nftSuffix.length);
    final parts = inner.split(':');
    if (parts.length < 3) return null;
    // tokenDataId может содержать 0x поэтому берём первые 2 части как id
    // imageUrl может содержать : (https://)
    final tokenDataId = parts[0];
    final tokenName = parts[1];
    final imageUrl = parts.sublist(2).join(':'); // склеиваем остаток
    return NftMessageData(
      tokenDataId: tokenDataId,
      tokenName: tokenName,
      imageUrl: imageUrl,
    );
  }

  static bool isNftMessage(String text) =>
    text.startsWith(_nftPrefix) && text.endsWith(_nftSuffix);

    static bool containsNft(String text) => text.contains(_nftPrefix);

  static List<dynamic> parseMessage(String text) {
    final result = <dynamic>[];
    final regex = RegExp(r'\[NFT:[^\]]+\]');
    int last = 0;
    for (final m in regex.allMatches(text)) {
      if (m.start > last) result.add(text.substring(last, m.start).trim());
      final nft = NftMessageData.decode(m.group(0)!);
      if (nft != null) result.add(nft);
      last = m.end;
    }
    if (last < text.length) result.add(text.substring(last).trim());
    return result.where((e) => e is NftMessageData || (e is String && e.isNotEmpty)).toList();
  }


}

// ══════════════════════════════════════════════════════════════
// NftPickerSheet — выбор NFT из коллекции для отправки в чат
// ══════════════════════════════════════════════════════════════
class NftPickerSheet extends StatefulWidget {
  final String walletAddress;
  final Function(NftMessageData) onSelected;

  const NftPickerSheet({
    super.key,
    required this.walletAddress,
    required this.onSelected,
  });

  @override
  State<NftPickerSheet> createState() => _NftPickerSheetState();
}

class _NftPickerSheetState extends State<NftPickerSheet> {
  List<Map<String,String>> _nfts = []; // {id, name, imageUrl}
  bool _loading = true;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _loadNfts();
  }

  String _parseIpfsUrl(String? url) {
    if (url == null || url.isEmpty) return '';
    if (url.startsWith('ipfs://')) {
      return url.replaceFirst('ipfs://', 'https://gateway.pinata.cloud/ipfs/');
    }
    return url;
  }

  Future<void> _loadNfts() async {
    setState(() { _loading = true; _error = ''; });
    try {
      const query = r'''
        query GetUserNfts($address: String!) {
          current_token_ownerships_v2(
            where: {
              owner_address: {_eq: $address},
              amount: {_gt: "0"},
              current_token_data: {
                current_collection: {
                  collection_name: {_eq: "MEGA Wallet NFT"}
                }
              }
            }
          ) {
            current_token_data {
              token_data_id
              token_name
              token_uri
            }
          }
        }
      ''';

      final resp = await http.post(
        Uri.parse(_aptosIndexer),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'query': query, 'variables': {'address': widget.walletAddress}}),
      ).timeout(const Duration(seconds: 10));

      if (resp.statusCode != 200) throw Exception('Ошибка загрузки');
      final data = jsonDecode(resp.body);
      final tokens = data['data']['current_token_ownerships_v2'] as List;

      final nfts = <Map<String,String>>[];
      for (final t in tokens) {
        final td = t['current_token_data'];
        if (td == null) continue;
        final rawUri = td['token_uri'] ?? '';
        String imageUrl = '';
        // Загружаем метадату чтобы получить image
        try {
          final metaUrl = _parseIpfsUrl(rawUri);
          if (metaUrl.isNotEmpty) {
            final mr = await http.get(Uri.parse(metaUrl))
              .timeout(const Duration(seconds: 8));
            if (mr.statusCode == 200) {
              final meta = jsonDecode(mr.body);
              imageUrl = _parseIpfsUrl(meta['image']?.toString() ?? '');
            }
          }
        } catch(_) {}

        nfts.add({
          'id': td['token_data_id'] ?? '',
          'name': td['token_name'] ?? 'NFT',
          'imageUrl': imageUrl,
        });
      }
      setState(() { _nfts = nfts; _loading = false; });
    } catch(e) {
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF111827),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        // Хэндл
        Center(child: Container(width:40,height:4,
          decoration: BoxDecoration(color:Colors.white24, borderRadius:BorderRadius.circular(2)))),
        const SizedBox(height:14),
        const Row(children: [
          Icon(Icons.image_outlined, color: Colors.cyanAccent, size: 18),
          SizedBox(width: 8),
          Text('Отправить NFT в чат', style: TextStyle(
            color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold,
          )),
        ]),
        const SizedBox(height:4),
        const Text('Выберите NFT из вашей коллекции',
          style: TextStyle(color: Colors.white38, fontSize: 12)),
        const SizedBox(height:16),

        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 30),
            child: Center(child: CircularProgressIndicator(color: Colors.cyanAccent, strokeWidth: 2)),
          )
        else if (_error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Text('Ошибка: $_error', style: const TextStyle(color: Colors.redAccent)),
          )
        else if (_nfts.isEmpty)
          Container(
            padding: const EdgeInsets.all(20),
            child: const Center(child: Text(
              'У вас нет NFT для отправки.\nСоздайте NFT во вкладке NFT.',
              style: TextStyle(color: Colors.white38, fontSize: 13),
              textAlign: TextAlign.center,
            )),
          )
        else
          SizedBox(
            height: 200,
            child: GridView.builder(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3, crossAxisSpacing: 8, mainAxisSpacing: 8,
                childAspectRatio: 0.85,
              ),
              itemCount: _nfts.length,
              itemBuilder: (_, i) {
                final nft = _nfts[i];
                return GestureDetector(
                  onTap: () {
                    final data = NftMessageData(
                      tokenDataId: nft['id']!,
                      tokenName: nft['name']!,
                      imageUrl: nft['imageUrl']!,
                    );
                    Navigator.pop(context);
                    widget.onSelected(data);
                  },
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A2035),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.cyanAccent.withOpacity(0.2)),
                    ),
                    child: Column(children: [
                      Expanded(child: ClipRRect(
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(9)),
                        child: nft['imageUrl']!.isNotEmpty
                          ? Image.network(nft['imageUrl']!, fit: BoxFit.cover,
                              width: double.infinity,
                              errorBuilder: (_,__,___) => const Icon(
                                Icons.image_outlined, color: Colors.white24, size: 28),
                              loadingBuilder: (_, child, progress) => progress == null
                                ? child
                                : const Center(child: SizedBox(width:14,height:14,
                                    child: CircularProgressIndicator(
                                      color: Colors.cyanAccent, strokeWidth: 1.5))),
                            )
                          : const Center(child: Icon(
                              Icons.image_outlined, color: Colors.white24, size: 28)),
                      )),
                      Padding(
                        padding: const EdgeInsets.all(4),
                        child: Text(nft['name']!, maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white70, fontSize: 10)),
                      ),
                    ]),
                  ),
                );
              },
            ),
          ),
      ]),
    );
  }
}

// ══════════════════════════════════════════════════════════════
// NftChatBubble — карточка NFT внутри пузыря сообщения
// ══════════════════════════════════════════════════════════════
class NftChatBubble extends StatelessWidget {
  final NftMessageData nft;
  final bool isOwn;

  const NftChatBubble({super.key, required this.nft, required this.isOwn});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        if (nft.imageUrl.isNotEmpty) {
          showDialog(context: context, builder: (_) => Dialog(
            backgroundColor: Colors.black,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              AppBar(
                backgroundColor: Colors.black, elevation: 0,
                title: Text(nft.tokenName,
                  style: const TextStyle(color: Colors.white, fontSize: 15)),
                leading: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  InteractiveViewer(
                    child: Image.network(nft.imageUrl, fit: BoxFit.contain,
                      errorBuilder: (_,__,___) => const Icon(
                        Icons.broken_image, color: Colors.white38, size: 60)),
                  ),
                  const SizedBox(height: 8),
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Container(width:8,height:8,
                      decoration: const BoxDecoration(
                        color: Colors.cyanAccent, shape: BoxShape.circle)),
                    const SizedBox(width: 6),
                    const Text('Aptos NFT', style: TextStyle(
                      color: Colors.cyanAccent, fontSize: 12)),
                  ]),
                ]),
              ),
            ]),
          ));
        }
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: 180, height: 180,
          child: nft.imageUrl.isNotEmpty
            ? Image.network(nft.imageUrl, fit: BoxFit.cover,
                /* 
                errorBuilder: (_,__,___) => Container(
                  color: const Color(0xFF1A2035),
                  child: const Center(child: Icon(
                    Icons.broken_image, color: Colors.white24, size: 40))),
                 */ 

                errorBuilder: (_,__,___) => Container(
                  color: const Color(0xFF1A2035),
                  child: const Center(child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.hide_image_outlined, color: Colors.white24, size: 32),
                      SizedBox(height: 6),
                      Text('NFT удалён', style: TextStyle(
                        color: Colors.white24, fontSize: 11)),
                    ],
                  ))), 

                loadingBuilder: (_, child, progress) => progress == null
                  ? child
                  : Container(color: const Color(0xFF1A2035),
                      child: const Center(child: CircularProgressIndicator(
                        color: Colors.cyanAccent, strokeWidth: 2))),
              )
            : Container(color: const Color(0xFF1A2035),
                child: const Center(child: Icon(
                  Icons.image_outlined, color: Colors.white24, size: 40))),
        ),
      ),
    );
  }
}

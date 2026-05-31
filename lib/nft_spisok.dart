import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'nft_actions.dart';

class NftSpisok extends StatefulWidget {
  final String? address;
  final String? privateKeyHex;
  const NftSpisok({super.key, this.address, this.privateKeyHex});

  @override
  State<NftSpisok> createState() => _NftSpisokState();
}

class _NftSpisokState extends State<NftSpisok> {
  List<dynamic> _nfts = [];
  Map<String, String> _resolvedImages = {};
  bool _loading = false;
  String _error = '';

  @override
  void initState() { super.initState(); _loadNfts(); }

  @override
  void didUpdateWidget(covariant NftSpisok oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.address != widget.address) _loadNfts();
  }

  String _parseIpfsUrl(String? url) {
    if (url == null || url.isEmpty) return '';
    if (url.startsWith('ipfs://')) {
      return url.replaceFirst('ipfs://', 'https://gateway.pinata.cloud/ipfs/');
    }
    return url;
  }

  Future<void> _loadNfts() async {
    if (widget.address == null || widget.address!.isEmpty) return;
    setState(() { _loading = true; _error = ''; });
    try {
      final query = {
        "query": """
          query GetUserNfts(\$address: String!) {
            current_token_ownerships_v2(
              where: {
                owner_address: {_eq: \$address},
                amount: {_gt: "0"},
                current_token_data: {
                  current_collection: {
                    collection_name: {_eq: "MEGA Wallet NFT"}
                  }
                }
              }
            ) {
              amount
              current_token_data {
                token_data_id
                token_name
                token_uri
                description
                collection_id
                current_collection {
                  creator_address    
                }
              }
            }
          }
        """,
        "variables": {"address": widget.address}
      };

      final response = await http.post(
        Uri.parse('https://api.mainnet.aptoslabs.com/v1/graphql'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(query),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final resBody = jsonDecode(response.body);
        if (resBody['data'] != null) {
          final List<dynamic> tokens = resBody['data']['current_token_ownerships_v2'] ?? [];
          setState(() { _nfts = tokens; _loading = false; });
          for (var token in tokens) {
            final td = token['current_token_data'];
            if (td != null) _fetchNftMetadata(td['token_uri']);
          }
        } else {
          setState(() { _error = 'Не удалось обработать данные'; _loading = false; });
        }
      } else {
        setState(() { _error = 'Ошибка: ${response.statusCode}'; _loading = false; });
      }
    } catch (e) {
      setState(() { _error = 'Сеть недоступна'; _loading = false; });
    }
  }

  Future<void> _fetchNftMetadata(String? rawUri) async {
    if (rawUri == null || rawUri.isEmpty || _resolvedImages.containsKey(rawUri)) return;
    final httpUrl = _parseIpfsUrl(rawUri);
    if (httpUrl.isEmpty) return;

    for (int attempt = 0; attempt < 3; attempt++) {
      try {
        final res = await http.get(Uri.parse(httpUrl)).timeout(const Duration(seconds: 15));
        if (res.statusCode == 200) {
          final meta = jsonDecode(res.body);
          final String? imgUrl = meta['image'] ?? meta['image_url'] ?? meta['uri'] ?? meta['animation_url'];
          if (imgUrl != null && imgUrl.isNotEmpty) {
            if (mounted) setState(() => _resolvedImages[rawUri] = _parseIpfsUrl(imgUrl));
            return;
          }
        }
      } catch (e) {
        if (attempt == 2) {
          if (mounted) setState(() => _resolvedImages[rawUri] = 'error');
          return;
        }
        await Future.delayed(const Duration(seconds: 2));
      }
    }
    if (mounted) setState(() => _resolvedImages[rawUri] = 'error');
  }

  // ── Открыть меню действий ─────────────────────────────────
  void _openActions(BuildContext context, dynamic tokenData, String? imageUrl) {
    if (widget.privateKeyHex == null || widget.privateKeyHex!.isEmpty) return;
    final tokenDataId = tokenData['token_data_id'] ?? '';
    if (tokenDataId.isEmpty) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => NftActionsSheet(
        tokenDataId: tokenDataId,
        tokenName: tokenData['token_name'] ?? 'NFT',
        imageUrl: imageUrl,
        privateKeyHex: widget.privateKeyHex!,
        creatorAddress: tokenData['current_collection']?['creator_address'] ?? '',
        onDone: () {
          Future.delayed(const Duration(seconds: 3), _loadNfts);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.address == null || widget.address!.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(child: Text('Авторизуйтесь, чтобы увидеть ваши NFT',
          style: TextStyle(color: Colors.white24, fontSize: 13))),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Row(children: [
          const Text('МОЯ ГАЛЕРЕЯ NFT', style: TextStyle(
            color: Colors.cyanAccent, fontSize: 13,
            fontWeight: FontWeight.bold, letterSpacing: 2,
          )),
          if (_nfts.isNotEmpty) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.cyanAccent.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text('${_nfts.length}',
                style: const TextStyle(color: Colors.cyanAccent, fontSize: 11, fontWeight: FontWeight.bold)),
            ),
          ],
        ]),
        IconButton(
          icon: Icon(Icons.refresh, color: Colors.cyanAccent.withOpacity(0.6), size: 18),
          onPressed: _loading ? null : _loadNfts,
        ),
      ]),
      const SizedBox(height: 4),

      if (_loading)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 30),
          child: Center(child: CircularProgressIndicator(color: Colors.cyanAccent, strokeWidth: 2)),
        )
      else if (_error.isNotEmpty)
        Text(_error, style: const TextStyle(color: Colors.redAccent, fontSize: 13))
      else if (_nfts.isEmpty)
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: const Color(0xFF151B2E),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white12),
          ),
          child: const Center(child: Text('У вас пока нет NFT объектов',
            style: TextStyle(color: Colors.white38, fontSize: 13))),
        )
      else
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2, crossAxisSpacing: 10, mainAxisSpacing: 10, childAspectRatio: 0.78,
          ),
          itemCount: _nfts.length,
          itemBuilder: (context, index) {
            final tokenData = _nfts[index]['current_token_data'];
            if (tokenData == null) return const SizedBox.shrink();
            final String name = tokenData['token_name'] ?? 'Без названия';
            final String rawUri = tokenData['token_uri'] ?? '';
            final String? imageUrl = _resolvedImages[rawUri];
            final bool hasActions = widget.privateKeyHex != null;

            return GestureDetector(
              // Долгое нажатие — открыть меню действий
              onLongPress: hasActions
                ? () => _openActions(context, tokenData, imageUrl != null && imageUrl != 'error' ? imageUrl : null)
                : null,
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF151B2E),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.white12),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () {
                        if (imageUrl != null && imageUrl.isNotEmpty && imageUrl != 'error') {
                          Navigator.push(context, MaterialPageRoute(
                            builder: (_) => NftDetailScreen(imageUrl: imageUrl, nftName: name),
                          ));
                        }
                      },
                      child: Stack(children: [
                        ClipRRect(
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(13)),
                          child: Container(
                            width: double.infinity, height: double.infinity,
                            color: Colors.black.withOpacity(0.23),
                            child: imageUrl != null && imageUrl.isNotEmpty
                              ? (imageUrl == 'error'
                                ? const Center(child: Icon(Icons.broken_image, color: Colors.white24, size: 28))
                                : Image.network(imageUrl, fit: BoxFit.cover,
                                    errorBuilder: (_,__,___) => const Icon(Icons.broken_image, color: Colors.white24, size: 28),
                                    loadingBuilder: (context, child, progress) {
                                      if (progress == null) return child;
                                      return const Center(child: SizedBox(width:16,height:16,
                                        child: CircularProgressIndicator(color: Colors.cyanAccent, strokeWidth: 1.5)));
                                    }))
                              : const Center(child: SizedBox(width:16,height:16,
                                  child: CircularProgressIndicator(color: Colors.cyanAccent, strokeWidth: 1.5))),
                          ),
                        ),
                        // Подсказка удержания
                        if (hasActions)
                          Positioned(top:6,right:6,
                            child: Container(
                              padding: const EdgeInsets.all(4),
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.5),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: const Icon(Icons.more_horiz, color: Colors.white54, size: 14),
                            ),
                          ),
                      ]),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(10),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                      const SizedBox(height: 2),
                      Row(children: [
                        Container(width:6,height:6,
                          decoration: const BoxDecoration(color: Colors.greenAccent, shape: BoxShape.circle)),
                        const SizedBox(width: 5),
                        Text('Aptos NFT', style: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 10)),
                      ]),
                    ]),
                  ),
                ]),
              ),
            );
          },
        ),
    ]);
  }
}

class NftDetailScreen extends StatelessWidget {
  final String imageUrl;
  final String nftName;
  const NftDetailScreen({super.key, required this.imageUrl, required this.nftName});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black, elevation: 0,
        title: Text(nftName, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Center(
        child: InteractiveViewer(
          panEnabled: true, minScale: 0.5, maxScale: 4.0,
          child: Image.network(imageUrl,
            fit: BoxFit.contain, width: double.infinity, height: double.infinity,
            loadingBuilder: (context, child, progress) {
              if (progress == null) return child;
              return const Center(child: CircularProgressIndicator(color: Colors.cyanAccent));
            },
            errorBuilder: (c,e,s) => const Icon(Icons.broken_image, color: Colors.white38, size: 40),
          ),
        ),
      ),
    );
  }
}

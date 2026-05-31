import 'package:flutter/material.dart';
import 'main.dart';
import 'token_manager.dart';

class TokenSettingsDialog extends StatefulWidget {
  final List<TokenBalance> tokens;
  final VoidCallback onSettingsChanged;

  const TokenSettingsDialog({
    super.key,
    required this.tokens,
    required this.onSettingsChanged,
  });

  @override
  State<TokenSettingsDialog> createState() => _TokenSettingsDialogState();
}

class _TokenSettingsDialogState extends State<TokenSettingsDialog> {
  late Map<String, TokenSettings> settings;
  late List<String> orderedTokens;

  @override
  void initState() {
    super.initState();
    orderedTokens = [];
    settings = {};
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    settings = await TokenManager.loadSettings();
    
    orderedTokens = widget.tokens.map((t) => t.assetType).toList();
    orderedTokens.sort((a, b) {
      final orderA = settings[a]?.order ?? 999;
      final orderB = settings[b]?.order ?? 999;
      return orderA.compareTo(orderB);
    });

    if (mounted) setState(() {});
  }

  Future<void> _onReorder(int oldIndex, int newIndex) async {
    setState(() {
      if (newIndex > oldIndex) {
        newIndex -= 1;
      }
      final String item = orderedTokens.removeAt(oldIndex);
      orderedTokens.insert(newIndex, item);
    });

    await _saveNewOrder();
    widget.onSettingsChanged();
  }

  Future<void> _saveNewOrder() async {
    for (int i = 0; i < orderedTokens.length; i++) {
      await TokenManager.updateOrder(orderedTokens[i], i);
    }
  }

  Future<void> _toggleVisibility(String assetType) async {
    await TokenManager.toggleVisibility(assetType);
    settings = await TokenManager.loadSettings();
    setState(() {});
    widget.onSettingsChanged();
  }

  String _getTokenSymbol(String assetType) {
    return widget.tokens.firstWhere((t) => t.assetType == assetType).symbol;
  }

  String _getTokenName(String assetType) {
    return widget.tokens.firstWhere((t) => t.assetType == assetType).name;
  }

  // Маппинг контракт → иконка
  static const Map<String, String> _assetIcons = {
    '0x1::aptos_coin::AptosCoin': 'assets/apt.png',
    '0xe9c192ff55cffab3963c695cff6dbf9dad6aff2bb5ac19a6415cad26a81860d9::mee_coin::MeeCoin': 'assets/mee.png',
    '0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3::mega_coin::MEGA': 'assets/mega.png',
    '0xf22bede237a07e121b56d91a491eb7bcdfd1f5907926a9e58338f964a01b17fa::asset::USDT': 'assets/usdt.png',
    '0x357b0b74bc833e95a115ad22604854d6b0fca151cecd94111770e5d6ffc9dc2b': 'assets/usdt.png',
    '0xbae207659db88bea0cbead6da0ed00aac12edcdda169e591cd41c94180b46f3b': 'assets/usdc.png',
  };

  // Метод для отрисовки иконки
  Widget _buildTokenIcon(String assetType, String symbol) {
    final assetPath = _assetIcons[assetType];
    if (assetPath != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: Image.asset(
          assetPath,
          width: 44, height: 44, fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _buildFallbackIcon(symbol),
        ),
      );
    }
    return _buildFallbackIcon(symbol);
  }

  // Заглушка, если иконки нет
  Widget _buildFallbackIcon(String symbol) {
    return Container(
      width: 44,
      height: 44,
      decoration: const BoxDecoration(
        color: Color(0xFF1C2438),
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Text(
          symbol.isNotEmpty ? symbol.substring(0, 1) : '?',
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF131929),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: Container(
        width: double.infinity,
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 12, 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Управление',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white, size: 24),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),

            Expanded(
              child: orderedTokens.isEmpty
                  ? const Center(
                      child: Text('Нет активов', style: TextStyle(color: Colors.white38)),
                    )
                  : ReorderableListView.builder(
                      padding: const EdgeInsets.only(bottom: 20),
                      itemCount: orderedTokens.length,
                      onReorder: _onReorder,
                      buildDefaultDragHandles: false,
                      itemBuilder: (context, index) {
                        final assetType = orderedTokens[index];
                        final isVisible = settings[assetType]?.isVisible ?? true;
                        final symbol = _getTokenSymbol(assetType);
                        final name = _getTokenName(assetType);

                        return Container(
                          key: ValueKey(assetType),
                          color: Colors.transparent,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                            child: Row(
                              children: [
                                // Используем новый метод для иконок
                                _buildTokenIcon(assetType, symbol),
                                const SizedBox(width: 16),

                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        symbol,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      Text(
                                        name,
                                        style: const TextStyle(
                                          color: Colors.white54,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),

                                IconButton(
                                  icon: Icon(
                                    isVisible ? Icons.visibility : Icons.visibility_off,
                                    color: isVisible ? const Color(0xFF4C94FF) : Colors.white24,
                                    size: 24,
                                  ),
                                  onPressed: () => _toggleVisibility(assetType),
                                ),

                                ReorderableDragStartListener(
                                  index: index,
                                  child: const Padding(
                                    padding: EdgeInsets.only(left: 8),
                                    child: Icon(
                                      Icons.menu,
                                      color: Colors.white24,
                                      size: 24,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
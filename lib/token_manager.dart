import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'main.dart';

class TokenSettings {
  final String assetType;
  bool isVisible;
  int order;

  TokenSettings({
    required this.assetType,
    this.isVisible = true,
    required this.order,
  });

  Map<String, dynamic> toJson() => {
    'assetType': assetType,
    'isVisible': isVisible,
    'order': order,
  };

  factory TokenSettings.fromJson(Map<String, dynamic> json) => TokenSettings(
    assetType: json['assetType'] as String,
    isVisible: json['isVisible'] as bool? ?? true,
    order: json['order'] as int? ?? 0,
  );
}

class TokenManager {
  static const _storage = FlutterSecureStorage();
  static const _storageKeyBase = 'token_settings';

  /// Устанавливается при старте и при смене кошелька
  static String _currentAddress = '';

  static void setCurrentAddress(String address) {
    _currentAddress = address;
  }

  /// Ключ хранилища — уникальный для каждого кошелька
  static String get _storageKey => _currentAddress.isNotEmpty
      ? '${_storageKeyBase}_$_currentAddress'
      : _storageKeyBase;

  // Загружает сохраненные настройки
  static Future<Map<String, TokenSettings>> loadSettings() async {
    try {
      final json = await _storage.read(key: _storageKey);
      if (json == null) return {};
      
      final Map<String, dynamic> decoded = jsonDecode(json);
      return decoded.map(
        (key, value) => MapEntry(
          key,
          TokenSettings.fromJson(value as Map<String, dynamic>),
        ),
      );
    } catch (e) {
      return {};
    }
  }

  // Сохраняет настройки
  static Future<void> saveSettings(Map<String, TokenSettings> settings) async {
    try {
      final Map<String, dynamic> toSave = settings.map(
        (key, value) => MapEntry(key, value.toJson()),
      );
      await _storage.write(
        key: _storageKey,
        value: jsonEncode(toSave),
      );
    } catch (e) {
      // Handle error silently
    }
  }

  // Обновить порядковый номер токена
  static Future<void> updateOrder(String assetType, int newOrder) async {
    var settings = await loadSettings();
    final token = settings[assetType];
    if (token != null) {
      token.order = newOrder;
      await saveSettings(settings);
    }
  }

  // Применяет настройки к списку токенов
  static Future<List<TokenBalance>> applySettings(
    List<TokenBalance> tokens,
  ) async {
    final settings = await loadSettings();
    
    // Фильтруем видимые токены
    var filtered = tokens.where((token) {
      final setting = settings[token.assetType];
      return setting?.isVisible ?? true;
    }).toList();

    // Сортируем по сохраненному порядку
    filtered.sort((a, b) {
      final settingA = settings[a.assetType];
      final settingB = settings[b.assetType];
      final orderA = settingA?.order ?? 999;
      final orderB = settingB?.order ?? 999;
      return orderA.compareTo(orderB);
    });

    return filtered;
  }

  // Инициализирует настройки для новых токенов
  static Future<void> initializeNewTokens(List<TokenBalance> tokens) async {
    var settings = await loadSettings();
    bool needsSave = false;

    for (int i = 0; i < tokens.length; i++) {
      final token = tokens[i];
      if (!settings.containsKey(token.assetType)) {
        settings[token.assetType] = TokenSettings(
          assetType: token.assetType,
          isVisible: true,
          order: i,
        );
        needsSave = true;
      }
    }

    if (needsSave) {
      await saveSettings(settings);
    }
  }

  // Переместить токен вверх (сохранено для совместимости)
  static Future<void> moveUp(String assetType) async {
    var settings = await loadSettings();
    final current = settings[assetType];
    if (current == null || current.order == 0) return;

    final above = settings.values.firstWhere(
      (s) => s.order == current.order - 1,
      orElse: () => TokenSettings(assetType: '', order: -1),
    );

    if (above.order != -1) {
      above.order = current.order;
      current.order = current.order - 1;
      await saveSettings(settings);
    }
  }

  // Переместить токен вниз (сохранено для совместимости)
  static Future<void> moveDown(
    String assetType,
    int maxOrder,
  ) async {
    var settings = await loadSettings();
    final current = settings[assetType];
    if (current == null || current.order >= maxOrder) return;

    final below = settings.values.firstWhere(
      (s) => s.order == current.order + 1,
      orElse: () => TokenSettings(assetType: '', order: -1),
    );

    if (below.order != -1) {
      below.order = current.order;
      current.order = current.order + 1;
      await saveSettings(settings);
    }
  }

  // Переключить видимость
  static Future<void> toggleVisibility(String assetType) async {
    var settings = await loadSettings();
    final token = settings[assetType];
    if (token != null) {
      token.isVisible = !token.isVisible;
      await saveSettings(settings);
    }
  }
}
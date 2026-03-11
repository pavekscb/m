import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:math'; // Добавлено для pow
import 'dart:math' as math;
import 'package:flutter/gestures.dart';

import 'package:app_links/app_links.dart';
import 'package:cryptography/cryptography.dart';
import 'package:pinenacl/x25519.dart' as pine;
import 'package:pinenacl/api.dart' as pine_api;
import 'package:convert/convert.dart';
import 'package:pointycastle/export.dart' as pc; // Use export.dart to include all algorithms, including SHA3


import 'package:pointycastle/export.dart' as pc;
import 'dart:typed_data';  // For Uint8List (already there?)
import 'package:convert/convert.dart';  // For hex.encode (you already have this as import 'package:convert/convert.dart';)


// --- КОНСТАНТЫ ПРИЛОЖЕНИЯ И ВЕРСИИ ---
const String currentVersion = "1.1.1"; 
const String urlGithubApi = "https://api.github.com/repos/pavekscb/m/releases/latest";

const String walletKey = "WALLET_ADDRESS"; 
const String defaultExampleAddress = ""; // "0x9ba27fc8a65ba4507fc4cca1b456e119e4730b8d8cfaf72a2a486e6d0825b27b";
const int rawDataCorrectionFactor = 100;

// --- Константы Сети ---
const int decimals = 8;
const int accPrecision = 100000000000; 
const int updateIntervalSeconds = 60;

const String meeCoinT0T1 = "0xe9c192ff55cffab3963c695cff6dbf9dad6aff2bb5ac19a6415cad26a81860d9::mee_coin::MeeCoin";
const String aptCoinType = "0x1::aptos_coin::AptosCoin";
const String megaCoinType = "0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3::mega_coin::MEGA";

const String aptLedgerUrl = "https://fullnode.mainnet.aptoslabs.com/v1";
const String poolUrl = "https://fullnode.mainnet.aptoslabs.com/v1/accounts/0xc7efb4076dbe143cbcd98cfaaa929ecfc8f299203dfff63b95ccb6bfe19850fa/resource/0xc7efb4076dbe143cbcd98cfaaa929ecfc8f299203dfff63b95ccb6bfe19850fa::swap::TokenPairMetadata<0x1::aptos_coin::AptosCoin,0xe9c192ff55cffab3963c695cff6dbf9dad6aff2bb5ac19a6415cad26a81860d9::mee_coin::MeeCoin>";
const String harvestBaseUrl = "https://explorer.aptoslabs.com/account/0x514cfb77665f99a2e4c65a5614039c66d13e00e98daf4c86305651d29fd953e5/modules/run/Staking/harvest?network=mainnet";
const String addMeeUrl = "https://explorer.aptoslabs.com/account/0x514cfb77665f99a2e4c65a5614039c66d13e00e98daf4c86305651d29fd953e5/modules/run/Staking/stake?network=mainnet";
const String unstakeBaseUrl = "https://explorer.aptoslabs.com/account/0x514cfb77665f99a2e4c65a5614039c66d13e00e98daf4c86305651d29fd953e5/modules/run/Staking/unstake?network=mainnet";

// КОНСТАНТЫ: Ссылки для кнопок
const String urlSource = "https://github.com/pavekscb/m";
const String urlSwapEarnium = "https://app.panora.exchange/?ref=V94RDWEH#/swap/aptos?pair=MEE-APT";
const String urlSupport = "https://t.me/cripto_karta";
const String urlGraph = "https://dexscreener.com/aptos/pcs-167";

const String petraConnectedKey = "IS_PETRA_CONNECTED"; //
const String lastPetraAddressKey = "LAST_PETRA_ADDRESS"; // Ключ для хранения последнего адреса от Petra
const String manualAddressKey = "MANUAL_WALLET_ADDRESS";

// для истории задаий
class LogEntry {
  final int actionType;
  final String amount;
  final String note;
  final String taskId;
  final int timestamp;

  LogEntry({
    required this.actionType,
    required this.amount,
    required this.note,
    required this.taskId,
    required this.timestamp,
  });

  factory LogEntry.fromJson(Map<String, dynamic> json) {
    return LogEntry(
      actionType: int.parse(json['action_type'].toString()),
      amount: json['amount'].toString(),
      note: json['note'].toString(),
      taskId: json['task_id'].toString(),
      timestamp: int.parse(json['timestamp'].toString()),
    );
  }

  // Вспомогательный метод для расшифровки типа действия
  String get actionName {
    switch (actionType) {
      case 0: return "Создание задачи";
      case 1: return "Одобрено";
      case 2: return "Выполнено";
      case 3: return "Удалено/Возврат";
      default: return "Действие $actionType";
    }
  }
}
// конец история заданий

class TaskV3 {
  final int id;
  final String creator;
  final String description;
  final double rewardApt;
  final int totalClaims;
  final int remainingClaims;
  final int createdAt;
  final int expiresAt;
  int status; // 0 - ожидание, 1 - одобрено, 2 - выполнено, 3 - отклонено

  TaskV3({
    required this.id,
    required this.creator,
    required this.description,
    required this.rewardApt,
    required this.totalClaims,
    required this.remainingClaims,
    required this.createdAt,
    required this.expiresAt,
    this.status = 0,
  });

  // Метод для создания объекта из JSON (Aptos View Method response)
  factory TaskV3.fromJson(Map<String, dynamic> json) {
    return TaskV3(
      id: int.parse(json['id'].toString()),
      creator: json['creator'].toString(),
      description: json['description'].toString(),
      rewardApt: (double.tryParse(json['reward_per_claim_apt'].toString()) ?? 0) / 100000000,
      totalClaims: int.parse(json['total_claims'].toString()),
      remainingClaims: int.parse(json['remaining_claims'].toString()),
      createdAt: int.parse(json['created_at'].toString()),
      expiresAt: int.parse(json['expires_at'].toString()),
    );
  }
} 

void main() {
  // 
  ErrorWidget.builder = (FlutterErrorDetails details) {
    // В дебаг-режиме можно выводить ошибку в консоль, чтобы знать, что чинить
    //debugPrint(details.toString());
    // Возвращаем пустой контейнер вместо красного экрана
    return const SizedBox.shrink(); 
  };
  // -----------------------
  
  runApp(const MeeiroApp());
}

class MeeiroApp extends StatelessWidget {
  const MeeiroApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MEE MEGA Mining',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.blue,
        scaffoldBackgroundColor: const Color(0xFF121212),
        fontFamily: 'Arial',
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin, WidgetsBindingObserver {

  bool _isInitialLoading = false; // Тот самый флаг для лоадера

  String currentWalletAddress = defaultExampleAddress;
  double meeCurrentReward = 0.0;
  double megaOnChain = 0.0;
  double meeRatePerSec = 0.0;
  int countdownVal = updateIntervalSeconds;
  bool isRunning = false;
  
  double unlockingAmount = 0.0;
  int? unlockingStartTime; // Время начала разблокировки (timestamp)
  bool isUnlockComplete = false; // Флаг: прошло ли время ожидания (15 дней)

  double aptOnChain = 0.0;
  double meeOnChain = 0.0;
  double meeStaked = 0.0;
  double priceApt = 0.0;
  double priceMee = 0.0;
  double megaInUsd = 0.0;
  String megaRewardText = "0,00000000 \$MEGA";
  String megaRateText = "15% APR (0,00 MEGA/сек)";

  BigInt megaStakedAmountRaw = BigInt.zero; // Raw-значение стейка $MEGA (из блокчейна)
  BigInt megaLastUpdate = BigInt.zero;      // Время последнего обновления (из блокчейна)
  BigInt megaUnlockTime = BigInt.zero;      // Время разблокировки (если unstake заказан)
  BigInt megaCurrentReward = BigInt.zero;   // Текущая награда $MEGA (локальный расчет)

  BigInt megaApy = BigInt.from(15);   // APY 15% (убрал const, так как в коде не const)
  BigInt secondsInYear = BigInt.from(31536000); // Секунд в году (убрал const)
  BigInt megaNetworkTimeOffset = BigInt.zero; // Смещение времени сети (для синхронизации)

  bool isMegaUnlockComplete = false; // Переместил внутрь класса

  double megaStakeBalance = 0.0; // Баланс $MEGA именно в стейкинге

  final List<String> animationFrames = ['🌱', '🌿', '💰'];
  int currentFrameIndex = 0;
  String rewardTickerText = "";
  Timer? simulationTimer;

  String walletLabelText = "Кошелек: Загрузка...";
  Color walletLabelColor = Colors.white;
  String onChainBalancesText = "Загрузка балансов...";
  String meeBalanceText = "0,00 \$MEE (\$0,00)";
  String meeBalanceText2 = "";
  
  String meeRewardText = "0,00000000 \$MEE";
  String meeRateText = "Скорость: 0,00 MEE/сек";
  
  String updateStatusText = "";
  Color updateStatusColor = const Color(0xFFBBBBBB);
  VoidCallback? updateAction;

  final algorithm = X25519();
  SimpleKeyPair? _myKeyPair;
  late AppLinks _appLinks;
  StreamSubscription? _linkSubscription;

  bool isPetraConnected = false; // Флаг: подключены ли мы именно через кошелек
 
  String? _petraAddress; // Именно это имя используется в твоем UI

  bool isAptToMeeDirection = true;
  bool isMegaToAptDirection = true;
  
  bool isMegaDirection = false;


  List<dynamic> _megaTasks = [];

  bool _isLoadingTasks = false; // Флаг загрузки

  final TextEditingController _descriptionController = TextEditingController();

  Map<String, DateTime> _taskClickTimes = {}; // taskId -> время клика
  bool _isAppActive = true; // Активно ли приложение сейчас
  List<dynamic> _pendingTasks = [];

  StateSetter? _setDialogState;

  List<int> _selectedTaskIds = []; // Список ID выбранных заданий для удаления
  OverlayEntry? _currentToastEntry;

  Map<int, List<dynamic>> _pendingSubmissions = {}; // taskId -> список ответов
  int _totalPendingV3 = 0; // Общий счетчик для кнопки
  Map<int, int> _myV3Statuses = {}; // taskId -> status (0: проверка, 1: ок, 2: отказ)
  

  Widget _buildUnlockCountdown() {
    if (unlockingStartTime == null) return const SizedBox();
    
    final int now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final int unlockTime = unlockingStartTime! + (15 * 24 * 60 * 60);
    final int remaining = unlockTime - now;

    if (remaining <= 0) {
      return const Text("✅ Можно выводить!", style: TextStyle(color: Colors.greenAccent, fontSize: 11));
    }

    int days = remaining ~/ 86400;
    int hours = (remaining % 86400) ~/ 3600;
    int minutes = (remaining % 3600) ~/ 60;

    return Text(
      "До завершения: $days д. $hours ч. $minutes мин.",
      style: const TextStyle(color: Colors.white54, fontSize: 11),
    );
  }

  @override
  void initState() {
    super.initState();
    // _resetPetraOnce(); // сброс данных в телефоне
    WidgetsBinding.instance.addObserver(this); // Регистрируем наблюдателя
    _appLinks = AppLinks(); 
    _initDeepLinks();
    _loadSavedData();      
    _startApp();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this); // Удаляем наблюдателя
    _linkSubscription?.cancel();
    simulationTimer?.cancel();
    _descriptionController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _isAppActive = false;
      //debugPrint("Пользователь покинул приложение (ушел по ссылке или свернул)");
    } else if (state == AppLifecycleState.resumed) {
      _isAppActive = true;
      //debugPrint("Пользователь вернулся в приложение");
      // Здесь можно принудительно обновить диалог, если он открыт
      _setDialogState?.call(() {}); 
    }
  }



  Future<void> _startApp() async {
  setState(() => _isInitialLoading = true); // Включили
  
  await _loadWalletAddress();

//////////////////
  final bool hasValidAddress = currentWalletAddress.isNotEmpty &&
                               currentWalletAddress.length >= 10 &&
                               currentWalletAddress.startsWith("0x");

  if (!hasValidAddress) {
    //debugPrint("🚫 Нет валидного адреса кошелька → лоадер выключаем");
    
    setState(() => _isInitialLoading = false);
    
    
    _showPetraRequiredDialog();
   
    
    return;
  }

  // Если адрес нормальный — продолжаем загрузку
  //debugPrint("✅ Адрес валидный → загружаем данные");

//////////////////

  await _runUpdateThread(); // ЖДЕМ, пока данные реально загрузятся

  await _fetchMegaTasks();

  _checkUpdates(manualCheck: false); // Проверка обновлений (версии)
  _startPeriodicTimer();             // Запуск таймера для обновления данных
  
  setState(() => _isInitialLoading = false); // Выключили
}


  

  void _startPeriodicTimer() {
  simulationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
    if (!isRunning) return;

    setState(() { 
      // 1. Начисляем награду MEE
      meeCurrentReward += meeRatePerSec;
      
      // 2. Уменьшаем счетчик до обновления данных из сети
      countdownVal -= 1;
      
      // 3. Обновляем MEGA (убедись, что там внутри нет лишних анимаций)
      _startMegaSimulation();
      
      // 4. Обновляем текстовые метки, если это необходимо
      _updateRewardLabelsOnly();
      
      // СТРОКИ С АНИМАЦИЕЙ (rewardTickerText и currentFrameIndex) УДАЛЕНЫ
      _setDialogState?.call(() {});
    });

    // Проверка таймера обновления
    if (countdownVal <= 0) {
      _runUpdateThread();
      countdownVal = updateIntervalSeconds;
    }
  });
}

Widget _buildClickableResponse(String response) {
  // Регулярка для поиска URL (простая, ловит http/https + не-пробелы)
  final urlRegExp = RegExp(r'(https?://\S+)');
  final matches = urlRegExp.allMatches(response);

  // Если ссылок нет — просто обычный Text
  if (matches.isEmpty) {
    return Text(response, style: const TextStyle(color: Colors.white70, fontSize: 14));
  }

  // Строим список спанов для RichText
  List<TextSpan> spans = [];
  int lastEnd = 0;
  for (var match in matches) {
    // Текст до ссылки
    if (match.start > lastEnd) {
      spans.add(TextSpan(text: response.substring(lastEnd, match.start)));
    }
    // Сама ссылка (синяя, подчёркнутая, кликабельная)
    spans.add(TextSpan(
      text: match.group(0),
      style: const TextStyle(color: Colors.blueAccent, decoration: TextDecoration.underline),
      recognizer: TapGestureRecognizer()..onTap = () async {
        final url = Uri.parse(match.group(0)!);
        if (await canLaunchUrl(url)) {
          await launchUrl(url, mode: LaunchMode.externalApplication);  // Используем существующую функцию launchUrl
        } else {
          // Опционально: покажите тост с ошибкой (используйте ваш showTopToast)
          showTopToast("Не удалось открыть ссылку", isError: true);
        }
      },
    ));
    lastEnd = match.end;
  }
  // Текст после последней ссылки
  if (lastEnd < response.length) {
    spans.add(TextSpan(text: response.substring(lastEnd)));
  }

  return RichText(
    text: TextSpan(
      children: spans,
      style: const TextStyle(color: Colors.white70, fontSize: 14),  // Стиль по умолчанию (под ваш дизайн)
    ),
  );
}

////////// СООБЩЕНИЯ ПОВЕРХ ОКОН (ПРОФЕССИОНАЛЬНЫЙ СТИЛЬ) //////////////


  void showTopToast(String message, {bool isError = false}) {
  // 1. Если уже есть активное уведомление — удаляем его сразу
  _currentToastEntry?.remove();
  _currentToastEntry = null;

  OverlayState? overlayState = Overlay.of(context);
  late OverlayEntry overlayEntry;

  overlayEntry = OverlayEntry(
    builder: (context) => IgnorePointer( // Чтобы кнопки под окном нажимались
      child: Material(
        color: Colors.transparent,
        child: Center(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 40),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1A),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isError ? Colors.redAccent : Colors.greenAccent.withOpacity(0.5),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 15, spreadRadius: 2),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isError ? Icons.warning_amber_rounded : Icons.info_outline_rounded,
                  color: isError ? Colors.redAccent : Colors.greenAccent,
                  size: 28,
                ),
                const SizedBox(height: 12),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  _currentToastEntry = overlayEntry; // Запоминаем текущий
  overlayState.insert(overlayEntry);

  // Удаляем через 5 секунд
  Future.delayed(const Duration(seconds: 5), () {
    if (overlayEntry.mounted && _currentToastEntry == overlayEntry) {
      overlayEntry.remove();
      _currentToastEntry = null;
    }
  });
}

 

///////////////////


  // Функция для расчета цены $MEGA в APT (уже есть _getMegaCurrentPrice, но возвращаем в double)
  double _getMegaPriceInApt() {
    return _getMegaCurrentPrice(); // Возвращает цену в APT (0.001 -> 0.1)
  }

  // Функция для расчета текущей награды $MEGA локально (аналогично popup.js)
  void _calculateMegaRewardLocally() {
    if (megaStakedAmountRaw == BigInt.zero || megaLastUpdate == BigInt.zero) {
      megaCurrentReward = BigInt.zero;
      return;
    }

    final int now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final BigInt nowSynced = BigInt.from(now) + megaNetworkTimeOffset;

    // Если unstake заказан или время не прошло — награда 0 (как в контракте)
    if (megaUnlockTime > BigInt.zero || nowSynced <= megaLastUpdate) {
      megaCurrentReward = BigInt.zero;
      return;
    }

    final BigInt duration = nowSynced - megaLastUpdate;
    megaCurrentReward = (megaStakedAmountRaw * megaApy * duration) ~/ (secondsInYear * BigInt.from(100));
  }

  // Функция для расчета скорости (rate) $MEGA/сек
  double _getMegaRatePerSec() {
    if (megaStakedAmountRaw == BigInt.zero) return 0.0;
    final double rate = (megaStakedAmountRaw.toDouble() * 15) / (31536000 * 100 * pow(10, decimals));
    return rate;
  }

  // Функция для обновления меток $MEGA (награда, USD, rate)
  void _updateMegaLabels() {
    setState(() {
      // Награда в $MEGA
      final double megaRewardFloat = megaCurrentReward.toDouble() / pow(10, decimals);
      final double megaPriceInApt = _getMegaPriceInApt();
      final double megaRewardUsd = megaRewardFloat * megaPriceInApt * priceApt;

      // Обновляем текст награды с USD в скобках (зелёным цветом)
      megaRewardText = "${megaRewardFloat.toStringAsFixed(8).replaceAll(".", ",")} \$MEGA";
      if (priceApt > 0) {
        //megaRewardText += " (\$${megaRewardUsd.toStringAsFixed(8).replaceAll(".", ",")})"; 
        megaRewardText += "\n(\$${megaRewardUsd.toStringAsFixed(8).replaceAll(".", ",")})";
      }

      // Доходность: 15% APR (rate $MEGA/сек)
      final double megaRate = _getMegaRatePerSec();
      megaRateText = "15% APR (${megaRate.toStringAsFixed(10).replaceAll(".", ",")} \$MEGA / сек)";
    });
  }




  // Функция для таймера unstake $MEGA (аналогично _buildUnlockCountdown для MEE, добавил секунды)
  Widget _buildMegaUnlockCountdown() {
    if (megaUnlockTime == BigInt.zero) return const SizedBox();


    final int now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final BigInt nowSynced = BigInt.from(now) + megaNetworkTimeOffset;
    final BigInt remaining = megaUnlockTime - nowSynced;

    if (remaining <= BigInt.zero) { 
      isMegaUnlockComplete = true;
      return const Text("✅ Можно выводить!", style: TextStyle(color: Colors.greenAccent, fontSize: 11));
    } else {
      isMegaUnlockComplete = false;
    }

    
    final BigInt days = remaining ~/ BigInt.from(86400);
    final BigInt hours = (remaining % BigInt.from(86400)) ~/ BigInt.from(3600);
    final BigInt minutes = (remaining % BigInt.from(3600)) ~/ BigInt.from(60);
    final BigInt seconds = remaining % BigInt.from(60);
    
    return Text(
      "До завершения: $days д. $hours ч. $minutes мин. $seconds сек.",
      style: const TextStyle(color: Colors.white54, fontSize: 11),
    );
    
  }

  // Функция для синхронизации данных $MEGA с блокчейном (вызывается в _runUpdateThread)
  Future<void> _fetchMegaStakeData() async {
    try {
      final url = Uri.parse("$aptLedgerUrl/accounts/$currentWalletAddress/resource/0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3::mega_coin::StakePosition");
      final headers = {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36',
        'Accept': 'application/json',
      };
      final response = await http.get(url, headers: headers).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = json.decode(response.body)['data'];
        if (data != null) { // Добавил проверку
          megaStakedAmountRaw = BigInt.parse(data['amount'] ?? '0');
          megaLastUpdate = BigInt.parse(data['last_update'] ?? '0');
          megaUnlockTime = BigInt.parse(data['unlock_time'] ?? '0');
          megaStakeBalance = megaStakedAmountRaw.toDouble() / pow(10, decimals);

          // Расчет megaInUsd
          final double megaPriceInApt = _getMegaPriceInApt();
          megaInUsd = megaStakeBalance * megaPriceInApt * priceApt;

          // Смещение времени сети
          final ledgerResponse = await http.get(Uri.parse(aptLedgerUrl));
          if (ledgerResponse.statusCode == 200) {
            final ledgerData = json.decode(ledgerResponse.body);
            final BigInt ledgerTimeSec = BigInt.from(int.parse(ledgerData['ledger_timestamp']) ~/ 1000000);
            final BigInt localTimeSec = BigInt.from(DateTime.now().millisecondsSinceEpoch ~/ 1000);
            megaNetworkTimeOffset = ledgerTimeSec - localTimeSec;
          }
        }
      }
    } catch (e) {
      //debugPrint("Mega stake fetch error: $e");
    }
  }

  // Функция для запуска симуляции $MEGA
  void _startMegaSimulation() {
    _calculateMegaRewardLocally();
    _updateMegaLabels();
  }

  void _showContractsDialog() {
  showDialog(
    context: context,
    builder: (BuildContext context) {
      return AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(15),
          side: const BorderSide(color: Colors.blueAccent, width: 1.5),
        ),
        title: const Center(
          child: Text(
            "📜 Контракты монет",
            style: TextStyle(
              color: Colors.blueAccent,
              fontWeight: FontWeight.bold,
              fontSize: 18,
            ),
          ),
        ),
        content: SingleChildScrollView(
          child: RichText(
            textAlign: TextAlign.center,
            text: TextSpan(
              style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.5),
              children: [
                const TextSpan(
                  text: "Контракт монеты ",
                  style: TextStyle(color: Colors.white70),
                ),
                const TextSpan(
                  text: "\$MEE",
                  style: TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold),
                ),
                const TextSpan(text: ":\n"),
                WidgetSpan(
                  child: GestureDetector(
                    onTap: () async {
                      await Clipboard.setData(const ClipboardData(
                        text: "0xe9c192ff55cffab3963c695cff6dbf9dad6aff2bb5ac19a6415cad26a81860d9::mee_coin::MeeCoin",
                      ));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text("Контракт \$MEE скопирован в буфер"),
                          duration: Duration(seconds: 3),
                        ),
                      );
                    },
                    child: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 6),
                      child: Text(
                        "0xe9c192ff55cffab3963c695cff6dbf9dad6aff2bb5ac19a6415cad26a81860d9::mee_coin::MeeCoin",
                        style: TextStyle(
                          color: Colors.cyanAccent,
                          fontSize: 13,
                          decoration: TextDecoration.underline,
                          decorationColor: Colors.cyanAccent,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
                const TextSpan(text: "\n\n"),
                const TextSpan(
                  text: "Контракт монеты ",
                  style: TextStyle(color: Colors.white70),
                ),
                const TextSpan(
                  text: "\$MEGA",
                  style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold),
                ),
                const TextSpan(text: ":\n"),
                WidgetSpan(
                  child: GestureDetector(
                    onTap: () async {
                      await Clipboard.setData(const ClipboardData(
                        text: "0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3::mega_coin::MEGA",
                      ));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text("Контракт \$MEGA скопирован в буфер"),
                          duration: Duration(seconds: 3),
                        ),
                      );
                    },
                    child: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 6),
                      child: Text(
                        "0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3::mega_coin::MEGA",
                        style: TextStyle(
                          color: Colors.greenAccent,
                          fontSize: 13,
                          decoration: TextDecoration.underline,
                          decorationColor: Colors.greenAccent,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
                const TextSpan(text: "\n\n"),
                const TextSpan(
                  text: "Купить/продать (Swap tokens)",
                  style: TextStyle(color: Colors.white70),
                ),
                const TextSpan(
                  text: "\$MEE ",
                  style: TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold),
                ),
                const TextSpan(text: "можно в кошельке Petra.\n"),
                const TextSpan(
                  text: "\$MEGA - идет MINT до 19.11.2026",
                  style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold),
                ),
                const TextSpan(text: "— кликните на баннер GTA 6."),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            style: TextButton.styleFrom(foregroundColor: Colors.blueAccent),
            child: const Text("Закрыть", style: TextStyle(fontSize: 16)),
          ),
        ],
        actionsPadding: const EdgeInsets.only(bottom: 12, right: 12, left: 12),
      );
    },
  );
}

////////////// #swap   ( _showSwapDialog  _swapAptToMee  _swapMeeToApt _swapAptToMega)

Future<void> _showSwapDialog() async {
  final TextEditingController inputController = TextEditingController();
  final TextEditingController outputController = TextEditingController();

  const int decimalsApt = 8;
  const int decimalsMee = 6;

  BigInt reserveAptRaw = BigInt.zero;
  BigInt reserveMeeRaw = BigInt.zero;
  bool poolDataLoaded = false;

  try {
    final response = await http.get(Uri.parse(poolUrl)).timeout(const Duration(seconds: 5));
    if (response.statusCode == 200) {
      final data = json.decode(response.body)['data'];
      reserveAptRaw = BigInt.parse(data['balance_x']['value'] ?? '0');
      reserveMeeRaw = BigInt.parse(data['balance_y']['value'] ?? '0');
      poolDataLoaded = true;
    }
  } catch (e) {
    //debugPrint("Ошибка пула: $e");
  }

  void recalculate() {
    final double inputVal = double.tryParse(inputController.text) ?? 0.0;
    if (inputVal <= 0) {
      outputController.text = "0.000000";
      return;
    }

    double outputVal = 0.0;

    if (isMegaDirection) {
        final double megaPriceInApt = _getMegaPriceInApt();
        // НОВАЯ ЛОГИКА РАСЧЕТА:
        if (isMegaToAptDirection) {
          // MEGA -> APT
          outputVal = inputVal * megaPriceInApt;
        } else {
          // APT -> MEGA
          outputVal = megaPriceInApt > 0 ? inputVal / megaPriceInApt : 0.0;
        }
      } else if (poolDataLoaded && reserveAptRaw > BigInt.zero && reserveMeeRaw > BigInt.zero) {
      if (isAptToMeeDirection) {
        final BigInt inRaw = BigInt.from((inputVal * pow(10, decimalsApt)).round());
        final BigInt inFee = inRaw * BigInt.from(997);
        final BigInt num = inFee * reserveMeeRaw;
        final BigInt den = reserveAptRaw * BigInt.from(1000) + inFee;
        outputVal = num.toDouble() / den.toDouble() / pow(10, decimalsMee);
      } else {
        final BigInt inRaw = BigInt.from((inputVal * pow(10, decimalsMee)).round());
        final BigInt inFee = inRaw * BigInt.from(997);
        final BigInt num = inFee * reserveAptRaw;
        final BigInt den = reserveMeeRaw * BigInt.from(1000) + inFee;
        outputVal = num.toDouble() / den.toDouble() / pow(10, decimalsApt);
      }
    } else {
      if (isAptToMeeDirection) {
        outputVal = inputVal * priceApt / priceMee * pow(10, decimalsApt - decimalsMee);
      } else {
        outputVal = inputVal * priceMee / priceApt * pow(10, decimalsMee - decimalsApt);
      }
    }

    outputController.text = outputVal.toStringAsFixed(6);
  }

  inputController.addListener(recalculate);
  recalculate();

  if (!mounted) return;

  await showDialog(
    context: context,
    builder: (BuildContext dialogCtx) {
      return StatefulBuilder(
        builder: (context, setDialogState) {
          final bool isMegaMode = isMegaDirection;

          return AlertDialog(
            backgroundColor: const Color(0xFF1A1A1A),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(15),
              side: const BorderSide(color: Colors.blueAccent, width: 1.5),
            ),
            title: Text(
              isMegaMode
                  ? (isMegaToAptDirection ? "Обмен MEGA → APT" : "Обмен APT → MEGA")
                  : (isAptToMeeDirection ? "Обмен APT → MEE" : "Обмен MEE → APT"),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isMegaMode ? Colors.greenAccent : Colors.blueAccent,
                fontWeight: FontWeight.bold,
                fontSize: 18,
              ),
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [

                 
                  // --- БАЛАНСЫ МОНЕТ (ТЕПЕРЬ ВВЕРХУ) ---
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // APT
                      GestureDetector(
                        onTap: () {
                          if (aptOnChain > 0) {
                            inputController.text = aptOnChain.toStringAsFixed(6);
                            setDialogState(() {
                              if (isMegaMode) {
                                isMegaToAptDirection = false;
                              } else {
                                isMegaDirection = false;
                                isAptToMeeDirection = true;
                              }
                              recalculate();
                            });
                          }
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Image.asset('assets/apt.png', width: 18, height: 18),
                              const SizedBox(width: 8),
                              Text(
                                "APT: ${aptOnChain.toStringAsFixed(6)}",
                                style: TextStyle(
                                  color: aptOnChain > 0 ? Colors.blueAccent : Colors.grey,
                                  fontSize: 13,
                                  decoration: aptOnChain > 0 ? TextDecoration.underline : null,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      // MEE
                      GestureDetector(
                        onTap: () {
                          if (meeOnChain > 0) {
                            inputController.text = meeOnChain.toStringAsFixed(6);
                            setDialogState(() {
                              isMegaDirection = false;
                              isAptToMeeDirection = false;
                              recalculate();
                            });
                          }
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Image.asset('assets/mee.png', width: 18, height: 18),
                              const SizedBox(width: 8),
                              Text(
                                "MEE: ${meeOnChain.toStringAsFixed(6)}",
                                style: TextStyle(
                                  color: meeOnChain > 0 ? Colors.cyanAccent : Colors.grey,
                                  fontSize: 13,
                                  decoration: meeOnChain > 0 ? TextDecoration.underline : null,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      // MEGA
                      GestureDetector(
                        onTap: () {
                          if (megaOnChain > 0) {
                            inputController.text = megaOnChain.toStringAsFixed(8);
                            setDialogState(() {
                              isMegaDirection = true;
                              isMegaToAptDirection = true;
                              recalculate();
                            });
                          }
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Image.asset('assets/mega.png', width: 18, height: 18),
                              const SizedBox(width: 8),
                              Text(
                                "MEGA: ${megaOnChain.toStringAsFixed(8)}",
                                style: TextStyle(
                                  color: megaOnChain > 0 ? Colors.greenAccent : Colors.grey,
                                  fontSize: 13,
                                  decoration: megaOnChain > 0 ? TextDecoration.underline : null,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  

                 
                  
                  const SizedBox(height: 8),

                  // Курс
                  Text(
                    isMegaMode
                        ? (isMegaToAptDirection 
                            ? "1 MEGA ≈ ${_getMegaPriceInApt().toStringAsFixed(6)} APT" 
                            : "1 APT ≈ ${(1 / _getMegaPriceInApt()).toStringAsFixed(2)} MEGA")
                        : poolDataLoaded
                            ? isAptToMeeDirection
                                ? "1 APT ≈ ${(reserveMeeRaw.toDouble() / reserveAptRaw.toDouble() * pow(10, 8 - 6)).toStringAsFixed(6)} MEE"
                                : "1 MEE ≈ ${(reserveAptRaw.toDouble() / reserveMeeRaw.toDouble() * pow(10, 6 - 8)).toStringAsFixed(6)} APT"
                            : isAptToMeeDirection
                                ? "≈ ${(priceApt / priceMee).toStringAsFixed(6)} MEE"
                                : "≈ ${(priceMee / priceApt).toStringAsFixed(6)} APT",
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                    textAlign: TextAlign.center,
                  ),

                  const SizedBox(height: 8),

                 
                  const SizedBox(height: 4),
                 
                  TextField(
                    controller: inputController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      hintText: "0.0",
                      // Используем prefixIcon, помещая в него Row с иконкой и текстом
                      prefixIcon: Container(
                        // Увеличиваем ширину, чтобы влезла и иконка, и текст MEGA
                        width: 95, 
                        padding: const EdgeInsets.only(left: 10),
                        child: Row(
                          mainAxisSize: MainAxisSize.min, // Важно: чтобы Row не занимал все поле
                          children: [
                            // Динамическая иконка
                            Image.asset(
                              isMegaMode
                                  ? (isMegaToAptDirection ? 'assets/mega.png' : 'assets/apt.png')
                                  : (isAptToMeeDirection ? 'assets/apt.png' : 'assets/mee.png'),
                              width: 20,
                              height: 20,
                            ),
                            const SizedBox(width: 6),
                            // Название монеты
                            Text(
                              isMegaMode
                                  ? (isMegaToAptDirection ? "MEGA:" : "APT:")
                                  : (isAptToMeeDirection ? "APT:" : "MEE:"),
                              style: TextStyle(
                                color: isMegaMode
                                    ? (isMegaToAptDirection ? Colors.greenAccent : Colors.blueAccent)
                                    : (isAptToMeeDirection ? Colors.blueAccent : Colors.cyanAccent),
                                fontSize: 15, // Чуть уменьшил шрифт, чтобы точно не переносило
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                      prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
                      filled: true,
                      fillColor: const Color(0xFF2C2C2C),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                    onChanged: (value) {
                      setDialogState(() {
                        recalculate();
                      });
                    },
                  ),




                  // --- КНОПКА СМЕНЫ КУРСА (МЕЖДУ ОКНАМИ) ---
                  IconButton(
                    icon: const Icon(Icons.swap_vert, color: Colors.cyanAccent, size: 32),
                    onPressed: () {
                      setDialogState(() {
                        if (isMegaMode) {
                          isMegaToAptDirection = !isMegaToAptDirection;
                        } else {
                          isAptToMeeDirection = !isAptToMeeDirection;
                        }
                        inputController.clear();
                        outputController.clear();
                        recalculate();
                      });
                    },
                  ),

                 
                  const SizedBox(height: 4),
                 
                 
                TextField(
                  controller: outputController,
                  enabled: false, // Поле только для чтения
                  decoration: InputDecoration(
                    hintText: "0.000000",
                    // Префикс для поля ВЫВОДА
                    prefixIcon: Container(
                      width: 95, 
                      padding: const EdgeInsets.only(left: 10),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Иконка монеты, которую ПОЛУЧАЕМ
                          Image.asset(
                            isMegaMode
                                ? (isMegaToAptDirection ? 'assets/apt.png' : 'assets/mega.png')
                                : (isAptToMeeDirection ? 'assets/mee.png' : 'assets/apt.png'),
                            width: 20,
                            height: 20,
                          ),
                          const SizedBox(width: 6),
                          // Название монеты
                          Text(
                            isMegaMode
                                ? (isMegaToAptDirection ? "APT:" : "MEGA:")
                                : (isAptToMeeDirection ? "MEE:" : "APT:"),
                            style: TextStyle(
                              color: isMegaMode
                                  ? (isMegaToAptDirection ? Colors.blueAccent : Colors.greenAccent)
                                  : (isAptToMeeDirection ? Colors.cyanAccent : Colors.blueAccent),
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                    prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
                    filled: true,
                    fillColor: const Color(0xFF2C2C2C),
                    // Добавляем границы для выключенного состояния
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    disabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: Colors.white10), 
                    ),
                  ),
                  // Стиль цифр в поле вывода
                  style: const TextStyle(
                    color: Colors.greenAccent, 
                    fontSize: 16, 
                    fontWeight: FontWeight.bold
                  ),
                ),
                

                  const SizedBox(height: 10),
                  Text(
                    isMegaMode
                        ? "Примерный расчёт по цене MEGA"
                        : poolDataLoaded
                            ? "Расчёт по пулу • комиссия 0.3%"
                            : "Примерный расчёт по ценам",
                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
           
            actions: [

              if (!isPetraConnected)
                ElevatedButton.icon(
                  icon: const Icon(Icons.account_balance_wallet, size: 18, color: Colors.blueAccent),
                  label: const Text(
                    "Подключить Petra",
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueAccent.withOpacity(0.1),
                    foregroundColor: Colors.blueAccent,
                    side: const BorderSide(color: Colors.blueAccent, width: 1.5),
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onPressed: () {
                    Navigator.pop(dialogCtx);   // закрываем окно обмена
                    _connectPetra();            // открываем подключение Petra
                  },
                ),
             
              
              if (isPetraConnected)
                ElevatedButton.icon(
                  icon: const Icon(Icons.swap_horiz),
                  label: const Text("Обмен в Petra"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green.shade700,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () {
                    // --- Функция для вывода ошибки поверх ---
                    void showError(String message) {
                      showDialog(
                        context: context,
                        builder: (BuildContext errorCtx) {
                          return AlertDialog(
                            backgroundColor: const Color(0xFF1A1A1A),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                              side: const BorderSide(color: Colors.redAccent, width: 1.5),
                            ),
                            title: const Row(
                              children: [
                                Icon(Icons.error_outline, color: Colors.redAccent),
                                SizedBox(width: 10),
                                Text("Ошибка", style: TextStyle(color: Colors.redAccent, fontSize: 16)),
                              ],
                            ),
                            content: Text(message, style: const TextStyle(color: Colors.white70)),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(errorCtx),
                                child: const Text("ОК", style: TextStyle(color: Colors.blueAccent)),
                              ),
                            ],
                          );
                        },
                      );
                    }

                    final double inputAmount = double.tryParse(inputController.text) ?? 0.0;

                    // 1. Проверка на пустой ввод
                    if (inputAmount <= 0) {
                      showError("Введите сумму для обмена");
                      return;
                    }

                    // 2. Проверка баланса
                    double currentBalance = 0.0;
                    if (isMegaMode) {
                      currentBalance = isMegaToAptDirection ? megaOnChain : aptOnChain;
                    } else {
                      currentBalance = isAptToMeeDirection ? aptOnChain : meeOnChain;
                    }

                    if (inputAmount > currentBalance) {
                      showError("Недостаточно средств.\nБаланс: ${currentBalance.toStringAsFixed(6)}");
                      return;
                    }

                    // 3. Логика для MEGA
                    if (isMegaMode && isMegaToAptDirection) {
                      showDialog(
                        context: context,
                        builder: (BuildContext ctx) {
                          return AlertDialog(
                            backgroundColor: const Color(0xFF1A1A1A),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(15),
                              side: const BorderSide(color: Colors.blueAccent, width: 1.5),
                            ),
                            title: const Center(
                              child: Text("Информация", style: TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold)),
                            ),
                            content: const Text(
                              "Обмен MEGA → APT будет запущен\n19 ноября 2026 года",
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.white70, fontSize: 15),
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx),
                                child: const Text("Понял"),
                              ),
                            ],
                          );
                        },
                      );
                      return;
                    }

                    // 4. Выполнение обмена (окно не закрываем)
                    if (isMegaMode) {
                      final double megaOut = double.tryParse(outputController.text) ?? 0.0;
                      _swapAptToMega(megaOut);
                    } else {
                      if (isAptToMeeDirection) {
                        _swapAptToMee(inputAmount);
                      } else {
                        _swapMeeToApt(inputAmount);
                      }
                    }
                  },
                ),

                 TextButton(
                onPressed: () => Navigator.pop(dialogCtx),
                style: TextButton.styleFrom(foregroundColor: Colors.blueAccent),
                child: const Text("Закрыть"),
              ),
            ],

            
            ////////////////////
          );
        },
      );
    },
).then((_) {
    inputController.removeListener(recalculate);
    Future.delayed(Duration.zero, () {
      inputController.dispose();
      outputController.dispose();
    });
  });
}

// === send ОТПРАВИТЬ (APT / MEE / MEGA) ===
Future<void> _showSendDialog() async {
  if (!isPetraConnected) {
    _showPetraRequiredDialog();
    return;
  }

  String selectedCoin = "APT";
  final TextEditingController amountCtrl = TextEditingController();
  final TextEditingController recipientCtrl = TextEditingController();

  final Map<String, dynamic> coinInfo = {
    "APT":  {"bal": aptOnChain,  "dec": 8,  "type": aptCoinType,     "color": Colors.blueAccent,  "icon": "assets/apt.png"},
    "MEE":  {"bal": meeOnChain,  "dec": 6,  "type": meeCoinT0T1,    "color": Colors.cyanAccent,  "icon": "assets/mee.png"},
    "MEGA": {"bal": megaOnChain, "dec": 8,  "type": megaCoinType,    "color": Colors.greenAccent, "icon": "assets/mega.png"},
  };

  await showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (context, setStateDlg) {
        final info = coinInfo[selectedCoin]!;

        return AlertDialog(
          backgroundColor: const Color(0xFF1A1A1A),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15), side: const BorderSide(color: Colors.blueAccent, width: 1.5)),
          title: const Text("Отправить", style: TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Выбор монеты
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: coinInfo.keys.map((c) {
                    final bool sel = selectedCoin == c;
                    final info = coinInfo[c]!;

                    return GestureDetector(
                      onTap: () => setStateDlg(() { 
                        selectedCoin = c; 
                        amountCtrl.clear(); 
                      }),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        decoration: BoxDecoration(
                          color: sel ? info["color"].withOpacity(0.15) : Colors.white10,
                          border: Border.all(
                            color: sel ? info["color"] : Colors.white24,
                            width: sel ? 2 : 1,
                          ),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Image.asset(info["icon"], width: 24, height: 24),
                            const SizedBox(width: 8),
                            Text(
                              c,
                              style: TextStyle(
                                color: sel ? info["color"] : Colors.white70,
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),

                const SizedBox(height: 16),
                Text("Баланс: ${info["bal"].toStringAsFixed(6)} $selectedCoin", style: const TextStyle(color: Colors.white70)),

                const SizedBox(height: 12),
                TextField(
                  controller: amountCtrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: "Сумма",
                    suffixIcon: TextButton(onPressed: () => amountCtrl.text = info["bal"].toStringAsFixed(info["dec"]), child: const Text("MAX")),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),

                const SizedBox(height: 12),
                TextField(
                  controller: recipientCtrl,
                  decoration: InputDecoration(
                    labelText: "Адрес получателя (0x...)",
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.paste),
                      onPressed: () async {
                        final data = await Clipboard.getData(Clipboard.kTextPlain);
                        if (data?.text != null) recipientCtrl.text = data!.text!.trim();
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Отмена")),
            ElevatedButton(
              onPressed: () async {
                final double amt = double.tryParse(amountCtrl.text) ?? 0;
                final String to = recipientCtrl.text.trim();

                if (amt <= 0 || amt > info["bal"]) {
                  showTopToast("Неверная сумма", isError: true);
                  return;
                }
                if (!to.startsWith("0x") || to.length != 66) {
                  showTopToast("Неверный адрес (должен быть 66 символов 0x...)", isError: true);
                  return;
                }

                Navigator.pop(ctx);

                final BigInt raw = BigInt.from((amt * pow(10, info["dec"])).round());

                final payload = {
                  "type": "entry_function_payload",
                  "function": "0x1::coin::transfer",
                  "type_arguments": [info["type"]],
                  "arguments": [to, raw.toString()],
                };

                try {
                  await _sendAptosTransaction(payload);
                  showTopToast("✅ Транзакция отправлена в Petra");
                } catch (e) {
                  showTopToast("Ошибка: $e", isError: true);
                }
              },
              child: const Text("Отправить в Petra"),
            ),
          ],
        );
      },
    ),
  );

  amountCtrl.dispose();
  recipientCtrl.dispose();
}





///// swap apt - mee

Future<void> _swapAptToMee(double amount) async {
  if (!isPetraConnected) {
    showTopToast("❌ Подключите Petra для обмена");
    return;
  }

  // --- ПРОВЕРКА баланса на газ ---
  /*
  if (aptOnChain < 0.20) {
    showTopToast("❌ Недостаточно APT. Petra требует минимум 0.20 APT на балансе.");
    return;
  }*/

  if (_myKeyPair == null) {
    showTopToast("❌ Ошибка: ключи не инициализированы.\nВ Petra → Настройки → Security & Privacy → Connected apps → удалите mega.io и подключитесь заново.", isError: true);
    return;
  }

  /*
  if (amount <= 0.0009) {
    showTopToast("❌ Минимальная сумма: 0.001 APT");
    return;
  }*/

  final double safeAmount = amount; 
  final prefs = await SharedPreferences.getInstance();
  
  // Достаем ключи
  String? petraKeyHex = prefs.getString('petra_saved_pub_key');
  final String? savedPrivKey = prefs.getString('petra_temp_priv_key');

  if (petraKeyHex == null || savedPrivKey == null) {
    showTopToast("❌ Ошибка: ключи не инициализированы.\nПожалуйста, переподключите кошелёк.", isError: true);
    return;
  }

  try {
    // 1. Очистка ключа Petra от 0x
    if (petraKeyHex.startsWith('0x')) {
      petraKeyHex = petraKeyHex.substring(2);
    }

    // Загружаем резервы пула для расчёта min_out
    BigInt reserveAptRaw = BigInt.zero;
    BigInt reserveMeeRaw = BigInt.zero;

    final poolResponse = await http.get(Uri.parse(poolUrl)).timeout(const Duration(seconds: 5));
    if (poolResponse.statusCode == 200) {
      final data = json.decode(poolResponse.body)['data'];
      reserveAptRaw = BigInt.parse(data['balance_x']['value'] ?? '0');
      reserveMeeRaw = BigInt.parse(data['balance_y']['value'] ?? '0');
    }

    // Рассчитываем amount_out_min (с 1% slippage)
    BigInt amountOutMinRaw = BigInt.zero;
    if (reserveAptRaw > BigInt.zero && reserveMeeRaw > BigInt.zero) {
      final BigInt amountInRaw = BigInt.from((safeAmount * pow(10, decimals)).round());
      final BigInt amountInWithFee = amountInRaw * BigInt.from(997); // 0.3% fee
      final BigInt numerator = amountInWithFee * reserveMeeRaw;
      final BigInt denominator = reserveAptRaw * BigInt.from(1000) + amountInWithFee;
      final double estimatedOut = numerator.toDouble() / denominator.toDouble();
      // Рассчитываем min_out с учетом проскальзывания 1%
      amountOutMinRaw = BigInt.from((estimatedOut * 0.99).round()); 
    }

    // 2. Формируем Payload для Liquidswap (Router)
    final txObject = {
      "type": "entry_function_payload",
      "function": "0xc7efb4076dbe143cbcd98cfaaa929ecfc8f299203dfff63b95ccb6bfe19850fa::router::swap_exact_input",
      "type_arguments": [aptCoinType, meeCoinT0T1],
      "arguments": [
        (safeAmount * pow(10, decimals)).toInt().toString(),  // x_in: u64
        amountOutMinRaw.toString(),                           // y_min_out: u64
      ],
    };

    final innerJsonString = jsonEncode(txObject);
    final innerBase64 = base64.encode(utf8.encode(innerJsonString));

    // 3. Шифрование
    final myPrivKey = pine.PrivateKey(base64.decode(savedPrivKey));
    final petraPubKey = pine.PublicKey(_hexToBytes(petraKeyHex));

    final box = pine.Box(myPrivateKey: myPrivKey, theirPublicKey: petraPubKey);
    final nonce = pine.PineNaClUtils.randombytes(24);
    final encrypted = box.encrypt(utf8.encode(innerBase64), nonce: nonce);

    // 4. Подготовка нашего публичного ключа DApp
    final pubKey = await _myKeyPair!.extractPublicKey();
    String myPubKeyHex = _bytesToHex(Uint8List.fromList(pubKey.bytes));
    
    if (myPubKeyHex.startsWith('0x')) {
      myPubKeyHex = myPubKeyHex.substring(2);
    }

    // 5. Итоговый запрос
    final finalRequest = {
      "appInfo": {"name": "Mega App", "domain": "https://mega.io"},
      "dappEncryptionPublicKey": myPubKeyHex,
      "nonce": _bytesToHex(Uint8List.fromList(nonce)),
      "payload": _bytesToHex(Uint8List.fromList(encrypted.cipherText)),
      "redirectLink": "mega://api/v1/swap_apt_mee",
    };

    final dataParam = base64.encode(utf8.encode(jsonEncode(finalRequest)));
    final url = Uri.parse("petra://api/v1/signAndSubmit?data=$dataParam");

    //debugPrint("🚀 Запуск свопа: $safeAmount APT -> MEE");
    //debugPrint("📡 Min Out Raw: $amountOutMinRaw");

    showTopToast("🔄 Обмен APT на MEE...\nПереходим в Petra");
    await Future.delayed(const Duration(seconds: 2));

    await launchUrl(url, mode: LaunchMode.externalApplication);

    final double minOutDisplay = amountOutMinRaw.toDouble() / pow(10, 6);

    /*
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            "Своп запущен: $safeAmount APT → MEE (мин: ${minOutDisplay.toStringAsFixed(4)})"
          ),
          backgroundColor: Colors.green.shade800,
          duration: const Duration(seconds: 6),
        ),
      );
    } */

  } catch (e, stack) {
    //debugPrint("❌ Swap Error: $e");
    //debugPrint("Stack: $stack");
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Ошибка: $e"), backgroundColor: Colors.red.shade800),
      );
    }
  }
}


///// swap mee - apt

Future<void> _swapMeeToApt(double amount) async {
  if (!isPetraConnected) {
    showTopToast("❌ Подключите Petra для обмена");
    return;
  }

  // Проверка баланса MEE (с учетом небольшого запаса)
  /*
  if (meeOnChain < amount + 0.1) {
    showTopToast("Недостаточно MEE. Требуется минимум ${amount.toStringAsFixed(2)} + запас", isError: true);
    return;
  }*/

  if (_myKeyPair == null) {
    showTopToast("❌ Ошибка: ключи не инициализированы.\nВ Petra → Настройки → Security & Privacy → Connected apps → удалите mega.io и подключитесь заново.", isError: true);
    return;
  }

  /*
  if (amount <= 0.9) {
    showTopToast("❌ Минимальная сумма: 1 MEE");
    return;
  }*/

  final double safeAmount = amount;
  final prefs = await SharedPreferences.getInstance();
  
  // Достаем ключи из SharedPreferences
  String? petraKeyHex = prefs.getString('petra_saved_pub_key');
  final String? savedPrivKey = prefs.getString('petra_temp_priv_key');

  if (petraKeyHex == null || savedPrivKey == null) {
    showTopToast("❌ Ошибка: ключи не инициализированы.\nПожалуйста, переподключите кошелёк.", isError: true);
    return;
  }

  try {
    // 1. Очистка ключа Petra от префикса 0x
    if (petraKeyHex.startsWith('0x')) {
      petraKeyHex = petraKeyHex.substring(2);
    }

    // Загружаем резервы пула для расчёта (X - APT, Y - MEE)
    BigInt reserveAptRaw = BigInt.zero;
    BigInt reserveMeeRaw = BigInt.zero;
    final poolResponse = await http.get(Uri.parse(poolUrl)).timeout(const Duration(seconds: 5));
    if (poolResponse.statusCode == 200) {
      final data = json.decode(poolResponse.body)['data'];
      reserveAptRaw = BigInt.parse(data['balance_x']['value'] ?? '0');
      reserveMeeRaw = BigInt.parse(data['balance_y']['value'] ?? '0');
    }

    // Рассчитываем минимальный выход APT (8 decimals) с 1% slippage
    BigInt amountOutMinRaw = BigInt.zero;
    if (reserveAptRaw > BigInt.zero && reserveMeeRaw > BigInt.zero) {
      // MEE (amount_in) имеет 6 знаков
      final BigInt amountInRaw = BigInt.from((safeAmount * pow(10, 6)).round());
      final BigInt amountInWithFee = amountInRaw * BigInt.from(997); // 0.3% комиссия
      final BigInt numerator = amountInWithFee * reserveAptRaw;
      final BigInt denominator = reserveMeeRaw * BigInt.from(1000) + amountInWithFee;
      
      final double estimatedOut = numerator.toDouble() / denominator.toDouble();
      // Высчитываем min_out с 1% проскальзывания
      amountOutMinRaw = BigInt.from((estimatedOut * 0.99).round());
    }

    // 2. Payload для Liquidswap Router (MEE -> APT)
    final txObject = {
      "type": "entry_function_payload",
      "function": "0xc7efb4076dbe143cbcd98cfaaa929ecfc8f299203dfff63b95ccb6bfe19850fa::router::swap_exact_input",
      "type_arguments": [meeCoinT0T1, aptCoinType], // Порядок: In (MEE) -> Out (APT)
      "arguments": [
        (safeAmount * pow(10, 6)).toInt().toString(), // x_in (MEE, 6 decimals)
        amountOutMinRaw.toString(),                   // y_min_out (APT, 8 decimals)
      ],
    };

    final innerJsonString = jsonEncode(txObject);
    final innerBase64 = base64.encode(utf8.encode(innerJsonString));

    // 3. Шифрование пакета
    final myPrivKey = pine.PrivateKey(base64.decode(savedPrivKey));
    final petraPubKey = pine.PublicKey(_hexToBytes(petraKeyHex));
    final box = pine.Box(myPrivateKey: myPrivKey, theirPublicKey: petraPubKey);
    final nonce = pine.PineNaClUtils.randombytes(24);
    final encrypted = box.encrypt(utf8.encode(innerBase64), nonce: nonce);

    // 4. Подготовка нашего публичного ключа DApp
    final pubKey = await _myKeyPair!.extractPublicKey();
    String myPubKeyHex = _bytesToHex(Uint8List.fromList(pubKey.bytes));
    
    if (myPubKeyHex.startsWith('0x')) {
      myPubKeyHex = myPubKeyHex.substring(2);
    }

    // 5. Формирование финального запроса в кошелек
    final finalRequest = {
      "appInfo": {"name": "Mega App", "domain": "https://mega.io"},
      "dappEncryptionPublicKey": myPubKeyHex,
      "nonce": _bytesToHex(Uint8List.fromList(nonce)),
      "payload": _bytesToHex(Uint8List.fromList(encrypted.cipherText)),
      "redirectLink": "mega://api/v1/swap_mee_apt",
    };

    final dataParam = base64.encode(utf8.encode(jsonEncode(finalRequest)));
    final url = Uri.parse("petra://api/v1/signAndSubmit?data=$dataParam");

    //debugPrint("🚀 Запуск обратного свопа: $safeAmount MEE -> APT");
    //debugPrint("📡 Min Out (APT) Raw: $amountOutMinRaw");

    showTopToast("🔄 Обмен MEE на APT...\nПереходим в Petra");
    await Future.delayed(const Duration(seconds: 2));

    await launchUrl(url, mode: LaunchMode.externalApplication);

    // Конвертируем для отображения (APT = 8 decimals)
    final double minOutDisplay = amountOutMinRaw.toDouble() / pow(10, 8);
    /* showTopToast("Своп запущен: $safeAmount MEE → APT\n(мин: ${minOutDisplay.toStringAsFixed(6)})");*/

  } catch (e, stack) {
    //debugPrint("❌ Swap MEE→APT error: $e");
    //debugPrint("Stack: $stack");
    showTopToast("Ошибка обмена: $e", isError: true);
  }
}



//// _swapAptToMega

Future<void> _swapAptToMega(double megaAmount) async {
  if (!isPetraConnected) {
    showTopToast("❌ Подключите Petra для обмена");
    return;
  }

  // Рассчитываем примерную стоимость в APT для проверки
  final double megaPriceInApt = _getMegaPriceInApt();
  final double approxAptCost = megaAmount * megaPriceInApt;

  // Проверка баланса APT (с запасом на газ ~0.01 APT)
  /*if (aptOnChain < approxAptCost + 0.01) {
    showTopToast("Недостаточно APT\nТребуется: ${approxAptCost.toStringAsFixed(6)} + на газ", isError: true);
    return;
  }*/

  if (_myKeyPair == null) {
    showTopToast("❌ Ошибка: ключи не инициализированы.\nВ Petra → Настройки → Security & Privacy → Connected apps → удалите mega.io и подключитесь заново.", isError: true); 
    return;
  }

  /*if (megaAmount < 0.001) {
    showTopToast("❌ Минимальная сумма: 0.001 MEGA"); 
    return;
  }*/

  final prefs = await SharedPreferences.getInstance();
  String? petraKeyHex = prefs.getString('petra_saved_pub_key');
  final String? savedPrivKey = prefs.getString('petra_temp_priv_key');

  if (petraKeyHex == null || savedPrivKey == null) {
    showTopToast("❌ Ошибка: ключи не инициализированы.\nПожалуйста, переподключите кошелёк.", isError: true);
    return;
  }

  try {
    // 1. Очистка ключа Petra от префикса "0x"
    if (petraKeyHex.startsWith('0x')) {
      petraKeyHex = petraKeyHex.substring(2);
    }

    // Raw amount_to_mint (u64) - используем BigInt для точности
    final BigInt amountToMintRaw = BigInt.from((megaAmount * pow(10, decimals)).round());

    // 2. Формируем Payload для harvest_any
    final txObject = {
      "type": "entry_function_payload",
      "function": "0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3::mega_coin::harvest_any",
      "type_arguments": [],
      "arguments": [
        amountToMintRaw.toString(), // В аргументах Aptos всегда передаем числа как строки
      ],
    };

    // 3. Кодирование: JSON -> UTF8 -> Base64
    final innerJsonString = jsonEncode(txObject);
    final innerBase64 = base64.encode(utf8.encode(innerJsonString));

    // 4. Шифрование NaCl Box
    final myPrivKey = pine.PrivateKey(base64.decode(savedPrivKey));
    final petraPubKey = pine.PublicKey(_hexToBytes(petraKeyHex));

    final box = pine.Box(myPrivateKey: myPrivKey, theirPublicKey: petraPubKey);
    final nonce = pine.PineNaClUtils.randombytes(24);
    
    // Шифруем Base64-строку
    final encrypted = box.encrypt(utf8.encode(innerBase64), nonce: nonce);

    // 5. Подготовка нашего публичного ключа DApp
    final pubKey = await _myKeyPair!.extractPublicKey();
    String myPubKeyHex = _bytesToHex(Uint8List.fromList(pubKey.bytes));
    
    // Также убираем 0x у нашего ключа для Petra
    if (myPubKeyHex.startsWith('0x')) {
      myPubKeyHex = myPubKeyHex.substring(2);
    }

    // 6. Итоговый объект запроса
    final finalRequest = {
      "appInfo": {"name": "Mega", "domain": "https://mega.io"},
      "dappEncryptionPublicKey": myPubKeyHex,
      "nonce": _bytesToHex(Uint8List.fromList(nonce)),
      "payload": _bytesToHex(Uint8List.fromList(encrypted.cipherText)),
      "redirectLink": "mega://api/v1/swap_apt_mega",
    };

    final dataParam = base64.encode(utf8.encode(jsonEncode(finalRequest)));
    final url = Uri.parse("petra://api/v1/signAndSubmit?data=$dataParam");

    //debugPrint("🚀 Отправляю запрос harvest_any в Petra...");
    //debugPrint("📡 Сумма минта: $amountToMintRaw units");

    showTopToast("🔄 Обмен APT на MEGA...\nПереходим в Petra");
    await Future.delayed(const Duration(seconds: 2));

    await launchUrl(url, mode: LaunchMode.externalApplication);

    // Показываем подтверждение пользователю
    // showTopToast("Минт запущен:\n${megaAmount.toStringAsFixed(6)} MEGA за ~${approxAptCost.toStringAsFixed(6)} APT");

  } catch (e, stack) {
    //debugPrint("❌ Swap APT→MEGA error: $e");
    //debugPrint("Stack: $stack");
    showTopToast("Ошибка обмена: $e", isError: true);
  }
}


Future<void> _claimTaskReward(String taskId, String secretWord) async {
  if (!isPetraConnected) {
    showTopToast("❌ Сначала подключите кошелек Petra"); 
    return;
  }

  final prefs = await SharedPreferences.getInstance();
  String? petraKeyHex = prefs.getString('petra_saved_pub_key');
  final String? savedPrivKey = prefs.getString('petra_temp_priv_key');

  if (petraKeyHex == null || savedPrivKey == null || _myKeyPair == null) {
    showTopToast("❌ Ошибка: ключи не инициализированы.\nВ Petra → Настройки → Security & Privacy → Connected apps → удалите mega.io и подключитесь заново.", isError: true);
    return;
  }

  try {
    // 1. Очистка ключа Petra от "0x"
    if (petraKeyHex.startsWith('0x')) {
      petraKeyHex = petraKeyHex.substring(2);
    }

    const String moduleAddress = "0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3";

    // --- ХЕШИРОВАНИЕ СЕКРЕТА ---
    final String cleanSecret = secretWord.trim();
    
    // Используем SHA3-256 (библиотека pointycastle)
    var hashDigest = pc.SHA3Digest(256);
    Uint8List hashedSecret = hashDigest.process(Uint8List.fromList(utf8.encode(cleanSecret)));

    //debugPrint("🔑 Исходный секрет: '$cleanSecret'");
    //debugPrint("📡 Отправляем ХЕШ секрета: ${hex.encode(hashedSecret)}");

    // 2. Формируем объект транзакции для метода claim_reward_v2
    final txObject = {
      "type": "entry_function_payload",
      "function": "$moduleAddress::mega_tasks::claim_reward_v2",
      "type_arguments": [],
      "arguments": [
        taskId,
        hashedSecret.toList(), // Контракт ждет vector<u8>
      ],
    };

    // 3. Кодирование транзакции
    final innerJsonString = jsonEncode(txObject);
    final innerBase64 = base64.encode(utf8.encode(innerJsonString));

    // 4. Шифрование NaCl Box
    final myPrivKey = pine.PrivateKey(base64.decode(savedPrivKey));
    final petraPubKey = pine.PublicKey(_hexToBytes(petraKeyHex));
    final box = pine.Box(myPrivateKey: myPrivKey, theirPublicKey: petraPubKey);
    final nonce = pine.PineNaClUtils.randombytes(24);
    
    final encrypted = box.encrypt(utf8.encode(innerBase64), nonce: nonce);

    // 5. Подготовка нашего ключа DApp
    final pubKey = await _myKeyPair!.extractPublicKey();
    String myPubKeyHex = _bytesToHex(Uint8List.fromList(pubKey.bytes));
    
    if (myPubKeyHex.startsWith('0x')) {
      myPubKeyHex = myPubKeyHex.substring(2);
    }

    // 6. Финальный пакет для Petra
    final finalRequest = {
      "appInfo": {"name": "Mega", "domain": "https://mega.io"},
      "dappEncryptionPublicKey": myPubKeyHex,
      "nonce": _bytesToHex(Uint8List.fromList(nonce)),
      "payload": _bytesToHex(Uint8List.fromList(encrypted.cipherText)),
      "redirectLink": "mega://api/v1/claim_task",
    };

    final dataParam = base64.encode(utf8.encode(jsonEncode(finalRequest)));
    final url = Uri.parse("petra://api/v1/signAndSubmit?data=$dataParam");
    
    // 7. Уведомление и запуск
    showTopToast("🔑 Секрет обработан!\nПереходим в Petra для получения награды...");

    // Небольшая задержка, чтобы пользователь успел прочитать тост
    await Future.delayed(const Duration(seconds: 2));

    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } else {
      showTopToast("❌ Ошибка: Кошелек Petra не найден", isError: true);
    }

  } catch (e, stack) {
    //debugPrint("❌ Claim error: $e");
    //debugPrint("Stack: $stack");
    showTopToast("Ошибка: $e", isError: true);
  }
}


// Универсальный метод для отправки транзакций в Petra


Future<void> _sendAptosTransaction(Map<String, dynamic> payload) async {
  if (!isPetraConnected) {
    showTopToast("❌ Подключите Petra");
    return;
  }

  final prefs = await SharedPreferences.getInstance();
  String? petraKeyHex = prefs.getString('petra_saved_pub_key');
  final String? savedPrivKey = prefs.getString('petra_temp_priv_key');

  if (petraKeyHex == null || savedPrivKey == null || _myKeyPair == null) {
    throw Exception(
        "Ошибка ключей. Переподключите кошелек. \nВ Petra → Настройки → Security & Privacy → Connected apps → удалите mega.io и подключитесь заново.");
  }

  try {
    // 1. КРИТИЧЕСКОЕ ИСПРАВЛЕНИЕ: Очищаем публичный ключ Petra от 0x
    if (petraKeyHex.startsWith('0x')) {
      petraKeyHex = petraKeyHex.substring(2);
    }

    // 2. Подготовка данных
    final innerJsonString = jsonEncode(payload);
    final innerBase64 = base64.encode(utf8.encode(innerJsonString));

    // 3. Шифрование
    final myPrivKey = pine.PrivateKey(base64.decode(savedPrivKey));
    final petraPubKey = pine.PublicKey(_hexToBytes(petraKeyHex));
    final box = pine.Box(myPrivateKey: myPrivKey, theirPublicKey: petraPubKey);
    final nonce = pine.PineNaClUtils.randombytes(24);
    final encrypted = box.encrypt(utf8.encode(innerBase64), nonce: nonce);

    // 4. Подготовка нашего публичного ключа DApp
    final pubKey = await _myKeyPair!.extractPublicKey();
    String myPubKeyHex = _bytesToHex(Uint8List.fromList(pubKey.bytes));

    // КРИТИЧЕСКОЕ ИСПРАВЛЕНИЕ: Очищаем наш ключ от 0x для Petra
    if (myPubKeyHex.startsWith('0x')) {
      myPubKeyHex = myPubKeyHex.substring(2);
    }

    // 5. Формируем финальный запрос
    final finalRequest = {
      "appInfo": {"name": "Mega", "domain": "https://mega.io"},
      "dappEncryptionPublicKey": myPubKeyHex,
      "nonce": _bytesToHex(Uint8List.fromList(nonce)),
      "payload": _bytesToHex(Uint8List.fromList(encrypted.cipherText)),
      "redirectLink": "mega://api/v1/transaction",
    };

    final dataParam = base64.encode(utf8.encode(jsonEncode(finalRequest)));
    final url = Uri.parse("petra://api/v1/signAndSubmit?data=$dataParam");

    // 6. Уведомление и переход
    showTopToast("⚙️ Операция подготовлена!\nОткрываем кошелек для подтверждения...");

    // Пауза 2-3 секунды (2 обычно достаточно, чтобы прочитать)
    await Future.delayed(const Duration(seconds: 2));

    if (await canLaunchUrl(url)) {
      //debugPrint("🚀 Запуск универсальной транзакции...");
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } else {
      showTopToast("❌ Кошелек Petra не найден", isError: true);
    }
    
  } catch (e, stack) {
    //debugPrint("❌ Universal Transaction Error: $e");
    //debugPrint("Stack: $stack");
    showTopToast("❌ Ошибка подготовки транзакции", isError: true);
    rethrow; // Пробрасываем ошибку дальше, так как метод используется внутри других try-catch
  }
}



////////// #заработать

void _showClaimDialog(String taskId) {
  final TextEditingController _codeController = TextEditingController();

  showDialog(
    context: context,
    builder: (BuildContext context) {
      return AlertDialog(
        backgroundColor: const Color(0xFF222222),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: Colors.greenAccent, width: 1),
        ),
        title: Text(
          "Задание #$taskId",
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              "Введите секретный код для получения награды:",
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 15),
            TextField(
              controller: _codeController,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: "Секретное слово",
                hintStyle: const TextStyle(color: Colors.white24),
                filled: true,
                fillColor: Colors.black26,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: const BorderSide(color: Colors.greenAccent),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Отмена", style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            onPressed: () async {
              String code = _codeController.text.trim();
              if (code.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("Введите секретный код")),
                );
                return;
              }

            

              print("Введённый код: '$code'");

              Navigator.pop(context);

              // Вызываем функцию отправки в Petra с хэшем вместо чистого кода
              _claimTaskReward(taskId, code);
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.greenAccent.shade700),
            child: const Text("Отправить", style: TextStyle(color: Colors.black)),
          ),
        ],
      );
    },
  );
}

// Вспомогательная функция для уведомлений
void _showSuccessSnackBar(String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), backgroundColor: Colors.green.shade900),
  );
}

/*
void _showV3SubmitDialog(String taskId) {
  final TextEditingController controller = TextEditingController();

  showDialog(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent, // Прозрачный фон для кастомной рамки
      insetPadding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
        // Настройка рамки и фона
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: Colors.purpleAccent.withOpacity(0.3), 
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.purpleAccent.withOpacity(0.1),
              blurRadius: 20,
              spreadRadius: 5,
            ),
          ],
        ),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Отправить ответ",
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 20),
            
            // Поле ввода
            TextField(
              controller: controller,
              maxLines: 5,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              decoration: InputDecoration(
                hintText: "Вставьте ссылку, текст или детали работы...",
                hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
                filled: true,
                fillColor: const Color(0xFF252525),
                contentPadding: const EdgeInsets.all(16),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Color(0xFF333333)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Colors.purpleAccent, width: 1.5),
                ),
              ),
            ),
            
            const SizedBox(height: 16),
            
            // Информационная плашка
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blueAccent.withOpacity(0.05),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline, size: 18, color: Colors.blueAccent.withOpacity(0.7)),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      "После отправки рекламодатель проверит вашу работу перед начислением награды.",
                      style: TextStyle(color: Colors.white60, fontSize: 11, height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
            
            const SizedBox(height: 24),
            
            // Кнопки действий
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(
                    "ОТМЕНА",
                    style: TextStyle(color: Colors.white.withOpacity(0.5), fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(width: 12),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.purpleAccent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    elevation: 0,
                  ),
                  onPressed: () async {
                    final content = controller.text.trim();
                    if (content.isEmpty) {
                      showTopToast("Введите ответ", isError: true);
                      return;
                    }

                    Navigator.pop(ctx);

                    try {
                      final payload = {
                        "type": "entry_function_payload",
                        "function": "0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3::mega_tasks::submit_work_v3",
                        "arguments": [taskId, content],
                      };

                      await _sendAptosTransaction(payload);
                      showTopToast("✅ Ответ отправлен", isError: false);

                      await Future.delayed(const Duration(seconds: 2));
                      await _fetchMegaTasks();
                      _setDialogState?.call(() {});
                    } catch (e) {
                      showTopToast("Ошибка: $e", isError: true);
                    }
                  },
                  child: const Text("ОТПРАВИТЬ", style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  ).then((_) => controller.dispose());
}
*/
void _showV3SubmitDialog(String taskId) {
  final TextEditingController controller = TextEditingController();

  showDialog(
    context: context,
    // Чтобы диалог не прыгал, установим true, если хотим, чтобы он сам обрабатывал клавиатуру
    builder: (ctx) => Scaffold( // Используем Scaffold для корректной работы клавиатуры
      backgroundColor: Colors.transparent,
      body: Center(
        child: SingleChildScrollView( // Позволяет скроллить, если клавиатура закрыла пол-экрана
          child: Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A1A),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: Colors.purpleAccent.withOpacity(0.3),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.purpleAccent.withOpacity(0.1),
                    blurRadius: 20,
                    spreadRadius: 5,
                  ),
                ],
              ),
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min, // Важно!
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "Отправить ответ",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 20),
                  
                  TextField(
                    controller: controller,
                    maxLines: 5,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    decoration: InputDecoration(
                      hintText: "Вставьте ссылку, текст или детали работы...",
                      hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
                      filled: true,
                      fillColor: const Color(0xFF252525),
                      contentPadding: const EdgeInsets.all(16),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Color(0xFF333333)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Colors.purpleAccent, width: 1.5),
                      ),
                    ),
                  ),
                  
                  const SizedBox(height: 16),
                  
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.blueAccent.withOpacity(0.05),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.info_outline, size: 18, color: Colors.blueAccent.withOpacity(0.7)),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text(
                            "После отправки рекламодатель проверит вашу работу перед начислением награды.",
                            style: TextStyle(color: Colors.white60, fontSize: 11, height: 1.4),
                          ),
                        ),
                      ],
                    ),
                  ),
                  
                  const SizedBox(height: 24),
                  
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: Text(
                          "ОТМЕНА",
                          style: TextStyle(color: Colors.white.withOpacity(0.5), fontWeight: FontWeight.w600),
                        ),
                      ),
                      const SizedBox(width: 12),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.purpleAccent,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        onPressed: () async {
                          final content = controller.text.trim();
                          if (content.isEmpty) {
                            showTopToast("Введите ответ", isError: true);
                            return;
                          }
                          Navigator.pop(ctx);
                          // ... ваш код отправки транзакции ...
                          try {
                            final payload = {
                              "type": "entry_function_payload",
                              "function": "0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3::mega_tasks::submit_work_v3",
                              "arguments": [taskId, content],
                            };
                            await _sendAptosTransaction(payload);
                            showTopToast("✅ Ответ отправлен");
                            await Future.delayed(const Duration(seconds: 2));
                            await _fetchMegaTasks();
                            _setDialogState?.call(() {});
                          } catch (e) {
                            showTopToast("Ошибка: $e", isError: true);
                          }
                        },
                        child: const Text("ОТПРАВИТЬ", style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  ).then((_) => controller.dispose());
}


// === НОВОЕ: Диалог выбора типа создания задания ===
void _showTaskCreationChoiceDialog() {
  showDialog(
    context: context,
    builder: (BuildContext ctx) {
      return AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(15),
          side: const BorderSide(color: Colors.blueAccent, width: 1.5),
        ),
        title: const Text(
          "Выберите способ проверки задания",
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 1. Автоматическая проверка
            ElevatedButton.icon(
              icon: const Icon(Icons.auto_awesome, color: Colors.greenAccent),
              label: const Text("Автоматическая проверка"),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green.shade700,
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 48),
              ),
              onPressed: () {
                Navigator.pop(ctx);
                _showCreateTaskForm();
              },
            ),
            const SizedBox(height: 6),
            const Text(
              "Вводите секретный код после выполнения задания — награда приходит мгновенно",
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: Colors.white70,
                height: 1.3,
              ),
            ),

            const SizedBox(height: 20),

            // 2. Ручная проверка
            ElevatedButton.icon(
              icon: const Icon(Icons.person_search, color: Colors.orangeAccent),
              label: const Text("Ручная проверка"),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange.shade700,
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 48),
              ),
              onPressed: () {
                Navigator.pop(ctx);
                _showCreateManualTaskForm();
              },
            ),
            const SizedBox(height: 6),
            const Text(
              "Выполняете задание → ждёте одобрения рекламодателя → получаете награду",
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: Colors.white70,
                height: 1.3,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Отмена", style: TextStyle(color: Colors.white70)),
          ),
        ],
      );
    },
  );
}


/*
void _showCreateManualTaskForm() {
  final TextEditingController descController = TextEditingController();
  final TextEditingController rewardController = TextEditingController();
  final TextEditingController claimsController = TextEditingController();

  showDialog(
    context: context,
    builder: (BuildContext ctx) {
      return AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(15), 
          side: const BorderSide(color: Colors.blueAccent)
        ),
        title: const Text("Задание с ручной проверкой:", style: TextStyle(color: Colors.blueAccent)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: descController,
                maxLength: 500,
                maxLines: null,
                minLines: 3,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  labelText: "Что нужно сделать?",
                  hintText: "Например: Подпишись на X и пришли ссылку на профиль",
                  labelStyle: const TextStyle(color: Colors.white70),
                  filled: true,
                  fillColor: Colors.black26,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: rewardController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: "Награда (\$APT) за 1 выполнение ", 
                  labelStyle: TextStyle(color: Colors.white70)
                ),
              ),
              TextField(
                controller: claimsController,
                keyboardType: TextInputType.number,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: "Лимит (max 1000) выполнений ", 
                  labelStyle: TextStyle(color: Colors.white70)
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                "Комиссия за создание: 0.01 \$MEGA\nВы будете проверять отчеты вручную.",
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
              // ─── Общая сумма выплат ───────────────────────────────────────
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: rewardController,
                  builder: (context, rewardVal, _) {
                    return ValueListenableBuilder<TextEditingValue>(
                      valueListenable: claimsController,
                      builder: (context, claimsVal, _) {
                        final double? r = double.tryParse(rewardVal.text);
                        final int? c = int.tryParse(claimsVal.text);

                        final double total = (r ?? 0) * (c ?? 0);

                        return Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            "Общая сумма: ${total.toStringAsFixed(6)} \$APT",
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
                // ──────────────────────────────────────────────────────────────
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Отмена", style: TextStyle(color: Colors.redAccent))),
          ElevatedButton(
            onPressed: () {
              final String desc = descController.text.trim();
              final double? reward = double.tryParse(rewardController.text);
              final int? claims = int.tryParse(claimsController.text);

              if (desc.isEmpty || reward == null || reward <= 0.000001 || claims == null || claims <= 0 || claims > 1000) {
                showTopToast("Заполните поля корректно (макс. 1000 выполнений), награда не может быть меньше 0.000001 \$APT", isError: true);
                return;
              }

              // Для APT обычно 8 децималов (Octas)
              // Если у тебя константа decimals настроена на 8, оставляем так
              BigInt rewardRaw = BigInt.from((reward * pow(10, 8)).round()); 
              BigInt claimsRaw = BigInt.from(claims);

              Navigator.pop(ctx);
              _createManualTaskV3(desc, rewardRaw, claimsRaw);
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.blue.shade700),
            child: const Text("Создать"),
          ),
        ],
      );
    },
  );
}
*/
void _showCreateManualTaskForm() {
  final TextEditingController descController = TextEditingController();
  final TextEditingController rewardController = TextEditingController();
  final TextEditingController claimsController = TextEditingController();

  showDialog(
    context: context,
    builder: (BuildContext ctx) {
      return AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(15),
          side: const BorderSide(color: Colors.blueAccent),
        ),
        title: const Text("Задание с ручной проверкой", style: TextStyle(color: Colors.blueAccent)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: descController,
                maxLength: 500,
                maxLines: null,
                minLines: 3,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  labelText: "Что нужно сделать?",
                  hintText: "Например: Подпишись на X и пришли ссылку на профиль",
                  labelStyle: const TextStyle(color: Colors.white70),
                  filled: true,
                  fillColor: Colors.black26,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: rewardController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: "Награда (\$APT) за 1 выполнение",
                  labelStyle: TextStyle(color: Colors.white70),
                ),
              ),
              TextField(
                controller: claimsController,
                keyboardType: TextInputType.number,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: "Лимит (max 1000) выполнений",
                  labelStyle: TextStyle(color: Colors.white70),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                "Комиссия за создание: 0.01 \$MEGA ",
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: rewardController,
                builder: (context, rewardVal, _) {
                  return ValueListenableBuilder<TextEditingValue>(
                    valueListenable: claimsController,
                    builder: (context, claimsVal, _) {
                      final double? r = double.tryParse(rewardVal.text);
                      final int? c = int.tryParse(claimsVal.text);
                      final double total = (r ?? 0) * (c ?? 0);

                      return Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          "Общая сумма выплат: ${total.toStringAsFixed(6)} \$APT",
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Отмена", style: TextStyle(color: Colors.redAccent)),
          ),
          ElevatedButton(
            onPressed: () {
              final String desc = descController.text.trim();
              final double? reward = double.tryParse(rewardController.text);
              final int? claims = int.tryParse(claimsController.text);

              if (desc.isEmpty ||
                  reward == null ||
                  reward <= 0.000001 ||
                  claims == null ||
                  claims <= 0 ||
                  claims > 1000) {
                showTopToast(
                  "Заполните поля корректно (макс. 1000 выполнений), награда не может быть меньше 0.000001 \$APT",
                  isError: true,
                );
                return;
              }

              // ─── Показываем окно подтверждения ───────────────────────────────
              _showConfirmManualTaskDialog(
                context,
                desc: desc,
                reward: reward,
                claims: claims,
                onConfirm: () {
                  // Здесь уже настоящая отправка
                  BigInt rewardRaw = BigInt.from((reward * pow(10, 8)).round());
                  BigInt claimsRaw = BigInt.from(claims);

                  //Navigator.pop(ctx);           // закрываем первый диалог

                  // ЗАКРЫВАЕМ ОБА ОКНА:
                  // 1. Закрываем окно подтверждения (оно сейчас сверху)
                  Navigator.of(context, rootNavigator: true).pop(); 
                  // 2. Закрываем первое окно с формой (используем его контекст ctx)
                  Navigator.of(ctx).pop();


                  _createManualTaskV3(desc, rewardRaw, claimsRaw);
                },
                onEdit: () {
                  // Ничего не делаем — первый диалог остаётся открытым
                  Navigator.pop(context);       // закрываем только подтверждение
                },
              );
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.blue.shade700),
            child: const Text("Далее"),
          ),
        ],
      );
    },
  );
}

// ──────────────────────────────────────────────────────────────
// Новый метод — окно подтверждения
// ──────────────────────────────────────────────────────────────
void _showConfirmManualTaskDialog(
  BuildContext context, {
  required String desc,
  required double reward,
  required int claims,
  required VoidCallback onConfirm,
  required VoidCallback onEdit,
}) {
  final double total = reward * claims;

  showDialog(
    context: context,
    builder: (BuildContext confirmCtx) {
      return AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Colors.blueAccent, width: 1.5),
        ),
        title: const Text(
          "Подтвердите задание",
          style: TextStyle(color: Colors.blueAccent),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("Описание:", style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(desc, style: const TextStyle(color: Colors.white, fontSize: 15)),
              const SizedBox(height: 16),
              


              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text("Награда за выполнение:", style: TextStyle(color: Colors.white70)),
                trailing: Text(
                  "${reward.toStringAsFixed(6)} \$APT",
                  style: const TextStyle(color: Colors.white),
                ),
              ),

              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text("Количество выполнений:", style: TextStyle(color: Colors.white70)),
                trailing: Text("$claims", style: const TextStyle(color: Colors.white)),
              ),

              Divider(color: Colors.white24),

              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  "Общая сумма выплат:",
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                ),
                trailing: Text(
                  "${total.toStringAsFixed(6)} \$APT",
                  style: const TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold),
                ),
              ),   
              const SizedBox(height: 16),

              const Text(
                "Комиссия за создание: 0.01 \$MEGA",
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ),
        ),
        /*
        actions: [
          TextButton(
            onPressed: onEdit,
            child: const Text("Редактировать", style: TextStyle(color: Colors.orangeAccent)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(confirmCtx),
            child: const Text("Отмена", style: TextStyle(color: Colors.redAccent)),
          ),
          ElevatedButton(
            onPressed: onConfirm,
            style: ElevatedButton.styleFrom(backgroundColor: Colors.blue.shade700),
            child: const Text("Создать"),
          ),
        ],
         */ 
        actions: [
          TextButton(
            onPressed: onEdit, // Тут Navigator.pop уже есть внутри колбэка в первом методе
            child: const Text("Редактировать", style: TextStyle(color: Colors.orangeAccent)),
          ),
          TextButton(
            // Явное закрытие только этого окна при отмене
            onPressed: () => Navigator.of(confirmCtx).pop(), 
            child: const Text("Отмена", style: TextStyle(color: Colors.redAccent)),
          ),
          ElevatedButton(
            onPressed: onConfirm, // Вызывает наш исправленный блок выше
            style: ElevatedButton.styleFrom(backgroundColor: Colors.blue.shade700),
            child: const Text("Создать"),
          ),
        ],

      );
    },
  );
}


Future<void> _approveSelectedTasks() async {
  if (_selectedTaskIds.isEmpty) {
    showTopToast("Сначала выберите задачи для одобрения");
    return;
  }

  setState(() => _isLoadingTasks = true);
  //debugPrint("🚀 Начинаю одобрение задач: $_selectedTaskIds");

  try {
    const String moduleAddress = "0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3";
    
    // Копируем список, чтобы избежать проблем при очистке в процессе
    final List<int> tasksToApprove = List.from(_selectedTaskIds);

    for (int taskId in tasksToApprove) {
      final payload = {
        "type": "entry_function_payload",
        "function": "$moduleAddress::mega_tasks::approve_task",
        "type_arguments": [],
        "arguments": [taskId.toString()], // Контракт ждет u64 в виде строки
      };

      //debugPrint("📡 Подготовка транзакции для задачи #$taskId");

      // Вызываем наш универсальный метод (он сам почистит ключи и откроет Petra)
      await _sendAptosTransaction(payload);
      
      //debugPrint("✅ Сигнал для задачи #$taskId отправлен в кошелек");

      // Если задач несколько, делаем небольшую паузу после возвращения из Petra,
      // чтобы пользователь успел понять, что происходит перед следующим открытием
      if (tasksToApprove.length > 1 && taskId != tasksToApprove.last) {
        await Future.delayed(const Duration(seconds: 1));
      }
    }

    // После того как все транзакции были отправлены в Petra
    _selectedTaskIds.clear();
    
    // Даем немного времени блокчейну обработать транзакции перед обновлением списка
    await Future.delayed(const Duration(seconds: 2));
    await _fetchMegaTasks();
    
    showTopToast("Запросы на одобрение отправлены!");

  } catch (e, stack) {
    //debugPrint("🆘 Ошибка при одобрении: $e");
    //debugPrint("Stack: $stack");
    showTopToast("❌ Ошибка: $e", isError: true);
  } finally {
    if (mounted) {
      setState(() => _isLoadingTasks = false);
    }
  }
}


Future<void> _adminBatchApproveTasks(List<int> ids) async {
  if (ids.isEmpty) {
    showTopToast("Ничего не выбрано", isError: true);
    return;
  }

  if (!isPetraConnected) {
    showTopToast("❌ Подключите кошелёк Petra заново", isError: true);
    return;
  }

  setState(() => _isLoadingTasks = true);

  try {
    const String moduleAddress = "0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3";

    //debugPrint("🚀 Выбрано ID для одобрения: $ids");
    //debugPrint("Всего задач в списке: ${_megaTasks.length}");

    List<String> v2Ids = [];
    List<String> v3Ids = [];

    // Распределяем ID по версиям задач
    for (int id in ids) {
      final task = _megaTasks.firstWhere(
        (t) {
          if (t is TaskV3) {
            return t.id == id;
          } else if (t is Map) {
            final taskId = int.tryParse(t['id']?.toString() ?? '0') ?? -1;
            return taskId == id;
          }
          return false;
        },
        orElse: () => null,
      );

      if (task is TaskV3) {
        v3Ids.add(id.toString()); // Контракту нужны строки для u64
      } else if (task != null) {
        v2Ids.add(id.toString());
      }
    }

    //debugPrint("📊 Распределение: V2 = ${v2Ids.length}, V3 = ${v3Ids.length}");

    // 1. Одобряем V2 (если есть)
    if (v2Ids.isNotEmpty) {
      final payloadV2 = {
        "type": "entry_function_payload",
        "function": "$moduleAddress::mega_tasks::admin_batch_approve_tasks",
        "type_arguments": [],
        "arguments": [v2Ids], // Передаем список строк
      };
      await _sendAptosTransaction(payloadV2);
      //debugPrint("✅ Транзакция одобрения V2 отправлена");
      
      // Пауза перед следующей транзакцией, если есть V3
      if (v3Ids.isNotEmpty) {
        await Future.delayed(const Duration(seconds: 2));
      }
    }

    // 2. Одобряем V3 (если есть)
    if (v3Ids.isNotEmpty) {
      final payloadV3 = {
        "type": "entry_function_payload",
        "function": "$moduleAddress::mega_tasks::admin_mass_approve_v3",
        "type_arguments": [],
        "arguments": [v3Ids],
      };
      await _sendAptosTransaction(payloadV3);
      //debugPrint("✅ Транзакция одобрения V3 отправлена");
    }

    // Очищаем выбор
    _selectedTaskIds.clear();

    // Локально обновляем статусы в списке для мгновенного отклика UI
    for (int id in ids) {
      for (var task in _megaTasks) {
        if (task is TaskV3 && task.id == id) {
          task.status = 1;
          break;
        } else if (task is Map && int.tryParse(task['id']?.toString() ?? '0') == id) {
          task['status'] = 1;
          break;
        }
      }
    }

    // Принудительно обновляем состояние диалога, если он открыт
    _setDialogState?.call(() {});

    final approvedCount = v2Ids.length + v3Ids.length;
    if (approvedCount > 0) {
      showTopToast("✅ Запросы отправлены! (V2: ${v2Ids.length}, V3: ${v3Ids.length})");
      
      // Даем время чейну обновиться и запрашиваем свежие данные
      await Future.delayed(const Duration(seconds: 2));
      await _fetchMegaTasks();
    } else {
      showTopToast("Не удалось найти выбранные задачи в списке", isError: true);
    }

  } catch (e, stack) {
    //debugPrint("🆘 Batch approve error: $e");
    //debugPrint("Stack: $stack");
    
    if (e.toString().contains("key") || e.toString().contains("petra")) {
      showTopToast(
        "❌ Ошибка ключей Petra.\nУдалите приложение в Petra (Connected apps) и подключитесь заново.",
        isError: true,
      );
    } else {
      showTopToast("❌ Ошибка одобрения: $e", isError: true);
    }
  } finally {
    if (mounted) {
      setState(() => _isLoadingTasks = false);
    }
    _setDialogState?.call(() {});
    // Повторное обновление через долю секунды для корректной прорисовки
    Future.delayed(const Duration(milliseconds: 400), () {
      _setDialogState?.call(() {});
    });
  }
}

///// история заданий /////////

Future<List<LogEntry>> _fetchUserHistory() async {
  if (currentWalletAddress == null || currentWalletAddress!.isEmpty) return [];

  final String contractAddress = "0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3"; // Твой адрес контракта
  final url = Uri.parse("https://fullnode.mainnet.aptoslabs.com/v1/view");

  try {
    final response = await http.post(
      url,
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({
        "function": "$contractAddress::mega_tasks::get_user_history",
        "type_arguments": [],
        "arguments": [currentWalletAddress]
      }),
    );

    if (response.statusCode == 200) {
      final List<dynamic> data = jsonDecode(response.body);
      // Ответ приходит как список внутри списка [[{...}, {...}]]
      if (data.isNotEmpty && data[0] is List) {
        return (data[0] as List).map((e) => LogEntry.fromJson(e)).toList().reversed.toList(); // Разворачиваем, чтобы новые были сверху
      }
    }
  } catch (e) {
    //debugPrint("Ошибка при получении истории: $e");
  }
  return [];
}

void _showHistorySheet() {
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.grey[900],
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (context) {
      return FutureBuilder<List<LogEntry>>(
        future: _fetchUserHistory(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator(color: Colors.greenAccent));
          }
          if (!snapshot.hasData || snapshot.data!.isEmpty) {
            return const Center(child: Text("История пуста", style: TextStyle(color: Colors.white70)));
          }

          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Text("ИСТОРИЯ ОПЕРАЦИЙ НА БИРЖЕ", style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold)),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: snapshot.data!.length,
                  itemBuilder: (context, index) {
                    final item = snapshot.data![index];
                    final date = DateTime.fromMillisecondsSinceEpoch(item.timestamp * 1000);
                    return ListTile(
                      leading: Icon(
                        item.actionType == 2 ? Icons.check_circle : Icons.info_outline,
                        color: item.actionType == 2 ? Colors.green : Colors.blueAccent,
                      ),
                      title: Text(item.actionName, style: const TextStyle(color: Colors.white, fontSize: 14)),
                      subtitle: Text("${item.note}\nID задачи: ${item.taskId} | ${date.day}.${date.month} ${date.hour}:${date.minute}", 
                        style: const TextStyle(color: Colors.white54, fontSize: 12)),
                      trailing: item.amount != "0" 
                        ? Text("${(int.parse(item.amount) / 100000000).toStringAsFixed(6)} APT", 
                            style: const TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold))
                        : null,
                    );
                  },
                ),
              ),
            ],
          );
        },
      );
    },
  );
}


// Функция для сокращения адреса кошелька (например, 0x1234...abcd)
String _shortenAddress(String address) {
  if (address.length < 10) return address;
  return "${address.substring(0, 6)}...${address.substring(address.length - 4)}";
}

Widget _buildStatusBadge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: const TextStyle(fontSize: 8, color: Colors.white, fontWeight: FontWeight.bold),
      ),
    );
  }


void _showPetraRequiredDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1A1A1A),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(15),
            side: const BorderSide(color: Colors.orangeAccent, width: 1.5),
          ),
          title: const Center(
            child: Text("⚠️ Требуется Petra", style: TextStyle(color: Colors.orangeAccent, fontWeight: FontWeight.bold)),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                "Для выполнения операций необходимо подключить кошелек Petra.",
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontSize: 14),
              ),
              const SizedBox(height: 15),
              const Text(
                "Если у вас он не установлен, вы можете скачать его по ссылке:",
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
              const SizedBox(height: 10),
              GestureDetector(
                onTap: () => launchUrl(Uri.parse("https://play.google.com/store/apps/details?id=com.aptoslabs.petra.wallet&hl=ru"), mode: LaunchMode.externalApplication),
                child: const Text(
                  "Скачать Petra Wallet",
                  style: TextStyle(color: Colors.blueAccent, decoration: TextDecoration.underline, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          actions: [
            // Кнопка "Понятно" (остаётся слева)
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Понятно", style: TextStyle(color: Colors.white60)),
            ),

            ElevatedButton.icon(
              icon: const Icon(
                Icons.account_balance_wallet,
                size: 18,
                color: Colors.blueAccent,
              ),
              label: const Text(
                "Подключить Petra",
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blueAccent.withOpacity(0.1),
                foregroundColor: Colors.blueAccent,
                side: const BorderSide(color: Colors.blueAccent, width: 1.5),
                elevation: 0,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onPressed: () {
                Navigator.pop(context);
                _connectPetra(); // сразу запускаем подключение
              },
            ),
          ],
        );
      },
    );
  }

// Вспомогательная функция для форматирования даты 
String _formatExpiryDate(dynamic expiresAt) {
  if (expiresAt == null) return "Неизвестно";
  try {
    final int seconds = int.parse(expiresAt.toString());
    final DateTime date = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    return "${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}";
  } catch (e) {
    return "---";
  }
}

// Функция для определения цвета кнопки
Color _getButtonColor(int status, bool isEnabled) {
  if (status == 0 || status == 2) return Colors.grey.shade900; // На проверке или Готово
  if (status == 3) return Colors.red.shade900; // Отклонено - выделяем красным
  return isEnabled ? Colors.purple.shade600 : Colors.grey.shade800;
}

// Функция для отрисовки содержимого (Текст, Таймер или Иконка)
Widget _buildButtonChild(int status, DateTime? clickTime, bool isWaitFinished, int secondsLeft, bool isEnabled) {
  // 1. Если на проверке (0) или выполнено (2) — показываем птичку
  if (status == 0 || status == 2) {
    return Icon(
      Icons.check,
      size: 18,
      color: status == 2 ? Colors.greenAccent : Colors.white70,
    );
  }

  // 2. Если отклонено (3) — показываем крестик или текст "ПОВТОР"
  if (status == 3) {
    return const Text(
      "ПОВТОР", 
      style: TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.bold)
    );
  }

  // 3. Стандартная логика: Таймер или надпись ОТВЕТ
  if (clickTime != null && !isWaitFinished) {
    return Text("$secondsLeftс", style: const TextStyle(fontSize: 11, color: Colors.white));
  }
  
  return Text(
    "ОТВЕТ",
    style: TextStyle(
      fontSize: 11,
      color: isEnabled ? Colors.white : Colors.white54,
      fontWeight: FontWeight.bold,
    ),
  );
}

void _showEarnDialog() {
  showDialog(
    context: context,
    builder: (BuildContext dialogContext) {
      return StatefulBuilder(
        builder: (context, setStateDialog) {
          _setDialogState = setStateDialog; // для обновления чекбоксов и таймера

          // ====================== СТАТИСТИКА (универсальная V2 + V3) ======================
          double totalAptPool = 0;
          int activeTasksCount = 0;

          for (var task in _megaTasks) {
            int remains = 0;
            double reward = 0;

            if (task is TaskV3) {
              remains = task.remainingClaims;
              reward = task.rewardApt;
            } else {
              remains = int.tryParse(task['remaining_claims']?.toString() ?? "0") ?? 0;
              reward = (double.tryParse(task['reward_per_claim_apt']?.toString() ??
                          task['reward_per_claim']?.toString() ?? '0') ??
                      0) /
                  100000000;
            }

            if (remains > 0) {
              activeTasksCount++;
              totalAptPool += reward * remains;
            }
          }

          bool hasActiveMegaTask = false;

          final bool isAdmin = currentWalletAddress.toLowerCase() == 
              "0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3".toLowerCase();

          if (!isAdmin) {
            hasActiveMegaTask = _megaTasks.any((task) {
              String creatorAddr = (task is TaskV3) ? task.creator : (task['creator']?.toString() ?? "");
              int remains = (task is TaskV3) ? task.remainingClaims : (int.tryParse(task['remaining_claims']?.toString() ?? "0") ?? 0);
              return creatorAddr.toLowerCase() == currentWalletAddress.toLowerCase() && remains > 0;
            });
          }

          // ====================== ДИАЛОГ ======================
          final screenSize = MediaQuery.of(context).size;
          final dialogHeight = screenSize.height * 0.9;

          return AlertDialog(
            backgroundColor: const Color(0xFF1A1A1A),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            insetPadding: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(15),
              side: const BorderSide(color: Colors.greenAccent, width: 1.5),
            ),

            title: Column(
              children: [

                /*
                const Text(
                  "💰 Заработать \$APT",
                  style: TextStyle(color: Colors.greenAccent, fontSize: 18, fontWeight: FontWeight.bold),
                ),*/

                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text(
                      "💰 Заработать \$APT",
                      style: TextStyle(
                          color: Colors.greenAccent,
                          fontSize: 18,
                          fontWeight: FontWeight.bold
                      ),
                    ),
                    const SizedBox(width: 10),
                    Image.asset(
                      'assets/apt.png',
                      width: 24,
                      height: 24,
                    ),
                    const SizedBox(width: 8), 
                    const Text(
                      "beta",
                      style: TextStyle(
                        color: Colors.white54,    
                        fontSize: 12,             
                        fontStyle: FontStyle.italic, 
                        fontWeight: FontWeight.w300,
                      ),
                    ),
                  ],
                ),
                  

                const SizedBox(height: 5),
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 0, horizontal: 8),  
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.05),
                    borderRadius: BorderRadius.circular(8),
                  ),

                  /*
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      Text("ЗАДАНИЙ: $activeTasksCount", style: const TextStyle(color: Colors.white70, fontSize: 10)),
                      const Text("|", style: TextStyle(color: Colors.white10, height: 1.0)),
                      Text(
                        "ПУЛ: ${totalAptPool.toStringAsFixed(4)} APT",
                        style: const TextStyle(color: Colors.greenAccent, fontSize: 10, fontWeight: FontWeight.bold, height: 1.0),
                      ),
                      IconButton(
                        padding: EdgeInsets.zero,  
                        icon: const Icon(Icons.history, color: Colors.greenAccent, size: 18),  
                        onPressed: _showHistorySheet,
                        tooltip: "История",
                      ),
                    ],
                  ),*/
                   child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      Text("ЗАДАНИЙ: $activeTasksCount", style: const TextStyle(color: Colors.white70, fontSize: 10, height: 1.0)),
                      const Text("|", style: TextStyle(color: Colors.white10, height: 1.0)),
                      Text(
                        "ПУЛ: ${totalAptPool.toStringAsFixed(4)} APT",
                        style: const TextStyle(color: Colors.greenAccent, fontSize: 10, fontWeight: FontWeight.bold, height: 1.0),
                      ),
                      IconButton(
                        padding: EdgeInsets.zero,  
                        icon: const Icon(Icons.history, color: Colors.greenAccent, size: 18),  
                        onPressed: _showHistorySheet,
                        tooltip: "История",
                      ),
                    ],
                  ),


                ),
                  
               
                
                // Вставляем сюда:
                if (_totalPendingV3 > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 8), // Отступ сверху от контейнера статистики
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.orangeAccent.withOpacity(0.1),
                        side: const BorderSide(color: Colors.orangeAccent, width: 1),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        minimumSize: const Size(double.infinity, 40), // Растягиваем на всю ширину
                      ),
                      onPressed: () => _showReviewListDialog(),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.rate_review, color: Colors.orangeAccent, size: 18),
                          const SizedBox(width: 8),
                          Text(
                            "ОТВЕТЫ НА ПРОВЕРКУ: $_totalPendingV3", 
                            style: const TextStyle(color: Colors.orangeAccent, fontWeight: FontWeight.bold, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),

            

            content: SizedBox(
              width: double.maxFinite,
              height: dialogHeight,
              child: Column(
                children: [
                  Expanded(
                    child: _isLoadingTasks
                        ? const Center(child: CircularProgressIndicator(color: Colors.greenAccent))
                        : _megaTasks.isEmpty
                            ? const Center(child: Text("Заданий нет", style: TextStyle(color: Colors.white54)))
                            : ListView.builder(
                                itemCount: _megaTasks.length,
                                itemBuilder: (context, index) {
                                  final task = _megaTasks[index];

                                  // ==================== УНИВЕРСАЛЬНЫЙ ПАРСИНГ V2 / V3 ====================
                                  final bool isV3 = task is TaskV3;

                                  final String taskId = isV3 ? task.id.toString() : (task['id']?.toString() ?? '0');
                                  final int remains = isV3 ? task.remainingClaims : (int.tryParse(task['remaining_claims']?.toString() ?? '0') ?? 0);
                                  final String creator = isV3 ? task.creator : (task['creator']?.toString() ?? "");
                                  final double reward = isV3
                                      ? task.rewardApt
                                      : ((int.tryParse(task['reward_per_claim_apt']?.toString() ??
                                                      task['reward_per_claim']?.toString() ??
                                                      '0') ??
                                                  0) /
                                              100000000.0);
                                  final int expiresAt = isV3 ? task.expiresAt : (int.tryParse(task['expires_at']?.toString() ?? '0') ?? 0);
                                  final int status = isV3 ? task.status : (task['status'] ?? 0);

                                  // print("UI render task #${taskId} → computed status = $status (isV3=$isV3)");

                                  final String description = isV3
                                      ? task.description
                                      : (task['description']?.toString() ?? '');

                                  final List<dynamic> claimedBy = !isV3 && task['claimed_by'] is List
                                      ? task['claimed_by']
                                      : [];

                                  // ==================== ЛОГИКА ====================
                                  final String expiryStr = expiresAt > 0
                                      ? DateTime.fromMillisecondsSinceEpoch(expiresAt * 1000)
                                          .toLocal()
                                          .toString()
                                          .substring(0, 16)
                                      : "Не ограничено";

                                  final bool isMyTask = creator.toLowerCase() == currentWalletAddress.toLowerCase();
                                  final bool isAlreadyClaimed = claimedBy.any((addr) =>
                                      addr.toString().toLowerCase() == currentWalletAddress.toLowerCase());
                                  final bool isFinished = isAlreadyClaimed || status == 2;

                                  // Таймер 30 секунд
                                  final DateTime? clickTime = _taskClickTimes[taskId];
                                  final int elapsedSeconds = clickTime != null
                                      ? DateTime.now().difference(clickTime).inSeconds
                                      : 0;
                                  final int secondsLeft = (30 - elapsedSeconds).clamp(0, 30);
                                  final bool isWaitFinished = clickTime != null && elapsedSeconds >= 30;
                                  final bool isButtonEnabled = !isFinished && isWaitFinished;

                                  // Админ
                                  final bool isAdmin = (_petraAddress ?? "").toLowerCase().trim() ==
                                      "0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3".toLowerCase().trim();

                                  final int taskIdInt = int.parse(taskId);
                                  final int? myV3Status = _myV3Statuses[taskIdInt]; // Берем статус из карты, которую мы наполнили    

                                  // 1. Сначала рассчитайте общий статус завершения (с учетом V3)
                                  final bool isTaskDone = isFinished || (isV3 && myV3Status == 1);

                                  return Card(
                                    margin: const EdgeInsets.only(bottom: 8),
                                    color: isMyTask
                                        ? Colors.blueAccent.withOpacity(0.1)
                                        : (isFinished ? Colors.white.withOpacity(0.02) : Colors.white10),
                                    child: Padding(
                                      padding: const EdgeInsets.all(10),
                                      child: Row(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [

                                              
 
                                               Row(
                                                children: [
                                                  if (isAdmin)
                                                    Checkbox(
                                                      value: _selectedTaskIds.contains(taskIdInt),
                                                      onChanged: (checked) {
                                                        setStateDialog(() {
                                                          if (checked == true) {
                                                            _selectedTaskIds.add(taskIdInt);
                                                          } else {
                                                            _selectedTaskIds.remove(taskIdInt);
                                                          }
                                                        });
                                                      },
                                                    ),
                                                  Text("#$taskId",
                                                      style: const TextStyle(
                                                          color: Colors.orangeAccent,
                                                          fontSize: 11,
                                                          fontWeight: FontWeight.bold)),
                                                  const SizedBox(width: 8),
                                                  _buildStatusBadge(
                                                    // --- ЛОГИКА ТЕКСТА ---
                                                    status == 5 
                                                        ? "ОТКЛОНЕНО" 
                                                        : (status == 2 || isAlreadyClaimed) 
                                                            ? "ВЫПОЛНЕНО" 
                                                            // НОВАЯ ЛОГИКА ДЛЯ ИСПОЛНИТЕЛЯ V3
                                                            : (isV3 && myV3Status != null)
                                                                ? (myV3Status == 0 ? "ПРОВЕРЯЕТСЯ" : 
                                                                  myV3Status == 1 ? "ВЫПОЛНЕНО" : "ОТКЛОНЕНО")
                                                                // ОСТАЛЬНАЯ ТВОЯ ЛОГИКА
                                                                : isV3 
                                                                    ? (status == 1 
                                                                        ? (isMyTask ? "ВАШЕ (АКТИВНО)" : "АКТИВНО") 
                                                                        : (isAdmin ? "НУЖНО ПРОВЕРИТЬ" : "НА МОДЕРАЦИИ"))
                                                                    : (status == 1 
                                                                        ? (isMyTask ? "ВАШЕ (ОДОБРЕНО)" : "НОВОЕ") 
                                                                        : (status == 0 
                                                                            ? (isAdmin ? "НУЖНО ПРОВЕРИТЬ" : "НА МОДЕРАЦИИ") 
                                                                            : "АКТИВНО")),
                                                    
                                                    // --- ЛОГИКА ЦВЕТА ---
                                                    status == 5 
                                                        ? Colors.redAccent 
                                                        : (status == 2 || isAlreadyClaimed) 
                                                            ? Colors.green.withOpacity(0.8) 
                                                            // ЦВЕТ ДЛЯ ИСПОЛНИТЕЛЯ V3
                                                            : (isV3 && myV3Status != null)
                                                                ? (myV3Status == 0 ? Colors.orangeAccent : 
                                                                  myV3Status == 1 ? Colors.green.shade800 : Colors.redAccent)
                                                                // ОСТАЛЬНАЯ ТВОЯ ЛОГИКА
                                                                : isV3 
                                                                    ? (status == 1 ? Colors.green.shade600 : Colors.orange)
                                                                    : (status == 1 ? Colors.orange.withOpacity(0.8) : Colors.blueAccent),
                                                  ),
                                                ],
                                              ),

                                                const SizedBox(height: 6),

                                                // 2. Передайте isTaskDone в функцию
                                                _buildRichDescription(
                                                  description,
                                                  isTaskDone, // Теперь функция знает, что V3 тоже "завершено"
                                                  taskId,
                                                  setStateDialog,
                                                ),


                                                const SizedBox(height: 8),
                                                Text("💎 Награда: ${reward.toStringAsFixed(6)} APT",
                                                    style: const TextStyle(color: Colors.greenAccent, fontSize: 10)),
                                                Text("👥 Осталось мест: $remains",
                                                    style: const TextStyle(color: Colors.white70, fontSize: 10)),
                                                Text("👤 От: ${_shortenAddress(creator)}",
                                                    style: const TextStyle(color: Colors.white70, fontSize: 9)),
                                                Text("🕒 До: $expiryStr",
                                                    style: TextStyle(color: Colors.white70, fontSize: 9)),

                                                // Кнопка удаления для автора
                                                /////////////
                                            if (isMyTask && !isFinished) ...[
                                              const SizedBox(height: 12),
                                              InkWell(
                                                onTap: () {
                                                  // Подтверждение удаления
                                                  showDialog(
                                                    context: context,
                                                    builder: (ctx) => AlertDialog(
                                                      backgroundColor: Colors.transparent,
                                                      contentPadding: EdgeInsets.zero,
                                                      content: Container(
                                                        width: 280, // Ограничим ширину, чтобы окно выглядело аккуратнее
                                                        decoration: BoxDecoration(
                                                          color: const Color(0xFF121212),
                                                          borderRadius: BorderRadius.circular(12),
                                                          border: Border.all(color: Colors.blueAccent.withOpacity(0.4), width: 1),
                                                          boxShadow: [
                                                            BoxShadow(
                                                              color: Colors.blueAccent.withOpacity(0.1),
                                                              blurRadius: 10,
                                                            )
                                                          ],
                                                        ),
                                                        child: Column(
                                                          mainAxisSize: MainAxisSize.min,
                                                          children: [
                                                            // Шапка
                                                            Container(
                                                              padding: const EdgeInsets.symmetric(vertical: 10),
                                                              decoration: BoxDecoration(
                                                                color: Colors.blueAccent.withOpacity(0.05),
                                                                borderRadius: const BorderRadius.only(
                                                                  topLeft: Radius.circular(12),
                                                                  topRight: Radius.circular(12),
                                                                ),
                                                              ),
                                                              child: const Row(
                                                                mainAxisAlignment: MainAxisAlignment.center,
                                                                children: [
                                                                  Icon(Icons.delete_sweep_outlined, color: Colors.redAccent, size: 18),
                                                                  SizedBox(width: 8),
                                                                  Text(
                                                                    "УДАЛЕНИЕ",
                                                                    style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.1),
                                                                  ),
                                                                ],
                                                              ),
                                                            ),
                                                            
                                                            // Контент
                                                            Padding(
                                                              padding: const EdgeInsets.all(16),
                                                              child: Column(
                                                                children: [
                                                                  const Text(
                                                                    "Удалить это задание?",
                                                                    style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                                                                  ),
                                                                  const SizedBox(height: 8),
                                                                  const Text(
                                                                    "Остаток награды вернется вам.",
                                                                    textAlign: TextAlign.center,
                                                                    style: TextStyle(color: Colors.white70, fontSize: 12),
                                                                  ),
                                                                  const SizedBox(height: 12),
                                                                  // Блок с комиссией
                                                                  Container(
                                                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                                                    decoration: BoxDecoration(
                                                                      color: Colors.orangeAccent.withOpacity(0.1),
                                                                      borderRadius: BorderRadius.circular(4),
                                                                    ),
                                                                   
                                                                  ),
                                                                ],
                                                              ),
                                                            ),

                                                            // Кнопки действий (сделали меньше)
                                                            Padding(
                                                              padding: const EdgeInsets.only(bottom: 12, left: 16, right: 16),
                                                              child: Row(
                                                                children: [
                                                                  Expanded(
                                                                    child: SizedBox(
                                                                      height: 32, // Уменьшенная высота
                                                                      child: OutlinedButton(
                                                                        onPressed: () => Navigator.pop(ctx),
                                                                        style: OutlinedButton.styleFrom(
                                                                          side: BorderSide(color: Colors.white24), // Теперь видно границы
                                                                          foregroundColor: Colors.white, // Белый текст
                                                                          padding: EdgeInsets.zero,
                                                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                                                                        ),
                                                                        child: const Text("ОТМЕНА", style: TextStyle(fontSize: 10)),
                                                                      ),
                                                                    ),
                                                                  ),
                                                                  const SizedBox(width: 12),
                                                                  Expanded(
                                                                    child: SizedBox(
                                                                      height: 32, // Уменьшенная высота
                                                                      child: ElevatedButton(
                                                                        onPressed: () {
                                                                          Navigator.pop(ctx);
                                                                     //   _deleteTaskV2(taskId);
                                                                           Navigator.pop(ctx);
                                                                          if (isV3) {
                                                                            _deleteTaskV3(taskId);
                                                                          } else {
                                                                            _deleteTaskV2(taskId);
                                                                          }

                                                                        },
                                                                        style: ElevatedButton.styleFrom(
                                                                          backgroundColor: Colors.redAccent.shade700,
                                                                          foregroundColor: Colors.white,
                                                                          padding: EdgeInsets.zero,
                                                                          elevation: 0,
                                                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                                                                        ),
                                                                        child: const Text("УДАЛИТЬ", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                                                                      ),
                                                                    ),
                                                                  ),
                                                                ],
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                      ),
                                                    ),
                                                  );
                                                  ///////
                                                },
                                                child: Container(
                                                  padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
                                                  decoration: BoxDecoration(
                                                    border: Border.all(color: Colors.redAccent.withOpacity(0.5)),
                                                    borderRadius: BorderRadius.circular(5),
                                                  ),
                                                  child: const Row(
                                                    mainAxisSize: MainAxisSize.min,
                                                    children: [
                                                      Icon(Icons.delete_outline, color: Colors.redAccent, size: 14),
                                                      SizedBox(width: 5),
                                                      Text("УДАЛИТЬ ЗАДАНИЕ", 
                                                        style: TextStyle(color: Colors.redAccent, fontSize: 9, fontWeight: FontWeight.bold)),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                            ],
                                              ],
                                            ),
                                          ),

                                         

                                       
                                          if (!isFinished) ...[
                                        if (isV3) ...[
                                            Builder(
                                              builder: (context) {
                                                // Оставляем логи, чтобы видеть изменения в реальном времени
                                               // debugPrint("DEBUG V3: Task=$taskId, Status=$myV3Status, Enabled=$isButtonEnabled");

                                                // ТЕПЕРЬ ВКЛЮЧАЕМ СТАТУС 1 (Выполнено) в проверку
                                                bool isDoneOrPending = (myV3Status == 0 || myV3Status == 1 || myV3Status == 2);
                                                
                                                // Кнопка кликабельна только если статус не 0, 1 или 2
                                                bool canClick = isButtonEnabled && !isDoneOrPending;

                                                return ElevatedButton(
                                                  onPressed: canClick
                                                      ? () {
                                                          _taskClickTimes[taskId] = DateTime.now();
                                                          setStateDialog(() {});
                                                          _showV3SubmitDialog(taskId);
                                                        }
                                                      : null,
                                                  style: ElevatedButton.styleFrom(
                                                    backgroundColor: (myV3Status == 1 || myV3Status == 2)
                                                        ? Colors.green.shade900 // Темно-зеленый для выполненных
                                                        : (myV3Status == 0 
                                                            ? Colors.grey.shade900 // Серый для проверки
                                                            : (myV3Status == 3 ? Colors.red.shade900 : (isButtonEnabled ? Colors.purple.shade600 : Colors.grey.shade800))),
                                                    disabledBackgroundColor: isDoneOrPending ? Colors.black87 : Colors.grey.shade900,
                                                    minimumSize: const Size(70, 32),
                                                    padding: const EdgeInsets.symmetric(horizontal: 12),
                                                  ),
                                                  child: isDoneOrPending
                                                      ? Icon(
                                                          Icons.check,
                                                          size: 18,
                                                          // Если статус 1 или 2 (Выполнено) - зеленая птичка, если 0 - белая
                                                          color: (myV3Status == 1 || myV3Status == 2) ? Colors.greenAccent : Colors.white60,
                                                        )
                                                      : Text(
                                                          (myV3Status == 3) ? "ПОВТОР" : ((clickTime != null && !isWaitFinished) ? "${secondsLeft}с" : "ОТВЕТ"),
                                                          style: TextStyle(
                                                            fontSize: 11,
                                                            color: canClick ? Colors.white : Colors.white54,
                                                            fontWeight: FontWeight.bold,
                                                          ),
                                                        ),
                                                );
                                              },
                                            ),
                                          ] else ...[



                                          /*
                                          ElevatedButton(
                                            onPressed: isButtonEnabled
                                                ? () {
                                                    _taskClickTimes[taskId] = DateTime.now();
                                                    setStateDialog(() {});
                                                    _showV3SubmitDialog(taskId);
                                                  }
                                                : null,
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: isButtonEnabled 
                                                  ? Colors.purple.shade600 
                                                  : Colors.grey.shade800,
                                              disabledBackgroundColor: Colors.grey.shade800,
                                              minimumSize: const Size(70, 32),
                                              padding: const EdgeInsets.symmetric(horizontal: 12),
                                            ),
                                            child: Text(
                                              (clickTime != null && !isWaitFinished) 
                                                  ? "${secondsLeft}с" 
                                                  : "ОТВЕТ",
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: isButtonEnabled ? Colors.white : Colors.white54,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ),
                                        
                                        ] else ...[

                                         */ 
                                          // Кнопка "КОД" для V2 (остаётся прежней)
                                          ElevatedButton(
                                            onPressed: isButtonEnabled
                                                ? () {
                                                    _taskClickTimes[taskId] = DateTime.now();
                                                    setStateDialog(() {});
                                                    _showClaimDialog(taskId);
                                                  }
                                                : null,
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: isButtonEnabled
                                                  ? Colors.greenAccent.shade700
                                                  : Colors.grey.shade800,
                                              disabledBackgroundColor: Colors.grey.shade800,
                                              minimumSize: const Size(50, 30),
                                            ),
                                            child: Text(
                                              (clickTime != null && !isWaitFinished) 
                                                  ? "${secondsLeft}с" 
                                                  : "КОД",
                                              style: TextStyle(
                                                fontSize: 10,
                                                color: isButtonEnabled ? Colors.black : Colors.white24,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ),
                                        ]
                                      ] else ...[
                                        const Icon(
                                          Icons.check_circle_outline,
                                          color: Colors.white10,
                                          size: 24,
                                        ),
                                      ],
                                    
                                       ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                  ),
                  const SizedBox(height: 2),
                   
                  /* 
                  // Кнопка "Создать задание"
                  if (isPetraConnected)
                    ElevatedButton(
                      onPressed: hasActiveMegaTask ? null : _showTaskCreationChoiceDialog,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: hasActiveMegaTask ? Colors.grey : Colors.orangeAccent,
                        foregroundColor: Colors.black,
                        minimumSize: const Size(double.infinity, 40),
                      ),
                      child: Text(
                        hasActiveMegaTask ? "ЛИМИТ ЗАДАНИЙ 1/1" : "СОЗДАТЬ ЗАДАНИЕ",
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              // Админ-панель (твой блок полностью сохранён)
              if ((_petraAddress ?? "").toLowerCase() ==
                      "0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3".toLowerCase() &&
                  _selectedTaskIds.isNotEmpty)
               
                
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        TextButton(
                          onPressed: () => _adminBatchApproveTasks(_selectedTaskIds),
                          child: Text("ОДОБРИТЬ (${_selectedTaskIds.length})",
                              style: const TextStyle(color: Colors.greenAccent, fontSize: 12)),
                        ),
                        TextButton(
                          onPressed: () {
                            // твоя логика отклонения
                          },
                          child: Text("ОТКЛОНИТЬ (${_selectedTaskIds.length})",
                              style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
                        ),
                      ],
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        TextButton(
                          onPressed: _adminBatchDeleteTasks,
                          child: Text("УДАЛИТЬ (${_selectedTaskIds.length})",
                              style: const TextStyle(color: Colors.orangeAccent, fontSize: 12)),
                        ),
                        TextButton(
                          onPressed: () {
                            _setDialogState = null;
                            Navigator.pop(dialogContext);
                          },
                          child: const Text("ЗАКРЫТЬ", style: TextStyle(color: Colors.white54, fontSize: 12)),
                        ),
                      ],
                    ),
                  ],
                )
              else
                /*
                TextButton(
                  onPressed: () {
                    _setDialogState = null;
                    Navigator.pop(dialogContext);
                  },
                  child: const Text("ЗАКРЫТЬ", style: TextStyle(color: Colors.white54, fontSize: 12)),
                ),*/
                // Кнопка ЗАКРЫТЬ (твоя, немного поправил стиль для порядка)
                TextButton(
                  onPressed: () {
                    _setDialogState = null;
                    Navigator.pop(dialogContext);
                  },
                  child: const Text("ЗАКРЫТЬ", style: TextStyle(color: Colors.white54, fontSize: 12)),
                ),

                // Новая кнопка ОБНОВИТЬ
                TextButton(
                  onPressed: () async {
                    showTopToast("🔄 Обновление списка заданий...");
                    await _fetchMegaTasks();
                    if (_setDialogState != null) {
                      _setDialogState!(() {}); 
                    }
                  },
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.refresh_rounded, color: Colors.greenAccent, size: 14),
                      const SizedBox(width: 4),
                      const Text("ОБНОВИТЬ", style: TextStyle(color: Colors.greenAccent, fontSize: 12, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
            ],
            /////// 
            */
            // Кнопка "Создать задание" - удалена из content, перемещена в actions ниже
                ],
              ),
            ),
            actions: [
              // Админ-панель (твой блок полностью сохранён)
              if ((_petraAddress ?? "").toLowerCase() ==
                      "0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3".toLowerCase() &&
                  _selectedTaskIds.isNotEmpty)
               
                
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        TextButton(
                          onPressed: () => _adminBatchApproveTasks(_selectedTaskIds),
                          child: Text("ОДОБРИТЬ (${_selectedTaskIds.length})",
                              style: const TextStyle(color: Colors.greenAccent, fontSize: 12)),
                        ),
                        TextButton(
                          onPressed: () {
                            // твоя логика отклонения
                          },
                          child: Text("ОТКЛОНИТЬ (${_selectedTaskIds.length})",
                              style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
                        ),
                      ],
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        TextButton(
                          onPressed: _adminBatchDeleteTasks,
                          child: Text("УДАЛИТЬ (${_selectedTaskIds.length})",
                              style: const TextStyle(color: Colors.orangeAccent, fontSize: 12)),
                        ),
                        TextButton(
                          onPressed: () {
                            _setDialogState = null;
                            Navigator.pop(dialogContext);
                          },
                          child: const Text("ЗАКРЫТЬ", style: TextStyle(color: Colors.white54, fontSize: 12)),
                        ),
                      ],
                    ),
                  ],
                )
              else
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    // Кнопка "Создать" (перемещена сюда, сокращена, стиль TextButton для компактности)
                    if (isPetraConnected)
                      TextButton(
                        onPressed: hasActiveMegaTask ? null : _showTaskCreationChoiceDialog,
                        child: Text(
                          hasActiveMegaTask ? "ЛИМИТ 1/1" : "СОЗДАТЬ",
                          style: TextStyle(
                            color: hasActiveMegaTask ? Colors.grey : Colors.orangeAccent,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    // Кнопка ЗАКРЫТЬ (твоя, немного поправил стиль для порядка)
                    TextButton(
                      onPressed: () {
                        _setDialogState = null;
                        Navigator.pop(dialogContext);
                      },
                      child: const Text("ЗАКРЫТЬ", style: TextStyle(color: Colors.white54, fontSize: 12)),
                    ),
                    // Новая кнопка ОБНОВИТЬ
                    TextButton(
                      onPressed: () async {
                        showTopToast("🔄 Обновление списка заданий...");
                        await _fetchMegaTasks();
                        if (_setDialogState != null) {
                          _setDialogState!(() {}); 
                        }
                      },
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.refresh_rounded, color: Colors.greenAccent, size: 14),
                          const SizedBox(width: 4),
                          const Text("ОБНОВИТЬ", style: TextStyle(color: Colors.greenAccent, fontSize: 12, fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                  ],
                ),
            ],


          );
        },
      );
    },
  );
}


//// конец вывода заданий

Future<void> _fetchMegaTasks() async {
  //print("🛠 Начинаю загрузку заданий V2 + V3...");

  //debugPrint("✅ Загружено заданий (V2 + V3): ${_megaTasks.length}");
  // Добавляем этот вызов:
  _fetchV3Submissions();

  void update(bool loading, List<dynamic> tasks) {
    if (mounted) {
      setState(() { 
        _isLoadingTasks = loading; 
        _megaTasks = tasks; 
      });
    }
    if (_setDialogState != null) {
      try {
        _setDialogState!(() { 
          _isLoadingTasks = loading; 
          _megaTasks = tasks; 
        });
      } catch (e) { _setDialogState = null; }
    }
  }

  update(true, []);

  try {
    const String moduleAddress = "0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3";
    final viewUrl = Uri.parse("https://fullnode.mainnet.aptoslabs.com/v1/view");

    // Запросы V2 и V3
    final tasksV2Payload = {
      "function": "$moduleAddress::mega_tasks::get_all_tasks_v2",
      "type_arguments": [],
      "arguments": [],
    };

    final statusV2Payload = {
      "function": "$moduleAddress::mega_tasks::get_all_task_statuses",
      "type_arguments": [],
      "arguments": [],
    };

    final tasksV3Payload = {
      "function": "$moduleAddress::mega_tasks::get_all_tasks_v3",
      "type_arguments": [],
      "arguments": [],
    };

    final responses = await Future.wait([
      http.post(viewUrl, body: jsonEncode(tasksV2Payload), headers: {"Content-Type": "application/json"}),
      http.post(viewUrl, body: jsonEncode(statusV2Payload), headers: {"Content-Type": "application/json"}),
      http.post(viewUrl, body: jsonEncode(tasksV3Payload), headers: {"Content-Type": "application/json"}),
    ]).timeout(const Duration(seconds: 12));

    if (responses[0].statusCode != 200 || responses[2].statusCode != 200) {
      //print("⚠️ Ошибка загрузки задач");
      update(false, []);
      return;
    }

    // --- V2 ---
    final List rawTasksV2 = (jsonDecode(responses[0].body) as List).first ?? [];
    final dynamic statusDataV2 = (jsonDecode(responses[1].body) as List).first ?? [];

    List<int> statusListV2 = [];
    if (statusDataV2 is String) {
      String hexStr = statusDataV2.startsWith("0x") ? statusDataV2.substring(2) : statusDataV2;
      try { statusListV2 = hex.decode(hexStr); } catch (e) {}
    } else if (statusDataV2 is List) {
      statusListV2 = List<int>.from(statusDataV2);
    }

    // --- V3 ---
    final List rawTasksV3 = (jsonDecode(responses[2].body) as List).first ?? [];

    List<dynamic> combinedTasks = [];
    const String adminAddress = "0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3";
    final bool isAdmin = currentWalletAddress.toLowerCase() == adminAddress.toLowerCase();
    

    // Добавляем V2
    for (int i = 0; i < rawTasksV2.length; i++) {
      final Map<String, dynamic> task = Map.from(rawTasksV2[i]);
      final int taskStatus = (i < statusListV2.length) ? statusListV2[i] : 0;
      task['status'] = taskStatus;
      task['version'] = 'v2';

      final bool isCreator = task['creator'].toString().toLowerCase() == currentWalletAddress.toLowerCase();
      if (taskStatus == 1 || isCreator || isAdmin) {
        combinedTasks.add(task);
      }
    }

    // Добавляем V3
    for (var raw in rawTasksV3) {
      final TaskV3 task = TaskV3.fromJson(raw as Map<String, dynamic>);

        // Запрос статуса для этой задачи V3
      try {
        final statusPayload = {
          "function": "$moduleAddress::mega_tasks::get_task_status",
          "type_arguments": [],
          "arguments": [task.id.toString()],
        };
        final statusResp = await http.post(
          viewUrl,
          body: jsonEncode(statusPayload),
          headers: {"Content-Type": "application/json"},
        );

        if (statusResp.statusCode == 200) {
          final statusData = jsonDecode(statusResp.body);
          final int realStatus = (statusData as List).first ?? 0;
          task.status = realStatus;  // ← вот здесь обновляем!
          //print("V3 task #${task.id} → real status from get_task_status = $realStatus");
        }
      } catch (e) {
        //print("Не удалось получить статус для #${task.id}: $e");
      }


      //print("V3 task #${task.id} → status from chain = ${task.status}");

      final bool isCreator = task.creator.toLowerCase() == currentWalletAddress.toLowerCase();
      if (task.status == 1 || isCreator || isAdmin) {
        combinedTasks.add(task);
      }
    }

    // Сортируем (новые сверху)
    combinedTasks.sort((a, b) {
      final int idA = (a is TaskV3) ? a.id : int.parse(a['id'].toString());
      final int idB = (b is TaskV3) ? b.id : int.parse(b['id'].toString());
      return idB.compareTo(idA);
    });

    update(false, combinedTasks);
    //print("✅ Загружено заданий (V2 + V3): ${combinedTasks.length}");

  } catch (e) {
    //print("🆘 Ошибка загрузки задач: $e");
    update(false, []);
  }
}




Future<void> _fetchV3Submissions() async {
  int total = 0;
  Map<int, List<dynamic>> tempMap = {};
  Map<int, int> tempMyStatuses = {}; 
  
  // Убедись, что здесь адрес твоего Petra кошелька, а не контракта!
  String myAddr = currentWalletAddress.toLowerCase();

  for (var task in _megaTasks) {
    int taskId = (task is TaskV3) ? task.id : int.tryParse(task['id'].toString()) ?? -1;
    String creator = (task is TaskV3) ? task.creator : task['creator'].toString();
    bool isV3 = (task is TaskV3) || task['version'] == 'v3';

    if (isV3 && taskId != -1) {
      try {
        final payload = {
          "function": "0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3::mega_tasks::get_submissions_v3",
          "type_arguments": [],
          "arguments": [taskId.toString()],
        };

        final res = await http.post(
          Uri.parse("$aptLedgerUrl/view"),
          headers: {"Content-Type": "application/json"}, // ИСПРАВЛЕНИЕ ТУТ
          body: jsonEncode(payload),
        );
        
        if (res.statusCode == 200) {
          final decoded = jsonDecode(res.body);
          if (decoded is List && decoded.isNotEmpty) {
            final List subs = decoded.first ?? [];

            // 1. Для админа (свои задачи)
            if (creator.toLowerCase() == myAddr) {
              final pending = subs.where((s) => s['status'].toString() == "0").toList();
              if (pending.isNotEmpty) {
                tempMap[taskId] = pending;
                total += pending.length;
              }
            }

            // 2. Для воркера (свой ответ в любой задаче)
            for (var s in subs) {
              String workerAddr = s['worker'].toString().toLowerCase();
              if (workerAddr == myAddr) {
                tempMyStatuses[taskId] = int.tryParse(s['status'].toString()) ?? 0;
                //debugPrint("✅ Найдено выполнение для #$taskId. Статус: ${tempMyStatuses[taskId]}");
              }
            }
          }
        } else {
          //debugPrint("❌ Ошибка API (${res.statusCode}): ${res.body}");
        }
      } catch (e) { 
        //debugPrint("❌ Ошибка запроса для задачи $taskId: $e"); 
      }
    }
  }

  if (mounted) {
    setState(() {
      _pendingSubmissions = tempMap;
      _totalPendingV3 = total;
      _myV3Statuses = tempMyStatuses;
    });
    _setDialogState?.call(() {});
  }
}

Map<String, dynamic> getStatusDisplay(int status, String creatorAddr) {
  bool isCreator = creatorAddr == currentWalletAddress;
  bool isAdmin = currentWalletAddress == "0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3";

  switch (status) {
    case 0:
      if (isAdmin) return {"text": "НУЖНО ПРОВЕРИТЬ", "color": Colors.orange};
      if (isCreator) return {"text": "НА ПРОВЕРКЕ", "color": Colors.blueAccent};
      return {"text": "В ОЖИДАНИИ", "color": Colors.grey};
    case 1:
      return {"text": "НОВОЕ", "color": Colors.greenAccent};
    case 2:
      return {"text": "ЗАВЕРШЕНО", "color": Colors.purpleAccent};
    case 5:
      return {"text": "ОТКЛОНЕНО", "color": Colors.redAccent};
    default:
      return {"text": "АРХИВ", "color": Colors.grey};
  }
}


// Функция массового одобрения/отказа
Future<void> _handleMassVerify(int taskId, List<String> workers, bool approve) async {
  if (workers.isEmpty) {
    showTopToast("Список воркеров пуст");
    return;
  }

  try {
    // Формируем payload
    final payload = {
      "type": "entry_function_payload",
      "function": "0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3::mega_tasks::mass_verify_v3",
      "type_arguments": [],
      "arguments": [
        taskId.toString(), // Передаем ID как строку для u64
        workers,           // Список адресов (vector<address>)
        approve,           // bool (true/false)
      ],
    };

    //debugPrint("🚀 Отправка mass_verify_v3 для задачи #$taskId");
    //debugPrint("👥 Воркеров на проверку: ${workers.length}");

    // Используем наш обновленный универсальный метод
    await _sendAptosTransaction(payload);

    showTopToast("✅ Решение отправлено в блокчейн");
    
    // Закрываем диалог/экран
    if (mounted) {
      Navigator.pop(context);
    }

    // Даем чейну 2 секунды на обновление данных, прежде чем рефрешить список
    await Future.delayed(const Duration(seconds: 2));
    _fetchV3Submissions(); 

  } catch (e, stack) {
    //debugPrint("❌ Mass verify error: $e");
    //debugPrint("Stack: $stack");
    showTopToast("❌ Ошибка: $e", isError: true);
  }
}



void _showReviewListDialog() {
  showDialog(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 20),
      child: Container(
        // Рамка и фон
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: Colors.greenAccent.withOpacity(0.4),
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.5),
              blurRadius: 20,
              spreadRadius: 5,
            ),
          ],
        ),
        child: Column(
          children: [
            // Шапка диалога
            Padding(
              padding: const EdgeInsets.all(20.0),
              child: Row(
                children: [
                  const Icon(Icons.rate_review_outlined, color: Colors.greenAccent),
                  const SizedBox(width: 12),
                  const Text(
                    "Проверка ответов",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.pop(ctx),
                    icon: const Icon(Icons.close, color: Colors.white54),
                  ),
                ],
              ),
            ),
            
            const Divider(color: Colors.white10, height: 1),

            // Основной список
            Expanded(
              child: _pendingSubmissions.isEmpty
                  ? const Center(
                      child: Text("Нет новых ответов для проверки", 
                      style: TextStyle(color: Colors.white38)))
                  : ListView(
                      padding: const EdgeInsets.all(12),
                      children: _pendingSubmissions.entries.map((entry) {
                        int taskId = entry.key;
                        List subs = entry.value;
                        List<String> selectedWorkers = [];

                        return StatefulBuilder(builder: (context, setInternalState) {
                          return Container(
                            margin: const EdgeInsets.only(bottom: 12),
                            decoration: BoxDecoration(
                              color: const Color(0xFF252525),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: Colors.white10),
                            ),
                            child: ExpansionTile(
                              shape: const RoundedRectangleBorder(side: BorderSide.none),
                              collapsedShape: const RoundedRectangleBorder(side: BorderSide.none),
                              title: Text(
                                "Задача #$taskId",
                                style: const TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold),
                              ),
                              subtitle: Text(
                                "Ожидают проверки: ${subs.length}",
                                style: const TextStyle(color: Colors.white54, fontSize: 12),
                              ),
                              children: [
                                const Divider(color: Colors.white10),
                                ...subs.map((s) {
                                  String addr = s['worker'].toString();
                                  bool isSel = selectedWorkers.contains(addr);
                                  return CheckboxListTile(
                                    activeColor: Colors.greenAccent,
                                    checkColor: Colors.black,
                                    value: isSel,
                                    onChanged: (v) => setInternalState(() {
                                      v! ? selectedWorkers.add(addr) : selectedWorkers.remove(addr);
                                    }),
                                    title: Text(
                                      "${addr.substring(0, 8)}...${addr.substring(addr.length - 6)}",
                                      style: const TextStyle(fontSize: 13, color: Colors.white, fontFamily: 'monospace'),
                                    ),
                                    /*
                                    subtitle: Padding(
                                      padding: const EdgeInsets.only(top: 4),
                                      child: Text(
                                        "Ответ: ${s['content']}",
                                        style: const TextStyle(fontSize: 12, color: Colors.white70),
                                      ),
                                    ),*/
                                    subtitle: Padding(
                                      padding: const EdgeInsets.only(top: 4),
                                      child: Row(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          const Text("Ответ: ", style: TextStyle(fontSize: 12, color: Colors.white70)),
                                          Expanded(child: _buildClickableResponse(s['content'] ?? '')),
                                        ],
                                      ),
                                    ),

                                  );
                                }).toList(),
                                
                                // Панель действий для конкретной задачи
                                Padding(
                                  padding: const EdgeInsets.all(12.0),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: OutlinedButton.icon(
                                          style: OutlinedButton.styleFrom(
                                            side: BorderSide(color: selectedWorkers.isEmpty ? Colors.white10 : Colors.redAccent.withOpacity(0.5)),
                                            foregroundColor: Colors.redAccent,
                                            elevation: 0,
                                            minimumSize: const Size(0, 32),
                                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),    
                                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                          ),
                                          onPressed: selectedWorkers.isEmpty 
                                            ? null 
                                            : () => _handleMassVerify(taskId, selectedWorkers, false),
                                          icon: const Icon(Icons.close, size: 12),
                                          label: const Text("ОТКЛОНИТЬ"),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: ElevatedButton.icon(
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: Colors.greenAccent,
                                            foregroundColor: Colors.black,
                                            elevation: 0,
                                            minimumSize: const Size(0, 32),
                                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),     
                                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,   
                                          ),
                                          onPressed: selectedWorkers.isEmpty 
                                            ? null 
                                            : () => _handleMassVerify(taskId, selectedWorkers, true),
                                          icon: const Icon(Icons.check, size: 12),
                                          label: const Text("ОДОБРИТЬ", style: TextStyle(fontWeight: FontWeight.bold)),
                                        ),
                                      ),
                                    ],
                                  ),
                                )
                                ////
                              ],
                            ),
                          );
                        });
                      }).toList(),
                    ),
            ),
            
            // Нижняя панель 
           
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: SizedBox(
                width: double.infinity,
                child: TextButton(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    backgroundColor: Colors.white.withOpacity(0.05),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text("ЗАКРЫТЬ", style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold)),
                ),
              ),
            ),
           

          ],
        ),
      ),
    ),
  );
}


Future<void> _loadSavedData() async {
  //debugPrint("🚀 [DEBUG] Начинаю загрузку данных из памяти...");
  final prefs = await SharedPreferences.getInstance();
  
  // 1. Проверяем адрес
  final savedAddress = prefs.getString('petra_saved_address');
  //debugPrint("📡 [DEBUG] Считанный адрес: $savedAddress");
  
  // 2. Проверяем флаг подключения (Ключ из ваших констант: petraConnectedKey)
  // ВАЖНО: Мы проверяем и константу, и строку на всякий случай
  final bool isConnected = prefs.getBool(petraConnectedKey) ?? false;
  //debugPrint("🔗 [DEBUG] Флаг isPetraConnected из памяти: $isConnected");

  // отладка
  final String? savedPrivKey = prefs.getString('petra_temp_priv_key');
  final String? petraPubKey = prefs.getString('petra_saved_pub_key');
  //debugPrint("🔑 [STARTUP] Восстановление ключей из SharedPreferences:");
  //debugPrint("🔑 [STARTUP] Приватный ключ (DApp): ${savedPrivKey != null ? 'ЕСТЬ (длина: ${savedPrivKey.length})' : 'ПУСТО'}");
  //debugPrint("🔑 [STARTUP] Публичный ключ (Petra): ${petraPubKey != null ? 'ЕСТЬ' : 'ПУСТО'}");
  if (savedPrivKey != null) {
  try {
    // Восстанавливаем объект _myKeyPair из сохраненного приватного ключа
    final privBytes = base64.decode(savedPrivKey);
    _myKeyPair = await algorithm.newKeyPairFromSeed(privBytes);
    //debugPrint("✅ [STARTUP] _myKeyPair успешно восстановлен из памяти");
  } catch (e) {
    //debugPrint("❌ [STARTUP] Ошибка восстановления _myKeyPair: $e");
  }
}
  // конец отладки

  if (savedAddress != null && savedAddress.isNotEmpty && isConnected) {
    //debugPrint("✅ [DEBUG] Условия выполнены! Активирую красный статус кнопки.");
    setState(() {
      _petraAddress = savedAddress;
      currentWalletAddress = savedAddress;
      isPetraConnected = true; // Именно это делает кнопку красной
    });
    
    _updateWalletLabelText();
    _runUpdateThread();
  } else {
    //debugPrint("⚠️ [DEBUG] Условия не выполнены. Адрес пуст или флаг = false.");
    //debugPrint("Подробности: адрес_ок=${savedAddress != null}, флаг_ок=$isConnected");
  }
}


void _disconnectPetra() async {
  final prefs = await SharedPreferences.getInstance();
  
  // 1. Сохраняем адрес перед сбросом
  String currentAddressBeforeDisconnect = currentWalletAddress;
  
  // 2. ПОЛНАЯ очистка SharedPreferences
  await prefs.remove('petra_saved_pub_key');
  await prefs.remove('petra_temp_priv_key');
  await prefs.remove(lastPetraAddressKey);
  await prefs.setBool(petraConnectedKey, false);

  // 3. ОБНУЛЕНИЕ переменных в оперативной памяти (Критично!)
  // Если не обнулить _myKeyPair, старая сессия может "прилипнуть"
  _myKeyPair = null; 

  // 4. Логика сохранения адреса как "ручного"
  if (currentAddressBeforeDisconnect == defaultExampleAddress) {
    final String? savedManualAddress = prefs.getString(manualAddressKey);
    if (savedManualAddress != null && 
        savedManualAddress.length == 66 && 
        savedManualAddress.startsWith("0x")) {
      currentAddressBeforeDisconnect = savedManualAddress;
    }
  } else if (currentAddressBeforeDisconnect.length == 66 && 
             currentAddressBeforeDisconnect.startsWith("0x")) {
    await prefs.setString(manualAddressKey, currentAddressBeforeDisconnect);
  }

  // 5. Обновляем UI
  setState(() {
    currentWalletAddress = currentAddressBeforeDisconnect;
    isPetraConnected = false; 
    _updateWalletLabelText();
  });
  
  // 6. Синхронизируем состояние
  _saveWalletAddress(currentAddressBeforeDisconnect, isPetra: false);
  
  showTopToast("Кошелек Petra отключен");
  //debugPrint("🧹 Сессия Petra полностью очищена (включая _myKeyPair)");
}



Future<void> _connectPetra() async {
  try {
    // 1. Генерируем ОДНУ пару ключей
    final keyPair = await algorithm.newKeyPair();
    final privBytes = await keyPair.extractPrivateKeyBytes();
    
    // 2. Сохраняем приватный ключ (он нужен для расшифровки ответов Petra)
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('petra_temp_priv_key', base64.encode(privBytes));
    
    // 3. Сохраняем пару в переменную класса
    _myKeyPair = keyPair;
    
    // 4. Готовим публичный ключ для Petra
    final pubKey = await keyPair.extractPublicKey();
    String pubKeyHex = _bytesToHex(Uint8List.fromList(pubKey.bytes));

    // Важно: Убираем 0x, если он есть, для чистоты протокола
    if (pubKeyHex.startsWith('0x')) {
      pubKeyHex = pubKeyHex.substring(2);
    }

    //debugPrint("📡 [CONNECT] DApp PubKey (отправка в Petra): $pubKeyHex");

    // 5. Формируем Payload
    // Убедись, что name: "Mega App" совпадает с тем, что в транзакциях!
    final payload = {
      "appInfo": {"name": "Mega", "domain": "https://mega.io"},
      "redirectLink": "mega://api/v1/connect",
      "dappEncryptionPublicKey": pubKeyHex,
    };

    final String encodedData = base64.encode(utf8.encode(jsonEncode(payload)));
    final url = Uri.parse("petra://api/v1/connect?data=$encodedData");
    
    // 6. Запуск
    if (await canLaunchUrl(url)) {

      showTopToast("🔑 Подключаем кошелек Petra...");
      await Future.delayed(const Duration(seconds: 2));

      await launchUrl(url, mode: LaunchMode.externalApplication);
    } else {
      showTopToast("❌ Кошелек Petra не найден", isError: true);
    }

  } catch (e, stack) {
    //debugPrint("❌ Petra Connect Error: $e");
    //debugPrint("Stack: $stack");
    showTopToast("Ошибка подключения: $e", isError: true);
  }
}

//////////////

Future<void> _handlePetraConnectResponse(Uri uri) async {
  // 1. Достаем запакованный 'data'
  final data = uri.queryParameters['data'];
  final prefs = await SharedPreferences.getInstance();

  if (data == null) {
    showTopToast("❌ Нет данных от кошелька", isError: true);
    return;
  }

  try {
    // 2. Декодируем base64 → utf8 → json
    // Petra присылает данные именно внутри этого зашифрованного/закодированного блока
    final decoded = jsonDecode(utf8.decode(base64.decode(data)));

    final String? newAddr = decoded['address'];
    final String? petraPubKey = decoded['petraPublicEncryptedKey']; // Ключ шифрования (X25519)
    final String? publicKey = decoded['publicKey'];               // Публичный ключ аккаунта

    // --- БЛОК ОТЛАДКИ (Теперь он будет показывать реальные данные) ---
    //debugPrint("📥 [RESPONSE] Ответ от Petra успешно декодирован:");
    //debugPrint("📥 Address: $newAddr");
    //debugPrint("📥 Petra Encryption PubKey: $petraPubKey");
    //debugPrint("📥 Account PublicKey: $publicKey");

    if (petraPubKey != null) {
      final oldKey = prefs.getString('petra_saved_pub_key');
      if (oldKey != null && oldKey != petraPubKey) {
       // debugPrint("⚠️ [ATTENTION] Petra прислала НОВЫЙ ключ шифрования! Старый: $oldKey");
      }
    }
    // -----------------------------------------------------------------

    if (newAddr == null || newAddr.isEmpty) {
      showTopToast("❌ Кошелёк не вернул адрес", isError: true);
      return;
    }

    // 3. Обновляем состояние UI (твой оригинальный код)
    setState(() {
      // Обнуляем старые данные перед загрузкой новых
      megaCurrentReward = BigInt.zero;
      megaStakedAmountRaw = BigInt.zero;
      megaStakeBalance = 0.0;
      meeCurrentReward = 0.0;

      // Устанавливаем новые данные кошелька
      currentWalletAddress = newAddr;
      _petraAddress = newAddr;
      isPetraConnected = true;

      _updateWalletLabelText();
    });

    // 4. Сохраняем всё в SharedPreferences
    await prefs.setString('petra_saved_address', newAddr);
    await prefs.setBool(petraConnectedKey, true);

    if (petraPubKey != null) {
      await prefs.setString('petra_saved_pub_key', petraPubKey);
    }
    if (publicKey != null) {
      await prefs.setString('petra_full_public_key', publicKey);
    }

    // 5. Твои дополнительные методы инициализации
    _saveWalletAddress(newAddr, isPetra: true);
    _runUpdateThread();

    if (mounted) {
      showTopToast(
        "Кошелёк подключён:\n${newAddr.substring(0, 6)}...${newAddr.substring(newAddr.length - 4)}",
      );
    }

   // debugPrint('✅ Адрес и ключи сохранены: $newAddr');

  } on FormatException catch (e) {
   // debugPrint("❌ Ошибка формата данных от Petra: $e");
    showTopToast(
      "❌ Некорректный ответ от кошелька.\n"
      "Удалите mega.io в Connected apps в Petra и попробуйте снова.",
      isError: true,
    );
    _resetPetraConnectionState();

  } catch (e, stack) {
   // debugPrint("❌ Неизвестная ошибка в _handlePetraConnectResponse: $e");
   // debugPrint("Stack: $stack");
    showTopToast(
      "❌ Ошибка подключения.\n"
      "В Petra → Настройки → Security & Privacy → Connected apps → удалите mega.io и подключитесь заново.",
      isError: true,
    );
    _resetPetraConnectionState();
  }
}


// Вспомогательный метод (добавь куда удобно, например в класс)
void _resetPetraConnectionState() {
  setState(() {
    isPetraConnected = false;
    _petraAddress = null;
    currentWalletAddress = defaultExampleAddress;
    _myKeyPair = null;               // ← очень важно, если ключи используются дальше
    // если есть petraKeyHex, savedPrivKey — тоже обнуляй
  });

 
}

/////////////////////////


// Утилита для HEX 
String _bytesToHex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List _hexToBytes(String hex) {
  hex = hex.startsWith('0x') ? hex.substring(2) : hex;
  return Uint8List.fromList(List.generate(
    hex.length ~/ 2,
    (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16),
  ));
}


Future<void> _harvest() async {
  if (_myKeyPair == null) {
    showTopToast("❌ Ошибка: ключи не инициализированы.", isError: true);
    return;
  }

  final prefs = await SharedPreferences.getInstance();
  // Достаем сохраненный ключ Petra
  String? petraKeyHex = prefs.getString('petra_saved_pub_key');
  final savedPrivKey = prefs.getString('petra_temp_priv_key');

  if (petraKeyHex == null || savedPrivKey == null) {
    showTopToast("❌ Ошибка: переподключите кошелёк", isError: true);
    return;
  }

  try {
    // !!! ИСПРАВЛЕНИЕ 1: Очищаем HEX от 0x, если он есть
    if (petraKeyHex.startsWith('0x')) {
      petraKeyHex = petraKeyHex.substring(2);
    }

    // Восстанавливаем приватный ключ DApp и публичный ключ Petra
    final myPrivKey = pine.PrivateKey(base64.decode(savedPrivKey));
    final petraPubKey = pine.PublicKey(_hexToBytes(petraKeyHex));

    // 1. Формируем объект транзакции
    final txObject = {
      "function": "0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3::mega_coin::harvest",
      "type": "entry_function_payload",
      "type_arguments": [],
      "arguments": [],
    };

    // 2. Кодируем в JSON, а затем в Base64 (это стандарт для Petra)
    final innerJsonString = jsonEncode(txObject);
    final innerBase64 = base64.encode(utf8.encode(innerJsonString));

    // 3. Шифрование через NaCl Box
    final box = pine.Box(myPrivateKey: myPrivKey, theirPublicKey: petraPubKey);
    final nonce = pine.PineNaClUtils.randombytes(24);
    
    // Шифруем именно base64-строку
    final encrypted = box.encrypt(utf8.encode(innerBase64), nonce: nonce);

    // 4. Получаем публичный ключ DApp
    final pubKey = await _myKeyPair!.extractPublicKey();
    String myPubKeyHex = _bytesToHex(Uint8List.fromList(pubKey.bytes));
    
    // !!! ИСПРАВЛЕНИЕ 2: Убеждаемся, что наш ключ для Petra БЕЗ 0x
    if (myPubKeyHex.startsWith('0x')) {
      myPubKeyHex = myPubKeyHex.substring(2);
    }

    // 5. Итоговый объект для отправки в Petra
    final finalRequest = {
      "appInfo": {"name": "Mega", "domain": "https://mega.io"},
      "dappEncryptionPublicKey": myPubKeyHex, // Наш публичный ключ (HEX без 0x)
      "nonce": _bytesToHex(Uint8List.fromList(nonce)),
      "payload": _bytesToHex(Uint8List.fromList(encrypted.cipherText)),
      "redirectLink": "mega://api/v1/harvest",
    };

    final dataParam = base64.encode(utf8.encode(jsonEncode(finalRequest)));
    final url = Uri.parse("petra://api/v1/signAndSubmit?data=$dataParam");

    //debugPrint("🚀 Отправляю Harvest в Petra...");

    showTopToast("🔄 Подготовка транзакции...\nОткрываем кошелек для подтверждения");
    await Future.delayed(const Duration(seconds: 1)); 

    await launchUrl(url, mode: LaunchMode.externalApplication);

  } catch (e, stack) {
   // debugPrint("❌ Harvest Error: $e");
   // debugPrint("Stack: $stack");
    showTopToast("❌ Ошибка при подготовке транзакции", isError: true);
  }
}



Future<void> _harvest10() async {
  if (_myKeyPair == null) {
    showTopToast("❌ Ошибка: ключи не инициализированы.\nВ Petra → Настройки → Security & Privacy → Connected apps → удалите mega.io и подключитесь заново.", isError: true);
    return;
  }

  final prefs = await SharedPreferences.getInstance();
  // Достаем сохраненный публичный ключ Petra и наш временный приватный ключ
  String? petraKeyHex = prefs.getString('petra_saved_pub_key');
  final String? savedPrivKey = prefs.getString('petra_temp_priv_key');

  if (petraKeyHex == null || savedPrivKey == null) {
    showTopToast("❌ Ошибка: ключи не инициализированы.\nПожалуйста, переподключите кошелёк.", isError: true);
    return;
  }

  try {
    // --- ПОДГОТОВКА КЛЮЧЕЙ ---
    
    // 1. Обязательно очищаем публичный ключ Petra от "0x", если он пришел в таком формате
    if (petraKeyHex.startsWith('0x')) {
      petraKeyHex = petraKeyHex.substring(2);
    }

    final myPrivKey = pine.PrivateKey(base64.decode(savedPrivKey));
    final petraPubKey = pine.PublicKey(_hexToBytes(petraKeyHex));

    // 2. Формируем объект транзакции (Payload)
    final txObject = {
      // ИСПОЛЬЗУЕМ harvest10
      "function": "0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3::mega_coin::harvest10",
      "type": "entry_function_payload",
      "type_arguments": [],
      "arguments": [],
    };

    // 3. Кодируем транзакцию: JSON -> UTF8 -> Base64
    final innerJsonString = jsonEncode(txObject);
    final innerBase64 = base64.encode(utf8.encode(innerJsonString));

    // 4. Шифрование через NaCl Box (X25519 + XSalsa20 + Poly1305)
    final box = pine.Box(myPrivateKey: myPrivKey, theirPublicKey: petraPubKey);
    final nonce = pine.PineNaClUtils.randombytes(24);
    
    // Шифруем Base64-строку транзакции
    final encrypted = box.encrypt(utf8.encode(innerBase64), nonce: nonce);

    // 5. Получаем наш публичный ключ DApp
    final pubKey = await _myKeyPair!.extractPublicKey();
    String myPubKeyHex = _bytesToHex(Uint8List.fromList(pubKey.bytes));
    
    // Убеждаемся, что наш HEX тоже без 0x для отправки в Petra
    if (myPubKeyHex.startsWith('0x')) {
      myPubKeyHex = myPubKeyHex.substring(2);
    }

    // 6. Формируем финальный запрос к API кошелька
    final finalRequest = {
      "appInfo": {"name": "Mega", "domain": "https://mega.io"},
      "dappEncryptionPublicKey": myPubKeyHex,
      "nonce": _bytesToHex(Uint8List.fromList(nonce)),
      "payload": _bytesToHex(Uint8List.fromList(encrypted.cipherText)),
      "redirectLink": "mega://api/v1/harvest10", 
    };

    // 7. Запаковываем всё в URL
    final dataParam = base64.encode(utf8.encode(jsonEncode(finalRequest)));
    final url = Uri.parse("petra://api/v1/signAndSubmit?data=$dataParam");

    //debugPrint("🚀 Отправляю Harvest10 в Petra...");
    //debugPrint("📡 DApp PubKey: $myPubKeyHex");
    //debugPrint("📡 Target Petra PubKey: $petraKeyHex");

    showTopToast("🔄 Подготовка транзакции...\nОткрываем кошелек для подтверждения");
    await Future.delayed(const Duration(seconds: 1)); 

    await launchUrl(url, mode: LaunchMode.externalApplication);

  } catch (e, stack) {
   // debugPrint("❌ Harvest10 Error: $e");
   // debugPrint("Stack: $stack");
    showTopToast("❌ Ошибка при подготовке транзакции", isError: true);
  }
}


Future<void> _harvest100() async {
  if (_myKeyPair == null) {
    showTopToast("❌ Ошибка: ключи не инициализированы.\nВ Petra → Настройки → Security & Privacy → Connected apps → удалите mega.io и подключитесь заново.", isError: true);
    return;
  }

  final prefs = await SharedPreferences.getInstance();
  // Извлекаем ключи из памяти
  String? petraKeyHex = prefs.getString('petra_saved_pub_key');
  final String? savedPrivKey = prefs.getString('petra_temp_priv_key');

  if (petraKeyHex == null || savedPrivKey == null) {
    showTopToast("❌ Ошибка: ключи не инициализированы.\nПожалуйста, переподключите кошелёк.", isError: true);
    return;
  }

  try {
    // 1. Очищаем публичный ключ Petra от префикса "0x", если он есть
    // Это критично для корректной работы функции _hexToBytes
    if (petraKeyHex.startsWith('0x')) {
      petraKeyHex = petraKeyHex.substring(2);
    }

    final myPrivKey = pine.PrivateKey(base64.decode(savedPrivKey));
    final petraPubKey = pine.PublicKey(_hexToBytes(petraKeyHex));

    // 2. Формируем объект транзакции для функции harvest100
    final txObject = {
      "function": "0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3::mega_coin::harvest100",
      "type": "entry_function_payload",
      "type_arguments": [],
      "arguments": [],
    };

    // 3. Кодируем Payload в Base64 (стандарт Petra для шифруемых данных)
    final innerJsonString = jsonEncode(txObject);
    final innerBase64 = base64.encode(utf8.encode(innerJsonString));

    // 4. Шифрование через NaCl Box
    final box = pine.Box(myPrivateKey: myPrivKey, theirPublicKey: petraPubKey);
    final nonce = pine.PineNaClUtils.randombytes(24);
    
    // Шифруем именно Base64 строку
    final encrypted = box.encrypt(utf8.encode(innerBase64), nonce: nonce);

    // 5. Подготовка нашего публичного ключа DApp
    final pubKey = await _myKeyPair!.extractPublicKey();
    String myPubKeyHex = _bytesToHex(Uint8List.fromList(pubKey.bytes));
    
    // Убеждаемся, что наш ключ тоже без 0x (Petra ждет чистый HEX)
    if (myPubKeyHex.startsWith('0x')) {
      myPubKeyHex = myPubKeyHex.substring(2);
    }

    // 6. Формируем финальный запрос
    final finalRequest = {
      "appInfo": {"name": "Mega", "domain": "https://mega.io"},
      "dappEncryptionPublicKey": myPubKeyHex,
      "nonce": _bytesToHex(Uint8List.fromList(nonce)),
      "payload": _bytesToHex(Uint8List.fromList(encrypted.cipherText)),
      "redirectLink": "mega://api/v1/harvest100", 
    };

    // 7. Сборка и запуск URL
    final dataParam = base64.encode(utf8.encode(jsonEncode(finalRequest)));
    final url = Uri.parse("petra://api/v1/signAndSubmit?data=$dataParam");

    //debugPrint("🚀 Отправляю Harvest100 в Petra...");
    //debugPrint("📡 Используемый Petra PubKey: $petraKeyHex");

    showTopToast("🔄 Подготовка транзакции...\nОткрываем кошелек для подтверждения");
    await Future.delayed(const Duration(seconds: 1)); 

    await launchUrl(url, mode: LaunchMode.externalApplication);

  } catch (e, stack) {
   // debugPrint("❌ Harvest100 Error: $e");
   // debugPrint("Stack: $stack");
    showTopToast("❌ Ошибка при подготовке транзакции", isError: true);
  }
}


Future<void> _claimRewards() async {
  if (_myKeyPair == null) {
    showTopToast("❌ Ошибка: ключи не инициализированы.\nВ Petra → Настройки → Security & Privacy → Connected apps → удалите mega.io и подключитесь заново.", isError: true);
    return;
  }

  final prefs = await SharedPreferences.getInstance();
  String? petraKeyHex = prefs.getString('petra_saved_pub_key');
  final String? savedPrivKey = prefs.getString('petra_temp_priv_key');

  if (petraKeyHex == null || savedPrivKey == null) {
    showTopToast("❌ Ошибка: ключи не инициализированы.\nПожалуйста, переподключите кошелёк.", isError: true);
    return;
  }

  try {
    // 1. Очистка ключа Petra от "0x"
    if (petraKeyHex.startsWith('0x')) {
      petraKeyHex = petraKeyHex.substring(2);
    }

    final myPrivKey = pine.PrivateKey(base64.decode(savedPrivKey));
    final petraPubKey = pine.PublicKey(_hexToBytes(petraKeyHex));

    // 2. Формируем объект транзакции
    final txObject = {
      "function": "0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3::mega_coin::claim_staking_rewards",
      "type": "entry_function_payload",
      "type_arguments": [],
      "arguments": [],
    };

    final innerJsonString = jsonEncode(txObject);
    final innerBase64 = base64.encode(utf8.encode(innerJsonString));

    // 3. Шифрование пакета
    final box = pine.Box(myPrivateKey: myPrivKey, theirPublicKey: petraPubKey);
    final nonce = pine.PineNaClUtils.randombytes(24);
    final encrypted = box.encrypt(utf8.encode(innerBase64), nonce: nonce);

    // 4. Подготовка нашего ключа (DApp)
    final pubKey = await _myKeyPair!.extractPublicKey();
    String myPubKeyHex = _bytesToHex(Uint8List.fromList(pubKey.bytes));
    
    // Также очищаем наш ключ от 0x
    if (myPubKeyHex.startsWith('0x')) {
      myPubKeyHex = myPubKeyHex.substring(2);
    }

    // 5. Финальный запрос в Petra
    final finalRequest = {
      "appInfo": {"name": "Mega", "domain": "https://mega.io"},
      "dappEncryptionPublicKey": myPubKeyHex,
      "nonce": _bytesToHex(Uint8List.fromList(nonce)),
      "payload": _bytesToHex(Uint8List.fromList(encrypted.cipherText)),
      "redirectLink": "mega://api/v1/claim", 
    };

    final dataParam = base64.encode(utf8.encode(jsonEncode(finalRequest)));
    final url = Uri.parse("petra://api/v1/signAndSubmit?data=$dataParam");

    //debugPrint("🚀 Отправляю запрос на получение наград стейкинга...");

    if (await canLaunchUrl(url)) {
        
      showTopToast("💰 Забираем награду в \$MEGA");
      await Future.delayed(const Duration(seconds: 2)); 

      await launchUrl(url, mode: LaunchMode.externalApplication);
    } else {
      showTopToast("❌ Кошелек Petra не найден", isError: true);
    }

  } catch (e, stack) {
    //debugPrint("❌ Claim Rewards Error: $e");
    //debugPrint("Stack: $stack");
    showTopToast("❌ Ошибка подготовки транзакции", isError: true);
  }
}


Future<void> _stakeMega() async {
  if (_myKeyPair == null) {
    showTopToast("❌ Ошибка: ключи не инициализированы.\nВ Petra → Настройки → Security & Privacy → Connected apps → удалите mega.io и подключитесь заново.", isError: true);
    return;
  }

  final prefs = await SharedPreferences.getInstance();
  String? petraKeyHex = prefs.getString('petra_saved_pub_key');
  final String? savedPrivKey = prefs.getString('petra_temp_priv_key');

  if (petraKeyHex == null || savedPrivKey == null) {
    showTopToast("❌ Ошибка: ключи не инициализированы.\nПожалуйста, переподключите кошелёк.", isError: true);
    return;
  }

  try {
    // 1. Очистка ключа Petra от префикса "0x"
    if (petraKeyHex.startsWith('0x')) {
      petraKeyHex = petraKeyHex.substring(2);
    }

    final myPrivKey = pine.PrivateKey(base64.decode(savedPrivKey));
    final petraPubKey = pine.PublicKey(_hexToBytes(petraKeyHex));

    // 2. Объект транзакции для функции stake_all
    final txObject = {
      "function": "0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3::mega_coin::stake_all",
      "type": "entry_function_payload",
      "type_arguments": [],
      "arguments": [], 
    };

    final innerJsonString = jsonEncode(txObject);
    final innerBase64 = base64.encode(utf8.encode(innerJsonString));

    // 3. Шифрование пакета (Box)
    final box = pine.Box(myPrivateKey: myPrivKey, theirPublicKey: petraPubKey);
    final nonce = pine.PineNaClUtils.randombytes(24);
    final encrypted = box.encrypt(utf8.encode(innerBase64), nonce: nonce);

    // 4. Подготовка нашего публичного ключа
    final pubKey = await _myKeyPair!.extractPublicKey();
    String myPubKeyHex = _bytesToHex(Uint8List.fromList(pubKey.bytes));
    
    // Очищаем и наш ключ от 0x перед отправкой
    if (myPubKeyHex.startsWith('0x')) {
      myPubKeyHex = myPubKeyHex.substring(2);
    }

    // 5. Формирование финального запроса
    final finalRequest = {
      "appInfo": {"name": "Mega App", "domain": "https://mega.io"},
      "dappEncryptionPublicKey": myPubKeyHex,
      "nonce": _bytesToHex(Uint8List.fromList(nonce)),
      "payload": _bytesToHex(Uint8List.fromList(encrypted.cipherText)),
      "redirectLink": "mega://api/v1/stake", 
    };

    final dataParam = base64.encode(utf8.encode(jsonEncode(finalRequest)));
    final url = Uri.parse("petra://api/v1/signAndSubmit?data=$dataParam");

    //debugPrint("🚀 Запуск транзакции stake_all...");

    if (await canLaunchUrl(url)) {
      
      showTopToast("⏳ Переход в Petra для подтверждения стейкинга...");
      await Future.delayed(const Duration(seconds: 2));
      
      await launchUrl(url, mode: LaunchMode.externalApplication);
      /*showTopToast("⏳ Переход в Petra для подтверждения стейкинга...");*/

    } else {
      showTopToast("❌ Кошелек Petra не найден", isError: true);
    }

  } catch (e, stack) {
    //debugPrint("❌ Stake Error: $e");
    //debugPrint("Stack: $stack");
    showTopToast("❌ Ошибка подготовки стейкинга", isError: true);
  }
}

Future<void> _unstakeRequest() async {
  if (_myKeyPair == null) {
    showTopToast("❌ Ошибка: ключи не инициализированы.\nВ Petra → Настройки → Security & Privacy → Connected apps → удалите mega.io и подключитесь заново.", isError: true);
    return;
  }

  final prefs = await SharedPreferences.getInstance();
  String? petraKeyHex = prefs.getString('petra_saved_pub_key');
  final String? savedPrivKey = prefs.getString('petra_temp_priv_key');

  if (petraKeyHex == null || savedPrivKey == null) {
    showTopToast("❌ Ошибка: ключи не инициализированы.\nПожалуйста, переподключите кошелёк.", isError: true);
    return;
  }

  try {
    // 1. Очистка ключа Petra от "0x"
    if (petraKeyHex.startsWith('0x')) {
      petraKeyHex = petraKeyHex.substring(2);
    }

    final myPrivKey = pine.PrivateKey(base64.decode(savedPrivKey));
    final petraPubKey = pine.PublicKey(_hexToBytes(petraKeyHex));

    // 2. Объект транзакции для функции unstake_request
    final txObject = {
      "function": "0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3::mega_coin::unstake_request",
      "type": "entry_function_payload",
      "type_arguments": [],
      "arguments": [], 
    };

    final innerJsonString = jsonEncode(txObject);
    final innerBase64 = base64.encode(utf8.encode(innerJsonString));

    // 3. Шифрование пакета
    final box = pine.Box(myPrivateKey: myPrivKey, theirPublicKey: petraPubKey);
    final nonce = pine.PineNaClUtils.randombytes(24);
    final encrypted = box.encrypt(utf8.encode(innerBase64), nonce: nonce);

    // 4. Подготовка нашего публичного ключа
    final pubKey = await _myKeyPair!.extractPublicKey();
    String myPubKeyHex = _bytesToHex(Uint8List.fromList(pubKey.bytes));
    
    // Очищаем наш ключ от 0x
    if (myPubKeyHex.startsWith('0x')) {
      myPubKeyHex = myPubKeyHex.substring(2);
    }

    // 5. Формирование запроса в Petra
    final finalRequest = {
      "appInfo": {"name": "Mega App", "domain": "https://mega.io"},
      "dappEncryptionPublicKey": myPubKeyHex,
      "nonce": _bytesToHex(Uint8List.fromList(nonce)),
      "payload": _bytesToHex(Uint8List.fromList(encrypted.cipherText)),
      "redirectLink": "mega://api/v1/unstake", 
    };

    final dataParam = base64.encode(utf8.encode(jsonEncode(finalRequest)));
    final url = Uri.parse("petra://api/v1/signAndSubmit?data=$dataParam");

    //debugPrint("🚀 Отправляю запрос на unstake_request...");

    if (await canLaunchUrl(url)) {

      showTopToast("⏳ Переход в Petra для подтверждения вывода со стейкинга...");
      await Future.delayed(const Duration(seconds: 2));

      await launchUrl(url, mode: LaunchMode.externalApplication);
      /*showTopToast("⏳ Переход в Petra для подтверждения...");*/

    } else {
      showTopToast("❌ Кошелек Petra не найден", isError: true);
    }

  } catch (e, stack) {
    //debugPrint("❌ Unstake Request Error: $e");
    //debugPrint("Stack: $stack");
    showTopToast("❌ Ошибка подготовки транзакции", isError: true);
  }
}

Future<void> _cancelUnstake() async {
  if (_myKeyPair == null) {
    showTopToast("❌ Ошибка: ключи не инициализированы.\nВ Petra → Настройки → Security & Privacy → Connected apps → удалите mega.io и подключитесь заново.", isError: true);
    return;
  }

  final prefs = await SharedPreferences.getInstance();
  String? petraKeyHex = prefs.getString('petra_saved_pub_key');
  final String? savedPrivKey = prefs.getString('petra_temp_priv_key');

  if (petraKeyHex == null || savedPrivKey == null) {
    showTopToast("❌ Ошибка: ключи не инициализированы.\nПожалуйста, переподключите кошелёк.", isError: true);
    return;
  }

  try {
    // 1. Очистка ключа Petra от префикса "0x"
    if (petraKeyHex.startsWith('0x')) {
      petraKeyHex = petraKeyHex.substring(2);
    }

    final myPrivKey = pine.PrivateKey(base64.decode(savedPrivKey));
    final petraPubKey = pine.PublicKey(_hexToBytes(petraKeyHex));

    // 2. Объект транзакции для функции cancel_unstake
    final txObject = {
      "function": "0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3::mega_coin::cancel_unstake",
      "type": "entry_function_payload",
      "type_arguments": [],
      "arguments": [],
    };

    final innerJsonString = jsonEncode(txObject);
    final innerBase64 = base64.encode(utf8.encode(innerJsonString));

    // 3. Шифрование пакета через NaCl Box
    final box = pine.Box(myPrivateKey: myPrivKey, theirPublicKey: petraPubKey);
    final nonce = pine.PineNaClUtils.randombytes(24);
    final encrypted = box.encrypt(utf8.encode(innerBase64), nonce: nonce);

    // 4. Подготовка нашего публичного ключа DApp
    final pubKey = await _myKeyPair!.extractPublicKey();
    String myPubKeyHex = _bytesToHex(Uint8List.fromList(pubKey.bytes));
    
    // Очищаем и наш ключ от 0x перед отправкой
    if (myPubKeyHex.startsWith('0x')) {
      myPubKeyHex = myPubKeyHex.substring(2);
    }

    // 5. Формирование финального запроса для кошелька
    final finalRequest = {
      "appInfo": {"name": "Mega App", "domain": "https://mega.io"},
      "dappEncryptionPublicKey": myPubKeyHex,
      "nonce": _bytesToHex(Uint8List.fromList(nonce)),
      "payload": _bytesToHex(Uint8List.fromList(encrypted.cipherText)),
      "redirectLink": "mega://api/v1/cancel_unstake", 
    };

    final dataParam = base64.encode(utf8.encode(jsonEncode(finalRequest)));
    final url = Uri.parse("petra://api/v1/signAndSubmit?data=$dataParam");

    //debugPrint("🚀 Отправляю запрос на cancel_unstake...");

    if (await canLaunchUrl(url)) {

      showTopToast("⏳ Переход в Petra для подтверждения стейкинга...");
      await Future.delayed(const Duration(seconds: 2));

      await launchUrl(url, mode: LaunchMode.externalApplication);
      /*showTopToast("⏳ Переход в Petra для отмены разстейкинга...");*/

    } else {
      showTopToast("❌ Кошелек Petra не найден", isError: true);
    }

  } catch (e, stack) {
    //debugPrint("❌ Cancel Unstake Error: $e");
    //debugPrint("Stack: $stack");
    showTopToast("❌ Ошибка подготовки транзакции", isError: true);
  }
}


Future<void> _unstakeConfirm() async {
  if (_myKeyPair == null) {
    showTopToast("❌ Ошибка: ключи не инициализированы.\nВ Petra → Настройки → Security & Privacy → Connected apps → удалите mega.io и подключитесь заново.", isError: true);
    return;
  }

  final prefs = await SharedPreferences.getInstance();
  String? petraKeyHex = prefs.getString('petra_saved_pub_key');
  final String? savedPrivKey = prefs.getString('petra_temp_priv_key');

  if (petraKeyHex == null || savedPrivKey == null) {
    showTopToast("❌ Ошибка: ключи не инициализированы.\nПожалуйста, переподключите кошелёк.", isError: true);
    return;
  }

  try {
    // 1. Очистка ключа Petra от префикса "0x"
    if (petraKeyHex.startsWith('0x')) {
      petraKeyHex = petraKeyHex.substring(2);
    }

    final myPrivKey = pine.PrivateKey(base64.decode(savedPrivKey));
    final petraPubKey = pine.PublicKey(_hexToBytes(petraKeyHex));

    // 2. Объект транзакции для функции unstake_confirm
    final txObject = {
      "function": "0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3::mega_coin::unstake_confirm",
      "type": "entry_function_payload",
      "type_arguments": [],
      "arguments": [],
    };

    final innerJsonString = jsonEncode(txObject);
    final innerBase64 = base64.encode(utf8.encode(innerJsonString));

    // 3. Шифрование пакета (Box)
    final box = pine.Box(myPrivateKey: myPrivKey, theirPublicKey: petraPubKey);
    final nonce = pine.PineNaClUtils.randombytes(24);
    final encrypted = box.encrypt(utf8.encode(innerBase64), nonce: nonce);

    // 4. Подготовка нашего публичного ключа DApp
    final pubKey = await _myKeyPair!.extractPublicKey();
    String myPubKeyHex = _bytesToHex(Uint8List.fromList(pubKey.bytes));
    
    // Очищаем и наш ключ от 0x перед отправкой в Petra
    if (myPubKeyHex.startsWith('0x')) {
      myPubKeyHex = myPubKeyHex.substring(2);
    }

    // 5. Формирование финального запроса
    final finalRequest = {
      "appInfo": {"name": "Mega App", "domain": "https://mega.io"},
      "dappEncryptionPublicKey": myPubKeyHex,
      "nonce": _bytesToHex(Uint8List.fromList(nonce)),
      "payload": _bytesToHex(Uint8List.fromList(encrypted.cipherText)),
      "redirectLink": "mega://api/v1/unstake_confirm", 
    };

    final dataParam = base64.encode(utf8.encode(jsonEncode(finalRequest)));
    final url = Uri.parse("petra://api/v1/signAndSubmit?data=$dataParam");

    //debugPrint("🚀 Отправляю запрос на подтверждение вывода (unstake_confirm)...");

    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
      showTopToast("⏳ Переход в Petra для подтверждения получения средств...");
    } else {
      showTopToast("❌ Кошелек Petra не найден", isError: true);
    }

  } catch (e, stack) {
    //debugPrint("❌ Unstake Confirm Error: $e");
    //debugPrint("Stack: $stack");
    showTopToast("❌ Ошибка подготовки транзакции", isError: true);
  }
}


/// mee harvest
Future<void> _harvestMee() async {
  if (_myKeyPair == null) {
    showTopToast("❌ Ошибка: ключи не инициализированы.\nВ Petra → Настройки → Security & Privacy → Connected apps → удалите mega.io и подключитесь заново.", isError: true);
    return;
  }

  final prefs = await SharedPreferences.getInstance();
  String? petraKeyHex = prefs.getString('petra_saved_pub_key');
  final String? savedPrivKey = prefs.getString('petra_temp_priv_key');

  if (petraKeyHex == null || savedPrivKey == null) {
    showTopToast("❌ Ошибка: ключи не инициализированы.\nПожалуйста, переподключите кошелёк.", isError: true);
    return;
  }

  try {
    // 1. Очистка ключа Petra от "0x"
    if (petraKeyHex.startsWith('0x')) {
      petraKeyHex = petraKeyHex.substring(2);
    }

    final myPrivKey = pine.PrivateKey(base64.decode(savedPrivKey));
    final petraPubKey = pine.PublicKey(_hexToBytes(petraKeyHex));

    // 2. Параметры для MeeCoin
    const meeType = "0xe9c192ff55cffab3963c695cff6dbf9dad6aff2bb5ac19a6415cad26a81860d9::mee_coin::MeeCoin";

    // 3. Формируем Payload
    final txObject = {
      "function": "0x514cfb77665f99a2e4c65a5614039c66d13e00e98daf4c86305651d29fd953e5::Staking::harvest",
      "type": "entry_function_payload",
      "type_arguments": [meeType, meeType], 
      "arguments": [],
    };

    final innerJsonString = jsonEncode(txObject);
    final innerBase64 = base64.encode(utf8.encode(innerJsonString));

    // 4. Шифрование NaCl Box
    final box = pine.Box(myPrivateKey: myPrivKey, theirPublicKey: petraPubKey);
    final nonce = pine.PineNaClUtils.randombytes(24);
    final encrypted = box.encrypt(utf8.encode(innerBase64), nonce: nonce);

    // 5. Наш публичный ключ
    final pubKey = await _myKeyPair!.extractPublicKey();
    String myPubKeyHex = _bytesToHex(Uint8List.fromList(pubKey.bytes));
    
    // Очищаем наш ключ от 0x
    if (myPubKeyHex.startsWith('0x')) {
      myPubKeyHex = myPubKeyHex.substring(2);
    }

    // 6. Формирование запроса
    final finalRequest = {
      "appInfo": {"name": "Mega App", "domain": "https://mega.io"},
      "dappEncryptionPublicKey": myPubKeyHex,
      "nonce": _bytesToHex(Uint8List.fromList(nonce)),
      "payload": _bytesToHex(Uint8List.fromList(encrypted.cipherText)),
      "redirectLink": "mega://api/v1/harvest_mee", 
    };

    final dataParam = base64.encode(utf8.encode(jsonEncode(finalRequest)));
    final url = Uri.parse("petra://api/v1/signAndSubmit?data=$dataParam");

    //debugPrint("🚀 Отправляю запрос harvest для MEE...");

    if (await canLaunchUrl(url)) {

      showTopToast("⏳ Переход в Petra для получения MEE...");
      await Future.delayed(const Duration(seconds: 2)); 

      await launchUrl(url, mode: LaunchMode.externalApplication);
      /* showTopToast("⏳ Переход в Petra для получения MEE...");*/
    } else {
      showTopToast("❌ Кошелек Petra не найден", isError: true);
    }

  } catch (e, stack) {
    //debugPrint("❌ Harvest MEE Error: $e");
    //debugPrint("Stack: $stack");
    showTopToast("❌ Ошибка подготовки транзакции", isError: true);
  }
}


Future<void> _stakeMee() async {
  if (_myKeyPair == null) {
    showTopToast("❌ Ошибка: ключи не инициализированы.\nВ Petra → Настройки → Security & Privacy → Connected apps → удалите mega.io и подключитесь заново.", isError: true);
    return;
  }

  // Используем meeOnChain (баланс в кошельке)
  // Вычитаем небольшой запас для надежности
  double amountToStake = meeOnChain - 0.0001;

  if (amountToStake <= 0) {
    showTopToast("❌ Недостаточно MEE для стейкинга");
    return;
  }

  final prefs = await SharedPreferences.getInstance();
  String? petraKeyHex = prefs.getString('petra_saved_pub_key');
  final String? savedPrivKey = prefs.getString('petra_temp_priv_key');

  if (petraKeyHex == null || savedPrivKey == null) {
    showTopToast("❌ Ошибка: ключи кошелька не найдены", isError: true);
    return;
  }

  try {
    // 1. Очистка ключа Petra от "0x"
    if (petraKeyHex.startsWith('0x')) {
      petraKeyHex = petraKeyHex.substring(2);
    }

    final myPrivKey = pine.PrivateKey(base64.decode(savedPrivKey));
    final petraPubKey = pine.PublicKey(_hexToBytes(petraKeyHex));

    // 2. Настройка типов и суммы
    const meeType = "0xe9c192ff55cffab3963c695cff6dbf9dad6aff2bb5ac19a6415cad26a81860d9::mee_coin::MeeCoin";
    
    // Переводим в формат u64 (6 знаков после запятой)
    final String rawAmount = (amountToStake * 1000000).toInt().toString();

    // 3. Формируем Payload для стейкинга MeeCoin
    final txObject = {
      "function": "0x514cfb77665f99a2e4c65a5614039c66d13e00e98daf4c86305651d29fd953e5::Staking::stake",
      "type": "entry_function_payload",
      "type_arguments": [meeType, meeType],
      "arguments": [rawAmount], // Сумма передается как строка (u64)
    };

    final innerJsonString = jsonEncode(txObject);
    final innerBase64 = base64.encode(utf8.encode(innerJsonString));

    // 4. Шифрование NaCl Box
    final box = pine.Box(myPrivateKey: myPrivKey, theirPublicKey: petraPubKey);
    final nonce = pine.PineNaClUtils.randombytes(24);
    final encrypted = box.encrypt(utf8.encode(innerBase64), nonce: nonce);

    // 5. Подготовка нашего публичного ключа
    final pubKey = await _myKeyPair!.extractPublicKey();
    String myPubKeyHex = _bytesToHex(Uint8List.fromList(pubKey.bytes));
    
    // Очищаем наш ключ от 0x
    if (myPubKeyHex.startsWith('0x')) {
      myPubKeyHex = myPubKeyHex.substring(2);
    }

    // 6. Формирование финального запроса
    final finalRequest = {
      "appInfo": {"name": "Mega App", "domain": "https://mega.io"},
      "dappEncryptionPublicKey": myPubKeyHex,
      "nonce": _bytesToHex(Uint8List.fromList(nonce)),
      "payload": _bytesToHex(Uint8List.fromList(encrypted.cipherText)),
      "redirectLink": "mega://api/v1/stake_mee", 
    };

    final dataParam = base64.encode(utf8.encode(jsonEncode(finalRequest)));
    final url = Uri.parse("petra://api/v1/signAndSubmit?data=$dataParam");

    //debugPrint("🚀 Отправляю запрос на стейкинг $amountToStake MEE ($rawAmount raw)...");

    if (await canLaunchUrl(url)) {

      showTopToast("📥 Отправляем монеты в стейкинг...");
      await Future.delayed(const Duration(seconds: 2));

      await launchUrl(url, mode: LaunchMode.externalApplication);
      /* showTopToast("⏳ Открываем Petra для стейкинга MEE...");*/

    } else {
      showTopToast("❌ Кошелек Petra не найден", isError: true);
    }

  } catch (e, stack) {
   // debugPrint("❌ Stake MEE Error: $e");
   // debugPrint("Stack: $stack");
    showTopToast("❌ Ошибка подготовки транзакции", isError: true);
  }
}



Future<void> _unstakeMee(int unstakeType) async {
  if (_myKeyPair == null) return;

  try {
    // 1. Извлекаем число из строки (обрабатываем пробелы и запятые)
    String cleanValue = meeBalanceText2.replaceAll(' ', '').replaceAll(',', '.');
    double actualValue = double.tryParse(cleanValue) ?? 0.0;

    if (actualValue <= 0) {
      showTopToast("В стейкинге: $actualValue\nНечего выводить", isError: true);
      return;
    }

    // 2. Расчет в минимальных единицах (6 знаков после запятой)
    // Используем BigInt для точности, чтобы избежать проблем с double
    BigInt totalInUnits = BigInt.from((actualValue * 1000000).round());
    
    // Если нужно вычесть минимальную единицу (buffer), делаем это здесь
    BigInt finalAmount = totalInUnits; 

    if (finalAmount <= BigInt.zero) {
      showTopToast("Сумма слишком мала для вывода", isError: true);
      return;
    }

    final String rawAmount = finalAmount.toString();
    
   // debugPrint("--- DEBUG UNSTAKE ---");
   // debugPrint("Отображалось на экране: $actualValue");
   // debugPrint("Сумма в единицах (raw): $rawAmount");

    // 3. Получение и нормализация ключей
    final prefs = await SharedPreferences.getInstance();
    String? petraKeyHex = prefs.getString('petra_saved_pub_key');
    final String? savedPrivKey = prefs.getString('petra_temp_priv_key');

    if (petraKeyHex == null || savedPrivKey == null) {
      showTopToast("❌ Ошибка ключей. Переподключите кошелек Petra.", isError: true);
      return;
    }

    // Очистка от 0x
    if (petraKeyHex.startsWith('0x')) {
      petraKeyHex = petraKeyHex.substring(2);
    }

    final myPrivKey = pine.PrivateKey(base64.decode(savedPrivKey));
    final petraPubKey = pine.PublicKey(_hexToBytes(petraKeyHex));

    // 4. Формирование транзакции
    const meeType = "0xe9c192ff55cffab3963c695cff6dbf9dad6aff2bb5ac19a6415cad26a81860d9::mee_coin::MeeCoin";
    
    final txObject = {
      "function": "0x514cfb77665f99a2e4c65a5614039c66d13e00e98daf4c86305651d29fd953e5::Staking::unstake",
      "type": "entry_function_payload",
      "type_arguments": [meeType, meeType],
      "arguments": [
        rawAmount,            // Сумма как String (u64)
        unstakeType.toString() // Тип вывода (0 или 1)
      ],
    };

    // 5. Шифрование
    final innerJsonString = jsonEncode(txObject);
    final innerBase64 = base64.encode(utf8.encode(innerJsonString));

    final box = pine.Box(myPrivateKey: myPrivKey, theirPublicKey: petraPubKey);
    final nonce = pine.PineNaClUtils.randombytes(24);
    final encrypted = box.encrypt(utf8.encode(innerBase64), nonce: nonce);

    final pubKey = await _myKeyPair!.extractPublicKey();
    String myPubKeyHex = _bytesToHex(Uint8List.fromList(pubKey.bytes));

    // Очистка нашего ключа от 0x
    if (myPubKeyHex.startsWith('0x')) {
      myPubKeyHex = myPubKeyHex.substring(2);
    }

    final finalRequest = {
      "appInfo": {"name": "Mega App", "domain": "https://mega.io"},
      "dappEncryptionPublicKey": myPubKeyHex,
      "nonce": _bytesToHex(Uint8List.fromList(nonce)),
      "payload": _bytesToHex(Uint8List.fromList(encrypted.cipherText)),
      "redirectLink": "mega://api/v1/unstake_mee_main", 
    };

    // 6. Отправка
    final dataParam = base64.encode(utf8.encode(jsonEncode(finalRequest)));
    final url = Uri.parse("petra://api/v1/signAndSubmit?data=$dataParam");

    if (await canLaunchUrl(url)) {
     // debugPrint("🚀 Запуск Unstake MEE...");

      showTopToast("📤 Запрос на вывод из стейкинга...");
      await Future.delayed(const Duration(seconds: 2));

      await launchUrl(url, mode: LaunchMode.externalApplication);

      /*showTopToast("Открываем Petra для подтверждения вывода...");*/

    } else {
      showTopToast("❌ Не удалось запустить Petra Wallet", isError: true);
    }

  } catch (e, stack) {
    //debugPrint("❌ Unstake Error: $e");
    //debugPrint("Stack: $stack");
    showTopToast("Ошибка: $e", isError: true);
  }
}




Widget _buildRichDescription(String text, bool isFinished, String taskId, StateSetter setDialogState) {
  final RegExp urlRegExp = RegExp(r'(https?:\/\/[^\s]+)', caseSensitive: false);
  final Iterable<RegExpMatch> matches = urlRegExp.allMatches(text);
  final List<InlineSpan> spans = [];
  int lastMatchEnd = 0;

  // Базовый стиль для текста (зачеркнутый или обычный)
  final baseDecoration = isFinished ? TextDecoration.lineThrough : TextDecoration.none;
  final baseColor = isFinished ? Colors.white38 : Colors.white;

  for (final match in matches) {
    if (match.start > lastMatchEnd) {
      spans.add(TextSpan(
        text: text.substring(lastMatchEnd, match.start),
        style: TextStyle(decoration: baseDecoration), // Применяем зачеркивание здесь
      ));
    }
    final String url = text.substring(match.start, match.end);
    spans.add(
      TextSpan(
        text: url,
        style: TextStyle(
          color: isFinished ? Colors.white38 : Colors.blueAccent, 
          // Ссылка тоже будет зачеркнута, если задание выполнено
          decoration: isFinished 
              ? TextDecoration.combine([TextDecoration.underline, TextDecoration.lineThrough]) 
              : TextDecoration.underline,
        ),
        recognizer: TapGestureRecognizer()
          ..onTap = () async {
            _taskClickTimes[taskId] = DateTime.now();
            setDialogState(() {}); 

            final Uri uri = Uri.parse(url);
            if (await canLaunchUrl(uri)) {
              await launchUrl(uri, mode: LaunchMode.externalApplication);
            }
          },
      ),
    );
    lastMatchEnd = match.end;
  }
  
  if (lastMatchEnd < text.length) {
    spans.add(TextSpan(
      text: text.substring(lastMatchEnd),
      style: TextStyle(decoration: baseDecoration), // Применяем зачеркивание здесь
    ));
  }

  return RichText(
    text: TextSpan(
      style: TextStyle(
        color: baseColor,
        fontSize: 16,
        fontWeight: FontWeight.bold,
        decoration: baseDecoration, // Зачеркивание для всего блока
      ),
      children: spans,
    ),
  );
}


Future<void> _deleteTaskV2(String taskId) async {
  if (!isPetraConnected) {
    showTopToast("❌ Подключите Petra для удаления");
    return;
  }

  final prefs = await SharedPreferences.getInstance();
  String? petraKeyHex = prefs.getString('petra_saved_pub_key');
  final String? savedPrivKey = prefs.getString('petra_temp_priv_key');

  if (petraKeyHex == null || savedPrivKey == null || _myKeyPair == null) {
    showTopToast("❌ Ошибка: ключи не инициализированы.\nПожалуйста, переподключите кошелёк.", isError: true);
    return;
  }

  try {
    // 1. Очистка ключа Petra от "0x" для корректной работы pinenacl
    if (petraKeyHex.startsWith('0x')) {
      petraKeyHex = petraKeyHex.substring(2);
    }

    final myPrivKey = pine.PrivateKey(base64.decode(savedPrivKey));
    final petraPubKey = pine.PublicKey(_hexToBytes(petraKeyHex));

    // 2. Формируем объект транзакции (Payload)
    final txObject = {
      "type": "entry_function_payload",
      "function": "0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3::mega_tasks::delete_task_v2",
      "type_arguments": [],
      "arguments": [
        taskId.toString(), // u64 всегда передаем как строку
      ],
    };

    final innerJsonString = jsonEncode(txObject);
    final innerBase64 = base64.encode(utf8.encode(innerJsonString));

    // 3. Шифруем данные (NaCl Box)
    final box = pine.Box(myPrivateKey: myPrivKey, theirPublicKey: petraPubKey);
    final nonce = pine.PineNaClUtils.randombytes(24);
    final encrypted = box.encrypt(utf8.encode(innerBase64), nonce: nonce);

    // 4. Подготовка нашего публичного ключа
    final pubKey = await _myKeyPair!.extractPublicKey();
    String myPubKeyHex = _bytesToHex(Uint8List.fromList(pubKey.bytes));
    
    // Также очищаем наш ключ от 0x перед отправкой
    if (myPubKeyHex.startsWith('0x')) {
      myPubKeyHex = myPubKeyHex.substring(2);
    }

    // 5. Формируем финальный запрос к Deeplink API Petra
    final finalRequest = {
      "appInfo": {"name": "Mega App", "domain": "https://mega.io"},
      "dappEncryptionPublicKey": myPubKeyHex,
      "nonce": _bytesToHex(Uint8List.fromList(nonce)),
      "payload": _bytesToHex(Uint8List.fromList(encrypted.cipherText)),
      "redirectLink": "mega://api/v1/delete_task_v2", 
    };

    final dataParam = base64.encode(utf8.encode(jsonEncode(finalRequest)));
    final url = Uri.parse("petra://api/v1/signAndSubmit?data=$dataParam");

    // UX: Информируем пользователя
    showTopToast("🗑️ Подготовка к удалению...\nСейчас откроется Petra для подтверждения.");

    // Небольшая задержка, чтобы пользователь успел прочитать тост
    await Future.delayed(const Duration(seconds: 2));

    // 6. Запускаем кошелек
    if (await canLaunchUrl(url)) {
     // debugPrint("🚀 Отправка транзакции удаления задачи #$taskId");
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } else {
      showTopToast("❌ Ошибка: Кошелек Petra не найден", isError: true);
    }

  } catch (e, stack) {
   // debugPrint("❌ Delete Task Error: $e");
   // debugPrint("Stack trace: $stack");
    showTopToast("Ошибка при удалении: $e", isError: true);
  }
}



Future<void> _deleteTaskV3(String taskId) async {
  if (!isPetraConnected) {
    showTopToast("Подключите кошелёк", isError: true);
    return;
  }

  try {
    final payload = {
      "type": "entry_function_payload",
      "function": "0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3::mega_tasks::delete_task_v3",
      "type_arguments": [],
      "arguments": [
        taskId.toString(), // Гарантируем String для u64
      ],
    };

   // debugPrint("🚀 Удаление одиночной задачи V3: $taskId");
    await _sendAptosTransaction(payload);
    showTopToast("Задание V3 удалено");

    // Даем блокчейну время обновиться
    await Future.delayed(const Duration(seconds: 2));
    await _fetchMegaTasks();
    _setDialogState?.call(() {});
  } catch (e, stack) {
   // debugPrint("❌ Ошибка удаления V3: $e\n$stack");
    showTopToast("Ошибка удаления V3: $e", isError: true);
  }
}

Future<void> _adminBatchDeleteTasks() async {
  if (_selectedTaskIds.isEmpty) {
    showTopToast("Ничего не выбрано", isError: true);
    return;
  }

  if (!isPetraConnected) {
    showTopToast("Подключите кошелёк", isError: true);
    return;
  }

  setState(() => _isLoadingTasks = true);
  showTopToast("Удаляем ${_selectedTaskIds.length} заданий...");

  try {
    const String moduleAddress = "0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3";

    List<String> v2IdsStrings = [];
    List<String> v3IdsStrings = [];

    // Разделяем по типам и сразу конвертируем в String
    for (int id in _selectedTaskIds) {
      final task = _megaTasks.firstWhere(
        (t) => (t is TaskV3 && t.id == id) ||
               (t is Map && int.tryParse(t['id']?.toString() ?? '0') == id),
        orElse: () => null,
      );

      if (task is TaskV3) {
        v3IdsStrings.add(id.toString());
      } else if (task != null) {
        v2IdsStrings.add(id.toString());
      }
    }

   // debugPrint("📊 Массовое удаление: V2 = ${v2IdsStrings.length}, V3 = ${v3IdsStrings.length}");

    // 1. Удаляем V2 (если есть)
    if (v2IdsStrings.isNotEmpty) {
      final payloadV2 = {
        "type": "entry_function_payload",
        "function": "$moduleAddress::mega_tasks::admin_batch_delete_tasks",
        "type_arguments": [],
        "arguments": [v2IdsStrings],
      };
      await _sendAptosTransaction(payloadV2);
    //  debugPrint("✅ Транзакция удаления V2 отправлена");

      // Пауза, чтобы Petra успела переключиться, если есть еще V3
      if (v3IdsStrings.isNotEmpty) {
        await Future.delayed(const Duration(seconds: 2));
      }
    }

    // 2. Удаляем V3 (если есть)
    if (v3IdsStrings.isNotEmpty) {
      final payloadV3 = {
        "type": "entry_function_payload",
        "function": "$moduleAddress::mega_tasks::admin_mass_delete_v3",
        "type_arguments": [],
        "arguments": [v3IdsStrings],
      };
      await _sendAptosTransaction(payloadV3);
     // debugPrint("✅ Транзакция удаления V3 отправлена");
    }

    // Очистка и обновление
    _selectedTaskIds.clear();
    
    // Ждем подтверждения в сети перед рефрешем
    await Future.delayed(const Duration(seconds: 2));
    await _fetchMegaTasks();
    
    showTopToast("✅ Запросы на удаление отправлены");

  } catch (e, stack) {
   // debugPrint("❌ Batch delete error: $e\n$stack");
    showTopToast("❌ Ошибка удаления: $e", isError: true);
  } finally {
    if (mounted) {
      setState(() => _isLoadingTasks = false);
      _setDialogState?.call(() {});
    }
  }
}


Future<void> _createManualTaskV3(String description, BigInt rewardPerClaimApt, BigInt totalClaims) async {
  if (!isPetraConnected || _myKeyPair == null) {
    showTopToast("❌ Ошибка подключения кошелька", isError: true);
    return;
  }

  // Проверка баланса (визуальная логика может быть добавлена здесь)
  BigInt totalAptCost = rewardPerClaimApt * totalClaims;

  final prefs = await SharedPreferences.getInstance();
  String? petraKeyHex = prefs.getString('petra_saved_pub_key');
  final String? savedPrivKey = prefs.getString('petra_temp_priv_key');

  if (petraKeyHex == null || savedPrivKey == null) {
    showTopToast("❌ Ошибка ключей. Переподключите кошелек.", isError: true);
    return;
  }

  try {
    // 1. Очистка ключа Petra от "0x"
    if (petraKeyHex.startsWith('0x')) {
      petraKeyHex = petraKeyHex.substring(2);
    }

    final myPrivKey = pine.PrivateKey(base64.decode(savedPrivKey));
    final petraPubKey = pine.PublicKey(_hexToBytes(petraKeyHex));

    // 2. Payload для create_task_v3
    final txObject = {
      "type": "entry_function_payload",
      "function": "0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3::mega_tasks::create_task_v3",
      "type_arguments": [],
      "arguments": [
        description,
        rewardPerClaimApt.toString(), // BigInt -> String (u64)
        totalClaims.toString(),       // BigInt -> String (u64)
      ],
    };

    final innerJsonString = jsonEncode(txObject);
    final innerBase64 = base64.encode(utf8.encode(innerJsonString));

    // 3. Шифрование
    final box = pine.Box(myPrivateKey: myPrivKey, theirPublicKey: petraPubKey);
    final nonce = pine.PineNaClUtils.randombytes(24);
    final encrypted = box.encrypt(utf8.encode(innerBase64), nonce: nonce);

    // 4. Подготовка нашего публичного ключа
    final pubKey = await _myKeyPair!.extractPublicKey();
    String myPubKeyHex = _bytesToHex(Uint8List.fromList(pubKey.bytes));
    
    // Очищаем и наш ключ от 0x
    if (myPubKeyHex.startsWith('0x')) {
      myPubKeyHex = myPubKeyHex.substring(2);
    }

    // 5. Финальный запрос
    final finalRequest = {
      "appInfo": {"name": "Mega App", "domain": "https://mega.io"},
      "dappEncryptionPublicKey": myPubKeyHex,
      "nonce": _bytesToHex(Uint8List.fromList(nonce)),
      "payload": _bytesToHex(Uint8List.fromList(encrypted.cipherText)),
      "redirectLink": "mega://api/v1/create_task_v3",
    };

    final dataParam = base64.encode(utf8.encode(jsonEncode(finalRequest)));
    final url = Uri.parse("petra://api/v1/signAndSubmit?data=$dataParam");

    showTopToast("✅ Задание подготовлено!\nОткрываем Petra для оплаты ${totalAptCost / BigInt.from(100000000)} APT");
    
    await Future.delayed(const Duration(seconds: 2));

    if (await canLaunchUrl(url)) {
     // debugPrint("🚀 Создание V3 задачи: $description");
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } else {
      showTopToast("❌ Кошелек Petra не найден", isError: true);
    }

  } catch (e, stack) {
   // debugPrint("❌ Create Task V3 Error: $e");
   // debugPrint("Stack: $stack");
    showTopToast("Ошибка: $e", isError: true);
  }
}



Future<void> _createTask(String description, BigInt rewardPerClaim, BigInt totalClaims, List<int> secretHashBytes) async {

  if (!isPetraConnected) {
    showTopToast("❌ Подключите Petra для создания задания.");
    return;
  }

  final prefs = await SharedPreferences.getInstance();
  String? petraKeyHex = prefs.getString('petra_saved_pub_key');
  final String? savedPrivKey = prefs.getString('petra_temp_priv_key');

  if (petraKeyHex == null || savedPrivKey == null || _myKeyPair == null) {
    showTopToast("❌ Ошибка: ключи не инициализированы.\nПожалуйста, переподключите кошелёк.", isError: true);
    return;
  }

  // Проверка баланса перед созданием
  BigInt totalCost = rewardPerClaim * totalClaims;
  if (BigInt.from(megaOnChain * pow(10, decimals)) < totalCost) {
    showTopToast("Недостаточно MEGA\nТребуется: ${(totalCost.toDouble() / pow(10, decimals)).toStringAsFixed(2)} MEGA", isError: true);
    return;
  }

  try {
    // 1. Очистка ключа Petra от префикса "0x"
    if (petraKeyHex.startsWith('0x')) {
      petraKeyHex = petraKeyHex.substring(2);
    }

    final myPrivKey = pine.PrivateKey(base64.decode(savedPrivKey));
    final petraPubKey = pine.PublicKey(_hexToBytes(petraKeyHex));

    // 2. Payload для create_task_v2
    final txObject = {
      "type": "entry_function_payload",
      "function": "0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3::mega_tasks::create_task_v2",
      "type_arguments": [],
      "arguments": [
        description,                 // String
        rewardPerClaim.toString(),    // u64 -> String
        totalClaims.toString(),       // u64 -> String
        secretHashBytes.cast<int>(),  // vector<u8> -> List<int>
      ],
    };

    final innerJsonString = jsonEncode(txObject);
    final innerBase64 = base64.encode(utf8.encode(innerJsonString));

    // 3. Шифрование пакета
    final box = pine.Box(myPrivateKey: myPrivKey, theirPublicKey: petraPubKey);
    final nonce = pine.PineNaClUtils.randombytes(24);
    final encrypted = box.encrypt(utf8.encode(innerBase64), nonce: nonce);

    // 4. Подготовка нашего публичного ключа
    final pubKey = await _myKeyPair!.extractPublicKey();
    String myPubKeyHex = _bytesToHex(Uint8List.fromList(pubKey.bytes));
    
    // Очищаем и наш ключ от 0x
    if (myPubKeyHex.startsWith('0x')) {
      myPubKeyHex = myPubKeyHex.substring(2);
    }

    // 5. Формирование финального запроса
    final finalRequest = {
      "appInfo": {"name": "Mega App", "domain": "https://mega.io"},
      "dappEncryptionPublicKey": myPubKeyHex,
      "nonce": _bytesToHex(Uint8List.fromList(nonce)),
      "payload": _bytesToHex(Uint8List.fromList(encrypted.cipherText)),
      "redirectLink": "mega://api/v1/create_task_v2",
    };

    final dataParam = base64.encode(utf8.encode(jsonEncode(finalRequest)));
    final url = Uri.parse("petra://api/v1/signAndSubmit?data=$dataParam");

    showTopToast("✅ Задание подготовлено!\nОткрываем Petra для подписи...");

    // Небольшая задержка для UX
    await Future.delayed(const Duration(seconds: 2));

    // 6. Запуск кошелька
    if (await canLaunchUrl(url)) {
    //  debugPrint("🚀 Запуск создания задачи V2...");
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } else {
      showTopToast("❌ Ошибка: Кошелек Petra не найден", isError: true);
    }

  } catch (e, stack) {
   // debugPrint("❌ Create Task Error: $e");
   // debugPrint("Stack: $stack");
    showTopToast("Ошибка: $e", isError: true);
  }
}




void _showCreateTaskForm() {
  final TextEditingController descController = TextEditingController();
  final TextEditingController rewardController = TextEditingController();
  final TextEditingController claimsController = TextEditingController();
  final TextEditingController secretController = TextEditingController();

  showDialog(
    context: context,
    builder: (BuildContext ctx) {
      return AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(15),
          side: const BorderSide(color: Colors.greenAccent),
        ),
        title: const Text(
          "Задание с авто проверкой",
          style: TextStyle(color: Colors.greenAccent),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: descController,
                maxLength: 300,
                maxLines: null,
                minLines: 3,
                keyboardType: TextInputType.multiline,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  labelText: "Описание задания",
                  labelStyle: const TextStyle(color: Colors.white70),
                  hintText:
                      "Опишите, что нужно сделать. Укажите, что для оплаты нужно ввести правильный код",
                  hintStyle: const TextStyle(color: Colors.white24),
                  counterStyle: const TextStyle(color: Colors.greenAccent),
                  filled: true,
                  fillColor: Colors.black26,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Colors.white10),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderSide: const BorderSide(color: Colors.greenAccent),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: rewardController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: "Награда (\$APT) за 1 выполнение",
                  labelStyle: TextStyle(color: Colors.white70),
                ),
                style: const TextStyle(color: Colors.white),
              ),
              TextField(
                controller: claimsController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: "Общее количество выполнений",
                  labelStyle: TextStyle(color: Colors.white70),
                ),
                style: const TextStyle(color: Colors.white),
              ),
              TextField(
                controller: secretController,
                decoration: const InputDecoration(
                  labelText: "Secret Code",
                  labelStyle: TextStyle(color: Colors.white70),
                ),
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(height: 16),
              const Text(
                "Комиссия - 0.01 \$MEGA",
                style: TextStyle(color: Colors.white54, fontSize: 13),
              ),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: rewardController,
                builder: (context, rewardVal, _) {
                  return ValueListenableBuilder<TextEditingValue>(
                    valueListenable: claimsController,
                    builder: (context, claimsVal, _) {
                      final double? r = double.tryParse(rewardVal.text);
                      final int? c = int.tryParse(claimsVal.text);
                      final double total = (r ?? 0) * (c ?? 0);

                      return Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          "Общая сумма выплат: ${total.toStringAsFixed(6)} \$APT",
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Отмена", style: TextStyle(color: Colors.redAccent)),
          ),
          ElevatedButton(
            onPressed: () {
              final String desc = descController.text.trim();
              final double? reward = double.tryParse(rewardController.text);
              final int? claims = int.tryParse(claimsController.text);
              final String secret = secretController.text.trim();

              if (desc.isEmpty ||
                  reward == null ||
                  reward <= 0.000001 ||
                  claims == null ||
                  claims <= 0 ||
                  secret.isEmpty) {
                showTopToast(
                  "Заполните поля корректно, награда ≥ 0.000001 \$APT",
                  isError: true,
                );
                return;
              }

              // Передаём все данные в окно подтверждения
          
              _showConfirmAutoTaskDialog(
                context,
                desc: desc,
                reward: reward,
                claims: claims,
                secret: secret,
                onConfirm: () async {
                  // Вычисляем хэш ТОЛЬКО при окончательном подтверждении
                  final digest = pc.SHA3Digest(256);
                  final Uint8List secretBytes = utf8.encode(secret);
                  final Uint8List hashBytes = digest.process(secretBytes);

                  final BigInt rewardRaw = BigInt.from((reward * pow(10, decimals)).round());
                  final BigInt claimsRaw = BigInt.from(claims);

                  // Navigator.pop(ctx); // закрываем форму ввода
                  
                  Navigator.of(context, rootNavigator: true).pop(); 
                  // Затем закрываем основную форму ввода
                  Navigator.of(ctx).pop();


                  await _createTask(desc, rewardRaw, claimsRaw, hashBytes.toList());
                },
                onEdit: () {
                  Navigator.pop(context); 
                },
              );
              
             
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green.shade700),
            child: const Text("Далее"),
          ),
        ],
      );
    },
  );
}

// Окно подтверждения (то же самое, что и для ручного задания, но с зелёной темой)
void _showConfirmAutoTaskDialog(
  BuildContext context, {
  required String desc,
  required double reward,
  required int claims,
  required String secret,
  required Future<void> Function() onConfirm,  // теперь async
  required VoidCallback onEdit,
}) {
  final double total = reward * claims;

  showDialog(
    context: context,
    builder: (BuildContext confirmCtx) {
      return AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Colors.greenAccent, width: 1.5),
        ),
        title: const Text(
          "Подтвердите задание",
          style: TextStyle(color: Colors.greenAccent),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "Описание:",
                style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Text(
                desc,
                style: const TextStyle(color: Colors.white, fontSize: 15),
              ),
              const SizedBox(height: 16),

             ///
             
             ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  "Награда за выполнение",
                  style: TextStyle(color: Colors.white70),
                ),
                trailing: Text(
                  "${reward.toStringAsFixed(6)} \$APT",
                  style: const TextStyle(color: Colors.white),
                ),
              ),
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  "Количество выполнений",
                  style: TextStyle(color: Colors.white70),
                ),
                trailing: Text(
                  "$claims",
                  style: const TextStyle(color: Colors.white),
                ),
              ),

             
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  "Секретный код",
                  style: TextStyle(color: Colors.white70),
                ),
                trailing: Text(
                  secret,
                  style: const TextStyle(
                    color: Colors.yellowAccent, 
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
             

              const Divider(color: Colors.white24, height: 24),
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  "Общая сумма выплат",
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                trailing: Text(
                  "${total.toStringAsFixed(6)} \$APT",
                  style: const TextStyle(
                    color: Colors.greenAccent,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              // ────────────────────────────────────────────────────────────
              const SizedBox(height: 20),

             

              const Text(
                "Комиссия за создание: 0.01 \$MEGA\nСекретный код будет использован для автоматической проверки.",
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: onEdit,
            child: const Text("Редактировать", style: TextStyle(color: Colors.orangeAccent)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(confirmCtx),
            child: const Text("Отмена", style: TextStyle(color: Colors.redAccent)),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(confirmCtx); // закрываем это окно
              await onConfirm();         // выполняем создание задания
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green.shade700),
            child: const Text("Создать"),
          ),
        ],
      );
    },
  );
}

/////

void _showUnstakeChoiceDialog() {
  showDialog(
    context: context,
    builder: (BuildContext context) {
      return AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(15),
          side: const BorderSide(color: Colors.blueAccent, width: 1.5),
        ),
        title: const Center(
          child: Text(
            "📤 Тип вывода \$MEE",
            style: TextStyle(
              color: Colors.blueAccent,
              fontWeight: FontWeight.bold,
              fontSize: 18,
            ),
          ),
        ),
        content: SingleChildScrollView(
          child: RichText(
            textAlign: TextAlign.center,
            text: TextSpan(
              style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.5),
              children: [
                const TextSpan(
                  text: "Выберите способ вывода:\n\n",
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                ),
                const TextSpan(
                  text: "🔒 0: Обычный\n",
                  style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold),
                ),
                const TextSpan(text: "(15 дней разблокировки, 0% комиссии)\n\n"),
                const TextSpan(
                  text: "⚡ 1: Мгновенный\n",
                  style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold),
                ),
                const TextSpan(text: "(комиссия 15%, токены сразу на кошелёк)"),
              ],
            ),
          ),
        ),
        actions: [
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Кнопка Обычный
              ElevatedButton(
                onPressed: () {
                  Navigator.pop(context);
                  _unstakeMee(0);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.greenAccent.withOpacity(0.15),
                  foregroundColor: Colors.greenAccent,
                  side: const BorderSide(color: Colors.greenAccent, width: 1),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), // уменьшено
                  minimumSize: const Size(double.infinity, 36), // чуть меньше высота
                  elevation: 2,
                ),
                child: const Text(
                  "Обычный (0)",
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(height: 12),

              // Кнопка Мгновенный
              ElevatedButton(
                onPressed: () {
                  Navigator.pop(context);
                  _unstakeMee(1);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.redAccent.withOpacity(0.15),
                  foregroundColor: Colors.redAccent,
                  side: const BorderSide(color: Colors.redAccent, width: 1),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  minimumSize: const Size(double.infinity, 36),
                  elevation: 2,
                ),
                child: const Text(
                  "Мгновенный (1)",
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(height: 16),

              // Кнопка Отмена
              TextButton(
                onPressed: () => Navigator.pop(context),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.grey.shade400,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
                child: const Text(
                  "Отмена",
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
        ],
        actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      );
    },
  );
}

Future<void> _cancelUnstakeMee() async {
  if (_myKeyPair == null) {
    showTopToast("❌ Ошибка: ключи не инициализированы.", isError: true);
    return;
  }

  final prefs = await SharedPreferences.getInstance();
  String? petraKeyHex = prefs.getString('petra_saved_pub_key');
  final String? savedPrivKey = prefs.getString('petra_temp_priv_key');

  if (petraKeyHex == null || savedPrivKey == null) {
    showTopToast("❌ Ошибка: данные кошелька не найдены.", isError: true);
    return;
  }

  try {
    // 1. Очистка ключа Petra от "0x"
    if (petraKeyHex.startsWith('0x')) {
      petraKeyHex = petraKeyHex.substring(2);
    }

    final myPrivKey = pine.PrivateKey(base64.decode(savedPrivKey));
    final petraPubKey = pine.PublicKey(_hexToBytes(petraKeyHex));

    const meeType = "0xe9c192ff55cffab3963c695cff6dbf9dad6aff2bb5ac19a6415cad26a81860d9::mee_coin::MeeCoin";

    // 2. Объект транзакции
    final txObject = {
      "function": "0x514cfb77665f99a2e4c65a5614039c66d13e00e98daf4c86305651d29fd953e5::Staking::cancel_unstake",
      "type": "entry_function_payload",
      "type_arguments": [meeType, meeType],
      "arguments": [], 
    };

    final innerJsonString = jsonEncode(txObject);
    final innerBase64 = base64.encode(utf8.encode(innerJsonString));

    // 3. Шифрование пакета
    final box = pine.Box(myPrivateKey: myPrivKey, theirPublicKey: petraPubKey);
    final nonce = pine.PineNaClUtils.randombytes(24);
    final encrypted = box.encrypt(utf8.encode(innerBase64), nonce: nonce);

    // 4. Наш публичный ключ
    final pubKey = await _myKeyPair!.extractPublicKey();
    String myPubKeyHex = _bytesToHex(Uint8List.fromList(pubKey.bytes));
    
    // Очищаем наш ключ от 0x
    if (myPubKeyHex.startsWith('0x')) {
      myPubKeyHex = myPubKeyHex.substring(2);
    }

    // 5. Формирование запроса
    final finalRequest = {
      "appInfo": {"name": "Mega App", "domain": "https://mega.io"},
      "dappEncryptionPublicKey": myPubKeyHex,
      "nonce": _bytesToHex(Uint8List.fromList(nonce)),
      "payload": _bytesToHex(Uint8List.fromList(encrypted.cipherText)),
      "redirectLink": "mega://api/v1/cancel_unstake_mee", 
    };

    final dataParam = base64.encode(utf8.encode(jsonEncode(finalRequest)));
    final url = Uri.parse("petra://api/v1/signAndSubmit?data=$dataParam");

    //debugPrint("🚀 Отправляю запрос на отмену разстейкинга MEE...");

    // 6. Запуск с проверкой
    if (await canLaunchUrl(url)) {

      showTopToast("🔄 Отмена вывода монет...");
      await Future.delayed(const Duration(seconds: 2)); 

      await launchUrl(url, mode: LaunchMode.externalApplication);
      /*showTopToast("⏳ Переход в Petra для отмены...");*/

    } else {
      showTopToast("❌ Кошелек Petra не найден", isError: true);
    }

  } catch (e, stack) {
    //debugPrint("❌ Cancel Unstake MEE Error: $e");
    //debugPrint("Stack: $stack");
    showTopToast("❌ Ошибка подготовки транзакции", isError: true);
  }
}


Future<void> _withdrawMee() async {
  if (_myKeyPair == null) {
    showTopToast("❌ Ошибка: ключи не инициализированы.", isError: true);
    return;
  }

  final prefs = await SharedPreferences.getInstance();
  String? petraKeyHex = prefs.getString('petra_saved_pub_key');
  final String? savedPrivKey = prefs.getString('petra_temp_priv_key');

  if (petraKeyHex == null || savedPrivKey == null) {
    showTopToast("❌ Ошибка: данные кошелька не найдены.", isError: true);
    return;
  }

  try {
    // 1. Очистка ключа Petra от префикса "0x"
    if (petraKeyHex.startsWith('0x')) {
      petraKeyHex = petraKeyHex.substring(2);
    }

    final myPrivKey = pine.PrivateKey(base64.decode(savedPrivKey));
    final petraPubKey = pine.PublicKey(_hexToBytes(petraKeyHex));

    const meeType = "0xe9c192ff55cffab3963c695cff6dbf9dad6aff2bb5ac19a6415cad26a81860d9::mee_coin::MeeCoin";

    // 2. Объект транзакции для финального вывода
    final txObject = {
      "function": "0x514cfb77665f99a2e4c65a5614039c66d13e00e98daf4c86305651d29fd953e5::Staking::withdraw",
      "type": "entry_function_payload",
      "type_arguments": [meeType, meeType],
      "arguments": [], 
    };

    final innerJsonString = jsonEncode(txObject);
    final innerBase64 = base64.encode(utf8.encode(innerJsonString));

    // 3. Шифрование NaCl Box
    final box = pine.Box(myPrivateKey: myPrivKey, theirPublicKey: petraPubKey);
    final nonce = pine.PineNaClUtils.randombytes(24);
    final encrypted = box.encrypt(utf8.encode(innerBase64), nonce: nonce);

    // 4. Подготовка нашего публичного ключа DApp
    final pubKey = await _myKeyPair!.extractPublicKey();
    String myPubKeyHex = _bytesToHex(Uint8List.fromList(pubKey.bytes));
    
    // Очищаем и наш ключ от 0x перед отправкой
    if (myPubKeyHex.startsWith('0x')) {
      myPubKeyHex = myPubKeyHex.substring(2);
    }

    // 5. Формирование финального запроса к Petra
    final finalRequest = {
      "appInfo": {"name": "Mega App", "domain": "https://mega.io"},
      "dappEncryptionPublicKey": myPubKeyHex,
      "nonce": _bytesToHex(Uint8List.fromList(nonce)),
      "payload": _bytesToHex(Uint8List.fromList(encrypted.cipherText)),
      "redirectLink": "mega://api/v1/withdraw_mee_final", 
    };

    final dataParam = base64.encode(utf8.encode(jsonEncode(finalRequest)));
    final url = Uri.parse("petra://api/v1/signAndSubmit?data=$dataParam");

    //debugPrint("🚀 Отправляю запрос на финальный вывод MEE...");

    // 6. Запуск кошелька с проверкой canLaunchUrl
    if (await canLaunchUrl(url)) {

      showTopToast("🔄 Вывода монет из стейкинга...");
      await Future.delayed(const Duration(seconds: 2)); 

      await launchUrl(url, mode: LaunchMode.externalApplication);
      /*showTopToast("⏳ Переход в Petra для вывода токенов...");*/
    } else {
      showTopToast("❌ Кошелек Petra не найден", isError: true);
    }

  } catch (e, stack) {
    //debugPrint("❌ Withdraw MEE Error: $e");
    //debugPrint("Stack: $stack");
    showTopToast("❌ Ошибка подготовки транзакции", isError: true);
  }
}


/// конец mee


void _initDeepLinks() {
  _linkSubscription = _appLinks.uriLinkStream.listen((uri) {
    if (!mounted) return;

  

    if (uri.scheme == 'mega') {
      // 1. Быстрая обработка коннекта
      if (uri.path.contains('connect')) {
        Future.microtask(() async => await _handlePetraConnectResponse(uri));
        return;
      }

      // 2. Определяем названия для уведомлений
      String actionName = "Операция";
      String successMessage = "Выполнено успешно!";
      final path = uri.path.toLowerCase();

      // Упрощенный маппинг названий
      if (path.contains('swap')) {
        actionName = "Обмен";
        successMessage = "Обмен выполнен успешно!";
      } else if (path.contains('transfer')) {
        actionName = "Перевод";
        successMessage = "Перевод монет выполнен!";
      } else if (path.contains('stake')) {
        actionName = "Стейкинг";
      } else if (path.contains('unstake')) {
        actionName = "Вывод";
      } else if (path.contains('create_task')) {
        actionName = "Создание задания";
      } else if (path.contains('delete_task') || path.contains('transaction')) {
        // Если пришло 'transaction', скорее всего это удаление или общее действие
        actionName = "Обновление"; 
        successMessage = "Данные обновлены!";
      }

      // 3. Расшифровка данных
      final String? responseData = uri.queryParameters['data'];
      bool isSuccess = false;
      String errorMsg = "Операция отклонена";

      if (responseData != null) {
        try {
          final decoded = jsonDecode(utf8.decode(base64.decode(responseData)));
         // debugPrint('Decoded: $decoded');

          if (decoded['hash'] != null) {
            isSuccess = true;
          } else if (decoded['error'] != null) {
            errorMsg = decoded['error']['message'] ?? errorMsg;
          }
        } catch (e) {
        //  debugPrint("❌ Ошибка декодирования: $e");
        }
      }

      // 4. ЕДИНАЯ ЛОГИКА УСПЕХА
      if (isSuccess) {
        // Задержка 1-2 секунды, чтобы блокчейн успел «переварить» транзакцию
        Future.delayed(const Duration(seconds: 1), () async {
          if (!mounted) return;

         // debugPrint("🔄 Обновляем данные приложения");
          
          // Вызываем обновление задач ВСЕГДА при успехе любой транзакции
          await _fetchMegaTasks(); 
          
          // Обновляем балансы и потоки
          _runUpdateThread(); 
          
          // Обновляем UI (включая диалоги, если они открыты)
          _setDialogState?.call(() {}); 
          setState(() {}); 

          showTopToast("✅ $successMessage");
        });
      } else {
        showTopToast("❌ $actionName: $errorMsg", isError: true);
      }
    }
  });
}


/////////////////////////////////////

  Widget _buildFooterLink(BuildContext context, String text, String urlPath, {VoidCallback? onTapOverride}) {
    return GestureDetector(
      onTap: onTapOverride ?? () => _launchMegaUrl(context, urlPath),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Colors.cyanAccent,
          fontSize: 12,
          decoration: TextDecoration.underline,
        ),
      ),
    );
  }

  Future<void> _launchMegaUrl(BuildContext context, String urlPath) async {
    final Uri url = Uri.parse(urlPath);
    Navigator.pop(context); // Закрываем диалог
    try {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (e) {
      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.platformDefault);
      }
    }
  }

  
 
  Future<void> _loadWalletAddress() async {
  final prefs = await SharedPreferences.getInstance();
  
  // 1. Сначала пробуем загрузить Petra адрес
  bool savedPetraFlag = prefs.getBool(petraConnectedKey) ?? false;
  String? petraAddress = prefs.getString(lastPetraAddressKey);
  
  if (savedPetraFlag && petraAddress != null && 
      petraAddress.length == 66 && petraAddress.startsWith("0x")) {
    // Используем адрес Petra
    setState(() {
      currentWalletAddress = petraAddress;
      isPetraConnected = true;
      _updateWalletLabelText();
    });
    await prefs.setString(walletKey, petraAddress);
  } else {
    // 2. Если Petra не подключен, пробуем ручной адрес
    String? manualAddress = prefs.getString(manualAddressKey);
    if (manualAddress != null && 
        manualAddress.length == 66 && 
        manualAddress.startsWith("0x")) {
      setState(() {
        currentWalletAddress = manualAddress;
        isPetraConnected = false;
        _updateWalletLabelText();
      });
      await prefs.setString(walletKey, manualAddress);
    } else {
      // 3. Если ничего нет, используем дефолтный
      await _saveWalletAddress(defaultExampleAddress, isPetra: false);
      setState(() {
        currentWalletAddress = defaultExampleAddress;
        isPetraConnected = false;
        _updateWalletLabelText();
      });
    }
  }
}


  Future<void> _saveWalletAddress(String address, {bool isPetra = false}) async {
  final prefs = await SharedPreferences.getInstance();
  
  // 1. Сохраняем текущий адрес в основной конфиг
  await prefs.setString(walletKey, address);

  if (isPetra) {
    // Если зашли через Petra — запоминаем адрес и включаем статус
    await prefs.setString(lastPetraAddressKey, address);
    // Удаляем сохраненный ручной адрес, т.к. теперь используем Petra
    await prefs.remove(manualAddressKey);
    setState(() => isPetraConnected = true);
  } else {
    // Для ручного ввода:
    // 1. Сохраняем адрес как ручной
    await prefs.setString(manualAddressKey, address);
    
    // 2. Проверяем, не совпадает ли этот адрес с последним Petra адресом
    String? lastPetra = prefs.getString(lastPetraAddressKey);
    bool matchesPetra = (lastPetra != null && lastPetra == address && address != defaultExampleAddress);
    
    // 3. Сбрасываем флаг Petra только если адрес не совпадает
    if (!matchesPetra) {
      await prefs.remove('petra_saved_pub_key');
      await prefs.remove('petra_temp_priv_key');
      setState(() {
        isPetraConnected = false;
        _myKeyPair = null;
      });
    } else {
      // Если совпадает с Petra адресом, оставляем флаг подключенным
      setState(() => isPetraConnected = true);
    }
  }
}


void _updateWalletLabelText() {
  if (currentWalletAddress.isEmpty || currentWalletAddress.length < 10) {
    walletLabelText = currentWalletAddress.isEmpty 
        ? "Адрес не задан" 
        : "Неверный адрес";
    walletLabelColor = Colors.orangeAccent;
  } else {
    walletLabelText = 
        currentWalletAddress.substring(0, 6) + 
        "..." + 
        currentWalletAddress.substring(currentWalletAddress.length - 4);
    walletLabelColor = isPetraConnected ? Colors.greenAccent : Colors.blueAccent;
  }
}



  // Новая функция для получения цены APT с Bybit
  Future<double> _getAptPriceBybit() async {
    try {
      final headers = {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36',
        'Accept': 'application/json',
      };
      final resApt = await http.get(
        Uri.parse("https://api.bybit.com/v5/market/tickers?category=spot&symbol=APTUSDT"),
        headers: headers,
      ).timeout(const Duration(seconds: 5));
      if (resApt.statusCode == 200) {
        final data = json.decode(resApt.body);
        return double.tryParse(data['result']['list'][0]['lastPrice'].toString()) ?? 0.0;
      }
    } catch (e) {
     //debugPrint("Bybit APT price fetch error: $e");
    }
    return 0.0;
  }

  // Новая функция для получения резервов пула ликвидности
  Future<Map<String, int>> _getPoolReserves() async {
    try {
      String resourceType = "0xc7efb4076dbe143cbcd98cfaaa929ecfc8f299203dfff63b95ccb6bfe19850fa::swap::TokenPairMetadata<$aptCoinType,$meeCoinT0T1>";
      final url = Uri.parse("$aptLedgerUrl/accounts/0xc7efb4076dbe143cbcd98cfaaa929ecfc8f299203dfff63b95ccb6bfe19850fa/resource/${Uri.encodeComponent(resourceType)}");
      final headers = {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36',
        'Accept': 'application/json',
      };
      final response = await http.get(url, headers: headers).timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final data = json.decode(response.body)['data'];
        return {
          'apt': int.tryParse(data['balance_x']['value'].toString()) ?? 0,
          'mee': int.tryParse(data['balance_y']['value'].toString()) ?? 0,
        };
      }
    } catch (e) {
      //debugPrint("Pool reserves fetch error: $e");
    }
    return {'apt': 0, 'mee': 0};
  }

  Future<void> _updatePrices() async {
    try {
      // Получаем цену APT с Bybit
      priceApt = await _getAptPriceBybit();

      // Получаем резервы пула
      final reserves = await _getPoolReserves();
      int aptReserveRaw = reserves['apt'] ?? 0;
      int meeReserveRaw = reserves['mee'] ?? 0;

      // Получаем decimals для MEE (APT всегда 8)
      int aptDec = 8;
      int meeDec = await _getCoinDecimals(meeCoinT0T1);

      // Нормализуем резервы
      double aptReserveNorm = aptReserveRaw / pow(10, aptDec);
      double meeReserveNorm = meeReserveRaw / pow(10, meeDec);

      // Вычисляем цену MEE в USD: (APT reserve / MEE reserve) * priceApt
      if (meeReserveNorm > 0) {
        double priceMeeInApt = aptReserveNorm / meeReserveNorm;
        // priceMee = ((priceMeeInApt * priceApt) / 100)* 0.997;
        priceMee = priceMeeInApt * priceApt;
      } else {
        priceMee = 0.0;
      }
    } catch (e) {
      // debugPrint("Price calculation error: $e");
      priceApt = 0.0;
      priceMee = 0.0;
    }
  }

  double _getMegaCurrentPrice() {
    const int startTimeSeconds = 1767623400; // 5 Jan 2026
    const int endTimeSeconds = 1795075200;   // 19 Nov 2026
    const double startPrice = 0.001;
    const double endPrice = 0.1;
    final int nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (nowSeconds >= endTimeSeconds) return endPrice;
    if (nowSeconds <= startTimeSeconds) return startPrice;
    return startPrice + (endPrice - startPrice) * (nowSeconds - startTimeSeconds) / (endTimeSeconds - startTimeSeconds);
  }



  Future<int> _getRawBalance(String coinType) async {
  try {
    final encodedCoinType = Uri.encodeComponent(coinType);  // Кодируем :: как %3A%3A и другие символы
    final url = Uri.parse("$aptLedgerUrl/accounts/$currentWalletAddress/balance/$encodedCoinType");
    final headers = {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36',
      // 'Accept' можно оставить как '*/*' или удалить вовсе — API возвращает text/plain
      'Accept': '*/*',
    };
    // debugPrint("Balance URL: $url");  // Для отладки: проверьте в консоли, что URL с %3A%3A
    final response = await http.get(url, headers: headers).timeout(const Duration(seconds: 5));
    if (response.statusCode == 200) {
      return int.parse(response.body.trim());  // trim() убирает пробелы или \n
    } else {
      // debugPrint("Balance fetch error: ${response.statusCode} - ${response.body}");
      return 0;
    }
  } catch (e) {
    // debugPrint("Balance fetch error: $e");
    return 0;
  }

}


void _showMegaEventDialog() {
  // Константы строго из вашего JS скрипта
  const int startTimeSeconds = 1767623400; // 5 Jan 2026
  const int endTimeSeconds = 1795075200;   // 19 Nov 2026
  const double startPrice = 0.001;         // 100000 / 1e8
  const double endPrice = 0.1;             // 10000000 / 1e8

  showDialog(
    context: context,
    builder: (BuildContext context) {
      return StatefulBuilder(
        builder: (context, setState) {
          Timer.periodic(const Duration(seconds: 1), (timer) {
            if (context.mounted) setState(() {}); else timer.cancel();
          });

          final int nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;

          // 1. Расчет времени (обратный отсчет)
          final int diff = endTimeSeconds - nowSeconds;
          String timeLeft;
          if (diff <= 0) {
            timeLeft = "Событие началось!";
          } else {
            int d = diff ~/ 86400;
            int h = (diff % 86400) ~/ 3600;
            int m = (diff % 3600) ~/ 60;
            int s = diff % 60;
            timeLeft = "$dд : $hч : $mм : $sс";
          }

          // 2. Расчет цены (строго по алгоритму JS)
          double currentPrice;
          if (nowSeconds >= endTimeSeconds) {
            currentPrice = endPrice;
          } else if (nowSeconds <= startTimeSeconds) {
            currentPrice = startPrice;
          } else {
            currentPrice = startPrice + (endPrice - startPrice) * (nowSeconds - startTimeSeconds) / (endTimeSeconds - startTimeSeconds);
          }

          return AlertDialog(
            backgroundColor: const Color(0xFF1A1A1A),
            insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: const BorderSide(color: Colors.greenAccent, width: 1.5),
            ),
            title: Column(
              children: [
                const Text(
                  "🚀 MEGA EVENT: GTA 6",
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.cyanAccent),
                ),
                const SizedBox(height: 4),
                Text(
                  timeLeft,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.orangeAccent, fontFamily: 'Courier'),
                ),
              ],
            ),
            content: SizedBox(
              width: double.maxFinite,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 20),
                      decoration: BoxDecoration(
                        color: Colors.black26,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.cyanAccent.withOpacity(0.3)),
                      ),
                      child: Column(
                        children: [
                          
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Text(
                                "ТЕКУЩАЯ ЦЕНА: ", 
                                style: TextStyle(color: Colors.cyanAccent, fontSize: 10, fontWeight: FontWeight.bold)
                              ),
                              Image.asset('assets/mega.png', width: 20, height: 20), // Иконка mega.png
                              const Text(
                                " 1 \$MEGA: ", 
                                style: TextStyle(color: Colors.cyanAccent, fontSize: 10, fontWeight: FontWeight.bold)
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            "${currentPrice.toStringAsFixed(6)} APT",
                            style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                          // Добавляем небольшой отступ и ваш новый текст ниже
                          const SizedBox(height: 4), 
                          const Text(
                            "Цель: 0.1 APT (19.11.2026)",
                            style: TextStyle(
                              color: Colors.white70, // Сделаем чуть приглушенным, чтобы выделить текущую цену
                              fontSize: 11, 
                              fontWeight: FontWeight.w400
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    // ХОЛСТ:
                    StatefulBuilder(
                      builder: (context, setState) {
                         return _AnimatedMegaChart(currentPrice: _getMegaCurrentPrice());
                        
                      },
                    ),
                    const SizedBox(height: 20),
                    RichText(
                      textAlign: TextAlign.center,
                      text: TextSpan(
                        style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.5),
                        children: [
                          const TextSpan(text: "Цена растет каждую секунду! Успей забрать "),
                          const TextSpan(text: "\$MEGA", style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold)),
                          const TextSpan(text: " до 19 ноября 2026 года.\n\n"),
                          const TextSpan(text: "🔥 Нажмите ", style: TextStyle(color: Colors.orangeAccent)),
                          const TextSpan(text: "ЗАБРАТЬ \$MEGA", style: TextStyle(fontWeight: FontWeight.bold)),
                          const TextSpan(text: ", мгновенно подключите кошелек "),
                          const TextSpan(text: "Petra", style: TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold)),
                          const TextSpan(text: ", жмите "),
                          const TextSpan(text: "⚡EXECUTE", style: TextStyle(color: Colors.yellowAccent, fontWeight: FontWeight.bold)),
                          const TextSpan(text: " и подтвердите транзакцию.\n\n"),
                          const TextSpan(text: "✨ Поздравляем! ", style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold)),
                          const TextSpan(text: "Теперь вы — "),
                          const TextSpan(text: "ранний холдер ", style: TextStyle(fontStyle: FontStyle.italic)),
                          const TextSpan(text: "эксклюзивной монеты "),
                          const TextSpan(text: "\$MEGA! 💎\n\n", style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold)),
                          const TextSpan(
                            text: "⚠️ Важно: убедитесь, что на балансе есть немного APT для оплаты газа.",
                            style: TextStyle(color: Colors.redAccent, fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            actions: [
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Первый ряд: Отмена + ЗАБРАТЬ 10 $MEGA
                  Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          onPressed: () => Navigator.pop(context),
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.white70,
                            backgroundColor: Colors.grey.shade800,
                            padding: const EdgeInsets.symmetric(vertical: 8), // Уменьшил padding для меньшего размера
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                              side: BorderSide(color: Colors.grey.shade600, width: 1.5), // Добавил базовую каёмку
                            ),
                            minimumSize: const Size.fromHeight(35), // Уменьшил на ~20% (с 44 до 35)
                            shadowColor: Colors.greenAccent.withOpacity(0.6), // Цвет свечения
                            elevation: 4, // Добавил elevation для тени/glow
                          ),
                          child: const Text(
                            "Отмена",
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600), // Уменьшил fontSize
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: isPetraConnected
                              ? _harvest10 
                              : () => _showPetraRequiredDialog(), 
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.orangeAccent.shade700, // Сделал чуть другим цветом для отличия
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                              side: BorderSide(color: Colors.orangeAccent.shade400, width: 1.5),
                            ),
                            elevation: 4,
                            minimumSize: const Size.fromHeight(35),
                          ),
                          child: const Text(
                            "ЗАБРАТЬ 10 \$MEGA",
                            style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 8),

                  // Второй ряд: ЗАБРАТЬ 1 $MEGA + ЗАБРАТЬ 100 $MEGA
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton(
                          // ПРОВЕРКА: Если Petra подключена, вызываем транзакцию, иначе — открываем браузер
                          onPressed: isPetraConnected
                              ? _harvest 
                              : () => _showPetraRequiredDialog(), 
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.greenAccent.shade700,
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(vertical: 8), 
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                              side: BorderSide(color: Colors.greenAccent.shade400, width: 1.5), 
                            ),
                            elevation: 4, 
                            shadowColor: Colors.greenAccent.withOpacity(0.6), 
                            minimumSize: const Size.fromHeight(35), 
                          ),
                          child: const Text(
                            "ЗАБРАТЬ 1 \$MEGA",
                            style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold), 
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: isPetraConnected
                              ? _harvest100 
                              : () => _showPetraRequiredDialog(), 
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.redAccent.shade700, // Сделаем её красной для важности
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                              side: BorderSide(color: Colors.redAccent.shade400, width: 1.5),
                            ),
                            elevation: 6,
                            minimumSize: const Size.fromHeight(35),
                          ),
                          child: const Text(
                            "ЗАБРАТЬ 100 \$MEGA",
                            style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 16),

                  // Нижние текстовые ссылки (оставляем как было)
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      _buildFooterLink(
                        context, 
                        "Проблема с кнопкой? 1 \$MEGA", 
                        isPetraConnected ? "" : "https://explorer.aptoslabs.com/account/0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3/modules/run/mega_coin/harvest?network=mainnet", // URL теперь опционален
                        onTapOverride: isPetraConnected ? _harvest : null, 
                      ),
                      _buildFooterLink(
                        context, 
                        "ЗАБРАТЬ 10 \$MEGA", 
                        "https://explorer.aptoslabs.com/account/0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3/modules/run/mega_coin/harvest10?network=mainnet",
                        // Если Petra подключена, при нажатии сработает переход в кошелек
                        onTapOverride: isPetraConnected ? _harvest10 : null,
                      ),
                      _buildFooterLink(
                        context, 
                        "ЗАБРАТЬ 100 \$MEGA", 
                        "https://explorer.aptoslabs.com/account/0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3/modules/run/mega_coin/harvest100?network=mainnet",
                        onTapOverride: isPetraConnected ? _harvest100 : null,
                      ),
                    ],
                  ),
                ],
              ),
            ],
          );
        },
      );
    },
  );
}



  Future<int> _getCoinDecimals(String coinType) async {
  try {
    String moduleAddress = coinType.split("::")[0];
    final url = Uri.parse("$aptLedgerUrl/accounts/$moduleAddress/resource/0x1::coin::CoinInfo<$coinType>");
    final headers = {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36',
      'Accept': '*/*', 
    };
    final response = await http.get(url, headers: headers).timeout(const Duration(seconds: 5));
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      final decimalsValue = data["data"]["decimals"];  // Может быть int или String
      if (decimalsValue is int) {
        return decimalsValue;  // Уже int — просто верните
      } else if (decimalsValue is String) {
        return int.parse(decimalsValue);  // Если String — парсите
      } else {
        // debugPrint("Unexpected decimals type: ${decimalsValue.runtimeType}");
        return 8;  // Fallback
      }
    }
  } catch (e) {
    // debugPrint("Decimals fetch error: $e");
  }
  return 8;  // Дефолт на 8
}

  Future<int?> _fetchLedgerTimestamp() async {
    try {
      final headers = {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36',
        'Accept': 'application/json',
      };
      final response = await http.get(Uri.parse(aptLedgerUrl), headers: headers).timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return int.parse(data["ledger_timestamp"]) ~/ 1000000;
      }
    } catch (e) {
      // debugPrint("Timestamp fetch error: $e");
    }
    return null;
  }

  Future<dynamic> _fetchData(String apiUrl) async {
    try {
      final headers = {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36',
        'Accept': 'application/json',
      };
      final response = await http.get(Uri.parse(apiUrl), headers: headers).timeout(const Duration(seconds: 5));
      if (response.statusCode == 404) {
        if (apiUrl.contains("StakeInfo")) return {"amount": "0", "reward_amount": "0", "reward_debt": "0"};
        return null;
      }
      if (response.statusCode == 200) return json.decode(response.body)["data"];
    } catch (e) {
      // debugPrint("Data fetch error: $e");
    }
    return null;
  }

  Future<void> _runUpdateThread() async {
    await _updatePrices();
    await _fetchMegaStakeData(); // Получаем данные $MEGA
    _calculateMegaRewardLocally(); // Первичный расчет награды
    _updateMegaLabels(); // Обновляем метки
    double aptVal = 0; double meeVal = 0;
    try {
      int aptRaw = await _getRawBalance(aptCoinType);
      aptVal = aptRaw / 1e8;
      int meeDec = await _getCoinDecimals(meeCoinT0T1);
      int meeRaw = await _getRawBalance(meeCoinT0T1);
      // meeVal = (meeRaw * rawDataCorrectionFactor) / (BigInt.from(10).pow(meeDec).toDouble());
      meeVal = meeRaw / pow(10, meeDec);
      
      int megaDec = await _getCoinDecimals(megaCoinType);
      int megaRaw = await _getRawBalance(megaCoinType);
      double megaVal = megaRaw / pow(10, megaDec);
      megaOnChain = megaVal;
      megaInUsd = megaStakeBalance * _getMegaCurrentPrice() * priceApt;
      // debugPrint("Mega raw balance: $megaRaw");


    } catch (e) {}

    if (currentWalletAddress.length != 66 || !currentWalletAddress.startsWith("0x")) {
       _updateUI(null, null, 0.0, aptVal, meeVal);
       return;
    }


    String stakeResType = "0x514cfb77665f99a2e4c65a5614039c66d13e00e98daf4c86305651d29fd953e5::Staking::StakeInfo<$meeCoinT0T1,$meeCoinT0T1>";
    String stakeApiUrl = "$aptLedgerUrl/accounts/$currentWalletAddress/resource/${Uri.encodeComponent(stakeResType)}";
    String poolAddress = "0x482b8d35e320cca4f2d49745a1f702d052aa0366ac88e375c739dc479e81bc98";
    String poolResType = "0x514cfb77665f99a2e4c65a5614039c66d13e00e98daf4c86305651d29fd953e5::Staking::PoolInfo<$meeCoinT0T1,$meeCoinT0T1>";
    String poolApiUrl = "$aptLedgerUrl/accounts/$poolAddress/resource/${Uri.encodeComponent(poolResType)}";

    int? currentTime = await _fetchLedgerTimestamp();
    var meeStakeData = await _fetchData(stakeApiUrl);
    var meePoolData = await _fetchData(poolApiUrl);

    if (meeStakeData == null || meePoolData == null || currentTime == null) {
      _updateUI(null, null, 0.0, aptVal, meeVal);
      return;
    }

    double? stakeBalance; double? totalRewardFloat;
    try {
      BigInt amount = BigInt.parse(meeStakeData["amount"]) * BigInt.from(rawDataCorrectionFactor);
      BigInt rewardAmount = BigInt.parse(meeStakeData["reward_amount"]) * BigInt.from(rawDataCorrectionFactor);
      BigInt rewardDebt = BigInt.parse(meeStakeData["reward_debt"]) * BigInt.from(rawDataCorrectionFactor);

      
       
      // Читаем данные о разблокировке
     
      BigInt unlockingAmountRaw = BigInt.parse(meeStakeData["unlocking_amount"] ?? "0") * BigInt.from(rawDataCorrectionFactor);
      unlockingAmount = unlockingAmountRaw.toDouble() / pow(10, decimals);
      
      String? startTimeStr = meeStakeData["unlocking_start_time"];
      unlockingStartTime = (startTimeStr != null && startTimeStr != "0") ? int.parse(startTimeStr) : null;

      // Проверка: завершена ли разблокировка (обычно 15 дней = 1296000 секунд)
      if (unlockingStartTime != null && currentTime != null) {
        const int fifteenDaysInSec = 15 * 24 * 60 * 60;
        isUnlockComplete = (currentTime >= (unlockingStartTime! + fifteenDaysInSec));
      } else {
        isUnlockComplete = false;
      }  

            // --- ЛОГИКА ДЛЯ $MEGA STAKE ---
      String megaStakeResType = "0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3::mega_coin::StakePosition";
      String megaStakeApiUrl = "$aptLedgerUrl/accounts/$currentWalletAddress/resource/${Uri.encodeComponent(megaStakeResType)}";

      var megaStakeData = await _fetchData(megaStakeApiUrl);

      if (megaStakeData != null) {
        try {
          // Получаем значение amount из JSON
          String rawAmount = megaStakeData["amount"] ?? "0";
          // Делим на 10^8 (так как в вашем примере 3405127654 -> 34.05)
          megaStakeBalance = double.parse(rawAmount) / pow(10, 8);
        } catch (e) {
          megaStakeBalance = 0.0;
          //debugPrint("Error parsing MEGA stake: $e");
        }
      } else {
        megaStakeBalance = 0.0; // Если ресурса нет (кошелек не стейкал)
      }


      if (amount == BigInt.zero) {
        stakeBalance = 0.0; totalRewardFloat = 0.0;
      } else {
         BigInt accRewardPerShare = BigInt.parse(meePoolData["acc_reward_per_share"]);
         BigInt tokenPerSecond = BigInt.parse(meePoolData["token_per_second"]);
         int lastRewardTime = int.parse(meePoolData["last_reward_time"]);
         BigInt unlockingAmount = BigInt.parse(meePoolData["unlocking_amount"]);
         BigInt stakedValue = BigInt.parse(meePoolData["staked_coins"]["value"]);
         BigInt poolTotalAmount = stakedValue - unlockingAmount;
         int passedSeconds = currentTime - lastRewardTime;
         BigInt rewardPerShare = BigInt.zero;
         if (poolTotalAmount > BigInt.zero && passedSeconds > 0) {
            rewardPerShare = (tokenPerSecond * BigInt.from(passedSeconds) * BigInt.from(accPrecision)) ~/ poolTotalAmount;
         }
         BigInt newAcc = accRewardPerShare + rewardPerShare;
         BigInt pending = (amount * newAcc ~/ BigInt.from(accPrecision)) - rewardDebt;
         BigInt totalRewardRaw = rewardAmount + pending;
         stakeBalance = amount.toDouble() / (BigInt.from(10).pow(decimals).toDouble());
         totalRewardFloat = totalRewardRaw.toDouble() / (BigInt.from(10).pow(decimals).toDouble());
      }
    } catch (e) { stakeBalance = null; }

    double meeRate = 0.0;
    try {
       BigInt amount = BigInt.parse(meeStakeData["amount"]) * BigInt.from(rawDataCorrectionFactor);
       if (amount != BigInt.zero) {
          BigInt tokenPerSecond = BigInt.parse(meePoolData["token_per_second"]);
          BigInt unlockingAmount = BigInt.parse(meePoolData["unlocking_amount"]);
          BigInt stakedValue = BigInt.parse(meePoolData["staked_coins"]["value"]);
          BigInt poolTotalAmount = stakedValue - unlockingAmount;
          if (poolTotalAmount > BigInt.zero) {
             BigInt ratePrecision = BigInt.from(10).pow(18);
             BigInt numerator = tokenPerSecond * amount * ratePrecision;
             BigInt rateRawBigInt = numerator ~/ poolTotalAmount;
             double rateFloatRaw = rateRawBigInt.toDouble() / ratePrecision.toDouble();
             meeRate = rateFloatRaw / (BigInt.from(10).pow(decimals).toDouble());
          }
       }
    } catch (e) { meeRate = 0.0; }
    _updateUI(stakeBalance, totalRewardFloat, meeRate, aptVal, meeVal);

  

    if (currentWalletAddress == "0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3") {
     // await _fetchPendingTasks(); // Для админа — pending
    }

  }


void _updateUI(double? balance, double? reward, double rate, double aptVal, double meeVal) {
  if (!mounted) return;
  setState(() {
    // Присваиваем входящие значения (aptVal и meeVal) переменным класса
    // Теперь переменные aptOnChain и meeOnChain обновятся и будут видны в build
    aptOnChain = aptVal;
    meeOnChain = meeVal;

    // Расчеты для MEGA (оставляем, чтобы данные были актуальны)
    double megaPriceInApt = _getMegaCurrentPrice(); 
    double megaPriceInUsd = megaPriceInApt * priceApt;
    double megaTotalUsd = megaOnChain * megaPriceInUsd;
    
    // onChainBalancesText больше не нужен для вывода, 
    // так как мы используем Text.rich напрямую в build

    if (balance == null || reward == null) {
      meeBalanceText = "Ошибка сети!";
      meeRewardText = "Ошибка!";
      meeRateText = "Скорость: Ошибка";
      rewardTickerText = "[ОШИБКА]";
      isRunning = false;
      return;
    }
    
    meeRatePerSec = rate;
    meeCurrentReward = reward;
    
    String balUsd = (balance * priceMee).toStringAsFixed(6);
    meeBalanceText = "${balance.toStringAsFixed(2)} \$MEE (\$$balUsd)".replaceAll(".", ",");
    meeBalanceText2 = "${balance}";
    
    meeRateText = "Скорость: ${meeRatePerSec.toStringAsFixed(10)} MEE/сек".replaceAll(".", ",");
    _updateRewardLabelsOnly();
    isRunning = true;
    countdownVal = updateIntervalSeconds;
  });
}

  void _updateRewardLabelsOnly() {
    String rewardUsd = (meeCurrentReward * priceMee).toStringAsFixed(6);
   
    meeRewardText = "${meeCurrentReward.toStringAsFixed(8)} \$MEE ".replaceAll(".", ",");
    
  }

  Future<void> _checkUpdates({required bool manualCheck}) async {
  if (!manualCheck) {
    setState(() {
      updateStatusText = "v$currentVersion [Проверка...]";
      updateStatusColor = Colors.grey;
      updateAction = null;
    });
  }

  try {
    // Увеличим таймаут до 10 секунд на случай плохого интернета
    final response = await http.get(Uri.parse(urlGithubApi)).timeout(const Duration(seconds: 10));

    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      String latestTag = data['tag_name'] ?? 'v0.0.0';
      String? downloadUrl = data['html_url'];

      String cleanLatest = latestTag.replaceFirst(RegExp(r'[vV]'), '').trim();
      String cleanCurrent = currentVersion.replaceFirst(RegExp(r'[vV]'), '').trim();

      List<int> currentParts = cleanCurrent.split('.').map(int.parse).toList();
      List<int> newParts = cleanLatest.split('.').map(int.parse).toList();

      int comparison = 0; // 0 - равны, 1 - GitHub новее, -1 - Текущая новее
      for (int i = 0; i < 3; i++) {
        int newP = newParts.length > i ? newParts[i] : 0;
        int currP = currentParts.length > i ? currentParts[i] : 0;
        if (newP > currP) {
          comparison = 1;
          break;
        } else if (newP < currP) {
          comparison = -1;
          break;
        }
      }

      setState(() {
        if (comparison == 1 && downloadUrl != null) {
          // Версия на GitHub новее
          updateStatusText = "ДОСТУПНА v$cleanLatest! (Качай mee.apk)";
          updateStatusColor = Colors.redAccent;
          updateAction = () => _showUpdateModal(cleanLatest, downloadUrl);
          if (!manualCheck) _showUpdateModal(cleanLatest, downloadUrl);
        } else if (comparison == -1) {
          // Текущая версия новее (Бета/Разработка)
          updateStatusText = "v$currentVersion (Новее чем на GitHub)";
          updateStatusColor = Colors.blueAccent; // Выделим синим, что версия "особенная"
          updateAction = () => _manualUpdateCheck();
        } else {
          // Версии равны
          updateStatusText = manualCheck ? "v$currentVersion (Последняя)" : "v$currentVersion (Проверить обновление)";
          updateStatusColor = manualCheck ? Colors.greenAccent : Colors.grey;
          updateAction = () => _manualUpdateCheck();
        }
      });
    } else {
      // Если сервер ответил не 200 (например, 403 - лимит запросов GitHub)
      _setUpdateError("Ошибка сервера: ${response.statusCode}");
    }
  } on TimeoutException {
    _setUpdateError("Ошибка: Время ожидания истекло");
  } catch (e) {
    // Вывод типа ошибки (например, SocketException если нет интернета)
    _setUpdateError("Ошибка: ${e.runtimeType}");
    //debugPrint("Update error: $e");
  }
}

// Вспомогательный метод для вывода ошибок
void _setUpdateError(String text) {
  setState(() {
    updateStatusText = text;
    updateStatusColor = Colors.orangeAccent;
    updateAction = () => _manualUpdateCheck();
  });
}

  void _manualUpdateCheck() => _checkUpdates(manualCheck: true);

  // --- ДИАЛОГОВЫЕ ОКНА ---

  void _showMiningInfo() {
    showDialog(context: context, builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF1E1E1E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: Colors.blueAccent)),
      title: const Row(children: [
        Text("⛏️ ", style: TextStyle(fontSize: 24)),
        Text("О скорости", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold))
      ]),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("Скорость стейкинга напрямую зависит от вашего "),
            const Text("личного баланса монет \$MEE ", style: TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold, fontStyle: FontStyle.italic)),
            const Text("в майнере и общего пула нагар."),
            const SizedBox(height: 15),
            const Text("Примерные показатели:", style: TextStyle(fontWeight: FontWeight.bold, decoration: TextDecoration.underline)),
            const SizedBox(height: 10),
            _infoRow("🔹 1 000 MEE", "~0.000004 MEE/с"),
            _infoRow("🔹 10 000 MEE", "~0.00004 MEE/с"),
            _infoRow("🔹 100 000 MEE", "~0.0004 MEE/с"),
            const SizedBox(height: 15),
            const Text("Чем больше монет вы отправили в стейкинг, тем ", style: TextStyle(fontSize: 13)),
            const Text("выше ваша доля ", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.greenAccent)),
            const Text("в распределении новых монет.", style: TextStyle(fontSize: 13)),
          ],
        ),
      ),
      actionsPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      actions: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              style: TextButton.styleFrom(foregroundColor: Colors.white70, backgroundColor: Colors.white10),
              child: const Text("Закрыть"),
            ),
          ],
        )
      ],
    ));
  }

  Widget _infoRow(String label, String val) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 13)),
          Text(val, style: const TextStyle(color: Colors.orangeAccent, fontSize: 13, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }

  void _showAboutProject() {
    showDialog(context: context, builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF1A1A1A),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15), side: const BorderSide(color: Colors.blue)),
      title: const Center(child: Text("🚀 MEE - MEGA Miner", style: TextStyle(color: Colors.blue, fontWeight: FontWeight.bold))),
      content: SingleChildScrollView(
        child: RichText(text: const TextSpan(
          style: TextStyle(color: Colors.white70, fontSize: 14, height: 1.4),
          children: [
            TextSpan(text: "Приложение MEGA ", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blueAccent)),
            TextSpan(text: "позволяет накапливать доход даже при минимальном стейкинге в "),
            TextSpan(text: "1 MEE, 1 MEGA", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.orange)),
            TextSpan(text: ".\n\n"),
            TextSpan(text: "💡 Бесплатные монеты:\n", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
            TextSpan(text: "Напишите в чат поддержки — сообщество часто помогает новичкам монетами для старта!\n\n"),
            TextSpan(text: "⚠️ Важно:\n", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.redAccent)),
            TextSpan(text: "Для любых транзакций в сети Aptos необходим "),
            TextSpan(text: "APT (газ)", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
            TextSpan(text: ".\n\n"),
            TextSpan(text: "📈 О проекте:\n", style: TextStyle(fontWeight: FontWeight.bold)),
            TextSpan(text: "Стейеинг реализован через официальные смарт-контракты проекта."),
          ]
        )),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          style: TextButton.styleFrom(backgroundColor: Colors.blueGrey.shade800, foregroundColor: Colors.white),
          child: const Text("Закрыть"),
        )
      ],
    ));
  }

  void _openCustomEditWalletDialog() {
    final TextEditingController controller = TextEditingController(text: currentWalletAddress);
    showDialog(context: context, builder: (context) {
      return StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: const Text("Сменить кошелек"),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text("Введите адрес Aptos (66 симв.):", style: TextStyle(fontSize: 12)),
                const SizedBox(height: 10),
                TextField(
                  controller: controller, 
                  style: const TextStyle(fontSize: 12),
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(), 
                    hintText: "0x...",
                    suffixIcon: controller.text.isNotEmpty 
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 18), 
                          onPressed: () { 
                            controller.clear(); 
                            setDialogState(() {}); 
                          }
                        ) 
                      : null,
                  ),
                  onChanged: (val) => setDialogState(() {}),
                ),
                const SizedBox(height: 10),
                TextButton.icon(onPressed: () async {
                  ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
                  if (data?.text != null) {
                    controller.text = data!.text!.trim();
                    setDialogState(() {});
                  }
                }, icon: const Icon(Icons.paste, size: 16), label: const Text("Вставить"))
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context), 
                child: const Text("Отмена")
              ),
              ElevatedButton(
                onPressed: () {
                  String trimmed = controller.text.trim(); // Используем 'controller'
                  if (trimmed.length == 66 && trimmed.startsWith("0x")) {
                    setState(() { 
                      currentWalletAddress = trimmed; 
                      isRunning = false; 
                      meeCurrentReward = 0.0; 
                      // ─── Обнуляем ВСЁ, что связано с $MEGA ───────────────────────
                      megaCurrentReward     = BigInt.zero;
                      megaStakeBalance      = 0.0;
                      megaOnChain           = 0.0;
                      megaInUsd             = 0.0;
                      megaRewardText        = "0,00000000 \$MEGA";
                      megaRateText          = "15% APR (0,00 MEGA/сек)";
                      megaStakedAmountRaw   = BigInt.zero;
                      megaLastUpdate        = BigInt.zero;
                      megaUnlockTime        = BigInt.zero;
                      isMegaUnlockComplete  = false;
                      unlockingAmount       = 0.0;          
                      isUnlockComplete      = false;

                      _updateWalletLabelText(); 
                    });

                    _saveWalletAddress(trimmed, isPetra: false); 

                    // Показываем уведомление
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text("Ручной адрес сохранен"),
                        duration: Duration(seconds: 3),
                      ),
                    );

                    _runUpdateThread(); 
                    Navigator.pop(context);
                  }
                }, 
                child: const Text("Сохранить")
              ),
            ],
          );
        }
      );
    });
  }

  void _showUpdateModal(String newVersion, String url) {
    showDialog(context: context, builder: (ctx) => AlertDialog(
      title: const Text("Обновление!"),
      content: Text("Доступна версия v$newVersion. Обновите приложение для стабильной работы. Качать нужно mee.apk!"),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Позже")),
        ElevatedButton(onPressed: () { launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication); Navigator.pop(ctx); }, child: const Text("Скачать")),
      ],
    ));
  }





void _showMegaHelp() {
  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: const Color(0xFF0D1F2D), 
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Colors.greenAccent, width: 1.5),
      ),
      title: const Column(
        children: [
          Text(
            "💎 СТЕЙКИНГ \$MEGA — как это работает",
            style: TextStyle(
              color: Colors.greenAccent,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          SizedBox(height: 6),
          Text(
            "15% годовых • мгновенная награда!",
            style: TextStyle(
              color: Colors.white70,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),

            // Шаг 1
            _helpStep(
              emoji: "1️⃣",
              title: "Добавить \$MEGA в стейкинг",
              text: "Нажми «Добавить \$MEGA» → подтверди транзакцию в Petra.\n"
                  "Твои монеты начинают приносить доход **сразу** — 15% годовых.",
              color: Colors.cyanAccent,
            ),

            const SizedBox(height: 16),

            // Шаг 2
            _helpStep(
              emoji: "2️⃣",
              title: "Награда начисляется автоматически",
              text: "Каждую секунду ты видишь, как растёт твой заработок.\n"
                  "Чем дольше \$MEGA в стейкинге — тем больше получаешь.",
              color: Colors.greenAccent,
            ),

            const SizedBox(height: 16),

            // Шаг 3
            _helpStep(
              emoji: "3️⃣",
              title: "Забрать награду",
              text: "Нажимай «ЗАБРАТЬ НАГРАДУ» → получаешь только **начисленные** \$MEGA.\n"
                  "Основной стейк остаётся работать и дальше приносить доход.",
              color: Colors.orangeAccent,
            ),

            const SizedBox(height: 16),

            // Шаг 4 — важный блок
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.redAccent.withOpacity(0.12),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.redAccent.withOpacity(0.4), width: 1),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "4️⃣  Вывод основного стейка",
                    style: TextStyle(
                      color: Colors.redAccent,
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text.rich(
                    TextSpan(
                      style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
                      children: [
                        TextSpan(text: "• Нажми "),
                        TextSpan(
                          text: "ЗАБРАТЬ \$MEGA",
                          style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold),
                        ),
                        TextSpan(text: " → запустится таймер "),
                        TextSpan(
                          text: "15 дней",
                          style: TextStyle(color: Colors.orangeAccent, fontWeight: FontWeight.bold),
                        ),
                        TextSpan(text: "\n• Награда во время ожидания **не начисляется**\n"),
                        TextSpan(text: "• Через 15 дней жми "),
                        TextSpan(
                          text: "unstake_confirm",
                          style: TextStyle(
                            color: Colors.greenAccent,
                            fontWeight: FontWeight.bold,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                        TextSpan(text: ", чтобы получить монеты обратно"),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            
            const Center(
              child: Text(
                "✨ Главное преимущество \$MEGA:\n"
                "можно выводить награду **в любой момент** без потери основного стейка",
                style: TextStyle(
                  color: Colors.greenAccent,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  height: 1.4,
                ),
                textAlign: TextAlign.center,
              ),
            ),

            const SizedBox(height: 8),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text(
            "ПОНЯТНО!",
            style: TextStyle(
              color: Colors.greenAccent,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
      actionsPadding: const EdgeInsets.only(bottom: 8, right: 12, left: 12),
    ),
  );
}

// Вспомогательный виджет для красивого шага
Widget _helpStep({
  required String emoji,
  required String title,
  required String text,
  required Color color,
}) {
  return Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        emoji,
        style: const TextStyle(fontSize: 22),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                color: color,
                fontSize: 15,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              text,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    ],
  );
}



  Future<void> _showModalAndOpenUrl(String action, String url) async {
    // Подготовка стилей
    const stepStyle = TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 14);
    const normalStyle = TextStyle(color: Colors.white70, fontSize: 14, height: 1.5);
    const highlightStyle = TextStyle(fontWeight: FontWeight.bold, color: Colors.orangeAccent);
    const italicStyle = TextStyle(fontStyle: FontStyle.italic, color: Colors.grey, fontSize: 13);

    Map<String, dynamic> instructions = {
      "Harvest": {
        "title": "✅ Контракт скопирован!",
        "content": RichText(text: const TextSpan(style: normalStyle, children: [
          TextSpan(text: "1. В браузере подключите кошелек.\n"),
          TextSpan(text: "2. Вставьте контракт в поля "),
          TextSpan(text: "T0", style: highlightStyle),
          TextSpan(text: " и "),
          TextSpan(text: "T1", style: highlightStyle),
          TextSpan(text: ".\n"),
          TextSpan(text: "3. Нажмите кнопку "),
          TextSpan(text: "EXECUTE", style: highlightStyle),
          TextSpan(text: "."),
        ]))
      },
      "Stake": {
        "title": "✅ Контракт скопирован!",
        "content": RichText(text: const TextSpan(style: normalStyle, children: [
          TextSpan(text: "1. Подключите кошелек.\n"),
          TextSpan(text: "2. Вставьте контракт в "),
          TextSpan(text: "T0", style: highlightStyle),
          TextSpan(text: " и "),
          TextSpan(text: "T1", style: highlightStyle),
          TextSpan(text: ".\n"),
          TextSpan(text: "3. В поле "),
          TextSpan(text: "arg0", style: highlightStyle),
          TextSpan(text: " - введите сумму (1 MEE = 1000000).\n"),
          TextSpan(text: "4. Нажмите "),
          TextSpan(text: "EXECUTE", style: highlightStyle),
          TextSpan(text: "."),
        ]))
      },
      "Unstake": {
        "title": "⚠️ Вывод из стейкинга",
        "content": RichText(
          text: TextSpan(
            style: normalStyle,
            children: [
              const TextSpan(text: "1. Контракт скопирован! ", style: highlightStyle),
              const TextSpan(text: "Откройте браузер.\n\n"),
              const TextSpan(text: "2. Вставьте адрес \$MEE в поля ", style: stepStyle),
              const TextSpan(text: "T0", style: highlightStyle),
              const TextSpan(text: " и "),
              const TextSpan(text: "T1", style: highlightStyle),
              const TextSpan(text: ".\n\n"),
              const TextSpan(text: "3. В поле ", style: stepStyle),
              const TextSpan(text: "arg0 (u64)", style: highlightStyle),
              const TextSpan(text: " укажите сумму:\n"),
              const TextSpan(text: "   (Пример: 1 MEE = 1000000)\n\n"),
              const TextSpan(text: "4. В поле ", style: stepStyle),
              const TextSpan(text: "arg1 (u8)", style: highlightStyle),
              const TextSpan(text: " выберите режим:\n"),
              const TextSpan(text: "   • 0 — Обычный ", style: stepStyle),
              const TextSpan(text: "(15 дней, 0% комиссия)\n"),
              const TextSpan(text: "   • 1 — Мгновенный ", style: stepStyle),
              const TextSpan(text: "(комиссия 15%)\n\n"),
              const TextSpan(text: "5. Нажмите ", style: stepStyle),
              const TextSpan(text: "EXECUTE", style: highlightStyle),
              const TextSpan(text: " и подтвердите транзакцию.\n\n"),
              const TextSpan(text: "──────────────────────\n"),
              const TextSpan(text: "📌 Важно: ", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blueAccent)),
              const TextSpan(text: "Если вы выбрали режим «0», то через "),
              const TextSpan(text: "15 дней ", style: highlightStyle),
              const TextSpan(text: "вам необходимо будет использовать функцию "),
              // Ссылка на withdraw
              TextSpan(
                text: "withdraw",
                style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.greenAccent, decoration: TextDecoration.underline),
                recognizer: TapGestureRecognizer()..onTap = () {
                  launchUrl(Uri.parse("https://explorer.aptoslabs.com/account/0x514cfb77665f99a2e4c65a5614039c66d13e00e98daf4c86305651d29fd953e5/modules/run/Staking/withdraw?network=mainnet"), mode: LaunchMode.externalApplication);
                },
              ),
              const TextSpan(text: ", чтобы монеты вернулись на кошелек.\n\n", style: italicStyle),
              
              // НОВЫЙ ТЕКСТ: Ссылка на cancel_unstake
              const TextSpan(text: "* Если передумали Unstake, хотите снова майнить, жмите ", style: TextStyle(fontSize: 12, color: Colors.white70)),
              TextSpan(
                text: "cancel_unstake",
                style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.orangeAccent, decoration: TextDecoration.underline, fontSize: 12),
                recognizer: TapGestureRecognizer()..onTap = () {
                  launchUrl(Uri.parse("https://explorer.aptoslabs.com/account/0x514cfb77665f99a2e4c65a5614039c66d13e00e98daf4c86305651d29fd953e5/modules/run/Staking/cancel_unstake?network=mainnet"), mode: LaunchMode.externalApplication);
                },
              ),
            ],
          ),
        )
      }
    };
    
    var data = instructions[action]!;
    await Clipboard.setData(const ClipboardData(text: meeCoinT0T1));
    
    bool? result = await showDialog<bool>(
      context: context, 
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15), side: BorderSide(color: action == "Unstake" ? Colors.redAccent : Colors.blueAccent)),
        title: Text(data["title"]!, style: TextStyle(color: action == "Unstake" ? Colors.redAccent : Colors.blueAccent, fontWeight: FontWeight.bold)),
        content: SingleChildScrollView(child: data["content"]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Отмена")),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true), 
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green.shade700),
            child: const Text("Открыть браузер")
          )
        ],
      )
    );
    if (result == true) launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  Widget _buildSection({required Color bg, required Color borderColor, required Widget child}) {
    return Container(width: double.infinity, margin: const EdgeInsets.symmetric(vertical: 6), padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8), border: Border.all(color: borderColor, width: 1.5)), child: child);
  }
  

  @override
  Widget build(BuildContext context) {
    double megaPriceInApt_ui = _getMegaCurrentPrice();
    double megaPriceInUsd_ui = megaPriceInApt_ui * priceApt;
    double megaTotalUsd_ui = megaOnChain * megaPriceInUsd_ui;
    String megaBalanceDisplay = "${megaOnChain.toStringAsFixed(2)} \$MEGA (\$${megaTotalUsd_ui.toStringAsFixed(4)})".replaceAll(".", ",");
    

    return Scaffold(

      body: Stack( // Обернули всё в Stack
        children: [

        SafeArea(
          child: RefreshIndicator(
            
            onRefresh: () async { 
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("Обновление данных..."), duration: Duration(milliseconds: 800))
              );
              await _runUpdateThread(); 
            },
            
          

            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                 
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center, // Центровка
                      children: [
                        const Text(
                          "БИРЖА \$MEGA (APTOS)",
                          style: TextStyle(color: Colors.blueAccent, fontSize: 15, fontWeight: FontWeight.bold, letterSpacing: 1.2),
                        ),
                        const SizedBox(width: 8), // Отступ между текстом и картинкой
                        Image.asset('assets/apt.png', width: 20, height: 20),
                      ],
                    ),
                  ),

                  _buildSection(
                    bg: const Color(0xFF1E1E1E),
                    borderColor: Colors.grey.shade800,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                          
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Text(
                                  // Если адрес выглядит как настоящий → показываем сокращённый
                                  (currentWalletAddress.isNotEmpty &&
                                          currentWalletAddress.length >= 10 &&
                                          currentWalletAddress.startsWith("0x"))
                                      ? "${currentWalletAddress.substring(0, 6)}...${currentWalletAddress.substring(currentWalletAddress.length - 4)}"
                                      : "Ваш кошелёк →",
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: walletLabelColor,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),

                            // Иконка копирования — только если есть реальный адрес в памяти
                            if (currentWalletAddress.isNotEmpty &&
                                currentWalletAddress.length >= 10 &&
                                currentWalletAddress.startsWith("0x")) ...[
                             GestureDetector(
                                onTap: () {
                                  // Копируем адрес
                                  Clipboard.setData(ClipboardData(text: currentWalletAddress));
                                  
                                  // Заменяем SnackBar на твой стандартный тост сверху
                                  showTopToast("📋 Адрес скопирован!"); 
                                },
                                child: Padding(
                                  padding: const EdgeInsets.only(left: 8.0),
                                  child: Icon(
                                    Icons.copy_rounded,
                                    size: 14,
                                    color: walletLabelColor.withOpacity(0.9),
                                  ),
                                ),
                              ),
                            ],


                            ],
                          ),

                            ////////////
                            const SizedBox(width: 8),
                            // КНОПКА PETRA
                            GestureDetector(
                              onTap: isPetraConnected ? _disconnectPetra : _connectPetra,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(
                                  color: isPetraConnected 
                                      ? Colors.redAccent.withOpacity(0.1) 
                                      : Colors.blueAccent.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: isPetraConnected 
                                        ? Colors.redAccent.withOpacity(0.5) 
                                        : Colors.blueAccent.withOpacity(0.5)
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      isPetraConnected ? Icons.link_off : Icons.account_balance_wallet, 
                                      color: isPetraConnected ? Colors.redAccent : Colors.blueAccent, 
                                      size: 14
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      isPetraConnected ? "ОТКЛЮЧИТЬ PETRA" : "ПОДКЛЮЧИТЬ PETRA",
                                      style: TextStyle(
                                        color: isPetraConnected ? Colors.redAccent : Colors.blueAccent,
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                      
                      
                        Text.rich(
                          TextSpan(
                            style: const TextStyle(fontSize: 13, color: Colors.white70, fontWeight: FontWeight.w500, height: 1.8,),
                            children: [
                              // --- APT ---
                              WidgetSpan(
                                alignment: PlaceholderAlignment.middle,
                                child: Padding(
                                  padding: const EdgeInsets.only(right: 4),
                                  child: Image.asset('assets/apt.png', width: 20, height: 20),
                                ),
                              ),
                              const TextSpan(text: "\$APT", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                              TextSpan(text: ": ${aptOnChain.toStringAsFixed(8)}", style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                              const TextSpan(text: " (", style: TextStyle(color: Colors.greenAccent)),
                              TextSpan(text: "\$${priceApt}", style: const TextStyle(color: Colors.greenAccent)),
                              const TextSpan(text: " / ", style: TextStyle(color: Colors.greenAccent)),
                              TextSpan(text: "\$${(aptOnChain * priceApt).toStringAsFixed(4)}", style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.greenAccent)),
                              const TextSpan(text: ")\n", style: TextStyle(color: Colors.greenAccent)), // Добавили \n в конце строки

                              // --- MEE ---
                              WidgetSpan(
                                alignment: PlaceholderAlignment.middle,
                                child: Padding(
                                  padding: const EdgeInsets.only(right: 4),
                                  child: Image.asset('assets/mee.png', width: 20, height: 20),
                                ),
                              ),
                              const TextSpan(text: "\$MEE", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                              TextSpan(text: ": ${meeOnChain.toStringAsFixed(6)}", style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                              const TextSpan(text: " (", style: TextStyle(color: Colors.greenAccent)),
                              TextSpan(text: "\$${priceMee.toStringAsFixed(6)}", style: const TextStyle(color: Colors.greenAccent)),
                              const TextSpan(text: " / ", style: TextStyle(color: Colors.greenAccent)),
                              TextSpan(text: "\$${(meeOnChain * priceMee).toStringAsFixed(6)}", style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.greenAccent)),
                              const TextSpan(text: ")\n", style: TextStyle(color: Colors.greenAccent)), // Добавили \n в конце строки

                              // --- MEGA ---
                              WidgetSpan(
                                alignment: PlaceholderAlignment.middle,
                                child: Padding(
                                  padding: const EdgeInsets.only(right: 4),
                                  child: Image.asset('assets/mega.png', width: 20, height: 20),
                                ),
                              ),
                              const TextSpan(text: "\$MEGA", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                              TextSpan(text: ": ${megaOnChain.toStringAsFixed(8)}", style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                              const TextSpan(text: " (", style: TextStyle(color: Colors.greenAccent)),
                              TextSpan(text: "\$${(megaOnChain * _getMegaCurrentPrice() * priceApt).toStringAsFixed(4)}", style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.greenAccent)),
                              const TextSpan(text: ")", style: TextStyle(color: Colors.greenAccent)),
                            ],
                          ),
                        ), 

                        const SizedBox(height: 8),
                    
                        // Кнопки управления кошельком и обмена
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            // ← НОВАЯ КНОПКА "ИСТОРИЯ"
                            ElevatedButton.icon(
                              icon: const Icon(Icons.history_rounded, size: 18, color: Colors.orangeAccent),
                              label: const Text(
                                "",
                                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.blueGrey.shade900,
                                foregroundColor: Colors.orangeAccent,
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                minimumSize: const Size(50, 36),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                elevation: 2,
                              ),
                              onPressed: _showHistorySheet, // _showWalletTransactionHistory,
                            ),

                            const SizedBox(width: 8),

                            // Кнопка "Отправить" (остаётся как была)
                            ElevatedButton.icon(
                              label: const Text(
                                "",
                                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                              ),
                              icon: const Icon(Icons.send_rounded, size: 18, color: Colors.white),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.blueGrey.shade900,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                minimumSize: const Size(50, 36),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                elevation: 2,
                              ),
                              onPressed: _showSendDialog,
                            ),

                            const SizedBox(width: 8),

                            Expanded(
                              flex: 1,
                              child: ElevatedButton(   // твоя кнопка "БИРЖА"
                                onPressed: () {
                                  _fetchMegaTasks();
                                  _showEarnDialog();
                                },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.green.shade800,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(vertical: 6),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  mainAxisSize: MainAxisSize.min,
                                  children: const [
                                    Icon(Icons.currency_exchange, size: 16, color: Colors.white),
                                    SizedBox(width: 6),
                                    Text("БИРЖА", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                                  ],
                                ),
                              ),
                            ),

                            const SizedBox(width: 8),

                            // Кнопка "Обмен" (остаётся как была)
                            SizedBox(
                              height: 36,
                              child: ElevatedButton.icon(
                                onPressed: _showSwapDialog,
                                icon: const Icon(Icons.swap_horiz, size: 16),
                                label: const Text("Обмен", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.blueGrey.shade900,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(horizontal: 16),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                ),
                              ),
                            ),
                          ],
                        ),

                      ],
                    )
                  ),
                  _buildSection(
                    bg: const Color(0xFF0D2335),
                    borderColor: Colors.blue.shade900,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text.rich(
                              TextSpan(
                                children: [
                                  const TextSpan(
                                    text: "СТЕЙКИНГ ",
                                    style: TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold, fontSize: 13),
                                  ),
                                  WidgetSpan(
                                    alignment: PlaceholderAlignment.middle,
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 4),
                                      child: Image.asset(
                                        'assets/mee.png', 
                                        width: 20,
                                        height: 20,
                                      ),
                                    ),
                                  ),
                                  TextSpan( // УБРАНО const ЗДЕСЬ
                                    text: "\$MEE:", // Добавлен \ перед $, чтобы код не искал переменную MEE
                                    style: const TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold, fontSize: 13),
                                  ),
                                ],
                              ),
                            ), 

                          
                            ElevatedButton(
                              onPressed: () {
                                if (isPetraConnected) {
                                  // Если кошелек подключен — показываем выбор типа
                                  _showUnstakeChoiceDialog();
                                } else {
                                  // Если нет — стандартное окно со ссылкой в браузер
                                  
                                  _showPetraRequiredDialog();
                                }
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFFDC143C),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                                minimumSize: const Size(80, 25),
                              ),
                              child: const Text("ЗАБРАТЬ \$MEE", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                            ),
  

                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(child: Text(meeBalanceText, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500))),
                            
                            ElevatedButton(
                              onPressed: () {
                                if (isPetraConnected) {
                                  _stakeMee();
                                } else {
                                  
                                  _showPetraRequiredDialog();

                                }
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.green.shade700, 
                                foregroundColor: Colors.white,
                                
                              ), 
                              child: const Text("ДОБАВИТЬ \$MEE", style: TextStyle(fontSize: 10)),
                            )

                          ],
                        ),
                                            
                        // НОВЫЙ БЛОК: ПРОВЕРКА UNSTAKE
                        if (unlockingAmount > 0) ...[
                          const Divider(color: Colors.white10, height: 20),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                "🔓 Разблокировка: ${unlockingAmount.toStringAsFixed(2)} \$MEE",
                                style: const TextStyle(color: Colors.orangeAccent, fontSize: 12, fontWeight: FontWeight.bold),
                              ),
                              _buildUnlockCountdown(), // Вызов таймера (код ниже)
                              const SizedBox(height: 10),
                                  
                              // Кнопка ЗАВЕРШИТЬ ВЫВОД
                              ElevatedButton(
                                onPressed: isUnlockComplete 
                                  ? () {
                                      if (isPetraConnected) {
                                        _withdrawMee();
                                      } else {
                                        
                                        _showPetraRequiredDialog();
                                      }
                                    }
                                  : null, // Кнопка неактивна, пока время не выйдет
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: isUnlockComplete ? Colors.green : Colors.grey.shade800,
                                  disabledBackgroundColor: Colors.white10,
                                  foregroundColor: Colors.white,
                                ),
                                child: Text(
                                  isUnlockComplete ? "ЗАВЕРШИТЬ ВЫВОД \$MEE" : "ОЖИДАНИЕ ВЫВОДА...", 
                                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                                ),
                              ), 
                      
                              // Кнопка ОТМЕНИТЬ
                              TextButton(
                                onPressed: () async {
                                  if (isPetraConnected) {
                                    // Если Petra подключена — вызываем функцию для кошелька
                                    _cancelUnstakeMee();
                                  } else {
                                    
                                    _showPetraRequiredDialog();
                                  }
                                },
                                child: const Text(
                                  "Отменить вывод", 
                                  style: TextStyle(color: Colors.redAccent, fontSize: 12),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  _buildSection(
                    bg: const Color(0xFF0D2B1A),
                    borderColor: Colors.green.shade900,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [

                        Row(
                          children: [
                            Text.rich(
                              TextSpan(
                                children: [
                                  const TextSpan(
                                    text: "НАГРАДА ",
                                    style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 13),
                                  ),
                                  WidgetSpan(
                                    alignment: PlaceholderAlignment.middle,
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 4),
                                      child: Image.asset(
                                        'assets/mee.png',
                                        width: 20,
                                        height: 20,
                                      ),
                                    ),
                                  ),
                                  const TextSpan(
                                    text: "\$MEE:",
                                    style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 13),
                                  ),
                                ],
                              ),
                            ),
                            
                          ],
                        ),

                      
                        const SizedBox(height: 4),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween, 
                          crossAxisAlignment: CrossAxisAlignment.center, // Выравнивание по центру по вертикали для кнопки
                          children: [
                            // Используем Column, чтобы сумма в монетах и в $ были друг под другом
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    meeRewardText, 
                                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.greenAccent)
                                  ),
                                  const SizedBox(height: 2),
                                  // НОВЫЙ БЛОК: Сумма в долларах
                                  Text(
                                    "(\$${(meeCurrentReward * priceMee).toStringAsFixed(6)})".replaceAll(".", ","),
                                    style: TextStyle(fontSize: 13, color: Colors.greenAccent.withOpacity(0.8), fontWeight: FontWeight.w500)
                                  ),
                                ],
                              ),
                            ),
                          

                            ElevatedButton(
                              onPressed: () {
                                if (isPetraConnected) {
                                  // 1. Если кошелек подключен, сразу запускаем транзакцию в Petra
                                  _harvestMee();
                                } else {
                                  // 2. Если не подключен, показываем старое окно с кнопкой перехода в браузер
                                  // _showModalAndOpenUrl("Harvest", harvestBaseUrl);
                                  _showPetraRequiredDialog();
                                }
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.green.shade700, 
                                foregroundColor: Colors.white,
                              ), 
                              child: const Text("ЗАБРАТЬ НАГРАДУ", style: TextStyle(fontSize: 10)),
                            )
                            
                          ]
                        ),
                        const SizedBox(height: 6),
                        Row(children: [
                          Text(meeRateText, style: const TextStyle(fontSize: 11, color: Colors.white60)),
                          const SizedBox(width: 10),
                          SizedBox(
                            width: 25, height: 25,
                            child: IconButton(
                              padding: EdgeInsets.zero,
                              onPressed: _showMiningInfo, 
                              icon: Container(
                                width: 20, height: 20,
                                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.blueAccent, width: 2)),
                                child: const Center(child: Text("?", style: TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold, fontSize: 8))),
                              ),
                            ),
                          ),
                        ]),
                      ],
                    )
                  ),
                  // GTA
                  GestureDetector(
                    onTap: _showMegaEventDialog,
                    child: Center(
                      child: Image.asset(
                        'assets/GTA.gif',
                        width: double.infinity,
                        height: null,
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                                // РАЗДЕЛ $MEGA (Ниже баннера GTA)
                  // --- СЕКЦИЯ $MEGA: БАЛАНС (СИНИЙ) ---
                  _buildSection(
                    bg: const Color(0xFF0D2335),
                    borderColor: Colors.blue.shade900,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [ 
                            
                            Text.rich(
                              TextSpan(
                                children: [
                                  const TextSpan(
                                    text: "СТЕЙКИНГ ",
                                    style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 13),
                                  ),
                                  WidgetSpan(
                                    alignment: PlaceholderAlignment.middle,
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 4),
                                      child: Image.asset(
                                        'assets/mega.png', 
                                        width: 20, 
                                        height: 20,
                                      ),
                                    ),
                                  ),
                                  const TextSpan(
                                    text: "\$MEGA:",
                                    style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 13),
                                  ),
                                ],
                              ),
                            ), 

                            Row(
                              children: [
                                // КРУГЛАЯ КНОПКА СПРАВКИ 
                              
                                const SizedBox(width: 8),
                                
                                // КНОПКА ЗАБРАТЬ (интегрированная с Petra)
                                ElevatedButton(
                                  onPressed: () async {
                                    // 1. Если Petra подключена, вызываем новую функцию напрямую
                                    if (isPetraConnected) {
                                      _unstakeRequest();
                                    } 
                                    // 2. Если не подключена — открываем по старинке в браузере
                                    else {
                                     
                                      _showPetraRequiredDialog();
                                    }
                                  },
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFFDC143C), // Сохраняем ваш красный цвет
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                                    minimumSize: const Size(80, 25),
                                  ),
                                  child: const Text(
                                    "ЗАБРАТЬ \$MEGA", 
                                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween, 
                          children: [
                            // Отображаем баланс из StakePosition (megaStakeBalance)
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text.rich(
                                    TextSpan(
                                      style: const TextStyle(fontSize: 14, color: Colors.white70),
                                      children: [
                                        TextSpan(
                                          text: "${megaStakeBalance.toStringAsFixed(4)} ",
                                          style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
                                        ),
                                        const TextSpan(
                                          text: "\$MEGA",
                                          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
                                        ),
                                      ],
                                    ),
                                    overflow: TextOverflow.ellipsis,  
                                    maxLines: 1,                      
                                  ),
                                  Text(
                                    "(\$${megaInUsd.toStringAsFixed(2)})",
                                    style: const TextStyle(fontSize: 12, color: Colors.greenAccent), 
                                    overflow: TextOverflow.ellipsis,  
                                    maxLines: 1,                   
                                  ),
                                ],
                              ),
                            ),
                            ElevatedButton(
                              onPressed: () async {
                                // Если кошелек подключен, вызываем функцию напрямую
                                if (isPetraConnected) {
                                  _stakeMega();
                                } 
                                // Если нет — открываем старую ссылку в браузере
                                else {                                
                                  _showPetraRequiredDialog(); 
                                }
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.green.shade700,
                                foregroundColor: Colors.white,
                                // Можно добавить те же отступы и форму, что и у других кнопок
                              ),
                              child: const Text("ДОБАВИТЬ \$MEGA", style: TextStyle(fontSize: 10)),
                            )
                          ]
                        ),
                      ],
                    ),
                  ),

                  // --- СЕКЦИЯ $MEGA: НАГРАДА (ЗЕЛЁНЫЙ) ---
                  _buildSection(
                    bg: const Color(0xFF0D3523), 
                    borderColor: Colors.green.shade900,
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            // Левая часть: Награда и сумма
                            Expanded( 
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text.rich(
                                    TextSpan(
                                      children: [
                                        const TextSpan(
                                          text: "НАГРАДА ",
                                          style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 13),
                                        ),
                                        WidgetSpan(
                                          alignment: PlaceholderAlignment.middle,
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(horizontal: 4),
                                            child: Image.asset(
                                              'assets/mega.png',
                                              width: 20,
                                              height: 20,
                                            ),
                                          ),
                                        ),
                                        const TextSpan(
                                          text: "\$MEGA:",
                                          style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 13),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Text(
                                    megaRewardText, 
                                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.greenAccent),
                                    overflow: TextOverflow.ellipsis,  
                                    maxLines: 1,                     
                                  ),
                                ],
                              ),
                            ),

                            const SizedBox(width: 4),

                            // Твоя кнопка со всей логикой БЕЗ сокращений
                            ElevatedButton(
                              onPressed: () async {
                                if (isPetraConnected) {
                                  _claimRewards(); 
                                } else {
                                 
                                  _showPetraRequiredDialog();
                                }
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.green.shade700, 
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(horizontal: 8), // Уменьшил внутренние отступы, чтобы текст влез
                                minimumSize: const Size(80, 30),
                              ), 
                              child: const Text("ЗАБРАТЬ НАГРАДУ", style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold)), // Чуть уменьшил шрифт текста на кнопке
                            ),
                          ],
                        ),
                        
                        const SizedBox(height: 8),

                        // Ряд с доходностью и иконкой помощи
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween, 
                          children: [
                            Expanded(
                              child: Text(
                                megaRateText, 
                                style: const TextStyle(fontSize: 10, color: Colors.blueAccent),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            GestureDetector(
                              onTap: _showMegaHelp,
                              child: Container(
                                padding: const EdgeInsets.all(4),
                                decoration: const BoxDecoration(
                                  color: Color(0xFFDC143C),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(Icons.help_outline, color: Colors.white, size: 14),
                              ),
                            ),
                          ],
                        ),

                        // Блок разблокировки (Unstake) — полностью сохранен
                        if (megaUnlockTime > BigInt.zero) ...[
                          const Divider(color: Colors.white10, height: 20),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                "🔓 Разблокировка: ${megaStakeBalance.toStringAsFixed(2)} \$MEGA",
                                style: const TextStyle(color: Colors.orangeAccent, fontSize: 12, fontWeight: FontWeight.bold),
                              ),
                              _buildMegaUnlockCountdown(),
                              const SizedBox(height: 10),
                              ElevatedButton(
                                onPressed: isMegaUnlockComplete ? () {
                                  if (isPetraConnected) {
                                    _unstakeConfirm();
                                  } else {
                                   
                                    _showPetraRequiredDialog();  
                                  }
                                } : null,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: isMegaUnlockComplete ? Colors.green : Colors.grey.shade800,
                                ),
                                child: Text(isMegaUnlockComplete ? "ЗАВЕРШИТЬ ВЫВОД \$MEGA" : "ОЖИДАНИЕ ВЫВОДА...", 
                                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                              ),
                              TextButton(
                                onPressed: () async {
                                  if (isPetraConnected) {
                                    _cancelUnstake();
                                  } else {
                                    
                                    _showPetraRequiredDialog();

                                  }
                                },
                                child: const Text("Отменить вывод", style: TextStyle(color: Colors.redAccent, fontSize: 12)),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),                
                  GridView.count(
                    crossAxisCount: 2, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), childAspectRatio: 3.5,
                    children: [
                      _linkBtn("Исходный код", urlSource),
                      _actionBtn("Контракты монет", _showContractsDialog),                      
                      _actionBtn("О проекте", _showAboutProject),
                      _linkBtn("Обмен \$MEE/APT", urlSwapEarnium),
                      _linkBtn("Чат поддержки", urlSupport),
                      _linkBtn("График \$MEE", urlGraph),
                    ],
                  ),
                  const SizedBox(height: 12),
                  GestureDetector(onTap: updateAction, child: Text(updateStatusText, textAlign: TextAlign.center,
                    style: TextStyle(color: updateStatusColor, fontSize: 11, fontWeight: FontWeight.bold))),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
        ),
      ///////// конец 
      // --- ПРОЗРАЧНЫЙ ЛОАДЕР (рисуется поверх всего) ---
          if (_isInitialLoading)
            Positioned.fill( // <-- ДОБАВЬ ЭТО: растягивает контейнер на весь экран
              child: Container(
                // color: Colors.black.withOpacity(0.7), // Затемнение
                child: const Center(
                  child: CircularProgressIndicator(
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.greenAccent),
                  ),
                ),
              ),
            ),
        ],
      ),  
      ///////////
    );
  }
  
  Widget _linkBtn(String text, String url) {
    return Container(margin: const EdgeInsets.all(4), child: ElevatedButton(
        onPressed: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
        style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2C2C2C), foregroundColor: Colors.orangeAccent, side: const BorderSide(color: Colors.orangeAccent), padding: EdgeInsets.zero),
        child: Text(text, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
    ));
  }

  Widget _actionBtn(String text, VoidCallback action) {
    return Container(margin: const EdgeInsets.all(4), child: ElevatedButton(
        onPressed: action,
        style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1E1E1E), foregroundColor: Colors.cyanAccent, side: const BorderSide(color: Colors.cyanAccent), padding: EdgeInsets.zero),
        child: Text(text, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
    ));
  }
}

class _AnimatedMegaChart extends StatefulWidget {
  final double currentPrice;
  _AnimatedMegaChart({required this.currentPrice});
  @override
  _AnimatedMegaChartState createState() => _AnimatedMegaChartState();
}

class _AnimatedMegaChartState extends State<_AnimatedMegaChart> with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 12),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Container(
          width: 300,
          height: 240,
          margin: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(15),
            border: Border.all(color: Colors.greenAccent.withOpacity(0.2)),
            boxShadow: [
              BoxShadow(color: Colors.greenAccent.withOpacity(0.05), blurRadius: 20)
            ],
          ),
          child: CustomPaint(
            painter: MegaChartPainter(_controller.value, widget.currentPrice),
          ),
        );
      },
    );
  }

}

class MegaChartPainter extends CustomPainter {
  final double animationValue;
  final double currentPrice;
  MegaChartPainter(this.animationValue, this.currentPrice);

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width;
    final double h = size.height - 40;
    final double paddingX = 35; // Отступ для текста месяцев
    final double chartW = w - paddingX * 2;
    final double chartH = h - 60;

    // Функция позиции: 0.0 (Январь) -> 1.0 (Ноябрь)
    Offset getPos(double t) {
      double x = paddingX + t * chartW;
      double y = (h - 20) - (t * chartH); 
      return Offset(x, y);
    }

    void drawText(String text, Offset pos, Color color, {double size = 10, bool bold = false}) {
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(color: color, fontSize: size, fontWeight: bold ? FontWeight.bold : FontWeight.normal, fontFamily: 'monospace'),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, pos);
    }

    // 1. СЕТКА (Горизонтальные уровни)
    // Увеличиваем прозрачность до 0.25 и толщину до 0.8 для четкости
    final gridPaint = Paint()
      ..color = Colors.white.withOpacity(0.25) 
      ..strokeWidth = 0.8;
      
    for (int i = 0; i <= 3; i++) {
      double y = (h - 20) - (i * chartH / 3);
      // Рисуем линию
      canvas.drawLine(Offset(paddingX, y), Offset(w - paddingX, y), gridPaint);
    }

    // 6. ВЕРТИКАЛЬНАЯ СЕТКА (чтобы сетка была полной клеткой)
    // В блоке с месяцами (внизу метода) убедитесь, что вертикальные линии тоже яркие
    final verticalGridPaint = Paint()
      ..color = Colors.white.withOpacity(0.15)
      ..strokeWidth = 0.5;

    // 2. ЦЕНОВЫЕ ЛИМИТЫ
    drawText("0.001 APT", const Offset(10, 10), Colors.greenAccent.withOpacity(0.6));
    drawText("0.1 APT", Offset(w - 55, 10), Colors.greenAccent, bold: true);

    // 3. ОСНОВНАЯ ЛИНИЯ ГРАФИКА
    canvas.drawLine(getPos(0), getPos(1), Paint()..color = Colors.white.withOpacity(0.15)..strokeWidth = 2);

    // 4. ТЕКУЩАЯ ТОЧКА (СВЕРХЪЯРКАЯ И БЫСТРАЯ ПУЛЬСАЦИЯ)
    double currentProgress = (currentPrice - 0.001) / (0.1 - 0.001);
    currentProgress = currentProgress.clamp(0.0, 1.0);
    Offset currentPos = getPos(currentProgress);

    // Ускоряем пульсацию в 3 раза (добавляем * 3.0)
    double pulseFactor = math.sin(animationValue * math.pi * 2 * 3.0);
    
    // 1. ВНЕШНЕЕ СВЕЧЕНИЕ (Аура)
    for (int i = 1; i <= 3; i++) {
      double glowSize = (12 + (pulseFactor * 8)) * i;
      canvas.drawCircle(
        currentPos,
        glowSize,
        Paint()
          ..color = Colors.greenAccent.withOpacity((0.3 / i).clamp(0.0, 1.0))
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 10 * i.toDouble()),
      );
    }

    // 2. ЯРКИЙ ЦЕНТРАЛЬНЫЙ ОРЕОЛ
    canvas.drawCircle(
      currentPos,
      8 + (pulseFactor * 4),
      Paint()
        ..color = Colors.greenAccent
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );

    // 3. БЕЛОЕ ЯДРО
    canvas.drawCircle(
      currentPos,
      5,
      Paint()
        ..color = Colors.white
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
    );

    // 4. САМА ТОЧКА
    canvas.drawCircle(currentPos, 4, Paint()..color = Colors.greenAccent);
    
    // ОСТАВЛЯЕМ ТОЛЬКО ОДИН ВЫВОД ЦЕНЫ ТУТ:
    drawText("${currentPrice.toStringAsFixed(6)} APT", 
      Offset(currentPos.dx - 35, currentPos.dy - 45), // Поднял чуть выше для красоты
      Colors.greenAccent, size: 11, bold: true);

    // 5. КОМЕТА И СВЕРХ-ЯРКИЙ ХВОСТ
    double cometT = currentProgress + (animationValue * (1.0 - currentProgress));
    Offset cometPos = getPos(cometT);
    
    // Эффект Bloom (свечение хвоста)
    canvas.drawLine(currentPos, cometPos, Paint()
      ..shader = LinearGradient(colors: [Colors.greenAccent.withOpacity(0), Colors.greenAccent.withOpacity(0.5)]).createShader(Rect.fromPoints(currentPos, cometPos))
      ..strokeWidth = 12.0
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8));

    // Основная яркая линия
    canvas.drawLine(currentPos, cometPos, Paint()
      ..shader = LinearGradient(colors: [Colors.greenAccent.withOpacity(0), Colors.greenAccent, Colors.white], stops: const [0.0, 0.8, 1.0]).createShader(Rect.fromPoints(currentPos, cometPos))
      ..strokeWidth = 4.5
      ..strokeCap = StrokeCap.round);

    // --- АГРЕССИВНАЯ ПУЛЬСАЦИЯ ГОЛОВЫ КОМЕТЫ ---
    // Ускоряем пульсацию (как и у основной точки)
    double cometPulse = math.sin(animationValue * math.pi * 2 * 3.0);
    
    // 1. Внешний пульсирующий ореол (создает эффект "энергетического заряда")
    canvas.drawCircle(
      cometPos, 
      12 + (cometPulse * 8), // Радиус "гуляет" от 4 до 20
      Paint()
        ..color = Colors.greenAccent.withOpacity(0.6)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );

    // 2. Внутренняя яркая вспышка
    canvas.drawCircle(
      cometPos, 
      6 + (cometPulse * 3), 
      Paint()
        ..color = Colors.greenAccent.withOpacity(0.6)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );

    // 3. Твердое ядро головы
    canvas.drawCircle(cometPos, 4, Paint()..color = Colors.white);

    // --- ЦЕНА У ГОЛОВЫ КОМЕТЫ (ПРОГНОЗ) ---
    double priceAtComet = 0.001 + (0.1 - 0.001) * cometT;
    
    drawText(
      "${priceAtComet.toStringAsFixed(6)} APT", 
      Offset(cometPos.dx + 15, cometPos.dy - 25), // Чуть отодвинули от пульсации
      Colors.white.withOpacity(0.9),
      size: 10, 
      bold: true // Сделаем чуть жирнее, чтобы лучше читалось на фоне вспышек
    );


    // 6. МЕСЯЦЫ И ВЕРТИКАЛЬНАЯ СЕТКА
    List<String> months = ['Янв', 'Мар', 'Май', 'Июл', 'Сен', 'Ноя'];
    for (int i = 0; i < months.length; i++) {
      double t = i / (months.length - 1);
      double x = paddingX + t * chartW;
      
      // Вертикальная линия сетки
      canvas.drawLine(Offset(x, h - 20), Offset(x, h - 20 - chartH), gridPaint);

      // Подпись месяца ровно под линией
      drawText(months[i], Offset(x - 12, h + 8), Colors.white.withOpacity(0.7), size: 10);
    }
  }

  @override
  bool shouldRepaint(covariant MegaChartPainter oldDelegate) => true;
}


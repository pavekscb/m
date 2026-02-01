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


// --- КОНСТАНТЫ ПРИЛОЖЕНИЯ И ВЕРСИИ ---
const String currentVersion = "1.0.9"; 
const String urlGithubApi = "https://api.github.com/repos/pavekscb/m/releases/latest";

const String walletKey = "WALLET_ADDRESS"; 
const String defaultExampleAddress = "0x9ba27fc8a65ba4507fc4cca1b456e119e4730b8d8cfaf72a2a486e6d0825b27b";
const int rawDataCorrectionFactor = 100;

// --- Константы Сети ---
const int decimals = 8;
const int accPrecision = 100000000000; 
const int updateIntervalSeconds = 60;

const String meeCoinT0T1 = "0xe9c192ff55cffab3963c695cff6dbf9dad6aff2bb5ac19a6415cad26a81860d9::mee_coin::MeeCoin";
const String aptCoinType = "0x1::aptos_coin::AptosCoin";
const String megaCoinType = "0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3::mega_coin::MEGA";

const String aptLedgerUrl = "https://fullnode.mainnet.aptoslabs.com/v1";
const String harvestBaseUrl = "https://explorer.aptoslabs.com/account/0x514cfb77665f99a2e4c65a5614039c66d13e00e98daf4c86305651d29fd953e5/modules/run/Staking/harvest?network=mainnet";
const String addMeeUrl = "https://explorer.aptoslabs.com/account/0x514cfb77665f99a2e4c65a5614039c66d13e00e98daf4c86305651d29fd953e5/modules/run/Staking/stake?network=mainnet";
const String unstakeBaseUrl = "https://explorer.aptoslabs.com/account/0x514cfb77665f99a2e4c65a5614039c66d13e00e98daf4c86305651d29fd953e5/modules/run/Staking/unstake?network=mainnet";

// КОНСТАНТЫ: Ссылки для кнопок
const String urlSource = "https://github.com/pavekscb/m";
// const String urlGraph = "https://dexscreener.com/aptos/pcs-167";
const String urlSwapEarnium = "https://app.panora.exchange/?ref=V94RDWEH#/swap/aptos?pair=MEE-APT";
const String urlSupport = "https://t.me/cripto_karta";
const String urlGraph = "https://dexscreener.com/aptos/pcs-167";

const String petraConnectedKey = "IS_PETRA_CONNECTED"; //
const String lastPetraAddressKey = "LAST_PETRA_ADDRESS"; // Ключ для хранения последнего адреса от Petra
const String manualAddressKey = "MANUAL_WALLET_ADDRESS";

void main() {
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

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
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
  String megaRateText = "Доходность: 15% APR (0,00 MEGA/сек)";

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
  String rewardTickerText = "[Загрузка]";
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
    _appLinks = AppLinks(); 
    _initDeepLinks();
    _loadSavedData();      
    _startApp();
  }

  @override
  void dispose() {
    _linkSubscription?.cancel();
    simulationTimer?.cancel();
    super.dispose();
  }

  Future<void> _startApp() async {
    await _loadWalletAddress();
    _runUpdateThread();
    _checkUpdates(manualCheck: false);
    _startPeriodicTimer();
  }

  void _startPeriodicTimer() {
    simulationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!isRunning) return;
      setState(() {     
        meeCurrentReward += meeRatePerSec;
        currentFrameIndex = (currentFrameIndex + 1) % animationFrames.length;
        _updateRewardLabelsOnly();
        countdownVal -= 1;
        rewardTickerText = animationFrames[currentFrameIndex];
        _startMegaSimulation();
      });
      if (countdownVal <= 0) {
        _runUpdateThread();
        countdownVal = updateIntervalSeconds;
      }
    });
  }

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
      megaRateText = "Доходность: 15% APR (${megaRate.toStringAsFixed(10).replaceAll(".", ",")} \$MEGA / сек)";
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
      debugPrint("Mega stake fetch error: $e");
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

//////////////////////////////////////// wallet connect

Future<void> _loadSavedData() async {
  final prefs = await SharedPreferences.getInstance();
  final savedPrivKey = prefs.getString('petra_temp_priv_key');
  final savedAddress = prefs.getString('petra_saved_address');

  if (savedPrivKey != null) {
    try {
      final privBytes = base64.decode(savedPrivKey);
      final algorithm = X25519();
      _myKeyPair = await algorithm.newKeyPairFromSeed(privBytes);
      
      if (savedAddress != null) {
        setState(() {
          // Исправлено: используем _petraAddress, как в твоем коде
          _petraAddress = savedAddress; 
          isPetraConnected = true;
        });
      }
      debugPrint("✅ Ключи восстановлены для адреса: $savedAddress");
    } catch (e) {
      debugPrint("❌ Ошибка восстановления ключей: $e");
    }
  }
}



void _disconnectPetra() async {
  final prefs = await SharedPreferences.getInstance();
  
  // 1. Сохраняем текущий адрес ПЕРЕД сбросом (если он не дефолтный)
  String currentAddressBeforeDisconnect = currentWalletAddress;
  
  // 2. Удаляем ключи Petra
  await prefs.remove('petra_saved_pub_key');
  await prefs.remove('petra_temp_priv_key');
  await prefs.remove('petra_temp_priv_key');
  await prefs.setBool(petraConnectedKey, false);
  await prefs.remove(lastPetraAddressKey); // Удаляем адрес Petra

  // 3. Проверяем, не является ли текущий адрес дефолтным примером
  // Если это дефолтный адрес, пробуем загрузить сохраненный ручной адрес
  if (currentAddressBeforeDisconnect == defaultExampleAddress) {
    final String? savedManualAddress = prefs.getString(manualAddressKey);
    if (savedManualAddress != null && 
        savedManualAddress.length == 66 && 
        savedManualAddress.startsWith("0x")) {
      currentAddressBeforeDisconnect = savedManualAddress;
    }
  } else if (currentAddressBeforeDisconnect.length == 66 && 
             currentAddressBeforeDisconnect.startsWith("0x")) {
    // Сохраняем текущий адрес как ручной (если он валидный и не дефолтный)
    await prefs.setString(manualAddressKey, currentAddressBeforeDisconnect);
  }

  // 4. Обновляем UI
  setState(() {
    currentWalletAddress = currentAddressBeforeDisconnect;
    isPetraConnected = false; 
    _updateWalletLabelText();
  });
  
  // 5. Сохраняем адрес в память (с флагом не-Petra)
  _saveWalletAddress(currentAddressBeforeDisconnect, isPetra: false);
  
  // 6. Показываем уведомление и обновляем данные
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(
      content: Text("Кошелек Petra отключен, используем введенный кошелек"),
      duration: Duration(seconds: 3),
    ),
  );
  
  Future.delayed(const Duration(milliseconds: 500), () {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Идет обновление данных..."),
        duration: Duration(seconds: 3),
      ),
    );
    _runUpdateThread();
  });
}


// 1. Начинаем слушать возвраты из кошелька
/* void _initDeepLinks() {
  _linkSubscription = _appLinks.uriLinkStream.listen((uri) {
    if (uri.scheme == 'meeiro' && uri.path.contains('connect')) {
      _handlePetraConnectResponse(uri);
    }
  });
}
*/

// 2. Метод, который вызывается по нажатию кнопки
Future<void> _connectPetra() async {
  try {
    final keyPair = await algorithm.newKeyPair();
    final privBytes = await keyPair.extractPrivateKeyBytes();
    
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('petra_temp_priv_key', base64.encode(privBytes));
    
    _myKeyPair = keyPair;
    final pubKey = await keyPair.extractPublicKey();
    final pubKeyHex = _bytesToHex(Uint8List.fromList(pubKey.bytes));

    final payload = {
      "appInfo": {"name": "Meeiro", "domain": "https://meeiro.io"},
      "redirectLink": "meeiro://api/v1/connect",
      "dappEncryptionPublicKey": pubKeyHex,
    };

    final url = Uri.parse(
      "petra://api/v1/connect?data=${base64.encode(utf8.encode(jsonEncode(payload)))}"
    );
    
    await launchUrl(url, mode: LaunchMode.externalApplication);

   /*
   // Новый код: показываем SnackBar после подключения
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Идет обновление данных..."),
        duration: Duration(seconds: 3),
      ),
    );
    _runUpdateThread();  // Уже есть, оставляем
   */

  } catch (e) {
    debugPrint("Petra Connect Error: $e");
  }
}

// 3. Обработка ответа от Petra
Future<void> _handlePetraConnectResponse(Uri uri) async {
  final data = uri.queryParameters['data'];
  if (data == null) return;

  try {
    final decoded = jsonDecode(utf8.decode(base64.decode(data)));
    final String newAddr = decoded['address'];
    final String petraPubKey = decoded['petraPublicEncryptedKey'];

    if (newAddr.isNotEmpty) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('petra_saved_pub_key', petraPubKey);
      // 
      await prefs.setBool(petraConnectedKey, true);



      
      setState(() {
        // ─── Самое важное: сначала обнуляем ВСЁ старое ────────
        megaCurrentReward     = BigInt.zero;
        megaStakedAmountRaw   = BigInt.zero;
        megaLastUpdate        = BigInt.zero;
        megaUnlockTime        = BigInt.zero;
        megaStakeBalance      = 0.0;
        megaOnChain           = 0.0;
        megaInUsd             = 0.0;
        megaRewardText        = "0,00000000 \$MEGA";
        megaRateText          = "Доходность: 15% APR (0,00 MEGA/сек)";
        isMegaUnlockComplete  = false;

        // Желательно обнулить и MEE-майнинг, чтобы консистентно
        meeCurrentReward      = 0.0;
        meeRewardText         = "0,00000000 \$MEE";
        unlockingAmount    = 0.0;   
        isUnlockComplete   = false;
        

        currentWalletAddress = newAddr; // Подставляем адрес в твою переменную
        isPetraConnected = true; // УСТАНАВЛИВАЕМ ФЛАГ
        _updateWalletLabelText();       // Обновляем текст в UI
      });
      
      _saveWalletAddress(newAddr, isPetra: true); // Сохраняем с флагом Petra
      _runUpdateThread(); //  

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Кошелек успешно подключен: ${newAddr.substring(0, 6)}...${newAddr.substring(newAddr.length - 4)}"),
          backgroundColor: Colors.green.shade800,
          duration: const Duration(seconds: 3),
        ),
      );
          // Новый код: показываем SnackBar после обработки ответа
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Идет обновление данных..."),
          duration: Duration(seconds: 3),
        ),
      );
      _runUpdateThread();  // Уже есть, оставляем
      
    }
  } catch (e) {
    debugPrint("Decode error: $e");
  }
}

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
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("❌ Ошибка: Ключи не инициализированы. Переподключите кошелек.")),
    );
    return;
  }

  final prefs = await SharedPreferences.getInstance();
  final petraKeyHex = prefs.getString('petra_saved_pub_key');
  final savedPrivKey = prefs.getString('petra_temp_priv_key');

  if (petraKeyHex == null || savedPrivKey == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("❌ Ошибка ключей в памяти. Переподключите кошелек.")),
    );
    return;
  }

  try {
    final myPrivKey = pine.PrivateKey(base64.decode(savedPrivKey));
    final petraPubKey = pine.PublicKey(_hexToBytes(petraKeyHex));

    // 1. Формируем объект транзакции
    final txObject = {
      "function": "0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3::mega_coin::harvest",
      "type": "entry_function_payload",
      "type_arguments": [],
      "arguments": [],
    };

    // 2. ВАЖНО: Делаем Base64 от JSON-строки перед шифрованием
    final innerJsonString = jsonEncode(txObject);
    final innerBase64 = base64.encode(utf8.encode(innerJsonString));

    // 3. Шифрование
    final box = pine.Box(myPrivateKey: myPrivKey, theirPublicKey: petraPubKey);
    final nonce = pine.PineNaClUtils.randombytes(24);
    
    // Шифруем именно base64-строку (как в рабочем коде)
    final encrypted = box.encrypt(utf8.encode(innerBase64), nonce: nonce);

    // 4. Получаем публичный ключ DApp (обязательно через extractPublicKey)
    final pubKey = await _myKeyPair!.extractPublicKey();
    final myPubKeyHex = _bytesToHex(Uint8List.fromList(pubKey.bytes));

    // 5. Итоговый объект
    final finalRequest = {
      "appInfo": {"name": "Meeiro", "domain": "https://meeiro.io"},
      "dappEncryptionPublicKey": myPubKeyHex,
      "nonce": _bytesToHex(Uint8List.fromList(nonce)),
      "payload": _bytesToHex(Uint8List.fromList(encrypted.cipherText)),
      "redirectLink": "meeiro://api/v1/harvest",
    };

    final dataParam = base64.encode(utf8.encode(jsonEncode(finalRequest)));
    final url = Uri.parse("petra://api/v1/signAndSubmit?data=$dataParam");

    await launchUrl(url, mode: LaunchMode.externalApplication);

  } catch (e) {
    debugPrint("Harvest Error: $e");
  }
}

Future<void> _harvest10() async {
  if (_myKeyPair == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("❌ Ошибка: Ключи не инициализированы. Переподключите кошелек.")),
    );
    return;
  }

  final prefs = await SharedPreferences.getInstance();
  final petraKeyHex = prefs.getString('petra_saved_pub_key');
  final savedPrivKey = prefs.getString('petra_temp_priv_key');

  if (petraKeyHex == null || savedPrivKey == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("❌ Ошибка ключей в памяти. Переподключите кошелек.")),
    );
    return;
  }

  try {
    final myPrivKey = pine.PrivateKey(base64.decode(savedPrivKey));
    final petraPubKey = pine.PublicKey(_hexToBytes(petraKeyHex));

    final txObject = {
      // ИЗМЕНЕНО: добавили 10 в конце названия функции
      "function": "0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3::mega_coin::harvest10",
      "type": "entry_function_payload",
      "type_arguments": [],
      "arguments": [],
    };

    final innerJsonString = jsonEncode(txObject);
    final innerBase64 = base64.encode(utf8.encode(innerJsonString));

    final box = pine.Box(myPrivateKey: myPrivKey, theirPublicKey: petraPubKey);
    final nonce = pine.PineNaClUtils.randombytes(24);
    final encrypted = box.encrypt(utf8.encode(innerBase64), nonce: nonce);

    final pubKey = await _myKeyPair!.extractPublicKey();
    final myPubKeyHex = _bytesToHex(Uint8List.fromList(pubKey.bytes));

    final finalRequest = {
      "appInfo": {"name": "Meeiro", "domain": "https://meeiro.io"},
      "dappEncryptionPublicKey": myPubKeyHex,
      "nonce": _bytesToHex(Uint8List.fromList(nonce)),
      "payload": _bytesToHex(Uint8List.fromList(encrypted.cipherText)),
      "redirectLink": "meeiro://api/v1/harvest10", // ИЗМЕНЕНО для статистики/логов
    };

    final dataParam = base64.encode(utf8.encode(jsonEncode(finalRequest)));
    final url = Uri.parse("petra://api/v1/signAndSubmit?data=$dataParam");

    await launchUrl(url, mode: LaunchMode.externalApplication);
  } catch (e) {
    debugPrint("Harvest10 Error: $e");
  }
}

Future<void> _harvest100() async {
  if (_myKeyPair == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("❌ Ошибка: Ключи не инициализированы. Переподключите кошелек.")),
    );
    return;
  }

  final prefs = await SharedPreferences.getInstance();
  final petraKeyHex = prefs.getString('petra_saved_pub_key');
  final savedPrivKey = prefs.getString('petra_temp_priv_key');

  if (petraKeyHex == null || savedPrivKey == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("❌ Ошибка ключей в памяти. Переподключите кошелек.")),
    );
    return;
  }

  try {
    final myPrivKey = pine.PrivateKey(base64.decode(savedPrivKey));
    final petraPubKey = pine.PublicKey(_hexToBytes(petraKeyHex));

    final txObject = {
      // МЕНЯЕМ НА harvest100
      "function": "0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3::mega_coin::harvest100",
      "type": "entry_function_payload",
      "type_arguments": [],
      "arguments": [],
    };

    final innerJsonString = jsonEncode(txObject);
    final innerBase64 = base64.encode(utf8.encode(innerJsonString));

    final box = pine.Box(myPrivateKey: myPrivKey, theirPublicKey: petraPubKey);
    final nonce = pine.PineNaClUtils.randombytes(24);
    final encrypted = box.encrypt(utf8.encode(innerBase64), nonce: nonce);

    final pubKey = await _myKeyPair!.extractPublicKey();
    final myPubKeyHex = _bytesToHex(Uint8List.fromList(pubKey.bytes));

    final finalRequest = {
      "appInfo": {"name": "Meeiro", "domain": "https://meeiro.io"},
      "dappEncryptionPublicKey": myPubKeyHex,
      "nonce": _bytesToHex(Uint8List.fromList(nonce)),
      "payload": _bytesToHex(Uint8List.fromList(encrypted.cipherText)),
      "redirectLink": "meeiro://api/v1/harvest100", 
    };

    final dataParam = base64.encode(utf8.encode(jsonEncode(finalRequest)));
    final url = Uri.parse("petra://api/v1/signAndSubmit?data=$dataParam");

    await launchUrl(url, mode: LaunchMode.externalApplication);
  } catch (e) {
    debugPrint("Harvest100 Error: $e");
  }
}

Future<void> _claimRewards() async {
  if (_myKeyPair == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("❌ Ошибка: Ключи не инициализированы. Переподключите кошелек.")),
    );
    return;
  }

  final prefs = await SharedPreferences.getInstance();
  final petraKeyHex = prefs.getString('petra_saved_pub_key');
  final savedPrivKey = prefs.getString('petra_temp_priv_key');

  if (petraKeyHex == null || savedPrivKey == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("❌ Ошибка ключей в памяти. Переподключите кошелек.")),
    );
    return;
  }

  try {
    final myPrivKey = pine.PrivateKey(base64.decode(savedPrivKey));
    final petraPubKey = pine.PublicKey(_hexToBytes(petraKeyHex));

    final txObject = {
      // Указываем функцию для получения наград
      "function": "0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3::mega_coin::claim_staking_rewards",
      "type": "entry_function_payload",
      "type_arguments": [],
      "arguments": [],
    };

    final innerJsonString = jsonEncode(txObject);
    final innerBase64 = base64.encode(utf8.encode(innerJsonString));

    final box = pine.Box(myPrivateKey: myPrivKey, theirPublicKey: petraPubKey);
    final nonce = pine.PineNaClUtils.randombytes(24);
    final encrypted = box.encrypt(utf8.encode(innerBase64), nonce: nonce);

    final pubKey = await _myKeyPair!.extractPublicKey();
    final myPubKeyHex = _bytesToHex(Uint8List.fromList(pubKey.bytes));

    final finalRequest = {
      "appInfo": {"name": "Meeiro", "domain": "https://meeiro.io"},
      "dappEncryptionPublicKey": myPubKeyHex,
      "nonce": _bytesToHex(Uint8List.fromList(nonce)),
      "payload": _bytesToHex(Uint8List.fromList(encrypted.cipherText)),
      "redirectLink": "meeiro://api/v1/claim", 
    };

    final dataParam = base64.encode(utf8.encode(jsonEncode(finalRequest)));
    final url = Uri.parse("petra://api/v1/signAndSubmit?data=$dataParam");

    await launchUrl(url, mode: LaunchMode.externalApplication);
  } catch (e) {
    debugPrint("Claim Rewards Error: $e");
  }
}

Future<void> _stakeMega() async {
  if (_myKeyPair == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("❌ Ошибка: Ключи не инициализированы. Переподключите кошелек.")),
    );
    return;
  }

  final prefs = await SharedPreferences.getInstance();
  final petraKeyHex = prefs.getString('petra_saved_pub_key');
  final savedPrivKey = prefs.getString('petra_temp_priv_key');

  if (petraKeyHex == null || savedPrivKey == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("❌ Ошибка ключей. Переподключите кошелек.")),
    );
    return;
  }

  try {
    final myPrivKey = pine.PrivateKey(base64.decode(savedPrivKey));
    final petraPubKey = pine.PublicKey(_hexToBytes(petraKeyHex));

    final txObject = {
      // Имя функции для стейкинга
      "function": "0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3::mega_coin::stake_all",
      "type": "entry_function_payload",
      "type_arguments": [],
      "arguments": [], // Если контракт требует сумму, её нужно будет добавить сюда
    };

    final innerJsonString = jsonEncode(txObject);
    final innerBase64 = base64.encode(utf8.encode(innerJsonString));

    final box = pine.Box(myPrivateKey: myPrivKey, theirPublicKey: petraPubKey);
    final nonce = pine.PineNaClUtils.randombytes(24);
    final encrypted = box.encrypt(utf8.encode(innerBase64), nonce: nonce);

    final pubKey = await _myKeyPair!.extractPublicKey();
    final myPubKeyHex = _bytesToHex(Uint8List.fromList(pubKey.bytes));

    final finalRequest = {
      "appInfo": {"name": "Meeiro", "domain": "https://meeiro.io"},
      "dappEncryptionPublicKey": myPubKeyHex,
      "nonce": _bytesToHex(Uint8List.fromList(nonce)),
      "payload": _bytesToHex(Uint8List.fromList(encrypted.cipherText)),
      "redirectLink": "meeiro://api/v1/stake", 
    };

    final dataParam = base64.encode(utf8.encode(jsonEncode(finalRequest)));
    final url = Uri.parse("petra://api/v1/signAndSubmit?data=$dataParam");

    await launchUrl(url, mode: LaunchMode.externalApplication);
  } catch (e) {
    debugPrint("Stake Error: $e");
  }
}

Future<void> _unstakeRequest() async {
  if (_myKeyPair == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("❌ Ошибка: Ключи не инициализированы. Переподключите кошелек.")),
    );
    return;
  }

  final prefs = await SharedPreferences.getInstance();
  final petraKeyHex = prefs.getString('petra_saved_pub_key');
  final savedPrivKey = prefs.getString('petra_temp_priv_key');

  if (petraKeyHex == null || savedPrivKey == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("❌ Ошибка ключей. Переподключите кошелек.")),
    );
    return;
  }

  try {
    final myPrivKey = pine.PrivateKey(base64.decode(savedPrivKey));
    final petraPubKey = pine.PublicKey(_hexToBytes(petraKeyHex));

    final txObject = {
      // Имя функции из контракта
      "function": "0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3::mega_coin::unstake_request",
      "type": "entry_function_payload",
      "type_arguments": [],
      "arguments": [], 
    };

    final innerJsonString = jsonEncode(txObject);
    final innerBase64 = base64.encode(utf8.encode(innerJsonString));

    final box = pine.Box(myPrivateKey: myPrivKey, theirPublicKey: petraPubKey);
    final nonce = pine.PineNaClUtils.randombytes(24);
    final encrypted = box.encrypt(utf8.encode(innerBase64), nonce: nonce);

    final pubKey = await _myKeyPair!.extractPublicKey();
    final myPubKeyHex = _bytesToHex(Uint8List.fromList(pubKey.bytes));

    final finalRequest = {
      "appInfo": {"name": "Meeiro", "domain": "https://meeiro.io"},
      "dappEncryptionPublicKey": myPubKeyHex,
      "nonce": _bytesToHex(Uint8List.fromList(nonce)),
      "payload": _bytesToHex(Uint8List.fromList(encrypted.cipherText)),
      "redirectLink": "meeiro://api/v1/unstake", 
    };

    final dataParam = base64.encode(utf8.encode(jsonEncode(finalRequest)));
    final url = Uri.parse("petra://api/v1/signAndSubmit?data=$dataParam");

    await launchUrl(url, mode: LaunchMode.externalApplication);
  } catch (e) {
    debugPrint("Unstake Request Error: $e");
  }
}

Future<void> _cancelUnstake() async {
  if (_myKeyPair == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("❌ Ошибка: Ключи не инициализированы. Переподключите кошелек.")),
    );
    return;
  }

  final prefs = await SharedPreferences.getInstance();
  final petraKeyHex = prefs.getString('petra_saved_pub_key');
  final savedPrivKey = prefs.getString('petra_temp_priv_key');

  if (petraKeyHex == null || savedPrivKey == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("❌ Ошибка ключей. Переподключите кошелек.")),
    );
    return;
  }

  try {
    final myPrivKey = pine.PrivateKey(base64.decode(savedPrivKey));
    final petraPubKey = pine.PublicKey(_hexToBytes(petraKeyHex));

    final txObject = {
      // Имя функции для отмены вывода
      "function": "0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3::mega_coin::cancel_unstake",
      "type": "entry_function_payload",
      "type_arguments": [],
      "arguments": [],
    };

    final innerJsonString = jsonEncode(txObject);
    final innerBase64 = base64.encode(utf8.encode(innerJsonString));

    final box = pine.Box(myPrivateKey: myPrivKey, theirPublicKey: petraPubKey);
    final nonce = pine.PineNaClUtils.randombytes(24);
    final encrypted = box.encrypt(utf8.encode(innerBase64), nonce: nonce);

    final pubKey = await _myKeyPair!.extractPublicKey();
    final myPubKeyHex = _bytesToHex(Uint8List.fromList(pubKey.bytes));

    final finalRequest = {
      "appInfo": {"name": "Meeiro", "domain": "https://meeiro.io"},
      "dappEncryptionPublicKey": myPubKeyHex,
      "nonce": _bytesToHex(Uint8List.fromList(nonce)),
      "payload": _bytesToHex(Uint8List.fromList(encrypted.cipherText)),
      "redirectLink": "meeiro://api/v1/cancel_unstake", 
    };

    final dataParam = base64.encode(utf8.encode(jsonEncode(finalRequest)));
    final url = Uri.parse("petra://api/v1/signAndSubmit?data=$dataParam");

    await launchUrl(url, mode: LaunchMode.externalApplication);
  } catch (e) {
    debugPrint("Cancel Unstake Error: $e");
  }
}

Future<void> _unstakeConfirm() async {
  if (_myKeyPair == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("❌ Ошибка: Ключи не инициализированы. Переподключите кошелек.")),
    );
    return;
  }

  final prefs = await SharedPreferences.getInstance();
  final petraKeyHex = prefs.getString('petra_saved_pub_key');
  final savedPrivKey = prefs.getString('petra_temp_priv_key');

  if (petraKeyHex == null || savedPrivKey == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("❌ Ошибка ключей. Переподключите кошелек.")),
    );
    return;
  }

  try {
    final myPrivKey = pine.PrivateKey(base64.decode(savedPrivKey));
    final petraPubKey = pine.PublicKey(_hexToBytes(petraKeyHex));

    final txObject = {
      "function": "0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3::mega_coin::unstake_confirm",
      "type": "entry_function_payload",
      "type_arguments": [],
      "arguments": [],
    };

    final innerJsonString = jsonEncode(txObject);
    final innerBase64 = base64.encode(utf8.encode(innerJsonString));

    final box = pine.Box(myPrivateKey: myPrivKey, theirPublicKey: petraPubKey);
    final nonce = pine.PineNaClUtils.randombytes(24);
    final encrypted = box.encrypt(utf8.encode(innerBase64), nonce: nonce);

    final pubKey = await _myKeyPair!.extractPublicKey();
    final myPubKeyHex = _bytesToHex(Uint8List.fromList(pubKey.bytes));

    final finalRequest = {
      "appInfo": {"name": "Meeiro", "domain": "https://meeiro.io"},
      "dappEncryptionPublicKey": myPubKeyHex,
      "nonce": _bytesToHex(Uint8List.fromList(nonce)),
      "payload": _bytesToHex(Uint8List.fromList(encrypted.cipherText)),
      "redirectLink": "meeiro://api/v1/unstake_confirm", 
    };

    final dataParam = base64.encode(utf8.encode(jsonEncode(finalRequest)));
    final url = Uri.parse("petra://api/v1/signAndSubmit?data=$dataParam");

    await launchUrl(url, mode: LaunchMode.externalApplication);
  } catch (e) {
    debugPrint("Unstake Confirm Error: $e");
  }
}

/// mee
Future<void> _harvestMee() async {
  if (_myKeyPair == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("❌ Ошибка: Ключи не инициализированы. Переподключите кошелек.")),
    );
    return;
  }

  final prefs = await SharedPreferences.getInstance();
  final petraKeyHex = prefs.getString('petra_saved_pub_key');
  final savedPrivKey = prefs.getString('petra_temp_priv_key');

  if (petraKeyHex == null || savedPrivKey == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("❌ Ошибка ключей в памяти. Переподключите кошелек.")),
    );
    return;
  }

  try {
    final myPrivKey = pine.PrivateKey(base64.decode(savedPrivKey));
    final petraPubKey = pine.PublicKey(_hexToBytes(petraKeyHex));

    // Параметр типа, который нужно передать дважды
    const meeType = "0xe9c192ff55cffab3963c695cff6dbf9dad6aff2bb5ac19a6415cad26a81860d9::mee_coin::MeeCoin";

    final txObject = {
      "function": "0x514cfb77665f99a2e4c65a5614039c66d13e00e98daf4c86305651d29fd953e5::Staking::harvest",
      "type": "entry_function_payload",
      "type_arguments": [meeType, meeType], // Передаем дважды, как требует контракт
      "arguments": [],
    };

    final innerJsonString = jsonEncode(txObject);
    final innerBase64 = base64.encode(utf8.encode(innerJsonString));

    final box = pine.Box(myPrivateKey: myPrivKey, theirPublicKey: petraPubKey);
    final nonce = pine.PineNaClUtils.randombytes(24);
    final encrypted = box.encrypt(utf8.encode(innerBase64), nonce: nonce);

    final pubKey = await _myKeyPair!.extractPublicKey();
    final myPubKeyHex = _bytesToHex(Uint8List.fromList(pubKey.bytes));

    final finalRequest = {
      "appInfo": {"name": "Meeiro", "domain": "https://meeiro.io"},
      "dappEncryptionPublicKey": myPubKeyHex,
      "nonce": _bytesToHex(Uint8List.fromList(nonce)),
      "payload": _bytesToHex(Uint8List.fromList(encrypted.cipherText)),
      "redirectLink": "meeiro://api/v1/harvest_mee", 
    };

    final dataParam = base64.encode(utf8.encode(jsonEncode(finalRequest)));
    final url = Uri.parse("petra://api/v1/signAndSubmit?data=$dataParam");

    await launchUrl(url, mode: LaunchMode.externalApplication);
  } catch (e) {
    debugPrint("Harvest MEE Error: $e");
  }
}

Future<void> _stakeMee() async {
  if (_myKeyPair == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("❌ Ошибка: Ключи не инициализированы.")),
    );
    return;
  }

  // Используем meeOnChain (баланс в кошельке)
  // Вычитаем 0.0001 MEE для надежности (чтобы не было Insufficient Balance)
  double amountToStake = meeOnChain - 0.0001;

  if (amountToStake <= 0) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("❌ Недостаточно MEE для стейкинга")),
    );
    return;
  }

  final prefs = await SharedPreferences.getInstance();
  final petraKeyHex = prefs.getString('petra_saved_pub_key');
  final savedPrivKey = prefs.getString('petra_temp_priv_key');

  if (petraKeyHex == null || savedPrivKey == null) return;

  try {
    final myPrivKey = pine.PrivateKey(base64.decode(savedPrivKey));
    final petraPubKey = pine.PublicKey(_hexToBytes(petraKeyHex));

    const meeType = "0xe9c192ff55cffab3963c695cff6dbf9dad6aff2bb5ac19a6415cad26a81860d9::mee_coin::MeeCoin";
    
    // Переводим в формат u64 (умножаем на 1 000 000, так как у MEE 6 знаков)
    final String rawAmount = (amountToStake * 1000000).toInt().toString();

    final txObject = {
      "function": "0x514cfb77665f99a2e4c65a5614039c66d13e00e98daf4c86305651d29fd953e5::Staking::stake",
      "type": "entry_function_payload",
      "type_arguments": [meeType, meeType],
      "arguments": [rawAmount],
    };

    final innerJsonString = jsonEncode(txObject);
    final innerBase64 = base64.encode(utf8.encode(innerJsonString));

    final box = pine.Box(myPrivateKey: myPrivKey, theirPublicKey: petraPubKey);
    final nonce = pine.PineNaClUtils.randombytes(24);
    final encrypted = box.encrypt(utf8.encode(innerBase64), nonce: nonce);

    final pubKey = await _myKeyPair!.extractPublicKey();
    final myPubKeyHex = _bytesToHex(Uint8List.fromList(pubKey.bytes));

    final finalRequest = {
      "appInfo": {"name": "Meeiro", "domain": "https://meeiro.io"},
      "dappEncryptionPublicKey": myPubKeyHex,
      "nonce": _bytesToHex(Uint8List.fromList(nonce)),
      "payload": _bytesToHex(Uint8List.fromList(encrypted.cipherText)),
      "redirectLink": "meeiro://api/v1/stake_mee", 
    };

    final dataParam = base64.encode(utf8.encode(jsonEncode(finalRequest)));
    final url = Uri.parse("petra://api/v1/signAndSubmit?data=$dataParam");

    await launchUrl(url, mode: LaunchMode.externalApplication);
  } catch (e) {
    debugPrint("Stake MEE Error: $e");
  }
}

Future<void> _unstakeMee(int unstakeType) async {
  if (_myKeyPair == null) return;

  try {
    // 1. Извлекаем число из строки (например, "92 504,83")
     String cleanValue = meeBalanceText2.replaceAll(' ', '').replaceAll(',', '.');
    double actualValue = double.tryParse(cleanValue) ?? 0.0;
    
    // double actualValue = meeStaked;

    if (actualValue <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("В стейкинге: $actualValue. ❌ Нечего выводить."),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    // 2. Расчет в Octas (8 знаков после запятой)
    // 1 MEE = 100,000,000 Octas
    int decimals = 6;
    
    // Переводим double в целое число Octas
    BigInt totalInOctas = BigInt.from((actualValue * 1000000).round());

    // ВЫЧИТАЕМ ЗАПАС: 0.0001 MEE (это 10,000 Octas)
    BigInt buffer = BigInt.from(1); 
    BigInt finalAmount = totalInOctas; /* - buffer; */


    // Если баланс меньше буфера, выводим 0 (чтобы не уйти в минус)
    if (finalAmount < BigInt.zero) finalAmount = BigInt.zero;

    final String rawAmount = finalAmount.toString();
    
    debugPrint("--- DEBUG UNSTAKE ---");
    debugPrint("Отображалось на экране: $actualValue");
    debugPrint("Сумма в Octas (с вычетом 0.000001): $rawAmount");

    // 3. Получение ключей Petra
    final prefs = await SharedPreferences.getInstance();
    final petraKeyHex = prefs.getString('petra_saved_pub_key');
    final savedPrivKey = prefs.getString('petra_temp_priv_key');

    if (petraKeyHex == null || savedPrivKey == null) {
      throw "Ключи кошелька не найдены";
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
        rawAmount, 
        unstakeType.toString() 
      ],
    };

    // 5. Шифрование для Petra
    final innerJsonString = jsonEncode(txObject);
    final innerBase64 = base64.encode(utf8.encode(innerJsonString));

    final box = pine.Box(myPrivateKey: myPrivKey, theirPublicKey: petraPubKey);
    final nonce = pine.PineNaClUtils.randombytes(24);
    final encrypted = box.encrypt(utf8.encode(innerBase64), nonce: nonce);

    final pubKey = await _myKeyPair!.extractPublicKey();
    final myPubKeyHex = _bytesToHex(Uint8List.fromList(pubKey.bytes));

    final finalRequest = {
      "appInfo": {"name": "Meeiro", "domain": "https://meeiro.io"},
      "dappEncryptionPublicKey": myPubKeyHex,
      "nonce": _bytesToHex(Uint8List.fromList(nonce)),
      "payload": _bytesToHex(Uint8List.fromList(encrypted.cipherText)),
      "redirectLink": "meeiro://api/v1/unstake_mee_main", 
    };

    // 6. Отправка в Petra Wallet
    final dataParam = base64.encode(utf8.encode(jsonEncode(finalRequest)));
    final url = Uri.parse("petra://api/v1/signAndSubmit?data=$dataParam");

    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } else {
      throw "Не удалось запустить Petra Wallet";
    }

  } catch (e) {
    debugPrint("Unstake Error: $e");
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("Ошибка: $e")),
    );
  }
}

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
  if (_myKeyPair == null) return;

  /*
  // Проверка: есть ли активный вывод для отмены
  if (meeUnstaking <= 0) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("❌ У вас нет активных заявок на вывод")),
    );
    return;
  }
  */

  final prefs = await SharedPreferences.getInstance();
  final petraKeyHex = prefs.getString('petra_saved_pub_key');
  final savedPrivKey = prefs.getString('petra_temp_priv_key');

  if (petraKeyHex == null || savedPrivKey == null) return;

  try {
    final myPrivKey = pine.PrivateKey(base64.decode(savedPrivKey));
    final petraPubKey = pine.PublicKey(_hexToBytes(petraKeyHex));

    const meeType = "0xe9c192ff55cffab3963c695cff6dbf9dad6aff2bb5ac19a6415cad26a81860d9::mee_coin::MeeCoin";

    final txObject = {
      "function": "0x514cfb77665f99a2e4c65a5614039c66d13e00e98daf4c86305651d29fd953e5::Staking::cancel_unstake",
      "type": "entry_function_payload",
      "type_arguments": [meeType, meeType],
      "arguments": [], // Аргументы не нужны
    };

    final innerJsonString = jsonEncode(txObject);
    final innerBase64 = base64.encode(utf8.encode(innerJsonString));

    final box = pine.Box(myPrivateKey: myPrivKey, theirPublicKey: petraPubKey);
    final nonce = pine.PineNaClUtils.randombytes(24);
    final encrypted = box.encrypt(utf8.encode(innerBase64), nonce: nonce);

    final pubKey = await _myKeyPair!.extractPublicKey();
    final myPubKeyHex = _bytesToHex(Uint8List.fromList(pubKey.bytes));

    final finalRequest = {
      "appInfo": {"name": "Meeiro", "domain": "https://meeiro.io"},
      "dappEncryptionPublicKey": myPubKeyHex,
      "nonce": _bytesToHex(Uint8List.fromList(nonce)),
      "payload": _bytesToHex(Uint8List.fromList(encrypted.cipherText)),
      "redirectLink": "meeiro://api/v1/cancel_unstake_mee", 
    };

    final dataParam = base64.encode(utf8.encode(jsonEncode(finalRequest)));
    final url = Uri.parse("petra://api/v1/signAndSubmit?data=$dataParam");

    await launchUrl(url, mode: LaunchMode.externalApplication);
  } catch (e) {
    debugPrint("Cancel Unstake Error: $e");
  }
}

Future<void> _withdrawMee() async {
  if (_myKeyPair == null) return;

  final prefs = await SharedPreferences.getInstance();
  final petraKeyHex = prefs.getString('petra_saved_pub_key');
  final savedPrivKey = prefs.getString('petra_temp_priv_key');

  if (petraKeyHex == null || savedPrivKey == null) return;

  try {
    final myPrivKey = pine.PrivateKey(base64.decode(savedPrivKey));
    final petraPubKey = pine.PublicKey(_hexToBytes(petraKeyHex));

    const meeType = "0xe9c192ff55cffab3963c695cff6dbf9dad6aff2bb5ac19a6415cad26a81860d9::mee_coin::MeeCoin";

    final txObject = {
      "function": "0x514cfb77665f99a2e4c65a5614039c66d13e00e98daf4c86305651d29fd953e5::Staking::withdraw",
      "type": "entry_function_payload",
      "type_arguments": [meeType, meeType],
      "arguments": [], // Аргументы не нужны
    };

    final innerJsonString = jsonEncode(txObject);
    final innerBase64 = base64.encode(utf8.encode(innerJsonString));

    final box = pine.Box(myPrivateKey: myPrivKey, theirPublicKey: petraPubKey);
    final nonce = pine.PineNaClUtils.randombytes(24);
    final encrypted = box.encrypt(utf8.encode(innerBase64), nonce: nonce);

    final pubKey = await _myKeyPair!.extractPublicKey();
    final myPubKeyHex = _bytesToHex(Uint8List.fromList(pubKey.bytes));

    final finalRequest = {
      "appInfo": {"name": "Meeiro", "domain": "https://meeiro.io"},
      "dappEncryptionPublicKey": myPubKeyHex,
      "nonce": _bytesToHex(Uint8List.fromList(nonce)),
      "payload": _bytesToHex(Uint8List.fromList(encrypted.cipherText)),
      "redirectLink": "meeiro://api/v1/withdraw_mee_final", 
    };

    final dataParam = base64.encode(utf8.encode(jsonEncode(finalRequest)));
    final url = Uri.parse("petra://api/v1/signAndSubmit?data=$dataParam");

    await launchUrl(url, mode: LaunchMode.externalApplication);
  } catch (e) {
    debugPrint("Withdraw MEE Error: $e");
  }
}

/// конец mee

void _initDeepLinks() {
  _linkSubscription = _appLinks.uriLinkStream.listen((uri) {
    if (uri.scheme == 'meeiro') {
      if (uri.path.contains('connect')) {
        _handlePetraConnectResponse(uri);
      } 
      // Добавляем все наши новые пути: harvest, stake, claim, unstake, cancel
      else if (uri.path.contains('harvest') || 
               uri.path.contains('stake') || 
               uri.path.contains('claim') || 
               uri.path.contains('unstake') || 
               uri.path.contains('stake_mee') || 
               uri.path.contains('harvest_mee') ||
               uri.path.contains('unstake_mee_main') ||
               uri.path.contains('cancel_unstake_mee') ||
               uri.path.contains('withdraw_mee_final') ||
               uri.path.contains('cancel')) { 
        
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("✅ Транзакция отправлена! Обновляю данные..."),
            duration: Duration(seconds: 2),
          ),
        );

        // Запускаем обновление данных через 2 секунды, 
        // чтобы блокчейн успел обработать транзакцию
        Future.delayed(const Duration(seconds: 2), () {
          _runUpdateThread(); 
        });
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

/*
  Future<void> _saveWalletAddress(String address, {bool isPetra = false}) async {
    final prefs = await SharedPreferences.getInstance();
    
    // Сохраняем текущий адрес
    await prefs.setString(walletKey, address);

    if (isPetra) {
      // Если зашли через Petra — запоминаем этот адрес как "эталон"
      await prefs.setString(lastPetraAddressKey, address);
      setState(() => isPetraConnected = true);
    } else {
      // Если ввели руками — проверяем, не тот ли это адрес, что был в Petra
      String? lastPetra = prefs.getString(lastPetraAddressKey);
      bool matches = (lastPetra != null && lastPetra == address && address != defaultExampleAddress);
      
      setState(() => isPetraConnected = matches);
    }
  }
*/

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
    String displayAddress = "${currentWalletAddress.substring(0, 6)}...${currentWalletAddress.substring(currentWalletAddress.length - 4)}";
    if (currentWalletAddress == defaultExampleAddress) {
      walletLabelText = "Кошелек: $displayAddress (Смените на свой!)";
      walletLabelColor = Colors.green[400]!;
    } else {
      walletLabelText = "Кошелек: $displayAddress";
      walletLabelColor = Colors.greenAccent;
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
      debugPrint("Bybit APT price fetch error: $e");
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
      debugPrint("Pool reserves fetch error: $e");
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
                          const Text("ТЕКУЩАЯ ЦЕНА:", style: TextStyle(color: Colors.cyanAccent, fontSize: 10, fontWeight: FontWeight.bold)),
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
                        // return _AnimatedMegaChart(currentPrice: 0.05); // тест
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
                              : () => _launchMegaUrl(
                                  context,
                                  "https://explorer.aptoslabs.com/account/0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3/modules/run/mega_coin/harvest10?network=mainnet",
                                ),
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
                              : () => _launchMegaUrl(
                                  context,
                                  "https://explorer.aptoslabs.com/account/0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3/modules/run/mega_coin/harvest?network=mainnet",
                                ),
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
                              : () => _launchMegaUrl(
                                  context,
                                  "https://explorer.aptoslabs.com/account/0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3/modules/run/mega_coin/harvest100?network=mainnet",
                                ),
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
  return 8;  // Дефолт на 8, как в вашем коде
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
      // BigInt unlockingAmountRaw = BigInt.parse(meeStakeData["unlocking_amount"] ?? "0");
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
          debugPrint("Error parsing MEGA stake: $e");
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
    // meeRewardText = "${meeCurrentReward.toStringAsFixed(8)} \$MEE (\$$rewardUsd)".replaceAll(".", ",");
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
    debugPrint("Update error: $e");
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
            const Text("Скорость майнинга напрямую зависит от вашего "),
            const Text("личного баланса монет \$MEE ", style: TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold, fontStyle: FontStyle.italic)),
            const Text("в майнере и общего пула нагар."),
            const SizedBox(height: 15),
            const Text("Примерные показатели:", style: TextStyle(fontWeight: FontWeight.bold, decoration: TextDecoration.underline)),
            const SizedBox(height: 10),
            _infoRow("🔹 1 000 MEE", "~0.000004 MEE/с"),
            _infoRow("🔹 10 000 MEE", "~0.00004 MEE/с"),
            _infoRow("🔹 100 000 MEE", "~0.0004 MEE/с"),
            const SizedBox(height: 15),
            const Text("Чем больше монет вы отправили в майнинг, тем ", style: TextStyle(fontSize: 13)),
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
            TextSpan(text: "Майнер MEE - MEGA ", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blueAccent)),
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
            TextSpan(text: "Майнинг реализован через официальные смарт-контракты проекта."),
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
                      megaRateText          = "Доходность: 15% APR (0,00 MEGA/сек)";
                      megaStakedAmountRaw   = BigInt.zero;
                      megaLastUpdate        = BigInt.zero;
                      megaUnlockTime        = BigInt.zero;
                      isMegaUnlockComplete  = false;
                      unlockingAmount       = 0.0;          
                      isUnlockComplete      = false;

                      _updateWalletLabelText(); 
                    });

                    // ВЫЗЫВАЕМ ОДИН РАЗ И ПРАВИЛЬНО:
                    // Передаем trimmed (текст из поля) и явно говорим, что это ручной ввод
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
      backgroundColor: const Color(0xFF0D1F2D), // глубокий тёмно-синий, как в других диалогах
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Colors.greenAccent, width: 1.5),
      ),
      title: const Column(
        children: [
          Text(
            "💎 МАЙНИНГ \$MEGA — как это работает",
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

            // Важное примечание внизу
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
        "title": "⚠️ Вывод из майнинга",
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
      body: SafeArea(
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
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 10),
                  child: Text("МАЙНИНГ \$MEE-\$MEGA (APTOS)", 
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.blueAccent, fontSize: 15, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
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
                          // Оборачиваем текст адреса в Flexible, чтобы он не выталкивал кнопку
                          Flexible(
                            child: Text(
                              // Показываем короткую версию, если это дефолтный адрес
                              currentWalletAddress == defaultExampleAddress 
                                ? "Demo Wallet" 
                                : "${currentWalletAddress.substring(0, 6)}...${currentWalletAddress.substring(currentWalletAddress.length - 4)}",
                              style: TextStyle(fontSize: 13, color: walletLabelColor, fontWeight: FontWeight.bold),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
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
                                      fontSize: 11,
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
                      // Text(onChainBalancesText, style: const TextStyle(fontSize: 13, color: Colors.white70, fontWeight: FontWeight.w500)),
                     

                      Text.rich(
                        TextSpan(
                          style: const TextStyle(fontSize: 13, color: Colors.white70, fontWeight: FontWeight.w500),
                          children: [
                            // --- APT ---
                            const TextSpan(text: "\$APT", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                            TextSpan(text: ": ${aptOnChain.toStringAsFixed(8)}", style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                            const TextSpan(text: " (", style: TextStyle(color: Colors.greenAccent)),
                            TextSpan(text: "\$${priceApt}", style: const TextStyle(color: Colors.greenAccent)),
                            const TextSpan(text: " / ", style: TextStyle(color: Colors.greenAccent)),
                            TextSpan(text: "\$${(aptOnChain * priceApt).toStringAsFixed(4)}", style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.greenAccent)),
                            const TextSpan(text: ") ", style: TextStyle(color: Colors.greenAccent)),
                            
                            // Разделитель
                            const TextSpan(text: "| ", style: TextStyle(color: Colors.blue, fontWeight: FontWeight.bold)),
                            
                            // --- MEE ---
                            const TextSpan(text: "\$MEE", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                            TextSpan(text: ": ${meeOnChain.toStringAsFixed(6)}", style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                            const TextSpan(text: " (", style: TextStyle(color: Colors.greenAccent)),
                            TextSpan(text: "\$${priceMee.toStringAsFixed(6)}", style: const TextStyle(color: Colors.greenAccent)),
                            const TextSpan(text: " / ", style: TextStyle(color: Colors.greenAccent)),
                            TextSpan(text: "\$${(meeOnChain * priceMee).toStringAsFixed(6)}", style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.greenAccent)),
                            const TextSpan(text: ") ", style: TextStyle(color: Colors.greenAccent)),

                            // Разделитель
                            const TextSpan(text: "| ", style: TextStyle(color: Colors.blue, fontWeight: FontWeight.bold)),

                            // --- MEGA ---
                            const TextSpan(text: "\$MEGA", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                            TextSpan(text: ": ${megaOnChain.toStringAsFixed(2)}", style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                            const TextSpan(text: " (", style: TextStyle(color: Colors.greenAccent)),
                            TextSpan(text: "${_getMegaCurrentPrice().toStringAsFixed(6)}", style: const TextStyle(color: Colors.greenAccent)),
                            const TextSpan(text: " / ", style: TextStyle(color: Colors.greenAccent)),
                            TextSpan(text: "\$${(megaOnChain * _getMegaCurrentPrice() * priceApt).toStringAsFixed(4)}", style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.greenAccent)),
                            const TextSpan(text: ")", style: TextStyle(color: Colors.greenAccent)),
                          ],
                        ),
                      ),


                      const SizedBox(height: 8),
                      SizedBox(width: double.infinity, height: 35, child: ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.blueGrey.shade900, foregroundColor: Colors.white),
                        onPressed: _openCustomEditWalletDialog, child: const Text("Сменить кошелек", style: TextStyle(fontSize: 12)),
                      ))
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
                          const Text("МАЙНИНГ \$MEE:",
                              style: TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold, fontSize: 13)),
                        /*  ElevatedButton(
                            onPressed: () => _showModalAndOpenUrl("Unstake", unstakeBaseUrl),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFDC143C),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                              minimumSize: const Size(80, 25),
                            ),
                            child: const Text("ЗАБРАТЬ \$MEE", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                          ),*/
                           ElevatedButton(
                            onPressed: () {
                              if (isPetraConnected) {
                                // Если кошелек подключен — показываем выбор типа
                                _showUnstakeChoiceDialog();
                              } else {
                                // Если нет — стандартное окно со ссылкой в браузер
                                _showModalAndOpenUrl(
                                  "Unstake", 
                                  "https://explorer.aptoslabs.com/account/0x514cfb77665f99a2e4c65a5614039c66d13e00e98daf4c86305651d29fd953e5/modules/run/Staking/unstake?network=mainnet"
                                );
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
                          /*ElevatedButton(
                            onPressed: () => _showModalAndOpenUrl("Stake", addMeeUrl),
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.blue.shade700, foregroundColor: Colors.white),
                            child: const Text("Добавить \$MEE", style: TextStyle(fontSize: 12)),
                          )*/
                          ElevatedButton(
                            onPressed: () {
                              if (isPetraConnected) {
                                _stakeMee();
                              } else {
                                _showModalAndOpenUrl(
                                  "Stake", 
                                  "https://explorer.aptoslabs.com/account/0x514cfb77665f99a2e4c65a5614039c66d13e00e98daf4c86305651d29fd953e5/modules/run/Staking/stake?network=mainnet"
                                );
                              }
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.green.shade700, 
                              foregroundColor: Colors.white,
                              // Если нужно, добавь сюда padding или форму как в других кнопках
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
                                      launchUrl(Uri.parse("https://explorer.aptoslabs.com/account/0x514cfb77665f99a2e4c65a5614039c66d13e00e98daf4c86305651d29fd953e5/modules/run/Staking/withdraw?network=mainnet"));
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
 
                            /* 
                            // ТЕСТОВАЯ КНОПКА (БЕЗ ПРОВЕРКИ ВРЕМЕНИ)
                            if (isPetraConnected) 
                              Padding(
                                padding: const EdgeInsets.only(top: 8.0),
                                child: ElevatedButton(
                                  onPressed: () => _withdrawMee(), // Вызывает функцию напрямую
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.blueGrey.shade700,
                                    foregroundColor: Colors.white70,
                                    minimumSize: const Size(80, 25),
                                  ),
                                  child: const Text(
                                    "ТЕСТ: ВЫВЕСТИ СЕЙЧАС (БЕЗ ОЖИДАНИЯ)", 
                                    style: TextStyle(fontSize: 9, fontWeight: FontWeight.normal)
                                  ),
                                ),
                              ),
                              */


                            // Кнопка ОТМЕНИТЬ
                            TextButton(
                              onPressed: () async {
                                if (isPetraConnected) {
                                  // Если Petra подключена — вызываем функцию для кошелька
                                  _cancelUnstakeMee();
                                } else {
                                  // Если не подключена — старая логика с копированием и браузером
                                  await Clipboard.setData(const ClipboardData(
                                      text: "0xe9c192ff55cffab3963c695cff6dbf9dad6aff2bb5ac19a6415cad26a81860d9::mee_coin::MeeCoin"));
                                  
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text("Адрес контракта скопирован в буфер"),
                                      duration: Duration(seconds: 3),
                                    ),
                                  );

                                  launchUrl(Uri.parse(
                                      "https://explorer.aptoslabs.com/account/0x514cfb77665f99a2e4c65a5614039c66d13e00e98daf4c86305651d29fd953e5/modules/run/Staking/cancel_unstake?network=mainnet"));
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
                      Row(children: [
                        const Text("НАГРАДА \$MEE:", style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 13)),
                        const SizedBox(width: 8),
                        Text(rewardTickerText),
                      ]),
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
                          /*
                          ElevatedButton(
                            onPressed: () => _showModalAndOpenUrl("Harvest", harvestBaseUrl),
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.green.shade700, foregroundColor: Colors.white), 
                            child: const Text("ЗАБРАТЬ НАГРАДУ", style: TextStyle(fontSize: 10))
                          )*/

                          ElevatedButton(
                            onPressed: () {
                              if (isPetraConnected) {
                                // 1. Если кошелек подключен, сразу запускаем транзакцию в Petra
                                _harvestMee();
                              } else {
                                // 2. Если не подключен, показываем старое окно с кнопкой перехода в браузер
                                _showModalAndOpenUrl("Harvest", harvestBaseUrl);
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
                          const Text("МАЙНИНГ \$MEGA:", 
                            style: TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold, fontSize: 13)),
                          Row(
                            children: [
                              // КРУГЛАЯ КНОПКА СПРАВКИ
                              GestureDetector(
                                onTap: _showMegaHelp,
                                child: Container(
                                  padding: const EdgeInsets.all(4),
                                  decoration: const BoxDecoration(
                                    color: Color(0xFFDC143C),
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(Icons.help_outline, color: Colors.white, size: 16),
                                ),
                              ),
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
                                    const url = "https://explorer.aptoslabs.com/account/0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3/modules/run/mega_coin/unstake_request?network=mainnet";
                                    if (await canLaunchUrl(Uri.parse(url))) {
                                      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
                                    }
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
                                const url = "https://explorer.aptoslabs.com/account/0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3/modules/run/mega_coin/stake_all?network=mainnet";
                                final uri = Uri.parse(url);
                                if (await canLaunchUrl(uri)) {
                                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                                }
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
                // --- СЕКЦИЯ $MEGA: НАГРАДА (ЗЕЛЁНЫЙ) --- (удалил дубликат, оставил только обновлённый)
                _buildSection(
                  bg: const Color(0xFF0D3523), 
                  borderColor: Colors.green.shade900,
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text("НАГРАДА \$MEGA:", style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 13)),
                              Text(
                                megaRewardText, 
                                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.greenAccent),
                                overflow: TextOverflow.ellipsis,  
                                maxLines: 1,                     
                              ),
                            ],
                          ),
                          ElevatedButton(
                            onPressed: () async {
                              // 1. ПРОВЕРКА: Если Petra подключена, вызываем функцию напрямую
                              if (isPetraConnected) {
                                _claimRewards(); 
                              } 
                              // 2. Если не подключена — открываем браузер (ваш старый код)
                              else {
                                const url = "https://explorer.aptoslabs.com/account/0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3/modules/run/mega_coin/claim_staking_rewards?network=mainnet";
                                final uri = Uri.parse(url);
                                if (await canLaunchUrl(uri)) {
                                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                                }
                              }
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.green.shade700, 
                              foregroundColor: Colors.white,
                            ), 
                            child: const Text("ЗАБРАТЬ НАГРАДУ", style: TextStyle(fontSize: 10)),
                          )
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween, 
                        children: [
                          Text(
                            megaRateText, 
                            style: const TextStyle(fontSize: 10, color: Colors.blueAccent),
                            overflow: TextOverflow.ellipsis,  
                            maxLines: 1,                      
                          ),
                        ]
                      ),




                      // НОВЫЙ БЛОК: UNSTAKE ДЛЯ $MEGA (если unlocking)
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

                            // Кнопка ЗАВЕРШИТЬ ВЫВОД
                            // Кнопка ЗАВЕРШИТЬ ВЫВОД
                            ElevatedButton(
                              onPressed: isMegaUnlockComplete 
                                ? () {
                                    if (isPetraConnected) {
                                      _unstakeConfirm();  // Вызов через Petra (то, что вы хотите протестировать)
                                      ScaffoldMessenger.of(context).showSnackBar(  // Для отладки: Покажите сообщение
                                        const SnackBar(content: Text("unstake_confirm через Petra")),
                                      );
                                    } else {
                                      // Если Petra не подключена — открываем браузер (как раньше)
                                      launchUrl(Uri.parse("https://explorer.aptoslabs.com/account/0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3/modules/run/mega_coin/unstake_confirm?network=mainnet"), 
                                        mode: LaunchMode.externalApplication);
                                      ScaffoldMessenger.of(context).showSnackBar(  // Для отладки
                                        const SnackBar(content: Text("unstake_confirm через браузер")),
                                      );
                                    }
                                  } 
                                : null,  // Кнопка заблокирована, если таймер не вышел (но в тесте он "вышел")
                              style: ElevatedButton.styleFrom(
                                backgroundColor: isMegaUnlockComplete ? Colors.green : Colors.grey.shade800,
                                disabledBackgroundColor: Colors.white10,
                              ),
                              child: Text(isMegaUnlockComplete ? "ЗАВЕРШИТЬ ВЫВОД \$MEGA" : "ОЖИДАНИЕ ВЫВОДА...", 
                                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                            ),



                            // Кнопка ОТМЕНИТЬ (с поддержкой Petra)
                            TextButton(
                              onPressed: () async {
                                // 1. Если Petra подключена — вызываем функцию отмены напрямую
                                if (isPetraConnected) {
                                  _cancelUnstake();
                                } 
                                // 2. Если нет — открываем ссылку в браузере (ваш текущий код)
                                else {
                                  const url = "https://explorer.aptoslabs.com/account/0x350f1f65a2559ad37f95b8ba7c64a97c23118856ed960335fce4cd222d5577d3/modules/run/mega_coin/cancel_unstake?network=mainnet";
                                  await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
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
                  )
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


// ВСТАВЛЯТЬ СТРОГО ОДИН РАЗ В КОНЕЦ ФАЙЛА
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

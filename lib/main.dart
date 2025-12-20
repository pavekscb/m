import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

// --- КОНСТАНТЫ ПРИЛОЖЕНИЯ И ВЕРСИИ ---
const String currentVersion = "1.0.2";
const String urlGithubApi = "https://api.github.com/repos/pavekscb/m/releases/latest";

// --- Файл и Константы для адреса кошелька ---
const String walletKey = "WALLET_ADDRESS"; // Ключ для SharedPreferences вместо файла
const String defaultExampleAddress = "0x9ba27fc8a65ba4507fc4cca1b456e119e4730b8d8cfaf72a2a486e6d0825b27b";
const int rawDataCorrectionFactor = 100;

// --- Константы Сети ---
const int decimals = 8;
const int accPrecision = 100000000000; // 10^11
const int updateIntervalSeconds = 60;

const String meeCoinT0T1 = "0xe9c192ff55cffab3963c695cff6dbf9dad6aff2bb5ac19a6415cad26a81860d9::mee_coin::MeeCoin";
const String aptCoinType = "0x1::aptos_coin::AptosCoin";

const String aptLedgerUrl = "https://fullnode.mainnet.aptoslabs.com/v1";
const String harvestBaseUrl = "https://explorer.aptoslabs.com/account/0x514cfb77665f99a2e4c65a5614039c66d13e00e98daf4c86305651d29fd953e5/modules/run/Staking/harvest?network=mainnet";
const String addMeeUrl = "https://explorer.aptoslabs.com/account/0x514cfb77665f99a2e4c65a5614039c66d13e00e98daf4c86305651d29fd953e5/modules/run/Staking/stake?network=mainnet";
const String unstakeBaseUrl = "https://explorer.aptoslabs.com/account/0x514cfb77665f99a2e4c65a5614039c66d13e00e98daf4c86305651d29fd953e5/modules/run/Staking/unstake?network=mainnet";

// КОНСТАНТЫ: Ссылки для кнопок
const String urlSource = "https://github.com/pavekscb/m";
const String urlSite = "https://meeiro.xyz/staking";
const String urlGraph = "https://dexscreener.com/aptos/pcs-167";
// Формируем URL динамически в коде, но база здесь
const String urlSwapBase = "https://aptos.pancakeswap.finance/swap?outputCurrency=0x1%3A%3Aaptos_coin%3A%3AAptosCoin&inputCurrency=";
const String urlSwapEarnium = "https://app.panora.exchange/swap/aptos?pair=MEE-APT";
const String urlSupport = "https://t.me/cripto_karta";

void main() {
  runApp(const MeeiroApp());
}

class MeeiroApp extends StatelessWidget {
  const MeeiroApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MEE Mining',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.blue,
        scaffoldBackgroundColor: const Color(0xFFFFFFFF),
        fontFamily: 'Arial', // Используем системный, но стиль сохраняем
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
  // --- Переменные состояния ---
  String currentWalletAddress = defaultExampleAddress;
  double meeCurrentReward = 0.0;
  double meeRatePerSec = 0.0;
  int countdownVal = updateIntervalSeconds;
  bool isRunning = false;
  
  // Анимация
  final List<String> animationFrames = ['🌱', '🌿', '💰'];
  int currentFrameIndex = 0;
  String rewardTickerText = "[Загрузка]";
  Timer? simulationTimer;

  // Данные для отображения
  String walletLabelText = "Кошелек: Загрузка...";
  Color walletLabelColor = Colors.black;
  String onChainBalancesText = "Загрузка балансов...";
  String meeBalanceText = "0,00000000 \$MEE";
  String meeRewardText = "0,00000000 \$MEE";
  String meeRateText = "Скорость: 0,00 MEE/сек";
  
  // Статус обновления
  String updateStatusText = "";
  Color updateStatusColor = const Color(0xFF666666);
  VoidCallback? updateAction;

  @override
  void initState() {
    super.initState();
    _startApp();
  }

  @override
  void dispose() {
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
      });

      if (countdownVal <= 0) {
        _runUpdateThread();
        countdownVal = updateIntervalSeconds;
      }
    });
  }

  // --- Логика сохранения/загрузки кошелька ---
  Future<void> _loadWalletAddress() async {
    final prefs = await SharedPreferences.getInstance();
    String? address = prefs.getString(walletKey);
    
    if (address != null && address.length == 66 && address.startsWith("0x")) {
      setState(() {
        currentWalletAddress = address;
        _updateWalletLabelText();
      });
    } else {
      _saveWalletAddress(defaultExampleAddress);
      setState(() {
        currentWalletAddress = defaultExampleAddress;
        _updateWalletLabelText();
      });
    }
  }

  Future<void> _saveWalletAddress(String address) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(walletKey, address);
  }

  void _updateWalletLabelText() {
    String displayAddress = "${currentWalletAddress.substring(0, 6)}...${currentWalletAddress.substring(currentWalletAddress.length - 4)}";
    if (currentWalletAddress == defaultExampleAddress) {
      walletLabelText = "Кошелек: $displayAddress (ПРИМЕР)";
      walletLabelColor = Colors.orange.shade800; // darkorange equivalent
    } else {
      walletLabelText = "Кошелек: $displayAddress";
      walletLabelColor = Colors.purple;
    }
  }

  // --- Логика API и расчетов ---
  
  Future<int> _getRawBalance(String coinType) async {
    try {
      final url = Uri.parse("$aptLedgerUrl/accounts/$currentWalletAddress/balance/$coinType");
      final response = await http.get(url, headers: {"Accept": "application/json, application/x-bcs"});
      if (response.statusCode == 200) {
        return int.parse(response.body);
      }
    } catch (e) {
      // ignore
    }
    return 0;
  }

  Future<int> _getCoinDecimals(String coinType) async {
    try {
      String moduleAddress = coinType.split("::")[0];
      final url = Uri.parse("$aptLedgerUrl/accounts/$moduleAddress/resource/0x1::coin::CoinInfo<$coinType>");
      final response = await http.get(url).timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return int.parse(data["data"]["decimals"]);
      }
    } catch (e) {
      // ignore
    }
    return 8;
  }

  Future<int?> _fetchLedgerTimestamp() async {
    try {
      final response = await http.get(Uri.parse(aptLedgerUrl)).timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return int.parse(data["ledger_timestamp"]) ~/ 1000000;
      }
    } catch (e) {
      return null;
    }
    return null;
  }

  Future<dynamic> _fetchData(String apiUrl) async {
    try {
      final response = await http.get(Uri.parse(apiUrl)).timeout(const Duration(seconds: 5));
      if (response.statusCode == 404) {
        if (apiUrl.contains("StakeInfo")) {
          return {"amount": "0", "reward_amount": "0", "reward_debt": "0"};
        }
        return null;
      }
      if (response.statusCode == 200) {
        final jsonResponse = json.decode(response.body);
        return jsonResponse["data"];
      }
    } catch (e) {
      return null;
    }
    return null;
  }

  Future<void> _runUpdateThread() async {
    // 1. On-chain balances
    double aptVal = 0;
    double meeVal = 0;
    
    try {
      int aptRaw = await _getRawBalance(aptCoinType);
      aptVal = aptRaw / 1e8;
      
      int meeDec = await _getCoinDecimals(meeCoinT0T1);
      int meeRaw = await _getRawBalance(meeCoinT0T1);
      meeVal = meeRaw / (BigInt.from(10).pow(meeDec).toDouble());
    } catch (e) {
      aptVal = 0;
      meeVal = 0;
    }

    // 2. Staking API URLs
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

    // Calculate Reward & Balance
    double? stakeBalance;
    double? totalRewardFloat;
    
    try {
      BigInt amount = BigInt.parse(meeStakeData["amount"]) * BigInt.from(rawDataCorrectionFactor);
      BigInt rewardAmount = BigInt.parse(meeStakeData["reward_amount"]) * BigInt.from(rawDataCorrectionFactor);
      BigInt rewardDebt = BigInt.parse(meeStakeData["reward_debt"]) * BigInt.from(rawDataCorrectionFactor);

      if (amount == BigInt.zero) {
        stakeBalance = 0.0;
        totalRewardFloat = 0.0;
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
    } catch (e) {
      stakeBalance = null;
    }

    // Calculate Rate
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
    } catch (e) {
       meeRate = 0.0;
    }

    _updateUI(stakeBalance, totalRewardFloat, meeRate, aptVal, meeVal);
  }

  void _updateUI(double? balance, double? reward, double rate, double aptOnChain, double meeOnChain) {
    if (!mounted) return;
    setState(() {
      onChainBalancesText = "Баланс кошелька: ${aptOnChain.toStringAsFixed(6)} APT | ${meeOnChain.toStringAsFixed(6)} MEE";
      
      if (balance == null || reward == null) {
        meeBalanceText = "Ошибка! Проверьте адрес или сеть.";
        meeRewardText = "Ошибка! Проверьте адрес или сеть.";
        meeRateText = "Скорость: Ошибка";
        rewardTickerText = "[ОШИБКА]";
        isRunning = false;
        return;
      }

      meeRatePerSec = rate;
      meeCurrentReward = reward;

      meeBalanceText = "${balance.toStringAsFixed(8)} \$MEE".replaceAll(".", ",");
      meeRateText = "Скорость: ${meeRatePerSec.toStringAsFixed(12)} MEE/сек".replaceAll(".", ",");
      
      _updateRewardLabelsOnly();
      
      isRunning = true;
      countdownVal = updateIntervalSeconds;
    });
  }

  void _updateRewardLabelsOnly() {
    meeRewardText = "${meeCurrentReward.toStringAsFixed(8)} \$MEE".replaceAll(".", ",");
  }

  // --- Обновления ---
  Future<void> _checkUpdates({required bool manualCheck}) async {
    if (!manualCheck) {
      setState(() {
        updateStatusText = "Версия v$currentVersion [Проверка обновлений...]";
        updateStatusColor = const Color(0xFF666666);
        updateAction = null;
      });
    }

    try {
      final response = await http.get(Uri.parse(urlGithubApi)).timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        String latestVersionTag = data['tag_name'] ?? 'v0.0.0';
        String? downloadUrl = data['html_url'];
        
        String cleanLatest = latestVersionTag.replaceAll('v', '').trim();
        List<int> currentParts = currentVersion.split('.').map(int.parse).toList();
        List<int> newParts = cleanLatest.split('.').map(int.parse).toList();
        
        bool isNewer = false;
        for(int i=0; i<3; i++) {
           if (newParts[i] > currentParts[i]) { isNewer = true; break; }
           if (newParts[i] < currentParts[i]) { break; }
        }

        if (isNewer && downloadUrl != null) {
           setState(() {
             updateStatusText = "НОВАЯ ВЕРСИЯ v$cleanLatest ДОСТУПНА! (Нажмите)";
             updateStatusColor = Colors.red;
             updateAction = () => _showUpdateModal(cleanLatest, downloadUrl);
           });
           _showUpdateModal(cleanLatest, downloadUrl);
        } else {
           if (manualCheck) {
             setState(() {
               updateStatusText = "Версия v$currentVersion (У вас самая последняя версия)";
               updateStatusColor = Colors.green.shade800; // darkgreen
               updateAction = null;
             });
           } else {
             setState(() {
               updateStatusText = "Версия v$currentVersion (Последняя. Проверить обновление.)";
               updateStatusColor = const Color(0xFF666666);
               updateAction = () => _manualUpdateCheck();
             });
           }
        }

      }
    } catch (e) {
      setState(() {
         updateStatusText = "Версия v$currentVersion [Ошибка проверки. Нажмите для повтора.]";
         updateStatusColor = Colors.red;
         updateAction = () => _manualUpdateCheck();
      });
    }
  }

  void _manualUpdateCheck() {
    setState(() {
       updateStatusText = "Версия v$currentVersion [Проверка обновлений...]";
       updateStatusColor = const Color(0xFF666666);
       updateAction = null;
    });
    _checkUpdates(manualCheck: true);
  }

  // --- Диалоговые окна ---
  
  void _openCustomEditWalletDialog() {
    TextEditingController controller = TextEditingController(text: currentWalletAddress);
    
    showDialog(context: context, builder: (context) {
      return AlertDialog(
        title: const Text("Сменить кошелек"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("Введите новый адрес кошелька (66 символов, 0x...):", style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            TextField(controller: controller, decoration: const InputDecoration(border: OutlineInputBorder())),
            const SizedBox(height: 5),
            ElevatedButton(
              onPressed: () async {
                  ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
                  if (data != null && data.text != null) {
                    controller.text = data.text!.trim();
                  }
              }, 
              child: const Text("Вставить из буфера")
            )
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context), 
            style: TextButton.styleFrom(backgroundColor: const Color(0xFFDC143C), foregroundColor: Colors.white),
            child: const Text("Отмена")
          ),
          TextButton(
            onPressed: () {
               String trimmed = controller.text.trim();
               if (trimmed.length == 66 && trimmed.startsWith("0x")) {
                 setState(() {
                   currentWalletAddress = trimmed;
                   isRunning = false;
                   meeCurrentReward = 0.0;
                   meeRatePerSec = 0.0;
                   _saveWalletAddress(trimmed);
                   _updateWalletLabelText();
                   _updateRewardLabelsOnly();
                 });
                 _runUpdateThread();
                 Navigator.pop(context);
                 _showCustomInfoModal("Обновление", "Адрес кошелька сохранен. Запускается обновление данных...");
               } else {
                 // Error
                 ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Ошибка: Неверный формат адреса.")));
               }
            }, 
            style: TextButton.styleFrom(backgroundColor: const Color(0xFF4CAF50), foregroundColor: Colors.white),
            child: const Text("Сохранить")
          ),
        ],
      );
    });
  }

  void _showCustomInfoModal(String title, String message) {
    showDialog(context: context, builder: (ctx) => AlertDialog(
      title: Text(title, style: const TextStyle(color: Color(0xFF1E90FF), fontWeight: FontWeight.bold)),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          style: TextButton.styleFrom(backgroundColor: const Color(0xFF4CAF50), foregroundColor: Colors.white),
          child: const Text("ОК"),
        )
      ],
    ));
  }
  
  void _showUpdateModal(String newVersion, String url) {
    showDialog(context: context, builder: (ctx) => AlertDialog(
      title: const Text("Доступно обновление!"),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text("🎉 Есть новая версия: v$newVersion!", style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 10),
          Text("Ваша текущая версия: v$currentVersion\nНажмите \"Скачать\" для перехода на страницу релиза.", textAlign: TextAlign.center),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text("Позже"),
        ),
        TextButton(
          onPressed: () {
            launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
            Navigator.pop(ctx);
          },
          style: TextButton.styleFrom(backgroundColor: const Color(0xFFFFCC00), foregroundColor: Colors.black),
          child: const Text("Скачать"),
        )
      ],
    ));
  }

  Future<void> _showModalAndOpenUrl(String action, String url) async {
    Map<String, Map<String, String>> instructions = {
      "Harvest": {
        "title": "✅ Контракт скопирован! Откройте страницу Harvest.",
        "text": "1. Подключите кошелек.\n2. Вставьте контракт \$MEE (он уже в буфере обмена) в поля T0 и T1.\n3. Нажмите RUN и подпишите транзакцию."
      },
      "Stake": {
        "title": "✅ Контракт скопирован! Откройте страницу Stake.",
        "text": "1. Подключите кошелек.\n2. Вставьте контракт \$MEE в поля T0 и T1.\n3. В поле \"arg0: u64\" введите сумму \$MEE для внесения, используя формат без десятичных знаков (1 MEE = 1000000).\n4. Нажмите RUN и подпишите транзакцию."
      },
      "Unstake": {
        "title": "⚠️ Готовы забрать \$MEE из стейкинга?",
        "text": "1. Контракт скопирован! Подключите кошелек.\n2. Вставьте контракт \$MEE в поля T0 и T1.\n3. В поле \"arg0: u64\" введите сумму \$MEE, которую хотите забрать (с +6 нулями).\n4. В поле \"arg1: u8\" введите тип вывода: 0: Обычный Unstake (15 дней разблокировки, затем `withdraw`). или 1: Мгновенный Unstake (комиссия 15%).\n5. Нажмите RUN и подпишите транзакцию."
      }
    };
    
    var data = instructions[action] ?? {"title": "Переход", "text": "Контракт скопирован."};
    
    await Clipboard.setData(const ClipboardData(text: meeCoinT0T1));
    
    if (!mounted) return;
    
    bool? result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(data["title"]!, style: const TextStyle(color: Color(0xFF1E90FF), fontWeight: FontWeight.bold)),
        content: Text(data["text"]!),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false), // Закрыть окно
            child: const Text("Отмена"), // Не было в Python, но нужно для Android UX (кнопка назад)
          ),
          TextButton(
             onPressed: () => Navigator.pop(ctx, true),
             style: TextButton.styleFrom(backgroundColor: const Color(0xFF4CAF50), foregroundColor: Colors.white),
             child: const Text("Открыть браузер"),
          )
        ],
      )
    );

    if (result == true) {
      launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    }
  }

  void _copyContract() {
    Clipboard.setData(const ClipboardData(text: meeCoinT0T1));
    _showCustomInfoModal("Копирование", "Контракт \$MEE успешно скопирован в буфер обмена!");
  }

  // --- Вспомогательные виджеты UI ---
  Widget _buildSection({required Color bg, required Color borderColor, required Widget child}) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 5),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: borderColor, width: 1),
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Заголовок
              const Padding(
                padding: EdgeInsets.only(bottom: 15),
                child: Text("МАЙНИНГ МОНЕТЫ \$MEE (APTOS)", 
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color(0xFF1E90FF), fontSize: 18, fontWeight: FontWeight.bold)),
              ),
              
              // --- Секция Кошелек ---
              _buildSection(
                bg: const Color(0xFFF0F0F0),
                borderColor: Colors.black, // solid default
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(walletLabelText, style: TextStyle(fontSize: 14, color: walletLabelColor)),
                    const SizedBox(height: 5),
                    Text(onChainBalancesText, style: const TextStyle(fontSize: 12, color: Color(0xFF555555))),
                    const SizedBox(height: 5),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black, elevation: 1),
                        onPressed: _openCustomEditWalletDialog,
                        child: const Text("Сменить кошелек"),
                      ),
                    )
                  ],
                )
              ),

              // --- Секция Баланс ---
               _buildSection(
                bg: const Color(0xFFE6F7FF),
                borderColor: const Color(0xFF8AC0E6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                     const Text("Баланс стейкинга \$MEE:", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                     const SizedBox(height: 5),
                     Row(
                       mainAxisAlignment: MainAxisAlignment.spaceBetween,
                       children: [
                         Expanded(child: Text(meeBalanceText, style: const TextStyle(fontSize: 16))),
                         ElevatedButton(
                           onPressed: () => _showModalAndOpenUrl("Stake", addMeeUrl),
                           style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1E90FF), foregroundColor: Colors.white),
                           child: const Text("Добавить \$MEE"),
                         )
                       ],
                     )
                  ],
                )
              ),

              // --- Секция Награда (Ключевая) ---
              _buildSection(
                bg: const Color(0xFFE6FFE6),
                borderColor: const Color(0xFF00CC00),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text("Награда (harvest):", style: TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(width: 5),
                        Text(rewardTickerText, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.green)),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Row(
                       mainAxisAlignment: MainAxisAlignment.spaceBetween,
                       children: [
                         Expanded(child: Text(meeRewardText, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.green))),
                         ElevatedButton(
                           onPressed: () => _showModalAndOpenUrl("Harvest", harvestBaseUrl),
                           style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF4CAF50), foregroundColor: Colors.white),
                           child: const Text("Забрать награду"),
                         )
                       ],
                     ),
                     const SizedBox(height: 5),
                     Text(meeRateText, style: const TextStyle(fontSize: 12, color: Color(0xFF666666))),
                  ],
                )
              ),

              // --- Секция Unstake ---
              _buildSection(
                bg: const Color(0xFFFFE6E6),
                borderColor: const Color(0xFFFF9999),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Expanded(child: Text("Вывод \$MEE из стейкинга:", style: TextStyle(fontWeight: FontWeight.bold))),
                    ElevatedButton(
                        onPressed: () => _showModalAndOpenUrl("Unstake", unstakeBaseUrl),
                        style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFDC143C), foregroundColor: Colors.white),
                        child: const Text("Забрать \$MEE"),
                    )
                  ],
                )
              ),

              // --- Секция Контракт ---
              _buildSection(
                bg: const Color(0xFFF9F9F9),
                borderColor: Colors.black, // solid default
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("Контракт \$MEE:", style: TextStyle(fontSize: 12, color: Color(0xFF888888))),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                         Expanded(child: Text(meeCoinT0T1, style: const TextStyle(fontSize: 10))),
                         TextButton(
                           onPressed: _copyContract,
                           child: const Text("Копировать"),
                         )
                      ],
                    )
                  ],
                )
              ),

              // --- Секция Ссылки ---
              GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                childAspectRatio: 3.5,
                children: [
                  _linkBtn("Исходный код", urlSource),
                  _linkBtn("Сайт", urlSite),
                  _linkBtn("График \$MEE", urlGraph),
                  _linkBtn("Обмен \$MEE/\$APT", "$urlSwapBase${Uri.encodeComponent(meeCoinT0T1)}"),
                  _linkBtn("Обмен \$MEE/APT (2)", urlSwapEarnium),
                  _linkBtn("Поддержка", urlSupport),
                ],
              ),
              
              // --- Статус ---
              const SizedBox(height: 10),
              GestureDetector(
                onTap: updateAction,
                child: Text(updateStatusText, 
                   textAlign: TextAlign.right,
                   style: TextStyle(color: updateStatusColor, fontSize: 12, fontWeight: updateStatusColor == Colors.red ? FontWeight.bold : FontWeight.normal)),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
  
  Widget _linkBtn(String text, String url) {
    return Container(
      margin: const EdgeInsets.all(4),
      child: ElevatedButton(
        onPressed: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFFFFFACD),
          foregroundColor: const Color(0xFF333333),
          side: const BorderSide(color: Color(0xFFFFCC00)),
          padding: EdgeInsets.zero,
        ),
        child: Text(text, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
      ),
    );
  }
}

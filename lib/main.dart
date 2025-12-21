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

const String walletKey = "WALLET_ADDRESS"; 
const String defaultExampleAddress = "0x9ba27fc8a65ba4507fc4cca1b456e119e4730b8d8cfaf72a2a486e6d0825b27b";
const int rawDataCorrectionFactor = 100;

// --- Константы Сети ---
const int decimals = 8;
const int accPrecision = 100000000000; 
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
  double meeRatePerSec = 0.0;
  int countdownVal = updateIntervalSeconds;
  bool isRunning = false;
  
  final List<String> animationFrames = ['🌱', '🌿', '💰'];
  int currentFrameIndex = 0;
  String rewardTickerText = "[Загрузка]";
  Timer? simulationTimer;

  String walletLabelText = "Кошелек: Загрузка...";
  Color walletLabelColor = Colors.black;
  String onChainBalancesText = "Загрузка балансов...";
  String meeBalanceText = "0,00000000 \$MEE";
  String meeRewardText = "0,00000000 \$MEE";
  String meeRateText = "Скорость: 0,00 MEE/сек";
  
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
      walletLabelColor = Colors.orange.shade800;
    } else {
      walletLabelText = "Кошелек: $displayAddress";
      walletLabelColor = Colors.purple;
    }
  }

  Future<int> _getRawBalance(String coinType) async {
    try {
      final url = Uri.parse("$aptLedgerUrl/accounts/$currentWalletAddress/balance/$coinType");
      final response = await http.get(url, headers: {"Accept": "application/json"});
      if (response.statusCode == 200) return int.parse(response.body);
    } catch (e) {}
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
    } catch (e) {}
    return 8;
  }

  Future<int?> _fetchLedgerTimestamp() async {
    try {
      final response = await http.get(Uri.parse(aptLedgerUrl)).timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return int.parse(data["ledger_timestamp"]) ~/ 1000000;
      }
    } catch (e) {}
    return null;
  }

  Future<dynamic> _fetchData(String apiUrl) async {
    try {
      final response = await http.get(Uri.parse(apiUrl)).timeout(const Duration(seconds: 5));
      if (response.statusCode == 404) {
        if (apiUrl.contains("StakeInfo")) return {"amount": "0", "reward_amount": "0", "reward_debt": "0"};
        return null;
      }
      if (response.statusCode == 200) return json.decode(response.body)["data"];
    } catch (e) {}
    return null;
  }

  Future<void> _runUpdateThread() async {
    double aptVal = 0; double meeVal = 0;
    try {
      int aptRaw = await _getRawBalance(aptCoinType);
      aptVal = aptRaw / 1e8;
      int meeDec = await _getCoinDecimals(meeCoinT0T1);
      int meeRaw = await _getRawBalance(meeCoinT0T1);
      meeVal = meeRaw / (BigInt.from(10).pow(meeDec).toDouble());
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
        String latestTag = data['tag_name'] ?? 'v0.0.0';
        String? downloadUrl = data['html_url'];
        
        // Удаляем любую букву v/V в начале, чтобы корректно сравнить цифры
        String cleanLatest = latestTag.replaceFirst(RegExp(r'[vV]'), '').trim();
        String cleanCurrent = currentVersion.replaceFirst(RegExp(r'[vV]'), '').trim();

        List<int> currentParts = cleanCurrent.split('.').map(int.parse).toList();
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
           if (!manualCheck) _showUpdateModal(cleanLatest, downloadUrl);
        } else {
           setState(() {
             updateStatusText = manualCheck ? "Версия v$currentVersion (У вас самая последняя версия)" : "Версия v$currentVersion (Последняя. Проверить обновление.)";
             updateStatusColor = manualCheck ? Colors.green.shade800 : const Color(0xFF666666);
             updateAction = () => _manualUpdateCheck();
           });
        }
      } else {
         throw Exception("Status code ${response.statusCode}");
      }
    } catch (e) {
      setState(() {
         updateStatusText = "Версия v$currentVersion [Ошибка проверки. Повторить.]";
         updateStatusColor = Colors.red;
         updateAction = () => _manualUpdateCheck();
      });
    }
  }

  void _manualUpdateCheck() => _checkUpdates(manualCheck: true);

  // --- ДИАЛОГОВЫЕ ОКНА ---

  void _showMiningInfo() {
    showDialog(context: context, builder: (ctx) => AlertDialog(
      title: const Text("О скорости майнинга", style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
      content: const Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("Скорость майнинга напрямую зависит от вашего личного баланса монет \$MEE в майнере и общего пула наград."),
          SizedBox(height: 10),
          Text("Примерные показатели:", style: TextStyle(fontWeight: FontWeight.bold)),
          Text("• При 1 000 MEE: ~0.000035 MEE/сек"),
          Text("• При 100 000 MEE: ~0.003500 MEE/сек"),
          SizedBox(height: 10),
          Text("Чем больше монет вы отправили в майнинг, тем выше ваша доля в распределении новых монет."),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Понятно")),
      ],
    ));
  }

  void _showAboutProject() {
    showDialog(context: context, builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      title: const Center(child: Text("🚀 О проекте MEE Miner", style: TextStyle(color: Color(0xFF1E90FF), fontWeight: FontWeight.bold))),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            RichText(text: const TextSpan(
              style: TextStyle(color: Colors.black, fontSize: 14),
              children: [
                TextSpan(text: "Майнер MEE", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blue)),
                TextSpan(text: " позволяет накапливать монету MEE даже при пополнении баланса майнера на "),
                TextSpan(text: "1 MEE", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.orange)),
                TextSpan(text: ".\n\n"),
                TextSpan(text: "💡 Бесплатные монеты:\n", style: TextStyle(fontWeight: FontWeight.bold)),
                TextSpan(text: "Вы можете попросить монету в чате поддержки — вам её пришлют бесплатно! Просто укажите свой кошелек.\n\n"),
                TextSpan(text: "⚙️ Процесс:\n", style: TextStyle(fontWeight: FontWeight.bold)),
                TextSpan(text: "После пополнения майнинг запустится автоматически.\n\n"),
                TextSpan(text: "⚠️ Важно:\n", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red)),
                TextSpan(text: "Для транзакций нужен "),
                TextSpan(text: "APT (газ)", style: TextStyle(fontWeight: FontWeight.bold)),
                TextSpan(text: ". Монета MEE имеет пул на DEX, её можно менять на APT.\n\n"),
                TextSpan(text: "📈 О монете:\n", style: TextStyle(fontWeight: FontWeight.bold)),
                TextSpan(text: "MEE — это токен площадки "),
                TextSpan(text: "MEEIRO", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.purple)),
                TextSpan(text: ". Мы надеемся на развитие проекта и пользу для сообщества!"),
              ]
            )),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          style: TextButton.styleFrom(backgroundColor: const Color(0xFF4CAF50), foregroundColor: Colors.white),
          child: const Text("Закрыть"),
        )
      ],
    ));
  }

  void _openCustomEditWalletDialog() {
    TextEditingController controller = TextEditingController(text: currentWalletAddress);
    showDialog(context: context, builder: (context) {
      return StatefulBuilder(builder: (context, setDialogState) {
        return AlertDialog(
          title: const Text("Сменить кошелек"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text("Введите адрес Aptos (66 симв.):", style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              TextField(
                controller: controller, 
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.clear, color: Colors.grey),
                    onPressed: () { controller.clear(); },
                  ),
                ),
              ),
              const SizedBox(height: 10),
              ElevatedButton(onPressed: () async {
                ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
                if (data?.text != null) {
                  controller.text = data!.text!.trim();
                }
              }, child: const Text("Вставить из буфера"))
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), style: TextButton.styleFrom(backgroundColor: const Color(0xFFDC143C), foregroundColor: Colors.white), child: const Text("Отмена")),
            TextButton(onPressed: () {
               String trimmed = controller.text.trim();
               if (trimmed.length == 66 && trimmed.startsWith("0x")) {
                 setState(() { currentWalletAddress = trimmed; isRunning = false; meeCurrentReward = 0.0; _saveWalletAddress(trimmed); _updateWalletLabelText(); });
                 _runUpdateThread(); Navigator.pop(context);
               } else { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Ошибка формата!"))); }
            }, style: TextButton.styleFrom(backgroundColor: const Color(0xFF4CAF50), foregroundColor: Colors.white), child: const Text("Сохранить")),
          ],
        );
      });
    });
  }

  void _showUpdateModal(String newVersion, String url) {
    showDialog(context: context, builder: (ctx) => AlertDialog(
      title: const Text("Доступно обновление!"),
      content: Text("🎉 Новая версия: v$newVersion!\nВаша: v$currentVersion\nНажмите \"Скачать\" для перехода на GitHub."),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Позже")),
        TextButton(onPressed: () { launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication); Navigator.pop(ctx); },
          style: TextButton.styleFrom(backgroundColor: const Color(0xFFFFCC00), foregroundColor: Colors.black), child: const Text("Скачать")),
      ],
    ));
  }

Future<void> _showModalAndOpenUrl(String action, String url) async {
    Map<String, Map<String, String>> instructions = {
      "Harvest": {
        "title": "✅ Контракт скопирован! Harvest.",
        "text": "1. Подключите кошелек.\n2. Вставьте контракт в T0 и T1.\n3. Нажмите RUN."
      },
      "Stake": {
        "title": "✅ Контракт скопирован! Майнинг.",
        "text": "1. Подключите кошелек.\n2. Вставьте контракт в T0 и T1.\n3. Введите сумму (1 MEE = 1000000).\n4. Нажмите RUN."
      },
      "Unstake": {
        "title": "⚠️ Вывод из майнинга?",
        "text": "1. Контракт скопирован! Подключите кошелек.\n"
                 "2. Вставьте контракт \$MEE в поля T0 и T1.\n"
                 "3. В поле 'arg0: u64' введите сумму (1 MEE = 1000000).\n"
                 "4. В поле 'arg1: u8' введите тип вывода:\n"
                 "   0 — Обычный (15 дней ждать, без комиссии)\n"
                 "   1 — Мгновенный (комиссия 15%)\n"
                 "5. Нажмите RUN и подтвердите."
      }
    };
    
    var data = instructions[action]!;
    await Clipboard.setData(const ClipboardData(text: meeCoinT0T1));
    
    bool? result = await showDialog<bool>(
      context: context, 
      builder: (ctx) => AlertDialog(
        title: Text(data["title"]!, style: const TextStyle(color: Color(0xFF1E90FF), fontWeight: FontWeight.bold)),
        content: Text(data["text"]!),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Отмена")),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true), 
            style: TextButton.styleFrom(backgroundColor: const Color(0xFF4CAF50), foregroundColor: Colors.white), 
            child: const Text("Открыть браузер")
          )
        ],
      )
    );
    if (result == true) launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  Widget _buildSection({required Color bg, required Color borderColor, required Widget child}) {
    return Container(width: double.infinity, margin: const EdgeInsets.symmetric(vertical: 5), padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: bg, border: Border.all(color: borderColor, width: 1)), child: child);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Обновление данных..."), duration: Duration(seconds: 1)));
            await _runUpdateThread();
          },
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Padding(
                  padding: EdgeInsets.only(bottom: 15),
                  child: Text("МАЙНИНГ МОНЕТЫ \$MEE (APTOS)", 
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Color(0xFF1E90FF), fontSize: 18, fontWeight: FontWeight.bold)),
                ),
                _buildSection(
                  bg: const Color(0xFFF0F0F0),
                  borderColor: Colors.black,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(walletLabelText, style: TextStyle(fontSize: 14, color: walletLabelColor)),
                      const SizedBox(height: 5),
                      Text(onChainBalancesText, style: const TextStyle(fontSize: 12, color: Color(0xFF555555))),
                      const SizedBox(height: 5),
                      SizedBox(width: double.infinity, child: ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black, elevation: 1),
                        onPressed: _openCustomEditWalletDialog, child: const Text("Сменить кошелек"),
                      ))
                    ],
                  )
                ),
                _buildSection(
                  bg: const Color(0xFFE6F7FF),
                  borderColor: const Color(0xFF8AC0E6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                       const Text("Баланс майнинга \$MEE:", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                       const SizedBox(height: 5),
                       Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                           Expanded(child: Text(meeBalanceText, style: const TextStyle(fontSize: 16))),
                           ElevatedButton(onPressed: () => _showModalAndOpenUrl("Stake", addMeeUrl),
                             style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1E90FF), foregroundColor: Colors.white), child: const Text("В майнинг"))
                       ])
                    ],
                  )
                ),
                _buildSection(
                  bg: const Color(0xFFE6FFE6),
                  borderColor: const Color(0xFF00CC00),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        const Text("Награда (harvest):", style: TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(width: 5),
                        Text(rewardTickerText, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.green)),
                      ]),
                      const SizedBox(height: 5),
                      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                         Expanded(child: Text(meeRewardText, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.green))),
                         ElevatedButton(onPressed: () => _showModalAndOpenUrl("Harvest", harvestBaseUrl),
                           style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF4CAF50), foregroundColor: Colors.white), child: const Text("Забрать награду"))
                      ]),
                      const SizedBox(height: 5),
                      Row(children: [
                        Text(meeRateText, style: const TextStyle(fontSize: 12, color: Color(0xFF666666))),
                        const SizedBox(width: 5),
                        GestureDetector(onTap: _showMiningInfo, child: const Icon(Icons.help_outline, size: 16, color: Colors.blue)),
                      ]),
                    ],
                  )
                ),
                _buildSection(
                  bg: const Color(0xFFFFE6E6),
                  borderColor: const Color(0xFFFF9999),
                  child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    const Expanded(child: Text("Вывод \$MEE из майнинга:", style: TextStyle(fontWeight: FontWeight.bold))),
                    ElevatedButton(onPressed: () => _showModalAndOpenUrl("Unstake", unstakeBaseUrl),
                        style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFDC143C), foregroundColor: Colors.white), child: const Text("Забрать \$MEE"))
                  ])
                ),
                _buildSection(
                  bg: const Color(0xFFF9F9F9),
                  borderColor: Colors.black,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text("Контракт \$MEE:", style: TextStyle(fontSize: 12, color: Color(0xFF888888))),
                      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                         Expanded(child: Text(meeCoinT0T1, style: const TextStyle(fontSize: 10))),
                         TextButton(onPressed: () { Clipboard.setData(const ClipboardData(text: meeCoinT0T1)); 
                           ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Контракт скопирован!"))); }, child: const Text("Копировать"))
                      ])
                    ],
                  )
                ),
                GridView.count(
                  crossAxisCount: 2, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), childAspectRatio: 3.5,
                  children: [
                    _linkBtn("Исходный код", urlSource),
                    _linkBtn("Сайт", urlSite),
                    _linkBtn("График \$MEE", urlGraph),
                    _actionBtn("О проекте", _showAboutProject),
                    _linkBtn("Обмен \$MEE/APT", urlSwapEarnium),
                    _linkBtn("Чат поддержки", urlSupport),
                  ],
                ),
                const SizedBox(height: 10),
                GestureDetector(onTap: updateAction, child: Text(updateStatusText, textAlign: TextAlign.right,
                   style: TextStyle(color: updateStatusColor, fontSize: 12, fontWeight: updateStatusColor == Colors.red ? FontWeight.bold : FontWeight.normal))),
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
        style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFFFACD), foregroundColor: const Color(0xFF333333), side: const BorderSide(color: Color(0xFFFFCC00)), padding: EdgeInsets.zero),
        child: Text(text, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
    ));
  }

  Widget _actionBtn(String text, VoidCallback action) {
    return Container(margin: const EdgeInsets.all(4), child: ElevatedButton(
        onPressed: action,
        style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE0F7FA), foregroundColor: const Color(0xFF006064), side: const BorderSide(color: Colors.cyan), padding: EdgeInsets.zero),
        child: Text(text, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
    ));
  }
}

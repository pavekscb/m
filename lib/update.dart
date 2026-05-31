import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';

class UpdatePage extends StatefulWidget {
  const UpdatePage({super.key});

  @override
  State<UpdatePage> createState() => _UpdatePageState();
}

class _UpdatePageState extends State<UpdatePage> {
  // Текущая версия приложения
  final String _currentVersion = 'v1.1.3';
  
  String _statusMessage = 'Нажмите кнопку для проверки обновлений';
  bool _isChecking = false;
  bool _hasUpdate = false;
  String _newVersion = '';
  
  // Переменные для скачивания
  bool _isDownloading = false;
  double _downloadProgress = 0.0;
  String _downloadStatus = '';

  // Твой репозиторий на GitHub
  final String _githubApiUrl = 'https://api.github.com/repos/pavekscb/m/releases/latest';

  @override
  void initState() {
    super.initState();
    // Можно запустить проверку автоматически при входе на страницу
    _checkForUpdates();
  }

  // 1. Новая вспомогательная функция для корректного сравнения версий (например, v1.1.3 и v1.1.2)
  // Возвращает true, если latest новее, чем current
  bool _isVersionNewer(String current, String latest) {
    // Очищаем строки от буквы 'v' и пробелов, разбиваем по точкам
    final currentParts = current.toLowerCase().replaceAll('v', '').trim().split('.');
    final latestParts = latest.toLowerCase().replaceAll('v', '').trim().split('.');

    for (int i = 0; i < 3; i++) {
      // Получаем числовое значение компонента версии (мажорная.минорная.патч)
      int currentNum = i < currentParts.length ? (int.tryParse(currentParts[i]) ?? 0) : 0;
      int latestNum = i < latestParts.length ? (int.tryParse(latestParts[i]) ?? 0) : 0;

      if (latestNum > currentNum) return true;  // Версия на удаленном сервере новее
      if (latestNum < currentNum) return false; // Локальная версия новее
    }
    return false; // Версии абсолютно одинаковы
  }

  // 2. Проверка обновлений через GitHub API с корректным сравнением
  Future<void> _checkForUpdates() async {
    if (_isChecking || _isDownloading) return;

    setState(() {
      _isChecking = true;
      _hasUpdate = false;
      _statusMessage = 'Проверяем обновления на GitHub...';
    });

    try {
      final response = await http.get(
        Uri.parse(_githubApiUrl),
        headers: {'Accept': 'application/vnd.github.v3+json'},
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final String latestTagName = data['tag_name'] ?? ''; // Например: "v1.1.2"

        if (latestTagName.isEmpty) {
          setState(() => _statusMessage = 'Не удалось определить версию на удаленном сервере.');
          return;
        }

        final cleanLatest = latestTagName.trim();
        final cleanCurrent = _currentVersion.trim();

        // Проверяем, действительно ли версия на GitHub СТАРШЕ (новее) текущей
        if (_isVersionNewer(cleanCurrent, cleanLatest)) {
          setState(() {
            _hasUpdate = true;
            _newVersion = cleanLatest;
            _statusMessage = 'Доступна новая версия: $_newVersion\nУ вас установлена: $_currentVersion';
          });
        } else if (cleanLatest == cleanCurrent) {
          setState(() {
            _hasUpdate = false;
            _statusMessage = 'У вас установлена самая свежая версия! Обновление не требуется.';
          });
        } else {
          // Этот случай сработает, если локальная v1.1.3, а на GitHub v1.1.2
          setState(() {
            _hasUpdate = false;
            _statusMessage = 'Ваша версия ($_currentVersion) новее, чем доступная на GitHub ($cleanLatest).\nВы используете бета- или кастомную сборку.';
          });
        }
      } else if (response.statusCode == 404) {
        setState(() => _statusMessage = 'Релизы в репозитории пока не найдены (404).');
      } else {
        setState(() => _statusMessage = 'Ошибка сервера GitHub: HTTP ${response.statusCode}');
      }
    } catch (e) {
      setState(() => _statusMessage = 'Сбой сети при проверке: $e');
    } finally {
      setState(() => _isChecking = false);
    }
  }

  // 2. Прямое скачивание и запуск установки
  Future<void> _downloadAndInstall() async {
    if (_isDownloading) return;

    setState(() {
      _isDownloading = true;
      _downloadProgress = 0.0;
      _downloadStatus = 'Подготовка к скачиванию...';
    });

    try {
      // Сначала запрашиваем инфу о релизе, чтобы взять точную прямую ссылку на mee.apk из assets
      final response = await http.get(Uri.parse(_githubApiUrl));
      if (response.statusCode != 200) {
        throw Exception('Не удалось получить структуру ассетов релиза');
      }

      final data = jsonDecode(response.body);
      final List<dynamic> assets = data['assets'] ?? [];
      
      // Ищем файл с именем mee.apk
      String downloadUrl = '';
      for (var asset in assets) {
        if (asset['name'] == 'mee.apk') {
          downloadUrl = asset['browser_download_url'];
          break;
        }
      }

      // Фолбэк на случай, если структура ассетов пустая (собираем прямую ссылку вручную)
      if (downloadUrl.isEmpty) {
        downloadUrl = 'https://github.com/pavekscb/m/releases/download/$_newVersion/mee.apk';
      }

      // Получаем путь к локальной папке устройства (кэш или временная папка)
      final directory = await getTemporaryDirectory();
      final filePath = '${directory.path}/mee.apk';

      // Скачиваем файл с помощью Dio
      final dio = Dio();
      await dio.download(
        downloadUrl,
        filePath,
        onReceiveProgress: (received, total) {
          if (total != -1) {
            setState(() {
              _downloadProgress = received / total;
              _downloadStatus = 'Скачивание: ${(_downloadProgress * 100).toStringAsFixed(0)}%';
            });
          }
        },
      );

      setState(() {
        _downloadStatus = 'Файл успешно скачан. Запуск установки...';
      });

      // Открываем APK файл встроенными средствами ОС для переустановки/обновления
      final result = await OpenFilex.open(filePath);
      
      if (result.type != ResultType.done) {
        setState(() {
          _downloadStatus = 'Не удалось запустить установщик: ${result.message}';
        });
      }
    } catch (e) {
      setState(() {
        _downloadStatus = 'Ошибка при скачивании или установке: $e';
      });
    } finally {
      setState(() {
        _isDownloading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      appBar: AppBar(
        title: const Text('Обновление ПО', style: TextStyle(color: Colors.white, fontSize: 18)),
        backgroundColor: const Color(0xFF0A0E1A),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(height: 30),
              // Иконка
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: const Color(0xFF00D4AA).withOpacity(0.12),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0xFF00D4AA).withOpacity(0.3)),
                ),
                child: const Icon(
                  Icons.system_update_alt_rounded,
                  color: Color(0xFF00D4AA),
                  size: 38,
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'MEGA WALLET',
                style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold, letterSpacing: 1.2),
              ),
              const SizedBox(height: 6),
              Text(
                'Установленная версия: $_currentVersion',
                style: const TextStyle(color: Colors.white38, fontSize: 13, fontFamily: 'monospace'),
              ),
              const SizedBox(height: 32),
              
              // Основной блок статуса
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: const Color(0xFF131929),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white.withOpacity(0.06)),
                ),
                child: Column(
                  children: [
                    if (_isChecking) ...[
                      const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(color: Color(0xFF00D4AA), strokeWidth: 2),
                      ),
                      const SizedBox(height: 16),
                    ],
                    Text(
                      _statusMessage,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.5),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // Блок прогресса скачивания (показывается только во время загрузки)
              if (_isDownloading || _downloadProgress > 0)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1F2E),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_downloadStatus, style: const TextStyle(color: Colors.white70, fontSize: 13)),
                      const SizedBox(height: 12),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: LinearProgressIndicator(
                          value: _downloadProgress,
                          backgroundColor: Colors.white10,
                          color: const Color(0xFF00D4AA),
                          minHeight: 8,
                        ),
                      ),
                    ],
                  ),
                ),

              const Spacer(),
              
              // Нижняя кнопка действия
              SizedBox(
                width: double.infinity,
                child: _hasUpdate 
                ? FilledButton.icon(
                    onPressed: (_isDownloading || _isChecking) ? null : _downloadAndInstall,
                    icon: const Icon(Icons.cloud_download_rounded),
                    label: const Text('Скачать и установить', style: TextStyle(fontWeight: FontWeight.bold)),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      backgroundColor: const Color(0xFF00D4AA),
                      disabledBackgroundColor: Colors.white10,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  )
                : OutlinedButton.icon(
                    onPressed: (_isChecking || _isDownloading) ? null : _checkForUpdates,
                    icon: const Icon(Icons.refresh_rounded, color: Color(0xFF00D4AA)),
                    label: const Text('Проверить заново', style: TextStyle(color: Colors.white)),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      side: BorderSide(color: const Color(0xFF00D4AA).withOpacity(0.4)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }
}
# MEE MEGA Mining App 🚀

**MEE Mining App** — это майнер монеты MEE, MEGA  приложение, разработанное на фреймворке **Flutter**.
## 📥 Загрузки

[![DOWNLOADS](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/pavekscb/m/main/stats.json)](https://github.com/pavekscb/m/releases) [![DOWNLOADS LATEST](https://img.shields.io/github/downloads/pavekscb/m/latest/total?label=Latest%20release%20downloads&color=blue)](https://github.com/pavekscb/m/releases/latest) 

## 📱 О приложении
* **Версия:** 1.1.1 (Alpha) (от 11.03.2026)
* **Платформа:** Android
* **Минимальная версия Android:** 5.0 (API 21)
* **Рекомендуемая версия Android:** 11.0+ (API 30+)

---

## 📥 Скачать
Вы можете найти готовый установочный файл в разделе Releases:
👉 **[mee.apk](https://github.com/pavekscb/m/releases)**

---

## 🛠 Технические особенности сборки
Данный проект настроен для обеспечения максимальной совместимости со старыми системами разработки (включая ранние билды Windows 10) и использует фиксированные версии зависимостей:
* **Gradle:** 8.7
* **Android Gradle Plugin (AGP):** 8.5.0
* **Compile SDK:** 34 (Android 14)

---
06.01.2026 - Добавлена раздача монеты $MEGA.

12.01.2026 - Добавлены курсы монет, график цены $MEGA.

12.01.2026 - Добавлен стейкинг $MEGA.

01.02.2026 - Добавлено подключение кошелька Petra.

17.02.2026 - Добавлен обмен монет.

11.03.2026 - Добавлена биржа заданий.


------

## 💻 Инструкция по сборке (Compilation Guide)

Если вы хотите скомпилировать приложение самостоятельно из исходного кода, следуйте этим шагам:

### 1. Подготовка окружения
Убедитесь, что у вас установлен **Flutter SDK** последней версии.

### 2. Настройка путей (для Windows)
Для стабильной сборки рекомендуется использовать выделенные папки для кэша, чтобы избежать проблем с кириллицей в путях пользователя:
```cmd
set GRADLE_USER_HOME=C:\gradle_cache
set PUB_CACHE=C:\flutter_pub_cache

3. Сборка APK
Выполните следующие команды в терминале из корня проекта:

Bash

set GRADLE_USER_HOME=C:\gr

set PUB_CACHE=F:\flutter_pub_cache

cd /d C:\build\meeiro

# Очистка старых билдов
flutter clean

# Получение зависимостей
flutter pub get

# Сборка разных версии APK
flutter build apk --debug --android-skip-build-dependency-validation

flutter build apk --profile --android-skip-build-dependency-validation

flutter build apk --release --android-skip-build-dependency-validation

📄 Лицензия
Этот проект распространяется под лицензией MIT. 

Разработано с помощью Flutter и упорства.




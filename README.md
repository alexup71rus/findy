# Findy

<img src="Findy/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="96" alt="Findy">

Findy — голосовой AI-помощник, который работает на заблокированном iPhone. Телефон остаётся в кармане, руки свободны.

Вызовите Siri через AirPods, скажите «Давай поболтаем» и разговаривайте с ассистентом, занимаясь своими делами. Можно даже оставить телефон в другой комнате — в пределах связи с наушниками.

Также доступны текстовый чат, память и напоминания.

<p>
  <img src="assets/screenshots/locked-iphone.png" width="220" alt="Разговор с Findy на заблокированном iPhone">
  <img src="assets/screenshots/chat.png" width="220" alt="Голосовой разговор и история чата Findy">
  <img src="assets/screenshots/prompt-presets.png" width="220" alt="Настройка характера ответов Findy">
</p>

Для работы нужен свой OpenAI-совместимый провайдер (лучше openai с gpt-live для максимально комфортного опыта). Возможности голоса и веб-поиска зависят от выбранного сервиса и модели. История, память и напоминания хранятся на устройстве, API-ключ — в Keychain.

## Запуск

1. Откройте `Findy.xcodeproj` в Xcode 26 или новее. Требуется iPhone с iOS 18+.
2. Войдите со своим Apple Account в Xcode. В настройках Signing & Capabilities целей `Findy` и `FindyActivity` включите Automatically manage signing, выберите свою Team и уникальные Bundle Identifier (например, `com.yourname.Findy` и `com.yourname.Findy.Activity`). Подключите iPhone, при необходимости включите на нём Developer Mode, выберите его в Xcode и нажмите Run.
3. В приложении добавьте подключение: адрес API, тип API, модель и свой ключ, если провайдер его требует. Разрешите необходимые доступы для голоса и напоминаний.
4. Для своей сборки создайте в приложении «Команды» личную команду с действием Findy → Чат и названием «Давай поболтаем». Разрешите Siri при блокировке и включите Live Activities для Findy.

Проверка Swift-пакета на Mac:

```sh
swift test
```

# iostg

**WhiteGram** — iOS-клиент на базе **Telegram 13.0** с дополнительными настройками.

## Скачать

[IPA — build 34651](https://github.com/HVHBIGNAME/iostg/actions/runs/39761413246/artifacts/12424308231) · [Сборки](https://github.com/HVHBIGNAME/iostg/actions/workflows/build.yml)

Скачайте ZIP, извлеките `.ipa` и подпишите через ESign, Feather, AltStore или Sideloadly.

## Сборка

GitHub Actions → **Build WhiteGram IPA** → **Run workflow**.

- `simulator_only` — проверка в симуляторе без device IPA.
- `login_check` — проверка связи при входе; отключайте во время `FLOOD_WAIT`.
- Для своего приложения добавьте Secrets `WHITEGRAM_TELEGRAM_API_ID` и `WHITEGRAM_TELEGRAM_API_HASH` из [my.telegram.org/apps](https://my.telegram.org/apps).

Исходники Telegram закреплены на `release-13.0.0`; изменения WhiteGram находятся в `whitegram/`.

## Статус

Проект в разработке. Сборка IPA и запуск в симуляторе проверены; поведение на iPhone и соответствие всех функций оригиналу ещё проверяются.

[Telegram-iOS](https://github.com/TelegramMessenger/Telegram-iOS) · [Текущие задачи](whitegram/CURRENT_BACKLOG.md)

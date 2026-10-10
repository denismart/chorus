<div align="center">

# Chorus

[![Release](https://img.shields.io/github/v/release/denismart/chorus?include_prereleases&logo=github&label=release)](https://github.com/denismart/chorus/releases)
[![Downloads](https://img.shields.io/github/downloads/denismart/chorus/total?logo=github&label=downloads)](https://github.com/denismart/chorus/releases)
[![WoW](https://img.shields.io/badge/WoW-Retail%2012.1-blue)](https://worldofwarcraft.blizzard.com)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

**Каждый NPC говорит своим голосом.**<br>
**Every NPC speaks in their own voice.**

[Русский](#русский) · [English](#english)

</div>

---

## Русский

Chorus озвучивает задания World of Warcraft. Ключевые персонажи читают текст **своими настоящими голосами** из игры: Лор'темар, Лиадрин, Аратор, Умбрий, Орвейна, Зул'джарра и другие. Остальные NPC говорят типовыми голосами своей расы и пола. Озвучивается **дословный текст задания**, а не пересказ.

### Возможности

- Озвучка взятия, хода выполнения и сдачи заданий.
- Субтитры внизу экрана, окно можно перетащить.
- Очередь: несколько принятых заданий читаются по очереди, кнопки «Стоп» и «Далее».
- Чтение продолжается с той фразы, на которой остановилось.
- Книги, письма и таблички читаются вслух постранично и собираются в библиотеку (`/chorus lib`): всё прочитанное можно переслушать.
- Если для задания нет озвучки, его читает встроенный синтез речи игры.
- Озвучка ставится отдельными пакетами: только нужные язык и дополнения.

### Пакеты озвучки

| Пакет | Язык | Что озвучено | Размер |
|---|---|---|---|
| `Chorus_ruRU_Midnight` | русский | все задания Midnight: 2999 реплик, 317 NPC | ~450 МБ |
| другие дополнения и языки | | в работе | |

### Установка

1. Скачайте `Chorus` и нужные пакеты озвучки из [релизов](https://github.com/denismart/chorus/releases). Скоро — CurseForge и Wago.
2. Распакуйте папки в `World of Warcraft\_retail_\Interface\AddOns\`.
3. Перезапустите игру и включите аддоны на экране выбора персонажа.

### Быстрый старт

Возьмите любое задание Midnight — озвучка начнётся сама. Настройки: `/chorus`, а также кнопка в меню аддонов у миникарты.

### Частые вопросы

**Это голоса из игры?** Ключевые персонажи озвучены синтезом речи, который клонирует их голоса по образцам из игрового клиента. Это не официальная озвучка Blizzard.

**Будут ли другие дополнения и английский?** Да. Порядок: задания остальных дополнений на русском, затем неквестовые диалоги и книги, затем английский и другие языки.

**Почему пакет такой большой?** Это около 13 часов речи. Пакеты разбиты по дополнениям, чтобы ставить только нужное.

**Нашёл неверное ударение или неподходящий голос.** Пожалуйста, создайте [issue](https://github.com/denismart/chorus/issues/new/choose): укажите задание, NPC и слово. Ударения правятся словарём, голоса переназначаются, и это попадает в следующий выпуск пакета.

### Проблемы и предложения

- Ошибка в работе аддона или в озвучке: [issues](https://github.com/denismart/chorus/issues).
- Если после обновления сыплются ошибки, полностью закройте игру и откройте снова: обновлять аддоны при запущенной игре нельзя.

### Как сделана озвучка

Синтез речи [F5-TTS](https://github.com/SWivid/F5-TTS) с русской моделью [Misha24-10/F5-TTS_RUSSIAN](https://huggingface.co/Misha24-10/F5-TTS_RUSSIAN) и клонированием голосов по образцам из клиента. Ударения: разметка текстов и [silero-stress](https://github.com/snakers4/silero-stress). Контроль качества: каждая фраза распознаётся [GigaAM](https://huggingface.co/ai-sage/GigaAM-v3) и сверяется с текстом, из нескольких дублей выбирается лучший.

### Благодарности

- [SWivid/F5-TTS](https://github.com/SWivid/F5-TTS) — модель синтеза речи.
- [Misha24-10](https://huggingface.co/Misha24-10) — русская модель F5-TTS с поддержкой ударений.
- [Silero](https://github.com/snakers4/silero-stress) — расстановка ударений.
- [ai-sage / Сбер](https://huggingface.co/ai-sage/GigaAM-v3) — распознавание речи GigaAM.
- [wowdev](https://github.com/wowdev) — listfile и TACTSharp.

### Права

Код аддона — [MIT](LICENSE). World of Warcraft, персонажи и их голоса принадлежат Blizzard Entertainment. Chorus — бесплатный некоммерческий фанатский проект, не связанный с Blizzard Entertainment.

---

## English

Chorus voices World of Warcraft quests. Key characters read the quest text **in their own voices** cloned from the game client (Lor'themar, Liadrin, Arator, Umbric, Orweyna, Zul'jarra and more); other NPCs get a voice that matches their race and gender. Chorus reads the **actual quest text**, not a summary.

### Features

- Voiced quest accept, progress and turn-in text.
- Movable subtitles, a playback queue with Stop and Next, resume from the last phrase.
- Books, letters and plaques are read aloud page by page and collected into a library (`/chorus lib`) so you can listen again.
- Falls back to the game's built-in text-to-speech when a line has no recording.
- Voice packs are separate add-ons: install only the languages and expansions you need.

### Voice packs

| Pack | Language | Content |
|---|---|---|
| `Chorus_ruRU_Midnight` | Russian | all Midnight quests (2999 lines, 317 NPCs) |
| English and other expansions | | planned |

### Install

Download `Chorus` and the voice packs from [Releases](https://github.com/denismart/chorus/releases) (CurseForge and Wago coming soon), extract them into `World of Warcraft\_retail_\Interface\AddOns\` and restart the game. Settings: `/chorus`.

### Feedback

Bugs, wrong stress or a voice that does not fit: open an [issue](https://github.com/denismart/chorus/issues/new/choose).

### Credits and legal

Speech: [F5-TTS](https://github.com/SWivid/F5-TTS), [Misha24-10/F5-TTS_RUSSIAN](https://huggingface.co/Misha24-10/F5-TTS_RUSSIAN), [silero-stress](https://github.com/snakers4/silero-stress), [GigaAM](https://huggingface.co/ai-sage/GigaAM-v3). Add-on code is [MIT](LICENSE) licensed. World of Warcraft, its characters and voices are property of Blizzard Entertainment. Chorus is a free, non-commercial fan project not affiliated with Blizzard Entertainment.

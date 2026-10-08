# Chorus

*[English below](#english)*

Озвучка заданий World of Warcraft: каждый NPC говорит своим голосом. Ключевые персонажи озвучены их собственными голосами из игры, остальные NPC — типовыми голосами своей расы и пола.

## Состав

- **Chorus** — ядро: очередь реплик, субтитры, кнопки «Стоп» и «Далее», настройки. Звуков в ядре нет.
- **Пакеты озвучки** `Chorus_<язык>_<дополнение>` — ставятся отдельно, только нужные язык и дополнения:
  - `Chorus_ruRU_Midnight` — все задания Midnight на русском (2999 реплик).

## Установка

1. Скопируйте папки `Chorus` и нужные пакеты озвучки в `World of Warcraft\_retail_\Interface\AddOns\`.
2. Включите аддоны на экране выбора персонажа. Если игра пишет, что аддон устарел, включите «Загружать устаревшие модификации».

## Как пользоваться

- Озвучка начинается при принятии задания, внизу экрана появляются субтитры (окно можно перетащить).
- Несколько принятых заданий читаются по очереди.
- `/chorus` (или `/qv`) — настройки.

## Как сделана озвучка

Синтез речи F5-TTS (дообученная русская модель [Misha24-10/F5-TTS_RUSSIAN](https://huggingface.co/Misha24-10/F5-TTS_RUSSIAN)) с клонированием голосов по образцам из игрового клиента. Ударения — [silero-stress](https://github.com/snakers4/silero-stress) и разметка текстов; проверка качества — распознавание речи [GigaAM](https://huggingface.co/ai-sage/GigaAM-v3), из нескольких дублей выбирается лучший.

Спасибо авторам [F5-TTS](https://github.com/SWivid/F5-TTS), Misha24-10, Silero и Сбера за открытые модели.

## Права

Код аддона — лицензия MIT. World of Warcraft, персонажи и их голоса принадлежат Blizzard Entertainment. Chorus — некоммерческий фанатский проект, не связан с Blizzard. Аддон бесплатный.

---

## English

Voiced quests for World of Warcraft: every NPC speaks in their own voice. Key characters use voices cloned from their in-game voice-over, other NPCs get a voice matching their race and gender.

- **Chorus** — the core: line queue, subtitles, Stop/Next buttons, settings. No audio inside.
- **Voice packs** `Chorus_<locale>_<expansion>` are separate add-ons. Available now: `Chorus_ruRU_Midnight` (all Midnight quests in Russian). English and other languages are planned.

Install `Chorus` plus the voice packs you need into `World of Warcraft\_retail_\Interface\AddOns\`. Settings: `/chorus`.

Speech is synthesized with F5-TTS and voice cloning from in-game samples. Add-on code is MIT licensed. World of Warcraft, its characters and voices are property of Blizzard Entertainment; Chorus is a free, non-commercial fan project not affiliated with Blizzard.

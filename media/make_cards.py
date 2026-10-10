# Карточки пакетов озвучки для описания на CurseForge и иконки пакетов для игры - из списка media/packs.json.
# Пакет с url - готовый: цветная карточка со ссылкой и Icon.tga 64x64 (если есть icon). Без url - серая «скоро».
# Без icon берётся иконка ядра. Строки карточек вписываются в curseforge/description-core.md (английская и русская части).
# Запуск из корня аддона: python3 media/make_cards.py   (нужен Pillow, шрифты macOS)
# Картинки берутся с GitHub, поэтому после запуска их нужно закоммитить и запушить.
import json, re
from pathlib import Path
from PIL import Image, ImageDraw, ImageEnhance, ImageFont, ImageOps

ROOT = Path(__file__).resolve().parent.parent
RAW = "https://raw.githubusercontent.com/denismart/chorus/main/"
SERIF = "/System/Library/Fonts/Supplemental/Georgia Bold.ttf"
SANS = "/System/Library/Fonts/Avenir Next.ttc"
GOLD, GOLD_DIM = (222, 178, 92), (110, 96, 74)
K = 3                       # рисуем в 3 раза крупнее и уменьшаем: края чёткие
W, H = 280 * K, 80 * K      # итоговый размер карточки 280x80, три помещаются в ряд
CORE_ICON = Image.open(ROOT / "media/icon-source.png").convert("RGBA").crop((247, 215, 1007, 975))


def fit(text, path, size, width):
    """Самый крупный шрифт, при котором текст влезает в ширину."""
    while size > 8 * K:
        font = ImageFont.truetype(path, size)
        if font.getlength(text) <= width:
            return font
        size -= K
    return ImageFont.truetype(path, size)


def card(pack, lang, out):
    ready = bool(pack.get("url"))
    own_icon = pack.get("icon")
    icon = Image.open(ROOT / own_icon).convert("RGBA") if own_icon else CORE_ICON
    line1, line2 = pack[lang]
    im = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    bg = Image.new("RGBA", (W, H))
    d = ImageDraw.Draw(bg)
    for y in range(H):
        t = y / H
        d.line([(0, y), (W, y)], fill=(int(30 - 12 * t), int(24 - 10 * t), int(19 - 8 * t), 255))
    mask = Image.new("L", (W, H), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, W - 1, H - 1], 9 * K, fill=255)
    im.paste(bg, (0, 0), mask)
    d = ImageDraw.Draw(im)
    edge = GOLD if ready else GOLD_DIM
    d.rounded_rectangle([K // 2, K // 2, W - 1 - K // 2, H - 1 - K // 2], 9 * K, outline=edge, width=int(1.5 * K))
    # У своей иконки пакета уже есть рамка, у иконки ядра рисуем тонкую
    pad = 7 * K if own_icon else 9 * K
    size = H - 2 * pad
    pic = icon.resize((size, size), Image.LANCZOS)
    if not ready:
        pic = ImageEnhance.Brightness(ImageOps.grayscale(pic).convert("RGBA")).enhance(0.55)
    im.alpha_composite(pic, (pad, pad))
    if not own_icon:
        d.rectangle([pad, pad, pad + size, pad + size], outline=edge, width=K)
    x = pad + size + 12 * K
    room = W - x - 10 * K
    d.text((x, 10 * K), pack["title"], font=fit(pack["title"], SERIF, 22 * K, room), fill=(240, 214, 150) if ready else (145, 141, 133))
    small = ImageFont.truetype(SANS, 12 * K, index=0)
    d.text((x, 40 * K), line1, font=small, fill=(228, 222, 210) if ready else (135, 131, 125))
    d.text((x, 56 * K), line2 + ("  ›" if ready else ""), font=small, fill=GOLD if ready else (115, 111, 105))
    im.resize((W // K, H // K), Image.LANCZOS).save(out)


def markdown(packs, lang):
    items = []
    for pack in packs:
        path = f"media/curseforge/{pack['id']}-{lang}.png"
        alt = f"{pack['title'].title()} · {pack[lang][0]}"
        image = f"![{alt}]({RAW}{path})"
        items.append(f"[{image}]({pack['url']})" if pack.get("url") else image)
    return " ".join(items)


def main():
    packs = json.loads((ROOT / "media/packs.json").read_text(encoding="utf-8"))
    (ROOT / "media/curseforge").mkdir(parents=True, exist_ok=True)
    for pack in packs:
        for lang in ("en", "ru"):
            card(pack, lang, ROOT / f"media/curseforge/{pack['id']}-{lang}.png")
        if pack.get("url") and pack.get("icon"):
            Image.open(ROOT / pack["icon"]).convert("RGBA").resize((64, 64), Image.LANCZOS) \
                .save(ROOT / f"media/packs/{pack['id']}-icon.tga", compression=None)
    # В описании строки карточек - первая (английская часть) и вторая (русская) строки со ссылками на media/curseforge/
    desc = ROOT / "curseforge/description-core.md"
    lines = desc.read_text(encoding="utf-8").split("\n")
    spots = [i for i, line in enumerate(lines) if "media/curseforge/" in line or "img.shields.io" in line]
    if len(spots) == 2:
        lines[spots[0]], lines[spots[1]] = markdown(packs, "en"), markdown(packs, "ru")
        desc.write_text("\n".join(lines), encoding="utf-8")
        print("описание обновлено:", desc.relative_to(ROOT))
    else:
        print("в описании не найдено двух строк с карточками, вставьте вручную:\n" + markdown(packs, "en") + "\n\n" + markdown(packs, "ru"))
    print(f"карточек: {len(packs) * 2}, иконок пакетов: {sum(1 for p in packs if p.get('url') and p.get('icon'))}")


if __name__ == "__main__":
    main()

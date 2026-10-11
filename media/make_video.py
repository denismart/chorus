# Ролик с примерами озвучки для YouTube и README: заставка, реплики (персонаж, задание, текст, полоса хода), концовка.
# Берёт docs/samples/samples.json и звуки docs/samples/<ключ>-<язык>.mp3. Нужны Pillow и ffmpeg, шрифты macOS.
# Запуск из корня аддона: python3 media/make_video.py ru   (или en) -> media/video/chorus-samples-<язык>.mp4
import json, subprocess, sys, tempfile, textwrap
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
LANG = sys.argv[1] if len(sys.argv) > 1 else "en"
W, H, FPS = 1920, 1080, 30
SERIF = "/System/Library/Fonts/Supplemental/Georgia Bold.ttf"
SANS = "/System/Library/Fonts/Avenir Next.ttc"
GOLD, GOLD_SOFT, TEXT, MUTED = (222, 178, 92), (240, 214, 150), (232, 224, 210), (165, 154, 136)
T = {
    "en": {"tag": "Every NPC speaks in their own voice", "sub": "AI voice-over for World of Warcraft quests · Midnight",
           "kind": {"accept": "Quest accept", "complete": "Quest turn-in", "progress": "Quest progress"},
           "end1": "Chorus on CurseForge", "end2": "More samples: denismart.github.io/chorus",
           "fine": "AI-generated voice-over, not official Blizzard voice acting"},
    "ru": {"tag": "Каждый NPC говорит своим голосом", "sub": "Озвучка заданий World of Warcraft · Midnight",
           "kind": {"accept": "Взятие задания", "complete": "Сдача задания", "progress": "Ход задания"},
           "end1": "Chorus на CurseForge", "end2": "Больше примеров: denismart.github.io/chorus",
           "fine": "Озвучка создана нейросетью и не является официальной озвучкой Blizzard"},
}[LANG]
ICON = Image.open(ROOT / "media/curseforge-avatar.png").convert("RGBA")


def font(path, size):
    return ImageFont.truetype(path, size, index=0) if path.endswith(".ttc") else ImageFont.truetype(path, size)


def background():
    """Тёмный тёплый фон: вертикальный градиент и мягкое золотое свечение сверху."""
    im = Image.new("RGB", (W, H))
    d = ImageDraw.Draw(im)
    for y in range(H):
        t = y / H
        d.line([(0, y), (W, y)], fill=(int(30 - 16 * t), int(23 - 12 * t), int(16 - 9 * t)))
    glow = Image.new("L", (W, H), 0)
    ImageDraw.Draw(glow).ellipse([W * 0.15, -H * 0.55, W * 0.85, H * 0.45], fill=70)
    glow = glow.filter(ImageFilter.GaussianBlur(160))
    return Image.composite(Image.new("RGB", (W, H), GOLD), im, glow)


def header(im):
    """Маленький логотип в углу на кадрах с репликами."""
    icon = ICON.resize((64, 64), Image.LANCZOS)
    im.paste(icon, (80, 64), icon)
    ImageDraw.Draw(im).text((160, 74), "Chorus", font=font(SERIF, 38), fill=GOLD_SOFT)


def wrap(text, fnt, width, draw):
    lines = []
    for para in text.split("\n"):
        words, cur = para.split(), ""
        for w in words:
            test = (cur + " " + w).strip()
            if draw.textlength(test, font=fnt) <= width:
                cur = test
            else:
                lines.append(cur); cur = w
        lines.append(cur)
    return [l for l in lines if l is not None]


def title_card(path, big, small, extra=None):
    im = background()
    icon = ICON.resize((200, 200), Image.LANCZOS)
    im.paste(icon, ((W - 200) // 2, 230), icon)
    d = ImageDraw.Draw(im)
    for text, fnt, y, color in ((big, font(SERIF, 96), 470, GOLD_SOFT), (small, font(SANS, 44), 600, TEXT), (extra or "", font(SANS, 34), 670, MUTED)):
        d.text(((W - d.textlength(text, font=fnt)) / 2, y), text, font=fnt, fill=color)
    d.text(((W - d.textlength(T["fine"], font=font(SANS, 26))) / 2, H - 90), T["fine"], font=font(SANS, 26), fill=MUTED)
    im.save(path)


def sample_card(path, s):
    d_ = s[LANG]
    im = background()
    header(im)
    d = ImageDraw.Draw(im)
    x = 160
    d.text((x, 230), T["kind"].get(s["kind"], s["kind"]).upper(), font=font(SANS, 30), fill=GOLD)
    d.text((x, 280), d_["npc"], font=font(SERIF, 84), fill=GOLD_SOFT)
    d.text((x, 390), d_["title"], font=font(SANS, 40), fill=MUTED)
    d.line([(x, 465), (x + 220, 465)], fill=GOLD, width=3)
    # Текст: подбираем размер, чтобы влез до полосы хода
    for size in (46, 42, 38, 34, 30):
        fnt = font(SANS, size)
        lines = wrap(d_["text"], fnt, W - 2 * x, d)
        if 500 + len(lines) * size * 1.42 < H - 140:
            break
    y = 500
    for line in lines:
        d.text((x, y), line, font=fnt, fill=TEXT)
        y += size * 1.42
    im.save(path)


def run(args):
    subprocess.run(["ffmpeg", "-v", "error", "-y", *args], check=True)


def duration(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)], capture_output=True, text=True)
    return float(out.stdout.strip())


samples = json.load(open(ROOT / "docs/samples/samples.json", encoding="utf-8"))
out = ROOT / "media/video"; out.mkdir(exist_ok=True)
tmp = Path(tempfile.mkdtemp())
parts = []
enc = ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-r", str(FPS), "-c:a", "aac", "-b:a", "160k", "-ar", "44100", "-ac", "2"]
title_card(tmp / "intro.png", "Chorus", T["tag"], T["sub"])
run(["-loop", "1", "-t", "3.5", "-i", str(tmp / "intro.png"), "-f", "lavfi", "-t", "3.5", "-i", "anullsrc=r=44100:cl=stereo",
     "-vf", "fade=in:0:20", *enc, "-shortest", str(tmp / "p00.mp4")])
parts.append(tmp / "p00.mp4")
for i, s in enumerate(samples, 1):
    audio = ROOT / f"docs/samples/{s['key']}-{LANG}.mp3"
    dur = duration(audio) + 1.2
    sample_card(tmp / f"s{i}.png", s)
    # Полоса хода внизу растёт вместе с репликой; звук начинается через 0,4 с после кадра
    bar = (f"drawbox=x=160:y={H - 110}:w={W - 320}:h=6:color=0x3a2e20@1:t=fill,"
           f"drawbox=x=160:y={H - 110}:w='({W - 320})*min(1\\,t/{dur - 0.8:.2f})':h=6:color=0xdeb25c@1:t=fill,"
           f"fade=in:0:10,fade=out:st={dur - 0.35:.2f}:d=0.35")
    run(["-loop", "1", "-t", f"{dur:.2f}", "-i", str(tmp / f"s{i}.png"), "-i", str(audio),
         "-filter_complex", f"[0:v]{bar}[v];[1:a]adelay=400|400,apad[a]", "-map", "[v]", "-map", "[a]",
         "-t", f"{dur:.2f}", *enc, str(tmp / f"p{i:02d}.mp4")])
    parts.append(tmp / f"p{i:02d}.mp4")
title_card(tmp / "outro.png", T["end1"], "curseforge.com/wow/addons/chorus", T["end2"])
run(["-loop", "1", "-t", "4", "-i", str(tmp / "outro.png"), "-f", "lavfi", "-t", "4", "-i", "anullsrc=r=44100:cl=stereo",
     "-vf", "fade=in:0:10,fade=out:st=3.4:d=0.6", *enc, "-shortest", str(tmp / "p99.mp4")])
parts.append(tmp / "p99.mp4")
(tmp / "list.txt").write_text("".join(f"file '{p}'\n" for p in parts))
final = out / f"chorus-samples-{LANG}.mp4"
run(["-f", "concat", "-safe", "0", "-i", str(tmp / "list.txt"), "-c", "copy", "-movflags", "+faststart", str(final)])
print(f"{final.relative_to(ROOT)}: {duration(final):.0f} с, {final.stat().st_size / 1e6:.1f} МБ")

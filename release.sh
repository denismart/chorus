#!/usr/bin/env bash
# Выпуск версии Chorus с компа (без GitHub Actions).
#   ./release.sh core <версия> [--dry-run]          ядро: zip, тег v<версия>, релиз на GitHub
#   ./release.sh pack <Пакет> <версия> [--dry-run]  пакет озвучки: zip собирается на ноутбуке (ssh hyperpc),
#                                                   скачивается и выкладывается релизом <Пакет>-v<версия>
# --dry-run: только собрать архив в .release/, ничего не публиковать.
# CurseForge: если в .release.env заданы CF_API_TOKEN и CF_PROJECT_<имя> (например CF_PROJECT_Chorus),
# архив загружается и туда. Пример — .release.env.example.
set -euo pipefail
cd "$(dirname "$0")"

kind="${1:-}"; [[ "$kind" == core || "$kind" == pack ]] || { sed -n '2,8p' "$0"; exit 1; }
if [[ "$kind" == core ]]; then name=Chorus; ver="${2:?версия}"; shift 2; else name="${2:?имя пакета}"; ver="${3:?версия}"; shift 3; fi
dry=0; [[ "${1:-}" == "--dry-run" ]] && dry=1
[[ -f .release.env ]] && source .release.env
out=".release"; mkdir -p "$out"; zip="$out/$name-v$ver.zip"
GAME_VERSION="${GAME_VERSION:-12.1.0}"

if [[ "$kind" == core ]]; then
    tag="v$ver"
    [[ $dry == 1 || -z "$(git status --porcelain)" ]] || { echo "есть незакоммиченные изменения"; exit 1; }
    tmp="$(mktemp -d)"; mkdir "$tmp/Chorus"
    sed "s/@project-version@/$ver/" Chorus.toc > "$tmp/Chorus/Chorus.toc"
    cp -R Core.lua LICENSE Icon.tga Icons "$tmp/Chorus/"
    (cd "$tmp" && zip -qr - Chorus) > "$zip"; rm -r "$tmp"
    notes="$(awk -v v="## $ver" '$0==v{f=1;next} /^## /{f=0} f' CHANGELOG.md)"
else
    tag="$name-v$ver"
    remote="C:\\wow-voice\\release"
    # Копия пакета с версией в .toc (UTF-8 без BOM) и zip встроенным в Windows tar
    ps="\$ProgressPreference='SilentlyContinue'; \$s='C:\\wow-voice\\addon\\$name'; \$r='$remote'; \$d=\"\$r\\$name\"
New-Item -ItemType Directory -Force \$r | Out-Null
robocopy \$s \$d /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
\$toc=\"\$d\\$name.toc\"; \$t=(Get-Content \$toc -Encoding UTF8) -replace '^## Version: .*', '## Version: $ver'
[IO.File]::WriteAllLines(\$toc, \$t, (New-Object Text.UTF8Encoding \$false))
\$z=\"\$r\\$name-v$ver.zip\"; Remove-Item \$z -EA 0
tar.exe -a -c -f \$z -C \$r $name
'{0:N0} MB' -f ((Get-Item \$z).Length/1MB)"
    enc=$(printf '%s' "$ps" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')
    echo "собираю $name на ноутбуке: $(ssh -o BatchMode=yes hyperpc "powershell -NoProfile -NonInteractive -EncodedCommand $enc" | tr -d '\r')"
    if [[ $dry == 1 ]]; then echo "dry-run: архив остался на ноутбуке ($remote\\$name-v$ver.zip)"; exit 0; fi
    scp -q "hyperpc:C:/wow-voice/release/$name-v$ver.zip" "$zip"
    notes="Пакет озвучки $name, версия $ver. Требует аддон Chorus."
fi
echo "архив: $zip ($(du -h "$zip" | cut -f1))"
[[ $dry == 1 ]] && { echo "dry-run: публикация пропущена"; exit 0; }

# GitHub: тег и релиз
if ! git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then git tag -a "$tag" -m "$name $ver"; fi
git push -q origin "$tag"
gh release create "$tag" "$zip" --title "$name $ver" --notes "${notes:-$name $ver}" --prerelease
echo "GitHub: готово"

# CurseForge (если настроен)
pid_var="CF_PROJECT_${name}"; pid="${!pid_var:-}"
if [[ -n "${CF_API_TOKEN:-}" && -n "$pid" ]]; then
    # Версии игры: все из GAME_VERSIONS (через пробел), по умолчанию одна GAME_VERSION
    gv=$(curl -fsS -H "X-Api-Token: $CF_API_TOKEN" https://wow.curseforge.com/api/game/versions \
        | python3 -c "import json,sys; want=sys.argv[1].split(); v=[str(x['id']) for x in json.load(sys.stdin) if x['name'] in want]; print(','.join(v))" "${GAME_VERSIONS:-$GAME_VERSION}")
    [[ -n "$gv" ]] || { echo "CurseForge: не найдены версии игры ${GAME_VERSIONS:-$GAME_VERSION}"; exit 1; }
    # Пакет озвучки требует ядро: на CurseForge зависимость задаётся у каждого файла
    meta=$(python3 -c "
import json, sys
name, ver, kind, core, notes = sys.argv[1:6]
meta = {'changelog': notes, 'changelogType': 'markdown', 'displayName': f\"{name.replace('_', ' ')} {ver}\",
        'gameVersions': [int(x) for x in sys.argv[6].split(',')], 'releaseType': 'beta'}
if kind == 'pack':
    meta['relations'] = {'projects': [{'slug': core, 'type': 'requiredDependency'}]}
print(json.dumps(meta))" "$name" "$ver" "$kind" "${CF_CORE_SLUG:-chorus}" "${notes:-$name $ver}" "$gv")
    curl -fsS -H "X-Api-Token: $CF_API_TOKEN" -F "metadata=$meta" -F "file=@$zip" \
        "https://wow.curseforge.com/api/projects/$pid/upload-file" && echo && echo "CurseForge: загружено"
else
    echo "CurseForge: пропущено (нет CF_API_TOKEN или $pid_var в .release.env)"
fi

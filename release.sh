#!/usr/bin/env bash
# Выпуск версии Chorus с компа (без GitHub Actions).
#   ./release.sh core <версия> [--dry-run]          ядро: zip, тег v<версия>, релиз на GitHub
#   ./release.sh pack <Пакет> <версия> [--dry-run]  пакет озвучки: zip собирается на ноутбуке (ssh hyperpc),
#                                                   скачивается и выкладывается релизом <Пакет>-v<версия>
# --dry-run: только собрать архив в .release/, ничего не публиковать.
# RELEASE_TYPE=alpha|beta|release - тип файла на CurseForge (по умолчанию release).
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
    # Где собран пакет: по умолчанию ноутбук (ssh hyperpc, C:\wow-voice\addon). Для пакета можно задать в .release.env
    # PACK_SSH_<имя> (аргументы ssh, например "-J bw winps") и PACK_DIR_<имя> (папка, где лежит папка пакета)
    ssh_var="PACK_SSH_${name}"; dir_var="PACK_DIR_${name}"
    read -r -a pack_ssh <<< "${!ssh_var:-hyperpc}"
    src_dir="${!dir_var:-C:\\wow-voice\\addon}"
    drive="${src_dir%%:*}"
    remote="$drive:\\wow-voice\\release"
    # Копия пакета с версией в .toc (UTF-8 без BOM) и zip встроенным в Windows tar
    ps="\$ProgressPreference='SilentlyContinue'; \$s='$src_dir\\$name'; \$r='$remote'; \$d=\"\$r\\$name\"
New-Item -ItemType Directory -Force \$r | Out-Null
robocopy \$s \$d /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
\$toc=\"\$d\\$name.toc\"; \$t=(Get-Content \$toc -Encoding UTF8) -replace '^## Version: .*', '## Version: $ver'
[IO.File]::WriteAllLines(\$toc, \$t, (New-Object Text.UTF8Encoding \$false))
\$z=\"\$r\\$name-v$ver.zip\"; Remove-Item \$z -EA 0
tar.exe -a -c -f \$z -C \$r $name
'{0:N0} MB' -f ((Get-Item \$z).Length/1MB)"
    enc=$(printf '%s' "$ps" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')
    echo "собираю $name (${pack_ssh[*]}, $src_dir): $(ssh -o BatchMode=yes "${pack_ssh[@]}" "powershell -NoProfile -NonInteractive -EncodedCommand $enc" | tr -d '\r')"
    if [[ $dry == 1 ]]; then echo "dry-run: архив остался на машине ($remote\\$name-v$ver.zip)"; exit 0; fi
    # scp: те же аргументы, хост последним; путь Windows - с прямыми слэшами
    scp -q "${pack_ssh[@]:0:${#pack_ssh[@]}-1}" "${pack_ssh[${#pack_ssh[@]}-1]}:$drive:/wow-voice/release/$name-v$ver.zip" "$zip"
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
        'gameVersions': [int(x) for x in sys.argv[6].split(',')], 'releaseType': sys.argv[7]}
if kind == 'pack':
    meta['relations'] = {'projects': [{'slug': core, 'type': 'requiredDependency'}]}
print(json.dumps(meta))" "$name" "$ver" "$kind" "${CF_CORE_SLUG:-chorus}" "${notes:-$name $ver}" "$gv" "${RELEASE_TYPE:-release}")
    upload() { curl -sS -w '\n%{http_code}' -H "X-Api-Token: $CF_API_TOKEN" --form-string "metadata=$1" -F "file=@$zip" \
        "https://wow.curseforge.com/api/projects/$pid/upload-file"; }
    resp=$(upload "$meta")
    # Ядро на модерации ещё нельзя указать зависимостью (ошибка 1018): грузим без неё, в .toc она всё равно есть
    if [[ "$resp" == *'"errorCode":1018'* ]]; then
        echo "CurseForge: ядро пока недоступно как зависимость, загружаю без неё"
        resp=$(upload "$(python3 -c "import json,sys; m=json.loads(sys.argv[1]); m.pop('relations',None); print(json.dumps(m))" "$meta")")
    fi
    [[ "${resp##*$'\n'}" == 200 ]] || { echo "CurseForge: ошибка ${resp}"; exit 1; }
    echo "CurseForge: загружено ${resp%$'\n'*}"
else
    echo "CurseForge: пропущено (нет CF_API_TOKEN или $pid_var в .release.env)"
fi

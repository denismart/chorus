-- Chorus: озвучка заданий и реплик NPC. Ядро без звуков, звуки приходят из пакетов Chorus_<язык>_<дополнение>.
-- Задание читается после того, как игрок его принял. Несколько заданий читаются по очереди с паузой.
-- Если для текста есть готовый аудиофайл (см. Manifest.lua), играет он, иначе встроенный синтез речи.
-- Внизу экрана показываются субтитры с кнопками «Стоп» и «Далее».
local addonName = ...

local SOUND_DIR = "Interface\\AddOns\\Chorus\\Sounds\\"
-- Папка звука реплики: её регистрирует пакет озвучки, иначе папка ядра
local function SoundDir(key) return (ChorusSoundDirs and ChorusSoundDirs[key]) or SOUND_DIR end
local EXTENSIONS = { "mp3", "ogg" }
local PREFIX = "|cff66ccffChorus:|r "
local CHUNK_CHARS = 110   -- примерная длина одной порции субтитров в символах
local TTS_CPS = 14        -- оценка скорости синтеза, символов в секунду

local defaults = {
	enabled = true,       -- озвучка включена
	channel = "Dialog",   -- звуковой канал для файлов
	tts = true,           -- читать синтезом речи, если нет файла
	ttsVoice = nil,       -- ID голоса синтеза (nil = подобрать автоматически)
	ttsRate = 0,          -- скорость синтеза (-10..10)
	ttsVolume = 100,      -- громкость синтеза (0..100)
	subtitles = true,     -- показывать субтитры
	portrait = true,      -- показывать портрет говорящего в окне субтитров
	gap = 2,              -- пауза между заданиями, секунд
	waitNpc = true,       -- ждать, пока договорит NPC (говорящая голова, реплики в чате, ролики)
	waitAny = true,       -- учитывать реплики любых NPC рядом, а не только выдавшего задание
	npcTail = 3,          -- сколько ещё ждать после реплики NPC: вдруг следом заговорит другой
	preroll = 1.5,        -- задержка перед началом чтения, секунд
	complete = false,     -- читать текст при сдаче задания
	gossip = false,       -- читать обычные диалоги с NPC
	pos = nil,            -- сохранённое положение окна субтитров
	width = 520,          -- ширина окна субтитров
	height = 96,          -- высота окна субтитров: заголовок и три строки текста
	fontSize = 14,        -- размер шрифта субтитров
	texts = {},           -- собранные тексты: ключ -> { t, n, s, id, title }
}

local db
local queue = {}         -- очередь реплик
local current            -- реплика, которая звучит сейчас
local currentHandle      -- дескриптор проигрываемого файла
local token = 0          -- меняется при каждой смене состояния, отменяет старые таймеры
local hold = { manual = false, head = false, headUntil = 0, movie = false, notBefore = 0, sayUntil = 0, waitStart = 0, waiting = false, lastQuestEvent = -100, lastSayAt = -100 }
local speakers = {}  -- кто из NPC когда говорил: по повторам узнаём идущий диалог
local DIALOG_TAIL = 6  -- пауза после реплики, если идёт диалог: следующая фраза в нём обычно не заставляет себя ждать
local QUEST_SCENE_WINDOW = 4  -- реплика NPC в пределах стольких секунд от взятия или сдачи задания считается частью сценки
local MAX_NPC_WAIT = 40  -- дольше этого реплик NPC не ждём, чтобы очередь не застревала в людных местах  -- причины, по которым очередь ждёт
local retryPending = false
local pendingAccept = {} -- тексты, увиденные в окне задания: ID -> реплика
local pendingComplete = {}
local subtitle           -- окно субтитров

-- Секретные значения Midnight нельзя читать в Lua: считаем их отсутствующими
local function Plain(value)
	if issecretvalue and issecretvalue(value) then return nil end
	return value
end

-- Простой стабильный хеш строки (djb2) для ключей диалогов
local function Hash(text)
	local h = 5381
	for i = 1, #text do
		h = (h * 33 + text:byte(i)) % 4294967296
	end
	return ("%08x"):format(h)
end

-- Убирает разметку игры, чтобы её не читал голос и не показывали субтитры
local function CleanText(text)
	text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
	text = text:gsub("|n", "\n"):gsub("|T.-|t", ""):gsub("|A.-|a", "")
	text = text:gsub("|H.-|h(.-)|h", "%1")
	text = text:gsub("[<>]", "")
	return text
end

-- Число символов в строке UTF-8
local function CharCount(text)
	local _, continuation = text:gsub("[\128-\191]", "")
	return #text - continuation
end

-- Делит текст на порции для субтитров: по концам предложений и по длине
local function SplitChunks(text, limit)
	limit = limit or CHUNK_CHARS
	local chunks, line, length = {}, {}, 0
	local function Flush()
		if #line > 0 then
			chunks[#chunks + 1] = table.concat(line, " ")
			line, length = {}, 0
		end
	end
	for word in CleanText(text):gmatch("%S+") do
		local size = CharCount(word)
		if length > 0 and length + size + 1 > limit then Flush() end
		line[#line + 1] = word
		length = length + size + 1
		if length >= limit * 0.5 and word:find("[%.%!%?]$") then Flush() end
	end
	Flush()
	return chunks
end

-- Невидимая модель: через неё узнаём номер файла модели собеседника, по нему генератор определяет расу
local modelProbe
local function GetModelFileID(unit)
	local ok, id = pcall(function()
		if not modelProbe then
			modelProbe = CreateFrame("PlayerModel", nil, UIParent)
			modelProbe:SetSize(1, 1)
			modelProbe:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -50, 50)
			modelProbe:SetAlpha(0)
		end
		modelProbe:SetUnit(unit)
		return modelProbe:GetModelFileID()
	end)
	id = ok and Plain(id) or nil
	return type(id) == "number" and id > 0 and id or nil
end

local function NpcUnit()
	return UnitExists("questnpc") and "questnpc" or "npc"
end

-- Данные о собеседнике: имя, пол, ID существа, раса, тип существа, модель
local function GetNpcInfo()
	local unit = NpcUnit()
	local info = { name = Plain(UnitName(unit)), sex = Plain(UnitSex(unit)) }
	local guid = Plain(UnitGUID(unit))
	if type(guid) == "string" then
		local unitType, _, _, _, _, id = strsplit("-", guid)
		if unitType == "Creature" or unitType == "Vehicle" or unitType == "GameObject" then
			info.id = tonumber(id)
		end
	end
	local _, raceFile = UnitRace(unit)
	info.race = Plain(raceFile)
	local creatureType, creatureTypeID = UnitCreatureType(unit)
	info.ct = Plain(creatureType)
	info.cti = Plain(creatureTypeID)
	info.model = GetModelFileID(unit)
	return info
end

-- Подбирает голос синтеза: сохранённый, затем русский, затем первый доступный
local function PickTtsVoice()
	if not (C_VoiceChat and C_VoiceChat.GetTtsVoices) then return nil end
	local ok, voices = pcall(C_VoiceChat.GetTtsVoices)
	if not ok or type(voices) ~= "table" or #voices == 0 then return nil end
	if db.ttsVoice then
		for _, voice in ipairs(voices) do
			if voice.voiceID == db.ttsVoice then return voice.voiceID end
		end
	end
	for _, voice in ipairs(voices) do
		local name = (voice.name or ""):lower()
		if name:find("russian") or name:find("irina") or name:find("pavel") or name:find("milena") or name:find("русск") then
			return voice.voiceID
		end
	end
	return voices[1].voiceID
end

local function SpeakTts(text)
	local voiceID = PickTtsVoice()
	if not voiceID then return false end
	return (pcall(C_VoiceChat.SpeakText, voiceID, CleanText(text), db.ttsRate, db.ttsVolume, false))
end

-- Останавливает звук текущей реплики, очередь не трогает
local function StopAudio()
	if currentHandle then
		StopSound(currentHandle, 300)
		currentHandle = nil
	end
	if current and current.mode == "tts" and C_VoiceChat and C_VoiceChat.StopSpeakingText then
		pcall(C_VoiceChat.StopSpeakingText)
	end
end

----------------------------------------------------------------------
-- Окно субтитров
----------------------------------------------------------------------

local StopAll, Skip, TogglePause, Restart, SetPortrait, OpenConfig, YieldToNpc  -- объявлены ниже

local function CreateSubtitle()
	local f = CreateFrame("Frame", "ChorusSubtitle", UIParent, "BackdropTemplate")
	f:SetSize(db.width, db.height)
	f:SetFrameStrata("MEDIUM")
	f:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8x8",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		edgeSize = 14,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	f:SetBackdropColor(0.05, 0.04, 0.03, 0.88)
	f:SetBackdropBorderColor(0.85, 0.68, 0.32, 1)

	-- Мягкая подсветка сверху и тонкая линия под заголовком
	f.shine = f:CreateTexture(nil, "BACKGROUND", nil, 1)
	f.shine:SetPoint("TOPLEFT", 4, -4)
	f.shine:SetPoint("TOPRIGHT", -4, -4)
	f.shine:SetHeight(24)
	f.shine:SetColorTexture(1, 1, 1, 1)
	if f.shine.SetGradient and CreateColor then
		f.shine:SetGradient("VERTICAL", CreateColor(0.85, 0.68, 0.32, 0), CreateColor(0.85, 0.68, 0.32, 0.22))
	else
		f.shine:SetColorTexture(0.85, 0.68, 0.32, 0.1)
	end
	f.line = f:CreateTexture(nil, "ARTWORK")
	f.line:SetHeight(1)
	f.line:SetColorTexture(0.85, 0.68, 0.32, 0.45)
	f:SetClampedToScreen(true)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relPoint, x, y = self:GetPoint()
		db.pos = { point, relPoint, x, y }
	end)
	if db.pos then
		f:SetPoint(db.pos[1], UIParent, db.pos[2], db.pos[3], db.pos[4])
	else
		f:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 260)
	end

	-- Размер меняется мышью за правый нижний угол
	f:SetResizable(true)
	if f.SetResizeBounds then f:SetResizeBounds(300, 60, 1400, 400) end
	f.grip = CreateFrame("Button", nil, f)
	f.grip:SetSize(16, 16)
	f.grip:SetPoint("BOTTOMRIGHT", -1, 1)
	f.grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	f.grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
	f.grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
	f.grip:SetScript("OnMouseUp", function()
		f:StopMovingOrSizing()
		local width, height = f:GetSize()
		if width then db.width, db.height = math.floor(width + 0.5), math.floor(height + 0.5) end
		local point, _, relPoint, x, y = f:GetPoint()
		db.pos = { point, relPoint, x, y }
	end)

	-- Кнопка настроек стоит последней в ряду
	f.gear = CreateFrame("Button", nil, f)
	f.gear:SetSize(20, 20)
	f.gear:SetPoint("TOPRIGHT", -8, -4)
	f.gear:SetNormalTexture("Interface\\Buttons\\UI-OptionsButton")
	f.gear:SetHighlightTexture("Interface\\Buttons\\UI-OptionsButton", "ADD")
	f.gear:SetScript("OnClick", function() if OpenConfig then OpenConfig() end end)
	f.gear:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("Настройки Chorus")
		GameTooltip:Show()
	end)
	f.gear:SetScript("OnLeave", function() GameTooltip:Hide() end)

	f.stop = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	f.stop:SetSize(52, 20)
	f.stop:SetPoint("RIGHT", f.gear, "LEFT", -4, 0)
	f.stop:SetText("Стоп")
	f.stop:SetScript("OnClick", function() StopAll() end)

	-- Порядок справа налево: «Стоп», «Пауза», «Далее»
	f.pause = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	f.pause:SetSize(64, 20)
	f.pause:SetPoint("RIGHT", f.stop, "LEFT", -4, 0)
	f.pause:SetText("Пауза")
	f.pause:SetScript("OnClick", function() TogglePause() end)

	f.skip = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	f.skip:SetSize(78, 20)
	f.skip:SetPoint("RIGHT", f.pause, "LEFT", -4, 0)
	f.skip:SetText("Далее")
	f.skip:SetScript("OnClick", function() Skip() end)

	f.restart = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	f.restart:SetSize(70, 20)
	f.restart:SetPoint("RIGHT", f.skip, "LEFT", -4, 0)
	f.restart:SetText("Сначала")
	f.restart:SetScript("OnClick", function() Restart() end)

	f.count = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	f.count:SetPoint("BOTTOMRIGHT", -20, 7)
	f.count:SetJustifyH("RIGHT")

	f.title = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	f.title:SetPoint("TOPLEFT", 10, -8)
	f.title:SetPoint("RIGHT", f.restart, "LEFT", -8, 0)
	f.title:SetJustifyH("LEFT")
	f.title:SetWordWrap(false)

	-- Портрет говорящего: живая модель с анимацией разговора
	f.portrait = CreateFrame("Frame", nil, f, "BackdropTemplate")
	f.portrait:SetPoint("TOPLEFT", 7, -7)
	f.portrait:SetPoint("BOTTOMLEFT", 7, 7)
	f.portrait:SetWidth(66)
	f.portrait:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8x8",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		edgeSize = 12,
		insets = { left = 2, right = 2, top = 2, bottom = 2 },
	})
	f.portrait:SetBackdropColor(0.12, 0.1, 0.08, 1)
	f.portrait:SetBackdropBorderColor(0.85, 0.68, 0.32, 1)
	f.portrait:Hide()
	f.model = CreateFrame("PlayerModel", nil, f.portrait)
	f.model:SetPoint("TOPLEFT", 3, -3)
	f.model:SetPoint("BOTTOMRIGHT", -3, 3)
	f.model:SetScript("OnAnimFinished", function(self) self:SetAnimation(f.talking and 60 or 0) end)

	-- Кнопки видны ярко только под курсором, чтобы не отвлекать от текста
	f.sinceUpdate = 0
	f:SetScript("OnUpdate", function(self, elapsed)
		self.sinceUpdate = self.sinceUpdate + elapsed
		if self.sinceUpdate < 0.15 then return end
		self.sinceUpdate = 0
		local alpha = (self.preview or MouseIsOver(self)) and 1 or 0.3
		self.stop:SetAlpha(alpha); self.skip:SetAlpha(alpha); self.pause:SetAlpha(alpha); self.grip:SetAlpha(alpha); self.gear:SetAlpha(alpha); self.restart:SetAlpha(alpha)
	end)

	f.text = f:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	f.text:SetPoint("TOPLEFT", 12, -28)
	f.text:SetPoint("BOTTOMRIGHT", -12, 6)
	f.text:SetJustifyH("LEFT")
	f.text:SetJustifyV("MIDDLE")
	local font, _, flags = f.text:GetFont()
	if font then f.text:SetFont(font, db.fontSize, flags) end

	f:Hide()
	return f
end

-- Применяет сохранённые размеры, положение и шрифт к окну субтитров
local function ApplyLayout()
	if not subtitle then return end
	subtitle:SetSize(db.width, db.height)
	subtitle:ClearAllPoints()
	if db.pos then
		subtitle:SetPoint(db.pos[1], UIParent, db.pos[2], db.pos[3], db.pos[4])
	else
		subtitle:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 260)
	end
	local font, _, flags = subtitle.text:GetFont()
	if font then subtitle.text:SetFont(font, db.fontSize, flags) end
	SetPortrait(current and current.key or (queue[1] and queue[1].key), current ~= nil, true)
end

-- Показывает или прячет портрет и сдвигает текст, чтобы он не налезал на модель.
-- talking: персонаж говорит (анимация разговора) или ждёт (стоит спокойно).
-- Модель перезагружается, только когда сменился персонаж: иначе она дёргается при каждом обновлении.
function SetPortrait(key, talking, force)
	if not subtitle then return end
	talking = talking and true or false
	if not force and subtitle.portraitKey == key and subtitle.portraitShown ~= nil then
		if subtitle.talking ~= talking then
			subtitle.talking = talking
			if subtitle.portraitShown then pcall(subtitle.model.SetAnimation, subtitle.model, talking and 60 or 0) end
		end
		return
	end
	subtitle.portraitKey, subtitle.talking = key, talking
	local known = key and ((ChorusTexts and ChorusTexts[key]) or db.texts[key])
	local shown = false
	if db.portrait and known and (known.d or known.id) then
		shown = pcall(function()
			subtitle.portrait:SetWidth(math.max(40, subtitle:GetHeight() - 14))
			subtitle.portrait:Show()
			local model = subtitle.model
			model:ClearModel()
			if known.d then model:SetDisplayInfo(known.d) else model:SetCreature(known.id) end
			model:SetPortraitZoom(0.85)
			model:SetAnimation(talking and 60 or 0)
		end)
	end
	subtitle.portraitShown = shown
	if not shown then subtitle.portrait:Hide() end
	local left = shown and (subtitle.portrait:GetWidth() + 18) or 14
	subtitle.title:ClearAllPoints()
	subtitle.title:SetPoint("TOPLEFT", left, -10)
	subtitle.title:SetPoint("RIGHT", subtitle.restart, "LEFT", -8, 0)
	subtitle.line:ClearAllPoints()
	subtitle.line:SetPoint("TOPLEFT", left, -28)
	subtitle.line:SetPoint("TOPRIGHT", -12, -28)
	subtitle.text:ClearAllPoints()
	subtitle.text:SetPoint("TOPLEFT", left, -32)
	subtitle.text:SetPoint("BOTTOMRIGHT", -14, 8)
end

-- Обновляет заголовок: кто говорит, какое задание и сколько ещё в очереди
local function UpdateTitle()
	if not subtitle or not current then return end
	local parts = {}
	if current.npc then parts[#parts + 1] = current.npc end
	if current.title then parts[#parts + 1] = current.title end
	subtitle.title:SetText(table.concat(parts, ": "))
	subtitle.skip:SetShown(#queue > 0)
	subtitle.skip:SetText(("Далее (%d)"):format(#queue))
	subtitle.count:SetText(#queue > 0 and ("ещё в очереди: %d"):format(#queue) or "")
end

-- Показывает порции текста по очереди, распределяя время пропорционально их длине
local function ShowSubtitles(item, duration, my, offset)
	if not db.subtitles then return end
	offset = offset or 0
	subtitle = subtitle or CreateSubtitle()
	UpdateTitle()
	SetPortrait(item.key, true)

	-- Сколько символов помещается в три строки при текущей ширине окна и размере шрифта
	local textWidth = subtitle.text:GetWidth()
	if not textWidth or textWidth < 100 then textWidth = db.width - 120 end
	local perLine = textWidth / (db.fontSize * 0.56)
	local chunks = SplitChunks(item.text, math.max(60, math.floor(perLine * 3 * 0.88)))
	if #chunks == 0 then return end
	local total = 0
	for _, chunk in ipairs(chunks) do total = total + CharCount(chunk) end

	-- Время начала каждой порции. При продолжении после паузы показываем ту, на которую пришлось место остановки
	local starts, elapsed, first = { 0 }, 0, 1
	for index = 2, #chunks do
		elapsed = elapsed + duration * CharCount(chunks[index - 1]) / total
		starts[index] = elapsed
		if elapsed <= offset then first = index end
	end

	subtitle.text:SetText(chunks[first])
	subtitle:Show()

	for index = first + 1, #chunks do
		C_Timer.After(starts[index] - offset, function()
			if token == my and subtitle then subtitle.text:SetText(chunks[index]) end
		end)
	end
end

----------------------------------------------------------------------
-- Очередь
----------------------------------------------------------------------

local StartNext

-- Нужно ли сейчас ждать: ручная пауза, говорящая голова, ролик, реплика NPC или задержка перед началом
local function HoldReason()
	if hold.manual then return "Пауза" end
	if not db.waitNpc then
		return GetTime() < hold.notBefore and "..." or nil
	end
	if hold.movie then return "Ждём окончания ролика" end
	if hold.head and GetTime() < hold.headUntil then return "Ждём, пока договорит NPC" end
	-- Реплики NPC: ждём до конца последней услышанной, но не дольше предела с момента, когда начали ждать
	if GetTime() < math.min(hold.sayUntil, hold.waitStart + MAX_NPC_WAIT) then return "Ждём, пока договорит NPC" end
	if GetTime() < hold.notBefore then return "..." end
	return nil
end

-- Показывает в окне субтитров, почему очередь стоит
local function ShowWaiting(reason)
	if not db.subtitles or #queue == 0 then return end
	subtitle = subtitle or CreateSubtitle()
	local nextItem = queue[1]
	local parts = {}
	if nextItem.npc then parts[#parts + 1] = nextItem.npc end
	if nextItem.title then parts[#parts + 1] = nextItem.title end
	SetPortrait(nextItem.key, false)
	subtitle.title:SetText(table.concat(parts, ": "))
	subtitle.count:SetText(("в очереди: %d"):format(#queue))
	subtitle.text:SetText("|cff999999" .. reason .. "|r")
	subtitle.skip:SetShown(false)
	subtitle.pause:SetText(hold.manual and "Дальше" or "Пауза")
	subtitle:Show()
end

-- Прерывает текущую реплику и возвращает её в начало очереди: после ожидания она прозвучит заново
-- resume: запомнить часть, на которой остановились, чтобы продолжить с неё, а не с начала
local function Interrupt(resume)
	if not current then return end
	local item = current
	StopAudio()
	current, currentHandle = nil, nil
	token = token + 1
	table.insert(queue, 1, { key = item.key, text = item.text, title = item.title, npc = item.npc,
		resumeSeg = resume and item.segIndex or nil, yielded = item.yielded, pauses = item.pauses })
end

-- Реплика закончилась сама или её пропустили: переходим к следующей после паузы
local function Finish(pause)
	current, currentHandle = nil, nil
	token = token + 1
	if #queue > 0 then
		local my = token
		if subtitle then subtitle.text:SetText("...") end
		C_Timer.After(pause or db.gap, function()
			if token == my and not current then StartNext() end
		end)
	elseif subtitle and not subtitle.preview then
		subtitle:Hide()
	end
end

-- Играет часть реплики и по её окончании запускает следующую
local function PlaySegment(item, segments, index, my)
	for _, ext in ipairs(EXTENSIONS) do
		local willPlay, handle = PlaySoundFile(SoundDir(item.key) .. item.key .. "-" .. index .. "." .. ext, db.channel)
		if willPlay then
			currentHandle = handle
			item.segIndex = index
			C_Timer.After(segments[index], function()
				if token ~= my then return end
				if index < #segments then
					if not PlaySegment(item, segments, index + 1, my) then Finish() end
				else
					C_Timer.After(0.4, function() if token == my then Finish() end end)
				end
			end)
			return true
		end
	end
	return false
end

function StartNext()
	if current or #queue == 0 then return end
	if not hold.waiting then
		hold.waiting = true
		hold.waitStart = GetTime()
	end
	local reason = HoldReason()
	if reason then
		if reason ~= "..." then ShowWaiting(reason) end
		if not retryPending and not hold.manual then
			retryPending = true
			C_Timer.After(0.5, function() retryPending = false; StartNext() end)
		end
		return
	end
	hold.waiting = false
	if subtitle then subtitle.pause:SetText("Пауза") end
	local item = table.remove(queue, 1)
	item.startedAt = GetTime()
	token = token + 1
	local my = token
	current = item

	-- Готовый звук играем, только если он есть в манифесте: оттуда же берём длительность.
	-- Число означает один файл, список - реплику, разрезанную на части по паузам между фразами.
	local entry = ChorusManifest and ChorusManifest[item.key]
	local segments = type(entry) == "table" and entry or nil
	local duration, offset = entry, 0
	if segments then
		duration = 0
		for _, length in ipairs(segments) do duration = duration + length end
		local first = math.max(1, math.min(item.resumeSeg or 1, #segments))
		for index = 1, first - 1 do offset = offset + segments[index] end
		if PlaySegment(item, segments, first, my) then item.mode = "file" end
	elseif duration then
		for _, ext in ipairs(EXTENSIONS) do
			local willPlay, handle = PlaySoundFile(SoundDir(item.key) .. item.key .. "." .. ext, db.channel)
			if willPlay then
				currentHandle = handle
				item.mode = "file"
				break
			end
		end
	end

	local estimate = math.max(2.5, CharCount(CleanText(item.text)) / (TTS_CPS * (1 + db.ttsRate * 0.08)))
	if not item.mode and db.tts then
		-- Режим выставляем заранее: событие начала речи может прийти прямо во время вызова
		item.mode = "tts"
		if not SpeakTts(item.text) then item.mode = nil end
	end
	if not item.mode then item.mode = "text" end
	if item.mode ~= "file" then duration, offset = estimate, 0 end

	ShowSubtitles(item, duration, my, offset)

	-- Реплика из частей завершается сама, когда доиграет последняя часть
	if item.mode == "file" and segments then return end
	-- Синтез сообщает об окончании событием, таймер для него только страховка
	local wait = item.mode == "tts" and (duration * 1.7 + 4) or (duration + 0.4)
	C_Timer.After(wait, function()
		if token == my then Finish() end
	end)
end

local function Enqueue(item)
	if not db.enabled or not item or not item.text then return end
	if current and current.key == item.key then return end
	for _, queued in ipairs(queue) do
		if queued.key == item.key then return end
	end
	queue[#queue + 1] = { key = item.key, text = item.text, title = item.title, npc = item.npc }
	if current then
		UpdateTitle()
	else
		-- Небольшая задержка перед началом: за это время игра успевает сообщить, что NPC заговорил сам
		if #queue == 1 then hold.notBefore = GetTime() + (db.preroll or 0) end
		StartNext()
	end
end

function TogglePause()
	hold.manual = not hold.manual
	if hold.manual then
		Interrupt(true)
		ShowWaiting("Пауза")
		if #queue == 0 and subtitle and not subtitle.preview then subtitle:Hide() end
	else
		StartNext()
	end
end

-- Читает текущую реплику заново с самого начала
function Restart()
	if current then
		Interrupt(false)
	elseif queue[1] then
		queue[1].resumeSeg = nil
	else
		return
	end
	hold.manual = false
	hold.notBefore = 0
	StartNext()
end

function StopAll()
	hold.manual = false
	wipe(queue)
	StopAudio()
	current, currentHandle = nil, nil
	token = token + 1
	if subtitle and not subtitle.preview then subtitle:Hide() end
end

function Skip()
	if not current then return end
	StopAudio()
	Finish(0.4)
end

----------------------------------------------------------------------
-- Сбор текстов
----------------------------------------------------------------------

-- Запоминает текст для генератора озвучки и возвращает реплику для очереди
local function Remember(key, text, title)
	text = Plain(text)
	if type(text) ~= "string" or text:trim() == "" then return nil end
	title = Plain(title)
	local npc = GetNpcInfo()
	local entry = db.texts[key]
	if not entry or entry.t ~= text then
		entry = { t = text, title = title }
		db.texts[key] = entry
	end
	entry.n, entry.s, entry.id = npc.name or entry.n, npc.sex or entry.s, npc.id or entry.id
	entry.r, entry.ct, entry.cti = npc.race or entry.r, npc.ct or entry.ct, npc.cti or entry.cti
	entry.m = npc.model or entry.m
	-- Модель подгружается не мгновенно: если номера ещё нет, спрашиваем повторно
	if not entry.m then
		local unit = NpcUnit()
		C_Timer.After(0.5, function()
			if UnitExists(unit) and Plain(UnitName(unit)) == entry.n then
				entry.m = GetModelFileID(unit) or entry.m
			end
		end)
	end
	return { key = key, text = text, title = title, npc = npc.name }
end

-- Описание задания из журнала: нужно для заданий, принятых без окна
local function QuestLogText(questID)
	if not (C_QuestLog and C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(questID)) then return nil end
	local ok, text = pcall(function()
		local previous = C_QuestLog.GetSelectedQuest()
		C_QuestLog.SetSelectedQuest(questID)
		local description = GetQuestLogQuestText()
		C_QuestLog.SetSelectedQuest(previous or 0)
		return description
	end)
	return ok and text or nil
end

-- Локальные задания и бонусные цели принимаются сами при входе в область: их не читаем
local function IsAutoTask(questID)
	if C_QuestLog.IsQuestTask and C_QuestLog.IsQuestTask(questID) then return true end
	if C_QuestLog.IsWorldQuest and C_QuestLog.IsWorldQuest(questID) then return true end
	local index = C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(questID)
	local info = index and C_QuestLog.GetInfo and C_QuestLog.GetInfo(index)
	return info and info.isHidden or false
end

local handlers = {}

function handlers.QUEST_DETAIL()
	local questID = GetQuestID()
	if not questID or questID == 0 then return end
	pendingAccept[questID] = Remember(("q%d_accept"):format(questID), GetQuestText(), GetTitleText())
end

local function QuestScene()
	hold.lastQuestEvent = GetTime()
	if current and GetTime() - hold.lastSayAt < 2 then YieldToNpc() end
end

function handlers.QUEST_ACCEPTED(questID)
	QuestScene()
	if not questID then return end
	local item = pendingAccept[questID]
	pendingAccept[questID] = nil
	if not item then
		if IsAutoTask(questID) then return end
		local title = C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(questID)
		local packed = ChorusTexts and ChorusTexts[("q%d_accept"):format(questID)]
		local text = Plain(QuestLogText(questID)) or (packed and packed.t)
		if type(text) ~= "string" or text:trim() == "" then return end
		local key = ("q%d_accept"):format(questID)
		if not db.texts[key] then db.texts[key] = { t = text, title = Plain(title) } end
		item = { key = key, text = text, title = Plain(title), npc = db.texts[key].n }
	end
	Enqueue(item)
end

function handlers.QUEST_PROGRESS()
	local questID = GetQuestID()
	if not questID or questID == 0 then return end
	Remember(("q%d_progress"):format(questID), GetProgressText(), GetTitleText())
end

function handlers.QUEST_COMPLETE()
	local questID = GetQuestID()
	if not questID or questID == 0 then return end
	pendingComplete[questID] = Remember(("q%d_complete"):format(questID), GetRewardText(), GetTitleText())
end

function handlers.QUEST_TURNED_IN(questID)
	QuestScene()
	local item = questID and pendingComplete[questID]
	if questID then pendingComplete[questID] = nil end
	if item and db.complete then Enqueue(item) end
end

function handlers.GOSSIP_SHOW()
	if not (C_GossipInfo and C_GossipInfo.GetText) then return end
	local text = Plain(C_GossipInfo.GetText())
	if type(text) ~= "string" or text == "" then return end
	local npc = GetNpcInfo()
	local item = Remember(("g%d_%s"):format(npc.id or 0, Hash(text)), text)
	if item and db.gossip then Enqueue(item) end
end

-- Говорящая голова: игра сообщает длительность реплики
function handlers.TALKINGHEAD_REQUESTED()
	local duration
	if C_TalkingHead and C_TalkingHead.GetCurrentLineInfo then
		local ok, _, _, _, lineDuration = pcall(C_TalkingHead.GetCurrentLineInfo)
		if ok then duration = Plain(lineDuration) end
	end
	hold.head = true
	hold.headUntil = GetTime() + (tonumber(duration) or 12) + 1
	YieldToNpc()
end

function handlers.TALKINGHEAD_CLOSE()
	hold.head = false
	-- После говорящей головы тоже выдерживаем паузу: часто следом идёт следующая реплика
	local untilTime = GetTime() + (db.npcTail or 0)
	if db.waitNpc and untilTime > hold.sayUntil then hold.sayUntil = untilTime end
end

-- Уступает NPC идущее чтение. Только что начатая реплика потом прозвучит заново,
-- а прерванная посередине продолжится с той же фразы. Не больше трёх раз на реплику, чтобы не было рывков.
function YieldToNpc()
	if not current or not db.waitNpc then return end
	local key = current.key
	if current.startedAt and GetTime() - current.startedAt < 2.5 and not current.resumeSeg then
		if current.yielded then return end
		Interrupt(false)
		if queue[1] and queue[1].key == key then queue[1].yielded = true end
	else
		local pauses = (current.pauses or 0) + 1
		if pauses > 3 then return end
		Interrupt(true)
		if queue[1] and queue[1].key == key then queue[1].pauses = pauses end
	end
	StartNext()
end

-- Далеко ли говорящий. Узнать это можно, только если у него видна полоска здоровья над головой и нет боя.
local function IsFar(guid)
	if type(guid) ~= "string" or InCombatLockdown() then return false end
	local ok, far = pcall(function()
		for _, plate in ipairs(C_NamePlate.GetNamePlates() or {}) do
			local unit = plate.namePlateUnitToken
			if unit and Plain(UnitGUID(unit)) == guid then
				return CheckInteractDistance(unit, 4) == false  -- дальше примерно 28 метров
			end
		end
		return false
	end)
	return ok and far or false
end

-- Реплики NPC в чате обычно сопровождаются голосом: длительность оцениваем по длине текста.
-- Запоминаем, до какого момента кто-то рядом говорит. Это влияет только на старт: уже начатое чтение не прерывается.
local function NoteSpeech(text, speaker, guid, giverOnly)
	if not db.waitNpc then return end
	speaker = Plain(speaker)
	local isGiver = #queue > 0 and type(speaker) == "string" and speaker == queue[1].npc
	if not isGiver then
		if giverOnly or not db.waitAny then return end
		if IsFar(Plain(guid)) then return end
	end
	text = Plain(text)
	local length = type(text) == "string" and CharCount(text) or 60
	local now = GetTime()
	-- Идёт диалог, если этот же NPC уже говорил недавно: значит, реплики следуют одна за другой
	local inDialog = type(speaker) == "string" and speakers[speaker] and now - speakers[speaker] < 45
	if type(speaker) == "string" then speakers[speaker] = now end
	-- Озвученная реплика длится дольше, чем кажется по тексту: считаем с запасом
	local tail = inDialog and math.max(db.npcTail or 0, DIALOG_TAIL) or (db.npcTail or 0)
	local untilTime = now + math.max(3, math.min(25, length / 10.5 + 1)) + tail
	if untilTime > hold.sayUntil then hold.sayUntil = untilTime end
	hold.lastSayAt = GetTime()
	if current then
		local fresh = current.startedAt and GetTime() - current.startedAt < 2.5 and not current.resumeSeg
		-- Уступаем, если наша реплика только началась, если говорит выдавший задание из очереди
		-- если идёт диалог (этот NPC уже говорил недавно)
		-- или если NPC заговорил сразу после взятия либо сдачи задания: это реплика сценки, а не болтовня вокруг
		if fresh or isGiver or inDialog or GetTime() - hold.lastQuestEvent < QUEST_SCENE_WINDOW then
			YieldToNpc()
		end
	end
end

local function NpcSay(text, speaker, _, _, _, _, _, _, _, _, _, guid) NoteSpeech(text, speaker, guid, false) end
-- Крик слышен на всю зону, поэтому учитываем его только от выдавшего задание
local function NpcYell(text, speaker, _, _, _, _, _, _, _, _, _, guid) NoteSpeech(text, speaker, guid, true) end
handlers.CHAT_MSG_MONSTER_SAY = NpcSay
handlers.CHAT_MSG_MONSTER_WHISPER = NpcSay
handlers.CHAT_MSG_MONSTER_PARTY = NpcSay
handlers.CHAT_MSG_MONSTER_YELL = NpcYell

local function MovieStart()
	hold.movie = true
	if db.waitNpc and current then Interrupt() end
end
local function MovieStop()
	hold.movie = false
	StartNext()
end
handlers.CINEMATIC_START = MovieStart
handlers.CINEMATIC_STOP = MovieStop
handlers.PLAY_MOVIE = MovieStart
handlers.STOP_MOVIE = MovieStop

function handlers.VOICE_CHAT_TTS_PLAYBACK_STARTED(utteranceID)
	if current and current.mode == "tts" and not current.utterance then
		current.utterance = utteranceID
	end
end

function handlers.VOICE_CHAT_TTS_PLAYBACK_FINISHED(utteranceID)
	if current and current.mode == "tts" and current.utterance == utteranceID then
		Finish()
	end
end

function handlers.ADDON_LOADED(name)
	if name ~= addonName then return end
	ChorusDB = ChorusDB or {}
	db = ChorusDB
	for key, value in pairs(defaults) do
		if db[key] == nil then
			db[key] = type(value) == "table" and {} or value
		end
	end
	if (db.tuning or 1) < 2 then
		if (db.npcTail or 0) < 3 then db.npcTail = 3 end
		db.tuning = 2
	end
	-- Раскладка версии 2: окно в три строки текста
	if (db.layout or 1) < 2 then
		db.height = math.max(db.height or 0, 34 + 3 * ((db.fontSize or 14) + 3) + 11)
		db.layout = 2
	end
end

local frame = CreateFrame("Frame")
for event in pairs(handlers) do frame:RegisterEvent(event) end
frame:SetScript("OnEvent", function(_, event, ...)
	if event ~= "ADDON_LOADED" and not db then return end
	handlers[event](...)
end)

----------------------------------------------------------------------
-- Команды чата
----------------------------------------------------------------------

local function CountTexts()
	local total, voiced = 0, 0
	for key in pairs(db.texts) do
		total = total + 1
		if ChorusManifest and ChorusManifest[key] then voiced = voiced + 1 end
	end
	return total, voiced
end

local function OnOff(value) return value and "|cff55ff55вкл|r" or "|cffff5555выкл|r" end

local function Toggle(field, label)
	db[field] = not db[field]
	print(PREFIX .. label .. " " .. OnOff(db[field]) .. ".")
end

local commands = {}

commands[""] = function()
	local total, voiced = CountTexts()
	print(PREFIX .. ("озвучка %s. Собрано текстов: %d, с готовым файлом: %d."):format(OnOff(db.enabled), total, voiced))
	print(PREFIX .. "/qv - открыть окно настроек, /qv help - этот список")
	print(PREFIX .. "/qv on | off - включить или выключить озвучку")
	print(PREFIX .. "/qv stop - остановить всё, /qv skip - следующее задание, /qv pause - пауза и продолжение, /qv restart - сначала")
	print(PREFIX .. "/qv waitnpc - ждать, пока договорит NPC (" .. OnOff(db.waitNpc) .. ")")
	print(PREFIX .. "/qv test 3 - проверка: прочитать три случайных задания подряд")
	print(PREFIX .. "/qv volume 0..100 - громкость озвучки")
	print(PREFIX .. "/qv subs - субтитры (" .. OnOff(db.subtitles) .. ")")
	print(PREFIX .. "/qv move - подвинуть и растянуть окно субтитров мышью, /qv resetpos - вернуть как было")
	print(PREFIX .. "/qv width <число>, /qv height <число>, /qv font <число> - ширина, высота окна и размер шрифта")
	print(PREFIX .. "/qv gap <сек> - пауза между заданиями (сейчас " .. db.gap .. ")")
	print(PREFIX .. "/qv complete - читать текст при сдаче задания (" .. OnOff(db.complete) .. ")")
	print(PREFIX .. "/qv gossip - читать обычные диалоги (" .. OnOff(db.gossip) .. ")")
	print(PREFIX .. "/qv tts - синтез речи, когда нет файла (" .. OnOff(db.tts) .. ")")
	print(PREFIX .. "/qv voices, /qv voice <номер>, /qv rate <-10..10> - настройки синтеза речи")
	print(PREFIX .. "/qv channel <Master|Dialog|SFX> - канал для файлов")
end

-- Тест: ставит в очередь N случайных заданий, для которых есть готовый звук
commands.test = function(arg)
	local keys = {}
	for key in pairs(ChorusManifest or {}) do
		if key:find("_accept$") then keys[#keys + 1] = key end
	end
	if #keys == 0 then
		print(PREFIX .. "готовых звуков нет: манифест пуст.")
		return
	end
	local count = math.max(1, math.min(10, tonumber(arg) or 1))
	local wasEnabled = db.enabled
	db.enabled = true
	for _ = 1, count do
		local key = keys[math.random(#keys)]
		local known = (ChorusTexts and ChorusTexts[key]) or db.texts[key] or {}
		Enqueue({ key = key, text = known.t or "(текст этого задания аддон ещё не видел)", title = known.title, npc = known.n })
	end
	db.enabled = wasEnabled
	print(PREFIX .. ("в очередь добавлено заданий: %d."):format(count))
end

commands.on = function() db.enabled = true; print(PREFIX .. "озвучка включена.") end
commands.off = function() db.enabled = false; StopAll(); print(PREFIX .. "озвучка выключена.") end
commands.stop = function() StopAll() end
commands.pause = function() TogglePause() end
commands.restart = function() Restart() end
commands.waitnpc = function() Toggle("waitNpc", "ожидание реплик NPC") end
commands.waitany = function() Toggle("waitAny", "учёт реплик любых NPC рядом") end
commands.skip = function() Skip() end
commands.tts = function() Toggle("tts", "синтез речи") end
commands.complete = function() Toggle("complete", "чтение при сдаче задания") end
commands.gossip = function() Toggle("gossip", "чтение диалогов") end

commands.subs = function()
	Toggle("subtitles", "субтитры")
	if not db.subtitles and subtitle then subtitle:Hide() end
end

commands.resetpos = function()
	db.pos, db.width, db.height, db.fontSize = nil, defaults.width, defaults.height, defaults.fontSize
	ApplyLayout()
	print(PREFIX .. "окно субтитров возвращено к исходному виду.")
end

commands.gap = function(arg)
	local value = tonumber(arg)
	if not value then print(PREFIX .. "укажите паузу в секундах, например /qv gap 2."); return end
	db.gap = math.max(0, math.min(15, value))
	print(PREFIX .. "пауза между заданиями: " .. db.gap .. " с.")
end

commands.voices = function()
	local ok, voices = pcall(C_VoiceChat.GetTtsVoices)
	if not ok or type(voices) ~= "table" or #voices == 0 then
		print(PREFIX .. "голоса синтеза не найдены. Установите голос в настройках речи системы.")
		return
	end
	local active = PickTtsVoice()
	for _, voice in ipairs(voices) do
		print(("%s%d - %s%s"):format(PREFIX, voice.voiceID, voice.name or "?", voice.voiceID == active and " |cff55ff55(выбран)|r" or ""))
	end
end

commands.voice = function(arg)
	local id = tonumber(arg)
	if not id then print(PREFIX .. "укажите номер голоса из /qv voices."); return end
	db.ttsVoice = id
	print(PREFIX .. "выбран голос " .. id .. ".")
end

commands.rate = function(arg)
	local value = tonumber(arg)
	if not value then print(PREFIX .. "укажите число от -10 до 10."); return end
	db.ttsRate = math.max(-10, math.min(10, value))
	print(PREFIX .. "скорость синтеза: " .. db.ttsRate .. ".")
end

local CHANNEL_CVAR = { Master = "Sound_MasterVolume", Dialog = "Sound_DialogVolume", SFX = "Sound_SFXVolume", Music = "Sound_MusicVolume", Ambience = "Sound_AmbienceVolume" }

-- Громкость озвучки: это громкость звукового канала игры, в котором играют файлы
commands.volume = function(arg)
	local cvar = CHANNEL_CVAR[db.channel] or "Sound_DialogVolume"
	local value = tonumber(arg)
	if not value then
		local current = math.floor((tonumber(GetCVar(cvar)) or 0) * 100 + 0.5)
		print(PREFIX .. ("громкость канала %s: %d. Изменить: /qv volume 0..100."):format(db.channel, current))
		return
	end
	value = math.max(0, math.min(100, value))
	SetCVar(cvar, value / 100)
	db.ttsVolume = value
	print(PREFIX .. ("громкость озвучки: %d (канал %s)."):format(value, db.channel))
end

-- Показывает окно субтитров с примером, чтобы его можно было подвинуть и растянуть
commands.move = function()
	subtitle = subtitle or CreateSubtitle()
	if subtitle.preview then
		subtitle.preview = nil
		if not current then subtitle:Hide() end
		print(PREFIX .. "положение и размер окна сохранены.")
		return
	end
	subtitle.preview = true
	if not current then
		SetPortrait(nil)
		subtitle.count:SetText("")
		subtitle.title:SetText("Настройка окна субтитров")
		subtitle.text:SetText("Перетащите окно мышью. Размер меняется за правый нижний угол. Закончить: /qv move")
		subtitle.skip:SetShown(false)
	end
	subtitle:Show()
	print(PREFIX .. "двигайте и растягивайте окно мышью, затем снова /qv move.")
end

local function SetNumber(field, arg, low, high, label)
	local value = tonumber(arg)
	if not value then print(PREFIX .. ("%s сейчас %s. Укажите число от %d до %d."):format(label, tostring(db[field]), low, high)); return end
	db[field] = math.max(low, math.min(high, value))
	ApplyLayout()
	print(PREFIX .. label .. ": " .. db[field] .. ".")
end

commands.width = function(arg) SetNumber("width", arg, 300, 1400, "ширина окна") end
commands.height = function(arg) SetNumber("height", arg, 60, 400, "высота окна") end
commands.font = function(arg) SetNumber("fontSize", arg, 8, 32, "размер шрифта") end

commands.channel = function(arg)
	local channels = { master = "Master", dialog = "Dialog", sfx = "SFX", music = "Music", ambience = "Ambience" }
	local channel = channels[(arg or ""):lower()]
	if not channel then print(PREFIX .. "доступные каналы: Master, Dialog, SFX, Music, Ambience."); return end
	db.channel = channel
	print(PREFIX .. "канал: " .. channel .. ".")
end

----------------------------------------------------------------------
-- Окно настроек
----------------------------------------------------------------------

local config

local function CreateConfig()
	local f = CreateFrame("Frame", "ChorusConfig", UIParent, "BasicFrameTemplateWithInset")
	f:SetSize(400, 730)
	f:SetPoint("CENTER")
	f:SetFrameStrata("DIALOG")
	f:SetMovable(true)
	f:SetClampedToScreen(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	tinsert(UISpecialFrames, "ChorusConfig")
	if f.TitleText then f.TitleText:SetText("Chorus: настройки") end

	local refreshers = {}
	local y = -34

	local function Header(text)
		local label = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
		label:SetPoint("TOPLEFT", 18, y)
		label:SetText(text)
		y = y - 20
	end

	local function Check(text, field, onChange)
		local check = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
		check:SetSize(24, 24)
		check:SetPoint("TOPLEFT", 16, y)
		local label = check.Text or check.text
		if label then
			label:SetText(text)
			label:SetFontObject("GameFontHighlight")
		end
		check:SetScript("OnClick", function(self)
			db[field] = self:GetChecked() and true or false
			if onChange then onChange(db[field]) end
		end)
		refreshers[#refreshers + 1] = function() check:SetChecked(db[field] and true or false) end
		y = y - 26
	end

	local function Slider(text, low, high, step, getter, setter, suffix)
		local label = f:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		label:SetPoint("TOPLEFT", 20, y)
		local slider = CreateFrame("Slider", nil, f, "UISliderTemplate")
		slider:SetSize(200, 16)
		slider:SetPoint("TOPRIGHT", -24, y + 1)
		slider:SetMinMaxValues(low, high)
		slider:SetValueStep(step)
		slider:SetObeyStepOnDrag(true)
		local function Show(value)
			label:SetText(("%s: |cffffffff%s%s|r"):format(text, tostring(value), suffix or ""))
		end
		slider:SetScript("OnValueChanged", function(self, value, userInput)
			value = math.floor(value / step + 0.5) * step
			Show(value)
			if userInput then setter(value) end
		end)
		refreshers[#refreshers + 1] = function()
			local value = getter()
			slider:SetValue(value)
			Show(value)
		end
		y = y - 28
	end

	local function Button(text, width, x, onClick)
		local button = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
		button:SetSize(width, 22)
		button:SetPoint("TOPLEFT", x, y)
		button:SetText(text)
		button:SetScript("OnClick", onClick)
		return button
	end

	local function VolumeCvar() return CHANNEL_CVAR[db.channel] or "Sound_DialogVolume" end

	Header("Озвучка")
	Check("Озвучка включена", "enabled", function(on) if not on then StopAll() end end)
	Check("Читать текст и при сдаче задания", "complete")
	Check("Читать обычные диалоги с NPC", "gossip")
	Check("Если нет готового файла, читать синтезом речи", "tts")
	Check("Обрывать речь при закрытии окна задания", "stopOnClose")
	Check("Ждать, пока договорит NPC или закончится ролик", "waitNpc")
	Check("Учитывать реплики любых NPC рядом, не только выдавшего", "waitAny")
	y = y - 4
	Slider("Громкость", 0, 100, 5,
		function() return math.floor((tonumber(GetCVar(VolumeCvar())) or 0) * 100 / 5 + 0.5) * 5 end,
		function(value) SetCVar(VolumeCvar(), value / 100); db.ttsVolume = value end)
	Slider("Пауза после реплики NPC", 0, 8, 0.5,
		function() return db.npcTail end, function(value) db.npcTail = value end, " с")
	Slider("Задержка перед чтением", 0, 5, 0.5,
		function() return db.preroll end, function(value) db.preroll = value end, " с")
	Slider("Пауза между заданиями", 0, 10, 0.5,
		function() return db.gap end, function(value) db.gap = value end, " с")

	y = y - 8
	Header("Субтитры")
	Check("Показывать субтитры", "subtitles", function(on) if not on and subtitle then subtitle:Hide() end end)
	Check("Показывать портрет говорящего", "portrait", function() ApplyLayout() end)
	y = y - 4
	Slider("Ширина окна", 300, 1400, 10,
		function() return db.width end, function(value) db.width = value; ApplyLayout() end)
	Slider("Высота окна", 60, 400, 2,
		function() return db.height end, function(value) db.height = value; ApplyLayout() end)
	Slider("Размер шрифта", 8, 32, 1,
		function() return db.fontSize end, function(value) db.fontSize = value; ApplyLayout() end)
	y = y - 4
	Button("Двигать окно мышью", 170, 18, function() commands.move() end)
	Button("Вернуть как было", 170, 196, function()
		commands.resetpos()
		for _, refresh in ipairs(refreshers) do refresh() end
	end)
	y = y - 36

	Header("Проверка")
	Button("Одно задание", 115, 18, function() commands.test("1") end)
	Button("Три подряд", 115, 139, function() commands.test("3") end)
	Button("Стоп", 115, 260, function() StopAll() end)
	y = y - 34

	f.status = f:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	f.status:SetPoint("TOPLEFT", 20, y)
	f.status:SetPoint("RIGHT", -20, 0)
	f.status:SetJustifyH("LEFT")

	f:SetScript("OnShow", function()
		for _, refresh in ipairs(refreshers) do refresh() end
		local total, voiced = CountTexts()
		local sounds = 0
		for _ in pairs(ChorusManifest or {}) do sounds = sounds + 1 end
		f.status:SetText(("Готовых звуков: %d. Текстов, собранных в игре: %d."):format(sounds, total))
	end)
	f:Hide()
	return f
end

local function ToggleConfig()
	config = config or CreateConfig()
	config:SetShown(not config:IsShown())
end

OpenConfig = ToggleConfig
commands.config = ToggleConfig
commands.options = ToggleConfig

-- Вызывается из меню аддонов у миникарты
function Chorus_OpenConfig() ToggleConfig() end

SLASH_CHORUS1 = "/chorus"
SLASH_CHORUS2 = "/qv"
SlashCmdList.CHORUS = function(msg)
	local cmd, arg = (msg or ""):trim():match("^(%S*)%s*(.-)$")
	cmd = (cmd or ""):lower()
	if cmd == "" then ToggleConfig(); return end
	if cmd == "help" then cmd = "" end
	local handler = commands[cmd] or commands[""]
	handler(arg)
end

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
	channel = "Master",   -- звуковой канал для файлов
	duck = true,          -- приглушать канал «Диалоги» игры, пока читает Chorus
	duckLevel = 20,       -- до скольких процентов приглушать
	duckMusic = false,    -- приглушать и музыку
	mail = true,          -- читать письма от NPC в почтовом ящике
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
	autoQuest = true,     -- читать задания сами (иначе только кнопкой «Озвучить» в окне задания)
	questButton = true,   -- кнопка «Озвучить» в окне задания
	complete = true,      -- читать текст при сдаче задания
	progress = true,      -- читать реплику NPC, когда пришёл с невыполненным заданием
	gossip = false,       -- читать обычные диалоги с NPC
	books = true,         -- читать книги, письма и таблички (окно текста)
	minimapButton = true, -- кнопка у миникарты
	minimapAngle = 200,   -- где она стоит на круге миникарты, градусы
	pos = nil,            -- сохранённое положение окна субтитров
	width = 520,          -- ширина окна субтитров
	height = 96,          -- высота окна субтитров: заголовок и три строки текста
	fontSize = 14,        -- размер шрифта субтитров
	texts = {},           -- собранные тексты: ключ -> { t, n, s, id, title }
	library = {},         -- прочитанные книги: ключ первой страницы -> { title, author, material, zone, at, pages }
}

local db
local queue = {}         -- очередь реплик
local current            -- реплика, которая звучит сейчас
local lastPlayed         -- последняя начатая реплика: её можно пометить и после окончания
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

local StopAll, Skip, TogglePause, Restart, SetPortrait, OpenConfig, YieldToNpc, MarkProblem  -- объявлены ниже

-- Иконки кнопок: свои, золотые с тенью, в папке Icons
local ICONS = {
	play = "Interface\\AddOns\\Chorus\\Icons\\play",
	pause = "Interface\\AddOns\\Chorus\\Icons\\pause",
	restart = "Interface\\AddOns\\Chorus\\Icons\\restart",
	stop = "Interface\\AddOns\\Chorus\\Icons\\stop",
	next = "Interface\\AddOns\\Chorus\\Icons\\next",
}

-- Узкая игровая кнопка (как «Принять») с иконкой вместо надписи; при нажатии иконка смещается, как текст у обычных кнопок
local function IconButton(parent, icon, tip, height)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	height = height or 20
	b:SetSize(height + 8, height)
	b.glyph = b:CreateTexture(nil, "OVERLAY")
	b.glyph:SetSize(height - 6, height - 6)
	b.glyph:SetPoint("CENTER")
	function b:SetIcon(path)
		self.glyph:SetTexture(path)
	end
	b:SetIcon(icon)
	b:HookScript("OnMouseDown", function(self) self.glyph:SetPoint("CENTER", 1, -1) end)
	b:HookScript("OnMouseUp", function(self) self.glyph:SetPoint("CENTER", 0, 0) end)
	b.tip = tip
	b:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText(self.tip)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function() GameTooltip:Hide() end)
	return b
end

-- Журнал последних событий очереди в ChorusDB.trace: по нему видно, почему реплика не прозвучала
local function Trace(text)
	if not db then return end
	db.trace = db.trace or {}
	db.trace[#db.trace + 1] = date("%H:%M:%S") .. " " .. text
	while #db.trace > 80 do table.remove(db.trace, 1) end
end

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
	f.gear:SetSize(18, 18)
	-- По центру кнопок высотой 22, которые начинаются на 4 пикселя ниже верха окна
	f.gear:SetPoint("TOPRIGHT", -8, -6)
	f.gear:SetNormalTexture("Interface\\Buttons\\UI-OptionsButton")
	f.gear:SetHighlightTexture("Interface\\Buttons\\UI-OptionsButton", "ADD")
	f.gear:SetScript("OnClick", function() if OpenConfig then OpenConfig() end end)
	f.gear:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("Настройки Chorus")
		GameTooltip:Show()
	end)
	f.gear:SetScript("OnLeave", function() GameTooltip:Hide() end)

	f.stop = IconButton(f, ICONS.stop, "Стоп: остановить всё")
	-- Кнопки выровнены по верху шестерёнки и выше неё: лишняя высота уходит вниз
	f.stop:SetSize(28, 22)
	f.stop:SetPoint("TOPRIGHT", f, "TOPRIGHT", -30, -4)
	f.stop:SetScript("OnClick", function() StopAll() end)

	-- Порядок справа налево: «Стоп», «Пауза», «Далее»
	f.pause = IconButton(f, ICONS.pause, "Пауза")
	f.pause:SetSize(28, 22)
	f.pause:SetPoint("TOPRIGHT", f.stop, "TOPLEFT", -4, 0)
	f.pause:SetScript("OnClick", function() TogglePause() end)

	f.skip = IconButton(f, ICONS.next, "Следующая реплика")
	f.skip:SetSize(28, 22)
	f.skip:SetPoint("TOPRIGHT", f.pause, "TOPLEFT", -4, 0)
	f.skip:SetScript("OnClick", function() Skip() end)
	-- Сколько ещё ждёт в очереди: маленькая цифра в углу стрелки
	f.skip.count = f.skip:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
	f.skip.count:SetPoint("BOTTOMRIGHT", 3, -2)

	f.restart = IconButton(f, ICONS.restart, "Сначала: прочитать текущую реплику заново")
	f.restart:SetSize(28, 22)
	-- «Следующая» прячется, когда очередь пуста: тогда «Сначала» встаёт вплотную к «Паузе», без дыры
	local function PlaceRestart()
		f.restart:ClearAllPoints()
		f.restart:SetPoint("TOPRIGHT", f.skip:IsShown() and f.skip or f.pause, "TOPLEFT", -4, 0)
	end
	f.PlaceRestart = PlaceRestart
	PlaceRestart()
	f.restart:SetScript("OnClick", function() Restart() end)

	-- Скрытая кнопка «Пометить ошибку» (/chorus dev): запоминает реплику с ошибкой произношения для исправления пакета
	f.mark = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	f.mark:SetSize(22, 22)
	f.mark:SetText("!")
	f.mark:SetPoint("TOPRIGHT", f.restart, "TOPLEFT", -4, 0)
	f.mark:SetScript("OnClick", function() MarkProblem() end)
	f.mark:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("Пометить ошибку")
		GameTooltip:AddLine("Запомнить эту реплику: неверное ударение, «е» вместо «э», не та интонация. Пояснение: /chorus mark <что не так>", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	f.mark:SetScript("OnLeave", function() GameTooltip:Hide() end)
	f.mark:SetShown(db.devMode and true or false)

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
		local alpha = (self.preview or self:IsMouseOver()) and 1 or 0.3
		self.stop:SetAlpha(alpha); self.skip:SetAlpha(alpha); self.pause:SetAlpha(alpha); self.grip:SetAlpha(alpha); self.gear:SetAlpha(alpha); self.restart:SetAlpha(alpha); self.mark:SetAlpha(alpha)
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
	-- Модель берём и из пакета, и из того, что аддон увидел в игре: в пакете её может не быть
	local packed = key and ChorusTexts and ChorusTexts[key]
	local seen = key and db.texts[key]
	local display = (packed and packed.d) or (seen and seen.d)
	local creature = (seen and seen.id) or (packed and packed.id)
	local shown = false
	if db.portrait and (display or creature) then
		shown = pcall(function()
			subtitle.portrait:SetWidth(math.max(40, subtitle:GetHeight() - 14))
			subtitle.portrait:Show()
			local model = subtitle.model
			model:ClearModel()
			if display then model:SetDisplayInfo(display) else model:SetCreature(creature) end
			model:SetPortraitZoom(0.85)
			model:SetAnimation(talking and 60 or 0)
		end)
	end
	subtitle.portraitShown = shown
	if not shown then subtitle.portrait:Hide() end
	local left = shown and (subtitle.portrait:GetWidth() + 18) or 14
	subtitle.title:ClearAllPoints()
	subtitle.title:SetPoint("TOPLEFT", left, -10)
	subtitle.title:SetPoint("RIGHT", subtitle.mark:IsShown() and subtitle.mark or subtitle.restart, "LEFT", -8, 0)
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
	subtitle.PlaceRestart()
	subtitle.skip.count:SetText(#queue)
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
	if queue[1] and queue[1].manual then return nil end
	if not db.waitNpc then
		return GetTime() < hold.notBefore and "..." or nil
	end
	-- Событие конца ролика приходит не всегда: если окна ролика уже нет на экране, больше не ждём
	if hold.movie and not ((CinematicFrame and CinematicFrame:IsShown()) or (MovieFrame and MovieFrame:IsShown())) then
		hold.movie = false
		Trace("ролик закончился без события")
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
	-- На паузе первая в очереди - это сама прерванная реплика, её не считаем
	local waiting = hold.manual and #queue - 1 or #queue
	subtitle.count:SetText(waiting > 0 and ("ещё в очереди: %d"):format(waiting) or "")
	subtitle.text:SetText("|cff999999" .. reason .. "|r")
	subtitle.skip:SetShown(false)
	subtitle.PlaceRestart()
	subtitle.pause:SetIcon(hold.manual and ICONS.play or ICONS.pause)
	subtitle.pause.tip = hold.manual and "Продолжить" or "Пауза"
	subtitle:Show()
end

-- Приглушение других голосов: пока читает Chorus, канал «Диалоги» игры убавляется, потом громкость возвращается.
-- Исходная громкость хранится в ChorusDB.duckSaved: после вылета или перезагрузки посреди чтения её вернёт вход в игру.
-- Канал, в котором играет сама озвучка, не приглушается: иначе заглушили бы и себя. По галочке приглушается и музыка
local function Duck(on)
	-- Прежний формат: сохранённая громкость одним числом (только диалоги)
	if type(db.duckSaved) == "number" then db.duckSaved = { Sound_DialogVolume = db.duckSaved } end
	if on and db.duck then
		db.duckSaved = db.duckSaved or {}
		local function Lower(cvar, channel)
			if db.channel == channel or db.duckSaved[cvar] then return end
			local volume = tonumber(GetCVar(cvar)) or 1
			db.duckSaved[cvar] = volume
			SetCVar(cvar, volume * (db.duckLevel or 20) / 100)
		end
		Lower("Sound_DialogVolume", "Dialog")
		if db.duckMusic then Lower("Sound_MusicVolume", "Music") end
	elseif db.duckSaved then
		for cvar, volume in pairs(db.duckSaved) do SetCVar(cvar, volume) end
		db.duckSaved = nil
	end
end

-- Прерывает текущую реплику и возвращает её в начало очереди: после ожидания она прозвучит заново
-- resume: запомнить часть, на которой остановились, чтобы продолжить с неё, а не с начала
local function Interrupt(resume)
	if not current then return end
	local item = current
	StopAudio()
	Duck(false)
	current, currentHandle = nil, nil
	token = token + 1
	table.insert(queue, 1, { key = item.key, text = item.text, title = item.title, npc = item.npc, book = item.book, lib = item.lib, manual = item.manual,
		resumeSeg = resume and item.segIndex or nil, yielded = item.yielded, pauses = item.pauses })
end

-- Реплика закончилась сама или её пропустили: переходим к следующей после паузы
local function Finish(pause)
	Duck(false)
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
	if reason and reason ~= hold.lastTraced then Trace(("ждём: %s (%s)"):format(reason, queue[1].key)) end
	hold.lastTraced = reason
	if reason then
		if reason ~= "..." then ShowWaiting(reason) end
		if not retryPending and not hold.manual then
			retryPending = true
			C_Timer.After(0.5, function() retryPending = false; StartNext() end)
		end
		return
	end
	hold.waiting = false
	if subtitle then subtitle.pause:SetIcon(ICONS.pause); subtitle.pause.tip = "Пауза" end
	local item = table.remove(queue, 1)
	item.startedAt = GetTime()
	lastPlayed = item
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
	Trace(("старт %s: %s, в манифесте %s"):format(item.key, item.mode, tostring(entry ~= nil)))
	if item.mode ~= "text" then Duck(true) end
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
	Trace(("в очередь %s: озвучка %s, текст %s"):format(item and item.key or "?", tostring(db.enabled), tostring(item and item.text ~= nil)))
	if not db.enabled or not item or not item.text then return end
	-- Нет готового звука и синтез выключен: читать нечем, беззвучные субтитры только держали бы очередь
	if not db.tts and not item.manual and not (ChorusManifest and ChorusManifest[item.key]) then
		Trace(("пропуск %s: нет звука, синтез выключен"):format(item.key))
		return
	end
	if current and current.key == item.key then return end
	for _, queued in ipairs(queue) do
		if queued.key == item.key then return end
	end
	queue[#queue + 1] = { key = item.key, text = item.text, title = item.title, npc = item.npc, book = item.book, lib = item.lib, manual = item.manual }
	if current then
		UpdateTitle()
	else
		-- Небольшая задержка перед началом: за это время игра успевает сообщить, что NPC заговорил сам
		if #queue == 1 then hold.notBefore = GetTime() + (item.manual and 0 or db.preroll or 0) end
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
	Duck(false)
	Trace("стоп всего")
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

----------------------------------------------------------------------
-- Кнопка «Озвучить» в окне задания: прослушать текст сразу, не принимая задание
----------------------------------------------------------------------

local shownQuest      -- реплика окна задания, открытого сейчас (описание, ход выполнения или награда)
local manualPlayed = {}  -- ключ -> когда прослушали кнопкой: после принятия второй раз не читаем
local MANUAL_MEMORY = 600
local questButton

-- Играет реплику сейчас же: всё, что звучало и ждало в очереди, прерывается. Повторный щелчок останавливает
local function PlayNow(item)
	if not item then return end
	if current and current.key == item.key then StopAll(); return end
	StopAll()
	hold.sayUntil = 0
	manualPlayed[item.key] = GetTime()
	local wasEnabled = db.enabled
	db.enabled = true
	Enqueue({ key = item.key, text = item.text, title = item.title, npc = item.npc, manual = true })
	db.enabled = wasEnabled
end

local function RecentlyPlayed(key)
	return manualPlayed[key] and GetTime() - manualPlayed[key] < MANUAL_MEMORY
end

-- Кнопка ставится внизу окна задания игры, а если его заменяет Immersion - над окном Immersion
local function AnchorQuestButton()
	local host, anchor
	if ImmersionFrame and ImmersionFrame:IsShown() then
		host, anchor = ImmersionFrame, ImmersionFrame.TalkBox or ImmersionFrame
	elseif QuestFrame and QuestFrame:IsShown() then
		host, anchor = QuestFrame, QuestFrame
	else
		return false
	end
	-- Кнопка живёт на слое окна задания: окна настроек и библиотеки всегда оказываются над ней
	questButton:SetParent(host)
	questButton:SetFrameStrata(host:GetFrameStrata())
	questButton:SetFrameLevel(host:GetFrameLevel() + 20)
	questButton:ClearAllPoints()
	if anchor == QuestFrame then
		-- Внизу окна по центру, между «Принять» и «Отказаться» («Отмена» и «Завершить»)
		questButton:SetPoint("BOTTOM", anchor, "BOTTOM", 0, 4)
	else
		questButton:SetPoint("BOTTOMRIGHT", anchor, "TOPRIGHT", 0, 4)
	end
	return true
end

-- Кнопка «Озвучить»: что читать, лежит в b.item. tip - подсказка под курсором
local function CreateQuestButton(name, tip)
	local b = CreateFrame("Button", name, UIParent, "UIPanelButtonTemplate")
	b:SetSize(118, 22)
	b.icon = b:CreateTexture(nil, "OVERLAY")
	b.icon:SetSize(16, 16)
	b.icon:SetPoint("LEFT", 6, 0)
	b.icon:SetTexture("Interface\\AddOns\\Chorus\\Icon")
	b:SetScript("OnClick", function(self) PlayNow(self.item) end)
	b:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("Chorus")
		GameTooltip:AddLine(tip, 1, 1, 1, true)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function() GameTooltip:Hide() end)
	-- Надпись следит за тем, звучит ли это задание
	b.elapsed = 0
	b:SetScript("OnUpdate", function(self, elapsed)
		self.elapsed = self.elapsed + elapsed
		if self.elapsed < 0.2 then return end
		self.elapsed = 0
		local playing = current and self.item and current.key == self.item.key
		self:SetText(playing and "    Стоп" or "    Озвучить")
	end)
	b:Hide()
	return b
end

local function ShowQuestButton(item)
	shownQuest = item
	if not item or not db.questButton then
		if questButton then questButton:Hide() end
		return
	end
	questButton = questButton or CreateQuestButton("ChorusQuestButton", "Прослушать текст задания сейчас, не принимая его. Повторный щелчок останавливает.")
	questButton.item = item
	-- Окно задания (своё или Immersion) появляется чуть позже события, поэтому ставим кнопку на следующем кадре
	C_Timer.After(0.05, function()
		if shownQuest == item and AnchorQuestButton() then questButton:Show() end
	end)
end

-- Кнопка в описании уже взятого задания (журнал заданий у карты и всплывающее окно описания):
-- читает текст взятия ещё раз. Показывается, только если для него есть звук или включён синтез
local logButtons = {}
local hookedLog = {}

local function LogQuestItem(questID)
	if not questID or questID == 0 then return nil end
	local key = ("q%d_accept"):format(questID)
	if not db.tts and not (ChorusManifest and ChorusManifest[key]) then return nil end
	local known = db.texts[key] or (ChorusTexts and ChorusTexts[key])
	local text = (known and known.t) or Plain(QuestLogText(questID))
	if type(text) ~= "string" or text:trim() == "" then return nil end
	local title = C_QuestLog.GetTitleForQuestID and Plain(C_QuestLog.GetTitleForQuestID(questID))
	return { key = key, text = text, title = title or (known and known.title), npc = known and known.n }
end

local function ShowLogButton(host, questID, x, y)
	local b = logButtons[host]
	local item = db and db.questButton and LogQuestItem(questID)
	if not item then
		if b then b:Hide() end
		return
	end
	if not b then
		b = CreateQuestButton(nil, "Прослушать текст этого задания ещё раз. Повторный щелчок останавливает.")
		b:SetParent(host)
		logButtons[host] = b
	end
	b.item = item
	b:SetFrameStrata(host:GetFrameStrata())
	b:SetFrameLevel(host:GetFrameLevel() + 20)
	b:ClearAllPoints()
	b:SetPoint("TOPRIGHT", host, "TOPRIGHT", x, y)
	b:Show()
end

-- Окна журнала заданий загружаются не сразу: пробуем подцепиться при входе и после загрузки модулей игры
local function HookQuestLog()
	local details = QuestMapFrame and QuestMapFrame.DetailsFrame
	if details and not hookedLog.map then
		hookedLog.map = true
		local function Update() ShowLogButton(details, C_QuestLog.GetSelectedQuest(), -8, -10) end
		details:HookScript("OnShow", function() C_Timer.After(0, Update) end)
		if QuestMapFrame_ShowQuestDetails then hooksecurefunc("QuestMapFrame_ShowQuestDetails", function() C_Timer.After(0, Update) end) end
	end
	local popup = QuestLogPopupDetailFrame
	if popup and not hookedLog.popup then
		hookedLog.popup = true
		popup:HookScript("OnShow", function(self)
			C_Timer.After(0, function() ShowLogButton(self, self.questID or C_QuestLog.GetSelectedQuest(), -30, -32) end)
		end)
	end
end

function handlers.QUEST_FINISHED()
	shownQuest = nil
	if questButton then questButton:Hide() end
end

function handlers.QUEST_DETAIL()
	local questID = GetQuestID()
	if not questID or questID == 0 then return end
	pendingAccept[questID] = Remember(("q%d_accept"):format(questID), GetQuestText(), GetTitleText())
	ShowQuestButton(pendingAccept[questID])
end

local function QuestScene()
	hold.lastQuestEvent = GetTime()
	if current and GetTime() - hold.lastSayAt < 2 then YieldToNpc() end
end

function handlers.QUEST_ACCEPTED(questID)
	Trace(("задание принято %s, окно видели %s"):format(tostring(questID), tostring(questID and pendingAccept[questID] ~= nil)))
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
	if RecentlyPlayed(item.key) then
		Trace(("не повторяем %s: уже слушали кнопкой"):format(item.key))
	elseif db.autoQuest then
		Enqueue(item)
	end
end

-- Окно хода выполнения. Если задание уже можно сдать, его не читаем: следом прозвучит текст сдачи
function handlers.QUEST_PROGRESS()
	local questID = GetQuestID()
	if not questID or questID == 0 then return end
	local item = Remember(("q%d_progress"):format(questID), GetProgressText(), GetTitleText())
	-- Задание в процессе: кнопку не показываем, слушать тут нечего
	ShowQuestButton(nil)
	local completable = IsQuestCompletable and IsQuestCompletable()
	if item and db.autoQuest and db.progress and not completable then Enqueue(item) end
end

function handlers.QUEST_COMPLETE()
	local questID = GetQuestID()
	if not questID or questID == 0 then return end
	pendingComplete[questID] = Remember(("q%d_complete"):format(questID), GetRewardText(), GetTitleText())
	ShowQuestButton(pendingComplete[questID])
end

function handlers.QUEST_TURNED_IN(questID)
	QuestScene()
	local item = questID and pendingComplete[questID]
	if questID then pendingComplete[questID] = nil end
	if item and db.autoQuest and db.complete and not RecentlyPlayed(item.key) then Enqueue(item) end
end

function handlers.GOSSIP_SHOW()
	if not (C_GossipInfo and C_GossipInfo.GetText) then return end
	local text = Plain(C_GossipInfo.GetText())
	if type(text) ~= "string" or text == "" then return end
	local npc = GetNpcInfo()
	local item = Remember(("g%d_%s"):format(npc.id or 0, Hash(text)), text)
	if item and db.gossip then Enqueue(item) end
end

-- Книги, письма и таблички: окно текста, срабатывает при открытии и на каждой странице.
-- Ключ страницы b<хеш названия и текста>: у табличек с одинаковым названием («Табличка», «Письмо») тексты разные.
-- Имя игрока в тексте заменяется на $N, чтобы ключ и озвучка были общими для всех персонажей.
-- Говорящего нет, поэтому голос рассказчика; у писем автор берётся из ItemTextGetCreator.
local function BookKey(title, text)
	return "b" .. Hash((title or "") .. "\n" .. text)
end

local function NormalizeBookText(text)
	local name = UnitName("player")
	if name and name ~= "" then
		text = text:gsub(name:gsub("%p", "%%%0"), "$N")
	end
	return text
end

-- Название страницы для субтитров и очереди
local function PageTitle(title, page)
	return title and page > 1 and ("%s, стр. %d"):format(title, page) or title
end

-- Убирает из очереди книги: открытые сейчас (book) и, если нужно, включённые из библиотеки (lib)
local function DropBooks(withLibrary)
	local function Match(item) return item.book or (withLibrary and item.lib) end
	for i = #queue, 1, -1 do
		if Match(queue[i]) then table.remove(queue, i) end
	end
	if current and Match(current) then Skip() end
end

local readingBook  -- ключ первой страницы книги, открытой сейчас: к ней цепляются следующие страницы

function handlers.ITEM_TEXT_BEGIN()
	readingBook = nil
end

function handlers.ITEM_TEXT_READY()
	local text = Plain(ItemTextGetText and ItemTextGetText())
	if type(text) ~= "string" then return end
	text = CleanText((text:gsub("<[^>]+>", " "))):gsub("%s+", " "):trim()
	if text == "" then return end
	local title = Plain(ItemTextGetItem and ItemTextGetItem())
	local page = (ItemTextGetPage and ItemTextGetPage()) or 1
	local author = Plain(ItemTextGetCreator and ItemTextGetCreator())
	local normalized = NormalizeBookText(text)
	local key = BookKey(title, normalized)
	local entry = db.texts[key]
	if not entry then
		entry = { t = normalized, title = title, page = page, kind = "book" }
		db.texts[key] = entry
	end
	entry.author = author or entry.author

	-- Библиотека: книга собирается из страниц по мере чтения, ключ книги - ключ её первой страницы
	if page == 1 then readingBook = key end
	if readingBook then
		local book = db.library[readingBook]
		if not book then
			book = { title = title, zone = Plain(GetRealZoneText()), at = time(), pages = {} }
			db.library[readingBook] = book
			print(PREFIX .. ("в библиотеку добавлено: |cffffd100%s|r. Переслушать: /chorus lib"):format(title or "без названия"))
		end
		book.author = author or book.author
		book.material = Plain(ItemTextGetMaterial and ItemTextGetMaterial()) or book.material
		book.pages[page] = key
	end

	if not db.books then return end
	-- Перелистнули страницу или открыли книгу во время прослушивания библиотеки: прежнее чтение больше не нужно
	DropBooks(true)
	Enqueue({ key = key, text = text, title = PageTitle(title, page), npc = author, book = true })
end

-- Книгу закрыли: её чтение больше не нужно, задания и прослушивание библиотеки остаются
function handlers.ITEM_TEXT_CLOSED()
	DropBooks(false)
end

-- Письма от NPC в почтовом ящике: читаются при открытии и попадают в библиотеку, как книги с автором.
-- Письма игроков, счета аукциона и пустые письма не трогаем. На ответ у NPC-писем нет кнопки (canReply = false)
local mailHooked
local function ReadOpenMail()
	if not (db and db.mail) then return end
	local index = InboxFrame and InboxFrame.openMailID
	if not index then return end
	local _, _, sender, subject, _, _, _, _, _, _, _, canReply, isGM = GetInboxHeaderInfo(index)
	local body, _, _, _, isInvoice = GetInboxText(index)
	sender, subject, body = Plain(sender), Plain(subject), Plain(body)
	if canReply or isGM or isInvoice or type(body) ~= "string" then return end
	local text = CleanText((body:gsub("<[^>]+>", " "))):gsub("%s+", " "):trim()
	if text == "" then return end
	local normalized = NormalizeBookText(text)
	local key = BookKey(subject, normalized)
	if not db.texts[key] then db.texts[key] = { t = normalized, title = subject, page = 1, kind = "book", author = sender } end
	if not db.library[key] then
		db.library[key] = { title = subject, author = sender, material = "Mail", zone = Plain(GetRealZoneText()), at = time(), pages = { key } }
		print(PREFIX .. ("в библиотеку добавлено письмо: |cffffd100%s|r"):format(subject or "без темы"))
	end
	DropBooks(true)
	Enqueue({ key = key, text = text, title = subject, npc = sender, book = true })
end

-- Окно почты загружается не сразу: подцепляемся, когда оно появится
local function HookMail()
	if mailHooked or not OpenMailFrame then return end
	mailHooked = true
	OpenMailFrame:HookScript("OnShow", function() C_Timer.After(0, ReadOpenMail) end)
	OpenMailFrame:HookScript("OnHide", function() DropBooks(false) end)
	if OpenMail_Update then hooksecurefunc("OpenMail_Update", function() C_Timer.After(0, ReadOpenMail) end) end
end

-- Переносит книги, собранные версией 0.2.0 (ключ b<хеш названия>_<страница>), в новые ключи и библиотеку
local function MigrateBooks()
	local books = {}
	for key, entry in pairs(db.texts) do
		local titleHash, page = key:match("^b(%x+)_(%d+)$")
		if titleHash and entry.kind == "book" then
			db.texts[key] = nil
			local newKey = BookKey(entry.title, entry.t)
			if not db.texts[newKey] then db.texts[newKey] = entry end
			books[titleHash] = books[titleHash] or {}
			books[titleHash][tonumber(page)] = newKey
		end
	end
	for _, pages in pairs(books) do
		local first = pages[1]
		if first and not db.library[first] then
			local entry = db.texts[first]
			db.library[first] = { title = entry.title, author = entry.author, at = time(), pages = pages }
		end
	end
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
	-- Запущенное кнопкой «Озвучить» не прерываем: игрок сам попросил послушать сейчас
	if not current or not db.waitNpc or current.manual then return end
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
	Trace("ролик начался")
	hold.movie = true
	if db.waitNpc and current then Interrupt() end
end
local function MovieStop()
	Trace("ролик закончился")
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
	if name ~= addonName then HookQuestLog(); HookMail(); return end
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
	-- Версия 3: текст сдачи задания читается по умолчанию (раньше был выключен)
	if db.tuning < 3 then
		db.complete = true
		db.tuning = 3
	end
	-- Книги версии 0.2.0: новые ключи страниц и библиотека
	if (db.booksVersion or 1) < 2 then
		MigrateBooks()
		db.booksVersion = 2
	end
	-- Версия 4: приглушение других голосов, поэтому озвучка уходит из канала «Диалоги» в «Общий»
	if db.tuning < 4 then
		if db.channel == "Dialog" then db.channel = "Master" end
		db.duck = true
		db.tuning = 4
	end
	-- Вылет или перезагрузка посреди чтения: возвращаем громкость диалогов
	Duck(false)
	-- Раскладка версии 2: окно в три строки текста
	if (db.layout or 1) < 2 then
		db.height = math.max(db.height or 0, 34 + 3 * ((db.fontSize or 14) + 3) + 11)
		db.layout = 2
	end
end

-- При выходе громкость диалогов должна сохраниться настоящей, а не приглушённой
function handlers.PLAYER_LOGOUT() Duck(false) end

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
	print(PREFIX .. "/chorus - открыть окно настроек, /chorus help - этот список")
	print(PREFIX .. "/chorus on | off - включить или выключить озвучку")
	print(PREFIX .. "/chorus stop - остановить всё, /chorus skip - следующее задание, /chorus pause - пауза и продолжение, /chorus restart - сначала")
	print(PREFIX .. "/chorus waitnpc - ждать, пока договорит NPC (" .. OnOff(db.waitNpc) .. ")")
	print(PREFIX .. "/chorus test 3 - проверка: прочитать три случайных задания подряд")
	print(PREFIX .. "/chorus volume 0..100 - громкость озвучки")
	print(PREFIX .. "/chorus subs - субтитры (" .. OnOff(db.subtitles) .. ")")
	print(PREFIX .. "/chorus move - подвинуть и растянуть окно субтитров мышью, /chorus resetpos - вернуть как было")
	print(PREFIX .. "/chorus width <число>, /chorus height <число>, /chorus font <число> - ширина, высота окна и размер шрифта")
	print(PREFIX .. "/chorus gap <сек> - пауза между заданиями (сейчас " .. db.gap .. ")")
	print(PREFIX .. "/chorus preset полная | кнопка | задания | максимум - готовые наборы настроек")
	print(PREFIX .. "/chorus auto - читать задания автоматически, иначе только кнопкой «Озвучить» (" .. OnOff(db.autoQuest) .. ")")
	print(PREFIX .. "/chorus complete - читать текст при сдаче задания (" .. OnOff(db.complete) .. ")")
	print(PREFIX .. "/chorus progress - читать реплику NPC, когда задание ещё не выполнено (" .. OnOff(db.progress) .. ")")
	print(PREFIX .. "/chorus gossip - читать обычные диалоги (" .. OnOff(db.gossip) .. ")")
	print(PREFIX .. "/chorus books - читать книги, письма и таблички (" .. OnOff(db.books) .. ")")
	print(PREFIX .. "/chorus lib - библиотека: прочитанные книги, письма и таблички, их можно переслушать")
	print(PREFIX .. "/chorus minimap - кнопка у миникарты (" .. OnOff(db.minimapButton) .. ")")
	print(PREFIX .. "/chorus tts - синтез речи, когда нет файла (" .. OnOff(db.tts) .. ")")
	print(PREFIX .. "/chorus voices, /chorus voice <номер>, /chorus rate <-10..10> - настройки синтеза речи")
	print(PREFIX .. "/chorus channel <Master|Dialog|SFX> - канал для файлов")
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
-- Пометка ошибок произношения (режим разработчика): список лежит в ChorusDB.reports
function MarkProblem()
	local item = current or lastPlayed
	if not item then print(PREFIX .. "нечего помечать: ещё ничего не звучало."); return end
	db.reports = db.reports or {}
	db.reports[#db.reports + 1] = { key = item.key, part = item.segIndex, at = date("%Y-%m-%d %H:%M:%S"),
		shown = subtitle and subtitle.text:GetText(), npc = item.npc, title = item.title }
	print(PREFIX .. ("помечено: %s%s. Пояснение: /chorus mark <что не так>"):format(item.key, item.segIndex and (", часть " .. item.segIndex) or ""))
end

commands.mark = function(arg)
	if not arg or arg == "" then MarkProblem(); return end
	if not (db.reports and #db.reports > 0) then MarkProblem() end
	local report = db.reports and db.reports[#db.reports]
	if report then
		report.note = arg
		print(PREFIX .. ("к пометке %s добавлено: %s"):format(report.key, arg))
	end
end

commands.dev = function()
	Toggle("devMode", "режим разработчика (кнопка «!» в окне субтитров)")
	if subtitle then
		subtitle.mark:SetShown(db.devMode and true or false)
		ApplyLayout()
	end
end

commands.auto = function() Toggle("autoQuest", "автоматическое чтение заданий") end
commands.complete = function() Toggle("complete", "чтение при сдаче задания") end
commands.progress = function() Toggle("progress", "чтение реплики о невыполненном задании") end
commands.books = function() Toggle("books", "чтение книг, писем и табличек") end
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
	if not value then print(PREFIX .. "укажите паузу в секундах, например /chorus gap 2."); return end
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
	if not id then print(PREFIX .. "укажите номер голоса из /chorus voices."); return end
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
		print(PREFIX .. ("громкость канала %s: %d. Изменить: /chorus volume 0..100."):format(db.channel, current))
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
		subtitle.text:SetText("Перетащите окно мышью. Размер меняется за правый нижний угол. Закончить: /chorus move")
		subtitle.skip:SetShown(false)
		subtitle.PlaceRestart()
	end
	subtitle:Show()
	print(PREFIX .. "двигайте и растягивайте окно мышью, затем снова /chorus move.")
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
	Duck(false)
	db.channel = channel
	print(PREFIX .. "канал: " .. channel .. ".")
end

----------------------------------------------------------------------
-- Окно настроек
----------------------------------------------------------------------

local config
local UpdateMinimapButton  -- объявлена ниже, у кнопки миникарты

local CHANNEL_NAMES = { Dialog = "Диалоги", Master = "Общий", SFX = "Эффекты", Ambience = "Окружение", Music = "Музыка" }
local CHANNEL_ORDER = { "Dialog", "Master", "SFX", "Ambience" }

-- Короткое имя голоса синтеза: без «Microsoft» и «Desktop»
local function ShortVoiceName(name)
	return ((name or "?"):gsub("^Microsoft ", ""):gsub(" Desktop", ""):gsub(" %- .*$", ""))
end

-- Готовые наборы: меняют только то, что и когда читать («Максимум» включает ещё синтез и приглушение музыки)
local PRESETS = {
	{ id = "full", name = "Полная озвучка", tip = "Задания читаются сами (взятие, сдача, «не выполнено»), книги и письма тоже. Обычные диалоги не читаются.",
		set = { autoQuest = true, questButton = true, complete = true, progress = true, gossip = false, books = true, mail = true, waitNpc = true } },
	{ id = "manual", name = "Только по кнопке", tip = "Само ничего не читается: задание звучит по кнопке «Озвучить» в окне задания или в журнале. Книги и письма молчат, но собираются в библиотеку.",
		set = { autoQuest = false, questButton = true, gossip = false, books = false, mail = false } },
	{ id = "quests", name = "Только задания", tip = "Задания читаются сами, книги, письма и диалоги - нет.",
		set = { autoQuest = true, questButton = true, complete = true, progress = true, gossip = false, books = false, mail = false } },
	{ id = "max", name = "Максимум", tip = "Читается всё, включая обычные диалоги NPC. Где нет готовой озвучки - синтез речи. Приглушаются и голоса вокруг, и музыка.",
		set = { autoQuest = true, questButton = true, complete = true, progress = true, gossip = true, books = true, mail = true, waitNpc = true, tts = true, duck = true, duckMusic = true } },
}

local function ApplyPreset(preset)
	for field, value in pairs(preset.set) do db[field] = value end
	Duck(false)
	print(PREFIX .. "набор настроек: " .. preset.name .. ".")
end

-- Какой набор совпадает с текущими настройками (nil - настроено вручную)
local function CurrentPreset()
	for _, preset in ipairs(PRESETS) do
		local same = true
		for field, value in pairs(preset.set) do
			if (db[field] and true or false) ~= value then same = false; break end
		end
		if same then return preset end
	end
end

local PRESET_ALIASES = { full = "full", ["полная"] = "full", manual = "manual", ["кнопка"] = "manual", quests = "quests", ["задания"] = "quests", max = "max", ["максимум"] = "max" }
commands.preset = function(arg)
	local id = PRESET_ALIASES[(arg or ""):lower()] or PRESET_ALIASES[arg or ""]
	for _, preset in ipairs(PRESETS) do
		if preset.id == id then ApplyPreset(preset); if config and config:IsShown() then config:Hide(); config:Show() end; return end
	end
	print(PREFIX .. "наборы: /chorus preset полная | кнопка | задания | максимум")
end

-- Окно настроек с вкладками: в каждой одна колонка, окно помещается в экран небольшой высоты (Steam Deck)
local CONFIG_TABS = { "Озвучка", "Звук и голос", "Субтитры", "Прочее" }

local function CreateConfig()
	local f = CreateFrame("Frame", "ChorusConfig", UIParent, "BasicFrameTemplateWithInset")
	f:SetSize(460, 540)
	f:SetPoint("CENTER")
	f:SetFrameStrata("DIALOG")
	f:SetMovable(true)
	f:SetClampedToScreen(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	tinsert(UISpecialFrames, "ChorusConfig")
	f:SetToplevel(true)
	local version = C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(addonName, "Version")
	if f.TitleText then f.TitleText:SetText(version and ("Chorus %s: настройки"):format(version) or "Chorus: настройки") end

	local refreshers = {}
	local function RefreshAll() for _, refresh in ipairs(refreshers) do refresh() end end

	-- Страница вкладки и текущая колонка на ней: элементы идут сверху вниз
	local page, y
	local X, WIDTH = 22, 410
	local function Page()
		page = CreateFrame("Frame", nil, f)
		page:SetPoint("TOPLEFT", 0, -28)
		page:SetPoint("BOTTOMRIGHT", 0, 0)
		page:Hide()
		y = -10
		return page
	end

	local function Tooltip(region, text)
		if not text then return end
		region:HookScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(text, 1, 1, 1, 1, true)
			GameTooltip:Show()
		end)
		region:HookScript("OnLeave", function() GameTooltip:Hide() end)
	end

	local function Header(text)
		if y < -10 then y = y - 8 end
		local label = page:CreateFontString(nil, "ARTWORK", "GameFontNormal")
		label:SetPoint("TOPLEFT", X, y)
		label:SetText(text)
		local line = page:CreateTexture(nil, "ARTWORK")
		line:SetHeight(1)
		line:SetPoint("TOPLEFT", X, y - 16)
		line:SetWidth(WIDTH)
		line:SetColorTexture(0.85, 0.68, 0.32, 0.35)
		y = y - 24
	end

	local function Note(text)
		local label = page:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
		label:SetPoint("TOPLEFT", X + 2, y)
		label:SetWidth(WIDTH - 4)
		label:SetJustifyH("LEFT")
		label:SetText(text)
		y = y - math.max(14, label:GetStringHeight()) - 6
		return label
	end

	local function Check(text, field, onChange, tip)
		local check = CreateFrame("CheckButton", nil, page, "UICheckButtonTemplate")
		check:SetSize(24, 24)
		check:SetPoint("TOPLEFT", X - 2, y)
		local label = check.Text or check.text
		if label then
			label:SetText(text)
			label:SetFontObject("GameFontHighlight")
			label:ClearAllPoints()
			label:SetPoint("LEFT", check, "RIGHT", 4, 1)
			label:SetWidth(WIDTH - 34)
			label:SetJustifyH("LEFT")
			label:SetWordWrap(false)
		end
		check:SetScript("OnClick", function(self)
			db[field] = self:GetChecked() and true or false
			if onChange then onChange(db[field]) end
		end)
		Tooltip(check, tip)
		refreshers[#refreshers + 1] = function() check:SetChecked(db[field] and true or false) end
		y = y - 25
	end

	local function Slider(text, low, high, step, getter, setter, suffix, tip)
		local label = page:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		label:SetPoint("TOPLEFT", X + 2, y - 4)
		local slider = CreateFrame("Slider", nil, page, "UISliderTemplate")
		slider:SetSize(160, 16)
		slider:SetPoint("TOPLEFT", X + WIDTH - 160, y - 3)
		slider:SetMinMaxValues(low, high)
		slider:SetValueStep(step)
		slider:SetObeyStepOnDrag(true)
		local function Show(value)
			label:SetText(("%s: |cffffffff%s%s|r"):format(text, tostring(value), suffix or ""))
		end
		slider:SetScript("OnValueChanged", function(_, value, userInput)
			value = math.floor(value / step + 0.5) * step
			Show(value)
			if userInput then setter(value) end
		end)
		Tooltip(slider, tip)
		refreshers[#refreshers + 1] = function()
			local value = getter()
			slider:SetValue(value)
			Show(value)
		end
		y = y - 27
	end

	-- Кнопка-переключатель: подпись слева, по щелчку выбирается следующее значение
	local function Cycle(text, getter, onClick, tip)
		local label = page:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		label:SetPoint("TOPLEFT", X + 2, y - 5)
		label:SetText(text)
		local button = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
		button:SetSize(160, 22)
		button:SetPoint("TOPLEFT", X + WIDTH - 160, y)
		button:SetScript("OnClick", function() onClick(); RefreshAll() end)
		Tooltip(button, tip)
		refreshers[#refreshers + 1] = function() button:SetText(getter()) end
		y = y - 28
	end

	local function Buttons(list)
		local gap = 8
		local width = (WIDTH - gap * (#list - 1)) / #list
		for index, spec in ipairs(list) do
			local button = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
			button:SetSize(width, 22)
			button:SetPoint("TOPLEFT", X + (index - 1) * (width + gap), y)
			button:SetText(spec[1])
			button:SetScript("OnClick", function() spec[2](); RefreshAll() end)
			Tooltip(button, spec[3])
		end
		y = y - 30
	end

	local function VolumeCvar() return CHANNEL_CVAR[db.channel] or "Sound_DialogVolume" end
	local function TtsVoices()
		local ok, voices = pcall(C_VoiceChat.GetTtsVoices)
		return ok and type(voices) == "table" and voices or {}
	end

	local pages = {}

	-- Вкладка 1: что и когда читать
	pages[1] = Page()
	-- Главный выключатель - первым на вкладке «Озвучка», крупнее остальных и с линией под ним
	local master = CreateFrame("CheckButton", nil, page, "UICheckButtonTemplate")
	master:SetSize(28, 28)
	master:SetPoint("TOPLEFT", X - 4, -4)
	local masterLabel = master.Text or master.text
	if masterLabel then
		masterLabel:SetFontObject("GameFontNormalLarge")
		local font, size, flags = masterLabel:GetFont()
		if font then masterLabel:SetFont(font, size - 1, flags) end
		masterLabel:SetText("Озвучка включена")
		masterLabel:ClearAllPoints()
		masterLabel:SetPoint("LEFT", master, "RIGHT", 4, 1)
	end
	master:SetScript("OnClick", function(self)
		db.enabled = self:GetChecked() and true or false
		if not db.enabled then StopAll() end
	end)
	refreshers[#refreshers + 1] = function() master:SetChecked(db.enabled and true or false) end
	local masterLine = page:CreateTexture(nil, "ARTWORK")
	masterLine:SetHeight(1)
	masterLine:SetPoint("TOPLEFT", X, -34)
	masterLine:SetWidth(WIDTH)
	masterLine:SetColorTexture(0.85, 0.68, 0.32, 0.6)
	y = -46
	Header("Готовые наборы")
	local presetButtons = {}
	do
		local gap = 6
		local width = (WIDTH - gap * (#PRESETS - 1)) / #PRESETS
		for index, preset in ipairs(PRESETS) do
			local button = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
			button:SetSize(width, 22)
			button:SetPoint("TOPLEFT", X + (index - 1) * (width + gap), y)
			button:SetText(preset.name)
			local label = button:GetFontString()
			if label then label:SetFontObject("GameFontHighlightSmall") end
			button:SetScript("OnClick", function() ApplyPreset(preset); RefreshAll() end)
			Tooltip(button, preset.tip)
			presetButtons[index] = button
		end
		y = y - 28
	end
	local presetNote = Note("")
	refreshers[#refreshers + 1] = function()
		local active = CurrentPreset()
		presetNote:SetText(active and ("Сейчас: |cffffd100" .. active.name .. "|r") or "Сейчас: свои настройки")
		for index, button in ipairs(presetButtons) do button:SetEnabled(PRESETS[index] ~= active) end
	end
	Header("Что читать")
	Check("Читать задания автоматически", "autoQuest", nil, "Выключите, чтобы задания звучали только по кнопке «Озвучить» в окне задания.")
	Check("Кнопка «Озвучить» в окне задания и в журнале", "questButton", nil, "Прослушать текст сразу, не принимая задание, или ещё раз - уже взятое.")
	Check("Текст при сдаче задания", "complete", nil, "После сдачи задания NPC читает текст из окна награды.")
	Check("Реплика, если задание не выполнено", "progress", nil, "Когда вы пришли к NPC, не выполнив задание («Ну что, принёс?»).")
	Check("Обычные диалоги с NPC", "gossip", nil, "Приветствие NPC в окне разговора, когда это не задание. Готовой озвучки у них пока нет: читает синтез речи, если он включён.")
	Check("Книги, письма и таблички", "books", nil, "Каждая страница при открытии. Прочитанное попадает в библиотеку.")
	Check("Письма от NPC на почте", "mail", nil, "Письмо от персонажа игры читается при открытии в почтовом ящике и попадает в библиотеку. Письма игроков и счета аукциона не читаются.")
	Header("Ожидание")
	Check("Ждать, пока договорит NPC", "waitNpc", nil, "Не перебивать говорящую голову, ролик или реплику NPC: чтение начнётся, когда они закончат.")
	Check("Учитывать любых NPC рядом", "waitAny", nil, "Ждать реплик всех NPC поблизости, а не только того, кто выдал задание.")
	Slider("Задержка перед чтением", 0, 5, 0.5,
		function() return db.preroll end, function(value) db.preroll = value end, " с",
		"Сколько ждать после взятия задания: за это время NPC часто успевает заговорить сам.")
	Slider("Пауза после реплики NPC", 0, 8, 0.5,
		function() return db.npcTail end, function(value) db.npcTail = value end, " с",
		"Сколько ещё ждать после реплики NPC: следом может заговорить другой.")
	Slider("Пауза между заданиями", 0, 10, 0.5,
		function() return db.gap end, function(value) db.gap = value end, " с")

	-- Вкладка 2: звук и синтез речи
	pages[2] = Page()
	Header("Звук")
	Cycle("Звуковой канал", function() return CHANNEL_NAMES[db.channel] or db.channel end, function()
		local index = 1
		for i, channel in ipairs(CHANNEL_ORDER) do if channel == db.channel then index = i end end
		Duck(false)
		db.channel = CHANNEL_ORDER[index % #CHANNEL_ORDER + 1]
	end, "Канал звука игры, в котором играет озвучка. В канале «Диалоги» приглушение других голосов не работает.")
	Slider("Громкость", 0, 100, 5,
		function() return math.floor((tonumber(GetCVar(VolumeCvar())) or 0) * 100 / 5 + 0.5) * 5 end,
		function(value) SetCVar(VolumeCvar(), value / 100); db.ttsVolume = value end, "%")
	Note("Громкость - это громкость выбранного канала в настройках звука игры: она меняет и другие звуки этого канала.")
	Check("Приглушать другие голоса, пока читает Chorus", "duck", function(on)
		if on and db.channel == "Dialog" then db.channel = "Master" end
		if not on then Duck(false) end
		RefreshAll()
	end, "Пока звучит озвучка, канал «Диалоги» игры убавляется, и болтовня NPC вокруг не мешает. Потом громкость возвращается. Работает, если озвучка играет не в канале «Диалоги».")
	Check("Приглушать и музыку", "duckMusic", function(on) if not on then Duck(false) end end,
		"Пока звучит озвучка, музыка игры тоже убавляется до того же уровня.")
	Slider("Приглушать до", 0, 100, 10,
		function() return db.duckLevel end, function(value) db.duckLevel = value end, "%",
		"Громкость голосов NPC, пока читает Chorus: 0 - тишина, 100 - без приглушения.")
	Header("Синтез речи")
	Note("Читает то, для чего нет готовой озвучки: задания других дополнений, диалоги, книги. Голоса берутся из системы.")
	Check("Читать синтезом, если нет озвучки", "tts")
	Cycle("Голос", function()
		local active = PickTtsVoice()
		for _, voice in ipairs(TtsVoices()) do
			if voice.voiceID == active then return ShortVoiceName(voice.name) end
		end
		return "нет голосов"
	end, function()
		local voices, active = TtsVoices(), PickTtsVoice()
		if #voices == 0 then return end
		local index = 1
		for i, voice in ipairs(voices) do if voice.voiceID == active then index = i end end
		db.ttsVoice = voices[index % #voices + 1].voiceID
		if not current then SpeakTts("Так звучит этот голос.") end
	end, "Щёлкните, чтобы выбрать следующий голос: прозвучит пример.")
	Slider("Скорость", -10, 10, 1,
		function() return db.ttsRate end, function(value) db.ttsRate = value end)

	-- Вкладка 3: окно субтитров
	pages[3] = Page()
	Header("Окно субтитров")
	Check("Показывать субтитры", "subtitles", function(on) if not on and subtitle then subtitle:Hide() end end)
	Check("Портрет говорящего", "portrait", function() ApplyLayout() end)
	Slider("Ширина окна", 300, 1400, 10,
		function() return db.width end, function(value) db.width = value; ApplyLayout() end)
	Slider("Высота окна", 60, 400, 2,
		function() return db.height end, function(value) db.height = value; ApplyLayout() end)
	Slider("Размер шрифта", 8, 32, 1,
		function() return db.fontSize end, function(value) db.fontSize = value; ApplyLayout() end)
	y = y - 4
	Buttons({
		{ "Двигать мышью", function() commands.move() end, "Показать окно субтитров, чтобы перетащить его и растянуть за угол. Повторный щелчок сохраняет." },
		{ "Как было", function() commands.resetpos() end, "Вернуть положение, размер окна и шрифт по умолчанию." },
	})

	-- Вкладка 4: библиотека, кнопка у миникарты, проверка
	pages[4] = Page()
	Header("Библиотека")
	Note("Всё, что вы открывали и читали в игре: книги, письма, таблички. Их можно переслушать.")
	Buttons({ { "Открыть библиотеку", function() commands.lib() end } })
	Header("Интерфейс")
	Check("Кнопка у миникарты", "minimapButton", function() UpdateMinimapButton() end, "Левый щелчок - настройки, правый - библиотека. Кнопку можно перетащить по кругу.")
	Header("Проверка")
	Buttons({
		{ "Прослушать пример", function() commands.test("1") end, "Прочитать случайное задание из пакета озвучки." },
		{ "Стоп", function() StopAll() end },
	})
	local status = Note("")
	refreshers[#refreshers + 1] = function()
		local total, voiced = CountTexts()
		local sounds = 0
		for _ in pairs(ChorusManifest or {}) do sounds = sounds + 1 end
		status:SetText(("Готовых звуков в пакетах: %d. Встречено в игре текстов: %d, из них без озвучки: %d - они войдут в следующие пакеты. Команды: /chorus help."):format(sounds, total, total - voiced))
	end

	-- Вкладки внизу окна, как у окон игры
	f.tabs = {}
	local function SelectTab(index)
		db.configTab = index
		for i, tab in ipairs(f.tabs) do
			pages[i]:SetShown(i == index)
			if i == index then pcall(PanelTemplates_SelectTab, tab) else pcall(PanelTemplates_DeselectTab, tab) end
		end
	end
	for i, name in ipairs(CONFIG_TABS) do
		local ok, tab = pcall(CreateFrame, "Button", "ChorusConfigTab" .. i, f, "PanelTabButtonTemplate")
		if not ok then tab = CreateFrame("Button", "ChorusConfigTab" .. i, f, "UIPanelButtonTemplate"); tab:SetSize(100, 22) end
		tab:SetText(name)
		if PanelTemplates_TabResize then pcall(PanelTemplates_TabResize, tab, 10) end
		if i == 1 then tab:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 8, 2) else tab:SetPoint("LEFT", f.tabs[i - 1], "RIGHT", 2, 0) end
		tab:SetScript("OnClick", function() SelectTab(i) end)
		f.tabs[i] = tab
	end

	f:SetScript("OnShow", function(self)
		self:Raise()
		RefreshAll()
		SelectTab(db.configTab or 1)
	end)
	f:Hide()
	return f
end

local function ToggleConfig()
	config = config or CreateConfig()
	config:SetShown(not config:IsShown())
end

----------------------------------------------------------------------
-- Библиотека: прочитанные книги, письма и таблички, их можно переслушать
----------------------------------------------------------------------

local library
local ROW_HEIGHT = 40
local MATERIAL_ICONS = {
	Stone = "Interface\\Icons\\INV_Misc_StoneTablet_05",
	Marble = "Interface\\Icons\\INV_Misc_StoneTablet_05",
	Bronze = "Interface\\Icons\\INV_Misc_StoneTablet_05",
	Silver = "Interface\\Icons\\INV_Misc_StoneTablet_05",
}

-- Нижний регистр с кириллицей: string.lower меняет только латиницу
local function Lower(text)
	text = text:gsub("\208\129", "\209\145")
	text = text:gsub("\208([\144-\175])", function(c)
		local b = c:byte()
		return b < 160 and ("\208" .. string.char(b + 32)) or ("\209" .. string.char(b - 32))
	end)
	return text:lower()
end

-- Обрезает строку UTF-8 примерно до limit байт, не разрывая букву
local function Cut(text, limit)
	if #text <= limit then return text end
	-- Отступаем, пока следующий байт - продолжение буквы
	while limit > 0 and text:byte(limit + 1) >= 128 and text:byte(limit + 1) < 192 do limit = limit - 1 end
	return text:sub(1, limit) .. "..."
end

-- Номера прочитанных страниц книги по порядку
local function BookPages(book)
	local pages = {}
	for page in pairs(book.pages or {}) do pages[#pages + 1] = page end
	table.sort(pages)
	return pages
end

local function BookVoiced(book)
	for _, key in pairs(book.pages or {}) do
		if not (ChorusManifest and ChorusManifest[key]) then return false end
	end
	return next(book.pages or {}) ~= nil
end

-- Ставит книгу в очередь целиком, со страницы 1. То, что читалось из библиотеки или книги до этого, прерывается
local function PlayBook(bookKey)
	local book = db.library[bookKey]
	if not book then return end
	DropBooks(true)
	local name = UnitName("player") or ""
	local wasEnabled = db.enabled
	db.enabled = true
	for _, page in ipairs(BookPages(book)) do
		local key = book.pages[page]
		local entry = db.texts[key] or (ChorusTexts and ChorusTexts[key])
		if entry and entry.t then
			Enqueue({ key = key, text = (entry.t:gsub("%$N", name)), title = PageTitle(book.title, page), npc = book.author, lib = true })
		end
	end
	db.enabled = wasEnabled
end

StaticPopupDialogs["CHORUS_FORGET_BOOK"] = {
	text = "Убрать «%s» из библиотеки?",
	button1 = YES,
	button2 = NO,
	OnAccept = function(_, bookKey)
		db.library[bookKey] = nil
		if library then library:Refresh() end
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
}

local function CreateLibraryRow(parent)
	local row = CreateFrame("Button", nil, parent)
	row:SetHeight(ROW_HEIGHT)
	row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(30, 30)
	row.icon:SetPoint("LEFT", 4, 0)

	row.forget = CreateFrame("Button", nil, row, "UIPanelCloseButton")
	row.forget:SetSize(24, 24)
	row.forget:SetPoint("RIGHT", -2, 0)
	row.forget:SetScript("OnClick", function()
		StaticPopup_Show("CHORUS_FORGET_BOOK", row.book.title or "без названия", nil, row.bookKey)
	end)

	row.play = IconButton(row, ICONS.play, "Слушать с первой страницы", 22)
	row.play:SetPoint("RIGHT", row.forget, "LEFT", -4, 0)
	row.play:SetScript("OnClick", function() PlayBook(row.bookKey) end)

	row.title = row:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	row.title:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 8, -1)
	row.title:SetPoint("RIGHT", row.play, "LEFT", -6, 0)
	row.title:SetJustifyH("LEFT")
	row.title:SetWordWrap(false)

	row.info = row:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	row.info:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 8, 1)
	row.info:SetPoint("RIGHT", row.play, "LEFT", -6, 0)
	row.info:SetJustifyH("LEFT")
	row.info:SetWordWrap(false)

	-- Двойной щелчок по строке тоже включает чтение, под курсором видно начало текста
	row:SetScript("OnDoubleClick", function(self) PlayBook(self.bookKey) end)
	row:SetScript("OnEnter", function(self)
		local first = self.book.pages[BookPages(self.book)[1]]
		local entry = first and (db.texts[first] or (ChorusTexts and ChorusTexts[first]))
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(self.book.title or "без названия", 1, 0.82, 0)
		if self.book.author then GameTooltip:AddLine(self.book.author, 0.8, 0.8, 0.8) end
		if entry and entry.t then
			GameTooltip:AddLine(Cut(entry.t:gsub("%$N", UnitName("player") or ""), 400), 1, 1, 1, true)
		end
		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", function() GameTooltip:Hide() end)
	return row
end

local function CreateLibrary()
	local f = CreateFrame("Frame", "ChorusLibrary", UIParent, "BasicFrameTemplateWithInset")
	f:SetSize(480, 520)
	f:SetPoint("CENTER")
	f:SetFrameStrata("DIALOG")
	f:SetMovable(true)
	f:SetClampedToScreen(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	tinsert(UISpecialFrames, "ChorusLibrary")
	f:SetToplevel(true)
	if f.TitleText then f.TitleText:SetText("Chorus: библиотека") end

	f.search = CreateFrame("EditBox", nil, f, "SearchBoxTemplate")
	f.search:SetSize(200, 20)
	f.search:SetPoint("TOPLEFT", 20, -32)
	f.search:SetAutoFocus(false)
	f.search:HookScript("OnTextChanged", function() f:Refresh() end)

	f.count = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	f.count:SetPoint("LEFT", f.search, "RIGHT", 12, 0)
	f.count:SetPoint("RIGHT", -20, 0)
	f.count:SetJustifyH("RIGHT")

	f.scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
	f.scroll:SetPoint("TOPLEFT", 12, -60)
	f.scroll:SetPoint("BOTTOMRIGHT", -32, 34)
	f.content = CreateFrame("Frame", nil, f.scroll)
	f.content:SetSize(1, 1)
	f.scroll:SetScrollChild(f.content)

	f.empty = f:CreateFontString(nil, "ARTWORK", "GameFontDisable")
	f.empty:SetPoint("TOPLEFT", f.scroll, "TOPLEFT", 10, -20)
	f.empty:SetPoint("RIGHT", f.scroll, "RIGHT", -10, 0)
	f.empty:SetJustifyH("CENTER")

	f.stop = IconButton(f, ICONS.stop, "Стоп: остановить чтение", 22)
	f.stop:SetPoint("BOTTOMRIGHT", -16, 8)
	f.stop:SetScript("OnClick", function() StopAll() end)

	f.hint = f:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	f.hint:SetPoint("BOTTOMLEFT", 18, 13)
	f.hint:SetPoint("RIGHT", f.stop, "LEFT", -8, 0)
	f.hint:SetJustifyH("LEFT")
	f.hint:SetText("Сюда попадает всё, что вы открывали и читали в игре.")

	f.rows = {}
	function f:Refresh()
		local query = Lower((self.search:GetText() or ""):trim())
		local list, total, voiced = {}, 0, 0
		for key, book in pairs(db.library) do
			total = total + 1
			if BookVoiced(book) then voiced = voiced + 1 end
			local haystack = Lower(table.concat({ book.title or "", book.author or "", book.zone or "" }, " "))
			if query == "" or haystack:find(query, 1, true) then
				list[#list + 1] = key
			end
		end
		table.sort(list, function(a, b) return (db.library[a].at or 0) > (db.library[b].at or 0) end)
		self.count:SetText(("Собрано: %d, с озвучкой: %d"):format(total, voiced))
		self.empty:SetText(total == 0 and "Библиотека пуста. Откройте в игре книгу, письмо или табличку, и она появится здесь." or (#list == 0 and "Ничего не найдено." or ""))

		-- Ширину считаем от окна: при первом показе у области прокрутки она ещё не посчитана
		local width = self:GetWidth() - 44
		self.content:SetSize(width, math.max(1, #list * ROW_HEIGHT))
		for index, key in ipairs(list) do
			local row = self.rows[index] or CreateLibraryRow(self.content)
			self.rows[index] = row
			local book = db.library[key]
			row.bookKey, row.book = key, book
			row:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
			row:SetWidth(width)
			local icon = MATERIAL_ICONS[book.material or ""] or (book.author and "Interface\\Icons\\INV_Letter_15") or "Interface\\Icons\\INV_Misc_Book_09"
			row.icon:SetTexture(icon)
			row.title:SetText(book.title or "без названия")
			local pages = #BookPages(book)
			local info = { pages == 1 and "1 стр." or (pages .. " стр.") }
			if book.zone then info[#info + 1] = book.zone end
			if book.at then info[#info + 1] = date("%d.%m.%Y", book.at) end
			info[#info + 1] = BookVoiced(book) and "|cff55ff55озвучено|r" or "синтез речи"
			row.info:SetText(table.concat(info, " · "))
			row:Show()
		end
		for index = #list + 1, #self.rows do self.rows[index]:Hide() end
	end

	f:SetScript("OnShow", function(self) self:Raise(); self:Refresh() end)
	f:Hide()
	return f
end

local function ToggleLibrary()
	library = library or CreateLibrary()
	library:SetShown(not library:IsShown())
end

commands.lib = ToggleLibrary
commands.library = ToggleLibrary

OpenConfig = ToggleConfig
commands.config = ToggleConfig
commands.options = ToggleConfig

----------------------------------------------------------------------
-- Кнопка у миникарты: левый щелчок - настройки, правый - библиотека, перетаскивается по кругу
----------------------------------------------------------------------

local ICON = "Interface\\AddOns\\Chorus\\Icon"
local minimapButton

local function PlaceMinimapButton()
	local angle = math.rad(db.minimapAngle or defaults.minimapAngle)
	local radius = Minimap:GetWidth() / 2 + 5
	minimapButton:ClearAllPoints()
	minimapButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function CreateMinimapButton()
	local b = CreateFrame("Button", "ChorusMinimapButton", Minimap)
	b:SetSize(31, 31)
	b:SetFrameStrata("MEDIUM")
	b:SetFrameLevel(8)
	b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	b:RegisterForDrag("LeftButton")

	local background = b:CreateTexture(nil, "BACKGROUND")
	background:SetSize(20, 20)
	background:SetPoint("TOPLEFT", 7, -5)
	background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
	local icon = b:CreateTexture(nil, "ARTWORK")
	icon:SetSize(19, 19)
	icon:SetPoint("TOPLEFT", 6, -6)
	icon:SetTexture(ICON)
	if icon.SetMask then icon:SetMask("Interface\\CharacterFrame\\TempPortraitAlphaMask") end
	local border = b:CreateTexture(nil, "OVERLAY")
	border:SetSize(53, 53)
	border:SetPoint("TOPLEFT")
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

	b:SetScript("OnClick", function(_, button)
		if button == "RightButton" then ToggleLibrary() else ToggleConfig() end
	end)
	b:SetScript("OnDragStart", function(self)
		self:SetScript("OnUpdate", function()
			local mx, my = Minimap:GetCenter()
			local px, py = GetCursorPosition()
			local scale = Minimap:GetEffectiveScale()
			db.minimapAngle = math.deg(math.atan2(py / scale - my, px / scale - mx))
			PlaceMinimapButton()
		end)
	end)
	b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
	b:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:SetText("Chorus")
		GameTooltip:AddLine("Левый щелчок: настройки", 1, 1, 1)
		GameTooltip:AddLine("Правый щелчок: библиотека", 1, 1, 1)
		GameTooltip:AddLine("Перетащите, чтобы передвинуть", 0.6, 0.6, 0.6)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function() GameTooltip:Hide() end)
	return b
end

UpdateMinimapButton = function()
	if not db.minimapButton then
		if minimapButton then minimapButton:Hide() end
		return
	end
	minimapButton = minimapButton or CreateMinimapButton()
	PlaceMinimapButton()
	minimapButton:Show()
end

commands.minimap = function()
	Toggle("minimapButton", "кнопка у миникарты")
	UpdateMinimapButton()
end

-- Кнопка создаётся при входе в игру: к этому времени настройки уже загружены
local loginFrame = CreateFrame("Frame")
loginFrame:RegisterEvent("PLAYER_LOGIN")
loginFrame:SetScript("OnEvent", function()
	local sounds = 0
	for _ in pairs(ChorusManifest or {}) do sounds = sounds + 1 end
	Trace(("вход: озвучка %s, звуков в пакетах %d, синтез %s, канал %s"):format(tostring(db.enabled), sounds, tostring(db.tts), tostring(db.channel)))
	UpdateMinimapButton()
	HookQuestLog()
	HookMail()
end)

-- Страница в настройках игры (Esc - Настройки - Модификации): оттуда открываются окно настроек и библиотека
local function RegisterSettingsPage()
	if not (Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory) then return end
	local page = CreateFrame("Frame")
	local title = page:CreateFontString(nil, "ARTWORK", "GameFontNormalHuge")
	title:SetPoint("TOPLEFT", 16, -16)
	title:SetText("Chorus")
	local about = page:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	about:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -10)
	about:SetPoint("RIGHT", -16, 0)
	about:SetJustifyH("LEFT")
	about:SetText("Озвучка заданий: каждый NPC говорит своим голосом. Настройки открываются в отдельном окне, его же открывают /chorus и кнопка у миникарты.")
	local function Open(toggle)
		if SettingsPanel and SettingsPanel:IsShown() then HideUIPanel(SettingsPanel) end
		toggle()
	end
	local configButton = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
	configButton:SetSize(180, 24)
	configButton:SetPoint("TOPLEFT", about, "BOTTOMLEFT", 0, -16)
	configButton:SetText("Открыть настройки")
	configButton:SetScript("OnClick", function() Open(ToggleConfig) end)
	local libraryButton = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
	libraryButton:SetSize(180, 24)
	libraryButton:SetPoint("LEFT", configButton, "RIGHT", 10, 0)
	libraryButton:SetText("Библиотека")
	libraryButton:SetScript("OnClick", function() Open(ToggleLibrary) end)
	local category = Settings.RegisterCanvasLayoutCategory(page, "Chorus")
	Settings.RegisterAddOnCategory(category)
end
pcall(RegisterSettingsPage)

-- Вызывается из меню аддонов у миникарты: левый щелчок - настройки, правый - библиотека
function Chorus_OpenConfig(_, button)
	if button == "RightButton" then ToggleLibrary() else ToggleConfig() end
end

SLASH_CHORUS1 = "/chorus"
SlashCmdList.CHORUS = function(msg)
	local cmd, arg = (msg or ""):trim():match("^(%S*)%s*(.-)$")
	cmd = (cmd or ""):lower()
	if cmd == "" then ToggleConfig(); return end
	if cmd == "help" then cmd = "" end
	local handler = commands[cmd] or commands[""]
	handler(arg)
end

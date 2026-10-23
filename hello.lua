--[[
    QQ GUI  |  Right Control = show / hide
    Tabs: ESP, Visuals, Potions, Settings

    Performance notes (loads in stages so it doesn't hitch / crash):
      1. Window shell appears first
      2. Tabs are built lazily the first time you open them
      3. ESP starts after the UI is up, and scans in small chunks
      4. Items are tracked with events (no constant workspace polling)
      5. Only the nearest MAX_HIGHLIGHTS get a Highlight (Roblox caps ~31 anyway);
         everything else still gets its billboard. Lower it if you still lag.
]]

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")

local lp = Players.LocalPlayer

--------------------------------------------------------------------
-- Config
--------------------------------------------------------------------
local MAX_HIGHLIGHTS = 25   -- lower this if the game still struggles
local TICK_RATE = 0.3      -- how often distances / highlight ranking update (seconds)
local SLOW_TICK = 2        -- how often Merchant / Live / pending items are re-checked
local SCAN_CHUNK = 100      -- children processed per frame during the first item scan

local cfg = {
	items = true,
	npc = true,         -- master switch for the NPC ESP group
	merchant = true,
	medic = true,
	antiquarian = true,
	campfire = true,
	live = true,
	fullbright = false,
	transparency = 0.5, -- fill transparency for ALL highlights
}

local ACCENT = Color3.fromRGB(240, 105, 140)
local BG = Color3.fromRGB(20, 20, 20)
local BG2 = Color3.fromRGB(26, 26, 26)
local BG3 = Color3.fromRGB(32, 32, 32)
local DIM = Color3.fromRGB(120, 120, 120)
local WHITE = Color3.fromRGB(230, 230, 230)
local FONT = Enum.Font.Code
local TEXT_SIZE = 11 -- billboard text size

local RED = Color3.fromRGB(255, 40, 40)
local PURPLE = Color3.fromRGB(170, 70, 255)
local ESP_WHITE = Color3.fromRGB(255, 255, 255)
local ESP_BLUE = Color3.fromRGB(50, 140, 255)

-- NPC ESP: every model with this name inside Workspace.NPCs gets highlighted
local NPC_RULES = {
	{ key = "merchant",    model = "Merchant",    color = RED },
	{ key = "medic",       model = "Doctor",      color = ESP_WHITE },
	{ key = "antiquarian", model = "Antiquarian", color = ESP_BLUE },
}

--------------------------------------------------------------------
-- Theme core
-- Every UI colour that matches one of the default theme colours is registered under a
-- "role" (ACCENT, BG, ...). Changing the theme just re-colours those registered objects.
--------------------------------------------------------------------
local HttpService = game:GetService("HttpService")
local THEME_FILE = "QQGui_theme.json"

local ROLES = { "ACCENT", "BG", "BG2", "BG3", "DARK", "DIM", "TEXT" } -- editable roles
local DEFAULT_THEME = {
	ACCENT = ACCENT, BG = BG, BG2 = BG2, BG3 = BG3,
	DARK = Color3.fromRGB(14, 14, 14), DIM = DIM, TEXT = WHITE,
}
-- the ORIGINAL colours, used only to recognise which role a new object belongs to
local ROLE_MATCH = {
	{ "ACCENT", ACCENT }, { "BG", BG }, { "BG2", BG2 }, { "BG3", BG3 },
	{ "DARK", DEFAULT_THEME.DARK }, { "DIM", DIM }, { "TEXT", WHITE },
	{ "STROKE", Color3.fromRGB(45, 45, 45) }, { "LINE", Color3.fromRGB(90, 45, 60) },
}
local COLOR_PROPS = { "BackgroundColor3", "TextColor3", "ScrollBarImageColor3", "Color" }

local T = {}            -- the current theme
local themed = {}       -- { instance, property, role }
local themeRefreshers = {} -- functions re-run after a theme change (selected tabs, rich text...)
local noTheme = false   -- set while building ESP labels so item colours never get re-themed

local function colorHex(c)
	return string.format("#%02X%02X%02X", math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
end

local function hexToColor(s)
	local clean = tostring(s):gsub("%s", ""):gsub("^#", "")
	local n = clean:match("^(%x%x%x%x%x%x)$")
	if not n then return nil end
	return Color3.fromRGB(tonumber(n:sub(1, 2), 16), tonumber(n:sub(3, 4), 16), tonumber(n:sub(5, 6), 16))
end

local function deriveTheme()
	T.STROKE = T.BG3:Lerp(T.TEXT, 0.12)
	T.LINE = T.ACCENT:Lerp(T.DARK, 0.55)
end

for k, v in pairs(DEFAULT_THEME) do T[k] = v end
deriveTheme()

-- load a saved theme (only works in executors that have file functions)
do
	local ok, data = pcall(function()
		if isfile and readfile and isfile(THEME_FILE) then
			return HttpService:JSONDecode(readfile(THEME_FILE))
		end
	end)
	if ok and type(data) == "table" then
		for _, r in ipairs(ROLES) do
			local c = type(data[r]) == "string" and hexToColor(data[r])
			if c then T[r] = c end
		end
		deriveTheme()
	end
end

local function registerTheme(inst, props)
	for _, prop in ipairs(COLOR_PROPS) do
		local v = props[prop]
		if typeof(v) == "Color3" then
			for _, m in ipairs(ROLE_MATCH) do
				if m[2] == v then
					themed[#themed + 1] = { inst, prop, m[1] }
					inst[prop] = T[m[1]] -- start in the current theme
					break
				end
			end
		end
	end
end

local function applyTheme()
	deriveTheme()
	for i = #themed, 1, -1 do
		local e = themed[i]
		if e[1].Parent == nil then
			table.remove(themed, i) -- destroyed
		else
			e[1][e[2]] = T[e[3]]
		end
	end
	for _, f in ipairs(themeRefreshers) do pcall(f) end
end

local saveToken = 0
local function scheduleSave()
	if not writefile then return end
	saveToken += 1
	local mine = saveToken
	task.delay(0.6, function()
		if mine ~= saveToken then return end
		local d = {}
		for _, r in ipairs(ROLES) do d[r] = colorHex(T[r]) end
		pcall(writefile, THEME_FILE, HttpService:JSONEncode(d))
	end)
end

local running = true
local connections = {}
local function connect(sig, fn)
	local c = sig:Connect(fn)
	table.insert(connections, c)
	return c
end

--------------------------------------------------------------------
-- Root gui
--------------------------------------------------------------------
local function getParent()
	if gethui then
		local ok, h = pcall(gethui)
		if ok and h then return h end
	end
	local ok = pcall(function() return game:GetService("CoreGui"):GetChildren() end)
	if ok then return game:GetService("CoreGui") end
	return lp:WaitForChild("PlayerGui")
end

local function new(class, props, parent)
	local o = Instance.new(class)
	for k, v in pairs(props or {}) do o[k] = v end
	if props and not noTheme then registerTheme(o, props) end
	if parent then o.Parent = parent end
	return o
end

local old = getParent():FindFirstChild("QQGui")
if old then old:Destroy() end

local gui = new("ScreenGui", {
	Name = "QQGui",
	ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	DisplayOrder = 999,
}, getParent())

local espFolder = new("Folder", { Name = "ESP" }, gui)

--------------------------------------------------------------------
-- UI helpers
--------------------------------------------------------------------
local function label(parent, text, props)
	local p = {
		BackgroundTransparency = 1,
		Font = FONT,
		Text = text,
		TextColor3 = WHITE,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left,
	}
	for k, v in pairs(props or {}) do p[k] = v end
	return new("TextLabel", p, parent)
end

local function section(parent, title)
	local f = new("Frame", { Size = UDim2.new(1, 0, 0, 22), BackgroundColor3 = BG3, BorderSizePixel = 0 }, parent)
	label(f, title, { Size = UDim2.new(1, -10, 1, 0), Position = UDim2.new(0, 6, 0, 0), TextColor3 = ACCENT })
	return f
end

local function toggle(parent, text, default, cb)
	local row = new("TextButton", {
		Size = UDim2.new(1, 0, 0, 24),
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
	}, parent)
	new("Frame", {
		Size = UDim2.fromOffset(4, 4),
		Position = UDim2.new(0, 6, 0.5, -2),
		BackgroundColor3 = ACCENT,
		BorderSizePixel = 0,
	}, row)
	label(row, text, { Size = UDim2.new(1, -60, 1, 0), Position = UDim2.new(0, 18, 0, 0) })
	local box = new("Frame", {
		Size = UDim2.fromOffset(16, 16),
		Position = UDim2.new(1, -24, 0.5, -8),
		BackgroundColor3 = BG3,
		BorderSizePixel = 0,
	}, row)
	local mark = new("Frame", {
		Size = UDim2.fromOffset(8, 8),
		Position = UDim2.fromOffset(4, 4),
		BackgroundColor3 = ACCENT,
		BorderSizePixel = 0,
		Visible = default,
	}, box)
	local state = default
	row.MouseButton1Click:Connect(function()
		state = not state
		mark.Visible = state
		cb(state)
	end)
end

local function slider(parent, text, min, max, def, dec, cb)
	local row = new("Frame", { Size = UDim2.new(1, 0, 0, 26), BackgroundTransparency = 1 }, parent)
	label(row, text, { Size = UDim2.new(0.35, 0, 1, 0), Position = UDim2.new(0, 18, 0, 0), TextColor3 = DIM })
	local bar = new("Frame", {
		Position = UDim2.new(0.38, 0, 0.5, -6),
		Size = UDim2.new(0.48, 0, 0, 12),
		BackgroundColor3 = BG3,
		BorderSizePixel = 0,
	}, row)
	local r0 = (def - min) / (max - min)
	local fill = new("Frame", { Size = UDim2.new(r0, 0, 1, 0), BackgroundColor3 = ACCENT, BackgroundTransparency = 0.6, BorderSizePixel = 0 }, bar)
	local val = label(row, string.format("%." .. dec .. "f", def), {
		Size = UDim2.new(0.12, 0, 1, 0), Position = UDim2.new(0.88, 0, 0, 0),
		TextColor3 = DIM, TextXAlignment = Enum.TextXAlignment.Right, TextSize = 12,
	})
	local dragging = false
	local function set(x)
		local r = math.clamp((x - bar.AbsolutePosition.X) / bar.AbsoluteSize.X, 0, 1)
		local v = min + (max - min) * r
		local m = 10 ^ dec
		v = math.floor(v * m + 0.5) / m
		fill.Size = UDim2.new(r, 0, 1, 0)
		val.Text = string.format("%." .. dec .. "f", v)
		cb(v)
	end
	bar.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			set(i.Position.X)
		end
	end)
	connect(UIS.InputChanged, function(i)
		if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
			set(i.Position.X)
		end
	end)
	connect(UIS.InputEnded, function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)
	-- returns a setter so the slider can be moved from code (without firing the callback)
	return function(v)
		local r = math.clamp((v - min) / (max - min), 0, 1)
		fill.Size = UDim2.new(r, 0, 1, 0)
		val.Text = string.format("%." .. dec .. "f", v)
	end
end

local function button(parent, text, cb)
	local b = new("TextButton", {
		Size = UDim2.new(1, -12, 0, 24),
		BackgroundColor3 = BG3,
		BorderSizePixel = 0,
		Font = FONT,
		Text = text,
		TextColor3 = ACCENT,
		TextSize = 13,
		AutoButtonColor = true,
	}, parent)
	b.MouseButton1Click:Connect(cb)
	return b
end

--------------------------------------------------------------------
-- STAGE 1: Window shell
--------------------------------------------------------------------
local main = new("Frame", {
	Name = "Main",
	Size = UDim2.fromOffset(700, 440),
	Position = UDim2.new(0.5, -350, 0.5, -220),
	BackgroundColor3 = BG,
	BorderSizePixel = 0,
}, gui)
new("UIStroke", { Color = Color3.fromRGB(45, 45, 45) }, main)

local titleBar = new("Frame", { Size = UDim2.new(1, 0, 0, 28), BackgroundColor3 = Color3.fromRGB(14, 14, 14), BorderSizePixel = 0 }, main)
label(titleBar, "QQ GUI", { Size = UDim2.new(1, -20, 1, 0), Position = UDim2.new(0, 14, 0, 0), TextColor3 = ACCENT })
new("Frame", { Size = UDim2.new(1, 0, 0, 1), Position = UDim2.new(0, 0, 1, 0), BackgroundColor3 = Color3.fromRGB(90, 45, 60), BorderSizePixel = 0 }, titleBar)

do -- dragging
	local dragging, startPos, startMouse
	titleBar.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = true
			startMouse = i.Position
			startPos = main.Position
		end
	end)
	connect(UIS.InputChanged, function(i)
		if dragging and i.UserInputType == Enum.UserInputType.MouseMovement then
			local d = i.Position - startMouse
			main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end)
	connect(UIS.InputEnded, function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
	end)
end

local tabBar = new("Frame", { Position = UDim2.fromOffset(0, 29), Size = UDim2.new(1, 0, 0, 30), BackgroundColor3 = Color3.fromRGB(14, 14, 14), BorderSizePixel = 0 }, main)
new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6) }, tabBar)
new("UIPadding", { PaddingLeft = UDim.new(0, 8) }, tabBar)

local content = new("Frame", {
	Position = UDim2.fromOffset(0, 60),
	Size = UDim2.new(1, 0, 1, -80),
	BackgroundTransparency = 1,
}, main)

local footer = new("Frame", { Position = UDim2.new(0, 0, 1, -18), Size = UDim2.new(1, 0, 0, 18), BackgroundColor3 = Color3.fromRGB(14, 14, 14), BorderSizePixel = 0 }, main)
local statusLbl = label(footer, "Version 2.6 (Colors)", { Size = UDim2.new(0.5, 0, 1, 0), Position = UDim2.new(0, 10, 0, 0), TextColor3 = DIM, TextSize = 11 })
label(footer, "RightCtrl = toggle", { Size = UDim2.new(0.5, -10, 1, 0), Position = UDim2.new(0.5, 0, 0, 0), TextColor3 = DIM, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Right })

-- Tabs are built lazily: the builder only runs the first time the tab is opened
local pages, tabButtons, builders, built = {}, {}, {}, {}
local currentTab = "ESP"

local function selectTab(name)
	if not built[name] and builders[name] then
		built[name] = true
		builders[name](pages[name])
	end
	for n, p in pairs(pages) do p.Visible = (n == name) end
	for n, b in pairs(tabButtons) do
		b.Button.TextColor3 = (n == name) and T.ACCENT or T.DIM
		b.Line.Visible = (n == name)
	end
	currentTab = name
end
table.insert(themeRefreshers, function() selectTab(currentTab) end)

local function addTab(name, builder)
	local btn = new("TextButton", {
		Size = UDim2.new(0, 90, 1, 0),
		BackgroundTransparency = 1,
		Font = FONT,
		Text = name,
		TextColor3 = DIM,
		TextSize = 13,
	}, tabBar)
	local line = new("Frame", { Size = UDim2.new(1, -10, 0, 1), Position = UDim2.new(0, 5, 1, -1), BackgroundColor3 = ACCENT, BorderSizePixel = 0, Visible = false }, btn)
	tabButtons[name] = { Button = btn, Line = line }

	local page = new("ScrollingFrame", {
		Size = UDim2.new(1, -16, 1, -8),
		Position = UDim2.fromOffset(8, 4),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 3,
		ScrollBarImageColor3 = ACCENT,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		Visible = false,
	}, content)
	new("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }, page)
	pages[name] = page
	builders[name] = builder
	btn.MouseButton1Click:Connect(function() selectTab(name) end)
	return page
end

--------------------------------------------------------------------
-- ESP engine (event driven, chunked, capped)
--------------------------------------------------------------------
-- The real position of a target. Model:GetPivot() can sit far from the actual body
-- (that caused the "4000 studs" readings), so use the character's root part instead.
local function getAnchor(inst)
	if inst:IsA("Model") then
		return inst:FindFirstChild("HumanoidRootPart")
			or inst.PrimaryPart
			or inst:FindFirstChild("Torso")
			or inst:FindFirstChild("Head")
			or inst:FindFirstChildWhichIsA("BasePart", true)
	end
	return inst
end

local entries = {}   -- [instance] = { kind, name, color, bb, lbl, hl, conns, dist, lastDist }
local pending = {}   -- [part] = time first seen (items whose ID child hasn't arrived yet)

local function removeEntry(inst)
	local e = entries[inst]
	if not e then return end
	entries[inst] = nil
	if e.hl then e.hl:Destroy() end
	if e.bb then e.bb:Destroy() end
	for _, c in ipairs(e.conns) do c:Disconnect() end
end

local function addEntry(inst, kind, name, color)
	local e = entries[inst]
	if e then
		if e.color ~= color then
			e.color = color
			e.lbl.TextColor3 = color
			if e.hl then
				e.hl.FillColor = color
				e.hl.OutlineColor = color
			end
		end
		return
	end

	noTheme = true -- ESP colours (item colours etc.) must never be re-themed
	local bb = new("BillboardGui", {
		Adornee = getAnchor(inst) or inst,
		AlwaysOnTop = true,
		Size = UDim2.fromOffset(170, 16),
		StudsOffset = Vector3.new(0, 2.5, 0),
		LightInfluence = 0,
		ResetOnSpawn = false,
	}, espFolder)

	local lbl = new("TextLabel", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Font = FONT,
		TextSize = TEXT_SIZE,
		TextColor3 = color,
		TextStrokeTransparency = 0,
		TextStrokeColor3 = Color3.new(0, 0, 0),
		Text = name,
	}, bb)

	noTheme = false
	e = { kind = kind, name = name, color = color, bb = bb, lbl = lbl, hl = nil, conns = {}, dist = math.huge, lastDist = -1 }
	entries[inst] = e

	-- auto clean up when the object is removed from the world
	table.insert(e.conns, inst.AncestryChanged:Connect(function()
		if not inst:IsDescendantOf(Workspace) then removeEntry(inst) end
	end))
end

local function removeKind(kind)
	for inst, e in pairs(entries) do
		if e.kind == kind then removeEntry(inst) end
	end
end

local function hasId(part)
	local v = part:FindFirstChild("ID")
	if v and v:IsA("ValueBase") then return true end
	if part:GetAttribute("ID") ~= nil then return true end
	return false
end

-- Items: only direct children of Workspace named "Part" that have an ID
local function considerItem(o, allowPending)
	if not cfg.items or entries[o] then return end
	if o.Name == "Part" and o:IsA("BasePart") then
		if hasId(o) then
			addEntry(o, "item", "Item", o.Color)
		elseif allowPending then
			pending[o] = os.clock()
		end
	end
end

local scanId = 0
local function scanItems()
	scanId += 1
	local myId = scanId
	local kids = Workspace:GetChildren()
	for i, o in ipairs(kids) do
		if not running or not cfg.items or myId ~= scanId then return end
		if o.Name == "Part" then considerItem(o, false) end
		if i % SCAN_CHUNK == 0 then task.wait() end -- yield so we never freeze the game
	end
end

local function reconcile(kind, wanted)
	for inst, e in pairs(entries) do
		if e.kind == kind and not wanted[inst] then removeEntry(inst) end
	end
end

-- NPC ESP: there can be several of each NPC, so check every child of Workspace.NPCs
local function syncNpcs()
	local npcs = Workspace:FindFirstChild("NPCs")
	for _, rule in ipairs(NPC_RULES) do
		local wanted = {}
		if cfg.npc and cfg[rule.key] and npcs then
			for _, m in ipairs(npcs:GetChildren()) do
				if m.Name == rule.model and m:IsA("PVInstance") then
					wanted[m] = true
					addEntry(m, rule.key, m.Name, rule.color)
				end
			end
		end
		reconcile(rule.key, wanted) -- removes ones that are gone / switched off
	end
end

-- Campfire ESP: models named "Campfire" inside Workspace.Map
-- (checks the folder's children and one level below, in case campfires sit inside map models)
-- Event driven: scanned ONCE (chunked, yielding) then new campfires are caught as they appear.
-- Nothing touches the big Map folder in the repeating loops anymore (that was the timed lag).
local CAMPFIRE_COLOR = Color3.fromRGB(255, 150, 40)
local campScanId = 0
local campHooked = false

local function considerCampfire(o)
	if cfg.campfire and o.Name == "Campfire" and o:IsA("PVInstance") and not entries[o] then
		addEntry(o, "campfire", "Campfire", CAMPFIRE_COLOR)
	end
end

local function scanCampfires()
	campScanId += 1
	local myId = campScanId
	local map = Workspace:FindFirstChild("Map")
	if not map then return end
	local n = 0
	for _, d in ipairs(map:GetDescendants()) do
		if not running or not cfg.campfire or myId ~= campScanId then return end
		if d.Name == "Campfire" then considerCampfire(d) end
		n += 1
		if n % 250 == 0 then task.wait() end
	end
end

local function hookCampfires()
	if campHooked then return end
	local map = Workspace:WaitForChild("Map", 30)
	if not map or not running then return end
	campHooked = true
	connect(map.DescendantAdded, function(o)
		if o.Name == "Campfire" then considerCampfire(o) end
	end)
	scanCampfires()
end

local function syncLive()
	if not cfg.live then return end
	local wanted = {}
	local live = Workspace:FindFirstChild("Live")
	if live then
		for _, m in ipairs(live:GetChildren()) do
			if m:IsA("Model") and m ~= lp.Character and m.Name ~= lp.Name then
				wanted[m] = true
				addEntry(m, "live", m.Name, PURPLE)
			end
		end
	end
	reconcile("live", wanted)
end

local function instPos(inst, e)
	-- anchor part is cached so we don't search the model every tick
	local a = e and e.anchor
	if not a or not a.Parent then
		a = getAnchor(inst)
		if e then
			e.anchor = a
			if a and e.bb.Adornee ~= a then e.bb.Adornee = a end
		end
	end
	if a then return a.Position end
	if inst:IsA("Model") then return inst:GetPivot().Position end
	return inst.Position
end

local function setHighlight(inst, e, on)
	if on then
		if not e.hl then
			e.hl = new("Highlight", {
				Adornee = inst,
				FillColor = e.color,
				OutlineColor = e.color,
				FillTransparency = cfg.transparency,
				OutlineTransparency = 0,
				DepthMode = Enum.HighlightDepthMode.AlwaysOnTop,
			}, espFolder)
		end
	elseif e.hl then
		e.hl:Destroy()
		e.hl = nil
	end
end

local function applyTransparency()
	for _, e in pairs(entries) do
		if e.hl then e.hl.FillTransparency = cfg.transparency end
	end
end

-- distances + highlight ranking (only the nearest MAX_HIGHLIGHTS get a Highlight)
local function refresh()
	local cam = Workspace.CurrentCamera
	local origin = cam and cam.CFrame.Position or Vector3.zero
	local char = lp.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if root then origin = root.Position end

	local ranked = {}
	for inst, e in pairs(entries) do
		if inst.Parent then
			if e.kind == "item" and e.color ~= inst.Color then
				e.color = inst.Color
				e.lbl.TextColor3 = e.color
				if e.hl then
					e.hl.FillColor = e.color
					e.hl.OutlineColor = e.color
				end
			end
			local d = (instPos(inst, e) - origin).Magnitude
			e.dist = d
			local rounded = math.floor(d + 0.5)
			if rounded ~= e.lastDist then -- only touch the text when it changes
				e.lastDist = rounded
				e.lbl.Text = string.format("%s [%d studs]", e.name, rounded)
			end
			ranked[#ranked + 1] = inst
		end
	end

	table.sort(ranked, function(a, b)
		local ea, eb = entries[a], entries[b]
		local pa = ea.kind == "item" and 1 or 0 -- merchant / live always rank first
		local pb = eb.kind == "item" and 1 or 0
		if pa ~= pb then return pa < pb end
		return ea.dist < eb.dist
	end)

	for i, inst in ipairs(ranked) do
		setHighlight(inst, entries[inst], i <= MAX_HIGHLIGHTS)
	end
end

local function startEsp()
	-- new items appear / disappear via events instead of polling the workspace
	connect(Workspace.ChildAdded, function(o)
		if o.Name == "Part" then considerItem(o, true) end
	end)
	connect(Workspace.ChildRemoved, function(o)
		pending[o] = nil
		removeEntry(o)
	end)

	task.spawn(scanItems) -- first scan is chunked
	task.spawn(hookCampfires)

	-- fast loop: distances / ranking
	task.spawn(function()
		while running do
			refresh()
			task.wait(TICK_RATE)
		end
	end)

	-- slow loop: Merchant, Live and items waiting for their ID child
	task.spawn(function()
		while running do
			syncNpcs()
			task.wait()
			syncLive()
			task.wait()
			for o, t in pairs(pending) do
				if not o.Parent or os.clock() - t > 5 then
					pending[o] = nil
				elseif hasId(o) then
					pending[o] = nil
					considerItem(o, false)
				end
			end
			task.wait(SLOW_TICK)
		end
	end)
end

--------------------------------------------------------------------
-- Fullbright (event based, only sets values that differ)
--------------------------------------------------------------------
local origLighting = {
	Ambient = Lighting.Ambient,
	OutdoorAmbient = Lighting.OutdoorAmbient,
	Brightness = Lighting.Brightness,
	ClockTime = Lighting.ClockTime,
	FogEnd = Lighting.FogEnd,
	GlobalShadows = Lighting.GlobalShadows,
}

local fbTarget = {
	Ambient = Color3.fromRGB(178, 178, 178),
	OutdoorAmbient = Color3.fromRGB(178, 178, 178),
	Brightness = 2,
	ClockTime = 14,
	FogEnd = 1e6,
	GlobalShadows = false,
}

local function applyFullbright()
	if not cfg.fullbright then return end
	for k, v in pairs(fbTarget) do
		if Lighting[k] ~= v then Lighting[k] = v end
	end
end

local function restoreLighting()
	for k, v in pairs(origLighting) do Lighting[k] = v end
end

for k in pairs(fbTarget) do
	connect(Lighting:GetPropertyChangedSignal(k), applyFullbright) -- game changed it? put it back
end

--------------------------------------------------------------------
-- Tab builders (run lazily)
--------------------------------------------------------------------
local function buildEsp(p)
	section(p, "Highlights")
	toggle(p, "Item ESP", cfg.items, function(v)
		cfg.items = v
		if v then task.spawn(scanItems) else removeKind("item") end
	end)
	section(p, "NPC ESP")
	toggle(p, "NPC ESP", cfg.npc, function(v)
		cfg.npc = v
		syncNpcs()
	end)
	toggle(p, "    Merchant ESP  (red)", cfg.merchant, function(v)
		cfg.merchant = v
		syncNpcs()
	end)
	toggle(p, "    Medic ESP  (white)", cfg.medic, function(v)
		cfg.medic = v
		syncNpcs()
	end)
	toggle(p, "    Antiquarian ESP  (blue)", cfg.antiquarian, function(v)
		cfg.antiquarian = v
		syncNpcs()
	end)
	section(p, "Map")
	toggle(p, "Campfire ESP  (orange)", cfg.campfire, function(v)
		cfg.campfire = v
		if v then task.spawn(scanCampfires) else campScanId += 1 removeKind("campfire") end
	end)
	section(p, "Live")
	toggle(p, "Live ESP", cfg.live, function(v)
		cfg.live = v
		if v then syncLive() else removeKind("live") end
	end)
	section(p, "Colors")
	label(p, "  Items = their own color   |   Live = purple", { Size = UDim2.new(1, 0, 0, 20), TextColor3 = DIM, TextSize = 12 })
	label(p, "  Merchant = red  |  Doctor = white  |  Antiquarian = blue  |  Campfire = orange", { Size = UDim2.new(1, 0, 0, 20), TextColor3 = DIM, TextSize = 12 })
end

local function buildVisuals(p)
	section(p, "World")
	toggle(p, "Fullbright", cfg.fullbright, function(v)
		cfg.fullbright = v
		if v then applyFullbright() else restoreLighting() end
	end)
	section(p, "Highlights")
	slider(p, "Transparency", 0, 1, cfg.transparency, 2, function(v)
		cfg.transparency = v
		applyTransparency()
	end)
end

local potions = {
	{
		name = "Bone Growth Potion",
		desc = "A magic potion that instantly mends severe internal bone and cartilage related damage when consumed.",
		tox = "49.9% (half your bar)",
		heals = { "Broken Leg", "Fractured Rib", "Dislocated Arm" },
		note = "Will not heal other injuries like Laceration or Burn Scar.",
		ing = {
			{ "Gaia", { "Trote", "Uncanny Tentacle", "Strange Tentacle" } },
			{ "Khei", { "Grass Tentacle", "Scroom (x2)" } },
		},
	},
	{
		name = "Fire Protection Potion",
		desc = "A fire protection potion.",
		tox = "33%",
		ing = { { nil, { "Trote", "Scroom (x2)" } } },
	},
	{
		name = "Switch Witch",
		desc = "Swaps gender.",
		tox = "25%",
		ing = { { nil, { "Dire Flower", "Glowshroom (x2)" } } },
	},
	{
		name = "Tespian Elixir",
		desc = "Can be imbibed to gain Orderly alignment in the early game. Below 10 Orderly the potion will damage and purify you (increasing Orderly by 2). Once you reach 10 Orderly it no longer increases your alignment and instead heals you.",
		tox = "16.67% (2.4% if you're a Construct)",
		ing = { { nil, { "Lava Flower", "Moss Plant (x2)", "Scroom" } } },
	},
	{
		name = "Silver Sun",
		desc = "Cures you from being a Vampire.",
		tox = "25%",
		ing = { { nil, { "Desert Mist", "FreeLeaf", "Polar Plant" } } },
	},
	{
		name = "Lords Bane",
		desc = "3.5x damage. Can only be consumed by Construct, Homunculus, and Lich.",
		tox = "650% (90% for Construct)",
		ing = { { nil, { "Crown Flower (x3)" } } },
	},
	{
		name = "Liquid Wisdom",
		desc = "Temporarily increases Scholar Boon.",
		tox = "~50% [?] roughly",
		ing = { { nil, { "Desert Mist", "Periashroom", "Crown Flower", "FreeLeaf" } } },
	},
	{
		name = "Ice Protection",
		desc = "Increases Cold Resistance.",
		tox = "30%",
		ing = { { nil, { "Snowscroom (x2)", "Trote" } } },
	},
	{
		name = "Health Potion",
		desc = "Restores Health (35 HP).",
		tox = "24.5% (~3.45% for Construct)",
		ing = {
			{ "Gaia", { "Scroom (x2)", "Lava Flower" } },
			{ "Khei", { "Scroom", "Coconut", "Grass Stem" } },
		},
	},
	{
		name = "Kingsbane",
		desc = "2x movement and attack speed for 2 minutes. Can only be consumed by races with above average toxicity, such as Construct, Homunculus, and Lich.",
		tox = "420 points / 499% for any normal race",
		ing = { { nil, { "Vile Seed (x2)", "Crown Flower" } } },
	},
	{
		name = "Fall Protection (2nd 'Ice Protection')",
		desc = "Negates all fall damage for 30 seconds.",
		tox = "15% (2.1% for Construct)",
		ing = { { nil, { "Creely", "Dire Flower", "Polar Plant" } } },
	},
}

local function hex(c)
	return string.format("#%02x%02x%02x", math.floor(c.R * 255), math.floor(c.G * 255), math.floor(c.B * 255))
end

local function potionText(po)
	local acc = hex(T.ACCENT)
	local dim = hex(T.DIM)
	local s = {}
	table.insert(s, string.format('<font color="%s"><b>%s</b></font>', acc, po.name))
	table.insert(s, "")
	table.insert(s, string.format('<font color="%s">Description</font>', acc))
	table.insert(s, po.desc)
	table.insert(s, string.format('<font color="%s">Toxicity:</font> %s', dim, po.tox))
	if po.heals then
		table.insert(s, "")
		table.insert(s, string.format('<font color="%s">Will heal</font>', acc))
		for _, h in ipairs(po.heals) do table.insert(s, "  - " .. h) end
		if po.note then table.insert(s, string.format('<font color="%s">%s</font>', dim, po.note)) end
	end
	table.insert(s, "")
	table.insert(s, string.format('<font color="%s">Ingredients</font>', acc))
	for _, group in ipairs(po.ing) do
		if group[1] then table.insert(s, string.format('<font color="%s">%s</font>', dim, group[1])) end
		for _, item in ipairs(group[2]) do table.insert(s, "  - " .. item) end
	end
	return table.concat(s, "\n")
end

local function buildPotions(p)
	p:FindFirstChildOfClass("UIListLayout"):Destroy()
	p.AutomaticCanvasSize = Enum.AutomaticSize.None
	p.ScrollBarThickness = 0

	local list = new("ScrollingFrame", {
		Size = UDim2.new(0, 190, 1, 0),
		BackgroundColor3 = BG2,
		BorderSizePixel = 0,
		ScrollBarThickness = 3,
		ScrollBarImageColor3 = ACCENT,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
	}, p)
	new("UIListLayout", { Padding = UDim.new(0, 1) }, list)

	local detail = new("ScrollingFrame", {
		Position = UDim2.new(0, 198, 0, 0),
		Size = UDim2.new(1, -198, 1, 0),
		BackgroundColor3 = BG2,
		BorderSizePixel = 0,
		ScrollBarThickness = 3,
		ScrollBarImageColor3 = ACCENT,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
	}, p)
	new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingTop = UDim.new(0, 8), PaddingRight = UDim.new(0, 10), PaddingBottom = UDim.new(0, 8) }, detail)
	local body = new("TextLabel", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Font = FONT,
		TextSize = 13,
		TextColor3 = WHITE,
		TextWrapped = true,
		RichText = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Text = "",
	}, detail)

	local btns = {}
	local cur = 1
	local function pick(i)
		cur = i
		body.Text = potionText(potions[i])
		for j, b in ipairs(btns) do
			b.TextColor3 = (j == i) and T.ACCENT or T.DIM
			b.BackgroundColor3 = (j == i) and T.BG3 or T.BG2
		end
	end
	table.insert(themeRefreshers, function() pick(cur) end)
	for i, po in ipairs(potions) do
		local b = new("TextButton", {
			Size = UDim2.new(1, 0, 0, 24),
			BackgroundColor3 = BG2,
			BorderSizePixel = 0,
			Font = FONT,
			Text = "  " .. po.name,
			TextColor3 = DIM,
			TextSize = 12,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			AutoButtonColor = false,
		}, list)
		b.MouseButton1Click:Connect(function() pick(i) end)
		btns[i] = b
	end
	pick(1)
end

--------------------------------------------------------------------
-- Spells (mana bar stays visible on the left the whole time)
--------------------------------------------------------------------
local spellCats = {
	{ title = "Spells available to everyone" },
	{ title = "Curse Spells", note = "These are spells that will unlock the target's Mana upon being hit." },
	{ title = "God Spells", note = "These are spells only usable by Mages at super class or higher." },
}

-- castR / snapR are used to show the range on the mana bar
local spells = {
	-- Spells available to everyone
	{ cat = 1, name = "Celeritas", effects = "Enhances speed of targets. Works on anyone if houseless.",
		cast = { "70-99% mana charge", "70-85% mana charge (Snap)" }, castR = { 70, 99 }, snapR = { 70, 85 }, obtained = "Scrolls" },
	{ cat = 1, name = "Trickstus", effects = "The target becomes unable to see other players or NPCs for a time, excluding speech bubbles. If backfired, the effect is instead applied to you.",
		cast = { "30-70% mana to cast", "30-50% mana to cast (Snap)" }, castR = { 30, 70 }, snapR = { 30, 50 }, obtained = "Scrolls" },
	{ cat = 1, name = "Sagitta Sol", effects = "Summons Golden Archer. If backfired, the caster will get knocked back and take some damage.",
		cast = { "50-60% mana to cast", "40-70% mana to cast (Snap)" }, castR = { 50, 60 }, snapR = { 40, 70 }, obtained = "Scrolls" },
	{ cat = 1, name = "Scrupus", effects = "Summons a pillar next to the caster, and the caster then rips a stone sword out of it.",
		cast = { "1-100% mana to cast" }, castR = { 1, 100 }, obtained = "Scrolls" },
	{ cat = 1, name = "Viribus", effects = "Unearths two lines of stone pillars in front of the user (can break through mana shield).",
		cast = { "25-35% mana to cast", "60-75% mana for casting the snap" }, castR = { 25, 35 }, snapR = { 60, 75 }, obtained = "Scrolls" },
	{ cat = 1, name = "Velo", effects = "Creates a ball of light for the caster.",
		cast = { "50-100%", "50-60% (Snap)" }, castR = { 50, 100 }, snapR = { 50, 60 }, obtained = "Scrolls" },
	{ cat = 1, name = "Telorum", effects = "Summons a bow of light that you fire automatically. Automatically 'snaps' onto the nearest player that your bow is facing.",
		cast = { "80-90%", "70-80% (Snap)" }, castR = { 80, 90 }, snapR = { 70, 80 }, obtained = "Scroll" },
	{ cat = 1, name = "Nocere", effects = "A curse spell that can be used on a player who is knocked down. The victim receives a random injury (Bones, Chest Gashes, Concussion, Cataract, etc.).",
		cast = { "70-80%" }, castR = { 70, 80 }, obtained = "Set your mana color/percentage to 70-80% as a mage and use the spell on a knocked-down player." },
	{ cat = 1, name = "Armis", effects = "Disarms the target of their held weapon-type item.",
		cast = { "40-60% mana to cast", "70-85% mana to cast (Snap)" }, castR = { 40, 60 }, snapR = { 70, 85 }, obtained = "Scrolls" },
	{ cat = 1, name = "Gate", effects = "Allows easy transportation throughout the world.",
		cast = { "75-85% (Gate, Snap Gate)", "Any% (Azaels, Seraphs)" }, castR = { 75, 85 }, obtained = "Rift Gem, Racial Ability" },
	{ cat = 1, name = "Snarvindur", effects = "Creates a large propelling force forward.",
		cast = { "55-75%", "15-30% (Snap)" }, castR = { 55, 75 }, snapR = { 15, 30 }, obtained = "Scroll" },

	-- Curse Spells
	{ cat = 2, name = "Ignis", effects = "Creates a short wave of fire in front of the caster.",
		cast = { "85-95% mana to cast", "45-60% mana to cast (Snap)" }, castR = { 85, 95 }, snapR = { 45, 60 }, obtained = "Scrolls" },
	{ cat = 2, name = "Gelidus", effects = "Creates a close-range cone of ice in front of the caster.",
		cast = { "80-100% mana to cast (same for snap)" }, castR = { 80, 100 }, snapR = { 80, 100 }, obtained = "Acquiring an Ice Essence" },
	{ cat = 2, name = "Trahere", effects = "Gives mana to those who do not have it.",
		cast = { "75-85% mana to cast" }, castR = { 75, 85 }, obtained = "Scrolls" },

	-- God Spells
	{ cat = 3, name = "Manus Dei", effects = "Charges up, then rains down a large fireball at the cursor location.",
		cast = { "90-95%", "50-60% (Snap)" }, castR = { 90, 95 }, snapR = { 50, 60 }, obtained = "Scroll" },
	{ cat = 3, name = "Fimbulvetr", effects = "Calls down an icy chain on the caster's cursor location.",
		cast = { "90-95%", "70-80% (Snap)" }, castR = { 90, 95 }, snapR = { 70, 80 }, obtained = "Scroll" },
	{ cat = 3, name = "Contrarium", effects = "Disables Mana Charge.",
		cast = { "90-100%", "70-90% (Snap)" }, castR = { 90, 100 }, snapR = { 70, 90 }, obtained = "Scrolls" },
	{ cat = 3, name = "Hoppa", effects = "Flings the user into the sky with fall damage immunity.",
		cast = { "30-60%", "50-65% (Snap)" }, castR = { 30, 60 }, snapR = { 50, 65 }, obtained = "Scroll Roulette" },
	{ cat = 3, name = "Percutiens", effects = "Fires a large lightning bolt to the cursor.",
		cast = { "55-70%", "70-80% (Snap)" }, castR = { 55, 70 }, snapR = { 70, 80 }, obtained = "Scroll Roulette" },
	{ cat = 3, name = "Sraunus (Khei only spell)", effects = "Caster thrusts forward, burning anyone in path.",
		cast = { "1-50% mana to cast (staff any %)", "No Snap" }, castR = { 1, 50 }, obtained = "Trinket spawns, Scroll Roulette" },
}

local function spellText(sp)
	local acc = hex(T.ACCENT)
	local dim = hex(T.DIM)
	local cat = spellCats[sp.cat]
	local s = {}
	table.insert(s, string.format('<font color="%s"><b>%s</b></font>', acc, sp.name))
	table.insert(s, string.format('<font color="%s">%s</font>', dim, cat.title))
	if cat.note then table.insert(s, string.format('<font color="%s">%s</font>', dim, cat.note)) end
	table.insert(s, "")
	table.insert(s, string.format('<font color="%s">Effects</font>', acc))
	table.insert(s, sp.effects)
	table.insert(s, "")
	table.insert(s, string.format('<font color="%s">Casting Range</font>', acc))
	for _, c in ipairs(sp.cast) do table.insert(s, "  - " .. c) end
	table.insert(s, "")
	table.insert(s, string.format('<font color="%s">Obtained By</font>', acc))
	table.insert(s, "  - " .. sp.obtained)
	return table.concat(s, "\n")
end

local function buildSpells(p)
	p:FindFirstChildOfClass("UIListLayout"):Destroy()
	p.AutomaticCanvasSize = Enum.AutomaticSize.None
	p.ScrollBarThickness = 0

	-- fixed mana bar panel (never scrolls, always visible)
	local panel = new("Frame", { Size = UDim2.new(0, 98, 1, 0), BackgroundColor3 = BG2, BorderSizePixel = 0 }, p)
	label(panel, "Mana", {
		Size = UDim2.new(1, 0, 0, 20), Position = UDim2.fromOffset(0, 2),
		TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = ACCENT, TextSize = 12,
	})

	local bar = new("Frame", {
		Position = UDim2.new(0, 28, 0, 26),
		Size = UDim2.new(0, 30, 1, -70),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
	}, panel)
	new("UIGradient", {
		Rotation = 90, -- top -> bottom
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(150, 20, 255)),   -- 100% purple
			ColorSequenceKeypoint.new(0.3, Color3.fromRGB(195, 80, 170)),
			ColorSequenceKeypoint.new(0.6, Color3.fromRGB(240, 150, 50)),  -- orange
			ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 230, 0)),    -- 0% yellow
		}),
	}, bar)

	for v = 10, 90, 10 do
		local y = 1 - v / 100
		new("Frame", { -- divider line
			Size = UDim2.new(1, 0, 0, 1), Position = UDim2.new(0, 0, y, 0),
			BackgroundColor3 = Color3.fromRGB(60, 40, 40), BackgroundTransparency = 0.45, BorderSizePixel = 0,
		}, bar)
		local tag = new("TextLabel", { -- tan number tag like the wiki bar
			Size = UDim2.fromOffset(26, 14), Position = UDim2.new(1, 5, y, -7),
			BackgroundColor3 = Color3.fromRGB(222, 170, 110), BorderSizePixel = 0,
			Font = FONT, Text = tostring(v), TextSize = 11, TextColor3 = Color3.fromRGB(40, 25, 10),
		}, bar)
		new("UICorner", { CornerRadius = UDim.new(0, 4) }, tag)
	end

	-- range strips for the selected spell (left of the bar)
	local castBand = new("Frame", { Size = UDim2.new(0, 5, 0, 0), BackgroundColor3 = ESP_WHITE, BorderSizePixel = 0, Visible = false, Position = UDim2.new(0, -14, 0, 0) }, bar)
	local snapBand = new("Frame", { Size = UDim2.new(0, 5, 0, 0), BackgroundColor3 = Color3.fromRGB(70, 220, 255), BorderSizePixel = 0, Visible = false, Position = UDim2.new(0, -22, 0, 0) }, bar)

	local function setBand(band, r)
		if r then
			band.Visible = true
			band.Position = UDim2.new(0, band.Position.X.Offset, 1 - r[2] / 100, 0)
			band.Size = UDim2.new(0, 5, math.max((r[2] - r[1]) / 100, 0.01), 0)
		else
			band.Visible = false
		end
	end

	-- legend
	local function legend(y, color, text)
		new("Frame", { Size = UDim2.fromOffset(6, 6), Position = UDim2.new(0, 8, 1, y + 4), BackgroundColor3 = color, BorderSizePixel = 0 }, panel)
		label(panel, text, { Size = UDim2.new(1, -20, 0, 14), Position = UDim2.new(0, 18, 1, y), TextColor3 = DIM, TextSize = 11 })
	end
	legend(-38, ESP_WHITE, "cast")
	legend(-22, Color3.fromRGB(70, 220, 255), "snap")

	-- spell list
	local list = new("ScrollingFrame", {
		Position = UDim2.new(0, 106, 0, 0),
		Size = UDim2.new(0, 176, 1, 0),
		BackgroundColor3 = BG2,
		BorderSizePixel = 0,
		ScrollBarThickness = 3,
		ScrollBarImageColor3 = ACCENT,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
	}, p)
	new("UIListLayout", { Padding = UDim.new(0, 1), SortOrder = Enum.SortOrder.LayoutOrder }, list)

	local detail = new("ScrollingFrame", {
		Position = UDim2.new(0, 290, 0, 0),
		Size = UDim2.new(1, -290, 1, 0),
		BackgroundColor3 = BG2,
		BorderSizePixel = 0,
		ScrollBarThickness = 3,
		ScrollBarImageColor3 = ACCENT,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
	}, p)
	new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingTop = UDim.new(0, 8), PaddingRight = UDim.new(0, 10), PaddingBottom = UDim.new(0, 8) }, detail)
	local body = new("TextLabel", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Font = FONT,
		TextSize = 13,
		TextColor3 = WHITE,
		TextWrapped = true,
		RichText = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Text = "",
	}, detail)

	local btns = {}
	local cur = 1
	local function pick(i)
		cur = i
		local sp = spells[i]
		body.Text = spellText(sp)
		setBand(castBand, sp.castR)
		setBand(snapBand, sp.snapR)
		for j, b in pairs(btns) do
			b.TextColor3 = (j == i) and T.ACCENT or T.DIM
			b.BackgroundColor3 = (j == i) and T.BG3 or T.BG2
		end
	end
	table.insert(themeRefreshers, function() pick(cur) end)

	local order = 0
	for c, cat in ipairs(spellCats) do
		order += 1
		local h = new("TextLabel", {
			Size = UDim2.new(1, 0, 0, 20), BackgroundColor3 = BG3, BorderSizePixel = 0,
			Font = FONT, Text = " " .. cat.title, TextColor3 = ACCENT, TextSize = 11,
			TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, LayoutOrder = order,
		}, list)
		for i, sp in ipairs(spells) do
			if sp.cat == c then
				order += 1
				local b = new("TextButton", {
					Size = UDim2.new(1, 0, 0, 22), BackgroundColor3 = BG2, BorderSizePixel = 0,
					Font = FONT, Text = "  " .. sp.name, TextColor3 = DIM, TextSize = 12,
					TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
					AutoButtonColor = false, LayoutOrder = order,
				}, list)
				b.MouseButton1Click:Connect(function() pick(i) end)
				btns[i] = b
			end
		end
	end
	pick(1)
end

--------------------------------------------------------------------
-- Alignment obtaining / gains / losses
--------------------------------------------------------------------
local alignRows = {
	{ "Jailing a player", "+1 orderly", "Also gives 5 silver." },
	{ "Jailed player rotted/died", "+3 orderly", "Also gives 25 silver." },
	{ "Turning in a shrieker to the Monster Officer at Oresfall", "+3 orderly", "<b>(None)</b>" },
	{ "Drinking a Tespian Elixir", "+2 orderly", "<u>Caps</u> to 10 orderly. (sadly)" },
	{ "Completing an orderly quest", "+5 orderly?", "Amount varies from the quest. But most give 5 orderly." },
	{ "Completing a repeatable orderly quest", "+2 orderly", "With 3 daily orderly quest available, you can get 6 orderly per day.\n  \226\128\162 Doing a repeatable quest <u>for the first time</u> will give 5 orderly." },
	{ "Feed on someone", "-2 orderly", "Vampire exclusive, does not include Navaran grip or Morvid to Morvid grip" },
	{ "Fire gripping", "-4 orderly", "Kill credit is only awarded if you directly apply the fire (with ignis or fire charge for exemple).\n<s>Cannot make you chaotic.</s> wrong" },
	{ "Complete a repeatable chaotic quest", "+2 chaotic", "With 2 daily chaotic quest available, you can get 4 chaotic per day.\n  \226\128\162 Doing a repeatable quest <u>for the first time</u> will give 5 chaotic.." },
	{ "Gripping a player", "+2 chaotic", "Gripping a housemate gives no chaotic." },
	{ "Soul rip", "+6 chaotic", "Does not give chaotic for the grip itself, so you do not get +8 chaotic" },
	{ "Complete an assisination", "+10 chaotic", "You gain +2 chaotic from the grip, so you gain +12 chaotic in total.\n  \226\128\162 Also gives 50 silver." },
	{ "Rotting inside jail", "-% to your chaotic", "Can be avoided by combat logging or getting gripped in the prison.\n  \226\128\162 Cannot make you orderly.\n  \226\128\162 Can make you orderly neutral." },
}

-- Chaotic <-> Orderly scale with the classes at their alignment values
local function buildAlignScale(p)
	section(p, "Alignment Scale")

	local SIDE = 70
	local BAR_Y, BAR_H = 112, 24
	local card = new("Frame", { Size = UDim2.new(1, 0, 0, 214), BackgroundColor3 = BG2, BorderSizePixel = 0 }, p)

	local bar = new("Frame", {
		Position = UDim2.new(0, SIDE, 0, BAR_Y),
		Size = UDim2.new(1, -SIDE * 2, 0, BAR_H),
		BackgroundTransparency = 1,
	}, card)

	-- scale runs from 160 chaotic (left) to 60 orderly (right); chaotic values are negative
	local function sx(v) return (160 + v) / 220 end

	local RED_BAR = Color3.fromRGB(235, 30, 30)
	local BLUE_BAR = Color3.fromRGB(30, 150, 255)

	for i = 0, 21 do
		new("Frame", {
			Position = UDim2.new(i / 22, 0, 0, 0),
			Size = UDim2.new(1 / 22, -1, 1, 0),
			BackgroundColor3 = (i < 16) and RED_BAR or BLUE_BAR,
			BorderSizePixel = 0,
		}, bar)
	end

	label(card, "Chaotic", { Position = UDim2.new(0, 8, 0, BAR_Y), Size = UDim2.new(0, SIDE - 10, 0, BAR_H), TextSize = 12 })
	label(card, "Orderly", { Position = UDim2.new(1, -(SIDE - 6), 0, BAR_Y), Size = UDim2.new(0, SIDE - 8, 0, BAR_H), TextSize = 12 })

	-- numbers under the bar (160 ... 0 ... 60)
	for v = -160, 60, 10 do
		label(bar, tostring(math.abs(v)), {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(sx(v), 0, 1, 3),
			Size = UDim2.fromOffset(24, 12),
			BackgroundTransparency = 0,
			BackgroundColor3 = BG2,
			TextSize = 10,
			TextColor3 = WHITE,
			TextXAlignment = Enum.TextXAlignment.Center,
			ZIndex = 3,
		})
	end

	-- classes above the bar: { value, names, extra lift }
	local above = {
		{ -155, { "Wraith Knight" }, 0 },
		{ -120, { "Church Knight", "Oni", "Abyss Walker", "Master Necromancer", "Faceless", "Shinobi" }, 0 },
		{ -60, { "Necromancer" }, 0 },
		{ -40, { "Akuma" }, 18 },
		{ -30, { "Assassin" }, 0 },
		{ 0, { "Ultra Bard", "Samurai", "Druid", "Botanist" }, 0 },
		{ 35, { "Sigil Knight", "Spy" }, 0 },
		{ 60, { "Master Illusionist", "Sigil Knight Commander", "Dragon Sage", "Dragon Slayer" }, 0 },
	}
	for _, a in ipairs(above) do
		local v, names, lift = a[1], a[2], a[3]
		new("Frame", {
			Position = UDim2.new(sx(v), 0, 0, -(8 + lift)),
			Size = UDim2.new(0, 1, 0, 8 + lift),
			BackgroundColor3 = WHITE, BorderSizePixel = 0,
		}, bar)
		label(bar, table.concat(names, "\n"), {
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(sx(v), 0, 0, -(10 + lift)),
			Size = UDim2.fromOffset(150, 12 * #names),
			TextSize = 11,
			TextXAlignment = Enum.TextXAlignment.Center,
			TextYAlignment = Enum.TextYAlignment.Bottom,
		})
	end

	-- classes below the bar: { value, text, stem length, label alignment }
	local below = {
		{ 5, "Monk (5)", 40, "right" },
		{ 10, "Dragon Knight (10)", 56, "center" },
		{ 40, "Ronin", 40, "center" },
		{ 50, "Illusionist", 56, "center" },
	}
	for _, b in ipairs(below) do
		local v, text, len, al = b[1], b[2], b[3], b[4]
		new("Frame", {
			Position = UDim2.new(sx(v), 0, 1, 0),
			Size = UDim2.new(0, 1, 0, len),
			BackgroundColor3 = WHITE, BorderSizePixel = 0,
		}, bar)
		label(bar, text, {
			AnchorPoint = Vector2.new(al == "right" and 1 or 0.5, 0),
			Position = UDim2.new(sx(v), 0, 1, len + 1),
			Size = UDim2.fromOffset(130, 12),
			TextSize = 11,
			TextXAlignment = al == "right" and Enum.TextXAlignment.Right or Enum.TextXAlignment.Center,
		})
	end
end

local function buildAlignment(p)
	buildAlignScale(p)
	section(p, "Alignment Obtaining, Gains/Losses")

	local COL_ACTION, COL_OUT, COL_NOTES = 200, 110, 340

	local function cell(parent, w, text, color, order)
		local l = new("TextLabel", {
			Size = UDim2.new(0, w, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			Font = FONT,
			TextSize = 12,
			TextColor3 = color or WHITE,
			TextWrapped = true,
			RichText = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			Text = text,
			LayoutOrder = order,
		}, parent)
		new("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6), PaddingTop = UDim.new(0, 5), PaddingBottom = UDim.new(0, 5) }, l)
		return l
	end

	local function row(bg, action, outcome, notes, outColor, textColor)
		local r = new("Frame", {
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundColor3 = bg,
			BorderSizePixel = 0,
		}, p)
		new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, SortOrder = Enum.SortOrder.LayoutOrder }, r)
		cell(r, COL_ACTION, action, textColor, 1)
		cell(r, COL_OUT, outcome, outColor or textColor, 2)
		cell(r, COL_NOTES, notes, textColor, 3)
	end

	row(BG3, "Action", "Outcome", "Notes", ACCENT, ACCENT)

	for _, r in ipairs(alignRows) do
		local out = r[2]:lower()
		local c = WHITE
		if out:find("orderly") then
			c = Color3.fromRGB(120, 175, 255)
		elseif out:find("chaotic") then
			c = Color3.fromRGB(255, 120, 120)
		end
		row(BG2, r[1], r[2], r[3], c, WHITE)
	end
end

--------------------------------------------------------------------
-- Enchants
--------------------------------------------------------------------
local enchants = {
	{ gem = "Ruby", color = Color3.fromRGB(220, 40, 60), text = Color3.fromRGB(255, 150, 150),
		desc = "Ignites players hit on fire whenever it procs.",
		notes = "The fire is identical to any normal fire and can be extinguished when the target rolls.\n  \226\128\162 Azaels are immune and Vampire will suffer the fire weakness." },
	{ gem = "Opal", color = Color3.fromRGB(170, 255, 220), text = Color3.fromRGB(200, 255, 235),
		desc = "Deals 1.25x more damage against undead monsters and negates vampirism buffs on proc.",
		notes = "Said monsters are Shriekers, Sealed Shriekers, and Zscrooms." },
	{ gem = "Sapphire", color = Color3.fromRGB(50, 90, 255), text = Color3.fromRGB(150, 160, 255),
		desc = "Freezes the target in ice and progressively slows their movement.",
		notes = "" },
	{ gem = "Emerald", color = Color3.fromRGB(50, 220, 70), text = Color3.fromRGB(170, 255, 170),
		desc = "Covers the target in poison on proc.",
		notes = "Similarly to a ruby's fire, the poison is identical to any normal poison.\n  \226\128\162 Scrooms, Gaian, and Metascroom are immune to its effects." },
	{ gem = "Diamond", color = Color3.fromRGB(90, 230, 255), text = Color3.fromRGB(180, 240, 255),
		desc = "Occasionally zaps the target with lightning, stunning them for twice the normal amount.",
		notes = "This enchant has the lowest chance to proc of any other." },
	{ gem = "Nightstone", color = Color3.fromRGB(80, 60, 140), text = Color3.fromRGB(200, 160, 235),
		desc = "Temporarily blinds the target whenever they are hit.",
		notes = "This enchant is largely useless as it only blinds the target when they are stunned, in which seeing doesn't matter.\n  \226\128\162 Will proc 100% of the time." },
}

local function buildEnchants(p)
	section(p, "Enchants")

	local COL_GEM, COL_DESC, COL_NOTES = 100, 250, 300

	local function cell(parent, w, text, color, order)
		local l = new("TextLabel", {
			Size = UDim2.new(0, w, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			Font = FONT,
			TextSize = 12,
			TextColor3 = color or WHITE,
			TextWrapped = true,
			RichText = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			Text = text,
			LayoutOrder = order,
		}, parent)
		new("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6), PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6) }, l)
		return l
	end

	local function row(bg)
		local r = new("Frame", {
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundColor3 = bg,
			BorderSizePixel = 0,
		}, p)
		new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, SortOrder = Enum.SortOrder.LayoutOrder }, r)
		return r
	end

	local head = row(BG3)
	cell(head, COL_GEM, "<b>Gem</b>", ACCENT, 1)
	cell(head, COL_DESC, "<b>Description</b>", ACCENT, 2)
	cell(head, COL_NOTES, "<b>Notes</b>", ACCENT, 3)

	for _, e in ipairs(enchants) do
		local r = row(BG2)

		-- gem cell: coloured gem chip + name
		local g = new("Frame", { Size = UDim2.fromOffset(COL_GEM, 56), BackgroundTransparency = 1, LayoutOrder = 1 }, r)
		local chip = new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 7),
			Size = UDim2.fromOffset(22, 22),
			BackgroundColor3 = e.color,
			BorderSizePixel = 0,
			Rotation = 45,
		}, g)
		new("UICorner", { CornerRadius = UDim.new(0, 4) }, chip)
		new("UIStroke", { Color = e.text, Transparency = 0.4 }, chip)
		label(g, e.gem, {
			Position = UDim2.new(0, 0, 0, 34), Size = UDim2.new(1, 0, 0, 16),
			TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = e.text, TextSize = 12,
		})

		cell(r, COL_DESC, e.desc, WHITE, 2)
		cell(r, COL_NOTES, e.notes, WHITE, 3)
	end
end

local function unload()
	running = false
	scanId += 1
	for _, c in ipairs(connections) do c:Disconnect() end
	for inst in pairs(entries) do removeEntry(inst) end
	restoreLighting()
	gui:Destroy()
end

--------------------------------------------------------------------
-- Theme editor (Settings tab)
--------------------------------------------------------------------
local function rgb(r, g, b) return Color3.fromRGB(r, g, b) end

local PRESETS = {
	{ "Rose", { ACCENT = rgb(240, 105, 140), BG = rgb(20, 20, 20), BG2 = rgb(26, 26, 26), BG3 = rgb(32, 32, 32), DARK = rgb(14, 14, 14), DIM = rgb(120, 120, 120), TEXT = rgb(230, 230, 230) } },
	{ "Ocean", { ACCENT = rgb(70, 160, 255), BG = rgb(14, 18, 24), BG2 = rgb(19, 24, 32), BG3 = rgb(26, 33, 44), DARK = rgb(9, 12, 17), DIM = rgb(110, 125, 145), TEXT = rgb(225, 232, 240) } },
	{ "Mint", { ACCENT = rgb(80, 220, 150), BG = rgb(16, 22, 20), BG2 = rgb(21, 29, 26), BG3 = rgb(28, 38, 34), DARK = rgb(10, 15, 13), DIM = rgb(115, 135, 125), TEXT = rgb(225, 240, 232) } },
	{ "Violet", { ACCENT = rgb(170, 110, 255), BG = rgb(20, 17, 27), BG2 = rgb(26, 22, 35), BG3 = rgb(34, 29, 46), DARK = rgb(13, 11, 18), DIM = rgb(128, 120, 145), TEXT = rgb(232, 228, 242) } },
	{ "Ember", { ACCENT = rgb(255, 140, 50), BG = rgb(24, 18, 14), BG2 = rgb(31, 23, 18), BG3 = rgb(40, 30, 23), DARK = rgb(16, 12, 9), DIM = rgb(140, 125, 110), TEXT = rgb(240, 232, 225) } },
	{ "Mono", { ACCENT = rgb(230, 230, 230), BG = rgb(18, 18, 18), BG2 = rgb(24, 24, 24), BG3 = rgb(31, 31, 31), DARK = rgb(12, 12, 12), DIM = rgb(115, 115, 115), TEXT = rgb(215, 215, 215) } },
	{ "Light", { ACCENT = rgb(220, 60, 110), BG = rgb(238, 238, 240), BG2 = rgb(228, 228, 232), BG3 = rgb(216, 216, 222), DARK = rgb(205, 205, 212), DIM = rgb(110, 110, 120), TEXT = rgb(30, 30, 35) } },
}

local ROLE_INFO = {
	{ "ACCENT", "Accent" },
	{ "BG", "Background" },
	{ "BG2", "Panels" },
	{ "BG3", "Controls" },
	{ "DARK", "Title / footer" },
	{ "DIM", "Dim text" },
	{ "TEXT", "Text" },
}

local function buildThemeEditor(p)
	section(p, "Theme Editor")

	local selected = "ACCENT"
	local hsv = { 0, 0, 0 }
	local rows = {}
	local setH, setS, setV

	local function commit()
		applyTheme()
		scheduleSave()
	end

	local function loadSelected()
		local h, s, v = T[selected]:ToHSV()
		hsv = { h, s, v }
		if setH then setH(h * 360) end
		if setS then setS(s * 100) end
		if setV then setV(v * 100) end
	end

	local function refreshRows()
		for role, r in pairs(rows) do
			r.swatch.BackgroundColor3 = T[role]
			if not r.box:IsFocused() then r.box.Text = colorHex(T[role]) end
			r.btn.BackgroundColor3 = (role == selected) and T.BG3 or T.BG2
			r.name.TextColor3 = (role == selected) and T.ACCENT or T.TEXT
		end
	end
	table.insert(themeRefreshers, refreshRows)

	-- presets
	label(p, "  Presets", { Size = UDim2.new(1, 0, 0, 18), TextColor3 = DIM, TextSize = 12 })
	local grid = new("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1 }, p)
	new("UIGridLayout", { CellSize = UDim2.fromOffset(92, 24), CellPadding = UDim2.fromOffset(6, 6) }, grid)
	new("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingBottom = UDim.new(0, 4) }, grid)

	local function applyPreset(colors)
		for _, r in ipairs(ROLES) do T[r] = colors[r] end
		loadSelected()
		commit()
	end

	for _, pr in ipairs(PRESETS) do
		local b = new("TextButton", {
			BackgroundColor3 = BG3, BorderSizePixel = 0,
			Font = FONT, Text = pr[1], TextColor3 = WHITE, TextSize = 12, AutoButtonColor = true,
		}, grid)
		noTheme = true -- the preview stripe shows the preset's own colour, so don't re-theme it
		new("Frame", { Size = UDim2.new(0, 4, 1, 0), BackgroundColor3 = pr[2].ACCENT, BorderSizePixel = 0 }, b)
		noTheme = false
		b.MouseButton1Click:Connect(function() applyPreset(pr[2]) end)
	end

	-- colour list
	label(p, "  Colors (click one, then use the sliders or type a hex code)", { Size = UDim2.new(1, 0, 0, 18), TextColor3 = DIM, TextSize = 12 })
	for _, info in ipairs(ROLE_INFO) do
		local role, title = info[1], info[2]
		local btn = new("TextButton", {
			Size = UDim2.new(1, 0, 0, 26), BackgroundColor3 = BG2, BorderSizePixel = 0,
			Text = "", AutoButtonColor = false,
		}, p)
		noTheme = true
		local swatch = new("Frame", {
			Position = UDim2.fromOffset(8, 4), Size = UDim2.fromOffset(18, 18),
			BackgroundColor3 = T[role], BorderSizePixel = 0,
		}, btn)
		new("UIStroke", { Color = rgb(95, 95, 95) }, swatch)
		noTheme = false
		local name = label(btn, title, { Position = UDim2.fromOffset(36, 0), Size = UDim2.new(1, -140, 1, 0) })
		local box = new("TextBox", {
			AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -8, 0.5, 0), Size = UDim2.fromOffset(84, 18),
			BackgroundColor3 = rgb(14, 14, 14), BorderSizePixel = 0,
			Font = FONT, TextSize = 12, TextColor3 = WHITE, Text = colorHex(T[role]),
			ClearTextOnFocus = false,
		}, btn)
		rows[role] = { btn = btn, swatch = swatch, name = name, box = box }

		btn.MouseButton1Click:Connect(function()
			selected = role
			loadSelected()
			refreshRows()
		end)
		box.FocusLost:Connect(function()
			local c = hexToColor(box.Text)
			if c then
				T[role] = c
				if role == selected then loadSelected() end
				commit()
			else
				box.Text = colorHex(T[role]) -- invalid hex, put the old value back
			end
		end)
	end

	-- sliders for the selected colour
	label(p, "  Edit selected color", { Size = UDim2.new(1, 0, 0, 18), TextColor3 = DIM, TextSize = 12 })
	local function onSlide(idx, scale)
		return function(v)
			hsv[idx] = v / scale
			T[selected] = Color3.fromHSV(hsv[1], hsv[2], hsv[3])
			commit()
		end
	end
	setH = slider(p, "Hue", 0, 360, 0, 0, onSlide(1, 360))
	setS = slider(p, "Saturation", 0, 100, 0, 0, onSlide(2, 100))
	setV = slider(p, "Brightness", 0, 100, 0, 0, onSlide(3, 100))

	button(p, "Reset to default theme", function() applyPreset(DEFAULT_THEME) end)

	local note = writefile and "  Your theme is saved automatically (QQGui_theme.json)."
		or "  This executor has no file access, so the theme won't be saved between sessions."
	label(p, note, { Size = UDim2.new(1, 0, 0, 18), TextColor3 = DIM, TextSize = 11 })

	loadSelected()
	refreshRows()
end

local function buildSettings(p)
	section(p, "Menu")
	label(p, "  Right Control hides / shows this menu.", { Size = UDim2.new(1, 0, 0, 20), TextColor3 = DIM, TextSize = 12 })
	buildThemeEditor(p)
	section(p, "Script")
	button(p, "Unload", unload)
end

--------------------------------------------------------------------
-- Toggle key
--------------------------------------------------------------------
connect(UIS.InputBegan, function(input)
	if input.KeyCode == Enum.KeyCode.RightControl then
		main.Visible = not main.Visible
	end
end)

--------------------------------------------------------------------
-- STAGED LOAD
--------------------------------------------------------------------
task.spawn(function()
	-- stage 1: tab buttons + default tab
	addTab("ESP", buildEsp)
	addTab("Visuals", buildVisuals)
	addTab("Potions", buildPotions)
	addTab("Spells", buildSpells)
	addTab("Alignment", buildAlignment)
	addTab("Enchants", buildEnchants)
	addTab("Settings", buildSettings)
	selectTab("ESP")
	task.wait(0.1)

	-- stage 2: ESP engine (item scan inside is chunked)
	startEsp()
	task.wait(0.1)

	-- stage 3: prebuild the remaining tabs one per frame so opening them is instant
	for _, name in ipairs({ "Visuals", "Potions", "Spells", "Alignment", "Enchants", "Settings" }) do
		if not running then return end
		if not built[name] then
			built[name] = true
			builders[name](pages[name])
		end
		task.wait(0.1)
	end

	statusLbl.Text = "Version 2.6 (Colors)"
end)

--[[
    QQ GUI  |  version 2.3
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
local TICK_RATE = 0.2       -- how often distances / highlight ranking update (seconds)
local SLOW_TICK = 1         -- how often Merchant / Live / pending items are re-checked
local SCAN_CHUNK = 100      -- children processed per frame during the first item scan

local cfg = {
	items = true,
	npc = true,         -- master switch for the NPC ESP group
	merchant = true,
	medic = true,
	antiquarian = true,
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

local tabBar = new("Frame", { Position = UDim2.fromOffset(0, 29), Size = UDim2.new(1, 0, 0, 30), BackgroundColor3 = Color3.fromRGB(17, 17, 17), BorderSizePixel = 0 }, main)
new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6) }, tabBar)
new("UIPadding", { PaddingLeft = UDim.new(0, 8) }, tabBar)

local content = new("Frame", {
	Position = UDim2.fromOffset(0, 60),
	Size = UDim2.new(1, 0, 1, -80),
	BackgroundTransparency = 1,
}, main)

local footer = new("Frame", { Position = UDim2.new(0, 0, 1, -18), Size = UDim2.new(1, 0, 0, 18), BackgroundColor3 = Color3.fromRGB(14, 14, 14), BorderSizePixel = 0 }, main)
local statusLbl = label(footer, "Version 2.3 (Info Update)", { Size = UDim2.new(0.5, 0, 1, 0), Position = UDim2.new(0, 10, 0, 0), TextColor3 = DIM, TextSize = 11 })
label(footer, "RightCtrl = toggle", { Size = UDim2.new(0.5, -10, 1, 0), Position = UDim2.new(0.5, 0, 0, 0), TextColor3 = DIM, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Right })

-- Tabs are built lazily: the builder only runs the first time the tab is opened
local pages, tabButtons, builders, built = {}, {}, {}, {}

local function selectTab(name)
	if not built[name] and builders[name] then
		built[name] = true
		builders[name](pages[name])
	end
	for n, p in pairs(pages) do p.Visible = (n == name) end
	for n, b in pairs(tabButtons) do
		b.Button.TextColor3 = (n == name) and ACCENT or DIM
		b.Line.Visible = (n == name)
	end
end

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
	local a = getAnchor(inst)
	if a then
		if e and e.bb.Adornee ~= a then e.bb.Adornee = a end -- keep the billboard on the body
		return a.Position
	end
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
	section(p, "Live")
	toggle(p, "Live ESP", cfg.live, function(v)
		cfg.live = v
		if v then syncLive() else removeKind("live") end
	end)
	section(p, "Colors")
	label(p, "  Items = their own color   |   Live = purple", { Size = UDim2.new(1, 0, 0, 20), TextColor3 = DIM, TextSize = 12 })
	label(p, "  Merchant = red  |  Doctor = white  |  Antiquarian = blue", { Size = UDim2.new(1, 0, 0, 20), TextColor3 = DIM, TextSize = 12 })
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
	local acc = hex(ACCENT)
	local dim = hex(DIM)
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
	local function pick(i)
		body.Text = potionText(potions[i])
		for j, b in ipairs(btns) do
			b.TextColor3 = (j == i) and ACCENT or DIM
			b.BackgroundColor3 = (j == i) and BG3 or BG2
		end
	end
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
		cast = { "70-80%" }, castR = { 70, 80 }, obtained = "Not listed" },
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
		cast = { "80-100% mana to cast (same for snap)" }, castR = { 80, 100 }, snapR = { 80, 100 }, obtained = "Not listed" },
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
	local acc = hex(ACCENT)
	local dim = hex(DIM)
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
	local function pick(i)
		local sp = spells[i]
		body.Text = spellText(sp)
		setBand(castBand, sp.castR)
		setBand(snapBand, sp.snapR)
		for j, b in pairs(btns) do
			b.TextColor3 = (j == i) and ACCENT or DIM
			b.BackgroundColor3 = (j == i) and BG3 or BG2
		end
	end

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

local function buildAlignment(p)
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

local function unload()
	running = false
	scanId += 1
	for _, c in ipairs(connections) do c:Disconnect() end
	for inst in pairs(entries) do removeEntry(inst) end
	restoreLighting()
	gui:Destroy()
end

local function buildSettings(p)
	section(p, "Menu")
	label(p, "  Right Control hides / shows this menu.", { Size = UDim2.new(1, 0, 0, 20), TextColor3 = DIM, TextSize = 12 })
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
	addTab("Settings", buildSettings)
	selectTab("ESP")
	task.wait(0.1)

	-- stage 2: ESP engine (item scan inside is chunked)
	startEsp()
	task.wait(0.1)

	-- stage 3: prebuild the remaining tabs one per frame so opening them is instant
	for _, name in ipairs({ "Visuals", "Potions", "Spells", "Alignment", "Settings" }) do
		if not running then return end
		if not built[name] then
			built[name] = true
			builders[name](pages[name])
		end
		task.wait(0.1)
	end

	statusLbl.Text = "Version 2.3 (Info Update)"
end)
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")

local PAGE = "https://github.com/soynd/cardoster"
local CONFIG = "soynd_altlift.json"

local defaults = {
	push = 130,
	spin = 8,
	delay = 0,
	smoke = 1,
	key = "LeftAlt",
	menu = "Zero",
}

local settings = table.clone(defaults)

local saveQueued = false

local function saveConfig()
	if not writefile or saveQueued then return end
	saveQueued = true
	task.delay(0.4, function()
		saveQueued = false
		pcall(writefile, CONFIG, HttpService:JSONEncode(settings))
	end)
end

if isfile and readfile then
	pcall(function()
		if not isfile(CONFIG) then return end
		local saved = HttpService:JSONDecode(readfile(CONFIG))
		for name, value in pairs(defaults) do
			if type(saved[name]) == type(value) then
				settings[name] = saved[name]
			end
		end
	end)
end

local liftKey = Enum.KeyCode[settings.key] or Enum.KeyCode.LeftAlt
local menuKey = Enum.KeyCode[settings.menu] or Enum.KeyCode.Zero

local GRAVITY = Workspace.Gravity
local CF_SPEED = 45
local SPLASH_RANGE = 14
local FADE_TIME = 0.75
local GROUND_PROBE = 2.5
local TEXTURE = "rbxasset://textures/particles/smoke_main.dds"

local altDown = UserInputService:IsKeyDown(liftKey)
local rig = nil
local spinTime = 0
local spinLastCF = nil
local airTime = 0
local pendingKey = nil
local connections = {}

local stale = Workspace:FindFirstChild("AltLiftRuntime")
if stale then
	stale:Destroy()
end

local function bind(signal, handler)
	table.insert(connections, signal:Connect(handler))
end

local function vehicle()
	local character = Players.LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local seat = humanoid and humanoid.SeatPart
	if seat and (seat:IsA("VehicleSeat") or seat:IsA("Seat")) then
		return seat.AssemblyRootPart or seat
	end

	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root then
		local ok, parts = pcall(function()
			return root:GetConnectedParts(true)
		end)
		if ok and parts then
			for _, part in ipairs(parts) do
				if not part:IsDescendantOf(character) then
					return part.AssemblyRootPart or part
				end
			end
		end
	end
	return nil
end

local function keyDown(key)
	return UserInputService:IsKeyDown(key)
end

local sizeRoot, sizeVec = nil, nil
local filterRoot, filterParams = nil, nil

local function boxSize(root)
	if sizeRoot == root and sizeVec then
		return sizeVec
	end
	local size = root.Size
	local model = root:FindFirstAncestorOfClass("Model")
	if model then
		local ok, _, box = pcall(function()
			return model:GetBoundingBox()
		end)
		if ok and box and box.Magnitude < root.Size.Magnitude * 8 then
			size = box
		end
	end
	sizeRoot, sizeVec = root, size
	return size
end

local function rayFilter(root)
	if filterParams and filterRoot == root then
		return filterParams
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.RespectCanCollide = true
	local ignore = {}
	local character = Players.LocalPlayer.Character
	local model = root:FindFirstAncestorOfClass("Model")
	if character then
		table.insert(ignore, character)
	end
	if model then
		table.insert(ignore, model)
	end

	local ok, connected = pcall(function()
		return root:GetConnectedParts(true)
	end)
	if ok and connected then
		for _, part in ipairs(connected) do
			table.insert(ignore, part)
		end
	end
	table.insert(ignore, root)
	params.FilterDescendantsInstances = ignore
	filterRoot, filterParams = root, params
	return params
end

local function touchingGround(root)
	local cf = root.CFrame
	local size = boxSize(root)
	local halfY = (math.abs(cf.RightVector.Y) * size.X
		+ math.abs(cf.UpVector.Y) * size.Y
		+ math.abs(cf.LookVector.Y) * size.Z) * 0.5
	local origin = Vector3.new(cf.Position.X, cf.Position.Y - halfY + 0.5, cf.Position.Z)
	return Workspace:Raycast(origin, Vector3.new(0, -GROUND_PROBE, 0), rayFilter(root)) ~= nil
end

local function rotationBetween(a, b)
	local trace = a.RightVector:Dot(b.RightVector)
		+ a.UpVector:Dot(b.UpVector)
		+ a.LookVector:Dot(b.LookVector)
	return math.acos(math.clamp((trace - 1) * 0.5, -1, 1))
end

local function newEmitter(parent)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = TEXTURE
	emitter.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255))
	emitter.LightEmission = 0
	emitter.LightInfluence = 1
	emitter.Parent = parent
	return emitter
end

local function stop()
	if not rig then return end

	local visuals = rig.visuals
	local force = rig.force
	rig = nil

	force:Destroy()

	for _, object in ipairs(visuals) do
		if object:IsA("ParticleEmitter") then
			object.Enabled = false
		end
	end
	task.delay(FADE_TIME, function()
		for _, object in ipairs(visuals) do
			object:Destroy()
		end
	end)
end

local function start(root)
	local visuals = {}

	local force = Instance.new("VectorForce")
	force.RelativeTo = Enum.ActuatorRelativeTo.World
	force.ApplyAtCenterOfMass = true
	force.Force = Vector3.new(0, root.AssemblyMass * GRAVITY, 0)
		+ root.CFrame.UpVector * (root.AssemblyMass * settings.push)
	force.Parent = root

	local params = rayFilter(root)

	local jets, splashes = {}, {}
	local rates = {}

	local function rate(emitter, base)
		emitter.Rate = base * settings.smoke
		table.insert(rates, { emitter = emitter, base = base })
	end

	local x, y, z = root.Size.X * 0.4, -root.Size.Y * 0.5, root.Size.Z * 0.4
	local corners = {
		Vector3.new(-x, y, -z), Vector3.new(x, y, -z),
		Vector3.new(-x, y, z), Vector3.new(x, y, z),
	}

	for _, position in ipairs(corners) do

		local attachment = Instance.new("Attachment")
		attachment.Position = position
		attachment.Parent = root
		table.insert(jets, attachment)

		local jet = newEmitter(attachment)
		jet.EmissionDirection = Enum.NormalId.Bottom
		jet.Lifetime = NumberRange.new(0.3, 0.55)
		rate(jet, 120)
		jet.Speed = NumberRange.new(24, 40)
		jet.SpreadAngle = Vector2.new(22, 22)
		jet.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 2.2),
			NumberSequenceKeypoint.new(1, 0.6),
		})
		jet.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.35),
			NumberSequenceKeypoint.new(1, 1),
		})
		jet.Acceleration = Vector3.new(0, -55, 0)
		table.insert(visuals, jet)

		local splashAttachment = Instance.new("Attachment")
		splashAttachment.Parent = root
		table.insert(visuals, splashAttachment)

		local splash = newEmitter(splashAttachment)
		splash.Enabled = false
		splash.EmissionDirection = Enum.NormalId.Top
		splash.Lifetime = NumberRange.new(0.3, 0.5)
		rate(splash, 70)
		splash.Speed = NumberRange.new(16, 32)
		splash.SpreadAngle = Vector2.new(130, 130)
		splash.Drag = 5
		splash.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1.8),
			NumberSequenceKeypoint.new(1, 0.4),
		})
		splash.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.4),
			NumberSequenceKeypoint.new(1, 1),
		})
		splash.Acceleration = Vector3.new(0, -35, 0)
		table.insert(visuals, splash)

		table.insert(splashes, { attachment = splashAttachment, emitter = splash })
	end

	local rcs = {}

	local function sideJet(position, direction)
		local attachment = Instance.new("Attachment")
		attachment.Position = position
		attachment.Parent = root
		table.insert(visuals, attachment)

		local jet = newEmitter(attachment)
		jet.Enabled = false
		jet.EmissionDirection = direction
		jet.Lifetime = NumberRange.new(0.18, 0.32)
		rate(jet, 35)
		jet.Speed = NumberRange.new(8, 16)
		jet.SpreadAngle = Vector2.new(25, 25)
		jet.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(1, 0),
		})
		jet.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.5),
			NumberSequenceKeypoint.new(1, 1),
		})
		jet.Acceleration = Vector3.new(0, -20, 0)
		table.insert(visuals, jet)
		return jet
	end

	rcs.front = sideJet(Vector3.new(0, 0, -root.Size.Z * 0.5 - 0.2), Enum.NormalId.Front)
	rcs.back = sideJet(Vector3.new(0, 0, root.Size.Z * 0.5 + 0.2), Enum.NormalId.Back)
	rcs.left = sideJet(Vector3.new(-root.Size.X * 0.5 - 0.2, 0, 0), Enum.NormalId.Left)
	rcs.right = sideJet(Vector3.new(root.Size.X * 0.5 + 0.2, 0, 0), Enum.NormalId.Right)

	local rigData = {
		root = root,
		force = force,
		visuals = visuals,
		jets = jets,
		splashes = splashes,
		rcs = rcs,
		rates = rates,
		params = params,
		mode = "physics",
		started = os.clock(),
		startPos = root.Position,
	}

	rig = rigData
end

local function applySmoke()
	if not rig then return end
	for _, item in ipairs(rig.rates) do
		item.emitter.Rate = item.base * settings.smoke
	end
end

local WHITE = Color3.fromRGB(240, 240, 240)
local DIM = Color3.fromRGB(145, 145, 145)
local INK = Color3.fromRGB(16, 16, 16)

local gui = Instance.new("ScreenGui")
gui.Name = "SoyndMenu"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 999999
gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

local scrim = Instance.new("TextButton")
scrim.Size = UDim2.fromScale(1, 1)
scrim.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
scrim.BackgroundTransparency = 1
scrim.Text = ""
scrim.AutoButtonColor = false
scrim.Visible = false
scrim.ZIndex = 0
scrim.Parent = gui

local function anim(object, time, goals, style)
	local info = TweenInfo.new(time or 0.14, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local tween = TweenService:Create(object, info, goals)
	tween:Play()
	return tween
end

local function round(object, radius)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius or 8)
	corner.Parent = object
	return object
end

local function outline(object, alpha)
	local stroke = Instance.new("UIStroke")
	stroke.Color = WHITE
	stroke.Thickness = 1
	stroke.Transparency = alpha or 0.86
	stroke.Parent = object
	return stroke
end

local function text(parent, value, size, color, weight)
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Text = value
	label.TextSize = size
	label.TextColor3 = color or WHITE
	label.Font = weight or Enum.Font.GothamMedium
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = parent
	return label
end

local function interactive(button, grow)
	local scale = Instance.new("UIScale")
	scale.Parent = button

	button.MouseEnter:Connect(function()
		anim(scale, 0.12, { Scale = grow or 1.03 })
	end)

	button.MouseLeave:Connect(function()
		anim(scale, 0.12, { Scale = 1 })
	end)

	button.MouseButton1Down:Connect(function()
		anim(scale, 0.06, { Scale = (grow or 1.03) * 0.95 })
	end)

	button.MouseButton1Up:Connect(function()
		anim(scale, 0.18, { Scale = grow or 1.03 }, Enum.EasingStyle.Back)
	end)

	return scale
end

local panel = Instance.new("Frame")
panel.AnchorPoint = Vector2.new(0.5, 0)
panel.Position = UDim2.new(0.5, 0, 0, 14)
panel.Size = UDim2.fromOffset(328, 0)
panel.AutomaticSize = Enum.AutomaticSize.Y
panel.BackgroundColor3 = INK
panel.BackgroundTransparency = 0.05
panel.BorderSizePixel = 0
panel.Visible = false
panel.ZIndex = 1
round(panel, 12)
outline(panel, 0.82)
panel.Parent = gui

local panelScale = Instance.new("UIScale")
panelScale.Scale = 0.96
panelScale.Parent = panel

local edge = Instance.new("UIPadding")
edge.PaddingTop = UDim.new(0, 12)
edge.PaddingBottom = UDim.new(0, 12)
edge.PaddingLeft = UDim.new(0, 12)
edge.PaddingRight = UDim.new(0, 12)
edge.Parent = panel

local stack = Instance.new("UIListLayout")
stack.Padding = UDim.new(0, 8)
stack.SortOrder = Enum.SortOrder.LayoutOrder
stack.Parent = panel

local header = Instance.new("Frame")
header.BackgroundTransparency = 1
header.Size = UDim2.new(1, 0, 0, 26)
header.LayoutOrder = 1
header.Parent = panel

local tabs = Instance.new("UIListLayout")
tabs.FillDirection = Enum.FillDirection.Horizontal
tabs.HorizontalAlignment = Enum.HorizontalAlignment.Center
tabs.VerticalAlignment = Enum.VerticalAlignment.Center
tabs.Padding = UDim.new(0, 6)
tabs.Parent = header

local function homeIcon(parent, color)
	local holder = Instance.new("Frame")
	holder.Size = UDim2.fromOffset(12, 12)
	holder.Position = UDim2.new(0, 2, 0.5, 0)
	holder.AnchorPoint = Vector2.new(0, 0.5)
	holder.BackgroundTransparency = 1
	holder.Parent = parent

	local roof = Instance.new("Frame")
	roof.Size = UDim2.fromOffset(7, 7)
	roof.AnchorPoint = Vector2.new(0.5, 0.5)
	roof.Position = UDim2.new(0.5, 0, 0.36, 0)
	roof.Rotation = 45
	roof.BackgroundColor3 = color
	roof.BorderSizePixel = 0
	round(roof, 1)
	roof.Parent = holder

	local body = Instance.new("Frame")
	body.Size = UDim2.fromOffset(7, 6)
	body.AnchorPoint = Vector2.new(0.5, 1)
	body.Position = UDim2.new(0.5, 0, 1, 0)
	body.BackgroundColor3 = color
	body.BorderSizePixel = 0
	round(body, 1)
	body.Parent = holder

	return { roof, body }
end

local function settingsIcon(parent, color)
	local holder = Instance.new("Frame")
	holder.Size = UDim2.fromOffset(12, 12)
	holder.Position = UDim2.new(0, 2, 0.5, 0)
	holder.AnchorPoint = Vector2.new(0, 0.5)
	holder.BackgroundTransparency = 1
	holder.Parent = parent

	local parts = {}
	for row = 0, 2 do
		local line = Instance.new("Frame")
		line.Size = UDim2.fromOffset(12, 1)
		line.Position = UDim2.fromOffset(0, 1 + row * 4)
		line.BackgroundColor3 = color
		line.BorderSizePixel = 0
		line.Parent = holder

		local knob = Instance.new("Frame")
		knob.Size = UDim2.fromOffset(3, 3)
		knob.AnchorPoint = Vector2.new(0.5, 0.5)
		knob.Position = UDim2.fromOffset(row == 1 and 4 or 9, 1.5 + row * 4)
		knob.BackgroundColor3 = color
		knob.BorderSizePixel = 0
		round(knob, 2)
		knob.Parent = holder

		table.insert(parts, line)
		table.insert(parts, knob)
	end

	return parts
end

local function tab(name, order, build)
	local button = Instance.new("TextButton")
	button.Size = UDim2.fromOffset(94, 26)
	button.BackgroundColor3 = WHITE
	button.BackgroundTransparency = 1
	button.Text = ""
	button.AutoButtonColor = false
	button.LayoutOrder = order
	button.Parent = header
	round(button, 6)
	interactive(button, 1.02)

	local icon = build(button, WHITE)
	local caption = text(button, name, 12, DIM)
	caption.Position = UDim2.fromOffset(19, 0)
	caption.Size = UDim2.new(1, -25, 1, 0)

	return { button = button, icon = icon, caption = caption, name = name }
end

local homeTab = tab("Home", 1, homeIcon)
local settingsTab = tab("Settings", 2, settingsIcon)

local function page(order)
	local frame = Instance.new("Frame")
	frame.BackgroundTransparency = 1
	frame.Size = UDim2.new(1, 0, 0, 0)
	frame.AutomaticSize = Enum.AutomaticSize.Y
	frame.LayoutOrder = order
	frame.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 10)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = frame
	return frame
end

local pageHome = page(2)
local pageSettings = page(3)

local drag = nil

local function slider(parent, order, name, min, max, step, current, fmt, apply)
	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 36)
	row.LayoutOrder = order
	row.Parent = parent

	local title = text(row, name, 12, WHITE)
	title.Size = UDim2.new(1, -78, 0, 15)

	local value = text(row, "", 12, WHITE, Enum.Font.GothamBold)
	value.Size = UDim2.fromOffset(78, 15)
	value.Position = UDim2.new(1, -78, 0, 0)
	value.TextXAlignment = Enum.TextXAlignment.Right

	local track = Instance.new("Frame")
	track.Size = UDim2.new(1, 0, 0, 3)
	track.Position = UDim2.fromOffset(0, 25)
	track.BackgroundColor3 = WHITE
	track.BackgroundTransparency = 0.82
	track.BorderSizePixel = 0
	track.Parent = row
	round(track, 2)

	local fill = Instance.new("Frame")
	fill.Size = UDim2.new(0, 0, 1, 0)
	fill.BackgroundColor3 = WHITE
	fill.BorderSizePixel = 0
	fill.Parent = track
	round(fill, 2)

	local knob = Instance.new("Frame")
	knob.Size = UDim2.fromOffset(8, 8)
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.Position = UDim2.new(0, 0, 0.5, 0)
	knob.BackgroundColor3 = WHITE
	knob.BorderSizePixel = 0
	knob.Parent = track
	round(knob, 4)

	local knobScale = Instance.new("UIScale")
	knobScale.Parent = knob

	local hit = Instance.new("TextButton")
	hit.Text = ""
	hit.AutoButtonColor = false
	hit.BackgroundTransparency = 1
	hit.Size = UDim2.new(1, 14, 0, 20)
	hit.Position = UDim2.new(0, -7, 0, 16)
	hit.Parent = row

	hit.MouseEnter:Connect(function()
		anim(knobScale, 0.12, { Scale = 1.4 })
	end)

	hit.MouseLeave:Connect(function()
		anim(knobScale, 0.12, { Scale = 1 })
	end)

	local function show(number)
		local alpha = math.clamp((number - min) / (max - min), 0, 1)
		fill.Size = UDim2.new(alpha, 0, 1, 0)
		knob.Position = UDim2.new(alpha, 0, 0.5, 0)
		value.Text = fmt(number)
	end

	local function move(input)
		local width = math.max(track.AbsoluteSize.X, 1)
		local alpha = math.clamp((input.Position.X - track.AbsolutePosition.X) / width, 0, 1)
		local number = math.clamp(math.floor((min + alpha * (max - min)) / step + 0.5) * step, min, max)
		show(number)
		apply(number)
	end

	hit.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			drag = move
			move(input)
			anim(knobScale, 0.1, { Scale = 1.7 })
		end
	end)

	hit.MouseButton1Up:Connect(function()
		anim(knobScale, 0.18, { Scale = 1.4 }, Enum.EasingStyle.Back)
	end)

	show(current())
	return show
end

local pushSlider = slider(pageHome, 1, "Push power", 20, 300, 5,
	function() return settings.push end,
	function(number) return string.format("%d", math.floor(number + 0.5)) end,
	function(number)
		settings.push = number
		saveConfig()
	end)

local spinSlider = slider(pageHome, 2, "Rotation power", 2, 20, 0.5,
	function() return settings.spin end,
	function(number) return string.format("%.1f", number) end,
	function(number)
		settings.spin = number
		saveConfig()
	end)

local delaySlider = slider(pageHome, 3, "Rotation delay", 0, 1.5, 0.05,
	function() return settings.delay end,
	function(number) return string.format("%dms", math.floor(number * 1000 + 0.5)) end,
	function(number)
		settings.delay = number
		saveConfig()
	end)

local smokeSlider = slider(pageHome, 4, "Smoke", 0, 4, 0.05,
	function() return settings.smoke end,
	function(number) return string.format("%d%%", math.floor(number * 100 + 0.5)) end,
	function(number)
		settings.smoke = number
		applySmoke()
		saveConfig()
	end)

local function keyRow(parent, order, name, slot)
	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 26)
	row.LayoutOrder = order
	row.Parent = parent

	local title = text(row, name, 12, WHITE)
	title.Size = UDim2.new(1, -100, 1, 0)

	local button = Instance.new("TextButton")
	button.Size = UDim2.fromOffset(92, 22)
	button.Position = UDim2.new(1, -92, 0.5, 0)
	button.BackgroundColor3 = WHITE
	button.BackgroundTransparency = 0.92
	button.Text = ""
	button.TextColor3 = WHITE
	button.TextSize = 11
	button.Font = Enum.Font.GothamBold
	button.AutoButtonColor = false
	button.Parent = row
	round(button, 5)
	outline(button, 0.78)
	interactive(button, 1.04)

	button.MouseEnter:Connect(function()
		anim(button, 0.12, { BackgroundTransparency = 0.84 })
	end)

	button.MouseLeave:Connect(function()
		anim(button, 0.12, { BackgroundTransparency = 0.92 })
	end)

	button.MouseButton1Click:Connect(function()
		pendingKey = slot
		button.Text = "press a key"
		button.TextColor3 = DIM
	end)

	return button
end

local liftButton = keyRow(pageSettings, 1, "Lift key", "key")
local menuButton = keyRow(pageSettings, 2, "Menu key", "menu")

local function prettyKey(name)
	local rest = name:match("^Left(.+)$") or name:match("^Right(.+)$")
	if name:sub(1, 5) == "Right" and rest then
		return "R" .. rest
	end
	return rest or name
end

local function showKeys()
	liftButton.Text = prettyKey(settings.key)
	liftButton.TextColor3 = WHITE
	menuButton.Text = prettyKey(settings.menu)
	menuButton.TextColor3 = WHITE
end

showKeys()

local resetButton = Instance.new("TextButton")
resetButton.Size = UDim2.new(1, 0, 0, 26)
resetButton.BackgroundColor3 = WHITE
resetButton.BackgroundTransparency = 1
resetButton.Text = "Reset defaults"
resetButton.TextColor3 = WHITE
resetButton.TextSize = 11
resetButton.Font = Enum.Font.GothamMedium
resetButton.AutoButtonColor = false
resetButton.LayoutOrder = 3
resetButton.Parent = pageSettings
round(resetButton, 6)
outline(resetButton, 0.8)
interactive(resetButton, 1.01)

resetButton.MouseEnter:Connect(function()
	anim(resetButton, 0.12, { BackgroundTransparency = 0.9 })
end)

resetButton.MouseLeave:Connect(function()
	anim(resetButton, 0.12, { BackgroundTransparency = 1 })
end)

resetButton.MouseButton1Click:Connect(function()
	settings.push = defaults.push
	settings.spin = defaults.spin
	settings.delay = defaults.delay
	settings.smoke = defaults.smoke
	settings.key = defaults.key
	settings.menu = defaults.menu

	liftKey = Enum.KeyCode[settings.key] or Enum.KeyCode.LeftAlt
	menuKey = Enum.KeyCode[settings.menu] or Enum.KeyCode.Zero
	altDown = UserInputService:IsKeyDown(liftKey)
	pendingKey = nil

	pushSlider(settings.push)
	spinSlider(settings.spin)
	delaySlider(settings.delay)
	smokeSlider(settings.smoke)

	applySmoke()
	showKeys()
	saveConfig()
end)

local divider = Instance.new("Frame")
divider.Size = UDim2.new(1, 0, 0, 1)
divider.BackgroundColor3 = WHITE
divider.BackgroundTransparency = 0.86
divider.BorderSizePixel = 0
divider.LayoutOrder = 4
divider.Parent = pageSettings

local credit = text(pageSettings, "made by soynd", 11, DIM)
credit.Size = UDim2.new(1, 0, 0, 14)
credit.LayoutOrder = 5

local copyButton = Instance.new("TextButton")
copyButton.Size = UDim2.new(1, 0, 0, 30)
copyButton.BackgroundColor3 = WHITE
copyButton.Text = "Script page"
copyButton.TextColor3 = INK
copyButton.TextSize = 12
copyButton.Font = Enum.Font.GothamBold
copyButton.AutoButtonColor = false
copyButton.LayoutOrder = 6
copyButton.Parent = pageSettings
round(copyButton, 7)
interactive(copyButton, 1.01)

copyButton.MouseEnter:Connect(function()
	anim(copyButton, 0.12, { BackgroundColor3 = Color3.fromRGB(214, 214, 214) })
end)

copyButton.MouseLeave:Connect(function()
	anim(copyButton, 0.12, { BackgroundColor3 = WHITE })
end)

local toast = Instance.new("CanvasGroup")
toast.AnchorPoint = Vector2.new(1, 0)
toast.Position = UDim2.new(1, -14, 0, 6)
toast.Size = UDim2.fromOffset(240, 54)
toast.BackgroundColor3 = INK
toast.BackgroundTransparency = 0.04
toast.BorderSizePixel = 0
toast.GroupTransparency = 1
toast.Visible = false
toast.ZIndex = 2
toast.Parent = gui
round(toast, 10)
outline(toast, 0.8)

local toastTitle = text(toast, "copied page", 12, WHITE, Enum.Font.GothamBold)
toastTitle.Position = UDim2.fromOffset(13, 10)
toastTitle.Size = UDim2.new(1, -26, 0, 15)

local toastLink = text(toast, PAGE, 10, DIM)
toastLink.Position = UDim2.fromOffset(13, 28)
toastLink.Size = UDim2.new(1, -26, 0, 14)
toastLink.TextTruncate = Enum.TextTruncate.AtEnd

local toastId = 0

local function copyPage()
	pcall(function()
		if setclipboard then
			setclipboard(PAGE)
		elseif toclipboard then
			toclipboard(PAGE)
		end
	end)

	toastId = toastId + 1
	local id = toastId
	toast.Visible = true
	toast.Position = UDim2.new(1, -14, 0, 2)
	anim(toast, 0.24, { GroupTransparency = 0, Position = UDim2.new(1, -14, 0, 14) })

	task.delay(2.2, function()
		if toastId ~= id then return end
		anim(toast, 0.26, { GroupTransparency = 1, Position = UDim2.new(1, -14, 0, 6) })
		task.delay(0.3, function()
			if toastId == id then
				toast.Visible = false
			end
		end)
	end)
end

copyButton.MouseButton1Click:Connect(copyPage)

local function selectTab(which)
	for _, item in ipairs({ homeTab, settingsTab }) do
		local on = item.name == which
		anim(item.button, 0.16, { BackgroundTransparency = on and 0 or 1 })
		anim(item.caption, 0.16, { TextColor3 = on and INK or DIM })
		for _, part in ipairs(item.icon) do
			anim(part, 0.16, { BackgroundColor3 = on and INK or WHITE })
		end
	end
	pageHome.Parent = which == "Home" and panel or nil
	pageSettings.Parent = which == "Settings" and panel or nil
end

homeTab.button.MouseButton1Click:Connect(function()
	selectTab("Home")
end)

settingsTab.button.MouseButton1Click:Connect(function()
	selectTab("Settings")
end)

selectTab("Home")

local menuId = 0

local function toggleMenu()
	menuId = menuId + 1
	local id = menuId

	if panel.Visible then
		anim(panelScale, 0.13, { Scale = 0.95 })
		anim(panel, 0.13, { Position = UDim2.new(0.5, 0, 0, 6) })
		anim(scrim, 0.13, { BackgroundTransparency = 1 })
		task.delay(0.13, function()
			if menuId == id then
				panel.Visible = false
				scrim.Visible = false
			end
		end)
		pendingKey = nil
		drag = nil
		showKeys()
	else
		panel.Visible = true
		panelScale.Scale = 0.92
		panel.Position = UDim2.new(0.5, 0, 0, 6)
		scrim.Visible = true
		scrim.BackgroundTransparency = 1
		anim(scrim, 0.2, { BackgroundTransparency = 0.55 })
		anim(panelScale, 0.22, { Scale = 1 }, Enum.EasingStyle.Back)
		anim(panel, 0.22, { Position = UDim2.new(0.5, 0, 0, 14) })
	end
end

bind(UserInputService.InputBegan, function(input, gameProcessed)
	if pendingKey then
		local slot = pendingKey
		pendingKey = nil
		local code = input.KeyCode
		if code ~= Enum.KeyCode.Unknown then
			if slot == "key" then
				liftKey = code
				settings.key = code.Name
				altDown = UserInputService:IsKeyDown(code)
			else
				menuKey = code
				settings.menu = code.Name
			end
			saveConfig()
		end
		showKeys()
		return
	end

	if input.KeyCode == menuKey then
		if not gameProcessed then
			toggleMenu()
		end
	elseif input.KeyCode == liftKey then
		altDown = true
	end
end)

bind(UserInputService.InputChanged, function(input)
	if drag and (input.UserInputType == Enum.UserInputType.MouseMovement
		or input.UserInputType == Enum.UserInputType.Touch) then
		drag(input)
	end
end)

bind(UserInputService.InputEnded, function(input)
	if input.KeyCode == liftKey then
		altDown = false
	end
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch then
		drag = nil
	end
end)

bind(UserInputService.WindowFocusReleased, function()
	altDown = false
	pendingKey = nil
	drag = nil
end)

bind(RunService.Stepped, function(_, dt)
	dt = math.min(dt, 0.1)

	local root = vehicle()
	if not root or not root.Parent then
		stop()
		return
	end

	local onGround = touchingGround(root)
	if altDown and not onGround then
		airTime = airTime + dt
	else
		airTime = 0
	end
	local armed = altDown and not onGround and airTime >= settings.delay

	local axis = nil
	local pitch = 0
	local roll = 0
	if armed then
		if keyDown(Enum.KeyCode.S) then pitch = pitch + 1 end
		if keyDown(Enum.KeyCode.W) then pitch = pitch - 1 end
		if keyDown(Enum.KeyCode.D) then roll = roll + 1 end
		if keyDown(Enum.KeyCode.A) then roll = roll - 1 end

		if pitch ~= 0 or roll ~= 0 then
			local direction = root.CFrame.RightVector * pitch + root.CFrame.LookVector * roll
			if direction.Magnitude > 0 then
				axis = direction.Unit
			end
		end
	end

	if rig and rig.rcs then
		rig.rcs.front.Enabled = armed and pitch < 0
		rig.rcs.back.Enabled = armed and pitch > 0
		rig.rcs.left.Enabled = armed and roll < 0
		rig.rcs.right.Enabled = armed and roll > 0
	end

	local spin = 0
	if axis then
		local cap = settings.spin
		spinTime = spinTime + dt
		spin = math.min(cap, spinTime * math.max(cap * 2, 1))
	else
		spinTime = 0
	end

	if altDown then
		if not rig or rig.root ~= root then
			stop()
			start(root)
		end

		if rig.mode == "physics" then
			local mass = root.AssemblyMass
			local up = root.CFrame.UpVector
			local push = settings.push
			local maxUp = push * 1.08

			rig.force.Force = Vector3.new(0, mass * GRAVITY, 0) + up * (mass * push)

			local velocity = root.AssemblyLinearVelocity
				+ Vector3.new(0, GRAVITY * dt, 0)
				+ up * (push * dt)

			local along = velocity:Dot(up)
			if along > maxUp then
				velocity = velocity - up * (along - maxUp)
			end
			root.AssemblyLinearVelocity = velocity

			if not axis then
				root.AssemblyAngularVelocity = root.AssemblyAngularVelocity * math.exp(-8 * dt)
			end

			if os.clock() - rig.started > 0.25 and (root.Position - rig.startPos).Magnitude < 1 then
				root.AssemblyLinearVelocity = Vector3.zero
				rig.mode = "cframe"
			end
		else
			root.CFrame = root.CFrame + root.CFrame.UpVector * (CF_SPEED * settings.push / 130 * dt)
			root.AssemblyLinearVelocity = Vector3.zero
			if not axis then
				root.AssemblyAngularVelocity = Vector3.zero
			end
		end

		for index, splash in ipairs(rig.splashes) do
			local jet = rig.jets[index]
			local hit = Workspace:Raycast(jet.WorldPosition, Vector3.new(0, -SPLASH_RANGE, 0), rig.params)
			if hit then
				local point = hit.Position + hit.Normal * 0.15
				splash.attachment.Position = root.CFrame:PointToObjectSpace(point)
				splash.emitter.Enabled = true
			else
				splash.emitter.Enabled = false
			end
		end
	else
		stop()
	end

	if axis then
		local current = root.AssemblyAngularVelocity
		local along = current:Dot(axis)
		if along < spin then
			root.AssemblyAngularVelocity = current + axis * (spin - along)
		end

		local expected = spin * dt
		local moved = expected
		if spinLastCF then
			moved = rotationBetween(spinLastCF, root.CFrame)
		end
		if moved < expected * 0.9 then
			local position = root.CFrame.Position
			root.CFrame = (CFrame.fromAxisAngle(axis, expected - moved) * root.CFrame.Rotation) + position
		end
		spinLastCF = root.CFrame
	else
		spinLastCF = nil
	end
end)

local runtime = Instance.new("Folder")
runtime.Name = "AltLiftRuntime"

runtime.Destroying:Connect(function()
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	connections = {}
	altDown = false
	stop()
	gui:Destroy()
end)

runtime.Parent = Workspace

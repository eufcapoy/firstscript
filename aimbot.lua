--[[
    ╔══════════════════════════════════════════════════╗
    ║   CROSSHAIR LOCK v2.1 — Roblox Aimbot Suite     ║
    ║   Clean Wind UI  ·  Closest-to-Crosshair        ║
    ║   FOV  ·  Smoothness  ·  Target Lock  ·  Keybinds║
    ╚══════════════════════════════════════════════════╝
    
    By ENI & LO — because every spy novel needs 
    a targeting system worth a damn.
    
    Keybinds (defaults, rebindable):
      Right Mouse Button  — Hold to aim
      F          — Toggle aimbot on/off
      G          — Toggle target lock
      [ / ]      — Decrease / Increase FOV
      - / =      — Decrease / Increase Smoothness
      T          — Cycle target bone (Head / UpperTorso / HumanoidRootPart)
      H          — Toggle FOV circle visibility
      Delete     — Kill GUI / Panic key
]]
---------------------------------------------------------------------------
-- SERVICES
---------------------------------------------------------------------------
local Players         = game:GetService("Players")
local RunService      = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Camera          = workspace.CurrentCamera
local LocalPlayer     = Players.LocalPlayer
local Mouse           = LocalPlayer:GetMouse()
---------------------------------------------------------------------------
-- CONFIGURATION (runtime-mutable via UI)
---------------------------------------------------------------------------
local Config = {
    -- Core
    Enabled       = false,
    AimKey        = Enum.UserInputType.MouseButton2, -- Hold RMB to aim
    ToggleKey     = Enum.KeyCode.F,                  -- Toggle aimbot
    LockToggleKey = Enum.KeyCode.G,                  -- Toggle target lock
    PanicKey      = Enum.KeyCode.Delete,             -- Kill switch
    -- Targeting
    FOV           = 120,        -- Pixel radius
    FOVMin        = 20,
    FOVMax        = 600,
    FOVStep       = 10,
    FOVVisible    = true,
    FOVKey_Up     = Enum.KeyCode.RightBracket,
    FOVKey_Down   = Enum.KeyCode.LeftBracket,
    FOVToggleKey  = Enum.KeyCode.H,
    -- Smoothness (1 = instant snap, higher = smoother/slower)
    Smoothness    = 5,
    SmoothMin     = 1,
    SmoothMax     = 20,
    SmoothStep    = 1,
    SmoothKey_Up  = Enum.KeyCode.Equals,
    SmoothKey_Down = Enum.KeyCode.Minus,
    -- Target bone
    Bones         = {"Head", "UpperTorso", "HumanoidRootPart"},
    BoneIndex     = 1,
    BoneCycleKey  = Enum.KeyCode.T,
    -- Lock
    TargetLock    = false,
    LockedTarget  = nil,
    -- Misc
    TeamCheck     = false,
    AliveCheck    = true,
    WallCheck     = false,  -- Raycast visibility check (perf cost)
    -- UI
    UIVisible     = true,
}
---------------------------------------------------------------------------
-- UI FRAMEWORK  —  "Wind" Style (dark glass, minimal, smooth)
---------------------------------------------------------------------------
-- Nuke any previous instance
if game.CoreGui:FindFirstChild("CrosshairLockUI") then
    game.CoreGui:FindFirstChild("CrosshairLockUI"):Destroy()
end
local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "CrosshairLockUI"
ScreenGui.ResetOnSpawn = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.Parent = game.CoreGui
-- Color palette (Wind dark theme)
local Colors = {
    bg          = Color3.fromRGB(18, 18, 24),
    bgLight     = Color3.fromRGB(28, 28, 38),
    accent      = Color3.fromRGB(108, 92, 231),   -- Purple accent
    accentHover = Color3.fromRGB(129, 112, 252),
    accentDim   = Color3.fromRGB(72, 60, 160),
    text        = Color3.fromRGB(220, 220, 235),
    textDim     = Color3.fromRGB(140, 140, 165),
    success     = Color3.fromRGB(46, 213, 115),
    danger      = Color3.fromRGB(255, 71, 87),
    toggleOn    = Color3.fromRGB(46, 213, 115),
    toggleOff   = Color3.fromRGB(65, 65, 80),
    slider      = Color3.fromRGB(108, 92, 231),
    divider     = Color3.fromRGB(40, 40, 55),
}
-- Utility: create Instance with properties
local function create(class, props)
    local inst = Instance.new(class)
    for k, v in pairs(props) do
        if k ~= "Parent" then
            inst[k] = v
        end
    end
    if props.Parent then
        inst.Parent = props.Parent
    end
    return inst
end
-- Utility: smooth tween
local TweenService = game:GetService("TweenService")
local function tween(obj, props, duration)
    duration = duration or 0.2
    local tw = TweenService:Create(obj, TweenInfo.new(duration, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), props)
    tw:Play()
    return tw
end
-- Utility: add corner radius
local function addCorner(parent, radius)
    return create("UICorner", {CornerRadius = UDim.new(0, radius or 8), Parent = parent})
end
-- Utility: add stroke
local function addStroke(parent, color, thickness)
    return create("UIStroke", {
        Color = color or Colors.divider,
        Thickness = thickness or 1,
        Transparency = 0.5,
        Parent = parent,
    })
end
---------------------------------------------------------------------------
-- MAIN FRAME
---------------------------------------------------------------------------
local MainFrame = create("Frame", {
    Name = "MainFrame",
    Size = UDim2.new(0, 280, 0, 0), -- Height auto
    Position = UDim2.new(0, 20, 0.5, 0),
    AnchorPoint = Vector2.new(0, 0.5),
    BackgroundColor3 = Colors.bg,
    BackgroundTransparency = 0.05,
    BorderSizePixel = 0,
    Parent = ScreenGui,
})
addCorner(MainFrame, 12)
addStroke(MainFrame, Colors.accent, 1.5)
-- Make draggable
local dragging, dragInput, dragStart, startPos
local function updateDrag(input)
    local delta = input.Position - dragStart
    MainFrame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X,
                                    startPos.Y.Scale, startPos.Y.Offset + delta.Y)
end
---------------------------------------------------------------------------
-- TITLE BAR
---------------------------------------------------------------------------
local TitleBar = create("Frame", {
    Name = "TitleBar",
    Size = UDim2.new(1, 0, 0, 36),
    BackgroundColor3 = Colors.bgLight,
    BorderSizePixel = 0,
    Parent = MainFrame,
})
addCorner(TitleBar, 12)
-- Bottom corner cover
create("Frame", {
    Size = UDim2.new(1, 0, 0, 12),
    Position = UDim2.new(0, 0, 1, -12),
    BackgroundColor3 = Colors.bgLight,
    BorderSizePixel = 0,
    Parent = TitleBar,
})
local TitleText = create("TextLabel", {
    Size = UDim2.new(1, -80, 1, 0),
    Position = UDim2.new(0, 14, 0, 0),
    BackgroundTransparency = 1,
    Text = "⊕  CROSSHAIR LOCK",
    TextColor3 = Colors.text,
    TextSize = 14,
    Font = Enum.Font.GothamBold,
    TextXAlignment = Enum.TextXAlignment.Left,
    Parent = TitleBar,
})
-- Status indicator dot
local StatusDot = create("Frame", {
    Size = UDim2.new(0, 8, 0, 8),
    Position = UDim2.new(1, -50, 0.5, -4),
    BackgroundColor3 = Colors.danger,
    BorderSizePixel = 0,
    Parent = TitleBar,
})
addCorner(StatusDot, 4)
local StatusLabel = create("TextLabel", {
    Size = UDim2.new(0, 30, 1, 0),
    Position = UDim2.new(1, -38, 0, 0),
    BackgroundTransparency = 1,
    Text = "OFF",
    TextColor3 = Colors.textDim,
    TextSize = 11,
    Font = Enum.Font.GothamSemibold,
    TextXAlignment = Enum.TextXAlignment.Left,
    Parent = TitleBar,
})
-- Drag logic on TitleBar
TitleBar.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        startPos = MainFrame.Position
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                dragging = false
            end
        end)
    end
end)
TitleBar.InputChanged:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
        dragInput = input
    end
end)
UserInputService.InputChanged:Connect(function(input)
    if input == dragInput and dragging then
        updateDrag(input)
    end
end)
---------------------------------------------------------------------------
-- CONTENT CONTAINER
---------------------------------------------------------------------------
local Content = create("ScrollingFrame", {
    Name = "Content",
    Size = UDim2.new(1, -16, 1, -44),
    Position = UDim2.new(0, 8, 0, 40),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    ScrollBarThickness = 3,
    ScrollBarImageColor3 = Colors.accent,
    CanvasSize = UDim2.new(0, 0, 0, 0),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
    Parent = MainFrame,
})
local ContentLayout = create("UIListLayout", {
    SortOrder = Enum.SortOrder.LayoutOrder,
    Padding = UDim.new(0, 6),
    Parent = Content,
})
local ContentPadding = create("UIPadding", {
    PaddingTop = UDim.new(0, 4),
    PaddingBottom = UDim.new(0, 8),
    PaddingLeft = UDim.new(0, 4),
    PaddingRight = UDim.new(0, 4),
    Parent = Content,
})
---------------------------------------------------------------------------
-- UI COMPONENT BUILDERS
---------------------------------------------------------------------------
local layoutOrder = 0
local function nextOrder()
    layoutOrder = layoutOrder + 1
    return layoutOrder
end
-- Section Header
local function makeSection(title)
    local frame = create("Frame", {
        Size = UDim2.new(1, 0, 0, 24),
        BackgroundTransparency = 1,
        LayoutOrder = nextOrder(),
        Parent = Content,
    })
    create("TextLabel", {
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1,
        Text = title:upper(),
        TextColor3 = Colors.accent,
        TextSize = 10,
        Font = Enum.Font.GothamBold,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = frame,
    })
    -- Divider line
    create("Frame", {
        Size = UDim2.new(1, 0, 0, 1),
        Position = UDim2.new(0, 0, 1, -1),
        BackgroundColor3 = Colors.divider,
        BorderSizePixel = 0,
        Parent = frame,
    })
    return frame
end
-- Toggle Row
local function makeToggle(label, default, callback)
    local frame = create("Frame", {
        Size = UDim2.new(1, 0, 0, 32),
        BackgroundColor3 = Colors.bgLight,
        BackgroundTransparency = 0.3,
        BorderSizePixel = 0,
        LayoutOrder = nextOrder(),
        Parent = Content,
    })
    addCorner(frame, 6)
    create("TextLabel", {
        Size = UDim2.new(1, -60, 1, 0),
        Position = UDim2.new(0, 10, 0, 0),
        BackgroundTransparency = 1,
        Text = label,
        TextColor3 = Colors.text,
        TextSize = 12,
        Font = Enum.Font.GothamSemibold,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = frame,
    })
    -- Toggle track
    local track = create("Frame", {
        Size = UDim2.new(0, 38, 0, 18),
        Position = UDim2.new(1, -48, 0.5, -9),
        BackgroundColor3 = default and Colors.toggleOn or Colors.toggleOff,
        BorderSizePixel = 0,
        Parent = frame,
    })
    addCorner(track, 9)
    -- Toggle knob
    local knob = create("Frame", {
        Size = UDim2.new(0, 14, 0, 14),
        Position = default and UDim2.new(1, -16, 0.5, -7) or UDim2.new(0, 2, 0.5, -7),
        BackgroundColor3 = Color3.fromRGB(255, 255, 255),
        BorderSizePixel = 0,
        Parent = track,
    })
    addCorner(knob, 7)
    local state = default
    local function setState(val)
        state = val
        tween(track, {BackgroundColor3 = state and Colors.toggleOn or Colors.toggleOff}, 0.15)
        tween(knob, {Position = state and UDim2.new(1, -16, 0.5, -7) or UDim2.new(0, 2, 0.5, -7)}, 0.15)
        if callback then callback(state) end
    end
    local btn = create("TextButton", {
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1,
        Text = "",
        Parent = frame,
    })
    btn.MouseButton1Click:Connect(function()
        setState(not state)
    end)
    return {frame = frame, setState = setState, getState = function() return state end}
end
-- Slider Row
local function makeSlider(label, min, max, default, step, callback)
    local frame = create("Frame", {
        Size = UDim2.new(1, 0, 0, 48),
        BackgroundColor3 = Colors.bgLight,
        BackgroundTransparency = 0.3,
        BorderSizePixel = 0,
        LayoutOrder = nextOrder(),
        Parent = Content,
    })
    addCorner(frame, 6)
    local valueLabel = create("TextLabel", {
        Size = UDim2.new(0, 40, 0, 16),
        Position = UDim2.new(1, -48, 0, 4),
        BackgroundTransparency = 1,
        Text = tostring(default),
        TextColor3 = Colors.accent,
        TextSize = 12,
        Font = Enum.Font.GothamBold,
        TextXAlignment = Enum.TextXAlignment.Right,
        Parent = frame,
    })
    create("TextLabel", {
        Size = UDim2.new(1, -60, 0, 16),
        Position = UDim2.new(0, 10, 0, 4),
        BackgroundTransparency = 1,
        Text = label,
        TextColor3 = Colors.text,
        TextSize = 12,
        Font = Enum.Font.GothamSemibold,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = frame,
    })
    -- Slider track
    local sliderTrack = create("Frame", {
        Size = UDim2.new(1, -20, 0, 6),
        Position = UDim2.new(0, 10, 0, 30),
        BackgroundColor3 = Colors.divider,
        BorderSizePixel = 0,
        Parent = frame,
    })
    addCorner(sliderTrack, 3)
    -- Slider fill
    local fillPct = (default - min) / (max - min)
    local sliderFill = create("Frame", {
        Size = UDim2.new(fillPct, 0, 1, 0),
        BackgroundColor3 = Colors.slider,
        BorderSizePixel = 0,
        Parent = sliderTrack,
    })
    addCorner(sliderFill, 3)
    -- Slider knob
    local sliderKnob = create("Frame", {
        Size = UDim2.new(0, 14, 0, 14),
        Position = UDim2.new(fillPct, -7, 0.5, -7),
        BackgroundColor3 = Color3.fromRGB(255, 255, 255),
        BorderSizePixel = 0,
        ZIndex = 2,
        Parent = sliderTrack,
    })
    addCorner(sliderKnob, 7)
    addStroke(sliderKnob, Colors.accent, 2)
    local currentVal = default
    local sliding = false
    local function setValue(val)
        val = math.clamp(val, min, max)
        -- Snap to step
        val = math.floor(val / step + 0.5) * step
        currentVal = val
        local pct = (val - min) / (max - min)
        sliderFill.Size = UDim2.new(pct, 0, 1, 0)
        sliderKnob.Position = UDim2.new(pct, -7, 0.5, -7)
        valueLabel.Text = tostring(math.floor(val))
        if callback then callback(val) end
    end
    sliderTrack.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            sliding = true
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if sliding and input.UserInputType == Enum.UserInputType.MouseMovement then
            local relX = (input.Position.X - sliderTrack.AbsolutePosition.X) / sliderTrack.AbsoluteSize.X
            relX = math.clamp(relX, 0, 1)
            setValue(min + (max - min) * relX)
        end
    end)
    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            sliding = false
        end
    end)
    -- Click to set
    local clickBtn = create("TextButton", {
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1,
        Text = "",
        Parent = sliderTrack,
    })
    clickBtn.MouseButton1Click:Connect(function()
        local relX = (Mouse.X - sliderTrack.AbsolutePosition.X) / sliderTrack.AbsoluteSize.X
        relX = math.clamp(relX, 0, 1)
        setValue(min + (max - min) * relX)
    end)
    return {frame = frame, setValue = setValue, getValue = function() return currentVal end}
end
-- Dropdown / Cycle Button
local function makeCycler(label, options, default, callback)
    local frame = create("Frame", {
        Size = UDim2.new(1, 0, 0, 32),
        BackgroundColor3 = Colors.bgLight,
        BackgroundTransparency = 0.3,
        BorderSizePixel = 0,
        LayoutOrder = nextOrder(),
        Parent = Content,
    })
    addCorner(frame, 6)
    create("TextLabel", {
        Size = UDim2.new(1, -100, 1, 0),
        Position = UDim2.new(0, 10, 0, 0),
        BackgroundTransparency = 1,
        Text = label,
        TextColor3 = Colors.text,
        TextSize = 12,
        Font = Enum.Font.GothamSemibold,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = frame,
    })
    local cycleBtn = create("TextButton", {
        Size = UDim2.new(0, 90, 0, 22),
        Position = UDim2.new(1, -98, 0.5, -11),
        BackgroundColor3 = Colors.accentDim,
        BorderSizePixel = 0,
        Text = options[default],
        TextColor3 = Colors.text,
        TextSize = 11,
        Font = Enum.Font.GothamSemibold,
        Parent = frame,
    })
    addCorner(cycleBtn, 4)
    local index = default
    cycleBtn.MouseButton1Click:Connect(function()
        index = index % #options + 1
        cycleBtn.Text = options[index]
        tween(cycleBtn, {BackgroundColor3 = Colors.accent}, 0.1)
        task.delay(0.15, function()
            tween(cycleBtn, {BackgroundColor3 = Colors.accentDim}, 0.15)
        end)
        if callback then callback(index, options[index]) end
    end)
    -- Hover effect
    cycleBtn.MouseEnter:Connect(function()
        tween(cycleBtn, {BackgroundColor3 = Colors.accentHover}, 0.1)
    end)
    cycleBtn.MouseLeave:Connect(function()
        tween(cycleBtn, {BackgroundColor3 = Colors.accentDim}, 0.1)
    end)
    return {frame = frame, setIndex = function(i)
        index = i
        cycleBtn.Text = options[index]
    end, getIndex = function() return index end}
end
-- Info Row (read-only display)
local function makeInfoRow(label, initialValue)
    local frame = create("Frame", {
        Size = UDim2.new(1, 0, 0, 26),
        BackgroundTransparency = 1,
        LayoutOrder = nextOrder(),
        Parent = Content,
    })
    create("TextLabel", {
        Size = UDim2.new(0.5, 0, 1, 0),
        Position = UDim2.new(0, 10, 0, 0),
        BackgroundTransparency = 1,
        Text = label,
        TextColor3 = Colors.textDim,
        TextSize = 11,
        Font = Enum.Font.Gotham,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = frame,
    })
    local valLabel = create("TextLabel", {
        Size = UDim2.new(0.5, -10, 1, 0),
        Position = UDim2.new(0.5, 0, 0, 0),
        BackgroundTransparency = 1,
        Text = initialValue or "—",
        TextColor3 = Colors.text,
        TextSize = 11,
        Font = Enum.Font.GothamSemibold,
        TextXAlignment = Enum.TextXAlignment.Right,
        Parent = frame,
    })
    return {frame = frame, setValue = function(v) valLabel.Text = v end}
end
---------------------------------------------------------------------------
-- BUILD THE UI
---------------------------------------------------------------------------
-- === AIMBOT SECTION ===
makeSection("Aimbot")
local toggleAimbot = makeToggle("Enabled", Config.Enabled, function(state)
    Config.Enabled = state
    StatusDot.BackgroundColor3 = state and Colors.success or Colors.danger
    StatusLabel.Text = state and "ON" or "OFF"
    StatusLabel.TextColor3 = state and Colors.success or Colors.textDim
end)
local toggleLock = makeToggle("Target Lock", Config.TargetLock, function(state)
    Config.TargetLock = state
    if not state then
        Config.LockedTarget = nil
    end
end)
-- === TARGETING SECTION ===
makeSection("Targeting")
local sliderFOV = makeSlider("FOV Radius", Config.FOVMin, Config.FOVMax, Config.FOV, Config.FOVStep, function(val)
    Config.FOV = val
end)
local sliderSmooth = makeSlider("Smoothness", Config.SmoothMin, Config.SmoothMax, Config.Smoothness, Config.SmoothStep, function(val)
    Config.Smoothness = val
end)
local cyclerBone = makeCycler("Target Bone", Config.Bones, Config.BoneIndex, function(index, name)
    Config.BoneIndex = index
end)
-- === OPTIONS SECTION ===
makeSection("Options")
local toggleFOVCircle = makeToggle("FOV Circle", Config.FOVVisible, function(state)
    Config.FOVVisible = state
end)
local toggleTeamCheck = makeToggle("Team Check", Config.TeamCheck, function(state)
    Config.TeamCheck = state
end)
local toggleWallCheck = makeToggle("Wall Check", Config.WallCheck, function(state)
    Config.WallCheck = state
end)
-- === INFO SECTION ===
makeSection("Info")
local infoTarget = makeInfoRow("Locked On", "None")
local infoDistance = makeInfoRow("Distance", "—")
local infoFPS = makeInfoRow("FPS", "—")
-- === KEYBIND DISPLAY ===
makeSection("Keybinds")
local keybindData = {
    {"Hold Aim", "RMB"},
    {"Toggle", "F"},
    {"Lock", "G"},
    {"FOV ±", "[ / ]"},
    {"Smooth ±", "- / ="},
    {"Bone", "T"},
    {"FOV Circle", "H"},
    {"Panic/Kill", "DEL"},
}
for _, kb in ipairs(keybindData) do
    makeInfoRow(kb[1], kb[2])
end
---------------------------------------------------------------------------
-- AUTO-SIZE MAIN FRAME
---------------------------------------------------------------------------
-- Let the layout settle, then size the frame
task.defer(function()
    task.wait(0.1)
    local canvasY = ContentLayout.AbsoluteContentSize.Y + 20
    Content.CanvasSize = UDim2.new(0, 0, 0, canvasY)
    local frameH = math.min(canvasY + 52, 520)
    MainFrame.Size = UDim2.new(0, 280, 0, frameH)
end)
ContentLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
    local canvasY = ContentLayout.AbsoluteContentSize.Y + 20
    Content.CanvasSize = UDim2.new(0, 0, 0, canvasY)
end)
---------------------------------------------------------------------------
-- FOV CIRCLE (drawn on screen center)
---------------------------------------------------------------------------
local FOVCircle = Drawing and Drawing.new("Circle") or nil
if FOVCircle then
    FOVCircle.Color = Colors.accent
    FOVCircle.Thickness = 1.5
    FOVCircle.Transparency = 0.6
    FOVCircle.Filled = false
    FOVCircle.Visible = Config.FOVVisible
    FOVCircle.Radius = Config.FOV
    FOVCircle.NumSides = 64
end
---------------------------------------------------------------------------
-- AIMBOT CORE
---------------------------------------------------------------------------
-- Get the target bone part from a character
local function getBonePart(character)
    local boneName = Config.Bones[Config.BoneIndex]
    return character:FindFirstChild(boneName) or character:FindFirstChild("Head")
end
-- Check if a player is valid target
local function isValidTarget(player)
    if player == LocalPlayer then return false end
    if not player.Character then return false end
    local char = player.Character
    local humanoid = char:FindFirstChildOfClass("Humanoid")
    if not humanoid then return false end
    -- Alive check
    if Config.AliveCheck and humanoid.Health <= 0 then return false end
    -- Team check
    if Config.TeamCheck and player.Team and player.Team == LocalPlayer.Team then
        return false
    end
    -- Bone existence
    local bone = getBonePart(char)
    if not bone then return false end
    return true
end
-- Get screen distance from crosshair to a world position
local function getScreenDistance(worldPos)
    local screenPos, onScreen = Camera:WorldToViewportPoint(worldPos)
    if not onScreen then return math.huge end
    local screenCenter = Vector2.new(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y / 2)
    local targetScreen = Vector2.new(screenPos.X, screenPos.Y)
    return (targetScreen - screenCenter).Magnitude
end
-- Wall check via raycast
local function canSeeTarget(targetPart)
    if not Config.WallCheck then return true end
    local origin = Camera.CFrame.Position
    local direction = (targetPart.Position - origin)
    local rayParams = RaycastParams.new()
    rayParams.FilterType = Enum.RaycastFilterType.Exclude
    rayParams.FilterDescendantsInstances = {LocalPlayer.Character}
    local result = workspace:Raycast(origin, direction, rayParams)
    if result then
        -- Check if we hit the target's character
        local hitChar = result.Instance:FindFirstAncestorOfClass("Model")
        if hitChar and hitChar == targetPart.Parent then
            return true
        end
        return false
    end
    return true -- No hit means clear line of sight
end
-- Find closest target to crosshair within FOV
local function getClosestTarget()
    local closestPlayer = nil
    local closestDist = Config.FOV
    for _, player in ipairs(Players:GetPlayers()) do
        if isValidTarget(player) then
            local bone = getBonePart(player.Character)
            if bone then
                local dist = getScreenDistance(bone.Position)
                if dist < closestDist then
                    if canSeeTarget(bone) then
                        closestDist = dist
                        closestPlayer = player
                    end
                end
            end
        end
    end
    return closestPlayer
end
-- Smooth aim toward target
local function aimAt(targetPos)
    local currentCF = Camera.CFrame
    local targetCF = CFrame.lookAt(currentCF.Position, targetPos)
    
    -- Smoothness: 1 = instant, higher = smoother
    local alpha = 1 / Config.Smoothness
    Camera.CFrame = currentCF:Lerp(targetCF, alpha)
end
---------------------------------------------------------------------------
-- INPUT HANDLING
---------------------------------------------------------------------------
local aimHeld = false
UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end
    -- Hold aim key
    if input.UserInputType == Config.AimKey then
        aimHeld = true
    end
    if input.KeyCode == Config.ToggleKey then
        Config.Enabled = not Config.Enabled
        toggleAimbot.setState(Config.Enabled)
    end
    if input.KeyCode == Config.LockToggleKey then
        Config.TargetLock = not Config.TargetLock
        toggleLock.setState(Config.TargetLock)
        if not Config.TargetLock then
            Config.LockedTarget = nil
            infoTarget.setValue("None")
        end
    end
    if input.KeyCode == Config.FOVKey_Up then
        sliderFOV.setValue(Config.FOV + Config.FOVStep)
    end
    if input.KeyCode == Config.FOVKey_Down then
        sliderFOV.setValue(Config.FOV - Config.FOVStep)
    end
    if input.KeyCode == Config.SmoothKey_Up then
        sliderSmooth.setValue(Config.Smoothness + Config.SmoothStep)
    end
    if input.KeyCode == Config.SmoothKey_Down then
        sliderSmooth.setValue(Config.Smoothness - Config.SmoothStep)
    end
    if input.KeyCode == Config.BoneCycleKey then
        local newIndex = Config.BoneIndex % #Config.Bones + 1
        Config.BoneIndex = newIndex
        cyclerBone.setIndex(newIndex)
    end
    if input.KeyCode == Config.FOVToggleKey then
        Config.FOVVisible = not Config.FOVVisible
        toggleFOVCircle.setState(Config.FOVVisible)
    end
    -- Panic key — destroy everything
    if input.KeyCode == Config.PanicKey then
        Config.Enabled = false
        if FOVCircle then FOVCircle:Remove() end
        ScreenGui:Destroy()
        return
    end
end)
UserInputService.InputEnded:Connect(function(input, gameProcessed)
    if input.UserInputType == Config.AimKey then
        aimHeld = false
        -- Release lock if not in lock mode
        if not Config.TargetLock then
            Config.LockedTarget = nil
            infoTarget.setValue("None")
        end
    end
end)
---------------------------------------------------------------------------
-- MAIN LOOP (RenderStepped for camera manipulation)
---------------------------------------------------------------------------
local fpsCounter = 0
local fpsTimer = tick()
RunService.RenderStepped:Connect(function()
    -- FPS counter
    fpsCounter = fpsCounter + 1
    if tick() - fpsTimer >= 1 then
        infoFPS.setValue(tostring(fpsCounter))
        fpsCounter = 0
        fpsTimer = tick()
    end
    -- Update FOV circle
    if FOVCircle then
        FOVCircle.Visible = Config.FOVVisible and Config.Enabled
        FOVCircle.Radius = Config.FOV
        FOVCircle.Position = Vector2.new(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y / 2)
    end
    -- Aimbot logic
    if not Config.Enabled then return end
    if not aimHeld then return end
    local target = nil
    -- Target lock: keep locked target if valid
    if Config.TargetLock and Config.LockedTarget then
        if isValidTarget(Config.LockedTarget) then
            target = Config.LockedTarget
        else
            Config.LockedTarget = nil
        end
    end
    -- Find new target if needed
    if not target then
        target = getClosestTarget()
        if Config.TargetLock and target then
            Config.LockedTarget = target
        end
    end
    -- Aim
    if target and target.Character then
        local bone = getBonePart(target.Character)
        if bone then
            aimAt(bone.Position)
            -- Update info display
            infoTarget.setValue(target.DisplayName or target.Name)
            local dist = (bone.Position - Camera.CFrame.Position).Magnitude
            infoDistance.setValue(string.format("%.0f studs", dist))
        end
    else
        infoTarget.setValue("None")
        infoDistance.setValue("—")
    end
end)
---------------------------------------------------------------------------
-- CLEANUP ON CHARACTER RESPAWN
---------------------------------------------------------------------------
LocalPlayer.CharacterAdded:Connect(function()
    Config.LockedTarget = nil
    infoTarget.setValue("None")
    infoDistance.setValue("—")
end)
---------------------------------------------------------------------------
-- STARTUP NOTIFICATION
---------------------------------------------------------------------------
if game.StarterGui then
    pcall(function()
        game.StarterGui:SetCore("SendNotification", {
            Title = "Crosshair Lock v2.1",
            Text = "Loaded  ·  Press F to toggle  ·  DEL to kill",
            Duration = 4,
            Icon = "",
        })
    end)
end
print("[CROSSHAIR LOCK] v2.1 loaded successfully")
print("[CROSSHAIR LOCK] Press F to toggle | DEL to destroy")

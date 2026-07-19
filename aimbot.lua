--[[
    ╔══════════════════════════════════════════════════╗
    ║   CROSSHAIR LOCK v2.2 — Roblox Aimbot Suite     ║
    ║   Clean Wind UI  ·  Closest-to-Crosshair        ║
    ║   FOV  ·  Smoothness  ·  Target Lock  ·  Keybinds║
    ╠══════════════════════════════════════════════════╣
    ║   Uses mousemoverel — works with custom cameras ║
    ║   Tested on: Arsenal, Da Hood, etc.              ║
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
local LocalPlayer     = Players.LocalPlayer
local Mouse           = LocalPlayer:GetMouse()
-- Camera ref refreshed every frame (some games swap cameras)
local function getCamera()
    return workspace.CurrentCamera
end
---------------------------------------------------------------------------
-- CONFIGURATION (runtime-mutable via UI)
---------------------------------------------------------------------------
local Config = {
    -- Core
    Enabled       = false,
    AimKey        = Enum.UserInputType.MouseButton1, -- Hold LMB to aim
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
    -- ESP
    ESP_Enabled   = false,
    ESP_Boxes     = true,
    ESP_Names     = true,
    ESP_Health    = true,
    ESP_Distance  = true,
    ESP_Tracers   = false,
    ESP_ToggleKey = Enum.KeyCode.J,
    ESP_BoxColor  = Color3.fromRGB(108, 92, 231),  -- Purple to match theme
    ESP_NameColor = Color3.fromRGB(220, 220, 235),
    ESP_TracerColor = Color3.fromRGB(108, 92, 231),
    ESP_TracerOrigin = "Bottom", -- "Bottom", "Center", "Mouse"
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
-- === ESP SECTION ===
makeSection("ESP / Wallhack")
local toggleESP = makeToggle("ESP Enabled", Config.ESP_Enabled, function(state)
    Config.ESP_Enabled = state
end)
local toggleESPBoxes = makeToggle("Boxes", Config.ESP_Boxes, function(state)
    Config.ESP_Boxes = state
end)
local toggleESPNames = makeToggle("Names", Config.ESP_Names, function(state)
    Config.ESP_Names = state
end)
local toggleESPHealth = makeToggle("Health Bars", Config.ESP_Health, function(state)
    Config.ESP_Health = state
end)
local toggleESPDistance = makeToggle("Distance", Config.ESP_Distance, function(state)
    Config.ESP_Distance = state
end)
local toggleESPTracers = makeToggle("Tracers", Config.ESP_Tracers, function(state)
    Config.ESP_Tracers = state
end)
-- === INFO SECTION ===
makeSection("Info")
local infoTarget = makeInfoRow("Locked On", "None")
local infoDistance = makeInfoRow("Distance", "—")
local infoFPS = makeInfoRow("FPS", "—")
-- === KEYBIND DISPLAY ===
makeSection("Keybinds")
local keybindData = {
    {"Hold Aim", "LMB"},
    {"Toggle", "F"},
    {"Lock", "G"},
    {"FOV ±", "[ / ]"},
    {"Smooth ±", "- / ="},
    {"Bone", "T"},
    {"FOV Circle", "H"},
    {"ESP Toggle", "J"},
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
local FOVCircle = nil
pcall(function()
    if Drawing then
        FOVCircle = Drawing.new("Circle")
        FOVCircle.Color = Color3.fromRGB(108, 92, 231)
        FOVCircle.Thickness = 1.5
        FOVCircle.Transparency = 0.6
        FOVCircle.Filled = false
        FOVCircle.Visible = Config.FOVVisible
        FOVCircle.Radius = Config.FOV
        FOVCircle.NumSides = 64
    end
end)
---------------------------------------------------------------------------
-- ESP SYSTEM (Drawing API)
---------------------------------------------------------------------------
local ESPObjects = {} -- { [player] = { box, nameTag, healthBarBG, healthBarFill, distTag, tracer } }
-- Create ESP drawing objects for a player
local function createESP(player)
    if ESPObjects[player] then return end
    
    local success, drawings = pcall(function()
        local box = Drawing.new("Square")
        box.Color = Config.ESP_BoxColor
        box.Thickness = 1.5
        box.Filled = false
        box.Transparency = 0.8
        box.Visible = false
        
        local nameTag = Drawing.new("Text")
        nameTag.Color = Config.ESP_NameColor
        nameTag.Size = 13
        nameTag.Center = true
        nameTag.Outline = true
        nameTag.OutlineColor = Color3.fromRGB(0, 0, 0)
        nameTag.Font = 2 -- Plex (cleaner than default)
        nameTag.Visible = false
        nameTag.Text = player.DisplayName or player.Name
        
        local healthBG = Drawing.new("Square")
        healthBG.Color = Color3.fromRGB(40, 40, 40)
        healthBG.Thickness = 1
        healthBG.Filled = true
        healthBG.Transparency = 0.6
        healthBG.Visible = false
        
        local healthFill = Drawing.new("Square")
        healthFill.Color = Color3.fromRGB(46, 213, 115)
        healthFill.Thickness = 1
        healthFill.Filled = true
        healthFill.Transparency = 0.8
        healthFill.Visible = false
        
        local distTag = Drawing.new("Text")
        distTag.Color = Config.ESP_NameColor
        distTag.Size = 11
        distTag.Center = true
        distTag.Outline = true
        distTag.OutlineColor = Color3.fromRGB(0, 0, 0)
        distTag.Font = 2
        distTag.Visible = false
        
        local tracer = Drawing.new("Line")
        tracer.Color = Config.ESP_TracerColor
        tracer.Thickness = 1.5
        tracer.Transparency = 0.6
        tracer.Visible = false
        
        return {
            box = box,
            nameTag = nameTag,
            healthBG = healthBG,
            healthFill = healthFill,
            distTag = distTag,
            tracer = tracer,
        }
    end)
    
    if success then
        ESPObjects[player] = drawings
    end
end
-- Remove ESP drawings for a player
local function removeESP(player)
    local data = ESPObjects[player]
    if not data then return end
    pcall(function()
        for _, drawing in pairs(data) do
            drawing:Remove()
        end
    end)
    ESPObjects[player] = nil
end
-- Remove ALL ESP drawings
local function clearAllESP()
    for player, _ in pairs(ESPObjects) do
        removeESP(player)
    end
    ESPObjects = {}
end
-- Update ESP for a single player
local function updateESP(player, cam)
    local data = ESPObjects[player]
    if not data then return end
    
    -- Hide everything by default
    local function hideAll()
        for _, d in pairs(data) do
            d.Visible = false
        end
    end
    
    -- Not a valid target? Hide ESP
    if player == LocalPlayer then hideAll() return end
    if not player.Character then hideAll() return end
    
    local char = player.Character
    if not char.Parent then hideAll() return end
    
    local humanoid = char:FindFirstChildOfClass("Humanoid")
    if not humanoid then hideAll() return end
    if humanoid.Health <= 0 then hideAll() return end
    
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hrp then hideAll() return end
    
    local head = char:FindFirstChild("Head", true)
    if not head or not head:IsA("BasePart") then hideAll() return end
    
    -- Team check
    if Config.TeamCheck and player.Team and player.Team == LocalPlayer.Team then
        hideAll()
        return
    end
    
    -- Get screen positions for bounding box
    -- Use character height to estimate 2D box
    local rootPos = hrp.Position
    local headPos = head.Position
    
    local screenRoot, onScreenRoot = cam:WorldToViewportPoint(rootPos)
    if not onScreenRoot then hideAll() return end
    
    local screenHead, _ = cam:WorldToViewportPoint(headPos + Vector3.new(0, 1.5, 0))
    local screenFeet, _ = cam:WorldToViewportPoint(rootPos - Vector3.new(0, 3, 0))
    
    local boxHeight = math.abs(screenFeet.Y - screenHead.Y)
    local boxWidth = boxHeight * 0.55
    local boxCenterX = screenRoot.X
    local boxTopY = screenHead.Y
    
    -- Distance from camera
    local distance = (rootPos - cam.CFrame.Position).Magnitude
    
    -- === BOX ===
    if Config.ESP_Boxes then
        data.box.Size = Vector2.new(boxWidth, boxHeight)
        data.box.Position = Vector2.new(boxCenterX - boxWidth / 2, boxTopY)
        data.box.Color = Config.ESP_BoxColor
        data.box.Visible = true
    else
        data.box.Visible = false
    end
    
    -- === NAME TAG === (above box)
    if Config.ESP_Names then
        data.nameTag.Text = player.DisplayName or player.Name
        data.nameTag.Position = Vector2.new(boxCenterX, boxTopY - 16)
        data.nameTag.Visible = true
    else
        data.nameTag.Visible = false
    end
    
    -- === HEALTH BAR === (left side of box)
    if Config.ESP_Health then
        local healthPct = math.clamp(humanoid.Health / humanoid.MaxHealth, 0, 1)
        local barWidth = 3
        local barX = boxCenterX - boxWidth / 2 - barWidth - 3
        local barHeight = boxHeight
        local fillHeight = barHeight * healthPct
        
        -- Background
        data.healthBG.Size = Vector2.new(barWidth, barHeight)
        data.healthBG.Position = Vector2.new(barX, boxTopY)
        data.healthBG.Visible = true
        
        -- Fill (from bottom up)
        data.healthFill.Size = Vector2.new(barWidth, fillHeight)
        data.healthFill.Position = Vector2.new(barX, boxTopY + (barHeight - fillHeight))
        -- Color gradient: green > yellow > red based on health
        if healthPct > 0.6 then
            data.healthFill.Color = Color3.fromRGB(46, 213, 115)
        elseif healthPct > 0.3 then
            data.healthFill.Color = Color3.fromRGB(255, 195, 18)
        else
            data.healthFill.Color = Color3.fromRGB(255, 71, 87)
        end
        data.healthFill.Visible = true
    else
        data.healthBG.Visible = false
        data.healthFill.Visible = false
    end
    
    -- === DISTANCE TAG === (below box)
    if Config.ESP_Distance then
        data.distTag.Text = string.format("[%d studs]", math.floor(distance))
        data.distTag.Position = Vector2.new(boxCenterX, boxTopY + boxHeight + 3)
        data.distTag.Visible = true
    else
        data.distTag.Visible = false
    end
    
    -- === TRACER === (line from screen bottom to player feet)
    if Config.ESP_Tracers then
        local fromPos = Vector2.new(cam.ViewportSize.X / 2, cam.ViewportSize.Y)
        local toPos = Vector2.new(screenRoot.X, screenRoot.Y)
        data.tracer.From = fromPos
        data.tracer.To = toPos
        data.tracer.Color = Config.ESP_TracerColor
        data.tracer.Visible = true
    else
        data.tracer.Visible = false
    end
end
-- Auto-create ESP for new players, clean up leaving players
Players.PlayerAdded:Connect(function(player)
    if Drawing then
        pcall(function() createESP(player) end)
    end
end)
Players.PlayerRemoving:Connect(function(player)
    removeESP(player)
end)
-- Initialize ESP for all current players
if Drawing then
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then
            pcall(function() createESP(player) end)
        end
    end
end
---------------------------------------------------------------------------
-- AIMBOT CORE
---------------------------------------------------------------------------
-- Get the target bone part from a character
-- Uses FindFirstChild + recursive search for games that nest bones
local function getBonePart(character)
    local boneName = Config.Bones[Config.BoneIndex]
    -- Direct child first (fast path)
    local bone = character:FindFirstChild(boneName)
    if bone and bone:IsA("BasePart") then return bone end
    -- Recursive search (Arsenal and some games nest parts deeper)
    bone = character:FindFirstChild(boneName, true)
    if bone and bone:IsA("BasePart") then return bone end
    -- Fallback chain: Head > HumanoidRootPart > any BasePart
    bone = character:FindFirstChild("Head", true)
    if bone and bone:IsA("BasePart") then return bone end
    bone = character:FindFirstChild("HumanoidRootPart", true)
    if bone and bone:IsA("BasePart") then return bone end
    return nil
end
-- Check if a player is valid target
-- This is the HARDENED version — multiple checks to avoid locking
-- onto dead bodies, despawned characters, or ragdolls on the ground
local function isValidTarget(player)
    if player == LocalPlayer then return false end
    if not player.Character then return false end
    local char = player.Character
    
    -- Character must be parented to workspace (not nil = despawned/removing)
    if not char.Parent then return false end
    if not char:IsDescendantOf(workspace) then return false end
    local humanoid = char:FindFirstChildOfClass("Humanoid")
    if not humanoid then return false end
    -- === ALIVE CHECKS (this is why it was locking to ground) ===
    -- Check 1: Health must be above 0
    if humanoid.Health <= 0 then return false end
    
    -- Check 2: Humanoid state — reject Dead state explicitly
    -- Arsenal sets state to Dead before removing the character
    local state = humanoid:GetState()
    if state == Enum.HumanoidStateType.Dead then return false end
    
    -- Check 3: Head/bone Y-position sanity
    -- Dead ragdolls fall through the map or sink into the ground
    -- If the target bone is below Y = -10, they're gone
    local bone = getBonePart(char)
    if not bone then return false end
    if bone.Position.Y < -10 then return false end
    
    -- Check 4: HumanoidRootPart must exist and be reasonably positioned
    -- When a character dies in Arsenal, the rootpart often gets destroyed
    local rootPart = char:FindFirstChild("HumanoidRootPart")
    if not rootPart then return false end
    if rootPart.Position.Y < -10 then return false end
    -- Team check
    if Config.TeamCheck and player.Team and player.Team == LocalPlayer.Team then
        return false
    end
    return true
end
-- Get screen position and distance from crosshair to a world position
local function getScreenData(worldPos)
    local cam = getCamera()
    if not cam then return math.huge, Vector2.new(0, 0), false end
    local screenPos, onScreen = cam:WorldToViewportPoint(worldPos)
    if not onScreen then return math.huge, Vector2.new(0, 0), false end
    local screenCenter = Vector2.new(cam.ViewportSize.X / 2, cam.ViewportSize.Y / 2)
    local targetScreen = Vector2.new(screenPos.X, screenPos.Y)
    local dist = (targetScreen - screenCenter).Magnitude
    return dist, targetScreen, true
end
-- Wall check via raycast
local function canSeeTarget(targetPart)
    if not Config.WallCheck then return true end
    local cam = getCamera()
    if not cam then return false end
    local origin = cam.CFrame.Position
    local direction = (targetPart.Position - origin)
    local rayParams = RaycastParams.new()
    rayParams.FilterType = Enum.RaycastFilterType.Exclude
    rayParams.FilterDescendantsInstances = {LocalPlayer.Character}
    local result = workspace:Raycast(origin, direction, rayParams)
    if result then
        -- Walk up ancestors to find the character model
        local hitPart = result.Instance
        local hitChar = hitPart:FindFirstAncestorOfClass("Model")
        if hitChar and hitChar == targetPart:FindFirstAncestorOfClass("Model") then
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
                local dist, _, onScreen = getScreenData(bone.Position)
                if onScreen and dist < closestDist then
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
-- ================================================================
-- AIM FUNCTION — uses mousemoverel instead of Camera.CFrame
-- This is the critical fix. Games like Arsenal use their own
-- camera controller that overwrites CFrame every frame.
-- mousemoverel physically moves the mouse, so the game's own
-- camera system processes it naturally. Works universally.
-- ================================================================
local function aimAt(targetPos)
    local cam = getCamera()
    if not cam then return end
    
    local screenPos, onScreen = cam:WorldToViewportPoint(targetPos)
    if not onScreen then return end
    
    local screenCenter = Vector2.new(cam.ViewportSize.X / 2, cam.ViewportSize.Y / 2)
    local targetScreen = Vector2.new(screenPos.X, screenPos.Y)
    local delta = targetScreen - screenCenter
    
    -- Apply smoothness: divide the delta so we move a fraction per frame
    -- Smoothness 1 = move full delta (snap), 20 = move 1/20th per frame
    local moveX = delta.X / Config.Smoothness
    local moveY = delta.Y / Config.Smoothness
    
    -- mousemoverel is an executor function (Synapse, Script-Ware, Fluxus, etc.)
    if mousemoverel then
        mousemoverel(moveX, moveY)
    elseif Input and Input.MouseMove then
        -- Some executors use Input.MouseMove instead
        Input.MouseMove(moveX, moveY)
    end
end
---------------------------------------------------------------------------
-- INPUT HANDLING
---------------------------------------------------------------------------
local aimHeld = false
UserInputService.InputBegan:Connect(function(input, gameProcessed)
    -- ======================================================
    -- DO NOT block on gameProcessed for the aim key!
    -- Arsenal (and many FPS games) mark RMB as "processed"
    -- because they use it for ADS. If we check gameProcessed
    -- here, our aimbot never activates. We only block
    -- gameProcessed for keybind toggles (keyboard keys).
    -- ======================================================
    
    -- Hold aim key — NO gameProcessed check
    if input.UserInputType == Config.AimKey then
        aimHeld = true
    end
    -- Everything below: block if game processed (typing in chat, etc.)
    if gameProcessed then return end
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
    -- ESP toggle
    if input.KeyCode == Config.ESP_ToggleKey then
        Config.ESP_Enabled = not Config.ESP_Enabled
        toggleESP.setState(Config.ESP_Enabled)
    end
    -- Panic key — destroy everything
    if input.KeyCode == Config.PanicKey then
        Config.Enabled = false
        Config.ESP_Enabled = false
        clearAllESP()
        if FOVCircle then pcall(function() FOVCircle:Remove() end) end
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
-- ================================================================
-- Use BindToRenderStep with priority ABOVE the camera (priority 201)
-- Default camera runs at Enum.RenderPriority.Camera.Value (200).
-- By running at 201 we execute AFTER the game's camera has finished,
-- so our mousemoverel takes effect on the next frame correctly.
-- ================================================================
local RENDER_NAME = "CrosshairLock_AimLoop"
-- Clean up any previous binding (re-execution safety)
pcall(function() RunService:UnbindFromRenderStep(RENDER_NAME) end)
RunService:BindToRenderStep(RENDER_NAME, 201, function()
    local cam = getCamera()
    
    -- FPS counter
    fpsCounter = fpsCounter + 1
    if tick() - fpsTimer >= 1 then
        infoFPS.setValue(tostring(fpsCounter))
        fpsCounter = 0
        fpsTimer = tick()
    end
    -- Update FOV circle
    if FOVCircle and cam then
        FOVCircle.Visible = Config.FOVVisible and Config.Enabled
        FOVCircle.Radius = Config.FOV
        FOVCircle.Position = Vector2.new(cam.ViewportSize.X / 2, cam.ViewportSize.Y / 2)
    end
    -- === ESP UPDATE ===
    if Config.ESP_Enabled and cam then
        for _, player in ipairs(Players:GetPlayers()) do
            if player ~= LocalPlayer then
                -- Ensure ESP objects exist
                if not ESPObjects[player] and Drawing then
                    pcall(function() createESP(player) end)
                end
                updateESP(player, cam)
            end
        end
    else
        -- ESP disabled: hide all drawings
        for player, data in pairs(ESPObjects) do
            for _, d in pairs(data) do
                d.Visible = false
            end
        end
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
            if cam then
                local dist = (bone.Position - cam.CFrame.Position).Magnitude
                infoDistance.setValue(string.format("%.0f studs", dist))
            end
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
    -- Re-init ESP objects (in case Drawing refs broke)
    if Drawing and Config.ESP_Enabled then
        for _, player in ipairs(Players:GetPlayers()) do
            if player ~= LocalPlayer and not ESPObjects[player] then
                pcall(function() createESP(player) end)
            end
        end
    end
end)
---------------------------------------------------------------------------
-- STARTUP NOTIFICATION
---------------------------------------------------------------------------
if game.StarterGui then
    pcall(function()
        game.StarterGui:SetCore("SendNotification", {
            Title = "Crosshair Lock v2.2",
            Text = "Loaded  ·  Press F to toggle  ·  DEL to kill",
            Duration = 4,
            Icon = "",
        })
    end)
end
print("[CROSSHAIR LOCK] v2.3 loaded — aimbot + ESP")
print("[CROSSHAIR LOCK] Press F = aimbot | J = ESP | DEL = destroy")
print("[CROSSHAIR LOCK] Aim: mousemoverel | ESP: Drawing API")

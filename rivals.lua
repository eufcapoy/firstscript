-- palofsc
-- Rivals Aimbot + ESP with WindUI Library (OP Aim + Tray Icon)
-- Features:
-- 1. OP Aimbot: Sticks tightly to enemy head
-- 2. Aim Mode slider: OP (instant lock) vs Casual (smooth)
-- 3. Tray icon with "B" logo to toggle menu instead of Insert

-- SERVICES
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local LocalPlayer = Players.LocalPlayer
local Camera = workspace.CurrentCamera

-- ============================================
-- WINDUI LOADER
-- ============================================
local WindUI = loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()

if not WindUI then
    error("WindUI failed to load.")
end

-- ============================================
-- CONFIGURATION
-- ============================================
local Settings = {
    AimbotEnabled = false,
    AimMode = "OP", -- "OP" or "Casual"
    OPStrength = 0.95, -- How tight the lock is (0.8-1.0)
    FOVRadius = 250,
    ESPEnabled = false,
    ESPBox = true,
    ESPName = false,
    ESPDistance = false,
    ESPHealth = false
}

-- ============================================
-- DRAWING OBJECTS (ESP & FOV)
-- ============================================
local ESPObjects = {}
local FOVCircle = Drawing.new("Circle")
FOVCircle.Thickness = 2
FOVCircle.Visible = false
FOVCircle.Color = Color3.fromRGB(255, 50, 50)
FOVCircle.Transparency = 0.5
FOVCircle.Filled = false
FOVCircle.Radius = Settings.FOVRadius

-- ============================================
-- TRAY ICON WITH "B" LOGO
-- ============================================
local TrayGui = Instance.new("ScreenGui")
TrayGui.Name = "TrayIcon"
TrayGui.ResetOnSpawn = false
TrayGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
TrayGui.Parent = LocalPlayer:WaitForChild("PlayerGui")

local TrayButton = Instance.new("ImageButton")
TrayButton.Name = "TrayButton"
TrayButton.Size = UDim2.new(0, 40, 0, 40)
TrayButton.Position = UDim2.new(0, 15, 0, 15)
TrayButton.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
TrayButton.BackgroundTransparency = 0.15
TrayButton.BorderSizePixel = 0
TrayButton.Image = "rbxassetid://10734824417" -- Blank circle
TrayButton.ImageColor3 = Color3.fromRGB(0, 180, 255)
TrayButton.ImageTransparency = 0.3
TrayButton.Parent = TrayGui

-- Round corners for the tray button
local TrayCorner = Instance.new("UICorner")
TrayCorner.CornerRadius = UDim.new(1, 0)
TrayCorner.Parent = TrayButton

-- "B" Label on the tray icon
local TrayLabel = Instance.new("TextLabel")
TrayLabel.Size = UDim2.new(1, 0, 1, 0)
TrayLabel.BackgroundTransparency = 1
TrayLabel.Text = "B"
TrayLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
TrayLabel.TextSize = 22
TrayLabel.TextScaled = true
TrayLabel.Font = Enum.Font.GothamBold
TrayLabel.Parent = TrayButton

-- Shadow for tray icon
local TrayShadow = Instance.new("ImageLabel")
TrayShadow.Size = UDim2.new(1, 4, 1, 4)
TrayShadow.Position = UDim2.new(0, -2, 0, -2)
TrayShadow.BackgroundTransparency = 1
TrayShadow.Image = "rbxassetid://10734824417"
TrayShadow.ImageColor3 = Color3.fromRGB(0, 0, 0)
TrayShadow.ImageTransparency = 0.6
TrayShadow.ZIndex = 0
TrayShadow.Parent = TrayButton

-- Toggle menu on tray click
local MenuVisible = true
TrayButton.MouseButton1Click:Connect(function()
    MenuVisible = not MenuVisible
    -- Find the main WindUI window and toggle visibility
    local mainFrame = nil
    for _, child in ipairs(LocalPlayer.PlayerGui:GetChildren()) do
        if child.Name == "WindUI" or child:FindFirstChild("MainFrame") then
            mainFrame = child
            break
        end
    end
    if mainFrame then
        mainFrame.Enabled = MenuVisible
    end
end)

-- Hover effect
TrayButton.MouseEnter:Connect(function()
    TweenService:Create(TrayButton, TweenInfo.new(0.15), {
        BackgroundTransparency = 0.05,
        Size = UDim2.new(0, 44, 0, 44),
        Position = UDim2.new(0, 13, 0, 13)
    }):Play()
end)

TrayButton.MouseLeave:Connect(function()
    TweenService:Create(TrayButton, TweenInfo.new(0.15), {
        BackgroundTransparency = 0.15,
        Size = UDim2.new(0, 40, 0, 40),
        Position = UDim2.new(0, 15, 0, 15)
    }):Play()
end)

-- ============================================
-- ESP HELPERS
-- ============================================
local function GetBoundingBox(character)
    local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
    local parts = character:GetChildren()
    for _, part in ipairs(parts) do
        if part:IsA("BasePart") then
            local pos, onScreen = Camera:WorldToViewportPoint(part.Position)
            if onScreen then
                local size = part.Size
                local corners = {
                    part.Position + Vector3.new(size.X/2, size.Y/2, size.Z/2),
                    part.Position + Vector3.new(-size.X/2, size.Y/2, size.Z/2),
                    part.Position + Vector3.new(size.X/2, -size.Y/2, size.Z/2),
                    part.Position + Vector3.new(-size.X/2, -size.Y/2, size.Z/2)
                }
                for _, corner in ipairs(corners) do
                    local screenPoint, onScreenCorner = Camera:WorldToViewportPoint(corner)
                    if onScreenCorner then
                        minX = math.min(minX, screenPoint.X)
                        minY = math.min(minY, screenPoint.Y)
                        maxX = math.max(maxX, screenPoint.X)
                        maxY = math.max(maxY, screenPoint.Y)
                    end
                end
            end
        end
    end
    if minX ~= math.huge and minY ~= math.huge and maxX ~= -math.huge and maxY ~= -math.huge then
        return {X = minX, Y = minY, Width = maxX - minX, Height = maxY - minY}
    end
    return nil
end

-- ============================================
-- CLEAR ESP OBJECTS
-- ============================================
local function ClearESPObjects()
    for _, obj in ipairs(ESPObjects) do
        if obj and obj.Remove then
            obj:Remove()
        end
    end
    ESPObjects = {}
end

-- ============================================
-- AIMBOT: Get closest target with head priority
-- ============================================
local function GetTarget()
    local targetPart = nil
    local shortestDist = Settings.FOVRadius
    local mousePos = UserInputService:GetMouseLocation()
    
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and player.Character and player.Character:FindFirstChild("Humanoid") and player.Character.Humanoid.Health > 0 then
            -- Priority: HeadHB > Head > UpperTorso
            local hitbox = player.Character:FindFirstChild("HeadHB") or 
                           player.Character:FindFirstChild("Head") or 
                           player.Character:FindFirstChild("UpperTorso")
            if hitbox then
                local screenPos, onScreen = Camera:WorldToViewportPoint(hitbox.Position)
                if onScreen then
                    local dist = (Vector2.new(screenPos.X, screenPos.Y) - mousePos).Magnitude
                    if dist < shortestDist then
                        shortestDist = dist
                        targetPart = hitbox
                    end
                end
            end
        end
    end
    return targetPart
end

-- ============================================
-- MAIN RENDER LOOP (Aimbot + ESP)
-- ============================================
RunService.RenderStepped:Connect(function()
    -- Update FOV circle
    FOVCircle.Visible = Settings.AimbotEnabled
    FOVCircle.Radius = Settings.FOVRadius
    FOVCircle.Position = UserInputService:GetMouseLocation()

    -- AIMBOT: OP or Casual mode
    if Settings.AimbotEnabled and UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2) then
        local target = GetTarget()
        if target then
            local targetScreen, _ = Camera:WorldToViewportPoint(target.Position)
            local currentMouse = UserInputService:GetMouseLocation()
            
            local deltaX = targetScreen.X - currentMouse.X
            local deltaY = targetScreen.Y - currentMouse.Y
            
            -- Apply mode-specific behavior
            if Settings.AimMode == "OP" then
                -- OP Mode: Instant lock with strength factor (0.95 = very tight)
                local strength = Settings.OPStrength
                deltaX = deltaX * strength
                deltaY = deltaY * strength
                -- If close enough, snap directly to target
                if math.abs(deltaX) < 3 and math.abs(deltaY) < 3 then
                    deltaX = deltaX * 1.5 -- Micro-adjustment for perfect lock
                    deltaY = deltaY * 1.5
                end
            else
                -- Casual Mode: Smooth, human-like aiming
                local smoothFactor = 0.25 -- Adjustable feel
                deltaX = deltaX * smoothFactor
                deltaY = deltaY * smoothFactor
            end
            
            if mousemoverel then
                mousemoverel(deltaX, deltaY)
            end
        end
    end

    -- ESP: Clear previous frame's objects FIRST to prevent multiplication
    ClearESPObjects()

    -- ESP: Draw fresh objects for this frame
    if Settings.ESPEnabled then
        for _, player in ipairs(Players:GetPlayers()) do
            if player ~= LocalPlayer and player.Character and player.Character:FindFirstChild("Humanoid") and player.Character.Humanoid.Health > 0 then
                local char = player.Character
                local humanoid = char.Humanoid
                local box = GetBoundingBox(char)
                if box then
                    -- Box ESP
                    if Settings.ESPBox then
                        local line1 = Drawing.new("Line")
                        line1.Thickness = 1.5
                        line1.Color = Color3.fromRGB(0, 255, 0)
                        line1.From = Vector2.new(box.X, box.Y)
                        line1.To = Vector2.new(box.X + box.Width, box.Y)
                        line1.Visible = true
                        table.insert(ESPObjects, line1)

                        local line2 = Drawing.new("Line")
                        line2.Thickness = 1.5
                        line2.Color = Color3.fromRGB(0, 255, 0)
                        line2.From = Vector2.new(box.X + box.Width, box.Y)
                        line2.To = Vector2.new(box.X + box.Width, box.Y + box.Height)
                        line2.Visible = true
                        table.insert(ESPObjects, line2)

                        local line3 = Drawing.new("Line")
                        line3.Thickness = 1.5
                        line3.Color = Color3.fromRGB(0, 255, 0)
                        line3.From = Vector2.new(box.X + box.Width, box.Y + box.Height)
                        line3.To = Vector2.new(box.X, box.Y + box.Height)
                        line3.Visible = true
                        table.insert(ESPObjects, line3)

                        local line4 = Drawing.new("Line")
                        line4.Thickness = 1.5
                        line4.Color = Color3.fromRGB(0, 255, 0)
                        line4.From = Vector2.new(box.X, box.Y + box.Height)
                        line4.To = Vector2.new(box.X, box.Y)
                        line4.Visible = true
                        table.insert(ESPObjects, line4)
                    end

                    -- Name ESP
                    if Settings.ESPName then
                        local nameText = Drawing.new("Text")
                        nameText.Text = player.Name
                        nameText.Position = Vector2.new(box.X + box.Width/2 - nameText.TextBounds.X/2, box.Y - 20)
                        nameText.Color = Color3.fromRGB(255, 255, 255)
                        nameText.Size = 14
                        nameText.Visible = true
                        table.insert(ESPObjects, nameText)
                    end

                    -- Distance ESP
                    if Settings.ESPDistance then
                        local dist = (LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("Head") and (LocalPlayer.Character.Head.Position - char.Head.Position).Magnitude) or 0
                        local distText = Drawing.new("Text")
                        distText.Text = string.format("%.1fm", dist)
                        distText.Position = Vector2.new(box.X + box.Width/2 - distText.TextBounds.X/2, box.Y + box.Height + 5)
                        distText.Color = Color3.fromRGB(200, 200, 200)
                        distText.Size = 12
                        distText.Visible = true
                        table.insert(ESPObjects, distText)
                    end

                    -- Health Bar ESP
                    if Settings.ESPHealth then
                        local healthPercent = humanoid.Health / humanoid.MaxHealth
                        local healthLine = Drawing.new("Line")
                        healthLine.Thickness = 4
                        healthLine.Color = Color3.fromRGB(255 * (1 - healthPercent), 255 * healthPercent, 0)
                        healthLine.From = Vector2.new(box.X, box.Y + box.Height + 2)
                        healthLine.To = Vector2.new(box.X + box.Width * healthPercent, box.Y + box.Height + 2)
                        healthLine.Visible = true
                        table.insert(ESPObjects, healthLine)
                    end
                end
            end
        end
    end
end)

-- ============================================
-- WINDUI UI CREATION
-- ============================================
local MainWindow = WindUI:CreateWindow({
    Title = "Rivals Cheat",
    SubTitle = "by : Rivals",
    Size = UDim2.fromOffset(420, 520),
    Theme = "Dark",
    Resizable = true,
    ToggleKey = Enum.KeyCode.Insert -- Keep Insert as fallback
})

-- ============================================
-- TAB 1: Aimbot
-- ============================================
local AimbotTab = MainWindow:Tab({
    Title = "Aimbot",
    Icon = "crosshair"
})

AimbotTab:Toggle({
    Title = "Enable Aimbot",
    Desc = "Toggle aimbot ON/OFF (hold Right Mouse to lock)",
    Value = false,
    Callback = function(value)
        Settings.AimbotEnabled = value
        print("Aimbot " .. (value and "ENABLED" or "DISABLED"))
    end
})

-- Aim Mode: OP vs Casual
AimbotTab:Dropdown({
    Title = "Aim Mode",
    Desc = "OP: Instant tight lock | Casual: Smooth human-like",
    Options = {"OP", "Casual"},
    Default = "OP",
    Callback = function(value)
        Settings.AimMode = value
        print("Aim Mode set to: " .. value)
    end
})

-- OP Strength slider (only affects OP mode)
AimbotTab:Slider({
    Title = "OP Lock Strength",
    Desc = "0.8 = loose | 1.0 = perfect instant lock",
    Value = {
        Min = 0.8,
        Max = 1.0,
        Default = 0.95
    },
    Step = 0.01,
    Callback = function(value)
        Settings.OPStrength = value
    end
})

AimbotTab:Slider({
    Title = "FOV Radius",
    Desc = "Field of view radius in pixels",
    Value = {
        Min = 30,
        Max = 500,
        Default = 250
    },
    Step = 1,
    Callback = function(value)
        Settings.FOVRadius = value
    end
})

-- ============================================
-- TAB 2: ESP
-- ============================================
local ESPTab = MainWindow:Tab({
    Title = "ESP",
    Icon = "eye"
})

ESPTab:Toggle({
    Title = "Enable ESP",
    Desc = "Toggle ESP ON/OFF",
    Value = false,
    Callback = function(value)
        Settings.ESPEnabled = value
        if not value then
            ClearESPObjects()
        end
        print("ESP " .. (value and "ENABLED" or "DISABLED"))
    end
})

ESPTab:Toggle({
    Title = "Box ESP",
    Desc = "Show 2D bounding boxes",
    Value = true,
    Callback = function(value)
        Settings.ESPBox = value
    end
})

ESPTab:Toggle({
    Title = "Name ESP",
    Desc = "Show player names",
    Value = false,
    Callback = function(value)
        Settings.ESPName = value
    end
})

ESPTab:Toggle({
    Title = "Distance ESP",
    Desc = "Show distance to player",
    Value = false,
    Callback = function(value)
        Settings.ESPDistance = value
    end
})

ESPTab:Toggle({
    Title = "Health Bar",
    Desc = "Show health bar under player",
    Value = false,
    Callback = function(value)
        Settings.ESPHealth = value
    end
})

-- ============================================
-- TAB 3: Status
-- ============================================
local StatusTab = MainWindow:Tab({
    Title = "Status",
    Icon = "info"
})

StatusTab:Button({
    Title = "Refresh Status",
    Desc = "Click to update status display",
    Callback = function()
        print("=== STATUS ===")
        print("Aimbot: " .. (Settings.AimbotEnabled and "ON" or "OFF"))
        print("Aim Mode: " .. Settings.AimMode)
        print("OP Strength: " .. tostring(Settings.OPStrength))
        print("FOV: " .. tostring(Settings.FOVRadius))
        print("ESP: " .. (Settings.ESPEnabled and "ON" or "OFF"))
        print("Box ESP: " .. (Settings.ESPBox and "ON" or "OFF"))
        print("Name ESP: " .. (Settings.ESPName and "ON" or "OFF"))
        print("Distance ESP: " .. (Settings.ESPDistance and "ON" or "OFF"))
        print("Health ESP: " .. (Settings.ESPHealth and "ON" or "OFF"))
    end
})

StatusTab:Button({
    Title = "Click 'B' Icon to toggle menu",
    Desc = "Tray icon with 'B' logo in top-left",
    Callback = function() end
})

-- ============================================
-- INITIALIZATION COMPLETE
-- ============================================
print("Rivals Cheat v2.0 loaded successfully!")
print("Aimbot: Use UI toggle to enable/disable | Hold Right Mouse to lock")
print("Aim Modes: OP (tight lock) | Casual (smooth)")
print("ESP: Use UI toggle to enable/disable")
print("Menu Toggle: Click the 'B' icon in top-left or press Insert")
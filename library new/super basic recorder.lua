if not game:IsLoaded() then pcall(function() game.Loaded:Wait() end) end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local local_player = Players.LocalPlayer or Players.PlayerAdded:Wait()
local player_gui = local_player:WaitForChild("PlayerGui")

if _G.TDS == nil then _G.TDS = {} end
local TDS = _G.TDS

local _log_history = {}
local _tower_logs = {}
local _logged_towers = setmetatable({}, { __mode = "k" })
local _auto_log_interval = 5
local _auto_log_running = false
local _resizable_enabled = false

local function append_log(line)
    pcall(function()
        table.insert(_log_history, "[" .. os.date("%H:%M:%S") .. "] " .. tostring(line))
        if #_log_history > 800 then table.remove(_log_history, 1) end
    end)
end

local function append_tower_log_struct(tbl)
    pcall(function()
        table.insert(_tower_logs, tbl)
        if #_tower_logs > 800 then table.remove(_tower_logs, 1) end
    end)
end

local function find_child_ci(parent, name)
    if not parent then return nil end
    local direct = parent:FindFirstChild(name)
    if direct then return direct end
    local lname = name:lower()
    for _, c in ipairs(parent:GetChildren()) do
        if c.Name:lower() == lname then
            return c
        end
    end
    return nil
end

local function extract_t_name(tower)
    if not tower then return "Unknown" end
    if typeof(tower) ~= "Instance" then
        if type(tower) == "table" and tower.Name then return tostring(tower.Name) end
        return "Unknown"
    end

    local ok, a = pcall(function()
        return tower:GetAttribute("t_name") or tower:GetAttribute("TName") or tower:GetAttribute("tname") or tower:GetAttribute("Troop")
    end)
    if ok and a and tostring(a) ~= "" then return tostring(a) end

    local candidates = { "t_name", "TName", "tname", "Troop", "troop", "TroopName", "Internal_name", "InternalName" }
    for _, cname in ipairs(candidates) do
        local child = find_child_ci(tower, cname)
        if child then
            if child:IsA("StringValue") and child.Value and child.Value ~= "" then return child.Value end
            if child:IsA("IntValue") and child.Value then return tostring(child.Value) end
            if child:IsA("ObjectValue") and child.Value and typeof(child.Value) == "Instance" then return tostring(child.Value.Name) end
            if child:IsA("ValueBase") and child.Value ~= nil then return tostring(child.Value) end
        end
    end

    for _, d in ipairs(tower:GetDescendants()) do
        if d:IsA("StringValue") or d:IsA("IntValue") or d:IsA("ValueBase") then
            local lname = d.Name:lower()
            if lname:find("t_name") or lname:find("tname") or lname:find("troop") or lname:find("internal") or lname:find("prefab") then
                if d:IsA("StringValue") and d.Value and d.Value ~= "" then return d.Value end
                if d:IsA("IntValue") and d.Value then return tostring(d.Value) end
                if d:IsA("ValueBase") and d.Value ~= nil then return tostring(d.Value) end
            end
        end
    end

    for _, d in ipairs(tower:GetDescendants()) do
        if d:IsA("ModuleScript") and d.Name and d.Name ~= "" then
            local nm = d.Name
            if nm:lower():find("troop") or nm:lower():find("unit") or nm:lower():find("prefab") then
                return nm
            end
        end
        if d:IsA("ObjectValue") and d.Value and typeof(d.Value) == "Instance" then
            local ref = d.Value
            if ref:IsDescendantOf(ReplicatedStorage) then
                return ref.Name
            end
        end
    end

    local ok2, tname = pcall(function() return tower:GetAttribute("t_name") end)
    if ok2 and tname and tostring(tname) ~= "" then return tostring(tname) end

    if tower.Name and tower.Name ~= "" then return tower.Name end
    return "Unknown"
end

local function get_tower_position(tower)
    if not tower then return nil end
    if type(tower) == "table" and tower.Position then return tower.Position end
    if typeof(tower) == "Instance" then
        if tower.PrimaryPart and tower.PrimaryPart:IsA("BasePart") then
            return tower.PrimaryPart.Position
        end
        for _, d in ipairs(tower:GetDescendants()) do
            if d:IsA("BasePart") then return d.Position end
        end
    end
    return nil
end

local function get_tower_index(tower)
    if TDS and type(TDS.placed_towers) == "table" and #TDS.placed_towers > 0 then
        for i, v in ipairs(TDS.placed_towers) do if v == tower then return i end end
    end
    local tf = workspace:FindFirstChild("Towers")
    if tf then
        local ch = tf:GetChildren()
        for i, v in ipairs(ch) do if v == tower then return i end end
    end
    return (#_tower_logs) + 1
end

local function format_as_tds_place(tname, pos, index)
    if pos then
        return string.format('TDS:Place("%s", %.2f, %.2f, %.2f) -- %d', tostring(tname), pos.X, pos.Y, pos.Z, index)
    else
        return string.format('TDS:Place("%s", nil) -- %d', tostring(tname), index)
    end
end

local function log_single_tower_once(tower)
    if not tower then return end
    local already = false
    pcall(function() already = (_logged_towers[tower] == true) end)
    if already then return end

    local idx = get_tower_index(tower)
    local tname = extract_t_name(tower)
    local pos = get_tower_position(tower)
    local line = format_as_tds_place(tname, pos, idx)

    _logged_towers[tower] = true
    append_tower_log_struct({ text = line, index = idx, t_name = tname, pos = pos, time = os.time() })
    append_log(line)
end

local function scan_tower_positions()
    pcall(function()
        local source = (TDS and type(TDS.placed_towers) == "table") and TDS.placed_towers or nil
        if not source or #source == 0 then
            local tf = workspace:FindFirstChild("Towers")
            source = tf and tf:GetChildren() or {}
        end
        for _, tower in ipairs(source) do
            log_single_tower_once(tower)
        end
    end)
end

do
    local tf = workspace:FindFirstChild("Towers")
    if tf then
        tf.ChildAdded:Connect(function(child)
            task.wait(0.05)
            log_single_tower_once(child)
            pcall(function()
                if TDS and type(TDS.placed_towers) == "table" then
                    local found = false
                    for _, v in ipairs(TDS.placed_towers) do if v == child then found = true; break end end
                    if not found then table.insert(TDS.placed_towers, child) end
                end
            end)
        end)
    end
    workspace.ChildAdded:Connect(function(c)
        if c and c.Name == "Towers" and c:IsA("Folder") then
            c.ChildAdded:Connect(function(child)
                task.wait(0.05)
                log_single_tower_once(child)
                pcall(function()
                    if TDS and type(TDS.placed_towers) == "table" then
                        local found = false
                        for _, v in ipairs(TDS.placed_towers) do if v == child then found = true; break end end
                        if not found then table.insert(TDS.placed_towers, child) end
                    end
                end)
            end)
        end
    end)
end

local function copy_to_clipboard(text)
    if not text then return false, "no text" end
    if setclipboard then
        local ok, err = pcall(setclipboard, text)
        if ok then return true end
        return false, tostring(err)
    end
    if syn and syn.set_clipboard then
        local ok, err = pcall(syn.set_clipboard, text)
        if ok then return true end
        return false, tostring(err)
    end
    if toclipboard then
        local ok, err = pcall(toclipboard, text)
        if ok then return true end
        return false, tostring(err)
    end
    if (typeof(write_clipboard) == "function") then
        local ok, err = pcall(write_clipboard, text)
        if ok then return true end
        return false, tostring(err)
    end
    return false, "clipboard function not found"
end

local UI_NAME = "TDS_TowerLogger_UI_tname"
local existing_ui = player_gui:FindFirstChild(UI_NAME)
if existing_ui then pcall(function() existing_ui:Destroy() end) end

local screen_gui = Instance.new("ScreenGui")
screen_gui.Name = UI_NAME
screen_gui.ResetOnSpawn = false
screen_gui.Parent = player_gui

local main_frame = Instance.new("Frame")
main_frame.Name = "MainFrame"
main_frame.Size = UDim2.new(0, 480, 0, 360)
main_frame.Position = UDim2.new(0, 20, 0, 80)
main_frame.BackgroundColor3 = Color3.fromRGB(30,30,30)
main_frame.BorderSizePixel = 0
main_frame.Active = true
main_frame.Parent = screen_gui

local ui_stroke = Instance.new("UIStroke", main_frame)
ui_stroke.Color = Color3.fromRGB(50,50,50)
ui_stroke.Thickness = 1

local title = Instance.new("TextLabel", main_frame)
title.Name = "Title"
title.Size = UDim2.new(1, -80, 0, 28)
title.Position = UDim2.new(0, 8, 0, 6)
title.BackgroundTransparency = 1
title.Text = "TDS — Tower Logger (t_name)"
title.TextXAlignment = Enum.TextXAlignment.Left
title.Font = Enum.Font.SourceSansBold
title.TextSize = 16
title.TextColor3 = Color3.fromRGB(255,255,255)

local minimize_btn = Instance.new("TextButton", main_frame)
minimize_btn.Name = "Minimize"
minimize_btn.Size = UDim2.new(0, 28, 0, 24)
minimize_btn.Position = UDim2.new(1, -36, 0, 6)
minimize_btn.Text = "-"
minimize_btn.Font = Enum.Font.SourceSansBold
minimize_btn.TextSize = 18
minimize_btn.TextColor3 = Color3.fromRGB(255,255,255)
minimize_btn.BackgroundColor3 = Color3.fromRGB(70,70,70)

local resize_toggle = Instance.new("TextButton", main_frame)
resize_toggle.Name = "ResizeToggle"
resize_toggle.Size = UDim2.new(0, 120, 0, 24)
resize_toggle.Position = UDim2.new(1, -160, 0, 6)
resize_toggle.Text = "Resizable: OFF"
resize_toggle.Font = Enum.Font.SourceSans
resize_toggle.TextSize = 12
resize_toggle.BackgroundColor3 = Color3.fromRGB(160,60,60)
resize_toggle.TextColor3 = Color3.fromRGB(255,255,255)

local tabs = Instance.new("Frame", main_frame)
tabs.Name = "Tabs"
tabs.Size = UDim2.new(1, -16, 0, 34)
tabs.Position = UDim2.new(0, 8, 0, 44)
tabs.BackgroundTransparency = 1

local function make_tab(name, x)
    local b = Instance.new("TextButton", tabs)
    b.Name = name .. "Tab"
    b.Size = UDim2.new(0, 140, 1, 0)
    b.Position = UDim2.new(0, x, 0, 0)
    b.Text = name
    b.Font = Enum.Font.SourceSansSemibold
    b.TextSize = 14
    b.BackgroundColor3 = Color3.fromRGB(46,46,46)
    b.TextColor3 = Color3.fromRGB(220,220,220)
    return b
end

local controls_tab_btn = make_tab("Controls", 0)
local logs_tab_btn = make_tab("Logs", 150)

local content_y = 86
local content_h = 360 - content_y - 18
local controls_frame = Instance.new("Frame", main_frame)
controls_frame.Name = "ControlsFrame"
controls_frame.Size = UDim2.new(1, -16, 0, content_h)
controls_frame.Position = UDim2.new(0, 8, 0, content_y)
controls_frame.BackgroundTransparency = 1

local logs_frame = Instance.new("Frame", main_frame)
logs_frame.Name = "LogsFrame"
logs_frame.Size = controls_frame.Size
logs_frame.Position = controls_frame.Position
logs_frame.BackgroundTransparency = 1
logs_frame.Visible = false

local sep = Instance.new("Frame", main_frame)
sep.Name = "Separator"
sep.Size = UDim2.new(1, -16, 0, 1)
sep.Position = UDim2.new(0, 8, 1, -48)
sep.BackgroundColor3 = Color3.fromRGB(60,60,60)
sep.BorderSizePixel = 0

local scan_btn = Instance.new("TextButton", controls_frame)
scan_btn.Name = "ScanNow"
scan_btn.Size = UDim2.new(0, 300, 0, 30)
scan_btn.Position = UDim2.new(0, 8, 0, 6)
scan_btn.Text = "Scan Towers Now (log any unlogged instantly)"
scan_btn.Font = Enum.Font.SourceSans
scan_btn.TextSize = 14
scan_btn.BackgroundColor3 = Color3.fromRGB(70,70,70)
scan_btn.TextColor3 = Color3.fromRGB(240,240,240)

local auto_log_lbl = Instance.new("TextLabel", controls_frame)
auto_log_lbl.Size = UDim2.new(0, 160, 0, 20)
auto_log_lbl.Position = UDim2.new(0, 8, 0, 44)
auto_log_lbl.BackgroundTransparency = 1
auto_log_lbl.Text = "Auto Log Interval (sec):"
auto_log_lbl.Font = Enum.Font.SourceSans
auto_log_lbl.TextSize = 14
auto_log_lbl.TextColor3 = Color3.fromRGB(220,220,220)

local interval_box = Instance.new("TextBox", controls_frame)
interval_box.Size = UDim2.new(0, 60, 0, 22)
interval_box.Position = UDim2.new(0, 180, 0, 44)
interval_box.PlaceholderText = tostring(_auto_log_interval)
interval_box.ClearTextOnFocus = false
interval_box.Font = Enum.Font.SourceSans
interval_box.TextSize = 14
interval_box.BackgroundColor3 = Color3.fromRGB(40,40,40)
interval_box.TextColor3 = Color3.fromRGB(230,230,230)

local auto_log_toggle = Instance.new("TextButton", controls_frame)
auto_log_toggle.Name = "AutoLogToggle"
auto_log_toggle.Size = UDim2.new(0, 100, 0, 28)
auto_log_toggle.Position = UDim2.new(0, 260, 0, 42)
auto_log_toggle.Text = "Auto Log: OFF"
auto_log_toggle.Font = Enum.Font.SourceSansBold
auto_log_toggle.TextSize = 12
auto_log_toggle.BackgroundColor3 = Color3.fromRGB(160,60,60)
auto_log_toggle.TextColor3 = Color3.fromRGB(255,255,255)

local last_scan_label = Instance.new("TextLabel", controls_frame)
last_scan_label.Size = UDim2.new(1, -20, 0, 18)
last_scan_label.Position = UDim2.new(0, 8, 0, 78)
last_scan_label.BackgroundTransparency = 1
last_scan_label.Text = "Last scan: never"
last_scan_label.Font = Enum.Font.SourceSans
last_scan_label.TextSize = 13
last_scan_label.TextColor3 = Color3.fromRGB(200,200,200)

local logs_scroller = Instance.new("ScrollingFrame", logs_frame)
logs_scroller.Name = "LogsScroller"
logs_scroller.Size = UDim2.new(1, -20, 1, -120)
logs_scroller.Position = UDim2.new(0, 10, 0, 85)
logs_scroller.BackgroundColor3 = Color3.fromRGB(20,20,20)
logs_scroller.BorderSizePixel = 0
logs_scroller.ScrollBarThickness = 8

local ui_list = Instance.new("UIListLayout", logs_scroller)
ui_list.Padding = UDim.new(0, 6)

local refresh_btn = Instance.new("TextButton", logs_frame)
refresh_btn.Name = "Refresh"
refresh_btn.Size = UDim2.new(0, 100, 0, 28)
refresh_btn.Position = UDim2.new(1, -220, 1, -40)
refresh_btn.Text = "Refresh"
refresh_btn.Font = Enum.Font.SourceSans
refresh_btn.TextSize = 13
refresh_btn.BackgroundColor3 = Color3.fromRGB(70,70,70)
refresh_btn.TextColor3 = Color3.fromRGB(230,230,230)

local copy_btn = Instance.new("TextButton", logs_frame)
copy_btn.Name = "CopyLogs"
copy_btn.Size = UDim2.new(0, 120, 0, 28)
copy_btn.Position = UDim2.new(1, -100, 1, -40)
copy_btn.Text = "Copy All Logs"
copy_btn.Font = Enum.Font.SourceSans
copy_btn.TextSize = 13
copy_btn.BackgroundColor3 = Color3.fromRGB(70,70,70)
copy_btn.TextColor3 = Color3.fromRGB(230,230,230)

controls_tab_btn.MouseButton1Click:Connect(function()
    controls_frame.Visible = true
    logs_frame.Visible = false
end)
logs_tab_btn.MouseButton1Click:Connect(function()
    controls_frame.Visible = false
    logs_frame.Visible = true
    pcall(function() refresh_btn:MouseButton1Click() end)
end)

local resize_handle = Instance.new("Frame", main_frame)
resize_handle.Name = "ResizeHandle"
resize_handle.Size = UDim2.new(0, 18, 0, 18)
resize_handle.Position = UDim2.new(1, -20, 1, -20)
resize_handle.BackgroundColor3 = Color3.fromRGB(90,90,90)
resize_handle.AnchorPoint = Vector2.new(1,1)
resize_handle.Visible = false
local resize_icon = Instance.new("ImageLabel", resize_handle)
resize_icon.Size = UDim2.new(1,0,1,0)
resize_icon.Image = "rbxassetid://3926305904"
resize_icon.ImageColor3 = Color3.fromRGB(200,200,200)
resize_icon.BackgroundTransparency = 1

resize_toggle.MouseButton1Click:Connect(function()
    _resizable_enabled = not _resizable_enabled
    resize_toggle.Text = (_resizable_enabled and "Resizable: ON" or "Resizable: OFF")
    resize_toggle.BackgroundColor3 = (_resizable_enabled and Color3.fromRGB(80,170,80) or Color3.fromRGB(160,60,60))
    resize_handle.Visible = _resizable_enabled
end)

do
    local resizing = false
    local startPos = Vector2.new()
    local startSize = Vector2.new()
    local minW, minH = 320, 180
    local maxW, maxH = 1200, 900

    resize_handle.InputBegan:Connect(function(input)
        if not _resizable_enabled then return end
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            resizing = true
            startPos = input.Position
            startSize = Vector2.new(main_frame.AbsoluteSize.X, main_frame.AbsoluteSize.Y)
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then resizing = false end
            end)
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if not resizing then return end
        local delta = input.Position - startPos
        local newW = math.clamp(startSize.X + delta.X, minW, maxW)
        local newH = math.clamp(startSize.Y + delta.Y, minH, maxH)
        main_frame.Size = UDim2.new(0, newW, 0, newH)
    end)
end

do
    local dragging = false
    local dragStart = Vector2.new()
    local startPos = main_frame.Position
    local currentInput = nil

    main_frame.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            currentInput = input
            dragStart = input.Position
            startPos = main_frame.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                    currentInput = nil
                end
            end)
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if not dragging then return end
        if input ~= currentInput then return end
        local delta = input.Position - dragStart
        main_frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
    end)
end

local function make_log_label(text)
    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, -24, 0, 0)
    lbl.Position = UDim2.new(0, 12, 0, 0)
    lbl.BackgroundTransparency = 1
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.TextYAlignment = Enum.TextYAlignment.Top
    lbl.TextWrapped = true
    lbl.AutomaticSize = Enum.AutomaticSize.Y
    lbl.Font = Enum.Font.Code
    lbl.TextSize = 14
    lbl.TextColor3 = Color3.fromRGB(200,200,200)
    lbl.Text = text
    return lbl
end

local function update_logs_ui()
    for _, child in ipairs(logs_scroller:GetChildren()) do if child:IsA("TextLabel") then child:Destroy() end end
    for _, t in ipairs(_tower_logs) do
        local lbl = make_log_label(t.text)
        lbl.Parent = logs_scroller
    end
end

refresh_btn.MouseButton1Click:Connect(update_logs_ui)

auto_log_toggle.MouseButton1Click:Connect(function()
    _auto_log_running = not _auto_log_running
    auto_log_toggle.Text = _auto_log_running and "Auto Log: ON" or "Auto Log: OFF"
    auto_log_toggle.BackgroundColor3 = _auto_log_running and Color3.fromRGB(80,170,80) or Color3.fromRGB(160,60,60)
    if _auto_log_running then
        local n = tonumber(interval_box.Text)
        if n and n > 0 then _auto_log_interval = n end
        task.spawn(function()
            while _auto_log_running do
                scan_tower_positions()
                last_scan_label.Text = "Last scan: " .. os.date("%Y-%m-%d %H:%M:%S")
                update_logs_ui()
                task.wait(_auto_log_interval)
            end
        end)
    end
end)

scan_btn.MouseButton1Click:Connect(function()
    scan_tower_positions()
    last_scan_label.Text = "Last scan: " .. os.date("%Y-%m-%d %H:%M:%S")
    update_logs_ui()
end)

copy_btn.MouseButton1Click:Connect(function()
    local parts = {}
    table.insert(parts, "TDS AutoStrat Tower Logs Export")
    table.insert(parts, "Generated: " .. os.date("%Y-%m-%d %H:%M:%S"))
    table.insert(parts, "")
    table.insert(parts, "Tower Logs:")
    for _, t in ipairs(_tower_logs) do table.insert(parts, t.text) end

    local text = table.concat(parts, "\n")
    local ok, err = copy_to_clipboard(text)
    if ok then append_log("Copied tower logs to clipboard") else append_log("Copy to clipboard failed: " .. tostring(err)) end
    update_logs_ui()
end)

task.spawn(function()
    while true do
        if logs_frame.Visible then pcall(update_logs_ui) end
        task.wait(1.5)
    end
end)

task.spawn(function()
    task.wait(0.05)
    scan_tower_positions()
    update_logs_ui()
end)

_G.TDS_TowerLogger_Scan = scan_tower_positions
_G.TDS_TowerLogger_Logs = _tower_logs

return TDS
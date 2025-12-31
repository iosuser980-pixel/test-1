if not game:IsLoaded() then pcall(function() game.Loaded:Wait() end) end
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local local_player = Players.LocalPlayer or Players.PlayerAdded:Wait()
local player_gui = local_player:WaitForChild("PlayerGui")
local workspace = workspace
if type(_G.TDS) ~= "table" then
    _G.TDS = {
        placed_towers = {},
        active_strat = true,
        autoskip = function(self,v) _G.AutoSkip = v end,
        Upgrade = function(self, idx) end,
        Sell = function(self, idx) return false end
    }
end
_G.TDS_TowerLogger_Renames = _G.TDS_TowerLogger_Renames or {}
local rename_map = _G.TDS_TowerLogger_Renames
local UI_NAME = "TDS_TowerLogger_UI_Mobile"
local _tower_logs = {}
local _logged_towers = setmetatable({}, { __mode = "k" })
_G._TDS_Logger_Suppress = _G._TDS_Logger_Suppress or false
local _auto_log_interval = 1.2
local _auto_log_running = true
local function safe_attr(inst, key)
    local ok, v = pcall(function() if inst and inst.GetAttribute then return inst:GetAttribute(key) end end)
    return ok and v or nil
end
local function findChildCI(parent, name)
    if not parent then return nil end
    local d = parent:FindFirstChild(name)
    if d then return d end
    local lname = name:lower()
    for _, c in ipairs(parent:GetChildren()) do
        if c.Name:lower() == lname then return c end
    end
    return nil
end
local function extract_t_name(tower)
    if not tower then return "Unknown" end
    if typeof(tower) ~= "Instance" then
        if type(tower) == "table" and tower.Name then return tostring(tower.Name) end
        return "Unknown"
    end
    local a = safe_attr(tower, "t_name") or safe_attr(tower, "TName") or safe_attr(tower, "tname")
    if a and tostring(a) ~= "" then return tostring(a) end
    local child = findChildCI(tower, "t_name") or findChildCI(tower, "TName") or findChildCI(tower, "tname")
    if child then
        if child:IsA("StringValue") and child.Value and child.Value ~= "" then return child.Value end
        if child:IsA("ObjectValue") and child.Value and typeof(child.Value) == "Instance" then return child.Value.Name end
    end
    if tower.Name and tower.Name ~= "" then return tower.Name end
    return "Unknown"
end
local function get_pos(tower)
    if not tower then return nil end
    if tower.PrimaryPart and tower.PrimaryPart:IsA("BasePart") then return tower.PrimaryPart.Position end
    for _, d in ipairs(tower:GetDescendants()) do if d:IsA("BasePart") then return d.Position end end
    return nil
end
local function get_index(tower)
    if type(_G.TDS) == "table" and type(_G.TDS.placed_towers) == "table" then
        for i,v in ipairs(_G.TDS.placed_towers) do if v == tower then return i end end
    end
    local tf = workspace:FindFirstChild("Towers")
    if tf then
        for i,v in ipairs(tf:GetChildren()) do if v == tower then return i end end
    end
    return nil
end
local function fmt_place(name,pos,idx)
    if pos then
        return string.format('TDS:Place("%s", %.2f, %.2f, %.2f) -- %d', tostring(name), pos.X, pos.Y, pos.Z, idx or 0)
    else
        return string.format('TDS:Place("%s", nil) -- %d', tostring(name), idx or 0)
    end
end
local function fmt_upgrade(idx) return string.format('TDS:Upgrade(%s)', tostring(idx or "<nil>")) end
local function fmt_autoskip(v) return string.format('TDS:autoskip(%s)', tostring(v and "true" or "false")) end
local function try_clip(text)
    if not text then return false end
    if setclipboard then pcall(setclipboard, text); return true end
    if syn and syn.set_clipboard then pcall(syn.set_clipboard, text); return true end
    if toclipboard then pcall(toclipboard, text); return true end
    if typeof(write_clipboard) == "function" then pcall(write_clipboard, text); return true end
    return false
end
pcall(function() local ex = player_gui:FindFirstChild(UI_NAME); if ex then ex:Destroy() end end)
local screen_gui = Instance.new("ScreenGui")
screen_gui.Name = UI_NAME
screen_gui.ResetOnSpawn = false
screen_gui.Parent = player_gui
local MAIN_W, MAIN_H = 420, 280
local main = Instance.new("Frame")
main.Name = "Main"
main.Size = UDim2.new(0, MAIN_W, 0, MAIN_H)
main.Position = UDim2.new(0, 20, 0, 80)
main.BackgroundColor3 = Color3.fromRGB(34,34,34)
main.BorderSizePixel = 0
main.Parent = screen_gui
Instance.new("UICorner", main).CornerRadius = UDim.new(0,10)
local header = Instance.new("Frame", main)
header.Name = "Header"
header.Size = UDim2.new(1, 0, 0, 32)
header.Position = UDim2.new(0, 0, 0, 0)
header.BackgroundColor3 = Color3.fromRGB(28,28,28)
Instance.new("UICorner", header).CornerRadius = UDim.new(0,10)
local dragStrip = Instance.new("TextLabel", header)
dragStrip.Name = "DragStrip"
dragStrip.Size = UDim2.new(0.46, 0, 1, 0)
dragStrip.Position = UDim2.new(0, 0, 0, 0)
dragStrip.BackgroundColor3 = Color3.fromRGB(26,26,26)
dragStrip.Text = "Drag"
dragStrip.Font = Enum.Font.SourceSans
dragStrip.TextSize = 12
dragStrip.TextColor3 = Color3.fromRGB(180,180,180)
dragStrip.TextXAlignment = Enum.TextXAlignment.Left
Instance.new("UICorner", dragStrip).CornerRadius = UDim.new(0,8)
dragStrip.ZIndex = 5
local title = Instance.new("TextLabel", header)
title.Size = UDim2.new(0.54, -8, 1, 0)
title.Position = UDim2.new(0.46, 8, 0, 0)
title.BackgroundTransparency = 1
title.Text = "TDS Logger"
title.Font = Enum.Font.SourceSansBold
title.TextSize = 13
title.TextColor3 = Color3.fromRGB(240,240,240)
title.TextXAlignment = Enum.TextXAlignment.Left
title.ZIndex = 6
local tabs = Instance.new("Frame", header)
tabs.Size = UDim2.new(0.4, -8, 1, 0)
tabs.Position = UDim2.new(0.6, 8, 0, 0)
tabs.BackgroundTransparency = 1
tabs.ZIndex = 6
local function mkTab(text, xpos)
    local b = Instance.new("TextButton", tabs)
    b.Size = UDim2.new(0.5, -6, 1, -6)
    b.Position = UDim2.new(xpos, (xpos==0 and 0 or 6), 0, 3)
    b.Text = text
    b.Font = Enum.Font.SourceSansSemibold
    b.TextSize = 11
    b.BackgroundColor3 = Color3.fromRGB(46,46,46)
    b.TextColor3 = Color3.fromRGB(220,220,220)
    Instance.new("UICorner", b).CornerRadius = UDim.new(0,6)
    return b
end
local logsTabBtn = mkTab("Logs", 0)
local namesTabBtn = mkTab("Names", 0.5)
local content = Instance.new("Frame", main)
content.Size = UDim2.new(1, -12, 1, -78)
content.Position = UDim2.new(0, 6, 0, 36)
content.BackgroundTransparency = 1
local logsFrame = Instance.new("Frame", content)
logsFrame.Size = UDim2.new(1, 0, 1, 0)
logsFrame.BackgroundTransparency = 1
local logsBg = Instance.new("Frame", logsFrame)
logsBg.Size = UDim2.new(1, 0, 1, 0)
logsBg.Position = UDim2.new(0, 0, 0, 0)
logsBg.BackgroundColor3 = Color3.fromRGB(24,24,24)
Instance.new("UICorner", logsBg).CornerRadius = UDim.new(0,8)
local logsScroller = Instance.new("ScrollingFrame", logsBg)
logsScroller.Size = UDim2.new(1, -12, 1, -12)
logsScroller.Position = UDim2.new(0, 6, 0, 6)
logsScroller.BackgroundTransparency = 1
logsScroller.BorderSizePixel = 0
logsScroller.ScrollBarThickness = 8
logsScroller.AutomaticCanvasSize = Enum.AutomaticSize.Y
local logsLayout = Instance.new("UIListLayout", logsScroller)
logsLayout.Padding = UDim.new(0,6)
logsLayout.SortOrder = Enum.SortOrder.LayoutOrder
local namesFrame = Instance.new("Frame", content)
namesFrame.Size = logsFrame.Size
namesFrame.Position = logsFrame.Position
namesFrame.BackgroundTransparency = 1
namesFrame.Visible = false
local namesBg = Instance.new("Frame", namesFrame)
namesBg.Size = UDim2.new(1,0,1,0)
namesBg.BackgroundColor3 = Color3.fromRGB(24,24,24)
Instance.new("UICorner", namesBg).CornerRadius = UDim.new(0,8)
local namesScroller = Instance.new("ScrollingFrame", namesBg)
namesScroller.Size = UDim2.new(1, -12, 1, -12)
namesScroller.Position = UDim2.new(0, 6, 0, 6)
namesScroller.BackgroundTransparency = 1
namesScroller.BorderSizePixel = 0
namesScroller.AutomaticCanvasSize = Enum.AutomaticSize.Y
local namesLayout = Instance.new("UIListLayout", namesScroller)
namesLayout.Padding = UDim.new(0,6)
namesLayout.SortOrder = Enum.SortOrder.LayoutOrder
local controls = Instance.new("Frame", main)
controls.Size = UDim2.new(1, -12, 0, 36)
controls.Position = UDim2.new(0, 6, 1, -44)
controls.BackgroundTransparency = 1
local function mk_btn(parent, text, x, w)
    local b = Instance.new("TextButton", parent)
    b.Size = UDim2.new(0, w or 96, 0, 28)
    b.Position = UDim2.new(x, 0, 0, 4)
    b.Text = text
    b.Font = Enum.Font.SourceSansSemibold
    b.TextSize = 11
    b.BackgroundColor3 = Color3.fromRGB(70,70,70)
    b.TextColor3 = Color3.fromRGB(240,240,240)
    Instance.new("UICorner", b).CornerRadius = UDim.new(0,6)
    return b
end
local copyBtn = mk_btn(controls, "Copy", 0.02, 88)
local resetBtn = mk_btn(controls, "Reset", 0.26, 88)
local autoskipBtn = mk_btn(controls, "AutoSkip: OFF", 0.52, 160)
autoskipBtn.BackgroundColor3 = Color3.fromRGB(150,50,50)
local autoskipState = false
local function build_names_view()
    for _, c in ipairs(namesScroller:GetChildren()) do if not c:IsA("UIListLayout") then pcall(function() c:Destroy() end) end end
    local seen = {}
    for _, e in ipairs(_tower_logs) do
        local orig = e.t_name or "Unknown"
        if orig and orig ~= "" then seen[orig] = true end
    end
    pcall(function()
        local tf = workspace:FindFirstChild("Towers")
        if tf then
            for _, inst in ipairs(tf:GetChildren()) do
                local orig = extract_t_name(inst) or "Unknown"
                if orig and orig ~= "" then seen[orig] = true end
            end
        end
    end)
    local keys = {}
    for k in pairs(seen) do table.insert(keys,k) end
    table.sort(keys)
    if #keys == 0 then
        local lbl = Instance.new("TextLabel", namesScroller)
        lbl.Size = UDim2.new(1, -12, 0, 18)
        lbl.BackgroundTransparency = 1
        lbl.Font = Enum.Font.Code
        lbl.TextSize = 11
        lbl.TextColor3 = Color3.fromRGB(200,200,200)
        lbl.Text = "No original names detected."
        return
    end
    for _, orig in ipairs(keys) do
        local row = Instance.new("Frame", namesScroller)
        row.Size = UDim2.new(1, -12, 0, 22)
        row.BackgroundTransparency = 1
        local origLbl = Instance.new("TextLabel", row)
        origLbl.Size = UDim2.new(0.34, 0, 1, 0)
        origLbl.Position = UDim2.new(0, 0, 0, 0)
        origLbl.BackgroundTransparency = 1
        origLbl.Font = Enum.Font.Code
        origLbl.TextSize = 11
        origLbl.TextColor3 = Color3.fromRGB(200,200,200)
        origLbl.Text = orig
        local box = Instance.new("TextBox", row)
        box.Size = UDim2.new(0.44, 0, 1, 0)
        box.Position = UDim2.new(0.36, 6, 0, 0)
        box.ClearTextOnFocus = false
        box.Font = Enum.Font.Code
        box.TextSize = 11
        box.TextColor3 = Color3.fromRGB(230,230,230)
        box.BackgroundColor3 = Color3.fromRGB(36,36,36)
        box.Text = rename_map[orig] or orig
        local applyBtn = Instance.new("TextButton", row)
        applyBtn.Size = UDim2.new(0.18, -6, 1, 0)
        applyBtn.Position = UDim2.new(0.82, 6, 0, 0)
        applyBtn.Text = "Apply"
        applyBtn.Font = Enum.Font.SourceSansSemibold
        applyBtn.TextSize = 11
        applyBtn.BackgroundColor3 = Color3.fromRGB(80,80,80)
        applyBtn.TextColor3 = Color3.fromRGB(240,240,240)
        Instance.new("UICorner", applyBtn).CornerRadius = UDim.new(0,6)
        applyBtn.MouseButton1Click:Connect(function()
            local newVal = tostring(box.Text or "")
            if newVal == "" then rename_map[orig] = nil else rename_map[orig] = newVal end
            for _, entry in ipairs(_tower_logs) do
                if entry.t_name == orig then
                    local display = rename_map[orig] or orig
                    entry.text = fmt_place(display, entry.pos, entry.index)
                end
            end
            pcall(build_names_view)
            pcall(update_logs_ui)
        end)
    end
end
local function update_logs_ui()
    for _, c in ipairs(logsScroller:GetChildren()) do if not c:IsA("UIListLayout") then pcall(function() c:Destroy() end) end end
    table.sort(_tower_logs, function(a,b) return (a.time or 0) < (b.time or 0) end)
    local rightMargin = 8
    local xWidth = 28
    local gap = 6
    local upgradeWidth = 96
    local reserved = rightMargin + xWidth + gap + upgradeWidth + 8
    for i, entry in ipairs(_tower_logs) do
        local row = Instance.new("Frame")
        row.Size = UDim2.new(1, -12, 0, 24)
        row.BackgroundTransparency = 1
        row.LayoutOrder = i
        local isPlace = tostring(entry.text or ""):match("^TDS:Place")
        local labelBg = Instance.new("Frame", row)
        labelBg.Size = UDim2.new(1, -reserved, 1, 0)
        labelBg.Position = UDim2.new(0, 8, 0, 0)
        if isPlace then
            labelBg.BackgroundColor3 = Color3.fromRGB(18,48,80)
            labelBg.BackgroundTransparency = 0
            Instance.new("UICorner", labelBg).CornerRadius = UDim.new(0,6)
        else
            labelBg.BackgroundTransparency = 1
        end
        local label = Instance.new("TextLabel", labelBg)
        label.Size = UDim2.new(1, -8, 1, 0)
        label.Position = UDim2.new(0, 4, 0, 0)
        label.BackgroundTransparency = 1
        label.Font = Enum.Font.Code
        label.TextSize = 11
        label.TextColor3 = isPlace and Color3.fromRGB(220,235,250) or Color3.fromRGB(200,200,200)
        label.TextXAlignment = Enum.TextXAlignment.Left
        label.TextYAlignment = Enum.TextYAlignment.Center
        label.Text = tostring(entry.text or "")
        local delBtn = Instance.new("TextButton", row)
        delBtn.Size = UDim2.new(0, xWidth, 0, 20)
        delBtn.AnchorPoint = Vector2.new(1, 0.5)
        delBtn.Position = UDim2.new(1, -rightMargin, 0.5, 0)
        delBtn.Text = "✕"
        delBtn.Font = Enum.Font.SourceSansBold
        delBtn.TextSize = 14
        delBtn.BackgroundColor3 = Color3.fromRGB(200,60,60)
        delBtn.TextColor3 = Color3.fromRGB(255,255,255)
        Instance.new("UICorner", delBtn).CornerRadius = UDim.new(0,6)
        local upBtn = Instance.new("TextButton", row)
        upBtn.Size = UDim2.new(0, upgradeWidth, 0, 20)
        upBtn.AnchorPoint = Vector2.new(1, 0.5)
        upBtn.Position = UDim2.new(1, -rightMargin - xWidth - gap, 0.5, 0)
        upBtn.Text = "Upgrade"
        upBtn.Font = Enum.Font.SourceSansSemibold
        upBtn.TextSize = 11
        upBtn.BackgroundColor3 = Color3.fromRGB(70,120,200)
        upBtn.TextColor3 = Color3.fromRGB(240,240,240)
        Instance.new("UICorner", upBtn).CornerRadius = UDim.new(0,6)
        local linkedIndex = entry.index or get_index(entry.instance) or 0
        if not (tonumber(linkedIndex) and tonumber(linkedIndex) >= 1) then
            upBtn.Active = false
            upBtn.AutoButtonColor = false
            upBtn.BackgroundColor3 = Color3.fromRGB(90,90,90)
        end
        upBtn.MouseButton1Click:Connect(function()
            local idx = tonumber(linkedIndex)
            if not idx or idx < 1 then return end
            _G._TDS_Logger_Suppress = true
            pcall(function() if type(_G.TDS) == "table" and type(_G.TDS.Upgrade) == "function" then _G.TDS:Upgrade(idx) end end)
            _G._TDS_Logger_Suppress = false
            table.insert(_tower_logs, { text = fmt_upgrade(idx), index = idx, t_name = tostring(idx), pos = nil, time = os.time(), instance = nil })
            pcall(update_logs_ui)
        end)
        delBtn.MouseButton1Click:Connect(function()
            local found = nil
            for j,e in ipairs(_tower_logs) do if e == entry then found = j; break end end
            if not found then return end
            local idxToRemove = tonumber(entry.index or get_index(entry.instance) or 0)
            if idxToRemove and idxToRemove >= 1 then
                pcall(function() if type(_G.TDS) == "table" and type(_G.TDS.Sell) == "function" then _G.TDS:Sell(idxToRemove) end end)
                local filtered = {}
                for _, e in ipairs(_tower_logs) do
                    local txt = tostring(e.text or "")
                    local isUpgrade = txt:match("^TDS:Upgrade%(%s*"..tostring(idxToRemove).."%s*%)")
                    local isThis = (e == entry)
                    if (not isUpgrade) and (not isThis) then table.insert(filtered, e) end
                end
                _tower_logs = filtered
            else
                table.remove(_tower_logs, found)
            end
            pcall(function() _logged_towers[entry.instance] = nil end)
            pcall(update_logs_ui)
        end)
        row.Parent = logsScroller
    end
    pcall(build_names_view)
end
logsTabBtn.MouseButton1Click:Connect(function() logsFrame.Visible = true; namesFrame.Visible = false end)
namesTabBtn.MouseButton1Click:Connect(function() logsFrame.Visible = false; namesFrame.Visible = true; pcall(build_names_view) end)
copyBtn.MouseButton1Click:Connect(function()
    local parts = {"TDS Tower Logs Export", "Generated: "..os.date("%Y-%m-%d %H:%M:%S"), ""}
    for _, e in ipairs(_tower_logs) do table.insert(parts, tostring(e.text or "")) end
    local txt = table.concat(parts, "\n")
    try_clip(txt)
end)
resetBtn.MouseButton1Click:Connect(function()
    _tower_logs = {}
    _logged_towers = setmetatable({}, { __mode = "k" })
    pcall(update_logs_ui)
end)
autoskipBtn.MouseButton1Click:Connect(function()
    autoskipState = not autoskipState
    if type(_G.TDS) == "table" and type(_G.TDS.autoskip) == "function" then
        pcall(function() _G.TDS:autoskip(autoskipState) end)
    else
        _G.AutoSkip = autoskipState
    end
    autoskipBtn.Text = autoskipState and "AutoSkip: ON" or "AutoSkip: OFF"
    autoskipBtn.BackgroundColor3 = autoskipState and Color3.fromRGB(50,160,50) or Color3.fromRGB(150,50,50)
    table.insert(_tower_logs, { text = fmt_autoskip(autoskipState), index = 0, t_name = "", pos = nil, time = os.time(), instance = nil })
    pcall(update_logs_ui)
end)
do
    main.Active = true
    header.Active = true
    dragStrip.Active = true
    local dragging = false
    local dragInput = nil
    local dragStart = Vector2.new()
    local startPos = main.Position
    local function beginDrag(input)
        dragging = true
        dragInput = input
        dragStart = input.Position
        startPos = main.Position
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                dragging = false
                dragInput = nil
            end
        end)
    end
    dragStrip.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            beginDrag(input)
        end
    end)
    header.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            beginDrag(input)
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if dragging and input == dragInput and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
end
local function log_tower_once(tower)
    if not tower then return end
    local already = false
    pcall(function() already = (_logged_towers[tower] == true) end)
    if already then return end
    local idx = get_index(tower) or (#_tower_logs + 1)
    local orig = extract_t_name(tower)
    local display = rename_map[orig] or orig
    local pos = get_pos(tower)
    local line = fmt_place(display, pos, idx)
    _logged_towers[tower] = true
    table.insert(_tower_logs, { text = line, index = idx, t_name = orig, pos = pos, time = os.time(), instance = tower })
end
local function scan_tower_positions()
    pcall(function()
        local source
        if type(_G.TDS) == "table" and type(_G.TDS.placed_towers) == "table" and #_G.TDS.placed_towers > 0 then
            source = _G.TDS.placed_towers
        else
            local tf = workspace:FindFirstChild("Towers")
            source = tf and tf:GetChildren() or {}
        end
        for _, t in ipairs(source) do log_tower_once(t) end
    end)
    pcall(update_logs_ui)
end
do
    local tf = workspace:FindFirstChild("Towers")
    if tf then
        tf.ChildAdded:Connect(function(c) task.wait(0.05); log_tower_once(c); pcall(update_logs_ui) end)
    end
    workspace.ChildAdded:Connect(function(c)
        if c and c.Name == "Towers" and c:IsA("Folder") then
            c.ChildAdded:Connect(function(child) task.wait(0.05); log_tower_once(child); pcall(update_logs_ui) end)
        end
    end)
end
task.spawn(function()
    while true do
        local ok, tds = pcall(function() return _G.TDS end)
        if ok and type(tds) == "table" then
            if not tds._logger_patched then
                if type(tds.Upgrade) == "function" then
                    local orig = tds.Upgrade
                    tds.Upgrade = function(self, idx, p_id)
                        local res = { pcall(orig, self, idx, p_id) }
                        if _G._TDS_Logger_Suppress then
                            _G._TDS_Logger_Suppress = false
                        else
                            table.insert(_tower_logs, { text = fmt_upgrade(idx), index = idx or 0, t_name = tostring(idx or ""), pos = nil, time = os.time(), instance = nil })
                            pcall(update_logs_ui)
                        end
                        return unpack(res, 2)
                    end
                end
                if type(tds.Sell) == "function" then
                    local origS = tds.Sell
                    tds.Sell = function(self, idx, req)
                        local ok2, res2 = pcall(origS, self, idx, req)
                        local idxnum = tonumber(idx) or idx
                        if idxnum and idxnum >= 1 then
                            local filtered = {}
                            for _, e in ipairs(_tower_logs) do
                                local txt = tostring(e.text or "")
                                local isUpgrade = txt:match("^TDS:Upgrade%(%s*"..tostring(idxnum).."%s*%)")
                                if not isUpgrade then table.insert(filtered, e) end
                            end
                            _tower_logs = filtered
                            pcall(update_logs_ui)
                        end
                        if ok2 then return res2 end
                        return false
                    end
                end
                tds._logger_patched = true
                _G.TDS = tds
            end
            break
        end
        task.wait(0.7)
    end
end)
task.spawn(function()
    while true do
        if _auto_log_running then pcall(scan_tower_positions) end
        task.wait(_auto_log_interval)
    end
end)
task.spawn(function()
    task.wait(0.05)
    scan_tower_positions()
    pcall(update_logs_ui)
end)
_G.TDS_TowerLogger_Logs = _tower_logs
_G.TDS_TowerLogger_Renames = rename_map
_G.TDS_TowerLogger_Scan = scan_tower_positions
return _G.TDS
-- TDS_UI.lua
-- Combined TDS library + in-game command UI + placement logging
-- Place as a LocalScript (e.g., StarterPlayerScripts or StarterGui) for Roblox

-- NOTE: This script assumes a typical Tower Defense Simulator structure with:
--   - ReplicatedStorage.RemoteFunction / RemoteEvent used as in the provided library
--   - PlayerGui UI element names similar to the original script
-- The command parser supports calls of the form:
--   TDS:Place("TowerName", 0, 5, 0)
--   TDS:AutoChain(1,2,3)
--   TDS:Ability(1, "Call to Arms", nil, true)
-- Basic arg types supported: numbers, quoted strings, booleans (true/false), Vector3.new(x,y,z)
-- For simple tables or other expressions the parser will attempt loadstring if available.

-- ========== BOILERPLATE / ENV SETUP ==========
if not game:IsLoaded() then
    game.Loaded:Wait()
end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer or Players.PlayerAdded:Wait()
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

-- utility: safe request function (common exploit names)
local send_request = rawget(_G, "request") or rawget(_G, "http_request") or rawget(_G, "httprequest")
    or (rawget(_G, "GetDevice") and rawget(_G, "GetDevice")().request)

-- ========== CORE LIBRARY (merged from provided script) ==========
local TDS = {
    placed_towers = {},
    active_strat = true
}
local upgrade_history = {}
local placed_logs = {} -- for UI logging

local back_to_lobby_running = false
local auto_snowballs_running = false
local auto_skip_running = false
local anti_lag_running = false

local ItemNames = {
    ["17447507910"] = "Timescale Ticket(s)",
    ["17438486690"] = "Range Flag(s)",
    ["17438486138"] = "Damage Flag(s)",
    ["17438487774"] = "Cooldown Flag(s)",
    ["17429537022"] = "Blizzard(s)",
    ["17448596749"] = "Napalm Strike(s)",
    ["18493073533"] = "Spin Ticket(s)",
    ["17429548305"] = "Supply Drop(s)",
    ["18443277308"] = "Low Grade Consumable Crate(s)",
    ["136180382135048"] = "Santa Radio(s)",
    ["18443277106"] = "Mid Grade Consumable Crate(s)",
    ["132155797622156"] = "Christmas Tree(s)",
    ["124065875200929"] = "Fruit Cake(s)",
    ["17429541513"] = "Barricade(s)",
}

-- remote refs (may error if structure differs)
local remote_func = ReplicatedStorage:WaitForChild("RemoteFunction")
local remote_event = ReplicatedStorage:WaitForChild("RemoteEvent")

-- helper: check remote result
local function check_res_ok(data)
    if data == true then return true end
    if type(data) == "table" and data.Success == true then return true end

    local ok, is_model = pcall(function()
        return data and data:IsA and data:IsA("Model")
    end)
    if ok and is_model then return true end
    if type(data) == "userdata" then return true end

    return false
end

-- get_current_wave used by some features
local function get_current_wave()
    local ok, label = pcall(function()
        local ui = PlayerGui:FindFirstChild("ReactGameTopGameDisplay")
        return ui and ui.Frame and ui.Frame.wave and ui.Frame.wave.container and ui.Frame.wave.container.value
    end)
    if not ok or not label then return 0 end
    local wave_num = label.Text:match("^(%d+)")
    return tonumber(wave_num) or 0
end

-- DO remote calls with retries
local function invoke_with_retry(...)
    while true do
        local ok, res = pcall(remote_func.InvokeServer, remote_func, ...)
        if ok and check_res_ok(res) then return res end
        task.wait(0.25)
    end
end

local function fire_with_retry(...)
    while true do
        local ok, _
        ok, _ = pcall(remote_event.FireServer, remote_event, ...)
        if ok then return true end
        task.wait(0.25)
    end
end

-- Core tower actions (wrap remote invocation)
local function do_place_tower(t_name, t_pos)
    while true do
        local ok, res = pcall(function()
            return remote_func:InvokeServer("Troops", "Pl\208\176ce", {
                Rotation = CFrame.new(),
                Position = t_pos
            }, t_name)
        end)

        if ok and check_res_ok(res) then return true end
        task.wait(0.25)
    end
end

local function do_upgrade_tower(t_obj, path_id)
    while true do
        local ok, res = pcall(function()
            return remote_func:InvokeServer("Troops", "Upgrade", "Set", {
                Troop = t_obj,
                Path = path_id
            })
        end)
        if ok and check_res_ok(res) then return true end
        task.wait(0.25)
    end
end

local function do_sell_tower(t_obj)
    while true do
        local ok, res = pcall(function()
            return remote_func:InvokeServer("Troops", "Sell", { Troop = t_obj })
        end)
        if ok and check_res_ok(res) then return true end
        task.wait(0.25)
    end
end

local function do_set_option(t_obj, opt_name, opt_val, req_wave)
    if req_wave then
        repeat task.wait(0.3) until get_current_wave() >= req_wave
    end

    while true do
        local ok, res = pcall(function()
            return remote_func:InvokeServer("Troops", "Option", "Set", {
                Troop = t_obj,
                Name = opt_name,
                Value = opt_val
            })
        end)
        if ok and check_res_ok(res) then return true end
        task.wait(0.25)
    end
end

local function do_activate_ability(t_obj, ab_name, ab_data, is_looping)
    if type(ab_data) == "boolean" then
        is_looping = ab_data
        ab_data = nil
    end

    ab_data = type(ab_data) == "table" and ab_data or nil

    local positions
    if ab_data and type(ab_data.towerPosition) == "table" then
        positions = ab_data.towerPosition
    end

    local clone_idx = ab_data and ab_data.towerToClone
    local target_idx = ab_data and ab_data.towerTarget

    local function attempt()
        while true do
            local ok, res = pcall(function()
                local data
                if ab_data then
                    data = table.clone(ab_data)
                    if positions and #positions > 0 then
                        data.towerPosition = positions[math.random(#positions)]
                    end
                    if type(clone_idx) == "number" then
                        data.towerToClone = TDS.placed_towers[clone_idx]
                    end
                    if type(target_idx) == "number" then
                        data.towerTarget = TDS.placed_towers[target_idx]
                    end
                end

                return remote_func:InvokeServer(
                    "Troops",
                    "Abilities",
                    "Activate",
                    {
                        Troop = t_obj,
                        Name = ab_name,
                        Data = data
                    }
                )
            end)

            if ok and check_res_ok(res) then
                return true
            end

            task.wait(0.25)
        end
    end

    if is_looping then
        local active = true
        task.spawn(function()
            while active do
                attempt()
                task.wait(1)
            end
        end)
        return function() active = false end
    end

    return attempt()
end

-- Wrapper to log placements in placed_logs
local function record_place_log(t_name, px, py, pz, index)
    local line = string.format('TDS:Place("%s", %s, %s, %s) --index %d',
        tostring(t_name), tostring(px), tostring(py), tostring(pz), index)
    table.insert(placed_logs, 1, line) -- newest first
end

-- ========== PUBLIC API (TDS methods) ==========
function TDS:Place(t_name, px, py, pz)
    if not t_name then return false end
    -- ensure in-game check not strictly required
    local existing = {}
    if workspace:FindFirstChild("Towers") then
        for _, child in ipairs(workspace.Towers:GetChildren()) do
            existing[child] = true
        end
    end

    local pos = Vector3.new(px or 0, py or 0, pz or 0)
    do_place_tower(t_name, pos)

    -- find newly added tower
    local new_t
    repeat
        for _, child in ipairs(workspace.Towers:GetChildren()) do
            if not existing[child] then
                new_t = child
                break
            end
        end
        task.wait(0.05)
    until new_t

    table.insert(self.placed_towers, new_t)
    local idx = #self.placed_towers
    record_place_log(t_name, px or 0, py or 0, pz or 0, idx)
    return idx
end

function TDS:Upgrade(idx, p_id)
    local t = self.placed_towers[idx]
    if t then
        do_upgrade_tower(t, p_id or 1)
        upgrade_history[idx] = (upgrade_history[idx] or 0) + 1
    end
end

function TDS:SetTarget(idx, target_type, req_wave)
    if req_wave then
        repeat task.wait(0.5) until get_current_wave() >= req_wave
    end

    local t = self.placed_towers[idx]
    if not t then return end

    pcall(function()
        remote_func:InvokeServer("Troops", "Target", "Set", {
            Troop = t,
            Target = target_type
        })
    end)
end

function TDS:Sell(idx, req_wave)
    if req_wave then
        repeat task.wait(0.5) until get_current_wave() >= req_wave
    end
    local t = self.placed_towers[idx]
    if t and do_sell_tower(t) then
        table.remove(self.placed_towers, idx)
        return true
    end
    return false
end

function TDS:SellAll(req_wave)
    if req_wave then
        repeat task.wait(0.5) until get_current_wave() >= req_wave
    end

    local towers_copy = {unpack(self.placed_towers)}
    for idx, t in ipairs(towers_copy) do
        if do_sell_tower(t) then
            for i, orig_t in ipairs(self.placed_towers) do
                if orig_t == t then
                    table.remove(self.placed_towers, i)
                    break
                end
            end
        end
    end

    return true
end

function TDS:Ability(idx, name, data, loop)
    local t = self.placed_towers[idx]
    if not t then return false end
    return do_activate_ability(t, name, data, loop)
end

function TDS:AutoChain(...)
    local tower_indices = {...}
    if #tower_indices == 0 then return end

    local running = true

    task.spawn(function()
        local i = 1
        while running do
            local idx = tower_indices[i]
            local tower = TDS.placed_towers[idx]

            if tower then
                do_activate_ability(tower, "Call to Arms")
            end

            if LocalPlayer and LocalPlayer:FindFirstChild("TimescaleTickets") and LocalPlayer.TimescaleTickets.Value >= 1 then
                task.wait(5.5)
            else
                task.wait(10.5)
            end

            i += 1
            if i > #tower_indices then
                i = 1
            end
        end
    end)

    return function()
        running = false
    end
end

function TDS:SetOption(idx, name, val, req_wave)
    local t = self.placed_towers[idx]
    if t then
        return do_set_option(t, name, val, req_wave)
    end
    return false
end

-- Expose TDS to global so runtime console or other scripts can access if desired
_G.TDS = TDS

-- ========== SIMPLE COMMAND PARSER ==========
-- Parses "TDS:Method(arg1, arg2, ...)" and calls TDS:Method(...)
local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function split_top_level_args(s)
    local args = {}
    local cur = ""
    local depth = 0
    local in_single = false
    local in_double = false
    for i = 1, #s do
        local ch = s:sub(i,i)
        if ch == "'" and not in_double then
            in_single = not in_single
            cur = cur .. ch
        elseif ch == '"' and not in_single then
            in_double = not in_double
            cur = cur .. ch
        elseif not in_single and not in_double and (ch == "(" or ch == "{" or ch == "[") then
            depth = depth + 1
            cur = cur .. ch
        elseif not in_single and not in_double and (ch == ")" or ch == "}" or ch == "]") then
            depth = math.max(0, depth - 1)
            cur = cur .. ch
        elseif ch == "," and depth == 0 and not in_single and not in_double then
            table.insert(args, trim(cur))
            cur = ""
        else
            cur = cur .. ch
        end
    end
    if trim(cur) ~= "" then table.insert(args, trim(cur)) end
    return args
end

local function parse_arg(raw)
    raw = trim(raw)
    if raw == "" then return nil end

    -- quoted string
    local s = raw:match("^%s*\"(.*)\"%s*$") or raw:match("^%s*'(.*)'%s*$")
    if s then return s end

    -- boolean
    if raw == "true" then return true end
    if raw == "false" then return false end

    -- number
    local n = tonumber(raw)
    if n then return n end

    -- Vector3.new(x,y,z)
    local vx, vy, vz = raw:match("^%s*Vector3%.new%(%s*([%-%d%.]+)%s*,%s*([%-%d%.]+)%s*,%s*([%-%d%.]+)%s*%)%s*$")
    if vx and vy and vz then
        return Vector3.new(tonumber(vx), tonumber(vy), tonumber(vz))
    end

    -- CFrame.new(x,y,z)
    local cx, cy, cz = raw:match("^%s*CFrame%.new%(%s*([%-%d%.]+)%s*,%s*([%-%d%.]+)%s*,%s*([%-%d%.]+)%s*%)%s*$")
    if cx and cy and cz then
        return CFrame.new(tonumber(cx), tonumber(cy), tonumber(cz))
    end

    -- attempt to evaluate simple tables or expressions via loadstring (if available)
    if type(loadstring) == "function" then
        local ok, val = pcall(function()
            local f = loadstring("return " .. raw)
            if not f then return nil end
            return f()
        end)
        if ok then return val end
    end

    -- fallback: return raw text
    return raw
end

local function parse_and_run_command(cmd)
    if not cmd or cmd == "" then return false, "empty command" end
    cmd = trim(cmd)

    -- Only allow commands that start with TDS:
    local method, inside = cmd:match("^TDS:([%w_]+)%s*%((.*)%)%s*$")
    if not method then
        return false, "invalid command format. Use: TDS:Method(arg1, arg2, ...)"
    end

    -- split args top-level
    local raw_args = split_top_level_args(inside)
    local parsed_args = {}
    for _, a in ipairs(raw_args) do
        parsed_args[#parsed_args + 1] = parse_arg(a)
    end

    local fn = TDS[method]
    if type(fn) ~= "function" then
        return false, ("method TDS:%s not found"):format(method)
    end

    local ok, result = pcall(fn, TDS, table.unpack(parsed_args))
    if not ok then
        return false, ("error running TDS:%s - %s"):format(method, tostring(result))
    end

    return true, result
end

-- ========== UI: Command Input, Console & Log Tabs ==========
local function create_ui()
    -- avoid creating multiple UI instances
    local existing = PlayerGui:FindFirstChild("TDS_CommandUI")
    if existing then existing:Destroy() end

    local screen = Instance.new("ScreenGui")
    screen.Name = "TDS_CommandUI"
    screen.ResetOnSpawn = false
    screen.Parent = PlayerGui

    -- main frame
    local frame = Instance.new("Frame")
    frame.Name = "Main"
    frame.Size = UDim2.new(0, 520, 0, 360)
    frame.Position = UDim2.new(0.5, -260, 0.5, -180)
    frame.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
    frame.BorderSizePixel = 0
    frame.Parent = screen

    local uiCorner = Instance.new("UICorner", frame); uiCorner.CornerRadius = UDim.new(0, 8)

    -- header
    local header = Instance.new("TextLabel")
    header.Name = "Header"
    header.Text = "TDS Command Console"
    header.Font = Enum.Font.SourceSansBold
    header.TextSize = 20
    header.TextColor3 = Color3.fromRGB(240,240,240)
    header.BackgroundTransparency = 1
    header.Size = UDim2.new(1, -16, 0, 36)
    header.Position = UDim2.new(0, 8, 0, 8)
    header.Parent = frame

    -- Tab buttons
    local tabsFrame = Instance.new("Frame", frame)
    tabsFrame.Name = "Tabs"
    tabsFrame.BackgroundTransparency = 1
    tabsFrame.Position = UDim2.new(0, 8, 0, 48)
    tabsFrame.Size = UDim2.new(1, -16, 0, 28)

    local function makeTabButton(name, x)
        local b = Instance.new("TextButton")
        b.Name = name .. "Tab"
        b.Text = name
        b.Font = Enum.Font.SourceSans
        b.TextSize = 16
        b.TextColor3 = Color3.fromRGB(230,230,230)
        b.BackgroundColor3 = Color3.fromRGB(45,45,45)
        b.Position = UDim2.new(0, x, 0, 0)
        b.Size = UDim2.new(0, 100, 1, 0)
        b.Parent = tabsFrame
        local c = Instance.new("UICorner", b); c.CornerRadius = UDim.new(0,6)
        return b
    end

    local consoleTab = makeTabButton("Console", 0)
    local logTab = makeTabButton("Log", 110)

    -- content area
    local content = Instance.new("Frame", frame)
    content.Name = "Content"
    content.BackgroundTransparency = 1
    content.Position = UDim2.new(0, 8, 0, 84)
    content.Size = UDim2.new(1, -16, 1, -92)

    -- console view
    local consoleView = Instance.new("Frame", content)
    consoleView.Name = "ConsoleView"
    consoleView.Size = UDim2.new(1, 0, 1, 0)
    consoleView.BackgroundTransparency = 1

    local consoleOutput = Instance.new("ScrollingFrame", consoleView)
    consoleOutput.Name = "Out"
    consoleOutput.Size = UDim2.new(1, -140, 1, -44)
    consoleOutput.Position = UDim2.new(0, 0, 0, 0)
    consoleOutput.CanvasSize = UDim2.new(0, 0, 0, 0)
    consoleOutput.ScrollBarThickness = 6
    consoleOutput.BackgroundColor3 = Color3.fromRGB(28,28,28)
    consoleOutput.BorderSizePixel = 0
    local corner = Instance.new("UICorner", consoleOutput); corner.CornerRadius = UDim.new(0,6)

    local outLayout = Instance.new("UIListLayout", consoleOutput)
    outLayout.Padding = UDim.new(0, 6)
    outLayout.SortOrder = Enum.SortOrder.LayoutOrder
    outLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
        consoleOutput.CanvasSize = UDim2.new(0, 0, 0, outLayout.AbsoluteContentSize.Y + 12)
    end)

    -- right side: input & run button
    local inputBox = Instance.new("TextBox", consoleView)
    inputBox.Name = "Input"
    inputBox.PlaceholderText = 'Type command: TDS:Place("Archer", 0,5,0)'
    inputBox.ClearTextOnFocus = false
    inputBox.BackgroundColor3 = Color3.fromRGB(22,22,22)
    inputBox.TextColor3 = Color3.fromRGB(220,220,220)
    inputBox.TextWrapped = true
    inputBox.Size = UDim2.new(0, 380, 0, 36)
    inputBox.Position = UDim2.new(0, 0, 1, -44)
    local iCorner = Instance.new("UICorner", inputBox); iCorner.CornerRadius = UDim.new(0,6)
    inputBox.Font = Enum.Font.SourceSans
    inputBox.TextSize = 16

    local runBtn = Instance.new("TextButton", consoleView)
    runBtn.Name = "Run"
    runBtn.Text = "Run"
    runBtn.Font = Enum.Font.SourceSansBold
    runBtn.TextSize = 16
    runBtn.Size = UDim2.new(0, 100, 0, 36)
    runBtn.Position = UDim2.new(0, 386, 1, -44)
    runBtn.BackgroundColor3 = Color3.fromRGB(72, 132, 255)
    local rCorner = Instance.new("UICorner", runBtn); rCorner.CornerRadius = UDim.new(0,6)

    -- right side: quick help
    local helpLabel = Instance.new("TextLabel", consoleView)
    helpLabel.Name = "Help"
    helpLabel.Text = "Examples:\nTDS:Place(\"Archer\", 0, 5, 0)\nTDS:AutoChain(1,2,3)\nTDS:Ability(1, \"Call to Arms\", nil, true)"
    helpLabel.Font = Enum.Font.SourceSans
    helpLabel.TextSize = 14
    helpLabel.TextColor3 = Color3.fromRGB(200,200,200)
    helpLabel.BackgroundTransparency = 1
    helpLabel.Position = UDim2.new(0, 386, 0, 0)
    helpLabel.Size = UDim2.new(0, 120, 0, 80)
    helpLabel.TextWrapped = true

    -- Log view
    local logView = Instance.new("Frame", content)
    logView.Name = "LogView"
    logView.Size = UDim2.new(1, 0, 1, 0)
    logView.BackgroundTransparency = 1
    logView.Visible = false

    local logScrolling = Instance.new("ScrollingFrame", logView)
    logScrolling.Name = "LogScroll"
    logScrolling.Size = UDim2.new(1, 0, 1, -44)
    logScrolling.Position = UDim2.new(0, 0, 0, 0)
    logScrolling.CanvasSize = UDim2.new(0, 0, 0, 0)
    logScrolling.ScrollBarThickness = 6
    logScrolling.BackgroundColor3 = Color3.fromRGB(28,28,28)
    logScrolling.BorderSizePixel = 0
    local logCorner = Instance.new("UICorner", logScrolling); logCorner.CornerRadius = UDim.new(0,6)

    local logList = Instance.new("UIListLayout", logScrolling)
    logList.Padding = UDim.new(0, 6)
    logList.SortOrder = Enum.SortOrder.LayoutOrder
    logList:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
        logScrolling.CanvasSize = UDim2.new(0, 0, 0, logList.AbsoluteContentSize.Y + 12)
    end)

    local clearBtn = Instance.new("TextButton", logView)
    clearBtn.Name = "Clear"
    clearBtn.Text = "Clear Logs"
    clearBtn.Font = Enum.Font.SourceSansBold
    clearBtn.TextSize = 14
    clearBtn.Size = UDim2.new(0, 100, 0, 32)
    clearBtn.Position = UDim2.new(1, -110, 1, -40)
    clearBtn.BackgroundColor3 = Color3.fromRGB(200, 80, 80)
    local clearCorner = Instance.new("UICorner", clearBtn); clearCorner.CornerRadius = UDim.new(0,6)

    -- helper to append to console
    local function append_console(text, color)
        local lbl = Instance.new("TextLabel")
        lbl.BackgroundTransparency = 1
        lbl.Font = Enum.Font.SourceSans
        lbl.TextSize = 14
        lbl.TextXAlignment = Enum.TextXAlignment.Left
        lbl.TextColor3 = color or Color3.fromRGB(230,230,230)
        lbl.Size = UDim2.new(1, -12, 0, 20)
        lbl.Text = tostring(text)
        lbl.Parent = consoleOutput
    end

    -- refresh logs UI
    local function refresh_logs()
        -- clear
        for _, c in ipairs(logScrolling:GetChildren()) do
            if c:IsA("TextLabel") then c:Destroy() end
        end
        for i, line in ipairs(placed_logs) do
            local t = Instance.new("TextLabel")
            t.Text = line
            t.Font = Enum.Font.SourceSans
            t.TextSize = 14
            t.TextWrapped = true
            t.TextColor3 = Color3.fromRGB(240,240,240)
            t.BackgroundTransparency = 1
            t.Size = UDim2.new(1, -16, 0, 20)
            t.Parent = logScrolling
        end
    end

    -- Tab switching
    consoleTab.MouseButton1Click:Connect(function()
        consoleView.Visible = true
        logView.Visible = false
    end)
    logTab.MouseButton1Click:Connect(function()
        consoleView.Visible = false
        logView.Visible = true
        refresh_logs()
    end)

    -- Run button click
    runBtn.MouseButton1Click:Connect(function()
        local text = inputBox.Text
        append_console("» " .. text, Color3.fromRGB(180, 180, 255))
        local ok, res = parse_and_run_command(text)
        if ok then
            append_console("✔ Success: " .. tostring(res), Color3.fromRGB(120, 220, 120))
        else
            append_console("✖ Error: " .. tostring(res), Color3.fromRGB(240, 120, 120))
        end
        -- refresh log area if placed towers changed
        refresh_logs()
    end)

    -- Clear logs button
    clearBtn.MouseButton1Click:Connect(function()
        placed_logs = {}
        refresh_logs()
    end)

    -- make console output accessible for script-wide logging
    local function global_log(msg, color)
        append_console(msg, color)
    end

    -- initial greeting
    append_console("TDS Command UI ready. Use commands like: TDS:Place(\"Archer\", 0,5,0)", Color3.fromRGB(200,200,200))
    return {
        Append = append_console,
        RefreshLogs = refresh_logs,
        GlobalLog = global_log
    }
end

local UI = create_ui()

-- ========== OPTIONAL BACKGROUND TASKS (lightweight wrappers) ==========
-- Auto-snowballs (simplified)
local function is_void_charm(obj)
    return type(obj) == "Instance" and math.abs(obj.Position.Y) > 999999
end

local function get_root()
    local char = LocalPlayer.Character
    return char and char:FindFirstChild("HumanoidRootPart")
end

local function start_auto_snowballs()
    if auto_snowballs_running or not _G.AutoSnowballs then return end
    auto_snowballs_running = true

    task.spawn(function()
        while _G.AutoSnowballs do
            local folder = workspace:FindFirstChild("Pickups")
            local hrp = get_root()

            if folder and hrp then
                for _, item in ipairs(folder:GetChildren()) do
                    if not _G.AutoSnowballs then break end

                    if item:IsA("MeshPart") and item.Name == "SnowCharm" then
                        if not is_void_charm(item) then
                            local old_pos = hrp.CFrame
                            pcall(function()
                                hrp.CFrame = item.CFrame * CFrame.new(0, 3, 0)
                            end)
                            task.wait(0.2)
                            pcall(function()
                                hrp.CFrame = old_pos
                            end)
                            task.wait(0.3)
                        end
                    end
                end
            end

            task.wait(1)
        end

        auto_snowballs_running = false
    end)
end

-- Anti-lag (simplified)
local function start_anti_lag()
    if anti_lag_running then return end
    anti_lag_running = true

    task.spawn(function()
        while _G.AntiLag do
            local towers_folder = workspace:FindFirstChild("Towers")
            local client_units = workspace:FindFirstChild("ClientUnits")
            local enemies = workspace:FindFirstChild("NPCs")

            if towers_folder then
                for _, tower in ipairs(towers_folder:GetChildren()) do
                    local anims = tower:FindFirstChild("Animations")
                    local weapon = tower:FindFirstChild("Weapon")
                    local projectiles = tower:FindFirstChild("Projectiles")

                    if anims then pcall(function() anims:Destroy() end) end
                    if projectiles then pcall(function() projectiles:Destroy() end) end
                    if weapon then pcall(function() weapon:Destroy() end) end
                end
            end
            if client_units then
                for _, unit in ipairs(client_units:GetChildren()) do
                    pcall(function() unit:Destroy() end)
                end
            end
            if enemies then
                for _, npc in ipairs(enemies:GetChildren()) do
                    pcall(function() npc:Destroy() end)
                end
            end
            task.wait(0.5)
        end
        anti_lag_running = false
    end)
end

-- Start background features depending on global toggles
if _G.AutoSnowballs then start_auto_snowballs() end
if _G.AntiLag then start_anti_lag() end

-- Export small API for convenience
local Public = {}
Public.UI = UI
Public.TDS = TDS
Public.GetLogs = function() return placed_logs end

-- Keep script running
-- (This LocalScript will remain alive in the player; no explicit return required)
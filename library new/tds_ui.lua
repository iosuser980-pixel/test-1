-- TDS AutoStrat + In-game Console UI
-- Combined library (cleaned) + simple command console UI + Placement log tab
-- Save as .lua and run in your execution environment (exploit/runner) where game API and http functions are available.

-- WARNING: This script uses loadstring/load to execute user commands from the UI.
-- Only run trusted input. This is intended for personal automation/testing in controlled environments.

-- ====== BEGIN LIBRARY (cleaned & consolidated from provided script) ======

if not game:IsLoaded() then game.Loaded:Wait() end

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer or Players.PlayerAdded:Wait()
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local send_request = request or http_request or httprequest
    or (GetDevice and GetDevice().request)

-- basic state flags
local back_to_lobby_running = false
local auto_snowballs_running = false
local auto_skip_running = false
local anti_lag_running = false

-- helper mapping for icons -> friendly names
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

-- choose environment game state from PlayerGui presence
local function identify_game_state()
    local players = game:GetService("Players")
    local temp_player = players.LocalPlayer or players.PlayerAdded:Wait()
    local temp_gui = temp_player:WaitForChild("PlayerGui")
    
    while true do
        if temp_gui:FindFirstChild("LobbyGui") then
            return "LOBBY"
        elseif temp_gui:FindFirstChild("GameGui") then
            return "GAME"
        end
        task.wait(1)
    end
end

local game_state = identify_game_state()

-- starting currency (for webhook)
local start_coins, current_total_coins, start_gems, current_total_gems = 0, 0, 0, 0
if game_state == "GAME" then
    pcall(function()
        repeat task.wait(1) until LocalPlayer:FindFirstChild("Coins")
        start_coins = LocalPlayer.Coins.Value
        current_total_coins = start_coins
        start_gems = LocalPlayer.Gems.Value
        current_total_gems = start_gems
    end)
end

local function check_res_ok(data)
    if data == true then return true end
    if type(data) == "table" and data.Success == true then return true end

    local success, is_model = pcall(function()
        return data and data:IsA and data:IsA("Model")
    end)
    
    if success and is_model then return true end
    if type(data) == "userdata" then return true end

    return false
end

local function get_all_rewards()
    local results = {
        Coins = 0, 
        Gems = 0, 
        XP = 0, 
        Time = "00:00",
        Status = "UNKNOWN",
        Others = {} 
    }
    
    local ui_root = PlayerGui:FindFirstChild("ReactGameNewRewards")
    local main_frame = ui_root and ui_root:FindFirstChild("Frame")
    local game_over = main_frame and main_frame:FindFirstChild("gameOver")
    local rewards_screen = game_over and game_over:FindFirstChild("RewardsScreen")
    
    local game_stats = rewards_screen and rewards_screen:FindFirstChild("gameStats")
    local stats_list = game_stats and game_stats:FindFirstChild("stats")
    
    if stats_list then
        for _, frame in ipairs(stats_list:GetChildren()) do
            local l1 = frame:FindFirstChild("textLabel")
            local l2 = frame:FindFirstChild("textLabel2")
            if l1 and l2 and l1.Text:find("Time Completed:") then
                results.Time = l2.Text
                break
            end
        end
    end

    local top_banner = rewards_screen and rewards_screen:FindFirstChild("RewardBanner")
    if top_banner and top_banner:FindFirstChild("textLabel") then
        local txt = top_banner.textLabel.Text:upper()
        results.Status = txt:find("TRIUMPH") and "WIN" or (txt:find("LOST") and "LOSS" or "UNKNOWN")
    end

    local section_rewards = rewards_screen and rewards_screen:FindFirstChild("RewardsSection")
    if section_rewards then
        for _, item in ipairs(section_rewards:GetChildren()) do
            if tonumber(item.Name) then 
                local icon_id = "0"
                local img = item:FindFirstChildWhichIsA("ImageLabel", true)
                if img then icon_id = img.Image:match("%d+") or "0" end

                for _, child in ipairs(item:GetDescendants()) do
                    if child:IsA("TextLabel") then
                        local text = child.Text
                        local amt = tonumber(text:match("(%d+)")) or 0
                        
                        if text:find("Coins") then
                            results.Coins = amt
                        elseif text:find("Gems") then
                            results.Gems = amt
                        elseif text:find("XP") then
                            results.XP = amt
                        elseif text:lower():find("x%d+") then 
                            local displayName = ItemNames[icon_id] or "Unknown Item (" .. icon_id .. ")"
                            table.insert(results.Others, {Amount = text:match("x%d+"), Name = displayName})
                        end
                    end
                end
            end
        end
    end
    
    return results
end

local function send_to_lobby()
    task.wait(1)
    local lobby_remote = ReplicatedStorage:WaitForChild("Network"):WaitForChild("Teleport"):WaitForChild("RE:backToLobby")
    pcall(function() lobby_remote:FireServer() end)
end

local function handle_post_match()
    local ui_root
    repeat
        task.wait(1)

        local root = PlayerGui:FindFirstChild("ReactGameNewRewards")
        local frame = root and root:FindFirstChild("Frame")
        local gameOver = frame and frame:FindFirstChild("gameOver")
        local rewards_screen = gameOver and gameOver:FindFirstChild("RewardsScreen")
        ui_root = rewards_screen and rewards_screen:FindFirstChild("RewardsSection")
    until ui_root

    if not ui_root then return send_to_lobby() end

    if not _G.SendWebhook then
        send_to_lobby()
        return
    end

    local match = get_all_rewards()

    current_total_coins += match.Coins
    current_total_gems += match.Gems

    local bonus_string = ""
    if #match.Others > 0 then
        for _, res in ipairs(match.Others) do
            bonus_string = bonus_string .. "🎁 **" .. res.Amount .. " " .. res.Name .. "**\n"
        end
    else
        bonus_string = "_No bonus rewards found._"
    end

    local post_data = {
        username = "TDS AutoStrat",
        embeds = {{
            title = (match.Status == "WIN" and "🏆 TRIUMPH" or "💀 DEFEAT"),
            color = (match.Status == "WIN" and 0x2ecc71 or 0xe74c3c),
            description = "### 📋 Match Overview\n" ..
                          "> **Status:** `" .. match.Status .. "`\n" ..
                          "> **Time:** `" .. match.Time .. "`",
            fields = {
                {
                    name = "✨ Rewards",
                    value = "```ansi\n" ..
                            "[2;33mCoins:[0m +" .. match.Coins .. "\n" ..
                            "[2;34mGems: [0m +" .. match.Gems .. "\n" ..
                            "[2;32mXP:   [0m +" .. match.XP .. "```",
                    inline = false
                },
                {
                    name = "🎁 Bonus Items",
                    value = bonus_string,
                    inline = true
                },
                {
                    name = "📊 Session Totals",
                    value = "```py\n# Total Amount\nCoins: " .. current_total_coins .. "\nGems:  " .. current_total_gems .. "```",
                    inline = true
                }
            },
            footer = { text = "Logged for " .. LocalPlayer.Name .. " • TDS AutoStrat" },
            timestamp = DateTime.now():ToIsoDate()
        }}
    }

    pcall(function()
        send_request({
            Url = _G.Webhook,
            Method = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body = HttpService:JSONEncode(post_data)
        })
    end)

    send_to_lobby()
end

local function log_match_start()
    if not _G.SendWebhook then return end

    local start_payload = {
        username = "TDS AutoStrat",
        embeds = {{
            title = "🚀 **Match Started Successfully**",
            description = "The AutoStrat has successfully loaded into a new game session and is beginning execution.",
            color = 3447003,
            
            fields = {
                { 
                    name = "🪙 Starting Coins", 
                    value = "```" .. tostring(start_coins) .. " Coins```", 
                    inline = true 
                },
                { 
                    name = "💎 Starting Gems", 
                    value = "```" .. tostring(start_gems) .. " Gems```", 
                    inline = true 
                },
                { 
                    name = "Status", 
                    value = "🟢 Running Script", 
                    inline = false 
                }
            },
            
            footer = { text = "Logged for " .. LocalPlayer.Name .. " • TDS AutoStrat" },
            timestamp = DateTime.now():ToIsoDate()
        }}
    }

    pcall(function()
        send_request({
            Url = _G.Webhook,
            Method = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body = HttpService:JSONEncode(start_payload)
        })
    end)
end

-- Voting / map selection
local RemoteFunction = ReplicatedStorage:WaitForChild("RemoteFunction")
local RemoteEvent = ReplicatedStorage:WaitForChild("RemoteEvent")

local function run_vote_skip()
    while true do
        local ok = pcall(function()
            RemoteFunction:InvokeServer("Voting", "Skip")
        end)
        if ok then break end
        task.wait(0.2)
    end
end

local function match_ready_up()
    local player_gui = Players.LocalPlayer:WaitForChild("PlayerGui")
    
    local ui_overrides = player_gui:WaitForChild("ReactOverridesVote", 30)
    local main_frame = ui_overrides and ui_overrides:WaitForChild("Frame", 30)
    
    if not main_frame then
        return
    end

    local vote_ready = nil

    while not vote_ready do
        local vote_node = main_frame:FindFirstChild("votes")
        
        if vote_node then
            local container = vote_node:FindFirstChild("container")
            if container then
                local ready = container:FindFirstChild("ready")
                if ready then
                    vote_ready = ready
                end
            end
        end
        
        if not vote_ready then
            task.wait(0.5) 
        end
    end

    repeat task.wait(0.1) until vote_ready.Visible == true

    run_vote_skip()
    log_match_start()
end

local function cast_map_vote(map_id, pos_vec)
    local target_map = map_id or "Simplicity"
    local target_pos = pos_vec or Vector3.new(0,0,0)
    RemoteEvent:FireServer("LobbyVoting", "Vote", target_map, target_pos)
end

local function lobby_ready_up()
    pcall(function()
        RemoteEvent:FireServer("LobbyVoting", "Ready")
    end)
end

local function select_map_override(map_id)
    pcall(function()
        RemoteFunction:InvokeServer("LobbyVoting", "Override", map_id)
    end)
    task.wait(3)
    cast_map_vote(map_id, Vector3.new(12.59, 10.64, 52.01))
    task.wait(1)
    lobby_ready_up()
    match_ready_up()
end

local function cast_modifier_vote(mods_table)
    local bulk_modifiers = ReplicatedStorage:WaitForChild("Network"):WaitForChild("Modifiers"):WaitForChild("RF:BulkVoteModifiers")
    local selected_mods = mods_table or {
        HiddenEnemies = true, Glass = true, ExplodingEnemies = true,
        Limitation = true, Committed = true, HealthyEnemies = true,
        SpeedyEnemies = true, Quarantine = true, Fog = true,
        FlyingEnemies = true, Broke = true, Jailed = true, Inflation = true
    }

    pcall(function()
        bulk_modifiers:InvokeServer(selected_mods)
    end)
end

-- Timescale management
local function set_game_timescale(target_val)
    local speed_list = {0, 0.5, 1, 1.5, 2}

    local target_idx
    for i, v in ipairs(speed_list) do
        if v == target_val then
            target_idx = i
            break
        end
    end
    if not target_idx then return end

    local speed_label = Players.LocalPlayer.PlayerGui.ReactUniversalHotbar.Frame.timescale.Speed

    local current_val = tonumber(speed_label.Text:match("x([%d%.]+)"))
    if not current_val then return end

    local current_idx
    for i, v in ipairs(speed_list) do
        if v == current_val then
            current_idx = i
            break
        end
    end
    if not current_idx then return end

    local diff = target_idx - current_idx
    if diff < 0 then
        diff = #speed_list + diff
    end

    for _ = 1, diff do
        ReplicatedStorage.RemoteFunction:InvokeServer(
            "TicketsManager",
            "CycleTimeScale"
        )
        task.wait(0.5)
    end
end

local function unlock_speed_tickets()
    if LocalPlayer.TimescaleTickets.Value >= 1 then
        if Players.LocalPlayer.PlayerGui.ReactUniversalHotbar.Frame.timescale.Lock.Visible then
            ReplicatedStorage.RemoteFunction:InvokeServer('TicketsManager', 'UnlockTimeScale')
        end
    else
        warn("no tickets left")
    end
end

-- In-game control helpers
local function trigger_restart()
    local ui_root = PlayerGui:WaitForChild("ReactGameNewRewards")
    local found_section = false

    repeat
        task.wait(0.3)
        local f = ui_root:FindFirstChild("Frame")
        local g = f and f:FindFirstChild("gameOver")
        local s = g and g:FindFirstChild("RewardsScreen")
        if s and s:FindFirstChild("RewardsSection") then
            found_section = true
        end
    until found_section

    task.wait(3)
    run_vote_skip()
end

local function get_current_wave()
    local label = PlayerGui:WaitForChild("ReactGameTopGameDisplay").Frame.wave.container.value
    local wave_num = label.Text:match("^(%d+)")
    return tonumber(wave_num) or 0
end

-- Tower management core
local TDS = {
    placed_towers = {},
    active_strat = true
}
local upgrade_history = {}

local function do_place_tower(t_name, t_pos)
    while true do
        local ok, res = pcall(function()
            return RemoteFunction:InvokeServer("Troops", "Pl\208\176ce", {
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
            return RemoteFunction:InvokeServer("Troops", "Upgrade", "Set", {
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
            return RemoteFunction:InvokeServer("Troops", "Sell", { Troop = t_obj })
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
            return RemoteFunction:InvokeServer("Troops", "Option", "Set", {
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

                    -- 🎯 RANDOMIZE HERE (every attempt)
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

                return RemoteFunction:InvokeServer(
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

-- ====== LOGGING: record placed towers for UI tab ======
local PlacementLogs = {} -- { { str = "TDS:Place(...)", idx = n, ts = os.time() }, ... }

local function add_placement_log(t_name, px, py, pz, idx)
    local str = string.format('TDS:Place(%q, %s, %s, %s) --%d', tostring(t_name), tostring(px), tostring(py), tostring(pz), idx)
    table.insert(PlacementLogs, 1, { str = str, idx = idx, ts = os.time() })
    -- if there's a UI, we'll update it from outside; keep the data here
end

-- ====== PUBLIC API (TDS methods) ======
function TDS:Mode(difficulty)
    if game_state ~= "LOBBY" then 
        return false 
    end

    local lobby_hud = PlayerGui:WaitForChild("ReactLobbyHud", 30)
    local frame = lobby_hud and lobby_hud:WaitForChild("Frame", 30)
    local match_making = frame and frame:WaitForChild("matchmaking", 30)

    if match_making then
        local success = false
        repeat
            local ok, result = pcall(function()
                if difficulty == "Hardcore" then
                    return RemoteFunction:InvokeServer("Multiplayer", "v2:start", {
                        mode = "hardcore",
                        count = 1
                    })
                elseif difficulty == "Pizza Party" then
                    return RemoteFunction:InvokeServer("Multiplayer", "v2:start", {
                        mode = "halloween",
                        count = 1
                    })
                else
                    return RemoteFunction:InvokeServer("Multiplayer", "v2:start", {
                        difficulty = difficulty,
                        mode = "survival",
                        count = 1
                    })
                end
            end)

            if ok and check_res_ok(result) then
                success = true
            else
                task.wait(0.5) 
            end
        until success
    end

    return true
end

function TDS:Loadout(...)
    if game_state ~= "LOBBY" then 
        return false 
    end

    local lobby_hud = PlayerGui:WaitForChild("ReactLobbyHud", 30)
    local frame = lobby_hud and lobby_hud:WaitForChild("Frame", 30)
    local match_making = frame and frame:WaitForChild("matchmaking", 30)

    if match_making then
        local towers = {...}
        for _, tower_name in ipairs(towers) do
            if tower_name and tower_name ~= "" then
                pcall(function()
                    RemoteFunction:InvokeServer("Inventory", "Equip", "tower", tower_name)
                end)
                task.wait(0.5)
            end
        end
    end
end

function TDS:TeleportToLobby()
    send_to_lobby()
end

function TDS:VoteSkip(req_wave)
    if req_wave then
        repeat task.wait(0.5) until get_current_wave() >= req_wave
    end
    run_vote_skip()
end

function TDS:GameInfo(name, list)
    list = list or {}
    if game_state ~= "GAME" then return false end

    local vote_gui = PlayerGui:WaitForChild("ReactGameIntermission", 30)

    if vote_gui and vote_gui.Enabled and vote_gui:WaitForChild("Frame", 5) then
        cast_modifier_vote(list)
        select_map_override(name)
    end
end

function TDS:UnlockTimeScale()
    unlock_speed_tickets()
end

function TDS:TimeScale(val)
    set_game_timescale(val)
end

function TDS:StartGame()
    lobby_ready_up()
end

function TDS:Ready()
    match_ready_up()
end

function TDS:GetWave()
    return get_current_wave()
end

function TDS:RestartGame()
    trigger_restart()
end

function TDS:Place(t_name, px, py, pz)
    if game_state ~= "GAME" then
        return false 
    end
    local existing = {}
    for _, child in ipairs(Workspace:WaitForChild("Towers"):GetChildren()) do
        existing[child] = true
    end

    do_place_tower(t_name, Vector3.new(px, py, pz))

    local new_t
    repeat
        for _, child in ipairs(Workspace.Towers:GetChildren()) do
            if not existing[child] then
                new_t = child
                break
            end
        end
        task.wait(0.05)
    until new_t

    table.insert(self.placed_towers, new_t)
    local idx = #self.placed_towers

    -- add placement to logs (for UI)
    pcall(function()
        add_placement_log(t_name, px, py, pz, idx)
    end)

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
        RemoteFunction:InvokeServer("Troops", "Target", "Set", {
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

            if LocalPlayer.TimescaleTickets.Value >= 1 then
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

-- Misc utilities
local function is_void_charm(obj)
    return math.abs(obj.Position.Y) > 999999
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
            local folder = Workspace:FindFirstChild("Pickups")
            local hrp = get_root()

            if folder and hrp then
                for _, item in ipairs(folder:GetChildren()) do
                    if not _G.AutoSnowballs then break end

                    if item:IsA("MeshPart") and item.Name == "SnowCharm" then
                        if not is_void_charm(item) then
                            local old_pos = hrp.CFrame
                            hrp.CFrame = item.CFrame * CFrame.new(0, 3, 0)
                            task.wait(0.2)
                            hrp.CFrame = old_pos
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

local function start_back_to_lobby()
    if back_to_lobby_running then return end
    back_to_lobby_running = true

    task.spawn(function()
        while true do
            pcall(function()
                handle_post_match()
            end)
            task.wait(5)
        end
        back_to_lobby_running = false
    end)
end

local function start_anti_lag()
    if anti_lag_running then return end
    anti_lag_running = true

    task.spawn(function()
        while _G.AntiLag do
            local towers_folder = Workspace:FindFirstChild("Towers")
            local client_units = Workspace:FindFirstChild("ClientUnits")
            local enemies = Workspace:FindFirstChild("NPCs")

            if towers_folder then
                for _, tower in ipairs(towers_folder:GetChildren()) do
                    local anims = tower:FindFirstChild("Animations")
                    local weapon = tower:FindFirstChild("Weapon")
                    local projectiles = tower:FindFirstChild("Projectiles")
                    
                    if anims then anims:Destroy() end
                    if projectiles then projectiles:Destroy() end
                    if weapon then weapon:Destroy() end
                end
            end
            if client_units then
                for _, unit in ipairs(client_units:GetChildren()) do
                    unit:Destroy()
                end
            end
            if enemies then
                for _, npc in ipairs(enemies:GetChildren()) do
                    npc:Destroy()
                end
            end
            task.wait(0.5)
        end
        anti_lag_running = false
    end)
end

-- start background tasks based on settings
pcall(function() start_back_to_lobby() end)
pcall(function() start_auto_snowballs() end)
pcall(function() start_anti_lag() end)

-- ====== END LIBRARY ======

-- ====== UI: Console + Logs Tab ======
-- Creates a small on-screen console UI where you can type commands that run against the above TDS table.
-- Supported input examples:
--   TDS:Place("TowerName", 0, 5, 0)
--   Place("TowerName", 0, 5, 0)
--   TDS:AutoChain(1,2,3)
--   AutoChain(1,2,3)
--   TDS:Ability(1, "Name", { towerTarget = 2 }, true)
-- Notes: The console attempts a safe-ish transform to call methods on the TDS table.

-- Utilities for UI
local function create(className, props)
    local obj = Instance.new(className)
    for k,v in pairs(props or {}) do
        if k == "Parent" then
            obj.Parent = v
        else
            obj[k] = v
        end
    end
    return obj
end

-- Ensure ScreenGui parent
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "TDS_ConsoleGui"
screenGui.ResetOnSpawn = false
screenGui.Parent = PlayerGui

-- Main frame
local main = create("Frame", {
    Parent = screenGui,
    Name = "Main",
    BackgroundColor3 = Color3.fromRGB(30,30,30),
    BorderSizePixel = 0,
    Position = UDim2.new(0.01, 0, 0.12, 0),
    Size = UDim2.new(0, 420, 0, 340),
    AnchorPoint = Vector2.new(0,0),
})
create("UICorner", { Parent = main, CornerRadius = UDim.new(0,8) })

-- Title bar
local title = create("TextLabel", {
    Parent = main,
    BackgroundTransparency = 1,
    Text = "TDS Console",
    TextColor3 = Color3.fromRGB(255,255,255),
    Font = Enum.Font.SourceSansBold,
    TextSize = 18,
    Position = UDim2.new(0, 8, 0, 8),
    Size = UDim2.new(0.7, -12, 0, 24)
})
-- Close button
local closeBtn = create("TextButton", {
    Parent = main,
    BackgroundColor3 = Color3.fromRGB(200,60,60),
    Text = "X",
    TextColor3 = Color3.fromRGB(255,255,255),
    Font = Enum.Font.SourceSans,
    TextSize = 18,
    Position = UDim2.new(1, -36, 0, 8),
    Size = UDim2.new(0, 28, 0, 24),
})
create("UICorner", { Parent = closeBtn, CornerRadius = UDim.new(0,6) })

-- Tab buttons
local tabContainer = create("Frame", {
    Parent = main,
    BackgroundTransparency = 1,
    Position = UDim2.new(0,8,0,44),
    Size = UDim2.new(1,-16,0,28),
})
local consoleTabBtn = create("TextButton", {
    Parent = tabContainer, Text = "Console", BackgroundColor3 = Color3.fromRGB(50,50,50),
    TextColor3 = Color3.fromRGB(255,255,255), Font = Enum.Font.SourceSans, TextSize = 14,
    Position = UDim2.new(0,0,0,0), Size = UDim2.new(0.5,-4,1,0)
})
local logsTabBtn = create("TextButton", {
    Parent = tabContainer, Text = "Logs", BackgroundColor3 = Color3.fromRGB(45,45,45),
    TextColor3 = Color3.fromRGB(200,200,200), Font = Enum.Font.SourceSans, TextSize = 14,
    Position = UDim2.new(0.5,4,0,0), Size = UDim2.new(0.5,-4,1,0)
})
create("UICorner", { Parent = consoleTabBtn, CornerRadius = UDim.new(0,6) })
create("UICorner", { Parent = logsTabBtn, CornerRadius = UDim.new(0,6) })

-- Console frame
local consoleFrame = create("Frame", {
    Parent = main,
    BackgroundColor3 = Color3.fromRGB(20,20,20),
    Position = UDim2.new(0,8,0,80),
    Size = UDim2.new(1,-16,0,250)
})
create("UICorner", { Parent = consoleFrame, CornerRadius = UDim.new(0,6) })

-- Command input
local inputBox = create("TextBox", {
    Parent = consoleFrame,
    Name = "InputBox",
    BackgroundColor3 = Color3.fromRGB(40,40,40),
    Position = UDim2.new(0,8,0,8),
    Size = UDim2.new(1,-16,0,34),
    TextColor3 = Color3.fromRGB(230,230,230),
    Font = Enum.Font.SourceSans,
    TextSize = 16,
    ClearTextOnFocus = false,
    Text = "",
})
create("UICorner", { Parent = inputBox, CornerRadius = UDim.new(0,6) })

-- Execute / Clear
local execBtn = create("TextButton", {
    Parent = consoleFrame, Text = "Execute", BackgroundColor3 = Color3.fromRGB(60,140,60),
    TextColor3 = Color3.fromRGB(255,255,255), Font = Enum.Font.SourceSans, TextSize = 14,
    Position = UDim2.new(1,-180,0,50), Size = UDim2.new(0,80,0,28)
})
local clearBtn = create("TextButton", {
    Parent = consoleFrame, Text = "Clear", BackgroundColor3 = Color3.fromRGB(140,60,60),
    TextColor3 = Color3.fromRGB(255,255,255), Font = Enum.Font.SourceSans, TextSize = 14,
    Position = UDim2.new(1,-90,0,50), Size = UDim2.new(0,80,0,28)
})
create("UICorner", { Parent = execBtn, CornerRadius = UDim.new(0,6) })
create("UICorner", { Parent = clearBtn, CornerRadius = UDim.new(0,6) })

-- Output log (read-only)
local outputView = create("TextBox", {
    Parent = consoleFrame,
    BackgroundColor3 = Color3.fromRGB(30,30,30),
    Position = UDim2.new(0,8,0,88),
    Size = UDim2.new(1,-16,1,-96),
    TextColor3 = Color3.fromRGB(220,220,220),
    Font = Enum.Font.Code,
    TextSize = 14,
    ClearTextOnFocus = false,
    TextWrapped = true,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextYAlignment = Enum.TextYAlignment.Top,
    MultiLine = true,
    Text = "Console ready.\n",
})
create("UICorner", { Parent = outputView, CornerRadius = UDim.new(0,6) })
outputView:GetPropertyChangedSignal("Text"):Connect(function() end) -- noop to keep style

-- Logs frame (hidden by default)
local logsFrame = create("Frame", {
    Parent = main,
    BackgroundColor3 = Color3.fromRGB(18,18,18),
    Position = UDim2.new(0,8,0,80),
    Size = UDim2.new(1,-16,0,250),
    Visible = false
})
create("UICorner", { Parent = logsFrame, CornerRadius = UDim.new(0,6) })

local logsScroller = create("ScrollingFrame", {
    Parent = logsFrame,
    BackgroundColor3 = Color3.fromRGB(10,10,10),
    Position = UDim2.new(0,8,0,8),
    Size = UDim2.new(1,-16,1,-16),
    CanvasSize = UDim2.new(0,0,0,0),
    ScrollBarThickness = 8
})
create("UIListLayout", { Parent = logsScroller, Padding = UDim.new(0,4) })

-- Close button behavior
closeBtn.MouseButton1Click:Connect(function()
    screenGui:Destroy()
end)

-- Tab switching
consoleTabBtn.MouseButton1Click:Connect(function()
    consoleFrame.Visible = true
    logsFrame.Visible = false
    consoleTabBtn.BackgroundColor3 = Color3.fromRGB(50,50,50)
    logsTabBtn.BackgroundColor3 = Color3.fromRGB(45,45,45)
end)
logsTabBtn.MouseButton1Click:Connect(function()
    consoleFrame.Visible = false
    logsFrame.Visible = true
    consoleTabBtn.BackgroundColor3 = Color3.fromRGB(45,45,45)
    logsTabBtn.BackgroundColor3 = Color3.fromRGB(50,50,50)
    -- refresh logs UI
    logsScroller:ClearAllChildren()
    local layout = logsScroller:FindFirstChildOfClass("UIListLayout")
    local total = 0
    for i,entry in ipairs(PlacementLogs) do
        local lbl = create("TextLabel", {
            Parent = logsScroller,
            BackgroundTransparency = 1,
            Text = string.format("[%d] %s", entry.idx, entry.str),
            TextColor3 = Color3.fromRGB(220,220,220),
            Font = Enum.Font.SourceSans,
            TextSize = 14,
            Size = UDim2.new(1, -12, 0, 20),
            TextXAlignment = Enum.TextXAlignment.Left
        })
        total = total + 24
    end
    logsScroller.CanvasSize = UDim2.new(0,0,0, math.max(1, total))
end)

-- safe-ish command execution:
local function sanitize_and_transform(input)
    -- Trim
    input = tostring(input):gsub("^%s+", ""):gsub("%s+$", "")
    if input == "" then return nil, "empty input" end

    -- If user already typed "TDS:" use as-is
    if input:match("^%s*TDS:") then
        return "return " .. input, nil
    end

    -- If user typed "TDS." convert first dot to colon (method call)
    if input:match("^%s*TDS%.") then
        local transformed = input:gsub("^%s*TDS%.", "TDS:")
        return "return " .. transformed, nil
    end

    -- If user typed a bare method call like "Place(...)" or "AutoChain(...)", prefix with TDS:
    if input:match("^%s*[%a_][%w_]*%s*%(") then
        return "return TDS:" .. input, nil
    end

    -- If user typed "TDS" then dot property or other: return as-is but prefix return to evaluate
    if input:match("^%s*TDS") then
        return "return " .. input, nil
    end

    -- fallback: attempt to call it as expression
    return "return " .. input, nil
end

local function safe_run(code)
    -- prefer loadstring, fallback to load; bind environment with TDS and common globals
    local fn, err
    if type(loadstring) == "function" then
        fn, err = loadstring(code)
    else
        -- load in Lua 5.2+ style
        fn, err = load(code, "TDSConsole", "t", { TDS = TDS, game = game, workspace = workspace, players = Players, wait = task.wait })
        -- Note: Using load with sandboxed env only if available; in some exploit envs this will not be used.
    end

    if not fn then return false, "compile error: " .. tostring(err) end

    -- setfenv for luajit/5.1 environments if necessary
    if setfenv and type(setfenv) == "function" then
        pcall(function() setfenv(fn, setmetatable({ TDS = TDS, game = game, workspace = workspace, Players = Players }, { __index = _G })) end)
    end

    local ok, res = pcall(fn)
    if not ok then
        return false, tostring(res)
    end
    return true, res
end

local function append_output(text)
    outputView.Text = outputView.Text .. tostring(text) .. "\n"
    -- keep to bottom
    outputView.CursorPosition = #outputView.Text
end

-- Execute button logic
execBtn.MouseButton1Click:Connect(function()
    local raw = inputBox.Text
    local transformed, reason = sanitize_and_transform(raw)
    if not transformed then
        append_output("Transform error: " .. tostring(reason))
        return
    end

    append_output("> " .. raw)
    local ok, result_or_err = safe_run(transformed)
    if ok then
        append_output("=> " .. tostring(result_or_err))
    else
        append_output("ERROR: " .. tostring(result_or_err))
    end
end)

-- Clear output
clearBtn.MouseButton1Click:Connect(function()
    outputView.Text = ""
end)

-- Small helper: update logs UI when new placement log is added
-- We'll watch PlacementLogs and refresh the Logs tab only when visible
local lastLogCount = #PlacementLogs
task.spawn(function()
    while screenGui.Parent do
        if #PlacementLogs ~= lastLogCount then
            lastLogCount = #PlacementLogs
            if logsFrame.Visible then
                logsTabBtn:MouseButton1Click() -- refresh via clicking action
            end
        end
        task.wait(0.6)
    end
end)

-- Quick example buttons (optional)
local exampleFrame = create("Frame", {
    Parent = main,
    BackgroundTransparency = 1,
    Position = UDim2.new(0,8,0,328),
    Size = UDim2.new(1,-16,0,24)
})
local ex1 = create("TextButton", {
    Parent = exampleFrame, Text = "Place Example", BackgroundColor3 = Color3.fromRGB(60,60,120),
    TextColor3 = Color3.fromRGB(255,255,255), Font = Enum.Font.SourceSans, TextSize = 14,
    Position = UDim2.new(0,0,0,0), Size = UDim2.new(0,120,1,0)
})
create("UICorner", { Parent = ex1, CornerRadius = UDim.new(0,6) })
ex1.MouseButton1Click:Connect(function()
    inputBox.Text = [[Place("SimpleTower", 0, 5, 0)]]
end)

local ex2 = create("TextButton", {
    Parent = exampleFrame, Text = "AutoChain Example", BackgroundColor3 = Color3.fromRGB(60,60,120),
    TextColor3 = Color3.fromRGB(255,255,255), Font = Enum.Font.SourceSans, TextSize = 14,
    Position = UDim2.new(0,126,0,0), Size = UDim2.new(0,140,1,0)
})
create("UICorner", { Parent = ex2, CornerRadius = UDim.new(0,6) })
ex2.MouseButton1Click:Connect(function()
    inputBox.Text = [[AutoChain(1,2,3)]]
end)

-- Expose TDS and PlacementLogs to global for convenience
_G.TDS = TDS
_G.TDSPlacementLogs = PlacementLogs

append_output("TDS Console initialized. Use commands like: Place(\"Name\", x, y, z) or TDS:Place(\"Name\", x, y, z)")

-- Return TDS for module-style environments (if used as a ModuleScript)
return TDS
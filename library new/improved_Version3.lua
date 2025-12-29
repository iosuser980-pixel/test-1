if not game:IsLoaded() then game.Loaded:Wait() end

local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

local function identify_game_state()
    local players = Players
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

local send_request = request or http_request or httprequest
    or (GetDevice and GetDevice().request)

if not send_request then 
    warn("failure: no http function") 
    -- continue: UI will still work but webhook features won't
end

-- logging (available before UI so core code can log)
local _log_history = {}
local function safe_append_log(text)
    pcall(function()
        table.insert(_log_history, "[" .. os.date("%H:%M:%S") .. "] " .. tostring(text))
        if #_log_history > 400 then table.remove(_log_history, 1) end
    end)
end

local function Log(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts+1] = tostring(select(i, ...))
    end
    local msg = table.concat(parts, " ")
    print("[TDS AutoStrat] " .. msg)
    safe_append_log(msg)
end

-- main refs
local replicated_storage = ReplicatedStorage
local remote_func = replicated_storage:WaitForChild("RemoteFunction")
local remote_event = replicated_storage:WaitForChild("RemoteEvent")
local players_service = Players
local local_player = players_service.LocalPlayer or players_service.PlayerAdded:Wait()
local player_gui = local_player:WaitForChild("PlayerGui")

-- state flags & internals
local back_to_lobby_running = false
local auto_snowballs_running = false
local auto_skip_running = false
local anti_lag_running = false

-- icon item ids
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

-- currency tracking
local start_coins, current_total_coins, start_gems, current_total_gems = 0, 0, 0, 0
if game_state == "GAME" then
    pcall(function()
        repeat task.wait(1) until local_player:FindFirstChild("Coins")
        start_coins = local_player.Coins.Value
        current_total_coins = start_coins
        start_gems = local_player.Gems.Value
        current_total_gems = start_gems
    end)
end

-- helpers
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
    local results = { Coins = 0, Gems = 0, XP = 0, Time = "00:00", Status = "UNKNOWN", Others = {} }
    local ui_root = player_gui:FindFirstChild("ReactGameNewRewards")
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
    local ok, err = pcall(function()
        local lobby_remote = replicated_storage:FindFirstChild("Network") and replicated_storage.Network:FindFirstChild("Teleport") and replicated_storage.Network.Teleport["RE:backToLobby"]
        if lobby_remote then
            lobby_remote:FireServer()
            Log("Fired backToLobby remote")
        else
            Log("Lobby remote not found")
        end
    end)
    if not ok then Log("send_to_lobby err:", err) end
end

local function handle_post_match()
    local ui_root
    repeat
        task.wait(1)
        local root = player_gui:FindFirstChild("ReactGameNewRewards")
        local frame = root and root:FindFirstChild("Frame")
        local gameOver = frame and frame:FindFirstChild("gameOver")
        local rewards_screen = gameOver and gameOver:FindFirstChild("RewardsScreen")
        ui_root = rewards_screen and rewards_screen:FindFirstChild("RewardsSection")
    until ui_root

    if not ui_root then 
        Log("No rewards UI found; skipping post-match")
        return 
    end

    if not _G.SendWebhook then
        Log("SendWebhook disabled; skipping webhook")
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
                            "[2;33mCoins:[0m +" .. match.Coins .. "\n" ..
                            "[2;34mGems: [0m +" .. match.Gems .. "\n" ..
                            "[2;32mXP:   [0m +" .. match.XP .. "```",
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
            footer = { text = "Logged for " .. local_player.Name .. " • TDS AutoStrat" },
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
        Log("Posted match summary to webhook")
    end)

    send_to_lobby()
end

local function log_match_start()
    if not _G.SendWebhook then 
        Log("SendWebhook disabled; skipping match start post")
        return 
    end

    local start_payload = {
        username = "TDS AutoStrat",
        embeds = {{
            title = "🚀 **Match Started Successfully**",
            description = "The AutoStrat has successfully loaded into a new game session and is beginning execution.",
            color = 3447003,
            fields = {
                { name = "🪙 Starting Coins", value = "```" .. tostring(start_coins) .. " Coins```", inline = true },
                { name = "💎 Starting Gems", value = "```" .. tostring(start_gems) .. " Gems```", inline = true },
                { name = "Status", value = "🟢 Running Script", inline = false }
            },
            footer = { text = "Logged for " .. local_player.Name .. " • TDS AutoStrat" },
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
        Log("Posted match start to webhook")
    end)
end

local function run_vote_skip()
    Log("Attempting vote skip")
    while true do
        local success = pcall(function()
            remote_func:InvokeServer("Voting", "Skip")
        end)
        if success then 
            Log("Vote skip invoked successfully")
            break 
        end
        task.wait(0.1)
    end
end

local function match_ready_up()
    Log("Waiting for match ready UI")
    local player_gui_local = Players.LocalPlayer:WaitForChild("PlayerGui")
    local ui_overrides = player_gui_local:WaitForChild("ReactOverridesVote", 30)
    local main_frame = ui_overrides and ui_overrides:WaitForChild("Frame", 30)
    if not main_frame then
        Log("match_ready_up: UI not found")
        return
    end

    local vote_ready = nil
    while not vote_ready do
        local vote_node = main_frame:FindFirstChild("votes")
        if vote_node then
            local container = vote_node:FindFirstChild("container")
            if container then
                local ready = container:FindFirstChild("ready")
                if ready then vote_ready = ready end
            end
        end
        if not vote_ready then task.wait(0.1) end
    end

    repeat task.wait(0.1) until vote_ready.Visible == true
    run_vote_skip()
    log_match_start()
end

local function cast_map_vote(map_id, pos_vec)
    local target_map = map_id or "Simplicity"
    local target_pos = pos_vec or Vector3.new(0,0,0)
    pcall(function()
        remote_event:FireServer("LobbyVoting", "Vote", target_map, target_pos)
        Log("Cast map vote for", target_map)
    end)
end

local function lobby_ready_up()
    pcall(function()
        remote_event:FireServer("LobbyVoting", "Ready")
        Log("Lobby ready fired")
    end)
end

local function cast_modifier_vote(mods_table)
    local bulk_modifiers = replicated_storage:WaitForChild("Network"):WaitForChild("Modifiers"):WaitForChild("RF:BulkVoteModifiers")
    local selected_mods = mods_table or {
        HiddenEnemies = true, Glass = true, ExplodingEnemies = true,
        Limitation = true, Committed = true, HealthyEnemies = true,
        SpeedyEnemies = true, Quarantine = true, Fog = true,
        FlyingEnemies = true, Broke = true, Jailed = true, Inflation = true
    }
    pcall(function()
        bulk_modifiers:InvokeServer(selected_mods)
        Log("Modifiers voted")
    end)
end

local function set_game_timescale(target_val)
    local speed_list = {0, 0.5, 1, 1.5, 2}
    local target_idx
    for i, v in ipairs(speed_list) do if v == target_val then target_idx = i break end end
    if not target_idx then return end

    local speed_label = Players.LocalPlayer.PlayerGui:FindFirstChild("ReactUniversalHotbar") and Players.LocalPlayer.PlayerGui.ReactUniversalHotbar.Frame.timescale.Speed
    if not speed_label then return end

    local current_val = tonumber(speed_label.Text:match("x([%d%.]+)"))
    if not current_val then return end
    local current_idx
    for i, v in ipairs(speed_list) do if v == current_val then current_idx = i break end end
    if not current_idx then return end

    local diff = target_idx - current_idx
    if diff < 0 then diff = #speed_list + diff end

    for _ = 1, diff do
        replicated_storage.RemoteFunction:InvokeServer("TicketsManager", "CycleTimeScale")
        task.wait(0.5)
    end
    Log("Set game timescale to", target_val)
end

local function unlock_speed_tickets()
    if local_player:FindFirstChild("TimescaleTickets") and local_player.TimescaleTickets.Value >= 1 then
        local lock = Players.LocalPlayer.PlayerGui:FindFirstChild("ReactUniversalHotbar") and Players.LocalPlayer.PlayerGui.ReactUniversalHotbar.Frame.timescale.Lock
        if lock and lock.Visible then
            replicated_storage.RemoteFunction:InvokeServer('TicketsManager', 'UnlockTimeScale')
            Log("UnlockTimeScale invoked")
        end
    else
        Log("unlock_speed_tickets: no tickets left")
    end
end

local function trigger_restart()
    local ui_root = player_gui:WaitForChild("ReactGameNewRewards")
    local found_section = false
    repeat
        task.wait(0.3)
        local f = ui_root:FindFirstChild("Frame")
        local g = f and f:FindFirstChild("gameOver")
        local s = g and g:FindFirstChild("RewardsScreen")
        if s and s:FindFirstChild("RewardsSection") then found_section = true end
    until found_section
    task.wait(3)
    run_vote_skip()
end

local function get_current_wave()
    local ok, label = pcall(function()
        return player_gui:WaitForChild("ReactGameTopGameDisplay").Frame.wave.container.value
    end)
    if not ok or not label then return 0 end
    local wave_num = label.Text:match("^(%d+)")
    return tonumber(wave_num) or 0
end

-- tower management core
local TDS = { placed_towers = {}, active_strat = true }
local upgrade_history = {}

local function do_place_tower(t_name, t_pos)
    while true do
        local ok, res = pcall(function()
            return remote_func:InvokeServer("Troops", "Pl\208\176ce", { Rotation = CFrame.new(), Position = t_pos }, t_name)
        end)
        if ok and check_res_ok(res) then Log("Placed tower", t_name, t_pos); return true end
        task.wait(0.25)
    end
end

local function do_upgrade_tower(t_obj, path_id)
    while true do
        local ok, res = pcall(function()
            return remote_func:InvokeServer("Troops", "Upgrade", "Set", { Troop = t_obj, Path = path_id })
        end)
        if ok and check_res_ok(res) then Log("Upgraded tower", t_obj, "path", path_id); return true end
        task.wait(0.25)
    end
end

local function do_sell_tower(t_obj)
    while true do
        local ok, res = pcall(function()
            return remote_func:InvokeServer("Troops", "Sell", { Troop = t_obj })
        end)
        if ok and check_res_ok(res) then Log("Sold tower", t_obj); return true end
        task.wait(0.25)
    end
end

local function do_set_option(t_obj, opt_name, opt_val, req_wave)
    if req_wave then repeat task.wait(0.3) until get_current_wave() >= req_wave end
    while true do
        local ok, res = pcall(function()
            return remote_func:InvokeServer("Troops", "Option", "Set", { Troop = t_obj, Name = opt_name, Value = opt_val })
        end)
        if ok and check_res_ok(res) then Log("Set option", opt_name, "=", opt_val, "for", t_obj); return true end
        task.wait(0.25)
    end
end

local function do_activate_ability(t_obj, ab_name, ab_data, is_looping)
    if type(ab_data) == "boolean" then is_looping = ab_data; ab_data = nil end
    ab_data = type(ab_data) == "table" and ab_data or nil
    local positions = (ab_data and type(ab_data.towerPosition) == "table") and ab_data.towerPosition or nil
    local clone_idx = ab_data and ab_data.towerToClone
    local target_idx = ab_data and ab_data.towerTarget

    local function attempt()
        while true do
            local ok, res = pcall(function()
                local data
                if ab_data then
                    data = table.clone(ab_data)
                    if positions and #positions > 0 then data.towerPosition = positions[math.random(#positions)] end
                    if type(clone_idx) == "number" then data.towerToClone = TDS.placed_towers[clone_idx] end
                    if type(target_idx) == "number" then data.towerTarget = TDS.placed_towers[target_idx] end
                end
                return remote_func:InvokeServer("Troops", "Abilities", "Activate", { Troop = t_obj, Name = ab_name, Data = data })
            end)

            if ok and check_res_ok(res) then Log("Activated ability", ab_name, "for", t_obj); return true end
            task.wait(0.25)
        end
    end

    if is_looping then
        local active = true
        task.spawn(function()
            while active do attempt(); task.wait(1) end
        end)
        return function() active = false end
    end

    return attempt()
end

-- Auto Skip
local function start_auto_skip()
    if auto_skip_running or not _G.AutoSkip then return end
    auto_skip_running = true
    task.spawn(function()
        Log("AutoSkip loop started")
        while _G.AutoSkip do
            local skip_visible =
                player_gui:FindFirstChild("ReactOverridesVote")
                and player_gui.ReactOverridesVote:FindFirstChild("Frame")
                and player_gui.ReactOverridesVote.Frame:FindFirstChild("votes")
                and player_gui.ReactOverridesVote.Frame.votes:FindFirstChild("vote")

            if skip_visible and skip_visible.Position == UDim2.new(0.5, 0, 0.5, 0) then run_vote_skip() end
            task.wait(0.1)
        end
        auto_skip_running = false
        Log("AutoSkip loop stopped")
    end)
end

-- Auto Snowballs
local function is_void_charm(obj) return math.abs(obj.Position.Y) > 999999 end
local function get_root()
    local char = local_player.Character
    return char and char:FindFirstChild("HumanoidRootPart")
end

local function start_auto_snowballs()
    if auto_snowballs_running or not _G.AutoSnowballs then return end
    auto_snowballs_running = true
    task.spawn(function()
        Log("AutoSnowballs loop started")
        while _G.AutoSnowballs do
            local folder = workspace:FindFirstChild("Pickups")
            local hrp = get_root()
            if folder and hrp then
                for _, item in ipairs(folder:GetChildren()) do
                    if not _G.AutoSnowballs then break end
                    if item:IsA("MeshPart") and item.Name == "SnowCharm" and not is_void_charm(item) then
                        local old_pos = hrp.CFrame
                        hrp.CFrame = item.CFrame * CFrame.new(0, 3, 0)
                        task.wait(0.2)
                        hrp.CFrame = old_pos
                        task.wait(0.3)
                        Log("Collected SnowCharm at", tostring(item.Position))
                    end
                end
            end
            task.wait(1)
        end
        auto_snowballs_running = false
        Log("AutoSnowballs loop stopped")
    end)
end

-- Back to Lobby monitor (kept but not in UI per request)
local function start_back_to_lobby()
    if back_to_lobby_running then return end
    back_to_lobby_running = true
    task.spawn(function()
        Log("BackToLobby monitor started")
        while true do
            pcall(function() handle_post_match() end)
            task.wait(5)
        end
        back_to_lobby_running = false
    end)
end

-- Anti-lag
local function start_anti_lag()
    if anti_lag_running then return end
    anti_lag_running = true
    task.spawn(function()
        Log("AntiLag loop started")
        while _G.AntiLag do
            local towers_folder = workspace:FindFirstChild("Towers")
            local client_units = workspace:FindFirstChild("ClientUnits")
            local enemies = workspace:FindFirstChild("NPCs")

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
            if client_units then for _, unit in ipairs(client_units:GetChildren()) do unit:Destroy() end end
            if enemies then for _, npc in ipairs(enemies:GetChildren()) do npc:Destroy() end end
            task.wait(0.5)
        end
        anti_lag_running = false
        Log("AntiLag loop stopped")
    end)
end

-- TDS public API
function TDS:Mode(difficulty)
    if game_state ~= "LOBBY" then return false end
    local lobby_hud = player_gui:WaitForChild("ReactLobbyHud", 30)
    local frame = lobby_hud and lobby_hud:WaitForChild("Frame", 30)
    local match_making = frame and frame:WaitForChild("matchmaking", 30)
    if match_making then
        local remote = replicated_storage:WaitForChild("RemoteFunction")
        local success = false
        repeat
            local ok, result = pcall(function()
                if difficulty == "Hardcore" then
                    return remote:InvokeServer("Multiplayer", "v2:start", { mode = "hardcore", count = 1 })
                elseif difficulty == "Pizza Party" then
                    return remote:InvokeServer("Multiplayer", "v2:start", { mode = "halloween", count = 1 })
                else
                    return remote:InvokeServer("Multiplayer", "v2:start", { difficulty = difficulty, mode = "survival", count = 1 })
                end
            end)
            if ok and check_res_ok(result) then success = true; Log("Mode started:", difficulty) else task.wait(0.5) end
        until success
    end
    return true
end

function TDS:Loadout(...)
    if game_state ~= "LOBBY" then return false end
    local lobby_hud = player_gui:WaitForChild("ReactLobbyHud", 30)
    local frame = lobby_hud and lobby_hud:WaitForChild("Frame", 30)
    local match_making = frame and frame:WaitForChild("matchmaking", 30)
    if match_making then
        local towers = {...}
        local remote = replicated_storage:WaitForChild("RemoteFunction")
        for _, tower_name in ipairs(towers) do
            if tower_name and tower_name ~= "" then
                pcall(function() remote:InvokeServer("Inventory", "Equip", "tower", tower_name) end)
                Log("Equipped tower:", tower_name)
                task.wait(0.5)
            end
        end
    end
end

function TDS:TeleportToLobby() send_to_lobby() end
function TDS:VoteSkip(req_wave) if req_wave then repeat task.wait(0.1) until get_current_wave() >= req_wave end; run_vote_skip() end
function TDS:GameInfo(name, list) list = list or {}; if game_state ~= "GAME" then return false end; local vote_gui = player_gui:WaitForChild("ReactGameIntermission", 30); if vote_gui and vote_gui.Enabled and vote_gui:WaitForChild("Frame", 5) then cast_modifier_vote(list); select_map_override(name) end end
function TDS:UnlockTimeScale() unlock_speed_tickets() end
function TDS:TimeScale(val) set_game_timescale(val) end
function TDS:StartGame() lobby_ready_up() end
function TDS:Ready() match_ready_up() end
function TDS:GetWave() return get_current_wave() end
function TDS:RestartGame() trigger_restart() end

function TDS:Place(t_name, px, py, pz)
    if game_state ~= "GAME" then return false end
    local existing = {}
    for _, child in ipairs(workspace.Towers:GetChildren()) do existing[child] = true end
    do_place_tower(t_name, Vector3.new(px, py, pz))
    local new_t
    repeat
        for _, child in ipairs(workspace.Towers:GetChildren()) do
            if not existing[child] then new_t = child; break end
        end
        task.wait(0.05)
    until new_t
    table.insert(self.placed_towers, new_t)
    Log("Placed tower index", #self.placed_towers)
    return #self.placed_towers
end

function TDS:Upgrade(idx, p_id) local t = self.placed_towers[idx]; if t then do_upgrade_tower(t, p_id or 1); upgrade_history[idx] = (upgrade_history[idx] or 0) + 1 end end

function TDS:SetTarget(idx, target_type, req_wave)
    if req_wave then repeat task.wait(0.5) until get_current_wave() >= req_wave end
    local t = self.placed_towers[idx]; if not t then return end
    pcall(function() remote_func:InvokeServer("Troops", "Target", "Set", { Troop = t, Target = target_type }); Log("Set target for tower", idx, "to", target_type) end)
end

function TDS:Sell(idx, req_wave)
    if req_wave then repeat task.wait(0.5) until get_current_wave() >= req_wave end
    local t = self.placed_towers[idx]
    if t and do_sell_tower(t) then table.remove(self.placed_towers, idx); return true end
    return false
end

function TDS:SellAll(req_wave)
    if req_wave then repeat task.wait(0.5) until get_current_wave() >= req_wave end
    local towers_copy = {unpack(self.placed_towers)}
    for idx, t in ipairs(towers_copy) do
        if do_sell_tower(t) then
            for i, orig_t in ipairs(self.placed_towers) do
                if orig_t == t then table.remove(self.placed_towers, i); break end
            end
        end
    end
    return true
end

function TDS:Ability(idx, name, data, loop) local t = self.placed_towers[idx]; if not t then return false end; return do_activate_ability(t, name, data, loop) end

function TDS:AutoChain(...)
    local tower_indices = {...}
    if #tower_indices == 0 then return end
    local running = true
    task.spawn(function()
        local i = 1
        while running do
            local idx = tower_indices[i]
            local tower = self.placed_towers[idx]
            if tower then do_activate_ability(tower, "Call to Arms") end
            if local_player:FindFirstChild("TimescaleTickets") and local_player.TimescaleTickets.Value >= 1 then task.wait(5.5) else task.wait(10.5) end
            i += 1
            if i > #tower_indices then i = 1 end
        end
    end)
    return function() running = false end
end

function TDS:SetOption(idx, name, val, req_wave) local t = self.placed_towers[idx]; if t then return do_set_option(t, name, val, req_wave) end; return false end

function TDS:autoskip(enable)
    if enable == true then _G.AutoSkip = true; start_auto_skip(); return true
    elseif enable == false then _G.AutoSkip = false; return false
    else return _G.AutoSkip or false end
end
function TDS:AutoSkip(enable) return self:autoskip(enable) end

-- initialize globals
_G.AutoSkip = _G.AutoSkip or false
_G.AutoSnowballs = _G.AutoSnowballs or false
_G.AntiLag = _G.AntiLag or false
_G.SendWebhook = _G.SendWebhook or false
_G.BackToLobby = _G.BackToLobby == nil and true or _G.BackToLobby

-- start features if requested (BackToLobby kept running to not break behavior)
if _G.BackToLobby then start_back_to_lobby() end
if _G.AutoSkip then start_auto_skip() end
if _G.AutoSnowballs then start_auto_snowballs() end
if _G.AntiLag then start_anti_lag() end

-- =========================
-- UI (created after TDS exists so UI actions can call TDS directly)
-- =========================
local ui_root_name = "TDSAutoStratUI"
local screen_gui = player_gui:FindFirstChild(ui_root_name)
if not screen_gui then
    screen_gui = Instance.new("ScreenGui")
    screen_gui.Name = ui_root_name
    screen_gui.ResetOnSpawn = false
    screen_gui.Parent = player_gui
end

local main_frame = screen_gui:FindFirstChild("MainFrame")
if not main_frame then
    main_frame = Instance.new("Frame")
    main_frame.Name = "MainFrame"
    main_frame.Size = UDim2.new(0, 480, 0, 320)
    main_frame.Position = UDim2.new(0, 20, 0, 20)
    main_frame.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
    main_frame.BorderSizePixel = 0
    main_frame.Parent = screen_gui

    local ui_stroke = Instance.new("UIStroke", main_frame)
    ui_stroke.Color = Color3.fromRGB(50, 50, 50)
    ui_stroke.Thickness = 1

    local title = Instance.new("TextLabel")
    title.Name = "Title"
    title.Size = UDim2.new(1, -40, 0, 30)
    title.Position = UDim2.new(0, 10, 0, 5)
    title.BackgroundTransparency = 1
    title.Text = "TDS AutoStrat — Controls & Logs"
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Font = Enum.Font.SourceSansBold
    title.TextSize = 16
    title.TextColor3 = Color3.fromRGB(255,255,255)
    title.Parent = main_frame

    local minimize_btn = Instance.new("TextButton")
    minimize_btn.Name = "Minimize"
    minimize_btn.Size = UDim2.new(0, 24, 0, 24)
    minimize_btn.Position = UDim2.new(1, -30, 0, 6)
    minimize_btn.Text = "-"
    minimize_btn.Font = Enum.Font.SourceSansBold
    minimize_btn.TextSize = 18
    minimize_btn.TextColor3 = Color3.fromRGB(255,255,255)
    minimize_btn.BackgroundColor3 = Color3.fromRGB(70,70,70)
    minimize_btn.Parent = main_frame

    local tabs = Instance.new("Frame")
    tabs.Name = "Tabs"
    tabs.Size = UDim2.new(1, -10, 0, 30)
    tabs.Position = UDim2.new(0, 5, 0, 40)
    tabs.BackgroundTransparency = 1
    tabs.Parent = main_frame

    local function make_tab_button(name, x)
        local b = Instance.new("TextButton")
        b.Name = name .. "Tab"
        b.Size = UDim2.new(0, 120, 1, 0)
        b.Position = UDim2.new(0, x, 0, 0)
        b.Text = name
        b.Font = Enum.Font.SourceSansSemibold
        b.TextSize = 14
        b.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
        b.TextColor3 = Color3.fromRGB(220,220,220)
        b.Parent = tabs
        return b
    end

    local controls_tab_btn = make_tab_button("Controls", 0)
    local logs_tab_btn = make_tab_button("Logs", 130)
    local utils_tab_btn = make_tab_button("Utilities", 260)

    local controls_frame = Instance.new("Frame")
    controls_frame.Name = "ControlsFrame"
    controls_frame.Size = UDim2.new(1, -10, 1, -80)
    controls_frame.Position = UDim2.new(0, 5, 0, 75)
    controls_frame.BackgroundTransparency = 1
    controls_frame.Parent = main_frame

    local logs_frame = Instance.new("Frame")
    logs_frame.Name = "LogsFrame"
    logs_frame.Size = controls_frame.Size
    logs_frame.Position = controls_frame.Position
    logs_frame.BackgroundTransparency = 1
    logs_frame.Visible = false
    logs_frame.Parent = main_frame

    local utils_frame = Instance.new("Frame")
    utils_frame.Name = "UtilsFrame"
    utils_frame.Size = controls_frame.Size
    utils_frame.Position = controls_frame.Position
    utils_frame.BackgroundTransparency = 1
    utils_frame.Visible = false
    utils_frame.Parent = main_frame

    local separator = Instance.new("Frame")
    separator.Name = "Separator"
    separator.Size = UDim2.new(1, -10, 0, 1)
    separator.Position = UDim2.new(0, 5, 1, -45)
    separator.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
    separator.BorderSizePixel = 0
    separator.Parent = main_frame

    -- Logs
    local logs_scroller = Instance.new("ScrollingFrame")
    logs_scroller.Name = "LogsScroller"
    logs_scroller.Size = UDim2.new(1, -20, 1, -100)
    logs_scroller.Position = UDim2.new(0, 10, 0, 85)
    logs_scroller.BackgroundColor3 = Color3.fromRGB(22,22,22)
    logs_scroller.BorderSizePixel = 0
    logs_scroller.ScrollBarThickness = 6
    logs_scroller.Parent = logs_frame

    local ui_list_layout = Instance.new("UIListLayout")
    ui_list_layout.Padding = UDim.new(0, 4)
    ui_list_layout.Parent = logs_scroller

    local refresh_btn = Instance.new("TextButton")
    refresh_btn.Name = "Refresh"
    refresh_btn.Size = UDim2.new(0, 80, 0, 26)
    refresh_btn.Position = UDim2.new(1, -95, 1, -40)
    refresh_btn.Text = "Refresh"
    refresh_btn.Font = Enum.Font.SourceSans
    refresh_btn.TextSize = 13
    refresh_btn.BackgroundColor3 = Color3.fromRGB(60,60,60)
    refresh_btn.TextColor3 = Color3.fromRGB(230,230,230)
    refresh_btn.Parent = logs_frame

    refresh_btn.MouseButton1Click:Connect(function()
        for _, child in ipairs(logs_scroller:GetChildren()) do if child:IsA("TextLabel") then child:Destroy() end end
        for _, entry in ipairs(_log_history) do
            local lbl = Instance.new("TextLabel")
            lbl.Size = UDim2.new(1, -10, 0, 18)
            lbl.BackgroundTransparency = 1
            lbl.TextXAlignment = Enum.TextXAlignment.Left
            lbl.Font = Enum.Font.Code
            lbl.TextSize = 13
            lbl.TextColor3 = Color3.fromRGB(200,200,200)
            lbl.Text = entry
            lbl.Parent = logs_scroller
        end
    end)

    controls_tab_btn.MouseButton1Click:Connect(function()
        controls_frame.Visible = true; logs_frame.Visible = false; utils_frame.Visible = false
    end)
    logs_tab_btn.MouseButton1Click:Connect(function()
        controls_frame.Visible = false; logs_frame.Visible = true; utils_frame.Visible = false; refresh_btn:MouseButton1Click()
    end)
    utils_tab_btn.MouseButton1Click:Connect(function()
        controls_frame.Visible = false; logs_frame.Visible = false; utils_frame.Visible = true
    end)

    -- Minimize toggle
    local minimized = false
    local content_children = { tabs, controls_frame, logs_frame, utils_frame, separator }
    minimize_btn.MouseButton1Click:Connect(function()
        minimized = not minimized
        for _, c in ipairs(content_children) do c.Visible = not minimized end
        if minimized then main_frame.Size = UDim2.new(0, 260, 0, 40) else main_frame.Size = UDim2.new(0, 480, 0, 320) end
    end)
end

-- Make UI draggable using UserInputService (robust pattern)
do
    local dragging = false
    local dragStart = Vector2.new(0,0)
    local startPos = main_frame.Position

    main_frame.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = true
            dragStart = UserInputService:GetMouseLocation()
            startPos = main_frame.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
            local delta = UserInputService:GetMouseLocation() - dragStart
            main_frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
end

-- Controls content (toggles)
local controls_frame = main_frame:FindFirstChild("ControlsFrame")
local function make_toggle(parent, y, label_text, initial_state, on_toggle)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, -20, 0, 30)
    row.Position = UDim2.new(0, 10, 0, y)
    row.BackgroundTransparency = 1
    row.Parent = parent

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(0.7, 0, 1, 0)
    lbl.Position = UDim2.new(0, 0, 0, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text = label_text
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Font = Enum.Font.SourceSans
    lbl.TextSize = 14
    lbl.TextColor3 = Color3.fromRGB(230,230,230)
    lbl.Parent = row

    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(0.25, 0, 0.8, 0)
    btn.Position = UDim2.new(0.72, 0, 0.1, 0)
    btn.Text = initial_state and "ON" or "OFF"
    btn.Font = Enum.Font.SourceSansBold
    btn.TextSize = 13
    btn.TextColor3 = Color3.fromRGB(255,255,255)
    btn.BackgroundColor3 = initial_state and Color3.fromRGB(80,170,80) or Color3.fromRGB(150,60,60)
    btn.Parent = row

    local function set_state(s)
        btn.Text = s and "ON" or "OFF"
        btn.BackgroundColor3 = s and Color3.fromRGB(80,170,80) or Color3.fromRGB(150,60,60)
        pcall(on_toggle, s)
    end

    btn.MouseButton1Click:Connect(function()
        local new = not (btn.Text == "ON")
        set_state(new)
    end)

    return set_state
end

-- Create toggles and ensure they call start_* functions
local autoskip_set = make_toggle(controls_frame, 0, "Auto Skip (vote skip)", _G.AutoSkip, function(state)
    _G.AutoSkip = state
    if state then start_auto_skip(); Log("AutoSkip enabled via UI") else Log("AutoSkip disabled via UI") end
end)

local autosnow_set = make_toggle(controls_frame, 36, "Auto Snowballs (collect)", _G.AutoSnowballs, function(state)
    _G.AutoSnowballs = state
    if state then start_auto_snowballs(); Log("AutoSnowballs enabled via UI") else Log("AutoSnowballs disabled via UI") end
end)

local antilag_set = make_toggle(controls_frame, 72, "Anti-Lag (destroy visuals)", _G.AntiLag, function(state)
    _G.AntiLag = state
    if state then start_anti_lag(); Log("AntiLag enabled via UI") else Log("AntiLag disabled via UI") end
end)

-- initialize visuals to match current globals
autoskip_set(_G.AutoSkip)
autosnow_set(_G.AutoSnowballs)
antilag_set(_G.AntiLag)

-- Quick actions: only Force Skip
local actions_label = Instance.new("TextLabel")
actions_label.Size = UDim2.new(1, -20, 0, 20)
actions_label.Position = UDim2.new(0, 10, 0, 110)
actions_label.BackgroundTransparency = 1
actions_label.Text = "Quick Actions"
actions_label.Font = Enum.Font.SourceSansSemibold
actions_label.TextSize = 14
actions_label.TextColor3 = Color3.fromRGB(220,220,220)
actions_label.Parent = controls_frame

local function make_action_button(parent, x, text, callback)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(0, 140, 0, 28)
    b.Position = UDim2.new(0, x, 0, 136)
    b.Text = text
    b.Font = Enum.Font.SourceSans
    b.TextSize = 13
    b.BackgroundColor3 = Color3.fromRGB(70,70,70)
    b.TextColor3 = Color3.fromRGB(240,240,240)
    b.Parent = parent
    b.MouseButton1Click:Connect(function()
        local ok, err = pcall(callback)
        if not ok then Log("Action error:", err) end
    end)
end

make_action_button(controls_frame, 0, "Force Skip", function() run_vote_skip(); Log("Force Skip used") end)

-- Utilities tab: AutoChain UI
local utils_frame = main_frame:FindFirstChild("UtilsFrame")
local auto_chain_label = Instance.new("TextLabel")
auto_chain_label.Size = UDim2.new(1, -20, 0, 20)
auto_chain_label.Position = UDim2.new(0, 10, 0, 10)
auto_chain_label.BackgroundTransparency = 1
auto_chain_label.Text = "AutoChain — Enter tower indices (1–50). Examples: 1,2,3  or  1-5  or  1,3,5-8"
auto_chain_label.Font = Enum.Font.SourceSans
auto_chain_label.TextSize = 14
auto_chain_label.TextColor3 = Color3.fromRGB(220,220,220)
auto_chain_label.Parent = utils_frame

local auto_chain_box = Instance.new("TextBox")
auto_chain_box.Size = UDim2.new(1, -20, 0, 28)
auto_chain_box.Position = UDim2.new(0, 10, 0, 40)
auto_chain_box.PlaceholderText = "e.g. 1,2,3  or  1-5  or  1,3,5-8"
auto_chain_box.ClearTextOnFocus = false
auto_chain_box.Font = Enum.Font.SourceSans
auto_chain_box.TextSize = 14
auto_chain_box.BackgroundColor3 = Color3.fromRGB(40,40,40)
auto_chain_box.TextColor3 = Color3.fromRGB(230,230,230)
auto_chain_box.Parent = utils_frame

local parse_ids_label = Instance.new("TextLabel")
parse_ids_label.Size = UDim2.new(1, -20, 0, 18)
parse_ids_label.Position = UDim2.new(0, 10, 0, 74)
parse_ids_label.BackgroundTransparency = 1
parse_ids_label.Text = "Parsed IDs: (none)"
parse_ids_label.Font = Enum.Font.Code
parse_ids_label.TextSize = 13
parse_ids_label.TextColor3 = Color3.fromRGB(200,200,200)
parse_ids_label.Parent = utils_frame

local auto_chain_btn = Instance.new("TextButton")
auto_chain_btn.Size = UDim2.new(0, 120, 0, 30)
auto_chain_btn.Position = UDim2.new(0, 10, 0, 100)
auto_chain_btn.Text = "Start AutoChain"
auto_chain_btn.Font = Enum.Font.SourceSans
auto_chain_btn.TextSize = 14
auto_chain_btn.BackgroundColor3 = Color3.fromRGB(70,130,70)
auto_chain_btn.TextColor3 = Color3.fromRGB(240,240,240)
auto_chain_btn.Parent = utils_frame

local auto_chain_status = Instance.new("TextLabel")
auto_chain_status.Size = UDim2.new(1, -150, 0, 30)
auto_chain_status.Position = UDim2.new(0, 140, 0, 100)
auto_chain_status.BackgroundTransparency = 1
auto_chain_status.Text = "Status: Stopped"
auto_chain_status.Font = Enum.Font.SourceSansSemibold
auto_chain_status.TextSize = 14
auto_chain_status.TextColor3 = Color3.fromRGB(200,200,200)
auto_chain_status.TextXAlignment = Enum.TextXAlignment.Left
auto_chain_status.Parent = utils_frame

-- parse input
local function parse_id_input(str)
    if not str or str == "" then return {} end
    local parts = {}
    for token in string.gmatch(str, "[^,]+") do
        token = token:match("^%s*(.-)%s*$")
        if token:find("-") then
            local a, b = token:match("^(%d+)%s*%-%s*(%d+)$")
            if a and b then
                a = tonumber(a); b = tonumber(b)
                if a and b and a <= b then
                    for i = a, b do if i >= 1 and i <= 50 then table.insert(parts, i) end end
                end
            end
        else
            local n = tonumber(token)
            if n and n >= 1 and n <= 50 then table.insert(parts, n) end
        end
    end
    local seen = {}
    local out = {}
    for _, v in ipairs(parts) do if not seen[v] then seen[v] = true; table.insert(out, v) end end
    return out
end

local function ids_to_string(ids) if #ids == 0 then return "(none)" end; local t = {}; for _, v in ipairs(ids) do table.insert(t, tostring(v)) end; return table.concat(t, ",") end

local auto_chain_stop_func = nil
local auto_chain_running = false
local last_parsed_ids = {}

auto_chain_box.FocusLost:Connect(function(enterPressed)
    last_parsed_ids = parse_id_input(auto_chain_box.Text)
    parse_ids_label.Text = "Parsed IDs: " .. ids_to_string(last_parsed_ids)
end)

auto_chain_btn.MouseButton1Click:Connect(function()
    if not auto_chain_running then
        last_parsed_ids = parse_id_input(auto_chain_box.Text)
        if #last_parsed_ids == 0 then Log("AutoChain: no valid IDs provided"); parse_ids_label.Text = "Parsed IDs: (none)"; return end

        local ok, res = pcall(function()
            return TDS:AutoChain(table.unpack(last_parsed_ids))
        end)

        if ok then
            auto_chain_stop_func = res
            auto_chain_running = true
            auto_chain_btn.Text = "Stop AutoChain"
            auto_chain_btn.BackgroundColor3 = Color3.fromRGB(170,50,50)
            auto_chain_status.Text = "Status: Running (" .. ids_to_string(last_parsed_ids) .. ")"
            Log("AutoChain started for IDs:", ids_to_string(last_parsed_ids))
        else
            Log("AutoChain start failed:", res)
            auto_chain_status.Text = "Status: Error starting"
        end
    else
        local ok, err = pcall(function() if type(auto_chain_stop_func) == "function" then auto_chain_stop_func() end end)
        if not ok then Log("Error stopping AutoChain:", err) else Log("AutoChain stopped by user") end
        auto_chain_running = false; auto_chain_stop_func = nil
        auto_chain_btn.Text = "Start AutoChain"; auto_chain_btn.BackgroundColor3 = Color3.fromRGB(70,130,70)
        auto_chain_status.Text = "Status: Stopped"
    end
end)

-- auto-refresh logs when Logs tab visible
task.spawn(function()
    while true do
        local logs_frame = main_frame:FindFirstChild("LogsFrame")
        if logs_frame and logs_frame.Visible then
            local logs_scroller = logs_frame:FindFirstChild("LogsScroller")
            if logs_scroller then
                for _, child in ipairs(logs_scroller:GetChildren()) do if child:IsA("TextLabel") then child:Destroy() end end
                for _, entry in ipairs(_log_history) do
                    local lbl = Instance.new("TextLabel")
                    lbl.Size = UDim2.new(1, -10, 0, 18)
                    lbl.BackgroundTransparency = 1
                    lbl.TextXAlignment = Enum.TextXAlignment.Left
                    lbl.Font = Enum.Font.Code
                    lbl.TextSize = 13
                    lbl.TextColor3 = Color3.fromRGB(200,200,200)
                    lbl.Text = entry
                    lbl.Parent = logs_scroller
                end
            end
        end
        task.wait(1.5)
    end
end)

-- final: ensure UI toggles reflect runtime changes
task.spawn(function()
    while true do
        pcall(function()
            autoskip_set(_G.AutoSkip)
            autosnow_set(_G.AutoSnowballs)
            antilag_set(_G.AntiLag)
        end)
        task.wait(1)
    end
end)

return TDS
-- TowerTrackerUI.lua
-- LocalScript to run in StarterPlayerScripts or StarterGui (PlayerGui)
-- Purpose: show all towers placed (with positions px,py,pz) and upgrades (same index mapping).
-- If a previously-tracked tower is later removed, mark it as "SOLD" and log that event.
--
-- This script was written by extracting the important tower-tracking concepts
-- from the provided comparison file and implementing a focused UI + tracking system.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Utility helpers -----------------------------------------------------------
local function fmtVec3(v)
	return string.format("%.2f, %.2f, %.2f", v.X, v.Y, v.Z)
end

local function find_position_of_model(model)
	-- Prefer PrimaryPart, fallback to first BasePart descendant
	if not model then return Vector3.new(0,0,0) end
	if model.PrimaryPart and model.PrimaryPart:IsA("BasePart") then
		return model.PrimaryPart.Position
	end
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			return d.Position
		end
	end
	return Vector3.new(0,0,0)
end

local function get_upgrade_count(model)
	-- Try common conventions: NumberValue/IntValue named "Upgrade", "Upgrades", "Level"
	for _, name in ipairs({"Upgrade", "Upgrades", "Level", "Tier"}) do
		local v = model:FindFirstChild(name)
		if v and (v:IsA("NumberValue") or v:IsA("IntValue")) then
			return tonumber(v.Value) or 0
		end
	end

	-- If there's a folder called "Upgrades", use number of children
	local folder = model:FindFirstChild("Upgrades")
	if folder and folder:IsA("Folder") then
		return #folder:GetChildren()
	end

	-- Fallback: attempt to parse digits in model.Name like "Tower_x2" or "Tower (2)"
	local digits = model.Name:match("(%d+)%s*$")
	if digits then
		return tonumber(digits) or 0
	end

	-- Unknown: return 0
	return 0
end

-- UI creation ---------------------------------------------------------------
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "TowerTrackerUI"
screenGui.ResetOnSpawn = false
screenGui.DisplayOrder = 1000
screenGui.Parent = playerGui

local mainFrame = Instance.new("Frame")
mainFrame.Name = "Main"
mainFrame.Size = UDim2.new(0, 360, 0, 420)
mainFrame.Position = UDim2.new(1, -370, 0, 20)
mainFrame.AnchorPoint = Vector2.new(0, 0)
mainFrame.BackgroundColor3 = Color3.fromRGB(30,30,30)
mainFrame.BorderSizePixel = 0
mainFrame.Parent = screenGui

local uiTitle = Instance.new("TextLabel")
uiTitle.Size = UDim2.new(1, 0, 0, 28)
uiTitle.BackgroundTransparency = 1
uiTitle.Text = "Tower Tracker"
uiTitle.TextColor3 = Color3.fromRGB(255,255,255)
uiTitle.Font = Enum.Font.SourceSansBold
uiTitle.TextSize = 18
uiTitle.Parent = mainFrame

local listFrame = Instance.new("ScrollingFrame")
listFrame.Name = "List"
listFrame.Size = UDim2.new(1, -12, 1, -110)
listFrame.Position = UDim2.new(0, 6, 0, 34)
listFrame.BackgroundTransparency = 1
listFrame.BorderSizePixel = 0
listFrame.CanvasSize = UDim2.new(0,0,0,0)
listFrame.ScrollBarThickness = 6
listFrame.Parent = mainFrame

local uiLayout = Instance.new("UIListLayout")
uiLayout.Padding = UDim.new(0,6)
uiLayout.Parent = listFrame

local logTitle = Instance.new("TextLabel")
logTitle.Size = UDim2.new(1, -12, 0, 18)
logTitle.Position = UDim2.new(0, 6, 1, -70)
logTitle.BackgroundTransparency = 1
logTitle.Text = "Sold Log"
logTitle.TextColor3 = Color3.fromRGB(255,255,255)
logTitle.Font = Enum.Font.SourceSansSemibold
logTitle.TextSize = 14
logTitle.Parent = mainFrame

local soldLog = Instance.new("TextBox")
soldLog.Name = "SoldLog"
soldLog.Size = UDim2.new(1, -12, 0, 50)
soldLog.Position = UDim2.new(0, 6, 1, -52)
soldLog.TextWrapped = true
soldLog.MultiLine = true
soldLog.ClearTextOnFocus = false
soldLog.Text = ""
soldLog.TextXAlignment = Enum.TextXAlignment.Left
soldLog.TextYAlignment = Enum.TextYAlignment.Top
soldLog.BackgroundColor3 = Color3.fromRGB(20,20,20)
soldLog.TextColor3 = Color3.fromRGB(220,220,220)
soldLog.Font = Enum.Font.Code
soldLog.TextSize = 14
soldLog.Parent = mainFrame

-- Tracking state ------------------------------------------------------------
local towersFolder = workspace:WaitForChild("Towers", 5) or workspace:FindFirstChild("Towers")
if not towersFolder then
	-- If folder doesn't exist, create a watcher that waits until it exists
	local conn
	conn = workspace.ChildAdded:Connect(function(child)
		if child.Name == "Towers" then
			towersFolder = child
			conn:Disconnect()
		end
	end)
end

local tracked = {} -- model -> data { index, position, upgrades, frame, status }
local indexCounter = 0

local function make_entry_ui(data)
	local frame = Instance.new("Frame")
	frame.Size = UDim2.new(1, -8, 0, 52)
	frame.BackgroundColor3 = Color3.fromRGB(40,40,40)
	frame.BorderSizePixel = 0
	frame.Parent = listFrame

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, -8, 0, 20)
	title.Position = UDim2.new(0, 6, 0, 4)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.SourceSansBold
	title.TextSize = 14
	title.TextColor3 = Color3.fromRGB(255,255,255)
	title.Text = string.format("#%d - %s", data.index, data.name or "Tower")
	title.Parent = frame

	local posLabel = Instance.new("TextLabel")
	posLabel.Size = UDim2.new(1, -8, 0, 16)
	posLabel.Position = UDim2.new(0, 6, 0, 24)
	posLabel.BackgroundTransparency = 1
	posLabel.Font = Enum.Font.Code
	posLabel.TextSize = 13
	posLabel.TextColor3 = Color3.fromRGB(200,200,200)
	posLabel.Text = "Pos: " .. data.pos_str
	posLabel.Parent = frame

	local upgradeLabel = Instance.new("TextLabel")
	upgradeLabel.Size = UDim2.new(0.4, -8, 0, 16)
	upgradeLabel.Position = UDim2.new(0.58, 0, 0, 24)
	upgradeLabel.BackgroundTransparency = 1
	upgradeLabel.Font = Enum.Font.Code
	upgradeLabel.TextSize = 13
	upgradeLabel.TextColor3 = Color3.fromRGB(175,220,150)
	upgradeLabel.Text = "Upg: " .. tostring(data.upgrades)
	upgradeLabel.TextXAlignment = Enum.TextXAlignment.Right
	upgradeLabel.Parent = frame

	return {
		frame = frame,
		title = title,
		posLabel = posLabel,
		upgradeLabel = upgradeLabel
	}
end

local function update_canvas_size()
	local total = uiLayout.AbsoluteContentSize.Y + 12
	listFrame.CanvasSize = UDim2.new(0,0,0, total)
end

local function track_new_tower(model)
	if not model or tracked[model] then return end
	indexCounter = indexCounter + 1
	local pos = find_position_of_model(model)
	local upgrades = get_upgrade_count(model)

	local data = {
		index = indexCounter,
		model = model,
		pos = pos,
		pos_str = fmtVec3(pos),
		upgrades = upgrades,
		status = "ACTIVE",
		name = model.Name
	}

	local ui = make_entry_ui(data)
	data.ui = ui

	tracked[model] = data

	update_canvas_size()

	-- Listen for position changes (PrimaryPart moved) and upgrade changes
	spawn(function()
		-- position watcher (simple polling, inexpensive)
		local lastPos = data.pos
		while model.Parent and tracked[model] and tracked[model].status == "ACTIVE" do
			local newPos = find_position_of_model(model)
			if (newPos - lastPos).Magnitude > 0.01 then
				lastPos = newPos
				data.pos = newPos
				data.pos_str = fmtVec3(newPos)
				pcall(function()
					data.ui.posLabel.Text = "Pos: " .. data.pos_str
				end)
			end
			task.wait(0.5)
		end
	end)

	-- upgrade watcher: watch for specific Number/Int values and folder changes
	local function refresh_upgrades()
		local newCount = get_upgrade_count(model)
		if newCount ~= data.upgrades then
			data.upgrades = newCount
			pcall(function()
				data.ui.upgradeLabel.Text = "Upg: " .. tostring(newCount)
			end)
		end
	end

	local valueConns = {}
	-- watch known names
	for _, name in ipairs({"Upgrade","Upgrades","Level","Tier"}) do
		local v = model:FindFirstChild(name)
		if v and (v:IsA("NumberValue") or v:IsA("IntValue")) then
			valueConns[name] = v:GetPropertyChangedSignal("Value"):Connect(refresh_upgrades)
		end
	end

	-- watch folder child changes
	local folder = model:FindFirstChild("Upgrades")
	local folderConn
	if folder and folder:IsA("Folder") then
		folderConn = folder.ChildAdded:Connect(refresh_upgrades)
		local folderConn2 = folder.ChildRemoved:Connect(refresh_upgrades)
		valueConns["_folder_added"] = folderConn
		valueConns["_folder_removed"] = folderConn2
	end

	-- fallback: monitor model descendant added/removed (may be noisy but covers unknown cases)
	local descAdded, descRemoved
	descAdded = model.DescendantAdded:Connect(function()
		refresh_upgrades()
	end)
	descRemoved = model.DescendantRemoving and model.DescendantRemoving:Connect and model.DescendantRemoving:Connect(function()
		refresh_upgrades()
	end) or model.DescendantRemoving and model.DescendantRemoving:Connect(function()
		refresh_upgrades()
	end)

	-- store connections so we can clean up later
	data._conns = valueConns
	data._descAdded = descAdded
	data._descRemoved = descRemoved
end

local function mark_tower_sold(model)
	local data = tracked[model]
	if not data then
		-- Might be a tower removed before we tracked it; log minimal info
		local msg = string.format("[%s] Unknown tower removed", os.date("%X"))
		soldLog.Text = msg .. "\n" .. soldLog.Text
		return
	end

	-- Update UI to show sold state
	data.status = "SOLD"
	pcall(function()
		data.ui.frame.BackgroundColor3 = Color3.fromRGB(55,25,25)
		data.ui.title.Text = string.format("#%d - %s (SOLD)", data.index, data.name or "Tower")
		data.ui.upgradeLabel.TextColor3 = Color3.fromRGB(200,120,120)
	end)

	-- append to sold log (include index & position & upgrades)
	local msg = string.format("[%s] #%d - %s sold @ %s | Upgrades: %d",
		os.date("%X"), data.index, data.name or "Tower", data.pos_str, data.upgrades)
	soldLog.Text = msg .. "\n" .. soldLog.Text

	-- cleanup connections
	if data._descAdded and data._descAdded.Disconnect then pcall(function() data._descAdded:Disconnect() end) end
	if data._descRemoved and data._descRemoved.Disconnect then pcall(function() data._descRemoved:Disconnect() end) end
	if data._conns then
		for _, c in pairs(data._conns) do
			if c and c.Disconnect then
				pcall(function() c:Disconnect() end)
			end
		end
	end

	-- keep the entry visible but don't remove it (so user can see what was sold)
end

-- Initialize from existing children
if towersFolder then
	for _, child in ipairs(towersFolder:GetChildren()) do
		if child:IsA("Model") then
			track_new_tower(child)
		end
	end
end

-- Connect watchers to track add/remove
local childAddedConn
local childRemovedConn

childAddedConn = towersFolder and towersFolder.ChildAdded:Connect(function(child)
	-- Only track Models as towers
	if child and child:IsA("Model") then
		-- small delay to allow PrimaryPart to be set
		task.wait(0.05)
		track_new_tower(child)
		update_canvas_size()
	end
end)

childRemovedConn = towersFolder and towersFolder.ChildRemoved:Connect(function(child)
	-- If we had tracked it, mark sold
	if child and tracked[child] then
		mark_tower_sold(child)
	end
	update_canvas_size()
end)

-- Periodic sweep: catch cases where tower get removed from workspace but not via ChildRemoved (defensive)
spawn(function()
	while true do
		for model, data in pairs(tracked) do
			if not model.Parent or model.Parent == game nil then
				if data.status ~= "SOLD" then
					mark_tower_sold(model)
				end
			end
		end
		task.wait(2)
	end
end)

-- Small convenience: print a JSON snapshot to output on request (bind to chat command)
local function dump_snapshot()
	local out = {}
	for _, data in pairs(tracked) do
		table.insert(out, {
			index = data.index,
			name = data.name,
			pos = { x = data.pos.X, y = data.pos.Y, z = data.pos.Z },
			pos_str = data.pos_str,
			upgrades = data.upgrades,
			status = data.status
		})
	end
	print("TowerTracker snapshot:\n" .. HttpService:JSONEncode(out))
end

-- Optional: expose a simple API on player for other scripts to query
player:SetAttribute("TowerTrackerInitialized", true)
local public = {}
public.DumpSnapshot = dump_snapshot
public.GetTracked = function()
	local res = {}
	for m, d in pairs(tracked) do
		table.insert(res, d)
	end
	return res
end
-- attach to player for external access if needed
player:SetAttribute("TowerTrackerAPI", true)
-- store in a script-global (not ideal, but convenient in local environment)
_G.TowerTracker = public

-- End of script.
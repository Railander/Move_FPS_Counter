-- ingame instructions
local exitColor = "|r"
local colorOrange = "|cFFDF9F1F"
local colorRed = "|cFFFF3F1F"
local function MoveFPS_instructions()
	print(colorOrange .. "Use /movefps followed by: the desired X and Y coordinates; whether to remember the FPS toggle on/off between sessions; to print saved config." .. exitColor)
	print(colorOrange .. "Example:" .. exitColor .. " /movefps 25.7 -40")
	print(colorOrange .. "Example:" .. exitColor .. " /movefps yes")
	print(colorOrange .. "Example:" .. exitColor .. " /movefps print")
end

-- main functionality
local function MoveFPS_mover()
	FramerateLabel:ClearAllPoints()
	FramerateText:ClearAllPoints()
	FramerateLabel:SetPoint("RIGHT", UIParent, "CENTER", Move_FPS_Counter.x, Move_FPS_Counter.y)
	FramerateText:SetPoint("LEFT", FramerateLabel, "RIGHT")
end

local function MoveFPS_toggled()
	if Move_FPS_Counter.remember then
		Move_FPS_Counter.toggle = not Move_FPS_Counter.toggle
	end
end

-- persist through sessions functionality
local function MoveFPS_loaded(self, event, arg1)
	if event == "ADDON_LOADED" and arg1 == "Move_FPS_Counter" then
		if not Move_FPS_Counter then
			MoveFPS_instructions()
			Move_FPS_Counter = {
				x = 0,
				y = 0,
				remember = true,
				toggle = true,
			}
		end
		if Move_FPS_Counter.remember and Move_FPS_Counter.toggle then
			ToggleFramerate()
		end
		-- append ourselves into blizzard's frames
		hooksecurefunc("ToggleFramerate", function()
			MoveFPS_toggled()
		end)
		hooksecurefunc("ActionBarController_UpdateAll", function()
			MoveFPS_mover()
		end)
	end
end

local function MoveFPS_loadedScreen(self, event)
	MoveFPS_mover()
end

-- event triggers
local MoveFPS_AddonLoaded = CreateFrame("Frame")
MoveFPS_AddonLoaded:RegisterEvent("ADDON_LOADED")
MoveFPS_AddonLoaded:SetScript("OnEvent", MoveFPS_loaded)
local MoveFPS_ScreenLoaded = CreateFrame("Frame")
MoveFPS_ScreenLoaded:RegisterEvent("UPDATE_ALL_UI_WIDGETS")
MoveFPS_ScreenLoaded:SetScript("OnEvent", MoveFPS_loadedScreen)

EventRegistry:RegisterCallback("QueueStatusButton.OnShow", function()
	MoveFPS_mover()
end)
EventRegistry:RegisterCallback("QueueStatusButton.OnHide", function()
	MoveFPS_mover()
end)

-- slash command functionality
SLASH_MOVEFPS1 = "/movefps"
function SlashCmdList.MOVEFPS(msg, editbox)
	local msgX,msgY = string.match(msg, "^(-?%d+\.?%d?) (-?%d+\.?%d?)$")
	local msgRemember = string.match(string.upper(msg), "^YES$") or string.match(string.upper(msg), "^NO$")
	local msgPrint = string.match(string.lower(msg), "^print$")
	if msgX and msgY then
		msgX = tonumber(msgX)
		msgY = tonumber(msgY)
		Move_FPS_Counter.x,Move_FPS_Counter.y = msgX,msgY
		MoveFPS_mover()
	elseif msgRemember then
		if msgRemember == "YES" then
			Move_FPS_Counter.remember = true
		else
			Move_FPS_Counter.remember = false
		end
		MoveFPS_mover()
	elseif msgPrint then
		print(colorOrange .. "Remember: " .. exitColor .. tostring(Move_FPS_Counter.remember))
		print(colorOrange .. "Coords: " .. exitColor .. "x=" .. tostring(Move_FPS_Counter.x) .. ", y=" .. tostring(Move_FPS_Counter.y))
	else
		print(colorRed .. "Incorrect use of" .. exitColor .. " /movefps")
		MoveFPS_instructions()
	end
end
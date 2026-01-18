-- ingame instructions
local exitColor = "|r"
local colorOrange = "|cFFDF9F1F"
local colorRed = "|cFFFF3F1F"
local function MoveFPS_instructions()
	print(colorOrange .. "Use /movefps followed by: the desired X and Y coordinates; an anchor point (center or any 4 sides or 4 edges); whether to remember the FPS toggle on/off between sessions; to print saved config." .. exitColor)
	print(colorOrange .. "Example:" .. exitColor .. " /movefps 25.7 -40")
	print(colorOrange .. "Example:" .. exitColor .. " /movefps topleft")
	print(colorOrange .. "Example:" .. exitColor .. " /movefps yes")
	print(colorOrange .. "Example:" .. exitColor .. " /movefps print")
end

-- main functionality
local function MoveFPS_mover()
	FramerateFrame:ClearAllPoints()
	FramerateFrame:SetPoint(Move_FPS_Counter.anchor, UIParent, "CENTER", Move_FPS_Counter.x, Move_FPS_Counter.y)
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
				anchor = "LEFT",
			}
		end
		if Move_FPS_Counter.remember and Move_FPS_Counter.toggle then
			FramerateFrame:Toggle()
		end
		MoveFPS_mover()
		-- append ourselves into blizzard's frames
		hooksecurefunc(FramerateFrame, "Toggle", function()
			MoveFPS_toggled()
		end)
		hooksecurefunc(FramerateFrame, "UpdatePosition", function()
			MoveFPS_mover()
		end)
	end
end

-- event triggers
local MoveFPS = CreateFrame("Frame")
MoveFPS:RegisterEvent("ADDON_LOADED")
MoveFPS:SetScript("OnEvent", MoveFPS_loaded)

-- slash command functionality
SLASH_MOVEFPS1 = "/movefps"
function SlashCmdList.MOVEFPS(msg, editbox)
	local msgX,msgY = string.match(msg, "^(-?%d+\.?%d?) (-?%d+\.?%d?)$")
	local msgRemember = string.match(string.upper(msg), "^YES$") or string.match(string.upper(msg), "^NO$")
	local msgAnchors = {"CENTER", "TOP", "LEFT", "RIGHT", "BOTTOM", "TOPLEFT", "TOPRIGHT", "BOTTOMLEFT", "BOTTOMRIGHT"}
	local msgAnchor = nil
	for _,a in ipairs(msgAnchors) do
		msgAnchor = string.match(string.upper(msg), "^" .. a .. "$")
		if msgAnchor then
			break
		end
	end
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
	elseif msgAnchor then
		Move_FPS_Counter.anchor = msgAnchor
		MoveFPS_mover()
	elseif msgPrint then
		print(colorOrange .. "Remember: " .. exitColor .. tostring(Move_FPS_Counter.remember))
		print(colorOrange .. "Coords: " .. exitColor .. "x=" .. tostring(Move_FPS_Counter.x) .. ", y=" .. tostring(Move_FPS_Counter.y))
		print(colorOrange .. "Anchor: " .. exitColor .. tostring(Move_FPS_Counter.anchor))
	else
		print(colorRed .. "Incorrect use of" .. exitColor .. " /movefps")
		MoveFPS_instructions()
	end
end
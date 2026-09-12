-- Move FPS Counter
-- Moves, styles and remembers the game's default FPS counter on every version
-- of the game. One shared implementation; at load the runtime picks the flavor:
--   * modern clients: the FramerateFrame from Blizzard_FramerateFrame
--   * classic clients: the FramerateLabel/FramerateText fontstrings on WorldFrame
-- Once placed, the anchors are locked (the original methods are kept privately
-- and the region's own ones become no-ops), so no later Blizzard re-anchor, UI
-- reload pass or other addon can displace the counter. Everything is event
-- driven: no polling and no per-frame code. /movefps opens the config window
-- (with a move mode that makes the counter drag-movable), /movefps reset
-- restores the defaults.
--
-- Midnight (12.x) gate discipline, retail flavor only: there is none. Tainted
-- calls on secret-clean objects serve under any restriction state
-- (live-verified 2026-09-12 on the sibling mover, all six types forced:
-- drags, settings, strata writes, installs, all clean), and nothing this
-- addon touches can become secret-marked (it ingests no unit/combat/aura
-- data -- framerate text only; Blizzard doesn't mark chrome). So every op
-- below just attempts -- no flag checks, no mark checks, no pcall, no
-- read-back verification, no queues. If the engine ever refuses, it errors
-- LOUDLY (Bugsack, not silence), which is exactly what we want: a silent
-- queue would hide the bug forever, an error gets reported and fixed. The
-- only guards left are crash-safety (nil results abort geometry) and
-- correctness (the placed-state anchor lock, the already-there early-outs).
-- Classic flavors run the same code. Chat tutorial prints best-effort always
-- (a swallowed line under Chat lockdown is harmless -- it is never
-- load-bearing).

local ADDON_NAME = "Move_FPS_Counter";

-- ingame instructions, in the same scheme as the other Move_* addons
local exitColor = "|r";
local colorOrange = "|cFFDF9F1F";
local function MoveFPS_instructions()
	-- commands sit outside the color spans, so they render in the chat's
	-- default white while the surrounding text stays orange
	print(colorOrange .. "Use " .. exitColor .. "/movefps" .. colorOrange .. " to open the configuration window." .. exitColor);
	print(colorOrange .. "Use " .. exitColor .. "/movefps reset" .. colorOrange .. " to restore the defaults." .. exitColor);
end

local ANCHOR_LIST = { "CENTER", "TOP", "TOPRIGHT", "RIGHT", "BOTTOMRIGHT", "BOTTOM", "BOTTOMLEFT", "LEFT", "TOPLEFT" };
local ANCHORS = {};
for _, a in ipairs(ANCHOR_LIST) do
	ANCHORS[a] = true;
end
-- from the counter's center to its anchor point, in half-dimensions
local ANCHOR_DELTAS = {
	CENTER = { 0, 0 },
	TOP = { 0, 1 }, TOPRIGHT = { 1, 1 }, RIGHT = { 1, 0 }, BOTTOMRIGHT = { 1, -1 },
	BOTTOM = { 0, -1 }, BOTTOMLEFT = { -1, -1 }, LEFT = { -1, 0 }, TOPLEFT = { -1, 1 },
};

local defaults = {
	x = 0, y = 0;   -- position of the counter's anchor point, in UI units from the screen center
	anchor = "CENTER", -- which part of the counter stays put when the text width fluctuates
	placed = false,    -- false: the game's own placement is left untouched
	decimals = 1,      -- decimal places shown for the framerate, 0-2
	remember = true,   -- remember the counter's shown/hidden state
	toggle = true,     -- the remembered state itself
	win = { x = 0, y = 0 }, -- config window position, relative to screen center
	-- size is backfilled with the game's own default font size at login
};

local db; -- alias for the Move_FPS_Counter SavedVariables table, set on ADDON_LOADED
local MoveFPS_frame;        -- modern clients only: FramerateFrame as a whole
local MoveFPS_label;        -- the "FPS" label fontstring
local MoveFPS_text;         -- the number fontstring
local MoveFPS_regions = {}; -- regions whose anchors we own and keep locked
local MoveFPS_orig = {};    -- [region] = Blizzard's methods, anchors and font size
local MoveFPS_toggle;       -- the flavor's toggle for the counter's visibility
local MoveFPS_locked;       -- true while our anchors are locked in place
local options, dragProxy;   -- config window and its drag preview, created below
local RefreshWindow;        -- assigned below
local counterShownSnapshot;   -- the counter's visibility before configuring
local counterTouchedWhileOpen; -- the player toggled visibility while configuring
local MoveFPS_grabDX, MoveFPS_grabDY; -- cursor offset from the anchor point at grab time
local MoveFPS_CounterShown;   -- assigned below (used by the toggle hook)
local MoveFPS_SetCounterShown; -- assigned below

-- Install state. Declared HERE, above every function that reads or writes
-- them: Lua upvalues bind at closure creation, so a later `local` would
-- leave earlier paths writing to a same-named global instead.
local MoveFPS_stateLoaded = false; -- flavor resolved + db backfilled (pure Lua, always runs)
local MoveFPS_initDone = false; -- one-time login restore finished (measure/lock/toggle/hooks)
local MoveFPS_dragActive = false;  -- a drag gesture is in flight (OnUpdate early-returns without it)
local MoveFPS_quietVisibility = false; -- programmatic Show/Hide: don't track as a user toggle
local MoveFPS_visibilityHooked = false; -- visibility post-hooks attempted once (HookScript chains)
-- Forward declarations: assigned further below, called from early paths and
-- mid-file widget closures (bound here so they resolve correctly).
local MoveFPS_EnsureInit;
local MoveFPS_RegisterAddonEvents;
local MoveFPS_EventFrame; -- listener frame, created at file load below

local MIN_SIZE, MAX_SIZE = 1, 64;
local gameDefaultSize = 12; -- the game's own counter font size, captured at login

local function MoveFPS_Round2(v)
	return math.floor(v * 100 + 0.5) / 100;
end

local function MoveFPS_Round1(v)
	return math.floor(v * 10 + 0.5) / 10;
end

local function MoveFPS_ValidSize(n)
	return n and n >= MIN_SIZE and n <= MAX_SIZE;
end

local function MoveFPS_ValidCoord(v)
	return v and v >= -100000 and v <= 100000;
end

-- recursive default backfill; never overwrites an existing value
local function MergeDefaults(t, d)
	for k, v in pairs(d) do
		if type(v) == "table" then
			if type(t[k]) ~= "table" then
				t[k] = {};
			end
			MergeDefaults(t[k], v);
		elseif t[k] == nil then
			t[k] = v;
		end
	end
end

-- upgrade older tables: they stored the coords of the counter's anchor point,
-- which is still what x/y mean today; only the anchor point used to be fixed
-- (the old vanilla flavor hardcoded its RIGHT point, the others stored one).
-- Returns true when the table predates v2 (no placed field was ever written),
-- so the caller can greet the upgrading player
local function MoveFPS_BackfillLegacy(dbt)
	local hadPlaced = dbt.placed ~= nil;
	if not hadPlaced then
		-- v1's slash parser accepted arbitrarily large coordinates; only a
		-- stored position that is nonzero AND within the valid range counts
		-- as configured, so garbage falls back to the game's placement
		local x = MoveFPS_Round2(tonumber(dbt.x) or 0);
		local y = MoveFPS_Round2(tonumber(dbt.y) or 0);
		dbt.placed = (MoveFPS_ValidCoord(x) and x ~= 0) or (MoveFPS_ValidCoord(y) and y ~= 0);
	end
	if dbt.anchor == nil then
		if not hadPlaced and dbt.placed then
			dbt.anchor = "RIGHT"; -- old vanilla flavor placement
		else
			dbt.anchor = "CENTER";
		end
	end
	return not hadPlaced;
end

local function MoveFPS_Sanitize(dbt)
	dbt.x = MoveFPS_Round2(tonumber(dbt.x) or 0);
	dbt.y = MoveFPS_Round2(tonumber(dbt.y) or 0);
	if not MoveFPS_ValidCoord(dbt.x) then dbt.x = 0; end
	if not MoveFPS_ValidCoord(dbt.y) then dbt.y = 0; end
	if not ANCHORS[dbt.anchor] then dbt.anchor = "CENTER"; end
	dbt.size = MoveFPS_Round1(tonumber(dbt.size) or gameDefaultSize);
	if not MoveFPS_ValidSize(dbt.size) then dbt.size = gameDefaultSize; end
	dbt.decimals = math.floor(tonumber(dbt.decimals) or 1);
	if dbt.decimals < 0 or dbt.decimals > 2 then dbt.decimals = 1; end
	dbt.remember = dbt.remember and true or false;
	dbt.toggle = dbt.toggle and true or false;
	if type(dbt.win) ~= "table" then
		dbt.win = {};
	end
	dbt.win.x = MoveFPS_Round2(tonumber(dbt.win.x) or 0);
	dbt.win.y = MoveFPS_Round2(tonumber(dbt.win.y) or 0);
end

-- core behavior: every op below just attempts. A call from any path --
-- hooks, slash, options, events -- runs the same straight-line code; there
-- is no lock state, no queue, nothing to flush
-- ----------------------------------------------------------------------------

-- Placement lock (not a restriction gate): while placed, the region's own
-- anchor methods are no-ops so nothing can move the counter behind our back;
-- unplaced (never placed), it behaves exactly like the stock game.
local function MoveFPS_SetLocked(locked)
	if locked == MoveFPS_locked then
		return;
	end
	MoveFPS_locked = locked;
	for _, region in ipairs(MoveFPS_regions) do
		local orig = MoveFPS_orig[region];
		if locked then
			region.ClearAllPoints = function() end;
			region.SetPoint = function() end;
		else
			region.ClearAllPoints = orig.clear;
			region.SetPoint = orig.setPoint;
		end
	end
end

local function MoveFPS_ApplyAnchor(region, point, relativeTo, relativePoint, x, y)
	local orig = MoveFPS_orig[region];
	orig.clear(region);
	orig.setPoint(region, point, relativeTo, relativePoint, x, y);
end

local function MoveFPS_ApplyPosition()
	if db.placed then
		if MoveFPS_frame then
			MoveFPS_ApplyAnchor(MoveFPS_frame, db.anchor, UIParent, "CENTER", db.x, db.y);
		else
			MoveFPS_ApplyAnchor(MoveFPS_label, db.anchor, UIParent, "CENTER", db.x, db.y);
			MoveFPS_ApplyAnchor(MoveFPS_text, "LEFT", MoveFPS_label, "RIGHT", 0, 0);
		end
	else
		for _, region in ipairs(MoveFPS_regions) do
			local points = MoveFPS_orig[region].points;
			if points then
				MoveFPS_ApplyAnchor(region, points.point, points.relativeTo, points.relativePoint, points.x, points.y);
			end
		end
	end
end

local function MoveFPS_ApplyTextSize(region)
	if not (region and region.GetFont) then
		return;
	end
	local font, _, flags = region:GetFont();
	if font then
		region:SetFont(font, db.size, flags);
	end
end

local function MoveFPS_ApplySize()
	MoveFPS_ApplyTextSize(MoveFPS_label);
	MoveFPS_ApplyTextSize(MoveFPS_text);
end

local function MoveFPS_OnToggled()
	if not db then
		return;
	end
	if MoveFPS_quietVisibility then
		return; -- our own preview force-show/restore, never the player's state
	end
	if db.remember then
		-- store what the toggle actually did (never a blind flip: the config
		-- window's preview force-show would desync a flip counter)
		db.toggle = MoveFPS_CounterShown();
	end
	if options and options:IsShown() then
		-- the player changed visibility themselves while configuring
		counterTouchedWhileOpen = true;
	end
end

-- ----------------------------------------------------------------------------
-- config window, built on gated init inside a pcall: even if a widget template
-- is missing in some client flavor, the counter keeps working
-- ----------------------------------------------------------------------------
MoveFPS_CounterShown = function()
	if MoveFPS_frame then
		return MoveFPS_frame:IsShown();
	end
	return MoveFPS_text:IsShown();
end

MoveFPS_SetCounterShown = function(shown)
	-- Show/Hide carry no gate annotation and stay usable while protected;
	-- callers that must not count as a user toggle wrap this in the quiet flag.
	if MoveFPS_frame then
		if shown then MoveFPS_frame:Show(); else MoveFPS_frame:Hide(); end
		return;
	end
	if WorldFrame then
		-- ToggleFramerate normally resets the throttle timer; the game's
		-- OnUpdate must never read it as nil
		WorldFrame.fpsTime = 0;
	end
	if shown then
		MoveFPS_label:Show();
		MoveFPS_text:Show();
	else
		MoveFPS_label:Hide();
		MoveFPS_text:Hide();
	end
end

local function MoveFPS_MakeLabel(parent, text, fontObject, point, relativeTo, relPoint, x, y)
	local fs = parent:CreateFontString(nil, "OVERLAY");
	fs:SetFontObject(fontObject);
	fs:SetText(text);
	fs:SetPoint(point, relativeTo, relPoint, x, y);
	return fs;
end

local function MoveFPS_MakeEditBox(parent, width, maxLetters, point, relativeTo, relPoint, x, y, onEnter)
	local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate");
	box:SetSize(width, 28);
	box:SetPoint(point, relativeTo, relPoint, x, y);
	-- the compact font is load-bearing for the coordinate boxes: the Large
	-- font makes "-100.00" (the first 7-glyph value) wider than the box's
	-- visible text area, and the EditBox's scroll/caret handling then clips
	-- and misplaces the digits. At this size even "-99999.99" fits.
	box:SetFontObject("GameFontHighlight");
	if box.SetTextInsets then
		-- the search-border left cap protrudes 5px outside the frame
		box:SetTextInsets(12, 8, 6, 6); -- equal vertical insets center the text
	end
	box:SetAutoFocus(false);
	box:SetMaxLetters(maxLetters);
	box:SetJustifyH("CENTER");
	box:SetScript("OnEscapePressed", function(self)
		self:ClearFocus();
	end);
	box:SetScript("OnEnterPressed", function(self)
		self:ClearFocus();
		if db then
			onEnter(self:GetText());
		end
	end);
	return box;
end

-- offset from the counter's visual bounding-box center to its anchor point,
-- in UI units: on classic the anchor point belongs to the label while the
-- number hangs to its right, so the two centers differ
local function MoveFPS_AnchorOffset()
	local delta = ANCHOR_DELTAS[db.anchor] or ANCHOR_DELTAS.CENTER;
	if MoveFPS_frame then
		local w, h = MoveFPS_frame:GetSize();
		if w == nil or h == nil then
			return nil, nil; -- unreadable: the caller refuses the grab, never a wrong spot
		end
		return delta[1] * w / 2, delta[2] * h / 2;
	end
	local left, right = MoveFPS_label:GetLeft(), MoveFPS_text:GetRight();
	if left == nil or right == nil then
		return nil, nil;
	end
	local centerX = (left + right) / 2;
	local _, centerY = MoveFPS_label:GetCenter();
	if centerY == nil then
		return nil, nil;
	end
	local anchorX = delta[1] == 0 and centerX or (delta[1] > 0 and MoveFPS_label:GetRight() or left);
	local anchorY = delta[2] == 0 and centerY or (delta[2] > 0 and MoveFPS_label:GetTop() or MoveFPS_label:GetBottom());
	if anchorX == nil or anchorY == nil then
		return nil, nil;
	end
	return anchorX - centerX, anchorY - centerY;
end

-- real-time drag: the counter follows the cursor frame by frame. The math is
-- cursor-driven, never read back from the square: the square is anchored to
-- the counter it moves, so reading it would feed the counter's own movement
-- into the next update and run away. The OnUpdate script only exists while a
-- drag is active and is removed on release, so there is no per-frame cost
-- outside of it
local function MoveFPS_DragUpdate()
	if not db then
		return;
	end
	if not MoveFPS_dragActive then
		return; -- idle frame: cheapest possible return, no queries at all
	end
	local pw, ph = UIParent:GetSize();
	local cx, cy = GetCursorPosition(); -- already in UI units on this client
	if cx == nil or cy == nil then
		-- cursor unreadable mid-drag: end the gesture without persisting
		-- anything further (db keeps the last good spot)
		MoveFPS_dragActive = false;
		if dragProxy then
			dragProxy:SetScript("OnUpdate", nil);
		end
		return;
	end
	db.x = MoveFPS_Round2(cx - MoveFPS_grabDX - pw / 2);
	db.y = MoveFPS_Round2(cy - MoveFPS_grabDY - ph / 2);
	db.placed = true;
	MoveFPS_SetLocked(true);
	MoveFPS_ApplyPosition();
	if RefreshWindow then
		RefreshWindow(); -- the x/y boxes update live while dragging
	end
end

-- hug the counter's exact visual rectangle (label + number on classic); the
-- anchors being relative, the square follows every counter move and anchor
-- change on its own
local function MoveFPS_SyncDragProxy()
	if not (dragProxy and dragProxy:IsShown()) then
		return;
	end
	dragProxy:ClearAllPoints();
	if MoveFPS_frame then
		dragProxy:SetPoint("TOPLEFT", MoveFPS_frame, "TOPLEFT", 0, 0);
		dragProxy:SetPoint("BOTTOMRIGHT", MoveFPS_frame, "BOTTOMRIGHT", 0, 0);
	else
		dragProxy:SetPoint("LEFT", MoveFPS_label, "LEFT", 0, 0);
		dragProxy:SetPoint("RIGHT", MoveFPS_text, "RIGHT", 0, 0);
		dragProxy:SetPoint("TOP", MoveFPS_label, "TOP", 0, 0);
		dragProxy:SetPoint("BOTTOM", MoveFPS_label, "BOTTOM", 0, 0);
	end
end

-- The counter's anchor point expressed in stored-coordinate units (UIParent
-- units: what SetPoint offsets, GetCursorPosition and the x/y boxes use).
-- Rect reads cannot be converted with a fixed factor: for a region parented
-- outside UIParent (classic-era fonts live on the unscaled WorldFrame) each
-- client flavor reports Get* values with its own scale and origin. So the
-- mapping is measured instead of assumed: pin the region to two known
-- UIParent spots, read the rect back, and solve the per-axis affine mapping
-- (scale and origin, so even a flipped or offset read convention cancels).
-- Everything runs inside the calling event handler and the game's own
-- anchors are restored before returning, so nothing is rendered mid-measure.
local function MoveFPS_MeasuredAnchorU()
	local region = MoveFPS_frame or MoveFPS_label;
	local pw, ph = UIParent:GetSize();
	if pw == nil or ph == nil then
		return nil, nil;
	end
	local ox, oy = MoveFPS_AnchorOffset();
	if ox == nil or oy == nil then
		MoveFPS_ApplyPosition(); -- restore before refusing
		return nil, nil;
	end
	local gx, gy = region:GetCenter(); -- the anchor spot, in rect units
	if gx == nil or gy == nil then
		MoveFPS_ApplyPosition();
		return nil, nil;
	end
	local CAL = 100;
	MoveFPS_ApplyAnchor(region, "CENTER", UIParent, "CENTER", 0, 0);
	local k1x, k1y = region:GetCenter();
	MoveFPS_ApplyAnchor(region, "CENTER", UIParent, "CENTER", CAL, CAL);
	local k2x, k2y = region:GetCenter();
	MoveFPS_ApplyPosition(); -- back on the game's own placement
	if k1x == nil or k1y == nil or k2x == nil or k2y == nil then
		return nil, nil;
	end
	local sx = (k2x - k1x) / CAL;
	local sy = (k2y - k1y) / CAL;
	if math.abs(sx) < 1e-8 then sx = 1; end
	if math.abs(sy) < 1e-8 then sy = 1; end
	-- read = read(knownSpot) + slope * (UI - knownSpot), solved per axis
	return (gx + ox - k1x) / sx + pw / 2, (gy + oy - k1y) / sy + ph / 2;
end

-- with the counter sitting on its game placement, remember that spot as real
-- center-relative coordinates so the x/y boxes tell the truth before the
-- first move
local function MoveFPS_StoreGamePlacement()
	local ux, uy = MoveFPS_MeasuredAnchorU();
	if ux == nil or uy == nil then
		return false; -- unreadable: no box beats a wrong box
	end
	local w = UIParent:GetWidth();
	local h = UIParent:GetHeight();
	if w == nil or h == nil then
		return false;
	end
	db.x, db.y = ux - w / 2, uy - h / 2;
	return true;
end

local function MoveFPS_BuildDragProxy()
	if dragProxy then
		return;
	end
	-- The green move-mode square must render BELOW the counter's text while
	-- still receiving the drag, so it is a BACKGROUND-layer texture inside
	-- the counter's own frame hierarchy (a frame's background layer draws
	-- under its artwork fontstrings), and the drag input is a fully
	-- transparent frame stacked above the text: the text stays readable and
	-- click-through while the invisible frame catches the mouse.
	local square, inputParent;
	if MoveFPS_frame then
		square = MoveFPS_frame:CreateTexture(nil, "BACKGROUND");
		square:SetColorTexture(0, 1, 0, 0.5);
		square:SetAllPoints(MoveFPS_frame);
		inputParent = MoveFPS_frame;
	else
		square = WorldFrame:CreateTexture(nil, "BACKGROUND");
		square:SetColorTexture(0, 1, 0, 0.5);
		square:SetPoint("LEFT", MoveFPS_label, "LEFT", 0, 0);
		square:SetPoint("RIGHT", MoveFPS_text, "RIGHT", 0, 0);
		square:SetPoint("TOP", MoveFPS_label, "TOP", 0, 0);
		square:SetPoint("BOTTOM", MoveFPS_label, "BOTTOM", 0, 0);
		inputParent = WorldFrame;
	end
	dragProxy = CreateFrame("Frame", "Move_FPS_CounterDragProxy", inputParent);
	dragProxy.square = square; -- hidden and shown together with the input
	dragProxy:EnableMouse(true);
	dragProxy:RegisterForDrag("LeftButton");
	-- No StartMoving/StopMovingOrSizing anywhere: the built-in mover would
	-- fight the square's counter-relative anchors (each counter update pulled
	-- the square, each square read fed back into the counter). Instead the
	-- square is ONLY ever counter-anchored and the counter is ONLY ever
	-- cursor-driven, so there is a single control loop with nothing to fight.
	dragProxy:SetScript("OnDragStart", function(self)
		if not db then
			return;
		end
		-- capture where the cursor grabbed the square relative to the counter's
		-- anchor point. A placed counter needs no measuring at all: db already
		-- IS the anchor point's position in UI units, so the grab is exact and
		-- the counter cannot jump by a single pixel, whatever the ui scale.
		local cx, cy = GetCursorPosition(); -- already in UI units on this client
		if cx == nil or cy == nil then
			return; -- cursor unreadable: refuse the grab without touching anything
		end
		local pw, ph = UIParent:GetSize();
		if pw == nil or ph == nil then
			return;
		end
		local ax, ay;
		if db.placed then
			ax, ay = pw / 2 + db.x, ph / 2 + db.y;
		else
			-- first placement: measure the game-default spot once, in stored-
			-- coordinate units, so the counter is re-anchored exactly where it
			-- sits and only ever follows the cursor from there
			ax, ay = MoveFPS_MeasuredAnchorU();
			if ax == nil or ay == nil then
				return; -- unmeasurable: no grab beats a displacing grab
			end
		end
		MoveFPS_grabDX = cx - ax;
		MoveFPS_grabDY = cy - ay;
		MoveFPS_dragActive = true;
		self:SetScript("OnUpdate", function() MoveFPS_DragUpdate(); end);
	end);
	dragProxy:SetScript("OnDragStop", function(self)
		MoveFPS_DragUpdate(); -- exact final position (drag still active)
		MoveFPS_dragActive = false;
		self:SetScript("OnUpdate", nil);
		if RefreshWindow then
			RefreshWindow();
		end
	end);
end

local function MoveFPS_BuildOptionsWindow()
	if options then
		return;
	end
	options = CreateFrame("Frame", "Move_FPS_CounterOptions", UIParent, "BackdropTemplate");
	options:SetFrameStrata("HIGH");
	options:SetSize(292, 184);
	options:SetMovable(true);
	options:EnableMouse(true);
	options:RegisterForDrag("LeftButton");
	options:SetClampedToScreen(true);
	options:SetScript("OnDragStart", function(self)
		self:StartMoving(); -- own frame: always servable
	end);
	options:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing();
		if db then
			local pw, ph = UIParent:GetSize();
			local cx, cy = self:GetCenter();
			if pw == nil or ph == nil or cx == nil or cy == nil then
				return; -- unreadable: keep the last good window spot
			end
			db.win = { x = MoveFPS_Round2(cx - pw / 2), y = MoveFPS_Round2(cy - ph / 2) };
			self:ClearAllPoints();
			self:SetPoint("CENTER", UIParent, "CENTER", db.win.x, db.win.y);
		end
	end);
	options:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		edgeSize = 16,
		insets = { left = 2, right = 2, top = 2, bottom = 2 },
	});
	options:SetBackdropColor(0, 0, 0, 0.85);
	options:Hide();

	-- clicking anywhere outside an edit box (on the window or on the world)
	-- gives keyboard focus back so the game chat works again
	local function ReleaseFocus()
		for _, box in ipairs({ options.xBox, options.yBox, options.sizeBox }) do
			box:ClearFocus();
		end
	end
	options:SetScript("OnMouseDown", ReleaseFocus);
	if WorldFrame then
		WorldFrame:HookScript("OnMouseUp", function()
			if options and options:IsShown() then
				ReleaseFocus();
			end
		end);
	end

	-- close
	local close = CreateFrame("Button", nil, options, "UIPanelCloseButton");
	close:SetPoint("TOPRIGHT", options, "TOPRIGHT", -4, -4);
	close:SetScript("OnClick", function()
		options:Hide();
	end);

	-- move mode: only while it is on is the counter drag-movable; it sits
	-- centered at the top of the window
	options.moveBtn = CreateFrame("Button", nil, options, "UIPanelButtonTemplate");
	options.moveBtn:SetSize(140, 22); -- wide enough for the Large-font label
	if options.moveBtn.SetNormalFontObject then
		options.moveBtn:SetNormalFontObject("GameFontNormalLarge");
		options.moveBtn:SetHighlightFontObject("GameFontHighlightLarge");
		options.moveBtn:SetDisabledFontObject("GameFontNormalLarge");
	end
	options.moveBtn:SetText("move counter");
	options.moveBtn:SetPoint("TOP", options, "TOP", 0, -6);
	options.moveBtn:SetScript("OnClick", function()
		if dragProxy and dragProxy:IsShown() then
			dragProxy:Hide();
			dragProxy.square:Hide();
			options.moveBtn:SetText("move counter");
		else
			MoveFPS_BuildDragProxy();
			if not dragProxy then
				return;
			end
			dragProxy.square:Show();
			dragProxy:Show();
			MoveFPS_SyncDragProxy();
			options.moveBtn:SetText("stop moving");
		end
	end);

	-- position: x/y coordinates with two decimal places, side by side; the
	-- labels are edge-anchored to their boxes so they sit on the same row
	options.xBox = MoveFPS_MakeEditBox(options, 80, 9, "TOPLEFT", options, "TOPLEFT", 52, -32, function(v)
		v = tonumber(v);
		if v and MoveFPS_ValidCoord(v) then
			db.x, db.placed = MoveFPS_Round2(v), true;
			MoveFPS_SetLocked(true);
			MoveFPS_ApplyPosition(); -- db already correct, frame follows
		end
	end);
	options.xLabel = MoveFPS_MakeLabel(options, "X", "GameFontNormalLarge", "RIGHT", options.xBox, "LEFT", -12, 0);
	options.yBox = MoveFPS_MakeEditBox(options, 80, 9, "TOPLEFT", options, "TOPLEFT", 176, -32, function(v)
		v = tonumber(v);
		if v and MoveFPS_ValidCoord(v) then
			db.y, db.placed = MoveFPS_Round2(v), true;
			MoveFPS_SetLocked(true);
			MoveFPS_ApplyPosition(); -- db already correct, frame follows
		end
	end);
	options.yLabel = MoveFPS_MakeLabel(options, "Y", "GameFontNormalLarge", "RIGHT", options.yBox, "LEFT", -12, 0);

	-- text size: one decimal place; defaults to the game's own size; the box
	-- shares the slider/dropdown column and its label right-aligns with the
	-- other row labels. x is 101, not 96: the InputBoxTemplate's left border
	-- cap protrudes 5px past the frame edge, so 101 puts the visible border
	-- exactly on the column edge the slider and dropdown start at
	options.sizeBox = MoveFPS_MakeEditBox(options, 80, 5, "TOPLEFT", options, "TOPLEFT", 101, -68, function(v)
		v = tonumber(v);
		if v and MoveFPS_ValidSize(v) then
			db.size = MoveFPS_Round1(v);
			MoveFPS_ApplySize(); -- db already correct, frame follows
		end
	end);
	-- 17 = the labels' shared 12px gap from the visible border + the 5px the
	-- border cap protrudes past the frame edge, so the right edges of the
	-- Size/Decimals/Anchor labels stay on one line
	options.sizeLabel = MoveFPS_MakeLabel(options, "Size", "GameFontNormalLarge", "RIGHT", options.sizeBox, "LEFT", -17, 0);

	-- decimals: compact slider, 0-2
	options.decimals = CreateFrame("Slider", nil, options, "OptionsSliderTemplate");
	options.decimals:SetSize(160, 14);
	options.decimals:SetPoint("TOPLEFT", options, "TOPLEFT", 96, -104);
	options.decimals:SetMinMaxValues(0, 2);
	options.decimals:SetValueStep(1);
	options.decimals:SetObeyStepOnDrag(true);
	for _, part in ipairs({ "Text", "Low", "High" }) do
		if options.decimals[part] then
			options.decimals[part]:Hide();
		end
	end
	options.decimalsLabel = MoveFPS_MakeLabel(options, "Decimals", "GameFontNormalLarge", "RIGHT", options.decimals, "LEFT", -12, 0);
	options.decimalsValue = MoveFPS_MakeLabel(options, "1", "GameFontNormalLarge", "LEFT", options.decimals, "RIGHT", 6, 0);
	options.decimals:SetScript("OnValueChanged", function(_, value)
		value = math.floor(value + 0.5);
		if db and db.decimals ~= value then
			db.decimals = value;
			options.decimalsValue:SetText(tostring(value));
		end
	end);

	-- remember the counter's visibility between sessions: the label +
	-- checkbox pair sits centered in the window, below the Anchor row
	options.rememberLabel = MoveFPS_MakeLabel(options, "Remember", "GameFontNormalLarge", "TOPLEFT", options, "TOPLEFT", 91, -158); -- pair (label + 8 + checkbox) centered horizontally
	options.remember = CreateFrame("CheckButton", "Move_FPS_CounterRemember", options, "UICheckButtonTemplate");
	options.remember:SetSize(22, 22);
	options.remember:SetPoint("LEFT", options.rememberLabel, "RIGHT", 8, 0);
	options.remember:SetScript("OnClick", function(self)
		if not db then
			return;
		end
		db.remember = self:GetChecked() and true or false;
		if db.remember then
			-- remember the visibility as the player left it: the window's
			-- preview force-show is not the player's state, but their own
			-- toggle while configuring is
			if options:IsShown() and counterTouchedWhileOpen then
				db.toggle = MoveFPS_CounterShown();
			elseif options:IsShown() and counterShownSnapshot ~= nil then
				db.toggle = counterShownSnapshot;
			else
				db.toggle = MoveFPS_CounterShown();
			end
		end
	end);

	options:SetScript("OnShow", function()
		counterShownSnapshot = MoveFPS_CounterShown();
		counterTouchedWhileOpen = false;
		if not counterShownSnapshot then
			-- live preview while configuring; quiet so the visibility hooks
			-- (retail) do not mistake it for the player's own toggle
			MoveFPS_quietVisibility = true;
			MoveFPS_SetCounterShown(true);
			MoveFPS_quietVisibility = false;
		end
		-- own frame: every write below serves, marked or not.
		options.moveBtn:SetText("move counter");
		if RefreshWindow then
			RefreshWindow();
		end
	end);
	options:SetScript("OnHide", function()
		if dragProxy then
			dragProxy:Hide(); -- leaving the window also leaves move mode
			if dragProxy.square then
				dragProxy.square:Hide();
			end
			dragProxy:SetScript("OnUpdate", nil);
		end
		MoveFPS_dragActive = false;
		-- undo our preview force-show, but never a visibility change the
		-- player made themselves while the window was open
		if counterShownSnapshot ~= nil and not counterShownSnapshot and not counterTouchedWhileOpen then
			MoveFPS_quietVisibility = true;
			MoveFPS_SetCounterShown(false);
			MoveFPS_quietVisibility = false;
		end
		counterShownSnapshot = nil;
	end);

	function RefreshWindow()
		if not db or not options.xBox then
			return;
		end
		-- own frames throughout: every write below serves, marked or not.
		if tonumber(options.xBox:GetText()) ~= db.x then
			options.xBox:SetText(string.format("%.2f", db.x));
		end
		if tonumber(options.yBox:GetText()) ~= db.y then
			options.yBox:SetText(string.format("%.2f", db.y));
		end
		if tonumber(options.sizeBox:GetText()) ~= db.size then
			options.sizeBox:SetText(string.format("%.1f", db.size));
		end
		if options.decimals then
			options.decimalsValue:SetText(tostring(db.decimals));
			if math.floor(options.decimals:GetValue() + 0.5) ~= db.decimals then
				options.decimals:SetValue(db.decimals);
			end
		end
		if options.anchorBtn then
			options.anchorBtn:SetText(db.anchor);
		end
		options.remember:SetChecked(db.remember);
	end
end

-- the anchor picker needs the menu system; load it lazily (it ships on every
-- target flavor) so the dropdown builds where it exists, and fall back to a
-- cycling button where it does not
local function MoveFPS_EnsureMenuUtil()
	if not MenuUtil and LoadAddOn then
		pcall(LoadAddOn, "Blizzard_Menu");
	end
end

-- shared placement + row label for both anchor picker variants
local function MoveFPS_StyleAnchorButton(button)
	button:SetSize(160, 24);
	button:SetPoint("TOPLEFT", options, "TOPLEFT", 96, -128);
	options.anchorLabel = MoveFPS_MakeLabel(options, "Anchor", "GameFontNormalLarge", "RIGHT", button, "LEFT", -12, 0);
end

local function MoveFPS_BuildAnchorDropdown()
	options.anchorBtn = CreateFrame("DropdownButton", nil, options, "WowStyle1DropdownTemplate");
	MoveFPS_StyleAnchorButton(options.anchorBtn);
	if options.anchorBtn.Text then
		-- the classic template right-aligns the text at a small size
		options.anchorBtn.Text:SetFontObject("GameFontHighlightLarge");
		options.anchorBtn.Text:SetJustifyH("LEFT");
		options.anchorBtn.Text:SetWidth(124); -- room for BOTTOMRIGHT beside the arrow
	end
	options.anchorBtn:SetupMenu(function(_, rootDescription)
		if not db then
			return;
		end
		for _, a in ipairs(ANCHOR_LIST) do
			rootDescription:CreateRadio(
				a,
				function(data)
					return db.anchor == data;
				end,
				function(data)
					db.anchor = data;
					MoveFPS_ApplyPosition(); -- db already correct, frame follows
					options.anchorBtn:SetText(data);
				end,
				a
			);
		end
	end);
end

local function MoveFPS_BuildAnchorFallback()
	options.anchorBtn = CreateFrame("Button", nil, options, "UIPanelButtonTemplate");
	MoveFPS_StyleAnchorButton(options.anchorBtn);
	options.anchorBtn:SetScript("OnClick", function()
		if not db then
			return;
		end
		for i, a in ipairs(ANCHOR_LIST) do
			if a == db.anchor then
				db.anchor = ANCHOR_LIST[i + 1] or ANCHOR_LIST[1];
				break;
			end
		end
		MoveFPS_ApplyPosition(); -- db already correct, frame follows
		options.anchorBtn:SetText(db.anchor);
	end);
end

-- ----------------------------------------------------------------------------
-- Load (pure Lua, always) + init (attempt everything at file scope, on load,
-- and on slash)
-- ----------------------------------------------------------------------------

-- Resolve the flavor, load and backfill the db, capture Blizzard's methods,
-- anchors and font size. Pure Lua and plain reads only. Returns false on an
-- unknown layout -- inert before touching SavedVariables. Idempotent. The
-- first-run tutorial prints best-effort, chat lockdown or not -- it is never
-- load-bearing.
local function MoveFPS_LoadState()
	if MoveFPS_stateLoaded then
		return true;
	end
	-- resolve the client flavor first: on an unknown layout stay inert
	-- before touching saved variables
	if FramerateFrame then
		-- modern clients: one frame holds both fontstrings
		MoveFPS_frame = FramerateFrame;
		MoveFPS_text = FramerateFrame.FramerateText;
		MoveFPS_label = FramerateFrame.Label;
		MoveFPS_regions[1] = FramerateFrame;
		MoveFPS_toggle = function() FramerateFrame:Toggle(); end;
	elseif FramerateLabel and FramerateText then
		-- classic clients: two fontstrings on WorldFrame
		MoveFPS_label = FramerateLabel;
		MoveFPS_text = FramerateText;
		MoveFPS_regions[1] = FramerateLabel;
		MoveFPS_regions[2] = FramerateText;
		MoveFPS_toggle = function() ToggleFramerate(); end;
	else
		return false;
	end

	local freshDB = _G[ADDON_NAME] == nil;
	db = _G[ADDON_NAME];
	if not db then
		db = {};
		_G[ADDON_NAME] = db; -- first session: publish it so it gets saved
	end

	-- capture Blizzard's methods, anchors and font size (plain reads)
	for _, region in ipairs(MoveFPS_regions) do
		local orig = {
			clear = region.ClearAllPoints,
			setPoint = region.SetPoint,
		};
		local ok, point, relativeTo, relativePoint, x, y = pcall(region.GetPoint, region, 1);
		if ok then
			orig.points = { point = point, relativeTo = relativeTo, relativePoint = relativePoint, x = x, y = y };
		end
		if region.GetFont then
			local _, fontSize = region:GetFont();
			orig.size = fontSize;
		end
		MoveFPS_orig[region] = orig;
	end
	-- the label and number fontstrings also need their game-default font
	-- size remembered (they are not anchored by us on modern clients)
	for _, region in ipairs({ MoveFPS_label, MoveFPS_text }) do
		if region and not MoveFPS_orig[region] and region.GetFont then
			local _, fontSize = region:GetFont();
			MoveFPS_orig[region] = { size = fontSize };
		end
	end
	local labelOrig = MoveFPS_orig[MoveFPS_label] or MoveFPS_orig[MoveFPS_text] or {};
	if labelOrig.size then
		gameDefaultSize = labelOrig.size; -- the size the game UI actually uses
	end

	local upgraded = MoveFPS_BackfillLegacy(db);
	MergeDefaults(db, defaults);
	MoveFPS_Sanitize(db);
	if freshDB or upgraded then
		MoveFPS_instructions(); -- first generation, or a v1 table upgrading
	end

	-- rewrite the decimals in whatever format Blizzard feeds the counter
	-- (default 1 passes the format through untouched). Plain assignment: safe.
	if MoveFPS_text then
		local origSetFormattedText = MoveFPS_text.SetFormattedText;
		MoveFPS_text.SetFormattedText = function(self, format, ...)
			if db.decimals ~= 1 then
				format = string.gsub(format, "%%%.%df", "%%." .. db.decimals .. "f");
			end
			return origSetFormattedText(self, format, ...);
		end;
	end
	MoveFPS_stateLoaded = true;
	return true;
end

-- Setup, run at file scope (pre-SV: registers, builds the window) and again
-- on ADDON_LOADED and slash (cheap idempotent re-entry: registration
-- no-ops, the window builds once, hooks run once, applies re-assert). The
-- first apply waits for state (db guard below); the visibility restore runs
-- once (Toggle flips, so repeats would un-restore).
MoveFPS_EnsureInit = function()
	MoveFPS_RegisterAddonEvents();
	if not options then
		pcall(function()
			MoveFPS_EnsureMenuUtil();
			MoveFPS_BuildOptionsWindow();
		end);
	end
	if options and not options.anchorBtn then
		pcall(MoveFPS_BuildAnchorDropdown);
		if not options.anchorBtn then
			pcall(MoveFPS_BuildAnchorFallback);
		end
	end
	if MoveFPS_stateLoaded and not MoveFPS_initDone then
		if not db.placed then
			MoveFPS_StoreGamePlacement(); -- self-guarded: no-op when unreadable
		end
		if db.placed then
			MoveFPS_SetLocked(true);
		end
		MoveFPS_ApplyPosition();
		MoveFPS_ApplySize();
		-- restore the visibility BEFORE hooking the toggle so our own restore
		-- does not count as a user toggle (hooks install right after)
		if db.remember and db.toggle then
			MoveFPS_toggle();
		end
		if not MoveFPS_visibilityHooked then
			if MoveFPS_frame then
				-- retail: post-hooks on Show/Hide. NEVER hooksecurefunc the
				-- frame's Toggle: it is a Blizzard Lua method whose body
				-- calls the gated SetShown, and tainting it would break the
				-- player's own keybind toggle while protected.
				MoveFPS_frame:HookScript("OnShow", MoveFPS_OnToggled);
				MoveFPS_frame:HookScript("OnHide", MoveFPS_OnToggled);
			else
				-- classic: no gate system; the global hook is inert and safe
				hooksecurefunc("ToggleFramerate", MoveFPS_OnToggled);
			end
			MoveFPS_visibilityHooked = true;
		end
		if options then
			options:ClearAllPoints();
			options:SetPoint("CENTER", UIParent, "CENTER", db.win.x, db.win.y);
			if RefreshWindow then
				RefreshWindow();
			end
		end
		MoveFPS_initDone = true;
	elseif MoveFPS_stateLoaded then
		-- re-assert on every re-entry (login re-anchor, slash): positions
		-- over Blizzard's own placement, idempotent by construction.
		MoveFPS_ApplyPosition();
		MoveFPS_ApplySize();
		if options then
			options:ClearAllPoints();
			options:SetPoint("CENTER", UIParent, "CENTER", db.win.x, db.win.y);
			if RefreshWindow then
				RefreshWindow();
			end
		end
	end
end;

-- ----------------------------------------------------------------------------
-- login and persist through sessions functionality
-- ----------------------------------------------------------------------------
local function MoveFPS_OnEvent(self, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 == ADDON_NAME then
			if MoveFPS_LoadState() then
				MoveFPS_EnsureInit();
			end
			-- unregister LAST: EnsureInit re-registers everything above,
			-- so unsubscribing first would resurrect in the same tick.
			-- The handler is idempotent anyway, so a lingering
			-- registration would be harmless regardless.
			self:UnregisterEvent("ADDON_LOADED");
		end
	end
end

-- All event installs funnel through here. Re-registering is a no-op and the
-- script is simply replaced, so repeated EnsureInit calls stay cheap.
local function MoveFPS_RegisterAddonEventsInner()
	if not MoveFPS_EventFrame then return end
	MoveFPS_EventFrame:RegisterEvent("ADDON_LOADED");
	MoveFPS_EventFrame:SetScript("OnEvent", MoveFPS_OnEvent);
end
MoveFPS_RegisterAddonEvents = MoveFPS_RegisterAddonEventsInner;

MoveFPS_EventFrame = CreateFrame("Frame", "Move_FPS_CounterEventFrame");
MoveFPS_RegisterAddonEvents();

-- File scope runs before SavedVariables land: register (so our own
-- ADDON_LOADED is heard) and build the window. The first apply waits for
-- state in the ADDON_LOADED handler below.
MoveFPS_EnsureInit();

-- slash command functionality: bare /movefps (or anything unrecognized)
-- toggles the config window, /movefps reset restores every default
SLASH_MOVEFPS1 = "/movefps";
SlashCmdList.MOVEFPS = function(msg)
	if not MoveFPS_stateLoaded then
		if not MoveFPS_LoadState() then
			return; -- unknown layout: inert, SavedVariables untouched
		end
	end
	-- re-entry is cheap and idempotent: a missed ADDON_LOADED (refused
	-- registration) resumes here.
	MoveFPS_EnsureInit();
	if not db then
		return;
	end
	if string.match(msg or "", "^reset$") then
		Move_FPS_Counter = {};
		db = Move_FPS_Counter;
		MergeDefaults(db, defaults);
		db.size = gameDefaultSize; -- the game's own size, never a 0 sentinel
		MoveFPS_SetLocked(false);
		-- hand the anchors back first, then measure the game's own spot
		MoveFPS_ApplyPosition();
		MoveFPS_ApplySize();
		MoveFPS_StoreGamePlacement(); -- self-guarded: db already correct regardless
		if options then
			options:ClearAllPoints();
			options:SetPoint("CENTER", UIParent, "CENTER", db.win.x, db.win.y);
			if RefreshWindow then
				RefreshWindow();
			end
		end
	elseif options and options:IsShown() then
		options:Hide();
	elseif options then
		options:Show();
	end
end

-- Move FPS Counter
-- Moves, styles and remembers the game's default FPS counter on every version
-- of the game. One shared implementation; at load the runtime picks the flavor:
--   * modern clients: the FramerateFrame from Blizzard_FramerateFrame
--   * classic clients: the FramerateLabel/FramerateText fontstrings on WorldFrame
-- Once placed, the anchors are locked (the original methods are kept privately
-- and the region's own ones become no-ops), so no later Blizzard re-anchor, UI
-- reload pass or other addon can displace the counter. Everything is event
-- driven: no polling and no per-frame code outside an active drag. /movefps
-- opens the config window (with a move mode that makes the counter
-- drag-movable), /movefps reset restores the defaults.
--
-- Midnight (12.x) restrictions: nothing this addon touches can become
-- secret-marked (it ingests no unit/combat/aura data -- framerate text only),
-- so every op just attempts, with no restriction checks and no queues. If the
-- engine ever refuses, it errors loudly instead of failing silently. The only
-- guards are crash-safety (nil reads abort geometry) and correctness (the
-- placed-state anchor lock, the already-there early-outs).

local ADDON_NAME = "Move_FPS_Counter";

-- ingame instructions
local exitColor = "|r";
local colorOrange = "|cFFDF9F1F";
local function MoveFPS_instructions()
	-- commands sit outside the color spans, so they render in the chat's
	-- default white while the surrounding text stays orange
	print(colorOrange .. "Use " .. exitColor .. "/movefps" .. colorOrange .. " to open the configuration window." .. exitColor);
	print(colorOrange .. "Use " .. exitColor .. "/movefps reset" .. colorOrange .. " to restore the defaults." .. exitColor);
end

local ANCHOR_LIST = { "CENTER", "TOP", "TOPRIGHT", "RIGHT", "BOTTOMRIGHT", "BOTTOM", "BOTTOMLEFT", "LEFT", "TOPLEFT" };
-- from a region's center to its anchor point, in half-dimensions
local ANCHOR_DELTAS = {
	CENTER = { 0, 0 },
	TOP = { 0, 1 }, TOPRIGHT = { 1, 1 }, RIGHT = { 1, 0 }, BOTTOMRIGHT = { 1, -1 },
	BOTTOM = { 0, -1 }, BOTTOMLEFT = { -1, -1 }, LEFT = { -1, 0 }, TOPLEFT = { -1, 1 },
};

local defaults = {
	x = 0, y = 0;   -- position of the counter's anchor point, in counter units from the screen center
	anchor = "CENTER", -- which part of the counter stays put when the text width fluctuates
	placed = false,    -- false: the game's own placement is left untouched
	decimals = 1,      -- decimal places shown for the framerate, 0-2
	remember = true,   -- remember the counter's shown/hidden state
	toggle = true,     -- the remembered state itself
	win = { x = 0, y = 0 }, -- config window position, relative to screen center
	-- size is backfilled with the game's own default font size at login
};

local MIN_SIZE, MAX_SIZE = 1, 64;
local MAX_COORD = 100000;

-- All shared state is declared HERE, above every function that reads or
-- writes it: Lua upvalues bind at closure creation, so a later `local` would
-- leave earlier functions writing to a same-named global instead.
local db; -- alias for the Move_FPS_Counter SavedVariables table, set on ADDON_LOADED
local MoveFPS_frame;        -- modern clients only: FramerateFrame as a whole
local MoveFPS_label;        -- the "FPS" label fontstring
local MoveFPS_text;         -- the number fontstring
local MoveFPS_regions = {}; -- regions whose anchors we own and keep locked
local MoveFPS_orig = {};    -- [region] = Blizzard's methods and anchors
local MoveFPS_toggle;       -- the flavor's toggle for the counter's visibility
local MoveFPS_locked;       -- true while our anchors are locked in place
local gameDefaultSize = 12; -- the game's own counter font size, captured at load
local options, dragProxy;   -- config window and its drag preview, created below
local RefreshWindow;        -- assigned with the config window
local counterShownSnapshot;    -- the counter's visibility before configuring
local counterTouchedWhileOpen; -- the player toggled visibility while configuring
local MoveFPS_grabDX, MoveFPS_grabDY; -- cursor offset from the anchor point at grab time
local MoveFPS_stateLoaded = false;    -- flavor resolved + db backfilled
local MoveFPS_initDone = false;       -- one-time login restore finished
local MoveFPS_dragActive = false;     -- a drag gesture is in flight
local MoveFPS_quietVisibility = false; -- programmatic Show/Hide: don't track as a user toggle

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
	return v and v >= -MAX_COORD and v <= MAX_COORD;
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
	if not ANCHOR_DELTAS[dbt.anchor] then dbt.anchor = "CENTER"; end
	dbt.size = MoveFPS_Round1(tonumber(dbt.size) or gameDefaultSize);
	if not MoveFPS_ValidSize(dbt.size) then dbt.size = gameDefaultSize; end
	dbt.decimals = math.floor(tonumber(dbt.decimals) or 1);
	if dbt.decimals < 0 or dbt.decimals > 2 then dbt.decimals = 1; end
	dbt.placed = dbt.placed and true or false;
	dbt.remember = dbt.remember and true or false;
	dbt.toggle = dbt.toggle and true or false;
	if type(dbt.win) ~= "table" then
		dbt.win = {};
	end
	dbt.win.x = MoveFPS_Round2(tonumber(dbt.win.x) or 0);
	dbt.win.y = MoveFPS_Round2(tonumber(dbt.win.y) or 0);
end

-- ----------------------------------------------------------------------------
-- core: placement, size, visibility
-- ----------------------------------------------------------------------------

-- Placement lock: while placed, the region's own anchor methods are no-ops so
-- nothing can move the counter behind our back; unplaced (never placed), it
-- behaves exactly like the stock game.
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

-- places the counter at the stored spot from now on (any input path)
local function MoveFPS_Place()
	db.placed = true;
	MoveFPS_SetLocked(true);
	MoveFPS_ApplyPosition();
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

local function MoveFPS_CounterShown()
	if MoveFPS_frame then
		return MoveFPS_frame:IsShown();
	end
	return MoveFPS_text:IsShown();
end

-- The visibility as the player left it: the config window's preview
-- force-show is not the player's state, but their own toggle while
-- configuring is.
local function MoveFPS_PlayerVisibility()
	if options and options:IsShown() and not counterTouchedWhileOpen and counterShownSnapshot ~= nil then
		return counterShownSnapshot;
	end
	return MoveFPS_CounterShown();
end

-- programmatic Show/Hide (preview force-show and its undo): quiet, so the
-- visibility hooks never mistake it for the player's own toggle
local function MoveFPS_SetCounterShownQuietly(shown)
	MoveFPS_quietVisibility = true;
	if MoveFPS_frame then
		if shown then MoveFPS_frame:Show(); else MoveFPS_frame:Hide(); end
	else
		-- ToggleFramerate normally resets the throttle timer; the game's
		-- OnUpdate must never read it as nil
		if WorldFrame then
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
	MoveFPS_quietVisibility = false;
end

local function MoveFPS_OnToggled()
	if not db or MoveFPS_quietVisibility then
		return;
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
-- coordinates
-- ----------------------------------------------------------------------------

-- the region's db.anchor point, read from its own rect (rect units)
local function MoveFPS_RectAnchorPoint(region)
	local left, right = region:GetLeft(), region:GetRight();
	local top, bottom = region:GetTop(), region:GetBottom();
	if not (left and right and top and bottom) then
		return nil, nil;
	end
	local delta = ANCHOR_DELTAS[db.anchor] or ANCHOR_DELTAS.CENTER;
	return (left + right) / 2 + delta[1] * (right - left) / 2,
		(top + bottom) / 2 + delta[2] * (top - bottom) / 2;
end

-- The counter's anchor point in stored units: the SetPoint offset from
-- UIParent's center that would put it exactly where it sits now. The counter
-- lives on WorldFrame on every flavor (scale 1, outside UIParent), so its
-- offsets are scale-1 units -- the cursor's own -- and are never divided by
-- UIParent's scale.
-- Rect reads cannot be converted with a fixed factor: for a region parented
-- outside UIParent each client flavor reports Get* values with its own scale
-- and origin. So the mapping is measured instead of assumed: pin the region
-- to two known UIParent spots, read the rect back, and solve the per-axis
-- affine mapping (scale and origin, so even a flipped or offset convention
-- cancels). Everything runs inside the calling handler and the counter's own
-- placement is restored before returning, so nothing renders mid-measure.
-- The anchored region is the label on classic (the number hangs off its
-- right edge), so its own rect is what the anchor point is measured on.
local function MoveFPS_MeasuredAnchor()
	local region = MoveFPS_frame or MoveFPS_label;
	local gx, gy = MoveFPS_RectAnchorPoint(region);
	if gx == nil or gy == nil then
		return nil, nil;
	end
	local CAL = 100;
	MoveFPS_ApplyAnchor(region, "CENTER", UIParent, "CENTER", 0, 0);
	local k1x, k1y = region:GetCenter();
	MoveFPS_ApplyAnchor(region, "CENTER", UIParent, "CENTER", CAL, CAL);
	local k2x, k2y = region:GetCenter();
	MoveFPS_ApplyPosition(); -- back where it was
	if k1x == nil or k1y == nil or k2x == nil or k2y == nil then
		return nil, nil;
	end
	local sx = (k2x - k1x) / CAL;
	local sy = (k2y - k1y) / CAL;
	if math.abs(sx) < 1e-8 then sx = 1; end
	if math.abs(sy) < 1e-8 then sy = 1; end
	-- read = read(offset 0) + slope * offset, solved per axis
	return (gx - k1x) / sx, (gy - k1y) / sy;
end

-- with the counter sitting on its game placement, remember that spot as real
-- center-relative coordinates so the x/y boxes tell the truth before the
-- first move. Rounded: raw float32 layout reads would overflow the boxes.
local function MoveFPS_StoreGamePlacement()
	local x, y = MoveFPS_MeasuredAnchor();
	if x == nil or y == nil then
		return false; -- unreadable: no box beats a wrong box
	end
	db.x, db.y = MoveFPS_Round2(x), MoveFPS_Round2(y);
	return true;
end

-- Switching the anchor keeps the counter exactly where it is on screen: a
-- placed counter re-expresses its stored spot for the new anchor point (the
-- region's own size is in offset units, no measuring needed), an unplaced
-- one re-measures the game's spot so the boxes stay truthful.
local function MoveFPS_SetAnchor(anchor)
	if anchor == db.anchor or not ANCHOR_DELTAS[anchor] then
		return;
	end
	local old, new = ANCHOR_DELTAS[db.anchor], ANCHOR_DELTAS[anchor];
	db.anchor = anchor;
	if db.placed then
		local region = MoveFPS_frame or MoveFPS_label;
		local w, h = region:GetWidth(), region:GetHeight();
		if w and h then
			local dx, dy = (new[1] - old[1]) * w / 2, (new[2] - old[2]) * h / 2;
			db.x, db.y = MoveFPS_Round2(db.x + dx), MoveFPS_Round2(db.y + dy);
			if MoveFPS_dragActive then
				-- the grab is relative to the anchor point: shift it along
				MoveFPS_grabDX, MoveFPS_grabDY = MoveFPS_grabDX - dx, MoveFPS_grabDY - dy;
			end
		end
		MoveFPS_ApplyPosition();
	else
		MoveFPS_StoreGamePlacement();
	end
	if RefreshWindow then
		RefreshWindow();
	end
end

-- ----------------------------------------------------------------------------
-- drag
-- ----------------------------------------------------------------------------

local function MoveFPS_EndDrag()
	MoveFPS_dragActive = false;
	if dragProxy then
		dragProxy:SetScript("OnUpdate", nil);
	end
end

-- real-time drag: the counter follows the cursor frame by frame. The math is
-- cursor-driven, never read back from the square: the square is anchored to
-- the counter it moves, so reading it would feed the counter's own movement
-- into the next update and run away. The OnUpdate script only exists while a
-- drag is active and is removed on release
local function MoveFPS_DragUpdate()
	if not (db and MoveFPS_dragActive) then
		return;
	end
	local cx, cy = GetCursorPosition(); -- the counter's own units (see MoveFPS_MeasuredAnchor)
	if cx == nil or cy == nil then
		MoveFPS_EndDrag(); -- db keeps the last good spot
		return;
	end
	db.x = MoveFPS_Round2(cx - MoveFPS_grabDX);
	db.y = MoveFPS_Round2(cy - MoveFPS_grabDY);
	MoveFPS_Place();
	if RefreshWindow then
		RefreshWindow(); -- the x/y boxes update live while dragging
	end
end

local function MoveFPS_SetMoveMode(on)
	if not dragProxy then
		return;
	end
	dragProxy:SetShown(on);
	dragProxy.square:SetShown(on);
	if not on then
		MoveFPS_EndDrag();
	end
	options.moveBtn:SetText(on and "stop moving" or "move counter");
end

local function MoveFPS_BuildDragProxy()
	if dragProxy then
		return;
	end
	-- The green move-mode square must render BELOW the counter's text while
	-- still receiving the drag, so it is a BACKGROUND-layer texture inside
	-- the counter's own frame hierarchy (a frame's background layer draws
	-- under its artwork fontstrings), and the drag input is a fully
	-- transparent frame stacked above the text: the text stays readable while
	-- the invisible frame catches the mouse. Both hug the counter's exact
	-- visual rectangle (label + number) through relative anchors, so they
	-- follow every counter move and size change on their own.
	local parent = MoveFPS_frame or WorldFrame;
	local square = parent:CreateTexture(nil, "BACKGROUND");
	square:SetColorTexture(0, 1, 0, 0.5);
	dragProxy = CreateFrame("Frame", "Move_FPS_CounterDragProxy", parent);
	for _, region in ipairs({ square, dragProxy }) do
		if MoveFPS_frame then
			region:SetPoint("TOPLEFT", MoveFPS_frame, "TOPLEFT", 0, 0);
			region:SetPoint("BOTTOMRIGHT", MoveFPS_frame, "BOTTOMRIGHT", 0, 0);
		else
			region:SetPoint("LEFT", MoveFPS_label, "LEFT", 0, 0);
			region:SetPoint("RIGHT", MoveFPS_text, "RIGHT", 0, 0);
			region:SetPoint("TOP", MoveFPS_label, "TOP", 0, 0);
			region:SetPoint("BOTTOM", MoveFPS_label, "BOTTOM", 0, 0);
		end
	end
	dragProxy.square = square;
	dragProxy:Hide();
	square:Hide();
	dragProxy:EnableMouse(true);
	-- No StartMoving anywhere: the built-in mover would fight the square's
	-- counter-relative anchors. The square is ONLY ever counter-anchored and
	-- the counter is ONLY ever cursor-driven: a single control loop.
	-- The grab starts on the press itself (no drag threshold), so the counter
	-- follows from the first pixel of movement.
	dragProxy:SetScript("OnMouseDown", function(self, button)
		if button ~= "LeftButton" or not db then
			return;
		end
		local cx, cy = GetCursorPosition(); -- the counter's own units
		if cx == nil or cy == nil then
			return; -- cursor unreadable: refuse the grab without touching anything
		end
		-- capture where the cursor grabbed the counter relative to its anchor
		-- point. A placed counter needs no measuring: db already IS the anchor
		-- point's position, so the grab is exact whatever the ui scale. The
		-- first grab measures the game's spot once, so the counter is
		-- re-anchored exactly where it sits and only follows the cursor.
		local ax, ay = db.x, db.y;
		if not db.placed then
			ax, ay = MoveFPS_MeasuredAnchor();
			if ax == nil or ay == nil then
				return; -- unmeasurable: no grab beats a displacing grab
			end
		end
		MoveFPS_grabDX, MoveFPS_grabDY = cx - ax, cy - ay;
		MoveFPS_dragActive = true;
		self:SetScript("OnUpdate", MoveFPS_DragUpdate);
	end);
	dragProxy:SetScript("OnMouseUp", function(_, button)
		if button ~= "LeftButton" then
			return;
		end
		MoveFPS_DragUpdate(); -- exact final position (drag still active)
		MoveFPS_EndDrag();
	end);
end

-- ----------------------------------------------------------------------------
-- config window, built inside a pcall: even if a widget template is missing
-- in some client flavor, the counter keeps working. A partial build simply
-- never assigns RefreshWindow (or the OnShow/OnHide scripts), and every
-- RefreshWindow call site is nil-guarded
-- ----------------------------------------------------------------------------

local function MoveFPS_PlaceWindow()
	if options then
		options:ClearAllPoints();
		options:SetPoint("CENTER", UIParent, "CENTER", db.win.x, db.win.y);
		if RefreshWindow then
			RefreshWindow();
		end
	end
end

local function MoveFPS_MakeLabel(parent, text, fontObject, point, relativeTo, relPoint, x, y)
	local fs = parent:CreateFontString(nil, "OVERLAY");
	fs:SetFontObject(fontObject);
	fs:SetText(text);
	fs:SetPoint(point, relativeTo, relPoint, x, y);
	return fs;
end

-- Enter applies the typed value; Escape or clicking away discards it. Either
-- way the box then shows the stored value again (formatted, so invalid input
-- visibly reverts)
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
		-- left/right insets stay SYMMETRIC: SetJustifyH("CENTER") centers
		-- the text field, so any asymmetry visibly shifts the typed text off
		-- the box's middle; equal vertical insets center it vertically
		box:SetTextInsets(10, 10, 6, 6);
	end
	box:SetAutoFocus(false);
	box:SetMaxLetters(maxLetters);
	box:SetJustifyH("CENTER");
	local function Revert()
		if RefreshWindow then
			RefreshWindow();
		end
	end
	box:SetScript("OnEscapePressed", function(self)
		self:ClearFocus();
		Revert();
	end);
	box:SetScript("OnEnterPressed", function(self)
		-- read before ClearFocus: losing focus reverts the text
		local v = tonumber(self:GetText());
		if db and v then
			onEnter(v);
		end
		self:ClearFocus();
		Revert();
	end);
	box:SetScript("OnEditFocusLost", Revert);
	return box;
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
	options:SetClampedToScreen(true);
	-- the window moves from the press itself (no drag threshold)
	options:SetScript("OnMouseUp", function(self, button)
		if button ~= "LeftButton" or not self.moving then
			return;
		end
		self.moving = false;
		self:StopMovingOrSizing();
		if db then
			local pw, ph = UIParent:GetSize();
			local cx, cy = self:GetCenter();
			if pw == nil or ph == nil or cx == nil or cy == nil then
				return; -- unreadable: keep the last good window spot
			end
			db.win.x, db.win.y = MoveFPS_Round2(cx - pw / 2), MoveFPS_Round2(cy - ph / 2);
			MoveFPS_PlaceWindow();
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
	options:SetScript("OnMouseDown", function(self, button)
		ReleaseFocus();
		if button == "LeftButton" then
			self.moving = true;
			self:StartMoving();
		end
	end);
	if WorldFrame then
		WorldFrame:HookScript("OnMouseUp", function()
			if options:IsShown() then
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
		MoveFPS_BuildDragProxy();
		MoveFPS_SetMoveMode(not dragProxy:IsShown());
	end);

	-- position: x/y coordinates with two decimal places, side by side; the
	-- labels are edge-anchored to their boxes so they sit on the same row
	options.xBox = MoveFPS_MakeEditBox(options, 80, 9, "TOPLEFT", options, "TOPLEFT", 52, -32, function(v)
		if MoveFPS_ValidCoord(v) then
			db.x = MoveFPS_Round2(v);
			MoveFPS_Place();
		end
	end);
	options.xLabel = MoveFPS_MakeLabel(options, "X", "GameFontNormalLarge", "RIGHT", options.xBox, "LEFT", -12, 0);
	options.yBox = MoveFPS_MakeEditBox(options, 80, 9, "TOPLEFT", options, "TOPLEFT", 176, -32, function(v)
		if MoveFPS_ValidCoord(v) then
			db.y = MoveFPS_Round2(v);
			MoveFPS_Place();
		end
	end);
	options.yLabel = MoveFPS_MakeLabel(options, "Y", "GameFontNormalLarge", "RIGHT", options.yBox, "LEFT", -12, 0);

	-- text size: one decimal place; defaults to the game's own size; the box
	-- shares the slider/dropdown column and its label right-aligns with the
	-- other row labels. x is 101, not 96: the InputBoxTemplate's left border
	-- cap protrudes 5px past the frame edge, so 101 puts the visible border
	-- exactly on the column edge the slider and dropdown start at
	options.sizeBox = MoveFPS_MakeEditBox(options, 80, 5, "TOPLEFT", options, "TOPLEFT", 101, -68, function(v)
		if MoveFPS_ValidSize(v) then
			db.size = MoveFPS_Round1(v);
			MoveFPS_ApplySize();
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
			db.toggle = MoveFPS_PlayerVisibility();
		end
	end);

	options:SetScript("OnShow", function()
		counterShownSnapshot = MoveFPS_CounterShown();
		counterTouchedWhileOpen = false;
		if not counterShownSnapshot then
			MoveFPS_SetCounterShownQuietly(true); -- live preview while configuring
		end
		options.moveBtn:SetText("move counter");
		if RefreshWindow then
			RefreshWindow();
		end
	end);
	options:SetScript("OnHide", function(self)
		-- hidden mid-move (Escape): finish the move so the spot is saved
		if self.moving then
			self:GetScript("OnMouseUp")(self, "LeftButton");
		end
		-- leaving the window also leaves move mode
		MoveFPS_SetMoveMode(false);
		MoveFPS_EndDrag();
		-- undo our preview force-show, but never a visibility change the
		-- player made themselves while the window was open
		if counterShownSnapshot == false and not counterTouchedWhileOpen then
			MoveFPS_SetCounterShownQuietly(false);
		end
		counterShownSnapshot = nil;
	end);

	-- shows the stored value unless the box already does (re-setting the
	-- same text would reset the caret and scroll for nothing)
	local function SyncBox(box, text)
		if box:GetText() ~= text then
			box:SetText(text);
		end
	end

	function RefreshWindow()
		if not db then
			return;
		end
		SyncBox(options.xBox, string.format("%.2f", db.x));
		SyncBox(options.yBox, string.format("%.2f", db.y));
		SyncBox(options.sizeBox, string.format("%.1f", db.size));
		options.decimalsValue:SetText(tostring(db.decimals));
		if math.floor(options.decimals:GetValue() + 0.5) ~= db.decimals then
			options.decimals:SetValue(db.decimals);
		end
		if options.anchorBtn then
			options.anchorBtn:SetText(db.anchor);
		end
		options.remember:SetChecked(db.remember);
	end
end

-- the anchor picker needs the menu system; load it lazily where it is not
-- loaded yet, and fall back to a cycling button where it does not exist
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
	local button = CreateFrame("DropdownButton", nil, options, "WowStyle1DropdownTemplate");
	MoveFPS_StyleAnchorButton(button);
	if button.Text then
		-- the classic template right-aligns the text at a small size
		button.Text:SetFontObject("GameFontHighlightLarge");
		button.Text:SetJustifyH("LEFT");
		button.Text:SetWidth(124); -- room for BOTTOMRIGHT beside the arrow
	end
	button:SetupMenu(function(_, rootDescription)
		if not db then
			return;
		end
		for _, a in ipairs(ANCHOR_LIST) do
			rootDescription:CreateRadio(a, function(data)
				return db.anchor == data;
			end, MoveFPS_SetAnchor, a);
		end
	end);
	options.anchorBtn = button;
end

local function MoveFPS_BuildAnchorFallback()
	local button = CreateFrame("Button", nil, options, "UIPanelButtonTemplate");
	MoveFPS_StyleAnchorButton(button);
	button:SetScript("OnClick", function()
		if not db then
			return;
		end
		for i, a in ipairs(ANCHOR_LIST) do
			if a == db.anchor then
				MoveFPS_SetAnchor(ANCHOR_LIST[i + 1] or ANCHOR_LIST[1]);
				return;
			end
		end
	end);
	options.anchorBtn = button;
end

-- ----------------------------------------------------------------------------
-- load + init
-- ----------------------------------------------------------------------------

-- Resolve the flavor, load and backfill the db, capture Blizzard's methods,
-- anchors and font size. Returns false on an unknown layout -- inert before
-- touching SavedVariables. Idempotent.
local function MoveFPS_LoadState()
	if MoveFPS_stateLoaded then
		return true;
	end
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
	if type(db) ~= "table" then
		db = {};
		_G[ADDON_NAME] = db; -- first session: publish it so it gets saved
	end

	for _, region in ipairs(MoveFPS_regions) do
		local orig = {
			clear = region.ClearAllPoints,
			setPoint = region.SetPoint,
		};
		local ok, point, relativeTo, relativePoint, x, y = pcall(region.GetPoint, region, 1);
		if ok and point then
			orig.points = { point = point, relativeTo = relativeTo, relativePoint = relativePoint, x = x, y = y };
		end
		MoveFPS_orig[region] = orig;
	end
	local sizeSource = MoveFPS_label or MoveFPS_text;
	if sizeSource and sizeSource.GetFont then
		local _, fontSize = sizeSource:GetFont();
		if fontSize then
			gameDefaultSize = MoveFPS_Round1(fontSize); -- the size the game UI actually uses
		end
	end

	local upgraded = MoveFPS_BackfillLegacy(db);
	MergeDefaults(db, defaults);
	MoveFPS_Sanitize(db);
	if freshDB or upgraded then
		MoveFPS_instructions(); -- first generation, or a v1 table upgrading
	end

	-- rewrite the decimals in whatever format Blizzard feeds the counter
	-- (default 1 passes the format through untouched)
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

-- Builds the window (once), and once state is loaded applies the saved
-- settings: the first time with the one-time login restore (visibility and
-- hooks), later just re-asserting (idempotent by construction).
local function MoveFPS_EnsureInit()
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
	if not MoveFPS_stateLoaded then
		return;
	end
	if not MoveFPS_initDone then
		MoveFPS_initDone = true;
		if db.placed then
			MoveFPS_SetLocked(true);
		end
		MoveFPS_ApplyPosition();
		MoveFPS_ApplySize();
		if not db.placed then
			MoveFPS_StoreGamePlacement(); -- self-guarded: no-op when unreadable
		end
		-- restore the visibility BEFORE hooking the toggle so our own restore
		-- does not count as a user toggle. Toggle flips: only when hidden.
		if db.remember and db.toggle and not MoveFPS_CounterShown() then
			MoveFPS_toggle();
		end
		if MoveFPS_frame then
			-- retail: post-hooks on Show/Hide. NEVER hooksecurefunc the
			-- frame's Toggle: it is a Blizzard Lua method whose body calls
			-- the gated SetShown, and tainting it would break the player's
			-- own keybind toggle while protected.
			MoveFPS_frame:HookScript("OnShow", MoveFPS_OnToggled);
			MoveFPS_frame:HookScript("OnHide", MoveFPS_OnToggled);
		else
			-- classic: no gate system; the global hook is inert and safe
			hooksecurefunc("ToggleFramerate", MoveFPS_OnToggled);
		end
	else
		MoveFPS_ApplyPosition();
		MoveFPS_ApplySize();
	end
	MoveFPS_PlaceWindow();
end

local MoveFPS_EventFrame = CreateFrame("Frame", "Move_FPS_CounterEventFrame");
MoveFPS_EventFrame:RegisterEvent("ADDON_LOADED");
MoveFPS_EventFrame:SetScript("OnEvent", function(self, _, name)
	if name == ADDON_NAME then
		self:UnregisterEvent("ADDON_LOADED");
		if MoveFPS_LoadState() then
			MoveFPS_EnsureInit();
		end
	end
end);

-- file scope runs before SavedVariables land: build the window now, apply
-- the settings on ADDON_LOADED
MoveFPS_EnsureInit();

-- slash command functionality: bare /movefps (or anything unrecognized)
-- toggles the config window, /movefps reset restores every default
SLASH_MOVEFPS1 = "/movefps";
SlashCmdList.MOVEFPS = function(msg)
	if not MoveFPS_LoadState() then
		return; -- unknown layout: inert, SavedVariables untouched
	end
	MoveFPS_EnsureInit();
	if string.match(string.lower(msg or ""), "^%s*reset%s*$") then
		-- end any in-flight drag first: its OnUpdate would otherwise rewrite
		-- the restored defaults from the cursor on its very next frame
		MoveFPS_EndDrag();
		for k in pairs(db) do db[k] = nil; end -- wipe in place: db aliases stay valid
		MergeDefaults(db, defaults);
		db.size = gameDefaultSize;
		MoveFPS_SetLocked(false);
		-- hand the anchors back first, then measure the game's own spot
		MoveFPS_ApplyPosition();
		MoveFPS_ApplySize();
		MoveFPS_StoreGamePlacement();
		MoveFPS_PlaceWindow();
	elseif options then
		options:SetShown(not options:IsShown());
	end
end

--[[
    Unit Test Suite for Move FPS Counter
    Run with: lua5.1 tests/test_movefps.lua   (from the addon root)

    Drives the addon over the shared mock client (../shared/wow_test_env.lua)
    through the shared suite library (tests/lib.lua: assert helpers, the
    classic/modern counter worlds mirroring source 1.15.9/12.1.0, session
    booting, window drivers). World builders and drivers live in the lib so
    the unit suite and the two integration sims exercise identical worlds.
--]]

local env = dofile("../shared/wow_test_env.lua");
local lib = dofile("tests/lib.lua").init(env);
local out = env.rawPrint;
local ok, same, P = lib.ok, lib.same, lib.P;
local BootSession, WindowOpen, WindowClose, TypeIn, Click = lib.BootSession, lib.WindowOpen, lib.WindowClose, lib.TypeIn, lib.Click;
local Slash, DriveMenu, PickMenuEntry = lib.Slash, lib.DriveMenu, lib.PickMenuEntry;
local BuildClassicWorld, BuildRetailWorld = lib.BuildClassicWorld, lib.BuildRetailWorld;

-- ----------------------------------------------------------------------------
-- Static check: every XML template the addon references must exist in the
-- client source dumps (mocks ignore templates, so this is the only guard we
-- have). 1.15.9 covers the classic family, 12.1.0 covers modern clients.
-- ----------------------------------------------------------------------------
do
    local src = io.open("Move_FPS_Counter.lua", "r");
    local body = src and src:read("*a");
    if src then src:close(); end
    for tmpl in body and body:gmatch('"([%w]+Template)"') or function() end do
        local hit = false;
        for _, ver in ipairs({ "1.15.9", "12.1.0" }) do
            local p = io.popen(("grep -rl --include='*.xml' --include='*.lua' '%s' ../source/%s/Interface/AddOns 2>/dev/null | head -n 1"):format(tmpl, ver));
            local line = p and p:read("*l");
            if p then p:close(); end
            if line then hit = true; break; end
        end
        ok(hit, "template exists in a client dump: " .. tmpl);
    end
end

-- ----------------------------------------------------------------------------
-- config window on classic
-- ----------------------------------------------------------------------------
out("config window (classic world):");

do
    local label, text = unpack(BootSession(nil, BuildClassicWorld));
    local db = _G.Move_FPS_Counter;

    ok(env:FindFrame("Move_FPS_CounterOptions") ~= nil, "options window built");
    ok(env:FindFrame("Move_FPS_CounterOptions").anchorBtn ~= nil, "anchor picker built");
    ok(#env.printLog == 2 and env.printLog[1]:find("|cFFDF9F1F", 1, true) == 1
        and env.printLog[1]:find("/movefps", 1, true) ~= nil
        and env.printLog[2]:find("/movefps reset", 1, true) ~= nil,
        "fresh install prints the orange chat tutorial with white commands");
    local chatBaseline = #env.printLog;

    -- fresh install: game placement, counter remembered on
    ok(db.placed == false, "fresh install keeps the game placement");
    ok(same(P(label:GetPoint(1)), {"BOTTOM", _G.WorldFrame, "BOTTOM", 0, 64}), "default anchors untouched on fresh install");
    ok(text:IsShown(), "counter restored on (remember + toggle defaults)");
    ok(db.toggle == true, "restore before hooking does not count as a user toggle");
    ok(db.size == 12, "size defaults to the game's own size", tostring(db.size));

    local options = WindowOpen();
    local proxy = env:FindFrame("Move_FPS_CounterDragProxy");
    ok(options:IsShown() and proxy == nil, "window opens without move mode (no proxy built yet)");
    ok(text:IsShown(), "hidden counter is force-shown as a live preview");
    ok(options.moveBtn:GetText() == "move counter", "move button starts inactive");
    ok(options.xBox:GetText() == "0.00" and options.yBox:GetText() == "-313.00",
        "boxes show the game-default spot (measured, center-relative)", options.xBox:GetText() .. "," .. options.yBox:GetText());
    ok(options.sizeBox:GetText() == "12.0", "size box shows the game default size", options.sizeBox:GetText());
    ok(same(P(options.moveBtn:GetPoint(1)), {"TOP", options, "TOP", 0, -6}), "move button sits centered at the top");
    ok(options:GetSize() == 292 and select(2, options:GetSize()) == 184, "window is snug around its elements", options:GetSize() .. "x" .. select(2, options:GetSize()));
    ok(options.xLabel ~= nil and same(P(options.xLabel:GetPoint(1)), {"RIGHT", options.xBox, "LEFT", -12, 0}), "x label right-anchored to its box, vertically centered");
    ok(same(P(options.yLabel:GetPoint(1)), {"RIGHT", options.yBox, "LEFT", -12, 0}), "y label right-anchored to its box, vertically centered");
    ok(same(P(options.xBox:GetPoint(1)), {"TOPLEFT", options, "TOPLEFT", 52, -32}), "x box in the left position");
    ok(same(P(options.yBox:GetPoint(1)), {"TOPLEFT", options, "TOPLEFT", 176, -32}), "y box right edge aligns with the slider and dropdown");
    ok(options.xBox.fontObject == "GameFontHighlight" and options.yBox.fontObject == "GameFontHighlight"
        and options.sizeBox.fontObject == "GameFontHighlight",
        "coord/size boxes use the compact font so 7+ glyph values (-100.00 and below) stay visible");
    ok(options.sizeLabel ~= nil and same(P(options.sizeLabel:GetPoint(1)), {"RIGHT", options.sizeBox, "LEFT", -17, 0}), "size label right edge on the shared label line (12px off the visible border, +5px cap protrusion)");
    -- the box frame sits at 101: its left border art protrudes 5px, so the
    -- visible border aligns with the 96 column edge the slider/dropdown use
    ok(same(P(options.sizeBox:GetPoint(1)), {"TOPLEFT", options, "TOPLEFT", 101, -68})
        and same(P(options.decimals:GetPoint(1)), {"TOPLEFT", options, "TOPLEFT", 96, -104})
        and same(P(options.anchorBtn:GetPoint(1)), {"TOPLEFT", options, "TOPLEFT", 96, -128}),
        "size box, decimals slider and anchor dropdown share a visible left edge");
    ok(options.moveBtn:GetWidth() == 140 and options.moveBtn:GetHeight() == 22,
        "move button is wide enough for its Large-font label",
        options.moveBtn:GetWidth() .. "x" .. options.moveBtn:GetHeight());
    ok(same(P(options.rememberLabel:GetPoint(1)), {"TOPLEFT", options, "TOPLEFT", 91, -158})
        and options.rememberLabel:GetText() == "Remember",
        "remember row sits centered below the anchor row");
    ok(same(P(options.remember:GetPoint(1)), {"LEFT", options.rememberLabel, "RIGHT", 8, 0}),
        "remember checkbox sits to the right of its text");

    -- move mode: only now is the counter drag-movable (the proxy is built here)
    Click(options.moveBtn);
    proxy = env:FindFrame("Move_FPS_CounterDragProxy");
    ok(proxy:IsShown() and options.moveBtn:GetText() == "stop moving", "move button enables dragging");
    local square = proxy.square;
    ok(square ~= nil and square:IsShown() and square.r == 0 and square.g == 1 and square.b == 0 and square.a == 0.5,
        "move mode shows a plain green square at 50% alpha",
        square and (tostring(square.r) .. "," .. tostring(square.g) .. "," .. tostring(square.b) .. "," .. tostring(square.a)));
    Click(options.moveBtn);
    ok(not proxy:IsShown() and not proxy.square:IsShown(), "toggling move off removes the green square");
    Click(options.moveBtn);
    ok(proxy:IsShown() and proxy.square:IsShown(), "toggling move on restores the green square");
    ok(same(P(square:GetPoint(1)), {"LEFT", label, "LEFT", 0, 0}),
        "square is a texture inside the counter's hierarchy (text renders above it)");
    ok(proxy:GetNumPoints() == 4
        and same(P(proxy:GetPoint(1)), {"LEFT", label, "LEFT", 0, 0})
        and same(P(proxy:GetPoint(2)), {"RIGHT", text, "RIGHT", 0, 0})
        and same(P(proxy:GetPoint(3)), {"TOP", label, "TOP", 0, 0})
        and same(P(proxy:GetPoint(4)), {"BOTTOM", label, "BOTTOM", 0, 0}),
        "grab area hugs the counter's full visual rectangle");

    -- position via the coordinate boxes
    TypeIn(options.xBox, "-180.755");
    ok(db.x == -180.75 and db.placed == true, "x input is rounded to two decimals", tostring(db.x));
    ok(same(P(label:GetPoint(1)), {"CENTER", UIParent, "CENTER", -180.75, -313}), "x input repositions the counter");
    TypeIn(options.yBox, "88.25");
    ok(db.y == 88.25, "y input is stored as typed");
    TypeIn(options.xBox, "banana");
    ok(db.x == -180.75, "non-numeric input is ignored");
    TypeIn(options.xBox, "999999");
    ok(db.x == -180.75, "out of range input is ignored");

    -- placed: the anchors are locked against everything
    label:ClearAllPoints();
    label:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 1, 2);
    ok(same(P(label:GetPoint(1)), {"CENTER", UIParent, "CENTER", -180.75, 88.25}), "placed anchors survive an external re-anchor attempt");

    -- anchor picker: pin the counter's right edge instead of its center
    local anchorMenu = DriveMenu(options.anchorBtn);
    ok(#anchorMenu == 9, "anchor menu lists all nine anchor points");
    PickMenuEntry(anchorMenu, "RIGHT");
    ok(db.anchor == "RIGHT" and options.anchorBtn:GetText() == "RIGHT", "anchor menu selection shown uppercase");
    local allUppercase = true;
    for _, entry in ipairs(anchorMenu) do
        if entry.text ~= string.upper(entry.text) then allUppercase = false; end
    end
    ok(allUppercase, "anchor menu options are uppercase");
    ok(same(P(label:GetPoint(1)), {"RIGHT", UIParent, "CENTER", -180.75, 88.25}), "anchor point change keeps the stored coords");

    -- dragging: cursor-driven, the counter follows in real time, and the
    -- pinned anchor point lands where the cursor takes it
    -- grab exactly on the anchor point: for a placed counter the addon knows
    -- it is at screen center + db (no measuring involved)
    local pw, ph = UIParent:GetSize();
    env.cursorX, env.cursorY = pw / 2 + db.x, ph / 2 + db.y;
    proxy:GetScript("OnDragStart")(proxy); -- grabbing attaches the drag OnUpdate
    local onUpdate = proxy:GetScript("OnUpdate");
    ok(onUpdate ~= nil, "grabbing the square attaches a drag OnUpdate");
    env.cursorX, env.cursorY = 612, 334; -- drop the anchor point at screen center + (100, -50)
    onUpdate(proxy); -- mid-drag frame
    ok(same(P(label:GetPoint(1)), {"RIGHT", UIParent, "CENTER", 100, -50}),
        "counter follows the cursor in real time during the drag");
    proxy:GetScript("OnDragStop")(proxy);
    ok(db.x == 100 and db.y == -50, "drag stores anchor-relative coordinates", tostring(db.x));
    ok(same(P(label:GetPoint(1)), {"RIGHT", UIParent, "CENTER", db.x, -50}), "dragging moves the counter");
    ok(proxy:GetNumPoints() == 4, "after the drag the square hugs the counter again");
    ok(proxy:GetScript("OnUpdate") == nil, "releasing the square removes the drag OnUpdate");
    ok(options.xBox:GetText() == string.format("%.2f", db.x), "dragging updates the coordinate boxes", options.xBox:GetText());

    -- anchor point change from the menu keeps the stored coords
    PickMenuEntry(anchorMenu, "CENTER");
    ok(same(P(label:GetPoint(1)), {"CENTER", UIParent, "CENTER", db.x, -50}), "anchor menu selection repositions the counter");

    -- leave move mode through the button
    Click(options.moveBtn);
    ok(not proxy:IsShown() and options.moveBtn:GetText() == "move counter", "move button disables dragging again");

    -- size, with one decimal precision (no 0 sentinel: the default is real)
    TypeIn(options.sizeBox, "18.25");
    ok(db.size == 18.3, "size input is rounded to one decimal", tostring(db.size));
    ok(select(2, label:GetFont()) == 18.3 and select(2, text:GetFont()) == 18.3, "fractional size applies to both fontstrings");
    TypeIn(options.sizeBox, "0");
    ok(db.size == 18.3, "size 0 is rejected instead of meaning default", tostring(db.size));
    TypeIn(options.sizeBox, "99");
    ok(db.size == 18.3, "out of range size is ignored");

    -- decimals slider
    options.decimals:SetValue(2);
    ok(db.decimals == 2 and options.decimalsValue:GetText() == "2", "decimals slider stores its value");
    env:Pump(0.5);
    ok(text:GetText() == "59.96", "decimals 2 rewrites Blizzard's format", text:GetText());
    options.decimals:SetValue(0);
    env:Pump(0.5);
    ok(text:GetText() == "60", "decimals 0 rewrites Blizzard's format", text:GetText());
    options.decimals:SetValue(1);
    env:Pump(0.5);
    ok(text:GetText() == "60.0", "decimals 1 passes the original format through", text:GetText());

    -- remember checkbox
    Click(options.remember, false);
    ok(db.remember == false, "remember checkbox stores its state");
    Click(options.remember, true);
    ok(db.remember == true, "remember checkbox toggles back on");

    -- keyboard focus: clicking the world or the window releases the edit boxes
    options.xBox:SetFocus();
    ok(options.xBox:HasFocus(), "edit box takes focus when clicked");
    WorldFrame:GetScript("OnMouseUp")(WorldFrame);
    ok(not options.xBox:HasFocus(), "clicking the world releases keyboard focus");
    options.xBox:SetFocus();
    options:GetScript("OnMouseDown")(options);
    ok(not options.xBox:HasFocus(), "clicking the window releases keyboard focus");

    -- closing the window while move mode is on: the square must go too
    Click(options.moveBtn);
    WindowClose(options);
    ok(not proxy.square:IsShown(), "closing the window hides the square (move mode left via close)");
    WindowOpen();
    Click(options.moveBtn); -- move mode on again
    _G.ToggleFramerate(); -- user hides the counter while the window is open
    ok(db.toggle == false, "hiding through the game flips the remembered state");
    WindowClose(options);
    ok(not proxy:IsShown(), "closing the window leaves move mode");
    ok(not text:IsShown(), "the player's own hide while configuring wins on close");
    WindowOpen();
    WindowClose(options);
    ok(not text:IsShown(), "counter hidden again (our preview force-show is undone)");

    -- silence: the whole session produced no chat output
    ok(#env.printLog == chatBaseline, "no chat output beyond the first-run tutorial");
end

-- ----------------------------------------------------------------------------
-- classic reload round trip + reset
-- ----------------------------------------------------------------------------
out("classic reload + reset:");

do
    local label, text = unpack(BootSession(nil, BuildClassicWorld));
    local db = _G.Move_FPS_Counter;
    local options = WindowOpen();
    TypeIn(options.xBox, "-300.5");
    TypeIn(options.yBox, "88.25");
    TypeIn(options.sizeBox, "16.5");
    options.decimals:SetValue(0);
    _G.ToggleFramerate(); -- user left the counter hidden
    ok(db.toggle == false, "hidden state saved before the reload");

    -- reload: SavedVariables survive env:Reset
    label, text = unpack(BootSession(db, BuildClassicWorld));
    ok(same(P(label:GetPoint(1)), {"CENTER", UIParent, "CENTER", -300.5, 88.25}), "saved position applied at ADDON_LOADED");
    ok(select(2, label:GetFont()) == 16.5, "saved size applied at ADDON_LOADED");
    ok(not text:IsShown(), "counter stays hidden when the user left it hidden");
    _G.ToggleFramerate();
    env:FireEvent("PLAYER_ENTERING_WORLD");
    env:FireEvent("UPDATE_ALL_UI_WIDGETS");
    ok(same(P(label:GetPoint(1)), {"CENTER", UIParent, "CENTER", -300.5, 88.25}), "position intact after login events");
    env:Pump(0.5);
    ok(text:GetText() == "60", "decimals survive the reload", text:GetText());

    options = WindowOpen();
    ok(options.xBox:GetText() == "-300.50" and options.sizeBox:GetText() == "16.5", "window fields reflect the loaded config", options.xBox:GetText());
    ok(math.floor(options.decimals:GetValue() + 0.5) == 0, "decimals slider reflects the loaded config");

    -- reset through the slash command only
    Slash("reset");
    db = _G.Move_FPS_Counter; -- reset replaces the table
    ok(db.placed == false and db.size == 12 and db.decimals == 1 and db.remember == true and db.toggle == true and db.anchor == "CENTER", "reset restores every default (size = game default)");
    ok(same(P(label:GetPoint(1)), {"BOTTOM", _G.WorldFrame, "BOTTOM", 0, 64}), "reset restores the game's own anchors");
    ok(select(2, label:GetFont()) == 12, "reset restores the game's font size");
    ok(options.xBox:GetText() == "0.00" and options.yBox:GetText() == "-313.00",
        "reset refreshes the open window with the measured game-default spot",
        options.xBox:GetText() .. "," .. options.yBox:GetText());
    env:Pump(0.5);
    ok(text:GetText() == "60.0", "reset restores one decimal", text:GetText());

    -- unrecognized slash input toggles the window, always
    WindowClose(options);
    Slash("banana garbage");
    ok(options:IsShown(), "unrecognized input opens the window");
end

-- ----------------------------------------------------------------------------
-- the fpsTime crash: remember off -> reload -> open the config window
-- ----------------------------------------------------------------------------
out("fpsTime crash regression:");

do
    -- the preview force-show must initialize the game's throttle timer, or the
    -- client's WorldFrame_OnUpdate errors every single frame
    local label, text = unpack(BootSession({ placed = false, remember = false, toggle = true }, BuildClassicWorld));
    ok(not text:IsShown(), "counter hidden after the reload (remember off)");
    local options = WindowOpen();
    ok(text:IsShown(), "preview shows the hidden counter");
    local okPump, pumpErr = pcall(env.Pump, env, 0.5);
    ok(okPump, "writer runs without error against the preview-shown counter", pumpErr);
    WindowClose(options);
    ok(not text:IsShown(), "closing restores the hidden state");
end

-- ----------------------------------------------------------------------------
-- remember state machine: every order combination of visibility, the
-- remember flag, the window's preview force-show and reloads
-- ----------------------------------------------------------------------------
out("remember state machine:");

local function ComboTest(name, boot, actions, expectShown)
    local text = select(2, unpack(BootSession(boot, BuildClassicWorld)));
    local db = _G.Move_FPS_Counter;
    actions(text, db);
    text = select(2, unpack(BootSession(db, BuildClassicWorld)));
    ok(text:IsShown() == expectShown and db.toggle == expectShown,
        name, "shown=" .. tostring(text:IsShown()) .. " toggle=" .. tostring(db.toggle));
end

ComboTest("hidden + remember off -> remember on -> reload stays hidden",
    { remember = false },
    function(text, db)
        local options = WindowOpen();
        Click(options.remember, true);
        WindowClose(options);
    end, false);

ComboTest("shown + remember off -> remember on -> reload stays shown",
    { remember = false },
    function(text, db)
        _G.ToggleFramerate(); -- show it
        local options = WindowOpen();
        Click(options.remember, true);
        WindowClose(options);
    end, true);

ComboTest("remember on: show then hide -> reload hidden",
    { remember = true, toggle = false },
    function(text, db)
        _G.ToggleFramerate();
        _G.ToggleFramerate();
    end, false);

ComboTest("remember on: hide -> reload hidden",
    { remember = true, toggle = true },
    function(text, db)
        _G.ToggleFramerate();
    end, false);

ComboTest("remember on: hide then show -> reload shown",
    { remember = true, toggle = true },
    function(text, db)
        _G.ToggleFramerate();
        _G.ToggleFramerate();
    end, true);

ComboTest("remember on: hidden, window preview then game hide -> reload hidden",
    { remember = true, toggle = false },
    function(text, db)
        local options = WindowOpen(); -- preview force-shows
        _G.ToggleFramerate(); -- the player hides it themselves
        WindowClose(options);
    end, false);

ComboTest("remember on: hidden -> open and close window -> reload hidden",
    { remember = true, toggle = false },
    function(text, db)
        local options = WindowOpen();
        WindowClose(options);
    end, false);

ComboTest("remember on: shown, re-check remember in window -> reload shown",
    { remember = true, toggle = true },
    function(text, db)
        local options = WindowOpen();
        Click(options.remember, false);
        Click(options.remember, true);
        WindowClose(options);
    end, true);

ComboTest("remember off: hidden, window preview, game hide, remember on -> reload hidden",
    { remember = false },
    function(text, db)
        local options = WindowOpen(); -- preview force-shows
        _G.ToggleFramerate(); -- the player hides it themselves
        Click(options.remember, true); -- must sync to the actual, not the preview
        WindowClose(options);
    end, false);

ComboTest("remember off: shown, window open, game hide, remember on -> reload hidden",
    { remember = false, toggle = true },
    function(text, db)
        _G.ToggleFramerate(); -- show it
        local options = WindowOpen(); -- snapshot: shown
        _G.ToggleFramerate(); -- the player hides it themselves
        Click(options.remember, true); -- must sync to the actual, not the snapshot
        WindowClose(options);
    end, false);

ComboTest("remember tracked through benchmark toggles",
    { remember = true, toggle = true },
    function(text, db)
        _G.ToggleFramerate(); -- hide first: the game only starts a benchmark while hidden
        _G.ToggleFramerate(true); -- benchmark start: shows
        if not text:IsShown() then error("benchmark did not show"); end
        _G.ToggleFramerate(); -- benchmark end: hides
    end, false);

-- ----------------------------------------------------------------------------
-- bounding box: nothing inside the config window may clip its edges
-- ----------------------------------------------------------------------------
out("config window bounding box:");

do
    -- model the real client's text metrics: every label sits on a font
    -- object bumped +2 points by the addon
    local options = env:FindFrame("Move_FPS_CounterOptions");
    local W, H = options:GetWidth(), options:GetHeight();

    local FONT_SIZES = { GameFontNormal = 12, GameFontHighlight = 12, GameFontNormalLarge = 16, GameFontHighlightLarge = 16 };
    for _, f in ipairs(options.children) do -- fontstrings live on the window
        if f.isFontString and type(f.fontObject) == "string" then
            f.fontSize = FONT_SIZES[f.fontObject] or 12;
            function f:GetStringHeight() return math.ceil((self.fontSize or 12) * 1.25); end
        end
    end

    local children = {};
    for _, f in ipairs(env.frames) do
        if f.parent == options then children[#children + 1] = f; end
    end
    for _, f in ipairs(options.children) do
        children[#children + 1] = f;
    end

    local rects = {};
    local function RectOf(el)
        if rects[el] then return rects[el]; end
        local w, h;
        if el.isFontString then
            w, h = el:GetStringWidth(), el:GetStringHeight();
        else
            w, h = el:GetWidth(), el:GetHeight();
        end
        local point, relTo, relPoint, x, y = el:GetPoint(1);
        local rw;
        if relTo == options then
            rw = { left = 0, top = 0, w = W, h = H };
        else
            rw = rects[relTo] or RectOf(relTo);
        end
        -- reference point: left/center/right column of the reference rect,
        -- top/middle/bottom row of it
        local refX, refY = rw.left, rw.top;
        if relPoint == "TOPRIGHT" or relPoint == "RIGHT" or relPoint == "BOTTOMRIGHT" then
            refX = refX + rw.w;
        elseif relPoint == "TOP" or relPoint == "CENTER" or relPoint == "BOTTOM" then
            refX = refX + rw.w / 2;
        end
        if relPoint == "LEFT" or relPoint == "CENTER" or relPoint == "RIGHT" then
            refY = refY + rw.h / 2;
        elseif relPoint == "BOTTOMLEFT" or relPoint == "BOTTOM" or relPoint == "BOTTOMRIGHT" then
            refY = refY + rw.h;
        end
        local left, top;
        if point == "TOPLEFT" then left, top = refX + x, refY - y;
        elseif point == "TOPRIGHT" then left, top = refX + x - w, refY - y;
        elseif point == "TOP" then left, top = refX + x - w / 2, refY - y;
        elseif point == "LEFT" then left, top = refX + x, refY - y - h / 2;
        elseif point == "RIGHT" then left, top = refX + x - w, refY - y - h / 2;
        elseif point == "CENTER" then left, top = refX + x - w / 2, refY - y - h / 2;
        elseif point == "BOTTOMLEFT" then left, top = refX + x, refY - y - h;
        elseif point == "BOTTOMRIGHT" then left, top = refX + x - w, refY - y - h;
        elseif point == "BOTTOM" then left, top = refX + x - w / 2, refY - y - h;
        end
        rects[el] = { left = left, top = top, w = w, h = h };
        return rects[el];
    end

    local clips = {};
    local PAD = 4; -- required buffer between every element and the window edge
    local MIN_GAP = 2; -- required clearance between two elements
    local named = function(el)
        return el.name or (el.GetText and el:GetText()) or "?";
    end

    local placed = {};
    for _, el in ipairs(children) do
        if el.GetPoint and el:GetPoint(1) and not el.isTexture then
            RectOf(el);
        end
    end
    -- the remember label + checkbox are one element: merge their rects
    if rects[options.rememberLabel] and rects[options.remember] then
        local l, c = rects[options.rememberLabel], rects[options.remember];
        local right = math.max(l.left + l.w, c.left + c.w);
        local bottom = math.max(l.top + l.h, c.top + c.h);
        l.w = right - l.left;
        l.h = bottom - l.top;
    end
    for _, el in ipairs(children) do
        if el.GetPoint and el:GetPoint(1) and not el.isTexture and el ~= options.remember then
            local r = rects[el];
            placed[#placed + 1] = { el = el, r = r };
            if r.left and (r.left < PAD or r.top < PAD or r.left + r.w > W - PAD or r.top + r.h > H - PAD) then
                clips[#clips + 1] = "window edge: " .. named(el)
                    .. (" [%.1f,%.1f +%dx%d]"):format(r.left, r.top, r.w, r.h);
            end
        end
    end
    for i = 1, #placed do
        for j = i + 1, #placed do
            local a, b = placed[i].r, placed[j].r;
            local separated = a.left + a.w + MIN_GAP <= b.left or b.left + b.w + MIN_GAP <= a.left
                or a.top + a.h + MIN_GAP <= b.top or b.top + b.h + MIN_GAP <= a.top;
            if not separated then
                clips[#clips + 1] = "too close: " .. named(placed[i].el) .. " vs " .. named(placed[j].el);
            end
        end
    end
    ok(#clips == 0, "no element clips the config window bounds", table.concat(clips, "; "));
end

-- ----------------------------------------------------------------------------
-- unplaced first grab (reset config): adopts the game-default spot exactly
-- ----------------------------------------------------------------------------
out("unplaced first grab:");

do
    local label2, text2 = unpack(BootSession(nil, BuildClassicWorld));
    local db2 = _G.Move_FPS_Counter;
    local opts = WindowOpen();
    Click(opts.moveBtn);
    local proxy2 = env:FindFrame("Move_FPS_CounterDragProxy");
    local gx, gy = 500, 120; -- grab somewhere on the square
    env.cursorX, env.cursorY = gx, gy;
    proxy2:GetScript("OnDragStart")(proxy2);
    local beforeX, beforeY = label2:GetCenter();
    env.cursorX, env.cursorY = gx + 3, gy + 1; -- 1px-ish move
    proxy2:GetScript("OnUpdate")(proxy2);
    ok(db2.placed == true, "grab marks the counter placed");
    ok(math.abs((db2.x + 512) - beforeX) <= 3.01 and math.abs((db2.y + 384) - beforeY) <= 1.01,
        "adopted position stays within the grab movement", tostring(db2.x) .. "," .. tostring(db2.y));
    ok(same(P(label2:GetPoint(1)), {"CENTER", UIParent, "CENTER", db2.x, db2.y}), "adopted position applied to the counter");
    proxy2:GetScript("OnDragStop")(proxy2);
end

-- ----------------------------------------------------------------------------
-- ui scale: cursor reads and stored coords share one unit space, but the
-- unplaced counter's rect reads (it lives on the unscaled WorldFrame) are in
-- whatever units the flavor uses — the addon must measure that mapping, not
-- assume it. A wrong assumption displaces the counter exactly when the drag
-- engages; the invariant is that grabbing never moves the counter on its own
-- ----------------------------------------------------------------------------
out("ui scale handling:");

do
    local label2, text2 = unpack(BootSession(nil, BuildClassicWorld));
    local db2 = _G.Move_FPS_Counter;
    local SCALE = 0.8;
    _G.UIParent:SetScale(SCALE);
    local function near(a, b) return math.abs(a - b) < 0.011; end

    local wx, wy = label2:GetCenter(); -- the game-default spot
    ok(near(wx, 512) and near(wy, 71), "sanity: default spot is 512, 71", wx .. "," .. wy);

    local opts = WindowOpen();
    Click(opts.moveBtn);
    local proxy2 = env:FindFrame("Move_FPS_CounterDragProxy");
    env.cursorX, env.cursorY = wx, wy; -- grab exactly on the anchor point
    proxy2:GetScript("OnDragStart")(proxy2);
    proxy2:GetScript("OnUpdate")(proxy2);
    ok(near(db2.x, 0) and near(db2.y, -313),
        "scaled ui: first grab stores the game-default spot in stored coords", db2.x .. "," .. db2.y);
    local cx2, cy2 = label2:GetCenter();
    ok(near(cx2, wx) and near(cy2, wy),
        "scaled ui: first grab does not displace the counter", cx2 .. "," .. cy2);

    -- placed drags: the anchor point follows the cursor 1:1
    env.cursorX, env.cursorY = wx + 100, wy - 50;
    proxy2:GetScript("OnUpdate")(proxy2);
    ok(near(db2.x, 100) and near(db2.y, -363),
        "scaled ui: placed drag tracks the cursor 1:1", db2.x .. "," .. db2.y);
    proxy2:GetScript("OnDragStop")(proxy2);
    cx2, cy2 = label2:GetCenter();
    ok(near(cx2, wx + 100) and near(cy2, wy - 50),
        "scaled ui: placed drag lands the anchor under the cursor", cx2 .. "," .. cy2);
end

do
    local frame, _, text = unpack(BootSession(nil, BuildRetailWorld));
    local db3 = _G.Move_FPS_Counter;
    local SCALE = 0.9;
    _G.UIParent:SetScale(SCALE);
    local options = WindowOpen();
    Click(options.moveBtn);
    local proxy3 = env:FindFrame("Move_FPS_CounterDragProxy");
    TypeIn(options.xBox, "40.5");
    TypeIn(options.yBox, "-12.25");
    -- grab the anchor point (screen center + db) and drag by an exact delta
    local pw2, ph2 = UIParent:GetSize();
    local ax, ay = pw2 / 2 + db3.x, ph2 / 2 + db3.y;
    env.cursorX, env.cursorY = ax, ay;
    proxy3:GetScript("OnDragStart")(proxy3);
    env.cursorX, env.cursorY = ax + 90, ay - 45;
    proxy3:GetScript("OnUpdate")(proxy3);
    proxy3:GetScript("OnDragStop")(proxy3);
    ok(db3.x == 130.5 and db3.y == -57.25,
        "scaled modern ui: drag moves the frame by the exact UI-unit delta", db3.x .. "," .. db3.y);
    ok(same(P(frame:GetPoint(1)), {"CENTER", UIParent, "CENTER", 130.5, -57.25}),
        "scaled modern ui: frame anchored at the dropped spot");
end

-- ----------------------------------------------------------------------------
-- schema migration: SavedVariables interop without moving anything
-- ----------------------------------------------------------------------------
out("schema migration (SavedVariables interop):");

do
    -- a v1.9 retail user who configured a position (LEFT point of the label)
    local label = unpack(BootSession(
        { x = 830, y = -320, anchor = "LEFT", remember = true, toggle = false }, BuildClassicWorld));
    local db = _G.Move_FPS_Counter;
    ok(#env.printLog == 2, "v1 table conversion prints the chat tutorial");
    ok(db.anchor == "LEFT" and db.placed == true, "v1.9 retail anchor and placement kept");
    ok(same(P(label:GetPoint(1)), {"LEFT", UIParent, "CENTER", 830, -320}), "v1.9 retail placement preserved verbatim");
    ok(not _G.FramerateText:IsShown(), "v1.9 hidden toggle not restored");
    ok(db.size == 12, "v1.9 table without size gets the game default size", tostring(db.size));
    label = unpack(BootSession(db, BuildClassicWorld));
    ok(#env.printLog == 0, "v2 config reload does not reprint the tutorial");
    ok(same(P(label:GetPoint(1)), {"LEFT", UIParent, "CENTER", 830, -320}), "v1.9 retail config reloads identically");
end

do
    -- a live-v1 mainline user who kept every default: v1 always anchored the
    -- frame LEFT at the screen center; v2 instead gives them the game's own
    -- placement, with their remembered visibility intact
    local frame = unpack(BootSession(
        { x = 0, y = 0, remember = true, toggle = true, anchor = "LEFT" }, BuildRetailWorld));
    local db = _G.Move_FPS_Counter;
    ok(db.placed == false and db.anchor == "LEFT", "v1 mainline default table: game placement, anchor dormant");
    ok(frame:IsShown(), "v1 mainline default table: remembered toggle restored");
end

do
    -- a live-v1 mainline user who configured: v2's anchor point semantics are
    -- identical, so the frame keeps its exact spot and visibility
    local frame = unpack(BootSession(
        { x = -210, y = 55.5, remember = true, toggle = false, anchor = "TOPRIGHT" }, BuildRetailWorld));
    local db = _G.Move_FPS_Counter;
    ok(db.placed == true and db.anchor == "TOPRIGHT", "v1 mainline configured table: anchor kept");
    ok(same(P(frame:GetPoint(1)), {"TOPRIGHT", UIParent, "CENTER", -210, 55.5}), "v1 mainline configured table: position verbatim");
    ok(not frame:IsShown(), "v1 mainline configured table: hidden state kept");
    frame = unpack(BootSession(db, BuildRetailWorld));
    ok(same(P(frame:GetPoint(1)), {"TOPRIGHT", UIParent, "CENTER", -210, 55.5}), "v1 mainline configured table: stable across reload");
end

do
    -- v1's slash parser accepted arbitrarily large coordinates; a stored
    -- position outside the valid range is treated as never configured
    local label = unpack(BootSession(
        { x = 500000, y = -500000, remember = true, toggle = true }, BuildClassicWorld));
    local db = _G.Move_FPS_Counter;
    ok(db.placed == false and db.x == 0 and db.y == -313,
        "v1 out-of-range coords fall back to the measured game placement", db.x .. "," .. db.y);
    ok(same(P(label:GetPoint(1)), {"BOTTOM", _G.WorldFrame, "BOTTOM", 0, 64}), "v1 out-of-range coords keep the game anchors");
end

do
    -- a v1.9 vanilla flavor user: the mover hardcoded the RIGHT point
    local label = unpack(BootSession(
        { x = 25.75, y = -40.5, remember = true, toggle = true }, BuildClassicWorld));
    local db = _G.Move_FPS_Counter;
    ok(db.anchor == "RIGHT", "vanilla flavor placement gets its RIGHT point backfilled");
    ok(same(P(label:GetPoint(1)), {"RIGHT", UIParent, "CENTER", 25.75, -40.5}), "vanilla flavor placement preserved verbatim");
end

do
    -- tables from the unpublished center-coords build: anchor=CENTER keeps
    -- their meaning identical
    local label = unpack(BootSession(
        { x = 100, y = -50, placed = true, size = 0, decimals = 1, remember = true, toggle = true }, BuildClassicWorld));
    local db = _G.Move_FPS_Counter;
    ok(db.anchor == "CENTER" and db.placed == true, "center-coords build gets CENTER backfilled");
    ok(same(P(label:GetPoint(1)), {"CENTER", UIParent, "CENTER", 100, -50}), "center-coords build unchanged");
end

do
    -- a v1.9 user who never moved the counter: they were seeing it mid-screen;
    -- they now get the game's own placement instead
    local label = unpack(BootSession(
        { x = 0, y = 0, remember = true, toggle = true }, BuildClassicWorld));
    local db = _G.Move_FPS_Counter;
    ok(db.placed == false, "untouched default migrates to game placement");
    ok(same(P(label:GetPoint(1)), {"BOTTOM", _G.WorldFrame, "BOTTOM", 0, 64}), "migrated user sits at the game default, not mid-screen");
end

do
    -- corrupt values are sanitized
    local label = unpack(BootSession(
        { x = "banana", y = 3, anchor = "WEIRD", size = 99, decimals = 7, placed = true }, BuildClassicWorld));
    local db = _G.Move_FPS_Counter;
    ok(db.x == 0 and db.size == 12 and db.decimals == 1 and db.anchor == "CENTER", "corrupt values sanitized at load (size = game default)");
    ok(same(P(label:GetPoint(1)), {"CENTER", UIParent, "CENTER", 0, 3}), "sanitized config applied");
end

-- ----------------------------------------------------------------------------
-- modern world
-- ----------------------------------------------------------------------------
out("config window (modern world):");

do
    local frame, label, text = unpack(BootSession(nil, BuildRetailWorld));
    local db = _G.Move_FPS_Counter;
    ok(same(P(frame:GetPoint(1)), {"TOPRIGHT", _G.MicroMenuContainer, "TOPLEFT", -5, -5}), "micro menu anchoring untouched on fresh install");
    ok(frame:IsShown(), "counter restored on");

    -- while unplaced, Blizzard's own re-anchoring still applies
    frame:UpdatePosition("BOTTOMLEFT", "BOTTOMRIGHT", 5, 0);
    ok(same(P(frame:GetPoint(1)), {"BOTTOMLEFT", _G.MicroMenuContainer, "BOTTOMRIGHT", 5, 0}), "unplaced counter follows the micro menu like stock");

    local options = WindowOpen();
    Click(options.moveBtn);
    local proxy = env:FindFrame("Move_FPS_CounterDragProxy");
    ok(proxy ~= nil and proxy:IsShown(), "move mode shows the preview over the frame");
    TypeIn(options.xBox, "40.5");
    TypeIn(options.yBox, "-12.25");
    ok(same(P(frame:GetPoint(1)), {"CENTER", UIParent, "CENTER", 40.5, -12.25}), "coordinates applied to the whole frame");
    -- once placed, Blizzard's re-anchoring cannot displace it
    frame:UpdatePosition("TOPRIGHT", "TOPLEFT", -5, -5);
    ok(same(P(frame:GetPoint(1)), {"CENTER", UIParent, "CENTER", 40.5, -12.25}), "placed counter ignores Blizzard's re-anchoring");

    -- drag the preview with a TOPLEFT anchor: the drop pins the anchor point
    local anchorMenu = DriveMenu(options.anchorBtn);
    PickMenuEntry(anchorMenu, "TOPLEFT");
    ok(db.anchor == "TOPLEFT" and same(P(frame:GetPoint(1)), {"TOPLEFT", UIParent, "CENTER", 40.5, -12.25}), "anchor picker re-anchors the frame");
    -- grab the frame's top-left corner (its anchor point), drop it at
    -- screen center + (-60, 10.5)
    local pw2, ph2 = UIParent:GetSize();
    env.cursorX, env.cursorY = pw2 / 2 + db.x, ph2 / 2 + db.y; -- the frame's top-left corner
    proxy:GetScript("OnDragStart")(proxy); -- grabbing attaches the drag OnUpdate
    local onUpdate = proxy:GetScript("OnUpdate");
    ok(onUpdate ~= nil, "grabbing the square attaches a drag OnUpdate");
    env.cursorX, env.cursorY = 452, 394.5;
    onUpdate(proxy); -- mid-drag frame: the frame follows in real time
    ok(same(P(frame:GetPoint(1)), {"TOPLEFT", UIParent, "CENTER", -60, 10.5}),
        "counter follows the cursor in real time during the drag");
    proxy:GetScript("OnDragStop")(proxy);
    ok(db.x == -60 and db.y == 10.5, "drag stores anchor-relative coordinates", tostring(db.x));
    ok(same(P(frame:GetPoint(1)), {"TOPLEFT", UIParent, "CENTER", db.x, db.y}), "dragging moves the frame");
    ok(proxy:GetNumPoints() == 2
        and same(P(proxy:GetPoint(1)), {"TOPLEFT", frame, "TOPLEFT", 0, 0})
        and same(P(proxy:GetPoint(2)), {"BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0}),
        "after the drag the square hugs the frame again");
    ok(proxy:GetScript("OnUpdate") == nil, "releasing the square removes the drag OnUpdate");

    -- the localized CPU/GPU-bound formats keep their prefix, only decimals change
    options.decimals:SetValue(2);
    lib.cpuBound = true;
    env:Pump(0.5);
    ok(text:GetText() == "CPU bound: 59.96", "cpu bound format with decimals 2", text:GetText());
    lib.cpuBound = false;
    env:Pump(0.5);
    ok(text:GetText() == "GPU bound: 59.96", "gpu bound format with decimals 2", text:GetText());
    lib.cpuBound = nil;

    -- window position persists for the next session
    options:ClearAllPoints();
    options:SetPoint("CENTER", UIParent, "CENTER", 120, -30);
    options:GetScript("OnDragStop")(options);
    ok(db.win.x == 120 and db.win.y == -30, "window position saved on drag");

    frame:Toggle(); -- user hides through the game
    frame, label, text = unpack(BootSession(db, BuildRetailWorld));
    ok(not frame:IsShown(), "counter stays hidden after reload");
    options = WindowOpen();
    ok(frame:IsShown(), "preview force-shows the hidden counter");
    ok(same(P(frame:GetPoint(1)), {"TOPLEFT", UIParent, "CENTER", db.x, db.y}), "saved position survives reload");
    ok(same(P(options:GetPoint(1)), {"CENTER", UIParent, "CENTER", 120, -30}), "window reopens where it was left");
    WindowClose(options);
    ok(not frame:IsShown(), "closing the preview restores the hidden state");

    Slash("reset");
    db = _G.Move_FPS_Counter; -- reset replaces the table
    ok(db.placed == false and db.size == 12 and db.decimals == 1 and db.anchor == "CENTER", "reset restores the defaults");
    ok(same(P(frame:GetPoint(1)), {"TOPRIGHT", _G.MicroMenuContainer, "TOPLEFT", -5, -5}), "reset restores the game's micro menu anchoring");
end

-- ----------------------------------------------------------------------------
-- anchor picker fallback (no menu system available)
-- ----------------------------------------------------------------------------
out("anchor picker fallback:");

do
    local label = unpack(BootSession({ placed = true, x = 10, y = -10, anchor = "CENTER" }, function()
        env.failTemplates = { "WowStyle1DropdownTemplate" }; -- must be set after env:Reset
        return BuildClassicWorld();
    end));
    local db = _G.Move_FPS_Counter;
    local options = env:FindFrame("Move_FPS_CounterOptions");
    ok(options.anchorBtn ~= nil, "fallback anchor button built when the dropdown template is missing");
    Click(options.anchorBtn);
    ok(db.anchor == "TOP" and same(P(label:GetPoint(1)), {"TOP", UIParent, "CENTER", 10, -10}), "fallback button cycles the anchor");
    Click(options.anchorBtn);
    ok(db.anchor == "TOPRIGHT", "fallback button keeps cycling");
    env.failTemplates = nil;
end

-- ----------------------------------------------------------------------------
-- unknown client layout
-- ----------------------------------------------------------------------------
out("unknown client layout:");

do
    BootSession(nil, function() end);
    local okLoad, err = pcall(function()
        Slash("");
        Slash("reset");
    end);
    ok(okLoad, "inert client ignores the window and reset without erroring", err);
    ok(_G.Move_FPS_Counter == nil, "unknown layout leaves saved variables untouched");
end

lib.done();

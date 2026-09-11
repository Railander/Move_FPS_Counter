--[[
    Restriction-discipline suite for Move FPS Counter on the SHARED harness.

    Straps the addon to shared/wow_test_env.lua (mock client) +
    shared/wow_restriction_sim.lua (12.x enforcement layer: SecretArguments
    gates, dispatch-false query semantics, hooksecurefunc taint).

    Run from the addon root: lua5.1 tests/sim_restrictions.lua
    Prints PASS:/FAIL: lines, ends with "Test Results: N passed, M failed",
    os.exit(1) on any failure. Output via env.rawPrint (print is captured).

    Harness adaptations (documented, not worked around):
    - tests/lib.lua is NOT reused here: its ClearWorld nils hooksecurefunc and
      its builders reinstall a naive hooksecurefunc, which would clobber the
      sim's taint tracker. The minimal worlds below preserve every sim gate.
    - Hidden frames receive no OnUpdate here, so drag scripts are driven by hand.
    - The retail Toggle mock chains the show/hide scripts, modelling the
      client's Toggle->SetShown->script dispatch (same as tests/lib.lua).
]]

local env = dofile("../shared/wow_test_env.lua");
local rs = dofile("../shared/wow_restriction_sim.lua");

local PASS, FAIL = 0, 0;
local function ok(cond, name, extra)
    if cond then PASS = PASS + 1; env.rawPrint("  PASS: " .. name);
    else FAIL = FAIL + 1; env.rawPrint("  FAIL: " .. name .. (extra and (" -- " .. tostring(extra)) or "")); end
end

local SCREEN_W, SCREEN_H = 1024, 768;
local DEFAULT_FONT = "Fonts\\FRIZQT__.TTF";

-- anchor-aware rect reads, mirroring the client's geometry (same as lib.lua)
local POINT_OFF = {
    CENTER = { 0, 0 }, TOP = { 0, -0.5 }, BOTTOM = { 0, 0.5 },
    LEFT = { 0.5, 0 }, RIGHT = { -0.5, 0 },
    TOPLEFT = { 0.5, 0.5 }, TOPRIGHT = { -0.5, 0.5 },
    BOTTOMLEFT = { 0.5, -0.5 }, BOTTOMRIGHT = { -0.5, -0.5 },
};
local REL_OFF = {
    CENTER = { 0.5, 0.5 }, TOP = { 0.5, 1 }, BOTTOM = { 0.5, 0 },
    LEFT = { 0, 0.5 }, RIGHT = { 1, 0.5 },
    TOPLEFT = { 0, 1 }, TOPRIGHT = { 1, 1 },
    BOTTOMLEFT = { 0, 0 }, BOTTOMRIGHT = { 1, 0 },
};
local function installRect(region)
    function region:GetCenter()
        local p = self.points[1];
        if not p then return (self.w or 0) / 2, (self.h or 0) / 2; end
        local tw = p.relativeTo and p.relativeTo.GetWidth and p.relativeTo:GetWidth() or 0;
        local th = p.relativeTo and p.relativeTo.GetHeight and p.relativeTo:GetHeight() or 0;
        local ro = REL_OFF[p.relativePoint] or REL_OFF.CENTER;
        local po = POINT_OFF[p.point] or POINT_OFF.CENTER;
        return ro[1] * tw + (p.x or 0) + po[1] * (self.w or 0),
               ro[2] * th + (p.y or 0) + po[2] * (self.h or 0);
    end
    function region:GetLeft() local cx = self:GetCenter(); return cx - (self.w or 0) / 2; end
    function region:GetRight() local cx = self:GetCenter(); return cx + (self.w or 0) / 2; end
    function region:GetTop() local _, cy = self:GetCenter(); return cy + (self.h or 0) / 2; end
    function region:GetBottom() local _, cy = self:GetCenter(); return cy - (self.h or 0) / 2; end
end

local function makeFonts(label, text)
    label:SetFont(DEFAULT_FONT, 12);
    text:SetFont(DEFAULT_FONT, 12);
    label.w, label.h = 60, 14;
    function text:SetFormattedText(format, ...) self:SetText(string.format(format, ...)); end
end

-- Retail world on top of the sim's seeded (Blizzard-owned, gated) frames.
local function buildRetail()
    _G.GetFramerate = function() return 59.96; end;
    _G.IsCpuBound = function() return nil; end;
    _G.FPS_COUNTER_CPU_BOUND = "CPU bound: %.1f";
    _G.FPS_COUNTER_GPU_BOUND = "GPU bound: %.1f";
    _G.MicroMenuContainer = CreateFrame("Frame", "MicroMenuContainer");
    local frame = _G.FramerateFrame;
    frame:Hide();
    frame:SetPoint("TOPRIGHT", _G.MicroMenuContainer, "TOPLEFT", -5, -5);
    local label = frame:CreateFontString(nil, "ARTWORK");
    local text = frame:CreateFontString(nil, "ARTWORK");
    makeFonts(label, text);
    label:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0);
    text:SetPoint("LEFT", label, "RIGHT", 0, 0);
    frame.Label = label; frame.FramerateText = text;
    frame:SetSize(72, 14);
    -- NOTE: no SetShown override here (unlike tests/lib.lua): Toggle must hit
    -- the sim-gated SetShown, exactly like the client's C call, so the locked
    -- Toggle blocks instead of slipping through a Lua shortcut.
    function frame:Toggle()
        local willShow = not self:IsShown();
        self:SetShown(willShow);
        local s = self:GetScript(willShow and "OnShow" or "OnHide");
        if s then s(self); end
    end
    function frame:UpdatePosition(point, relativePoint, x, y)
        self:ClearAllPoints();
        self:SetPoint(point, _G.MicroMenuContainer, relativePoint, x, y);
    end
    installRect(frame);
    return frame, label, text;
end

-- Classic world: the real classic client has NO FramerateFrame global, so the
-- sim's seed is cleared first (same as tests/lib.lua ClearWorld).
local function buildClassic()
    _G.FramerateFrame = nil;
    local world = _G.WorldFrame;
    world:SetSize(SCREEN_W, SCREEN_H);
    world:Show();
    local label = world:CreateFontString("FramerateLabel", "ARTWORK");
    local text = world:CreateFontString("FramerateText", "ARTWORK");
    makeFonts(label, text);
    label:SetPoint("BOTTOM", world, "BOTTOM", 0, 64);
    text:SetPoint("LEFT", label, "RIGHT", 0, 0);
    label:Hide(); text:Hide();
    installRect(label); installRect(text);
    _G.FramerateLabel = label; _G.FramerateText = text;
    _G.GetFramerate = function() return 59.96; end;
    _G.ToggleFramerate = function(benchmark)
        text.benchmark = benchmark;
        if text:IsShown() then label:Hide(); text:Hide(); else label:Show(); text:Show(); end
        _G.WorldFrame.fpsTime = 0;
    end
    return label, text;
end

-- Minimal window drivers (mock Show chains no scripts; fire them by hand).
local function WindowOpen()
    SlashCmdList.MOVEFPS("");
    local options;
    for i = #env.frames, 1, -1 do
        if env.frames[i]:GetName() == "Move_FPS_CounterOptions" then options = env.frames[i]; break; end
    end
    if options then
        if not options:IsShown() then options:Show(); end
        local s = options:GetScript("OnShow");
        if s then s(options); end
    end
    return options;
end
local function WindowClose(options)
    options:Hide();
    local s = options:GetScript("OnHide");
    if s then s(options); end
end
local function TypeIn(box, value)
    box:SetText(value);
    local s = box:GetScript("OnEnterPressed");
    if s then s(box); end
end
local function Click(widget, checked)
    if checked ~= nil then widget:SetChecked(checked); end
    local s = widget:GetScript("OnClick");
    if s then s(widget); end
end
local function findProxy()
    for i = #env.frames, 1, -1 do
        if env.frames[i]:GetName() == "Move_FPS_CounterDragProxy" then return env.frames[i]; end
    end
    return nil;
end
local function newViolations(base)
    local out = {};
    for i = base + 1, #env.restrictionViolations do
        out[#out + 1] = env.restrictionViolations[i].api;
    end
    return out;
end
local function onlyFrom(list, allowed)
    for _, api in ipairs(list) do
        if not allowed[api] then return false, api; end
    end
    return true;
end
local function pointOf(region)
    local a, b, c, d, e = region:GetPoint(1);
    if type(b) == "table" then b = b:GetName() or "?"; end
    return table.concat({ tostring(a), tostring(b), tostring(c), tostring(d), tostring(e) }, "|");
end

-- Boot under MAX restrictions: the /reload-in-combat trap (retail). The world
-- itself is built clear first (Blizzard frames anchor before combat; only the
-- ADDON load lands mid-protection), then the lock slams on for the load.
rs.Enable(env, { scenario = "none", flavor = "mainline" });
_G.UIParent:SetSize(SCREEN_W, SCREEN_H);
buildRetail();
env:ActivateAllRestrictions();
env:ClearViolations();
_G.Move_FPS_Counter = nil;
assert(loadfile("Move_FPS_Counter.lua"))();
env:FireEvent("ADDON_LOADED", "Move_FPS_Counter");

env.rawPrint("== R1: max boot defers everything; only listener install touches gates ==");
do
    local fresh = newViolations(0);
    ok(#fresh == 8, "boot touches exactly 8 gated calls (7 events + 1 script)", #fresh);
    local clean, bad = onlyFrom(fresh, { ["Frame:RegisterEvent"] = true, ["Frame:SetScript"] = true });
    ok(clean, "boot violations are listener-install only", bad);
    ok(_G.Move_FPS_Counter == nil, "saved state untouched: ADDON_LOADED unheard while deaf");
    ok(env:FindFrame("Move_FPS_CounterOptions") == nil, "options window NOT half-built while protected");
end

env.rawPrint("== R2: slash self-heal attempt while locked is fully silent ==");
do
    local base = #env.restrictionViolations;
    SlashCmdList.MOVEFPS(""); -- lazy state load (pure Lua) + deferred gated init
    ok(#newViolations(base) == 0, "locked slash logs nothing");
    local db = _G.Move_FPS_Counter;
    ok(db ~= nil and db.placed == false, "state loaded (game placement) while gates wait");
    ok(#env.printLog == 0, "first-run greet queued, not printed into lockdown (best-effort)");
    ok(env:FindFrame("Move_FPS_CounterOptions") == nil, "options still unbuilt while locked");
    base = #env.restrictionViolations;
    SlashCmdList.MOVEFPS("reset"); -- db-only work lands, applies queue
    ok(#newViolations(base) == 0, "locked reset logs nothing");
    ok(_G.Move_FPS_Counter.placed == false, "reset db correct while applies wait");
end

env.rawPrint("== R3: lift resumes everything with zero gates ==");
do
    env:DeactivateAllRestrictions();
    env:ClearViolations();
    SlashCmdList.MOVEFPS(""); -- self-heal: full gated init runs once clear
    ok(#env.restrictionViolations == 0, "lift init is clean");
    local db = _G.Move_FPS_Counter;
    local frame = _G.FramerateFrame;
    ok(db.placed == false, "game placement kept after lift");
    ok(pointOf(frame) == "TOPRIGHT|MicroMenuContainer|TOPLEFT|-5|-5", "game anchors applied", pointOf(frame));
    ok(frame:IsShown(), "remembered toggle restored on lift");
    local options = env:FindFrame("Move_FPS_CounterOptions");
    ok(options ~= nil and options.anchorBtn ~= nil, "options + anchor picker built on lift");
    ok(#env.printLog == 2 and env.printLog[1]:find("/movefps", 1, true) ~= nil,
        "queued first-run greet printed once clear");
end

env.rawPrint("== R4: visibility tracked with zero hooksecurefunc taint ==");
do
    env:ClearViolations();
    local frame = _G.FramerateFrame;
    ok(frame:GetScript("OnShow") ~= nil and frame:GetScript("OnHide") ~= nil,
        "retail tracks via Show/Hide post-hooks (sanctioned form)");
    ok(#env.taintedHooks == 0, "never hooksecurefunc'd a Blizzard Lua method");
    frame:Toggle(); -- user hides through the game
    local db = _G.Move_FPS_Counter;
    ok(not frame:IsShown() and db.toggle == false, "game toggle tracked through the hooks");
    frame:Toggle();
    ok(frame:IsShown() and db.toggle == true, "game re-show tracked");
    ok(#env.restrictionViolations == 0, "tracking while clear touches no gates");
end

env.rawPrint("== R5: activation mid-drag cancels without writes or gates ==");
do
    local db = _G.Move_FPS_Counter;
    -- capture gated-readable handlers while clear: GetScript itself is gated
    -- while locked, so every locked driver below uses these references.
    local capOptions = env:FindFrame("Move_FPS_CounterOptions");
    local enterX = capOptions.xBox:GetScript("OnEnterPressed");
    local enterY = capOptions.yBox:GetScript("OnEnterPressed");
    local enterSize = capOptions.sizeBox:GetScript("OnEnterPressed");
    local onShow = capOptions:GetScript("OnShow");
    local onHide = capOptions:GetScript("OnHide");
    local function openW(o) if not o:IsShown() then o:Show(); end onShow(o); return o; end
    local function closeW(o) o:Hide(); onHide(o); end
    local function typeIn(box, fn, v) box:SetText(v); fn(box); end
    -- drive the dropdown generator with a fake root description (mock frames
    -- record it via SetupMenu, same as tests/lib.lua DriveMenu)
    local function pickAnchor(dd, data)
        local root = {};
        function root:CreateRadio(text, isSelected, setSelected, d)
            self[#self + 1] = { setSelected = setSelected, data = d };
        end
        dd:GetMenuGenerator()(dd, root);
        for _, entry in ipairs(root) do
            if entry.data == data then entry.setSelected(data); return true; end
        end
        return false;
    end
    _G.MoveFPS_testHooks = { enterX = enterX, enterY = enterY, enterSize = enterSize,
        onShow = onShow, onHide = onHide, openW = openW, closeW = closeW,
        typeIn = typeIn, pickAnchor = pickAnchor };

    local options = openW(capOptions);
    Click(options.moveBtn);
    local proxy = findProxy();
    ok(proxy ~= nil and proxy:IsShown(), "move mode on while clear");
    local pw, ph = UIParent:GetSize();
    env.cursorX, env.cursorY = pw / 2 + 25.5, ph / 2 - 12.25;
    -- configure + grab while clear (placed from here on)
    local H = _G.MoveFPS_testHooks;
    H.typeIn(options.xBox, H.enterX, "25.5");
    H.typeIn(options.yBox, H.enterY, "-12.25");
    proxy:GetScript("OnDragStart")(proxy);
    ok(proxy:GetScript("OnUpdate") ~= nil, "drag OnUpdate attached");
    env.cursorX, env.cursorY = 612, 334;
    proxy:GetScript("OnUpdate")(proxy);
    local midX, midY = db.x, db.y;
    -- capture the frame BEFORE the lock: GetScript itself is gated while active
    local dragUpdate = proxy:GetScript("OnUpdate");
    env:ClearViolations();
    env:FireRestrictionChange("Combat", 2); -- Activating edge locks
    ok(not proxy:IsShown(), "activation hides the grab area");
    dragUpdate(proxy); -- stray frames after the lock
    dragUpdate(proxy);
    ok(db.x == midX and db.y == midY, "post-lock frames persist nothing", db.x .. "," .. db.y);
    ok(#env.restrictionViolations == 0, "activation path touches no gates");
    _G.MoveFPS_testHooks.closeW(options);
end

env.rawPrint("== R6: inputs while locked queue silently, flush on lift ==");
do
    local H = _G.MoveFPS_testHooks;
    local db = _G.Move_FPS_Counter;
    local options = H.openW(env:FindFrame("Move_FPS_CounterOptions"));
    env:ClearViolations();
    H.typeIn(options.xBox, H.enterX, "111.25");
    ok(db.x == 111.25, "locked x input lands in db (pure Lua)");
    H.typeIn(options.sizeBox, H.enterSize, "20");
    ok(db.size == 20, "locked size input lands in db");
    ok(H.pickAnchor(options.anchorBtn, "RIGHT"), "locked anchor pick runs");
    ok(db.anchor == "RIGHT", "locked anchor lands in db");
    ok(#env.restrictionViolations == 0, "locked inputs log nothing");
    local frame = _G.FramerateFrame;
    local before = pointOf(frame);
    ok(before == "CENTER|UIParent|CENTER|100|-50", "locked inputs apply nothing yet", before);
    env:DeactivateAllRestrictions();
    env:ClearViolations();
    env:FireEvent("PLAYER_REGEN_ENABLED"); -- backstop refresh flushes the queue
    ok(#env.restrictionViolations == 0, "lift flush is clean");
    ok(pointOf(frame) == "RIGHT|UIParent|CENTER|111.25|-50", "queued position+anchor applied on lift", pointOf(frame));
    local _, size = frame.Label:GetFont();
    ok(size == 20, "queued size applied on lift", tostring(size));
    _G.MoveFPS_testHooks.closeW(options);
end

env.rawPrint("== R7: restriction-event payload protocol lifts via out-of-dispatch confirm ==");
do
    env:SetRestriction("Encounter", rs.ACTIVE);
    env:ClearViolations();
    env:FireRestrictionChange("Encounter", 2);
    local db = _G.Move_FPS_Counter;
    local H = _G.MoveFPS_testHooks;
    H.typeIn(env:FindFrame("Move_FPS_CounterOptions").xBox, H.enterX, "77.5");
    ok(db.x == 77.5, "write queued under Encounter lock");
    env:FireRestrictionChange("Encounter", 0); -- Inactive applies first, then dispatches
    env:Pump(0.1); -- the C_Timer.After(0) confirm runs outside dispatch
    ok(pointOf(_G.FramerateFrame) == "RIGHT|UIParent|CENTER|77.5|-50",
        "queued write flushed on confirm", pointOf(_G.FramerateFrame));
    ok(#env.restrictionViolations == 0, "confirm path touches no gates");
    env:DeactivateAllRestrictions();
end

env.rawPrint("== R8: retail Toggle while locked cannot desync remembered state ==");
do
    env:ActivateAllRestrictions();
    env:ClearViolations();
    local frame = _G.FramerateFrame;
    local db = _G.Move_FPS_Counter;
    local shownBefore, toggleBefore = frame:IsShown(), db.toggle;
    frame:Toggle(); -- the TEST's own gated call: SetShown + GetScript block
    ok(frame:IsShown() == shownBefore, "gated Toggle changes nothing while locked");
    ok(db.toggle == toggleBefore, "remembered state cannot desync while locked");
    env:ClearViolations(); -- drop the test's own two violations from the log
    env:DeactivateAllRestrictions();
    ok(#env.restrictionViolations == 0, "log clean after lift");
end

env.rawPrint("== R9: classic flavor at max logs nothing by construction ==");
do
    rs.Enable(env, { scenario = "max", flavor = "classic" });
    _G.UIParent:SetSize(SCREEN_W, SCREEN_H);
    buildClassic();
    env:ClearViolations();
    _G.Move_FPS_Counter = nil;
    assert(loadfile("Move_FPS_Counter.lua"))();
    env:FireEvent("ADDON_LOADED", "Move_FPS_Counter");
    ok(#env.restrictionViolations == 0, "classic max boot is clean (no gate system)");
    local db = _G.Move_FPS_Counter;
    ok(db ~= nil and db.placed == false, "classic state loaded immediately, game placement");
    ok(env:FindFrame("Move_FPS_CounterOptions") ~= nil, "classic options built immediately");
    env:ClearViolations();
    -- NOTE: the sim models string-form hooksecurefunc as inert (it installs
    -- nothing), so classic toggle tracking cannot fire here; it is covered by
    -- the unit suites (lib.lua installs a working hooksecurefunc) and was
    -- validated in game on 1.15. What the sim proves: the install is clean.
    _G.ToggleFramerate();
    ok(#env.restrictionViolations == 0, "classic toggle path ungated at max");
    _G.FramerateLabel:SetPoint("CENTER", UIParent, "CENTER", 10, 10);
    ok(#env.restrictionViolations == 0, "classic frames stay ungated at max");
    ok(#env.taintedHooks == 0, "classic global hook is inert (no taint)");
    env:ClearViolations();
    _G.LearnPvpTalent(1, 1);
    _G.SendChatMessage("hi");
    ok(#env.restrictionViolations == 0, "classic chat/talent calls ungated at max");
end

env.rawPrint(("\nTest Results: %d passed, %d failed"):format(PASS, FAIL));
if FAIL > 0 then os.exit(1); end

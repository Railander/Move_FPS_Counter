--[[
    Integration Sim for Move FPS Counter -- modern client session
    Run with: lua5.1 tests/sim_mainline.lua   (from the addon root)

    Replays a realistic modern session (Blizzard_FramerateFrame per
    source/12.1.0) over the shared mock and suite library: config
    window, drag preview, micro menu re-anchoring, the CPU/GPU-bound
    localized formats, reload persistence and /movefps reset.
--]]

local env = dofile("../shared/wow_test_env.lua");
local lib = dofile("tests/lib.lua").init(env);
local out = env.rawPrint;
local ok, same, P = lib.ok, lib.same, lib.P;
local BootSession, WindowOpen, WindowClose, TypeIn, Click = lib.BootSession, lib.WindowOpen, lib.WindowClose, lib.TypeIn, lib.Click;
local Slash = lib.Slash;

out("modern session:");

-- fresh install: the frame stays where Blizzard's OnLoad put it
local frame, _, text = unpack(BootSession(nil, lib.BuildRetailWorld));
local db = _G.Move_FPS_Counter;
ok(db.placed == false, "fresh install keeps the game placement");
ok(same(P(frame:GetPoint(1)), {"TOPRIGHT", _G.MicroMenuContainer, "TOPLEFT", -5, -5}), "micro menu anchoring untouched");
ok(frame:IsShown(), "counter remembered on");
env:Pump(1);
ok(text:GetText() == "60.0", "game writer produces its own format", text:GetText());
ok(#env.printLog == 2 and env.printLog[1]:find("/movefps", 1, true) ~= nil,
    "fresh install prints the chat tutorial");

-- while unplaced, Blizzard's own re-anchoring still applies
frame:UpdatePosition("BOTTOMRIGHT", "TOPRIGHT", 0, 5);
ok(same(P(frame:GetPoint(1)), {"BOTTOMRIGHT", _G.MicroMenuContainer, "TOPRIGHT", 0, 5}), "unplaced counter follows the micro menu like stock");

-- the player opens the window and configures
local options = WindowOpen();
ok(env:FindFrame("Move_FPS_CounterDragProxy") == nil, "window opens without move mode");
Click(options.moveBtn);
local proxy = env:FindFrame("Move_FPS_CounterDragProxy");
ok(proxy ~= nil and proxy:IsShown() and proxy:GetNumPoints() == 2
    and same(P(proxy:GetPoint(1)), {"TOPLEFT", frame, "TOPLEFT", 0, 0})
    and same(P(proxy:GetPoint(2)), {"BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0}),
    "move mode grab area hugs the unplaced counter");
TypeIn(options.xBox, "25.5");
TypeIn(options.yBox, "-12.25");
TypeIn(options.sizeBox, "20");
options.decimals:SetValue(0);
ok(same(P(frame:GetPoint(1)), {"CENTER", UIParent, "CENTER", 25.5, -12.25}), "configured position applied");
ok(select(2, text:GetFont()) == 20, "configured size applied");

-- now micro menu moves can no longer displace it
frame:UpdatePosition("TOPLEFT", "BOTTOMRIGHT", 0, -5);
frame:UpdatePosition("BOTTOMLEFT", "BOTTOMRIGHT", 5, 0);
ok(same(P(frame:GetPoint(1)), {"CENTER", UIParent, "CENTER", 25.5, -12.25}), "placed counter ignores micro menu moves");

-- drag the preview somewhere else (cursor-driven)
local fcx, fcy = frame:GetCenter();
env.cursorX, env.cursorY = fcx, fcy; -- grab on the anchor point (CENTER)
proxy:GetScript("OnDragStart")(proxy);
env.cursorX, env.cursorY = 302, 439.5; -- drop it at screen center + (-210, 55.5)
proxy:GetScript("OnUpdate")(proxy); -- mid-drag frame
proxy:GetScript("OnDragStop")(proxy);
ok(db.x == -210 and db.y == 55.5, "drag stores centered coordinates");
ok(same(P(frame:GetPoint(1)), {"CENTER", UIParent, "CENTER", -210, 55.5}), "drag moves the frame");
ok(options.xBox:GetText() == "-210.00" and options.yBox:GetText() == "55.50", "drag updates the coordinate boxes");

-- the CPU/GPU-bound localized formats keep their prefix; only decimals change
lib.cpuBound = true;
env:Pump(1);
ok(text:GetText() == "CPU bound: 60", "cpu bound format with decimals 0", text:GetText());
lib.cpuBound = false;
env:Pump(1);
ok(text:GetText() == "GPU bound: 60", "gpu bound format with decimals 0", text:GetText());
lib.cpuBound = nil;
options.decimals:SetValue(2);
lib.cpuBound = true;
env:Pump(1);
ok(text:GetText() == "CPU bound: 59.96", "cpu bound format with decimals 2", text:GetText());
lib.cpuBound = nil;
options.decimals:SetValue(1);
env:Pump(1);
ok(text:GetText() == "60.0", "decimals 1 restores the game format", text:GetText());

-- the player moves the config window itself; its position persists
options:ClearAllPoints();
options:SetPoint("CENTER", UIParent, "CENTER", 180, -40);
options:GetScript("OnDragStop")(options);
ok(db.win.x == 180 and db.win.y == -40, "window position saved on drag");

-- the user toggles the counter off through the game, then reloads
frame:Toggle();
ok(not frame:IsShown() and db.toggle == false, "Toggle tracked before the reload");

for i = 1, 5 do -- determinism: the reload segment runs 5 times back-to-back
    frame, _, text = unpack(BootSession(db, lib.BuildRetailWorld));
    db = _G.Move_FPS_Counter;
    local positioned = same(P(frame:GetPoint(1)), {"CENTER", UIParent, "CENTER", -210, 55.5});
    local sized = select(2, text:GetFont()) == 20;
    local hidden = not frame:IsShown();
    frame:Toggle();
    env:Pump(0.6);
    ok(positioned and sized and hidden and text:GetText() == "60.0",
        "reload " .. i .. ": state restored from ADDON_LOADED, format correct");
    frame:Toggle(); -- hide again for the next iteration
end

-- reload once more and check the window remembers its own position
frame, _, text = unpack(BootSession(db, lib.BuildRetailWorld));
db = _G.Move_FPS_Counter;
options = WindowOpen();
ok(same(P(options:GetPoint(1)), {"CENTER", UIParent, "CENTER", 180, -40}), "window reopens where it was left");
ok(frame:IsShown(), "preview force-shows the hidden counter");
WindowClose(options);
ok(not frame:IsShown(), "closing the preview restores the hidden state");

-- reset through the only non-window command hands the counter back to Blizzard
Slash("reset");
db = _G.Move_FPS_Counter;
ok(db.placed == false and db.size == 12 and db.decimals == 1, "reset restores the defaults");
ok(same(P(frame:GetPoint(1)), {"TOPRIGHT", _G.MicroMenuContainer, "TOPLEFT", -5, -5}), "reset restores the OnLoad anchoring");
ok(select(2, text:GetFont()) == 12, "reset restores the game font size");
frame:Toggle();
env:Pump(1);
ok(text:GetText() == "60.0", "reset restores the game format", text:GetText());
ok(#env.printLog == 0, "still no chat output at the end of the session");

lib.done();

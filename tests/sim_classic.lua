--[[
    Integration Sim for Move FPS Counter -- classic client session
    Run with: lua5.1 tests/sim_classic.lua   (from the addon root)

    Replays a realistic classic session (FramerateLabel/FramerateText on
    WorldFrame, per WoW_UI_Source/1.15 Blizzard_UIParent/Classic/WorldFrame)
    over the shared mock and suite library: fresh install, config window with
    move mode, drag preview, Blizzard's throttled FPS writer, re-anchor
    storms, reload persistence, benchmark toggles and /movefps reset.
--]]

local env = dofile("../shared/wow_test_env.lua");
local lib = dofile("tests/lib.lua").init(env);
local out = env.rawPrint;
local ok, same, P = lib.ok, lib.same, lib.P;
local BootSession, WindowOpen, WindowClose, TypeIn, Click = lib.BootSession, lib.WindowOpen, lib.WindowClose, lib.TypeIn, lib.Click;
local Slash = lib.Slash;

out("classic session:");

-- fresh install: the counter sits where the game puts it (NOT mid-screen) and
-- the addon is silent
local label, text = unpack(BootSession(nil, lib.BuildClassicWorld));
local db = _G.Move_FPS_Counter;
ok(db.placed == false, "fresh install keeps the game placement");
ok(same(P(label:GetPoint(1)), {"BOTTOM", _G.WorldFrame, "BOTTOM", 0, 64}), "fresh install anchors untouched");
ok(text:IsShown(), "counter remembered on");
ok(#env.printLog == 2 and env.printLog[1]:find("/movefps", 1, true) ~= nil,
    "fresh install prints the chat tutorial");

-- Blizzard's throttled writer runs against the untouched fontstrings
env:Pump(1);
ok(text:GetText() == "60.0", "game writer produces its own format", text:GetText());

-- the player opens the window, enables move mode and configures
local options = WindowOpen();
local proxy = env:FindFrame("Move_FPS_CounterDragProxy");
ok(proxy == nil, "window opens without move mode");
Click(options.moveBtn);
proxy = env:FindFrame("Move_FPS_CounterDragProxy");
ok(proxy ~= nil and proxy:IsShown(), "move mode makes the counter drag-movable");
TypeIn(options.xBox, "-180.75");
TypeIn(options.yBox, "120.5");
TypeIn(options.sizeBox, "22");
options.decimals:SetValue(2);
ok(same(P(label:GetPoint(1)), {"CENTER", UIParent, "CENTER", -180.75, 120.5}), "configured position applied");
ok(select(2, label:GetFont()) == 22 and select(2, text:GetFont()) == 22, "configured size applied");
env:Pump(1);
ok(text:GetText() == "59.96", "configured decimals applied", text:GetText());

-- pin the counter's right edge: it must stay put while the number width moves
local anchorMenu = lib.DriveMenu(options.anchorBtn);
lib.PickMenuEntry(anchorMenu, "RIGHT");
ok(db.anchor == "RIGHT" and same(P(label:GetPoint(1)), {"RIGHT", UIParent, "CENTER", -180.75, 120.5}), "anchor picker pins the right edge");
ok(proxy:GetNumPoints() == 4, "grab area hugs the counter rectangle while placed");

-- drag the preview somewhere else: the pinned right edge lands on the drop,
-- and the counter follows in real time while the drag is active
local pw, ph = UIParent:GetSize();
env.cursorX, env.cursorY = pw / 2 + db.x, ph / 2 + db.y; -- grab right on the anchor point
proxy:GetScript("OnDragStart")(proxy);
env.cursorX, env.cursorY = 722.5, 350.75; -- drop it at screen center + (210.5, -33.25)
proxy:GetScript("OnUpdate")(proxy); -- mid-drag frame
local placedX = 210.5;
ok(same(P(label:GetPoint(1)), {"RIGHT", UIParent, "CENTER", placedX, -33.25}), "counter follows the cursor in real time");
proxy:GetScript("OnDragStop")(proxy);
ok(db.x == placedX and db.y == -33.25, "drag stores anchor-relative coordinates", tostring(db.x));
ok(same(P(label:GetPoint(1)), {"RIGHT", UIParent, "CENTER", placedX, -33.25}), "drag moves the counter");
ok(options.xBox:GetText() == string.format("%.2f", placedX) and options.yBox:GetText() == "-33.25", "drag updates the coordinate boxes");

-- anchor storms that used to displace the counter on classic: none of them
-- may move it now, and no reposition helpers are needed
label:ClearAllPoints();
label:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 3, 3);
text:ClearAllPoints();
text:SetPoint("RIGHT", UIParent, "RIGHT", -3, 0);
env:FireEvent("PLAYER_ENTERING_WORLD");
env:FireEvent("UPDATE_ALL_UI_WIDGETS");
ok(same(P(label:GetPoint(1)), {"RIGHT", UIParent, "CENTER", placedX, -33.25}), "position survives re-anchor storm + login events");
ok(same(P(text:GetPoint(1)), {"LEFT", label, "RIGHT", 0, 0}), "number fontstring stays glued to the label");

-- the player hides the counter through the game, leaves move mode and closes
-- the window: the hidden state must not be stomped by the preview logic
_G.ToggleFramerate();
Click(options.moveBtn); -- leave move mode
ok(not proxy:IsShown(), "leaving move mode hides the grab area");
WindowClose(options);
ok(not text:IsShown() and db.toggle == false, "hidden state respected when the window closes");

for i = 1, 5 do -- determinism: the reload segment runs 5 times back-to-back
    label, text = unpack(BootSession(db, lib.BuildClassicWorld));
    db = _G.Move_FPS_Counter;
    local positioned = same(P(label:GetPoint(1)), {"RIGHT", UIParent, "CENTER", placedX, -33.25});
    local sized = select(2, label:GetFont()) == 22;
    local hidden = not text:IsShown();
    env:FireEvent("PLAYER_ENTERING_WORLD");
    local stillPositioned = same(P(label:GetPoint(1)), {"RIGHT", UIParent, "CENTER", placedX, -33.25});
    ok(positioned and sized and hidden and stillPositioned,
        "reload " .. i .. ": position, size and hidden state correct from ADDON_LOADED");
    -- the window opens in non-move mode, force-shows the counter as a preview
    -- and restores the hidden state on close
    options = WindowOpen();
    local previewShown = text:IsShown();
    local fieldsSynced = options.xBox:GetText() == string.format("%.2f", placedX) and options.sizeBox:GetText() == "22.0";
    WindowClose(options);
    ok(previewShown and fieldsSynced and not text:IsShown(),
        "reload " .. i .. ": preview force-show then restore works");
    _G.ToggleFramerate(); -- show again for the next check
    env:Pump(0.6);
    ok(text:GetText() == "59.96", "reload " .. i .. ": writer uses the configured decimals", text:GetText());
    _G.ToggleFramerate(); -- hide again for the next iteration
end

-- benchmark style toggles keep the remembered state in sync with visibility
_G.ToggleFramerate(true); -- benchmark start shows the counter
ok(text:IsShown() and db.toggle == true, "benchmark start shows and is tracked");
_G.ToggleFramerate(); -- benchmark end hides it
ok(not text:IsShown() and db.toggle == false, "benchmark end hides and is tracked");

-- reset through the only non-window command hands everything back
Slash("reset");
db = _G.Move_FPS_Counter;
ok(db.placed == false and db.size == 12 and db.decimals == 1 and db.remember == true and db.anchor == "CENTER", "reset restores the defaults");
ok(same(P(label:GetPoint(1)), {"BOTTOM", _G.WorldFrame, "BOTTOM", 0, 64}), "reset restores the game anchors");
ok(select(2, text:GetFont()) == 12, "reset restores the game font size");
_G.ToggleFramerate();
env:Pump(1);
ok(text:GetText() == "60.0", "reset restores the game format", text:GetText());
ok(#env.printLog == 0, "still no chat output at the end of the session");

lib.done();

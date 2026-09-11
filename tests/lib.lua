--[[
    Shared suite library for Move FPS Counter (test_movefps, sim_classic,
    sim_mainline). Suites run from the addon root:

        local env = dofile("../shared/wow_test_env.lua"); -- the canonical mock
        local lib = dofile("tests/lib.lua").init(env);

    Passing env in (instead of dofile-ing the mock a second time) matters: a
    second dofile re-executes the mock and installs a FRESH frame registry,
    which would silently detach the addon from the suite's env.

    Provides the assert helpers, the classic/modern counter worlds (mirroring
    source 1.15.9 Blizzard_UIParent/Classic/WorldFrame.xml and 12.1.0
    Blizzard_FramerateFrame, including Blizzard's throttled FPS writers and
    the full rect-read API the addon's coordinate math exercises), session
    booting, and the config-window drivers.
--]]

local SCREEN_W, SCREEN_H = 1024, 768;
local DEFAULT_FONT = "Fonts\\FRIZQT__.TTF";
local fps = 59.96;

-- anchor-aware rect reads (parent units, parent bottom-left origin), mirroring
-- the client's geometry so the addon's coordinate conversions behave for real
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

return {
    init = function(env)
        local out = env.rawPrint;
        local lib = { cpuBound = nil }; -- nil | true | false, as IsCpuBound returns

        local PASS, FAIL = 0, 0;
        function lib.ok(cond, name, extra)
            if cond then PASS = PASS + 1; out("  PASS: " .. name);
            else FAIL = FAIL + 1; out("  FAIL: " .. name .. (extra ~= nil and (" -- " .. tostring(extra)) or "")); end
        end
        function lib.done()
            out(("Test/Sim Results: %d passed, %d failed"):format(PASS, FAIL));
            if FAIL > 0 then
                os.exit(1);
            end
        end

        function lib.same(actual, expected)
            if #actual ~= #expected then return false; end
            for i = 1, #actual do
                if actual[i] ~= expected[i] then return false; end
            end
            return true;
        end

        function lib.P(...)
            return { ... };
        end

        function lib.InstallRectAPI(region)
            function region:GetCenter()
                local p = self.points[1];
                if not p then
                    return (self.w or 0) / 2, (self.h or 0) / 2;
                end
                local tw = p.relativeTo and p.relativeTo.GetWidth and p.relativeTo:GetWidth() or 0;
                local th = p.relativeTo and p.relativeTo.GetHeight and p.relativeTo:GetHeight() or 0;
                local ro = REL_OFF[p.relativePoint] or REL_OFF.CENTER;
                local po = POINT_OFF[p.point] or POINT_OFF.CENTER;
                return ro[1] * tw + (p.x or 0) + po[1] * (self.w or 0),
                       ro[2] * th + (p.y or 0) + po[2] * (self.h or 0);
            end
            function region:GetLeft()
                local cx = self:GetCenter();
                return cx - (self.w or 0) / 2;
            end
            function region:GetRight()
                local cx = self:GetCenter();
                return cx + (self.w or 0) / 2;
            end
            function region:GetTop()
                local _, cy = self:GetCenter();
                return cy + (self.h or 0) / 2;
            end
            function region:GetBottom()
                local _, cy = self:GetCenter();
                return cy - (self.h or 0) / 2;
            end
        end

        function lib.InstallHooksecurefunc()
            _G.hooksecurefunc = function(a, b, c)
                if type(a) == "string" then
                    -- two-argument form: hooksecurefunc("GlobalFunc", hook)
                    local orig, fn = _G[a], b;
                    _G[a] = function(...)
                        orig(...);
                        fn(...);
                    end;
                else
                    -- method form: hooksecurefunc(table, "Method", hook)
                    local orig, fn = a[b], c;
                    a[b] = function(...)
                        orig(...);
                        fn(...);
                    end;
                end
            end;
        end

        function lib.MakeFramerateFontStrings(label, text)
            label:SetFont(DEFAULT_FONT, 12);
            text:SetFont(DEFAULT_FONT, 12);
            label.w, label.h = 60, 14; -- measured text footprint
            function text:SetFormattedText(format, ...)
                self:SetText(string.format(format, ...));
            end
        end

        function lib.ClearWorld()
            _G.WorldFrame, _G.FramerateLabel, _G.FramerateText, _G.ToggleFramerate = nil;
            _G.FramerateFrame, _G.MicroMenuContainer = nil;
            _G.hooksecurefunc, _G.GetFramerate, _G.IsCpuBound = nil;
            _G.FPS_COUNTER_CPU_BOUND, _G.FPS_COUNTER_GPU_BOUND = nil;
            -- _G.Move_FPS_Counter deliberately survives: env:Reset() models a
            -- reload and keeps SavedVariables; fresh-install tests nil it
        end

        -- classic clients: FramerateLabel/FramerateText on WorldFrame, with
        -- Blizzard's own throttled writer (WorldFrame_OnUpdate, 4x per second,
        -- strict fpsTime field exactly like the real client)
        function lib.BuildClassicWorld()
            lib.InstallHooksecurefunc();
            _G.GetFramerate = function() return fps; end;
            _G.WorldFrame = CreateFrame("Frame", "WorldFrame");
            _G.WorldFrame:Show();
            _G.WorldFrame:SetSize(SCREEN_W, SCREEN_H); -- the mock leaves frames zero-sized
            local label = _G.WorldFrame:CreateFontString("FramerateLabel", "ARTWORK");
            local text = _G.WorldFrame:CreateFontString("FramerateText", "ARTWORK");
            lib.MakeFramerateFontStrings(label, text);
            -- default anchors from 1.15 WorldFrame.xml
            label:SetPoint("BOTTOM", _G.WorldFrame, "BOTTOM", 0, 64);
            text:SetPoint("LEFT", label, "RIGHT", 0, 0);
            label:Hide();
            text:Hide();
            lib.InstallRectAPI(label);
            lib.InstallRectAPI(text);
            _G.FramerateLabel = label;
            _G.FramerateText = text;
            _G.ToggleFramerate = function(benchmark)
                text.benchmark = benchmark;
                if text:IsShown() then
                    label:Hide();
                    text:Hide();
                else
                    label:Show();
                    text:Show();
                end
                _G.WorldFrame.fpsTime = 0;
            end
            _G.WorldFrame:SetScript("OnUpdate", function(self, elapsed)
                if _G.FramerateText:IsShown() then
                    local timeLeft = self.fpsTime - elapsed;
                    if timeLeft <= 0 then
                        self.fpsTime = 0.25;
                        _G.FramerateText:SetFormattedText("%.1f", _G.GetFramerate());
                    else
                        self.fpsTime = timeLeft;
                    end
                end
            end);
            return label, text;
        end

        -- modern clients: the FramerateFrame from Blizzard_FramerateFrame
        -- (ResizeLayoutFrame hugging the text, OnUpdate writer with the
        -- localized CPU/GPU-bound formats)
        function lib.BuildRetailWorld()
            lib.InstallHooksecurefunc();
            _G.GetFramerate = function() return fps; end;
            _G.IsCpuBound = function() return lib.cpuBound; end;
            _G.FPS_COUNTER_CPU_BOUND = "CPU bound: %.1f";
            _G.FPS_COUNTER_GPU_BOUND = "GPU bound: %.1f";
            _G.MicroMenuContainer = CreateFrame("Frame", "MicroMenuContainer");
            local frame = CreateFrame("Frame", "FramerateFrame");
            frame:Hide();
            -- FramerateFrameMixin:OnLoad anchors relative to the micro menu
            frame:SetPoint("TOPRIGHT", _G.MicroMenuContainer, "TOPLEFT", -5, -5);
            local label = frame:CreateFontString(nil, "ARTWORK");
            local text = frame:CreateFontString(nil, "ARTWORK");
            lib.MakeFramerateFontStrings(label, text);
            label:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0);
            text:SetPoint("LEFT", label, "RIGHT", 0, 0);
            frame.Label = label;
            frame.FramerateText = text;
            frame:SetSize(72, 14); -- ResizeLayoutFrame hugs the text
            function frame:SetShown(b)
                if b then self:Show(); else self:Hide(); end
            end
            -- models the client's Toggle->SetShown->script dispatch so the
            -- addon's OnShow/OnHide visibility hooks observe it (the mock's
            -- Show/Hide/SetShown primitives chain no scripts by design)
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
            lib.InstallRectAPI(frame);
            frame:SetScript("OnUpdate", function(self, elapsed)
                if self:IsShown() then
                    self.fpsTime = (self.fpsTime or 0) - elapsed;
                    if self.fpsTime <= 0 then
                        self.fpsTime = 0.25;
                        local isCpuBound = _G.IsCpuBound();
                        if isCpuBound == nil or _G.FPS_COUNTER_CPU_BOUND == nil or _G.FPS_COUNTER_GPU_BOUND == nil then
                            self.FramerateText:SetFormattedText("%.1f", _G.GetFramerate());
                        else
                            self.FramerateText:SetFormattedText(isCpuBound and _G.FPS_COUNTER_CPU_BOUND or _G.FPS_COUNTER_GPU_BOUND, _G.GetFramerate());
                        end
                    end
                end
            end);
            _G.FramerateFrame = frame;
            return frame, label, text;
        end

        -- env:Reset() models a reload: SavedVariables globals survive, so
        -- pass them back in to reload them (nil = fresh install). Returns the
        -- world table for the caller to unpack: local label, text =
        -- unpack(lib.BootSession(nil, lib.BuildClassicWorld));
        function lib.BootSession(savedVariables, buildWorld)
            env:Reset();
            lib.ClearWorld();
            _G.UIParent:SetSize(SCREEN_W, SCREEN_H);
            _G.Move_FPS_Counter = savedVariables;
            local world = { buildWorld() };
            assert(loadfile("Move_FPS_Counter.lua"))();
            env:FireEvent("ADDON_LOADED", "Move_FPS_Counter");
            return world;
        end

        function lib.Slash(msg)
            SlashCmdList.MOVEFPS(msg);
        end

        function lib.WindowOpen()
            lib.Slash("");
            local options = env:FindFrame("Move_FPS_CounterOptions");
            if options then
                -- the real client chains OnShow inside Show(); the mock does not
                if not options:IsShown() then
                    options:Show();
                end
                local s = options:GetScript("OnShow");
                if s then s(options); end
            end
            return options;
        end

        function lib.WindowClose(options)
            options:Hide();
            local s = options:GetScript("OnHide");
            if s then s(options); end
        end

        function lib.TypeIn(box, value)
            box:SetText(value);
            local s = box:GetScript("OnEnterPressed");
            if s then s(box); end
        end

        function lib.Click(widget, checked)
            if checked ~= nil then
                widget:SetChecked(checked);
            end
            local s = widget:GetScript("OnClick");
            if s then s(widget); end
        end

        -- drive a DropdownButton's MenuUtil generator with a fake root description
        function lib.DriveMenu(dd)
            local root = {};
            function root:CreateRadio(text, isSelected, setSelected, data)
                self[#self + 1] = { text = text, isSelected = isSelected, setSelected = setSelected, data = data };
            end
            dd:GetMenuGenerator()(dd, root);
            return root;
        end

        function lib.PickMenuEntry(root, data)
            for _, entry in ipairs(root) do
                if entry.data == data then
                    entry.setSelected(data);
                    return;
                end
            end
        end

        return lib;
    end,
};

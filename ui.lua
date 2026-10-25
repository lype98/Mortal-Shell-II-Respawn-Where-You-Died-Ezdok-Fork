-- Self-contained settings panel for "Respawn Where You Died".
--
-- Written from scratch so the mod carries its own UI. The previous version
-- borrowed a shared library that ships with another mod, which meant the panel
-- quietly did nothing on an install where that mod was absent.
--
-- Two engine facts shape everything below.
--
-- Lua cannot bind to a UMG delegate, so a UButton OnClicked never reaches us.
-- Presses are read instead by polling IsPressed / HasMouseCapture and firing on
-- the rising edge. That is why there is a poll loop at all.
--
-- The poll exists only while the panel is open. A callback that keeps
-- re-arming forever is what tore the Lua state down during hot reload before,
-- so closing the panel stops re-arming and leaves nothing behind.

local UI = {}

local POLL_MS = 60

-- ESlateVisibility
local VIS_VISIBLE = 0
local VIS_COLLAPSED = 1

-- ETextJustify
local JUSTIFY_CENTER = 1

local hooks = nil        -- callbacks into the mod, set by UI.setup
local root = nil         -- the UUserWidget added to the viewport
local rows = {}          -- one per clickable button
local statusLabel = nil
local open = false
local polling = false
local savedInput = nil   -- controller flags to put back on close
local pinned = {}        -- delayed callbacks UE4SS only holds by registry ref
local labelCount = 0
local toastRoot = nil
local toastLabel = nil
local toastDeadline = 0
local toastBuildCount = 0

local function log(msg)
    print("[RespawnWhereYouDied] " .. tostring(msg) .. "\n")
end

local function valid(o)
    if o == nil then return false end
    local ok, res = pcall(function() return o:IsValid() end)
    return ok and res == true
end

local function truthy(v) return v == true or v == 1 end

-- UE4SS 3.0.1 has no FindClass on every build; a class is an object like any
-- other, so it comes back from StaticFindObject by path on all of them.
local function construct(classPath, outer, name)
    local cls = StaticFindObject(classPath)
    if not valid(cls) then error("no class " .. classPath) end
    local obj = StaticConstructObject(cls, outer, FName(name))
    if not valid(obj) then error("could not construct " .. classPath) end
    return obj
end

local function setText(widget, str)
    pcall(function() widget:SetText(FText(tostring(str))) end)
end

local function styleText(widget, size, color, center)
    pcall(function()
        if widget.Font then widget.Font.Size = size end
        widget:SetColorAndOpacity({ SpecifiedColor = color, ColorUseRule = 0 })
        if center then widget:SetJustification(JUSTIFY_CENTER) end
    end)
end

local function controller()
    local ok, pc = pcall(function() return FindFirstOf("BP_PlayerController_C") end)
    if ok and valid(pc) then return pc end
    for _, c in ipairs(FindAllOf("PlayerController") or {}) do
        if valid(c) then return c end
    end
    return nil
end

-- A small transient confirmation for marker shortcuts and panel actions.
local function buildToast()
    local outer = controller()
    if outer == nil then return false end
    toastBuildCount = toastBuildCount + 1
    local suffix = tostring(toastBuildCount)
    local ok, err = pcall(function()
        local hud = construct("/Script/UMG.UserWidget", outer, "RWYD_Toast_" .. suffix)
        local tree = construct("/Script/UMG.WidgetTree", hud, "RWYD_ToastTree_" .. suffix)
        hud.WidgetTree = tree
        local canvas = construct("/Script/UMG.CanvasPanel", tree, "RWYD_ToastCanvas_" .. suffix)
        tree.RootWidget = canvas
        local panel = construct("/Script/UMG.Border", canvas, "RWYD_ToastPanel_" .. suffix)
        panel:SetBrushColor({ R = 0.055, G = 0.060, B = 0.065, A = 0.94 })
        panel:SetPadding({ Left = 16, Top = 9, Right = 16, Bottom = 9 })
        local label = construct("/Script/UMG.TextBlock", panel, "RWYD_ToastText_" .. suffix)
        setText(label, "")
        styleText(label, 12, { R = 0.93, G = 0.89, B = 0.78, A = 1.0 }, true)
        panel:SetContent(label)
        local slot = canvas:AddChildToCanvas(panel)
        slot:SetAnchors({ Minimum = { X = 0.5, Y = 0.88 },
                          Maximum = { X = 0.5, Y = 0.88 } })
        slot:SetOffsets({ Left = -190, Top = -42, Right = 190, Bottom = 42 })
        slot:SetAlignment({ X = 0.5, Y = 1.0 })
        hud:AddToViewport(2100)
        hud:SetVisibility(VIS_COLLAPSED)
        toastRoot, toastLabel = hud, label
    end)
    if not ok then
        log("marker confirmation could not be built: " .. tostring(err))
        toastRoot, toastLabel = nil, nil
        return false
    end
    return true
end

local hideToast
hideToast = function()
    if not valid(toastRoot) then return end
    local remaining = toastDeadline - os.clock()
    if remaining > 0.05 then
        ExecuteInGameThreadWithDelay(math.floor(remaining * 1000), pinned.toastHide)
        return
    end
    if valid(toastRoot) then pcall(function() toastRoot:SetVisibility(VIS_COLLAPSED) end) end
end
pinned.toastHide = hideToast

function UI.toast(message)
    if not valid(toastRoot) and not buildToast() then return end
    if not valid(toastLabel) then return end
    setText(toastLabel, message)
    pcall(function() toastRoot:SetVisibility(VIS_VISIBLE) end)
    toastDeadline = os.clock() + 2.4
    ExecuteInGameThreadWithDelay(2400, pinned.toastHide)
end

--================================================================== palette ===

local COL = {
    panel   = { R = 0.055, G = 0.060, B = 0.065, A = 0.96 },
    edge    = { R = 0.58,  G = 0.51,  B = 0.33,  A = 0.9 },
    title   = { R = 0.93,  G = 0.89,  B = 0.78,  A = 1.0 },
    heading = { R = 0.72,  G = 0.64,  B = 0.42,  A = 1.0 },
    text    = { R = 0.70,  G = 0.69,  B = 0.65,  A = 1.0 },
    dim     = { R = 0.50,  G = 0.49,  B = 0.47,  A = 1.0 },
    btnOff  = { R = 0.145, G = 0.150, B = 0.155, A = 1.0 },
    btnOn   = { R = 0.20,  G = 0.34,  B = 0.22,  A = 1.0 },
    rule    = { R = 0.35,  G = 0.31,  B = 0.22,  A = 0.7 },
}

--=================================================================== layout ===

local function pad(l, t, r, b)
    return { Left = l, Top = t, Right = r, Bottom = b }
end

local function addSlotted(vbox, widget, top, bottom)
    local ok, slot = pcall(function() return vbox:AddChildToVerticalBox(widget) end)
    if ok and slot ~= nil then
        pcall(function() slot:SetPadding(pad(0, top or 2, 0, bottom or 2)) end)
    end
end

local function addLabel(vbox, caption, size, color, top, bottom)
    labelCount = labelCount + 1
    local text = construct("/Script/UMG.TextBlock", vbox, "RWYD_Label_" .. labelCount)
    setText(text, caption)
    styleText(text, size, color)
    pcall(function() text:SetAutoWrapText(true) end)
    addSlotted(vbox, text, top, bottom)
    return text
end

-- A one pixel Border with nothing in it reads as a hairline rule.
local function addRule(vbox)
    labelCount = labelCount + 1
    local rule = construct("/Script/UMG.Border", vbox, "RWYD_Rule_" .. labelCount)
    pcall(function()
        rule:SetBrushColor(COL.rule)
        rule:SetPadding(pad(0, 0.5, 0, 0.5))
    end)
    addSlotted(vbox, rule, 7, 7)
end

-- UButton crams its content against the edges, so the label goes inside a
-- transparent Border that supplies the breathing room.
local function addButton(vbox, caption, onClick, textFn)
    local n = #rows + 1
    local button = construct("/Script/UMG.Button", vbox, "RWYD_Btn_" .. n)
    pcall(function() button:SetBackgroundColor(COL.btnOff) end)

    local inner = construct("/Script/UMG.Border", button, "RWYD_BtnPad_" .. n)
    pcall(function()
        inner:SetBrushColor({ R = 0, G = 0, B = 0, A = 0 })
        inner:SetPadding(pad(10, 6, 10, 6))
    end)

    local label = construct("/Script/UMG.TextBlock", inner, "RWYD_BtnText_" .. n)
    setText(label, caption)
    styleText(label, 11, COL.title, true)
    pcall(function()
        inner:SetContent(label)
        button:SetContent(inner)
    end)

    addSlotted(vbox, button, 3, 3)

    rows[n] = {
        button = button,
        label = label,
        onClick = onClick,
        text = textFn,
        wasDown = false,
    }
end

local function build()
    local outer = controller()
    if outer == nil then
        log("panel: no player controller yet")
        return false
    end

    local ok, err = pcall(function()
        local hud = construct("/Script/UMG.UserWidget", outer, "RWYD_Root")
        local tree = construct("/Script/UMG.WidgetTree", hud, "RWYD_Tree")
        hud.WidgetTree = tree

        local canvas = construct("/Script/UMG.CanvasPanel", tree, "RWYD_Canvas")
        tree.RootWidget = canvas

        -- One border inside another: the outer is the hairline edge, the inner
        -- is the fill. A single Border cannot be both.
        local edge = construct("/Script/UMG.Border", canvas, "RWYD_Edge")
        local fill = construct("/Script/UMG.Border", edge, "RWYD_Fill")
        pcall(function()
            edge:SetBrushColor(COL.edge)
            edge:SetPadding(pad(1, 1, 1, 1))
            fill:SetBrushColor(COL.panel)
            fill:SetPadding(pad(18, 16, 18, 16))
            edge:SetContent(fill)
        end)

        local vbox = construct("/Script/UMG.VerticalBox", fill, "RWYD_VBox")
        pcall(function() fill:SetContent(vbox) end)

        addLabel(vbox, "RESPAWN WHERE YOU DIED", 14, COL.title, 0, 2)
        addLabel(vbox, "Ctrl+0 opens and closes this panel.", 9, COL.dim, 0, 4)
        addRule(vbox)

        addButton(vbox, "", function()
            if hooks.setEnabled then hooks.setEnabled(not hooks.isEnabled()) end
        end, function()
            -- Named for what it actually governs. It used to read ENABLED and
            -- looked like a master switch, while continuing after a quit is a
            -- feature of its own that people may want without the respawn.
            return hooks.isEnabled() and "Death spot respawn:  YES" or "Death spot respawn:  NO"
        end)

        addRule(vbox)
        addLabel(vbox, "RESPAWN POINT", 10, COL.heading, 0, 4)

        addButton(vbox, "Mark this spot", function()
            if hooks.markHere then hooks.markHere() end
        end)

        addButton(vbox, "Clear mark", function()
            if hooks.clearMark then hooks.clearMark() end
        end)

        addButton(vbox, "", function()
            if hooks.toggleBeaconReset then hooks.toggleBeaconReset() end
        end, function()
            local on = hooks.isBeaconReset ~= nil and hooks.isBeaconReset()
            return on and "Beacon clears mark:  YES" or "Beacon clears mark:  NO"
        end)

        statusLabel = addLabel(vbox, "", 9, COL.text, 6, 4)

        addLabel(vbox, "A mark makes you respawn there instead of where you died, "
            .. "even when death spot respawn is off. Ctrl+numpad 1 sets a mark; "
            .. "Ctrl+numpad 2 clears it. "
            .. "Your Gloom still drops where you fell.", 9, COL.dim, 0, 6)


        addRule(vbox)
        addLabel(vbox, "CONTINUE AFTER QUIT", 10, COL.heading, 0, 4)

        addButton(vbox, "", function()
            if hooks.toggleResume then hooks.toggleResume() end
        end, function()
            local on = hooks.isResume ~= nil and hooks.isResume()
            return on and "Resume where you quit:  YES" or "Resume where you quit:  NO"
        end)

        addLabel(vbox, "Resume applies when you load your save from the main "
            .. "menu, and works even with respawn switched off. Beacon travel "
            .. "is never touched.", 9, COL.dim, 0, 2)

        addButton(vbox, "", function()
            if hooks.toggleBeaconRevives then hooks.toggleBeaconRevives() end
        end, function()
            local on = hooks.isBeaconRevives ~= nil and hooks.isBeaconRevives()
            return on and "Resting revives enemies:  YES" or "Resting revives enemies:  NO"
        end)

        addLabel(vbox, "Enemies you killed stay dead across a quit either way. "
            .. "With resting revival on NO they stay dead even after resting. "
            .. "Dying revives everyone, as in vanilla.",
            9, COL.dim, 0, 6)

        addRule(vbox)
        addButton(vbox, "Close", function() UI.close() end)

        local slot = canvas:AddChildToCanvas(edge)
        pcall(function()
            slot:SetAutoSize(true)
            slot:SetAnchors({ Minimum = { X = 0.02, Y = 0.14 },
                              Maximum = { X = 0.02, Y = 0.14 } })
            slot:SetOffsets({ Left = 0, Top = 0, Right = 340, Bottom = 0 })
            slot:SetAlignment({ X = 0.0, Y = 0.0 })
        end)

        hud:AddToViewport(2000)
        hud:SetVisibility(VIS_COLLAPSED)
        root = hud
    end)

    if not ok then
        log("panel could not be built: " .. tostring(err))
        root, rows, statusLabel = nil, {}, nil
        return false
    end
    return true
end

--==================================================================== input ===

local function widgetLib()
    local ok, lib = pcall(function()
        return StaticFindObject("/Script/UMG.WidgetBlueprintLibrary"):GetCDO()
    end)
    if ok then return lib end
    return nil
end

-- bShowMouseCursor alone does nothing in this game: no cursor appears and the
-- camera keeps turning. The input mode has to change too, and that lives on
-- the WidgetBlueprintLibrary CDO.
local function grabInput()
    local pc = controller()
    if pc == nil then return end
    pcall(function()
        pc.bShowMouseCursor = true
        pc.bEnableClickEvents = true
        pc.bEnableMouseOverEvents = true
    end)
    local lib = widgetLib()
    if lib ~= nil then
        pcall(function()
            lib:SetInputMode_GameAndUIEx(pc, root, 0, false, true)
        end)
        pcall(function() root:SetKeyboardFocus() end)
    end
    savedInput = true
end

local function releaseInput()
    if not savedInput then return end
    savedInput = nil
    local pc = controller()
    if pc == nil then return end
    pcall(function()
        pc.bShowMouseCursor = false
        pc.bEnableClickEvents = false
        pc.bEnableMouseOverEvents = false
    end)
    local lib = widgetLib()
    if lib ~= nil then
        pcall(function() lib:SetInputMode_GameOnly(pc, true) end)
    end
end

--===================================================================== poll ===

local function refresh()
    for _, row in ipairs(rows) do
        if row.text ~= nil and valid(row.label) then
            setText(row.label, row.text())
        end
    end
    if valid(statusLabel) and hooks.markStatus then
        setText(statusLabel, hooks.markStatus())
    end
    -- The toggle wears its state as colour, so the answer is readable without
    -- reading -- which is the entire reason this panel exists.
    local toggle = rows[1]
    if toggle ~= nil and valid(toggle.button) then
        pcall(function()
            toggle.button:SetBackgroundColor(hooks.isEnabled() and COL.btnOn or COL.btnOff)
        end)
    end
end

local function isDown(widget)
    local ok, pressed = pcall(function() return widget:IsPressed() end)
    if ok and truthy(pressed) then return true end
    ok, pressed = pcall(function() return widget:HasMouseCapture() end)
    return ok and truthy(pressed)
end

local tick
tick = function()
    polling = false
    if not open then return end
    if not valid(root) then
        -- The level unloaded and took the widget with it. Rebuild on the next
        -- open rather than clinging to a dead object.
        open, root, rows, statusLabel = false, nil, {}, nil
        releaseInput()
        return
    end

    for _, row in ipairs(rows) do
        if valid(row.button) then
            local down = isDown(row.button)
            if down and not row.wasDown then
                pcall(row.onClick)
                pcall(refresh)
                if not open then return end   -- Close was pressed
            end
            row.wasDown = down
        end
    end

    pcall(refresh)

    polling = true
    ExecuteInGameThreadWithDelay(POLL_MS, pinned.tick)
end

pinned.tick = tick

--=================================================================== public ===

function UI.open()
    if open then return end
    if not valid(root) then
        rows, statusLabel = {}, nil
        if not build() then return end
    end
    open = true
    pcall(function() root:SetVisibility(VIS_VISIBLE) end)
    grabInput()
    pcall(refresh)
    if not polling then
        polling = true
        ExecuteInGameThreadWithDelay(POLL_MS, pinned.tick)
    end
end

function UI.close()
    if not open then return end
    open = false
    pcall(function() root:SetVisibility(VIS_COLLAPSED) end)
    releaseInput()
end

function UI.toggle()
    if open then UI.close() else UI.open() end
end

function UI.isOpen() return open end

--- Refresh from outside, when the mod state changed on its own.
function UI.sync()
    if open then pcall(refresh) end
end

---@param callbacks table isEnabled, setEnabled, markHere, clearMark,
--- markStatus, isBeaconReset, toggleBeaconReset, isResume, toggleResume,
--- isBeaconRevives, toggleBeaconRevives
function UI.setup(callbacks)
    hooks = callbacks
end

return UI

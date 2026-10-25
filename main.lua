-- Respawn Where You Died -- Mortal Shell II (UE 5.6.1)
--
-- Vanilla: dying reloads the level and puts you back at a landing area.
-- With this mod you come back where you fell.
--
-- Confirmed on this build by watching a real death:
--   * dying reloads the level -- the pawn AND the game mode are new objects;
--   * BP_SpartaGameMode_C:ChoosePlayerStart runs afterwards, the death choice
--     screen does not bypass it;
--   * its Blueprint is  if IsValid(CustomPlayerStart) then return that one,
--     so writing that variable during the hook is enough to move the spawn.
--
-- Where the coordinate comes from: the game already answers this question for
-- its own Gloom drop. GA_DeathSpoilsHandler_C:ShouldSaveLocation says whether
-- the player is somewhere worth remembering -- on the ground, carrying none of
-- six blocking tags -- and GetPlayerRelevantLocation gives the spot. Both are
-- called from the hook the game itself ticks, so the mod owns no timer.
--
-- Two traps cost a lot of time and are worth naming. SpawnLostGloom stays
-- silent when there is no Gloom to drop, and SpartaAbilityCommitted fires about
-- three seconds after every level *load*, not on death -- reading a position
-- from it sent the player back to the beacon they had just spawned at, which
-- looked exactly like the mod doing nothing. The real death signal is
-- GA_Death_Player_C:HandlePlayerDeath.
--
-- Loading a save is told apart from dying by that same flag: a fresh process
-- has never seen a death, so the mod stands aside and vanilla wins.
--
-- The spawn itself cannot be redirected. SpartaGameMode takes the respawn
-- transform from the session save through GetStartTransformFromSessionSave, so
-- ChoosePlayerStart is only a signal; the pawn is moved after it exists.
--
-- Dungeons are not World Partition cells and never stream in from presence
-- alone -- see wakeDungeon further down for the machinery that loads them.

-- Defaults. Anything in Scripts/config.lua wins over these, and the on/off
-- state is remembered in Scripts/state.lua between sessions.
local CONFIG = {
    Enabled = true,
    -- No instant-toggle key by default: the panel's checkbox is the switch.
    -- Set to a UE4SS key name (e.g. "F7") to get one back.
    ToggleKey = nil,
    MenuKey = "ZERO",
    MenuCtrl = true,
    -- Using a beacon wipes the manual mark, so a mark set before a fight
    -- cannot ambush you hours later. Toggleable in the panel.
    ClearMarkOnBeacon = true,
    -- Continue-after-quit. Resume (panel-toggleable) puts the pawn back where
    -- the game was closed. Enemies killed since the last rest staying dead
    -- across a quit is not a toggle -- it is what continuing a session means.
    -- BeaconRevives is the one choice left: true is the game's own rule
    -- (resting revives everyone), false keeps your kills dead even then.
    ResumeAtQuit = true,
    BeaconRevives = true,

    -- Delivering into a dungeon the game has not opened leaves you in a level
    -- with no zone behind it. Measured from the bytecode on 2026-08-28: the
    -- exit's TeleportToDungeonEntrance moves nobody -- with IsManualTeleport
    -- false it only broadcasts "player is leaving", and the actor that carries
    -- the player out is the dungeon zone listening for it. No zone, no way out.
    -- So the mod steps aside there: both the death respawn and the resume leave
    -- the player wherever the game put them. Turn on only to reproduce it.
    DeliverIntoClosedDungeons = false,
    SearchForDungeons = false,
    InvulnerableSeconds = 5.0,

    -- Coming back exactly where you died means coming back inside the group
    -- that killed you. This shoves them off, using the game's own knockback --
    -- the one a parried attacker gets -- so it looks and behaves native.
    PushEnemies = true,
    PushRadius = 1500.0,
    PushImpulse = 1200.0,
    PushDuration = 0.5,
    OffsetZ = 20.0,
    SampleAgeSeconds = 3,
    FreshnessSeconds = 90,
    ArrivedWithin = 1500.0,
    -- Milestones (death, teleport, mark, errors) are always logged. Verbose
    -- adds the play-by-play: per-second holds, death events, streaming pokes.
    Verbose = false,

    -- After a long teleport the destination is not streamed in yet and the
    -- pawn arrives in mid-air. Hold it on the spot for this long -- which is
    -- also what makes the world stream there -- and let go once it has a floor.
    SettleSeconds = 30,

    -- Vertical slack that still counts as landed (cm).
    SettleWithinZ = 400.0,

    -- Fallback teleport is gone from the config on purpose: the polling watch
    -- it needed crashed the game inside UE4SS property lookup, and the hook
    -- driven delivery replaced it entirely.
}

-- A spot the player picked by hand in the panel. When set it wins over the
-- place of death entirely, which is the whole point: you mark a spot before a
-- hard fight and keep coming back to it. Declared up here because loadState
-- fills it in before anything else runs.
local marked = nil

-- Where the player stood when the game was last closed. There is no quit
-- event to hook, so this is simply the last spot the game itself approved as
-- solid ground, written to state.lua every few seconds while playing.
local quitSpot = nil

-- Spawners whose enemy died since the last beacon rest, keyed by the FGuid of
-- their SpartaSaveComponent -- the identity the game itself uses for its save
-- data, stable across loads and unique across level instances (verified over
-- a live world: 43 spawners, zero duplicate guids). The game already keeps a
-- WasEverKilled flag on disk for every one of these; what does NOT survive a
-- quit is the "dead until you rest" state, and this set is exactly that state.
local deadSpawners = {}
local deadCount = 0

local MOD_DIR = nil
local function modFile(name)
    if MOD_DIR == nil then
        local ok, dirs = pcall(IterateGameDirectories)
        if not ok or dirs == nil then return nil end
        local ok2, win64 = pcall(function()
            return dirs.Game.Binaries.Win64.__absolute_path
        end)
        if not ok2 or win64 == nil then return nil end
        MOD_DIR = win64 .. "\\ue4ss\\Mods\\RespawnWhereYouDied\\Scripts\\"
    end
    return MOD_DIR .. name
end

-- config.lua may be missing, may be mid-edit, may be nonsense. Any of that is
-- survivable: keep the defaults and say so once.
local function loadConfig()
    local path = modFile("config.lua")
    if path == nil then return "no path" end
    local ok, cfg = pcall(dofile, path)
    if not ok or type(cfg) ~= "table" then return "defaults" end
    for k, v in pairs(cfg) do
        if CONFIG[k] ~= nil and type(v) == type(CONFIG[k]) then CONFIG[k] = v end
    end
    -- The two key names default to nil, so the type-matched loop above can
    -- never accept them: a user's `ToggleKey = "F7"` was silently dropped.
    -- They are taken as given -- a string or nothing.
    CONFIG.ToggleKey = type(cfg.ToggleKey) == "string" and cfg.ToggleKey or nil
    CONFIG.MenuKey = type(cfg.MenuKey) == "string" and cfg.MenuKey or nil
    return "config.lua"
end

local function loadState()
    local path = modFile("state.lua")
    if path == nil then return end
    local ok, st = pcall(dofile, path)
    if not ok or type(st) ~= "table" then return end
    -- Version 1 had an F7 toggle and no way to see the result. Since the mod
    -- ships enabled, everyone who pressed that key expecting to switch it ON
    -- switched it OFF -- permanently, because the answer was written here and
    -- survived every restart. That is what "it does not work" meant on the
    -- release page. Files from back then have no V, so their Enabled is
    -- deliberately ignored once and everybody starts from the config default.
    if st.V == 2 and type(st.Enabled) == "boolean" then CONFIG.Enabled = st.Enabled end
    if st.V == 2 and type(st.BeaconClears) == "boolean" then
        CONFIG.ClearMarkOnBeacon = st.BeaconClears
    end
    if st.V == 2 and type(st.ResumeAtQuit) == "boolean" then
        CONFIG.ResumeAtQuit = st.ResumeAtQuit
    end
    if st.V == 2 and type(st.BeaconRevives) == "boolean" then
        CONFIG.BeaconRevives = st.BeaconRevives
    end
    -- A mark is worth keeping across sessions: it is a deliberate choice, and
    -- losing it on every launch would make the feature annoying to rely on.
    if type(st.MarkX) == "number" and type(st.MarkY) == "number"
       and type(st.MarkZ) == "number" then
        marked = { x = st.MarkX, y = st.MarkY, z = st.MarkZ }
    end
    if type(st.QuitX) == "number" and type(st.QuitY) == "number"
       and type(st.QuitZ) == "number" then
        quitSpot = { x = st.QuitX, y = st.QuitY, z = st.QuitZ,
                     sealed = st.QuitSealed == true,
                     sel = type(st.QuitSel) == "string" and st.QuitSel or nil }
    end
    if type(st.Dead) == "table" then
        for _, g in ipairs(st.Dead) do
            if type(g) == "string" and not deadSpawners[g] then
                deadSpawners[g] = true
                deadCount = deadCount + 1
            end
        end
    end
end

local function saveState()
    local path = modFile("state.lua")
    if path == nil then return end
    local f = io.open(path, "w")
    if f == nil then return end
    local mark = ""
    if marked ~= nil then
        mark = string.format(", MarkX = %.3f, MarkY = %.3f, MarkZ = %.3f",
            marked.x, marked.y, marked.z)
    end
    local quit = ""
    if quitSpot ~= nil then
        quit = string.format(", QuitX = %.3f, QuitY = %.3f, QuitZ = %.3f, QuitSealed = %s",
            quitSpot.x, quitSpot.y, quitSpot.z, tostring(quitSpot.sealed == true))
        if type(quitSpot.sel) == "string" then
            quit = quit .. string.format(", QuitSel = %q", quitSpot.sel)
        end
    end
    local dead = ""
    if deadCount > 0 then
        local gs = {}
        for g in pairs(deadSpawners) do gs[#gs + 1] = string.format("%q", g) end
        table.sort(gs)
        dead = ",\n  Dead = { " .. table.concat(gs, ", ") .. " }"
    end
    f:write("-- written by the mod, safe to delete\n"
         .. "return { V = 2, Enabled = " .. tostring(CONFIG.Enabled)
         .. ", BeaconClears = " .. tostring(CONFIG.ClearMarkOnBeacon)
         .. ", ResumeAtQuit = " .. tostring(CONFIG.ResumeAtQuit)
         .. ", BeaconRevives = " .. tostring(CONFIG.BeaconRevives)
         .. mark .. quit .. dead .. " }\n")
    f:close()
end

local CONFIG_SOURCE = loadConfig()
loadState()

local GAME_MODE  = "/Game/Sparta/Core/GameModes/BP_SpartaGameMode.BP_SpartaGameMode_C"
local DEATH_ABIL = "/Game/Sparta/Core/Player/Ability/Death/GA_DeathSpoilsHandler.GA_DeathSpoilsHandler_C"
local PLAYER_DEATH = "/Game/Sparta/Core/Player/Ability/GA_Death_Player.GA_Death_Player_C:HandlePlayerDeath"

-- Hooked for the log only -- they tell us when things happen, they do not
-- decide anything. Handy the next time the order of events matters.
local DEATH_EVENTS = { "SpartaAbilityCommitted", "SpawnLostGloom", "SaveLostGloomData" }

local ring = {}          -- last approved spot, or raw samples in fallback mode
local askedGame = false  -- true once the game answered where the player stood
local pendingSpot = nil  -- death spot to put the pawn on once it exists
local settle = nil       -- {x, y, z, deadline} hold after a long teleport
local died = false       -- set by the real death handler, cleared once used
local borrowed = nil     -- {start, x, y, z} original transform of a borrowed start
local watching = false
-- Armed whenever a fresh game mode is constructed -- process start, continue
-- from the main menu and death reload alike -- and consumed by the first
-- ChoosePlayerStart after it. The died guard there keeps deaths on the death
-- path, so what is left is exactly "the player pressed continue".
-- (A once-per-process flag was tried first and missed the menu case; the
-- game's own ShouldResumeRun measured false on a real menu continue.)
--
-- It starts FALSE on purpose. Arming it at load looks harmless -- the mod
-- starts at the title screen, where the next spawn really is a continue --
-- but a hot reload happens mid-game, and then the next spawn is whatever the
-- player does next. Reloading in the hub and travelling to a beacon dragged
-- the player straight back: the travel spawn ate the flag left over from the
-- reload. Only a game mode being constructed arms it now.
local resumePending = false

local function log(fmt, ...)
    local ok, msg = pcall(string.format, "[RespawnWhereYouDied] " .. fmt .. "\n", ...)
    print(ok and msg or ("[RespawnWhereYouDied] bad log line: " .. tostring(msg) .. "\n"))
end

-- Property access on a dead UObject dies inside UStruct::FindProperty, taking
-- the game with it -- an access violation, not a Lua error, so pcall is a seat
-- belt and not a cure. The cure is to touch objects only right after they were
-- looked up, in the game thread, and never across a level transition.
local function valid(o)
    if o == nil then return false end
    local ok, res = pcall(function() return o:IsValid() end)
    return ok and res == true
end

-- Struct properties come back as wrappers whose fields are not reliably
-- readable from Lua -- reading LastValidLocation directly is what failed on the
-- first attempt, silently. Locations therefore always come from a call.
local function locationOf(actor)
    if not valid(actor) then return nil end
    local ok, v = pcall(function() return actor:K2_GetActorLocation() end)
    if not ok or v == nil then return nil end
    local x, y, z = v.X, v.Y, v.Z
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then return nil end
    if x == 0.0 and y == 0.0 and z == 0.0 then return nil end
    return { x = x, y = y, z = z }
end

local function firstOf(className)
    local all = FindAllOf(className)
    if all == nil then return nil end
    for _, o in ipairs(all) do
        if valid(o) then return o end
    end
    return nil
end

-- The actor the game itself placed. Its position went through the EQS query
-- that guarantees a spot you can walk back to, so it beats anything we sample.
local function unrecoveredSpoils()
    local all = FindAllOf("BP_DeathSpoils_C")
    if all == nil then return nil end
    for _, s in ipairs(all) do
        if valid(s) then
            local ok, rec = pcall(function() return s.Recovered end)
            if not ok or rec == false or rec == nil then return s end
        end
    end
    return nil
end

--================================================================== sampling ===

local settleTick   -- defined further down, once locationOf and log exist
local wakeDungeon  -- likewise: settleTick calls it, its body needs the helpers
local wakeNamedSelector   -- likewise: the identity-only half of wakeDungeon
local sealedDungeonAt     -- likewise: tells a dungeon whose exit cannot work
local refreshSealedFlag   -- likewise: needs nearestTo, runs off the sampler
local SEALED_CHECK_MS = 4000   -- give the woken level time to bring its exit up

-- "The player is standing in a dungeon whose only way out is a dialogue."
-- Noticed while they are alive, because that is when the answer is cheap and
-- certain -- the exit actor is right there. Acting on it later, after a death
-- or a load, saves the player a pointless flight out and back.
local sealedNow = false

-- The level-instance selector the player is currently inside, by actor name.
--
-- Radius alone cannot tell "the dungeon I am in" from "a dungeon that happens
-- to be over there": the world holds 92 selectors and the second nearest one
-- sat 426 m away when the wide-radius wake crashed the game. A name recorded
-- while the level was genuinely loaded around the player is not a guess, so
-- waking it later needs no radius and no falling pawn to justify it.
--
-- The UAID in the name is baked into the map, so it survives a restart -- which
-- is the whole point, since the case this exists for is quit-and-continue.
local currentSelector = nil
local installBeaconHooks  -- likewise: retried from ChoosePlayerStart on each spawn
local installSpawnerHooks -- likewise: spawner classes load with the level
local installTravelGuard  -- likewise: the traversal ability loads with the level
local schedulePush        -- likewise: settleTick fires it once the pawn lands
local findBurstSystem     -- likewise: looked up when the burst plays
local applyStayDead       -- flags recorded spawners; called from ChoosePlayerStart
local clearStayDead       -- forgets them; called from the beacon rest hook

local function sample()
    local l = locationOf(firstOf("BP_PlayerCharacter_C"))
    if l == nil then return end
    local now = os.time()
    local last = ring[#ring]
    if last and last.t == now then return end   -- one sample per second is plenty
    l.t = now
    ring[#ring + 1] = l
    while #ring > 0 and now - ring[1].t > CONFIG.FreshnessSeconds do table.remove(ring, 1) end
    while #ring > 64 do table.remove(ring, 1) end
end

-- Newest sample that is already a few seconds old. Aging it is the cheap way to
-- not hand back the inside of the pit you just fell into: a two-second fall
-- resolves to the solid ground you fell from.
-- With the game answering, the ring holds exactly one entry -- the last spot
-- it approved -- and ageing it would be wrong, not cautious. The ageing only
-- applies to the fallback, where samples are raw pawn positions.
local function agedSample()
    local now = os.time()
    local pick
    if askedGame then
        pick = ring[#ring]
    else
        for _, s in ipairs(ring) do
            if now - s.t >= CONFIG.SampleAgeSeconds then pick = s end
        end
        pick = pick or ring[1]
    end
    if pick == nil then return nil end
    -- The freshness cap is only there for the case where the death hook never
    -- fired and an old sample could be mistaken for "you just died here". Once
    -- the real death signal has arrived there is nothing left to guess, and
    -- applying the cap anyway is actively wrong: sitting on the death screen
    -- for two minutes threw the spot away and dropped the player at the beacon
    -- with the mod fully enabled, which read as the mod being broken.
    if not died and now - pick.t > CONFIG.FreshnessSeconds then return nil end
    return pick
end

-- The quit spot is just the newest game-approved sample, persisted. Throttle
-- the check itself, not only successful writes: otherwise a player who has
-- not moved a metre (or is on a moving base) repeats the pawn/base lookup on
-- every SaveLastValidLocation callback.
local lastQuitCheck = 0

-- Is the pawn standing on something that moves? A quit spot recorded on a
-- lift is a coordinate the lift has left by the time the save is continued:
-- the pawn comes back to empty air over the shaft, hangs there for the whole
-- hold, drops, and dies (2026-09-03, 11:10). The previous spot on real ground
-- is the better memory, so a moving base simply does not overwrite it.
-- EComponentMobility: 0 Static, 1 Stationary, 2 Movable. An unreadable base
-- counts as static -- refusing to record on a doubt would lose ordinary spots.
local function onMovingBase(pawn)
    local moving = false
    pcall(function()
        local base = pawn:GetMovementBase()
        if base == nil then return end
        local m = base.Mobility
        if type(m) == "userdata" or type(m) == "table" then
            local ok, got = pcall(function() return m:get() end)
            if ok then m = got end
        end
        moving = (m == 2)
    end)
    return moving
end

local function noteQuitSpot()
    local s = ring[#ring]
    if s == nil then return end
    local now = os.time()
    -- This runs on the game's own location-save hook. Cap both the checks and
    -- state.lua writes on that thread; in-memory sampling continues separately.
    if now - lastQuitCheck < 15 then return end
    lastQuitCheck = now
    local pawn = firstOf("BP_PlayerCharacter_C")
    if valid(pawn) and onMovingBase(pawn) then return end
    if quitSpot ~= nil then
        local dx, dy, dz = s.x - quitSpot.x, s.y - quitSpot.y, s.z - quitSpot.z
        if dx * dx + dy * dy + dz * dz < 100.0 * 100.0 then return end
    end
    quitSpot = { x = s.x, y = s.y, z = s.z, sealed = sealedNow,
                 sel = currentSelector }
    saveState()
end

-- Sampling rides the game's own timer instead of a LoopAsync of ours.
--
-- That is not a micro-optimisation. UE4SS keeps per-tick Lua callbacks in a
-- registry, and a hot reload frees the Lua state while the engine tick hook
-- still holds references into it -- the game then dies inside luaH_getint with
-- an access violation. Every mod that owns a periodic callback is a candidate
-- for that crash, so this one owns none while alive.
--
-- GA_DeathSpoilsHandler_C:SaveLastValidLocation is called by the game on its
-- own schedule for exactly this purpose: it records where the player last stood
-- on solid ground.
-- Ask the game, do not guess. The hook fires on the game's own schedule;
-- inside it the handler answers whether the player is somewhere worth
-- remembering, and where that is.
local warnedFallback = false

local function sampleFromGame(handler)
    if handler == nil then return false end
    local ok, should = pcall(function() return handler:ShouldSaveLocation() end)
    if not ok or should ~= true then return ok end   -- a false answer is still an answer
    local ok2, v = pcall(function() return handler:GetPlayerRelevantLocation() end)
    if not ok2 or v == nil then return false end
    local x, y, z = v.X, v.Y, v.Z
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then return false end
    if x == 0.0 and y == 0.0 and z == 0.0 then return false end
    ring = { { x = x, y = y, z = z, t = os.time() } }
    askedGame = true
    return true
end

local okSampler = false
local function installSampler()
    if okSampler then return true end
    okSampler = pcall(function()
    RegisterHook(DEATH_ABIL .. ":SaveLastValidLocation", function(Context)
        -- Sampling feeds both halves: the death spot and the quit spot. With
        -- respawn switched off it still has to run, or "continue where you
        -- quit" would have nothing to continue from.
        if not CONFIG.Enabled and not CONFIG.ResumeAtQuit then
            -- A manually marked respawn still needs the settle pass after its
            -- teleport, but does not need normal sampling or dungeon scans.
            if marked ~= nil then pcall(settleTick) end
            return
        end
        local handler
        pcall(function() handler = Context:get() end)
        local ok = false
        pcall(function() ok = sampleFromGame(handler) end)
        if not ok then
            if not warnedFallback then
                warnedFallback = true
                log("game location calls unavailable -- falling back to sampling")
            end
            pcall(sample)
        end
        if refreshSealedFlag ~= nil then pcall(refreshSealedFlag) end
        if CONFIG.ResumeAtQuit then pcall(noteQuitSpot) end
        pcall(settleTick)
    end)
    end)
    return okSampler
end

--============================================================ player starts ===

-- Landing areas are player starts too, but they are also the visible bonfire
-- actors -- moving one would drag the prop across the level. Plain
-- BP_SpartaPlayerStart_C has no mesh, so that is the one to borrow.
local function borrowPlayerStart(gameMode)
    local current
    pcall(function() current = gameMode.CustomPlayerStart end)
    local starts = FindAllOf("BP_SpartaPlayerStart_C")
    if starts == nil then
        log("no BP_SpartaPlayerStart_C in the world")
        return nil
    end
    for _, ps in ipairs(starts) do
        if valid(ps) and not (valid(current) and ps == current) then return ps end
    end
    return nil
end

local function releasePlayerStart()
    if borrowed == nil then return end
    local ps = borrowed.start
    if valid(ps) then
        pcall(function()
            ps:K2_SetActorLocation({ X = borrowed.x, Y = borrowed.y, Z = borrowed.z }, false, {}, false)
        end)
        -- Put mobility back too, or the level keeps an actor that is Movable
        -- for no reason for the rest of the session.
        if borrowed.mobility ~= nil then
            pcall(function()
                local root = ps.RootComponent
                if root == nil then return end
                local okSet = pcall(function() root:SetMobility(borrowed.mobility) end)
                if not okSet then root.Mobility = borrowed.mobility end
            end)
        end
        log("borrowed player start restored")
    end
    borrowed = nil
end

--=================================================================== fallback ===

-- If the spawn still came up elsewhere, put the pawn where it belongs once
-- streaming has had a moment.
local function armWatch(target)
    if true then return end   -- kept for reference; delivery is hook driven now
    if watching or target == nil then return end
    watching = true
    local waited, pawnSeenFor, done = 0, 0, false
    LoopAsync(500, function()
        if done then watching = false; return true end
        waited = waited + 500
        if waited > CONFIG.WatchTimeoutMs or not CONFIG.Enabled then
            watching = false
            return true
        end
        ExecuteInGameThread(function()
            local pawn = firstOf("BP_PlayerCharacter_C")
            if not valid(pawn) then return end
            pawnSeenFor = pawnSeenFor + 500
            local l = locationOf(pawn)
            if l == nil then return end
            local dx, dy, dz = l.x - target.x, l.y - target.y, l.z - target.z
            local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
            if dist <= CONFIG.ArrivedWithin then
                log("landed at the death spot, distance %.0f", dist)
                done = true
                return
            end
            if pawnSeenFor >= CONFIG.FallbackDelayMs then
                log("pawn came up %.0f away -- teleporting", dist)
                pcall(function()
                    pawn:K2_TeleportTo(
                        { X = target.x, Y = target.y, Z = target.z + CONFIG.OffsetZ },
                        pawn:K2_GetActorRotation())
                end)
                done = true
            end
        end)
        return false
    end)
end

--================================================================== delivery ===

-- Where the pawn actually ends up is not decided by ChoosePlayerStart. Both
-- writes were verified in the log -- the borrowed start moved to the requested
-- spot and CustomPlayerStart held it -- and the player still woke up at the
-- beacon. SpartaGameMode carries native ShouldResumeRun and
-- GetStartTransformFromSessionSave, so the respawn transform comes from the
-- session save and the player start is never consulted.
--
-- So the pawn is moved after it exists. Not by polling: SpartaAbilityCommitted
-- fires about three seconds after every level load, on the game thread, with a
-- live pawn -- exactly the moment needed, and without owning a periodic
-- callback that a hot reload would leave dangling.
local function teleportTo(pawn, spot)
    return pcall(function()
        pawn:K2_TeleportTo(
            { X = spot.x, Y = spot.y, Z = spot.z + CONFIG.OffsetZ },
            pawn:K2_GetActorRotation())
    end)
end

-- Killing the velocity matters more than it sounds. The teleport above moves
-- the pawn but leaves it falling, so the speed keeps building from one
-- placement to the next. Zeroed, the pawn drops about five centimetres per tick
-- instead of four metres, which is close enough to hovering.
local warnedStop = false
local function stopFall(pawn)
    local ok = pcall(function()
        local mv = pawn.CharacterMovement
        if mv == nil then error("no movement component") end
        mv:StopMovementImmediately()
    end)
    if not ok and not warnedStop then
        warnedStop = true
        log("StopMovementImmediately unavailable -- the pawn will build up speed")
    end
    return ok
end

-- The movement mode is a CACHED verdict, not a measurement: the component
-- writes it during its own update and nothing invalidates it when an actor is
-- teleported. So the tick right after a long teleport still reports the footing
-- the pawn had at the beacon it left -- walking, on solid ground, in a place it
-- is no longer standing. That one stale reading was enough to make a resume
-- into a tomb look like a success: settleTick saw "on foot" at zero seconds,
-- ended the hold, and everything that fixes a void below -- the streaming
-- flush, the LoadMe that wakes the dungeon -- is gated behind that hold. The
-- player fell through the world with the level instance still unloaded and the
-- mod's log saying "settled at the death spot".
--
-- Cheapest honest fix: after moving the pawn, tell the component it is falling.
-- That is true by construction at that instant (nothing has checked the floor
-- yet) and it makes the engine re-derive footing on its next update, flipping
-- back to walking within a tick wherever there really is ground. Only at the
-- delivery, never during the hold: setting it every tick would overwrite the
-- walking the engine just found and the hold would never end.
local function dropFooting(pawn)
    return pcall(function()
        local mv = pawn.CharacterMovement
        if mv == nil then error("no movement component") end
        mv:SetMovementMode(3, 0)   -- MOVE_Falling, no custom sub-mode
    end)
end

-- A moment of the game's own invulnerability, so the respawn survives itself.
--
-- Respawning on your corpse means respawning inside the group that killed you,
-- and the knockback that clears them cannot be made to land any sooner: it is
-- pinned to the landing plus BURST_DELAY_MS, and moving that means finding a
-- new anchor in the ability graph. Measured 2026-09-02: settled at 17:11:23,
-- burst due at 17:11:25.8, player dead at 17:11:26.3. The push was never late
-- so much as outrun.
--
-- The game already has the answer as a blueprint utility --
-- BPFL_Utility:TimedInvulnerability(Actor, duration) -- which is what the dash
-- i-frames use, so it is the sanctioned path rather than a health hack.
local BPFL_UTILITY = "/Game/Sparta/Core/Utility/BPFL_Utility.Default__BPFL_Utility_C"
local warnedInvuln = false

local function grantInvulnerability(pawn, seconds)
    if seconds == nil or seconds <= 0 then return false end
    local ok = pcall(function()
        local cdo = StaticFindObject(BPFL_UTILITY)
        if cdo == nil then error("BPFL_Utility CDO not loaded") end
        cdo:TimedInvulnerability(pawn, seconds, pawn)
    end)
    if not ok and not warnedInvuln then
        warnedInvuln = true
        log("TimedInvulnerability unavailable -- respawning without the grace window")
    end
    return ok
end

-- Undo dropFooting when the hold is over.
--
-- dropFooting is a lie told for half a second so the footing reading is honest
-- rather than a stale "walking" left over from before the teleport. The engine
-- normally takes the lie back the moment it finds a floor -- but not always:
-- a player reported respawning on perfectly solid ground stuck in the falling
-- animation. Nothing else clears it, so the hold clears it on the way out.
local function takeFooting(pawn)
    return pcall(function()
        local mv = pawn.CharacterMovement
        if mv == nil then error("no movement component") end
        mv:SetMovementMode(1, 0)   -- MOVE_Walking
    end)
end

-- EMovementMode: 0 none, 1 walking, 2 nav walking, 3 falling, 4 swimming,
-- 5 flying, 6 custom. Anything that is not walking means there is no floor
-- under the pawn yet.
local function onFoot(pawn)
    local ok, mode = pcall(function()
        local mv = pawn.CharacterMovement
        if mv == nil then return nil end
        local m = mv.MovementMode
        if type(m) == "userdata" or type(m) == "table" then
            local ok2, got = pcall(function() return m:get() end)
            if ok2 then return got end
            return nil
        end
        return m
    end)
    if not ok or type(mode) ~= "number" then return nil end   -- unknown, not false
    return mode == 1 or mode == 2
end

-- Diagnostic, not machinery. Answers the two questions left: is there a floor
-- under the pawn, and does the pawn still collide with anything.
local UEHelpers = require("UEHelpers")

-- The treatment, not a measurement: make the player a streaming source again
-- and force the engine to finish loading before it hands control back.
local function forceStreaming()
    local what = "no controller"
    pcall(function()
        for _, c in ipairs(FindAllOf("PlayerController") or {}) do
            if valid(c) then
                local set = pcall(function() c.bEnableStreamingSource = true end)
                local flushed = pcall(function() c:ClientFlushLevelStreaming() end)
                what = string.format("source %s, flush %s",
                    set and "on" or "FAILED", flushed and "done" or "FAILED")
                return
            end
        end
    end)
    return what
end

-- Never search for something to load while the pawn is standing.
--
-- LoadMe and ClientFlushLevelStreaming are synchronous loads, and the crash
-- they cause is not theoretical: on 2026-08-29 an open-world resume woke the
-- nearest selector inside a 600 m radius, the engine sat in FlushLoading for
-- two minutes growing from 13 to 19 GB, and died on the AsyncLoading2 assert.
-- The selector it woke was 426 m away and belonged to a tomb the player had
-- never entered -- the world holds 92 of them, so "nearest within the radius"
-- answers something in half the open world.
--
-- Three licences to wake something, in order of how much they prove:
--
--   * A NAME recorded while the player was inside that level. No search, no
--     candidates, nothing to pick wrong -- safe standing or falling.
--   * STANDING, no name: only the selector within arm's reach (30 m), the one
--     whose entrance corridor the pawn is on. The crash selector was 80 m out
--     in the open world; nothing in the open world sits this close.
--   * FALLING, no name: the wide 600 m search -- OFF by default, because it
--     is the one path that has crashed the game twice. Three seconds of
--     falling was supposed to prove a void, and it does not: on 2026-09-02 a
--     resume forty seconds into a cold launch teleported 245 m, the open world
--     took longer than three seconds to stream a floor in, the search woke a
--     tomb the player had never entered, and LoadMe hung FlushLoading until
--     the AsyncLoading2 assert. No timeout can separate "cold streaming" from
--     "void" -- only proximity to a selector can, and that is what the two
--     paths above already use. CONFIG.SearchForDungeons turns it back on for
--     anyone who would rather have the rescue than the guarantee.
--
-- os.time() counts whole seconds, so "held >= 1" is true anywhere between one
-- tick and one second after the teleport, depending on where the clock happened
-- to sit. That is fine for a deadline and useless as a floor: every gate below
-- pairs it with a tick count, which the sampler produces at a steady ten a
-- second and which cannot collapse to nothing.
local MIN_TICKS = 5
local WIDE_WAKE_TICKS = 30   -- ~3 s of falling before the searching wake

-- Every synchronous load leaves the hook before it runs.
--
-- settleTick executes inside a RegisterHook callback -- the sampler rides the
-- game's SaveLastValidLocation timer -- and three minidumps (09-02 16:55,
-- 09-03 11:51, 09-03 12:02) carry the identical chain: FTimerManager::Tick,
-- UE4SS script_hook, three nested luaB_pcall, call_ufunction_from_lua,
-- LoadMe, FSoftObjectPtr::LoadSynchronous, FlushAsyncLoading, assert. A
-- blocking load issued from inside a script hook never returns; the same
-- load issued from a plain game-thread action (the DevBridge rescue, which
-- is how the corridor was woken by hand) completes. This is the rule the
-- project already wrote down for the teleport -- from a callback only mark
-- the moment, do the work through ExecuteInGameThreadWithDelay -- applied to
-- the one call that had not been given it.
local function deferWake(fn, ...)
    local args = { ... }
    ExecuteInGameThreadWithDelay(50, function()
        local ok, err = pcall(fn, table.unpack(args))
        if not ok then log("deferred wake failed: %s", tostring(err)) end
    end)
end
local WAKE_WAIT_TICKS = 150  -- ~15 s: how long a wake waits for a quiet streamer

-- Is World Partition done streaming? The one question that decides whether
-- LoadMe is a load or a deadlock.
--
-- LoadMe ends in FlushAsyncLoading, which waits for every pending package.
-- Packages finish on the game thread -- the thread this Lua is standing on.
-- So if anything is still streaming when we call it, the loader waits for
-- us and we wait for the loader, and two minutes later the engine asserts
-- (AsyncLoading2.cpp:11310; three times now: 08-29, 09-02, 09-03). Every
-- wake fires within a second of a 250 m teleport, which is exactly when the
-- streamer is busiest; the one LoadMe that always worked -- the corridor
-- rescue -- was issued into a settled world. Distance was never the variable.
--
-- UWorldPartitionSubsystem::IsAllStreamingCompleted is reflected in this
-- build (name-table hit in the shipping exe). nil means the question could
-- not be asked, and an unanswerable question is a no.
local function streamingQuiet(cache)
    local sub = cache and cache.wpSub or nil
    if not valid(sub) then
        sub = nil
        pcall(function() sub = FindFirstOf("WorldPartitionSubsystem") end)
        if cache then cache.wpSub = sub end
    end
    if not valid(sub) then return nil end
    local ok, done = pcall(function() return sub:IsAllStreamingCompleted() end)
    if not ok or type(done) ~= "boolean" then return nil end
    return done
end

local WAKE_RADIUS = 60000.0   -- 600 m: same-dungeon distances, not the next zone

-- For a standing pawn with no recorded name: only the selector it is
-- practically on top of. Measured in the entrance corridor 2026-08-29: the
-- dungeon's own selector sat 3.4 m away, the next one 337 m. The open-world
-- crash selector was 80 m out -- an order of magnitude beyond this.
local NEAR_WAKE_RADIUS = 3000.0

-- Called from the sampler hook, which the game drives itself.
function settleTick()
    if settle == nil then return end
    -- The pawn is looked up once per hold and re-validated every tick, not
    -- found afresh: firstOf walks the whole object array, and ten walks a
    -- second for thirty seconds is the kind of per-frame cost this project
    -- forbids. valid() before every use is what makes the cache safe.
    local pawn = settle.pawn
    if not valid(pawn) then
        pawn = firstOf("BP_PlayerCharacter_C")
        settle.pawn = pawn
    end
    if not valid(pawn) then return end
    local l = locationOf(pawn)
    if l == nil then return end

    local dx, dy = l.x - settle.x, l.y - settle.y
    local flat = math.sqrt(dx * dx + dy * dy)
    local drop = settle.z - l.z
    local footing = onFoot(pawn)
    local held = os.time() - settle.since
    settle.ticks = settle.ticks + 1

    -- Both treatments below are for a void under the pawn, and both are
    -- synchronous loads. On solid ground they buy nothing and cost everything:
    -- see the note above settleTick.
    if not settle.forced and held >= 1 and settle.ticks >= MIN_TICKS
       and footing ~= true then
        settle.forced = true
        deferWake(function()
            local what = forceStreaming()
            if CONFIG.Verbose then log("forcing streaming: %s", what) end
        end)
    end

    -- The three licences from the note above MIN_TICKS. settle.woke means
    -- "the decision was made", not "something was woken", so the verdict below
    -- still has a gate to wait for either way.
    -- Nothing below may run into a busy streamer: see streamingQuiet. A
    -- "not yet" costs one tick and is asked again; a "cannot tell" ends the
    -- wake pass without waking anything, because a LoadMe we cannot vouch
    -- for is the crash.
    if not settle.woke and held >= 1 and settle.ticks >= MIN_TICKS then
        local quiet = streamingQuiet(settle)
        if quiet == nil then
            settle.woke = true
            log("cannot tell whether streaming is done -- not waking anything")
        elseif quiet == false then
            -- Waiting is free while the pawn is in the air, and cheap on the
            -- ground for a while; but a streamer that stays busy for fifteen
            -- seconds is not going to hand us a safe moment, and a standing
            -- player should not be held that long for a wake that may not
            -- even be needed. Give up the wake, keep the player.
            if settle.ticks >= WAKE_WAIT_TICKS then
                settle.woke = true
                log("streaming still busy after %ds -- not waking anything", held)
            elseif CONFIG.Verbose and settle.ticks % 10 == 0 then
                log("streaming still busy at %ds, wake deferred", held)
            end
        elseif settle.sel ~= nil then
            settle.woke = true
            deferWake(wakeNamedSelector, settle.sel)
        elseif footing == true then
            settle.woke = true
            deferWake(wakeDungeon, settle, NEAR_WAKE_RADIUS)
        elseif CONFIG.SearchForDungeons and settle.ticks >= WIDE_WAKE_TICKS then
            settle.woke = true
            deferWake(wakeDungeon, settle, WAKE_RADIUS)
        end

        -- Waking a dungeon level is not the same as the game opening it. When
        -- the game opens one, its zone comes with it and owns the way out; when
        -- the mod wakes it, there is no zone, and the exit interaction can only
        -- shout into the void. That is true of a death respawn just as much as
        -- of a resume, so both step aside here.
        -- The verdict has to wait: the exit interaction only exists once the
        -- level is up, and that is the thing being looked for.
        -- Every wake path gets the check -- a mod-woken level has no zone no
        -- matter how precisely it was chosen, so a dialogue-only exit is dead
        -- either way. Where the dungeon is fine, the check answers false and
        -- costs one delayed lookup.
        if settle.woke and settle.origin ~= nil
           and not CONFIG.DeliverIntoClosedDungeons then
            local spot = { x = settle.x, y = settle.y, z = settle.z }
            local back = settle.origin
            -- The hold this check belongs to, by identity. Four seconds is
            -- long enough for this hold to finish and a fresh death or resume
            -- to start another; without the check the callback would kill
            -- that unrelated hold and drag the player to a stale origin.
            local mine = settle
            ExecuteInGameThreadWithDelay(SEALED_CHECK_MS, function()
                if settle ~= mine then return end
                local ok, sealed, howFar = pcall(sealedDungeonAt, spot)
                if not ok or sealed ~= true then return end
                local p = firstOf("BP_PlayerCharacter_C")
                if not valid(p) then return end
                settle = nil
                local okBack = teleportTo(p, back)
                if okBack then stopFall(p) end
                -- Every exit from a hold takes the falling lie back; this one
                -- did not, and the origin is ground the game itself chose.
                takeFooting(p)
                log("this dungeon's only exit is a dialogue and no zone is alive "
                    .. "to answer it (exit %.0f cm away) -- it could not carry you "
                    .. "out, so you stay where the game placed you, %s",
                    howFar or -1, okBack and "moved back" or "MOVE BACK FAILED")
            end)
        end
    end

    -- Being at the right coordinate is not enough: right after the teleport the
    -- pawn is exactly on target and falling through empty space. The pawn stays
    -- in falling mode the whole hold, sweeping downwards a little every tick, so
    -- the engine flips it to walking the instant a floor streams in underneath.
    -- An unreadable movement mode means no signal at all -- then the hold simply
    -- runs its course, which is honest rather than a guess dressed up as one.
    -- The verdict waits for MIN_TICKS even when the footing already reads good.
    -- dropFooting makes the reading honest, but honest-and-early is still a race
    -- against the component's own update: half a second costs nothing here and
    -- buys the certainty that the engine has looked at the floor at least once
    -- since the pawn arrived.
    -- settle.woke, not just the tick count: landing on the entrance floor is a
    -- success the pawn feels and the dungeon behind it does not share, so the
    -- verdict waits until the wake pass has had its look.
    if footing == true and settle.woke and settle.ticks >= MIN_TICKS
       and flat <= CONFIG.ArrivedWithin and math.abs(drop) <= CONFIG.SettleWithinZ then
        log("settled at the death spot after %ds", held)
        takeFooting(pawn)
        settle = nil
        if schedulePush ~= nil then pcall(schedulePush) end
        return
    end

    if os.time() >= settle.deadline then
        log("released after %ds: %.0f away, %.0f below, %s",
            held, flat, drop,
            footing == nil and "footing never readable" or "no floor streamed in")
        -- Only where the pawn is actually on something: in a genuine void
        -- walking mode would be the second lie, and the fall is real.
        if footing == true then takeFooting(pawn) end
        -- A whole hold with no floor means the spot is not a place any more
        -- -- a lift that has moved on, a level that will never load. Dropping
        -- the player into it is a death with extra steps (2026-09-03: fall,
        -- death 0.4 s after release, vanilla respawn at the beacon). Going
        -- back to where the game put them is the same outcome without the
        -- death, the lost spoils, or the forty seconds in the air.
        if footing ~= true and settle.origin ~= nil then
            local back = settle.origin
            settle = nil
            local okBack = teleportTo(pawn, back)
            if okBack then stopFall(pawn); takeFooting(pawn) end
            log("no floor ever came -- back where the game placed you, %s",
                okBack and "moved back" or "MOVE BACK FAILED")
            return
        end
        settle = nil
        if schedulePush ~= nil then pcall(schedulePush) end
        return
    end

    -- Pull the pawn back only once it has actually gone somewhere. Doing this
    -- every tick regardless held it at exactly OffsetZ above the spot, with
    -- its velocity zeroed ten times a second, so it never descended those
    -- twenty centimetres to touch the floor: the floor probe never hit,
    -- footing read "falling" for the whole hold, and the player watched
    -- themselves twitch in the air over solid ground for thirty seconds.
    -- Measured live 2026-09-02: MovementMode 3, Velocity 0, FloorDist 0,
    -- bBlockingHit false, Z exactly spot + 20. Within the tolerances the pawn
    -- is left alone and gravity does the last bit.
    local ok = true
    if flat > CONFIG.ArrivedWithin or drop > CONFIG.SettleWithinZ then
        ok = teleportTo(pawn, settle)
        stopFall(pawn)
    end
    -- One line a second: a thirty second hold is three hundred ticks.
    if CONFIG.Verbose and (settle.ticks % 10 == 1 or not ok) then
        log("holding at %ds (%.0f away, %.0f below, %s) %s",
            held, flat, drop,
            footing == nil and "footing unknown" or (footing and "on foot" or "falling"),
            ok and "ok" or "FAILED")
    end
end

-- The dungeons are not World Partition cells, and no amount of hovering makes
-- one stream in. Diagnostics on a real death showed the machinery: each
-- entrance pairs a BP_LevelInstanceSelector_C, which loads the dungeon interior
-- as a level instance through SpartaLevelStreamingDynamic, with a
-- BP_DungeonSpawnLocations_C that carries its own
-- WorldPartitionStreamingSourceComponent -- and the selector nearest the death
-- spot sat at bIsLevelLoaded = false while the player hung in the void where
-- its dungeon should have been. So before holding the pawn there, wake both:
-- point a streaming source at the area and ask the selector to load its level.
-- WAKE_RADIUS and NEAR_WAKE_RADIUS live next to MIN_TICKS, above settleTick:
-- they are read inside its body, and a local declared below a function's body
-- is an unrelated global (nil) in there. That nil used to be masked by the
-- `radius or WAKE_RADIUS` default -- which would silently turn a near wake
-- into the searching one.


-- FindAllOf walks UE4SS's global object array, even for a narrow class. These
-- dungeon queries run during ordinary play, so cache their actor lists and let
-- UE4SS append newly-created instances. Invalid actors are pruned as levels
-- stream out. If notification registration is unavailable, retain the direct
-- lookup fallback rather than silently losing dungeon detection.
local dungeonActorCache = {}

local function dungeonActors(className)
    local cached = dungeonActorCache[className]
    if cached == nil then
        local found = FindAllOf(className) or {}
        local classPaths = {}
        for _, actor in ipairs(found) do
            if valid(actor) then
                local cls
                pcall(function() cls = actor:GetClass() end)
                local ok, full = pcall(function() return cls:GetFullName() end)
                if ok and type(full) == "string" then
                    local path = full:match("%S+%s+(.+)")
                    if path ~= nil then classPaths[path] = true end
                end
            end
        end
        local registered = false
        for classPath in pairs(classPaths) do
            local ok = pcall(function()
                NotifyOnNewObject(classPath, function(actor)
                    found[#found + 1] = actor
                end)
            end)
            registered = ok or registered
        end
        if registered then
            cached = found
            dungeonActorCache[className] = cached
        end
        if cached == nil then return found end
    end

    local live = {}
    for _, actor in ipairs(cached) do
        if valid(actor) then live[#live + 1] = actor end
    end
    dungeonActorCache[className] = live
    return live
end

local function nearestTo(spot, className)
    local best, bestD = nil, nil
    for _, a in ipairs(dungeonActors(className)) do
        local ok, v = pcall(function() return a:K2_GetActorLocation() end)
        if ok and v ~= nil and type(v.X) == "number" then
            local dx, dy, dz = v.X - spot.x, v.Y - spot.y, v.Z - spot.z
            local d = math.sqrt(dx * dx + dy * dy + dz * dz)
            if bestD == nil or d < bestD then best, bestD = a, d end
        end
    end
    return best, bestD
end

-- How close a loaded selector has to be before we call its level "the one the
-- player is in". Measured 2026-08-29 inside a tomb: the owning selector was
-- 30 m away, the next one 426 m. Three hundred metres sits between those with
-- room to spare and still cannot reach the neighbour.
-- How close a selector has to be before its level counts as "the place I am".
--
-- First written as 300 m and "must already be loaded", which made it useless
-- exactly where it was needed: standing in an entrance corridor nothing is
-- loaded yet, so no name was ever recorded and the corridor case fell through
-- to the searching wake -- the one that hangs the engine. Load state is
-- therefore not part of the question; proximity is the whole question.
--
-- Sixty metres, from the corridor measurement on 2026-08-29: the dungeon's own
-- selector was 3.4 m away and the next one 337 m. Anything the player is
-- genuinely standing at is metres away, not hundreds.
local SELECTOR_CLAIM_RADIUS = 6000.0

local function selectorName(a)
    local n
    pcall(function() n = a:GetFName():ToString() end)
    return n
end

-- Name of the selector the player is standing at, loaded or not; nil if none
-- is close enough to claim.
local function selectorNameAt(spot)
    local best, bestD = nil, nil
    for _, a in ipairs(dungeonActors("BP_LevelInstanceSelector_C")) do
        local ok, v = pcall(function() return a:K2_GetActorLocation() end)
        if ok and v ~= nil and type(v.X) == "number" then
            local dx, dy, dz = v.X - spot.x, v.Y - spot.y, v.Z - spot.z
            local d = math.sqrt(dx * dx + dy * dy + dz * dz)
            if d <= SELECTOR_CLAIM_RADIUS and (bestD == nil or d < bestD) then
                best, bestD = a, d
            end
        end
    end
    return best ~= nil and selectorName(best) or nil
end

local function selectorNamed(name)
    if type(name) ~= "string" then return nil end
    for _, a in ipairs(dungeonActors("BP_LevelInstanceSelector_C")) do
        if selectorName(a) == name then return a end
    end
    return nil
end

-- Is this a dungeon whose only way out is a dialogue with nobody to answer it?
--
-- Read out of the bytecode on 2026-08-28, not guessed. The exit interaction's
-- TeleportToDungeonEntrance carries nobody: with IsManualTeleport false -- every
-- ordinary exit -- it only calls BroadcastLeaveDungeonByTeleport and returns.
-- What actually moves the player is the dungeon zone
-- (BP_LevelInstanceSelector_TombZone_C), which listens for that broadcast. The
-- zone arrives with the entrance, so a level the mod woke by itself has none:
-- the broadcast lands nowhere and the player is sealed in.
--
-- Dungeons you walk out of are untouched -- this only fires where a leave
-- interaction is the only exit AND no zone is alive to serve it.
--
-- FindAllOf on the zone class returns nothing even while zones exist, so the
-- base classes are enumerated and filtered by class name instead.
local SEALED_RADIUS = 30000.0   -- 300 m: close enough to be this dungeon's exit

local function zoneAlive()
    for _, base in ipairs({ "BP_STH_Exit_Dungeon_C", "BP_STH_Entrance_Dungeon_C" }) do
        for _, a in ipairs(FindAllOf(base) or {}) do
            if valid(a) then
                local cn = ""
                pcall(function() cn = a:GetClass():GetFName():ToString() end)
                if cn:find("TombZone") then return true end
            end
        end
    end
    return false
end

-- Runs off the game's own sampler, but no more than once every few seconds:
-- FindAllOf walks the entire object array, and this only has to be roughly
-- right. While the player is alive the zone is up, so the test is simply "is a
-- dialogue exit within reach" -- that alone marks the kind of dungeon whose
-- exit stops working once the level is re-woken by us.
-- Each refresh walks the UObject array several times (selectors, exits and
-- interaction actors). This only identifies the current dungeon and whether
-- its dialogue exit is unsafe, so a slower refresh is sufficient and avoids
-- periodic full-world scans on the game's sampler thread.
local SEALED_FLAG_EVERY = 15  -- seconds
local sealedCheckedAt = 0

function refreshSealedFlag()
    local now = os.time()
    if now - sealedCheckedAt < SEALED_FLAG_EVERY then return end
    sealedCheckedAt = now
    local s = ring[#ring]
    if s == nil then return end

    -- Rides the same throttle for the same reason: another walk of the object
    -- array, and "which level instance am I in" changes at walking pace.
    local sel = selectorNameAt(s)
    if sel ~= currentSelector then
        currentSelector = sel
        if CONFIG.Verbose then
            log("inside level instance %s", sel or "(none)")
        end
    end

    -- Exit actors do not exist in the open world. Avoid a separate global
    -- object-array search unless a level-instance selector says we are in a
    -- dungeon.
    local near = false
    local ed = nil
    if sel ~= nil then
        local exit
        exit, ed = nearestTo(s, "BP_Interaction_P_LeaveDungeon_C")
        near = exit ~= nil and ed ~= nil and ed <= SEALED_RADIUS
    end
    if near ~= sealedNow then
        sealedNow = near
        log("%s a dungeon whose only exit is a dialogue%s",
            near and "entered" or "left",
            near and string.format(" (exit %.0f m away)", (ed or 0) / 100.0) or "")
    end
end

function sealedDungeonAt(spot)
    local exit, ed = nearestTo(spot, "BP_Interaction_P_LeaveDungeon_C")
    if exit == nil or ed == nil or ed > SEALED_RADIUS then return false end
    if zoneAlive() then return false end
    return true, ed
end
-- Wake the one selector recorded while the player was inside its level.
--
-- This is the only wake allowed to run under a pawn that is standing, because
-- it is the only one that knows its target instead of guessing it. Returns true
-- when the named selector was found, whether or not it needed loading.
function wakeNamedSelector(name)
    local sel = selectorNamed(name)
    if sel == nil then return false end
    local isLoaded
    pcall(function() isLoaded = sel.bIsLevelLoaded end)
    if isLoaded == false then
        local ok = pcall(function() sel:LoadMe() end)
        log("waking the recorded level instance, LoadMe %s", ok and "called" or "FAILED")
    elseif CONFIG.Verbose then
        log("recorded level instance is already loaded")
    end
    return true
end

function wakeDungeon(spot, radius)
    -- No default. `radius or WAKE_RADIUS` once turned a nil -- a local
    -- declared below the caller -- into the 600 m search that crashed the
    -- game, silently. A missing radius is a bug in the caller, not a wish
    -- for the widest one.
    if radius == nil then
        log("wakeDungeon called without a radius -- refusing to search")
        return
    end
    if spot ~= nil and spot.sel ~= nil and wakeNamedSelector(spot.sel) then return end
    local marker, md = nearestTo(spot, "BP_DungeonSpawnLocations_C")
    if marker ~= nil and md ~= nil and md < radius then
        local okSrc = pcall(function()
            marker.WorldPartitionStreamingSource:EnableStreamingSource()
        end)
        if CONFIG.Verbose or not okSrc then
            log("dungeon marker %.0f cm away, streaming source %s",
                md, okSrc and "enabled" or "NOT enabled")
        end
    end

    local sel, sd = nearestTo(spot, "BP_LevelInstanceSelector_C")
    if sel ~= nil and sd ~= nil and sd < radius then
        local isLoaded = nil
        pcall(function() isLoaded = sel.bIsLevelLoaded end)
        if isLoaded == false then
            local okLoad = pcall(function() sel:LoadMe() end)
            log("dungeon selector %.0f cm away, level not loaded, LoadMe %s",
                sd, okLoad and "called" or "FAILED")
        else
            if CONFIG.Verbose then
                log("dungeon selector %.0f cm away, bIsLevelLoaded = %s",
                    sd, tostring(isLoaded))
            end
        end
    end
end

--============================================================== respawn push ===

-- Landing on your own corpse means landing inside the group that made it, and
-- the vanilla answer to that is the beacon you no longer respawn at. So the
-- mod borrows the game's own shove: BFFL_StatusEffects:InflictKnockback with
-- the Event.Status.Knockback.Impulse tag -- the exact call a parried attacker
-- receives, found by recording a real fight rather than guessed.
--
-- Where the burst really lives, after three wrong guesses: not in losing the
-- shell and not in reviving it, but in GETTING BACK UP. A montage notify on
-- GA_ShellSeveredAnimation_StrongOne fires about two seconds after the sever
-- and does exactly two things -- InflictKnockback on whoever is close, and the
-- PS_ShellDetach_Impulse Niagara system. Both halves are copied here. Every
-- earlier capture missed it by watching the sever itself, whose own window had
-- closed by then; the sever really does push nobody.
local STATUS_LIB = "/Game/Sparta/Core/Utility/BFFL_StatusEffects.BFFL_StatusEffects_C"
local KNOCKBACK_TAG = "Event.Status.Knockback.Impulse"

-- The burst the player sees when the shell is knocked off and the character
-- gets back up. Recorded from a real one: the get-up montage notify calls
-- InflictKnockback on whoever stands close and plays this Niagara system.
-- Same two halves are used here, so the respawn reads as that same beat.
local NIAGARA_LIB = "/Script/Niagara.NiagaraFunctionLibrary"
local BURST_VFX = "/Game/Sparta/FX/VFX/Abilities/ShellDetach/Particles/PS_ShellDetach_Impulse.PS_ShellDetach_Impulse"

local pushPending = false
-- The push runs as three waves; the flash belongs to the first one only.
local burstShown = false
-- Which anchor fired this burst -- the spawn ability or the fallback timer.
local burstReason = "?"

-- Looked up fresh every time, deliberately. Keeping the found system in a
-- variable would cache a pointer across a level load, and a UObject freed
-- underneath such a pointer takes the game down through an access violation
-- that pcall does not catch -- the one failure mode in this project that is
-- never worth a convenience.
findBurstSystem = function()
    local system = nil
    pcall(function()
        local o = StaticFindObject(BURST_VFX)
        if o ~= nil and o:IsValid() then system = o end
    end)
    return system
end

-- Visual only: a missing system or library costs the effect, never the push.
local function playBurstVFX(pawn, pl)
    local lib = nil
    pcall(function() lib = StaticFindObject(NIAGARA_LIB):GetCDO() end)
    local system = findBurstSystem()
    if lib == nil or system == nil then
        log("burst VFX unavailable (%s)",
            lib == nil and "no Niagara library" or "system not loaded yet")
        return
    end
    pcall(function()
        lib:SpawnSystemAtLocation(pawn, system,
            { X = pl.x, Y = pl.y, Z = pl.z },
            { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 },
            { X = 1.0, Y = 1.0, Z = 1.0 },
            true, true, 0, true)
    end)
end

local function pushEnemiesNow()
    if not CONFIG.Enabled or not CONFIG.PushEnemies then return end
    local pawn = firstOf("BP_PlayerCharacter_C")
    if not valid(pawn) then return end
    local pl = locationOf(pawn)
    if pl == nil then return end

    local lib = nil
    pcall(function()
        local o = StaticFindObject(STATUS_LIB)
        if o ~= nil and o:IsValid() then lib = o:GetCDO() end
    end)
    if lib == nil then
        log("push FAILED: status effect library not found")
        return
    end

    if not burstShown then
        burstShown = true
        playBurstVFX(pawn, pl)
    end

    local tag = { TagName = FName(KNOCKBACK_TAG) }
    local from = { X = pl.x, Y = pl.y, Z = pl.z }
    local pushed, failed = 0, 0
    local nearest, farthest = nil, nil
    -- Characters, not spawners. Going through BP_Spawner_C.SpawnedAICharacter
    -- reads the world as the spawn system sees it, and moments after a respawn
    -- that link is not restored yet: enemies stood next to the player while the
    -- sweep found a single one fifteen metres away. Every enemy in this game is
    -- a SpartaCharacter, so ask for those and drop the player's own pawn.
    for _, enemy in ipairs(FindAllOf("SpartaCharacter") or {}) do
        if valid(enemy) and enemy ~= pawn then
            local cn = ""
            pcall(function() cn = enemy:GetClass():GetFName():ToString() end)
            if not cn:find("PlayerCharacter", 1, true) then
                local el = locationOf(enemy)
                if el ~= nil then
                    local dx, dy, dz = el.x - pl.x, el.y - pl.y, el.z - pl.z
                    local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
                    if dist <= CONFIG.PushRadius then
                        if nearest == nil or dist < nearest then nearest = dist end
                        if farthest == nil or dist > farthest then farthest = dist end
                        -- Victim, Instigator, InstigatingAbility, SingleInstance,
                        -- duration, Impulse, EventTag, OptionalObject,
                        -- OptionalValue, ImpactLocation, IgnoreInstigator, World.
                        -- The impact location is the player: that is what makes
                        -- the shove point outwards.
                        local ok = pcall(function()
                            lib:InflictKnockback(enemy, pawn, nil, true,
                                CONFIG.PushDuration, CONFIG.PushImpulse,
                                tag, nil, 0.0, from, false, pawn)
                        end)
                        if ok then pushed = pushed + 1 else failed = failed + 1 end
                    end
                end
            end
        end
    end
    if pushed > 0 or failed > 0 then
        log("pushed %d enemies (nearest %.1f m, farthest %.1f m) via %s%s", pushed,
            (nearest or 0) / 100.0, (farthest or 0) / 100.0, burstReason,
            failed > 0 and string.format(" -- %d failed", failed) or "")
    end
end

-- Pinned at file scope: UE4SS keeps only a registry reference to a delayed
-- callback, and an anonymous chain gets collected out from under it.
local pushLater = function() pcall(pushEnemiesNow) end

-- A timer, and not for lack of trying to find an event. GA_Player_Spawn -- the
-- respawn's own ability, montage notify and all -- was hooked and did fire
-- (the log line carried "via spawn ability", which is the only reason this is
-- known: both of us had assumed the fallback timer). It arrives about 3.5 s
-- after the pawn lands, by which point the enemies have already got a hit in.
--
-- The number below is bracketed by two measured failures rather than picked:
-- at 800 ms everything ran correctly and was invisible, because the screen was
-- still coming back from the death fade; at 3.5 s it was too late to matter.
local BURST_DELAY_MS = 1800

local burstArmed = false

-- Never from inside a hooked Blueprint's own call stack -- that is what froze
-- the game when the teleport was inline. A short delay puts it on its own tick.
-- Waiting for footing, not for the machine. The delay is counted from the
-- landing, so a slow PC moves the starting point rather than stretching the
-- pause -- but if the pawn is somehow still in the air when it expires, the
-- burst waits instead of going off mid-fall.
local BURST_WAIT_MS = 400
local BURST_WAIT_LIMIT = 6
local burstWaits = 0

-- Declared before the body that re-arms it: a Lua closure only captures a
-- local that already exists, otherwise it silently reads a nil global.
local fireFromTimer

local function fireBurst(reason)
    if not burstArmed then return end

    local pawn = firstOf("BP_PlayerCharacter_C")
    if valid(pawn) and onFoot(pawn) == false and burstWaits < BURST_WAIT_LIMIT then
        burstWaits = burstWaits + 1
        ExecuteInGameThreadWithDelay(BURST_WAIT_MS, fireFromTimer)
        return
    end

    burstArmed = false
    -- Carried into the summary line rather than logged separately: which
    -- anchor won is the one thing worth knowing about a respawn burst, and
    -- guessing it from timestamps is how the last two rounds were wasted.
    burstReason = reason
    ExecuteInGameThreadWithDelay(80, pushLater)
end

fireFromTimer = function() pcall(fireBurst, "landing") end

schedulePush = function()
    if not pushPending then return end
    pushPending = false
    burstShown = false
    burstArmed = true
    burstWaits = 0
    -- Granted again from here: the first window is counted from the
    -- teleport, and a slow-streaming hold can outlast it before the push
    -- has even been scheduled. The player has no controls during the hold,
    -- so that is the one stretch that must never be uncovered.
    -- schedulePush is reached from settleTick, i.e. from inside the sampler
    -- hook; a Blueprint call from there goes through deferWake like every
    -- other one.
    deferWake(function()
        local p = firstOf("BP_PlayerCharacter_C")
        if valid(p) then grantInvulnerability(p, CONFIG.InvulnerableSeconds) end
    end)
    ExecuteInGameThreadWithDelay(BURST_DELAY_MS, fireFromTimer)
end

local function deliver()
    if pendingSpot == nil then return end
    -- By delivery time the spoils actor usually exists, and its spot went
    -- through the EQS query that guarantees somewhere reachable -- better than
    -- anything we recorded. Unless the player marked a spot by hand: that is
    -- an explicit instruction, and the spoils lie where they died instead.
    local target = pendingSpot
    if not pendingSpot.fromMark then
        target = locationOf(unrecoveredSpoils()) or pendingSpot
    end
    local pawn = firstOf("BP_PlayerCharacter_C")
    if not valid(pawn) then return end
    local l = locationOf(pawn)
    if l == nil then return end
    local dx, dy, dz = l.x - target.x, l.y - target.y, l.z - target.z
    local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
    -- The 15 m tolerance is for the place of death, where close enough is
    -- good enough. A mark is a precise order: honour it down to 3 m, so a
    -- mark set within sight of the beacon still gets its teleport.
    local within = pendingSpot.fromMark and 300.0 or CONFIG.ArrivedWithin
    -- Only a death earns the shove: a resume or a travel puts you somewhere
    -- you chose, and knocking the neighbourhood over there is just noise.
    pushPending = pendingSpot.afterDeath == true and CONFIG.Enabled
    local viaResume = pendingSpot.viaResume == true
    -- Read before the nil below; indexing pendingSpot after it killed deliver
    -- mid-flight, silently, right past the teleport log line.
    local spotSel = pendingSpot.sel
    pendingSpot = nil
    if dist <= within then
        log("already at the target, distance %.0f", dist)
        schedulePush()
        return
    end
    local ok = teleportTo(pawn, target)
    log("pawn was %.0f away, teleport %s", dist, ok and "done" or "FAILED")

    -- The teleport is what makes the destination start streaming, so the first
    -- one always lands in mid-air. Hold the pawn on the spot; the settle pass
    -- wakes the dungeon machinery if the pawn is still falling a second later.
    if ok then
        stopFall(pawn)
        dropFooting(pawn)
        -- Counted from here, not from the landing: the hold itself is part of
        -- what has to be survived, and it is the part with no controls.
        if grantInvulnerability(pawn, CONFIG.InvulnerableSeconds) then
            log("invulnerability requested for %.1fs", CONFIG.InvulnerableSeconds)
        end
        local now = os.time()
        settle = { x = target.x, y = target.y, z = target.z,
                   since = now, deadline = now + CONFIG.SettleSeconds, ticks = 0,
                   -- Where the game had put the pawn. A resume that turns out to
                   -- lead into a sleeping dungeon is undone by going back here.
                   viaResume = viaResume,
                   -- Which level instance this spot belongs to, if it is known.
                   -- A resume carries it from the state file; an in-session
                   -- death takes the live answer, which is the same thing.
                   sel = spotSel or target.sel or currentSelector,
                   origin = { x = l.x, y = l.y, z = l.z } }
    end
end

--===================================================================== hooks ===

-- The callback goes in the PRE slot, and that is not a detail. Registered as a
-- post callback the very same hook never fired once on this build -- two deaths
-- with Gloom in hand went unnoticed, which read as "the game does not call this
-- function" until the earlier pre-hook version turned out to have worked fine.
-- Pre means the spoils actor does not exist yet, hence the sampled fallback.
-- The genuine death signal, found by tracing who owns CreateDeathScreen:
-- GA_Death_Player_C:HandlePlayerDeath unpossesses the pawn, grants the death
-- state and broadcasts GlobalEvent_PlayerDeath. Unlike everything on the spoils
-- handler it fires on death and only on death.
--
-- Without it the mod had to infer a death from having sampled a live pawn
-- seconds earlier, which is true for a death and false for a load from the main
-- menu -- but also true for a load that happens moments after a death.
local okDeath = false
local function installDeath()
    if okDeath then return true end
    okDeath = pcall(function()
        RegisterHook(PLAYER_DEATH, function()
            -- Recorded even with respawn off: the flag also tells the
            -- stay-dead list to reset, which is vanilla behaviour and has
            -- nothing to do with where the player comes back.
            died = true
            log("player death")
        end)
    end)
    return okDeath
end

-- Held at file scope so the registry ref UE4SS keeps for the delayed call can
-- never be the only thing keeping the closure alive.
local deliverLater = function() pcall(deliver) end

local eventHooked = {}
local function installEvents()
    local all = true
    for _, event in ipairs(DEATH_EVENTS) do
        if not eventHooked[event] then
            eventHooked[event] = pcall(function()
                RegisterHook(DEATH_ABIL .. ":" .. event, function()
                    -- A pending spot means some feature already decided to move
                    -- the player; delivering it is not the respawn switch's call.
                    if not CONFIG.Enabled and pendingSpot == nil then return end
                    if CONFIG.Verbose then log("%s fired", event) end
                    -- Not inline. A teleport executed from inside the
                    -- ability's own call once froze the game solid: the log
                    -- ended between "fired" and "teleport done". Let the
                    -- Blueprint finish, then move the pawn.
                    if event == "SpartaAbilityCommitted" then
                        ExecuteInGameThreadWithDelay(150, deliverLater)
                    end
                end)
            end)
        end
        all = all and eventHooked[event]
    end
    return all
end

local okChoose = false
local function installChoose()
    if okChoose then return true end
    okChoose = pcall(function()
    RegisterHook(GAME_MODE .. ":ChoosePlayerStart", function(Context)
        -- The landing areas are guaranteed loaded by now; on a cold start the
        -- attempt at file scope ran at the main menu and found none.
        if installBeaconHooks ~= nil then pcall(installBeaconHooks) end
        if installSpawnerHooks ~= nil then pcall(installSpawnerHooks) end
        if installTravelGuard ~= nil then pcall(installTravelGuard) end
        -- Vanilla revives everything on a death, and the mod follows suit: a
        -- death wipes the stay-dead list, whatever the beacon toggle says.
        -- The list only ever bridges a quit, and optionally a rest.
        if died and clearStayDead ~= nil then
            pcall(clearStayDead, "death respawn")
        end
        -- Every spawn is a fresh set of spawner objects, so the stay-dead
        -- flags have to be re-applied here -- and once more a few seconds
        -- later, for spawners that stream in after the game mode ran.
        if applyStayDead ~= nil then
            pcall(applyStayDead, "spawn")
            ExecuteInGameThreadWithDelay(4000, function()
                if applyStayDead ~= nil then pcall(applyStayDead, "post-load") end
            end)
        end
        local gameMode = Context:get()
        local currentName = "?"
        pcall(function()
            local c = gameMode.CustomPlayerStart
            currentName = valid(c) and c:GetFName():ToString() or "null"
        end)

        -- The position comes from the sampler, never from a death event.
        -- Sampling runs while a pawn exists and stops when the level unloads,
        -- so at this exact moment the ring still holds where you were standing
        -- before you died -- the new pawn does not exist yet. A load from the
        -- main menu has no samples at all, which is what tells the two apart.
        --
        -- Death events are only logged. SpartaAbilityCommitted in particular
        -- fires three seconds after a level load, not on death, and using it as
        -- the source of the coordinate sent the player straight back to the
        -- beacon they had just spawned at.
        -- With the death hook registered, a respawn is a respawn only when the
        -- player actually died. Without it, fall back to the old rule: having
        -- sampled a live pawn seconds ago means the level reloaded under us.
        -- The death screen offers the beacon or the hub, and the choice is
        -- expressed by which player start the save ends up naming: picking the
        -- hub sends GetHUBPlayerStart through SetRespawnPlayerStart. By the
        -- time we get here SelectCustomPlayerStart has already resolved that
        -- name into an actor, so the class of what sits in CustomPlayerStart
        -- says which button was pressed -- no need to hook the menu at all.
        local wantsHub = false
        pcall(function()
            local c = gameMode.CustomPlayerStart
            if valid(c) then
                local cn = c:GetClass():GetFName():ToString()
                wantsHub = cn:find("HUB") ~= nil
            end
        end)

        local target, source = nil, "none, respawning vanilla"
        -- viaMark means "an explicit order, not a guess": deliver to the exact
        -- coordinate, skip the spoils override and the player-start borrow.
        -- True for a manual mark and for the resume-at-quit spot alike.
        local viaMark = false
        -- A resume is the one case where the destination may be somewhere the
        -- game has never taken the player: quitting inside a dungeon and loading
        -- again puts the world back without its dungeon. See settleTick.
        local viaResume = false

        local wasArmed = resumePending
        if resumePending then
            resumePending = false
            if CONFIG.ResumeAtQuit and not wantsHub and not died
               and quitSpot ~= nil then
                -- A brand-new run has no session save to resume; without this
                -- gate, starting a new game would teleport the player to the
                -- previous save's quit spot.
                local hasSession = true
                pcall(function()
                    hasSession = gameMode:GetStartTransformFromSessionSave({}) == true
                end)
                if hasSession then
                    if quitSpot.sealed and not CONFIG.DeliverIntoClosedDungeons then
                        -- Recorded while the player was still in there: that
                        -- dungeon's exit only works while its zone is alive, and
                        -- a fresh load has none. Going back in would seal them.
                        source = "quit spot is inside a sealed dungeon, standing aside"
                    else
                        target, source, viaMark = quitSpot, "quit spot (resume)", true
                        viaResume = true
                    end
                end
            end
        end

        -- The panel's big switch governs respawning and nothing else, so this
        -- half is the only one it gates. Continuing where you quit stays on
        -- its own toggle: wanting one without the other is a fair ask, and the
        -- switch is labelled RESPAWN precisely so it cannot promise otherwise.
        -- Dying inside a dungeon whose only exit is a dialogue: bringing the
        -- player back would seal them in, because the level we would wake has
        -- no zone to answer that dialogue. Noted while they were alive, so no
        -- flight out and back is needed to find out.
        if died and sealedNow and marked == nil
           and not CONFIG.DeliverIntoClosedDungeons then
            log("you died in a dungeon whose only exit is a dialogue -- standing "
                .. "aside so the game's own respawn keeps that exit working")
            died = false
            ring = {}
            return
        end

        if target == nil and not wantsHub and (died or not okDeath) then
            if marked ~= nil then
                target, source, viaMark = marked, "marked spot", true
            elseif CONFIG.Enabled then
                target, source = agedSample(), "sampled position"
            end
            if target == nil then source = "none, respawning vanilla" end
        end

        log("ChoosePlayerStart fired, CustomPlayerStart = %s, died = %s, hub = %s, armed = %s, target = %s",
            currentName, tostring(died), tostring(wantsHub), tostring(wasArmed), source)

        if wantsHub then died = false end

        -- No Enabled check here any more: a target only exists if whichever
        -- feature produced it was allowed to.
        if target == nil or not valid(gameMode) then return end

        -- The spoils actor normally beats our own reading: the game placed it
        -- through a reachability query, so it is guaranteed to stand on ground
        -- you can walk away from. But a mark is an explicit instruction, and
        -- the spoils lie where the player died, which may be far from it.
        local spot = target
        if not viaMark then spot = locationOf(unrecoveredSpoils()) or target end
        pendingSpot = { x = spot.x, y = spot.y, z = spot.z,
                        fromMark = viaMark, afterDeath = died,
                        viaResume = viaResume,
                        -- The recorded level instance rides along, or the
                        -- named wake never sees it: review 2026-09-02 found
                        -- QuitSel loaded, carried to `target`, and dropped
                        -- right here, which made the whole feature dead on
                        -- the one path it was written for.
                        sel = spot.sel or target.sel }

        -- A mark changes the machinery, not just the coordinate. The borrowed
        -- player start turned out to anchor where the game drops the return
        -- Gloom: moved to the mark, it dragged the Gloom there while the
        -- player still woke up at the beacon. So with a mark no start is
        -- touched at all -- the teleport alone does the job, and the Gloom
        -- stays where the player actually died.
        if pendingSpot.fromMark then
            ring = {}
            died = false
            armWatch(spot)
            return
        end

        local ps = borrowPlayerStart(gameMode)
        if not valid(ps) then
            log("no spare player start to borrow -- leaving it to the fallback")
            armWatch(spot)
            ring = {}
            return
        end

        local orig = locationOf(ps)
        if orig then borrowed = { start = ps, x = orig.x, y = orig.y, z = orig.z } end

        -- A PlayerStart is a static actor, and UE refuses to move a static root
        -- component at runtime -- without a word. That is why the previous run
        -- looked so confusing: the variable accepted our start, the start never
        -- left the spot its level designer put it on, and the player woke up
        -- there. Flip mobility to Movable first, remember what it was.
        local prevMobility
        pcall(function()
            local root = ps.RootComponent
            if root == nil then return end
            prevMobility = root.Mobility
            local okSet = pcall(function() root:SetMobility(2) end)  -- Movable
            if not okSet then root.Mobility = 2 end
        end)
        if borrowed then borrowed.mobility = prevMobility end

        local moved = pcall(function()
            ps:K2_SetActorLocation({ X = spot.x, Y = spot.y, Z = spot.z + CONFIG.OffsetZ }, false, {}, false)
            gameMode.CustomPlayerStart = ps
        end)
        if not moved then
            log("could not move the player start -- leaving it to the fallback")
            borrowed = nil
        else
            -- Read both writes back. Last run the pawn still came up at the
            -- beacon, so one of the two did not stick, and the log has to say
            -- which: the actor that refused to move, or the variable that
            -- refused to hold it.
            local after = locationOf(ps)
            local heldName = "?"
            pcall(function()
                local c = gameMode.CustomPlayerStart
                heldName = valid(c) and c:GetFName():ToString() or "null"
            end)
            if CONFIG.Verbose then log("asked for %.0f %.0f %.0f | start now at %s | CustomPlayerStart = %s",
                spot.x, spot.y, spot.z,
                after and string.format("%.0f %.0f %.0f", after.x, after.y, after.z) or "unreadable",
                heldName) end
        end

        ring = {}
        died = false
        armWatch(spot)
        ExecuteWithDelay(5000, function() ExecuteInGameThread(releasePlayerStart) end)
    end)
    end)
    return okChoose
end

-- Re-arms the resume flag on every fresh game mode. Held in file-scope locals
-- so the UE4SS registry reference can never be the only thing keeping the
-- callback alive.
-- Measured, not assumed: travelling between beacons constructs a game mode
-- exactly like continuing from the main menu does, and the launcher and
-- traversal abilities never fired a hook at all. So a game mode alone cannot
-- tell the two apart, and arming on every one of them dragged the player back
-- to the hub on every trip.
--
-- The unambiguous signal is the main menu itself: the player pressing Continue
-- (or confirming a save slot). That happens on the launch load and on a return
-- from the menu -- the two cases a resume is for -- and never on a trip.
-- Found by enumerating UFunctions: FindAllOf cannot list classes on this build
-- but lists all 35k functions happily, which is how a Blueprint button event
-- becomes findable at all.
local MENU_ARM_FNS = {
    "/Game/Sparta/UI/MainMenu/WBP_MainMenu.WBP_MainMenu_C:BndEvt__WBP_MainMenu_WBP_MGT_MainScreen_K2Node_ComponentBoundEvent_1_OnContinueCommitted__DelegateSignature",
    "/Game/Sparta/UI/MainMenu/WBP_MainMenu.WBP_MainMenu_C:BndEvt__WBP_MainMenu_WBP_MGT_SaveSlots_K2Node_ComponentBoundEvent_2_OnSlotConfirmed__DelegateSignature",
}

local menuArmHooked = {}
local menuArmWorks = false

local armFromMenu = function()
    resumePending = true
    log("resume armed: loading a save from the main menu")
end

local function installMenuArm()
    local all = true
    for _, path in ipairs(MENU_ARM_FNS) do
        if not menuArmHooked[path] then
            local owns = false
            pcall(function()
                local fn = StaticFindObject(path)
                owns = fn ~= nil and fn:IsValid()
            end)
            if owns then
                menuArmHooked[path] = pcall(function()
                    RegisterHook(path, armFromMenu)
                end)
                if menuArmHooked[path] then
                    menuArmWorks = true
                    log("menu arm hook installed on %s", path:match("([^:]+)$"))
                end
            end
        end
        all = all and (menuArmHooked[path] == true)
    end
    return all
end

-- Fallback only. With the menu hooks in place this must never fire: it cannot
-- tell a trip from a continue, which is the whole bug it once caused.
local okResumeArm = false
local armedOnce = false

local armResume = function()
    if menuArmWorks or armedOnce then return end
    armedOnce = true
    resumePending = true
    log("resume armed: first game mode of this session (menu hook missing)")
end

local function installResumeArm()
    if okResumeArm then return true end
    okResumeArm = pcall(function()
        NotifyOnNewObject(GAME_MODE, armResume)
    end)
    if not okResumeArm then
        -- No notification, no way to tell a continue from a travel: fall back
        -- to the old rule and let the first spawn we see have it.
        resumePending = true
        log("resume arming unavailable -- falling back to the first spawn")
        return false
    end
    -- A hot reload happens mid-session, where the game mode is long since
    -- built and the next spawn is whatever the player does next -- a travel,
    -- most likely. Spend the one fallback arming right here so it cannot fire.
    if not armedOnce then
        local live = FindAllOf("BP_SpartaGameMode_C")
        if live ~= nil and #live > 0 then
            armedOnce = true
            log("game already running -- resume not armed for this reload")
        end
    end
    return true
end

--=========================================================== hook installer ===

-- Every hook above targets a Blueprint, and a Blueprint class does not exist
-- until the game loads the asset that owns it. At mod-start time the player is
-- still on the title screen and none of them are there, so a single attempt
-- registers nothing and the mod stays dead for the whole session.
--
-- That is not a theoretical worry, it is what a clean install looks like. It
-- went unnoticed for weeks because other mods in the folder pulled those
-- Blueprints in first and ours registered on their coat-tails. With only this
-- mod installed nothing does. Measured on a fresh install: attempt 1 failed,
-- attempt 2 two seconds later installed everything.
--
-- So keep trying until every hook is in, then stop for good.
local RETRY_MS = 2000
local RETRY_LIMIT = 150      -- five minutes, then give up and say so

local installer = {}
local attempts = 0

installer.run = function()
    attempts = attempts + 1
    local ready = installSampler()
    ready = installDeath() and ready
    ready = installEvents() and ready
    ready = installChoose() and ready
    ready = installResumeArm() and ready
    -- Once any menu hook has taken, the rest only exist while the main menu
    -- widget is loaded; insisting on all of them kept the installer retrying
    -- for five minutes on a healthy install and logging a failure at the end.
    ready = (installMenuArm() or menuArmWorks) and ready
    -- Defined further down the file, so the very first run skips it; the
    -- retry two seconds later -- and every ChoosePlayerStart -- picks it up.
    if installSpawnerHooks ~= nil then
        ready = installSpawnerHooks() and ready
    end
    if installTravelGuard ~= nil then
        ready = installTravelGuard() and ready
    end

    if ready then
        log("all hooks installed (attempt %d)", attempts)
        return
    end
    if attempts >= RETRY_LIMIT then
        log("giving up after %d attempts -- sampler %s, death %s, choose %s",
            attempts, okSampler and "ok" or "FAILED",
            okDeath and "ok" or "FAILED", okChoose and "ok" or "FAILED")
        return
    end
    ExecuteInGameThreadWithDelay(RETRY_MS, installer.run)
end

installer.run()

--=================================================================== switch ===

-- One switch, several entry points: the menu checkbox, an optional key, and
-- whatever loadState read at startup. All of them go through here so the
-- cleanup and the save never get skipped.
local syncMenu   -- set below if the shared ModMenu library is present

local function setEnabled(on)
    if CONFIG.Enabled == on then return end
    CONFIG.Enabled = on
    if not on then
        pendingSpot, ring, died = nil, {}, false
        -- An in-flight hold ends too, on foot: otherwise settleTick keeps
        -- pulling the pawn back for up to SettleSeconds after the switch,
        -- and the falling mode dropFooting set would have no one to undo it.
        if settle ~= nil then
            settle = nil
            local p = firstOf("BP_PlayerCharacter_C")
            if valid(p) then takeFooting(p) end
        end
        ExecuteInGameThread(releasePlayerStart)
    end
    saveState()
    log(on and "ON" or "OFF")
    if syncMenu ~= nil then pcall(syncMenu, on) end
end

--============================================================ manual marking ===

-- Set by the panel once it is built, so marking from anywhere refreshes the
-- status line without this code knowing the menu exists.
local refreshMark = nil
local notifyUser = nil

local function markStatus()
    if marked == nil then
        return "No mark set -- you return to where you died."
    end
    local pawn = firstOf("BP_PlayerCharacter_C")
    local l = pawn and locationOf(pawn) or nil
    if l == nil then
        return "Mark set."
    end
    local dx, dy, dz = l.x - marked.x, l.y - marked.y, l.z - marked.z
    return string.format("Mark set, %.0f m from here.",
        math.sqrt(dx * dx + dy * dy + dz * dz) / 100.0)
end

local function markHere()
    local pawn = firstOf("BP_PlayerCharacter_C")
    local l = pawn and locationOf(pawn) or nil
    if l == nil then
        log("cannot mark: no player character right now")
        if notifyUser ~= nil then pcall(notifyUser, "Cannot set marker right now") end
        return
    end
    marked = { x = l.x, y = l.y, z = l.z }
    saveState()
    log("marked %.0f %.0f %.0f", l.x, l.y, l.z)
    if notifyUser ~= nil then pcall(notifyUser, "Respawn marker set") end
    if refreshMark ~= nil then pcall(refreshMark) end
end

local function clearMark()
    if marked == nil then
        if notifyUser ~= nil then pcall(notifyUser, "No respawn marker to clear") end
        return
    end
    marked = nil
    saveState()
    log("mark cleared")
    if notifyUser ~= nil then pcall(notifyUser, "Respawn marker cleared") end
    if refreshMark ~= nil then pcall(refreshMark) end
end

--================================================================ stay dead ===

-- Quitting the game resurrects every enemy, because the "dead until you rest"
-- state is runtime-only. The persistent half already exists: every spawner
-- carries a SpartaSaveComponent whose BPSO_SpawnerSaveObj payload keeps
-- WasEverKilled on disk, and the spawn path suppresses the spawn when
-- PermaDeath is also set -- that is how bosses stay dead. Verified live: with
-- PermaDeath forced on an everKilled spawner the enemy did not come back, not
-- on approach and not after a beacon rest; everything else respawned normally.
--
-- So the mod records which spawners lost their enemy since the last rest and,
-- on the next session, sets PermaDeath on exactly those. The game does the
-- rest with its own machinery: no actors are destroyed, no encounter logic is
-- bypassed. PermaDeath itself is not part of the save payload, so nothing we
-- write here can corrupt a save -- a plain restart reverts every flag.

local function guidOf(spawner)
    local hex = nil
    pcall(function()
        local g = spawner.SpartaSave.Guid
        hex = string.format("%08X%08X%08X%08X",
            g.A & 0xFFFFFFFF, g.B & 0xFFFFFFFF, g.C & 0xFFFFFFFF, g.D & 0xFFFFFFFF)
    end)
    return hex
end

local function recordSpawnerDeath(spawner)
    if not valid(spawner) then return end
    -- A spawner that is already permadeath is the game's own business (a
    -- boss); recording it would make the beacon-rest clear below revive it.
    local ownPerma = false
    pcall(function() ownPerma = spawner.PermaDeath == true end)
    if ownPerma then return end
    local g = guidOf(spawner)
    if g == nil or deadSpawners[g] then return end
    deadSpawners[g] = true
    deadCount = deadCount + 1
    saveState()
    if CONFIG.Verbose then log("enemy death recorded (%d kept dead)", deadCount) end
end

-- PermaDeath off again on every spawner we touched. Used by the beacon clear
-- and by switching the feature off mid-session.
local function unflagLive()
    local n = 0
    if deadCount == 0 then return n end
    for _, s in ipairs(FindAllOf("BP_Spawner_C") or {}) do
        if valid(s) then
            local g = guidOf(s)
            if g ~= nil and deadSpawners[g] then
                if pcall(function() s.PermaDeath = false end) then n = n + 1 end
            end
        end
    end
    return n
end

-- Both halves of keeping one spawner dead, in one place, because the second
-- half is not optional and used to be missing from the late path.
--
-- PermaDeath only suppresses a spawn that has NOT happened yet. Inside a
-- dungeon the flag always lands second: the level instance comes up with its
-- spawners AND their enemies already on the ground, and the mod hears about
-- those spawners only through NotifyOnNewObject, 700 ms behind. Flagging them
-- then is a promise about the next session, not about this one -- which is
-- exactly what the player saw: enemies they had killed standing there after a
-- resume, on spawners the mod had correctly marked PermaDeath = true.
--
-- TryDespawnEnemy is the cleanup and it does work; the flag it moves is
-- IsSpawnedEnemyDestroyed, NOT IsSpawnedEnemyDead. Despawning is not dying:
-- the enemy is removed, so nothing about the death state changes, and reading
-- the wrong flag makes a working call look like a no-op. Measured on four live
-- tomb spawners on 2026-08-29.
local function enforceDead(s)
    local flagged, despawned = false, false

    local isPerma = false
    pcall(function() isPerma = s.PermaDeath == true end)
    if not isPerma then
        if pcall(function() s.PermaDeath = true end) then flagged = true end
    end

    local fin, deadNow, gone = false, false, false
    pcall(function() fin = s.FinishedSpawn == true end)
    pcall(function() deadNow = s.IsSpawnedEnemyDead == true end)
    pcall(function() gone = s.IsSpawnedEnemyDestroyed == true end)
    if fin and not deadNow and not gone then
        if pcall(function() s:TryDespawnEnemy() end) then despawned = true end
    end

    return flagged, despawned
end

-- Not gated by the respawn switch either: keeping a cleared area cleared
-- across a quit belongs to the continue-after-quit half of the mod.
function applyStayDead(where)
    if deadCount == 0 then return end
    local flagged, despawned = 0, 0
    for _, s in ipairs(FindAllOf("BP_Spawner_C") or {}) do
        if valid(s) then
            local g = guidOf(s)
            if g ~= nil and deadSpawners[g] then
                local f, d = enforceDead(s)
                if f then flagged = flagged + 1 end
                if d then despawned = despawned + 1 end
            end
        end
    end
    if flagged > 0 or despawned > 0 then
        log("stay dead: %d spawners flagged, %d enemies despawned (%s)",
            flagged, despawned, where)
    end
end

function clearStayDead(reason)
    if deadCount == 0 then return end
    local n = unflagLive()
    deadSpawners = {}
    deadCount = 0
    saveState()
    log("stay dead cleared: %s (%d spawners released)", reason, n)
end

-- Spawners that stream in later than the post-load sweep -- a dungeon interior
-- above all -- announce themselves here. The flagging is deferred, because at
-- construction time the actor's components are not loaded yet.
local newSpawners = {}

local flagNewSpawners = function()
    if #newSpawners == 0 then return end
    local batch = newSpawners
    newSpawners = {}
    if deadCount == 0 then return end
    local flagged, despawned = 0, 0
    for _, s in ipairs(batch) do
        if valid(s) then
            local g = guidOf(s)
            if g ~= nil and deadSpawners[g] then
                local f, d = enforceDead(s)
                if f then flagged = flagged + 1 end
                if d then despawned = despawned + 1 end
            end
        end
    end
    -- Logged unconditionally, unlike before: this path is the one that carries
    -- a dungeon's own spawners, and it used to flag them silently while their
    -- enemies walked around.
    if flagged > 0 or despawned > 0 then
        log("stay dead: %d late spawners flagged, %d enemies despawned", flagged, despawned)
    end
end

-- The death signal lives on SpawnedEnemyDeathStarted. The subclasses override
-- it (BP_Spawner_Proximity_C does), and an override is its own UFunction that
-- a hook on the parent never sees -- so every class that owns one gets its own
-- hook, discovered with StaticFindObject exactly like the beacon hook below.
local SPAWNER_CLASS = "/Game/Sparta/Characters/SpawnSystem/BP_Spawner.BP_Spawner_C"
local SPAWNER_DEATH_FNS = {
    SPAWNER_CLASS .. ":SpawnedEnemyDeathStarted",
    "/Game/Sparta/Characters/SpawnSystem/BP_Spawner_Proximity.BP_Spawner_Proximity_C:SpawnedEnemyDeathStarted",
    "/Game/Sparta/Characters/SpawnSystem/BP_Spawner_Jump.BP_Spawner_Jump_C:SpawnedEnemyDeathStarted",
}

local spawnerHooked = {}
local notifyArmed = false

function installSpawnerHooks()
    for _, fnPath in ipairs(SPAWNER_DEATH_FNS) do
        if not spawnerHooked[fnPath] then
            local owns = false
            pcall(function()
                local fn = StaticFindObject(fnPath)
                owns = fn ~= nil and fn:IsValid()
            end)
            if owns then
                local okH, err = pcall(function()
                    RegisterHook(fnPath, function(Context)
                        local s
                        pcall(function() s = Context:get() end)
                        pcall(recordSpawnerDeath, s)
                    end)
                end)
                if okH then
                    spawnerHooked[fnPath] = true
                    log("spawner death hook installed on %s", fnPath)
                else
                    log("spawner death hook FAILED on %s: %s", fnPath, tostring(err))
                end
            end
        end
    end
    if not notifyArmed then
        notifyArmed = pcall(function()
            NotifyOnNewObject(SPAWNER_CLASS, function(obj)
                if deadCount == 0 then return end
                newSpawners[#newSpawners + 1] = obj
                ExecuteInGameThreadWithDelay(700, flagNewSpawners)
            end)
        end)
    end
    -- The parent hook is the essential one; the overrides only exist on some
    -- classes and register whenever their class first loads.
    return spawnerHooked[SPAWNER_DEATH_FNS[1]] == true
end

-- There was a travel guard here: hooks on GA_Traversal_EnterBeacon and the
-- three GA_LauncherDevice_* abilities, meant to mark "the next spawn is a
-- trip, not a continue". All four registered and not one of them fired across
-- three measured beacon trips, so beacon travel does not run through them.
-- Removed rather than kept as decoration; the resume arming above no longer
-- needs a guard, and if a real travel signal is ever found, this is where it
-- would go.
function installTravelGuard() return true end

--=================================================================== beacon ===

-- "Using a beacon" is the beacon calling its own SetPlayerStart -- the moment
-- it becomes the respawn anchor, which is exactly when a manual mark stops
-- being a plan and starts being a trap. HandleInteract was considered and
-- rejected: it fires on merely opening the beacon menu, even to glance and
-- leave. Both names came from a live dump of BP_LandingArea_C /
-- BP_LandingArea_Checkpoint_C (probe of 27.08); the attempt before that
-- watched a fast travel widget that turned out never to exist -- 0 instances
-- even with the beacon menu open.
--
-- Full class paths are taken from live instances, so nothing is hard-coded
-- beyond the short names; registration is re-attempted from ChoosePlayerStart,
-- which runs on every spawn, when the landing areas are guaranteed loaded.
local beaconHooked = {}

function installBeaconHooks()
    -- Any live landing area will do as a door into the class hierarchy.
    local sample
    for _, short in ipairs({ "BP_LandingAreaBase_C", "BP_LandingArea_C",
                             "BP_LandingArea_Checkpoint_C" }) do
        for _, a in ipairs(FindAllOf(short) or {}) do
            if valid(a) then sample = a break end
        end
        if sample ~= nil then break end
    end
    if sample == nil then return end

    -- SetPlayerStart lives on the common ancestor, not on the concrete
    -- classes, and RegisterHook resolves the function by exact path -- so walk
    -- up until the owner is found. One hook on the ancestor covers every
    -- subclass, including plain BP_LandingAreaBase_C beacons.
    local cls
    pcall(function() cls = sample:GetClass() end)
    local guard = 0
    while cls ~= nil and guard < 8 do
        guard = guard + 1
        local okF, full = pcall(function() return cls:GetFullName() end)
        local path = okF and type(full) == "string"
            and tostring(full):match("%S+%s+(.+)") or nil
        if path ~= nil then
            if beaconHooked[path] then return end
            local fnPath = path .. ":SetPlayerStart"
            local owns = false
            pcall(function()
                local fn = StaticFindObject(fnPath)
                owns = fn ~= nil and fn:IsValid()
            end)
            if owns then
                local okH, err = pcall(function()
                    RegisterHook(fnPath, function()
                        if CONFIG.Verbose then log("beacon set as respawn") end
                        -- Two separate jobs behind one hook. The stay-dead
                        -- stay-dead handling is independent of respawn. The
                        -- manual mark also remains active with that switch off.
                        if CONFIG.BeaconRevives then
                            -- Resting revives enemies by the game's own rules,
                            -- so it ends the stay-dead list too.
                            if clearStayDead ~= nil then
                                pcall(clearStayDead, "beacon rest")
                            end
                        elseif applyStayDead ~= nil then
                            -- Revival switched off: the kills of this session
                            -- are only recorded so far, and the rest is about
                            -- to run every spawner's reset. Flag them now,
                            -- before that happens, and once more after the
                            -- rest fade-out in case some spawner reset first.
                            pcall(applyStayDead, "beacon rest, revival off")
                            ExecuteInGameThreadWithDelay(2000, function()
                                if applyStayDead ~= nil then
                                    pcall(applyStayDead, "post-rest")
                                end
                            end)
                        end
                        if not CONFIG.ClearMarkOnBeacon then return end
                        if marked == nil then return end
                        clearMark()
                        log("mark cleared: beacon used")
                    end)
                end)
                if okH then
                    beaconHooked[path] = true
                    log("beacon hook installed on %s", fnPath)
                else
                    log("beacon hook FAILED on %s: %s", fnPath, tostring(err))
                end
                return
            end
        end
        local okS, sup = pcall(function() return cls:GetSuperStruct() end)
        cls = (okS and sup) or nil
    end
    log("beacon hook: no class in the chain owns SetPlayerStart")
end

pcall(installBeaconHooks)
-- Same late kick for the spawner hooks: on a hot reload mid-session the
-- installer's first pass ran before this half of the file existed.
pcall(installSpawnerHooks)
pcall(installTravelGuard)

--================================================================== keybind ===

local toggleKey = nil
if type(CONFIG.ToggleKey) == "string" then toggleKey = Key[CONFIG.ToggleKey] end

if toggleKey ~= nil then
    RegisterKeyBind(toggleKey, function()
        setEnabled(not CONFIG.Enabled)
    end)
elseif CONFIG.ToggleKey ~= nil then
    log("unknown toggle key %s -- no key registered", tostring(CONFIG.ToggleKey))
end

--=============================================================== settings UI ===

-- The panel is ours, in ui.lua, and needs nothing but UE4SS. The previous
-- version borrowed a library that ships with another mod, so the panel quietly
-- did nothing wherever that mod was absent.
local okMenu, menuErr = pcall(function()
    local UI = require("ui")

    UI.setup({
        isEnabled  = function() return CONFIG.Enabled end,
        setEnabled = function(on) setEnabled(on) end,
        markHere   = function() markHere() end,
        clearMark  = function() clearMark() end,
        markStatus = function() return markStatus() end,
        isBeaconReset = function() return CONFIG.ClearMarkOnBeacon end,
        toggleBeaconReset = function()
            CONFIG.ClearMarkOnBeacon = not CONFIG.ClearMarkOnBeacon
            saveState()
        end,
        isResume = function() return CONFIG.ResumeAtQuit end,
        toggleResume = function()
            CONFIG.ResumeAtQuit = not CONFIG.ResumeAtQuit
            saveState()
        end,
        isBeaconRevives = function() return CONFIG.BeaconRevives end,
        toggleBeaconRevives = function()
            CONFIG.BeaconRevives = not CONFIG.BeaconRevives
            saveState()
        end,
    })

    -- Keep the panel in step when something else flips the switch.
    syncMenu = function() UI.sync() end
    refreshMark = function() UI.sync() end
    notifyUser = function(message) UI.toast(message) end

    -- Numpad marker shortcuts work independently of the panel and toggle.
    local markerMods = { ModifierKey.CONTROL }
    if Key.NUM_ONE ~= nil then
        RegisterKeyBind(Key.NUM_ONE, markerMods, function() markHere() end)
    end
    if Key.NUM_TWO ~= nil then
        RegisterKeyBind(Key.NUM_TWO, markerMods, function() clearMark() end)
    end

    local menuKey = nil
    if type(CONFIG.MenuKey) == "string" then menuKey = Key[CONFIG.MenuKey] end
    if menuKey == nil then return end

    local mods = CONFIG.MenuCtrl and { ModifierKey.CONTROL } or {}
    RegisterKeyBind(menuKey, mods, function() UI.toggle() end)
    -- The numpad zero should feel the same as the top-row one.
    if CONFIG.MenuKey == "ZERO" then
        RegisterKeyBind(Key.NUM_ZERO, mods, function() UI.toggle() end)
    end
    -- Escape closes but never opens; when the panel is shut the game keeps
    -- Escape to itself.
    RegisterKeyBind(Key.ESCAPE, function()
        if UI.isOpen() then UI.close() end
    end)
end)

if not okMenu then
    log("settings panel unavailable: %s", tostring(menuErr))
end

log("loaded (%s, from %s), hooks %s",
    CONFIG.Enabled and "enabled" or "disabled", CONFIG_SOURCE,
    (okSampler and okDeath and okChoose) and "installed"
        or "waiting for the game to load its Blueprints")

-- Startup: sets up saved settings and timers when the game says the addon is loaded,
-- and creates the invisible frame that paces outgoing frames.

local addonName, ns = ...

ns.sender = CreateFrame("Frame")
ns.sender:Hide()
ns.sender:SetScript("OnUpdate", function() ns:SendStep() end)

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(_, event, name)
  if event == "ADDON_LOADED" and name == addonName then
    PromptPeonDB = PromptPeonDB or {}
    local db = PromptPeonDB
    db.nextSeq = db.nextSeq or 1
    db.pending = db.pending or {}
    db.drafts = db.drafts or {}
    db.results = db.results or {}
    db.opacity = db.opacity or 1
    db.fontSize = db.fontSize or 11
    db.hiddenThreads = db.hiddenThreads or {}
    db.hiddenProjects = db.hiddenProjects or {}
    db.tracked = db.tracked or {}
    db.corpseRuns = db.corpseRuns or {}
    -- Once, for an install from before the tracker was an inbox: threads used to pin themselves when
    -- they started working, and the party frames were on unless you turned them off.
    if not db.inbox then db.inbox, db.tracked, db.partyOn = 1, {}, false end
    db.expanded = db.expanded or {}
    -- Once: a build before 0.38.0 was released kept some expanded tables by their header's words.
    if db.wideTablesBy ~= "mark" then db.wideTables, db.wideTablesBy = {}, "mark" end
    db.faces = db.faces or {}
    if db.faceSet ~= "peons" then db.faces, db.faceSet = {}, "peons" end
    db.levels = db.levels or {}
    db.seen = db.seen or {}
    db.looted = db.looted or {}
    db.achievements = db.achievements or {}
    db.stats = db.stats or {}
    ns.db = db
    for _, entry in ipairs(db.pending) do entry.stuck, entry.waiting, entry.tries = nil, nil, 0 end
    ns:Ingest()
    ns:WriteOutbox()
  elseif event == "PLAYER_LOGIN" then
    ns:CharacterKey()
    if ns:CanSendSilently() then ns:WriteFrame(nil) end -- Clear anything a crash left set.
    if ns.UI then ns.UI:Build() end
    C_Timer.NewTicker(5, function() ns:Tick() end)
    C_Timer.NewTicker(1, function() ns:Listen() end)
    C_Timer.After(1, function() ns:StartNextSend() end)
    -- A few seconds in, once the bridge has had a chance to start. Never forces a reload.
    C_Timer.After(5, function()
      if ns.db and ns:CanSendSilently() then ns:SendHidden(true) end
    end)
  end
end)

--- The key binding, the minimap button and the game's addon list button all open or close the log.
function PromptPeon_Toggle()
  if ns.UI then ns.UI:Toggle() end
end

function PromptPeon_NextWaiting()
  if ns.UI then ns.UI:NextWaiting() end
end

function PromptPeon_Reply()
  if ns.UI then ns.UI:StartReply() end
end

-- The game titles the section in Key Bindings with the global each binding names as its category.
BINDING_HEADER_PROMPTPEON = "Prompt Peon"
BINDING_NAME_PROMPTPEON_TOGGLE = "Open or close the log"
BINDING_NAME_PROMPTPEON_NEXT_WAITING = "Open the next thread waiting on you"
BINDING_NAME_PROMPTPEON_REPLY = "Type a reply to the open thread"

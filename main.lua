return function(mod)
  -- Huge shoutout to the Kanto Companion mod for the inspiration. I took
  -- what it did and it turned into a whole new project entirely.
  --
  -- DISCLAIMER: This overlay requires my badge boost glitch mod. There's no
  -- way around it.
  --
  -- This is an overlay designed solely for solo running. It shows game time,
  -- resets, your Pokemon's moves, stats, growth rate, experience, and more.
  -- It also shows enemy stats. Both sets of stats update in real time to
  -- show stat changes, burn debuffs, badge boost glitch effects, etc.
  --
  -- Everything is drawn solid black with white outlines so it sits under the
  -- game's own battle boxes without fighting them. Types, statuses and the
  -- speed indicator are icons rather than text.
  --
  -- Move power is shown already multiplied out: the same-type bonus and the
  -- type matchup are baked into the number, rounded down at each step the
  -- way the real game does it. The star marks the same-type bonus.
  --
  -- Your Pokemon's HP is a live number with a coloured dot beside it, since
  -- the game's own HUD already draws the bar. Green is full, yellow is hurt,
  -- red is 24% or less.
  --
  -- The speed arrow reads the same adjusted stats the SPD boxes show, so
  -- paralysis, stat stages and badge boosts are all accounted for.
  --
  -- Game time stops for good once the Champion is beaten, so the final time
  -- stays on screen for the end of a recording.
  --
  -- It includes a stylized badge box, a conditional repel counter, and an
  -- indicator when bags are almost full (18, 19, or 20 slots).
  --
  -- I tried to keep this minimal. I made this just for me to use and I'm
  -- happy with it. I likely will not be making many more changes, so what you
  -- see is what you get. If you use this for inspiration, give me a little
  -- credit and do your own thing!

  local OVERLAY_KEYS = { o = true, f8 = true }   -- toggle the passive overlay
  local RESETS_INC_KEY  = "]"    -- manual resets counter: +1
  local RESETS_DEC_KEY  = "["    -- manual resets counter: -1
  local RESETS_ZERO_KEY = "\\"   -- manual resets counter: reset to 0
  local REF_H      = 1440        -- design reference height; everything scales off this
  local INTERVAL   = 0.12        -- seconds between save reads

  local C = _G.__KANTO_INGAME or {}
  _G.__KANTO_INGAME = C
  mod.exports = C
  if C.visible == nil then C.visible = true end    -- shown by default; O/F8 toggles it
  if C.resets == nil then C.resets = mod.save:get("resets", 0) end   -- persists across sessions
  C.fonts   = C.fonts or {}
  C.sprites = C.sprites or {}

  -- engine modules (same sources the streaming mod uses)
  local function req(p) local ok, m = pcall(require, p); return ok and m or nil end
  C.game     = C.game or req("src.core.Game")
  C.TypeChart = C.TypeChart or req("src.battle.TypeChart")
  C.Growth   = C.Growth or req("src.pokemon.Growth")
  C.Badges   = C.Badges or req("src.inventory.Badges")
  C.BattleState = C.BattleState or req("src.battle.BattleState")
  C.Bag      = C.Bag or req("src.inventory.Bag")
  C.Stats    = C.Stats or req("src.pokemon.Stats")
  C.PaletteFX = C.PaletteFX or req("src.render.PaletteFX")
  C.Status   = C.Status or req("src.battle.Status")
  mod.events:on("game.ready", function(p) C.game = (p and p.game) or C.game end)

  -- ---------------------------------------------------------------------
  -- Palette (0..1)
  -- ---------------------------------------------------------------------
  local function hex(s)
    return { tonumber(s:sub(1,2),16)/255, tonumber(s:sub(3,4),16)/255, tonumber(s:sub(5,6),16)/255 }
  end
  local COL = {
    panel = hex("000000"), sub = hex("141414"), plate = hex("1c1c1c"),
    border = hex("ffffff"), text = hex("ffffff"), dim = hex("b9bdc9"),
    xp = hex("5ab0ff"), gold = hex("ffd54a"), outline = hex("000000"),
    bestFill = hex("264a2c"), bestLine = hex("6ed278"),
    hpFull = hex("3cd25a"), hpHurt = hex("f5d232"), hpLow = hex("eb3c3c"),
  }

  -- ---------------------------------------------------------------------
  -- Cheap caches: scaled fonts + species sprites
  -- ---------------------------------------------------------------------
  local FONT_PATH = mod.assets:path("assets/fonts/verdanab.ttf")
  local function getFont(sizePx)
    sizePx = math.max(8, math.floor(sizePx))
    local f = C.fonts[sizePx]
    if not f then
      local ok, nf = pcall(love.graphics.newFont, FONT_PATH, sizePx)
      if not ok then nf = love.graphics.newFont(sizePx) end
      f = nf; C.fonts[sizePx] = f
    end
    return f
  end
  -- Making sure battle sprites get colored the correct way and not be greyscale.
  local function getSprite(speciesId, dPoke)
    -- Cache key includes the color scheme so it can't get stuck wrong forever.
    local def = dPoke[speciesId]
    local pal = C.PaletteFX and C.gameData and C.PaletteFX.monPal(C.gameData, speciesId)
    local cacheKey = speciesId .. ":" .. ((def and def.trueColor) and "TC" or (pal and table.concat(
      { pal[1][1],pal[1][2],pal[1][3], pal[2][1],pal[2][2],pal[2][3],
        pal[3][1],pal[3][2],pal[3][3], pal[4][1],pal[4][2],pal[4][3] }, ",") or "?"))
    if C.sprites[cacheKey] ~= nil then return C.sprites[cacheKey] or nil end
    local rel = def and def.spriteFront
    local img = false
    if rel then
      if def.trueColor then
        -- Same art the real battle screen shows: its own colors, no recolor.
        local ok0, i0 = pcall(love.graphics.newImage, rel)
        if ok0 then img = i0 end
      elseif pal and love.image and love.image.newImageData then
        local ok, id = pcall(love.image.newImageData, rel)
        if ok and id then
          id:mapPixel(function(_, _, r, g, b, a)
            if a == 0 then return r, g, b, a end
            -- Luminance, not just red -- true for all 4 vanilla grayscale
            -- shades (r=g=b, so this gives the same answer as before), and
            -- also correct for a real-color sprite, where red alone isn't
            -- a reliable stand-in for brightness.
            local lum = 0.299*r + 0.587*g + 0.114*b
            local col = lum > 0.83 and pal[1] or lum > 0.5 and pal[2] or lum > 0.17 and pal[3] or pal[4]
            return col[1] / 255, col[2] / 255, col[3] / 255, a
          end)
          local okImg, i = pcall(love.graphics.newImage, id)
          if okImg then img = i end
        end
      end
      if not img then
        -- fallback: just load it plain if coloring fails
        local ok2, i2 = pcall(love.graphics.newImage, rel)
        if ok2 then img = i2 end
      end
    end
    C.sprites[cacheKey] = img
    return img or nil
  end
  -- Separate cache for this mod's own icons (badges, bag, types, statuses, speed).
  C.uiImages = C.uiImages or {}
  local function uiImage(path)
    if C.uiImages[path] ~= nil then return C.uiImages[path] or nil end
    local ok, img = pcall(love.graphics.newImage, path)
    C.uiImages[path] = ok and img or false
    return C.uiImages[path] or nil
  end
  local function typeIconImg(t)
    if not t then return nil end
    return uiImage(mod.assets:path("assets/types/" .. tostring(t):lower() .. ".png"))
  end
  local STATUS_ICON = {
    SLP = "sleep", PAR = "paralysis", BRN = "burn", FRZ = "freeze", PSN = "poison",
  }

  -- ---------------------------------------------------------------------
  -- Reads the save data into something easy to draw.
  -- ---------------------------------------------------------------------
  local function currentBattle()
    local g = C.game; local stk = g and g.stack
    if not (stk and stk.states and C.BattleState) then return nil end
    for i = #stk.states, 1, -1 do
      if getmetatable(stk.states[i]) == C.BattleState then return stk.states[i] end
    end
    return nil
  end
  local function buildState()
    local game = C.game
    local save = game and game.save
    if not save then return nil end
    local data  = game.data or {}
    local dPoke = data.pokemon or {}
    local dMove = data.moves or {}
    C.dPoke = dPoke
    C.gameData = data

    local function dispTypes(raw)
      local o = {}
      for _, t in ipairs(raw or {}) do o[#o+1] = (C.TypeChart and C.TypeChart.displayName(t)) or t end
      return o
    end
    local function hasType(list, t)
      for _, x in ipairs(list or {}) do if x == t then return true end end
      return false
    end
    local function brief(mon)
      if not mon then return nil end
      local d = dPoke[mon.species]
      return {
        name = mon.nickname or (d and d.name) or tostring(mon.species),
        species = mon.species, level = mon.level, hp = mon.hp,
        maxhp = mon.stats and mon.stats.hp, status = mon.status or "OK",
        types = dispTypes(d and d.types),
        stats = mon.stats,
        baseSpeed = d and d.baseStats and d.baseStats.speed,
      }
    end

    local battle = currentBattle()
    local activeMon = battle and battle.player and battle.player.mon or nil
    local teamTypes = {}

    -- Which stat each badge boosts.
    local BADGE_STAT_MAP = {
      BOULDERBADGE = "attack", THUNDERBADGE = "defense",
      SOULBADGE = "speed", VOLCANOBADGE = "special",
    }
    local playerBadgeStat = {}
    if save.inventory then
      for badgeId, stat in pairs(BADGE_STAT_MAP) do
        if save.inventory[badgeId] then playerBadgeStat[stat] = true end
      end
    end

    -- party
    local party = {}
    for i, mon in ipairs(save.party or {}) do
      local def = dPoke[mon.species]
      local raw = (def and def.types) or {}
      local moves = {}
      for _, mv in ipairs(mon.moves or {}) do
        local md = dMove[mv.id]
        local pow = md and md.power or 0
        moves[#moves+1] = {
          name = (md and md.name) or mv.id, pp = mv.pp, maxpp = md and md.pp,
          type = md and md.type and C.TypeChart and C.TypeChart.displayName(md.type) or nil,
          power = pow > 0 and pow or nil,
          status = md and ((md.category == "status") or pow == 0) or nil,
          stab = (md and md.type and hasType(raw, md.type)) or nil,
        }
      end
      if #raw > 0 then teamTypes[#teamTypes+1] = raw end
      local xpProg, xpNext
      if C.Growth and def and def.growthRate and mon.exp and mon.level then
        local rates = data.growth_rates
        local cur = C.Growth.expForLevel(def.growthRate, mon.level, rates)
        local nxt = C.Growth.expForLevel(def.growthRate, mon.level + 1, rates)
        if mon.level >= 100 or nxt <= cur then xpProg, xpNext = 1, 0
        else xpProg = math.max(0, math.min(1, (mon.exp - cur)/(nxt - cur))); xpNext = math.max(0, nxt - mon.exp) end
      end
      party[i] = {
        slot = i, name = mon.nickname or (def and def.name) or tostring(mon.species),
        species = mon.species, level = mon.level, hp = mon.hp,
        maxhp = mon.stats and mon.stats.hp, status = mon.status or "OK",
        types = dispTypes(raw), moves = moves, exp = mon.exp,
        xpProgress = xpProg, xpToNext = xpNext,
        growthRate = def and def.growthRate,
        stats = mon.stats,
        badgeStat = playerBadgeStat,
        baseSpeed = def and def.baseStats and def.baseStats.speed,
        active = (activeMon ~= nil and mon == activeMon) or nil,
      }
    end

    -- trainer
    local badges, badgeCount = {}, 0
    if C.Badges and data then
      for i, e in ipairs(C.Badges.list(data)) do
        local owned = save.inventory[C.Badges.itemFor(e)] and true or false
        if owned then badgeCount = badgeCount + 1 end
        local id = e.id or ("BADGE"..i); local base = id:gsub("BADGE$", "")
        badges[i] = { name = e.name or (base:sub(1,1)..base:sub(2):lower()), owned = owned }
      end
    end
    local dex = save.pokedex or {}
    local function countTrue(t) local n=0; if t then for _,v in pairs(t) do if v then n=n+1 end end end; return n end
    local dexTotal = 0
    for _, d in pairs(dPoke) do if d.dex and d.dex > dexTotal then dexTotal = d.dex end end
    local splitsMod = mod.find("solo_run_splits")
    local splits = splitsMod and splitsMod.exports
    local champ = splits and splits.myTimes and splits.myTimes.CHAMPION
    if not champ and save.flags and save.flags.EVENT_BEAT_CHAMPION_RIVAL then
      champ = C.champTime or save.playTime
    end
    C.champTime = champ

    local trainer = {
      name = (save.player and save.player.name) or "", money = save.money or 0,
      version = save.version or "", playTime = math.floor(champ or save.playTime or 0),
      timeFrozen = champ ~= nil or nil,
      badges = badges, badgeCount = badgeCount, dexSeen = countTrue(dex.seen),
      dexOwned = countTrue(dex.owned), dexTotal = dexTotal > 0 and dexTotal or nil,
      partyCount = #(save.party or {}),
      repelSteps = save.repelSteps or 0,
    }

    -- battle + matchup + catch
    local battleBlock
    if battle then
      local pMon, eMon = battle.player and battle.player.mon, battle.enemy and battle.enemy.mon
      local myTypes = (pMon and dPoke[pMon.species] and dPoke[pMon.species].types) or {}
      local enTypes = (eMon and dPoke[eMon.species] and dPoke[eMon.species].types) or {}
      local matchup
      if C.TypeChart and pMon and eMon then
        if not C.tcReady then C.tcReady = pcall(C.TypeChart.load, data) end
        local ok, res = pcall(function()
          local eff, disp, cat = C.TypeChart.effectiveness, C.TypeChart.displayName, C.TypeChart.category
          local function has(l,t) for _,x in ipairs(l) do if x==t then return true end end return false end
          local myMoves, bi, bs = {}, nil, -1
          for _, mv in ipairs(pMon.moves or {}) do
            local md = dMove[mv.id]
            if md then
              local pow = md.power or 0
              local st = (md.category == "status") or pow == 0
              local mult = eff(md.type, enTypes); local stab = has(myTypes, md.type)
              myMoves[#myMoves+1] = { name = md.name or mv.id, type = disp(md.type),
                power = pow > 0 and pow or nil, pp = mv.pp, maxpp = md.pp,
                mult = mult, stab = stab or nil, status = st or nil }
              if not st and mult > 0 then local sc = mult*pow*(stab and 15 or 10); if sc > bs then bs=sc; bi=#myMoves end end
            end
          end
          if bi then myMoves[bi].best = true end
          local enemyMoves = {}
          for _, mv in ipairs(eMon.moves or {}) do
            local md = dMove[mv.id]
            if md then
              local pow = md.power or 0
              local st2 = (md.category == "status") or pow == 0
              local mult = eff(md.type, myTypes)
              enemyMoves[#enemyMoves+1] = { name = md.name or mv.id, type = disp(md.type),
                power = pow > 0 and pow or nil, pp = mv.pp, maxpp = md.pp,
                mult = mult, stab = has(enTypes, md.type) or nil, status = st2 or nil }
            end
          end
          return { myMoves = myMoves, enemyMoves = enemyMoves }
        end)
        if ok then matchup = res end
      end
      battleBlock = { kind = battle.kind, trainer = battle.trainer and battle.trainer.name or nil,
        enemy = brief(eMon), active = brief(pMon), matchup = matchup }
      if battleBlock.enemy and matchup and matchup.enemyMoves then
        battleBlock.enemy.moves = matchup.enemyMoves
      end
      -- Stat stage changes read straight from the battle itself.
      if battleBlock.enemy and battle.enemy then
        battleBlock.enemy.stages = battle.enemy.stages
        battleBlock.enemy.confusedTurns = battle.enemy.confusedTurns
        battleBlock.enemy.tarred = battle.enemy.tarred
        battleBlock.enemy.liveStats = battle.enemy.curStats
        local enBadges = battle.enemy.badges or {}
        local enBadgeStat = {}
        for badgeId, stat in pairs(BADGE_STAT_MAP) do
          if enBadges[badgeId] then enBadgeStat[stat] = true end
        end
        battleBlock.enemy.badgeStat = enBadgeStat
      end
      if party[1] and battle.player then
        party[1].stages = battle.player.stages
        party[1].confusedTurns = battle.player.confusedTurns
        party[1].liveStats = battle.player.curStats
      end
    end

    -- Adds move effectiveness info to the lead Pokemon's own move list.
    if battleBlock and battleBlock.matchup and battleBlock.matchup.myMoves
       and party[1] and party[1].moves then
      for i, mv in ipairs(party[1].moves) do
        local em = battleBlock.matchup.myMoves[i]
        if em then mv.mult = em.mult; mv.stab = em.stab; mv.best = em.best end
      end
    end

    -- One place decides what a stat reads, so the SPD boxes and the speed
    -- arrow can never disagree with each other.
    local STAT_KEYS = { "attack", "defense", "special", "speed" }
    local function shownStats(e)
      local base = e.stats or {}
      local stages = e.stages or {}
      local badge = e.badgeStat or {}
      local live = e.liveStats
      local pen = e.status and C.Status and C.Status.RECORDS
        and C.Status.RECORDS[e.status] and C.Status.RECORDS[e.status].statPenalty
      local out = { hp = base.hp }
      for _, k in ipairs(STAT_KEYS) do
        local v
        if live and live[k] ~= nil then
          v = live[k]
        else
          v = base[k]
          if v then
            local stg = stages[k]
            if stg and stg ~= 0 and C.Stats and C.Stats.applyStage then
              v = C.Stats.applyStage(v, stg)
            end
            if badge[k] then v = math.floor(v * 9 / 8) end
            if pen and pen.stat == k then v = math.max(1, math.floor(v / pen.div)) end
          end
        end
        out[k] = v
      end
      return out
    end
    if party[1] then party[1].shown = shownStats(party[1]) end
    if battleBlock and battleBlock.enemy then
      battleBlock.enemy.shown = shownStats(battleBlock.enemy)
      local mS = party[1] and party[1].shown and party[1].shown.speed
      local eS = battleBlock.enemy.shown.speed
      if mS and eS then
        battleBlock.faster = (mS > eS) and "you" or ((eS > mS) and "them" or "tie")
      end
    end

    return { active = true, party = party, trainer = trainer,
      battle = battleBlock, items = {
        bagFull = C.Bag and C.Bag.slots(save), bagCap = C.Bag and C.Bag.capacity(C.gameData) }
    }
  end

  -- ---------------------------------------------------------------------
  -- Runs every frame: reads the save.
  -- ---------------------------------------------------------------------
  C.onFrame = function(dt)
    C.acc = (C.acc or 0) + (dt or 0)
    if not C.state or C.acc >= INTERVAL then
      C.acc = 0
      local ok, st = pcall(buildState)
      if ok then C.state = st
      elseif st ~= C.buildErr then C.buildErr = st; mod.log:error("kanto_ingame build: %s", tostring(st)) end
    end
  end

  -- ---------------------------------------------------------------------
  -- Drawing helpers (sizes scale automatically to fit the screen).
  -- ---------------------------------------------------------------------
  local s = 1
  -- Swaps symbols the game's font can't display for simple text instead.
  local SUB = {
    ["\226\153\128"] = " (F)",  -- U+2640
    ["\226\153\130"] = " (M)",  -- U+2642
    ["\226\152\133"] = "*",    -- U+2605
    ["\226\154\160"] = "!",    -- U+26A0
    ["\226\150\186"] = ">",    -- U+25BA
    ["\226\151\132"] = "<",    -- U+25C4
    ["\226\151\134"] = "*",    -- U+25C6
    ["\226\151\135"] = "\194\183",  -- U+25C7
  }
  local function sanitize(str)
    if type(str) ~= "string" then str = tostring(str) end
    for k, v in pairs(SUB) do str = str:gsub(k, v) end
    return str
  end
  local function setc(c, a) love.graphics.setColor(c[1], c[2], c[3], a or 1) end
  local function rrect(mode, x, y, w, h, r)
    love.graphics.rectangle(mode, math.floor(x*s), math.floor(y*s), math.floor(w*s), math.floor(h*s),
      (r or 0)*s, (r or 0)*s, 16)
  end
  local function textW(str, size) return getFont(size*s):getWidth(sanitize(str)) / s end
  -- Everything is white on black, so every string gets a black outline drawn
  -- around it. Four passes reads as cleanly as eight at these sizes.
  local OUTLINE_OFF = { {-1,0}, {1,0}, {0,-1}, {0,1} }
  local function txt(str, x, y, size, col, align, weight)
    str = sanitize(str)
    local f = getFont(size*s); love.graphics.setFont(f)
    local X = x*s
    if align == "right" then X = X - f:getWidth(str)
    elseif align == "center" then X = X - f:getWidth(str)/2 end
    X, y = math.floor(X), math.floor(y*s)
    local o = math.max(1, math.floor((weight or 0.07) * size * s + 0.5))
    setc(COL.outline, 1)
    for i = 1, #OUTLINE_OFF do
      love.graphics.print(str, X + OUTLINE_OFF[i][1]*o, y + OUTLINE_OFF[i][2]*o)
    end
    setc(col or COL.text, 1)
    love.graphics.print(str, X, y)
  end
  local function txtMid(str, x, y, size, col, align, weight)
    txt(str, x, y - size*0.62, size, col, align, weight)
  end
  local function ellipsize(str, size, maxW)
    if textW(str, size) <= maxW then return str end
    local s2 = str
    while #s2 > 1 and textW(s2 .. "..", size) > maxW do s2 = s2:sub(1, #s2 - 1) end
    return s2 .. ".."
  end
  local function panel(x, y, w, h, activeGold)
    setc(COL.panel, 1); rrect("fill", x, y, w, h, 14)
    love.graphics.setLineWidth(math.max(1, 3*s))
    if activeGold then setc(COL.gold, 1) else setc(COL.border, 1) end
    rrect("line", x, y, w, h, 14)
  end
  local function subbox(x, y, w, h, fill)
    setc(fill or COL.sub, 1); rrect("fill", x, y, w, h, 10)
    love.graphics.setLineWidth(math.max(1, 2.8*s))
    setc(COL.border, 1); rrect("line", x, y, w, h, 10)
  end
  local function drawImg(img, x, y, size)
    if not img then return end
    local iw, ih = img:getDimensions()
    local sc = (size / math.max(iw, ih)) * s
    setc(COL.text, 1)
    love.graphics.draw(img, math.floor(x*s + (size*s - iw*sc)/2),
      math.floor(y*s + (size*s - ih*sc)/2), 0, sc, sc)
  end
  local function fitImg(img, x, y, w, h, flip)
    if not img then return end
    local iw, ih = img:getDimensions()
    local sc = math.min(w*s / iw, h*s / ih)
    local ox = math.floor(x*s + (w*s - iw*sc)/2)
    local oy = math.floor(y*s + (h*s - ih*sc)/2)
    setc(COL.text, 1)
    if flip then love.graphics.draw(img, ox + iw*sc, oy, 0, -sc, sc)
    else love.graphics.draw(img, ox, oy, 0, sc, sc) end
  end
  -- The type art is a flat disc with no border, so the ring is drawn here and
  -- stays the same weight whatever size the icon is used at.
  local function typeIcon(t, x, y, size)
    local img = typeIconImg(t)
    if img then
      drawImg(img, x, y, size)
      love.graphics.setLineWidth(math.max(1, 3.2*s))
      setc(COL.border, 1)
      love.graphics.circle("line", math.floor((x + size/2)*s), math.floor((y + size/2)*s),
        (size/2 - size*0.025)*s, 48)
    else
      subbox(x, y, size, size, COL.plate)
      txtMid(tostring(t):sub(1,3), x + size/2, y + size/2, size*0.34, COL.text, "center")
    end
    return size
  end
  -- Status art carries its own black outline, so it needs a plate to sit on.
  local function iconPlate(path, x, y, size, pad)
    pad = pad or 4
    local box = size + pad*2
    setc(COL.plate, 1); rrect("fill", x, y, box, box, box*0.28)
    love.graphics.setLineWidth(math.max(1, 2.2*s))
    setc(COL.border, 1); rrect("line", x, y, box, box, box*0.28)
    drawImg(uiImage(path), x + pad, y + pad, size)
    return box
  end
  local function statusIcons(m, x, y, size, rightToLeft)
    local list = {}
    if m.status and STATUS_ICON[m.status] then list[#list+1] = STATUS_ICON[m.status] end
    if m.confusedTurns then list[#list+1] = "confuse" end
    if #list == 0 then return 0 end
    local box = size + 8
    local cx = x
    if rightToLeft then cx = x - (#list * (box + 6) - 6) end
    for _, nm in ipairs(list) do
      cx = cx + iconPlate(mod.assets:path("assets/status/" .. nm .. ".png"), cx, y, size) + 6
    end
    return #list
  end
  local function bar(x, y, w, h, frac, col)
    setc(COL.panel, 1); rrect("fill", x, y, w, h, h/2)
    love.graphics.setLineWidth(math.max(1, 1.6*s))
    setc(COL.border, 1); rrect("line", x, y, w, h, h/2)
    if frac and frac > 0 then
      setc(col, 1)
      rrect("fill", x + 2, y + 2, math.max(3, (w - 4)*math.min(1, frac)), h - 4, (h-4)/2)
    end
  end
  local function money(n) local s2 = tostring(math.floor(n or 0)); local o = s2:reverse():gsub("(%d%d%d)","%1,"):reverse():gsub("^,",""); return "\194\165"..o end
  local function titleCase(s)
    s = (s or ""):lower():gsub("_", " ")
    return (s:gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b end))
  end
  local function fmtTimeHMS(sec)
    sec = math.floor(sec or 0)
    return string.format("%d:%02d:%02d", math.floor(sec/3600), math.floor(sec/60)%60, sec%60)
  end
  local function effPower(mv)
    if not (mv and mv.power) then return nil end
    local p = mv.power
    if mv.stab then p = math.floor(p * 3 / 2) end
    local m = mv.mult
    if m == 2 then
      p = math.floor(math.floor(p * 5 / 10) * 5 / 10)
    elseif m then
      p = math.floor(p * m / 10)
    end
    return p
  end

  -- ---------------------------------------------------------------------
  -- Draws each panel. Each one returns how tall it drew.
  -- ---------------------------------------------------------------------
  local COLW = 463        -- battle column width (party / enemy)
  local HUD_COLW = 463    -- top-right HUD cluster, same width so the edge lines up
  local EDGE_MARGIN = 4   -- how tight panels hug the screen edges
  local HUD_GAP = 10      -- vertical gap inside the top-right HUD stack
  local PAD = 16
  local GAP = 12

  local SPRITE_BOX = 186  -- player's sprite box, square
  local NAME_SIZE = 34    -- fixed, sized against VICTREEBEL / NIDOQUEEN
  local MOVE_SIZE = 22    -- fixed, sized against SEISMIC TOSS *
  local MOVE_ROW = 52
  local STAT_H = 108
  local MOVEBOX_H = 12 + 4*MOVE_ROW + 12
  local STATS_H = STAT_H*2 + GAP
  local PARTY_PANEL_H = PAD + SPRITE_BOX + GAP + MOVEBOX_H + GAP + STATS_H + PAD
  local ENEMY_SB_H = 230
  local ENEMY_PANEL_H = PAD + ENEMY_SB_H + GAP + STATS_H + PAD

  local STAT_COL = {
    HP = hex("ff8a3d"), ATK = hex("ffd83d"), DEF = hex("6fe89a"),
    SPC = hex("6fc3ff"), SPD = hex("b48bff"), CRIT = hex("ff7fc0"),
  }
  local BADGE_STAT_INDEX = { attack = 1, defense = 3, speed = 5, special = 7 }

  local function stageBadge(x, y, w, h, stage)
    if not stage or stage == 0 then return end
    local bw, bh = 40, 30
    local bx, by = x + w - bw - 6, y + h - bh - 6
    setc(COL.border, 1); rrect("fill", bx, by, bw, bh, 7)
    love.graphics.setLineWidth(math.max(1, 1.6*s))
    setc(COL.outline, 1); rrect("line", bx, by, bw, bh, 7)
    local col = stage > 0 and {0.04, 0.43, 0.1} or {0.59, 0.06, 0.06}
    txt((stage > 0 and "+" or "") .. tostring(stage), bx + bw/2, by + 5, 18, col, "center", 0.05)
  end

  local function hpDot(cur, mx)
    if not (cur and mx and mx > 0) then return nil end
    if cur >= mx then return COL.hpFull end
    if cur / mx >= 0.25 then return COL.hpHurt end
    return COL.hpLow
  end

  local function statBox(x, y, w, h, label, value, col, stage, badgeIndex, dot)
    setc(col, 1); rrect("fill", x, y, w, h, 10)
    love.graphics.setLineWidth(math.max(1, 2.8*s))
    setc(COL.border, 1); rrect("line", x, y, w, h, 10)
    local lsz = 22
    if dot then
      local lw = textW(label, lsz)
      local dsz = 21
      local lx = x + w/2 - (lw + 8 + dsz)/2
      txt(label, lx + dsz + 8, y + h*0.11, lsz, COL.text, nil, 0.10)
      local cx2, cy2 = lx + dsz/2, y + h*0.11 + 3 + dsz/2
      setc(dot, 1)
      love.graphics.circle("fill", math.floor(cx2*s), math.floor(cy2*s), (dsz/2)*s, 24)
      love.graphics.setLineWidth(math.max(1, 2.6*s))
      setc(COL.outline, 1)
      love.graphics.circle("line", math.floor(cx2*s), math.floor(cy2*s), (dsz/2)*s, 24)
    else
      txt(label, x + w/2, y + h*0.11, lsz, COL.text, "center", 0.10)
    end
    local vsz = h*0.42
    while textW(value, vsz) > w - 20 and vsz > 16 do vsz = vsz - 1 end
    txt(value, x + w/2, y + h*0.38, vsz, COL.text, "center")
    stageBadge(x, y, w, h, stage)
    if badgeIndex then
      -- Shows which badge is boosting this stat.
      drawImg(uiImage(mod.assets:path("assets/badges/badge" .. badgeIndex .. "_true.png")), x + 6, y + 6, 26)
    end
  end

  local function statGrid(x, y, w, m, cols, showHPDot)
    local stats = (m and m.shown) or (m and m.stats) or {}
    local stages = (m and m.stages) or {}
    local badgeStat = (m and m.badgeStat) or {}
    local gapc = GAP
    local bw = (w - gapc*(cols-1)) / cols
    local critPct = m and m.baseSpeed and (m.baseSpeed / 512 * 100) or nil
    local critStr = critPct and string.format("%.1f%%", critPct) or "--"
    local dot = showHPDot and hpDot(m and m.hp, stats.hp) or nil
    local hpVal = showHPDot and (m and m.hp) or stats.hp
    local rows = {
      { "HP",   hpVal,          STAT_COL.HP,   stages.accuracy, nil, dot },
      { "ATK",  stats.attack,   STAT_COL.ATK,  stages.attack,   badgeStat.attack and BADGE_STAT_INDEX.attack },
      { "DEF",  stats.defense,  STAT_COL.DEF,  stages.defense,  badgeStat.defense and BADGE_STAT_INDEX.defense },
      { "SPC",  stats.special,  STAT_COL.SPC,  stages.special,  badgeStat.special and BADGE_STAT_INDEX.special },
      { "SPD",  stats.speed,    STAT_COL.SPD,  stages.speed,    badgeStat.speed and BADGE_STAT_INDEX.speed },
      { "CRIT", critStr,        STAT_COL.CRIT, stages.evasion,  nil },
    }
    for i, e in ipairs(rows) do
      local cx = x + ((i-1) % cols) * (bw + gapc)
      local cy = y + math.floor((i-1) / cols) * (STAT_H + gapc)
      statBox(cx, cy, bw, STAT_H, e[1], tostring(e[2] or "--"), e[3], e[4], e[5], e[6])
    end
    return STAT_H*2 + gapc
  end

  -- Only shows your lead Pokemon, not the whole party.
  local function party(st, x, y)
    local m = (st.party or {})[1]
    if not m then return 0 end
    local w = COLW
    panel(x, y, w, PARTY_PANEL_H, false)
    local iL, iW = x + PAD, w - PAD*2

    local sbx, sby = iL, y + PAD
    subbox(sbx, sby, SPRITE_BOX, SPRITE_BOX)
    fitImg(getSprite(m.species, C.dPoke), sbx + 12, sby + 6, SPRITE_BOX - 24, SPRITE_BOX - 40, true)
    statusIcons(m, sbx + 7, sby + SPRITE_BOX - 57, 42, false)

    local bx = sbx + SPRITE_BOX + GAP
    local bw = x + w - PAD - bx
    txt(ellipsize(m.name, NAME_SIZE, bw), bx, sby - 2, NAME_SIZE)

    local ty, tsz = sby + 44, 48
    local tx = bx
    for _, t in ipairs(m.types or {}) do tx = tx + typeIcon(t, tx, ty, tsz) + 8 end
    txtMid("Lv " .. (m.level or "?"), x + w - PAD, ty + tsz/2, 30, COL.text, "right")

    local gy = ty + tsz + 10
    if m.growthRate then txt(titleCase(m.growthRate), bx, gy, 22) end
    if m.xpProgress ~= nil then
      local xby = gy + 30
      bar(bx, xby, bw, 12, m.xpProgress, COL.xp)
      local lbl = (m.xpToNext and m.xpToNext > 0)
        and (money(m.xpToNext):gsub("\194\165","") .. " XP to Lv " .. ((m.level or 0)+1))
        or (((m.exp and money(m.exp):gsub("\194\165","")) or "0") .. " XP \194\183 Max")
      txt(lbl, bx, xby + 20, 21)
    end

    local mby = y + PAD + SPRITE_BOX + GAP
    subbox(iL, mby, iW, MOVEBOX_H)
    local mL, mR = iL + 12, iL + iW - 12
    local ppR = mR
    local powR = ppR - 90
    local nameL = mL + 42 + 12
    local nameMax = powR - 58 - nameL
    for i = 1, 4 do
      local mv = m.moves and m.moves[i]
      local ry = mby + 12 + (i-1)*MOVE_ROW
      local cy = ry + MOVE_ROW/2
      if mv then
        if mv.best then
          setc(COL.bestFill, 1); rrect("fill", mL - 4, ry + 2, (mR - mL) + 8, MOVE_ROW - 4, 8)
          love.graphics.setLineWidth(math.max(1, 1.8*s))
          setc(COL.bestLine, 1); rrect("line", mL - 4, ry + 2, (mR - mL) + 8, MOVE_ROW - 4, 8)
        end
        if mv.type then typeIcon(mv.type, mL, cy - 21, 42) end
        local pw = effPower(mv)
        local nm = mv.name .. ((pw and mv.stab) and " *" or "")
        txtMid(ellipsize(nm, MOVE_SIZE, nameMax), nameL, cy, MOVE_SIZE)
        txtMid(pw and tostring(pw) or "\226\128\148", powR, cy, MOVE_SIZE, COL.text, "right")
        local pp = (mv.pp ~= nil and mv.maxpp ~= nil) and (mv.pp.."/"..mv.maxpp) or "--"
        txtMid(pp, ppR, cy, 20, COL.text, "right")
      else
        txtMid("\226\128\148", nameL, cy, MOVE_SIZE, COL.dim)
        txtMid("\226\128\148", ppR, cy, 20, COL.dim, "right")
      end
    end

    statGrid(iL, mby + MOVEBOX_H + GAP, iW, m, 3, true)
    return PARTY_PANEL_H
  end

  -- Enemy panel: sprite in its own box, icons in the gutters either side.
  local function enemyPanel(st, x, y)
    local b = st.battle; if not b then return 0 end
    local en = b.enemy or {}
    local w = COLW
    panel(x, y, w, ENEMY_PANEL_H, false)
    local iL, iW = x + PAD, w - PAD*2

    local hy = y + PAD
    local sbw = 264
    local sbx = iL + (iW - sbw)/2
    subbox(sbx, hy, sbw, ENEMY_SB_H)
    fitImg(getSprite(en.species, C.dPoke), sbx + 12, hy + 10, sbw - 24, ENEMY_SB_H - 20, false)

    local isz = 56
    local gl = iL + ((sbx - iL) - isz)/2
    local ty = hy + 6
    for _, t in ipairs(en.types or {}) do typeIcon(t, gl, ty, isz); ty = ty + isz + 8 end

    local gr = sbx + sbw + ((iL + iW) - (sbx + sbw) - isz)/2
    local arrow = b.faster == "you" and "faster" or (b.faster == "them" and "slower"
      or (b.faster == "tie" and "tie" or nil))
    if arrow then
      drawImg(uiImage(mod.assets:path("assets/speed/" .. arrow .. ".png")), gr, hy + 6, isz)
    end

    statusIcons(en, sbx + sbw - 7, hy + ENEMY_SB_H - 57, 42, true)
    statGrid(iL, hy + ENEMY_SB_H + GAP, iW, en, 3, false)
    return ENEMY_PANEL_H
  end

  -- Play time and resets, plus a repel box that only shows up while active.
  local function statBoxPlain(x, y, w, h, label, value, col)
    panel(x, y, w, h, false)
    txt(label, x + w/2, y + 10, 20, col or COL.text, "center", 0.10)
    local vsz = 40
    while textW(value, vsz) > w - 24 and vsz > 14 do vsz = vsz - 1 end
    txt(value, x + w/2, y + 34, vsz, col or COL.text, "center")
  end
  -- 8 badge slots in a single thin row, evenly spaced, filled in once earned.
  local BADGE_ICON = 32
  local BADGE_ROW_H = 60
  local function badgeRow(st, x, y)
    local w = HUD_COLW
    panel(x, y, w, BADGE_ROW_H, false)
    local badges = (st.trainer and st.trainer.badges) or {}
    local gapX = (w - PAD*2 - 8*BADGE_ICON) / 7
    local by = y + (BADGE_ROW_H - BADGE_ICON)/2
    for i = 0, 7 do
      local bx = x + PAD + i*(BADGE_ICON + gapX)
      local owned = badges[i+1] and badges[i+1].owned
      love.graphics.setLineWidth(math.max(1, 1.6*s))
      setc(COL.border, owned and 1 or 0.45); rrect("line", bx - 3, by - 3, BADGE_ICON + 6, BADGE_ICON + 6, 6)
      drawImg(uiImage(mod.assets:path(
        "assets/badges/badge" .. (i+1) .. "_" .. (owned and "true" or "false") .. ".png")),
        bx, by, BADGE_ICON)
    end
    return BADGE_ROW_H
  end

  -- Top-right HUD, built from the top down so nothing shifts around.
  local GT_BOX_H = 86
  local GT_GAP = 12
  local function gameTimePanel(st, x, y)
    local t = st.trainer
    local bw = (HUD_COLW - GT_GAP) / 2
    local frozen = t and t.timeFrozen
    statBoxPlain(x, y, bw, GT_BOX_H, frozen and "FINAL TIME" or "GAME TIME",
      t and fmtTimeHMS(t.playTime) or "--", frozen and COL.gold or nil)
    statBoxPlain(x + bw + GT_GAP, y, bw, GT_BOX_H, "RESETS", tostring(C.resets or 0))
    return GT_BOX_H
  end

  -- Repel and bag warnings -- both hang off the bottom of the badge row.
  local REPEL_BOX_W = (HUD_COLW - GT_GAP) / 2
  local BAG_BOX_H = 70
  local function repelPanel(st, x, y)
    local t = st.trainer
    if not (t and (t.repelSteps or 0) > 0) then return 0 end
    statBoxPlain(x, y, REPEL_BOX_W, GT_BOX_H, "REPEL", tostring(t.repelSteps))
    return GT_BOX_H
  end

  local function bagPanel(st, x, y)
    local badges = (st.trainer and st.trainer.badges) or {}
    if badges[8] and badges[8].owned then return 0 end
    local it = st.items or {}
    if not (it.bagFull and it.bagCap) then return 0 end
    local remaining = it.bagCap - it.bagFull
    local iconPath = remaining <= 0 and "assets/ui/bag_red.png"
      or remaining == 1 and "assets/ui/bag_yellow.png"
      or remaining == 2 and "assets/ui/bag_green.png"
    if not iconPath then return 0 end
    panel(x, y, BAG_BOX_H, BAG_BOX_H, false)
    drawImg(uiImage(mod.assets:path(iconPath)), x + 8, y + 8, 54)
    return BAG_BOX_H
  end

  -- ---------------------------------------------------------------------
  -- Draws everything, positioned from the screen edges.
  -- ---------------------------------------------------------------------
  C.drawOverlay = function()
    local st = C.state
    if not st or not st.active then return end
    local W, H = love.graphics.getDimensions()
    s = H / REF_H
    love.graphics.push("all")
    love.graphics.origin()
    local edge = EDGE_MARGIN
    local dw, dh = W / s, H / s

    -- Top right: game time + resets, badge row below, then repel and bag
    -- hanging off the badge row's bottom edge. Always visible.
    local hudX = dw - edge - HUD_COLW
    gameTimePanel(st, hudX, edge)
    local badgeRowY = edge + GT_BOX_H + HUD_GAP
    badgeRow(st, hudX, badgeRowY)
    local condY = badgeRowY + BADGE_ROW_H + HUD_GAP
    if not C.visible then
      love.graphics.pop()
      return
    end

    bagPanel(st, hudX, condY)
    repelPanel(st, hudX + HUD_COLW - REPEL_BOX_W, condY)

    if not (st.party and #st.party > 0) then
      love.graphics.pop()
      return
    end

    -- Bottom left: your Pokemon. Bottom right: the enemy, battle only. Both
    -- sit on the same baseline so the stat grids line up across the screen.
    party(st, edge, dh - edge - PARTY_PANEL_H)
    if st.battle then
      enemyPanel(st, dw - edge - COLW, dh - edge - ENEMY_PANEL_H)
    end
    love.graphics.pop()
  end

  -- ---------------------------------------------------------------------
  -- Hooks into the game (won't double up if the mod reloads).
  -- ---------------------------------------------------------------------
  mod.hooks:wrap("core.update", function(nextFn, game, dt)
    nextFn(game, dt)
    if C.onFrame then pcall(C.onFrame, dt) end
  end)
  mod.hooks:wrap("render.hud", function(nextFn, game, viewport)
    nextFn(game, viewport)
    if C.drawOverlay then
      local ok, err = pcall(C.drawOverlay)
      if not ok and err ~= C.drawErr then C.drawErr = err; mod.log:error("kanto_ingame draw: %s", tostring(err)) end
    end
  end)
  -- Key handling. Reassigned every load so F5 reload picks up changes.
  C.onKeyDown = function(_, key)
    local c = _G.__KANTO_INGAME
    if c then
      if OVERLAY_KEYS[key] then c.visible = not c.visible; return true end
      if key == RESETS_INC_KEY then
        c.resets = (c.resets or 0) + 1; mod.save:set("resets", c.resets); return true
      end
      if key == RESETS_DEC_KEY then
        c.resets = math.max(0, (c.resets or 0) - 1); mod.save:set("resets", c.resets); return true
      end
      if key == RESETS_ZERO_KEY then
        c.resets = 0; mod.save:set("resets", 0); return true
      end
    end
    return false
  end
  local GameModule = req("src.core.Game")
  if GameModule and GameModule.keypressed then
    local slot = GameModule.__soloOverlayKeys
    if not slot then
      slot = {}
      GameModule.__soloOverlayKeys = slot
      local origKeypressed = GameModule.keypressed
      GameModule.keypressed = function(self, key, ...)
        if slot.onKeyDown and slot.onKeyDown(self, key) then return end
        return origKeypressed(self, key, ...)
      end
    end
    slot.onKeyDown = C.onKeyDown
  end
  mod.log:info("solo_run_overlay: overlay=o/f8  resets=[, ], \\")
end

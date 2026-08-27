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
  -- Battle sprite art isn't cropped to the creature -- most species have
  -- real empty margin on one or more sides of their canvas (small/low
  -- Pokemon especially), so centering the FULL canvas in a box centers the
  -- padding, not the creature, and it reads as "off in a corner." This
  -- scans the actual opaque pixels once per species and caches the tight
  -- box around them, so fitImg can center and size against the creature
  -- itself instead of its canvas.
  C.spriteBounds = C.spriteBounds or {}
  local function getSpriteBounds(speciesId, dPoke)
    if C.spriteBounds[speciesId] ~= nil then return C.spriteBounds[speciesId] or nil end
    local def = dPoke[speciesId]
    local rel = def and def.spriteFront
    local b = false
    if rel and love.image and love.image.newImageData then
      local ok, id = pcall(love.image.newImageData, rel)
      if ok and id then
        local iw, ih = id:getDimensions()
        local minX, minY, maxX, maxY = iw, ih, -1, -1
        for py = 0, ih - 1 do
          for px = 0, iw - 1 do
            local _, _, _, a = id:getPixel(px, py)
            if a > 0.05 then
              if px < minX then minX = px end
              if py < minY then minY = py end
              if px > maxX then maxX = px end
              if py > maxY then maxY = py end
            end
          end
        end
        if maxX >= 0 then
          b = { x0 = minX, y0 = minY, w = maxX + 1 - minX, h = maxY + 1 - minY }
        end
      end
    end
    C.spriteBounds[speciesId] = b
    return b or nil
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
          accuracy = md and md.accuracy,
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
        ability = def and def.ability,
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
  -- around it. Four passes (cardinal directions only) reads as cleanly as
  -- eight at these sizes -- true for the original thin outline, but a
  -- thickened one (extraPx) needs the diagonals too, or the four cardinal
  -- strokes don't quite meet at each glyph's corners. That gap is exactly
  -- what read as a soft blurry "shadow" instead of a crisp edge: four
  -- rings stacked outward (to fill the gap between glyph and outline)
  -- still all share the same four missing corners, so the notch just got
  -- restated at each ring instead of going away.
  local OUTLINE_OFF = { {-1,0}, {1,0}, {0,-1}, {0,1} }
  local OUTLINE_OFF8 = { {-1,0}, {1,0}, {0,-1}, {0,1}, {-1,-1}, {1,-1}, {-1,1}, {1,1} }
  local function txt(str, x, y, size, col, align, weight, extraPx, skipOutline)
    str = sanitize(str)
    local f = getFont(size*s); love.graphics.setFont(f)
    local X = x*s
    if align == "right" then X = X - f:getWidth(str)
    elseif align == "center" then X = X - f:getWidth(str)/2 end
    X, y = math.floor(X), math.floor(y*s)
    if not skipOutline then
      -- extraPx is a literal pixel bump on top of the scaled weight, for
      -- spots that need a visibly thicker stroke regardless of resolution.
      local o = math.max(1, math.floor((weight or 0.07) * size * s + 0.5)) + (extraPx or 0)
      setc(COL.outline, 1)
      -- A thickened outline (extraPx set) fills solid from 1px out to o
      -- using all 8 directions, so both the ring-gap and the corner-notch
      -- are gone.
      local thick = extraPx and extraPx > 0
      local offs = thick and OUTLINE_OFF8 or OUTLINE_OFF
      local fromD = thick and 1 or o
      for d = fromD, o do
        for i = 1, #offs do
          love.graphics.print(str, X + offs[i][1]*d, y + offs[i][2]*d)
        end
      end
    end
    setc(col or COL.text, 1)
    love.graphics.print(str, X, y)
  end
  local function txtMid(str, x, y, size, col, align, weight, extraPx, skipOutline)
    txt(str, x, y - size*0.62, size, col, align, weight, extraPx, skipOutline)
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
  -- One-texel silhouette shader for the "outline both sprites" pass: it
  -- paints solid white exactly where a transparent source pixel borders an
  -- opaque one, and stays transparent everywhere else (including the
  -- sprite's own interior, which the normal draw handles on top of it).
  -- Sized in source-image texels rather than screen pixels, so it comes out
  -- one game-pixel thick at any resolution, matching the pixel-art grid.
  local function getSpriteOutlineShader()
    if C.spriteOutlineShader == nil then
      local ok, sh = pcall(love.graphics.newShader, [[
        extern vec2 texel;
        vec4 effect(vec4 color, Image tex, vec2 uv, vec2 screen_coords) {
          vec4 c = Texel(tex, uv);
          if (c.a > 0.15) { return vec4(0.0); }
          float a = 0.0;
          a = max(a, Texel(tex, uv + vec2( texel.x, 0.0)).a);
          a = max(a, Texel(tex, uv + vec2(-texel.x, 0.0)).a);
          a = max(a, Texel(tex, uv + vec2(0.0,  texel.y)).a);
          a = max(a, Texel(tex, uv + vec2(0.0, -texel.y)).a);
          a = max(a, Texel(tex, uv + vec2( texel.x,  texel.y)).a);
          a = max(a, Texel(tex, uv + vec2(-texel.x,  texel.y)).a);
          a = max(a, Texel(tex, uv + vec2( texel.x, -texel.y)).a);
          a = max(a, Texel(tex, uv + vec2(-texel.x, -texel.y)).a);
          return vec4(1.0, 1.0, 1.0, a);
        }
      ]])
      C.spriteOutlineShader = ok and sh or false
    end
    return C.spriteOutlineShader or nil
  end

  -- bounds (optional, from getSpriteBounds) makes this center and size
  -- against the creature's actual opaque pixels instead of its full
  -- canvas -- most sprites have real empty margin on the canvas, which
  -- otherwise reads as the creature sitting off in a corner.
  local function fitImg(img, x, y, w, h, flip, outline, bounds)
    if not img then return end
    local iw, ih = img:getDimensions()
    local cx0, cy0, cw, ch = 0, 0, iw, ih
    if bounds then cx0, cy0, cw, ch = bounds.x0, bounds.y0, bounds.w, bounds.h end
    local sc = math.min(w*s / cw, h*s / ch)
    local oy = math.floor(y*s + (h*s - ch*sc)/2 - cy0*sc)
    local ox
    if flip then
      -- Flipping mirrors the canvas around its own right edge, so the
      -- content's effective offset becomes its margin measured from the
      -- RIGHT of the canvas, not the left.
      local xR = iw - (cx0 + cw)
      ox = math.floor(x*s + (w*s - cw*sc)/2 - xR*sc)
    else
      ox = math.floor(x*s + (w*s - cw*sc)/2 - cx0*sc)
    end
    if outline then
      local sh = getSpriteOutlineShader()
      if sh then
        sh:send("texel", {1/iw, 1/ih})
        love.graphics.setShader(sh)
        setc(COL.text, 1)
        if flip then love.graphics.draw(img, ox + iw*sc, oy, 0, -sc, sc)
        else love.graphics.draw(img, ox, oy, 0, sc, sc) end
        love.graphics.setShader()
      end
    end
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
      setc(COL.outline, 1)
      love.graphics.circle("line", math.floor((x + size/2)*s), math.floor((y + size/2)*s),
        (size/2 - size*0.025)*s, 48)
    else
      subbox(x, y, size, size, COL.plate)
      txtMid(tostring(t):sub(1,3), x + size/2, y + size/2, size*0.34, COL.text, "center")
    end
    return size
  end
  -- Speed comparison badge: the original green/red/yellow speed/*.png art,
  -- outlined the same way the battle sprites are -- a thin white trace of
  -- the icon's own silhouette (fitImg's outline pass) rather than a ring
  -- around it. No circle backdrop.
  local function speedBadge(kind, x, y, size)
    local img = uiImage(mod.assets:path("assets/speed/" .. kind .. ".png"))
    if not img then return end
    fitImg(img, x, y, size, size, false, true)
  end
  -- Single status slot (used on both sides now): draws NOTHING -- no box,
  -- no outline -- when there's no status to show, rather than a permanent
  -- empty placeholder. Confusion is a temporary overlay -- it takes
  -- priority for display over a lingering primary status (sleep, burn,
  -- etc.), which comes back into view once confusion wears off.
  local function primaryStatus(m)
    if m.confusedTurns then return "confuse" end
    if m.status and STATUS_ICON[m.status] then return STATUS_ICON[m.status] end
    return nil
  end
  local function statusBox(x, y, size, m)
    local nm = primaryStatus(m)
    if not nm then return end
    setc(COL.plate, 1); rrect("fill", x, y, size, size, size*0.28)
    love.graphics.setLineWidth(math.max(1, 2.2*s))
    setc(COL.border, 1); rrect("line", x, y, size, size, size*0.28)
    local pad = math.floor(size*0.14)
    drawImg(uiImage(mod.assets:path("assets/status/" .. nm .. ".png")), x + pad, y + pad, size - pad*2)
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
  -- Solid hot pink fill over a dark-almost-black-pink track (not a
  -- gradient of the fill itself -- that was a misread of "pink" last
  -- round). The track color is what shows through on the unfilled portion
  -- while you're still gaining XP.
  local XP_FILL = { 1.0, 0.13, 0.58 }
  local XP_BG   = { 0.12, 0.02, 0.08 }
  local function xpBar(x, y, w, h, frac)
    setc(XP_BG, 1); rrect("fill", x, y, w, h, h/2)
    love.graphics.setLineWidth(math.max(1, 1.6*s))
    setc(COL.border, 1); rrect("line", x, y, w, h, h/2)
    if frac and frac > 0 then
      setc(XP_FILL, 1)
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

  -- Compact header strip: sprite (no background box -- just the outlined
  -- silhouette, filling the full row height), name/level, growth rate, XP
  -- bar. About 40% shorter than the old sprite-box layout. Kept tight
  -- enough (with MOVE_ROW/STAT_H trimmed too) that the whole panel fits
  -- above the screen bottom while still top-anchored to line up with the
  -- game's FIGHT/ITEM/RUN box -- it doesn't get to grow past that.
  local INFO_H = 120      -- gives the header row enough room for even
                           -- growth-rate/bar/xp-text spacing without touching
  local NAME_SIZE = 34    -- ceiling; auto-shrinks down to fit the full name
  local MOVE_SIZE = 22    -- fixed, sized against SEISMIC TOSS *
  local MOVE_ROW = 26
  local STAT_H = 88
  -- Tight top inset (moves sit right under the box's own top edge now) and
  -- a little more room at the bottom.
  local MOVEBOX_H = 6 + 4*MOVE_ROW + 8
  local STATS_H = STAT_H*2 + GAP
  local PARTY_PANEL_H = PAD + INFO_H + GAP + MOVEBOX_H + GAP + STATS_H + PAD

  -- Enemy panel is the compact layout: sprite sits beside the stat grid
  -- instead of stacked above it, with no background box or badge strip of
  -- its own anymore -- type badges and the status slot just sit on its
  -- corners, so the sprite gets the full height to itself.
  local ENEMY_STAT_H = 66
  local ENEMY_STATS_H = ENEMY_STAT_H*2 + GAP
  local ENEMY_SPRITE_W = ENEMY_STATS_H   -- square, fills the full height now
  local ENEMY_PANEL_H = PAD + ENEMY_STATS_H + PAD
  -- Calibrated by eye against your screenshot so both panels' TOPS line up
  -- with the FIGHT/ITEM/RUN box's top -- nudge this if it's off once you
  -- see it in-game; it's independent of either panel's height on purpose
  -- so they don't just grow downward as they shrink. Shared by both sides
  -- now that your panel is top-anchored the same way the enemy's is.
  local PANEL_TOP_FROM_BOTTOM = 487

  local STAT_COL = {
    HP = hex("ff8a3d"), ATK = hex("ffd83d"), DEF = hex("6fe89a"),
    SPC = hex("6fc3ff"), SPD = hex("b48bff"), CRIT = hex("ff7fc0"),
  }
  local BADGE_STAT_INDEX = { attack = 1, defense = 3, speed = 5, special = 7 }

  local function stageBadge(x, y, w, h, stage, big)
    if not stage or stage == 0 then return end
    -- Dark plate instead of a white/colored fill -- the raised/lowered
    -- number itself carries the color now (green/red, same hpFull/hpLow
    -- tones used elsewhere), with its usual black outline, so it pops off
    -- the dark background instead of blending into a colored one.
    local bw, bh, bx, by, fsz
    if big then
      -- Player side: still top-right, flush, bumped a bit bigger again.
      bw, bh = 30, 25
      bx, by = x + w - bw, y
      fsz = 18
    else
      -- Enemy side: moved to top-right too, flush, to cleanly wrap around
      -- the corner instead of hanging off the bottom.
      bw, bh = 22, 19
      bx, by = x + w - bw, y
      fsz = 14
    end
    setc(COL.plate, 1); rrect("fill", bx, by, bw, bh, 6)
    love.graphics.setLineWidth(math.max(1, 1.6*s))
    setc(COL.outline, 1); rrect("line", bx, by, bw, bh, 6)
    local col = stage > 0 and COL.hpFull or COL.hpLow
    txtMid(tostring(math.abs(stage)), bx + bw/2, by + bh/2, fsz, col, "center")
  end

  local function statBox(x, y, w, h, label, value, col, stage, badgeIndex, dot, noLabel, speedArrow)
    setc(col, 1); rrect("fill", x, y, w, h, 10)
    love.graphics.setLineWidth(math.max(1, 2.8*s))
    setc(COL.border, 1); rrect("line", x, y, w, h, 10)
    -- Label row (when shown) and its accessory icon -- the HP dot, a
    -- badge-boost icon, or the speed arrow -- all share this same inset
    -- from the top, so every box's little marker lines up on one row.
    local topY = y + 4
    local iconSz = 22
    if noLabel then
      -- Enemy grid: no HP/ATK/DEF text (the player's grid teaches that
      -- already), so the number gets the whole box, centered, and reads
      -- bigger. Sized against a fixed "99" reference so every 1-2 digit
      -- value lands at the SAME font size/outline weight -- no more a lone
      -- digit reading thicker than a 2-digit value just because it needed
      -- less shrinking. Only a genuinely wider value (triple digit, or a
      -- decimal like CRIT's) drops to its own smaller, independently
      -- thickened tier so it doesn't come out paper-thin.
      -- Ratio bumped up from the box's earlier, taller size (0.3 at
      -- h=92) to the same one here (h=66) -- shrinking the box shouldn't
      -- have shrunk the font with it; this restores the same absolute
      -- pixel size that was already legible.
      local vszRef = h*0.42
      while textW("99", vszRef) > w - 16 and vszRef > 16 do vszRef = vszRef - 1 end
      local vsz, extraPx = vszRef, 1
      if textW(value, vszRef) > w - 16 then
        vsz = vszRef
        while textW(value, vsz) > w - 16 and vsz > 16 do vsz = vsz - 1 end
        extraPx = 3
      end
      txtMid(value, x + w/2, y + h/2, vsz, COL.text, "center", 0.07, extraPx)
    else
      local lsz = 22
      -- Labels sit flat black with no outline -- they're already on a
      -- light, solid pastel box, so the outline was just adding noise --
      -- rather than white-on-color like the rest of this HUD. HP's colored
      -- dot is gone -- it's a live number already, the dot was redundant.
      txt(label, x + w/2, topY, lsz, COL.outline, "center", nil, nil, true)
      -- Centered in the space below the label row (not pinned to a fixed
      -- offset that pushes it toward the bottom) so it stays balanced
      -- against the label above and the stage-modifier badge below.
      -- Same fixed-reference sizing as the enemy grid: every 1-2 digit
      -- value locks to one size/outline weight instead of drifting per
      -- value, and it uses the same weight/extraPx as the enemy's normal
      -- tier so both sides read at the same outline thickness.
      local vszRef = h*0.38
      while textW("99", vszRef) > w - 20 and vszRef > 16 do vszRef = vszRef - 1 end
      local vsz, extraPx = vszRef, 1
      if textW(value, vszRef) > w - 20 then
        vsz = vszRef
        while textW(value, vsz) > w - 20 and vsz > 16 do vsz = vsz - 1 end
        extraPx = 3
      end
      local vmidY = (topY + iconSz + (y + h)) / 2
      txtMid(value, x + w/2, vmidY, vsz, COL.text, "center", 0.07, extraPx)
    end
    stageBadge(x, y, w, h, stage, not noLabel)
    if badgeIndex then
      -- Shows which badge is boosting this stat. Lines up with the label
      -- row's icon inset, top-left.
      drawImg(uiImage(mod.assets:path("assets/badges/badge" .. badgeIndex .. "_true.png")), x + 6, topY, iconSz)
    end
    if speedArrow then
      -- Only used on your own SPD box: up = you're faster, down = you're
      -- not. A bit bigger than the badge-boost icon now that it's not
      -- carrying a ring, so it's centered on the same row rather than
      -- top-aligned with it.
      local asz = iconSz + 4
      speedBadge(speedArrow, x + w - 6 - asz, topY - (asz - iconSz)/2, asz)
    end
  end

  local function statGrid(x, y, w, m, cols, showHPDot, noLabel, speedArrow, rowH)
    local rh = rowH or STAT_H
    local stats = (m and m.shown) or (m and m.stats) or {}
    local stages = (m and m.stages) or {}
    local badgeStat = (m and m.badgeStat) or {}
    local gapc = GAP
    local bw = (w - gapc*(cols-1)) / cols
    local critPct = m and m.baseSpeed and (m.baseSpeed / 512 * 100) or nil
    -- The label now says "CRIT %", so the number itself drops the percent
    -- sign -- one less character buys the box real breathing room, and it
    -- makes it obvious triple-digit stats (and any other value) still fit,
    -- since it's the same box, same font logic, just fewer characters.
    local critStr = critPct and string.format("%.1f", critPct) or "--"
    local hpVal = showHPDot and (m and m.hp) or stats.hp
    local rows = {
      { "HP",   hpVal,          STAT_COL.HP,   stages.accuracy, nil },
      { "ATK",  stats.attack,   STAT_COL.ATK,  stages.attack,   badgeStat.attack and BADGE_STAT_INDEX.attack },
      { "DEF",  stats.defense,  STAT_COL.DEF,  stages.defense,  badgeStat.defense and BADGE_STAT_INDEX.defense },
      { "SPC",  stats.special,  STAT_COL.SPC,  stages.special,  badgeStat.special and BADGE_STAT_INDEX.special },
      { "SPD",  stats.speed,    STAT_COL.SPD,  stages.speed,    badgeStat.speed and BADGE_STAT_INDEX.speed, nil, speedArrow },
      { "CRIT %", critStr,      STAT_COL.CRIT, stages.evasion,  nil },
    }
    for i, e in ipairs(rows) do
      local cx = x + ((i-1) % cols) * (bw + gapc)
      local cy = y + math.floor((i-1) / cols) * (rh + gapc)
      statBox(cx, cy, bw, rh, e[1], tostring(e[2] or "--"), e[3], e[4], e[5], e[6], noLabel, e[7])
    end
    return rh*2 + gapc
  end

  -- Only shows your lead Pokemon, not the whole party.
  local function party(st, x, y)
    local m = (st.party or {})[1]
    if not m then return 0 end
    local w = COLW
    panel(x, y, w, PARTY_PANEL_H, false)
    local iL, iW = x + PAD, w - PAD*2

    -- Header strip: sprite fills the whole row height (no background box,
    -- just the outlined silhouette), types stacked beside it top-aligned,
    -- name+level on one row, growth rate on its own row below, then the XP
    -- bar (which leaves room on its row for a status icon, shown only when
    -- something's actually active), then XP-to-next with the ability name
    -- (also only when the mon actually has one) to its right.
    local iy = y + PAD
    local spriteX = iL - 6
    fitImg(getSprite(m.species, C.dPoke), spriteX, iy, INFO_H, INFO_H, true, true,
      getSpriteBounds(m.species, C.dPoke))

    local typeSz = 28
    local ttx = spriteX + INFO_H + 8
    local tty = iy
    for _, t in ipairs(m.types or {}) do
      typeIcon(t, ttx, tty, typeSz)
      tty = tty + typeSz + 4
    end

    local bx = ttx + typeSz + 10
    local bw = x + w - PAD - bx
    -- Auto-shrinks to fit the FULL name -- never truncates -- reserving
    -- only the actual width "Lv ##" needs (not a flat guess), so the name
    -- gets as much of the row as it can.
    local lvlStr = "Lv " .. (m.level or "?")
    local lvlSz = 22
    local nameMaxW = bw - textW(lvlStr, lvlSz) - 10
    local nameSz = NAME_SIZE
    while textW(m.name, nameSz) > nameMaxW and nameSz > 18 do nameSz = nameSz - 1 end
    txt(m.name, bx, iy - 2, nameSz)
    txt(lvlStr, x + w - PAD, iy + nameSz - lvlSz, lvlSz, COL.text, "right")

    local gy = iy + NAME_SIZE + 4
    if m.growthRate then txt(titleCase(m.growthRate), bx, gy, 24) end

    -- Big status slot, spanning roughly the growth-rate-to-XP-text block so
    -- it can read at real size instead of being squeezed into just the
    -- bar's own thin row. Still only drawn when something's actually
    -- active (statusBox no-ops otherwise).
    local statusSz = 44
    local statusY = gy + 15

    if m.xpProgress ~= nil then
      -- Growth rate -> bar: 12px gap, same as before. Bar itself is
      -- thicker now, and its bottom edge lines up directly with the top of
      -- the XP-to-next text below it -- no gap between them anymore.
      local xby = gy + 24 + 12
      local barH = 16
      local barW = bw - statusSz - 10
      xpBar(bx, xby, barW, barH, m.xpProgress)
      statusBox(bx + barW + 10, statusY, statusSz, m)

      local lbl = (m.xpToNext and m.xpToNext > 0)
        and (money(m.xpToNext):gsub("\194\165","") .. " XP to Lv " .. ((m.level or 0)+1))
        or (((m.exp and money(m.exp):gsub("\194\165","")) or "0") .. " XP \194\183 Max")
      local xty = xby + barH
      txt(lbl, bx, xty, 20)
      -- Ability: no permanent placeholder box or caption -- most Gen 1
      -- species don't have one, so it only appears (right-aligned, next to
      -- the XP-to-next text) when a mod actually gives the mon one, e.g.
      -- Steam Engine on Coalossal. Shrinks to whatever room is actually
      -- left after the XP-to-next text -- a long ability name next to a
      -- long XP label was running the two into each other.
      if m.ability then
        local abilName = titleCase(m.ability)
        local availW = (x + w - PAD) - (bx + textW(lbl, 20) + 10)
        local abilSz = 22
        while textW(abilName, abilSz) > availW and abilSz > 8 do abilSz = abilSz - 1 end
        -- Bottom-aligned with the XP-to-next text (which sits at size 20)
        -- rather than sharing its top -- so a shrunk ability name doesn't
        -- look like it's floating above the line it's next to.
        txt(abilName, x + w - PAD, xty + (20 - abilSz), abilSz, COL.gold, "right")
      end
    end

    local mby = y + PAD + INFO_H + GAP
    subbox(iL, mby, iW, MOVEBOX_H)
    local mL, mR = iL + 12, iL + iW - 12
    local moveIconSz = 28
    local ppR = mR
    local accR = ppR - 40
    -- Well clear of accuracy now, not just a few px off it -- "100" and
    -- "100%" no longer come anywhere near touching.
    local powR = accR - 80
    local nameL = mL + moveIconSz + 8
    local nameMax = powR - 46 - nameL
    for i = 1, 4 do
      local mv = m.moves and m.moves[i]
      local ry = mby + 6 + (i-1)*MOVE_ROW
      local cy = ry + MOVE_ROW/2
      if mv then
        if mv.best then
          setc(COL.bestFill, 1); rrect("fill", mL - 4, ry + 2, (mR - mL) + 8, MOVE_ROW - 4, 8)
          love.graphics.setLineWidth(math.max(1, 1.8*s))
          setc(COL.bestLine, 1); rrect("line", mL - 4, ry + 2, (mR - mL) + 8, MOVE_ROW - 4, 8)
        end
        if mv.type then typeIcon(mv.type, mL, cy - moveIconSz/2, moveIconSz) end
        local pw = effPower(mv)
        local nm = mv.name .. ((pw and mv.stab) and " *" or "")
        txtMid(ellipsize(nm, MOVE_SIZE, nameMax), nameL, cy, MOVE_SIZE)
        txtMid(pw and tostring(pw) or "\226\128\148", powR, cy, MOVE_SIZE, COL.text, "right")
        local accStr = mv.accuracy and (tostring(mv.accuracy) .. "%") or "--"
        txtMid(accStr, accR, cy, 17, COL.dim, "right")
        -- Just the current count now, not "current/max" -- saves a lot of
        -- horizontal room. Reads dark red once you're down to 3 PP or less.
        local pp = mv.pp ~= nil and tostring(mv.pp) or "--"
        local ppCol = (mv.pp ~= nil and mv.pp <= 3) and COL.hpLow or COL.text
        txtMid(pp, ppR, cy, 20, ppCol, "right")
      else
        txtMid("\226\128\148", nameL, cy, MOVE_SIZE, COL.dim)
        txtMid("\226\128\148", accR, cy, 17, COL.dim, "right")
        txtMid("\226\128\148", ppR, cy, 20, COL.dim, "right")
      end
    end

    -- Speed arrow scrapped on your side -- it read too small next to the
    -- stat-modifier badge, and freeing that corner lets the badge sit
    -- there instead when speed itself is raised/lowered.
    statGrid(iL, mby + MOVEBOX_H + GAP, iW, m, 3, true, false, nil)
    return PARTY_PANEL_H
  end

  -- Enemy panel: stat grid and sprite box side by side. The sprite box is
  -- a small square tucked in the bottom-right, with a strip above it (same
  -- width) holding the type badge(s) and the speed badge, top-right
  -- anchored. Labels are dropped from the grid (statGrid's noLabel) so the
  -- numbers can run bigger in the smaller boxes.
  local function enemyPanel(st, x, y)
    local b = st.battle; if not b then return 0 end
    local en = b.enemy or {}
    local w = COLW
    panel(x, y, w, ENEMY_PANEL_H, false)
    local iL, iW = x + PAD, w - PAD*2

    local gy = y + PAD
    local sbw, sbh = ENEMY_SPRITE_W, ENEMY_SPRITE_W
    local sbx = iL + iW - sbw
    local statAreaW = sbx - iL - GAP

    -- No background box behind the sprite anymore -- just the outlined
    -- silhouette, same treatment your own Pokemon now gets, filling the
    -- full height freed up by dropping the badge strip above it.
    fitImg(getSprite(en.species, C.dPoke), sbx + 4, gy + 4, sbw - 8, sbh - 8, false, true,
      getSpriteBounds(en.species, C.dPoke))

    -- Stat grid first: the type badges and status slot sit on the sprite's
    -- corners and can overlap its edge, so they need to draw on top.
    statGrid(iL, gy, statAreaW, en, 3, false, true, nil, ENEMY_STAT_H)

    -- Type badge(s) anchored to the sprite's top-right corner: a single
    -- type sits at the top, two stack with the primary on top.
    local badgeSz = 36
    -- Right up against the sprite box's top border (corner-badge look), and
    -- when there are two types, stacked tight -- barely any gap between
    -- them.
    local tby = gy - 12
    for _, t in ipairs(en.types or {}) do
      typeIcon(t, sbx + sbw - badgeSz, tby, badgeSz)
      tby = tby + badgeSz + 2
    end

    -- Status condition, bottom-right corner of the sprite -- same rule as
    -- your own side: confusion overrides a lingering status for display.
    local statusSz = 40
    statusBox(sbx + sbw - statusSz, gy + sbh - statusSz, statusSz, en)

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
    -- are top-anchored now, lined up with the top of the game's own
    -- FIGHT/ITEM/RUN box, instead of sitting bottom-flush.
    party(st, edge, dh - PANEL_TOP_FROM_BOTTOM)
    if st.battle then
      enemyPanel(st, dw - edge - COLW, dh - PANEL_TOP_FROM_BOTTOM)
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

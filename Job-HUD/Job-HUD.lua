--[[
    Job-HUD
    Version: 3.5
    Author:  Valdimar @ Phoenix

    A job-aware heads-up display for Windower 4, drawn in the LATTICE style of RahvinGS.

    The panel shows the rows you choose for each job (weapons, vitals, buff timers, runes,
    rolls...) and, in place of a gear grid, a grid of cooldowns colored by state:
        green   ready
        orange  coming off cooldown soon
        red     on cooldown
        slate   not usable right now (not learned, level-synced, no avatar out...)

    The panel is the same size on every job (see the <layout> settings).

    Settings are per character: addons/Job-HUD/data/<CharacterName>.xml
    Commands: //jhud help
]]

_addon.name = 'Job-HUD'
_addon.author = 'Valdimar @ Phoenix'
_addon.version = '3.5'
_addon.commands = { 'jhud', 'jobhud' }

-- Jobs with a layout made for them (named in chat on load). Update when a job is added.
-- In release order: WAR MNK WHM BLM RDM THF PLD DRK BST BRD RNG SMN (2002), SAM NIN DRG (Rise of
-- the Zilart), BLU COR PUP (Treasures of Aht Urhgan), DNC SCH (Wings of the Goddess), GEO RUN
-- (Seekers of Adoulin).
local SUPPORTED_JOBS = { 'WAR', 'WHM', 'RDM', 'BST', 'BRD', 'RNG', 'NIN', 'DRG', 'COR', 'DNC', 'SCH', 'GEO', 'RUN' }

require('tables')
require('strings')
require('pack')
local config = require('config')
local files = require('files')
local res = require('resources')

local defaults = require('jobhud_defaults')
local data = require('jobhud_data')
local ROLL_DATA = require('jobhud_rolls')
local display = require('jobhud_display')
local themes = require('jobhud_themes')

local settings          -- this character's settings, once logged in
local char_name
local player            -- windower.ffxi.get_player() for this tick
local entries = {}      -- cooldown entries for the current job
local job_key           -- main/sub/levels the entries were built for
local notes, note_order = {}, {}
local zoning = false
local dragging
local pressed           -- mouse button down on the panel (click to use)
local hovering         -- mouse is over the panel
local idle_since       -- when you stopped being engaged
local last_tick = 0
local last_model
local learned_ja, learned_spells, learned_at = {}, {}, -1
local equip_cache = {}
local last_error
local last_tp
local timers, timer_order = {}, {}   -- custom countdowns: label -> { ends = os.time() target }
local ordered_rows    -- defined with the model builder; standard row order
-- Set while the left column is too long for the panel: rows that can, draw shorter.
--   ws: damage on the WS line (2 lines instead of 3); runes: one line per rune
local compact = {}
local showbiz_gif     -- set by the showbiz row: where the bust animation plays
local bounty_shown    -- the Bounty line is already in this column (it follows Hover)
local wyvern_saved_at = -100   -- when the learned wyvern HP was last written to the settings
local velocity_shown  -- same for the Velocity line
local col_width       -- width (chars) of the column being built: left rows or right column
local palette = {}    -- colours actually drawn: settings.colors + theme + colour-blind palette + opacity
local load_debuff_times
local load_learned       -- learned charge times / durations for the current job
local print_stats
local pet_extras

local LABEL_W = 5

------------------------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------------------------

local function msg(text)
    windower.add_to_chat(207, '[Job-HUD] ' .. text)
end

local function deepcopy(t)
    if type(t) ~= 'table' then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = deepcopy(v) end
    return out
end

local function save()
    if settings then config.save(settings, 'all') end
end

local function cs(c, s) return display.cs(c, s) end

-- Element colours (runes, burst, maneuvers), darkened on a light theme.
local element_cache, element_scale
local function element_colors()
    local k = palette.element_scale or 1
    if element_cache and element_scale == k then return element_cache end
    element_cache, element_scale = {}, k
    for el, col in pairs(data.ELEMENT_COLORS) do
        element_cache[el] = { red = math.floor(col.red * k), green = math.floor(col.green * k), blue = math.floor(col.blue * k) }
    end
    return element_cache
end

local function pad(s, w)
    if #s >= w then return s:sub(1, w) end
    return s .. (' '):rep(w - #s)
end

local function fmt_cd(sec)
    sec = math.ceil(sec)
    if sec < 60 then return sec .. 's' end
    if sec < 600 then return ('%d:%02d'):format(math.floor(sec / 60), sec % 60) end
    if sec < 3600 then return math.floor(sec / 60) .. 'm' end
    return ('%dh%02d'):format(math.floor(sec / 3600), math.floor(sec % 3600 / 60))
end

local function fmt_time(sec)
    sec = math.floor(sec)
    if sec < 60 then return sec .. 's' end
    if sec < 3600 then return ('%d:%02d'):format(math.floor(sec / 60), sec % 60) end
    return ('%d:%02d:%02d'):format(math.floor(sec / 3600), math.floor(sec % 3600 / 60), sec % 60)
end

local function job_cfg(create)
    local job = player and player.main_job or 'DEFAULT'
    local cfg = settings.jobs[job]
    if not cfg and create then
        cfg = deepcopy(settings.jobs.DEFAULT)
        settings.jobs[job] = cfg
    end
    return cfg or settings.jobs.DEFAULT, job
end

local function list_find(list, needle)
    needle = needle:lower()
    for i, item in ipairs(list) do
        local label, name = data.label_split(item)
        if name:lower() == needle or (label and label:lower() == needle) or item:lower() == needle then
            return i
        end
    end
end

------------------------------------------------------------------------------------------
-- Cooldown entries
------------------------------------------------------------------------------------------

-- Support job level, Master Levels included: 49 + 1 per 5 Master Levels (59 at ML 50), never
-- above that job's own level. Uses whichever is higher, this or what the game reports.
local function sub_level()
    local base = player.sub_job_level or 0
    local ml = data.master_level or 0
    if ml <= 0 or not player.sub_job or (player.main_job_level or 0) < 99 then return base end
    local cap = 49 + math.floor(ml / 5)
    local own = type(player.jobs) == 'table' and tonumber(player.jobs[player.sub_job]) or nil
    if own then cap = math.min(cap, own) end
    return math.max(base, cap)
end

-- Stratagem charges: 1 at level 10, +1 every 20 levels, up to 5 as main job SCH; as a support
-- job at most 3. Each charge takes 240 s / that number to come back (48 s at 5, 80 s at 3).
local function sch_strat_cap() return player.main_job == 'SCH' and 5 or 3 end
local function sch_strat_max()
    local lvl = 0
    if player.main_job == 'SCH' then lvl = player.main_job_level
    elseif player.sub_job == 'SCH' then lvl = sub_level() end
    return math.max(1, math.min(sch_strat_cap(), math.floor((lvl - 10) / 20) + 1))
end
-- Timer key for learning the real charge time: per number of charges, so SCH (5) and /SCH (3)
-- don't mix.
local function charge_key(e)
    return e.recast_id == 231 and ('231:' .. e.charges.max) or e.recast_id
end

-- Which Arts you're in: 'light' (Light Arts / Addendum: White), 'dark' (Dark Arts /
-- Addendum: Black) or nil. Grid entries written 'A/B' show A in Light Arts, B in Dark Arts.
local ARTS_BUFFS = { [358] = 'light', [401] = 'light', [359] = 'dark', [402] = 'dark' }
local function arts_state()
    for _, id in ipairs(player and player.buffs or {}) do
        if ARTS_BUFFS[id] then return ARTS_BUFFS[id] end
    end
end

local function build_entries()
    entries = {}
    if not player then return end
    local cfg = job_cfg()
    local charges = data.parse_charges(settings.charges)
    local width = settings.grid.cell_chars
    local seen = {}
    local unknown = {}

    local arts = arts_state()
    local function add(list, is_sub)
        for _, item in ipairs(data.split(list)) do
            -- 'ACCN=Accession/MANI=Manifestation': Light Arts / Dark Arts pair. With no Arts up
            -- the Light Arts one is shown, greyed out.
            local need_arts
            local light, dark = item:match('^([^/]+)/([^/]+)$')
            if light then
                item = arts == 'dark' and data.trim(dark) or data.trim(light)
                need_arts = not arts
            end
            -- 'BNTY=Bounty Shot*2': the cell is 2 cells wide (the rest of the row slots are
            -- covered by it).
            -- '?FLSH=Flashy Shot': only shown once you have it (merits); an empty slot until then.
            local if_known = item:sub(1, 1) == '?'
            if if_known then item = data.trim(item:sub(2)) end
            local span = tonumber(item:match('%*%s*(%d+)%s*$'))
            if span then item = data.trim((item:gsub('%*%s*%d+%s*$', ''))) end
            local before = #entries
            local label, name = data.label_split(item)
            local count_item = name:match('^#[Cc][Oo][Uu][Nn][Tt]:%s*(.+)$')
            if count_item then
                -- '#COUNT:Shihei' (or 'SHIH=#COUNT:Shihei'): how many of that item are in your
                -- inventory (where ninja tools have to be).
                entries[#entries + 1] = { count_item = data.trim(count_item), sub = is_sub,
                    label = (label or count_item:sub(1, settings.grid.cell_chars)):upper():sub(1, settings.grid.cell_chars) }
            elseif not is_sub and item:lower():match('^#geohud') then
                -- '#GEOHUD': one big box over the rest of the grid, pointing you to GEO-HUD.
                local cols = settings.layout.columns
                while #entries % cols ~= 0 do entries[#entries + 1] = { blank = true } end
                local rows = math.max(1, settings.layout.grid_rows - math.floor(#entries / cols))
                local big = { big = 'geohud', cols = cols, rows = rows }
                entries[#entries + 1] = big
                for _ = 2, cols * rows do entries[#entries + 1] = { covered = true, owner = big } end
            elseif not is_sub and item:lower():match('^#ammo') then
                -- '#AMMO': your equipped ammo and how much is left.
                entries[#entries + 1] = { ammo = true }
            elseif not is_sub and item:lower():match('^#rolls') then
                -- '#ROLLS': the next two grid rows become big 2x2 boxes, one per Phantom Roll
                -- on you (two boxes on a 4-wide grid).
                local cols = settings.layout.columns
                while #entries % cols ~= 0 do entries[#entries + 1] = { blank = true } end
                local n = math.floor(cols / 2)
                for b = 1, n do
                    entries[#entries + 1] = { box = b }
                    entries[#entries + 1] = { covered = true, of = b }
                end
                if cols % 2 == 1 then entries[#entries + 1] = { blank = true } end
                for b = 1, n do
                    entries[#entries + 1] = { covered = true, of = b }
                    entries[#entries + 1] = { covered = true, of = b }
                end
                if cols % 2 == 1 then entries[#entries + 1] = { blank = true } end
            elseif item:lower():match('^#strat') then
                -- '#STRAT': a full grid row showing the stratagem charges as 5 filling bubbles
                -- (as a support job, the ones you can't hold yet are dark).
                local cols = settings.layout.columns
                if not is_sub then
                    while #entries % cols ~= 0 do entries[#entries + 1] = { blank = true } end
                end
                local ch = charges[231] or {}
                local max = sch_strat_max()
                entries[#entries + 1] = { meter = 'strat', kind = 'ja', recast_id = 231, sub = is_sub,
                    slots = sch_strat_cap(), charges = { max = max, time = math.floor(240 / max) } }
                for _ = 2, cols do entries[#entries + 1] = { covered = true, sub = is_sub } end
            else
            -- 'Haste II|Haste': alternatives; the first one you can use is shown.
            -- '!Curing Waltz V|Curing Waltz IV|...': each has its own timer; the first one that's
            -- ready is shown (or the one back soonest), labelled with its tier (CW5, CW4...).
            local pick_ready = name:sub(1, 1) == '!'
            if pick_ready then name = data.trim(name:sub(2)) end
            local alts = item ~= '_' and data.resolve_alts(name) or {}
            local r = alts[1]
            if item == '_' then
                -- '_' holds an empty slot, to line cells up in the grid.
                entries[#entries + 1] = { blank = true, sub = is_sub }
            elseif not r then
                unknown[#unknown + 1] = name
                if not is_sub then
                    entries[#entries + 1] = { label = (label or data.auto_label(name)):sub(1, width),
                                              name = name, missing = true }
                end
            else
                -- Your job's list: one cell per ability you list, even when two share a timer
                -- (Heel and Stay); the same ability twice is merged. Support-job cells skip
                -- anything whose timer the job's cells already show.
                -- (Stratagems share one timer but are each their own cell, support job too.)
                local strat = r.kind == 'ja' and r.recast_id == 231
                local key = (is_sub and not strat) and (r.kind .. ':' .. tostring(r.recast_id)) or (r.kind .. ':' .. r.name)
                local timer_key = r.kind .. ':' .. tostring(r.recast_id)
                if not seen[key] and not (is_sub and not strat and seen[timer_key]) then
                    seen[key] = true
                    seen[timer_key] = true
                    local e = {
                        label = (label or data.auto_label(r.name)):sub(1, width),
                        name = r.name, kind = r.kind, id = r.id, recast_id = r.recast_id,
                        status = r.status, levels = r.levels, sub = is_sub, prefix = r.prefix,
                        jatype = r.type, alts = #alts > 1 and alts or nil, need_arts = need_arts,
                        pick_ready = pick_ready and #alts > 1 or nil,
                    }
                    local ch = r.kind == 'ja' and charges[r.recast_id]
                    if ch then
                        e.charges = { max = ch.max, time = ch.time }
                        if r.recast_id == 231 then
                            e.charges.max = sch_strat_max()
                            e.charges.time = math.floor(240 / e.charges.max)
                        end
                    end
                    entries[#entries + 1] = e
                end
            end
            end
            if if_known and #entries == before + 1 then entries[#entries].if_known = true end
            -- Merit abilities (Group 2) in your own grid: an empty slot until merited.
            if not is_sub and #entries == before + 1 and entries[#entries].kind == 'ja'
               and data.MERIT_JA[entries[#entries].name] then
                entries[#entries].if_known = true
                entries[#entries].merit = true
            end
            if span and span > 1 and not is_sub and #entries == before + 1 then
                local owner = entries[#entries]
                if owner.label and owner.name then
                    owner.label = (label or data.auto_label(owner.name)):sub(1, display.span_chars(span))
                end
                owner.span = span
                for _ = 2, span do entries[#entries + 1] = { covered = true, owner = owner } end
            end
        end
    end

    add(cfg.cooldowns, false)
    -- With the stratagem bar in the grid, stratagem cells don't repeat the charge count.
    local bar = false
    for _, e in ipairs(entries) do if e.meter then bar = true end end
    if bar then
        for _, e in ipairs(entries) do if e.recast_id == 231 and not e.meter then e.no_count = true end end
    end
    if player.sub_job and settings.subjobs[player.sub_job] then
        add(settings.subjobs[player.sub_job], true)
    end
    if #unknown > 0 then
        msg('Not recognised (check spelling): ' .. table.concat(unknown, ', '))
    end
end

local function refresh_learned()
    local now = os.clock()
    if now - learned_at < 2 then return end
    learned_at = now
    learned_ja, learned_spells = {}, {}
    local ab = windower.ffxi.get_abilities() or {}
    for k, v in pairs(ab.job_abilities or {}) do
        if type(v) == 'number' then learned_ja[v] = true elseif v == true then learned_ja[k] = true end
    end
    for k, v in pairs(windower.ffxi.get_spells() or {}) do
        if v then learned_spells[k] = true end
    end
end

local function available(e)
    -- Pet commands (Ready, Spur, Steady Wing, breaths...) can only be used with a pet out.
    if e.prefix == '/pet' then return windower.ffxi.get_mob_by_target('pet') ~= nil end
    if e.kind == 'ja' then
        -- Stratagems share one timer but unlock at different levels (Rapture at 55): check
        -- the one itself.
        if e.recast_id == 231 then return learned_ja[e.id] == true end
        for _, id in ipairs(data.recast_group(e.recast_id)) do
            if learned_ja[id] then return true end
        end
        return false
    end
    if not learned_spells[e.id] then return false end
    local lv = e.levels or {}
    local m, s = lv[player.main_job_id], lv[player.sub_job_id]
    if m and (m <= player.main_job_level or m > 99) then return true end
    if s and s <= sub_level() then return true end
    return false
end

-- Pet HP alarm: true while your pet is out and under this job's pet_alarm HP%.
local PET_HEAL = { ['Spirit Link'] = true, ['Steady Wing'] = true, ['Reward'] = true }
local function pet_alarm()
    local at = tonumber(job_cfg().pet_alarm) or 0
    if at <= 0 then return false end
    local pet = windower.ffxi.get_mob_by_target('pet')
    return pet and (pet.hpp or 100) > 0 and (pet.hpp or 100) < at
end
local function flash_on() return math.floor(os.clock() * 4) % 2 == 0 end

-- Ammo: the equipped stack and how many more of it are in your inventory and wardrobes.
-- Green normally, flashing red under ammo_warn (10), red with none.
local AMMO_BAGS = { 0, 8, 10, 11, 12, 13, 14, 15, 16 }   -- inventory, wardrobes 1-8
local ammo_spare = { at = -10 }
local function ammo_info()
    local eq = windower.ffxi.get_items('equipment')
    local index, bag = eq and eq.ammo, eq and eq.ammo_bag
    if not index or index == 0 then return nil end
    local it = windower.ffxi.get_items(bag, index)
    if not it or not it.id or it.id == 0 then return nil end
    -- The spare count walks the bags, so only every 2 seconds.
    local now = os.clock()
    if ammo_spare.id ~= it.id or now - ammo_spare.at >= 2 then
        local n = 0
        for _, b in ipairs(AMMO_BAGS) do
            local items = windower.ffxi.get_items(b)
            if type(items) == 'table' then
                for i = 1, tonumber(items.max) or 80 do
                    local x = items[i]
                    if type(x) == 'table' and x.id == it.id and not (b == bag and i == index) then
                        n = n + (x.count or 0)
                    end
                end
            end
        end
        ammo_spare = { id = it.id, n = n, at = now }
    end
    return data.item_name(it.id), it.count or 0, ammo_spare.n
end

-- Item counter cell (#COUNT:Shihei): how many are in your inventory. Green; under ammo_warn
-- (10) it flashes red; none: red 'NONE'.
local count_cache = {}
local count_ids = {}     -- item name -> id (looked up once)
-- Every bag: inventory, Mog Safe / Safe 2, Storage, Locker, Satchel, Sack, Case, Wardrobes 1-8.
local ALL_BAGS = { { 0, 'Inventory' }, { 1, 'Mog Safe' }, { 9, 'Mog Safe 2' }, { 2, 'Storage' },
    { 4, 'Mog Locker' }, { 5, 'Satchel' }, { 6, 'Sack' }, { 7, 'Case' }, { 8, 'Wardrobe' },
    { 10, 'Wardrobe 2' }, { 11, 'Wardrobe 3' }, { 12, 'Wardrobe 4' }, { 13, 'Wardrobe 5' },
    { 14, 'Wardrobe 6' }, { 15, 'Wardrobe 7' }, { 16, 'Wardrobe 8' } }

-- How many of an item you have across all your bags (every 2 s): total, and { bag name = n }.
local function inventory_count(name)
    local now = os.clock()
    local c = count_cache[name]
    if c and now - c.at < 2 then return c.n, c.where end
    local id = count_ids[name]
    if id == nil then id = data.item_id(name) or false count_ids[name] = id end
    local n, where = 0, {}
    for _, bag in ipairs(id and ALL_BAGS or {}) do
        local items = windower.ffxi.get_items(bag[1])
        if type(items) == 'table' then
            local here = 0
            for i = 1, tonumber(items.max) or 80 do
                local x = items[i]
                if type(x) == 'table' and x.id == id then here = here + (x.count or 0) end
            end
            if here > 0 then n = n + here where[#where + 1] = bag[2] .. ' ' .. here end
        end
    end
    count_cache[name] = { n = n, where = where, at = now }
    return n, where
end

local function count_cell(e)
    local C = palette
    local n, where = inventory_count(e.count_item)
    local warn = tonumber(settings.ammo_warn) or 10
    local low = n < warn
    local label, value = e.label, n > 0 and tostring(n) or 'NONE'
    -- Toolbags of it (Shihei -> Toolbag (Shihe)): '(#)' after the count, e.g. 87(2). Ten or more
    -- toolbags won't fit the brackets: '(*)'. If the count and brackets together are too wide for
    -- the cell, the count shows alone with a '*' (106*). Hover for the exact numbers.
    local bag = data.toolbag_name(e.count_item)
    local bags, bag_where = 0, {}
    if bag then bags, bag_where = inventory_count(bag) end
    if bag then
        local tag = '(' .. bags .. ')'
        if #tag > 3 then tag = '(*)' end
        local v = (n > 0 and tostring(n) or '0') .. tag
        if #v <= settings.grid.cell_chars then value = v
        else value = (n > 0 and tostring(n) or '0') .. '*' end
    end
    return { label = label, value = value,
             color = low and C.cooldown or C.ready, label_color = C.cell_text, value_color = C.cell_text,
             flash = low or nil, flash_color = low and C.empty or nil,
             tip = ('%s: %d in all your bags%s%s%s'):format(e.count_item, n,
                 #where > 0 and (' (' .. table.concat(where, ', ') .. ')') or '',
                 low and (' - under ' .. warn .. '!') or '',
                 bag and ('\n%s: %d%s'):format(bag, bags,
                     #bag_where > 0 and (' (' .. table.concat(bag_where, ', ') .. ')') or '') or '') }
end

local function ammo_cell(e)
    local C = palette
    local name, count, spare = ammo_info()
    local warn = tonumber(settings.ammo_warn) or 10
    if not name or count <= 0 then
        return { label = 'NO AMMO', value = spare and spare > 0 and ('+' .. spare .. ' in bags') or '',
                 color = C.cooldown, label_color = C.cell_text, value_color = C.cell_text,
                 flash = true, flash_color = C.empty, tip = 'No ammo equipped' }
    end
    local low = count < warn
    return {
        label = name,
        value = tostring(count) .. (spare > 0 and ('  +' .. spare) or ''),
        color = low and C.cooldown or C.ready,
        label_color = C.cell_text, value_color = C.cell_text,
        flash = low or nil, flash_color = low and C.empty or nil,
        tip = ('%s: %d equipped%s%s'):format(name, count,
            spare > 0 and (', ' .. spare .. ' more in your inventory / wardrobes') or '',
            low and (' - under ' .. warn .. '!') or ''),
    }
end

-- Phantom Rolls on you, oldest first: { name, id, info (number, if seen) }.
local function active_rolls(counts)
    data.prune_rolls(counts)
    local list = {}
    for name in pairs(data.ROLL_LUCK) do
        local id = data.buff_id(name .. ' Roll')
        if id and counts[id] then list[#list + 1] = { name = name, id = id, info = data.rolls[name] } end
    end
    table.sort(list, function(a, b)
        local ta, tb = a.info and a.info.at or 0, b.info and b.info.at or 0
        if ta ~= tb then return ta < tb end
        return a.name < b.name
    end)
    return list
end

-- A big roll box (2x2 cells): roll and number, what it raises, how much, luck and time left.
-- Background: green lucky / 11, red unlucky / bust, orange any other number, grey unknown.
local function roll_box(slot, counts)
    local C = palette
    local W = display.span_chars(2)
    local rolls = active_rolls(counts)
    local r = rolls[slot]
    local function fit(a, b)
        a, b = tostring(a), tostring(b or '')
        -- Keep the left text whole: drop the right one if both don't fit.
        if b ~= '' and #a + 1 + #b > W and #a <= W then b = '' end
        local room = W - #b - (b ~= '' and 1 or 0)
        if #a > room then a = a:sub(1, math.max(room, 0)) end
        return a .. (' '):rep(math.max(W - #a - #b, b ~= '' and 1 or 0)) .. b
    end
    if not r then
        local bust = data.buff_id('Bust')
        if slot == #rolls + 1 and bust and counts[bust] then
            local left = data.buff_remaining(bust)
            return { box = { fit('Bust', ''), '', fit('Fold it or', ''), fit('wait', left and fmt_time(left)) },
                     color = C.cooldown, text_color = C.cell_text, tip = 'Busted: Phantom Roll is blocked until it wears or you Fold' }
        end
        return { box = { '', fit('No roll ' .. slot, ''), '', '' }, color = C.empty, text_color = C.dim,
                 tip = 'Roll box ' .. slot .. ': no Phantom Roll on you' }
    end
    local d = ROLL_DATA[r.name] or { effect = '?', full = '?', v = {} }
    local luck = data.ROLL_LUCK[r.name]
    local n = r.info and r.info.value
    local num, value, color, note
    if not n then
        num, value, color, note = '?', '--', C.unavailable, 'number not seen (rolled before the addon loaded)'
    elseif n > 11 then
        num, value, color, note = 'BUST', d.bust or '?', C.cooldown, 'bust'
    else
        num, value = tostring(n), d.v[n] or '?'
        if n == 11 then color, note = C.ready, 'eleven!'
        elseif n == luck[1] then color, note = C.ready, 'lucky'
        elseif n == luck[2] then color, note = C.cooldown, 'unlucky'
        else color, note = C.soon, nil end
    end
    if value:match('^%d') then value = '+' .. value end
    local left = data.buff_remaining(r.id)
    local short = r.name:gsub("'s$", ''):gsub("'$", '')
    local lines = {
        fit(short, num),
        fit(d.effect, ''),
        fit(value, note == 'lucky' and 'LCKY' or note == 'unlucky' and 'UNLK' or note == 'eleven!' and 'MAX' or ''),
        fit(('L%d U%d'):format(luck[1], luck[2]), left and fmt_time(left) or ''),
    }
    local tip = ('%s Roll %s: %s %s%s. Lucky %d, unlucky %d.'):format(r.name, num, d.full, value,
        note and (' (' .. note .. ')') or '', luck[1], luck[2])
    if d.plus then tip = tip .. ' Phantom Roll+ gear: ' .. d.plus .. ' per point.' end
    if d.job then tip = tip .. ' ' .. d.job .. ' in the party (or worn): +' .. d.bonus:gsub('^%+', '') .. ' more.' end
    if left then tip = tip .. ' ' .. fmt_time(left) .. ' left.' end
    return { box = lines, color = color, text_color = C.cell_text, tip = tip }
end

-- The command that uses a grid cell's ability or spell, e.g. 'input /ja "Berserk" <me>'.
-- Target: <t> for things used on an enemy, <me> for things you can use on yourself, else <stpt>
-- (pick a party member).
local function use_command(e)
    local r = e.kind == 'ja' and res.job_abilities[e.id] or e.kind == 'spell' and res.spells[e.id] or nil
    if not r then return nil end
    -- SP abilities (1-hour / SP2: Spirit Surge, Soul Voice, Mighty Strikes, Bolster...) are never
    -- clickable, so a stray click can't burn one. They share recast 0 (SP1) and 254 (SP2).
    if e.kind == 'ja' and (r.recast_id == 0 or r.recast_id == 254) then return nil end
    local t = r.targets
    local function has(name, bit)
        if type(t) == 'table' then
            if t[name] then return true end
            for _, v in pairs(t) do if v == name then return true end end
            return false
        end
        return type(t) == 'number' and math.floor(t / bit) % 2 == 1
    end
    local target = has('Enemy', 32) and '<t>' or has('Self', 1) and '<me>' or '<stpt>'
    local prefix = r.prefix or (e.kind == 'ja' and '/ja' or '/ma')
    return ('input %s "%s" %s'):format(prefix, r.en or r.english or e.name, target)
end

-- 'Curing Waltz V' -> 'CW5', 'Curing Waltz' -> 'CW1': initials plus the tier.
local ROMAN_DIGIT = { I = 1, II = 2, III = 3, IV = 4, V = 5, VI = 6 }
local function tier_label(name)
    local initials, tier = '', 1
    for w in name:gmatch('%S+') do
        if ROMAN_DIGIT[w] then tier = ROMAN_DIGIT[w] else initials = initials .. w:sub(1, 1):upper() end
    end
    return (initials .. tier):sub(1, settings.grid.cell_chars)
end

local function build_cells(counts)
    local highlighted = {}
    for _, n in ipairs(data.split(job_cfg().highlight)) do highlighted[n:lower()] = true end
    local C = palette
    local cells = {}
    local ja_recasts = windower.ffxi.get_ability_recasts() or {}
    local sp_recasts = windower.ffxi.get_spell_recasts() or {}
    local soon_s, soon_p = settings.soon_seconds, settings.soon_pct

    local meter_tip
    local box_tips = {}
    for _, e in ipairs(entries) do
        local cell
        if e.blank then
            cell = { empty = true }
        elseif e.box then
            cell = roll_box(e.box, counts)
            box_tips[e.box] = cell.tip
        elseif e.covered then
            -- The rest of a bar's row (or a roll box): drawn by it, hovering shows its details.
            cell = { covered = true,
                     tip = e.owner and e.owner.tip or e.of and box_tips[e.of] or meter_tip,
                     use = e.owner and e.owner.use or nil }
        elseif e.ammo then
            cell = ammo_cell(e)
        elseif e.count_item then
            cell = count_cell(e)
        elseif e.big then
            -- Message box: text centred across and down the whole box.
            local W = display.span_chars(e.cols)
            local msg_lines = { 'why are you here,', 'go use GEO-HUD' }
            local n = 2 * e.rows
            local out = {}
            local top = math.floor((n - #msg_lines) / 2)
            for k = 1, n do
                local t = msg_lines[k - top] or ''
                local l = math.floor((W - #t) / 2)
                out[k] = (' '):rep(math.max(l, 0)) .. t
            end
            cell = { box = out, span = { e.cols, e.rows }, color = palette.buffed, text_color = palette.cell_text }   -- (no hover text)
        elseif e.meter then
            -- Stratagem bar: one segment per charge. Held charges are full (ready colour), the
            -- one recharging fills up as it charges, the rest are empty.
            local remaining = ja_recasts[e.recast_id] or 0
            data.observe_charge(charge_key(e), remaining)
            local per = data.charge_time(charge_key(e), e.charges.time)
            local have, next_in = data.charges(remaining, e.charges.max, per)
            local segs = {}
            for i = 1, math.max(e.charges.max, e.slots or 0) do
                if i > e.charges.max then
                    segs[i] = { fill = 0, locked = true }   -- more than your level holds
                elseif i <= have then
                    segs[i] = { fill = 1, color = C.ready, text = tostring(i) }
                elseif i == have + 1 and next_in > 0 then
                    segs[i] = { fill = math.max(0, math.min(1, 1 - next_in / per)),
                                color = next_in <= math.max(soon_s, soon_p * per) and C.soon or C.cooldown,
                                text = tostring(i), value = fmt_cd(next_in) }
                else
                    segs[i] = { fill = 0, text = tostring(i) }
                end
            end
            meter_tip = ('Stratagems: %d of %d%s, %s per charge'):format(have, e.charges.max,
                next_in > 0 and (', next in ' .. fmt_time(next_in)) or ' (full)', fmt_time(per))
            cell = { meter = segs, tip = meter_tip, text_color = C.cell_text, dim_color = C.dim }
        elseif e.missing then
            cell = { label = e.label, value = '?', color = C.unavailable, label_color = C.bad, value_color = C.bad,
                     tip = e.label .. ': "' .. e.name .. '" isn\'t an ability or spell the addon knows (check the spelling)' }
        else
            -- '!A|B|C' (separate timers): the first one ready, else the one back soonest.
            if e.pick_ready then
                local best, best_rem
                for _, a in ipairs(e.alts) do
                    if available(a) then
                        local rem = a.kind == 'ja' and (ja_recasts[a.recast_id] or 0) or (sp_recasts[a.recast_id] or 0) / 60
                        if rem <= 0 then best, best_rem = a, rem break end
                        if not best or rem < best_rem then best, best_rem = a, rem end
                    end
                end
                best = best or e.alts[1]
                if e.name ~= best.name then e.max = nil end
                e.name, e.kind, e.id, e.recast_id = best.name, best.kind, best.id, best.recast_id
                e.status, e.levels, e.prefix, e.jatype = best.status, best.levels, best.prefix, best.type
                e.label = tier_label(best.name)
            elseif e.alts then
                for _, a in ipairs(e.alts) do
                    if available(a) then
                        e.name, e.kind, e.id, e.recast_id = a.name, a.kind, a.id, a.recast_id
                        e.status, e.levels, e.prefix, e.jatype = a.status, a.levels, a.prefix, a.type
                        break
                    end
                end
            end
            -- Jigs (one shared timer): SJIG for Spectral Jig, CJIG while Chocobo Jig's speed is on you.
            if e.jatype == 'Jig' then
                local quick = data.buff_id('quickening') or 176
                local choco = counts[quick]
                local want = choco and 'Chocobo Jig II|Chocobo Jig' or 'Spectral Jig'
                local pick
                for _, a in ipairs(data.resolve_alts(want)) do if available(a) then pick = a break end end
                if pick then
                    e.name, e.id, e.prefix = pick.name, pick.id, pick.prefix
                    e.label = choco and 'CJIG' or 'SJIG'
                end
            end
            local remaining
            if e.kind == 'ja' then
                remaining = ja_recasts[e.recast_id] or 0
            else
                remaining = (sp_recasts[e.recast_id] or 0) / 60
            end
            local usable = available(e) and not e.need_arts
            -- (Merit abilities check their own id: stratagems share a timer with ones you
            -- always have.)
            local known = e.merit and learned_ja[e.id] or (not e.merit and available(e))
            if e.if_known and not known then e.hidden = true else e.hidden = nil end
            local state, value, label = nil, nil, e.label
            local who = e.label .. ' = ' .. e.name .. (e.sub and ' (support job)' or '')
            local tip

            -- (A stratagem you can't use yet stays unavailable even while the shared timer runs.)
            if (not usable and (remaining <= 0 or e.recast_id == 231)) or e.need_arts then
                state = 'unavailable'
            elseif e.charges then
                data.observe_charge(charge_key(e), remaining)
                local per = data.charge_time(charge_key(e), e.charges.time)
                local have, next_in = data.charges(remaining, e.charges.max, per)
                label = e.no_count and e.label or (e.label:sub(1, settings.grid.cell_chars - 2) .. ' ' .. have)
                tip = ('%s: %d of %d charges%s, %s per charge'):format(who, have, e.charges.max,
                    next_in > 0 and (', next in ' .. fmt_time(next_in)) or '', fmt_time(per))
                if have >= 1 then
                    state = 'ready'
                    value = next_in > 0 and fmt_cd(next_in) or 'RDY'
                else
                    state = next_in <= math.max(soon_s, soon_p * per) and 'soon' or 'cooldown'
                    value = fmt_cd(next_in)
                end
            else
                if remaining > (e.max or 0) then e.max = remaining end
                if remaining <= 0 then
                    e.max = nil
                    state, value = 'ready', 'RDY'
                    tip = who .. ': ready'
                else
                    local full = e.max or remaining
                    state = remaining <= math.max(soon_s, soon_p * full) and 'soon' or 'cooldown'
                    value = fmt_cd(remaining)
                    tip = ('%s: %s left (recast %s)'):format(who, fmt_time(remaining), fmt_time(full))
                end
            end

            -- RUN wards and effusions need runes: show how many you'd use, or that you have none.
            local rune_note
            if (e.jatype == 'Ward' or e.jatype == 'Effusion') and state == 'ready' then
                local runes = data.rune_count(counts)
                if runes == 0 then
                    state, value = 'norunes', '0 RN'
                    tip = who .. ': needs runes up (none right now)'
                else
                    value = 'RDY ' .. runes
                    tip = who .. ': ready, uses your ' .. runes .. ' rune' .. (runes > 1 and 's' or '')
                        .. (e.jatype == 'Effusion' and ' (consumed)' or '')
                end
            end
            local hide = state == 'unavailable' and (e.sub or settings.hide_unavailable)
            if not hide then
                if state == 'unavailable' then
                    value = '--'
                    tip = who .. ': can\'t use it right now (' .. (e.need_arts and 'needs Light or Dark Arts up'
                        or e.prefix == '/pet' and 'needs your pet out'
                        or 'not learned, or above your level') .. ')'
                end
                -- Purple: a one-use ability (Stymie, Embolden, Warrior's Charge, Sekkanoki...) whose
                -- effect is waiting on your next action, on every job (active_cells), plus anything
                -- on the job's highlight list while its effect is on you.
                -- Cyan label: any other effect of this ability is on you (Berserk, Crusade...).
                local on = false
                if e.status then
                    for _, id in ipairs(data.buff_ids(data.buff_name(e.status))) do
                        if counts[id] then on = true break end
                    end
                end
                local purple = false
                local one = settings.active_cells and data.one_use_ids(e.name, e.recast_id)
                if one then
                    for _, id in ipairs(one) do if counts[id] then purple = true break end end
                end
                if not purple and on and (highlighted[e.name:lower()] or highlighted[e.label:lower()]) then
                    purple = true
                end
                local cyan = on and not purple and e.jatype ~= 'CorsairRoll'
                    and (e.kind ~= 'ja' or #data.recast_group(e.recast_id) == 1)
                if purple then tip = tip .. ' (waiting on your next action)'
                elseif on then tip = tip .. ' (its effect is on you)' end
                local norunes = state == 'norunes'
                cell = {
                    label = label, value = value,
                    color = (purple and C.buffed) or (norunes and C.unavailable) or C[state],
                    flash = state == 'ready' and PET_HEAL[e.name] and pet_alarm() or nil,
                    label_color = (state == 'unavailable' or norunes) and C.dim
                        or (cyan and C.cell_active) or C.cell_text,
                    value_color = (state == 'unavailable' or norunes) and C.dim or C.cell_text,
                    tip = tip,
                }
                if settings.announce_ready and state == 'ready' and e.state and e.state ~= 'ready'
                   and e.state ~= 'unavailable' and e.state ~= 'norunes' then
                    msg(e.name .. ' is ready.')
                end
            end
            e.state = state
            if e.hidden then cell = { empty = true } end
        end
        if cell then
            cell.sub = e.sub
            if e.span and e.span > 1 then cell.span = { e.span, 1 } end
            -- Click to use (option 'clickuse'): the command this cell sends.
            if e.name and e.kind and not e.missing and not e.covered and not e.box and not e.meter then
                e.use = use_command(e)
                cell.use = e.use
                if e.use and settings.click_to_use and cell.tip then cell.tip = cell.tip .. '  [click to use]' end
            end
            e.tip = cell.tip
            cells[#cells + 1] = cell
        end
    end
    return cells
end

------------------------------------------------------------------------------------------
-- Rows
------------------------------------------------------------------------------------------

-- One text row: an optional label column, then colored segments. Clipped to the layout width
-- so the panel never grows.
local function line(label, segs)
    local C = palette
    local width = col_width or settings.layout.width
    local s, n = '', 0
    local hovers = {}   -- { c0, c1, tip }: character spans with hover details
    if label then
        s = cs(C.label, pad(label, LABEL_W))
        n = LABEL_W
    end
    for _, seg in ipairs(segs) do
        local text = tostring(seg[1])
        if n + #text > width then text = text:sub(1, math.max(width - n, 0)) end
        if text ~= '' then
            s = s .. cs(seg[2] or C.text, text)
            if seg[3] then
                local lead = #text:match('^%s*')
                hovers[#hovers + 1] = { n + lead, n + #text, seg[3] }
            end
            n = n + #text
        end
        if n >= width then break end
    end
    -- segs.tip: details for the whole line
    if segs.tip then hovers[#hovers + 1] = { 0, n, segs.tip } end
    return { s = s, n = n, hovers = hovers }
end

local function pct_color(p)
    local C = palette
    if p >= 75 then return C.good elseif p >= 50 then return C.text elseif p >= 25 then return C.warn end
    return C.bad
end

local SLOT_LABEL = { main = 'MAIN', sub = 'SUB', range = 'RNG', ammo = 'AMMO' }

local function equipped(slot)
    local eq = windower.ffxi.get_items('equipment')
    if not eq then return nil end
    local index, bag = eq[slot], eq[slot .. '_bag']
    if not index or index == 0 then return nil end
    local key = tostring(bag) .. ':' .. tostring(index)
    local item = windower.ffxi.get_items(bag, index)
    local id = item and item.id
    if not id or id == 0 then return nil end
    local c = equip_cache[key]
    if c and c.id == id then return c.name, id end
    local name = data.item_name(id)
    equip_cache[key] = { id = id, name = name }
    return name, id
end

-- Sublimation: how long it has been charging and an estimate of the MP it will give back.
-- Every 3 s it turns HP into MP: 2 MP at SCH 35, +1 per 10 levels (8 at 95+), plus 1 per point
-- of "Sublimation" gear worn at that moment, and one free tick at the start. It stops at half
-- your max HP. The game doesn't report the stored amount, so this is an estimate.
local subl = nil   -- { start, stored, last, known, bonus, bonus_at, complete }
local subl_seen_off = false

local function subl_base()
    local lvl = player.main_job == 'SCH' and player.main_job_level
        or player.sub_job == 'SCH' and sub_level() or 0
    if lvl < 35 then return 0 end
    return math.min(8, 2 + math.floor((lvl - 35) / 10))
end

local SUBL_SLOTS = { 'main', 'sub', 'head', 'body', 'waist', 'left_ear', 'right_ear', 'left_ring', 'right_ring' }
local function subl_gear()
    local n = 0
    for _, slot in ipairs(SUBL_SLOTS) do
        local _, id = equipped(slot)
        n = n + data.sublimation_bonus(id)
    end
    return n
end

local function track_sublimation()
    local active, complete = data.buff_id('Sublimation: Activated'), data.buff_id('Sublimation: Complete')
    local on_a, on_c = false, false
    for _, id in ipairs(player.buffs or {}) do
        if id == active then on_a = true elseif id == complete then on_c = true end
    end
    local now = os.clock()
    if not on_a and not on_c then
        subl = nil
        subl_seen_off = true
        return
    end
    if not subl then
        -- Started while we watched: exact start and the free first tick. Otherwise (addon
        -- loaded mid-charge) the time and MP are only what we've seen since.
        local bonus = subl_gear()
        subl = { start = now, last = now, known = subl_seen_off, bonus = bonus, bonus_at = now,
                 stored = subl_seen_off and (subl_base() + bonus) or 0 }
    end
    if on_a then
        if now - subl.bonus_at >= 1 then subl.bonus, subl.bonus_at = subl_gear(), now end
        subl.stored = subl.stored + (now - subl.last) / 3 * (subl_base() + subl.bonus)
        local cap = (player.vitals.max_hp or 0) / 2
        if cap > 0 and subl.stored > cap then subl.stored = cap end
    end
    subl.complete = on_c
    subl.last = now
end

local function element_list(defs, counts, field)
    local present = {}
    for _, d in ipairs(defs) do
        local id = data.buff_id(d.name)
        local c = id and counts[id]
        if c then present[#present + 1] = { def = d, count = c, id = id } end
    end
    return present
end

local function soonest(present)
    local best
    for _, p in ipairs(present) do
        local left = data.buff_remaining(p.id)
        if left and (not best or left < best) then best = left end
    end
    return best
end

local ROWS = {}

-- Your own buffs wearing off: under 'warn' seconds (30) they turn yellow, under 10 orange,
-- and blink slowly (on / dim, about once a second).
local function wearing_color(left, warn)
    local C = palette
    warn = tonumber(warn) or 30
    if not left or left > warn then return C.good end
    local col = left <= 10 and C.warn or C.upkeep_warn
    if math.floor(os.clock() / 0.6) % 2 == 1 then return C.dim end
    return col
end

local function slot_row(slot)
    return function(lines, counts)
        local C = palette
        local name, id = equipped(slot)
        if not name then
            lines[#lines + 1] = line(SLOT_LABEL[slot], { { '--', C.dim, 'Nothing equipped in this slot' } })
            return
        end
        -- Main weapon that can give Aftermath: its level and time left after the name.
        local am
        -- (Ranged weapons give it too: the RNG line shows it unless the main weapon can.)
        local main_am = false
        if slot == 'range' then
            local _, mid = equipped('main')
            main_am = data.has_aftermath(mid)
        end
        if (slot == 'main' or (slot == 'range' and not main_am)) and data.has_aftermath(id) then
            local lv, bid = data.aftermath(counts or {})
            if lv then
                local left = data.buff_remaining(bid)
                -- Which kind: what this weapon's Aftermath does at this level (from its
                -- description), e.g. AM3 OA2/3, AM1 Acc, AM2 ODD, AM3 SC/MB.
                local kind, full = data.aftermath_kind(id, lv)
                local label = (lv > 0 and ('AM' .. lv) or 'AM') .. (kind and (' ' .. kind) or '')
                am = { label .. (left and (' ' .. fmt_time(left)) or ''),
                       left and wearing_color(left, settings.upkeep_warn) or C.good,
                       (lv > 0 and ('Aftermath Lv.' .. lv) or 'Aftermath') .. (full and (' (' .. full .. ')') or '')
                       .. (left and (': ' .. fmt_time(left) .. ' left') or ' is on') }
            else
                am = { 'AM --', C.dim, 'No Aftermath on you (' .. name .. ' can give it)' }
            end
        end
        local width = col_width or settings.layout.width
        local room = width - LABEL_W - (am and (#am[1] + 2) or 0)
        local segs = { { name:sub(1, math.max(room, 6)), C.text, name } }
        if am then segs[2] = { '  ' .. am[1], am[2], am[3] } end
        lines[#lines + 1] = line(SLOT_LABEL[slot], segs)
    end
end
ROWS.weapon = slot_row('main')
ROWS.sub = slot_row('sub')
ROWS.ranged = slot_row('range')
ROWS.ammo = slot_row('ammo')

function ROWS.tp(lines)
    local C = palette
    local tp = player.vitals.tp or 0
    local col = tp >= 3000 and C.accent or tp >= 1000 and C.good or C.text
    lines[#lines + 1] = line('TP', { { tostring(tp), col } })
end

function ROWS.hp(lines)
    local v = player.vitals
    lines[#lines + 1] = line('HP', { { tostring(v.hp), pct_color(v.hpp) }, { '  ' .. v.hpp .. '%', palette.dim } })
end

function ROWS.mp(lines)
    local v = player.vitals
    lines[#lines + 1] = line('MP', { { tostring(v.mp), pct_color(v.mpp) }, { '  ' .. v.mpp .. '%', palette.dim } })
end

-- HP / MP / TP on one line.
function ROWS.vitals(lines)
    local C = palette
    local v = player.vitals
    local tp = v.tp or 0
    local segs = { { 'HP ', C.label }, { tostring(v.hp), pct_color(v.hpp or 100) } }
    -- MP always shows, so the line looks the same on every job (a dim 0 when you have none).
    segs[#segs + 1] = { '  MP ', C.label }
    if (v.max_mp or 0) > 0 or (v.mp or 0) > 0 then
        segs[#segs + 1] = { tostring(v.mp), pct_color(v.mpp or 100) }
    else
        segs[#segs + 1] = { '0', C.dim }
    end
    segs[#segs + 1] = { '  TP ', C.label }
    segs[#segs + 1] = { tostring(tp), tp >= 3000 and C.accent or tp >= 1000 and C.good or C.text }
    -- Narrow column (compact mode): tighten the gaps so TP isn't cut off.
    local width = col_width or settings.layout.width
    local len = 0
    for _, sg in ipairs(segs) do len = len + #sg[1] end
    if len > width then
        segs[3][1], segs[5][1] = ' MP ', ' TP '
        len = len - 2
    end
    if len > width then
        segs[1][1], segs[3][1], segs[5][1] = 'HP', ' MP', ' TP'
    end
    lines[#lines + 1] = line(nil, segs)
end

-- Name, HP%, then extras (pet TP / target distance); the name is shortened to make room.
-- BST Ready charges: have, max, seconds to the next, seconds per charge (nil if not set up).
local function ready_charges()
    local ch = data.parse_charges(settings.charges)[102]   -- 102 = Ready / Sic
    if not ch then return nil end
    local remaining = (windower.ffxi.get_ability_recasts() or {})[102] or 0
    local per = data.charge_time(102, ch.time)
    local have, next_in = data.charges(remaining, ch.max, per)
    return have, ch.max, next_in, per
end

-- What the pet is attacking: the pet status packet's target, else what it last hit.
local function pet_target(pet)
    local id = (data.pet.index == pet.index and data.pet.target) or data.last_target[pet.id]
    local m = id and windower.ffxi.get_mob_by_id(id)
    if m and m.is_npc and (m.hpp or 0) > 0 then return m end
end

-- Who a mob is attacking (the game's target info, else its last attack).
local function mob_victim(mob)
    if mob.target_index and mob.target_index > 0 then
        local m = windower.ffxi.get_mob_by_index(mob.target_index)
        if m then return m end
    end
    local id = data.last_target[mob.id]
    return id and windower.ffxi.get_mob_by_id(id)
end

-- Extra pet lines, per job (pet_info = 'ready,target,hate'):
--   ready   Ready charges and time to the next one
--   target  what the pet is attacking, and its HP%
--   hate    who that mob is attacking: Pet (green), You (yellow), or someone else (red)
pet_extras = function(lines, pet)
    local C = palette
    local want = {}
    for _, k in ipairs(data.split(job_cfg().pet_info)) do want[k:lower()] = true end
    local indent = { (' '):rep(LABEL_W + 2), C.text }
    if want.ready then
        local have, max, next_in, per = ready_charges()
        if have then
            local segs = { indent, { 'Ready ', C.label },
                           { have .. '/' .. max, have > 0 and C.good or C.bad } }
            if have < max then segs[#segs + 1] = { '  next ' .. fmt_time(next_in), C.dim } end
            segs.tip = ('Ready: %d of %d charges%s, %s per charge'):format(have, max,
                have < max and (', next in ' .. fmt_time(next_in)) or '', fmt_time(per))
            lines[#lines + 1] = line(nil, segs)
        end
    end
    local tgt = (want.target or want.hate) and pet_target(pet)
    if want.target then
        if tgt then
            local hp = '  ' .. (tgt.hpp or 0) .. '%'
            local room = (col_width or settings.layout.width) - #indent[1] - 4 - #hp
            lines[#lines + 1] = line(nil, { indent, { 'Tgt ', C.label }, { tgt.name:sub(1, math.max(room, 4)), C.text },
                { hp, pct_color(tgt.hpp or 0) }, tip = pet.name .. ' is attacking ' .. tgt.name })
        else
            lines[#lines + 1] = line(nil, { indent, { 'Tgt ', C.label }, { '--', C.dim }, tip = pet.name .. ' is not attacking' })
        end
    end
    if want.hate then
        local who = tgt and mob_victim(tgt)
        local me = player
        local segs = { indent, { 'Hate ', C.label } }
        if not who then segs[#segs + 1] = { '--', C.dim }
        elseif who.id == pet.id then segs[#segs + 1] = { 'Pet', C.good }
        elseif me and who.id == me.id then segs[#segs + 1] = { 'You', C.upkeep_warn }
        else segs[#segs + 1] = { who.name or '?', C.bad } end
        segs.tip = tgt and ('Who ' .. tgt.name .. ' is attacking') or 'Who your pet\'s target is attacking'
        lines[#lines + 1] = line(nil, segs)
    end
end

local function mob_row(label, target)
    return function(lines)
        local C = palette
        local mob = windower.ffxi.get_mob_by_target(target)
        if not (mob and mob.name and mob.name ~= '') then
            -- No pet is worth noticing on a pet job; no target isn't.
            lines[#lines + 1] = line(label, { target == 'pet' and { 'none', C.bad } or { '--', C.dim } })
            return
        end
        local hpp = mob.hpp or 0
        if target == 'pet' then
            -- Pet: name, then HP% and TP on an indented line below it. Under the job's pet_alarm
            -- HP% both lines flash red.
            local alarm = pet_alarm()
            local hot = alarm and flash_on()
            local tip = alarm and ('Pet HP under ' .. job_cfg().pet_alarm .. '%: Spirit Link / Steady Wing / Reward flash when ready') or nil
            lines[#lines + 1] = line(label, { { mob.name, hot and C.bad or C.text, tip } })
            local segs = { { (' '):rep(LABEL_W + 2), C.text }, { 'HP ', C.label },
                           { hpp .. '%', alarm and (hot and C.bad or C.text) or pct_color(hpp), tip } }
            local tp = data.pet_tp(mob)
            if tp then
                segs[#segs + 1] = { '  TP ', C.label }
                segs[#segs + 1] = { tostring(tp), tp >= 1000 and C.good or C.text }
            end
            lines[#lines + 1] = line(nil, segs)
            pet_extras(lines, mob)
            return
        end
        local tail = { { '  ' .. hpp .. '%', pct_color(hpp) } }
        if mob.distance and settings.target_distance then
            local d = math.sqrt(mob.distance)
            tail[#tail + 1] = { ('  %.1fy'):format(d), d > 20 and C.bad or C.dim }
        end
        local used = LABEL_W
        for _, t in ipairs(tail) do used = used + #t[1] end
        local name = mob.name:sub(1, math.max((col_width or settings.layout.width) - used, 6))
        local segs = { { name, C.text } }
        for _, t in ipairs(tail) do segs[#segs + 1] = t end
        lines[#lines + 1] = line(label, segs)
    end
end
ROWS.pet = mob_row('PET', 'pet')
ROWS.target = mob_row('TGT', 't')

-- Short coloured tags for buffs: green = on, yellow = under upkeep_warn seconds left,
-- red = off. Shared by 'upkeep' (your own buffs) and 'party' (buffs others keep on you).
local function tag_row(lines, counts, list, own)
    local C = palette
    list = data.split(list)
    if #list == 0 then return end
    local width = col_width or settings.layout.width
    local segs, n = {}, 0
    local function flush()
        if #segs > 0 then lines[#lines + 1] = line(nil, segs) end
        segs, n = {}, 0
    end
    -- Hover text for a tag: what it stands for and how long is left.
    local function tip_for(tag, name, key)
        if key == 'PET' then
            local pet = windower.ffxi.get_mob_by_target('pet')
            return tag .. ': ' .. (pet and (pet.name .. ' is out') or 'no pet out')
        end
        local ids = key == 'ROLL' and data.roll_buff_ids() or nil
        if not ids then
            local r = own and data.resolve_alts(name)[1]
            if r then name = r.name end
            local buff = r and r.status and data.buff_name(r.status) or name
            ids = data.buff_ids(buff)
            if r and r.status and buff:lower() ~= name:lower() then name = name .. ' (' .. buff .. ')' end
        end
        local best, on
        for _, id in ipairs(ids) do
            if counts[id] then
                on = true
                local left = data.buff_remaining(id)
                if left and (not best or left > best) then best = left end
            end
        end
        local what = key == 'ROLL' and 'any Phantom Roll' or name
        if not on then return tag .. ' = ' .. what .. ': off' end
        return tag .. ' = ' .. what .. ': ' .. (best and (fmt_time(best) .. ' left') or 'on')
    end
    local function state(ids)
        local best
        for _, id in ipairs(ids) do
            if counts[id] then
                local left = data.buff_remaining(id)
                if not left then return C.good end            -- on, no timer: can't be ending
                if not best or left > best then best = left end
            end
        end
        if not best then return C.bad end
        if own then return wearing_color(best, settings.upkeep_warn) end
        return best <= 10 and C.upkeep_warn or C.good
    end
    local shown = {}
    for _, item in ipairs(list) do
        local label, name = data.label_split(item)
        local tag, col
        local key = name:upper()
        if key == 'PET' then
            tag = label or 'PET'
            col = windower.ffxi.get_mob_by_target('pet') and C.good or C.bad
        elseif key == 'ROLL' then
            tag = label or 'ROLL'
            col = state(data.roll_buff_ids())
        elseif own then
            -- 'Haste II|Haste': the tag is shown if you can use any of them.
            local alts = data.resolve_alts(name)
            local r
            for _, a in ipairs(alts) do
                if available(a) then r = a break end
            end
            local buff = (r or alts[1]) and (r or alts[1]).status or data.buff_id(name)
            tag = label or data.auto_label(name)
            if #alts > 0 and not r then
                tag = nil
            elseif not buff then
                col, tag = C.bad, tag .. '?'
            else
                col = state(data.buff_ids(data.buff_name(buff)))
            end
        else
            -- Buffs from other people: the name is the buff itself (Haste, March, Protect...).
            local ids = data.buff_ids(name)
            tag = label or data.auto_label(name)
            if #ids == 0 then col, tag = C.bad, tag .. '?'
            else col = state(ids) end
        end
        if tag then shown[#shown + 1] = { tag, col, tip_for(tag, name, key) } end
    end
    -- Lay the tags out over as few lines as they need, spread evenly (4 + 3, not 6 + 1).
    local total = -1
    for _, t in ipairs(shown) do total = total + #t[1] + 1 end
    local nlines = math.max(1, math.ceil(total / width))
    local per = math.ceil(#shown / nlines)
    local count = 0
    for _, t in ipairs(shown) do
        local text = (n > 0 and ' ' or '') .. t[1]
        if count >= per or n + #text > width then flush() count = 0 text = t[1] end
        segs[#segs + 1] = { text, t[2], t[3] }
        n = n + #text
        count = count + 1
    end
    flush()
end

-- Upkeep: your own buffs. Name the spell/ability that gives the buff (Crusade, Temper,
-- Regen IV, Hasso...); tags for things you can't use right now (not learned, wrong subjob)
-- are left out. PET is green when your pet is out. A plain buff name works too.
function ROWS.upkeep(lines, counts)
    tag_row(lines, counts, job_cfg().upkeep, true)
end

-- Party: buffs other people keep on you (Haste, March, Protect, Shell, Refresh...), by buff
-- name. ROLL = any Phantom Roll.
-- RNG: Velocity Shot on or off (it comes right under Hover, before Bounty).
function ROWS.velocity(lines, counts)
    local C = palette
    if velocity_shown then return end
    velocity_shown = true
    local id = data.buff_id('Velocity Shot')
    local on = id and counts[id]
    local left = on and data.buff_remaining(id)
    lines[#lines + 1] = line(nil, { { 'Velocity: ', C.label }, { on and 'On' or 'Off', on and C.good or C.bad },
        tip = 'Velocity Shot ' .. (on and ('is up' .. (left and (': ' .. fmt_time(left) .. ' left') or '')) or 'is off') })
end

function ROWS.party(lines, counts)
    local list = job_cfg().party
    if list == nil and settings.jobs.DEFAULT then list = settings.jobs.DEFAULT.party end
    -- '#HASTE': FLRY (Flurry) while Velocity Shot is up, HSTE (Haste) otherwise.
    if list and list:find('#HASTE', 1, true) then
        local id = data.buff_id('Velocity Shot')
        list = list:gsub('#HASTE', (id and counts[id]) and 'FLRY=Flurry' or 'HSTE=Haste')
    end
    -- '#HSFL': one tag for Haste / Flurry (they don't go on together): FLRY while Flurry is on
    -- you, otherwise HSTE (green with Haste, red with neither).
    if list and list:find('#HSFL', 1, true) then
        local on = false
        for _, id in ipairs(data.buff_ids('Flurry')) do if counts[id] then on = true end end
        list = list:gsub('#HSFL', on and 'FLRY=Flurry' or 'HSTE=Haste')
    end
    tag_row(lines, counts, list, false)
end

function ROWS.buffs(lines, counts)
    local C = palette
    local list = data.split(job_cfg().buffs)
    local w = 0
    for _, name in ipairs(list) do w = math.max(w, #name + 3) end
    w = math.min(w, 24)
    for _, name in ipairs(list) do
        local id = data.buff_id(name)
        if not id then
            lines[#lines + 1] = line(nil, { { pad(name, w), C.bad }, { '?', C.bad } })
        else
            local count = counts[id]
            if count then
                local left = data.buff_remaining(id)
                local shown = name .. (count > 1 and (' x' .. count) or '')
                local value, col
                if left then
                    value = fmt_time(left)
                    col = wearing_color(left, settings.buff_warn)
                else
                    value, col = 'On', C.good
                end
                lines[#lines + 1] = line(nil, { { pad(shown, w), C.label }, { value, col } })
            elseif not settings.hide_missing_buffs then
                lines[#lines + 1] = line(nil, { { pad(name, w), C.dim }, { '--', C.dim } })
            end
        end
    end
end

-- RUN: one section per rune you have up, in the order you cast them. The rune's name is in
-- the color of the element it resists, with its count and the time left on the soonest one;
-- indented under it, that element and the ailments it helps resist (bright while Pflug is up,
-- since that's when the ailment resistance applies; dim otherwise).
function ROWS.runes(lines, counts)
    local C, EC = palette, element_colors()
    local by_id = {}
    for _, d in ipairs(data.RUNES) do
        local id = data.buff_id(d.name)
        if id then by_id[id] = d end
    end
    local order, seen = {}, {}
    for _, id in ipairs(player.buffs or {}) do
        if by_id[id] and not seen[id] then
            seen[id] = true
            order[#order + 1] = id
        end
    end
    if #order == 0 then
        lines[#lines + 1] = line('RUNE', { { 'none', C.bad } })
        return
    end
    local pflug = data.buff_id('Pflug')
    pflug = pflug and counts[pflug]
    local indent = '   '
    local name_w = 0
    for _, id in ipairs(order) do
        local n = counts[id]
        name_w = math.max(name_w, #by_id[id].name + (n > 1 and 3 or 0))
    end
    for _, id in ipairs(order) do
        local d, n = by_id[id], counts[id]
        local name = d.name .. (n > 1 and (' x' .. n) or '')
        local left = data.buff_remaining(id)
        if compact.runes then
            -- Short on room: one line, the ailments after the time (the name's colour is the
            -- element it resists).
            lines[#lines + 1] = line(nil, { { pad(name, name_w + 1), EC[d.resists] },
                { pad(left and fmt_time(left) or '', 5), left and left <= settings.buff_warn and C.warn or C.dim },
                { (d.ailments:gsub(', ', '/')), pflug and C.text or C.dim },
                tip = d.name .. ' resists ' .. d.resists .. ': ' .. d.ailments })
        else
            local segs = { { pad(name, 14), EC[d.resists] } }
            if left then segs[#segs + 1] = { fmt_time(left), left <= settings.buff_warn and C.warn or C.dim } end
            lines[#lines + 1] = line(nil, segs)
            lines[#lines + 1] = line(nil, { { indent, C.text }, { d.resists, EC[d.resists] },
                { ': ' .. d.ailments, pflug and C.text or C.dim } })
        end
    end
end

function ROWS.maneuvers(lines, counts)
    local C, EC = palette, element_colors()
    local present = element_list(data.MANEUVERS, counts)
    if #present == 0 then
        lines[#lines + 1] = line('MANV', { { '--', C.dim } })
        return
    end
    local segs = {}
    for i, p in ipairs(present) do
        segs[#segs + 1] = { (i > 1 and '  ' or '') .. p.def.element .. (p.count > 1 and (' x' .. p.count) or ''), EC[p.def.element] }
    end
    local left = soonest(present)
    if left then segs[#segs + 1] = { '  ' .. fmt_time(left), C.dim } end
    lines[#lines + 1] = line('MANV', segs)
end

function ROWS.rolls(lines, counts)
    local C = palette
    data.prune_rolls(counts)
    local active = {}
    for name in pairs(data.ROLL_LUCK) do
        local id = data.buff_id(name .. ' Roll')
        if id and counts[id] then active[#active + 1] = { name = name, id = id } end
    end
    table.sort(active, function(a, b) return a.name < b.name end)
    for _, r in ipairs(active) do
        local info = data.rolls[r.name]
        local luck = data.ROLL_LUCK[r.name]
        local num, col, tag, tag_col = '--', C.dim, '', C.dim
        if info then
            num, col = tostring(info.value), C.text
            if info.value > 11 then num, col = 'BUST', C.bad
            elseif info.value == 11 then col, tag, tag_col = C.accent, 'MAX', C.accent
            elseif info.value == luck[1] then col, tag, tag_col = C.good, 'LUCKY', C.good
            elseif info.value == luck[2] then col, tag, tag_col = C.bad, 'UNLUCKY', C.bad
            else tag = ('L%d U%d'):format(luck[1], luck[2]) end
        else
            tag = ('L%d U%d'):format(luck[1], luck[2])
        end
        local left = data.buff_remaining(r.id)
        local segs = { { pad(r.name, 13), C.label }, { pad(num, 5), col }, { pad(tag, 8), tag_col } }
        if left then segs[#segs + 1] = { fmt_time(left), left <= settings.buff_warn and C.warn or C.dim } end
        lines[#lines + 1] = line(nil, segs)
    end
    local bust = data.buff_id('Bust')
    if bust and counts[bust] then
        local left = data.buff_remaining(bust)
        lines[#lines + 1] = line('ROLL', { { 'BUST', C.bad }, { left and ('  ' .. fmt_time(left)) or '', C.dim } })
    end
    if #active == 0 and not (bust and counts[bust]) then
        lines[#lines + 1] = line('ROLL', { { '--', C.dim } })
    end
    -- What's left to roll from the luck table is shown in the grid (ROLL / DBL cells).
end

local SHADOW_BUFFS = { ['Copy Image'] = 1, ['Copy Image (2)'] = 2, ['Copy Image (3)'] = 3, ['Copy Image (4+)'] = 4 }

function ROWS.shadows(lines, counts)
    local C = palette
    local n = 0
    for name, v in pairs(SHADOW_BUFFS) do
        local id = data.buff_id(name)
        if id and counts[id] then n = math.max(n, v) end
    end
    local segs = {}
    if n > 0 then
        segs[#segs + 1] = { (n >= 4 and '4+' or tostring(n)) .. ' Utsu', n >= 2 and C.good or C.warn }
    end
    for _, name in ipairs({ 'Blink', 'Third Eye' }) do
        local id = data.buff_id(name)
        if id and counts[id] then segs[#segs + 1] = { (#segs > 0 and '  ' or '') .. name, C.good } end
    end
    if #segs == 0 then segs[1] = { 'none', C.bad } end
    table.insert(segs, 1, { 'Shadows ', C.label })
    lines[#lines + 1] = line(nil, segs)
end

-- Current mob for the right-hand column: your target, or the mob you're fighting.
local function focus_mob()
    local mob = windower.ffxi.get_mob_by_target('t')
    if not (mob and mob.is_npc) then mob = windower.ffxi.get_mob_by_target('bt') or mob end
    return mob
end

-- What a Step / flourish gives depends on: main job DNC, Presto up, Terpsichore in the main
-- hand, a Charis / Maculele Tiara on (Climactic Flourish +1 round).
data.dnc_context = function()
    local p = player or windower.ffxi.get_player()
    local presto = false
    for _, b in ipairs(p and p.buffs or {}) do if b == data.buff_id('Presto') then presto = true end end
    local main = equipped('main') or ''
    local head = equipped('head') or ''
    return { main = p and p.main_job == 'DNC', presto = presto, terpsichore = main:find('^Terpsichore') ~= nil,
             tiara = head:find('Charis Tiara') ~= nil or head:find('Maculele Tiara') ~= nil }
end

-- DNC: finishing moves, 0 up to the most you can hold (9 with the 100 / 1200 JP gifts). The
-- game only says "6+" past 5, so above that the addon counts them (marked ~); hover for how.
function ROWS.fm(lines, counts)
    local C = palette
    data.dnc.max = tonumber(settings.dnc_fm_max) or 9
    local n, est = data.fm_count(counts)
    local max = data.dnc.max
    local col = n >= max and C.accent or n >= 5 and C.good or n > 0 and C.text or C.dim
    local tip = ('%d of %d finishing moves'):format(n, max) ..
        (est and ' (counted by the addon: the game only shows "6+")' or '')
    local num = (est and '~' or '') .. n
    if col_width and col_width < settings.layout.width then
        lines[#lines + 1] = line(nil, { { 'FM:      ', C.label }, { num, col }, { '/' .. max, C.dim }, tip = tip })
        return
    end
    local pips = { { num .. (' '):rep(math.max(1, 4 - #num)), col } }
    pips[#pips + 1] = { ('+'):rep(n), col }
    if max > n then pips[#pips + 1] = { ('-'):rep(max - n), C.dim } end
    pips.tip = tip
    lines[#lines + 1] = line('FM', pips)
end

-- DNC: flourishes still waiting to go off, one line each (none = no line).
--   Climactic: crits on the first swing of the next N rounds (N = finishing moves used, +1 with
--   a Charis / Maculele Tiara); Striking / Ternary: the next swing; Building: the next WS.
function ROWS.flourish(lines, counts)
    local C = palette
    local d = data.dnc
    local function buff(name) local id = data.buff_id(name) return id and counts[id] and id end
    local right = col_width and col_width < settings.layout.width
    local function add(label, text, id, tip)
        local left = id and data.buff_remaining(id)
        local segs = { { text, C.good } }
        if left then segs[#segs + 1] = { ' ' .. fmt_time(left), wearing_color(left, 10) } end
        segs.tip = tip
        if right then table.insert(segs, 1, { label .. (' '):rep(math.max(1, 6 - #label)), C.label }) end
        lines[#lines + 1] = line(not right and label or nil, segs)
    end
    local id = buff('Climactic Flourish')
    if id then
        local c = d.climactic
        add('CLMX', c and (c.left .. '/' .. c.total .. ' rnds') or 'crits', id,
            'Climactic Flourish: critical first swing for ' .. (c and (c.left .. ' more round(s)') or 'your next rounds'))
    else d.climactic = nil end
    id = buff('Striking Flourish')
    if id then add('STRK', 'next swing DA', id, 'Striking Flourish: your next swing is a double attack') end
    id = buff('Ternary Flourish')
    if id then add('TERN', 'next swing TA', id, 'Ternary Flourish: your next swing is a triple attack') end
    id = buff('Building Flourish')
    if id then
        local b = d.building
        add('BLDG', 'next WS' .. (b and (' (' .. b.used .. ' FM)') or ''), id,
            'Building Flourish: boosts your next weapon skill' .. (b and (' (' .. b.used .. ' finishing moves used)') or ''))
    else d.building = nil end
end

-- DNC: dance stance (Saber / Fan / none) with its time, and what it locks you out of.
function ROWS.dance(lines, counts)
    local C = palette
    local function on(name) local id = data.buff_id(name) return id and counts[id] and id end
    local saber, fan = on('Saber Dance'), on('Fan Dance')
    local id = saber or fan
    local name = saber and 'Saber' or fan and 'Fan' or 'None'
    local left = id and data.buff_remaining(id)
    local right = col_width and col_width < settings.layout.width
    -- How strong it is now: Saber Dance's Double Attack fades with time, Fan Dance's damage
    -- reduction with every hit you take. Horos / Etoile gear raises the floor by your merits.
    local merits = tonumber(settings.dnc_dance_merits) or 5
    local pct, what
    if saber then
        local legs = equipped('legs') or ''
        local bonus = (legs:find('Horos Tights') or legs:find('Etoile Tights')) and merits or 0
        pct, what = data.saber_strength(left, bonus), 'Double Attack'
    elseif fan then
        local hands = equipped('hands') or ''
        local bonus = (hands:find('Horos Bangles') or hands:find('Etoile Bangles')) and merits or 0
        pct, what = data.fan_strength(bonus), 'physical damage taken -'
    end
    local segs = { { name, id and C.good or C.dim } }
    if pct then
        local col = pct >= 50 and C.good or pct >= 30 and C.warn or C.bad
        segs[#segs + 1] = { ' ' .. pct .. '%', col }
    end
    if left then segs[#segs + 1] = { ' ' .. fmt_time(left), wearing_color(left, settings.buff_warn) } end
    segs.tip = id and (name .. ' Dance: ' .. (saber and ('Double Attack ' .. pct .. '% (50% at the start, about -1% a second down to its floor)')
            or ('physical damage taken -' .. pct .. '% (90% at the start, -10% per hit you take, down to its floor; ' .. data.dnc.fan_hits .. ' hit(s) so far)'))
        .. (left and ('; ' .. fmt_time(left) .. ' left') or '')
        .. (saber and ' - no Waltzes while it is on' or ' - no Sambas while it is on')) or 'No dance up (Saber Dance / Fan Dance)'
    if right then table.insert(segs, 1, { 'Dance: ', C.label }) end
    lines[#lines + 1] = line(not right and 'DANC' or nil, segs)
    -- Reminder of what it locks out.
    if id and settings.dnc_dance_reminder ~= false then
        lines[#lines + 1] = line(not right and '' or nil, { { right and '       ' or '' }, { saber and 'no Waltz' or 'no Samba', C.warn },
            tip = saber and 'Saber Dance: you can\'t use Waltzes' or 'Fan Dance: you can\'t use Sambas' })
    end
end

-- DNC: the samba up on you (Haste / Drain / Aspir) and its time.
function ROWS.samba(lines, counts)
    local C = palette
    local which, id
    for _, n in ipairs({ 'Haste Samba', 'Drain Samba', 'Aspir Samba' }) do
        local b = data.buff_id(n)
        if b and counts[b] then which, id = n, b break end
    end
    local left = id and data.buff_remaining(id)
    local right = col_width and col_width < settings.layout.width
    local segs = { { which and which:gsub(' Samba', '') or 'None', which and C.good or C.bad } }
    if left then segs[#segs + 1] = { ' ' .. fmt_time(left), wearing_color(left, settings.buff_warn) } end
    segs.tip = which and (which .. (left and (': ' .. fmt_time(left) .. ' left') or ' is up')) or 'No samba up'
    if right then table.insert(segs, 1, { 'Samba: ', C.label }) end
    lines[#lines + 1] = line(not right and 'SMBA' or nil, segs)
end

-- DNC: Daze from Steps on your target: which step, its level and about how long it has left
-- (~: the time is an estimate; the level is what the game reported).
function ROWS.steps(lines)
    local C = palette
    local mob = focus_mob()
    data.dnc.step_jp = tonumber(settings.dnc_step_jp) or 0
    local list = data.mob_daze(mob and mob.id)
    local right = col_width and col_width < settings.layout.width
    local label = right and { 'Step: ', C.label } or nil
    if #list == 0 then
        local segs = { { '--', C.dim }, tip = 'No Daze from Steps on your target' }
        if right then table.insert(segs, 1, label) end
        lines[#lines + 1] = line(not right and 'STEP' or nil, segs)
        return
    end
    for i, e in ipairs(list) do
        -- 'Box     Lv5 1:40' (the time is an estimate: dim, and '~' in the details)
        local segs = { { e.step .. (' '):rep(8 - #e.step), C.accent }, { 'Lv' .. e.level, e.level >= 5 and C.good or C.text },
            { ' ' .. fmt_time(e.left), e.left <= 15 and wearing_color(e.left, 15) or C.dim },
            tip = ('%s Step: %s Daze lv.%d on %s, ~%s left (estimated%s)'):format(e.step, e.name, e.level,
                mob and mob.name or 'your target', fmt_time(e.left), e.mine and '' or '; not your step') }
        if right then table.insert(segs, 1, i == 1 and label or { (' '):rep(6) }) end
        lines[#lines + 1] = line(not right and (i == 1 and 'STEP' or '') or nil, segs)
    end
end

-- SCH: which Arts you're in. Addendum shows as "Light Arts + Addendum" / "Dark Arts + Addendum".
-- Light in the Light colour, Dark in the Dark colour; red "none" when you have neither.
-- Main job or support job is SCH (Arts / Sublimation rows only show then).
local function has_sch() return player.main_job == 'SCH' or player.sub_job == 'SCH' end

-- WHM: which Afflatus you're in.
local stance_seen = {}   -- Afflatus stance and when the addon first saw it
function ROWS.afflatus(lines, counts)
    local C = palette
    local function on(name) local id = data.buff_id(name) return id and counts[id] end
    if col_width and col_width < settings.layout.width then
        -- Right-hand column: one line, which stance you're in.
        local val, tip, which
        if on('Afflatus Solace') then val, tip, which = { 'Solace', C.good }, 'Afflatus Solace is up', 'Afflatus Solace'
        elseif on('Afflatus Misery') then val, tip, which = { 'Misery', C.accent }, 'Afflatus Misery is up', 'Afflatus Misery'
        else val, tip = { 'None', C.bad }, 'No Afflatus stance up' end
        lines[#lines + 1] = line(nil, { { 'Stance: ', C.label }, val, tip = tip })
        -- Under it: time left on the stance, or (if the game gives no timer) how long it's
        -- been up since you switched (as seen by the addon).
        if which then
            if stance_seen.name ~= which then stance_seen = { name = which, at = os.clock() } end
            local left = data.buff_remaining(data.buff_id(which))
            local text = left and (fmt_time(left) .. ' left') or ('up ' .. fmt_time(os.clock() - stance_seen.at))
            lines[#lines + 1] = line(nil, { { '        ' }, { text, left and left <= settings.buff_warn and C.warn or C.dim },
                tip = which .. (left and (': ' .. fmt_time(left) .. ' left') or (': on for ' .. fmt_time(os.clock() - stance_seen.at))) })
        else
            stance_seen = {}
        end
        return
    end
    if on('Afflatus Solace') then
        lines[#lines + 1] = line('AFFL', { { 'Solace', C.good }, tip = 'Afflatus Solace is up' })
    elseif on('Afflatus Misery') then
        lines[#lines + 1] = line('AFFL', { { 'Misery', C.accent }, tip = 'Afflatus Misery is up' })
    else
        lines[#lines + 1] = line('AFFL', { { 'none', C.bad }, tip = 'No Afflatus stance up' })
    end
end

function ROWS.arts(lines, counts)
    local C, EC = palette, element_colors()
    if not has_sch() then return end
    local function on(name) local id = data.buff_id(name) return id and counts[id] end
    local text, col
    if on('Addendum: White') then text, col = 'Light Arts + Addendum', EC.Light
    elseif on('Addendum: Black') then text, col = 'Dark Arts + Addendum', EC.Dark
    elseif on('Light Arts') then text, col = 'Light Arts', EC.Light
    elseif on('Dark Arts') then text, col = 'Dark Arts', EC.Dark end
    lines[#lines + 1] = line('ARTS', { text and { text, col } or { 'none', C.bad },
        tip = text and ('In ' .. text) or 'Not in Light Arts or Dark Arts' })
end

-- SCH: the storm on you (Storm II included), in its element's colour, with time left.
local STORMS = { Firestorm = 'Fire', Hailstorm = 'Ice', Windstorm = 'Wind', Sandstorm = 'Earth',
                 Thunderstorm = 'Thunder', Rainstorm = 'Water', Aurorastorm = 'Light', Voidstorm = 'Dark' }
function ROWS.storm(lines, counts)
    local C, EC = palette, element_colors()
    -- Right-hand column (e.g. WHM/SCH): 'Storm:  Aurorastorm' or 'None'; only with SCH main or sub.
    if col_width and col_width < settings.layout.width then
        if not has_sch() then return end
        for name, el in pairs(STORMS) do
            for _, id in ipairs(data.buff_ids(name)) do
                if counts[id] then
                    local tier = id >= 589 and ' II' or ''
                    local left = data.buff_remaining(id)
                    lines[#lines + 1] = line(nil, { { 'Storm:  ', C.label }, { name .. tier, EC[el] },
                        tip = name .. tier .. ' (' .. el .. ')' .. (left and (': ' .. fmt_time(left) .. ' left') or '') })
                    return
                end
            end
        end
        lines[#lines + 1] = line(nil, { { 'Storm:  ', C.label }, { 'None', C.bad }, tip = 'No storm on you' })
        return
    end
    for name, el in pairs(STORMS) do
        for _, id in ipairs(data.buff_ids(name)) do
            if counts[id] then
                local tier = id >= 589 and ' II' or ''          -- Storm II buffs are 589-596
                local left = data.buff_remaining(id)
                local segs = { { name .. tier, EC[el] } }
                if left then
                    segs[#segs + 1] = { '  ' .. fmt_time(left), left <= settings.upkeep_warn and wearing_color(left, settings.upkeep_warn) or C.dim }
                end
                segs.tip = name .. tier .. ' (' .. el .. ')' .. (left and (': ' .. fmt_time(left) .. ' left') or '')
                lines[#lines + 1] = line('STRM', segs)
                return
            end
        end
    end
    lines[#lines + 1] = line('STRM', { { '--', C.dim }, tip = 'No storm on you' })
end

-- SCH: Klimaform on (green, time left) or off.
function ROWS.klimaform(lines, counts)
    local C = palette
    local id = data.buff_id('Klimaform')
    if id and counts[id] then
        local left = data.buff_remaining(id)
        lines[#lines + 1] = line('KLIM', { { left and fmt_time(left) or 'On',
            left and wearing_color(left, settings.upkeep_warn) or C.good },
            tip = 'Klimaform' .. (left and (': ' .. fmt_time(left) .. ' left') or ' is on') })
    else
        lines[#lines + 1] = line('KLIM', { { '--', C.dim }, tip = 'Klimaform is off' })
    end
end

-- SCH: Sublimation. Complete (green: ready to use the stored MP), Charging (yellow), or the
-- ability's own recast when it isn't running: Ready (green) or time left.
function ROWS.sublimation(lines, counts)
    local C = palette
    if not has_sch() then return end
    local complete, active = data.buff_id('Sublimation: Complete'), data.buff_id('Sublimation: Activated')
    local on_c, on_a = complete and counts[complete], active and counts[active]
    if on_c or on_a then
        local t = subl or { start = os.clock(), stored = 0 }
        local since = fmt_time(os.clock() - t.start) .. (t.known and '' or '+')
        local mp = math.floor(t.stored)
        local tip = (on_c and 'Sublimation: Complete - use Sublimation again to get the MP back'
            or 'Sublimation: Activated - turning HP into MP')
            .. ('. Started %s ago; about %d MP stored'):format(since, mp)
            .. (t.known and '' or ' (since the addon loaded)')
            .. ((t.bonus or 0) > 0 and (', Sublimation gear +' .. t.bonus) or '')
        lines[#lines + 1] = line('SUBL', {
            { on_c and 'Complete' or 'Charging', on_c and C.good or C.upkeep_warn },
            { ' ' .. since, C.dim },
            { (t.known and ' ~%d MP' or ' %d+ MP'):format(mp), on_c and C.good or C.text },
            tip = tip })
    else
        local r = data.resolve('Sublimation')
        local rec = r and (windower.ffxi.get_ability_recasts() or {})[r.recast_id] or 0
        if rec > 0 then
            lines[#lines + 1] = line('SUBL', { { fmt_time(rec), C.dim }, tip = 'Sublimation: recast ' .. fmt_time(rec) })
        else
            lines[#lines + 1] = line('SUBL', { { 'Ready', C.good }, tip = 'Sublimation is ready to start' })
        end
    end
end

function ROWS.inventory(lines)
    local C = palette
    local ok, info = pcall(windower.ffxi.get_bag_info, 0)
    if not ok or not info then
        local inv = windower.ffxi.get_items('inventory')
        info = inv and { count = inv.count, max = inv.max }
    end
    if not info or not info.max then return end
    local free = info.max - info.count
    local col = free <= 0 and C.bad or free <= 5 and C.warn or C.text
    lines[#lines + 1] = line('INV', { { ('%d/%d'):format(info.count, info.max), col } })
end

function ROWS.timers(lines)
    local C = palette
    local now = os.time()
    local keep = {}
    for _, key in ipairs(timer_order) do
        local t = timers[key]
        local left = t.ends - now
        if left > -10 then
            keep[#keep + 1] = key
            local value, col
            if left <= 0 then value, col = 'DONE', C.good
            else value, col = fmt_time(left), left <= settings.buff_warn and C.warn or C.text end
            local k = #key >= LABEL_W and (key .. ' ') or pad(key, LABEL_W)
            lines[#lines + 1] = line(nil, { { k, C.label }, { value, col } })
            if left <= 0 and not t.told then
                t.told = true
                msg('Timer done: ' .. key)
            end
        else
            timers[key] = nil
        end
    end
    timer_order = keep
end

local function commas(n)
    local s = tostring(math.floor(n))
    while true do
        local r, k = s:gsub('^(%d+)(%d%d%d)', '%1,%2')
        s = r
        if k == 0 then return s end
    end
end

-- Last weapon skill: name, damage indented under it, then the skillchain line. Always three
-- lines (with "--" for anything not known yet), so the panel doesn't shift when a skillchain
-- closes or you haven't weapon skilled yet.
-- RNG: Hover Shot stacks (counted from your shots) and whether you've moved since the last
-- shot (you need to, at least 1 yalm, for the next shot to add a stack).
function ROWS.hover(lines, counts)
    local C = palette
    -- In the right-hand column it's written like Window / Hate; on the left with a label.
    local right = col_width and col_width < settings.layout.width
    local label = not right and 'HOVR' or nil
    local lead = right and { 'Hover   ', C.label } or { '' }
    local id = data.buff_id('Hover Shot')
    if not (id and counts[id]) then
        data.hover.stacks, data.hover.target = 0, nil
        local r = data.resolve('Hover Shot')
        local rec = r and (windower.ffxi.get_ability_recasts() or {})[r.recast_id] or 0
        lines[#lines + 1] = line(label, { lead, { 'off', C.bad }, { rec > 0 and ('  ' .. fmt_time(rec)) or '  ready', C.dim },
            tip = 'Hover Shot is not on you' })
        if right then ROWS.velocity(lines, counts) ROWS.bounty(lines) end
        return
    end
    local h = data.hover
    local n = h.stacks or 0
    local me = windower.ffxi.get_mob_by_target('me')
    local moved = data.hover_moved(me and me.x and { x = me.x, y = me.y } or nil)
    local mv
    if moved == nil then mv = { right and '--' or 'shoot to start', C.dim }
    elseif moved then mv = { 'moved', C.good }
    else mv = { 'move!', C.upkeep_warn } end
    lines[#lines + 1] = line(label, { lead, { ('%d/%d'):format(n, data.HOVER_MAX), n >= data.HOVER_MAX and C.good or C.text },
        { right and ' ' or '  ' }, mv,
        tip = ('Hover Shot: %d stacks (+%d%% ranged damage, +%d ranged / magic accuracy). %s'):format(n, n * 4, n * 4,
            moved == nil and 'Your next shot sets the starting spot.'
            or moved and 'You have moved since your last shot: the next one adds a stack.'
            or 'Move at least 1 yalm before your next shot to add a stack.') })
    -- On the right, Bounty always comes straight under Hover.
    if right then ROWS.velocity(lines, counts) ROWS.bounty(lines) end
end

-- COR: after a bust, a line at the very bottom of the column while Bust is on you.
function ROWS.showbiz(lines, counts)
    local bust = data.buff_id('Bust')
    if not (bust and counts[bust]) then return end
    local fit = display.layout()
    local total = fit and fit.lines or (#lines + 1)
    while #lines < total - 1 do lines[#lines + 1] = line(nil, {}) end
    for i = #lines, total, -1 do lines[i] = nil end   -- full column: it takes the last line
    local used = #lines   -- last line with something on it, above the padding
    while used > 0 and lines[used].s == '' do used = used - 1 end
    local left = data.buff_remaining(bust)
    -- The animation plays in the empty lines above the text (when 2 or more are empty).
    local room = math.min(total - 1 - used, 5)
    if settings.showbiz_gif ~= false and room >= 2 then showbiz_gif = { line = total, lines = room } end
    lines[#lines + 1] = line(nil, { { "That's showbiz, baby!", palette.bad },
        tip = 'Busted' .. (left and (': ' .. fmt_time(left) .. ' left') or '') .. ' (Fold clears it)' })
end

function ROWS.ws(lines)
    local C = palette
    local w = data.last_ws
    local indent = { (' '):rep(LABEL_W + 2), C.text }
    if not w then
        lines[#lines + 1] = line('WS', { { '--', C.dim } })
        if not compact.ws then lines[#lines + 1] = line(nil, { indent, { '--', C.dim } }) end
        lines[#lines + 1] = line('SC', { { '--', C.dim } })
        return
    end
    -- TP you had right after it (what it gave back): the first TP reading that differs from what
    -- you had going in, or whatever it is 1.5 s later.
    if w.tp_after == nil and w.at then
        local p = windower.ffxi.get_player()
        local tp = p and p.vitals and p.vitals.tp
        local age = os.clock() - w.at
        if tp and (tp ~= w.tp or age > 1.5) and age < 5 then w.tp_after = tp end
    end
    -- Red when it healed the mob instead of hurting it (the mob absorbs that element).
    local tip = w.healed and (w.name .. ' healed the mob (it absorbs that element)') or nil
    local dmg = w.healed and { commas(w.damage or 0) .. ' healed', C.bad }
        or w.damage and { commas(w.damage), C.good } or { 'Miss', C.bad }
    local tps = w.tp_after and { { '  TP ', C.label }, { tostring(w.tp_after), w.tp_after >= 1000 and C.good or C.text } } or {}
    local tp_tip = w.tp_after and ('TP after ' .. w.name .. ': ' .. w.tp_after .. (w.tp and (' (used ' .. w.tp .. ')') or '')) or nil
    if compact.ws then
        -- Short on room: damage on the same line, after the name.
        local segs = { { w.name .. '  ', w.healed and C.bad or C.text }, dmg, tip = tip or tp_tip }
        for _, sg in ipairs(tps) do segs[#segs + 1] = sg end
        lines[#lines + 1] = line('WS', segs)
    else
        lines[#lines + 1] = line('WS', { { w.name, w.healed and C.bad or C.text }, tip = tip })
        local segs = { indent, dmg, tip = tp_tip }
        for _, sg in ipairs(tps) do segs[#segs + 1] = sg end
        lines[#lines + 1] = line(nil, segs)
    end
    if w.sc and w.sc_healed then
        lines[#lines + 1] = line('SC', { { w.sc, C.bad }, { '  ' .. commas(w.sc_damage or 0) .. ' healed', C.bad },
            tip = 'Skillchain ' .. w.sc .. ' healed the mob (it absorbs that element)' })
    elseif w.sc then
        lines[#lines + 1] = line('SC', { { w.sc, C.accent }, { '  ' .. commas(w.sc_damage or 0), C.good } })
    else
        lines[#lines + 1] = line('SC', { { '--', C.dim } })
    end
end


-- BRD: the songs you've sung on your target (newest first): 'Song:  Foe Requiem VII'.
function ROWS.foesong(lines)
    local C = palette
    local mob = focus_mob()
    local label = { 'Song: ', C.label }
    local list = {}
    for status, e in pairs((mob and data.mob_songs[mob.id]) or {}) do list[#list + 1] = e end
    table.sort(list, function(a, b) return a.at > b.at end)
    if #list == 0 then
        lines[#lines + 1] = line(nil, { label, { '--', C.dim }, tip = 'None of your songs on your target' })
        return
    end
    for i, e in ipairs(list) do
        if i > 2 then break end
        -- ('Foe ' dropped to fit: Requiem VII, Lullaby II)
        lines[#lines + 1] = line(nil, { i == 1 and label or { (' '):rep(6) }, { (e.name:gsub('^Foe ', '')), C.accent },
            tip = e.name .. ' on ' .. (mob.name or 'your target') .. ' (' .. fmt_time(os.clock() - e.at) .. ' ago)' })
    end
end

-- DRG: the wyvern's HP in numbers (its max is learned from the damage it takes; '~' until
-- then, or set wyvern_hp in the settings), and whether Steady Wing is up on it.
function ROWS.wyvern(lines)
    local C = palette
    local pet = windower.ffxi.get_mob_by_target('pet')
    local w = data.wyvern
    -- The Steady Wing line is always there (Off with its recast when there's no wyvern).
    local function steady_off()
        local r = data.resolve('Steady Wing')
        local rec = r and (windower.ffxi.get_ability_recasts() or {})[r.recast_id] or 0
        lines[#lines + 1] = line(nil, { { 'Steady  ', C.label }, { 'Off', C.bad },
            { rec > 0 and ('  ' .. fmt_time(rec)) or '  ready', C.dim },
            tip = 'Steady Wing is not on your wyvern' .. (rec > 0 and (' (recast ' .. fmt_time(rec) .. ')') or '') })
    end
    if not pet then
        lines[#lines + 1] = line(nil, { { 'Wyvern  ', C.label }, { 'none', C.dim } })
        steady_off()
        return
    end
    local hpp = data.wyvern_hpp(pet.hpp or 100)
    local max = tonumber(job_cfg().wyvern_hp) or w.max
    local hcol = hpp < 25 and C.bad or hpp < 50 and C.warn or hpp < 75 and C.upkeep_warn or C.good
    -- Time for Spirit Link: its HP is under the job's pet alarm (petalarm, 40% on DRG) and
    -- Spirit Link is ready -> the HP blinks.
    local link = data.resolve('Spirit Link')
    local link_ready = link and learned_ja[link.id] and ((windower.ffxi.get_ability_recasts() or {})[link.recast_id] or 0) <= 0
    local use_link = link_ready and pet_alarm()
    if use_link and math.floor(os.clock() / 0.6) % 2 == 1 then hcol = C.dim end
    local seg
    if max then
        seg = { ('%s/%s'):format(commas(math.floor(max * hpp / 100 + 0.5)), commas(max)), hcol }
    else
        seg = { hpp .. '%', hcol }
    end
    lines[#lines + 1] = line(nil, { { 'Wyvern  ', C.label }, seg,
        tip = (use_link and 'Use Spirit Link! ' or '') .. 'Wyvern HP ' .. hpp .. '%' .. (max and ('; max about ' .. commas(max) .. (job_cfg().wyvern_hp and ' (set)' or #w.samples > 0 and (' (learned from ' .. #w.samples .. ' hits)') or ' (saved for this character)')) or '; max HP not known yet: learned from the damage it takes') })
    local st = w.steady
    if st then
        -- Total HP it can take now: its HP plus what's left of the shield (1.3 x max HP - HP
        -- when used). Coloured by the time left on Steady Wing (blinks in its last 30 s).
        local left = st.at + data.STEADY_TIME - os.clock()
        local hp = max and math.floor(max * hpp / 100 + 0.5)
        local absorb = max and math.max(0, math.floor(1.3 * max - max * st.hpp / 100)) or st.absorb
        local shield = st.spent and 0 or absorb
        local segs = { { 'Steady  ', C.label } }
        if hp and shield then
            segs[#segs + 1] = { '~' .. commas(hp + shield), wearing_color(left, 30) }
            segs[#segs + 1] = { st.spent and ' (used)' or ' total', C.dim }
        else
            segs[#segs + 1] = { fmt_time(left), wearing_color(left, 30) }   -- (max HP not known yet)
        end
        segs.tip = 'Steady Wing: ' .. fmt_time(left) .. ' left'
            .. (shield and (st.spent and '; the shield is used up' or ('; shield about ' .. commas(shield) .. ' (1.3 x max HP - its HP when used)')) or '')
            .. (hp and shield and ('; HP ' .. commas(hp) .. ' + shield = about ' .. commas(hp + shield) .. ' total') or '')
        lines[#lines + 1] = line(nil, segs)
    else
        steady_off()
    end
end

-- NIN: Migawari on or off.
function ROWS.migawari(lines, counts)
    local C = palette
    local id = data.buff_id('Migawari')
    local on = id and counts[id]
    local left = on and data.buff_remaining(id)
    -- On with its time left (blinks when ending, like your other buffs), or Off.
    local segs = { { 'Migawari: ', C.label }, { on and 'On' or 'Off', on and C.good or C.bad },
        tip = 'Migawari ' .. (on and ('is up' .. (left and (': ' .. fmt_time(left) .. ' left') or '')) or 'is off') }
    if left then segs[#segs + 1] = { ' ' .. fmt_time(left), wearing_color(left, settings.buff_warn) } end
    lines[#lines + 1] = line(nil, segs)
    -- Under it: your stance, Yonin / Innin / None.
    local function has(n) local b = data.buff_id(n) return b and counts[b] end
    local st, col = 'None', C.bad
    if has('Yonin') then st, col = 'Yonin', C.good elseif has('Innin') then st, col = 'Innin', C.accent end
    lines[#lines + 1] = line(nil, { { 'Stance:   ', C.label }, { st, col }, tip = st == 'None' and 'No Yonin / Innin' or (st .. ' is up') })
end

-- RNG: has your target been hit with Bounty Shot (by anyone)?
function ROWS.bounty(lines)
    local C = palette
    if bounty_shown then return end   -- already drawn under Hover
    bounty_shown = true
    local mob = focus_mob()
    local label = { 'Bounty  ', C.label }
    if not (mob and mob.is_npc) then
        lines[#lines + 1] = line(nil, { label, { '--', C.dim } })
        return
    end
    local yes = data.bounty[mob.id]
    lines[#lines + 1] = line(nil, { label, { yes and 'Yes' or 'No', yes and C.good or C.bad },
        tip = (mob.name or 'Target') .. (yes and ' has been hit with Bounty Shot' or ' has not been hit with Bounty Shot yet') })
end

-- Skillchain window on your target: 'wait' until it opens, then a countdown to when it
-- closes (yellow for the last 2 s). Driven by anyone's weapon skills on that mob.
function ROWS.window(lines)
    local C = palette
    local mob = focus_mob()
    local w = mob and data.windows[mob.id]
    local now = os.clock()
    local label = { 'Window  ', C.label }
    if not w or now > w.close or (mob.hpp or 0) <= 0 then
        lines[#lines + 1] = line(nil, { label, { '--', C.dim } })
    elseif w.closed then
        lines[#lines + 1] = line(nil, { label, { 'closed', C.dim } })
    elseif w.open - now >= 0.05 then   -- (not 'wait 0.0' in the instant it opens)
        lines[#lines + 1] = line(nil, { label, { ('wait %.1f'):format(w.open - now), C.bad } })
    else
        local left = w.close - now
        lines[#lines + 1] = line(nil, { label, { ('%.1fs'):format(left), left <= 2 and C.upkeep_warn or C.good } })
    end
end

-- Magic burst window: from the moment a skillchain lands on your target until its window
-- closes, with the elements that burst. Two lines, always, so nothing below it moves. Set apart
-- from the Window line by colour: the label is in the accent colour and the time in cyan.
function ROWS.burst(lines)
    local C = palette
    local mob = focus_mob()
    local w = mob and data.windows[mob.id]
    local now = os.clock()
    local label = { 'Burst   ', C.accent }
    local indent = { '   ', C.text }
    if not (w and w.sc) or now > w.close or (mob.hpp or 0) <= 0 then
        lines[#lines + 1] = line(nil, { label, { '--', C.dim } })
        lines[#lines + 1] = line(nil, { indent })
        return
    end
    local left = w.close - now
    local time = ('%.1fs'):format(left)
    local segs1 = { label, { time, left <= 2 and C.upkeep_warn or C.active } }
    -- The skillchain's name too, when it fits whole (Light, Darkness, Fusion...).
    if #label[1] + #time + 2 + #w.sc <= (col_width or settings.layout.width) then
        segs1[#segs1 + 1] = { '  ' .. w.sc, C.dim }
    end
    lines[#lines + 1] = line(nil, segs1)
    local els = data.BURST_ELEMENTS[w.sc] or {}
    -- Full element names if they fit the column, 4-letter ones if not (Light / Darkness).
    local SHORT = { Earth = 'Erth', Thunder = 'Thun', Water = 'Watr', Light = 'Lght' }
    local full = #indent[1] + #table.concat(els, ' ')
    local segs = { indent }
    for i, el in ipairs(els) do
        local shown = full > (col_width or settings.layout.width) and (SHORT[el] or el) or el
        segs[#segs + 1] = { (i > 1 and ' ' or '') .. shown, element_colors()[el] or C.text }
    end
    lines[#lines + 1] = line(nil, segs)
end

-- Who your target is attacking: You (green), your pet (yellow), anyone else (red).
function ROWS.aggro(lines)
    local C = palette
    local mob = focus_mob()
    local label = { 'Hate    ', C.label }
    if not (mob and mob.is_npc and (mob.hpp or 0) > 0) then
        lines[#lines + 1] = line(nil, { label, { '--', C.dim } })
        return
    end
    local who
    if mob.target_index and mob.target_index > 0 then who = windower.ffxi.get_mob_by_index(mob.target_index) end
    if not who and data.last_target[mob.id] then who = windower.ffxi.get_mob_by_id(data.last_target[mob.id]) end
    local pet = windower.ffxi.get_mob_by_target('pet')
    if not who then
        lines[#lines + 1] = line(nil, { label, { '--', C.dim } })
    elseif who.id == player.id then
        lines[#lines + 1] = line(nil, { label, { 'You', C.good } })
    elseif pet and who.id == pet.id then
        local tank = data.split(job_cfg().pet_info)
        local pet_tanks = false
        for _, k in ipairs(tank) do if k:lower() == 'hate' then pet_tanks = true end end
        lines[#lines + 1] = line(nil, { label, { 'Pet', pet_tanks and C.good or C.upkeep_warn } })
    else
        lines[#lines + 1] = line(nil, { label, { who.name or '?', C.bad } })
    end
end

-- Your debuffs on the target, with time left. Until the addon has seen one wear off on its own
-- the time is an estimate from the base duration (shown with ~); after that it uses your real
-- duration. '--' = not on the target.
-- Give every line a row draws a whole-line hover text (more specific hovers on parts of the
-- line still win).
local function tipped(fn, tipf)
    return function(lines, counts)
        local n0 = #lines
        fn(lines, counts)
        local tip = tipf()
        if not tip then return end
        for i = n0 + 1, #lines do
            local l = lines[i]
            l.hovers = l.hovers or {}
            l.hovers[#l.hovers + 1] = { 0, l.n, tip }
        end
    end
end

ROWS.window = tipped(ROWS.window, function()
    return 'Skillchain window on your target: opens 3s after a weapon skill lands, closes 10s after it'
        .. ' (1s shorter each skillchain step)'
end)
ROWS.burst = tipped(ROWS.burst, function()
    local mob = focus_mob()
    local w = mob and data.windows[mob.id]
    if w and w.sc and os.clock() <= w.close then
        return 'Magic burst: ' .. w.sc .. ' -> ' .. table.concat(data.BURST_ELEMENTS[w.sc] or {}, ', ')
    end
    return 'Magic burst window: counts down after a skillchain lands on your target'
end)
ROWS.aggro = tipped(ROWS.aggro, function()
    local mob = focus_mob()
    return 'Who ' .. (mob and mob.name or 'your target') .. ' is attacking'
end)

-- Items an ability uses up, counted across inventory and wardrobes (the equipped stack is in
-- one of those bags). Rescanned at most every 2 seconds.
local ITEM_FOR = { Angon = 'Angon', Tomahawk = 'Thr. Tomahawk' }
local ITEM_LOW = 3
local item_counts, items_at, item_ids = {}, -1, nil
local BAGS = { 0, 8, 10, 11, 12, 13, 14, 15, 16 }
local function item_count(ability)
    local item = ITEM_FOR[ability]
    if not item then return nil end
    local now = os.clock()
    if now - items_at > 2 then
        items_at = now
        item_counts = {}
        if not item_ids then
            item_ids = {}
            for _, n in pairs(ITEM_FOR) do
                local id = data.item_id(n)
                if id then item_ids[id] = n end
            end
        end
        local want = item_ids
        for _, bag in ipairs(BAGS) do
            local ok, t = pcall(windower.ffxi.get_items, bag)
            if ok and type(t) == 'table' then
                for k = 1, (tonumber(t.max) or 80) do
                    local it = t[k]
                    if type(it) == 'table' and want[it.id] then
                        item_counts[want[it.id]] = (item_counts[want[it.id]] or 0) + (it.count or 1)
                    end
                end
            end
        end
    end
    return item_counts[item] or 0
end

-- Your debuffs on the target, with time left. Angon and Tomahawk also show how many of their
-- item you have, as (#), red at 3 or fewer.
function ROWS.debuffs(lines)
    local C = palette
    local names = data.split(job_cfg().debuffs)
    if #names == 0 then return end
    local mob = focus_mob()
    local list = mob and data.debuffs[mob.id] or {}
    local now = os.clock()
    for _, name in ipairs(names) do
        local e = list[name]
        local learned = data.debuff_learned[name]
        local dur = learned or data.debuff_base(name) or 30
        local count = item_count(name)
        local segs = { { name, e and C.text or C.dim } }
        local used = #name
        if count then
            local txt = ' (' .. count .. ')'
            segs[#segs + 1] = { txt, count <= ITEM_LOW and C.bad or C.dim,
                                ('%d %s left (inventory + wardrobes)'):format(count, ITEM_FOR[name]) }
            used = used + #txt
        end
        segs[#segs + 1] = { (' '):rep(math.max(1, 14 - used)), C.text }
        local tip
        if e then
            local left = dur - (now - e.start)
            local how = learned and ('lasts ' .. fmt_time(learned) .. ' for you')
                or ('~' .. fmt_time(dur) .. ' estimate until it has worn off once on its own')
            if left > 0 then
                local col = left <= settings.upkeep_warn and C.upkeep_warn or C.good
                segs[#segs + 1] = { (learned and '' or '~') .. fmt_time(left), col }
                tip = ('%s on %s: %s left (%s)'):format(name, mob and mob.name or 'target', fmt_time(left), how)
            else
                segs[#segs + 1] = { 'on', C.good }   -- past the estimate, not worn off yet
                tip = ('%s on %s: past the estimate, not worn off yet'):format(name, mob and mob.name or 'target')
            end
        else
            segs[#segs + 1] = { '--', C.dim }
            tip = name .. ': not on your target'
        end
        segs.tip = tip
        lines[#lines + 1] = line(nil, segs)
    end
end

function ROWS.notes(lines)
    local C = palette
    for _, key in ipairs(note_order) do
        local k = #key >= LABEL_W and (key .. ' ') or pad(key, LABEL_W)
        lines[#lines + 1] = line(nil, { { k, C.label }, { notes[key], C.accent } })
    end
end

local ROW_NAMES = { 'weapon', 'sub', 'ranged', 'ammo', 'tp', 'hp', 'mp', 'pet', 'target', 'buffs',
    'runes', 'rolls', 'shadows', 'maneuvers', 'fm', 'arts', 'inventory', 'timers', 'notes',
    'vitals', 'upkeep', 'ws', 'window', 'debuffs', 'burst', 'aggro', 'party',
    'storm', 'klimaform', 'sublimation', 'afflatus', 'hover', 'velocity', 'bounty', 'showbiz', 'foesong', 'wyvern', 'migawari',
    'flourish', 'dance', 'samba', 'steps' }

------------------------------------------------------------------------------------------
-- Header
------------------------------------------------------------------------------------------

local INDICATORS = {
    engaged = { label = 'ENG' }, ws = { label = 'WS' }, pet = { label = 'PET' },
    food = { label = 'FOOD', buffs = { 'Food' }, missing_bad = true },
    reraise = { label = 'RR', buffs = { 'Reraise' }, missing_bad = true },
    signet = { label = 'SIG', buffs = { 'Signet', 'Sanction', 'Sigil', 'Ionis' } },
    sneak = { label = 'SNK', buffs = { 'Sneak' }, missing_bad = true },
    invis = { label = 'INVIS', buffs = { 'Invisible' }, missing_bad = true },
    sync = { label = 'SYNC', buffs = { 'Level Restriction' } },
}

-- Effects that stop you weapon skilling (Amnesia is handled on its own).
-- sleep, petrification, stun, charm, sleep, terror, impairment
local WS_BLOCKERS = { 2, 7, 10, 14, 17, 19, 28, 261 }
local AMNESIA = 16

-- WS square: yellow = Amnesia, red = can't WS (under 1000 TP, or slept/stunned/etc.),
-- blue = 2000+ TP, green = can WS.
local function ws_color(counts)
    local C = palette
    if counts[AMNESIA] then return C.ind_warn end
    for _, id in ipairs(WS_BLOCKERS) do
        if counts[id] then return C.ind_bad end
    end
    local tp = player.vitals.tp or 0
    if tp < 1000 then return C.ind_bad end
    if tp >= 2000 then return C.ind_high end
    return C.ind_on
end

local function build_header(counts)
    local C = palette
    local job = player.main_job .. player.main_job_level
    local ml = data.master_level or 0
    if ml > 0 and (player.main_job_level or 0) >= 99 then job = job .. ' ML' .. ml end
    if player.sub_job and player.sub_job_level and player.sub_job_level > 0 then
        job = job .. '/' .. player.sub_job .. sub_level()
    end
    local inds = {}
    local keys = {}
    for _, key in ipairs(data.split(settings.header)) do keys[#keys + 1] = key:lower() end
    -- Compact mode: no PET / SIG / SYNC, and SNK and INVIS always there (kept when the strip
    -- is too short for everything).
    local compact_keep = settings.compact_mode and { sneak = true, invis = true } or {}
    if settings.compact_mode then
        local out = {}
        for _, k in ipairs(keys) do if k ~= 'pet' and k ~= 'signet' and k ~= 'sync' then out[#out + 1] = k end end
        for _, k in ipairs({ 'sneak', 'invis' }) do
            if not table.contains(out, k) then out[#out + 1] = k end
        end
        keys = out
    end
    for _, key in ipairs(keys) do
        local def = INDICATORS[key]
        if def then
            local on, color, left
            if key == 'engaged' then on = player.status == 1
            elseif key == 'ws' then color = ws_color(counts)
            elseif key == 'pet' then on = windower.ffxi.get_mob_by_target('pet') ~= nil
            else
                for _, b in ipairs(def.buffs) do
                    for _, id in ipairs(data.buff_ids(b)) do
                        if counts[id] then
                            on = true
                            local l = data.buff_remaining(id)
                            if l and (not left or l > left) then left = l end
                        end
                    end
                end
            end
            -- Food and Reraise turn orange in their last 5 minutes.
            if on and def.missing_bad and left and left < 300 then
                color = { alpha = 255, red = C.soon.red, green = C.soon.green, blue = C.soon.blue }
            end
            local tip
            if key == 'ws' then
                local tp = player.vitals.tp or 0
                tip = ('WS: TP %d. Green = can weapon skill, blue = 2000+, yellow = Amnesia, red = can\'t'):format(tp)
            elseif key == 'engaged' then
                tip = 'Engaged: ' .. (on and 'yes' or 'no')
            elseif key == 'pet' then
                local pet = windower.ffxi.get_mob_by_target('pet')
                tip = 'Pet: ' .. (pet and pet.name or 'none')
            else
                local what = def.tip or def.buffs[1]
                tip = what .. ': ' .. (on and (left and (fmt_time(left) .. ' left') or 'on') or 'off')
                if def.missing_bad then tip = tip .. ' (orange under 5 minutes, red when off)' end
            end
            inds[#inds + 1] = { label = cs(C.label, def.label), chars = #def.label, tip = tip, keep = compact_keep[key],
                                color = color or (on and C.ind_on or (def.missing_bad and C.ind_bad or C.ind_off)) }
        end
    end
    return cs(C.text, job), #job, inds
end

------------------------------------------------------------------------------------------
-- Tick
------------------------------------------------------------------------------------------

local function should_show()
    if not settings.visible or zoning then return false end
    if not windower.ffxi.get_mob_by_target('me') then return false end
    if settings.hide_in_cutscene and player.status == 4 then return false end
    return true
end

-- At most n cells. If there are more, the last one says how many didn't fit, and turns
-- orange/green if any of the hidden ones is soon/ready.
-- The standard left-side order, applied whatever order a job's row list is in:
--   1. gear, vitals and pet (weapon, sub, ranged, ammo, vitals, tp, hp, mp, pet), as listed
--   2. target
--   3. upkeep (the buff tags) directly under the target
--   4. the last weapon skill and skillchain (ws), so it's never pushed off the bottom
--   5. everything else (runes, buff timers, rolls, timers, notes...), as listed
local TOP_ROWS = { weapon = true, sub = true, ranged = true, ammo = true, vitals = true,
                   tp = true, hp = true, mp = true, pet = true }

ordered_rows = function(list)
    local top, rest, target, upkeep, ws = {}, {}, nil, nil, nil
    for _, r in ipairs(data.split(list)) do
        local k = r:lower()
        if k == 'target' then target = r
        elseif k == 'upkeep' then upkeep = r
        elseif k == 'ws' then ws = r
        elseif TOP_ROWS[k] then top[#top + 1] = r
        else rest[#rest + 1] = r end
    end
    if target then top[#top + 1] = target end
    if upkeep then top[#top + 1] = upkeep end
    if ws then top[#top + 1] = ws end
    for _, r in ipairs(rest) do top[#top + 1] = r end
    return top
end

local function fit_cells(cells, n)
    if #cells <= n then return cells end
    if n <= 0 then return {} end
    local C = palette
    local hidden = #cells - n + 1
    local col = C.unavailable
    for i = n, #cells do
        if cells[i].color == C.ready then col = C.ready break end
        if cells[i].color == C.soon then col = C.soon end
    end
    local out = {}
    for i = 1, n - 1 do out[i] = cells[i] end
    out[n] = { label = '+' .. hidden, value = 'more', color = col, label_color = C.text, value_color = C.dim }
    return out
end

-- Party window: you and each party member, with the buffs YOU can put on them (spells and
-- abilities that can target a party member and give a status) - green on, red missing.
local PW_ORDER = { 'Haste', 'Flurry', 'Refresh', 'Phalanx', 'Protect', 'Shell', 'Regen' }
local PW_TAGS = { haste = 'HSTE', flurry = 'FLRY', refresh = 'RFSH', phalanx = 'PHLX', protect = 'PROT',
                  shell = 'SHEL', regen = 'RGN', stoneskin = 'STSK', blink = 'BLNK', aquaveil = 'AQVL',
                  reraise = 'RR', embrava = 'EMBR', adloquium = 'ADLO', regain = 'RGAN', ['animus augeo'] = 'AUGE',
                  ['animus minuo'] = 'MINU' }
local pw_cache = {}
-- Can it be cast on a party member? In game the resources give targets as a set of names
-- ({ Self = true, Party = true, ... }); some resource dumps give a bit mask (4 = party).
local function targets_party(t)
    if type(t) == 'table' then
        if t.Party or t.Ally then return true end
        for _, v in pairs(t) do if v == 'Party' or v == 'Ally' then return true end end
        return false
    end
    if type(t) == 'number' then return math.floor(t / 4) % 2 == 1 or math.floor(t / 8) % 2 == 1 end
    return false
end
-- Groups of buffs that can be named together in the rules ('Storms' = all eight storms).
local PW_GROUPS = { storms = { firestorm = true, hailstorm = true, windstorm = true, sandstorm = true,
                               thunderstorm = true, rainstorm = true, aurorastorm = true, voidstorm = true } }
local function pw_group(buff)
    for g, set in pairs(PW_GROUPS) do if set[buff:lower()] then return g end end
end

local function castable_buffs()
    local key = job_key .. ':' .. tostring(learned_at)
    if pw_cache.key == key then return pw_cache.list end
    local skip = {}
    for _, n in ipairs(data.split(settings.party_window_skip or '')) do skip[n:lower()] = true end
    local by_name, list = {}, {}
    local function consider(e)
        if not e.status or not targets_party(e.targets) then return end
        local name = data.buff_name(e.status)
        if not name or skip[name:lower()] then return end
        if not available(e) then return end
        -- The strongest tier you can cast of each buff (Protect V, Haste II...).
        local tier = e.kind == 'spell' and data.spell_tier(res.spells[e.id] and res.spells[e.id].en) or 1
        local have = by_name[name:lower()]
        if have then
            if tier > have.best then have.best = tier end
            return
        end
        -- Haste and Flurry don't go on together: one slot, showing whichever they have.
        if name:lower() == 'haste' or name:lower() == 'flurry' then
            local slot = by_name['haste/flurry']
            if not slot then
                slot = { name = 'Haste', slot = true, parts = {}, ids = {}, tag = 'HSTE', best = 1 }
                by_name['haste/flurry'] = slot
                list[#list + 1] = slot
            end
            local part = { name = name, ids = data.buff_ids(name), tag = PW_TAGS[name:lower()], best = tier }
            slot.parts[name:lower()] = part
            by_name[name:lower()] = part
            return
        end
        -- Storms: only one can be on someone, so they share one tag (which storm, or STRM).
        if pw_group(name) == 'storms' then
            local g = by_name.storms
            if not g then
                g = { name = 'Storms', ids = {}, tag = 'STRM', best = 1, storms = {} }
                by_name.storms = g
                list[#list + 1] = g
            end
            for _, id in ipairs(data.buff_ids(name)) do
                g.ids[#g.ids + 1] = id
                g.storms[id] = name:sub(1, 4):upper()
            end
            return
        end
        have = { name = name, ids = data.buff_ids(name), tag = PW_TAGS[name:lower()] or data.auto_label(name), best = tier }
        by_name[name:lower()] = have
        list[#list + 1] = have
    end
    for id, sp in pairs(res.spells) do
        if learned_spells[id] then
            consider({ kind = 'spell', id = id, status = sp.status, targets = sp.targets, levels = sp.levels })
        end
    end
    for id, ja in pairs(res.job_abilities) do
        if learned_ja[id] and ja.prefix ~= '/pet' then
            consider({ kind = 'ja', id = id, recast_id = ja.recast_id, status = ja.status, targets = ja.targets })
        end
    end
    local rank = {}
    for i, n in ipairs(PW_ORDER) do rank[n:lower()] = i end
    table.sort(list, function(a, b)
        local ra, rb = rank[a.name:lower()] or 99, rank[b.name:lower()] or 99
        if ra ~= rb then return ra < rb end
        return a.name < b.name
    end)
    pw_cache = { key = key, list = list }
    return list
end

-- Party window on for this job? The job's own setting (RDM: on) wins; otherwise the general one.
local function party_window_on()
    local v = job_cfg().party_window
    if v == nil then return settings.party_window and true or false end
    return v == true or v == 'true' or v == 'on'
end

-- Which buffs to show on whom: 'Flurry=RNG COR' shows Flurry only on Rangers and Corsairs.
-- Each entry is a buff name, '=', then jobs and/or player names. Buffs not listed show on
-- everyone; so do members whose job the addon doesn't know yet.
local pw_rules_cache = {}
local function pw_rules()
    local src = settings.party_window_for or ''
    if pw_rules_cache.src == src then return pw_rules_cache.rules end
    local rules = {}
    for _, item in ipairs(data.split(src)) do
        local buff, who = item:match('^(.-)%s*=%s*(.+)$')
        if buff and who then
            local set = {}
            for w in who:gmatch('[^%s/]+') do set[w:lower()] = true end
            rules[buff:lower()] = set
        end
    end
    pw_rules_cache = { src = src, rules = rules }
    return rules
end

-- Hidden on certain players / party slots: 'Storms=p2 Valda' hides every storm on party
-- slot 2 and on Valda. (p0 = you, p1-p5 = the others in party-list order.)
local pw_hide_cache = {}
local function pw_hidden_rules()
    local src = settings.party_window_hide or ''
    if pw_hide_cache.src == src then return pw_hide_cache.rules end
    local rules = {}
    for _, item in ipairs(data.split(src)) do
        local buff, who = item:match('^(.-)%s*=%s*(.+)$')
        if buff and who then
            local set = {}
            for w in who:gmatch('[^%s/]+') do set[w:lower()] = true end
            rules[buff:lower()] = set
        end
    end
    pw_hide_cache = { src = src, rules = rules }
    return rules
end

local function pw_allowed(buff, job, name, slot)
    local group = pw_group(buff)
    -- Hidden for this player or party slot?
    local hide = pw_hidden_rules()
    for _, key in ipairs({ buff:lower(), group }) do
        local h = key and hide[key]
        if h and ((name and h[name:lower()]) or (slot and h['p' .. slot]) or h.all) then return false end
    end
    local r = pw_rules()[buff:lower()] or (group and pw_rules()[group])
    if not r then return true end
    if r.all then return true end
    if not job and not (name and r[name:lower()]) then return job == nil end
    return (job and r[job:lower()]) or (name and r[name:lower()]) or false
end

local PW_MEMBER_LINES = 2   -- party window: lines per member at most
local PW_PER_LINE = 4       -- tags per line at most
local PW_INDENT = 2         -- extra indent for a member's second line

local function party_model(counts)
    if not party_window_on() then return nil end
    local C = palette
    local chars = tonumber(settings.party_window_width) or 30
    local list = castable_buffs()
    local party = windower.ffxi.get_party() or {}
    local out, n = {}, 0
    local NAME_W = 8   -- name column: 7 letters and a space
    local function add(s) out[#out + 1] = s n = n + 1 end
    -- A full party (6): leave yourself out, your own buffs are on the main window; the other
    -- five fit at 2 lines each.
    local members = 0
    for k = 0, 5 do if party['p' .. k] and party['p' .. k].name then members = members + 1 end end
    for k = 0, 5 do
        local m = party['p' .. k]
        if m and m.name and not (k == 0 and members >= 6) then
            local set, mid
            local job = k == 0 and player.main_job or (m.mob and data.party_jobs[m.mob.id] or {}).main
            if k == 0 then set, mid = counts, player.id
            elseif m.mob and m.mob.id then set, mid = data.party_buffs[m.mob.id] or {}, m.mob.id end
            if k == 0 then
                data.prune_member_buffs(player.id, function(bn)
                    for _, b in ipairs(data.buff_ids(bn)) do if counts[b] then return true end end
                    return false
                end)
            end
            local tracked = mid and data.member_buffs[mid] or {}
            local hpp = m.hpp or 0
            local name = cs(C.text, pad(m.name:sub(1, NAME_W - 1), NAME_W))
            if not set then
                local here = (windower.ffxi.get_info() or {}).zone
                add(name .. cs(C.dim, (m.zone and here and m.zone ~= here) and 'other zone' or 'out of range'))
            elseif #list == 0 and player.main_job ~= 'BRD' and not next((mid and data.member_songs[mid]) or {}) then
                add(name .. cs(C.dim, '--'))
            else
                -- Tags, wrapped under the name when they don't fit on one line. A buff not
                -- tracked on this member leaves a blank, so the columns line up with the others,
                -- unless the blanks would cost extra lines; then they're simply left out.
                local items = {}
                for _, b in ipairs(list) do
                  if b.slot then
                    -- Haste / Flurry slot: the one they have; if neither, Flurry where it's
                    -- tracked for them (RNG / COR) and you can cast it, else Haste.
                    local function has(part) if not part then return false end
                        for _, id in ipairs(part.ids) do if set[id] then return true end end return false end
                    local hp, fp = b.parts.haste, b.parts.flurry
                    if has(fp) then b = fp elseif has(hp) then b = hp
                    elseif fp and pw_allowed('Flurry', job, m.name, k) then b = fp
                    else b = hp or fp end
                  end
                  if not pw_allowed(b.name, job, m.name, k) then
                    items[#items + 1] = { text = (' '):rep(#b.tag) }
                  else
                    local on, which = false, nil
                    for _, id in ipairs(b.ids) do if set[id] then on, which = true, id break end end
                    -- red: missing. yellow: under a minute left. light blue: a weaker tier than
                    -- the one you can cast (only known if the addon saw it cast). green: fine.
                    local col = C.bad
                    if on then
                        local e = tracked[b.name:lower()]
                        local left
                        if k == 0 then
                            for _, id in ipairs(b.ids) do
                                local l = counts[id] and data.buff_remaining(id)
                                if l and (not left or l > left) then left = l end
                            end
                        elseif e and e.dur then
                            left = e.at + e.dur - os.clock()
                        end
                        if left and left < 60 then col = C.upkeep_warn
                        elseif e and e.tier < b.best then col = C.lower_tier or C.active
                        else col = C.good end
                    end
                    -- (the storm tag names the storm they have: AURO, FIRE...)
                    items[#items + 1] = { text = (b.storms and which and b.storms[which]) or b.tag, col = col }
                  end
                end
                while #items > 0 and not items[#items].col do items[#items] = nil end
                -- Then your songs on them, once you've sung them (oldest first): green, yellow
                -- under a minute left. They drop off when they wear.
                local songs = {}
                for sid, e in pairs((mid and data.member_songs[mid]) or {}) do
                    local left = e.at + e.dur - os.clock()
                    if left > 0 then songs[#songs + 1] = { e = e, left = left } end
                end
                table.sort(songs, function(a, b) return (a.e.seq or 0) < (b.e.seq or 0) end)
                for _, sg in ipairs(songs) do
                    -- yellow under a minute; sung under Soul Voice: its own colour (pink)
                    items[#items + 1] = { text = data.song_tag(sg.e.name),
                        col = sg.left < 60 and C.upkeep_warn or (sg.e.sv and (C.soul_voice or C.accent)) or C.good }
                end
                -- On BRD, the song slots you haven't filled on them yet: SNG1, SNG2... in grey.
                if player.main_job == 'BRD' then
                    local slots = tonumber(job_cfg().song_slots or settings.song_slots) or 5
                    for i = #songs + 1, slots do items[#items + 1] = { text = 'SNG' .. i, col = C.dim } end
                end
                -- At most PW_PER_LINE tags on a line; the next line is indented a little more
                -- than the tags above it.
                local function layout(use)
                    local rows, row, used, start, count = {}, name, NAME_W, NAME_W, 0
                    for _, it in ipairs(use) do
                        local t = it.text
                        if count >= PW_PER_LINE or (used + #t + 1 > chars and used > start) then
                            rows[#rows + 1] = row
                            start = NAME_W + PW_INDENT
                            row, used, count = (' '):rep(start), start, 0
                        end
                        local sep = used > start and ' ' or ''
                        row = row .. (it.col and cs(it.col, sep .. t) or (sep .. t))
                        used = used + #t + #sep
                        count = count + 1
                    end
                    rows[#rows + 1] = row
                    return rows
                end
                local rows = layout(items)
                local shown = {}
                for _, it in ipairs(items) do if it.col then shown[#shown + 1] = it end end
                local tight = layout(shown)
                if #tight < #rows then rows = tight end
                -- At most 2 lines per member; anything past that is left off with a '+'.
                if #rows > PW_MEMBER_LINES then
                    rows = layout(shown)
                    for r = #rows, PW_MEMBER_LINES + 1, -1 do rows[r] = nil end
                    rows[#rows] = rows[#rows] .. cs(C.dim, '+')
                end
                for r = 1, #rows - 1 do add(rows[r]) end
                local row = rows[#rows]
                add(row)
            end
        end
    end
    if n == 0 then add(cs(C.dim, 'No party')) end
    local title_plain = 'Party' .. (#list > 0 and ('  ' .. #list .. ' buffs you can cast') or '')
    local title = cs(C.label, 'Party') .. cs(C.dim, title_plain:sub(6))
    -- Same size on every job: party_window_width wide, as tall as the main panel. Rows that
    -- don't fit end in '+N more'.
    -- As tall as the main panel; if a full party runs past it, the last line says so.
    local fit = display.layout()
    local max_lines = fit and fit.lines or n
    if n > max_lines then
        local extra = n - max_lines + 1
        for i = #out, max_lines, -1 do out[i] = nil end
        out[max_lines] = cs(C.dim, '+' .. extra .. ' more lines')
        n = max_lines
    end
    if #title_plain > chars then title = cs(C.label, 'Party') .. cs(C.dim, title_plain:sub(6, chars)) end
    return { title = title, text = table.concat(out, '\n'), lines = n, chars = chars }
end

-- Compact mode's rows: the job's own `compact` list if set, otherwise the stance-type rows from
-- both columns (Stance, Migawari, Storm, Hover, Wyvern...) plus shadows, runes, maneuvers and the
-- like, after HP/MP/TP and the target, then your own buffs and Hate (if it fits); no weapon / WS /
-- SC / window / burst / party tags.
local COMPACT_LEFT = { shadows = true, runes = true, maneuvers = true, fm = true, rolls = true, arts = true,
    storm = true, klimaform = true, sublimation = true, afflatus = true, migawari = true, hover = true,
    velocity = true, bounty = true, wyvern = true, foesong = true, flourish = true, dance = true, samba = true, steps = true }
local COMPACT_SKIP = { window = true, burst = true, aggro = true, debuffs = true, party = true, ws = true,
    showbiz = true, buffs = true, timers = true, notes = true, upkeep = true }
local function compact_rows(cfg, rlist)
    if cfg.compact and cfg.compact ~= '' then return data.split(cfg.compact) end
    local out, seen = {}, {}
    local function add(r) local k = r:lower() if not seen[k] then seen[k] = true out[#out + 1] = r end end
    local left = ordered_rows(cfg.rows)
    local function has(list, name) for _, r in ipairs(list) do if r:lower() == name then return true end end end
    add('vitals')                                         -- HP / MP / TP
    add('target')
    for _, r in ipairs(left) do if COMPACT_LEFT[r:lower()] then add(r) end end
    for _, r in ipairs(rlist) do if not COMPACT_SKIP[r:lower()] then add(r) end end
    -- Your own buffs: the job's buff tags, then its buff timer lines (wherever the job keeps them).
    if has(left, 'upkeep') or has(rlist, 'upkeep') then add('upkeep') end
    if has(left, 'buffs') or has(rlist, 'buffs') then add('buffs') end
    add('aggro')                                          -- Hate, only if it fits (see build_model)
    return out
end

local function build_model()
    local counts = data.count_buffs(player.buffs)
    refresh_learned()
    local fit = display.layout()
    local header, header_chars, inds = build_header(counts)

    -- Left rows, then the right-hand column: each only as many lines as the fixed panel holds.
    local function column(rows, width, shrink)
        col_width = width
        -- Rows that may simply be cut off the bottom when there's no room (they're lists that
        -- can run long); the rest are worth drawing shorter to keep.
        local CUTTABLE = { buffs = true, timers = true, notes = true, inventory = true }
        local function build()
            bounty_shown = false
            velocity_shown = false
            local out, keep = {}, 0
            for _, row in ipairs(rows) do
                local fn = ROWS[row:lower()]
                local n0 = #out
                if fn then fn(out, counts) end
                if not CUTTABLE[row:lower()] then keep = keep + (#out - n0) end
            end
            return out, keep
        end
        local lines, keep = build()
        -- The rows worth keeping don't fit: draw the WS block, then the runes, shorter.
        if shrink and keep > fit.lines then
            compact.ws = true
            lines, keep = build()
            if keep > fit.lines then compact.runes = true lines = build() end
            compact = {}
        end
        if #lines > fit.lines then
            local extra = #lines - fit.lines + 1
            for i = #lines, fit.lines, -1 do lines[i] = nil end
            lines[fit.lines] = line(nil, { { '+' .. extra .. ' more', palette.dim } })
            overflow = true
        end
        col_width = nil
        local overflow = #lines > fit.lines
        local strs, hovers = {}, {}
        for i, l in ipairs(lines) do
            strs[i] = l.s
            for _, h in ipairs(l.hovers or {}) do hovers[#hovers + 1] = { line = i - 1, c0 = h[1], c1 = h[2], tip = h[3] } end
        end
        return table.concat(strs, '\n'), hovers, overflow
    end
    showbiz_gif = nil
    local cfg = job_cfg()
    local right_rows = cfg.right or (settings.jobs.DEFAULT and settings.jobs.DEFAULT.right) or ''
    local rlist = data.split(right_rows)
    -- Support job NIN: a Shadows count on the right (before the party tags), unless the job
    -- already shows shadows somewhere.
    if player.sub_job == 'NIN' then
        local has = false
        for _, r in ipairs(rlist) do if r:lower() == 'shadows' then has = true end end
        for _, r in ipairs(data.split(cfg.rows or '')) do if r:lower() == 'shadows' then has = true end end
        if not has then
            local at = #rlist + 1
            for i, r in ipairs(rlist) do if r:lower() == 'party' then at = i break end end
            table.insert(rlist, at, 'shadows')
        end
    end
    local left, left_hovers, right, right_hovers
    if settings.compact_mode then
        -- Compact: one narrow column with only what matters mid-fight (no right column).
        -- Hate goes in only if there's room for it.
        local rows = compact_rows(cfg, rlist)
        local over
        left, left_hovers, over = column(rows, fit.width, true)
        local has_aggro = false
        for _, r in ipairs(rows) do if r:lower() == 'aggro' then has_aggro = true end end
        if has_aggro and over then
            local without = {}
            for _, r in ipairs(rows) do if r:lower() ~= 'aggro' then without[#without + 1] = r end end
            left, left_hovers = column(without, fit.width, true)
        end
    else
        left, left_hovers = column(ordered_rows(cfg.rows), fit.width, true)
        if fit.right > 0 then right, right_hovers = column(rlist, fit.right) end
    end

    -- Cells: only as many as the grid holds. Support-job cells go on the bottom row(s) when
    -- grid.sub_position is 'bottom', with any gap left empty.
    local cells = {}
    local cap = display.capacity()
    if cap > 0 then
        local all = build_cells(counts)
        local cols = settings.layout.columns
        if settings.grid.sub_position == 'bottom' then
            local main, sub = {}, {}
            for _, c in ipairs(all) do
                if c.sub then sub[#sub + 1] = c else main[#main + 1] = c end
            end
            -- The job's own cells always come first; support-job cells only use slots left over,
            -- starting at the bottom row (or right after the job's cells if that's lower).
            main = fit_cells(main, cap)
            for i, c in ipairs(main) do cells[i] = c end
            local free = cap - #main
            if free > 0 and #sub > 0 then
                sub = fit_cells(sub, free)
                local start = cap - math.ceil(#sub / cols) * cols + 1
                if start <= #main then start = #main + 1 end
                for i, c in ipairs(sub) do cells[start + i - 1] = c end
            end
        else
            cells = fit_cells(all, cap)
        end
    end

    return { header = header, header_chars = header_chars, indicators = inds,
             rows = left, right = right, cells = cells, gif = showbiz_gif,
             hovers = { left = left_hovers or {}, right = right_hovers or {} } }
end

local function tick()
    if not settings then return end
    if not display.measure() then return end
    player = windower.ffxi.get_player()
    if not player or not player.main_job then display.hide() return end
    if (player.vitals.tp or 0) >= 1000 then last_tp = player.vitals.tp end
    track_sublimation()
    do  -- wyvern HP learning (DRG), kept per character in the settings file
        local pet = player.main_job == 'DRG' and windower.ffxi.get_mob_by_target('pet')
        data.wyvern_tick(pet and pet.hpp or nil)
        if player.main_job == 'DRG' then
            local cfg = job_cfg(true)
            local w = data.wyvern
            local saved = tonumber(cfg.wyvern_hp_learned)
            -- Start from this character's saved value; new readings take over from there.
            if not w.max and saved then w.max = saved end
            -- Save a newly learned value (right away the first time, then at most every 30 s).
            local now = os.clock()
            if w.max and #w.samples > 0 and saved ~= w.max and (not saved or now - wyvern_saved_at >= 30) then
                cfg.wyvern_hp_learned = w.max
                wyvern_saved_at = now
                save()
            end
        end
    end

    local key = table.concat({ player.main_job, player.main_job_level or 0,
        player.sub_job or '-', sub_level(), arts_state() or '-' }, ':')
    if key ~= job_key then
        if not job_key or job_key:match('^[^:]+') ~= key:match('^[^:]+') then load_learned() end   -- new job / login
        job_key = key
        learned_at = -1
        build_entries()
    end

    if not should_show() then display.hide() return end
    last_model = build_model()
    -- Danger: the frame flashes red while your HP is under the job's danger HP%.
    local danger = tonumber(job_cfg().danger) or 0
    local alarm = danger > 0 and (player.vitals.hpp or 100) < danger
    -- Fade when idle: not engaged for idle_delay seconds -> the cooldown grid fades to idle_opacity
    -- (the rest of the panel stays as it is). Back to solid the moment you engage, the mouse is
    -- over the panel, or the HP alarm is on. Set before drawing, so a change shows this frame.
    local now = os.clock()
    local idle_op = tonumber(settings.idle_opacity) or 100
    if player.status == 1 or hovering or alarm or idle_op >= 100 then
        idle_since = nil
        display.fade(1)
    else
        idle_since = idle_since or now
        if now - idle_since >= (tonumber(settings.idle_delay) or 10) then display.fade(idle_op / 100) end
    end
    display.render(last_model)
    display.show()
    display.alarm(alarm)
    display.party_render(party_model(data.count_buffs(player.buffs)))
end

windower.register_event('prerender', function()
    local now = os.clock()
    if now - last_tick < (settings and settings.update_rate or 0.2) then return end
    last_tick = now
    local ok, err = pcall(tick)
    if not ok and err ~= last_error then
        last_error = err
        msg('Error: ' .. tostring(err))
    end
end)

------------------------------------------------------------------------------------------
-- Settings lifecycle
------------------------------------------------------------------------------------------

local function rebuild()
    job_key = nil
    local stroke
    palette, stroke = themes.build(settings)
    display.init(settings, palette, stroke)
end

-- Debuff durations learned in play are kept in settings.debuff_times ('Angon:90,Gambit:80').
load_debuff_times = function()
    data.debuff_learned = {}
    for _, part in ipairs(data.split(settings.debuff_times)) do
        local name, sec = part:match('^(.-):(%d+)$')
        if name then data.debuff_learned[name] = tonumber(sec) end
    end
end

-- Charge times and buff / song durations learned in play, per character AND job (job points,
-- merits and gear differ by job): job settings learned_charges ('102:30,231:5:48') and
-- learned_durations ('57:216,398:180').
load_learned = function()
    for k in pairs(data.learned_charge) do data.learned_charge[k] = nil end
    data.learned_buff_dur = {}
    if not (settings and player) then return end
    local cfg = job_cfg()
    for _, part in ipairs(data.split(cfg.learned_charges or '')) do
        local key, sec = part:match('^(.-)=(%d+)$')
        if key then data.learned_charge[tonumber(key) or key] = tonumber(sec) end
    end
    for _, part in ipairs(data.split(cfg.learned_durations or '')) do
        local id, sec = part:match('^(%d+)=(%d+)$')
        if id then data.learned_buff_dur[tonumber(id)] = tonumber(sec) end
    end
end

data.on_learned = function(kind, key, sec)
    if not (settings and player) then return end
    local cfg = job_cfg(true)
    local src = kind == 'charge' and data.learned_charge or data.learned_buff_dur
    local parts = {}
    for k, v in pairs(src) do parts[#parts + 1] = tostring(k) .. '=' .. v end
    table.sort(parts)
    if kind == 'charge' then cfg.learned_charges = table.concat(parts, ',')
    else cfg.learned_durations = table.concat(parts, ',') end
    save()
end

data.on_debuff_learned = function(name, sec)
    if not settings then return end
    local parts = {}
    for n, v in pairs(data.debuff_learned) do parts[#parts + 1] = n .. ':' .. v end
    table.sort(parts)
    settings.debuff_times = table.concat(parts, ',')
    save()
end

------------------------------------------------------------------------------------------
-- Keeping settings files up to date
------------------------------------------------------------------------------------------
-- Next to each character's settings file the addon keeps data/<Name>_defaults.lua: the
-- defaults that file was last brought up to. On load, every setting that still holds that old
-- default (you never changed it) is moved to this version's default; anything you changed is
-- kept. Files from before this existed are compared against every default the addon has ever
-- shipped (jobhud_legacy.lua).

local function flatten(t, prefix, out)
    out = out or {}
    for k, v in pairs(t) do
        local path = prefix and (prefix .. '.' .. k) or tostring(k)
        if type(v) == 'table' then flatten(v, path, out)
        elseif type(v) ~= 'function' then out[path] = tostring(v) end
    end
    return out
end

local function path_get(t, path)
    for part in path:gmatch('[^.]+') do
        if type(t) ~= 'table' then return nil end
        t = t[part]
    end
    return t
end

local function path_set(t, path, value)
    local parts = {}
    for part in path:gmatch('[^.]+') do parts[#parts + 1] = part end
    for i = 1, #parts - 1 do
        if type(t[parts[i]]) ~= 'table' then return end
        t = t[parts[i]]
    end
    t[parts[#parts]] = value
end

local function seen_path(name) return windower.addon_path .. 'data/' .. name .. '_defaults.lua' end

local function read_seen(name)
    local f = io.open(seen_path(name), 'r')
    if not f then return nil end
    local text = f:read('*a')
    f:close()
    local chunk = loadstring and loadstring(text) or load(text)
    local ok, t = pcall(chunk)
    return ok and type(t) == 'table' and t or nil
end

local function write_seen(name, flat)
    local keys = {}
    for k in pairs(flat) do keys[#keys + 1] = k end
    table.sort(keys)
    local out = { '-- Job-HUD: the defaults this character\'s settings were last updated to. Don\'t edit.', 'return {' }
    for _, k in ipairs(keys) do out[#out + 1] = ('    [%q] = %q,'):format(k, flat[k]) end
    out[#out + 1] = '}'
    local f = io.open(seen_path(name), 'w')
    if not f then return end
    f:write(table.concat(out, '\n'), '\n')
    f:close()
end

-- Returns how many settings were moved to new defaults, and the defaults to record.
local function migrate(name)
    local new = flatten(defaults)
    local seen = read_seen(name)
    local legacy
    if not seen then
        local ok, t = pcall(require, 'jobhud_legacy')
        legacy = ok and t or {}
    end
    local changed = 0
    for path, value in pairs(new) do
        local cur = path_get(settings, path)
        if cur ~= nil and tostring(cur) ~= value then
            local was_default
            if seen then
                was_default = seen[path] ~= nil and tostring(cur) == seen[path]
            else
                for _, old in ipairs(legacy[path] or {}) do
                    if tostring(cur) == old then was_default = true break end
                end
            end
            if was_default then
                path_set(settings, path, path_get(defaults, path))
                changed = changed + 1
            end
        end
    end
    return changed, new
end

-- You, your pet, or anyone in your party / alliance (for counting kills).
data.is_ally = function(id)
    local me = player or windower.ffxi.get_player()
    if me and id == me.id then return true end
    local pet = windower.ffxi.get_mob_by_target('pet')
    if pet and id == pet.id then return true end
    local ok, party = pcall(windower.ffxi.get_party)
    if not ok or type(party) ~= 'table' then return false end
    for k, m in pairs(party) do
        if type(m) == 'table' and m.mob and m.mob.id == id then return true end
    end
    return false
end

local function load_settings()
    local p = windower.ffxi.get_player()
    if not p then return end
    data.wyvern = { samples = {}, pending = 0 }   -- a new character: its own wyvern HP
    char_name = p.name
    settings = config.load('data/' .. p.name .. '.xml', defaults)
    local changed, synced = migrate(p.name)
    -- The cooldown grid is always 4 x 4 and beside the rows, in normal and compact mode.
    settings.layout.columns, settings.layout.grid_rows = 4, 4
    settings.grid.enabled, settings.grid.position = true, 'right'
    load_debuff_times()
    save() -- write the full file, so every option is there to edit
    write_seen(p.name, synced)
    rebuild()
    if changed > 0 then
        msg(('Updated %d setting%s to this version\'s defaults (anything you changed was kept).'):format(
            changed, changed == 1 and '' or 's'))
    end
end

-- Settings are saved whenever they change (commands, dragging), never on unload or logout:
-- an old copy of the addon unloading during an update would otherwise write its settings
-- over the new version's file.
local function unload_settings()
    display.destroy()
    settings, player, job_key = nil, nil, nil
end

windower.register_event('load', function()
    -- Runs on //lua load and //lua reload.
    msg(('v%s loaded (by %s). //jhud help for commands.'):format(_addon.version, _addon.author))
    msg('Current jobs with their own layout:')
    msg(table.concat(SUPPORTED_JOBS, ', ') .. '.')
    if windower.ffxi.get_info().logged_in then
        load_settings()
        local p63 = windower.packets.last_incoming(0x063)
        if p63 then data.on_0x063(p63) end
        local p61 = windower.packets.last_incoming(0x061)
        if p61 then data.on_0x061(p61) end
    end
end)

windower.register_event('login', function()
    -- The player table isn't filled in for a moment after login.
    coroutine.schedule(load_settings, 2)
end)

windower.register_event('logout', unload_settings)
windower.register_event('unload', function()
    display.destroy()
end)

windower.register_event('incoming chunk', function(id, packet)
    if id == 0x063 then
        data.on_0x063(packet)
    elseif id == 0x067 or id == 0x068 then
        data.on_pet_packet(id, packet, player or windower.ffxi.get_player())
    elseif id == 0x029 then
        data.on_0x029(packet)
    elseif id == 0x0DD then
        data.on_0x0DD(packet)
    elseif id == 0x076 then
        data.on_0x076(packet)
    elseif id == 0x061 then
        data.on_0x061(packet)
    elseif id == 0x00B then
        zoning = true
        if settings then display.hide() end
    elseif id == 0x00A then
        zoning = false
        data.clear_buffs()
        -- TP is wiped on zoning, so the last weapon skill / skillchain is cleared too.
        data.last_ws = nil
        data.clear_mobs()
        last_tp = nil
    end
end)

windower.register_event('action', function(act)
    -- player.vitals.tp is from the last tick, i.e. the TP the weapon skill was used at.
    if player then
        -- Soul Voice up as you sing? (songs sung under it are marked in the party window)
        local sv = data.buff_id('Soul Voice')
        data.soul_voice = false
        for _, id in ipairs(player.buffs or {}) do if id == sv then data.soul_voice = true end end
        data.on_action(act, player.id, last_tp)
        data.on_any_action(act, player.id)
        data.track_pet(act, player.id, windower.ffxi.get_mob_by_target('pet'))
        local me = windower.ffxi.get_mob_by_target('me')
        local hv = data.buff_id('Hover Shot')
        local on = false
        for _, id in ipairs(player.buffs or {}) do if id == hv then on = true end end
        data.on_hover_action(act, player.id, me and me.x and { x = me.x, y = me.y } or nil, on)
    end
end)

windower.register_event('job change', function() job_key = nil end)

------------------------------------------------------------------------------------------
-- Mouse: drag the panel anywhere on it
------------------------------------------------------------------------------------------

-- Keep at least `margin` pixels of the panel on screen, so it can't be lost off an edge.
local function clamp_to_screen(x, y, w, h)
    local ws = windower.get_windower_settings()
    local sw, sh = ws and ws.x_res, ws and ws.y_res
    if not w then w, h = display.size() end
    if not (sw and sh and w and h) then return x, y end
    local margin = 40
    x = math.max(margin - w, math.min(x, sw - margin))
    y = math.max(0, math.min(y, sh - margin))
    return math.floor(x), math.floor(y)
end

local pw_dragging   -- the party window being dragged on its own: { dx, dy }

windower.register_event('mouse', function(type, mx, my, delta, blocked)
    if not settings then return end
    -- The party window moves on its own (//jhud pw reset puts it back beside the main one).
    if type == 2 and pw_dragging then
        pw_dragging = nil
        local _, _, w, h = display.party_geom()
        settings.party_window_x, settings.party_window_y = clamp_to_screen(settings.party_window_x, settings.party_window_y, w, h)
        display.party_refresh()
        save()
        return true
    end
    if type == 0 and pw_dragging then
        settings.party_window_docked = false
        settings.party_window_x, settings.party_window_y = math.floor(mx - pw_dragging.dx), math.floor(my - pw_dragging.dy)
        display.party_refresh()
        return true
    end
    if type == 1 and not blocked and not settings.locked and not display.hit(mx, my) and display.party_hit(mx, my) then
        local x, y = display.party_geom()
        display.tip(nil)
        pw_dragging = { dx = mx - x, dy = my - y }
        return true
    end
    -- Always finish a drag on button up, even if another addon claimed the event.
    -- Click to use: a click (no drag) on a grid cell uses its ability or spell.
    if type == 2 and (dragging or pressed) then
        local p, d = pressed, dragging
        pressed = nil
        if p and settings.click_to_use and math.abs(mx - p.x) <= 4 and math.abs(my - p.y) <= 4 then
            local i = display.cell_at(mx, my)
            local c = i and last_model and last_model.cells[i]
            if c and c.use and i == p.cell then
                if d then settings.pos.x, settings.pos.y = d.ox, d.oy end   -- (not moved)
                dragging = nil
                if last_model then display.render(last_model) end
                windower.send_command(c.use)
                return true
            end
        end
        if not d then return true end
        dragging = nil
        settings.pos.x, settings.pos.y = clamp_to_screen(settings.pos.x, settings.pos.y)
        if last_model then display.render(last_model) end
        save()
        return true
    end
    if blocked then return end
    if type == 0 and dragging then
        settings.pos.x, settings.pos.y = clamp_to_screen(mx - dragging.dx, my - dragging.dy)
        if last_model then display.render(last_model) end
        return true
    elseif type == 1 and display.hit(mx, my) and (not settings.locked or settings.click_to_use) then
        pressed = { x = mx, y = my, cell = settings.click_to_use and display.cell_at(mx, my) or nil }
        if settings.locked then
            -- Locked: only a press on a usable cell is taken (for click to use).
            local c = pressed.cell and last_model and last_model.cells[pressed.cell]
            if not (c and c.use) then pressed = nil return end
            return true
        end
        -- Left button down anywhere on the panel picks it up.
        display.tip(nil)
        dragging = { dx = mx - settings.pos.x, dy = my - settings.pos.y, ox = settings.pos.x, oy = settings.pos.y }
        return true
    elseif type == 0 then
        -- Hover: details for whatever is under the mouse.
        hovering = display.hit(mx, my)
        if settings.tooltips then display.tip(hovering and display.tip_at(mx, my) or nil, mx, my)
        else display.tip(nil) end
    end
end)

------------------------------------------------------------------------------------------
-- Commands
------------------------------------------------------------------------------------------

-- Help, in sections. '//jhud help' lists the sections; '//jhud help <section>' (or just
-- '//jhud <section>') shows one. Section names also work as a prefix to their commands:
-- '//jhud look theme light' is the same as '//jhud theme light'.
local HELP_ORDER = { 'panel', 'look', 'job', 'options', 'timers', 'setup' }
local HELP_SECTIONS = {
    panel = {
        about = 'show / hide, dragging, position and size',
        commands = { 'show', 'hide', 'toggle', 'compact', 'lock', 'unlock', 'partywindow', 'pw', 'pos', 'layout', 'size', 'font',
                     'width', 'lines', 'gridsize', 'cols', 'cell', 'rwidth', 'grid' },
        lines = {
            'show | hide | toggle        the panel',
            'compact [on|off]            grid + stances / shadows only (compact rows ... to pick them)',
            'lock | unlock               stop / allow dragging (locked: clicks go to the game)',
            'partywindow [on|off|<w>]    second window: party + buffs you can cast (pw)',
            'pw for [<Buff> <JOB/Name...>|all]  which members each buff shows on',
            'pw hide <Buff|Storms> <Name|p1..p5|all>   hide a buff on a player / party slot (pw unhide)',
            'pw reset                    party window back beside the main window (drag it to move it)',
            'pos [<x> <y>]               show or set the position (or just drag it)',
            'layout                      panel size in pixels (same on every job)',
            'size <n> | font <name>      text size / font',
            'width <chars> | lines <n>   left column width / text lines',
            'cell <chars> | rwidth <chars> (0 = no right column)   (the grid is always 4 x 4)',
            'grid sub bottom|after       support-job cells: bottom row, or after your job\'s',
        },
    },
    look = {
        about = 'theme, colour-blind palette, opacity, idle fade, header squares',
        commands = { 'theme', 'palette', 'colorblind', 'colourblind', 'opacity', 'idle', 'header' },
        lines = {
            'theme lattice|light|contrast',
            'look normal|redgreen|deut|trit   colour-blind colours (redgreen = protanopia)',
            'opacity <0-100>             panel and cell backgrounds',
            'idle <0-100> [seconds] | idle off   fade the cooldown grid when not engaged',
            'header <list>               engaged,ws,pet,food,reraise,signet,sneak,invis,sync',
        },
    },
    job = {
        about = 'what this job shows (left rows, right column, grid, tags)',
        commands = { 'rows', 'row', 'right', 'cd', 'cooldown', 'cooldowns', 'sub', 'upkeep', 'keep',
                     'party', 'debuff', 'debuffs', 'buff', 'buffs', 'danger', 'petalarm', 'highlight', 'copyjob' },
        lines = {
            'Lists: <name> shows it, then add <x> [pos] | remove <x> | move <x> <pos> | clear',
            'rows | row ...              left-side rows',
            'right ...                   right column: window, burst, debuffs, aggro, party',
            'cd ...                      grid cells, e.g. cd add HJ=High Jump 2 (cd add _ 6 = empty slot)',
            'sub ...                     cells for the support job you\'re on',
            'upkeep ...                  your buff tags, e.g. upkeep add HSSO=Hasso',
            'party ...                   buffs others keep on you, e.g. party add RFSH=Refresh (ROLL = any roll)',
            'debuff ...                  Angon, Tomahawk, Gambit, Rayke timers',
            'buff ...                    buff timer lines on the left',
            'danger <HP%>|off            frame flashes red under this HP%',
            'petalarm <HP%>|off          pet line flashes, pet heals highlighted, under this pet HP%',
            'highlight ...               cells that turn purple while their effect is on you',
            'copyjob <JOB>               copy another job\'s setup onto this one',
        },
    },
    options = {
        about = 'cooldown colours, announcements, what\'s hidden',
        commands = { 'soon', 'announce', 'hideunavail', 'hidemissing', 'distance', 'tooltips', 'tips', 'activecells', 'purple', 'clickuse', 'click' },
        lines = {
            'soon <seconds> [fraction]   when a cell turns orange (default 10 0.2)',
            'announce on|off             chat line when a cooldown comes back',
            'hideunavail on|off          hide slate (unusable) cells',
            'hidemissing on|off          hide buff lines that are off',
            'distance on|off             target distance on the TGT line',
            'tooltips on|off             details when you hover over the panel',
            'activecells on|off          one-use abilities turn purple while their effect waits on you',
            'clickuse on|off             click a grid cell to use its ability / spell (off by default)',
        },
    },
    timers = {
        about = 'your own countdowns, notes, session stats',
        commands = { 'timer', 'timers', 'note', 'stats' },
        lines = {
            'timer <label> <time>        e.g. timer Pop 5:00, timer Pull 45, timer NM 2h',
            'timer clear [label] | timers',
            'note <key> <value> | note clear [key]   text for the notes row',
            'stats | stats reset         this session\'s weapon skills, skillchains and kills',
        },
    },
    setup = {
        about = 'reset, copy from another character, reload the addon',
        commands = { 'reset', 'import', 'reload', 'save' },
        lines = {
            'reset job | reset pw | reset all   back to defaults (keeps your position; pw = party window back beside the main one)',
            'import <Character>          copy another character\'s setup',
            'reload                      reload the addon (re-reads the settings file too)',
            'save                        write the settings file now',
        },
    },
}

-- //jhud stats: this session's weapon skills, skillchains and kills, in chat.
local function commas_n(n)
    local s = tostring(math.floor(n))
    while true do
        local r, k = s:gsub('^(%d+)(%d%d%d)', '%1,%2')
        s = r
        if k == 0 then return s end
    end
end

print_stats = function()
    local st = data.stats
    local secs = math.max(os.time() - st.start, 1)
    local hours = secs / 3600
    local out = {}
    out[#out + 1] = ('Job-HUD session: %s'):format(fmt_time(secs))
    local names = {}
    for name in pairs(st.ws) do names[#names + 1] = name end
    table.sort(names, function(a, b) return st.ws[a].n > st.ws[b].n end)
    if #names == 0 then
        out[#out + 1] = '  No weapon skills yet.'
    end
    local all_n, all_hits, all_total = 0, 0, 0
    for _, name in ipairs(names) do
        local w = st.ws[name]
        all_n, all_hits, all_total = all_n + w.n, all_hits + w.hits, all_total + w.total
        out[#out + 1] = ('  %s x%d: avg %s, best %s%s'):format(name, w.n,
            w.hits > 0 and commas_n(w.total / w.hits) or '-', commas_n(w.best),
            w.n > w.hits and (', ' .. (w.n - w.hits) .. ' missed') or '')
    end
    if #names > 1 then
        out[#out + 1] = ('  All weapon skills: %d, avg %s'):format(all_n, all_hits > 0 and commas_n(all_total / all_hits) or '-')
    end
    out[#out + 1] = ('  Skillchains: %d (avg %s)   Kills: %d'):format(st.sc,
        st.sc > 0 and commas_n(st.sc_damage / st.sc) or '-', st.kills)
    if secs >= 300 then
        out[#out + 1] = ('  %s weapon skills/h, %s skillchains/h, %s kills/h'):format(
            commas_n(all_n / hours), commas_n(st.sc / hours), commas_n(st.kills / hours))
    end
    for _, l in ipairs(out) do windower.add_to_chat(207, l) end
end

local function show_help(section)
    local sec = section and HELP_SECTIONS[section]
    if sec then
        windower.add_to_chat(207, ('Job-HUD %s: %s'):format(section, sec.about))
        for _, l in ipairs(sec.lines) do windower.add_to_chat(207, '  ' .. l) end
        return
    end
    windower.add_to_chat(207, 'Job-HUD  //jhud help <section>   (or //jhud <section> <command>)')
    for _, name in ipairs(HELP_ORDER) do
        windower.add_to_chat(207, ('  %-8s %s'):format(name, HELP_SECTIONS[name].about))
    end
end

local function on_off(arg, current)
    if arg == 'on' or arg == 'true' then return true end
    if arg == 'off' or arg == 'false' then return false end
    return not current
end

local function edit_list(get, set, args, what)
    local sub = (args[1] or ''):lower()
    local list = data.split(get())
    if sub == '' or sub == 'list' then
        msg(what .. ': ' .. (#list > 0 and table.concat(list, ', ') or '(none)'))
        return
    end
    if sub == 'clear' then
        set('')
        msg(what .. ': (none)')
        job_key = nil
        save()
        return
    end
    local rest = {}
    for i = 2, #args do rest[#rest + 1] = args[i] end
    local pos
    if (sub == 'add' or sub == 'move') and #rest > 1 and tonumber(rest[#rest]) then
        pos = tonumber(table.remove(rest))
    end
    local name = table.concat(rest, ' ')
    if name == '' then msg('Usage: ' .. what .. ' add|remove|move <name> [pos]') return end
    if sub == 'add' then
        local _, plain = data.label_split(name)
        if what == 'Party' and not (data.buff_id(plain) or plain:upper() == 'ROLL') then
            msg('Unknown buff: ' .. plain) return
        end
        if what == 'Upkeep' and not (#data.resolve_alts(plain) > 0 or data.buff_id(plain) or plain:upper() == 'PET') then
            msg('Unknown spell, ability or buff: ' .. plain) return
        end
        if what ~= 'Rows' and what ~= 'Compact rows' and what ~= 'Buffs' and what ~= 'Upkeep' and what ~= 'Party' and what ~= 'Highlight' and plain ~= '_' and #data.resolve_alts(plain) == 0 then
            msg('Unknown ability or spell: ' .. plain) return
        end
        if what == 'Buffs' and not data.buff_id(name) then msg('Unknown buff: ' .. name) return end
        if (what == 'Rows' or what == 'Compact rows') and not table.contains(ROW_NAMES, name:lower()) then
            msg('Unknown row. Rows: ' .. table.concat(ROW_NAMES, ', ')) return
        end
        table.insert(list, math.max(1, math.min(pos or (#list + 1), #list + 1)), name)
    elseif sub == 'remove' or sub == 'rm' or sub == 'del' then
        local i = list_find(list, name)
        if not i then msg('Not in the list: ' .. name) return end
        table.remove(list, i)
    elseif sub == 'move' then
        local i = list_find(list, name)
        if not i or not pos then msg('Usage: ' .. what .. ' move <name> <pos>') return end
        local item = table.remove(list, i)
        table.insert(list, math.max(1, math.min(pos, #list + 1)), item)
    else
        msg('Use add, remove, move or list.') return
    end
    set(data.join(list))
    msg(what .. ': ' .. (#list > 0 and table.concat(list, ', ') or '(none)'))
    job_key = nil
    save()
end

windower.register_event('addon command', function(cmd, ...)
    local args = { ... }
    cmd = (cmd or 'help'):lower()
    if not settings then msg('Not logged in.') return end
    player = player or windower.ffxi.get_player()

    -- '//jhud look normal|redgreen|deut|trit': the colour palette.
    if cmd == 'look' and args[1] and themes.palette_alias[args[1]:lower()] then
        cmd = 'palette'
    end
    -- A section name: on its own, that section's help; followed by a command, runs it.
    if HELP_SECTIONS[cmd] then
        local section = cmd
        if #args == 0 then show_help(section) return end
        cmd = table.remove(args, 1):lower()
        if not table.contains(HELP_SECTIONS[section].commands, cmd) then
            msg(('"%s" isn\'t a %s command.'):format(cmd, section))
            show_help(section)
            return
        end
    end

    if cmd == 'help' then
        show_help(args[1] and args[1]:lower())
    elseif cmd == 'show' or cmd == 'hide' or cmd == 'toggle' then
        settings.visible = cmd == 'show' or (cmd == 'toggle' and not settings.visible)
        if not settings.visible then display.hide() end
        save()
    elseif cmd == 'lock' or cmd == 'unlock' then
        settings.locked = cmd == 'lock'
        msg(settings.locked and 'Locked in place (//jhud unlock to move it again).' or 'Unlocked: drag to move.')
        save()
    elseif cmd == 'pos' and not args[1] then
        msg(('Position %d, %d.%s'):format(settings.pos.x, settings.pos.y,
            settings.locked and ' Locked: //jhud unlock to drag it.' or ' Drag it with the left mouse button.'))
    elseif cmd == 'pos' and tonumber(args[1]) and tonumber(args[2]) then
        settings.pos.x, settings.pos.y = tonumber(args[1]), tonumber(args[2])
        save()
    elseif cmd == 'size' and tonumber(args[1]) then
        settings.size = tonumber(args[1])
        save() rebuild()
    elseif cmd == 'font' and args[1] then
        settings.font = table.concat(args, ' ')
        save() rebuild()
    elseif cmd == 'layout' then
        local L = settings.layout
        local w, h = display.size()
        msg(('Panel %sx%s px on every job: rows %d chars x %s lines, grid %dx%d = %d cells (%s).'):format(
            tostring(w or '?'), tostring(h or '?'), L.width, (tonumber(L.lines) or 0) > 0 and L.lines or 'auto',
            L.columns, L.grid_rows, L.columns * L.grid_rows, settings.grid.enabled and settings.grid.position or 'off'))
    elseif cmd == 'gridsize' or cmd == 'cols' then
        msg('The grid is always 4 x 4.')
    elseif cmd == 'width' and tonumber(args[1]) then
        settings.layout.width = math.max(16, math.min(80, math.floor(tonumber(args[1]))))
        save() display.invalidate()
    elseif cmd == 'lines' and args[1] then
        local n = tonumber(args[1])
        settings.layout.lines = n and n >= 1 and math.min(40, math.floor(n)) or 0   -- 0 = auto
        msg('Row lines: ' .. (settings.layout.lines > 0 and settings.layout.lines or 'auto (fit the grid)'))
        save() display.invalidate()
    elseif cmd == 'timer' or cmd == 'timers' then
        local a = (args[1] or ''):lower()
        if a == '' or a == 'list' then
            if #timer_order == 0 then msg('No timers. Usage: timer <label> <m:ss | seconds | 10m>') return end
            for _, k in ipairs(timer_order) do msg(k .. ': ' .. fmt_time(math.max(timers[k].ends - os.time(), 0))) end
            return
        end
        if a == 'clear' then
            local label = table.concat(args, ' ', 2)
            if label ~= '' then
                timers[label] = nil
                for i, k in ipairs(timer_order) do if k == label then table.remove(timer_order, i) break end end
            else
                timers, timer_order = {}, {}
            end
            return
        end
        local spec = args[#args]
        local label = table.concat(args, ' ', 1, #args - 1)
        local secs
        local h, m, sec = spec:match('^(%d+):(%d+):(%d+)$')
        if h then secs = h * 3600 + m * 60 + sec
        else
            m, sec = spec:match('^(%d+):(%d+)$')
            if m then secs = m * 60 + sec
            else
                local num, unit = spec:match('^(%d+)([smh]?)$')
                if num then secs = tonumber(num) * (unit == 'm' and 60 or unit == 'h' and 3600 or 1) end
            end
        end
        if not secs or label == '' then msg('Usage: timer <label> <m:ss | seconds | 10m>') return end
        if not timers[label] then timer_order[#timer_order + 1] = label end
        timers[label] = { ends = os.time() + secs }
        msg(('Timer %s: %s'):format(label, fmt_time(secs)))
    elseif cmd == 'cell' and tonumber(args[1]) then
        settings.grid.cell_chars = math.max(3, math.floor(tonumber(args[1])))
        save() rebuild()
    elseif cmd == 'grid' then
        local a = (args[1] or ''):lower()
        if a == 'sub' then
            local b = (args[2] or ''):lower()
            settings.grid.sub_position = (b == 'after' or b == 'bottom') and b
                or (settings.grid.sub_position == 'bottom' and 'after' or 'bottom')
            msg('Support-job cells: ' .. (settings.grid.sub_position == 'bottom' and 'bottom row.' or 'right after the job\'s cells.'))
        else
            msg('The grid is always shown, 4 x 4, beside the rows. (grid sub bottom|after: where support-job cells go)')
            return
        end
        save() display.invalidate()
    elseif cmd == 'rows' then
        local cfg = job_cfg(true)
        if #args == 0 then msg('Rows: ' .. data.join(ordered_rows(cfg.rows)) .. '   (available: ' .. table.concat(ROW_NAMES, ', ') .. ')') return end
        cfg.rows = table.concat(args, ' '):gsub('%s', '')
        save()
    elseif cmd == 'row' then
        local cfg = job_cfg(true)
        edit_list(function() return cfg.rows end, function(v) cfg.rows = v end, args, 'Rows')
    elseif cmd == 'cd' or cmd == 'cooldown' or cmd == 'cooldowns' then
        local cfg = job_cfg(true)
        edit_list(function() return cfg.cooldowns end, function(v) cfg.cooldowns = v end, args, 'Cooldowns')
    elseif cmd == 'sub' then
        local sj = player.sub_job
        if not sj then msg('No support job.') return end
        edit_list(function() return settings.subjobs[sj] or '' end, function(v) settings.subjobs[sj] = v end, args, sj .. ' subjob cells')
    elseif cmd == 'danger' then
        local cfg = job_cfg(true)
        local a = (args[1] or ''):lower()
        if a == 'off' then cfg.danger = 0
        elseif tonumber(a) then cfg.danger = math.max(0, math.min(99, math.floor(tonumber(a))))
        else msg('Usage: danger <HP%> | danger off   (now ' .. tostring(cfg.danger or 0) .. ')') return end
        msg(player.main_job .. ': ' .. ((cfg.danger or 0) > 0 and ('frame flashes red under ' .. cfg.danger .. '% HP.') or 'HP alarm off.'))
        save()
    elseif cmd == 'petalarm' then
        local cfg = job_cfg(true)
        local a = (args[1] or ''):lower()
        if a == 'off' then cfg.pet_alarm = 0
        elseif tonumber(a) then cfg.pet_alarm = math.max(0, math.min(99, math.floor(tonumber(a))))
        else msg('Usage: petalarm <HP%> | petalarm off   (now ' .. tostring(cfg.pet_alarm or 0) .. ')') return end
        msg(player.main_job .. ': ' .. ((cfg.pet_alarm or 0) > 0 and ('pet line flashes under ' .. cfg.pet_alarm .. '% pet HP.') or 'pet HP alarm off.'))
        save()
    elseif cmd == 'compact' then
        -- //jhud compact [on|off]: grid plus a narrow column of stances / shadows etc.
        -- //jhud compact rows [add|remove|move|clear ...]: this job's compact rows (clear = automatic).
        local a = (args[1] or ''):lower()
        if a == 'rows' then
            local cfg = job_cfg(true)
            table.remove(args, 1)
            if #args == 0 then
                msg(player.main_job .. ' compact rows: ' .. table.concat(compact_rows(cfg, data.split(cfg.right or '')), ', ')
                    .. ((cfg.compact or '') == '' and '  (automatic)' or ''))
                return
            end
            if (cfg.compact or '') == '' and args[1]:lower() ~= 'clear' then
                cfg.compact = table.concat(compact_rows(cfg, data.split(cfg.right or '')), ',')   -- start from what's shown
            end
            edit_list(function() return cfg.compact or '' end, function(v) cfg.compact = v end, args, 'Compact rows')
            return
        end
        if a == 'on' then settings.compact_mode = true
        elseif a == 'off' then settings.compact_mode = false
        elseif a == '' or a == 'toggle' then settings.compact_mode = not settings.compact_mode
        else msg('Usage: compact [on|off] | compact rows [add|remove|move|clear <row>]') return end
        msg('Compact mode ' .. (settings.compact_mode and 'on: grid plus stances, shadows and the like.' or 'off.'))
        save() rebuild()
    elseif cmd == 'highlight' then
        local cfg = job_cfg(true)
        edit_list(function() return cfg.highlight or '' end, function(v) cfg.highlight = v end, args, 'Highlight')
    elseif cmd == 'partywindow' or cmd == 'pw' then
        -- on / off: for the job you're on (each job remembers its own; RDM starts on).
        local v = args[1] and args[1]:lower()
        if v == 'reset' then
            -- Put it back beside the main window (it follows the main window again).
            settings.party_window_docked = true
            display.party_refresh()
            save()
            msg('Party window back beside the main window.')
            return
        end
        if v == 'hide' or v == 'unhide' then
            -- //jhud pw hide <Buff|Storms> <Name|p1..p5|all...>   /   pw unhide <Buff|Storms> [<Name|pN...>]
            local buff = args[2]
            if not buff then
                msg('Hidden in the party window (p0 = you, p1-p5 = party slots):')
                for _, item in ipairs(data.split(settings.party_window_hide or '')) do msg('  ' .. item) end
                msg('Change: //jhud pw hide <Buff|Storms> <Name|p1..p5|all>   //jhud pw unhide <Buff|Storms> [<Name|pN>]')
                return
            end
            local who = {}
            for i = 3, #args do who[#who + 1] = args[i]:lower():match('^p%d$') and args[i]:lower() or args[i] end
            local current, keep = {}, {}
            for _, item in ipairs(data.split(settings.party_window_hide or '')) do
                local b, w = item:match('^(.-)%s*=%s*(.+)$')
                if b and b:lower() == buff:lower() then
                    for x in w:gmatch('[^%s/]+') do current[#current + 1] = x end
                else keep[#keep + 1] = item end
            end
            local name = buff:sub(1, 1):upper() .. buff:sub(2):lower()
            local list = {}
            if v == 'hide' then
                if #who == 0 then msg('Usage: //jhud pw hide <Buff|Storms> <Name|p1..p5|all>') return end
                local seen = {}
                for _, x in ipairs(current) do if not seen[x:lower()] then seen[x:lower()] = true list[#list + 1] = x end end
                for _, x in ipairs(who) do if not seen[x:lower()] then seen[x:lower()] = true list[#list + 1] = x end end
            elseif #who > 0 then
                local drop = {}
                for _, x in ipairs(who) do drop[x:lower()] = true end
                for _, x in ipairs(current) do if not drop[x:lower()] then list[#list + 1] = x end end
            end
            if #list > 0 then keep[#keep + 1] = name .. '=' .. table.concat(list, ' ') end
            settings.party_window_hide = table.concat(keep, ',')
            msg(#list > 0 and (name .. ' hidden on: ' .. table.concat(list, ' ')) or (name .. ' shown on everyone again.'))
            save()
            return
        end
        if v == 'for' then
            -- //jhud pw for <Buff> <jobs / names...> | all     (which members a buff shows on)
            local buff = args[2]
            if not buff then
                msg('Party window buffs by job / player (others show on everyone):')
                for _, item in ipairs(data.split(settings.party_window_for or '')) do msg('  ' .. item) end
                msg('Change: //jhud pw for <Buff> <JOB JOB Name...>   or   //jhud pw for <Buff> all')
                return
            end
            local who = {}
            for i = 3, #args do who[#who + 1] = args[i] end
            local keep = {}
            for _, item in ipairs(data.split(settings.party_window_for or '')) do
                local b = item:match('^(.-)%s*=')
                if not b or b:lower() ~= buff:lower() then keep[#keep + 1] = item end
            end
            local name = buff:sub(1, 1):upper() .. buff:sub(2):lower()
            if #who > 0 and who[1]:lower() ~= 'all' then
                for i, w in ipairs(who) do who[i] = (#w == 3 and w:upper()) or w end
                keep[#keep + 1] = name .. '=' .. table.concat(who, ' ')
                msg(name .. ' now shows on: ' .. table.concat(who, ' '))
            else
                msg(name .. ' now shows on everyone.')
            end
            settings.party_window_for = table.concat(keep, ',')
            save()
            return
        end
        local cfg = job_cfg(true)
        if v == 'on' or v == 'off' then cfg.party_window = v == 'on'
        elseif not v or v == 'toggle' then cfg.party_window = not party_window_on()
        elseif tonumber(v) then settings.party_window_width = math.max(16, math.floor(tonumber(v)))
        else msg('Usage: //jhud partywindow [on|off|<width>]') return end
        msg(('Party window: %s for %s (shows the buffs you can cast on each member).'):format(
            party_window_on() and 'on' or 'off', player and player.main_job or 'this job'))
        save()
    elseif cmd == 'party' then
        local cfg = job_cfg(true)
        edit_list(function() return cfg.party or '' end, function(v) cfg.party = v end, args, 'Party')
    elseif cmd == 'stats' then
        if (args[1] or ''):lower() == 'reset' then
            data.reset_stats()
            msg('Session stats reset.')
            return
        end
        print_stats()
    elseif cmd == 'clickuse' or cmd == 'click' then
        settings.click_to_use = on_off((args[1] or ''):lower(), settings.click_to_use)
        msg('Click to use ' .. (settings.click_to_use and 'on: click a grid cell to use that ability or spell.' or 'off.'))
        save()
    elseif cmd == 'tooltips' or cmd == 'tips' then
        settings.tooltips = on_off((args[1] or ''):lower(), settings.tooltips)
        if not settings.tooltips then display.tip(nil) end
        msg('Hover details ' .. (settings.tooltips and 'on.' or 'off.'))
        save()
    elseif cmd == 'idle' then
        local a = (args[1] or ''):lower()
        if a == 'off' then settings.idle_opacity = 100
        elseif tonumber(a) then settings.idle_opacity = math.max(0, math.min(100, math.floor(tonumber(a))))
            if tonumber(args[2]) then settings.idle_delay = math.max(0, tonumber(args[2])) end
        else msg(('Usage: idle <opacity 0-100> [seconds] | idle off   (now %s%% after %ss)'):format(
            tostring(settings.idle_opacity), tostring(settings.idle_delay))) return end
        msg(settings.idle_opacity >= 100 and 'Idle fade off.' or
            ('The grid fades to %d%% after %ss out of combat.'):format(settings.idle_opacity, tostring(settings.idle_delay)))
        save()
    elseif cmd == 'theme' then
        local t = (args[1] or ''):lower()
        if not themes.themes[t] then msg('Themes: lattice, light, contrast. Now: ' .. tostring(settings.theme)) return end
        settings.theme = t
        msg('Theme: ' .. t)
        save() rebuild()
    elseif cmd == 'palette' or cmd == 'colorblind' or cmd == 'colourblind' then
        local p = themes.palette_alias[(args[1] or ''):lower()]
        if not p then msg('Colours: //jhud look normal | redgreen | deut | trit   (redgreen: protanopia, deut: deuteranopia, trit: tritanopia). Now: ' .. tostring(settings.palette)) return end
        settings.palette = p
        msg('Palette: ' .. p)
        save() rebuild()
    elseif cmd == 'opacity' and tonumber(args[1]) then
        settings.opacity = math.max(0, math.min(100, math.floor(tonumber(args[1]))))
        msg('Opacity: ' .. settings.opacity .. '%')
        save() rebuild()
    elseif cmd == 'right' then
        local cfg = job_cfg(true)
        edit_list(function() return cfg.right or '' end, function(v) cfg.right = v end, args, 'Rows')
    elseif cmd == 'debuff' or cmd == 'debuffs' then
        local cfg = job_cfg(true)
        local sub = (args[1] or ''):lower()
        local name = table.concat(args, ' ', 2)
        if sub == 'add' and not data.debuff_base(name) then
            msg('Debuff timers available: Angon, Tomahawk, Gambit, Rayke') return
        end
        edit_list(function() return cfg.debuffs or '' end, function(v) cfg.debuffs = v end, args, 'Debuffs')
    elseif cmd == 'rwidth' and tonumber(args[1]) then
        settings.layout.right_width = math.max(0, math.min(60, math.floor(tonumber(args[1]))))
        save() display.invalidate()
    elseif cmd == 'upkeep' or cmd == 'keep' then
        local cfg = job_cfg(true)
        edit_list(function() return cfg.upkeep or '' end, function(v) cfg.upkeep = v end, args, 'Upkeep')
    elseif cmd == 'buff' or cmd == 'buffs' then
        local cfg = job_cfg(true)
        edit_list(function() return cfg.buffs end, function(v) cfg.buffs = v end, args, 'Buffs')
    elseif cmd == 'header' then
        if #args == 0 then msg('Header: ' .. data.join(data.split(settings.header))) return end
        settings.header = table.concat(args, ' '):gsub('%s', '')
        save() display.invalidate()
    elseif cmd == 'soon' and tonumber(args[1]) then
        settings.soon_seconds = tonumber(args[1])
        if tonumber(args[2]) then settings.soon_pct = tonumber(args[2]) end
        msg(('Orange at %ds or %d%% of the recast left.'):format(settings.soon_seconds, settings.soon_pct * 100))
        save()
    elseif cmd == 'announce' then
        settings.announce_ready = on_off(args[1], settings.announce_ready)
        msg('Ready announcements ' .. (settings.announce_ready and 'on.' or 'off.'))
        save()
    elseif cmd == 'hideunavail' then
        settings.hide_unavailable = on_off(args[1], settings.hide_unavailable)
        save()
    elseif cmd == 'activecells' or cmd == 'purple' then
        settings.active_cells = on_off((args[1] or ''):lower(), settings.active_cells)
        msg('One-use abilities turn purple while their effect waits on you: ' .. (settings.active_cells and 'on.' or 'off (only the job\'s highlight list).'))
        save()
    elseif cmd == 'distance' then
        settings.target_distance = on_off(args[1], settings.target_distance)
        msg('Target distance ' .. (settings.target_distance and 'on.' or 'off.'))
        save()
    elseif cmd == 'hidemissing' then
        settings.hide_missing_buffs = on_off(args[1], settings.hide_missing_buffs)
        save()
    elseif cmd == 'note' then
        local key = args[1]
        if not key then msg('Usage: note <key> <value> | note clear [key]') return end
        if key:lower() == 'clear' then
            if args[2] then
                notes[args[2]] = nil
                for i, k in ipairs(note_order) do if k == args[2] then table.remove(note_order, i) break end end
            else
                notes, note_order = {}, {}
            end
            return
        end
        local value = table.concat(args, ' ', 2)
        if value == '' then
            notes[key] = nil
            for i, k in ipairs(note_order) do if k == key then table.remove(note_order, i) break end end
        else
            if not notes[key] then note_order[#note_order + 1] = key end
            notes[key] = value
        end
    elseif cmd == 'copyjob' and args[1] then
        local from = args[1]:upper()
        if not settings.jobs[from] then msg('No settings for ' .. from) return end
        settings.jobs[player.main_job] = deepcopy(settings.jobs[from])
        msg('Copied ' .. from .. ' setup to ' .. player.main_job .. '.')
        job_key = nil
        save()
    elseif cmd == 'import' and args[1] then
        local other = args[1]:sub(1, 1):upper() .. args[1]:sub(2):lower()
        local path = 'data/' .. other .. '.xml'
        if not files.new(path):exists() then msg('No settings file for ' .. other) return end
        local theirs = config.load(path, defaults)
        local pos = deepcopy(settings.pos)
        for k, v in pairs(theirs) do settings[k] = deepcopy(v) end
        settings.pos = pos
        msg('Imported ' .. other .. '\'s setup.')
        save() rebuild()
    elseif cmd == 'reset' then
        local what = (args[1] or ''):lower()
        if what == 'job' then
            local job = player.main_job
            settings.jobs[job] = deepcopy(defaults.jobs[job] or defaults.jobs.DEFAULT)
            msg(job .. ' reset to defaults.')
            job_key = nil
        elseif what == 'pw' or what == 'partywindow' then
            settings.party_window_docked = true
            display.party_refresh()
            msg('Party window back beside the main window.')
        elseif what == 'all' then
            local pos = deepcopy(settings.pos)
            for k, v in pairs(defaults) do settings[k] = deepcopy(v) end
            settings.pos = pos
            msg('All settings reset (position kept).')
            rebuild()
        else
            msg('Usage: reset job | reset pw | reset all') return
        end
        save()
    elseif cmd == 'reload' then
        -- Reload the whole addon (same as //lua reload Job-HUD): picks up new files and
        -- re-reads the settings file.
        msg('Reloading...')
        windower.send_command('lua reload ' .. _addon.name)
    elseif cmd == 'save' then
        save()
        msg('Saved to data/' .. char_name .. '.xml')
    else
        if cmd ~= '' then msg('Unknown command: ' .. cmd) end
        show_help()
    end
end)

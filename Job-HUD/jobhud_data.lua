--[[
    Job-HUD: game data lookups and trackers.

    Name resolution for abilities, spells and buffs; buff durations from the server's buff
    packet (0x063); Phantom Roll numbers from action packets; and charge timing for charged
    abilities (Stratagems, Quick Draw, Ready).
]]

local res = require('resources')

local data = {}

local ELEMENT_COLORS = {
    Fire    = { red = 255, green = 95,  blue = 70 },
    Ice     = { red = 130, green = 210, blue = 255 },
    Wind    = { red = 110, green = 230, blue = 120 },
    Earth   = { red = 215, green = 175, blue = 95 },
    Thunder = { red = 200, green = 130, blue = 255 },
    Water   = { red = 80,  green = 140, blue = 255 },
    Light   = { red = 255, green = 250, blue = 210 },
    Dark    = { red = 160, green = 110, blue = 190 },
}
data.ELEMENT_COLORS = ELEMENT_COLORS

-- Rune -> its own element, the element it raises resistance to, and the status ailments of
-- that element it also resists while Pflug is up (10% per rune; BG Wiki, "Pflug").
data.RUNES = {
    { name = 'Ignis',    element = 'Fire',    resists = 'Ice',     ailments = 'Paralyze, Bind' },
    { name = 'Gelus',    element = 'Ice',     resists = 'Wind',    ailments = 'Silence, Gravity' },
    { name = 'Flabra',   element = 'Wind',    resists = 'Earth',   ailments = 'Petrify, Slow' },
    { name = 'Tellus',   element = 'Earth',   resists = 'Thunder', ailments = 'Stun' },
    { name = 'Sulpor',   element = 'Thunder', resists = 'Water',   ailments = 'Poison' },
    { name = 'Unda',     element = 'Water',   resists = 'Fire',    ailments = 'Amnesia, Plague' },
    { name = 'Lux',      element = 'Light',   resists = 'Dark',    ailments = 'Blind, Curse, Sleep' },
    { name = 'Tenebrae', element = 'Dark',    resists = 'Light',   ailments = 'Charm, Sleep' },
}

data.MANEUVERS = {
    { name = 'Fire Maneuver',    element = 'Fire' },
    { name = 'Ice Maneuver',     element = 'Ice' },
    { name = 'Wind Maneuver',    element = 'Wind' },
    { name = 'Earth Maneuver',   element = 'Earth' },
    { name = 'Thunder Maneuver', element = 'Thunder' },
    { name = 'Water Maneuver',   element = 'Water' },
    { name = 'Light Maneuver',   element = 'Light' },
    { name = 'Dark Maneuver',    element = 'Dark' },
}

-- Job abilities that come from merits (Group 2): until you've merited one, its grid cell is
-- left empty instead of showing a grey square.
data.MERIT_JA = {}
for _, n in ipairs({
    "Warrior's Charge", 'Tomahawk', 'Formless Strikes', 'Mantra', 'Martyr', 'Devotion',
    "Assassin's Charge", 'Feint', 'Fealty', 'Chivalry', 'Diabolic Eye', 'Nether Void',
    'Feral Howl', 'Killer Instinct', 'Nightingale', 'Troubadour', 'Stealth Shot', 'Flashy Shot',
    'Shikikoyo', 'Blade Bash', 'Deep Breathing', 'Angon', 'Convergence', 'Diffusion',
    'Snake Eye', 'Fold', 'Role Reversal', 'Ventriloquy', 'Saber Dance', 'Fan Dance',
    'No Foot Rise', 'Altruism', 'Focalization', 'Tranquility', 'Equanimity', 'Enlightenment',
}) do data.MERIT_JA[n] = true end

-- Lucky / unlucky numbers, by roll name (without " Roll").
data.ROLL_LUCK = {
    ["Allies'"] = {3, 10},     ["Avenger's"] = {4, 8},   ['Beast'] = {4, 8},
    ["Blitzer's"] = {4, 9},    ["Bolter's"] = {3, 9},    ["Caster's"] = {2, 7},
    ['Chaos'] = {4, 8},        ['Choral'] = {2, 6},      ["Companion's"] = {2, 10},
    ["Corsair's"] = {5, 9},    ["Courser's"] = {3, 9},   ["Dancer's"] = {3, 7},
    ['Drachen'] = {4, 8},      ["Evoker's"] = {5, 9},    ["Fighter's"] = {5, 9},
    ["Gallant's"] = {3, 7},    ["Healer's"] = {3, 7},    ["Hunter's"] = {4, 8},
    ["Magus's"] = {2, 6},      ["Miser's"] = {5, 7},     ["Monk's"] = {3, 7},
    ["Naturalist's"] = {3, 7}, ['Ninja'] = {4, 8},       ['Puppet'] = {3, 7},
    ["Rogue's"] = {5, 9},      ["Runeist's"] = {4, 8},   ['Samurai'] = {2, 6},
    ["Scholar's"] = {2, 6},    ["Tactician's"] = {5, 8}, ["Warlock's"] = {4, 8},
    ["Wizard's"] = {5, 9},
}

------------------------------------------------------------------------------------------
-- Name indexes
------------------------------------------------------------------------------------------

local ja_by_name, spell_by_name, buff_by_name = {}, {}, {}
local recast_group = {}   -- ability recast id -> list of ability ids sharing it
local roll_ids = {}       -- ability id -> roll name (without " Roll")

local function en(entry) return entry.en or entry.english or entry.name end

do
    for id, ja in pairs(res.job_abilities) do
        local name = en(ja)
        if name then
            local key = name:lower()
            -- Prefer the player's version over a pet command that happens to share a name.
            if not ja_by_name[key] or (ja.prefix == '/jobability' and ja_by_name[key].prefix ~= '/jobability') then
                ja_by_name[key] = ja
            end
            if ja.recast_id then
                recast_group[ja.recast_id] = recast_group[ja.recast_id] or {}
                table.insert(recast_group[ja.recast_id], id)
            end
            if ja.type == 'CorsairRoll' then
                roll_ids[id] = name:gsub(' Roll$', '')
            end
        end
    end
    for _, sp in pairs(res.spells) do
        local name = en(sp)
        if name and not spell_by_name[name:lower()] then spell_by_name[name:lower()] = sp end
    end
    for id, b in pairs(res.buffs) do
        local name = en(b)
        if name then
            local key = name:lower()
            -- Several buffs share a name; keep the lowest id, which is the common one.
            if not buff_by_name[key] or id < buff_by_name[key].id then buff_by_name[key] = b end
        end
    end
end

-- Every buff id with this name (Haste, for one, has two).
local buff_ids_cache = {}
function data.buff_ids(name)
    local key = name and name:lower()
    if not key then return {} end
    if buff_ids_cache[key] then return buff_ids_cache[key] end
    local ids = {}
    for id, b in pairs(res.buffs) do
        local n = en(b)
        if n and n:lower() == key then ids[#ids + 1] = id end
    end
    table.sort(ids)
    buff_ids_cache[key] = ids
    return ids
end

-- Roll buff ids (any Phantom Roll), for the ROLL party tag.
function data.roll_buff_ids()
    local ids = {}
    for name in pairs(data.ROLL_LUCK) do
        local id = data.buff_id(name .. ' Roll')
        if id then ids[#ids + 1] = id end
    end
    return ids
end

-- One-use abilities: their effect waits on you until your next action spends it (next spell,
-- next weapon skill, next roll...). Their grid cells turn the 'buffed' colour while it's up.
-- The buff has the ability's name in every case here.
local ONE_USE = {
    "Warrior's Charge", 'Embolden', 'Saboteur', 'Stymie', 'Spontaneity', 'Sekkanoki', 'Sengikori',
    'Sneak Attack', 'Trick Attack', 'Divine Seal', 'Elemental Seal', 'Divine Caress', 'Divine Emblem',
    'Nether Void', 'Dark Seal', 'Manawell', 'Cascade', 'Futae', 'Burst Affinity', 'Chain Affinity',
    'Efflux', 'Diffusion', 'Convergence', 'Marcato', 'Pianissimo', 'Tenuto', 'Barrage',
    'Unlimited Shot', 'Crooked Cards', 'Snake Eye', 'Climactic Flourish', 'Building Flourish',
    'Ternary Flourish', 'Presto', 'Apogee', 'Entrust', 'Blaze of Glory', 'Theurgic Focus',
}
-- Stratagems share one cell (recast 231): any of them up lights it.
local STRATAGEMS = { 'Rapture', 'Ebullience', 'Accession', 'Manifestation', 'Perpetuance', 'Immanence',
    'Penury', 'Parsimony', 'Celerity', 'Alacrity', 'Altruism', 'Focalization', 'Tranquility', 'Equanimity' }
local stratagem_set = {}
for _, n in ipairs(STRATAGEMS) do stratagem_set[n:lower()] = true end
local one_use_set = {}
for _, n in ipairs(ONE_USE) do one_use_set[n:lower()] = true end

-- Buff ids that mean this one-use ability's effect is waiting on you; nil if it isn't one-use.
function data.one_use_ids(name, recast_id)
    -- Stratagems share one timer, so each cell checks only its own effect.
    if recast_id == 231 and name and stratagem_set[name:lower()] then return data.buff_ids(name) end
    if name and one_use_set[name:lower()] then return data.buff_ids(name) end
end

-- Runes you're harbouring right now (all elements together).
function data.rune_count(counts)
    local n = 0
    for _, d in ipairs(data.RUNES) do
        local id = data.buff_id(d.name)
        if id and counts[id] then n = n + counts[id] end
    end
    return n
end

function data.buff_id(name)
    local b = name and buff_by_name[name:lower()]
    return b and b.id
end

function data.buff_name(id)
    local b = res.buffs[id]
    return b and en(b) or tostring(id)
end

function data.item_name(id)
    local it = res.items[id]
    return it and en(it) or ('#' .. tostring(id))
end

function data.recast_group(recast_id)
    return recast_group[recast_id] or {}
end

-- 'Haste II|Haste' -> every alternative that resolves, in order (first = preferred).
function data.resolve_alts(name)
    local out = {}
    for part in tostring(name):gmatch('[^|]+') do
        local r = data.resolve((part:gsub('^%s+', ''):gsub('%s+$', '')))
        if r then out[#out + 1] = r end
    end
    return out
end

-- Ability or spell by name: { kind = 'ja'|'spell', id, recast_id, name, status }.
-- Abilities win when a name exists as both.
function data.resolve(name)
    if not name or name == '' then return nil end
    local key = name:lower()
    local ja = ja_by_name[key]
    -- Pet moves share names with spells: BST Ready moves with Blue Magic (Jettatura, Geist Wall),
    -- avatar Blood Pacts with White Magic (Raise II). For those the spell is the one you'd track.
    if ja and ja.prefix == '/pet' and ja.type ~= 'PetCommand' and spell_by_name[key] then ja = nil end
    if ja then
        return { kind = 'ja', id = ja.id, recast_id = ja.recast_id, name = en(ja), status = ja.status,
                 prefix = ja.prefix, type = ja.type }
    end
    local sp = spell_by_name[key]
    if sp then
        return { kind = 'spell', id = sp.id, recast_id = sp.recast_id or sp.id, name = en(sp),
                 status = sp.status, levels = sp.levels }
    end
    return nil
end

------------------------------------------------------------------------------------------
-- Lists from settings
------------------------------------------------------------------------------------------

local function trim(s) return (s:gsub('^%s+', ''):gsub('%s+$', '')) end
data.trim = trim

-- 'A,B=Name,C' -> { 'A', 'B=Name', 'C' } with blanks removed.
function data.split(str)
    local out = {}
    if type(str) == 'table' then
        for _, v in ipairs(str) do
            v = trim(tostring(v))
            if v ~= '' then out[#out + 1] = v end
        end
        return out
    end
    for part in tostring(str or ''):gmatch('[^,]+') do
        part = trim(part)
        if part ~= '' then out[#out + 1] = part end
    end
    return out
end

function data.join(list) return table.concat(list, ',') end

-- 'LABEL=Name' -> label, name. With no label, one is made from the name.
function data.label_split(entry)
    local label, name = entry:match('^([^=]+)=(.+)$')
    if label then return trim(label), trim(name) end
    return nil, entry
end

function data.auto_label(name, width)
    width = width or 4
    local words = {}
    for w in name:gmatch('[%w\']+') do words[#words + 1] = w end
    local label
    if #words <= 1 then
        label = name:gsub('[^%w]', ''):sub(1, width)
    else
        label = ''
        for _, w in ipairs(words) do label = label .. w:sub(1, 1) end
        if #label < 3 then label = words[1]:sub(1, 2) .. words[2]:sub(1, 1) end
    end
    return label:upper():sub(1, width)
end

-- 'Penury:5:48,Fire Shot:2' -> { [recast_id] = { max = 5, time = 48 } }
function data.parse_charges(str)
    local out = {}
    for _, part in ipairs(data.split(str)) do
        local name, max, t = part:match('^([^:]+):(%d+):?(%d*)$')
        local r = name and data.resolve(trim(name))
        if r and r.kind == 'ja' then
            out[r.recast_id] = { max = tonumber(max), time = tonumber(t) }
        end
    end
    return out
end

------------------------------------------------------------------------------------------
-- Buff durations (packet 0x063, type 9)
------------------------------------------------------------------------------------------

-- The packet's buff end times are in 1/60 s from 2002-01-01 (Unix 1009810800), in a 32-bit
-- counter that wraps every ~2.27 years. The right wrap is the one that puts the end time
-- nearest to now, since no buff lasts anywhere near a year.
local BASE = 1009810800
local WRAP = 0x100000000 / 60
local buff_slots = {}  -- { { id = buff id, ends = unix time or nil } }

local function buff_end(raw)
    local t = BASE + raw / 60
    local k = math.floor((os.time() - t) / WRAP + 0.5)
    return t + k * WRAP
end

function data.on_0x063(packet)
    if packet:byte(0x05) ~= 0x09 then return end
    local slots = {}
    for i = 1, 32 do
        local id = packet:unpack('H', i * 2 + 7)
        if id ~= 255 and id ~= 0 then
            local ends = buff_end(packet:unpack('I', i * 4 + 0x45))
            local left = ends - os.time()
            -- Permanent buffs carry a meaningless far-off time.
            if left < -5 or left > 86400 then ends = nil end
            slots[#slots + 1] = { id = id, ends = ends }
        end
    end
    buff_slots = slots
end

function data.clear_buffs() buff_slots = {} end

-- Master Level, from the character stats packet (0x061, byte 0x65).
data.master_level = 0
function data.on_0x061(packet)
    if #packet >= 0x66 then data.master_level = packet:byte(0x66) or 0 end
end

-- Seconds left on the soonest-expiring copy of a buff, or nil if unknown.
function data.buff_remaining(id)
    local now, best = os.time(), nil
    for _, s in ipairs(buff_slots) do
        if s.id == id and s.ends then
            local left = math.max(s.ends - now, 0)
            if not best or left < best then best = left end
        end
    end
    return best
end

-- { [buff id] = count } from the player's buff list.
function data.count_buffs(list)
    local counts = {}
    for _, id in ipairs(list or {}) do
        if id and id ~= 255 then counts[id] = (counts[id] or 0) + 1 end
    end
    return counts
end

------------------------------------------------------------------------------------------
-- Pet TP (packets 0x068, and 0x067 type 4). The game only tells the owner.
------------------------------------------------------------------------------------------

data.pet = {}  -- { index = pet mob index, tp = number }

function data.on_pet_packet(id, packet, me)
    if not me then return end
    if id == 0x068 then
        if packet:unpack('I', 0x09) ~= me.id then return end
        local target = packet:unpack('I', 0x15)
        data.pet = { index = packet:unpack('H', 0x0D), tp = packet:unpack('I', 0x11),
                     target = target ~= 0 and target or nil }
    elseif id == 0x067 then
        if packet:byte(0x05) % 64 ~= 4 or packet:unpack('H', 0x0D) ~= me.index then return end
        data.pet = { index = packet:unpack('H', 0x07), tp = packet:unpack('I', 0x11) }
    end
end

-- Pet TP if the packet was about this pet.
function data.pet_tp(mob)
    if mob and data.pet.index and mob.index == data.pet.index then return data.pet.tp end
end

------------------------------------------------------------------------------------------
-- Phantom Roll numbers
------------------------------------------------------------------------------------------

data.rolls = {}  -- roll name -> { value, at }
local last_roll

------------------------------------------------------------------------------------------
-- Last weapon skill: name, damage, and the skillchain it closed (if any)
------------------------------------------------------------------------------------------

local SKILLCHAINS = {
    [288] = 'Light', [289] = 'Darkness', [290] = 'Gravitation', [291] = 'Fragmentation',
    [292] = 'Distortion', [293] = 'Fusion', [294] = 'Compression', [295] = 'Liquefaction',
    [296] = 'Induration', [297] = 'Reverberation', [298] = 'Transfixion', [299] = 'Scission',
    [300] = 'Detonation', [301] = 'Impaction', [302] = 'Cosmic Elucidation',
    [385] = 'Light', [386] = 'Darkness', [387] = 'Gravitation', [388] = 'Fragmentation',
    [389] = 'Distortion', [390] = 'Fusion', [391] = 'Compression', [392] = 'Liquefaction',
    [393] = 'Induration', [394] = 'Reverberation', [395] = 'Transfixion', [396] = 'Scission',
    [397] = 'Detonation', [398] = 'Impaction',
    [767] = 'Radiance', [768] = 'Umbra', [769] = 'Radiance', [770] = 'Umbra',
}
local WS_DAMAGE = { [185] = true, [187] = true, [197] = true, [264] = true }  -- hit / drain / resisted / AoE
-- The weapon skill or skillchain healed the mob instead (it absorbs that element).
local WS_HEAL = { [103] = true, [238] = true }
local SC_HEAL = { [769] = true, [770] = true }
for id = 385, 398 do SC_HEAL[id] = true end

-- Jumps, Shield Bash and other damaging job abilities arrive as the same action category as
-- weapon skills, with an ability id in the same field (Jump is #66, and so is Gale Axe). The
-- message is what tells them apart: only weapon skill messages name a ${weapon_skill}.
local WS_MESSAGE = {}
for id, m in pairs(res.action_messages or {}) do
    local text = m.en or m.english or ''
    if text:find('${weapon_skill}', 1, true) then WS_MESSAGE[id] = true end
end

data.last_ws = nil  -- { name, damage (nil = missed), sc = name, sc_damage, tp }

------------------------------------------------------------------------------------------
-- Session stats (//jhud stats)
------------------------------------------------------------------------------------------

function data.reset_stats()
    data.stats = { start = os.time(), ws = {}, sc = 0, sc_damage = 0, kills = 0 }
end
data.reset_stats()


------------------------------------------------------------------------------------------
-- Weapons with Aftermath (their description mentions it), and item counts
------------------------------------------------------------------------------------------

local am_cache = {}
-- Sublimation bonus of an item, from its description: '"Sublimation"+N' gives N, the older
-- 'Enhances "Sublimation" effect' gives 1 (2 on Argute Gown +2 and Academic's Mortarboard).
local SUBL_ENHANCES = { [10689] = 2, [27683] = 2 }
local subl_cache = {}
function data.sublimation_bonus(item_id)
    if not item_id then return 0 end
    if subl_cache[item_id] == nil then
        local d = res.item_descriptions and res.item_descriptions[item_id]
        local text = d and (d.en or d.english) or ''
        local n = tonumber(text:match('Sublimation"?%s*%+(%d+)'))
        if not n and text:find('Enhances "Sublimation" effect', 1, true) then n = SUBL_ENHANCES[item_id] or 1 end
        subl_cache[item_id] = n or 0
    end
    return subl_cache[item_id]
end

function data.has_aftermath(item_id)
    if not item_id then return false end
    if am_cache[item_id] == nil then
        local d = res.item_descriptions and res.item_descriptions[item_id]
        local text = d and (d.en or d.english) or ''
        am_cache[item_id] = text:find('Aftermath', 1, true) ~= nil
    end
    return am_cache[item_id]
end

-- Aftermath level from your buffs: 1-3, 0 for the plain "Aftermath" (older relics/empyreans),
-- nil if none. Also returns its buff id.
function data.aftermath(counts)
    for lv = 3, 1, -1 do
        if counts[269 + lv] then return lv, 269 + lv end   -- Aftermath: Lv.1-3 are buffs 270-272
    end
    if counts[273] then return 0, 273 end
end

-- What a weapon's Aftermath does at a level, read from its description: a short tag and a
-- longer text. Mythic / Ergon style ("Increases Acc./Atk. Occasionally attacks twice or
-- thrice"): Lv.1 the first stat, Lv.2 the second, Lv.3 the extra attacks / damage. Empyrean
-- ("Occ. deals double damage", "triple damage" on III): Lv.1-2 ODD, Lv.3 OTD. Aeonic: SC/MB
-- (skillchain / magic burst potency, Lv.3 ultimate skillchains). Prime: PDL (physical damage
-- limit). Unknown (e.g. Relic): nil.
local am_kind_cache = {}
local function stat_code(s)
    s = s:lower()
    local mag, rng = s:find('mag') ~= nil, s:find('rng') ~= nil or s:find('ranged') ~= nil
    local acc = s:find('acc') ~= nil
    if mag then return acc and 'MAcc' or 'MAB', acc and 'Magic Accuracy' or 'Magic Attack Bonus' end
    if rng then return acc and 'RAcc' or 'RAtk', acc and 'Ranged Accuracy' or 'Ranged Attack' end
    return acc and 'Acc' or 'Atk', acc and 'Accuracy' or 'Attack'
end
function data.aftermath_kind(item_id, lv)
    if not item_id then return nil end
    local key = item_id .. ':' .. tostring(lv)
    if am_kind_cache[key] ~= nil then return am_kind_cache[key][1], am_kind_cache[key][2] end
    local d = res.item_descriptions and res.item_descriptions[item_id]
    local text = (d and (d.en or d.english) or ''):match('Aftermath:(.*)')
    local kind, full
    if text then
        -- Only the Aftermath part (not Afterglow, Dispense... lines after it).
        text = text:gsub('\n%s*Afterglow.*$', ''):gsub('\n%s*Dispense.*$', '')
        text = text:gsub('\n', ' '):gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
        local low = text:lower()
        if low:find('skillchain') then
            kind, full = 'SC/MB', 'skillchain and magic burst damage up' .. (lv == 3 and ', ultimate skillchains' or '')
        elseif low:find('damage ?l ?imit') then
            kind, full = 'PDL', 'physical damage limit up'
        elseif low:find('^%s*inc') then
            local stats = text:match('^%s*(.-)%s*Occ') or text
            stats = stats:gsub('^Increases%s*', ''):gsub('^Inc%.%s*', '')
            local a, b = stats:match('^(.-)%s*/%s*(.-)%s*$')
            if not a then a, b = stats:match('^(.-)%s+and%s+(.-)%s*$') end
            if lv == 1 and a then kind, full = stat_code(a)
            elseif lv == 2 and b then kind, full = stat_code(b)
            elseif lv == 3 then
                if low:find('double [ot][ro] triple') then kind, full = 'DD/TD', 'occasionally deals double or triple damage'
                elseif low:find('double damage') then kind, full = 'DD', 'occasionally deals double damage'
                elseif low:find('twice or thrice') then kind, full = 'OA2/3', 'occasionally attacks twice or thrice'
                elseif low:find('twice') then kind, full = 'OA2', 'occasionally attacks twice' end
            end
            if kind and lv < 3 then kind, full = kind .. '+', full .. ' up' end
        elseif low:find('triple damage') then
            if lv == 3 then kind, full = 'OTD', 'occasionally deals triple damage'
            else kind, full = 'ODD', 'occasionally deals double damage' end
        elseif low:find('double damage') then
            kind, full = 'ODD', 'occasionally deals double damage'
        elseif text ~= '' then
            full = text   -- e.g. Relic: 'Accuracy+15 Critical hit rate +10%' (no short tag)
        end
    end
    am_kind_cache[key] = { kind, full }
    return kind, full
end

function data.item_id(name)
    for id, it in pairs(res.items) do
        if en(it) == name then return id end
    end
end

-- The ninja toolbag that holds an item ('Shihei' -> 'Toolbag (Shihe)'), or nil. Looked up by the
-- long name ('toolbag (shihei)'), since the short one is cut off.
local toolbag_cache = {}
function data.toolbag_name(name)
    local key = name:lower()
    if toolbag_cache[key] == nil then
        toolbag_cache[key] = false
        for _, it in pairs(res.items) do
            if it.enl and it.enl:lower() == 'toolbag (' .. key .. ')' then toolbag_cache[key] = en(it) break end
        end
    end
    return toolbag_cache[key] or nil
end

local function on_ws(act, tp)
    local first = act.targets and act.targets[1] and act.targets[1].actions and act.targets[1].actions[1]
    if not (first and WS_MESSAGE[first.message]) then return end
    local ws = res.weapon_skills[act.param]
    if not ws then return end
    local total, hit, sc, sc_dmg = 0, false, nil, nil
    local healed, sc_healed = false, false
    for _, t in ipairs(act.targets or {}) do
        for _, a in ipairs(t.actions or {}) do
            if WS_DAMAGE[a.message] or WS_HEAL[a.message] then
                hit = true
                total = total + (a.param or 0)
                if WS_HEAL[a.message] then healed = true end
            end
            if a.has_add_effect and SKILLCHAINS[a.add_effect_message] then
                sc = SKILLCHAINS[a.add_effect_message]
                sc_dmg = (sc_dmg or 0) + (a.add_effect_param or 0)
                if SC_HEAL[a.add_effect_message] then sc_healed = true end
            end
        end
    end
    data.last_ws = { name = en(ws), damage = hit and total or nil, sc = sc, sc_damage = sc_dmg, tp = tp,
                     healed = healed, sc_healed = sc_healed }
    -- Session stats
    local st = data.stats
    local w = st.ws[data.last_ws.name] or { n = 0, hits = 0, total = 0, best = 0 }
    st.ws[data.last_ws.name] = w
    w.n = w.n + 1
    if hit and not healed then
        w.hits = w.hits + 1
        w.total = w.total + total
        if total > w.best then w.best = total end
    end
    if sc and not sc_healed then
        st.sc = st.sc + 1
        st.sc_damage = st.sc_damage + (sc_dmg or 0)
    end
end

function data.on_action(act, player_id, tp)
    if act.actor_id ~= player_id then return end
    if act.category == 3 then return on_ws(act, tp) end
    if act.category ~= 6 then return end
    local roll = roll_ids[act.param]
    if not roll then return end
    local t = act.targets and act.targets[1]
    local a = t and t.actions and t.actions[1]
    if not a then return end
    -- Double-Up reports under the roll's own id, with the new total.
    data.rolls[roll] = { value = a.param, at = os.time() }
    last_roll = roll
end

-- Forget rolls whose buff has worn (with a short grace for the buff to arrive).
function data.prune_rolls(counts)
    local now = os.time()
    for name, r in pairs(data.rolls) do
        local id = data.buff_id(name .. ' Roll')
        if (not id or not counts[id]) and now - r.at > 4 then data.rolls[name] = nil end
    end
end

------------------------------------------------------------------------------------------
-- Charged abilities
------------------------------------------------------------------------------------------

-- Seconds per charge, measured in play (so job points, merits and gear are counted). Kept per
-- character and job in the settings (Job-HUD.lua loads / saves them).
data.learned_charge = {}   -- key (recast id, or '231:5' for stratagems by charges) -> seconds
local learned_charge = data.learned_charge
data.on_learned = nil      -- callback(kind, key, seconds): 'charge' or 'duration' learned / changed
local last_recast = {}     -- recast id -> remaining seen last tick

-- Watch a charged recast for the jump a use causes; that jump is one charge's time.
function data.observe_charge(recast_id, remaining)
    local prev = last_recast[recast_id]
    if prev and remaining > prev + 1 then
        local jump = math.floor(remaining - prev + 0.5)
        if jump >= 3 and learned_charge[recast_id] ~= jump then
            learned_charge[recast_id] = jump
            if data.on_learned then data.on_learned('charge', recast_id, jump) end
        end
    end
    last_recast[recast_id] = remaining
end

function data.charge_time(recast_id, fallback)
    return learned_charge[recast_id] or fallback
end

-- Charges available and seconds to the next one, from the time until all are back.
function data.charges(remaining, max, per)
    if not per or per <= 0 then per = 60 end
    if remaining <= 0 then return max, 0 end
    local missing = math.min(math.ceil(remaining / per - 0.01), max)
    local next_in = remaining - (missing - 1) * per
    return max - missing, math.max(next_in, 0)
end

------------------------------------------------------------------------------------------
-- Skillchain window, per mob, from anyone's weapon skills and skillchains
------------------------------------------------------------------------------------------
-- Timing as in the Skillchains addon (Ivaar): after a weapon skill lands, the next one can
-- skillchain from 3 s later until 10 s after it. Each skillchain opens a new window that is
-- 1 s shorter per step; past step 5, or after Radiance / Umbra, the chain is closed.

local SC_CLOSES = { Radiance = true, Umbra = true }
local WS_OPENS = { [185] = true, [187] = true, [197] = true }  -- weapon skill landed
data.windows = {}  -- mob id -> { open = clock, close = clock, step, closed, sc }

local function track_window(act)
    local now = os.clock()
    for _, t in ipairs(act.targets or {}) do
        for _, a in ipairs(t.actions or {}) do
            local sc = a.has_add_effect and SKILLCHAINS[a.add_effect_message]
            if sc then
                local prev = data.windows[t.id]
                local step = ((prev and now <= prev.close + 1) and prev.step or 1) + 1
                data.windows[t.id] = { open = now + 3, close = now + 3 + 8 - step, step = step,
                                       closed = step > 5 or SC_CLOSES[sc], sc = sc }
            elseif act.category == 3 and WS_OPENS[a.message] then
                data.windows[t.id] = { open = now + 3, close = now + 10, step = 1 }
            end
        end
    end
end

------------------------------------------------------------------------------------------
-- Debuffs you put on a mob (Angon, Tomahawk, Gambit, Rayke...)
------------------------------------------------------------------------------------------
-- Started when your ability lands, ended by the game's "wears off" message (which also
-- teaches the real duration, merits / job points / gear included) or the mob's death.

data.debuffs = {}        -- mob id -> { [name] = { start = clock, status = buff id } }
data.debuff_learned = {} -- name -> seconds, measured from a natural wear-off
data.on_debuff_learned = nil  -- callback(name, seconds)

local DEBUFF_JA = {}     -- ability id -> { name, status, base duration }
for _, n in ipairs({ 'Angon', 'Tomahawk', 'Gambit', 'Rayke' }) do
    local ja = ja_by_name[n:lower()]
    if ja then DEBUFF_JA[ja.id] = { name = n, status = ja.status, base = ja.duration or 30 } end
end
function data.debuff_base(name)
    for _, d in pairs(DEBUFF_JA) do if d.name == name then return d.base end end
end

-- Messages that mean the ability didn't land.
local FAILED = {}
for id, m in pairs(res.action_messages or {}) do
    local text = (m.en or m.english or ''):lower()
    for _, w in ipairs({ 'miss', 'no effect', 'resist', 'evade', 'fail', 'anticipate', 'intimidat' }) do
        if text:find(w, 1, true) then FAILED[id] = true break end
    end
end

local function track_debuff(act, me)
    if act.actor_id ~= me then return end
    if act.category ~= 6 and act.category ~= 14 and act.category ~= 15 then return end
    local d = DEBUFF_JA[act.param]
    if not d then return end
    for _, t in ipairs(act.targets or {}) do
        local a = t.actions and t.actions[1]
        if a and not FAILED[a.message] then
            data.debuffs[t.id] = data.debuffs[t.id] or {}
            data.debuffs[t.id][d.name] = { start = os.clock(), status = d.status }
        end
    end
end

-- Elements a skillchain can be magic burst with.
data.BURST_ELEMENTS = {
    Light = { 'Fire', 'Wind', 'Thunder', 'Light' }, Radiance = { 'Fire', 'Wind', 'Thunder', 'Light' },
    Darkness = { 'Earth', 'Ice', 'Water', 'Dark' }, Umbra = { 'Earth', 'Ice', 'Water', 'Dark' },
    Gravitation = { 'Earth', 'Dark' }, Fragmentation = { 'Wind', 'Thunder' },
    Distortion = { 'Ice', 'Water' }, Fusion = { 'Fire', 'Light' },
    Compression = { 'Dark' }, Liquefaction = { 'Fire' }, Induration = { 'Ice' },
    Reverberation = { 'Water' }, Transfixion = { 'Light' }, Scission = { 'Earth' },
    Detonation = { 'Wind' }, Impaction = { 'Thunder' },
}

-- Who each actor last aimed an action at (melee, TP moves, spells...). Used to tell who a mob
-- is attacking when the game hasn't told us its target directly.
data.last_target = {}

-- Every action, from anyone: skillchain windows, your own debuffs, and who's hitting whom.
-- Mobs hit with Bounty Shot (anyone's): mob id -> true, until it dies or you zone.
data.bounty = {}
local BOUNTY_SHOT = 285
local function track_bounty(act)
    if act.category ~= 6 and act.category ~= 14 and act.category ~= 15 then return end
    if act.param ~= BOUNTY_SHOT then return end
    for _, t in ipairs(act.targets or {}) do
        local a = t.actions and t.actions[1]
        if a and not FAILED[a.message] then data.bounty[t.id] = true end
    end
end

function data.on_any_action(act, me)
    track_window(act)
    track_debuff(act, me)
    track_bounty(act)
    data.dnc_action(act, me)
    data.track_member_buff(act, me)
    local t = act.targets and act.targets[1]
    if t and t.id and t.id ~= act.actor_id then data.last_target[act.actor_id] = t.id end
end

local WEARS = { [204] = true, [206] = true }
local DIES = { [6] = true, [20] = true, [97] = true, [113] = true, [406] = true, [605] = true, [646] = true }

-- Packet 0x029 (action message): wear-offs and deaths.
function data.on_0x029(packet)
    local target = packet:unpack('I', 0x09)
    local param = packet:unpack('I', 0x0D)
    local message = packet:unpack('H', 0x19)
    if WEARS[message] then
        local ms = data.mob_songs[target]
        if ms then ms[param] = nil end
        if data.steps[target] then data.on_daze_worn(target, param) end
        local list = data.debuffs[target]
        if not list then return end
        for name, e in pairs(list) do
            if e.status == param then
                local took = math.floor(os.clock() - e.start + 0.5)
                if took >= 5 then
                    data.debuff_learned[name] = took
                    if data.on_debuff_learned then data.on_debuff_learned(name, took) end
                end
                list[name] = nil
            end
        end
    elseif DIES[message] then
        data.debuffs[target] = nil
        data.windows[target] = nil
        data.bounty[target] = nil
        data.mob_songs[target] = nil
        data.steps[target] = nil
        local actor = packet:unpack('I', 0x05)
        if data.is_ally and data.is_ally(actor) then data.stats.kills = data.stats.kills + 1 end
    end
end

-- Party members' buffs, from packet 0x076 (up to 5 members, not you): member id -> { [buff id] = true }.
-- Each member: id (4 bytes), index (2), 2 unused, 8 bytes holding the high 2 bits of each buff,
-- then 32 bytes with the low 8 bits. 255 = empty.
data.party_buffs = {}

-- Buffs cast on party members (by anyone, seen in action packets): member id -> buff name
-- (lower case) -> { spell, tier, at, dur, mine }. dur is only known for your own casts: the
-- spell's base duration until the addon has seen one of yours wear off, then the real time.
data.member_buffs = {}
data.learned_buff_dur = {}   -- spell id -> seconds (your casts; job points / gear included)
function data.learn_duration(spell, took)
    local sec = math.floor(took + 0.5)
    if data.learned_buff_dur[spell] == sec then return end
    data.learned_buff_dur[spell] = sec
    if data.on_learned then data.on_learned('duration', spell, sec) end
end
local BUFF_GAIN = { [230] = true, [237] = true, [266] = true, [267] = true, [278] = true, [280] = true }
local ROMAN = { I = 1, II = 2, III = 3, IV = 4, V = 5, VI = 6 }
-- Tier of a spell from its name: Protect V = 5, Haste II = 2, Haste = 1.
function data.spell_tier(name)
    local r = name and name:match('%s([IVX]+)$')
    return r and ROMAN[r] or 1
end
-- Your songs on each member, once you've sung them: member id -> spell id -> { name, family
-- (buff name, lower case), at, dur }. Two songs of a family (two Minuets) are both kept.
data.member_songs = {}
local song_seq = 0

-- Short tag for a song: family + tier (MIN5, BAL3, PAE6, MNE5), or for songs told apart by
-- their first word, that letter + family (HMAR Honor March, VMAR Victory March, FCAR2 Fire
-- Carol II, SMAD Sword Madrigal).
local SONG_FAM = { minuet = 'MIN', minne = 'MNE', paeon = 'PAE', ballad = 'BAL', madrigal = 'MAD',
    prelude = 'PRE', mambo = 'MAM', march = 'MAR', etude = 'ETU', carol = 'CAR', mazurka = 'MAZ',
    scherzo = 'SCH', hymnus = 'HYM', fantasia = 'FAN', operetta = 'OPE', capriccio = 'CAP',
    serenade = 'SER', round = 'RND', gavotte = 'GAV', fugue = 'FUG', aria = 'ARI', dirge = 'DIR',
    sirvente = 'SIR', aubade = 'AUB', pastoral = 'PAS', hum = 'HUM' }
local SONG_LETTER = { march = true, madrigal = true, prelude = true, mambo = true, etude = true,
    carol = true, mazurka = true, operetta = true }
function data.song_tag(name)
    local words = {}
    for w in name:gmatch('%S+') do words[#words + 1] = w end
    local tier = ''
    if ROMAN[words[#words]] then tier = tostring(ROMAN[words[#words]]) table.remove(words) end
    local fam = (words[#words] or ''):lower()
    local code = SONG_FAM[fam] or fam:sub(1, 3):upper()
    if SONG_LETTER[fam] and #words > 1 then code = words[1]:sub(1, 1):upper() .. code end
    return code .. tier
end

-- Your songs on enemies (Requiem, Elegy, Lullaby, Threnody...): mob id -> status -> { name, at }.
-- Gone when it wears off or the mob dies.
data.mob_songs = {}
local SONG_RESISTED = { [75] = true, [85] = true, [284] = true, [653] = true, [654] = true, [655] = true, [656] = true }

function data.track_member_buff(act, me)
    if act.category ~= 4 then return end
    local sp = res.spells[act.param]
    if not (sp and sp.status) then return end
    local t_ = sp.targets
    local at_enemy = (type(t_) == 'table' and (t_.Enemy or false)) or (type(t_) == 'number' and math.floor(t_ / 32) % 2 == 1)
    if type(t_) == 'table' and not at_enemy then for _, v in pairs(t_) do if v == 'Enemy' then at_enemy = true end end end
    if act.actor_id == me and sp.type == 'BardSong' and at_enemy then
        for _, t in ipairs(act.targets or {}) do
            local a = t.actions and t.actions[1]
            local mob = t.id and windower.ffxi.get_mob_by_id(t.id)
            if a and not SONG_RESISTED[a.message] and mob and mob.is_npc and mob.spawn_type ~= 14 then
                data.mob_songs[t.id] = data.mob_songs[t.id] or {}
                data.mob_songs[t.id][sp.status] = { name = en(sp), at = os.clock() }
            end
        end
    end
    local bname = data.buff_name(sp.status)
    if not bname then return end
    local mine = act.actor_id == me
    local song = sp.type == 'BardSong'
    for _, t in ipairs(act.targets or {}) do
        local a = t.actions and t.actions[1]
        if a and BUFF_GAIN[a.message] and song then
            if mine then
                data.member_songs[t.id] = data.member_songs[t.id] or {}
                song_seq = song_seq + 1
                data.member_songs[t.id][sp.id] = { name = en(sp), family = bname:lower(), at = os.clock(), seq = song_seq,
                    dur = data.learned_buff_dur[sp.id] or sp.duration or 120,
                    sv = data.soul_voice or nil }   -- sung under Soul Voice (shown in its own colour)
            end
        elseif a and BUFF_GAIN[a.message] then
            data.member_buffs[t.id] = data.member_buffs[t.id] or {}
            data.member_buffs[t.id][bname:lower()] = {
                spell = sp.id, tier = data.spell_tier(en(sp)), at = os.clock(), mine = mine,
                dur = mine and (data.learned_buff_dur[sp.id] or sp.duration) or nil,
            }
        end
    end
end

-- Forget tracked buffs a member no longer has; learn how long yours really lasted.
function data.prune_member_buffs(id, has)
    -- Your songs: gone when that kind of song is no longer on them (learning how long it
    -- lasted), or once its time is well past.
    local songs = data.member_songs[id]
    if songs then
        local now = os.clock()
        for sid, e in pairs(songs) do
            if not has(e.family) then
                local took = now - e.at
                if took >= 10 and took <= e.dur * 3 then data.learn_duration(sid, took) end
                songs[sid] = nil
            elseif now > e.at + e.dur + 10 then
                songs[sid] = nil
            end
        end
    end
    local list = data.member_buffs[id]
    if not list then return end
    for name, e in pairs(list) do
        if not has(name) then
            local took = os.clock() - e.at
            if e.mine and took >= 10 then data.learn_duration(e.spell, took) end
            list[name] = nil
        end
    end
end

-- Party members' jobs, from packet 0x0DD (party member update): id -> { main = 'RNG', sub = 'WAR' }.
-- Main job id at 0x22, sub job at 0x24.
data.party_jobs = {}
function data.on_0x0DD(packet)
    if #packet < 0x26 then return end
    local id = packet:unpack('I', 0x05)
    local main, sub = packet:byte(0x23), packet:byte(0x25)
    local function code(j) local r = res.jobs and res.jobs[j] return r and r.ens ~= 'NON' and r.ens or nil end
    if id and id ~= 0 and code(main) then data.party_jobs[id] = { main = code(main), sub = code(sub) } end
end

function data.on_0x076(packet)
    local list = {}
    for k = 0, 4 do
        local base = 5 + k * 48
        if #packet < base + 47 then break end
        local id = packet:unpack('I', base)
        if id and id ~= 0 then
            local set = {}
            for i = 0, 31 do
                local low = packet:byte(base + 16 + i)
                local high = math.floor(packet:byte(base + 8 + math.floor(i / 4)) / 4 ^ (i % 4)) % 4
                local buff = low + 256 * high
                if low ~= 255 then set[buff] = true end
            end
            list[id] = set
        end
    end
    data.party_buffs = list
    for id, set in pairs(list) do
        data.prune_member_buffs(id, function(name)
            for _, b in ipairs(data.buff_ids(name)) do if set[b] then return true end end
            return false
        end)
    end
end

------------------------------------------------------------------------------------------
-- Wyvern HP (DRG). The game only gives a pet's HP %, so its max HP is worked out from the
-- damage it takes: the damage numbers in action messages against how far its HP % drops
-- (median of the last samples). Steady Wing: when you used it (3 minutes) and about how
-- much it absorbs: 1.3 x max HP - current HP.
------------------------------------------------------------------------------------------

local PET_DMG, PET_HEAL = {}, {}
for id, m in pairs(res.action_messages or {}) do
    local t = m.en or m.english or ''
    if t:find('${target} takes ${number}', 1, true) or t:find('hits ${target} for ${number}', 1, true) then PET_DMG[id] = true end
    if t:find('${target} recovers ${number} HP', 1, true) then PET_HEAL[id] = true end
end
local STEADY_WING = 295

data.wyvern = { samples = {}, pending = 0 }   -- max, samples, pending damage, last_hpp, steady
data.STEADY_TIME = 180

function data.track_pet(act, me, pet)
    local w = data.wyvern
    if act.actor_id == me and act.category == 6 and act.param == STEADY_WING then
        local hpp = (w.last_hpp or (pet and pet.hpp) or 100)
        local hp = w.max and math.floor(w.max * hpp / 100)
        -- hpp: its HP % when used. Right after Steady Wing the game shows the HP % dip for a
        -- second or two before it's back to full; that dip is ignored (see data.wyvern_hpp).
        w.steady = { at = os.clock(), hpp = hpp, absorb = w.max and hp and math.floor(1.3 * w.max - hp) or nil }
    end
    if not (pet and pet.id) then return end
    for _, t in ipairs(act.targets or {}) do
        if t.id == pet.id then
            for _, a in ipairs(t.actions or {}) do
                if PET_DMG[a.message] then w.pending, w.pending_at = w.pending + (a.param or 0), os.clock()
                elseif PET_HEAL[a.message] then w.pending, w.pending_at = w.pending - (a.param or 0), os.clock() end
            end
        end
    end
end

-- Called every tick with the wyvern's HP % (nil: no wyvern).
-- The wyvern's HP % to show: during the brief dip right after Steady Wing (no damage taken),
-- the HP % from when it was used.
function data.wyvern_hpp(hpp)
    local st = data.wyvern.steady
    if st and hpp and hpp < st.hpp and os.clock() - st.at < 4 and not st.hit then return st.hpp end
    return hpp
end

-- Steady Wing's shield: { absorb = what it held at the start, left = its estimate now (nil
-- unknown), spent = true once damage has got through it }.
-- The game doesn't say how much of the shield is left. Damage it absorbs doesn't move the HP %,
-- so it's taken as whole until the wyvern's HP % drops below where it was (the shield is used
-- up), from then on as gone.
function data.wyvern_tick(hpp)
    local w = data.wyvern
    local now = os.clock()
    if not hpp then w.last_hpp, w.pending, w.steady = nil, 0, nil return end
    if w.steady and now - w.steady.at > data.STEADY_TIME then w.steady = nil end
    local st = w.steady
    if st then
        if w.pending > 0 then st.hit = true end
        -- Past the dip: a drop below the HP % it had when used means damage got through.
        if hpp < st.hpp and (st.hit or now - st.at >= 4) then st.spent = true end
        if hpp > st.hpp then st.hpp = hpp end   -- healed: the shield still counts on top
    end
    if w.last_hpp and hpp ~= w.last_hpp and w.pending > 0 then
        local drop = w.last_hpp - hpp
        -- (not while Steady Wing soaks damage, and only clear drops for a usable reading)
        if drop >= 3 and not w.steady then
            local est = w.pending * 100 / drop
            local s = w.samples
            s[#s + 1] = est
            if #s > 9 then table.remove(s, 1) end
            local sorted = {}
            for i, v in ipairs(s) do sorted[i] = v end
            table.sort(sorted)
            w.max = math.floor(sorted[math.ceil(#sorted / 2)] + 0.5)
        end
        w.pending = 0
    elseif w.pending ~= 0 and now - (w.pending_at or now) > 2 then
        w.pending = 0   -- the HP % never moved for it (absorbed, overhealed): drop it
    elseif hpp ~= w.last_hpp then
        w.pending = 0
    end
    w.last_hpp = hpp
end


------------------------------------------------------------------------------------------
-- Dancer: finishing moves, Daze from Steps on mobs, and flourishes that last several rounds.
--
-- Finishing moves: the game shows exactly 1-5 as buffs, but only "6+" above that, so past 5 the
-- count is kept from your own actions: a Step gives 1, +1 on main DNC, +4 with Presto, +1 with
-- Terpsichore in the main hand; No Foot Rise reports the new total; flourishes use theirs (the
-- variable ones always take as many as they can). Capped at data.dnc.max (9 with the 100 and
-- 1200 JP gifts). Whenever the buff shows 0-5 again, that's taken as the real count.
--
-- Daze: the Step message gives the level exactly. The time is an estimate: 60 s for a new one,
-- +30 s for each Step after (capped at 120 s), plus your Step Duration job points on yours.
------------------------------------------------------------------------------------------

data.dnc = { est = 0, max = 9, state = nil, step_jp = 0, climactic = nil, building = nil,
             saber_at = nil, fan_hits = 0 }   -- Saber Dance used at (os.clock); hits taken since Fan Dance
data.steps = {}   -- mob id -> daze name -> { level, expires, mine }
data.dnc_context = nil   -- set by the addon: function() -> { main = bool, presto = bool, terpsichore = bool, tiara = bool }

local STEP_MSG = { [519] = 'Lethargic', [520] = 'Sluggish', [521] = 'Weakened', [591] = 'Bewildered' }
data.STEP_OF = { Lethargic = 'Quick', Sluggish = 'Box', Weakened = 'Stutter', Bewildered = 'Feather' }
data.DAZE_ORDER = { 'Sluggish', 'Lethargic', 'Weakened', 'Bewildered' }
local STEP_BASE, STEP_ADD, STEP_CAP = 60, 30, 120
local FM_NOW = 560       -- "<actor> uses No Foot Rise. Finishing move now N."
-- Flourishes: { least, most } finishing moves used (variable ones take as many as they can).
local FLOURISH_COST = {
    ['Animated Flourish'] = { 1, 2 }, ['Desperate Flourish'] = { 1, 1 }, ['Violent Flourish'] = { 1, 1 },
    ['Reverse Flourish'] = { 1, 5 }, ['Building Flourish'] = { 1, 3 }, ['Wild Flourish'] = { 2, 2 },
    ['Climactic Flourish'] = { 1, 5 }, ['Striking Flourish'] = { 2, 2 }, ['Ternary Flourish'] = { 3, 3 },
}
local MISS = { [15] = true, [63] = true }   -- melee misses

-- Finishing moves now: exact from the buffs (0-5), or the kept count past 5.
-- Returns count, estimated (true when it's past 5 and counted by the addon).
function data.fm_count(counts)
    local state = 0
    for i = 1, 5 do
        local id = data.buff_id('Finishing Move ' .. i)
        if id and counts[id] then state = i end
    end
    local six = data.buff_id('Finishing Move (6+)')
    if six and counts[six] then state = 6 end
    local d = data.dnc
    if state ~= d.state then
        -- The buff changed: 0-5 is the real count; 6+ means at least 6.
        d.state = state
        if state < 6 then d.est = state else d.est = math.max(d.est, 6) end
    end
    if state < 6 then return state, false end
    return math.max(6, math.min(d.est, d.max)), true
end

local function fm_add(n)
    local d = data.dnc
    d.est = math.max(0, math.min(d.max, d.est + n))
end

local function ja_name(act)
    if act.category ~= 6 and act.category ~= 14 and act.category ~= 15 then return nil end
    local r = res.job_abilities[act.param]
    return r and en(r)
end

function data.dnc_action(act, me)
    local now = os.clock()
    local d = data.dnc
    -- Daze on mobs, from anyone's Steps (the level is in the message).
    for _, t in ipairs(act.targets or {}) do
        for _, a in ipairs(t.actions or {}) do
            local daze = STEP_MSG[a.message]
            if daze then
                local list = data.steps[t.id] or {}
                data.steps[t.id] = list
                local mine = act.actor_id == me
                local jp = mine and (d.step_jp or 0) or 0
                local old = list[daze]
                local left = old and old.expires > now and (old.expires - now) or 0
                local dur = left > 0 and math.min(left + STEP_ADD + jp, STEP_CAP + jp) or (STEP_BASE + jp)
                list[daze] = { level = a.param, expires = now + dur, mine = mine or (old and old.mine) }
                if mine then
                    local c = data.dnc_context and data.dnc_context() or {}
                    fm_add(1 + (c.main and 1 or 0) + (c.presto and 4 or 0) + (c.terpsichore and 1 or 0))
                end
            end
            if a.message == FM_NOW and act.actor_id == me then d.est = math.min(d.max, a.param) end
        end
    end
    -- Fan Dance weakens by 10% for every physical hit you take (melee hits and crits on you).
    if act.category == 1 and act.actor_id ~= me then
        for _, t in ipairs(act.targets or {}) do
            if t.id == me then
                for _, a in ipairs(t.actions or {}) do
                    if a.message == 1 or a.message == 67 then d.fan_hits = d.fan_hits + 1 end
                end
            end
        end
    end
    if act.actor_id ~= me then return end
    local used_ja = ja_name(act)
    if used_ja == 'Saber Dance' then d.saber_at = now end
    if used_ja == 'Fan Dance' then d.fan_hits = 0 end
    -- Your melee rounds use up Climactic Flourish (a missed first swing doesn't count).
    if act.category == 1 and d.climactic then
        local first = act.targets and act.targets[1] and act.targets[1].actions and act.targets[1].actions[1]
        if first and not MISS[first.message] then
            d.climactic.left = d.climactic.left - 1
            if d.climactic.left <= 0 then d.climactic = nil end
        end
    end
    -- Flourishes use finishing moves.
    local name = ja_name(act)
    local cost = name and FLOURISH_COST[name]
    if cost then
        local have = d.state and d.state < 6 and d.state or d.est
        local used = math.max(cost[1], math.min(cost[2], have))
        if name == 'Climactic Flourish' then
            local c = data.dnc_context and data.dnc_context() or {}
            d.climactic = { left = used + (c.tiara and 1 or 0), total = used + (c.tiara and 1 or 0), at = now }
        elseif name == 'Building Flourish' then
            d.building = { used = used, at = now }
        end
        fm_add(-used)
    end
end

-- Saber Dance: 50% Double Attack falling about 1% a second to 20% (+1% per merit with
-- Horos / Etoile Tights on), from when it was used (or from its time left: it lasts 5:00).
-- Fan Dance: 90% physical damage reduction, -10% per physical hit you take, down to 20% (+1% per
-- merit with Horos / Etoile Bangles on). Returns the percentage now.
function data.saber_strength(left, floor_bonus)
    local d = data.dnc
    local elapsed = d.saber_at and (os.clock() - d.saber_at) or (left and (300 - left)) or 0
    if left and d.saber_at and os.clock() - d.saber_at > 310 then elapsed = 300 - left end   -- stale
    return math.max(20 + (floor_bonus or 0), math.floor(50 - elapsed + 0.5))
end
function data.fan_strength(floor_bonus)
    return math.max(20 + (floor_bonus or 0), 90 - 10 * data.dnc.fan_hits)
end

-- Daze on a mob that's still running: list of { name, step, level, left, mine }, in a fixed order.
function data.mob_daze(id)
    local list = id and data.steps[id]
    if not list then return {} end
    local now, out = os.clock(), {}
    for _, daze in ipairs(data.DAZE_ORDER) do
        local e = list[daze]
        if e then
            if e.expires <= now then list[daze] = nil
            else out[#out + 1] = { name = daze, step = data.STEP_OF[daze], level = e.level, left = e.expires - now, mine = e.mine } end
        end
    end
    return out
end

function data.on_daze_worn(target, buff)
    local list = data.steps[target]
    if not list then return end
    for _, daze in ipairs(data.DAZE_ORDER) do
        local r = res.buffs[buff]
        if r and en(r):find('^' .. daze .. ' Daze') then list[daze] = nil end
    end
end

function data.clear_mobs()
    data.debuffs, data.windows, data.last_target = {}, {}, {}
    data.hover = { stacks = 0 }
    data.bounty = {}
    data.member_buffs = {}
    data.member_songs = {}
    data.mob_songs = {}
    data.steps = {}
end

------------------------------------------------------------------------------------------
-- Hover Shot (RNG): +1 stack (max 25) for each ranged attack or weapon skill fired at least
-- 1 yalm from where you last shot; the first shot at a target (a new one included) starts
-- the count at 1. The game doesn't report the
-- count, so it's counted from your own shots while Hover Shot is on you.
------------------------------------------------------------------------------------------

data.HOVER_MAX = 25
data.hover = { stacks = 0 }   -- stacks, target (mob id), pos { x, y } of the last shot

function data.hover_moved(pos)
    local h = data.hover
    if not (h.pos and pos) then return nil end
    local dx, dy = pos.x - h.pos.x, pos.y - h.pos.y
    return math.sqrt(dx * dx + dy * dy) >= 1
end

function data.on_hover_action(act, me, pos, active)
    if act.actor_id ~= me then return end
    local first = act.targets and act.targets[1]
    if not first then return end
    local shot = act.category == 2
        or (act.category == 3 and first.actions and first.actions[1] and WS_MESSAGE[first.actions[1].message])
    if not shot then return end
    local h = data.hover
    if not active then
        h.stacks, h.target = 0, nil
    elseif first.id ~= h.target then
        -- First shot, or a shot at a different target: starts over at 1 (that shot counts).
        h.stacks, h.target = 1, first.id
    elseif data.hover_moved(pos) then
        h.stacks = math.min(data.HOVER_MAX, h.stacks + 1)
    end
    h.pos = pos and { x = pos.x, y = pos.y } or nil
end

return data

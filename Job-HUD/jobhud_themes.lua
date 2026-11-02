--[[
    Job-HUD: themes, colour-blind palettes and opacity.

    The colours actually drawn are built in layers:
        1. your colours (<colors> in the settings file)
        2. the theme   (panel, frame and text colours)        //jhud theme lattice|light|contrast
        3. the palette (every colour that means something:   //jhud look normal|redgreen|deut|trit
           ready / soon / cooldown cells, on / ending / off tags, good / warning / bad text,
           header squares)
        4. opacity     (panel and cell backgrounds only; text stays solid)   //jhud opacity 0-100
    Nothing here is written to the settings file, so switching back is always exact.

    Palettes use the Okabe-Ito colours, which stay apart for the common kinds of colour
    blindness:
        redgreen  red-green (made for protanopia; works for both): blue = good, orange/vermilion = bad,
                  yellow = soon
        deut      deuteranopia: blue = good, yellow = soon, purple / magenta = bad (no reds or
                  oranges, which look like the greens and yellows)
        tritan    tritanopia: teal = good, red = bad, pink = soon
]]

local themes = {}

local function c(r, g, b, a) return { red = r, green = g, blue = b, alpha = a } end

-- Panel, frame and text colours. 'lattice' is the default look (your <colors> as they are).
themes.themes = {
    lattice = {},
    light = {
        body = c(232, 233, 238, 225), strip = c(200, 205, 222, 235), border = c(120, 125, 140, 255),
        recess = c(180, 184, 196, 235), empty = c(205, 208, 216, 160),
        label = c(55, 75, 120), text = c(25, 25, 30), dim = c(115, 118, 128),
        stroke = { width = 0, alpha = 0, red = 255, green = 255, blue = 255 },
        cell_text = c(255, 255, 255),
        darken_text = 0.6,   -- coloured text (and element colours) darkened to read on a light panel
    },
    contrast = {
        body = c(0, 0, 0, 245), strip = c(0, 0, 0, 255), border = c(255, 255, 255, 255),
        recess = c(0, 0, 0, 255), empty = c(40, 40, 40, 200),
        label = c(255, 255, 120), text = c(255, 255, 255), dim = c(185, 185, 185),
        stroke = { width = 2, alpha = 255, red = 0, green = 0, blue = 0 },
    },
}

-- Colours that carry meaning.
themes.palettes = {
    normal = {},
    redgreen = {
        ready = c(0, 114, 178, 235), soon = c(240, 200, 40, 235), cooldown = c(150, 60, 0, 235),
        ind_on = c(86, 180, 233, 255), ind_bad = c(213, 94, 0, 255), ind_warn = c(240, 228, 66, 255),
        ind_high = c(204, 121, 167, 255),
        good = c(86, 180, 233), warn = c(230, 159, 0), bad = c(240, 110, 40), upkeep_warn = c(240, 228, 66),
        active = c(255, 255, 255), accent = c(204, 121, 167), buffed = c(204, 121, 167, 235),
        lower_tier = c(204, 121, 167), soul_voice = c(213, 94, 0),
    },
    deut = {
        ready = c(0, 114, 178, 235), soon = c(220, 190, 40, 235), cooldown = c(120, 40, 110, 235),
        ind_on = c(86, 180, 233, 255), ind_bad = c(190, 70, 170, 255), ind_warn = c(240, 228, 66, 255),
        ind_high = c(255, 255, 255, 255),
        good = c(86, 180, 233), warn = c(240, 228, 66), bad = c(230, 110, 210), upkeep_warn = c(240, 228, 66),
        active = c(255, 255, 255), accent = c(170, 150, 255), buffed = c(150, 120, 230, 235),
        lower_tier = c(170, 150, 255), soul_voice = c(255, 255, 255),
    },
    tritan = {
        ready = c(0, 140, 110, 235), soon = c(204, 121, 167, 235), cooldown = c(200, 40, 40, 235),
        ind_on = c(0, 190, 150, 255), ind_bad = c(220, 50, 50, 255), ind_warn = c(230, 140, 190, 255),
        ind_high = c(255, 255, 255, 255),
        good = c(0, 200, 160), warn = c(230, 140, 190), bad = c(240, 70, 70), upkeep_warn = c(230, 140, 190),
        active = c(255, 255, 255), accent = c(230, 140, 190), buffed = c(150, 150, 255, 235),
        lower_tier = c(150, 150, 255), soul_voice = c(255, 255, 255),
    },
}

-- Aliases people might type.
themes.palette_alias = {
    normal = 'normal', off = 'normal', default = 'normal',
    redgreen = 'redgreen', protan = 'redgreen', protanopia = 'redgreen',
    deut = 'deut', deutan = 'deut', deuteranopia = 'deut',
    trit = 'tritan', tritan = 'tritan', tritanopia = 'tritan', blueyellow = 'tritan',
}

local BACKGROUNDS = { body = true, strip = true, recess = true, empty = true, buffed = true,
                      ready = true, soon = true, cooldown = true, unavailable = true }

local function copy(t)
    if type(t) ~= 'table' then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = copy(v) end
    return o
end

-- Effective colours and text stroke for the given settings. Never modifies the settings.
function themes.build(settings)
    local out = copy(settings.colors)
    local stroke = copy(settings.stroke)
    local theme = themes.themes[settings.theme or 'lattice'] or themes.themes.lattice
    local pal = themes.palettes[settings.palette or 'normal'] or themes.palettes.normal
    for k, v in pairs(theme) do
        if k == 'stroke' then stroke = copy(v) elseif k ~= 'darken_text' then out[k] = copy(v) end
    end
    for k, v in pairs(pal) do out[k] = copy(v) end
    -- A light theme darkens every coloured text colour (applied after the palette, so a
    -- colour-blind palette stays readable on it too).
    -- Cells keep the bright "effect is on you" colour: their text sits on coloured cells.
    out.cell_active = copy(out.active)
    local dk = theme.darken_text
    if dk then
        for _, k in ipairs({ 'good', 'warn', 'bad', 'upkeep_warn', 'accent', 'active', 'lower_tier', 'soul_voice' }) do
            if out[k] then
                out[k] = { red = math.floor(out[k].red * dk), green = math.floor(out[k].green * dk),
                           blue = math.floor(out[k].blue * dk), alpha = out[k].alpha }
            end
        end
    end
    out.element_scale = dk or 1
    -- Text drawn on top of cells: the theme's text colour unless the theme says otherwise.
    out.cell_text = out.cell_text or out.text
    local op = math.max(0, math.min(100, tonumber(settings.opacity) or 100)) / 100
    for k in pairs(BACKGROUNDS) do
        if out[k] and out[k].alpha then out[k].alpha = math.floor(out[k].alpha * op + 0.5) end
    end
    return out, stroke
end

return themes

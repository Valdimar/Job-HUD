--[[
    Job-HUD: the lattice panel.

    Drawn in the style of RahvinGS's LATTICE display: a dark body with a thin border, a header
    strip across the top, and a recessed grid of cells beside the text rows. Here the grid holds
    cooldowns instead of gear slots.

    The panel is a FIXED size: its width and height come only from the layout settings
    (row width in characters, number of row lines, grid columns x grid rows) and the font, never
    from what the current job puts on it. Every job therefore gets the same footprint on screen.
    Unused grid slots are drawn as empty cells; rows that don't fit are cut off.

    Everything is laid out in pixels from one measurement of the font (a hidden probe text), so
    the panel scales with the font size and needs no per-font tuning. Text is drawn by Windower
    text objects over windower.prim rectangles.
]]

local texts = require('texts')

local display = {}

local PREFIX = 'jobhud_'
local PANEL = { 'body', 'strip', 'top', 'bottom', 'left', 'right', 'recess' }
local MAX_IND = 9
local MAX_SEG = 5     -- segments in a bar row (stratagem charges)
local VPAD = 2

local S              -- settings
local COL, STROKE    -- effective colours and text stroke (theme / palette / opacity applied)
local probe          -- measuring text
local header_t, rows_t, right_t
local cell_t = {}    -- text objects for grid cells
local seg_t = {}     -- text objects for bar segments
local seg_count = 0  -- bar segments shown right now
local seg_key        -- where the bar was last placed
local spanned = {}   -- cells drawn as a big 2x2 box right now
local ind_t = {}     -- text objects for header indicator labels
local tip_t          -- hover tooltip
local regions = {}   -- hover regions from the last render: cells, header squares, column text
local created = false
local metrics        -- { cw = char width, lh = line height }
local shown = false
local geom = {}      -- last layout: x, y, w, h and the key it was built from
local ind_count = 0
local prim_cells = 0  -- cell primitives created (= grid capacity)
local last_text = {} -- text object -> last string written
local last_color = {}-- prim name -> last color key

local prim = windower.prim
local anim = { frames = nil, times = nil, total = 0, cur = 0 }   -- COR bust animation (see anim_render)
local anim_hide, anim_destroy, anim_render

local function pname(n) return PREFIX .. n end

local function text_settings(alpha, stroke_alpha)
    local st = STROKE or S.stroke
    return {
        pos = { x = S.pos.x, y = S.pos.y },
        bg = { visible = false, alpha = 0, red = 0, green = 0, blue = 0 },
        flags = { draggable = false, bold = S.bold, right = false, bottom = false },
        text = {
            font = S.font, size = S.size,
            red = 235, green = 235, blue = 235, alpha = alpha or 255,
            stroke = { width = st.width, alpha = stroke_alpha or st.alpha,
                       red = st.red, green = st.green, blue = st.blue },
        },
        padding = 0,
    }
end

local FADE = 1        -- idle fade of the cooldown grid (recess + cells), 0-1

local function fades(name) return name == PREFIX .. 'recess' or name:find(PREFIX .. 'cell', 1, true) == 1 end

local function set_color(name, c)
    local a = math.floor((c.alpha or 255) * (fades(name) and FADE or 1) + 0.5)
    local key = a .. ',' .. c.red .. ',' .. c.green .. ',' .. c.blue
    if last_color[name] == key then return end
    last_color[name] = key
    prim.set_color(name, a, c.red, c.green, c.blue)
end

local function set_text(t, str)
    if last_text[t] == str then return end
    last_text[t] = str
    t:text(str)
end

local function place(name, x, y, w, h)
    prim.set_position(name, math.floor(x), math.floor(y))
    prim.set_size(name, math.max(math.floor(w), 0), math.max(math.floor(h), 0))
end

------------------------------------------------------------------------------------------
-- Fixed layout
------------------------------------------------------------------------------------------

local function grid_on() return S.grid.enabled and S.layout.columns > 0 and S.layout.grid_rows > 0 end

-- Grid capacity in cells (0 when the grid is off).
function display.capacity()
    if not grid_on() then return 0 end
    return S.layout.columns * S.layout.grid_rows
end

-- Pixel sizes of the parts, from the font measurement and the layout settings only.
-- Compact mode: no right column, and the left column is only as wide as the right one was
-- (it holds the stances / shadows etc. instead of the usual left rows).
local function left_chars()
    if S.compact_mode then return tonumber(S.layout.right_width) or 22 end
    return S.layout.width
end
local function right_chars()
    if S.compact_mode then return 0 end
    return tonumber(S.layout.right_width) or 0
end

local function sizes()
    local cw, lh = metrics.cw, metrics.lh
    local L, G = S.layout, S.grid
    local z = {}
    z.strip_h = math.floor(lh + 2 * VPAD)
    z.cell_w = math.floor(G.cell_chars * cw + 6)
    z.cell_h = math.floor(2 * lh + 2)
    if grid_on() then
        z.cols, z.grows = L.columns, L.grid_rows
        z.grid_w = z.cols * z.cell_w + (z.cols - 1) * G.gap + 2 * G.inset
        z.grid_h = z.grows * z.cell_h + (z.grows - 1) * G.gap + 2 * G.inset
    else
        z.cols, z.grows, z.grid_w, z.grid_h = 0, 0, 0, 0
    end
    -- Row lines: a fixed number, or (0 = auto) as many as fit beside the grid.
    local lines = tonumber(L.lines) or 0
    if lines <= 0 then
        if grid_on() and G.position ~= 'bottom' then lines = math.max(1, math.floor(z.grid_h / lh))
        else lines = 10 end
    end
    z.lines = lines
    z.rows_w = left_chars() * cw
    z.rows_h = lines * lh
    -- Right-hand text column (beside the grid): fixed width on every job, 0 = none.
    z.right_w = right_chars() * cw
    return z
end

-- How much text the panel holds: { lines = row lines, width = row chars, right = right column
-- chars (0 = no right column) }.
-- nil until the font has been measured.
function display.layout()
    if not metrics then return nil end
    local z = sizes()
    local P = S.panel
    local inner_w
    if S.grid.position == 'bottom' then inner_w = math.max(z.rows_w, z.grid_w)
    else inner_w = z.rows_w + (z.grid_w > 0 and P.gutter or 0) + z.grid_w end
    return { lines = z.lines, width = left_chars(), right = right_chars(),
             header = math.floor(inner_w / metrics.cw) }
end

------------------------------------------------------------------------------------------
-- Creation
------------------------------------------------------------------------------------------

function display.init(settings, colors, stroke)
    S = settings
    COL, STROKE = colors or settings.colors, stroke or settings.stroke
    display.destroy()
    -- Primitives draw in creation order: body first, then the frame, the recess, the cells
    -- and the indicator squares on top.
    for _, n in ipairs(PANEL) do prim.create(pname(n)) end
    prim_cells = math.max(0, S.layout.columns * S.layout.grid_rows)
    for i = 1, prim_cells do prim.create(pname('cell' .. i)) end
    for i = 1, MAX_SEG do prim.create(pname('cellseg' .. i)) prim.create(pname('cellsegfill' .. i)) end
    for i = 1, MAX_IND do prim.create(pname('ind' .. i)) end
    local C = COL
    set_color(pname('body'), C.body)
    set_color(pname('strip'), C.strip)
    for _, n in ipairs({ 'top', 'bottom', 'left', 'right' }) do set_color(pname(n), C.border) end
    set_color(pname('recess'), C.recess)
    for _, n in ipairs(PANEL) do prim.set_visibility(pname(n), false) end
    for i = 1, prim_cells do prim.set_visibility(pname('cell' .. i), false) end
    for i = 1, MAX_SEG do
        prim.set_visibility(pname('cellseg' .. i), false)
        prim.set_visibility(pname('cellsegfill' .. i), false)
    end
    seg_count, seg_key = 0, nil
    for i = 1, MAX_IND do prim.set_visibility(pname('ind' .. i), false) end

    header_t = texts.new('', text_settings())
    rows_t = texts.new('', text_settings())
    right_t = texts.new('', text_settings())
    for i = 1, prim_cells do cell_t[i] = texts.new('', text_settings()) end
    for i = 1, MAX_SEG do seg_t[i] = texts.new('', text_settings()) end
    for i = 1, MAX_IND do ind_t[i] = texts.new('', text_settings()) end
    local ts = text_settings()
    ts.bg = { visible = true, alpha = 235, red = 12, green = 14, blue = 22 }
    ts.padding = 4
    tip_t = texts.new('', ts)
    FADE = 1

    -- The probe is drawn nearly transparent (alpha 1, so the renderer still lays it out) and
    -- reports the font's size: 10 columns by 10 lines.
    probe = texts.new(('MMMMMMMMMM\n'):rep(9) .. 'MMMMMMMMMM', text_settings(1, 1))
    probe:show()
    metrics = nil
    created = true
    shown = false
    geom = {}
end

function display.destroy()
    if not created then return end
    for _, n in ipairs(PANEL) do prim.delete(pname(n)) end
    for i = 1, prim_cells do prim.delete(pname('cell' .. i)) end
    prim_cells = 0
    for i = 1, MAX_SEG do prim.delete(pname('cellseg' .. i)) prim.delete(pname('cellsegfill' .. i)) end
    for _, t in ipairs(seg_t) do t:destroy() end
    seg_t, seg_count, seg_key = {}, 0, nil
    for i = 1, MAX_IND do prim.delete(pname('ind' .. i)) end
    anim_destroy()
    if display.party_destroy then display.party_destroy() end
    if header_t then header_t:destroy() end
    if rows_t then rows_t:destroy() end
    if right_t then right_t:destroy() end
    right_t = nil
    for _, t in ipairs(cell_t) do t:destroy() end
    for _, t in ipairs(ind_t) do t:destroy() end
    ind_t = {}
    if tip_t then tip_t:destroy() end
    tip_t = nil
    regions = {}
    if probe then probe:destroy() end
    header_t, rows_t, probe = nil, nil, nil
    cell_t = {}
    last_text, last_color = {}, {}
    created = false
    shown = false
end

-- True once the font has been measured. Call every tick until it is.
function display.measure()
    if metrics then return true end
    if not probe then return false end
    local w, h = probe:extents()
    if not w or w <= 0 or not h or h <= 0 then return false end
    metrics = { cw = w / 10, lh = h / 10 }
    probe:destroy()
    probe = nil
    return true
end

function display.metrics() return metrics end

-- Characters that fit across n grid cells joined into one (with the gaps between them).
function display.span_chars(n)
    if not metrics then return n * S.grid.cell_chars end
    local z = sizes()
    return math.floor((n * z.cell_w + (n - 1) * S.grid.gap - 6) / metrics.cw)
end

------------------------------------------------------------------------------------------
-- Visibility
------------------------------------------------------------------------------------------

local function apply_visibility()
    local on = shown
    local grid = on and grid_on()
    for _, n in ipairs(PANEL) do
        prim.set_visibility(pname(n), n == 'recess' and grid or on)
    end
    for i = 1, prim_cells do
        prim.set_visibility(pname('cell' .. i), grid)
        if cell_t[i] then cell_t[i]:visible(grid) end
    end
    for i = 1, MAX_SEG do
        local v = grid and i <= seg_count
        prim.set_visibility(pname('cellseg' .. i), v)
        prim.set_visibility(pname('cellsegfill' .. i), v)
        if seg_t[i] then seg_t[i]:visible(v) end
    end
    for i = 1, MAX_IND do
        prim.set_visibility(pname('ind' .. i), on and i <= ind_count)
        if ind_t[i] then ind_t[i]:visible(on and i <= ind_count) end
    end
    if not on then anim_hide() if display.party_render then display.party_render(nil) end end
    if header_t then header_t:visible(on) end
    if rows_t then rows_t:visible(on) end
    if right_t then right_t:visible(on and S and right_chars() > 0) end
end

function display.hide_tip()
    if tip_t then tip_t:visible(false) end
end

function display.show()
    if not created or not metrics or shown then return end
    shown = true
    apply_visibility()
end

function display.hide()
    if not created or not shown then return end
    shown = false
    apply_visibility()
    display.hide_tip()
end

function display.visible() return shown end

------------------------------------------------------------------------------------------
-- Layout and paint
------------------------------------------------------------------------------------------

local function center(s, w)
    local n = #s
    if n >= w then return s:sub(1, w) end
    local left = math.floor((w - n) / 2)
    return (' '):rep(left) .. s .. (' '):rep(w - n - left)
end

local function cs(c, s)
    return ('\\cs(%d,%d,%d)%s\\cr'):format(c.red, c.green, c.blue, s)
end

-- Width of a text object as drawn, or an estimate from its length before the first draw.
local function text_width(t, chars)
    local w = t:extents()
    if w and w > 0 then return w end
    return chars * metrics.cw
end

-- Header indicators: each is a square followed by its own label text, laid out in pixels
-- from the panel's right edge. Every label is its own text object, so positions don't drift
-- with the font the way character counting does. Indicators that would run into the job
-- text are dropped (from the end; ones marked keep go last). Returns how many are shown.
local function layout_indicators(model, x, y, W, n_ind)
    local cw, lh = metrics.cw, metrics.lh
    local P = S.panel
    local sq = math.max(4, math.floor(lh * 0.6))
    local sq_gap = math.max(3, math.floor(cw * 0.5))
    local gap = math.floor(cw * 2)
    local list = {}
    for i = 1, n_ind do list[i] = model.indicators[i] end
    local function width(ind) return sq + sq_gap + math.floor(ind.chars * cw + 0.5) end
    local right = x + W - P.border - P.pad
    local left_limit = x + P.border + P.pad + text_width(header_t, model.header_chars or 0) + gap
    local function total()
        local t = 0
        for i, ind in ipairs(list) do t = t + width(ind) + (i > 1 and gap or 0) end
        return t
    end
    while #list > 0 and right - total() < left_limit do
        local drop = #list
        for i = #list, 1, -1 do if not list[i].keep then drop = i break end end
        table.remove(list, drop)
    end
    model.indicators = list
    local n = #list
    local widths = {}
    for i = 1, n do
        set_text(ind_t[i], list[i].label)
        widths[i] = sq + sq_gap + text_width(ind_t[i], list[i].chars)
    end
    local total = 0
    for i = 1, n do total = total + widths[i] + (i > 1 and gap or 0) end
    local cx = right - total
    for i = 1, n do
        place(pname('ind' .. i), cx, y + VPAD + (lh - sq) / 2, sq, sq)
        ind_t[i]:pos(math.floor(cx + sq + sq_gap), math.floor(y + VPAD))
        regions.inds[i] = { x = cx, y = y, w = widths[i], h = lh + 2 * VPAD, tip = model.indicators[i].tip }
        cx = cx + widths[i] + gap
    end
    return n
end

--[[
    model = {
        header = string (with color codes),
        header_chars = visible length of header,
        indicators = { { label = string (with color codes), chars = length, color = {..} }, ... },
        rows = string (with color codes, lines joined by \n),
        right = string for the right-hand column (same format), or nil,
        cells = { { label, value, color = {..}, label_color, value_color }, ... },
    }
    The model is expected to fit display.layout(); anything beyond the grid capacity is ignored.
]]
function display.render(model)
    if not created or not metrics then return end
    local cw, lh = metrics.cw, metrics.lh
    local P, G = S.panel, S.grid
    local pad, bw = P.pad, P.border
    local x, y = S.pos.x, S.pos.y
    local z = sizes()
    local n_ind = math.min(#model.indicators, MAX_IND)
    local grid = z.grid_w > 0

    local body_top = y + z.strip_h
    local inner_w, inner_h, gx, gy, rx
    local right = z.right_w > 0
    if G.position == 'bottom' then
        local gap = grid and P.gutter / 2 or 0
        local top_w = z.rows_w + (right and P.gutter + z.right_w or 0)
        inner_w = math.max(top_w, z.grid_w)
        inner_h = z.rows_h + gap + z.grid_h
        gx = x + bw + pad
        gy = body_top + VPAD + z.rows_h + gap
        rx = x + bw + pad + z.rows_w + P.gutter
    else
        local gutter = grid and P.gutter or 0
        inner_w = z.rows_w + gutter + z.grid_w + (right and P.gutter + z.right_w or 0)
        inner_h = math.max(z.rows_h, z.grid_h)
        gx = x + bw + pad + z.rows_w + gutter
        gy = body_top + VPAD
        rx = gx + z.grid_w + P.gutter
    end
    local W = math.floor(inner_w + 2 * pad + 2 * bw)
    local H = math.floor(z.strip_h + inner_h + 2 * VPAD + pad / 2 + bw)

    local key = table.concat({ x, y, W, H, n_ind, gx, gy, z.cols, z.grows, rx }, ':')
    if geom.key ~= key then
        geom = { key = key, x = x, y = y, w = W, h = H }
        place(pname('top'), x, y, W, bw)
        place(pname('bottom'), x, y + H - bw, W, bw)
        place(pname('left'), x, y + bw, bw, H - 2 * bw)
        place(pname('right'), x + W - bw, y + bw, bw, H - 2 * bw)
        place(pname('strip'), x + bw, y + bw, W - 2 * bw, z.strip_h - bw)
        place(pname('body'), x + bw, y + z.strip_h, W - 2 * bw, H - z.strip_h - bw)
        if grid then
            place(pname('recess'), gx, gy, z.grid_w, z.grid_h)
            for i = 1, prim_cells do
                local c, r = (i - 1) % z.cols, math.floor((i - 1) / z.cols)
                local cx = gx + G.inset + c * (z.cell_w + G.gap)
                local cy = gy + G.inset + r * (z.cell_h + G.gap)
                place(pname('cell' .. i), cx, cy, z.cell_w, z.cell_h)
                cell_t[i]:pos(math.floor(cx + 3), math.floor(cy + 1))
                spanned[i] = nil
            end
        end
        header_t:pos(math.floor(x + bw + pad), math.floor(y + VPAD))
        rows_t:pos(math.floor(x + bw + pad), math.floor(body_top + VPAD))
        right_t:pos(math.floor(rx), math.floor(body_top + VPAD))
        geom.left = { x = x + bw + pad, y = body_top + VPAD }
        geom.right = right and { x = rx, y = body_top + VPAD } or nil
        geom.cells = {}
        if grid then
            for i = 1, prim_cells do
                local c, r = (i - 1) % z.cols, math.floor((i - 1) / z.cols)
                geom.cells[i] = { x = gx + G.inset + c * (z.cell_w + G.gap), y = gy + G.inset + r * (z.cell_h + G.gap),
                                  w = z.cell_w, h = z.cell_h }
            end
        end
        if shown then apply_visibility() end
    end

    regions = { model = model, inds = {} }
    -- Paint
    set_text(header_t, model.header)
    set_text(rows_t, model.rows)
    set_text(right_t, right and model.right or '')
    n_ind = layout_indicators(model, x, y, W, n_ind)
    for i = 1, n_ind do set_color(pname('ind' .. i), model.indicators[i].color) end
    local segs_now = 0
    if grid then
        local w = G.cell_chars
        for i = 1, prim_cells do
            local c = model.cells[i]
            -- Wide / big cells: 'span' = { columns, rows } (roll boxes are 2 x 2).
            local sw, sh = 1, 1
            if c and c.box then sw, sh = 2, 2 end
            if c and c.span then sw, sh = c.span[1] or 1, c.span[2] or 1 end
            local skey = sw .. 'x' .. sh
            if (spanned[i] or '1x1') ~= skey then
                local r, cc = math.floor((i - 1) / z.cols), (i - 1) % z.cols
                place(pname('cell' .. i), gx + G.inset + cc * (z.cell_w + G.gap), gy + G.inset + r * (z.cell_h + G.gap),
                      sw * z.cell_w + (sw - 1) * G.gap, sh * z.cell_h + (sh - 1) * G.gap)
                spanned[i] = skey ~= '1x1' and skey or nil
            end
            if c and c.box then
                -- A big box over 2x2 cells (Phantom Rolls).
                set_color(pname('cell' .. i), c.color or COL.empty)
                local out = {}
                for k = 1, math.max(4, #c.box) do out[k] = cs(c.text_color or COL.text, c.box[k] or '') end
                set_text(cell_t[i], table.concat(out, '\n'))
            elseif c and (c.covered or c.meter) then
                -- Drawn by the bar segments instead.
                set_color(pname('cell' .. i), { alpha = 0, red = 0, green = 0, blue = 0 })
                set_text(cell_t[i], '')
                if c.meter then
                    segs_now = math.min(#c.meter, MAX_SEG)
                    local r = math.floor((i - 1) / z.cols)
                    local bx = gx + G.inset
                    local by = gy + G.inset + r * (z.cell_h + G.gap)
                    local total = z.cols * z.cell_w + (z.cols - 1) * G.gap
                    local sw = (total - (segs_now - 1) * G.gap) / segs_now
                    local chars = math.max(1, math.floor((sw - 4) / cw))
                    local pkey = table.concat({ bx, by, total, segs_now }, ':')
                    for k = 1, segs_now do
                        local sx = bx + (k - 1) * (sw + G.gap)
                        local sg = c.meter[k]
                        if seg_key ~= pkey then
                            place(pname('cellseg' .. k), sx, by, sw, z.cell_h)
                            seg_t[k]:pos(math.floor(sx + 2), math.floor(by + 1))
                        end
                        place(pname('cellsegfill' .. k), sx, by, sw * (sg.fill or 0), z.cell_h)
                        set_color(pname('cellseg' .. k), sg.locked
                            and { alpha = math.floor((COL.empty.alpha or 255) * 0.4), red = COL.empty.red, green = COL.empty.green, blue = COL.empty.blue }
                            or COL.empty)
                        set_color(pname('cellsegfill' .. k), sg.color or COL.empty)
                        local tc = (sg.fill or 0) > 0 and c.text_color or c.dim_color
                        set_text(seg_t[k], cs(tc, center(sg.text or '', chars)) .. '\n'
                            .. cs(c.text_color, center(sg.value or '', chars)))
                    end
                    seg_key = pkey
                end
            elseif c and not c.empty then
                -- A highlighted cell (pet heal while the pet HP alarm is on) flashes blue.
                local col = c.color
                -- (flash_color: flash between the cell colour and that one instead, e.g. low ammo)
                if c.flash and math.floor(os.clock() * 4) % 2 == 0 then
                    local f = c.flash_color or COL.ind_high
                    col = { alpha = c.flash_color and (f.alpha or 235) or 235, red = f.red, green = f.green, blue = f.blue }
                end
                set_color(pname('cell' .. i), col)
                local cw_i = sw > 1 and math.floor((sw * z.cell_w + (sw - 1) * G.gap - 6) / cw) or w
                set_text(cell_t[i], cs(c.label_color, center(c.label, cw_i)) .. '\n' .. cs(c.value_color, center(c.value, cw_i)))
            else
                set_color(pname('cell' .. i), COL.empty)
                set_text(cell_t[i], '')
            end
        end
    end

    if segs_now ~= seg_count then
        seg_count = segs_now
        if shown then apply_visibility() end
    end

    if n_ind ~= ind_count then
        ind_count = n_ind
        if shown then apply_visibility() end
    end

    anim_render(right and model.gif or nil, rx, body_top + VPAD, z.right_w)
end

-- Animation (COR bust): one prim per frame, created the first time it plays, only the
-- current frame visible. Frames are images/showbiz/01.png..., times in frames.lua (ms).

local function anim_load()
    if anim.frames then return #anim.frames > 0 end
    anim.frames = {}
    local dir = windower.addon_path .. 'images/showbiz/'
    local ok, times = pcall(dofile, dir .. 'frames.lua')
    if not ok or type(times) ~= 'table' then return false end
    anim.times, anim.total = times, 0
    for i, t in ipairs(times) do
        anim.total = anim.total + t
        local n = pname('gif' .. i)
        prim.create(n)
        prim.set_texture(n, dir .. ('%02d.png'):format(i))
        prim.set_fit_to_texture(n, false)
        prim.set_color(n, 255, 255, 255, 255)
        prim.set_visibility(n, false)
        anim.frames[i] = n
    end
    return #anim.frames > 0
end

anim_hide = function()
    if anim.cur > 0 and anim.frames and anim.frames[anim.cur] then
        prim.set_visibility(anim.frames[anim.cur], false)
    end
    anim.cur = 0
end

anim_destroy = function()
    for _, n in ipairs(anim.frames or {}) do prim.delete(n) end
    anim.frames, anim.cur = nil, 0
end

-- Play the animation so its bottom sits just above line 'line' (1-based) of the right-hand
-- column, at most 'lines' lines tall; nil stops it.
anim_render = function(g, rx, ry, right_w)
    if not (g and shown and anim_load()) then anim_hide() return end
    local lh = metrics.lh
    local h = g.lines * lh - 2
    local w = h * 4 / 3
    if w > right_w then w = right_w h = w * 3 / 4 end
    local y = ry + (g.line - 1) * lh - h - 1
    local t = (os.clock() * 1000) % anim.total
    local k = 1
    for i, d in ipairs(anim.times) do
        if t < d then k = i break end
        t = t - d
    end
    -- Centred over the text below it.
    local text_w = math.min(right_w, 21 * metrics.cw)
    place(anim.frames[k], rx + math.max(0, (text_w - w) / 2), y, w, h)
    if k ~= anim.cur then
        anim_hide()
        prim.set_visibility(anim.frames[k], true)
        anim.cur = k
    end
end

-- Low-HP alarm: while on, the frame alternates between the 'bad' colour and normal twice a
-- second. Turning it off restores the frame.
local alarm_on = false
function display.alarm(on)
    if not created then return end
    if not on and not alarm_on then return end
    alarm_on = on
    local c, strip = COL.border, COL.strip
    if on and math.floor(os.clock() * 4) % 2 == 0 then
        c = COL.ind_bad
        strip = { alpha = 210, red = COL.ind_bad.red, green = COL.ind_bad.green, blue = COL.ind_bad.blue }
    end
    for _, n in ipairs({ 'top', 'bottom', 'left', 'right' }) do set_color(pname(n), c) end
    set_color(pname('strip'), strip)
end

-- Force the next render to re-place everything (and re-apply visibility).
function display.invalidate()
    geom = {}
    if shown then apply_visibility() end
end

function display.hit(mx, my)
    return shown and geom.w and mx >= geom.x and mx <= geom.x + geom.w and my >= geom.y and my <= geom.y + geom.h
end

-- Grid cell index at a screen point, or nil.
function display.cell_at(mx, my)
    if not (shown and geom.cells) then return nil end
    for i, r in ipairs(geom.cells) do
        if mx >= r.x and mx < r.x + r.w and my >= r.y and my < r.y + r.h then return i end
    end
end

-- Hover details at a screen point, or nil.
function display.tip_at(mx, my)
    if not (shown and metrics and regions.model) then return nil end
    local function inside(r) return r and mx >= r.x and mx < r.x + r.w and my >= r.y and my < r.y + r.h end
    for _, r in ipairs(regions.inds or {}) do
        if inside(r) then return r.tip end
    end
    local cells = regions.model.cells or {}
    for i, r in ipairs(geom.cells or {}) do
        if inside(r) then
            local c = cells[i]
            return c and not c.empty and c.tip or nil
        end
    end
    local cw, lh = metrics.cw, metrics.lh
    for side, list in pairs(regions.model.hovers or {}) do
        local o = geom[side]
        if o and my >= o.y and mx >= o.x then
            local ln = math.floor((my - o.y) / lh)
            local col = (mx - o.x) / cw
            for _, h in ipairs(list) do
                if h.line == ln and col >= h.c0 and col < h.c1 then return h.tip end
            end
        end
    end
end

-- Show the tooltip near the mouse (kept on screen), or hide it with nil.
function display.tip(text, mx, my)
    if not tip_t then return end
    if not text then tip_t:visible(false) return end
    set_text(tip_t, text)
    local ws = windower.get_windower_settings()
    local w, h = tip_t:extents()
    if not w or w <= 0 then w, h = #text * metrics.cw + 8, metrics.lh + 8 end
    local tx, ty = mx + 16, my + 20
    if ws and ws.x_res and tx + w > ws.x_res then tx = mx - w - 8 end
    if ws and ws.y_res and ty + h > ws.y_res then ty = my - h - 8 end
    tip_t:pos(math.floor(tx), math.floor(ty))
    tip_t:visible(true)
end

-- Fade the cooldown grid (recess, cells and their text) when idle. 1 = solid. The rest of the
-- panel is left as it is.
function display.fade(f)
    f = math.max(0, math.min(1, f))
    if not created or math.abs(f - FADE) < 0.001 then return end
    FADE = f
    for i = 1, prim_cells do last_color[pname('cell' .. i)] = nil end
    set_color(pname('recess'), COL.recess)
    local st = STROKE or S.stroke
    local function fade_text(t)
        if not t then return end
        t:alpha(math.floor(255 * f))
        t:stroke_alpha(math.floor((st.alpha or 255) * f))
    end
    for _, t in ipairs(cell_t) do fade_text(t) end
    for _, t in ipairs(seg_t) do fade_text(t) end
    for i = 1, MAX_SEG do
        last_color[pname('cellseg' .. i)] = nil
        last_color[pname('cellsegfill' .. i)] = nil
    end
end

function display.faded() return FADE end

-- The panel's current pixel size (for tests and the 'layout' command).
function display.size() return geom.w, geom.h end

display.cs = cs

------------------------------------------------------------------------------------------
-- Party window: a second panel to the right of the main one (or wherever it was dragged to:
-- S.party_window_docked = false uses S.party_window_x / _y), same look. Created the first
-- time it's shown. model = { title = string, text = string (with colour codes), lines = n,
-- chars = width in characters } or nil to hide it.
------------------------------------------------------------------------------------------

local pw = { created = false }
local PW_PRIMS = { 'pw_body', 'pw_strip', 'pw_top', 'pw_bottom', 'pw_left', 'pw_right' }

local function pw_create()
    if pw.created then return end
    for _, n in ipairs(PW_PRIMS) do prim.create(pname(n)) prim.set_visibility(pname(n), false) end
    pw.title = texts.new('', text_settings())
    pw.text = texts.new('', text_settings())
    pw.created, pw.shown, pw.key = true, false, nil
end

local function pw_visible(on)
    if not pw.created or pw.shown == on then return end
    pw.shown = on
    for _, n in ipairs(PW_PRIMS) do prim.set_visibility(pname(n), on) end
    pw.title:visible(on)
    pw.text:visible(on)
end

function display.party_render(model)
    if not (model and shown and metrics and geom.w) then pw_visible(false) return end
    pw_create()
    local cw, lh = metrics.cw, metrics.lh
    local P = S.panel
    local pad, bw = P.pad, P.border
    local z = sizes()
    local x, y = geom.x + geom.w + 4, geom.y
    if S.party_window_docked == false then x, y = S.party_window_x, S.party_window_y end
    local W = math.floor(model.chars * cw + 2 * pad + 2 * bw)
    local body_lines = z.lines   -- the same height as the main panel
    local H = math.floor(z.strip_h + body_lines * lh + 2 * VPAD + pad / 2 + bw)
    pw.model, pw.geom = model, { x = x, y = y, w = W, h = H }
    local key = table.concat({ x, y, W, H }, ':')
    if pw.key ~= key then
        pw.key = key
        place(pname('pw_top'), x, y, W, bw)
        place(pname('pw_bottom'), x, y + H - bw, W, bw)
        place(pname('pw_left'), x, y + bw, bw, H - 2 * bw)
        place(pname('pw_right'), x + W - bw, y + bw, bw, H - 2 * bw)
        place(pname('pw_strip'), x + bw, y + bw, W - 2 * bw, z.strip_h - bw)
        place(pname('pw_body'), x + bw, y + z.strip_h, W - 2 * bw, H - z.strip_h - bw)
        pw.title:pos(math.floor(x + bw + pad), math.floor(y + VPAD))
        pw.text:pos(math.floor(x + bw + pad), math.floor(y + z.strip_h + VPAD))
    end
    set_color(pname('pw_body'), COL.body)
    set_color(pname('pw_strip'), COL.strip)
    for _, n in ipairs({ 'pw_top', 'pw_bottom', 'pw_left', 'pw_right' }) do set_color(pname(n), COL.border) end
    set_text(pw.title, model.title)
    set_text(pw.text, model.text)
    pw_visible(true)
end

local function pw_destroy()
    if not pw.created then return end
    for _, n in ipairs(PW_PRIMS) do prim.delete(pname(n)) end
    pw.title:destroy() pw.text:destroy()
    pw = { created = false }
end
display.party_destroy = pw_destroy

-- Is a screen point on the party window? / Where it is now (x, y, w, h).
function display.party_hit(mx, my)
    local g = pw.shown and pw.geom
    return g and mx >= g.x and mx <= g.x + g.w and my >= g.y and my <= g.y + g.h or false
end
function display.party_geom()
    local g = pw.geom
    if g then return g.x, g.y, g.w, g.h end
end
-- Draw it again with its last contents (after it's moved).
function display.party_refresh()
    if pw.shown and pw.model then display.party_render(pw.model) end
end
display.center = center

return display

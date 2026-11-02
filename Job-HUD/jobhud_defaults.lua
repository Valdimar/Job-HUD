--[[
    Job-HUD default settings.

    These are only the starting values. Each character gets its own copy in
    addons/Job-HUD/data/<CharacterName>.xml the first time they log in, and that file is
    what the addon reads from then on. Edit the file (then //jhud reload) or use the in-game
    commands; you never need to touch this file.

    List format (cooldowns / buffs / subjob lists): comma separated, names exactly as they
    appear in game. A cooldown may carry a short label for its grid cell: LABEL=Name.
    Several abilities share one timer (all Phantom Rolls, all Runes, all Quick Draws...);
    any one of them stands for the whole group.
]]

local defaults = {}

defaults.pos = { x = 200, y = 200 }
defaults.visible = true
defaults.locked = false          -- true: the HUD can't be dragged with the mouse
defaults.party_window = false        -- second window: party members and the buffs you can cast on them (//jhud pw)
defaults.party_window_width = 29     -- its width in characters (the same on every job)
defaults.dnc_fm_max = 9              -- DNC: most finishing moves you can hold (5, 7 with the 100 JP gift, 9 with 1200 JP)
defaults.dnc_step_jp = 20            -- DNC: your Step Duration job points (0-20): +1 s per Step and on the cap
defaults.dnc_dance_merits = 5        -- DNC: Saber / Fan Dance merits (Horos / Etoile gear raises the dances' floor by 1% each)
defaults.dnc_dance_reminder = true   -- DNC: 'no Waltz' / 'no Samba' under the dance stance
defaults.compact_mode = false        -- compact: no left rows / WS / SC; stances, shadows etc. on a narrow left column (//jhud compact)
defaults.party_window_docked = true  -- right beside the main window; false once you drag it away (//jhud pw reset)
defaults.party_window_x = 0          -- where it is when not docked
defaults.party_window_y = 0
defaults.party_window_skip = 'Sneak,Invisible,Deodorize,Spontaneity'   -- buffs left out of it
-- Which members a buff shows on in the party window: 'Buff=JOB JOB Name ...' (jobs or player
-- names). Buffs not listed show on everyone. Change in game: //jhud pw for <Buff> <JOB...> | all
defaults.party_window_for = 'Flurry=RNG COR,Refresh=WHM BLM RDM PLD DRK BLU SMN SCH GEO RUN BRD'
-- Buffs hidden on certain players or party slots: 'Storms=p2 Valda' hides all storms on party
-- slot 2 and on Valda (p0 = you). 'Storms' = all eight storms. //jhud pw hide / pw unhide.
defaults.party_window_hide = ''
defaults.ammo_warn = 10           -- RNG / COR ammo cell flashes red under this many
defaults.showbiz_gif = true      -- COR: play the bust animation above "That's showbiz, baby!"

defaults.font = 'Consolas'       -- use a monospaced font; columns are lined up with spaces
defaults.size = 10
defaults.bold = true
defaults.stroke = { width = 2, alpha = 255, red = 15, green = 15, blue = 15 }

-- Look. These change what's drawn without touching your <colors> below.
defaults.theme = 'lattice'       -- lattice (default) | light | contrast
defaults.palette = 'normal'      -- normal | redgreen (protanopia / deuteranopia) | tritan (tritanopia)
defaults.opacity = 100           -- panel and cell backgrounds, 0-100 (text always solid)
defaults.idle_opacity = 40       -- cooldown grid when not engaged; 100 = never fade, 0 = hide the grid
defaults.idle_delay = 10         -- seconds out of combat before it fades
defaults.tooltips = true         -- details when you hover the mouse over the panel
defaults.click_to_use = false    -- click a grid cell to use its ability / spell (//jhud clickuse on)
defaults.active_cells = true     -- one-use abilities (Stymie, Embolden...) turn purple while their effect waits on you

defaults.update_rate = 0.2       -- seconds between refreshes
defaults.hide_in_cutscene = true
defaults.hide_unavailable = false -- hide grid cells for abilities you can't use right now
defaults.hide_missing_buffs = true -- false: tracked buffs that are off still get a line, shown as "--"
defaults.buff_warn = 30          -- a buff timer turns yellow (orange under 10 s) and blinks at this many seconds left
defaults.upkeep_warn = 30        -- your buff tags turn yellow (orange under 10 s) and blink at this many seconds left
-- Debuff durations measured in play (filled in by the addon the first time each one wears off
-- on its own). Edit or clear to re-learn. Format: Angon:90,Gambit:80
defaults.debuff_times = ''
defaults.announce_ready = false  -- chat line when a tracked cooldown comes back up
defaults.target_distance = false -- add the target's distance (yalms) to the target row

-- When a cooldown counts as "coming up soon" (orange): either this many seconds or less
-- remain, or this fraction of the full recast remains, whichever is larger.
defaults.soon_seconds = 10
defaults.soon_pct = 0.2

-- Header indicators, left to right. Choose from:
--   engaged, ws, pet, food, reraise, signet, sneak, invis, sync
-- WS: green = can weapon skill, blue = 2000+ TP, yellow = Amnesia, red = can't (under
-- 1000 TP, or asleep / stunned / petrified / terrorized / charmed / impaired).
-- FOOD, RR, SNK and INVIS are red when you don't have them.
defaults.header = 'engaged,ws,food,reraise,sneak,invis'

defaults.panel = {
    pad = 6,         -- inner margin, pixels
    gutter = 12,     -- space between the text rows and the cooldown grid
    border = 1,      -- border width
}

-- The panel is the SAME SIZE on every job. Its size comes only from these numbers (and the
-- font), never from what a job puts on it: unused grid slots show as empty cells, and rows
-- beyond the line count are cut off (the last line then reads "+N more").
defaults.layout = {
    width = 32,          -- width of the text rows, in characters
    lines = 11,          -- number of text row lines; 0 = as many as fit beside the grid
    columns = 4,         -- cooldown grid columns
    grid_rows = 4,       -- cooldown grid rows (columns x grid_rows = cells available)
    right_width = 22,    -- width of the right-hand column (beside the grid), in characters; 0 = none
}

defaults.grid = {
    enabled = true,
    position = 'right',  -- 'right' of the rows, or 'bottom' under them
    cell_chars = 5,      -- width of a cell, in characters
    sub_position = 'bottom', -- support-job cells: 'bottom' row of the grid, or 'after' the job's
    gap = 2,
    inset = 3,
}

-- Charged abilities: Name:max charges[:seconds per charge]. The seconds are only a starting
-- guess; the addon measures the real charge time (gear, merits, job points) the first time you
-- use one. Stratagem charges follow your SCH level automatically.
defaults.charges = 'Penury:5:48,Fire Shot:2:60,Sic:3:30'

defaults.colors = {
    body     = { alpha = 190, red = 0,   green = 0,   blue = 0 },
    strip    = { alpha = 220, red = 30,  green = 30,  blue = 50 },
    border   = { alpha = 255, red = 110, green = 110, blue = 110 },
    recess   = { alpha = 235, red = 0,   green = 0,   blue = 0 },
    ready    = { alpha = 235, red = 46,  green = 160, blue = 74 },
    soon     = { alpha = 235, red = 222, green = 128, blue = 30 },
    cooldown = { alpha = 235, red = 178, green = 42,  blue = 42 },
    unavailable = { alpha = 235, red = 55, green = 62, blue = 78 },
    empty    = { alpha = 110, red = 28,  green = 32,  blue = 42 },
    ind_on   = { alpha = 255, red = 80,  green = 220, blue = 110 },
    ind_off  = { alpha = 255, red = 70,  green = 82,  blue = 104 },
    ind_bad  = { alpha = 255, red = 230, green = 70,  blue = 70 },
    ind_warn = { alpha = 255, red = 240, green = 210, blue = 60 },   -- WS square: Amnesia
    upkeep_warn = { red = 255, green = 230, blue = 70 },           -- upkeep tag about to wear off
    ind_high = { alpha = 255, red = 70,  green = 150, blue = 255 },  -- WS square: 2000+ TP
    label    = { red = 150, green = 170, blue = 205 },
    text     = { red = 235, green = 235, blue = 235 },
    dim      = { red = 120, green = 125, blue = 135 },
    good     = { red = 110, green = 230, blue = 130 },
    warn     = { red = 255, green = 170, blue = 60 },
    bad      = { red = 255, green = 90,  blue = 90 },
    accent   = { red = 186, green = 150, blue = 255 },
    active   = { red = 120, green = 220, blue = 255 },
    lower_tier = { red = 110, green = 170, blue = 255 },  -- party window: a weaker tier than you can cast
    soul_voice = { red = 255, green = 130, blue = 210 },  -- party window: a song sung under Soul Voice
    buffed   = { alpha = 235, red = 140, green = 80, blue = 210 },  -- highlighted cell whose effect is on you
}

--[[
    Rows. Whatever order you list them in, the panel always uses the standard order:
    gear / vitals / pet first, then target, then upkeep right under the target, then the rest.
    Available rows:
      weapon sub ranged ammo   item in that slot
      tp hp mp                 one vital per line
      vitals                   HP, MP and TP on one line
      upkeep                   short tags for buffs you keep up: green on, amber ending, red off
      ws                       last weapon skill and its damage (+ skillchain line if one closed)
      pet target               name and HP%
      buffs                    one line per tracked buff, with time left
      timers                   your own countdowns, set with //jhud timer
      runes                    RUN: active runes, and the elements they resist
      rolls                    COR: active rolls, roll number, lucky/unlucky
      shadows                  Utsusemi / Blink / Third Eye
      maneuvers                PUP: active maneuvers
      fm                       DNC: finishing moves
      arts                     SCH: Light / Dark Arts (+ Addendum)
      storm                    SCH: the storm on you, in its element's colour, with time left
      klimaform                SCH: Klimaform on / off
      sublimation              SCH: Sublimation Complete / Charging / Ready / recast
      inventory                inventory used / max
      notes                    values sent in with //jhud note (e.g. from GearSwap)

    Right-hand column ('right', beside the grid), same row names plus:
      window                   skillchain window on your target: wait, then a countdown to close
      debuffs                  your debuffs on the target (the job's 'debuffs' list) with time left
      burst                    magic burst window after a skillchain: countdown + elements
      aggro                    who your target is attacking: You / Pet / their name
      party                    tags for buffs others keep on you (the job's 'party' list), like upkeep

    danger = HP%: the panel frame and header flash red while your HP is below it (0 = off).
    highlight = grid cells (names or labels) whose background turns the 'buffed' colour while
    their effect is on you, e.g. Stymie,Spontaneity.
    pet_info = extra pet lines under the pet's HP: ready (Ready charges), target (what the pet is
    attacking), hate (who that mob is attacking: Pet / You / someone else).
    pet_alarm = HP%: under it your pet's lines flash red and ready Spirit Link / Steady Wing /
    Reward cells flash blue (0 = off).
]]
defaults.jobs = {
    DEFAULT = {
        rows = 'weapon,sub,vitals,target,ws,buffs,timers',
        cooldowns = '',
        buffs = '',
        upkeep = '',
        right = 'window,burst,aggro,party',
        debuffs = '',
        party = '#HSFL,MRCH=March,MADR=Madrigal,PROT=Protect,SHEL=Shell',
        danger = 0,
    },
    -- WAR: grid rows = core buffs / utility / 2-hours, then subjob.
    -- Upkeep goes red when Berserk, Aggressor, Restraint, Retaliation (or Hasso on /SAM) drops.
    WAR = {
        rows = 'weapon,sub,vitals,target,upkeep,ws,buffs,timers',
        cooldowns = "BRK=Berserk,WCRY=Warcry,AGGR=Aggressor,RSTR=Restraint,BLRG=Blood Rage,CHRG=Warrior's Charge,TOMA=Tomahawk,RETA=Retaliation,PROV=Provoke,DEF=Defender,MS=Mighty Strikes,BRZN=Brazen Rush",
        buffs = "Mighty Strikes,Brazen Rush",
        upkeep = 'BRK=Berserk,AGGR=Aggressor,RSTR=Restraint,RETA=Retaliation,HSSO=Hasso',
        right = 'window,burst,debuffs,aggro,party',
        debuffs = 'Tomahawk',
        party = '#HSFL,MRCH=March,MADR=Madrigal,PROT=Protect,SHEL=Shell',
        danger = 0,
    },
    MNK = {
        rows = 'weapon,sub,vitals,target,ws,buffs,timers',
        cooldowns = 'BST=Boost,FOC=Focus,DDG=Dodge,CHAK=Chakra,CNTR=Counterstance,FTWK=Footwork,IMP=Impetus,MANT=Mantra,FRML=Formless Strikes,PCTR=Perfect Counter,INNR=Inner Strength,HF=Hundred Fists',
        buffs = 'Impetus,Footwork,Focus,Counterstance',
    },
    WHM = {
        -- Left: upkeep tags, WS/SC, and with /SCH your Arts and Sublimation (time charging and
        -- estimated MP back). Right: Afflatus Solace / Misery. Grid: Divine Seal, Divine Caress,
        -- Sacrosanctity, Asylum / Devotion, Martyr, Benediction, Arise / Esuna, Sacrifice /
        -- support job (/SCH: stratagem bubbles).
        rows = 'weapon,sub,vitals,target,upkeep,ws,arts,sublimation,buffs,timers',
        right = 'window,burst,afflatus,storm,aggro,party',   -- storm: only shown with /SCH
        upkeep = 'PROT=Protect V|Protectra V|Protect IV|Protect III,SHEL=Shell V|Shellra V|Shell IV|Shell III,AUSP=Auspice,RGN=Regen IV|Regen III|Regen II|Regen',
        cooldowns = 'SEAL=Divine Seal,CRSS=Divine Caress,SANC=Sacrosanctity,ASYL=Asylum,DEVO=Devotion,MRTY=Martyr,BENE=Benediction,ARIS=Arise,ESNA=Esuna,SCRF=Sacrifice,_,_',
        buffs = 'Sacrosanctity,Asylum,Divine Seal,Divine Caress',
    },
    BLM = {
        rows = 'weapon,sub,vitals,target,ws,buffs,timers',
        cooldowns = 'ESEL=Elemental Seal,MWAL=Mana Wall,DOUS=Enmity Douse,MWEL=Manawell,CASC=Cascade,SUBT=Subtle Sorcery,MFNT=Manafont,STUN=Stun,ASP3=Aspir III,DETH=Death',
        buffs = 'Mana Wall,Manawell,Cascade,Manafont',
    },
    -- RDM (4 wide):  Composure  Haste      Refresh      Phalanx
    --                Temper     Stymie     Spontaneity  Convert
    --                Saboteur   Chainspell Dispel       Distract
    --                support job on the bottom row
    -- Stymie and Spontaneity cells turn purple while their effect is on you (highlight).
    -- 'A|B' = the first one you can cast (Haste II, else Haste).
    -- Left side: Composure, Haste, Refresh, Phalanx, Temper as tags (green on / yellow ending / red off).
    RDM = {
        rows = 'weapon,sub,vitals,target,upkeep,ws,timers',
        cooldowns = 'COMP=Composure,HSTE=Haste II|Haste,RFSH=Refresh III|Refresh II|Refresh,PHLX=Phalanx,TMPR=Temper II|Temper,STYM=Stymie,SPON=Spontaneity,CNVT=Convert,SABO=Saboteur,CHN=Chainspell,DSPL=Dispel,DIST=Distract III|Distract II|Distract',
        buffs = '',
        upkeep = 'COMP=Composure,HSTE=Haste II|Haste,RFSH=Refresh III|Refresh II|Refresh,PHLX=Phalanx,TMPR=Temper II|Temper',
        right = 'window,burst,aggro,party',
        debuffs = '',
        party = 'MRCH=March,MADR=Madrigal,PROT=Protect,SHEL=Shell',
        party_window = true,   -- the party window (buffs you can cast on each member) is on for RDM
        danger = 0,
    },
    THF = {
        rows = 'weapon,sub,vitals,target,ws,buffs,timers',
        cooldowns = 'SA=Sneak Attack,TA=Trick Attack,FEIN=Feint,BULY=Bully,CONS=Conspirator,COLL=Collaborator,DSPO=Despoil,FLEE=Flee,HIDE=Hide,PD=Perfect Dodge',
        buffs = 'Sneak Attack,Trick Attack,Feint,Conspirator,Flee',
    },
    PLD = {
        rows = 'weapon,sub,vitals,target,ws,buffs,timers',
        cooldowns = 'SENT=Sentinel,RAMP=Rampart,BASH=Shield Bash,PALI=Palisade,FEAL=Fealty,CHIV=Chivalry,MAJ=Majesty,EMBL=Divine Emblem,SEPU=Sepulcher,INV=Invincible,FLSH=Flash',
        buffs = 'Majesty,Enmity Boost,Phalanx,Reprisal,Protect,Shell',
    },
    DRK = {
        rows = 'weapon,sub,vitals,target,ws,buffs,timers',
        cooldowns = 'LR=Last Resort,SOUL=Souleater,BASH=Weapon Bash,ARC=Arcane Circle,NVOD=Nether Void,DSEL=Dark Seal,DEYE=Diabolic Eye,SDLR=Scarlet Delirium,CMNA=Consume Mana,BW=Blood Weapon,STUN=Stun,SE=Soul Enslavement',
        buffs = 'Last Resort,Souleater,Scarlet Delirium,Endark,Dread Spikes',
    },
    -- BST (4 wide):  Loyalty  Reward  Charm  Unleash
    --                Fight    Ready   Heel   Stay      (Heel and Stay share one timer)
    --                Snarl    Spur
    --                support job on the bottom row
    -- Buff timers (Killer Instinct...) are in the right column.
    BST = {
        rows = 'weapon,sub,vitals,pet,target,upkeep,ws,timers',
        cooldowns = 'LOYL=Bestial Loyalty,RWRD=Reward,CHRM=Charm,UNLS=Unleash,FGHT=Fight,RDY=Sic,HEEL=Heel,STAY=Stay,SNRL=Snarl,SPUR=Spur',
        buffs = 'Unleash,Killer Instinct,Spur',
        upkeep = '',
        right = 'window,burst,aggro,buffs,party',
        debuffs = '',
        party = '#HSFL,MRCH=March,MADR=Madrigal,PROT=Protect,SHEL=Shell',
        danger = 0,
        pet_alarm = 40,
        pet_info = 'ready,target,hate',
    },
    BRD = {
        rows = 'weapon,sub,ranged,vitals,target,ws,buffs,timers',
        -- Grid (each 2 wide): Nightingale | Troubadour / Pianissimo | Marcato / Clarion Call |
        -- Soul Voice / support job.
        cooldowns = 'NIGHTNGALE=Nightingale*2,TROUBADOUR=Troubadour*2,PIANISSIMO=Pianissimo*2,MARCATO=Marcato*2,CLARION=Clarion Call*2,SOUL VOICE=Soul Voice*2',
        buffs = 'Nightingale,Troubadour,Marcato,Soul Voice,Clarion Call',
        right = 'window,burst,foesong,aggro,party',   -- foesong: your songs on your target
        party_window = true,   -- the party window shows your songs on each member once sung
        song_slots = 5,        -- songs you keep on people (Clarion Call + Daurdabla: 5): unfilled ones show as grey SNG1, SNG2...
    },
    RNG = {
        -- Right: Hover Shot stacks and whether you've moved since your last shot.
        -- Grid: ammo (3 wide, flashes under ammo_warn) | Barrage / Shadowbind | Scavenge |
        -- Camouflage | Sharpshot / Bounty Shot (2 wide) | Double Shot (2 wide) / Flashy Shot |
        -- Stealth Shot | Overkill | Unlimited Shot ('?': only shown once merited).
        rows = 'weapon,sub,ranged,ammo,vitals,target,ws,buffs,timers',
        right = 'window,burst,aggro,hover,velocity,bounty,party',
        -- '#HASTE': FLRY (Flurry) while Velocity Shot is up, HSTE (Haste) when it isn't.
        party = '#HASTE,MRCH=March,MADR=Madrigal,PROT=Protect,SHEL=Shell',
        cooldowns = '#AMMO*3,BARR=Barrage,SHDW=Shadowbind,SCAV=Scavenge,CAMO=Camouflage,SHRP=Sharpshot,BOUNTY=Bounty Shot*2,DBL SHOT=Double Shot*2,?FLSH=Flashy Shot,?STLH=Stealth Shot,OVKL=Overkill,UNLM=Unlimited Shot',
        buffs = 'Velocity Shot,Double Shot,Barrage,Hover Shot,Sharpshot,Decoy Shot',
    },
    SAM = {
        rows = 'weapon,sub,vitals,target,ws,buffs,timers',
        cooldowns = 'MED=Meditate,HSSO=Hasso,SGN=Seigan,3EYE=Third Eye,SEKK=Sekkanoki,SENG=Sengikori,KONZ=Konzen-ittai,HAGA=Hagakure,BASH=Blade Bash,MEIK=Meikyo Shisui,YAEG=Yaegasumi',
        buffs = 'Hasso,Seigan,Third Eye,Sekkanoki,Meikyo Shisui',
    },
    NIN = {
        rows = 'weapon,sub,ammo,vitals,target,ws,shadows,buffs,timers',
        -- Grid: Utsusemi San | Ni | Ichi | Shihei count / Yonin | Issekigan | Sange | Futae /
        -- Innin | - | Mikage | - / support job. Right: Migawari On / Off.
        cooldowns = 'SAN=Utsusemi: San,NI=Utsusemi: Ni,ICHI=Utsusemi: Ichi,SHIH=#COUNT:Shihei,YON=Yonin,ISSK=Issekigan,SNGE=Sange,FUTA=Futae,INN=Innin,_,MIKG=Mikage,_',
        right = 'window,burst,migawari,aggro,party',
        buffs = 'Issekigan',   -- (Migawari and Yonin / Innin are on the right)
    },
    -- DRG (4 wide):  Jump  SPJ   HJ    SLJ
    --                Super  --   Link  Steady
    --                Angon  --   Rest  Smite      ('_' = empty slot)
    -- Upkeep: Hasso (only shown when you're /SAM).
    DRG = {
        rows = 'weapon,sub,vitals,pet,target,upkeep,ws',
        cooldowns = 'JUMP=Jump,SPJ=Spirit Jump,HJ=High Jump,SLJ=Soul Jump,SUPR=Super Jump,_,LINK=Spirit Link,STDY=Steady Wing,ANG=Angon,_,REST=Restoring Breath,SMIT=Smiting Breath',
        buffs = '',
        upkeep = 'HSSO=Hasso',
        right = 'window,burst,wyvern,debuffs,aggro,party',   -- wyvern: its HP and Steady Wing
        -- wyvern_hp = 1600,   -- the wyvern's max HP if you know it (otherwise learned in play)
        debuffs = 'Angon',
        party = '#HSFL,MRCH=March,MADR=Madrigal,PROT=Protect,SHEL=Shell',
        danger = 0,
        pet_alarm = 40,
    },
    SMN = {
        rows = 'weapon,sub,vitals,pet,target,ws,buffs,timers',
        cooldowns = "RAGE=Punch,WARD=Shining Ruby,APOG=Apogee,CEDE=Mana Cede,SIPH=Elemental Siphon,CNDT=Astral Conduit,AF=Astral Flow",
        buffs = "Avatar's Favor,Apogee,Astral Conduit",
    },
    BLU = {
        rows = 'weapon,sub,vitals,target,ws,buffs,timers',
        cooldowns = 'BRST=Burst Affinity,CHAN=Chain Affinity,EFLX=Efflux,DIFF=Diffusion,UNBR=Unbridled Learning,AZUR=Azure Lore,WIS=Unbridled Wisdom',
        buffs = 'Burst Affinity,Chain Affinity,Efflux,Diffusion',
    },
    COR = {
        -- Grid: Wild Card, Crooked Cards, Cutting Cards, Random Deal / Double-Up, Snake Eye,
        -- Fold, Quick Draw / '#ROLLS': rows 3-4 as two big boxes, one per Phantom Roll on you.
        rows = 'weapon,sub,ranged,ammo,vitals,target,ws,buffs,timers',
        cooldowns = "WILD=Wild Card,CROK=Crooked Cards,CUT=Cutting Cards,RAND=Random Deal,DBL=Double-Up,SNAK=Snake Eye,FOLD=Fold,QD=Fire Shot,#ROLLS",
        -- 'showbiz': after a bust, a line at the bottom of the right column.
        right = 'window,burst,aggro,party,showbiz',
        buffs = 'Triple Shot,Snake Eye,Crooked Cards',
    },
    PUP = {
        rows = 'weapon,sub,vitals,pet,target,ws,maneuvers,buffs,timers',
        cooldowns = 'ACTV=Activate,DEUS=Deus Ex Automata,RPR=Repair,MNVR=Fire Maneuver,DPLY=Deploy,ROLE=Role Reversal,VENT=Ventriloquy,TACT=Tactical Switch,COOL=Cooldown,OVDR=Overdrive,HEAD=Heady Artifice',
        buffs = 'Overdrive',
    },
    DNC = {
        -- Left: finishing moves (0-9) and flourishes waiting to go off; right: dance stance,
        -- samba, and the Daze from Steps on your target (level, and about how long it has left).
        rows = 'weapon,sub,vitals,target,ws,fm,flourish,buffs,timers',
        right = 'window,burst,dance,samba,steps,aggro,party',
        -- Grid: Presto | Steps | Flourishes II | Flourishes III /
        --       Saber Dance | Sambas | No Foot Rise | Flourishes I /
        --       Fan Dance | Contradance | Waltzes | Jigs /  Grand Pas | Trance (+ support job)
        -- Waltzes each have their own timer: the cell shows the highest one that's ready (CW5,
        -- CW4...), or the one back soonest. Jigs: SJIG, or CJIG while Chocobo Jig is on you.
        cooldowns = 'PRST=Presto,STEP=Box Step|Quick Step|Stutter Step|Feather Step,FL2=Reverse Flourish|Building Flourish|Wild Flourish,FL3=Climactic Flourish|Striking Flourish|Ternary Flourish,'
            .. 'SABR=Saber Dance,SMBA=Haste Samba|Drain Samba III|Drain Samba II|Drain Samba|Aspir Samba II|Aspir Samba,NFR=No Foot Rise,FL1=Animated Flourish|Violent Flourish|Desperate Flourish,'
            .. 'FAN=Fan Dance,CONT=Contradance,WLTZ=!Curing Waltz V|Curing Waltz IV|Curing Waltz III|Curing Waltz II|Curing Waltz,SJIG=Spectral Jig|Chocobo Jig,'
            .. 'GRND=Grand Pas,TRNC=Trance',
        buffs = 'Presto',   -- (samba, dance and flourishes have their own lines)
    },
    -- SCH: left side shows your Arts, storm, Klimaform and Sublimation.
    SCH = {
        rows = 'weapon,sub,vitals,target,ws,arts,storm,klimaform,sublimation,buffs,timers',
        -- 'Light/Dark' pairs switch with your Arts. Row 1: Accession Rapture Altruism -
        -- (Manifestation Ebullience Focalization), row 2: Penury Celerity Tranquility Perpetuance
        -- (Parsimony Alacrity Equanimity Immanence), row 3: '#STRAT', a bar of your stratagem
        -- charges, row 4: Sublimation Modus Veritas Enlightenment Tabula Rasa.
        cooldowns = 'ACCN=Accession/MANI=Manifestation,RAPT=Rapture/EBUL=Ebullience,ALTR=Altruism/FOCL=Focalization,_,PENU=Penury/PARS=Parsimony,CELR=Celerity/ALAC=Alacrity,TRNQ=Tranquility/EQUA=Equanimity,PERP=Perpetuance/IMMA=Immanence,#STRAT,SUBL=Sublimation,MODV=Modus Veritas,ENLT=Enlightenment,TAB=Tabula Rasa',
        buffs = 'Enlightenment',
    },
    GEO = {
        rows = 'weapon,sub,vitals,pet,target,ws,buffs,timers',
        -- Grid: one big box telling you to go use GEO-HUD.
        cooldowns = '#GEOHUD',
        buffs = 'Blaze of Glory,Entrust,Bolster,Collimated Fervor',
    },
    -- RUN (4 wide):  Aquaveil  Crusade   Temper   Phalanx
    --                Flash     Foil      Regen IV Refresh
    --                Vallation Valiance  Liement  Embolden
    --                Swipe     Lunge     Gambit   Rayke        (subjob on the bottom row)
    -- Left side: weapon, vitals, target, buff tags (green on / yellow ending / red off), then
    -- one section per rune you have up.
    -- A spell's label turns cyan while its effect is on you (e.g. CRSD while Crusade is up).
    RUN = {
        rows = 'weapon,sub,vitals,target,upkeep,ws,runes',
        cooldowns = 'AQVL=Aquaveil,CRSD=Crusade,TMPR=Temper,PHLX=Phalanx,FLSH=Flash,FOIL=Foil,RGN4=Regen IV,RFSH=Refresh,VALL=Vallation,VALI=Valiance,LIEM=Liement,EMBO=Embolden,SWIP=Swipe,LUNG=Lunge,GMBT=Gambit,RAYK=Rayke',
        buffs = '',
        upkeep = 'AQVL=Aquaveil,CRSD=Crusade,PHLX=Phalanx,TMPR=Temper,RGN=Regen IV,RFSH=Refresh',
        right = 'window,burst,debuffs,aggro,party',
        debuffs = 'Gambit,Rayke',
        party = '#HSFL,MRCH=March,MADR=Madrigal,PROT=Protect,SHEL=Shell',
        danger = 50,
    },
}

-- Extra cells added for your support job. Abilities you can't use yet at your subjob level
-- are left out automatically.
defaults.subjobs = {
    WAR = 'PROV=Provoke,BRK=Berserk,WCRY=Warcry,AGGR=Aggressor',
    MNK = 'BST=Boost,FOC=Focus,DDG=Dodge,CHAK=Chakra',
    WHM = 'SEAL=Divine Seal',
    BLM = 'ESEL=Elemental Seal',
    RDM = 'CNVT=Convert',
    THF = 'SA=Sneak Attack,TA=Trick Attack,FLEE=Flee',
    PLD = 'SENT=Sentinel,FLSH=Flash',
    DRK = 'LR=Last Resort,SOUL=Souleater,ARC=Arcane Circle,STUN=Stun',
    BST = 'RWRD=Reward',
    BRD = '',
    RNG = 'SHRP=Sharpshot,SCAV=Scavenge',
    SAM = 'MED=Meditate,HSSO=Hasso,SEKK=Sekkanoki',
    NIN = 'NI=Utsusemi: Ni,ICHI=Utsusemi: Ichi,_,SHIH=#COUNT:Shihei',   -- no stances as a support job (+ Shadows on the right)
    DRG = 'JUMP=Jump,HJ=High Jump,CIRC=Ancient Circle',
    SMN = '',
    BLU = '',
    COR = "ROLL=Fighter's Roll,DBL=Double-Up",
    PUP = '',
    DNC = 'STEP=Box Step,WLTZ=!Curing Waltz III|Curing Waltz II|Curing Waltz,SMBA=Haste Samba|Drain Samba II|Drain Samba,FL1=Animated Flourish|Violent Flourish',
    -- /SCH: your stratagem charges as 5 bubbles filling up (dark ones: more than your support
    -- level holds).
    SCH = '#STRAT',
    GEO = '',
    RUN = 'RUNE=Ignis,VALL=Vallation,PFLG=Pflug,SWRD=Swordplay',
}

return defaults

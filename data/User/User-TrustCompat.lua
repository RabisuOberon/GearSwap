-------------------------------------------------------------------------------------------------------------------
-- User-TrustCompat.lua  (v2)
--
-- Lets Cyrite Game Studios' Trust drive Selindrile's GearSwap without the two fighting each other.
--
-- Principle: GearSwap keeps ALL of its functionality. None of your states, binds or sets are changed.
-- While Trust is running, Sel's own decision-making (auto-WS, auto-buff, auto-arts, "use JA first and
-- re-send" substitutions, action re-queueing) steps aside, because Trust is the one deciding what to do.
-- GearSwap still picks every piece of gear. When Trust stops, everything behaves exactly as before.
--
-- Install: add this line to the END of Data/User/User-Globals.lua:
--     optional_include('User-TrustCompat.lua')
--
-- How GearSwap knows Trust is running (state.TrustMode):
--   on  : "// trust start", "// trust toggle", the Trust on-screen toggle, "// trust startall" from another box,
--         or Trust finishing loading on a job listed in trust_autostart_jobs (set per character, see below).
--   off : "// trust stop", zoning, dying, changing job (Trust stops/unloads in all of those by default).
--   manual override: gs c set TrustMode on|off  (e.g. after "// lua unload trust")
--
-- Commands for Trust "Command" gambits (quiet and idempotent, so repeated firing does nothing extra):
--   gs c trust set <State> <value>     e.g. //gs c trust set DefenseMode Physical
--   gs c trust reset <State>           e.g. //gs c trust reset DefenseMode
--   gs c trust on | off                mark Trust as running / stopped (always prints the result)
--   gs c trust status                  show whether GearSwap thinks Trust is driving
--
-- Zone mode sets: entering Sortie loads Trust's "Sortie" mode set, leaving loads "Default" (see bottom of file).
-------------------------------------------------------------------------------------------------------------------

state.TrustMode = M(false, 'Trust Mode')

-- Per-character settings go in your Data/<Name>/<Name>-Globals.lua (loaded after this file), e.g.:
--   trust_autostart_jobs = S{'PUP'}   -- jobs where Trust starts itself when it loads (Trust "Auto Enable Mode" = Auto).
--                                      -- Trust prints no "started" message then, so GearSwap watches for its
--                                      -- "Trust is up to date" load message on these jobs instead.
--   trust_dummy_songs_fallback = {"Goblin Gavotte", "Scop's Operetta"}  -- BRD: only used if Trust's file can't be read.

-- Sel states that are treated as off ONLY while Sel is deciding something (tick, pretarget, precast) and
-- ONLY while Trust is running. Their real values are untouched and restored immediately.
trust_deferred_states = {
	-- Action re-queueing: Sel cancels an action sent "too early"/while moving and re-sends it later itself.
	MiniQueue = false, Uninterruptible = 'Off',
	-- General automation that duplicates a Trust role.
	AutoBuffMode = 'Off', AutoWSMode = false, AutoNukeMode = false, AutoArts = false, AutoSambaMode = 'Off',
	AutoShadowMode = false, AutoSubMode = false, AutoFoodMode = false, AutoTrustMode = false,
	AutoJumpMode = false, AutoSuperJumpMode = false, AutoTankMode = false,
	-- Job toggles that cancel your action, use a job ability, then re-send the action.
	AutoManawell = false,   -- BLM: Manawell before nukes
	AutoPrestoMode = false, -- DNC: Presto before steps
	AutoBondMode = false,   -- DRG: Spirit Bond before Restoring Breath
	AutoEmblem = false,     -- PLD: Divine Emblem before Flash
	AutoConvert = false,    -- SMN/RDM: Convert
	AutoCaress = false,     -- WHM: Divine Caress before -na
	AutoCelerity = false,   -- WHM: Celerity before Arise/Raise III
	AutoEntrust = false,    -- GEO: Entrust before Indi- on party
	AutoUnbridled = false,  -- BLU: Unbridled Learning
	AutoBoost = false,      -- MNK: Boost/Warcry before WS
	AutoSongMode = false, AutoDummyMode = false, -- BRD: Trust picks songs and dummies
}
-- Not deferred on purpose (your Trust profiles don't do these, or they only change gear / handle emergencies):
-- AutoRuneMode (no Trust RUN profile casts runes), BST pet checks, AutoDefenseMode, AutoStunMode,
-- doom/Holy Water handling, ammo refills, Treasure Hunter, lockstyle, and "gs c buffup" (you asked for it).

-------------------------------------------------------------------------------------------------------------------
-- Scoped deferral
-------------------------------------------------------------------------------------------------------------------
local function defer_begin()
	if not state.TrustMode.value then return nil end
	local saved = {}
	for name, off_value in pairs(trust_deferred_states) do
		local s = state[name]
		if type(s) == 'table' and s.value ~= nil and s.value ~= off_value then
			saved[name] = s.value
			pcall(s.set, s, off_value)
		end
	end
	return saved
end

local function defer_end(saved)
	if not saved then return end
	for name, value in pairs(saved) do
		local s = state[name]
		if s then pcall(s.set, s, value) end
	end
end

local unpack = unpack or table.unpack
local function deferred(fn)
	return function(...)
		local saved = defer_begin()
		local results = {pcall(fn, ...)}
		defer_end(saved)
		if not results[1] then error(results[2], 0) end
		return unpack(results, 2, table.maxn(results))
	end
end

local wrapped = {}
local function wrap_global(name, wrapper)
	local fn = _G[name]
	if type(fn) == 'function' and wrapped[name] ~= fn then
		local new_fn = wrapper(fn)
		_G[name] = new_fn
		wrapped[name] = new_fn
	end
end

local TICK_FUNCTIONS = {'pre_tick', 'default_tick', 'job_tick', 'user_job_tick', 'user_tick', 'extra_user_job_tick', 'extra_user_tick'}

-------------------------------------------------------------------------------------------------------------------
-- BRD: dummy songs come straight from your Trust settings file, so the two never drift apart.
-------------------------------------------------------------------------------------------------------------------
trust_dummy_songs = S{}

local function load_trust_dummy_songs()
	trust_dummy_songs = S(type(trust_dummy_songs_fallback) == 'table' and trust_dummy_songs_fallback or {})
	if player.main_job ~= 'BRD' or not (io and io.open and windower.addon_path) then return end
	local candidates = {
		windower.addon_path .. '../trust/data/BRD_' .. player.name .. '.lua',
		windower.addon_path .. '../Trust/data/BRD_' .. player.name .. '.lua',
	}
	for _, path in ipairs(candidates) do
		local ok, f = pcall(io.open, path, 'r')
		if ok and f then
			local text = f:read('*a')
			f:close()
			local found = S{}
			for block in text:gmatch('DummySongs%s*=%s*L(%b{})') do
				for name in block:gmatch('Spell%.new%("([^"]+)"') do
					found:add(name)
				end
			end
			if next(found) then trust_dummy_songs = found end
			return
		end
	end
end

-------------------------------------------------------------------------------------------------------------------
-- Hooks
-------------------------------------------------------------------------------------------------------------------
local zone_name, zone_modeset, trust_has_modeset -- defined with the zone mode sets below

local function report_trust_mode(reason)
	add_to_chat(122, 'GearSwap: Trust ' .. (state.TrustMode.value and 'is driving, Sel automation deferred' or 'stopped, Sel automation active') .. (reason and (' (' .. reason .. ')') or '') .. '.')
end

local function set_trust_mode(on, reason, always_report)
	if state.TrustMode.value == on then
		if always_report then report_trust_mode(reason) end
		return
	end
	state.TrustMode:set(on)
	report_trust_mode(reason)
end

local previous_extra_user_setup = extra_user_setup
function extra_user_setup()
	if previous_extra_user_setup then previous_extra_user_setup() end

	for _, name in ipairs(TICK_FUNCTIONS) do wrap_global(name, deferred) end
	wrap_global('handle_actions', function(fn)
		local deferred_fn = deferred(fn)
		return function(spell, action)
			if action == 'pretarget' or action == 'precast' then
				return deferred_fn(spell, action)
			end
			return fn(spell, action)
		end
	end)

	-- Ungated substitutions in job files that duplicate what Trust already does itself.
	if player.main_job == 'BRD' or player.main_job == 'GEO' then
		wrap_global('job_filter_precast', function(fn)
			return function(spell, spellMap, eventArgs)
				if state.TrustMode.value then
					if spell.type == 'BardSong' then return end                -- Sel auto-Pianissimo
					if spell.english:startswith('Geo-') then return end         -- Sel auto-Full Circle
				end
				return fn(spell, spellMap, eventArgs)
			end
		end)
	end

	load_trust_dummy_songs()
end

local previous_extra_user_precast = extra_user_precast
function extra_user_precast(spell, spellMap, eventArgs)
	if previous_extra_user_precast then previous_extra_user_precast(spell, spellMap, eventArgs) end

	if state.TrustMode.value and spell.type == 'BardSong' and state.ExtraSongsMode and not spell.targets.Enemy
		and not state.ExtraSongsMode.value:endswith('Lock') then
		if trust_dummy_songs:contains(spell.english) then
			state.ExtraSongsMode:set('Dummy')
		elseif state.ExtraSongsMode.value == 'Dummy' then
			state.ExtraSongsMode:reset()
		end
	end
end

local previous_user_self_command = user_self_command
function user_self_command(commandArgs, eventArgs)
	if previous_user_self_command then previous_user_self_command(commandArgs, eventArgs) end
	if eventArgs.handled or not commandArgs[1] or commandArgs[1]:lower() ~= 'trust' then return end
	eventArgs.handled = true

	local sub = (commandArgs[2] or ''):lower()
	if sub == 'on' or sub == 'off' then
		set_trust_mode(sub == 'on', 'gs c trust ' .. sub, true)
		return
	end
	if sub == 'status' or sub == '' then
		local info = windower.ffxi.get_info()
		local zone = info and info.zone
		local set = zone_modeset(zone)
		report_trust_mode('compat loaded; dummy songs: ' .. (next(trust_dummy_songs) and 'yes' or 'none') ..
			'; zone ' .. zone_name(zone) .. ' (' .. tostring(zone) .. ')' ..
			(set and ('; zone mode set ' .. set .. (trust_has_modeset(set) and '' or ' (not in this job\'s Trust modes file)')) or '; no zone mode set'))
		return
	end

	local s = commandArgs[3] and get_state and get_state(commandArgs[3])
	if not s then
		add_to_chat(123, 'gs c trust: usage "gs c trust set <State> <value>", "gs c trust reset <State>", "gs c trust on|off".')
		return
	end

	local old = s.value
	if sub == 'set' and commandArgs[4] then
		local ok = pcall(s.set, s, table.concat(commandArgs, ' ', 4))
		if not ok then add_to_chat(123, 'gs c trust: invalid value for ' .. commandArgs[3]) return end
	elseif sub == 'reset' then
		s:reset()
	else
		return
	end

	if s.value ~= old then
		if state_change then state_change(s.description or commandArgs[3], s.value, old) end
		if not midaction() then handle_equipping_gear(player.status) end
	end
end

local previous_user_state_change = user_state_change
function user_state_change(stateField, newValue, oldValue)
	if previous_user_state_change then previous_user_state_change(stateField, newValue, oldValue) end
	if stateField == 'Trust Mode' and newValue ~= oldValue then
		add_to_chat(122, 'GearSwap: Sel automation ' .. (newValue and 'deferred to Trust.' or 'active.'))
	end
end

add_to_chat(122, 'GearSwap: Trust compatibility loaded (gs c trust status).')

-- Trust prints "Trust: GeneralTrustCommands Trust started/stopped" for start, stop, toggle, the UI toggle and startall.
windower.raw_register_event('incoming text', function(original)
	if type(original) ~= 'string' then return end
	-- Trust finished loading; with Auto Enable Mode = Auto it has just started itself.
	if original:find('Trust is up to date (', 1, true) then
		local auto = trust_autostart_jobs
		if type(auto) == 'table' and player and auto[player.main_job] then set_trust_mode(true, 'Trust auto-started on ' .. player.main_job) end
		return
	end
	if not original:find('GeneralTrustCommands', 1, true) then return end
	if original:find('Trust started', 1, true) then
		set_trust_mode(true)
	elseif original:find('Trust stopped', 1, true) then
		set_trust_mode(false)
	end
end)

-------------------------------------------------------------------------------------------------------------------
-- Zone mode sets: load a Trust mode set when you enter a zone, and Default again when you leave it.
-- Trust can't do this itself (it turns off when you zone, so its zone-change reactions never fire).
-- Only loads a mode set that exists in this job's Trust modes file (trust/data/modes/<JOB>_<Name>.lua),
-- so jobs without a "Sortie" mode set are left alone. Override in <Name>-Globals.lua, e.g.
--   trust_zone_modesets = {[275] = 'Sortie'}     -- zone id -> mode set; {} turns this off
--   trust_zone_modeset_delay = 5                  -- seconds after zoning before loading
-------------------------------------------------------------------------------------------------------------------
local DEFAULT_ZONE_MODESETS = {
	[275] = 'Sortie', -- Outer Ra'Kaznar [U1]
	[133] = 'Sortie', -- Outer Ra'Kaznar [U2]
	[189] = 'Sortie', -- Outer Ra'Kaznar [U3]
}

function trust_has_modeset(name)
	if not (io and io.open and windower.addon_path and player and player.main_job) then return false end
	for _, dir in ipairs({'trust', 'Trust'}) do
		local ok, f = pcall(io.open, windower.addon_path .. '../' .. dir .. '/data/modes/' .. player.main_job .. '_' .. player.name .. '.lua', 'r')
		if ok and f then
			local text = f:read('*a')
			f:close()
			return text:find('["' .. name .. '"]', 1, true) ~= nil
		end
	end
	return false
end

-- Also matched by zone name, in case the ids differ: any "Outer Ra'Kaznar [U...]" zone is Sortie.
local DEFAULT_ZONE_NAME_MODESETS = {["Outer Ra'Kaznar [U"] = 'Sortie'}

function zone_name(zone_id)
	local zone = zone_id and res and res.zones and res.zones[zone_id]
	return zone and zone.en or tostring(zone_id)
end

function zone_modeset(zone_id)
	if not zone_id then return nil end
	local map = rawget(_G, 'trust_zone_modesets')
	if type(map) == 'table' then return map[zone_id] end
	if DEFAULT_ZONE_MODESETS[zone_id] then return DEFAULT_ZONE_MODESETS[zone_id] end
	local name = zone_name(zone_id)
	for prefix, set in pairs(DEFAULT_ZONE_NAME_MODESETS) do
		if name:sub(1, #prefix) == prefix then return set end
	end
end

local function load_zone_modeset(new_id, old_id)
	local entering, leaving = zone_modeset(new_id), zone_modeset(old_id)
	local name = entering or (leaving and 'Default')
	if not name or entering == leaving then return end
	if not trust_has_modeset(name) then
		add_to_chat(122, 'GearSwap: no Trust "' .. name .. '" mode set for ' .. player.main_job .. ', not loading it.')
		return
	end
	local delay = tonumber(rawget(_G, 'trust_zone_modeset_delay')) or 5
	add_to_chat(122, 'GearSwap: loading Trust mode set "' .. name .. '" in ' .. delay .. 's.')
	send_command('wait ' .. delay .. '; trust load ' .. name)
end

-- Trust stops on zone (Auto Disable Mode = Auto in all your profiles) and unloads on death by default.
windower.raw_register_event('zone change', function(new_id, old_id)
	set_trust_mode(false, 'zoned')
	load_zone_modeset(new_id, old_id)
end)
windower.raw_register_event('status change', function(new_status)
	if new_status == 2 or new_status == 3 then set_trust_mode(false, 'KO') end
end)

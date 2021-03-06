-- Copyright 2015, Björn Ståhl
-- License: 3-Clause BSD
-- Reference: http://durden.arcan-fe.com
-- Description: Global / Persistent configuration management copied from
-- senseye, tracks default font, border, layout and other settings.
--

-- here for the time being, will move with internationalization
LBL_YES = "yes";
LBL_NO = "no";
LBL_BIND_COMBINATION = "Press and hold the desired combination, %s to Cancel";
LBL_BIND_KEYSYM = "Press and hold single key to bind keysym %s, %s to Cancel";
LBL_BIND_COMBINATION_REP = "Press and hold or repeat- press, %s to Cancel";
LBL_UNBIND_COMBINATION = "Press and hold the combination to unbind, %s to Cancel";
LBL_METAGUARD = "Query Rebind in %d keypresses";
LBL_METAGUARD_META = "Rebind (meta keys) in %.2f seconds, %s to Cancel";
LBL_METAGUARD_BASIC = "Rebind (basic keys) in %.2f seconds, %s to Cancel";
LBL_METAGUARD_MENU = "Rebind (global menu) in %.2f seconds, %s to Cancel";
LBL_METAGUARD_TMENU = "Rebind (target menu) in %.2f seconds, %s to Cancel";

HC_PALETTE = {
	"\\#efd469",
	"\\#43abc9",
	"\\#cd594a",
	"\\#b5c689",
	"\\#f58b4c"
};

local defaults = {
	msg_timeout = 100,
	tbar_timeout = 200,
	font_def = "default.ttf",
	font_fb = "emoji.ttf",
	font_sz = 18,
	font_hint = 2,
	font_str = "",
	text_color = "\\#aaaaaa",
	label_color = "\\#ffff00",
	borderw = 1,
	bordert = 1,

-- right now, the options are 'none' and 'auto'
	preview_mode = "auto",

-- should entries that request a password show the input as *** chars
	passmask = false,

--
-- advanced lockscreen features, not currently mapped to UI
-- lock_ok = "!/some/path/like/resume_all",
-- lock_on = "!/some/path/like/suspend_all"
-- lock_fail_1 = "!/system/output=fail_once",
-- lock_fail_10 = "!/system/shutdown/ok",
--

-- default window dimensions (relative tiler size) for windows
-- created in float mode with unknown starting size
	float_defw = 0.3,
	float_defh = 0.2,

-- default encoder setting, used by suppl when building string. We don't
-- have a way to query the span of these parameters yet (like available
-- codecs).
	enc_fps = 30,
	enc_srate = -1,
	enc_vcodec = "H264",
	enc_vpreset = 8,
	enc_container = "mkv",
	enc_presilence = 0,
	enc_vbr = 0,

-- SECURITY: set to :disabled to disable these features, or enable
-- whitelist and modify whitelist.lua to set allowed commands and paths
	extcon_path = "durden",
	status_path = "status",
	control_path = "control",
	output_path = "output",
	whitelist = false,

-- only enabled manually, only passive for now
	remote_port = 5900,
	remote_pass = "guest",

-- MANUAL/REQUIRES RESTART: setting this to true possibly reduces latency,
-- performance footprint etc. but prevents certain features like selective
-- desktop sharing and multiple displays.
	display_simple = false,
	display_shader = "basic",

-- some people can't handle the flash transition between workspaces,
-- setting this to a higher value adds animation fade in/out
	transition = 10,
	animation = 10,

-- (none, move-h, move-v, fade)
	ws_transition_in = "fade",
	ws_transition_out = "fade",
	ws_autodestroy = true,
	ws_autoadopt = true,
	ws_default = "tile",

-- per window toggle, global default here
	hide_titlebar = false,

-- we repeat regular mouse/mstate properties here to avoid a separate
-- path for loading / restoring / updating
	mouse_focus_event = "click", -- motion, hover
	mouse_remember_position = true,
	mouse_factor = 1.0,
	mouse_autohide = true,
	mouse_reveal = true,
	mouse_dblclick_step = 12,
	mouse_hidetime = 120,
	mouse_hovertime = 40,
	mouse_dragdelta = 4,

-- used for keyboard- move step size in float mode
	float_tile_sz = {16, 16},

-- used as a workaround for mouse-control issues when we cannot get
-- relative samples etc. due to being in a windows mode with different
-- scaling parameters, SDL on OSX for instance.
	mouse_hardlock = true,

-- "native' or "nonnative", while native is more energy- efficient as mouse
-- motion do not contribute to a full refresh, it may be bugged on some
-- platforms and have problems with multiple monitors right now.
	mouse_mode = "nonnative",
	mouse_scalef = 1.0,

-- audio settings
	global_gain = 1.0,
	gain_fade = 10,
	global_mute = false,

-- default keyboard repeat rate for all windows, some archetypes have
-- default overrides and individual windows can have strong overrides
	kbd_period = 4,
	kbd_delay = 300,

-- built-in terminal defaults
	term_autosz = true, -- will ignore cellw / cellh and use font testrender
	term_cellw = 12,
	term_cellh = 12,
	term_font_sz = 12,
	term_font_hint = 2,
	term_font = "hack.ttf",
	term_bgcol = {0x00, 0x00, 0x00},
	term_fgcol = {0xff, 0xff, 0xff},
	term_opa = 1.0,

-- input bar graphics
	lbar_dim = 0.8,
	lbar_tpad = 4,
	lbar_bpad = 0,
	lbar_spacing = 10,
	lbar_sz = 12, -- dynamically recalculated on font changes
	lbar_bg = {0x33, 0x33, 0x33},
	lbar_textstr = "\\#cccccc ",
	lbar_alertstr = "\\#ff0000 ",
	lbar_labelstr = "\\#00ff00 ",
	lbar_menulblstr = "\\#ffff00 ",
	lbar_menulblselstr = "\\#ffff00 ",
	lbar_helperstr = "\\#ffffff ",
	lbar_errstr = "\\#ff4444 ",
	lbar_caret_w = 2,
	lbar_caret_h = 16,
	lbar_caret_col = {0x00, 0xff, 0x00},
	lbar_seltextstr = "\\#ffffff ",
	lbar_seltextbg = {0x44, 0x66, 0x88},
	lbar_itemspace = 10,
	lbar_textsz = 12,

-- binding bar
	bind_waittime = 30,
	bind_repeat = 5,

-- sbar
	sbar_tpad = 2,
	sbar_bpad = 2,
	sbar_sz = 12, -- dynamically recalculated on font changes
	sbar_textstr = "\\#00ff00 ",
	sbar_alpha = 0.3,

-- titlebar
	tbar_sz = 12, -- dynamically recalculated on font changes
	tbar_tpad = 2,
	tbar_bpad = 2,
	tbar_text = "left", -- left, center, right
	tbar_textstr = "\\#ffffff ",
	pretiletext_color = "\\#ffffff ",

-- LWA specific settings, only really useful for development / debugging
	lwa_autores = true
};

local listeners = {};
function gconfig_listen(key, id, fun)
	if (listeners[key] == nil) then
		listeners[key] = {};
	end
	listeners[key][id] = fun;
end

function gconfig_set(key, val)
if (type(val) ~= type(defaults[key])) then
		warning(string.format("gconfig_set(), type (%s) mismatch (%s) for key (%s)",
			type(val), type(defaults[key]), key));
		return;
	end

	defaults[key] = val;

	if (listeners[key]) then
		for k,v in pairs(listeners[key]) do
			v(key, val);
		end
	end
end

local allowed = system_load("whitelist.lua")();

-- whitelist used for control channel
local allowed = {
	input_lock_on = true,
	input_lock_off = true,
	input_lock_toggle = true
};

function allowed_commands(cmd)
	if (cmd == nil or string.len(cmd) == 0) then
		return false;
	end

	print("check", cmd, gconfig_get("whitelist"));
	local rv = string.split(cmd, "=")[1];
	return gconfig_get("whitelist") == false or
		allowed[cmd];
end

function gconfig_get(key)
	return defaults[key];
end

local function gconfig_setup()
	for k,vl in pairs(defaults) do
		local v = get_key(k);
		if (v) then
			if (type(vl) == "number") then
				defaults[k] = tonumber(v);
-- no packing format for tables, ignore for now, since its a trusted context,
-- we can use concat / split without much issue, although store_key should
-- really support deep table serialization
			elseif (type(vl) == "table") then
				defaults[k] = defaults[k];
			elseif (type(vl) == "boolean") then
				defaults[k] = v == "true";
			else
				defaults[k] = v;
			end
		end
	end

	local ms = mouse_state();
	mouse_acceleration(defaults.mouse_factor, defaults.mouse_factor);
	ms.autohide = defaults.mouse_autohide;
	ms.hover_ticks = defaults.mouse_hovertime;
	ms.drag_delta = defaults.mouse_dragdelta;
	ms.hide_base = defaults.mouse_hidetime;
end

-- shouldn't store all of default overrides in database, just from a
-- filtered subset
function gconfig_shutdown()
	local ktbl = {};
	for k,v in pairs(defaults) do
		if (type(v) ~= "table") then
			ktbl[k] = tostring(v);
		end
	end

	store_key(ktbl);
end

gconfig_setup();

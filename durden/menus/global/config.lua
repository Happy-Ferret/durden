hint_lut = {
	none = 0,
	mono = 1,
	light = 2,
	normal = 3,
	subpixel = 4 -- need to specify +1 in the case of rotated display
};

TERM_HINT_RLUT = {};
for k,v in pairs(hint_lut) do TERM_HINT_RLUT[v] = k; end

local durden_font = {
	{
		name = "size",
		label = "Size",
		kind = "value";
		validator = gen_valid_num(1, 100),
		initial = function() return tostring(gconfig_get("font_sz")); end,
		handler = function(ctx, val)
			gconfig_set("font_sz", tonumber(val));
		end
	},
	{
		name = "hinting",
		label = "Hinting",
		kind = "value",
		set = {"none", "mono", "light", "normal", "subpixel"},
		initial = function() return TERM_HINT_RLUT[gconfig_get("font_hint")]; end,
		handler = function(ctx, val)
			gconfig_set("font_hint", hint_lut[val]);
		end
	},
	{
		name = "name",
		label = "Font",
		kind = "value",
		set = function()
			local set = glob_resource("*", SYS_FONT_RESOURCE);
			set = set ~= nil and set or {};
			return set;
		end,
		initial = function() return gconfig_get("font_def"); end,
		handler = function(ctx, val)
			gconfig_set("font_def", val);
		end
	},
	{
		name = "fbfont",
		label = "Fallback",
		kind = "value",
		set = function()
			local set = glob_resource("*", SYS_FONT_RESOURCE);
			set = set ~= nil and set or {};
			return set;
		end,
		initial = function() return gconfig_get("font_fb"); end,
		handler = function(ctx, val)
			gconfig_set("font_fb", val);
		end
	}
};

local function relay_alldisp()
end

local tb_buttons = {
	{
		name = "add_left",
		label = "Add(Left)",
		kind = "action",
		handler = function()
			local bar = active_display():lbar(
				function(ctx, instr, done, lastv)
-- missing: select subpath, actually adding the buttons,
-- altering wnd_create, applying to existing windows,
-- allowing subpath select that takes either global or target path..
-- but then it works for both wnd_title and statusbar
			end, ctx, {label = "specify byte-sequence:"});
		end
	},
};

local durden_bars = {
	{
		name = "sb_top",
		label = "Pad Top",
		kind = "value",
		initial = function() return gconfig_get("sbar_tpad"); end,
		validator = function() return gen_valid_num(0, gconfig_get("sbar_sz")); end,
		handler = function(ctx, val)
			gconfig_set("sbar_tpad", tonumber(val));
			gconfig_set("tbar_tpad", tonumber(val));
			gconfig_set("lbar_tpad", tonumber(val));
		end
	},
	{
		name = "sb_bottom",
		label = "Pad Bottom",
		kind = "value",
		initial = function() return gconfig_get("sbar_bpad"); end,
		validator = function() return gen_valid_num(0, gconfig_get("sbar_sz")); end,
		handler = function(ctx, val)
			gconfig_set("sbar_bpad", tonumber(val));
			gconfig_set("tbar_bpad", tonumber(val));
			gconfig_set("lbar_bpad", tonumber(val));
		end
	},
	{
		name = "tb_buttons",
		label = "Titlebar(Buttons)",
		kind = "action",
		eval = function() return false; end,
		submenu = true,
		handler = tb_buttons
	},
	{
		name = "tb_hide",
		label = "Hide Titlebar",
		kind = "value",
		set = {LBL_YES, LBL_NO},
		initial = function() return
			gconfig_get("hide_titlebar") and LBL_YES or LBL_NO end,
		handler = function(ctx, val)
			gconfig_set("hide_titlebar", val == LBL_YES);
		end
	}
}
;

local durden_visual = {
-- thickness is dependent on area, make sure the labels and
-- constraints update dynamically
	{
		name = "font",
		label = "Font",
		kind = "action",
		submenu = true,
		handler = durden_font
	},
	{
		name = "bars",
		label = "Bars",
		kind = "action",
		submenu = true,
		handler = durden_bars
	},
	{
		name = "border_vsz",
		label = "Border Thickness",
		kind = "value",
		hint = function() return
			string.format("(0..%d)", gconfig_get("borderw")) end,
		validator = function(val)
			return gen_valid_num(0, gconfig_get("borderw"))(val);
		end,
		initial = function() return tostring(gconfig_get("bordert")); end,
		handler = function(ctx, val)
			local num = tonumber(val);
			gconfig_set("bordert", tonumber(val));
			active_display():rebuild_border();
			for k,v in pairs(active_display().spaces) do
				v:resize();
			end
		end
	},
	{
		name = "border_area",
		label = "Border Area",
		kind = "value",
		hint = "(0..20)",
		inital = function() return tostring(gconfig_get("borderw")); end,
		validator = gen_valid_num(0, 20),
		handler = function(ctx, val)
			gconfig_set("borderw", tonumber(val));
			active_display():rebuild_border();
			for k,v in pairs(active_display().spaces) do
				v:resize();
			end
		end
	},
	{
		name = "shaders",
		label = "Shaders",
		kind = "action",
		submenu = true,
		handler = system_load("menus/global/shaders.lua")();
	},
	{
		name = "mouse_scale",
		label = "Mouse Scale",
		kind = "value",
		hint = "(0.1 .. 10.0)",
		initial = function() return tostring(gconfig_get("mouse_scalef")); end,
		handler = function(ctx, val)
			gconfig_set("mouse_scalef", tonumber(val));
			display_cycle_active(true);
		end
	},
	{
		name = "anim_speed",
		label = "Animation Speed",
		kind = "value",
		hint = "(1..100)",
		validator = gen_valid_num(1, 100),
		initial = function() return tostring(gconfig_get("animation")); end,
		handler = function(ctx, val)
			gconfig_set("animation", tonumber(val));
		end
	},
	{
		name = "trans_speed",
		label = "Transition Speed",
		kind = "value",
		hint = "(1..100)",
		validator = gen_valid_num(1, 100),
		initial = function() return tostring(gconfig_get("transition")); end,
		handler = function(ctx, val)
			gconfig_set("transition", tonumber(val));
		end
	},
	{
		name = "anim_in",
		label = "In-Animation",
		kind = "value",
		set = {"none", "fade", "move-h", "move-v"},
		initial = function() return tostring(gconfig_get("ws_transition_in")); end,
		handler = function(ctx, val)
			gconfig_set("ws_transition_in", val);
		end
	},
	{
		name = "anim_out",
		label = "Out-Animation",
		kind = "value",
		set = {"none", "fade", "move-h", "move-v"},
		initial = function() return tostring(gconfig_get("ws_transition_out")); end,
		handler = function(ctx, val)
			gconfig_set("ws_transition_out", val);
		end
	},
};

local durden_workspace = {
	{
		name = "autodel",
		label = "Autodelete",
		kind = "value",
		set = {LBL_YES, LBL_NO},
		initial = function() return
			gconfig_get("ws_autodestroy") and LBL_YES or LBL_NO end,
		handler = function(ctx, val)
			gconfig_set("ws_autodestroy", val == LBL_YES);
		end
	},
	{
		name = "defmode",
		label = "Default Mode",
		kind = "value",
		set = {"tile", "tab", "vtab", "float"},
		initial = function() return tostring(gconfig_get("ws_default")); end,
		handler = function(ctx, val)
			gconfig_set("ws_default", val);
		end
	},
	{
		name = "adopt",
		label = "Autoadopt",
		kind = "value",
		set = {LBL_YES, LBL_NO},
		eval = function() return gconfig_get("display_simple")
			and LBL_YES or LBL_NO; end,
		initial = function() return tostring(gconfig_get("ws_autoadopt")); end,
		handler = function(ctx, val)
			gconfig_set("ws_autoadopt", val == LBL_YES);
		end
	}
};

local durden_system = {
	{
		name = "cpath",
		label = "Connection Path",
		kind = "value",
		hint = "(a..Z_)",
		validator = strict_fname_valid,
		initial = function() local path = gconfig_get("extcon_path");
			return path == ":disabled" and "[disabled]" or path;
		end,
		handler = function(ctx, val)
			gconfig_set("extcon_path", val);
			if (valid_vid(INCOMING_ENDPOINT)) then
				delete_image(INCOMING_ENDPOINT);
				INCOMING_ENDPOINT = nil;
			end
			if (string.len(val) == 0) then
				val = ":disabled";
			else
				durden_new_connection();
			end
		end
	},
	{
		name = "ctrlpipe",
		label = "Control Pipe",
		kind = "value",
		hint = "(a..Z_)",
		validator = strict_fname_valid,
		initial = function() local path = gconfig_get("control_path");
			return path == ":disabled" and "[disabled]" or path;
		end,
		handler = function(ctx, val)
			if (CONTROL_CHANNEL) then
				CONTROL_CHANNEL:close();
				zap_resource(gconfig_get("control_path"));
				CONTROL_CHANNEL = nil;
			end

			if (string.len(val) == 0) then
				val = ":disabled";
			else
				COMMAND_CHANNEL = open_nonblock("<ipc/" .. val);
			end
			gconfig_set("control_path", val);
		end
	},
	{
		name = "ctrlwhitelist",
		label = "Whitelist",
		kind = "value",
		initial = function() return
			gconfig_get("whitelist") and LBL_YES or LBL_NO;
		end,
		set = {LBL_YES, LBL_NO},
		handler = function(ctx, val)
			gconfig_set("whitelist", val == LBL_YES);
		end
	},
	{
		name = "statpipe",
		label = "Status Pipe",
		kind = "value",
		hint = "(a..Z_)",
		validator = strict_fname_valid,
		initial = function() local path = gconfig_get("status_path");
			return path == ":disabled" and "[disabled]" or path;
		end,
		handler = function(ctx, val)
			if (STATUS_CHANNEL) then
				STATUS_CHANNEL:close();
				zap_resource(gconfig_get("status_path"));
				STATUS_CHANNEL = nil;
			end

			if (string.len(val) == 0) then
				val = ":disabled";
			else
				STATUS_CHANNEL = open_nonblock("<ipc/" .. val);
			end

			gconfig_set("status_path", val);
		end
	},
	{
		name = "outpipe",
		label = "Output Pipe",
		kind = "value",
		hint = "(a..Z_)",
		validator = strict_fname_valid,
		initial = function() local path = gconfig_get("output_path");
				return path == ":disabled" and "[disabled]" or path;
		end,
		handler = function(ctx, val)
			if (OUTPUT_CHANNEL) then
				OUTPUT_CHANNEL:close();
				zap_resource(gconfig_get("output_path"));
				OUTPUT_CHANNEL = nil;
			end

			if (string.len(val) == 0) then
				val = ":disabled";
			else
				OUTPUT_CJANNEL = open_nonblock("<ipc/" .. val, true);
			end

			gconfig_set("output_path", val);
		end
	},
	{
		name = "dispmode",
		label = "Display Mode",
		kind = "value",
		set = {"Simple", "Normal"},
		initial = function() return gconfig_get("display_simple") and
			"Simple" or "Normal"; end,
		handler = function(ctx, val)
			gconfig_set("display_simple", val == "Simple");
			active_display():message("Switching Displaymode, Reset Required.");
		end
	}
};

local recmenu = {
	{
	name = "fps",
	label = "Framerate",
	kind = "value",
	hint = "(10..60)",
	validator = gen_valid_num(10, 60),
	initial = function() return tostring(gconfig_get("enc_fps")); end,
	handler = function(ctx, val)
		gconfig_set("enc_fps", tonumber(val));
	end
	},
	{
	name = "preset",
	label = "Video Quality Preset",
	kind = "value",
	hint = "(0:disable..10:max, overrides bitrate)",
	validator = gen_valid_num(0, 10),
	initial = function() return tostring(gconfig_get("enc_vpreset")); end,
	handler = function(ctx, val)
		gconfig_set("enc_vpreset", tonumber(val));
		gconfig_set("enc_vbr", tonumber(val) == 0 and 800 or 0);
	end
	},
	{
	name = "vbr",
	label = "Video Bitrate",
	kind = "value",
	hint = "(kbit/s, overrides preset)",
	validator = gen_valid_num(100, 10000),
	initial = function() return tostring(gconfig_get("enc_vbr")); end,
	handler = function(ctx, val)
		gconfig_set("enc_vpreset", 0);
		gconfig_set("enc_vbr", tonumber(val));
	end
	},
	{
	name = "presilence",
	label = "Audio Presilence",
	kind = "value",
	hint = "(samples)",
	validator = gen_valid_num(0, 16384),
	initial = function() return tostring(gconfig_get("enc_presilence")); end,
	handler = function(ctx, val) gconfig_set("enc_presilence", tonumber(val)); end
	}
};

local config_terminal_font = {
	{
		name = "font_sz",
		label = "Size",
		kind = "value",
		validator = gen_valid_num(1, 100),
		initial = function() return tostring(gconfig_get("term_font_sz")); end,
		handler = function(ctx, val)
			gconfig_set("term_font_sz", tonumber(val));
		end
	},
	{
		name = "font_hint",
		label = "Hinting",
		kind = "value",
		set = {"none", "mono", "light", "normal", "subpixel"},
		initial = function() return TERM_HINT_RLUT[
		gconfig_get("term_font_hint")]; end,
		handler = function(ctx, val)
			gconfig_set("term_font_hint", hint_lut[val]);
		end
	},
-- should replace with some "font browser" but we don't have asynch font
-- loading etc. and no control over cache size
	{
		name = "font_name",
		label = "Name",
		kind = "value",
		set = function()
			local set = glob_resource("*", SYS_FONT_RESOURCE);
			set = set ~= nil and set or {};
			table.insert(set, "BUILTIN");
			return set;
		end,
		initial = function() return gconfig_get("term_font"); end,
		handler = function(ctx, val)
			gconfig_set("term_font", val == "BUILTIN" and "" or val);
		end
	}
};

local config_terminal = {
	{
		name = "alpha",
		label = "Background Alpha",
		kind = "value",
		hint = "(0..1)",
		validator = gen_valid_float(0, 1),
		initial = function() return tostring(gconfig_get("term_opa")); end,
		handler = function(ctx, val)
			gconfig_set("term_opa", tonumber(val));
		end
	},
	{
		name = "font",
		label = "Font",
		kind = "action",
		submenu = true,
		handler = config_terminal_font
	}
};

local allmenu = {
	{
		name = "all_susp",
		label = "Suspend All",
		kind = "action",
		handler = grab_global_function("all_suspend")
	},
	{
		name = "all_media_susp",
		label = "Suspend Media",
		kind = "action",
		handler = grab_global_function("all_media_suspend")
	},
	{
		name = "all_susp",
		label = "Resume All",
		kind = "action",
		handler = grab_global_function("all_resume")
	},
	{
		name = "all_media_resume",
		label = "Resume Media",
		kind = "action",
		handler = grab_global_function("all_media_resume")
	},
};

return {
	{
		name = "visual",
		label = "Visual",
		kind = "action",
		submenu = true,
		handler = durden_visual
	},
	{
		name = "wspaces",
		label = "Workspaces",
		kind = "action",
		submenu = true,
		handler = durden_workspace
	},
	{
		name = "timers",
		label = "Timers",
		kind = "action",
		submenu = true,
		handler = system_load("menus/global/timer.lua")()
	},
	{
		name = "system",
		label = "System",
		kind = "action",
		submenu = true,
		handler = durden_system
	},
	{
		name = "recording",
		label = "Recording",
		kind = "action",
		submenu = true,
		handler = recmenu
	},
	{
		name = "allwnd",
		label = "All-Windows",
		kind = "action",
		submenu = true,
		handler = allmenu,
	},
	{
		name = "terminal",
		label = "Terminal",
		kind = "action",
		submenu = true,
		eval = function()
			return string.match(FRAMESERVER_MODES, "terminal") ~= nil;
		end,
		handler = config_terminal
	}
};

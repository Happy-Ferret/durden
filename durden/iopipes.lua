-- unsetting these values will prevent all external communication that is not
-- using the nonauth- connection or regular input devices
local sbar_fn = gconfig_get("status_path");
if (sbar_fn ~= nil and string.len(sbar_fn) > 0 and sbar_fn ~= ":disabled") then
	zap_resource("ipc/" .. sbar_fn);
	STATUS_CHANNEL = open_nonblock("<ipc/" .. sbar_fn);
end

local cchan_fn = gconfig_get("control_path");
if (cchan_fn ~= nil and string.len(cchan_fn) > 0 and cchan_fn ~= ":disabled") then
	zap_resource("ipc/" .. cchan_fn);
	CONTROL_CHANNEL = open_nonblock("<ipc/" .. cchan_fn);
end

local ochan_fn = gconfig_get("output_path");
if (ochan_fn ~= nil and string.len(ochan_fn) > 0 and ochan_fn ~= ":disabled") then
	zap_resource("ipc/" .. ochan_fn);
	OUTPUT_CHANNEL = open_nonblock("<ipc/" .. ochan_fn, true);
end

-- grammar:
-- | element splits group
-- %{ ... } gives formatting command
-- %% escape %
--
-- handled formatting commands:
--  Frrggbb - set foreground color
--  Grrggbb - set group background
--  F- - set default color
--  G- - set group default background
--  Iidentifier - set group icon [if identifier match, overrides text]
--  S+, S-, Sf, Sl, Sn - switch tiler/display
--  | step group
--  Aidentifier - bind command or output to click
--
-- ignored formatting commands:
--  l [ align left, not supported   ]
--  r [ align right, not supported  ]
--  c [ align center, not supported ]
--  Brrggbb - set background color, not supported (engine limit)
--  Urrggbb - set underline color, not supported (engine limit)
--
-- most of these are limited as there are in-durden ways of achieving same res.
--
local function process_fmt(dfmt, tok, i)
	local col;

-- can support more here (e.g. embed glyph, bold/italic)
	while (tok[i] and tok[i].fmt) do
		if (string.len(tok[i].msg) > 0) then
			if tok[i].msg == "F-" then
				dfmt.col = gconfig_get("text_color");
			elseif string.match(tok[i].msg, "F#%x%x%x%x%x%x") then
				dfmt.col = "\\#"  .. string.sub(tok[i].msg, 3);
			elseif tok[i].msg == "G-" then
				dfmt.bg = nil;
			elseif string.match(tok[i].msg, "G#%x%x%x%x%x%x") then
				dfmt.bg = {
					tonumber(string.sub(tok[i].msg, 3, 4), 16),
					tonumber(string.sub(tok[i].msg, 5, 6), 16),
					tonumber(string.sub(tok[i].msg, 7, 8), 16)
				};
			elseif string.match(tok[i].msg, "S%d") then
				dfmt.disp = tostring(string.sub(tok[i].msg, 2));
			elseif tok[i].msg == "S+" then
				dfmt.disp = dfmt.disp + 1;
				dfmt.disp = dfmt.disp > display_count() and
					1 + (display_count() % dfmt.disp) or dfmt.disp;
			elseif tok[i].msg == "S-" then
				dfmt.disp = dfmt.disp - 1;
				dfmt.disp = dfmt.disp <= 0 and display_count() or dfmt.disp;
			elseif tok[i].msg == "Sf" then
				dfmt.disp = 1;
			elseif tok[i].msg == "Sl" then
				dfmt.disp = display_count();
			elseif string.byte(tok[i].msg, 1) == string.byte("A", 1) then
				dfmt.action = string.sub(tok[i].msg, 2);
			else
				if (DEBUGLEVEL > 0) then
					print("status parse, ignoring bad format " .. tok[i].msg);
				end
			end
		end

		i = i + 1;
	end

	return i;
end

local function status_parse(line)
	local tok = {};

	local cs = "";
	local i = 1;
	local in_p = false;
	local in_g = false;

-- first tokenize
	while i <= string.len(line) do
		local ni = string.utf8forward(line, i);
		if (not ni) then
			break;
		end
		local ch = string.sub(line, i, ni-1);

-- handle %% %{
		if (ch == '%') then
			if (in_g) then
				warning("status-channel parse, malformed input (pct in fmt-cmd)");
				return {};
			end

			if (in_p) then
				cs = cs .. '%';
				in_p = false;

			elseif (not in_g) then
				in_p = true;
			end

		elseif (in_p and ch ~= '{') then
			warning("status-channel parse, malformed input (pct to npct/bracket)");
			return {};

-- handle transition msg%{ to fmt group state
		elseif (in_p) then
			in_g = true;
			in_p = false;
			if (string.len(cs) > 0) then
				table.insert(tok, {fmt = false, msg = cs});
				cs = "";
			end

-- handle transition fmt-group -> default
		elseif (in_g and ch == '}') then
			in_g = false;
			if (string.len(cs) == 0) then
				warning("status-channel parse, malformed input (empty fmt group)");
				return {};
			end
			table.insert(tok, {fmt = true, msg = cs});
			cs = "";

		elseif (ch == '|') then
			if (not in_g and not in_p) then
				table.insert(tok, {fmt = false, msg = cs});
			end
			cs = "";
			table.insert(tok, {newgrp = true, msg = ""});
		else
			cs = cs .. ch;
		end

		i = ni;
	end

-- handle EoS state
	if (not in_g and not in_p) then
		table.insert(tok, {fmt = false, msg = cs});
	end

-- now process the token stream and build a table of groups with entries
-- that carries active format state and coupled message
	local i = 1;
	local groups = {};
	local cfmt = {disp = 1};
	local cg = {};

	while i <= #tok do
		if (tok[i].newgrp) then
			table.insert(groups, cg);
			cg = {};
			cfmt.action = nil;
			i = i + 1;
		elseif (tok[i].fmt) then
			i = process_fmt(cfmt, tok, i);
		else
			local newfmt = {};
			for k,v in pairs(cfmt) do
				newfmt[k] = v;
			end
			table.insert(cg, {newfmt, tok[i].msg});
			i = i + 1;
		end
	end
	if (#cg > 0) then
		table.insert(groups, cg);
	end

-- normalize group to display
	local res = {};
	for i,v in ipairs(groups) do
		if (#v > 0) then
			local pd = v[#v][1].disp;
			if (not res[pd]) then res[pd] = {}; end
			table.insert(res[pd], v);
		end
	end

	return res;
end

local function gen_cmdtbl(cmd)
	if (not cmd) then
		return nil;
	end

	return {
		click = function(btn)
			if (string.sub(cmd, 1, 1) == "!" or
				string.sub(cmd, 1, 1) == "#") then
				if (allowed_commands(cmd)) then
					dispatch_symbol(cmd);
				end
			else
				if (OUTPUT_CHANNEL) then
					OUTPUT_CHANNEL:write(string.format("%s\n", cmd));
				end
			end
		end,
		rclick = click,
		over = function(btn)
			btn:switch_state("active");
		end,
		out = function(btn)
			btn:switch_state("inactive");
		end
	};
end

local function poll_status_channel()
	local line = STATUS_CHANNEL:read();
	if (line == nil or string.len(line) == 0) then
		return;
	end

-- generate render_text compatible tables based on input line and add to
-- the suitable statusbar for each display.
	local lst = status_parse(line);

	local ind = 1;
	for disp in all_tilers_iter() do
		if (lst[ind]) then
			for i=#lst[ind],1,-1 do
				local di = #lst[ind]-i+1;
				local grp = lst[ind][i];
				local fmttbl = {};
				local bg = nil;
				local cmd = nil;
				for k,v in ipairs(grp) do
					table.insert(fmttbl, v[1].col and v[1].col or "");
					table.insert(fmttbl, v[2]);
					if (v[1].bg) then
						bg = v[1].bg;
					end
					if (v[1].action) then
						cmd = v[1].action;
					end
				end
				local btn = disp.statusbar.buttons.right[di];
				local mh = gen_cmdtbl(cmd);
				if (btn == nil) then
-- we can't currently handle a text background color as font renderer does not
-- provide a background color state, so we need to wait for changes to arcan
-- for that
					local btn = disp.statusbar:add_button("right", "sbar_msg_bg",
						"sbar_msg_text", fmttbl, gconfig_get("sbar_tpad") * disp.scalef,
						disp.font_resfn, nil, nil, mh);
					btn:switch_state("inactive");
				else
					local cw = btn.last_label_w;
					disp.statusbar:update("right", di, fmttbl);
					if ((not btn.minw or btn.minw == 0 and cw) or (cw and cw > btn.minw)) then
						btn:constrain(nil, cw, nil, nil, nil);
					end
					btn:update_mh(mh);
				end
			end
			ind = ind + 1;
		end
	end
end

local function poll_control_channel()
	local line = CONTROL_CHANNEL:read();
	if (line == nil or string.len(line) == 0) then
		return;
	end

	if (not allowed_commands(line)) then
		warning("unknown/disallowed command: " .. line);
		return;
	end

	dispatch_symbol(line);
end

-- open question is if we should check lock-state here and if we're in locked
-- input, also disable polling status / control
timer_add_periodic("status_control", 8, false,
function()
	if (STATUS_CHANNEL) then
		poll_status_channel();
	end

	if (CONTROL_CHANNEL) then
		poll_control_channel();
	end
end, true
);

-- chain here rather than add some other hook mechanism, then the entire feature
-- can be removed by dropping the system_load() call.
local dshut = durden_shutdown;
durden_shutdown = function()
	dshut();

	if (gconfig_get("status_path") ~= ":disabled") then
		zap_resource("ipc/" .. gconfig_get("status_path"));
	end
	if (gconfig_get("control_path") ~= ":disabled") then
		zap_resource("ipc/" .. gconfig_get("control_path"));
	end
	if (gconfig_get("output_path") ~= ":disabled") then
		zap_resource("ipc/" .. gconfig_get("output_path"));
	end
end

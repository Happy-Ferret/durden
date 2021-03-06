-- Copyright: 2015, Björn Ståhl
-- License: 3-Clause BSD
-- Reference: http://durden.arcan-fe.com
-- Depends: display, shdrmgmt, lbar, suppl, mouse
-- Description: Tiler comprise the main tiling window management, event
-- routing, key interpretation and other hooks. It returns a single
-- creation function (tiler_create(W, H)) that returns the usual table
-- of functions and members in pseudo-OO style.

-- number of Z values reserved for each window
local WND_RESERVED = 10;

local ent_count = 1;

local create_workspace = function() end

local function linearize(wnd)
	local res = {};
	local dive = function(wnd, df)
		if (wnd == nil or wnd.children == nil) then
			return;
		end

		for i,v in ipairs(wnd.children) do
			table.insert(res, v);
			df(v, df);
		end
	end
	dive(wnd, dive);
	return res;
end

local function tbar_mode(mode)
	return mode == "tile";
end

local function tbar_geth(wnd)
	assert(wnd ~= nil);
	return (wnd.hide_titlebar and tbar_mode(wnd.space.mode)) and 1 or
		(wnd.wm.scalef * gconfig_get("tbar_sz"));
end

local function sbar_geth(wm, ign)
	if (ign) then
		return math.ceil(gconfig_get("sbar_sz") * wm.scalef);
	else
		return (wm.spaces[wm.space_ind] and
			wm.spaces[wm.space_ind].mode == "fullscreen") and 0 or
			math.ceil(gconfig_get("sbar_sz") * wm.scalef);
	end
end

local function run_event(wnd, event, ...)
	assert(wnd.handlers[event]);
	for i,v in ipairs(wnd.handlers[event]) do
		v(wnd, unpack({...}));
	end
end

local function wnd_destroy(wnd)
	local wm = wnd.wm;
	if (wnd.delete_protect) then
		return;
	end

	if (wm.debug_console) then
		wm.debug_console:system_event("lost " .. wnd.name);
	end

	if (wm.deactivated and wm.deactivated.wnd == wnd) then
		wm.deactivated.wnd = nil;
	end

	if (wm.selected == wnd) then
		wnd:deselect();
		local mx, my = mouse_xy();
	end

	if (wnd.fullscreen) then
		wnd.space:tile();
	end

	if (wm.deactivated and wm.deactivated.wnd == wnd) then
		wm.deactivated.wnd = nil;
	end

	mouse_droplistener(wnd.handlers.mouse.border);
	mouse_droplistener(wnd.handlers.mouse.canvas);

-- mark a new node as selected
	if (#wnd.children > 0) then
		wnd.children[1]:select();
	elseif (wnd.parent and wnd.parent.parent) then
		wnd.parent:select();
	else
		wnd:prev();
	end

-- but that doesn't always succeed (edge-case, last window)
	if (wnd.wm.selected == wnd) then
		wnd.wm.selected = nil;
		if (wnd.space.selected == wnd) then
		wnd.space.selected = nil;
		end
	end

-- re-assign all children to parent
	for i,v in ipairs(wnd.children) do
		table.insert(wnd.parent.children, v);
		v.parent = wnd.parent;
	end

-- now we can run destroy hooks
	run_event(wnd, "destroy");
	for i,v in ipairs(wnd.relatives) do
		run_event(v, "lost_relative", wnd);
	end

-- drop references, cascade delete from anchor
	delete_image(wnd.anchor);
	table.remove_match(wnd.parent.children, wnd);

	for i=1,10 do
		if (wm.spaces[i] and wm.spaces[i].selected == wnd) then
			wm.spaces[i].selected = nil;
		end

		if (wm.spaces[i] and wm.spaces[i].previous == wnd) then
			wm.spaces[i].previous = nil;
		end
	end

	wnd.titlebar:destroy();

	if (valid_vid(wnd.external)) then
		delete_image(wnd.external);
	end

	local space = wnd.space;
	for k,v in pairs(wnd) do
		wnd[k] = nil;
	end

-- drop global tracking
	table.remove_match(wm.windows, wnd);

-- rebuild layout
	space:resize();
end

local function wnd_message(wnd, message, timeout)
--	print("wnd_message", message);
end

local function wnd_deselect(wnd, nopick)
	local mwm = wnd.space.mode;
	if (mwm == "tab" or mwm == "vtab") then
		hide_image(wnd.anchor);
	end

	if (wnd.wm.selected == wnd) then
		wnd.wm.selected = nil;
	end

	if (wnd.mouse_lock) then
		mouse_lockto(BADID);
	end

	wnd:set_dispmask(bit.bor(wnd.dispmask, TD_HINT_UNFOCUSED));

	local x, y = mouse_xy();
	if (image_hit(wnd.canvas, x, y) and wnd.cursor == "hidden") then
		mouse_hidemask(true);
		mouse_show();
		mouse_hidemask(false);
	end

	local state = wnd.suspended and "suspended" or "inactive";
	shader_setup(wnd.border, "ui", "border", state);
	wnd.titlebar:switch_state(state, true);

-- save scaled coordinates so we can handle a resize
	if (gconfig_get("mouse_remember_position")) then
		local props = image_surface_resolve_properties(wnd.canvas);
		if (x >= props.x and y >= props.y and
			x <= props.x + props.width and y <= props.y + props.height) then
			wnd.mouse = {
				(x - props.x) / props.width,
				(y - props.y) / props.height
			};
		end
	end

	run_event(wnd, "deselect");
end

local function output_mouse_devent(btl, wnd)
	btl.kind = "digital";
	btl.source = "mouse";

-- rate limit is used to align input event storms (likely to cause visual
-- changes that need synchronization) with the logic ticks (where the engine
-- is typically not processing rendering), and to provent the horrible
-- spikes etc. that can come with high-samplerate.
	if (not wnd.rate_unlimited) then
		local wndq = EVENT_SYNCH[wnd.external];
		if (wndq and (wndq.pending and #wndq.pending > 0)) then
			table.insert(wndq.queue, wndq.pending[1]);
			table.insert(wndq.queue, wndq.pending[2]);
			table.insert(wndq.queue, btl);
			wndq.pending = nil;
			return;
		end
	end

	target_input(wnd.external, btl);
end

local function wm_update_mode(wm)
	if (not wm.spaces[wm.space_ind]) then
		return;
	end

	local modestr = wm.spaces[wm.space_ind].mode;
	if (modestr == "tile") then
		modestr = modestr .. ":" .. wm.spaces[wm.space_ind].insert;
	end
--	wm.sbar_ws["left"]:fullscreen();
	wm.sbar_ws["left"]:update(modestr);
end

local function tiler_statusbar_update(wm)
	local statush = sbar_geth(wm);
	if (statush > 0) then
		wm.statusbar:resize(wm.width, statush);
	end
	wm.statusbar:move(0, wm.height - statush);

	if (not wm.space_ind or not wm.spaces[wm.space_ind]) then
		return;
	end
	wm_update_mode(wm);
	local space = wm.spaces[wm.space_ind];
	wm.statusbar[space == "fullscreen" and "hide" or "show"](wm.statusbar);

	for i=1,10 do
		if (wm.spaces[i] ~= nil) then
			wm.sbar_ws[i]:show();
			local lbltbl = {gconfig_get("pretiletext_color"), tostring(i)};
			local lbl = wm.spaces[i].label;
			if (lbl and string.len(lbl) > 0) then
				lbltbl[3] = "";
				lbltbl[4] = ":";
				lbltbl[5] = gconfig_get("label_color");
				lbltbl[6] = lbl;
			end
			wm.sbar_ws[i]:update(lbltbl);
		else
			wm.sbar_ws[i]:hide();
		end
		wm.sbar_ws[i]:switch_state(i == wm.space_ind and "active" or "inactive");
	end
end

local function tiler_statusbar_build(wm)
	local sbsz = sbar_geth(wm, true);
	wm.statusbar = uiprim_bar(
		wm.order_anchor, ANCHOR_UL, wm.width, sbsz, "statusbar");
	local pad = gconfig_get("sbar_tpad") * wm.scalef;
	wm.sbar_ws = {};

-- add_button(left, pretile, label etc.)
	wm.sbar_ws["left"] = wm.statusbar:add_button("left", "sbar_item_bg",
		"sbar_item", "mode", pad, wm.font_resfn, nil, sbsz,
		{
			click = function()
				if (not wm.spaces[wm.space_ind].in_float) then
					wm.spaces[wm.space_ind]:float();
				else
-- NOTE: this breaks the decoupling between tiler and rest of durden, and maybe
-- this mouse-handler management hook should be configurable elsewhere
					local fun = grab_global_function("global_actions");
					if (fun) then
						fun();
					end
				end
			end,
			rclick = function()
				if (wm.spaces[wm.space_ind].in_float) then
					local fun = grab_shared_function("target_actions");
					if (fun) then
						fun();
					end
				end
			end
		});

-- pre-allocate buffer slots, but keep hidden
	for i=1,10 do
		wm.sbar_ws[i] = wm.statusbar:add_button("left", "sbar_item_bg",
			"sbar_item", tostring(i), pad, wm.font_resfn, sbsz, nil,
			{
				click = function(btn)
					wm:switch_ws(i);
				end,
				rclick = click
			}
		);
		wm.sbar_ws[i]:hide();
	end
-- fill slot with system messages, will later fill the role of a notification
-- stack, with possible timeout and popup- list
	wm.sbar_ws["msg"] = wm.statusbar:add_button("center",
		"sbar_msg_bg", "sbar_msg_text", " ", pad, wm.font_resfn, nil, sbsz,
		{
			click = function(btn)
				btn:update("");
			end
		});
	wm.sbar_ws["msg"].align_left = true;
end

-- we need an overlay anchor that is only used for ordering, this to handle
-- that windows may appear while the overlay is active
local function wm_order(wm)
	return wm.order_anchor;
end
-- recursively resolve the relation hierarchy and return a list
-- of vids that are linked to a specific vid
local function get_hier(vid)
	local ht = {};

	local level = function(hf, vid)
		for i,v in ipairs(image_children(vid)) do
			table.insert(ht, v);
			hf(hf, v);
		end
	end

	level(level, vid);
	return ht;
end

local function wnd_select(wnd, source)
	if (not wnd.wm) then
		warning("select on broken window");
		print(debug.traceback());
		return;
	end

	if (wnd.wm.deactivated) then
		return;
	end

-- may be used to reactivate locking after a lbar or similar action
-- has been performed.
	if (wnd.wm.selected == wnd) then
		if (wnd.mouse_lock) then
			mouse_lockto(wnd.canvas, type(wnd.mouse_lock) == "function" and
				wnd.mouse_lock or nil, wnd.mouse_lock_center);
		end
		return;
	end

	wnd:set_dispmask(bit.band(wnd.dispmask,
		bit.bnot(wnd.dispmask, TD_HINT_UNFOCUSED)));

	if (wnd.wm.selected) then
		wnd.wm.selected:deselect();
	end

	local mwm = wnd.space.mode;
	if (mwm == "tab" or mwm == "vtab") then
		show_image(wnd.anchor);
	end

	local state = wnd.suspended and "suspended" or "active";
	shader_setup(wnd.border, "ui", "border", state);
	wnd.titlebar:switch_state(state, true);

	run_event(wnd, "select");
	wnd.space.previous = wnd.space.selected;

	if (wnd.wm.active_space == wnd.space) then
		wnd.wm.selected = wnd;
	end
	wnd.space.selected = wnd;

	ms = mouse_state();
	ms.hover_ign = true;
	local mouse_moved = false;
	local props = image_surface_resolve_properties(wnd.canvas);
	if (gconfig_get("mouse_remember_position") and not ms.in_handler) then
		local px = 0.0;
		local py = 0.0;

		if (wnd.mouse) then
			px = wnd.mouse[1];
			py = wnd.mouse[2];
		end
		mouse_absinput_masked(
			props.x + px * props.width, props.y + py * props.height, true);
		mouse_moved = true;
	end
	ms.last_hover = CLOCK;
	ms.hover_ign = false;

	if (wnd.mouse_lock) then
		mouse_lockto(wnd.canvas, type(wnd.mouse_lock) == "function" and
				wnd.mouse_lock or nil);
	end

	wnd:to_front();
end

--
-- This is _the_ operation when it comes to window management here, it resizes
-- the actual size of a tile (which may not necessarily match the size of the
-- underlying surface). Keep everything divisible by two for simplicity.
--
-- The overall structure in split mode is simply a tree, split resources fairly
-- between individuals (with an assignable weight) and recurse down to children
--
local function level_resize(level, x, y, w, h, node)
	local fair = math.ceil(w / #level.children);
	fair = (fair % 2) == 0 and fair or fair + 1;

	if (#level.children == 0) then
		return;
	end

	local process_node = function(node, last)
		node.x = x; node.y = y;
		node.h = h;

		if (last) then
			node.w = w;
		else
			node.w = math.ceil(fair * node.weight);
			node.w = (node.w % 2) == 0 and node.w or node.w + 1;
		end

		if (#node.children > 0) then
			node.h = math.ceil(h / 2 * node.vweight);
			node.h = (node.h % 2) == 0 and node.h or node.h + 1;
			level_resize(node, x, y + node.h, node.w, h - node.h);
		end

		move_image(node.anchor, node.x, node.y);
		node:resize(node.w, node.h);

		x = x + node.w;
		w = w - node.w;
	end

	for i=1,#level.children-1 do
		process_node(level.children[i]);
	end

	process_node(level.children[#level.children], true);
end

local function workspace_activate(space, noanim, negdir, oldbg)
	local time = gconfig_get("transition");
	local method = gconfig_get("ws_transition_in");

-- wake any sleeping windows up and make sure it knows if it is selected or not
	for k,v in ipairs(space.wm.windows) do
		if (v.space == space) then
			v:set_dispmask(bit.band(v.dispmask, bit.bnot(TD_HINT_INVISIBLE)), true);
			if (space.selected ~= v) then
				v:set_dispmask(bit.bor(v.dispmask, TD_HINT_UNFOCUSED));
			else
				v:set_dispmask(bit.band(v.dispmask, bit.bnot(TD_HINT_UNFOCUSED)));
			end
		end
	end

	instant_image_transform(space.anchor);
	if (valid_vid(space.background)) then
		instant_image_transform(space.background);
	end

	if (not noanim and time > 0 and method ~= "none") then
		local htime = time * 0.5;
		if (method == "move-h") then
			move_image(space.anchor, (negdir and -1 or 1) * space.wm.width, 0);
			move_image(space.anchor, 0, 0, time);
			show_image(space.anchor);
		elseif (method == "move-v") then
			move_image(space.anchor, 0, (negdir and -1 or 1) * space.wm.height);
			move_image(space.anchor, 0, 0, time);
			show_image(space.anchor);
		elseif (method == "fade") then
			move_image(space.anchor, 0, 0);
-- stay at level zero for a little while so not to fight with crossfade
			blend_image(space.anchor, 0.0);
			blend_image(space.anchor, 0.0, htime);
			blend_image(space.anchor, 1.0, htime);
		else
			warning("broken method set for ws_transition_in: " ..method);
		end
-- slightly more complicated, we don't want transitions if the background is the
-- same between different workspaces as it is visually more distracting
		local bg = space.background;
		if (bg) then
			if (not valid_vid(oldbg) or not image_matchstorage(oldbg, bg)) then
				blend_image(bg, 0.0, htime);
				blend_image(bg, 1.0, htime);
				image_mask_set(bg, MASK_POSITION);
				image_mask_set(bg, MASK_OPACITY);
			else
				show_image(bg);
				image_mask_clear(bg, MASK_POSITION);
				image_mask_clear(bg, MASK_OPACITY);
			end
		end
	else
		show_image(space.anchor);
		if (space.background) then show_image(space.background); end
	end

	space.wm.active_space = space;
	local tgt = space.selected and space.selected or space.children[1];
end

local function workspace_deactivate(space, noanim, negdir, newbg)
	local time = gconfig_get("transition");
	local method = gconfig_get("ws_transition_out");

-- hack so that deselect event is sent but not all other state changes trigger
	if (space.selected and not noanim) then
		local sel = space.selected;
		wnd_deselect(space.selected);
		space.selected = sel;
	end

-- notify windows that they can take things slow
	for k,v in ipairs(space.wm.windows) do
		if (v.space == space) then
			if (valid_vid(v.external, TYPE_FRAMESERVER)) then
				v:set_dispmask(bit.bor(v.dispmask, TD_HINT_INVISIBLE));
				target_displayhint(v.external, 0, 0, v.dispmask);
			end
		end
	end

	instant_image_transform(space.anchor);
	if (valid_vid(space.background)) then
		instant_image_transform(space.background);
	end

	if (not noanim and time > 0 and method ~= "none") then

		if (method == "move-h") then
			move_image(space.anchor, (negdir and -1 or 1) * space.wm.width, 0, time);
		elseif (method == "move-v") then
			move_image(space.anchor, 0, (negdir and -1 or 1) * space.wm.height, time);
		elseif (method == "fade") then
			blend_image(space.anchor, 0.0, 0.5 * time);
		else
			warning("broken method set for ws_transition_out: "..method);
		end
		local bg = space.background;
		if (bg) then
			if (not valid_vid(newbg) or not image_matchstorage(newbg, bg)) then
				blend_image(bg, 0.0, 0.5 * time);
				image_mask_set(bg, MASK_POSITION);
				image_mask_set(bg, MASK_OPACITY);
			else
				hide_image(bg);
				image_mask_clear(bg, MASK_POSITION);
				image_mask_clear(bg, MASK_OPACITY);
			end
		end
	else
		hide_image(space.anchor);
		if (valid_vid(space.background)) then
			hide_image(space.background);
		end
	end
end

-- migrate window means:
-- copy valuable properties, destroy then "add", including tiler.windows
--
local function workspace_migrate(ws, newt, disptbl)
	local oldt = ws.wm;
	if (oldt == display) then
		return;
	end

-- find a free slot and locate the source slot
	local dsti;
	for i=1,10 do
		if (newt.spaces[i] == nil or (
			#newt.spaces[i].children == 0 and newt.spaces[i].label == nil)) then
			dsti = i;
			break;
		end
	end

	local srci;
	for i=1,10 do
		if (oldt.spaces[i] == ws) then
			srci = i;
			break;
		end
	end

	if (not dsti or not srci) then
		return;
	end

-- add/remove from corresponding tilers, update status bars
	workspace_deactivate(ws, true);
	ws.wm = newt;
	rendertarget_attach(newt.rtgt_id, ws.anchor, RENDERTARGET_DETACH);
	link_image(ws.anchor, newt.anchor);

	local wnd = linearize(ws);
	for i,v in ipairs(wnd) do
		v.wm = newt;
		table.insert(newt.windows, v);
		table.remove_match(oldt.windows, v);
-- send new display properties
		if (disptbl and valid_vid(v.external, TYPE_FRAMESERVER)) then
			target_displayhint(v.external, 0, 0, v.dispmask, disptbl);
		end

-- special handling for titlebar
		for j in v.titlebar:all_buttons() do
			j.fontfn = newt.font_resfn;
		end
		v.titlebar:invalidate();
		v:set_title(tt);
	end
	oldt.spaces[srci] = create_workspace(oldt, false);

-- switch rendertargets
	local list = get_hier(ws.anchor);
	for i,v in ipairs(list) do
		rendertarget_attach(newt.rtgt_id, v, RENDERTARGET_DETACH);
	end

	if (dsti == newt.space_ind) then
		workspace_activate(ws, true);
		newt.selected = oldt.selected;
	end

	oldt.selected = nil;

	order_image(oldt.order_anchor,
		2 + #oldt.windows * WND_RESERVED + 2 * WND_RESERVED);
	order_image(newt.order_anchor,
		2 + #newt.windows * WND_RESERVED + 2 * WND_RESERVED);

	newt.spaces[dsti] = ws;

	local olddisp = active_display();
	set_context_attachment(newt.rtgt_id);

-- enforce layout and dimension changes as needed
	ws:resize();
	if (valid_vid(ws.label_id)) then
		delete_image(ws.label_id);
		mouse_droplistener(ws.tile_ml);
		ws.label_id = nil;
	end

	set_context_attachment(olddisp.rtgt_id);
end

-- undo / redo the effect that deselect will hide the active window
local function switch_tab(space, to, ndir, newbg, oldbg)
	local wnds = linearize(space);
	if (to) then
		for k,v in ipairs(wnds) do
			hide_image(v.anchor);
		end
		workspace_activate(space, false, ndir, oldbg);
	else
		workspace_deactivate(space, false, ndir, newbg);
		if (space.selected) then
			show_image(space.selected.anchor);
		end
	end
end

local function switch_fullscreen(space, to, ndir, newbg, oldbg)
	if (space.selected == nil) then
		return;
	end

	if (to) then
		space.wm.statusbar:hide();
		space.wm.hidden_sb = true;
		workspace_activate(space, false, ndir, oldbg);
		local lst = linearize(space);
		for k,v in ipairs(space) do
			hide_image(space.anchor);
		end
			show_image(space.selected.anchor);
	else
		space.wm.statusbar:show();
		space.wm.hidden_sb = false;
		workspace_deactivate(space, false, ndir, newbg);
	end
end

local function drop_fullscreen(space, swap)
	workspace_activate(space, true);
	space.wm.statusbar:show();
	space.wm.hidden_sb = false;

	if (not space.selected) then
		return;
	end

	local wnds = linearize(space);
	for k,v in ipairs(wnds) do
		show_image(v.anchor);
	end

	local dw = space.selected;
	dw.titlebar:show();
	show_image(dw.border);
	for k,v in pairs(dw.fs_copy) do dw[k] = v; end
	dw.fs_copy = nil;
	dw.fullscreen = nil;
	image_mask_set(dw.canvas, MASK_OPACITY);
	space.switch_hook = nil;
end

local function drop_tab(space)
	local res = linearize(space);
-- new mode will resize so don't worry about that, just relink
	for k,v in ipairs(res) do
		v.titlebar:reanchor(v.anchor, 2, v.border_w, v.border_w);
		show_image(v.border);
		show_image(v.anchor);
	end

	space.mode_hook = nil;
	space.switch_hook = nil;
	space.reassign_hook = nil;
end

local function drop_float(space)
	space.in_float = false;

	local lst = linearize(space);
	for i,v in ipairs(lst) do
		local pos = image_surface_properties(v.anchor);
		v.last_float = {
			width = v.width / space.wm.width,
			height = v.height / space.wm.height,
			x = pos.x / space.wm.width,
			y = pos.y / space.wm.height
		};
	end
end

local function reassign_float(space, wnd)
end

local function reassign_tab(space, wnd)
	wnd.titlebar:reanchor(wnd.anchor, 2, wnd.border_w, wnd.border_w);
	show_image(wnd.anchor);
	show_image(wnd.border);
end

-- just unlink statusbar, resize all at the same time (also hides some
-- of the latency in clients producing new output buffers with the correct
-- dimensions etc). then line the statusbars at the top.
local function set_tab(space)
	local lst = linearize(space);
	if (#lst == 0) then
		return;
	end

	space.mode_hook = drop_tab;
	space.switch_hook = switch_tab;
	space.reassign_hook = reassign_tab;

	local wm = space.wm;
	local fairw = math.ceil(wm.width / #lst);
	local tbar_sz = math.ceil(gconfig_get("tbar_sz") * wm.scalef);
	local sb_sz = sbar_geth(wm);
	local bw = gconfig_get("borderw");
	local ofs = 0;

	for k,v in ipairs(lst) do
		v:resize_effective(wm.width, wm.height - sb_sz - tbar_sz);
		move_image(v.anchor, 0, 0);
		move_image(v.canvas, 0, tbar_sz);
		hide_image(v.anchor);
		hide_image(v.border);
		v.titlebar:reanchor(space.anchor, 2, ofs, 0);
		v.titlebar:resize(fairw, tbar_sz);
		ofs = ofs + fairw;
	end

	if (space.selected) then
		local wnd = space.selected;
		wnd:deselect();
		wnd:select();
	end
end

-- tab and vtab are similar in most aspects except for the axis used
-- and the re-ordering of the selected statusbar
local function set_vtab(space)
	local lst = linearize(space);
	if (#lst == 0) then
		return;
	end

	space.mode_hook = drop_tab;
	space.switch_hook = switch_tab;
	space.reassign_hook = reassign_tab;

	local wm = space.wm;
	local tbar_sz = math.ceil(gconfig_get("tbar_sz") * wm.scalef);
	local sb_sz = sbar_geth(wm);

	local ypos = #lst * tbar_sz;
	local cl_area = wm.height - sb_sz - ypos;
	if (cl_area < 1) then
		return;
	end

	local ofs = 0;
	for k,v in ipairs(lst) do
		v:resize_effective(wm.width, cl_area);
		move_image(v.anchor, 0, ypos);
		move_image(v.canvas, 0, 0);
		hide_image(v.anchor);
		hide_image(v.border);
		v.titlebar:reanchor(space.anchor, 2, 0, (k-1) * tbar_sz);
		v.titlebar:resize(wm.width, tbar_sz);
		ofs = ofs + tbar_sz;
	end

	if (space.selected) then
		local wnd = space.selected;
		wnd:deselect();
		wnd:select();
	end
end

local function set_fullscreen(space)
	if (not space.selected) then
		return;
	end
	local dw = space.selected;

-- keep a copy of properties we may want to change during fullscreen
	dw.fs_copy = {
		centered = dw.centered,
		fullscreen = false
	};
	dw.centered = true;
	dw.fullscreen = true;

-- hide all images + statusbar
	dw.wm.statusbar:hide();
	dw.wm.hidden_sb = true;
	local wnds = linearize(space);
	for k,v in ipairs(wnds) do
		hide_image(v.anchor);
	end
	show_image(dw.anchor);
	dw.titlebar:hide();
	hide_image(space.selected.border);

	dw.fullscreen = true;
	space.mode_hook = drop_fullscreen;
	space.switch_hook = switch_fullscreen;

	move_image(dw.canvas, 0, 0);
	move_image(dw.anchor, 0, 0);
	dw:resize(dw.wm.width, dw.wm.height);
end

local function set_float(space)
	if (not space.in_float) then
		space.in_float = true;
		space.reassign_hook = reassign_float;
		space.mode_hook = drop_float;
		local tbl = linearize(space);
		for i,v in ipairs(tbl) do
			local props = image_storage_properties(v.canvas);
			local neww;
			local newh;
-- work with relative position / size to handle migrate or resize
			if (v.last_float) then
				neww = space.wm.width * v.last_float.width;
				newh = space.wm.height * v.last_float.height;
				move_image(v.anchor,
					space.wm.width * v.last_float.x,
					space.wm.height * v.last_float.y
				);
-- if window havn't been here before, clamp
			else
				neww = props.width + v.pad_left + v.pad_right;
				newh = props.height + v.pad_top + v.pad_bottom;
				neww = (space.wm.width < neww and space.wm.width) or neww;
				newh = (space.wm.height < newh and space.wm.height) or newh;
			end

			v:resize(neww, newh, true);
		end
	end
end

local function set_tile(space)
	local wm = space.wm;
	wm.statusbar:show();
	wm.statusbar.hidden_sb = false;
	level_resize(space, 0, 0, wm.width, wm.height - sbar_geth(wm));
end

local space_handlers = {
	tile = set_tile,
	float = set_float,
	fullscreen = set_fullscreen,
	tab = set_tab,
	vtab = set_vtab
};

local function workspace_destroy(space)
	if (space.mode_hook) then
		space:mode_hook();
		space.mode_hook = nil;
	end

	while (#space.children > 0) do
		space.children[1]:destroy();
	end

	if (valid_vid(space.rtgt_id)) then
		delete_image(space.rtgt_id);
	end

	if (space.label_id ~= nil) then
		delete_image(space.label_id);
	end

	if (space.background) then
		delete_image(space.background);
	end

	delete_image(space.anchor);
	for k,v in pairs(space) do
		space[k] = nil;
	end
end

local function workspace_set(space, mode)
	if (space_handlers[mode] == nil or mode == space.mode) then
		return;
	end

-- cleanup to revert to the normal stable state (tiled)
	if (space.mode_hook) then
		space:mode_hook();
		space.mode_hook = nil;
	end

-- for float, first reset to tile then switch to get a fair distribution
-- another option would be to first set their storage dimensions and then
-- force
	if (mode == "float" and space.mode ~= "tile") then
		space.mode = "tile";
		space:resize();
	end

	space.last_mode = space.mode;
	space.mode = mode;

-- enforce titlebar changes (some modes need them to work..)
	local lst = linearize(space);
	for k,v in ipairs(lst) do
		v:set_title();
	end

	space:resize();
	tiler_statusbar_update(space.wm);
end

local function workspace_resize(space)
	if (space_handlers[space.mode]) then
		space_handlers[space.mode](space, true);
	end

	if (valid_vid(space.background)) then
		resize_image(space.background, space.wm.width, space.wm.height);
	end
end

local function workspace_label(space, lbl)
	local ind = 1;
	repeat
		if (space.wm.spaces[ind] == space) then
			break;
		end
		ind = ind + 1;
	until (ind > 10);

	space.label = lbl;
	tiler_statusbar_update(space.wm);
end

local function workspace_empty(wm, i)
	return (wm.spaces[i] == nil or
		(#wm.spaces[i].children == 0 and wm.spaces[i].label == nil));
end

local function workspace_save(ws, shallow)

	local ind;
	for k,v in pairs(ws.wm.spaces) do
		if (v == ws) then
			ind = k;
		end
	end

	assert(ind ~= nil);

	local keys = {};
	local prefix = string.format("wsk_%s_%d", ws.wm.name, ind);
	keys[prefix .. "_mode"] = ws.mode;
	keys[prefix .. "_insert"] = ws.insert;
	if (ws.label) then
		keys[prefix .."_label"] = ws.label;
	end

	if (ws.background_name) then
		keys[prefix .. "_bg"] = ws.background_name;
	end

	drop_keys(prefix .. "%");
	store_key(keys);

	if (shallow) then
		return;
	end
-- depth serialization and metastructure missing
end

local function workspace_background(ws, bgsrc, generalize)
	if (bgsrc == ws.wm.background_name and valid_vid(ws.wm.background_id)) then
		bgsrc = ws.wm.background_id;
	end

	local ttime = gconfig_get("transition");
	local crossfade = false;
	if (valid_vid(ws.background)) then
		ttime = ttime * 0.5;
		crossfade = true;
		expire_image(ws.background, ttime);
		blend_image(ws.background, 0.0, ttime);
		ws.background = nil;
		ws.background_name = nil;
	end

	local new_vid = function(src)
		if (not valid_vid(ws.background)) then
			ws.background = null_surface(ws.wm.width, ws.wm.height);
			shader_setup(ws.background, "simple", "noalpha");
		end
		resize_image(ws.background, ws.wm.width, ws.wm.height);
		link_image(ws.background, ws.anchor);
		if (crossfade) then
			blend_image(ws.background, 0.0, ttime);
		end
		blend_image(ws.background, 1.0, ttime);
		if (valid_vid(src)) then
			image_sharestorage(src, ws.background);
		end
	end

	if (bgsrc == nil) then
	elseif (type(bgsrc) == "string") then
-- before loading, check if some space doesn't already have the bg
		local vid = load_image_asynch(bgsrc, function(src, stat)
			if (stat.kind == "loaded") then
			ws.background_name = bgsrc;
			new_vid(src);
			delete_image(src);
			if (generalize) then
				ws.wm.background_name = bgsrc;
				store_key(string.format("ws_%s_bg", ws.wm.name), bgsrc);
			end
		else
			delete_image(src);
		end
	end);
--		new_vid(vid);
	elseif (type(bgsrc) == "number" and valid_vid(bgsrc)) then
		new_vid(bgsrc);
		ws.background_name = nil;
	else
		warning("workspace_background - called with invalid. arg");
	end
end

create_workspace = function(wm, anim)
	local res = {
		activate = workspace_activate,
		deactivate = workspace_deactivate,
		resize = workspace_resize,
		destroy = workspace_destroy,
		migrate = workspace_migrate,
		save = workspace_save,

-- different layout modes, patch here and workspace_set to add more
		fullscreen = function(ws) workspace_set(ws, "fullscreen"); end,
		tile = function(ws) workspace_set(ws, "tile"); end,
		tab = function(ws) workspace_set(ws, "tab"); end,
		vtab = function(ws) workspace_set(ws, "vtab"); end,
		float = function(ws) workspace_set(ws, "float"); end,

		set_label = workspace_label,
		set_background = workspace_background,

-- can be used for clipping / transitions
		anchor = null_surface(wm.width, wm.height),
		mode = "tile",
		name = "workspace_" .. tostring(ent_count);
		insert = "h",
		children = {},
		weight = 1.0,
		vweight = 1.0
	};
	image_tracetag(res.anchor, "workspace_anchor");
	show_image(res.anchor);
	link_image(res.anchor, wm.anchor);
	ent_count = ent_count + 1;
	res.wm = wm;
	workspace_set(res, gconfig_get("ws_default"));
	if (wm.background_name) then
		res:set_background(wm.background_name);
	end
	res:activate(anim);
	return res;
end

local function wnd_merge(wnd)
	local i = 1;
	while (i ~= #wnd.parent.children) do
		if (wnd.parent.children[i] == wnd) then
			break;
		end
		i = i + 1;
	end

	if (i < #wnd.parent.children) then
		for j=i+1,#wnd.parent.children do
			table.insert(wnd.children, wnd.parent.children[j]);
			wnd.parent.children[j].parent = wnd;
		end
		for j=#wnd.parent.children,i+1,-1 do
			table.remove(wnd.parent.children, j);
		end
	end

	wnd.space:resize();
end

local function wnd_collapse(wnd)
	for k,v in ipairs(wnd.children) do
		table.insert(wnd.parent.children, v);
		v.parent = wnd.parent;
	end
	wnd.children = {};
	wnd.space:resize();
end

local function apply_scalemode(wnd, mode, src, props, maxw, maxh, force)
	local outw = 1;
	local outh = 1;

	if (wnd.scalemode == "normal" and not force) then
		if (props.width > 0 and props.height > 0) then
			outw = props.width < maxw and props.width or maxw;
			outh = props.height < maxh and props.height or maxh;
		end

	elseif (force or wnd.scalemode == "stretch") then
		outw = maxw;
		outh = maxh;

	elseif (wnd.scalemode == "aspect") then
		local ar = props.width / props.height;
		local wr = props.width / maxw;
		local hr = props.height/ maxh;

		outw = hr > wr and maxh * ar or maxw;
		outh = hr < wr and maxw / ar or maxh;
	end

	outw = math.floor(outw);
	outh = math.floor(outh);
	resize_image(src, outw, outh);
	if (wnd.autocrop) then
		local ip = image_storage_properties(src);
		image_set_txcos_default(src, wnd.origo_ll);
		image_scale_txcos(src, outw / ip.width, outh / ip.height);
	end
	if (wnd.filtermode) then
		image_texfilter(src, wnd.filtermode);
	end

	return outw, outh;
end

local function wnd_effective_resize(wnd, neww, newh, force)
	wnd:resize(neww + wnd.pad_left + wnd.pad_right,
		newh + wnd.pad_top + wnd.pad_bottom);
end

local function wnd_font(wnd, sz, hint, font)
	if (wnd.font_block) then
		if (type(wnd.font_block) == "function") then
			wnd:font_block(sz, hint, font);
		end
		return;
	end

	if (valid_vid(wnd.external, TYPE_FRAMESERVER)) then
		wnd.last_font = {sz, hint, font};
		if (font) then
			local dtbl = {};
			if (type(font) == "table") then
				dtbl = font;
			else
				dtbl[1] = font;
			end

			target_fonthint(wnd.external, dtbl[1], sz * FONT_PT_SZ, hint);
			for i=2,#dtbl do
				target_fonthint(wnd.external, dtbl[i], sz * FONT_PT_SZ, hint, true);
			end
		else
			target_fonthint(wnd.external, sz * FONT_PT_SZ, hint);
		end
	end
end

local function wnd_resize(wnd, neww, newh, force)
	if (wnd.in_drag_rz and not force) then
		return false;
	end

	neww = wnd.wm.min_width > neww and wnd.wm.min_width or neww;
	newh = wnd.wm.min_height > newh and wnd.wm.min_height or newh;

	wnd.width = neww;
	wnd.height = newh;

	local props = image_storage_properties(wnd.canvas);

	if (wnd.wm.debug_console) then
		wnd.wm.debug_console:system_event(string.format("%s%s resized to %d, %d",
			wnd.name, force and " force" or "", neww, newh));
	end

-- to save space for border width, statusbar and other properties
	if (not wnd.fullscreen) then
		move_image(wnd.canvas, wnd.pad_left, wnd.pad_top);
		neww = neww - wnd.pad_left - wnd.pad_right;
		newh = newh - wnd.pad_top - wnd.pad_bottom;
	end

	if (neww <= 0 or newh <= 0) then
		return;
	end

	wnd.effective_w = math.ceil(neww);
	wnd.effective_h = math.ceil(newh);

-- now we know dimensions of the window in regards to its current tiling cell
-- etc. so we can resize the border accordingly (or possibly cascade weights)
	wnd.effective_w, wnd.effective_h = apply_scalemode(wnd,
		wnd.scalemode, wnd.canvas, props, neww, newh, wnd.space.mode == "float");

	local bw = wnd.border_w;
	local tbh = tbar_geth(wnd);
	local size_decor = function(w, h)
		resize_image(wnd.anchor, w, h);
		wnd.titlebar:move(bw, bw);
		wnd.titlebar:resize(w - bw - bw, tbh);
		resize_image(wnd.border, w, h);
	end

-- still up for experimentation, but this method favors the canvas size rather
-- than the allocated tile size
	size_decor(wnd.effective_w + bw + bw, wnd.effective_h + tbh + bw + bw);
	wnd.pad_top = bw + tbh;
	move_image(wnd.canvas, wnd.pad_left, wnd.pad_top);

	if (wnd.centered and wnd.space.mode ~= "float") then
		if (wnd.space.mode == "tile") then
			move_image(wnd.anchor, wnd.x, wnd.y);
		elseif (wnd.space.mode == "tab" or wnd.space.mode == "vtab") then
			move_image(wnd.anchor, 0, 0);
		end
		if (wnd.fullscreen) then
			move_image(wnd.canvas, math.floor(0.5*(wnd.wm.width - wnd.effective_w)),
				math.floor(0.5*(wnd.wm.height - wnd.effective_h)));
		else
			nudge_image(wnd.anchor, math.floor(0.5*(neww - wnd.effective_w)),
				math.floor(0.5*(newh - wnd.effective_h)));
		end
	end

	run_event(wnd, "resize", neww, newh, wnd.effective_w, wnd.effective_h);
end

-- sweep all windows, calculate center-point distance,
-- and weight based on desired direction (no diagonals)
local function find_nearest(wnd, wx, wy, rec)
	local lst = linearize(wnd.space);
	local ddir = {};

	local cp_xy = function(vid)
		local props = image_surface_resolve_properties(vid);
		return (props.x + 0.5 * props.width), (props.y + 0.5 * props.height);
	end

	local bp_x, bp_y = cp_xy(wnd.canvas);

-- only track distances for windows in the desired direction (wx, wy)
	local shortest;

	for k,v in ipairs(lst) do
		if (v ~= wnd) then
			local cp_x, cp_y = cp_xy(v.canvas);
			cp_x = cp_x - bp_x;
			cp_y = cp_y - bp_y;
			local dist = math.sqrt(cp_x * cp_x + cp_y * cp_y);
			if ((cp_x * wx > 0) or (cp_y * wy > 0)) then
				if (not shortest or dist < shortest[2]) then
					shortest = {v, dist};
				end
			end
		end
	end

	return (shortest and shortest[1] or nil);
end

local function wnd_next(mw, level)
	if (mw.fullscreen) then
		return;
	end

	local mwm = mw.space.mode;
	if (mwm == "float") then
		wnd = level and find_nearest(mw, 0, 1) or find_nearest(mw, 1, 0);
		if (wnd) then
			wnd:select();
			return;
		end

	elseif (mwm == "tab" or mwm == "vtab") then
		local lst = linearize(mw.space);
		local ind = table.find_i(lst, mw);
		ind = ind == #lst and 1 or ind + 1;
		lst[ind]:select();
		return;
	end

	if (level) then
		if (#mw.children > 0) then
			mw.children[1]:select();
			return;
		end
	end

	local i = 1;
	while (i < #mw.parent.children) do
		if (mw.parent.children[i] == mw) then
			break;
		end
		i = i + 1;
	end

	if (i == #mw.parent.children) then
		if (mw.parent.parent ~= nil) then
			return wnd_next(mw.parent, false);
		else
			i = 1;
		end
	else
		i = i + 1;
	end

	mw.parent.children[i]:select();
end

local function wnd_prev(mw, level)
	if (mw.fullscreen) then
		return;
	end

	local mwm = mw.space.mode;
	if (mwm == "float") then
		wnd = level and find_nearest(mw, 0, -1) or find_nearest(mw, -1, 0);
		if (wnd) then
			wnd:select();
			return;
		end

	elseif (mwm == "tab" or mwm == "vtab" or mwm == "float") then
		local lst = linearize(mw.space);
		local ind = table.find_i(lst, mw);
		ind = ind == 1 and #lst or ind - 1;
		lst[ind]:select();
		return;
	end

	if (level or mwm == "tab" or mwm == "vtab") then
		if (mw.parent.select) then
			mw.parent:select();
			return;
		end
	end

	local ind = 1;
	for i,v in ipairs(mw.parent.children) do
		if (v == mw) then
			ind = i;
			break;
		end
	end

	if (ind == 1) then
		if (mw.parent.parent) then
			mw.parent:select();
		else
			mw.parent.children[#mw.parent.children]:select();
		end
	else
		ind = ind - 1;
		mw.parent.children[ind]:select();
	end
end

local function wnd_reassign(wnd, ind, ninv)
-- for reassign by name, resolve to index
	local newspace = nil;

	if (type(ind) == "string") then
		for k,v in pairs(wnd.wm.spaces) do
			if (v.label == ind) then
				ind = k;
			end
		end
		if (type(ind) == "string") then
			return;
		end
		newspace = wnd.wm.spaces[ind];
	elseif (type(ind) == "table") then
		newspace = ind;
	else
		newspace = wnd.wm.spaces[ind];
	end

-- don't switch unless necessary
	if (wnd.space == newspace or wnd.fullscreen) then
		return;
	end

	if (wnd.space.selected == wnd) then
		wnd.space.selected = nil;
	end

	if (wnd.space.previous == wnd) then
		wnd.space.previous = nil;
	end

-- drop selection references unless we can find a new one,
-- or move to child if there is one
	if (wnd.wm.selected == wnd) then
		wnd:prev();
		if (wnd.wm.selected == wnd) then
			if (wnd.children[1] ~= nil) then
				wnd.children[1]:select();
			else
				wnd.wm.selected = nil;
			end
		end
	end
-- create if it doesn't exist
	local oldspace_ind = wnd.wm.active_space;
	if (newspace == nil) then
		wnd.wm.spaces[ind] = create_workspace(wnd.wm);
		newspace = wnd.wm.spaces[ind];
	end

-- reparent
	table.remove_match(wnd.parent.children, wnd);
	for i,v in ipairs(wnd.children) do
		table.insert(wnd.parent.children, v);
		v.parent = wnd.parent;
	end

-- update workspace assignment
	wnd.children = {};
	local oldspace = wnd.space;
	wnd.space = newspace;
	wnd.space_ind = ind;
	wnd.parent = newspace;
	link_image(wnd.anchor, newspace.anchor);
	table.insert(newspace.children, wnd);

-- restore vid structure etc. to the default state
	if (oldspace.reassign_hook and newspace.mode ~= oldspace.mode) then
		oldspace:reassign_hook(wnd);
	end

-- weights aren't useful for new space, reset
	wnd.weight = 1.0;
	wnd.vweight = 1.0;

-- edge condition, if oldspace had more children, the select event would
-- have caused a deselect already - but deselect can only be called once
-- or iostatem_ saving will be messed up.
	if (#oldspace.children == 0) then
		wnd:deselect();
	end

-- subtle resize in order to propagate resize events while still hidden
	if (not(newspace.selected and newspace.selected.fullscreen)) then
		newspace.selected = wnd;
		newspace:resize();
		if (not ninv) then
			newspace:deactivate(true);
		end
	end

	tiler_statusbar_update(wnd.wm);
	wnd.wm.active_space = oldspace_ind;
	oldspace:resize();
end

local function wnd_move(wnd, dx, dy, align)
	if (wnd.space.mode ~= "float") then
		return;
	end

	if (align) then
		local pos = image_surface_properties(wnd.anchor);
		pos.x = pos.x + dx;
		pos.y = pos.y + dy;
		if (dx ~= 0) then
			pos.x = pos.x + (dx + -1 * dx) * math.fmod(pos.x, math.abs(dx));
		end
		if (dy ~= 0) then
			pos.y = pos.y + (dy + -1 * dy) * math.fmod(pos.y, math.abs(dy));
		end
		pos.x = pos.x < 0 and 0 or pos.x;
		pos.y = pos.y < 0 and 0 or pos.y;

		move_image(wnd.anchor, pos.x, pos.y);
	else
		nudge_image(wnd.anchor, dx, dy);
	end
end

--
-- re-adjust each window weight, they are not allowed to go down to negative
-- range and the last cell will always pad to fit
--
local function wnd_grow(wnd, w, h)
	if (wnd.space.mode == "float") then
		wnd:resize(wnd.width + (wnd.wm.width*w), wnd.height + (wnd.wm.height*h));
		return;
	end

	if (wnd.space.mode ~= "tile") then
		return;
	end

	if (h ~= 0) then
		wnd.vweight = wnd.vweight + h;
		wnd.parent.vweight = wnd.parent.vweight - h;
	end

	if (w ~= 0) then
		wnd.weight = wnd.weight + w;
		if (#wnd.parent.children > 1) then
			local ws = w / (#wnd.parent.children - 1);
		for i=1,#wnd.parent.children do
			if (wnd.parent.children[i] ~= wnd) then
				wnd.parent.children[i].weight = wnd.parent.children[i].weight - ws;
			end
		end
		end
	end

	wnd.space:resize();
end

local function wnd_title(wnd, message, skipresize)
	if (message ~= nil and string.len(message) > 0) then
		wnd.title_text = message;
	end

	if (wnd.title_prefix and string.len(wnd.title_prefix) > 0) then
		message = string.format("%s:%s", wnd.title_prefix,
			wnd.title_text and wnd.title_text or " ");
	else
		message = wnd.title_text and wnd.title_text or " ";
	end

	local tbh = tbar_geth(wnd);

-- only re-render if the message has changed
	local lbl = {gconfig_get("tbar_textstr"), message};
	wnd.titlebar:update("center", 1, lbl);

-- override if the mode requires it
	local hide_titlebar = wnd.hide_titlebar;
	if (not tbar_mode(wnd.space.mode)) then
		hide_titlebar = false;
	end

	if (hide_titlebar) then
		wnd.titlebar:hide();
		wnd.pad_top = wnd.border_w;
		if (not skipresize) then
			wnd:resize(wnd.width, wnd.height);
		end
		return;
	else
		wnd.pad_top = wnd.border_w + tbar_geth(wnd);
	end

	wnd.titlebar:show();
	if (not skipresize) then
		wnd.space:resize();
	end
end

local function convert_mouse_xy(wnd, x, y)
-- note, this should really take viewport into account (if provided), when
-- doing so, move this to be part of fsrv-resize and manual resize as this is
-- rather wasteful.
	local res = {};
	local sprop = image_storage_properties(
		valid_vid(wnd.external) and wnd.external or wnd.canvas);
	local aprop = image_surface_resolve_properties(wnd.canvas);
	local sfx = sprop.width / aprop.width;
	local sfy = sprop.height / aprop.height;
	local lx = sfx * (x - aprop.x);
	local ly = sfy * (y - aprop.y);

	res[1] = lx;
	res[2] = 0;
	res[3] = ly;
	res[4] = 0;

	if (wnd.last_ms) then
		res[2] = (wnd.last_ms[1] - res[1]);
		res[4] = (wnd.last_ms[2] - res[3]);
	else
		wnd.last_ms = {};
	end

	wnd.last_ms[1] = res[1];
	wnd.last_ms[2] = res[3];
	return res;
end

local function wnd_mousebutton(ctx, ind, pressed, x, y)
	local wnd = ctx.tag;
	if (wnd.wm.selected ~= wnd) then
		return;
	end

	output_mouse_devent({
		active = pressed, devid = 0, subid = ind}, wnd);
end

local function wnd_mouseclick(ctx, vid)
	local wnd = ctx.tag;

	if (wnd.wm.selected ~= wnd and
		gconfig_get("mouse_focus_event") == "click") then
		wnd:select();
		return;
	end

	if (not (vid == wnd.canvas and
		valid_vid(wnd.external, TYPE_FRAMESERVER))) then
		return;
	end

	output_mouse_devent({
		active = true, devid = 0, subid = 0, gesture = true, label = "click"}, wnd);
end

local function wnd_toggle_maximize(wnd)
	if (wnd.float_dim) then
		move_image(wnd.anchor,
			wnd.float_dim.x * wnd.wm.width, wnd.float_dim.y * wnd.wm.height);
		wnd:resize(wnd.float_dim.w * wnd.wm.width, wnd.float_dim.h * wnd.wm.height);
		wnd.float_dim = nil;
	else
		local cur = {};
		local props = image_surface_resolve_properties(wnd.anchor);
		cur.x = props.x / wnd.wm.width;
		cur.y = props.y / wnd.wm.height;
		cur.w = wnd.width / wnd.wm.width;
		cur.h = wnd.height / wnd.wm.height;
		wnd.float_dim = cur;
		wnd:resize(wnd.wm.width, wnd.wm.height);
		move_image(wnd.anchor, 0, 0);
	end
end

local function wnd_mousedblclick(ctx)
	output_mouse_devent({
		active = true, devid = 0, subid = 0,
		label = "dblclick", gesture = true}, ctx.tag
	);
end

local function wnd_mousepress(ctx)
	local wnd = ctx.tag;

	if (wnd.wm.selected ~= wnd) then
		if (gconfig_get("mouse_focus_event") == "click") then
			wnd:select();
		end
		return;
	end

	if (wnd.space.mode ~= "float") then
		return;
	end
end

local function wnd_mousemotion(ctx, x, y)
	local wnd = ctx.tag;
	local mv = convert_mouse_xy(wnd, x, y);
	local iotbl = {
		kind = "analog",
		source = "mouse",
		devid = 0,
		subid = 0,
		samples = {mv[1], mv[2]}
	};
	local iotbl2 = {
		kind = "analog",
		source = "mouse",
		devid = 0,
		subid = 1,
		samples = {mv[3], mv[4]}
	};

-- with rate limited mouse events (those 2khz gaming mice that likes
-- to saturate things even when not needed), we accumulate relative samples
	if (not wnd.rate_unlimited) then
		local ep = EVENT_SYNCH[wnd.canvas].pending;
		if (ep) then
			ep[1].samples[1] = mv[1];
			ep[1].samples[2] = ep[1].samples[2] + mv[2];
			ep[2].samples[1] = mv[3];
			ep[2].samples[2] = ep[2].samples[2] + mv[4];
		else
			EVENT_SYNCH[wnd.canvas].pending = {iotbl, iotbl2};
		end
	else
		target_input(wnd.external, iotbl);
		target_input(wnd.external, iotbl2);
	end
end

local function dist(x, y)
	return math.sqrt(x * x + y * y);
end

-- returns: [ul, u, ur, r, lr, l, ll, l]
local function wnd_borderpos(wnd)
	local x, y = mouse_xy();
	local props = image_surface_resolve_properties(wnd.anchor);

-- hi-clamp radius, select corner by distance (priority)
	local cd_ul = dist(x-props.x, y-props.y);
	local cd_ur = dist(props.x + props.width - x, y - props.y);
	local cd_ll = dist(x-props.x, props.y + props.height - y);
	local cd_lr = dist(props.x + props.width - x, props.y + props.height - y);

	local lim = 16 < (0.5 * props.width) and 16 or (0.5 * props.width);
	if (cd_ur < lim) then
		return "ur";
	elseif (cd_lr < lim) then
		return "lr";
	elseif (cd_ll < lim) then
		return "ll";
	elseif (cd_ul < lim) then
		return "ul";
	end

	local dle = x-props.x;
	local dre = props.x+props.width-x;
	local due = y-props.y;
	local dde = props.y+props.height-y;

	local dx = dle < dre and dle or dre;
	local dy = due < dde and due or dde;

	if (dx < dy) then
		return dle < dre and "l" or "r";
	else
		return due < dde and "u" or "d";
	end
end

local dir_lut = {
	ul = {"rz_diag_r", {-1, -1, 1, 1}},
	 u = {"rz_up", {0, -1, 0, 1}},
	ur = {"rz_diag_l", {1, -1, 0, 1}},
	 r = {"rz_right", {1, 0, 0, 0}},
	lr = {"rz_diag_r", {1, 1, 0, 0}},
	 d = {"rz_down", {0, 1, 0, 0}},
	ll = {"rz_diag_l", {-1, 1, 1, 0}},
	 l = {"rz_left", {-1, 0, 1, 0}}
};

local function wnd_mousehover(ctx, vid)
	local wnd = ctx.tag;
-- this event can be triggered slightly deferred and race against destroy
	if (not wnd.wm) then
		return;
	end

	if (wnd.wm.selected ~= ctx.tag and
		gconfig_get("mouse_focus_event") == "hover") then
		wnd:select();
	end
-- good place for tooltip hover hint
end

local function wnd_mouseover(ctx, vid)
--focus follows mouse
	local wnd = ctx.tag;

	if (wnd.wm.selected ~= ctx.tag and
		gconfig_get("mouse_focus_event") == "motion") then
		wnd:select();
	end
end

local function wnd_alert(wnd)
	local wm = wnd.wm;

	if (not wm.selected or wm.selected == wnd) then
		return;
	end

	if (wnd.space ~= wm.spaces[wm.space_ind]) then
		wm.sbar_ws[wnd.space_ind]:switch_state("alert");
	end

	wnd.titlebar:switch_state("alert", true);
	shader_setup(wnd.border, "ui", "border", "alert");
end

local function wnd_prefix(wnd, prefix)
	wnd.title_prefix = prefix and prefix or "";
	wnd:set_title();
end

local function wnd_addhandler(wnd, ev, fun)
	assert(ev);
	if (wnd.handlers[ev] == nil) then
		warning("tried to add handler for unknown event: " .. ev);
		return;
	end
	table.remove_match(wnd.handlers[ev], fun);
	table.insert(wnd.handlers[ev], fun);
end

local function wnd_dispmask(wnd, val, noflush)
	wnd.dispmask = val;
	if (not noflush and valid_vid(wnd.external, TYPE_FRAMESERVER)) then
		target_displayhint(wnd.external, 0, 0, wnd.dispmask);
	end
end

local function wnd_migrate(wnd, tiler, disptbl)
	if (tiler == wnd.wm) then
		return;
	end

-- select next in line
	wnd:prev();
	if (wnd.wm.selected == wnd) then
		if (wnd.children[1] ~= nil) then
			wnd.children[1]:select();
		else
			wnd.wm.selected = nil;
		end
	end

-- reassign children to parent
	for i,v in ipairs(wnd.children) do
		table.insert(wnd.parent.children, v);
	end
	wnd.children = {};
	for i,v in ipairs(get_hier(wnd.anchor)) do
		rendertarget_attach(tiler.rtgt_id, v, RENDERTARGET_DETACH);
	end
	rendertarget_attach(tiler.rtgt_id, wnd.anchor, RENDERTARGET_DETACH);
	local ind = table.find_i(wnd.parent.children, wnd);
	table.remove(wnd.parent.children, ind);

	if (wnd.fullscreen) then
		wnd.space:tile();
	end

-- change association with wm and relayout old one
	local oldsp = wnd.space;
	table.remove_match(wnd.wm.windows, wnd);
	wnd.wm = tiler;

-- make sure titlebar sizes etc. match
	wnd:rebuild_border(gconfig_get("borderw"));

-- employ relayouting hooks to currently active ws
	local dsp = tiler.spaces[tiler.space_ind];
	wnd:assign_ws(dsp, true);

-- rebuild border and titlebar to account for changes in font/scale
	for i in wnd.titlebar:all_buttons() do
		i.fontfn = tiler.font_resfn;
	end
	wnd.titlebar:invalidate();
	wnd:set_title(tt);
	if (wnd.last_font) then
		wnd:update_font(unpack(wnd.last_font));
	end

-- propagate pixel density information
	if (disptbl and valid_vid(wnd.external, TYPE_FRAMESERVER)) then
		target_displayhint(wnd.external, 0, 0, wnd.dispmask, disptbl);
	end

-- special handling, will be next selected
	if (tiler.deactivated and not tiler.deactivated.wnd) then
		tiler.deactivated.wnd = wnd;
	elseif (not tiler.deactivated) then
		tiler.deactivated = {
			wnd = wnd,
			mx = 0.5 * tiler.width,
			my = 0.5 * tiler.height
		};
	end
end

-- track suspend state with window so that we can indicate with
-- border color and make sure we don't send state changes needlessly
local function wnd_setsuspend(wnd, val)
	local susp = val;
	if ((wnd.suspended and susp) or (not wnd.suspended and not susp) or
		not valid_vid(wnd.external, TYPE_FRAMESERVER)) then
		return;
	end

	local sel = (wnd.wm.selected == wnd);

	if (susp) then
		suspend_target(wnd.external);
		wnd.suspended = true;
		shader_setup(wnd.border, "ui", "border", "suspended");
		wnd.titlebar:switch_state("suspended", true);
	else
		resume_target(wnd.external);
		wnd.suspended = nil;
		shader_setup(wnd.border, "ui", "border", sel and "active" or "inactive");
		wnd.titlebar:switch_state(sel and "active" or "inactive");
	end
end

local function wnd_tofront(wnd)
	local wm = wnd.wm;
	local wnd_i = table.find_i(wm.windows, wnd);
	if (wnd_i) then
		table.remove(wm.windows, wnd_i);
	end

	table.insert(wm.windows, wnd);
	for i=1,#wm.windows do
		order_image(wm.windows[i].anchor, i * WND_RESERVED);
	end

	order_image(wm.order_anchor, #wm.windows * 2 * WND_RESERVED);
end

local function wnd_rebuild(v, bw)
	local tbarh = tbar_geth(v);
	v.pad_left = bw;
	v.pad_right = bw;
	v.pad_top = bw + tbarh;
	v.pad_bottom = bw;
	v.border_w = bw;

	if (v.space.mode == "tile" or v.space.mode == "float") then
		v.titlebar:move(v.border_w, v.border_w);
		v.titlebar:resize(v.width - v.border_w * 2, tbarh);
		link_image(v.canvas, v.anchor);
		move_image(v.canvas, v.pad_left, v.pad_top);
		resize_image(v.canvas, v.effective_w, v.effective_h);
	end
end

local titlebar_mh = {
	over = function(ctx)
		if (ctx.tag.space.mode == "float") then
			mouse_switch_cursor("grabhint");
		end
	end,
	out = function(ctx)
		mouse_switch_cursor("default");
	end,
	press = function(ctx)
		ctx.tag:select();
		if (ctx.tag.space.mode == "float") then
			mouse_switch_cursor("drag");
		end
	end,
	release = function(ctx)
		mouse_switch_cursor("grabhint");
	end,
	drop = function(bar)
	end,
	drag = function(ctx, vid, dx, dy)
		local tag = ctx.tag;
		if (tag.space.mode == "float") then
			nudge_image(tag.anchor, dx, dy);
		end
-- possibly check for other window in tile hierarchy based on
-- polling mouse cursor, and do a window swap
	end,
	click = function(ctx)
	end,
	dblclick = function(ctx)
		local tag = ctx.tag;
		if (tag.space.mode == "float") then
			tag:toggle_maximize();
		end
	end
};

local border_mh = {
	over = function(ctx)
		if (ctx.tag.space.mode == "float") then
			local p = wnd_borderpos(ctx.tag);
			local ent = dir_lut[p];
			ctx.mask = ent[2];
			mouse_switch_cursor(ent[1]);
		end
	end,
	out = function(ctx)
		mouse_switch_cursor("default");
	end,
	drag = function(ctx, vid, dx, dy)
		local wnd = ctx.tag;
		if (wnd.space.mode == "float" and ctx.mask) then
			wnd.in_drag_rz = true;
			nudge_image(wnd.anchor, dx * ctx.mask[3], dy * ctx.mask[4]);
			wnd:resize(wnd.width+dx*ctx.mask[1], wnd.height+dy*ctx.mask[2], true);
		end
	end,
	drop = function(ctx)
		ctx.tag.in_drag_rz = false;
	end
};

local canvas_mh = {
	motion = function(ctx, vid, ...)
		if (valid_vid(ctx.tag.external, TYPE_FRAMESERVER)) then
			wnd_mousemotion(ctx, ...);
		end
	end,

	press = wnd_mousepress,

	over = function(ctx)
		local tag = ctx.tag;
		if (tag.wm.selected ~= tag and gconfig_get(
			"mouse_focus_event") == "motion") then
			tag:select();
		end

		if (ctx.tag.cursor == "hidden") then
			mouse_hide();
		end
	end,

	out = function(ctx)
		mouse_hidemask(true);
		mouse_show();
		mouse_hidemask(false);
	end,

	button = function(ctx, vid, ...)
		if (valid_vid(ctx.tag.external, TYPE_FRAWMESERVER)) then
			wnd_mousebutton(ctx, ...);
		end
	end,

	dblclick = function(ctx)
		if (valid_vid(ctx.tag.external, TYPE_FRAMESERVER)) then
			wnd_mousedblclick(ctx);
		end
	end
};

local function wnd_create(wm, source, opts)
	if (opts == nil) then opts = {}; end
	local bw = gconfig_get("borderw");
	local res = {
		anchor = null_surface(1, 1),
-- we use fill surfaces rather than color surfaces to get texture coordinates
		border = fill_surface(1, 1, 255, 255, 255),
		canvas = source,
		gain = 1.0 * gconfig_get("global_gain"),

-- hierarchies used for tile layout
		children = {},

-- specific event / keysym bindings
		labels = {},
		dispatch = {},

-- register:able event handlers to relate one window to another
		relatives = {},
		handlers = {
			destroy = {},
			resize = {},
			gained_relative = {},
			lost_relative = {},
			select = {},
			deselect = {},
			mouse = {}
		},

-- can be modified to reserve space for scrollbars and other related contents
		pad_left = bw,
		pad_right = bw,
		pad_top = bw,
		pad_bottom = bw,

-- note on multi-PPCM:
-- scale factor is manipulated by the display manager in order to take pixel
-- density into account, so when a window is migrated or similar -- scale
-- factor may well change. Sizes are primarily defined relative to self or
-- active default font size though, and display manager changes font-size
-- during migration and display setup.

-- properties that change visual behavior
		border_w = gconfig_get("borderw"),
		dispmask = 0,
		name = "wnd_" .. tostring(ent_count),
		effective_w = 0,
		effective_h = 0,
		weight = 1.0,
		vweight = 1.0,
		cfg_prefix = "",
		hide_titlebar = gconfig_get("hide_titlebar"),
		scalemode = opts.scalemode and opts.scalemode or "normal",

-- public events to manipulate the window
		alert = wnd_alert,
		assign_ws = wnd_reassign,
		destroy = wnd_destroy,
		set_message = wnd_message,
		set_title = wnd_title,
		set_prefix = wnd_prefix,
		add_handler = wnd_addhandler,
		set_dispmask = wnd_dispmask,
		set_suspend = wnd_setsuspend,
		rebuild_border = wnd_rebuild,
		toggle_maximize = wnd_toggle_maximize,
		to_front = wnd_tofront,
		update_font = wnd_font,
		resize = wnd_resize,
		migrate = wnd_migrate,
		resize_effective = wnd_effective_resize,
		select = wnd_select,
		deselect = wnd_deselect,
		next = wnd_next,
		merge = wnd_merge,
		collapse = wnd_collapse,
		prev = wnd_prev,
		move =wnd_move,
		mousemotion = wnd_mousemotion,
		grow = wnd_grow
	};

	if (wm.debug_console) then
		wm.debug_console:system_event(string.format("new window using %d", source));
	end

	local space = wm.spaces[wm.space_ind];
	res.space_ind = wm.space_ind;
	res.space = space;
	if (space.mode == "float") then
		res.width = math.floor(wm.width * gconfig_get("float_defw"));
		res.height = math.floor(wm.height * gconfig_get("float_defh"));
	else
		res.width = opts.width and opts.width or wm.min_width;
		res.height = opts.height and opts.height or wm.min_height;
	end

	ent_count = ent_count + 1;
	image_tracetag(res.anchor, "wnd_anchor");
	image_tracetag(res.border, "wnd_border");
	image_tracetag(res.canvas, "wnd_canvas");
	res.wm = wm;

	image_mask_set(res.anchor, MASK_UNPICKABLE);
	res.titlebar = uiprim_bar(res.anchor, ANCHOR_UL,
		res.width - 2 * bw, tbar_geth(res), "titlebar", titlebar_mh);
	res.titlebar.tag = res;
	res.titlebar:move(bw, bw);

	res.titlebar:add_button("center", nil, "titlebar_text",
		" ", gconfig_get("sbar_tpad") * wm.scalef, res.wm.font_resfn);
	res.titlebar:hide();

	if (wm.spaces[wm.space_ind] == nil) then
		wm.spaces[wm.space_ind] = create_workspace(wm);
	end

	image_inherit_order(res.anchor, true);
	image_inherit_order(res.border, true);
	image_inherit_order(res.canvas, true);

	link_image(res.canvas, res.anchor);
	link_image(res.border, res.anchor);

-- order canvas so that it comes on top of the border for mouse events
	order_image(res.canvas, 2);

	shader_setup(res.border, "ui", "border", "active");
	show_image({res.border, res.canvas});

	if (not wm.selected or wm.selected.space ~= space) then
		table.insert(space.children, res);
		res.parent = space;

	elseif (space.insert == "h") then
		if (wm.selected.parent) then
			table.insert(wm.selected.parent.children, res);
			res.parent = wm.selected.parent;
		else
			table.insert(space.children, res);
			res.parent = space;
		end
	else
		table.insert(wm.selected.children, res);
		res.parent = wm.selected;
	end

	res.handlers.mouse.border = {
		name = tostring(res.anchor) .. "_border",
		own = function(ctx, vid) return vid == res.border; end,
		tag = res
	};

	res.handlers.mouse.canvas = {
		name = tostring(res.anchor) .. "_canvas",
		own = function(ctx, vid) return vid == res.canvas; end,
		tag = res
	};

	local tl = {};
	for k,v in pairs(border_mh) do
		res.handlers.mouse.border[k] = v;
		table.insert(tl, k);
	end
	mouse_addlistener(res.handlers.mouse.border, tl);

	tl = {};
	for k,v in pairs(canvas_mh) do
		res.handlers.mouse.canvas[k] = v;
		table.insert(tl, k);
	end
	mouse_addlistener(res.handlers.mouse.canvas, tl);

	link_image(res.anchor, space.anchor);

	if (not(wm.selected and wm.selected.fullscreen)) then
		show_image(res.anchor);
		space:resize(res);
		res:select();
	else
		shader_setup(res.border, "ui", "border", "inactive");
	end

	res.block_mouse = opts.block_mouse;

	if (res.space.mode == "float") then
		move_image(res.anchor, mouse_xy());
		res:resize(res.width, res.height);
	end

	wm:on_wnd_create(res);
	return res;
end

local function tick_windows(wm)
	for k,v in ipairs(wm.windows) do
		if (v.tick) then
			v:tick();
		end
	end
	wm.statusbar:tick();
end

local function tiler_find(wm, source)
	for i=1,#wm.windows do
		if (wm.windows[i].canvas == source) then
			return wm.windows[i];
		end
	end
	return nil;
end

local function tiler_switchws(wm, ind)
	if (type(ind) ~= "number") then
		for k,v in pairs(wm.spaces) do
			if (type(ind) == "table" and v == ind) then
				ind = k;
				break;
			elseif (type(ind) == "string" and v.label == ind) then
				ind = k;
				break;
			end
		end
-- no match
		if (type(ind) ~= "number") then
			return;
		end
	end

	local cw = wm.selected;
	if (ind == wm.space_ind) then
		return;
	end

	local nd = wm.space_ind < ind;
	local cursp = wm.spaces[wm.space_ind];

	if (not wm.spaces[ind]) then
		wm.spaces[ind] = create_workspace(wm, false);
	end

	local nextsp = wm.spaces[ind];

-- workaround for autodelete on workspace triggers are an edge condition when the
-- backgrounds are the same and should not be faded but when activate_ comes the
-- ws is already dead so we need an intermediate
	local oldbg = nil;
	local nextbg = nextsp.background and nextsp.background or wm.background_id;
	if (valid_vid(nextsp.background) and valid_vid(cursp.background)) then
		oldbg = null_surface(1, 1);
		image_sharestorage(cursp.background, oldbg);
	end

	if (cursp.switch_hook) then
		cursp:switch_hook(false, nd, nextbg, oldbg);
	else
		workspace_deactivate(cursp, false, nd, nextbg);
	end
-- policy, don't autodelete if the user has made some kind of customization
	if (#cursp.children == 0 and gconfig_get("ws_autodestroy") and
		(cursp.label == nil or string.len(cursp.label) == 0 ) and
		(cursp.background_name == nil or cursp.background_name == wm.background_name)) then
		cursp:destroy();
		wm.spaces[wm.space_ind] = nil;
		wm.sbar_ws[wm.space_ind]:hide();
	else
		cursp.selected = cw;
	end

	wm.sbar_ws[wm.space_ind]:switch_state("inactive");
	wm.sbar_ws[ind]:show();
	wm.sbar_ws[ind]:switch_state("active");
	wm.space_ind = ind;
	wm_update_mode(wm);

	if (nextsp.switch_hook) then
		nextsp:switch_hook(true, not nd, nextbg, oldbg);
	else
		workspace_activate(nextsp, false, not nd, oldbg);
	end

	if (valid_vid(oldbg)) then
		delete_image(oldbg);
	end
-- safeguard against broken state
	nextsp.selected = nextsp.selected and
		nextsp.selected or nextsp.children[1];

	if (nextsp.selected) then
		wnd_select(nextsp.selected);
	else
		wm.selected = nil;
	end

	tiler_statusbar_update(wm);
end

local function tiler_swapws(wm, ind2)
	local ind1 = wm.space_ind;

	if (ind2 == ind1) then
		return;
	end
  tiler_switchws(wm, ind2);
-- now space_ind is ind2 and ind2 is visible and hooks have been run
	local space = wm.spaces[ind2];
	wm.spaces[ind2] = wm.spaces[ind1];
 	wm.spaces[ind1] = space;
	wm.space_ind = ind1;
	wm_update_mode(wm);

 -- now the swap is done with, need to update bar again
	if (valid_vid(wm.spaces[ind1].label_id)) then
		mouse_droplistener(wm.spaces[ind1].tile_ml);
		delete_image(wm.spaces[ind1].label_id);
		wm.spaces[ind1].label_id = nil;
	end

	if (valid_vid(wm.spaces[ind2].label_id)) then
		mouse_droplistener(wm.spaces[ind1].tile_m2);
		delete_image(wm.spaces[ind2].label_id);
		wm.spaces[ind2].label_id = nil;
	end

	wm:tile_update();
end

local function wnd_swap(w1, w2, deep)
	if (w1 == w2) then
		return;
	end
-- 1. weights, only makes sense in tile mode
	if (w1.space.mode == "tile") then
		local wg1 = w1.weight;
		local wg1v = w1.vweight;
		w1.weight = w2.weight;
		w1.vweight = w2.vweight;
		w2.weight = wg1;
		w2.vweight = wg1v;
	end
-- 2. parent->children entries
	local wp1 = w1.parent;
	local wp1i = table.find_i(wp1.children, w1);
	local wp2 = w2.parent;
	local wp2i = table.find_i(wp2.children, w2);
	wp1.children[wp1i] = w2;
	wp2.children[wp2i] = w1;
-- 3. parents
	w1.parent = wp2;
	w2.parent = wp1;
-- 4. question is if we want children to tag along or not
	if (not deep) then
		for i=1,#w1.children do
			w1.children[i].parent = w2;
		end
		for i=1,#w2.children do
			w2.children[i].parent = w1;
		end
		local wc = w1.children;
		w1.children = w2.children;
		w2.children = wc;
	end
end

local function tiler_swapup(wm, deep, resel)
	local wnd = wm.selected;
	if (not wnd or wnd.parent.parent == nil) then
		return;
	end

	local p1 = wnd.parent;
	wnd_swap(wnd, wnd.parent, deep);
	if (resel) then
		p1:select();
	end

	wnd.space:resize();
end

local function tiler_swapdown(wm, resel)
	local wnd = wm.selected;
	if (not wnd or #wnd.children == 0) then
		return;
	end

	local pl = wnd.children[1];
	wnd_swap(wnd, wnd.children[1]);
	if (resel) then
		pl:select();
	end

	wnd.space:resize();
end

local function tiler_swapleft(wm, deep, resel)
	local wnd = wm.selected;
	if (not wnd) then
		return;
	end

	local ind = table.find_i(wnd.parent.children, wnd);
	assert(ind);

	if ((ind ~= 1 or wnd.parent.parent == nil) and #wnd.parent.children > 1) then
		local li = (ind - 1) == 0 and #wnd.parent.children or (ind - 1);
		local oldi = wnd.parent.children[li];
		wnd_swap(wnd, oldi, deep);
		if (resel) then oldi:select(); end
	elseif (ind == 1 and wnd.parent.parent) then
		local root_node = wnd.parent;
		while (root_node.parent.parent) do
			root_node = root_node.parent;
		end
		local li = table.find_i(root_node.parent.children, root_node);
		li = (li - 1) == 0 and #root_node.parent.children or (li - 1);
		wnd_swap(wnd, root_node.parent.children[li]);
	end
	wnd.space:resize();
end

local function tiler_swapright(wm, deep, resel)
	local wnd = wm.selected;
	if (not wnd) then
		return;
	end

	local ind = table.find_i(wnd.parent.children, wnd);
	assert(ind);

	if ((ind ~= 1 or wnd.parent.parent == nil) and #wnd.parent.children > 1) then
		local li = (ind + 1) > #wnd.parent.children and 1 or (ind + 1);
		local oldi = wnd.parent.children[li];
		wnd_swap(wnd, oldi, deep);
		if (resel) then oldi:select(); end
	elseif (ind == 1 and wnd.parent.parent) then
		local root_node = wnd.parent;
		while (root_node.parent.parent) do
			root_node = root_node.parent;
		end
		local li = table.find_i(root_node.parent.children, root_node);
		li = (li + 1) > #root_node.parent.children and 1 or (li + 1);
		wnd_swap(wnd, root_node.parent.children[li]);
	end

	wnd.space:resize();
end

local function tiler_message(tiler, msg, timeout)
	local msgvid;
	if (timeout ~= -1) then
		timeout = gconfig_get("msg_timeout");
	end

	tiler.sbar_ws["msg"]:update(msg == nil and "" or msg, timeout);
end

local function tiler_rebuild_border(tiler)
	local bw = gconfig_get("borderw");
	local tw = bw - gconfig_get("bordert");
	local s = {"active", "inactive", "alert", "default"};
	shader_update_uniform("border", "ui", "border", bw, s, "tiler-rebuild");
	shader_update_uniform("border", "ui", "thickness", tw, s, "tiler-rebuild");

	for i,v in ipairs(tiler.windows) do
		v:rebuild_border(bw);
	end
end

local function tiler_rendertarget(wm, set)
	if (set == nil or (wm.rtgt_id and set) or (not set and not wm.rtgt_id)) then
		return wm.rtgt_id;
	end

	local list = get_hier(wm.anchor);

-- the surface we use as rendertarget for compositioning will use the highest
-- quality internal storage format, and disable the use of the alpha channel
	if (set == true) then
		wm.rtgt_id = alloc_surface(wm.width, wm.height, true, 1);
		image_tracetag(wm.rtgt_id, "tiler_rt" .. wm.name);
		local pitem = null_surface(32, 32); --workaround for rtgt restriction
		image_tracetag(pitem, "rendertarget_placeholder");
		define_rendertarget(wm.rtgt_id, {pitem});
		for i,v in ipairs(list) do
			rendertarget_attach(wm.rtgt_id, v, RENDERTARGET_DETACH);
		end
	else
		for i,v in ipairs(list) do
			rendertarget_attach(WORLDID, v, RENDERTARGET_DETACH);
		end
		delete_image(rt);
		wm.rtgt_id = nil;
	end
	image_texfilter(wm.rtgt_id, FILTER_NONE);
	return wm.rtgt_id;
end

local function wm_countspaces(wm)
	local r = 0;
	for i=1,10 do
		r = r + (wm.spaces[i] ~= nil and 1 or 0);
	end
	return r;
end

local function tiler_input_lock(wm, dst)
	if (wm.debug_console) then
		wm.debug_console:system_event(dst and ("input lock set to "
			.. tostring(dst)) or "input lock cleared");
	end
	wm.input_lock = dst;
end

local function tiler_resize(wm, neww, newh, norz)
-- special treatment for workspaces with float, we "fake" drop/set float
	for i=1,10 do
		if (wm.spaces[i] and wm.spaces[i].mode == "float") then
			drop_float(wm.spaces[i]);
		end
	end

	wm.width = neww;
	wm.height = newh;

	if (valid_vid(wm.rtgt_id)) then
		image_resize_storage(wm.rtgt_id, neww, newh);
	end

	for i=1,10 do
		if (wm.spaces[i] and wm.spaces[i].mode == "float") then
			set_float(wm.spaces[i]);
		end
	end

	if (not norz) then
		for k,v in pairs(wm.spaces) do
			v:resize(neww, newh);
		end
	end
end

local function tiler_activate(wm)
	if (wm.deactivated) then
		local deact = wm.deactivated;
		wm.deactivated = nil;
		mouse_absinput_masked(deact.mx, deact.my, true);
		if (deact.wnd) then
			deact.wnd:select();
		end
	end
end

-- could've just had the external party call deselect,
-- but hook may be useful for later so keep like this
local function tiler_deactivate(wm)
	local mx, my = mouse_xy();
	wm.deactivated = {
		mx = mx, my = my,
		wnd = wm.selected
	}
	if (wm.selected) then
		wm.selected:deselect(true);
	end
end

local function recalc_fsz(wm)
	local fsz = gconfig_get("font_sz") * wm.scalef - gconfig_get("font_sz");
	local int, fract = math.modf(fsz);
	int = int + ((fract > 0.75) and 1 or 0);
	if (int ~= int or int == 0/0 or int == -1/0 or int == 1/0) then
		int = 0;
	end

	wm.font_deltav = int;

-- since ascent etc. may be different at different sizes, render a test line
-- and set the "per tiler" shift here
	if (int > 0) then
		wm.font_delta = "\\f,+" .. tostring(int);
	elseif (int <= 0) then
		wm.font_delta = "\\f," .. tostring(int);
	end
end

-- the tiler is now on a display with a new scale factor, this means redoing
-- everything from decorations to rendered text which will cascade to different
-- window sizes etc.
local function tiler_scalef(wm, newf, disptbl)
	wm.scalef = newf;
	recalc_fsz(wm);
	wm:rebuild_border();

	for k,v in ipairs(wm.windows) do
		v:set_title();
		if (disptbl and valid_vid(v.external, TYPE_FRAMESERVER)) then
			target_displayhint(v.external, 0, 0, v.dispmask, disptbl);
		end
	end

	wm:resize(wm.width, wm.height);

-- easier doing things like this than fixing the other dimensioning edgecases
	wm.statusbar:destroy();
	tiler_statusbar_build(wm);
	wm:tile_update();
end

local function tiler_fontres(wm)
	return wm.font_delta .. "\\#ffffff", wm.scalef * gconfig_get("sbar_tpad");
end

local function tiler_switchbg(wm, newbg)
	wm.background_name = newbg;
	if (valid_vid(wm.background_id)) then
		delete_image(wm.background_id);
		wm.background_id = nil;
	end

-- we need this synchronously unfortunately
	if ((type(newbg) == "string" and resource(newbg))) then
		wm.background_id = load_image(newbg);
	elseif (valid_vid(newbg)) then
		wm.background_id = null_surface(wm.width, wm.height);
		image_sharestorage(newbg, wm.background_id);
	end

-- update for all existing spaces that uses this already
	for k,v in pairs(wm.spaces) do
		if (v.background == nil or v.background_name == wm.background_name) then
			v:set_background(wm.background_name);
		end
	end
end

function tiler_create(width, height, opts)
	opts = opts == nil and {} or opts;

	local res = {
-- null surfaces for clipping / moving / drawing
		name = opts.name and opts.name or "default",
		anchor = null_surface(1, 1),
		order_anchor = null_surface(1, 1),
		empty_space = workspace_empty,
		lbar = tiler_lbar,
		tick = tick_windows,

-- for multi-DPI handling
		font_delta = "\\f,+0",
		font_deltav = 0,
		font_sf = gconfig_get("font_defsf"),
		scalef = opts.scalef and opts.scalef or 1.0,

-- management members
		spaces = {},
		windows = {},
		space_ind = 1,

-- debug

-- kept per/tiler in order to allow custom modes as well
		scalemodes = {"normal", "stretch", "aspect"},

-- public functions
		set_background = tiler_switchbg,
		switch_ws = tiler_switchws,
		swap_ws = tiler_swapws,
		swap_up = tiler_swapup,
		swap_down = tiler_swapdown,
		swap_left = tiler_swapleft,
		swap_right = tiler_swapright,
		active_spaces = wm_countspaces,
		activate = tiler_activate,
		deactivate = tiler_deactivate,
		set_rendertarget = tiler_rendertarget,
		add_window = wnd_create,
		find_window = tiler_find,
		message = tiler_message,
		resize = tiler_resize,
		tile_update = tiler_statusbar_update,
		rebuild_border = tiler_rebuild_border,
		set_input_lock = tiler_input_lock,
		update_scalef = tiler_scalef,

-- unique event handlers
		on_wnd_create = function() end
	};

	res.font_resfn = function() return tiler_fontres(res); end
	res.height = height;
	res.width = width;
-- to help with y positioning when we have large subscript,
-- this is manually probed during font-load
	recalc_fsz(res);
	tiler_statusbar_build(res);

	res.min_width = 32;
	res.min_height = 32;
	image_tracetag(res.anchor, "tiler_anchor");
	image_tracetag(res.order_anchor, "tiler_order_anchor");

	order_image(res.order_anchor, 2);
	show_image({res.anchor, res.order_anchor});
	link_image(res.order_anchor, res.anchor);

-- unpack preset workspaces from saved keys
	local mask = string.format("wsk_%s_%%", res.name);
	local wstbl = {};
	for i,v in ipairs(match_keys(mask)) do
		local pos, stop = string.find(v, "=", 1);
		local key = string.sub(v, 1, pos-1);
		local ind, cmd = string.match(key, "(%d+)_(%a+)$");
		if (ind ~= nil and cmd ~= nil) then
			ind = tonumber(ind);
			if (wstbl[ind] == nil) then wstbl[ind] = {}; end
			local val = string.sub(v, pos+1);
			wstbl[ind][cmd] = val;
		end
	end

	for k,v in pairs(wstbl) do
		res.spaces[k] = create_workspace(res, true);
		for ind, val in pairs(v) do
			if (ind == "mode") then
				res.spaces[k].mode = val;
			elseif (ind == "insert") then
				res.spaces[k].insert = val;
			elseif (ind == "bg") then
				res.spaces[k]:set_background(val);
			elseif (ind == "label") then
				res.spaces[k]:set_label(val);
			end
		end
	end

-- always make sure we have a 'first one'
	if (not res.spaces[1]) then
		res.spaces[1] = create_workspace(res, true);
	end

	res:tile_update();
	return res;
end

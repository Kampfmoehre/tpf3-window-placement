-- Window placement mod for Transport Fever 3.
--
-- Restores the TF2 behaviour: a newly opened entity window is placed next to
-- the already pinned entity windows instead of always at the top-right corner
-- on top of them. Slots form a grid: columns are filled from the right screen
-- edge; within a column, a second row is used when a window still fits above
-- the bottom game bar (happens e.g. at 50% UI scale on a 3840x1600 screen).
--
-- How it hooks in: this script is loaded through a "react-plugin
-- ::ModEntryPointExtension" resource (entry.res.lua), so it runs inside the
-- game's GUI Lua state (see base gui/main/game.tl, EntryPoints). builtin.lua is
-- cached per resolved path in _ug_loadedModules, so wrapping builtin.Window
-- here also affects base gui/entity_window/view_manager.tl, which hardcodes
-- initialX = 1, initialY = 0 for every entity window.
--
-- Coordinates: initialX/initialY are screen fractions (0..1). The entity
-- window CSS uses anchorPoint = {1, 0}, i.e. initialX is the window's RIGHT
-- edge and initialY its TOP edge. api.gui.byId.getSize(id) returns the outer
-- box (incl. CSS margins) as screen fractions as well.
--
-- .script.lua files must export via function data() (see base
-- scripts/construction/assetbuilderutil.script.lua).

function data()
	local VERSION = "0.1.1"

	local react = ug_require "::/gui/main/react.lua"
	local builtin = ug_require "::/gui/main/builtin.lua"
	local mod_entry_point = ug_require "::/gui/main/mod_entry_point.tl"

	---------------------------------------------------------------------------
	-- Tunables
	---------------------------------------------------------------------------
	-- Horizontal: getSize() includes the CSS margins, so two adjacent slots show
	-- a gap of roughly 13% of a window's width (scales with the UI). Pull each
	-- next column back to the right by this fraction of the window width.
	-- 0 = full margin gap, 0.13 = windows touch, 0.10 = small gap.
	local GAP_REDUCTION_FRACTION = 0.10
	-- Vertical: margins are 15 top + 30 bottom (vs 30 + 30 horizontally), so the
	-- natural gap between rows is ~3/4 of the horizontal one. Expressed as a
	-- fraction of the window WIDTH so it scales the same way.
	local VGAP_REDUCTION_FRACTION = 0.07
	-- Order in which free slots are tried:
	--   "columns": top-right, below it, then next column to the left, ...
	--   "rows":    top-right, left of it, ... and only then the second row.
	local FILL_ORDER = "columns"
	-- Give up cascading left of this right-edge x and fall back to the default.
	local MIN_RIGHT_EDGE = 0.25
	-- Fallbacks when measuring fails (CSS px of entity_window_sizes.lua).
	local FALLBACK_WINDOW_WIDTH = 450
	local FALLBACK_BOTTOM_RESERVE = 0.06 -- game bar height as screen fraction
	local MAX_COLUMNS = 8
	local MAX_ROWS = 4

	---------------------------------------------------------------------------
	-- Helpers
	---------------------------------------------------------------------------
	-- Builtins may be called as builtin.X{params} or builtin.X(react.ref(r), {params})
	-- (see react.lua splitParams); the params table is always the last argument.
	local function lastArg(...)
		local n = select("#", ...)
		if n == 0 then return nil end
		return (select(n, ...))
	end

	local function screenSizePx()
		local ok, size = pcall(api.gui.camera.getSize)
		if ok and size and size.x and size.y and size.x > 0 and size.y > 0 then
			return size.x, size.y
		end
		return nil, nil
	end

	-- Outer size of a UI node as screen fractions (w, h), or nil.
	local function sizeFrac(id)
		local ok, size = pcall(api.gui.byId.getSize, id)
		if ok and size and size.x and size.y and size.x > 0 and size.y > 0 then
			if size.x <= 1 and size.y <= 1 then
				return size.x, size.y
			end
			local sw, sh = screenSizePx()
			if sw and sh then
				return size.x / sw, size.y / sh
			end
		end
		return nil, nil
	end

	local function bottomReserveFrac()
		local _, h = sizeFrac("menu.gamebar")
		if h and h < 0.3 then
			return h
		end
		return FALLBACK_BOTTOM_RESERVE
	end

	---------------------------------------------------------------------------
	-- Window registry: id -> { id, pinned, x (right edge), y (top), w, h }
	---------------------------------------------------------------------------
	local windows = {}

	-- Refresh measured sizes of tracked windows (cheap; a handful of calls).
	local function refreshSizes()
		for _, w in pairs(windows) do
			local wf, hf = sizeFrac(w.id)
			if wf then
				w.w, w.h = wf, hf
			end
		end
	end

	-- Estimated size of a window that does not exist yet: all entity windows
	-- share the same width; for the height take the tallest one seen.
	local function estimateNewSize()
		local wEst, hEst = nil, 0
		for _, w in pairs(windows) do
			if w.w and (wEst == nil or w.w > wEst) then
				wEst = w.w
			end
			if w.h and w.h > hEst then
				hEst = w.h
			end
		end
		local sw, sh = screenSizePx()
		if not wEst then
			wEst = FALLBACK_WINDOW_WIDTH / (sw or 3840)
		end
		if hEst <= 0 then
			-- max entity window is 900 CSS px tall vs 450 wide (plus margins)
			hEst = wEst * ((sw or 3840) / (sh or 1600)) * 1.85
		end
		return wEst, hEst
	end

	-- Does a candidate rect (right edge x, top y, size w x h) overlap a pinned
	-- window? The pinned window is shrunk by the gap reductions on each side.
	local function overlapsPinned(x, y, w, h, newId)
		local eps = 0.0005
		for id, p in pairs(windows) do
			if id ~= newId and p.pinned and p.x and p.y and p.w and p.h then
				local hg = p.w * GAP_REDUCTION_FRACTION
				local vg = p.w * VGAP_REDUCTION_FRACTION
				local pLeft, pRight = p.x - p.w + hg, p.x - hg
				local pTop, pBottom = p.y + vg, p.y + p.h - vg
				local cLeft, cRight = x - w, x
				local cTop, cBottom = y, y + h
				local hOverlap = cLeft < pRight - eps and cRight > pLeft + eps
				local vOverlap = cTop < pBottom - eps and cBottom > pTop + eps
				if hOverlap and vOverlap then
					return true
				end
			end
		end
		return false
	end

	-- The pinned window whose top-right corner sits at (x, y), if any.
	local function pinnedAt(x, y, w, newId)
		local eps = 0.0005
		for id, p in pairs(windows) do
			if id ~= newId and p.pinned and p.x and p.y and p.w and p.h then
				if math.abs(p.x - x) < w * 0.5 and math.abs(p.y - y) < eps + p.w * VGAP_REDUCTION_FRACTION then
					return p
				end
			end
		end
		return nil
	end

	-- Returns right edge x and top y (fractions) for a new window.
	local function findFreeSlot(newId)
		refreshSizes()
		local wEst, hEst = estimateNewSize()
		local bottomLimit = 1 - bottomReserveFrac()
		local hg = wEst * GAP_REDUCTION_FRACTION
		local vg = wEst * VGAP_REDUCTION_FRACTION

		-- Candidate (col, row) -> rect. Column right edges step left by one
		-- window width minus the gap reduction; row tops step down by the height
		-- of the window actually sitting above (or the estimate).
		local function candidate(col, row)
			local x = 1 - (col - 1) * (wEst - hg)
			local y = 0
			for _ = 1, row - 1 do
				local above = pinnedAt(x, y, wEst, newId)
				local hAbove = (above and above.h) or hEst
				y = y + hAbove - vg
			end
			return x, y
		end

		local function tryCandidate(col, row)
			local x, y = candidate(col, row)
			if x < MIN_RIGHT_EDGE then
				return nil
			end
			if y + hEst > bottomLimit + 0.001 then
				return nil -- does not fit above the game bar
			end
			if overlapsPinned(x, y, wEst, hEst, newId) then
				return nil
			end
			return x, y
		end

		if FILL_ORDER == "rows" then
			for row = 1, MAX_ROWS do
				for col = 1, MAX_COLUMNS do
					local x, y = tryCandidate(col, row)
					if x then return x, y end
				end
			end
		else
			for col = 1, MAX_COLUMNS do
				for row = 1, MAX_ROWS do
					local x, y = tryCandidate(col, row)
					if x then return x, y end
				end
			end
		end
		return 1, 0 -- no room: default spot
	end

	---------------------------------------------------------------------------
	-- Hook builtin.Window
	---------------------------------------------------------------------------
	if not builtin._kampfmoehreWindowPlacementOrig then
		local origWindow = builtin.Window
		builtin._kampfmoehreWindowPlacementOrig = origWindow

		builtin.Window = function(...)
			local params = lastArg(...)
			if type(params) == "table" and params.tool == "entityWindow" and params.id then
				local id = params.id
				local entry = windows[id]
				if entry == nil then
					entry = { id = id, pinned = params.pinned == true }
					entry.x, entry.y = findFreeSlot(id)
					windows[id] = entry
					log.message(string.format("[window_placement] new entity window %s -> x = %.3f, y = %.3f (pinned=%s)",
						tostring(id), entry.x, entry.y, tostring(entry.pinned)))
				elseif entry.pinned ~= (params.pinned == true) then
					entry.pinned = params.pinned == true
					log.message(string.format("[window_placement] %s pinned=%s", tostring(id), tostring(entry.pinned)))
				end

				params.initialX = entry.x
				params.initialY = entry.y

				local origOnClose = params.onClose
				params.onClose = function(...)
					windows[id] = nil
					if origOnClose then
						return origOnClose(...)
					end
				end

				-- We are inside the EntityWindow recipe execution here, so react
				-- hooks are legal: drop the entry when the window node is removed
				-- (covers replacement of unpinned windows, close-all, entity deletion).
				react.onUnmount(function()
					if windows[id] == entry then
						windows[id] = nil
						log.message("[window_placement] unmounted " .. tostring(id))
					end
				end)
			end
			return origWindow(...)
		end
		log.message("[window_placement] v" .. VERSION .. " builtin.Window wrapped")
	end

	local window_placement = {}
	window_placement.EntryPlugin = react.RegisterPluginRecipe(mod_entry_point.ModEntryPointExtension, "KampfmoehreWindowPlacementEntry", function()
		return builtin.BoxLayout{ children = {} }
	end)
	return window_placement
end

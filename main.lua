--- @since 26.9.1

-- stowr: move the hovered (or marked) file(s) into a GNU Stow package inside
-- your dotfiles repo, then run `stow` so the symlink is created back in place.

local HOME = os.getenv("HOME")

local function expand(path)
	if path == "~" then
		return HOME
	elseif path:sub(1, 2) == "~/" then
		return HOME .. path:sub(2)
	end
	return path
end

local function dirname(p)
	return p:match("^(.*)/[^/]+$") or "/"
end

local function is_under_home(p)
	return HOME ~= nil and p:sub(1, #HOME + 1) == HOME .. "/"
end

local function valid_pkg(p)
	return p ~= ""
		and p ~= "."
		and p ~= ".."
		and p:sub(1, 1) ~= "."
		and not p:find("[/\\%z]")
end

-- Reads the sync context: marked files if any, otherwise the hovered one.
local read_targets = ya.sync(function(state)
	local out = {}
	local function push(file)
		out[#out + 1] = {
			url = tostring(file.url),
			name = file.name,
			link = file.cha.is_link,
			dir = file.cha.is_dir,
		}
	end

	local selected = cx.active.selected
	if #selected > 0 then
		for _, f in pairs(selected) do
			push(f)
		end
	elseif cx.active.current.hovered then
		push(cx.active.current.hovered)
	end
	return out, state.dotfiles or "~/dotfiles", state.flags or {}
end)

local set_last_pkg = ya.sync(function(state, pkg)
	state.last_pkg = pkg
end)

local get_last_pkg = ya.sync(function(state)
	return state.last_pkg or ""
end)

-- Rename, falling back to copy+remove across file systems.
local function move(src, dest)
	local ok, err = fs.rename(Url(src), Url(dest))
	if ok then
		return true
	end
	if err and err.kind == "CrossesDevices" then
		local _, cerr = fs.copy(Url(src), Url(dest))
		if cerr then
			return false, cerr
		end
		local rok, rerr = fs.remove("file", Url(src))
		if not rok then
			return false, rerr
		end
		return true
	end
	return false, err
end

-- Restore the moved files, then drop the package tree if we created it.
local function rollback(moved, dotfiles, pkg, pkg_existed)
	for i = #moved, 1, -1 do
		local ok, err = move(moved[i].dest, moved[i].src)
		if not ok then
			ya.err("stowr: rollback failed for " .. moved[i].dest .. ": " .. tostring(err))
		end
	end
	if not pkg_existed then
		fs.remove("dir_clean", Url(dotfiles .. "/" .. pkg))
	end
end

local function guess_pkg(last_pkg, first)
	if HOME then
		local seg = first:match("^" .. HOME:gsub("%W", "%%%0") .. "/%.config/([^/]+)/")
		if seg then
			return seg
		end
	end
	local parent = first:match("^(.*)/[^/]+$")
	if parent then
		return parent:match("([^/]+)$") or last_pkg
	end
	return last_pkg
end

return {
	setup = function(state, opts)
		opts = opts or {}
		state.dotfiles = opts.dotfiles or "~/dotfiles"
		state.flags = opts.flags or {}
		state.last_pkg = opts.last_pkg or ""
	end,

	entry = function()
		local targets, dotfiles_raw, flags = read_targets()

		if #targets == 0 then
			return ya.notify { title = "Stow", content = "No file hovered or marked", level = "warn", timeout = 5 }
		end

		for _, t in ipairs(targets) do
			local why
			if t.link then
				why = t.name .. " is already a symlink (already stowed?)"
			elseif t.dir then
				why = t.name .. " is a directory"
			elseif not is_under_home(t.url) then
				why = t.name .. " is outside $HOME"
			end
			if why then
				return ya.notify { title = "Stow", content = why, level = "warn", timeout = 6 }
			end
		end

		local body
		if #targets == 1 then
			body = "Do you want to stow this file: " .. targets[1].name .. "?"
		else
			body = "Do you want to stow these " .. #targets .. " files?"
			for i, t in ipairs(targets) do
				if i > 10 then
					body = body .. "\n…"
					break
				end
				body = body .. "\n" .. t.name
			end
		end
		local ok = ya.confirm { pos = { "center", w = 60, h = 14 }, title = "Stow", body = body }
		if not ok then
			return
		end

		local dotfiles = expand(dotfiles_raw)
		local value, event = ya.input {
			pos = { "top-center", y = 2, w = 50 },
			title = "Stow package (folder) name:",
			value = guess_pkg(get_last_pkg(), targets[1].url),
		}
		if event ~= 1 or not value then
			return
		end
		local pkg = value:gsub("^%s+", ""):gsub("%s+$", "")
		if not valid_pkg(pkg) then
			return ya.notify { title = "Stow", content = "Invalid package name: " .. value, level = "error", timeout = 6 }
		end

		local plan = {}
		for _, t in ipairs(targets) do
			plan[#plan + 1] = {
				src = t.url,
				name = t.name,
				dest = dotfiles .. "/" .. pkg .. "/" .. t.url:sub(#HOME + 2),
			}
		end

		local conflicts = {}
		for _, p in ipairs(plan) do
			if fs.cha(Url(p.dest)) then
				conflicts[#conflicts + 1] = p
			end
		end
		if #conflicts > 0 then
			local cbody
			if #conflicts == 1 then
				cbody = "This file already exists in the dotfiles package:\n\n" .. conflicts[1].dest .. "\n\nOverwrite it?"
			else
				cbody = #conflicts .. " files already exist in the dotfiles package. Overwrite them?"
			end
			if not ya.confirm { pos = { "center", w = 70, h = 12 }, title = "Stow — overwrite", body = cbody } then
				return
			end
		end

		local pkg_dir = dotfiles .. "/" .. pkg
		local pkg_existed = fs.cha(Url(pkg_dir)) ~= nil

		for _, p in ipairs(plan) do
			local created, cerr = fs.create("dir_all", Url(dirname(p.dest)))
			if not created then
				rollback({}, dotfiles, pkg, pkg_existed)
				return ya.notify { title = "Stow", content = "Failed to create " .. dirname(p.dest) .. ": " .. tostring(cerr), level = "error", timeout = 8 }
			end
		end

		local moved = {}
		for _, p in ipairs(plan) do
			local ok2, merr = move(p.src, p.dest)
			if not ok2 then
				rollback(moved, dotfiles, pkg, pkg_existed)
				return ya.notify { title = "Stow", content = "Failed to move " .. p.name .. ": " .. tostring(merr), level = "error", timeout = 8 }
			end
			moved[#moved + 1] = p
		end

		local args = { "-t", HOME, pkg }
		for _, f in ipairs(flags) do
			args[#args + 1] = f
		end

		local output, err = Command("stow"):cwd(dotfiles):arg(args):output()
		if not output or err or not output.status.success then
			rollback(moved, dotfiles, pkg, pkg_existed)
			local detail = err and tostring(err)
				or (output.stderr ~= "" and output.stderr or ("stow exited with code " .. tostring(output.status.code)))
			return ya.notify {
				title = "Stow failed — rolled back",
				content = detail .. "\nRestored " .. #moved .. " file(s).",
				level = "error",
				timeout = 10,
			}
		end

		set_last_pkg(pkg)
		ya.emit("escape", { select = true })
		ya.emit("refresh", {})

		local summary = plan[1].dest
		if #plan > 1 then
			summary = summary .. " (+" .. (#plan - 1) .. " more)"
		end
		ya.notify { title = "Stowed " .. pkg, content = summary, timeout = 6 }
	end,
}

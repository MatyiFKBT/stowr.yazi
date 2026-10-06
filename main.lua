--- @since 26.9.1

-- stowr: move the hovered (or marked) files/directories into a GNU Stow package
-- inside your dotfiles repo, then run `stow` so the symlink is created back in place.

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

-- Remove a file, symlink or directory, whichever the path is.
local function remove_path(url)
	local cha = fs.cha(Url(url))
	if not cha then
		return true
	end
	return fs.remove(cha.is_dir and "dir_all" or "file", Url(url))
end

-- Rename, falling back to copy+remove across file systems. `fs.copy` only
-- handles single files, so directories go through `cp -a`.
local function move(src, dest, is_dir)
	local ok, err = fs.rename(Url(src), Url(dest))
	if ok then
		return true
	end
	if not (err and err.kind == "CrossesDevices") then
		return false, err
	end

	if not is_dir then
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

	local output, cerr = Command("cp"):arg { "-a", "--", src, dest }:output()
	if not output or cerr or not output.status.success then
		return false, cerr or output.stderr or ("cp exited with code " .. tostring(output.status.code))
	end
	local rm, rerr = Command("rm"):arg { "-rf", "--", src }:output()
	if not rm or rerr or not rm.status.success then
		return false, rerr or rm.stderr or ("rm exited with code " .. tostring(rm.status.code))
	end
	return true
end

-- Put `p.src` at `p.dest`. When the destination already exists, the old content
-- is swapped out through a temp name in the same directory, so `stow` never sees
-- anything but the final tree and at every instant either the old or the new
-- content is in place. Returns (ok, err, partial): `partial` is the path that may
-- hold a half-written copy, if any.
local function place(p)
	if not p.conflict then
		local ok, err = move(p.src, p.dest, p.is_dir)
		return ok, err, p.dest
	end

	local tmp = p.dest .. ".stowr-new"
	remove_path(tmp)

	local ok, err = move(p.src, tmp, p.is_dir)
	if not ok then
		return false, err, tmp
	end

	local removed, rerr = remove_path(p.dest)
	if not removed then
		move(tmp, p.src, p.is_dir)
		return false, rerr
	end

	local ok2, err2 = fs.rename(Url(tmp), Url(p.dest))
	if not ok2 then
		return false, err2, tmp
	end
	return true
end

-- Undo: move items back, drop a half-written copy, then drop a package tree we created.
local function undo(moved, partial, dotfiles, pkg, pkg_existed)
	for i = #moved, 1, -1 do
		local m = moved[i]
		local ok, err = move(m.dest, m.src, m.is_dir)
		if not ok then
			ya.err("stowr: rollback failed for " .. m.dest .. ": " .. tostring(err))
		end
	end
	if partial then
		remove_path(partial)
	end
	if not pkg_existed then
		fs.remove("dir_clean", Url(dotfiles .. "/" .. pkg))
	end
end

-- Best-effort package name: the first path segment under $HOME (skipping a
-- leading `.config`), minus a leading dot and a trailing extension.
local function guess_pkg(last_pkg, first)
	if not HOME or not is_under_home(first) then
		return last_pkg
	end
	local rel = first:sub(#HOME + 2)
	local seg = rel:match("^([^/]+)")
	if seg == ".config" then
		seg = rel:match("^%.config/([^/]+)") or seg
	end
	local name = seg:gsub("^%.", ""):gsub("%.[^.]*$", "")
	return name ~= "" and name or last_pkg
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
			elseif not is_under_home(t.url) then
				why = t.name .. " is outside $HOME"
			end
			if why then
				return ya.notify { title = "Stow", content = why, level = "warn", timeout = 6 }
			end
		end

		local body
		if #targets == 1 then
			body = "Do you want to stow this " .. (targets[1].dir and "folder" or "file") .. ": " .. targets[1].name .. "?"
		else
			body = "Do you want to stow these " .. #targets .. " items?"
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
				is_dir = t.dir,
				dest = dotfiles .. "/" .. pkg .. "/" .. t.url:sub(#HOME + 2),
			}
		end

		local conflicts, first_conflict = 0, nil
		for _, p in ipairs(plan) do
			if fs.cha(Url(p.dest)) then
				p.conflict = true
				conflicts = conflicts + 1
				first_conflict = first_conflict or p.dest
			end
		end
		if conflicts > 0 then
			local cbody
			if conflicts == 1 then
				cbody = "This path already exists in the dotfiles package:\n\n" .. first_conflict .. "\n\nOverwrite it?"
			else
				cbody = conflicts .. " paths already exist in the dotfiles package. Overwrite them?"
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
				undo({}, {}, nil, dotfiles, pkg, pkg_existed)
				return ya.notify { title = "Stow", content = "Failed to create " .. dirname(p.dest) .. ": " .. tostring(cerr), level = "error", timeout = 8 }
			end
		end

		local moved = {}
		for _, p in ipairs(plan) do
			local ok2, merr, partial = place(p)
			if not ok2 then
				undo(moved, partial, dotfiles, pkg, pkg_existed)
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
			undo(moved, nil, dotfiles, pkg, pkg_existed)
			local detail = err and tostring(err)
				or (output.stderr ~= "" and output.stderr or ("stow exited with code " .. tostring(output.status.code)))
			return ya.notify {
				title = "Stow failed — rolled back",
				content = detail .. "\nRestored " .. #moved .. " item(s).",
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

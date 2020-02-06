-- list of shadowmuted players.
-- written to disk whenever modified with the chat commands below.
-- player is *not* shadowmuted if the key for a player's name doesn't exist;
-- if it does, it's value is the shadowmute reason.
-- currently backed by a table and written to disk upon modification.
-- table format (in lua representation):
--[[
{
	version = 1,
	entries = {
		-- if a player has an entry, they are considered muted.
		-- this includes if no reason was specified.
		["player1"] = {
			reason = "some reason",	-- optional
			by = "admin1",	-- the user imposing the shadowmute
		}
	}
}
]]

local modname = minetest.get_current_modname()
local data

-- file format expected:
-- data from minetest.serialise producing a table as described above.
local wp = minetest.get_worldpath() .. "/"
local filename = "shadowmute_players.mt.txt"
local save =  wp .. filename
local sync = function()
	local s = minetest.serialize(data)
	return minetest.safe_file_write(save, s)
end


-- at load time...
-- first we must check the file even exists,
-- lest we get ENOENT when we try to open it for reading.
-- if it doesn't (new server), assume empty.
local list = minetest.get_dir_list(wp, false)
local found = false
for _, entry in ipairs(list) do
	print(entry)
	if entry == filename then
		found = true
		break
	end
end
if found then
	local f = assert(io.open(save))
	local s = f:read("*a")
	data = assert(minetest.deserialize(s))
	assert(data.version == 1, "unrecognised or missing version key in shadowmute data (expected 1)")
else
	-- otherwise we start with an empty table.
	data = {}
	data.version = 1
	data.entries = {}
	sync()
end




-- returns false if not forced and a previous reason would be overwritten,
-- along with the mute record (see entries in data table above).
-- otherwise returns true.
local muted = data.entries
local mute = function(user, target, reason, forced)

	-- allow for a "are you sure?" if a previous reason would be overwritten.
	local old_data = muted[target]
	if (not forced) and (old_data ~= nil) then
		return false, old_data
	end
	muted[target] = { reason=reason, by=user }
	sync()
	return true
end

-- returns old reason when unmuting, if any -
-- an already non-muted player returns nil.
-- will refuse if the invoking user is not the original muter,
-- unless the user has privileges to issue the forced version below
-- (see commands and privileges below).
-- returns true or false and the existing user record in either case.
local unmute = function(user, target, forced)
	local old = muted[target]
	if not old then
		-- user not previously muted
		return true, nil
	end
	local original_muter = old.by
	local success = false
	if (forced) or (user == original_muter) then
		muted[target] = nil
		sync()
		success = true
	end
	return success, old
end




local __send = minetest.chat_send_player
local send = function(n, m)
	local msg = "# " .. m
	return __send(n, msg)
end
-- command registration
minetest.register_privilege("shadowmute", {
	description = "Enables querying, setting and removing your own shadowmutes on a player."
})
minetest.register_privilege("shadowmute_override", {
	description = "Enables overriding shadowmute records even if you are not the original muting admin."
})
local blank = "(none)"
local usage = "No target user specified. (See help)"
local nope = "The specified player has never logged in, refusing. (Did you make a typo?)"
local common = function(force, usern, str)
	local args = str:split(" ", false, 1)
	local target = args[1]
	if not target then
		send(usern, usage)
		return
	end
	-- Doing it this way for now to avoid a combinatorial explosion of command variants.
	if not minetest.player_exists(target) then
		send(usern, nope)
		return
	end
	local reason = args[2] or blank
	local success, old_record = mute(usern, target, reason, force)
	if not success then
		send(usern,
			"Target user " .. target ..
			" was already shadow muted by " .. old_record.by ..
			" for the following reason: " .. old_record.reason)
		send(usern, "To override, use /shadowmute_force if you have privilege to do so.")
	else
		send(usern, "Succesfully shadow muted " .. target .. " with reason: " .. reason)
	end
end

local common_undo = function(force, usern, str)
	-- no extra reason argument neaded here.
	local target = str
	if #target == 0 then
		send(usern, usage)
		return
	end
	if not minetest.player_exists(target) then
		send(usern, nope)
		return
	end
	local success, current = unmute(usern, target, force)
	if not success then
		send(usern, 
			"Target user " .. target ..
			" was previously shadow muted by " .. current.by ..
			" for the following reason: " .. current.reason)
		send(usern, "To force unmute, use /shadowunmute_force if you have privilege to do so.")
	else
		if current then
			send(usern,
				"Successfully unmuted " .. target ..
				". Was previous muted by " .. current.by ..
				" with reason: " .. current.reason)
		else
			send(usern,
				"Player " .. target ..
				" was not previously shadow muted.")
		end
	end
end

minetest.register_chatcommand("shadowmute", {
	params = "<name> [mute reason]",
	description = "Shadow mute a player with an optional reason (defaults to \"" .. blank .. "\")",
	privs = {shadowmute = true},
	func = function(...)
		return common(false, ...)
	end
})
minetest.register_chatcommand("shadowmute_force", {
	params = "<name> [mute reason]",
	description = "See /shadowmute, but forces overwrite of a previous mute reason. Please use carefully.",
	privs = {shadowmute = true, shadowmute_override = true},
	func = function(...)
		return common(true, ...)
	end
})
minetest.register_chatcommand("shadowunmute", {
	params = "<name>",
	description = "Unmute a player that you previously shadow muted yourself.",
	privs = {shadowmute = true},
	func = function(...)
		return common_undo(false, ...)
	end
})
minetest.register_chatcommand("shadowunmute_force", {
	params = "<name>",
	description = "See /shadowunmute, but forces unmute even if previously muted by someone else. Please use carefully.",
	privs = {shadowmute = true, shadowmute_override = true},
	func = function(...)
		return common_undo(true, ...)
	end
})








-- misc query code
local find = string.find
local search = function(user, str)
	local count = 0
	local found = {}

	for name, details in pairs(muted) do
		-- note we need pcall because there's not currently a way to pre-compile a pattern,
		-- so we have to catch errors on the fly.
		local success, result = pcall(find, name, str)
		if not success then
			send(user, "String matching error occurred during search: " .. result)
			return
		end
		if result then
			count = count + 1
			found[count] = name
		end
	end

	table.sort(found)
	local has_pat = (#str > 0)
	local pat = has_pat and " matching " .. minetest.colorize("#00FFFF", str) or ""
	send(user,
		"Found usernames" .. pat .. " with shadow mute records: " ..
		table.concat(found, " "))
	send(user, "For a total of " .. count .. " entries.")
end
minetest.register_chatcommand("shadowmute_find", {
	params = "<pattern>",
	description = "Queries for shadow muted players whose names match <pattern> as per lua's string.find().",
	privs = {shadowmute = true},
	func = search,
})







--[[
local fake_message = function(name, message)
	return "<" .. name .. "> " .. message
end
]]
local fake_message = function(...)
	return assert(minetest.format_chat_message(...))
end

local raw = minetest.chat_send_player
local callback = function(name, message)
	if muted[name] then
		minetest.log(
			"action",
			"shadow muted player " .. name .. " tried to speak: " .. message)
		raw(name, fake_message(name, message))
		return true
	end
end
-- bit of a hack here, but it is imperative that we are higher precedence than e.g. any chat relaying.
-- we assume we are the first mod to run (outside of game builtin) by using the 00_ prefix.
assert(modname == "00_shadowmute", "mod wasn't named correctly. (expected 00_shadowmute)")
local origins = minetest.callback_origins
local broken = "Mod outside of builtin has registered a chat handler before shadowmute, cannot be bulletproof."
for _, f in ipairs(minetest.registered_on_chat_messages) do
	assert(origins[f].mod == "*builtin*", broken)
end
minetest.register_on_chat_message(callback)



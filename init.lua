local http = minetest.request_http_api()
local settings = minetest.settings

local host = settings:get('discord.host') or 'localhost'
local port = settings:get('discord.port') or 8080
local escape_formatting = settings:get_bool('discord.escape_formatting') or false
local timeout = 10

discord = {}

-- Configuration
discord.text_colorization = settings:get('discord.text_color') or '#ffffff'

discord.send_server_startup = settings:get_bool('discord.send_server_startup', true)
discord.send_server_shutdown = settings:get_bool('discord.send_server_shutdown', true)

discord.include_server_status = settings:get_bool('discord.include_server_status', true)
discord.include_server_status_on_shutdown = settings:get_bool('discord.include_server_status_on_shutdown', true)


discord.startup_text = settings:get('discord.startup_text') or '*** Server started!'
discord.shutdown_text = settings:get('discord.shutdown_text') or '*** Server shutting down...'

discord.use_embeds_on_server_updates = settings:get_bool('discord.use_embeds_on_server_updates', true)

discord.startup_color = settings:get('discord.startup_color') or '#5865f2'
discord.shutdown_color = settings:get('discord.shutdown_color') or '#d9d9dc'

discord.registered_on_messages = {}

local irc_enabled = minetest.get_modpath("irc")

function discord.register_on_message(func)
    table.insert(discord.registered_on_messages, func)
end

discord.chat_send_all = minetest.chat_send_all

-- Allow the chat message format to be customised by other mods
function discord.format_chat_message(name, msg)
    return ('<%s@Discord> %s'):format(name, msg)
end

function discord.handle_response(response)
    local data = response.data
    if data == '' or data == nil then
        return
    end
    local data = minetest.parse_json(response.data)
    if not data then
        return
    end
    if data.messages then
        for _, message in pairs(data.messages) do
            for _, func in pairs(discord.registered_on_messages) do
                func(message.author, message.content)
            end
            local msg = discord.format_chat_message(message.author, message.content)
            discord.chat_send_all(minetest.colorize(discord.text_colorization, msg))
            if irc_enabled then
                irc.say(msg)
            end
            minetest.log('action', '[Discord] Message: '..msg)
        end
    end
    if data.commands then
        local commands = minetest.registered_chatcommands
        for _, v in pairs(data.commands) do
            if commands[v.command] then
                if minetest.get_ban_description(v.name) ~= '' then
                    discord.send('You cannot run commands because you are banned.', v.context or nil)
                    return
                end
                -- Check player privileges
                local required_privs = commands[v.command].privs or {}
                local player_privs = minetest.get_player_privs(v.name)
                for priv, value in pairs(required_privs) do
                    if player_privs[priv] ~= value then
                        discord.send('Insufficient privileges.', v.context or nil)
                        return
                    end
                end
                local old_chat_send_player = minetest.chat_send_player
                minetest.chat_send_player = function(name, message)
                    old_chat_send_player(name, message)
                    if name == v.name then
                        discord.send(message, v.context or nil)
                    end
                end
                local success, ret_val = commands[v.command].func(v.name, v.params or '')
                if ret_val then
                    discord.send(ret_val, v.context or nil)
                end
                minetest.chat_send_player = old_chat_send_player
            else
                discord.send(('Command not found: `%s`'):format(v.command), v.context or nil)
            end
        end
    end
    if data.logins then
        local auth = minetest.get_auth_handler()
        for _, v in pairs(data.logins) do
            local authdata = auth.get_auth(v.username)
            local result = false
            if authdata then
                result = minetest.check_password_entry(v.username, authdata.password, v.password)
            end
            local request = {
                type = 'DISCORD_LOGIN_RESULT',
                user_id = v.user_id,
                username = v.username,
                success = result
            }
            http.fetch({
                url = tostring(host)..':'..tostring(port),
                timeout = timeout,
                post_data = minetest.write_json(request)
            }, discord.handle_response)
        end
    end
end

function discord.send(message, id, embed_color, embed_description)
    local content
    if escape_formatting then
        content = minetest.strip_colors(message):gsub("\\", "\\\\"):gsub("%*", "\\*"):gsub("_", "\\_"):gsub("^#", "\\#")
    else
        content = minetest.strip_colors(message)
    end
    local data = {
        type = 'DISCORD-RELAY-MESSAGE',
        content = content
    }
    if id then
        data['context'] = id
    end
    data['embed_color'] = embed_color
    data['embed_description'] = embed_description
    http.fetch_async({
        url = tostring(host)..':'..tostring(port),
        timeout = timeout,
        post_data = minetest.write_json(data)
    })
end

function minetest.chat_send_all(message)
    discord.chat_send_all(message)
    discord.send(message)
end

-- Register the chat message callback after other mods load so that anything
-- that overrides chat will work correctly
minetest.after(0, minetest.register_on_chat_message, function(name, message)
    discord.send(minetest.format_chat_message(name, message))
end)

local timer = 0
local ongoing = nil
minetest.register_globalstep(function(dtime)
    if dtime then
        timer = timer + dtime
        if timer > 0.2 then
            if not ongoing then
                ongoing = http.fetch_async({
                    url = tostring(host)..':'..tostring(port),
                    timeout = timeout,
                    post_data = minetest.write_json({
                        type = 'DISCORD-REQUEST-DATA'
                    })
                })
            else
                local res = http.fetch_async_get(ongoing)

                if res.completed == true then
                    discord.handle_response(res)
                    ongoing = http.fetch_async({
                        url = tostring(host)..':'..tostring(port),
                        timeout = timeout,
                        post_data = minetest.write_json({
                            type = 'DISCORD-REQUEST-DATA'
                        })
                    })
                end
            end

            timer = 0
        end
    end
end)

minetest.register_on_shutdown(function()
    if discord.send_server_shutdown then
        if discord.use_embeds_on_server_updates then
            discord.send(discord.shutdown_text, nil, discord.shutdown_color,
                (discord.include_server_status_on_shutdown and minetest.get_server_status():gsub("^#", "\\#") or nil))
        else
            discord.send(discord.shutdown_text ..
                (discord.include_server_status_on_shutdown and " - " .. minetest.get_server_status() or ""))
        end
    end
end)

if irc_enabled then
    discord.old_irc_sendLocal = irc.sendLocal
    function irc.sendLocal(msg)
        discord.old_irc_sendLocal(msg)
        discord.send(msg)
    end
end

if discord.send_server_startup then
    if discord.use_embeds_on_server_updates then
        discord.send(discord.startup_text, nil, discord.startup_color,
            (discord.include_server_status and minetest.get_server_status():gsub("^#", "\\#") or nil))
        -- core.log('error', minetest.get_server_status())
    else
        discord.send(discord.startup_text ..
            (discord.include_server_status and " - " .. minetest.get_server_status() or ""))
    end
end

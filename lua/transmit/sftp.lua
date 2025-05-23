local ffi = require('ffi')

local function get_current_lua_file_directory()
  local info = debug.getinfo(1, 'S')
  if info and info.source then
    return vim.fn.fnamemodify(info.source, ':h')
  end
  return nil
end

local plugin_root = get_current_lua_file_directory()
if not plugin_root then
  vim.api.nvim_err_writeln("Error: Could not determine plugin directory.")
  return
end

local lib_path = plugin_root .. '/../../' .. 'libtransmit.so'
-- local sftp_lib, err = ffi.load(lib_path)
local sftp_lib, err = ffi.load('/home/declanb/.local/share/nvim/lazy/transmit2/libtransmit.so') -- Adjust the actual path

if not sftp_lib then
  vim.api.nvim_err_writeln("Error loading SFTP library: " .. err)
  return
end

-- Define the C functions we need
ffi.cdef[[
    typedef struct LIBSSH2_SFTP LIBSSH2_SFTP;
    typedef struct LIBSSH2_SESSION LIBSSH2_SESSION;

    int init_sftp_session(const char *hostname, const char *username, const char *privkey_path, LIBSSH2_SFTP **sftp_session, LIBSSH2_SESSION **session, int *sock);
    int upload_file(LIBSSH2_SFTP *sftp_session, const char *local_file, const char *remote_file);
    int create_directory(LIBSSH2_SFTP *sftp_session, const char *directory);
    void close_sftp_session(LIBSSH2_SFTP *sftp_session, LIBSSH2_SESSION *session, int sock);
	int sftp_remove_path_recursive(LIBSSH2_SFTP *sftp_session, const char *path, char **err_msg);
]]

local sftp_session = ffi.new("LIBSSH2_SFTP *[1]")
local session = ffi.new("LIBSSH2_SESSION *[1]")
local sock = ffi.new("int[1]")

local data_path = vim.fn.stdpath("data")
local Path = require("plenary.path")
local Job = require('plenary.job')

local sftp = {}

local queue = {}

sftp.server_config = {}

local transmit_server_data = string.format("%s/transmit.json", data_path)

sftp.has_active_queue = function()
	return next(queue) ~= nil
end

local function get_current_queue_item()
    local iter = pairs(queue)

    local current_key, _ = iter(queue)

    if queue[current_key] == nil then
        return false
    end

    return queue[current_key]
end

local function get_transmit_data()
    local path = Path:new(transmit_server_data)
    local exists = path:exists()

    if not exists then
        path:write('{}', 'w')
    end

    local transmit_data = path:read()

    return vim.json.decode(transmit_data)
end

local function get_selected_server()
    local current_transmit_data = get_transmit_data()
    local working_dir = vim.loop.cwd()

    if current_transmit_data[working_dir] == nil or current_transmit_data[working_dir]['server_name'] == nil or current_transmit_data[working_dir] == nil then
        return false
    end

    return current_transmit_data[working_dir]['server_name']
end

function sftp.parse_sftp_config(config_location)
    local path = Path:new(config_location)
    local exists = path:exists()

    if not exists then
        return false
    end

    local sftp_config_data = path:read()

    sftp.server_config = vim.json.decode(sftp_config_data)
end

function sftp.get_sftp_server_config()
    local selected_server = get_selected_server()

    if selected_server == false then
        return false
    end

    return sftp.server_config[selected_server]
end

function sftp.update_transmit_server_config(server_name, remote)
    local working_dir = vim.loop.cwd()
    local current_transmit_data = get_transmit_data()

    if server_name == 'none' then
        current_transmit_data[working_dir] = nil
    elseif current_transmit_data[working_dir] == nil then
        current_transmit_data[working_dir] = {}
        current_transmit_data[working_dir]["server_name"] = server_name
        current_transmit_data[working_dir]["remote"] = remote
    else
        current_transmit_data[working_dir]["server_name"] = server_name
        current_transmit_data[working_dir]["remote"] = remote
    end

    Path:new(transmit_server_data):write(vim.json.encode(current_transmit_data), "w")
end

local function escapePattern(str)
    local specialCharacters = "([%.%+%-%%%[%]%*%?%^%$%(%)])"
    return (str:gsub(specialCharacters, "%%%1"))
end

local function process_next_queue_item()
    local current_queue_item = get_current_queue_item()

    if current_queue_item == nil or current_queue_item == false then
        queue = {}

		sftp_lib.close_sftp_session(sftp_session[0], session[0], sock[0])

        return false
    end

	local current_config = sftp.get_sftp_server_config()
	local current_transmit_data = get_transmit_data()

	local working_dir = current_queue_item.working_dir
	local file = current_queue_item.filename

	local relative_path =  string.gsub(file, escapePattern(working_dir), '')

	local selected_remote = current_transmit_data[working_dir]['remote']
	local remote_path = current_config['remotes'][selected_remote]

	local function remove_item_from_queue()
		local iter = pairs(queue)
		local current_key, _ = iter(queue)
		queue[current_key] = nil
	end

	local async = vim.loop.new_async(vim.schedule_wrap(function()
		if current_queue_item.type == "upload" then
			sftp_lib.upload_file(sftp_session[0], file, remote_path .. relative_path);
		end

		if current_queue_item.type == "remove" then
			local err_ptr = ffi.new("char *[1]")
			if sftp_lib.sftp_remove_path_recursive(sftp_session[0], remote_path .. relative_path, err_ptr) ~= 0 then
				vim.print(ffi.string(err_ptr[0]));
			end
		end

		remove_item_from_queue()
	end))

	vim.defer_fn(function()
		async:send()
	end, 0)
end

function sftp.add_to_queue(type, filename, working_dir)
	    local start_queue = false

    if sftp.has_active_queue() == false and type ~= "connect" then
        local connect_processes = sftp.generate_connect_proceses(working_dir)
        sftp.add_to_queue("connect", "", "", connect_processes)

        start_queue = true
    end

    table.insert(queue, {
        type = type,
        filename = filename,
        working_dir = working_dir,
        processes = processes
    })

    if start_queue then
        sftp.start_connection()
    end
end

function sftp.working_dir_has_active_sftp_selection(working_dir)
    local current_transmit_data = get_transmit_data()

    if current_transmit_data[working_dir] == nil or current_transmit_data[working_dir]['remote'] == nil then
        return false
    end

    return true
end


function sftp.start_connection()
    local config = sftp.get_sftp_server_config()

    local host = config.credentials.host
    local username = config.credentials.username
    local identity_file = config.credentials.identity_file

    local uv = vim.loop

    local stdin = uv.new_pipe(false)
    local stdout = uv.new_pipe(false)
    local stderr = uv.new_pipe(false)

	sftp_lib.init_sftp_session(host, username, identity_file, sftp_session, session, sock)

	return vim.fn.jobstart(
		{
		}
	)

    -- return vim.fn.jobstart(
    --     {
    --     "lftp",
    --     "sftp://" .. username .. "@" .. host,
    --     "-u", username .. ",",
    --     "-e", "set sftp:connect-program \"ssh -i " .. identity_file .. "\"",
    --     },
    --     {
    --         pty = true,
    --         on_stdout = on_sftp_event,
    --         on_stderr = on_sftp_event,
    --         on_exit = on_sftp_event,
    --     }
    -- )
end

function sftp.get_current_remote(working_dir)
    if sftp.working_dir_has_active_sftp_selection(working_dir) == false then
        return 'none'
    end

    local current_transmit_data = get_transmit_data()
    return current_transmit_data[working_dir]["remote"]
end

function sftp.get_current_server(working_dir)
    if sftp.working_dir_has_active_sftp_selection(working_dir) == false then
        return 'none'
    end

    local current_transmit_data = get_transmit_data()
    return current_transmit_data[working_dir]["server_name"]
end

return sftp

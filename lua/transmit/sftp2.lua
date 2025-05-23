local data_path = vim.fn.stdpath("data")
local Path = require("plenary.path")

local sftp = {}
local queue = {}
local transmit_job = nil
local transmit_phase = "init"
local auth_step = 0

sftp.server_config = {}

local transmit_server_data = string.format("%s/transmit.json", data_path)

local function get_transmit_path()
    local info = debug.getinfo(1, "S")
    local dir = info.source:match("@?(.*[/\\])")
    if not dir then
        dir = vim.loop.cwd() .. "/"
    end

    -- Remove trailing slash if any
    dir = dir:gsub("[/\\]$", "")

    -- Go two directories up
    local parent_dir = dir:match("^(.*)[/\\][^/\\]+[/\\][^/\\]+$")

    return parent_dir .. "/transmit"
end

local function get_current_queue_item()
  for _, item in pairs(queue) do
    return item
  end
  return nil
end

local function remove_item_from_queue()
  for k in pairs(queue) do
    queue[k] = nil
    break
  end
end

local function escapePattern(str)
  return (str:gsub("([%%%.%+%-%*%?%[%]%^%$%(%)])", "%%%1"))
end

local function get_transmit_data()
  local path = Path:new(transmit_server_data)
  if not path:exists() then path:write('{}', 'w') end
  return vim.json.decode(path:read())
end

local function get_selected_server()
  local data = get_transmit_data()
  local cwd = vim.loop.cwd()
  if data[cwd] and data[cwd].server_name then
    return data[cwd].server_name
  end
  return nil
end

function sftp.parse_sftp_config(config_location)
  local path = Path:new(config_location)
  if not path:exists() then return false end
  sftp.server_config = vim.json.decode(path:read())
end

function sftp.get_sftp_server_config()
  local server = get_selected_server()
  if not server then return nil end
  return sftp.server_config[server]
end

function sftp.update_transmit_server_config(server_name, remote)
  local cwd = vim.loop.cwd()
  local data = get_transmit_data()
  data[cwd] = data[cwd] or {}
  if server_name == 'none' then
    data[cwd] = nil
  else
    data[cwd].server_name = server_name
    data[cwd].remote = remote
  end
  Path:new(transmit_server_data):write(vim.json.encode(data), 'w')
end

function sftp.working_dir_has_active_sftp_selection(working_dir)
  local data = get_transmit_data()
  return data[working_dir] and data[working_dir].remote
end

function sftp.process_next()
  local item = get_current_queue_item()
  if not item then
    if transmit_job then
      vim.fn.chansend(transmit_job, "exit\n")
      transmit_job = nil
      transmit_phase = "init"
      auth_step = 0
    end
    return
  end

  local config = sftp.get_sftp_server_config()
  local data = get_transmit_data()
  local cwd = item.working_dir
  local file = item.filename
  local relative = file:gsub(escapePattern(cwd), "")
  local remote_base = config.remotes[data[cwd].remote]
  local remote_path = remote_base .. relative

  local cmd = nil
  if item.type == "upload" then
    cmd = string.format("upload %s %s\n", file, remote_path)
  elseif item.type == "remove" then
    cmd = string.format("remove %s\n", remote_path)
  end

  if cmd then
    vim.fn.chansend(transmit_job, cmd)
  end
  remove_item_from_queue()
end

function sftp.start_connection()
  local config = sftp.get_sftp_server_config()
  if not config then return end

  local transmit_executable = get_transmit_path()

  transmit_phase = "init"

  transmit_job = vim.fn.jobstart({ transmit_executable }, {
    stdout_buffered = false,
    stderr_buffered = false,
    pty = true,
    on_stdout = function(_, data)
		-- Open the log file in append mode
		local log_file_path = vim.fn.stdpath("cache") .. "/sftp_log.txt"
		local log_file = io.open(log_file_path, "a")
		local timestamp_format = "[%Y-%m-%d %H:%M:%S] " -- e.g. [2025-05-23 14:33:45] 

		for _, line in ipairs(data) do
			local timestamp = os.date(timestamp_format)
			log_file:write(timestamp .. line .. "\n")

			if transmit_phase == "init" and line:match("Enter SSH hostname") then
				vim.fn.chansend(transmit_job, config.credentials.host .. "\n")
				transmit_phase = "username"
			elseif transmit_phase == "username" and line:match("Enter SSH username") then
				vim.fn.chansend(transmit_job, config.credentials.username .. "\n")
				transmit_phase = "key"
			elseif transmit_phase == "key" and line:match("Enter path to private key") then
				vim.fn.chansend(transmit_job, config.credentials.identity_file .. "\n")
				transmit_phase = "ready"
			elseif transmit_phase == "ready" and line:match("Connected to") then
				transmit_phase = "active"
				sftp.process_next()
			elseif transmit_phase == "active" then
				if line:match("^1|Upload succeeded") or line:match("^1|Remove succeeded") or line:match("^0|") then
					sftp.process_next()
				end
			end
		end
    end,
  })
end

function sftp.add_to_queue(type, filename, working_dir)
  local start_queue = false
  if next(queue) == nil and type ~= "connect" then
    start_queue = true
  end

  table.insert(queue, {
    type = type,
    filename = filename,
    working_dir = working_dir,
  })

  if start_queue then
    sftp.start_connection()
  end
end

function sftp.get_current_remote(working_dir)
  local data = get_transmit_data()
  return data[working_dir] and data[working_dir].remote or 'none'
end

function sftp.get_current_server(working_dir)
  local data = get_transmit_data()
  return data[working_dir] and data[working_dir].server_name or 'none'
end

return sftp

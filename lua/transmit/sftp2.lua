-- Updated SFTP module with connection lock and 5-minute keepalive
local data_path = vim.fn.stdpath("data")
local Path = require("plenary.path")
local uv = vim.loop

local sftp = {}
local queue = {}
local transmit_job = nil
local transmit_phase = "init"
local auth_step = 0
local keepalive_timer = nil
local connecting = false
local connection_ready = false

local current_progress = {
  file = nil,
  percent = nil,
}

sftp.server_config = {}

local transmit_server_data = string.format("%s/transmit.json", data_path)

local function get_transmit_path()
  local info = debug.getinfo(1, "S")
  local dir = info.source:match("@?(.*[/\\])")
  if not dir then
    dir = vim.loop.cwd() .. "/"
  end
  dir = dir:gsub("[/\\]$", "")
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

local function reset_keepalive_timer()
  if keepalive_timer then
    keepalive_timer:stop()
    keepalive_timer:close()
  end
  keepalive_timer = uv.new_timer()
  keepalive_timer:start(5 * 60 * 1000, 0, function() -- keep alive for 5 minutes
    vim.schedule(function()
      if transmit_job then
        vim.fn.chansend(transmit_job, "exit\n")
        transmit_job = nil
        transmit_phase = "init"
        auth_step = 0
        connecting = false
        connection_ready = false
        vim.notify("SFTP connection closed after 5 seconds of inactivity", vim.log.levels.INFO)
      end
      if keepalive_timer then
        keepalive_timer:stop()
        keepalive_timer:close()
        keepalive_timer = nil
      end
    end)
  end)
end

function sftp.ensure_connection(callback)
  if transmit_job and connection_ready then
    if callback then callback() end
    reset_keepalive_timer()
    return
  end
  if connecting then return end
  connecting = true

  local config = sftp.get_sftp_server_config()
  if not config then
    connecting = false
    return
  end

  local transmit_executable = get_transmit_path()
  transmit_phase = "init"

  transmit_job = vim.fn.jobstart({ transmit_executable }, {
    stdout_buffered = false,
    stderr_buffered = false,
    pty = true,
    on_stdout = function(_, data)
      local log_file_path = vim.fn.stdpath("cache") .. "/sftp_log.txt"
      local log_file = io.open(log_file_path, "a")
      local stat = vim.loop.fs_stat(log_file_path)
      if stat and stat.size > 50 * 1024 * 1024 then
        local clear_file = io.open(log_file_path, "w")
        if clear_file then
          clear_file:close()
          vim.notify("Transmit Log file exceeded 50MB. It has been cleared.", vim.log.levels.WARN)
        end
      end
      local timestamp_format = "[%Y-%m-%d %H:%M:%S] "
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
          connecting = false
          connection_ready = true
          if callback then callback() end
          sftp.process_next()

        elseif transmit_phase == "active" then
			if line:match("^PROGRESS|") then
				local file, percent = line:match("^PROGRESS|(.-)|(%d+)")
				percent = tonumber(percent)
				if file and percent then
					current_progress.file = Path:new(file):make_relative()
					current_progress.percent = percent
				end
			elseif line:match("^1|Upload succeeded") or line:match("^1|Remove succeeded") or line:match("^0|") then
				reset_keepalive_timer()
				sftp.process_next()
				remove_item_from_queue()
			end
        end
      end
    end,

	on_exit = function(_, exit_code, _)
		connection_ready = false
		transmit_job = nil
		connecting = false
		vim.notify("SFTP connection lost (exit code " .. exit_code .. "). Reconnecting...", vim.log.levels.WARN)
		sftp.ensure_connection(function()
			sftp.process_next()
		end)	
	end,
  })
end

function sftp.process_next()
  local item = get_current_queue_item()
  if not item then
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
end

function sftp.add_to_queue(type, filename, working_dir)
  table.insert(queue, {
    type = type,
    filename = filename,
    working_dir = working_dir,
  })

  sftp.ensure_connection(function()
    sftp.process_next()
  end)
end

function sftp.get_current_remote(working_dir)
  local data = get_transmit_data()
  return data[working_dir] and data[working_dir].remote or 'none'
end

function sftp.get_current_server(working_dir)
  local data = get_transmit_data()
  return data[working_dir] and data[working_dir].server_name or 'none'
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

function sftp.get_progress()
  return current_progress
end

return sftp

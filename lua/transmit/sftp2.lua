-- SFTP module with connection management and file transfer queue
local data_path = vim.fn.stdpath("data")
local Path = require("plenary.path")
local uv = vim.loop

-- Constants for phase names
local PHASE = {
  INIT = "init",
  USERNAME = "username",
  KEY = "key",
  READY = "ready",
  ACTIVE = "active",
}

local OPERATION_TYPE = {
  UPLOAD = "upload",
  REMOVE = "remove",
}

local LOG_LEVELS = {
  DEBUG = 1,
  INFO = 2,
  WARN = 3,
  ERROR = 4,
}

-- Configuration
local config = {
  keepalive_timeout = 5 * 60 * 1000, -- 5 minutes
  auth_timeout = 30 * 1000, -- 30 seconds
  log_rotation_size = 50 * 1024 * 1024, -- 50MB
  log_check_interval = 100, -- Check log size every 100 writes
  log_level = LOG_LEVELS.INFO, -- Default log level
}

---@class QueueItem
---@field type "upload"|"remove"
---@field filename string
---@field working_dir string
---@field processing boolean
---@field id number

---@class ProgressInfo
---@field file string|nil
---@field percent number|nil

---@class ServerCredentials
---@field host string
---@field username string
---@field identity_file string

---@class ServerConfig
---@field credentials ServerCredentials
---@field remotes table<string, string>

---@class TransmitData
---@field [string] {server_name: string, remote: string}

---@class SFTPState
---@field server_config table<string, ServerConfig>
---@field queue QueueItem[]
---@field transmit_job number|nil
---@field transmit_phase string
---@field keepalive_timer uv_timer_t|nil
---@field auth_timeout_timer uv_timer_t|nil
---@field connecting boolean
---@field connection_ready boolean
---@field is_exiting boolean
---@field log_check_counter number
---@field current_progress ProgressInfo
---@field next_queue_id number
local state = {
  server_config = {},
  queue = {},
  transmit_job = nil,
  transmit_phase = PHASE.INIT,
  keepalive_timer = nil,
  auth_timeout_timer = nil,
  connecting = false,
  connection_ready = false,
  is_exiting = false,
  log_check_counter = 0,
  current_progress = {
    file = nil,
    percent = nil,
  },
  next_queue_id = 1,
}

---@class SFTP
---@field server_config table<string, ServerConfig>
local sftp = {}

sftp.server_config = state.server_config

local transmit_server_data = string.format("%s/transmit.json", data_path)

---Log message with level filtering
---@param level number Log level
---@param message string Message to log
---@param notify boolean|nil Whether to also show vim notification
local function log(level, message, notify)
  if level < config.log_level then
    return
  end
  
  local log_file_path = vim.fn.stdpath("cache") .. "/sftp_debug.txt"
  local log_file = io.open(log_file_path, "a")
  
  if log_file then
    local level_names = {"DEBUG", "INFO", "WARN", "ERROR"}
    local timestamp = os.date("[%Y-%m-%d %H:%M:%S]")
    log_file:write(string.format("%s [%s] %s\n", timestamp, level_names[level] or "UNKNOWN", message))
    log_file:close()
  end
  
  if notify then
    local vim_levels = {
      [LOG_LEVELS.DEBUG] = vim.log.levels.DEBUG,
      [LOG_LEVELS.INFO] = vim.log.levels.INFO,
      [LOG_LEVELS.WARN] = vim.log.levels.WARN,
      [LOG_LEVELS.ERROR] = vim.log.levels.ERROR,
    }
    vim.notify(message, vim_levels[level] or vim.log.levels.INFO)
  end
end

---Cleanup all timers and state
local function cleanup_state()
  if state.keepalive_timer then
    state.keepalive_timer:stop()
    state.keepalive_timer:close()
    state.keepalive_timer = nil
  end

  if state.auth_timeout_timer then
    state.auth_timeout_timer:stop()
    state.auth_timeout_timer:close()
    state.auth_timeout_timer = nil
  end

  if state.transmit_job then
    vim.fn.jobstop(state.transmit_job)
    state.transmit_job = nil
  end

  state.transmit_phase = PHASE.INIT
  state.connecting = false
  state.connection_ready = false
  
  state.server_config = {}
end

vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    state.is_exiting = true
    cleanup_state()
    state.queue = {}
  end
})

---Get the path to the transmit executable based on OS
---@return string|nil path Path to the transmit executable or nil on error
local function get_transmit_path()
  local info = debug.getinfo(1, "S")
  if not info or not info.source then
    log(LOG_LEVELS.ERROR, "Failed to get script info", true)
    return nil
  end
  
  local source = info.source:match("^@(.+)$")
  if not source then
    log(LOG_LEVELS.ERROR, "Failed to parse source path", true)
    return nil
  end
  
  local dir = vim.fn.fnamemodify(source, ":h")
  local parent_dir = vim.fn.fnamemodify(dir, ":h:h")
  
  -- Determine OS and select appropriate binary
  local binary_name
  if vim.fn.has("mac") == 1 or vim.fn.has("macunix") == 1 then
    binary_name = "transmit-macos"
  elseif vim.fn.has("unix") == 1 then
    binary_name = "transmit-linux"
  elseif vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
    binary_name = "transmit-windows.exe"
  else
    log(LOG_LEVELS.ERROR, "Unsupported operating system", true)
    return nil
  end
  
  -- Look in bin/ subdirectory
  local transmit_path = parent_dir .. "/bin/" .. binary_name
  
  -- Verify the executable exists
  if vim.fn.filereadable(transmit_path) ~= 1 then
    log(LOG_LEVELS.ERROR, "Transmit executable not found at: " .. transmit_path, true)
    return nil
  end
  
  -- Verify it's executable
  if vim.fn.executable(transmit_path) ~= 1 then
    log(LOG_LEVELS.WARN, "Transmit binary exists but is not executable, attempting to fix: " .. transmit_path, true)
    -- Try to make it executable
    vim.fn.system("chmod +x " .. vim.fn.shellescape(transmit_path))
    
    -- Check again
    if vim.fn.executable(transmit_path) ~= 1 then
      log(LOG_LEVELS.ERROR, "Failed to make transmit binary executable: " .. transmit_path, true)
      return nil
    end
  end
  
  return transmit_path
end

---Get the first item in the queue (O(1))
---@return QueueItem|nil item The current queue item or nil if queue is empty
local function get_current_queue_item()
  return state.queue[1]
end

---Remove the first item from the queue (O(n))
---@return nil
local function remove_item_from_queue()
  table.remove(state.queue, 1)
end

---Find a queue item by ID
---@param id number Queue item ID
---@return QueueItem|nil, number|nil item, index The queue item and its index, or nil
local function find_queue_item(id)
  for i, item in ipairs(state.queue) do
    if item.id == id then
      return item, i
    end
  end
  return nil, nil
end

---Escape special pattern characters in a string
---@param str string The string to escape
---@return string escaped The escaped string
local function escapePattern(str)
  return (str:gsub("([%%%.%+%-%*%?%[%]%^%$%(%)])", "%%%1"))
end

---Read transmit data from JSON file
---@return TransmitData|nil data The transmit configuration data or nil on error
local function get_transmit_data()
  local path = Path:new(transmit_server_data)
  if not path:exists() then 
    local success = pcall(function() path:write('{}', 'w') end)
    if not success then
      log(LOG_LEVELS.ERROR, "Failed to create transmit.json", true)
      return nil
    end
    return {}
  end
  
  local success, result = pcall(vim.json.decode, path:read())
  if not success then
    log(LOG_LEVELS.ERROR, "Failed to parse transmit.json: " .. tostring(result), true)
    return {}
  end
  
  return result
end

---Get the selected server name for the current working directory
---@return string|nil server_name The selected server name or nil
local function get_selected_server()
  local data = get_transmit_data()
  if not data then return nil end
  
  local cwd = vim.loop.cwd()
  if data[cwd] and data[cwd].server_name then
    return data[cwd].server_name
  end
  return nil
end

---Reset the keepalive timer
---@return nil
local function reset_keepalive_timer()
  if state.keepalive_timer then
    state.keepalive_timer:stop()
    state.keepalive_timer:close()
  end
  state.keepalive_timer = uv.new_timer()
  state.keepalive_timer:start(config.keepalive_timeout, 0, function()
    vim.schedule(function()
      if state.transmit_job then
        vim.fn.chansend(state.transmit_job, "exit\n")
        state.transmit_job = nil
        state.transmit_phase = PHASE.INIT
        state.connecting = false
        state.connection_ready = false
        log(LOG_LEVELS.INFO, "SFTP connection closed after inactivity timeout", true)
      end
      if state.keepalive_timer then
        state.keepalive_timer:stop()
        state.keepalive_timer:close()
        state.keepalive_timer = nil
      end
    end)
  end)
end

---Start authentication timeout timer
---@return nil
local function start_auth_timeout()
  if state.auth_timeout_timer then
    state.auth_timeout_timer:stop()
    state.auth_timeout_timer:close()
  end
  state.auth_timeout_timer = uv.new_timer()
  state.auth_timeout_timer:start(config.auth_timeout, 0, function()
    vim.schedule(function()
      if state.connecting and not state.connection_ready then
        log(LOG_LEVELS.ERROR, "SFTP authentication timed out", true)
        if state.transmit_job then
          vim.fn.jobstop(state.transmit_job)
          state.transmit_job = nil
        end
        state.transmit_phase = PHASE.INIT
        state.connecting = false
        state.connection_ready = false
      end
      if state.auth_timeout_timer then
        state.auth_timeout_timer:stop()
        state.auth_timeout_timer:close()
        state.auth_timeout_timer = nil
      end
    end)
  end)
end

---Stop authentication timeout timer
---@return nil
local function stop_auth_timeout()
  if state.auth_timeout_timer then
    state.auth_timeout_timer:stop()
    state.auth_timeout_timer:close()
    state.auth_timeout_timer = nil
  end
end

---Check and potentially rotate log file (called periodically)
---@param log_file_path string Path to the log file
---@return file*|nil log_file The opened log file or nil on error
local function get_log_file(log_file_path)
  state.log_check_counter = state.log_check_counter + 1
  
  local log_file = io.open(log_file_path, "a")
  if not log_file then
    return nil
  end
  
  if state.log_check_counter >= config.log_check_interval then
    state.log_check_counter = 0
    local stat = vim.loop.fs_stat(log_file_path)
    if stat and stat.size > config.log_rotation_size then
      log_file:close()
      local clear_file = io.open(log_file_path, "w")
      if clear_file then
        clear_file:close()
        log(LOG_LEVELS.WARN, "Transmit log file exceeded size limit and was cleared", true)
      end
      log_file = io.open(log_file_path, "a")
    end
  end
  
  return log_file
end

---Ensure SFTP connection is established, creating one if needed
---@param callback function|nil Optional callback to run after connection is ready
---@return boolean success Returns false if connection setup failed
function sftp.ensure_connection(callback)
  if state.transmit_job and state.connection_ready then
    if callback then callback() end
    reset_keepalive_timer()
    return true
  end
  if state.connecting then return false end
  state.connecting = true

  local config_data = sftp.get_sftp_server_config()
  if not config_data then
    state.connecting = false
    log(LOG_LEVELS.ERROR, "No SFTP server configuration found", true)
    return false
  end

  local transmit_executable = get_transmit_path()
  if not transmit_executable then
    state.connecting = false
    return false
  end
  
  state.transmit_phase = PHASE.INIT

  start_auth_timeout()
  
  log(LOG_LEVELS.INFO, "Starting SFTP connection to " .. config_data.credentials.host)

  state.transmit_job = vim.fn.jobstart({ transmit_executable }, {
    stdout_buffered = false,
    stderr_buffered = false,
    pty = false,
    on_stdout = function(_, data)
      local log_file_path = vim.fn.stdpath("cache") .. "/sftp_log.txt"
      local log_file = get_log_file(log_file_path)
      
      if not log_file then
        log(LOG_LEVELS.WARN, "Failed to open SFTP log file")
        return
      end

      local timestamp_format = "[%Y-%m-%d %H:%M:%S] "
      local progress_path = nil

      for _, line in ipairs(data) do
        local timestamp = os.date(timestamp_format)
        log_file:write(timestamp .. line .. "\n")

        if state.transmit_phase == PHASE.INIT and line:match("Enter SSH hostname") then
          vim.fn.chansend(state.transmit_job, config_data.credentials.host .. "\n")
          state.transmit_phase = PHASE.USERNAME
        elseif state.transmit_phase == PHASE.USERNAME and line:match("Enter SSH username") then
          vim.fn.chansend(state.transmit_job, config_data.credentials.username .. "\n")
          state.transmit_phase = PHASE.KEY
        elseif state.transmit_phase == PHASE.KEY and line:match("Enter path to private key") then
          vim.fn.chansend(state.transmit_job, config_data.credentials.identity_file .. "\n")
          state.transmit_phase = PHASE.READY
        elseif state.transmit_phase == PHASE.READY and line:match("Connected to") then
          state.transmit_phase = PHASE.ACTIVE
          state.connecting = false
          state.connection_ready = true
          stop_auth_timeout()
          log(LOG_LEVELS.INFO, "SFTP connection established", true)
          if callback then callback() end
        elseif state.transmit_phase == PHASE.ACTIVE then
          if line:match("^PROGRESS|") then
            local file, percent = line:match("^PROGRESS|(.-)|(%d+)")
            percent = tonumber(percent)
            
            if file and percent and percent >= 0 and percent <= 100 then
              if not progress_path or progress_path.filename ~= file then
                progress_path = Path:new(file)
              end
              state.current_progress.file = progress_path:make_relative()
              state.current_progress.percent = percent
            else
              log(LOG_LEVELS.WARN, "Invalid progress data: " .. line)
            end
          elseif line:match("^1|Upload succeeded") or line:match("^1|Remove succeeded") or line:match("^0|") then
            local current_item = get_current_queue_item()
            if current_item and current_item.processing then
              log(LOG_LEVELS.DEBUG, "Completed " .. current_item.type .. " for " .. current_item.filename)
              remove_item_from_queue()
              state.current_progress = { file = nil, percent = nil }
              reset_keepalive_timer()
              sftp.process_next()
            end
          end
        end
      end

      log_file:close()
    end,

    on_exit = function(_, exit_code, _)
      state.connection_ready = false
      state.transmit_job = nil
      state.connecting = false
      state.current_progress = { file = nil, percent = nil }
      stop_auth_timeout()

      if not state.is_exiting then
        log(LOG_LEVELS.WARN, "SFTP connection lost (exit code " .. exit_code .. "). Reconnecting...", true)
        
        for _, item in ipairs(state.queue) do
          item.processing = false
        end
        
        sftp.ensure_connection(function()
          sftp.process_next()
        end)
      end
    end,
  })
  
  return true
end

---Process the next item in the queue
---@return boolean success Returns true if an item was processed
function sftp.process_next()
  local item = get_current_queue_item()
  if not item then
    return false
  end

  if item.processing then
    return false
  end

  local config_data = sftp.get_sftp_server_config()
  if not config_data then
    log(LOG_LEVELS.ERROR, "No SFTP server configuration found", true)
    return false
  end
  
  local data = get_transmit_data()
  if not data then
    return false
  end
  
  local cwd = item.working_dir
  local file = item.filename
  local relative = file:gsub(escapePattern(cwd), "")
  
  if not data[cwd] or not data[cwd].remote then
    log(LOG_LEVELS.ERROR, "No remote configured for working directory: " .. cwd, true)
    remove_item_from_queue()
    return false
  end
  
  local remote_base = config_data.remotes[data[cwd].remote]
  if not remote_base then
    log(LOG_LEVELS.ERROR, "Remote '" .. data[cwd].remote .. "' not found in server config", true)
    remove_item_from_queue()
    return false
  end
  
  local remote_path = remote_base .. relative

  local cmd = nil
  if item.type == OPERATION_TYPE.UPLOAD then
    cmd = string.format("upload %s %s\n", file, remote_path)
  elseif item.type == OPERATION_TYPE.REMOVE then
    cmd = string.format("remove %s\n", remote_path)
  end

  if cmd then
    item.processing = true
    log(LOG_LEVELS.DEBUG, "Processing " .. item.type .. " for " .. item.filename)
    vim.fn.chansend(state.transmit_job, cmd)
    return true
  end
  
  return false
end

---Add a file operation to the queue
---@param type "upload"|"remove" The operation type
---@param filename string The local file path
---@param working_dir string The working directory
---@return number|nil queue_id Returns queue item ID on success, nil on failure
function sftp.add_to_queue(type, filename, working_dir)
  if not type or (type ~= OPERATION_TYPE.UPLOAD and type ~= OPERATION_TYPE.REMOVE) then
    log(LOG_LEVELS.ERROR, "Invalid operation type: " .. tostring(type), true)
    return nil
  end
  
  if not filename or filename == "" then
    log(LOG_LEVELS.ERROR, "Invalid filename", true)
    return nil
  end
  
  if not working_dir or working_dir == "" then
    log(LOG_LEVELS.ERROR, "Invalid working directory", true)
    return nil
  end

  local queue_id = state.next_queue_id
  state.next_queue_id = state.next_queue_id + 1

  table.insert(state.queue, {
    id = queue_id,
    type = type,
    filename = filename,
    working_dir = working_dir,
    processing = false,
  })

  log(LOG_LEVELS.DEBUG, "Added to queue [" .. queue_id .. "]: " .. type .. " " .. filename)

  sftp.ensure_connection(function()
    sftp.process_next()
  end)
  
  return queue_id
end

---Cancel a queued operation by ID
---@param queue_id number The queue item ID to cancel
---@return boolean success Returns true if item was cancelled
function sftp.cancel_queue_item(queue_id)
  local item, index = find_queue_item(queue_id)
  
  if not item then
    log(LOG_LEVELS.WARN, "Queue item not found: " .. queue_id)
    return false
  end
  
  if item.processing then
    log(LOG_LEVELS.WARN, "Cannot cancel item that is currently processing: " .. queue_id, true)
    return false
  end
  
  table.remove(state.queue, index)
  log(LOG_LEVELS.INFO, "Cancelled queue item [" .. queue_id .. "]: " .. item.filename)
  return true
end

---Clear all non-processing items from the queue
---@return number count Number of items cleared
function sftp.clear_queue()
  local cleared = 0
  local i = 1
  
  while i <= #state.queue do
    if not state.queue[i].processing then
      table.remove(state.queue, i)
      cleared = cleared + 1
    else
      i = i + 1
    end
  end
  
  log(LOG_LEVELS.INFO, "Cleared " .. cleared .. " items from queue")
  return cleared
end

---Get the current remote path for a working directory
---@param working_dir string The working directory path
---@return string remote The remote name or 'none'
function sftp.get_current_remote(working_dir)
  local data = get_transmit_data()
  if not data then return 'none' end
  return data[working_dir] and data[working_dir].remote or 'none'
end

---Get the current server name for a working directory
---@param working_dir string The working directory path
---@return string server The server name or 'none'
function sftp.get_current_server(working_dir)
  local data = get_transmit_data()
  if not data then return 'none' end
  return data[working_dir] and data[working_dir].server_name or 'none'
end

---Parse and load SFTP configuration from a JSON file
---@param config_location string Path to the configuration file
---@return boolean success True if config was loaded successfully
function sftp.parse_sftp_config(config_location)
  log(LOG_LEVELS.INFO, "Attempting to parse config from: " .. config_location)
  
  local path = Path:new(config_location)
  if not path:exists() then 
    log(LOG_LEVELS.ERROR, "Config file not found: " .. config_location, true)
    return false 
  end
  
  local success, result = pcall(vim.json.decode, path:read())
  if not success then
    log(LOG_LEVELS.ERROR, "Failed to parse SFTP config: " .. tostring(result), true)
    return false
  end
  
  -- Clear existing config
  for k in pairs(state.server_config) do
    state.server_config[k] = nil
  end
  
  -- Copy new config into existing table (preserves reference)
  for k, v in pairs(result) do
    state.server_config[k] = v
  end
  
  log(LOG_LEVELS.INFO, "Loaded " .. vim.tbl_count(state.server_config) .. " server(s)", true)
  
  return true
end

---Get the SFTP server configuration for the currently selected server
---@return ServerConfig|nil config The server configuration or nil
function sftp.get_sftp_server_config()
  local server = get_selected_server()
  if not server then return nil end
  return state.server_config[server]
end

---Update the server configuration for the current working directory
---@param server_name string The server name (or 'none' to clear)
---@param remote string The remote path name
---@return boolean success Returns true if update was successful
function sftp.update_transmit_server_config(server_name, remote)
  local cwd = vim.loop.cwd()
  local data = get_transmit_data()
  if not data then
    return false
  end
  
  data[cwd] = data[cwd] or {}
  if server_name == 'none' then
    data[cwd] = nil
  else
    data[cwd].server_name = server_name
    data[cwd].remote = remote
  end
  
  local success, err = pcall(function()
    Path:new(transmit_server_data):write(vim.json.encode(data), 'w')
  end)
  
  if not success then
    log(LOG_LEVELS.ERROR, "Failed to save transmit config: " .. tostring(err), true)
    return false
  end
  
  log(LOG_LEVELS.DEBUG, "Updated server config: " .. server_name .. " -> " .. remote)
  return true
end

---Check if a working directory has an active SFTP server selection
---@param working_dir string The working directory path
---@return boolean active True if there is an active selection
function sftp.working_dir_has_active_sftp_selection(working_dir)
  local data = get_transmit_data()
  if not data then return false end
  return data[working_dir] and data[working_dir].remote ~= nil
end

---Get the current upload progress information
---@return ProgressInfo progress Current progress with file and percent
function sftp.get_progress()
  return state.current_progress
end

---Get the number of items in the queue (O(1))
---@return number count Number of items in queue
function sftp.queue_length()
  return #state.queue
end

---Get all queue items
---@return QueueItem[] items All items in the queue
function sftp.get_queue()
  return vim.deepcopy(state.queue)
end

---Get connection status
---@return boolean connected, boolean connecting Connection status
function sftp.get_connection_status()
  return state.connection_ready, state.connecting
end

---Set logging level
---@param level number Log level (1=DEBUG, 2=INFO, 3=WARN, 4=ERROR)
function sftp.set_log_level(level)
  if level >= LOG_LEVELS.DEBUG and level <= LOG_LEVELS.ERROR then
    config.log_level = level
    log(LOG_LEVELS.INFO, "Log level set to " .. level)
  end
end

---Disconnect from SFTP server
---@return boolean success Returns true if disconnected successfully
function sftp.disconnect()
  if not state.transmit_job then
    return false
  end
  
  vim.fn.chansend(state.transmit_job, "exit\n")
  log(LOG_LEVELS.INFO, "Manually disconnecting SFTP session")
  
  -- Cleanup will happen in on_exit callback
  return true
end

return sftp

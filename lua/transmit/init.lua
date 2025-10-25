-- Transmit: SFTP file transfer plugin for Neovim
local sftp = require("transmit.sftp2")
local events = require("transmit.events")
local util = require("transmit.util")

-- Constants
local CLOSING_KEYS = {'<Esc>'}
local WINDOW_CONFIG = {
  width = 40,
  height = 10,
}

---@class TransmitConfig
---@field config_location string Path to the SFTP configuration file

---@class Transmit
local transmit = {}

---Get centered window position
---@param width number Window width
---@param height number Window height
---@return number col, number row Window column and row position
local function get_centered_position(width, height)
  local ui_list = vim.api.nvim_list_uis()
  if #ui_list == 0 then
    return 0, 0
  end
  
  local ui = ui_list[1]
  local col = math.floor((ui.width / 2) - (width / 2))
  local row = math.floor((ui.height / 2) - (height / 2))
  
  return col, row
end

---Create a floating window buffer with closing keymaps
---@param title string Window title
---@return number buf Buffer handle
---@return number win Window handle
local function create_floating_window(title)
  local buf = vim.api.nvim_create_buf(false, true)
  
  -- Set closing keymaps
  for _, key in ipairs(CLOSING_KEYS) do
    vim.api.nvim_buf_set_keymap(buf, 'n', key, ':close<CR>', { noremap = true, silent = true })
  end
  
  local col, row = get_centered_position(WINDOW_CONFIG.width, WINDOW_CONFIG.height)
  
  local opts = {
    title = title,
    title_pos = "left",
    relative = "editor",
    width = WINDOW_CONFIG.width,
    height = WINDOW_CONFIG.height,
    col = col,
    row = row,
    style = "minimal",
    border = "single"
  }
  
  local win = vim.api.nvim_open_win(buf, true, opts)
  
  return buf, win
end

---Set buffer lines and make it non-modifiable
---@param buf number Buffer handle
---@param lines string[] Lines to set
local function set_buffer_lines(buf, lines)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, 'modifiable', false)
end

---Get list of server names from configuration
---@return string[] servers List of server names with 'none' prepended
local function get_server_list()
  local servers = {"none"}
  
  -- Check if server_config exists and is a table
  if not sftp.server_config or type(sftp.server_config) ~= "table" then
    return servers
  end
  
  for name, _ in pairs(sftp.server_config) do
    table.insert(servers, name)
  end
  
  return servers
end

---Get list of remote names for a server
---@param server_name string The server name
---@return string[]|nil remotes List of remote names or nil if server not found
local function get_remote_list(server_name)
  -- Check if server_config exists
  if not sftp.server_config or type(sftp.server_config) ~= "table" then
    return nil
  end
  
  if not sftp.server_config[server_name] then
    return nil
  end
  
  -- Check if remotes exists
  if not sftp.server_config[server_name]['remotes'] or 
     type(sftp.server_config[server_name]['remotes']) ~= "table" then
    return {}
  end
  
  local remotes = {}
  for name, _ in pairs(sftp.server_config[server_name]['remotes']) do
    table.insert(remotes, name)
  end
  
  return remotes
end

---Open server selection window
---@return nil
function transmit.open_select_window()
  local servers = get_server_list()
  
  -- Check if any servers are configured beyond 'none'
  if #servers == 1 then
    vim.notify("No SFTP servers configured. Check your config file.", vim.log.levels.WARN)
  end
  
  local buf, win = create_floating_window("Transmit server selection")
  
  set_buffer_lines(buf, servers)
  
  vim.api.nvim_buf_set_keymap(
    buf, 
    'n', 
    '<CR>', 
    ":lua require('transmit').select_server()<CR>", 
    { noremap = true, silent = true }
  )
end

---Setup the Transmit plugin
---@param config TransmitConfig Configuration table
---@return boolean success Returns true if setup was successful
function transmit.setup(config)
  if not config or not config.config_location then
    vim.notify("Transmit: config_location is required", vim.log.levels.ERROR)
    return false
  end

  -- Register commands
  vim.api.nvim_create_user_command('TransmitOpenSelectWindow', function()
    transmit.open_select_window()
  end, { desc = "Open Transmit server selection window" })
  
  vim.api.nvim_create_user_command('TransmitUpload', function()
    transmit.upload_file()
  end, { desc = "Upload current file via SFTP" })
  
  vim.api.nvim_create_user_command('TransmitRemove', function()
    transmit.remove_path()
  end, { desc = "Remove current file from remote via SFTP" })

  -- Parse SFTP configuration
  local success = sftp.parse_sftp_config(config.config_location)
  if not success then
    vim.notify("Transmit: Failed to parse SFTP configuration", vim.log.levels.ERROR)
    return false
  end

  local server_config = sftp.get_sftp_server_config()

  if not server_config then
    -- No server selected yet, which is fine
    return true
  end

  -- Setup auto-upload on buffer write if configured
  if server_config.upload_on_bufwrite then
    vim.api.nvim_create_augroup("TransmitAutoCommands", { clear = true })
    vim.api.nvim_create_autocmd("BufWritePost", {
      group = "TransmitAutoCommands",
      callback = function()
        transmit.upload_file()
      end,
      desc = "Auto-upload file after save"
    })
  end

  -- Setup directory watching if configured
  if server_config.watch_for_changes then
    -- Watch functionality can be enabled per-server
    -- Actual watching starts when a server/remote is selected
  end

  return true
end

---Get the current server name for the current working directory
---@return string server The server name or 'none'
function transmit.get_current_server()
  return sftp.get_current_server(vim.loop.cwd())
end

---Get the current remote name for the current working directory
---@return string remote The remote name or 'none'
function transmit.get_current_remote()
  return sftp.get_current_remote(vim.loop.cwd())
end

---Get the server name for a specific directory
---@param directory string The directory path
---@return string server The server name or 'none'
function transmit.get_server(directory)
  return sftp.get_current_server(directory)
end

---Select a server from the server list window
---@return boolean success Returns true if server was selected
function transmit.select_server()
  local idx = vim.fn.line(".")
  
  -- If "none" is selected
  if idx == 1 then
    sftp.update_transmit_server_config('none', nil)
    vim.api.nvim_win_close(0, true)
    return true
  end

  -- Adjust index to account for "none" option
  idx = idx - 1

  local servers = get_server_list()
  -- Remove "none" from list to get actual server at index
  table.remove(servers, 1)
  
  local selected_server = servers[idx]
  if not selected_server then
    vim.notify("Invalid server selection", vim.log.levels.ERROR)
    return false
  end

  -- Open remote selection window
  local buf, win = create_floating_window("Transmit remotes selection")
  
  local remotes = get_remote_list(selected_server)
  if not remotes or #remotes == 0 then
    vim.notify("No remotes configured for server: " .. selected_server, vim.log.levels.WARN)
    vim.api.nvim_win_close(0, true)
    return false
  end
  
  set_buffer_lines(buf, remotes)
  
  vim.api.nvim_buf_set_keymap(
    buf,
    'n',
    '<CR>',
    string.format(":lua require('transmit').select_remote('%s')<CR>", selected_server),
    { noremap = true, silent = true }
  )
  
  return true
end

---Select a remote from the remote list window
---@param server_name string The server name
---@return boolean success Returns true if remote was selected
function transmit.select_remote(server_name)
  local remote_index = vim.fn.line(".")
  
  if not sftp.server_config[server_name] then
    vim.notify("Server not found: " .. server_name, vim.log.levels.ERROR)
    return false
  end

  local remotes = get_remote_list(server_name)
  if not remotes or not remotes[remote_index] then
    vim.notify("Invalid remote selection", vim.log.levels.ERROR)
    return false
  end

  local selected_remote = remotes[remote_index]
  local success = sftp.update_transmit_server_config(server_name, selected_remote)
  
  if not success then
    vim.notify("Failed to update server configuration", vim.log.levels.ERROR)
    return false
  end

  -- Close both windows (remote selection and server selection)
  vim.api.nvim_win_close(0, true)
  -- Find and close the server selection window
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, 1, false)
    if lines[1] == "none" then
      vim.api.nvim_win_close(win, true)
      break
    end
  end

  vim.notify("Selected: " .. server_name .. " -> " .. selected_remote, vim.log.levels.INFO)

  local server_config = sftp.get_sftp_server_config()
  
  -- Start watching if configured
  if server_config and server_config.watch_for_changes then
    transmit.watch_current_working_directory()
  end
  
  return true
end

---Watch a directory for changes and auto-upload
---@param directory string The directory path to watch
---@return boolean success Returns true if watching started
function transmit.watch_directory(directory)
  local server_name = transmit.get_server(directory)
  
  if not sftp.server_config[server_name] or server_name == 'none' then
    return false
  end

  local server_config = sftp.server_config[server_name]
  
  if not server_config.watch_for_changes then
    return false
  end

  local excluded = server_config.exclude_watch_directories or {}
  events.watch_directory_for_changes(directory, excluded)
  
  return true
end

---Watch the current working directory for changes
---@return boolean success Returns true if watching started
function transmit.watch_current_working_directory()
  local server_name = transmit.get_current_server()
  
  if not sftp.server_config[server_name] or server_name == 'none' then
    return false
  end

  local server_config = sftp.server_config[server_name]
  
  if not server_config.watch_for_changes then
    return false
  end

  local excluded = server_config.exclude_watch_directories or {}
  events.watch_directory_for_changes(vim.loop.cwd(), excluded)
  
  return true
end

---Remove a path from the remote server
---@param path string|nil Optional path to remove (defaults to current file)
---@return boolean success Returns true if removal was queued
function transmit.remove_path(path)
  return util.remove_path(path)
end

---Upload a file to the remote server
---@param file string|nil Optional file path (defaults to current file)
---@return boolean success Returns true if upload was queued
function transmit.upload_file(file)
  return util.upload_file(file)
end

---Remove directory watchers
---@param directory string|nil Optional directory path (nil removes all watchers)
---@return nil
function transmit.remove_watch(directory)
  if directory == nil then
    events.remove_all_watchers()
  else
    events.remove_all_watches_for_root(directory)
  end
end

---Get current upload progress information
---@return ProgressInfo progress Current progress with file and percent
function transmit.get_progress()
  return sftp.get_progress()
end

---Get the number of items in the upload queue
---@return number count Number of items in queue
function transmit.queue_length()
  return sftp.queue_length()
end

---Get all queue items
---@return QueueItem[] items All items in the queue
function transmit.get_queue()
  return sftp.get_queue()
end

---Cancel a queued operation by ID
---@param queue_id number The queue item ID to cancel
---@return boolean success Returns true if item was cancelled
function transmit.cancel_queue_item(queue_id)
  return sftp.cancel_queue_item(queue_id)
end

---Clear all non-processing items from the queue
---@return number count Number of items cleared
function transmit.clear_queue()
  return sftp.clear_queue()
end

---Get connection status
---@return boolean connected, boolean connecting Connection status
function transmit.get_connection_status()
  return sftp.get_connection_status()
end

---Manually disconnect from SFTP server
---@return boolean success Returns true if disconnected successfully
function transmit.disconnect()
  return sftp.disconnect()
end

---Set logging level for SFTP operations
---@param level number Log level (1=DEBUG, 2=INFO, 3=WARN, 4=ERROR)
---@return nil
function transmit.set_log_level(level)
  sftp.set_log_level(level)
end

return transmit

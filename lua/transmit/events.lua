-- File system event watching for automatic SFTP sync
local util = require('transmit.util')

---@class Events
local events = {}

---@type table<string, table<string, uv_fs_event_t>>
events.watching = {}

-- Constants
local EXCLUDED_PATTERNS = {
  "%.vim%.bak$",      -- Vim backup files
  "%.sw[a-z]$",       -- Vim swap files (.swp, .swo, etc.)
  "%.tmp$",           -- Temporary files
  "%.git",            -- Git directory
  "node_modules",     -- Node.js modules
  "__pycache__",      -- Python cache
  "%.DS_Store$",      -- macOS metadata
}

---Check if the current OS is Windows
---@return boolean is_windows True if running on Windows
local function is_windows()
  return package.config:sub(1, 1) == '\\'
end

---Check if a path matches any excluded pattern
---@param path string Path to check
---@return boolean is_excluded True if path should be excluded
local function is_excluded_by_pattern(path)
  for _, pattern in ipairs(EXCLUDED_PATTERNS) do
    if string.find(path, pattern) then
      return true
    end
  end
  return false
end

---Check if a directory is in the excluded list
---@param directory string Directory path to check
---@param excluded_directories string[] List of excluded directory patterns
---@return boolean is_excluded True if directory matches any exclusion pattern
local function is_excluded_directory(directory, excluded_directories)
  if not excluded_directories then
    return false
  end
  
  for _, excluded in ipairs(excluded_directories) do
    if string.find(directory, excluded, 1, true) then
      return true
    end
  end
  
  return false
end

---Stringify a table for debugging (recursive)
---@param tbl table Table to stringify
---@param depth number|nil Current recursion depth (for cycle detection)
---@return string stringified String representation of table
local function stringify_table(tbl, depth)
  depth = depth or 0
  
  -- Prevent infinite recursion
  if depth > 10 then
    return "{...}"
  end
  
  if type(tbl) ~= "table" then
    return tostring(tbl)
  end
  
  local result = "{"
  local first = true
  
  for k, v in pairs(tbl) do
    if not first then
      result = result .. ", "
    end
    first = false
    
    -- Handle key formatting
    local key_str = type(k) == "string" and '"' .. k .. '"' or tostring(k)
    
    -- Handle value formatting based on its type
    local value_str
    if type(v) == "table" then
      value_str = stringify_table(v, depth + 1)
    elseif type(v) == "string" then
      value_str = '"' .. v .. '"'
    else
      value_str = tostring(v)
    end
    
    result = result .. "[" .. key_str .. "]=" .. value_str
  end
  
  return result .. "}"
end

---Check if a file or directory exists
---@param path string Path to check
---@return boolean exists, boolean is_directory Whether path exists and if it's a directory
local function check_path_exists(path)
  local stat = vim.loop.fs_stat(path)
  if not stat then
    return false, false
  end
  return true, stat.type == "directory"
end

---Handle file system change events
---@param path string Full path to the changed file/directory
---@param root_directory string Root directory being watched
---@param excluded_directories string[] List of excluded directory patterns
---@return nil
local function on_change(path, root_directory, excluded_directories)
  -- Skip if path matches excluded patterns
  if is_excluded_by_pattern(path) then
    return
  end
  
  -- Skip if path is the root directory or in excluded list
  if path == root_directory or is_excluded_directory(path, excluded_directories) then
    return
  end
  
  local exists, is_directory = check_path_exists(path)
  
  -- Handle directory changes
  if is_directory then
    -- TODO: Implement directory creation/removal
    -- Could watch new directories or remove watches for deleted directories
    return
  end
  
  -- Schedule file operations on main thread
  if not exists then
    -- File was deleted
    vim.schedule(function()
      util.remove_path(path, root_directory)
    end)
  else
    -- File was created or modified
    vim.schedule(function()
      util.upload_file(path, root_directory)
    end)
  end
end

---Stop watching a specific directory
---@param dir string Directory path
---@param handle_event uv_fs_event_t Event handle
---@param root_directory string Root directory being watched
---@return nil
local function remove_watch(dir, handle_event, root_directory)
  local uv = vim.uv or vim.loop
  
  if handle_event then
    uv.fs_event_stop(handle_event)
  end
  
  if events.watching[root_directory] then
    events.watching[root_directory][dir] = nil
  end
end

---Remove all file system watchers
---@return number count Number of watchers removed
function events.remove_all_watchers()
  local uv = vim.uv or vim.loop
  local count = 0
  
  for root_directory, watchers in pairs(events.watching) do
    for dir, handle_event in pairs(watchers) do
      if handle_event then
        uv.fs_event_stop(handle_event)
        count = count + 1
      end
      events.watching[root_directory][dir] = nil
    end
    events.watching[root_directory] = nil
  end
  
  return count
end

---Remove all watchers for a specific root directory
---@param root_directory string Root directory path
---@return number count Number of watchers removed
function events.remove_all_watches_for_root(root_directory)
  local uv = vim.uv or vim.loop
  
  if not events.watching[root_directory] then
    return 0
  end
  
  local count = 0
  
  for dir, handle_event in pairs(events.watching[root_directory]) do
    if handle_event then
      uv.fs_event_stop(handle_event)
      count = count + 1
    end
    events.watching[root_directory][dir] = nil
  end
  
  events.watching[root_directory] = nil
  
  return count
end

---Get list of all subdirectories in a directory
---@param directory string Root directory to scan
---@return string[]|nil directories List of subdirectory paths or nil on error
local function get_subdirectories(directory)
  local command
  if is_windows() then
    command = 'dir "' .. directory .. '" /ad /b /s'
  else
    command = 'find "' .. directory .. '" -type d'
  end
  
  local handle = io.popen(command)
  if not handle then
    return nil
  end
  
  local directories = {}
  for dir in handle:lines() do
    table.insert(directories, dir)
  end
  
  handle:close()
  return directories
end

---Watch a directory and all its subdirectories for changes
---@param directory string Root directory path to watch
---@param excluded_directories string[]|nil List of directory patterns to exclude
---@return boolean success Returns true if watching started successfully
function events.watch_directory_for_changes(directory, excluded_directories)
  excluded_directories = excluded_directories or {}
  
  -- Check if already watching this directory
  if events.watching[directory] then
    vim.notify("Already watching directory: " .. directory, vim.log.levels.INFO)
    return true
  end
  
  -- Validate directory exists
  local exists, is_dir = check_path_exists(directory)
  if not exists then
    vim.notify("Directory does not exist: " .. directory, vim.log.levels.ERROR)
    return false
  end
  
  if not is_dir then
    vim.notify("Path is not a directory: " .. directory, vim.log.levels.ERROR)
    return false
  end
  
  local uv = vim.uv or vim.loop
  
  -- Get all subdirectories
  local directories = get_subdirectories(directory)
  if not directories then
    vim.notify("Failed to scan directory: " .. directory, vim.log.levels.ERROR)
    return false
  end
  
  -- FS event flags
  local flags = {
    watch_entry = false, -- When true, watch dir inode instead of dir content
    stat = false,        -- When true, use periodic check instead of inotify/kqueue
    recursive = false    -- Recursion handled manually for better control
  }
  
  events.watching[directory] = {}
  local watch_count = 0
  local excluded_count = 0
  
  -- Watch each directory
  for _, dir in ipairs(directories) do
    -- Skip excluded directories
    if is_excluded_directory(dir, excluded_directories) or is_excluded_by_pattern(dir) then
      excluded_count = excluded_count + 1
      goto continue
    end
    
    local handle_event = uv.new_fs_event()
    
    if not handle_event then
      vim.notify("Failed to create fs_event handle for: " .. dir, vim.log.levels.WARN)
      goto continue
    end
    
    -- Callback for file system events
    local callback = function(err, filename, event_info)
      if err then
        vim.schedule(function()
          vim.notify("Watch error for " .. dir .. ": " .. err, vim.log.levels.WARN)
        end)
        remove_watch(dir, handle_event, directory)
      else
        if filename then
          local full_path = dir .. "/" .. filename
          on_change(full_path, directory, excluded_directories)
        end
      end
    end
    
    -- Start watching
    local success, err = pcall(function()
      uv.fs_event_start(handle_event, dir, flags, callback)
    end)
    
    if not success then
      vim.notify("Failed to start watching " .. dir .. ": " .. tostring(err), vim.log.levels.WARN)
      goto continue
    end
    
    events.watching[directory][dir] = handle_event
    watch_count = watch_count + 1
    
    ::continue::
  end
  
  vim.notify(
    string.format("Watching %d director%s in: %s%s",
      watch_count,
      watch_count == 1 and "y" or "ies",
      directory,
      excluded_count > 0 and string.format(" (%d excluded)", excluded_count) or ""
    ),
    vim.log.levels.INFO
  )
  
  return watch_count > 0
end

---Check if a directory is being watched
---@param directory string Directory path to check
---@return boolean is_watching True if directory is being watched
function events.is_watching(directory)
  return events.watching[directory] ~= nil
end

---Get count of directories being watched under a root
---@param root_directory string Root directory path
---@return number count Number of subdirectories being watched
function events.get_watch_count(root_directory)
  if not events.watching[root_directory] then
    return 0
  end
  
  local count = 0
  for _ in pairs(events.watching[root_directory]) do
    count = count + 1
  end
  
  return count
end

---Get all root directories currently being watched
---@return string[] roots List of root directory paths
function events.get_watched_roots()
  local roots = {}
  for root, _ in pairs(events.watching) do
    table.insert(roots, root)
  end
  return roots
end

return events

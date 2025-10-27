-- Utility functions for file operations with SFTP
local sftp = require('transmit.sftp2')

---@class Util
local util = {}

---Validate that a file path exists and is readable
---@param path string File path to validate
---@return boolean valid, string|nil error True if valid, false with error message if invalid
local function validate_file_path(path)
  if not path or path == "" then
    return false, "Empty file path"
  end
  
  -- Check if file exists
  local stat = vim.loop.fs_stat(path)
  if not stat then
    return false, "File does not exist: " .. path
  end
  
  -- Check if it's a directory
  if stat.type == "directory" then
    return false, "Path is a directory, not a file: " .. path
  end
  
  return true, nil
end

---Validate that a working directory exists
---@param working_dir string Directory path to validate
---@return boolean valid, string|nil error True if valid, false with error message if invalid
local function validate_working_dir(working_dir)
  if not working_dir or working_dir == "" then
    return false, "Empty working directory"
  end
  
  local stat = vim.loop.fs_stat(working_dir)
  if not stat then
    return false, "Working directory does not exist: " .. working_dir
  end
  
  if stat.type ~= "directory" then
    return false, "Working directory is not a directory: " .. working_dir
  end
  
  return true, nil
end

---Remove a path from the remote server
---@param path string|nil Optional path to remove (defaults to current buffer file)
---@param working_dir string|nil Optional working directory (defaults to current working directory)
---@return number|nil queue_id Returns queue item ID on success, nil on failure
function util.remove_path(path, working_dir)
  -- Default to current buffer file if no path provided
  if path == nil then
    path = vim.api.nvim_buf_get_name(0)
    
    -- Check if buffer has a valid file
    if path == "" then
      vim.notify("Current buffer has no associated file", vim.log.levels.WARN)
      return nil
    end
  end
  
  -- Default to current working directory
  if working_dir == nil then
    working_dir = vim.loop.cwd()
  end
  
  -- Validate inputs
  local valid_dir, dir_error = validate_working_dir(working_dir)
  if not valid_dir then
    vim.notify("Invalid working directory: " .. (dir_error or "unknown error"), vim.log.levels.ERROR)
    return nil
  end
  
  -- Check if working directory has an active SFTP selection
  if not sftp.working_dir_has_active_sftp_selection(working_dir) then
    vim.notify("No SFTP server/remote configured for: " .. working_dir, vim.log.levels.WARN)
    return nil
  end
  
  -- Add to queue
  local queue_id = sftp.add_to_queue("remove", path, working_dir)
  
  return queue_id
end

---Upload a file to the remote server
---@param file string|nil Optional file path (defaults to current buffer file)
---@param working_dir string|nil Optional working directory (defaults to current working directory)
---@return number|nil queue_id Returns queue item ID on success, nil on failure
function util.upload_file(file, working_dir)
  -- Default to current buffer file if no file provided
  if file == nil then
    file = vim.api.nvim_buf_get_name(0)
    
    -- Check if buffer has a valid file
    if file == "" then
      vim.notify("Current buffer has no associated file", vim.log.levels.WARN)
      return nil
    end
  end
  
  -- Default to current working directory
  if working_dir == nil then
    working_dir = vim.loop.cwd()
  end
  
  -- Validate file path
  local valid_file, file_error = validate_file_path(file)
  if not valid_file then
    vim.notify("Invalid file: " .. (file_error or "unknown error"), vim.log.levels.ERROR)
    return nil
  end
  
  -- Validate working directory
  local valid_dir, dir_error = validate_working_dir(working_dir)
  if not valid_dir then
    vim.notify("Invalid working directory: " .. (dir_error or "unknown error"), vim.log.levels.ERROR)
    return nil
  end
  
  -- Check if working directory has an active SFTP selection
  if not sftp.working_dir_has_active_sftp_selection(working_dir) then
    vim.notify("No SFTP server/remote configured for: " .. working_dir, vim.log.levels.WARN)
    return nil
  end
  
  -- Add to queue
  local queue_id = sftp.add_to_queue("upload", file, working_dir)
  
  return queue_id
end

---Batch upload multiple files
---@param files string[] List of file paths to upload
---@param working_dir string|nil Optional working directory (defaults to current working directory)
---@return number[] queue_ids List of queue item IDs for successfully queued files
function util.upload_files(files, working_dir)
  if not files or #files == 0 then
    vim.notify("No files provided for upload", vim.log.levels.WARN)
    return {}
  end
  
  if working_dir == nil then
    working_dir = vim.loop.cwd()
  end
  
  -- Validate working directory once
  local valid_dir, dir_error = validate_working_dir(working_dir)
  if not valid_dir then
    vim.notify("Invalid working directory: " .. (dir_error or "unknown error"), vim.log.levels.ERROR)
    return {}
  end
  
  -- Check if working directory has an active SFTP selection
  if not sftp.working_dir_has_active_sftp_selection(working_dir) then
    vim.notify("No SFTP server/remote configured for: " .. working_dir, vim.log.levels.WARN)
    return {}
  end
  
  local queue_ids = {}
  local success_count = 0
  local failed_count = 0
  
  for _, file in ipairs(files) do
    local valid_file, _ = validate_file_path(file)
    if valid_file then
      local queue_id = sftp.add_to_queue("upload", file, working_dir)
      if queue_id then
        table.insert(queue_ids, queue_id)
        success_count = success_count + 1
      else
        failed_count = failed_count + 1
      end
    else
      failed_count = failed_count + 1
    end
  end
  
  if success_count > 0 then
    vim.notify(
      string.format("Queued %d file(s) for upload%s", 
        success_count, 
        failed_count > 0 and string.format(" (%d failed)", failed_count) or ""
      ),
      vim.log.levels.INFO
    )
  end
  
  return queue_ids
end

---Batch remove multiple files from remote
---@param paths string[] List of paths to remove
---@param working_dir string|nil Optional working directory (defaults to current working directory)
---@return number[] queue_ids List of queue item IDs for successfully queued removals
function util.remove_paths(paths, working_dir)
  if not paths or #paths == 0 then
    vim.notify("No paths provided for removal", vim.log.levels.WARN)
    return {}
  end
  
  if working_dir == nil then
    working_dir = vim.loop.cwd()
  end
  
  -- Validate working directory once
  local valid_dir, dir_error = validate_working_dir(working_dir)
  if not valid_dir then
    vim.notify("Invalid working directory: " .. (dir_error or "unknown error"), vim.log.levels.ERROR)
    return {}
  end
  
  -- Check if working directory has an active SFTP selection
  if not sftp.working_dir_has_active_sftp_selection(working_dir) then
    vim.notify("No SFTP server/remote configured for: " .. working_dir, vim.log.levels.WARN)
    return {}
  end
  
  local queue_ids = {}
  local success_count = 0
  
  for _, path in ipairs(paths) do
    local queue_id = sftp.add_to_queue("remove", path, working_dir)
    if queue_id then
      table.insert(queue_ids, queue_id)
      success_count = success_count + 1
    end
  end
  
  if success_count > 0 then
    vim.notify(
      string.format("Queued %d path(s) for removal", success_count),
      vim.log.levels.INFO
    )
  end
  
  return queue_ids
end

---Upload all modified buffers in the current working directory
---@return number[] queue_ids List of queue item IDs for successfully queued uploads
function util.upload_modified_buffers()
  local working_dir = vim.loop.cwd()
  
  -- Check if working directory has an active SFTP selection
  if not sftp.working_dir_has_active_sftp_selection(working_dir) then
    vim.notify("No SFTP server/remote configured for current directory", vim.log.levels.WARN)
    return {}
  end
  
  local files = {}
  local buffers = vim.api.nvim_list_bufs()
  
  for _, buf in ipairs(buffers) do
    -- Check if buffer is loaded, modified, and has a file
    if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_option(buf, 'modified') then
      local file = vim.api.nvim_buf_get_name(buf)
      
      if file and file ~= "" then
        -- Check if file is within working directory
        if vim.startswith(file, working_dir) then
          table.insert(files, file)
        end
      end
    end
  end
  
  if #files == 0 then
    vim.notify("No modified buffers to upload", vim.log.levels.INFO)
    return {}
  end
  
  return util.upload_files(files, working_dir)
end

---Check if a file is within the current working directory
---@param file string File path to check
---@param working_dir string|nil Optional working directory (defaults to current working directory)
---@return boolean is_within True if file is within working directory
function util.is_file_in_working_dir(file, working_dir)
  if not file or file == "" then
    return false
  end
  
  if working_dir == nil then
    working_dir = vim.loop.cwd()
  end
  
  -- Normalize paths
  file = vim.fn.fnamemodify(file, ":p")
  working_dir = vim.fn.fnamemodify(working_dir, ":p")
  
  return vim.startswith(file, working_dir)
end

---Get relative path from working directory
---@param file string Absolute file path
---@param working_dir string|nil Optional working directory (defaults to current working directory)
---@return string|nil relative_path Relative path or nil if file is not in working directory
function util.get_relative_path(file, working_dir)
  if working_dir == nil then
    working_dir = vim.loop.cwd()
  end
  
  if not util.is_file_in_working_dir(file, working_dir) then
    return nil
  end
  
  -- Normalize paths
  file = vim.fn.fnamemodify(file, ":p")
  working_dir = vim.fn.fnamemodify(working_dir, ":p")
  
  -- Remove working_dir prefix
  local relative = file:sub(#working_dir + 1)
  
  -- Remove leading slash if present
  if vim.startswith(relative, "/") or vim.startswith(relative, "\\") then
    relative = relative:sub(2)
  end
  
  return relative
end

return util

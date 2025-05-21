local sftp = require('transmit.sftp2')
local util = {}

function util.remove_path(path, working_dir)
    if path == nil then
        path = vim.api.nvim_buf_get_name(0)
    end

    if working_dir == nil then
        working_dir = vim.loop.cwd()
    end

    if sftp.working_dir_has_active_sftp_selection(working_dir) == false then
        return false
    end

	sftp.add_to_queue("remove", path, working_dir)
end

function util.upload_file(file, working_dir)
    if file == nil then
        file = vim.api.nvim_buf_get_name(0)
    end

    if working_dir == nil then
        working_dir = vim.loop.cwd()
    end

    if sftp.working_dir_has_active_sftp_selection(working_dir) == false then
        return false
    end

	sftp.add_to_queue("upload", file, working_dir)
end

return util

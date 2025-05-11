local ffi = require("ffi")
local lib = ffi.load("./libtransmit.so")

-- Define the C functions we need
ffi.cdef[[
    typedef struct LIBSSH2_SFTP LIBSSH2_SFTP;
    typedef struct LIBSSH2_SESSION LIBSSH2_SESSION;

    int init_sftp_session(const char *hostname, const char *username, const char *privkey_path, LIBSSH2_SFTP **sftp_session, LIBSSH2_SESSION **session, int *sock);
    int upload_file(LIBSSH2_SFTP *sftp_session, const char *local_file, const char *remote_file);
    int create_directory(LIBSSH2_SFTP *sftp_session, const char *directory);
    void close_sftp_session(LIBSSH2_SFTP *sftp_session, LIBSSH2_SESSION *session, int sock);
	int sftp_remove_path_recursive(LIBSSH2_SFTP *sftp_session, const char *path);
]]

-- Load the C library (adjust the path to where the C shared library is located)
local sftp_lib = ffi.load("./libtransmit.so")

-- Declare variables to store session and sock
local sftp_session = ffi.new("LIBSSH2_SFTP *[1]")
local session = ffi.new("LIBSSH2_SESSION *[1]")
local sock = ffi.new("int[1]")
-- Connect to the server and get an SFTP session
local result = sftp_lib.init_sftp_session("52.87.27.131", "declan.brown", "/home/declanb/.ssh/id_rsa", sftp_session, session, sock)

sftp_lib.sftp_remove_path_recursive(sftp_session[0], "/workspace.declanb/cupboardy.web")

-- List of files to upload
local files_to_upload = {
	{
		local_file = "./twome",
		remote = "/workspace.declanb/twome"
	},
	{
		local_file = "./twome40",
		remote = "/workspace.declanb/twome40"
	},
	{
		local_file = "./file",
		remote = "/workspace.declanb/file"
	},
    {
    	local_file = "./test.txt",
    	remote = "/workspace.declanb/test.txt"
    },
    {
    	local_file = "./test.txt",
    	remote = "/workspace.declanb/kill5/test2/test.txt"
    },
	{
    	local_file = "./test.txt",
    	remote = "/workspace.declanb/kill6/test2/test.txt"
    },
{
    	local_file = "./test.txt",
    	remote = "/workspace.declanb/kill7/test2/test.txt"
    },
{
    	local_file = "./test.txt",
    	remote = "/workspace.declanb/kill8/test2/test.txt"
    },
{
    	local_file = "./test.txt",
    	remote = "/workspace.declanb/kill9/test2/test.txt"
    },
{
    	local_file = "./test.txt",
    	remote = "/workspace.declanb/kill10/test2/test.txt"
    },
{
    	local_file = "./test.txt",
    	remote = "/workspace.declanb/kill11/test2/test.txt"
    },
{
    	local_file = "./test.txt",
    	remote = "/workspace.declanb/kill12/test2/test.txt"
    },
{
    	local_file = "./test.txt",
    	remote = "/workspace.declanb/kill13/test2/test.txt"
    },
{
    	local_file = "./test.txt",
    	remote = "/workspace.declanb/kill14/test2/test.txt"
    },
{
    	local_file = "./test.txt",
    	remote = "/workspace.declanb/kill15/test2/test.txt"
    },
{
    	local_file = "./test.txt",
    	remote = "/workspace.declanb/kill16/test2/test.txt"
    },
{
    	local_file = "./test.txt",
    	remote = "/workspace.declanb/kill17/test2/test.txt"
    },
{
    	local_file = "./test.txt",
    	remote = "/workspace.declanb/kill18/test2/test.txt"
    },
	{
    	local_file = "./test.txt",
    	remote = "/workspace.declanb/kill19/test2/test.txt"
    },
}

-- local total_files = #files_to_upload
-- local files_uploaded = 0
--
-- -- Function to print progress bar
-- local function print_progress_bar(completed, total)
--     local percent = (completed / total) * 100
--     local bar_width = 50  -- Width of the progress bar
--     local progress = math.floor(bar_width * (completed / total))
--
--     -- Construct the progress bar string
--     local bar = string.rep("=", progress) .. string.rep(" ", bar_width - progress)
--     io.write(string.format("\r[%s] %.2f%% (%d/%d)", bar, percent, completed, total))
--     io.flush()
-- end

-- Upload each file
for _, file in ipairs(files_to_upload) do
    local result = sftp_lib.upload_file(sftp_session[0], file.local_file, file.remote)
    if result ~= 0 then
        print("Error uploading file:", file.local_file, " To: ", file.remote)
    else
        -- files_uploaded = files_uploaded + 1
        print("Successfully uploaded:", file.local_file, " To: ", file.remote)
    end
    -- -- Update progress bar
    -- print_progress_bar(files_uploaded, total_files)
end

-- Close the session after all uploads
sftp_lib.close_sftp_session(sftp_session[0], session[0], sock[0])

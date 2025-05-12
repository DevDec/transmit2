// transmit.c
#include <stdbool.h>
#include <libssh2.h>
#include <libssh2_sftp.h>
#include "transmit.h"
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netdb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <libgen.h>

#define SERVER_PORT 22

enum REMOVE_RESPONSES {
  SUCCESS,
  MEDIUM,
  HIGH
};

int init_sftp_session(const char *hostname, const char *username, const char *privkey_path, LIBSSH2_SFTP **sftp_session, LIBSSH2_SESSION **session, int *sock) {
    int rc;
    struct sockaddr_in sin;

    // Init libssh2
    rc = libssh2_init(0);
    if (rc != 0) {
        /* fprintf(stderr, "libssh2 initialization failed (%d)\n", rc); */
        return -1;
    }

    // Create socket and connect
    *sock = socket(AF_INET, SOCK_STREAM, 0);  // This modifies *sock
    if (*sock < 0) {
        /* perror("Socket creation failed"); */
        return -1;
    }
    
    sin.sin_family = AF_INET;
    sin.sin_port = htons(22);  // SFTP typically runs on port 22
    inet_pton(AF_INET, hostname, &sin.sin_addr);
    
    if (connect(*sock, (struct sockaddr*)(&sin), sizeof(struct sockaddr_in)) != 0) {
        /* perror("Socket connection failed"); */
        return -1;
    }

    // Create SSH session
    *session = libssh2_session_init();
    if (libssh2_session_handshake(*session, *sock)) {
        /* fprintf(stderr, "SSH session handshake failed\n"); */
        return -1;
    }

    // Authenticate with public key
    const char *passphrase = NULL;  // or your passphrase
    if (libssh2_userauth_publickey_fromfile(*session, username, NULL, privkey_path, passphrase)) {
        /* fprintf(stderr, "Authentication with public key failed\n"); */
        return -1;
    }

    // Init SFTP session
    *sftp_session = libssh2_sftp_init(*session);
    if (!(*sftp_session)) {
        /* fprintf(stderr, "Unable to init SFTP session\n"); */
        return -1;
    }

    return 0;
}

// Function to close the SFTP connection
void close_sftp_session(LIBSSH2_SFTP *sftp_session, LIBSSH2_SESSION *session, int sock) {
    libssh2_sftp_shutdown(sftp_session);
    libssh2_session_disconnect(session, "Normal Shutdown");
    libssh2_session_free(session);
    close(sock);
    libssh2_exit();
}

bool is_directory(const char *path) {
    struct stat path_stat;
    if (stat(path, &path_stat) != 0) {
        // Error accessing path (e.g., doesn't exist)
        return false;
    }
    return S_ISDIR(path_stat.st_mode);
}

// Function to upload a single file
int upload_file(LIBSSH2_SFTP *sftp_session, const char *local_file, const char *remote_file) {
	char path_copy[1024];
	snprintf(path_copy, sizeof(path_copy), "%s", remote_file);

	char local_path_copy[1024];
	snprintf(local_path_copy, sizeof(local_path_copy), "%s", local_file);

	if (is_directory(local_path_copy)) {
		char *dir_path = path_copy;

		if (create_remote_directory_recursively(sftp_session, dir_path)) {
			/* fprintf(stderr, "Failed to create remote directory recursively.\n"); */
			return 1;
		}

		return 0;
	}

    char *dir_path = dirname(path_copy);

	if (create_remote_directory_recursively(sftp_session, dir_path)) {
		/* fprintf(stderr, "Failed to create remote directory recursively.\n"); */
		return 1;
	}

    // Open remote file for writing
    LIBSSH2_SFTP_HANDLE *sftp_handle = libssh2_sftp_open(sftp_session, remote_file,
            LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC,
            LIBSSH2_SFTP_S_IRUSR | LIBSSH2_SFTP_S_IWUSR);
    if (!sftp_handle) {
        /* fprintf(stderr, "Unable to open remote file\n"); */
        return 1;
    }

    // Open local file
    FILE *local = fopen(local_file, "rb");
    if (!local) {
        /* perror("Failed to open local file"); */
        libssh2_sftp_close(sftp_handle);
        return 1;
    }

    // Upload loop
    char mem[1024];
    size_t nread;
    while ((nread = fread(mem, 1, sizeof(mem), local)) > 0) {
        char *ptr = mem;
        while (nread > 0) {
            ssize_t nwritten = libssh2_sftp_write(sftp_handle, ptr, nread);
            if (nwritten < 0) {
                /* fprintf(stderr, "SFTP write error\n"); */
                fclose(local);
                libssh2_sftp_close(sftp_handle);
                return 1;
            }
            ptr += nwritten;
            nread -= nwritten;
        }
    }

    fclose(local);
    libssh2_sftp_close(sftp_handle);
    return 0;
}

int create_directory(LIBSSH2_SFTP *sftp_session, const char *directory) {
	return create_remote_directory_recursively(sftp_session, directory);
}

// Function to create remote directories recursively
int create_remote_directory_recursively(LIBSSH2_SFTP *sftp_session, const char *path) {
	LIBSSH2_SFTP_ATTRIBUTES attrs;
	int rc = libssh2_sftp_stat(sftp_session, path, &attrs);

	if (rc == 0 && ((attrs.flags & LIBSSH2_SFTP_ATTR_PERMISSIONS) && ((attrs.permissions & LIBSSH2_SFTP_S_IFMT) == LIBSSH2_SFTP_S_IFDIR))) {
		return 0;
	}

	char dir_path[1024];
    char *dir_part;
    size_t path_len = strlen(path);

    strncpy(dir_path, path, sizeof(dir_path));
    dir_path[path_len] = '\0';  // Null-terminate the path string

    char current_path[1024];  // Ensure each path part is safely copied into current_path
    current_path[0] = '\0';   // Initialize the current_path as empty
    // Check each part of the path and create the directories as needed
    for (dir_part = strtok(dir_path, "/"); dir_part != NULL; dir_part = strtok(NULL, "/")) {
        // Append the directory part to the current path with a separator
        if (strlen(current_path) > 0) {
            strcat(current_path, "/");
        }
        strcat(current_path, dir_part);

		LIBSSH2_SFTP_ATTRIBUTES directory_attrs;
		int rc = libssh2_sftp_stat(sftp_session, current_path, &directory_attrs);

		if (rc == 0 && ((directory_attrs.flags & LIBSSH2_SFTP_ATTR_PERMISSIONS) && ((directory_attrs.permissions & LIBSSH2_SFTP_S_IFMT) != LIBSSH2_SFTP_S_IFDIR))) {
			/* fprintf(stderr, "Failed to create directory, path exists and is not a directory: %s\n", current_path); */
			return 1;
		}

		if (rc != 0) {
			// Attempt to create the directory
			if (libssh2_sftp_mkdir(sftp_session, current_path, LIBSSH2_SFTP_S_IRUSR | LIBSSH2_SFTP_S_IWUSR | LIBSSH2_SFTP_S_IXUSR) != 0) {
				/* fprintf(stderr, "Failed to create directory here: %s\n", current_path); */
				return 1;
			}

			/* printf("Created directory: %s\n", current_path); */
		}
	}

    return 0;
}

int sftp_remove_path_recursive(LIBSSH2_SFTP *sftp_session, const char *path, char **err_msg) {
    LIBSSH2_SFTP_ATTRIBUTES stat_attrs;
    if (!libssh2_sftp_stat(sftp_session, path, &stat_attrs) == 0) {
		unsigned long err = libssh2_sftp_last_error(sftp_session);
		if (err == LIBSSH2_FX_NO_SUCH_FILE) {
			return 0;
		}
    }

    LIBSSH2_SFTP_HANDLE *dir;
    char buffer[512];

    // Try to unlink the path as a file
    if (libssh2_sftp_unlink(sftp_session, path) == 0) {
        return 0;
    }

    // Try opening the directory
    dir = libssh2_sftp_opendir(sftp_session, path);
    if (!dir) {
        // Try removing as an empty directory
        if (libssh2_sftp_rmdir(sftp_session, path) == 0) {
            return 0;
        }

		asprintf(err_msg, "Failed to open or remove path: %s", path);
        return -1;
    }

    while (1) {
        LIBSSH2_SFTP_ATTRIBUTES attrs;
        char entry[256];
        int rc = libssh2_sftp_readdir(dir, entry, sizeof(entry), &attrs);
        if (rc <= 0) break; // No more entries

        // Skip "." and ".."
        if (strcmp(entry, ".") == 0 || strcmp(entry, "..") == 0)
            continue;

        // Construct full path
        snprintf(buffer, sizeof(buffer), "%s/%s", path, entry);

        if (LIBSSH2_SFTP_S_ISDIR(attrs.permissions)) {
            // Recursive call for subdirectory
            if (sftp_remove_path_recursive(sftp_session, buffer, err_msg) != 0) {
                libssh2_sftp_closedir(dir);
                return -1;
            }
        } else {
            // Delete file
            if (libssh2_sftp_unlink(sftp_session, buffer) != 0) {
				asprintf(err_msg, "Failed to delete file: %s", buffer);
                libssh2_sftp_closedir(dir);
                return -1;
            }
        }
    }

    libssh2_sftp_closedir(dir);

    // Now remove the parent directory
    if (libssh2_sftp_rmdir(sftp_session, path) != 0) {
		asprintf(err_msg, "Failed to remove directory: %s", path);
        return -1;
    }

    return 0;
}

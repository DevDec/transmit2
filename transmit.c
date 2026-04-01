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
#include <sys/select.h>
#include <errno.h>

#define SERVER_PORT 22

static int resolve_hostname(const char *hostname, struct sockaddr_in *sin) {
    struct addrinfo hints, *result, *rp;
    int rc;

    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;

    rc = getaddrinfo(hostname, "22", &hints, &result);
    if (rc != 0) {
        fprintf(stderr, "DEBUG: getaddrinfo failed: %s\n", gai_strerror(rc));
        return -1;
    }

    for (rp = result; rp != NULL; rp = rp->ai_next) {
        if (rp->ai_family == AF_INET) {
            memcpy(sin, rp->ai_addr, sizeof(struct sockaddr_in));
            sin->sin_port = htons(22);
            freeaddrinfo(result);
            return 0;
        }
    }

    fprintf(stderr, "DEBUG: No IPv4 address found for hostname\n");
    freeaddrinfo(result);
    return -1;
}

int init_sftp_session(const char *hostname, const char *username, const char *privkey_path, const char *pubkey_path, LIBSSH2_SFTP **sftp_session, LIBSSH2_SESSION **session, int *sock) {
    int rc;
    struct sockaddr_in sin;

    rc = libssh2_init(0);
    if (rc != 0) {
        return -1;
    }

    *sock = socket(AF_INET, SOCK_STREAM, 0);
    if (*sock < 0) {
        return -1;
    }

    if (resolve_hostname(hostname, &sin) != 0) {
        close(*sock);
        return -1;
    }

    if (connect(*sock, (struct sockaddr*)(&sin), sizeof(struct sockaddr_in)) != 0) {
        close(*sock);
        return -1;
    }

    *session = libssh2_session_init();
    if (libssh2_session_handshake(*session, *sock)) {
        close(*sock);
        return -1;
    }

    const char *passphrase = NULL;
    if (libssh2_userauth_publickey_fromfile(*session, username, pubkey_path, privkey_path, passphrase)) {
        char *err_msg;
        int err_len;
        int err = libssh2_session_last_error(*session, &err_msg, &err_len, 0);
        fprintf(stderr, "DEBUG: Key auth failed, libssh2 error %d: %s\n", err, err_msg);
        close(*sock);
        return -1;
    }

    *sftp_session = libssh2_sftp_init(*session);
    if (!(*sftp_session)) {
        close(*sock);
        return -1;
    }

    return 0;
}

int init_sftp_session_password(const char *hostname, const char *username, const char *password, LIBSSH2_SFTP **sftp_session, LIBSSH2_SESSION **session, int *sock) {
    int rc;
    struct sockaddr_in sin;
    memset(&sin, 0, sizeof(sin));

    fprintf(stderr, "DEBUG: Initializing libssh2...\n");
    rc = libssh2_init(0);
    if (rc != 0) {
        fprintf(stderr, "DEBUG: libssh2_init failed: %d\n", rc);
        return -1;
    }

    fprintf(stderr, "DEBUG: Creating socket...\n");
    *sock = socket(AF_INET, SOCK_STREAM, 0);
    if (*sock < 0) {
        fprintf(stderr, "DEBUG: socket creation failed\n");
        return -1;
    }

    fprintf(stderr, "DEBUG: Resolving hostname: %s...\n", hostname);
    if (resolve_hostname(hostname, &sin) != 0) {
        fprintf(stderr, "DEBUG: Failed to resolve hostname: %s\n", hostname);
        close(*sock);
        return -1;
    }

    fprintf(stderr, "DEBUG: Connecting to %s:22...\n", hostname);
    if (connect(*sock, (struct sockaddr*)(&sin), sizeof(struct sockaddr_in)) != 0) {
        fprintf(stderr, "DEBUG: connect failed: %s\n", strerror(errno));
        close(*sock);
        return -1;
    }

    fprintf(stderr, "DEBUG: Creating SSH session...\n");
    *session = libssh2_session_init();

    fprintf(stderr, "DEBUG: Starting SSH handshake...\n");
    if (libssh2_session_handshake(*session, *sock)) {
        fprintf(stderr, "DEBUG: SSH handshake failed\n");
        close(*sock);
        return -1;
    }

    fprintf(stderr, "DEBUG: Authenticating with password...\n");
    if (libssh2_userauth_password(*session, username, password)) {
        fprintf(stderr, "DEBUG: Password authentication failed\n");
        char *err_msg;
        int err_len;
        int err = libssh2_session_last_error(*session, &err_msg, &err_len, 0);
        fprintf(stderr, "DEBUG: libssh2 error %d: %s\n", err, err_msg);
        close(*sock);
        return -1;
    }

    fprintf(stderr, "DEBUG: Initializing SFTP...\n");
    *sftp_session = libssh2_sftp_init(*session);
    if (!(*sftp_session)) {
        fprintf(stderr, "DEBUG: SFTP init failed\n");
        close(*sock);
        return -1;
    }

    fprintf(stderr, "DEBUG: Connection successful!\n");
    return 0;
}

int is_socket_closed(int sock) {
    char buf;
    int rc = recv(sock, &buf, 1, MSG_PEEK);
    if (rc == 0) return 1;
    else if (rc < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) return 0;
        return 1;
    }
    return 0;
}

int is_sftp_session_alive(LIBSSH2_SFTP *sftp_session, LIBSSH2_SESSION *session) {
    LIBSSH2_SFTP_ATTRIBUTES attrs;
    int rc = libssh2_sftp_stat_ex(sftp_session, "/", 1, LIBSSH2_SFTP_STAT, &attrs);
    if (rc == 0) return 1;

    int err = libssh2_session_last_error(session, NULL, NULL, 0);
    if (err == LIBSSH2_ERROR_SOCKET_DISCONNECT ||
        err == LIBSSH2_ERROR_CHANNEL_CLOSED ||
        err == LIBSSH2_ERROR_SOCKET_SEND ||
        err == LIBSSH2_ERROR_SOCKET_TIMEOUT) {
        return 0;
    }
    return 1;
}

void close_sftp_session(LIBSSH2_SFTP *sftp_session, LIBSSH2_SESSION *session, int sock) {
    libssh2_sftp_shutdown(sftp_session);
    libssh2_session_disconnect(session, "Normal Shutdown");
    libssh2_session_free(session);
    close(sock);
    libssh2_exit();
}

bool is_directory(const char *path) {
    struct stat path_stat;
    if (stat(path, &path_stat) != 0) return false;
    return S_ISDIR(path_stat.st_mode);
}

int upload_file(LIBSSH2_SFTP *sftp_session, const char *local_file, const char *remote_file, char **err_msg) {
    char path_copy[1024];
    snprintf(path_copy, sizeof(path_copy), "%s", remote_file);

    char local_path_copy[1024];
    snprintf(local_path_copy, sizeof(local_path_copy), "%s", local_file);

    if (is_directory(local_path_copy)) {
        asprintf(err_msg, "Uploading directories is not supported: %s", local_path_copy);
        return 1;
    }

    char *dir_path = dirname(path_copy);
    if (create_remote_directory_recursively(sftp_session, dir_path)) {
        asprintf(err_msg, "Failed to create remote directory recursively: %s", dir_path);
        return 1;
    }

    LIBSSH2_SFTP_HANDLE *sftp_handle = libssh2_sftp_open(
        sftp_session,
        remote_file,
        LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC,
        LIBSSH2_SFTP_S_IRUSR | LIBSSH2_SF

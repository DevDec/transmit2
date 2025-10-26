// transmit.h
#ifndef TRANSMIT_H
#define TRANSMIT_H

bool is_directory(const char *path);
int create_remote_directory_recursively(LIBSSH2_SFTP *sftp_session, const char *path);
int create_directory(LIBSSH2_SFTP *sftp_session, const char *directory);
int init_sftp_session(const char *hostname, const char *username, const char *privkey_path, LIBSSH2_SFTP **sftp_session, LIBSSH2_SESSION **session, int *sock);
void close_sftp_session(LIBSSH2_SFTP *sftp_session, LIBSSH2_SESSION *session, int sock);
int upload_file(LIBSSH2_SFTP *sftp_session, const char *local_file, const char *remote_file, char **err_msg);
int sftp_remove_path_recursive(LIBSSH2_SFTP *sftp_session, const char *path, char **err_msg);
int is_sftp_session_alive(LIBSSH2_SFTP *sftp_session, LIBSSH2_SESSION *session);
int is_socket_closed(int sock);
int init_sftp_session_password(const char *hostname, const char *username, const char *password, 
                                LIBSSH2_SFTP **sftp_session, LIBSSH2_SESSION **session, int *sock);

#endif

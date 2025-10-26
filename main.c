#include <stdbool.h>
#include <libssh2.h>
#include <libssh2_sftp.h>
#include "transmit.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

int main() {
    char hostname[256], username[128], auth_method[16];
    char privkey_path[256], password[256];
    char input[512];
    char command[32], arg1[256], arg2[256];
    LIBSSH2_SFTP *sftp_session = NULL;
    LIBSSH2_SESSION *session = NULL;
    int sock;
    
    printf("Enter SSH hostname: ");
    fflush(stdout);
    if (!fgets(hostname, sizeof(hostname), stdin)) {
        printf("0|Failed to read hostname\n");
        return 1;
    }
    hostname[strcspn(hostname, "\n")] = 0;
    
    printf("Enter SSH username: ");
    fflush(stdout);
    if (!fgets(username, sizeof(username), stdin)) {
        printf("0|Failed to read username\n");
        return 1;
    }
    username[strcspn(username, "\n")] = 0;
    
    printf("Authentication method (key/password): ");
    fflush(stdout);
    if (!fgets(auth_method, sizeof(auth_method), stdin)) {
        printf("0|Failed to read auth method\n");
        return 1;
    }
    auth_method[strcspn(auth_method, "\n")] = 0;
    
	if (strcmp(auth_method, "password") == 0) {
		printf("Enter password: ");
		fflush(stdout);
		if (!fgets(password, sizeof(password), stdin)) {
			printf("0|Failed to read password\n");
			return 1;
		}
		password[strcspn(password, "\n")] = 0;

		printf("DEBUG: Attempting password authentication...\n");  // ADD THIS
		fflush(stdout);

		if (init_sftp_session_password(hostname, username, password, &sftp_session, &session, &sock) != 0) {
			printf("0|Failed to establish SFTP session with password\n");
			fflush(stdout);
			return 1;
		}

		printf("DEBUG: Password authentication succeeded\n");  // ADD THIS
		fflush(stdout);
	} else {
        printf("Enter path to private key: ");
        fflush(stdout);
        if (!fgets(privkey_path, sizeof(privkey_path), stdin)) {
            printf("0|Failed to read private key path\n");
            return 1;
        }
        privkey_path[strcspn(privkey_path, "\n")] = 0;
        
        if (init_sftp_session(hostname, username, privkey_path, &sftp_session, &session, &sock) != 0) {
            printf("0|Failed to establish SFTP session with key\n");
            return 1;
        }
    }
    
    printf("1|Connected to %s as %s\n", hostname, username);
    
    while (1) {
        if (!is_sftp_session_alive(sftp_session, session)) {
            printf("0|SFTP session lost\n");
            break;
        }
        
        printf("Command (upload <local> <remote> | remove <remote> | exit): ");
        fflush(stdout);
        
        if (!fgets(input, sizeof(input), stdin)) {
            printf("0|Failed to read input\n");
            break;
        }
        
        input[strcspn(input, "\n")] = 0;
        command[0] = arg1[0] = arg2[0] = 0;
        int num = sscanf(input, "%31s %255s %255s", command, arg1, arg2);
        
        if (strcmp(command, "exit") == 0) {
            printf("1|Exiting shell\n");
            break;
        } else if (strcmp(command, "upload") == 0 && num == 3) {
            char *err_msg = NULL;
            if (upload_file(sftp_session, arg1, arg2, &err_msg) == 0) {
                printf("1|Upload succeeded\n");
            } else {
                printf("0|%s\n", err_msg ? err_msg : "Upload failed");
                free(err_msg);
            }
        } else if (strcmp(command, "remove") == 0 && num == 2) {
            char *err_msg = NULL;
            if (sftp_remove_path_recursive(sftp_session, arg1, &err_msg) == 0) {
                printf("1|Remove succeeded\n");
            } else {
                printf("0|%s\n", err_msg ? err_msg : "Remove failed");
                free(err_msg);
            }
        } else {
            printf("0|Unknown command or incorrect usage\n");
        }
    }
    
    close_sftp_session(sftp_session, session, sock);
    printf("1|Session closed\n");
    return 0;
}

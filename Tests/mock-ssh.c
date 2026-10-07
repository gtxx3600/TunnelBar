// 模拟 OpenSSH 的握手、转发确认与失败输出，不建立网络连接。
#include <unistd.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    const char *mode = "ready";
    for (int i = 1; i < argc; i++)
        if (strncmp(argv[i], "--fixture-mode=", 15) == 0) mode = argv[i] + 15;
    usleep(50000);
    if (strcmp(mode, "auth") == 0) { fprintf(stderr, "fixture: Permission denied (publickey).\n"); return 255; }
    if (strcmp(mode, "network") == 0) { fprintf(stderr, "ssh: connect to host fixture port 22: Connection timed out\n"); return 255; }
    if (strcmp(mode, "port") == 0) { fprintf(stderr, "bind [127.0.0.1]:18080: Address already in use\n"); return 255; }
    if (strcmp(mode, "silent") == 0) { for (;;) pause(); }
    if (strcmp(mode, "ready-warning") == 0) fprintf(stderr, "Warning: Identity file /unused not accessible: No such file or directory.\n");
    if (strcmp(mode, "delayed") == 0) usleep(600000);
    fprintf(stderr, "Authenticated to fixture ([127.0.0.1]:22) using publickey.\n");
    int remote = 0;
    for (int i = 1; i + 1 < argc; i++) {
        if (strcmp(argv[i], "-L") == 0 || strcmp(argv[i], "-D") == 0) {
            char copy[1024]; snprintf(copy, sizeof(copy), "%s", argv[i + 1]);
            char *parts[16]; int n = 0;
            for (char *p = strtok(copy, ":"); p != NULL && n < 16; p = strtok(NULL, ":")) parts[n++] = p;
            if (n > 0) {
                const char *port = strcmp(argv[i], "-D") == 0 ? parts[n - 1] : (n == 3 ? parts[0] : parts[1]);
                fprintf(stderr, "debug1: Local forwarding listening on 127.0.0.1 port %s.\n", port);
            }
        }
        if (strcmp(argv[i], "-R") == 0) { remote++; fprintf(stderr, "debug1: Remote connections from LOCALHOST:9000 forwarded to local address 127.0.0.1:9000\n"); }
    }
    fprintf(stderr, "debug1: Entering interactive session.\n");
    if (strcmp(mode, "remote-delayed") == 0) usleep(600000);
    for (int i = 1; i + 1 < argc; i++) {
        if (strcmp(argv[i], "-R") != 0) continue;
        char copy[1024]; snprintf(copy, sizeof(copy), "%s", argv[i + 1]);
        char *end = strrchr(copy, ':'); if (end) *end = 0;
        end = strrchr(copy, ':'); if (end) *end = 0;
        fprintf(stderr, "debug1: remote forward success for: listen %s, connect 127.0.0.1:9000\n", copy);
    }
    if (remote) fprintf(stderr, "debug1: forwarding_success: all expected forwarding replies received\n");
    for (;;) pause();
}

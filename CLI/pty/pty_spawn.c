#include "pty_spawn.h"

#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

pid_t pw_spawn_pty(const char *path, char *const argv[], char *const envp[],
                   const char *cwd, unsigned short cols, unsigned short rows,
                   int *master_out) {
    struct winsize ws = {0};
    ws.ws_col = cols ? cols : 80;
    ws.ws_row = rows ? rows : 24;

    int master = -1;
    pid_t pid = forkpty(&master, NULL, NULL, &ws);
    if (pid < 0) return -1;

    if (pid == 0) {
        // Child: forkpty already did setsid + TIOCSCTTY + dup2.
        // Reset signal dispositions the parent may have changed.
        signal(SIGINT, SIG_DFL);
        signal(SIGQUIT, SIG_DFL);
        signal(SIGPIPE, SIG_DFL);
        signal(SIGCHLD, SIG_DFL);
        signal(SIGHUP, SIG_DFL);
        sigset_t none;
        sigemptyset(&none);
        sigprocmask(SIG_SETMASK, &none, NULL);
        if (cwd && cwd[0]) {
            if (chdir(cwd) != 0) chdir(getenv("HOME") ? getenv("HOME") : "/");
        }
        execve(path, argv, envp);
        _exit(127);
    }

    int flags = fcntl(master, F_GETFD);
    fcntl(master, F_SETFD, flags | FD_CLOEXEC);
    *master_out = master;
    return pid;
}

int pw_open_pty(unsigned short cols, unsigned short rows, int *master_out, int *slave_out,
                char *name_out, int name_len) {
    struct winsize ws = {0};
    ws.ws_col = cols ? cols : 80;
    ws.ws_row = rows ? rows : 24;
    int master = -1, slave = -1;
    if (openpty(&master, &slave, NULL, NULL, &ws) != 0) return -1;
    const char *name = ttyname(slave);
    if (!name || (int)strlen(name) >= name_len) { close(master); close(slave); return -1; }
    strcpy(name_out, name);
    fcntl(master, F_SETFD, fcntl(master, F_GETFD) | FD_CLOEXEC);
    fcntl(slave, F_SETFD, fcntl(slave, F_GETFD) | FD_CLOEXEC);
    *master_out = master;
    *slave_out = slave;
    return 0;
}

pid_t pw_exec_on_tty(const char *path, char *const argv[], char *const envp[],
                     const char *cwd, const char *tty) {
    pid_t pid = fork();
    if (pid != 0) return pid;
    // Child: a new session whose controlling terminal is the slave.
    setsid();
    int fd = open(tty, O_RDWR);
    if (fd < 0) _exit(126);
    ioctl(fd, TIOCSCTTY, 0);
    dup2(fd, 0);
    dup2(fd, 1);
    dup2(fd, 2);
    if (fd > 2) close(fd);
    signal(SIGINT, SIG_DFL);
    signal(SIGQUIT, SIG_DFL);
    signal(SIGPIPE, SIG_DFL);
    signal(SIGCHLD, SIG_DFL);
    signal(SIGHUP, SIG_DFL);
    signal(SIGTERM, SIG_DFL);
    sigset_t none;
    sigemptyset(&none);
    sigprocmask(SIG_SETMASK, &none, NULL);
    if (cwd && cwd[0]) {
        if (chdir(cwd) != 0) chdir(getenv("HOME") ? getenv("HOME") : "/");
    }
    execve(path, argv, envp);
    _exit(127);
}

pid_t pw_tty_session(int master) {
    return tcgetsid(master);
}

int pw_set_winsize(int fd, unsigned short cols, unsigned short rows) {
    struct winsize ws = {0};
    ws.ws_col = cols;
    ws.ws_row = rows;
    return ioctl(fd, TIOCSWINSZ, &ws);
}

int pw_get_winsize(int fd, unsigned short *cols, unsigned short *rows) {
    struct winsize ws = {0};
    if (ioctl(fd, TIOCGWINSZ, &ws) != 0) return -1;
    *cols = ws.ws_col;
    *rows = ws.ws_row;
    return 0;
}

pid_t pw_foreground_pgrp(int fd) { return tcgetpgrp(fd); }

int pw_pid_cwd(pid_t pid, char *buf, int buflen) {
    struct proc_vnodepathinfo info;
    int n = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, sizeof(info));
    if (n <= 0) return -1;
    strlcpy(buf, info.pvi_cdir.vip_path, buflen);
    return 0;
}

int pw_pid_name(pid_t pid, char *buf, int buflen) {
    return proc_name(pid, buf, buflen) > 0 ? 0 : -1;
}

static struct termios saved;
static int saved_ok = 0;

int pw_tty_raw(int fd) {
    if (tcgetattr(fd, &saved) != 0) return -1;
    saved_ok = 1;
    struct termios raw = saved;
    cfmakeraw(&raw);
    return tcsetattr(fd, TCSANOW, &raw);
}

void pw_tty_restore(int fd) {
    if (saved_ok) tcsetattr(fd, TCSANOW, &saved);
}

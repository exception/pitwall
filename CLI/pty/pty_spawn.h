#ifndef PITWALL_PTY_SPAWN_H
#define PITWALL_PTY_SPAWN_H

#include <sys/types.h>

/// Fork a child attached to a new PTY. All strings must be prepared by the
/// caller; nothing between fork and exec allocates.
///   path: executable path, argv/envp: NULL-terminated, cwd may be NULL.
/// Returns the child pid (>0) and writes the master fd, or -1 on error.
pid_t pw_spawn_pty(const char *path, char *const argv[], char *const envp[],
                   const char *cwd, unsigned short cols, unsigned short rows,
                   int *master_out);

/// Opens a PTY pair at the given size. Writes both fds (close-on-exec) and
/// the slave's device path. Returns 0 on success.
int pw_open_pty(unsigned short cols, unsigned short rows, int *master_out, int *slave_out,
                char *name_out, int name_len);

/// Fork a child that becomes a session leader with `tty` as its controlling
/// terminal and stdio, then execs. Returns the child pid, or -1.
pid_t pw_exec_on_tty(const char *path, char *const argv[], char *const envp[],
                     const char *cwd, const char *tty);

/// Session id of the terminal's controlling process (the shell once it has
/// claimed the slave), or -1 while none has.
pid_t pw_tty_session(int master);

int pw_set_winsize(int fd, unsigned short cols, unsigned short rows);

/// Foreground process group of the terminal, or -1.
pid_t pw_foreground_pgrp(int fd);

/// Current working directory of a pid into buf. Returns 0 on success.
int pw_pid_cwd(pid_t pid, char *buf, int buflen);

/// Short process name of a pid into buf. Returns 0 on success.
int pw_pid_name(pid_t pid, char *buf, int buflen);

/// Puts stdin into raw mode, saving the old state. Returns 0 on success.
int pw_tty_raw(int fd);
void pw_tty_restore(int fd);
int pw_get_winsize(int fd, unsigned short *cols, unsigned short *rows);

#endif

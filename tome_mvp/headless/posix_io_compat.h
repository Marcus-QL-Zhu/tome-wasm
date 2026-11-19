#ifndef TOME_POSIX_IO_COMPAT_H
#define TOME_POSIX_IO_COMPAT_H
#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include <sys/prctl.h>
#include <sys/types.h>
#include <unistd.h>
#define _fdopen fdopen
#define _dup dup
#define _fileno fileno
/* Microsoft _dup2 returns zero on success; POSIX dup2 returns newfd. */
static inline int tome_posix_dup2(int oldfd, int newfd) {
    return dup2(oldfd, newfd) < 0 ? -1 : 0;
}
#define _dup2 tome_posix_dup2
/* The bridge supplies its PID. Check it after installing the death signal to
   close the race where the service dies between fork and this constructor. */
__attribute__((constructor)) static void tome_require_owner(void) {
    const char *raw = getenv("TOME_OWNER_PID");
    char *end = NULL;
    long expected;
    if (!raw || !*raw) _exit(126);
    expected = strtol(raw, &end, 10);
    if (*end || expected <= 1 || (pid_t)expected != expected) _exit(126);
    if (prctl(PR_SET_PDEATHSIG, SIGKILL) != 0) _exit(126);
    if (getppid() != (pid_t)expected) _exit(126);
}
#endif

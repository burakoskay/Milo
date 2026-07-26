#include "AntiDebug.h"
#include <libproc.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ptrace.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <unistd.h>

__attribute__((constructor))
static void mh_deny_attach_constructor(void) {
#if !defined(DEBUG) && !defined(AD_HOC)
    ptrace(PT_DENY_ATTACH, 0, 0, 0);
#endif
}

int mh_antidebug_is_traced(void) {
    struct kinfo_proc info;
    size_t info_size = sizeof(info);
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid() };
    if (sysctl(mib, 4, &info, &info_size, 0, 0) != 0) {
        return 0;
    }
    return (info.kp_proc.p_flag & P_TRACED) != 0;
}

int mh_antidebug_parent_is_suspicious(void) {
    pid_t parent = getppid();
    char path[PROC_PIDPATHINFO_MAXSIZE];
    int result = proc_pidpath(parent, path, sizeof(path));
    if (result <= 0) {
        return 0;
    }

    if (strstr(path, "lldb") != 0 || strstr(path, "debugserver") != 0 || strstr(path, "gdb") != 0) {
        return 1;
    }
    return 0;
}

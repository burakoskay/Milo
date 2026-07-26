#include "AntiInstrumentation.h"
#include <arpa/inet.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <netinet/in.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static int mh_has_suspicious_dylib(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t index = 0; index < count; index++) {
        const char *name = _dyld_get_image_name(index);
        if (name == 0) {
            continue;
        }
        if (strstr(name, "frida") != 0 || strstr(name, "cycript") != 0 || strstr(name, "substrate") != 0 || strstr(name, "objection") != 0) {
            return 1;
        }
    }
    return 0;
}

static int mh_frida_port_open(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return 0;
    }

    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons(27042);
    inet_pton(AF_INET, "127.0.0.1", &address.sin_addr);
    int result = connect(fd, (struct sockaddr *)&address, sizeof(address));
    close(fd);
    return result == 0 ? 1 : 0;
}

static int mh_exception_ports_present(void) {
    exception_mask_t masks[32];
    mach_msg_type_number_t count = 32;
    exception_handler_t ports[32];
    exception_behavior_t behaviors[32];
    thread_state_flavor_t flavors[32];
    kern_return_t result = task_get_exception_ports(
        mach_task_self(),
        EXC_MASK_ALL,
        masks,
        &count,
        ports,
        behaviors,
        flavors
    );
    if (result != KERN_SUCCESS) {
        return 0;
    }

    for (mach_msg_type_number_t index = 0; index < count; index++) {
        if (MACH_PORT_VALID(ports[index])) {
            return 1;
        }
    }
    return 0;
}

int mh_instrumentation_signal_count(void) {
    int signals = 0;
    signals += mh_has_suspicious_dylib();
    signals += mh_frida_port_open();
    signals += mh_exception_ports_present();
    return signals;
}

int mh_instrumentation_is_compromised(void) {
    return mh_instrumentation_signal_count() >= 3 ? 1 : 0;
}

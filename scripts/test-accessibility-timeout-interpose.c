#include <ApplicationServices/ApplicationServices.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdlib.h>
#include <unistd.h>

static AXError observeFocusedWindow(AXUIElementRef element, CFStringRef attribute, CFTypeRef *value) {
    const char *target = getenv("HISTORY_AX_TEST_PID");
    const char *arm = getenv("HISTORY_AX_TEST_ARM");
    const char *marker = getenv("HISTORY_AX_TEST_ENTERED");
    const char *returned = getenv("HISTORY_AX_TEST_RETURNED");
    pid_t pid = 0;
    if (target && arm && marker && returned && pthread_main_np() && CFEqual(attribute, kAXFocusedWindowAttribute)
        && AXUIElementGetPid(element, &pid) == kAXErrorSuccess && pid == atoi(target)
        && unlink(arm) == 0) {
        int fd = open(marker, O_WRONLY | O_CREAT | O_EXCL, 0600);
        if (fd >= 0) close(fd);
        AXError result = AXUIElementCopyAttributeValue(element, attribute, value);
        fd = open(returned, O_WRONLY | O_CREAT | O_EXCL, 0600);
        if (fd >= 0) close(fd);
        return result;
    }
    return AXUIElementCopyAttributeValue(element, attribute, value);
}

__attribute__((used, section("__DATA,__interpose")))
static const struct {
    AXError (*replacement)(AXUIElementRef, CFStringRef, CFTypeRef *);
    AXError (*original)(AXUIElementRef, CFStringRef, CFTypeRef *);
} interpose = {observeFocusedWindow, AXUIElementCopyAttributeValue};

#include <dispatch/dispatch.h>
#include <stdio.h>
#include <stdlib.h>
#include <xpc/xpc.h>

int main(void)
{
    dispatch_queue_t queue = dispatch_queue_create("fanfan.local.negative-test", 0);
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block int rejected = 0;
    xpc_connection_t connection = xpc_connection_create_mach_service(
        "com.huangyincan.fanfan.local.helper", queue,
        XPC_CONNECTION_MACH_SERVICE_PRIVILEGED);
    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) { (void)event; });
    xpc_connection_resume(connection);
    xpc_object_t message = xpc_dictionary_create_empty();
    xpc_dictionary_set_string(message, "line", "PINGV2");
    xpc_connection_send_message_with_reply(connection, message, queue, ^(xpc_object_t reply) {
        // A peer requirement failure is delivered as INTERRUPTED on macOS 27.
        // Verify the real app can PING before and after this negative check.
        rejected = xpc_get_type(reply) == XPC_TYPE_ERROR &&
            (reply == XPC_ERROR_CONNECTION_INVALID || reply == XPC_ERROR_CONNECTION_INTERRUPTED);
        dispatch_semaphore_signal(done);
    });
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC))) {
        fprintf(stderr, "FAIL: negative test timed out\n"); return 2;
    }
    printf("%s: unpinned client with the same identifier is rejected\n", rejected ? "PASS" : "FAIL");
    return rejected ? 0 : 1;
}

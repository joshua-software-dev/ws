const std = @import("std");
const os = std.os;
const ws2_32 = os.windows.ws2_32;

const timeval_from_ns = @import("common.zig").timeval_from_ns;


pub extern "ws2_32" fn select(
    nfds: i32,
    readfds: ?*ws2_32.fd_set,
    writefds: ?*ws2_32.fd_set,
    exceptfds: ?*ws2_32.fd_set,
    timeout: ?*const std.os.timeval,
) callconv(os.windows.WINAPI) i32;

pub fn wait_until_socket_readable(sock_fd: os.socket_t, timeout_nano_seconds: ?u64) !bool {
    var fd_set = ws2_32.fd_set{ .fd_count = 1, .fd_array = undefined };
    fd_set.fd_array[0] = sock_fd;

    const tv = timeval_from_ns(timeout_nano_seconds);

    const rc = select(0, &fd_set, null, null, if (timeout_nano_seconds != null) &tv else null);
    if (rc == ws2_32.SOCKET_ERROR) {
        return switch (ws2_32.WSAGetLastError()) {
            .WSANOTINITIALISED => unreachable, // not initialized WSA
            .WSAEFAULT => unreachable,
            .WSAENETDOWN => return error.NetworkSubsystemFailed,
            .WSAEINVAL => return error.SocketNotListening,
            .WSAEINTR => return error.SocketCanceled,
            .WSAEINPROGRESS => return error.SocketCallInProgress,
            .WSAENOTSOCK => return error.InvalidSocketInDescriptorSet,
            else => |err| return os.windows.unexpectedWSAError(err),
        };
    }
    if (rc == 0) return false; // timeout
    std.debug.assert(rc == 1);
    return true;
}

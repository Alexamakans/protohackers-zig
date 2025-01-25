const std = @import("std");
const log = std.log.scoped(.reader);
const net = std.net;
const posix = std.posix;

pub const SocketWriter = struct {
    socket: posix.socket_t,
    const Self = @This();
    pub fn write(self: Self, data: []u8) posix.WriteError!usize {
        return posix.write(self.socket, data);
    }
};

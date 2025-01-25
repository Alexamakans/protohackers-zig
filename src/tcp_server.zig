const std = @import("std");
const net = std.net;
const posix = std.posix;

const Reader = @import("readers.zig").Reader;

pub const Server = struct {
    socket: posix.socket_t,
    const Self = @This();
};

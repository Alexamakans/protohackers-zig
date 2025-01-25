const std = @import("std");
const net = std.net;
const posix = std.posix;

pub fn handle(socket: posix.socket_t, client_address: net.Address) !void {
    var buf: [128]u8 = undefined;
    std.debug.print("{} connected\n", .{client_address});

    const timeout = posix.timeval{ .tv_sec = 5, .tv_usec = 0 };
    try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &std.mem.toBytes(timeout));
    try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.SNDTIMEO, &std.mem.toBytes(timeout));

    const stream = net.Stream{ .handle = socket };
    defer stream.close();
    while (true) {
        const read = try stream.read(&buf);
        if (read == 0) {
            break;
        }
        try stream.writeAll(buf[0..read]);
    }
}

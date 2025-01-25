const std = @import("std");
const net = std.net;
const posix = std.posix;

pub fn main() !void {
    const address = try net.Address.parseIp("0.0.0.0", 17777);

    const tpe: u32 = posix.SOCK.STREAM;
    const protocol = posix.IPPROTO.TCP;
    const listener = try posix.socket(address.any.family, tpe, protocol);
    defer posix.close(listener);

    try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    try posix.bind(listener, &address.any, address.getOsSockLen());
    try posix.listen(listener, 128);

    var buf: [128]u8 = undefined;
    while (true) {
        var client_address: net.Address = undefined;
        var client_address_len: posix.socklen_t = @sizeOf(net.Address);

        const socket = posix.accept(listener, &client_address.any, &client_address_len, 0) catch |err| {
            std.debug.print("error accept: {}\n", .{err});
            continue;
        };

        defer posix.close(socket);

        std.debug.print("{} connected\n", .{client_address});

        const timeout = posix.timeval{ .tv_sec = 2, .tv_usec = 500_000 };
        try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &std.mem.toBytes(timeout));
        try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.SNDTIMEO, &std.mem.toBytes(timeout));

        const stream = net.Stream{ .handle = socket };
        while (true) {
            const read = try stream.read(&buf);
            if (read == 0) {
                break;
            }
            std.debug.print("received: {s}\n", .{buf[0..read]});
            try stream.writeAll(buf[0..read]);
        }
    }
}

fn write(socket: posix.socket_t, msg: []const u8) !void {
    var pos: usize = 0;
    while (pos < msg.len) {
        const written = try posix.write(socket, msg[pos..]);
        if (written == 0) {
            return error.Closed;
        }
        pos += written;
    }
}

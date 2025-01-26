const std = @import("std");
const Allocator = std.mem.Allocator;
const net = std.net;
const posix = std.posix;

pub fn handle(socket: posix.socket_t) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var db = std.StringHashMap([]const u8).init(allocator);
    try db.put("version", "UDPDBv1");

    var buf: [8096]u8 = undefined;
    var response: [8096]u8 = undefined;
    while (true) {
        var client_address: net.Address = undefined;
        var client_address_len: posix.socklen_t = @sizeOf(net.Address);
        const len = try posix.recvfrom(socket, &buf, 0, &client_address.any, &client_address_len);
        const message = buf[0..len];
        std.debug.print("recv: '{s}'\n", .{message});
        if (std.mem.indexOfScalar(u8, message, '=')) |i| {
            const key = try allocator.dupe(u8, message[0..i]);
            if (std.mem.eql(u8, key, "version")) {
                allocator.free(key);
                continue;
            }
            // don't include the equals sign
            const value = try allocator.dupe(u8, message[i + 1 ..]);
            std.debug.print("inserting {s}={s}\n", .{ key, value });
            try db.put(key, value);
        } else if (db.get(message)) |value| {
            const written = (try std.fmt.bufPrint(&response, "{s}={s}", .{ message, value })).len;
            std.debug.print("responding to request: '{s}'\n", .{response[0..written]});
            const sent = try posix.sendto(socket, response[0..written], 0, &client_address.any, client_address_len);
            std.debug.print("sent {} bytes\n", .{sent});
        }
    }
}

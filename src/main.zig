const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log;
const net = std.net;
const process = std.process;
const posix = std.posix;

const arg_error_msg = "missing argument. specify test to run. i.e. 00, 01, ...";

const smoketest = @import("problems/0-smoketest.zig");
const primetime = @import("problems/1-primetime.zig");
const meanstoanend = @import("problems/2-meanstoanend.zig");
const budgetchat = @import("problems/3-budgetchat.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const args = try process.argsAlloc(gpa.allocator());
    defer process.argsFree(gpa.allocator(), args);

    if (args.len == 1) {
        log.err(arg_error_msg, .{});
        process.exit(1);
    }

    const option = std.fmt.parseInt(u8, args[1], 10) catch {
        log.err(arg_error_msg, .{});
        process.exit(1);
    };

    try run(option);
    if (option == 3) {
        budgetchat.deinit();
    }
}

fn run(problem: u8) !void {
    const address = try net.Address.parseIp("0.0.0.0", 17777);

    const socket_type: u32 = posix.SOCK.STREAM;
    const protocol = posix.IPPROTO.TCP;
    const listener = try posix.socket(address.any.family, socket_type, protocol);
    defer posix.close(listener);

    try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(i512, 1)));
    try posix.bind(listener, &address.any, address.getOsSockLen());
    try posix.listen(listener, 128);

    while (true) {
        var client_address: net.Address = undefined;
        var client_address_len: posix.socklen_t = @sizeOf(net.Address);

        const socket = posix.accept(listener, &client_address.any, &client_address_len, 0) catch |err| {
            std.debug.print("error accept: {}\n", .{err});
            continue;
        };

        switch (problem) {
            0 => {
                const thread = try std.Thread.spawn(.{}, smoketest.handle, .{ socket, client_address });
                thread.detach();
            },
            1 => {
                const thread = try std.Thread.spawn(.{}, primetime.handle, .{ socket, client_address });
                thread.detach();
            },
            2 => {
                const thread = try std.Thread.spawn(.{}, meanstoanend.handle, .{ socket, client_address });
                thread.detach();
            },
            3 => {
                const thread = try std.Thread.spawn(.{}, budgetchat.handle, .{ socket, client_address });
                thread.detach();
            },
            else => {
                std.debug.print("{} is not implemented in main yet", .{problem});
                return;
            },
        }
    }
}

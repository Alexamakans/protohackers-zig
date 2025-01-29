const std = @import("std");
const net = std.net;
const posix = std.posix;
const Allocator = std.mem.Allocator;
const DelimitedWriter = @import("../writers.zig").DelimitedWriter;
const DelimitedReader = @import("../readers.zig").DelimitedReader;
const Stream = @import("../stream.zig").Stream;

const tonysAddress = "7YWHMfk9JZe0LM0g1ZauHuiSxhI";

var nextUID = @as(usize, 0);
var mutex = std.Thread.Mutex{};

pub fn handle(socket: posix.socket_t, client_address: net.Address) !void {
    const timeout = posix.timeval{ .tv_sec = 1, .tv_usec = 0 };
    try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &std.mem.toBytes(timeout));
    try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.SNDTIMEO, &std.mem.toBytes(timeout));
    defer posix.close(socket);
    mutex.lock();
    const uid = nextUID;
    nextUID += 1;
    mutex.unlock();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator: Allocator = gpa.allocator();

    std.debug.print("{} connected\n", .{client_address});

    var client_reader = DelimitedReader.init(allocator, socket, '\n');
    defer client_reader.deinit();
    var client_writer = DelimitedWriter.create(socket, "\n");
    var client = Stream.create(client_reader.reader(), client_writer.writer());

    const upstream_socket = try connect_upstream();
    try posix.setsockopt(upstream_socket, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &std.mem.toBytes(timeout));
    try posix.setsockopt(upstream_socket, posix.SOL.SOCKET, posix.SO.SNDTIMEO, &std.mem.toBytes(timeout));
    defer posix.close(upstream_socket);
    var upstream_reader = DelimitedReader.init(allocator, upstream_socket, '\n');
    defer upstream_reader.deinit();
    var upstream_writer = DelimitedWriter.create(upstream_socket, "\n");
    var upstream = Stream.create(upstream_reader.reader(), upstream_writer.writer());

    {
        var done1 = false;
        var mut1 = std.Thread.Mutex{};
        var done2 = false;
        var mut2 = std.Thread.Mutex{};
        var relay_client_to_upstream_thread = try std.Thread.spawn(.{}, relay, .{ &done1, &mut1, uid, "C->S", allocator, &client, &upstream });
        defer relay_client_to_upstream_thread.join();
        var relay_upstream_to_client_thread = try std.Thread.spawn(.{}, relay, .{ &done2, &mut2, uid, "S->C", allocator, &upstream, &client });
        defer relay_upstream_to_client_thread.join();
        var closed1 = false;
        var closed2 = false;
        while (!closed1 or !closed2) {
            std.time.sleep(std.time.ns_per_ms * 50); // 50 ms
            {
                mut1.lock();
                defer mut1.unlock();
                if (done1) {
                    mut2.lock();
                    defer mut2.unlock();
                    std.debug.print("[{}] done1 is true, setting done2 to true\n", .{uid});
                    closed1 = true;
                    done2 = true;
                }
            }
            {
                mut2.lock();
                defer mut2.unlock();
                if (done2) {
                    mut1.lock();
                    defer mut1.unlock();
                    std.debug.print("[{}] done2 is true, setting done1 to true\n", .{uid});
                    closed2 = true;
                    done1 = true;
                }
            }
        }
    }
    std.debug.print("--------------- [{}] IS GONE ------------\n", .{uid});
}

fn relay(done: *bool, mut: *std.Thread.Mutex, uid: usize, s_type: []const u8, allocator: Allocator, src: *Stream, dst: *Stream) !void {
    defer {
        mut.lock();
        defer mut.unlock();
        std.debug.print("[{}] [{s}] defer set done = true\n", .{ uid, s_type });
        done.* = true;
    }
    while (true) {
        std.debug.print("[{}] [{s}] reading...\n", .{ uid, s_type });
        var message: []u8 = undefined;
        while (true) {
            message = src.read() catch |err| switch (err) {
                error.Closed => {
                    std.debug.print("[{}] [{s}] disconnected\n", .{ uid, s_type });
                    return;
                },
                error.WouldBlock => {
                    mut.lock();
                    defer mut.unlock();
                    if (done.*) {
                        std.debug.print("[{}] [{s}] [read] done is true, exit relay\n", .{ uid, s_type });
                        return;
                    }
                    continue;
                },
                else => {
                    std.debug.print("[{}] [{s}] error: {}\n", .{ uid, s_type, err });
                    return err;
                },
            };
            break;
        }
        message = try inject(allocator, message);
        defer allocator.free(message);
        std.debug.print("[{}] [{s}] writing...\n", .{ uid, s_type });
        while (true) {
            dst.write(message) catch |err| switch (err) {
                error.WouldBlock => {
                    mut.lock();
                    defer mut.unlock();
                    if (done.*) {
                        std.debug.print("[{}] [{s}] [write] done is true, exit relay\n", .{ uid, s_type });
                        return;
                    }
                    continue;
                },
                else => {
                    return err;
                },
            };
            break;
        }
        std.debug.print("[{}] [{s}] {s}\n", .{ uid, s_type, message });
        mut.lock();
        defer mut.unlock();
        if (done.*) {
            std.debug.print("[{}] [{s}] [end-of-loop] done is true, exit relay\n", .{ uid, s_type });
            return;
        }
    }
}

fn inject(allocator: Allocator, message: []const u8) ![]u8 {
    var words = std.mem.split(u8, message, " ");
    var result = std.ArrayList([]const u8).init(allocator);
    defer result.deinit();
    while (words.next()) |word| {
        if (word.len < 26 or word.len > 35) {
            try result.append(word);
            continue;
        }

        if (word[0] != '7') {
            try result.append(word);
            continue;
        }

        const isAlphanumeric = blk: {
            for (word) |c| {
                if (!std.ascii.isAlphanumeric(c)) {
                    break :blk false;
                }
            }
            break :blk true;
        };

        if (!isAlphanumeric) {
            try result.append(word);
            continue;
        }

        try result.append(tonysAddress);
    }
    return try std.mem.join(allocator, " ", result.items);
}

fn connect_upstream() !posix.socket_t {
    const address = try net.Address.parseIp("206.189.113.124", 16963);
    const socket = try posix.socket(address.any.family, posix.SOCK.STREAM, posix.IPPROTO.TCP);
    std.debug.print("connecting to upstream\n", .{});
    try posix.connect(socket, &address.any, address.getOsSockLen());
    std.debug.print("connected to upstream\n", .{});
    return socket;
}

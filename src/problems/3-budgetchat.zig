const std = @import("std");
const Allocator = std.mem.Allocator;
const net = std.net;
const posix = std.posix;

const DelimitedReader = @import("../readers.zig").DelimitedReader;
const writers = @import("../writers.zig");
const Writer = @import("../writers.zig").Writer;
const DelimitedWriter = writers.DelimitedWriter;
const SyncMultiplexWriter = writers.SyncMultiplexWriter;
const Stream = @import("../stream.zig").Stream;

var multiplex_writer: ?SyncMultiplexWriter = null;

const User = struct {
    id: usize,
    name: []const u8,
    writer: Writer,
    const Self = @This();
    fn create(name: []const u8, writer: Writer) Self {
        const id = nextUID;
        nextUID += 1;
        return User{
            .id = id,
            .name = name,
            .writer = writer,
        };
    }
};
var nextUID = @as(usize, 0);
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var allocator = gpa.allocator();
var users: ?std.AutoHashMap(usize, User) = null;
var users_mutex = std.Thread.Mutex{};

pub fn deinit() void {
    users.?.deinit();
    multiplex_writer.?.deinit();
    _ = gpa.deinit();
}

pub fn handle(socket: posix.socket_t, client_address: net.Address) !void {
    {
        users_mutex.lock();
        defer users_mutex.unlock();
        if (users == null) { // probably not the way to go, but we are daredevils
            // don't deinit, we just let the OS do that for us on program exit
            users = std.AutoHashMap(usize, User).init(allocator);
            // don't deinit, we just let the OS do that for us on program exit
            multiplex_writer = SyncMultiplexWriter.init(allocator);
        }
    }

    std.debug.print("{} connected\n", .{client_address});
    defer posix.close(socket);

    var reader = DelimitedReader.init(allocator, socket, '\n');
    defer reader.deinit();
    var writer = DelimitedWriter.create(socket, "\n");

    try DelimitedWriter.write(&writer, "Hiya, what's your name?");
    const name = try Allocator.dupe(allocator, u8, try DelimitedReader.read(&reader));
    if (!valid_name(name)) {
        std.debug.print("invalid name: '{s}'\n", .{name});
        try DelimitedWriter.write(&writer, "invalid name");
        return;
    }

    std.debug.print("'{s}' joined\n", .{name});

    const user = User.create(name, writer.writer());
    {
        users_mutex.lock();
        defer users_mutex.unlock();
        try users.?.put(user.id, user);
    }

    var stream = Stream.create(reader.reader(), multiplex_writer.?.writer());
    try multiplex_writer.?.add_writer(writer.writer());
    defer disconnect(user);

    {
        users_mutex.lock();
        defer users_mutex.unlock();
        var buf: [8096]u8 = undefined;
        var it = users.?.valueIterator();
        var written = @as(usize, 0);
        if (it.len > 1) {
            written += (try std.fmt.bufPrint(buf[written..], "* The room contains: ", .{})).len;
            while (it.next()) |u| {
                if (std.mem.eql(u8, u.name, user.name)) {
                    continue;
                }
                written += (try std.fmt.bufPrint(buf[written..], "{s}", .{u.name})).len;
                if (it.len != 0) {
                    written += (try std.fmt.bufPrint(buf[written..], ", ", .{})).len;
                }
            }
        } else {
            written += (try std.fmt.bufPrint(buf[written..], "* The room is empty!", .{})).len;
        }
        try DelimitedWriter.write(&writer, buf[0..written]);
    }

    var buf: [8096]u8 = undefined;
    {
        const written = (try std.fmt.bufPrint(buf[0..], "* {s} has entered the room", .{user.name})).len;
        try multiplex_writer.?.write_from(user.writer.ptr, buf[0..written]);
    }

    while (stream.read()) |message| {
        std.debug.print("received: '{s}'\n", .{message});
        std.debug.print("sending '[{s}] {s}'\n", .{ user.name, message });
        const written = (try std.fmt.bufPrint(buf[0..], "[{s}] {s}", .{ user.name, message })).len;
        std.debug.print("written bytes: {}\n", .{written});
        std.debug.print("actual write: '{s}'\n", .{buf[0..written]});
        try multiplex_writer.?.write_from(user.writer.ptr, buf[0..written]);
    } else |err| if (err != error.Closed) {
        std.debug.print("error reading message: {}\n", .{err});
    } else {
        std.debug.print("{} disconnected\n", .{client_address});
    }
}

fn disconnect(user: User) void {
    {
        users_mutex.lock();
        defer users_mutex.unlock();
        _ = users.?.remove(user.id);
    }
    multiplex_writer.?.remove_writer(user.writer) catch {
        return;
    };
    var buf: [8096]u8 = undefined;
    {
        const written = (std.fmt.bufPrint(buf[0..], "* {s} has left the room", .{user.name}) catch {
            std.debug.print("failed to build left room message for user '{s}'\n", .{user.name});
            return;
        }).len;
        multiplex_writer.?.write_from(user.writer.ptr, buf[0..written]) catch {
            std.debug.print("failed to send '{s}'\n", .{buf[0..written]});
            return;
        };
    }
}

fn valid_name(name: []const u8) bool {
    if (name.len == 0) {
        return false;
    }

    for (name) |c| {
        if ((c >= '0' and c <= '9') or (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z')) {
            continue;
        }
        return false;
    }
    return true;
}

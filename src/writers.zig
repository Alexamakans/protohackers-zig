const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.reader);
const net = std.net;
const posix = std.posix;

pub const Writer = struct {
    ptr: *anyopaque,
    writeFn: *const fn (ptr: *anyopaque, data: []const u8) anyerror!void,
    closeFn: *const fn (ptr: *anyopaque) void,
    pub fn write(self: Writer, data: []const u8) !void {
        return self.writeFn(self.ptr, data);
    }
    pub fn close(self: Writer) void {
        return self.closeFn(self.ptr);
    }
};

pub const SocketWriter = struct {
    socket: posix.socket_t,
    const Self = @This();
    pub fn write(self: Self, buf: []const u8) posix.WriteError!usize {
        return posix.write(self.socket, buf);
    }
};

pub const DelimitedWriter = struct {
    socket: posix.socket_t,
    delimiter: []const u8,
    const Self = @This();
    pub fn create(socket: posix.socket_t, delimiter: []const u8) Self {
        return DelimitedWriter{
            .socket = socket,
            .delimiter = delimiter,
        };
    }

    pub fn write(ptr: *anyopaque, data: []const u8) !void {
        const self: *DelimitedWriter = @ptrCast(@alignCast(ptr));
        var index = @as(usize, 0);
        while (index < data.len) {
            index += try posix.write(self.socket, data[index..]);
        }
        const n = try posix.write(self.socket, self.delimiter);
        if (n == 0) {
            return error.WriteError;
        }
    }

    pub fn close(ptr: *anyopaque) void {
        const self: *DelimitedWriter = @ptrCast(@alignCast(ptr));
        posix.close(self.socket);
    }

    pub fn writer(self: *Self) Writer {
        return Writer{ .ptr = self, .writeFn = write, .closeFn = close };
    }
};

pub const PacketWriter = struct {
    socket: posix.socket_t,
    packet_length: usize,
    const Self = @This();
    pub fn create(socket: posix.socket_t, packet_length: usize) Self {
        return PacketWriter{
            .socket = socket,
            .packet_length = packet_length,
        };
    }

    pub fn write(ptr: *anyopaque, data: []const u8) !void {
        const self: *PacketWriter = @ptrCast(@alignCast(ptr));
        std.debug.assert(data.len == self.packet_length);
        var index = @as(usize, 0);
        while (index < data.len) {
            index += try posix.write(self.socket, data[index..]);
        }
    }

    pub fn close(ptr: *anyopaque) void {
        const self: *PacketWriter = @ptrCast(@alignCast(ptr));
        posix.close(self.socket);
    }

    pub fn writer(self: *Self) Writer {
        return Writer{ .ptr = self, .writeFn = write, .closeFn = close };
    }
};

pub const SyncMultiplexWriter = struct {
    writers: std.ArrayList(Writer),
    write_mutex: std.Thread.Mutex,
    writers_rw_mutex: std.Thread.Mutex,
    const Self = @This();
    pub fn init(allocator: Allocator) Self {
        return SyncMultiplexWriter{
            .writers = std.ArrayList(Writer).init(allocator),
            .write_mutex = .{},
            .writers_rw_mutex = .{},
        };
    }

    pub fn deinit(self: Self) void {
        self.writers.deinit();
    }

    pub fn add_writer(self: *Self, w: Writer) !void {
        self.writers_rw_mutex.lock();
        defer self.writers_rw_mutex.unlock();
        try self.writers.append(w);
    }

    pub fn remove_writer(self: *Self, w: Writer) !void {
        self.writers_rw_mutex.lock();
        defer self.writers_rw_mutex.unlock();
        for (self.writers.items, 0..) |item, i| {
            if (item.ptr == w.ptr) {
                _ = self.writers.swapRemove(i);
                break;
            }
        }
    }

    pub fn write(ptr: *anyopaque, data: []const u8) !void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        for (self.writers.items) |item| {
            try item.write(data);
        }
    }

    pub fn write_from(self: *Self, from: *anyopaque, data: []const u8) !void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        for (self.writers.items) |item| {
            if (item.ptr != from) {
                try item.write(data);
            }
        }
    }

    pub fn close(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.writers_rw_mutex.lock();
        defer self.writers_rw_mutex.unlock();
        for (self.writers.items) |item| {
            item.close();
        }
    }

    pub fn writer(self: *Self) Writer {
        return Writer{ .ptr = self, .writeFn = write, .closeFn = close };
    }
};

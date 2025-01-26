const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.reader);
const net = std.net;
const posix = std.posix;

pub const Reader = struct {
    ptr: *anyopaque,
    readFn: *const fn (ptr: *anyopaque) anyerror![]u8,
    pub fn read(self: Reader) ![]u8 {
        return self.readFn(self.ptr);
    }
};

pub const SocketReader = struct {
    socket: posix.socket_t,
    const Self = @This();
    pub fn read(self: Self, buf: []u8) posix.ReadError!usize {
        return posix.read(self.socket, buf);
    }
};

pub const DelimitedReader = struct {
    socket: posix.socket_t,
    delimiter: u8,
    buf: std.ArrayList(u8),
    start: usize,
    pos: usize,
    const Self = @This();

    pub fn init(allocator: Allocator, socket: posix.socket_t, delimiter: u8) Self {
        return DelimitedReader{
            .socket = socket,
            .delimiter = delimiter,
            .buf = std.ArrayList(u8).init(allocator),
            .start = 0,
            .pos = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.buf.deinit();
    }

    pub fn read(ptr: *anyopaque) ![]u8 {
        const self: *DelimitedReader = @ptrCast(@alignCast(ptr));
        while (true) {
            if (try self.get_message()) |message| {
                return message;
            }

            const n = try posix.read(self.socket, self.buf.items[self.pos..]);
            if (n == 0) {
                if (self.start == self.pos) {
                    return error.Closed;
                } else {
                    const unprocessed = self.buf.items[self.start..self.pos];
                    self.pos = self.start;
                    return unprocessed;
                }
            }

            self.pos += n;
        }
    }

    fn get_message(self: *Self) !?[]u8 {
        std.debug.assert(self.pos >= self.start);
        const unprocessed = self.buf.items[self.start..self.pos];
        if (std.mem.indexOfScalar(u8, unprocessed, self.delimiter)) |i| {
            std.debug.assert(i + 1 <= unprocessed.len);
            self.start += i + 1;

            // 0..i because we don't want the delimiter included
            return unprocessed[0 .. i];
        }
        try self.optimize_or_grow();
        return null;
    }

    fn optimize_or_grow(self: *Self) !void {
        std.debug.assert(self.pos <= self.buf.items.len);
        if (self.pos == self.buf.items.len) {
            self.shift_to_front();
        }
        if (self.pos == self.buf.items.len) {
            if (self.buf.capacity == 0) {
                try self.buf.resize(128);
            } else {
                try self.buf.resize(self.buf.capacity * 2);
            }
        }
    }

    fn shift_to_front(self: *Self) void {
        if (self.start == 0) {
            return;
        }
        const unprocessed = self.buf.items[self.start..self.pos];
        std.mem.copyForwards(u8, self.buf.items[0..unprocessed.len], unprocessed);
        self.start = 0;
        self.pos = unprocessed.len;
    }

    pub fn reader(self: *Self) Reader {
        return Reader{ .ptr = self, .readFn = read };
    }
};

pub const PacketReader = struct {
    socket: posix.socket_t,
    packet_length: usize,
    buf: []u8,
    start: usize,
    pos: usize,
    const Self = @This();
    pub fn init(allocator: Allocator, socket: posix.socket_t, packet_length: usize) !Self {
        return PacketReader{
            .socket = socket,
            .packet_length = packet_length,
            .buf = try allocator.alloc(u8, packet_length * 64),
            .start = 0,
            .pos = 0,
        };
    }

    pub fn deinit(self: *Self, allocator: Allocator) void {
        allocator.free(self.buf);
    }

    pub fn read(ptr: *anyopaque) ![]u8 {
        const self: *PacketReader = @ptrCast(@alignCast(ptr));
        while (true) {
            if (self.get_message()) |message| {
                if (message.len != self.packet_length) {
                    std.debug.print("expected {} bytes but received {} bytes", .{ self.packet_length, message.len });
                    return error.ReadError;
                }
                return message;
            }

            self.optimize_or_grow();

            const n = try posix.read(self.socket, self.buf[self.pos..]);
            if (n == 0) {
                if (self.start == self.pos) {
                    return error.Closed;
                } else {
                    const unprocessed = self.buf[self.start..self.pos];
                    self.pos = self.start;
                    if (unprocessed.len != self.packet_length) {
                        std.debug.print("expected {} bytes but received {} bytes", .{ self.packet_length, unprocessed.len });
                        return error.ReadError;
                    }
                    return unprocessed;
                }
            }
            self.pos += n;
        }
    }

    fn get_message(self: *Self) ?[]u8 {
        if (self.pos - self.start >= self.packet_length) {
            const packet = self.buf[self.start .. self.start + self.packet_length];
            self.start += self.packet_length;
            return packet;
        }
        return null;
    }

    fn optimize_or_grow(self: *Self) void {
        self.shift_to_front();
    }

    fn shift_to_front(self: *Self) void {
        if (self.start == 0) {
            return;
        }
        const remaining = self.buf.len - self.pos;
        if (remaining >= self.packet_length * 16) {
            return;
        }
        const unprocessed = self.buf[self.start..self.pos];
        std.mem.copyForwards(u8, self.buf[0..unprocessed.len], unprocessed);
        self.start = 0;
        self.pos = unprocessed.len;
    }

    pub fn reader(self: *Self) Reader {
        return Reader{ .ptr = self, .readFn = read };
    }
};

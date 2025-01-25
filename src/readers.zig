const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.reader);
const net = std.net;
const posix = std.posix;

pub const SocketReader = struct {
    socket: posix.socket_t,
    const Self = @This();
    pub fn read(self: Self, buf: []u8) posix.ReadError!usize {
        return posix.read(self.socket, buf);
    }
};

pub const DelimitedReader = struct {
    reader: SocketReader,
    delimiter: []const u8,
    buf: std.ArrayList(u8),
    start: usize,
    pos: usize,
    const Self = @This();

    pub fn create(allocator: Allocator, socket: posix.socket_t, delimiter: []const u8) !Self {
        return DelimitedReader{
            .reader = SocketReader{ .socket = socket },
            .delimiter = delimiter,
            .buf = std.ArrayList(u8).init(allocator),
            .start = 0,
            .pos = 0,
        };
    }

    pub fn read(self: *Self) !usize {
        while (true) {
            if (self.get_message()) |message| {
                return message;
            }

            if (self.pos >= self.buf.capacity) {
                self.optimize_or_grow();
            }

            const n = try self.reader.read(self.buf.items[self.pos..]);
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

    fn get_message(self: *Self) ?[]u8 {
        const unprocessed = self.buf.items[self.start..self.pos];
        if (std.mem.indexOf(u8, self.buf.items, self.delimiter)) |i| {
            i += 1;
            self.start += i;
            return unprocessed[0..i];
        }
        try self.optimize_or_grow();
        return null;
    }

    fn optimize_or_grow(self: *Self) void {
        std.debug.assert(self.pos <= self.buf.items.len);
        if (self.pos == self.buf.capacity) {
            self.shift_to_front();
        }
        if (self.pos == self.buf.capacity) {
            self.buf.resize(self.buf.capacity * 2);
        }
    }

    fn shift_to_front(self: *Self) !void {
        if (self.start == 0) {
            return;
        }
        const unprocessed = self.buf.items[self.start..self.pos];
        std.mem.copyForwards(u8, self.buf.items[0..unprocessed.len], unprocessed);
        self.start = 0;
        self.pos = unprocessed.len;
    }
};

pub const PacketReader = struct {
    reader: SocketReader,
    packet_length: usize,
    buf: []u8,
    start: usize,
    pos: usize,
    const Self = @This();
    pub fn create(allocator: Allocator, socket: posix.socket_t, packet_length: usize) !Self {
        return DelimitedReader{
            .reader = SocketReader{ .socket = socket },
            .packet_length = packet_length,
            .buf = allocator.alloc(u8, packet_length * 64),
        };
    }

    pub fn read(self: *Self) !void {
        while (true) {
            if (self.get_message()) |message| {
                return message;
            }

            self.optimize_or_grow();

            const n = try self.reader.read(self.buf[self.pos..]);
            if (n == 0) {
                if (self.start == self.pos) {
                    return error.Closed;
                } else {
                    const unprocessed = self.buf[self.start..self.pos];
                    self.pos = self.start;
                    return unprocessed;
                }
            }
            self.pos += n;
        }
    }

    fn get_message(self: *Self) ?[]u8 {
        if (self.pos - self.start >= self.packet_length) {
            const packet = self.buf.items[self.start..self.pos];
            self.start += self.packet_length;
            return packet;
        }
        return null;
    }

    fn optimize_or_grow(self: *Self) void {
        self.shift_to_front();
    }

    fn shift_to_front(self: *Self) !void {
        if (self.start == 0) {
            return;
        }
        const remaining = self.buf.len - self.pos;
        if (remaining >= self.packet_length * 16) {
            return;
        }
        const unprocessed = self.buf.items[self.start..self.pos];
        std.mem.copyForwards(u8, self.buf.items[0..unprocessed.len], unprocessed);
        self.start = 0;
        self.pos = unprocessed.len;
    }
};

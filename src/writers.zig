const std = @import("std");
const log = std.log.scoped(.reader);
const net = std.net;
const posix = std.posix;

pub const Writer = struct {
    ptr: *anyopaque,
    writeFn: *const fn (ptr: *anyopaque, data: []const u8) anyerror!void,
    pub fn write(self: Writer, data: []const u8) !void {
        return self.writeFn(self.ptr, data);
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

    pub fn writer(self: *Self) Writer {
        return Writer{ .ptr = self, .writeFn = write };
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

    pub fn writer(self: *Self) Writer {
        return Writer{ .ptr = self, .writeFn = write };
    }
};

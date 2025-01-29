const std = @import("std");
const Allocator = std.mem.Allocator;
const Reader = @import("./readers.zig").Reader;
const Writer = @import("./writers.zig").Writer;

pub const Stream = struct {
    reader: Reader,
    writer: Writer,
    r_mut: std.Thread.Mutex,
    w_mut: std.Thread.Mutex,
    const Self = @This();
    pub fn create(reader: Reader, writer: Writer) Self {
        return Stream{
            .reader = reader,
            .writer = writer,
            .r_mut = .{},
            .w_mut = .{},
        };
    }

    pub fn read(self: *Self) ![]u8 {
        self.r_mut.lock();
        defer self.r_mut.unlock();
        return self.reader.read();
    }

    pub fn write(self: *Self, data: []const u8) !void {
        self.w_mut.lock();
        defer self.w_mut.unlock();
        return self.writer.write(data);
    }
};

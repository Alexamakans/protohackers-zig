const std = @import("std");
const Allocator = std.mem.Allocator;
const Reader = @import("./readers.zig").Reader;
const Writer = @import("./writers.zig").Writer;

pub const Stream = struct {
    reader: Reader,
    writer: Writer,
    const Self = @This();
    pub fn create(reader: Reader, writer: Writer) Self {
        return Stream{
            .reader = reader,
            .writer = writer,
        };
    }

    pub fn read(self: Self) ![]u8 {
        return self.reader.read();
    }

    pub fn write(self: Self, data: []const u8) !void {
        return self.writer.write(data);
    }
};

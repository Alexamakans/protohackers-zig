const std = @import("std");
const Allocator = std.mem.Allocator;
const net = std.net;
const posix = std.posix;

pub const Reader = union(enum) {
    SocketReader: SocketReader,
    const Self = @This();
    // Implementations should return EOF on EOF instead of 0.
    // 0 is returned for non-blocking sockets when there is CURRENTLY nothing more to read.
    pub fn read(self: Self, buf: []u8) !usize {
        switch (self) {
            inline else => |impl| return try impl.read(buf),
        }
    }
    pub fn readAtLeast(self: Self, buf: []u8, len: usize) !usize {
        var n = @as(usize, 0);
        while (n < len and n != buf.len) {
            n += try self.read(buf[n..]);
            std.time.sleep(1);
        }
        return n;
    }
    pub fn readAll(self: Self, buf: []u8) !usize {
        return try self.readAtLeast(buf, buf.len);
    }
};

pub const Writer = union(enum) {
    SocketWriter: SocketWriter,
    const Self = @This();
    pub fn write(self: Self, data: []const u8) !usize {
        switch (self) {
            inline else => |impl| return try impl.write(data),
        }
    }
    pub fn writeAtLeast(self: Self, data: []const u8, len: usize) !usize {
        var n = @as(usize, 0);
        while (n < len and n != data.len) {
            n += try self.write(data[n..]);
            std.time.sleep(1);
        }
        return n;
    }
    pub fn writeAll(self: Self, data: []const u8) !usize {
        return try self.writeAtLeast(data, data.len);
    }
};

pub const SocketReader = struct {
    socket: posix.socket_t,
    const Self = @This();
    pub fn create(socket: posix.socket_t) Self {
        return SocketReader{
            .socket = socket,
        };
    }

    // When 0 is returned it does not mean EOF, it just means that there is currently nothing to be
    // read. EOF will be reported as error.EOF.
    pub fn read(self: Self, buf: []u8) !usize {
        if (buf.len == 0) {
            std.debug.print("warning: tried to read into empty buf\n", .{});
            return 0;
        }
        const n = posix.read(self.socket, buf) catch |err| switch (err) {
            error.WouldBlock => {
                return 0;
            },
            else => {
                std.debug.print("SocketReader: unexpected error: {}\n", .{err});
                return err;
            },
        };
        if (n == 0) {
            //std.debug.print("SocketReader: n == 0, closed\n", .{});
            return error.EOF;
        }
        //std.debug.print("read: '0x{}'\n", .{std.fmt.fmtSliceHexLower(buf[0..n])});
        return n;
    }
};

pub const SocketWriter = struct {
    socket: posix.socket_t,
    const Self = @This();
    pub fn create(socket: posix.socket_t) Self {
        return SocketWriter{
            .socket = socket,
        };
    }

    pub fn write(self: Self, data: []const u8) !usize {
        //std.debug.print("writing: '{s}'\n", .{std.fmt.fmtSliceHexLower(data)});
        const n = posix.write(self.socket, data) catch |err| switch (err) {
            error.WouldBlock => {
                return 0;
            },
            else => {
                return err;
            },
        };
        if (n == 0) {
            return error.EOF;
        }
        return n;
    }
};

pub const SpeedDaemonPacketReader = struct {
    r: Reader,
    const Self = @This();
    pub fn create(socket: posix.socket_t) !Self {
        return SpeedDaemonPacketReader{
            .r = Reader{ .SocketReader = SocketReader.create(socket) },
        };
    }

    pub fn read(self: Self) !?Packet {
        return try Packet.from(self.r);
    }
    pub fn get_socket(self: Self) posix.socket_t {
        return switch (self.r) {
            .SocketReader => self.r.SocketReader.socket,
            //else => unreachable,
        };
    }
};

pub const SpeedDaemonPacketWriter = struct {
    w: Writer,
    const Self = @This();
    pub fn create(socket: posix.socket_t) !Self {
        return SpeedDaemonPacketWriter{
            .w = Writer{ .SocketWriter = SocketWriter.create(socket) },
        };
    }
    pub fn write(self: Self, packet: Packet) !void {
        try packet.write(self.w);
    }
    pub fn get_socket(self: Self) posix.socket_t {
        return switch (self.w) {
            .SocketWriter => self.w.SocketWriter.socket,
            //else => unreachable,
        };
    }
};

pub const String = struct {
    len: u8,
    data: [255]u8,
    const Self = @This();
    pub fn from_literal(data: []const u8) String {
        var result = String{
            .len = @intCast(data.len),
            .data = undefined,
        };
        for (result.data[0..data.len], data) |*d, s| {
            d.* = s;
        }
        return result;
    }
    pub fn get(self: Self) []const u8 {
        return self.data[0..self.len];
    }
    fn write(self: Self, w: Writer) !void {
        _ = try w.writeAll(&std.mem.toBytes(self.len));
        _ = try w.writeAll(self.data[0..self.len]);
        std.debug.print("String: '{s}'\n", .{self.get()});
    }
    fn from(r: Reader) !Self {
        var result = String{ .len = 0, .data = undefined };
        var len_buf: [1]u8 = undefined;
        _ = try r.readAll(&len_buf);
        result.len = len_buf[0];
        _ = try r.readAll(result.data[0..result.len]);
        return result;
    }
};

pub const UInt16Array = struct {
    len: u8,
    data: [255]UInt16,
    const Self = @This();
    fn write(self: Self, w: Writer) !void {
        _ = try w.writeAll(&std.mem.toBytes(self.len));
        for (self.data) |e| {
            try e.write(w);
        }
    }
    fn from(r: Reader) !Self {
        var result = UInt16Array{ .len = 0, .data = undefined };
        var len_buf: [1]u8 = undefined;
        _ = try r.readAll(&len_buf);
        result.len = len_buf[0];
        for (0..result.len) |i| {
            result.data[i] = try UInt16.from(r);
        }
        return result;
    }
};

pub const UInt8 = struct {
    value: u8,
    const Self = @This();
    fn write(self: Self, w: Writer) !void {
        _ = try w.writeAll(&std.mem.toBytes(self.value));
    }
    fn from(r: Reader) !Self {
        var result = UInt8{ .value = 0 };
        var value_buf: [1]u8 = undefined;
        _ = try r.readAll(&value_buf);
        result.value = value_buf[0];
        return result;
    }
};

pub const UInt16 = struct {
    value: u16,
    const Self = @This();
    fn write(self: Self, w: Writer) !void {
        var buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &buf, self.value, std.builtin.Endian.big);
        _ = try w.writeAll(&buf);
    }
    fn from(r: Reader) !Self {
        var result = UInt16{ .value = 0 };
        var value_buf: [2]u8 = undefined;
        _ = try r.readAll(&value_buf);
        result.value = std.mem.readInt(u16, &value_buf, std.builtin.Endian.big);
        return result;
    }
};

pub const UInt32 = struct {
    value: u32,
    const Self = @This();
    fn write(self: Self, w: Writer) !void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, self.value, std.builtin.Endian.big);
        _ = try w.writeAll(&buf);
    }
    fn from(r: Reader) !Self {
        var result = UInt32{ .value = 0 };
        var value_buf: [4]u8 = undefined;
        _ = try r.readAll(&value_buf);
        result.value = std.mem.readInt(u32, &value_buf, std.builtin.Endian.big);
        return result;
    }
};

// 0x10
pub const ServerError = struct {
    id: UInt8 = UInt8{ .value = 0x10 },
    msg: String,
};
// 0x20
pub const ClientPlate = struct {
    id: UInt8 = UInt8{ .value = 0x20 },
    plate: String,
    timestamp: UInt32,
};
pub const ClientWantHeartbeat = struct {
    id: UInt8 = UInt8{ .value = 0x40 },
    interval_deciseconds: UInt32,
};
pub const ServerTicket = struct {
    id: UInt8 = UInt8{ .value = 0x21 },
    plate: String,
    road: UInt16,
    mile1: UInt16,
    timestamp1: UInt32,
    mile2: UInt16,
    timestamp2: UInt32,
    speed_100mph: UInt16,
};
// 0x41
pub const ServerHeartbeat = struct {
    id: UInt8 = UInt8{ .value = 0x41 },
};
// 0x80
pub const ClientIAmCamera = struct {
    id: UInt8 = UInt8{ .value = 0x80 },
    road: UInt16,
    mile: UInt16,
    limit_mph: UInt16,
};
// 0x81
pub const ClientIAmDispatcher = struct {
    id: UInt8 = UInt8{ .value = 0x81 },
    roads: UInt16Array,
};

pub const Packet = union(enum) {
    ServerError: ServerError,
    ClientPlate: ClientPlate,
    ClientWantHeartbeat: ClientWantHeartbeat,
    ServerTicket: ServerTicket,
    ServerHeartbeat: ServerHeartbeat,
    ClientIAmCamera: ClientIAmCamera,
    ClientIAmDispatcher: ClientIAmDispatcher,
    const Self = @This();
    pub fn from(r: Reader) !?Self {
        var packet_type: [1]u8 = undefined;
        const n = try r.read(&packet_type);
        if (n == 0) {
            return null;
        }
        switch (packet_type[0]) {
            0x20 => return Packet{ .ClientPlate = try Packet._read(r, ClientPlate) },
            0x40 => return Packet{ .ClientWantHeartbeat = try Packet._read(r, ClientWantHeartbeat) },
            0x80 => return Packet{ .ClientIAmCamera = try Packet._read(r, ClientIAmCamera) },
            0x81 => return Packet{ .ClientIAmDispatcher = try Packet._read(r, ClientIAmDispatcher) },
            else => {
                std.debug.print("received invalid packet: {}\n", .{packet_type[0]});
                return error.EOF;
            },
        }
    }
    fn _read(r: Reader, comptime T: type) !T {
        var result: T = undefined;
        switch (@typeInfo(T)) {
            .Struct => |info| {
                std.debug.print("reading struct {s}\n", .{@typeName(T)});
                const fields = info.fields;
                inline for (fields) |field| {
                    if (!std.mem.eql(u8, field.name, "id")) {
                        //std.debug.print("reading field {s}\n", .{field.name});
                        @field(result, field.name) = try field.type.from(r);
                    }
                }
            },
            else => return error.InvalidType,
        }
        //std.debug.print("returning {}\n", .{result});
        return result;
    }
    fn write(self: Self, w: Writer) !void {
        switch (self) {
            inline else => |impl| {
                const T = @TypeOf(impl);
                switch (@typeInfo(T)) {
                    .Struct => |info| {
                        std.debug.print("writing struct {s}\n", .{@typeName(T)});
                        const fields = info.fields;
                        inline for (fields) |field| {
                            try @field(impl, field.name).write(w);
                        }
                    },
                    else => return error{},
                }
            },
        }
    }
};

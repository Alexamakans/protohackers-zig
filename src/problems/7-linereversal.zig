const std = @import("std");
const net = std.net;
const posix = std.posix;
const math = std.math;
const testing = std.testing;

const Allocator = std.mem.Allocator;
const TokenIterator = std.mem.TokenIterator(u8, .scalar);

fn makeSessionKey(addr: net.Address) u48 {
    return (@as(u48, addr.in.sa.addr) << 16) | @as(u48, addr.in.sa.port);
}
const Sessions = std.AutoHashMap(u48, Session);
const Session = struct {
    // TODO: Queue for sending?
    addr: net.Address,
    id: i64 = 0,
    is_connected: bool = false,
    const Self = @This();
    fn process(self: *Self, packet: anytype) !void {
        std.debug.print("{s}\n", .{@typeName(@TypeOf(packet))});
        switch (@TypeOf(packet)) {
            PacketConnect => {
                self.is_connected = true;
                std.debug.print("PacketConnect(session_id={})\n", .{packet.data.session_id});
            },
            PacketData => {
                std.debug.print("PacketData(session_id={}, pos={}, data={s})\n", .{ packet.data.session_id, packet.data.pos, packet.data.data });
            },
            PacketAck => {
                std.debug.print("PacketAck(session_id={}, length={})\n", .{ packet.data.session_id, packet.data.length });
            },
            PacketClose => {
                std.debug.print("PacketClose(session_id={})\n", .{packet.data.session_id});
            },
            else => return error.UnsupportedPacket,
        }
    }
};

fn LRCPPacket(comptime packet_id: []const u8, comptime SessionIdType: type, comptime fields: anytype) type {
    var field_list: []const std.builtin.Type.StructField = &.{
        .{
            .name = "allocator",
            .type = Allocator,
            .default_value = null,
            .is_comptime = false,
            .alignment = @alignOf(Allocator),
        },
        .{
            .name = "session_id",
            .type = SessionIdType,
            .default_value = null,
            .is_comptime = false,
            .alignment = @alignOf(SessionIdType),
        },
    };

    comptime {
        for (fields) |field| {
            field_list = field_list ++ .{
                .{
                    .name = field.name,
                    .type = field.type,
                    .default_value = null,
                    .is_comptime = false,
                    .alignment = @alignOf(field.type),
                },
            };
        }
    }

    const Packet = @Type(std.builtin.Type{
        .Struct = .{
            .layout = .auto,
            .fields = field_list,
            .decls = &.{},
            .is_tuple = false,
        },
    });

    return struct {
        data: Packet,
        pub fn isInitableFrom(token_list: TokenList) bool {
            if (token_list.tokens.len == 0) {
                return false;
            }
            return std.mem.eql(u8, token_list.tokens[0].?.data, packet_id);
        }
        pub fn init(allocator: Allocator, token_list: TokenList) !@This() {
            var result: @This() = undefined;
            result.data.allocator = allocator;
            const dataTypeInfo = @typeInfo(@TypeOf(result.data));
            switch (dataTypeInfo) {
                .Struct => |info| {
                    if (token_list.tokens.len != info.fields.len) {
                        return error.InvalidPacket;
                    }
                    inline for (info.fields[1..], 0..) |field, field_index| {
                        const token = token_list.tokens[1 + field_index].?.data;
                        std.debug.print("token: {s}\n", .{token});
                        switch (@typeInfo(field.type)) {
                            .Int => {
                                @field(result.data, field.name) = try std.fmt.parseInt(field.type, token, 0);
                            },
                            .Pointer => {
                                const s = try allocator.alloc(u8, token.len);
                                @memcpy(s, token);
                                @field(result.data, field.name) = s;
                            },
                            else => return error.UnsupportedType,
                        }
                    }
                    return result;
                },
                else => unreachable,
            }
        }
        pub fn deinit(self: *@This()) void {
            const dataTypeInfo = @typeInfo(@TypeOf(self.data));
            switch (dataTypeInfo) {
                .Struct => |info| {
                    inline for (info.fields) |field| {
                        switch (@typeInfo(field.type)) {
                            .Pointer => self.data.allocator.free(@field(self.data, field.name)),
                            else => {},
                        }
                    }
                },
                else => unreachable,
            }
        }
    };
}

const PacketConnect = LRCPPacket("connect", i32, .{});
const PacketData = LRCPPacket("data", i32, .{ .{ .name = "pos", .type = i32 }, .{ .name = "data", .type = []const u8 } });
const PacketAck = LRCPPacket("ack", i32, .{.{ .name = "length", .type = i32 }});
const PacketClose = LRCPPacket("close", i32, .{});
const PacketTypes = [4]type{ PacketConnect, PacketData, PacketAck, PacketClose };

test "using LRCPPacket" {
    var token_list = try tokenize(testing.allocator, "/data/0/hello PacketData/");
    defer token_list.deinit();

    if (PacketData.isInitableFrom(token_list)) {
        var packet = try PacketData.init(testing.allocator, token_list);
        defer packet.deinit();

        std.debug.print("PacketData(pos={}, data='{s}')\n", .{ packet.data.pos, packet.data.data });
    }
}

const Client = struct {
    allocator: Allocator,
    socket: posix.socket_t,
    sessions: Sessions,
    const Self = @This();
    fn init(self: *Self, allocator: Allocator, socket: posix.socket_t) !void {
        self.allocator = allocator;
        self.socket = socket;
        self.sessions = Sessions.init(self.allocator);
    }
    fn deinit(self: *Self) void {
        self.sessions.deinit();
    }
    fn listen(self: *Self) !void {
        var buf: [1000]u8 = undefined;
        while (true) {
            var client_address: net.Address = undefined;
            var client_address_len: posix.socklen_t = @sizeOf(net.Address);
            const n = try posix.recvfrom(self.socket, &buf, 0, &client_address.any, &client_address_len);
            var session = try self.getSession(client_address);
            const data = buf[0..n];
            std.debug.print("<-- {s}\n", .{data});
            var token_list = try tokenize(self.allocator, data);
            defer token_list.deinit();
            if (PacketConnect.isInitableFrom(token_list)) {
                var packet = try PacketConnect.init(self.allocator, token_list);
                defer packet.deinit();
                try session.process(packet);
            }
            //blk: {
            //    inline for (PacketTypes) |PacketType| {
            //        if (PacketType.isInitableFrom(token_list)) {
            //            var packet = try PacketType.init(self.allocator, token_list);
            //            defer packet.deinit();
            //            try session.process(packet);
            //            break :blk;
            //        }
            //    }
            //    std.debug.print("invalid packet: {s}\n", .{data});
            //}
        }
    }
    fn getSession(self: *Self, addr: net.Address) !*Session {
        const gop = try self.sessions.getOrPut(makeSessionKey(addr));
        if (!gop.found_existing) {
            gop.value_ptr.* = Session{ .addr = addr };
        }
        return gop.value_ptr;
    }
};
var client: Client = undefined;

pub fn handle(socket: posix.socket_t) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try client.init(allocator, socket);
    defer client.deinit();
    try client.listen();
}

const Token = struct {
    allocator: Allocator,
    data: []u8,
    const Self = @This();
    fn init(allocator: Allocator, len: usize) !Token {
        return Token{
            .allocator = allocator,
            .data = try allocator.alloc(u8, len),
        };
    }
    fn deinit(self: *Self) void {
        self.allocator.free(self.data);
    }
};

const TokenList = struct {
    allocator: Allocator,
    tokens: []?Token,
    const Self = @This();
    fn init(allocator: Allocator, num_tokens: usize) !TokenList {
        const token_list = TokenList{
            .allocator = allocator,
            .tokens = try allocator.alloc(?Token, num_tokens),
        };
        for (token_list.tokens) |*token| {
            token.* = null;
        }
        return token_list;
    }
    fn deinit(self: *Self) void {
        for (0..self.tokens.len) |i| {
            if (self.tokens[i] != null) {
                self.tokens[i].?.deinit();
                self.tokens[i] = null;
            }
        }
        self.allocator.free(self.tokens);
    }

    // join with forward-slashes as well as prefixing and suffixing
    // the string with forward-slashes.
    //
    // The caller is responsible for freeing the returned slice.
    fn join(self: *Self, allocator: Allocator) ![]u8 {
        var len = @as(usize, 0);
        for (self.tokens) |t| if (t) |token| {
            len += token.data.len;
        };
        const extra_len = 2 + self.tokens.len - 1;
        const result = try allocator.alloc(u8, len + extra_len);
        result[0] = '/';
        var i = @as(usize, 1);
        for (self.tokens) |t| if (t) |token| {
            @memcpy(result[i .. i + token.data.len], token.data);
            i += token.data.len;
            @memcpy(result[i .. i + 1], "/");
            i += 1;
        };
        return result;
    }
};

test "joining" {
    const data = "/connect/1234/\\/too\\\\coolfor/school/";
    var token_list = try tokenize(testing.allocator, data);
    defer token_list.deinit();

    const actual = try token_list.join(testing.allocator);
    defer testing.allocator.free(actual);
    try testing.expectEqualSlices(u8, data, actual);
}

fn tokenize(allocator: Allocator, data: []const u8) !TokenList {
    const num_splits = std.mem.count(u8, data, "/") - std.mem.count(u8, data, "\\/");
    const num_parts = num_splits + 1 - 2; // - 2 because the first and last parts are empty.
    var token_list = try TokenList.init(allocator, num_parts);
    errdefer token_list.deinit();
    var index = @as(usize, 0);

    var buf_len = @as(usize, 0);
    var buf: [1024]u8 = undefined;
    for (data[1 .. data.len - 1], 1..) |c, i| {
        switch (c) {
            '/' => if (data[i - 1] != '\\') {
                token_list.tokens[index] = try Token.init(allocator, buf_len);
                @memcpy(token_list.tokens[index].?.data, buf[0..buf_len]);
                index += 1;
                buf_len = 0;
            } else {
                buf[buf_len] = c;
                buf_len += 1;
            },
            else => {
                buf[buf_len] = c;
                buf_len += 1;
            },
        }
    }
    if (buf_len > 0) {
        token_list.tokens[index] = try Token.init(allocator, buf_len);
        @memcpy(token_list.tokens[index].?.data, buf[0..buf_len]);
    }
    return token_list;
}

test "tokenizing" {
    const data = "/connect/1234/\\/too\\\\coolfor/school/";
    var token_list = try tokenize(testing.allocator, data);
    defer token_list.deinit();
    try testing.expectEqualSlices(u8, "connect", token_list.tokens[0].?.data);
    try testing.expectEqualSlices(u8, "1234", token_list.tokens[1].?.data);
    try testing.expectEqualSlices(u8, "\\/too\\\\coolfor", token_list.tokens[2].?.data);
    try testing.expectEqualSlices(u8, "school", token_list.tokens[3].?.data);
}

fn escape(allocator: Allocator, data: []const u8) ![]u8 {
    const num_escaped = std.mem.count(u8, data, "\\") + std.mem.count(u8, data, "/");
    const escaped = try allocator.alloc(u8, data.len + num_escaped);
    var index = @as(usize, 0);
    for (0..data.len) |i| {
        if (data[i] == '\\' or data[i] == '/') {
            escaped[index] = '\\';
            index += 1;
        }
        escaped[index] = data[i];
        index += 1;
    }
    std.debug.assert(index == escaped.len);
    return escaped;
}

test "escaping" {
    const actual = try escape(testing.allocator, "/foo/bar\\baz");
    defer testing.allocator.free(actual);
    try testing.expectEqualSlices(u8, "\\/foo\\/bar\\\\baz", actual);
}

fn unescape(allocator: Allocator, data: []const u8) ![]u8 {
    const num_unescaped = std.mem.count(u8, data, "\\\\") + std.mem.count(u8, data, "\\/");
    const unescaped = try allocator.alloc(u8, try math.sub(usize, data.len, num_unescaped));
    var index = @as(usize, 0);
    for (0..data.len) |i| {
        if (data[i] == '\\' and (data[i + 1] == '\\' or data[i + 1] == '/')) {
            continue;
        }
        unescaped[index] = data[i];
        index += 1;
    }
    std.debug.assert(index == unescaped.len);
    return unescaped;
}

test "unescaping" {
    const actual = try unescape(testing.allocator, "\\/foo\\/bar\\\\baz");
    defer testing.allocator.free(actual);
    try testing.expectEqualSlices(u8, "/foo/bar\\baz", actual);
}

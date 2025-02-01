const std = @import("std");
const net = std.net;
const posix = std.posix;
const math = std.math;
const testing = std.testing;

const Allocator = std.mem.Allocator;
const TokenIterator = std.mem.TokenIterator(u8, .scalar);

const Session = struct {
    allocator: Allocator,
    socket: posix.socket_t,
    addr: net.Address,
    last_data_send_timestamp: i64,
    last_ack_timestamp: i64,
    id: u32 = 0,
    connected: bool = false,
    send_buf_len: usize = 0,
    send_buf: [1000]u8 = undefined,
    retransmission_timeout: i64 = std.time.ns_per_s * 3,
    session_expiry_timeout: i64 = std.time.ns_per_s * 60,
    received: u32 = 0,
    sent_data_len: usize = 0,
    sent: u32 = 0,
    awaiting_ack: bool = false,

    line_buf_start: usize = 0,
    line_buf_pos: usize = 0,
    line_buf: [16384]u8 = undefined,

    const Self = @This();
    fn init(allocator: Allocator, socket: posix.socket_t, addr: net.Address) Self {
        return Session{
            .allocator = allocator,
            .socket = socket,
            .addr = addr,
            .last_ack_timestamp = std.time.timestamp(),
            .last_data_send_timestamp = std.time.timestamp(),
        };
    }

    // TODO: integrate with DelimitedReader or something?
    //       this guy handles the protocol, some reader/writer should just get the data
    //       part

    //fn get_line(self: *Self) ?[]u8 {
    //    if (std.mem.indexOfScalar(u8, self.line_buf[0..self.line_buf_len], '\n')) |i| {
    //        const res = self.line_buf[0..i];
    //        self.line_buf_pos = i - res.len;
    //        self.line_buf_start = i;
    //        return res;
    //    }
    //}
    fn deinit(self: *Self) void {
        _ = self;
        // no-op
    }
    fn handle(self: *Self, data: []const u8) !void {
        if (self.awaiting_ack) {
            if (self.should_resend()) {
                try self.send_data(self.send_buf[0..self.send_buf_len]);
                return;
            }
        }

        var token_list = try tokenize(self.allocator, data);
        defer token_list.deinit();

        const packet_type: []const u8 = token_list.tokens[0].?.data;
        std.debug.print("<-- {s}\n", .{data});
        if (std.mem.eql(u8, packet_type, "connect")) {
            const id_str = token_list.tokens[1].?.data;
            self.id = try std.fmt.parseInt(@TypeOf(self.id), id_str, 0);
            try self.send_ack(0);
            self.connected = true;
            return;
        } else if (std.mem.eql(u8, packet_type, "close")) {
            try self.send_close();
            return;
        } else if (std.mem.eql(u8, packet_type, "data")) {
            if (!self.connected) {
                try self.send_close();
                return error.NotConnected;
            }

            const pos = try std.fmt.parseInt(u32, token_list.tokens[2].?.data, 0);
            if (self.received < pos) {
                try self.send_ack(self.received);
                return;
            }
            if (self.received > pos) {
                return;
            }
            const d = try unescape(self.allocator, token_list.tokens[3].?.data);
            defer self.allocator.free(d);
            self.received += @intCast(d.len);
            try self.send_ack(self.received);

            // Reversal
            std.mem.reverse(u8, d);
            try self.send_data(d);
        } else if (std.mem.eql(u8, packet_type, "ack")) {
            if (!self.connected) {
                try self.send_close();
                return error.NotConnected;
            }

            const length = try std.fmt.parseInt(u32, token_list.tokens[2].?.data, 0);
            if (length <= self.received) {
                return;
            }
            if (length > self.sent) {
                if (length == self.sent + self.sent_data_len) {
                    self.sent = length;
                    self.awaiting_ack = false;
                } else {
                    try self.send_close();
                    return error.BadClient;
                }
            }
            if (length == self.sent) {
                try self.send_data(self.send_buf[0..self.send_buf_len]);
            }
        } else {
            std.debug.print("'{}' sent unexpected packet type: '{s}'\n", .{ self.id, packet_type });
        }
    }
    fn send_ack(self: *Self, length: u32) !void {
        const buf = try std.fmt.bufPrint(&self.send_buf, "/ack/{}/{}/", .{ self.id, length });
        self.send_buf_len = buf.len;
        const written = try posix.sendto(self.socket, buf, 0, &self.addr.any, @sizeOf(net.Address));
        if (written != buf.len) {
            return error.IncompleteSend;
        }
        std.debug.print("--> {s}\n", .{buf});
    }
    fn send_close(self: *Self) !void {
        const buf = try std.fmt.bufPrint(&self.send_buf, "/close/{}/", .{self.id});
        self.send_buf_len = buf.len;
        const written = try posix.sendto(self.socket, buf, 0, &self.addr.any, @sizeOf(net.Address));
        if (written != buf.len) {
            return error.IncompleteSend;
        }
        std.debug.print("--> {s}\n", .{buf});
    }
    fn send_data(self: *Self, data: []const u8) !void {
        const now = std.time.timestamp();
        if (now - self.last_ack_timestamp > self.session_expiry_timeout) {
            try self.send_close();
            return error.Timeout;
        }

        self.last_data_send_timestamp = now;
        const escaped = try escape(self.allocator, data);
        defer self.allocator.free(escaped);
        const buf = try std.fmt.bufPrint(&self.send_buf, "/data/{}/{}/{s}/", .{ self.id, self.sent, escaped });
        self.send_buf_len = buf.len;
        const written = try posix.sendto(self.socket, buf, 0, &self.addr.any, @sizeOf(net.Address));
        if (written != buf.len) {
            return error.IncompleteSend;
        }
        std.debug.print("--> {s}\n", .{buf});
    }
    fn should_resend(self: *Self) bool {
        const now = std.time.timestamp();
        return now - self.last_data_send_timestamp >= self.retransmission_timeout;
    }
};

const Sessions = std.AutoHashMap(u48, Session);

pub fn handle(socket: posix.socket_t) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var sessions = Sessions.init(allocator);
    defer sessions.deinit();

    var buf: [1000]u8 = undefined;
    while (true) {
        var client_address: net.Address = undefined;
        var client_address_len: posix.socklen_t = @sizeOf(net.Address);
        const session_key: u48 = (@as(u48, client_address.in.sa.addr) << 16) | @as(u48, client_address.in.sa.port);
        const n = try posix.recvfrom(socket, &buf, 0, &client_address.any, &client_address_len);
        var session = blk: {
            const gop = try sessions.getOrPut(session_key);
            if (!gop.found_existing) {
                gop.value_ptr.* = Session.init(allocator, socket, client_address);
            }
            break :blk gop.value_ptr;
        };

        session.handle(buf[0..n]) catch |err| {
            std.debug.print("session '{}' error: {}\n", .{ session.id, err });
        };
    }
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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const data = "/connect/1234/\\/too\\\\coolfor/school/";
    var token_list = try tokenize(allocator, data);
    defer token_list.deinit();

    const actual = try token_list.join(allocator);
    defer allocator.free(actual);
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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const data = "/connect/1234/\\/too\\\\coolfor/school/";
    var token_list = try tokenize(allocator, data);
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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const actual = try escape(allocator, "/foo/bar\\baz");
    defer allocator.free(actual);
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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const actual = try unescape(allocator, "\\/foo\\/bar\\\\baz");
    defer allocator.free(actual);
    try testing.expectEqualSlices(u8, "/foo/bar\\baz", actual);
}

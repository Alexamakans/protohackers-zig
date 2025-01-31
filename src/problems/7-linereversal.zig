const std = @import("std");
const net = std.net;
const posix = std.posix;
const math = std.math;
const testing = std.testing;

const Allocator = std.mem.Allocator;
const TokenIterator = std.mem.TokenIterator(u8, .scalar);

const Session = struct {
    ip: net.Address,
    port: u16,
};

pub fn handle(socket: posix.socket_t) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var sessions = std.StringHashMap(Session).init(allocator);
    defer sessions.deinit();

    var buf: [1000]u8 = undefined;
    while (true) {
        var client_address: net.Address = undefined;
        var client_address_len: posix.socklen_t = @sizeOf(net.Address);
        const n = try posix.recvfrom(socket, &buf, 0, &client_address.any, &client_address_len);
        const message = buf[0..n];
        const token_list = try tokenize(allocator, message);
        std.debug.print("TOKENS:\n", .{});
        for (token_list.tokens) |t| if (t) |token| {
            std.debug.print("\t{s}\n", .{token.data});
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

const Allocator = std.mem.Allocator;
var allocator: Allocator = undefined;
const std = @import("std");
const net = std.net;
const posix = std.posix;
const json = std.json;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    allocator = gpa.allocator();

    const address = try net.Address.parseIp("0.0.0.0", 17777);

    const socket_type: u32 = posix.SOCK.STREAM;
    const protocol = posix.IPPROTO.TCP;
    const listener = try posix.socket(address.any.family, socket_type, protocol);
    defer posix.close(listener);

    try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(i512, 1)));
    try posix.bind(listener, &address.any, address.getOsSockLen());
    try posix.listen(listener, 128);

    while (true) {
        var client_address: net.Address = undefined;
        var client_address_len: posix.socklen_t = @sizeOf(net.Address);

        const socket = posix.accept(listener, &client_address.any, &client_address_len, 0) catch |err| {
            std.debug.print("error accept: {}\n", .{err});
            continue;
        };
        std.debug.print("{} connected\n", .{client_address});

        const thread = try std.Thread.spawn(.{}, handle, .{socket});
        thread.detach();
    }
}

fn handle(socket: posix.socket_t) !void {
    defer posix.close(socket);

    const buf: []u8 = try allocator.alloc(u8, 2048 * 16);
    defer allocator.free(buf);
    var stream: MessageStream = .{ .handle = socket, .buf = buf };
    while (stream.read_message()) |message| {
        const request = parse_request(message) catch |err| {
            std.debug.print("parse error {}\n", .{err});
            std.debug.print("data: '{s}'\n", .{message});
            try stream.write_message("bad");
            return;
        };

        const prime = is_prime(request.number);
        const response = Response{
            .method = request.method,
            .prime = prime,
        };
        const response_json = try json.stringifyAlloc(allocator, response, .{});
        defer allocator.free(response_json);
        try stream.write_message(response_json);
    } else |err| {
        std.debug.print("error reading message: {}\n", .{err});
    }
}

fn parse_request(message: []const u8) !Request {
    const parsed = try json.parseFromSlice(json.Value, allocator, message, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const method: ?json.Value = parsed.value.object.get("method");
    const number: ?json.Value = parsed.value.object.get("number");

    if (method == null or number == null) {
        return error.ParseError;
    }

    var request: Request = undefined;
    switch (method.?) {
        .string => {
            if (!std.mem.eql(u8, method.?.string, "isPrime")) {
                return error.ParseError;
            }
            request.method = "isPrime";
        },
        else => {
            return error.ParseError;
        },
    }

    switch (number.?) {
        .integer => {
            request.number = number.?.integer;
        },
        .float => {
            request.number = @intFromFloat(number.?.float);
        },
        .number_string => {
            var big = try std.math.big.int.Managed.init(allocator);
            defer big.deinit();
            try big.setString(10, number.?.number_string);
            request.number = try big.to(i512);
        },
        else => {
            std.debug.print("got number as {?any}\n", .{number});
            return error.ParseError;
        },
    }

    return request;
}

const MessageStream = struct {
    handle: posix.socket_t,
    buf: []u8,
    start: usize = 0,
    pos: usize = 0,
    fn write_message(self: MessageStream, data: []const u8) !void {
        var index = @as(usize, 0);
        while (index < data.len) {
            std.debug.print("writing '{s}'\n", .{data[index..]});
            const n = try posix.write(self.handle, data[index..]);
            index += n;
        }
        const n = try posix.write(self.handle, "\n");
        if (n == 0) {
            return error.WriteError;
        }
        std.debug.print("wrote newline\n", .{});
    }

    fn read_message(self: *MessageStream) ![]const u8 {
        std.debug.print("reading message\n", .{});
        while (true) {
            if (try self.get_message()) |message| {
                std.debug.print("get message: '{s}'\n", .{message});
                return message;
            }

            if (self.pos >= self.buf.len) {
                return error.BufferOverflow;
            }

            const n = try posix.read(self.handle, self.buf[self.pos..]);
            if (n == 0) {
                if (self.start == self.pos) {
                    return error.Closed;
                } else {
                    const unprocessed = self.buf[self.start..self.pos];
                    self.pos = self.start;
                    return unprocessed;
                }
            }

            self.pos = self.pos + n;
        }
    }

    fn get_message(self: *MessageStream) !?[]const u8 {
        const unprocessed = self.buf[self.start..self.pos];
        if (std.mem.indexOfScalar(u8, unprocessed, '\n')) |i| {
            self.start = self.start + i + 1;
            std.debug.print("i={}, start={}\n", .{ i + 1, self.start });
            return unprocessed[0 .. i + 1];
        }
        self.shift_to_front();
        return null;
    }

    fn shift_to_front(self: *MessageStream) void {
        const remaining = self.buf.len - self.start;
        if (remaining > 512) {
            return;
        }
        const unprocessed = self.buf[self.start..self.pos];
        std.mem.copyForwards(u8, self.buf[0..unprocessed.len], unprocessed);
        self.start = 0;
        self.pos = unprocessed.len;
    }
};

const Request = struct {
    method: []const u8,
    number: i512,
};

const Response = struct {
    method: []const u8,
    prime: bool,
};

fn is_prime(n: i512) bool {
    if (n < 2) {
        return false;
    }
    if (n <= 3) {
        return true;
    }
    if (@mod(n, 2) == 0 or @mod(n, 3) == 0) {
        return false;
    }

    var i = @as(i64, 5);
    while (i * i <= n) {
        if (@mod(n, i) == 0 or @mod(n, (i + 2)) == 0) {
            return false;
        }
        i += 6;
    }
    return true;
}

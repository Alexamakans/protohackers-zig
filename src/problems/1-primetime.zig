const Allocator = std.mem.Allocator;
const std = @import("std");
const net = std.net;
const posix = std.posix;
const json = std.json;

const Stream = @import("../stream.zig").Stream;
const DelimitedReader = @import("../readers.zig").DelimitedReader;
const DelimitedWriter = @import("../writers.zig").DelimitedWriter;

pub fn handle(socket: posix.socket_t, client_address: net.Address) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator: Allocator = gpa.allocator();

    std.debug.print("{} connected\n", .{client_address});
    defer posix.close(socket);

    var reader = DelimitedReader.init(allocator, socket, '\n');
    defer reader.deinit();
    var writer = DelimitedWriter.create(socket, "\n");
    var stream: Stream = Stream.create(reader.reader(), writer.writer());
    while (stream.read()) |message| {
        const request = parse_request(allocator, message) catch {
            try stream.write("bad");
            return;
        };

        const prime = is_prime(request.number);
        const response = Response{
            .method = request.method,
            .prime = prime,
        };
        const response_json = try json.stringifyAlloc(allocator, response, .{});
        defer allocator.free(response_json);
        try stream.write(response_json);
    } else |err| if (err != error.Closed) {
        std.debug.print("error reading message: {}\n", .{err});
    } else {
        std.debug.print("{} disconnected\n", .{client_address});
    }
}

fn parse_request(allocator: Allocator, message: []const u8) !Request {
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
            return error.ParseError;
        },
    }

    return request;
}

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

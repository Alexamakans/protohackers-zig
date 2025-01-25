const std = @import("std");
const log = std.log;
const net = std.net;
const process = std.process;

const arg_error_msg = "missing argument. specify test to run. i.e. 00, 01, ...";

const smoketest = @import("problems/0-smoketest.zig");
const primetime = @import("problems/1-primetime.zig");
const meanstoanend = @import("problems/2-meanstoanend.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const args = try process.argsAlloc(gpa.allocator());
    defer process.argsFree(gpa.allocator(), args);

    if (args.len == 1) {
        log.err(arg_error_msg, .{});
        process.exit(1);
    }

    const option = std.fmt.parseInt(u8, args[1], 10) catch {
        log.err(arg_error_msg, .{});
        process.exit(1);
    };

    switch (option) {
        0 => {
            log.info("Running 00 - Smoke Test", .{});
            try smoketest.main();
        },
        1 => {
            log.info("Running 01 - Prime Time", .{});
            try primetime.main();
        },
        2 => {
            log.info("Running 02 - Means to an End", .{});
            try meanstoanend.main();
        },
        else => {
            log.err("test not found, try: 00, 01, ...", .{});
        },
    }
}

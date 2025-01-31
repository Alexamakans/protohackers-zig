const std = @import("std");
const Allocator = std.mem.Allocator;
const net = std.net;
const posix = std.posix;
const math = std.math;

const mnet = @import("../non-blocking-stream.zig");

fn send_error(allocator: Allocator, w: mnet.SpeedDaemonPacketWriter, msg: []const u8) void {
    var s = mnet.String.from_literal(allocator, msg) catch |err| {
        std.debug.print("failed sending server error: {}\n", .{err});
        return;
    };
    defer s.free();
    w.write(mnet.Packet{
        .ServerError = mnet.ServerError{
            .msg = s,
        },
    }) catch |err| {
        std.debug.print("failed sending server error: {}\n", .{err});
    };
}

const MaxDispatchers = 4096;
const MaxPlates = 4096;
const MaxDayTickets = 4096;
const MaxStoredTickets = 4096;
const Brain = struct {
    allocator: ?Allocator = null,
    dispatchers_len: usize = 0,
    dispatchers: [MaxDispatchers]Dispatcher = undefined,
    dispatchers_mutex: std.Thread.Mutex = std.Thread.Mutex{},
    plates_len: usize = 0,
    plates: [MaxPlates]Plate = undefined,
    plates_mutex: std.Thread.Mutex = std.Thread.Mutex{},
    day_tickets_len: usize = 0,
    day_tickets: [MaxDayTickets]DayTicket = undefined,
    stored_tickets_len: usize = 0,
    stored_tickets: [MaxStoredTickets]StoredTicket = undefined,
    const Self = @This();
    fn add_dispatcher(self: *Self, dispatcher: Dispatcher) void {
        self.dispatchers[self.dispatchers_len] = dispatcher;
        self.dispatchers_len += 1;
    }
    fn add_plate(self: *Self, plate: Plate) !void {
        self.plates[self.plates_len] = plate;
        self.plates_len += 1;
    }
    fn remove_dispatcher(self: *Self, dispatcher: Dispatcher) !void {
        if (self.dispatchers_len == 0) {
            return error.NotFound;
        }
        const index = blk: {
            for (self.dispatchers[0..self.dispatchers_len], 0..) |d, i| {
                if (d.r.get_socket() == dispatcher.r.get_socket()) {
                    break :blk i;
                }
            }
            return error.NotFound;
        };

        self.dispatchers[index].roads.free();
        self.dispatchers[index] = self.dispatchers[self.dispatchers_len - 1];
        self.dispatchers_len -= 1;
    }
    fn remove_plate(self: *Self, plate: Plate) !void {
        return try self._remove_plate(plate.plate.plate.data, plate.camera.road, plate.plate.timestamp.value);
    }

    fn _remove_plate(self: *Self, plate: []const u8, road: u16, timestamp: u32) !void {
        if (self.plates_len == 0) {
            return error.NotFound;
        }
        const index = blk: {
            for (self.plates[0..self.plates_len], 0..) |p, i| {
                if (!std.mem.eql(u8, p.plate.plate.data, plate)) {
                    continue;
                }
                if (p.plate.timestamp.value != timestamp) {
                    continue;
                }
                if (p.camera.road != road) {
                    continue;
                }

                break :blk i;
            }
            return error.NotFound;
        };

        self.plates[index].plate.plate.free();
        self.plates[index] = self.plates[self.plates_len - 1];
        self.plates_len -= 1;
    }

    fn lock(self: *Self) void {
        self.dispatchers_mutex.lock();
        self.plates_mutex.lock();
    }

    fn unlock(self: *Self) void {
        self.dispatchers_mutex.unlock();
        self.plates_mutex.unlock();
    }

    fn process(self: *Self) !void {
        self.lock();
        defer self.unlock();
        try self.process_tickets();
        try self.process_plates();
    }

    fn has_ticketed(self: Self, plate: []const u8, day_start: u32, day_end: u32) bool {
        for (self.day_tickets[0..self.day_tickets_len]) |t| {
            if (t.day == day_start or t.day == day_end) {
                if (std.mem.eql(u8, t.plate.data, plate)) {
                    return true;
                }
            }
        }
        return false;
    }

    fn get_dispatcher(self: Self, road: u16) ?Dispatcher {
        for (self.dispatchers[0..self.dispatchers_len]) |dispatcher| {
            for (dispatcher.roads.data) |r| {
                if (r.value == road) {
                    return dispatcher;
                }
            }
        }
        return null;
    }

    fn process_tickets(self: *Self) !void {
        var to_remove: [MaxStoredTickets]usize = undefined;
        var to_remove_len = @as(usize, 0);
        for (self.stored_tickets[0..self.stored_tickets_len], 0..) |ticket, i| {
            const dispatcher = if (self.get_dispatcher(ticket.packet.road.value)) |dispatcher| dispatcher else continue;
            to_remove[to_remove_len] = i;
            to_remove_len += 1;
            const day_start = ticket.packet.timestamp1.value / std.time.s_per_day;
            const day_end = ticket.packet.timestamp2.value / std.time.s_per_day;
            if (self.has_ticketed(ticket.packet.plate.data, day_start, day_end)) {
                continue;
            }

            dispatcher.w.write(mnet.Packet{ .ServerTicket = ticket.packet }) catch |err| {
                if (err == error.EOF) {
                    std.debug.print("--dropped ticket\n", .{});
                    continue;
                } else {
                    return err;
                }
            };

            for (day_start..day_end + 1) |day| {
                var t = DayTicket{
                    .plate = undefined,
                    .day = @intCast(day),
                };
                t.plate = try mnet.String.from_literal(self.allocator.?, ticket.packet.plate.data);
                self.day_tickets[self.day_tickets_len] = t;
                self.day_tickets_len += 1;
            }
        }

        var new_stored_tickets: [MaxStoredTickets]StoredTicket = undefined;
        var new_stored_tickets_len = @as(usize, 0);
        for (0..self.stored_tickets_len) |i| {
            if (std.mem.indexOfScalar(usize, to_remove[0..to_remove_len], i)) |_| {
                self.stored_tickets[i].packet.plate.free();
                continue;
            }
            new_stored_tickets[new_stored_tickets_len] = self.stored_tickets[i];
            new_stored_tickets_len += 1;
        }
        self.stored_tickets = new_stored_tickets;
        self.stored_tickets_len = new_stored_tickets_len;
    }

    fn process_plates(self: *Self) !void {
        std.mem.sort(Plate, self.plates[0..self.plates_len], {}, Plate.less_than);
        var to_remove: [MaxPlates]usize = undefined;
        var to_remove_len = @as(usize, 0);
        for (0..self.plates_len) |i| {
            const a = self.plates[i];
            const day_start = a.plate.timestamp.value / std.time.s_per_day;
            if (self.has_ticketed(a.plate.plate.data, day_start, day_start)) {
                to_remove[to_remove_len] = i;
                to_remove_len += 1;
                continue;
            }
            //if (a.used) {
            //    continue;
            //}
            for (i + 1..self.plates_len) |j| {
                const b = self.plates[j];
                //if (b.used) {
                //    continue;
                //}

                if (a.camera.road != b.camera.road) {
                    continue;
                }

                if (a.camera.mile == b.camera.mile) {
                    continue;
                }

                if (!std.mem.eql(u8, a.plate.plate.data, b.plate.plate.data)) {
                    continue;
                }

                const time_between_seconds: f64 = @floatFromInt(try math.sub(u32, b.plate.timestamp.value, a.plate.timestamp.value));
                const time_between_hours: f64 = time_between_seconds / 3600.0;
                const distance_between_miles: f64 = @floatFromInt(math.sub(u32, a.camera.mile, b.camera.mile) catch try math.sub(u32, b.camera.mile, a.camera.mile));
                const mph: f64 = distance_between_miles / time_between_hours;
                if (mph > 655.35) {
                    continue;
                }
                const speed_100mph: u16 = @intFromFloat(mph * 100);

                if (speed_100mph <= a.camera.limit_mph * 100) {
                    continue;
                }

                const ticket = mnet.ServerTicket{
                    .mile1 = mnet.UInt16{ .value = a.camera.mile },
                    .timestamp1 = mnet.UInt32{ .value = a.plate.timestamp.value },
                    .mile2 = mnet.UInt16{ .value = b.camera.mile },
                    .timestamp2 = mnet.UInt32{ .value = b.plate.timestamp.value },
                    .road = mnet.UInt16{ .value = a.camera.road },
                    .plate = try a.plate.plate.clone(self.allocator.?),
                    .speed_100mph = mnet.UInt16{ .value = speed_100mph },
                };

                self.stored_tickets[self.stored_tickets_len] = StoredTicket{ .road = ticket.road.value, .packet = ticket };
                self.stored_tickets_len += 1;
            }
        }

        var new_plates: [MaxPlates]Plate = undefined;
        var new_plates_len = @as(usize, 0);
        for (0..self.plates_len) |i| {
            if (std.mem.indexOfScalar(usize, to_remove[0..to_remove_len], i)) |_| {
                self.plates[i].plate.plate.free();
                continue;
            }
            new_plates[new_plates_len] = self.plates[i];
            new_plates_len += 1;
        }
        self.plates = new_plates;
        self.plates_len = new_plates_len;
    }
};
var brain: Brain = Brain{};

const Client = union(enum) {
    Pending: Pending,
    Camera: Camera,
    Dispatcher: Dispatcher,
    const Self = @This();
    fn process(self: *Self) !Client {
        switch (self.*) {
            inline else => |*impl| {
                self.* = try impl.process();
                return self.*;
            },
        }
    }
    fn heartbeat(self: *Self) !Client {
        switch (self.*) {
            inline else => |*impl| {
                if (impl.heartbeat_interval_deciseconds != 0) {
                    self.* = try impl.heartbeat();
                }
                return self.*;
            },
        }
    }
};

const Pending = struct {
    last_heartbeat_milliseconds: i64 = 0,
    heartbeat_interval_deciseconds: u32 = 0,
    heartbeat_has_been_set: bool = false,
    m: *std.Thread.Mutex,
    r: mnet.SpeedDaemonPacketReader,
    w: mnet.SpeedDaemonPacketWriter,
    const Self = @This();
    fn process(self: *Self) !Client {
        self.m.lock();
        defer self.m.unlock();
        var slf = self;
        errdefer |err| {
            std.debug.print("pending error: {}\n", .{err});
            send_error(brain.allocator.?, slf.w, "bad stuff");
        }
        while (try slf.r.read(brain.allocator.?)) |packet| {
            switch (packet) {
                .ClientWantHeartbeat => |p| {
                    if (slf.heartbeat_has_been_set) {
                        return error.HeartbeatAlreadySet;
                    }
                    slf.heartbeat_has_been_set = true;
                    slf.heartbeat_interval_deciseconds = p.interval_deciseconds.value;
                },
                .ClientIAmCamera => |p| {
                    return (Camera{
                        .road = p.road.value,
                        .mile = p.mile.value,
                        .limit_mph = p.limit_mph.value,
                        .heartbeat_has_been_set = slf.heartbeat_has_been_set,
                        .last_heartbeat_milliseconds = slf.last_heartbeat_milliseconds,
                        .heartbeat_interval_deciseconds = slf.heartbeat_interval_deciseconds,
                        .m = slf.m,
                        .r = slf.r,
                        .w = slf.w,
                    }).client();
                },
                .ClientIAmDispatcher => |p| {
                    var d = Dispatcher{
                        .roads = p.roads,
                        .heartbeat_has_been_set = slf.heartbeat_has_been_set,
                        .last_heartbeat_milliseconds = slf.last_heartbeat_milliseconds,
                        .heartbeat_interval_deciseconds = slf.heartbeat_interval_deciseconds,
                        .m = slf.m,
                        .r = slf.r,
                        .w = slf.w,
                    };
                    brain.add_dispatcher(d);
                    return d.client();
                },
                else => {
                    return error.InvalidPacketType;
                },
            }
        }

        return slf.client();
    }
    fn heartbeat(self: *Self) !Client {
        self.m.lock();
        defer self.m.unlock();
        var slf = self;
        const now = std.time.milliTimestamp();
        if (now - slf.last_heartbeat_milliseconds > slf.heartbeat_interval_deciseconds * 100) {
            try slf.w.write(mnet.Packet{ .ServerHeartbeat = mnet.ServerHeartbeat{} });
            slf.last_heartbeat_milliseconds = now;
        }
        return slf.client();
    }
    fn client(self: Self) Client {
        return Client{ .Pending = self };
    }
};

const Camera = struct {
    road: u16,
    mile: u16,
    limit_mph: u16,
    heartbeat_has_been_set: bool,
    last_heartbeat_milliseconds: i64,
    heartbeat_interval_deciseconds: u32,
    m: *std.Thread.Mutex,
    r: mnet.SpeedDaemonPacketReader,
    w: mnet.SpeedDaemonPacketWriter,
    const Self = @This();
    fn process(self: *Self) !Client {
        self.m.lock();
        defer self.m.unlock();
        var slf = self;
        errdefer |err| {
            if (err != error.ConnectionResetByPeer) {
                if (err != error.EOF) {
                    std.debug.print("camera error: {}\n", .{err});
                }
                send_error(brain.allocator.?, slf.w, "bad stuff");
            }
        }
        while (try slf.r.read(brain.allocator.?)) |packet| {
            switch (packet) {
                .ClientWantHeartbeat => |p| {
                    if (slf.heartbeat_has_been_set) {
                        return error.HeartbeatAlreadySet;
                    }
                    slf.heartbeat_has_been_set = true;
                    slf.heartbeat_interval_deciseconds = p.interval_deciseconds.value;
                },
                .ClientPlate => |p| {
                    brain.plates_mutex.lock();
                    defer brain.plates_mutex.unlock();
                    try brain.add_plate(Plate{
                        .plate = p,
                        .camera = slf.*,
                    });
                },
                else => {
                    return error.InvalidPacketType;
                },
            }
        }

        return slf.client();
    }
    fn heartbeat(self: *Self) !Client {
        self.m.lock();
        defer self.m.unlock();
        var slf = self;
        const now = std.time.milliTimestamp();
        if (now - slf.last_heartbeat_milliseconds > slf.heartbeat_interval_deciseconds * 100) {
            try slf.w.write(mnet.Packet{ .ServerHeartbeat = mnet.ServerHeartbeat{} });
            slf.last_heartbeat_milliseconds = now;
        }
        return slf.client();
    }
    fn client(self: Self) Client {
        return Client{ .Camera = self };
    }
};

const Dispatcher = struct {
    roads: mnet.UInt16Array,
    heartbeat_has_been_set: bool,
    last_heartbeat_milliseconds: i64,
    heartbeat_interval_deciseconds: u32,
    m: *std.Thread.Mutex,
    r: mnet.SpeedDaemonPacketReader,
    w: mnet.SpeedDaemonPacketWriter,
    const Self = @This();
    fn free(self: *Self) void {
        self.allocator.free(self.roads);
    }
    fn process(self: *Self) !Client {
        self.m.lock();
        defer self.m.unlock();
        var slf = self;
        errdefer |err| {
            if (err != error.EOF) {
                brain.dispatchers_mutex.lock();
                std.debug.print("dispatcher error: {}\n", .{err});
                if (err != error.ConnectionResetByPeer) {
                    send_error(brain.allocator.?, slf.w, "bad stuff");
                }
                brain.remove_dispatcher(self.*) catch {};
                brain.dispatchers_mutex.unlock();
            }
        }
        while (try slf.r.read(brain.allocator.?)) |packet| {
            switch (packet) {
                .ClientWantHeartbeat => |p| {
                    if (slf.heartbeat_has_been_set) {
                        return error.HeartbeatAlreadySet;
                    }
                    slf.heartbeat_has_been_set = true;
                    slf.heartbeat_interval_deciseconds = p.interval_deciseconds.value;
                },
                else => {
                    return error.InvalidPacketType;
                },
            }
        }

        return slf.client();
    }
    fn heartbeat(self: *Self) !Client {
        self.m.lock();
        defer self.m.unlock();
        var slf = self;
        const now = std.time.milliTimestamp();
        if (now - slf.last_heartbeat_milliseconds > slf.heartbeat_interval_deciseconds * 100) {
            try slf.w.write(mnet.Packet{ .ServerHeartbeat = mnet.ServerHeartbeat{} });
            slf.last_heartbeat_milliseconds = now;
        }
        return slf.client();
    }
    fn client(self: Self) Client {
        return Client{ .Dispatcher = self };
    }
};

const Plate = struct {
    camera: Camera,
    plate: mnet.ClientPlate,
    fn less_than(ctx: void, a: Plate, b: Plate) bool {
        _ = ctx;
        return a.plate.timestamp.value < b.plate.timestamp.value;
    }
};

const DayTicket = struct {
    plate: mnet.String,
    day: u32,
};

const StoredTicket = struct {
    road: u16,
    packet: mnet.ServerTicket,
};

pub fn handle(socket: posix.socket_t, _: net.Address) !void {
    const timeout = posix.timeval{ .tv_sec = 0, .tv_usec = std.time.us_per_ms * 1 };
    try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &std.mem.toBytes(timeout));
    try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.SNDTIMEO, &std.mem.toBytes(timeout));

    const r = try mnet.SpeedDaemonPacketReader.create(socket);
    const w = try mnet.SpeedDaemonPacketWriter.create(socket);
    var m = std.Thread.Mutex{};
    var client = (Pending{ .r = r, .w = w, .m = &m }).client();

    while (true) {
        if (brain.allocator == null) {
            continue;
        }
        client = client.process() catch |err| switch (err) {
            error.EOF => {
                //std.debug.print("process: EOF\n", .{});
                break;
            },
            else => return err,
        };
        client = client.heartbeat() catch |err| switch (err) {
            error.EOF => {
                //std.debug.print("heartbeat: EOF\n", .{});
                break;
            },
            else => return err,
        };
    }
}

pub fn handle2() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    {
        brain.lock();
        defer brain.unlock();
        brain.allocator = gpa.allocator();
    }
    while (true) {
        try brain.process();
        std.time.sleep(std.time.ns_per_ms * 1000);
    }
}

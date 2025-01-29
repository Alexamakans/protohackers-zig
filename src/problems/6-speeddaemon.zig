const std = @import("std");
const net = std.net;
const posix = std.posix;
const math = std.math;

const mnet = @import("../non-blocking-stream.zig");

// TODO: Redo this shit?

const Camera = struct {
    road: u16,
    mile: u16,
    limit_mph: u16,
    last_heartbeat_milliseconds: i64,
    heartbeat_interval_deciseconds: u32,
    r: mnet.SpeedDaemonPacketReader,
    w: mnet.SpeedDaemonPacketWriter,
};

const Dispatcher = struct {
    len: u8,
    roads: [255]u16,
    last_heartbeat_milliseconds: i64,
    heartbeat_interval_deciseconds: u32,
    r: mnet.SpeedDaemonPacketReader,
    w: mnet.SpeedDaemonPacketWriter,
};

const Pending = struct {
    last_heartbeat_milliseconds: i64,
    heartbeat_interval_deciseconds: u32,
    r: mnet.SpeedDaemonPacketReader,
    w: mnet.SpeedDaemonPacketWriter,
};

const Plate = struct {
    camera: Camera,
    plate: mnet.ClientPlate,
};

const DayTicket = struct {
    plate_len: u8,
    plate: [256]u8,
    day: u32,
};

const Server = struct {
    cameras_len: usize = 0,
    cameras: [2048]Camera = undefined,
    dispatchers_len: usize = 0,
    dispatchers: [2048]Dispatcher = undefined,
    pending_len: usize = 0,
    pending: [2048]Pending = undefined,
    plates_len: usize = 0,
    plates: [8096]Plate = undefined,
    day_tickets_len: usize = 0,
    day_tickets: [16384]DayTicket = undefined,
    m: std.Thread.Mutex,
    const Self = @This();
    fn create() Self {
        return Server{
            .m = .{},
        };
    }
    fn lock(self: *Self) void {
        self.m.lock();
    }
    fn unlock(self: *Self) void {
        self.m.unlock();
    }
    fn add(self: *Self, pending: Pending) void {
        self.lock();
        defer self.unlock();
        self.pending[self.pending_len] = pending;
        self.pending_len += 1;
    }
    fn process(self: *Self) !void {
        self.lock();
        defer self.unlock();
        var to_remove_pending_len = @as(usize, 0);
        var to_remove_pending: [4096]usize = undefined;
        var to_remove_cameras_len = @as(usize, 0);
        var to_remove_cameras: [4096]usize = undefined;
        var to_remove_dispatchers_len = @as(usize, 0);
        var to_remove_dispatchers: [4096]usize = undefined;
        var to_remove_plates_len = @as(usize, 0);
        var to_remove_plates: [4096]usize = undefined;
        for (self.pending[0..self.pending_len], 0..) |*p, i| {
            var errored = false;
            defer {
                if (errored) {
                    std.debug.print("error, disconnecting\n", .{});
                    p.w.write(mnet.Packet{ .ServerError = mnet.ServerError{ .msg = mnet.String.from_literal("naughty naughty") } }) catch |e| {
                        std.debug.print("failed writing error to client: {}\n", .{e});
                    };
                    posix.shutdown(p.r.get_socket(), .both) catch |e| {
                        std.debug.print("failed shutting down socket (1): {}\n", .{e});
                    };
                    posix.close(p.r.get_socket());
                    if (p.r.get_socket() != p.w.get_socket()) {
                        posix.shutdown(p.w.get_socket(), .both) catch |e| {
                            std.debug.print("failed shutting down socket (2): {}\n", .{e});
                        };
                        posix.close(p.w.get_socket());
                    }
                    to_remove_pending[to_remove_pending_len] = i;
                    to_remove_pending_len += 1;
                }
            }
            while (p.r.read()) |pkt| {
                if (pkt) |packet| {
                    //std.debug.print("successfully read {s}\n", .{@typeName(@TypeOf(pkt))});
                    switch (packet) {
                        .ClientWantHeartbeat => |impl| {
                            if (p.heartbeat_interval_deciseconds != 0) {
                                return error.RepeatWantHeartbeatRequests;
                            }
                            p.heartbeat_interval_deciseconds = impl.interval_deciseconds.value;
                            std.debug.print("Set heartbeat interval to {} deciseconds\n", .{p.heartbeat_interval_deciseconds});
                            break;
                        },
                        .ClientIAmCamera => |impl| {
                            to_remove_pending[to_remove_pending_len] = i;
                            to_remove_pending_len += 1;
                            self.cameras[self.cameras_len] = Camera{
                                .road = impl.road.value,
                                .mile = impl.mile.value,
                                .limit_mph = impl.limit_mph.value,
                                .last_heartbeat_milliseconds = 0,
                                .heartbeat_interval_deciseconds = p.heartbeat_interval_deciseconds,
                                .r = p.r,
                                .w = p.w,
                            };
                            self.cameras_len += 1;
                            // break to allow transfer to cameras array
                        },
                        .ClientIAmDispatcher => |impl| {
                            to_remove_pending[to_remove_pending_len] = i;
                            to_remove_pending_len += 1;

                            var d = Dispatcher{
                                .len = impl.roads.len,
                                .roads = undefined,
                                .last_heartbeat_milliseconds = 0,
                                .heartbeat_interval_deciseconds = p.heartbeat_interval_deciseconds,
                                .r = p.r,
                                .w = p.w,
                            };
                            for (d.roads[0..d.len], impl.roads.data[0..d.len]) |*road, s| {
                                road.* = s.value;
                            }
                            self.dispatchers[self.dispatchers_len] = d;
                            self.dispatchers_len += 1;
                            // break to allow transfer to dispatchers array
                        },
                        inline else => |impl| {
                            std.debug.print("received invalid packet from pending: {s}\n", .{@typeName(@TypeOf(impl))});
                            return error.InvalidPacket;
                        },
                    }
                } else {
                    // no more data for now
                    break;
                }
            } else |err| {
                errored = true;
                std.debug.print("pending: error: {}\n", .{err});
            }
        }

        for (self.cameras[0..self.cameras_len], 0..) |*p, i| {
            var errored = false;
            defer {
                if (errored) {
                    std.debug.print("error, disconnecting\n", .{});
                    p.w.write(mnet.Packet{ .ServerError = mnet.ServerError{ .msg = mnet.String.from_literal("naughty naughty camera") } }) catch |e| {
                        std.debug.print("failed writing error to client: {}\n", .{e});
                    };
                    posix.shutdown(p.r.get_socket(), .both) catch |e| {
                        std.debug.print("failed shutting down socket (1): {}\n", .{e});
                    };
                    posix.close(p.r.get_socket());
                    if (p.r.get_socket() != p.w.get_socket()) {
                        posix.shutdown(p.w.get_socket(), .both) catch |e| {
                            std.debug.print("failed shutting down socket (2): {}\n", .{e});
                        };
                        posix.close(p.w.get_socket());
                    }
                    to_remove_cameras[to_remove_cameras_len] = i;
                    to_remove_cameras_len += 1;
                }
            }
            while (p.r.read()) |pkt| {
                if (pkt) |packet| {
                    //std.debug.print("successfully read {s}\n", .{@typeName(@TypeOf(pkt))});
                    switch (packet) {
                        .ClientWantHeartbeat => |impl| {
                            if (p.heartbeat_interval_deciseconds != 0) {
                                return error.RepeatWantHeartbeatRequests;
                            }
                            p.heartbeat_interval_deciseconds = impl.interval_deciseconds.value;
                            //std.debug.print("Set heartbeat interval to {} deciseconds\n", .{p.heartbeat_interval_deciseconds});
                        },
                        .ClientPlate => |impl| {
                            var pl = Plate{
                                .plate = mnet.ClientPlate{
                                    .plate = mnet.String{
                                        .len = impl.plate.len,
                                        .data = undefined,
                                    },
                                    .timestamp = impl.timestamp,
                                },
                                .camera = p.*,
                            };
                            const len = pl.plate.plate.len;
                            std.mem.copyForwards(u8, pl.plate.plate.data[0..len], impl.plate.get());
                            self.plates[self.plates_len] = pl;
                            self.plates_len += 1;
                        },
                        inline else => |impl| {
                            std.debug.print("received invalid packet from pending: {s}\n", .{@typeName(@TypeOf(impl))});
                            return error.InvalidPacket;
                        },
                    }
                } else {
                    // no more data for now
                    break;
                }
            } else |err| {
                errored = true;
                std.debug.print("camera: error: {}\n", .{err});
            }
        }

        for (self.dispatchers[0..self.dispatchers_len], 0..) |*p, i| {
            var errored = false;
            defer {
                if (errored) {
                    std.debug.print("error, disconnecting\n", .{});
                    p.w.write(mnet.Packet{ .ServerError = mnet.ServerError{ .msg = mnet.String.from_literal("naughty naughty dispatcher") } }) catch |e| {
                        std.debug.print("failed writing error to client: {}\n", .{e});
                    };
                    posix.shutdown(p.r.get_socket(), .both) catch |e| {
                        std.debug.print("failed shutting down socket (1): {}\n", .{e});
                    };
                    posix.close(p.r.get_socket());
                    if (p.r.get_socket() != p.w.get_socket()) {
                        posix.shutdown(p.w.get_socket(), .both) catch |e| {
                            std.debug.print("failed shutting down socket (2): {}\n", .{e});
                        };
                        posix.close(p.w.get_socket());
                    }
                    to_remove_dispatchers[to_remove_dispatchers_len] = i;
                    to_remove_dispatchers_len += 1;
                }
            }
            while (p.r.read()) |pkt| {
                if (pkt) |packet| {
                    //std.debug.print("successfully read {s}\n", .{@typeName(@TypeOf(pkt))});
                    switch (packet) {
                        .ClientWantHeartbeat => |impl| {
                            if (p.heartbeat_interval_deciseconds != 0) {
                                return error.RepeatWantHeartbeatRequests;
                            }
                            p.heartbeat_interval_deciseconds = impl.interval_deciseconds.value;
                            //std.debug.print("Set heartbeat interval to {} deciseconds\n", .{p.heartbeat_interval_deciseconds});
                        },
                        inline else => |impl| {
                            std.debug.print("received invalid packet from pending: {s}\n", .{@typeName(@TypeOf(impl))});
                            return error.InvalidPacket;
                        },
                    }
                } else {
                    // no more data for now
                    break;
                }
            } else |err| {
                errored = true;
                std.debug.print("dispatcher: error: {}\n", .{err});
            }
        }

        {
            var len = @as(usize, 0);
            for (self.pending[0..self.pending_len], 0..) |p, i| {
                const needle: [1]usize = .{i};
                if (!std.mem.containsAtLeast(usize, to_remove_pending[0..to_remove_pending_len], 1, &needle)) {
                    self.pending[len] = p;
                    len += 1;
                }
            }
            self.pending_len = len;
        }

        {
            var len = @as(usize, 0);
            for (self.cameras[0..self.cameras_len], 0..) |p, i| {
                const needle: [1]usize = .{i};
                if (!std.mem.containsAtLeast(usize, to_remove_cameras[0..to_remove_cameras_len], 1, &needle)) {
                    self.cameras[len] = p;
                    len += 1;
                }
            }
            self.cameras_len = len;
        }

        {
            var len = @as(usize, 0);
            for (self.dispatchers[0..self.dispatchers_len], 0..) |p, i| {
                const needle: [1]usize = .{i};
                if (!std.mem.containsAtLeast(usize, to_remove_dispatchers[0..to_remove_dispatchers_len], 1, &needle)) {
                    self.dispatchers[len] = p;
                    len += 1;
                }
            }
            self.dispatchers_len = len;
        }

        std.mem.sort(Plate, self.plates[0..self.plates_len], {}, struct {
            fn lessThan(context: void, a: Plate, b: Plate) bool {
                _ = context;
                if (a.plate.timestamp.value == b.plate.timestamp.value) {
                    return a.camera.mile < b.camera.mile;
                }
                return a.plate.timestamp.value < b.plate.timestamp.value;
            }
        }.lessThan);
        for (0..self.plates_len) |i| {
            for (i + 1..self.plates_len) |j| {
                const a = self.plates[i];
                const b = self.plates[j];
                std.debug.assert(a.plate.timestamp.value <= b.plate.timestamp.value);
                if (!std.mem.eql(u8, a.plate.plate.get(), b.plate.plate.get())) {
                    continue;
                }

                if (a.camera.road != b.camera.road) {
                    continue;
                }

                const time_between_seconds: f64 = @floatFromInt(try math.sub(u32, b.plate.timestamp.value, a.plate.timestamp.value));
                const distance_between_miles: f64 = @floatFromInt(math.sub(u16, b.camera.mile, a.camera.mile) catch
                    try math.sub(u16, a.camera.mile, b.camera.mile));
                if (distance_between_miles == 0) {
                    //std.debug.print("distance is 0\n", .{});
                    continue;
                }
                const day_start = a.plate.timestamp.value / std.time.s_per_day;
                const day_end = b.plate.timestamp.value / std.time.s_per_day;

                //if (day_start != day_end) {
                //continue;
                //}

                std.debug.assert(a.camera.limit_mph == b.camera.limit_mph);
                std.debug.assert(time_between_seconds > 0);
                const time_between_hours = time_between_seconds / 3600.0;
                //std.debug.print("tbh: {}, dbm: {}\n", .{ time_between_hours, distance_between_miles });
                const asdf = (distance_between_miles / time_between_hours) * 100.0;
                if (asdf > 65535.0) {
                    continue;
                }
                const mph: u16 = @intFromFloat(asdf);
                //std.debug.print("mph = {}\n", .{mph});
                if (mph > b.camera.limit_mph * 100) {
                    //std.debug.print("day {} -> {}\n", .{ day_start, day_end });
                    const already_ticketed = blk: {
                        for (self.day_tickets[0..self.day_tickets_len]) |t| {
                            //std.debug.print("ticket on day {} for {s}\n", .{ t.day, t.plate[0..t.plate_len] });
                            if (t.day >= day_start and t.day <= day_end) {
                                if (std.mem.eql(u8, t.plate[0..t.plate_len], a.plate.plate.get())) {
                                    break :blk true;
                                }
                            }
                        }
                        break :blk false;
                    };
                    if (already_ticketed) {
                        //std.debug.print("already ticketed\n", .{});
                        continue;
                    }
                    //std.debug.print("TICKETING {s} on day(s) {} -> {}\n", .{ a.plate.plate.get(), day_start, day_end });

                    const dispatcher = blk: {
                        for (self.dispatchers[0..self.dispatchers_len]) |d| {
                            for (d.roads[0..d.len]) |road| {
                                if (road == a.camera.road) {
                                    break :blk d;
                                }
                            }
                        }
                        //std.debug.print("no matching dispatcher yet\n", .{});
                        //return error.NoMatchingDispatcherYet;
                        continue;
                    };

                    // make sure to remove even if dispatcher disconnects, maybe?
                    to_remove_plates[to_remove_plates_len] = i;
                    to_remove_plates_len += 1;
                    to_remove_plates[to_remove_plates_len] = j;
                    to_remove_plates_len += 1;

                    dispatcher.w.write(mnet.Packet{ .ServerTicket = mnet.ServerTicket{
                        .road = mnet.UInt16{ .value = a.camera.road },
                        .plate = a.plate.plate,
                        .mile1 = mnet.UInt16{ .value = a.camera.mile },
                        .mile2 = mnet.UInt16{ .value = b.camera.mile },
                        .timestamp1 = a.plate.timestamp,
                        .timestamp2 = b.plate.timestamp,
                        .speed_100mph = mnet.UInt16{ .value = mph },
                    } }) catch {
                        continue;
                    };

                    for (day_start..day_end + 1) |day| {
                        const len = a.plate.plate.len;
                        var day_ticket = DayTicket{
                            .plate_len = len,
                            .plate = undefined,
                            .day = @intCast(day),
                        };
                        std.mem.copyForwards(u8, day_ticket.plate[0..len], a.plate.plate.get());
                        self.day_tickets[self.day_tickets_len] = day_ticket;
                        self.day_tickets_len += 1;
                    }
                }
            }
        }

        {
            var len = @as(usize, 0);
            for (self.plates[0..self.plates_len], 0..) |p, i| {
                const needle: [1]usize = .{i};
                if (!std.mem.containsAtLeast(usize, to_remove_plates[0..to_remove_plates_len], 1, &needle)) {
                    self.plates[len] = p;
                    len += 1;
                }
            }
            self.plates_len = len;
        }

        try heartbeat(&self.pending, self.pending_len);
        try heartbeat(&self.cameras, self.cameras_len);
        try heartbeat(&self.dispatchers, self.dispatchers_len);

        //std.debug.print("num pending: {}\n", .{self.pending_len});
        //std.debug.print("num cameras: {}\n", .{self.cameras_len});
        //std.debug.print("num dispatchers: {}\n", .{self.dispatchers_len});
    }
    fn heartbeat(items: anytype, len: usize) !void {
        const now = std.time.milliTimestamp();
        for (items[0..len]) |*item| {
            if (item.heartbeat_interval_deciseconds == 0) {
                continue;
            }

            if (now - item.last_heartbeat_milliseconds > item.heartbeat_interval_deciseconds * 100) {
                try item.w.write(mnet.Packet{ .ServerHeartbeat = mnet.ServerHeartbeat{} });
                @field(@constCast(item), "last_heartbeat_milliseconds") = now;
            }
        }
    }
};

var server = Server.create();

pub fn handle(socket: posix.socket_t, _: net.Address) !void {
    const timeout = posix.timeval{ .tv_sec = 0, .tv_usec = std.time.us_per_ms * 1 };
    try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &std.mem.toBytes(timeout));
    try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.SNDTIMEO, &std.mem.toBytes(timeout));

    const r = try mnet.SpeedDaemonPacketReader.create(socket);
    const w = try mnet.SpeedDaemonPacketWriter.create(socket);
    server.add(Pending{ .r = r, .w = w, .last_heartbeat_milliseconds = 0, .heartbeat_interval_deciseconds = 0 });
}

pub fn handle2() !void {
    while (true) {
        try server.process();
        std.time.sleep(std.time.ns_per_us * 50);
    }
}

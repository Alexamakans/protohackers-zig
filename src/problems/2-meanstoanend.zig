const std = @import("std");
const net = std.net;
const posix = std.posix;
const Allocator = std.mem.Allocator;
const PacketReader = @import("../readers.zig").PacketReader;
const PacketWriter = @import("../writers.zig").PacketWriter;
const Stream = @import("../stream.zig").Stream;

const Packet = struct {
    type: u8,
    timestamp: i32,
    price: i32,
};

pub fn handle(socket: posix.socket_t, client_address: net.Address) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator: Allocator = gpa.allocator();

    const read_packet_length = 9;
    const write_packet_length = 4;

    std.debug.print("{} connected\n", .{client_address});
    defer posix.close(socket);

    var reader = try PacketReader.init(allocator, socket, read_packet_length);
    defer reader.deinit(allocator);
    var writer = PacketWriter.create(socket, write_packet_length);
    var stream = Stream.create(reader.reader(), writer.writer());
    while (stream.read()) |message| {
        const packet = Packet{
            .type = message[0],
            .timestamp = std.mem.readInt(i32, message[1..5], std.builtin.Endian.big),
            .price = std.mem.readInt(i32, message[5..9], std.builtin.Endian.big),
        };

        std.debug.print("type = {}, timestamp = {}, price = {}\n", .{ packet.type, packet.timestamp, packet.price });
        switch (packet.type) {
            'I' => {
                // Insert
                // An insert message lets the client insert a timestamped price.
                //
                // The message format is:
                //
                // Byte:  |  0  |  1     2     3     4  |  5     6     7     8  |
                // Type:  |char |         int32         |         int32         |
                // Value: | 'I' |       timestamp       |         price         |
                // The first int32 is the timestamp, in seconds since 00:00, 1st Jan 1970.
                //
                // The second int32 is the price, in pennies, of this client's asset, at the given timestamp.
            },
            'Q' => {
                // A query message lets the client query the average price over a given time period.
                // The message format is:
                //
                // Byte:  |  0  |  1     2     3     4  |  5     6     7     8  |
                // Type:  |char |         int32         |         int32         |
                // Value: | 'Q' |        mintime        |        maxtime        |
                // The first int32 is mintime, the earliest timestamp of the period.
                //
                // The second int32 is maxtime, the latest timestamp of the period.
                //
                // The server must compute the mean of the inserted prices with timestamps T, mintime <= T <= maxtime (i.e. timestamps in the closed interval [mintime, maxtime]). If the mean is not an integer, it is acceptable to round either up or down, at the server's discretion.
            },
            else => {
                std.debug.print("unsupported packet type '{}'\n", .{packet.type});
                return error.ParseError;
            },
        }
    } else |err| if (err != error.Closed) {
        std.debug.print("error reading message: {}\n", .{err});
    } else {
        std.debug.print("{} disconnected\n", .{client_address});
    }
}

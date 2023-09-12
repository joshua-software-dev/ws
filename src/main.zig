const std = @import("std");
const net = std.net;
const mem = std.mem;
const io = std.io;

// these can be used directly too
pub const Header = [2][]const u8;

pub const buffered = @import("buffered/buffered.zig");
pub const create_buffered_client = buffered.create_buffered_client;
pub const Client = buffered.Client;
pub const Connection = buffered.Connection;

pub const unbuffered = @import("unbuffered/unbuffered.zig");
pub const create_unbuffered_client = unbuffered.create_unbuffered_client;
pub const UnbufferedClient = unbuffered.UnbufferedClient;
pub const UnbufferedConnection = unbuffered.UnbufferedConnection;

pub const Address = union(enum) {
    ip: std.net.Address,
    host: []const u8,

    pub fn resolve(host: []const u8, port: u16) Address {
        const ip = std.net.Address.parseIp(host, port) catch return Address{ .host = host };
        return Address{ .ip = ip };
    }
};

// TODO: implement TLS connection
/// Open a new WebSocket connection.
/// Allocator is used for DNS resolving of host and the storage of response headers.
pub fn connect(allocator: mem.Allocator, uri: std.Uri, request_headers: ?[]const Header) !Connection {
    const port: u16 = uri.port orelse
        if (mem.eql(u8, uri.scheme, "ws")) 80
        else if (mem.eql(u8, uri.scheme, "wss")) 443
        else return error.UnknownScheme;

    var stream = try switch (Address.resolve(uri.host orelse return error.MissingHost, port)) {
        .ip => |ip| net.tcpConnectToAddress(ip),
        .host => |host| net.tcpConnectToHost(allocator, host, port),
    };
    errdefer stream.close();

    return Connection.init(allocator, stream, uri, request_headers);
}

/// If Allocator is not null, it is used for DNS resolving of host, otherwise
/// only IP addresses can be connected to.
///
/// Note: Despite the name, this connection is not completely without buffers.
/// Very small buffers (125 bytes or less) are used judiciously when
/// appropriate, one moderately large buffer (16384 bytes) is used briefly
/// during connection initialization, and some functions may accept buffers to
/// receive into so that the buffer size is in the caller's control. While the
/// very small buffers use cannot be stopped by the caller, no buffer is
/// required for sending or receiving from the connection, the functions
/// accepting buffers are merely provided as a convenience.
pub fn connect_unbuffered(allocator: ?mem.Allocator, uri: std.Uri, request_headers: ?[]const Header) !UnbufferedConnection {
    const port: u16 = uri.port orelse
        if (mem.eql(u8, uri.scheme, "ws")) 80
        else if (mem.eql(u8, uri.scheme, "wss")) 443
        else return error.UnknownScheme;

    var stream: net.Stream = undefined;
    switch (Address.resolve(uri.host orelse return error.MissingHost, port)) {
        .ip => |ip|
        {
            stream = try net.tcpConnectToAddress(ip);
        },
        .host => |host|
        {
            if (allocator == null) return error.CannotAllocate;
            stream = try net.tcpConnectToHost(allocator.?, host, port);
        },
    }
    errdefer stream.close();

    return UnbufferedConnection.init(stream, uri, request_headers);
}

test "Simple buffered connection to :8080" {
    std.debug.print("\n", .{});
    const allocator = std.testing.allocator;

    var cli = try connect(allocator, try std.Uri.parse("ws://localhost:6463"), &.{
        .{"Host",   "localhost"},
        .{"Origin", "http://localhost/"},
    });
    defer cli.deinit(allocator);

    while (true) {
        const msg = try cli.receive(500);
        switch (msg.type) {
            .text => {
                std.debug.print("received: {s}\n", .{msg.data});
                try cli.send(.text, msg.data);
            },

            .ping => {
                std.debug.print("got ping! sending pong...\n", .{});
                try cli.pong();
            },

            .close => {
                std.debug.print("close\n", .{});
                break;
            },

            else => {
                std.debug.print("got {s}: {s}\n", .{@tagName(msg.type), msg.data});
            },
        }
    }

    try cli.close();
}

test "Simple unbuffered connection to :8080" {
    std.debug.print("\n", .{});
    const allocator = std.testing.allocator;
    _ = allocator;

    var cli = try connect_unbuffered(null, try std.Uri.parse("ws://127.0.0.1:8080"), &.{
        .{"Host",   "127.0.0.1"},
        .{"Origin", "http://localhost/"},
    });
    defer cli.deinit();

    var new_msg = false;
    var buf = try std.BoundedArray(u8, 1024).init(0);
    while (true) {
        var msg = try cli.receiveUnbuffered(0, 500);
        switch (msg.type) {
            .text => {
                switch (msg.data) {
                    .slice => |slice| {
                        std.debug.print("received: {s}\n", .{slice});
                        try cli.send(.text, slice);
                        new_msg = true;
                    },
                    .reader => |*reader| {
                        // not the most optimal way to do this
                        var limited_reader = reader.message_reader.reader();
                        for (0..reader.message_reader.bytes_left) |_| {
                            try buf.append(limited_reader.readByte() catch unreachable);
                        }

                        if (reader.message_complete) {
                            new_msg = true;
                            std.debug.print("received: {s}\n", .{buf.constSlice()});
                            try cli.send(.text, buf.constSlice());
                        }
                    },
                    else => unreachable
                }
            },

            .ping => {
                std.debug.print("got ping! sending pong...\n", .{});
                try cli.pong();
            },

            .close => {
                std.debug.print("close\n", .{});
                break;
            },

            else => {
                std.debug.print("got {s}: {any}\n", .{@tagName(msg.type), msg.data});
            },
        }

        if (new_msg) {
            buf.len = 0;
            new_msg = false;
        }
    }

    try cli.close();
}

test "Simple unbuffered writer connection to :8080" {
    std.debug.print("\n", .{});
    const allocator = std.testing.allocator;

    var cli = try connect_unbuffered(null, try std.Uri.parse("ws://127.0.0.1:8080"), &.{
        .{"Host",   "127.0.0.1"},
        .{"Origin", "http://localhost/"},
    });
    defer cli.deinit();

    var buf = std.ArrayList(u8).init(allocator);
    while (true) {
        buf.clearRetainingCapacity();
        var msg = try cli.receiveIntoWriter(buf.writer(), 0, 500);
        switch (msg.type) {
            .text => {
                switch (msg.data) {
                    .slice => |slice| {
                        std.debug.print("received: {s}\n", .{slice});
                        try cli.send(.text, slice);
                    },
                    .written => |write_length| {
                        const out = buf.items[0..write_length];
                        std.debug.print("received: {s}\n", .{out});
                        try cli.send(.text, out);
                    },
                    else => unreachable
                }
            },

            .ping => {
                std.debug.print("got ping! sending pong...\n", .{});
                try cli.pong();
            },

            .close => {
                std.debug.print("close\n", .{});
                break;
            },

            else => {
                std.debug.print("got {s}: {any}\n", .{@tagName(msg.type), msg.data});
            },
        }
    }

    try cli.close();
}

test "Simple unbuffered connection with local buffer to :8080" {
    std.debug.print("\n", .{});
    const allocator = std.testing.allocator;
    _ = allocator;

    var cli = try connect_unbuffered(null, try std.Uri.parse("ws://127.0.0.1:8080"), &.{
        .{"Host",   "127.0.0.1"},
        .{"Origin", "http://localhost/"},
    });
    defer cli.deinit();

    while (true) {
        var buf: [1024]u8 = undefined;
        var msg = try cli.receiveIntoBuffer(&buf, 500);
        switch (msg.type) {
            .text => {
                switch (msg.data) {
                    .slice => |slice| {
                        std.debug.print("received: {s}\n", .{slice});
                        try cli.send(.text, slice);
                    },
                    else => unreachable
                }
            },

            .ping => {
                std.debug.print("got ping! sending pong...\n", .{});
                try cli.pong();
            },

            .close => {
                std.debug.print("close\n", .{});
                break;
            },

            else => {
                std.debug.print("got {s}: {any}\n", .{@tagName(msg.type), msg.data});
            },
        }
    }

    try cli.close();
}

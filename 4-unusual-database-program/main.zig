const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;
const testing = std.testing;
const posix = std.posix;
const linux = std.os.linux;
const net = std.net;

const ServerConfig = struct {
    address: []const u8,
    port: u16,
    max_events: u32,
};

const Server = struct {
    config: ServerConfig,
    allocator: mem.Allocator,
    epoll_fd: posix.fd_t,
    sock: posix.socket_t,
    db: std.StringHashMap([]const u8),

    fn init(allocator: mem.Allocator, config: ServerConfig) !Server {
        var server = Server{
            .config = config,
            .allocator = allocator,
            .epoll_fd = try posix.epoll_create1(0),
            .sock = try createSock(config),
            .db = std.StringHashMap([]const u8).init(allocator),
        };

        try server.db.ensureTotalCapacity(500);

        try server.setupEpoll();
        return server;
    }

    fn deinit(self: *Server) void {
        var it = self.db.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }

        self.db.deinit();
        posix.close(self.epoll_fd);
        posix.close(self.sock);
    }

    fn createSock(config: ServerConfig) !posix.socket_t {
        const address = try net.Address.parseIp(config.address, config.port);
        const sockfd: posix.socket_t = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM | posix.SOCK.NONBLOCK, 0);
        errdefer posix.close(sockfd);

        try posix.setsockopt(sockfd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &mem.toBytes(@as(c_int, 1)));
        try posix.bind(sockfd, &address.any, address.getOsSockLen());
        // try posix.listen(sockfd, @as(u31, @intCast(config.max_events)));
        return sockfd;
    }

    fn setupEpoll(self: *Server) !void {
        var event = linux.epoll_event{
            .events = linux.EPOLL.IN | linux.EPOLL.ET,
            .data = .{ .fd = self.sock },
        };

        try posix.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, self.sock, &event);
    }

    fn run(self: *Server) !void {
        var events: []linux.epoll_event = try self.allocator.alloc(linux.epoll_event, self.config.max_events);
        defer self.allocator.free(events);

        std.log.info("Server is listening on port {d}", .{self.config.port});

        var recv_msg_buf = try self.allocator.alloc(u8, 1024);
        defer self.allocator.free(recv_msg_buf);

        while (true) {
            std.log.info("Waiting a request\n", .{});
            const n = posix.epoll_wait(self.epoll_fd, events, -1);
            std.log.info("Got a request\n", .{});
            for (events[0..n]) |event| {
                if (event.events & linux.EPOLL.IN != 0) {
                    var client_addr: posix.sockaddr = undefined;
                    var client_addr_len: posix.socklen_t = @sizeOf(@TypeOf(client_addr));
                    const recv_size = try posix.recvfrom(self.sock, recv_msg_buf, 0, &client_addr, &client_addr_len);

                    if (recv_size > recv_msg_buf.len) {
                        std.log.err("Received message too large for buffer", .{});
                        continue;
                    }

                    const recv_msg = recv_msg_buf[0..recv_size];
                    const stripped_recv_message = mem.trimRight(u8, recv_msg, "\n");

                    // std.log.info("0x{x}\n", .{stripped_recv_message});
                    std.log.info("{s}\n", .{stripped_recv_message});
                    if (mem.eql(u8, stripped_recv_message, "version")) {
                        _ = try posix.sendto(self.sock, "version=Ken's Key-Value Store 1.0", 0, &client_addr, client_addr_len);
                        // std.log.info("version=Ken's Key-Value Store 1.0\n", .{});
                        continue;
                    }

                    if (mem.indexOfScalar(u8, stripped_recv_message, '=')) |eq_delim_i| {
                        if (mem.startsWith(u8, stripped_recv_message, "=")) {
                            try self.db.put("", stripped_recv_message[eq_delim_i + 1 ..]);
                        } else {
                            // std.log.info("set key: {s}\nvalue: {s}\n", .{ stripped_recv_message[0..eq_delim_i], stripped_recv_message[eq_delim_i + 1 ..] });
                            // std.debug.print("db size: {d}\n", .{self.db.count()});
                            try self.db.put(stripped_recv_message[0..eq_delim_i], stripped_recv_message[eq_delim_i + 1 ..]);
                        }
                    } else {
                        if (self.db.getEntry(stripped_recv_message)) |entry| {
                            const resp_msg = try fmt.allocPrint(self.allocator, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* });
                            defer self.allocator.free(resp_msg);
                            _ = try posix.sendto(self.sock, resp_msg, 0, &client_addr, client_addr_len);
                            // std.log.info("{s}\n", .{resp_msg});
                        } else {
                            std.log.err("entry's not found!\n", .{});
                        }
                    }
                }
            }
        }
    }
};

fn splitKeyVal(payload: []const u8) struct { key: []const u8, val: []const u8 } {
    if (mem.indexOfScalar(u8, payload, '=')) |eq_delim_i| {
        if (mem.startsWith(u8, payload, "=")) {
            return .{ .key = "", .val = payload[eq_delim_i + 1 ..] };
        } else {
            return .{ .key = payload[0..eq_delim_i], .val = payload[eq_delim_i + 1 ..] };
        }
    } else {
        unreachable;
    }
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const config = ServerConfig{
        .address = "0.0.0.0",
        .port = 8000,
        .max_events = 100,
    };

    var server = try Server.init(allocator, config);
    defer server.deinit();

    try server.run();
}

test "test insert: foo=bar" {
    const result = splitKeyVal("foo=bar");
    try testing.expectEqualStrings("foo", result.key);
    try testing.expectEqualStrings("bar", result.val);
}

test "test insert: foo=bar=baz" {
    const result = splitKeyVal("foo=bar=baz");
    try testing.expectEqualStrings("foo", result.key);
    try testing.expectEqualStrings("bar=baz", result.val);
}

test "test insert: foo=" {
    const result = splitKeyVal("foo=");
    try testing.expectEqualStrings("foo", result.key);
    try testing.expectEqualStrings("", result.val);
}

test "test insert: foo===" {
    const result = splitKeyVal("foo===");
    try testing.expectEqualStrings("foo", result.key);
    try testing.expectEqualStrings("==", result.val);
}

test "test insert: =foo" {
    const result = splitKeyVal("=foo");
    try testing.expectEqualStrings("", result.key);
    try testing.expectEqualStrings("foo", result.val);
}

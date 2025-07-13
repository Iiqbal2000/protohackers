const std = @import("std");
const net = std.net;
const linux = std.os.linux;
const mem = std.mem;
const log = std.log;
const Allocator = mem.Allocator;

const ClientManager = struct {
    clients: std.AutoHashMap(linux.fd_t, ?*User),
    allocator: Allocator,

    fn init(allocator: Allocator) ClientManager {
        return .{
            .clients = std.AutoHashMap(linux.fd_t, ?*User).init(allocator),
            .allocator = allocator,
        };
    }

    fn deinit(self: *ClientManager) void {
        var it = self.clients.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*) |user| {
                self.allocator.free(user.name);
                self.allocator.destroy(user);
            }
        }
        self.clients.deinit();
    }

    fn add(self: *ClientManager, fd: linux.fd_t) !void {
        try self.clients.put(fd, null);
    }

    fn remove(self: *ClientManager, fd: linux.fd_t) void {
        if (self.clients.fetchRemove(fd)) |entry| {
            if (entry.value) |user| {
                self.allocator.free(user.name);
                self.allocator.destroy(user);
            }
            log.info("Client removed: {}", .{fd});
        } else {
            log.err("Failed to remove client: {}", .{fd});
        }
    }

    fn get(self: *ClientManager, fd: linux.fd_t) ?*User {
        return if (self.clients.get(fd)) |maybe_user| maybe_user else null;
    }

    fn setUser(self: *ClientManager, fd: linux.fd_t, user: *User) !void {
        try self.clients.put(fd, user);
    }
};

const ClientStream = struct {
    buffer: []u8,
    stream: net.Stream,
    pos: usize,
    done: bool,

    fn create(fd: linux.fd_t, allocator: Allocator) !*ClientStream {
        const buffer = try allocator.alloc(u8, 1024);
        const client_stream = try allocator.create(ClientStream);
        client_stream.* = .{
            .buffer = buffer,
            .stream = net.Stream{ .handle = fd },
            .pos = 0,
            .done = false,
        };
        return client_stream;
    }

    fn deinit(self: *ClientStream, allocator: Allocator) void {
        allocator.free(self.buffer);
        allocator.destroy(self);
    }

    fn readLine(self: *ClientStream, allocator: Allocator) !usize {
        if (self.done) {
            self.pos = 0;
            self.done = false;
        }

        var tmp_buffer = try allocator.alloc(u8, 1024);
        defer allocator.free(tmp_buffer);

        while (true) {
            const received_byte = self.stream.read(tmp_buffer) catch |err| {
                switch (err) {
                    std.posix.ReadError.WouldBlock => return self.pos, // Not an error, just non-blocking behavior
                    else => return err,
                }
            };

            if (received_byte == 0) return 0;

            if (mem.indexOfScalar(u8, tmp_buffer[0..received_byte], '\n')) |index| {
                const stripped_line = strippedLineEndings(tmp_buffer[0 .. index + 1]);
                @memcpy(self.buffer[self.pos..][0..stripped_line.len], stripped_line);
                self.pos += stripped_line.len;
                self.done = true;
                return self.pos;
            } else {
                @memcpy(self.buffer[self.pos..][0..received_byte], tmp_buffer[0..received_byte]);
                self.pos += received_byte;
            }
        }
    }

    fn strippedLineEndings(line: []u8) []u8 {
        if (std.mem.endsWith(u8, line, "\r\n")) {
            return line[0 .. line.len - 2];
        } else if (std.mem.endsWith(u8, line, "\n")) {
            return line[0 .. line.len - 1];
        } else {
            return line;
        }
    }
};

const User = struct {
    name: []const u8,

    fn create(allocator: Allocator, name: []const u8) !*User {
        const user = try allocator.create(User);
        user.* = .{ .name = name };
        return user;
    }

    fn isValidName(buffer: []const u8) bool {
        if (buffer.len == 0 or buffer.len > 16) return false;
        for (buffer) |char| {
            if (!std.ascii.isAlphanumeric(char)) return false;
        }

        return true;
    }
};

const ServerConfig = struct {
    address: []const u8,
    port: u16,
    max_events: u32,
};

const ChatServer = struct {
    config: ServerConfig,
    allocator: Allocator,
    clients: ClientManager,
    epoll_fd: linux.fd_t,
    server_socket: linux.socket_t,

    fn init(allocator: Allocator, config: ServerConfig) !ChatServer {
        var server = ChatServer{
            .config = config,
            .allocator = allocator,
            .clients = ClientManager.init(allocator),
            .epoll_fd = @intCast(linux.epoll_create()),
            .server_socket = try createServerSocket(config),
        };

        try server.setupEpoll();

        return server;
    }

    fn deinit(self: *ChatServer) void {
        self.clients.deinit();
        _ = linux.close(self.epoll_fd);
        _ = linux.close(self.server_socket);
    }

    fn createServerSocket(config: ServerConfig) !linux.socket_t {
        const address = try net.Address.parseIp(config.address, config.port);
        const sockfd: linux.socket_t = @intCast(linux.socket(
            linux.AF.INET,
            linux.SOCK.STREAM | linux.SOCK.NONBLOCK,
            0,
        ));
        errdefer linux.close(sockfd);

        var optVal = mem.toBytes(@as(c_int, 1));

        _ = linux.setsockopt(
            sockfd,
            linux.SOL.SOCKET,
            linux.SO.REUSEADDR,
            &optVal,
            optVal.len,
        );

        _ = linux.bind(sockfd, &address.any, address.getOsSockLen());
        _ = linux.listen(sockfd, config.max_events);

        return sockfd;
    }

    fn setupEpoll(self: *ChatServer) !void {
        var event = linux.epoll_event{
            .events = linux.EPOLL.IN | linux.EPOLL.ET,
            .data = .{ .fd = self.server_socket },
        };

        _ = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, self.server_socket, &event);
    }

    fn run(self: *ChatServer) !void {
        var events: []linux.epoll_event = try self.allocator.alloc(linux.epoll_event, self.config.max_events);
        defer self.allocator.free(events);

        log.info("Server is listening on port {d}", .{self.config.port});

        while (true) {
            const n = linux.epoll_wait(self.epoll_fd, @as([*]linux.epoll_event, @ptrCast(events)), self.config.max_events, -1);
            for (events[0..n]) |event| {
                if (event.data.fd == self.server_socket) {
                    try self.acceptClient();
                } else if (event.events & linux.EPOLL.IN != 0) {
                    try self.handleClientData(event);
                }
            }
        }
    }

    fn acceptClient(self: *ChatServer) !void {
        const clientfd: linux.socket_t = @intCast(linux.accept(self.server_socket, null, null));

        try self.clients.add(clientfd);
        try self.sendWelcomeMessage(clientfd);

        var flags: usize = linux.fcntl(clientfd, linux.F.GETFL, 0);
        flags |= linux.SOCK.NONBLOCK;
        _ = linux.fcntl(clientfd, linux.F.SETFL, flags);

        var event = linux.epoll_event{ .events = linux.EPOLL.IN | linux.EPOLL.ET, .data = .{ .ptr = @intFromPtr(try ClientStream.create(clientfd, self.allocator)) } };

        _ = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, clientfd, &event);

        log.info("Accepting new connection with fd {}", .{clientfd});
    }

    fn handleClientData(self: *ChatServer, event: linux.epoll_event) !void {
        const stream: *ClientStream = @ptrFromInt(event.data.ptr);
        const client_fd = stream.stream.handle;

        const nread = try stream.readLine(self.allocator);

        if (nread > 0 and stream.done) {
            if (self.clients.get(client_fd) == null) {
                try self.handleNewUser(client_fd, stream);
            } else {
                try self.broadcastMessage(client_fd, stream);
            }
        } else if (nread == 0) {
            try self.removeClient(client_fd);
        }
    }

    fn handleNewUser(self: *ChatServer, client_fd: linux.fd_t, stream: *ClientStream) !void {
        const name = try self.allocator.dupe(u8, stream.buffer[0..stream.pos]);
        errdefer self.allocator.free(name);

        log.info("client name: {s}\n", .{name});

        if (!User.isValidName(name)) {
            self.sendInvalidNameMessage(client_fd);
            try self.removeClient(client_fd);
            return;
        }

        const new_user = try User.create(self.allocator, name);
        try self.clients.setUser(client_fd, new_user);

        try self.broadcastNewUserMessage(client_fd, new_user);
        try self.sendRoomOccupantsMessage(client_fd);
    }

    fn sendInvalidNameMessage(_: *ChatServer, fd: linux.fd_t) void {
        const msg = "A valid name should be alphanumeric and the max length 16 characters\n";
        _ = linux.write(fd, msg, msg.len);
    }

    fn sendWelcomeMessage(_: *ChatServer, fd: linux.fd_t) !void {
        const msg = "Welcome to budgetchat! What shall I call you?\n";
        _ = linux.write(fd, msg, msg.len);
    }

    fn sendRoomOccupantsMessage(self: *ChatServer, fd: linux.fd_t) !void {
        var names = std.ArrayList([]const u8).init(self.allocator);
        defer names.deinit();

        var it = self.clients.clients.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.* != fd and entry.value_ptr.* != null) {
                try names.append(entry.value_ptr.*.?.name);
            }
        }

        const names_str = try std.mem.join(self.allocator, ", ", names.items);
        defer self.allocator.free(names_str);

        const msg = try std.fmt.allocPrint(self.allocator, "* The room contains: {s}\n", .{names_str});
        defer self.allocator.free(msg);

        _ = linux.write(fd, msg.ptr, msg.len);
    }

    fn broadcastMessage(self: *ChatServer, sender_fd: linux.fd_t, stream: *ClientStream) !void {
        const sender = self.clients.get(sender_fd).?;
        const msg = try std.fmt.allocPrint(self.allocator, "[{s}] {s}\n", .{ sender.name, stream.buffer[0..stream.pos] });
        defer self.allocator.free(msg);

        try self.broadcastToAllExcept(sender_fd, msg);
    }

    fn broadcastNewUserMessage(self: *ChatServer, fd: linux.fd_t, user: *User) !void {
        const msg = try std.fmt.allocPrint(self.allocator, "* {s} has entered the room\n", .{user.name});
        defer self.allocator.free(msg);

        try self.broadcastToAllExcept(fd, msg);
    }

    fn broadcastToAllExcept(self: *ChatServer, except_fd: ?linux.fd_t, msg: []const u8) !void {
        var it = self.clients.clients.iterator();
        while (it.next()) |entry| {
            const fd = entry.key_ptr.*;
            if (except_fd != null and fd == except_fd.? or entry.value_ptr.* == null) continue;
            _ = linux.write(fd, msg.ptr, msg.len);
        }
    }

    fn removeClient(self: *ChatServer, fd: linux.fd_t) !void {
        if (self.clients.get(fd)) |user| {
            const msg = try std.fmt.allocPrint(self.allocator, "* {s} has left the room\n", .{user.name});
            defer self.allocator.free(msg);
            try self.broadcastToAllExcept(fd, msg);
        }

        self.clients.remove(fd);
        _ = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, fd, null);
        _ = linux.close(fd);
    }
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const config = ServerConfig{
        .address = "127.0.0.1",
        .port = 8000,
        .max_events = 100,
    };

    var server = try ChatServer.init(allocator, config);
    defer server.deinit();

    try server.run();
}

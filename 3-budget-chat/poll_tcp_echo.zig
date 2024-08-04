const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const testing = std.testing;
const c = @cImport({
    @cInclude("arpa/inet.h");
});

const MAX_CONNECTION: usize = 10;
const SERVER_FD_INDEX = 0;
const FIRST_CONNECTION = 2;
const POLLFDS = MAX_CONNECTION + FIRST_CONNECTION;

const State = enum {
    READING,
    WRITING,
    DONE,
};

const ConnCtx = struct {
    fd: i32,
    state: State,
    buf: [1024]u8,
    bytes: usize,
    buf_end: ?usize,

    fn new(allocator: std.mem.Allocator, fd: i32, event: *u32) !ConnCtx {
        const ctx = try allocator.create(ConnCtx);
        ctx.* = .{
            .fd = fd,
            .state = State.READING,
            .buf = [1024]u8{0} ** 1024,
            .bytes = 0,
            .buf_end = null,
        };

        event = posix.POLL.IN;
        return ctx;
    }
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const address = try std.net.Address.parseIp("127.0.0.1", 8000);
    const server_fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0);
    try posix.setsockopt(
        server_fd,
        posix.SOL.SOCKET,
        posix.SO.REUSEADDR,
        &std.mem.toBytes(@as(c_int, 1)),
    );

    const socklen = address.getOsSockLen();
    try posix.bind(server_fd, &address.any, socklen);
    try posix.listen(server_fd, 100);

    var pollfds: []posix.pollfd = try allocator.alloc(posix.pollfd, MAX_CONNECTION);
    defer allocator.free(pollfds);

    // var connection: *ConnCtx = undefined;
    // var connections: [MAX_CONNECTION]?*ConnCtx = [MAX_CONNECTION]?*ConnCtx{null} ** MAX_CONNECTION;
    // var total_connection: usize = 0;
    // var events: u32 = 0;

    var fd_client_len: usize = 1;

    pollfds[SERVER_FD_INDEX].fd = server_fd;
    pollfds[SERVER_FD_INDEX].events = posix.POLL.IN;

    // for (FIRST_CONNECTION..POLLFDS) |i| {
    //     pollfds[i].fd = -1;
    //     pollfds[i].events = 0;
    // }

    while (true) {
        _ = try posix.poll(pollfds, -1);

        for (0..MAX_CONNECTION) |poll_i| {
            if (pollfds[poll_i].revents & posix.POLL.IN != 0) {
                if (pollfds[poll_i].fd == server_fd) {
                    const socket_fd = try posix.accept(server_fd, null, null, 0);
                    std.debug.print("a new connection accepted\n", .{});
                    const flags = try posix.fcntl(socket_fd, std.os.linux.F.GETFD, 0);
                    _ = try posix.fcntl(socket_fd, std.os.linux.F.SETFD, flags | posix.SOCK.NONBLOCK);

                    pollfds[fd_client_len].fd = socket_fd;
                    pollfds[fd_client_len].events = posix.POLL.IN;
                    fd_client_len += 1;

                    // for (0..MAX_CONNECTION) |i| {
                    //     if (connections[i] == null) {
                    //         connection = try ConnCtx.new(allocator, socket_fd, &events);
                    //         connections[i] = connection;
                    //         pollfds[FIRST_CONNECTION + i].fd = socket_fd;
                    //         pollfds[FIRST_CONNECTION + i].events = events;
                    //         total_connection += 1;
                    //         break;
                    //     }
                    // }
                }

                // if (total_connection == MAX_CONNECTION) {
                //     pollfds[SERVER_FD_INDEX].fd = -pollfds[SERVER_FD_INDEX].fd;
                // }
            }
        }
    }
}

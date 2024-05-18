const std = @import("std");

pub fn main() !void {
    const address = try std.net.Address.parseIp("127.0.0.1", 8000);
    var listener = try std.net.Address.listen(address, .{
        .kernel_backlog = 1024,
        .reuse_address = true,
    });

    defer listener.deinit();

    while (true) {
        const conn = try listener.accept();
        const thread = try std.Thread.spawn(.{}, handler, .{conn});
        thread.join();
    }
}

fn handler(conn: std.net.Server.Connection) !void {
    std.debug.print("handled by {d}\n", .{std.Thread.getCurrentId()});

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    while (true) {
        var buffer = try allocator.alloc(u8, 100);
        const read_len = try conn.stream.read(buffer);
        if (read_len <= 0) break;

        std.debug.print("read {d} bytes\n", .{read_len});

        const write_len = try conn.stream.write(buffer[0..read_len]);
        std.debug.print("write size: {d} bytes\n", .{write_len});
    }

    conn.stream.close();
}

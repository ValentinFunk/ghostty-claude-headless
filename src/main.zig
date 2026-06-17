const std = @import("std");
const builtin = @import("builtin");
const ghostty_vt = @import("ghostty-vt");

const c = @cImport({
    @cInclude("errno.h");
    @cInclude("fcntl.h");
    @cInclude("poll.h");
    @cInclude("signal.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/wait.h");
    @cInclude("termios.h");
    @cInclude("unistd.h");
    if (builtin.os.tag == .macos) {
        @cInclude("util.h");
    } else {
        @cInclude("pty.h");
    }
});

const default_cols: u16 = 120;
const default_rows: u16 = 40;
const default_cell_width_px: u32 = 9;
const default_cell_height_px: u32 = 18;
const ghostty_version = "1.3.2-dev";
const ghostty_xtversion = "ghostty " ++ ghostty_version;
const debug_render_interval_ms: i64 = 250;
const no_progress_timeout_ms: i64 = 30 * 1000;
const final_transcript_after_spinner_timeout_ms: i64 = 10 * 1000;
const latest_debug_screen_path = "/tmp/ghostty-claude-headless-latest.screen.txt";
const latest_debug_meta_path = "/tmp/ghostty-claude-headless-latest.meta.txt";

var active_pty_fd: c_int = -1;
var active_cols: u16 = default_cols;
var active_rows: u16 = default_rows;

const Config = struct {
    cwd: [:0]const u8,
    claude: [:0]const u8,
    max_timeout_ms: i64 = 30 * 60 * 1000,
    idle_timeout_ms: i64 = 8 * 60 * 1000,
    startup_timeout_ms: i64 = 30 * 1000,
    transcript_timeout_ms: i64 = 15 * 1000,
    cols: u16 = default_cols,
    rows: u16 = default_rows,
    ensure_auto_mode: bool = true,
    prompt: []const u8,
};

const ClaudeResponse = struct {
    text: []const u8,
};

const TerminalDebug = struct {
    alloc: std.mem.Allocator,
    session_id: []const u8,
    screen_path: []u8,
    meta_path: []u8,
    last_render_ms: i64 = 0,

    fn init(alloc: std.mem.Allocator, session_id: []const u8) !TerminalDebug {
        const screen_path = try std.fmt.allocPrint(alloc, "/tmp/ghostty-claude-headless-{s}.screen.txt", .{session_id});
        errdefer alloc.free(screen_path);
        const meta_path = try std.fmt.allocPrint(alloc, "/tmp/ghostty-claude-headless-{s}.meta.txt", .{session_id});
        errdefer alloc.free(meta_path);
        return .{
            .alloc = alloc,
            .session_id = session_id,
            .screen_path = screen_path,
            .meta_path = meta_path,
        };
    }

    fn deinit(self: *TerminalDebug) void {
        self.alloc.free(self.screen_path);
        self.alloc.free(self.meta_path);
    }

    fn writeMeta(self: *TerminalDebug, cfg: Config, child_pid: c.pid_t) void {
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        out.writer.print(
            \\session_id={s}
            \\runner_pid={}
            \\claude_pid={}
            \\cwd={s}
            \\claude={s}
            \\screen_path={s}
            \\meta_path={s}
            \\latest_screen_path={s}
            \\latest_meta_path={s}
            \\
        , .{
            self.session_id,
            c.getpid(),
            child_pid,
            cfg.cwd,
            cfg.claude,
            self.screen_path,
            self.meta_path,
            latest_debug_screen_path,
            latest_debug_meta_path,
        }) catch return;
        writeDebugFile(self.meta_path, out.written());
        writeDebugFile(latest_debug_meta_path, out.written());
    }

    fn render(self: *TerminalDebug, terminal: *ghostty_vt.Terminal, raw: []const u8, force: bool) void {
        const now = nowMs();
        if (!force and now - self.last_render_ms < debug_render_interval_ms) return;
        self.last_render_ms = now;

        const screen = terminal.plainString(self.alloc) catch return;
        defer self.alloc.free(screen);

        const raw_tail_start = if (raw.len > 8000) raw.len - 8000 else 0;
        const raw_tail = raw[raw_tail_start..];

        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        out.writer.print(
            \\ghostty-claude-headless terminal snapshot
            \\session_id={s}
            \\updated_ms={}
            \\raw_bytes={}
            \\
            \\--- screen ---
            \\{s}
            \\
            \\--- raw_tail ---
            \\{s}
            \\
        , .{ self.session_id, now, raw.len, screen, raw_tail }) catch return;

        writeDebugFile(self.screen_path, out.written());
        writeDebugFile(latest_debug_screen_path, out.written());
    }
};

fn writeDebugFile(path: []const u8, contents: []const u8) void {
    var file = std.fs.createFileAbsolute(path, .{ .truncate = true }) catch return;
    defer file.close();
    file.writeAll(contents) catch return;
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const cfg = try parseArgs(alloc);
    defer alloc.free(cfg.cwd);
    defer alloc.free(cfg.claude);
    defer alloc.free(cfg.prompt);

    const response = try runClaudePrompt(alloc, cfg);
    defer alloc.free(response.text);

    const stdout_file = std.fs.File.stdout();
    var out_buf: [4096]u8 = undefined;
    var stdout_writer = stdout_file.writer(&out_buf);
    const stdout = &stdout_writer.interface;
    try stdout.writeAll(response.text);
    if (!std.mem.endsWith(u8, response.text, "\n")) try stdout.writeByte('\n');
    try stdout.flush();
}

fn parseArgs(alloc: std.mem.Allocator) !Config {
    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    _ = args.next();

    const cwd_raw = try std.process.getCwdAlloc(alloc);
    defer alloc.free(cwd_raw);
    var cwd = try alloc.dupeZ(u8, cwd_raw);
    errdefer alloc.free(cwd);
    var claude = try alloc.dupeZ(u8, "claude");
    errdefer alloc.free(claude);
    var max_timeout_ms: i64 = 30 * 60 * 1000;
    var idle_timeout_ms: i64 = 8 * 60 * 1000;
    var startup_timeout_ms: i64 = 30 * 1000;
    var transcript_timeout_ms: i64 = 15 * 1000;
    var cols: u16 = default_cols;
    var rows: u16 = default_rows;
    var ensure_auto_mode = true;

    var positional: std.Io.Writer.Allocating = .init(alloc);
    defer positional.deinit();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--cwd")) {
            alloc.free(cwd);
            cwd = try alloc.dupeZ(u8, args.next() orelse return error.MissingValue);
        } else if (std.mem.eql(u8, arg, "--claude")) {
            alloc.free(claude);
            claude = try alloc.dupeZ(u8, args.next() orelse return error.MissingValue);
        } else if (std.mem.eql(u8, arg, "--max-timeout-ms")) {
            max_timeout_ms = try parseI64(args.next() orelse return error.MissingValue);
        } else if (std.mem.eql(u8, arg, "--idle-timeout-ms")) {
            idle_timeout_ms = try parseI64(args.next() orelse return error.MissingValue);
        } else if (std.mem.eql(u8, arg, "--startup-timeout-ms")) {
            startup_timeout_ms = try parseI64(args.next() orelse return error.MissingValue);
        } else if (std.mem.eql(u8, arg, "--transcript-timeout-ms")) {
            transcript_timeout_ms = try parseI64(args.next() orelse return error.MissingValue);
        } else if (std.mem.eql(u8, arg, "--cols")) {
            cols = try parseU16(args.next() orelse return error.MissingValue);
        } else if (std.mem.eql(u8, arg, "--rows")) {
            rows = try parseU16(args.next() orelse return error.MissingValue);
        } else if (std.mem.eql(u8, arg, "--no-auto-mode")) {
            ensure_auto_mode = false;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printHelp();
            std.process.exit(0);
        } else {
            if (positional.written().len > 0) try positional.writer.writeByte(' ');
            try positional.writer.writeAll(arg);
        }
    }

    const prompt = prompt: {
        if (positional.written().len > 0) break :prompt try positional.toOwnedSlice();
        if (c.isatty(c.STDIN_FILENO) == 0) {
            const stdin = std.fs.File.stdin();
            break :prompt try stdin.readToEndAlloc(alloc, 16 * 1024 * 1024);
        }
        return error.MissingPrompt;
    };

    const trimmed_prompt = try trimOwned(alloc, prompt);
    if (trimmed_prompt.len == 0) return error.MissingPrompt;

    return .{
        .cwd = cwd,
        .claude = claude,
        .max_timeout_ms = max_timeout_ms,
        .idle_timeout_ms = idle_timeout_ms,
        .startup_timeout_ms = startup_timeout_ms,
        .transcript_timeout_ms = transcript_timeout_ms,
        .cols = cols,
        .rows = rows,
        .ensure_auto_mode = ensure_auto_mode,
        .prompt = trimmed_prompt,
    };
}

fn printHelp() !void {
    const stderr_file = std.fs.File.stderr();
    var buf: [2048]u8 = undefined;
    var writer = stderr_file.writer(&buf);
    const stderr = &writer.interface;
    try stderr.writeAll(
        \\Usage: ghostty-claude-headless [options] [prompt]
        \\
        \\Reads prompt from stdin when no positional prompt is supplied.
        \\
        \\Options:
        \\  --cwd <dir>                    Claude working directory
        \\  --claude <path>                Claude executable (default: claude)
        \\  --max-timeout-ms <ms>          Overall assistant response timeout
        \\  --idle-timeout-ms <ms>         Transcript idle timeout
        \\  --startup-timeout-ms <ms>      TUI startup timeout
        \\  --transcript-timeout-ms <ms>   Transcript creation timeout
        \\  --cols <n>                     PTY columns (default: 120)
        \\  --rows <n>                     PTY rows (default: 40)
        \\  --no-auto-mode                 Do not cycle Claude into auto mode
        \\
    );
    try stderr.flush();
}

fn runClaudePrompt(alloc: std.mem.Allocator, cfg: Config) !ClaudeResponse {
    active_cols = cfg.cols;
    active_rows = cfg.rows;

    const session_id = try createUuid(alloc);
    defer alloc.free(session_id);

    var terminal_debug = try TerminalDebug.init(alloc, session_id);
    defer terminal_debug.deinit();

    var terminal: ghostty_vt.Terminal = try .init(alloc, .{ .cols = cfg.cols, .rows = cfg.rows, .max_scrollback = 2000 });
    defer terminal.deinit(alloc);

    var handler = terminal.vtHandler();
    handler.effects = .{
        .write_pty = writePty,
        .bell = null,
        .color_scheme = colorScheme,
        .device_attributes = null,
        .enquiry = enquiry,
        .size = sizeReport,
        .title_changed = null,
        .xtversion = xtversion,
    };
    var stream = ghostty_vt.TerminalStream.initAlloc(alloc, handler);
    defer stream.deinit();

    var master_fd: c_int = -1;
    const child_pid = try forkClaude(alloc, &master_fd, cfg, session_id);
    const child_running = true;
    terminal_debug.writeMeta(cfg, child_pid);
    active_pty_fd = master_fd;
    defer {
        active_pty_fd = -1;
        if (child_running) _ = c.kill(child_pid, c.SIGTERM);
        _ = c.close(master_fd);
        if (child_running) {
            var status: c_int = 0;
            _ = c.waitpid(child_pid, &status, 0);
        }
    }

    var raw = std.Io.Writer.Allocating.init(alloc);
    defer raw.deinit();
    defer terminal_debug.render(&terminal, raw.written(), true);
    var responder = ProbeResponder.init(alloc, master_fd, &terminal);
    defer responder.deinit();
    terminal_debug.render(&terminal, raw.written(), true);

    const startup_deadline = nowMs() + cfg.startup_timeout_ms;
    try readUntilReady(alloc, master_fd, &stream, &terminal, &raw, &responder, &terminal_debug, startup_deadline);
    try waitForOutputIdle(alloc, master_fd, &stream, &terminal, &raw, &responder, &terminal_debug, 1000, cfg.startup_timeout_ms);
    _ = try confirmTrustPromptIfPresent(
        alloc,
        master_fd,
        &stream,
        &terminal,
        &raw,
        &responder,
        &terminal_debug,
        cfg.startup_timeout_ms,
    );

    if (cfg.ensure_auto_mode) {
        try ensureAutoMode(alloc, master_fd, &stream, &terminal, &raw, &responder, &terminal_debug);
    }

    try sendBracketedPaste(master_fd, cfg.prompt);
    try ensurePromptSubmitted(alloc, master_fd, &stream, &terminal, &raw, &responder, &terminal_debug);
    const response_deadline = nowMs() + cfg.max_timeout_ms;

    const transcript_path = waitForTranscriptPath(
        alloc,
        cfg.cwd,
        session_id,
        cfg.transcript_timeout_ms,
        master_fd,
        &stream,
        &terminal,
        &raw,
        &responder,
        &terminal_debug,
    ) catch |err| recover: {
        if (err != error.TranscriptTimeout) {
            terminal_debug.render(&terminal, raw.written(), true);
            debugDump(raw.written());
            return err;
        }
        break :recover recoverTranscriptAfterVisibleResponse(
            alloc,
            session_id,
            master_fd,
            &stream,
            &terminal,
            &raw,
            &responder,
            &terminal_debug,
            response_deadline,
        ) catch |recover_err| {
            terminal_debug.render(&terminal, raw.written(), true);
            debugDump(raw.written());
            return recover_err;
        };
    };
    defer alloc.free(transcript_path);

    const text = waitForAssistantText(
        alloc,
        transcript_path,
        cfg.max_timeout_ms,
        cfg.idle_timeout_ms,
        master_fd,
        &stream,
        &terminal,
        &raw,
        &responder,
        &terminal_debug,
    ) catch |err| {
        terminal_debug.render(&terminal, raw.written(), true);
        debugDump(raw.written());
        return err;
    };
    return .{ .text = text };
}

fn debugDump(raw: []const u8) void {
    if (std.posix.getenv("GHOSTTY_CLAUDE_DEBUG") == null) return;
    std.debug.print("\n--- ghostty-claude-headless raw tail ---\n{s}\n--- end raw tail ---\n", .{raw[if (raw.len > 8000) raw.len - 8000 else 0..]});
}

fn forkClaude(alloc: std.mem.Allocator, master_fd: *c_int, cfg: Config, session_id: []const u8) !c.pid_t {
    var ws: c.struct_winsize = .{
        .ws_row = cfg.rows,
        .ws_col = cfg.cols,
        .ws_xpixel = @intCast(@as(u32, cfg.cols) * default_cell_width_px),
        .ws_ypixel = @intCast(@as(u32, cfg.rows) * default_cell_height_px),
    };

    var owned_args: [24]?[:0]u8 = .{null} ** 24;
    var owned_args_len: usize = 0;
    defer {
        for (owned_args[0..owned_args_len]) |maybe_arg| {
            if (maybe_arg) |arg| alloc.free(arg);
        }
    }

    var argv: [64:null][*c]u8 = undefined;
    var argc: usize = 0;
    appendLiteralArg(&argv, &argc, "/usr/bin/env");
    appendLiteralArg(&argv, &argc, "-i");
    try appendEnvArgFromCurrent(alloc, &argv, &argc, &owned_args, &owned_args_len, "HOME");
    try appendEnvArgFromCurrent(alloc, &argv, &argc, &owned_args, &owned_args_len, "USER");
    try appendEnvArgFromCurrent(alloc, &argv, &argc, &owned_args, &owned_args_len, "LOGNAME");
    try appendEnvArgFromCurrent(alloc, &argv, &argc, &owned_args, &owned_args_len, "SHELL");
    try appendEnvArgFromCurrent(alloc, &argv, &argc, &owned_args, &owned_args_len, "TMPDIR");
    try appendEnvArgFromCurrent(alloc, &argv, &argc, &owned_args, &owned_args_len, "LANG");
    try appendEnvArgFromCurrent(alloc, &argv, &argc, &owned_args, &owned_args_len, "LC_ALL");
    try appendEnvArgFromCurrent(alloc, &argv, &argc, &owned_args, &owned_args_len, "LC_CTYPE");
    try appendEnvArgFromCurrent(alloc, &argv, &argc, &owned_args, &owned_args_len, "LC_MESSAGES");
    try appendEnvArgFromCurrent(alloc, &argv, &argc, &owned_args, &owned_args_len, "SSH_AUTH_SOCK");
    try appendEnvArg(alloc, &argv, &argc, &owned_args, &owned_args_len, "PWD", cfg.cwd);

    const path_value = try standaloneTerminalPath(alloc);
    defer alloc.free(path_value);
    try appendEnvArg(alloc, &argv, &argc, &owned_args, &owned_args_len, "PATH", path_value);
    appendLiteralArg(&argv, &argc, "TERM=xterm-ghostty");
    appendLiteralArg(&argv, &argc, "COLORTERM=truecolor");
    appendLiteralArg(&argv, &argc, "TERM_PROGRAM=ghostty");
    appendLiteralArg(&argv, &argc, "TERM_PROGRAM_VERSION=" ++ ghostty_version);
    appendLiteralArg(&argv, &argc, "GHOSTTY_SHELL_FEATURES=cursor:blink,path,ssh-env,ssh-terminfo,sudo,title");
    argv[argc] = @constCast(@ptrCast(cfg.claude.ptr));
    argc += 1;
    appendLiteralArg(&argv, &argc, "--session-id");
    argv[argc] = @constCast(@ptrCast(session_id.ptr));
    argc += 1;
    argv[argc] = null;

    const pid = c.forkpty(master_fd, null, null, &ws);
    if (pid < 0) return error.ForkPtyFailed;
    if (pid == 0) {
        _ = c.chdir(cfg.cwd.ptr);
        _ = c.execv("/usr/bin/env", &argv);
        c._exit(127);
    }

    return pid;
}

fn appendLiteralArg(argv: *[64:null][*c]u8, argc: *usize, value: [:0]const u8) void {
    argv[argc.*] = @constCast(@ptrCast(value.ptr));
    argc.* += 1;
}

fn appendEnvArgFromCurrent(
    alloc: std.mem.Allocator,
    argv: *[64:null][*c]u8,
    argc: *usize,
    owned_args: *[24]?[:0]u8,
    owned_args_len: *usize,
    name: []const u8,
) !void {
    if (std.posix.getenv(name)) |value| {
        try appendEnvArg(alloc, argv, argc, owned_args, owned_args_len, name, value);
    }
}

fn appendEnvArg(
    alloc: std.mem.Allocator,
    argv: *[64:null][*c]u8,
    argc: *usize,
    owned_args: *[24]?[:0]u8,
    owned_args_len: *usize,
    name: []const u8,
    value: []const u8,
) !void {
    const formatted = try std.fmt.allocPrint(alloc, "{s}={s}", .{ name, value });
    defer alloc.free(formatted);
    const arg = try alloc.dupeZ(u8, formatted);
    owned_args[owned_args_len.*] = arg;
    owned_args_len.* += 1;
    argv[argc.*] = @ptrCast(arg.ptr);
    argc.* += 1;
}

fn standaloneTerminalPath(alloc: std.mem.Allocator) ![:0]u8 {
    if (std.posix.getenv("HOME")) |home| {
        const formatted = try std.fmt.allocPrint(alloc, "{s}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", .{home});
        defer alloc.free(formatted);
        return alloc.dupeZ(u8, formatted);
    }
    return alloc.dupeZ(u8, "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin");
}

fn readUntilReady(
    alloc: std.mem.Allocator,
    fd: c_int,
    stream: *ghostty_vt.TerminalStream,
    terminal: *ghostty_vt.Terminal,
    raw: *std.Io.Writer.Allocating,
    responder: *ProbeResponder,
    terminal_debug: *TerminalDebug,
    deadline: i64,
) !void {
    while (nowMs() <= deadline) {
        try pumpPty(alloc, fd, stream, terminal, raw, responder, terminal_debug, 100);
        const screen = try terminal.plainString(alloc);
        defer alloc.free(screen);
        if (std.mem.indexOf(u8, screen, "Claude Code") != null or
            std.mem.indexOf(u8, screen, "❯") != null or
            std.mem.indexOf(u8, raw.written(), "Claude Code") != null)
        {
            return;
        }
    }
    return error.StartupTimeout;
}

fn waitForOutputIdle(
    alloc: std.mem.Allocator,
    fd: c_int,
    stream: *ghostty_vt.TerminalStream,
    terminal: *ghostty_vt.Terminal,
    raw: *std.Io.Writer.Allocating,
    responder: *ProbeResponder,
    terminal_debug: *TerminalDebug,
    idle_ms: i64,
    timeout_ms: i64,
) !void {
    const deadline = nowMs() + timeout_ms;
    var last_len = raw.written().len;
    var last_change = nowMs();
    while (nowMs() <= deadline) {
        try pumpPty(alloc, fd, stream, terminal, raw, responder, terminal_debug, 100);
        if (raw.written().len != last_len) {
            last_len = raw.written().len;
            last_change = nowMs();
        }
        if (nowMs() - last_change >= idle_ms) return;
    }
    return error.OutputIdleTimeout;
}

fn ensureAutoMode(
    alloc: std.mem.Allocator,
    fd: c_int,
    stream: *ghostty_vt.TerminalStream,
    terminal: *ghostty_vt.Terminal,
    raw: *std.Io.Writer.Allocating,
    responder: *ProbeResponder,
    terminal_debug: *TerminalDebug,
) !void {
    if (try hasText(alloc, terminal, raw, "auto mode on")) return;

    var attempt: u8 = 0;
    while (attempt < 3) : (attempt += 1) {
        try writeAllFd(fd, "\x1b[Z");
        const deadline = nowMs() + 1000;
        while (nowMs() <= deadline) {
            try pumpPty(alloc, fd, stream, terminal, raw, responder, terminal_debug, 100);
            if (try hasText(alloc, terminal, raw, "auto mode on")) {
                try waitForOutputIdle(alloc, fd, stream, terminal, raw, responder, terminal_debug, 250, 5000);
                return;
            }
        }
    }
}

fn hasText(alloc: std.mem.Allocator, terminal: *ghostty_vt.Terminal, raw: *std.Io.Writer.Allocating, needle: []const u8) !bool {
    const screen = try terminal.plainString(alloc);
    defer alloc.free(screen);
    return std.ascii.indexOfIgnoreCase(screen, needle) != null or std.ascii.indexOfIgnoreCase(raw.written(), needle) != null;
}

fn confirmTrustPromptIfPresent(
    alloc: std.mem.Allocator,
    fd: c_int,
    stream: *ghostty_vt.TerminalStream,
    terminal: *ghostty_vt.Terminal,
    raw: *std.Io.Writer.Allocating,
    responder: *ProbeResponder,
    terminal_debug: *TerminalDebug,
    timeout_ms: i64,
) !bool {
    const screen = try terminal.plainString(alloc);
    defer alloc.free(screen);
    const screen_has_prompt = try containsTrustDirectoryPrompt(alloc, screen);
    const raw_has_prompt = try containsTrustDirectoryPrompt(alloc, raw.written());
    if (!screen_has_prompt and !raw_has_prompt) return false;

    try writeAllFd(fd, "\r");
    try waitForOutputIdle(alloc, fd, stream, terminal, raw, responder, terminal_debug, 1000, timeout_ms);
    return true;
}

fn containsTrustDirectoryPrompt(alloc: std.mem.Allocator, haystack: []const u8) !bool {
    return (try containsNormalizedAscii(alloc, haystack, "quicksafetycheck")) and
        (try containsNormalizedAscii(alloc, haystack, "yesitrustthisfolder"));
}

fn containsNormalizedAscii(alloc: std.mem.Allocator, haystack: []const u8, normalized_needle: []const u8) !bool {
    var normalized: std.Io.Writer.Allocating = .init(alloc);
    defer normalized.deinit();
    for (haystack) |ch| {
        if (!std.ascii.isAlphanumeric(ch)) continue;
        try normalized.writer.writeByte(std.ascii.toLower(ch));
    }
    return std.mem.indexOf(u8, normalized.written(), normalized_needle) != null;
}

fn pumpPty(
    alloc: std.mem.Allocator,
    fd: c_int,
    stream: *ghostty_vt.TerminalStream,
    terminal: *ghostty_vt.Terminal,
    raw: *std.Io.Writer.Allocating,
    responder: *ProbeResponder,
    terminal_debug: *TerminalDebug,
    timeout_ms: i32,
) !void {
    _ = alloc;
    var pfd = c.struct_pollfd{ .fd = fd, .events = c.POLLIN, .revents = 0 };
    const poll_result = c.poll(&pfd, 1, timeout_ms);
    if (poll_result < 0) return error.PollFailed;
    if (poll_result == 0) return;
    if ((pfd.revents & c.POLLIN) == 0) return;

    var buf: [8192]u8 = undefined;
    const n = c.read(fd, &buf, buf.len);
    if (n < 0) return error.ReadFailed;
    if (n == 0) return error.PtyClosed;
    const data = buf[0..@intCast(n)];
    try raw.writer.writeAll(data);
    try responder.observe(data);
    stream.nextSlice(data);
    terminal_debug.render(terminal, raw.written(), false);
}

fn sendBracketedPaste(fd: c_int, prompt: []const u8) !void {
    try writeAllFd(fd, "\x1b[200~");
    try writeAllFd(fd, prompt);
    try writeAllFd(fd, "\x1b[201~");
}

fn ensurePromptSubmitted(
    alloc: std.mem.Allocator,
    fd: c_int,
    stream: *ghostty_vt.TerminalStream,
    terminal: *ghostty_vt.Terminal,
    raw: *std.Io.Writer.Allocating,
    responder: *ProbeResponder,
    terminal_debug: *TerminalDebug,
) !void {
    var saw_pasted_prompt = false;
    var observe_deadline = nowMs() + 1000;
    while (nowMs() <= observe_deadline) {
        try pumpPty(alloc, fd, stream, terminal, raw, responder, terminal_debug, 50);
        if (terminalHasActiveClaudeSpinner(alloc, terminal)) return;
        if (terminalHasPastedPrompt(alloc, terminal)) {
            saw_pasted_prompt = true;
            break;
        }
    }

    var attempts: u8 = 0;
    while (attempts < 3) : (attempts += 1) {
        try writeAllFd(fd, "\r");
        observe_deadline = nowMs() + 1000;
        while (nowMs() <= observe_deadline) {
            try pumpPty(alloc, fd, stream, terminal, raw, responder, terminal_debug, 50);
            if (terminalHasActiveClaudeSpinner(alloc, terminal)) return;
            const has_pasted_prompt = terminalHasPastedPrompt(alloc, terminal);
            if (saw_pasted_prompt and !has_pasted_prompt) return;
            if (!saw_pasted_prompt and has_pasted_prompt) saw_pasted_prompt = true;
        }
        if (!saw_pasted_prompt) return;
    }
    return error.PromptSubmitTimeout;
}

fn terminalHasPastedPrompt(alloc: std.mem.Allocator, terminal: *ghostty_vt.Terminal) bool {
    const screen = terminal.plainString(alloc) catch return false;
    defer alloc.free(screen);
    return std.mem.indexOf(u8, screen, "[Pasted text #") != null;
}

fn writePty(_: *ghostty_vt.TerminalStream.Handler, data: [:0]const u8) void {
    if (active_pty_fd < 0) return;
    writeAllFd(active_pty_fd, data) catch {};
}

fn xtversion(_: *ghostty_vt.TerminalStream.Handler) []const u8 {
    return ghostty_xtversion;
}

fn enquiry(_: *ghostty_vt.TerminalStream.Handler) []const u8 {
    return "";
}

fn colorScheme(_: *ghostty_vt.TerminalStream.Handler) ?ghostty_vt.device_status.ColorScheme {
    return .dark;
}

fn sizeReport(_: *ghostty_vt.TerminalStream.Handler) ?ghostty_vt.size_report.Size {
    return .{
        .rows = active_rows,
        .columns = active_cols,
        .cell_width = default_cell_width_px,
        .cell_height = default_cell_height_px,
    };
}

const ProbeResponder = struct {
    alloc: std.mem.Allocator,
    fd: c_int,
    terminal: *ghostty_vt.Terminal,
    pending: std.Io.Writer.Allocating,

    fn init(alloc: std.mem.Allocator, fd: c_int, terminal: *ghostty_vt.Terminal) ProbeResponder {
        return .{ .alloc = alloc, .fd = fd, .terminal = terminal, .pending = .init(alloc) };
    }

    fn deinit(self: *ProbeResponder) void {
        self.pending.deinit();
    }

    fn observe(self: *ProbeResponder, data: []const u8) !void {
        try self.pending.writer.writeAll(data);
        const bytes = self.pending.written();

        if (std.mem.indexOf(u8, bytes, "\x1b[c") != null or std.mem.indexOf(u8, bytes, "\x1b[0c") != null) {
            try writeAllFd(self.fd, "\x1b[?62;22;52c");
        }
        if (std.mem.indexOf(u8, bytes, "\x1b[>c") != null or std.mem.indexOf(u8, bytes, "\x1b[>0c") != null) {
            try writeAllFd(self.fd, "\x1b[>1;10;0c");
        }
        try self.respondXtgettcap(bytes);
        try self.respondDecrqss(bytes);
        try self.respondOscColor(bytes);

        if (bytes.len > 4096) {
            const keep = bytes[bytes.len - 1024 ..];
            self.pending.clearRetainingCapacity();
            try self.pending.writer.writeAll(keep);
        }
    }

    fn respondXtgettcap(self: *ProbeResponder, bytes: []const u8) !void {
        var search_index: usize = 0;
        while (std.mem.indexOfPos(u8, bytes, search_index, "\x1bP+q")) |start| {
            const payload_start = start + 4;
            const rel_end = std.mem.indexOfPos(u8, bytes, payload_start, "\x1b\\") orelse return;
            const payload = bytes[payload_start..rel_end];
            var it = std.mem.splitScalar(u8, payload, ';');
            while (it.next()) |key_raw| {
                var key_buf: [128]u8 = undefined;
                if (key_raw.len > key_buf.len) continue;
                const key = std.ascii.upperString(key_buf[0..key_raw.len], key_raw);
                if (xtgettcapResponse(key)) |response| try writeAllFd(self.fd, response);
            }
            search_index = rel_end + 2;
        }
    }

    fn respondDecrqss(self: *ProbeResponder, bytes: []const u8) !void {
        var search_index: usize = 0;
        while (std.mem.indexOfPos(u8, bytes, search_index, "\x1bP$q")) |start| {
            const payload_start = start + 4;
            const rel_end = std.mem.indexOfPos(u8, bytes, payload_start, "\x1b\\") orelse return;
            const payload = bytes[payload_start..rel_end];
            if (std.mem.eql(u8, payload, "m")) {
                var buf: [256]u8 = undefined;
                const attrs = self.terminal.printAttributes(&buf) catch "0";
                try writeAllFd(self.fd, "\x1bP1$r");
                try writeAllFd(self.fd, attrs);
                try writeAllFd(self.fd, "m\x1b\\");
            } else if (std.mem.eql(u8, payload, " q")) {
                try writeAllFd(self.fd, "\x1bP1$r1 q\x1b\\");
            } else if (std.mem.eql(u8, payload, "r")) {
                var out: [64]u8 = undefined;
                const msg = try std.fmt.bufPrint(&out, "\x1bP1$r1;{}r\x1b\\", .{active_rows});
                try writeAllFd(self.fd, msg);
            } else {
                try writeAllFd(self.fd, "\x1bP0$r\x1b\\");
            }
            search_index = rel_end + 2;
        }
    }

    fn respondOscColor(self: *ProbeResponder, bytes: []const u8) !void {
        _ = self;
        if (std.mem.indexOf(u8, bytes, "\x1b]10;?") != null) try writeAllFd(active_pty_fd, "\x1b]10;rgb:ffff/ffff/ffff\x07");
        if (std.mem.indexOf(u8, bytes, "\x1b]11;?") != null) try writeAllFd(active_pty_fd, "\x1b]11;rgb:0000/0000/0000\x07");
        if (std.mem.indexOf(u8, bytes, "\x1b]12;?") != null) try writeAllFd(active_pty_fd, "\x1b]12;rgb:ffff/ffff/ffff\x07");
    }
};

fn waitForTranscriptPath(
    alloc: std.mem.Allocator,
    cwd: []const u8,
    session_id: []const u8,
    timeout_ms: i64,
    fd: c_int,
    stream: *ghostty_vt.TerminalStream,
    terminal: *ghostty_vt.Terminal,
    raw: *std.Io.Writer.Allocating,
    responder: *ProbeResponder,
    terminal_debug: *TerminalDebug,
) ![]u8 {
    const deadline = nowMs() + timeout_ms;
    var last_raw_len = raw.written().len;
    var last_progress = nowMs();
    while (nowMs() <= deadline) {
        try pumpPty(alloc, fd, stream, terminal, raw, responder, terminal_debug, 50);
        const expected = try expectedTranscriptPath(alloc, cwd, session_id);
        if (fileExists(expected)) return expected;
        alloc.free(expected);
        if (try findTranscriptPathBySessionId(alloc, session_id)) |found| return found;
        noteTerminalProgress(alloc, terminal, raw, &last_raw_len, &last_progress);
    }
    return error.TranscriptTimeout;
}

fn recoverTranscriptAfterVisibleResponse(
    alloc: std.mem.Allocator,
    session_id: []const u8,
    fd: c_int,
    stream: *ghostty_vt.TerminalStream,
    terminal: *ghostty_vt.Terminal,
    raw: *std.Io.Writer.Allocating,
    responder: *ProbeResponder,
    terminal_debug: *TerminalDebug,
    response_deadline: i64,
) ![]u8 {
    var last_raw_len = raw.written().len;
    var last_progress = nowMs();
    while (nowMs() <= response_deadline) {
        pumpPty(alloc, fd, stream, terminal, raw, responder, terminal_debug, 50) catch |err| switch (err) {
            error.PtyClosed => break,
            else => return err,
        };
        if (try findTranscriptPathBySessionId(alloc, session_id)) |found| return found;
        noteTerminalProgress(alloc, terminal, raw, &last_raw_len, &last_progress);
        if (nowMs() - last_progress > no_progress_timeout_ms) return error.TranscriptNoProgress;
    }
    return error.TranscriptTimeout;
}

fn noteTerminalProgress(
    alloc: std.mem.Allocator,
    terminal: *ghostty_vt.Terminal,
    raw: *std.Io.Writer.Allocating,
    last_raw_len: *usize,
    last_progress: *i64,
) void {
    if (raw.written().len != last_raw_len.*) {
        last_raw_len.* = raw.written().len;
        last_progress.* = nowMs();
        return;
    }
    if (terminalHasActiveClaudeSpinner(alloc, terminal)) {
        last_progress.* = nowMs();
    }
}

fn terminalHasActiveClaudeSpinner(alloc: std.mem.Allocator, terminal: *ghostty_vt.Terminal) bool {
    const screen = terminal.plainString(alloc) catch return false;
    defer alloc.free(screen);
    return screenHasActiveClaudeSpinner(screen);
}

fn screenHasActiveClaudeSpinner(screen: []const u8) bool {
    var lines = std.mem.splitScalar(u8, screen, '\n');
    while (lines.next()) |line| {
        if (isActiveSpinnerLine(line)) return true;
    }
    return false;
}

fn isActiveSpinnerLine(line: []const u8) bool {
    const trimmed = trimTerminalStatusWhitespace(line);
    return startsWithSpinnerStatus(trimmed, "✢") or
        startsWithSpinnerStatus(trimmed, "✳") or
        startsWithSpinnerStatus(trimmed, "✶") or
        startsWithSpinnerStatus(trimmed, "✻") or
        startsWithSpinnerStatus(trimmed, "✽") or
        startsWithSpinnerStatus(trimmed, "*") or
        startsWithSpinnerStatus(trimmed, "·");
}

fn startsWithSpinnerStatus(line: []const u8, glyph: []const u8) bool {
    if (!std.mem.startsWith(u8, line, glyph)) return false;
    const rest = line[glyph.len..];
    if (!startsWithTerminalStatusWhitespace(rest)) return false;
    return std.mem.indexOf(u8, rest, "…") != null;
}

fn startsWithTerminalStatusWhitespace(value: []const u8) bool {
    return value.len > 0 and (std.ascii.isWhitespace(value[0]) or std.mem.startsWith(u8, value, "\xc2\xa0"));
}

fn trimTerminalStatusWhitespace(value: []const u8) []const u8 {
    var start: usize = 0;
    while (start < value.len) {
        if (std.ascii.isWhitespace(value[start])) {
            start += 1;
        } else if (std.mem.startsWith(u8, value[start..], "\xc2\xa0")) {
            start += 2;
        } else {
            break;
        }
    }

    var end = value.len;
    while (end > start) {
        if (std.ascii.isWhitespace(value[end - 1])) {
            end -= 1;
        } else if (end >= start + 2 and std.mem.eql(u8, value[end - 2 .. end], "\xc2\xa0")) {
            end -= 2;
        } else {
            break;
        }
    }
    return value[start..end];
}

fn terminateChild(child_pid: c.pid_t, child_running: *bool) void {
    if (!child_running.*) return;
    _ = c.kill(child_pid, c.SIGTERM);
    var status: c_int = 0;
    _ = c.waitpid(child_pid, &status, 0);
    child_running.* = false;
}

fn expectedTranscriptPath(alloc: std.mem.Allocator, cwd: []const u8, session_id: []const u8) ![]u8 {
    const home = std.posix.getenv("HOME") orelse return error.HomeNotSet;
    const abs_cwd = try std.fs.path.resolve(alloc, &.{cwd});
    defer alloc.free(abs_cwd);
    const project = try alloc.dupe(u8, abs_cwd);
    defer alloc.free(project);
    for (project) |*ch| {
        if (!std.ascii.isAlphanumeric(ch.*)) ch.* = '-';
    }
    const file_name = try std.fmt.allocPrint(alloc, "{s}.jsonl", .{session_id});
    defer alloc.free(file_name);
    return std.fs.path.join(alloc, &.{ home, ".claude", "projects", project, file_name });
}

fn findTranscriptPathBySessionId(alloc: std.mem.Allocator, session_id: []const u8) !?[]u8 {
    const home = std.posix.getenv("HOME") orelse return error.HomeNotSet;
    const projects_dir = try std.fs.path.join(alloc, &.{ home, ".claude", "projects" });
    defer alloc.free(projects_dir);
    const file_name = try std.fmt.allocPrint(alloc, "{s}.jsonl", .{session_id});
    defer alloc.free(file_name);

    var dir = std.fs.openDirAbsolute(projects_dir, .{ .iterate = true }) catch return null;
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        const candidate = try std.fs.path.join(alloc, &.{ projects_dir, entry.name, file_name });
        if (fileExists(candidate)) return candidate;
        alloc.free(candidate);
    }
    return null;
}

fn waitForAssistantText(
    alloc: std.mem.Allocator,
    path: []const u8,
    max_timeout_ms: i64,
    idle_timeout_ms: i64,
    fd: c_int,
    stream: *ghostty_vt.TerminalStream,
    terminal: *ghostty_vt.Terminal,
    raw: *std.Io.Writer.Allocating,
    responder: *ProbeResponder,
    terminal_debug: *TerminalDebug,
) ![]u8 {
    const deadline = nowMs() + max_timeout_ms;
    var last_size: usize = 0;
    var last_change = nowMs();
    var last_raw_len = raw.written().len;
    var last_progress = nowMs();
    var saw_spinner = false;
    var last_spinner_or_response_progress = nowMs();

    while (nowMs() <= deadline) {
        pumpPty(alloc, fd, stream, terminal, raw, responder, terminal_debug, 50) catch |err| switch (err) {
            error.PtyClosed => {},
            else => return err,
        };
        const spinner_active = terminalHasActiveClaudeSpinner(alloc, terminal);
        var saw_progress_this_tick = false;
        if (spinner_active) {
            saw_spinner = true;
            const now = nowMs();
            last_spinner_or_response_progress = now;
            last_progress = now;
        }
        if (raw.written().len != last_raw_len) {
            last_raw_len = raw.written().len;
            last_progress = nowMs();
            saw_progress_this_tick = true;
        }

        const content = std.fs.cwd().readFileAlloc(alloc, path, 64 * 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => {
                continue;
            },
            else => return err,
        };

        if (content.len != last_size) {
            last_size = content.len;
            last_change = nowMs();
            last_progress = nowMs();
            saw_progress_this_tick = true;
        }

        const text = try finalAssistantText(alloc, content);
        alloc.free(content);
        if (text) |final_text| return final_text;

        const now = nowMs();
        if (saw_spinner and !spinner_active and saw_progress_this_tick) {
            last_spinner_or_response_progress = now;
        }
        if (saw_spinner and !spinner_active and now - last_spinner_or_response_progress > final_transcript_after_spinner_timeout_ms) {
            return error.FinalTranscriptTimeout;
        }
        if (now - last_progress > no_progress_timeout_ms) return error.ResponseNoProgress;
        if (now - last_change > idle_timeout_ms) return error.TranscriptIdleTimeout;
    }
    return error.ResponseTimeout;
}

fn finalAssistantText(alloc: std.mem.Allocator, content: []const u8) !?[]u8 {
    var result: ?[]u8 = null;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch continue;
        defer parsed.deinit();
        const obj = switch (parsed.value) { .object => |o| o, else => continue };
        const type_value = obj.get("type") orelse continue;
        if (!jsonStringEquals(type_value, "assistant")) continue;
        const message = switch (obj.get("message") orelse continue) { .object => |o| o, else => continue };
        if (!jsonStringEquals(message.get("role") orelse continue, "assistant")) continue;
        const stop_reason = message.get("stop_reason") orelse continue;
        const stopped = jsonStringEquals(stop_reason, "end_turn") or jsonStringEquals(stop_reason, "stop_sequence");
        const text = try extractText(alloc, message.get("content") orelse continue);
        if (text.len == 0) {
            alloc.free(text);
            continue;
        }
        if (result) |old| alloc.free(old);
        result = text;
        if (stopped) return result;
    }
    if (result) |old| alloc.free(old);
    return null;
}

fn extractText(alloc: std.mem.Allocator, value: std.json.Value) ![]u8 {
    switch (value) {
        .string => |s| return alloc.dupe(u8, s),
        .array => |arr| {
            var out = std.Io.Writer.Allocating.init(alloc);
            errdefer out.deinit();
            for (arr.items) |item| {
                const obj = switch (item) { .object => |o| o, else => continue };
                if (!jsonStringEquals(obj.get("type") orelse continue, "text")) continue;
                const part = switch (obj.get("text") orelse continue) { .string => |s| s, else => continue };
                if (out.written().len > 0) try out.writer.writeByte('\n');
                try out.writer.writeAll(part);
            }
            return out.toOwnedSlice();
        },
        else => return alloc.dupe(u8, ""),
    }
}

fn jsonStringEquals(value: std.json.Value, expected: []const u8) bool {
    return switch (value) {
        .string => |s| std.mem.eql(u8, s, expected),
        else => false,
    };
}

fn xtgettcapResponse(hex_key: []const u8) ?[]const u8 {
    // Full Ghostty answers XTGETTCAP from its xterm-ghostty terminfo entry.
    // This table covers the commonly fingerprinted capabilities while keeping
    // the headless wrapper independent from Ghostty's non-lib-vt modules.
    if (std.mem.eql(u8, hex_key, "544E")) return "\x1bP1+r544E=787465726D2D67686F73747479\x1b\\"; // TN=xterm-ghostty
    if (std.mem.eql(u8, hex_key, "436F")) return "\x1bP1+r436F=323536\x1b\\"; // Co=256
    if (std.mem.eql(u8, hex_key, "524742")) return "\x1bP1+r524742=38\x1b\\"; // RGB=8
    if (std.mem.eql(u8, hex_key, "5463")) return "\x1bP1+r5463\x1b\\"; // Tc
    if (std.mem.eql(u8, hex_key, "5854")) return "\x1bP1+r5854\x1b\\"; // XT
    if (std.mem.eql(u8, hex_key, "5256")) return "\x1bP1+r5256=1B5B3E63\x1b\\"; // RV=ESC[>c
    if (std.mem.eql(u8, hex_key, "5852")) return "\x1bP1+r5852=1B5B3E3071\x1b\\"; // XR=ESC[>0q
    if (std.mem.eql(u8, hex_key, "616D")) return "\x1bP1+r616D\x1b\\"; // am
    if (std.mem.eql(u8, hex_key, "626365")) return "\x1bP1+r626365\x1b\\"; // bce
    if (std.mem.eql(u8, hex_key, "6B6273")) return "\x1bP1+r6B6273=08\x1b\\"; // kbs=^H
    return null;
}

fn createUuid(alloc: std.mem.Allocator) ![:0]u8 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const uuid = try std.fmt.allocPrint(alloc, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15],
    });
    defer alloc.free(uuid);
    return alloc.dupeZ(u8, uuid);
}

fn writeAllFd(fd: c_int, data: []const u8) !void {
    var written: usize = 0;
    while (written < data.len) {
        const n = c.write(fd, data[written..].ptr, data.len - written);
        if (n < 0) return error.WriteFailed;
        if (n == 0) return error.WriteFailed;
        written += @intCast(n);
    }
}

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn parseI64(value: []const u8) !i64 {
    return std.fmt.parseInt(i64, value, 10);
}

fn parseU16(value: []const u8) !u16 {
    return std.fmt.parseInt(u16, value, 10);
}

fn nowMs() i64 {
    return std.time.milliTimestamp();
}

fn trimOwned(alloc: std.mem.Allocator, value: []u8) ![]u8 {
    const trimmed = std.mem.trimRight(u8, value, &std.ascii.whitespace);
    if (trimmed.ptr == value.ptr and trimmed.len == value.len) return value;
    const result = try alloc.dupe(u8, trimmed);
    alloc.free(value);
    return result;
}

test "extract final assistant text from Claude JSONL" {
    const alloc = std.testing.allocator;
    const jsonl =
        \\{"type":"user","message":{"role":"user","content":"hi"}}
        \\{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}}
        \\
    ;
    const text = (try finalAssistantText(alloc, jsonl)).?;
    defer alloc.free(text);
    try std.testing.expectEqualStrings("ok", text);
}

test "do not return or leak partial assistant text before end_turn" {
    const alloc = std.testing.allocator;
    const jsonl =
        \\{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"partial"}],"stop_reason":null}}
        \\
    ;
    try std.testing.expect((try finalAssistantText(alloc, jsonl)) == null);
}

test "detect Claude spinner status rows without prompt glyphs" {
    try std.testing.expect(screenHasActiveClaudeSpinner(
        "* Subscribing to Grok SuperHeavy… (30s)\n",
    ));
    try std.testing.expect(screenHasActiveClaudeSpinner(
        "✻ Searching for 1 pattern…\n",
    ));
}

test "do not mistake markdown bullets for spinner status" {
    try std.testing.expect(!screenHasActiveClaudeSpinner(
        "* cleanup must be tree-aware\n· a normal bullet without ellipsis\n",
    ));
}

test "detect Claude directory trust prompt from screen text" {
    try std.testing.expect(try containsTrustDirectoryPrompt(
        std.testing.allocator,
        \\Quick safety check: Is this a project you created or one you trust?
        \\❯ 1. Yes, I trust this folder
        \\  2. No, exit
        \\
    ));
}

test "detect Claude directory trust prompt from compact raw buffer" {
    try std.testing.expect(try containsTrustDirectoryPrompt(
        std.testing.allocator,
        "Quicksafetycheck:Isthisaprojectyoucreatedoroneyoutrust?❯1.Yes,Itrustthisfolder\r\n2.No,exit",
    ));
}

test "do not mistake normal Claude prompt for directory trust prompt" {
    try std.testing.expect(!try containsTrustDirectoryPrompt(
        std.testing.allocator,
        \\Claude Code
        \\❯ Try "create a util logging.py that..."
        \\
    ));
}

test "Ghostty XTVERSION effect matches headful Ghostty format" {
    try std.testing.expectEqualStrings("ghostty " ++ ghostty_version, xtversion(undefined));
}

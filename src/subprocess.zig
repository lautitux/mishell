// Modified source code from Zig Standard Library [std.process.Child]

const std = @import("std");
const builtin = @import("builtin");
const fs = std.fs;
const mem = std.mem;
const posix = std.posix;
const windows = std.os.windows;
const native_os = builtin.os.tag;

const EnvMap = std.process.EnvMap;
const File = fs.File;

const Child = std.process.Child;
const SpawnError = Child.SpawnError;
const Term = Child.Term;
const Id = Child.Id;
const ErrInt = std.meta.Int(.unsigned, @sizeOf(anyerror) * 8);
const WaitError = Child.WaitError;

pub const Subprocess = struct {
    /// Available after calling `spawn()`. This becomes `undefined` after calling `wait()`.
    /// On Windows this is the hProcess.
    /// On POSIX this is the pid.
    id: Id = undefined,
    thread_handle: if (native_os == .windows) windows.HANDLE else void = undefined,

    allocator: mem.Allocator,

    stdin: File,
    stdout: File,
    stderr: File,

    /// Terminated state of the child process.
    /// Available after calling `wait()`.
    term: ?(SpawnError!Term) = null,

    exe_absolute_path: []const u8,
    argv: []const []const u8,

    /// Leave as null to use the current env map using the supplied allocator.
    env_map: *const EnvMap,

    err_pipe: if (native_os == .windows) void else ?posix.fd_t =
        if (native_os == .windows) undefined else null,

    fn writeIntFd(fd: i32, value: ErrInt) !void {
        var buffer: [8]u8 = undefined;
        var fw: std.fs.File.Writer = .initStreaming(.{ .handle = fd }, &buffer);
        fw.interface.writeInt(u64, value, .little) catch unreachable;
        fw.interface.flush() catch return error.SystemResources;
    }

    fn readIntFd(fd: i32) !ErrInt {
        var buffer: [8]u8 = undefined;
        var fr: std.fs.File.Reader = .initStreaming(.{ .handle = fd }, &buffer);
        return @intCast(fr.interface.takeInt(u64, .little) catch return error.SystemResources);
    }

    // Child of fork calls this to report an error to the fork parent.
    // Then the child exits.
    fn forkChildErrReport(fd: i32, err: SpawnError) noreturn {
        writeIntFd(fd, @as(ErrInt, @intFromError(err))) catch {};
        // If we're linking libc, some naughty applications may have registered atexit handlers
        // which we really do not want to run in the fork child. I caught LLVM doing this and
        // it caused a deadlock instead of doing an exit syscall. In the words of Avril Lavigne,
        // "Why'd you have to go and make things so complicated?"
        if (builtin.link_libc) {
            // The _exit(2) function does nothing but make the exit syscall, unlike exit(3)
            std.c._exit(1);
        }
        posix.exit(1);
    }

    /// On success must call `kill` or `wait`.
    /// After spawning the `id` is available.
    pub fn spawn(self: *Subprocess) SpawnError!void {
        if (!std.process.can_spawn) {
            @compileError("the target operating system cannot spawn processes");
        }

        if (native_os == .windows) {
            @compileError("TODO!");
        } else {
            return self.spawnPosix();
        }
    }

    fn spawnPosix(self: *Subprocess) SpawnError!void {
        var arena_allocator = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_allocator.deinit();
        const arena = arena_allocator.allocator();

        // The POSIX standard does not allow malloc() between fork() and execve(),
        // and `self.allocator` may be a libc allocator.
        // I have personally observed the child process deadlocking when it tries
        // to call malloc() due to a heap allocation between fork() and execve(),
        // in musl v1.1.24.
        // Additionally, we want to reduce the number of possible ways things
        // can fail between fork() and execve().
        // Therefore, we do all the allocation for the execve() before the fork().
        // This means we must do the null-termination of argv and env vars here.
        const argv_buf = try arena.allocSentinel(?[*:0]const u8, self.argv.len, null);
        for (self.argv, 0..) |arg, i| argv_buf[i] = (try arena.dupeZ(u8, arg)).ptr;

        const exe_path = try arena.dupeZ(u8, self.exe_absolute_path);

        const envp: [*:null]const ?[*:0]const u8 = (try std.process.createEnvironFromMap(arena, self.env_map, .{})).ptr;

        // This pipe communicates to the parent errors in the child between `fork` and `execvpe`.
        // It is closed by the child (via CLOEXEC) without writing if `execvpe` succeeds.
        const err_pipe: [2]posix.fd_t = try posix.pipe2(.{ .CLOEXEC = true });
        errdefer {
            if (err_pipe[0] != -1) posix.close(err_pipe[0]);
            if (err_pipe[0] != err_pipe[1]) posix.close(err_pipe[1]);
        }

        const pid_result = try posix.fork();
        if (pid_result == 0) {
            // we are the child
            posix.dup2(self.stdin.handle, posix.STDIN_FILENO) catch |err| forkChildErrReport(err_pipe[1], err);
            posix.dup2(self.stdout.handle, posix.STDOUT_FILENO) catch |err| forkChildErrReport(err_pipe[1], err);
            posix.dup2(self.stderr.handle, posix.STDERR_FILENO) catch |err| forkChildErrReport(err_pipe[1], err);

            const err = posix.execveZ(exe_path.ptr, argv_buf.ptr, envp);
            forkChildErrReport(err_pipe[1], err);
        }

        // we are the parent
        errdefer comptime unreachable; // The child is forked; we must not error from now on

        posix.close(err_pipe[1]); // make sure only the child holds the write end open
        self.err_pipe = err_pipe[0];

        const pid: i32 = @intCast(pid_result);

        self.id = pid;
        self.term = null;
    }

    /// On some targets, `spawn` may not report all spawn errors, such as `error.InvalidExe`.
    /// This function will block until any spawn errors can be reported, and return them.
    pub fn waitForSpawn(self: *Subprocess) SpawnError!void {
        if (native_os == .windows) return; // `spawn` reports everything
        if (self.term) |term| {
            _ = term catch |spawn_err| return spawn_err;
            return;
        }

        const err_pipe = self.err_pipe orelse return;
        self.err_pipe = null;

        // Wait for the child to report any errors in or before `execvpe`.
        if (readIntFd(err_pipe)) |child_err_int| {
            posix.close(err_pipe);
            const child_err: SpawnError = @errorCast(@errorFromInt(child_err_int));
            self.term = child_err;
            return child_err;
        } else |_| {
            // Write end closed by CLOEXEC at the time of the `execvpe` call, indicating success!
            posix.close(err_pipe);
        }
    }

    /// Blocks until child process terminates and then cleans up all resources.
    pub fn wait(self: *Subprocess) WaitError!Term {
        try self.waitForSpawn(); // report spawn errors
        if (self.term) |term| {
            return term;
        }
        switch (native_os) {
            .windows => @compileError("TODO!"),
            else => self.waitUnwrappedPosix(),
        }
        self.id = undefined;
        return self.term.?;
    }

    fn statusToTerm(status: u32) Term {
        return if (posix.W.IFEXITED(status))
            Term{ .Exited = posix.W.EXITSTATUS(status) }
        else if (posix.W.IFSIGNALED(status))
            Term{ .Signal = posix.W.TERMSIG(status) }
        else if (posix.W.IFSTOPPED(status))
            Term{ .Stopped = posix.W.STOPSIG(status) }
        else
            Term{ .Unknown = status };
    }

    fn waitUnwrappedPosix(self: *Subprocess) void {
        const res: posix.WaitPidResult = posix.waitpid(self.id, 0);
        const status = res.status;
        self.term = statusToTerm(status);
    }
};

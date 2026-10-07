// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Darwin
import Foundation

/// Tells the launchd agent that the bundle it was started from is gone.
///
/// An update (Sparkle) or a reinstall replaces Chevron7.app while launchd keeps
/// the agent running from the old copy. Sparkle moves that copy into its cache
/// and deletes it, so the Safari extension, which checks the agent's code
/// signature on every reply, refuses it (`-67065`) until the Mac restarts. An
/// agent that notices this quits, and launchd starts the current one from the
/// registered bundle on the next request.
public enum WebBridgeAgentStaleness {
    public struct FileIdentity: Equatable, Sendable {
        public let device: UInt64
        public let inode: UInt64

        public init(device: UInt64, inode: UInt64) {
            self.device = device
            self.inode = inode
        }
    }

    /// True when the agent no longer runs the file at the path it was launched
    /// from: its image moved elsewhere, or that path now holds another file or
    /// none. Anything that could not be read at launch decides nothing.
    public static func isStale(launchPath: String?, launchFile: FileIdentity?,
                               runningPath: String?, fileAtLaunchPath: FileIdentity?) -> Bool {
        guard let launchPath else { return false }
        if let runningPath, runningPath != launchPath {
            return true
        }
        guard let launchFile else { return false }
        return fileAtLaunchPath != launchFile
    }

    /// An agent started before this check existed never quits on its own. Seen
    /// from the app it is abandoned when its file is gone (Sparkle deletes the
    /// old copy, and the kernel then reports no path at all) or lies in the
    /// Trash; a copy that still exists elsewhere, such as a development
    /// build's, is left alone.
    public static func isAbandoned(executablePath: String?, fileExists: Bool) -> Bool {
        guard let executablePath else { return true }
        return !fileExists || executablePath.contains("/.Trash/")
    }

    public static let agentExecutableName = "chevron7-webbridge-agent"

    /// This user's agent processes whose executable is abandoned.
    public static func abandonedAgentProcesses() -> [pid_t] {
        let count = proc_listpids(UInt32(PROC_UID_ONLY), UInt32(getuid()), nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) / MemoryLayout<pid_t>.size + 32)
        let filled = proc_listpids(UInt32(PROC_UID_ONLY), UInt32(getuid()), &pids,
                                   Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        return pids.prefix(Int(filled) / MemoryLayout<pid_t>.size).filter { pid in
            guard pid > 0, processName(of: pid) == agentExecutableName else { return false }
            errno = 0
            let path = executablePath(of: pid)
            // No path for another reason (the process just ended) decides nothing.
            if path == nil, errno != ENOENT { return false }
            return isAbandoned(executablePath: path,
                               fileExists: path.map { FileManager.default.fileExists(atPath: $0) } ?? false)
        }
    }

    /// The process name the kernel keeps (up to 32 bytes), which survives the
    /// deletion of the executable.
    static func processName(of pid: pid_t) -> String? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pbi_name) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// Where the kernel says this process's executable is now; it follows a move.
    public static func runningExecutablePath() -> String? {
        executablePath(of: getpid())
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    public static func fileIdentity(atPath path: String) -> FileIdentity? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }
}

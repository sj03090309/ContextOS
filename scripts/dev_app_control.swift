import AppKit
import Foundation
import Darwin

// Development installer helper. Match the exact bundle, never just its name,
// and ask AppKit to terminate it so normal application shutdown can complete.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

let arguments = CommandLine.arguments
guard arguments.count == 3, ["check", "quit"].contains(arguments[1]),
      (arguments[2] as NSString).isAbsolutePath else {
    fail("Usage: dev_app_control <check|quit> <absolute ContextOS.app path>")
}

func normalized(_ url: URL) -> URL {
    url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
}

let target = normalized(URL(fileURLWithPath: arguments[2], isDirectory: true))
guard target.lastPathComponent == "ContextOS.app" else {
    fail("Target must be an absolute ContextOS.app bundle path.")
}

func matchingApplications() -> [NSRunningApplication] {
    NSWorkspace.shared.runningApplications.filter { application in
        guard !application.isTerminated, let bundle = application.bundleURL else { return false }
        return normalized(bundle).path == target.path
    }
}

let applications = matchingApplications()
if arguments[1] == "check" {
    exit(applications.isEmpty ? 1 : 0)
}

for application in applications {
    if !application.terminate(), !application.isTerminated {
        fail("ContextOS refused a normal quit; installation must wait.")
    }
}

let deadline = ProcessInfo.processInfo.systemUptime + 20
while !matchingApplications().isEmpty {
    guard ProcessInfo.processInfo.systemUptime < deadline else {
        fail("ContextOS did not quit within 20 seconds; installation must wait.")
    }
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
}
exit(0)

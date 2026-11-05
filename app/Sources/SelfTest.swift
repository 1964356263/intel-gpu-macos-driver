// SPDX-License-Identifier: MIT
// IntelXeManager --selftest [package folder]: the parts that need no window and no password, for checking a build.
import AppKit
import SwiftUI

/// Each page without a window, to look at the layout.
@MainActor
func renderSnapshots(into folder: String) {
    _ = NSApplication.shared
    let manager = Manager()
    manager.facts = SystemFacts.probe()
    if CommandLine.arguments.count > 2 {
        let package = Package(directory: URL(fileURLWithPath: CommandLine.arguments[2]))
        manager.package = package
        manager.packageStatus = package.status()
    }
    let pages: [(String, AnyView)] = [("system", AnyView(SystemView())), ("driver", AnyView(DriverView())), ("zink", AnyView(ZinkView()))]
    for (name, page) in pages {
        let host = NSHostingView(rootView: page.environmentObject(manager).frame(width: 640, height: 640))
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 640)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(folder)/\(name).png"))
    }
}

func selfTest() {
    var failures = 0
    func expect(_ condition: Bool, _ what: String) {
        print(condition ? "ok    \(what)" : "FAIL  \(what)")
        if !condition { failures += 1 }
    }
    expect(Version("v0.1.2")! > Version("0.1.1")!, "0.1.2 is newer than 0.1.1")
    expect(Version("0.10.0")! > Version("0.9.9")!, "versions compare as numbers")
    expect(Version("v0.2") == nil && Version("0.1.x") == nil, "a tag that is not x.y.z is not a version")
    expect(listedHash("abc  a.zip\ndef *b.zip\n", name: "b.zip") == "def", "hash list with the binary mark")
    expect(listedHash("abc  a.zip\n", name: "c.zip") == nil, "a file not in the list has no hash")
    expect(shellQuoted("it's") == "'it'\\''s'", "shell quoting")
    let script = privilegedScript(command: "'/a b/in\"st.sh' --apply", log: "/l.log", prompt: "p")
    expect(script.contains("in\\\"st.sh") && script.hasSuffix("with administrator privileges"), "AppleScript quoting")
    expect(packageSuffix(macOSMajor: 26) == "-tahoe.zip" && packageSuffix(macOSMajor: 15) == "-sequoia.zip" && packageSuffix(macOSMajor: 27) == nil, "package per macOS")

    let sample = #"{"tag_name":"v0.1.2","html_url":"https://example.invalid/r","body":"notes","prerelease":false,"unknown":1,"assets":[{"name":"intel-gpu-macos-driver-0.1.2-tahoe.zip","browser_download_url":"https://example.invalid/a.zip","size":5,"state":"uploaded"},{"name":"intel-gpu-macos-driver-0.1.2.sha256","browser_download_url":"https://example.invalid/s","size":1}]}"#
    let decoded = try? JSONDecoder().decode(Release.self, from: Data(sample.utf8))
    expect(decoded?.version == Version("0.1.2") && decoded?.asset("-tahoe.zip") != nil && decoded?.asset(".sha256") != nil && decoded?.asset("-zink-gl.zip") == nil, "a release as GitHub's API sends it")

    let facts = SystemFacts.probe()
    print("facts macOS \(facts.macOS), \(facts.architecture), card \(facts.hasCard), kext \(facts.kextLoaded), metal '\(facts.metalDevice)', sip '\(facts.sipText)', installed \(facts.installedVersion ?? "-"), zink \(facts.zinkInstalled)/\(facts.zinkGlobal)")
    for check in facts.checks { print("check \(check.id): \(check.state) \(check.value)") }

    if CommandLine.arguments.count > 2 {
        let package = Package(directory: URL(fileURLWithPath: CommandLine.arguments[2]))
        expect(package.isValid, "package folder is valid")
        print("status \(package.status().sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("intelxe-manager-selftest-\(getpid()).log")
        let ran = run(command: "\(shellQuoted(package.script.path)) --check", needsRoot: false, log: log, prompt: "")
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        print(text.split(separator: "\n").suffix(3).joined(separator: "\n"))
        expect(text.contains("checks") && !ran.cancelled, "ran the package's check and read its log")
        try? FileManager.default.removeItem(at: log)
    }

    if let at = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > at + 1 {
        MainActor.assumeIsolated { renderSnapshots(into: CommandLine.arguments[at + 1]) }
    }

    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            let release = try await latestRelease()
            print("latest \(release.tag_name), assets \(release.assets.map(\.name).joined(separator: " "))")
            expect(release.version != nil, "the latest tag is a version")
        } catch { print("no network answer: \(error.localizedDescription)") }
        semaphore.signal()
    }
    semaphore.wait()
    print(failures == 0 ? "selftest passed" : "selftest: \(failures) failure(s)")
    exit(failures == 0 ? 0 : 1)
}

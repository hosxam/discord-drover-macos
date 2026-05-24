import AppKit
import Foundation

enum ProxyMode: String, CaseIterable, Identifiable, Sendable {
    case direct
    case http
    case socks5

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .direct: return "Direct"
        case .http: return "HTTP"
        case .socks5: return "SOCKS5"
        }
    }
}

struct DiscordApplication: Identifiable, Sendable {
    let name: String
    let path: String

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
}

struct LaunchSettings: Sendable {
    let mode: ProxyMode
    let host: String
    let port: Int?
    let authentication: Bool
    let login: String
    let password: String

    var proxyURL: String? {
        guard mode != .direct, let port else { return nil }
        var value = "\(mode.rawValue)://"
        if mode == .http && authentication {
            value += "\(login):\(password)@"
        }
        return value + "\(host):\(port)"
    }

    var chromeProxy: String? {
        guard mode != .direct, let port else { return nil }
        return "\(mode.rawValue)://\(host):\(port)"
    }

    var environmentProxy: String? {
        guard mode != .direct, let port else { return nil }
        if mode == .socks5 {
            return "http://\(host):\(port)"
        }
        return proxyURL
    }
}

enum DroverError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let value): return value
        }
    }
}

@MainActor
final class DroverController: ObservableObject {
    @Published var applications: [DiscordApplication] = []
    @Published var selectedApplicationPath = ""
    @Published var mode: ProxyMode = .direct
    @Published var host = ""
    @Published var port = ""
    @Published var authentication = false
    @Published var login = ""
    @Published var password = ""
    @Published var hasPacket = false
    @Published var status = ""
    @Published var statusIsError = false
    @Published var busy = false
    @Published var canRevealManagedCopy = false

    private let supportDirectory = DroverRuntime.supportDirectory

    init() {
        refreshApplications()
        loadSettings()
        updatePacketStatus()
    }

    func refreshApplications() {
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]
        let names = ["Discord.app", "Discord Canary.app", "Discord PTB.app"]

        applications = roots.flatMap { root in
            names.compactMap { name -> DiscordApplication? in
                let url = root.appendingPathComponent(name, isDirectory: true)
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                return DiscordApplication(name: name.replacingOccurrences(of: ".app", with: ""), path: url.path)
            }
        }

        if !applications.contains(where: { $0.path == selectedApplicationPath }) {
            selectedApplicationPath = applications.first?.path ?? ""
        }
    }

    func prepareAndLaunch() {
        guard let application = applications.first(where: { $0.path == selectedApplicationPath }) else {
            setError("Select an installed Discord application first.")
            return
        }

        let settings: LaunchSettings
        do {
            settings = try validatedSettings()
            try ensureDiscordIsNotRunning(application.url)
        } catch {
            setError(error.localizedDescription)
            return
        }

        guard let shim = Bundle.main.url(forResource: "libdrover", withExtension: "dylib") else {
            setError("The bundled network shim is missing. Build the app with Scripts/build-app.sh.")
            return
        }

        busy = true
        canRevealManagedCopy = false
        statusIsError = false
        status = "Preparing a private Discord copy and applying Drover settings..."

        Task {
            do {
                let message = try await Task.detached {
                    try DroverRuntime.prepareAndLaunch(
                        sourceApplication: application.url,
                        settings: settings,
                        bundledShim: shim
                    )
                }.value
                status = message
                statusIsError = false
            } catch {
                setError(error.localizedDescription)
                canRevealManagedCopy = DroverRuntime.hasManagedCopy(for: application.url)
            }
            busy = false
        }
    }

    func importPacket(_ result: Result<[URL], Error>) {
        do {
            guard let source = try result.get().first else { return }
            let accessing = source.startAccessingSecurityScopedResource()
            defer {
                if accessing { source.stopAccessingSecurityScopedResource() }
            }
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            let destination = supportDirectory.appendingPathComponent("drover-packet.bin")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: source, to: destination)
            updatePacketStatus()
            setStatus("The optional UDP packet will be read on each new voice connection.")
        } catch {
            setError("Could not import the packet file: \(error.localizedDescription)")
        }
    }

    func removePacket() {
        try? FileManager.default.removeItem(at: supportDirectory.appendingPathComponent("drover-packet.bin"))
        updatePacketStatus()
        setStatus("Removed the optional UDP packet.")
    }

    func removeManagedCopy() {
        do {
            try DroverRuntime.removeManagedCopies()
            canRevealManagedCopy = false
            setStatus("Removed the managed Discord copy. Your original installation was not changed.")
        } catch {
            setError("Could not remove the managed copy: \(error.localizedDescription)")
        }
    }

    func showManagedCopyInFinder() {
        guard let application = applications.first(where: { $0.path == selectedApplicationPath }),
              let managedApplication = DroverRuntime.managedApplicationURL(for: application.url) else {
            setError("No prepared Discord copy was found. Click Prepare and Launch Discord first.")
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([managedApplication])
        setStatus("The prepared Discord copy is selected in Finder. This button shows the file; it does not launch Discord.")
    }

    private func validatedSettings() throws -> LaunchSettings {
        if mode == .direct {
            return LaunchSettings(mode: .direct, host: "", port: nil, authentication: false, login: "", password: "")
        }

        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty, !cleanHost.contains(" "), !cleanHost.contains("@") else {
            throw DroverError.message("Enter a valid proxy host.")
        }
        guard let numericPort = Int(port), (1...65535).contains(numericPort) else {
            throw DroverError.message("Enter a proxy port between 1 and 65535.")
        }
        if mode == .http && authentication &&
            (login.isEmpty || password.isEmpty || login.contains(":") || login.contains("@") || password.contains("@")) {
            throw DroverError.message("Enter HTTP proxy credentials without ':' or '@' in the login and without '@' in the password.")
        }

        return LaunchSettings(
            mode: mode,
            host: cleanHost,
            port: numericPort,
            authentication: mode == .http && authentication,
            login: login,
            password: password
        )
    }

    private func ensureDiscordIsNotRunning(_ source: URL) throws {
        guard let bundleIdentifier = Bundle(url: source)?.bundleIdentifier else { return }
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleIdentifier }) {
            throw DroverError.message("Quit Discord before preparing or launching a Drover session.")
        }
    }

    private func loadSettings() {
        let configuration = supportDirectory.appendingPathComponent("drover.ini")
        guard let contents = try? String(contentsOf: configuration, encoding: .utf8),
              let proxyLine = contents.split(whereSeparator: \.isNewline)
                .map(String.init)
                .first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("proxy") }),
              let equals = proxyLine.firstIndex(of: "=") else {
            return
        }

        let proxy = proxyLine[proxyLine.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        guard !proxy.isEmpty, let components = URLComponents(string: proxy),
              let scheme = components.scheme,
              let parsedMode = ProxyMode(rawValue: scheme),
              let parsedHost = components.host,
              let parsedPort = components.port else {
            return
        }

        mode = parsedMode
        host = parsedHost
        port = String(parsedPort)
        login = components.user ?? ""
        password = components.password ?? ""
        authentication = parsedMode == .http && components.user != nil && components.password != nil
    }

    private func updatePacketStatus() {
        hasPacket = FileManager.default.fileExists(
            atPath: supportDirectory.appendingPathComponent("drover-packet.bin").path
        )
    }

    private func setStatus(_ message: String) {
        status = message
        statusIsError = false
    }

    private func setError(_ message: String) {
        status = message
        statusIsError = true
    }
}

enum DroverRuntime {
    static let supportDirectory = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    )[0].appendingPathComponent("Discord Drover", isDirectory: true)

    static func prepareAndLaunch(
        sourceApplication: URL,
        settings: LaunchSettings,
        bundledShim: URL
    ) throws -> String {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)

        let configuration = supportDirectory.appendingPathComponent("drover.ini")
        let contents = "[drover]\nproxy = \(settings.proxyURL ?? "")\n"
        try contents.write(to: configuration, atomically: true, encoding: .utf8)

        let installedShim = supportDirectory.appendingPathComponent("libdrover.dylib")
        try? fileManager.removeItem(at: installedShim)
        try fileManager.copyItem(at: bundledShim, to: installedShim)

        let managedRoot = supportDirectory.appendingPathComponent("Managed", isDirectory: true)
        try fileManager.createDirectory(at: managedRoot, withIntermediateDirectories: true)
        let managedApplication = managedRoot.appendingPathComponent(sourceApplication.lastPathComponent, isDirectory: true)
        let marker = managedRoot.appendingPathComponent(sourceApplication.lastPathComponent + ".source-version")
        let sourceVersion = versionMarker(for: sourceApplication)
        let installedVersion = try? String(contentsOf: marker, encoding: .utf8)

        if installedVersion != sourceVersion || !fileManager.fileExists(atPath: managedApplication.path) {
            try? fileManager.removeItem(at: managedApplication)
            try fileManager.copyItem(at: sourceApplication, to: managedApplication)
            try resignForInjection(managedApplication)
            try sourceVersion.write(to: marker, atomically: true, encoding: .utf8)
        }
        try clearQuarantine(from: managedApplication)

        guard let executableName = Bundle(url: managedApplication)?
            .object(forInfoDictionaryKey: "CFBundleExecutable") as? String else {
            throw DroverError.message("The selected Discord application does not identify its executable.")
        }
        let executable = managedApplication
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(executableName)
        guard fileManager.isExecutableFile(atPath: executable.path) else {
            throw DroverError.message("The selected Discord executable is missing or cannot be launched.")
        }

        var environment = ProcessInfo.processInfo.environment
        environment["DYLD_INSERT_LIBRARIES"] = installedShim.path
        environment["DROVER_CONFIG_DIR"] = supportDirectory.path
        if let proxy = settings.environmentProxy {
            environment["http_proxy"] = proxy
            environment["https_proxy"] = proxy
        } else {
            environment.removeValue(forKey: "http_proxy")
            environment.removeValue(forKey: "https_proxy")
        }

        let process = Process()
        let log = supportDirectory.appendingPathComponent("discord-launch.log")
        fileManager.createFile(atPath: log.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: log)
        defer { try? logHandle.close() }
        process.executableURL = executable
        process.environment = environment
        process.standardOutput = logHandle
        process.standardError = logHandle
        if let proxy = settings.chromeProxy {
            process.arguments = ["--proxy-server=\(proxy)"]
        }
        try process.run()
        Thread.sleep(forTimeInterval: 2.0)
        try? logHandle.synchronize()
        guard process.isRunning else {
            let details = compactLogDetails(from: log)
            throw DroverError.message(
                "Discord exited before opening. Click Show Prepared Discord in Finder to locate the local copy. If macOS blocks it, Control-click it, choose Open, quit Discord, and try again." + details
            )
        }

        return settings.mode == .direct
            ? "Discord launched in Direct mode. UDP voice handling is active."
            : "Discord launched through the configured \(settings.mode.displayName) proxy with UDP voice handling active."
    }

    static func managedApplicationURL(for sourceApplication: URL) -> URL? {
        let managedApplication = supportDirectory
            .appendingPathComponent("Managed", isDirectory: true)
            .appendingPathComponent(sourceApplication.lastPathComponent, isDirectory: true)
        return FileManager.default.fileExists(atPath: managedApplication.path) ? managedApplication : nil
    }

    static func hasManagedCopy(for sourceApplication: URL) -> Bool {
        managedApplicationURL(for: sourceApplication) != nil
    }

    static func removeManagedCopies() throws {
        let managedRoot = supportDirectory.appendingPathComponent("Managed", isDirectory: true)
        if FileManager.default.fileExists(atPath: managedRoot.path) {
            try FileManager.default.removeItem(at: managedRoot)
        }
    }

    private static func versionMarker(for application: URL) -> String {
        let bundle = Bundle(url: application)
        let shortVersion = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let executableName = bundle?.object(forInfoDictionaryKey: "CFBundleExecutable") as? String ?? "Discord"
        let executable = application.appendingPathComponent("Contents/MacOS/\(executableName)")
        let attributes = try? FileManager.default.attributesOfItem(atPath: executable.path)
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(shortVersion)|\(build)|\(modified)"
    }

    private static func resignForInjection(_ application: URL) throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--deep", "--sign", "-", "--timestamp=none", application.path]
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8) ?? "codesign failed."
            throw DroverError.message("Could not prepare Discord for the Drover shim: \(detail)")
        }
    }

    private static func clearQuarantine(from application: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-dr", "com.apple.quarantine", application.path]
        try process.run()
        process.waitUntilExit()
        // If the attribute is already absent, there is nothing to remove.
    }

    private static func compactLogDetails(from url: URL) -> String {
        guard let data = try? Data(contentsOf: url),
              !data.isEmpty,
              let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty else {
            return ""
        }
        let suffix = String(output.suffix(500))
        return "\n\nLaunch log: \(suffix)"
    }
}

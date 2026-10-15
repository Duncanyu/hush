import AppKit
import CryptoKit
import Foundation

private struct GitHubRelease: Decodable {
    let tagName: String
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}

private struct GitHubAsset: Decodable {
    let name: String
    let downloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name
        case downloadURL = "browser_download_url"
    }
}

final class HushUpdater {
    private let session: URLSession
    private let fileManager = FileManager.default
    private var timer: Timer?
    private var checking = false
    private var enabled = false
    private let repository = "Duncanyu/hush"

    init(session: URLSession = .shared) {
        self.session = session
    }

    func start(enabled: Bool) {
        self.enabled = enabled
        timer?.invalidate()
        guard enabled else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) {
            [weak self] _ in self?.check()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.check() }
    }

    func setEnabled(_ enabled: Bool) {
        start(enabled: enabled)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func check() {
        guard enabled, !checking else { return }
        checking = true
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("Hush/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            defer { self.checking = false }
            guard error == nil, let data, let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let release = try? JSONDecoder().decode(GitHubRelease.self, from: data),
                  self.isNewer(release.tagName) else { return }
            DispatchQueue.main.async { self.offer(release) }
        }.resume()
    }

    private func offer(_ release: GitHubRelease) {
        let alert = NSAlert()
        alert.messageText = "Hush \(release.tagName) is available"
        alert.informativeText = "Download and install the update from GitHub now?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install Update")
        alert.addButton(withTitle: "Later")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        install(release)
    }

    private func install(_ release: GitHubRelease) {
        guard let archive = release.assets.first(where: { $0.name.hasSuffix(".zip") }),
              let checksum = release.assets.first(where: { $0.name.hasSuffix(".zip.sha256") }),
              let appURL = Bundle.main.bundleURL.standardizedFileURL as URL?,
              appURL.pathExtension == "app" else { return }
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("HushUpdate-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch { return }
        let task = session.downloadTask(with: archive.downloadURL) { [weak self] location, _, error in
            guard let self, error == nil, let location else { return }
            do {
                let archiveURL = directory.appendingPathComponent(archive.name)
                try self.fileManager.moveItem(at: location, to: archiveURL)
                let checksumData = try Data(contentsOf: checksum.downloadURL)
                let expected = String(decoding: checksumData, as: UTF8.self)
                    .split(whereSeparator: \.isWhitespace).first.map(String.init)
                let actual = SHA256.hash(data: try Data(contentsOf: archiveURL))
                    .map { String(format: "%02x", $0) }.joined()
                guard expected == actual else { return }
                try self.extract(archiveURL, to: directory)
                let newApp = directory.appendingPathComponent("Hush.app")
                guard self.fileManager.fileExists(atPath: newApp.path) else { return }
                self.launchReplacement(newApp: newApp, currentApp: appURL, directory: directory)
            } catch { return }
        }
        task.resume()
    }

    private func extract(_ archive: URL, to directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, directory.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
    }

    private func launchReplacement(newApp: URL, currentApp: URL, directory: URL) {
        let scriptURL = directory.appendingPathComponent("install.sh")
        let script = """
        #!/bin/sh
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 1; done
        rm -rf \(shellQuote(currentApp.path))
        mv \(shellQuote(newApp.path)) \(shellQuote(currentApp.path))
        open \(shellQuote(currentApp.path))
        rm -rf \(shellQuote(directory.path))
        """
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [scriptURL.path]
            try process.run()
            NSApp.terminate(nil)
        } catch { return }
    }

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    private func isNewer(_ tag: String) -> Bool {
        let remote = tag.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            .split(separator: ".").compactMap { Int($0) }
        let local = currentVersion.split(separator: ".").compactMap { Int($0) }
        let remoteVersion = Array((remote + [0, 0, 0]).prefix(3))
        let localVersion = Array((local + [0, 0, 0]).prefix(3))
        for index in 0..<3 where remoteVersion[index] != localVersion[index] {
            return remoteVersion[index] > localVersion[index]
        }
        return false
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

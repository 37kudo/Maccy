import CryptoKit
import Defaults
import Foundation
import Logging

final class SyncClipboardCloudSync {
  static let shared = SyncClipboardCloudSync()

  private let logger = Logger(label: "org.p0deje.Maccy.SyncClipboardCloud")
  private let session: URLSession
  private var uploadTask: URLSessionDataTask?
  private var lastUploadedHash: String?

  private init(session: URLSession = .shared) {
    self.session = session
  }

  func upload(_ item: HistoryItem) {
    let config = configuration()
    guard config.enabled else {
      logger.debug("Cloud sync skipped: disabled")
      return
    }
    guard let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
      logger.debug("Cloud sync skipped: empty text")
      return
    }
    guard var baseURL = URL(string: config.url.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      logger.warning("Cloud sync skipped: invalid URL")
      return
    }

    guard !config.username.isEmpty, !config.password.isEmpty else {
      logger.warning("Cloud sync skipped: missing credentials")
      return
    }

    let hash = Self.sha256(text)
    guard hash != lastUploadedHash else {
      logger.debug("Cloud sync skipped: already uploaded")
      return
    }

    if !baseURL.path.hasSuffix("/") {
      baseURL.appendPathComponent("")
    }

    let profileURL = baseURL.appendingPathComponent("SyncClipboard.json")
    var request = URLRequest(url: profileURL)
    request.httpMethod = "PUT"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(Self.basicAuth(username: config.username, password: config.password), forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 10

    let payload = SyncClipboardTextProfile(
      type: "Text",
      hash: hash,
      text: text,
      hasData: false,
      dataName: "",
      size: text.utf8.count
    )

    guard let body = try? JSONEncoder().encode(payload) else { return }
    request.httpBody = body

    uploadTask?.cancel()
    uploadTask = session.dataTask(with: request) { [weak self] _, response, error in
      if let error {
        self?.logger.error("Cloud sync failed: \(error.localizedDescription)")
        return
      }

      guard let response = response as? HTTPURLResponse else {
        self?.logger.error("Cloud sync failed: missing HTTP response")
        return
      }

      guard (200...299).contains(response.statusCode) else {
        self?.logger.error("Cloud sync failed: HTTP \(response.statusCode)")
        return
      }

      self?.lastUploadedHash = hash
      self?.logger.debug("Cloud sync uploaded text profile")
    }
    uploadTask?.resume()
  }

  private func configuration() -> CloudConfig {
    let enabled = externalPreference("syncClipboardCloudEnabled") as Bool? ??
      UserDefaults.standard.object(forKey: "syncClipboardCloudEnabled") as? Bool ??
      Defaults[.syncClipboardCloudEnabled]

    return CloudConfig(
      enabled: enabled,
      url: externalPreference("syncClipboardCloudURL") as String? ??
        UserDefaults.standard.string(forKey: "syncClipboardCloudURL") ??
        Defaults[.syncClipboardCloudURL],
      username: externalPreference("syncClipboardCloudUsername") as String? ??
        UserDefaults.standard.string(forKey: "syncClipboardCloudUsername") ??
        Defaults[.syncClipboardCloudUsername],
      password: externalPreference("syncClipboardCloudPassword") as String? ??
        UserDefaults.standard.string(forKey: "syncClipboardCloudPassword") ??
        Defaults[.syncClipboardCloudPassword]
    )
  }

  private func externalPreference<T>(_ key: String) -> T? {
    if let value = CFPreferencesCopyAppValue(key as CFString, "org.p0deje.Maccy" as CFString) as? T {
      return value
    }

    let candidates = [
      "\(NSHomeDirectory())/Library/Preferences/org.p0deje.Maccy.plist",
      "\(NSHomeDirectory())/Library/Containers/org.p0deje.Maccy/Data/Library/Preferences/org.p0deje.Maccy.plist"
    ]

    for candidate in candidates {
      guard let data = try? Data(contentsOf: URL(fileURLWithPath: candidate)),
            let preferences = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let value = preferences[key] as? T else {
        continue
      }

      return value
    }

    return nil
  }

  private static func basicAuth(username: String, password: String) -> String {
    let credentials = "\(username):\(password)"
    let encoded = Data(credentials.utf8).base64EncodedString()
    return "Basic \(encoded)"
  }

  private static func sha256(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8))
      .map { String(format: "%02X", $0) }
      .joined()
  }
}

private struct CloudConfig {
  let enabled: Bool
  let url: String
  let username: String
  let password: String
}

private struct SyncClipboardTextProfile: Encodable {
  let type: String
  let hash: String
  let text: String
  let hasData: Bool
  let dataName: String
  let size: Int
}

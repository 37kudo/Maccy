import AppKit
import Defaults
import Foundation

final class SMSCodeHelper {
  weak var footerItem: FooterItem?

  private let requestTimeout: TimeInterval = 10
  private var isFetching = false

  func fetchCode() {
    guard !isFetching else { return }

    let webhookURL = Defaults[.smsCodeWebhookURL].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !webhookURL.isEmpty else {
      notify(body: NSLocalizedString("sms_code_missing_webhook", comment: ""))
      return
    }

    guard let url = URL(string: webhookURL), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
      notify(body: NSLocalizedString("sms_code_invalid_webhook", comment: ""))
      return
    }

    isFetching = true
    footerItem?.title = "get_verification_code_fetching"

    let request = URLRequest(
      url: url,
      cachePolicy: .reloadIgnoringLocalCacheData,
      timeoutInterval: requestTimeout
    )

    URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
      let result = self?.parseResult(data: data, response: response, error: error) ?? .failure(.cancelled)
      Task { @MainActor [weak self] in
        self?.handle(result)
      }
    }.resume()
  }

  private func parseResult(data: Data?, response: URLResponse?, error: Error?) -> Result<String, FetchError> {
    if let error {
      return .failure(.network(error.localizedDescription))
    }

    guard let response = response as? HTTPURLResponse else {
      return .failure(.invalidResponse)
    }

    guard (200...299).contains(response.statusCode) else {
      return .failure(.httpStatus(response.statusCode))
    }

    let rawText = String(decoding: data ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rawText.isEmpty else {
      return .failure(.emptyResponse)
    }

    let code = Self.extractCode(from: rawText)
    guard !code.isEmpty else {
      return .failure(.unrecognized)
    }

    return .success(code)
  }

  @MainActor
  private func handle(_ result: Result<String, FetchError>) {
    isFetching = false

    switch result {
    case .success(let code):
      footerItem?.title = code
      Clipboard.shared.copy(code)
      notify(
        body: String(
          format: NSLocalizedString("sms_code_copied", comment: ""),
          code
        ),
        sound: .write
      )
    case .failure(.cancelled):
      break
    case .failure(.network(let reason)):
      footerItem?.title = "sms_code_fetch_failed_short"
      notify(
        body: String(
          format: NSLocalizedString("sms_code_fetch_failed", comment: ""),
          reason
        )
      )
    case .failure(.httpStatus(let statusCode)):
      footerItem?.title = "sms_code_fetch_failed_short"
      notify(
        body: String(
          format: NSLocalizedString("sms_code_http_error", comment: ""),
          statusCode
        )
      )
    case .failure(.invalidResponse):
      footerItem?.title = "sms_code_invalid_response"
      notify(body: NSLocalizedString("sms_code_invalid_response", comment: ""))
    case .failure(.emptyResponse):
      footerItem?.title = "sms_code_empty_response"
      notify(body: NSLocalizedString("sms_code_empty_response", comment: ""))
    case .failure(.unrecognized):
      footerItem?.title = "sms_code_unrecognized"
      notify(body: NSLocalizedString("sms_code_unrecognized", comment: ""))
    }

    resetFooterTitle()
  }

  private func notify(body: String?, sound: NSSound? = nil) {
    Notifier.notify(body: body, sound: sound)
  }

  private static func extractCode(from text: String) -> String {
    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return "" }

    if let data = cleaned.data(using: .utf8),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      for key in ["code", "sms_code", "verification_code", "验证码"] {
        if let value = json[key] as? String {
          let code = extractCode(from: value)
          if !code.isEmpty {
            return code
          }
        } else if let value = json[key] as? NSNumber {
          return value.stringValue
        }
      }
    }

    if cleaned.allSatisfy(\.isNumber) {
      return cleaned
    }

    return firstMatch(in: cleaned, pattern: "\\b\\d{4,8}\\b")
      ?? firstMatch(in: cleaned, pattern: "\\d+")
      ?? ""
  }

  private static func firstMatch(in text: String, pattern: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return nil
    }

    let range = NSRange(text.startIndex..., in: text)
    guard let result = regex.firstMatch(in: text, range: range),
          let matchRange = Range(result.range, in: text) else {
      return nil
    }

    return String(text[matchRange])
  }

  @MainActor
  private func resetFooterTitle() {
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(3))
      guard self?.isFetching == false else { return }
      self?.footerItem?.title = "get_verification_code"
    }
  }

  private enum FetchError: Error {
    case cancelled
    case network(String)
    case httpStatus(Int)
    case invalidResponse
    case emptyResponse
    case unrecognized
  }
}

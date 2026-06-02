import Defaults
import KeyboardShortcuts
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
  var panel: FloatingPanel<ContentView>!
  private let notebookUploader = NotebookLMUploaderController()

  @objc
  private lazy var statusItem: NSStatusItem = {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.behavior = .removalAllowed
    statusItem.button?.action = #selector(performStatusItemClick)
    statusItem.button?.image = Defaults[.menuIcon].image
    statusItem.button?.imagePosition = .imageLeft
    statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    statusItem.button?.target = self
    return statusItem
  }()

  private var isStatusItemDisabled: Bool {
    Defaults[.ignoreEvents] || Defaults[.enabledPasteboardTypes].isEmpty
  }

  private var statusItemVisibilityObserver: NSKeyValueObservation?

  func applicationWillFinishLaunching(_ notification: Notification) { // swiftlint:disable:this function_body_length
    // Bridge FloatingPanel via AppDelegate.
    AppState.shared.appDelegate = self
    migrateSyncClipboardCloudDefaults()

    Clipboard.shared.onNewCopy {
      SyncClipboardCloudSync.shared.upload($0)
      History.shared.add($0)
    }
    Clipboard.shared.start()

    Task {
      for await _ in Defaults.updates(.clipboardCheckInterval, initial: false) {
        Clipboard.shared.restart()
      }
    }

    statusItemVisibilityObserver = observe(\.statusItem.isVisible, options: .new) { _, change in
      if let newValue = change.newValue, Defaults[.showInStatusBar] != newValue {
        Defaults[.showInStatusBar] = newValue
      }
    }

    Task {
      for await value in Defaults.updates(.showInStatusBar) {
        statusItem.isVisible = value
      }
    }

    Task {
      for await value in Defaults.updates(.menuIcon, initial: false) {
        statusItem.button?.image = value.image
      }
    }

    synchronizeMenuIconText()
    Task {
      for await value in Defaults.updates(.showRecentCopyInMenuBar) {
        if value {
          statusItem.button?.title = AppState.shared.menuIconText
        } else {
          statusItem.button?.title = ""
        }
      }
    }

    Task {
      for await _ in Defaults.updates(.ignoreEvents) {
        statusItem.button?.appearsDisabled = isStatusItemDisabled
      }
    }

    Task {
      for await _ in Defaults.updates(.enabledPasteboardTypes) {
        statusItem.button?.appearsDisabled = isStatusItemDisabled
      }
    }
  }

  func applicationDidFinishLaunching(_ aNotification: Notification) {
    migrateUserDefaults()
    disableUnusedGlobalHotkeys()
    notebookUploader.prepare()

    panel = FloatingPanel(
      contentRect: NSRect(origin: .zero, size: Defaults[.windowSize]),
      identifier: Bundle.main.bundleIdentifier ?? "org.p0deje.Maccy",
      statusBarButton: statusItem.button,
      onClose: { AppState.shared.popup.reset() }
    ) {
      ContentView()
    }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    panel.toggle(height: AppState.shared.popup.height)
    return true
  }

  func applicationWillTerminate(_ notification: Notification) {
    notebookUploader.stopServer()

    if Defaults[.clearOnQuit] {
      AppState.shared.history.clear()
    }
  }

  private func migrateUserDefaults() {
    if Defaults[.migrations]["2024-07-01-version-2"] != true {
      // Start 2.x from scratch.
      Defaults.reset(.migrations)

      // Inverse hide* configuration keys.
      Defaults[.showFooter] = !UserDefaults.standard.bool(forKey: "hideFooter")
      Defaults[.showSearch] = !UserDefaults.standard.bool(forKey: "hideSearch")
      Defaults[.showTitle] = !UserDefaults.standard.bool(forKey: "hideTitle")
      UserDefaults.standard.removeObject(forKey: "hideFooter")
      UserDefaults.standard.removeObject(forKey: "hideSearch")
      UserDefaults.standard.removeObject(forKey: "hideTitle")

      Defaults[.migrations]["2024-07-01-version-2"] = true
    }

    // The following defaults are not used in Maccy 2.x
    // and should be removed in 3.x.
    // - LaunchAtLogin__hasMigrated
    // - avoidTakingFocus
    // - saratovSeparator
    // - maxMenuItemLength
    // - maxMenuItems
  }

  @objc
  private func performStatusItemClick() {
    if let event = NSApp.currentEvent {
      let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

      if modifierFlags.contains(.option) {
        Defaults[.ignoreEvents].toggle()

        if modifierFlags.contains(.shift) {
          Defaults[.ignoreOnlyNextEvent] = Defaults[.ignoreEvents]
        }

        return
      }
    }

    notebookUploader.showMenu(for: statusItem)
  }

  private func synchronizeMenuIconText() {
    _ = withObservationTracking {
      AppState.shared.menuIconText
    } onChange: {
      DispatchQueue.main.async {
        if Defaults[.showRecentCopyInMenuBar] {
          self.statusItem.button?.title = AppState.shared.menuIconText
        }
        self.synchronizeMenuIconText()
      }
    }
  }

  private func migrateSyncClipboardCloudDefaults() {
    guard let externalDefaults = UserDefaults.standard.persistentDomain(forName: "org.p0deje.Maccy") else {
      return
    }

    if UserDefaults.standard.object(forKey: "syncClipboardCloudEnabled") == nil,
       let enabled = externalDefaults["syncClipboardCloudEnabled"] as? Bool {
      Defaults[.syncClipboardCloudEnabled] = enabled
    }

    if UserDefaults.standard.string(forKey: "syncClipboardCloudURL") == nil,
       let url = externalDefaults["syncClipboardCloudURL"] as? String {
      Defaults[.syncClipboardCloudURL] = url
    }

    if UserDefaults.standard.string(forKey: "syncClipboardCloudUsername") == nil,
       let username = externalDefaults["syncClipboardCloudUsername"] as? String {
      Defaults[.syncClipboardCloudUsername] = username
    }

    if UserDefaults.standard.string(forKey: "syncClipboardCloudPassword") == nil,
       let password = externalDefaults["syncClipboardCloudPassword"] as? String {
      Defaults[.syncClipboardCloudPassword] = password
    }
  }

  private func disableUnusedGlobalHotkeys() {
    let names: [KeyboardShortcuts.Name] = [.delete, .pin]
    KeyboardShortcuts.disable(names)

    NotificationCenter.default.addObserver(
      forName: Notification.Name("KeyboardShortcuts_shortcutByNameDidChange"),
      object: nil,
      queue: nil
    ) { notification in
      if let name = notification.userInfo?["name"] as? KeyboardShortcuts.Name, names.contains(name) {
        KeyboardShortcuts.disable(name)
      }
    }
  }
}

private final class NotebookLMUploaderController: NSObject {
  private let uploadServerScript = URL(
    fileURLWithPath: "/Users/kudo/Desktop/Mixed/paper-download-crx-github/upload-server.py"
  )
  private let uploadDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("paper-upload-work/uploads", isDirectory: true)
  private let notebookCLI = URL(fileURLWithPath: "/opt/homebrew/bin/notebooklm-py")
  private let python = URL(fileURLWithPath: "/Library/Frameworks/Python.framework/Versions/3.14/bin/python3")

  private var serverProcess: Process?
  private var notebooks: [NotebookLMMenuNotebook] = []
  private var isLoadingNotebooks = false
  private var lastError: String?
  private let bingWallpaper = BingWallpaperController()

  private var selectedNotebookID: String {
    get { UserDefaults.standard.string(forKey: DefaultsKey.selectedNotebookID) ?? "" }
    set { UserDefaults.standard.set(newValue, forKey: DefaultsKey.selectedNotebookID) }
  }

  var isServerRunning: Bool {
    serverProcess?.isRunning == true
  }

  func prepare() {
    refreshNotebooks()
    bingWallpaper.updateIfNeeded()
  }

  func stopServer() {
    guard let serverProcess else { return }
    if serverProcess.isRunning {
      serverProcess.terminate()
    }
    self.serverProcess = nil
    updateStatus()
  }

  func showMenu(for statusItem: NSStatusItem) {
    let menu = NSMenu()
    menu.addItem(disabledItem("NotebookLM Uploader"))
    menu.addItem(disabledItem(isServerRunning ? "Running on 127.0.0.1:8766" : "Stopped"))

    if let lastError, !lastError.isEmpty {
      menu.addItem(disabledItem("Error: \(shorten(lastError, limit: 48))"))
    }

    menu.addItem(.separator())
    appendNotebookItems(to: menu)
    menu.addItem(.separator())

    let startStopTitle = isServerRunning ? "Stop Upload Server" : "Start Upload Server"
    let startStop = NSMenuItem(title: startStopTitle, action: #selector(toggleServer), keyEquivalent: "")
    startStop.target = self
    startStop.isEnabled = isServerRunning || !selectedNotebookID.isEmpty
    menu.addItem(startStop)

    let refresh = NSMenuItem(title: "Refresh Notebooks", action: #selector(refreshNotebooksAction), keyEquivalent: "")
    refresh.target = self
    menu.addItem(refresh)

    let dashboard = NSMenuItem(title: "Open Upload Page", action: #selector(openDashboard), keyEquivalent: "")
    dashboard.target = self
    dashboard.isEnabled = isServerRunning
    menu.addItem(dashboard)

    let folder = NSMenuItem(title: "Open Upload Folder", action: #selector(openUploadDirectory), keyEquivalent: "")
    folder.target = self
    menu.addItem(folder)

    menu.addItem(.separator())
    appendWallpaperItems(to: menu)

    menu.addItem(.separator())
    appendMaccyItems(to: menu)

    statusItem.menu = menu
    statusItem.button?.performClick(nil)
    DispatchQueue.main.async { [weak self] in
      statusItem.menu = nil
      self?.updateStatus()
    }
  }

  private func appendMaccyItems(to menu: NSMenu) {
    let clear = NSMenuItem(title: localized("clear"), action: #selector(clearHistory), keyEquivalent: "")
    clear.target = self
    menu.addItem(clear)

    let smsCode = NSMenuItem(title: localized("get_verification_code"), action: #selector(fetchSMSCode), keyEquivalent: "")
    smsCode.target = self
    menu.addItem(smsCode)

    let cling = NSMenuItem(title: "Open Cling", action: #selector(openCling), keyEquivalent: "")
    cling.target = self
    menu.addItem(cling)

    let preferences = NSMenuItem(title: localized("preferences"), action: #selector(openPreferences), keyEquivalent: ",")
    preferences.target = self
    preferences.keyEquivalentModifierMask = [.command]
    menu.addItem(preferences)

    let about = NSMenuItem(title: localized("about"), action: #selector(openAbout), keyEquivalent: "")
    about.target = self
    menu.addItem(about)

    let quit = NSMenuItem(title: localized("quit"), action: #selector(quit), keyEquivalent: "q")
    quit.target = self
    quit.keyEquivalentModifierMask = [.command]
    menu.addItem(quit)
  }

  private func appendWallpaperItems(to menu: NSMenu) {
    menu.addItem(disabledItem("Bing 4K Wallpaper"))

    let update = NSMenuItem(title: "Change Wallpaper Now", action: #selector(changeBingWallpaperNow), keyEquivalent: "")
    update.target = self
    menu.addItem(update)

    let daily = NSMenuItem(title: "Change Daily", action: #selector(toggleBingWallpaperDaily), keyEquivalent: "")
    daily.target = self
    daily.state = bingWallpaper.isDailyEnabled ? .on : .off
    menu.addItem(daily)

    if let status = bingWallpaper.statusText {
      menu.addItem(disabledItem(shorten(status, limit: 48)))
    }
  }

  @objc
  private func changeBingWallpaperNow() {
    bingWallpaper.updateNow()
  }

  @objc
  private func toggleBingWallpaperDaily() {
    bingWallpaper.isDailyEnabled.toggle()
    if bingWallpaper.isDailyEnabled {
      bingWallpaper.updateIfNeeded()
    }
  }

  @objc
  private func clearHistory() {
    Task { @MainActor in
      AppState.shared.history.clear()
    }
  }

  @objc
  private func fetchSMSCode() {
    AppState.shared.smsCodeHelper.fetchCode()
  }

  @objc
  private func openCling() {
    let bundledCling = Bundle.main.url(forResource: "Cling", withExtension: "app")
    let developmentCling = URL(fileURLWithPath: "/Users/kudo/Desktop/Mixed/Cling/dist/Cling.app")

    guard let clingURL = bundledCling ?? (FileManager.default.fileExists(atPath: developmentCling.path) ? developmentCling : nil) else {
      NSAlert(error: NSError(
        domain: "MaccyClingIntegration",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Cling.app was not found in this build."]
      )).runModal()
      return
    }

    NSWorkspace.shared.openApplication(at: clingURL, configuration: NSWorkspace.OpenConfiguration())
  }

  @objc
  private func openPreferences() {
    Task { @MainActor in
      AppState.shared.openPreferences()
    }
  }

  @objc
  private func openAbout() {
    Task { @MainActor in
      AppState.shared.openAbout()
    }
  }

  @objc
  private func quit() {
    Task { @MainActor in
      AppState.shared.quit()
    }
  }

  private func localized(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
  }

  private func appendNotebookItems(to menu: NSMenu) {
    if isLoadingNotebooks {
      menu.addItem(disabledItem("Loading notebooks..."))
      return
    }

    if notebooks.isEmpty {
      menu.addItem(disabledItem("No NotebookLM notebooks found"))
      return
    }

    for notebook in notebooks.prefix(5) {
      let item = NSMenuItem(title: shorten(notebook.displayTitle, limit: 30), action: #selector(selectNotebook(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = notebook.id
      item.state = notebook.id == selectedNotebookID ? .on : .off
      menu.addItem(item)
    }

    if notebooks.count > 5 {
      menu.addItem(disabledItem("Showing latest 5 of \(notebooks.count)"))
    }
  }

  @objc
  private func selectNotebook(_ sender: NSMenuItem) {
    guard let notebookID = sender.representedObject as? String else { return }
    selectedNotebookID = notebookID
    if isServerRunning {
      restartServer()
    }
  }

  @objc
  private func toggleServer() {
    if isServerRunning {
      stopServer()
    } else {
      startServer()
    }
  }

  @objc
  private func refreshNotebooksAction() {
    refreshNotebooks()
  }

  @objc
  private func openDashboard() {
    guard let url = URL(string: "http://127.0.0.1:8766") else { return }
    NSWorkspace.shared.open(url)
  }

  @objc
  private func openUploadDirectory() {
    NSWorkspace.shared.open(uploadDirectory)
  }

  private func startServer() {
    guard !selectedNotebookID.isEmpty else {
      lastError = "Choose a NotebookLM notebook first."
      return
    }

    guard FileManager.default.fileExists(atPath: uploadServerScript.path) else {
      lastError = "Missing upload-server.py"
      return
    }

    do {
      try FileManager.default.createDirectory(at: uploadDirectory, withIntermediateDirectories: true)
      stopServer()

      let process = Process()
      process.executableURL = FileManager.default.fileExists(atPath: python.path)
        ? python
        : URL(fileURLWithPath: "/usr/bin/python3")
      process.arguments = [
        uploadServerScript.path,
        "--notebooklm",
        "--notebooklm-cli",
        FileManager.default.fileExists(atPath: notebookCLI.path) ? notebookCLI.path : "notebooklm-py",
        "--notebook-id",
        selectedNotebookID,
        "--upload-dir",
        uploadDirectory.path
      ]
      process.currentDirectoryURL = uploadServerScript.deletingLastPathComponent()
      process.standardOutput = Pipe()
      process.standardError = Pipe()

      try process.run()
      serverProcess = process
      lastError = nil
      updateStatus()
    } catch {
      lastError = error.localizedDescription
      serverProcess = nil
      updateStatus()
    }
  }

  private func restartServer() {
    stopServer()
    startServer()
  }

  private func refreshNotebooks() {
    isLoadingNotebooks = true
    lastError = nil
    updateStatus()

    DispatchQueue.global(qos: .utility).async { [weak self] in
      guard let self else { return }
      let process = Process()
      process.executableURL = self.notebookCLIExecutable()
      process.arguments = self.notebookCLIArguments(["list", "--json"])

      let output = Pipe()
      process.standardOutput = output
      process.standardError = output

      do {
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus == 0 {
          let response = try JSONDecoder().decode(NotebookLMMenuNotebookList.self, from: data)
          DispatchQueue.main.async {
            self.notebooks = response.notebooks
            if self.selectedNotebookID.isEmpty ||
              !response.notebooks.contains(where: { $0.id == self.selectedNotebookID }) {
              self.selectedNotebookID = response.notebooks.first?.id ?? ""
            }
            self.isLoadingNotebooks = false
            self.lastError = nil
            self.updateStatus()
          }
        } else {
          let message = String(data: data, encoding: .utf8) ?? "NotebookLM command failed"
          DispatchQueue.main.async {
            self.isLoadingNotebooks = false
            self.lastError = message.trimmingCharacters(in: .whitespacesAndNewlines)
            self.updateStatus()
          }
        }
      } catch {
        DispatchQueue.main.async {
          self.isLoadingNotebooks = false
          self.lastError = error.localizedDescription
          self.updateStatus()
        }
      }
    }
  }

  private func notebookCLIExecutable() -> URL {
    if FileManager.default.fileExists(atPath: notebookCLI.path) {
      return notebookCLI
    }
    return URL(fileURLWithPath: "/usr/bin/env")
  }

  private func notebookCLIArguments(_ arguments: [String]) -> [String] {
    if FileManager.default.fileExists(atPath: notebookCLI.path) {
      return arguments
    }
    return ["notebooklm-py"] + arguments
  }

  private func updateStatus() {
  }

  private func disabledItem(_ title: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    return item
  }

  private func shorten(_ text: String, limit: Int) -> String {
    guard text.count > limit else { return text }
    return String(text.prefix(limit - 1)) + "..."
  }

  private enum DefaultsKey {
    static let selectedNotebookID = "selectedNotebookID"
  }
}

private struct NotebookLMMenuNotebook: Codable {
  let id: String
  let title: String
  let createdAt: String?

  var displayTitle: String {
    title.isEmpty ? "Untitled Notebook" : title
  }

  enum CodingKeys: String, CodingKey {
    case id
    case title
    case createdAt = "created_at"
  }
}

private struct NotebookLMMenuNotebookList: Codable {
  let notebooks: [NotebookLMMenuNotebook]
}

private final class BingWallpaperController {
  private let metadataURL = URL(string: "https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=1&mkt=zh-CN")!
  private let wallpaperDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Pictures/Bing4KWallpapers", isDirectory: true)

  private var isUpdating = false
  private(set) var statusText: String?

  var isDailyEnabled: Bool {
    get {
      if UserDefaults.standard.object(forKey: DefaultsKey.dailyEnabled) == nil {
        return true
      }
      return UserDefaults.standard.bool(forKey: DefaultsKey.dailyEnabled)
    }
    set {
      UserDefaults.standard.set(newValue, forKey: DefaultsKey.dailyEnabled)
      statusText = newValue ? "Daily wallpaper enabled" : "Daily wallpaper disabled"
    }
  }

  func updateIfNeeded() {
    guard isDailyEnabled else { return }
    let today = Self.dayStamp()
    guard UserDefaults.standard.string(forKey: DefaultsKey.lastUpdatedDay) != today else { return }
    updateNow(markDaily: true)
  }

  func updateNow(markDaily: Bool = false) {
    guard !isUpdating else { return }
    isUpdating = true
    statusText = "Updating wallpaper..."

    Task.detached(priority: .utility) { [weak self] in
      guard let self else { return }
      do {
        let metadata = try await self.fetchMetadata()
        let imageURL = self.bestImageURL(from: metadata)
        let imageData = try await self.fetchImage(from: imageURL)
        let fileURL = try self.writeImage(imageData, metadata: metadata)
        try await MainActor.run {
          try self.setWallpaper(fileURL)
          UserDefaults.standard.set(Self.dayStamp(), forKey: DefaultsKey.lastUpdatedDay)
          self.statusText = "Wallpaper updated: \(metadata.title)"
          self.isUpdating = false
        }
      } catch {
        await MainActor.run {
          self.statusText = "Wallpaper failed: \(error.localizedDescription)"
          self.isUpdating = false
        }
      }
    }
  }

  private func fetchMetadata() async throws -> BingWallpaperMetadata {
    let (data, response) = try await URLSession.shared.data(from: metadataURL)
    try Self.validate(response)
    let payload = try JSONDecoder().decode(BingWallpaperResponse.self, from: data)
    guard let image = payload.images.first else {
      throw WallpaperError.noImage
    }
    return image
  }

  private func bestImageURL(from metadata: BingWallpaperMetadata) -> URL {
    let baseURL: String
    if metadata.urlbase.hasPrefix("http") {
      baseURL = metadata.urlbase
    } else {
      baseURL = "https://www.bing.com\(metadata.urlbase)"
    }
    return URL(string: "\(baseURL)_UHD.jpg") ?? URL(string: "https://www.bing.com\(metadata.url)")!
  }

  private func fetchImage(from url: URL) async throws -> Data {
    let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
    let (data, response) = try await URLSession.shared.data(for: request)
    try Self.validate(response)
    return data
  }

  private func writeImage(_ data: Data, metadata: BingWallpaperMetadata) throws -> URL {
    try FileManager.default.createDirectory(at: wallpaperDirectory, withIntermediateDirectories: true)
    let name = "\(metadata.startdate)-bing-4k.jpg"
    let fileURL = wallpaperDirectory.appendingPathComponent(name)
    try data.write(to: fileURL, options: .atomic)
    return fileURL
  }

  @MainActor
  private func setWallpaper(_ fileURL: URL) throws {
    for screen in NSScreen.screens {
      try NSWorkspace.shared.setDesktopImageURL(fileURL, for: screen, options: [:])
    }
  }

  private static func validate(_ response: URLResponse) throws {
    guard let response = response as? HTTPURLResponse else {
      throw WallpaperError.invalidResponse
    }
    guard (200...299).contains(response.statusCode) else {
      throw WallpaperError.httpStatus(response.statusCode)
    }
  }

  private static func dayStamp() -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: Date())
  }

  private enum DefaultsKey {
    static let dailyEnabled = "BingWallpaper.dailyEnabled"
    static let lastUpdatedDay = "BingWallpaper.lastUpdatedDay"
  }

  private enum WallpaperError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case noImage

    var errorDescription: String? {
      switch self {
      case .invalidResponse:
        return "Invalid Bing response"
      case .httpStatus(let status):
        return "Bing returned HTTP \(status)"
      case .noImage:
        return "No Bing image found"
      }
    }
  }
}

private struct BingWallpaperResponse: Codable {
  let images: [BingWallpaperMetadata]
}

private struct BingWallpaperMetadata: Codable {
  let startdate: String
  let url: String
  let urlbase: String
  let title: String
}

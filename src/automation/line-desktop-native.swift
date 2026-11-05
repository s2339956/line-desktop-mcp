import AppKit
import ApplicationServices
import CryptoKit
import Darwin
import Foundation
import ImageIO
import ScreenCaptureKit
import Security
import Vision

let bundleIdentifier = "jp.naver.line.mac"
let expectedWindowTitle = "LINE"
let nodeLimit = 2_000
let depthLimit = 12
let textLimit = 4_096
let ocrConfidenceThreshold: Float = 0.95
let ocrRevision = VNRecognizeTextRequestRevision3
let processedOCRPolicyVersion = "whole-roi-2x-v1"
let processedOCRMaxDimension = 8_192
let processedOCRMaxPixels = 32_000_000
let expectedLineExecutablePath = "/Applications/LINE.app/Contents/MacOS/LINE"
let expectedLineTeamIdentifier = "VUTU7AKEUR"
let globalAllNavigationRoute = "line-hid-all-v1"
let systemEventsBundleIdentifier = "com.apple.systemevents"
let expectedWindowServerEntryPath =
    "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer"
let expectedWindowServerSigningIdentifier = "com.apple.WindowServer"
let windowServerProcessPathCapacity = 4_096

struct NativeFailure: Error {
    let code: String
    let message: String
    let details: [String: Any]
    init(_ code: String, _ message: String, _ details: [String: Any] = [:]) {
        self.code = code; self.message = message; self.details = details
    }
}

func forcingPhase(_ failure: NativeFailure, _ phase: String) -> NativeFailure {
    var details = failure.details
    details["phase"] = phase
    return NativeFailure(failure.code, failure.message, details)
}

func phaseAfterMutationAttempt(_ attempted: Bool, nestedPhase: String?) -> String? {
    attempted ? "post_commit" : nestedPhase
}

enum LiveScopeKind { case tab, global }

struct LiveScope {
    let kind: LiveScopeKind
    let tabName: String?
    let chatName: String
    let resultIndex: Int?

    init(tabName: String, chatName: String) {
        kind = .tab; self.tabName = tabName; self.chatName = chatName; resultIndex = nil
    }

    init(globalChatName chatName: String, resultIndex: Int? = nil) {
        kind = .global; tabName = nil; self.chatName = chatName; self.resultIndex = resultIndex
    }
}
struct Request { let name: String; let args: [String: Any]; let liveScope: LiveScope? }

struct WindowIdentity {
    let pid: pid_t
    let windowID: CGWindowID
    let title: String
    let bounds: CGRect
    let executableURL: String
    let signingIdentifier: String?
    let teamIdentifier: String?

    var json: [String: Any] {
        var value: [String: Any] = [
            "pid": Int(pid), "windowId": Int(windowID), "title": title,
            "bounds": ["x": bounds.minX, "y": bounds.minY, "width": bounds.width, "height": bounds.height],
            "bundleIdentifier": bundleIdentifier, "executableURL": executableURL,
        ]
        if let signingIdentifier { value["signingIdentifier"] = signingIdentifier }
        if let teamIdentifier { value["teamIdentifier"] = teamIdentifier }
        return value
    }
}

enum GlobalAllMouseStep: String, CaseIterable { case move, down, up }

struct GlobalAllEventCounts {
    var move = 0
    var down = 0
    var up = 0

    var inputAttempted: Bool { move > 0 || down > 0 || up > 0 }
    var json: [String: Any] { ["move": move, "down": down, "up": up] }

    mutating func record(_ step: GlobalAllMouseStep) {
        switch step {
        case .move: move += 1
        case .down: down += 1
        case .up: up += 1
        }
    }
}

struct GlobalAllMouseEvents {
    let move: CGEvent
    let down: CGEvent
    let up: CGEvent

    func event(_ step: GlobalAllMouseStep) -> CGEvent {
        switch step {
        case .move: return move
        case .down: return down
        case .up: return up
        }
    }
}

struct GlobalAllCoreFailure: Error {
    let cause: Error
    let counts: GlobalAllEventCounts
}

struct NodeRecord {
    let element: AXUIElement
    let parent: Int?
    let role: String
    let subrole: String
    let title: String
    let description: String
    let value: String
    let frame: CGRect?
    let enabled: Bool
    let selected: Bool?
    var texts: [String] {
        var seen = Set<String>()
        return [title, description, value].filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

struct Snapshot { let nodes: [NodeRecord]; let partial: Bool; let reasons: [String] }
enum SnapshotMode { case geometryOnly, structure, text }

struct LineLayout {
    let searchFieldIndex: Int
    let leftListIndex: Int
    let messageListIndex: Int
    let composerIndex: Int
    let tabROI: CGRect
    let headerROI: CGRect
}

struct ReadTabLayout {
    let searchFieldIndex: Int
    let leftListIndex: Int
    let tabROI: CGRect
}

struct OCRCandidate { let text: String; let confidence: Float; let normalizedBox: CGRect }
struct GreenComponent {
    let pixelBox: CGRect
    let pointBox: CGRect
    let pixelCount: Int
    let meanRed: Double
    let meanGreen: Double
    let meanBlue: Double
    let meanAlpha: Double
    var aspect: CGFloat { pointBox.width / pointBox.height }
    var fillRatio: CGFloat { CGFloat(pixelCount) / (pixelBox.width * pixelBox.height) }
}
struct UnderlineComponent {
    let pointBox: CGRect
    let pixelCount: Int
    let meanLuma: Double
    let fillRatio: CGFloat
    var aspect: CGFloat { pointBox.width / pointBox.height }
}
enum ReadColorProfile: String { case light, dark }
enum TabNavigationMode { case legacy, readOnly }
struct CanonicalReadROI { let image: CGImage; let profile: ReadColorProfile }
struct ReadOCRFrame { let frame: OCRFrame; let profile: ReadColorProfile }
struct OCRFrame {
    let identity: WindowIdentity
    let roi: CGRect
    let imageWidth: Int
    let imageHeight: Int
    let candidates: [OCRCandidate]
    let maskedCandidates: [OCRCandidate]
    let processedCandidates: [OCRCandidate]
    let processedPolicyApplied: Bool
    let greenComponents: [GreenComponent]
    let underlineComponents: [UnderlineComponent]
}

struct CaptureGeometry {
    let window: CGRect
    let roi: CGRect
    let imageWidth: Int
    let imageHeight: Int
    var scaleX: CGFloat { CGFloat(imageWidth) / window.width }
    var scaleY: CGFloat { CGFloat(imageHeight) / window.height }

    func validate() throws {
        guard window.width.isFinite, window.height.isFinite, window.width > 0, window.height > 0,
              roi.width.isFinite, roi.height.isFinite, roi.width > 0, roi.height > 0,
              imageWidth > 0, imageHeight > 0,
              scaleX.isFinite, scaleY.isFinite, scaleX >= 0.5, scaleY >= 0.5,
              scaleX <= 4, scaleY <= 4, abs(scaleX - scaleY) <= 0.05,
              window.contains(roi) else {
            throw NativeFailure("CAPTURE_GEOMETRY_INVALID", "擷取影像與 LINE 視窗幾何不一致")
        }
    }

    func roiPixels() throws -> CGRect {
        try validate()
        let raw = CGRect(x: (roi.minX - window.minX) * scaleX,
                         y: (roi.minY - window.minY) * scaleY,
                         width: roi.width * scaleX, height: roi.height * scaleY)
        let pixels = CGRect(x: floor(raw.minX), y: floor(raw.minY),
                            width: ceil(raw.maxX) - floor(raw.minX),
                            height: ceil(raw.maxY) - floor(raw.minY))
        let image = CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
        guard image.contains(pixels), pixels.width >= 1, pixels.height >= 1 else {
            throw NativeFailure("CAPTURE_GEOMETRY_INVALID", "OCR ROI 超出視窗影像")
        }
        return pixels
    }

    func screenRect(for candidate: OCRCandidate) throws -> CGRect {
        let pixels = try roiPixels()
        let box = candidate.normalizedBox
        guard box.minX.isFinite, box.minY.isFinite, box.width.isFinite, box.height.isFinite,
              box.minX >= 0, box.minY >= 0, box.maxX <= 1, box.maxY <= 1,
              box.width > 0, box.height > 0 else {
            throw NativeFailure("OCR_GEOMETRY_INVALID", "OCR 候選框格式不正確")
        }
        // Vision y 軸由下往上；CGWindow 與事件座標由畫面上往下。
        let pixelRect = CGRect(x: pixels.minX + box.minX * pixels.width,
                               y: pixels.minY + (1 - box.maxY) * pixels.height,
                               width: box.width * pixels.width, height: box.height * pixels.height)
        let result = CGRect(x: window.minX + pixelRect.minX / scaleX,
                            y: window.minY + pixelRect.minY / scaleY,
                            width: pixelRect.width / scaleX, height: pixelRect.height / scaleY)
        guard roi.contains(result), window.contains(result) else {
            throw NativeFailure("OCR_GEOMETRY_INVALID", "OCR 候選框 round-trip 超出安全範圍")
        }
        return result
    }
}

final class AsyncBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    func set(_ newValue: Value) { lock.lock(); value = newValue; lock.unlock() }
    func get() -> Value? { lock.lock(); defer { lock.unlock() }; return value }
}

func copyAttribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value as AnyObject?
}

func stringAttribute(_ element: AXUIElement, _ name: String) -> String {
    guard let value = copyAttribute(element, name) else { return "" }
    if let string = value as? String { return String(string.prefix(textLimit)) }
    if let number = value as? NSNumber { return number.stringValue }
    return ""
}

func boolAttribute(_ element: AXUIElement, _ name: String, default fallback: Bool = false) -> Bool {
    (copyAttribute(element, name) as? NSNumber)?.boolValue ?? fallback
}

func pointAttribute(_ element: AXUIElement, _ name: String) -> CGPoint? {
    guard let raw = copyAttribute(element, name), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    let value = raw as! AXValue
    var point = CGPoint.zero
    return AXValueGetValue(value, .cgPoint, &point) ? point : nil
}

func sizeAttribute(_ element: AXUIElement, _ name: String) -> CGSize? {
    guard let raw = copyAttribute(element, name), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    let value = raw as! AXValue
    var size = CGSize.zero
    return AXValueGetValue(value, .cgSize, &size) ? size : nil
}

func frameAttribute(_ element: AXUIElement) -> CGRect? {
    guard let point = pointAttribute(element, kAXPositionAttribute),
          let size = sizeAttribute(element, kAXSizeAttribute) else { return nil }
    return CGRect(origin: point, size: size)
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    copyAttribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
}

func actions(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
    return names as? [String] ?? []
}

func attributeNames(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyAttributeNames(element, &names) == .success else { return [] }
    return names as? [String] ?? []
}

// Qt 可能把 AXValue 同時用於文字與狀態；型別不明時不得猜測 selected。
func strictAXBoolean(_ raw: AnyObject?) -> Bool? {
    guard let raw else { return nil }
    if CFGetTypeID(raw) == CFBooleanGetTypeID() {
        return (raw as! CFBoolean) == kCFBooleanTrue
    }
    guard let number = raw as? NSNumber,
          number.doubleValue.isFinite,
          number.doubleValue == 0 || number.doubleValue == 1 else { return nil }
    return number.doubleValue == 1
}

func boundedAXString(_ raw: AnyObject?, maximum: Int = 200) -> String? {
    guard let value = raw as? String, !value.isEmpty, value.count <= maximum,
          !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          value.range(of: #"\p{Cc}|[\u{202A}-\u{202E}\u{2066}-\u{2069}]"#,
                      options: .regularExpression) == nil else { return nil }
    return value
}

func strictAXSemanticName(title: AnyObject?, value: AnyObject?) -> String? {
    let titleName: String?
    if let title {
        guard let safe = boundedAXString(title) else { return nil }
        titleName = safe
    } else { titleName = nil }
    let valueName: String?
    if let value {
        if value is String {
            guard let safe = boundedAXString(value) else { return nil }
            valueName = safe
        } else {
            // 數值 AXValue 只可作已驗證狀態；其它型別或非 0/1 數值直接拒絕。
            guard strictAXBoolean(value) != nil else { return nil }
            valueName = nil
        }
    } else { valueName = nil }
    if let titleName, let valueName { return titleName == valueName ? titleName : nil }
    return titleName ?? valueName
}

func strictAXSemanticState(selected: AnyObject?, value: AnyObject?) -> Bool? {
    if let selected {
        guard let selectedState = strictAXBoolean(selected) else { return nil }
        guard let value else { return selectedState }
        if value is String {
            // 合法字串 AXValue 是名稱，不可再轉成 state；不合法字串仍 fail closed。
            return boundedAXString(value) == nil ? nil : selectedState
        }
        guard let valueState = strictAXBoolean(value), valueState == selectedState else { return nil }
        return selectedState
    }
    guard let value, !(value is String) else { return nil }
    return strictAXBoolean(value)
}

func perform(_ action: String, on element: AXUIElement) throws {
    let error = AXUIElementPerformAction(element, action as CFString)
    guard error == .success else {
        throw NativeFailure("AX_ACTION_FAILED", "AX 動作失敗", ["action": action, "axError": error.rawValue])
    }
}

func snapshot(_ root: AXUIElement, mode: SnapshotMode = .text, deadline: TimeInterval = 1.5) -> Snapshot {
    let expires = Date().timeIntervalSince1970 + deadline
    var records: [NodeRecord] = []
    var partial = false
    var reasons: [String] = []
    func stop(_ reason: String) { partial = true; if !reasons.contains(reason) { reasons.append(reason) } }
    func visit(_ element: AXUIElement, parent: Int?, depth: Int) {
        if records.count >= nodeLimit { stop("NODE_LIMIT"); return }
        if depth > depthLimit { stop("DEPTH_LIMIT"); return }
        if Date().timeIntervalSince1970 > expires { stop("TIME_LIMIT"); return }
        let index = records.count
        let role = stringAttribute(element, kAXRoleAttribute)
        records.append(NodeRecord(element: element, parent: parent,
                                  role: role,
                                  subrole: stringAttribute(element, kAXSubroleAttribute),
                                  title: mode == .text ? stringAttribute(element, kAXTitleAttribute) : "",
                                  description: mode == .text ? stringAttribute(element, kAXDescriptionAttribute) : "",
                                  value: mode == .text ? stringAttribute(element, kAXValueAttribute) : "",
                                  frame: frameAttribute(element),
                                  enabled: boolAttribute(element, kAXEnabledAttribute, default: true),
                                  selected: (copyAttribute(element, kAXSelectedAttribute) as? NSNumber)?.boolValue))
        // 幾何校正不需要清單內容；structure 則只走角色與 frame，不讀文字。
        if mode == .geometryOnly && role == "AXList" { return }
        for child in children(element) { visit(child, parent: index, depth: depth + 1) }
    }
    visit(root, parent: nil, depth: 0)
    return Snapshot(nodes: records, partial: partial, reasons: reasons)
}

func isDescendant(_ index: Int, of ancestor: Int, in nodes: [NodeRecord]) -> Bool {
    var parent = nodes[index].parent
    while let current = parent {
        if current == ancestor { return true }
        parent = nodes[current].parent
    }
    return false
}

func descendantIndices(of parent: Int, in nodes: [NodeRecord]) -> [Int] {
    nodes.indices.filter { isDescendant($0, of: parent, in: nodes) }
}

func exactText(_ node: NodeRecord, _ expected: String) -> Bool { node.texts.contains(expected) }

func sha256(_ value: Any) -> String {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func signingInfo(_ url: URL) -> (String?, String?) {
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return (nil, nil) }
    var raw: CFDictionary?
    guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &raw) == errSecSuccess,
          let info = raw as? [String: Any] else { return (nil, nil) }
    return (info[kSecCodeInfoIdentifier as String] as? String,
            info[kSecCodeInfoTeamIdentifier as String] as? String)
}

func strictLineSigningInfo(_ url: URL) throws -> (String, String) {
    guard url.standardizedFileURL.path == expectedLineExecutablePath else {
        throw NativeFailure("LINE_IDENTITY_MISMATCH", "LINE 執行檔路徑不符")
    }
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
          SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else {
        throw NativeFailure("LINE_CODE_INVALID", "LINE 嚴格程式碼簽章驗證失敗")
    }
    var raw: CFDictionary?
    guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &raw) == errSecSuccess,
          let info = raw as? [String: Any],
          let identifier = info[kSecCodeInfoIdentifier as String] as? String,
          let team = info[kSecCodeInfoTeamIdentifier as String] as? String,
          strictLineIdentityFields(executablePath: url.standardizedFileURL.path,
                                   identifier: identifier, team: team, codeValid: true) else {
        throw NativeFailure("LINE_IDENTITY_MISMATCH", "LINE 簽章 identifier 或 team 不符")
    }
    return (identifier, team)
}

func strictLineIdentityFields(executablePath: String, identifier: String?,
                              team: String?, codeValid: Bool) -> Bool {
    codeValid && executablePath == expectedLineExecutablePath &&
        identifier == bundleIdentifier && team == expectedLineTeamIdentifier
}

func canonicalExpectedWindowServerPath() -> String? {
    let url = URL(fileURLWithPath: expectedWindowServerEntryPath)
        .resolvingSymlinksInPath().standardizedFileURL
    let path = url.path
    return url.isFileURL && path.hasPrefix("/") && path != "/" && !path.isEmpty ? path : nil
}

func validatedProcessPathBytes(_ buffer: [CChar], count: Int) -> String? {
    guard count > 0, count < buffer.count, buffer[count] == 0,
          !buffer[..<count].contains(0) else { return nil }
    let data = Data(buffer[..<count].map { UInt8(bitPattern: $0) })
    guard let path = String(data: data, encoding: .utf8), !path.isEmpty,
          path.utf8.count == count else { return nil }
    return path
}

func rawProcessPath(_ pid: pid_t) -> String? {
    let capacity = windowServerProcessPathCapacity
    guard capacity > 1 else { return nil }
    var buffer = [CChar](repeating: 0, count: capacity)
    let rawCount = buffer.withUnsafeMutableBytes {
        proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
    }
    let count = Int(rawCount)
    return validatedProcessPathBytes(buffer, count: count)
}

func strictWindowServerSigningIdentity(_ url: URL) -> (valid: Bool, identifier: String?) {
    var code: SecStaticCode?, requirement: SecRequirement?
    let expression = "anchor apple and identifier \"com.apple.WindowServer\"" as CFString
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
          let code,
          SecRequirementCreateWithString(expression, [], &requirement) == errSecSuccess,
          let requirement,
          SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate),
                                     requirement) == errSecSuccess else { return (false, nil) }
    var raw: CFDictionary?
    guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation),
                                        &raw) == errSecSuccess,
          let info = raw as? [String: Any] else { return (false, nil) }
    return (true, info[kSecCodeInfoIdentifier as String] as? String)
}

func trustedCursorSurfaceFields(layer: Int, cursorLayer: Int,
                                firstPath: String?, secondPath: String?,
                                expectedPath: String?, codeValid: Bool,
                                signingIdentifier: String?) -> Bool {
    layer == cursorLayer && expectedPath != nil && firstPath == expectedPath &&
        secondPath == firstPath && codeValid &&
        signingIdentifier == expectedWindowServerSigningIdentifier
}

func trustedWindowServerCursorPID(_ pid: pid_t, layer: Int, cursorLayer: Int) -> Bool {
    guard layer == cursorLayer,
          let expectedPath = canonicalExpectedWindowServerPath(),
          let firstPath = rawProcessPath(pid), firstPath == expectedPath else { return false }
    let expectedURL = URL(fileURLWithPath: expectedPath)
    let signing = strictWindowServerSigningIdentity(expectedURL)
    let secondPath = rawProcessPath(pid)
    return trustedCursorSurfaceFields(layer: layer, cursorLayer: cursorLayer,
                                      firstPath: firstPath, secondPath: secondPath,
                                      expectedPath: expectedPath, codeValid: signing.valid,
                                      signingIdentifier: signing.identifier)
}

func lineApplication() throws -> NSRunningApplication {
    let matches = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        .filter { !$0.isTerminated && $0.executableURL != nil }
    guard matches.count == 1, let app = matches.first else {
        throw NativeFailure(matches.isEmpty ? "LINE_NOT_RUNNING" : "LINE_PROCESS_AMBIGUOUS",
                            matches.isEmpty ? "LINE 未執行" : "偵測到多個 LINE 主程序", ["count": matches.count])
    }
    let signing = signingInfo(app.executableURL!)
    if let identifier = signing.0, identifier != bundleIdentifier {
        throw NativeFailure("LINE_IDENTITY_MISMATCH", "LINE 程式簽章識別不符")
    }
    return app
}

func cgWindows(pid: pid_t) -> [[String: Any]] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    return (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []).filter {
        ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid &&
        ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 &&
        (($0[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0) > 0
    }
}

func allCGWindows(pid: pid_t) -> [[String: Any]] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    return (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []).filter {
        ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid &&
        (($0[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0) > 0
    }
}

func rect(from dictionary: [String: Any]) -> CGRect? {
    guard let x = dictionary["X"] as? NSNumber, let y = dictionary["Y"] as? NSNumber,
          let width = dictionary["Width"] as? NSNumber, let height = dictionary["Height"] as? NSNumber else { return nil }
    return CGRect(x: x.doubleValue, y: y.doubleValue, width: width.doubleValue, height: height.doubleValue)
}

func similar(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 3) -> Bool {
    abs(lhs.minX - rhs.minX) <= tolerance && abs(lhs.minY - rhs.minY) <= tolerance &&
    abs(lhs.width - rhs.width) <= tolerance && abs(lhs.height - rhs.height) <= tolerance
}

func sameWindow(_ lhs: WindowIdentity, _ rhs: WindowIdentity) -> Bool {
    lhs.pid == rhs.pid && lhs.windowID == rhs.windowID && lhs.title == rhs.title &&
    lhs.executableURL == rhs.executableURL && lhs.signingIdentifier == rhs.signingIdentifier &&
    lhs.teamIdentifier == rhs.teamIdentifier && similar(lhs.bounds, rhs.bounds, tolerance: 0.5)
}

func containsWithTolerance(_ container: CGRect, _ child: CGRect, tolerance: CGFloat = 3) -> Bool {
    container.insetBy(dx: -tolerance, dy: -tolerance).contains(child)
}

func mainWindow(requireForeground: Bool) throws -> (NSRunningApplication, AXUIElement, AXUIElement, WindowIdentity) {
    guard AXIsProcessTrusted() else { throw NativeFailure("ACCESSIBILITY_DENIED", "尚未授予輔助使用權限") }
    let app = try lineApplication()
    if requireForeground && NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
        throw NativeFailure("FOREGROUND_REQUIRED", "LINE 必須位於前景")
    }
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    let allAXWindows = copyAttribute(appElement, kAXWindowsAttribute) as? [AXUIElement] ?? []
    let visibleCGWindows = allCGWindows(pid: app.processIdentifier)
    let modal = allAXWindows.contains { window in
        let frame = frameAttribute(window) ?? .zero
        guard frame.width > 20 && frame.height > 20 else { return false }
        if boolAttribute(window, kAXModalAttribute) || stringAttribute(window, kAXRoleAttribute) == kAXSheetRole {
            return true
        }
        guard stringAttribute(window, kAXSubroleAttribute) == kAXDialogSubrole else { return false }
        // Qt 會保留已隱藏 popup 的 stale AXDialog；只有 on-screen CGWindow 匹配才算可見阻擋。
        return visibleCGWindows.contains { cgWindow in
            guard let raw = cgWindow[kCGWindowBounds as String] as? [String: Any],
                  let cgFrame = rect(from: raw) else { return false }
            return similar(frame, cgFrame, tolerance: 1)
        }
    }
    guard !modal else { throw NativeFailure("MODAL_PRESENT", "LINE 有 modal/sheet，停止操作") }
    let axWindows = allAXWindows.filter { window in
        guard stringAttribute(window, kAXRoleAttribute) == kAXWindowRole,
              stringAttribute(window, kAXSubroleAttribute) == kAXStandardWindowSubrole,
              stringAttribute(window, kAXTitleAttribute) == expectedWindowTitle,
              !boolAttribute(window, kAXMinimizedAttribute), let frame = frameAttribute(window) else { return false }
        return frame.width >= 320 && frame.height >= 240
    }
    let windows = cgWindows(pid: app.processIdentifier)
    var matches: [(AXUIElement, [String: Any], CGRect)] = []
    for axWindow in axWindows {
        guard let axFrame = frameAttribute(axWindow) else { continue }
        for cgWindow in windows {
            guard cgWindow[kCGWindowName as String] as? String == expectedWindowTitle,
                  let raw = cgWindow[kCGWindowBounds as String] as? [String: Any],
                  let cgFrame = rect(from: raw), similar(axFrame, cgFrame) else { continue }
            matches.append((axWindow, cgWindow, cgFrame))
        }
    }
    guard matches.count == 1, let match = matches.first,
          let rawID = match.1[kCGWindowNumber as String] as? NSNumber, rawID.uint32Value != 0 else {
        throw NativeFailure(matches.isEmpty ? "MAIN_WINDOW_NOT_FOUND" : "MAIN_WINDOW_AMBIGUOUS",
                            matches.isEmpty ? "找不到唯一 LINE 主視窗" : "偵測到多個 LINE 主視窗",
                            ["count": matches.count])
    }
    let executable = app.executableURL!.standardizedFileURL.path
    let signing = signingInfo(app.executableURL!)
    let identity = WindowIdentity(pid: app.processIdentifier, windowID: rawID.uint32Value,
                                  title: expectedWindowTitle, bounds: match.2,
                                  executableURL: executable, signingIdentifier: signing.0,
                                  teamIdentifier: signing.1)
    return (app, appElement, match.0, identity)
}

// 唯讀名稱探針可在尚未選取聊天室時定位分頁列，但所有幾何仍須唯一且完整。
func readTabLayout(_ tree: Snapshot, window: WindowIdentity) throws -> ReadTabLayout {
    guard !tree.partial else {
        throw NativeFailure("SEMANTIC_PARTIAL", "AX 快照不完整，拒絕唯讀分頁定位")
    }
    let nodes = tree.nodes
    let leftLists = nodes.indices.filter { index in
        guard nodes[index].role == kAXListRole, let frame = nodes[index].frame else { return false }
        return frame.width > 0 && frame.height >= window.bounds.height * 0.3 &&
            window.bounds.contains(frame) && frame.minX < window.bounds.midX &&
            frame.maxX <= window.bounds.midX + 4
    }
    guard leftLists.count == 1, let left = leftLists.first,
          let leftFrame = nodes[left].frame else {
        throw NativeFailure("SEMANTIC_UNRELIABLE", "無法唯一辨識唯讀左側聊天室 AXList",
                            ["count": leftLists.count])
    }
    let searches = nodes.indices.filter { index in
        guard nodes[index].role == kAXTextFieldRole, let frame = nodes[index].frame else { return false }
        return frame.width > 0 && frame.height >= 18 && frame.height <= 64 &&
            window.bounds.contains(frame) && frame.minX >= leftFrame.minX - 4 &&
            frame.maxX <= leftFrame.maxX + 4 && frame.maxY <= leftFrame.minY + 4
    }
    guard searches.count == 1, let search = searches.first,
          let searchFrame = nodes[search].frame else {
        throw NativeFailure("SEMANTIC_UNRELIABLE", "無法唯一辨識唯讀左側搜尋欄",
                            ["count": searches.count])
    }
    let commonRoots = nodes.indices.filter { index in
        guard nodes[index].role == kAXSplitGroupRole, let frame = nodes[index].frame else { return false }
        return window.bounds.contains(frame) && isDescendant(search, of: index, in: nodes) &&
            isDescendant(left, of: index, in: nodes) && containsWithTolerance(frame, searchFrame) &&
            containsWithTolerance(frame, leftFrame)
    }
    let minimalRoots = commonRoots.filter { candidate in
        !commonRoots.contains { other in
            other != candidate && isDescendant(other, of: candidate, in: nodes)
        }
    }
    guard minimalRoots.count == 1, let root = minimalRoots.first,
          let rootFrame = nodes[root].frame,
          rootFrame.minX < window.bounds.midX, rootFrame.maxX > window.bounds.midX else {
        throw NativeFailure("SEMANTIC_UNRELIABLE", "無法辨識跨越主窗中線的唯讀 split group",
                            ["count": minimalRoots.count])
    }
    let chrome = nodes.compactMap { node -> (String, CGFloat)? in
        guard node.role == kAXButtonRole, let frame = node.frame,
              frame.width > 0, frame.height > 0, frame.width <= 30, frame.height <= 30,
              window.bounds.contains(frame), frame.maxY <= rootFrame.minY else { return nil }
        let subrole = node.subrole.lowercased()
        let kind: String
        if subrole.contains("close") { kind = "close" }
        else if subrole.contains("minimize") { kind = "minimize" }
        else if subrole.contains("fullscreen") || subrole.contains("zoom") { kind = "zoom" }
        else { return nil }
        return (kind, frame.midY)
    }
    guard chrome.count == 3, Set(chrome.map(\.0)).count == 3,
          let chromeMidY = chrome.map(\.1).min() else {
        throw NativeFailure("SEMANTIC_UNRELIABLE", "無法由三個唯一視窗 chrome 按鈕校正唯讀分頁帶")
    }
    let tabBottom = min(searchFrame.minY, rootFrame.minY)
    let tabTop = max(window.bounds.minY, chromeMidY)
    let tabROI = CGRect(x: rootFrame.minX, y: tabTop,
                        width: rootFrame.width, height: tabBottom - tabTop)
    let maximumHeight = min(CGFloat(80), window.bounds.height * 0.15)
    guard tabROI.width > 0, tabROI.height >= 12, tabROI.height <= maximumHeight,
          tabROI.maxY <= min(searchFrame.minY, leftFrame.minY),
          window.bounds.contains(tabROI) else {
        throw NativeFailure("SEMANTIC_UNRELIABLE", "AX 結構推導的唯讀分頁 ROI 不合理")
    }
    return ReadTabLayout(searchFieldIndex: search, leftListIndex: left, tabROI: tabROI)
}

struct AXTabSemanticItem {
    let element: AXUIElement
    let role: String
    let name: String
    let identifier: String?
    let selected: Bool
    let enabled: Bool
    let frame: CGRect
}

struct AXTabSemanticReceipt {
    let group: AXUIElement
    let items: [AXTabSemanticItem]
    let identity: WindowIdentity
    let layout: ReadTabLayout
}

enum AXTabSemanticAvailability {
    case unavailable
    case verified(AXTabSemanticReceipt)
}

// 真實 LINE 的水平溢出 AXTabs 全量語意尚未校準；校準前不得以 AX 子集合解鎖操作。
let axTabOverflowCalibrationVerified = false

func metadataSnapshot(_ root: AXUIElement, maximumNodes: Int = 256,
                      maximumDepth: Int = 12) -> Snapshot {
    var records: [NodeRecord] = []
    var partial = false
    var reasons: [String] = []
    func stop(_ reason: String) {
        partial = true
        if !reasons.contains(reason) { reasons.append(reason) }
    }
    func visit(_ element: AXUIElement, parent: Int?, depth: Int) {
        if records.count >= maximumNodes { stop("NODE_LIMIT"); return }
        if depth > maximumDepth { stop("DEPTH_LIMIT"); return }
        let role = stringAttribute(element, kAXRoleAttribute)
        let index = records.count
        records.append(NodeRecord(element: element, parent: parent, role: role,
                                  subrole: stringAttribute(element, kAXSubroleAttribute),
                                  title: "", description: "", value: "",
                                  frame: frameAttribute(element),
                                  enabled: boolAttribute(element, kAXEnabledAttribute, default: true),
                                  selected: nil))
        // 能力探針不走聊天列、訊息列或輸入區，避免讀取任何 body 內容。
        if role == kAXListRole || role == kAXTextAreaRole { return }
        for child in children(element) { visit(child, parent: index, depth: depth + 1) }
    }
    visit(root, parent: nil, depth: 0)
    return Snapshot(nodes: records, partial: partial, reasons: reasons)
}

func strictAXTabs(_ group: AXUIElement, tabROI: CGRect,
                  window: WindowIdentity) -> [AXTabSemanticItem]? {
    var advertised: CFIndex = 0
    guard AXUIElementGetAttributeValueCount(group, kAXTabsAttribute as CFString,
                                            &advertised) == .success,
          advertised > 0, advertised <= 100 else { return nil }
    var rawTabs: CFArray?
    guard AXUIElementCopyAttributeValues(group, kAXTabsAttribute as CFString, 0,
                                         advertised, &rawTabs) == .success,
          let tabs = rawTabs as? [AXUIElement], tabs.count == advertised else { return nil }
    var items = [AXTabSemanticItem]()
    for (position, tab) in tabs.enumerated() {
        guard !tabs[..<position].contains(where: { CFEqual($0, tab) }) else { return nil }
        let role = stringAttribute(tab, kAXRoleAttribute)
        guard role == kAXRadioButtonRole || role == "AXTab",
              let name = strictAXSemanticName(
                  title: copyAttribute(tab, kAXTitleAttribute),
                  value: copyAttribute(tab, kAXValueAttribute)
              ),
              let selected = strictAXSemanticState(
                  selected: copyAttribute(tab, kAXSelectedAttribute),
                  value: copyAttribute(tab, kAXValueAttribute)
              ),
              let frame = frameAttribute(tab),
              containsWithTolerance(tabROI, frame, tolerance: 1),
              window.bounds.contains(frame) else { return nil }
        let identifier = boundedAXString(copyAttribute(tab, kAXIdentifierAttribute), maximum: 256)
        items.append(AXTabSemanticItem(
            element: tab, role: role, name: name, identifier: identifier, selected: selected,
            enabled: boolAttribute(tab, kAXEnabledAttribute, default: false), frame: frame
        ))
    }
    guard Set(items.map(\.name)).count == items.count,
          items.filter(\.selected).count == 1 else { return nil }
    return items
}

func stableAXTabItems(_ first: [AXTabSemanticItem],
                      _ second: [AXTabSemanticItem]) -> Bool {
    first.count == second.count && zip(first, second).allSatisfy {
        CFEqual($0.element, $1.element) && $0.role == $1.role && $0.name == $1.name &&
            $0.identifier == $1.identifier && $0.selected == $1.selected &&
            $0.enabled == $1.enabled && similar($0.frame, $1.frame, tolerance: 0.5)
    }
}

func readAXTabSemanticReceipt() throws -> AXTabSemanticAvailability {
    guard axTabOverflowCalibrationVerified else { return .unavailable }
    let (_, _, firstWindow, firstIdentity) = try mainWindow(requireForeground: true)
    let firstTree = metadataSnapshot(firstWindow)
    let firstLayout = try readTabLayout(firstTree, window: firstIdentity)
    let firstGroups = firstTree.nodes.filter { node in
        guard node.role == kAXTabGroupRole, let frame = node.frame else { return false }
        return containsWithTolerance(firstLayout.tabROI, frame, tolerance: 1)
    }
    guard firstGroups.count == 1, let firstGroup = firstGroups.first,
          let firstItems = strictAXTabs(firstGroup.element, tabROI: firstLayout.tabROI,
                                        window: firstIdentity) else {
        throw NativeFailure("AX_TAB_SEMANTICS_UNRELIABLE", "AX 分頁語意不完整或不唯一")
    }
    let (_, _, secondWindow, secondIdentity) = try mainWindow(requireForeground: true)
    guard sameWindow(firstIdentity, secondIdentity) else {
        throw NativeFailure("WINDOW_CHANGED", "AX 分頁語意二讀期間主窗漂移")
    }
    let secondTree = metadataSnapshot(secondWindow)
    let secondLayout = try readTabLayout(secondTree, window: secondIdentity)
    let secondGroups = secondTree.nodes.filter { node in
        guard node.role == kAXTabGroupRole, let frame = node.frame else { return false }
        return containsWithTolerance(secondLayout.tabROI, frame, tolerance: 1)
    }
    guard secondGroups.count == 1, let secondGroup = secondGroups.first,
          CFEqual(firstGroup.element, secondGroup.element),
          let secondItems = strictAXTabs(secondGroup.element, tabROI: secondLayout.tabROI,
                                         window: secondIdentity),
          stableAXTabItems(firstItems, secondItems) else {
        throw NativeFailure("AX_TAB_SEMANTICS_UNRELIABLE", "AX 分頁語意二讀漂移")
    }
    return .verified(AXTabSemanticReceipt(group: secondGroup.element, items: secondItems,
                                          identity: secondIdentity, layout: secondLayout))
}

func axTabRouteAvailable(calibrated: Bool, complete: Bool) -> Bool {
    calibrated && complete
}

func axListTabsIfVerified(liveScope: LiveScope?) throws -> [String: Any]? {
    switch try readAXTabSemanticReceipt() {
    case .unavailable: return nil
    case let .verified(receipt):
        guard axTabRouteAvailable(calibrated: axTabOverflowCalibrationVerified,
                                  complete: !receipt.items.isEmpty) else { return nil }
        var result: [String: Any] = [
            "tabs": receipt.items.map(\.name),
            "observedAt": ISO8601DateFormatter().string(from: Date()),
            "partial": false, "complete": true, "reasons": [], "pagesScanned": 1,
            "selectedTab": receipt.items.first(where: \.selected)!.name,
            "source": "AX_TABS", "mainWindow": receipt.identity.json,
        ]
        if let liveScope, let tabName = liveScope.tabName {
            result["scopeTarget"] = ["exactText": tabName,
                                     "exactCandidateCount": receipt.items.filter {
                                         $0.name == tabName
                                     }.count]
        }
        return result
    }
}

func lineLayout(_ tree: Snapshot, window: WindowIdentity) throws -> LineLayout {
    let nodes = tree.nodes
    let composers = nodes.indices.filter { i in
        guard nodes[i].role == "AXTextArea", let f = nodes[i].frame else { return false }
        return window.bounds.contains(f) && f.midX > window.bounds.midX && f.minY > window.bounds.midY
    }
    guard composers.count == 1, let composer = composers.first, let composerFrame = nodes[composer].frame else {
        throw NativeFailure("SEMANTIC_UNRELIABLE", "無法唯一辨識訊息輸入區", ["count": composers.count])
    }
    let messages = nodes.indices.filter { i in
        guard nodes[i].role == "AXList", let f = nodes[i].frame else { return false }
        return window.bounds.contains(f) && f.midX > window.bounds.midX && f.minY < composerFrame.minY &&
            f.height >= window.bounds.height * 0.3 && abs(f.midX - composerFrame.midX) < 40
    }
    guard messages.count == 1, let message = messages.first, let messageFrame = nodes[message].frame else {
        throw NativeFailure("SEMANTIC_UNRELIABLE", "無法唯一辨識右側訊息 AXList", ["count": messages.count])
    }
    let leftLists = nodes.indices.filter { i in
        guard nodes[i].role == "AXList", let f = nodes[i].frame else { return false }
        return window.bounds.contains(f) && f.maxX <= messageFrame.minX + 4 && f.minX < window.bounds.midX &&
            f.height >= window.bounds.height * 0.3
    }
    guard leftLists.count == 1, let left = leftLists.first, let leftFrame = nodes[left].frame else {
        throw NativeFailure("SEMANTIC_UNRELIABLE", "無法唯一辨識左側聊天室 AXList", ["count": leftLists.count])
    }
    let searches = nodes.indices.filter { i in
        guard nodes[i].role == "AXTextField", let f = nodes[i].frame else { return false }
        return window.bounds.contains(f) && f.minX >= leftFrame.minX - 4 && f.maxX <= leftFrame.maxX + 4 &&
            f.maxY <= leftFrame.minY + 4 && f.height >= 18 && f.height <= 64
    }
    guard searches.count == 1, let search = searches.first, let searchFrame = nodes[search].frame else {
        throw NativeFailure("SEMANTIC_UNRELIABLE", "無法唯一辨識左側搜尋欄", ["count": searches.count])
    }
    let roots = nodes.indices.filter { i in
        guard nodes[i].role == "AXSplitGroup", let f = nodes[i].frame else { return false }
        return isDescendant(search, of: i, in: nodes) && isDescendant(left, of: i, in: nodes) &&
            isDescendant(message, of: i, in: nodes) && isDescendant(composer, of: i, in: nodes) &&
            containsWithTolerance(f, searchFrame) && containsWithTolerance(f, leftFrame) &&
            containsWithTolerance(f, messageFrame) && containsWithTolerance(f, composerFrame)
    }.sorted { (nodes[$0].frame?.width ?? .greatestFiniteMagnitude) < (nodes[$1].frame?.width ?? .greatestFiniteMagnitude) }
    guard let root = roots.first, let rootFrame = nodes[root].frame else {
        throw NativeFailure("SEMANTIC_UNRELIABLE", "無法辨識 LINE 主要 split group")
    }
    let rights = nodes.indices.filter { i in
        guard i != root, nodes[i].role == "AXSplitGroup", let f = nodes[i].frame else { return false }
        return isDescendant(message, of: i, in: nodes) && isDescendant(composer, of: i, in: nodes) &&
            containsWithTolerance(f, messageFrame) && containsWithTolerance(f, composerFrame)
    }.sorted { (nodes[$0].frame?.width ?? .greatestFiniteMagnitude) < (nodes[$1].frame?.width ?? .greatestFiniteMagnitude) }
    guard let right = rights.first, let rightFrame = nodes[right].frame else {
        throw NativeFailure("SEMANTIC_UNRELIABLE", "無法辨識 LINE 右側 split group")
    }
    let chromeCenters = nodes.compactMap { node -> CGFloat? in
        guard node.role == "AXButton", let f = node.frame, f.minY < rootFrame.minY,
              f.width <= 30, f.height <= 30 else { return nil }
        let subrole = node.subrole.lowercased()
        return subrole.contains("close") || subrole.contains("minimize") ||
            subrole.contains("fullscreen") || subrole.contains("zoom") ? f.midY : nil
    }
    guard chromeCenters.count == 3, let chromeMidY = chromeCenters.min() else {
        throw NativeFailure("SEMANTIC_UNRELIABLE", "無法由三個視窗 chrome 按鈕校正分頁帶")
    }
    let tabBottom = min(searchFrame.minY, rootFrame.minY)
    let tabTop = max(window.bounds.minY, chromeMidY)
    let tabROI = CGRect(x: rootFrame.minX, y: tabTop,
                        width: rootFrame.width, height: tabBottom - tabTop)
    let headerROI = CGRect(x: rightFrame.minX, y: rootFrame.minY,
                           width: rightFrame.width, height: messageFrame.minY - rootFrame.minY)
    guard tabROI.height >= 12, headerROI.height >= 12,
          window.bounds.contains(tabROI), window.bounds.contains(headerROI) else {
        throw NativeFailure("SEMANTIC_UNRELIABLE", "AX 結構推導的 OCR ROI 不合理")
    }
    return LineLayout(searchFieldIndex: search, leftListIndex: left,
                      messageListIndex: message, composerIndex: composer,
                      tabROI: tabROI, headerROI: headerROI)
}

func overlayIntersects(_ identity: WindowIdentity, roi: CGRect, windows: [[String: Any]]) -> Bool {
    windows.contains { window in
        guard (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value != identity.windowID,
              let raw = window[kCGWindowBounds as String] as? [String: Any],
              let frame = rect(from: raw), frame.width * frame.height >= 16 else { return false }
        return frame.intersects(roi)
    }
}

struct ROISourceCapturePlan {
    let sourceRect: CGRect
    let canvasWidth: Int
    let canvasHeight: Int
    let canvasBytesPerRow: Int
    let canvasByteCount: Int
    let roiX: Int
    let roiY: Int
    let roiWidth: Int
    let roiHeight: Int
    let roiBytesPerRow: Int
    let roiByteCount: Int
}

struct DisplayGeometryCandidate {
    let id: CGDirectDisplayID
    let scFrame: CGRect
    let cgFrame: CGRect
    let active: Bool
}

func uniqueDisplayGeometryIndex(_ candidates: [DisplayGeometryCandidate],
                                window: CGRect, roi: CGRect) -> Int? {
    let matches = candidates.indices.filter { index in
        let candidate = candidates[index]
        return candidate.active && candidate.scFrame == candidate.cgFrame &&
            candidate.scFrame.contains(window) && candidate.scFrame.contains(roi)
    }
    return matches.count == 1 ? matches[0] : nil
}

func stableDisplayGeometryIndex(before: DisplayGeometryCandidate,
                                candidates: [DisplayGeometryCandidate],
                                window: CGRect, roi: CGRect) -> Int? {
    guard let index = uniqueDisplayGeometryIndex(candidates, window: window, roi: roi) else {
        return nil
    }
    let selected = candidates[index]
    return selected.id == before.id && selected.scFrame == before.scFrame &&
        selected.cgFrame == before.cgFrame ? index : nil
}

func exactDisplayScale(_ before: CGFloat, _ after: CGFloat) -> Bool {
    before.isFinite && after.isFinite && before == after
}

func validDisplayFilterGeometry(contentRect: CGRect, displayFrame: CGRect,
                                scale: CGFloat) -> Bool {
    contentRect.minX == 0 && contentRect.minY == 0 &&
        contentRect.width == displayFrame.width && contentRect.height == displayFrame.height &&
        scale.isFinite && scale >= 0.5 && scale <= 4
}

func checkedROIRGBAShape(width: Int, height: Int) throws -> (bytesPerRow: Int, byteCount: Int) {
    guard width > 0, height > 0, width <= 8192, height <= 8192 else {
        throw NativeFailure("ROI_DIMENSION_LIMIT", "ROI 擷取尺寸超出安全上限")
    }
    let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
    guard !pixelOverflow, pixels <= 32_000_000 else {
        throw NativeFailure("ROI_PIXEL_LIMIT", "ROI 擷取像素數超出安全上限")
    }
    let (bytesPerRow, rowOverflow) = width.multipliedReportingOverflow(by: 4)
    let (byteCount, byteOverflow) = bytesPerRow.multipliedReportingOverflow(by: height)
    guard !rowOverflow, !byteOverflow, byteCount <= 128_000_000 else {
        throw NativeFailure("ROI_BYTE_LIMIT", "ROI 擷取記憶體超出安全上限")
    }
    return (bytesPerRow, byteCount)
}

func roiSourceCapturePlan(window: CGRect, roi: CGRect, display: CGRect,
                          scale: CGFloat) throws -> ROISourceCapturePlan {
    let rectangles = [window, roi, display]
    guard rectangles.allSatisfy({ rect in
        [rect.minX, rect.minY, rect.maxX, rect.maxY, rect.width, rect.height]
            .allSatisfy(\.isFinite) && rect.width > 0 && rect.height > 0
    }) else {
        throw NativeFailure("ROI_GEOMETRY_INVALID", "ROI 擷取幾何含有無效數值")
    }
    let localDisplay = CGRect(origin: .zero, size: display.size)
    let localROI = roi.offsetBy(dx: -display.minX, dy: -display.minY)
    guard display.contains(window), display.contains(roi), window.contains(roi),
          localDisplay.contains(localROI) else {
        throw NativeFailure("ROI_DISPLAY_UNSUPPORTED", "ROI 擷取要求單一顯示器完整包含主窗與 ROI")
    }
    guard scale.isFinite, scale >= 0.5, scale <= 4 else {
        throw NativeFailure("ROI_SCALE_INVALID", "ROI 擷取縮放比例不合理")
    }
    let rawCanvasWidth = (window.width * scale).rounded()
    let rawCanvasHeight = (window.height * scale).rounded()
    guard rawCanvasWidth.isFinite, rawCanvasHeight.isFinite,
          rawCanvasWidth >= 1, rawCanvasHeight >= 1,
          rawCanvasWidth <= 8192, rawCanvasHeight <= 8192 else {
        throw NativeFailure("ROI_DIMENSION_LIMIT", "ROI 擷取 canvas 尺寸超出安全上限")
    }
    let canvasWidth = Int(rawCanvasWidth)
    let canvasHeight = Int(rawCanvasHeight)
    let canvasShape = try checkedROIRGBAShape(width: canvasWidth, height: canvasHeight)
    let scaleX = CGFloat(canvasWidth) / window.width
    let scaleY = CGFloat(canvasHeight) / window.height
    guard scaleX.isFinite, scaleY.isFinite, scaleX >= 0.5, scaleY >= 0.5,
          scaleX <= 4, scaleY <= 4, abs(scaleX - scaleY) <= 0.05 else {
        throw NativeFailure("ROI_SCALE_INVALID", "ROI 擷取 canvas 與視窗比例不一致")
    }
    let rawMinX = floor((roi.minX - window.minX) * scaleX)
    let rawMinY = floor((roi.minY - window.minY) * scaleY)
    let rawMaxX = ceil((roi.maxX - window.minX) * scaleX)
    let rawMaxY = ceil((roi.maxY - window.minY) * scaleY)
    guard [rawMinX, rawMinY, rawMaxX, rawMaxY].allSatisfy(\.isFinite),
          rawMinX >= 0, rawMinY >= 0,
          rawMaxX <= CGFloat(canvasWidth), rawMaxY <= CGFloat(canvasHeight),
          rawMaxX > rawMinX, rawMaxY > rawMinY else {
        throw NativeFailure("ROI_GEOMETRY_INVALID", "ROI 擷取像素範圍超出 canvas")
    }
    let roiX = Int(rawMinX), roiY = Int(rawMinY)
    let roiWidth = Int(rawMaxX - rawMinX), roiHeight = Int(rawMaxY - rawMinY)
    let roiShape = try checkedROIRGBAShape(width: roiWidth, height: roiHeight)
    return ROISourceCapturePlan(
        sourceRect: localROI,
        canvasWidth: canvasWidth, canvasHeight: canvasHeight,
        canvasBytesPerRow: canvasShape.bytesPerRow, canvasByteCount: canvasShape.byteCount,
        roiX: roiX, roiY: roiY, roiWidth: roiWidth, roiHeight: roiHeight,
        roiBytesPerRow: roiShape.bytesPerRow, roiByteCount: roiShape.byteCount
    )
}

func validateROISourceCapturePlan(_ plan: ROISourceCapturePlan) throws {
    let canvas = try checkedROIRGBAShape(width: plan.canvasWidth, height: plan.canvasHeight)
    let roi = try checkedROIRGBAShape(width: plan.roiWidth, height: plan.roiHeight)
    let (roiMaxX, xOverflow) = plan.roiX.addingReportingOverflow(plan.roiWidth)
    let (roiMaxY, yOverflow) = plan.roiY.addingReportingOverflow(plan.roiHeight)
    guard !xOverflow, !yOverflow, plan.roiX >= 0, plan.roiY >= 0,
          roiMaxX <= plan.canvasWidth, roiMaxY <= plan.canvasHeight,
          plan.canvasBytesPerRow == canvas.bytesPerRow,
          plan.canvasByteCount == canvas.byteCount,
          plan.roiBytesPerRow == roi.bytesPerRow,
          plan.roiByteCount == roi.byteCount else {
        throw NativeFailure("ROI_PLAN_INVALID", "ROI 擷取配置未通過配置前檢查")
    }
}

func roiCanvasTopDown(_ roiTopDown: [UInt8], plan: ROISourceCapturePlan) throws -> [UInt8] {
    try validateROISourceCapturePlan(plan)
    guard roiTopDown.count == plan.roiByteCount else {
        throw NativeFailure("ROI_OUTPUT_MISMATCH", "來源端 ROI RGBA 位元組數不符")
    }
    var canvas = [UInt8](repeating: 0, count: plan.canvasByteCount)
    for row in 0..<plan.roiHeight {
        let source = row * plan.roiBytesPerRow
        let destination = (plan.roiY + row) * plan.canvasBytesPerRow + plan.roiX * 4
        canvas.replaceSubrange(destination..<(destination + plan.roiBytesPerRow),
                               with: roiTopDown[source..<(source + plan.roiBytesPerRow)])
    }
    return canvas
}

func roiCanvasImage(_ roiImage: CGImage, plan: ROISourceCapturePlan) throws -> CGImage {
    try validateROISourceCapturePlan(plan)
    guard roiImage.width == plan.roiWidth, roiImage.height == plan.roiHeight else {
        throw NativeFailure("ROI_OUTPUT_MISMATCH", "來源端 ROI 擷取尺寸不符")
    }
    let (bottomUp, bytesPerRow) = try rgbaBottomUp(roiImage)
    guard bytesPerRow == plan.roiBytesPerRow, bottomUp.count == plan.roiByteCount else {
        throw NativeFailure("ROI_OUTPUT_MISMATCH", "來源端 ROI RGBA 格式不符")
    }
    let roiTopDown = topDownRows(bottomUp, bytesPerRow: bytesPerRow, height: plan.roiHeight)
    let canvas = try roiCanvasTopDown(roiTopDown, plan: plan)
    guard let result = rgbaImage(topDown: canvas, width: plan.canvasWidth, height: plan.canvasHeight) else {
        throw NativeFailure("ROI_CANVAS_FAILED", "無法建立 ROI 外全透明的相容 canvas")
    }
    return result
}

@available(macOS 14.0, *)
func captureWindowImage(_ identity: WindowIdentity, roi: CGRect,
                        timeout: TimeInterval = 2.5,
                        opaqueForRead: Bool = false) throws -> CGImage {
    guard #available(macOS 14.2, *) else {
        throw NativeFailure("ROI_OS_UNSUPPORTED", "來源端 ROI 擷取需要 macOS 14.2 或以上版本")
    }
    guard !overlayIntersects(identity, roi: roi, windows: cgWindows(pid: identity.pid)) else {
        throw NativeFailure("WINDOW_OVERLAY_PRESENT", "LINE 同程序其他視窗遮住 OCR 區域")
    }
    let contentSemaphore = DispatchSemaphore(value: 0)
    let contentBox = AsyncBox<Result<SCShareableContent, Error>>()
    SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, error in
        if let content { contentBox.set(.success(content)) }
        else { contentBox.set(.failure(error ?? NativeFailure("ROI_CAPTURE_UNAVAILABLE", "無法取得 ROI 擷取來源"))) }
        contentSemaphore.signal()
    }
    guard contentSemaphore.wait(timeout: .now() + min(timeout, 2)) == .success,
          let contentResult = contentBox.get() else {
        throw NativeFailure("ROI_CAPTURE_TIMEOUT", "取得 ROI 擷取來源逾時")
    }
    let content: SCShareableContent
    do { content = try contentResult.get() }
    catch { throw NativeFailure("ROI_CAPTURE_UNAVAILABLE", "無法取得 ROI 擷取來源") }
    let windows = content.windows.filter {
        $0.windowID == identity.windowID && $0.owningApplication?.processID == identity.pid &&
        $0.title == expectedWindowTitle && $0.isOnScreen &&
            similar($0.frame, identity.bounds, tolerance: 0.5)
    }
    let displayCandidates = content.displays.map {
        DisplayGeometryCandidate(id: $0.displayID, scFrame: $0.frame,
                                 cgFrame: CGDisplayBounds($0.displayID),
                                 active: CGDisplayIsActive($0.displayID) != 0)
    }
    guard windows.count == 1,
          let displayIndex = uniqueDisplayGeometryIndex(displayCandidates,
                                                        window: identity.bounds, roi: roi) else {
        throw NativeFailure("ROI_SOURCE_AMBIGUOUS", "ROI 擷取來源或顯示器幾何不唯一",
                            ["windows": windows.count])
    }
    let selectedDisplay = content.displays[displayIndex]
    let selectedGeometry = displayCandidates[displayIndex]
    let filter = SCContentFilter(display: selectedDisplay, including: [windows[0]])
    filter.includeMenuBar = false
    let selectedScale = CGFloat(filter.pointPixelScale)
    guard filter.style == .display,
          validDisplayFilterGeometry(contentRect: filter.contentRect,
                                     displayFrame: selectedDisplay.frame,
                                     scale: selectedScale) else {
        throw NativeFailure("ROI_SOURCE_AMBIGUOUS", "ROI 擷取 filter 未精確綁定 LINE 主窗")
    }
    if #available(macOS 15.2, *) {
        guard filter.includedWindows.count == 1,
              filter.includedWindows[0].windowID == identity.windowID else {
            throw NativeFailure("ROI_SOURCE_AMBIGUOUS", "ROI 擷取 filter 未精確綁定 LINE 主窗")
        }
    }
    let plan = try roiSourceCapturePlan(window: identity.bounds, roi: roi,
                                        display: selectedDisplay.frame,
                                        scale: selectedScale)
    let configuration = SCStreamConfiguration()
    configuration.sourceRect = plan.sourceRect
    configuration.width = plan.roiWidth
    configuration.height = plan.roiHeight
    configuration.showsCursor = false
    configuration.ignoreShadowsDisplay = true
    configuration.includeChildWindows = false
    configuration.scalesToFit = true
    configuration.shouldBeOpaque = opaqueForRead
    configuration.capturesAudio = false
    if #available(macOS 15.0, *) { configuration.captureMicrophone = false }
    let semaphore = DispatchSemaphore(value: 0)
    let box = AsyncBox<Result<CGImage, Error>>()
    SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
        if let image { box.set(.success(image)) }
        else { box.set(.failure(error ?? NativeFailure("ROI_CAPTURE_UNAVAILABLE", "無法擷取 LINE ROI"))) }
        semaphore.signal()
    }
    guard semaphore.wait(timeout: .now() + timeout) == .success, let result = box.get() else {
        throw NativeFailure("ROI_CAPTURE_TIMEOUT", "擷取 LINE ROI 逾時")
    }
    let image: CGImage
    do { image = try result.get() }
    catch { throw NativeFailure("ROI_CAPTURE_UNAVAILABLE", "ScreenCaptureKit 無法擷取 LINE ROI") }
    guard image.width == plan.roiWidth, image.height == plan.roiHeight else {
        throw NativeFailure("ROI_OUTPUT_MISMATCH", "來源端 ROI 擷取尺寸不符")
    }
    let postContentSemaphore = DispatchSemaphore(value: 0)
    let postContentBox = AsyncBox<Result<SCShareableContent, Error>>()
    SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { postContent, error in
        if let postContent { postContentBox.set(.success(postContent)) }
        else {
            postContentBox.set(.failure(error ?? NativeFailure(
                "ROI_CAPTURE_UNAVAILABLE", "無法重新驗證 ROI 擷取來源"
            )))
        }
        postContentSemaphore.signal()
    }
    guard postContentSemaphore.wait(timeout: .now() + min(timeout, 2)) == .success,
          let postContentResult = postContentBox.get(),
          let postContent = try? postContentResult.get() else {
        throw NativeFailure("ROI_CAPTURE_TIMEOUT", "重新驗證 ROI 擷取來源逾時")
    }
    let postWindows = postContent.windows.filter {
        $0.windowID == identity.windowID && $0.owningApplication?.processID == identity.pid &&
        $0.title == expectedWindowTitle && $0.isOnScreen &&
            similar($0.frame, identity.bounds, tolerance: 0.5)
    }
    let postDisplayCandidates = postContent.displays.map {
        DisplayGeometryCandidate(id: $0.displayID, scFrame: $0.frame,
                                 cgFrame: CGDisplayBounds($0.displayID),
                                 active: CGDisplayIsActive($0.displayID) != 0)
    }
    guard postWindows.count == 1,
          let postDisplayIndex = stableDisplayGeometryIndex(
            before: selectedGeometry, candidates: postDisplayCandidates,
            window: identity.bounds, roi: roi
          ) else {
        throw NativeFailure("ROI_DISPLAY_CHANGED", "ROI 擷取期間顯示器或 LINE source 已漂移")
    }
    let postDisplay = postContent.displays[postDisplayIndex]
    let postFilter = SCContentFilter(display: postDisplay, including: [postWindows[0]])
    postFilter.includeMenuBar = false
    guard postFilter.style == .display,
          validDisplayFilterGeometry(contentRect: postFilter.contentRect,
                                     displayFrame: postDisplay.frame,
                                     scale: CGFloat(postFilter.pointPixelScale)),
          exactDisplayScale(selectedScale, CGFloat(postFilter.pointPixelScale)) else {
        throw NativeFailure("ROI_DISPLAY_CHANGED", "ROI 擷取期間 filter 幾何或 scale 已漂移")
    }
    if #available(macOS 15.2, *) {
        guard postFilter.includedWindows.count == 1,
              postFilter.includedWindows[0].windowID == identity.windowID else {
            throw NativeFailure("ROI_DISPLAY_CHANGED", "ROI 擷取後 filter window 已漂移")
        }
    }
    let (_, _, _, after) = try mainWindow(requireForeground: true)
    guard sameWindow(identity, after) else { throw NativeFailure("WINDOW_CHANGED", "擷取期間 LINE 視窗已變更") }
    return try roiCanvasImage(image, plan: plan)
}

func visionRequest(_ image: CGImage) throws -> [VNRecognizedTextObservation] {
    let request = VNRecognizeTextRequest()
    request.revision = ocrRevision
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["zh-Hant", "en-US"]
    request.usesLanguageCorrection = false
    do { try VNImageRequestHandler(cgImage: image, orientation: .up, options: [:]).perform([request]) }
    catch { throw NativeFailure("OCR_FAILED", "Vision OCR 執行失敗") }
    return request.results ?? []
}

func badgeGeometryEligible(_ component: GreenComponent, roiHeight: CGFloat) -> Bool {
    let diameter = max(component.pointBox.width, component.pointBox.height)
    return diameter >= 2 && diameter <= 8 && component.aspect >= 0.7 && component.aspect <= 1.4 &&
        component.fillRatio >= 0.45 && component.fillRatio <= 0.95 &&
        component.pointBox.midY <= roiHeight * 0.28 && component.pointBox.maxY <= roiHeight * 0.38
}

func rgbaBottomUp(_ image: CGImage) throws -> ([UInt8], Int) {
    let width = image.width, height = image.height, bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
    let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard rendered else { throw NativeFailure("BADGE_ANALYSIS_FAILED", "無法在記憶體建立 RGBA ROI") }
    return (pixels, bytesPerRow)
}

func isLineGreen(_ pixels: [UInt8], _ index: Int) -> Bool {
    let offset = index * 4
    let red = Int(pixels[offset]), green = Int(pixels[offset + 1]), blue = Int(pixels[offset + 2])
    return Int(pixels[offset + 3]) >= 160 && green >= 90 && green - red >= 35 &&
        green - blue >= 20 && Double(green) >= Double(max(red, blue)) * 1.25
}

func greenComponents(_ image: CGImage, geometry: CaptureGeometry) throws -> [GreenComponent] {
    guard let roiImage = image.cropping(to: try geometry.roiPixels()) else {
        throw NativeFailure("OCR_ROI_FAILED", "無法在記憶體裁切 badge ROI")
    }
    let width = roiImage.width
    let height = roiImage.height
    let (pixels, _) = try rgbaBottomUp(roiImage)
    var visited = [Bool](repeating: false, count: width * height)
    var results: [GreenComponent] = []
    let neighbors = [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)]
    for start in 0..<(width * height) where !visited[start] && isLineGreen(pixels, start) {
        var queue = [start]
        visited[start] = true
        var cursor = 0, minX = width, minY = height, maxX = 0, maxY = 0
        var red = 0, green = 0, blue = 0, alpha = 0
        while cursor < queue.count {
            let index = queue[cursor]; cursor += 1
            let x = index % width, y = index / width, offset = index * 4
            minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
            red += Int(pixels[offset]); green += Int(pixels[offset + 1])
            blue += Int(pixels[offset + 2]); alpha += Int(pixels[offset + 3])
            for (dx, dy) in neighbors {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                let next = ny * width + nx
                if !visited[next] && isLineGreen(pixels, next) { visited[next] = true; queue.append(next) }
            }
        }
        guard queue.count >= 2 else { continue }
        let pixelBox = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        let topY = CGFloat(height) - pixelBox.maxY
        let pointBox = CGRect(x: pixelBox.minX / geometry.scaleX, y: topY / geometry.scaleY,
                              width: pixelBox.width / geometry.scaleX, height: pixelBox.height / geometry.scaleY)
        let count = Double(queue.count)
        results.append(GreenComponent(pixelBox: pixelBox, pointBox: pointBox, pixelCount: queue.count,
                                      meanRed: Double(red) / count, meanGreen: Double(green) / count,
                                      meanBlue: Double(blue) / count, meanAlpha: Double(alpha) / count))
        if results.count >= 100 { break }
    }
    return results.sorted { $0.pointBox.minX < $1.pointBox.minX }
}

func underlineComponentsROI(_ roiImage: CGImage, scaleX: CGFloat,
                            scaleY: CGFloat) throws -> [UnderlineComponent] {
    let width = roiImage.width, height = roiImage.height
    let (pixels, _) = try rgbaBottomUp(roiImage)
    func isDark(_ index: Int) -> Bool {
        let offset = index * 4
        let r = Int(pixels[offset]), g = Int(pixels[offset + 1]), b = Int(pixels[offset + 2])
        return Int(pixels[offset + 3]) >= 200 && max(r, max(g, b)) <= 55
    }
    var visited = [Bool](repeating: false, count: width * height)
    var result: [UnderlineComponent] = []
    for start in 0..<(width * height) where !visited[start] && isDark(start) {
        var queue = [start], cursor = 0, minX = width, minY = height, maxX = 0, maxY = 0, luma = 0
        visited[start] = true
        while cursor < queue.count {
            let index = queue[cursor]; cursor += 1
            let x = index % width, y = index / width, offset = index * 4
            minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
            luma += (Int(pixels[offset]) + Int(pixels[offset + 1]) + Int(pixels[offset + 2])) / 3
            for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                let next = ny * width + nx
                if !visited[next] && isDark(next) { visited[next] = true; queue.append(next) }
            }
        }
        guard queue.count >= 2 else { continue }
        let pixelBox = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        let topY = CGFloat(height) - pixelBox.maxY
        let pointBox = CGRect(x: pixelBox.minX / scaleX, y: topY / scaleY,
                              width: pixelBox.width / scaleX, height: pixelBox.height / scaleY)
        result.append(UnderlineComponent(pointBox: pointBox, pixelCount: queue.count,
                                         meanLuma: Double(luma) / Double(queue.count),
                                         fillRatio: CGFloat(queue.count) / (pixelBox.width * pixelBox.height)))
    }
    return result
}

func underlineComponents(_ image: CGImage, geometry: CaptureGeometry) throws -> [UnderlineComponent] {
    guard let roiImage = image.cropping(to: try geometry.roiPixels()) else { return [] }
    return try underlineComponentsROI(roiImage, scaleX: geometry.scaleX, scaleY: geometry.scaleY)
}

func eligibleUnderline(_ component: UnderlineComponent, roiHeight: CGFloat) -> Bool {
    component.pointBox.width >= 8 && component.pointBox.width <= 200 &&
        component.pointBox.height >= 0.5 && component.pointBox.height <= 4 &&
        component.aspect >= 4 && component.fillRatio >= 0.6 && component.meanLuma <= 55 &&
        component.pointBox.maxY >= roiHeight - 6
}

func topDownRows(_ bottomUp: [UInt8], bytesPerRow: Int, height: Int) -> [UInt8] {
    var result = [UInt8](repeating: 0, count: bottomUp.count)
    for topRow in 0..<height {
        let source = (height - 1 - topRow) * bytesPerRow
        let destination = topRow * bytesPerRow
        result.replaceSubrange(destination..<(destination + bytesPerRow),
                               with: bottomUp[source..<(source + bytesPerRow)])
    }
    return result
}

func rgbaImage(topDown: [UInt8], width: Int, height: Int) -> CGImage? {
    let bytesPerRow = width * 4
    guard topDown.count == bytesPerRow * height,
          let provider = CGDataProvider(data: Data(topDown) as CFData) else { return nil }
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
}

func validReadROIShape(width: Int, height: Int) -> Bool {
    let (count, overflow) = width.multipliedReportingOverflow(by: height)
    let (_, rowOverflow) = width.multipliedReportingOverflow(by: 4)
    return !overflow && !rowOverflow && width > 0 && height > 0 &&
        width <= processedOCRMaxDimension && height <= processedOCRMaxDimension &&
        count <= processedOCRMaxPixels
}

func readColorProfile(_ pixels: [UInt8], width: Int, height: Int,
                      bytesPerRow: Int) -> ReadColorProfile? {
    let (expectedRowBytes, rowOverflow) = width.multipliedReportingOverflow(by: 4)
    let (expectedBytes, bytesOverflow) = bytesPerRow.multipliedReportingOverflow(by: height)
    guard validReadROIShape(width: width, height: height), !rowOverflow, !bytesOverflow,
          bytesPerRow == expectedRowBytes, pixels.count == expectedBytes else { return nil }
    let count = width * height
    var lumas = [UInt8](); lumas.reserveCapacity(count)
    for y in 0..<height {
        for x in 0..<width {
            let offset = y * bytesPerRow + x * 4
            guard pixels[offset + 3] == 255 else { return nil }
            let value = (Int(pixels[offset]) * 54 + Int(pixels[offset + 1]) * 183 +
                         Int(pixels[offset + 2]) * 19) / 256
            lumas.append(UInt8(value))
        }
    }
    lumas.sort()
    let median = lumas[lumas.count / 2]
    if median <= 80 { return .dark }
    if median >= 180 { return .light }
    return nil
}

func stableReadColorProfile(_ first: ReadColorProfile,
                            _ second: ReadColorProfile) -> Bool { first == second }

func tabNavigationProfileAllowed(_ mode: TabNavigationMode,
                                 expected: ReadColorProfile?,
                                 observed: ReadColorProfile?) -> Bool {
    switch mode {
    case .legacy:
        // legacy 不應偽造 canonical profile，也不得接受 readonly profile 狀態。
        return expected == nil && observed == nil
    case .readOnly:
        guard let observed else { return false }
        return expected.map { stableReadColorProfile($0, observed) } ?? true
    }
}

func canonicalReadROI(_ image: CGImage,
                      requiredProfile: ReadColorProfile? = nil) throws -> CanonicalReadROI {
    let width = image.width, height = image.height
    guard validReadROIShape(width: width, height: height) else {
        throw NativeFailure("OCR_PROCESSING_LIMIT", "唯讀 OCR ROI 超出固定尺寸或記憶體上限")
    }
    let (pixels, bytesPerRow) = try rgbaBottomUp(image)
    guard let profile = readColorProfile(pixels, width: width, height: height,
                                         bytesPerRow: bytesPerRow),
          requiredProfile == nil || requiredProfile == profile else {
        throw NativeFailure("UNSUPPORTED_COLOR_PROFILE", "唯讀 OCR ROI 色彩或透明度不支援")
    }
    guard profile == .dark else { return CanonicalReadROI(image: image, profile: profile) }
    var inverted = pixels
    for index in 0..<(width * height) {
        let offset = index * 4
        inverted[offset] = 255 - inverted[offset]
        inverted[offset + 1] = 255 - inverted[offset + 1]
        inverted[offset + 2] = 255 - inverted[offset + 2]
    }
    let topDown = topDownRows(inverted, bytesPerRow: bytesPerRow, height: height)
    guard let result = rgbaImage(topDown: topDown, width: width, height: height) else {
        throw NativeFailure("OCR_PROCESSING_FAILED", "無法在記憶體正規化唯讀 OCR ROI")
    }
    return CanonicalReadROI(image: result, profile: profile)
}

func maskedBadgeROI(_ image: CGImage, geometry: CaptureGeometry,
                    components: [GreenComponent]) throws -> CGImage? {
    let eligible = components.filter { badgeGeometryEligible($0, roiHeight: geometry.roi.height) }
    guard !eligible.isEmpty, let roiImage = image.cropping(to: try geometry.roiPixels()) else { return nil }
    let width = roiImage.width, height = roiImage.height
    var (pixels, bytesPerRow) = try rgbaBottomUp(roiImage)
    for component in eligible {
        let box = component.pixelBox.insetBy(dx: -1, dy: -1).intersection(
            CGRect(x: 0, y: 0, width: width, height: height)
        ).integral
        let ring = component.pixelBox.insetBy(dx: -3, dy: -3).intersection(
            CGRect(x: 0, y: 0, width: width, height: height)
        ).integral
        var channels = [[UInt8](), [UInt8](), [UInt8](), [UInt8]()]
        for y in Int(ring.minY)..<Int(ring.maxY) {
            for x in Int(ring.minX)..<Int(ring.maxX) where !box.contains(CGPoint(x: x, y: y)) {
                let index = y * width + x
                if isLineGreen(pixels, index) { continue }
                let offset = index * 4
                for channel in 0..<4 { channels[channel].append(pixels[offset + channel]) }
            }
        }
        guard channels.allSatisfy({ !$0.isEmpty }) else { continue }
        let background = channels.map { values -> UInt8 in
            let sorted = values.sorted(); return sorted[sorted.count / 2]
        }
        for y in Int(box.minY)..<Int(box.maxY) {
            for x in Int(box.minX)..<Int(box.maxX) {
                let offset = (y * width + x) * 4
                for channel in 0..<4 { pixels[offset + channel] = background[channel] }
            }
        }
    }
    let topDown = topDownRows(pixels, bytesPerRow: bytesPerRow, height: height)
    guard let masked = rgbaImage(topDown: topDown, width: width, height: height) else {
        throw NativeFailure("BADGE_MASK_FAILED", "無法在記憶體建立 badge-masked ROI")
    }
    return masked
}

func upscaledWholeROI2x(_ image: CGImage) throws -> CGImage {
    let width = image.width, height = image.height
    let (scaledWidth, widthOverflow) = width.multipliedReportingOverflow(by: 2)
    let (scaledHeight, heightOverflow) = height.multipliedReportingOverflow(by: 2)
    let (pixels, pixelOverflow) = scaledWidth.multipliedReportingOverflow(by: scaledHeight)
    guard !widthOverflow, !heightOverflow, !pixelOverflow,
          scaledWidth > 0, scaledHeight > 0,
          scaledWidth <= processedOCRMaxDimension, scaledHeight <= processedOCRMaxDimension,
          pixels <= processedOCRMaxPixels else {
        throw NativeFailure("OCR_PROCESSING_LIMIT", "2x OCR ROI 超出固定記憶體上限")
    }
    guard let context = CGContext(data: nil, width: scaledWidth, height: scaledHeight,
                                  bitsPerComponent: 8, bytesPerRow: scaledWidth * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw NativeFailure("OCR_PROCESSING_FAILED", "無法在記憶體建立 2x OCR ROI")
    }
    // 固定處理整張 ROI；不得為通過門檻改裁切、變形或嘗試多種影像策略。
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: scaledWidth, height: scaledHeight))
    guard let result = context.makeImage() else {
        throw NativeFailure("OCR_PROCESSING_FAILED", "無法在記憶體完成 2x OCR ROI")
    }
    return result
}

func visionCandidates(_ image: CGImage) throws -> [OCRCandidate] {
    try visionRequest(image).compactMap { observation in
        guard let candidate = observation.topCandidates(1).first else { return nil }
        let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : OCRCandidate(text: text, confidence: candidate.confidence,
                                                 normalizedBox: observation.boundingBox)
    }
}

struct MergedAllRawToken {
    let parentIndex: Int
    let label: String
    let normalizedBox: CGRect
}

func positiveAreaOverlap(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
    let overlap = lhs.intersection(rhs)
    return !overlap.isNull && overlap.width > 0 && overlap.height > 0
}

func mergedAllNavigationCandidate(rawTokens: [MergedAllRawToken],
                                  rawCandidates: [OCRCandidate],
                                  processedCandidates: [OCRCandidate],
                                  originalWidth: Int, originalHeight: Int) -> OCRCandidate? {
    guard rawTokens.count == 1, let token = rawTokens.first,
          rawCandidates.indices.contains(token.parentIndex),
          validNormalizedBox(token.normalizedBox),
          // coarse context 與 processed 全集合都必須幾何有效；invalid conflict 不可被略過。
          rawCandidates.allSatisfy({ validNormalizedBox($0.normalizedBox) }),
          processedCandidates.allSatisfy({ validNormalizedBox($0.normalizedBox) }),
          originalWidth > 0, originalHeight > 0 else { return nil }
    let processedExact = processedCandidates.filter { ["全部", "All"].contains($0.text) }
    guard processedExact.count == 1, let processed = processedExact.first,
          processed.text == token.label,
          processed.confidence >= ocrConfidenceThreshold,
          validNormalizedBox(processed.normalizedBox) else { return nil }
    let expanded = token.normalizedBox.insetBy(dx: -1 / CGFloat(originalWidth),
                                                dy: -1 / CGFloat(originalHeight))
    guard expanded.contains(processed.normalizedBox),
          token.normalizedBox.width * token.normalizedBox.height <=
            processed.normalizedBox.width * processed.normalizedBox.height * 2 else { return nil }
    let rawConflict = rawCandidates.enumerated().contains { index, candidate in
        index != token.parentIndex && candidate.confidence >= ocrConfidenceThreshold &&
            candidate.text != processed.text && validNormalizedBox(candidate.normalizedBox) &&
            positiveAreaOverlap(candidate.normalizedBox, processed.normalizedBox)
    }
    let processedConflict = processedCandidates.contains { candidate in
        candidate.text != processed.text && candidate.confidence >= ocrConfidenceThreshold &&
            validNormalizedBox(candidate.normalizedBox) &&
            positiveAreaOverlap(candidate.normalizedBox, processed.normalizedBox)
    }
    return !rawConflict && !processedConflict ? processed : nil
}

func allNavigationTokenRanges(_ text: String) -> [(label: String, range: Range<String.Index>)] {
    var result: [(String, Range<String.Index>)] = []
    var start: String.Index?
    var index = text.startIndex
    while index < text.endIndex {
        let next = text.index(after: index)
        if text[index].isWhitespace {
            if let tokenStart = start {
                let range = tokenStart..<index
                let token = String(text[range])
                if token == "全部" || token == "All" { result.append((token, range)) }
                start = nil
            }
        } else if start == nil { start = index }
        index = next
    }
    if let tokenStart = start {
        let range = tokenStart..<text.endIndex
        let token = String(text[range])
        if token == "全部" || token == "All" { result.append((token, range)) }
    }
    return result
}

func recognizeText(_ image: CGImage, geometry: CaptureGeometry) throws -> [OCRCandidate] {
    guard let cropped = image.cropping(to: try geometry.roiPixels()) else {
        throw NativeFailure("OCR_ROI_FAILED", "無法在記憶體裁切 OCR ROI")
    }
    let observations = try visionRequest(cropped)
    return observations.compactMap { observation -> OCRCandidate? in
        guard let candidate = observation.topCandidates(1).first else { return nil }
        let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : OCRCandidate(text: text, confidence: candidate.confidence,
                                                 normalizedBox: observation.boundingBox)
    }
}

struct NameBandSample {
    let identity: WindowIdentity
    let listElement: AXUIElement
    let listFrame: CGRect
    let rowElements: [AXUIElement]
    let rowFrames: [CGRect]
    let imageWidth: Int
    let imageHeight: Int
    let rowProfiles: [ReadColorProfile]
    let target: OCRCandidate?
    let targetRendererEvidence: RendererRefinementEvidence?
    let targetScreenRect: CGRect?
    let targetObservedCount: Int
    let visibleRowCount: Int
    let invalidRowCount: Int
    let bandInvalidRowCount: Int
    let candidateInvalidRowCount: Int
    let axRowsCount: Int
    let advertisedRowCount: Int?
    let denseIndices: Bool
    let allRowsVisible: Bool
}

// 只定位上半部第一條文字墨跡；下方預覽永遠不送入 Vision。
func titleBandCrop(luma: [UInt8], width: Int, height: Int, scale: CGFloat) -> CGRect? {
    guard width > 0, height > 0, luma.count == width * height,
          scale.isFinite, scale >= 0.5, scale <= 4 else { return nil }
    let upperEnd = max(1, Int(floor(CGFloat(height) * 0.5)))
    let sorted = luma.prefix(width * upperEnd).sorted()
    guard let background = sorted.isEmpty ? nil : sorted[sorted.count / 2], background >= 180 else { return nil }
    let scanStart = min(width, Int(ceil(CGFloat(height) * 1.10)))
    guard scanStart < width else { return nil }
    let minimumSupport = max(2, Int(ceil(scale)))
    var active = [Bool](repeating: false, count: upperEnd)
    var dark = [Bool](repeating: false, count: upperEnd)
    for y in 0..<upperEnd {
        var support = 0, darkSupport = 0
        for x in scanStart..<width {
            let value = Int(luma[y * width + x])
            if abs(value - Int(background)) >= 12 { support += 1 }
            if value <= 80 { darkSupport += 1 }
        }
        active[y] = support >= minimumSupport
        dark[y] = darkSupport >= minimumSupport
    }
    func bands(_ rows: [Bool]) -> [Range<Int>] {
        let gap = max(0, Int(floor(1.5 * scale)))
        var result: [Range<Int>] = [], start: Int?, last: Int?
        for index in rows.indices where rows[index] {
            if let prior = last, index - prior - 1 > gap {
                result.append(start!..<(prior + 1)); start = index
            } else if start == nil { start = index }
            last = index
        }
        if let start, let last { result.append(start..<(last + 1)) }
        return result
    }
    let inkBands = bands(active)
    guard let first = inkBands.first else { return nil }
    let pointStart = CGFloat(first.lowerBound) / scale
    let pointEnd = CGFloat(first.upperBound) / scale
    let pointHeight = CGFloat(first.count) / scale
    let rowPointHeight = CGFloat(height) / scale
    guard pointStart <= rowPointHeight * 0.28, pointEnd <= rowPointHeight * 0.48,
          pointHeight >= 8, pointHeight <= 22 else { return nil }
    let laterDark = bands(dark).contains {
        $0.lowerBound >= first.upperBound && CGFloat($0.lowerBound) / scale <= rowPointHeight * 0.45
    }
    guard !laterDark else { return nil }
    let padding = max(0, Int(floor(2 * scale)))
    let minimumGap = max(1, Int(ceil(scale)))
    let nextStart = inkBands.dropFirst().first?.lowerBound ?? upperEnd
    let cropTop = max(0, first.lowerBound - padding)
    let cropBottom = min(upperEnd, min(first.upperBound + padding, nextStart - minimumGap))
    let cropX = min(width, Int(floor(CGFloat(height) * 0.85)))
    guard cropBottom > cropTop, cropX < width else { return nil }
    return CGRect(x: cropX, y: cropTop, width: width - cropX, height: cropBottom - cropTop)
}

func candidateTouchesCrop(_ candidate: OCRCandidate) -> Bool {
    let box = candidate.normalizedBox
    return !validNormalizedBox(box) || box.minX <= 0.005 || box.minY <= 0.005 ||
        box.maxX >= 0.995 || box.maxY >= 0.995
}

func timestampCandidate(_ candidate: OCRCandidate) -> Bool {
    guard candidate.normalizedBox.minX >= 0.70 else { return false }
    let expression = try! NSRegularExpression(
        pattern: #"^(上午|下午|AM|PM)?\s*\d{1,2}:\d{2}$"#, options: [.caseInsensitive]
    )
    let range = NSRange(candidate.text.startIndex..<candidate.text.endIndex, in: candidate.text)
    return expression.firstMatch(in: candidate.text, range: range)?.range == range
}

func verifiedNameCandidate(_ candidates: [OCRCandidate]) -> OCRCandidate? {
    guard !candidates.isEmpty,
          candidates.allSatisfy({ !$0.text.contains("…") && !$0.text.contains("...") &&
              !$0.text.contains("\n") && !candidateTouchesCrop($0) &&
              $0.confidence >= ocrConfidenceThreshold }) else { return nil }
    let names = candidates.filter { $0.normalizedBox.minX <= 0.22 }
    let nonMetadata = candidates.filter { !timestampCandidate($0) }
    guard names.count == 1, let name = names.first,
          nonMetadata.count == 1, nonMetadata[0].text == name.text else { return nil }
    return name
}

struct ParsedRendererLabel {
    let prefix: String
    let observedParenthesizedCount: Int
    let countToken: String
    let prefixRange: Range<String.Index>
    let countRange: Range<String.Index>
    let suffixRange: Range<String.Index>?
    let rawSuffix: String?
}

struct RendererRefinementEvidence {
    let candidate: OCRCandidate
    let observedParenthesizedCount: Int
    let auxiliaryObserved: Bool
    let identityVerified: Bool
}

struct RendererRowChoice {
    let candidate: OCRCandidate
    let rendererChosen: Bool
}

func chooseRendererRowCandidate(literal: OCRCandidate?,
                                renderer: RendererRefinementEvidence?,
                                target: String) -> RendererRowChoice? {
    if let literal, literal.text == target {
        return RendererRowChoice(candidate: literal, rendererChosen: false)
    }
    if let renderer, renderer.candidate.text == target {
        return RendererRowChoice(candidate: renderer.candidate, rendererChosen: true)
    }
    if let literal { return RendererRowChoice(candidate: literal, rendererChosen: false) }
    if let renderer { return RendererRowChoice(candidate: renderer.candidate, rendererChosen: true) }
    return nil
}

enum AuxiliaryPixelVerdict { case absent, observed, rejected }

func parseRendererLabel(_ text: String) -> ParsedRendererLabel? {
    guard !text.isEmpty, text.first?.isWhitespace == false,
          text.count <= 240, !text.contains("…"), !text.contains("..."),
          !text.unicodeScalars.contains(where: {
              CharacterSet.controlCharacters.contains($0) ||
                  (0x202A...0x202E).contains(Int($0.value)) ||
                  (0x2066...0x2069).contains(Int($0.value))
          }) else { return nil }
    let expression = try! NSRegularExpression(
        pattern: #"^(.+)([（(])([0-9]{1,5})([）)])(.*)$"#
    )
    let whole = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = expression.firstMatch(in: text, range: whole),
          match.range == whole,
          let rawPrefixRange = Range(match.range(at: 1), in: text),
          let openRange = Range(match.range(at: 2), in: text),
          let digitsRange = Range(match.range(at: 3), in: text),
          let closeRange = Range(match.range(at: 4), in: text),
          let rawSuffixRange = Range(match.range(at: 5), in: text) else { return nil }
    let open = String(text[openRange]), close = String(text[closeRange])
    guard (open == "(" && close == ")") || (open == "（" && close == "）"),
          let count = Int(text[digitsRange]), (1...99_999).contains(count) else { return nil }
    var prefixEnd = rawPrefixRange.upperBound
    while prefixEnd > rawPrefixRange.lowerBound {
        let prior = text.index(before: prefixEnd)
        if text[prior].isWhitespace { prefixEnd = prior } else { break }
    }
    let prefixRange = rawPrefixRange.lowerBound..<prefixEnd
    let prefix = String(text[prefixRange])
    guard !prefix.isEmpty, prefix.count <= 200, !prefix.contains("\n"), !prefix.contains("\r") else { return nil }
    let countRange = openRange.lowerBound..<closeRange.upperBound
    var suffixStart = rawSuffixRange.lowerBound, suffixEnd = rawSuffixRange.upperBound
    while suffixStart < suffixEnd, text[suffixStart].isWhitespace {
        suffixStart = text.index(after: suffixStart)
    }
    while suffixEnd > suffixStart {
        let prior = text.index(before: suffixEnd)
        if text[prior].isWhitespace { suffixEnd = prior } else { break }
    }
    let suffixRange = suffixStart..<suffixEnd
    let suffix = String(text[suffixRange])
    guard suffix.count <= 1 else { return nil }
    return ParsedRendererLabel(prefix: prefix, observedParenthesizedCount: count,
                               countToken: String(text[countRange]),
                               prefixRange: prefixRange, countRange: countRange,
                               suffixRange: suffix.isEmpty ? nil : suffixRange,
                               rawSuffix: suffix.isEmpty ? nil : suffix)
}

func normalizedContains(_ container: CGRect, _ child: CGRect,
                        epsilon: CGFloat = 0.0000001) -> Bool {
    child.minX >= container.minX - epsilon && child.minY >= container.minY - epsilon &&
        child.maxX <= container.maxX + epsilon && child.maxY <= container.maxY + epsilon
}

func rendererGeometryAllowed(name: CGRect, count: CGRect, source: CGRect,
                             scale: CGFloat, imageWidth: Int) -> Bool {
    guard validNormalizedBox(name), validNormalizedBox(count), validNormalizedBox(source),
          normalizedContains(source, name), normalizedContains(source, count),
          abs(name.minY - count.minY) <= 0.08,
          abs(name.maxY - count.maxY) <= 0.12,
          scale.isFinite, scale >= 0.5, scale <= 4, imageWidth > 0 else { return false }
    let overlapPixels = max(0, name.maxX - count.minX) * CGFloat(imageWidth)
    return overlapPixels <= 1
}

func equivalentCountToken(_ lhs: String, _ rhs: String, expected: Int) -> Bool {
    func normalized(_ value: String) -> String {
        value.replacingOccurrences(of: "（", with: "(")
            .replacingOccurrences(of: "）", with: ")")
    }
    let pattern = try! NSRegularExpression(pattern: #"^\(([0-9]{1,5})\)$"#)
    return [lhs, rhs].allSatisfy { value in
        let text = normalized(value)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = pattern.firstMatch(in: text, range: range), match.range == range,
              let digits = Range(match.range(at: 1), in: text) else { return false }
        return Int(text[digits]) == expected
    }
}

func auxiliaryPixelVerdict(widthPoints: CGFloat, heightPoints: CGFloat,
                           pixelCount: Int, pixelArea: Int,
                           darkest: Int, nameCountDarkest: Int,
                           background: Int, maximumChannelSpread: Int,
                           opaque: Bool) -> AuxiliaryPixelVerdict {
    guard pixelCount > 0 else { return .absent }
    guard widthPoints >= 6, widthPoints <= 18, heightPoints >= 6, heightPoints <= 22,
          heightPoints > 0, widthPoints / heightPoints >= 0.5,
          widthPoints / heightPoints <= 1.5, pixelArea > 0,
          Double(pixelCount) / Double(pixelArea) >= 0.05,
          Double(pixelCount) / Double(pixelArea) <= 0.70,
          opaque, maximumChannelSpread <= 12, background >= 180,
          darkest <= background - 12,
          darkest >= nameCountDarkest + 24 else { return .rejected }
    return .observed
}

func auxiliaryComponentVerdict(componentCount: Int,
                               widthPoints: CGFloat, heightPoints: CGFloat,
                               pixelCount: Int, pixelArea: Int,
                               darkest: Int, nameCountDarkest: Int,
                               background: Int, maximumChannelSpread: Int,
                               opaque: Bool) -> AuxiliaryPixelVerdict {
    guard (1...2).contains(componentCount) else {
        return componentCount == 0 ? .absent : .rejected
    }
    return auxiliaryPixelVerdict(widthPoints: widthPoints, heightPoints: heightPoints,
                                 pixelCount: pixelCount, pixelArea: pixelArea,
                                 darkest: darkest, nameCountDarkest: nameCountDarkest,
                                 background: background,
                                 maximumChannelSpread: maximumChannelSpread,
                                 opaque: opaque)
}

func rendererSuffixPixelAllowed(rawSuffix: String?,
                                verdict: AuxiliaryPixelVerdict) -> Bool {
    verdict != .rejected && (rawSuffix == nil || verdict == .observed)
}

func rendererUITimeText(_ text: String) -> Bool {
    if text == "昨天" { return true }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    let time = try! NSRegularExpression(
        pattern: #"^(上午|下午|AM|PM)?\s*(\d{1,2}):(\d{2})$"#,
        options: [.caseInsensitive]
    )
    if let match = time.firstMatch(in: text, range: range), match.range == range,
       let hourRange = Range(match.range(at: 2), in: text),
       let minuteRange = Range(match.range(at: 3), in: text),
       let hour = Int(text[hourRange]), let minute = Int(text[minuteRange]) {
        let prefixed = match.range(at: 1).location != NSNotFound
        return minute <= 59 && (prefixed ? (1...12).contains(hour) : (0...23).contains(hour))
    }
    let monthDay = try! NSRegularExpression(pattern: #"^(\d{1,2})(月|/)(\d{1,2})日?$"#)
    guard let match = monthDay.firstMatch(in: text, range: range), match.range == range,
          let monthRange = Range(match.range(at: 1), in: text),
          let dayRange = Range(match.range(at: 3), in: text),
          let month = Int(text[monthRange]), let day = Int(text[dayRange]) else { return false }
    return (1...12).contains(month) && (1...31).contains(day)
}

func strictRendererComponentsAllowed(nameConfidence: Float, countConfidence: Float,
                                     prefixMatches: Bool, countMatches: Bool,
                                     nameSourceCoverage: Bool,
                                     countSourceCoverage: Bool,
                                     finalGapPixels: CGFloat,
                                     requiredGapPixels: CGFloat) -> Bool {
    nameConfidence >= ocrConfidenceThreshold &&
        countConfidence >= ocrConfidenceThreshold && prefixMatches && countMatches &&
        nameSourceCoverage && countSourceCoverage &&
        finalGapPixels >= requiredGapPixels
}

func strictUITimeRefinementAllowed(rawText: String, refinedText: String,
                                   refinedConfidence: Float,
                                   sourceCoverage: Bool) -> Bool {
    rendererUITimeText(rawText) && rendererUITimeText(refinedText) && rawText == refinedText &&
        refinedConfidence >= ocrConfidenceThreshold && sourceCoverage
}

func imageLuma(_ image: CGImage) throws -> [UInt8] {
    let (pixels, bytesPerRow) = try rgbaBottomUp(image)
    let topDown = topDownRows(pixels, bytesPerRow: bytesPerRow, height: image.height)
    var result = [UInt8](repeating: 0, count: image.width * image.height)
    for y in 0..<image.height {
        for x in 0..<image.width {
            let offset = y * bytesPerRow + x * 4
            let red = Int(topDown[offset]), green = Int(topDown[offset + 1])
            let blue = Int(topDown[offset + 2])
            let value = (red * 54 + green * 183 + blue * 19) / 256
            result[y * image.width + x] = UInt8(min(255, max(0, value)))
        }
    }
    return result
}

func normalizedPixelRect(_ box: CGRect, image: CGImage) -> CGRect? {
    guard validNormalizedBox(box) else { return nil }
    let raw = CGRect(x: box.minX * CGFloat(image.width),
                     y: (1 - box.maxY) * CGFloat(image.height),
                     width: box.width * CGFloat(image.width),
                     height: box.height * CGFloat(image.height)).integral
    let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    return bounds.contains(raw) && raw.width >= 1 && raw.height >= 1 ? raw : nil
}

func paddedPixelCrop(_ box: CGRect, image: CGImage, padding: CGFloat = 2,
                     minimumX: CGFloat? = nil,
                     maximumX: CGFloat? = nil) -> (CGImage, CGRect)? {
    guard padding >= 0, padding <= 2, var pixels = normalizedPixelRect(box, image: image) else { return nil }
    pixels = pixels.insetBy(dx: -padding, dy: -padding).integral
    if let minimumX {
        let oldMaxX = pixels.maxX
        pixels.origin.x = max(pixels.minX, minimumX)
        pixels.size.width = oldMaxX - pixels.minX
    }
    if let maximumX { pixels.size.width = min(pixels.width, maximumX - pixels.minX) }
    let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    pixels = pixels.intersection(bounds).integral
    guard !pixels.isNull, pixels.width >= 1, pixels.height >= 1,
          let crop = image.cropping(to: pixels) else { return nil }
    return (crop, pixels)
}

func mapCropCandidate(_ candidate: OCRCandidate, crop: CGRect,
                      imageWidth: Int, imageHeight: Int) -> OCRCandidate? {
    guard validNormalizedBox(candidate.normalizedBox), imageWidth > 0, imageHeight > 0 else { return nil }
    let box = candidate.normalizedBox
    let mapped = CGRect(
        x: (crop.minX + box.minX * crop.width) / CGFloat(imageWidth),
        y: 1 - (crop.maxY - box.minY * crop.height) / CGFloat(imageHeight),
        width: box.width * crop.width / CGFloat(imageWidth),
        height: box.height * crop.height / CGFloat(imageHeight)
    )
    guard validNormalizedBox(mapped) else { return nil }
    return OCRCandidate(text: candidate.text, confidence: candidate.confidence,
                        normalizedBox: mapped)
}

enum RendererFieldKind { case nameOrTime, count }

func rendererLanguages(_ kind: RendererFieldKind) -> [String] {
    kind == .count ? ["en-US"] : ["zh-Hant", "en-US"]
}

struct RendererFieldEvidence {
    let candidate: OCRCandidate
    let actualPixelBox: CGRect
}

func boundedOCRPixelRect(_ box: CGRect, width: Int, height: Int,
                         maximumOutside: CGFloat = 1) -> CGRect? {
    guard box.minX.isFinite, box.minY.isFinite, box.width.isFinite, box.height.isFinite,
          box.width > 0, box.height > 0, width > 0, height > 0 else { return nil }
    let raw = CGRect(x: box.minX * CGFloat(width),
                     y: (1 - box.maxY) * CGFloat(height),
                     width: box.width * CGFloat(width),
                     height: box.height * CGFloat(height))
    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
    guard max(0, -raw.minX) <= maximumOutside,
          max(0, -raw.minY) <= maximumOutside,
          max(0, raw.maxX - bounds.maxX) <= maximumOutside,
          max(0, raw.maxY - bounds.maxY) <= maximumOutside else { return nil }
    let clamped = raw.intersection(bounds)
    return !clamped.isNull && clamped.width > 0 && clamped.height > 0 ? clamped : nil
}

func actualGlyphCoverageAllowed(actual: CGRect, coarse: CGRect,
                                imageWidth: Int, imageHeight: Int) -> Bool {
    guard validNormalizedBox(actual), validNormalizedBox(coarse),
          imageWidth > 0, imageHeight > 0 else { return false }
    let leftOutside = max(0, coarse.minX - actual.minX) * CGFloat(imageWidth)
    let rightOutside = max(0, actual.maxX - coarse.maxX) * CGFloat(imageWidth)
    let bottomOutside = max(0, coarse.minY - actual.minY) * CGFloat(imageHeight)
    let topOutside = max(0, actual.maxY - coarse.maxY) * CGFloat(imageHeight)
    let intersection = actual.intersection(coarse)
    let coverage = intersection.isNull ? 0 :
        intersection.width * intersection.height / (actual.width * actual.height)
    return leftOutside <= 1 && rightOutside <= 1 && bottomOutside <= 1 &&
        topOutside <= 1 && coverage >= 0.95
}

func rendererGraphemeBoxesValid(text: String, boxes: [CGRect?]) -> Bool {
    let characters = Array(text)
    guard characters.count == boxes.count else { return false }
    return zip(characters, boxes).allSatisfy { character, box in
        character.isWhitespace ? box == nil : box != nil
    }
}

func rendererPixelGlyphBox(_ image: CGImage, ocrBox: CGRect,
                           graphemeBoxes: [CGRect?]) throws -> CGRect? {
    let width = image.width, height = image.height
    guard let boundedOCR = boundedOCRPixelRect(ocrBox, width: width, height: height) else { return nil }
    let (raw, bytesPerRow) = try rgbaBottomUp(image)
    let pixels = topDownRows(raw, bytesPerRow: bytesPerRow, height: height)
    var borderChannels = [[Int](), [Int](), [Int]()]
    for y in 0..<height { for x in 0..<width where x == 0 || y == 0 || x == width - 1 || y == height - 1 {
        let offset = y * bytesPerRow + x * 4
        guard pixels[offset + 3] == 255 else { return nil }
        for channel in 0..<3 { borderChannels[channel].append(Int(pixels[offset + channel])) }
    } }
    guard borderChannels.allSatisfy({ !$0.isEmpty }) else { return nil }
    let background = borderChannels.map { values -> Int in
        let sorted = values.sorted(); return sorted[sorted.count / 2]
    }
    guard background.max()! - background.min()! <= 1 else { return nil }
    for channel in 0..<3 where borderChannels[channel].contains(where: { abs($0 - background[channel]) > 1 }) {
        return nil
    }
    let backgroundLuma = (background[0] * 54 + background[1] * 183 + background[2] * 19) / 256
    var strong = [Bool](repeating: false, count: width * height)
    var weak = [Bool](repeating: false, count: width * height)
    for y in 0..<height { for x in 0..<width {
        let offset = y * bytesPerRow + x * 4
        guard pixels[offset + 3] == 255 else { return nil }
        let red = Int(pixels[offset]), green = Int(pixels[offset + 1]), blue = Int(pixels[offset + 2])
        guard max(red, green, blue) - min(red, green, blue) <= 12 else { return nil }
        let value = (red * 54 + green * 183 + blue * 19) / 256
        let difference = abs(value - backgroundLuma)
        if difference >= 12 { strong[y * width + x] = true }
        else if difference > 1 { weak[y * width + x] = true }
    } }
    guard strong.contains(true) else { return nil }
    var ownership = [Bool](repeating: false, count: width * height)
    var nonWhitespaceCount = 0
    for box in graphemeBoxes {
        guard let box else { continue }
        nonWhitespaceCount += 1
        guard let pixelsBox = boundedOCRPixelRect(box, width: width, height: height) else { return nil }
        let expanded = pixelsBox.insetBy(dx: -1, dy: -1)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        let iteration = expanded.integral
            .intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
        var hasStrong = false
        for y in Int(iteration.minY)..<Int(iteration.maxY) {
            for x in Int(iteration.minX)..<Int(iteration.maxX) {
                let pixel = CGRect(x: x, y: y, width: 1, height: 1)
                if expanded.contains(pixel) { ownership[y * width + x] = true }
                if strong[y * width + x],
                   pixelsBox.contains(CGPoint(x: CGFloat(x) + 0.5,
                                              y: CGFloat(y) + 0.5)) {
                    hasStrong = true
                }
            }
        }
        guard hasStrong else { return nil }
    }
    guard nonWhitespaceCount > 0 else { return nil }
    var inkIndices = [Int]()
    for index in strong.indices where strong[index] || weak[index] {
        let x = index % width, y = index / width
        guard x > 0, x < width - 1, y > 0, y < height - 1,
              ownership[index] else { return nil }
        if weak[index] {
            var attached = false
            for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                let nx = x + dx, ny = y + dy
                if nx >= 0, nx < width, ny >= 0, ny < height,
                   strong[ny * width + nx] { attached = true }
            } }
            guard attached else { return nil }
        }
        inkIndices.append(index)
    }
    guard !inkIndices.isEmpty else { return nil }
    let xs = inkIndices.map { $0 % width }, ys = inkIndices.map { $0 / width }
    let actual = CGRect(x: xs.min()!, y: ys.min()!,
                        width: xs.max()! - xs.min()! + 1,
                        height: ys.max()! - ys.min()! + 1)
    let intersection = actual.intersection(boundedOCR)
    let coverage = intersection.isNull ? 0 :
        intersection.width * intersection.height / (actual.width * actual.height)
    guard coverage >= 0.95,
          actual.minX >= boundedOCR.minX - 1, actual.maxX <= boundedOCR.maxX + 1,
          actual.minY >= boundedOCR.minY - 1, actual.maxY <= boundedOCR.maxY + 1 else { return nil }
    return actual
}

func rendererVisionRequest(_ image: CGImage, kind: RendererFieldKind) throws
    -> [VNRecognizedTextObservation] {
    let request = VNRecognizeTextRequest()
    request.revision = ocrRevision
    request.recognitionLevel = .accurate
    request.recognitionLanguages = rendererLanguages(kind)
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: image, orientation: .up, options: [:]).perform([request])
    return request.results ?? []
}

func uniqueStrictCropCandidate(_ image: CGImage,
                               kind: RendererFieldKind) throws -> RendererFieldEvidence? {
    let observations = try rendererVisionRequest(image, kind: kind)
    guard observations.count == 1, let observation = observations.first,
          let recognized = observation.topCandidates(1).first,
          recognized.confidence >= ocrConfidenceThreshold,
          !recognized.string.isEmpty else { return nil }
    var graphemeBoxes = [CGRect?]()
    for range in recognized.string.indices.map({ index in
        index..<recognized.string.index(after: index)
    }) {
        if recognized.string[range].allSatisfy({ $0.isWhitespace }) {
            graphemeBoxes.append(nil)
        } else {
            let box = try? recognized.boundingBox(for: range)
            graphemeBoxes.append(box?.boundingBox)
        }
    }
    guard rendererGraphemeBoxesValid(text: recognized.string,
                                     boxes: graphemeBoxes) else { return nil }
    guard let actualPixels = try rendererPixelGlyphBox(
        image, ocrBox: observation.boundingBox, graphemeBoxes: graphemeBoxes
    ) else { return nil }
    let normalized = CGRect(x: actualPixels.minX / CGFloat(image.width),
                            y: 1 - actualPixels.maxY / CGFloat(image.height),
                            width: actualPixels.width / CGFloat(image.width),
                            height: actualPixels.height / CGFloat(image.height))
    guard validNormalizedBox(normalized) else { return nil }
    return RendererFieldEvidence(
        candidate: OCRCandidate(text: recognized.string,
                                confidence: recognized.confidence,
                                normalizedBox: normalized),
        actualPixelBox: actualPixels
    )
}

func darkestInk(_ image: CGImage, normalizedBoxes: [CGRect], background: Int) throws -> Int? {
    let luma = try imageLuma(image)
    var darkest: Int?
    for box in normalizedBoxes {
        guard let pixels = normalizedPixelRect(box, image: image) else { return nil }
        for y in Int(pixels.minY)..<Int(pixels.maxY) {
            for x in Int(pixels.minX)..<Int(pixels.maxX) {
                let value = Int(luma[y * image.width + x])
                if value <= background - 12 { darkest = min(darkest ?? value, value) }
            }
        }
    }
    return darkest
}

func grayAuxiliaryEvidence(_ image: CGImage, countBox: CGRect, sourceBox: CGRect,
                           suffixBox: CGRect?, otherBoxes: [CGRect], scale: CGFloat,
                           nameCountDarkest: Int) throws -> AuxiliaryPixelVerdict {
    let luma = try imageLuma(image)
    let sorted = luma.sorted()
    guard let background = sorted.isEmpty ? nil : sorted[sorted.count / 2], background >= 180,
          let countPixels = normalizedPixelRect(countBox, image: image),
          let sourcePixels = normalizedPixelRect(sourceBox, image: image) else { return .rejected }
    let suffix: CGRect
    if let suffixBox {
        guard validNormalizedBox(suffixBox),
              let exact = normalizedPixelRect(suffixBox, image: image),
              exact.minX >= countPixels.maxX else { return .rejected }
        suffix = exact
    } else {
        let nearestOther = otherBoxes.compactMap { normalizedPixelRect($0, image: image)?.minX }
            .filter { $0 > countPixels.maxX }.min() ?? CGFloat(image.width)
        let endX = min(nearestOther - 1,
                       max(sourcePixels.maxX, countPixels.maxX + 18 * scale))
        let startX = countPixels.maxX + max(1, floor(scale))
        guard endX > startX else { return .absent }
        suffix = CGRect(x: startX, y: max(0, sourcePixels.minY - 2),
                        width: endX - startX,
                        height: min(CGFloat(image.height), sourcePixels.maxY + 2) -
                            max(0, sourcePixels.minY - 2)).integral
    }
    guard suffix.width > 0, suffix.height > 0 else { return .absent }
    let (raw, bytesPerRow) = try rgbaBottomUp(image)
    let pixels = topDownRows(raw, bytesPerRow: bytesPerRow, height: image.height)
    let width = Int(suffix.width), height = Int(suffix.height)
    var foreground = [Bool](repeating: false, count: width * height)
    var channelSpread = 0, allOpaque = true, darkest = 255
    for localY in 0..<height {
        for localX in 0..<width {
            let x = Int(suffix.minX) + localX, y = Int(suffix.minY) + localY
            let source = y * bytesPerRow + x * 4
            let red = Int(pixels[source]), green = Int(pixels[source + 1])
            let blue = Int(pixels[source + 2]), alpha = Int(pixels[source + 3])
            let value = (red * 54 + green * 183 + blue * 19) / 256
            if value <= background - 12 {
                foreground[localY * width + localX] = true
                channelSpread = max(channelSpread, max(red, green, blue) - min(red, green, blue))
                allOpaque = allOpaque && alpha == 255
                darkest = min(darkest, value)
            }
        }
    }
    var visited = [Bool](repeating: false, count: foreground.count)
    var components: [(Int, Int, Int, Int, Int)] = []
    for index in foreground.indices where foreground[index] && !visited[index] {
        var queue = [index], cursor = 0, minX = width, maxX = 0, minY = height, maxY = 0, count = 0
        visited[index] = true
        while cursor < queue.count {
            let current = queue[cursor]; cursor += 1
            let x = current % width, y = current / width
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y); count += 1
            for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                let next = ny * width + nx
                if foreground[next] && !visited[next] { visited[next] = true; queue.append(next) }
            } }
        }
        components.append((minX, maxX, minY, maxY, count))
    }
    guard components.count <= 2 else { return .rejected }
    guard !components.isEmpty else { return .absent }
    let unionMinX = components.map(\.0).min()!, unionMaxX = components.map(\.1).max()!
    let unionMinY = components.map(\.2).min()!, unionMaxY = components.map(\.3).max()!
    let pixelCount = components.map(\.4).reduce(0, +)
    let boxWidth = unionMaxX - unionMinX + 1, boxHeight = unionMaxY - unionMinY + 1
    return auxiliaryComponentVerdict(
        componentCount: components.count,
        widthPoints: CGFloat(boxWidth) / scale,
        heightPoints: CGFloat(boxHeight) / scale,
        pixelCount: pixelCount, pixelArea: boxWidth * boxHeight,
        darkest: darkest, nameCountDarkest: nameCountDarkest,
        background: Int(background), maximumChannelSpread: channelSpread,
        opaque: allOpaque
    )
}

func strictUITimeEvidence(_ recognized: VNRecognizedText, observation: VNRecognizedTextObservation,
                          bandImage: CGImage) throws -> Bool {
    let text = recognized.string
    let raw = OCRCandidate(text: text, confidence: recognized.confidence,
                           normalizedBox: observation.boundingBox)
    guard validNormalizedBox(raw.normalizedBox), !candidateTouchesCrop(raw),
          raw.normalizedBox.minX >= 0.70,
          rendererUITimeText(text) else { return false }
    guard let crop = paddedPixelCrop(raw.normalizedBox, image: bandImage),
          let refinedEvidence = try uniqueStrictCropCandidate(crop.0, kind: .nameOrTime),
          let refined = Optional(refinedEvidence.candidate), refined.text == text,
          let mapped = mapCropCandidate(refined, crop: crop.1,
                                        imageWidth: bandImage.width,
                                        imageHeight: bandImage.height),
          strictUITimeRefinementAllowed(
              rawText: text, refinedText: refined.text,
              refinedConfidence: refined.confidence,
              sourceCoverage: actualGlyphCoverageAllowed(
                  actual: mapped.normalizedBox, coarse: raw.normalizedBox,
                  imageWidth: bandImage.width, imageHeight: bandImage.height
              )
          ) else { return false }
    return true
}

func rendererLabelRefinement(bandImage: CGImage,
                             observations: [VNRecognizedTextObservation],
                             scale: CGFloat) throws -> RendererRefinementEvidence? {
    let values = observations.compactMap { observation -> (VNRecognizedTextObservation, VNRecognizedText)? in
        guard let candidate = observation.topCandidates(1).first,
              !candidate.string.isEmpty else { return nil }
        return (observation, candidate)
    }
    guard values.count == observations.count else { return nil }
    let left = values.filter { $0.0.boundingBox.minX <= 0.22 }
    guard left.count == 1, let source = left.first,
          let parsed = parseRendererLabel(source.1.string),
          validNormalizedBox(source.0.boundingBox) else { return nil }
    let others = values.filter { $0.0 !== source.0 }
    for other in others {
        guard validNormalizedBox(other.0.boundingBox),
              other.0.boundingBox.minX > source.0.boundingBox.minX,
              intersectionOverUnion(other.0.boundingBox, source.0.boundingBox) == 0,
              try strictUITimeEvidence(other.1, observation: other.0,
                                       bandImage: bandImage) else { return nil }
    }
    guard let nameObservation = try? source.1.boundingBox(for: parsed.prefixRange),
          let countObservation = try? source.1.boundingBox(for: parsed.countRange) else { return nil }
    let nameBox = nameObservation.boundingBox, countBox = countObservation.boundingBox
    let suffixBox: CGRect?
    if let suffixRange = parsed.suffixRange {
        guard let observation = try? source.1.boundingBox(for: suffixRange) else { return nil }
        suffixBox = observation.boundingBox
    } else { suffixBox = nil }
    guard suffixBox.map({ validNormalizedBox($0) && $0.minX >= countBox.maxX -
        1 / CGFloat(bandImage.width) }) ?? true,
          rendererGeometryAllowed(name: nameBox, count: countBox,
                                  source: source.0.boundingBox, scale: scale,
                                  imageWidth: bandImage.width),
          let countPixels = normalizedPixelRect(countBox, image: bandImage),
          let nameCrop = paddedPixelCrop(nameBox, image: bandImage,
                                         maximumX: countPixels.minX - 1),
          let refinedNameEvidence = try uniqueStrictCropCandidate(nameCrop.0, kind: .nameOrTime),
          let refinedName = Optional(refinedNameEvidence.candidate),
          let mappedName = mapCropCandidate(refinedName, crop: nameCrop.1,
                                            imageWidth: bandImage.width,
                                            imageHeight: bandImage.height),
          refinedName.text == parsed.prefix,
          let mappedNamePixels = normalizedPixelRect(mappedName.normalizedBox,
                                                      image: bandImage) else { return nil }
    let requiredGap = max(1, floor(scale))
    let suffixPixels = suffixBox.flatMap { normalizedPixelRect($0, image: bandImage) }
    guard let countCrop = paddedPixelCrop(
        countBox, image: bandImage,
        minimumX: mappedNamePixels.maxX + requiredGap,
        maximumX: suffixPixels.map { $0.minX - requiredGap }
    ),
          let refinedCountEvidence = try uniqueStrictCropCandidate(countCrop.0, kind: .count),
          let refinedCount = Optional(refinedCountEvidence.candidate),
          let mappedCount = mapCropCandidate(refinedCount, crop: countCrop.1,
                                             imageWidth: bandImage.width,
                                             imageHeight: bandImage.height),
          strictRendererComponentsAllowed(
              nameConfidence: refinedName.confidence,
              countConfidence: refinedCount.confidence,
              prefixMatches: true,
              countMatches: equivalentCountToken(
                  parsed.countToken, refinedCount.text,
                  expected: parsed.observedParenthesizedCount
              ),
              nameSourceCoverage: actualGlyphCoverageAllowed(
                  actual: mappedName.normalizedBox, coarse: nameBox,
                  imageWidth: bandImage.width, imageHeight: bandImage.height
              ),
              countSourceCoverage: actualGlyphCoverageAllowed(
                  actual: mappedCount.normalizedBox, coarse: countBox,
                  imageWidth: bandImage.width, imageHeight: bandImage.height
              ),
              finalGapPixels: (mappedCount.normalizedBox.minX -
                               mappedName.normalizedBox.maxX) * CGFloat(bandImage.width),
              requiredGapPixels: requiredGap
          ) else { return nil }
    if let suffixBox {
        let finalSuffixGap = (suffixBox.minX - mappedCount.normalizedBox.maxX) *
            CGFloat(bandImage.width)
        guard finalSuffixGap >= requiredGap else { return nil }
    }
    let luma = try imageLuma(bandImage).sorted()
    guard let background = luma.isEmpty ? nil : luma[luma.count / 2],
          let nameCountDarkest = try darkestInk(bandImage,
                                               normalizedBoxes: [mappedName.normalizedBox,
                                                                 mappedCount.normalizedBox],
                                               background: Int(background)) else { return nil }
    let auxiliary = try grayAuxiliaryEvidence(
        bandImage, countBox: mappedCount.normalizedBox, sourceBox: source.0.boundingBox,
        suffixBox: suffixBox, otherBoxes: others.map { $0.0.boundingBox }, scale: scale,
        nameCountDarkest: nameCountDarkest
    )
    guard rendererSuffixPixelAllowed(rawSuffix: parsed.rawSuffix,
                                     verdict: auxiliary) else { return nil }
    return RendererRefinementEvidence(
        candidate: OCRCandidate(text: parsed.prefix,
                                confidence: min(refinedName.confidence, refinedCount.confidence),
                                normalizedBox: mappedName.normalizedBox),
        observedParenthesizedCount: parsed.observedParenthesizedCount,
        auxiliaryObserved: auxiliary == .observed,
        identityVerified: false
    )
}

struct PrimerPrefixRow {
    let index: Int
    let frame: CGRect?
}

struct PrimerObservedRow {
    let role: String
    let index: Int?
    let frame: CGRect?
}

struct PrimerGeometry {
    let pitch: CGFloat
    let points: [CGPoint]
}

struct PrimerHitProof {
    let slot: Int
    let pid: Int
    let listID: Int
    let ancestryDepth: Int
    let directBlank: Bool
    let rowID: Int?
    let index: Int?
    let frame: CGRect?
}

struct PrimerFinalRow {
    let rowID: Int
    let index: Int
    let frame: CGRect
}

struct FreshVisibleRowModel {
    let rowID: Int
    let role: String
    let index: Int
    let frame: CGRect
}

struct VisibleRowReceiptItem {
    let element: AXUIElement
    let index: Int
    let frame: CGRect
}

struct VisibleRowsReceipt {
    let rows: [VisibleRowReceiptItem]
}

func freshVisibleModelValid(_ rows: [FreshVisibleRowModel],
                            listFrame: CGRect, windowFrame: CGRect) -> Bool {
    guard !rows.isEmpty, rows.count <= 20,
          Set(rows.map(\.rowID)).count == rows.count,
          rows.map(\.index) == Array(0..<rows.count),
          rows.allSatisfy({ $0.role == kAXRowRole }),
          let pitch = rows.first?.frame.height, pitch >= 18, pitch <= 160 else { return false }
    return rows.allSatisfy {
        primerFrameMatches($0.frame, slot: $0.index, pitch: pitch,
                           listFrame: listFrame, windowFrame: windowFrame)
    }
}

func freshModelCanSkipPrimer(advertisedCount: Int, modelValid: Bool) -> Bool {
    (1...20).contains(advertisedCount) && modelValid
}

func freshVisibleModelsStable(_ first: [PrimerFinalRow],
                              _ second: [PrimerFinalRow]) -> Bool {
    first.count == second.count && zip(first, second).allSatisfy {
        $0.rowID == $1.rowID && $0.index == $1.index &&
            similar($0.frame, $1.frame, tolerance: 0.5)
    }
}

func freshReceiptOrderStable(_ first: [AXUIElement],
                             _ second: [AXUIElement]) -> Bool {
    first.count == second.count && zip(first, second).allSatisfy { CFEqual($0, $1) }
}

func visibleReceiptConsumerValid(receipt: [PrimerFinalRow],
                                 axRows: [PrimerFinalRow],
                                 visibleRows: [PrimerFinalRow],
                                 advertisedCount: Int,
                                 dense: Bool, allVisible: Bool) -> Bool {
    guard !receipt.isEmpty, advertisedCount == receipt.count,
          axRows.count == receipt.count, visibleRows.count == receipt.count,
          dense, allVisible else { return false }
    return freshVisibleModelsStable(receipt, axRows) &&
        freshVisibleModelsStable(receipt, visibleRows)
}

func primerBudgetOpen(deadline: TimeInterval,
                      now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
    now < deadline
}

func primerPrefixSeeds(_ observed: [PrimerObservedRow], listFrame: CGRect,
                       windowFrame: CGRect) throws -> [PrimerPrefixRow] {
    var seeds = [PrimerPrefixRow]()
    for row in observed {
        if row.role.isEmpty { continue }
        guard row.role == kAXRowRole else {
            throw NativeFailure("SEMANTIC_PARTIAL", "primer AXRows prefix 含已知非 row")
        }
        guard let index = row.index, index >= 0, let frame = row.frame,
              frame.width > 0, frame.height >= 18, frame.height <= 160,
              listFrame.contains(frame), windowFrame.contains(frame),
              abs(frame.minX - listFrame.minX) <= 0.5,
              abs(frame.width - listFrame.width) <= 0.5 else { continue }
        seeds.append(PrimerPrefixRow(index: index, frame: frame))
    }
    return seeds
}

func primerFrameMatches(_ frame: CGRect, slot: Int, pitch: CGFloat,
                        listFrame: CGRect, windowFrame: CGRect) -> Bool {
    frame.width > 0 && frame.height >= 18 && frame.height <= 160 &&
        listFrame.contains(frame) && windowFrame.contains(frame) &&
        abs(frame.minX - listFrame.minX) <= 0.5 &&
        abs(frame.width - listFrame.width) <= 0.5 &&
        abs(frame.height - pitch) <= 0.5 &&
        abs(frame.minY - (listFrame.minY + CGFloat(slot) * pitch)) <= 0.5
}

func derivePrimerGeometry(listFrame: CGRect, windowFrame: CGRect,
                          prefix: [PrimerPrefixRow]) throws -> PrimerGeometry {
    guard listFrame.width > 0, listFrame.height > 0, windowFrame.contains(listFrame) else {
        throw NativeFailure("SEMANTIC_PARTIAL", "primer 清單幾何不可靠")
    }
    let candidates = prefix.compactMap { row -> (Int, CGRect)? in
        guard row.index >= 0, let frame = row.frame,
              frame.width > 0, frame.height >= 18, frame.height <= 160,
              listFrame.contains(frame), windowFrame.contains(frame),
              abs(frame.minX - listFrame.minX) <= 0.5,
              abs(frame.width - listFrame.width) <= 0.5 else { return nil }
        return (row.index, frame)
    }
    guard candidates.count >= 2,
          Set(candidates.map(\.0)).count == candidates.count,
          let pitch = candidates.first?.1.height else {
        throw NativeFailure("SEMANTIC_PARTIAL", "primer 缺少可證格線列")
    }
    let slotLimit = Int(floor(listFrame.height / pitch))
    guard pitch >= 18, pitch <= 160, slotLimit > 0,
          candidates.allSatisfy({ item in
              let rawSlot = (item.1.minY - listFrame.minY) / pitch
              let slot = Int(round(rawSlot))
              return abs(item.1.height - pitch) <= 0.5 && slot >= 0 && slot < slotLimit &&
                  abs(item.1.minY - (listFrame.minY + CGFloat(slot) * pitch)) <= 0.5
          }) else {
        throw NativeFailure("SEMANTIC_PARTIAL", "primer 列高或頂端格線不一致")
    }
    let slots = min(20, slotLimit)
    let points = (0..<slots).map { slot in
        CGPoint(x: listFrame.minX + pitch * 1.15,
                y: listFrame.minY + CGFloat(slot) * pitch + pitch * 0.22)
    }
    guard !points.isEmpty,
          points.allSatisfy({ listFrame.contains($0) && windowFrame.contains($0) }) else {
        throw NativeFailure("SEMANTIC_PARTIAL", "primer hit-test 點超出清單")
    }
    return PrimerGeometry(pitch: pitch, points: points)
}

func primerModelComplete(geometry: PrimerGeometry, listFrame: CGRect, windowFrame: CGRect,
                         expectedPID: Int, expectedListID: Int,
                         hits: [PrimerHitProof], finalCount: Int,
                         finalRows: [PrimerFinalRow]) -> Bool {
    guard !geometry.points.isEmpty, geometry.points.count <= 20,
          hits.count == geometry.points.count,
          hits.map(\.slot).sorted() == Array(geometry.points.indices),
          hits.allSatisfy({ $0.pid == expectedPID && $0.listID == expectedListID &&
              $0.ancestryDepth >= 0 && $0.ancestryDepth <= 6 }) else { return false }
    var rowIDs = [Int]()
    for hit in hits {
        if hit.directBlank {
            guard hit.rowID == nil, hit.index == nil, hit.frame == nil else { return false }
            continue
        }
        guard let rowID = hit.rowID, let index = hit.index, let frame = hit.frame,
              index == hit.slot,
              primerFrameMatches(frame, slot: index, pitch: geometry.pitch,
                                 listFrame: listFrame, windowFrame: windowFrame) else { return false }
        rowIDs.append(rowID)
    }
    guard !rowIDs.isEmpty, rowIDs.count <= 20, Set(rowIDs).count == rowIDs.count,
          finalCount == rowIDs.count, finalRows.count == finalCount,
          finalRows.map(\.index).sorted() == Array(0..<finalCount),
          Set(finalRows.map(\.rowID)) == Set(rowIDs),
          Set(finalRows.map(\.rowID)).count == finalRows.count,
          finalRows.allSatisfy({
              primerFrameMatches($0.frame, slot: $0.index, pitch: geometry.pitch,
                                 listFrame: listFrame, windowFrame: windowFrame)
          }) else { return false }
    return true
}

func passivePrimeVisibleRows(appElement: AXUIElement, list: AXUIElement,
                             listFrame: CGRect, expected: WindowIdentity) throws -> VisibleRowsReceipt {
    let deadline = ProcessInfo.processInfo.systemUptime + 1
    func requireBudget(reserving interval: TimeInterval = 0) throws {
        guard primerBudgetOpen(deadline: deadline,
                               now: ProcessInfo.processInfo.systemUptime + interval) else {
            throw NativeFailure("PRIMER_TIMEOUT", "Qt 可見列 primer 超過一秒預算")
        }
    }
    func boundedRole(_ element: AXUIElement) throws -> String {
        try requireBudget(reserving: 0.2)
        let value = stringAttribute(element, kAXRoleAttribute)
        try requireBudget()
        return value
    }
    func boundedFrame(_ element: AXUIElement) throws -> CGRect? {
        try requireBudget(reserving: 0.2)
        let point = pointAttribute(element, kAXPositionAttribute)
        try requireBudget(reserving: 0.2)
        let size = sizeAttribute(element, kAXSizeAttribute)
        try requireBudget()
        guard let point, let size else { return nil }
        return CGRect(origin: point, size: size)
    }
    func boundedIndex(_ element: AXUIElement) throws -> Int? {
        try requireBudget(reserving: 0.2)
        let value = (copyAttribute(element, "AXIndex") as? NSNumber)?.intValue
        try requireBudget()
        return value
    }
    func boundedParent(_ element: AXUIElement) throws -> AXUIElement? {
        try requireBudget(reserving: 0.2)
        let raw = copyAttribute(element, kAXParentAttribute)
        try requireBudget()
        guard let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }
    func receiptFrom(_ elements: [AXUIElement],
                     reference: [VisibleRowReceiptItem]? = nil) throws -> VisibleRowsReceipt? {
        guard !elements.isEmpty, elements.count <= 20 else { return nil }
        var items = [VisibleRowReceiptItem](), model = [FreshVisibleRowModel]()
        for (position, element) in elements.enumerated() {
            guard try boundedRole(element) == kAXRowRole,
                  let index = try boundedIndex(element),
                  let frame = try boundedFrame(element) else { return nil }
            let rowID: Int
            if let reference {
                guard let match = reference.firstIndex(where: { CFEqual($0.element, element) }) else {
                    return nil
                }
                rowID = match
            } else { rowID = position }
            items.append(VisibleRowReceiptItem(element: element, index: index, frame: frame))
            model.append(FreshVisibleRowModel(rowID: rowID, role: kAXRowRole,
                                              index: index, frame: frame))
        }
        guard items.indices.allSatisfy({ index in
            !items[..<index].contains(where: { CFEqual($0.element, items[index].element) })
        }),
              freshVisibleModelValid(model, listFrame: listFrame,
                                     windowFrame: expected.bounds) else { return nil }
        return VisibleRowsReceipt(rows: items)
    }
    try requireBudget(reserving: 0.2)
    guard AXUIElementSetMessagingTimeout(appElement, 0.2) == .success else {
        throw NativeFailure("SEMANTIC_PARTIAL", "無法設定有界 AX IPC timeout")
    }
    func freshList() throws -> (AXUIElement, AXUIElement) {
        try requireBudget(reserving: 0.2)
        let (_, freshApp, window, identity) = try mainWindow(requireForeground: true)
        try requireBudget()
        guard sameWindow(expected, identity) else {
            throw NativeFailure("WINDOW_CHANGED", "primer 期間主窗漂移")
        }
        try requireBudget(reserving: 0.01)
        let remaining = min(0.2, deadline - ProcessInfo.processInfo.systemUptime)
        let tree = snapshot(window, mode: .geometryOnly, deadline: remaining)
        let layout = try readTabLayout(tree, window: identity)
        let fresh = tree.nodes[layout.leftListIndex].element
        guard let frame = try boundedFrame(fresh), CFEqual(fresh, list),
              similar(frame, listFrame, tolerance: 0.5) else {
            throw NativeFailure("WINDOW_CHANGED", "primer 期間左側清單漂移")
        }
        return (freshApp, fresh)
    }
    let (freshApp, fresh) = try freshList()
    try requireBudget(reserving: 0.2)
    guard AXUIElementSetMessagingTimeout(freshApp, 0.2) == .success else {
        throw NativeFailure("SEMANTIC_PARTIAL", "無法設定 fresh AX IPC timeout")
    }
    var prefixCount: CFIndex = 0
    try requireBudget(reserving: 0.2)
    guard AXUIElementGetAttributeValueCount(fresh, kAXRowsAttribute as CFString,
                                            &prefixCount) == .success,
          prefixCount > 0, prefixCount <= 5_000 else {
        throw NativeFailure("SEMANTIC_PARTIAL", "primer AXRows count 不可靠")
    }
    let prefixLimit = min(prefixCount, 20)
    var rawPrefix: CFArray?
    try requireBudget(reserving: 0.2)
    guard AXUIElementCopyAttributeValues(fresh, kAXRowsAttribute as CFString, 0,
                                         prefixLimit, &rawPrefix) == .success,
          let prefixRows = rawPrefix as? [AXUIElement], prefixRows.count == prefixLimit else {
        throw NativeFailure("SEMANTIC_PARTIAL", "primer 無法讀取有界 AXRows prefix")
    }
    let firstReceipt = prefixCount <= 20 ? try receiptFrom(prefixRows) : nil
    if freshModelCanSkipPrimer(advertisedCount: Int(prefixCount),
                               modelValid: firstReceipt != nil),
       let firstReceipt {
        let (_, secondList) = try freshList()
        var secondCount: CFIndex = 0
        try requireBudget(reserving: 0.2)
        guard AXUIElementGetAttributeValueCount(secondList, kAXRowsAttribute as CFString,
                                                &secondCount) == .success,
              secondCount == firstReceipt.rows.count else {
            throw NativeFailure("SEMANTIC_PARTIAL", "fresh visible model count 漂移")
        }
        var rawSecond: CFArray?
        try requireBudget(reserving: 0.2)
        guard AXUIElementCopyAttributeValues(secondList, kAXRowsAttribute as CFString, 0,
                                             secondCount, &rawSecond) == .success,
              let secondRows = rawSecond as? [AXUIElement],
              secondRows.count == secondCount,
              let secondReceipt = try receiptFrom(secondRows,
                                                  reference: firstReceipt.rows) else {
            throw NativeFailure("SEMANTIC_PARTIAL", "fresh visible model 二讀漂移")
        }
        guard freshReceiptOrderStable(firstReceipt.rows.map(\.element),
                                      secondReceipt.rows.map(\.element)) else {
            throw NativeFailure("SEMANTIC_PARTIAL", "fresh visible model CF順序漂移")
        }
        let firstModel = firstReceipt.rows.enumerated().map {
            PrimerFinalRow(rowID: $0.offset, index: $0.element.index,
                           frame: $0.element.frame)
        }
        let secondModel = secondReceipt.rows.enumerated().map {
            PrimerFinalRow(rowID: $0.offset, index: $0.element.index,
                           frame: $0.element.frame)
        }
        guard freshVisibleModelsStable(firstModel, secondModel) else {
            throw NativeFailure("SEMANTIC_PARTIAL", "fresh visible model 順序或幾何漂移")
        }
        return secondReceipt
    }
    var observedPrefix = [PrimerObservedRow]()
    for row in prefixRows {
        let role = try boundedRole(row)
        if role.isEmpty {
            observedPrefix.append(PrimerObservedRow(role: "", index: nil, frame: nil))
        } else if role == kAXRowRole {
            observedPrefix.append(PrimerObservedRow(role: role,
                                                     index: try boundedIndex(row),
                                                     frame: try boundedFrame(row)))
        } else {
            observedPrefix.append(PrimerObservedRow(role: role, index: nil, frame: nil))
        }
    }
    let prefix = try primerPrefixSeeds(observedPrefix, listFrame: listFrame,
                                       windowFrame: expected.bounds)
    let geometry = try derivePrimerGeometry(listFrame: listFrame,
                                             windowFrame: expected.bounds, prefix: prefix)
    var actualRows = [AXUIElement]()
    var hits = [PrimerHitProof]()
    for (slot, point) in geometry.points.enumerated() {
        try requireBudget(reserving: 0.2)
        var rawHit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(freshApp, Float(point.x), Float(point.y),
                                               &rawHit) == .success,
              let hit = rawHit else {
            throw NativeFailure("SEMANTIC_PARTIAL", "primer hit-test 無法讀取")
        }
        var pid: pid_t = 0
        try requireBudget(reserving: 0.2)
        guard AXUIElementGetPid(hit, &pid) == .success, pid == expected.pid else {
            throw NativeFailure("SEMANTIC_PARTIAL", "primer hit-test PID 不符")
        }
        if CFEqual(hit, fresh) {
            hits.append(PrimerHitProof(slot: slot, pid: Int(pid), listID: 1,
                                       ancestryDepth: 0, directBlank: true,
                                       rowID: nil, index: nil, frame: nil))
            continue
        }
        var current = hit
        var rowElement: AXUIElement?, rowFrame: CGRect?, rowIndex: Int?
        var reachedList = false, reachedDepth = 0
        for depth in 0..<6 {
            if try boundedRole(current) == kAXRowRole, rowElement == nil {
                rowElement = current
                rowFrame = try boundedFrame(current)
                rowIndex = try boundedIndex(current)
            }
            guard let parent = try boundedParent(current) else { break }
            if CFEqual(parent, fresh) {
                reachedList = true; reachedDepth = depth + 1; break
            }
            current = parent
        }
        guard reachedList, let row = rowElement, let frame = rowFrame, let index = rowIndex,
              index == slot,
              primerFrameMatches(frame, slot: slot, pitch: geometry.pitch,
                                 listFrame: listFrame, windowFrame: expected.bounds) else {
            throw NativeFailure("SEMANTIC_PARTIAL", "primer hit-test row 證據不完整")
        }
        let rowID: Int
        if let existing = actualRows.firstIndex(where: { CFEqual($0, row) }) { rowID = existing }
        else { actualRows.append(row); rowID = actualRows.count - 1 }
        hits.append(PrimerHitProof(slot: slot, pid: Int(pid), listID: 1,
                                   ancestryDepth: reachedDepth, directBlank: false,
                                   rowID: rowID, index: index, frame: frame))
    }
    _ = try freshList()
    var finalCountRaw: CFIndex = 0
    try requireBudget(reserving: 0.2)
    guard AXUIElementGetAttributeValueCount(fresh, kAXRowsAttribute as CFString,
                                            &finalCountRaw) == .success,
          finalCountRaw > 0, finalCountRaw <= 20,
          finalCountRaw == actualRows.count else {
        throw NativeFailure("SEMANTIC_PARTIAL", "primer final AXRows count 不符")
    }
    var rawFinal: CFArray?
    try requireBudget(reserving: 0.2)
    guard AXUIElementCopyAttributeValues(fresh, kAXRowsAttribute as CFString, 0,
                                         finalCountRaw, &rawFinal) == .success,
          let finalElements = rawFinal as? [AXUIElement],
          finalElements.count == finalCountRaw else {
        throw NativeFailure("SEMANTIC_PARTIAL", "primer final AXRows 無法完整讀取")
    }
    var finalRows = [PrimerFinalRow]()
    for element in finalElements {
        guard try boundedRole(element) == kAXRowRole,
              let frame = try boundedFrame(element),
              let index = try boundedIndex(element),
              let rowID = actualRows.firstIndex(where: { CFEqual($0, element) }) else {
            throw NativeFailure("SEMANTIC_PARTIAL", "primer final row 證據不完整")
        }
        finalRows.append(PrimerFinalRow(rowID: rowID, index: index, frame: frame))
    }
    guard primerModelComplete(geometry: geometry, listFrame: listFrame,
                              windowFrame: expected.bounds, expectedPID: Int(expected.pid),
                              expectedListID: 1, hits: hits,
                              finalCount: Int(finalCountRaw), finalRows: finalRows),
          actualRows.allSatisfy({ row in finalElements.contains(where: { CFEqual($0, row) }) }),
          finalElements.allSatisfy({ row in actualRows.contains(where: { CFEqual($0, row) }) }) else {
        throw NativeFailure("SEMANTIC_PARTIAL", "primer final dense row model 不一致")
    }
    return VisibleRowsReceipt(rows: zip(finalElements, finalRows).map {
        VisibleRowReceiptItem(element: $0.0, index: $0.1.index, frame: $0.1.frame)
    })
}

func visibleChatRows(_ list: AXUIElement, listFrame: CGRect,
                     window: WindowIdentity) throws -> [(AXUIElement, CGRect)] {
    let tree = snapshot(list, mode: .structure)
    guard !tree.partial else { throw NativeFailure("SEMANTIC_PARTIAL", "聊天室列結構不完整") }
    let rows = tree.nodes.compactMap { node -> (AXUIElement, CGRect)? in
        guard node.role == kAXRowRole, let frame = node.frame,
              frame.width >= 100, frame.height >= 18, frame.height <= 160,
              listFrame.contains(frame), window.bounds.contains(frame) else { return nil }
        return (node.element, frame)
    }.reduce(into: [(AXUIElement, CGRect)]()) { values, row in
        if !values.contains(where: { CFEqual($0.0, row.0) }) { values.append(row) }
    }.sorted { $0.1.minY < $1.1.minY }
    guard !rows.isEmpty, rows.count <= 20 else {
        throw NativeFailure("SEMANTIC_UNRELIABLE", "可見聊天室列數不可靠")
    }
    return rows
}

struct NameProbeIdleProof {
    let searchElement: AXUIElement
    let listElement: AXUIElement
    let searchFrame: CGRect
    let listFrame: CGRect
}

func nameProbeIdleGeometryAllowed(searchFrame: CGRect, listFrame: CGRect,
                                  searchValue: String) -> Bool {
    searchValue.isEmpty && searchFrame.width > 0 && searchFrame.height > 0 &&
        listFrame.width > 0 && listFrame.height > 0 && searchFrame.maxY <= listFrame.minY
}

func nameProbeIdleProof(_ tree: Snapshot, layout: ReadTabLayout) throws -> NameProbeIdleProof {
    guard !tree.partial else { throw NativeFailure("SEMANTIC_PARTIAL", "名稱探針 Idle AX snapshot partial") }
    let search = tree.nodes[layout.searchFieldIndex]
    let list = tree.nodes[layout.leftListIndex]
    guard search.role == kAXTextFieldRole, let searchFrame = search.frame,
          let listFrame = list.frame,
          let rawValue = copyAttribute(search.element, kAXValueAttribute),
          let value = rawValue as? String,
          nameProbeIdleGeometryAllowed(searchFrame: searchFrame,
                                       listFrame: listFrame,
                                       searchValue: value) else {
        throw NativeFailure("NAME_PROBE_NOT_IDLE", "名稱探針只允許空搜尋欄 Idle 版面")
    }
    return NameProbeIdleProof(searchElement: search.element, listElement: list.element,
                              searchFrame: searchFrame, listFrame: listFrame)
}

@available(macOS 14.0, *)
func captureNameBandSample(_ target: String, expected: WindowIdentity) throws -> NameBandSample {
    let (_, appElement, window, identity) = try mainWindow(requireForeground: true)
    guard sameWindow(expected, identity) else { throw NativeFailure("WINDOW_CHANGED", "名稱探針視窗已漂移") }
    let geometryTree = snapshot(window, mode: .geometryOnly)
    let layout = try readTabLayout(geometryTree, window: identity)
    let initialIdle = try nameProbeIdleProof(geometryTree, layout: layout)
    guard identity.bounds.contains(initialIdle.listFrame) else {
        throw NativeFailure("SEMANTIC_UNRELIABLE", "名稱探針清單幾何不可靠")
    }
    let rowReceipt = try passivePrimeVisibleRows(appElement: appElement,
                                                 list: initialIdle.listElement,
                                                 listFrame: initialIdle.listFrame,
                                                 expected: identity)
    let (_, _, freshWindow, freshIdentity) = try mainWindow(requireForeground: true)
    guard sameWindow(identity, freshIdentity) else { throw NativeFailure("WINDOW_CHANGED", "primer 後主窗漂移") }
    let freshTree = snapshot(freshWindow, mode: .geometryOnly)
    let freshLayout = try readTabLayout(freshTree, window: freshIdentity)
    let freshIdle = try nameProbeIdleProof(freshTree, layout: freshLayout)
    guard CFEqual(initialIdle.listElement, freshIdle.listElement),
          similar(initialIdle.listFrame, freshIdle.listFrame, tolerance: 0.5) else {
        throw NativeFailure("WINDOW_CHANGED", "primer 後 Idle 清單漂移")
    }
    let listFrame = freshIdle.listFrame
    let rows = try visibleChatRows(freshIdle.listElement, listFrame: listFrame, window: identity)
    let axRows = copyAttribute(freshIdle.listElement, kAXRowsAttribute) as? [AXUIElement] ?? []
    var advertised: CFIndex = 0
    let advertisedStatus = AXUIElementGetAttributeValueCount(
        freshIdle.listElement, kAXRowsAttribute as CFString, &advertised
    )
    let indices = axRows.compactMap { (copyAttribute($0, "AXIndex") as? NSNumber)?.intValue }
    let dense = indices == Array(0..<axRows.count)
    let allVisible = axRows.count == rows.count && axRows.allSatisfy {
        guard let frame = frameAttribute($0) else { return false }
        return listFrame.contains(frame) && identity.bounds.contains(frame)
    }
    let receiptModel = rowReceipt.rows.enumerated().map {
        PrimerFinalRow(rowID: $0.offset, index: $0.element.index,
                       frame: $0.element.frame)
    }
    func currentAXModel() -> [PrimerFinalRow]? {
        guard axRows.count == rowReceipt.rows.count else { return nil }
        var result = [PrimerFinalRow]()
        for (position, element) in axRows.enumerated() {
            guard stringAttribute(element, kAXRoleAttribute) == kAXRowRole,
                  let index = (copyAttribute(element, "AXIndex") as? NSNumber)?.intValue,
                  let frame = frameAttribute(element),
                  CFEqual(rowReceipt.rows[position].element, element) else { return nil }
            result.append(PrimerFinalRow(rowID: position, index: index, frame: frame))
        }
        return result
    }
    func currentVisibleModel() -> [PrimerFinalRow]? {
        guard rows.count == rowReceipt.rows.count else { return nil }
        var result = [PrimerFinalRow]()
        for (position, row) in rows.enumerated() {
            guard CFEqual(rowReceipt.rows[position].element, row.0) else { return nil }
            result.append(PrimerFinalRow(rowID: position,
                                         index: rowReceipt.rows[position].index,
                                         frame: row.1))
        }
        return result
    }
    let axModel = currentAXModel(), visibleModel = currentVisibleModel()
    guard advertisedStatus == .success, let axModel, let visibleModel,
          visibleReceiptConsumerValid(receipt: receiptModel, axRows: axModel,
                                      visibleRows: visibleModel,
                                      advertisedCount: Int(advertised),
                                      dense: dense, allVisible: allVisible) else {
        throw NativeFailure("SEMANTIC_PARTIAL", "名稱OCR前可見列receipt驗證失敗")
    }
    let image = try captureWindowImage(identity, roi: listFrame, opaqueForRead: true)
    let whole = CaptureGeometry(window: identity.bounds, roi: listFrame,
                                imageWidth: image.width, imageHeight: image.height)
    let scale = whole.scaleX
    var bandInvalid = 0, candidateInvalid = 0
    var targets: [(OCRCandidate, CGRect, RendererRefinementEvidence?)] = []
    var profiles: [ReadColorProfile] = []
    for (_, row) in rows {
        let rowGeometry = CaptureGeometry(window: identity.bounds, roi: row,
                                          imageWidth: image.width, imageHeight: image.height)
        guard let rowImage = image.cropping(to: try rowGeometry.roiPixels()) else {
            throw NativeFailure("OCR_ROI_FAILED", "無法在記憶體裁切聊天室列")
        }
        let canonical = try canonicalReadROI(rowImage)
        profiles.append(canonical.profile)
        guard let band = titleBandCrop(luma: try imageLuma(canonical.image),
                                       width: canonical.image.width,
                                       height: canonical.image.height, scale: scale),
              let bandImage = canonical.image.cropping(to: band) else {
            bandInvalid += 1; continue
        }
        let observations = try visionRequest(bandImage)
        let candidates = observations.compactMap { observation -> OCRCandidate? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : OCRCandidate(text: text, confidence: candidate.confidence,
                                                     normalizedBox: observation.boundingBox)
        }
        let literal = verifiedNameCandidate(candidates)
        let renderer = try rendererLabelRefinement(bandImage: bandImage,
                                                   observations: observations, scale: scale)
        guard let choice = chooseRendererRowCandidate(literal: literal,
                                                      renderer: renderer,
                                                      target: target) else {
            candidateInvalid += 1; continue
        }
        let name = choice.candidate
        if name.text == target {
            let box = name.normalizedBox
            let rect = CGRect(x: row.minX + (band.minX + box.minX * band.width) / scale,
                              y: row.minY + (band.minY + (1 - box.maxY) * band.height) / scale,
                              width: box.width * band.width / scale,
                              height: box.height * band.height / scale)
            targets.append((name, rect, choice.rendererChosen ? renderer : nil))
        }
    }
    let exact = targets.count == 1 ? targets[0] : nil
    let (_, _, finalWindow, finalIdentity) = try mainWindow(requireForeground: true)
    guard sameWindow(identity, finalIdentity) else { throw NativeFailure("WINDOW_CHANGED", "名稱探針後主窗漂移") }
    let finalTree = snapshot(finalWindow, mode: .geometryOnly)
    let finalLayout = try readTabLayout(finalTree, window: finalIdentity)
    let finalIdle = try nameProbeIdleProof(finalTree, layout: finalLayout)
    guard CFEqual(freshIdle.listElement, finalIdle.listElement),
          similar(freshIdle.listFrame, finalIdle.listFrame, tolerance: 0.5) else {
        throw NativeFailure("WINDOW_CHANGED", "名稱探針後 Idle 清單漂移")
    }
    return NameBandSample(identity: identity, listElement: freshIdle.listElement, listFrame: listFrame,
                          rowElements: rows.map(\.0), rowFrames: rows.map(\.1),
                          imageWidth: image.width, imageHeight: image.height,
                          rowProfiles: profiles,
                          target: exact?.0, targetRendererEvidence: exact?.2,
                          targetScreenRect: exact?.1,
                          targetObservedCount: targets.count,
                          visibleRowCount: rows.count,
                          invalidRowCount: bandInvalid + candidateInvalid,
                          bandInvalidRowCount: bandInvalid,
                          candidateInvalidRowCount: candidateInvalid,
                          axRowsCount: axRows.count,
                          advertisedRowCount: advertisedStatus == .success ? Int(advertised) : nil,
                          denseIndices: dense, allRowsVisible: allVisible)
}

func stableNameBandGeometry(_ first: NameBandSample, _ second: NameBandSample) -> Bool {
    sameWindow(first.identity, second.identity) && CFEqual(first.listElement, second.listElement) &&
        similar(first.listFrame, second.listFrame, tolerance: 0.5) &&
        first.imageWidth == second.imageWidth && first.imageHeight == second.imageHeight &&
        first.rowProfiles == second.rowProfiles &&
        first.rowElements.count == second.rowElements.count &&
        zip(first.rowElements, second.rowElements).allSatisfy { CFEqual($0.0, $0.1) } &&
        zip(first.rowFrames, second.rowFrames).allSatisfy { similar($0.0, $0.1, tolerance: 0.5) }
}

func stableRendererEvidence(_ first: RendererRefinementEvidence?,
                            _ second: RendererRefinementEvidence?) -> Bool {
    switch (first, second) {
    case (nil, nil): return true
    case let (a?, b?):
        return a.candidate.text == b.candidate.text &&
            a.observedParenthesizedCount == b.observedParenthesizedCount &&
            a.auxiliaryObserved == b.auxiliaryObserved &&
            !a.identityVerified && !b.identityVerified &&
            intersectionOverUnion(a.candidate.normalizedBox,
                                   b.candidate.normalizedBox) >= 0.80
    default: return false
    }
}

func probeReadChatTitles(_ args: [String: Any], liveScope: LiveScope?) throws -> [String: Any] {
    guard #available(macOS 14.0, *), let scope = liveScope, let tabName = scope.tabName,
          args["tabName"] as? String == tabName,
          args["chatName"] as? String == scope.chatName else {
        throw NativeFailure("LIVE_SCOPE_DENIED", "名稱探針必須綁定 exact live scope")
    }
    let selected = try verifyReadSelectedTab(tabName).0
    let first = try captureNameBandSample(scope.chatName, expected: selected.frame.identity)
    Thread.sleep(forTimeInterval: 0.06)
    let second = try captureNameBandSample(scope.chatName, expected: selected.frame.identity)
    let selectedAfter = try verifyReadSelectedTab(tabName).0
    guard stableReadColorProfile(selected.profile, selectedAfter.profile),
          sameWindow(selected.frame.identity, selectedAfter.frame.identity),
          stableNameBandGeometry(first, second),
          stableRendererEvidence(first.targetRendererEvidence,
                                 second.targetRendererEvidence) else {
        throw NativeFailure("WINDOW_CHANGED", "名稱探針兩張證據不一致")
    }
    var reasons: [String] = []
    if first.axRowsCount != second.axRowsCount ||
       first.advertisedRowCount != second.advertisedRowCount ||
       first.denseIndices != second.denseIndices || first.allRowsVisible != second.allRowsVisible {
        reasons.append("ROW_METADATA_DRIFT")
    }
    if first.bandInvalidRowCount > 0 || second.bandInvalidRowCount > 0 {
        reasons.append("NAME_BAND_UNVERIFIED")
    }
    if first.candidateInvalidRowCount > 0 || second.candidateInvalidRowCount > 0 {
        reasons.append("NAME_CANDIDATE_UNVERIFIED")
    }
    let exactCount = first.targetObservedCount == second.targetObservedCount
        ? first.targetObservedCount : 0
    if first.targetObservedCount != second.targetObservedCount { reasons.append("TARGET_COUNT_DRIFT") }
    if first.targetObservedCount > 1 || second.targetObservedCount > 1 { reasons.append("AMBIGUOUS_NAME") }
    var confidence: Double = 0
    var stable = false
    if let a = first.target, let b = second.target,
       let ar = first.targetScreenRect, let br = second.targetScreenRect,
       a.confidence >= ocrConfidenceThreshold, b.confidence >= ocrConfidenceThreshold {
        confidence = Double(min(a.confidence, b.confidence))
        stable = intersectionOverUnion(ar, br) >= 0.80
        if !stable { reasons.append("NAME_BBOX_DRIFT") }
    } else if first.targetObservedCount <= 1 && second.targetObservedCount <= 1 {
        reasons.append("NAME_NOT_OBSERVED")
    }
    let pass = reasons.isEmpty && exactCount == 1
    return ["pass": pass, "visibleRowCount": first.visibleRowCount,
            "targetExactCount": exactCount, "confidence": confidence,
            "bboxStable": stable, "reasons": Array(Set(reasons)).sorted(),
            "axRowsCount": first.axRowsCount,
            "advertisedRowCount": first.advertisedRowCount ?? NSNull(),
            "denseIndices": first.denseIndices, "allRowsVisible": first.allRowsVisible,
            "bandInvalidRowCount": first.bandInvalidRowCount,
            "candidateInvalidRowCount": first.candidateInvalidRowCount,
            "profile": selected.profile.rawValue,
            "identityVerified": false,
            "observedParenthesizedCount": first.targetRendererEvidence?.observedParenthesizedCount ?? NSNull(),
            "auxiliaryObserved": first.targetRendererEvidence?.auxiliaryObserved ?? NSNull()]
}

enum OCRRegion { case tabs, header }

func ocrRegionROI(_ region: OCRRegion, tree: Snapshot,
                  window: WindowIdentity) throws -> CGRect {
    switch region {
    case .tabs:
        // 分頁帶只依賴左側結構，尚未選聊天室時不應要求右側 composer。
        return try readTabLayout(tree, window: window).tabROI
    case .header:
        return try lineLayout(tree, window: window).headerROI
    }
}

func captureOCR(_ region: OCRRegion, processedTabs: Bool = true) throws -> OCRFrame {
    guard #available(macOS 14.0, *) else {
        throw NativeFailure("UNSUPPORTED_OS_VERSION", "Vision 視窗 OCR 需要 macOS 14 以上")
    }
    let (_, _, window, identity) = try mainWindow(requireForeground: true)
    let tree = snapshot(window, mode: .geometryOnly)
    guard !tree.partial else { throw NativeFailure("SEMANTIC_PARTIAL", "AX 快照不完整，拒絕 OCR 導覽") }
    let roi = try ocrRegionROI(region, tree: tree, window: identity)
    let image = try captureWindowImage(identity, roi: roi)
    let geometry = CaptureGeometry(window: identity.bounds, roi: roi,
                                   imageWidth: image.width, imageHeight: image.height)
    let recognized = try recognizeText(image, geometry: geometry)
    let components = region == .tabs ? try greenComponents(image, geometry: geometry) : []
    let underlines = region == .tabs ? try underlineComponents(image, geometry: geometry) : []
    guard let originalROI = image.cropping(to: try geometry.roiPixels()) else {
        throw NativeFailure("OCR_ROI_FAILED", "無法在記憶體裁切 processed OCR ROI")
    }
    let masked = region == .tabs
        ? try maskedBadgeROI(image, geometry: geometry, components: components)
        : nil
    let maskedCandidates = try masked.map { try visionCandidates($0) } ?? []
    let processedCandidates = region == .tabs && processedTabs
        ? try visionCandidates(upscaledWholeROI2x(masked ?? originalROI))
        : []
    return OCRFrame(identity: identity, roi: roi, imageWidth: image.width, imageHeight: image.height,
                    candidates: recognized, maskedCandidates: maskedCandidates,
                    processedCandidates: processedCandidates,
                    processedPolicyApplied: region == .tabs && processedTabs,
                    greenComponents: components, underlineComponents: underlines)
}

func captureReadTabOCR(globalAllSourceRGB: Bool = false) throws -> ReadOCRFrame {
    guard #available(macOS 14.0, *) else {
        throw NativeFailure("UNSUPPORTED_OS_VERSION", "Vision 視窗 OCR 需要 macOS 14 以上")
    }
    let (_, _, window, identity) = try mainWindow(requireForeground: true)
    let tree = snapshot(window, mode: .geometryOnly)
    guard !tree.partial else { throw NativeFailure("SEMANTIC_PARTIAL", "AX 快照不完整，拒絕唯讀 OCR") }
    let layout = try readTabLayout(tree, window: identity)
    let roi = layout.tabROI
    let image = try captureWindowImage(identity, roi: roi, opaqueForRead: true)
    let geometry = CaptureGeometry(window: identity.bounds, roi: roi,
                                   imageWidth: image.width, imageHeight: image.height)
    guard let originalROI = image.cropping(to: try geometry.roiPixels()) else {
        throw NativeFailure("OCR_ROI_FAILED", "無法在記憶體裁切唯讀分頁 ROI")
    }
    let canonical = try canonicalReadROI(originalROI)
    // badge 身分與遮罩都保留原 RGB；只有送入 Vision／underline 的 ROI 正規化。
    let components = try greenComponents(image, geometry: geometry)
    let masked = try maskedBadgeROI(image, geometry: geometry, components: components)
    let canonicalMasked = try masked.map {
        try canonicalReadROI($0, requiredProfile: canonical.profile).image
    }
    let observedCandidates = try visionCandidates(globalAllSourceRGB ? originalROI : canonical.image)
    let candidates = globalAllSourceRGB ? canonicalReadOCRCandidates(
        observedCandidates, imageWidth: originalROI.width, imageHeight: originalROI.height
    ) : observedCandidates
    let candidateMaskedImage = globalAllSourceRGB ? masked : canonicalMasked
    let maskedCandidates: [OCRCandidate]
    if let candidateImage = candidateMaskedImage {
        let observed = try visionCandidates(candidateImage)
        maskedCandidates = globalAllSourceRGB ? canonicalReadOCRCandidates(
            observed, imageWidth: candidateImage.width, imageHeight: candidateImage.height
        ) : observed
    } else { maskedCandidates = [] }
    let trustedCandidates = canonicalMasked == nil ? candidates : maskedCandidates
    var processedCandidates: [OCRCandidate] = []
    var processedPolicyApplied = false
    if globalAllSourceRGB {
        let rawExact = trustedCandidates.filter {
            ["全部", "All"].contains($0.text) &&
                $0.confidence >= ocrConfidenceThreshold && validNormalizedBox($0.normalizedBox)
        }
        if rawExact.isEmpty {
            processedPolicyApplied = true
            // All 導覽 fallback 的 raw／2x／尺寸必須共用同一張來源 RGB ROI。
            let navigationImage = masked ?? originalROI
            let observations = try visionRequest(navigationImage)
            var rawTopCandidates: [OCRCandidate] = []
            var rawTokens: [MergedAllRawToken] = []
            for observation in observations {
                guard let top = observation.topCandidates(1).first else { continue }
                let parentIndex = rawTopCandidates.count
                rawTopCandidates.append(OCRCandidate(
                    text: top.string.trimmingCharacters(in: .whitespacesAndNewlines),
                    confidence: top.confidence, normalizedBox: observation.boundingBox
                ))
                for token in allNavigationTokenRanges(top.string) {
                    // 唯一性計數不可因 substring geometry 失敗而漏掉 token occurrence。
                    let substringBox = (try? top.boundingBox(for: token.range))?.boundingBox ?? .null
                    rawTokens.append(MergedAllRawToken(
                        parentIndex: parentIndex, label: token.label,
                        normalizedBox: substringBox
                    ))
                }
            }
            let fixed2x = try visionCandidates(upscaledWholeROI2x(navigationImage))
            if let fallback = mergedAllNavigationCandidate(
                rawTokens: rawTokens, rawCandidates: rawTopCandidates,
                processedCandidates: fixed2x,
                originalWidth: navigationImage.width, originalHeight: navigationImage.height
            ) { processedCandidates = [fallback] }
        }
    }
    let underlines = try underlineComponentsROI(canonical.image,
                                                scaleX: geometry.scaleX, scaleY: geometry.scaleY)
    let frame = OCRFrame(identity: identity, roi: roi, imageWidth: image.width,
                         imageHeight: image.height, candidates: candidates,
                         maskedCandidates: maskedCandidates, processedCandidates: processedCandidates,
                         processedPolicyApplied: processedPolicyApplied, greenComponents: components,
                         underlineComponents: underlines)
    return ReadOCRFrame(frame: frame, profile: canonical.profile)
}

func exactOCRMatches(_ text: String, in frame: OCRFrame) -> [OCRCandidate] {
    let raw = trustedOCRCandidates(frame)
    if !frame.processedPolicyApplied {
        return raw.filter {
            $0.confidence >= ocrConfidenceThreshold && $0.text == text &&
                validNormalizedBox($0.normalizedBox)
        }
    }
    guard raw.allSatisfy({ validNormalizedBox($0.normalizedBox) }),
          frame.processedCandidates.allSatisfy({ validNormalizedBox($0.normalizedBox) }) else { return [] }
    let rawExact = raw.filter { $0.text == text }
    guard rawExact.count == 1, let source = rawExact.first else { return rawExact }
    guard validNormalizedBox(source.normalizedBox) else { return [] }
    let processedExact = frame.processedCandidates.filter { $0.text == text }
    guard processedExact.count == 1, let processed = processedExact.first else { return processedExact }
    guard processed.confidence >= ocrConfidenceThreshold,
          validNormalizedBox(processed.normalizedBox),
          intersectionOverUnion(source.normalizedBox, processed.normalizedBox) >= 0.80 else { return [] }
    let rawConflicts = raw.filter {
        $0.confidence >= ocrConfidenceThreshold && $0.text != text &&
            intersectionOverUnion(source.normalizedBox, $0.normalizedBox) > 0
    }
    let processedConflicts = frame.processedCandidates.filter {
        $0.confidence >= ocrConfidenceThreshold && $0.text != text &&
            intersectionOverUnion(processed.normalizedBox, $0.normalizedBox) > 0
    }
    return rawConflicts.isEmpty && processedConflicts.isEmpty
        ? [processed]
        : [processed] + rawConflicts + processedConflicts
}

func allNavigationExactMatches(_ text: String, in frame: OCRFrame) -> [OCRCandidate] {
    guard frame.processedPolicyApplied else {
        let raw = trustedOCRCandidates(frame)
        // All route 的 raw fast path 也必須計入所有高低分與 merged token occurrence。
        guard raw.allSatisfy({ validNormalizedBox($0.normalizedBox) }),
              raw.flatMap({ allNavigationTokenRanges($0.text) }).count == 1 else { return [] }
        return exactOCRMatches(text, in: frame)
    }
    return frame.processedCandidates.filter {
        $0.text == text && $0.confidence >= ocrConfidenceThreshold &&
            validNormalizedBox($0.normalizedBox)
    }
}

func stableAllNavigationTarget(_ text: String, first: OCRFrame,
                               second: OCRFrame) throws -> OCRCandidate {
    guard sameWindow(first.identity, second.identity),
          similar(first.roi, second.roi, tolerance: 0.5),
          first.imageWidth == second.imageWidth, first.imageHeight == second.imageHeight,
          first.processedPolicyApplied == second.processedPolicyApplied,
          stableBadgeGeometry(first, second) else {
        throw NativeFailure("WINDOW_CHANGED", "兩次 All 導覽 OCR 證據已漂移")
    }
    let old = allNavigationExactMatches(text, in: first)
    let current = allNavigationExactMatches(text, in: second)
    guard old.count == 1, current.count == 1, let a = old.first, let b = current.first,
          intersectionOverUnion(a.normalizedBox, b.normalizedBox) >= 0.80 else {
        throw NativeFailure("GLOBAL_ALL_ROUTE_NOT_UNIQUE", "All 導覽候選無法兩次唯一穩定")
    }
    return b
}

func validNormalizedBox(_ box: CGRect) -> Bool {
    box.minX.isFinite && box.minY.isFinite && box.width.isFinite && box.height.isFinite &&
        box.minX >= 0 && box.minY >= 0 && box.maxX <= 1 && box.maxY <= 1 &&
        box.width > 0 && box.height > 0
}

func eligibleBadgeBoxes(_ frame: OCRFrame) -> [CGRect] {
    frame.greenComponents.filter { badgeGeometryEligible($0, roiHeight: frame.roi.height) }
        .map(\.pointBox).sorted { $0.minX < $1.minX }
}

func trustedOCRCandidates(_ frame: OCRFrame) -> [OCRCandidate] {
    eligibleBadgeBoxes(frame).isEmpty ? frame.candidates : frame.maskedCandidates
}

func stableBadgeGeometry(_ first: OCRFrame, _ second: OCRFrame) -> Bool {
    let old = eligibleBadgeBoxes(first), current = eligibleBadgeBoxes(second)
    guard old.count == current.count else { return false }
    return zip(old, current).allSatisfy { intersectionOverUnion($0, $1) >= 0.80 }
}

func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
    let intersection = lhs.intersection(rhs)
    guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return 0 }
    let union = lhs.width * lhs.height + rhs.width * rhs.height - intersection.width * intersection.height
    return union > 0 ? intersection.width * intersection.height / union : 0
}

func stableOCRTarget(_ text: String, first: OCRFrame, second: OCRFrame) throws -> OCRCandidate {
    guard sameWindow(first.identity, second.identity), similar(first.roi, second.roi, tolerance: 0.5),
          first.imageWidth == second.imageWidth, first.imageHeight == second.imageHeight,
          stableBadgeGeometry(first, second) else {
        throw NativeFailure("WINDOW_CHANGED", "兩次 OCR 擷取的視窗或 ROI 已漂移")
    }
    let old = exactOCRMatches(text, in: first)
    let current = exactOCRMatches(text, in: second)
    guard old.count == 1, current.count == 1, let a = old.first, let b = current.first else {
        let count = max(old.count, current.count)
        throw NativeFailure(count == 0 ? "TAB_NOT_FOUND" : "AMBIGUOUS_MATCH",
                            count == 0 ? "找不到高信心 exact 分頁標籤" : "分頁 OCR 標籤不唯一",
                            ["text": text, "count": count])
    }
    guard intersectionOverUnion(a.normalizedBox, b.normalizedBox) >= 0.80 else {
        throw NativeFailure("OCR_TARGET_DRIFT", "兩次 OCR 標籤位置不穩定")
    }
    return b
}

func status() throws -> [String: Any] {
    let app = try lineApplication()
    let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
    guard AXIsProcessTrusted() else {
        return ["running": true, "accessibilityTrusted": false, "foreground": foreground,
                "mainWindow": NSNull(), "usable": false]
    }
    do {
        let (_, _, _, identity) = try mainWindow(requireForeground: false)
        return ["running": true, "accessibilityTrusted": true, "foreground": foreground,
                "mainWindow": identity.json, "usable": true, "partial": false, "reasons": []]
    } catch let failure as NativeFailure {
        return ["running": true, "accessibilityTrusted": true, "foreground": foreground,
                "mainWindow": NSNull(), "usable": false, "reason": failure.code]
    }
}

struct TabInventory {
    let names: [String]
    let identity: WindowIdentity
    let selectedTab: String?
    let complete: Bool
    let reasons: [String]
    let pagesScanned: Int
    let firstFrame: OCRFrame
}

func tabPageEvidence(_ frame: OCRFrame) -> ([String], [String], String) {
    let raw = trustedOCRCandidates(frame).sorted { $0.normalizedBox.minX < $1.normalizedBox.minX }
    let trusted = raw.filter { $0.confidence >= ocrConfidenceThreshold && !$0.text.isEmpty }
    var reasons: [String] = []
    if raw.contains(where: { $0.confidence < ocrConfidenceThreshold || $0.text.isEmpty }) ||
        frame.candidates.contains(where: { $0.confidence < ocrConfidenceThreshold || $0.text.isEmpty }) {
        reasons.append("TAB_GLYPH_UNVERIFIED")
    }
    if Set(trusted.map(\.text)).count != trusted.count { reasons.append("DUPLICATE_TAB_NAMES") }
    let signature = sha256(trusted.map {
        ["text": $0.text, "confidence": $0.confidence,
         "x": $0.normalizedBox.minX, "y": $0.normalizedBox.minY,
         "width": $0.normalizedBox.width, "height": $0.normalizedBox.height] as [String: Any]
    })
    return (trusted.map(\.text), reasons, signature)
}

func mergeOrderedTabPage(_ existing: [String], _ page: [String]) -> ([String], Bool) {
    guard !existing.isEmpty else { return (page, true) }
    let maximum = min(existing.count, page.count)
    for overlap in stride(from: maximum, through: 1, by: -1) {
        if Array(existing.suffix(overlap)) == Array(page.prefix(overlap)) {
            return (existing + page.dropFirst(overlap), true)
        }
    }
    return (existing + page, false)
}

func scanFullTabInventory(maxPages: Int = 20) throws -> TabInventory {
    let initial = try captureOCR(.tabs)
    let selected = trustedOCRCandidates(initial).filter {
        $0.confidence >= ocrConfidenceThreshold && associatedUnderlines(initial, candidate: $0).count == 1
    }
    var reasons: [String] = []
    if selected.count != 1 { reasons.append("SELECTED_TAB_UNVERIFIED") }
    var pagesScanned = 1

    // 先走到一端，再反向走到另一端；兩端都要有連續相同頁面作邊界證據。
    var frame = initial
    var previous = tabPageEvidence(frame).2
    var firstBoundary = false
    for _ in 0..<maxPages {
        try scrollTabStrip(frame, direction: -1)
        Thread.sleep(forTimeInterval: 0.12)
        let next = try captureOCR(.tabs)
        guard sameWindow(initial.identity, next.identity) else {
            throw NativeFailure("WINDOW_CHANGED", "分頁全盤掃描期間視窗已變更")
        }
        pagesScanned += 1
        let signature = tabPageEvidence(next).2
        frame = next
        if signature == previous { firstBoundary = true; break }
        previous = signature
    }
    if !firstBoundary { reasons.append("TAB_LEFT_BOUNDARY_UNVERIFIED") }

    var names: [String] = []
    var secondBoundary = false
    previous = ""
    for _ in 0..<maxPages {
        let page = tabPageEvidence(frame)
        reasons.append(contentsOf: page.1)
        if page.2 == previous { secondBoundary = true; break }
        let merged = mergeOrderedTabPage(names, page.0)
        names = merged.0
        if !merged.1 { reasons.append("TAB_PAGE_CONTINUITY_UNVERIFIED") }
        previous = page.2
        try scrollTabStrip(frame, direction: 1)
        Thread.sleep(forTimeInterval: 0.12)
        let next = try captureOCR(.tabs)
        guard sameWindow(initial.identity, next.identity) else {
            throw NativeFailure("WINDOW_CHANGED", "分頁全盤掃描期間視窗已變更")
        }
        pagesScanned += 1
        frame = next
    }
    if !secondBoundary { reasons.append("TAB_RIGHT_BOUNDARY_UNVERIFIED") }
    if names.isEmpty { reasons.append("OCR_NO_CANDIDATES") }
    if Set(names).count != names.count { reasons.append("DUPLICATE_TAB_NAMES") }
    reasons = Array(Set(reasons)).sorted()
    return TabInventory(names: names, identity: initial.identity,
                        selectedTab: selected.count == 1 ? selected[0].text : nil,
                        complete: firstBoundary && secondBoundary && !names.isEmpty && reasons.isEmpty,
                        reasons: reasons, pagesScanned: pagesScanned, firstFrame: initial)
}

func listTabs(_ args: [String: Any], liveScope: LiveScope?) throws -> [String: Any] {
    if let semantic = try axListTabsIfVerified(liveScope: liveScope) { return semantic }
    let maxPages = (args["maxPages"] as? NSNumber)?.intValue ?? 5
    let inventory = try scanFullTabInventory(maxPages: maxPages)
    let frame = inventory.firstFrame
    let names = inventory.names
    guard !names.isEmpty else { throw NativeFailure("OCR_NO_CANDIDATES", "分頁帶沒有高信心 OCR 文字") }
    let observedCandidates = frame.candidates.map { candidate in
        ["text": candidate.text, "confidence": candidate.confidence,
         "normalizedBox": ["x": candidate.normalizedBox.minX, "y": candidate.normalizedBox.minY,
                           "width": candidate.normalizedBox.width, "height": candidate.normalizedBox.height]] as [String: Any]
    }
    let maskedCandidates = frame.maskedCandidates.map { candidate in
        ["text": candidate.text, "confidence": candidate.confidence,
         "normalizedBox": ["x": candidate.normalizedBox.minX, "y": candidate.normalizedBox.minY,
                           "width": candidate.normalizedBox.width, "height": candidate.normalizedBox.height]] as [String: Any]
    }
    let processedCandidates = frame.processedCandidates.map { candidate in
        ["text": candidate.text, "confidence": candidate.confidence,
         "normalizedBox": ["x": candidate.normalizedBox.minX, "y": candidate.normalizedBox.minY,
                           "width": candidate.normalizedBox.width, "height": candidate.normalizedBox.height]] as [String: Any]
    }
    let components = frame.greenComponents.map { component in
        ["pixelBox": ["x": component.pixelBox.minX, "y": component.pixelBox.minY,
                       "width": component.pixelBox.width, "height": component.pixelBox.height],
         "pointBox": ["x": component.pointBox.minX, "y": component.pointBox.minY,
                       "width": component.pointBox.width, "height": component.pointBox.height],
         "pixelCount": component.pixelCount, "aspect": component.aspect,
         "fillRatio": component.fillRatio,
         "meanRGBA": [component.meanRed, component.meanGreen, component.meanBlue, component.meanAlpha],
         "geometryEligible": badgeGeometryEligible(component, roiHeight: frame.roi.height)] as [String: Any]
    }
    var result: [String: Any] = [
            "tabs": names, "observedAt": ISO8601DateFormatter().string(from: Date()),
            "partial": !inventory.complete, "complete": inventory.complete, "reasons": inventory.reasons,
            "pagesScanned": inventory.pagesScanned,
            "ocrPolicy": ["revision": ocrRevision, "recognitionLevel": "accurate",
                          "languages": ["zh-Hant", "en-US"], "languageCorrection": false,
                          "confidenceThreshold": ocrConfidenceThreshold,
                          "badgePolicyVersion": "line-green-component-mask-v1",
                          "processedPolicyVersion": processedOCRPolicyVersion],
            "observedCandidates": observedCandidates,
            "maskedCandidates": maskedCandidates,
            "processedCandidates": processedCandidates,
            "greenComponents": components,
            "capture": ["roi": ["x": frame.roi.minX, "y": frame.roi.minY,
                                  "width": frame.roi.width, "height": frame.roi.height],
                        "imageWidth": frame.imageWidth, "imageHeight": frame.imageHeight],
            "mainWindow": frame.identity.json]
    if let selectedTab = inventory.selectedTab { result["selectedTab"] = selectedTab }
    if let liveScope, let tabName = liveScope.tabName {
        result["scopeTarget"] = ["exactText": tabName,
                                 "exactCandidateCount": exactOCRMatches(tabName, in: frame).count]
    }
    return result
}

func validateExpectedWindow(_ raw: Any?, current: WindowIdentity) throws {
    guard let expected = raw as? [String: Any] else { return }
    guard (expected["pid"] as? NSNumber)?.int32Value == current.pid,
          (expected["windowId"] as? NSNumber)?.uint32Value == current.windowID,
          expected["bundleIdentifier"] as? String == bundleIdentifier,
          expected["executableURL"] as? String == current.executableURL,
          expected["title"] as? String == expectedWindowTitle,
          let bounds = expected["bounds"] as? [String: Any],
          let expectedRect = rect(from: ["X": bounds["x"] as Any, "Y": bounds["y"] as Any,
                                         "Width": bounds["width"] as Any, "Height": bounds["height"] as Any]),
          similar(expectedRect, current.bounds, tolerance: 0.5) else {
        throw NativeFailure("WINDOW_CHANGED", "LINE 主視窗身分或幾何已變更", ["phase": "pre_commit"])
    }
}

func clickSemanticPoint(_ point: CGPoint) throws {
    guard point.x.isFinite, point.y.isFinite,
          let source = CGEventSource(stateID: .combinedSessionState),
          let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                             mouseCursorPosition: point, mouseButton: .left),
          let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                           mouseCursorPosition: point, mouseButton: .left) else {
        throw NativeFailure("MOUSE_EVENT_FAILED", "無法建立受限語意目標點擊事件")
    }
    down.post(tap: .cghidEventTap)
    var released = false
    defer { if !released { up.post(tap: .cghidEventTap) } }
    up.post(tap: .cghidEventTap)
    released = true
}

func globalAllNavigationReceipt(chatName: String, requestNonce: String,
                                expectedWindow: [String: Any],
                                mainWindow: WindowIdentity?, allSelected: Bool,
                                counts: GlobalAllEventCounts, phase: String,
                                identityVerified: Bool) -> [String: Any] {
    [
        "route": globalAllNavigationRoute,
        "requestNonce": requestNonce,
        "scope": ["kind": "all-navigation", "chatName": chatName],
        "expectedWindow": expectedWindow,
        "mainWindow": mainWindow?.json ?? NSNull(),
        "allSelected": allSelected,
        "inputAttempted": counts.inputAttempted,
        "eventCounts": counts.json,
        "systemEventsInvocations": 0,
        "phase": phase,
        "identityVerified": identityVerified,
    ]
}

func buildGlobalAllMouseEvents(point: CGPoint, eventNumber: Int64) throws -> GlobalAllMouseEvents {
    guard point.x.isFinite, point.y.isFinite,
          eventNumber > 0, eventNumber <= Int64(Int16.max),
          let source = CGEventSource(stateID: .combinedSessionState),
          let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                             mouseCursorPosition: point, mouseButton: .left),
          let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                             mouseCursorPosition: point, mouseButton: .left),
          let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                           mouseCursorPosition: point, mouseButton: .left) else {
        throw NativeFailure("MOUSE_EVENT_FAILED", "無法建立 LINE PID 定向的標準滑鼠事件")
    }
    for event in [move, down, up] { event.flags = [] }
    for event in [down, up] {
        event.setIntegerValueField(.mouseEventNumber, value: eventNumber)
        event.setIntegerValueField(.mouseEventClickState, value: 1)
    }
    down.setDoubleValueField(.mouseEventPressure, value: 1)
    up.setDoubleValueField(.mouseEventPressure, value: 0)
    let events = GlobalAllMouseEvents(move: move, down: down, up: up)
    guard globalAllMouseEventsValid(events, point: point, eventNumber: eventNumber) else {
        throw NativeFailure("MOUSE_EVENT_FAILED", "LINE PID 滑鼠事件欄位回讀不符")
    }
    return events
}

func globalAllMouseEventsValid(_ events: GlobalAllMouseEvents,
                               point: CGPoint, eventNumber: Int64) -> Bool {
    let ordered: [(CGEvent, CGEventType)] = [
        (events.move, .mouseMoved), (events.down, .leftMouseDown), (events.up, .leftMouseUp),
    ]
    guard ordered.allSatisfy({ event, type in
        event.type == type && event.flags.rawValue == 0 &&
            abs(event.location.x - point.x) <= 0.001 && abs(event.location.y - point.y) <= 0.001
    }) else { return false }
    return [events.down, events.up].allSatisfy {
        $0.getIntegerValueField(.mouseEventNumber) == eventNumber &&
            $0.getIntegerValueField(.mouseEventClickState) == 1 &&
            $0.getIntegerValueField(.mouseEventButtonNumber) == 0
    } && abs(events.down.getDoubleValueField(.mouseEventPressure) - 1) <= 0.001 &&
        abs(events.up.getDoubleValueField(.mouseEventPressure)) <= 0.001
}

func runGlobalAllMouseCore(pid: pid_t,
                           guardFresh: (GlobalAllMouseStep) throws -> Void,
                           post: (GlobalAllMouseStep, pid_t) throws -> Void) throws
    -> GlobalAllEventCounts {
    var counts = GlobalAllEventCounts()
    do {
        try guardFresh(.move)
        counts.record(.move)
        try post(.move, pid)

        func postDownAndRelease() throws {
            var downAttempted = false
            var releaseAttempted = false
            defer {
                // down 一旦嘗試便只補一次同 PID release；結果不明也不重送。
                if downAttempted && !releaseAttempted {
                    releaseAttempted = true
                    counts.record(.up)
                    try? post(.up, pid)
                }
            }
            try guardFresh(.down)
            downAttempted = true
            counts.record(.down)
            try post(.down, pid)
            try guardFresh(.up)
            releaseAttempted = true
            counts.record(.up)
            try post(.up, pid)
        }
        try postDownAndRelease()
        return counts
    } catch {
        throw GlobalAllCoreFailure(cause: error, counts: counts)
    }
}

struct SystemEventsAllCoreFailure: Error {
    let cause: Error
    let invocations: Int
}

func runSystemEventsAllCore(invoke: () throws -> Bool,
                            verify: () throws -> Bool) throws -> Int {
    var invocations = 0
    do {
        // execute 前先記帳；同步錯誤或 timeout 都不得重設為零。
        invocations = 1
        guard try invoke() else {
            throw NativeFailure("SYSTEM_EVENTS_RESULT_UNVERIFIED",
                                "System Events 未回傳成功布林值")
        }
        guard try verify() else {
            throw NativeFailure("GLOBAL_ALL_NOT_SELECTED",
                                "System Events 後未證明全部分頁已選取")
        }
        return invocations
    } catch {
        throw SystemEventsAllCoreFailure(cause: error, invocations: invocations)
    }
}

struct SystemEventsAllScriptPlan {
    let source: String
    let point: CGPoint
}

func exactScriptInteger(_ value: CGFloat) -> Int? {
    guard value.isFinite, value.rounded() == value,
          value >= CGFloat(Int32.min), value <= CGFloat(Int32.max) else { return nil }
    return Int(value)
}

func systemEventsAllScriptPlan(pid: pid_t, window: CGRect, roi: CGRect,
                               label: CGRect, point: CGPoint) -> SystemEventsAllScriptPlan? {
    let rounded = CGPoint(x: point.x.rounded(), y: point.y.rounded())
    guard pid > 0, label.contains(rounded), roi.contains(rounded), window.contains(rounded),
          let x = exactScriptInteger(rounded.x), let y = exactScriptInteger(rounded.y),
          let windowX = exactScriptInteger(window.minX),
          let windowY = exactScriptInteger(window.minY),
          let width = exactScriptInteger(window.width),
          let height = exactScriptInteger(window.height), width > 0, height > 0 else { return nil }
    let source = """
    on run
      with timeout of 3 seconds
        tell application "System Events"
          set lineProcesses to every application process whose unix id is \(pid)
          if (count of lineProcesses) is not 1 then return false
          set lineProcess to item 1 of lineProcesses
          if frontmost of lineProcess is not true then return false
          set lineWindows to every window of lineProcess whose name is "LINE"
          if (count of lineWindows) is not 1 then return false
          set lineWindow to item 1 of lineWindows
          if position of lineWindow is not {\(windowX), \(windowY)} then return false
          if size of lineWindow is not {\(width), \(height)} then return false
          tell lineProcess to click at {\(x), \(y)}
          return true
        end tell
      end timeout
    end run
    """
    return SystemEventsAllScriptPlan(source: source, point: rounded)
}

func systemEventsAllScriptSourceSafe(_ source: String, pid: pid_t,
                                     point: CGPoint, window: CGRect) -> Bool {
    let forbidden = ["keystroke", "key code", "clipboard", "set value", "close", "send"]
    guard forbidden.allSatisfy({ !source.localizedCaseInsensitiveContains($0) }),
          source.components(separatedBy: "click at").count == 2,
          source.contains("unix id is \(pid)"),
          source.contains("frontmost of lineProcess is not true"),
          source.contains("whose name is \"LINE\""),
          source.contains("{\(Int(point.x)), \(Int(point.y))}"),
          source.contains("{\(Int(window.minX)), \(Int(window.minY))}"),
          source.contains("{\(Int(window.width)), \(Int(window.height))}") else { return false }
    return true
}

func systemEventsAutomationPermission() -> OSStatus {
    let bytes = Array(systemEventsBundleIdentifier.utf8)
    var target = AEAddressDesc()
    let createStatus = bytes.withUnsafeBytes {
        AECreateDesc(DescType(typeApplicationBundleID), $0.baseAddress, $0.count, &target)
    }
    guard createStatus == noErr else { return OSStatus(createStatus) }
    defer { AEDisposeDesc(&target) }
    return AEDeterminePermissionToAutomateTarget(
        &target, AEEventClass(typeWildCard), AEEventID(typeWildCard), false
    )
}

func compileSystemEventsAllScript(_ source: String) throws -> NSAppleScript {
    guard let script = NSAppleScript(source: source) else {
        throw NativeFailure("SYSTEM_EVENTS_SCRIPT_INVALID", "無法建立固定 System Events 腳本")
    }
    var errorInfo: NSDictionary?
    guard script.compileAndReturnError(&errorInfo) else {
        throw NativeFailure("SYSTEM_EVENTS_SCRIPT_INVALID", "固定 System Events 腳本編譯失敗",
                            appleScriptNumericError(errorInfo))
    }
    return script
}

func executeSystemEventsAllScript(_ script: NSAppleScript) throws -> Bool {
    var errorInfo: NSDictionary?
    let result = script.executeAndReturnError(&errorInfo)
    guard errorInfo == nil else {
        throw NativeFailure("SYSTEM_EVENTS_EXECUTION_FAILED",
                            "System Events 執行失敗或逾時",
                            appleScriptNumericError(errorInfo))
    }
    return result.booleanValue
}

func appleScriptNumericError(_ errorInfo: NSDictionary?) -> [String: Any] {
    guard let number = errorInfo?[NSAppleScript.errorNumber] as? NSNumber else { return [:] }
    return ["appleEventError": number.intValue]
}

enum RawSelectedProof {
    case absent
    case invalid
    case selected(String, OCRCandidate, UnderlineComponent)
}

func rawSelectedProof(_ labels: [String], frame: OCRFrame) -> RawSelectedProof {
    let raw = trustedOCRCandidates(frame)
    let highConfidence = raw.filter { $0.confidence >= ocrConfidenceThreshold }
    var selected: [(String, OCRCandidate, UnderlineComponent)] = []
    var sawTargetHint = false
    for label in labels {
        let exact = raw.filter { $0.text == label }
        guard !exact.isEmpty else { continue }
        let hasSelectedHint = exact.contains { !associatedUnderlines(frame, candidate: $0).isEmpty }
        guard hasSelectedHint else { continue }
        sawTargetHint = true
        guard exact.count == 1, let candidate = exact.first,
              candidate.confidence >= ocrConfidenceThreshold,
              validNormalizedBox(candidate.normalizedBox) else { return .invalid }
        let underlines = associatedUnderlines(frame, candidate: candidate)
        guard underlines.count == 1, let underline = underlines.first else { return .invalid }
        selected.append((label, candidate, underline))
    }
    guard sawTargetHint else { return .absent }
    guard highConfidence.allSatisfy({ validNormalizedBox($0.normalizedBox) }) else { return .invalid }
    guard selected.count == 1, let target = selected.first else { return .invalid }
    let competing = highConfidence.filter { $0.text != target.0 }.contains {
        !associatedUnderlines(frame, candidate: $0).isEmpty
    }
    return competing ? .invalid : .selected(target.0, target.1, target.2)
}

func stableRawSelectedTab(_ labels: [String], first: OCRFrame,
                          second: OCRFrame) throws -> (String, OCRCandidate)? {
    switch rawSelectedProof(labels, frame: first) {
    case .absent: return nil
    case .invalid:
        throw NativeFailure("TAB_SELECTION_UNVERIFIED", "第一張 raw 分頁 selected 證據不可靠")
    case let .selected(label, oldCandidate, oldUnderline):
        guard case let .selected(currentLabel, candidate, underline) = rawSelectedProof(labels, frame: second),
              label == currentLabel,
              !first.processedPolicyApplied, !second.processedPolicyApplied,
              sameWindow(first.identity, second.identity),
              similar(first.roi, second.roi, tolerance: 0.5),
              first.imageWidth == second.imageWidth, first.imageHeight == second.imageHeight,
              stableBadgeGeometry(first, second),
              intersectionOverUnion(oldCandidate.normalizedBox, candidate.normalizedBox) >= 0.80,
              intersectionOverUnion(oldUnderline.pointBox, underline.pointBox) >= 0.80 else {
            throw NativeFailure("TAB_SELECTION_UNVERIFIED", "兩張 raw 分頁 selected 證據不一致")
        }
        return (label, candidate)
    }
}

@discardableResult
func navigateTab(_ tabName: String, expectedWindow: Any? = nil,
                 mode: TabNavigationMode = .legacy) throws -> WindowIdentity {
    try navigateTab(labels: [tabName], expectedWindow: expectedWindow, mode: mode).0
}

func navigateAXTabIfVerified(labels: [String], expectedWindow: Any?) throws
    -> (WindowIdentity, String)? {
    switch try readAXTabSemanticReceipt() {
    case .unavailable: return nil
    case let .verified(receipt):
        try validateExpectedWindow(expectedWindow, current: receipt.identity)
        let matches = receipt.items.filter { labels.contains($0.name) }
        guard matches.count <= 1 else {
            throw NativeFailure("AMBIGUOUS_MATCH", "AX 分頁白名單有多個 exact 候選")
        }
        guard let target = matches.first else {
            throw NativeFailure("TAB_NOT_FOUND", "完整 AXTabs 內找不到 exact 白名單標籤")
        }
        if target.selected { return (receipt.identity, target.name) }
        guard target.enabled, actions(target.element).contains(kAXPressAction) else {
            throw NativeFailure("AX_TAB_ACTION_UNAVAILABLE", "AX 分頁不提供可驗證的按壓動作",
                                ["phase": "pre_commit"])
        }
        var attempted = false
        do {
            attempted = true
            try perform(kAXPressAction, on: target.element)
            Thread.sleep(forTimeInterval: 0.25)
            guard case let .verified(after) = try readAXTabSemanticReceipt(),
                  sameWindow(receipt.identity, after.identity),
                  let selected = after.items.first(where: { $0.name == target.name }),
                  CFEqual(selected.element, target.element), selected.selected else {
                throw NativeFailure("TAB_SELECTION_UNVERIFIED", "AXPress 後 selected-state 未經證實")
            }
            return (after.identity, selected.name)
        } catch let failure as NativeFailure {
            throw forcingPhase(failure, phaseAfterMutationAttempt(attempted, nestedPhase: "pre_commit")!)
        } catch {
            throw NativeFailure("TAB_SELECTION_UNVERIFIED", "AXPress 後結果不明",
                                ["phase": "post_commit"])
        }
    }
}

func scrollTabStrip(_ frame: OCRFrame, direction: Int = -1) throws {
    let (_, _, _, current) = try mainWindow(requireForeground: true)
    guard (direction == -1 || direction == 1), sameWindow(frame.identity, current),
          let source = CGEventSource(stateID: .combinedSessionState),
          let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                              wheelCount: 2, wheel1: 0, wheel2: Int32(direction * 180), wheel3: 0) else {
        throw NativeFailure("TAB_SCROLL_FAILED", "無法建立受限分頁水平捲動事件")
    }
    event.location = CGPoint(x: frame.roi.midX, y: frame.roi.midY)
    event.post(tap: .cghidEventTap)
}

func advanceTabSearch(_ mode: TabNavigationMode, signature: String,
                      remainingPages: Int, direction: inout Int,
                      seen: inout Set<String>) -> Bool {
    guard (direction == -1 || direction == 1), remainingPages >= 0 else { return false }
    switch mode {
    case .legacy:
        guard direction == -1 else { return false }
        return seen.insert(signature).inserted
    case .readOnly:
        if seen.insert(signature).inserted { return true }
        guard direction == -1, remainingPages > 0 else { return false }
        // 左端重複且仍有全域頁數時只反向一次；重播種避免回訪舊頁被誤判。
        direction = 1
        seen.removeAll(keepingCapacity: true)
        seen.insert(signature)
        return true
    }
}

@discardableResult
func navigateTab(labels: [String], expectedWindow: Any? = nil,
                 maxPages: Int = 20,
                 mode: TabNavigationMode = .legacy) throws -> (WindowIdentity, String) {
    if let semantic = try navigateAXTabIfVerified(labels: labels, expectedWindow: expectedWindow) {
        return semantic
    }
    var expectedReadProfile: ReadColorProfile?
    func captureTabFrame(processedTabs: Bool) throws -> OCRFrame {
        switch mode {
        case .legacy:
            return try captureOCR(.tabs, processedTabs: processedTabs)
        case .readOnly:
            let captured = try captureReadTabOCR()
            guard tabNavigationProfileAllowed(.readOnly, expected: expectedReadProfile,
                                              observed: captured.profile) else {
                throw NativeFailure("TAB_SELECTION_UNVERIFIED",
                                    "唯讀分頁色彩或 selected 證據不穩定")
            }
            if expectedReadProfile == nil { expectedReadProfile = captured.profile }
            return captured.frame
        }
    }
    var seen = Set<String>()
    var direction = -1
    for page in 0..<maxPages {
        let rawFirst = try captureTabFrame(processedTabs: false)
        try validateExpectedWindow(expectedWindow, current: rawFirst.identity)
        switch rawSelectedProof(labels, frame: rawFirst) {
        case .absent: break
        case .invalid:
            throw NativeFailure("TAB_SELECTION_UNVERIFIED", "第一張 raw 分頁有不可靠的 selected hint")
        case .selected:
            Thread.sleep(forTimeInterval: 0.06)
            let rawSecond = try captureTabFrame(processedTabs: false)
            guard let selected = try stableRawSelectedTab(labels, first: rawFirst, second: rawSecond) else {
                throw NativeFailure("TAB_SELECTION_UNVERIFIED", "raw selected 證據意外消失")
            }
            try validateExpectedWindow(expectedWindow, current: rawSecond.identity)
            return (rawSecond.identity, selected.0)
        }
        let first = try captureTabFrame(processedTabs: true)
        try validateExpectedWindow(expectedWindow, current: first.identity)
        let matches = labels.flatMap { label in exactOCRMatches(label, in: first).map { (label, $0) } }
        if matches.count == 1, let match = matches.first {
            Thread.sleep(forTimeInterval: 0.06)
            let second = try captureTabFrame(processedTabs: true)
            let candidate = try stableOCRTarget(match.0, first: first, second: second)
            let geometry = CaptureGeometry(window: second.identity.bounds, roi: second.roi,
                                           imageWidth: second.imageWidth, imageHeight: second.imageHeight)
            let target = try geometry.screenRect(for: candidate)
            let (_, _, _, before) = try mainWindow(requireForeground: true)
            guard sameWindow(second.identity, before) else { throw NativeFailure("WINDOW_CHANGED", "點擊前 LINE 視窗已變更") }
            try clickSemanticPoint(CGPoint(x: target.midX, y: target.midY))
            Thread.sleep(forTimeInterval: 0.25)
            let (_, _, _, after) = try mainWindow(requireForeground: true)
            guard sameWindow(before, after) else { throw NativeFailure("WINDOW_CHANGED", "分頁導覽後 LINE 視窗已變更") }
            let selected = try verifySelectedTab(match.0, mode: mode,
                                                  expectedReadProfile: expectedReadProfile)
            guard sameWindow(after, selected.0.identity) else {
                throw NativeFailure("WINDOW_CHANGED", "selected-state 驗證期間視窗已變更")
            }
            return (after, match.0)
        }
        guard matches.isEmpty else { throw NativeFailure("AMBIGUOUS_MATCH", "分頁白名單有多個 exact 候選") }
        let digest = sha256(trustedOCRCandidates(first).map {
            ["text": $0.text, "confidence": $0.confidence,
             "x": $0.normalizedBox.minX, "y": $0.normalizedBox.minY] as [String: Any]
        })
        guard advanceTabSearch(mode, signature: digest,
                               remainingPages: maxPages - page - 1,
                               direction: &direction, seen: &seen) else {
            throw NativeFailure("TAB_PAGINATION_EXHAUSTED", "分頁捲動畫面重複，停止搜尋")
        }
        guard page + 1 < maxPages else { break }
        try scrollTabStrip(first, direction: direction)
        Thread.sleep(forTimeInterval: 0.12)
    }
    throw NativeFailure("TAB_NOT_FOUND", "在 bounded 分頁捲動內找不到 exact 白名單標籤")
}

func chatRows(_ tree: Snapshot, listFrame: CGRect, window: WindowIdentity) -> [(NodeRecord, String)] {
    var rows: [(NodeRecord, String)] = []
    for index in tree.nodes.indices where index == 0 || isDescendant(index, of: 0, in: tree.nodes) {
        let node = tree.nodes[index]
        guard node.role == "AXRow", let frame = node.frame,
              frame.width >= 100, frame.height >= 18, frame.height <= 160,
              listFrame.contains(frame), window.bounds.contains(frame) else { continue }
        // 只去同一 AX element 的父子重複；真正同名的不同 row 必須保留。
        if rows.contains(where: { CFEqual($0.0.element, node.element) }) { continue }
        let values = descendantIndices(of: index, in: tree.nodes).compactMap { childIndex -> String? in
            let child = tree.nodes[childIndex]
            guard child.role == "AXStaticText", let childFrame = child.frame,
                  frame.contains(childFrame), listFrame.contains(childFrame) else { return nil }
            let value = child.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty || value.count > 200 ? nil : value
        }
        if let name = values.first { rows.append((node, name)) }
    }
    return rows.sorted { ($0.0.frame?.minY ?? 0) < ($1.0.frame?.minY ?? 0) }
}

func currentChatRows() throws -> (Snapshot, LineLayout, WindowIdentity, [(NodeRecord, String)]) {
    let (_, _, window, identity) = try mainWindow(requireForeground: true)
    let geometry = snapshot(window, mode: .geometryOnly)
    let layout = try lineLayout(geometry, window: identity)
    guard let listFrame = geometry.nodes[layout.leftListIndex].frame else {
        throw NativeFailure("SEMANTIC_UNRELIABLE", "左側聊天室 AXList 缺少 frame")
    }
    let tree = snapshot(geometry.nodes[layout.leftListIndex].element, mode: .text)
    return (tree, layout, identity, chatRows(tree, listFrame: listFrame, window: identity))
}

func pairedKey(_ keyCode: CGKeyCode) throws {
    guard let source = CGEventSource(stateID: .combinedSessionState),
          let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
        throw NativeFailure("KEY_EVENT_FAILED", "無法建立清單捲動鍵盤事件")
    }
    down.post(tap: .cghidEventTap)
    var released = false
    defer { if !released { up.post(tap: .cghidEventTap) } }
    up.post(tap: .cghidEventTap)
    released = true
}

struct ChatScanRow {
    let element: AXUIElement
    let name: String
    let identifier: String
}

struct ChatScanResult {
    let names: [String]
    let identity: WindowIdentity
    let complete: Bool
    let reasons: [String]
    let pages: Int
    let ambiguousNames: [String]
}

enum MetadataScanDirection { case top, end }

struct MetadataWheelProbe {
    let foreground: Bool
    let windowMatches: Bool
    let tabSelected: Bool
    let listStable: Bool
    let windowFrame: CGRect
    let listFrame: CGRect
}

struct MetadataWheelIntent {
    let point: CGPoint
    let delta: Int32
}

func metadataWheelIntent(_ probe: MetadataWheelProbe, direction: MetadataScanDirection,
                         remainingSteps: Int) -> MetadataWheelIntent? {
    let point = CGPoint(x: probe.listFrame.midX, y: probe.listFrame.midY)
    guard remainingSteps > 0, probe.foreground, probe.windowMatches, probe.tabSelected,
          probe.listStable, probe.windowFrame.contains(probe.listFrame),
          probe.listFrame.width > 0, probe.listFrame.height > 0,
          probe.listFrame.contains(point) else { return nil }
    return MetadataWheelIntent(point: point, delta: direction == .top ? 180 : -180)
}

func metadataNoProgressReasons(previous: String, current: String,
                               boundaryVerified: Bool,
                               direction: MetadataScanDirection) -> [String] {
    guard !previous.isEmpty, previous == current, !boundaryVerified else { return [] }
    return ["SCROLL_PROGRESS_UNVERIFIED",
            direction == .top ? "TOP_BOUNDARY_UNVERIFIED" : "END_BOUNDARY_UNVERIFIED"]
}

func metadataScanComplete(topBoundary: Bool, endBoundary: Bool, reasons: [String]) -> Bool {
    topBoundary && endBoundary && reasons.isEmpty
}

func postMetadataWheel(_ intent: MetadataWheelIntent) throws {
    guard let source = CGEventSource(stateID: .combinedSessionState),
          let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                              wheelCount: 1, wheel1: intent.delta, wheel2: 0, wheel3: 0) else {
        throw NativeFailure("SCROLL_EVENT_FAILED", "無法建立唯讀 metadata 垂直捲動事件")
    }
    event.location = intent.point
    event.post(tap: .cghidEventTap)
}

enum MetadataWheelPostResult {
    case posted
    case blocked(String)
}

func metadataWheelLimitReason(remainingSteps: Int, now: TimeInterval,
                              deadline: TimeInterval) -> String? {
    if remainingSteps <= 0 { return "SCAN_BUDGET" }
    if now >= deadline { return "SCAN_DEADLINE" }
    return nil
}

func postFreshMetadataWheel(expected: WindowIdentity, tabName: String,
                            expectedListFrame: CGRect,
                            direction: MetadataScanDirection,
                            remainingSteps: Int,
                            deadline: TimeInterval,
                            mode: TabNavigationMode = .legacy) throws -> MetadataWheelPostResult {
    if let reason = metadataWheelLimitReason(remainingSteps: remainingSteps,
                                             now: Date().timeIntervalSince1970,
                                             deadline: deadline) {
        return .blocked(reason)
    }
    let selected = try verifySelectedTab(tabName, mode: mode)
    let (_, _, window, current) = try mainWindow(requireForeground: true)
    guard sameWindow(expected, current), sameWindow(selected.0.identity, current) else {
        throw NativeFailure("WINDOW_CHANGED", "metadata wheel 前 fresh 視窗或 selected-tab 證據已漂移")
    }
    let geometry = snapshot(window, mode: .geometryOnly)
    let layout = try readTabLayout(geometry, window: current)
    guard let listFrame = geometry.nodes[layout.leftListIndex].frame,
          current.bounds.contains(listFrame), similar(expectedListFrame, listFrame, tolerance: 0.5),
          !overlayIntersects(current, roi: listFrame, windows: cgWindows(pid: current.pid)) else {
        throw NativeFailure("WINDOW_CHANGED", "metadata wheel 前 fresh 左側清單幾何已漂移")
    }
    if let reason = metadataWheelLimitReason(remainingSteps: remainingSteps,
                                             now: Date().timeIntervalSince1970,
                                             deadline: deadline) {
        return .blocked(reason)
    }
    // 所有布林值都來自本函式剛完成的 guards，不沿用先前 page snapshot。
    let probe = MetadataWheelProbe(foreground: true, windowMatches: true,
                                   tabSelected: true, listStable: true,
                                   windowFrame: current.bounds, listFrame: listFrame)
    guard let intent = metadataWheelIntent(probe, direction: direction,
                                           remainingSteps: remainingSteps) else {
        throw NativeFailure("SCROLL_GUARD_FAILED", "metadata fresh wheel 安全條件不成立")
    }
    try postMetadataWheel(intent)
    return .posted
}

func pageSignature(_ rows: [(NodeRecord, String)]) -> String {
    sha256(rows.map { row in
        let frame = row.0.frame ?? .zero
        return ["name": row.1, "identifier": stringAttribute(row.0.element, kAXIdentifierAttribute),
                "x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height] as [String: Any]
    })
}

func focusedChatPage(expected: WindowIdentity) throws -> (AXUIElement, [(NodeRecord, String)], Snapshot) {
    let (_, _, window, identity) = try mainWindow(requireForeground: true)
    guard sameWindow(expected, identity) else { throw NativeFailure("WINDOW_CHANGED", "聊天室掃描期間視窗已變更") }
    let geometry = snapshot(window, mode: .geometryOnly)
    let layout = try lineLayout(geometry, window: identity)
    let list = geometry.nodes[layout.leftListIndex]
    guard let listFrame = list.frame,
          AXUIElementSetAttributeValue(list.element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success,
          boolAttribute(list.element, kAXFocusedAttribute) else {
        throw NativeFailure("SEMANTIC_UNRELIABLE", "無法安全聚焦左側聊天室 AXList")
    }
    let tree = snapshot(list.element, mode: .text)
    return (list.element, chatRows(tree, listFrame: listFrame, window: identity), tree)
}

func scanTabChats(expected: WindowIdentity, deadlineSeconds: TimeInterval = 6) throws -> ChatScanResult {
    let deadline = Date().timeIntervalSince1970 + deadlineSeconds
    var reasons: [String] = []
    var previous = "", stable = 0
    // 先回到頂端；只有連續兩次相同頁面才視為 top 穩定。
    for _ in 0..<20 {
        guard Date().timeIntervalSince1970 < deadline else { reasons.append("SCAN_DEADLINE"); break }
        let page = try focusedChatPage(expected: expected)
        let signature = pageSignature(page.1)
        stable = signature == previous ? stable + 1 : 0
        previous = signature
        if stable >= 1 { break }
        try pairedKey(116) // PageUp
        Thread.sleep(forTimeInterval: 0.05)
    }
    if stable < 1 { reasons.append("TOP_BOUNDARY_UNVERIFIED") }

    var collected: [ChatScanRow] = []
    var pages = 0
    previous = ""; stable = 0
    var reachedEnd = false
    for _ in 0..<20 {
        guard Date().timeIntervalSince1970 < deadline else { reasons.append("SCAN_DEADLINE"); break }
        let page = try focusedChatPage(expected: expected)
        pages += 1
        if page.2.partial { reasons.append(contentsOf: page.2.reasons) }
        let syncing = page.2.nodes.flatMap(\.texts).contains {
            $0.localizedCaseInsensitiveContains("同步中") || $0.localizedCaseInsensitiveContains("syncing")
        }
        if syncing { reasons.append("SYNC_IN_PROGRESS") }
        for row in page.1 {
            let identifier = stringAttribute(row.0.element, kAXIdentifierAttribute)
            if identifier.isEmpty { reasons.append("ROW_IDENTITY_UNVERIFIED") }
            if let sameElement = collected.first(where: { CFEqual($0.element, row.0.element) }) {
                if sameElement.name == row.1 { continue }
                reasons.append("ROW_ELEMENT_REUSED")
                collected.append(ChatScanRow(element: row.0.element, name: row.1, identifier: ""))
                continue
            }
            if !identifier.isEmpty, collected.contains(where: { $0.identifier == identifier }) { continue }
            collected.append(ChatScanRow(element: row.0.element, name: row.1, identifier: identifier))
            if collected.count >= 1_000 { reasons.append("ROW_LIMIT"); break }
        }
        if collected.count >= 1_000 { break }
        let signature = pageSignature(page.1)
        stable = signature == previous ? stable + 1 : 0
        previous = signature
        if stable >= 1 { reachedEnd = true; break }
        try pairedKey(121) // PageDown
        Thread.sleep(forTimeInterval: 0.05)
    }
    if !reachedEnd { reasons.append("END_BOUNDARY_UNVERIFIED") }
    var counts: [String: Int] = [:]
    for row in collected { counts[row.name, default: 0] += 1 }
    let ambiguous = counts.filter { $0.value > 1 }.map(\.key).sorted()
    if !ambiguous.isEmpty { reasons.append("DUPLICATE_NAMES_AMBIGUOUS") }
    reasons = Array(Set(reasons)).sorted()
    return ChatScanResult(names: collected.map(\.name), identity: expected,
                          complete: reachedEnd && stable >= 1 && reasons.isEmpty,
                          reasons: reasons, pages: pages, ambiguousNames: ambiguous)
}

struct MetadataChatPage {
    let list: AXUIElement
    let listFrame: CGRect
    let rows: [(NodeRecord, String)]
    let tree: Snapshot
    let identity: WindowIdentity
    let boundary: HistoryScrollBoundary?
}

func metadataChatRows(_ tree: Snapshot, listFrame: CGRect,
                      window: WindowIdentity) -> [(NodeRecord, String)] {
    var rows: [(NodeRecord, String)] = []
    for index in tree.nodes.indices where index == 0 || isDescendant(index, of: 0, in: tree.nodes) {
        let row = tree.nodes[index]
        guard row.role == kAXRowRole, let rowFrame = row.frame,
              rowFrame.width >= 100, rowFrame.height >= 18, rowFrame.height <= 160,
              listFrame.contains(rowFrame), window.bounds.contains(rowFrame),
              !rows.contains(where: { CFEqual($0.0.element, row.element) }) else { continue }
        let nameNode = descendantIndices(of: index, in: tree.nodes).lazy.map { tree.nodes[$0] }.first {
            guard $0.role == kAXStaticTextRole, let frame = $0.frame else { return false }
            return rowFrame.contains(frame) && listFrame.contains(frame)
        }
        guard let nameNode else { continue }
        let name = stringAttribute(nameNode.element, kAXValueAttribute)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty && name.count <= 200 { rows.append((row, name)) }
    }
    return rows.sorted { ($0.0.frame?.minY ?? 0) < ($1.0.frame?.minY ?? 0) }
}

func metadataChatPage(expected: WindowIdentity, tabName: String,
                      mode: TabNavigationMode = .legacy) throws -> MetadataChatPage {
    let (_, _, window, before) = try mainWindow(requireForeground: true)
    guard sameWindow(expected, before) else {
        throw NativeFailure("WINDOW_CHANGED", "metadata 掃描前 LINE 視窗已變更")
    }
    let firstGeometry = snapshot(window, mode: .geometryOnly)
    let firstLayout = try readTabLayout(firstGeometry, window: before)
    guard let firstListFrame = firstGeometry.nodes[firstLayout.leftListIndex].frame,
          before.bounds.contains(firstListFrame),
          !overlayIntersects(before, roi: firstListFrame, windows: cgWindows(pid: before.pid)) else {
        throw NativeFailure("SEMANTIC_UNRELIABLE", "metadata 左側清單幾何或 overlay 不可靠")
    }
    let selected = try verifySelectedTab(tabName, mode: mode)
    guard sameWindow(before, selected.0.identity) else {
        throw NativeFailure("WINDOW_CHANGED", "metadata selected-tab 驗證期間視窗已變更")
    }
    let (_, _, currentWindow, current) = try mainWindow(requireForeground: true)
    let currentGeometry = snapshot(currentWindow, mode: .geometryOnly)
    let currentLayout = try readTabLayout(currentGeometry, window: current)
    let list = currentGeometry.nodes[currentLayout.leftListIndex]
    guard sameWindow(before, current), let listFrame = list.frame,
          current.bounds.contains(listFrame), similar(firstListFrame, listFrame, tolerance: 0.5),
          !overlayIntersects(current, roi: listFrame, windows: cgWindows(pid: current.pid)) else {
        throw NativeFailure("WINDOW_CHANGED", "metadata wheel 前視窗或左側清單幾何已漂移")
    }
    // metadata 路徑只保留結構；每列名稱由 metadataChatRows 單獨讀第一個合格 AXStaticText.value。
    let tree = snapshot(list.element, mode: .structure)
    return MetadataChatPage(list: list.element, listFrame: listFrame,
                            rows: metadataChatRows(tree, listFrame: listFrame, window: current),
                            tree: tree, identity: current,
                            boundary: messageScrollBoundary(list.element))
}

func scanTabChatsMetadata(expected: WindowIdentity, tabName: String,
                          deadlineSeconds: TimeInterval = 6,
                          stepLimit: Int = 20,
                          mode: TabNavigationMode = .legacy) throws -> ChatScanResult {
    let deadline = Date().timeIntervalSince1970 + deadlineSeconds
    let boundedSteps = min(max(stepLimit, 1), 20)
    var reasons: [String] = []
    var previous = ""
    var topBoundary = false
    var topWheelEvents = 0

    topScan: for _ in 0..<boundedSteps {
        guard Date().timeIntervalSince1970 < deadline else { reasons.append("SCAN_DEADLINE"); break }
        let page = try metadataChatPage(expected: expected, tabName: tabName, mode: mode)
        if page.tree.partial { reasons.append(contentsOf: page.tree.reasons) }
        let signature = pageSignature(page.rows)
        topBoundary = page.boundary?.earliest == true
        let progressReasons = metadataNoProgressReasons(
            previous: previous, current: signature, boundaryVerified: topBoundary, direction: .top
        )
        if topBoundary || !progressReasons.isEmpty {
            reasons.append(contentsOf: progressReasons)
            break
        }
        previous = signature
        switch try postFreshMetadataWheel(
            expected: expected, tabName: tabName, expectedListFrame: page.listFrame,
            direction: .top, remainingSteps: boundedSteps - topWheelEvents, deadline: deadline,
            mode: mode
        ) {
        case .posted: topWheelEvents += 1
        case let .blocked(reason):
            reasons.append(reason)
            break topScan
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    if !topBoundary && topWheelEvents >= boundedSteps &&
        !reasons.contains("SCAN_BUDGET") { reasons.append("SCAN_BUDGET") }
    if !topBoundary && !reasons.contains("TOP_BOUNDARY_UNVERIFIED") {
        reasons.append("TOP_BOUNDARY_UNVERIFIED")
    }

    var collected: [ChatScanRow] = []
    var pages = 0
    previous = ""
    var endBoundary = false
    var endWheelEvents = 0
    endScan: for _ in 0..<boundedSteps {
        guard Date().timeIntervalSince1970 < deadline else { reasons.append("SCAN_DEADLINE"); break }
        let page = try metadataChatPage(expected: expected, tabName: tabName, mode: mode)
        pages += 1
        if page.tree.partial { reasons.append(contentsOf: page.tree.reasons) }
        for row in page.rows {
            let identifier = stringAttribute(row.0.element, kAXIdentifierAttribute)
            if identifier.isEmpty { reasons.append("ROW_IDENTITY_UNVERIFIED") }
            if let sameElement = collected.first(where: { CFEqual($0.element, row.0.element) }) {
                if sameElement.name == row.1 { continue }
                reasons.append("ROW_ELEMENT_REUSED")
                collected.append(ChatScanRow(element: row.0.element, name: row.1, identifier: ""))
                continue
            }
            if !identifier.isEmpty, collected.contains(where: { $0.identifier == identifier }) { continue }
            collected.append(ChatScanRow(element: row.0.element, name: row.1, identifier: identifier))
            if collected.count >= 1_000 { reasons.append("ROW_LIMIT"); break }
        }
        if collected.count >= 1_000 { break }
        let signature = pageSignature(page.rows)
        endBoundary = page.boundary?.latest == true
        let progressReasons = metadataNoProgressReasons(
            previous: previous, current: signature, boundaryVerified: endBoundary, direction: .end
        )
        if endBoundary || !progressReasons.isEmpty {
            reasons.append(contentsOf: progressReasons)
            break
        }
        previous = signature
        switch try postFreshMetadataWheel(
            expected: expected, tabName: tabName, expectedListFrame: page.listFrame,
            direction: .end, remainingSteps: boundedSteps - endWheelEvents, deadline: deadline,
            mode: mode
        ) {
        case .posted: endWheelEvents += 1
        case let .blocked(reason):
            reasons.append(reason)
            break endScan
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    if !endBoundary && endWheelEvents >= boundedSteps &&
        !reasons.contains("SCAN_BUDGET") { reasons.append("SCAN_BUDGET") }
    if !endBoundary && !reasons.contains("END_BOUNDARY_UNVERIFIED") {
        reasons.append("END_BOUNDARY_UNVERIFIED")
    }
    var counts: [String: Int] = [:]
    for row in collected { counts[row.name, default: 0] += 1 }
    let ambiguous = counts.filter { $0.value > 1 }.map(\.key).sorted()
    if !ambiguous.isEmpty { reasons.append("DUPLICATE_NAMES_AMBIGUOUS") }
    reasons = Array(Set(reasons)).sorted()
    return ChatScanResult(names: collected.map(\.name), identity: expected,
                          complete: metadataScanComplete(topBoundary: topBoundary,
                                                         endBoundary: endBoundary, reasons: reasons),
                          reasons: reasons, pages: pages, ambiguousNames: ambiguous)
}

func listTabChats(_ args: [String: Any]) throws -> [String: Any] {
    guard let tabName = args["tabName"] as? String else { throw NativeFailure("INVALID_ARGUMENT", "缺少 tabName") }
    let limit = (args["limit"] as? NSNumber)?.intValue ?? 50
    let offset = (args["offset"] as? NSNumber)?.intValue ?? 0
    let identity = try navigateTab(tabName, expectedWindow: args["expectedWindow"], mode: .readOnly)
    let scan = try scanTabChatsMetadata(expected: identity, tabName: tabName, mode: .readOnly)
    guard !scan.names.isEmpty else { throw NativeFailure("SEMANTIC_UNRELIABLE", "bounded 掃描沒有可靠聊天室列") }
    let names = scan.names
    let digest = sha256(["window": identity.json, "tab": tabName, "chats": names,
                         "ocrProcessedPolicy": processedOCRPolicyVersion] as [String: Any])
    if let expected = args["expectedDigest"] as? String, expected != digest {
        throw NativeFailure("CURSOR_INVALID", "聊天室清單已變更")
    }
    guard offset >= 0, limit > 0, offset <= names.count else {
        throw NativeFailure("CURSOR_INVALID", "cursor 超出目前可見聊天室清單")
    }
    let end = min(names.count, offset + limit)
    var result: [String: Any] = [
        "tabName": tabName, "chats": Array(names[offset..<end]), "snapshotDigest": digest,
        "observedAt": ISO8601DateFormatter().string(from: Date()),
        "selectedTabVerified": true,
        "partial": !scan.complete, "complete": scan.complete, "reasons": scan.reasons,
        "pagesScanned": scan.pages, "ambiguousNames": scan.ambiguousNames,
    ]
    if end < names.count { result["nextOffset"] = end }
    return result
}

struct TabEvidence {
    let frame: OCRFrame
    let candidate: OCRCandidate
    let badge: GreenComponent
    let digest: String
}

func candidatePointBox(_ candidate: OCRCandidate, roi: CGRect) -> CGRect {
    CGRect(x: candidate.normalizedBox.minX * roi.width,
           y: (1 - candidate.normalizedBox.maxY) * roi.height,
           width: candidate.normalizedBox.width * roi.width,
           height: candidate.normalizedBox.height * roi.height)
}

func associatedUnreadBadges(_ frame: OCRFrame, candidate: OCRCandidate) -> [GreenComponent] {
    let text = candidatePointBox(candidate, roi: frame.roi)
    return frame.greenComponents.filter { badgeGeometryEligible($0, roiHeight: frame.roi.height) }.filter { badge in
        badge.pointBox.midX >= text.minX - 8 && badge.pointBox.midX <= text.maxX + 12 &&
            badge.pointBox.maxY <= text.midY + 2
    }
}

func associatedUnderlines(_ frame: OCRFrame, candidate: OCRCandidate) -> [UnderlineComponent] {
    let text = candidatePointBox(candidate, roi: frame.roi)
    return frame.underlineComponents.filter { eligibleUnderline($0, roiHeight: frame.roi.height) }.filter { line in
        let overlap = max(0, min(line.pointBox.maxX, text.maxX) - max(line.pointBox.minX, text.minX))
        return overlap >= min(line.pointBox.width, text.width) * 0.5 && line.pointBox.minY >= text.maxY - 2
    }
}

func verifySelectedTab(_ tabName: String,
                       mode: TabNavigationMode = .legacy,
                       expectedReadProfile: ReadColorProfile? = nil) throws
    -> (OCRFrame, OCRCandidate) {
    switch mode {
    case .legacy:
        guard tabNavigationProfileAllowed(.legacy, expected: expectedReadProfile,
                                          observed: nil) else {
            throw NativeFailure("TAB_SELECTION_UNVERIFIED",
                                "唯讀分頁色彩或 selected 證據不穩定")
        }
    case .readOnly:
        let selected = try verifyReadSelectedTab(tabName, expectedProfile: expectedReadProfile)
        return (selected.0.frame, selected.1)
    }
    let first = try captureOCR(.tabs, processedTabs: false)
    guard case .selected = rawSelectedProof([tabName], frame: first) else {
        throw NativeFailure("TAB_SELECTION_UNVERIFIED", "目標分頁缺少唯一且相對應的 selected underline")
    }
    Thread.sleep(forTimeInterval: 0.06)
    let second = try captureOCR(.tabs, processedTabs: false)
    guard let selected = try stableRawSelectedTab([tabName], first: first, second: second) else {
        throw NativeFailure("TAB_SELECTION_UNVERIFIED", "目標分頁 raw selected 證據消失")
    }
    return (second, selected.1)
}

// 只回傳數量、信心與幾何布林，讓選取失敗可診斷而不洩漏其他分頁名稱。
func readTabSelectionDiagnostics(_ tabName: String, frame: OCRFrame) -> [String: Any] {
    let trusted = trustedOCRCandidates(frame)
    let exact = trusted.filter { $0.text == tabName }
    let kind: String
    switch rawSelectedProof([tabName], frame: frame) {
    case .absent: kind = "absent"
    case .invalid: kind = "invalid"
    case .selected: kind = "selected"
    }
    let samples = Array(exact.prefix(4))
    let confidences: [Any] = samples.map {
        $0.confidence.isFinite ? Double($0.confidence) as Any : NSNull()
    }
    return [
        "proofKind": kind,
        "trustedSource": eligibleBadgeBoxes(frame).isEmpty ? "raw" : "masked",
        "trustedCandidateCount": trusted.count,
        "targetExactCount": exact.count,
        "targetConfidences": confidences,
        "targetBoxesValid": samples.map { validNormalizedBox($0.normalizedBox) },
        "targetUnderlineCounts": samples.map { associatedUnderlines(frame, candidate: $0).count },
        "invalidHighConfidenceCount": trusted.filter {
            $0.confidence >= ocrConfidenceThreshold && !validNormalizedBox($0.normalizedBox)
        }.count,
        "competingUnderlineCount": trusted.filter {
            $0.text != tabName && $0.confidence >= ocrConfidenceThreshold &&
                !associatedUnderlines(frame, candidate: $0).isEmpty
        }.count,
        "eligibleBadgeCount": eligibleBadgeBoxes(frame).count,
    ]
}

func stableReadSelectedTab(_ labels: [String], first: ReadOCRFrame,
                           second: ReadOCRFrame,
                           expectedProfile: ReadColorProfile? = nil) throws
    -> (ReadOCRFrame, OCRCandidate) {
    guard tabNavigationProfileAllowed(.readOnly, expected: expectedProfile,
                                      observed: first.profile),
          tabNavigationProfileAllowed(.readOnly, expected: first.profile,
                                      observed: second.profile) else {
        throw NativeFailure("TAB_SELECTION_UNVERIFIED",
                            "唯讀分頁色彩或 selected 證據不穩定")
    }
    guard let selected = try stableRawSelectedTab(labels, first: first.frame,
                                                   second: second.frame) else {
        throw NativeFailure("TAB_SELECTION_UNVERIFIED",
                            "唯讀分頁色彩或 selected 證據不穩定")
    }
    return (second, selected.1)
}

func verifyReadSelectedTab(_ tabName: String,
                           expectedProfile: ReadColorProfile? = nil) throws
    -> (ReadOCRFrame, OCRCandidate) {
    let first = try captureReadTabOCR()
    guard case .selected = rawSelectedProof([tabName], frame: first.frame) else {
        throw NativeFailure("TAB_SELECTION_UNVERIFIED", "目標分頁缺少唯一且相對應的 selected underline",
                            readTabSelectionDiagnostics(tabName, frame: first.frame))
    }
    Thread.sleep(forTimeInterval: 0.06)
    let second = try captureReadTabOCR()
    return try stableReadSelectedTab([tabName], first: first, second: second,
                                     expectedProfile: expectedProfile)
}

func tabEvidence(_ tabName: String) throws -> TabEvidence {
    let frame = try captureOCR(.tabs)
    let matches = exactOCRMatches(tabName, in: frame)
    guard matches.count == 1, let candidate = matches.first else {
        throw NativeFailure(matches.isEmpty ? "TAB_NOT_FOUND" : "AMBIGUOUS_MATCH",
                            "分頁 exact 候選無法唯一辨識", ["phase": "pre_commit"])
    }
    let rawMatches = trustedOCRCandidates(frame).filter { $0.text == tabName }
    guard rawMatches.count == 1, let rawCandidate = rawMatches.first else {
        throw NativeFailure("AMBIGUOUS_MATCH", "分頁 raw exact 候選無法唯一辨識", ["phase": "pre_commit"])
    }
    let badges = associatedUnreadBadges(frame, candidate: candidate)
    guard badges.count == 1, let badge = badges.first else {
        throw NativeFailure("UNREAD_STATE_UNOBSERVABLE", "無法唯一證明目標分頁未讀 indicator",
                            ["phase": "pre_commit", "count": badges.count])
    }
    let structure: [String: Any] = [
        "window": frame.identity.json,
        "roi": ["x": frame.roi.minX, "y": frame.roi.minY,
                "width": frame.roi.width, "height": frame.roi.height],
        "pixels": ["width": frame.imageWidth, "height": frame.imageHeight],
        "ocrPolicy": ["revision": ocrRevision, "confidence": ocrConfidenceThreshold,
                      "badge": "line-green-component-mask-v1",
                      "processed": processedOCRPolicyVersion],
        "rawCandidate": ["text": rawCandidate.text, "confidence": rawCandidate.confidence,
                           "x": rawCandidate.normalizedBox.minX, "y": rawCandidate.normalizedBox.minY,
                           "width": rawCandidate.normalizedBox.width, "height": rawCandidate.normalizedBox.height],
        "processedCandidate": ["text": candidate.text, "confidence": candidate.confidence,
                                "x": candidate.normalizedBox.minX, "y": candidate.normalizedBox.minY,
                                "width": candidate.normalizedBox.width, "height": candidate.normalizedBox.height],
        "badge": ["x": badge.pointBox.minX, "y": badge.pointBox.minY,
                  "width": badge.pointBox.width, "height": badge.pointBox.height,
                  "pixels": badge.pixelCount],
    ]
    return TabEvidence(frame: frame, candidate: candidate, badge: badge, digest: sha256(structure))
}

func openPopup(parent: WindowIdentity, anchorFrame: CGRect, point: CGPoint) throws -> WindowIdentity {
    try pairedSearchClick(expected: parent, fieldFrame: anchorFrame,
                          down: .rightMouseDown, up: .rightMouseUp, button: .right,
                          validateWhileDown: {
                              try validateParentDuringPopupTransition(parent: parent, fieldFrame: anchorFrame)
                          }, point: point)
    return try waitForSearchPopup(parent: parent, fieldFrame: anchorFrame)
}

func previewMarkTabRead(_ args: [String: Any]) throws -> [String: Any] {
    guard let tabName = args["tabName"] as? String else { throw NativeFailure("INVALID_ARGUMENT", "缺少 tabName") }
    let evidence = try tabEvidence(tabName)
    return ["snapshotDigest": evidence.digest, "expectedWindow": evidence.frame.identity.json,
            "preview": ["tabName": tabName, "operation": "markTabRead", "willMutate": true,
                        "unreadIndicatorObserved": true,
                        "observedAt": ISO8601DateFormatter().string(from: Date())]]
}

func snapshotMarkTabRead(_ args: [String: Any]) throws -> [String: Any] {
    guard let tabName = args["tabName"] as? String else { throw NativeFailure("INVALID_ARGUMENT", "缺少 tabName") }
    let evidence = try tabEvidence(tabName)
    try validateExpectedWindow(args["expectedWindow"], current: evidence.frame.identity)
    return ["snapshotDigest": evidence.digest, "expectedWindow": evidence.frame.identity.json]
}

func executeMarkTabRead(_ args: [String: Any]) throws -> [String: Any] {
    guard let tabName = args["tabName"] as? String,
          let expectedDigest = args["snapshotDigest"] as? String else {
        throw NativeFailure("INVALID_ARGUMENT", "執行全部已讀缺少必要欄位", ["phase": "pre_commit"])
    }
    let first = try tabEvidence(tabName)
    try validateExpectedWindow(args["expectedWindow"], current: first.frame.identity)
    guard first.digest == expectedDigest else {
        throw NativeFailure("SNAPSHOT_CHANGED", "提交前分頁／OCR／badge 證據已變更", ["phase": "pre_commit"])
    }
    Thread.sleep(forTimeInterval: 0.05)
    let second = try tabEvidence(tabName)
    _ = try stableOCRTarget(tabName, first: first.frame, second: second.frame)
    guard intersectionOverUnion(first.badge.pointBox, second.badge.pointBox) >= 0.80 else {
        throw NativeFailure("SNAPSHOT_CHANGED", "提交前未讀 badge 位置已變更", ["phase": "pre_commit"])
    }
    let geometry = CaptureGeometry(window: second.frame.identity.bounds, roi: second.frame.roi,
                                   imageWidth: second.frame.imageWidth, imageHeight: second.frame.imageHeight)
    let targetRect = try geometry.screenRect(for: second.candidate)
    let popup = try openPopup(parent: second.frame.identity, anchorFrame: targetRect,
                              point: CGPoint(x: targetRect.midX, y: targetRect.midY))
    do {
        _ = try clickPopupItem(parent: second.frame.identity, anchorFrame: targetRect, popup: popup,
                               labels: ["全部已讀", "全部標示為已讀", "Mark all as read"])
    } catch let failure as NativeFailure {
        if failure.details["phase"] as? String == "post_commit" { throw failure }
        try? dismissSearchPopup(parent: second.frame.identity, popup: popup, fieldFrame: targetRect)
        throw forcingPhase(failure, "pre_commit")
    }
    do {
        let after = try captureOCR(.tabs)
        let target = exactOCRMatches(tabName, in: after)
        guard target.count == 1, associatedUnreadBadges(after, candidate: target[0]).isEmpty else {
            throw NativeFailure("READBACK_UNVERIFIED", "提交後未讀 indicator 未證明消失", ["phase": "post_commit"])
        }
        let observedAt = ISO8601DateFormatter().string(from: Date())
        return ["success": true, "action": "markTabRead", "tabName": tabName,
                "readback": ["allReadObserved": true, "observedAt": observedAt,
                             "timeCutoff": observedAt, "serverPermanent": false]]
    } catch let failure as NativeFailure {
        throw forcingPhase(failure, "post_commit")
    }
}

struct PasteboardBackup {
    let items: [[(NSPasteboard.PasteboardType, Data)]]
    init(_ pasteboard: NSPasteboard) throws {
        var captured: [[(NSPasteboard.PasteboardType, Data)]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var values: [(NSPasteboard.PasteboardType, Data)] = []
            for type in item.types {
                guard let data = item.data(forType: type) else {
                    throw NativeFailure("CLIPBOARD_BACKUP_FAILED", "無法完整備份剪貼簿，不執行貼上")
                }
                values.append((type, data))
            }
            captured.append(values)
        }
        items = captured
    }

    func restore(_ pasteboard: NSPasteboard, onlyIf changeCount: Int) -> Bool {
        guard pasteboard.changeCount == changeCount else { return false }
        pasteboard.clearContents()
        guard !items.isEmpty else { return true }
        let restored = items.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        return pasteboard.writeObjects(restored)
    }
}

func freshSearchField(expected: WindowIdentity) throws -> (AXUIElement, AXUIElement, CGRect, String) {
    let (_, appElement, window, identity) = try mainWindow(requireForeground: true)
    guard sameWindow(expected, identity) else { throw NativeFailure("WINDOW_CHANGED", "搜尋期間 LINE 視窗已變更") }
    let geometry = snapshot(window, mode: .geometryOnly)
    // 搜尋前可能尚未開啟聊天室；只需左側搜尋欄幾何，不要求右側 composer。
    let layout = try readTabLayout(geometry, window: identity)
    let record = geometry.nodes[layout.searchFieldIndex]
    guard let frame = record.frame else { throw NativeFailure("SEMANTIC_UNRELIABLE", "搜尋欄缺少 frame") }
    return (appElement, record.element, frame, stringAttribute(record.element, kAXValueAttribute))
}

func postMouse(_ type: CGEventType, button: CGMouseButton, point: CGPoint) throws {
    guard let source = CGEventSource(stateID: .combinedSessionState),
          let event = CGEvent(mouseEventSource: source, mouseType: type,
                              mouseCursorPosition: point, mouseButton: button) else {
        throw NativeFailure("MOUSE_EVENT_FAILED", "無法建立搜尋欄滑鼠事件")
    }
    event.post(tap: .cghidEventTap)
}

func revalidatedSearchPoint(expected: WindowIdentity, expectedFrame: CGRect) throws -> CGPoint {
    let (_, _, frame, _) = try freshSearchField(expected: expected)
    guard similar(frame, expectedFrame, tolerance: 0.5) else {
        throw NativeFailure("WINDOW_CHANGED", "搜尋欄 frame 已漂移")
    }
    return CGPoint(x: frame.midX, y: frame.midY)
}

func pairedSearchClick(expected: WindowIdentity, fieldFrame: CGRect,
                       down: CGEventType, up: CGEventType, button: CGMouseButton,
                       validateWhileDown: (() throws -> Void)? = nil,
                       point overridePoint: CGPoint? = nil) throws {
    let point: CGPoint
    if let overridePoint { point = overridePoint }
    else { point = try revalidatedSearchPoint(expected: expected, expectedFrame: fieldFrame) }
    try postMouse(down, button: button, point: point)
    var released = false
    defer {
        if !released { try? postMouse(up, button: button, point: point) }
    }
    if let validateWhileDown { try validateWhileDown() }
    else { _ = try revalidatedSearchPoint(expected: expected, expectedFrame: fieldFrame) }
    try postMouse(up, button: button, point: point)
    released = true
}

func searchPopup(parent: WindowIdentity, fieldFrame: CGRect) throws -> (AXUIElement, WindowIdentity) {
    let app = try lineApplication()
    guard app.processIdentifier == parent.pid,
          NSWorkspace.shared.frontmostApplication?.processIdentifier == parent.pid else {
        throw NativeFailure("FOREGROUND_REQUIRED", "搜尋 popup 驗證時 LINE 不在前景")
    }
    let appElement = AXUIElementCreateApplication(parent.pid)
    let axCandidates = (copyAttribute(appElement, kAXWindowsAttribute) as? [AXUIElement] ?? []).compactMap {
        window -> (AXUIElement, CGRect)? in
        guard stringAttribute(window, kAXRoleAttribute) == kAXWindowRole,
              stringAttribute(window, kAXSubroleAttribute) == kAXDialogSubrole,
              !boolAttribute(window, kAXModalAttribute), stringAttribute(window, kAXTitleAttribute).isEmpty,
              let frame = frameAttribute(window), frame.width >= 40, frame.width <= 300,
              frame.height >= 40, frame.height <= 300,
              parent.bounds.contains(frame), frame.intersects(fieldFrame.insetBy(dx: -20, dy: -160)) else { return nil }
        return (window, frame)
    }
    var bound: [CGWindowID: (AXUIElement, CGRect, [String: Any])] = [:]
    for candidate in axCandidates {
        let matches = allCGWindows(pid: parent.pid).filter { window in
            guard let raw = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = rect(from: raw) else { return false }
            return similar(frame, candidate.1, tolerance: 1)
        }
        guard matches.count == 1, let cg = matches.first,
              let rawID = cg[kCGWindowNumber as String] as? NSNumber,
              rawID.uint32Value != parent.windowID else { continue }
        bound[rawID.uint32Value] = (candidate.0, candidate.1, cg)
    }
    guard bound.count == 1, let (windowID, candidate) = bound.first else {
        throw NativeFailure(bound.isEmpty ? "SEARCH_POPUP_NOT_FOUND" : "SEARCH_POPUP_AMBIGUOUS",
                            "無法唯一綁定搜尋欄文字 popup", ["count": bound.count])
    }
    let popup = WindowIdentity(pid: parent.pid, windowID: windowID, title: "", bounds: candidate.1,
                               executableURL: parent.executableURL,
                               signingIdentifier: parent.signingIdentifier, teamIdentifier: parent.teamIdentifier)
    return (candidate.0, popup)
}

func validateParentWithOwnPopup(parent: WindowIdentity, popup: WindowIdentity,
                                fieldFrame: CGRect) throws {
    let app = try lineApplication()
    guard app.processIdentifier == parent.pid,
          NSWorkspace.shared.frontmostApplication?.processIdentifier == parent.pid else {
        throw NativeFailure("FOREGROUND_REQUIRED", "popup 開啟期間 LINE 不在前景")
    }
    let mainMatches = allCGWindows(pid: parent.pid).filter { window in
        guard (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value == parent.windowID,
              let raw = window[kCGWindowBounds as String] as? [String: Any],
              let frame = rect(from: raw) else { return false }
        return similar(frame, parent.bounds, tolerance: 0.5)
    }
    guard mainMatches.count == 1 else { throw NativeFailure("WINDOW_CHANGED", "popup 開啟期間 parent 已變更") }
    let (_, currentPopup) = try searchPopup(parent: parent, fieldFrame: fieldFrame)
    guard sameWindow(popup, currentPopup) else { throw NativeFailure("WINDOW_CHANGED", "搜尋 popup 已變更") }
    let appElement = AXUIElementCreateApplication(parent.pid)
    let dangerous = (copyAttribute(appElement, kAXWindowsAttribute) as? [AXUIElement] ?? []).contains {
        boolAttribute($0, kAXModalAttribute) || stringAttribute($0, kAXRoleAttribute) == kAXSheetRole
    }
    guard !dangerous else { throw NativeFailure("MODAL_PRESENT", "popup 開啟期間出現其他 modal/sheet") }
}

func retryablePopupTransition(_ code: String) -> Bool { code == "SEARCH_POPUP_NOT_FOUND" }

func validateParentDuringPopupTransition(parent: WindowIdentity, fieldFrame: CGRect) throws {
    let app = try lineApplication()
    guard app.processIdentifier == parent.pid,
          NSWorkspace.shared.frontmostApplication?.processIdentifier == parent.pid else {
        throw NativeFailure("FOREGROUND_REQUIRED", "right-click transition 期間 LINE 不在前景")
    }
    let mainMatches = allCGWindows(pid: parent.pid).filter { window in
        guard (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value == parent.windowID,
              let raw = window[kCGWindowBounds as String] as? [String: Any],
              let frame = rect(from: raw) else { return false }
        return similar(frame, parent.bounds, tolerance: 0.5)
    }
    guard mainMatches.count == 1 else { throw NativeFailure("WINDOW_CHANGED", "right-click transition 期間 parent 已變更") }
    let appElement = AXUIElementCreateApplication(parent.pid)
    let dangerous = (copyAttribute(appElement, kAXWindowsAttribute) as? [AXUIElement] ?? []).contains {
        boolAttribute($0, kAXModalAttribute) || stringAttribute($0, kAXRoleAttribute) == kAXSheetRole
    }
    guard !dangerous else { throw NativeFailure("MODAL_PRESENT", "right-click transition 期間出現 modal/sheet") }
    do { _ = try searchPopup(parent: parent, fieldFrame: fieldFrame) }
    catch let failure as NativeFailure where retryablePopupTransition(failure.code) { return }
}

func waitForSearchPopup(parent: WindowIdentity, fieldFrame: CGRect,
                        timeout: TimeInterval = 0.5) throws -> WindowIdentity {
    let deadline = Date().timeIntervalSince1970 + timeout
    while true {
        do { return try searchPopup(parent: parent, fieldFrame: fieldFrame).1 }
        catch let failure as NativeFailure where retryablePopupTransition(failure.code) {
            if Date().timeIntervalSince1970 >= deadline { throw failure }
            Thread.sleep(forTimeInterval: 0.025)
        }
    }
}

func dismissSearchPopup(parent: WindowIdentity, popup: WindowIdentity,
                        fieldFrame: CGRect) throws {
    let points = [0.25, 0.75].map { fraction in
        CGPoint(x: fieldFrame.minX + fieldFrame.width * fraction, y: fieldFrame.midY)
    }
    try validateParentWithOwnPopup(parent: parent, popup: popup, fieldFrame: fieldFrame)
    guard let safePoint = points.first(where: { fieldFrame.contains($0) && !popup.bounds.contains($0) }) else {
        // 錨點被 popup 完全遮住時只送 Escape 關閉；不點擊其他 UI，也不使用 Return。
        try pairedKey(53)
        Thread.sleep(forTimeInterval: 0.06)
        let visible = allCGWindows(pid: parent.pid).contains {
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == popup.windowID
        }
        guard !visible else { throw NativeFailure("POPUP_CLEANUP_FAILED", "Escape 後 popup 尚未消失") }
        return
    }
    try pairedSearchClick(expected: parent, fieldFrame: fieldFrame,
                          down: .leftMouseDown, up: .leftMouseUp, button: .left,
                          validateWhileDown: {
                              let visible = allCGWindows(pid: parent.pid).contains {
                                  ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == popup.windowID
                              }
                              if visible {
                                  try validateParentWithOwnPopup(parent: parent, popup: popup, fieldFrame: fieldFrame)
                              } else {
                                  let (_, _, _, current) = try mainWindow(requireForeground: true)
                                  guard sameWindow(parent, current) else {
                                      throw NativeFailure("WINDOW_CHANGED", "popup dismiss down 後 parent 已變更")
                                  }
                              }
                          }, point: safePoint)
    Thread.sleep(forTimeInterval: 0.06)
    let popupStillVisible = allCGWindows(pid: parent.pid).contains {
        ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == popup.windowID
    }
    guard !popupStillVisible else { throw NativeFailure("POPUP_CLEANUP_FAILED", "搜尋 popup CGWindow 尚未消失") }
    let (appElement, field, _, _) = try freshSearchField(expected: parent)
    guard let focusedRaw = copyAttribute(appElement, kAXFocusedUIElementAttribute),
          CFGetTypeID(focusedRaw) == AXUIElementGetTypeID(),
          CFEqual(focusedRaw as! AXUIElement, field) else {
        throw NativeFailure("POPUP_CLEANUP_FAILED", "popup 關閉後 parent/focus 無法驗證")
    }
}

struct PopupOCRFrame {
    let identity: WindowIdentity
    let imageWidth: Int
    let imageHeight: Int
    let candidates: [OCRCandidate]
}

@available(macOS 14.0, *)
func capturePopupOCR(parent: WindowIdentity, fieldFrame: CGRect) throws -> PopupOCRFrame {
    let (_, popup) = try searchPopup(parent: parent, fieldFrame: fieldFrame)
    let semaphore = DispatchSemaphore(value: 0)
    let contentBox = AsyncBox<Result<SCShareableContent, Error>>()
    SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, error in
        if let content { contentBox.set(.success(content)) }
        else { contentBox.set(.failure(error ?? NativeFailure("CAPTURE_UNAVAILABLE", "無法取得 popup 視窗"))) }
        semaphore.signal()
    }
    guard semaphore.wait(timeout: .now() + 2) == .success,
          let contentResult = contentBox.get(), let content = try? contentResult.get() else {
        throw NativeFailure("CAPTURE_TIMEOUT", "取得 popup 視窗逾時")
    }
    let matches = content.windows.filter {
        $0.windowID == popup.windowID && $0.owningApplication?.processID == popup.pid &&
        similar($0.frame, popup.bounds, tolerance: 1)
    }
    guard matches.count == 1, let scWindow = matches.first else {
        throw NativeFailure("CAPTURE_WINDOW_MISMATCH", "ScreenCaptureKit popup 身分不唯一", ["count": matches.count])
    }
    let filter = SCContentFilter(desktopIndependentWindow: scWindow)
    let scale = CGFloat(filter.pointPixelScale)
    guard scale.isFinite, scale >= 0.5, scale <= 4 else {
        throw NativeFailure("CAPTURE_GEOMETRY_INVALID", "popup pointPixelScale 不合理")
    }
    let configuration = SCStreamConfiguration()
    configuration.width = Int(round(popup.bounds.width * scale))
    configuration.height = Int(round(popup.bounds.height * scale))
    configuration.showsCursor = false
    configuration.ignoreShadowsSingleWindow = true
    configuration.scalesToFit = true
    let captureSemaphore = DispatchSemaphore(value: 0)
    let imageBox = AsyncBox<Result<CGImage, Error>>()
    SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
        if let image { imageBox.set(.success(image)) }
        else { imageBox.set(.failure(error ?? NativeFailure("CAPTURE_UNAVAILABLE", "無法擷取 popup"))) }
        captureSemaphore.signal()
    }
    guard captureSemaphore.wait(timeout: .now() + 2.5) == .success,
          let imageResult = imageBox.get(), let image = try? imageResult.get() else {
        throw NativeFailure("CAPTURE_TIMEOUT", "擷取 popup 逾時")
    }
    let (_, after) = try searchPopup(parent: parent, fieldFrame: fieldFrame)
    guard sameWindow(popup, after) else { throw NativeFailure("WINDOW_CHANGED", "popup 擷取期間已變更") }
    let candidates = try visionRequest(image).compactMap { observation -> OCRCandidate? in
        guard let candidate = observation.topCandidates(1).first else { return nil }
        let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : OCRCandidate(text: text, confidence: candidate.confidence,
                                                 normalizedBox: observation.boundingBox)
    }
    return PopupOCRFrame(identity: popup, imageWidth: image.width,
                         imageHeight: image.height, candidates: candidates)
}

func stablePopupTarget(_ labels: [String], first: PopupOCRFrame,
                       second: PopupOCRFrame) throws -> OCRCandidate {
    guard sameWindow(first.identity, second.identity),
          first.imageWidth == second.imageWidth, first.imageHeight == second.imageHeight else {
        throw NativeFailure("WINDOW_CHANGED", "兩次 popup OCR 的身分或像素尺寸已變更", ["phase": "pre_commit"])
    }
    let old = first.candidates.filter { $0.confidence >= ocrConfidenceThreshold && labels.contains($0.text) }
    let current = second.candidates.filter { $0.confidence >= ocrConfidenceThreshold && labels.contains($0.text) }
    guard old.count == 1, current.count == 1, let a = old.first, let b = current.first,
          a.text == b.text else {
        throw NativeFailure(max(old.count, current.count) > 1 ? "AMBIGUOUS_MATCH" : "POPUP_ITEM_NOT_FOUND",
                            "popup 白名單項目無法唯一 exact 辨識", ["phase": "pre_commit"])
    }
    guard intersectionOverUnion(a.normalizedBox, b.normalizedBox) >= 0.80 else {
        throw NativeFailure("OCR_TARGET_DRIFT", "popup 白名單項目 bbox 不穩定", ["phase": "pre_commit"])
    }
    return b
}

func popupTargetPoint(_ candidate: OCRCandidate, frame: PopupOCRFrame) throws -> CGPoint {
    let geometry = CaptureGeometry(window: frame.identity.bounds, roi: frame.identity.bounds,
                                   imageWidth: frame.imageWidth, imageHeight: frame.imageHeight)
    let rect = try geometry.screenRect(for: candidate)
    return CGPoint(x: rect.midX, y: rect.midY)
}

@available(macOS 14.0, *)
func clickPopupItem(parent: WindowIdentity, anchorFrame: CGRect,
                    popup: WindowIdentity, labels: [String]) throws -> String {
    let first = try capturePopupOCR(parent: parent, fieldFrame: anchorFrame)
    guard sameWindow(popup, first.identity) else { throw NativeFailure("WINDOW_CHANGED", "popup OCR 身分不符") }
    Thread.sleep(forTimeInterval: 0.05)
    let second = try capturePopupOCR(parent: parent, fieldFrame: anchorFrame)
    let candidate = try stablePopupTarget(labels, first: first, second: second)
    let point = try popupTargetPoint(candidate, frame: second)
    try validateParentWithOwnPopup(parent: parent, popup: popup, fieldFrame: anchorFrame)
    do {
        try pairedSearchClick(expected: parent, fieldFrame: anchorFrame,
                              down: .leftMouseDown, up: .leftMouseUp, button: .left,
                              validateWhileDown: {
                                  try validateParentWithOwnPopup(parent: parent, popup: popup, fieldFrame: anchorFrame)
                              }, point: point)
    } catch {
        // left-down 後選單是否已接受無法可靠判斷，一律視為提交後不明。
        throw NativeFailure("POPUP_COMMIT_UNCERTAIN", "popup 點擊結果不明", ["phase": "post_commit"])
    }
    Thread.sleep(forTimeInterval: 0.06)
    guard !allCGWindows(pid: parent.pid).contains(where: {
        ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == popup.windowID
    }) else {
        throw NativeFailure("POPUP_COMMIT_UNCERTAIN", "點擊後 popup 未消失", ["phase": "post_commit"])
    }
    return candidate.text
}

func pressSearchMenuItem(_ labels: [String], expected: WindowIdentity) throws {
    let (_, _, fieldFrame, _) = try freshSearchField(expected: expected)
    try pairedSearchClick(expected: expected, fieldFrame: fieldFrame,
                          down: .leftMouseDown, up: .leftMouseUp, button: .left)
    Thread.sleep(forTimeInterval: 0.04)
    let (focusedApp, focusedField, _, _) = try freshSearchField(expected: expected)
    guard let focusedRaw = copyAttribute(focusedApp, kAXFocusedUIElementAttribute),
          CFGetTypeID(focusedRaw) == AXUIElementGetTypeID() else {
        throw NativeFailure("SEARCH_FOCUS_UNVERIFIED", "原生點擊後搜尋欄未成為 focused element")
    }
    let focused = focusedRaw as! AXUIElement
    guard CFEqual(focused, focusedField) else {
        throw NativeFailure("SEARCH_FOCUS_UNVERIFIED", "原生點擊後焦點不在搜尋欄")
    }
    var openedPopup: WindowIdentity?
    try pairedSearchClick(expected: expected, fieldFrame: fieldFrame,
                          down: .rightMouseDown, up: .rightMouseUp, button: .right,
                          validateWhileDown: {
                              try validateParentDuringPopupTransition(parent: expected, fieldFrame: fieldFrame)
                          })
    openedPopup = try waitForSearchPopup(parent: expected, fieldFrame: fieldFrame)
    Thread.sleep(forTimeInterval: 0.08)
    guard #available(macOS 14.0, *) else {
        throw NativeFailure("UNSUPPORTED_OS_VERSION", "popup OCR 需要 macOS 14 以上")
    }
    guard let openedPopup else { throw NativeFailure("SEARCH_POPUP_NOT_FOUND", "right-click 未建立 popup") }
    do {
        _ = try clickPopupItem(parent: expected, anchorFrame: fieldFrame,
                               popup: openedPopup, labels: labels)
    } catch let failure as NativeFailure {
        if failure.details["phase"] as? String != "post_commit" {
            try? dismissSearchPopup(parent: expected, popup: openedPopup, fieldFrame: fieldFrame)
        }
        throw failure
    }
}

func setSearchValue(_ value: String, expected: WindowIdentity) throws -> [String: Any] {
    // 未知貼上可能已成功；先 exact 回讀，避免再開選單或碰剪貼簿。
    let (_, _, _, existing) = try freshSearchField(expected: expected)
    if globalQueryMatches(observed: existing, expected: value) {
        return ["usedClipboard": false, "clipboardUnchanged": true,
                "clipboardRestored": false, "externalClipboardChange": false]
    }
    let pasteboard = NSPasteboard.general
    let backup = try PasteboardBackup(pasteboard)
    pasteboard.clearContents()
    guard pasteboard.setString(value, forType: .string) else {
        throw NativeFailure("CLIPBOARD_WRITE_FAILED", "無法寫入暫時搜尋文字")
    }
    let ownChangeCount = pasteboard.changeCount
    do {
        let (_, _, _, existing) = try freshSearchField(expected: expected)
        if !existing.isEmpty { try pressSearchMenuItem(["全選", "Select All"], expected: expected) }
        guard pasteboard.changeCount == ownChangeCount else {
            throw NativeFailure("CLIPBOARD_CHANGED", "貼上前剪貼簿已被其他程式變更")
        }
        try pressSearchMenuItem(["貼上", "Paste"], expected: expected)
        Thread.sleep(forTimeInterval: 0.2)
        let (_, _, _, readback) = try freshSearchField(expected: expected)
        guard readback == value else { throw NativeFailure("SEARCH_QUERY_UNVERIFIED", "搜尋欄未回讀 exact 查詢") }
        let restored = backup.restore(pasteboard, onlyIf: ownChangeCount)
        return ["usedClipboard": true, "clipboardRestored": restored,
                "externalClipboardChange": !restored]
    } catch {
        _ = backup.restore(pasteboard, onlyIf: ownChangeCount)
        throw error
    }
}

enum IndexedSearchMutationRoute: Equatable { case alreadyExact, axValue, clipboard }

func indexedSearchMutationRoute(alreadyExact: Bool, settableStatus: AXError,
                                settable: Bool) -> IndexedSearchMutationRoute? {
    if alreadyExact { return .alreadyExact }
    guard settableStatus == .success else { return nil }
    return settable ? .axValue : .clipboard
}

func indexedPassiveCommitAllowed(queryExact: Bool, popupAbsent: Bool) -> Bool {
    queryExact && popupAbsent
}

func indexedSearchTransientFailure(_ code: String) -> Bool {
    ["INDEXED_SECTION_UNVERIFIED", "INDEXED_NAME_PROFILE_UNVERIFIED",
     "INDEXED_NAME_BAND_UNVERIFIED", "INDEXED_NAME_UNVERIFIED"].contains(code)
}

func indexedSearchSettleCore<T>(clock: () -> TimeInterval,
                                guardFresh: () throws -> Void,
                                probe: () throws -> T,
                                pause: () -> Void) throws -> T {
    let started = clock(), deadline = started + 8
    guard started.isFinite else {
        throw NativeFailure("SEARCH_RESULTS_NOT_READY", "搜尋結果 settle monotonic clock 無效")
    }
    var lastTransient: NativeFailure?
    for _ in 0..<160 {
        let now = clock()
        guard now.isFinite else {
            throw NativeFailure("SEARCH_RESULTS_NOT_READY", "搜尋結果 settle monotonic clock 無效")
        }
        if now >= deadline {
            if let lastTransient { throw lastTransient }
            throw NativeFailure("SEARCH_RESULTS_NOT_READY", "搜尋結果尚未在固定期限內穩定")
        }
        // window／focus／query 不是 renderer settle 狀態，任何漂移都立即停止。
        try guardFresh()
        do {
            let value = try probe()
            let afterProbe = clock()
            guard afterProbe.isFinite else {
                throw NativeFailure("SEARCH_RESULTS_NOT_READY", "搜尋結果 settle monotonic clock 無效")
            }
            if afterProbe >= deadline {
                if let lastTransient { throw lastTransient }
                throw NativeFailure("SEARCH_RESULTS_NOT_READY", "搜尋結果在固定期限後才穩定")
            }
            return value
        }
        catch let failure as NativeFailure {
            guard indexedSearchTransientFailure(failure.code) else { throw failure }
            lastTransient = failure
        }
        if clock() >= deadline { throw lastTransient! }
        pause()
    }
    if let lastTransient { throw lastTransient }
    throw NativeFailure("SEARCH_RESULTS_NOT_READY", "搜尋結果尚未在固定次數內穩定")
}

func settledIndexedSearchTarget(chatName: String, resultIndex: Int,
                                expected: WindowIdentity) throws -> IndexedSearchTarget {
    try indexedSearchSettleCore(clock: { ProcessInfo.processInfo.systemUptime }, guardFresh: {
        _ = try strictGlobalAllWindow(expected: expected.json)
        let (_, _, _, query) = try freshSearchField(expected: expected)
        guard globalQueryMatches(observed: query, expected: chatName) else {
            throw NativeFailure("SEARCH_QUERY_CHANGED", "搜尋結果 settle 期間 query 漂移")
        }
    }, probe: {
        try stableIndexedSearchTarget(chatName: chatName, resultIndex: resultIndex,
                                      expected: expected)
    }, pause: { Thread.sleep(forTimeInterval: 0.05) })
}

func setIndexedSearchValue(_ value: String, resultIndex: Int,
                           expected: WindowIdentity) throws -> [String: Any] {
    let (_, field, _, existing) = try freshSearchField(expected: expected)
    let alreadyExact = globalQueryMatches(observed: existing, expected: value)
    var settable = DarwinBoolean(false)
    let settableStatus = alreadyExact ? AXError.success :
        AXUIElementIsAttributeSettable(field, kAXValueAttribute as CFString, &settable)
    guard let route = indexedSearchMutationRoute(
        alreadyExact: alreadyExact, settableStatus: settableStatus,
        settable: settable.boolValue
    ) else {
        // AX settable 狀態未知時不可改走 clipboard；避免雙重輸入。
        throw NativeFailure("SEARCH_SET_CAPABILITY_UNKNOWN", "搜尋欄 AXValue settable 狀態未知")
    }
    if route == .alreadyExact {
        _ = try settledIndexedSearchTarget(chatName: value, resultIndex: resultIndex,
                                           expected: expected)
        return ["route": "already_exact", "setAttempts": 0]
    }
    if route == .axValue {
        guard AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString,
                                           value as CFString) == .success else {
            throw NativeFailure("SEARCH_SET_FAILED", "搜尋欄 AXValue 設定失敗")
        }
        Thread.sleep(forTimeInterval: 0.2)
        let (_, _, _, readback) = try freshSearchField(expected: expected)
        guard globalQueryMatches(observed: readback, expected: value) else {
            throw NativeFailure("SEARCH_QUERY_UNVERIFIED", "AX set後搜尋欄未 exact 回讀")
        }
        _ = try settledIndexedSearchTarget(chatName: value, resultIndex: resultIndex,
                                           expected: expected)
        return ["route": "ax_value", "setAttempts": 1]
    }
    do {
        let result = try setSearchValue(value, expected: expected)
        _ = try settledIndexedSearchTarget(chatName: value, resultIndex: resultIndex,
                                           expected: expected)
        return ["route": "clipboard", "setAttempts": 1, "clipboard": result]
    } catch let failure as NativeFailure where failure.code == "POPUP_COMMIT_UNCERTAIN" {
        let (_, _, fieldFrame, readback) = try freshSearchField(expected: expected)
        let queryExact = globalQueryMatches(observed: readback, expected: value)
        var popupAbsent = false
        do {
            _ = try searchPopup(parent: expected, fieldFrame: fieldFrame)
        } catch let popupFailure as NativeFailure where popupFailure.code == "SEARCH_POPUP_NOT_FOUND" {
            popupAbsent = true
        }
        guard indexedPassiveCommitAllowed(queryExact: queryExact, popupAbsent: popupAbsent) else {
            throw failure
        }
        _ = try settledIndexedSearchTarget(chatName: value, resultIndex: resultIndex,
                                           expected: expected)
        return ["route": "clipboard_passive_positive", "setAttempts": 1]
    }
}

struct GlobalSearchRowProof {
    let token: Int
    let name: String?
    let index: Int
    let frame: CGRect
    let selected: Bool
    let enabled: Bool
    let supportsPress: Bool
}

func globalSearchModelValid(_ rows: [GlobalSearchRowProof],
                            listFrame: CGRect, windowFrame: CGRect) -> Bool {
    guard (1...20).contains(rows.count), Set(rows.map(\.token)).count == rows.count,
          rows.map(\.index) == Array(0..<rows.count),
          rows.allSatisfy({ $0.name != nil && listFrame.contains($0.frame) &&
              windowFrame.contains($0.frame) && $0.frame.width > 0 &&
              $0.frame.height >= 18 && $0.frame.height <= 160 }) else { return false }
    return zip(rows, rows.dropFirst()).allSatisfy { $0.frame.maxY <= $1.frame.minY + 0.5 }
}

func globalSearchModelsStable(_ first: [GlobalSearchRowProof],
                              _ second: [GlobalSearchRowProof]) -> Bool {
    first.count == second.count && zip(first, second).allSatisfy {
        $0.token == $1.token && $0.name == $1.name && $0.index == $1.index &&
            similar($0.frame, $1.frame, tolerance: 0.5) &&
            $0.selected == $1.selected && $0.enabled == $1.enabled &&
            $0.supportsPress == $1.supportsPress
    }
}

func globalSemanticName(rowTitle: String?, relatedTitle: String?) -> String? {
    if let rowTitle, let relatedTitle { return rowTitle == relatedTitle ? rowTitle : nil }
    return rowTitle ?? relatedTitle
}

func globalQueryMatches(observed: String?, expected: String) -> Bool {
    observed == expected
}

func globalHeaderNamesVerify(_ names: [String], target: String) -> Bool {
    names.filter { $0 == target }.count == 1
}

// 回傳最後 fresh 模型的 token；同名、重排或 stale handle 都只會得到 nil。
func globalPressTarget(previous: [GlobalSearchRowProof], final: [GlobalSearchRowProof],
                       chatName: String, listFrame: CGRect,
                       windowFrame: CGRect) -> Int? {
    guard globalSearchModelValid(previous, listFrame: listFrame, windowFrame: windowFrame),
          globalSearchModelValid(final, listFrame: listFrame, windowFrame: windowFrame),
          globalSearchModelsStable(previous, final) else { return nil }
    let matches = final.filter { $0.name == chatName }
    guard matches.count == 1, let target = matches.first,
          target.enabled, target.supportsPress else { return nil }
    return target.token
}

struct GlobalAXSearchRow {
    let element: AXUIElement
    let name: String
    let index: Int
    let frame: CGRect
    let selected: Bool
    let enabled: Bool
    let supportsPress: Bool
}

struct GlobalAXSearchModel {
    let identity: WindowIdentity
    let list: AXUIElement
    let listFrame: CGRect
    let query: String
    let rows: [GlobalAXSearchRow]
}

func globalSearchFailure(_ message: String, _ details: [String: Any] = [:]) -> NativeFailure {
    NativeFailure("GLOBAL_SEARCH_RESULTS_UNVERIFIED", message, details)
}

func globalRowName(_ row: AXUIElement, frame: CGRect,
                   expectedPID: pid_t) throws -> String {
    let rowTitle = boundedAXString(copyAttribute(row, kAXTitleAttribute))
    var relatedTitle: String?
    if let raw = copyAttribute(row, kAXTitleUIElementAttribute) {
        guard CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            throw globalSearchFailure("搜尋結果 row 的 AXTitleUIElement 型別不正確")
        }
        let titleElement = raw as! AXUIElement
        var pid: pid_t = 0
        guard !CFEqual(titleElement, row), AXUIElementGetPid(titleElement, &pid) == .success,
              pid == expectedPID, let titleFrame = frameAttribute(titleElement),
              frame.contains(titleFrame) else {
            throw globalSearchFailure("搜尋結果 row 的 AXTitleUIElement 關係不可靠")
        }
        relatedTitle = boundedAXString(copyAttribute(titleElement, kAXTitleAttribute))
        guard relatedTitle != nil else {
            throw globalSearchFailure("搜尋結果 AXTitleUIElement 缺少安全名稱")
        }
    }
    guard let name = globalSemanticName(rowTitle: rowTitle, relatedTitle: relatedTitle) else {
        throw globalSearchFailure("搜尋結果 row 缺少可驗證 AXTitle 名稱")
    }
    return name
}

func readGlobalSearchModel(expected: WindowIdentity, query: String) throws -> GlobalAXSearchModel {
    let (_, _, window, identity) = try mainWindow(requireForeground: true)
    guard sameWindow(expected, identity) else {
        throw globalSearchFailure("搜尋結果模型期間主視窗已漂移")
    }
    let geometry = snapshot(window, mode: .geometryOnly)
    let layout = try readTabLayout(geometry, window: identity)
    let search = geometry.nodes[layout.searchFieldIndex]
    guard globalQueryMatches(observed: copyAttribute(search.element, kAXValueAttribute) as? String,
                             expected: query),
          let listFrame = geometry.nodes[layout.leftListIndex].frame else {
        throw globalSearchFailure("搜尋 query 或左側清單幾何無法 exact 回讀")
    }
    let list = geometry.nodes[layout.leftListIndex].element
    var advertised: CFIndex = 0
    guard AXUIElementGetAttributeValueCount(list, kAXRowsAttribute as CFString,
                                            &advertised) == .success,
          (1...20).contains(Int(advertised)) else {
        throw globalSearchFailure("搜尋結果 AXRows 必須是 1 到 20 個完整可見列")
    }
    var rawRows: CFArray?
    guard AXUIElementCopyAttributeValues(list, kAXRowsAttribute as CFString, 0,
                                         advertised, &rawRows) == .success,
          let elements = rawRows as? [AXUIElement], elements.count == advertised else {
        throw globalSearchFailure("搜尋結果 AXRows 無法完整讀取")
    }
    var rows = [GlobalAXSearchRow]()
    for (position, element) in elements.enumerated() {
        guard !elements[..<position].contains(where: { CFEqual($0, element) }) else {
            throw globalSearchFailure("搜尋結果 AXRows 含重複 CF element")
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid == identity.pid,
              stringAttribute(element, kAXRoleAttribute) == kAXRowRole,
              let rawParent = copyAttribute(element, kAXParentAttribute),
              CFGetTypeID(rawParent) == AXUIElementGetTypeID(),
              CFEqual(rawParent as! AXUIElement, list),
              let index = strictInteger(copyAttribute(element, "AXIndex"), minimum: 0, maximum: 19),
              index == position, let frame = frameAttribute(element),
              listFrame.contains(frame), identity.bounds.contains(frame),
              let selected = strictAXBoolean(copyAttribute(element, kAXSelectedAttribute)),
              let enabled = strictAXBoolean(copyAttribute(element, kAXEnabledAttribute)) else {
            throw globalSearchFailure("搜尋結果 row 的 PID、parent、index、frame 或狀態不完整")
        }
        let name = try globalRowName(element, frame: frame, expectedPID: identity.pid)
        rows.append(GlobalAXSearchRow(element: element, name: name, index: index, frame: frame,
                                      selected: selected, enabled: enabled,
                                      supportsPress: actions(element).contains(kAXPressAction)))
    }
    let proof = rows.enumerated().map {
        GlobalSearchRowProof(token: $0.offset, name: $0.element.name,
                             index: $0.element.index, frame: $0.element.frame,
                             selected: $0.element.selected, enabled: $0.element.enabled,
                             supportsPress: $0.element.supportsPress)
    }
    guard globalSearchModelValid(proof, listFrame: listFrame, windowFrame: identity.bounds) else {
        throw globalSearchFailure("搜尋結果不是完整、可見且 dense 的有界 AXRows 模型")
    }
    return GlobalAXSearchModel(identity: identity, list: list, listFrame: listFrame,
                               query: query, rows: rows)
}

func globalAXModelsStable(_ first: GlobalAXSearchModel,
                          _ second: GlobalAXSearchModel) -> Bool {
    guard sameWindow(first.identity, second.identity), CFEqual(first.list, second.list),
          similar(first.listFrame, second.listFrame, tolerance: 0.5),
          first.query == second.query, first.rows.count == second.rows.count else { return false }
    return zip(first.rows, second.rows).allSatisfy {
        CFEqual($0.element, $1.element) && $0.name == $1.name && $0.index == $1.index &&
            similar($0.frame, $1.frame, tolerance: 0.5) &&
            $0.selected == $1.selected && $0.enabled == $1.enabled &&
            $0.supportsPress == $1.supportsPress
    }
}

func globalSearchProof(_ model: GlobalAXSearchModel,
                       reference: [GlobalAXSearchRow]? = nil) -> [GlobalSearchRowProof] {
    model.rows.map { row in
        let token: Int
        if let reference {
            token = reference.firstIndex(where: { CFEqual($0.element, row.element) }) ?? -1
        } else {
            token = row.index
        }
        return GlobalSearchRowProof(token: token, name: row.name, index: row.index,
                                    frame: row.frame, selected: row.selected,
                                    enabled: row.enabled, supportsPress: row.supportsPress)
    }
}

func stableGlobalAllSelection(first: ReadOCRFrame, second: ReadOCRFrame) throws
    -> (ReadOCRFrame, OCRCandidate) {
    // 只細分原本混在一起的失敗原因；原色彩、信心、底線及雙快照門檻仍全部保留。
    guard tabNavigationProfileAllowed(.readOnly, expected: nil, observed: first.profile),
          tabNavigationProfileAllowed(.readOnly, expected: first.profile, observed: second.profile) else {
        throw NativeFailure("GLOBAL_ALL_PROFILE_CHANGED", "全部分頁兩次擷取的色彩模式不一致")
    }
    switch rawSelectedProof(["全部", "All"], frame: first.frame) {
    case .absent:
        throw NativeFailure("GLOBAL_ALL_NOT_SELECTED", "未觀察到全部分頁對應的選取標記")
    case .invalid:
        throw NativeFailure("GLOBAL_ALL_SELECTION_INVALID", "全部分頁選取標記存在但證據不可靠")
    case .selected:
        return try stableReadSelectedTab(["全部", "All"], first: first, second: second)
    }
}

func verifyGlobalAllSelected(expected: WindowIdentity) throws -> WindowIdentity {
    let first = try captureReadTabOCR(globalAllSourceRGB: true)
    guard sameWindow(expected, first.frame.identity) else {
        throw NativeFailure("TAB_SELECTION_UNVERIFIED", "global route 的主視窗已漂移")
    }
    Thread.sleep(forTimeInterval: 0.06)
    let second = try captureReadTabOCR(globalAllSourceRGB: true)
    let selected = try stableGlobalAllSelection(first: first, second: second)
    guard sameWindow(expected, selected.0.frame.identity) else {
        throw NativeFailure("TAB_SELECTION_UNVERIFIED", "global route 的 selected 證據視窗不符")
    }
    return selected.0.frame.identity
}

func windowStateExactlyMatches(_ expected: [String: Any], _ actual: WindowIdentity) -> Bool {
    guard Set(expected.keys) == Set(actual.json.keys),
          (expected["pid"] as? NSNumber)?.int32Value == actual.pid,
          (expected["windowId"] as? NSNumber)?.uint32Value == actual.windowID,
          expected["title"] as? String == actual.title,
          expected["bundleIdentifier"] as? String == bundleIdentifier,
          expected["executableURL"] as? String == actual.executableURL,
          expected["signingIdentifier"] as? String == actual.signingIdentifier,
          expected["teamIdentifier"] as? String == actual.teamIdentifier,
          let bounds = expected["bounds"] as? [String: Any],
          Set(bounds.keys) == ["x", "y", "width", "height"] else { return false }
    return (bounds["x"] as? NSNumber)?.doubleValue == actual.bounds.minX &&
        (bounds["y"] as? NSNumber)?.doubleValue == actual.bounds.minY &&
        (bounds["width"] as? NSNumber)?.doubleValue == actual.bounds.width &&
        (bounds["height"] as? NSNumber)?.doubleValue == actual.bounds.height
}

func nearestAXWindow(_ element: AXUIElement, expected: AXUIElement) -> Bool {
    var current = element
    for _ in 0..<16 {
        if CFEqual(current, expected) { return true }
        guard let raw = copyAttribute(current, kAXParentAttribute),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return false }
        current = raw as! AXUIElement
    }
    return false
}

func globalAllInputReady() -> Bool {
    let states: [CGEventSourceStateID] = [.hidSystemState, .combinedSessionState]
    for state in states {
        for raw in UInt32(0)..<UInt32(32) {
            guard let button = CGMouseButton(rawValue: raw) else { return false }
            if CGEventSource.buttonState(state, button: button) { return false }
        }
    }
    let relevant: CGEventFlags = [.maskAlphaShift, .maskShift, .maskControl, .maskAlternate,
                                  .maskCommand, .maskHelp, .maskSecondaryFn, .maskNumericPad]
    guard states.allSatisfy({ CGEventSource.flagsState($0).intersection(relevant).isEmpty }) else {
        return false
    }
    let recent: [CGEventType] = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                 .otherMouseDown, .otherMouseUp, .mouseMoved, .leftMouseDragged,
                                 .rightMouseDragged, .otherMouseDragged, .scrollWheel,
                                 .keyDown, .keyUp, .flagsChanged]
    return states.allSatisfy { state in
        recent.allSatisfy {
            CGEventSource.secondsSinceLastEventType(state, eventType: $0) >= 2
        }
    }
}

func strictGlobalAllWindow(expected: [String: Any], point: CGPoint? = nil,
                           requireInputReady: Bool = false) throws -> WindowIdentity {
    let (app, appElement, window, identity) = try mainWindow(requireForeground: true)
    let signing = try strictLineSigningInfo(app.executableURL!)
    guard identity.executableURL == expectedLineExecutablePath,
          identity.signingIdentifier == signing.0,
          identity.teamIdentifier == signing.1,
          windowStateExactlyMatches(expected, identity) else {
        throw NativeFailure("WINDOW_CHANGED", "LINE PID selector 的主視窗或簽章身分已漂移")
    }
    guard let focused = copyAttribute(appElement, kAXFocusedWindowAttribute),
          CFGetTypeID(focused) == AXUIElementGetTypeID(),
          CFEqual(focused as! AXUIElement, window) else {
        throw NativeFailure("FOCUSED_WINDOW_UNVERIFIED", "LINE focused window 不是預期主視窗")
    }
    if let point {
        guard point.x.isFinite, point.y.isFinite, identity.bounds.contains(point) else {
            throw NativeFailure("OCR_GEOMETRY_INVALID", "全部標籤事件點超出 LINE 主視窗")
        }
        var rawHit: AXUIElement?
        let systemWide = AXUIElementCreateSystemWide()
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &rawHit) == .success,
              let hit = rawHit else {
            throw NativeFailure("AX_HIT_UNVERIFIED", "全部標籤事件點無法取得 system-wide AX hit")
        }
        var hitPID: pid_t = 0
        guard AXUIElementGetPid(hit, &hitPID) == .success, hitPID == identity.pid,
              nearestAXWindow(hit, expected: window) else {
            throw NativeFailure("AX_HIT_UNVERIFIED", "全部標籤事件點不屬於預期 LINE 主視窗")
        }
    }
    if requireInputReady {
        guard CGPreflightPostEventAccess() else {
            throw NativeFailure("INPUT_PERMISSION_DENIED", "尚未具備事件投遞權限；不主動要求權限")
        }
        guard globalAllInputReady() else {
            throw NativeFailure("PHYSICAL_INPUT_BUSY", "實體按鍵、修飾鍵或硬體 idle 尚未通過")
        }
    }
    return identity
}

func currentStrictLineWindowState() throws -> [String: Any] {
    let (app, _, _, identity) = try mainWindow(requireForeground: true)
    let signing = try strictLineSigningInfo(app.executableURL!)
    guard identity.executableURL == expectedLineExecutablePath,
          identity.signingIdentifier == signing.0,
          identity.teamIdentifier == signing.1 else {
        throw NativeFailure("LINE_IDENTITY_MISMATCH", "目前 LINE 主視窗的嚴格簽章身分不符")
    }
    return identity.json
}

enum GlobalAllTargetState {
    case selected(WindowIdentity)
    case target(WindowIdentity, CGPoint, CGRect, CGRect)
}

func freshGlobalAllTarget(expectedWindow: [String: Any]) throws -> GlobalAllTargetState {
    let labels = ["全部", "All"]
    let before = try strictGlobalAllWindow(expected: expectedWindow)
    let first = try captureReadTabOCR(globalAllSourceRGB: true)
    guard sameWindow(before, first.frame.identity) else {
        throw NativeFailure("WINDOW_CHANGED", "全部標籤第一讀主視窗已漂移")
    }
    if case .selected = rawSelectedProof(labels, frame: first.frame) {
        return .selected(try verifyGlobalAllSelected(expected: first.frame.identity))
    }
    let matches = labels.flatMap { label in
        allNavigationExactMatches(label, in: first.frame).map { (label, $0) }
    }
    guard matches.count == 1, let match = matches.first else {
        throw NativeFailure("TAB_SELECTION_UNVERIFIED",
                            "單一可見分頁頁面無法唯一辨識全部／All route",
                            ["count": matches.count])
    }
    Thread.sleep(forTimeInterval: 0.06)
    _ = try strictGlobalAllWindow(expected: expectedWindow)
    let second = try captureReadTabOCR(globalAllSourceRGB: true)
    guard sameWindow(before, second.frame.identity), first.profile == second.profile else {
        throw NativeFailure("WINDOW_CHANGED", "全部標籤第二讀主視窗或色彩模式已漂移")
    }
    let candidate = try stableAllNavigationTarget(match.0, first: first.frame,
                                                   second: second.frame)
    let geometry = CaptureGeometry(window: second.frame.identity.bounds, roi: second.frame.roi,
                                   imageWidth: second.frame.imageWidth,
                                   imageHeight: second.frame.imageHeight)
    let label = try geometry.screenRect(for: candidate)
    let point = CGPoint(x: label.midX, y: label.midY)
    guard label.contains(point), second.frame.roi.contains(point), before.bounds.contains(point) else {
        throw NativeFailure("OCR_GEOMETRY_INVALID", "全部標籤事件點未落在 fresh label／tile／window")
    }
    return .target(second.frame.identity, point, label, second.frame.roi)
}

func verifyGlobalAllForRead(expectedWindow: Any?) throws -> WindowIdentity {
    let expected: [String: Any]
    if expectedWindow == nil || expectedWindow is NSNull {
        expected = try currentStrictLineWindowState()
    } else if let value = validWindowState(expectedWindow) {
        expected = value
    } else {
        throw NativeFailure("INVALID_ARGUMENT", "global reader expectedWindow 格式不正確")
    }
    let before = try strictGlobalAllWindow(expected: expected)
    let selected = try verifyGlobalAllSelected(expected: before)
    let after = try strictGlobalAllWindow(expected: expected)
    guard sameWindow(selected, after) else {
        throw NativeFailure("WINDOW_CHANGED", "global reader 的全部選取證據已漂移")
    }
    return after
}

func parseGlobalAllCommandArguments(_ args: [String: Any]) throws
    -> (chatName: String, requestNonce: String, expectedWindow: [String: Any]) {
    guard Set(args.keys) == ["chatName", "requestNonce", "expectedWindow"],
          let chatName = validName(args["chatName"]),
          let requestNonce = validHex(args["requestNonce"], count: 64),
          let expectedWindow = validWindowState(args["expectedWindow"]) else {
        throw NativeFailure("INVALID_ARGUMENT", "global All command 參數格式不正確")
    }
    return (chatName, requestNonce, expectedWindow)
}

func raiseGlobalAllWindowOnce(expected: [String: Any]) throws -> WindowIdentity {
    let (app, _, window, before) = try mainWindow(requireForeground: true)
    let signing = try strictLineSigningInfo(app.executableURL!)
    guard before.executableURL == expectedLineExecutablePath,
          before.signingIdentifier == signing.0,
          before.teamIdentifier == signing.1,
          windowStateExactlyMatches(expected, before) else {
        throw NativeFailure("WINDOW_CHANGED", "AXRaise 前 LINE 主視窗身分已漂移")
    }
    try perform(kAXRaiseAction, on: window)
    let after = try strictGlobalAllWindow(expected: expected)
    guard sameWindow(before, after) else {
        throw NativeFailure("WINDOW_CHANGED", "AXRaise 後 LINE 主視窗或 frame 已漂移")
    }
    return after
}

func requireSystemEventsAutomation() throws {
    let running = NSRunningApplication.runningApplications(
        withBundleIdentifier: systemEventsBundleIdentifier
    ).filter { !$0.isTerminated }
    guard running.count == 1 else {
        throw NativeFailure("SYSTEM_EVENTS_UNAVAILABLE", "System Events 未唯一執行")
    }
    let automationStatus = systemEventsAutomationPermission()
    guard systemEventsPermissionAllowed(automationStatus) else {
        throw NativeFailure("SYSTEM_EVENTS_PERMISSION_DENIED",
                            "System Events automation 權限不可用；不要求新權限",
                            ["automationStatus": Int(automationStatus)])
    }
}

func systemEventsPermissionAllowed(_ status: OSStatus) -> Bool { status == noErr }

func observeGlobalAll(_ args: [String: Any]) throws -> [String: Any] {
    let parsed = try parseGlobalAllCommandArguments(args)
    let counts = GlobalAllEventCounts()
    var actual: WindowIdentity?
    var identityVerified = false
    func receipt(allSelected: Bool, phase: String) -> [String: Any] {
        globalAllNavigationReceipt(chatName: parsed.chatName,
                                   requestNonce: parsed.requestNonce,
                                   expectedWindow: parsed.expectedWindow, mainWindow: actual,
                                   allSelected: allSelected, counts: counts,
                                   phase: phase, identityVerified: identityVerified)
    }
    do {
        actual = try strictGlobalAllWindow(expected: parsed.expectedWindow)
        identityVerified = true
        _ = try verifyGlobalAllSelected(expected: actual!)
        identityVerified = false
        actual = try strictGlobalAllWindow(expected: parsed.expectedWindow)
        identityVerified = true
        return receipt(allSelected: true, phase: "verified")
    } catch let failure as NativeFailure {
        throw NativeFailure(failure.code, failure.message, failure.details.merging([
            "allNavigation": receipt(allSelected: false, phase: "pre_input"),
            "cause": failure.code,
        ]) { _, new in new })
    } catch {
        throw NativeFailure("NATIVE_FAILURE", "All 純觀察未預期失敗",
                            ["allNavigation": receipt(allSelected: false, phase: "pre_input")])
    }
}

func selectGlobalAll(_ args: [String: Any]) throws -> [String: Any] {
    let parsed = try parseGlobalAllCommandArguments(args)
    var counts = GlobalAllEventCounts()
    var actual: WindowIdentity?
    var identityVerified = false
    func receipt(allSelected: Bool, phase: String) -> [String: Any] {
        globalAllNavigationReceipt(chatName: parsed.chatName,
                                   requestNonce: parsed.requestNonce,
                                   expectedWindow: parsed.expectedWindow, mainWindow: actual,
                                   allSelected: allSelected, counts: counts,
                                   phase: phase, identityVerified: identityVerified)
    }
    do {
        actual = try strictGlobalAllWindow(expected: parsed.expectedWindow)
        identityVerified = true
        do {
            _ = try verifyGlobalAllSelected(expected: actual!)
            identityVerified = false
            actual = try strictGlobalAllWindow(expected: parsed.expectedWindow)
            identityVerified = true
            return receipt(allSelected: true, phase: "verified")
        } catch let failure as NativeFailure where failure.code == "GLOBAL_ALL_NOT_SELECTED" {
            // 唯一可進入正式 HID 序列的狀態；其它證據錯誤全部 fail closed。
        }
        identityVerified = false
        let target = try freshGlobalAllTarget(expectedWindow: parsed.expectedWindow)
        identityVerified = true
        switch target {
        case let .selected(window):
            identityVerified = false
            actual = try strictGlobalAllWindow(expected: parsed.expectedWindow)
            guard sameWindow(window, actual!) else {
                throw NativeFailure("WINDOW_CHANGED", "HID 零輸入選取證據已漂移")
            }
            identityVerified = true
            return receipt(allSelected: true, phase: "verified")
        case let .target(window, point, _, _):
            actual = window
            let eventNumber = Int64.random(in: 1...Int64(Int16.max))
            let events = try buildGlobalAllMouseEvents(point: point, eventNumber: eventNumber)
            do {
                counts = try runGlobalAllMouseCore(pid: window.pid, guardFresh: { step in
                    identityVerified = false
                    actual = try strictGlobalAllWindow(
                        expected: parsed.expectedWindow, point: point,
                        requireInputReady: step == .move
                    )
                    guard actual?.pid == window.pid else {
                        throw NativeFailure("WINDOW_CHANGED", "HID 序列期間 LINE PID 已漂移")
                    }
                    identityVerified = true
                }, post: { step, _ in
                    events.event(step).post(tap: .cghidEventTap)
                })
            } catch let failure as GlobalAllCoreFailure {
                counts = failure.counts
                throw failure.cause
            }
            Thread.sleep(forTimeInterval: 0.25)
            identityVerified = false
            actual = try strictGlobalAllWindow(expected: parsed.expectedWindow, point: point)
            _ = try verifyGlobalAllSelected(expected: actual!)
            actual = try strictGlobalAllWindow(expected: parsed.expectedWindow, point: point)
            guard actual?.pid == window.pid else {
                throw NativeFailure("WINDOW_CHANGED", "HID 後 LINE PID 已漂移")
            }
            identityVerified = true
            return receipt(allSelected: true, phase: "verified")
        }
    } catch let failure as NativeFailure {
        let phase = counts.inputAttempted ? "post_input" : "pre_input"
        let code = counts.inputAttempted ? "GLOBAL_ALL_OUTCOME_UNKNOWN" : failure.code
        let message = counts.inputAttempted
            ? "HID 全部導航結果不明，停止且不重試"
            : failure.message
        throw NativeFailure(code, message, failure.details.merging([
            "allNavigation": receipt(allSelected: false, phase: phase),
            "cause": failure.code,
        ]) { _, new in new })
    } catch {
        let phase = counts.inputAttempted ? "post_input" : "pre_input"
        throw NativeFailure(counts.inputAttempted ? "GLOBAL_ALL_OUTCOME_UNKNOWN" : "NATIVE_FAILURE",
                            counts.inputAttempted ? "HID 全部導航結果不明，停止且不重試" : "全部導航未預期失敗",
                            ["allNavigation": receipt(allSelected: false, phase: phase)])
    }
}

func verifyGlobalHeader(_ chatName: String, expected: WindowIdentity) throws -> WindowIdentity {
    let (_, _, window, identity) = try mainWindow(requireForeground: true)
    guard sameWindow(expected, identity) else {
        throw NativeFailure("WINDOW_CHANGED", "global header 驗證期間主視窗已漂移")
    }
    let tree = metadataSnapshot(window)
    let layout = try readTabLayout(tree, window: identity)
    let leftFrame = tree.nodes[layout.leftListIndex].frame!
    let headerBand = CGRect(x: leftFrame.maxX, y: layout.tabROI.maxY,
                            width: identity.bounds.maxX - leftFrame.maxX,
                            height: min(CGFloat(120), identity.bounds.height * 0.25))
    let relationNodes = tree.nodes.filter { node in
        guard let frame = node.frame,
              containsWithTolerance(headerBand, frame, tolerance: 1) else { return false }
        return attributeNames(node.element).contains(kAXTitleUIElementAttribute)
    }
    if !relationNodes.isEmpty {
        var names = [String]()
        for node in relationNodes {
            guard let raw = copyAttribute(node.element, kAXTitleUIElementAttribute),
                  CFGetTypeID(raw) == AXUIElementGetTypeID() else {
                throw NativeFailure("CHAT_SELECTION_UNVERIFIED", "global header TitleUIElement 關係不可靠")
            }
            let titleElement = raw as! AXUIElement
            var pid: pid_t = 0
            guard AXUIElementGetPid(titleElement, &pid) == .success, pid == expected.pid,
                  let titleFrame = frameAttribute(titleElement),
                  containsWithTolerance(headerBand, titleFrame, tolerance: 1),
                  let name = boundedAXString(copyAttribute(titleElement, kAXTitleAttribute)) else {
                throw NativeFailure("CHAT_SELECTION_UNVERIFIED", "global header AXTitle 名稱不可靠")
            }
            names.append(name)
        }
        let matches = names.filter { $0 == chatName }
        guard globalHeaderNamesVerify(names, target: chatName) else {
            throw NativeFailure("CHAT_SELECTION_UNVERIFIED", "global header 無法唯一 exact 驗證聊天室",
                                ["count": matches.count])
        }
        return identity
    }
    // AX relation 不存在時只沿用 header-only OCR，不得擴大至左側聊天預覽區。
    let fallback = try verifyHeader(chatName)
    guard sameWindow(expected, fallback) else {
        throw NativeFailure("WINDOW_CHANGED", "global header OCR 驗證期間主視窗已漂移")
    }
    return fallback
}

func verifyAXHeaderIfAvailable(_ chatName: String) throws -> WindowIdentity? {
    guard axTabOverflowCalibrationVerified else { return nil }
    let (_, _, window, identity) = try mainWindow(requireForeground: true)
    let tree = metadataSnapshot(window)
    guard !tree.partial else {
        throw NativeFailure("SEMANTIC_PARTIAL", "AX header metadata snapshot 不完整")
    }
    let layout = try lineLayout(tree, window: identity)
    var matches = [AXUIElement]()
    for node in tree.nodes {
        guard let frame = node.frame,
              containsWithTolerance(layout.headerROI, frame, tolerance: 1),
              let rawTitle = copyAttribute(node.element, kAXTitleUIElementAttribute),
              CFGetTypeID(rawTitle) == AXUIElementGetTypeID() else { continue }
        let titleElement = rawTitle as! AXUIElement
        guard let titleFrame = frameAttribute(titleElement),
              containsWithTolerance(layout.headerROI, titleFrame, tolerance: 1),
              strictAXSemanticName(title: copyAttribute(titleElement, kAXTitleAttribute),
                                   value: copyAttribute(titleElement, kAXValueAttribute)) == chatName else {
            continue
        }
        if !matches.contains(where: { CFEqual($0, titleElement) }) { matches.append(titleElement) }
    }
    guard matches.count <= 1 else {
        throw NativeFailure("AMBIGUOUS_MATCH", "AX header title relation 不唯一")
    }
    return matches.count == 1 ? identity : nil
}

func verifyHeader(_ chatName: String) throws -> WindowIdentity {
    if let identity = try verifyAXHeaderIfAvailable(chatName) { return identity }
    let frame = try captureOCR(.header)
    let matches = exactOCRMatches(chatName, in: frame)
    guard matches.count == 1 else {
        throw NativeFailure(matches.isEmpty ? "CHAT_SELECTION_UNVERIFIED" : "AMBIGUOUS_MATCH",
                            "右側 header strip 無法唯一驗證聊天室標題", ["count": matches.count])
    }
    return frame.identity
}

func probeAXReadScope(_ args: [String: Any], liveScope: LiveScope?) throws -> [String: Any] {
    guard let scope = liveScope, let tabName = scope.tabName,
          args["tabName"] as? String == tabName,
          args["chatName"] as? String == scope.chatName else {
        throw NativeFailure("LIVE_SCOPE_DENIED", "AX 能力探針必須綁定 exact live scope")
    }
    let (_, application, window, identity) = try mainWindow(requireForeground: true)
    let tree = metadataSnapshot(window, maximumNodes: 224, maximumDepth: 12)
    let menuBudget = max(1, 256 - tree.nodes.count)
    let menuTree: Snapshot
    if let rawMenu = copyAttribute(application, kAXMenuBarAttribute),
       CFGetTypeID(rawMenu) == AXUIElementGetTypeID() {
        menuTree = metadataSnapshot(rawMenu as! AXUIElement,
                                    maximumNodes: menuBudget, maximumDepth: 12)
    } else {
        menuTree = Snapshot(nodes: [], partial: false, reasons: [])
    }
    let layout = try readTabLayout(tree, window: identity)
    let groups = tree.nodes.filter { node in
        guard node.role == kAXTabGroupRole, let frame = node.frame else { return false }
        return frame.intersects(layout.tabROI) && identity.bounds.contains(frame)
    }
    var advertisedCount = 0
    var returnedCount = 0
    var targetMatchCount = 0
    var targetSelectedCount = 0
    var targetStateKnownCount = 0
    var targetIdentifierPresentCount = 0
    var objectsWithNameCount = 0
    var objectsWithStateCount = 0
    var objectsWithIdentifierCount = 0
    if groups.count == 1, let group = groups.first {
        var count: CFIndex = 0
        if AXUIElementGetAttributeValueCount(group.element, kAXTabsAttribute as CFString,
                                             &count) == .success,
           count > 0, count <= 100 {
            advertisedCount = Int(count)
            var rawTabs: CFArray?
            if AXUIElementCopyAttributeValues(group.element, kAXTabsAttribute as CFString, 0,
                                              count, &rawTabs) == .success,
               let tabs = rawTabs as? [AXUIElement], tabs.count == count {
                returnedCount = tabs.count
                for tab in tabs {
                    let name = strictAXSemanticName(title: copyAttribute(tab, kAXTitleAttribute),
                                                    value: copyAttribute(tab, kAXValueAttribute))
                    let state = strictAXSemanticState(selected: copyAttribute(tab, kAXSelectedAttribute),
                                                      value: copyAttribute(tab, kAXValueAttribute))
                    if name != nil { objectsWithNameCount += 1 }
                    if state != nil { objectsWithStateCount += 1 }
                    if boundedAXString(copyAttribute(tab, kAXIdentifierAttribute), maximum: 256) != nil {
                        objectsWithIdentifierCount += 1
                    }
                    if name == tabName {
                        targetMatchCount += 1
                        if state != nil { targetStateKnownCount += 1 }
                        if state == true { targetSelectedCount += 1 }
                        if boundedAXString(copyAttribute(tab, kAXIdentifierAttribute), maximum: 256) != nil {
                            targetIdentifierPresentCount += 1
                        }
                    }
                }
            }
        }
    }
    let leftFrame = tree.nodes[layout.leftListIndex].frame!
    let headerBand = CGRect(x: leftFrame.maxX, y: layout.tabROI.maxY,
                            width: identity.bounds.maxX - leftFrame.maxX,
                            height: min(CGFloat(120), identity.bounds.height * 0.25))
    let headerRelationAvailable = tree.nodes.contains { node in
        guard let frame = node.frame,
              containsWithTolerance(headerBand, frame, tolerance: 1) else { return false }
        return attributeNames(node.element).contains(kAXTitleUIElementAttribute)
    }
    var headerRelationCount = 0
    if targetMatchCount == 1, targetSelectedCount == 1 {
        var titleElements = [AXUIElement]()
        for node in tree.nodes {
            guard let frame = node.frame, containsWithTolerance(headerBand, frame, tolerance: 1),
                  let raw = copyAttribute(node.element, kAXTitleUIElementAttribute),
                  CFGetTypeID(raw) == AXUIElementGetTypeID() else { continue }
            let titleElement = raw as! AXUIElement
            guard let titleFrame = frameAttribute(titleElement),
                  containsWithTolerance(headerBand, titleFrame, tolerance: 1),
                  strictAXSemanticName(title: copyAttribute(titleElement, kAXTitleAttribute),
                                       value: copyAttribute(titleElement, kAXValueAttribute)) == scope.chatName else {
                continue
            }
            if !titleElements.contains(where: { CFEqual($0, titleElement) }) {
                titleElements.append(titleElement)
            }
        }
        headerRelationCount = titleElements.count
    }
    let saveChatLabels = ["儲存聊天", "Save chat", "Save Chat"]
    let saveChatMenuMatchCount = (tree.nodes + menuTree.nodes).filter { node in
        node.role == kAXMenuItemRole &&
            strictAXSemanticName(title: copyAttribute(node.element, kAXTitleAttribute),
                                 value: copyAttribute(node.element, kAXValueAttribute))
                .map(saveChatLabels.contains) == true
    }.count
    return [
        "scope": ["tabName": tabName, "chatName": scope.chatName],
        "axTabGroupCount": groups.count,
        "axTabCount": returnedCount > 0 && returnedCount == advertisedCount ? returnedCount : 0,
        "axObjectsWithNameCount": objectsWithNameCount,
        "axObjectsWithStateCount": objectsWithStateCount,
        "axObjectsWithIdentifierCount": objectsWithIdentifierCount,
        "axTargetTabMatchCount": targetMatchCount,
        "axTargetTabSelected": targetMatchCount == 1 && targetStateKnownCount == 1
            ? targetSelectedCount == 1 : NSNull(),
        "axTargetTabIdentifierPresent": targetMatchCount == 1
            ? targetIdentifierPresentCount == 1 : NSNull(),
        "axTabInventoryCalibrated": axTabOverflowCalibrationVerified,
        "axRowCount": NSNull(), "axTargetRowNameMatchCount": NSNull(),
        "axHeaderTitleRelationAvailable": headerRelationAvailable,
        "axHeaderNameMatches": targetMatchCount == 1 && targetSelectedCount == 1 &&
            headerRelationAvailable ? headerRelationCount == 1 : NSNull(),
        "axSaveChatActionCount": saveChatMenuMatchCount,
        "requiresCalibration": true, "bodyReadAttempted": false,
        "ocrUsed": false, "uiEvents": 0,
    ]
}

func validHex(_ value: Any?, count: Int) -> String? {
    guard let value = value as? String, value.count == count,
          value.range(of: "^[a-f0-9]{\(count)}$", options: .regularExpression) != nil else { return nil }
    return value
}

func validExportDirectory(_ value: Any?) -> String? {
    guard let value = value as? String, value.count >= 2, value.count <= 1_024,
          value.hasPrefix("/"), value.range(of: #"\p{Cc}"#, options: .regularExpression) == nil,
          (value as NSString).standardizingPath == value else { return nil }
    return value
}

func validExportFileName(_ value: Any?) -> String? {
    guard let value = value as? String,
          value.range(of: "^[a-f0-9]{32}\\.txt$", options: .regularExpression) != nil else { return nil }
    return value
}

func validTextExportArguments(_ command: String, _ args: [String: Any]) -> Bool {
    let common = validName(args["tabName"]) != nil && validName(args["chatName"]) != nil &&
        validHex(args["identityKey"], count: 64) != nil &&
        validHex(args["requestNonce"], count: 32) != nil
    if command == "prepareTextExportScope" {
        return common && Set(args.keys) == ["tabName", "chatName", "identityKey", "requestNonce"]
    }
    if command == "exportChatText" {
        return common && validHex(args["expectedProofDigest"], count: 64) != nil &&
            validExportDirectory(args["outputDirectory"]) != nil &&
            validExportFileName(args["outputFileName"]) != nil &&
            Set(args.keys) == ["tabName", "chatName", "identityKey", "requestNonce",
                               "expectedProofDigest", "outputDirectory", "outputFileName"]
    }
    return false
}

func textExportCalibrationRequired(_ command: String, _ args: [String: Any]) throws -> [String: Any] {
    guard validTextExportArguments(command, args) else {
        throw NativeFailure("INVALID_ARGUMENT", "原生文字匯出參數格式不正確",
                            ["sideEffectsAttempted": false])
    }
    // Save Chat／Save Panel 尚未取得實機 schema；校準前必須在任何 AX 或檔案動作前停止。
    throw NativeFailure("AX_EXPORT_CALIBRATION_REQUIRED", "原生文字匯出尚需實機校準",
                        ["sideEffectsAttempted": false, "phase": "pre_commit"])
}

func selectChat(_ chatName: String, tabName: String?) throws -> [String: Any] {
    _ = try mainWindow(requireForeground: true)
    let selectedTab: String
    let tabIdentity: WindowIdentity
    if let tabName {
        tabIdentity = try navigateTab(tabName)
        selectedTab = tabName
    } else {
        let navigated = try navigateTab(labels: ["全部", "All"])
        tabIdentity = navigated.0
        selectedTab = navigated.1
    }
    let clipboard = try setSearchValue(chatName, expected: tabIdentity)
    Thread.sleep(forTimeInterval: 0.25)
    let (_, _, current, rows) = try currentChatRows()
    guard sameWindow(tabIdentity, current) else { throw NativeFailure("WINDOW_CHANGED", "搜尋結果出現前視窗已變更") }
    let matches = rows.filter { $0.1 == chatName }
    guard matches.count == 1, let row = matches.first else {
        throw NativeFailure(matches.isEmpty ? "CHAT_NOT_FOUND" : "AMBIGUOUS_MATCH",
                            matches.isEmpty ? "找不到完全同名聊天室" : "搜尋結果有多個完全同名聊天室",
                            ["count": matches.count])
    }
    let (_, _, _, before) = try mainWindow(requireForeground: true)
    guard sameWindow(current, before) else { throw NativeFailure("WINDOW_CHANGED", "選取聊天室前視窗已變更") }
    try perform(kAXPressAction, on: row.0.element)
    Thread.sleep(forTimeInterval: 0.3)
    let (_, _, selectedIdentity, selectedRows) = try currentChatRows()
    let selected = selectedRows.filter { $0.1 == chatName }
    guard selected.count == 1, selected[0].0.selected == true else {
        throw NativeFailure("CHAT_SELECTION_UNVERIFIED", "搜尋結果 AXRow 未提供唯一 selected-state",
                            ["count": selected.count])
    }
    let headerIdentity = try verifyHeader(chatName)
    guard sameWindow(selectedIdentity, headerIdentity) else { throw NativeFailure("WINDOW_CHANGED", "header 驗證期間視窗已變更") }
    return ["success": true, "chatName": chatName, "tabName": selectedTab,
            "selectedTabVerified": true,
            "mainWindow": headerIdentity.json, "clipboard": clipboard]
}

func looksLikeTimeMetadata(_ value: String) -> Bool {
    [#"^\d{1,2}:\d{2}$"#, #"^\d{4}[/.\-]\d{1,2}[/.\-]\d{1,2}$"#,
     #"^(上午|下午)\s*\d{1,2}:\d{2}$"#].contains {
        value.range(of: $0, options: .regularExpression) != nil
    }
}

func visibleMessageRow(listFrame: CGRect, rowFrame: CGRect, window: CGRect) -> Bool {
    listFrame.contains(rowFrame) && window.contains(rowFrame)
}

func rowOCRBlocks(window: WindowIdentity, rowFrame: CGRect) throws -> ([String], [String: Any]) {
    guard #available(macOS 14.0, *) else {
        throw NativeFailure("UNSUPPORTED_OS_VERSION", "訊息 row OCR 需要 macOS 14 以上")
    }
    let image = try captureWindowImage(window, roi: rowFrame)
    let geometry = CaptureGeometry(window: window.bounds, roi: rowFrame,
                                   imageWidth: image.width, imageHeight: image.height)
    let recognized = try recognizeText(image, geometry: geometry)
    let blocks = recognized.map(\.text).filter { !$0.isEmpty }
    guard !blocks.isEmpty else { throw NativeFailure("MESSAGE_BODY_UNREADABLE", "可見訊息 row OCR 無文字") }
    return (blocks, ["source": "VISIBLE_VERIFIED_ROW_OCR", "blockCount": blocks.count,
                     "rowROI": ["x": rowFrame.minX, "y": rowFrame.minY,
                                "width": rowFrame.width, "height": rowFrame.height],
                     "complete": false])
}

func messageBodies(_ list: AXUIElement, listFrame: CGRect,
                   window: WindowIdentity) throws -> ([String], [[String: Any]]) {
    let tree = snapshot(list, mode: .text)
    var seen: [AXUIElement] = []
    var bodies: [String] = []
    var provenance: [[String: Any]] = []
    for index in tree.nodes.indices {
        let row = tree.nodes[index]
        guard row.role == "AXRow", let rowFrame = row.frame,
              visibleMessageRow(listFrame: listFrame, rowFrame: rowFrame, window: window.bounds) else { continue }
        if seen.contains(where: { CFEqual($0, row.element) }) { continue }
        seen.append(row.element)
        let rowValue = row.value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rowValue.isEmpty, !looksLikeTimeMetadata(rowValue) {
            bodies.append(rowValue)
            provenance.append(["source": "AX_ROW_VALUE", "blockCount": 1, "complete": false])
            continue
        }
        let candidates = descendantIndices(of: index, in: tree.nodes).compactMap { childIndex -> String? in
            let child = tree.nodes[childIndex]
            guard child.role == "AXStaticText", let frame = child.frame,
                  rowFrame.contains(frame), listFrame.contains(frame) else { return nil }
            let value = child.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty || looksLikeTimeMetadata(value) ? nil : value
        }
        if candidates.count == 1, let body = candidates.first {
            bodies.append(body)
            provenance.append(["source": "AX_STATIC_TEXT", "blockCount": 1, "complete": false])
        } else {
            let observed = try rowOCRBlocks(window: window, rowFrame: rowFrame)
            bodies.append(observed.0.joined(separator: " "))
            provenance.append(observed.1)
        }
    }
    guard !bodies.isEmpty else { throw NativeFailure("MESSAGE_BODY_UNREADABLE", "沒有可可靠讀取的可見訊息 body") }
    return (bodies, provenance)
}

struct HistoryPageBudget {
    let requested: Int
    let target: Int
    let reasons: [String]
}

func historyPageBudget(_ requested: Int, maximum: Int = 50) throws -> HistoryPageBudget {
    guard requested >= 0, requested <= 100 else {
        throw NativeFailure("INVALID_ARGUMENT", "pageUpTimes 必須介於 0 與 100")
    }
    return HistoryPageBudget(requested: requested, target: min(requested, maximum),
                             reasons: requested > maximum ? ["PAGE_BUDGET"] : [])
}

func historyPagingShouldStop(applied: Int, target: Int,
                             now: TimeInterval, deadline: TimeInterval) -> String? {
    if applied >= target { return "TARGET_REACHED" }
    if now >= deadline { return "PAGE_TIME_LIMIT" }
    return nil
}

func pageUpMessages(chatName: String, expected: WindowIdentity,
                    budget: HistoryPageBudget, timeBudget: TimeInterval = 8) throws -> (Int, [String]) {
    let deadline = Date().timeIntervalSince1970 + timeBudget
    var applied = 0
    var reasons = budget.reasons
    while historyPagingShouldStop(applied: applied, target: budget.target,
                                  now: Date().timeIntervalSince1970, deadline: deadline) == nil {
        let header = try verifyHeader(chatName)
        guard sameWindow(expected, header) else { throw NativeFailure("WINDOW_CHANGED", "PageUp 前聊天室視窗已變更") }
        let (_, _, window, identity) = try mainWindow(requireForeground: true)
        guard sameWindow(expected, identity) else { throw NativeFailure("WINDOW_CHANGED", "PageUp 前主視窗已變更") }
        let geometry = snapshot(window, mode: .geometryOnly)
        let layout = try lineLayout(geometry, window: identity)
        let list = geometry.nodes[layout.messageListIndex]
        guard AXUIElementSetAttributeValue(list.element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success,
              boolAttribute(list.element, kAXFocusedAttribute) else {
            throw NativeFailure("SEMANTIC_UNRELIABLE", "無法安全聚焦已驗證 message AXList")
        }
        try pairedKey(116)
        applied += 1
        Thread.sleep(forTimeInterval: 0.05)
    }
    if applied < budget.target { reasons.append("PAGE_TIME_LIMIT") }
    return (applied, Array(Set(reasons)).sorted())
}

func getHistory(_ args: [String: Any]) throws -> [String: Any] {
    guard let chatName = args["chatName"] as? String else { throw NativeFailure("INVALID_ARGUMENT", "缺少 chatName") }
    let limit = (args["limit"] as? NSNumber)?.intValue ?? 100
    let pages = (args["pageUpTimes"] as? NSNumber)?.intValue ?? 10
    // 預算驗證必須先於任何 tab/chat UI 操作，避免 legacy long 在選取後才失敗。
    let pageBudget = try historyPageBudget(pages)
    _ = try selectChat(chatName, tabName: args["tabName"] as? String)
    let header = try verifyHeader(chatName)
    let paging = try pageUpMessages(chatName: chatName, expected: header, budget: pageBudget)
    let (_, _, window, identity) = try mainWindow(requireForeground: true)
    guard sameWindow(header, identity) else { throw NativeFailure("WINDOW_CHANGED", "訊息讀取前視窗已變更") }
    let geometry = snapshot(window, mode: .geometryOnly)
    let layout = try lineLayout(geometry, window: identity)
    let list = geometry.nodes[layout.messageListIndex]
    guard let listFrame = list.frame else { throw NativeFailure("MESSAGE_CONTAINER_UNREADABLE", "訊息 AXList 缺少 frame") }
    var observed = try messageBodies(list.element, listFrame: listFrame, window: identity)
    var bodies = observed.0
    var reasons = ["VISIBLE_AX_MESSAGE_ROWS_ONLY", "DATE_FILTER_UNAVAILABLE"] + paging.1
    if bodies.count > limit { bodies = Array(bodies.suffix(limit)); reasons.append("MESSAGE_LIMIT") }
    if bodies.count < observed.0.count { observed.1 = Array(observed.1.suffix(bodies.count)) }
    return ["history": bodies.joined(separator: "\n"),
            "metadata": ["complete": false, "reasons": reasons,
                         "mayAffectReadState": true, "messageLimitApplied": limit,
                         "dateFilterApplied": false, "contentMode": "OBSERVED_TEXT_BLOCKS",
                         "pageUpTimesRequested": pages, "pageUpTimesApplied": paging.0,
                         "provenance": observed.1,
                         "observedAt": ISO8601DateFormatter().string(from: Date())]]
}

let historyTextCodeUnitLimit = 50_000
let historySeenIDLimit = 2_000
let historyStateByteLimit = 65_536

struct HistoryDateContext {
    let date: String
    let anchorHash: String
}

struct HistoryNativeState {
    let expectedWindow: [String: Any]
    let headerDigest: String
    let anchorHash: String
    let offset: Int
    let pageNumber: Int
    let advance: Bool
    let seenIds: [String]
    let dateContext: HistoryDateContext?
}

enum HistoryMode: String { case tab, global }

struct HistoryArguments {
    let mode: HistoryMode
    let tabName: String
    let chatName: String
    let limit: Int
    let identityKey: Data
    let state: HistoryNativeState?
    let resultIndex: Int?
}

func lowerHex64(_ value: Any?) -> String? {
    guard let value = value as? String,
          value.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else { return nil }
    return value
}

func dataFromLowerHex(_ value: String) -> Data? {
    guard value.count % 2 == 0 else { return nil }
    var data = Data(capacity: value.count / 2)
    var index = value.startIndex
    while index < value.endIndex {
        let next = value.index(index, offsetBy: 2)
        guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
        data.append(byte)
        index = next
    }
    return data
}

func strictInteger(_ value: Any?, minimum: Int, maximum: Int) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue.isFinite, floor(number.doubleValue) == number.doubleValue,
          number.intValue >= minimum, number.intValue <= maximum else { return nil }
    return number.intValue
}

func validWindowState(_ raw: Any?) -> [String: Any]? {
    guard let value = raw as? [String: Any] else { return nil }
    let required: Set<String> = ["pid", "windowId", "title", "bounds", "bundleIdentifier", "executableURL"]
    let allowed = required.union(["signingIdentifier", "teamIdentifier"])
    guard required.isSubset(of: Set(value.keys)), Set(value.keys).isSubset(of: allowed),
          strictInteger(value["pid"], minimum: 1, maximum: Int(Int32.max)) != nil,
          strictInteger(value["windowId"], minimum: 1, maximum: Int(UInt32.max)) != nil,
          value["title"] as? String == expectedWindowTitle,
          value["bundleIdentifier"] as? String == bundleIdentifier,
          let executable = value["executableURL"] as? String, !executable.isEmpty,
          let bounds = value["bounds"] as? [String: Any],
          Set(bounds.keys) == ["x", "y", "width", "height"] else { return nil }
    for key in ["x", "y", "width", "height"] {
        guard let number = bounds[key] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
    }
    guard (bounds["width"] as! NSNumber).doubleValue > 0,
          (bounds["height"] as! NSNumber).doubleValue > 0 else { return nil }
    for key in ["signingIdentifier", "teamIdentifier"] where value[key] != nil {
        guard value[key] is String else { return nil }
    }
    return value
}

func verifiedGregorianDate(_ value: String) -> String? {
    guard value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
    let parts = value.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let components = DateComponents(calendar: calendar, timeZone: calendar.timeZone,
                                    year: parts[0], month: parts[1], day: parts[2])
    guard let date = calendar.date(from: components) else { return nil }
    let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
    guard roundTrip.year == parts[0], roundTrip.month == parts[1], roundTrip.day == parts[2] else { return nil }
    return value
}

func parseHistoryState(_ raw: Any?) throws -> HistoryNativeState? {
    if raw == nil || raw is NSNull { return nil }
    guard JSONSerialization.isValidJSONObject(raw as Any),
          let encoded = try? JSONSerialization.data(withJSONObject: raw as Any, options: [.sortedKeys]),
          encoded.count <= historyStateByteLimit,
          let value = raw as? [String: Any],
          Set(value.keys) == ["version", "expectedWindow", "headerDigest", "anchorHash", "offset",
                              "pageNumber", "advance", "seenIds", "dateContext"],
          strictInteger(value["version"], minimum: 1, maximum: 1) == 1,
          let expectedWindow = validWindowState(value["expectedWindow"]),
          let headerDigest = lowerHex64(value["headerDigest"]),
          let anchorHash = lowerHex64(value["anchorHash"]),
          let offset = strictInteger(value["offset"], minimum: 0, maximum: 2_000),
          let pageNumber = strictInteger(value["pageNumber"], minimum: 0, maximum: 1_000),
          let advance = value["advance"] as? Bool,
          let seenIds = value["seenIds"] as? [String], seenIds.count <= historySeenIDLimit,
          seenIds.allSatisfy({ lowerHex64($0) != nil }), Set(seenIds).count == seenIds.count else {
        throw NativeFailure("INVALID_NATIVE_STATE", "nativeState 不符合 P3 固定 schema")
    }
    let dateContext: HistoryDateContext?
    if value["dateContext"] is NSNull {
        dateContext = nil
    } else {
        guard let context = value["dateContext"] as? [String: Any],
              Set(context.keys) == ["date", "anchorHash"],
              let date = context["date"] as? String, verifiedGregorianDate(date) != nil,
              let contextAnchor = lowerHex64(context["anchorHash"]) else {
            throw NativeFailure("INVALID_NATIVE_STATE", "nativeState.dateContext 格式不正確")
        }
        dateContext = HistoryDateContext(date: date, anchorHash: contextAnchor)
    }
    if dateContext != nil && dateContext!.anchorHash != anchorHash {
        throw NativeFailure("INVALID_NATIVE_STATE", "dateContext 未綁定目前 viewport anchor")
    }
    return HistoryNativeState(expectedWindow: expectedWindow, headerDigest: headerDigest,
                              anchorHash: anchorHash, offset: offset, pageNumber: pageNumber,
                              advance: advance, seenIds: seenIds, dateContext: dateContext)
}

func parseHistoryArguments(_ args: [String: Any], mode: HistoryMode = .tab) throws -> HistoryArguments {
    let allowed: Set<String> = mode == .tab
        ? ["tabName", "chatName", "limit", "identityKey", "nativeState"]
        : ["chatName", "resultIndex", "limit", "identityKey", "nativeState"]
    guard Set(args.keys).isSubset(of: allowed),
          let chatName = validName(args["chatName"]),
          let limit = strictInteger(args["limit"], minimum: 1, maximum: 100),
          let keyHex = lowerHex64(args["identityKey"]), let identityKey = dataFromLowerHex(keyHex),
          identityKey.count == 32 else {
        throw NativeFailure("INVALID_ARGUMENT", mode == .tab
                            ? "readHistoryPage 參數格式不正確"
                            : "readGlobalHistoryPage 參數格式不正確")
    }
    let tabName: String
    if mode == .tab {
        guard let verifiedTab = validName(args["tabName"]) else {
            throw NativeFailure("INVALID_ARGUMENT", "readHistoryPage 參數格式不正確")
        }
        tabName = verifiedTab
    } else {
        guard args["tabName"] == nil else {
            throw NativeFailure("INVALID_ARGUMENT", "readGlobalHistoryPage 不接受 tabName")
        }
        tabName = ""
    }
    let resultIndex = mode == .global && args["resultIndex"] != nil
        ? strictInteger(args["resultIndex"], minimum: 1, maximum: 20) : nil
    guard args["resultIndex"] == nil || resultIndex != nil else {
        throw NativeFailure("INVALID_ARGUMENT", "resultIndex 必須是 1 到 20 的整數")
    }
    let state = try parseHistoryState(args["nativeState"])
    guard resultIndex == nil || state == nil else {
        throw NativeFailure("INVALID_ARGUMENT", "resultIndex 模式不支援 nativeState/cursor")
    }
    return HistoryArguments(mode: mode, tabName: tabName, chatName: chatName, limit: limit,
                            identityKey: identityKey, state: state, resultIndex: resultIndex)
}

func historyScopeBinding(_ args: HistoryArguments) -> [String: Any] {
    var scope: [String: Any] = ["mode": args.mode.rawValue, "chatName": args.chatName]
    if args.mode == .tab { scope["tabName"] = args.tabName }
    if let resultIndex = args.resultIndex { scope["resultIndex"] = resultIndex }
    return scope
}

func historyResultScope(_ args: HistoryArguments) -> [String: Any] {
    if args.mode == .global {
        if let resultIndex = args.resultIndex {
            return ["kind": "search_result", "chatName": args.chatName,
                    "resultIndex": resultIndex, "verified": true]
        }
        return ["kind": "chat", "chatName": args.chatName, "verified": true]
    }
    return ["tabName": args.tabName, "chatName": args.chatName, "verified": true]
}

func historyMAC(_ key: Data, _ value: Any) -> String {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    return HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))
        .map { String(format: "%02x", $0) }.joined()
}

func randomHistoryID() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
        throw NativeFailure("RANDOM_ID_FAILED", "無法產生本機 opaque observation ID")
    }
    return bytes.map { String(format: "%02x", $0) }.joined()
}

func historyObservedID(key: Data, tabName: String, chatName: String, axIdentifier: String,
                       mode: HistoryMode = .tab) -> String {
    if mode == .tab {
        return historyMAC(key, ["purpose": "line-history-observed-id-v1", "tabName": tabName,
                                "chatName": chatName, "axIdentifier": axIdentifier])
    }
    return historyMAC(key, ["purpose": "line-global-history-observed-id-v1",
                            "mode": mode.rawValue, "chatName": chatName,
                            "axIdentifier": axIdentifier])
}

func utf16Prefix(_ value: String, maximum: Int) -> (String, Bool) {
    let units = Array(value.utf16)
    guard units.count > maximum else { return (value, false) }
    var prefix = Array(units.prefix(maximum))
    if let last = prefix.last, (0xD800...0xDBFF).contains(last) { prefix.removeLast() }
    return (String(decoding: prefix, as: UTF16.self), true)
}

struct HistoryPageSlice {
    let range: Range<Int>
    let nextOffset: Int?
    let advance: Bool
    let terminal: Bool
}

func historyPageSlice(total: Int, offset: Int, limit: Int, earliestBoundary: Bool) -> HistoryPageSlice? {
    guard total >= 0, offset >= 0, offset <= total, limit > 0 else { return nil }
    let end = min(total, offset + limit)
    if end < total {
        return HistoryPageSlice(range: offset..<end, nextOffset: end, advance: false, terminal: false)
    }
    return HistoryPageSlice(range: offset..<end, nextOffset: nil,
                            advance: !earliestBoundary, terminal: earliestBoundary)
}

func historyOverlapMask(ids: [String?], seenIds: [String], afterPhysicalScroll: Bool) -> [Bool] {
    var keep = Array(repeating: true, count: ids.count)
    guard afterPhysicalScroll, ids.count >= 2 else { return keep }
    let positions = Dictionary(uniqueKeysWithValues: seenIds.enumerated().map { ($0.element, $0.offset) })
    var runStart: Int?
    var previousSeen: Int?
    func closeRun(at end: Int) {
        if let start = runStart, end - start >= 2 {
            for index in start..<end { keep[index] = false }
        }
        runStart = nil
        previousSeen = nil
    }
    for index in ids.indices {
        guard let id = ids[index], let seen = positions[id] else { closeRun(at: index); continue }
        if previousSeen == nil || seen != previousSeen! + 1 {
            closeRun(at: index)
            runStart = index
        }
        previousSeen = seen
    }
    closeRun(at: ids.count)
    return keep
}

func historyScopeAllowsBody(memberMatches: Int, selectedMatches: Int,
                            headerMatches: Int, windowMatches: Bool) -> Bool {
    memberMatches == 1 && selectedMatches == 1 && headerMatches == 1 && windowMatches
}

func historyPossibleDuplicates(base: Bool, overlapUnverified: Bool,
                               emittedIdentityVerified: [Bool]) -> Bool {
    base || overlapUnverified || emittedIdentityVerified.contains(false)
}

enum HistoryScrollProgress: Equatable { case advanced, terminalBoundary, repeatedUnverified }

func historyScrollProgress(previousAnchor: String, currentAnchor: String,
                           actualEarliestBoundary: Bool) -> HistoryScrollProgress {
    if previousAnchor != currentAnchor { return .advanced }
    return actualEarliestBoundary ? .terminalBoundary : .repeatedUnverified
}

func historyContinuationUnsafe(structurePartial: Bool, messagePartial: Bool,
                               hasRows: Bool, repeatedPage: Bool) -> Bool {
    structurePartial || messagePartial || !hasRows || repeatedPage
}

func historyComplete(nextStateExists: Bool, syncState: String, truncated: Bool,
                     possibleDuplicates: Bool, hasUnknownDate: Bool, reasons: [String]) -> Bool {
    !nextStateExists && syncState == "complete" && !truncated && !possibleDuplicates &&
        !hasUnknownDate && reasons.isEmpty
}

func historyStateJSON(_ state: HistoryNativeState) -> [String: Any] {
    ["version": 1, "expectedWindow": state.expectedWindow,
     "headerDigest": state.headerDigest, "anchorHash": state.anchorHash,
     "offset": state.offset, "pageNumber": state.pageNumber, "advance": state.advance,
     "seenIds": state.seenIds,
     "dateContext": state.dateContext.map { ["date": $0.date, "anchorHash": $0.anchorHash] } ?? NSNull()]
}

func boundedHistoryStateJSON(_ state: HistoryNativeState) -> [String: Any]? {
    let value = historyStateJSON(state)
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
          data.count <= historyStateByteLimit else { return nil }
    return value
}

struct HistoryScopeProof {
    let identity: WindowIdentity
    let headerDigest: String
}

struct HistoryScrollBoundary {
    let earliest: Bool
    let latest: Bool
}

struct HistoryMessageContext {
    let list: AXUIElement
    let listFrame: CGRect
    let identity: WindowIdentity
    let structure: Snapshot
    let anchorHash: String
    let boundary: HistoryScrollBoundary?
}

struct HistoryRowEvidence {
    let frame: CGRect
    let stableID: String?
    let text: String
    let date: String?
    let unit: String
    let source: String
    let provenanceComplete: Bool
    let textTruncated: Bool
}

struct HistoryReadResult {
    let tree: Snapshot
    let rows: [HistoryRowEvidence]
    let possibleDuplicates: Bool
    let contentAnchor: String
}

struct IndexedSearchTarget {
    let identity: WindowIdentity
    let listFrame: CGRect
    let rowFrame: CGRect
    let labelFrame: CGRect
    let bitmapDigest: String
}

func normalizedFullNameImage(_ image: CGImage) throws -> CGImage {
    let width = image.width, height = image.height
    var (pixels, bytesPerRow) = try rgbaBottomUp(image)
    guard width > 4, height > 4, stride(from: 3, to: pixels.count, by: 4)
        .allSatisfy({ pixels[$0] == 255 }) else {
        throw NativeFailure("INDEXED_NAME_PROFILE_UNVERIFIED", "名字欄不是完整 opaque RGB")
    }
    var border = [[UInt8](), [UInt8](), [UInt8]()]
    for y in 0..<height { for x in 0..<width where x == 0 || y == 0 || x == width - 1 || y == height - 1 {
        let offset = y * bytesPerRow + x * 4
        for channel in 0..<3 { border[channel].append(pixels[offset + channel]) }
    } }
    let background = border.map { values -> UInt8 in
        let sorted = values.sorted(); return sorted[sorted.count / 2]
    }
    guard border.enumerated().allSatisfy({ channel, values in
        values.allSatisfy { abs(Int($0) - Int(background[channel])) <= 12 }
    }) else { throw NativeFailure("INDEXED_NAME_PROFILE_UNVERIFIED", "名字欄邊界背景不均") }
    var distances = [Int](repeating: 0, count: width * height), peak = 0
    for y in 0..<height { for x in 0..<width {
        let offset = y * bytesPerRow + x * 4
        let distance = (0..<3).map { abs(Int(pixels[offset + $0]) - Int(background[$0])) }.max()!
        distances[y * width + x] = distance; peak = max(peak, distance)
    } }
    guard peak >= 16 else { throw NativeFailure("INDEXED_NAME_PROFILE_UNVERIFIED", "名字欄沒有足夠 RGB 對比") }
    for y in 0..<height { for x in 0..<width {
        let value = UInt8(max(0, min(255, 255 - distances[y * width + x] * 255 / peak)))
        let offset = y * bytesPerRow + x * 4
        pixels[offset] = value; pixels[offset + 1] = value; pixels[offset + 2] = value
    } }
    let topDown = topDownRows(pixels, bytesPerRow: bytesPerRow, height: height)
    guard let result = rgbaImage(topDown: topDown, width: width, height: height) else {
        throw NativeFailure("INDEXED_NAME_PROFILE_UNVERIFIED", "無法建立名字 RGB 正規化影像")
    }
    return result
}

func indexedUniformBackground(_ image: CGImage) throws -> [Int]? {
    let width = image.width, height = image.height
    let (raw, bytesPerRow) = try rgbaBottomUp(image)
    let pixels = topDownRows(raw, bytesPerRow: bytesPerRow, height: height)
    var channels = [[Int](), [Int](), [Int]()]
    for y in 0..<height { for x in 0..<width where y == 0 || x == 0 || x == width - 1 {
        let offset = y * bytesPerRow + x * 4
        guard pixels[offset + 3] == 255 else { return nil }
        for channel in 0..<3 { channels[channel].append(Int(pixels[offset + channel])) }
    } }
    let background = channels.map { values -> Int in
        let sorted = values.sorted(); return sorted[sorted.count / 2]
    }
    guard channels.enumerated().allSatisfy({ channel, values in
        values.allSatisfy { abs($0 - background[channel]) <= 12 }
    }) else { return nil }
    return background
}

func indexedInkRows(_ image: CGImage, background: [Int], maximumWidth: Int) throws -> [Bool] {
    guard background.count == 3 else { return [] }
    let width = min(image.width, maximumWidth), height = image.height
    let (raw, bytesPerRow) = try rgbaBottomUp(image)
    let pixels = topDownRows(raw, bytesPerRow: bytesPerRow, height: height)
    return (0..<height).map { y in
        (0..<width).contains { x in
            let offset = y * bytesPerRow + x * 4
            guard pixels[offset + 3] == 255 else { return true }
            return (0..<3).map { abs(Int(pixels[offset + $0]) - background[$0]) }.max()! >= 16
        }
    }
}

func adaptiveIndexedNameBandROI(identity: WindowIdentity, listFrame: CGRect,
                                rowFrame: CGRect) throws -> CGRect {
    let x = listFrame.minX + 74, width: CGFloat = 176
    let initialROI = CGRect(x: x, y: rowFrame.minY, width: width, height: 24)
    let initialImage = try captureWindowImage(identity, roi: initialROI, opaqueForRead: true)
    let initialGeometry = CaptureGeometry(window: identity.bounds, roi: initialROI,
                                          imageWidth: initialImage.width,
                                          imageHeight: initialImage.height)
    guard let initial = initialImage.cropping(to: try initialGeometry.roiPixels()),
          let background = try indexedUniformBackground(initial) else {
        throw NativeFailure("INDEXED_NAME_BAND_UNVERIFIED", "名字第一行背景不可靠")
    }
    let scale = initialGeometry.scaleX
    let scanWidth = Int(ceil(80 * scale))
    var rows = try indexedInkRows(initial, background: background, maximumWidth: scanWidth)
    var offset = 24
    var lineHeight = indexedFirstLineHeight(rows, scale: scale)
    while offset < 52 && lineHeight == nil {
        let stripROI = CGRect(x: x, y: rowFrame.minY + CGFloat(offset), width: 80, height: 2)
        let stripImage = try captureWindowImage(identity, roi: stripROI, opaqueForRead: true)
        let stripGeometry = CaptureGeometry(window: identity.bounds, roi: stripROI,
                                            imageWidth: stripImage.width,
                                            imageHeight: stripImage.height)
        guard let strip = stripImage.cropping(to: try stripGeometry.roiPixels()) else {
            throw NativeFailure("INDEXED_NAME_BAND_UNVERIFIED", "名字第一行 scan strip 無法裁切")
        }
        rows.append(contentsOf: try indexedInkRows(strip, background: background,
                                                   maximumWidth: scanWidth))
        offset += 2
        lineHeight = indexedFirstLineHeight(rows, scale: scale)
    }
    guard let lineHeight else {
        throw NativeFailure("INDEXED_NAME_BAND_UNVERIFIED", "名字第一行無唯一 blank boundary")
    }
    return CGRect(x: x, y: rowFrame.minY, width: width, height: lineHeight)
}

func indexedFirstLineHeight(_ rowHasInk: [Bool], scale: CGFloat) -> CGFloat? {
    guard scale.isFinite, scale >= 0.5, scale <= 4 else { return nil }
    let initialPixels = Int((24 * scale).rounded())
    let blankPixels = max(1, Int(ceil(2 * scale)))
    guard rowHasInk.count >= initialPixels,
          let firstInk = rowHasInk[..<initialPixels].firstIndex(of: true) else { return nil }
    var blankStart = firstInk + 1
    while blankStart + blankPixels <= rowHasInk.count {
        if rowHasInk[blankStart..<(blankStart + blankPixels)].allSatisfy({ !$0 }) {
            guard let lastInk = rowHasInk[..<blankStart].lastIndex(of: true),
                  CGFloat(lastInk - firstInk + 1) / scale <= 26 else { return nil }
            return CGFloat(blankStart + blankPixels) / scale
        }
        blankStart += 1
    }
    return nil
}

func canonicalReadOCRCandidate(_ candidate: OCRCandidate,
                               imageWidth: Int, imageHeight: Int) -> OCRCandidate? {
    guard let pixels = boundedOCRPixelRect(candidate.normalizedBox,
                                           width: imageWidth, height: imageHeight,
                                           maximumOutside: 0.00001) else { return nil }
    let normalized = CGRect(x: pixels.minX / CGFloat(imageWidth),
                            y: 1 - pixels.maxY / CGFloat(imageHeight),
                            width: pixels.width / CGFloat(imageWidth),
                            height: pixels.height / CGFloat(imageHeight))
    guard validNormalizedBox(normalized) else { return nil }
    return OCRCandidate(text: candidate.text, confidence: candidate.confidence,
                        normalizedBox: normalized)
}

func canonicalReadOCRCandidates(_ candidates: [OCRCandidate],
                                imageWidth: Int, imageHeight: Int) -> [OCRCandidate] {
    candidates.map {
        canonicalReadOCRCandidate($0, imageWidth: imageWidth, imageHeight: imageHeight) ?? $0
    }
}

func indexedExactNameCandidate(_ candidates: [OCRCandidate], expected: String,
                               imageWidth: Int, imageHeight: Int) -> OCRCandidate? {
    let canonical = candidates.compactMap {
        canonicalReadOCRCandidate($0, imageWidth: imageWidth, imageHeight: imageHeight)
    }
    guard canonical.count == candidates.count else { return nil }
    let exact = canonical.filter { $0.text == expected }
    guard exact.count == 1, let candidate = exact.first,
          candidate.text == expected, candidate.confidence >= ocrConfidenceThreshold,
          validNormalizedBox(candidate.normalizedBox), !candidate.text.contains("…"), imageWidth > 0,
          canonical.filter({ $0.text != expected }).allSatisfy({ auxiliary in
              validNormalizedBox(auxiliary.normalizedBox) && rendererUITimeText(auxiliary.text) &&
              (auxiliary.normalizedBox.minX - candidate.normalizedBox.maxX) *
                CGFloat(imageWidth) >= 8
          }) else { return nil }
    return candidate
}

func indexedRawNameAllowsNormalizedFallback(_ candidates: [OCRCandidate], expected: String,
                                            imageWidth: Int, imageHeight: Int) -> Bool {
    guard candidates.filter({ $0.text == expected }).count < 2 else { return false }
    return candidates.filter { $0.confidence >= ocrConfidenceThreshold }.allSatisfy { candidate in
        guard canonicalReadOCRCandidate(candidate, imageWidth: imageWidth,
                                        imageHeight: imageHeight) != nil else { return false }
        return candidate.text == expected || rendererUITimeText(candidate.text)
    }
}

struct IndexedNameCandidateChoice {
    let candidate: OCRCandidate
    let candidates: [OCRCandidate]
    let normalizedOCRUsed: Bool
}

func indexedNameCandidateChoice(rawCandidates: [OCRCandidate], expected: String,
                                imageWidth: Int, imageHeight: Int,
                                sourceOwnership: (OCRCandidate, [OCRCandidate]) throws -> Bool,
                                normalizedCandidates: () throws -> [OCRCandidate]) throws
    -> IndexedNameCandidateChoice? {
    if let raw = indexedExactNameCandidate(rawCandidates, expected: expected,
                                           imageWidth: imageWidth, imageHeight: imageHeight),
       try sourceOwnership(raw, rawCandidates) {
        return IndexedNameCandidateChoice(candidate: raw, candidates: rawCandidates,
                                          normalizedOCRUsed: false)
    }
    guard indexedRawNameAllowsNormalizedFallback(rawCandidates, expected: expected,
                                                 imageWidth: imageWidth,
                                                 imageHeight: imageHeight) else { return nil }
    let normalized = try normalizedCandidates()
    guard let candidate = indexedExactNameCandidate(normalized, expected: expected,
                                                    imageWidth: imageWidth,
                                                    imageHeight: imageHeight),
          try sourceOwnership(candidate, normalized) else { return nil }
    return IndexedNameCandidateChoice(candidate: candidate, candidates: normalized,
                                      normalizedOCRUsed: true)
}

func indexedChatSectionCount(labelCandidates: [OCRCandidate],
                             countCandidates: [OCRCandidate]) -> Int? {
    guard labelCandidates.count == 1, countCandidates.count == 1,
          let label = labelCandidates.first, let count = countCandidates.first,
          label.text == "聊天", label.confidence >= ocrConfidenceThreshold,
          count.confidence >= ocrConfidenceThreshold,
          validNormalizedBox(label.normalizedBox), validNormalizedBox(count.normalizedBox),
          count.text.range(of: #"^[0-9]{1,5}$"#, options: .regularExpression) != nil,
          let value = Int(count.text), (1...99_999).contains(value) else { return nil }
    return value
}

func indexedChatSectionResultAllowed(count: Int?, resultIndex: Int) -> Bool {
    guard let count, (1...20).contains(resultIndex) else { return false }
    return resultIndex <= count
}

func indexedChatSectionInsetCrop(_ image: CGImage, scaleX: CGFloat,
                                 scaleY: CGFloat) -> CGImage? {
    guard scaleX.isFinite, scaleY.isFinite, scaleX >= 0.5, scaleX <= 4,
          scaleY >= 0.5, scaleY <= 4 else { return nil }
    let left = ceil(8 * scaleX), top = ceil(6 * scaleY)
    let horizontal = ceil(16 * scaleX), vertical = ceil(8 * scaleY)
    let rect = CGRect(x: left, y: top,
                      width: CGFloat(image.width) - horizontal,
                      height: CGFloat(image.height) - vertical).integral
    guard let crop = indexedTopDownCropRect(rect, width: image.width, height: image.height) else {
        return nil
    }
    return image.cropping(to: crop)
}

struct IndexedChatSectionCrops {
    let label: CGImage
    let count: CGImage
}

func indexedChatSectionDomainCrops(_ image: CGImage, scale: CGFloat)
    throws -> IndexedChatSectionCrops? {
    guard scale.isFinite, scale >= 0.5, scale <= 4,
          let background = try indexedHeaderBackground(image) else { return nil }
    let luma = try imageLuma(image)
    let allInk = luma.indices.filter { Int(luma[$0]) <= background - 12 }
    let ink = luma.indices.filter { Int(luma[$0]) < 200 }
    guard !ink.isEmpty else { return nil }
    let occupiedX = Set(ink.map { $0 % image.width })
    guard let firstX = occupiedX.min(), let lastX = occupiedX.max(), firstX > 0,
          lastX < image.width - 1 else { return nil }
    let minimumGap = max(1, Int(ceil(4 * scale)))
    var gaps: [ClosedRange<Int>] = [], start: Int?
    for x in firstX...lastX {
        if !occupiedX.contains(x) {
            if start == nil { start = x }
        } else if let begin = start {
            if x - begin >= minimumGap { gaps.append(begin...(x - 1)) }
            start = nil
        }
    }
    guard gaps.count == 1, let gap = gaps.first else { return nil }
    let labelInk = ink.filter { $0 % image.width < gap.lowerBound }
    let countInk = ink.filter { $0 % image.width > gap.upperBound }
    guard !labelInk.isEmpty, !countInk.isEmpty else { return nil }
    func crop(_ indices: [Int], minX: Int, maxX: Int) -> (image: CGImage, rect: CGRect)? {
        let xs = indices.map { $0 % image.width }
        let padding = ceil(4 * scale)
        let rect = CGRect(
            x: max(CGFloat(minX), CGFloat(xs.min()!) - padding),
            y: 0,
            width: min(CGFloat(maxX), CGFloat(xs.max()! + 1) + padding) -
                max(CGFloat(minX), CGFloat(xs.min()!) - padding),
            height: CGFloat(image.height)
        ).integral
        guard let bounded = indexedTopDownCropRect(rect, width: image.width, height: image.height) else {
            return nil
        }
        guard let cropped = image.cropping(to: bounded) else { return nil }
        return (cropped, bounded)
    }
    let split = (gap.lowerBound + gap.upperBound + 1) / 2
    guard let label = crop(labelInk, minX: 0, maxX: split),
          let count = crop(countInk, minX: split, maxX: image.width) else { return nil }
    guard allInk.allSatisfy({ index in
        let point = CGPoint(x: CGFloat(index % image.width) + 0.5,
                            y: CGFloat(index / image.width) + 0.5)
        return label.rect.contains(point) || count.rect.contains(point)
    }) else { return nil }
    return IndexedChatSectionCrops(label: label.image, count: count.image)
}

func indexedWholeInkCrop(_ image: CGImage) throws -> CGImage? {
    let luma = try imageLuma(image)
    guard let background = try indexedHeaderBackground(image) else { return nil }
    let ink = luma.indices.filter { Int(luma[$0]) <= background - 12 }
    guard !ink.isEmpty else { return nil }
    let xs = ink.map { $0 % image.width }, ys = ink.map { $0 / image.width }
    let actual = CGRect(x: xs.min()!, y: ys.min()!,
                        width: xs.max()! - xs.min()! + 1,
                        height: ys.max()! - ys.min()! + 1)
    guard actual.minX > 0, actual.minY > 0,
          actual.maxX < CGFloat(image.width - 1),
          actual.maxY < CGFloat(image.height - 1) else { return nil }
    let padded = actual.insetBy(dx: -4, dy: -4).intersection(
        CGRect(x: 0, y: 0, width: image.width, height: image.height)
    ).integral
    guard let crop = indexedTopDownCropRect(padded, width: image.width, height: image.height) else {
        return nil
    }
    return image.cropping(to: crop)
}

func indexedWholeGlyphOwnershipAllowed(_ image: CGImage, name: OCRCandidate,
                                       auxiliaries: [OCRCandidate], scale: CGFloat) throws -> Bool {
    let width = image.width, height = image.height
    guard scale.isFinite, scale >= 0.5, scale <= 4,
          let namePixels = boundedOCRPixelRect(name.normalizedBox, width: width, height: height) else {
        return false
    }
    let auxiliaryPixels = auxiliaries.compactMap {
        boundedOCRPixelRect($0.normalizedBox, width: width, height: height)
    }
    guard auxiliaryPixels.count == auxiliaries.count, auxiliaryPixels.count <= 2 else { return false }
    let (raw, bytesPerRow) = try rgbaBottomUp(image)
    let pixels = topDownRows(raw, bytesPerRow: bytesPerRow, height: height)
    var border = [[Int](), [Int](), [Int]()]
    for y in 0..<height { for x in 0..<width where x == 0 || y == 0 || x == width - 1 || y == height - 1 {
        let offset = y * bytesPerRow + x * 4
        guard pixels[offset + 3] == 255 else { return false }
        for channel in 0..<3 { border[channel].append(Int(pixels[offset + channel])) }
    } }
    let background = border.map { values -> Int in
        let sorted = values.sorted(); return sorted[sorted.count / 2]
    }
    guard border.enumerated().allSatisfy({ channel, values in
        values.allSatisfy { abs($0 - background[channel]) <= 12 }
    }) else { return false }
    let backgroundLuma = (background[0] * 54 + background[1] * 183 + background[2] * 19) / 256
    var ink = [Bool](repeating: false, count: width * height)
    var nameIndices: [Int] = [], auxiliaryIndices = [[Int]](repeating: [], count: auxiliaryPixels.count)
    for y in 0..<height { for x in 0..<width {
        let offset = y * bytesPerRow + x * 4
        guard pixels[offset + 3] == 255 else { return false }
        let distance = (0..<3).map { abs(Int(pixels[offset + $0]) - background[$0]) }.max()!
        guard distance < 16 || (x > 0 && x < width - 1 && y > 0 && y < height - 1) else { return false }
        guard distance >= 16 else { continue }
        let index = y * width + x; ink[index] = true
        let point = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
        var owners = [Int]()
        if namePixels.insetBy(dx: -1, dy: -1).contains(point) { owners.append(-1) }
        for (auxIndex, box) in auxiliaryPixels.enumerated()
            where box.insetBy(dx: -1, dy: -1).contains(point) { owners.append(auxIndex) }
        guard owners.count == 1 else { return false }
        if owners[0] == -1 { nameIndices.append(index) }
        else { auxiliaryIndices[owners[0]].append(index) }
    } }
    guard !nameIndices.isEmpty else { return false }
    let nameXs = nameIndices.map { $0 % width }, nameYs = nameIndices.map { $0 / width }
    let actualPixels = CGRect(x: nameXs.min()!, y: nameYs.min()!,
                              width: nameXs.max()! - nameXs.min()! + 1,
                              height: nameYs.max()! - nameYs.min()! + 1)
    let actualNormalized = CGRect(x: actualPixels.minX / CGFloat(width),
                                  y: 1 - actualPixels.maxY / CGFloat(height),
                                  width: actualPixels.width / CGFloat(width),
                                  height: actualPixels.height / CGFloat(height))
    guard actualGlyphCoverageAllowed(actual: actualNormalized, coarse: name.normalizedBox,
                                     imageWidth: width, imageHeight: height) else { return false }
    let nameDarkest = nameIndices.map { index -> Int in
        let offset = (index / width) * bytesPerRow + (index % width) * 4
        return (Int(pixels[offset]) * 54 + Int(pixels[offset + 1]) * 183 +
                Int(pixels[offset + 2]) * 19) / 256
    }.min()!
    for (auxIndex, indices) in auxiliaryIndices.enumerated() {
        guard !indices.isEmpty else { return false }
        var visited = Set<Int>(), components = 0
        for start in indices where !visited.contains(start) {
            components += 1; var queue = [start]; visited.insert(start)
            while let current = queue.popLast() {
                let x = current % width, y = current / width
                for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    let nx = x + dx, ny = y + dy, next = ny * width + nx
                    if nx >= 0, nx < width, ny >= 0, ny < height,
                       ink[next], indices.contains(next), visited.insert(next).inserted { queue.append(next) }
                }
            }
        }
        let box = auxiliaryPixels[auxIndex]
        guard box.minX >= actualPixels.maxX,
              let darkest = indices.map({ index -> Int in
                  let offset = (index / width) * bytesPerRow + (index % width) * 4
                  return (Int(pixels[offset]) * 54 + Int(pixels[offset + 1]) * 183 +
                          Int(pixels[offset + 2]) * 19) / 256
              }).min(), auxiliaryComponentVerdict(
                componentCount: components, widthPoints: box.width / scale,
                heightPoints: box.height / scale, pixelCount: indices.count,
                pixelArea: Int(box.width * box.height), darkest: darkest,
                nameCountDarkest: nameDarkest, background: backgroundLuma,
                maximumChannelSpread: indices.map({ index -> Int in
                    let offset = (index / width) * bytesPerRow + (index % width) * 4
                    return [Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2])].max()! -
                        [Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2])].min()!
                }).max() ?? 0, opaque: true
              ) != .rejected else { return false }
    }
    return true
}

func indexedSearchTarget(chatName: String, resultIndex: Int,
                         expected: WindowIdentity) throws -> IndexedSearchTarget {
    let (_, _, window, identity) = try mainWindow(requireForeground: true)
    guard sameWindow(expected, identity) else { throw NativeFailure("WINDOW_CHANGED", "indexed row 視窗漂移") }
    let tree = snapshot(window, mode: .geometryOnly)
    let layout = try readTabLayout(tree, window: identity)
    guard let listFrame = tree.nodes[layout.leftListIndex].frame else {
        throw NativeFailure("INDEXED_SEARCH_RESULT_UNAVAILABLE", "搜尋清單缺少 frame")
    }
    let headerHeight: CGFloat = 34, rowHeight: CGFloat = 71
    let rowFrame = CGRect(x: listFrame.minX, y: listFrame.minY + headerHeight +
        CGFloat(resultIndex - 1) * rowHeight, width: listFrame.width, height: rowHeight)
    guard listFrame.contains(rowFrame) else {
        throw NativeFailure("INDEXED_SEARCH_RESULT_NOT_VISIBLE", "指定搜尋列未完整可見")
    }
    let sectionROI = CGRect(x: listFrame.minX, y: listFrame.minY,
                            width: listFrame.width, height: headerHeight)
    let sectionImage = try captureWindowImage(identity, roi: sectionROI, opaqueForRead: true)
    let sectionGeometry = CaptureGeometry(window: identity.bounds, roi: sectionROI,
                                          imageWidth: sectionImage.width, imageHeight: sectionImage.height)
    guard let sectionCrop = sectionImage.cropping(to: try sectionGeometry.roiPixels()) else {
        throw NativeFailure("INDEXED_SECTION_UNVERIFIED", "無法裁切 Chat section")
    }
    guard let sectionInset = indexedChatSectionInsetCrop(
        sectionCrop, scaleX: sectionGeometry.scaleX, scaleY: sectionGeometry.scaleY
    ) else {
        throw NativeFailure("INDEXED_SECTION_UNVERIFIED", "Chat section 安全 inset 不可靠")
    }
    let sectionCanonical = try canonicalReadROI(sectionInset).image
    let sectionNormalized = try normalizedFullNameImage(sectionCanonical)
    guard let sectionDomains = try indexedChatSectionDomainCrops(
        sectionNormalized, scale: sectionGeometry.scaleX
    ), let labelEvidence = try uniqueStrictCropCandidate(sectionDomains.label, kind: .nameOrTime),
       let countEvidence = try uniqueStrictCropCandidate(sectionDomains.count, kind: .nameOrTime),
       let sectionCount = indexedChatSectionCount(
        labelCandidates: [labelEvidence.candidate], countCandidates: [countEvidence.candidate]
       ), indexedChatSectionResultAllowed(count: sectionCount, resultIndex: resultIndex) else {
        throw NativeFailure("INDEXED_SECTION_UNVERIFIED", "Chat section label/count 或指定序位不符")
    }
    let bandROI = try adaptiveIndexedNameBandROI(identity: identity,
                                                 listFrame: listFrame, rowFrame: rowFrame)
    guard rowFrame.contains(bandROI), listFrame.contains(bandROI) else {
        throw NativeFailure("INDEXED_NAME_BAND_UNVERIFIED", "名字第一行 band 超出指定列")
    }
    let image = try captureWindowImage(identity, roi: bandROI, opaqueForRead: true)
    let geometry = CaptureGeometry(window: identity.bounds, roi: bandROI,
                                   imageWidth: image.width, imageHeight: image.height)
    guard let crop = image.cropping(to: try geometry.roiPixels()) else {
        throw NativeFailure("INDEXED_NAME_BAND_UNVERIFIED", "無法裁切名字第一行")
    }
    let normalized = try normalizedFullNameImage(crop)
    let rawCandidates = try visionCandidates(crop)
    guard let choice = try indexedNameCandidateChoice(
        rawCandidates: rawCandidates, expected: chatName,
        imageWidth: crop.width, imageHeight: crop.height,
        sourceOwnership: { candidate, candidates in
            try indexedWholeGlyphOwnershipAllowed(
                crop, name: candidate, auxiliaries: candidates.filter { $0.text != chatName },
                scale: geometry.scaleX
            )
        }, normalizedCandidates: { try visionCandidates(normalized) }
    ) else {
        throw NativeFailure("INDEXED_NAME_UNVERIFIED", "指定搜尋列完整名字無法 exact 驗證")
    }
    let candidate = choice.candidate
    let bandGeometry = CaptureGeometry(window: identity.bounds, roi: bandROI,
                                       imageWidth: image.width, imageHeight: image.height)
    let labelFrame = try bandGeometry.screenRect(for: candidate)
    let (rgba, _) = try rgbaBottomUp(normalized)
    return IndexedSearchTarget(identity: identity, listFrame: listFrame, rowFrame: rowFrame,
                               labelFrame: labelFrame,
                               bitmapDigest: SHA256.hash(data: Data(rgba)).map {
                                   String(format: "%02x", $0)
                               }.joined())
}

func stableIndexedSearchTarget(chatName: String, resultIndex: Int,
                               expected: WindowIdentity) throws -> IndexedSearchTarget {
    let first = try indexedSearchTarget(chatName: chatName, resultIndex: resultIndex, expected: expected)
    Thread.sleep(forTimeInterval: 0.06)
    let second = try indexedSearchTarget(chatName: chatName, resultIndex: resultIndex, expected: expected)
    guard sameWindow(first.identity, second.identity), first.listFrame == second.listFrame,
          first.rowFrame == second.rowFrame, first.bitmapDigest == second.bitmapDigest,
          intersectionOverUnion(first.labelFrame, second.labelFrame) >= 0.80 else {
        throw NativeFailure("INDEXED_SEARCH_RESULT_DRIFT", "指定搜尋列兩次名字證據漂移")
    }
    return second
}

struct IndexedSceneWindow {
    let pid: pid_t
    let id: CGWindowID
    let frame: CGRect
    let layer: Int
    let trustedCursor: Bool
}

func indexedSceneAllowsTarget(windows: [IndexedSceneWindow], point: CGPoint,
                              targetROI: CGRect, expectedPID: pid_t,
                              expectedWindowID: CGWindowID, cursorLayer: Int,
                              axOwnerVerified: Bool) -> Bool {
    guard axOwnerVerified,
          let first = windows.first(where: {
              $0.frame.contains(point) && !($0.layer == cursorLayer && $0.trustedCursor)
          }), first.pid == expectedPID, first.id == expectedWindowID else { return false }
    return !windows.contains(where: {
        $0.pid == expectedPID && $0.id != expectedWindowID &&
            ($0.frame.contains(point) || $0.frame.intersects(targetROI))
    })
}

func verifyIndexedPointScene(expected: WindowIdentity, point: CGPoint,
                             targetROI: CGRect) throws {
    // indexed Qt row 無 AX parent/window relation；先保留完整 signed/focused LINE guard。
    _ = try strictGlobalAllWindow(expected: expected.json)
    let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                         kCGNullWindowID) as? [[String: Any]] ?? []
    let cursorLayer = Int(CGWindowLevelForKey(.cursorWindow))
    var windows: [IndexedSceneWindow] = []
    for item in raw {
        guard let pid = (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              let id = (item[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let layer = (item[kCGWindowLayer as String] as? NSNumber)?.intValue,
              let bounds = item[kCGWindowBounds as String] as? [String: Any],
              let frame = rect(from: bounds) else {
            throw NativeFailure("INDEXED_SCENE_UNVERIFIED", "CG scene metadata 不完整")
        }
        windows.append(IndexedSceneWindow(
            pid: pid, id: id, frame: frame, layer: layer,
            trustedCursor: trustedWindowServerCursorPID(pid, layer: layer,
                                                        cursorLayer: cursorLayer)
        ))
    }
    var hit: AXUIElement?, hitPID: pid_t = 0
    var axOwnerVerified = false
    if AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x),
                                        Float(point.y), &hit) == .success, let hit {
        axOwnerVerified = AXUIElementGetPid(hit, &hitPID) == .success && hitPID == expected.pid
    }
    guard indexedSceneAllowsTarget(windows: windows, point: point, targetROI: targetROI,
                                   expectedPID: expected.pid,
                                   expectedWindowID: expected.windowID,
                                   cursorLayer: cursorLayer,
                                   axOwnerVerified: axOwnerVerified) else {
        throw NativeFailure("INDEXED_SCENE_UNVERIFIED", "指定搜尋列 CG window 或 AX hit PID 不符")
    }
}

func indexedTopDownCropRect(_ padded: CGRect, width: Int, height: Int) -> CGRect? {
    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
    let crop = padded.integral
    return width > 0 && height > 0 && bounds.contains(crop) && crop.width >= 1 && crop.height >= 1
        ? crop : nil
}

func indexedHeaderBackground(_ canonical: CGImage) throws -> Int? {
    let (raw, bytesPerRow) = try rgbaBottomUp(canonical)
    let pixels = topDownRows(raw, bytesPerRow: bytesPerRow, height: canonical.height)
    var values: [Int] = []
    for y in 0..<canonical.height { for x in 0..<canonical.width
        where x == 0 || y == 0 || x == canonical.width - 1 || y == canonical.height - 1 {
        let offset = y * bytesPerRow + x * 4
        let channels = [Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2])]
        guard pixels[offset + 3] == 255, channels.max()! - channels.min()! <= 12 else { return nil }
        values.append((channels[0] * 54 + channels[1] * 183 + channels[2] * 19) / 256)
    } }
    guard !values.isEmpty else { return nil }
    let median = values.sorted()[values.count / 2]
    return values.allSatisfy { abs($0 - median) <= 12 } ? median : nil
}

func indexedHeaderAuxiliaryDomainsValid(mask: [Bool], luma: [UInt8],
                                         originalPixels: [UInt8], bytesPerRow: Int,
                                         width: Int, height: Int,
                                         nameActual: CGRect, nameDarkest: Int,
                                         background: Int, scaleX: CGFloat,
                                         scaleY: CGFloat) -> Bool {
    guard width > 0, height > 0, mask.count == width * height,
          luma.count == mask.count, bytesPerRow == width * 4,
          originalPixels.count == bytesPerRow * height,
          scaleX.isFinite, scaleY.isFinite, scaleX >= 0.5, scaleX <= 4,
          scaleY >= 0.5, scaleY <= 4 else { return false }
    var visited = [Bool](repeating: false, count: mask.count)
    var components: [(indices: [Int], box: CGRect)] = []
    for start in mask.indices where mask[start] && !visited[start] {
        var queue = [start], indices: [Int] = []; visited[start] = true
        while let current = queue.popLast() {
            indices.append(current); let x = current % width, y = current / width
            for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                let next = ny * width + nx
                if mask[next] && !visited[next] { visited[next] = true; queue.append(next) }
            } }
        }
        let xs = indices.map { $0 % width }, ys = indices.map { $0 / width }
        components.append((indices, CGRect(x: xs.min()!, y: ys.min()!,
                                           width: xs.max()! - xs.min()! + 1,
                                           height: ys.max()! - ys.min()! + 1)))
    }
    components.sort { $0.box.minX < $1.box.minX }
    var domains: [[(indices: [Int], box: CGRect)]] = []
    let domainGap = ceil(3 * scaleX)
    for component in components {
        if let last = domains.indices.last,
           component.box.minX - domains[last].map(\.box.maxX).max()! <= domainGap {
            domains[last].append(component)
        } else { domains.append([component]) }
    }
    guard domains.count <= 2 else { return false }
    for domain in domains {
        let indices = domain.flatMap(\.indices)
        let minX = domain.map(\.box.minX).min()!, maxX = domain.map(\.box.maxX).max()!
        let minY = domain.map(\.box.minY).min()!, maxY = domain.map(\.box.maxY).max()!
        let box = CGRect(x: minX, y: minY,
                         width: maxX - minX + 1, height: maxY - minY + 1)
        let pixelMetadata = indices.map { index -> (spread: Int, opaque: Bool) in
            let offset = (index / width) * bytesPerRow + (index % width) * 4
            let channels = [Int(originalPixels[offset]), Int(originalPixels[offset + 1]),
                            Int(originalPixels[offset + 2])]
            return (channels.max()! - channels.min()!, originalPixels[offset + 3] == 255)
        }
        guard box.minX >= nameActual.maxX, box.minX > 0, box.maxX < CGFloat(width - 1),
              auxiliaryComponentVerdict(
                componentCount: domain.count, widthPoints: box.width / scaleX,
                heightPoints: box.height / scaleY, pixelCount: indices.count,
                pixelArea: Int(box.width * box.height),
                darkest: indices.map { Int(luma[$0]) }.min()!,
                nameCountDarkest: nameDarkest, background: background,
                maximumChannelSpread: pixelMetadata.map(\.spread).max() ?? 0,
                opaque: pixelMetadata.allSatisfy(\.opaque)
              ) != .rejected else { return false }
    }
    return true
}

func verifyIndexedHeader(_ chatName: String, expected: WindowIdentity) throws -> WindowIdentity {
    func capture() throws -> (WindowIdentity, OCRCandidate) {
        let (_, _, window, identity) = try mainWindow(requireForeground: true)
        guard sameWindow(expected, identity) else { throw NativeFailure("WINDOW_CHANGED", "header 視窗漂移") }
        let tree = snapshot(window, mode: .geometryOnly)
        let layout = try readTabLayout(tree, window: identity)
        let leftFrame = tree.nodes[layout.leftListIndex].frame!
        let roi = CGRect(x: leftFrame.maxX + 2, y: layout.tabROI.maxY + 6,
                         width: identity.bounds.maxX - leftFrame.maxX - 152, height: 40)
        let image = try captureWindowImage(identity, roi: roi, opaqueForRead: true)
        let geometry = CaptureGeometry(window: identity.bounds, roi: roi,
                                       imageWidth: image.width, imageHeight: image.height)
        guard let crop = image.cropping(to: try geometry.roiPixels()) else {
            throw NativeFailure("CHAT_SELECTION_UNVERIFIED", "無法裁切完整 header")
        }
        let canonical = try canonicalReadROI(crop).image
        let luma = try imageLuma(canonical)
        guard let minimum = luma.min(),
              let headerBackground = try indexedHeaderBackground(canonical) else {
            throw NativeFailure("CHAT_SELECTION_UNVERIFIED", "header ink 不可用")
        }
        let threshold = min(64, Int(minimum) + 16)
        let ink = luma.indices.filter { Int(luma[$0]) <= threshold }
        guard !ink.isEmpty else { throw NativeFailure("CHAT_SELECTION_UNVERIFIED", "header 無名字 ink") }
        let xs = ink.map { $0 % canonical.width }, ys = ink.map { $0 / canonical.width }
        let actual = CGRect(x: xs.min()!, y: ys.min()!,
                            width: xs.max()! - xs.min()! + 1,
                            height: ys.max()! - ys.min()! + 1)
        let padded = actual.insetBy(dx: -4, dy: -4)
            .intersection(CGRect(x: 0, y: 0, width: canonical.width, height: canonical.height)).integral
        guard actual.minX > 0, actual.maxX < CGFloat(canonical.width - 1),
              actual.minY > 0, actual.maxY < CGFloat(canonical.height - 1),
              let nameCropRect = indexedTopDownCropRect(
                padded, width: canonical.width, height: canonical.height
              ), let nameCrop = canonical.cropping(to: nameCropRect),
              let candidate = indexedExactNameCandidate(
                try visionCandidates(nameCrop), expected: chatName,
                imageWidth: nameCrop.width, imageHeight: nameCrop.height
              ) else {
            throw NativeFailure("CHAT_SELECTION_UNVERIFIED", "完整 header 名稱不唯一")
        }
        let actualInCrop = CGRect(x: actual.minX - padded.minX,
                                  y: actual.minY - padded.minY,
                                  width: actual.width, height: actual.height)
        let actualNormalized = CGRect(x: actualInCrop.minX / padded.width,
                                      y: 1 - actualInCrop.maxY / padded.height,
                                      width: actualInCrop.width / padded.width,
                                      height: actualInCrop.height / padded.height)
        guard actualGlyphCoverageAllowed(actual: actualNormalized,
                                         coarse: candidate.normalizedBox,
                                         imageWidth: nameCrop.width,
                                         imageHeight: nameCrop.height) else {
            throw NativeFailure("CHAT_SELECTION_UNVERIFIED", "header 全名字 ink ownership 不符")
        }
        var auxiliaryMask = [Bool](repeating: false, count: luma.count)
        for index in luma.indices {
            let x = index % canonical.width, y = index / canonical.width
            if !padded.contains(CGPoint(x: x, y: y)),
               Int(luma[index]) > threshold, Int(luma[index]) <= headerBackground - 12 {
                auxiliaryMask[index] = true
            }
        }
        let (originalRaw, originalBytesPerRow) = try rgbaBottomUp(crop)
        let originalPixels = topDownRows(originalRaw, bytesPerRow: originalBytesPerRow,
                                         height: crop.height)
        guard indexedHeaderAuxiliaryDomainsValid(
            mask: auxiliaryMask, luma: luma, originalPixels: originalPixels,
            bytesPerRow: originalBytesPerRow, width: canonical.width,
            height: canonical.height, nameActual: actual,
            nameDarkest: Int(minimum), background: headerBackground,
            scaleX: geometry.scaleX, scaleY: geometry.scaleY
        ) else {
            throw NativeFailure("CHAT_SELECTION_UNVERIFIED", "header 灰色 auxiliary domain 不可靠")
        }
        return (identity, candidate)
    }
    let first = try capture(); Thread.sleep(forTimeInterval: 0.06); let second = try capture()
    guard sameWindow(first.0, second.0),
          intersectionOverUnion(first.1.normalizedBox, second.1.normalizedBox) >= 0.80 else {
        throw NativeFailure("CHAT_SELECTION_UNVERIFIED", "完整 header 兩次證據漂移")
    }
    return second.0
}

func verifiedGlobalSelection(_ args: HistoryArguments,
                             expected: WindowIdentity) throws -> WindowIdentity {
    _ = try verifyGlobalAllSelected(expected: expected)
    let first = try readGlobalSearchModel(expected: expected, query: args.chatName)
    Thread.sleep(forTimeInterval: 0.06)
    let second = try readGlobalSearchModel(expected: expected, query: args.chatName)
    guard globalAXModelsStable(first, second) else {
        throw globalSearchFailure("global 搜尋結果二讀模型漂移")
    }
    let matches = second.rows.filter { $0.name == args.chatName }
    guard matches.count == 1, matches[0].selected,
          second.rows.filter(\.selected).count == 1 else {
        throw NativeFailure("CHAT_SELECTION_UNVERIFIED",
                            "global 搜尋結果未唯一 selected exact 目標",
                            ["count": matches.count])
    }
    let header = try verifyGlobalHeader(args.chatName, expected: second.identity)
    guard sameWindow(expected, header) else {
        throw NativeFailure("WINDOW_CHANGED", "global selected row 與 header 視窗不一致")
    }
    return header
}

func indexedChatRunCount(listFrame: CGRect, rowFrames: [CGRect]) -> Int {
    guard let first = rowFrames.first,
          (30...38).contains(first.minY - listFrame.minY),
          (68...74).contains(first.height) else { return 0 }
    var count = 1
    while count < rowFrames.count {
        let previous = rowFrames[count - 1]
        let current = rowFrames[count]
        guard (68...74).contains(current.height),
              (69...73).contains(current.minY - previous.minY) else { break }
        count += 1
    }
    return count
}

func indexedUIVersionAllowed(version: String?, build: String?) -> Bool {
    version == "26.4.2" && build == "3955"
}

func requireIndexedUIVersion() throws {
    let app = try lineApplication()
    let info = app.bundleURL.flatMap { Bundle(url: $0)?.infoDictionary }
    guard indexedUIVersionAllowed(version: info?["CFBundleShortVersionString"] as? String,
                                  build: info?["CFBundleVersion"] as? String) else {
        throw NativeFailure("INDEXED_UI_PROFILE_UNAVAILABLE", "LINE indexed UI profile 版本不符")
    }
}

func indexedAXChatRunCount(_ model: GlobalAXSearchModel) -> Int {
    indexedChatRunCount(listFrame: model.listFrame, rowFrames: model.rows.map(\.frame))
}

func indexedAXFailureAllowsOCRFallback(code: String, phase: String?) -> Bool {
    phase == nil && ["GLOBAL_SEARCH_RESULTS_UNVERIFIED",
                     "INDEXED_SEARCH_RESULT_UNAVAILABLE"].contains(code)
}

func indexedSelectionOutcomeUnknown(_ cause: Error, counts: GlobalAllEventCounts,
                                    axPressAttempts: Int = 0) -> NativeFailure {
    let causeCode = (cause as? NativeFailure)?.code ?? "UNKNOWN"
    return NativeFailure("INDEXED_SELECTION_OUTCOME_UNKNOWN",
                         "指定搜尋結果輸入後結果不明，不可重試",
                         ["phase": "post_input", "inputAttempted": true,
                          "eventCounts": counts.json,
                          "axPressAttempts": axPressAttempts,
                          "causeCode": causeCode])
}

func proveIndexedGlobalHistoryScopeAX(_ args: HistoryArguments,
                                      resultIndex: Int) throws -> HistoryScopeProof {
    let identity = try verifyGlobalAllForRead(expectedWindow: nil)
    _ = try setIndexedSearchValue(args.chatName, resultIndex: resultIndex,
                                  expected: identity)
    let first = try readGlobalSearchModel(expected: identity, query: args.chatName)
    Thread.sleep(forTimeInterval: 0.06)
    let second = try readGlobalSearchModel(expected: identity, query: args.chatName)
    guard globalAXModelsStable(first, second), resultIndex <= indexedAXChatRunCount(second),
          second.rows.indices.contains(resultIndex - 1),
          second.rows[resultIndex - 1].name == args.chatName else {
        throw NativeFailure("INDEXED_SEARCH_RESULT_UNAVAILABLE",
                            "指定搜尋結果 AX row 不可用或名稱不符")
    }
    _ = try verifyGlobalAllSelected(expected: identity)
    let final = try readGlobalSearchModel(expected: identity, query: args.chatName)
    guard globalAXModelsStable(second, final), resultIndex <= indexedAXChatRunCount(final),
          final.rows.indices.contains(resultIndex - 1),
          final.rows[resultIndex - 1].name == args.chatName else {
        throw NativeFailure("INDEXED_SEARCH_RESULT_DRIFT", "指定搜尋結果在選取前漂移")
    }
    let target = final.rows[resultIndex - 1]
    if !target.selected {
        do {
            try perform(kAXPressAction, on: target.element)
            Thread.sleep(forTimeInterval: 0.3)
            let header = try verifyGlobalHeader(args.chatName, expected: identity)
            let digest = historyMAC(args.identityKey,
                                    ["purpose": "line-indexed-global-history-header-v1",
                                     "scope": historyScopeBinding(args), "window": header.json])
            return HistoryScopeProof(identity: header, headerDigest: digest)
        } catch {
            throw indexedSelectionOutcomeUnknown(error, counts: GlobalAllEventCounts(),
                                                 axPressAttempts: 1)
        }
    }
    let header = try verifyGlobalHeader(args.chatName, expected: identity)
    let digest = historyMAC(args.identityKey,
                            ["purpose": "line-indexed-global-history-header-v1",
                             "scope": historyScopeBinding(args), "window": header.json])
    return HistoryScopeProof(identity: header, headerDigest: digest)
}

func proveIndexedGlobalHistoryScopeOCR(_ args: HistoryArguments,
                                       resultIndex: Int) throws -> HistoryScopeProof {
    let identity = try verifyGlobalAllForRead(expectedWindow: nil)
    _ = try setIndexedSearchValue(args.chatName, resultIndex: resultIndex,
                                  expected: identity)
    let target = try stableIndexedSearchTarget(chatName: args.chatName,
                                               resultIndex: resultIndex, expected: identity)
    let point = CGPoint(x: target.labelFrame.midX, y: target.labelFrame.midY)
    let events = try buildGlobalAllMouseEvents(point: point,
                                               eventNumber: Int64.random(in: 1...Int64(Int16.max)))
    let counts: GlobalAllEventCounts
    do {
        counts = try runGlobalAllMouseCore(pid: identity.pid, guardFresh: { step in
            let current = try strictGlobalAllWindow(expected: identity.json,
                                                    requireInputReady: step == .move)
            try verifyIndexedPointScene(expected: current, point: point,
                                        targetROI: target.rowFrame)
            if step != .up {
                let (_, _, _, query) = try freshSearchField(expected: current)
                guard query == args.chatName else {
                    throw NativeFailure("SEARCH_QUERY_CHANGED", "指定搜尋結果點擊前 query 漂移")
                }
            }
        }, post: { step, _ in events.event(step).post(tap: .cghidEventTap) })
    } catch let failure as GlobalAllCoreFailure {
        if failure.counts.inputAttempted {
            throw indexedSelectionOutcomeUnknown(failure.cause, counts: failure.counts)
        }
        throw failure.cause
    }
    Thread.sleep(forTimeInterval: 0.3)
    let header: WindowIdentity
    do { header = try verifyIndexedHeader(args.chatName, expected: identity) }
    catch { throw indexedSelectionOutcomeUnknown(error, counts: counts) }
    let digest = historyMAC(args.identityKey,
                            ["purpose": "line-indexed-global-history-header-v1",
                             "scope": historyScopeBinding(args), "window": header.json])
    return HistoryScopeProof(identity: header, headerDigest: digest)
}

func proveIndexedGlobalHistoryScope(_ args: HistoryArguments,
                                    resultIndex: Int) throws -> HistoryScopeProof {
    try requireIndexedUIVersion()
    do { return try proveIndexedGlobalHistoryScopeAX(args, resultIndex: resultIndex) }
    catch let failure as NativeFailure where indexedAXFailureAllowsOCRFallback(
        code: failure.code, phase: failure.details["phase"] as? String
    ) {
        // AX model 在任何 row action 前不可用時，才進入明確序位的 calibrated OCR profile。
        return try proveIndexedGlobalHistoryScopeOCR(args, resultIndex: resultIndex)
    }
}

func proveGlobalHistoryScope(_ args: HistoryArguments) throws -> HistoryScopeProof {
    if let resultIndex = args.resultIndex {
        return try proveIndexedGlobalHistoryScope(args, resultIndex: resultIndex)
    }
    // All 導航只能由有 durable journal 的獨立 selector 執行；reader 僅驗目前狀態。
    let identity = try verifyGlobalAllForRead(expectedWindow: args.state?.expectedWindow)
    _ = try setSearchValue(args.chatName, expected: identity)
    // 搜尋欄 exact 回讀不是 backend 證據；完整 AXRows 模型二讀穩定後才可能按壓。
    let first = try readGlobalSearchModel(expected: identity, query: args.chatName)
    Thread.sleep(forTimeInterval: 0.06)
    let second = try readGlobalSearchModel(expected: identity, query: args.chatName)
    guard globalAXModelsStable(first, second) else {
        throw globalSearchFailure("global 搜尋結果二讀模型漂移")
    }
    _ = try verifyGlobalAllSelected(expected: identity)
    let final = try readGlobalSearchModel(expected: identity, query: args.chatName)
    guard globalAXModelsStable(second, final) else {
        throw globalSearchFailure("global 搜尋結果在按壓前漂移")
    }
    let secondProof = globalSearchProof(second)
    let finalProof = globalSearchProof(final, reference: second.rows)
    guard let targetToken = globalPressTarget(
        previous: secondProof, final: finalProof, chatName: args.chatName,
        listFrame: final.listFrame, windowFrame: final.identity.bounds
    ), final.rows.indices.contains(targetToken) else {
        throw globalSearchFailure("global 搜尋結果無法唯一且可按壓地證明 exact 聊天室",
                                  ["count": final.rows.filter { $0.name == args.chatName }.count])
    }
    let target = final.rows[targetToken]
    if !target.selected {
        do {
            // 只對最後 fresh 模型的 element 執行一次；禁止使用第一讀保存的 handle。
            try perform(kAXPressAction, on: target.element)
        } catch {
            throw NativeFailure("GLOBAL_SELECTION_OUTCOME_UNKNOWN",
                                "global AXPress 結果不明，停止且不重試",
                                ["phase": "post_commit"])
        }
        Thread.sleep(forTimeInterval: 0.3)
    }
    let selectedIdentity: WindowIdentity
    do {
        selectedIdentity = try verifiedGlobalSelection(args, expected: identity)
    } catch let failure as NativeFailure {
        if target.selected { throw failure }
        throw NativeFailure("GLOBAL_SELECTION_OUTCOME_UNKNOWN",
                            "global AXPress 後 selected/header 證據不完整，停止且不重試",
                            ["phase": "post_commit", "cause": failure.code])
    }
    let digest = historyMAC(args.identityKey,
                            ["purpose": "line-global-history-header-v1",
                             "scope": historyScopeBinding(args),
                             "window": selectedIdentity.json])
    if let expected = args.state?.headerDigest, expected != digest {
        throw NativeFailure("HISTORY_STATE_DRIFT", "global header 證據已漂移")
    }
    return HistoryScopeProof(identity: selectedIdentity, headerDigest: digest)
}

struct IndexedViewportCapture {
    let identity: WindowIdentity
    let top: Int
    let bottom: Int
    let profile: String
    let bodyROI: CGRect
    let scale: CGFloat
    let gutterDigest: String
    let stripDigest: String
    let texts: [String]
}

func indexedPixel(_ pixels: [UInt8], bytesPerRow: Int, x: Int, y: Int)
    -> (luma: Int, opaque: Bool, monochrome: Bool) {
    let offset = y * bytesPerRow + x * 4
    let channels = [Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2])]
    return ((channels[0] + channels[1] + channels[2]) / 3,
            pixels[offset + 3] == 255,
            channels.max()! - channels.min()! <= 12)
}

func indexedGutterProjection(left: [UInt8], leftWidth: Int, leftBytesPerRow: Int,
                             right: [UInt8], rightWidth: Int, rightBytesPerRow: Int,
                             height: Int) -> (pixels: [UInt8], width: Int, bytesPerRow: Int)? {
    let width = 12, bytesPerRow = width * 4
    guard height > 0, leftWidth > 0, rightWidth > 0,
          leftBytesPerRow >= leftWidth * 4, rightBytesPerRow >= rightWidth * 4,
          left.count == leftBytesPerRow * height,
          right.count == rightBytesPerRow * height else { return nil }
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
    for y in 0..<height {
        let leftOffset = y * leftBytesPerRow, rightOffset = y * rightBytesPerRow
        for gutter in [(left, leftWidth, leftOffset), (right, rightWidth, rightOffset)] {
            let referenceChannels = [Int(gutter.0[gutter.2]), Int(gutter.0[gutter.2 + 1]),
                                     Int(gutter.0[gutter.2 + 2])]
            let referenceLuma = (referenceChannels[0] + referenceChannels[1] +
                                 referenceChannels[2]) / 3
            guard gutter.0[gutter.2 + 3] == 255,
                  referenceChannels.max()! - referenceChannels.min()! <= 12 else { return nil }
            for x in 1..<gutter.1 {
                let offset = gutter.2 + x * 4
                let channels = [Int(gutter.0[offset]), Int(gutter.0[offset + 1]),
                                Int(gutter.0[offset + 2])]
                let luma = (channels[0] + channels[1] + channels[2]) / 3
                guard gutter.0[offset + 3] == 255, channels.max()! - channels.min()! <= 12,
                      abs(luma - referenceLuma) <= 2 else { return nil }
            }
        }
        for x in 0..<width {
            // 兩個 probe 固定落在 parser 使用的 x=2／x=8，其餘像素只填滿合成列。
            let source = x < 6 ? (left, leftOffset) : (right, rightOffset)
            for channel in 0..<4 {
                pixels[y * bytesPerRow + x * 4 + channel] = source.0[source.1 + channel]
            }
        }
    }
    return (pixels, width, bytesPerRow)
}

func indexedViewportBounds(pixels: [UInt8], width: Int, height: Int,
                           bytesPerRow: Int, scanStart: Int, scale: CGFloat = 1)
    -> (top: Int, bottom: Int, separatorHeight: Int)? {
    guard width >= 12, height >= 80, bytesPerRow == width * 4,
          scale.isFinite, scale >= 0.5, scale <= 4,
          pixels.count == bytesPerRow * height else { return nil }
    let leftX = 2, rightX = width - 4
    var compatibleRows: [(row: Int, luma: Int)] = []
    for y in max(1, scanStart)..<(height - 1) {
        let left = indexedPixel(pixels, bytesPerRow: bytesPerRow, x: leftX, y: y)
        let right = indexedPixel(pixels, bytesPerRow: bytesPerRow, x: rightX, y: y)
        guard left.opaque, right.opaque, left.monochrome, right.monochrome,
              abs(left.luma - right.luma) <= 2 else { continue }
        compatibleRows.append((y, left.luma))
    }
    var runs: [ClosedRange<Int>] = []
    var runLumas: [Int] = []
    for candidate in compatibleRows {
        if let last = runs.last, let lastLuma = runLumas.last,
           candidate.row == last.upperBound + 1,
           abs(candidate.luma - lastLuma) <= 2 {
            runs[runs.count - 1] = last.lowerBound...candidate.row
            runLumas[runs.count - 1] = candidate.luma
        } else {
            runs.append(candidate.row...candidate.row)
            runLumas.append(candidate.luma)
        }
    }
    let minimumLine = max(1, Int(ceil(scale))), maximumLine = max(minimumLine, Int(ceil(3 * scale)))
    let backgroundDepth = max(1, Int(ceil(8 * scale)))
    let validRuns = runs.filter { run in
        guard (minimumLine...maximumLine).contains(run.count),
              run.lowerBound >= backgroundDepth,
              run.upperBound + backgroundDepth < height else { return false }
        let before = (run.lowerBound - backgroundDepth..<run.lowerBound).flatMap { row in
            [leftX, rightX].map { indexedPixel(pixels, bytesPerRow: bytesPerRow,
                                              x: $0, y: row).luma }
        }
        let after = (run.upperBound + 1...run.upperBound + backgroundDepth).flatMap { row in
            [leftX, rightX].map { indexedPixel(pixels, bytesPerRow: bytesPerRow,
                                              x: $0, y: row).luma }
        }
        guard let base = before.first,
              before.allSatisfy({ abs($0 - base) <= 2 }),
              after.allSatisfy({ abs($0 - base) <= 2 }) else { return false }
        let separator = indexedPixel(pixels, bytesPerRow: bytesPerRow,
                                     x: leftX, y: run.lowerBound).luma
        return abs(separator - base) >= 8
    }
    guard validRuns.count == 1, let divider = validRuns.first else { return nil }
    let background = indexedPixel(pixels, bytesPerRow: bytesPerRow,
                                  x: leftX, y: divider.lowerBound - 1).luma
    let stableDepth = max(1, Int(ceil(16 * scale)))
    var top: Int?
    for y in max(scanStart, 0)...max(scanStart, divider.lowerBound - stableDepth) {
        let stable = (y..<y + stableDepth).allSatisfy { row in
            [leftX, rightX].allSatisfy { x in
                let pixel = indexedPixel(pixels, bytesPerRow: bytesPerRow, x: x, y: row)
                return pixel.opaque && pixel.monochrome && abs(pixel.luma - background) <= 2
            }
        }
        if stable { top = y; break }
    }
    guard let top, divider.lowerBound - top >= stableDepth else { return nil }
    return (top, divider.lowerBound, divider.count)
}

func indexedBodyGlobalROI(scanOriginY: CGFloat, topPixels: Int, bottomPixels: Int,
                          scale: CGFloat, minX: CGFloat, maxX: CGFloat) -> CGRect? {
    guard scale.isFinite, scale >= 0.5, scale <= 4,
          topPixels >= 0, bottomPixels > topPixels, maxX > minX + 4 else { return nil }
    let roi = CGRect(x: minX + 2, y: scanOriginY + CGFloat(topPixels) / scale + 2,
                     width: maxX - minX - 4,
                     height: CGFloat(bottomPixels - topPixels) / scale - 4)
    return roi.height >= 16 ? roi : nil
}

func captureIndexedViewport(expected: WindowIdentity, readText: Bool) throws
    -> IndexedViewportCapture {
    let (_, _, window, identity) = try mainWindow(requireForeground: true)
    guard sameWindow(expected, identity) else { throw NativeFailure("WINDOW_CHANGED", "viewport 視窗漂移") }
    let tree = snapshot(window, mode: .geometryOnly)
    let layout = try readTabLayout(tree, window: identity)
    let leftFrame = tree.nodes[layout.leftListIndex].frame!
    let scanY = layout.tabROI.maxY + 50
    let scanHeight = identity.bounds.maxY - scanY - 44
    let leftROI = CGRect(x: leftFrame.maxX + 2, y: scanY, width: 2, height: scanHeight)
    let rightROI = CGRect(x: identity.bounds.maxX - 4, y: scanY, width: 2, height: scanHeight)
    guard identity.bounds.contains(leftROI), identity.bounds.contains(rightROI) else {
        throw NativeFailure("VISIBLE_VIEWPORT_LAYOUT_UNVERIFIED", "viewport gutters 不在主窗")
    }
    func captureGutter(_ roi: CGRect) throws -> (bytes: [UInt8], width: Int, height: Int,
                                                  bytesPerRow: Int, scale: CGFloat) {
        let image = try captureWindowImage(identity, roi: roi, opaqueForRead: true)
        let geometry = CaptureGeometry(window: identity.bounds, roi: roi,
                                       imageWidth: image.width, imageHeight: image.height)
        guard let crop = image.cropping(to: try geometry.roiPixels()) else {
            throw NativeFailure("VISIBLE_VIEWPORT_LAYOUT_UNVERIFIED", "無法裁切 viewport gutter")
        }
        let (bottomUp, bytesPerRow) = try rgbaBottomUp(crop)
        return (topDownRows(bottomUp, bytesPerRow: bytesPerRow, height: crop.height),
                crop.width, crop.height, bytesPerRow, geometry.scaleX)
    }
    let left = try captureGutter(leftROI), right = try captureGutter(rightROI)
    guard left.height == right.height, exactDisplayScale(left.scale, right.scale),
          left.width >= 1, right.width >= 1 else {
        throw NativeFailure("VISIBLE_VIEWPORT_LAYOUT_UNVERIFIED", "viewport gutter scale/size 漂移")
    }
    guard let projection = indexedGutterProjection(
        left: left.bytes, leftWidth: left.width, leftBytesPerRow: left.bytesPerRow,
        right: right.bytes, rightWidth: right.width, rightBytesPerRow: right.bytesPerRow,
        height: left.height
    ), let bounds = indexedViewportBounds(pixels: projection.pixels, width: projection.width,
                                             height: left.height,
                                             bytesPerRow: projection.bytesPerRow,
                                             scanStart: 0, scale: left.scale) else {
        throw NativeFailure("VISIBLE_VIEWPORT_LAYOUT_UNVERIFIED", "viewport gutter divider/top 無法唯一驗證")
    }
    let stripROI = CGRect(x: leftFrame.maxX + 2,
                          y: scanY + CGFloat(bounds.bottom) / left.scale,
                          width: identity.bounds.maxX - leftFrame.maxX - 6,
                          height: CGFloat(bounds.separatorHeight) / left.scale)
    let stripImage = try captureWindowImage(identity, roi: stripROI, opaqueForRead: true)
    let stripGeometry = CaptureGeometry(window: identity.bounds, roi: stripROI,
                                        imageWidth: stripImage.width, imageHeight: stripImage.height)
    guard exactDisplayScale(left.scale, stripGeometry.scaleX),
          let strip = stripImage.cropping(to: try stripGeometry.roiPixels()) else {
        throw NativeFailure("VISIBLE_VIEWPORT_LAYOUT_UNVERIFIED", "viewport separator strip 漂移")
    }
    let (stripBottomUp, stripBytesPerRow) = try rgbaBottomUp(strip)
    let stripPixels = topDownRows(stripBottomUp, bytesPerRow: stripBytesPerRow,
                                  height: strip.height)
    let expectedSeparator = indexedPixel(projection.pixels, bytesPerRow: projection.bytesPerRow,
                                         x: 2, y: bounds.bottom).luma
    for y in 0..<strip.height { for x in 0..<strip.width {
        let pixel = indexedPixel(stripPixels, bytesPerRow: stripBytesPerRow, x: x, y: y)
        guard pixel.opaque, pixel.monochrome, abs(pixel.luma - expectedSeparator) <= 2 else {
            throw NativeFailure("VISIBLE_VIEWPORT_LAYOUT_UNVERIFIED", "full-width separator proof 不符")
        }
    } }
    guard let bodyROI = indexedBodyGlobalROI(
        scanOriginY: scanY, topPixels: bounds.top, bottomPixels: bounds.bottom,
        scale: left.scale, minX: leftFrame.maxX, maxX: identity.bounds.maxX - 2
    ), identity.bounds.contains(bodyROI) else {
        throw NativeFailure("VISIBLE_VIEWPORT_LAYOUT_UNVERIFIED", "message body global ROI 不合理")
    }
    let backgroundLuma = indexedPixel(projection.pixels, bytesPerRow: projection.bytesPerRow,
                                      x: 2, y: max(bounds.top, bounds.bottom - 1)).luma
    let profile: String
    if backgroundLuma <= 80 { profile = "dark" }
    else if backgroundLuma >= 180 { profile = "light" }
    else { throw NativeFailure("VISIBLE_VIEWPORT_LAYOUT_UNVERIFIED", "viewport profile 未知") }
    var texts: [String] = []
    if readText {
        let bodyImage = try captureWindowImage(identity, roi: bodyROI, opaqueForRead: true)
        let bodyGeometry = CaptureGeometry(window: identity.bounds, roi: bodyROI,
                                           imageWidth: bodyImage.width, imageHeight: bodyImage.height)
        guard exactDisplayScale(left.scale, bodyGeometry.scaleX),
              let body = bodyImage.cropping(to: try bodyGeometry.roiPixels()) else {
            throw NativeFailure("VISIBLE_VIEWPORT_LAYOUT_UNVERIFIED", "body source ROI 漂移")
        }
        // Body文字不是身分證據；保留原row OCR的top1文字，不套名字.95門檻。
        texts = try visionCandidates(try canonicalReadROI(body).image)
            .map(\.text).filter { !$0.isEmpty }
    }
    let gutterDigest = SHA256.hash(data: Data(left.bytes + right.bytes)).map {
        String(format: "%02x", $0)
    }.joined()
    let stripDigest = SHA256.hash(data: Data(stripPixels)).map { String(format: "%02x", $0) }.joined()
    return IndexedViewportCapture(identity: identity, top: bounds.top,
                                  bottom: bounds.bottom, profile: profile,
                                  bodyROI: bodyROI, scale: left.scale,
                                  gutterDigest: gutterDigest, stripDigest: stripDigest,
                                  texts: texts)
}

func indexedViewportHistoryResult(_ args: HistoryArguments,
                                  proof: HistoryScopeProof) throws -> [String: Any] {
    _ = try verifyIndexedHeader(args.chatName, expected: proof.identity)
    let first = try captureIndexedViewport(expected: proof.identity, readText: true)
    _ = try verifyIndexedHeader(args.chatName, expected: proof.identity)
    let second = try captureIndexedViewport(expected: proof.identity, readText: false)
    guard sameWindow(first.identity, second.identity), first.top == second.top,
          first.bottom == second.bottom, first.profile == second.profile,
          first.bodyROI == second.bodyROI, exactDisplayScale(first.scale, second.scale),
          first.gutterDigest == second.gutterDigest,
          first.stripDigest == second.stripDigest else {
        throw NativeFailure("VISIBLE_VIEWPORT_LAYOUT_UNVERIFIED", "viewport 前後證據漂移")
    }
    var observations: [[String: Any]] = []
    var textUnits = 0
    for text in first.texts.prefix(args.limit) {
        let available = max(0, historyTextCodeUnitLimit - textUnits)
        guard available > 0 else { break }
        let bounded = utf16Prefix(text, maximum: available)
        // text_block 不可截斷 surrogate 或半個區塊；放不下就停止本頁。
        guard !bounded.1 else { break }
        textUnits += bounded.0.utf16.count
        observations.append([
            "observedId": try randomHistoryID(), "text": bounded.0,
            "date": NSNull(), "dateVerified": false, "unit": "text_block",
            "provenance": ["source": "VISIBLE_CHAT_VIEWPORT_OCR", "complete": false],
            "identityVerified": false,
        ])
    }
    let reasons = ["VISIBLE_VIEWPORT_ONLY", "DATE_CONTEXT_UNKNOWN",
                   "STABLE_MESSAGE_ID_UNAVAILABLE", "LATEST_BOUNDARY_UNVERIFIED"]
    let snapshot = historyMAC(args.identityKey,
                              ["purpose": "indexed-visible-viewport-v1",
                               "scope": historyScopeBinding(args), "header": proof.headerDigest,
                               "top": first.top, "bottom": first.bottom,
                               "texts": observations.map { $0["text"] as! String }])
    return historyEnvelope(args, observations: observations,
                           observedAt: ISO8601DateFormatter().string(from: Date()),
                           snapshotDigest: snapshot, nextState: nil, complete: false,
                           reasons: reasons, syncState: "unknown", truncated: false,
                           possibleDuplicates: true)
}

func proveHistoryScope(_ args: HistoryArguments) throws -> HistoryScopeProof {
    if args.mode == .global { return try proveGlobalHistoryScope(args) }
    let identity = try navigateTab(args.tabName, expectedWindow: args.state?.expectedWindow,
                                   mode: .readOnly)
    let selectedTab = try verifySelectedTab(args.tabName, mode: .readOnly)
    guard sameWindow(identity, selectedTab.0.identity) else {
        throw NativeFailure("WINDOW_CHANGED", "分頁 selected-state 驗證期間視窗已變更")
    }

    // 搜尋結果只作分頁成員 metadata 證據；成員、selected row、header 全部成立前不讀右側 body。
    _ = try setSearchValue(args.chatName, expected: identity)
    Thread.sleep(forTimeInterval: 0.25)
    let (memberTree, _, memberIdentity, rows) = try currentChatRows()
    guard sameWindow(identity, memberIdentity), !memberTree.partial else {
        throw NativeFailure("MEMBERSHIP_UNVERIFIED", "分頁成員清單不完整或視窗已變更")
    }
    let members = rows.filter { $0.1 == args.chatName }
    guard members.count == 1, let member = members.first else {
        throw NativeFailure(members.isEmpty ? "MEMBERSHIP_UNVERIFIED" : "AMBIGUOUS_MATCH",
                            "無法在 exact 分頁內唯一證明聊天室成員", ["count": members.count])
    }
    let (_, _, beforePress, _) = try currentChatRows()
    guard sameWindow(memberIdentity, beforePress) else {
        throw NativeFailure("WINDOW_CHANGED", "選取聊天室前視窗已變更")
    }
    try perform(kAXPressAction, on: member.0.element)
    Thread.sleep(forTimeInterval: 0.3)

    let (selectedTree, _, selectedIdentity, selectedRows) = try currentChatRows()
    let selectedMatches = selectedRows.filter { $0.1 == args.chatName && $0.0.selected == true }
    let selectedTabAgain = try verifySelectedTab(args.tabName, mode: .readOnly)
    let header = try verifyHeader(args.chatName)
    guard !selectedTree.partial,
          historyScopeAllowsBody(memberMatches: members.count, selectedMatches: selectedMatches.count,
                                 headerMatches: 1,
                                 windowMatches: sameWindow(identity, selectedIdentity) &&
                                     sameWindow(selectedIdentity, selectedTabAgain.0.identity) &&
                                     sameWindow(selectedIdentity, header)) else {
        throw NativeFailure("CHAT_SELECTION_UNVERIFIED", "selected row、分頁或 header 無法共同證明 exact scope")
    }
    let digest = historyMAC(args.identityKey,
                            ["purpose": "line-history-header-v1", "tabName": args.tabName,
                             "chatName": args.chatName, "window": selectedIdentity.json])
    if let expected = args.state?.headerDigest, expected != digest {
        throw NativeFailure("HISTORY_STATE_DRIFT", "header 證據已漂移")
    }
    return HistoryScopeProof(identity: selectedIdentity, headerDigest: digest)
}

func scrollBoundaryEvidence(value: Double, minimum: Double, maximum: Double) -> HistoryScrollBoundary? {
    guard value.isFinite, minimum.isFinite, maximum.isFinite, maximum >= minimum,
          value >= minimum - 0.0001, value <= maximum + 0.0001 else { return nil }
    let epsilon = max(0.0001, abs(maximum - minimum) * 0.001)
    return HistoryScrollBoundary(earliest: abs(value - minimum) <= epsilon,
                                 latest: abs(value - maximum) <= epsilon)
}

func messageScrollBoundary(_ list: AXUIElement) -> HistoryScrollBoundary? {
    guard let rawBar = copyAttribute(list, kAXVerticalScrollBarAttribute),
          CFGetTypeID(rawBar) == AXUIElementGetTypeID() else { return nil }
    let bar = rawBar as! AXUIElement
    guard let value = copyAttribute(bar, kAXValueAttribute) as? NSNumber,
          let minimum = copyAttribute(bar, kAXMinValueAttribute) as? NSNumber,
          let maximum = copyAttribute(bar, kAXMaxValueAttribute) as? NSNumber else { return nil }
    return scrollBoundaryEvidence(value: value.doubleValue, minimum: minimum.doubleValue,
                                  maximum: maximum.doubleValue)
}

func structuralHistoryRows(_ tree: Snapshot, listFrame: CGRect,
                           window: WindowIdentity) -> [NodeRecord] {
    tree.nodes.filter { node in
        guard node.role == kAXRowRole, let frame = node.frame else { return false }
        return visibleMessageRow(listFrame: listFrame, rowFrame: frame, window: window.bounds)
    }.reduce(into: [NodeRecord]()) { rows, row in
        if !rows.contains(where: { CFEqual($0.element, row.element) }) { rows.append(row) }
    }.sorted { ($0.frame?.minY ?? 0) < ($1.frame?.minY ?? 0) }
}

func historyAnchor(key: Data, tabName: String, chatName: String,
                   tree: Snapshot, listFrame: CGRect, window: WindowIdentity,
                   mode: HistoryMode = .tab) -> String {
    let rows = structuralHistoryRows(tree, listFrame: listFrame, window: window).map { row -> [String: Any] in
        let frame = row.frame!
        let identifier = stringAttribute(row.element, kAXIdentifierAttribute)
        return ["identifier": identifier.isEmpty ? NSNull() : historyMAC(
                    key, ["purpose": mode == .tab ? "line-history-anchor-row-v1" :
                            "line-global-history-anchor-row-v1",
                          "scope": mode == .tab ? [tabName, chatName] : [chatName],
                          "identifier": identifier]),
                "x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]
    }
    if mode == .tab {
        return historyMAC(key, ["purpose": "line-history-viewport-v1", "tabName": tabName,
                                "chatName": chatName,
                                "listFrame": [listFrame.minX, listFrame.minY, listFrame.width, listFrame.height],
                                "rows": rows])
    }
    return historyMAC(key, ["purpose": "line-global-history-viewport-v1",
                            "mode": mode.rawValue, "chatName": chatName,
                            "listFrame": [listFrame.minX, listFrame.minY,
                                          listFrame.width, listFrame.height],
                            "rows": rows])
}

func historyMessageContext(_ args: HistoryArguments, expected: WindowIdentity) throws -> HistoryMessageContext {
    let (_, _, window, identity) = try mainWindow(requireForeground: true)
    guard sameWindow(expected, identity) else { throw NativeFailure("WINDOW_CHANGED", "history viewport 視窗已變更") }
    let geometry = snapshot(window, mode: .geometryOnly)
    let layout = try lineLayout(geometry, window: identity)
    let list = geometry.nodes[layout.messageListIndex]
    guard let listFrame = list.frame else {
        throw NativeFailure("MESSAGE_CONTAINER_UNREADABLE", "訊息 AXList 缺少 frame")
    }
    let structure = snapshot(list.element, mode: .structure)
    let anchor = historyAnchor(key: args.identityKey, tabName: args.tabName,
                               chatName: args.chatName, tree: structure,
                               listFrame: listFrame, window: identity, mode: args.mode)
    return HistoryMessageContext(list: list.element, listFrame: listFrame, identity: identity,
                                 structure: structure, anchorHash: anchor,
                                 boundary: messageScrollBoundary(list.element))
}

func verifyHistoryScopeStillSelected(_ args: HistoryArguments, expected: WindowIdentity) throws {
    if args.mode == .global {
        _ = try verifiedGlobalSelection(args, expected: expected)
        return
    }
    let selectedTab = try verifySelectedTab(args.tabName, mode: .readOnly)
    let (tree, _, identity, rows) = try currentChatRows()
    let selected = rows.filter { $0.1 == args.chatName && $0.0.selected == true }
    let header = try verifyHeader(args.chatName)
    guard !tree.partial, selected.count == 1, sameWindow(expected, selectedTab.0.identity),
          sameWindow(expected, identity), sameWindow(expected, header) else {
        throw NativeFailure("HISTORY_STATE_DRIFT", "scroll 後 exact scope 證據已漂移")
    }
}

func scrollHistoryOnce(_ args: HistoryArguments, context: HistoryMessageContext) throws {
    guard AXUIElementSetAttributeValue(context.list, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success,
          boolAttribute(context.list, kAXFocusedAttribute) else {
        throw NativeFailure("SEMANTIC_UNRELIABLE", "無法安全聚焦已驗證 message AXList")
    }
    try verifyHistoryScopeStillSelected(args, expected: context.identity)
    try pairedKey(116) // 單次 PageUp；readHistoryPage 每次呼叫不會再送第二個歷史捲動事件。
    Thread.sleep(forTimeInterval: 0.08)
    try verifyHistoryScopeStillSelected(args, expected: context.identity)
}

func historySyncState(statusTexts: [String], partial: Bool) -> String {
    let normalized = statusTexts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    if normalized.contains(where: { ["同步中", "Syncing"].contains($0) }) { return "syncing" }
    if !partial && normalized.contains(where: { ["同步完成", "已同步", "Synced", "Up to date"].contains($0) }) {
        return "complete"
    }
    return "unknown"
}

func historyStatusTexts(_ tree: Snapshot, rows: [NodeRecord]) -> [String] {
    let rowIndices = rows.compactMap { row in tree.nodes.firstIndex(where: { CFEqual($0.element, row.element) }) }
    return tree.nodes.indices.filter { index in
        !rowIndices.contains(where: { index == $0 || isDescendant(index, of: $0, in: tree.nodes) })
    }.flatMap { tree.nodes[$0].texts }
}

func verifiedDateSeparator(role: String, outsideMessageRow: Bool, text: String) -> String? {
    guard role == kAXStaticTextRole, outsideMessageRow else { return nil }
    return verifiedGregorianDate(text.trimmingCharacters(in: .whitespacesAndNewlines))
}

func standaloneDateSeparators(_ tree: Snapshot, rows: [NodeRecord],
                              listFrame: CGRect) -> [(CGFloat, String)] {
    tree.nodes.indices.compactMap { index -> (CGFloat, String)? in
        let node = tree.nodes[index]
        guard node.role == kAXStaticTextRole, let frame = node.frame, listFrame.contains(frame),
              !rows.contains(where: { row in
                  guard let rowIndex = tree.nodes.firstIndex(where: { CFEqual($0.element, row.element) }) else { return false }
                  return index == rowIndex || isDescendant(index, of: rowIndex, in: tree.nodes)
              }),
              let date = verifiedDateSeparator(role: node.role, outsideMessageRow: true, text: node.value) else {
            return nil
        }
        return (frame.minY, date)
    }.sorted { $0.0 < $1.0 }
}

func fullAXText(_ element: AXUIElement, _ attribute: String) -> (String, Bool)? {
    guard let raw = copyAttribute(element, attribute) as? String else { return nil }
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }
    let bounded = utf16Prefix(value, maximum: historyTextCodeUnitLimit)
    return (bounded.0, !bounded.1)
}

func historyContentAnchor(_ args: HistoryArguments, context: HistoryMessageContext,
                          rows: [HistoryRowEvidence]) -> String {
    let evidence = rows.map { row -> [String: Any] in
        ["stableID": row.stableID ?? NSNull(),
         "textHMAC": historyMAC(args.identityKey,
                                 ["purpose": "line-history-anchor-text-v1", "text": row.text]),
         "date": row.date ?? NSNull(), "unit": row.unit, "source": row.source,
         "textTruncated": row.textTruncated,
         "x": row.frame.minX, "y": row.frame.minY,
         "width": row.frame.width, "height": row.frame.height]
    }
    if args.mode == .tab {
        return historyMAC(args.identityKey,
                          ["purpose": "line-history-content-viewport-v1", "tabName": args.tabName,
                           "chatName": args.chatName, "structure": context.anchorHash, "rows": evidence])
    }
    return historyMAC(args.identityKey,
                      ["purpose": "line-global-history-content-viewport-v1",
                       "scope": historyScopeBinding(args),
                       "structure": context.anchorHash, "rows": evidence])
}

func historyRows(_ args: HistoryArguments, context: HistoryMessageContext,
                 afterPhysicalScroll: Bool) throws -> HistoryReadResult {
    let tree = snapshot(context.list, mode: .text)
    let structureAfter = snapshot(context.list, mode: .structure)
    let anchorAfter = historyAnchor(key: args.identityKey, tabName: args.tabName,
                                    chatName: args.chatName, tree: structureAfter,
                                    listFrame: context.listFrame, window: context.identity,
                                    mode: args.mode)
    guard anchorAfter == context.anchorHash else {
        throw NativeFailure("HISTORY_STATE_DRIFT", "讀取 body 期間 viewport anchor 已漂移")
    }
    let rows = structuralHistoryRows(tree, listFrame: context.listFrame, window: context.identity)
    let separators = standaloneDateSeparators(tree, rows: rows, listFrame: context.listFrame)
    let rawIdentifiers = rows.map { stringAttribute($0.element, kAXIdentifierAttribute) }
    var identifierCounts: [String: Int] = [:]
    for identifier in rawIdentifiers where !identifier.isEmpty { identifierCounts[identifier, default: 0] += 1 }
    var possibleDuplicates = afterPhysicalScroll && rawIdentifiers.contains {
        $0.isEmpty || identifierCounts[$0, default: 0] != 1
    }
    var evidence: [HistoryRowEvidence] = []
    for (index, row) in rows.enumerated() {
        let frame = row.frame!
        let rawIdentifier = rawIdentifiers[index]
        let stableID = !rawIdentifier.isEmpty && identifierCounts[rawIdentifier] == 1
            ? historyObservedID(key: args.identityKey, tabName: args.tabName,
                                chatName: args.chatName, axIdentifier: rawIdentifier,
                                mode: args.mode) : nil
        if !rawIdentifier.isEmpty && identifierCounts[rawIdentifier, default: 0] > 1 { possibleDuplicates = true }
        let date = separators.last(where: { $0.0 <= frame.minY })?.1
        if let rowValue = fullAXText(row.element, kAXValueAttribute), !looksLikeTimeMetadata(rowValue.0) {
            evidence.append(HistoryRowEvidence(frame: frame, stableID: stableID, text: rowValue.0,
                                               date: date, unit: "message", source: "AX_ROW_VALUE",
                                               provenanceComplete: rowValue.1,
                                               textTruncated: !rowValue.1))
            continue
        }
        let rowIndex = tree.nodes.firstIndex(where: { CFEqual($0.element, row.element) })!
        let candidates = descendantIndices(of: rowIndex, in: tree.nodes).compactMap { childIndex -> (String, Bool)? in
            let child = tree.nodes[childIndex]
            guard child.role == kAXStaticTextRole, let childFrame = child.frame,
                  frame.contains(childFrame), context.listFrame.contains(childFrame),
                  let value = fullAXText(child.element, kAXValueAttribute),
                  !looksLikeTimeMetadata(value.0) else { return nil }
            return value
        }
        if candidates.count == 1, let candidate = candidates.first {
            evidence.append(HistoryRowEvidence(frame: frame, stableID: stableID, text: candidate.0,
                                               date: date, unit: "message", source: "AX_STATIC_TEXT",
                                               provenanceComplete: candidate.1,
                                               textTruncated: !candidate.1))
        } else {
            let blocks = try rowOCRBlocks(window: context.identity, rowFrame: frame).0
            let text = utf16Prefix(blocks.joined(separator: " "), maximum: historyTextCodeUnitLimit)
            evidence.append(HistoryRowEvidence(frame: frame, stableID: stableID, text: text.0,
                                               date: date, unit: "text_block",
                                               source: "VISIBLE_VERIFIED_ROW_OCR",
                                               provenanceComplete: false,
                                               textTruncated: text.1))
        }
    }
    return HistoryReadResult(tree: tree, rows: evidence, possibleDuplicates: possibleDuplicates,
                             contentAnchor: historyContentAnchor(args, context: context, rows: evidence))
}

func historyEnvelope(_ args: HistoryArguments,
                     observations: [[String: Any]], observedAt: String,
                     snapshotDigest: String, nextState: [String: Any]?,
                     complete: Bool, reasons: [String], syncState: String,
                     truncated: Bool, possibleDuplicates: Bool) -> [String: Any] {
    ["scope": historyResultScope(args), "observations": observations,
     "observedAt": observedAt, "snapshotDigest": snapshotDigest,
     "nextState": nextState ?? NSNull(), "complete": complete,
     "reasons": reasons, "syncState": syncState, "truncated": truncated,
     "possibleDuplicates": possibleDuplicates]
}

func terminalHistoryResult(_ args: HistoryArguments, proof: HistoryScopeProof,
                           context: HistoryMessageContext, reason: String) -> [String: Any] {
    let snapshotPayload: [String: Any]
    if args.mode == .tab {
        snapshotPayload = ["purpose": "line-history-snapshot-v1", "header": proof.headerDigest,
                           "anchor": context.anchorHash, "reason": reason]
    } else {
        snapshotPayload = ["purpose": "line-global-history-snapshot-v1",
                           "scope": historyScopeBinding(args), "header": proof.headerDigest,
                           "anchor": context.anchorHash, "reason": reason]
    }
    let snapshot = historyMAC(args.identityKey, snapshotPayload)
    return historyEnvelope(args, observations: [],
                           observedAt: ISO8601DateFormatter().string(from: Date()),
                           snapshotDigest: snapshot, nextState: nil, complete: false,
                           reasons: [reason], syncState: "unknown", truncated: false,
                           possibleDuplicates: false)
}

func readHistoryPage(_ rawArgs: [String: Any]) throws -> [String: Any] {
    try boundedHistoryPage(rawArgs, mode: .tab)
}

func readGlobalHistoryPage(_ rawArgs: [String: Any]) throws -> [String: Any] {
    try boundedHistoryPage(rawArgs, mode: .global)
}

func boundedHistoryPage(_ rawArgs: [String: Any], mode: HistoryMode) throws -> [String: Any] {
    let args = try parseHistoryArguments(rawArgs, mode: mode)
    let proof = try proveHistoryScope(args)
    if args.resultIndex != nil {
        return try indexedViewportHistoryResult(args, proof: proof)
    }
    var context = try historyMessageContext(args, expected: proof.identity)
    if args.state == nil && context.boundary?.latest != true {
        return terminalHistoryResult(args, proof: proof, context: context,
                                     reason: "LATEST_BOUNDARY_UNVERIFIED")
    }

    var didScroll = false
    var repeatedPage = false
    var pageNumber = args.state?.pageNumber ?? 0
    let read: HistoryReadResult
    if let state = args.state {
        // exact scope 已證後才讀內容；內容只進 HMAC anchor，不作 observedId 或去重。
        let currentRead = try historyRows(args, context: context, afterPhysicalScroll: false)
        guard currentRead.contentAnchor == state.anchorHash else {
            throw NativeFailure("HISTORY_STATE_DRIFT", "nativeState viewport 內容或結構已漂移")
        }
        if state.advance {
            guard context.boundary?.earliest != true, pageNumber < 1_000 else {
                throw NativeFailure("HISTORY_STATE_DRIFT", "cursor 要求前進但 viewport 已在最早端或超出頁數預算")
            }
            try scrollHistoryOnce(args, context: context)
            context = try historyMessageContext(args, expected: proof.identity)
            didScroll = true
            pageNumber += 1
            let advancedRead = try historyRows(args, context: context, afterPhysicalScroll: true)
            repeatedPage = historyScrollProgress(
                previousAnchor: state.anchorHash, currentAnchor: advancedRead.contentAnchor,
                actualEarliestBoundary: context.boundary?.earliest == true
            ) == .repeatedUnverified
            read = advancedRead
        } else {
            read = currentRead
        }
    } else {
        read = try historyRows(args, context: context, afterPhysicalScroll: false)
    }

    let bodyRows = structuralHistoryRows(read.tree, listFrame: context.listFrame, window: context.identity)
    let syncState = historySyncState(statusTexts: historyStatusTexts(read.tree, rows: bodyRows),
                                     partial: read.tree.partial)
    let seenBefore = args.state?.seenIds ?? []
    let seenBeforeSet = Set(seenBefore)
    let keepMask = historyOverlapMask(ids: read.rows.map(\.stableID), seenIds: seenBefore,
                                      afterPhysicalScroll: didScroll)
    let overlapUnverified = didScroll && zip(read.rows.map(\.stableID), keepMask).contains {
        $0.1 && $0.0.map(seenBeforeSet.contains) == true
    }
    let available = zip(read.rows, keepMask).compactMap { $0.1 ? $0.0 : nil }
    let offset = didScroll ? 0 : (args.state?.offset ?? 0)
    guard let slice = historyPageSlice(total: available.count, offset: offset,
                                       limit: args.limit,
                                       earliestBoundary: context.boundary?.earliest == true) else {
        throw NativeFailure("INVALID_NATIVE_STATE", "nativeState offset 超出目前已驗證 viewport")
    }

    var observations: [[String: Any]] = []
    var emittedStableIDs: [String] = []
    var textUnits = 0
    var truncated = false
    var processedEnd = slice.range.lowerBound
    var provenancePartial = false
    for index in slice.range {
        let row = available[index]
        let remaining = historyTextCodeUnitLimit - textUnits
        if remaining <= 0 { truncated = true; processedEnd = index; break }
        let bounded = utf16Prefix(row.text, maximum: remaining)
        if bounded.0.isEmpty { truncated = true; processedEnd = index + 1; break }
        let observedID: String
        let identityVerified: Bool
        if let stableID = row.stableID {
            observedID = stableID
            identityVerified = true
            emittedStableIDs.append(stableID)
        } else {
            observedID = try randomHistoryID()
            identityVerified = false
        }
        let provenanceComplete = row.provenanceComplete && !bounded.1 && !row.textTruncated
        provenancePartial = provenancePartial || !provenanceComplete
        observations.append(["observedId": observedID, "text": bounded.0,
                             "date": row.date ?? NSNull(), "dateVerified": row.date != nil,
                             "unit": row.unit,
                             "provenance": ["source": row.source, "complete": provenanceComplete],
                             "identityVerified": identityVerified])
        textUnits += bounded.0.utf16.count
        processedEnd = index + 1
        if bounded.1 || row.textTruncated { truncated = true; break }
    }

    var reasons: [String] = []
    if context.structure.partial { reasons.append("STRUCTURE_PARTIAL") }
    if read.tree.partial { reasons.append("MESSAGE_SNAPSHOT_PARTIAL") }
    if read.rows.isEmpty { reasons.append("NO_MESSAGE_ROWS_VERIFIED") }
    if syncState == "syncing" { reasons.append("SYNC_IN_PROGRESS") }
    if syncState == "unknown" { reasons.append("SYNC_STATE_UNKNOWN") }
    if truncated { reasons.append("TEXT_LIMIT") }
    if provenancePartial { reasons.append("BODY_PROVENANCE_PARTIAL") }
    if repeatedPage { reasons.append(contentsOf: ["REPEATED_PAGE", "SCROLL_PROGRESS_UNVERIFIED"]) }
    let hasUnknownDate = observations.contains { ($0["dateVerified"] as? Bool) != true }
    if hasUnknownDate { reasons.append("DATE_CONTEXT_UNKNOWN") }
    let possibleDuplicates = historyPossibleDuplicates(
        base: read.possibleDuplicates, overlapUnverified: overlapUnverified,
        emittedIdentityVerified: observations.compactMap { $0["identityVerified"] as? Bool }
    )
    if possibleDuplicates { reasons.append("OVERLAP_UNVERIFIED") }

    var seenIds = args.state?.seenIds ?? []
    var seenSet = Set(seenIds)
    for identifier in emittedStableIDs where seenSet.insert(identifier).inserted { seenIds.append(identifier) }
    var nextState: [String: Any]?
    let stillInViewport = processedEnd < available.count
    let stateUnsafe = historyContinuationUnsafe(structurePartial: context.structure.partial,
                                                messagePartial: read.tree.partial,
                                                hasRows: !read.rows.isEmpty,
                                                repeatedPage: repeatedPage)
    if seenIds.count > historySeenIDLimit {
        reasons.append("SEEN_ID_BUDGET_EXCEEDED")
    } else if stateUnsafe {
        // 不完整 AX tree 或未證明訊息列時，禁止發出可重播的 offset/scroll state。
    } else if stillInViewport {
        let date = available.first?.date.map { HistoryDateContext(date: $0, anchorHash: read.contentAnchor) }
        let candidate = HistoryNativeState(
            expectedWindow: context.identity.json, headerDigest: proof.headerDigest,
            anchorHash: read.contentAnchor, offset: processedEnd, pageNumber: pageNumber,
            advance: false, seenIds: seenIds, dateContext: date
        )
        nextState = boundedHistoryStateJSON(candidate)
        if nextState == nil { reasons.append("STATE_BUDGET_EXCEEDED") }
    } else if slice.advance {
        if pageNumber >= 1_000 {
            reasons.append("PAGE_BUDGET_EXCEEDED")
        } else {
            let date = available.first?.date.map { HistoryDateContext(date: $0, anchorHash: read.contentAnchor) }
            let candidate = HistoryNativeState(
                expectedWindow: context.identity.json, headerDigest: proof.headerDigest,
                anchorHash: read.contentAnchor, offset: 0, pageNumber: pageNumber,
                advance: true, seenIds: seenIds, dateContext: date
            )
            nextState = boundedHistoryStateJSON(candidate)
            if nextState == nil { reasons.append("STATE_BUDGET_EXCEEDED") }
        }
    }
    reasons = Array(Set(reasons)).sorted()
    if reasons.count > 32 { reasons = Array(reasons.prefix(31)) + ["REASON_LIMIT"] }
    if nextState == nil && !slice.terminal && reasons.isEmpty {
        reasons.append("HISTORY_TERMINAL_UNVERIFIED")
    }
    let complete = historyComplete(nextStateExists: nextState != nil, syncState: syncState,
                                   truncated: truncated, possibleDuplicates: possibleDuplicates,
                                   hasUnknownDate: hasUnknownDate, reasons: reasons)
    let snapshotPayload: [String: Any]
    if args.mode == .tab {
        snapshotPayload = ["purpose": "line-history-snapshot-v1", "header": proof.headerDigest,
                           "anchor": read.contentAnchor, "pageNumber": pageNumber,
                           "observationIds": observations.compactMap { $0["observedId"] }]
    } else {
        snapshotPayload = ["purpose": "line-global-history-snapshot-v1",
                           "scope": historyScopeBinding(args), "header": proof.headerDigest,
                           "anchor": read.contentAnchor, "pageNumber": pageNumber,
                           "observationIds": observations.compactMap { $0["observedId"] }]
    }
    let snapshotDigest = historyMAC(args.identityKey, snapshotPayload)
    return historyEnvelope(args, observations: observations,
                           observedAt: ISO8601DateFormatter().string(from: Date()),
                           snapshotDigest: snapshotDigest, nextState: nextState,
                           complete: complete, reasons: reasons, syncState: syncState,
                           truncated: truncated, possibleDuplicates: possibleDuplicates)
}

func freshComposer(expected: WindowIdentity) throws -> NodeRecord {
    let (_, _, window, identity) = try mainWindow(requireForeground: true)
    guard sameWindow(expected, identity) else { throw NativeFailure("WINDOW_CHANGED", "composer 流程中視窗已變更") }
    let geometry = snapshot(window, mode: .geometryOnly)
    let layout = try lineLayout(geometry, window: identity)
    let element = geometry.nodes[layout.composerIndex].element
    return NodeRecord(element: element, parent: nil, role: "AXTextArea", subrole: "",
                      title: "", description: "", value: stringAttribute(element, kAXValueAttribute),
                      frame: frameAttribute(element), enabled: boolAttribute(element, kAXEnabledAttribute, default: true),
                      selected: nil)
}

func pairedReturnKey() throws {
    guard let source = CGEventSource(stateID: .combinedSessionState),
          let down = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false) else {
        throw NativeFailure("KEY_EVENT_FAILED", "無法建立 Return 事件", ["phase": "pre_commit"])
    }
    // Return 必須是無修飾鍵；不能繼承前一步 Command-Shift-G 的事件狀態。
    down.flags = []; up.flags = []
    down.post(tap: .cghidEventTap)
    var released = false
    defer { if !released { up.post(tap: .cghidEventTap) } }
    up.post(tap: .cghidEventTap)
    released = true
}

func containsUnsupportedMention(_ message: String) -> Bool {
    message.range(of: #"(^|\s)@\S+"#, options: .regularExpression) != nil
}

func sendMessage(_ args: [String: Any]) throws -> [String: Any] {
    guard let chatName = args["chatName"] as? String,
          let message = args["message"] as? String, !message.isEmpty else {
        throw NativeFailure("INVALID_ARGUMENT", "缺少 chatName 或 message", ["phase": "pre_commit"])
    }
    if containsUnsupportedMention(message) {
        throw NativeFailure("UNSUPPORTED_MENTION", "native 草稿流程無法保留 LINE mention 語意", ["phase": "pre_commit"])
    }
    let autoSend = (args["autoSend"] as? NSNumber)?.boolValue ?? false
    let selected = try selectChat(chatName, tabName: args["tabName"] as? String)
    guard let rawWindow = selected["mainWindow"] as? [String: Any] else {
        throw NativeFailure("CHAT_SELECTION_UNVERIFIED", "缺少選取後視窗證據", ["phase": "pre_commit"])
    }
    let (_, _, _, identity) = try mainWindow(requireForeground: true)
    try validateExpectedWindow(rawWindow, current: identity)
    var composer = try freshComposer(expected: identity)
    guard composer.enabled,
          composer.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw NativeFailure("DRAFT_NOT_EMPTY", "訊息輸入區已有草稿，拒絕覆寫", ["phase": "pre_commit"])
    }
    let writeResult = AXUIElementSetAttributeValue(composer.element, kAXValueAttribute as CFString,
                                                   message as CFTypeRef)
    guard writeResult == .success else {
        // setter 已嘗試改變草稿，回傳失敗也不能證明 UI 完全未變。
        throw NativeFailure("AX_ACTION_FAILED", "無法確認訊息草稿寫入結果", ["phase": "post_commit"])
    }
    do {
        composer = try freshComposer(expected: identity)
        guard composer.value == message else {
            throw NativeFailure("DRAFT_READBACK_FAILED", "草稿 exact 回讀不一致")
        }
        if !autoSend {
            return ["success": true, "autoSent": false,
                    "receipt": ["status": "DRAFT_WRITTEN", "deliveryConfirmed": false,
                                "observedAt": ISO8601DateFormatter().string(from: Date())]]
        }
        _ = try verifyHeader(chatName)
        let (_, appElement, window, before) = try mainWindow(requireForeground: true)
        guard sameWindow(identity, before) else { throw NativeFailure("WINDOW_CHANGED", "送出前視窗已變更") }
        let geometry = snapshot(window, mode: .geometryOnly)
        let buttons = geometry.nodes.filter { node in
            guard node.role == "AXButton", node.enabled, let frame = node.frame,
                  frame.midX > before.bounds.midX, frame.minY > before.bounds.midY else { return false }
            let text = [stringAttribute(node.element, kAXTitleAttribute),
                        stringAttribute(node.element, kAXDescriptionAttribute),
                        stringAttribute(node.element, kAXValueAttribute)]
            return text.contains("傳送") || text.contains("Send")
        }
        if buttons.count == 1, let button = buttons.first {
            do { try perform(kAXPressAction, on: button.element) }
            catch { throw NativeFailure("SEND_UNCERTAIN", "UI 提交事件結果不明") }
        } else if buttons.isEmpty,
                  let focusedRaw = copyAttribute(appElement, kAXFocusedUIElementAttribute),
                  CFGetTypeID(focusedRaw) == AXUIElementGetTypeID(),
                  CFEqual(focusedRaw as! AXUIElement, composer.element) {
            do { try pairedReturnKey() }
            catch { throw NativeFailure("SEND_UNCERTAIN", "Return 提交事件結果不明") }
        } else {
            throw NativeFailure(buttons.count > 1 ? "AMBIGUOUS_MATCH" : "SEND_CONTROL_UNAVAILABLE",
                                "無法唯一辨識安全送出語意")
        }
        Thread.sleep(forTimeInterval: 0.2)
        composer = try freshComposer(expected: identity)
        guard composer.value.isEmpty else {
            throw NativeFailure("SEND_UNVERIFIED", "UI 提交後 composer 未清空")
        }
        return ["success": true, "autoSent": true,
                "receipt": ["status": "UI_SUBMITTED", "deliveryConfirmed": false,
                            "observedAt": ISO8601DateFormatter().string(from: Date())]]
    } catch let failure as NativeFailure {
        throw forcingPhase(failure, "post_commit")
    } catch {
        throw NativeFailure("SEND_UNCERTAIN", "草稿寫入後發生未預期錯誤", ["phase": "post_commit"])
    }
}

// 圖片僅走已校準的附件選擇器；不使用剪貼簿，也不自動搜尋或切換收件者。
func imageSendArgumentsValid(_ args: [String: Any]) -> Bool {
    guard Set(args.keys) == ["chatName", "imagePath", "imageSha256", "autoSend"],
          validName(args["chatName"]) != nil,
          let path = args["imagePath"] as? String, path.hasPrefix("/"), path.count <= 4096,
          path.range(of: #"\p{Cc}"#, options: .regularExpression) == nil,
          validHex(args["imageSha256"], count: 64) != nil,
          let autoSend = args["autoSend"] as? NSNumber,
          CFGetTypeID(autoSend) == CFBooleanGetTypeID() else { return false }
    return true
}

func imageSendDimensionsAllowed(_ width: Int, _ height: Int) -> Bool {
    width > 0 && height > 0 && width <= 8192 && height <= 8192 && width * height <= 16_000_000
}

func boundedAttachmentBytes(_ path: String, maximumBytes: Int, prefix: String) throws -> Data {
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else { throw NativeFailure(prefix + "_FILE_UNSAFE", "無法安全開啟附件") }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
          info.st_nlink == 1, info.st_size > 0, info.st_size <= maximumBytes else {
        throw NativeFailure(prefix + "_FILE_UNSAFE", "附件必須是一般單連結檔案，且未超過大小上限")
    }
    var result = Data(count: Int(info.st_size))
    let readCount = result.withUnsafeMutableBytes { buffer -> Int in
        var count = 0
        while count < buffer.count {
            let next = read(fd, buffer.baseAddress!.advanced(by: count), buffer.count - count)
            if next <= 0 { return -1 }
            count += next
        }
        return count
    }
    var extra: UInt8 = 0
    guard readCount == result.count, read(fd, &extra, 1) == 0 else {
        throw NativeFailure(prefix + "_FILE_CHANGED", "附件讀取期間已變更")
    }
    return result
}

func boundedImageBytes(_ path: String) throws -> Data {
    try boundedAttachmentBytes(path, maximumBytes: 20 * 1024 * 1024, prefix: "IMAGE")
}

struct ImageSendAsset {
    let directory: URL
    let file: URL
    let sourceDigest: String
    let digest: String
    let width: Int
    let height: Int
    var byteCount: Int = 0
}

func imageSendDigest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func stageImageSendAsset(path: String, expectedDigest: String) throws -> ImageSendAsset {
    let data = try boundedImageBytes(path)
    guard imageSendDigest(data) == expectedDigest else {
        throw NativeFailure("IMAGE_HASH_MISMATCH", "圖片與已核准 SHA256 不符")
    }
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          CGImageSourceGetCount(source) == 1,
          let type = CGImageSourceGetType(source) as String?,
          ["public.png", "public.jpeg"].contains(type),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
          let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
          let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
          imageSendDimensionsAllowed(width, height),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true,
          ] as CFDictionary), CGImageSourceGetStatus(source) == .statusComplete else {
        throw NativeFailure("IMAGE_INVALID", "只接受可解碼的單張 PNG/JPEG，最多 1600 萬像素")
    }
    // 從解碼後像素重建 PNG，保留方向並排除原圖 EXIF、定位與其他附加資料。
    let png = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil) else {
        throw NativeFailure("IMAGE_INVALID", "無法建立圖片快照")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NativeFailure("IMAGE_INVALID", "無法完成圖片快照")
    }
    let bytes = png as Data
    let digest = imageSendDigest(bytes)
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("line-mcp-image-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                           attributes: [.posixPermissions: 0o700])
    do {
        let file = directory.appendingPathComponent(digest + ".png")
        try bytes.write(to: file, options: .withoutOverwriting)
        guard chmod(file.path, 0o600) == 0 else { throw NativeFailure("IMAGE_FILE_UNSAFE", "無法保護圖片快照") }
        return ImageSendAsset(directory: directory, file: file, sourceDigest: expectedDigest,
                              digest: digest, width: image.width, height: image.height)
    } catch {
        try? FileManager.default.removeItem(at: directory)
        throw error
    }
}

// 一般檔案保留原始名稱與內容；目錄名稱綁定完整SHA，供選擇器交叉核對。
func stageFileSendAsset(path: String, expectedDigest: String) throws -> ImageSendAsset {
    let data = try boundedAttachmentBytes(path, maximumBytes: 100 * 1024 * 1024, prefix: "ATTACHMENT")
    guard imageSendDigest(data) == expectedDigest else {
        throw NativeFailure("FILE_HASH_MISMATCH", "檔案與指定SHA256不符")
    }
    let name = URL(fileURLWithPath: path).lastPathComponent.precomposedStringWithCanonicalMapping
    guard !name.isEmpty, ![".", ".."].contains(name),
          name.range(of: #"\p{Cc}|[\u{202A}-\u{202E}\u{2066}-\u{2069}]"#, options: .regularExpression) == nil else {
        throw NativeFailure("FILE_NAME_UNSAFE", "檔名含不支援字元")
    }
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("line-mcp-file-" + UUID().uuidString + "-" + expectedDigest, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                           attributes: [.posixPermissions: 0o700])
    do {
        let file = directory.appendingPathComponent(name)
        try data.write(to: file, options: .withoutOverwriting)
        guard chmod(file.path, 0o600) == 0 else { throw NativeFailure("ATTACHMENT_FILE_UNSAFE", "無法保護檔案快照") }
        return ImageSendAsset(directory: directory, file: file, sourceDigest: expectedDigest,
                              digest: expectedDigest, width: 0, height: 0, byteCount: data.count)
    } catch {
        try? FileManager.default.removeItem(at: directory)
        throw error
    }
}

func fileSendArgumentsValid(_ args: [String: Any]) -> Bool {
    guard Set(args.keys) == ["chatName", "filePath", "fileSha256"], validName(args["chatName"]) != nil,
          let path = args["filePath"] as? String, path.hasPrefix("/"), path.count <= 4096,
          path.range(of: #"\p{Cc}|[\u{202A}-\u{202E}\u{2066}-\u{2069}]"#, options: .regularExpression) == nil,
          validHex(args["fileSha256"], count: 64) != nil else { return false }
    return true
}

func fileInfoNameMatches(_ value: String, expected: String) -> Bool {
    value.components(separatedBy: "\n").first?.precomposedStringWithCanonicalMapping ==
        expected.precomposedStringWithCanonicalMapping
}

func imageSendComposer(expected: WindowIdentity) throws -> NodeRecord {
    let (_, _, window, current) = try mainWindow(requireForeground: true)
    guard sameWindow(current, expected) else { throw NativeFailure("WINDOW_CHANGED", "圖片輸入區視窗漂移") }
    let tree = snapshot(window, mode: .geometryOnly)
    let matches = tree.nodes.filter { node in
        guard node.role == kAXTextAreaRole, let frame = node.frame else { return false }
        return expected.bounds.contains(frame) && frame.midX > expected.bounds.midX &&
            frame.minY > expected.bounds.midY && frame.width > 250 && (50...200).contains(frame.height)
    }
    guard !tree.partial, matches.count == 1, let composer = matches.first, composer.enabled,
          let value = copyAttribute(composer.element, kAXValueAttribute) as? String, value.isEmpty else {
        throw NativeFailure("DRAFT_NOT_EMPTY", "無法證明圖片輸入區唯一且草稿完全空白")
    }
    return composer
}

func imageSendGoToEvents() throws -> (CGEvent, CGEvent) {
    guard let source = CGEventSource(stateID: .privateState),
          let down = CGEvent(keyboardEventSource: source, virtualKey: 5, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: 5, keyDown: false) else {
        throw NativeFailure("KEY_EVENT_FAILED", "無法建立前往檔案事件")
    }
    down.flags = [.maskCommand, .maskShift]
    up.flags = []
    return (down, up)
}

func imageSendSheetIndex(roots: [String], nested: [String], requested: String) -> Int? {
    guard roots == ["open-panel"], nested.allSatisfy({ $0 == "GoToWindow" }), nested.count <= 1 else { return nil }
    if requested == "open-panel", nested.isEmpty { return 0 }
    if requested == "GoToWindow", nested == ["GoToWindow"] { return 1 }
    return nil
}

// 只沿已驗主視窗→open-panel→GoToWindow 的父子關係，不遍歷應用程式選單或聊天內容。
func imageSendDialog(expected: WindowIdentity, parent: AXUIElement, identifier: String) throws -> Snapshot {
    let app = try lineApplication()
    let signing = try strictLineSigningInfo(app.executableURL!)
    guard app.processIdentifier == expected.pid,
          signing.0 == expected.signingIdentifier, signing.1 == expected.teamIdentifier,
          app.executableURL?.standardizedFileURL.path == expected.executableURL,
          NSWorkspace.shared.frontmostApplication?.processIdentifier == expected.pid,
          let parentFrame = frameAttribute(parent), similar(parentFrame, expected.bounds, tolerance: 0.5),
          cgWindows(pid: expected.pid).contains(where: { window in
            guard (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value == expected.windowID,
                  let raw = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = rect(from: raw) else { return false }
            return similar(frame, expected.bounds, tolerance: 0.5)
          }) else { throw NativeFailure("WINDOW_CHANGED", "圖片選擇器的主視窗或前景身分漂移") }
    let roots = children(parent).filter { stringAttribute($0, kAXRoleAttribute) == kAXSheetRole }
    let rootIDs = roots.map { stringAttribute($0, kAXIdentifierAttribute) }
    guard rootIDs == ["open-panel"] else {
        throw NativeFailure(roots.isEmpty ? "IMAGE_PANEL_NOT_READY" : "IMAGE_PANEL_UNVERIFIED",
                            "圖片選擇器不是主視窗下唯一的 open-panel")
    }
    let nested = children(roots[0]).filter { stringAttribute($0, kAXRoleAttribute) == kAXSheetRole }
    let nestedIDs = nested.map { stringAttribute($0, kAXIdentifierAttribute) }
    guard let index = imageSendSheetIndex(roots: rootIDs, nested: nestedIDs, requested: identifier) else {
        let transitioning = nestedIDs.isEmpty || nestedIDs == ["GoToWindow"]
        throw NativeFailure(transitioning ? "IMAGE_PANEL_NOT_READY" : "IMAGE_PANEL_UNVERIFIED",
                            "圖片選擇器的子視窗狀態不符")
    }
    let dialog = (roots + nested)[index]
    guard let frame = frameAttribute(dialog), frame.intersects(expected.bounds) else {
        throw NativeFailure("IMAGE_PANEL_UNVERIFIED", "圖片選擇器位置與主視窗不符")
    }
    let result = snapshot(dialog, mode: .geometryOnly)
    guard !result.partial else { throw NativeFailure("IMAGE_PANEL_UNVERIFIED", "圖片選擇器結構不完整") }
    return result
}

func waitImageSendDialog(expected: WindowIdentity, parent: AXUIElement, identifier: String) throws -> Snapshot {
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    for _ in 0..<20 {
        do { return try imageSendDialog(expected: expected, parent: parent, identifier: identifier) }
        catch let failure as NativeFailure where failure.code == "IMAGE_PANEL_NOT_READY" {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw failure }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
    throw NativeFailure("IMAGE_PANEL_NOT_READY", "圖片選擇器未在限定時間內備妥")
}

func imageSendNode(_ tree: Snapshot, identifier: String, role: String) throws -> AXUIElement {
    let matches = tree.nodes.filter { $0.role == role && $0.enabled &&
        stringAttribute($0.element, kAXIdentifierAttribute) == identifier }
    guard matches.count == 1 else { throw NativeFailure("IMAGE_PANEL_UNVERIFIED", "圖片選擇器控制項不唯一") }
    return matches[0].element
}

func imageSendPathEquivalent(_ observed: String, expected: String) -> Bool {
    // GoTo 欄位與建議列可能分別使用 /var 與 /private/var；僅正規化這個固定別名，兩端都處理。
    let observedPath = observed.hasPrefix("/private/var/") ? String(observed.dropFirst(8)) : observed
    let expectedPath = expected.hasPrefix("/private/var/") ? String(expected.dropFirst(8)) : expected
    return observedPath.precomposedStringWithCanonicalMapping == expectedPath.precomposedStringWithCanonicalMapping
}

func imageSendGoToReady(field: String, candidates: [String], selected: [Bool], expected: String) -> Bool {
    imageSendPathEquivalent(field, expected: expected) && candidates.count == 1 && selected == [true] &&
        imageSendPathEquivalent(candidates[0], expected: expected)
}

func waitImageSendGoToPath(expected: WindowIdentity, parent: AXUIElement, asset: ImageSendAsset) throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    for _ in 0..<40 {
        let tree = try imageSendDialog(expected: expected, parent: parent, identifier: "GoToWindow")
        let field = try imageSendNode(tree, identifier: "PathTextField", role: kAXTextFieldRole)
        let value = stringAttribute(field, kAXValueAttribute)
        guard imageSendPathEquivalent(value, expected: asset.file.path) else {
            throw NativeFailure("IMAGE_PATH_UNVERIFIED", "完整路徑在等待建議時漂移")
        }
        let indices = tree.nodes.indices.filter { index in
            tree.nodes[index].role == kAXListRole && imageSendPathEquivalent(
                stringAttribute(tree.nodes[index].element, kAXIdentifierAttribute), expected: asset.file.path)
        }
        guard indices.count <= 1 else { throw NativeFailure("IMAGE_PATH_UNVERIFIED", "完整路徑建議不唯一") }
        let selected = indices.map { index in
            tree.nodes.indices.contains { ancestor in
                tree.nodes[ancestor].role == kAXRowRole && tree.nodes[ancestor].selected == true &&
                    isDescendant(index, of: ancestor, in: tree.nodes)
            }
        }
        if imageSendGoToReady(field: value, candidates: indices.map {
            stringAttribute(tree.nodes[$0].element, kAXIdentifierAttribute)
        }, selected: selected, expected: asset.file.path) {
            let app = AXUIElementCreateApplication(expected.pid)
            guard let focused = copyAttribute(app, kAXFocusedUIElementAttribute),
                  CFGetTypeID(focused) == AXUIElementGetTypeID(), CFEqual(focused as! AXUIElement, field) else {
                throw NativeFailure("IMAGE_PATH_UNVERIFIED", "完整路徑已備妥但焦點不符")
            }
            return
        }
        guard ProcessInfo.processInfo.systemUptime < deadline else { break }
        Thread.sleep(forTimeInterval: 0.05)
    }
    throw NativeFailure("IMAGE_PATH_NOT_READY", "完整路徑建議未在限定時間內備妥")
}

func imageSendSelectionVerified(_ tree: Snapshot, asset: ImageSendAsset) throws -> AXUIElement {
    let locations = tree.nodes.filter {
        stringAttribute($0.element, kAXIdentifierAttribute) == "where popup" &&
            stringAttribute($0.element, kAXValueAttribute) == asset.directory.lastPathComponent
    }
    let selectedCount: Int
    if asset.width > 0 {
        selectedCount = tree.nodes.filter {
            stringAttribute($0.element, kAXIdentifierAttribute) == "Image Preview: " + asset.file.lastPathComponent
        }.count
    } else {
        // 標準NSOpenPanel的TXT與ZIP合成實測：Info的AXValue第一行為完整檔名。
        // 不讀Quick Look正文作證據，不依賴不穩定的_NS識別碼；另驗SHA目錄、完整GoTo路徑與位元組。
        let browsers = tree.nodes.indices.filter {
            tree.nodes[$0].role == kAXBrowserRole && stringAttribute(tree.nodes[$0].element, kAXIdentifierAttribute) == "ColumnView"
        }
        guard browsers.count == 1 else { throw NativeFailure("IMAGE_SELECTION_UNVERIFIED", "檔案瀏覽器不唯一") }
        selectedCount = tree.nodes.indices.filter { index in
            tree.nodes[index].role == kAXStaticTextRole && isDescendant(index, of: browsers[0], in: tree.nodes) &&
                fileInfoNameMatches(stringAttribute(tree.nodes[index].element, kAXValueAttribute), expected: asset.file.lastPathComponent)
        }.count
    }
    let data = try boundedAttachmentBytes(asset.file.path,
        maximumBytes: asset.width > 0 ? 20 * 1024 * 1024 : 100 * 1024 * 1024, prefix: "IMAGE")
    guard selectedCount == 1, locations.count == 1, imageSendDigest(data) == asset.digest else {
        throw NativeFailure("IMAGE_SELECTION_UNVERIFIED", "所選附件、檔案夾或快照內容無法核對")
    }
    return try imageSendNode(tree, identifier: "OKButton", role: kAXButtonRole)
}

func settledImageSendSelection<T>(clock: () -> TimeInterval, observe: () throws -> T,
                                  pause: () -> Void) throws -> T {
    let deadline = clock() + 3
    var lastFailure: NativeFailure?
    for _ in 0..<30 {
        guard clock() < deadline else { break }
        do {
            let result = try observe()
            guard clock() < deadline else {
                throw NativeFailure("IMAGE_SELECTION_UNVERIFIED", "圖片預覽在等待期限後才回覆")
            }
            return result
        } catch let failure as NativeFailure where failure.code == "IMAGE_SELECTION_UNVERIFIED" {
            lastFailure = failure
        }
        guard clock() < deadline else { break }
        pause()
    }
    throw lastFailure ?? NativeFailure("IMAGE_SELECTION_UNVERIFIED", "圖片預覽未在限定時間內穩定")
}

func waitImageSendSelection(expected: WindowIdentity, parent: AXUIElement,
                            asset: ImageSendAsset) throws -> AXUIElement {
    _ = try waitImageSendDialog(expected: expected, parent: parent, identifier: "open-panel")
    // 只被動等待欄位／預覽同步；成功仍需完整路徑、唯一預覽與檔案SHA全部核對，沒有額外輸入。
    return try settledImageSendSelection(clock: { ProcessInfo.processInfo.systemUptime }, observe: {
        try imageSendSelectionVerified(
            imageSendDialog(expected: expected, parent: parent, identifier: "open-panel"), asset: asset)
    }, pause: { Thread.sleep(forTimeInterval: 0.05) })
}

func imageSendTarget(_ chat: String) throws -> (WindowIdentity, AXUIElement, CGPoint) {
    try requireIndexedUIVersion()
    let (_, _, parent, identity) = try mainWindow(requireForeground: true)
    _ = try strictGlobalAllWindow(expected: identity.json, requireInputReady: true)
    _ = try verifyIndexedHeader(chat, expected: identity)
    let composer = try imageSendComposer(expected: identity)
    let tree = snapshot(parent, mode: .geometryOnly)
    let layout = try readTabLayout(tree, window: identity)
    guard let leftFrame = tree.nodes[layout.leftListIndex].frame else {
        throw NativeFailure("IMAGE_ATTACHMENT_UNVERIFIED", "圖片附件缺少右側邊界證據")
    }
    // 附件位於工具列而非文字編輯器框內；以已校準的左右面板邊界與視窗底緣定位。
    let point = CGPoint(x: leftFrame.maxX + 26, y: identity.bounds.maxY - 22)
    let roi = CGRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20)
    guard !tree.partial, identity.bounds.contains(roi), point.y > composer.frame!.minY,
          point.x < composer.frame!.midX else {
        throw NativeFailure("IMAGE_ATTACHMENT_UNVERIFIED", "附件位置不符合已校準版面")
    }
    return (identity, parent, point)
}

func sendImage(_ args: [String: Any]) throws -> [String: Any] {
    guard imageSendArgumentsValid(args) else {
        throw NativeFailure("INVALID_ARGUMENT", "圖片傳送參數格式不正確", ["phase": "pre_commit"])
    }
    return try submitAttachment(chat: args["chatName"] as! String, autoSend: (args["autoSend"] as! NSNumber).boolValue) {
        try stageImageSendAsset(path: args["imagePath"] as! String, expectedDigest: args["imageSha256"] as! String)
    }
}

func sendFile(_ args: [String: Any]) throws -> [String: Any] {
    guard fileSendArgumentsValid(args) else {
        throw NativeFailure("INVALID_ARGUMENT", "檔案傳送參數格式錯誤", ["phase": "pre_commit"])
    }
    return try submitAttachment(chat: args["chatName"] as! String, autoSend: true) {
        try stageFileSendAsset(path: args["filePath"] as! String, expectedDigest: args["fileSha256"] as! String)
    }
}

func prepareAttachmentForeground() throws {
    let (app, _, _, expected) = try mainWindow(requireForeground: false)
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier else { return }
    guard globalAllInputReady(), CGPreflightPostEventAccess() else {
        throw NativeFailure("PHYSICAL_INPUT_BUSY", "請暫停鍵鼠後再執行附件傳送")
    }
    let signing = try strictLineSigningInfo(app.executableURL!)
    guard strictLineIdentityFields(executablePath: expected.executableURL,
                                   identifier: signing.0, team: signing.1, codeValid: true),
          app.activate(options: [.activateAllWindows]) else {
        throw NativeFailure("LINE_IDENTITY_MISMATCH", "無法啟用已驗證的LINE主視窗")
    }
    let deadline = ProcessInfo.processInfo.systemUptime + 1
    while NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier &&
          ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.02) }
    let (_, _, _, current) = try mainWindow(requireForeground: true)
    guard sameWindow(current, expected) else { throw NativeFailure("WINDOW_CHANGED", "啟用LINE後主視窗已變更") }
}

func submitAttachment(chat: String, autoSend: Bool, stage: () throws -> ImageSendAsset) throws -> [String: Any] {
    var inputAttempted = false
    var staged: ImageSendAsset?
    defer {
        // 已進入選擇器時保留私有快照，避免 LINE 延後讀檔或人工確認時檔案消失。
        if !inputAttempted, let staged { try? FileManager.default.removeItem(at: staged.directory) }
    }
    do {
        let asset = try stage()
        staged = asset
        // 只啟用已驗證、已開啟的同一視窗；不搜尋或切換對話，不加確認關卡。
        try requireIndexedUIVersion()
        try prepareAttachmentForeground()
        let (identity, parent, point) = try imageSendTarget(chat)
        let targetROI = CGRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20)
        _ = try verifyIndexedHeader(chat, expected: identity)
        let events = try buildGlobalAllMouseEvents(point: point, eventNumber: Int64.random(in: 1...32000))
        let current = try strictGlobalAllWindow(expected: identity.json, requireInputReady: true)
        try verifyIndexedPointScene(expected: current, point: point, targetROI: targetROI)
        let composerFrame = try imageSendComposer(expected: current).frame!
        let parkingPoint = CGPoint(x: composerFrame.midX, y: composerFrame.midY)
        // 先完成所有核對，再原子式按下／放開；不先移入懸停，以免 Qt tooltip 被判為 modal。
        inputAttempted = true
        events.down.post(tap: .cghidEventTap)
        events.up.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.25)
        _ = try waitImageSendDialog(expected: identity, parent: parent, identifier: "open-panel")
        let (down, up) = try imageSendGoToEvents()
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.2)
        let goTo = try waitImageSendDialog(expected: identity, parent: parent, identifier: "GoToWindow")
        let field = try imageSendNode(goTo, identifier: "PathTextField", role: kAXTextFieldRole)
        guard AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, asset.file.path as CFString) == .success,
              imageSendPathEquivalent(stringAttribute(field, kAXValueAttribute), expected: asset.file.path),
              let focused = copyAttribute(AXUIElementCreateApplication(identity.pid), kAXFocusedUIElementAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID(), CFEqual(focused as! AXUIElement, field) else {
            throw NativeFailure("IMAGE_PATH_UNVERIFIED", "圖片完整路徑無法 exact 回讀或焦點不符")
        }
        try waitImageSendGoToPath(expected: identity, parent: parent, asset: asset)
        _ = try imageSendDialog(expected: identity, parent: parent, identifier: "GoToWindow")
        try pairedReturnKey()
        Thread.sleep(forTimeInterval: 0.3)
        _ = try waitImageSendSelection(expected: identity, parent: parent, asset: asset)
        Thread.sleep(forTimeInterval: 0.06)
        _ = try waitImageSendSelection(expected: identity, parent: parent, asset: asset)
        // 選檔完成後把游標停在文字區，避免對話框關閉時附件 tooltip 再次干擾送出回讀。
        guard let mouseSource = CGEventSource(stateID: .privateState),
              let parkingEvent = CGEvent(mouseEventSource: mouseSource, mouseType: .mouseMoved,
                                         mouseCursorPosition: parkingPoint, mouseButton: .left) else {
            throw NativeFailure("KEY_EVENT_FAILED", "無法建立游標停放事件")
        }
        parkingEvent.flags = []
        parkingEvent.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.06)
        let confirm = try waitImageSendSelection(expected: identity, parent: parent, asset: asset)
        if autoSend {
            // 打開可能立即發送；只提交一次，沒有 Return 或其它按鈕備援。
            try perform(kAXPressAction, on: confirm)
            Thread.sleep(forTimeInterval: 0.3)
            _ = try verifyIndexedHeader(chat, expected: identity)
            _ = try imageSendComposer(expected: identity)
        }
        var receipt: [String: Any] = ["success": true, "autoSent": autoSend, "chatVerified": true,
                "selectedFileVerified": true, "sourceSha256": asset.sourceDigest,
                "imageSha256": asset.digest, "width": asset.width, "height": asset.height,
                "temporaryFileRetained": true,
                "receipt": ["status": autoSend ? "UI_SUBMITTED" : "IMAGE_SELECTED_NOT_SENT",
                            "deliveryConfirmed": false,
                            "observedAt": ISO8601DateFormatter().string(from: Date())]]
        if asset.width == 0 { receipt["fileSha256"] = asset.sourceDigest; receipt["byteCount"] = asset.byteCount }
        return receipt
    } catch let failure as NativeFailure {
        throw forcingPhase(failure, inputAttempted ? "post_commit" : "pre_commit")
    } catch {
        throw NativeFailure("IMAGE_OPERATION_FAILED", "圖片選入或提交未完成",
                            ["phase": inputAttempted ? "post_commit" : "pre_commit"])
    }
}

func validName(_ value: Any?) -> String? {
    guard let value = value as? String, !value.isEmpty, value.count <= 200,
          !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          value.range(of: #"\p{Cc}|[\u{202A}-\u{202E}\u{2066}-\u{2069}]"#,
                      options: .regularExpression) == nil else { return nil }
    return value
}

enum TabChangeAction: String { case createTab = "create_tab", renameTab = "rename_tab", moveChat = "move_chat", removeChat = "remove_chat" }

struct TabChange {
    let action: TabChangeAction
    let name: String?
    let tabName: String?
    let newName: String?
    let sourceTab: String?
    let destinationTab: String?
    let chatName: String?

    var json: [String: Any] {
        var value: [String: Any] = ["action": action.rawValue]
        if let name { value["name"] = name }
        if let tabName { value["tabName"] = tabName }
        if let newName { value["newName"] = newName }
        if let sourceTab { value["sourceTab"] = sourceTab }
        if let destinationTab { value["destinationTab"] = destinationTab }
        if let chatName { value["chatName"] = chatName }
        return value
    }
}

let createTabLabels = ["新增分類", "新增分頁", "新增聊天分類", "Add category", "Create category"]
let renameTabLabels = ["變更分類名稱", "重新命名分類", "重新命名分頁", "Rename category", "Rename"]
let moveChatLabels = ["移往其他分類", "移動至其他分類", "Move to another category"]
let removeChatLabels = ["取消分類", "移出分類", "未分類", "Remove from category", "Uncategorized"]
let confirmLabels = ["確認", "儲存", "建立", "新增", "完成", "OK", "Save", "Create"]
let dangerousMutationLabels = ["刪除聊天室", "刪除分類", "退出群組", "封鎖", "Delete chat", "Delete category", "Leave group", "Block"]

func parseTabChanges(_ raw: Any?) throws -> [TabChange] {
    guard let raw = raw as? [[String: Any]], (1...20).contains(raw.count) else {
        throw NativeFailure("INVALID_ARGUMENT", "changes 必須是 1 到 20 筆物件")
    }
    var result: [TabChange] = []
    for value in raw {
        guard let actionName = value["action"] as? String, let action = TabChangeAction(rawValue: actionName) else {
            throw NativeFailure("INVALID_ARGUMENT", "changes 含有未知 action")
        }
        let expected: Set<String>
        switch action {
        case .createTab: expected = ["action", "name"]
        case .renameTab: expected = ["action", "tabName", "newName"]
        case .moveChat: expected = ["action", "sourceTab", "destinationTab", "chatName"]
        case .removeChat: expected = ["action", "sourceTab", "chatName"]
        }
        guard Set(value.keys) == expected else {
            throw NativeFailure("INVALID_ARGUMENT", "changes action 欄位不完整或含有未知欄位")
        }
        func name(_ key: String) throws -> String {
            guard let valid = validName(value[key]) else {
                throw NativeFailure("INVALID_ARGUMENT", "changes.\(key) 格式不正確")
            }
            return valid
        }
        switch action {
        case .createTab:
            result.append(TabChange(action: action, name: try name("name"), tabName: nil, newName: nil,
                                    sourceTab: nil, destinationTab: nil, chatName: nil))
        case .renameTab:
            let old = try name("tabName"), new = try name("newName")
            guard old != new else { throw NativeFailure("INVALID_ARGUMENT", "改名前後名稱不得相同") }
            result.append(TabChange(action: action, name: nil, tabName: old, newName: new,
                                    sourceTab: nil, destinationTab: nil, chatName: nil))
        case .moveChat:
            let source = try name("sourceTab"), destination = try name("destinationTab")
            guard source != destination else { throw NativeFailure("INVALID_ARGUMENT", "來源與目的分類不得相同") }
            result.append(TabChange(action: action, name: nil, tabName: nil, newName: nil,
                                    sourceTab: source, destinationTab: destination, chatName: try name("chatName")))
        case .removeChat:
            result.append(TabChange(action: action, name: nil, tabName: nil, newName: nil,
                                    sourceTab: try name("sourceTab"), destinationTab: nil,
                                    chatName: try name("chatName")))
        }
    }
    if result[0].action == .createTab || result[0].action == .renameTab {
        guard result.count == 1 else { throw NativeFailure("INVALID_ARGUMENT", "建立或改名計畫只能有一筆") }
    } else {
        guard result.allSatisfy({ $0.action == result[0].action && $0.sourceTab == result[0].sourceTab }) else {
            throw NativeFailure("INVALID_ARGUMENT", "批次必須同 action 且來源分類一致")
        }
        let names = result.compactMap(\.chatName)
        guard Set(names).count == names.count else { throw NativeFailure("INVALID_ARGUMENT", "批次聊天室不得重複") }
    }
    return result
}

struct CapacityEvidence {
    let current: Int
    let limit: Int
    let label: String
}

enum CapacityKind { case categories, chats }

enum CapacityObservation {
    case absent
    case verified(CapacityEvidence)
    case conflicting

    func projected(current: Int) -> CapacityObservation {
        guard case let .verified(value) = self else { return self }
        return .verified(CapacityEvidence(current: current, limit: value.limit, label: value.label))
    }
}

enum P2CapacityLocation { case anchor, source, destination }
enum P2CapacityDecision: Equatable { case allowed, absent, full, conflicting, invalidUse }

func p2CapacityDecision(action: TabChangeAction, location: P2CapacityLocation,
                        observation: CapacityObservation) -> P2CapacityDecision {
    if case .conflicting = observation { return .conflicting }
    let increasesQuota: Bool
    switch (action, location) {
    case (.createTab, .anchor), (.moveChat, .destination): increasesQuota = true
    case (.renameTab, .source), (.moveChat, .source), (.removeChat, .source): increasesQuota = false
    default: return .invalidUse
    }
    switch observation {
    case .absent: return increasesQuota ? .absent : .allowed
    case let .verified(value): return increasesQuota && value.current >= value.limit ? .full : .allowed
    case .conflicting: return .conflicting
    }
}

func requireP2Capacity(action: TabChangeAction, location: P2CapacityLocation,
                       observation: CapacityObservation) throws {
    switch p2CapacityDecision(action: action, location: location, observation: observation) {
    case .allowed: return
    case .absent: throw NativeFailure("CAPACITY_UNKNOWN", "增加分類或聊天室時缺少可證容量")
    case .full: throw NativeFailure("CAPACITY_FULL", "增加分類或聊天室會超過已證容量")
    case .conflicting: throw NativeFailure("CAPACITY_CONFLICT", "UI 容量文字與 inventory 衝突或不唯一")
    case .invalidUse: throw NativeFailure("INVALID_ARGUMENT", "capacity 判定位置與 action 不相容")
    }
}

func capacityEvidence(_ texts: [String], expectedCurrent: Int,
                      kind: CapacityKind = .categories) -> CapacityObservation {
    let expression = try! NSRegularExpression(pattern: #"(?<!\d)(\d{1,5})\s*/\s*(\d{1,5})(?!\d)"#)
    var values: [CapacityEvidence] = []
    var relevantCountLabel = false
    var conflicting = false
    for text in texts {
        let lowered = text.lowercased()
        let semantic = kind == .categories
            ? ["分類", "分頁", "category", "tab"].contains(where: lowered.contains)
            : ["聊天室", "聊天", "chat", "room"].contains(where: lowered.contains)
        guard semantic else { continue }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = expression.matches(in: text, range: range)
        let resemblesCount = text.contains("/") && text.unicodeScalars.contains {
            CharacterSet.decimalDigits.contains($0)
        }
        if resemblesCount { relevantCountLabel = true }
        if resemblesCount && matches.isEmpty { conflicting = true }
        for match in matches {
            relevantCountLabel = true
            guard let currentRange = Range(match.range(at: 1), in: text),
                  let limitRange = Range(match.range(at: 2), in: text),
                  let current = Int(text[currentRange]), let limit = Int(text[limitRange]),
                  current == expectedCurrent, current >= 0, limit >= current, limit > 0 else {
                conflicting = true
                continue
            }
            values.append(CapacityEvidence(current: current, limit: limit, label: text))
        }
    }
    if conflicting || values.count > 1 { return .conflicting }
    if let value = values.first { return .verified(value) }
    return relevantCountLabel ? .conflicting : .absent
}

func stablePopupTexts(_ parent: WindowIdentity, anchorFrame: CGRect,
                      popup: WindowIdentity) throws -> [String] {
    guard #available(macOS 14.0, *) else {
        throw NativeFailure("UNSUPPORTED_OS_VERSION", "popup OCR 需要 macOS 14 以上")
    }
    let first = try capturePopupOCR(parent: parent, fieldFrame: anchorFrame)
    guard sameWindow(popup, first.identity) else { throw NativeFailure("WINDOW_CHANGED", "popup 身分不符") }
    Thread.sleep(forTimeInterval: 0.05)
    let second = try capturePopupOCR(parent: parent, fieldFrame: anchorFrame)
    guard sameWindow(first.identity, second.identity), first.imageWidth == second.imageWidth,
          first.imageHeight == second.imageHeight else {
        throw NativeFailure("WINDOW_CHANGED", "popup OCR 幾何已變更")
    }
    var result: [String] = []
    for old in first.candidates where old.confidence >= ocrConfidenceThreshold {
        let matches = second.candidates.filter {
            $0.confidence >= ocrConfidenceThreshold && $0.text == old.text &&
                intersectionOverUnion($0.normalizedBox, old.normalizedBox) >= 0.80
        }
        if matches.count == 1 && !result.contains(old.text) { result.append(old.text) }
    }
    guard !result.isEmpty else { throw NativeFailure("UNSUPPORTED_UI", "popup 沒有穩定可證文字") }
    return result
}

func exactUniqueLabel(_ allowed: [String], in observed: [String]) -> String? {
    let matches = observed.filter { allowed.contains($0) }
    return matches.count == 1 ? matches[0] : nil
}

struct TabMenuEvidence {
    let labels: [String]
    let capacity: CapacityObservation
}

func inspectTabMenu(_ tabName: String, expectedCurrent: Int, capacityKind: CapacityKind,
                    expectedWindow: Any? = nil) throws -> TabMenuEvidence {
    let identity = try navigateTab(tabName, expectedWindow: expectedWindow)
    let selected = try verifySelectedTab(tabName)
    guard sameWindow(identity, selected.0.identity) else { throw NativeFailure("WINDOW_CHANGED", "分頁 menu 錨定前視窗已變更") }
    let geometry = CaptureGeometry(window: identity.bounds, roi: selected.0.roi,
                                   imageWidth: selected.0.imageWidth, imageHeight: selected.0.imageHeight)
    let target = try geometry.screenRect(for: selected.1)
    let popup = try openPopup(parent: identity, anchorFrame: target,
                              point: CGPoint(x: target.midX, y: target.midY))
    do {
        let labels = try stablePopupTexts(identity, anchorFrame: target, popup: popup)
        try dismissSearchPopup(parent: identity, popup: popup, fieldFrame: target)
        return TabMenuEvidence(labels: labels, capacity: capacityEvidence(
            labels, expectedCurrent: expectedCurrent, kind: capacityKind
        ))
    } catch {
        try? dismissSearchPopup(parent: identity, popup: popup, fieldFrame: target)
        throw error
    }
}

func selectedChatRow(_ chatName: String, tabName: String,
                     expectedWindow: Any? = nil) throws -> (WindowIdentity, NodeRecord) {
    let selected = try selectChat(chatName, tabName: tabName)
    guard let rawWindow = selected["mainWindow"] as? [String: Any] else {
        throw NativeFailure("CHAT_SELECTION_UNVERIFIED", "聊天室選取缺少視窗證據")
    }
    let (_, _, identity, rows) = try currentChatRows()
    try validateExpectedWindow(expectedWindow ?? rawWindow, current: identity)
    let matches = rows.filter { $0.1 == chatName && $0.0.selected == true }
    guard matches.count == 1, let row = matches.first, row.0.frame != nil else {
        throw NativeFailure("CHAT_SELECTION_UNVERIFIED", "聊天室 row 無法唯一綁定 selected-state")
    }
    return (identity, row.0)
}

struct RowRouteEvidence {
    let rootLabels: [String]
    let destinationLabels: [String]
}

func inspectRowRoute(_ change: TabChange, expectedWindow: Any? = nil) throws -> RowRouteEvidence {
    guard let source = change.sourceTab, let chat = change.chatName else {
        throw NativeFailure("INVALID_ARGUMENT", "聊天室分類操作缺少必要欄位")
    }
    let selected = try selectedChatRow(chat, tabName: source, expectedWindow: expectedWindow)
    let rowFrame = selected.1.frame!
    let popup = try openPopup(parent: selected.0, anchorFrame: rowFrame,
                              point: CGPoint(x: rowFrame.midX, y: rowFrame.midY))
    do {
        let rootLabels = try stablePopupTexts(selected.0, anchorFrame: rowFrame, popup: popup)
        guard !rootLabels.contains(where: { dangerousMutationLabels.contains($0) &&
            (removeChatLabels.contains($0) || moveChatLabels.contains($0)) }) else {
            throw NativeFailure("UNSUPPORTED_UI", "分類操作語意與危險動作衝突")
        }
        if change.action == .removeChat {
            guard exactUniqueLabel(removeChatLabels, in: rootLabels) != nil else {
                throw NativeFailure("UNSUPPORTED_UI", "沒有唯一明確的取消分類／未分類語意")
            }
            try dismissSearchPopup(parent: selected.0, popup: popup, fieldFrame: rowFrame)
            return RowRouteEvidence(rootLabels: rootLabels, destinationLabels: [])
        }
        guard exactUniqueLabel(moveChatLabels, in: rootLabels) != nil,
              let destination = change.destinationTab else {
            throw NativeFailure("UNSUPPORTED_UI", "沒有唯一明確的移往其他分類語意")
        }
        do {
            _ = try clickPopupItem(parent: selected.0, anchorFrame: rowFrame,
                                   popup: popup, labels: moveChatLabels)
        } catch let failure as NativeFailure {
            // 這一步只導覽到目的分類清單，尚未選擇目的地。
            throw forcingPhase(failure, "pre_commit")
        }
        let submenu = try waitForSearchPopup(parent: selected.0, fieldFrame: rowFrame)
        let destinationLabels = try stablePopupTexts(selected.0, anchorFrame: rowFrame, popup: submenu)
        guard exactUniqueLabel([destination], in: destinationLabels) != nil else {
            throw NativeFailure("UNSUPPORTED_UI", "目的分類在新 popup 中不唯一或不存在")
        }
        try dismissSearchPopup(parent: selected.0, popup: submenu, fieldFrame: rowFrame)
        return RowRouteEvidence(rootLabels: rootLabels, destinationLabels: destinationLabels)
    } catch {
        try? dismissSearchPopup(parent: selected.0, popup: popup, fieldFrame: rowFrame)
        throw error
    }
}

final class P2PreviewContext {
    let inventory: TabInventory
    var memberships: [String: ChatScanResult] = [:]
    var menus: [String: TabMenuEvidence] = [:]

    init(inventory: TabInventory) { self.inventory = inventory }

    func requireUniqueTab(_ name: String) throws {
        guard inventory.names.filter({ $0 == name }).count == 1 else {
            throw NativeFailure("TAB_NOT_FOUND", "分類不存在或不唯一", ["tabName": name])
        }
    }

    func membership(_ tabName: String) throws -> ChatScanResult {
        if let cached = memberships[tabName] { return cached }
        try requireUniqueTab(tabName)
        let identity = try navigateTab(tabName, expectedWindow: inventory.identity.json)
        let scan = try scanTabChats(expected: identity)
        guard scan.complete else {
            throw NativeFailure("INVENTORY_PARTIAL", "分類聊天室清單不完整", ["tabName": tabName, "reasons": scan.reasons])
        }
        memberships[tabName] = scan
        return scan
    }

    func menu(_ tabName: String, expectedCurrent: Int,
              capacityKind: CapacityKind) throws -> TabMenuEvidence {
        let kindKey = capacityKind == .categories ? "categories" : "chats"
        let key = "\(tabName)\u{0}\(expectedCurrent)\u{0}\(kindKey)"
        if let cached = menus[key] { return cached }
        try requireUniqueTab(tabName)
        let evidence = try inspectTabMenu(tabName, expectedCurrent: expectedCurrent,
                                          capacityKind: capacityKind,
                                          expectedWindow: inventory.identity.json)
        menus[key] = evidence
        return evidence
    }
}

func capacityJSON(_ capacity: CapacityObservation) -> [String: Any] {
    switch capacity {
    case .absent: return ["state": "absent"]
    case .conflicting: return ["state": "conflicting"]
    case let .verified(value):
        return ["state": "verified", "current": value.current, "limit": value.limit,
                "source": "UI_EXACT_COUNT_LIMIT_LABEL"]
    }
}

func p2Fingerprint(change: TabChange, inventory: TabInventory,
                   invariants: [String: Any]) -> String {
    // ordered plan digest 由 Node 綁定；單項 fingerprint 只描述執行當下應見的不變量。
    sha256(["change": change.json, "window": inventory.identity.json,
            "tabs": inventory.names, "invariants": invariants,
            "ocrProcessedPolicy": processedOCRPolicyVersion] as [String: Any])
}

func p2Blocked(_ index: Int, _ failure: NativeFailure) -> [String: Any] {
    ["index": index, "code": failure.code, "message": failure.message]
}

func previewTabChanges(_ args: [String: Any], predictedPrefixBase: Int = 0) throws -> [String: Any] {
    let changes = try parseTabChanges(args["changes"])
    let inventory = try scanFullTabInventory(maxPages: 20)
    var previewItems = changes.enumerated().map { index, change in
        ["index": index, "change": change.json, "willMutate": true,
         "mayAffectReadState": true, "maySelectChat": true] as [String: Any]
    }
    guard inventory.complete else {
        let blockedReasons = inventory.reasons.map {
            ["index": NSNull(), "code": "INVENTORY_PARTIAL", "message": $0] as [String: Any]
        }
        return ["preview": ["items": previewItems, "blockedReasons": blockedReasons,
                             "mayAffectReadState": true, "maySelectChat": true],
                "snapshotDigest": sha256(["changes": changes.map(\.json), "window": inventory.identity.json,
                                            "ocrProcessedPolicy": processedOCRPolicyVersion]),
                "expectedWindow": inventory.identity.json, "itemFingerprints": [],
                "canExecute": false, "blocked": true]
    }

    let context = P2PreviewContext(inventory: inventory)
    var predictedMemberships: [String: [String]] = [:]
    var itemFingerprints: [String] = []
    var blocked: [[String: Any]] = []

    func predicted(_ tab: String) throws -> [String] {
        if let value = predictedMemberships[tab] { return value }
        let value = try context.membership(tab).names.sorted()
        predictedMemberships[tab] = value
        return value
    }

    for (index, change) in changes.enumerated() {
        do {
            var invariants: [String: Any] = [:]
            switch change.action {
            case .createTab:
                let newName = change.name!
                guard !inventory.names.contains(newName) else {
                    throw NativeFailure("DUPLICATE_NAME", "新分類名稱已存在")
                }
                guard let anchor = inventory.selectedTab ?? inventory.names.first else {
                    throw NativeFailure("UNSUPPORTED_UI", "沒有可證 selected 分頁作新增 menu 錨點")
                }
                let menu = try context.menu(anchor, expectedCurrent: inventory.names.count,
                                            capacityKind: .categories)
                guard let capabilityLabel = exactUniqueLabel(createTabLabels, in: menu.labels) else {
                    throw NativeFailure("UNSUPPORTED_UI", "沒有唯一可證的新增分類能力")
                }
                try requireP2Capacity(action: .createTab, location: .anchor,
                                      observation: menu.capacity)
                invariants = ["capability": "create", "mutabilityLabel": capabilityLabel,
                              "anchorTab": anchor,
                              "tabStructure": sha256(["tabs": inventory.names]),
                              "capacity": capacityJSON(menu.capacity)]
            case .renameTab:
                let old = change.tabName!, new = change.newName!
                try context.requireUniqueTab(old)
                guard !inventory.names.contains(new) else {
                    throw NativeFailure("DUPLICATE_NAME", "新分類名稱已存在")
                }
                let members = try predicted(old)
                let menu = try context.menu(old, expectedCurrent: inventory.names.count,
                                            capacityKind: .categories)
                guard let mutabilityLabel = exactUniqueLabel(renameTabLabels, in: menu.labels) else {
                    throw NativeFailure("BUILTIN_OR_UNSUPPORTED_UI", "UI 未證明此分類可改名")
                }
                try requireP2Capacity(action: .renameTab, location: .source,
                                      observation: menu.capacity)
                invariants = ["capability": "rename", "mutabilityLabel": mutabilityLabel,
                              "membership": members,
                              "tabStructure": sha256(["tabs": inventory.names]),
                              "membershipStructure": sha256(["tab": old, "members": members]),
                              "capacity": capacityJSON(menu.capacity)]
            case .moveChat:
                let source = change.sourceTab!, destination = change.destinationTab!, chat = change.chatName!
                var sourceMembers = try predicted(source)
                var destinationMembers = try predicted(destination)
                guard sourceMembers.filter({ $0 == chat }).count == 1,
                      !destinationMembers.contains(chat) else {
                    throw NativeFailure("MEMBERSHIP_CHANGED", "來源聊天室不唯一或目的分類已含同名聊天室")
                }
                let sourceMenu = try context.menu(source, expectedCurrent: context.membership(source).names.count,
                                                  capacityKind: .chats)
                let destinationMenu = try context.menu(destination,
                                                       expectedCurrent: context.membership(destination).names.count,
                                                       capacityKind: .chats)
                guard let sourceMutabilityLabel = exactUniqueLabel(renameTabLabels, in: sourceMenu.labels),
                      let destinationMutabilityLabel = exactUniqueLabel(renameTabLabels,
                                                                        in: destinationMenu.labels) else {
                    throw NativeFailure("BUILTIN_OR_UNSUPPORTED_UI", "來源或目的分類未證明為可變更自訂分類")
                }
                let sourceCapacity = sourceMenu.capacity.projected(current: sourceMembers.count)
                let destinationCapacity = destinationMenu.capacity.projected(current: destinationMembers.count)
                try requireP2Capacity(action: .moveChat, location: .source,
                                      observation: sourceCapacity)
                try requireP2Capacity(action: .moveChat, location: .destination,
                                      observation: destinationCapacity)
                let route = try inspectRowRoute(change, expectedWindow: inventory.identity.json)
                invariants = ["chatIdentity": chat,
                              "sourceMutabilityLabel": sourceMutabilityLabel,
                              "destinationMutabilityLabel": destinationMutabilityLabel,
                              "predictedPrefixCount": predictedPrefixBase + index,
                              "sourceMembership": sourceMembers, "destinationMembership": destinationMembers,
                              "sourceStructure": sha256(["tab": source, "members": sourceMembers]),
                              "destinationStructure": sha256(["tab": destination, "members": destinationMembers]),
                              "sourceCapacity": capacityJSON(sourceCapacity),
                              "destinationCapacity": capacityJSON(destinationCapacity),
                              "route": ["root": route.rootLabels, "destination": route.destinationLabels]]
                sourceMembers.removeAll { $0 == chat }
                destinationMembers.append(chat)
                predictedMemberships[source] = sourceMembers.sorted()
                predictedMemberships[destination] = destinationMembers.sorted()
            case .removeChat:
                let source = change.sourceTab!, chat = change.chatName!
                var sourceMembers = try predicted(source)
                guard sourceMembers.filter({ $0 == chat }).count == 1 else {
                    throw NativeFailure("MEMBERSHIP_CHANGED", "來源聊天室不存在或不唯一")
                }
                let sourceMenu = try context.menu(source, expectedCurrent: context.membership(source).names.count,
                                                  capacityKind: .chats)
                guard let sourceMutabilityLabel = exactUniqueLabel(renameTabLabels,
                                                                   in: sourceMenu.labels) else {
                    throw NativeFailure("BUILTIN_OR_UNSUPPORTED_UI", "來源分類未證明為可變更自訂分類")
                }
                let sourceCapacity = sourceMenu.capacity.projected(current: sourceMembers.count)
                try requireP2Capacity(action: .removeChat, location: .source,
                                      observation: sourceCapacity)
                let allNames = inventory.names.filter { ["全部", "All"].contains($0) }
                guard allNames.count == 1 else { throw NativeFailure("UNSUPPORTED_UI", "無法唯一辨識非自訂的全部清單") }
                let allMembers = try predicted(allNames[0])
                guard allMembers.filter({ $0 == chat }).count == 1 else {
                    throw NativeFailure("MEMBERSHIP_UNVERIFIED", "非自訂清單沒有唯一保留聊天室證據")
                }
                let route = try inspectRowRoute(change, expectedWindow: inventory.identity.json)
                invariants = ["chatIdentity": chat,
                              "sourceMutabilityLabel": sourceMutabilityLabel,
                              "predictedPrefixCount": predictedPrefixBase + index,
                              "sourceMembership": sourceMembers, "allMembership": allMembers,
                              "sourceStructure": sha256(["tab": source, "members": sourceMembers]),
                              "allStructure": sha256(["tab": allNames[0], "members": allMembers]),
                              "sourceCapacity": capacityJSON(sourceCapacity), "allTab": allNames[0],
                              "route": ["root": route.rootLabels]]
                sourceMembers.removeAll { $0 == chat }
                predictedMemberships[source] = sourceMembers.sorted()
            }
            itemFingerprints.append(p2Fingerprint(change: change,
                                                  inventory: inventory, invariants: invariants))
            previewItems[index]["preconditionsVerified"] = true
        } catch let failure as NativeFailure {
            blocked.append(p2Blocked(index, failure))
            previewItems[index]["preconditionsVerified"] = false
            break
        }
    }
    let canExecute = blocked.isEmpty && itemFingerprints.count == changes.count
    let snapshotDigest = sha256(["changes": changes.map(\.json), "window": inventory.identity.json,
                                 "itemFingerprints": itemFingerprints,
                                 "ocrProcessedPolicy": processedOCRPolicyVersion] as [String: Any])
    let preview: [String: Any] = ["items": previewItems, "blockedReasons": blocked,
                                  "mayAffectReadState": true, "maySelectChat": true]
    let result: [String: Any] = ["preview": preview, "snapshotDigest": snapshotDigest,
                                 "expectedWindow": inventory.identity.json,
                                 "itemFingerprints": itemFingerprints,
                                 "canExecute": canExecute,
                                 "blocked": !canExecute]
    return result
}

func snapshotTabChanges(_ args: [String: Any]) throws -> [String: Any] {
    let changes = try parseTabChanges(args["changes"])
    guard let expectedFingerprints = args["itemFingerprints"] as? [String],
          expectedFingerprints.count == changes.count,
          expectedFingerprints.allSatisfy({ !$0.isEmpty && $0.count <= 256 }) else {
        throw NativeFailure("INVALID_ARGUMENT", "itemFingerprints 格式不正確", ["phase": "pre_commit"])
    }
    let current: [String: Any]
    do { current = try previewTabChanges(["changes": changes.map(\.json)]) }
    catch let failure as NativeFailure { throw forcingPhase(failure, "pre_commit") }
    guard current["canExecute"] as? Bool == true,
          let currentFingerprints = current["itemFingerprints"] as? [String],
          currentFingerprints == expectedFingerprints,
          let window = current["expectedWindow"] as? [String: Any] else {
        throw NativeFailure("SNAPSHOT_CHANGED", "P2 提交前結構或能力證據已變更", ["phase": "pre_commit"])
    }
    let (_, _, _, identity) = try mainWindow(requireForeground: true)
    try validateExpectedWindow(args["expectedWindow"], current: identity)
    try validateExpectedWindow(window, current: identity)
    guard let digest = current["snapshotDigest"] as? String else {
        throw NativeFailure("NATIVE_PROTOCOL_ERROR", "P2 snapshot 缺少 digest", ["phase": "pre_commit"])
    }
    return ["snapshotDigest": digest]
}

func uniqueAXElements(_ values: [AXUIElement]) -> [AXUIElement] {
    var result: [AXUIElement] = []
    for value in values where !result.contains(where: { CFEqual($0, value) }) { result.append(value) }
    return result
}

func hasAXAncestor(_ child: AXUIElement, ancestor: AXUIElement, maximumDepth: Int = 8) -> Bool {
    var current = child
    for _ in 0..<maximumDepth {
        guard let raw = copyAttribute(current, kAXParentAttribute),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return false }
        let parent = raw as! AXUIElement
        if CFEqual(parent, ancestor) { return true }
        current = parent
    }
    return false
}

struct MutationDialogEvidence {
    let root: AXUIElement
    let field: AXUIElement
    let confirm: AXUIElement
}

func mutationDialog(parent: WindowIdentity, parentWindow: AXUIElement,
                    oldValue: String?) throws -> MutationDialogEvidence {
    let app = try lineApplication()
    guard app.processIdentifier == parent.pid,
          NSWorkspace.shared.frontmostApplication?.processIdentifier == parent.pid else {
        throw NativeFailure("FOREGROUND_REQUIRED", "dialog 驗證時 LINE 不在前景", ["phase": "pre_commit"])
    }
    let appElement = AXUIElementCreateApplication(parent.pid)
    let appWindows = copyAttribute(appElement, kAXWindowsAttribute) as? [AXUIElement] ?? []
    let candidates = uniqueAXElements(appWindows + children(parentWindow)).filter { element in
        let role = stringAttribute(element, kAXRoleAttribute)
        let subrole = stringAttribute(element, kAXSubroleAttribute)
        guard role == kAXSheetRole || subrole == kAXDialogSubrole,
              let frame = frameAttribute(element), frame.width >= 160, frame.height >= 80,
              frame.intersects(parent.bounds),
              (hasAXAncestor(element, ancestor: parentWindow) || appWindows.contains(where: { CFEqual($0, element) })) else {
            return false
        }
        return true
    }
    guard candidates.count == 1, let dialog = candidates.first else {
        throw NativeFailure("UNSUPPORTED_UI", "無法唯一綁定同 PID 且屬於主視窗的 dialog/sheet",
                            ["phase": "pre_commit", "count": candidates.count])
    }
    let tree = snapshot(dialog, mode: .text)
    guard !tree.partial else {
        throw NativeFailure("SEMANTIC_PARTIAL", "dialog AX 快照不完整", ["phase": "pre_commit"])
    }
    let fields = tree.nodes.filter {
        $0.role == kAXTextFieldRole && $0.enabled && $0.subrole != kAXSearchFieldSubrole
    }
    guard fields.count == 1, let field = fields.first else {
        throw NativeFailure("UNSUPPORTED_UI", "dialog 沒有唯一 enabled AXTextField",
                            ["phase": "pre_commit", "count": fields.count])
    }
    let currentValue = stringAttribute(field.element, kAXValueAttribute)
    if let oldValue {
        guard currentValue == oldValue else {
            throw NativeFailure("DIALOG_VALUE_MISMATCH", "改名欄位原值不等於舊分類名稱", ["phase": "pre_commit"])
        }
    } else {
        guard currentValue.isEmpty else {
            throw NativeFailure("DIALOG_VALUE_MISMATCH", "新增分類欄位不是空值", ["phase": "pre_commit"])
        }
    }
    let buttons = tree.nodes.filter {
        $0.role == kAXButtonRole && $0.enabled && $0.texts.contains(where: { confirmLabels.contains($0) })
    }
    guard buttons.count == 1, let button = buttons.first else {
        throw NativeFailure("UNSUPPORTED_UI", "dialog 沒有唯一 enabled 白名單確認鈕",
                            ["phase": "pre_commit", "count": buttons.count])
    }
    return MutationDialogEvidence(root: dialog, field: field.element, confirm: button.element)
}

func pairedCommandKey(_ keyCode: CGKeyCode) throws {
    guard let source = CGEventSource(stateID: .combinedSessionState),
          let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
        throw NativeFailure("KEY_EVENT_FAILED", "無法建立受控 Command 快捷鍵", ["phase": "pre_commit"])
    }
    down.flags = .maskCommand; up.flags = .maskCommand
    down.post(tap: .cghidEventTap)
    var released = false
    defer { if !released { up.post(tap: .cghidEventTap) } }
    up.post(tap: .cghidEventTap)
    released = true
}

func pasteDialogValue(_ value: String, evidence: MutationDialogEvidence,
                      replacing: Bool) throws -> [String: Any] {
    let appElement = AXUIElementCreateApplication(try lineApplication().processIdentifier)
    guard AXUIElementSetAttributeValue(evidence.field, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success,
          let focused = copyAttribute(appElement, kAXFocusedUIElementAttribute),
          CFGetTypeID(focused) == AXUIElementGetTypeID(),
          CFEqual(focused as! AXUIElement, evidence.field) else {
        throw NativeFailure("DIALOG_FIELD_UNFOCUSED", "無法證明焦點位於 dialog 欄位", ["phase": "pre_commit"])
    }
    let pasteboard = NSPasteboard.general
    let backup = try PasteboardBackup(pasteboard)
    pasteboard.clearContents()
    guard pasteboard.setString(value, forType: .string) else {
        throw NativeFailure("CLIPBOARD_WRITE_FAILED", "無法寫入暫時分類名稱", ["phase": "pre_commit"])
    }
    let ownChangeCount = pasteboard.changeCount
    do {
        if replacing { try pairedCommandKey(0) } // Command+A，只選 dialog 內已驗證欄位。
        guard pasteboard.changeCount == ownChangeCount else {
            throw NativeFailure("CLIPBOARD_CHANGED", "貼上前剪貼簿已被其他程式變更", ["phase": "pre_commit"])
        }
        try pairedCommandKey(9) // Command+V；不使用 Return/default button 提交。
        Thread.sleep(forTimeInterval: 0.08)
        guard stringAttribute(evidence.field, kAXValueAttribute) == value else {
            throw NativeFailure("DIALOG_VALUE_MISMATCH", "貼上後分類名稱 exact 回讀不一致", ["phase": "pre_commit"])
        }
        let restored = backup.restore(pasteboard, onlyIf: ownChangeCount)
        return ["usedClipboard": true, "clipboardRestored": restored,
                "externalClipboardChange": !restored]
    } catch {
        _ = backup.restore(pasteboard, onlyIf: ownChangeCount)
        throw error
    }
}

func revalidateDialogBeforeConfirm(_ evidence: MutationDialogEvidence,
                                   expectedValue: String, parent: WindowIdentity) throws {
    let app = try lineApplication()
    guard app.processIdentifier == parent.pid,
          NSWorkspace.shared.frontmostApplication?.processIdentifier == parent.pid,
          stringAttribute(evidence.field, kAXValueAttribute) == expectedValue,
          boolAttribute(evidence.field, kAXEnabledAttribute, default: false),
          boolAttribute(evidence.confirm, kAXEnabledAttribute, default: false) else {
        throw NativeFailure("DIALOG_CHANGED", "按確認前 dialog 欄位或控制項已變更", ["phase": "pre_commit"])
    }
    let tree = snapshot(evidence.root, mode: .text)
    let fields = tree.nodes.filter {
        $0.role == kAXTextFieldRole && $0.enabled && $0.subrole != kAXSearchFieldSubrole &&
            CFEqual($0.element, evidence.field)
    }
    let buttons = tree.nodes.filter {
        $0.role == kAXButtonRole && $0.enabled && CFEqual($0.element, evidence.confirm) &&
            $0.texts.contains(where: { confirmLabels.contains($0) })
    }
    guard !tree.partial, fields.count == 1, buttons.count == 1 else {
        throw NativeFailure("DIALOG_CHANGED", "按確認前 dialog 身分或白名單控制項不再唯一", ["phase": "pre_commit"])
    }
}

func openTabMutationDialog(tabName: String, menuLabels: [String],
                           oldValue: String?, expectedWindow: Any?) throws ->
    (WindowIdentity, MutationDialogEvidence) {
    let (_, _, parentWindow, parent) = try mainWindow(requireForeground: true)
    try validateExpectedWindow(expectedWindow, current: parent)
    _ = try navigateTab(tabName, expectedWindow: parent.json)
    let selected = try verifySelectedTab(tabName)
    let geometry = CaptureGeometry(window: parent.bounds, roi: selected.0.roi,
                                   imageWidth: selected.0.imageWidth, imageHeight: selected.0.imageHeight)
    let target = try geometry.screenRect(for: selected.1)
    let popup = try openPopup(parent: parent, anchorFrame: target,
                              point: CGPoint(x: target.midX, y: target.midY))
    do {
        _ = try clickPopupItem(parent: parent, anchorFrame: target, popup: popup, labels: menuLabels)
    } catch let failure as NativeFailure {
        // 新增／改名 menu 僅開啟 dialog，尚未按確認鈕。
        throw forcingPhase(failure, "pre_commit")
    }
    Thread.sleep(forTimeInterval: 0.08)
    return (parent, try mutationDialog(parent: parent, parentWindow: parentWindow, oldValue: oldValue))
}

func completeMembership(_ tabName: String, expectedWindow: Any?) throws -> ChatScanResult {
    let identity = try navigateTab(tabName, expectedWindow: expectedWindow)
    let scan = try scanTabChats(expected: identity)
    guard scan.complete else {
        throw NativeFailure("INVENTORY_PARTIAL", "提交前後分類 membership 不完整", ["reasons": scan.reasons])
    }
    return scan
}

func executeCreateOrRename(_ change: TabChange, expectedWindow: Any?) throws -> [String: Any] {
    let isRename = change.action == .renameTab
    let anchor: String
    let newName: String
    var oldMembers: [String] = []
    if isRename {
        anchor = change.tabName!; newName = change.newName!
        oldMembers = try completeMembership(anchor, expectedWindow: expectedWindow).names.sorted()
    } else {
        let inventory = try scanFullTabInventory(maxPages: 20)
        guard inventory.complete, let selected = inventory.selectedTab ?? inventory.names.first else {
            throw NativeFailure("INVENTORY_PARTIAL", "新增前無完整分頁或 selected 錨點", ["phase": "pre_commit"])
        }
        anchor = selected; newName = change.name!
    }
    let opened = try openTabMutationDialog(tabName: anchor,
                                           menuLabels: isRename ? renameTabLabels : createTabLabels,
                                           oldValue: isRename ? anchor : nil,
                                           expectedWindow: expectedWindow)
    let clipboard = try pasteDialogValue(newName, evidence: opened.1, replacing: isRename)
    try revalidateDialogBeforeConfirm(opened.1, expectedValue: newName, parent: opened.0)
    var attempted = false
    do {
        attempted = true
        try perform(kAXPressAction, on: opened.1.confirm)
        Thread.sleep(forTimeInterval: 0.2)
        let after = try scanFullTabInventory(maxPages: 20)
        guard after.complete, after.names.filter({ $0 == newName }).count == 1 else {
            throw NativeFailure("READBACK_UNVERIFIED", "提交後新分類沒有唯一出現")
        }
        if isRename {
            guard !after.names.contains(anchor) else {
                throw NativeFailure("READBACK_UNVERIFIED", "提交後舊分類仍存在")
            }
            let newMembers = try completeMembership(newName, expectedWindow: after.identity.json).names.sorted()
            guard newMembers == oldMembers else {
                throw NativeFailure("READBACK_UNVERIFIED", "改名後聊天室 membership 未保持")
            }
        }
        return ["success": true, "action": change.action.rawValue,
                "readback": ["verified": true, "tabName": newName], "clipboard": clipboard]
    } catch let failure as NativeFailure {
        throw forcingPhase(failure, phaseAfterMutationAttempt(attempted, nestedPhase: failure.details["phase"] as? String) ?? "post_commit")
    }
}

func executeMoveOrRemove(_ change: TabChange, expectedWindow: Any?) throws -> [String: Any] {
    let source = change.sourceTab!, chat = change.chatName!
    let selected = try selectedChatRow(chat, tabName: source, expectedWindow: expectedWindow)
    let rowFrame = selected.1.frame!
    let popup = try openPopup(parent: selected.0, anchorFrame: rowFrame,
                              point: CGPoint(x: rowFrame.midX, y: rowFrame.midY))
    var attempted = false
    do {
        if change.action == .moveChat {
            do {
                _ = try clickPopupItem(parent: selected.0, anchorFrame: rowFrame,
                                       popup: popup, labels: moveChatLabels)
            } catch let failure as NativeFailure { throw forcingPhase(failure, "pre_commit") }
            let submenu = try waitForSearchPopup(parent: selected.0, fieldFrame: rowFrame)
            attempted = true
            _ = try clickPopupItem(parent: selected.0, anchorFrame: rowFrame,
                                   popup: submenu, labels: [change.destinationTab!])
        } else {
            attempted = true
            _ = try clickPopupItem(parent: selected.0, anchorFrame: rowFrame,
                                   popup: popup, labels: removeChatLabels)
        }
        Thread.sleep(forTimeInterval: 0.2)
        let sourceAfter = try completeMembership(source, expectedWindow: selected.0.json)
        guard !sourceAfter.names.contains(chat) else {
            throw NativeFailure("READBACK_UNVERIFIED", "提交後聊天室仍存在於來源分類")
        }
        let destination: String
        if change.action == .moveChat { destination = change.destinationTab! }
        else {
            let inventory = try scanFullTabInventory(maxPages: 20)
            let all = inventory.names.filter { ["全部", "All"].contains($0) }
            guard inventory.complete, all.count == 1 else {
                throw NativeFailure("READBACK_UNVERIFIED", "提交後無法唯一辨識非自訂清單")
            }
            destination = all[0]
        }
        let destinationAfter = try completeMembership(destination, expectedWindow: selected.0.json)
        guard destinationAfter.names.filter({ $0 == chat }).count == 1 else {
            throw NativeFailure("READBACK_UNVERIFIED", "提交後目的／非自訂清單沒有唯一聊天室")
        }
        // membership 與實際 selected row/header 必須交叉一致，不能只看清單文字。
        _ = try selectedChatRow(chat, tabName: destination, expectedWindow: selected.0.json)
        return ["success": true, "action": change.action.rawValue,
                "readback": ["verified": true, "sourceTab": source,
                             "destinationTab": destination, "chatName": chat]]
    } catch let failure as NativeFailure {
        let phase = phaseAfterMutationAttempt(attempted, nestedPhase: failure.details["phase"] as? String) ?? "pre_commit"
        throw forcingPhase(failure, phase)
    }
}

func executeTabChange(_ args: [String: Any]) throws -> [String: Any] {
    guard let rawChange = args["change"] as? [String: Any],
          let index = args["index"] as? NSNumber,
          CFGetTypeID(index) != CFBooleanGetTypeID(), index.doubleValue.isFinite,
          floor(index.doubleValue) == index.doubleValue, (0..<20).contains(index.intValue),
          let expectedFingerprint = args["itemFingerprint"] as? String,
          !expectedFingerprint.isEmpty, expectedFingerprint.count <= 256 else {
        throw NativeFailure("INVALID_ARGUMENT", "executeTabChange 參數格式不正確", ["phase": "pre_commit"])
    }
    do {
        let change = try parseTabChanges([rawChange])[0]
        let current = try previewTabChanges(["changes": [change.json]],
                                            predictedPrefixBase: index.intValue)
        guard current["canExecute"] as? Bool == true,
              let fingerprints = current["itemFingerprints"] as? [String],
              fingerprints == [expectedFingerprint],
              let window = current["expectedWindow"] as? [String: Any] else {
            throw NativeFailure("SNAPSHOT_CHANGED", "單項提交前身份／結構／容量證據已變更", ["phase": "pre_commit"])
        }
        let (_, _, _, identity) = try mainWindow(requireForeground: true)
        try validateExpectedWindow(args["expectedWindow"], current: identity)
        try validateExpectedWindow(window, current: identity)
        if change.action == .createTab || change.action == .renameTab {
            return try executeCreateOrRename(change, expectedWindow: window)
        }
        return try executeMoveOrRemove(change, expectedWindow: window)
    } catch let failure as NativeFailure {
        if failure.details["phase"] as? String == "post_commit" { throw failure }
        throw forcingPhase(failure, "pre_commit")
    }
}

func enforceLiveScope(_ request: Request) throws {
    guard let scope = request.liveScope else { return }
    if scope.kind == .global {
        let allowed: Set<String> = ["status", "processStatus", "accessibilityStatus",
                                    "activateLine", "selectGlobalAll", "observeGlobalAll",
                                    "readGlobalHistoryPage"]
        guard allowed.contains(request.name) else {
            throw NativeFailure("LIVE_SCOPE_DENIED", "global LIVE harness 不允許此 native command")
        }
        if request.name == "selectGlobalAll" || request.name == "observeGlobalAll" {
            guard request.args["chatName"] as? String == scope.chatName,
                  Set(request.args.keys) == ["chatName", "requestNonce", "expectedWindow"],
                  validHex(request.args["requestNonce"], count: 64) != nil,
                  validWindowState(request.args["expectedWindow"]) != nil else {
                throw NativeFailure("LIVE_SCOPE_DENIED", "global LIVE All command 必須綁定 exact 聊天室、nonce 與主視窗")
            }
        } else if request.name == "readGlobalHistoryPage" {
            guard request.args["chatName"] as? String == scope.chatName,
                  ((request.args["resultIndex"] as? NSNumber)?.intValue == scope.resultIndex ||
                   (request.args["resultIndex"] == nil && scope.resultIndex == nil)) else {
                throw NativeFailure("LIVE_SCOPE_DENIED", "global LIVE harness 必須綁定 exact 聊天室")
            }
            do { _ = try parseHistoryArguments(request.args, mode: .global) }
            catch {
                throw NativeFailure("LIVE_SCOPE_DENIED", "global LIVE harness 參數格式不正確")
            }
        } else if !request.args.isEmpty {
            throw NativeFailure("LIVE_SCOPE_DENIED", "global LIVE status command 不接受參數")
        }
        try validateArgs(request)
        return
    }
    guard let tabName = scope.tabName else {
        throw NativeFailure("LIVE_SCOPE_DENIED", "legacy LIVE scope 缺少 tabName")
    }
    let allowed: Set<String> = ["status", "processStatus", "accessibilityStatus", "activateLine", "listTabs",
                                "listTabChats", "selectChat", "getHistory", "readHistoryPage",
                                "probeReadChatTitles", "probeAXReadScope",
                                "prepareTextExportScope", "exportChatText"]
    guard allowed.contains(request.name) else {
        throw NativeFailure("LIVE_SCOPE_DENIED", "LIVE harness 不允許此 native command")
    }
    if request.name == "selectChat" || request.name == "getHistory" || request.name == "readHistoryPage" ||
        request.name == "probeReadChatTitles" || request.name == "probeAXReadScope" ||
        request.name == "prepareTextExportScope" || request.name == "exportChatText" {
        guard request.args["tabName"] as? String == tabName,
              request.args["chatName"] as? String == scope.chatName else {
            throw NativeFailure("LIVE_SCOPE_DENIED", "LIVE harness 必須綁定 exact 分頁與聊天室")
        }
    }
    if request.name == "probeReadChatTitles" || request.name == "probeAXReadScope",
       Set(request.args.keys) != Set(["tabName", "chatName"]) {
        throw NativeFailure("LIVE_SCOPE_DENIED", "唯讀探針只接受 exact scope 參數")
    }
    if (request.name == "prepareTextExportScope" || request.name == "exportChatText") &&
       !validTextExportArguments(request.name, request.args) {
        throw NativeFailure("LIVE_SCOPE_DENIED", "LIVE 原生匯出必須使用 exact scope 與受限內部參數")
    }
    if request.name == "listTabChats" {
        let keys = Set(request.args.keys)
        guard keys.isSubset(of: Set(["tabName", "limit", "offset", "expectedDigest"])),
              request.args["tabName"] as? String == tabName,
              let limit = request.args["limit"] as? NSNumber,
              CFGetTypeID(limit) != CFBooleanGetTypeID(), limit.doubleValue.isFinite,
              floor(limit.doubleValue) == limit.doubleValue, (1...100).contains(limit.intValue),
              let offset = request.args["offset"] as? NSNumber,
              CFGetTypeID(offset) != CFBooleanGetTypeID(), offset.doubleValue.isFinite,
              floor(offset.doubleValue) == offset.doubleValue, (0...1000).contains(offset.intValue) else {
            throw NativeFailure("LIVE_SCOPE_DENIED", "LIVE harness 分頁盤點必須綁定 exact scope 與有界 metadata")
        }
        if let digest = request.args["expectedDigest"] {
            guard let value = digest as? String, value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
                throw NativeFailure("LIVE_SCOPE_DENIED", "LIVE harness expectedDigest 格式不正確")
            }
        }
    }
    // scoped request 的純參數 schema 必須先於 disable/compile/OS gate。
    try validateArgs(request)
}

func validateArgs(_ request: Request) throws {
    let allowed: [String: Set<String>] = [
        "diagnostics": [], "status": [], "processStatus": [], "accessibilityStatus": [], "activateLine": [],
        "listTabs": ["maxPages"], "listTabChats": ["tabName", "limit", "offset", "expectedDigest", "expectedWindow"],
        "previewMarkTabRead": ["tabName"], "snapshotMarkTabRead": ["tabName", "expectedWindow"],
        "executeMarkTabRead": ["tabName", "snapshotDigest", "expectedWindow"],
        "previewTabChanges": ["changes"],
        "snapshotTabChanges": ["changes", "expectedWindow", "itemFingerprints"],
        "executeTabChange": ["change", "index", "expectedWindow", "itemFingerprint"],
        "selectChat": ["tabName", "chatName"],
        "getHistory": ["tabName", "chatName", "date", "limit", "pageUpTimes"],
        "readHistoryPage": ["tabName", "chatName", "limit", "identityKey", "nativeState"],
        "selectGlobalAll": ["chatName", "requestNonce", "expectedWindow"],
        "observeGlobalAll": ["chatName", "requestNonce", "expectedWindow"],
        "readGlobalHistoryPage": ["chatName", "resultIndex", "limit", "identityKey", "nativeState"],
        "probeReadChatTitles": ["tabName", "chatName"],
        "probeAXReadScope": ["tabName", "chatName"],
        "prepareTextExportScope": ["tabName", "chatName", "identityKey", "requestNonce"],
        "exportChatText": ["tabName", "chatName", "identityKey", "requestNonce",
                           "expectedProofDigest", "outputDirectory", "outputFileName"],
        "inspectImageTarget": ["chatName"],
        "inspectImage": ["imagePath", "imageSha256"],
        "sendImage": ["chatName", "imagePath", "imageSha256", "autoSend"],
        "sendFile": ["chatName", "filePath", "fileSha256"],
        "inspectFile": ["filePath", "fileSha256"],
        "sendMessage": ["tabName", "chatName", "message", "autoSend"], "selfTest": [],
    ]
    if let keys = allowed[request.name], !Set(request.args.keys).isSubset(of: keys) {
        throw NativeFailure("INVALID_ARGUMENT", "native command 含有未知參數")
    }
    for key in ["tabName", "chatName"] where request.args[key] != nil {
        guard validName(request.args[key]) != nil else { throw NativeFailure("INVALID_ARGUMENT", "\(key) 格式不正確") }
    }
    if request.name == "sendImage", !imageSendArgumentsValid(request.args) {
        throw NativeFailure("INVALID_ARGUMENT", "圖片傳送參數格式不正確", ["phase": "pre_commit"])
    }
    if request.name == "inspectImage", !imageSendArgumentsValid(
        request.args.merging(["chatName": "合成圖片檢查", "autoSend": false]) { _, new in new }
    ) {
        throw NativeFailure("INVALID_ARGUMENT", "圖片檢查參數格式不正確")
    }
    if request.name == "prepareTextExportScope" || request.name == "exportChatText" {
        guard validTextExportArguments(request.name, request.args) else {
            throw NativeFailure("INVALID_ARGUMENT", "原生文字匯出參數格式不正確",
                                ["sideEffectsAttempted": false])
        }
    }
    if request.name == "selectGlobalAll" || request.name == "observeGlobalAll" {
        guard Set(request.args.keys) == ["chatName", "requestNonce", "expectedWindow"],
              validName(request.args["chatName"]) != nil,
              validHex(request.args["requestNonce"], count: 64) != nil,
              validWindowState(request.args["expectedWindow"]) != nil else {
            throw NativeFailure("INVALID_ARGUMENT", "global All command 參數格式不正確")
        }
    }
    if let rawPages = request.args["pageUpTimes"] {
        guard let pages = rawPages as? NSNumber,
              CFGetTypeID(pages) != CFBooleanGetTypeID(), pages.doubleValue.isFinite,
              floor(pages.doubleValue) == pages.doubleValue,
              pages.intValue >= 0, pages.intValue <= 100 else {
            throw NativeFailure("INVALID_ARGUMENT", "pageUpTimes 必須是 0 到 100 的整數")
        }
    }
}

struct RowProbe { let elementID: Int; let parentElementID: Int?; let name: String }

func deduplicateRowProbes(_ rows: [RowProbe]) -> [RowProbe] {
    var seen = Set<Int>()
    return rows.filter { seen.insert($0.elementID).inserted }
}

func mergeSyntheticScanPages(_ pages: [[(String, String)]]) -> [String] {
    var seen = Set<String>(), names: [String] = []
    for page in pages {
        for (identifier, name) in page where seen.insert(identifier).inserted { names.append(name) }
    }
    return names
}

struct DialogFieldProbe {
    let role: String
    let subrole: String
    let enabled: Bool
    let value: String
    let isDialogDescendant: Bool
}

func syntheticDialogField(_ fields: [DialogFieldProbe], oldValue: String?) -> Int? {
    let matches = fields.indices.filter { index in
        let field = fields[index]
        guard field.role == kAXTextFieldRole, field.subrole != kAXSearchFieldSubrole,
              field.enabled, field.isDialogDescendant else { return false }
        return oldValue == nil ? field.value.isEmpty : field.value == oldValue
    }
    return matches.count == 1 ? matches[0] : nil
}

func popupBindingAllowed(parentWindowID: Int, expectedParentWindowID: Int,
                         rowAnchor: CGRect, currentRowAnchor: CGRect,
                         stale: Bool) -> Bool {
    !stale && parentWindowID == expectedParentWindowID &&
        similar(rowAnchor, currentRowAnchor, tolerance: 0.5)
}

func mutationLabel(_ allowed: [String], observed: [String]) -> String? {
    guard !observed.contains(where: { dangerousMutationLabels.contains($0) && allowed.contains($0) }) else {
        return nil
    }
    return exactUniqueLabel(allowed, in: observed)
}

func membershipReadbackVerified(sourceBefore: [String], sourceAfter: [String],
                                destinationBefore: [String], destinationAfter: [String],
                                chat: String) -> Bool {
    sourceBefore.filter { $0 == chat }.count == 1 && !destinationBefore.contains(chat) &&
        !sourceAfter.contains(chat) && destinationAfter.filter { $0 == chat }.count == 1
}

func tabChangesRejected(_ raw: [[String: Any]]) -> Bool {
    do { _ = try parseTabChanges(raw); return false }
    catch is NativeFailure { return true }
    catch { return false }
}

func refinementSourceAuthorizesIdentity(_ source: String, target: String) -> Bool {
    // 非 exact 來源一律需另有 badge 像素證據；目前尚未校正，因此 fail closed。
    source == target
}

func runSelfTests() throws -> [String: Any] {
    var checks: [String: Bool] = [:]
    let imageArgs: [String: Any] = ["chatName": "合成對話", "imagePath": "/tmp/synthetic.png",
                                   "imageSha256": String(repeating: "a", count: 64), "autoSend": false]
    let fileArgs: [String: Any] = ["chatName": "Synthetic", "filePath": "/tmp/synthetic.txt",
                                   "fileSha256": String(repeating: "a", count: 64)]
    checks["file-send-exact-args"] = fileSendArgumentsValid(fileArgs)
    var invalidFileArgs = fileArgs; invalidFileArgs["autoSend"] = false
    checks["file-send-unknown-denied"] = !fileSendArgumentsValid(invalidFileArgs)
    checks["file-info-name-canonical"] = fileInfoNameMatches("synthetic.txt\nPlain text", expected: "synthetic.txt") &&
        !fileInfoNameMatches("synthetic.txt.extra\nPlain text", expected: "synthetic.txt") &&
        fileInfoNameMatches("cafe\u{301}.txt\nPlain text", expected: "caf\u{E9}.txt")
    checks["image-send-exact-args"] = imageSendArgumentsValid(imageArgs)
    checks["image-sheet-owned-chain"] = imageSendSheetIndex(roots: ["open-panel"], nested: [], requested: "open-panel") == 0 &&
        imageSendSheetIndex(roots: ["open-panel"], nested: ["GoToWindow"], requested: "GoToWindow") == 1
    checks["image-sheet-duplicate-foreign-denied"] = imageSendSheetIndex(roots: ["open-panel", "open-panel"], nested: [], requested: "open-panel") == nil &&
        imageSendSheetIndex(roots: ["GoToWindow"], nested: [], requested: "GoToWindow") == nil &&
        imageSendSheetIndex(roots: ["open-panel"], nested: ["other"], requested: "GoToWindow") == nil
    checks["image-sheet-background-control-denied"] = imageSendSheetIndex(roots: ["open-panel"], nested: ["GoToWindow"], requested: "open-panel") == nil &&
        imageSendSheetIndex(roots: ["open-panel"], nested: ["GoToWindow", "GoToWindow"], requested: "GoToWindow") == nil
    checks["image-goto-selected-path-ready"] = imageSendGoToReady(field: "/var/folders/test.png",
        candidates: ["/private/var/folders/test.png"], selected: [true], expected: "/private/var/folders/test.png") &&
        imageSendGoToReady(field: "/var/folders/test.png", candidates: ["/private/var/folders/test.png"],
                          selected: [true], expected: "/var/folders/test.png")
    var imageSelectionCalls = 0, imageSelectionPauses = 0
    let imageSelectionValue: Int = try settledImageSendSelection(clock: { 0 }, observe: {
        imageSelectionCalls += 1
        if imageSelectionCalls == 1 { throw NativeFailure("IMAGE_SELECTION_UNVERIFIED", "synthetic loading") }
        return 7
    }, pause: { imageSelectionPauses += 1 })
    checks["image-selection-transient-waits-without-input"] = imageSelectionValue == 7 &&
        imageSelectionCalls == 2 && imageSelectionPauses == 1
    var imageFatalCalls = 0
    do {
        let _: Int = try settledImageSendSelection(clock: { 0 }, observe: {
            imageFatalCalls += 1; throw NativeFailure("WINDOW_CHANGED", "synthetic drift")
        }, pause: {})
        checks["image-selection-drift-no-retry"] = false
    } catch let failure as NativeFailure {
        checks["image-selection-drift-no-retry"] = failure.code == "WINDOW_CHANGED" && imageFatalCalls == 1
    }
    var imageBudgetCalls = 0
    do {
        let _: Int = try settledImageSendSelection(clock: { 0 }, observe: {
            imageBudgetCalls += 1; throw NativeFailure("IMAGE_SELECTION_UNVERIFIED", "synthetic loading")
        }, pause: {})
        checks["image-selection-probe-budget-bounded"] = false
    } catch let failure as NativeFailure {
        checks["image-selection-probe-budget-bounded"] = failure.code == "IMAGE_SELECTION_UNVERIFIED" && imageBudgetCalls == 30
    }
    checks["image-goto-unready-foreign-denied"] = !imageSendGoToReady(field: "/private/var/folders/test.png",
        candidates: [], selected: [], expected: "/private/var/folders/test.png") &&
        !imageSendGoToReady(field: "/tmp/other.png", candidates: ["/private/var/folders/test.png"],
                          selected: [true], expected: "/private/var/folders/test.png") &&
        !imageSendGoToReady(field: "/private/var/folders/test.png", candidates: ["/private/var/folders/test.png"],
                          selected: [false], expected: "/private/var/folders/test.png")
    var numericImageArgs = imageArgs; numericImageArgs["autoSend"] = 1
    var relativeImageArgs = imageArgs; relativeImageArgs["imagePath"] = "relative.png"
    var extraImageArgs = imageArgs; extraImageArgs["extra"] = true
    checks["image-send-invalid-args"] = !imageSendArgumentsValid(numericImageArgs) &&
        !imageSendArgumentsValid(relativeImageArgs) && !imageSendArgumentsValid(extraImageArgs)
    checks["image-send-dimension-budget"] = imageSendDimensionsAllowed(640, 360) &&
        !imageSendDimensionsAllowed(0, 1) && !imageSendDimensionsAllowed(8193, 1) &&
        !imageSendDimensionsAllowed(8192, 8192)
    func solidRGBA(_ value: UInt8, alpha: UInt8 = 255,
                   width: Int = 4, height: Int = 4) -> [UInt8] {
        Array(repeating: [value, value, value, alpha], count: width * height).flatMap { $0 }
    }
    func profileAt(_ value: UInt8) -> ReadColorProfile? {
        readColorProfile(solidRGBA(value), width: 4, height: 4, bytesPerRow: 16)
    }
    checks["readprofile-boundary-079-dark"] = profileAt(79) == .dark
    checks["readprofile-boundary-080-dark"] = profileAt(80) == .dark
    checks["readprofile-boundary-081-rejected"] = profileAt(81) == nil
    checks["readprofile-boundary-179-rejected"] = profileAt(179) == nil
    checks["readprofile-boundary-180-light"] = profileAt(180) == .light
    checks["readprofile-boundary-181-light"] = profileAt(181) == .light
    checks["readprofile-alpha-rejected"] = readColorProfile(
        solidRGBA(20, alpha: 254), width: 4, height: 4, bytesPerRow: 16
    ) == nil
    checks["readprofile-size-rejected"] =
        readColorProfile(solidRGBA(20), width: 4, height: 4, bytesPerRow: 15) == nil &&
        readColorProfile([], width: 0, height: 4, bytesPerRow: 0) == nil &&
        !validReadROIShape(width: processedOCRMaxDimension + 1, height: 1) &&
        !validReadROIShape(width: Int.max, height: 2)
    checks["readprofile-drift-rejected"] =
        stableReadColorProfile(.dark, .dark) && !stableReadColorProfile(.dark, .light)
    let lightImage = rgbaImage(topDown: solidRGBA(220), width: 4, height: 4)!
    let darkImage = rgbaImage(topDown: solidRGBA(20), width: 4, height: 4)!
    let lightCanonical = try canonicalReadROI(lightImage)
    let darkCanonical = try canonicalReadROI(darkImage)
    let lightLuma = try imageLuma(lightCanonical.image)
    let darkLuma = try imageLuma(darkCanonical.image)
    checks["readprofile-light-identity"] = lightCanonical.profile == .light &&
        lightLuma.allSatisfy { $0 == 220 }
    checks["readprofile-dark-inversion"] = darkCanonical.profile == .dark &&
        darkLuma.allSatisfy { $0 == 235 }
    do {
        _ = try canonicalReadROI(darkImage, requiredProfile: .light)
        checks["readprofile-required-mismatch-rejected"] = false
    } catch let failure as NativeFailure {
        checks["readprofile-required-mismatch-rejected"] = failure.code == "UNSUPPORTED_COLOR_PROFILE"
    }
    func syntheticLuma(title: Bool, preview: Bool, secondTitle: Bool = false) -> [UInt8] {
        let width = 302, height = 71
        var pixels = [UInt8](repeating: 245, count: width * height)
        func ink(_ x: Range<Int>, _ y: Range<Int>) {
            for row in y { for column in x { pixels[row * width + column] = 35 } }
        }
        if title { ink(80..<165, 10..<22) }
        if secondTitle { ink(80..<150, 25..<35) }
        if preview { ink(80..<195, 42..<50) }
        return pixels
    }
    let isolatedBand = titleBandCrop(luma: syntheticLuma(title: true, preview: true),
                                     width: 302, height: 71, scale: 1)
    checks["nameband-title-preview-crop-excludes-preview"] = isolatedBand.map { $0.maxY < 42 } == true
    checks["nameband-missing-title-does-not-use-preview"] = titleBandCrop(
        luma: syntheticLuma(title: false, preview: true), width: 302, height: 71, scale: 1
    ) == nil
    checks["nameband-multiline-title-rejected"] = titleBandCrop(
        luma: syntheticLuma(title: true, preview: false, secondTitle: true),
        width: 302, height: 71, scale: 1
    ) == nil
    let syntheticTopDown = syntheticLuma(title: true, preview: true).flatMap {
        [$0, $0, $0, UInt8(255)]
    }
    if let syntheticImage = rgbaImage(topDown: syntheticTopDown, width: 302, height: 71) {
        let crop = titleBandCrop(luma: try imageLuma(syntheticImage), width: 302, height: 71, scale: 1)
        checks["nameband-cgimage-topdown-privacy"] = crop.map { $0.minY < 10 && $0.maxY < 42 } == true
    } else { checks["nameband-cgimage-topdown-privacy"] = false }
    func darkRow(title: Bool, preview: Bool) -> CGImage? {
        let width = 302, height = 71
        var pixels = solidRGBA(20, width: width, height: height)
        func ink(_ x: Range<Int>, _ y: Range<Int>, value: UInt8) {
            for row in y { for column in x {
                let offset = (row * width + column) * 4
                pixels[offset] = value; pixels[offset + 1] = value; pixels[offset + 2] = value
            } }
        }
        if title { ink(80..<165, 10..<22, value: 220) }
        if preview { ink(80..<195, 42..<50, value: 180) }
        return rgbaImage(topDown: pixels, width: width, height: height)
    }
    if let darkTitle = darkRow(title: true, preview: true),
       let darkPreviewOnly = darkRow(title: false, preview: true) {
        let titleCanonical = try canonicalReadROI(darkTitle)
        let previewCanonical = try canonicalReadROI(darkPreviewOnly)
        let titleCrop = titleBandCrop(luma: try imageLuma(titleCanonical.image),
                                      width: 302, height: 71, scale: 1)
        checks["nameband-dark-title-preview-crop-excludes-preview"] =
            titleCanonical.profile == .dark && titleCrop.map { $0.maxY < 42 } == true
        checks["nameband-dark-missing-title-does-not-use-preview"] = titleBandCrop(
            luma: try imageLuma(previewCanonical.image), width: 302, height: 71, scale: 1
        ) == nil
    } else {
        checks["nameband-dark-title-preview-crop-excludes-preview"] = false
        checks["nameband-dark-missing-title-does-not-use-preview"] = false
    }
    var darkTabPixels = solidRGBA(20, width: 200, height: 40)
    for y in 36..<38 { for x in 40..<140 {
        let offset = (y * 200 + x) * 4
        darkTabPixels[offset] = 255; darkTabPixels[offset + 1] = 255; darkTabPixels[offset + 2] = 255
    } }
    let darkTabImage = rgbaImage(topDown: darkTabPixels, width: 200, height: 40)!
    let darkTabCanonical = try canonicalReadROI(darkTabImage)
    let whiteUnderline = try underlineComponentsROI(darkTabCanonical.image, scaleX: 1, scaleY: 1)
    checks["readprofile-white-selected-underline"] = darkTabCanonical.profile == .dark &&
        whiteUnderline.filter { eligibleUnderline($0, roiHeight: 40) }.count == 1
    var lightTabPixels = solidRGBA(220, width: 200, height: 40)
    for y in 36..<38 { for x in 40..<140 {
        let offset = (y * 200 + x) * 4
        lightTabPixels[offset] = 0; lightTabPixels[offset + 1] = 0; lightTabPixels[offset + 2] = 0
    } }
    let lightTabImage = rgbaImage(topDown: lightTabPixels, width: 200, height: 40)!
    let lightTabCanonical = try canonicalReadROI(lightTabImage)
    let blackUnderline = try underlineComponentsROI(lightTabCanonical.image, scaleX: 1, scaleY: 1)
    let safeName = OCRCandidate(text: "Synthetic room", confidence: 0.96,
                                normalizedBox: CGRect(x: 0.05, y: 0.15, width: 0.50, height: 0.70))
    let safeTime = OCRCandidate(text: "下午 2:05", confidence: 0.99,
                                normalizedBox: CGRect(x: 0.75, y: 0.15, width: 0.20, height: 0.70))
    checks["nameband-unique-name-timestamp-accepted"] =
        verifiedNameCandidate([safeName, safeTime])?.text == safeName.text
    checks["nameband-duplicate-rejected"] = verifiedNameCandidate([safeName, safeName]) == nil
    checks["nameband-right-duplicate-rejected"] = verifiedNameCandidate([
        safeName, OCRCandidate(text: safeName.text, confidence: 0.99,
                               normalizedBox: CGRect(x: 0.55, y: 0.15, width: 0.35, height: 0.70))
    ]) == nil
    checks["nameband-ellipsis-rejected"] = verifiedNameCandidate([
        OCRCandidate(text: "Synthetic…", confidence: 0.99, normalizedBox: safeName.normalizedBox)
    ]) == nil
    checks["nameband-crop-edge-rejected"] = verifiedNameCandidate([
        OCRCandidate(text: "Synthetic room", confidence: 0.99,
                     normalizedBox: CGRect(x: 0, y: 0.15, width: 0.5, height: 0.7))
    ]) == nil
    checks["nameband-low-confidence-not-passable"] = verifiedNameCandidate([
        OCRCandidate(text: safeName.text, confidence: 0.949,
                     normalizedBox: safeName.normalizedBox)
    ]) == nil
    let parsedRenderer = parseRendererLabel("Family (old)（123）")
    checks["renderer-last-count-prefix-preserved"] = parsedRenderer?.prefix == "Family (old)" &&
        parsedRenderer?.observedParenthesizedCount == 123 &&
        parsedRenderer?.countToken == "（123）"
    let parsedSuffix = parseRendererLabel("Family (old)（123） 以 ")
    checks["renderer-raw-suffix-parsed"] = parsedSuffix?.prefix == "Family (old)" &&
        parsedSuffix?.rawSuffix == "以" && parsedSuffix?.suffixRange != nil
    checks["renderer-mismatched-brackets-rejected"] = parseRendererLabel("Family（12)") == nil
    checks["renderer-suffix-rejected"] = parseRendererLabel("Family (12) xy") == nil &&
        parseRendererLabel("Family (12)…") == nil
    checks["renderer-count-equivalence"] = equivalentCountToken("（12）", "(12)", expected: 12) &&
        !equivalentCountToken("(12)", "(13)", expected: 12)
    checks["renderer-component-endpoints"] = strictRendererComponentsAllowed(
        nameConfidence: 0.95, countConfidence: 0.95,
        prefixMatches: true, countMatches: true,
        nameSourceCoverage: true, countSourceCoverage: true,
        finalGapPixels: 2, requiredGapPixels: 2
    ) && !strictRendererComponentsAllowed(
        nameConfidence: 0.949, countConfidence: 0.95,
        prefixMatches: true, countMatches: true,
        nameSourceCoverage: true, countSourceCoverage: true,
        finalGapPixels: 2, requiredGapPixels: 2
    ) && !strictRendererComponentsAllowed(
        nameConfidence: 0.95, countConfidence: 0.95,
        prefixMatches: true, countMatches: true,
        nameSourceCoverage: false, countSourceCoverage: true,
        finalGapPixels: 2, requiredGapPixels: 2
    )
    checks["renderer-prefix-mismatch-rejected"] = !strictRendererComponentsAllowed(
        nameConfidence: 0.99, countConfidence: 0.99,
        prefixMatches: false, countMatches: true,
        nameSourceCoverage: true, countSourceCoverage: true,
        finalGapPixels: 2, requiredGapPixels: 2
    )
    checks["renderer-count-not-capacity"] = parsedRenderer?.observedParenthesizedCount == 123
    let rendererSource = CGRect(x: 0.05, y: 0.2, width: 0.55, height: 0.5)
    let rendererName = CGRect(x: 0.06, y: 0.22, width: 0.30, height: 0.42)
    let rendererCount = CGRect(x: 0.37, y: 0.22, width: 0.10, height: 0.42)
    let allowedGap = rendererGeometryAllowed(name: rendererName, count: rendererCount,
                                             source: rendererSource, scale: 2,
                                             imageWidth: 200)
    let deniedGap = rendererGeometryAllowed(
        name: rendererName,
        count: CGRect(x: rendererName.maxX, y: 0.40, width: 0.10, height: 0.42),
        source: rendererSource, scale: 2, imageWidth: 200
    )
    checks["renderer-geometry-gap-endpoints"] = allowedGap && !deniedGap
    let epsilonSource = CGRect(x: rendererName.minX + 0.000000001,
                               y: rendererName.minY + 0.000000001,
                               width: rendererCount.maxX - rendererName.minX - 0.000000002,
                               height: rendererName.height - 0.000000002)
    checks["renderer-source-epsilon"] = rendererGeometryAllowed(
        name: rendererName, count: rendererCount, source: epsilonSource,
        scale: 2, imageWidth: 200
    )
    let quarterPixelOverlap = CGRect(x: rendererName.maxX - 0.25 / 200,
                                     y: rendererCount.minY,
                                     width: rendererCount.width,
                                     height: rendererCount.height)
    let overOnePixelOverlap = CGRect(x: rendererName.maxX - 1.01 / 200,
                                     y: rendererCount.minY,
                                     width: rendererCount.width,
                                     height: rendererCount.height)
    checks["renderer-coarse-overlap-one-pixel"] = rendererGeometryAllowed(
        name: rendererName, count: quarterPixelOverlap, source: rendererSource,
        scale: 2, imageWidth: 200
    ) && !rendererGeometryAllowed(
        name: rendererName, count: overOnePixelOverlap, source: rendererSource,
        scale: 2, imageWidth: 200
    )
    checks["renderer-aux-gap23-rejected"] = auxiliaryPixelVerdict(
        widthPoints: 12, heightPoints: 15, pixelCount: 270, pixelArea: 744,
        darkest: 55, nameCountDarkest: 32, background: 209,
        maximumChannelSpread: 4, opaque: true
    ) == .rejected
    checks["renderer-aux-gap24-accepted"] = auxiliaryPixelVerdict(
        widthPoints: 12, heightPoints: 15, pixelCount: 270, pixelArea: 744,
        darkest: 56, nameCountDarkest: 32, background: 209,
        maximumChannelSpread: 4, opaque: true
    ) == .observed
    checks["renderer-aux-color-rejected"] = auxiliaryPixelVerdict(
        widthPoints: 12, heightPoints: 15, pixelCount: 270, pixelArea: 744,
        darkest: 72, nameCountDarkest: 32, background: 209,
        maximumChannelSpread: 13, opaque: true
    ) == .rejected
    checks["renderer-aux-dark-rejected"] = auxiliaryPixelVerdict(
        widthPoints: 12, heightPoints: 15, pixelCount: 270, pixelArea: 744,
        darkest: 50, nameCountDarkest: 32, background: 209,
        maximumChannelSpread: 4, opaque: true
    ) == .rejected
    checks["renderer-two-part-aux-accepted"] = auxiliaryComponentVerdict(
        componentCount: 2, widthPoints: 12, heightPoints: 15,
        pixelCount: 261, pixelArea: 744, darkest: 72,
        nameCountDarkest: 32, background: 209,
        maximumChannelSpread: 4, opaque: true
    ) == .observed
    checks["renderer-three-part-aux-rejected"] = auxiliaryComponentVerdict(
        componentCount: 3, widthPoints: 12, heightPoints: 15,
        pixelCount: 261, pixelArea: 744, darkest: 72,
        nameCountDarkest: 32, background: 209,
        maximumChannelSpread: 4, opaque: true
    ) == .rejected
    checks["renderer-suffix-requires-pixels"] =
        !rendererSuffixPixelAllowed(rawSuffix: "以", verdict: .absent) &&
        rendererSuffixPixelAllowed(rawSuffix: "以", verdict: .observed) &&
        rendererSuffixPixelAllowed(rawSuffix: nil, verdict: .absent)
    checks["renderer-decoded-gap-rejected"] = !strictRendererComponentsAllowed(
        nameConfidence: 0.99, countConfidence: 0.99,
        prefixMatches: true, countMatches: true,
        nameSourceCoverage: true, countSourceCoverage: true,
        finalGapPixels: 1.99, requiredGapPixels: 2
    )
    var rendererPixels = [UInt8](repeating: 209, count: 140 * 40 * 4)
    for index in stride(from: 3, to: rendererPixels.count, by: 4) { rendererPixels[index] = 255 }
    func fillRendererRect(_ rect: CGRect, value: UInt8,
                          where include: (Int, Int) -> Bool = { _, _ in true }) {
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) where include(x, y) {
                let offset = (y * 140 + x) * 4
                rendererPixels[offset] = value; rendererPixels[offset + 1] = value
                rendererPixels[offset + 2] = value
            }
        }
    }
    fillRendererRect(CGRect(x: 10, y: 5, width: 40, height: 30), value: 32)
    fillRendererRect(CGRect(x: 60, y: 5, width: 10, height: 30), value: 32)
    fillRendererRect(CGRect(x: 80, y: 5, width: 24, height: 30), value: 72) {
        ($0 + $1) % 2 == 0
    }
    if let rendererImage = rgbaImage(topDown: rendererPixels, width: 140, height: 40) {
        func rendererNormalized(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX / 140, y: 1 - rect.maxY / 40,
                   width: rect.width / 140, height: rect.height / 40)
        }
        checks["renderer-cgimage-aux-isolated"] = try grayAuxiliaryEvidence(
            rendererImage,
            countBox: rendererNormalized(CGRect(x: 60, y: 5, width: 10, height: 30)),
            sourceBox: rendererNormalized(CGRect(x: 10, y: 5, width: 75, height: 30)),
            suffixBox: nil, otherBoxes: [], scale: 2, nameCountDarkest: 32
        ) == .observed
        let mutual = paddedPixelCrop(
            rendererNormalized(CGRect(x: 60, y: 5, width: 10, height: 30)),
            image: rendererImage, minimumX: 51, maximumX: 79
        )
        checks["renderer-mutual-crop-boundaries"] = mutual.map {
            $0.1.minX >= 51 && $0.1.maxX <= 79 && $0.1.width > 0
        } == true
    } else { checks["renderer-cgimage-aux-isolated"] = false }
    func fieldImage(_ mutate: (inout [UInt8], Int) -> Void = { _, _ in }) -> CGImage? {
        let width = 20, height = 12
        var pixels = [UInt8](repeating: 220, count: width * height * 4)
        for index in stride(from: 3, to: pixels.count, by: 4) { pixels[index] = 255 }
        for y in 3..<9 { for x in 5..<15 {
            let offset = (y * width + x) * 4
            pixels[offset] = 32; pixels[offset + 1] = 32; pixels[offset + 2] = 32
        } }
        mutate(&pixels, width)
        return rgbaImage(topDown: pixels, width: width, height: height)
    }
    func sparseFieldImage(_ strongPoints: [(Int, Int)]) -> CGImage? {
        let width = 20, height = 12
        var pixels = [UInt8](repeating: 220, count: width * height * 4)
        for index in stride(from: 3, to: pixels.count, by: 4) { pixels[index] = 255 }
        for point in strongPoints {
            let offset = (point.1 * width + point.0) * 4
            pixels[offset] = 32; pixels[offset + 1] = 32; pixels[offset + 2] = 32
        }
        return rgbaImage(topDown: pixels, width: width, height: height)
    }
    func normalizedFieldRect(_ pixels: CGRect) -> CGRect {
        CGRect(x: pixels.minX / 20, y: 1 - pixels.maxY / 12,
               width: pixels.width / 20, height: pixels.height / 12)
    }
    let fieldOCRBox = CGRect(x: 4.5 / 20, y: 1 - 9.5 / 12,
                             width: 11 / 20, height: 7 / 12)
    let fieldGrapheme = CGRect(x: 0.25, y: 0.25, width: 0.50, height: 0.50)
    if let complete = fieldImage() {
        checks["renderer-pixel-complete-fixture"] = try rendererPixelGlyphBox(
            complete, ocrBox: fieldOCRBox, graphemeBoxes: [fieldGrapheme]
        ) == CGRect(x: 5, y: 3, width: 10, height: 6)
        checks["renderer-bbox-one-pixel-bounds"] = boundedOCRPixelRect(
            CGRect(x: -1 / 20, y: fieldOCRBox.minY,
                   width: fieldOCRBox.maxX + 1 / 20, height: fieldOCRBox.height),
            width: 20, height: 12
        ) != nil && boundedOCRPixelRect(
            CGRect(x: -1.01 / 20, y: fieldOCRBox.minY,
                   width: fieldOCRBox.maxX + 1.01 / 20, height: fieldOCRBox.height),
            width: 20, height: 12
        ) == nil
        checks["renderer-bbox-nonfinite-rejected"] = boundedOCRPixelRect(
            CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1),
            width: 20, height: 12
        ) == nil
    } else {
        checks["renderer-pixel-complete-fixture"] = false
        checks["renderer-bbox-one-pixel-bounds"] = false
        checks["renderer-bbox-nonfinite-rejected"] = false
    }
    if let borderInk = fieldImage({ pixels, width in
        let offset = (5 * width) * 4
        pixels[offset] = 32; pixels[offset + 1] = 32; pixels[offset + 2] = 32
    }) {
        checks["renderer-border-ink-rejected"] = try rendererPixelGlyphBox(
            borderInk, ocrBox: fieldOCRBox, graphemeBoxes: [fieldGrapheme]
        ) == nil
    } else { checks["renderer-border-ink-rejected"] = false }
    if let transparent = fieldImage({ pixels, width in
        pixels[(5 * width + 10) * 4 + 3] = 254
    }) {
        checks["renderer-transparent-rejected"] = try rendererPixelGlyphBox(
            transparent, ocrBox: fieldOCRBox, graphemeBoxes: [fieldGrapheme]
        ) == nil
    } else { checks["renderer-transparent-rejected"] = false }
    if let colored = fieldImage({ pixels, width in
        let offset = (5 * width + 10) * 4
        pixels[offset] = 200; pixels[offset + 1] = 20; pixels[offset + 2] = 20
    }) {
        checks["renderer-colored-rejected"] = try rendererPixelGlyphBox(
            colored, ocrBox: fieldOCRBox, graphemeBoxes: [fieldGrapheme]
        ) == nil
    } else { checks["renderer-colored-rejected"] = false }
    let blankField = rgbaImage(topDown: Array(repeating: [UInt8(220), 220, 220, 255],
                                             count: 20 * 12).flatMap { $0 },
                               width: 20, height: 12)!
    checks["renderer-no-ink-rejected"] = try rendererPixelGlyphBox(
        blankField, ocrBox: fieldOCRBox, graphemeBoxes: [fieldGrapheme]
    ) == nil
    if let halo = fieldImage({ pixels, width in
        let offset = (5 * width + 15) * 4
        pixels[offset] = 215; pixels[offset + 1] = 215; pixels[offset + 2] = 215
    }) {
        let haloBox = CGRect(x: 0.25, y: 0.25, width: 0.55, height: 0.50)
        checks["renderer-attached-halo-accepted"] = try rendererPixelGlyphBox(
            halo, ocrBox: fieldOCRBox, graphemeBoxes: [haloBox]
        ) != nil
    } else { checks["renderer-attached-halo-accepted"] = false }
    if let weak = fieldImage({ pixels, width in
        let offset = (10 * width + 18) * 4
        pixels[offset] = 215; pixels[offset + 1] = 215; pixels[offset + 2] = 215
    }) {
        checks["renderer-independent-weak-rejected"] = try rendererPixelGlyphBox(
            weak, ocrBox: fieldOCRBox, graphemeBoxes: [fieldGrapheme]
        ) == nil
    } else {
        checks["renderer-independent-weak-rejected"] = false
    }
    if let gapDot = fieldImage({ pixels, width in
        let offset = (10 * width + 18) * 4
        pixels[offset] = 32; pixels[offset + 1] = 32; pixels[offset + 2] = 32
    }) {
        checks["renderer-gap-dot-rejected"] = try rendererPixelGlyphBox(
            gapDot, ocrBox: fieldOCRBox, graphemeBoxes: [fieldGrapheme]
        ) == nil
    } else { checks["renderer-gap-dot-rejected"] = false }
    if let weakBorder = fieldImage({ pixels, width in
        let offset = (5 * width) * 4
        pixels[offset] = 215; pixels[offset + 1] = 215; pixels[offset + 2] = 215
    }) {
        checks["renderer-weak-border-rejected"] = try rendererPixelGlyphBox(
            weakBorder, ocrBox: fieldOCRBox, graphemeBoxes: [fieldGrapheme]
        ) == nil
    } else { checks["renderer-weak-border-rejected"] = false }
    checks["renderer-grapheme-missing-rejected"] = !rendererGraphemeBoxesValid(
        text: "AB", boxes: [fieldGrapheme, nil]
    )
    if let missingInk = fieldImage({ pixels, width in
        for y in 3..<9 { for x in 10..<15 {
            let offset = (y * width + x) * 4
            pixels[offset] = 220; pixels[offset + 1] = 220; pixels[offset + 2] = 220
        } }
    }) {
        let leftGlyph = CGRect(x: 0.25, y: 0.25, width: 0.25, height: 0.50)
        let rightGlyph = CGRect(x: 0.55, y: 0.25, width: 0.20, height: 0.50)
        checks["renderer-grapheme-without-strong-rejected"] = try rendererPixelGlyphBox(
            missingInk, ocrBox: fieldOCRBox, graphemeBoxes: [leftGlyph, rightGlyph]
        ) == nil
    } else { checks["renderer-grapheme-without-strong-rejected"] = false }
    if let spaced = fieldImage({ pixels, width in
        for y in 3..<9 { for x in 9..<11 {
            let offset = (y * width + x) * 4
            pixels[offset] = 220; pixels[offset + 1] = 220; pixels[offset + 2] = 220
        } }
    }) {
        let leftGlyph = CGRect(x: 0.25, y: 0.25, width: 0.20, height: 0.50)
        let rightGlyph = CGRect(x: 0.55, y: 0.25, width: 0.20, height: 0.50)
        let spacedGlyph = try rendererPixelGlyphBox(
            spaced, ocrBox: fieldOCRBox, graphemeBoxes: [leftGlyph, nil, rightGlyph]
        )
        checks["renderer-grapheme-space-allowed"] = rendererGraphemeBoxesValid(
            text: "A B", boxes: [leftGlyph, nil, rightGlyph]
        ) && spacedGlyph != nil
    } else { checks["renderer-grapheme-space-allowed"] = false }
    let coverageActual = CGRect(x: 0.10, y: 0.20, width: 0.20, height: 0.30)
    checks["renderer-source-coverage-endpoints"] = actualGlyphCoverageAllowed(
        actual: coverageActual,
        coarse: CGRect(x: 0.11, y: 0.20, width: 0.19, height: 0.30),
        imageWidth: 100, imageHeight: 100
    ) && !actualGlyphCoverageAllowed(
        actual: coverageActual,
        coarse: CGRect(x: 0.1101, y: 0.20, width: 0.1899, height: 0.30),
        imageWidth: 100, imageHeight: 100
    )
    checks["renderer-count-language-fixed"] = rendererLanguages(.count) == ["en-US"] &&
        rendererLanguages(.nameOrTime) == ["zh-Hant", "en-US"]
    checks["renderer-count-low-confidence-rejected"] = !strictRendererComponentsAllowed(
        nameConfidence: 0.99, countConfidence: 0.949,
        prefixMatches: true, countMatches: true,
        nameSourceCoverage: true, countSourceCoverage: true,
        finalGapPixels: 2, requiredGapPixels: 2
    )
    if let fractional = sparseFieldImage([(3, 5), (5, 5)]) {
        checks["renderer-fractional-ownership-rejected"] = try rendererPixelGlyphBox(
            fractional,
            ocrBox: normalizedFieldRect(CGRect(x: 2, y: 3, width: 10, height: 5)),
            graphemeBoxes: [normalizedFieldRect(
                CGRect(x: 4.8, y: 4, width: 6, height: 3)
            )]
        ) == nil
    } else { checks["renderer-fractional-ownership-rejected"] = false }
    if let adjacent = sparseFieldImage([(8, 5), (9, 5)]) {
        checks["renderer-core-strong-required"] = try rendererPixelGlyphBox(
            adjacent,
            ocrBox: normalizedFieldRect(CGRect(x: 4, y: 3, width: 8, height: 5)),
            graphemeBoxes: [
                normalizedFieldRect(CGRect(x: 5, y: 4, width: 3, height: 3)),
                normalizedFieldRect(CGRect(x: 8, y: 4, width: 3, height: 3)),
            ]
        ) == nil
    } else { checks["renderer-core-strong-required"] = false }
    let literalParenthesized = OCRCandidate(text: "Literal (name)", confidence: 0.99,
                                            normalizedBox: safeName.normalizedBox)
    checks["renderer-literal-parentheses-not-rewritten"] =
        verifiedNameCandidate([literalParenthesized])?.text == "Literal (name)"
    let rendererEvidence = RendererRefinementEvidence(
        candidate: safeName, observedParenthesizedCount: 3,
        auxiliaryObserved: true, identityVerified: false
    )
    checks["renderer-identity-false-stable"] = stableRendererEvidence(
        rendererEvidence, rendererEvidence
    ) && !rendererEvidence.identityVerified
    let wholeLabel = OCRCandidate(text: "Synthetic room (3)", confidence: 0.99,
                                  normalizedBox: safeName.normalizedBox)
    checks["renderer-row-target-selects-refined"] = chooseRendererRowCandidate(
        literal: wholeLabel, renderer: rendererEvidence, target: "Synthetic room"
    )?.rendererChosen == true
    checks["renderer-row-literal-preserved"] = chooseRendererRowCandidate(
        literal: wholeLabel, renderer: rendererEvidence, target: "Synthetic room (3)"
    )?.rendererChosen == false
    let sameRenderer = RendererRefinementEvidence(
        candidate: wholeLabel, observedParenthesizedCount: 3,
        auxiliaryObserved: true, identityVerified: false
    )
    checks["renderer-row-same-text-dedup"] = chooseRendererRowCandidate(
        literal: wholeLabel, renderer: sameRenderer, target: wholeLabel.text
    )?.rendererChosen == false
    checks["uitime-yesterday-allowed"] = rendererUITimeText("昨天")
    checks["uitime-formats-bounded"] = rendererUITimeText("下午 2:05") &&
        rendererUITimeText("10月27日") && rendererUITimeText("10/27")
    checks["uitime-invalid-ranges"] = !rendererUITimeText("99:99") &&
        !rendererUITimeText("下午 13:00") && !rendererUITimeText("13月1日") &&
        !rendererUITimeText("2月32日") && rendererUITimeText("2月29日")
    checks["uitime-refinement-endpoints"] = strictUITimeRefinementAllowed(
        rawText: "昨天", refinedText: "昨天", refinedConfidence: 0.95, sourceCoverage: true
    ) && !strictUITimeRefinementAllowed(
        rawText: "昨天", refinedText: "昨天", refinedConfidence: 0.949, sourceCoverage: true
    ) && !strictUITimeRefinementAllowed(
        rawText: "昨天", refinedText: "昨日", refinedConfidence: 0.99, sourceCoverage: true
    ) && !strictUITimeRefinementAllowed(
        rawText: "昨天", refinedText: "昨天", refinedConfidence: 0.99, sourceCoverage: false
    )
    checks["uitime-unknown-rejected"] = !rendererUITimeText("剛剛") &&
        !rendererUITimeText("2026-10-27")
    let idleSearchFrame = CGRect(x: 615, y: 153, width: 244, height: 38)
    let idleListFrame = CGRect(x: 603, y: 198, width: 302, height: 537)
    checks["nameprobe-empty-idle-allowed"] = nameProbeIdleGeometryAllowed(
        searchFrame: idleSearchFrame, listFrame: idleListFrame, searchValue: ""
    )
    checks["nameprobe-active-overlap-rejected"] = !nameProbeIdleGeometryAllowed(
        searchFrame: idleSearchFrame,
        listFrame: CGRect(x: 603, y: 187, width: 302, height: 548), searchValue: ""
    )
    checks["nameprobe-nonempty-rejected"] = !nameProbeIdleGeometryAllowed(
        searchFrame: idleSearchFrame, listFrame: idleListFrame, searchValue: "query"
    )
    let window = CGRect(x: -900, y: 40, width: 900, height: 700)
    let roi = CGRect(x: -880, y: 90, width: 700, height: 40)
    let candidate = OCRCandidate(text: "Scope tab", confidence: 0.50,
                                 normalizedBox: CGRect(x: 0.25, y: 0.2, width: 0.2, height: 0.5))
    let processedCandidate = OCRCandidate(text: "Scope tab", confidence: 0.96,
                                          normalizedBox: candidate.normalizedBox)
    let one = CaptureGeometry(window: window, roi: roi, imageWidth: 900, imageHeight: 700)
    let two = CaptureGeometry(window: window, roi: roi, imageWidth: 1800, imageHeight: 1400)
    checks["geometry-1x-negative-roi-origin"] = try one.screenRect(for: candidate).minX < 0
    checks["geometry-2x-roundtrip"] = similar(try one.screenRect(for: candidate),
                                                try two.screenRect(for: candidate), tolerance: 0.01)
    func roiFailure(_ code: String, _ operation: () throws -> Void) -> Bool {
        do { try operation(); return false }
        catch let failure as NativeFailure { return failure.code == code }
        catch { return false }
    }
    let sourceDisplay = CGRect(x: 0, y: 0, width: 20, height: 20)
    let sourceWindow = CGRect(x: 2, y: 3, width: 4, height: 4)
    let sourceROI = CGRect(x: 3, y: 4, width: 2, height: 2)
    let sourceOne = try roiSourceCapturePlan(window: sourceWindow, roi: sourceROI,
                                             display: sourceDisplay, scale: 1)
    let sourceTwo = try roiSourceCapturePlan(window: sourceWindow, roi: sourceROI,
                                             display: sourceDisplay, scale: 2)
    checks["roi-source-1x-plan"] = sourceOne.sourceRect == sourceROI &&
        sourceOne.canvasWidth == 4 && sourceOne.canvasHeight == 4 &&
        sourceOne.roiX == 1 && sourceOne.roiY == 1 &&
        sourceOne.roiWidth == 2 && sourceOne.roiHeight == 2
    checks["roi-source-2x-plan"] = sourceTwo.sourceRect == sourceROI &&
        sourceTwo.canvasWidth == 8 && sourceTwo.canvasHeight == 8 &&
        sourceTwo.roiX == 2 && sourceTwo.roiY == 2 &&
        sourceTwo.roiWidth == 4 && sourceTwo.roiHeight == 4
    let secondaryDisplay = CGRect(x: 20, y: 0, width: 20, height: 20)
    let secondaryWindow = CGRect(x: 22, y: 3, width: 4, height: 4)
    let secondaryROI = CGRect(x: 23, y: 4, width: 2, height: 2)
    let secondary = try roiSourceCapturePlan(window: secondaryWindow, roi: secondaryROI,
                                             display: secondaryDisplay, scale: 1)
    checks["roi-source-secondary-positive-x"] =
        secondary.sourceRect == CGRect(x: 3, y: 4, width: 2, height: 2) &&
        secondary.roiX == 1 && secondary.roiY == 1
    let negativeX = try roiSourceCapturePlan(
        window: CGRect(x: -18, y: 3, width: 4, height: 4),
        roi: CGRect(x: -17, y: 4, width: 2, height: 2),
        display: CGRect(x: -20, y: 0, width: 20, height: 20), scale: 1
    )
    let negativeY = try roiSourceCapturePlan(
        window: CGRect(x: 2, y: -17, width: 4, height: 4),
        roi: CGRect(x: 3, y: -16, width: 2, height: 2),
        display: CGRect(x: 0, y: -20, width: 20, height: 20), scale: 1
    )
    checks["roi-source-negative-display-origins"] =
        negativeX.sourceRect == CGRect(x: 3, y: 4, width: 2, height: 2) &&
        negativeY.sourceRect == CGRect(x: 3, y: 4, width: 2, height: 2)
    let halfScale = try roiSourceCapturePlan(window: secondaryWindow, roi: secondaryROI,
                                             display: secondaryDisplay, scale: 0.5)
    let fourScale = try roiSourceCapturePlan(window: secondaryWindow, roi: secondaryROI,
                                             display: secondaryDisplay, scale: 4)
    checks["roi-source-scale-boundaries"] =
        halfScale.canvasWidth == 2 && halfScale.canvasHeight == 2 &&
        fourScale.canvasWidth == 16 && fourScale.canvasHeight == 16
    checks["roi-source-local-window-pixels-separated"] =
        secondary.sourceRect.minX == 3 && secondary.roiX == 1 &&
        secondary.sourceRect.minX != CGFloat(secondary.roiX)
    let displayModels = [
        DisplayGeometryCandidate(id: 1, scFrame: sourceDisplay,
                                 cgFrame: sourceDisplay, active: true),
        DisplayGeometryCandidate(id: 3, scFrame: secondaryDisplay,
                                 cgFrame: secondaryDisplay, active: true),
    ]
    checks["roi-source-display-selection-unique"] =
        uniqueDisplayGeometryIndex(displayModels, window: secondaryWindow,
                                   roi: secondaryROI) == 1
    checks["roi-source-display-selection-ambiguous"] = uniqueDisplayGeometryIndex(
        displayModels + [DisplayGeometryCandidate(id: 4, scFrame: secondaryDisplay,
                                                  cgFrame: secondaryDisplay, active: true)],
        window: secondaryWindow, roi: secondaryROI
    ) == nil && uniqueDisplayGeometryIndex([
        DisplayGeometryCandidate(id: 3, scFrame: secondaryDisplay,
                                 cgFrame: secondaryDisplay.offsetBy(dx: 1, dy: 0), active: true),
    ], window: secondaryWindow, roi: secondaryROI) == nil
    let secondaryGeometry = displayModels[1]
    checks["roi-source-post-display-stability"] = stableDisplayGeometryIndex(
        before: secondaryGeometry, candidates: displayModels,
        window: secondaryWindow, roi: secondaryROI
    ) == 1 && stableDisplayGeometryIndex(
        before: secondaryGeometry,
        candidates: displayModels + [DisplayGeometryCandidate(
            id: 4, scFrame: secondaryDisplay, cgFrame: secondaryDisplay, active: true
        )], window: secondaryWindow, roi: secondaryROI
    ) == nil && stableDisplayGeometryIndex(
        before: secondaryGeometry, candidates: [displayModels[0]],
        window: secondaryWindow, roi: secondaryROI
    ) == nil && stableDisplayGeometryIndex(
        before: secondaryGeometry, candidates: [DisplayGeometryCandidate(
            id: 3, scFrame: secondaryDisplay.offsetBy(dx: 0.5, dy: 0),
            cgFrame: secondaryDisplay.offsetBy(dx: 0.5, dy: 0), active: true
        )], window: secondaryWindow, roi: secondaryROI
    ) == nil
    checks["roi-source-post-scale-exact"] =
        exactDisplayScale(1, 1) && exactDisplayScale(2, 2) &&
        !exactDisplayScale(1, 1.000_001) && !exactDisplayScale(.nan, 1)
    checks["roi-source-filter-geometry"] = validDisplayFilterGeometry(
        contentRect: CGRect(origin: .zero, size: secondaryDisplay.size),
        displayFrame: secondaryDisplay, scale: 1
    ) && !validDisplayFilterGeometry(
        contentRect: secondaryDisplay, displayFrame: secondaryDisplay, scale: 1
    ) && !validDisplayFilterGeometry(
        contentRect: CGRect(origin: .zero, size: secondaryDisplay.size),
        displayFrame: secondaryDisplay, scale: 4.01
    )
    checks["roi-source-cross-display-rejected"] = roiFailure("ROI_DISPLAY_UNSUPPORTED") {
        _ = try roiSourceCapturePlan(window: CGRect(x: 18, y: 2, width: 4, height: 4),
                                     roi: CGRect(x: 19, y: 3, width: 2, height: 2),
                                     display: sourceDisplay, scale: 1)
    }
    let fractional = try roiSourceCapturePlan(
        window: CGRect(x: 2.25, y: 3.25, width: 4.5, height: 3.5),
        roi: CGRect(x: 2.75, y: 3.75, width: 1.25, height: 1.25),
        display: sourceDisplay, scale: 2
    )
    checks["roi-source-fractional-edges"] = fractional.canvasWidth == 9 &&
        fractional.canvasHeight == 7 && fractional.roiX == 1 && fractional.roiY == 1 &&
        fractional.roiWidth == 3 && fractional.roiHeight == 3
    checks["roi-source-nonzero-window-origin"] = sourceOne.sourceRect.minX == 3 &&
        sourceOne.sourceRect.minY == 4
    checks["roi-source-invalid-bounds-rejected"] = roiFailure("ROI_DISPLAY_UNSUPPORTED") {
        _ = try roiSourceCapturePlan(window: sourceWindow,
                                     roi: CGRect(x: 5, y: 6, width: 2, height: 2),
                                     display: sourceDisplay, scale: 1)
    } && roiFailure("ROI_DISPLAY_UNSUPPORTED") {
        _ = try roiSourceCapturePlan(window: sourceWindow, roi: sourceROI,
                                     display: CGRect(x: -20, y: 0, width: 20, height: 20), scale: 1)
    }
    checks["roi-source-scale-rejected"] = roiFailure("ROI_SCALE_INVALID") {
        _ = try roiSourceCapturePlan(window: sourceWindow, roi: sourceROI,
                                     display: sourceDisplay, scale: 0.49)
    } && roiFailure("ROI_SCALE_INVALID") {
        _ = try roiSourceCapturePlan(window: sourceWindow, roi: sourceROI,
                                     display: sourceDisplay, scale: 4.01)
    }
    checks["roi-source-overflow-rejected"] = roiFailure("ROI_DIMENSION_LIMIT") {
        _ = try checkedROIRGBAShape(width: Int.max, height: Int.max)
    }
    checks["roi-source-size-caps-rejected"] = roiFailure("ROI_DIMENSION_LIMIT") {
        _ = try checkedROIRGBAShape(width: 8193, height: 1)
    } && roiFailure("ROI_PIXEL_LIMIT") {
        _ = try checkedROIRGBAShape(width: 8192, height: 8192)
    }
    let sourcePixels: [UInt8] = [
        255, 0, 0, 255,   0, 255, 0, 255,
        0, 0, 255, 255,   255, 255, 255, 255,
    ]
    let forgedPlan = ROISourceCapturePlan(
        sourceRect: sourceOne.sourceRect,
        canvasWidth: sourceOne.canvasWidth, canvasHeight: sourceOne.canvasHeight,
        canvasBytesPerRow: sourceOne.canvasBytesPerRow, canvasByteCount: Int.max,
        roiX: sourceOne.roiX, roiY: sourceOne.roiY,
        roiWidth: sourceOne.roiWidth, roiHeight: sourceOne.roiHeight,
        roiBytesPerRow: sourceOne.roiBytesPerRow, roiByteCount: sourceOne.roiByteCount
    )
    checks["roi-source-canvas-invalid-plan-rejected"] = roiFailure("ROI_PLAN_INVALID") {
        _ = try roiCanvasTopDown(sourcePixels, plan: forgedPlan)
    }
    if let sourceImage = rgbaImage(topDown: sourcePixels, width: 2, height: 2),
       let canvasImage = try? roiCanvasImage(sourceImage, plan: sourceOne),
       let cropped = canvasImage.cropping(to: CGRect(x: sourceOne.roiX, y: sourceOne.roiY,
                                                     width: sourceOne.roiWidth,
                                                     height: sourceOne.roiHeight)),
       let canvasRendered = try? rgbaBottomUp(canvasImage),
       let sourceRendered = try? rgbaBottomUp(sourceImage),
       let croppedRendered = try? rgbaBottomUp(cropped) {
        let canvasTopDown = topDownRows(canvasRendered.0, bytesPerRow: canvasRendered.1,
                                        height: canvasImage.height)
        let sourceTopDown = topDownRows(sourceRendered.0, bytesPerRow: sourceRendered.1,
                                        height: sourceImage.height)
        let croppedTopDown = topDownRows(croppedRendered.0, bytesPerRow: croppedRendered.1,
                                         height: cropped.height)
        checks["roi-source-canvas-byte-roundtrip"] = sourceTopDown == sourcePixels &&
            croppedTopDown == sourceTopDown
        checks["roi-source-canvas-four-corners"] = croppedTopDown == sourcePixels
        var outsideBlank = true
        for y in 0..<sourceOne.canvasHeight {
            for x in 0..<sourceOne.canvasWidth
                where x < sourceOne.roiX || x >= sourceOne.roiX + sourceOne.roiWidth ||
                    y < sourceOne.roiY || y >= sourceOne.roiY + sourceOne.roiHeight {
                let offset = y * sourceOne.canvasBytesPerRow + x * 4
                outsideBlank = outsideBlank && canvasTopDown[offset..<(offset + 4)].allSatisfy { $0 == 0 }
            }
        }
        checks["roi-source-canvas-outside-blank"] = outsideBlank
    } else {
        checks["roi-source-canvas-byte-roundtrip"] = false
        checks["roi-source-canvas-four-corners"] = false
        checks["roi-source-canvas-outside-blank"] = false
    }
    var badgePixels = solidRGBA(20, width: 100, height: 40)
    for y in 2..<5 { for x in 50..<53 where !(x == 51 && y == 3) {
        let offset = (y * 100 + x) * 4
        badgePixels[offset] = 0; badgePixels[offset + 1] = 185; badgePixels[offset + 2] = 33
    } }
    let badgeImage = rgbaImage(topDown: badgePixels, width: 100, height: 40)!
    let badgeGeometry = CaptureGeometry(window: CGRect(x: 0, y: 0, width: 100, height: 40),
                                        roi: CGRect(x: 0, y: 0, width: 100, height: 40),
                                        imageWidth: 100, imageHeight: 40)
    let originalGreen = try greenComponents(badgeImage, geometry: badgeGeometry)
    let maskedBadge = try maskedBadgeROI(badgeImage, geometry: badgeGeometry,
                                         components: originalGreen)
    let originalGreenAfter = try greenComponents(badgeImage, geometry: badgeGeometry)
    checks["readprofile-original-green-unchanged"] = originalGreen.count == 1 &&
        originalGreenAfter.count == 1 && originalGreen[0].pixelBox == originalGreenAfter[0].pixelBox
    if let maskedBadge {
        let maskedCanonical = try canonicalReadROI(maskedBadge, requiredProfile: .dark)
        checks["readprofile-mask-position-profile"] = maskedBadge.width == badgeImage.width &&
            maskedBadge.height == badgeImage.height && maskedCanonical.profile == .dark
    } else { checks["readprofile-mask-position-profile"] = false }
    let cornerPixels: [UInt8] = [
        255, 0, 0, 255,   0, 255, 0, 255,
        0, 0, 255, 255,   255, 255, 255, 255,
    ]
    if let cornerImage = rgbaImage(topDown: cornerPixels, width: 2, height: 2) {
        let scaled = try upscaledWholeROI2x(cornerImage)
        checks["ocr-2x-aspect-dimensions"] = scaled.width == 4 && scaled.height == 4
        let (bottomUp, bytesPerRow) = try rgbaBottomUp(scaled)
        let topDown = topDownRows(bottomUp, bytesPerRow: bytesPerRow, height: scaled.height)
        func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let offset = y * bytesPerRow + x * 4
            return (Int(topDown[offset]), Int(topDown[offset + 1]), Int(topDown[offset + 2]))
        }
        let topLeft = rgb(0, 0), topRight = rgb(3, 0)
        let bottomLeft = rgb(0, 3), bottomRight = rgb(3, 3)
        checks["ocr-2x-corner-orientation"] =
            topLeft.0 > topLeft.1 && topLeft.0 > topLeft.2 &&
            topRight.1 > topRight.0 && topRight.1 > topRight.2 &&
            bottomLeft.2 > bottomLeft.0 && bottomLeft.2 > bottomLeft.1 &&
            bottomRight.0 > 180 && bottomRight.1 > 180 && bottomRight.2 > 180
    } else {
        checks["ocr-2x-aspect-dimensions"] = false
        checks["ocr-2x-corner-orientation"] = false
    }
    let identity = WindowIdentity(pid: 1, windowID: 9, title: expectedWindowTitle, bounds: window,
                                  executableURL: "/Applications/LINE.app/Contents/MacOS/LINE",
                                  signingIdentifier: bundleIdentifier, teamIdentifier: "TEST")
    func layoutNode(_ role: String, parent: Int?, frame: CGRect?, subrole: String = "",
                    pid: pid_t) -> NodeRecord {
        NodeRecord(element: AXUIElementCreateApplication(pid), parent: parent, role: role,
                   subrole: subrole, title: "", description: "", value: "", frame: frame,
                   enabled: true, selected: nil)
    }
    func emptyRightSnapshot(partial: Bool = false,
                            listFrames: [CGRect] = [CGRect(x: -880, y: 155, width: 300, height: 500)],
                            searchFrames: [CGRect] = [CGRect(x: -868, y: 110, width: 280, height: 38)],
                            rootFrame: CGRect = CGRect(x: -880, y: 95, width: 860, height: 640),
                            chromeSubroles: [String] = [kAXCloseButtonSubrole,
                                                       kAXMinimizeButtonSubrole,
                                                       kAXZoomButtonSubrole]) -> Snapshot {
        var nodes = [layoutNode(kAXWindowRole, parent: nil, frame: window,
                                subrole: kAXStandardWindowSubrole, pid: 20),
                     layoutNode(kAXSplitGroupRole, parent: 0, frame: rootFrame, pid: 21)]
        for (offset, frame) in listFrames.enumerated() {
            nodes.append(layoutNode(kAXListRole, parent: 1, frame: frame, pid: pid_t(30 + offset)))
        }
        for (offset, frame) in searchFrames.enumerated() {
            nodes.append(layoutNode(kAXTextFieldRole, parent: 1, frame: frame, pid: pid_t(40 + offset)))
        }
        for (offset, subrole) in chromeSubroles.enumerated() {
            nodes.append(layoutNode(kAXButtonRole, parent: 0,
                                    frame: CGRect(x: -895 + CGFloat(offset * 20), y: 48,
                                                  width: 16, height: 16),
                                    subrole: subrole, pid: pid_t(50 + offset)))
        }
        return Snapshot(nodes: nodes, partial: partial, reasons: partial ? ["TEST_PARTIAL"] : [])
    }
    func fullRightSnapshot() -> Snapshot {
        // 完整右側 fixture 證明新 resolver 不改變既有聊天畫面的 tabs ROI。
        let empty = emptyRightSnapshot()
        var nodes = empty.nodes
        let right = nodes.count
        nodes.append(layoutNode(kAXSplitGroupRole, parent: 1,
                                frame: CGRect(x: -580, y: 95, width: 560, height: 640), pid: 60))
        nodes.append(layoutNode(kAXListRole, parent: right,
                                frame: CGRect(x: -575, y: 165, width: 550, height: 400), pid: 61))
        nodes.append(layoutNode(kAXTextAreaRole, parent: right,
                                frame: CGRect(x: -575, y: 600, width: 550, height: 100), pid: 62))
        return Snapshot(nodes: nodes, partial: empty.partial, reasons: empty.reasons)
    }
    let emptyRight = emptyRightSnapshot()
    do {
        let layout = try readTabLayout(emptyRight, window: identity)
        checks["readtab-empty-right-layout"] = layout.leftListIndex == 2 &&
            similar(layout.tabROI, CGRect(x: -880, y: 56, width: 860, height: 39), tolerance: 0.01)
        checks["readtab-empty-right-search-field"] = layout.searchFieldIndex == 3 &&
            emptyRight.nodes[layout.searchFieldIndex].role == kAXTextFieldRole &&
            emptyRight.nodes[layout.searchFieldIndex].frame.map {
                similar($0, CGRect(x: -868, y: 110, width: 280, height: 38), tolerance: 0.01)
            } == true
    } catch {
        checks["readtab-empty-right-layout"] = false
        checks["readtab-empty-right-search-field"] = false
    }
    do { _ = try lineLayout(emptyRight, window: identity); checks["readtab-empty-right-old-layout-rejected"] = false }
    catch let failure as NativeFailure {
        checks["readtab-empty-right-old-layout-rejected"] = failure.code == "SEMANTIC_UNRELIABLE"
    }
    func readTabRejected(_ snapshot: Snapshot, code: String = "SEMANTIC_UNRELIABLE") -> Bool {
        do { _ = try readTabLayout(snapshot, window: identity); return false }
        catch let failure as NativeFailure { return failure.code == code }
        catch { return false }
    }
    checks["readtab-partial-rejected"] = readTabRejected(emptyRightSnapshot(partial: true),
                                                          code: "SEMANTIC_PARTIAL")
    checks["readtab-missing-list-rejected"] = readTabRejected(emptyRightSnapshot(listFrames: []))
    checks["readtab-duplicate-list-rejected"] = readTabRejected(emptyRightSnapshot(listFrames: [
        CGRect(x: -880, y: 155, width: 300, height: 500),
        CGRect(x: -875, y: 160, width: 295, height: 490),
    ]))
    checks["readtab-duplicate-search-rejected"] = readTabRejected(emptyRightSnapshot(searchFrames: [
        CGRect(x: -868, y: 110, width: 280, height: 38),
        CGRect(x: -866, y: 112, width: 278, height: 36),
    ]))
    checks["readtab-full-width-list-rejected"] = readTabRejected(emptyRightSnapshot(listFrames: [
        CGRect(x: -880, y: 155, width: 800, height: 500),
    ], searchFrames: [CGRect(x: -868, y: 110, width: 780, height: 38)]))
    checks["readtab-left-only-ancestor-rejected"] = readTabRejected(emptyRightSnapshot(
        rootFrame: CGRect(x: -880, y: 95, width: 350, height: 640)
    ))
    checks["readtab-search-geometry-rejected"] = readTabRejected(emptyRightSnapshot(searchFrames: [
        CGRect(x: -500, y: 110, width: 280, height: 38),
    ]))
    checks["readtab-out-of-window-rejected"] = readTabRejected(emptyRightSnapshot(listFrames: [
        CGRect(x: -910, y: 155, width: 300, height: 500),
    ]))
    checks["readtab-high-roi-rejected"] = readTabRejected(emptyRightSnapshot(
        listFrames: [CGRect(x: -880, y: 240, width: 300, height: 480)],
        searchFrames: [CGRect(x: -868, y: 195, width: 280, height: 38)],
        rootFrame: CGRect(x: -880, y: 180, width: 860, height: 555)
    ))
    checks["readtab-chrome-rejected"] = readTabRejected(emptyRightSnapshot(chromeSubroles: [
        kAXCloseButtonSubrole, kAXMinimizeButtonSubrole,
    ])) && readTabRejected(emptyRightSnapshot(chromeSubroles: [
        kAXCloseButtonSubrole, kAXMinimizeButtonSubrole, kAXZoomButtonSubrole,
        kAXZoomButtonSubrole,
    ]))
    func ocrRegionRejected(_ region: OCRRegion, snapshot: Snapshot,
                           code: String = "SEMANTIC_UNRELIABLE") -> Bool {
        do { _ = try ocrRegionROI(region, tree: snapshot, window: identity); return false }
        catch let failure as NativeFailure { return failure.code == code }
        catch { return false }
    }
    do {
        let roi = try ocrRegionROI(.tabs, tree: emptyRight, window: identity)
        checks["ocrregion-tabs-empty-right"] =
            similar(roi, CGRect(x: -880, y: 56, width: 860, height: 39), tolerance: 0.01)
    } catch { checks["ocrregion-tabs-empty-right"] = false }
    checks["ocrregion-header-empty-right-rejected"] =
        ocrRegionRejected(.header, snapshot: emptyRight)
    do {
        let full = fullRightSnapshot()
        let roi = try ocrRegionROI(.tabs, tree: full, window: identity)
        checks["ocrregion-full-right-tab-roi-equivalent"] =
            similar(roi, try lineLayout(full, window: identity).tabROI, tolerance: 0.01)
    } catch { checks["ocrregion-full-right-tab-roi-equivalent"] = false }
    checks["ocrregion-tabs-partial-rejected"] =
        ocrRegionRejected(.tabs, snapshot: emptyRightSnapshot(partial: true), code: "SEMANTIC_PARTIAL")
    checks["ocrregion-tabs-duplicate-left-rejected"] = ocrRegionRejected(.tabs, snapshot:
        emptyRightSnapshot(listFrames: [
            CGRect(x: -880, y: 155, width: 300, height: 500),
            CGRect(x: -875, y: 160, width: 295, height: 490),
        ]))
    checks["ocrregion-tabs-duplicate-search-rejected"] = ocrRegionRejected(.tabs, snapshot:
        emptyRightSnapshot(searchFrames: [
            CGRect(x: -868, y: 110, width: 280, height: 38),
            CGRect(x: -866, y: 112, width: 278, height: 36),
        ]))
    checks["ocrregion-tabs-missing-left-rejected"] =
        ocrRegionRejected(.tabs, snapshot: emptyRightSnapshot(listFrames: []))
    checks["ocrregion-tabs-missing-search-rejected"] =
        ocrRegionRejected(.tabs, snapshot: emptyRightSnapshot(searchFrames: []))
    checks["ocrregion-tabs-invalid-chrome-rejected"] = ocrRegionRejected(.tabs, snapshot:
        emptyRightSnapshot(chromeSubroles: [kAXCloseButtonSubrole, kAXMinimizeButtonSubrole]))
    checks["ocrregion-tabs-invalid-roi-rejected"] = ocrRegionRejected(.tabs, snapshot:
        emptyRightSnapshot(
            listFrames: [CGRect(x: -880, y: 240, width: 300, height: 480)],
            searchFrames: [CGRect(x: -868, y: 195, width: 280, height: 38)],
            rootFrame: CGRect(x: -880, y: 180, width: 860, height: 555)
        ))
    let primerWindow = CGRect(x: -900, y: 40, width: 900, height: 700)
    let primerList = CGRect(x: -880, y: 180, width: 280, height: 500)
    let primerPrefix = [
        PrimerPrefixRow(index: 0, frame: CGRect(x: -880, y: 180, width: 280, height: 50)),
        PrimerPrefixRow(index: 1, frame: CGRect(x: -880, y: 230, width: 280, height: 50)),
    ]
    let primerModel = try derivePrimerGeometry(listFrame: primerList, windowFrame: primerWindow,
                                               prefix: primerPrefix)
    let stalePrefix = [
        PrimerObservedRow(role: "", index: nil, frame: nil),
        PrimerObservedRow(role: kAXRowRole, index: -1, frame: nil),
        PrimerObservedRow(role: kAXRowRole, index: 0, frame: primerPrefix[0].frame),
        PrimerObservedRow(role: kAXRowRole, index: 1, frame: primerPrefix[1].frame),
        PrimerObservedRow(role: kAXRowRole, index: 2, frame: .zero),
    ]
    let staleSeeds = try primerPrefixSeeds(stalePrefix, listFrame: primerList,
                                           windowFrame: primerWindow)
    let staleGeometry = try derivePrimerGeometry(listFrame: primerList,
                                                 windowFrame: primerWindow,
                                                 prefix: staleSeeds)
    func primerHit(_ slot: Int, id: Int? = nil, index: Int? = nil,
                   pid: Int = 7, listID: Int = 9, depth: Int = 2,
                   blank: Bool = false) -> PrimerHitProof {
        PrimerHitProof(slot: slot, pid: pid, listID: listID, ancestryDepth: depth,
                       directBlank: blank, rowID: blank ? nil : (id ?? slot + 10),
                       index: blank ? nil : (index ?? slot),
                       frame: blank ? nil : CGRect(x: primerList.minX,
                                                   y: primerList.minY + CGFloat(slot) * 50,
                                                   width: primerList.width, height: 50))
    }
    let primerHits = primerModel.points.indices.map {
        $0 < 3 ? primerHit($0) : primerHit($0, blank: true)
    }
    let primerFinal = (0..<3).map {
        PrimerFinalRow(rowID: $0 + 10, index: $0,
                       frame: CGRect(x: primerList.minX,
                                     y: primerList.minY + CGFloat($0) * 50,
                                     width: primerList.width, height: 50))
    }
    checks["primer-valid-model"] = primerModelComplete(
        geometry: primerModel, listFrame: primerList, windowFrame: primerWindow,
        expectedPID: 7, expectedListID: 9, hits: primerHits,
        finalCount: 3, finalRows: primerFinal
    )
    checks["primer-stale-prefix-valid-seeds"] = staleSeeds.count == 2 &&
        primerModelComplete(
            geometry: staleGeometry,
            listFrame: primerList, windowFrame: primerWindow,
            expectedPID: 7, expectedListID: 9, hits: primerHits,
            finalCount: 3, finalRows: primerFinal
        )
    do {
        _ = try primerPrefixSeeds([
            PrimerObservedRow(role: kAXButtonRole, index: nil, frame: nil),
            PrimerObservedRow(role: kAXRowRole, index: 0, frame: primerPrefix[0].frame),
            PrimerObservedRow(role: kAXRowRole, index: 1, frame: primerPrefix[1].frame),
        ], listFrame: primerList, windowFrame: primerWindow)
        checks["primer-known-nonrow-rejected"] = false
    } catch let failure as NativeFailure {
        checks["primer-known-nonrow-rejected"] = failure.code == "SEMANTIC_PARTIAL"
    }
    func primerGeometryRejected(_ prefix: [PrimerPrefixRow],
                                list: CGRect = primerList) -> Bool {
        do { _ = try derivePrimerGeometry(listFrame: list, windowFrame: primerWindow,
                                          prefix: prefix); return false }
        catch { return true }
    }
    checks["primer-missing-frames-rejected"] = primerGeometryRejected([primerPrefix[0]])
    checks["primer-height-rejected"] = primerGeometryRejected([
        primerPrefix[0], PrimerPrefixRow(index: 1,
                                         frame: CGRect(x: -880, y: 230, width: 280, height: 49)),
    ])
    checks["primer-grid-rejected"] = primerGeometryRejected([
        primerPrefix[0], PrimerPrefixRow(index: 1,
                                         frame: CGRect(x: -880, y: 231, width: 280, height: 50)),
    ])
    checks["primer-bounds-rejected"] = primerGeometryRejected([
        PrimerPrefixRow(index: 0, frame: CGRect(x: -910, y: 180, width: 280, height: 50)),
        PrimerPrefixRow(index: 1, frame: CGRect(x: -910, y: 230, width: 280, height: 50)),
    ])
    let cappedGeometry = try derivePrimerGeometry(
        listFrame: primerList, windowFrame: primerWindow,
        prefix: [
            PrimerPrefixRow(index: 0, frame: CGRect(x: -880, y: 180, width: 280, height: 18)),
            PrimerPrefixRow(index: 1, frame: CGRect(x: -880, y: 198, width: 280, height: 18)),
        ]
    )
    checks["primer-slot-budget-capped"] = cappedGeometry.points.count == 20
    var foreignHits = primerHits; foreignHits[0] = primerHit(0, pid: 8)
    checks["primer-foreign-hit-rejected"] = !primerModelComplete(
        geometry: primerModel, listFrame: primerList, windowFrame: primerWindow,
        expectedPID: 7, expectedListID: 9, hits: foreignHits,
        finalCount: 3, finalRows: primerFinal
    )
    var duplicateHits = primerHits; duplicateHits[1] = primerHit(1, id: 10)
    checks["primer-duplicate-row-rejected"] = !primerModelComplete(
        geometry: primerModel, listFrame: primerList, windowFrame: primerWindow,
        expectedPID: 7, expectedListID: 9, hits: duplicateHits,
        finalCount: 3, finalRows: primerFinal
    )
    var badIndexHits = primerHits; badIndexHits[1] = primerHit(1, index: 4)
    checks["primer-dense-indices-required"] = !primerModelComplete(
        geometry: primerModel, listFrame: primerList, windowFrame: primerWindow,
        expectedPID: 7, expectedListID: 9, hits: badIndexHits,
        finalCount: 3, finalRows: primerFinal
    )
    checks["primer-count-mismatch-rejected"] = !primerModelComplete(
        geometry: primerModel, listFrame: primerList, windowFrame: primerWindow,
        expectedPID: 7, expectedListID: 9, hits: primerHits,
        finalCount: 2, finalRows: primerFinal
    )
    var wrongSet = primerFinal; wrongSet[2] = PrimerFinalRow(rowID: 99, index: 2, frame: primerFinal[2].frame)
    checks["primer-cfset-mismatch-rejected"] = !primerModelComplete(
        geometry: primerModel, listFrame: primerList, windowFrame: primerWindow,
        expectedPID: 7, expectedListID: 9, hits: primerHits,
        finalCount: 3, finalRows: wrongSet
    )
    let blankHits = primerModel.points.indices.map { primerHit($0, blank: true) }
    checks["primer-zero-rows-rejected"] = !primerModelComplete(
        geometry: primerModel, listFrame: primerList, windowFrame: primerWindow,
        expectedPID: 7, expectedListID: 9, hits: blankHits,
        finalCount: 0, finalRows: []
    )
    checks["primer-timeout-stops"] = !primerBudgetOpen(deadline: 1, now: 1)
    let freshRows = (0..<6).map {
        FreshVisibleRowModel(rowID: $0, role: kAXRowRole, index: $0,
                             frame: CGRect(x: primerList.minX,
                                           y: primerList.minY + CGFloat($0) * 50,
                                           width: primerList.width, height: 50))
    }
    checks["freshmodel-complete-six"] = freshVisibleModelValid(
        freshRows, listFrame: primerList, windowFrame: primerWindow
    ) && freshModelCanSkipPrimer(advertisedCount: 6, modelValid: true)
    checks["freshmodel-single-row"] = freshVisibleModelValid(
        [freshRows[0]], listFrame: primerList, windowFrame: primerWindow
    ) && freshModelCanSkipPrimer(advertisedCount: 1, modelValid: true)
    checks["freshmodel-count-bounds"] = !freshModelCanSkipPrimer(
        advertisedCount: 0, modelValid: true
    ) && !freshModelCanSkipPrimer(advertisedCount: 21, modelValid: true) &&
        !freshModelCanSkipPrimer(advertisedCount: 1_420, modelValid: true)
    var duplicateFresh = freshRows
    duplicateFresh[1] = FreshVisibleRowModel(rowID: 0, role: kAXRowRole, index: 1,
                                             frame: duplicateFresh[1].frame)
    checks["freshmodel-duplicate-id-rejected"] = !freshVisibleModelValid(
        duplicateFresh, listFrame: primerList, windowFrame: primerWindow
    )
    var badFreshIndex = freshRows
    badFreshIndex[1] = FreshVisibleRowModel(rowID: 1, role: kAXRowRole, index: 3,
                                           frame: badFreshIndex[1].frame)
    checks["freshmodel-index-rejected"] = !freshVisibleModelValid(
        badFreshIndex, listFrame: primerList, windowFrame: primerWindow
    )
    var badFreshRole = freshRows
    badFreshRole[0] = FreshVisibleRowModel(rowID: 0, role: kAXButtonRole, index: 0,
                                          frame: badFreshRole[0].frame)
    checks["freshmodel-role-rejected"] = !freshVisibleModelValid(
        badFreshRole, listFrame: primerList, windowFrame: primerWindow
    )
    var badFreshGrid = freshRows
    badFreshGrid[2] = FreshVisibleRowModel(rowID: 2, role: kAXRowRole, index: 2,
                                          frame: badFreshGrid[2].frame.offsetBy(dx: 0, dy: 1))
    checks["freshmodel-grid-rejected"] = !freshVisibleModelValid(
        badFreshGrid, listFrame: primerList, windowFrame: primerWindow
    )
    checks["freshmodel-window-list-rejected"] = !freshVisibleModelValid(
        freshRows, listFrame: primerList.offsetBy(dx: 1, dy: 0),
        windowFrame: primerWindow
    )
    let stableFresh = freshRows.map {
        PrimerFinalRow(rowID: $0.rowID, index: $0.index, frame: $0.frame)
    }
    var reorderedFresh = stableFresh
    reorderedFresh.swapAt(0, 1)
    checks["freshmodel-second-order-drift"] = !freshVisibleModelsStable(
        stableFresh, reorderedFresh
    )
    var shiftedFresh = stableFresh
    shiftedFresh[0] = PrimerFinalRow(rowID: 0, index: 0,
                                     frame: shiftedFresh[0].frame.offsetBy(dx: 0, dy: 1))
    checks["freshmodel-second-frame-drift"] = !freshVisibleModelsStable(
        stableFresh, shiftedFresh
    )
    let firstCFOrder = (0..<stableFresh.count).map {
        AXUIElementCreateApplication(pid_t(100 + $0))
    }
    var swappedCFOrder = firstCFOrder
    swappedCFOrder.swapAt(0, 1)
    checks["freshmodel-second-cf-order-drift"] = !freshReceiptOrderStable(
        firstCFOrder, swappedCFOrder
    )
    var foreignCFOrder = firstCFOrder
    foreignCFOrder[0] = AXUIElementCreateApplication(999)
    checks["freshmodel-second-foreign-cf"] = !freshReceiptOrderStable(
        firstCFOrder, foreignCFOrder
    )
    var indexOnlyDrift = stableFresh
    indexOnlyDrift[1] = PrimerFinalRow(rowID: 1, index: 2,
                                       frame: stableFresh[1].frame)
    checks["freshmodel-second-index-drift"] = !freshVisibleModelsStable(
        stableFresh, indexOnlyDrift
    )
    checks["freshmodel-deadline-rejected"] = !primerBudgetOpen(deadline: 1, now: 1)
    checks["freshmodel-consumer-missing-row"] = !visibleReceiptConsumerValid(
        receipt: stableFresh, axRows: Array(stableFresh.dropFirst()),
        visibleRows: stableFresh, advertisedCount: 6, dense: true, allVisible: true
    )
    checks["freshmodel-consumer-cf-order"] = !visibleReceiptConsumerValid(
        receipt: stableFresh, axRows: reorderedFresh,
        visibleRows: stableFresh, advertisedCount: 6, dense: true, allVisible: true
    )
    checks["freshmodel-consumer-index-frame"] = !visibleReceiptConsumerValid(
        receipt: stableFresh, axRows: shiftedFresh,
        visibleRows: stableFresh, advertisedCount: 6, dense: true, allVisible: true
    )
    checks["freshmodel-consumer-count-flags"] = !visibleReceiptConsumerValid(
        receipt: stableFresh, axRows: stableFresh,
        visibleRows: stableFresh, advertisedCount: 5, dense: true, allVisible: true
    ) && !visibleReceiptConsumerValid(
        receipt: stableFresh, axRows: stableFresh,
        visibleRows: stableFresh, advertisedCount: 6, dense: false, allVisible: true
    ) && !visibleReceiptConsumerValid(
        receipt: stableFresh, axRows: stableFresh,
        visibleRows: stableFresh, advertisedCount: 6, dense: true, allVisible: false
    )
    let syntheticList = AXUIElementCreateApplication(1)
    let syntheticRow = AXUIElementCreateApplication(2)
    func syntheticNameSample(rowOffset: CGFloat = 0, imageWidth: Int = 900) -> NameBandSample {
        NameBandSample(identity: identity, listElement: syntheticList,
                       listFrame: CGRect(x: -880, y: 180, width: 280, height: 500),
                       rowElements: [syntheticRow],
                       rowFrames: [CGRect(x: -880, y: 180 + rowOffset, width: 280, height: 71)],
                       imageWidth: imageWidth, imageHeight: 700,
                       rowProfiles: [.light],
                       target: safeName, targetRendererEvidence: nil,
                       targetScreenRect: CGRect(x: -800, y: 190, width: 100, height: 15),
                       targetObservedCount: 1,
                       visibleRowCount: 1, invalidRowCount: 0,
                       bandInvalidRowCount: 0, candidateInvalidRowCount: 0, axRowsCount: 1,
                       advertisedRowCount: 1, denseIndices: true, allRowsVisible: true)
    }
    checks["nameband-frame-geometry-stable"] = stableNameBandGeometry(
        syntheticNameSample(), syntheticNameSample()
    )
    checks["nameband-row-drift-rejected"] = !stableNameBandGeometry(
        syntheticNameSample(), syntheticNameSample(rowOffset: 2)
    ) && !stableNameBandGeometry(syntheticNameSample(), syntheticNameSample(imageWidth: 901))
    let first = OCRFrame(identity: identity, roi: roi, imageWidth: 900, imageHeight: 700,
                         candidates: [candidate, OCRCandidate(text: "Low", confidence: 0.949,
                                                              normalizedBox: candidate.normalizedBox)], maskedCandidates: [],
                         processedCandidates: [processedCandidate], processedPolicyApplied: true,
                         greenComponents: [], underlineComponents: [])
    let second = OCRFrame(identity: identity, roi: roi, imageWidth: 900, imageHeight: 700,
                          candidates: [OCRCandidate(text: "Scope tab", confidence: 0.51,
                                                    normalizedBox: candidate.normalizedBox.offsetBy(dx: 0.005, dy: 0))], maskedCandidates: [],
                          processedCandidates: [OCRCandidate(text: "Scope tab", confidence: 0.97,
                                                             normalizedBox: candidate.normalizedBox.offsetBy(dx: 0.005, dy: 0))],
                          processedPolicyApplied: true, greenComponents: [], underlineComponents: [])
    checks["ocr-threshold-fixed"] = exactOCRMatches("Low", in: first).isEmpty
    checks["ocr-processed-low-raw-upgraded"] = exactOCRMatches("Scope tab", in: first).first?.confidence == 0.96
    checks["ocr-unique-stable"] = (try stableOCRTarget("Scope tab", first: first, second: second)).text == "Scope tab"
    let duplicate = OCRFrame(identity: identity, roi: roi, imageWidth: 900, imageHeight: 700,
                             candidates: [candidate, candidate], maskedCandidates: [],
                             processedCandidates: [processedCandidate], processedPolicyApplied: true,
                             greenComponents: [], underlineComponents: [])
    do { _ = try stableOCRTarget("Scope tab", first: duplicate, second: second); checks["ocr-duplicate-rejected"] = false }
    catch let failure as NativeFailure { checks["ocr-duplicate-rejected"] = failure.code == "AMBIGUOUS_MATCH" }
    func syntheticOCR(_ raw: [OCRCandidate], _ processed: [OCRCandidate]) -> OCRFrame {
        OCRFrame(identity: identity, roi: roi, imageWidth: 900, imageHeight: 700,
                 candidates: raw, maskedCandidates: [], processedCandidates: processed,
                 processedPolicyApplied: true, greenComponents: [], underlineComponents: [])
    }
    let rawSelectedCandidate = OCRCandidate(text: "Selected tab", confidence: 0.99,
                                            normalizedBox: candidate.normalizedBox)
    let rawSelectedUnderline = UnderlineComponent(
        pointBox: CGRect(x: 175, y: 36, width: 120, height: 2),
        pixelCount: 480, meanLuma: 20, fillRatio: 1
    )
    func rawSelectedFrame(identity frameIdentity: WindowIdentity = identity,
                          roi frameROI: CGRect = roi,
                          candidates: [OCRCandidate] = [rawSelectedCandidate],
                          masked: [OCRCandidate] = [],
                          processed: [OCRCandidate] = [],
                          imageWidth: Int = 900,
                          imageHeight: Int = 700,
                          underlines: [UnderlineComponent] = [rawSelectedUnderline],
                          badges: [GreenComponent] = []) -> OCRFrame {
        OCRFrame(identity: frameIdentity, roi: frameROI,
                 imageWidth: imageWidth, imageHeight: imageHeight,
                 candidates: candidates, maskedCandidates: masked, processedCandidates: processed,
                 processedPolicyApplied: false, greenComponents: badges, underlineComponents: underlines)
    }
    let rawSelectedA = rawSelectedFrame(processed: [
        OCRCandidate(text: "Conflicting processed", confidence: 0.99,
                     normalizedBox: rawSelectedCandidate.normalizedBox),
    ])
    let rawSelectedB = rawSelectedFrame()
    let allCandidate = OCRCandidate(text: "全部", confidence: 0.99,
                                     normalizedBox: rawSelectedCandidate.normalizedBox)
    let allFrame = rawSelectedFrame(candidates: [allCandidate])
    func globalAllCode(_ a: OCRFrame, _ b: OCRFrame,
                       firstProfile: ReadColorProfile = .light,
                       secondProfile: ReadColorProfile = .light) -> String {
        do {
            _ = try stableGlobalAllSelection(first: ReadOCRFrame(frame: a, profile: firstProfile),
                                             second: ReadOCRFrame(frame: b, profile: secondProfile))
            return "OK"
        } catch let failure as NativeFailure { return failure.code }
        catch { return "UNEXPECTED" }
    }
    checks["global-all-diagnostic-profile-change"] = globalAllCode(
        allFrame, allFrame, firstProfile: .light, secondProfile: .dark
    ) == "GLOBAL_ALL_PROFILE_CHANGED"
    checks["global-all-diagnostic-not-selected"] = globalAllCode(
        rawSelectedFrame(candidates: [allCandidate], underlines: []), allFrame
    ) == "GLOBAL_ALL_NOT_SELECTED"
    let lowAll = OCRCandidate(text: "全部", confidence: 0.5,
                              normalizedBox: allCandidate.normalizedBox)
    checks["global-all-diagnostic-invalid-proof"] = globalAllCode(
        rawSelectedFrame(candidates: [lowAll]), allFrame
    ) == "GLOBAL_ALL_SELECTION_INVALID"
    checks["global-all-diagnostic-selected-unchanged"] = globalAllCode(allFrame, allFrame) == "OK"
    func syntheticReadSelection(_ profile: ReadColorProfile,
                                underlines: [UnderlineComponent]) -> Bool {
        let frame = rawSelectedFrame(
            roi: CGRect(x: -880, y: 90, width: 200, height: 40),
            imageWidth: 200, imageHeight: 40, underlines: underlines
        )
        do {
            let verified = try stableReadSelectedTab(
                ["Selected tab"], first: ReadOCRFrame(frame: frame, profile: profile),
                second: ReadOCRFrame(frame: frame, profile: profile), expectedProfile: profile
            )
            return verified.1.text == "Selected tab"
        } catch { return false }
    }
    checks["readnavigation-dark-selected-canonical"] =
        darkTabCanonical.profile == .dark && syntheticReadSelection(.dark, underlines: whiteUnderline)
    checks["readnavigation-light-selected-canonical"] =
        lightTabCanonical.profile == .light && syntheticReadSelection(.light, underlines: blackUnderline)
    checks["readnavigation-legacy-profile-combination"] =
        tabNavigationProfileAllowed(.legacy, expected: nil, observed: nil) &&
        !tabNavigationProfileAllowed(.legacy, expected: .light, observed: nil) &&
        !tabNavigationProfileAllowed(.legacy, expected: nil, observed: .light)
    checks["readnavigation-readonly-profile-accepted"] =
        tabNavigationProfileAllowed(.readOnly, expected: nil, observed: .dark) &&
        tabNavigationProfileAllowed(.readOnly, expected: .dark, observed: .dark)
    checks["readnavigation-readonly-profile-drift-rejected"] =
        !tabNavigationProfileAllowed(.readOnly, expected: .dark, observed: .light)
    checks["readnavigation-readonly-profile-missing-rejected"] =
        !tabNavigationProfileAllowed(.readOnly, expected: nil, observed: nil) &&
        !tabNavigationProfileAllowed(.readOnly, expected: .dark, observed: nil)
    func tabSweepTrace(_ mode: TabNavigationMode,
                       _ signatures: [String]) -> ([Bool], [Int], [Int], Set<String>) {
        var seen = Set<String>(), direction = -1
        var accepted: [Bool] = [], directions: [Int] = [], budgets: [Int] = []
        for (index, signature) in signatures.enumerated() {
            let remaining = signatures.count - index - 1
            let advanced = advanceTabSearch(mode, signature: signature,
                                            remainingPages: remaining,
                                            direction: &direction, seen: &seen)
            accepted.append(advanced); directions.append(direction); budgets.append(remaining)
            if !advanced { break }
        }
        return (accepted, directions, budgets, seen)
    }
    let readOnlySweep = tabSweepTrace(.readOnly, ["A", "B", "B", "A", "D"])
    checks["tabsweep-readonly-bidirectional-trace"] =
        readOnlySweep.0 == [true, true, true, true, true] &&
        readOnlySweep.1 == [-1, -1, 1, 1, 1] && readOnlySweep.3 == Set(["A", "B", "D"])
    checks["tabsweep-global-budget-descends"] =
        readOnlySweep.2 == [4, 3, 2, 1, 0]
    let legacySweep = tabSweepTrace(.legacy, ["A", "B", "B", "A", "D"])
    checks["tabsweep-legacy-repeat-stops"] =
        legacySweep.0 == [true, true, false] && legacySweep.1 == [-1, -1, -1]
    var rightSeen = Set<String>(), rightDirection = -1
    let rightFirst = advanceTabSearch(.readOnly, signature: "B", remainingPages: 2,
                                      direction: &rightDirection, seen: &rightSeen)
    let rightFlip = advanceTabSearch(.readOnly, signature: "B", remainingPages: 1,
                                     direction: &rightDirection, seen: &rightSeen)
    let rightStop = advanceTabSearch(.readOnly, signature: "B", remainingPages: 0,
                                     direction: &rightDirection, seen: &rightSeen)
    checks["tabsweep-readonly-right-repeat-stops"] =
        rightFirst && rightFlip && !rightStop && rightDirection == 1
    var zeroSeen = Set(["A"]), zeroDirection = -1
    checks["tabsweep-zero-budget-no-flip"] =
        !advanceTabSearch(.readOnly, signature: "A", remainingPages: 0,
                          direction: &zeroDirection, seen: &zeroSeen) &&
        zeroDirection == -1 && zeroSeen == Set(["A"])
    var invalidSeen = Set<String>(), invalidDirection = 0
    checks["tabsweep-invalid-direction-rejected"] =
        !advanceTabSearch(.readOnly, signature: "A", remainingPages: 1,
                          direction: &invalidDirection, seen: &invalidSeen) && invalidSeen.isEmpty
    var negativeSeen = Set<String>(), negativeDirection = -1
    checks["tabsweep-negative-budget-rejected"] =
        !advanceTabSearch(.readOnly, signature: "A", remainingPages: -1,
                          direction: &negativeDirection, seen: &negativeSeen) && negativeSeen.isEmpty
    let selectionDiagnostics = readTabSelectionDiagnostics("Selected tab", frame: rawSelectedB)
    checks["selection-diagnostics-selected"] =
        selectionDiagnostics["proofKind"] as? String == "selected" &&
        selectionDiagnostics["targetExactCount"] as? Int == 1
    let absentDiagnostics = readTabSelectionDiagnostics("Selected tab", frame: rawSelectedFrame(underlines: []))
    checks["selection-diagnostics-absent"] =
        absentDiagnostics["proofKind"] as? String == "absent" &&
        absentDiagnostics["targetUnderlineCounts"] as? [Int] == [0]
    let invalidDiagnostics = readTabSelectionDiagnostics("Selected tab", frame: rawSelectedFrame(candidates: [
        OCRCandidate(text: "Selected tab", confidence: 0.949,
                     normalizedBox: rawSelectedCandidate.normalizedBox),
    ]))
    checks["selection-diagnostics-invalid"] = invalidDiagnostics["proofKind"] as? String == "invalid"
    let diagnosticBadge = GreenComponent(pixelBox: CGRect(x: 0, y: 0, width: 8, height: 8),
                                         pointBox: CGRect(x: 310, y: 1, width: 4, height: 4),
                                         pixelCount: 52, meanRed: 0, meanGreen: 185,
                                         meanBlue: 33, meanAlpha: 255)
    let maskedDiagnostics = readTabSelectionDiagnostics("Selected tab", frame: rawSelectedFrame(
        candidates: [], masked: [rawSelectedCandidate], badges: [diagnosticBadge]
    ))
    checks["selection-diagnostics-masked"] =
        maskedDiagnostics["trustedSource"] as? String == "masked" &&
        maskedDiagnostics["targetExactCount"] as? Int == 1
    let diagnosticsJSON = String(data: try JSONSerialization.data(withJSONObject: selectionDiagnostics), encoding: .utf8)!
    checks["selection-diagnostics-no-names"] = !diagnosticsJSON.contains("Selected tab")
    let nonfiniteDiagnostics = readTabSelectionDiagnostics("Selected tab", frame: rawSelectedFrame(candidates: [
        OCRCandidate(text: "Selected tab", confidence: .nan,
                     normalizedBox: rawSelectedCandidate.normalizedBox),
    ]))
    checks["selection-diagnostics-nonfinite"] =
        (try? JSONSerialization.data(withJSONObject: nonfiniteDiagnostics)) != nil
    checks["ax-semantic-string-types"] =
        strictAXSemanticName(title: "Tab" as AnyObject, value: nil) == "Tab" &&
        strictAXSemanticName(title: nil, value: "Tab" as AnyObject) == "Tab" &&
        strictAXSemanticName(title: "Tab" as AnyObject, value: "Tab" as AnyObject) == "Tab" &&
        strictAXSemanticName(title: "Tab" as AnyObject, value: "Other" as AnyObject) == nil &&
        strictAXSemanticName(title: nil, value: NSNumber(value: 1)) == nil
    checks["ax-semantic-invalid-present-rejected"] =
        strictAXSemanticName(title: "bad\nname" as AnyObject, value: "Good" as AnyObject) == nil &&
        strictAXSemanticName(title: "Good" as AnyObject, value: "   " as AnyObject) == nil &&
        strictAXSemanticState(selected: "true" as AnyObject, value: NSNumber(value: 1)) == nil &&
        strictAXSemanticState(selected: NSNumber(value: 1), value: NSNumber(value: 2)) == nil
    checks["ax-semantic-mixed-name-state"] =
        strictAXSemanticName(title: "Tab" as AnyObject, value: NSNumber(value: 1)) == "Tab" &&
        strictAXSemanticState(selected: NSNumber(value: 1), value: "Tab" as AnyObject) == true &&
        strictAXSemanticState(selected: nil, value: NSNumber(value: 1)) == true &&
        strictAXSemanticState(selected: nil, value: "Tab" as AnyObject) == nil
    checks["ax-semantic-state-types"] =
        strictAXSemanticState(selected: kCFBooleanTrue, value: nil) == true &&
        strictAXSemanticState(selected: nil, value: NSNumber(value: 0)) == false &&
        strictAXSemanticState(selected: NSNumber(value: 1), value: NSNumber(value: 1)) == true &&
        strictAXSemanticState(selected: NSNumber(value: 1), value: NSNumber(value: 0)) == nil &&
        strictAXSemanticState(selected: "1" as AnyObject, value: nil) == nil &&
        strictAXSemanticState(selected: NSNumber(value: 2), value: nil) == nil
    checks["ax-semantic-calibration-gate"] =
        !axTabRouteAvailable(calibrated: false, complete: true) &&
        !axTabRouteAvailable(calibrated: true, complete: false) &&
        axTabRouteAvailable(calibrated: true, complete: true)
    let axTabA = AXUIElementCreateApplication(11)
    let axTabB = AXUIElementCreateApplication(12)
    let axItems = [
        AXTabSemanticItem(element: axTabA, role: kAXRadioButtonRole,
                          name: "One", identifier: "id-one", selected: true,
                          enabled: true, frame: CGRect(x: 0, y: 0, width: 50, height: 20)),
        AXTabSemanticItem(element: axTabB, role: kAXRadioButtonRole,
                          name: "Two", identifier: nil, selected: false,
                          enabled: true, frame: CGRect(x: 50, y: 0, width: 50, height: 20)),
    ]
    checks["ax-semantic-twofresh-stable"] = stableAXTabItems(axItems, axItems)
    checks["ax-semantic-cf-order-drift"] = !stableAXTabItems(axItems, axItems.reversed())
    var axStateDrift = axItems
    axStateDrift[1] = AXTabSemanticItem(element: axTabB, role: kAXRadioButtonRole,
                                       name: "Two", identifier: nil,
                                       selected: true, enabled: true,
                                       frame: axItems[1].frame)
    checks["ax-semantic-state-drift"] = !stableAXTabItems(axItems, axStateDrift)
    var axRoleDrift = axItems
    axRoleDrift[1] = AXTabSemanticItem(element: axTabB, role: "AXTab",
                                      name: "Two", identifier: nil,
                                      selected: false, enabled: true,
                                      frame: axItems[1].frame)
    checks["ax-semantic-role-drift"] = !stableAXTabItems(axItems, axRoleDrift)
    let exportCommon: [String: Any] = [
        "tabName": "Scope tab", "chatName": "Scope chat",
        "identityKey": String(repeating: "a", count: 64),
        "requestNonce": String(repeating: "b", count: 32),
    ]
    checks["native-export-prepare-args"] = validTextExportArguments(
        "prepareTextExportScope", exportCommon
    ) && !validTextExportArguments(
        "prepareTextExportScope", exportCommon.merging(["extra": true]) { _, new in new }
    )
    let exportArgs = exportCommon.merging([
        "expectedProofDigest": String(repeating: "c", count: 64),
        "outputDirectory": "/private/tmp/line-export-fixture",
        "outputFileName": String(repeating: "d", count: 32) + ".txt",
    ]) { _, new in new }
    checks["native-export-action-args"] = validTextExportArguments("exportChatText", exportArgs)
    var traversalExport = exportArgs
    traversalExport["outputDirectory"] = "/private/tmp/../escape"
    var badNameExport = exportArgs
    badNameExport["outputFileName"] = "chat.txt"
    checks["native-export-path-rejected"] =
        !validTextExportArguments("exportChatText", traversalExport) &&
        !validTextExportArguments("exportChatText", badNameExport)
    do {
        _ = try textExportCalibrationRequired("exportChatText", exportArgs)
        checks["native-export-calibration-zero-side-effects"] = false
    } catch let failure as NativeFailure {
        checks["native-export-calibration-zero-side-effects"] =
            failure.code == "AX_EXPORT_CALIBRATION_REQUIRED" &&
            failure.details["sideEffectsAttempted"] as? Bool == false &&
            failure.details["phase"] as? String == "pre_commit"
    }
    checks["qt-raw-selected-ignores-processed-zero-click"] =
        try stableRawSelectedTab(["Selected tab"], first: rawSelectedA, second: rawSelectedB)?.0 == "Selected tab"
    checks["qt-raw-selected-0949-rejected"] = {
        if case .invalid = rawSelectedProof(["Selected tab"], frame: rawSelectedFrame(candidates: [
            OCRCandidate(text: "Selected tab", confidence: 0.949,
                         normalizedBox: rawSelectedCandidate.normalizedBox),
        ])) { return true }
        return false
    }()
    checks["qt-raw-selected-duplicate-rejected"] = {
        if case .invalid = rawSelectedProof(["Selected tab"], frame: rawSelectedFrame(
            candidates: [rawSelectedCandidate, rawSelectedCandidate]
        )) { return true }
        return false
    }()
    checks["qt-raw-selected-multiple-underline-rejected"] = {
        let extra = UnderlineComponent(pointBox: rawSelectedUnderline.pointBox.offsetBy(dx: 2, dy: 0),
                                       pixelCount: 470, meanLuma: 20, fillRatio: 1)
        if case .invalid = rawSelectedProof(["Selected tab"], frame: rawSelectedFrame(
            underlines: [rawSelectedUnderline, extra]
        )) { return true }
        return false
    }()
    checks["qt-raw-selected-competing-selected-rejected"] = {
        let other = OCRCandidate(text: "Other tab", confidence: 0.99,
                                 normalizedBox: CGRect(x: 0.55, y: 0.2, width: 0.18, height: 0.5))
        let otherUnderline = UnderlineComponent(pointBox: CGRect(x: 385, y: 36, width: 110, height: 2),
                                                pixelCount: 440, meanLuma: 20, fillRatio: 1)
        if case .invalid = rawSelectedProof(["Selected tab"], frame: rawSelectedFrame(
            candidates: [rawSelectedCandidate, other],
            underlines: [rawSelectedUnderline, otherUnderline]
        )) { return true }
        return false
    }()
    checks["qt-raw-visible-unselected-allows-fallback"] = [Float(0.50), Float(0.99)].allSatisfy { confidence in
        let visibleTarget = OCRCandidate(text: "Selected tab", confidence: confidence,
                                         normalizedBox: rawSelectedCandidate.normalizedBox)
        let actualSelected = OCRCandidate(text: "Other tab", confidence: 0.99,
                                          normalizedBox: CGRect(x: 0.55, y: 0.2, width: 0.18, height: 0.5))
        let otherUnderline = UnderlineComponent(pointBox: CGRect(x: 385, y: 36, width: 110, height: 2),
                                                pixelCount: 440, meanLuma: 20, fillRatio: 1)
        if case .absent = rawSelectedProof(["Selected tab"], frame: rawSelectedFrame(
            candidates: [visibleTarget, actualSelected], underlines: [otherUnderline]
        )) { return true }
        return false
    }
    let rawCandidateDrift = rawSelectedFrame(candidates: [
        OCRCandidate(text: "Selected tab", confidence: 0.99,
                     normalizedBox: rawSelectedCandidate.normalizedBox.offsetBy(dx: 0.1, dy: 0)),
    ])
    do {
        _ = try stableRawSelectedTab(["Selected tab"], first: rawSelectedA, second: rawCandidateDrift)
        checks["qt-raw-selected-candidate-drift-rejected"] = false
    } catch { checks["qt-raw-selected-candidate-drift-rejected"] = true }
    let rawUnderlineDrift = rawSelectedFrame(underlines: [
        UnderlineComponent(pointBox: rawSelectedUnderline.pointBox.offsetBy(dx: 130, dy: 0),
                           pixelCount: 480, meanLuma: 20, fillRatio: 1),
    ])
    do {
        _ = try stableRawSelectedTab(["Selected tab"], first: rawSelectedA, second: rawUnderlineDrift)
        checks["qt-raw-selected-underline-drift-rejected"] = false
    } catch { checks["qt-raw-selected-underline-drift-rejected"] = true }
    do {
        _ = try stableRawSelectedTab(["Selected tab"], first: rawSelectedA,
                                     second: rawSelectedFrame(roi: roi.offsetBy(dx: 2, dy: 0)))
        checks["qt-raw-selected-roi-drift-rejected"] = false
    } catch { checks["qt-raw-selected-roi-drift-rejected"] = true }
    do {
        _ = try stableRawSelectedTab(["Selected tab"], first: rawSelectedA,
                                     second: rawSelectedFrame(imageWidth: 901))
        checks["qt-raw-selected-dimensions-drift-rejected"] = false
    } catch { checks["qt-raw-selected-dimensions-drift-rejected"] = true }
    let signatureDrift = WindowIdentity(pid: identity.pid, windowID: identity.windowID,
                                        title: identity.title, bounds: identity.bounds,
                                        executableURL: identity.executableURL,
                                        signingIdentifier: "OTHER", teamIdentifier: identity.teamIdentifier)
    do {
        _ = try stableRawSelectedTab(["Selected tab"], first: rawSelectedA,
                                     second: rawSelectedFrame(identity: signatureDrift))
        checks["qt-raw-selected-window-signature-drift-rejected"] = false
    } catch { checks["qt-raw-selected-window-signature-drift-rejected"] = true }
    let badgeA = GreenComponent(pixelBox: CGRect(x: 0, y: 0, width: 8, height: 8),
                                pointBox: CGRect(x: 310, y: 1, width: 4, height: 4), pixelCount: 52,
                                meanRed: 0, meanGreen: 185, meanBlue: 33, meanAlpha: 255)
    let badgeB = GreenComponent(pixelBox: badgeA.pixelBox,
                                pointBox: badgeA.pointBox.offsetBy(dx: 20, dy: 0), pixelCount: 52,
                                meanRed: 0, meanGreen: 185, meanBlue: 33, meanAlpha: 255)
    let badgedA = rawSelectedFrame(candidates: [], masked: [rawSelectedCandidate], badges: [badgeA])
    let badgedB = rawSelectedFrame(candidates: [], masked: [rawSelectedCandidate], badges: [badgeB])
    do {
        _ = try stableRawSelectedTab(["Selected tab"], first: badgedA, second: badgedB)
        checks["qt-raw-selected-badge-drift-rejected"] = false
    } catch { checks["qt-raw-selected-badge-drift-rejected"] = true }
    do {
        _ = try stableRawSelectedTab(["Selected tab"], first: rawSelectedA,
                                     second: rawSelectedFrame(underlines: []))
        checks["qt-raw-selected-second-invalid-no-fallback"] = false
    } catch { checks["qt-raw-selected-second-invalid-no-fallback"] = true }
    let wheelWindow = CGRect(x: -900, y: 40, width: 900, height: 700)
    let wheelList = CGRect(x: -880, y: 180, width: 280, height: 500)
    let validWheelProbe = MetadataWheelProbe(
        foreground: true, windowMatches: true, tabSelected: true, listStable: true,
        windowFrame: wheelWindow, listFrame: wheelList
    )
    let topWheel = metadataWheelIntent(validWheelProbe, direction: .top, remainingSteps: 20)
    let endWheel = metadataWheelIntent(validWheelProbe, direction: .end, remainingSteps: 20)
    checks["qt-wheel-point-delta-budget"] = topWheel?.delta == 180 && endWheel?.delta == -180 &&
        topWheel.map { wheelList.contains($0.point) } == true &&
        metadataWheelIntent(validWheelProbe, direction: .top, remainingSteps: 0) == nil
    checks["qt-wheel-deadline-budget-blocked"] =
        metadataWheelLimitReason(remainingSteps: 0, now: 10, deadline: 20) == "SCAN_BUDGET" &&
        metadataWheelLimitReason(remainingSteps: 1, now: 20, deadline: 20) == "SCAN_DEADLINE" &&
        metadataWheelLimitReason(remainingSteps: 1, now: 10, deadline: 20) == nil
    var rejectedWheelEvents = 0
    let unsafeWheelProbes = [
        MetadataWheelProbe(foreground: false, windowMatches: true, tabSelected: true, listStable: true,
                           windowFrame: wheelWindow, listFrame: wheelList),
        MetadataWheelProbe(foreground: true, windowMatches: false, tabSelected: true, listStable: true,
                           windowFrame: wheelWindow, listFrame: wheelList),
        MetadataWheelProbe(foreground: true, windowMatches: true, tabSelected: false, listStable: true,
                           windowFrame: wheelWindow, listFrame: wheelList),
        MetadataWheelProbe(foreground: true, windowMatches: true, tabSelected: true, listStable: false,
                           windowFrame: wheelWindow, listFrame: wheelList),
        MetadataWheelProbe(foreground: true, windowMatches: true, tabSelected: true, listStable: true,
                           windowFrame: wheelWindow, listFrame: wheelList.offsetBy(dx: 1_000, dy: 0)),
    ]
    for probe in unsafeWheelProbes {
        if metadataWheelIntent(probe, direction: .end, remainingSteps: 20) != nil {
            rejectedWheelEvents += 1
        }
    }
    checks["qt-wheel-unsafe-preflight-zero-event"] = rejectedWheelEvents == 0
    let noProgress = metadataNoProgressReasons(
        previous: "same", current: "same", boundaryVerified: false, direction: .end
    )
    checks["qt-wheel-no-progress-unknown-boundary-incomplete"] =
        noProgress == ["SCROLL_PROGRESS_UNVERIFIED", "END_BOUNDARY_UNVERIFIED"] &&
        !metadataScanComplete(topBoundary: true, endBoundary: false, reasons: noProgress)
    checks["qt-wheel-independent-boundaries-complete"] =
        metadataNoProgressReasons(previous: "same", current: "same",
                                  boundaryVerified: true, direction: .top).isEmpty &&
        metadataScanComplete(topBoundary: true, endBoundary: true, reasons: [])
    let belowThreshold = OCRCandidate(text: "Scope tab", confidence: 0.949,
                                      normalizedBox: candidate.normalizedBox)
    checks["ocr-processed-0949-rejected"] = exactOCRMatches(
        "Scope tab", in: syntheticOCR([candidate], [belowThreshold])
    ).isEmpty
    checks["ocr-processed-095-accepted"] = exactOCRMatches(
        "Scope tab", in: syntheticOCR([candidate], [
            OCRCandidate(text: "Scope tab", confidence: 0.95,
                         normalizedBox: candidate.normalizedBox),
        ])
    ).count == 1
    checks["ocr-header-raw-high-confidence-retained"] = exactOCRMatches(
        "Header", in: OCRFrame(identity: identity, roi: roi, imageWidth: 900, imageHeight: 700,
                               candidates: [OCRCandidate(text: "Header", confidence: 0.95,
                                                         normalizedBox: candidate.normalizedBox)],
                               maskedCandidates: [], processedCandidates: [], processedPolicyApplied: false,
                               greenComponents: [], underlineComponents: [])
    ).count == 1
    let iou0799 = OCRCandidate(text: "Scope tab", confidence: 0.96,
                               normalizedBox: candidate.normalizedBox.offsetBy(dx: 0.02235, dy: 0))
    checks["ocr-processed-iou-0799-rejected"] = intersectionOverUnion(
        candidate.normalizedBox, iou0799.normalizedBox
    ) < 0.80 && exactOCRMatches("Scope tab", in: syntheticOCR([candidate], [iou0799])).isEmpty
    checks["ocr-processed-only-rejected"] = exactOCRMatches(
        "Scope tab", in: syntheticOCR([], [processedCandidate])
    ).isEmpty
    checks["ocr-processed-prefix-rejected"] = exactOCRMatches(
        "Scope tab", in: syntheticOCR([
            OCRCandidate(text: "Prefix Scope tab", confidence: 0.50, normalizedBox: candidate.normalizedBox),
        ], [processedCandidate])
    ).isEmpty
    checks["ocr-processed-suffix-rejected"] = exactOCRMatches(
        "Scope tab", in: syntheticOCR([
            OCRCandidate(text: "Scope tab suffix", confidence: 0.50, normalizedBox: candidate.normalizedBox),
        ], [processedCandidate])
    ).isEmpty
    checks["ocr-processed-conflict-rejected"] = exactOCRMatches(
        "Scope tab", in: syntheticOCR([
            candidate, OCRCandidate(text: "Different", confidence: 0.99,
                                    normalizedBox: candidate.normalizedBox),
        ], [processedCandidate])
    ).count > 1
    let overlapTargetBox = CGRect(x: 0.1, y: 0.4, width: 0.3, height: 0.3)
    let overlapRaw = OCRCandidate(text: "Overlap target", confidence: 0.50,
                                  normalizedBox: overlapTargetBox)
    let overlapProcessed = OCRCandidate(text: "Overlap target", confidence: 0.96,
                                        normalizedBox: overlapTargetBox)
    let partialOther = OCRCandidate(text: "Other", confidence: 0.99,
                                    normalizedBox: CGRect(x: 0.1, y: 0.4, width: 0.15, height: 0.3))
    checks["ocr-raw-partial-overlap-conflict-rejected"] = exactOCRMatches(
        "Overlap target", in: syntheticOCR([overlapRaw, partialOther], [overlapProcessed])
    ).count != 1
    checks["ocr-processed-partial-overlap-conflict-rejected"] = exactOCRMatches(
        "Overlap target", in: syntheticOCR([overlapRaw], [overlapProcessed, partialOther])
    ).count != 1
    let touchingOther = OCRCandidate(text: "Touching", confidence: 0.99,
                                     normalizedBox: CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.3))
    checks["ocr-zero-area-touch-not-conflict"] = exactOCRMatches(
        "Overlap target", in: syntheticOCR([overlapRaw, touchingOther], [overlapProcessed])
    ).count == 1
    let lowDuplicate = OCRCandidate(text: "Overlap target", confidence: 0.50,
                                    normalizedBox: CGRect(x: 0.55, y: 0.4, width: 0.2, height: 0.3))
    checks["ocr-processed-low-confidence-duplicate-rejected"] = exactOCRMatches(
        "Overlap target", in: syntheticOCR([overlapRaw], [overlapProcessed, lowDuplicate])
    ).count != 1
    checks["ocr-processed-duplicate-rejected"] = exactOCRMatches(
        "Scope tab", in: syntheticOCR([candidate], [processedCandidate, processedCandidate])
    ).count > 1
    checks["ocr-invalid-bbox-rejected"] = exactOCRMatches(
        "Scope tab", in: syntheticOCR([candidate], [
            OCRCandidate(text: "Scope tab", confidence: 0.96,
                         normalizedBox: CGRect(x: .nan, y: 0.2, width: 0.2, height: 0.5)),
        ])
    ).isEmpty
    checks["global-all-merged-token-boundaries"] =
        allNavigationTokenRanges("全部 好友").map(\.label) == ["全部"] &&
        allNavigationTokenRanges("好友 All").map(\.label) == ["All"] &&
        allNavigationTokenRanges("全部好友").isEmpty &&
        allNavigationTokenRanges("前全部 後").isEmpty
    let rawAllHigh = OCRCandidate(text: "全部", confidence: 0.99,
                                  normalizedBox: candidate.normalizedBox)
    checks["global-all-raw-exact-unique"] = allNavigationExactMatches(
        "全部", in: rawSelectedFrame(candidates: [rawAllHigh], underlines: [])
    ).count == 1
    checks["global-all-raw-low-duplicate-rejected"] = allNavigationExactMatches(
        "全部", in: rawSelectedFrame(candidates: [rawAllHigh, OCRCandidate(
            text: "全部", confidence: 0.1,
            normalizedBox: candidate.normalizedBox.offsetBy(dx: 0.3, dy: 0)
        )], underlines: [])
    ).isEmpty
    checks["global-all-raw-other-literal-rejected"] = allNavigationExactMatches(
        "全部", in: rawSelectedFrame(candidates: [rawAllHigh, OCRCandidate(
            text: "All", confidence: 0.1,
            normalizedBox: candidate.normalizedBox.offsetBy(dx: 0.3, dy: 0)
        )], underlines: [])
    ).isEmpty
    checks["global-all-raw-merged-duplicate-rejected"] = allNavigationExactMatches(
        "全部", in: rawSelectedFrame(candidates: [rawAllHigh, OCRCandidate(
            text: "All 好友", confidence: 0.1,
            normalizedBox: candidate.normalizedBox.offsetBy(dx: 0.3, dy: 0)
        )], underlines: [])
    ).isEmpty
    checks["global-all-raw-invalid-bbox-rejected"] = allNavigationExactMatches(
        "全部", in: rawSelectedFrame(candidates: [rawAllHigh, OCRCandidate(
            text: "無關", confidence: 0.1,
            normalizedBox: CGRect(x: .nan, y: 0, width: 0.1, height: 0.1)
        )], underlines: [])
    ).isEmpty
    let noisyAll = OCRCandidate(
        text: "全部", confidence: 1,
        normalizedBox: CGRect(x: 0.2, y: 0.4500000089856,
                              width: 0.2, height: 0.55)
    )
    let canonicalAll = canonicalReadOCRCandidates(
        [noisyAll], imageWidth: 907, imageHeight: 39
    )
    let noisyUnderline = UnderlineComponent(
        pointBox: CGRect(x: 140, y: 36, width: 140, height: 2),
        pixelCount: 280, meanLuma: 20, fillRatio: 1
    )
    let noisyAllFrame = rawSelectedFrame(
        candidates: canonicalAll, masked: canonicalAll,
        imageWidth: 907, imageHeight: 39, underlines: [noisyUnderline]
    )
    checks["global-all-rgb-noise-canonicalized"] = canonicalAll.count == 1 &&
        canonicalAll[0].text == noisyAll.text && canonicalAll[0].confidence == noisyAll.confidence &&
        validNormalizedBox(canonicalAll[0].normalizedBox) &&
        !noisyAllFrame.processedPolicyApplied &&
        globalAllCode(noisyAllFrame, noisyAllFrame) == "OK"
    let retainedInvalid = [
        OCRCandidate(text: "其他", confidence: 1,
                     normalizedBox: CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.5222)),
        OCRCandidate(text: "NaN", confidence: 1,
                     normalizedBox: CGRect(x: .nan, y: 0.2, width: 0.1, height: 0.1)),
        OCRCandidate(text: "Inf", confidence: 1,
                     normalizedBox: CGRect(x: 0.2, y: 0.2, width: .infinity, height: 0.1)),
        OCRCandidate(text: "Zero", confidence: 1,
                     normalizedBox: CGRect(x: 0.2, y: 0.2, width: 0, height: 0.1)),
    ]
    let retainedMapped = canonicalReadOCRCandidates(
        [noisyAll] + retainedInvalid, imageWidth: 907, imageHeight: 39
    )
    // 較舊Swift對zip、閉包與布林鏈同時推導成本過高；拆開但保留全部檢查。
    let retainedOriginal: [OCRCandidate] = [noisyAll] + retainedInvalid
    let retainedValuesUnchanged: Bool = zip(retainedMapped, retainedOriginal).allSatisfy { pair in
        pair.0.text == pair.1.text && pair.0.confidence == pair.1.confidence
    }
    let retainedInvalidUnchanged: Bool = retainedMapped.dropFirst().allSatisfy { candidate in
        !validNormalizedBox(candidate.normalizedBox)
    }
    let retainedFrame = rawSelectedFrame(candidates: retainedMapped, masked: retainedMapped,
                                        imageWidth: 907, imageHeight: 39, underlines: [noisyUnderline])
    let retainedNoFalseMatch: Bool = allNavigationExactMatches("全部", in: retainedFrame).isEmpty
    checks["global-all-rgb-invalid-retained"] = retainedMapped.count == 5 &&
        retainedValuesUnchanged && retainedInvalidUnchanged && retainedNoFalseMatch

    let realRawBox = CGRect(x: 0.010968365855853496, y: 0.44510646650742003,
                            width: 0.0485483245177416, height: 0.40566396713256847)
    let realProcessedBox = CGRect(x: 0.011627906754786988, y: 0.49999999588801458,
                                  width: 0.031976743990426028, height: 0.37179487179487181)
    let mergedParent = OCRCandidate(text: "全部 好友", confidence: 0.3,
                                    normalizedBox: realRawBox)
    let mergedProcessed = OCRCandidate(text: "全部", confidence: 1,
                                       normalizedBox: realProcessedBox)
    let realToken = MergedAllRawToken(parentIndex: 0, label: "全部",
                                      normalizedBox: realRawBox)
    checks["global-all-merged-real-geometry"] = mergedAllNavigationCandidate(
        rawTokens: [realToken], rawCandidates: [mergedParent],
        processedCandidates: [mergedProcessed], originalWidth: 907, originalHeight: 39
    )?.text == "全部"
    checks["global-all-merged-duplicates-rejected"] = mergedAllNavigationCandidate(
        rawTokens: [realToken, MergedAllRawToken(parentIndex: 1, label: "全部",
                                                 normalizedBox: realRawBox.offsetBy(dx: 0.2, dy: 0))],
        rawCandidates: [mergedParent, OCRCandidate(text: "全部", confidence: 0.1,
                                                   normalizedBox: realRawBox.offsetBy(dx: 0.2, dy: 0))],
        processedCandidates: [mergedProcessed], originalWidth: 907, originalHeight: 39
    ) == nil && mergedAllNavigationCandidate(
        rawTokens: [realToken], rawCandidates: [mergedParent],
        processedCandidates: [mergedProcessed, OCRCandidate(text: "All", confidence: 0.1,
                                                              normalizedBox: realProcessedBox)],
        originalWidth: 907, originalHeight: 39
    ) == nil
    checks["global-all-merged-threshold"] = mergedAllNavigationCandidate(
        rawTokens: [realToken], rawCandidates: [mergedParent],
        processedCandidates: [OCRCandidate(text: "全部", confidence: 0.949,
                                            normalizedBox: realProcessedBox)],
        originalWidth: 907, originalHeight: 39
    ) == nil && mergedAllNavigationCandidate(
        rawTokens: [realToken], rawCandidates: [mergedParent],
        processedCandidates: [OCRCandidate(text: "全部", confidence: 0.95,
                                            normalizedBox: realProcessedBox)],
        originalWidth: 907, originalHeight: 39
    ) != nil
    checks["global-all-merged-containment-area"] = mergedAllNavigationCandidate(
        rawTokens: [MergedAllRawToken(parentIndex: 0, label: "全部",
                                      normalizedBox: CGRect(x: 0.2, y: 0.2, width: 0.1, height: 0.1))],
        rawCandidates: [mergedParent],
        processedCandidates: [OCRCandidate(text: "全部", confidence: 1,
                                            normalizedBox: CGRect(x: 0.19, y: 0.22,
                                                                  width: 0.08, height: 0.08))],
        originalWidth: 907, originalHeight: 39
    ) == nil && mergedAllNavigationCandidate(
        rawTokens: [MergedAllRawToken(parentIndex: 0, label: "全部",
                                      normalizedBox: CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2))],
        rawCandidates: [mergedParent],
        processedCandidates: [OCRCandidate(text: "全部", confidence: 1,
                                            normalizedBox: CGRect(x: 0.22, y: 0.22,
                                                                  width: 0.1, height: 0.1))],
        originalWidth: 907, originalHeight: 39
    ) == nil
    let mergedConflict = OCRCandidate(text: "好友", confidence: 0.99,
                                      normalizedBox: realProcessedBox.offsetBy(dx: 0.01, dy: 0))
    let mergedTouch = OCRCandidate(text: "好友", confidence: 0.99,
                                   normalizedBox: CGRect(x: realProcessedBox.maxX,
                                                         y: realProcessedBox.minY,
                                                         width: 0.02, height: realProcessedBox.height))
    checks["global-all-merged-conflict-overlap"] = mergedAllNavigationCandidate(
        rawTokens: [realToken], rawCandidates: [mergedParent, mergedConflict],
        processedCandidates: [mergedProcessed], originalWidth: 907, originalHeight: 39
    ) == nil && mergedAllNavigationCandidate(
        rawTokens: [realToken], rawCandidates: [mergedParent, mergedTouch],
        processedCandidates: [mergedProcessed], originalWidth: 907, originalHeight: 39
    ) != nil
    checks["global-all-merged-invalid-box"] = mergedAllNavigationCandidate(
        rawTokens: [MergedAllRawToken(parentIndex: 0, label: "全部",
                                      normalizedBox: CGRect(x: .nan, y: 0, width: 0.1, height: 0.1))],
        rawCandidates: [mergedParent], processedCandidates: [mergedProcessed],
        originalWidth: 907, originalHeight: 39
    ) == nil
    checks["global-all-merged-missing-box-token-rejected"] = mergedAllNavigationCandidate(
        rawTokens: [MergedAllRawToken(parentIndex: 0, label: "全部", normalizedBox: .null),
                    realToken],
        rawCandidates: [mergedParent], processedCandidates: [mergedProcessed],
        originalWidth: 907, originalHeight: 39
    ) == nil
    checks["global-all-merged-invalid-candidate-rejected"] = mergedAllNavigationCandidate(
        rawTokens: [realToken], rawCandidates: [mergedParent, OCRCandidate(
            text: "無關", confidence: 0.1,
            normalizedBox: CGRect(x: .nan, y: 0, width: 0.1, height: 0.1)
        )], processedCandidates: [mergedProcessed], originalWidth: 907, originalHeight: 39
    ) == nil && mergedAllNavigationCandidate(
        rawTokens: [realToken], rawCandidates: [mergedParent],
        processedCandidates: [mergedProcessed, OCRCandidate(
            text: "無關", confidence: 0.1,
            normalizedBox: CGRect(x: 0, y: 0, width: .nan, height: 0.1)
        )], originalWidth: 907, originalHeight: 39
    ) == nil
    let driftIdentity = WindowIdentity(pid: 1, windowID: 9, title: expectedWindowTitle,
                                       bounds: window.offsetBy(dx: 5, dy: 0), executableURL: identity.executableURL,
                                       signingIdentifier: bundleIdentifier, teamIdentifier: "TEST")
    let drift = OCRFrame(identity: driftIdentity, roi: roi.offsetBy(dx: 5, dy: 0), imageWidth: 900,
                         imageHeight: 700, candidates: [candidate], maskedCandidates: [],
                         processedCandidates: [processedCandidate], processedPolicyApplied: true,
                         greenComponents: [], underlineComponents: [])
    do { _ = try stableOCRTarget("Scope tab", first: first, second: drift); checks["geometry-drift-rejected"] = false }
    catch let failure as NativeFailure { checks["geometry-drift-rejected"] = failure.code == "WINDOW_CHANGED" }
    let overlays: [[String: Any]] = [[kCGWindowNumber as String: 10,
                                      kCGWindowBounds as String: ["X": -850, "Y": 95, "Width": 100, "Height": 20]]]
    checks["overlay-rejected"] = overlayIntersects(identity, roi: roi, windows: overlays)
    checks["splitgroup-1pt-sibling-jitter"] = containsWithTolerance(
        CGRect(x: 908, y: 165, width: 604, height: 539),
        CGRect(x: 908, y: 164, width: 604, height: 419)
    )
    let rows = deduplicateRowProbes([
        RowProbe(elementID: 1, parentElementID: nil, name: "Same"),
        RowProbe(elementID: 1, parentElementID: 1, name: "Same"),
        RowProbe(elementID: 2, parentElementID: nil, name: "Same"),
    ])
    checks["same-element-row-deduplicated"] = rows.count == 2
    checks["same-name-distinct-rows-preserved"] = rows.map(\.name) == ["Same", "Same"]
    checks["scroll-overlap-identifier-deduplicated"] = mergeSyntheticScanPages([
        [("1", "A"), ("2", "B")], [("2", "B"), ("3", "C")], [("2", "B"), ("3", "C")],
    ]) == ["A", "B", "C"]
    checks["scroll-same-name-distinct-identifiers-preserved"] = mergeSyntheticScanPages([
        [("1", "Same")], [("2", "Same")],
    ]) == ["Same", "Same"]
    let mergedTabs = mergeOrderedTabPage(["A", "B", "C"], ["B", "C", "D"])
    checks["p2-tab-pages-overlap-merged"] = mergedTabs.1 && mergedTabs.0 == ["A", "B", "C", "D"]
    let duplicateTabs = mergeOrderedTabPage(["A", "B"], ["B", "A"])
    checks["p2-tab-pages-duplicate-preserved"] = duplicateTabs.1 && duplicateTabs.0 == ["A", "B", "A"]
    checks["p2-tab-pages-gap-rejected"] = !mergeOrderedTabPage(["A"], ["C"]).1
    checks["refinement-suffix-digit-rejected"] = !refinementSourceAuthorizesIdentity("Scope tab 2", target: "Scope tab")
    checks["refinement-prefix-rejected"] = !refinementSourceAuthorizesIdentity("Other Scope tab", target: "Scope tab")
    checks["refinement-apostrophe-rejected"] = !refinementSourceAuthorizesIdentity("Scope tab'", target: "Scope tab")
    let circle = GreenComponent(pixelBox: CGRect(x: 0, y: 0, width: 10, height: 10),
                                pointBox: CGRect(x: 20, y: 1, width: 5, height: 5), pixelCount: 78,
                                meanRed: 20, meanGreen: 200, meanBlue: 70, meanAlpha: 255)
    checks["badge-small-top-circle-eligible"] = badgeGeometryEligible(circle, roiHeight: 39)
    let baselineEmoji = GreenComponent(pixelBox: circle.pixelBox,
                                       pointBox: CGRect(x: 20, y: 12, width: 5, height: 5), pixelCount: 78,
                                       meanRed: 20, meanGreen: 200, meanBlue: 70, meanAlpha: 255)
    checks["badge-baseline-emoji-rejected"] = !badgeGeometryEligible(baselineEmoji, roiHeight: 39)
    let large = GreenComponent(pixelBox: CGRect(x: 0, y: 0, width: 20, height: 20),
                               pointBox: CGRect(x: 20, y: 1, width: 10, height: 10), pixelCount: 300,
                               meanRed: 20, meanGreen: 200, meanBlue: 70, meanAlpha: 255)
    checks["badge-large-component-rejected"] = !badgeGeometryEligible(large, roiHeight: 39)
    let bar = GreenComponent(pixelBox: CGRect(x: 0, y: 0, width: 16, height: 4),
                             pointBox: CGRect(x: 20, y: 1, width: 8, height: 2), pixelCount: 50,
                             meanRed: 20, meanGreen: 200, meanBlue: 70, meanAlpha: 255)
    checks["badge-nonround-component-rejected"] = !badgeGeometryEligible(bar, roiHeight: 39)
    let markerRows: [UInt8] = [3, 3, 3, 3, 2, 2, 2, 2, 1, 1, 1, 1]
    checks["badge-row-origin-roundtrip"] = topDownRows(markerRows, bytesPerRow: 4, height: 3) ==
        [1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3]
    let syntheticPixels: [UInt8] = [
        255, 0, 0, 255, 0, 255, 0, 255,
        0, 0, 255, 255, 255, 255, 255, 255,
    ]
    if let synthetic = rgbaImage(topDown: syntheticPixels, width: 2, height: 2),
       let rendered = try? rgbaBottomUp(synthetic) {
        checks["popup-inmemory-corner-roundtrip"] = rendered.0.prefix(4).elementsEqual([0, 0, 255, 255]) &&
            rendered.0.suffix(4).elementsEqual([0, 255, 0, 255])
    } else { checks["popup-inmemory-corner-roundtrip"] = false }
    let messageList = CGRect(x: 908, y: 164, width: 604, height: 419)
    let liveWindow = CGRect(x: 543, y: 54, width: 969, height: 650)
    checks["message-row-inside-container-visible"] = visibleMessageRow(
        listFrame: messageList, rowFrame: CGRect(x: 920, y: 200, width: 500, height: 40), window: liveWindow
    )
    checks["message-row-negative-offscreen-rejected"] = !visibleMessageRow(
        listFrame: messageList, rowFrame: CGRect(x: 920, y: -40, width: 500, height: 40), window: liveWindow
    )
    let nestedPre = NativeFailure("WINDOW_CHANGED", "fixture", ["phase": "pre_commit"])
    checks["mutation-nested-pre-overridden"] = forcingPhase(nestedPre, "post_commit").details["phase"] as? String == "post_commit"
    checks["mutation-draft-attempt-post"] = phaseAfterMutationAttempt(true, nestedPhase: "pre_commit") == "post_commit"
    checks["page-budget-5"] = try historyPageBudget(5).target == 5
    checks["page-budget-10"] = try historyPageBudget(10).target == 10
    checks["page-budget-50"] = try historyPageBudget(50).target == 50
    let hundredPages = try historyPageBudget(100)
    checks["page-budget-100-capped"] = hundredPages.target == 50 && hundredPages.reasons == ["PAGE_BUDGET"]
    checks["page-budget-time-stop"] = historyPagingShouldStop(applied: 3, target: 10,
                                                               now: 20, deadline: 20) == "PAGE_TIME_LIMIT"
    let firstHistorySlice = historyPageSlice(total: 5, offset: 0, limit: 2, earliestBoundary: false)
    let secondHistorySlice = historyPageSlice(total: 5, offset: 2, limit: 2, earliestBoundary: false)
    checks["p3-offset-no-skipped-rows"] = Array(firstHistorySlice!.range) + Array(secondHistorySlice!.range) == [0, 1, 2, 3]
    checks["p3-scroll-only-after-viewport-exhausted"] = firstHistorySlice?.advance == false &&
        historyPageSlice(total: 2, offset: 2, limit: 2, earliestBoundary: false)?.advance == true
    checks["p3-earliest-boundary-terminal"] = historyPageSlice(
        total: 2, offset: 0, limit: 2, earliestBoundary: true
    )?.terminal == true
    checks["p3-single-id-overlap-retained"] = historyOverlapMask(
        ids: [String(repeating: "a", count: 64), nil, String(repeating: "b", count: 64)],
        seenIds: [String(repeating: "a", count: 64)], afterPhysicalScroll: true
    ) == [true, true, true]
    checks["p3-ordered-overlap-deduplicated"] = historyOverlapMask(
        ids: [String(repeating: "a", count: 64), String(repeating: "b", count: 64),
              String(repeating: "c", count: 64)],
        seenIds: [String(repeating: "a", count: 64), String(repeating: "b", count: 64)],
        afterPhysicalScroll: true
    ) == [false, false, true]
    checks["p3-same-viewport-seen-id-not-dropped"] = historyOverlapMask(
        ids: [String(repeating: "a", count: 64)],
        seenIds: [String(repeating: "a", count: 64)], afterPhysicalScroll: false
    ) == [true]
    checks["p3-random-id-flags-duplicates"] = historyPossibleDuplicates(
        base: false, overlapUnverified: false, emittedIdentityVerified: [true, false]
    )
    checks["p3-stable-ids-no-false-duplicate"] = !historyPossibleDuplicates(
        base: false, overlapUnverified: false, emittedIdentityVerified: [true, true]
    )
    checks["p3-repeated-page-not-terminal"] = historyScrollProgress(
        previousAnchor: String(repeating: "a", count: 64),
        currentAnchor: String(repeating: "a", count: 64), actualEarliestBoundary: false
    ) == .repeatedUnverified
    checks["p3-repeated-page-no-continuation"] = historyContinuationUnsafe(
        structurePartial: false, messagePartial: false, hasRows: true, repeatedPage: true
    )
    checks["p3-repeated-page-complete-false"] = !historyComplete(
        nextStateExists: false, syncState: "complete", truncated: false,
        possibleDuplicates: false, hasUnknownDate: false,
        reasons: ["REPEATED_PAGE", "SCROLL_PROGRESS_UNVERIFIED"]
    )
    checks["p3-same-page-real-boundary-terminal"] = historyScrollProgress(
        previousAnchor: String(repeating: "a", count: 64),
        currentAnchor: String(repeating: "a", count: 64), actualEarliestBoundary: true
    ) == .terminalBoundary
    checks["p3-changed-page-progress-verified"] = historyScrollProgress(
        previousAnchor: String(repeating: "a", count: 64),
        currentAnchor: String(repeating: "b", count: 64), actualEarliestBoundary: false
    ) == .advanced
    let historyKey = Data(repeating: 0x5a, count: 32)
    let stableHistoryID = historyObservedID(key: historyKey, tabName: "Scope tab",
                                            chatName: "Scope chat", axIdentifier: "AX-ID-1")
    checks["p3-hmac-id-lower-hex-64"] = lowerHex64(stableHistoryID) != nil
    checks["p3-hmac-id-scope-bound"] = stableHistoryID != historyObservedID(
        key: historyKey, tabName: "Other tab", chatName: "Scope chat", axIdentifier: "AX-ID-1"
    )
    checks["p3-hmac-id-does-not-use-message-text"] = stableHistoryID == historyObservedID(
        key: historyKey, tabName: "Scope tab", chatName: "Scope chat", axIdentifier: "AX-ID-1"
    )
    checks["p3-content-anchor-detects-text-drift"] = historyMAC(
        historyKey, ["purpose": "line-history-anchor-text-v1", "text": "first"]
    ) != historyMAC(historyKey, ["purpose": "line-history-anchor-text-v1", "text": "second"])
    checks["p3-date-leap-day-valid"] = verifiedGregorianDate("2024-02-29") == "2024-02-29"
    checks["p3-date-nonleap-invalid"] = verifiedGregorianDate("2023-02-29") == nil
    checks["p3-body-date-not-separator"] = verifiedDateSeparator(
        role: kAXStaticTextRole, outsideMessageRow: false, text: "2026-10-24"
    ) == nil
    checks["p3-relative-date-unknown"] = verifiedDateSeparator(
        role: kAXStaticTextRole, outsideMessageRow: true, text: "今天"
    ) == nil
    let bothBoundaries = scrollBoundaryEvidence(value: 0, minimum: 0, maximum: 0)
    checks["p3-scroll-boundary-both-verified"] = bothBoundaries?.earliest == true && bothBoundaries?.latest == true
    checks["p3-scroll-boundary-middle-not-terminal"] = scrollBoundaryEvidence(
        value: 0.5, minimum: 0, maximum: 1
    )?.earliest == false
    checks["p3-precondition-drift-zero-body"] = !historyScopeAllowsBody(
        memberMatches: 1, selectedMatches: 1, headerMatches: 1, windowMatches: false
    )
    checks["p3-sync-body-word-not-status"] = historySyncState(statusTexts: [], partial: false) == "unknown"
    checks["p3-sync-explicit-complete-status"] = historySyncState(
        statusTexts: ["Up to date"], partial: false
    ) == "complete"
    checks["p3-sync-explicit-progress-status"] = historySyncState(
        statusTexts: ["同步中"], partial: false
    ) == "syncing"
    checks["p3-complete-algebra-terminal"] = historyComplete(
        nextStateExists: false, syncState: "complete", truncated: false,
        possibleDuplicates: false, hasUnknownDate: false, reasons: []
    )
    checks["p3-complete-algebra-continuation-false"] = !historyComplete(
        nextStateExists: true, syncState: "complete", truncated: false,
        possibleDuplicates: false, hasUnknownDate: false, reasons: []
    )
    let syntheticWindow: [String: Any] = [
        "pid": 1, "windowId": 9, "title": expectedWindowTitle,
        "bounds": ["x": -900, "y": 40, "width": 900, "height": 700],
        "bundleIdentifier": bundleIdentifier,
        "executableURL": "/Applications/LINE.app/Contents/MacOS/LINE",
    ]
    let validHistoryState: [String: Any] = [
        "version": 1, "expectedWindow": syntheticWindow,
        "headerDigest": String(repeating: "c", count: 64),
        "anchorHash": String(repeating: "d", count: 64),
        "offset": 2, "pageNumber": 1, "advance": false,
        "seenIds": [String(repeating: "e", count: 64)],
        "dateContext": ["date": "2024-02-29", "anchorHash": String(repeating: "d", count: 64)],
    ]
    checks["p3-valid-state-accepted"] = (try parseHistoryState(validHistoryState))?.offset == 2
    let oversizedSeenIds = (0..<1_000).map { String(format: "%064x", $0) }
    checks["p3-producer-state-byte-budget"] = boundedHistoryStateJSON(HistoryNativeState(
        expectedWindow: syntheticWindow, headerDigest: String(repeating: "c", count: 64),
        anchorHash: String(repeating: "d", count: 64), offset: 0, pageNumber: 1,
        advance: true, seenIds: oversizedSeenIds, dateContext: nil
    )) == nil
    var invalidHistoryState = validHistoryState
    invalidHistoryState["body"] = "不得進入 state"
    do { _ = try parseHistoryState(invalidHistoryState); checks["p3-invalid-state-rejected"] = false }
    catch let failure as NativeFailure { checks["p3-invalid-state-rejected"] = failure.code == "INVALID_NATIVE_STATE" }
    checks["popup-transition-not-found-retryable"] = retryablePopupTransition("SEARCH_POPUP_NOT_FOUND")
    checks["popup-transition-ambiguous-not-retryable"] = !retryablePopupTransition("SEARCH_POPUP_AMBIGUOUS")
    checks["popup-transition-modal-not-retryable"] = !retryablePopupTransition("MODAL_PRESENT")
    let popupCandidate = OCRCandidate(text: "Paste", confidence: 0.99,
                                      normalizedBox: CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.2))
    let popupA = PopupOCRFrame(identity: identity, imageWidth: 170, imageHeight: 226,
                               candidates: [popupCandidate])
    let popupB = PopupOCRFrame(identity: identity, imageWidth: 170, imageHeight: 226,
                               candidates: [OCRCandidate(text: "Paste", confidence: 0.98,
                                                         normalizedBox: popupCandidate.normalizedBox.offsetBy(dx: 0.005, dy: 0))])
    checks["popup-exact-stable-target"] = (try stablePopupTarget(["貼上", "Paste"], first: popupA, second: popupB)).text == "Paste"
    do {
        _ = try stablePopupTarget(["Paste"],
                                  first: PopupOCRFrame(identity: identity, imageWidth: 170, imageHeight: 226,
                                                       candidates: [popupCandidate, popupCandidate]), second: popupB)
        checks["popup-duplicate-rejected"] = false
    } catch let failure as NativeFailure { checks["popup-duplicate-rejected"] = failure.code == "AMBIGUOUS_MATCH" }
    do {
        _ = try stablePopupTarget(["Paste"], first: popupA,
                                  second: PopupOCRFrame(identity: identity, imageWidth: 170, imageHeight: 226,
                                                        candidates: [OCRCandidate(text: "Paste", confidence: 0.99,
                                                                                  normalizedBox: CGRect(x: 0.8, y: 0.7, width: 0.1, height: 0.1))]))
        checks["popup-bbox-drift-rejected"] = false
    } catch let failure as NativeFailure { checks["popup-bbox-drift-rejected"] = failure.code == "OCR_TARGET_DRIFT" }
    checks["popup-substring-not-exact"] = popupA.candidates.filter {
        $0.confidence >= ocrConfidenceThreshold && ["Paste Extra"].contains($0.text)
    }.isEmpty
    let underline = UnderlineComponent(pointBox: CGRect(x: 175, y: 36, width: 120, height: 2),
                                       pixelCount: 480, meanLuma: 20, fillRatio: 1)
    let underlineFrame = OCRFrame(identity: identity, roi: roi, imageWidth: 900, imageHeight: 700,
                                  candidates: [candidate], maskedCandidates: [], processedCandidates: [],
                                  processedPolicyApplied: false,
                                  greenComponents: [], underlineComponents: [underline])
    checks["underline-target-associated"] = associatedUnderlines(underlineFrame, candidate: candidate).count == 1
    let adjacent = UnderlineComponent(pointBox: CGRect(x: 500, y: 36, width: 100, height: 2),
                                      pixelCount: 400, meanLuma: 20, fillRatio: 1)
    checks["underline-adjacent-tab-rejected"] = associatedUnderlines(
        OCRFrame(identity: identity, roi: roi, imageWidth: 900, imageHeight: 700,
                 candidates: [candidate], maskedCandidates: [], processedCandidates: [],
                 processedPolicyApplied: false, greenComponents: [],
                 underlineComponents: [adjacent]), candidate: candidate).isEmpty
    let gray = UnderlineComponent(pointBox: underline.pointBox, pixelCount: 480, meanLuma: 120, fillRatio: 1)
    checks["underline-gray-separator-rejected"] = !eligibleUnderline(gray, roiHeight: roi.height)
    let icon = UnderlineComponent(pointBox: CGRect(x: 200, y: 36, width: 4, height: 4),
                                  pixelCount: 40, meanLuma: 10, fillRatio: 0.8)
    checks["underline-icon-rejected"] = !eligibleUnderline(icon, roiHeight: roi.height)
    checks["underline-missing-rejected"] = associatedUnderlines(
        OCRFrame(identity: identity, roi: roi, imageWidth: 900, imageHeight: 700,
                 candidates: [candidate], maskedCandidates: [], processedCandidates: [],
                 processedPolicyApplied: false, greenComponents: [],
                 underlineComponents: []), candidate: candidate).isEmpty
    let unreadBadge = GreenComponent(pixelBox: CGRect(x: 0, y: 0, width: 8, height: 8),
                                     pointBox: CGRect(x: 310, y: 1, width: 4, height: 4), pixelCount: 52,
                                     meanRed: 0, meanGreen: 185, meanBlue: 33, meanAlpha: 255)
    let unreadFrame = OCRFrame(identity: identity, roi: roi, imageWidth: 900, imageHeight: 700,
                               candidates: [candidate], maskedCandidates: [candidate], processedCandidates: [],
                               processedPolicyApplied: false,
                               greenComponents: [unreadBadge], underlineComponents: [])
    checks["unread-badge-associated"] = associatedUnreadBadges(unreadFrame, candidate: candidate).count == 1
    let unrelatedBadge = GreenComponent(pixelBox: unreadBadge.pixelBox,
                                        pointBox: CGRect(x: 600, y: 1, width: 4, height: 4), pixelCount: 52,
                                        meanRed: 0, meanGreen: 185, meanBlue: 33, meanAlpha: 255)
    checks["unread-unrelated-badge-rejected"] = associatedUnreadBadges(
        OCRFrame(identity: identity, roi: roi, imageWidth: 900, imageHeight: 700,
                 candidates: [candidate], maskedCandidates: [candidate], processedCandidates: [],
                 processedPolicyApplied: false,
                 greenComponents: [unrelatedBadge], underlineComponents: []), candidate: candidate).isEmpty
    checks["mention-token-rejected"] = containsUnsupportedMention("hello @person")
    checks["plain-at-symbol-allowed"] = !containsUnsupportedMention("mail@example.com")
    let validDialogField = DialogFieldProbe(role: kAXTextFieldRole, subrole: "", enabled: true,
                                            value: "Old", isDialogDescendant: true)
    checks["p2-dialog-rename-original-exact"] = syntheticDialogField([validDialogField], oldValue: "Old") == 0 &&
        syntheticDialogField([validDialogField], oldValue: "Other") == nil
    checks["p2-dialog-wrong-field-rejected"] = syntheticDialogField([
        DialogFieldProbe(role: kAXTextFieldRole, subrole: "", enabled: true,
                         value: "Old", isDialogDescendant: false)
    ], oldValue: "Old") == nil
    checks["p2-dialog-search-rejected"] = syntheticDialogField([
        DialogFieldProbe(role: kAXTextFieldRole, subrole: kAXSearchFieldSubrole, enabled: true,
                         value: "Old", isDialogDescendant: true)
    ], oldValue: "Old") == nil
    checks["p2-dialog-composer-rejected"] = syntheticDialogField([
        DialogFieldProbe(role: kAXTextAreaRole, subrole: "", enabled: true,
                         value: "Old", isDialogDescendant: true)
    ], oldValue: "Old") == nil
    checks["p2-dialog-disabled-rejected"] = syntheticDialogField([
        DialogFieldProbe(role: kAXTextFieldRole, subrole: "", enabled: false,
                         value: "Old", isDialogDescendant: true)
    ], oldValue: "Old") == nil
    let anchor = CGRect(x: 10, y: 20, width: 100, height: 40)
    checks["p2-popup-stale-rejected"] = !popupBindingAllowed(
        parentWindowID: 9, expectedParentWindowID: 9, rowAnchor: anchor, currentRowAnchor: anchor, stale: true
    )
    checks["p2-popup-parent-mismatch-rejected"] = !popupBindingAllowed(
        parentWindowID: 10, expectedParentWindowID: 9, rowAnchor: anchor, currentRowAnchor: anchor, stale: false
    )
    checks["p2-popup-row-mismatch-rejected"] = !popupBindingAllowed(
        parentWindowID: 9, expectedParentWindowID: 9, rowAnchor: anchor,
        currentRowAnchor: anchor.offsetBy(dx: 2, dy: 0), stale: false
    )
    checks["p2-popup-duplicate-label-rejected"] = mutationLabel(
        moveChatLabels, observed: ["移往其他分類", "移往其他分類"]
    ) == nil
    checks["p2-popup-danger-label-not-substitute"] = mutationLabel(
        removeChatLabels, observed: ["刪除聊天室", "退出群組"]
    ) == nil
    let capacity = CapacityEvidence(current: 3, limit: 5, label: "3 / 5")
    let verifiedCapacity = CapacityObservation.verified(capacity)
    let fullCapacity = CapacityObservation.verified(
        CapacityEvidence(current: 5, limit: 5, label: "5 / 5")
    )
    checks["p2-builtin-without-capability-blocked"] = exactUniqueLabel(
        renameTabLabels, in: []
    ) == nil
    checks["p2-create-absent-capacity-blocked"] = p2CapacityDecision(
        action: .createTab, location: .anchor, observation: .absent
    ) == .absent
    checks["p2-create-full-capacity-blocked"] = p2CapacityDecision(
        action: .createTab, location: .anchor, observation: fullCapacity
    ) == .full
    checks["p2-move-destination-absent-blocked"] = p2CapacityDecision(
        action: .moveChat, location: .destination, observation: .absent
    ) == .absent
    checks["p2-move-destination-full-blocked"] = p2CapacityDecision(
        action: .moveChat, location: .destination, observation: fullCapacity
    ) == .full
    checks["p2-move-source-absent-allowed"] = p2CapacityDecision(
        action: .moveChat, location: .source, observation: .absent
    ) == .allowed
    checks["p2-move-source-conflict-blocked"] = p2CapacityDecision(
        action: .moveChat, location: .source, observation: .conflicting
    ) == .conflicting
    checks["p2-rename-absent-capacity-allowed"] = p2CapacityDecision(
        action: .renameTab, location: .source, observation: .absent
    ) == .allowed
    checks["p2-rename-full-capacity-allowed"] = p2CapacityDecision(
        action: .renameTab, location: .source, observation: fullCapacity
    ) == .allowed
    checks["p2-remove-absent-capacity-allowed"] = p2CapacityDecision(
        action: .removeChat, location: .source, observation: .absent
    ) == .allowed
    checks["p2-remove-full-capacity-allowed"] = p2CapacityDecision(
        action: .removeChat, location: .source, observation: fullCapacity
    ) == .allowed
    checks["p2-conflicting-capacity-blocked"] = p2CapacityDecision(
        action: .removeChat, location: .source, observation: .conflicting
    ) == .conflicting
    checks["p2-capacity-ui-label-parsed"] = capacityJSON(capacityEvidence(
        ["分類 3 / 5"], expectedCurrent: 3, kind: .categories
    ))["current"] as? Int == 3
    checks["p2-capacity-mismatch-conflicting"] = capacityJSON(capacityEvidence(
        ["分類 2 / 5"], expectedCurrent: 3, kind: .categories
    ))["state"] as? String == "conflicting"
    checks["p2-capacity-multiple-conflicting"] = capacityJSON(capacityEvidence(
        ["分類 3 / 5", "分類 3 / 6"], expectedCurrent: 3, kind: .categories
    ))["state"] as? String == "conflicting"
    checks["p2-regular-chat-label-capacity-absent"] = capacityJSON(capacityEvidence(
        ["新增聊天室"], expectedCurrent: 3, kind: .chats
    ))["state"] as? String == "absent"
    checks["p2-exact-observed-rename-label-allowed"] = exactUniqueLabel(
        renameTabLabels, in: ["變更分類名稱"]
    ) == "變更分類名稱"
    checks["p2-rename-label-substring-rejected"] = exactUniqueLabel(
        renameTabLabels, in: ["變更分類名稱（測試）"]
    ) == nil
    checks["p2-rename-label-duplicate-rejected"] = exactUniqueLabel(
        renameTabLabels, in: ["變更分類名稱", "變更分類名稱"]
    ) == nil
    let fingerprintInventory = TabInventory(names: ["Old"], identity: identity,
                                            selectedTab: "Old", complete: true,
                                            reasons: [], pagesScanned: 1, firstFrame: first)
    let fingerprintChange = try parseTabChanges([
        ["action": "rename_tab", "tabName": "Old", "newName": "New"]
    ])[0]
    let fingerprintBase = p2Fingerprint(
        change: fingerprintChange, inventory: fingerprintInventory,
        invariants: ["mutabilityLabel": "變更分類名稱", "capacity": capacityJSON(.absent)]
    )
    let fingerprintLabelChanged = p2Fingerprint(
        change: fingerprintChange, inventory: fingerprintInventory,
        invariants: ["mutabilityLabel": "重新命名分類", "capacity": capacityJSON(.absent)]
    )
    let fingerprintCapacityChanged = p2Fingerprint(
        change: fingerprintChange, inventory: fingerprintInventory,
        invariants: ["mutabilityLabel": "變更分類名稱", "capacity": capacityJSON(verifiedCapacity)]
    )
    let fingerprintPrefixChanged = p2Fingerprint(
        change: fingerprintChange, inventory: fingerprintInventory,
        invariants: ["mutabilityLabel": "變更分類名稱", "capacity": capacityJSON(.absent),
                     "predictedPrefixCount": 1]
    )
    checks["p2-fingerprint-binds-label-capacity"] = fingerprintBase != fingerprintLabelChanged &&
        fingerprintBase != fingerprintCapacityChanged && fingerprintBase != fingerprintPrefixChanged
    checks["p2-readback-move-verified"] = membershipReadbackVerified(
        sourceBefore: ["A", "Room"], sourceAfter: ["A"], destinationBefore: ["B"],
        destinationAfter: ["B", "Room"], chat: "Room"
    )
    checks["p2-readback-source-present-rejected"] = !membershipReadbackVerified(
        sourceBefore: ["Room"], sourceAfter: ["Room"], destinationBefore: [],
        destinationAfter: ["Room"], chat: "Room"
    )
    checks["p2-readback-destination-missing-rejected"] = !membershipReadbackVerified(
        sourceBefore: ["Room"], sourceAfter: [], destinationBefore: [], destinationAfter: [], chat: "Room"
    )
    let nestedP2Pre = NativeFailure("READBACK_UNVERIFIED", "fixture", ["phase": "pre_commit"])
    checks["p2-postphase-forced-after-confirm"] = forcingPhase(
        nestedP2Pre, phaseAfterMutationAttempt(true, nestedPhase: "pre_commit")!
    ).details["phase"] as? String == "post_commit"
    checks["p2-c0-name-rejected"] = validName("bad\nname") == nil
    checks["p2-bidi-name-rejected"] = validName("bad\u{202E}name") == nil
    checks["p2-long-name-rejected"] = validName(String(repeating: "x", count: 201)) == nil
    checks["p2-remove-does-not-accept-delete"] = exactUniqueLabel(removeChatLabels, in: ["Delete chat"]) == nil
    let allowedActionCounts = try [
        [["action": "create_tab", "name": "New"]],
        [["action": "rename_tab", "tabName": "Old", "newName": "New"]],
        [["action": "move_chat", "sourceTab": "A", "destinationTab": "B", "chatName": "Room"]],
        [["action": "remove_chat", "sourceTab": "A", "chatName": "Room"]],
    ].map { try parseTabChanges($0).count }
    checks["p2-action-whitelist-four"] = allowedActionCounts == [1, 1, 1, 1]
    checks["p2-unknown-field-rejected"] = tabChangesRejected([
        ["action": "create_tab", "name": "New", "extra": true]
    ])
    checks["p2-mixed-batch-rejected"] = tabChangesRejected([
        ["action": "move_chat", "sourceTab": "A", "destinationTab": "B", "chatName": "One"],
        ["action": "remove_chat", "sourceTab": "A", "chatName": "Two"],
    ])
    checks["p2-duplicate-chat-rejected"] = tabChangesRejected([
        ["action": "move_chat", "sourceTab": "A", "destinationTab": "B", "chatName": "Room"],
        ["action": "move_chat", "sourceTab": "A", "destinationTab": "C", "chatName": "Room"],
    ])
    checks["p2-source-destination-same-rejected"] = tabChangesRejected([
        ["action": "move_chat", "sourceTab": "A", "destinationTab": "A", "chatName": "Room"],
    ])
    checks["p2-rename-same-rejected"] = tabChangesRejected([
        ["action": "rename_tab", "tabName": "Same", "newName": "Same"],
    ])
    let globalWindow = CGRect(x: 0, y: 0, width: 500, height: 500)
    let globalList = CGRect(x: 0, y: 50, width: 250, height: 150)
    let globalRows = ["甲", "測試對話", "乙"].enumerated().map {
        GlobalSearchRowProof(token: $0.offset + 10, name: $0.element,
                             index: $0.offset,
                             frame: CGRect(x: 0, y: 50 + CGFloat($0.offset) * 50,
                                           width: 250, height: 50),
                             selected: false, enabled: true, supportsPress: true)
    }
    checks["global-model-complete"] = globalSearchModelValid(
        globalRows, listFrame: globalList, windowFrame: globalWindow
    ) && globalPressTarget(previous: globalRows, final: globalRows, chatName: "測試對話",
                           listFrame: globalList, windowFrame: globalWindow) == 11
    var globalReordered = globalRows
    globalReordered.swapAt(0, 1)
    checks["global-model-reorder-zero-action"] = globalPressTarget(
        previous: globalRows, final: globalReordered, chatName: "測試對話",
        listFrame: globalList, windowFrame: globalWindow
    ) == nil
    var globalMissingName = globalRows
    globalMissingName[1] = GlobalSearchRowProof(
        token: 11, name: nil, index: 1, frame: globalRows[1].frame,
        selected: false, enabled: true, supportsPress: true
    )
    checks["global-model-missing-name-zero-action"] = globalPressTarget(
        previous: globalRows, final: globalMissingName, chatName: "測試對話",
        listFrame: globalList, windowFrame: globalWindow
    ) == nil
    var globalDuplicate = globalRows
    globalDuplicate[2] = GlobalSearchRowProof(
        token: 12, name: "測試對話", index: 2, frame: globalRows[2].frame,
        selected: false, enabled: true, supportsPress: true
    )
    checks["global-model-duplicate-zero-action"] = globalPressTarget(
        previous: globalDuplicate, final: globalDuplicate, chatName: "測試對話",
        listFrame: globalList, windowFrame: globalWindow
    ) == nil
    var globalStale = globalRows
    globalStale[1] = GlobalSearchRowProof(
        token: 99, name: "測試對話", index: 1, frame: globalRows[1].frame,
        selected: false, enabled: true, supportsPress: true
    )
    checks["global-model-stale-handle-zero-action"] = globalPressTarget(
        previous: globalRows, final: globalStale, chatName: "測試對話",
        listFrame: globalList, windowFrame: globalWindow
    ) == nil
    checks["global-semantic-title-only"] =
        globalSemanticName(rowTitle: "測試對話", relatedTitle: nil) == "測試對話" &&
        globalSemanticName(rowTitle: nil, relatedTitle: "測試對話") == "測試對話" &&
        globalSemanticName(rowTitle: "測試對話", relatedTitle: "測試對話") == "測試對話"
    checks["global-semantic-conflict-rejected"] =
        globalSemanticName(rowTitle: "測試對話", relatedTitle: "其他") == nil &&
        globalSemanticName(rowTitle: nil, relatedTitle: nil) == nil
    checks["global-query-exact"] = globalQueryMatches(observed: "測試對話", expected: "測試對話") &&
        !globalQueryMatches(observed: "測試對話 ", expected: "測試對話")
    checks["indexed-query-mutation-route"] =
        indexedSearchMutationRoute(alreadyExact: true, settableStatus: .cannotComplete,
                                   settable: false) == .alreadyExact &&
        indexedSearchMutationRoute(alreadyExact: false, settableStatus: .success,
                                   settable: true) == .axValue &&
        indexedSearchMutationRoute(alreadyExact: false, settableStatus: .success,
                                   settable: false) == .clipboard &&
        indexedSearchMutationRoute(alreadyExact: false, settableStatus: .cannotComplete,
                                   settable: false) == nil
    checks["indexed-query-passive-commit"] =
        indexedPassiveCommitAllowed(queryExact: true, popupAbsent: true) &&
        !indexedPassiveCommitAllowed(queryExact: false, popupAbsent: true) &&
        !indexedPassiveCommitAllowed(queryExact: true, popupAbsent: false)
    var settleGuardCount = 0, settleProbeCount = 0, settlePauseCount = 0
    let settledValue: String = try indexedSearchSettleCore(clock: { 0 }, guardFresh: {
        settleGuardCount += 1
    }, probe: {
        settleProbeCount += 1
        if settleProbeCount == 1 {
            throw NativeFailure("INDEXED_NAME_PROFILE_UNVERIFIED", "synthetic transient")
        }
        return "ready"
    }, pause: { settlePauseCount += 1 })
    checks["indexed-search-settle-transient-positive"] = settledValue == "ready" &&
        settleGuardCount == 2 && settleProbeCount == 2 && settlePauseCount == 1
    var nonTransientProbeCount = 0, nonTransientStopped = false
    do {
        let _: String = try indexedSearchSettleCore(clock: { 0 }, guardFresh: {}, probe: {
            nonTransientProbeCount += 1
            throw NativeFailure("SEARCH_QUERY_CHANGED", "synthetic non-transient")
        }, pause: {})
    } catch let failure as NativeFailure {
        nonTransientStopped = failure.code == "SEARCH_QUERY_CHANGED"
    }
    checks["indexed-search-settle-nontransient-stops"] =
        nonTransientStopped && nonTransientProbeCount == 1
    var settleTime: TimeInterval = 0, boundedProbes = 0
    var boundedFailure: NativeFailure?
    do {
        let _: String = try indexedSearchSettleCore(clock: { settleTime }, guardFresh: {}, probe: {
            boundedProbes += 1
            throw NativeFailure("INDEXED_SECTION_UNVERIFIED", "synthetic bounded transient")
        }, pause: { settleTime += 4.1 })
    } catch let failure as NativeFailure { boundedFailure = failure }
    checks["indexed-search-settle-bounded"] = boundedProbes == 2 &&
        boundedFailure?.code == "INDEXED_SECTION_UNVERIFIED"
    var stuckProbes = 0, stuckPauses = 0, stuckFailure: NativeFailure?
    do {
        let _: String = try indexedSearchSettleCore(clock: { 0 }, guardFresh: {}, probe: {
            stuckProbes += 1
            throw NativeFailure("INDEXED_NAME_BAND_UNVERIFIED", "synthetic stuck clock")
        }, pause: { stuckPauses += 1 })
    } catch let failure as NativeFailure { stuckFailure = failure }
    checks["indexed-search-settle-clock-stuck"] = stuckProbes == 160 &&
        stuckPauses == 160 && stuckFailure?.code == "INDEXED_NAME_BAND_UNVERIFIED"
    var lateTime: TimeInterval = 0, lateProbes = 0, lateFailure: NativeFailure?
    do {
        let _: String = try indexedSearchSettleCore(clock: { lateTime }, guardFresh: {}, probe: {
            lateProbes += 1
            if lateProbes == 1 {
                throw NativeFailure("INDEXED_NAME_PROFILE_UNVERIFIED", "synthetic prior transient")
            }
            lateTime = 8.1
            return "late"
        }, pause: { lateTime = 7.9 })
    } catch let failure as NativeFailure { lateFailure = failure }
    var firstLateTime: TimeInterval = 0, firstLateFailure: NativeFailure?
    do {
        let _: String = try indexedSearchSettleCore(clock: { firstLateTime }, guardFresh: {}, probe: {
            firstLateTime = 8.1; return "late"
        }, pause: {})
    } catch let failure as NativeFailure { firstLateFailure = failure }
    checks["indexed-search-settle-late-positive-rejected"] = lateProbes == 2 &&
        lateFailure?.code == "INDEXED_NAME_PROFILE_UNVERIFIED" &&
        firstLateFailure?.code == "SEARCH_RESULTS_NOT_READY"
    let postAXFailure = indexedSelectionOutcomeUnknown(
        NativeFailure("INDEXED_SEARCH_RESULT_UNAVAILABLE", "synthetic post AX model drift"),
        counts: GlobalAllEventCounts(), axPressAttempts: 1
    )
    checks["indexed-no-retry-ax-post-input"] =
        indexedAXFailureAllowsOCRFallback(code: "INDEXED_SEARCH_RESULT_UNAVAILABLE",
                                          phase: nil) &&
        !indexedAXFailureAllowsOCRFallback(code: "INDEXED_SEARCH_RESULT_UNAVAILABLE",
                                           phase: postAXFailure.details["phase"] as? String) &&
        postAXFailure.code == "INDEXED_SELECTION_OUTCOME_UNKNOWN" &&
        postAXFailure.details["axPressAttempts"] as? Int == 1
    var attemptedHIDCounts = GlobalAllEventCounts()
    GlobalAllMouseStep.allCases.forEach { attemptedHIDCounts.record($0) }
    let postHIDFailure = indexedSelectionOutcomeUnknown(
        NativeFailure("CHAT_SELECTION_UNVERIFIED", "synthetic post HID header drift"),
        counts: attemptedHIDCounts
    )
    checks["indexed-no-retry-hid-post-input"] =
        postHIDFailure.code == "INDEXED_SELECTION_OUTCOME_UNKNOWN" &&
        postHIDFailure.details["inputAttempted"] as? Bool == true &&
        (postHIDFailure.details["eventCounts"] as? [String: Int]) ==
            ["move": 1, "down": 1, "up": 1]
    checks["global-header-exact-unique"] = globalHeaderNamesVerify(["測試對話"], target: "測試對話") &&
        !globalHeaderNamesVerify([], target: "測試對話") &&
        !globalHeaderNamesVerify(["測試對話", "測試對話"], target: "測試對話")
    let globalHistoryID = historyObservedID(
        key: historyKey, tabName: "", chatName: "測試對話", axIdentifier: "AX-ID-1", mode: .global
    )
    checks["global-history-domain-bound"] = globalHistoryID != stableHistoryID
    let globalRawArgs: [String: Any] = [
        "chatName": "測試對話", "limit": 5, "identityKey": String(repeating: "5a", count: 32),
    ]
    let globalFixtureArgs = try parseHistoryArguments(globalRawArgs, mode: .global)
    checks["global-args-no-tab"] = globalFixtureArgs.mode == .global &&
        globalFixtureArgs.tabName.isEmpty && globalFixtureArgs.chatName == "測試對話"
    let indexedRawArgs = globalRawArgs.merging(["resultIndex": 2]) { _, new in new }
    let indexedFixtureArgs = try parseHistoryArguments(indexedRawArgs, mode: .global)
    checks["global-indexed-args-scope"] = indexedFixtureArgs.resultIndex == 2 &&
        historyResultScope(indexedFixtureArgs) as NSDictionary == [
            "kind": "search_result", "chatName": "測試對話", "resultIndex": 2, "verified": true,
        ] as NSDictionary && historyScopeBinding(indexedFixtureArgs)["resultIndex"] as? Int == 2
    do {
        _ = try parseHistoryArguments(indexedRawArgs.merging([
            "nativeState": validHistoryState,
        ]) { _, new in new }, mode: .global)
        checks["global-indexed-cursor-rejected"] = false
    } catch let failure as NativeFailure {
        checks["global-indexed-cursor-rejected"] = failure.code == "INVALID_ARGUMENT"
    }
    do {
        _ = try parseHistoryArguments(globalRawArgs.merging(["tabName": "全部"]) { _, new in new },
                                      mode: .global)
        checks["global-args-tab-rejected"] = false
    } catch let failure as NativeFailure {
        checks["global-args-tab-rejected"] = failure.code == "INVALID_ARGUMENT"
    }
    func viewportProjection(height: Int, separatorRows: [Int], bodyStart: Int = 0,
                            rightDriftRows: Range<Int>? = nil)
        -> (pixels: [UInt8], width: Int, bytesPerRow: Int)? {
        let gutterWidth = 2, gutterBytesPerRow = gutterWidth * 4
        var left = [UInt8](repeating: 52, count: gutterBytesPerRow * height)
        var right = left
        for index in stride(from: 3, to: left.count, by: 4) {
            left[index] = 255; right[index] = 255
        }
        for row in 0..<min(bodyStart, height) { for x in 0..<gutterWidth {
            let offset = row * gutterBytesPerRow + x * 4
            for channel in 0..<3 { left[offset + channel] = 96; right[offset + channel] = 96 }
        } }
        for row in separatorRows { for x in 0..<gutterWidth {
            for gutter in 0..<2 {
                let offset = row * gutterBytesPerRow + x * 4
                if gutter == 0 {
                    left[offset] = 64; left[offset + 1] = 64; left[offset + 2] = 64
                } else {
                    right[offset] = 64; right[offset + 1] = 64; right[offset + 2] = 64
                }
            }
        } }
        if let rightDriftRows { for row in rightDriftRows { for x in 0..<gutterWidth {
            let offset = row * gutterBytesPerRow + x * 4
            right[offset] = 80; right[offset + 1] = 80; right[offset + 2] = 80
        } } }
        return indexedGutterProjection(left: left, leftWidth: gutterWidth,
                                       leftBytesPerRow: gutterBytesPerRow,
                                       right: right, rightWidth: gutterWidth,
                                       rightBytesPerRow: gutterBytesPerRow,
                                       height: height)
    }
    let scale1Projection = viewportProjection(height: 500, separatorRows: [424], bodyStart: 64)
    checks["indexed-viewport-boundary"] = scale1Projection.flatMap {
        indexedViewportBounds(pixels: $0.pixels, width: $0.width, height: 500,
                              bytesPerRow: $0.bytesPerRow, scanStart: 0)
    }.map { $0.top == 64 && $0.bottom == 424 && $0.separatorHeight == 1 } == true && {
        guard let projection = viewportProjection(height: 400, separatorRows: [280, 281],
                                                  bodyStart: 128) else {
            return false
        }
        return indexedViewportBounds(pixels: projection.pixels, width: projection.width,
                                     height: 400, bytesPerRow: projection.bytesPerRow,
                                     scanStart: 0, scale: 2)
            .map { $0.top == 128 && $0.bottom == 280 && $0.separatorHeight == 2 } == true
    }()
    checks["indexed-viewport-global-body-roi"] = indexedBodyGlobalROI(
        scanOriginY: 289, topPixels: 64, bottomPixels: 424,
        scale: 1, minX: 0, maxX: 605
    ) == CGRect(x: 2, y: 355, width: 601, height: 356)
    let multipleProjection = viewportProjection(height: 100, separatorRows: [60, 70])
    checks["indexed-viewport-multiple-divider-rejected"] = multipleProjection.flatMap {
        indexedViewportBounds(pixels: $0.pixels, width: $0.width, height: 100,
                              bytesPerRow: $0.bytesPerRow, scanStart: 0)
    } == nil
    checks["indexed-viewport-background-drift-rejected"] = {
        guard let projection = viewportProjection(height: 100, separatorRows: [70],
                                                  rightDriftRows: 71..<79) else { return false }
        return indexedViewportBounds(pixels: projection.pixels, width: projection.width,
                                     height: 100, bytesPerRow: projection.bytesPerRow,
                                     scanStart: 0) == nil
    }()
    var momRows = [Bool](repeating: false, count: 40)
    for row in 18...32 { momRows[row] = true }
    var groupRows = [Bool](repeating: false, count: 40)
    for row in 8...22 { groupRows[row] = true }; groupRows[31] = true
    var hidpiMomRows = [Bool](repeating: false, count: 80)
    for row in 36...64 { hidpiMomRows[row] = true }
    checks["indexed-first-line-adaptive"] =
        indexedFirstLineHeight(momRows, scale: 1) == 35 &&
        indexedFirstLineHeight(groupRows, scale: 1) == 25 &&
        indexedFirstLineHeight(hidpiMomRows, scale: 2) == 34.5
    var mergedPreviewRows = [Bool](repeating: false, count: 50)
    for row in 8...35 { mergedPreviewRows[row] = true }
    checks["indexed-first-line-preview-rejected"] =
        indexedFirstLineHeight(mergedPreviewRows, scale: 1) == nil
    let indexedListFrame = CGRect(x: 0, y: 100, width: 302, height: 500)
    let indexedChatFrames = (0..<7).map {
        CGRect(x: 0, y: 134 + CGFloat($0) * 71, width: 302, height: 71)
    }
    checks["indexed-ax-chat-domain"] = indexedChatRunCount(
        listFrame: indexedListFrame, rowFrames: indexedChatFrames + [
            CGRect(x: 0, y: 700, width: 302, height: 34),
            CGRect(x: 0, y: 734, width: 302, height: 71),
        ]) == 7 && indexedChatRunCount(
            listFrame: indexedListFrame,
            rowFrames: [CGRect(x: 0, y: 100, width: 302, height: 34)] + indexedChatFrames
        ) == 0
    checks["indexed-ui-version-pinned"] = indexedUIVersionAllowed(
        version: "26.4.2", build: "3955"
    ) && !indexedUIVersionAllowed(version: "26.4.3", build: "3955") &&
        !indexedUIVersionAllowed(version: "26.4.2", build: "3956")
    let cursorExpectedPath =
        "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer"
    checks["indexed-windowserver-trust-fields"] = trustedCursorSurfaceFields(
        layer: 99, cursorLayer: 99, firstPath: cursorExpectedPath,
        secondPath: cursorExpectedPath, expectedPath: cursorExpectedPath,
        codeValid: true, signingIdentifier: expectedWindowServerSigningIdentifier
    ) && !trustedCursorSurfaceFields(
        layer: 98, cursorLayer: 99, firstPath: cursorExpectedPath,
        secondPath: cursorExpectedPath, expectedPath: cursorExpectedPath,
        codeValid: true, signingIdentifier: expectedWindowServerSigningIdentifier
    ) && !trustedCursorSurfaceFields(
        layer: 99, cursorLayer: 99, firstPath: "/tmp/WindowServer",
        secondPath: "/tmp/WindowServer", expectedPath: cursorExpectedPath,
        codeValid: true, signingIdentifier: expectedWindowServerSigningIdentifier
    ) && !trustedCursorSurfaceFields(
        layer: 99, cursorLayer: 99, firstPath: cursorExpectedPath,
        secondPath: cursorExpectedPath + ".drift", expectedPath: cursorExpectedPath,
        codeValid: true, signingIdentifier: expectedWindowServerSigningIdentifier
    ) && !trustedCursorSurfaceFields(
        layer: 99, cursorLayer: 99, firstPath: cursorExpectedPath,
        secondPath: cursorExpectedPath, expectedPath: cursorExpectedPath,
        codeValid: false, signingIdentifier: expectedWindowServerSigningIdentifier
    ) && !trustedCursorSurfaceFields(
        layer: 99, cursorLayer: 99, firstPath: cursorExpectedPath,
        secondPath: cursorExpectedPath, expectedPath: cursorExpectedPath,
        codeValid: true, signingIdentifier: "com.example.WindowServer"
    )
    let processPathBytes = cursorExpectedPath.utf8.map { CChar(bitPattern: $0) } + [0, 0]
    var missingTerminator = processPathBytes
    missingTerminator[cursorExpectedPath.utf8.count] = 65
    var embeddedNUL = processPathBytes
    embeddedNUL[2] = 0
    checks["indexed-windowserver-path-bytes"] = validatedProcessPathBytes(
        processPathBytes, count: cursorExpectedPath.utf8.count
    ) == cursorExpectedPath && validatedProcessPathBytes(
        missingTerminator, count: cursorExpectedPath.utf8.count
    ) == nil && validatedProcessPathBytes(
        embeddedNUL, count: cursorExpectedPath.utf8.count
    ) == nil && validatedProcessPathBytes(
        processPathBytes, count: processPathBytes.count
    ) == nil && validatedProcessPathBytes(
        [CChar(bitPattern: 0xff), 0], count: 1
    ) == nil
    let scenePoint = CGPoint(x: 50, y: 50)
    let sceneTarget = CGRect(x: 40, y: 40, width: 20, height: 20)
    let sceneMain = IndexedSceneWindow(pid: 4321, id: 9876,
                                       frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                                       layer: 0, trustedCursor: false)
    let sceneCursor = IndexedSceneWindow(pid: 177, id: 3,
                                         frame: CGRect(x: 45, y: 45, width: 10, height: 10),
                                         layer: 99, trustedCursor: true)
    checks["indexed-scene-cursor-exact-trust"] = indexedSceneAllowsTarget(
        windows: [sceneCursor, sceneMain], point: scenePoint, targetROI: sceneTarget,
        expectedPID: 4321, expectedWindowID: 9876, cursorLayer: 99,
        axOwnerVerified: true
    ) && indexedSceneAllowsTarget(
        windows: [sceneMain], point: scenePoint, targetROI: sceneTarget,
        expectedPID: 4321, expectedWindowID: 9876, cursorLayer: 99,
        axOwnerVerified: true
    )
    let wrongLayerCursor = IndexedSceneWindow(pid: 177, id: 3, frame: sceneCursor.frame,
                                              layer: 98, trustedCursor: true)
    let untrustedCursor = IndexedSceneWindow(pid: 177, id: 3, frame: sceneCursor.frame,
                                             layer: 99, trustedCursor: false)
    let otherOverlay = IndexedSceneWindow(pid: 999, id: 4, frame: sceneCursor.frame,
                                          layer: 10, trustedCursor: false)
    let lineAux = IndexedSceneWindow(pid: 4321, id: 9877,
                                     frame: CGRect(x: 39, y: 39, width: 4, height: 4),
                                     layer: 1, trustedCursor: false)
    checks["indexed-scene-overlay-ax-rejected"] = !indexedSceneAllowsTarget(
        windows: [wrongLayerCursor, sceneMain], point: scenePoint, targetROI: sceneTarget,
        expectedPID: 4321, expectedWindowID: 9876, cursorLayer: 99,
        axOwnerVerified: true
    ) && !indexedSceneAllowsTarget(
        windows: [untrustedCursor, sceneMain], point: scenePoint, targetROI: sceneTarget,
        expectedPID: 4321, expectedWindowID: 9876, cursorLayer: 99,
        axOwnerVerified: true
    ) && !indexedSceneAllowsTarget(
        windows: [otherOverlay, sceneMain], point: scenePoint, targetROI: sceneTarget,
        expectedPID: 4321, expectedWindowID: 9876, cursorLayer: 99,
        axOwnerVerified: true
    ) && !indexedSceneAllowsTarget(
        windows: [sceneCursor, sceneMain], point: scenePoint, targetROI: sceneTarget,
        expectedPID: 4321, expectedWindowID: 9876, cursorLayer: 99,
        axOwnerVerified: false
    ) && !indexedSceneAllowsTarget(
        windows: [sceneMain, lineAux], point: scenePoint, targetROI: sceneTarget,
        expectedPID: 4321, expectedWindowID: 9876, cursorLayer: 99,
        axOwnerVerified: true
    )
    let indexedName = OCRCandidate(text: "測試對話", confidence: 0.95,
                                   normalizedBox: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.5))
    let sectionLabel = OCRCandidate(text: "聊天", confidence: 1,
                                    normalizedBox: CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.5))
    let sectionCount1 = OCRCandidate(text: "1", confidence: 1,
                                     normalizedBox: CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.5))
    let sectionCount12 = OCRCandidate(text: "12", confidence: 1,
                                      normalizedBox: sectionCount1.normalizedBox)
    checks["indexed-chat-section-label-count"] =
        indexedChatSectionCount(labelCandidates: [sectionLabel],
                                countCandidates: [sectionCount1]) == 1 &&
        indexedChatSectionCount(labelCandidates: [sectionLabel],
                                countCandidates: [sectionCount12]) == 12
    checks["indexed-chat-section-count-bounds"] =
        indexedChatSectionResultAllowed(count: 1, resultIndex: 1) &&
        !indexedChatSectionResultAllowed(count: 1, resultIndex: 2) &&
        !indexedChatSectionResultAllowed(count: 12, resultIndex: 0) &&
        !indexedChatSectionResultAllowed(count: 12, resultIndex: 21) &&
        indexedChatSectionCount(labelCandidates: [sectionLabel], countCandidates: [
            OCRCandidate(text: "0", confidence: 1, normalizedBox: sectionCount1.normalizedBox),
        ]) == nil && indexedChatSectionCount(labelCandidates: [sectionLabel], countCandidates: [
            OCRCandidate(text: "100000", confidence: 1, normalizedBox: sectionCount1.normalizedBox),
        ]) == nil && indexedChatSectionCount(labelCandidates: [sectionLabel],
                                              countCandidates: [sectionCount1, sectionCount12]) == nil
    var sectionSourcePixels = [UInt8](repeating: 202, count: 302 * 34 * 4)
    for index in stride(from: 3, to: sectionSourcePixels.count, by: 4) {
        sectionSourcePixels[index] = 255
    }
    var sectionDomainPixels = [UInt8](repeating: 255, count: 100 * 30 * 4)
    for index in stride(from: 3, to: sectionDomainPixels.count, by: 4) {
        sectionDomainPixels[index] = 255
    }
    for y in 8..<20 { for x in 20..<40 {
        let offset = (y * 100 + x) * 4
        sectionDomainPixels[offset] = 28; sectionDomainPixels[offset + 1] = 28
        sectionDomainPixels[offset + 2] = 28
    } }
    for y in 8..<20 { for x in 48..<54 {
        let offset = (y * 100 + x) * 4
        sectionDomainPixels[offset] = 28; sectionDomainPixels[offset + 1] = 28
        sectionDomainPixels[offset + 2] = 28
    } }
    let sectionSource = rgbaImage(topDown: sectionSourcePixels, width: 302, height: 34)
    let sectionDomains = try rgbaImage(topDown: sectionDomainPixels, width: 100, height: 30)
        .flatMap { try indexedChatSectionDomainCrops($0, scale: 1) }
    checks["indexed-chat-section-domain-crops"] =
        sectionSource.flatMap {
            indexedChatSectionInsetCrop($0, scaleX: 1, scaleY: 1)
        }.map { $0.width == 286 && $0.height == 26 } == true &&
        sectionDomains.map {
            $0.label.width > 0 && $0.count.width > 0 &&
                $0.label.height == 30 && $0.count.height == 30
        } == true
    func headerAuxiliaryFixture(splitOpen: Bool = false, prefix: Bool = false,
                                colored: Bool = false, edge: Bool = false) -> Bool {
        let width = 100, height = 40, bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 202, count: bytesPerRow * height)
        var luma = [UInt8](repeating: 202, count: width * height)
        var mask = [Bool](repeating: false, count: width * height)
        for index in stride(from: 3, to: pixels.count, by: 4) { pixels[index] = 255 }
        func paint(_ xs: Range<Int>, _ ys: Range<Int>, auxiliary: Bool) {
            for y in ys { for x in xs {
                let index = y * width + x, offset = index * 4
                let color: [UInt8] = auxiliary ? (colored ? [100, 64, 64] : [64, 64, 64]) : [28, 28, 28]
                pixels[offset] = color[0]; pixels[offset + 1] = color[1]; pixels[offset + 2] = color[2]
                luma[index] = auxiliary ? 64 : 28
                if auxiliary { mask[index] = true }
            } }
        }
        paint(10..<36, 14..<26, auxiliary: false)
        paint((prefix ? 2 : 50)..<(prefix ? 6 : 54), 14..<20, auxiliary: true)
        paint((prefix ? 8 : 56)..<(prefix ? 12 : 60), 17..<23, auxiliary: true)
        if splitOpen {
            paint(72..<74, 14..<21, auxiliary: true); paint(77..<79, 14..<21, auxiliary: true)
        } else {
            paint(72..<79, 14..<16, auxiliary: true); paint(72..<74, 16..<22, auxiliary: true)
            paint(77..<79, 16..<22, auxiliary: true); paint(72..<79, 22..<24, auxiliary: true)
        }
        if edge { paint(94..<100, 28..<34, auxiliary: true) }
        return indexedHeaderAuxiliaryDomainsValid(
            mask: mask, luma: luma, originalPixels: pixels, bytesPerRow: bytesPerRow,
            width: width, height: height, nameActual: CGRect(x: 10, y: 14, width: 26, height: 12),
            nameDarkest: 28, background: 202, scaleX: 1, scaleY: 1
        )
    }
    var headerBackgroundPixels = [UInt8](repeating: 202, count: 100 * 40 * 4)
    for index in stride(from: 3, to: headerBackgroundPixels.count, by: 4) {
        headerBackgroundPixels[index] = 255
    }
    var sectionInkPixels = headerBackgroundPixels
    for y in 10..<22 { for x in 30..<60 {
        let offset = (y * 100 + x) * 4
        sectionInkPixels[offset] = 28; sectionInkPixels[offset + 1] = 28
        sectionInkPixels[offset + 2] = 28
    } }
    let sectionInkCrop = try rgbaImage(topDown: sectionInkPixels, width: 100, height: 40)
        .flatMap { try indexedWholeInkCrop($0) }
    checks["indexed-header-topdown-background"] =
        indexedTopDownCropRect(CGRect(x: 8, y: 13, width: 34, height: 20),
                               width: 100, height: 40) ==
            CGRect(x: 8, y: 13, width: 34, height: 20) &&
        rgbaImage(topDown: headerBackgroundPixels, width: 100, height: 40)
            .flatMap { try? indexedHeaderBackground($0) } == 202 &&
        sectionInkCrop.map { $0.width == 38 && $0.height == 20 } == true
    checks["indexed-header-aux-domains"] =
        headerAuxiliaryFixture() && headerAuxiliaryFixture(splitOpen: true)
    checks["indexed-header-aux-prefix-color-edge-rejected"] =
        !headerAuxiliaryFixture(prefix: true) && !headerAuxiliaryFixture(colored: true) &&
        !headerAuxiliaryFixture(edge: true)
    checks["indexed-name-threshold"] = indexedExactNameCandidate(
        [indexedName], expected: "測試對話", imageWidth: 100, imageHeight: 100
    ) != nil && indexedExactNameCandidate([
        indexedName, OCRCandidate(text: "12:34", confidence: 0.99,
                                  normalizedBox: CGRect(x: 0.6, y: 0.2, width: 0.2, height: 0.5))
    ], expected: "測試對話", imageWidth: 100, imageHeight: 100) != nil && indexedExactNameCandidate([
        OCRCandidate(text: "測試對話", confidence: 0.949,
                     normalizedBox: indexedName.normalizedBox)
    ], expected: "測試對話", imageWidth: 100, imageHeight: 100) == nil
    checks["indexed-name-prefix-suffix-rejected"] = indexedExactNameCandidate([
        OCRCandidate(text: "前測試對話", confidence: 1, normalizedBox: indexedName.normalizedBox)
    ], expected: "測試對話", imageWidth: 100, imageHeight: 100) == nil && indexedExactNameCandidate([
        OCRCandidate(text: "測試對話後", confidence: 1, normalizedBox: indexedName.normalizedBox)
    ], expected: "測試對話", imageWidth: 100, imageHeight: 100) == nil && indexedExactNameCandidate([
        indexedName, OCRCandidate(text: "灰suffix", confidence: 0.2,
                                  normalizedBox: indexedName.normalizedBox.offsetBy(dx: 0.4, dy: 0))
    ], expected: "測試對話", imageWidth: 100, imageHeight: 100) == nil
    checks["indexed-name-ellipsis-invalid-rejected"] = indexedExactNameCandidate([
        OCRCandidate(text: "測試對話…", confidence: 1, normalizedBox: indexedName.normalizedBox)
    ], expected: "測試對話", imageWidth: 100, imageHeight: 100) == nil && indexedExactNameCandidate([
        OCRCandidate(text: "測試對話", confidence: 1,
                     normalizedBox: CGRect(x: .nan, y: 0.2, width: 0.3, height: 0.5))
    ], expected: "測試對話", imageWidth: 100, imageHeight: 100) == nil
    checks["indexed-name-numeric-noise-bounded"] =
        canonicalReadOCRCandidate(OCRCandidate(
            text: "測試對話", confidence: 1,
            normalizedBox: CGRect(x: -0.00000005, y: 0.1, width: 0.3, height: 0.8)
        ), imageWidth: 100, imageHeight: 100) != nil &&
        canonicalReadOCRCandidate(OCRCandidate(
            text: "測試對話", confidence: 1,
            normalizedBox: CGRect(x: 0.7, y: 0.1, width: 0.30000005, height: 0.8)
        ), imageWidth: 100, imageHeight: 100) != nil &&
        canonicalReadOCRCandidate(OCRCandidate(
            text: "測試對話", confidence: 1,
            normalizedBox: CGRect(x: 0.1, y: -0.00000005, width: 0.3, height: 0.8)
        ), imageWidth: 100, imageHeight: 100) != nil &&
        canonicalReadOCRCandidate(OCRCandidate(
            text: "測試對話", confidence: 1,
            normalizedBox: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.80000005)
        ), imageWidth: 100, imageHeight: 100) != nil &&
        canonicalReadOCRCandidate(OCRCandidate(
            text: "測試對話", confidence: 1,
            normalizedBox: CGRect(x: -0.000001, y: 0.1, width: 0.3, height: 0.8)
        ), imageWidth: 100, imageHeight: 100) == nil &&
        canonicalReadOCRCandidate(OCRCandidate(
            text: "測試對話", confidence: 1,
            normalizedBox: CGRect(x: -.infinity, y: 0.1, width: 0.3, height: 0.8)
        ), imageWidth: 100, imageHeight: 100) == nil &&
        canonicalReadOCRCandidate(OCRCandidate(
            text: "測試對話", confidence: 1,
            normalizedBox: CGRect(x: 0.1, y: 0.1, width: 0, height: 0.8)
        ), imageWidth: 100, imageHeight: 100) == nil &&
        canonicalReadOCRCandidate(OCRCandidate(
            text: "測試對話", confidence: 1,
            normalizedBox: CGRect(x: -0.2, y: 0.1, width: 0.3, height: 0.8)
        ), imageWidth: 100, imageHeight: 100) == nil
    var rawFirstNormalizedCalls = 0
    let rawFirstChoice = try indexedNameCandidateChoice(
        rawCandidates: [indexedName], expected: "測試對話", imageWidth: 100, imageHeight: 100,
        sourceOwnership: { _, _ in true }, normalizedCandidates: {
            rawFirstNormalizedCalls += 1; return [indexedName]
        }
    )
    var darkBackupCalls = 0
    let darkLow = OCRCandidate(text: "測試對話", confidence: 0.3,
                               normalizedBox: indexedName.normalizedBox)
    let darkBackupChoice = try indexedNameCandidateChoice(
        rawCandidates: [darkLow], expected: "測試對話", imageWidth: 100, imageHeight: 100,
        sourceOwnership: { _, _ in true }, normalizedCandidates: {
            darkBackupCalls += 1; return [indexedName]
        }
    )
    checks["indexed-name-raw-first"] = rawFirstChoice?.normalizedOCRUsed == false &&
        rawFirstNormalizedCalls == 0 && darkBackupChoice?.normalizedOCRUsed == true &&
        darkBackupCalls == 1
    let strongContradictions: [[OCRCandidate]] = [
        [indexedName, darkLow],
        [OCRCandidate(text: "其他", confidence: 1, normalizedBox: indexedName.normalizedBox)],
        [OCRCandidate(text: "前測試對話", confidence: 1, normalizedBox: indexedName.normalizedBox)],
        [OCRCandidate(text: "測試對話後", confidence: 1, normalizedBox: indexedName.normalizedBox)],
        [OCRCandidate(text: "測試對話", confidence: 1,
                      normalizedBox: CGRect(x: .nan, y: 0.2, width: 0.3, height: 0.5))],
        [OCRCandidate(text: "測試對話", confidence: 1,
                      normalizedBox: CGRect(x: 0.2, y: 0.2, width: .infinity, height: 0.5))],
        [OCRCandidate(text: "測試對話", confidence: 1,
                      normalizedBox: CGRect(x: 0.2, y: 0.2, width: 0, height: 0.5))],
    ]
    var contradictionNormalizedCalls = 0
    let contradictionsBlocked = try strongContradictions.allSatisfy { raw in
        try indexedNameCandidateChoice(
            rawCandidates: raw, expected: "測試對話", imageWidth: 100, imageHeight: 100,
            sourceOwnership: { _, _ in true }, normalizedCandidates: {
                contradictionNormalizedCalls += 1; return [indexedName]
            }
        ) == nil
    }
    checks["indexed-name-raw-contradiction-blocks-fallback"] =
        contradictionsBlocked && contradictionNormalizedCalls == 0
    let normalizedFailures: [[OCRCandidate]] = [
        [OCRCandidate(text: "測試對話", confidence: 0.949, normalizedBox: indexedName.normalizedBox)],
        [OCRCandidate(text: "測試對話", confidence: 1,
                      normalizedBox: CGRect(x: .nan, y: 0.2, width: 0.3, height: 0.5))],
        [indexedName, indexedName],
    ]
    var normalizedFailureCalls = 0
    let normalizedFailuresRejected = try normalizedFailures.allSatisfy { normalizedCandidates in
        try indexedNameCandidateChoice(
            rawCandidates: [darkLow], expected: "測試對話", imageWidth: 100, imageHeight: 100,
            sourceOwnership: { _, _ in true }, normalizedCandidates: {
                normalizedFailureCalls += 1; return normalizedCandidates
            }
        ) == nil
    }
    let normalizedOwnershipRejected = try indexedNameCandidateChoice(
        rawCandidates: [darkLow], expected: "測試對話", imageWidth: 100, imageHeight: 100,
        sourceOwnership: { _, _ in false }, normalizedCandidates: { [indexedName] }
    ) == nil
    checks["indexed-name-normalized-backup-strict"] = normalizedFailuresRejected &&
        normalizedFailureCalls == normalizedFailures.count && normalizedOwnershipRejected
    var namePixels = [UInt8](repeating: 220, count: 8 * 8 * 4)
    for index in stride(from: 3, to: namePixels.count, by: 4) { namePixels[index] = 255 }
    for (x, color) in [(2, [0, 180, 40]), (4, [255, 255, 255])] {
        let offset = (3 * 8 + x) * 4
        namePixels[offset] = UInt8(color[0]); namePixels[offset + 1] = UInt8(color[1])
        namePixels[offset + 2] = UInt8(color[2])
    }
    if let nameImage = rgbaImage(topDown: namePixels, width: 8, height: 8) {
        let normalized = try normalizedFullNameImage(nameImage)
        let luma = try imageLuma(normalized)
        checks["indexed-name-normalization-full-rgb"] =
            luma[3 * 8 + 2] < 220 && luma[3 * 8 + 4] < 220
    } else { checks["indexed-name-normalization-full-rgb"] = false }
    func ownershipImage(edgeInk: Bool = false, coloredAux: Bool = false) -> CGImage? {
        let width = 40, height = 20
        var pixels = [UInt8](repeating: 220, count: width * height * 4)
        for index in stride(from: 3, to: pixels.count, by: 4) { pixels[index] = 255 }
        for y in 5..<13 { for x in 5..<15 {
            let offset = (y * width + x) * 4
            pixels[offset] = 32; pixels[offset + 1] = 32; pixels[offset + 2] = 32
        } }
        for y in 6..<13 { for x in 25..<28 {
            let offset = (y * width + x) * 4
            pixels[offset] = coloredAux ? 180 : 80
            pixels[offset + 1] = 80; pixels[offset + 2] = 80
        } }
        if edgeInk { pixels[0] = 20; pixels[1] = 20; pixels[2] = 20 }
        return rgbaImage(topDown: pixels, width: width, height: height)
    }
    let ownershipName = OCRCandidate(text: "測試對話", confidence: 1,
                                     normalizedBox: CGRect(x: 0.125, y: 0.35,
                                                           width: 0.25, height: 0.4))
    let ownershipAux = OCRCandidate(text: "昨天", confidence: 1,
                                    normalizedBox: CGRect(x: 0.625, y: 0.35,
                                                          width: 0.15, height: 0.35))
    if let validOwnershipImage = ownershipImage(),
       let edgeOwnershipImage = ownershipImage(edgeInk: true),
       let colorOwnershipImage = ownershipImage(coloredAux: true) {
        checks["indexed-name-whole-glyph-ownership"] = try indexedWholeGlyphOwnershipAllowed(
            validOwnershipImage, name: ownershipName, auxiliaries: [ownershipAux], scale: 1
        )
        checks["indexed-name-edge-color-rejected"] = try !indexedWholeGlyphOwnershipAllowed(
            edgeOwnershipImage, name: ownershipName, auxiliaries: [ownershipAux], scale: 1
        ) && !indexedWholeGlyphOwnershipAllowed(
            colorOwnershipImage, name: ownershipName, auxiliaries: [ownershipAux], scale: 1
        )
    } else {
        checks["indexed-name-whole-glyph-ownership"] = false
        checks["indexed-name-edge-color-rejected"] = false
    }
    let globalFixture = historyEnvelope(
        globalFixtureArgs, observations: [], observedAt: "2026-10-29T08:00:00Z",
        snapshotDigest: historyMAC(historyKey, ["purpose": "global-selftest-envelope-v1",
                                                "scope": historyScopeBinding(globalFixtureArgs)]),
        nextState: nil, complete: false, reasons: ["NO_MESSAGE_ROWS_VERIFIED"],
        syncState: "unknown", truncated: false, possibleDuplicates: false
    )
    let navigationIdentity = WindowIdentity(
        pid: 4321, windowID: 9876, title: expectedWindowTitle,
        bounds: CGRect(x: 100, y: 80, width: 969, height: 650),
        executableURL: expectedLineExecutablePath,
        signingIdentifier: bundleIdentifier, teamIdentifier: expectedLineTeamIdentifier
    )
    let navigationNonce = String(repeating: "a", count: 64)
    let navigationFixture = globalAllNavigationReceipt(
        chatName: "測試對話", requestNonce: navigationNonce,
        expectedWindow: navigationIdentity.json, mainWindow: navigationIdentity,
        allSelected: true, counts: GlobalAllEventCounts(),
        phase: "verified",
        identityVerified: true
    )
    let navigationFixtures: [String: Any] = [
        "alreadySelected": navigationFixture,
        "inputVerified": globalAllNavigationReceipt(
            chatName: "測試對話", requestNonce: navigationNonce,
            expectedWindow: navigationIdentity.json, mainWindow: navigationIdentity,
            allSelected: true, counts: GlobalAllEventCounts(move: 1, down: 1, up: 1),
            phase: "verified", identityVerified: true
        ),
        "preInputFailure": globalAllNavigationReceipt(
            chatName: "測試對話", requestNonce: navigationNonce,
            expectedWindow: navigationIdentity.json, mainWindow: navigationIdentity,
            allSelected: false, counts: GlobalAllEventCounts(),
            phase: "pre_input",
            identityVerified: true
        ),
        "postInputUnknown": globalAllNavigationReceipt(
            chatName: "測試對話", requestNonce: navigationNonce,
            expectedWindow: navigationIdentity.json, mainWindow: navigationIdentity,
            allSelected: false, counts: GlobalAllEventCounts(move: 1, down: 1, up: 1),
            phase: "post_input", identityVerified: false
        ),
    ]
    checks["global-all-receipt-exact-schema"] = Set(navigationFixture.keys) == [
        "route", "requestNonce", "scope", "expectedWindow", "mainWindow", "allSelected",
        "inputAttempted", "eventCounts", "systemEventsInvocations", "phase", "identityVerified",
    ] && navigationFixture["route"] as? String == globalAllNavigationRoute
    checks["global-all-strict-identity-fields"] = strictLineIdentityFields(
        executablePath: expectedLineExecutablePath, identifier: bundleIdentifier,
        team: expectedLineTeamIdentifier, codeValid: true
    ) && !strictLineIdentityFields(
        executablePath: expectedLineExecutablePath, identifier: bundleIdentifier,
        team: nil, codeValid: true
    ) && !strictLineIdentityFields(
        executablePath: "/private/tmp/LINE", identifier: bundleIdentifier,
        team: expectedLineTeamIdentifier, codeValid: true
    ) && !strictLineIdentityFields(
        executablePath: expectedLineExecutablePath, identifier: bundleIdentifier,
        team: expectedLineTeamIdentifier, codeValid: false
    )
    var driftedNavigationWindow = navigationIdentity.json
    driftedNavigationWindow["teamIdentifier"] = "WRONGTEAM"
    checks["global-all-window-exact-binding"] =
        windowStateExactlyMatches(navigationIdentity.json, navigationIdentity) &&
        !windowStateExactlyMatches(driftedNavigationWindow, navigationIdentity)
    let scriptROI = CGRect(x: 100, y: 80, width: 320, height: 60)
    let scriptLabel = CGRect(x: 140, y: 90, width: 60, height: 30)
    let scriptPoint = CGPoint(x: 169.6, y: 104.6)
    let scriptPlan = systemEventsAllScriptPlan(
        pid: navigationIdentity.pid, window: navigationIdentity.bounds,
        roi: scriptROI, label: scriptLabel, point: scriptPoint
    )!
    checks["global-all-v4-script-owner-bounded"] =
        scriptPlan.point == CGPoint(x: 170, y: 105) &&
        systemEventsAllScriptSourceSafe(
            scriptPlan.source, pid: navigationIdentity.pid,
            point: scriptPlan.point, window: navigationIdentity.bounds
        ) && scriptPlan.source.components(separatedBy: "click at").count == 2
    checks["global-all-v4-script-forbidden-absent"] =
        !scriptPlan.source.contains("測試對話") && !scriptPlan.source.contains("Scope chat") &&
        !scriptPlan.source.localizedCaseInsensitiveContains("keystroke") &&
        !scriptPlan.source.localizedCaseInsensitiveContains("clipboard")
    do {
        _ = try compileSystemEventsAllScript(scriptPlan.source)
        checks["global-all-v4-script-compiles"] = true
    } catch { checks["global-all-v4-script-compiles"] = false }
    checks["global-all-v4-rounded-point-bounds"] = systemEventsAllScriptPlan(
        pid: navigationIdentity.pid, window: navigationIdentity.bounds,
        roi: scriptROI, label: scriptLabel,
        point: CGPoint(x: scriptLabel.maxX - 0.1, y: scriptLabel.maxY - 0.1)
    ) == nil && systemEventsAllScriptPlan(
        pid: navigationIdentity.pid,
        window: CGRect(x: 100.5, y: 80, width: 969, height: 650),
        roi: scriptROI, label: scriptLabel, point: scriptPoint
    ) == nil
    checks["global-all-v4-permission-status"] =
        systemEventsPermissionAllowed(noErr) &&
        !systemEventsPermissionAllowed(OSStatus(errAEEventNotPermitted))
    checks["global-all-v4-numeric-error-only"] =
        appleScriptNumericError([NSAppleScript.errorNumber: NSNumber(value: -1712)]) as NSDictionary ==
        ["appleEventError": -1712] as NSDictionary &&
        appleScriptNumericError([NSAppleScript.errorMessage: "private"] as NSDictionary).isEmpty
    func systemEventsCoreFixture(invokeResult: Bool = true,
                                 invokeThrows: Bool = false,
                                 verifyResult: Bool = true)
        -> (invocations: Int, invokeCalls: Int, verifyCalls: Int, succeeded: Bool) {
        var invokeCalls = 0, verifyCalls = 0
        do {
            let invocations = try runSystemEventsAllCore(invoke: {
                invokeCalls += 1
                if invokeThrows { throw NativeFailure("FIXTURE_TIMEOUT", "fixture") }
                return invokeResult
            }, verify: {
                verifyCalls += 1
                return verifyResult
            })
            return (invocations, invokeCalls, verifyCalls, true)
        } catch let failure as SystemEventsAllCoreFailure {
            return (failure.invocations, invokeCalls, verifyCalls, false)
        } catch { return (0, invokeCalls, verifyCalls, false) }
    }
    let systemEventsSuccess = systemEventsCoreFixture()
    checks["global-all-v4-core-success-one-invocation"] =
        systemEventsSuccess == (1, 1, 1, true)
    let systemEventsThrow = systemEventsCoreFixture(invokeThrows: true)
    checks["global-all-v4-core-throw-counted-once"] =
        systemEventsThrow == (1, 1, 0, false)
    let systemEventsFalse = systemEventsCoreFixture(invokeResult: false)
    checks["global-all-v4-core-false-counted-once"] =
        systemEventsFalse == (1, 1, 0, false)
    let systemEventsProof = systemEventsCoreFixture(verifyResult: false)
    checks["global-all-v4-core-proof-failure-counted-once"] =
        systemEventsProof == (1, 1, 1, false)
    let navigationPoint = CGPoint(x: 621.7, y: 62.25)
    let navigationEvents = try buildGlobalAllMouseEvents(point: navigationPoint, eventNumber: 77)
    checks["global-all-event-builder-fields"] = globalAllMouseEventsValid(
        navigationEvents, point: navigationPoint, eventNumber: 77
    )
    let boundaryPoint = CGPoint(x: 616.707, y: 62.25)
    let boundaryEvents = try buildGlobalAllMouseEvents(
        point: boundaryPoint, eventNumber: Int64(Int16.max)
    )
    checks["global-all-event-builder-32767"] = globalAllMouseEventsValid(
        boundaryEvents, point: boundaryPoint, eventNumber: Int64(Int16.max)
    )
    var rejectedBoundaryPosts = 0
    func eventNumberRejectedWithoutPost(_ eventNumber: Int64) -> Bool {
        do {
            let events = try buildGlobalAllMouseEvents(point: boundaryPoint, eventNumber: eventNumber)
            _ = try runGlobalAllMouseCore(pid: 4321, guardFresh: { _ in }, post: { step, _ in
                rejectedBoundaryPosts += 1
                _ = events.event(step)
            })
            return false
        } catch let failure as NativeFailure {
            return failure.code == "MOUSE_EVENT_FAILED"
        } catch { return false }
    }
    checks["global-all-event-builder-large-rejected-zero-post"] =
        eventNumberRejectedWithoutPost(Int64(Int16.max) + 1) &&
        eventNumberRejectedWithoutPost(2_147_483_000) && rejectedBoundaryPosts == 0
    func coreFixture(failingGuard: GlobalAllMouseStep? = nil,
                     failingPost: GlobalAllMouseStep? = nil)
        -> ([GlobalAllMouseStep], [GlobalAllMouseStep], GlobalAllEventCounts, Bool) {
        var guards = [GlobalAllMouseStep](), posts = [GlobalAllMouseStep]()
        do {
            let counts = try runGlobalAllMouseCore(pid: 4321, guardFresh: { step in
                guards.append(step)
                if step == failingGuard { throw NativeFailure("FIXTURE_GUARD", "fixture") }
            }, post: { step, pid in
                posts.append(step)
                guard pid == 4321 else { throw NativeFailure("FIXTURE_PID", "fixture") }
                if step == failingPost { throw NativeFailure("FIXTURE_POST", "fixture") }
            })
            return (guards, posts, counts, true)
        } catch let failure as GlobalAllCoreFailure {
            return (guards, posts, failure.counts, false)
        } catch {
            return (guards, posts, GlobalAllEventCounts(), false)
        }
    }
    let orderedCore = coreFixture()
    checks["global-all-core-ordered"] = orderedCore.0 == [.move, .down, .up] &&
        orderedCore.1 == [.move, .down, .up] && orderedCore.2.json as NSDictionary ==
        ["move": 1, "down": 1, "up": 1] as NSDictionary && orderedCore.3
    let zeroCore = coreFixture(failingGuard: .move)
    checks["global-all-core-preinput-zero"] = zeroCore.1.isEmpty &&
        !zeroCore.2.inputAttempted && !zeroCore.3
    let moveOnlyCore = coreFixture(failingGuard: .down)
    checks["global-all-core-move-only-no-release"] = moveOnlyCore.1 == [.move] &&
        moveOnlyCore.2.move == 1 && moveOnlyCore.2.down == 0 && moveOnlyCore.2.up == 0
    let downFailureCore = coreFixture(failingPost: .down)
    checks["global-all-core-down-failure-release-once"] =
        downFailureCore.1 == [.move, .down, .up] && downFailureCore.2.up == 1 && !downFailureCore.3
    let upGuardCore = coreFixture(failingGuard: .up)
    checks["global-all-core-up-guard-release-once"] =
        upGuardCore.1 == [.move, .down, .up] && upGuardCore.2.up == 1 && !upGuardCore.3
    let upFailureCore = coreFixture(failingPost: .up)
    checks["global-all-core-up-failure-no-retry"] =
        upFailureCore.1 == [.move, .down, .up] && upFailureCore.2.up == 1 && !upFailureCore.3
    var eventCount = 0
    let denied = Request(name: "sendMessage", args: ["tabName": "Scope tab", "chatName": "Scope chat"],
                         liveScope: LiveScope(tabName: "Scope tab", chatName: "Scope chat"))
    do { try enforceLiveScope(denied); eventCount += 1; checks["live-scope-zero-events"] = false }
    catch let failure as NativeFailure { checks["live-scope-zero-events"] = failure.code == "LIVE_SCOPE_DENIED" && eventCount == 0 }
    let globalScope = LiveScope(globalChatName: "測試對話")
    let allowedGlobal = Request(name: "readGlobalHistoryPage", args: globalRawArgs,
                                liveScope: globalScope)
    do {
        try enforceLiveScope(allowedGlobal)
        checks["global-live-scope-allows-exact-read"] = eventCount == 0
    } catch { checks["global-live-scope-allows-exact-read"] = false }
    let globalSelectorArgs: [String: Any] = [
        "chatName": "測試對話", "requestNonce": navigationNonce,
        "expectedWindow": navigationIdentity.json,
    ]
    let allowedGlobalSelector = Request(name: "selectGlobalAll", args: globalSelectorArgs,
                                        liveScope: globalScope)
    do {
        try enforceLiveScope(allowedGlobalSelector)
        checks["global-live-scope-allows-selector"] = eventCount == 0
    } catch { checks["global-live-scope-allows-selector"] = false }
    let allowedGlobalObserver = Request(name: "observeGlobalAll", args: globalSelectorArgs,
                                        liveScope: globalScope)
    do {
        try enforceLiveScope(allowedGlobalObserver)
        checks["global-live-scope-allows-observer"] = eventCount == 0
    } catch { checks["global-live-scope-allows-observer"] = false }
    let deniedGlobalInventory = Request(name: "listTabs", args: [:], liveScope: globalScope)
    do {
        try enforceLiveScope(deniedGlobalInventory)
        checks["global-live-scope-denies-inventory"] = false
    } catch let failure as NativeFailure {
        checks["global-live-scope-denies-inventory"] = failure.code == "LIVE_SCOPE_DENIED" && eventCount == 0
    }
    let legacyGlobalRead = Request(name: "readGlobalHistoryPage", args: globalRawArgs,
                                   liveScope: LiveScope(tabName: "全部", chatName: "測試對話"))
    do {
        try enforceLiveScope(legacyGlobalRead)
        checks["legacy-live-scope-denies-global"] = false
    } catch let failure as NativeFailure {
        checks["legacy-live-scope-denies-global"] = failure.code == "LIVE_SCOPE_DENIED" && eventCount == 0
    }
    let legacyGlobalSelector = Request(name: "selectGlobalAll", args: globalSelectorArgs,
                                       liveScope: LiveScope(tabName: "全部", chatName: "測試對話"))
    do {
        try enforceLiveScope(legacyGlobalSelector)
        checks["legacy-live-scope-denies-selector"] = false
    } catch let failure as NativeFailure {
        checks["legacy-live-scope-denies-selector"] =
            failure.code == "LIVE_SCOPE_DENIED" && eventCount == 0
    }
    let legacyGlobalObserver = Request(name: "observeGlobalAll", args: globalSelectorArgs,
                                       liveScope: LiveScope(tabName: "全部", chatName: "測試對話"))
    do {
        try enforceLiveScope(legacyGlobalObserver)
        checks["legacy-live-scope-denies-observer"] = false
    } catch let failure as NativeFailure {
        checks["legacy-live-scope-denies-observer"] =
            failure.code == "LIVE_SCOPE_DENIED" && eventCount == 0
    }
    guard checks.values.allSatisfy({ $0 }) else {
        throw NativeFailure("SELF_TEST_FAILED", "native 純函式安全策略測試失敗",
                            ["failed": checks.filter { !$0.value }.map(\.key).sorted()])
    }
    return ["passed": true, "checks": checks, "count": checks.count,
            "globalHistoryFixture": globalFixture,
            "globalAllNavigationFixture": navigationFixture,
            "globalAllNavigationFixtures": navigationFixtures]
}

func parseRequest() throws -> Request {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard data.count <= 1_048_576,
          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          Set(object.keys).isSubset(of: ["name", "args", "liveScope"]),
          let name = object["name"] as? String, let args = object["args"] as? [String: Any] else {
        throw NativeFailure("INVALID_REQUEST", "native request 格式不正確")
    }
    var scope: LiveScope?
    if let raw = object["liveScope"] {
        guard let value = raw as? [String: Any] else {
            throw NativeFailure("INVALID_LIVE_SCOPE", "liveScope 必須是物件")
        }
        if Set(value.keys) == ["tabName", "chatName"],
           let tab = validName(value["tabName"]), let chat = validName(value["chatName"]) {
            scope = LiveScope(tabName: tab, chatName: chat)
        } else if (Set(value.keys) == ["kind", "chatName"] ||
                   Set(value.keys) == ["kind", "chatName", "resultIndex"]),
                  value["kind"] as? String == "global",
                  let chat = validName(value["chatName"]),
                  (value["resultIndex"] == nil ||
                   strictInteger(value["resultIndex"], minimum: 1, maximum: 20) != nil) {
            scope = LiveScope(globalChatName: chat,
                              resultIndex: strictInteger(value["resultIndex"], minimum: 1, maximum: 20))
        } else {
            throw NativeFailure("INVALID_LIVE_SCOPE",
                                "liveScope 必須是 legacy exact scope 或 {kind:global,chatName}")
        }
    }
    return Request(name: name, args: args, liveScope: scope)
}

func dispatch(_ request: Request) throws -> [String: Any] {
    // scope gate 必須早於任何 AX、clipboard、capture 或事件建立。
    try enforceLiveScope(request)
    if request.name != "selfTest" && request.name != "inspectImage" && request.name != "inspectFile" &&
        ProcessInfo.processInfo.environment["LINE_NATIVE_DISABLE_UI"] == "1" {
        throw NativeFailure("NATIVE_DISABLED", "測試環境已禁止所有 native UI 與程序存取")
    }
    try validateArgs(request)
    switch request.name {
    case "inspectImageTarget":
        guard let chat = validName(request.args["chatName"]) else {
            throw NativeFailure("INVALID_ARGUMENT", "圖片目標需要唯一聊天室名稱")
        }
        let (identity, _, point) = try imageSendTarget(chat)
        return ["chatVerified": true, "mainWindow": identity.json,
                "attachmentPoint": ["x": point.x, "y": point.y], "inputAttempted": false]
    case "inspectImage":
        // 純本機檔案解碼與 metadata 清除，不接觸任何桌面 API；供雙停用離線驗收。
        let asset = try stageImageSendAsset(path: request.args["imagePath"] as! String,
                                            expectedDigest: request.args["imageSha256"] as! String)
        defer { try? FileManager.default.removeItem(at: asset.directory) }
        return ["sourceSha256": asset.sourceDigest, "imageSha256": asset.digest,
                "width": asset.width, "height": asset.height, "uiAccessed": false]
    case "inspectFile":
        guard Set(request.args.keys) == ["filePath", "fileSha256"],
              let path = request.args["filePath"] as? String, path.hasPrefix("/"),
              let digest = validHex(request.args["fileSha256"], count: 64) else {
            throw NativeFailure("INVALID_ARGUMENT", "檔案檢查參數格式錯誤")
        }
        let asset = try stageFileSendAsset(path: path, expectedDigest: digest)
        defer { try? FileManager.default.removeItem(at: asset.directory) }
        return ["sourceSha256": asset.sourceDigest, "fileSha256": asset.digest,
                "byteCount": asset.byteCount, "fileNamePreserved": asset.file.lastPathComponent.precomposedStringWithCanonicalMapping == URL(fileURLWithPath: path).lastPathComponent.precomposedStringWithCanonicalMapping,
                "uiAccessed": false]
    case "selfTest": return try runSelfTests()
    case "diagnostics":
        return ["checked": true, "accessibilityTrusted": AXIsProcessTrusted(),
                "screenCaptureTrusted": CGPreflightScreenCaptureAccess(),
                "lineRunning": !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty,
                "inputAttempted": false, "contentRead": false]
    case "status": return try status()
    case "processStatus": return ["running": !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty]
    case "accessibilityStatus": return ["trusted": AXIsProcessTrusted()]
    case "activateLine": return ["success": try lineApplication().activate(options: [.activateAllWindows])]
    case "listTabs": return try listTabs(request.args, liveScope: request.liveScope)
    case "listTabChats": return try listTabChats(request.args)
    case "previewMarkTabRead": return try previewMarkTabRead(request.args)
    case "snapshotMarkTabRead": return try snapshotMarkTabRead(request.args)
    case "executeMarkTabRead": return try executeMarkTabRead(request.args)
    case "previewTabChanges": return try previewTabChanges(request.args)
    case "snapshotTabChanges": return try snapshotTabChanges(request.args)
    case "executeTabChange": return try executeTabChange(request.args)
    case "selectChat":
        guard let chat = request.args["chatName"] as? String else { throw NativeFailure("INVALID_ARGUMENT", "缺少 chatName") }
        return try selectChat(chat, tabName: request.args["tabName"] as? String)
    case "getHistory": return try getHistory(request.args)
    case "readHistoryPage": return try readHistoryPage(request.args)
    case "selectGlobalAll": return try selectGlobalAll(request.args)
    case "observeGlobalAll": return try observeGlobalAll(request.args)
    case "readGlobalHistoryPage": return try readGlobalHistoryPage(request.args)
    case "probeReadChatTitles": return try probeReadChatTitles(request.args, liveScope: request.liveScope)
    case "probeAXReadScope": return try probeAXReadScope(request.args, liveScope: request.liveScope)
    case "prepareTextExportScope", "exportChatText":
        return try textExportCalibrationRequired(request.name, request.args)
    case "sendImage": return try sendImage(request.args)
    case "sendFile": return try sendFile(request.args)
    case "sendMessage": return try sendMessage(request.args)
    default: throw NativeFailure("UNKNOWN_NATIVE_COMMAND", "不支援的 native command")
    }
}

do {
    let result = try dispatch(try parseRequest())
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: ["ok": true, "result": result], options: [.sortedKeys]))
} catch let failure as NativeFailure {
    FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject: [
        "ok": false, "error": ["code": failure.code, "message": failure.message, "details": failure.details],
    ], options: [.sortedKeys]))
} catch {
    FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject: [
        "ok": false, "error": ["code": "NATIVE_FAILURE", "message": "native helper 未預期失敗", "details": [:]],
    ], options: [.sortedKeys]))
}

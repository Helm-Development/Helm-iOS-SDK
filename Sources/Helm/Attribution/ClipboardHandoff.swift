import Foundation
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Public result type (HELM-325)

/// What happened after the user tapped the Paste button
/// (`HelmPasteButton` or the control from `Helm.attribution.makePasteControl()`).
///
/// Every case means the app can move on. None of them needs to be shown to
/// the user as an error.
public enum ClipboardHandoffResult: Equatable, Sendable {

    /// Helm matched the pasted code and recorded the install's attribution.
    case matched

    /// The paste did not attribute the install. `reason` is one of:
    /// - `"unknown"`, `"expired"` or `"redeemed"`: Helm's answer for the code.
    /// - `"not_handoff_url"`: the pasted URL was not a Helm clipboard handoff
    ///   URL. Nothing was sent to Helm.
    ///
    /// Helm may add new reasons later, so treat any other value the same way.
    case notMatched(reason: String)

    /// The code could not be redeemed now. If the network was unreachable,
    /// the SDK keeps the code and sends it again on the next
    /// `Helm.configure(...)`, when the app returns to the foreground, or before
    /// the next attribution call.
    case failed
}

extension Notification.Name {

    /// HELM-325: posted on the main queue when the answer to
    /// `Helm.attribution.hasClipboardHandoff()` changes, for example because a
    /// handoff URL arrived on the clipboard after the app launched, or because
    /// the code was redeemed. The new answer is in `userInfo["available"]` as
    /// a `Bool`.
    ///
    /// The SDK starts watching the clipboard only after the app has called
    /// `hasClipboardHandoff()` once, so apps that do not use the clipboard
    /// handoff never have the clipboard checked.
    public static let helmClipboardHandoffAvailabilityDidChange =
        Notification.Name("HelmClipboardHandoffAvailabilityDidChange")
}

// MARK: - Code parsing

/// Parses clipboard handoff URLs.
///
/// A handoff URL has the form `https://<link domain>/h/<code>/`, where `<code>`
/// is at least 12 characters from `A-Z`, `a-z`, `0-9`, `_` and `-`. Helm's
/// server does the real check; this only stops the SDK from sending anything
/// that is clearly not a handoff code.
internal enum ClipboardHandoffCode {

    /// The shortest code the server issues.
    static let minimumLength = 12

    private static let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")

    /// The code inside `url`, or `nil` when `url` is not a handoff URL.
    ///
    /// The scheme must be `https` and the host must be present. The path must
    /// be exactly `/h/<code>/`. A query string or fragment is ignored.
    static func code(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty else {
            return nil
        }
        // `percentEncodedPath` keeps the path exactly as written, so an
        // encoded slash or other escape cannot pass as part of a code.
        let path = components.percentEncodedPath
        guard path.hasPrefix("/h/"), path.hasSuffix("/") else { return nil }
        let code = path.dropFirst("/h/".count).dropLast()
        guard code.count >= minimumLength, code.allSatisfy(allowed.contains) else {
            return nil
        }
        return String(code)
    }
}

// MARK: - Loading pasted items

/// Turns the items from a Paste button into a URL. Shared by
/// `HelmPasteButton` and `makePasteControl(configuration:onResult:)`.
///
/// The Paste buttons accept URLs and plain text, because a web page that
/// copies a URL may put it on the clipboard as either type. This only turns
/// the pasted item into a `URL`; `ClipboardHandoffCode.code(from:)` decides
/// whether it is a handoff URL.
internal enum PastedItemLoader {

    /// The pasted URL, or `nil` when no item holds one.
    ///
    /// Prefers an item that holds a URL (`UTType.url`) and loads as a `URL`.
    /// Otherwise loads the first item that holds text, trims whitespace and
    /// line breaks, and reads the rest as a URL.
    ///
    /// The URL pass checks the item's type rather than only
    /// `canLoadObject(ofClass: URL.self)`, because `NSURL` can also load from
    /// a plain-text item, which would make every text item count as a URL.
    static func url(from itemProviders: [NSItemProvider]) async -> URL? {
        for provider in itemProviders
        where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
            && provider.canLoadObject(ofClass: URL.self) {
            if let url = await loadURL(from: provider) {
                return url
            }
        }
        for provider in itemProviders where provider.canLoadObject(ofClass: NSString.self) {
            if let text = await loadString(from: provider) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : URL(string: trimmed)
            }
        }
        return nil
    }

    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }

    private static func loadString(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                continuation.resume(returning: object as? String)
            }
        }
    }
}

// MARK: - Pasteboard access

/// The pasteboard operations the clipboard handoff needs. None of them shows
/// the iOS paste prompt or the "pasted from" notice.
///
/// Hidden behind a protocol so tests never touch the real clipboard.
///
/// - Important: implementations must never read `UIPasteboard.string`,
///   `.url`, `.urls` or `.items`, and must never call `detectedValues` or
///   `detectValues`. Each of those shows the paste prompt or notice.
internal protocol PasteboardAccess: AnyObject, Sendable {

    /// The number of times the clipboard contents have changed. Reading it
    /// does not prompt.
    var changeCount: Int { get }

    /// Whether the clipboard probably holds a web URL, checked without a
    /// prompt (`hasURLs` and `detectPatterns(for: [.probableWebURL])`).
    func hasProbableWebURL() async -> Bool

    /// Empty the clipboard. Writing to the clipboard does not prompt.
    func clear()
}

/// Used where UIKit is not available (macOS). There is no clipboard handoff
/// there, so it reports an empty clipboard.
internal final class NoPasteboard: PasteboardAccess, @unchecked Sendable {
    var changeCount: Int { 0 }
    func hasProbableWebURL() async -> Bool { false }
    func clear() {}
}

#if canImport(UIKit) && os(iOS)
/// The system clipboard (`UIPasteboard.general`), read only in ways that do
/// not prompt.
internal final class SystemPasteboard: PasteboardAccess, @unchecked Sendable {

    var changeCount: Int {
        UIPasteboard.general.changeCount
    }

    func hasProbableWebURL() async -> Bool {
        let pasteboard = UIPasteboard.general
        // `hasURLs` covers an item typed as a URL. A web page that copies a
        // URL usually writes plain text, which pattern detection covers.
        // Apple documents that neither of these notifies the user.
        if pasteboard.hasURLs { return true }
        guard pasteboard.hasStrings else { return false }
        // The iOS 15 form of `detectPatterns(for: [.probableWebURL])`. It
        // reports which patterns are present, never the values themselves.
        return await withCheckedContinuation { continuation in
            pasteboard.detectPatterns(for: [\UIPasteboard.DetectedValues.probableWebURL]) { result in
                switch result {
                case .success(let patterns):
                    continuation.resume(returning: patterns.contains(\UIPasteboard.DetectedValues.probableWebURL))
                case .failure:
                    continuation.resume(returning: false)
                }
            }
        }
    }

    func clear() {
        // A write. `setItems` replaces everything on the clipboard and does
        // not read it.
        UIPasteboard.general.setItems([], options: [:])
    }
}
#endif

internal enum DefaultPasteboard {
    /// The real clipboard on iOS, and an empty one elsewhere.
    static func make() -> PasteboardAccess {
        #if canImport(UIKit) && os(iOS)
        return SystemPasteboard()
        #else
        return NoPasteboard()
        #endif
    }
}

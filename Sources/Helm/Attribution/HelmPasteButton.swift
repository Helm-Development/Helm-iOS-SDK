#if canImport(UIKit) && os(iOS)
import Foundation
import ObjectiveC
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// HELM-325: Paste button views for the clipboard handoff.
//
// Both views use Apple's own Paste button (SwiftUI `PasteButton`, UIKit
// `UIPasteControl`). iOS treats a tap on it as the user's permission to paste,
// so no paste prompt appears. Apple requires the button to be clearly
// visible: enough contrast, nothing covering it, and not hidden or
// transparent. If iOS decides the button was not visible when tapped, the
// paste does nothing.

/// A SwiftUI Paste button that hands a clipboard handoff code to Helm.
///
/// Show it when `Helm.attribution.hasClipboardHandoff()` returns `true`. The
/// button accepts URLs and plain text, and is enabled whenever the clipboard
/// holds either. When the user taps it, the SDK checks that the pasted value
/// is a Helm handoff URL, sends the code to Helm, and calls `onResult` on the
/// main actor.
///
/// Style it with the usual modifiers, for example `.labelStyle(.titleAndIcon)`,
/// `.buttonBorderShape(.capsule)` and `.tint(.accentColor)`. iOS draws the
/// label; it cannot be replaced.
@available(iOS 16.0, *)
public struct HelmPasteButton: View {

    private let onResult: (@MainActor (ClipboardHandoffResult) -> Void)?

    /// - Parameter onResult: Called on the main actor with the outcome of the
    ///   paste, so the app can move on. Optional.
    public init(onResult: (@MainActor (ClipboardHandoffResult) -> Void)? = nil) {
        self.onResult = onResult
    }

    public var body: some View {
        PasteButton(supportedContentTypes: [.url, .plainText]) { itemProviders in
            let attribution = Helm.attribution
            attribution.handlePaste(itemProviders: itemProviders,
                                    changeCountAtPaste: attribution.pasteboardChangeCount,
                                    onResult: onResult)
        }
    }
}

@available(iOS 16.0, *)
extension Attribution {

    /// A UIKit Paste button that hands a clipboard handoff code to Helm.
    ///
    /// Show it when `hasClipboardHandoff()` returns `true`. The control accepts
    /// URLs (`UTType.url`) and plain text (`UTType.plainText`), and is enabled
    /// whenever the clipboard holds either. When the user taps it, the SDK
    /// checks that the pasted value is a Helm handoff URL, sends the code to
    /// Helm, and calls `onResult` on the main actor.
    ///
    /// Add the returned control to your view hierarchy and lay it out like any
    /// other view. Keep it clearly visible: enough contrast and nothing
    /// covering it, or iOS ignores the tap.
    ///
    /// - Parameters:
    ///   - configuration: How iOS draws the control (`displayMode`,
    ///     `cornerStyle`, colors). `nil` uses the system default.
    ///   - onResult: Called on the main actor with the outcome of the paste,
    ///     so the app can move on. Optional.
    /// - Returns: A new `UIPasteControl`. It keeps its paste target alive for
    ///   as long as the control exists.
    @MainActor
    public func makePasteControl(configuration: UIPasteControl.Configuration? = nil,
                                 onResult: (@MainActor (ClipboardHandoffResult) -> Void)? = nil) -> UIPasteControl {
        let control = UIPasteControl(configuration: configuration ?? UIPasteControl.Configuration())
        let target = HelmPasteTarget(attribution: self, onResult: onResult)
        control.target = target
        // `UIPasteControl.target` is weak. Tie the target's lifetime to the
        // control's so the app does not have to hold it.
        objc_setAssociatedObject(control, &HelmPasteTarget.associationKey, target, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return control
    }
}

/// The paste target behind `makePasteControl(configuration:onResult:)`. It
/// accepts URLs and plain text.
@available(iOS 16.0, *)
@MainActor
internal final class HelmPasteTarget: NSObject, UIPasteConfigurationSupporting {

    nonisolated(unsafe) static var associationKey: UInt8 = 0

    var pasteConfiguration: UIPasteConfiguration? =
        UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.url.identifier, UTType.plainText.identifier])

    private let attribution: Attribution
    private let onResult: (@MainActor (ClipboardHandoffResult) -> Void)?

    init(attribution: Attribution, onResult: (@MainActor (ClipboardHandoffResult) -> Void)?) {
        self.attribution = attribution
        self.onResult = onResult
        super.init()
    }

    func paste(itemProviders: [NSItemProvider]) {
        // Read the change count now, at the moment of the paste.
        attribution.handlePaste(itemProviders: itemProviders,
                                changeCountAtPaste: attribution.pasteboardChangeCount,
                                onResult: onResult)
    }
}
#endif

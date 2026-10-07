import AppKit
import SwiftUI
import VehlaDockWidgetSDK

@objc(AntinoteDockWidgetPlugin)
public final class AntinoteDockWidgetPlugin: NSObject, VehlaDockWidgetPlugin {
    public let apiVersion = VehlaDockWidgetAPIVersion
    public let widgets = [
        VehlaDockWidgetDescriptor(
            id: "antinote",
            title: "Antinote",
            subtitle: "Notes from Antinote",
            systemImage: "note.text",
            preferredPopupWidth: 760,
            preferredPopupHeight: 680,
            supportedSurfaces: [.compact, .inline, .popup]
        ),
    ]

    @MainActor private let model = AntinoteModel()

    @MainActor
    public func makeViewController(
        widgetID: String,
        surface: VehlaDockWidgetSurface,
        context: VehlaDockWidgetContext
    ) throws -> NSViewController {
        guard widgetID == "antinote" else {
            throw CocoaError(.fileNoSuchFile)
        }
        model.configure(context)
        return NSHostingController(rootView: AntinoteRootView(surface: surface, model: model))
    }

    @MainActor
    public func widget(
        _ widgetID: String,
        didEnter phase: VehlaDockWidgetVisibilityPhase
    ) {
        phase == .hidden ? model.stop() : model.start()
    }

    @MainActor
    public func widget(
        _ widgetID: String,
        themeDidChange theme: VehlaDockWidgetTheme
    ) {
        model.theme = theme
    }

    @MainActor
    public func widgetWillClose(_ widgetID: String) {
        model.stop()
    }
}

import AppKit
import SwiftUI
import VehlaDockWidgetSDK

@objc(ResearchDockWidgetPlugin)
public final class ResearchDockWidgetPlugin: NSObject, VehlaDockWidgetPlugin {
    public let apiVersion = VehlaDockWidgetAPIVersion
    public let widgets = [VehlaDockWidgetDescriptor(id: "research", title: "Research", subtitle: "Your reading queue", systemImage: "books.vertical", preferredPopupWidth: 760, preferredPopupHeight: 800, supportedSurfaces: [.compact, .inline, .popup])]
    @MainActor private let model = ResearchModel()
    @MainActor public func makeViewController(widgetID: String, surface: VehlaDockWidgetSurface, context: VehlaDockWidgetContext) throws -> NSViewController {
        guard widgetID == "research" else { throw CocoaError(.fileNoSuchFile) }
        model.configure(context)
        return NSHostingController(rootView: ResearchRootView(surface: surface, model: model))
    }
    @MainActor public func widget(_ widgetID: String, didEnter phase: VehlaDockWidgetVisibilityPhase) {
        phase == .hidden ? model.stop() : model.start()
    }
    @MainActor public func widget(_ widgetID: String, themeDidChange theme: VehlaDockWidgetTheme) { model.theme = theme }
    @MainActor public func widgetWillClose(_ widgetID: String) { model.stop() }
}

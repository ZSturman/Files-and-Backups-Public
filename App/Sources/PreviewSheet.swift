import QuickLook
import SwiftUI

/// File preview. On iOS/iPadOS a sheet hosting QLPreviewController (which
/// includes Share/Save); SwiftUI's quickLookPreview did not present
/// reliably inside the iPad tab layout. macOS uses the system Quick Look panel.
struct FilePreview: ViewModifier {
    @Binding var url: URL?

    func body(content: Content) -> some View {
        #if os(iOS)
        content.sheet(isPresented: Binding(get: { url != nil }, set: { if !$0 { url = nil } })) {
            if let url {
                QuickLookController(url: url)
                    .ignoresSafeArea()
                    .accessibilityIdentifier("filePreview")
            }
        }
        #else
        content.quickLookPreview($url)
        #endif
    }
}

extension View {
    func filePreview(_ url: Binding<URL?>) -> some View { modifier(FilePreview(url: url)) }
}

#if os(iOS)
struct QuickLookController: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak controller] _ in
            controller?.dismiss(animated: true)
        })
        return UINavigationController(rootViewController: controller)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {
        context.coordinator.url = url
        (controller.viewControllers.first as? QLPreviewController)?.reloadData()
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { url as NSURL }
    }
}
#endif

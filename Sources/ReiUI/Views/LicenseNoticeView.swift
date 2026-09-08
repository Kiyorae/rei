import SwiftUI

/// Bundled notices stay readable without a network or a file-type association.
struct LicenseNoticeView: View {
    let component: ComponentAcknowledgement
    @Environment(\.dismiss) private var dismiss
    @State private var text: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(component.title).font(.title2.weight(.semibold))
                    Text(component.license).foregroundStyle(.secondary)
                }
                Spacer()
                Link("Online License", destination: component.licenseWebsite)
            }
            .padding(20)
            Divider()
            Group {
                if let text {
                    ScrollView {
                        Text(text)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                    }
                } else if let errorMessage {
                    ContentUnavailableView(
                        "License Unavailable", systemImage: "doc.text",
                        description: Text(errorMessage)
                    )
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 620, height: 540)
        .task(id: component.id) {
            do {
                text = try String(contentsOf: component.licenseURL, encoding: .utf8)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

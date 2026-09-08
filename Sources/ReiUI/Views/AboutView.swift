import ReiCore
import SwiftUI

struct AboutView: View {
    let store: ReiStore
    private let acknowledgements = ComponentAcknowledgement.bundled
    @State private var selectedLicense: ComponentAcknowledgement?

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 18) {
                    AvatarView(
                        name: "Akame",
                        path: Bundle.module.url(
                            forResource: "Akame", withExtension: "png", subdirectory: "Showcase"
                        )?.path, size: 72
                    )
                    .modifier(LogoSpinEasterEgg())

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Rei for macOS").font(.title2.weight(.semibold))
                        Text(version).font(.callout).foregroundStyle(.secondary)
                        Text("Native SwiftUI · AppKit · SwiftData")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(
                            "A local protocol simulator and conversation workspace for developing and debugging chat bots."
                        )
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 16) {
                            Link("Project Homepage", destination: URL(string: "https://github.com/Kiyorae/rei")!)
                            Link("AGPL-3.0", destination: URL(string: "https://www.gnu.org/licenses/agpl-3.0.html")!)
                        }
                        .font(.callout)
                    }
                }
                .padding(.vertical, 8)
            }

            Section("Local Storage") {
                if let fileURL = store.fileURL {
                    LabeledContent("Workspace") {
                        Button("Open Data Folder", systemImage: "folder") {
                            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                        }
                        .buttonStyle(.borderless)
                    }
                } else {
                    Label("This workspace stores conversations in memory.", systemImage: "memorychip")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Protocol Documentation") {
                protocolLink("OneBot V11", url: "https://11.onebot.dev/")
                protocolLink("OneBot V12", url: "https://12.onebot.dev/")
                protocolLink("Milky 1.3", url: "https://milky.ntqqrev.org/")
            }

            Section {
                ForEach(acknowledgements) { component in
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Link(component.title, destination: component.homepage)
                                .foregroundStyle(.primary)
                            Text(component.purpose).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Link(component.license, destination: component.licenseURL)
                            .font(.callout)
                            .multilineTextAlignment(.trailing)
                            .help("Read the license for \(component.name)")
                    }
                    .padding(.vertical, 3)
                }
                if let notices = ComponentAcknowledgement.mediaToolsURL {
                    Button("Open Bundled Licenses & Sources", systemImage: "folder") {
                        NSWorkspace.shared.open(notices)
                    }
                    .buttonStyle(.borderless)
                }
            } header: {
                Text("Components & Licenses")
            } footer: {
                Text(
                    "Media conversion uses a bundled FFmpeg executable. License links open the exact bundled notices when available. Apple frameworks are provided by macOS."
                )
                .font(.caption)
            }
        }
        .formStyle(.grouped)
        .environment(
            \.openURL,
            OpenURLAction { url in
                guard url.isFileURL,
                    let component = acknowledgements.first(where: { $0.licenseURL == url })
                else { return .systemAction }
                selectedLicense = component
                return .handled
            }
        )
        .sheet(item: $selectedLicense) { component in
            LicenseNoticeView(component: component)
        }
    }

    private var version: String {
        guard let release = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        else { return "Development Build" }
        return "Version \(release) (\(build))"
    }

    private func protocolLink(_ title: String, url: String) -> some View {
        LabeledContent(title) {
            Link(destination: URL(string: url)!) {
                Label("Documentation", systemImage: "arrow.up.right")
            }
        }
    }
}

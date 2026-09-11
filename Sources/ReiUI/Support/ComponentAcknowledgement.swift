import Foundation

/// Credits and bundled notices for shipped components. Media tool versions come
/// from their build lockfile; Swift package revisions are pinned by SwiftPM.
struct ComponentAcknowledgement: Identifiable {
    let id: String
    let name: String
    let version: String?
    let purpose: String
    let homepage: URL
    let license: String
    let licenseURL: URL
    let licenseWebsite: URL

    var title: String { version.map { "\(name) \($0)" } ?? name }

    static var mediaToolsURL: URL? {
        Bundle.main.url(forResource: "MediaTools", withExtension: nil)
    }

    static var bundled: [Self] {
        let lock = mediaToolsURL?.appendingPathComponent("media-dependencies.lock")
        let versions =
            lock.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .map { contents in
                contents.split(separator: "\n").reduce(into: [String: String]()) { versions, line in
                    let fields = line.split(separator: "|")
                    if !line.hasPrefix("#"), fields.count == 5 {
                        versions[String(fields[0])] = String(fields[1])
                    }
                }
            } ?? [:]

        func component(
            _ id: String, _ name: String, _ purpose: String, _ homepage: String,
            _ license: String, _ filename: String, _ fallback: String
        ) -> Self {
            let bundledURL = Bundle.main.url(
                forResource: filename, withExtension: nil,
                subdirectory: id == "silk" ? "SILK" : "MediaTools/Licenses"
            )
            return Self(
                id: id, name: name, version: id == "silk" ? "1.0.9" : versions[id],
                purpose: purpose, homepage: URL(string: homepage)!, license: license,
                licenseURL: bundledURL ?? URL(string: fallback)!, licenseWebsite: URL(string: fallback)!
            )
        }

        return [
            component(
                "ffmpeg", "FFmpeg", "Audio and video conversion", "https://ffmpeg.org/",
                "LGPL-3.0-or-later", "ffmpeg-COPYING.LGPLv3", "https://www.gnu.org/licenses/lgpl-3.0.html"
            ),
            component(
                "lame", "LAME", "MP3 encoding", "https://lame.sourceforge.io/",
                "LGPL-2.0-or-later", "lame-COPYING", "https://www.gnu.org/licenses/old-licenses/lgpl-2.0.html"
            ),
            component(
                "opencore-amr", "OpenCORE AMR", "AMR voice codecs", "https://opencore-amr.sourceforge.net/",
                "Apache-2.0", "opencore-amr-LICENSE", "https://www.apache.org/licenses/LICENSE-2.0"
            ),
            component(
                "speex", "Speex", "Speex voice codec", "https://www.speex.org/",
                "BSD-3-Clause", "speex-COPYING", "https://www.speex.org/docs/manual/speex-manual/node15.html"
            ),
            component(
                "silk", "Skype SILK SDK", "SILK voice decoding", "https://github.com/kn007/silk-v3-decoder",
                "Skype SDK License", "LICENSE",
                "https://github.com/kn007/silk-v3-decoder/blob/507be6bca8ce1fb977a061481f1d79e8c610e309/silk/interface/SKP_Silk_SDK_API.h"
            ),
            component(
                "pkgconf", "pkgconf", "Build tool only", "https://github.com/pkgconf/pkgconf",
                "ISC", "pkgconf-COPYING", "https://github.com/pkgconf/pkgconf/blob/pkgconf-3.0.5/COPYING"
            ),
        ] + markdownComponents
    }

    private static var markdownComponents: [Self] {
        let components = [
            ("MarkdownView", "Native Markdown rendering", "Innei/MarkdownView", "MIT", "LICENSE"),
            ("Litext", "Native text layout and selection", "Lakr233/Litext", "MIT", "LICENSE"),
            ("Highlightr", "Code syntax highlighting", "raspu/Highlightr", "MIT", "LICENSE"),
            ("highlight.js", "Syntax highlighting engine", "highlightjs/highlight.js", "BSD-3-Clause", "LICENSE"),
            ("SwiftMath", "Math typesetting", "mgriebling/SwiftMath", "MIT", "LICENSE"),
            ("swift-cmark", "Markdown parsing", "swiftlang/swift-cmark", "BSD-2-Clause and bundled notices", "COPYING"),
            (
                "swift-collections", "Collection data structures", "apple/swift-collections",
                "Apache-2.0 with Swift exception", "LICENSE.txt"
            ),
            ("LRUCache", "Rendering cache", "nicklockwood/LRUCache", "MIT", "LICENSE.md"),
        ]
        return components.map { name, purpose, repository, license, filename in
            let homepage = URL(string: "https://github.com/" + repository)!
            let website = homepage.appendingPathComponent("blob/HEAD/" + filename)
            return Self(
                id: name, name: name, version: nil, purpose: purpose, homepage: homepage, license: license,
                licenseURL: Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Licenses")
                    ?? website,
                licenseWebsite: website
            )
        }
    }
}

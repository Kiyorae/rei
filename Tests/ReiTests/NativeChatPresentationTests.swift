import AppKit
import Litext
import QuartzCore
import ReiCore
import Testing

@testable import ReiLogging
@testable import ReiUI

@Suite("Native Chat Presentation", .serialized)
@MainActor
struct NativeChatPresentationTests {
    @Test("Code blocks use the available reading width while short messages remain compact")
    func richMessageWidth() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let controller = fixture.transcript()
        let window = window(for: controller, size: NSSize(width: 600, height: 600))
        defer { close(window) }
        var rich = fixture.message(0)
        rich.content = [.text("Code\n\n```swift\nlet message = \"Hello, Rei\"\nprint(message)\n```")]
        controller.update(messages: [rich, fixture.message(1)], isLoading: false, reduceMotion: true, reveal: nil)
        try await settle(controller.view)
        let labels = descendants(MarkdownMessageView.self, in: controller.view)
        let code = try #require(labels.first { $0.source.hasPrefix("Code") })
        let short = try #require(labels.first { $0.source.hasPrefix("Message") })
        #expect(code.bounds.width > 300)
        #expect(short.bounds.width < 200)
    }

    @Test("Forwarded messages release expanded row height when collapsed and after cell reuse")
    func forwardedRowHeight() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let controller = fixture.transcript()
        let window = window(for: controller, size: NSSize(width: 600, height: 700))
        defer { close(window) }
        var message = fixture.message(0)
        let nodes = (0..<5).map { index in
            MessageSegment.ForwardNode(
                senderID: "author", senderName: "Author", time: .now,
                content: [
                    .text(
                        "Forward \(index)\n\n"
                            + String(repeating: "A paragraph in the forwarded message.\n\n", count: 4))
                ])
        }
        message.content = [.forward(id: "bundle", nodes: nodes)]
        controller.update(messages: [message], isLoading: false, reduceMotion: true, reveal: nil)
        try await settle(controller.view)
        let initial = controller.tableView.rect(ofRow: 0).height
        #expect(initial < 150)
        let forward = try #require(descendant(ForwardMessagesView.self, in: controller.view))
        let toggle = try #require(forward.arrangedSubviews.first as? NSButton)
        try activate(toggle)
        try await settle(controller.view)
        #expect(controller.tableView.rect(ofRow: 0).height > initial + 200)
        try activate(toggle)
        try await settle(controller.view)
        #expect(abs(controller.tableView.rect(ofRow: 0).height - initial) < 2)
        var replacement = fixture.message(1)
        replacement.content = message.content
        controller.update(messages: [replacement], isLoading: false, reduceMotion: true, reveal: nil)
        try await settle(controller.view)
        #expect(controller.tableView.rect(ofRow: 0).height < 150)
    }

    @Test("Audio and video messages keep compact rows at narrow and wide transcript widths")
    func compactMediaRows() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        var voice = fixture.message(0)
        voice.content = [
            .record(Asset(id: "voice", name: "Voice.silk", mimeType: "audio/silk", source: .inline), duration: 5)
        ]
        var video = fixture.message(1)
        video.content = [.video(Asset(id: "video", name: "Clip.mp4", mimeType: "video/mp4", source: .inline))]
        for width in [440.0, 760.0] {
            let controller = fixture.transcript()
            let window = window(for: controller, size: NSSize(width: width, height: 500))
            defer { close(window) }
            controller.update(messages: [voice, video], isLoading: false, reduceMotion: true, reveal: nil)
            try await settle(controller.view)
            for row in 0..<2 {
                let height = controller.tableView.rect(ofRow: row).height
                #expect(height > 50)
                #expect(height < 110, "Media controls must not reserve space for an empty status row")
            }
        }
    }

    @Test("Composer and forwarded references remain readable without a navigation action")
    func passiveMessageQuotes() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        var reference = fixture.message(0)
        let text = "A quoted message stays readable while writing a reply. 中文 🌿"
        reference.content = [.text(text)]
        try await fixture.environment.store.save(reference)
        let session = ComposerSession(key: ComposerDraftKey(chat: fixture.chat, senderID: "author"))
        session.draft.replyTo = reference.id
        let composer = ComposerViewController(environment: fixture.environment, session: session)
        let composerWindow = window(for: composer, size: NSSize(width: 480, height: 220))
        defer { close(composerWindow) }
        let node = MessageSegment.ForwardNode(
            id: reference.id, senderID: "author", senderName: "Forwarded Author", content: reference.content)
        let forwarded = MessageQuoteView(
            id: reference.id, environment: fixture.environment, chat: fixture.chat, reveal: nil,
            context: .forwarded([node]))
        let forwardedController = NSViewController()
        forwardedController.view = forwarded
        let forwardedWindow = window(for: forwardedController, size: NSSize(width: 380, height: 100))
        defer { close(forwardedWindow) }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            composerWindow.appearance = NSAppearance(named: appearance)
            forwardedWindow.appearance = NSAppearance(named: appearance)
            try await settle(composer.view)
            forwarded.layoutSubtreeIfNeeded()
            let composerQuote = try #require(descendants(MessageQuoteView.self, in: composer.view).first)
            for quote in [composerQuote, forwarded] {
                let preview = try #require(descendants(NSTextField.self, in: quote).first { $0.stringValue == text })
                #expect(preview.isEnabled, "A noninteractive reference must not dim its text as a disabled control")
                #expect(preview.bounds.width > 200)
                #expect(preview.bounds.height > 10)
                #expect(descendants(NSButton.self, in: quote).allSatisfy { $0.isHidden })
                #expect(quote.gestureRecognizers.allSatisfy { !$0.isEnabled })
            }
            let name = appearance == .aqua ? "light" : "dark"
            try snapshot(composer.view, name: "quote-composer-\(name)")
            try snapshot(forwarded, name: "quote-forwarded-\(name)")
        }
    }

    @Test("Quoted messages preserve navigation and resize when their referenced content changes")
    func messageQuoteNavigationAndUpdates() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        var reference = fixture.message(0)
        reference.content = [.text("Short quote")]
        try await fixture.environment.store.save(reference)
        var revealed: [Message.ID] = []
        let controller = TranscriptController(
            environment: fixture.environment, chat: fixture.chat, showcase: nil, reply: { _ in },
            reveal: { revealed.append($0) })
        let window = window(for: controller, size: NSSize(width: 600, height: 500))
        defer { close(window) }
        var outgoing = fixture.message(1)
        outgoing.content = [.reply(messageID: reference.id), .text("An outgoing reply")]
        var incoming = fixture.message(2)
        incoming.senderID = "bot"
        incoming.direction = .incoming
        incoming.content = [.reply(messageID: reference.id), .text("An incoming reply")]
        controller.update(messages: [outgoing, incoming], isLoading: false, reduceMotion: true, reveal: nil)
        try await settle(controller.view)
        let quote = try #require(descendants(MessageQuoteView.self, in: controller.view).first)
        let jump = try #require(descendants(NSButton.self, in: quote).first { !$0.isHidden })
        try activate(jump)
        #expect(revealed == [reference.id])
        #expect(quote.gestureRecognizers.contains { $0 is NSClickGestureRecognizer && $0.isEnabled })
        let previousHeight = controller.tableView.rect(ofRow: 0).height
        let text = Array(repeating: "The referenced message now has more context to read.", count: 4).joined(
            separator: " ")
        reference.content = [.text(text)]
        try await fixture.environment.store.save(reference)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline,
            !descendants(NSTextField.self, in: controller.view).contains(where: { $0.stringValue == text })
        {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await settle(controller.view)
        #expect(controller.tableView.rect(ofRow: 0).height > previousHeight)
        let updatedRow = try #require(controller.tableView.view(atColumn: 0, row: 0, makeIfNecessary: true))
        let updatedQuote = try #require(descendants(MessageQuoteView.self, in: updatedRow).first)
        #expect(updatedQuote.bounds.width > 300)
        #expect(updatedRow.bounds.contains(updatedQuote.convert(updatedQuote.bounds, to: updatedRow)))
        #expect(descendants(NSTextField.self, in: updatedRow).contains { $0.stringValue == text })
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            try await settle(controller.view)
            try snapshot(controller.view, name: "quote-bubbles-\(appearance == .aqua ? "light" : "dark")")
        }
    }

    @Test("Native transcript follows arrivals and preserves the reading anchor across updates")
    func transcriptNavigation() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let controller = fixture.transcript()
        let window = window(for: controller, size: NSSize(width: 680, height: 420))
        defer { close(window) }
        var messages = (0..<40).map(fixture.message)
        controller.update(messages: messages, isLoading: false, reduceMotion: true, reveal: nil)
        try await settle(controller.view)
        #expect(controller.tableView.numberOfRows == 40)
        #expect(controller.followsLatest)
        let scroll = controller.scrollView
        let document = try #require(scroll.documentView)
        #expect(abs(scroll.documentVisibleRect.maxY - document.bounds.height) < 2)
        #expect(document.bounds.height > scroll.contentSize.height * 2)

        scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: 160))
        scroll.onUserScroll?()
        #expect(!controller.followsLatest)
        let anchor = try anchor(in: controller)
        messages.append(fixture.message(40))
        controller.update(messages: messages, isLoading: false, reduceMotion: true, reveal: nil)
        try await settle(controller.view)
        #expect(controller.hasNewMessages)
        let afterAppend = try self.anchor(in: controller)
        #expect(afterAppend.id == anchor.id)
        #expect(abs(afterAppend.offset - anchor.offset) < 2)

        let originalHeight = controller.tableView.rect(ofRow: 0).height
        messages[0].content = [
            .text(String(repeating: "A longer paragraph above the reading position.\n\n", count: 12))
        ]
        controller.update(messages: messages, isLoading: false, reduceMotion: true, reveal: nil)
        try await settle(controller.view)
        let afterResize = try self.anchor(in: controller)
        #expect(afterResize.id == anchor.id)
        #expect(abs(afterResize.offset - anchor.offset) < 2)

        // Offscreen rows use AppKit's estimated height. Revealing the changed
        // row must realize its new content and replace that estimate.
        controller.update(
            messages: messages, isLoading: false, reduceMotion: true,
            reveal: MessageReveal(chat: fixture.chat, messageID: messages[0].id))
        try await settle(controller.view)
        #expect(controller.tableView.rect(ofRow: 0).height > originalHeight + 120)

        controller.jumpToLatest()
        #expect(controller.followsLatest)
        #expect(!controller.hasNewMessages)
        #expect(abs(scroll.documentVisibleRect.maxY - document.bounds.height) < 2)

        let request = MessageReveal(chat: fixture.chat, messageID: messages[10].id)
        controller.update(messages: messages, isLoading: false, reduceMotion: true, reveal: request)
        try await settle(controller.view)
        let target = document.convert(controller.tableView.rect(ofRow: 10), from: controller.tableView)
        #expect(scroll.documentVisibleRect.intersects(target))
        #expect(!controller.followsLatest)

        controller.update(messages: [], isLoading: false, reduceMotion: true, reveal: nil)
        try await settle(controller.view)
        #expect(controller.tableView.numberOfRows == 0)
        #expect(controller.followsLatest)
        #expect(!controller.hasNewMessages)
    }

    @Test("The composer floats over the transcript while expanded drafts keep the latest message visible")
    func floatingComposer() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let environment = fixture.environment
        try await environment.store.save(Group(id: fixture.chat.peerID, name: "Test Group"))
        for index in 0..<40 { try await environment.store.save(fixture.message(index)) }
        environment.selectChat(fixture.chat)
        for _ in 0..<100 where environment.messages.count != 40 {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(environment.messages.count == 40)
        let controller = ConversationViewController(environment: environment, showcase: nil)
        let window = window(for: controller, size: NSSize(width: 680, height: 700))
        defer { close(window) }
        try await settle(controller.view)
        let transcript = try #require(controller.children.compactMap { $0 as? TranscriptController }.first)
        let composer = try #require(controller.children.compactMap { $0 as? ComposerViewController }.first)
        let scroll = transcript.scrollView

        func composerFrame() -> NSRect {
            composer.view.convert(composer.view.bounds, to: controller.view)
        }
        func viewportFrame() -> NSRect {
            scroll.contentView.convert(scroll.contentView.bounds, to: controller.view)
        }
        func latestMessageFrame() -> NSRect {
            transcript.tableView.convert(
                transcript.tableView.rect(ofRow: transcript.tableView.numberOfRows - 1), to: controller.view)
        }

        let initialComposer = composerFrame()
        let initialViewport = viewportFrame()
        #expect(initialViewport.contains(initialComposer), "The transcript must continue behind the entire composer")
        #expect(abs(initialViewport.minY - controller.view.safeAreaRect.minY) < 1)
        #expect(latestMessageFrame().minY >= initialComposer.maxY)
        #expect(latestMessageFrame().maxY <= initialViewport.maxY)
        #expect(transcript.followsLatest)

        composer.editor.string = Array(repeating: "A line in the expanded draft.", count: 12).joined(separator: "\n")
        composer.textDidChange(Notification(name: NSText.didChangeNotification, object: composer.editor))
        try await settle(controller.view)
        let expandedComposer = composerFrame()
        #expect(expandedComposer.height > initialComposer.height + 70)
        #expect(abs(viewportFrame().height - initialViewport.height) < 1)
        #expect(latestMessageFrame().minY >= expandedComposer.maxY)
        #expect(latestMessageFrame().maxY <= viewportFrame().maxY)
        #expect(transcript.followsLatest)
        try snapshot(controller.view, name: "floating-composer-expanded")

        scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: 180))
        scroll.onUserScroll?()
        let coveredRows = transcript.tableView.rows(
            in: transcript.tableView.convert(composerFrame(), from: controller.view))
        #expect(coveredRows.length > 0, "Historical messages must be able to scroll beneath the floating composer")
        let readingAnchor = try anchor(in: transcript)
        composer.editor.string = "Short draft"
        composer.textDidChange(Notification(name: NSText.didChangeNotification, object: composer.editor))
        try await environment.store.save(fixture.message(40))
        for _ in 0..<100 where transcript.messages.count != 41 {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await settle(controller.view)
        let updatedAnchor = try anchor(in: transcript)
        #expect(updatedAnchor.id == readingAnchor.id)
        #expect(abs(updatedAnchor.offset - readingAnchor.offset) < 2)
        #expect(transcript.hasNewMessages)
        let latest = try #require(
            descendants(NSButton.self, in: transcript.view).first { $0.title == "Jump to Latest" })
        #expect(!latest.isHiddenOrHasHiddenAncestor)
        #expect(latest.convert(latest.bounds, to: controller.view).minY >= composerFrame().maxY)
        try activate(latest)
        for _ in 0..<100 where latestMessageFrame().minY < composerFrame().maxY {
            try await Task.sleep(for: .milliseconds(20))
            controller.view.layoutSubtreeIfNeeded()
        }
        #expect(transcript.followsLatest)
        #expect(!transcript.hasNewMessages)
        #expect(latestMessageFrame().minY >= composerFrame().maxY)

        transcript.update(
            messages: transcript.messages, isLoading: false, reduceMotion: true,
            reveal: MessageReveal(chat: fixture.chat, messageID: transcript.messages[10].id))
        try await settle(controller.view)
        let revealedFrame = transcript.tableView.convert(transcript.tableView.rect(ofRow: 10), to: controller.view)
        #expect(viewportFrame().contains(revealedFrame))
        #expect(revealedFrame.minY >= composerFrame().maxY, "Referenced messages must be revealed above the composer")
        #expect(!transcript.followsLatest)
    }

    @Test("A short conversation remains above the floating composer when a reply preview appears")
    func floatingComposerReply() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let environment = fixture.environment
        try await environment.store.save(Group(id: fixture.chat.peerID, name: "Test Group"))
        var message = fixture.message(0)
        message.content = [.text("A short conversation with a referenced message.")]
        try await environment.store.save(message)
        environment.selectChat(fixture.chat)
        for _ in 0..<100 where environment.messages.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        try #require(environment.messages.count == 1)
        let controller = ConversationViewController(environment: environment, showcase: nil)
        let window = window(for: controller, size: NSSize(width: 480, height: 460))
        defer { close(window) }
        try await settle(controller.view)
        let transcript = try #require(controller.children.compactMap { $0 as? TranscriptController }.first)
        let composer = try #require(controller.children.compactMap { $0 as? ComposerViewController }.first)
        let previousHeight = composer.view.bounds.height
        composer.session.draft.replyTo = message.id
        try await settle(controller.view)
        let quote = try #require(descendant(MessageQuoteView.self, in: composer.view))
        #expect(!quote.isHiddenOrHasHiddenAncestor)
        #expect(composer.view.bounds.height > previousHeight + 20)
        let viewport = transcript.scrollView.contentView
        let viewportFrame = viewport.convert(viewport.bounds, to: controller.view)
        let composerFrame = composer.view.convert(composer.view.bounds, to: controller.view)
        let rowFrame = transcript.tableView.convert(transcript.tableView.rect(ofRow: 0), to: controller.view)
        #expect(viewportFrame.contains(composerFrame))
        #expect(rowFrame.minY >= composerFrame.maxY)
        #expect(viewportFrame.contains(rowFrame))
        #expect(transcript.followsLatest)

        composer.editor.string = Array(repeating: "A line in the expanded reply.", count: 12).joined(separator: "\n")
        composer.textDidChange(Notification(name: NSText.didChangeNotification, object: composer.editor))
        window.setContentSize(NSSize(width: 480, height: 300))
        try await settle(controller.view)
        #expect(abs(controller.view.bounds.height - 300) < 1, "Expanded drafts must not resize their host window")
        let compactComposer = composer.view.convert(composer.view.bounds, to: controller.view)
        let compactViewport = viewport.convert(viewport.bounds, to: controller.view)
        #expect(compactViewport.contains(compactComposer))
        #expect(compactViewport.maxY - compactComposer.maxY >= 63)
        let editorScroll = try #require(composer.editor.enclosingScrollView)
        #expect(editorScroll.contentSize.height < 64, "Short panes scroll long drafts inside the editor")

        window.setContentSize(NSSize(width: 480, height: 460))
        composer.editor.string = ""
        composer.textDidChange(Notification(name: NSText.didChangeNotification, object: composer.editor))
        composer.session.draft.replyTo = nil
        try await settle(controller.view)
        #expect(abs(composer.view.bounds.height - previousHeight) < 1)
        #expect(
            transcript.tableView.convert(transcript.tableView.rect(ofRow: 0), to: controller.view).minY
                >= composer.view.convert(composer.view.bounds, to: controller.view).maxY)
    }

    @Test("Only new messages animate; historical loads and reduced motion remain still")
    func arrivalMotion() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let controller = fixture.transcript()
        let window = window(for: controller, size: NSSize(width: 680, height: 500))
        defer { close(window) }
        var messages = [fixture.message(0)]
        controller.update(messages: messages, isLoading: false, reduceMotion: false, reveal: nil)
        try await settle(controller.view)
        let initial = try #require(controller.tableView.rowView(atRow: 0, makeIfNecessary: true))
        #expect(initial.layer?.animation(forKey: "messageArrival") == nil)
        messages.append(fixture.message(1))
        controller.update(messages: messages, isLoading: false, reduceMotion: false, reveal: nil)
        let arrival = try #require(controller.tableView.rowView(atRow: 1, makeIfNecessary: true))
        #expect(arrival.layer?.animation(forKey: "messageArrival") != nil)
        messages.append(fixture.message(2))
        controller.update(messages: messages, isLoading: false, reduceMotion: true, reveal: nil)
        try await settle(controller.view)
        let reduced = try #require(controller.tableView.rowView(atRow: 2, makeIfNecessary: true))
        #expect(reduced.layer?.animation(forKey: "messageArrival") == nil)
    }

    @Test("Rapid snapshot replacement and relayout render the latest message identities")
    func replaceSnapshotsDuringLayout() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let controller = fixture.transcript()
        let window = window(for: controller, size: NSSize(width: 680, height: 420))
        defer { close(window) }
        for cycle in 0..<8 {
            for count in [32, 0, 1, 18, 3] {
                let messages = (0..<count).map { fixture.message(cycle * 100 + $0) }
                controller.update(messages: messages, isLoading: false, reduceMotion: false, reveal: nil)
                window.setContentSize(NSSize(width: cycle.isMultiple(of: 2) ? 540 : 780, height: 420))
                controller.view.layoutSubtreeIfNeeded()
            }
            try await settle(controller.view)
            #expect(controller.tableView.numberOfRows == 3)
            for row in 0..<3 {
                let cell = try #require(controller.tableView.view(atColumn: 0, row: row, makeIfNecessary: true))
                let markdown = try #require(descendant(MarkdownMessageView.self, in: cell))
                #expect(markdown.source == fixture.message(cycle * 100 + row).content.textPreview)
            }
        }
    }

    @Test("Markdown lays out native code, tables and selectable text in both appearances")
    func markdownLayout() async throws {
        let source = """
            # Native Markdown · 原生排版

            **Bold**, *emphasis*, ~~deleted~~, `inline code`, and [a link](https://example.com).

            - [x] Completed task
            - [ ] Open task

            > A quote with 中文 and emoji 🌿.

            Inline math: $a^2 + b^2 = c^2$.

            ```swift
            let greeting = "Hello, 世界"
            print(greeting)
            ```

            | Feature | Status |
            | --- | --- |
            | Markdown | Ready |
            | AppKit | Native |

            Final paragraph remains visible after all blocks.
            """
        for scheme in [NSAppearance.Name.aqua, .darkAqua] {
            for width in [260.0, 580.0] {
                let host = NSViewController()
                host.view = NSView()
                host.view.wantsLayer = true
                host.view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                NativeUI.embed(MarkdownMessageView(source: source), in: host.view, inset: 16)
                let window = window(for: host, size: NSSize(width: width, height: 900))
                window.appearance = NSAppearance(named: scheme)
                defer { close(window) }
                try await settle(host.view)
                let markdown = try #require(descendant(MarkdownMessageView.self, in: host.view))
                let text = markdown.textLabelView.attributedText.string
                #expect(text.contains("Native Markdown"))
                #expect(text.contains("Final paragraph"))
                #expect(!text.contains("**Bold**"))
                #expect(window.makeFirstResponder(markdown.textLabelView))
                let copy = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
                #expect(!markdown.validateUserInterfaceItem(copy))
                #expect(markdown.textLabelView.tryToPerform(#selector(NSText.selectAll(_:)), with: nil))
                #expect(markdown.textLabelView.selectionRange?.length == markdown.textLabelView.attributedText.length)
                #expect(markdown.validateUserInterfaceItem(copy))
                markdown.textLabelView.clearSelection()
                let code = try #require(
                    textLabels(in: markdown).first { $0.attributedText.string.contains("let greeting") })
                #expect(code.bounds.width > 100)
                #expect(code.bounds.height > 20)
                #expect(window.makeFirstResponder(code))
                #expect(code.tryToPerform(#selector(NSText.selectAll(_:)), with: nil))
                #expect(code.selectionRange?.length == code.attributedText.length)
                #expect(markdown.validateUserInterfaceItem(copy))
                code.clearSelection()
                let measured = markdown.boundingSize(for: width)
                #expect(measured.height > 200)
                #expect(measured.height < 900)
                #expect(abs(host.view.bounds.width - width) < 1)
                #expect(abs(markdown.bounds.width - (width - 32)) < 1)
                try snapshot(host.view, name: "markdown-\(Int(width))-\(scheme == .aqua ? "light" : "dark")")
            }
        }
        #expect(MarkdownMessageView.canOpen(URL(string: "https://example.com")!))
        #expect(!MarkdownMessageView.canOpen(URL(string: "file:///tmp/private")!))
        #expect(!MarkdownMessageView.canOpen(URL(string: "javascript:alert(1)")!))
    }

    @Test("Split panes retain their controllers through collapse and restoration")
    func splitPanes() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let controller = WorkspaceViewController(environment: fixture.environment, showcase: nil)
        let window = window(for: controller, size: NSSize(width: 1200, height: 700))
        defer { close(window) }
        try await settle(controller.view)
        #expect(controller.splitViewItems.count == 2)
        #expect(controller.workbench.splitViewItems.count == 2)
        #expect(controller.content.splitViewItems.count == 2)
        #expect(!controller.workbench.splitView.isVertical)
        #expect(controller.content.splitView.isVertical)
        let inspector = controller.inspector
        let events = controller.events
        controller.sidebarItem.isCollapsed = true
        controller.inspectorItem.isCollapsed = true
        controller.eventsItem.isCollapsed = true
        #expect(controller.sidebarItem.isCollapsed)
        #expect(controller.inspectorItem.isCollapsed)
        #expect(!controller.isEventsVisible)
        controller.sidebarItem.isCollapsed = false
        controller.inspectorItem.isCollapsed = false
        controller.eventsItem.isCollapsed = false
        try await settle(controller.view)
        #expect(!controller.sidebarItem.isCollapsed)
        #expect(!controller.inspectorItem.isCollapsed)
        #expect(controller.isEventsVisible)
        #expect(controller.inspector === inspector)
        #expect(controller.events === events)
        #expect(controller.conversation.view.bounds.width >= 400)
    }

    @Test("List content follows item identities when section rows move and disappear")
    func listSectionChanges() async throws {
        struct Row: Identifiable, Equatable {
            let id: String
            let title: String
        }
        let controller = ItemListController<Row> { NativeUI.label($0.title) }
        let window = window(for: controller, size: NSSize(width: 280, height: 500))
        defer { close(window) }
        let snapshots: [[Row]] = [
            [
                Row(id: "conversations", title: "Conversations"), Row(id: "group", title: "Group"),
                Row(id: "friend", title: "Direct"),
            ],
            [
                Row(id: "pinned", title: "Pinned"), Row(id: "group", title: "Group"),
                Row(id: "conversations", title: "Conversations"), Row(id: "friend", title: "Direct"),
            ],
            [
                Row(id: "pinned", title: "Pinned"), Row(id: "group", title: "Group updated"),
                Row(id: "friend", title: "Direct updated"),
            ],
        ]
        for snapshot in snapshots {
            controller.update(snapshot, selection: "friend")
            try await settle(controller.view)
        }
        let expected = try #require(snapshots.last)
        let table = controller.tableView
        #expect(table.numberOfRows == expected.count)
        for (index, row) in expected.enumerated() {
            let cell = try #require(table.view(atColumn: 0, row: index, makeIfNecessary: true))
            #expect(descendants(NSTextField.self, in: cell).map(\.stringValue) == [row.title])
        }
        #expect(table.selectedRow == 2)
    }

    @Test("Repeated list content updates preserve scrolling and do not reselect the conversation")
    func listContentRefresh() async throws {
        struct Row: Identifiable, Equatable {
            let id: String
            let title: String
        }
        let controller = ItemListController<Row> { NativeUI.label($0.title) }
        let window = window(for: controller, size: NSSize(width: 280, height: 320))
        defer { close(window) }
        var selectedIDs: [String?] = []
        controller.onSelect = { selectedIDs.append($0?.id) }
        let initial = (0..<60).map { Row(id: "row-\($0)", title: "Conversation \($0)") }
        controller.update(initial, selection: "row-12")
        let table = controller.tableView
        for _ in 0..<100 where table.numberOfRows != initial.count || table.selectedRow != 12 {
            try await Task.sleep(for: .milliseconds(20))
            controller.view.layoutSubtreeIfNeeded()
        }
        try #require(table.numberOfRows == initial.count)
        try #require(table.selectedRow == 12, "Initial selection is restored after the snapshot has finished")
        #expect(selectedIDs.isEmpty)
        let scroll = controller.scrollView
        scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: 480))
        scroll.reflectScrolledClipView(scroll.contentView)
        table.selectRowIndexes(IndexSet(integer: 13), byExtendingSelection: false)
        #expect(selectedIDs == ["row-13"])
        let origin = scroll.documentVisibleRect.origin
        #expect(origin.y > 0)
        for version in 1...3 {
            let updated = initial.map { Row(id: $0.id, title: $0.title + " · Update \(version)") }
            controller.update(updated, selection: "row-13")
            try await settle(controller.view)
            #expect(table.selectedRow == 13)
            #expect(selectedIDs == ["row-13"])
            #expect(abs(scroll.documentVisibleRect.minY - origin.y) < 1)
            let cell = try #require(table.view(atColumn: 0, row: 13, makeIfNecessary: true))
            #expect(descendants(NSTextField.self, in: cell).map(\.stringValue) == [updated[13].title])
        }
    }

    @Test("Native composer commits Markdown once and keeps failed and unrelated drafts")
    func composerDrafts() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let environment = fixture.environment
        try await environment.store.save(Group(id: fixture.chat.peerID, name: "Test Group"))
        for id in ["bot", "author"] {
            try await environment.store.save(
                GroupMember(groupID: fixture.chat.peerID, userID: id, role: id == "author" ? .owner : .member))
        }
        #expect(await environment.setBotUser("bot"))
        environment.setActiveUser("author")
        environment.selectChat(fixture.chat)
        let session = ComposerSession(key: ComposerDraftKey(chat: fixture.chat, senderID: "author"))
        let source = "## Markdown\n\n**Hello**, 世界 🌿\n\n```swift\nlet value = 42\n```"
        session.draft.text = source
        let controller = ComposerViewController(environment: environment, session: session)
        let window = window(for: controller, size: NSSize(width: 640, height: 200))
        defer { close(window) }
        let unrelated = ComposerSession(key: ComposerDraftKey(chat: fixture.chat, senderID: "bot"))
        unrelated.draft.text = "Keep the other persona's draft"
        controller.submit()
        controller.submit()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while session.draft.isSending, clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!session.draft.isSending)
        #expect(session.draft.isEmpty)
        let saved = try await environment.store.messages(in: fixture.chat)
        #expect(saved.count == 1)
        #expect(saved.first?.content == [.text(source)])
        #expect(unrelated.draft.text == "Keep the other persona's draft")

        let failed = ComposerSession(key: ComposerDraftKey(chat: fixture.chat, senderID: "missing-persona"))
        failed.draft.text = "Keep this failed message"
        let failingController = ComposerViewController(environment: environment, session: failed)
        failingController.loadViewIfNeeded()
        failingController.submit()
        let failureDeadline = clock.now.advanced(by: .seconds(3))
        while failed.draft.isSending, clock.now < failureDeadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!failed.draft.isSending)
        #expect(failed.draft.text == "Keep this failed message")
        #expect(try await environment.store.messages(in: fixture.chat).count == 1)
    }

    @Test("Native Return handling preserves IME composition and Shift-Return line breaks")
    func composerInput() throws {
        let controller = NSViewController()
        let editor = ComposerTextView()
        controller.view = editor
        let window = window(for: controller, size: NSSize(width: 400, height: 160))
        defer { close(window) }
        var submissions = 0
        editor.onSubmit = { submissions += 1 }
        func key(_ modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: "\r",
                    charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        }
        editor.setMarkedText(
            "拼", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.keyDown(with: try key())
        #expect(submissions == 0)
        editor.unmarkText()
        editor.keyDown(with: try key(.shift))
        #expect(editor.string.contains("\n"))
        #expect(submissions == 0)
        editor.keyDown(with: try key())
        #expect(submissions == 1)
    }

    @Test("Native settings fit both appearances, preserve drafts across sidebar pages, and validate before saving")
    func settingsDrafts() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let initialHost = fixture.environment.settings.host
        let initialPort = fixture.environment.settings.port
        let settings = SettingsWindowController(environment: fixture.environment, tab: .connection)
        let window = try #require(settings.window)
        settings.showWindow(nil)
        defer { settings.close() }
        let content = try #require(window.contentView)
        let split = try #require(window.contentViewController as? NSSplitViewController)
        let pages = try #require(
            descendants(NSTableView.self, in: content).first { $0.accessibilityLabel() == "Settings Pages" })
        #expect(pages.numberOfRows == 3)
        for size in [NSSize(width: 900, height: 680), NSSize(width: 780, height: 560)] {
            window.setFrame(NSRect(origin: window.frame.origin, size: size), display: true)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                for (index, name) in ["connection", "personas", "about"].enumerated() {
                    pages.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                    try await settle(content)
                    #expect(pages.selectedRow == index)
                    let detail = split.splitViewItems[1].viewController.view
                    let scroll = try #require(descendants(NSScrollView.self, in: detail).first)
                    #expect(scroll.bounds.height > 200, "Settings retain a usable scrolling area at minimum size")
                    #expect(abs(scroll.documentVisibleRect.minY) < 1, "Each settings page begins at its first section")
                    let action = try #require(
                        descendants(ActionButton.self, in: detail).first { $0.title == (index == 2 ? "Done" : "Save") })
                    #expect(content.bounds.contains(action.convert(action.bounds, to: content)))
                    for button in descendants(ActionButton.self, in: detail) {
                        #expect(
                            button.alignmentRect(forFrame: button.bounds).width <= button.intrinsicContentSize.width
                                + 1,
                            "Settings actions retain their natural width: \(button.title)")
                    }
                    for choice in descendants(NSPopUpButton.self, in: detail) {
                        #expect(choice.bounds.width <= 280)
                        #expect(
                            choice.alignmentRect(forFrame: choice.bounds).width <= choice.intrinsicContentSize.width + 1
                        )
                    }
                    try snapshot(
                        content,
                        name: "settings-\(name)-\(Int(size.width))-\(appearance == .aqua ? "light" : "dark")")
                }
            }
        }
        pages.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        #expect(descendants(NSTextField.self, in: content).allSatisfy { $0.placeholderString != "Host" })
        pages.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let fields = descendants(NSTextField.self, in: content)
        let host = try #require(fields.first { $0.placeholderString == "Host" })
        let port = try #require(fields.first { $0.placeholderString == "Port" })
        host.stringValue = "192.0.2.10"
        port.stringValue = "0"
        pages.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        pages.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        #expect(
            descendants(NSTextField.self, in: content).first { $0.placeholderString == "Host" }?.stringValue
                == "192.0.2.10")
        let save = try #require(descendants(ActionButton.self, in: content).first { $0.title == "Save" })
        try activate(save)
        #expect(fixture.environment.settings.host == initialHost)
        #expect(fixture.environment.settings.port == initialPort)
        #expect(window.isVisible)
        settings.select(.about)
        #expect(pages.selectedRow == 2)
        let done = try #require(descendants(ActionButton.self, in: content).first { $0.title == "Done" })
        try activate(done)
        #expect(!window.isVisible)
        #expect(fixture.environment.settings.host == initialHost)

        let validSettings = SettingsWindowController(environment: fixture.environment, tab: .connection)
        validSettings.showWindow(nil)
        defer { validSettings.close() }
        let validContent = try #require(validSettings.window?.contentView)
        let validFields = descendants(NSTextField.self, in: validContent)
        try #require(validFields.first { $0.placeholderString == "Port" }).stringValue = "6701"
        try activate(#require(descendants(ActionButton.self, in: validContent).first { $0.title == "Save" }))
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while validSettings.window?.isVisible == true, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fixture.environment.settings.port == 6701)
        #expect(validSettings.window?.isVisible == false)
    }

    @Test("About preserves the five-click logo spin and resets it when leaving the page")
    func aboutLogoSpin() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let settings = SettingsWindowController(environment: fixture.environment, tab: .about)
        settings.showWindow(nil)
        defer { settings.close() }
        let content = try #require(settings.window?.contentView)
        try await settle(content)
        let logo = try #require(descendants(NSButton.self, in: content).first { $0.accessibilityLabel() == "Rei Logo" })
        let artwork = try #require(logo.layer?.sublayers?.first { $0.name == "logoArtwork" })
        let frame = logo.frame
        #expect(artwork.contents != nil)
        #expect(artwork.anchorPoint == NSPoint(x: 0.5, y: 0.5))
        #expect(artwork.position == NSPoint(x: logo.bounds.midX, y: logo.bounds.midY))
        for _ in 0..<4 {
            try activate(logo)
            #expect(artwork.animation(forKey: "logoSpin") == nil)
        }
        settings.select(.connection)
        settings.select(.about)
        try await settle(content)
        try activate(logo)
        #expect(artwork.animation(forKey: "logoSpin") == nil, "Leaving About resets the click count")
        for _ in 0..<4 { try activate(logo) }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            #expect(artwork.animation(forKey: "logoSpin") == nil)
            return
        }
        let spin = try #require(artwork.animation(forKey: "logoSpin") as? CAAnimationGroup)
        #expect(abs(spin.duration - 2.5) < 0.01)
        #expect(spin.isRemovedOnCompletion)
        let turns = try #require(spin.animations?.first as? CABasicAnimation)
        let finish = try #require(spin.animations?.last as? CASpringAnimation)
        #expect(abs((turns.toValue as? Double ?? 0) + Double.pi * 4) < 0.01)
        #expect(abs((finish.toValue as? Double ?? 0) + Double.pi * 6) < 0.01)
        #expect(finish.beginTime == turns.duration)
        for _ in 0..<5 { try activate(logo) }
        // Simulate Core Animation removing the completed group so the next
        // interaction cycle does not depend on render-server timing or occlusion.
        artwork.removeAnimation(forKey: "logoSpin")
        #expect(artwork.animation(forKey: "logoSpin") == nil)
        #expect(CATransform3DIsIdentity(artwork.transform))
        #expect(logo.frame == frame)
        for _ in 0..<4 { try activate(logo) }
        #expect(artwork.animation(forKey: "logoSpin") == nil, "Clicks during the spin must not queue another spin")
        try activate(logo)
        #expect(artwork.animation(forKey: "logoSpin") != nil)
        settings.select(.connection)
        #expect(artwork.animation(forKey: "logoSpin") == nil)
        settings.select(.about)
        for _ in 0..<5 { try activate(logo) }
        #expect(artwork.animation(forKey: "logoSpin") != nil)
        settings.close()
        #expect(artwork.animation(forKey: "logoSpin") == nil)
    }

    private func anchor(in controller: TranscriptController) throws -> (id: Message.ID, offset: CGFloat) {
        let table = controller.tableView
        let scroll = controller.scrollView
        let document = try #require(scroll.documentView)
        let rows = table.rows(in: table.convert(scroll.documentVisibleRect, from: document))
        let row = try #require(controller.messages.indices.contains(rows.location) ? rows.location : nil)
        return (
            controller.messages[row].id,
            document.convert(table.rect(ofRow: row), from: table).minY - scroll.documentVisibleRect.minY
        )
    }

    private func window(for controller: NSViewController, size: NSSize) -> NSWindow {
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.setContentSize(size)
        window.orderBack(nil)
        return window
    }

    private func close(_ window: NSWindow) {
        window.contentView = nil
        window.close()
    }

    private func settle(_ view: NSView) async throws {
        try await Task.sleep(for: .milliseconds(200))
        view.layoutSubtreeIfNeeded()
    }

    private func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews {
            if let match = descendant(type, in: child) { return match }
        }
        return nil
    }

    private func snapshot(_ view: NSView, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["REI_WORKSPACE_PREVIEW_DIRECTORY"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try nativeViewSnapshot(view).write(
            to: directory.appendingPathComponent(name + ".png"))
    }

    private func textLabels(in view: NSView) -> [TextLabelView] {
        (view as? TextLabelView).map { [$0] } ?? view.subviews.flatMap { textLabels(in: $0) }
    }

    private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
    }

    @MainActor
    private struct Fixture {
        let directory: URL
        let defaults: UserDefaults
        let defaultsName: String
        let environment: AppEnvironment
        let chat = Chat(scene: .group, peerID: "group", selfID: "bot")

        init() async throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "Rei-NativeChat-\(UUID().uuidString)")
            defaultsName = "dev.rei.tests.native-chat.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: defaultsName))
            let store = try ReiStore()
            try await store.save(User(id: "bot", name: "Bot"))
            try await store.save(User(id: "author", name: "Author"))
            environment = AppEnvironment(
                store: store, assetStore: try AssetStore(directory: directory.appendingPathComponent("assets")),
                appLog: AppLog(directory: directory.appendingPathComponent("logs"), emitUnifiedLog: false),
                defaults: defaults
            )
            environment.setActiveUser("author")
        }

        func message(_ index: Int) -> Message {
            Message(
                id: "message-\(index)", seq: Int64(index), scene: chat.scene, peerID: chat.peerID, senderID: "author",
                selfID: chat.selfID, content: [.text("Message **\(index)** · 中文 🌿")], direction: .outgoing)
        }

        func transcript() -> TranscriptController {
            TranscriptController(environment: environment, chat: chat, showcase: nil, reply: { _ in }, reveal: { _ in })
        }

        func remove() {
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

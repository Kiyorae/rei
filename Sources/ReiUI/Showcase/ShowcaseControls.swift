import SwiftUI

struct ShowcaseControls: View {
    @Bindable var session: ShowcaseSession

    var body: some View {
        Menu {
            Text(session.isPlaying ? "Demo Playing · Every 4 Seconds" : "Demo Paused")
            if let error = session.errorMessage {
                Text(error)
            } else if !session.isPrepared {
                Text("Preparing Demo…")
            }
            Button(
                session.isPlaying ? "Pause Demo" : "Resume Demo",
                systemImage: session.isPlaying ? "pause.fill" : "play.fill"
            ) {
                if !session.isPlaying { session.resumeFollowing() }
                session.isPlaying.toggle()
            }
            .disabled(!session.isPrepared || session.errorMessage != nil)
            Toggle("Auto-follow", isOn: $session.isFollowing)
            Divider()
            Text("Local Milky Client · Live API RTT")
            if let error = session.connection.errorMessage { Text(error) }
        } label: {
            Label("Demo", systemImage: session.isPlaying ? "play.circle" : "pause.circle")
                .labelStyle(.titleAndIcon)
        }
        .fixedSize()
        .help("Demo controls")
        .onChange(of: session.isFollowing) { _, following in
            if following { session.resumeFollowing() } else { session.isPlaying = false }
        }
    }
}

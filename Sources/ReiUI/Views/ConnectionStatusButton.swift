import ReiProtocol
import SwiftUI

/// Connect/disconnect control that also exposes the current session state.
struct ConnectionStatusButton: View {
    let environment: AppEnvironment

    var body: some View {
        Button {
            Task {
                if environment.sessionState.isActive {
                    await environment.disconnect()
                } else {
                    await environment.connect()
                }
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(indicatorColor)
                    .frame(width: 7, height: 7)
                Text(protocolChoice.shortDisplayName)
                    .font(.callout)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(statusText)
                    .font(.callout)
                    .monospacedDigit()
            }
        }
        .accessibilityLabel("\(protocolChoice.shortDisplayName), \(statusText)")
        .accessibilityHint(environment.sessionState.isActive ? "Disconnect" : "Connect")
        .help(helpText)
    }

    private var indicatorColor: Color {
        switch environment.sessionState {
        case .connected where environment.roundTripTimeState == .timedOut:
            return .orange
        case .connected:
            return .green
        case .ready:
            return .green
        case .listening, .connecting: return .orange
        case .failed: return .red
        case .idle: return .secondary
        }
    }

    private var protocolChoice: ProtocolChoice {
        environment.activeProtocolChoice ?? environment.selectedProtocol
    }

    private var transportMode: TransportMode {
        environment.activeTransportMode ?? environment.settings.transport
    }

    private var statusText: String {
        switch environment.sessionState {
        case .idle:
            return "Not Connected"
        case .listening(let port):
            return "Listening on :\(port)"
        case .ready(let port):
            return "Serving on :\(port)"
        case .connecting:
            return "Connecting"
        case .failed:
            return "Connection Failed"
        case .connected:
            guard supportsRoundTripTime else {
                return "Serving"
            }
            switch environment.roundTripTimeState {
            case .measured(let duration): return durationLabel(duration)
            case .timedOut: return "Ping Timed Out"
            case .measuring, .unavailable: return "Measuring"
            case .unsupported: return "RTT —"
            }
        }
    }

    private var helpText: String {
        var components = [
            protocolChoice.displayName,
            transportMode.displayName,
            environment.sessionState.displayName,
        ]

        if case .measured(let duration) = environment.roundTripTimeState,
            supportsRoundTripTime
        {
            components.append("RTT \(durationLabel(duration))")
        } else if !supportsRoundTripTime, environment.sessionState.isActive {
            components.append("Milky serves independent API and event endpoints without a single connection RTT")
        }

        components.append(environment.sessionState.isActive ? "Click to Disconnect (⇧⌘K)" : "Click to Connect (⇧⌘K)")
        return components.joined(separator: " · ")
    }

    private var supportsRoundTripTime: Bool {
        transportMode == .webSocketServer || transportMode == .webSocketClient
    }

    private func durationLabel(_ duration: Duration) -> String {
        let components = duration.components
        let milliseconds =
            Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
        guard milliseconds >= 1 else { return "<1 ms" }
        return "\(Int(milliseconds.rounded())) ms"
    }
}

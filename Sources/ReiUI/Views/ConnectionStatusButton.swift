import ReiProtocol
import SwiftUI

/// Connect/disconnect control that also exposes the current session state.
struct ConnectionStatusButton: View {
    let environment: AppEnvironment
    var showcaseConnection: ShowcaseConnection? = nil

    var body: some View {
        Button {
            Task {
                if let showcaseConnection {
                    await showcaseConnection.toggle()
                    return
                }
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
        .accessibilityHint(isActive ? "Disconnect" : "Connect")
        .help(helpText)
    }

    private var indicatorColor: Color {
        if let showcaseConnection {
            switch showcaseConnection.state {
            case .idle: return .secondary
            case .connecting: return .orange
            case .connected: return .green
            case .failed: return .red
            }
        }
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
        showcaseConnection == nil ? environment.activeProtocolChoice ?? environment.selectedProtocol : .milky
    }

    private var transportMode: TransportMode {
        environment.activeTransportMode ?? environment.settings.transport
    }

    private var statusText: String {
        if let showcaseConnection {
            switch showcaseConnection.state {
            case .idle: return "Not Connected"
            case .connecting: return "Connecting"
            case .failed: return "Connection Failed"
            case .connected:
                return showcaseConnection.roundTripTime.map { "API RTT \(durationLabel($0))" } ?? "Measuring"
            }
        }
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
        if let showcaseConnection {
            let state =
                switch showcaseConnection.state {
                case .idle: "Disconnected"
                case .connecting: "Connecting"
                case .connected: "Connected"
                case .failed: showcaseConnection.errorMessage ?? "Connection Failed"
                }
            let measurement = showcaseConnection.roundTripTime.map { "API RTT \(durationLabel($0))" } ?? "API RTT —"
            return
                "Local Milky demo client · \(state) · \(measurement) · Click to \(isActive ? "Disconnect" : "Connect")"
        }
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

    private var isActive: Bool { showcaseConnection?.isActive ?? environment.sessionState.isActive }

    private func durationLabel(_ duration: Duration) -> String {
        let components = duration.components
        let milliseconds =
            Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
        guard milliseconds >= 1 else { return "<1 ms" }
        return "\(Int(milliseconds.rounded())) ms"
    }
}

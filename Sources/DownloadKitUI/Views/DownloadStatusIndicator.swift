//
//  DownloadStatusIndicator.swift
//  DownloadKitUI
//

import SwiftUI
import DownloadKit

/// A compact visual of one item's state: a progress ring (or a spinner when the size is
/// unknown) with a symbol. Every state has its own symbol, so color is never the only cue.
///
/// It scales with Dynamic Type, mirrors its ring in right-to-left layouts and is one
/// accessibility element whose value is the full status (for example "Downloading, 42%").
@available(iOS 15, macOS 12, *)
public struct DownloadStatusIndicator: View {
    private let indicator: DownloadIndicator
    @ScaledMetric(relativeTo: .body) private var diameter: CGFloat = 28
    @Environment(\.downloadStrings) private var strings

    public init(_ indicator: DownloadIndicator) {
        self.indicator = indicator
    }

    public var body: some View {
        ZStack {
            ring
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: diameter * 0.42, weight: .semibold))
                    .foregroundColor(tint)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(strings.text(.indicatorLabel))
        .accessibilityValue(strings.status(indicator))
    }

    @ViewBuilder private var ring: some View {
        switch indicator {
        case .active(nil), .queued, .removing:
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
        case .active(let progress?), .paused(_, let progress?), .waiting(_, let progress?):
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.3), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .flipsForRightToLeftLayoutDirection(true)
            }
        case .paused, .waiting:
            Circle().stroke(Color.secondary.opacity(0.3), lineWidth: lineWidth)
        case .notDownloaded, .completed, .failed, .missing:
            EmptyView()
        }
    }

    private var lineWidth: CGFloat { max(2, diameter / 12) }

    private var symbol: String? {
        switch indicator {
        case .notDownloaded: return "arrow.down.circle"
        case .queued, .removing, .active(nil): return nil
        case .active: return "pause.fill"
        case .waiting: return "hourglass"
        case .paused: return "arrow.down"
        case .failed: return "exclamationmark.triangle.fill"
        case .completed: return "checkmark.circle.fill"
        case .missing: return "questionmark.circle"
        }
    }

    private var tint: Color {
        switch indicator {
        case .failed: return .red
        case .completed: return .green
        case .waiting, .paused, .missing: return .secondary
        default: return .accentColor
        }
    }
}

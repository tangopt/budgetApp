// App/Dashboard/DashboardCard.swift
import SwiftUI

/// A Dashboard card: a `Panel` with an optional "Name ›" link, stretching to its row
/// partner's height (`TwoUpRow`); in the dashboard's scroll view it otherwise takes just its
/// own height.
struct DashboardCard<Content: View>: View {
    let title: String
    var linkTitle: String? = nil
    var onLink: (() -> Void)? = nil
    @ViewBuilder let content: Content

    var body: some View {
        Panel(title, fillsHeight: true) {
            if let linkTitle, let onLink {
                PanelLink(title: linkTitle, action: onLink)
            }
        } content: {
            content
        }
    }
}

/// A thin progress meter, optionally with a marker at "how far through the month we are"
/// (`pace` nil draws no marker).
struct PaceMeter: View {
    let fraction: Double
    let pace: Double?
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(nsColor: .separatorColor).opacity(0.5))
                Capsule().fill(tint).frame(width: proxy.size.width * min(max(fraction, 0), 1))
                if let pace {
                    Rectangle().fill(Color.primary.opacity(0.6)).frame(width: 2)
                        .offset(x: proxy.size.width * min(max(pace, 0), 1) - 1)
                }
            }
        }
        .frame(height: 6)
    }
}

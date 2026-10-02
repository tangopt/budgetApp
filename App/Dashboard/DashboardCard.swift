// App/Dashboard/DashboardCard.swift
import SwiftUI

struct DashboardCard<Content: View>: View {
    let title: String
    var linkTitle: String? = nil
    var onLink: (() -> Void)? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                if let linkTitle, let onLink {
                    Button("\(linkTitle) ›", action: onLink)
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

/// A thin progress meter with a marker at "how far through the month we are".
struct PaceMeter: View {
    let fraction: Double
    let pace: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(nsColor: .separatorColor).opacity(0.5))
                Capsule().fill(tint).frame(width: proxy.size.width * min(max(fraction, 0), 1))
                Rectangle().fill(Color.primary.opacity(0.6)).frame(width: 2)
                    .offset(x: proxy.size.width * min(max(pace, 0), 1) - 1)
            }
        }
        .frame(height: 6)
    }
}

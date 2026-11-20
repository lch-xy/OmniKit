//
//  SettingsUI.swift
//  OmniKit
//

import SwiftUI

enum OmniKitTheme {
    static let background = Color.white
    static let sidebar = Color.white
    static let surface = Color.white
    static let input = Color.white
    static let accent = Color.blue
    static let blue = Color(red: 0.2, green: 0.42, blue: 0.86)
    static let text = Color(red: 0.12, green: 0.12, blue: 0.13)
    static let secondary = Color(red: 0.45, green: 0.45, blue: 0.47)
    static let border = Color(red: 0.88, green: 0.88, blue: 0.89)
}

struct OmniKitButtonStyle: ButtonStyle {
    var prominent = false
    var tint: Color = OmniKitTheme.accent
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .foregroundStyle(prominent ? Color.white : OmniKitTheme.text)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(prominent ? tint : OmniKitTheme.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(prominent ? tint.opacity(0.6) : OmniKitTheme.border, lineWidth: 1)
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.4)
    }
}

struct SettingsCanvas<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                content
            }
            .frame(maxWidth: 800)
            .padding(.horizontal, 40)
            .padding(.vertical, 32)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct SettingsHeroCard<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let trailing: Trailing

    init(
        title: String,
        subtitle: String,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 24, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 20)
            trailing
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }
}

struct SettingsSection<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            
            VStack(spacing: 0) {
                content
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
            )
        }
    }
}

struct SettingsRow<Content: View>: View {
    let label: String
    let systemImage: String?
    let description: String?
    @ViewBuilder let content: Content

    init(
        _ label: String,
        systemImage: String? = nil,
        description: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.label = label
        self.systemImage = systemImage
        self.description = description
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: 13))
                    if let description {
                        Text(description)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                
                Spacer()
                
                content
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
        }
    }
}

struct SettingsDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 48)
            .opacity(0.5)
    }
}

struct SettingsInfoBadge: View {
    let text: String
    var tint: Color = .blue

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(tint.opacity(0.1))
            )
    }
}

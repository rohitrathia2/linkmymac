import SwiftUI
import AppKit

// LinkMyMac design system: tokens and shared components from the Figma redesign
// (file oQuyb8ht2Ewqcs6wIQBKKA, "LinkMyMac" variable collection, Light/Dark modes).

// MARK: - Colors

/// Figma color variables. Each resolves per appearance, like the variable's Light/Dark modes.
enum Theme {
    private static func color(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }

    static let canvas = color(0xF5F6FA, 0x0B0D17)          // bg/canvas
    static let sidebar = color(0xECEEF5, 0x11131F)         // bg/sidebar
    static let surface = color(0xFFFFFF, 0x171A2B)         // bg/surface
    static let surfaceMuted = color(0xF0F1F6, 0x20243A)    // bg/surface-muted
    static let borderSubtle = color(0xE3E6EE, 0x262B42)    // border/subtle
    static let borderStrong = color(0xC8CDDB, 0x3B4262)    // border/strong
    static let textPrimary = color(0x10131F, 0xF3F4FA)     // text/primary
    static let textSecondary = color(0x585E74, 0xA6ACC4)   // text/secondary
    static let textTertiary = color(0x8A90A6, 0x6F7593)    // text/tertiary
    static let brand = color(0x4F5BFF, 0x8F98FF)           // brand/primary
    static let onBrand = color(0xFFFFFF, 0x0B0D17)         // brand/on-primary
    static let brandSoft = color(0xDFE3FF, 0x232859)       // brand/soft
    static let onBrandSoft = color(0x3942D9, 0xC3C8FF)     // brand/on-soft
    static let success = color(0x0B7A3B, 0x3DDC84)         // success/fg
    static let successSoft = color(0xE1F5E9, 0x123222)     // success/soft
    static let warning = color(0x8F5400, 0xF6B84B)         // warning/fg
    static let warningSoft = color(0xFFF2D9, 0x3A2B0C)     // warning/soft
    static let danger = color(0xC21F2C, 0xFF6E76)          // danger/fg
    static let dangerSoft = color(0xFDE7E9, 0x3B1418)      // danger/soft

    /// Brand gradient (app icon, device hero, incoming call).
    static let gradient = LinearGradient(colors: [Color(red: 0.31, green: 0.36, blue: 1), Color(red: 0.55, green: 0.36, blue: 0.96)],
                                         startPoint: .leading, endPoint: .trailing)
    /// Call buttons: white on these passes contrast (the Figma Answer/Call green is #15803D).
    static let callGreen = Color(red: 0.08, green: 0.50, blue: 0.24)
    static let callRed = Color(red: 0.90, green: 0.28, blue: 0.30)
}

// MARK: - Type scale (Figma text styles Mac/*)

extension Font {
    static let lmLargeTitle = Font.system(size: 26, weight: .bold)      // tracking -0.4
    static let lmTitle = Font.system(size: 15, weight: .semibold)       // tracking -0.1
    static let lmHeadline = Font.system(size: 13, weight: .semibold)
    static let lmBody = Font.system(size: 13)
    static let lmCallout = Font.system(size: 12)
    static let lmCaption = Font.system(size: 11, weight: .medium)       // tracking 0.1
    static let lmSection = Font.system(size: 11, weight: .semibold)     // uppercase, tracking 0.6
    static let lmCode = Font.system(size: 26, weight: .semibold, design: .rounded)
    static let lmKeypad = Font.system(size: 24)
}

// MARK: - Surfaces

extension View {
    /// Card surface: white (or dark surface) fill, subtle border, continuous corners.
    func lmCard(padding: CGFloat = 16, radius: CGFloat = 14) -> some View {
        self.padding(padding)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.borderSubtle))
    }
}

/// Uppercase section label (Figma Mac/Section).
struct SectionLabel: View {
    let text: String
    var color: Color = Theme.textTertiary
    var body: some View {
        Text(text.uppercased()).font(.lmSection).tracking(0.6).foregroundStyle(color)
    }
}

/// Icon on a rounded tile (feature tiles, device badges, list rows).
struct IconTile: View {
    let symbol: String
    var size: CGFloat = 36
    var radius: CGFloat = 10
    var iconSize: CGFloat = 16
    var background: Color = Theme.brandSoft
    var foreground: Color = Theme.brand
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: iconSize, weight: .medium))
            .foregroundStyle(foreground)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(background))
    }
}

/// The LinkMyMac mark: brand gradient squircle with a link glyph (Figma Brand/App icon).
struct BrandMark: View {
    var size: CGFloat = 32
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.40, green: 0.45, blue: 1), Color(red: 0.55, green: 0.36, blue: 0.96)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(Image(systemName: "link").font(.system(size: size * 0.46, weight: .semibold)).foregroundStyle(.white))
            .frame(width: size, height: size)
    }
}

// MARK: - Controls

/// Push button, 32 pt (Figma Mac/Button Primary / Secondary).
struct LMButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive }
    var kind: Kind
    var fullWidth = false
    func makeBody(configuration: Configuration) -> some View {
        LMButtonBody(configuration: configuration, kind: kind, fullWidth: fullWidth)
    }
}

private struct LMButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: LMButtonStyle.Kind
    let fullWidth: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.lmHeadline)
            .lineLimit(1)
            .foregroundStyle(kind == .primary ? Theme.onBrand : kind == .destructive ? Theme.danger : Theme.textPrimary)
            .padding(.horizontal, 16)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(kind == .primary ? Theme.brand : Theme.surface))
            .overlay {
                if kind != .primary {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.borderStrong)
                }
            }
            .shadow(color: kind == .primary ? Theme.brand.opacity(0.28) : .clear, radius: 3, y: 2)
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

extension ButtonStyle where Self == LMButtonStyle {
    static var lmPrimary: LMButtonStyle { LMButtonStyle(kind: .primary) }
    static var lmSecondary: LMButtonStyle { LMButtonStyle(kind: .secondary) }
    static var lmDestructive: LMButtonStyle { LMButtonStyle(kind: .destructive) }
}

/// Borderless 28 pt icon button (Figma Mac/Icon button).
struct IconButton: View {
    let symbol: String
    let help: String
    var tint: Color = Theme.textSecondary
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Text field with a 1 pt border (Figma Mac/Text field).
struct LMTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(.lmBody)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.borderStrong))
    }
}

/// Filled search field (Figma Mac/Search field).
struct LMSearchField: View {
    let placeholder: String
    @Binding var text: String
    var width: CGFloat? = 200
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textTertiary)
            TextField(placeholder, text: $text).textFieldStyle(.plain).font(.lmBody)
        }
        .padding(.horizontal, 8)
        .frame(width: width, height: 28)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surfaceMuted))
    }
}

/// Connection status pill (Figma Mac/Status chip).
struct StatusChip: View {
    enum Tone { case brand, neutral, warning, success, danger }
    let tone: Tone
    let label: String
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(dot).frame(width: 8, height: 8)
            Text(label).font(.lmCaption).tracking(0.1).foregroundStyle(foreground).lineLimit(1)
        }
        .padding(.leading, 10).padding(.trailing, 12).padding(.vertical, 5)
        .background(Capsule().fill(background))
    }
    private var background: Color {
        switch tone {
        case .brand: Theme.brandSoft
        case .neutral: Theme.surfaceMuted
        case .warning: Theme.warningSoft
        case .success: Theme.successSoft
        case .danger: Theme.dangerSoft
        }
    }
    private var dot: Color {
        switch tone {
        case .brand: Theme.brand
        case .neutral: Theme.textTertiary
        case .warning: Theme.warning
        case .success: Theme.success
        case .danger: Theme.danger
        }
    }
    private var foreground: Color {
        switch tone {
        case .brand: Theme.onBrandSoft
        case .neutral: Theme.textSecondary
        case .warning: Theme.warning
        case .success: Theme.success
        case .danger: Theme.danger
        }
    }
}

// MARK: - Sidebar

/// Source-list row (Figma Mac/Sidebar item: Default / Selected / Disabled).
struct SidebarRow: View {
    let symbol: String
    let label: String
    var selected = false
    var disabled = false
    var badge: String? = nil
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(selected ? Theme.brand : disabled ? Theme.textTertiary : Theme.textSecondary)
                .frame(width: 18)
            Text(label)
                .font(selected ? .lmHeadline : .lmBody)
                .foregroundStyle(selected ? Theme.onBrandSoft : disabled ? Theme.textTertiary : Theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let badge {
                Text(badge)
                    .font(.lmCaption)
                    .foregroundStyle(selected ? Theme.onBrand : Theme.textSecondary)
                    .padding(.horizontal, 7).padding(.vertical, 1)
                    .background(Capsule().fill(selected ? Theme.brand : Theme.surfaceMuted))
            }
        }
        .padding(.leading, 10).padding(.trailing, 8)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Theme.brandSoft : .clear))
        .contentShape(Rectangle())
    }
}

// MARK: - Content building blocks

/// Overview shortcut to one phone feature (Figma Mac/Feature tile).
struct FeatureTile: View {
    let symbol: String
    let title: String
    let detail: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                IconTile(symbol: symbol)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.lmHeadline).foregroundStyle(Theme.textPrimary)
                    Text(detail).font(.lmCallout).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .lmCard(padding: 16, radius: 14)
            .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
        }
        .buttonStyle(.plain)
    }
}

/// One character of the pairing code (Figma Mac/Code cell: Empty / Active / Filled).
struct CodeCell: View {
    enum Phase { case empty, active, filled }
    let character: Character?
    let phase: Phase
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(phase == .empty ? Theme.surfaceMuted : Theme.surface)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(phase == .active ? Theme.brand : phase == .filled ? Theme.borderStrong : Theme.borderSubtle,
                              lineWidth: phase == .active ? 2 : 1)
            if phase == .filled, let character {
                Text(String(character)).font(.lmCode).foregroundStyle(Theme.textPrimary)
            }
            if phase == .active {
                RoundedRectangle(cornerRadius: 1).fill(Theme.brand).frame(width: 2, height: 26)
            }
        }
        .frame(width: 52, height: 64)
        .shadow(color: phase == .active ? Theme.brand.opacity(0.22) : .clear, radius: 4)
    }
}

/// Group-by-folder section header with a collapse arrow (Figma Mac/Folder header).
struct FolderHeaderRow: View {
    let name: String
    let count: String
    var path: String? = nil
    let expanded: Bool
    let toggle: () -> Void
    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 14)
                Text(name).font(.lmTitle).tracking(-0.1).foregroundStyle(Theme.textPrimary)
                Text(count).font(.lmCallout).foregroundStyle(Theme.textTertiary)
                Spacer()
                if let path, !path.isEmpty {
                    Text(path).font(.lmCaption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
            }
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Label / value row used in details panels.
struct KeyValueRow: View {
    let key: String
    let value: String
    var body: some View {
        HStack {
            Text(key).font(.lmCallout).foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 12)
            Text(value).font(.lmBody).foregroundStyle(Theme.textPrimary).lineLimit(1)
        }
    }
}

/// A 1 pt hairline in the subtle border color.
struct Hairline: View {
    var body: some View { Rectangle().fill(Theme.borderSubtle).frame(height: 1) }
}

/// Empty-state block: icon, title, one line of help, optional action.
struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 10) {
            IconTile(symbol: symbol, size: 56, radius: 16, iconSize: 24)
            Text(title).font(.lmTitle).foregroundStyle(Theme.textPrimary)
            Text(message).font(.lmCallout).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 360)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.lmPrimary).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

import SwiftUI

enum InstallPhase {
    case idle, clearing, formatting, writingEFI, writingBoot, writingTable, syncing, done, failed

    static func parse(_ log: String, running: Bool) -> InstallPhase {
        if log.contains("=== FAILED") { return .failed }
        if log.contains("successfully finished") || log.contains("=== Done") {
            return running ? .syncing : .done
        }
        let markers: [(String, InstallPhase)] = [
            ("Clearing old partition data", .clearing),
            ("Formatting partition 1", .formatting),
            ("Writing EFI partition image", .writingEFI),
            ("Writing boot image", .writingBoot),
            ("Writing partition table", .writingTable),
            ("Syncing", .syncing),
        ]
        var best: (Int, InstallPhase)? = nil
        for (marker, phase) in markers {
            if let r = log.range(of: marker, options: .backwards) {
                let pos = log.distance(from: log.startIndex, to: r.lowerBound)
                if best == nil || pos > best!.0 { best = (pos, phase) }
            }
        }
        return best?.1 ?? .idle
    }

    var label: String? {
        switch self {
        case .clearing: return "Clearing old partition data…"
        case .formatting: return "Formatting exFAT partition…"
        case .writingEFI: return "Writing EFI partition image…"
        case .writingBoot: return "Writing boot image…"
        case .writingTable: return "Writing partition table…"
        case .syncing: return "Syncing…"
        default: return nil
        }
    }

    var activeRegion: String? {
        switch self {
        case .clearing, .writingTable, .syncing: return "all"
        case .formatting: return "data"
        case .writingEFI: return "efi"
        case .writingBoot: return "boot"
        default: return nil
        }
    }
}

enum RegionKind {
    case boot, data, efi, reserved, existing
}

struct MapRegion: Identifiable {
    let id: String
    let label: String
    let kind: RegionKind
    let size: UInt64
    var fixedWidth: CGFloat?
}

struct PartitionBar: View {
    let regions: [MapRegion]
    var activeID: String?
    var faded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 2
            let fixed = regions.compactMap(\.fixedWidth).reduce(0, +)
            let flexTotal = regions.filter { $0.fixedWidth == nil }
                .reduce(0.0) { $0 + Double($1.size) }
            let avail = max(0, geo.size.width - fixed - spacing * CGFloat(max(0, regions.count - 1)))
            HStack(spacing: spacing) {
                ForEach(regions) { r in
                    let w = r.fixedWidth
                        ?? max(8, avail * CGFloat(Double(r.size) / max(flexTotal, 1)))
                    segment(r, width: w)
                        .frame(width: w)
                }
            }
        }
        .frame(height: 28)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private func segment(_ r: MapRegion, width: CGFloat) -> some View {
        let active = activeID == r.id || activeID == "all"
        return RoundedRectangle(cornerRadius: 3)
            .fill(fill(r.kind))
            .overlay {
                if r.kind == .existing || r.kind == .reserved {
                    Hatch(color: Theme.dim.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }
            .overlay {
                if r.kind == .existing, width > 70 {
                    Text(r.label)
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.dim)
                        .padding(.horizontal, 6)
                        .background(Capsule().fill(Theme.bezel.opacity(0.85)))
                        .lineLimit(1)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(active ? Theme.phosphor : .clear, lineWidth: 1.5)
            }
            .opacity(activeBrightness(active))
            .saturation(faded ? 0.5 : 1)
    }

    private func activeBrightness(_ active: Bool) -> Double {
        guard active else { return faded ? 0.55 : 1 }
        if reduceMotion { return 1 }
        return pulse ? 0.55 : 1
    }

    private func fill(_ kind: RegionKind) -> Color {
        switch kind {
        case .boot: return Theme.phosphor.opacity(0.45)
        case .data: return Theme.steel
        case .efi: return Theme.phosphor
        case .reserved: return Theme.well
        case .existing: return Theme.hairline
        }
    }
}

struct Hatch: View {
    let color: Color
    var body: some View {
        Canvas { ctx, size in
            var path = Path()
            for x in stride(from: -size.height, through: size.width, by: 7) {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
            }
            ctx.stroke(path, with: .color(color), lineWidth: 1)
        }
    }
}

struct LegendItem: View {
    let color: Color
    let hatched: Bool
    let text: String

    init(_ color: Color, hatched: Bool = false, _ text: String) {
        self.color = color
        self.hatched = hatched
        self.text = text
    }

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .overlay { if hatched { Hatch(color: Theme.dim.opacity(0.6)) } }
                .frame(width: 10, height: 10)
            Text(text)
                .font(Theme.mono(10))
                .foregroundStyle(Theme.dim)
        }
    }
}

import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Window-level pairing sheet: a QR code the phone scans, the 6-digit code as a
/// fallback for typing, and every base URL this host currently answers on.
@MainActor
final class PairingState: ObservableObject {
    @Published var ticket: PairingTicket?
    @Published var loading = false
    @Published var errorText: String?
    @Published var isPresented = false

    func open(model: WidgetModel) {
        isPresented = true
        guard ticket == nil, !loading else { return }
        Task { await refresh(model: model) }
    }

    func refresh(model: WidgetModel) async {
        loading = true
        errorText = nil
        do {
            ticket = try await model.startPairing()
        } catch {
            ticket = nil
            errorText = error.localizedDescription
        }
        loading = false
    }

    func close() {
        isPresented = false
        ticket = nil
        errorText = nil
    }
}

struct PairingOverlay: View {
    @ObservedObject var state: PairingState
    @ObservedObject var model: WidgetModel

    var body: some View {
        Group {
            if state.isPresented {
                ZStack {
                    Color.black.opacity(0.55)
                        .ignoresSafeArea()
                        .onTapGesture { state.close() }
                    card
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
            }
        }
        .animation(.easeOut(duration: 0.14), value: state.isPresented)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider().opacity(0.4)
            if let errorText = state.errorText {
                Text(errorText)
                    .font(.system(size: 11))
                    .foregroundStyle(.red.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            } else if let ticket = state.ticket {
                body(for: ticket)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在生成配对码…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            }
            footer
        }
        .padding(18)
        .frame(width: 470)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.98))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 26, y: 10)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "qrcode")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("手机配对")
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
            Button { state.close() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
    }

    private func body(for ticket: PairingTicket) -> some View {
        HStack(alignment: .top, spacing: 16) {
            qr(ticket.uri)
            VStack(alignment: .leading, spacing: 10) {
                code(ticket)
                countdown(ticket)
                addresses(ticket)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A dark QR code needs a light quiet zone; on the HUD material the code
    /// would otherwise be unscannable.
    private func qr(_ payload: String) -> some View {
        Group {
            if let image = Self.qrImage(payload) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 176, height: 176)
            } else {
                Text("二维码生成失败")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 176, height: 176)
            }
        }
        .padding(10)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func code(_ ticket: PairingTicket) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("在手机上扫右边二维码，或手输配对码")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(Self.spaced(ticket.code))
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .tracking(1.5)
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(ticket.code, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help("复制配对码")
            }
        }
    }

    private func countdown(_ ticket: PairingTicket) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = Self.remainingSeconds(ticket, now: context.date)
            Text(remaining > 0
                 ? "有效期还剩 " + Self.clock(remaining)
                 : "已过期，重新生成一个")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(remaining > 0 ? Color.secondary : Color.orange.opacity(0.9))
        }
    }

    private func addresses(_ ticket: PairingTicket) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("这台电脑的地址")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            ForEach(Array(ticket.usableAddrs.prefix(3).enumerated()), id: \.offset) { index, address in
                HStack(spacing: 5) {
                    Text(index == 0 ? "首选" : "备用")
                        .font(.system(size: 8, weight: .semibold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.white.opacity(index == 0 ? 0.16 : 0.07), in: Capsule())
                        .foregroundStyle(index == 0 ? Color.primary : Color.secondary)
                    Text(address)
                        .font(.system(size: 9, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(index == 0 ? Color.primary : Color.secondary)
                }
            }
            if ticket.usableAddrs.count <= 1 {
                Text("现在只有局域网地址；出门前在 DSH 里开隧道后重新生成。")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("手机和这台电脑在同一 Wi-Fi 时扫码即可；离开局域网要靠隧道地址。")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(state.loading ? "生成中…" : "重新生成") {
                Task { await state.refresh(model: model) }
            }
            .font(.system(size: 10))
            .disabled(state.loading)
        }
    }

    // MARK: - Helpers

    private static func spaced(_ code: String) -> String {
        guard code.count == 6 else { return code }
        let head = code.prefix(3)
        let tail = code.suffix(3)
        return head + " " + tail
    }

    private static func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private static func remainingSeconds(_ ticket: PairingTicket, now: Date) -> Int {
        guard let expiry = ticket.expiry else { return 0 }
        return max(0, Int(expiry.timeIntervalSince(now).rounded(.down)))
    }

    private static func qrImage(_ payload: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}

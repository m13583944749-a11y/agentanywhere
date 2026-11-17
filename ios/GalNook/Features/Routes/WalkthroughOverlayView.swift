import SwiftUI

struct WalkthroughOverlayView: View {
    let route: LocalRoute
    @Binding var isPresented: Bool
    @State private var offset = CGSize.zero
    @State private var dragOffset = CGSize.zero
    @State private var width: CGFloat = 280
    @State private var height: CGFloat = 360
    @State private var scale: CGFloat = 1

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "map.fill")
                VStack(alignment: .leading, spacing: 2) {
                    Text(route.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if !route.character.isEmpty {
                        Text(route.character).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Button { isPresented = false } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .accessibilityLabel("关闭浮层")
            }
            .padding(10)
            .background(.thinMaterial)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(route.nodes) { node in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(node.label, systemImage: node.kind.systemImage)
                                .font(.subheadline.weight(.medium))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if !node.condition.isEmpty {
                                Text("条件：\(node.condition)").font(.caption).foregroundStyle(.secondary)
                            }
                            if !node.notes.isEmpty {
                                Text(node.notes).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(12)
            }
            .background(Color(.systemBackground).opacity(0.94))
            HStack {
                Spacer()
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.caption)
                    .padding(10)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                width = min(480, max(180, 280 + value.translation.width))
                                height = min(620, max(140, 360 + value.translation.height))
                            }
                    )
            }
            .frame(height: 28)
            .background(.thinMaterial)
        }
        .frame(width: width, height: height)
        .scaleEffect(scale)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.quaternary)
        }
        .shadow(radius: 18, y: 8)
        .offset(x: offset.width + dragOffset.width, y: offset.height + dragOffset.height)
        .gesture(
            DragGesture()
                .onChanged { value in dragOffset = value.translation }
                .onEnded { value in
                    offset.width += value.translation.width
                    offset.height += value.translation.height
                    dragOffset = .zero
                }
        )
        .gesture(
            MagnificationGesture()
                .onChanged { value in scale = min(1.3, max(0.75, value)) }
                .onEnded { _ in scale = 1 }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .transition(.opacity.combined(with: .scale))
        .accessibilityLabel("应用内攻略浮层")
    }
}

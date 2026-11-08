import SwiftUI

/// 根据真实可用宽度选布局：完整标题能放下一行时，没有展开按钮；放不下才提供折叠操作。
struct DYExpandableTitle: View {
    let text: String
    let foreground: Color
    let secondary: Color
    @State private var expanded = false

    private var oneLine: String { text.split(whereSeparator: \.isNewline).joined(separator: " ") }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Text(oneLine)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityIdentifier("douyin.description")
            HStack(alignment: .bottom, spacing: 6) {
                Text(expanded ? text : oneLine)
                    .lineLimit(expanded ? nil : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onTapGesture { expanded.toggle() }
                    .accessibilityIdentifier("douyin.description")
                Button(expanded ? "收起" : "展开") { expanded.toggle() }
                    .font(.caption)
                    .foregroundStyle(secondary)
                    .fixedSize()
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("douyin.description.toggle")
            }
        }
        .font(.subheadline)
        .foregroundStyle(foreground)
    }
}

#if DEBUG
struct DYTitleLayoutProbe: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            DYExpandableTitle(text: "短标题", foreground: .primary, secondary: .secondary)
                .frame(width: 280).accessibilityElement(children: .contain).accessibilityIdentifier("title.short")
            DYExpandableTitle(text: String(repeating: "这是一段需要折叠的长标题，", count: 8), foreground: .primary, secondary: .secondary)
                .frame(width: 280).accessibilityElement(children: .contain).accessibilityIdentifier("title.long")
        }
        .padding()
    }
}
#endif

import SwiftUI

struct SelectionOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var subtitle: String? = nil
    var identifier: String = ""
    var id: Value { value }
}

/// A bounded sheet gives every choice a wrapping row and a real scroll surface,
/// including compact-height phones where popup menu rows can be clipped.
struct SelectionPicker<Value: Hashable, Label: View>: View {
    let title: String
    @Binding var selection: Value
    let options: [SelectionOption<Value>]
    var listIdentifier = "selection-list"
    var onPresentationChange: (Bool) -> Void = { _ in }
    @ViewBuilder let label: () -> Label
    @State private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: { label() }
            .onChange(of: isPresented) { _, value in onPresentationChange(value) }
            .sheet(isPresented: $isPresented) {
                SelectionSheet(title: title, listIdentifier: listIdentifier) {
                    ForEach(options) { option in
                        Button {
                            selection = option.value
                            isPresented = false
                        } label: {
                            SelectionRow(title: option.title, subtitle: option.subtitle,
                                         selected: selection == option.value)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(option.identifier)
                        .accessibilityValue(selection == option.value ? "Selected" : "Not selected")
                    }
                }
            }
    }
}

struct SelectionSheet<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let listIdentifier: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        NavigationStack {
            List { content() }
                .accessibilityIdentifier(listIdentifier)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .background(OptionsKeyboardDismissal(onDismiss: dismiss.callAsFunction).frame(width: 0, height: 0))
    }
}

struct SelectionRow: View {
    let title: String
    var subtitle: String? = nil
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).foregroundStyle(.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            if selected {
                Image(systemName: "checkmark").foregroundStyle(Color("AccessibleAccent"))
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

extension AudioTrack {
    func selectionOption(defaultIndex: Int?) -> SelectionOption<Int> {
        SelectionOption(value: index, title: displayName,
            subtitle: technicalLabel + (self.default || index == defaultIndex ? " · Default" : ""),
            identifier: "server-audio-\(index)")
    }
}

import SwiftUI

/// Small sheet for typing a lock message, a message, a website or an address.
struct PromptSheet: View {
    let prompt: Prompt
    let onSubmit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(prompt.title)
                .font(.headline)
            TextField(prompt.placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 380)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(prompt.actionTitle) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
        .padding(20)
        .onAppear { text = prompt.defaultText }
    }

    private var canSubmit: Bool {
        prompt.allowsEmpty || !text.trimmed.isEmpty
    }

    private func submit() {
        guard canSubmit else { return }
        onSubmit(text)
        dismiss()
    }
}

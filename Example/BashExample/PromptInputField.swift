//
//  PromptInputField.swift
//  BashExample
//
//  Created by Zac White on 4/18/26.
//

import SwiftUI

struct PromptInputField: View {
    @Binding var command: String
    @FocusState var isFocused: Bool

    var onSubmit: () -> Void

    var body: some View {
        TextField(
            "Prompt",
            text: $command,
            axis: .vertical
        )
        .autocorrectionDisabled()
        .focused($isFocused)
        .padding(12)
        .lineLimit(1 ... 4)
        .onSubmit(onSubmit)
        #if !os(macOS)
        .textInputAutocapitalization(.never)
        .keyboardType(.asciiCapable)
        #endif
        .textFieldStyle(.plain)
        .glassEffect(.regular, in: .containerRelative)
        .background {
            Button {
                onSubmit()
            } label: {
                EmptyView()
            }
            .keyboardShortcut(.defaultAction)
            .opacity(0)
        }
        .padding()
    }
}

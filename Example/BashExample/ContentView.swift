//
//  ContentView.swift
//  BashExample
//
//  Created by Zac White on 4/8/26.
//

import SwiftUI
import Bash

struct ContentView: View {

    @FocusState private var inputFocused

    @Observable
    class ViewModel {
        private var session: BashSession!
        var command: String = ""
        var transcript: String = ""
        var showBrowser = false

        func setup() async throws {
            session = try await BashSession(
                options: .init(
                    filesystem: InMemoryFilesystem(),
                    layout: .unixLike,
                    initialEnvironment: [:],
                    enableGlobbing: true,
                    maxHistory: 1000,
                    networkPolicy: .unrestricted,
                    executionLimits: .default,
                    permissionHandler: handle(permissionRequest:), secretPolicy: .off, secretResolver: nil, secretOutputRedactor: DefaultSecretOutputRedactor()
                )
            )
        }

        func runCurrentCommand() async {
            let commandToRun = command
            self.command = ""

            transcript.append("> \(commandToRun)\n")
            let result = await session.run(commandToRun)
            transcript.append(result.stdoutString)
            transcript.append(result.stderrString)
            transcript.append("\n")
        }

        func showFileBrowser() {
            showBrowser = true
        }

        private func handle(permissionRequest: ShellPermissionRequest) async -> ShellPermissionDecision {
            return .allowForSession
        }
    }

    @State private var viewModel = ViewModel()

    var body: some View {
        let onSubmit = { () -> Void in
            inputFocused = true
            Task {
                await viewModel.runCurrentCommand()
            }
        }
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading) {
                    Text(viewModel.transcript)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .safeAreaBar(edge: .bottom) {
                TextField("Prompt", text: $viewModel.command)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.asciiCapable)
                    .focused($inputFocused)
                    .onSubmit(onSubmit)
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
                    .textFieldStyle(.roundedBorder)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        viewModel.showFileBrowser()
                    } label: {
                        Label("File Browser", systemImage: "document.on.document")
                    }
                }
            }
        }
        .sheet(isPresented: $viewModel.showBrowser) {
            Text("Browser")
        }
        .task {
            try? await viewModel.setup()
        }
    }
}

#Preview {
    ContentView()
}

//
//  ContentView.swift
//  BashExample
//
//  Created by Zac White on 4/8/26.
//

import QuickLook
import SwiftUI
import Bash

struct ContentView: View {

    @FocusState private var inputFocused: Bool

    @MainActor
    @Observable
    final class ViewModel {
        private var session: BashSession?

        var command: String = ""
        var transcript: String = ""
        var showBrowser = false
        var workspaceRootURL: URL?
        var workspaceHomeURL: URL?
        var setupError: String?

        func setup() async {
            do {
                let rootURL = try Self.prepareWorkspaceRoot()
                let filesystem = ReadWriteFilesystem()
                let configuredSession = try await BashSession(
                    rootDirectory: rootURL,
                    options: .init(
                        filesystem: filesystem,
                        layout: .unixLike,
                        initialEnvironment: [:],
                        enableGlobbing: true,
                        maxHistory: 1000,
                        networkPolicy: .unrestricted,
                        executionLimits: .default,
                        permissionHandler: handle(permissionRequest:),
                        secretPolicy: .off,
                        secretResolver: nil,
                        secretOutputRedactor: DefaultSecretOutputRedactor()
                    )
                )

                let homeURL = rootURL.appendingPathComponent("home/user", isDirectory: true)
                try Self.seedWorkspaceFiles(in: homeURL)

                session = configuredSession
                workspaceRootURL = rootURL
                workspaceHomeURL = homeURL
                setupError = nil
            } catch {
                setupError = error.localizedDescription
                transcript = "Setup failed: \(error.localizedDescription)\n"
            }
        }

        private static func prepareWorkspaceRoot() throws -> URL {
            let documentsURL = try FileManager.default.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let workspaceURL = documentsURL.appendingPathComponent("BashWorkspace", isDirectory: true)
            try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
            return workspaceURL
        }

        private static func seedWorkspaceFiles(in homeURL: URL) throws {
            try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)

            let readmeURL = homeURL.appendingPathComponent("README.md")
            if !FileManager.default.fileExists(atPath: readmeURL.path) {
                try """
                # Bash Example Workspace

                Files created by shell commands appear here.
                Open the file browser to preview them with Quick Look.
                """.write(to: readmeURL, atomically: true, encoding: .utf8)
            }

            let scriptsURL = homeURL.appendingPathComponent("scripts", isDirectory: true)
            try FileManager.default.createDirectory(at: scriptsURL, withIntermediateDirectories: true)

            let pythonURL = scriptsURL.appendingPathComponent("hello.py")
            if !FileManager.default.fileExists(atPath: pythonURL.path) {
                try """
                import json

                print(json.dumps({"hello": "BashExample"}))
                """.write(to: pythonURL, atomically: true, encoding: .utf8)
            }
        }

        func runCurrentCommand() async {
            let commandToRun = command
            self.command = ""
            guard !commandToRun.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }

            guard let session else {
                transcript.append("Shell is still starting.\n")
                return
            }

            transcript.append("> \(commandToRun)\n")
            let result = await session.run(commandToRun)
            transcript.append(result.stdoutString)
            transcript.append(result.stderrString)
            transcript.append("\n")
        }

        func showFileBrowser() {
            if workspaceHomeURL != nil {
                showBrowser = true
            }
        }

        private func handle(permissionRequest: ShellPermissionRequest) async -> ShellPermissionDecision {
            _ = permissionRequest
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
                    if let setupError = viewModel.setupError {
                        Text(setupError)
                            .foregroundStyle(.red)
                    }
                    Text(viewModel.transcript)
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .safeAreaBar(edge: .bottom) {
                TextField(
                    "Prompt",
                    text: $viewModel.command,
                    axis: .vertical
                )
                .autocorrectionDisabled()
                .focused($inputFocused)
                .padding(12)
                .lineLimit(1 ... 4)
                .onSubmit(onSubmit)
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.asciiCapable)
                .textFieldStyle(.plain)
                .glassEffect(.regular, in: .containerRelative)
                #endif
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
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        viewModel.showFileBrowser()
                    } label: {
                        Label("File Browser", systemImage: "document.on.document")
                    }
                    .disabled(viewModel.workspaceHomeURL == nil)
                }
            }
        }
        .sheet(isPresented: $viewModel.showBrowser) {
            if let homeURL = viewModel.workspaceHomeURL,
               let rootURL = viewModel.workspaceRootURL {
                WorkspaceBrowserView(
                    rootURL: homeURL,
                    workspaceRootURL: rootURL
                )
            } else {
                ProgressView()
            }
        }
        .task {
            await viewModel.setup()
        }
    }
}

#Preview {
    ContentView()
}

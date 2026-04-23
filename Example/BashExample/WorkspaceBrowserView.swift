//
//  WorkspaceBrowserView.swift
//  BashExample
//
//  Created by Zac White on 4/17/26.
//

import SwiftUI
import QuickLook

struct WorkspaceBrowserView: View {
    let rootURL: URL
    let workspaceRootURL: URL

    @Environment(\.dismiss) private var dismiss
    @State private var previewURL: URL?

    var body: some View {
        NavigationStack {
            DirectoryBrowserView(
                directoryURL: rootURL,
                rootURL: rootURL,
                workspaceRootURL: workspaceRootURL,
                previewURL: $previewURL
            )
            .navigationTitle("Files")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) {
                        dismiss()
                    }
                }
            }
        }
        .quickLookPreview($previewURL)
    }
}

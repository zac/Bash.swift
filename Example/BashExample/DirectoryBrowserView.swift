//
//  DirectoryBrowserView.swift
//  BashExample
//
//  Created by Zac White on 4/17/26.
//

import SwiftUI

struct DirectoryBrowserView: View {
    let directoryURL: URL
    let rootURL: URL
    let workspaceRootURL: URL

    @Binding var previewURL: URL?

    @State private var entries: [FileBrowserEntry] = []
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }

            if entries.isEmpty && errorMessage == nil {
                Section {
                    Text("No files")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach(entries) { entry in
                    if entry.isDirectory {
                        NavigationLink {
                            DirectoryBrowserView(
                                directoryURL: entry.url,
                                rootURL: rootURL,
                                workspaceRootURL: workspaceRootURL,
                                previewURL: $previewURL
                            )
                        } label: {
                            FileBrowserRow(entry: entry)
                        }
                    } else {
                        Button {
                            previewURL = entry.url
                        } label: {
                            FileBrowserRow(entry: entry)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle(directoryTitle)
        #if !os(macOS)
        .toolbar {
            ToolbarItem(placement: .subtitle) {
                Text(relativeDisplayPath(for: directoryURL))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        #endif
        .onAppear {
            reload()
        }
        .refreshable {
            reload()
        }
    }

    private var directoryTitle: String {
        directoryURL.standardizedFileURL == rootURL.standardizedFileURL
        ? "Home"
        : directoryURL.lastPathComponent
    }

    private func reload() {
        do {
            let keys: Set<URLResourceKey> = [
                .isDirectoryKey,
                .isRegularFileKey,
                .fileSizeKey,
                .contentModificationDateKey,
                .isHiddenKey,
            ]
            let urls = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )

            entries = try urls.map { url in
                let values = try url.resourceValues(forKeys: keys)
                return FileBrowserEntry(
                    url: url,
                    isDirectory: values.isDirectory ?? false,
                    size: values.fileSize,
                    modifiedAt: values.contentModificationDate
                )
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory && !rhs.isDirectory
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            errorMessage = nil
        } catch {
            entries = []
            errorMessage = error.localizedDescription
        }
    }

    private func relativeDisplayPath(for url: URL) -> String {
        let standardizedURL = url.standardizedFileURL
        let root = workspaceRootURL.standardizedFileURL.path
        let path = standardizedURL.path
        guard path.hasPrefix(root) else {
            return path
        }

        let relative = String(path.dropFirst(root.count))
        return relative.isEmpty ? "/" : relative
    }
}

private struct FileBrowserEntry: Identifiable {
    let url: URL
    let isDirectory: Bool
    let size: Int?
    let modifiedAt: Date?

    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

private struct FileBrowserRow: View {
    let entry: FileBrowserEntry

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .lineLimit(1)
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: entry.isDirectory ? "folder" : "doc.text")
                .foregroundStyle(entry.isDirectory ? .primary : .secondary)
        }
    }

    private var detailText: String {
        if entry.isDirectory {
            return "Folder"
        }

        let byteCount = ByteCountFormatter.string(
            fromByteCount: Int64(entry.size ?? 0),
            countStyle: .file
        )

        guard let modifiedAt = entry.modifiedAt else {
            return byteCount
        }

        return "\(byteCount) - \(modifiedAt.formatted(date: .abbreviated, time: .shortened))"
    }
}

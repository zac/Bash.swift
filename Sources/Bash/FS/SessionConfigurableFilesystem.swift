import Foundation

public protocol SessionConfigurableFilesystem: ShellFilesystem {
    func configureForSession() throws
}

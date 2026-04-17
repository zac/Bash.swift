import BashCore
import Foundation

#if Git
import BashGitFeature
#endif

#if Python
import BashPythonFeature
#endif

#if SQLite
import BashSQLiteFeature
#endif

package enum BashCompiledCommands {
    package static func all() -> [AnyBuiltinCommand] {
        var commands = defaults()

        #if Git
        commands.append(builtin(GitCommand.self))
        #endif

        #if Python
        commands.append(builtin(Python3Command.self))
        #endif

        #if SQLite
        commands.append(builtin(SQLite3Command.self))
        #endif

        return commands
    }

    private static func defaults() -> [AnyBuiltinCommand] {
        [
            builtin(CatCommand.self),
            builtin(CpCommand.self),
            builtin(LnCommand.self),
            builtin(LsCommand.self),
            builtin(MkdirCommand.self),
            builtin(MvCommand.self),
            builtin(ReadlinkCommand.self),
            builtin(RmCommand.self),
            builtin(RmdirCommand.self),
            builtin(StatCommand.self),
            builtin(TouchCommand.self),
            builtin(ChmodCommand.self),
            builtin(FileCommand.self),
            builtin(TreeCommand.self),
            builtin(DiffCommand.self),
            builtin(GrepCommand.self),
            builtin(RgCommand.self),
            builtin(HeadCommand.self),
            builtin(TailCommand.self),
            builtin(NlCommand.self),
            builtin(WcCommand.self),
            builtin(SortCommand.self),
            builtin(UniqCommand.self),
            builtin(CutCommand.self),
            builtin(TrCommand.self),
            builtin(AwkCommand.self),
            builtin(SedCommand.self),
            builtin(XargsCommand.self),
            builtin(PrintfCommand.self),
            builtin(Base64Command.self),
            builtin(Sha256sumCommand.self),
            builtin(Sha1sumCommand.self),
            builtin(Md5sumCommand.self),
            builtin(GzipCommand.self),
            builtin(GunzipCommand.self),
            builtin(ZcatCommand.self),
            builtin(ZipCommand.self),
            builtin(UnzipCommand.self),
            builtin(TarCommand.self),
            builtin(JqCommand.self),
            builtin(YqCommand.self),
            builtin(XanCommand.self),
            builtin(BasenameCommand.self),
            builtin(CdCommand.self),
            builtin(DirnameCommand.self),
            builtin(DuCommand.self),
            builtin(EchoCommand.self),
            builtin(EnvCommand.self),
            builtin(ExportCommand.self),
            builtin(FindCommand.self),
            builtin(PrintenvCommand.self),
            builtin(PwdCommand.self),
            builtin(TeeCommand.self),
            builtin(CurlCommand.self),
            builtin(WgetCommand.self),
            builtin(HtmlToMarkdownCommand.self),
            builtin(ClearCommand.self),
            builtin(DateCommand.self),
            builtin(HostnameCommand.self),
            builtin(FalseCommand.self),
            builtin(WhoamiCommand.self),
            builtin(HelpCommand.self),
            builtin(HistoryCommand.self),
            builtin(JobsCommand.self),
            builtin(FgCommand.self),
            builtin(WaitCommand.self),
            builtin(PsCommand.self),
            builtin(KillCommand.self),
            builtin(SeqCommand.self),
            builtin(SleepCommand.self),
            builtin(TimeCommand.self),
            builtin(TimeoutCommand.self),
            builtin(TrueCommand.self),
            builtin(WhichCommand.self),
        ]
    }

    private static func builtin<C: BuiltinCommand>(_ command: C.Type) -> AnyBuiltinCommand {
        command._toAnyBuiltinCommand()
    }
}

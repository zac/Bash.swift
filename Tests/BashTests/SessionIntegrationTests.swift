import Foundation
import Testing
@testable import Bash

actor PermissionProbe {
    private var requests: [PermissionRequest] = []

    func record(_ request: PermissionRequest) {
        requests.append(request)
    }

    func snapshot() -> [PermissionRequest] {
        requests
    }
}

@Suite("Session Integration")
struct SessionIntegrationTests {
    @Test("touch then ls mutates read-write filesystem")
    func touchThenLsShowsFileAndMutatesReadWriteFilesystem() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let touch = await session.run("touch file.txt")
        #expect(touch.exitCode == 0)

        let ls = await session.run("ls")
        #expect(ls.exitCode == 0)
        #expect(ls.stdoutString.contains("file.txt"))

        let physicalPath = root
            .appendingPathComponent("home/user", isDirectory: true)
            .appendingPathComponent("file.txt")
            .path
        #expect(FileManager.default.fileExists(atPath: physicalPath))
    }

    @Test("pipe and output redirection")
    func pipeAndOutputRedirection() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let exec = await session.run("echo hi | tee out.txt > copy.txt")
        #expect(exec.exitCode == 0)
        #expect(exec.stdoutString == "")

        let out = await session.run("cat out.txt")
        #expect(out.stdoutString == "hi\n")

        let copy = await session.run("cat copy.txt")
        #expect(copy.stdoutString == "hi\n")
    }

    @Test("export and variable expansion")
    func exportAndVariableExpansion() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let exported = await session.run("export A=1")
        #expect(exported.exitCode == 0)

        let echoed = await session.run("echo $A")
        #expect(echoed.stdoutString == "1\n")

        let fallback = await session.run("echo ${MISSING:-fallback}")
        #expect(fallback.stdoutString == "fallback\n")
    }

    @Test("run options environment override is isolated from session state")
    func runOptionsEnvironmentOverrideIsIsolatedFromSessionState() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let isolated = await session.run(
            "export TEMP=mutated; echo $TEMP",
            options: RunOptions(environment: ["TEMP": "seed"])
        )
        #expect(isolated.exitCode == 0)
        #expect(isolated.stdoutString == "mutated\n")

        let restored = await session.run("echo $TEMP")
        #expect(restored.exitCode == 0)
        #expect(restored.stdoutString == "\n")
    }

    @Test("run options current directory override is isolated from session state")
    func runOptionsCurrentDirectoryOverrideIsIsolatedFromSessionState() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        _ = await session.run("mkdir -p tempdir && echo scoped > tempdir/file.txt")

        let isolated = await session.run(
            "pwd && cat file.txt",
            options: RunOptions(currentDirectory: "/home/user/tempdir")
        )
        #expect(isolated.exitCode == 0)
        #expect(isolated.stdoutString == "/home/user/tempdir\nscoped\n")

        let restored = await session.run("pwd")
        #expect(restored.exitCode == 0)
        #expect(restored.stdoutString == "/home/user\n")
    }

    @Test("run options can replace environment without mutating session")
    func runOptionsCanReplaceEnvironmentWithoutMutatingSession() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        _ = await session.run("export PERSIST=value")

        let isolated = await session.run(
            "printenv PERSIST",
            options: RunOptions(replaceEnvironment: true)
        )
        #expect(isolated.exitCode == 1)
        #expect(isolated.stdoutString.isEmpty)

        let restored = await session.run("printenv PERSIST")
        #expect(restored.exitCode == 0)
        #expect(restored.stdoutString == "value\n")
    }

    @Test("command substitution writes evaluated output")
    func commandSubstitutionWritesEvaluatedOutput() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let write = await session.run("echo $(pwd) > cwd.txt")
        #expect(write.exitCode == 0)

        let read = await session.run("cat cwd.txt")
        #expect(read.exitCode == 0)
        #expect(read.stdoutString == "/home/user\n")
    }

    @Test("pwd can map root-only virtual paths to a host workspace path")
    func pwdCanMapRootOnlyVirtualPathsToAHostWorkspacePath() async throws {
        let root = try TestSupport.makeTempDirectory()
        defer { TestSupport.removeDirectory(root) }

        let session = try await BashSession(
            rootDirectory: root,
            options: SessionOptions(
                layout: .rootOnly,
                initialEnvironment: ["BASHSWIFT_PWD_HOST_ROOT": root.path]
            )
        )

        let top = await session.run("pwd")
        #expect(top.exitCode == 0)
        #expect(top.stdoutString == "\(root.path)\n")

        let nested = await session.run("mkdir -p nested && cd nested && pwd")
        #expect(nested.exitCode == 0)
        #expect(nested.stdoutString == "\(root.path)/nested\n")
    }

    @Test("simple for loop executes and supports output redirection")
    func simpleForLoopExecutesAndSupportsOutputRedirection() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let loop = await session.run("for i in 1 2 3; do echo $i; done > nums.txt")
        #expect(loop.exitCode == 0)
        #expect(loop.stdoutString.isEmpty)

        let file = await session.run("cat nums.txt")
        #expect(file.exitCode == 0)
        #expect(file.stdoutString == "1\n2\n3\n")
    }

    @Test("newline for loop syntax executes")
    func newlineForLoopSyntaxExecutes() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let loop = await session.run(
            """
            for i in 1 2 3
            do
              echo $i
            done > nums_newline.txt
            """
        )
        #expect(loop.exitCode == 0)

        let file = await session.run("cat nums_newline.txt")
        #expect(file.exitCode == 0)
        #expect(file.stdoutString == "1\n2\n3\n")
    }

    @Test("for loop with empty list still applies redirection")
    func forLoopWithEmptyListStillAppliesRedirection() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let loop = await session.run("for i in; do echo $i; done > empty.txt")
        #expect(loop.exitCode == 0)

        let exists = await session.run("cat empty.txt")
        #expect(exists.exitCode == 0)

        let size = await session.run("wc -c < empty.txt")
        #expect(size.exitCode == 0)
        #expect(size.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "0")
    }

    @Test("for loop output can feed trailing pipeline")
    func forLoopOutputCanFeedTrailingPipeline() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let loop = await session.run("for i in b a c; do echo $i; done | sort > vals.txt")
        #expect(loop.exitCode == 0)

        let file = await session.run("cat vals.txt")
        #expect(file.exitCode == 0)
        #expect(file.stdoutString == "a\nb\nc\n")
    }

    @Test("function definition can be invoked later in the same line")
    func functionDefinitionCanBeInvokedLaterInTheSameLine() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let result = await session.run("greet(){ echo hi; }; greet > greet.txt")
        #expect(result.exitCode == 0)

        let file = await session.run("cat greet.txt")
        #expect(file.exitCode == 0)
        #expect(file.stdoutString == "hi\n")
    }

    @Test("function positional argument expansion")
    func functionPositionalArgumentExpansion() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let result = await session.run("joiner(){ echo \"$1\"; }; joiner pass > arg.txt")
        #expect(result.exitCode == 0)

        let file = await session.run("cat arg.txt")
        #expect(file.exitCode == 0)
        #expect(file.stdoutString == "pass\n")
    }

    @Test("if then else blocks execute")
    func ifThenElseBlocksExecute() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        _ = await session.run("touch flag.txt")
        let result = await session.run("if test -f flag.txt; then echo yes > result.txt; else echo no > result.txt; fi")
        #expect(result.exitCode == 0)

        let file = await session.run("cat result.txt")
        #expect(file.exitCode == 0)
        #expect(file.stdoutString == "yes\n")
    }

    @Test("while loops with assignment and arithmetic expansion")
    func whileLoopsWithAssignmentAndArithmeticExpansion() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let result = await session.run("i=1; while [ $i -le 3 ]; do echo $i; i=$((i+1)); done > while.txt")
        #expect(result.exitCode == 0)

        let file = await session.run("cat while.txt")
        #expect(file.exitCode == 0)
        #expect(file.stdoutString == "1\n2\n3\n")
    }

    @Test("if elif branches execute")
    func ifElifBranchesExecute() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let result = await session.run(
            "if false; then echo no > elif.txt; elif true; then echo elif-hit > elif.txt; else echo no > elif.txt; fi"
        )
        #expect(result.exitCode == 0)

        let file = await session.run("cat elif.txt")
        #expect(file.exitCode == 0)
        #expect(file.stdoutString == "elif-hit\n")
    }

    @Test("until loops execute until condition becomes true")
    func untilLoopsExecuteUntilConditionBecomesTrue() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let result = await session.run("i=1; until [ $i -gt 3 ]; do echo $i; i=$((i+1)); done > until.txt")
        #expect(result.exitCode == 0)

        let file = await session.run("cat until.txt")
        #expect(file.exitCode == 0)
        #expect(file.stdoutString == "1\n2\n3\n")
    }

    @Test("case statements with glob patterns execute")
    func caseStatementsWithGlobPatternsExecute() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let result = await session.run(
            "name=notes.md; case $name in *.md) echo md > case.txt ;; *.txt) echo txt > case.txt ;; *) echo other > case.txt ;; esac"
        )
        #expect(result.exitCode == 0)

        let file = await session.run("cat case.txt")
        #expect(file.exitCode == 0)
        #expect(file.stdoutString == "md\n")
    }

    @Test("c-style for loops execute")
    func cStyleForLoopsExecute() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let result = await session.run("for ((i=1; i<=3; i++)); do echo $i; done > cfor.txt")
        #expect(result.exitCode == 0)

        let file = await session.run("cat cfor.txt")
        #expect(file.exitCode == 0)
        #expect(file.stdoutString == "1\n2\n3\n")
    }

    @Test("function keyword form defines callable function")
    func functionKeywordFormDefinesCallableFunction() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let result = await session.run("function greet { echo hi; }; greet > func_kw.txt")
        #expect(result.exitCode == 0)

        let file = await session.run("cat func_kw.txt")
        #expect(file.exitCode == 0)
        #expect(file.stdoutString == "hi\n")
    }

    @Test("local variables are scoped to function execution")
    func localVariablesAreScopedToFunctionExecution() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let result = await session.run(
            "x=outer; function show { local x=inner; echo $x; }; show > local_scope.txt; echo $x >> local_scope.txt"
        )
        #expect(result.exitCode == 0)

        let file = await session.run("cat local_scope.txt")
        #expect(file.exitCode == 0)
        #expect(file.stdoutString == "inner\nouter\n")
    }

    @Test("arithmetic expansion supports rich operators")
    func arithmeticExpansionSupportsRichOperators() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let result = await session.run(
            "echo $((5 > 3)) > arith.txt; echo $((2 == 3)) >> arith.txt; echo $((1 && 0)) >> arith.txt; echo $((0 || 1)) >> arith.txt; echo $((5 & 3)) >> arith.txt; echo $((5 | 2)) >> arith.txt; echo $((5 ^ 1)) >> arith.txt; echo $((2 ** 8)) >> arith.txt"
        )
        #expect(result.exitCode == 0)

        let file = await session.run("cat arith.txt")
        #expect(file.exitCode == 0)
        #expect(file.stdoutString == "1\n0\n0\n1\n1\n7\n4\n256\n")
    }

    @Test("direct positional all-args and count expansions")
    func directPositionalAllArgsAndCountExpansions() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let result = await session.run("show(){ echo \"$@\"; echo \"$#\"; }; show one \"two words\" three > pos.txt")
        #expect(result.exitCode == 0)

        let file = await session.run("cat pos.txt")
        #expect(file.exitCode == 0)
        #expect(file.stdoutString == "one two words three\n3\n")
    }

    @Test("ln without -s keeps linked file content in sync")
    func lnWithoutSymbolicFlagKeepsLinkedFileContentInSync() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        _ = await session.run("printf 'one\\n' > src.txt")
        let linked = await session.run("ln src.txt dst.txt")
        #expect(linked.exitCode == 0)

        _ = await session.run("echo two >> src.txt")
        let file = await session.run("cat dst.txt")
        #expect(file.exitCode == 0)
        #expect(file.stdoutString == "one\ntwo\n")
    }

    @Test("wget version output includes Wget marker")
    func wgetVersionOutputIncludesWgetMarker() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let result = await session.run("wget --version | head -n 1")
        #expect(result.exitCode == 0)
        #expect(result.stdoutString.contains("Wget"))
    }

    @Test("cd and pwd with semicolon chaining")
    func cdPwdAndSemicolonChaining() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let result = await session.run("mkdir a; cd a; pwd")
        #expect(result.exitCode == 0)
        #expect(result.stdoutString == "/home/user/a\n")

        let cwd = await session.currentDirectory
        #expect(cwd == "/home/user/a")
    }

    @Test("and/or short-circuiting")
    func andOrShortCircuiting() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let result = await session.run("false && echo no; true || echo no; true && echo yes; false || echo ok")
        #expect(result.exitCode == 0)
        #expect(result.stdoutString == "yes\nok\n")
    }

    @Test("newline separators and comments")
    func newlineSeparatorsAndComments() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let multiline = await session.run(
            """
            echo one
            # skip this line
            echo two # trailing comment
            echo three#literal
            """
        )
        #expect(multiline.exitCode == 0)
        #expect(multiline.stdoutString == "one\ntwo\nthree#literal\n")
    }

    @Test("unknown command returns 127")
    func unknownCommandReturns127() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let result = await session.run("not-a-real-command")
        #expect(result.exitCode == 127)
        #expect(result.stderrString.contains("command not found"))
    }

    @Test("stderr redirection and merge")
    func stderrRedirectionAndStderrToStdoutMerge() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let redir = await session.run("ls does-not-exist 2> err.txt")
        #expect(redir.exitCode != 0)
        #expect(redir.stderrString == "")

        let err = await session.run("cat err.txt")
        #expect(err.stdoutString.contains("does-not-exist"))

        let merged = await session.run("ls does-not-exist 2>&1")
        #expect(merged.exitCode != 0)
        #expect(merged.stdoutString.contains("does-not-exist"))
        #expect(merged.stderrString == "")
    }

    @Test("extended redirection operators")
    func extendedRedirectionOperators() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let stdoutAlias = await session.run("echo hello 1> out.txt")
        #expect(stdoutAlias.exitCode == 0)

        let out = await session.run("cat out.txt")
        #expect(out.exitCode == 0)
        #expect(out.stdoutString == "hello\n")

        _ = await session.run("ls does-not-exist 2>> err.txt")
        _ = await session.run("ls does-not-exist 2>> err.txt")
        let err = await session.run("cat err.txt")
        let repeatedErrors = err.stdoutString
            .split(separator: "\n")
            .filter { $0.contains("does-not-exist") }
            .count
        #expect(repeatedErrors == 2)

        let both = await session.run("ls does-not-exist &> combined.txt")
        #expect(both.exitCode != 0)
        #expect(both.stdoutString.isEmpty)
        #expect(both.stderrString.isEmpty)

        let combined = await session.run("cat combined.txt")
        #expect(combined.stdoutString.contains("does-not-exist"))

        let appendBoth = await session.run("echo done &>> combined.txt")
        #expect(appendBoth.exitCode == 0)

        let combinedAfterAppend = await session.run("cat combined.txt")
        #expect(combinedAfterAppend.stdoutString.hasSuffix("done\n"))
    }

    @Test("stdin redirection")
    func inputRedirection() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let wrote = await session.run("echo hello > in.txt")
        #expect(wrote.exitCode == 0)
        let result = await session.run("cat < in.txt")
        #expect(result.exitCode == 0)
        #expect(result.stdoutString == "hello\n")
    }

    @Test("here document can write a file and feed a following command")
    func hereDocumentWritesFileAndRunsFollowingCommand() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let result = await session.run(
            """
            cat > fib100.py <<'PY'
            nums = []
            a, b = 0, 1
            for _ in range(5):
                nums.append(a)
                a, b = b, a + b
            print('\\n'.join(map(str, nums)))
            PY
            cat fib100.py
            """
        )

        #expect(result.exitCode == 0)
        #expect(result.stderrString.isEmpty)
        #expect(
            result.stdoutString ==
                """
                nums = []
                a, b = 0, 1
                for _ in range(5):
                    nums.append(a)
                    a, b = b, a + b
                print('\\n'.join(map(str, nums)))
                """
                + "\n"
        )
    }

    @Test("quoted here document bodies stay literal")
    func quotedHereDocumentBodiesStayLiteral() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let result = await session.run(
            """
            cat <<'EOF'
            $(echo nope)
            $HOME
            EOF
            """
        )

        #expect(result.exitCode == 0)
        #expect(result.stdoutString == "$(echo nope)\n$HOME\n")
    }

    @Test("tab-stripped here documents remove only leading tabs")
    func tabStrippedHereDocumentsRemoveOnlyLeadingTabs() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let result = await session.run(
            """
            cat <<-'EOF'
             \tkeep-leading-space
            \ttrim-leading-tab
            \tEOF
            """
        )

        #expect(result.exitCode == 0)
        #expect(
            result.stdoutString ==
                """
                 \tkeep-leading-space
                trim-leading-tab
                """
                + "\n"
        )
    }

    @Test("unquoted here documents expand shell substitutions")
    func unquotedHereDocumentsExpandShellSubstitutions() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let result = await session.run(
            """
            export NAME=world
            cat <<EOF
            hello $NAME
            math $((1 + 2))
            sub $(printf hi)
            escaped \\$NAME
            joined one\\
            two
            EOF
            """
        )

        #expect(result.exitCode == 0)
        #expect(result.stderrString.isEmpty)
        #expect(
            result.stdoutString ==
                """
                hello world
                math 3
                sub hi
                escaped $NAME
                joined onetwo
                """
                + "\n"
        )
    }

    @Test("globbing expansion")
    func globbingExpansion() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let touched = await session.run("touch a.txt b.txt c.md")
        #expect(touched.exitCode == 0)

        let result = await session.run("echo *.txt")
        #expect(result.exitCode == 0)

        let words = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").map(String.init)
        #expect(words.count == 2)
        #expect(words.contains("/home/user/a.txt"))
        #expect(words.contains("/home/user/b.txt"))
    }

    @Test("history formatting")
    func historyCommandFormatsEntries() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        _ = await session.run("echo one")
        _ = await session.run("echo two")
        let history = await session.run("history")

        #expect(history.exitCode == 0)
        #expect(history.stdoutString.contains("1  echo one"))
        #expect(history.stdoutString.contains("2  echo two"))
        #expect(history.stdoutString.contains("3  history"))
    }

    @Test("utility option parity chunk")
    func utilityOptionParityChunk() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let helpSeq = await session.run("help seq")
        #expect(helpSeq.exitCode == 0)
        #expect(helpSeq.stdoutString.contains("USAGE:"))

        let seqSeparated = await session.run("seq -s , 1 3")
        #expect(seqSeparated.exitCode == 0)
        #expect(seqSeparated.stdoutString == "1,2,3\n")

        let seqPadded = await session.run("seq -w 8 10")
        #expect(seqPadded.exitCode == 0)
        #expect(seqPadded.stdoutString == "08\n09\n10\n")

        let sleep = await session.run("sleep 0s 0.01s")
        #expect(sleep.exitCode == 0)

        let sleepInvalid = await session.run("sleep nope")
        #expect(sleepInvalid.exitCode == 1)
        #expect(sleepInvalid.stderrString.contains("invalid time interval"))

        let basename = await session.run("basename -s .txt /tmp/a.txt /tmp/b.log")
        #expect(basename.exitCode == 0)
        #expect(basename.stdoutString == "a\nb.log\n")

        let whichAll = await session.run("which -a ls")
        #expect(whichAll.exitCode == 0)
        #expect(whichAll.stdoutString.contains("/bin/ls\n"))
        #expect(whichAll.stdoutString.contains("/usr/bin/ls\n"))

        let whichSilent = await session.run("which -s ls")
        #expect(whichSilent.exitCode == 0)
        #expect(whichSilent.stdoutString.isEmpty)

        let whichMissing = await session.run("which -s no_such_command")
        #expect(whichMissing.exitCode == 1)

        let printenvMissing = await session.run("printenv HOME DOES_NOT_EXIST")
        #expect(printenvMissing.exitCode == 1)
        #expect(printenvMissing.stdoutString.contains("/home/user\n"))
    }

    @Test("text option parity chunk")
    func textOptionParityChunk() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        _ = await session.run("printf 'a\\nb\\nc' > one.txt")
        _ = await session.run("printf 'd\\ne\\nf' > two.txt")

        let headQuiet = await session.run("head -n 1 -q one.txt two.txt")
        #expect(headQuiet.exitCode == 0)
        #expect(headQuiet.stdoutString == "a\nd\n")

        let headLegacyCount = await session.run("head -2 one.txt")
        #expect(headLegacyCount.exitCode == 0)
        #expect(headLegacyCount.stdoutString == "a\nb\n")

        let headAttachedCount = await session.run("head -n2 one.txt")
        #expect(headAttachedCount.exitCode == 0)
        #expect(headAttachedCount.stdoutString == "a\nb\n")

        let headVerbose = await session.run("head -n 1 -v one.txt")
        #expect(headVerbose.exitCode == 0)
        #expect(headVerbose.stdoutString == "==> one.txt <==\na\n")

        let tailLegacyCount = await session.run("tail -2 one.txt")
        #expect(tailLegacyCount.exitCode == 0)
        #expect(tailLegacyCount.stdoutString == "b\nc\n")

        let tailLegacyFromLine = await session.run("tail +2 one.txt")
        #expect(tailLegacyFromLine.exitCode == 0)
        #expect(tailLegacyFromLine.stdoutString == "b\nc\n")

        let tailAttachedFromLine = await session.run("tail -n+2 one.txt")
        #expect(tailAttachedFromLine.exitCode == 0)
        #expect(tailAttachedFromLine.stdoutString == "b\nc\n")

        let tailFromLine = await session.run("tail -n +2 one.txt")
        #expect(tailFromLine.exitCode == 0)
        #expect(tailFromLine.stdoutString == "b\nc\n")

        let tailInvalidLegacyFromLine = await session.run("tail +0 one.txt")
        #expect(tailInvalidLegacyFromLine.exitCode == 1)
        #expect(tailInvalidLegacyFromLine.stderrString == "tail: invalid number of lines: +0\n")

        let wcChars = await session.run("printf 'é\\n' | wc -m")
        #expect(wcChars.exitCode == 0)
        #expect(wcChars.stdoutString == "2\n")

        _ = await session.run("printf 'b\\na\\nA' > sort.txt")
        let sortFold = await session.run("sort -f sort.txt")
        #expect(sortFold.exitCode == 0)
        #expect(sortFold.stdoutString == "A\na\nb\n")

        let sortOutput = await session.run("sort -f -o sorted.txt sort.txt")
        #expect(sortOutput.exitCode == 0)
        #expect(sortOutput.stdoutString.isEmpty)

        let sortedFile = await session.run("cat sorted.txt")
        #expect(sortedFile.exitCode == 0)
        #expect(sortedFile.stdoutString == "A\na\nb\n")

        let sortCheckGood = await session.run("sort -c sorted.txt")
        #expect(sortCheckGood.exitCode == 0)

        _ = await session.run("printf 'b\\na' > unsorted.txt")
        let sortCheckBad = await session.run("sort -c unsorted.txt")
        #expect(sortCheckBad.exitCode == 1)
        #expect(sortCheckBad.stderrString.contains("not sorted"))

        let uniqIgnoreCase = await session.run("printf 'Foo\\nfoo\\nBar' | uniq -i -c")
        #expect(uniqIgnoreCase.exitCode == 0)
        #expect(uniqIgnoreCase.stdoutString == "2 Foo\n1 Bar\n")

        let cutCharacters = await session.run("printf 'abcdef\\nxy' | cut -c 2-3,5-")
        #expect(cutCharacters.exitCode == 0)
        #expect(cutCharacters.stdoutString == "bcef\ny\n")

        let cutFieldsDefault = await session.run("printf 'a,b\\nplain' | cut -d , -f 2")
        #expect(cutFieldsDefault.exitCode == 0)
        #expect(cutFieldsDefault.stdoutString == "b\nplain\n")

        let cutFieldsSuppress = await session.run("printf 'a,b\\nplain' | cut -s -d , -f 2")
        #expect(cutFieldsSuppress.exitCode == 0)
        #expect(cutFieldsSuppress.stdoutString == "b\n")

        let trTranslate = await session.run("printf 'abc\\n' | tr 'a-c' 'x-z'")
        #expect(trTranslate.exitCode == 0)
        #expect(trTranslate.stdoutString == "xyz\n")

        let trDelete = await session.run("printf 'aabbcc\\n' | tr -d b")
        #expect(trDelete.exitCode == 0)
        #expect(trDelete.stdoutString == "aacc\n")

        let trPosixClasses = await session.run("printf 'hi\\n' | tr '[:lower:]' '[:upper:]'")
        #expect(trPosixClasses.exitCode == 0)
        #expect(trPosixClasses.stdoutString == "HI\n")

        let trSqueeze = await session.run("printf 'aaabbbcc\\n' | tr -s ab")
        #expect(trSqueeze.exitCode == 0)
        #expect(trSqueeze.stdoutString == "abcc\n")

        let trComplementDelete = await session.run("printf 'abc123\\n' | tr -cd '0-9\\n'")
        #expect(trComplementDelete.exitCode == 0)
        #expect(trComplementDelete.stdoutString == "123\n")
    }

    @Test("printf base64 and digest commands")
    func printfBase64AndDigestCommands() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let printf = await session.run("printf 'hello %s %d\\n' world 7")
        #expect(printf.exitCode == 0)
        #expect(printf.stdoutString == "hello world 7\n")

        let encoded = await session.run("printf hello | base64")
        #expect(encoded.exitCode == 0)
        #expect(encoded.stdoutString == "aGVsbG8=\n")

        let decoded = await session.run("printf aGVsbG8= | base64 -d")
        #expect(decoded.exitCode == 0)
        #expect(decoded.stdoutString == "hello")

        let sha256 = await session.run("printf hello | sha256sum")
        #expect(sha256.exitCode == 0)
        #expect(sha256.stdoutString == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824  -\n")

        let sha1 = await session.run("printf hello | sha1sum")
        #expect(sha1.exitCode == 0)
        #expect(sha1.stdoutString == "aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d  -\n")

        let md5 = await session.run("printf hello | md5sum")
        #expect(md5.exitCode == 0)
        #expect(md5.stdoutString == "5d41402abc4b2a76b9719d911017c592  -\n")
    }

    @Test("chmod file and tree commands")
    func chmodFileAndTreeCommands() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        _ = await session.run("mkdir -p docs/nested")
        _ = await session.run("echo hi > docs/nested/note.txt")

        let chmod = await session.run("chmod 600 docs/nested/note.txt")
        #expect(chmod.exitCode == 0)

        let stat = await session.run("stat docs/nested/note.txt")
        #expect(stat.exitCode == 0)
        #expect(stat.stdoutString.contains("Mode: 600"))

        let file = await session.run("file docs/nested/note.txt")
        #expect(file.exitCode == 0)
        #expect(file.stdoutString.contains("ASCII text"))

        let tree = await session.run("tree docs")
        #expect(tree.exitCode == 0)
        #expect(tree.stdoutString.contains("docs\n"))
        #expect(tree.stdoutString.contains("  nested\n"))
        #expect(tree.stdoutString.contains("    note.txt\n"))
    }

    @Test("hostname and whoami commands")
    func hostnameAndWhoamiCommands() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let hostname = await session.run("hostname")
        #expect(hostname.exitCode == 0)
        #expect(!hostname.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let whoami = await session.run("whoami")
        #expect(whoami.exitCode == 0)
        #expect(whoami.stdoutString == "user\n")
    }

    @Test("time and timeout commands")
    func timeAndTimeoutCommands() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let timed = await session.run("time echo hi")
        #expect(timed.exitCode == 0)
        #expect(timed.stdoutString == "hi\n")
        #expect(timed.stderrString.contains("real "))

        let timeout = await session.run("timeout 0.01 sleep 0.2")
        #expect(timeout.exitCode == 124)
        #expect(timeout.stderrString.contains("timed out"))
    }

    @Test("background jobs can be listed and foregrounded")
    func backgroundJobsCanBeListedAndForegrounded() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let launched = await session.run("sleep 0.05 &")
        #expect(launched.exitCode == 0)
        #expect(launched.stdoutString.contains("[1]"))

        let jobs = await session.run("jobs")
        #expect(jobs.exitCode == 0)
        #expect(jobs.stdoutString.contains("[1]"))
        #expect(jobs.stdoutString.contains("sleep 0.05"))

        let foregrounded = await session.run("fg %1")
        #expect(foregrounded.exitCode == 0)

        let jobsAfter = await session.run("jobs")
        #expect(jobsAfter.exitCode == 0)
        #expect(jobsAfter.stdoutString.isEmpty)
    }

    @Test("foreground and wait return background output and status")
    func foregroundAndWaitReturnBackgroundOutputAndStatus() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let echoed = await session.run("echo hi &")
        #expect(echoed.exitCode == 0)

        let fg = await session.run("fg")
        #expect(fg.exitCode == 0)
        #expect(fg.stdoutString == "hi\n")

        _ = await session.run("timeout 0.01 sleep 0.05 &")
        let waited = await session.run("wait")
        #expect(waited.exitCode == 124)

        let missing = await session.run("wait %1")
        #expect(missing.exitCode == 127)
        #expect(missing.stderrString.contains("no such job"))
    }

    @Test("last background pid expansion and ps lookup")
    func lastBackgroundPIDExpansionAndPSLookup() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let launched = await session.run("sleep 0.05 & echo $!")
        #expect(launched.exitCode == 0)

        let lines = launched.stdoutString
            .split(separator: "\n")
            .map(String.init)
        #expect(lines.count >= 2)
        #expect(lines[0].contains("[1]"))

        guard let pid = Int(lines[1]) else {
            Issue.record("expected numeric pseudo pid in $! output")
            return
        }

        let ps = await session.run("ps -p \(pid)")
        #expect(ps.exitCode == 0)
        #expect(ps.stdoutString.contains("PID JOB STAT COMMAND"))
        #expect(ps.stdoutString.contains("sleep 0.05"))
        #expect(ps.stdoutString.contains("\(pid)"))
    }

    @Test("kill by pid and job spec")
    func killByPIDAndJobSpec() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let launched = await session.run("sleep 5 &")
        #expect(launched.exitCode == 0)

        let pieces = launched.stdoutString
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .map(String.init)
        guard pieces.count >= 2, let pid = Int(pieces[1]) else {
            Issue.record("expected launch output to include pseudo pid")
            return
        }

        let killByPID = await session.run("kill \(pid)")
        #expect(killByPID.exitCode == 0)

        let waited = await session.run("wait %1")
        #expect(waited.exitCode == 143)

        let relaunched = await session.run("sleep 5 &")
        #expect(relaunched.exitCode == 0)

        let relaunchPieces = relaunched.stdoutString
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .map(String.init)
        guard relaunchPieces.count >= 2 else {
            Issue.record("expected second launch output to include job id and pseudo pid")
            return
        }

        let rawJobToken = relaunchPieces[0]
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard let jobID = Int(rawJobToken) else {
            Issue.record("expected second launch output to include numeric job id")
            return
        }

        let killByJob = await session.run("kill %\(jobID)")
        #expect(killByJob.exitCode == 0)

        let waitJob = await session.run("wait %\(jobID)")
        #expect(waitJob.exitCode == 143)

        let signals = await session.run("kill -l")
        #expect(signals.exitCode == 0)
        #expect(signals.stdoutString.contains("TERM"))
    }

    @Test("diff command shows differences and status")
    func diffCommandShowsDifferencesAndStatus() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        _ = await session.run("printf 'one\\ntwo\\n' > left.txt")
        _ = await session.run("printf 'one\\nchanged\\n' > right.txt")

        let changed = await session.run("diff left.txt right.txt")
        #expect(changed.exitCode == 1)
        #expect(changed.stdoutString.contains("--- left.txt"))
        #expect(changed.stdoutString.contains("+++ right.txt"))
        #expect(changed.stdoutString.contains("-two"))
        #expect(changed.stdoutString.contains("+changed"))

        let same = await session.run("diff left.txt left.txt")
        #expect(same.exitCode == 0)
        #expect(same.stdoutString.isEmpty)
    }

    @Test("rg awk and sed commands")
    func rgAwkAndSedCommands() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        _ = await session.run("mkdir -p logs")
        _ = await session.run("printf 'hello\\nworld\\n' > logs/app.txt")
        _ = await session.run("printf 'nope\\nhello again\\n' > logs/other.txt")

        let rg = await session.run("rg hello logs")
        #expect(rg.exitCode == 0)
        #expect(rg.stdoutString.contains("/home/user/logs/app.txt:hello"))
        #expect(rg.stdoutString.contains("/home/user/logs/other.txt:hello again"))

        let rgLineNumbers = await session.run("rg -n hello logs/app.txt")
        #expect(rgLineNumbers.exitCode == 0)
        #expect(rgLineNumbers.stdoutString == "logs/app.txt:1:hello\n")

        let awk = await session.run("printf 'a b\\nc d\\n' | awk '{print $2}'")
        #expect(awk.exitCode == 0)
        #expect(awk.stdoutString == "b\nd\n")

        let awkFiltered = await session.run("printf 'a b\\nc d\\n' | awk '/c/ {print $1}'")
        #expect(awkFiltered.exitCode == 0)
        #expect(awkFiltered.stdoutString == "c\n")

        let sedSingle = await session.run("printf 'foo foo\\n' | sed 's/foo/bar/'")
        #expect(sedSingle.exitCode == 0)
        #expect(sedSingle.stdoutString == "bar foo\n")

        let sedGlobal = await session.run("printf 'foo foo\\n' | sed 's/foo/bar/g'")
        #expect(sedGlobal.exitCode == 0)
        #expect(sedGlobal.stdoutString == "bar bar\n")
    }

    @Test("grep and rg high-value flags")
    func grepAndRgHighValueFlags() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        _ = await session.run("mkdir -p corpus .hidden")
        _ = await session.run("printf 'hello\\nhello world\\nnope\\n' > corpus/a.txt")
        _ = await session.run("printf 'needle\\nHELLO\\n' > corpus/b.md")
        _ = await session.run("printf 'hello\\n' > corpus/code.swift")
        _ = await session.run("printf 'secret hello\\n' > .hidden/secret.txt")
        _ = await session.run("printf 'hello\\nneedle\\n' > patterns.txt")

        let grepRegex = await session.run("grep -E 'h.llo' corpus/a.txt")
        #expect(grepRegex.exitCode == 0)
        #expect(grepRegex.stdoutString.contains("hello\n"))

        let grepFixed = await session.run("grep -F 'h.llo' corpus/a.txt")
        #expect(grepFixed.exitCode == 1)

        let grepOnly = await session.run("grep -o -n 'hello' corpus/a.txt")
        #expect(grepOnly.exitCode == 0)
        #expect(grepOnly.stdoutString == "1:hello\n2:hello\n")

        let grepCount = await session.run("grep -c hello corpus/a.txt")
        #expect(grepCount.exitCode == 0)
        #expect(grepCount.stdoutString == "2\n")

        let grepFilesWithMatch = await session.run("grep -l hello corpus/a.txt corpus/b.md")
        #expect(grepFilesWithMatch.exitCode == 0)
        #expect(grepFilesWithMatch.stdoutString == "corpus/a.txt\n")

        let grepFilesWithoutMatch = await session.run("grep -L hello corpus/a.txt corpus/b.md")
        #expect(grepFilesWithoutMatch.exitCode == 0)
        #expect(grepFilesWithoutMatch.stdoutString == "corpus/b.md\n")

        let grepWholeLine = await session.run("grep -x hello corpus/a.txt")
        #expect(grepWholeLine.exitCode == 0)
        #expect(grepWholeLine.stdoutString == "hello\n")

        let grepRecursive = await session.run("grep -r hello corpus")
        #expect(grepRecursive.exitCode == 0)
        #expect(grepRecursive.stdoutString.contains("/home/user/corpus/a.txt:hello"))
        #expect(grepRecursive.stdoutString.contains("/home/user/corpus/code.swift:hello"))

        let grepDirectoryError = await session.run("grep hello corpus")
        #expect(grepDirectoryError.exitCode == 2)
        #expect(grepDirectoryError.stderrString.contains("is a directory"))

        let rgPatternFiles = await session.run("rg -f patterns.txt -m 1 corpus/a.txt")
        #expect(rgPatternFiles.exitCode == 0)
        #expect(rgPatternFiles.stdoutString == "corpus/a.txt:hello\n")

        let rgWord = await session.run("rg -w hello corpus/a.txt")
        #expect(rgWord.exitCode == 0)
        #expect(rgWord.stdoutString.contains("corpus/a.txt:hello\n"))
        #expect(rgWord.stdoutString.contains("corpus/a.txt:hello world\n"))

        let rgLine = await session.run("rg -x hello corpus/a.txt")
        #expect(rgLine.exitCode == 0)
        #expect(rgLine.stdoutString == "corpus/a.txt:hello\n")

        let rgHiddenDefault = await session.run("rg hello .")
        #expect(rgHiddenDefault.exitCode == 0)
        #expect(!rgHiddenDefault.stdoutString.contains("/home/user/.hidden/secret.txt"))

        let rgNoIgnore = await session.run("rg --no-ignore hello .")
        #expect(rgNoIgnore.exitCode == 0)
        #expect(rgNoIgnore.stdoutString.contains("/home/user/.hidden/secret.txt:secret hello"))

        let rgTypeInclude = await session.run("rg hello -t swift corpus")
        #expect(rgTypeInclude.exitCode == 0)
        #expect(rgTypeInclude.stdoutString.contains("/home/user/corpus/code.swift:hello"))
        #expect(!rgTypeInclude.stdoutString.contains("/home/user/corpus/a.txt:"))

        let rgTypeExclude = await session.run("rg hello -T swift corpus")
        #expect(rgTypeExclude.exitCode == 0)
        #expect(!rgTypeExclude.stdoutString.contains("/home/user/corpus/code.swift:"))
        #expect(rgTypeExclude.stdoutString.contains("/home/user/corpus/a.txt:hello"))
    }

    @Test("gzip gunzip zcat zip unzip and tar commands")
    func gzipGunzipZcatZipUnzipAndTarCommands() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        _ = await session.run("printf 'hello\\n' > note.txt")

        let gzip = await session.run("gzip note.txt")
        #expect(gzip.exitCode == 0)

        let missingOriginal = await session.run("cat note.txt")
        #expect(missingOriginal.exitCode != 0)

        let zcat = await session.run("zcat note.txt.gz")
        #expect(zcat.exitCode == 0)
        #expect(zcat.stdoutString == "hello\n")

        let gunzip = await session.run("gunzip note.txt.gz")
        #expect(gunzip.exitCode == 0)

        let restored = await session.run("cat note.txt")
        #expect(restored.exitCode == 0)
        #expect(restored.stdoutString == "hello\n")

        _ = await session.run("mkdir -p pkg/sub")
        _ = await session.run("printf 'A\\n' > pkg/a.txt")
        _ = await session.run("printf 'B\\n' > pkg/sub/b.txt")

        let createTar = await session.run("tar -cf archive.tar pkg")
        #expect(createTar.exitCode == 0)

        let listTar = await session.run("tar -tf archive.tar")
        #expect(listTar.exitCode == 0)
        #expect(listTar.stdoutString.contains("pkg/\n"))
        #expect(listTar.stdoutString.contains("pkg/a.txt\n"))
        #expect(listTar.stdoutString.contains("pkg/sub/b.txt\n"))

        _ = await session.run("rm -r pkg")

        let extractTar = await session.run("tar -xf archive.tar")
        #expect(extractTar.exitCode == 0)

        let extractedA = await session.run("cat pkg/a.txt")
        #expect(extractedA.exitCode == 0)
        #expect(extractedA.stdoutString == "A\n")

        let createTgz = await session.run("tar -czf archive.tgz pkg")
        #expect(createTgz.exitCode == 0)

        _ = await session.run("rm -r pkg")

        let extractTgz = await session.run("tar -xzf archive.tgz")
        #expect(extractTgz.exitCode == 0)

        let extractedB = await session.run("cat pkg/sub/b.txt")
        #expect(extractedB.exitCode == 0)
        #expect(extractedB.stdoutString == "B\n")

        _ = await session.run("mkdir -p zipdir/sub")
        _ = await session.run("printf 'one\\n' > zipdir/one.txt")
        _ = await session.run("printf 'two\\n' > zipdir/sub/two.txt")

        let createZip = await session.run("zip -r bundle.zip zipdir")
        #expect(createZip.exitCode == 0)

        let listZip = await session.run("unzip -l bundle.zip")
        #expect(listZip.exitCode == 0)
        #expect(listZip.stdoutString.contains("zipdir/\n"))
        #expect(listZip.stdoutString.contains("zipdir/one.txt\n"))
        #expect(listZip.stdoutString.contains("zipdir/sub/two.txt\n"))

        let printZip = await session.run("unzip -p bundle.zip zipdir/sub/two.txt")
        #expect(printZip.exitCode == 0)
        #expect(printZip.stdoutString == "two\n")

        _ = await session.run("rm -r zipdir")

        let extractZip = await session.run("unzip bundle.zip")
        #expect(extractZip.exitCode == 0)

        let extractedZip = await session.run("cat zipdir/sub/two.txt")
        #expect(extractedZip.exitCode == 0)
        #expect(extractedZip.stdoutString == "two\n")
    }

    @Test("xargs command parity chunk")
    func xargsCommandParityChunk() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        _ = await session.run("printf 'content1' > file1.txt")
        _ = await session.run("printf 'content2' > file2.txt")

        let defaultEcho = await session.run("echo 'a b c' | xargs")
        #expect(defaultEcho.exitCode == 0)
        #expect(defaultEcho.stdoutString == "a b c\n")

        let withCommand = await session.run("echo 'file1.txt file2.txt' | xargs cat")
        #expect(withCommand.exitCode == 0)
        #expect(withCommand.stdoutString == "content1content2")

        let batched = await session.run("echo 'a b c d' | xargs -n 2 echo")
        #expect(batched.exitCode == 0)
        #expect(batched.stdoutString == "a b\nc d\n")

        let replaced = await session.run("printf 'a\\nb\\nc' | xargs -I {} echo file-{}")
        #expect(replaced.exitCode == 0)
        #expect(replaced.stdoutString == "file-a\nfile-b\nfile-c\n")

        let nullSeparatedInput = Data("file1".utf8) + Data([0]) + Data("file2".utf8) + Data([0]) + Data("file3".utf8)
        let nullSeparated = await session.run("xargs -0 echo", stdin: nullSeparatedInput)
        #expect(nullSeparated.exitCode == 0)
        #expect(nullSeparated.stdoutString == "file1 file2 file3\n")

        let delimited = await session.run("echo 'hello world:foo bar:test' | xargs -d : -n 1 echo")
        #expect(delimited.exitCode == 0)
        #expect(delimited.stdoutString == "hello world\nfoo bar\ntest\n")

        let verbose = await session.run("echo 'x y' | xargs -t echo")
        #expect(verbose.exitCode == 0)
        #expect(verbose.stdoutString == "x y\n")
        #expect(verbose.stderrString.contains("echo x y\n"))

        let noRunIfEmpty = await session.run("echo '' | xargs -r echo nonempty")
        #expect(noRunIfEmpty.exitCode == 0)
        #expect(noRunIfEmpty.stdoutString.isEmpty)

        let prefixed = await session.run("echo 'a b c' | xargs echo prefix")
        #expect(prefixed.exitCode == 0)
        #expect(prefixed.stdoutString == "prefix a b c\n")

        _ = await session.run("mkdir -p project/data")
        _ = await session.run("printf 'A' > project/data/a.txt")
        _ = await session.run("printf 'B' > project/data/b.txt")

        let respectsCwd = await session.run("cd project && printf 'data/a.txt\\ndata/b.txt' | xargs -d '\\n' cat")
        #expect(respectsCwd.exitCode == 0)
        #expect(respectsCwd.stdoutString == "AB")

        let parallel = await session.run("echo '1 2 3' | xargs -P 2 -n 1 echo item:")
        #expect(parallel.exitCode == 0)
        #expect(parallel.stdoutString == "item: 1\nitem: 2\nitem: 3\n")

        let missingFile = await session.run("echo 'missing.txt' | xargs cat")
        #expect(missingFile.exitCode != 0)
        #expect(missingFile.stderrString.contains("missing.txt"))

        let maxLines = await session.run("printf 'alpha beta\\ngamma delta\\nepsilon zeta\\n' | xargs -L 2 echo")
        #expect(maxLines.exitCode == 0)
        #expect(maxLines.stdoutString == "alpha beta gamma delta\nepsilon zeta\n")

        let maxLinesLong = await session.run("printf 'line one\\nline two\\n' | xargs --max-lines=1 echo")
        #expect(maxLinesLong.exitCode == 0)
        #expect(maxLinesLong.stdoutString == "line one\nline two\n")

        let eofShort = await session.run("printf 'one\\ntwo\\nSTOP\\nthree\\n' | xargs -E STOP echo")
        #expect(eofShort.exitCode == 0)
        #expect(eofShort.stdoutString == "one two\n")

        let eofLong = await session.run("printf 'x\\ny\\nEND\\nz\\n' | xargs --eof=END echo")
        #expect(eofLong.exitCode == 0)
        #expect(eofLong.stdoutString == "x y\n")
    }

    @Test("jq yq and xan commands")
    func jqYqAndXanCommands() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let jqRaw = await session.run("printf '{\"user\":{\"name\":\"zac\",\"roles\":[\"dev\",\"ops\"]}}' | jq -r '.user.name'")
        #expect(jqRaw.exitCode == 0)
        #expect(jqRaw.stdoutString == "zac\n")

        let jqArray = await session.run("printf '{\"user\":{\"roles\":[\"dev\",\"ops\"]}}' | jq '.user.roles[]'")
        #expect(jqArray.exitCode == 0)
        #expect(jqArray.stdoutString.contains("\"dev\""))
        #expect(jqArray.stdoutString.contains("\"ops\""))

        let yqValue = await session.run("printf 'app:\\n  name: Bash\\n  ports:\\n    - 8080\\n    - 9090\\n' | yq '.app.ports[1]'")
        #expect(yqValue.exitCode == 0)
        #expect(yqValue.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "9090")

        let yqRaw = await session.run("printf 'app:\\n  name: Bash\\n' | yq -r '.app.name'")
        #expect(yqRaw.exitCode == 0)
        #expect(yqRaw.stdoutString == "Bash\n")

        _ = await session.run("printf 'name,age,city\\nalice,30,LA\\nbob,25,SF\\n' > people.csv")

        let xanCount = await session.run("xan count people.csv")
        #expect(xanCount.exitCode == 0)
        #expect(xanCount.stdoutString == "2\n")

        let xanHeaders = await session.run("xan headers people.csv")
        #expect(xanHeaders.exitCode == 0)
        #expect(xanHeaders.stdoutString.contains("1,name\n"))
        #expect(xanHeaders.stdoutString.contains("3,city\n"))

        let xanSelect = await session.run("xan select name,city people.csv")
        #expect(xanSelect.exitCode == 0)
        #expect(xanSelect.stdoutString == "name,city\nalice,LA\nbob,SF\n")

        let xanFilter = await session.run("xan filter city SF people.csv")
        #expect(xanFilter.exitCode == 0)
        #expect(xanFilter.stdoutString == "name,age,city\nbob,25,SF\n")
    }

    @Test("jq and yq query engine phase 1")
    func jqAndYqQueryEnginePhase1() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let jqSelect = await session.run("printf '[{\"n\":1},{\"n\":3}]' | jq '.[] | select(.n > 1) | .n'")
        #expect(jqSelect.exitCode == 0)
        #expect(jqSelect.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "3")

        let jqCoalesce = await session.run("printf '{}' | jq '.missing // \"fallback\"'")
        #expect(jqCoalesce.exitCode == 0)
        #expect(jqCoalesce.stdoutString.contains("\"fallback\""))

        let jqBool = await session.run("printf '{\"a\":true,\"b\":false}' | jq '.a and .b'")
        #expect(jqBool.exitCode == 0)
        #expect(jqBool.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "false")

        let jqNullInput = await session.run("jq -n '1 == 1'")
        #expect(jqNullInput.exitCode == 0)
        #expect(jqNullInput.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "true")

        let jqJoin = await session.run("printf '[1,2]' | jq -j '.[]'")
        #expect(jqJoin.exitCode == 0)
        #expect(jqJoin.stdoutString == "12")

        _ = await session.run("printf '{\"b\":1,\"a\":2}' > obj.json")
        let jqSorted = await session.run("jq -c -S '.' obj.json")
        #expect(jqSorted.exitCode == 0)
        #expect(jqSorted.stdoutString == "{\"a\":2,\"b\":1}\n")

        _ = await session.run("printf '{\"id\":1}' > one.json")
        _ = await session.run("printf '{\"id\":2}' > two.json")
        let jqSlurp = await session.run("jq -s '.[] | .id' one.json two.json")
        #expect(jqSlurp.exitCode == 0)
        #expect(jqSlurp.stdoutString == "1\n2\n")

        let jqExitFalse = await session.run("jq -e -n 'false'")
        #expect(jqExitFalse.exitCode == 1)

        let jqExitNoOutput = await session.run("printf '[1]' | jq -e '.[] | select(. > 3)'")
        #expect(jqExitNoOutput.exitCode == 4)

        let yqSelect = await session.run("printf 'items:\\n  - n: 1\\n  - n: 3\\n' | yq '.items[] | select(.n >= 2) | .n'")
        #expect(yqSelect.exitCode == 0)
        #expect(yqSelect.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "3")

        let yqExit = await session.run("yq -e -n 'null'")
        #expect(yqExit.exitCode == 1)
    }

    @Test("curl command basic data and file usage")
    func curlCommandBasicDataAndFileUsage() async throws {
        let (session, root) = try await TestSupport.makeSession(networkPolicy: .unrestricted)
        defer { TestSupport.removeDirectory(root) }

        let dataURL = await session.run("curl data:text/plain,hello%20world")
        #expect(dataURL.exitCode == 0)
        #expect(dataURL.stdoutString == "hello world")

        let headDataURL = await session.run("curl -I data:text/plain,hello%20world")
        #expect(headDataURL.exitCode == 0)
        #expect(headDataURL.stdoutString.contains("HTTP/1.1 200"))
        #expect(!headDataURL.stdoutString.contains("hello world"))

        let writeOut = await session.run("curl -w '\\n%{http_code}\\n' data:text/plain,ok")
        #expect(writeOut.exitCode == 0)
        #expect(writeOut.stdoutString.hasSuffix("\n200\n"))

        let writeOutFields = await session.run("curl -s -w ' %{content_type} %{size_download} %{url_effective}' data:text/plain,ok")
        #expect(writeOutFields.exitCode == 0)
        #expect(writeOutFields.stdoutString.contains("text/plain"))
        #expect(writeOutFields.stdoutString.contains("2"))
        #expect(writeOutFields.stdoutString.contains("data:text/plain,ok"))

        let cookieJarDataURL = await session.run("curl -c cookie-jar.txt data:text/plain,ok")
        #expect(cookieJarDataURL.exitCode == 0)

        let cookieJarFile = await session.run("cat cookie-jar.txt")
        #expect(cookieJarFile.exitCode == 0)
        #expect(cookieJarFile.stdoutString.contains("Netscape HTTP Cookie File"))

        let outputFile = await session.run("curl -o fetched.txt data:text/plain,payload")
        #expect(outputFile.exitCode == 0)
        #expect(outputFile.stdoutString.isEmpty)

        let fetched = await session.run("cat fetched.txt")
        #expect(fetched.exitCode == 0)
        #expect(fetched.stdoutString == "payload")

        let outputWithWriteOut = await session.run("curl -o fetched2.txt -w '%{size_download}' data:text/plain,payload")
        #expect(outputWithWriteOut.exitCode == 0)
        #expect(outputWithWriteOut.stdoutString == "7")

        let fetched2 = await session.run("cat fetched2.txt")
        #expect(fetched2.exitCode == 0)
        #expect(fetched2.stdoutString == "payload")

        let hostReadBeforeSandboxFile = await session.run("curl file:///etc/hosts")
        #expect(hostReadBeforeSandboxFile.exitCode != 0)

        _ = await session.run("mkdir -p /etc")
        _ = await session.run("printf 'sandbox-hosts\\n' > /etc/hosts")

        let fileURL = await session.run("curl file:///etc/hosts")
        #expect(fileURL.exitCode == 0)
        #expect(fileURL.stdoutString == "sandbox-hosts\n")

        let traversalFileURL = await session.run("curl file:///../../../../etc/hosts")
        #expect(traversalFileURL.exitCode == 0)
        #expect(traversalFileURL.stdoutString == "sandbox-hosts\n")

        let encodedTraversalFileURL = await session.run("curl file:///%2e%2e/%2e%2e/%2e%2e/%2e%2e/etc/hosts")
        #expect(encodedTraversalFileURL.exitCode == 0)
        #expect(encodedTraversalFileURL.stdoutString == "sandbox-hosts\n")

        let remoteName = await session.run("curl -O file:///etc/hosts")
        #expect(remoteName.exitCode == 0)
        #expect(remoteName.stdoutString.isEmpty)

        let remoteNamedFile = await session.run("cat hosts")
        #expect(remoteNamedFile.exitCode == 0)
        #expect(remoteNamedFile.stdoutString == "sandbox-hosts\n")

        let combinedFlags = await session.run("curl -sSfL data:text/plain,ok")
        #expect(combinedFlags.exitCode == 0)
        #expect(combinedFlags.stdoutString == "ok")

        let requestEquals = await session.run("curl --request=HEAD data:text/plain,ok")
        #expect(requestEquals.exitCode == 0)
        #expect(requestEquals.stdoutString.isEmpty)

        let requestAttached = await session.run("curl -XHEAD data:text/plain,ok")
        #expect(requestAttached.exitCode == 0)
        #expect(requestAttached.stdoutString.isEmpty)

        let outputAttached = await session.run("curl -oattached.txt data:text/plain,ok")
        #expect(outputAttached.exitCode == 0)
        let attachedFile = await session.run("cat attached.txt")
        #expect(attachedFile.exitCode == 0)
        #expect(attachedFile.stdoutString == "ok")

        let connectTimeout = await session.run("curl --connect-timeout 1 data:text/plain,ok")
        #expect(connectTimeout.exitCode == 0)

        let maxRedirs = await session.run("curl --max-redirs 5 data:text/plain,ok")
        #expect(maxRedirs.exitCode == 0)

        let dataRawLiteral = await session.run("curl --data-raw @literal data:text/plain,ok")
        #expect(dataRawLiteral.exitCode == 0)
        #expect(dataRawLiteral.stdoutString == "ok")

        let formSimple = await session.run("curl -F name=value data:text/plain,ok")
        #expect(formSimple.exitCode == 0)
        #expect(formSimple.stdoutString == "ok")

        let missingUpload = await session.run("curl -T missing-upload.bin data:text/plain,ok")
        #expect(missingUpload.exitCode != 0)
        #expect(missingUpload.stderrString.contains("missing-upload.bin"))

        let missingFormFile = await session.run("curl -F file=@missing-form.bin data:text/plain,ok")
        #expect(missingFormFile.exitCode != 0)
        #expect(missingFormFile.stderrString.contains("missing-form.bin"))

        let authAndHeaderFlags = await session.run("curl -A Agent/1.0 -e https://example.com -u user:pass -b session=abc data:text/plain,ok")
        #expect(authAndHeaderFlags.exitCode == 0)
        #expect(authAndHeaderFlags.stdoutString == "ok")

        let missingCookieFile = await session.run("curl -b missing-cookies.txt https://example.com")
        #expect(missingCookieFile.exitCode == 26)
        #expect(missingCookieFile.stderrString.contains("missing-cookies.txt"))

        let remoteFileHost = await session.run("curl file://evil.com/etc/hosts")
        #expect(remoteFileHost.exitCode != 0)
        #expect(remoteFileHost.stderrString.contains("remote file host not supported"))

        let unsupported = await session.run("curl ftp://example.com/data")
        #expect(unsupported.exitCode != 0)
        #expect(unsupported.stderrString.contains("unsupported URL scheme"))
    }

    @Test("curl permission handler can deny outbound http requests")
    func curlPermissionHandlerCanDenyOutboundHTTPRequests() async throws {
        let probe = PermissionProbe()
        let (session, root) = try await TestSupport.makeSession(
            networkPolicy: .unrestricted,
            permissionHandler: { request in
                await probe.record(request)
                return .deny(message: "network access denied")
            }
        )
        defer { TestSupport.removeDirectory(root) }

        let result = await session.run("curl http://127.0.0.1:1")
        #expect(result.exitCode == 1)
        #expect(result.stderrString == "curl: network access denied\n")

        let requests = await probe.snapshot()
        #expect(requests.count == 1)
        #expect(requests[0].command == "curl")
        switch requests[0].kind {
        case let .network(network):
            #expect(network.url == "http://127.0.0.1:1")
            #expect(network.method == "GET")
        }
    }

    @Test("curl permission handler allow once does not persist")
    func curlPermissionHandlerAllowOnceDoesNotPersist() async throws {
        let probe = PermissionProbe()
        let (session, root) = try await TestSupport.makeSession(
            networkPolicy: .unrestricted,
            permissionHandler: { request in
                await probe.record(request)
                return .allow
            }
        )
        defer { TestSupport.removeDirectory(root) }

        let first = await session.run("curl --connect-timeout 0.1 http://127.0.0.1:1")
        let second = await session.run("curl --connect-timeout 0.1 http://127.0.0.1:1")

        #expect(first.exitCode != 0)
        #expect(second.exitCode != 0)

        let requests = await probe.snapshot()
        #expect(requests.count == 2)
    }

    @Test("curl permission handler can allow for session")
    func curlPermissionHandlerCanAllowForSession() async throws {
        let probe = PermissionProbe()
        let (session, root) = try await TestSupport.makeSession(
            networkPolicy: .unrestricted,
            permissionHandler: { request in
                await probe.record(request)
                return .allowForSession
            }
        )
        defer { TestSupport.removeDirectory(root) }

        let first = await session.run("curl --connect-timeout 0.1 http://127.0.0.1:1")
        let second = await session.run("curl --connect-timeout 0.1 http://127.0.0.1:1")

        #expect(first.exitCode != 0)
        #expect(second.exitCode != 0)

        let requests = await probe.snapshot()
        #expect(requests.count == 1)
    }

    @Test("curl permission handler is skipped for non-http urls")
    func curlPermissionHandlerIsSkippedForNonHTTPURLs() async throws {
        let probe = PermissionProbe()
        let (session, root) = try await TestSupport.makeSession(
            networkPolicy: .unrestricted,
            permissionHandler: { request in
                await probe.record(request)
                return .deny(message: "network access denied")
            }
        )
        defer { TestSupport.removeDirectory(root) }

        let result = await session.run("curl data:text/plain,ok")
        #expect(result.exitCode == 0)
        #expect(result.stdoutString == "ok")

        let requests = await probe.snapshot()
        #expect(requests.isEmpty)
    }

    @Test("curl network policy can deny private ranges")
    func curlNetworkPolicyCanDenyPrivateRanges() async throws {
        let (session, root) = try await TestSupport.makeSession(
            networkPolicy: NetworkPolicy(
                allowsHTTPRequests: true,
                denyPrivateRanges: true
            )
        )
        defer { TestSupport.removeDirectory(root) }

        let result = await session.run("curl http://127.0.0.1:1")
        #expect(result.exitCode == 1)
        #expect(result.stderrString.contains("private network host"))
    }

    @Test("curl network policy can deny urls outside allowlist")
    func curlNetworkPolicyCanDenyURLsOutsideAllowlist() async throws {
        let (session, root) = try await TestSupport.makeSession(
            networkPolicy: NetworkPolicy(
                allowsHTTPRequests: true,
                allowedURLPrefixes: ["https://api.example.com/"]
            )
        )
        defer { TestSupport.removeDirectory(root) }

        let result = await session.run("curl https://example.com")
        #expect(result.exitCode == 1)
        #expect(result.stderrString.contains("not in the network allowlist"))
    }

    @Test("curl blocks outbound http by default")
    func curlBlocksOutboundHTTPByDefault() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let result = await session.run("curl https://example.com")
        #expect(result.exitCode == 1)
        #expect(result.stderrString.contains("outbound HTTP(S) access is disabled"))
    }

    @Test("curl allowlist matches path boundaries instead of raw prefixes")
    func curlAllowlistMatchesPathBoundariesInsteadOfRawPrefixes() async throws {
        let (session, root) = try await TestSupport.makeSession(
            networkPolicy: NetworkPolicy(
                allowsHTTPRequests: true,
                allowedURLPrefixes: ["https://api.example.com/v1"]
            )
        )
        defer { TestSupport.removeDirectory(root) }

        let result = await session.run("curl https://api.example.com/v10/status")
        #expect(result.exitCode == 1)
        #expect(result.stderrString.contains("not in the network allowlist"))
    }

    @Test("execution limits cap command count")
    func executionLimitsCapCommandCount() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let result = await session.run(
            "echo one; echo two",
            options: RunOptions(
                executionLimits: ExecutionLimits(maxCommandCount: 1)
            )
        )
        #expect(result.exitCode == 2)
        #expect(result.stderrString.contains("maximum command count"))
    }

    @Test("execution limits cap loop iterations")
    func executionLimitsCapLoopIterations() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let result = await session.run(
            "while true; do echo tick; done",
            options: RunOptions(
                executionLimits: ExecutionLimits(maxLoopIterations: 3)
            )
        )
        #expect(result.exitCode == 2)
        #expect(result.stderrString.contains("while: exceeded max iterations"))
    }

    @Test("execution can be cancelled with run option")
    func executionCanBeCancelledWithRunOption() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let result = await session.run(
            "while true; do echo tick; done",
            options: RunOptions(
                cancellationCheck: { true }
            )
        )
        #expect(result.exitCode == 130)
        #expect(result.stderrString.contains("execution cancelled"))
    }

    @Test("html-to-markdown command parity chunk")
    func htmlToMarkdownCommandParityChunk() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let heading = await session.run("echo '<h1>Hello World</h1>' | html-to-markdown")
        #expect(heading.exitCode == 0)
        #expect(heading.stdoutString == "# Hello World\n")

        let paragraph = await session.run("echo '<p>First paragraph.</p><p>Second paragraph.</p>' | html-to-markdown")
        #expect(paragraph.exitCode == 0)
        #expect(paragraph.stdoutString.contains("First paragraph."))
        #expect(paragraph.stdoutString.contains("Second paragraph."))

        let link = await session.run("echo '<a href=\"https://example.com\">Click here</a>' | html-to-markdown")
        #expect(link.exitCode == 0)
        #expect(link.stdoutString == "[Click here](https://example.com)\n")

        let styles = await session.run("echo '<strong>bold</strong> and <em>italic</em>' | html-to-markdown")
        #expect(styles.exitCode == 0)
        #expect(styles.stdoutString == "**bold** and _italic_\n")

        let unordered = await session.run("echo '<ul><li>One</li><li>Two</li></ul>' | html-to-markdown -b '*'")
        #expect(unordered.exitCode == 0)
        #expect(unordered.stdoutString.contains("* One"))
        #expect(unordered.stdoutString.contains("* Two"))

        let ordered = await session.run("echo '<ol><li>First</li><li>Second</li></ol>' | html-to-markdown")
        #expect(ordered.exitCode == 0)
        #expect(ordered.stdoutString.contains("1. First"))
        #expect(ordered.stdoutString.contains("2. Second"))

        let fenced = await session.run("echo '<pre><code>const x = 1;</code></pre>' | html-to-markdown -c '~~~'")
        #expect(fenced.exitCode == 0)
        #expect(fenced.stdoutString.contains("~~~"))
        #expect(fenced.stdoutString.contains("const x = 1;"))

        let hr = await session.run("echo '<hr>' | html-to-markdown -r '***'")
        #expect(hr.exitCode == 0)
        #expect(hr.stdoutString.contains("***"))

        let setext = await session.run("echo '<h1>Title</h1>' | html-to-markdown --heading-style setext")
        #expect(setext.exitCode == 0)
        #expect(setext.stdoutString.contains("Title"))
        #expect(setext.stdoutString.contains("==="))

        _ = await session.run("printf '<h2>From File</h2>' > page.html")
        let fromFile = await session.run("html-to-markdown page.html")
        #expect(fromFile.exitCode == 0)
        #expect(fromFile.stdoutString == "## From File\n")

        let missingFile = await session.run("html-to-markdown missing.html")
        #expect(missingFile.exitCode == 1)
        #expect(missingFile.stderrString.contains("No such file or directory"))

        let stripsScriptAndStyle = await session.run(
            "echo '<style>.red{color:red;}</style><h1>Title</h1><script>alert(1);</script><p>Text</p>' | html-to-markdown"
        )
        #expect(stripsScriptAndStyle.exitCode == 0)
        #expect(stripsScriptAndStyle.stdoutString.contains("# Title"))
        #expect(stripsScriptAndStyle.stdoutString.contains("Text"))
        #expect(!stripsScriptAndStyle.stdoutString.contains("alert"))
        #expect(!stripsScriptAndStyle.stdoutString.contains("color"))

        let nestedList = await session.run(
            "echo '<ul><li>Parent<ul><li>Child One</li><li>Child Two</li></ul></li><li>Sibling</li></ul>' | html-to-markdown"
        )
        #expect(nestedList.exitCode == 0)
        #expect(nestedList.stdoutString.contains("- Parent"))
        #expect(nestedList.stdoutString.contains("  - Child One"))
        #expect(nestedList.stdoutString.contains("  - Child Two"))
        #expect(nestedList.stdoutString.contains("- Sibling"))

        let table = await session.run(
            "echo '<table><thead><tr><th>Name</th><th>Age</th></tr></thead><tbody><tr><td>Alice</td><td>30</td></tr><tr><td>Bob</td><td>25</td></tr></tbody></table>' | html-to-markdown"
        )
        #expect(table.exitCode == 0)
        #expect(table.stdoutString.contains("| Name | Age |"))
        #expect(table.stdoutString.contains("| --- | --- |"))
        #expect(table.stdoutString.contains("| Alice | 30 |"))
        #expect(table.stdoutString.contains("| Bob | 25 |"))

        let tableNoHeaders = await session.run(
            "echo '<table><tr><td>Lang</td><td>Creator</td></tr><tr><td>Swift</td><td>Apple</td></tr></table>' | html-to-markdown"
        )
        #expect(tableNoHeaders.exitCode == 0)
        #expect(tableNoHeaders.stdoutString.contains("| Lang | Creator |"))
        #expect(tableNoHeaders.stdoutString.contains("| Swift | Apple |"))

        let empty = await session.run("echo '' | html-to-markdown")
        #expect(empty.exitCode == 0)
        #expect(empty.stdoutString.isEmpty)
    }
}

@Suite("Session Integration Timeouts", .serialized)
struct SessionIntegrationTimeoutTests {
    @Test("execution limits cap wall clock time")
    func executionLimitsCapWallClockTime() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let result = await session.run(
            "sleep 0.2",
            options: RunOptions(
                executionLimits: ExecutionLimits(maxWallClockDuration: 0.01)
            )
        )
        #expect(result.exitCode == 124)
        #expect(result.stderrString.contains("execution timed out"))
    }

    @Test("timeout excludes permission wait time")
    func timeoutExcludesPermissionWaitTime() async throws {
        let (session, root) = try await TestSupport.makeSession(
            networkPolicy: .unrestricted,
            permissionHandler: { _ in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                return .deny(message: "blocked after approval wait")
            }
        )
        defer { TestSupport.removeDirectory(root) }

        let result = await session.run("timeout 0.5 curl https://example.com")
        #expect(result.exitCode == 1)
        #expect(result.stderrString.contains("blocked after approval wait"))
        #expect(!result.stderrString.contains("timed out"))
    }

    @Test("wall clock limits exclude permission wait time")
    func wallClockLimitsExcludePermissionWaitTime() async throws {
        let (session, root) = try await TestSupport.makeSession(
            networkPolicy: .unrestricted,
            permissionHandler: { _ in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                return .deny(message: "blocked after approval wait")
            }
        )
        defer { TestSupport.removeDirectory(root) }

        let result = await session.run(
            "curl https://example.com",
            options: RunOptions(
                executionLimits: ExecutionLimits(maxWallClockDuration: 0.5)
            )
        )
        #expect(result.exitCode == 1)
        #expect(result.stderrString.contains("blocked after approval wait"))
        #expect(!result.stderrString.contains("execution timed out"))
    }
}

import Foundation
import FridayCore
import FridayIPC

// fridayctl — talk to the running Friday app over its local Unix socket.

let usage = """
fridayctl — send commands to Friday (the app must be running).

USAGE
  fridayctl [options] "Add buy milk to my Shopping reminders list"
  fridayctl [options] --tool reminders.create --args '{"title":"Buy milk","list":"Shopping"}'
  fridayctl [options] --confirm TOKEN | --cancel TOKEN | --choose TOKEN INDEX
  fridayctl [options] --tools | --status | --ping
  fridayctl [options] --say "what's on my calendar today?" [--speak]
  fridayctl [options] --voice recording.wav
  fridayctl [options] --synthesize "Jarvis, abre Notas" --output /tmp/abre-notas.wav [--language es]
  fridayctl [options] --transcript [N]

OPTIONS
  --language en|es     Language of the command and of the reply (default: automatic)
  --session NAME       Scope for "yes / cancel / 2" style replies (default: one per invocation)
  --allow-duplicate    Run even if an identical creation just ran
  --json               Print the raw JSON response
  --socket PATH        Socket path (default: ~/Library/Application Support/Friday/friday.sock)
  --timeout SECONDS    Give up after this long (default 120)
  --say                Run the words that follow through the voice assistant's pipeline (transcript, memory)
  --speak              With --say: also speak the reply aloud
  --voice FILE         Play FILE into the microphone pipeline as if spoken (wake word included) and report the turn
  --synthesize TEXT    Write TEXT as speech to --output FILE (no playback)
  --output FILE        Output WAV for --synthesize
  --transcript [N]     Print the last N (default 20) turns of the assistant's transcript
  -h, --help           Show this help

EXIT CODES
  0  the request succeeded        1  Friday answered but the action did not complete        2  could not reach Friday
"""

struct Options {
    var language: String?
    var session: String?
    var allowDuplicate = false
    var json = false
    var socket = JarvisPaths.socketFile().path
    var timeout: TimeInterval = 120
    var request = IPCRequest(type: .command)
    var words: [String] = []
}

/// Paths travel to the app, whose working directory is not ours: send them absolute.
func absolutePath(_ path: String) -> String {
    if path.hasPrefix("/") { return path }
    if path.hasPrefix("~") { return NSString(string: path).expandingTildeInPath }
    return FileManager.default.currentDirectoryPath + "/" + path
}

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func parse(_ arguments: [String]) -> Options {
    var options = Options()
    var iterator = arguments.makeIterator()
    func value(for flag: String) -> String {
        guard let next = iterator.next() else { fail("Missing value for \(flag).\n\n\(usage)") }
        return next
    }
    while let argument = iterator.next() {
        switch argument {
        case "-h", "--help": print(usage); exit(0)
        case "--language": options.language = value(for: argument)
        case "--session": options.session = value(for: argument)
        case "--allow-duplicate": options.allowDuplicate = true
        case "--json": options.json = true
        case "--socket": options.socket = value(for: argument)
        case "--timeout": options.timeout = TimeInterval(value(for: argument)) ?? 120
        case "--ping": options.request.type = .ping
        case "--tools": options.request.type = .tools
        case "--status": options.request.type = .status
        case "--say": options.request.type = .assistant
        case "--speak": options.request.speak = true
        case "--voice":
            options.request.type = .voice
            options.request.file = absolutePath(value(for: argument))
        case "--synthesize":
            options.request.type = .synthesize
            options.request.command = value(for: argument)
        case "--output": options.request.output = absolutePath(value(for: argument))
        case "--transcript":
            options.request.type = .transcript
            options.request.index = 20
        case "--tool":
            options.request.type = .tool
            options.request.tool = value(for: argument)
        case "--args":
            let text = value(for: argument)
            guard let object = try? JSONDecoder().decode(JSONObject.self, from: Data(text.utf8)) else { fail("--args must be a JSON object.") }
            options.request.arguments = object
        case "--confirm", "--cancel":
            options.request.type = .resolve
            options.request.token = value(for: argument)
            options.request.decision = argument == "--confirm" ? "confirm" : "cancel"
        case "--choose":
            options.request.type = .resolve
            options.request.token = value(for: argument)
            options.request.decision = "choose"
            guard let index = Int(value(for: argument)) else { fail("--choose needs a numeric INDEX (0-based).") }
            options.request.index = index
        default:
            if options.request.type == .transcript, let count = Int(argument) { options.request.index = count; continue }
            options.words.append(argument)
        }
    }
    if options.request.type == .command || options.request.type == .assistant {
        let text = options.words.joined(separator: " ")
        if text.isEmpty { fail(usage) }
        options.request.command = text
    }
    if options.request.type == .synthesize, options.request.output == nil { fail("--synthesize needs --output FILE.") }
    if options.request.type == .voice { options.timeout = max(options.timeout, 150) }
    options.request.language = options.language
    options.request.session = options.session ?? "fridayctl-\(getpid())"
    options.request.allowDuplicate = options.allowDuplicate ? true : nil
    return options
}

func render(_ response: IPCResponse) {
    if let items = response.data?.arrayValue, response.status == "ok", response.message.hasSuffix("transcript items") {
        for item in items {
            let role = item["role"]?.stringValue ?? "?"
            let time = String((item["date"]?.stringValue ?? "").dropFirst(11).prefix(8))
            let tools = (item["tools"]?.arrayValue ?? []).compactMap(\.stringValue)
            print("\(time) \(role.padding(toLength: 9, withPad: " ", startingAt: 0)) [\(item["source"]?.stringValue ?? "")] \(item["text"]?.stringValue ?? "")" + (tools.isEmpty ? "" : "  {\(tools.joined(separator: ", "))}"))
        }
        return
    }
    if let data = response.data?.objectValue, data["wake_word_detected"] != nil {
        print("wake word detected: \(data["wake_word_detected"]?.boolValue == true ? "yes" : "no")")
        if let heard = data["heard"]?.stringValue { print("heard: \(heard)") }
        if let phases = data["phases"]?.arrayValue { print("phases: " + phases.compactMap(\.stringValue).joined(separator: " → ")) }
        if let latency = data["latency"]?.objectValue {
            let keys = ["wakeToListenMs", "speechEndToTranscriptMs", "routingMs", "planningMs", "toolsMs", "totalMs"]
            print("latency: " + keys.compactMap { key in latency[key]?.intValue.map { "\(key)=\($0)" } }.joined(separator: " "))
        }
        print("reply: ", terminator: "")
    }
    print(response.message)
    for result in response.results {
        if let confirmation = result.confirmation, let token = confirmation.token {
            print("\nTo proceed:  fridayctl --confirm \(token)")
            print("To cancel:   fridayctl --cancel \(token)")
        }
        if let clarification = result.clarification {
            for (index, option) in clarification.options.enumerated() {
                print("  [\(index)] \(option.label)\(option.detail.map { " — \($0)" } ?? "")")
            }
            if let token = clarification.token, !clarification.options.isEmpty { print("\nChoose with:  fridayctl --choose \(token) INDEX") }
        }
        if let permission = result.permission, let url = permission.settingsURL {
            print("\nGrant access in System Settings: \(url)")
        }
        if let setup = result.setup {
            print("\n\(setup.title)")
            for step in setup.steps { print("  \(step)") }
        }
        for assumption in result.assumptions { print("  (assumed: \(assumption))") }
        for warning in result.warnings { print("  ⚠︎ \(warning)") }
    }
}

@main
struct JarvisCTL {
    static func main() async {
        let options = parse(Array(CommandLine.arguments.dropFirst()))
        let client = IPCClient(socketPath: options.socket, timeout: options.timeout)
        var exitCode: Int32 = 0
        do {
            let response = try await client.send(options.request)
            if options.json {
                FileHandle.standardOutput.write(try IPCCodec.encode(response))
            } else if options.request.type == .tools || options.request.type == .status, let payload = response.data {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                print(String(decoding: (try? encoder.encode(payload)) ?? Data(), as: UTF8.self))
            } else {
                render(response)
            }
            exitCode = response.success ? 0 : 1
        } catch IPCError.notConnected(let reason) {
            FileHandle.standardError.write(Data("Could not reach Friday at \(options.socket): \(reason). Is the app running (and the local control channel enabled in Settings)?\n".utf8))
            exitCode = 2
        } catch IPCError.timedOut {
            FileHandle.standardError.write(Data("Friday did not answer within \(Int(options.timeout)) seconds.\n".utf8))
            exitCode = 2
        } catch {
            FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
            exitCode = 2
        }
        exit(exitCode)
    }
}

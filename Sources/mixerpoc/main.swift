import Foundation
import MixerCore

func printUsage() {
    print("""
    mixerpoc — per-app audio routing debug CLI

    USAGE:
      mixerpoc list
      mixerpoc route --app <bundle-substring> --device <name-substring>

    Example:
      mixerpoc route --app com.apple.Music --device Combo384
    """)
}

func arg(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let command = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "list"

switch command {
case "list":
    print("=== OUTPUT DEVICES ===")
    for d in listOutputDevices() {
        print(String(format: "  [%2u ch] %@  (uid: %@)", d.outputChannels, d.name, d.uid))
    }
    print("\n=== AUDIO PROCESSES ===")
    for p in listAudioProcesses() {
        print("  pid \(p.pid)\t\(p.bundleID ?? "(no bundle id)")")
    }

case "route":
    guard let app = arg("--app"), let deviceMatch = arg("--device") else { printUsage(); exit(1) }

    let processMatches = listAudioProcesses().filter {
        ($0.bundleID ?? "").localizedCaseInsensitiveContains(app)
    }
    guard processMatches.count == 1, let proc = processMatches.first else {
        if processMatches.isEmpty {
            print("✗ No audio process matching '\(app)'. Is it open/playing?")
        } else {
            print("✗ App match is ambiguous; use a more specific bundle ID:")
            for match in processMatches { print("  \(match.bundleID ?? "(no bundle id)")") }
        }
        exit(1)
    }

    let deviceMatches = listOutputDevices().filter {
        $0.name.localizedCaseInsensitiveContains(deviceMatch)
    }
    guard deviceMatches.count == 1, let device = deviceMatches.first else {
        if deviceMatches.isEmpty {
            print("✗ No output device matching '\(deviceMatch)'.")
        } else {
            print("✗ Output match is ambiguous; use a more specific device name:")
            for match in deviceMatches { print("  \(match.name)") }
        }
        exit(1)
    }

    let router = ProcessAudioRouter()
    router.verbose = true

    let sigsrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    signal(SIGINT, SIG_IGN)
    sigsrc.setEventHandler { print("\nStopping…"); router.stop(); exit(0) }
    sigsrc.resume()

    do {
        try router.start(processObjectID: proc.objectID, deviceID: device.id, deviceName: device.name)
        print("✓ Routing \(proc.bundleID ?? "?") → \(device.name). Ctrl-C to stop.")
    } catch {
        print("✗ \(error)"); router.stop(); exit(1)
    }
    RunLoop.main.run()

default:
    printUsage()
}

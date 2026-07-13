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

    guard let proc = listAudioProcesses().first(where: {
        ($0.bundleID ?? "").localizedCaseInsensitiveContains(app)
    }) else { print("✗ No audio process matching '\(app)'. Is it open/playing?"); exit(1) }

    guard let device = listOutputDevices().first(where: {
        $0.name.localizedCaseInsensitiveContains(deviceMatch)
    }) else { print("✗ No output device matching '\(deviceMatch)'."); exit(1) }

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

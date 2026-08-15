import AppKit

// sfcal — entrada. Modos:
//   (sin args)                    → app GUI
//   --sync-once                   → sync headless, imprime conteos y sale
//   --snapshot <vista> <out.png> [--light]  → render offscreen para evidencia/crítico
//   --version

let cliArgs = CommandLine.arguments

if cliArgs.contains("--version") {
    print("sfcal 1.0.0")
    exit(0)
}

MainActor.assumeIsolated {
    let appDelegate = AppDelegate()

    if let i = cliArgs.firstIndex(of: "--snapshot"), cliArgs.count > i + 2 {
        appDelegate.launchMode = .snapshot(view: cliArgs[i + 1], path: cliArgs[i + 2],
                                           light: cliArgs.contains("--light"))
    } else if cliArgs.contains("--sync-once") {
        appDelegate.launchMode = .syncOnce
    } else if let i = cliArgs.firstIndex(of: "--roundtrip"), cliArgs.count > i + 1 {
        appDelegate.launchMode = .roundtrip(calendarId: cliArgs[i + 1])
    } else {
        appDelegate.launchMode = .gui
    }

    let app = NSApplication.shared
    app.delegate = appDelegate
    app.run()
}

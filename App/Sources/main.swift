import AppKit
// `koffeelid <verb>` forwards to the running instance and exits before AppKit starts.
if let code = CommandLineClient.run(arguments: CommandLine.arguments) { exit(code) }
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

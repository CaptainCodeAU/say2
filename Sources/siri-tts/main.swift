import Darwin
import Foundation
import SiriTTSCore

let application = SiriTTSApplication()
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
signal(SIGPIPE, SIG_IGN)
let cancelHandler: @Sendable () -> Void = { [application] in
    application.cancel()
}

let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
interrupt.setEventHandler(handler: cancelHandler)
interrupt.resume()

let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
terminate.setEventHandler(handler: cancelHandler)
terminate.resume()

do {
    try application.run(arguments: Array(CommandLine.arguments.dropFirst()))
    exit(ExitCode.success.rawValue)
} catch let error as CLIError {
    if error.code == .success {
        print(error.message)
    } else {
        writeStderr("error: \(error.message)\n")
    }
    exit(error.code.rawValue)
} catch {
    writeStderr("error: \(error.localizedDescription)\n")
    exit(ExitCode.internalFailure.rawValue)
}

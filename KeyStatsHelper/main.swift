import Foundation

let listener = HelperXPCListener()
listener.resume()
NSLog("[KeyStatsHelper] listening on \(HelperLocations.machServiceName)")
CFRunLoopRun()

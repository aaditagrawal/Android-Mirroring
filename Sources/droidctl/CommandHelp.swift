import AgentProtocol
import Foundation

// MARK: - CLI

func usage(exitCode: Int32 = 2) -> Never {
    print("""
    droidctl — control the phone mirrored by Android Mirroring

    MCP:
      droidctl mcp                          Run as an MCP server over stdio

    Commands:
      status                                Connection status
      info                                  Device, battery, stream details
      screenshot [-o FILE] [--max N] [--png]  Save a screenshot (default ./screenshot.jpg)
      tap X Y                               Tap (screenshot pixel coordinates)
      double-tap X Y
      long-press X Y [MS]
      swipe X1 Y1 X2 Y2 [MS]
      scroll DY [X Y]                       Mouse-wheel scroll (positive = down)
      type TEXT...                          Type text (any Unicode)
      key NAME [--long]                     home back recents enter delete tab volume_up power …
      ui [FILTER]                           List on-screen elements with bounds
      text [QUERY]                          On-screen text via OCR, with centers
      tap-text QUERY                        Tap visible text (OCR), or an element by description / id
      wait-for QUERY [TIMEOUT_MS]           Wait for text to appear
      batch JSON                            Run several actions, e.g. '[{"tool":"tap","x":1,"y":2}]'
      launch APP                            Launch by package or label
      apps [FILTER]                         List apps
      open URL                              Open a URL / deep link
      current                               Foreground app
      notifications                         Current notifications
      clipboard [TEXT]                      Read, or set, the phone clipboard
      unlock                                Wake + unlock with the saved PIN
      screen on|off                         Phone display power (mirroring continues)
      shell CMD...                          adb shell
      install APK                           Install an APK
      push FILE [REMOTE]                    Copy a file to the phone
      pull REMOTE [LOCAL]                   Copy a file from the phone
      show | hide                           Show/hide the mirror window
      call METHOD [JSON]                    Raw API call
      tools                                 List API tools (JSON)

    Coordinates refer to the last screenshot (long edge \(AgentAPI.defaultMaxDimension) px by default).
    """)
    exit(exitCode)
}

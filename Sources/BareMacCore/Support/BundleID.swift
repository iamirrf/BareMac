import Foundation

/// Helpers for app IDs (bundle identifiers) such as `com.spotify.client`.
public enum BundleID {
    /// `true` for strings shaped like a reverse-DNS app ID: at least two parts, the
    /// first one letters only, and only letters, digits, `-` and `_` in each part.
    public static func isPlausible(_ string: String) -> Bool {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, string.count <= 255 else { return false }
        guard let first = parts.first, first.count >= 2, first.allSatisfy({ $0.isASCII && $0.isLetter }) else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }
    }

    /// The developer part of an ID: `com.spotify.client` → `com.spotify`.
    public static func organization(of identifier: String) -> String? {
        let parts = identifier.lowercased().split(separator: ".")
        guard parts.count >= 2 else { return nil }
        return parts.prefix(2).joined(separator: ".")
    }

    /// `true` when one ID is the other or nests inside it (`com.a.app.helper` in `com.a.app`).
    public static func isRelated(_ lhs: String, _ rhs: String) -> Bool {
        let a = lhs.lowercased(), b = rhs.lowercased()
        return a == b || a.hasPrefix(b + ".") || b.hasPrefix(a + ".")
    }

    public static func isApple(_ identifier: String) -> Bool {
        let lowered = identifier.lowercased()
        return lowered.hasPrefix("com.apple.") || lowered == "com.apple" || lowered.hasPrefix("group.com.apple.")
    }

    /// Team IDs are ten upper-case letters and digits, as in `UBF8T346G9.Office`.
    public static func isTeamIdentifier(_ string: some StringProtocol) -> Bool {
        string.count == 10 && string.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
    }

    /// Names of popular apps whose IDs don't spell their name. Used only to label
    /// leftovers of apps that are gone; the ID is always shown next to it.
    static let knownNames: [String: String] = [
        "com.spotify.client": "Spotify",
        "us.zoom.xos": "Zoom",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.google.chrome": "Google Chrome",
        "com.google.chrome.canary": "Google Chrome Canary",
        "com.microsoft.vscode": "Visual Studio Code",
        "com.microsoft.teams": "Microsoft Teams",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.microsoft.word": "Microsoft Word",
        "com.microsoft.excel": "Microsoft Excel",
        "com.microsoft.powerpoint": "Microsoft PowerPoint",
        "com.microsoft.outlook": "Microsoft Outlook",
        "com.microsoft.onenote.mac": "Microsoft OneNote",
        "com.hnc.discord": "Discord",
        "org.mozilla.firefox": "Firefox",
        "com.brave.browser": "Brave Browser",
        "com.operasoftware.opera": "Opera",
        "com.figma.desktop": "Figma",
        "notion.id": "Notion",
        "com.docker.docker": "Docker Desktop",
        "com.getdropbox.dropbox": "Dropbox",
        "com.adobe.acc.adobecreativecloud": "Adobe Creative Cloud",
        "com.valvesoftware.steam": "Steam",
        "com.openai.chat": "ChatGPT",
        "com.anthropic.claudefordesktop": "Claude",
        "md.obsidian": "Obsidian",
        "com.todoist.mac.todoist": "Todoist",
        "com.skype.skype": "Skype",
        "ru.keepcoder.telegram": "Telegram",
        "net.whatsapp.whatsapp": "WhatsApp",
        "com.readdle.smartemail-mac": "Spark",
        "com.postmanlabs.mac": "Postman",
        "com.sublimetext.4": "Sublime Text",
        "com.googlecode.iterm2": "iTerm2",
        "org.videolan.vlc": "VLC",
        "com.colliderli.iina": "IINA",
        "com.raycast.macos": "Raycast",
        "com.1password.1password": "1Password",
        "com.bitwarden.desktop": "Bitwarden",
        "com.github.githubclient": "GitHub Desktop",
        "com.jetbrains.intellij": "IntelliJ IDEA",
        "com.jetbrains.pycharm": "PyCharm",
        "com.electron.dockerdesktop": "Docker Desktop",
        "com.evernote.evernote": "Evernote",
        "com.linear": "Linear",
        "com.loom.desktop": "Loom",
        "com.grammarly.projectllama": "Grammarly",
        "com.nordvpn.macos": "NordVPN",
        "com.expressvpn.expressvpn": "ExpressVPN",
        "org.whispersystems.signal-desktop": "Signal",
        "com.webex.meetingmanager": "Webex",
        "com.cisco.webexmeetingsapp": "Webex",
        "com.logi.optionsplus": "Logi Options+",
        "com.canva.canvaeditor": "Canva",
    ]

    /// Parts of IDs that never name an app.
    static let genericParts: Set<String> = [
        "app", "apps", "mac", "macos", "osx", "client", "desktop", "helper", "agent", "launcher",
        "main", "application", "xos", "plist", "savedstate", "service", "daemon", "user", "prefs",
        "preferences", "settings", "shared", "group", "beta", "free", "pro", "lite",
    ]

    /// A readable name for an app ID, for apps that are no longer on this Mac.
    /// Popular apps come from a fixed table; otherwise the most specific part of the
    /// ID is used (`com.example.photopad` → "Photopad").
    public static func displayName(for identifier: String) -> String {
        if let known = knownNames[identifier.lowercased()] { return known }
        let parts = identifier.split(separator: ".").map(String.init)
        let candidates = parts.dropFirst()
        let chosen = candidates.reversed().first { part in
            !genericParts.contains(part.lowercased()) && !part.allSatisfy(\.isNumber) && part.count > 1
        } ?? (parts.count > 1 ? parts[1] : identifier)
        return humanize(chosen)
    }

    static func humanize(_ part: String) -> String {
        let spaced = part.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        if spaced.count <= 3 { return spaced.uppercased() }
        if spaced.contains(where: \.isUppercase) { return spaced }
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }
}

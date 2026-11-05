import Foundation

public enum MuesliPaths {
    public static func defaultSupportDirectoryURL(appName: String = "Muesli") -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(appName, isDirectory: true)
    }

    /// Where the settings backup lives. It sits outside `Library`, so uninstallers
    /// that sweep Application Support, Preferences, Caches and Logs by app name
    /// leave it alone. `appName` keeps production, dev and lane data apart.
    public static func backupDirectoryURL(
        appName: String = "Muesli",
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home
            .appendingPathComponent(".muesli", isDirectory: true)
            .appendingPathComponent("backup", isDirectory: true)
            .appendingPathComponent(appName, isDirectory: true)
    }

    public static func defaultDatabaseURL(appName: String = "Muesli") -> URL {
        defaultSupportDirectoryURL(appName: appName).appendingPathComponent("muesli.db")
    }
}

public enum MuesliNotifications {
    public static let dataDidChange = Notification.Name("com.muesli.dataChanged")

    public static func postDataDidChange() {
        DistributedNotificationCenter.default().post(name: dataDidChange, object: nil)
    }
}

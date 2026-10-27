import AppKit

@main struct MenuBarRegression {
    @MainActor static func main() throws {
        DispatchQueue.global().asyncAfter(deadline: .now() + 90) {
            fputs("FAIL: native panel check exceeded 90 seconds\n", stderr)
            exit(1)
        }
        switch CommandLine.arguments.dropFirst().first {
        case "panel": HistoryRegression.main()
        case "usage": UsageRegression.main()
        case "settings": try SettingsRegression.main()
        case "catalog": try CatalogRegression.main()
        case "reports": try ReportsRegression.main()
        case "permissions": try PermissionWindowRegression.main()
        default: fatalError("Choose panel, usage, settings, catalog, reports, or permissions")
        }
    }
}

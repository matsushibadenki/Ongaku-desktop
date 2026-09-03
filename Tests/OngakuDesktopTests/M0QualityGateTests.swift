import AppKit
import Foundation
import Testing

@Suite("M0 UI, accessibility, localization, and privacy gate")
struct M0QualityGateTests {
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    private static let resourceRoot = repositoryRoot
        .appendingPathComponent("Sources/OngakuDesktop/Resources", isDirectory: true)
    private static let locales = ["en", "ja", "zh-Hans"]

    @Test("English, Japanese, and Simplified Chinese localization keys stay in parity")
    func localizationKeyParity() throws {
        for table in ["Localizable", "InfoPlist"] {
            let dictionaries = try Self.locales.map { locale in
                try Self.stringsTable(named: table, locale: locale)
            }
            let referenceKeys = Set(dictionaries[0].keys)

            for (index, dictionary) in dictionaries.enumerated() {
                #expect(
                    Set(dictionary.keys) == referenceKeys,
                    "\(table).strings keys differ for \(Self.locales[index])"
                )
                #expect(
                    dictionary.values.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
                    "\(table).strings contains an empty value for \(Self.locales[index])"
                )
            }
        }
    }

    @Test("Localized format arguments remain compatible")
    func localizedFormatParity() throws {
        let dictionaries = try Self.locales.map {
            try Self.stringsTable(named: "Localizable", locale: $0)
        }
        for key in dictionaries[0].keys.sorted() {
            let expected = Self.formatArgumentTypes(in: dictionaries[0][key, default: ""])
            for (index, dictionary) in dictionaries.enumerated().dropFirst() {
                #expect(
                    Self.formatArgumentTypes(in: dictionary[key, default: ""]) == expected,
                    "Format arguments differ for \(key) in \(Self.locales[index])"
                )
            }
        }
    }

    @Test("Localized headings avoid forced line breaks and fit their layout budgets")
    func localizedHeadingLayoutContracts() throws {
        let titleKeys = [
            "deviceSync.title",
            "appleMusic.store.title",
            "appleMusic.conversion.title",
            "appleMusic.export.title",
        ]
        let buttonBudgets: [String: CGFloat] = [
            "common.close": 120,
            "common.cancel": 120,
            "deviceSync.discovery.retry": 220,
            "appleMusic.conversion.create": 240,
            "appleMusic.export.create": 240,
        ]
        let headingFont = NSFont.systemFont(ofSize: 22, weight: .semibold)
        let buttonFont = NSFont.systemFont(ofSize: 13)

        for locale in Self.locales {
            let strings = try Self.stringsTable(named: "Localizable", locale: locale)
            for key in titleKeys {
                let value = try #require(strings[key])
                #expect(!value.contains("\n"), "\(key) contains a forced line break in \(locale)")
                let width = (value as NSString).size(withAttributes: [.font: headingFont]).width
                #expect(width <= 560, "\(key) is wider than its heading budget in \(locale)")
            }
            for (key, budget) in buttonBudgets {
                let value = try #require(strings[key])
                let width = (value as NSString).size(withAttributes: [.font: buttonFont]).width + 36
                #expect(width <= budget, "\(key) is wider than its control budget in \(locale)")
            }
        }
    }

    @Test("Music and local-network usage descriptions exist in all supported languages")
    func requiredUsageDescriptions() throws {
        let requiredKeys = Set(["NSAppleMusicUsageDescription", "NSLocalNetworkUsageDescription"])
        for locale in Self.locales {
            let strings = try Self.stringsTable(named: "InfoPlist", locale: locale)
            #expect(Set(strings.keys) == requiredKeys)
            #expect(strings.values.allSatisfy { $0.count >= 20 })
        }
    }

    @Test("Privacy manifest declares no tracking and approved required-reason APIs")
    func privacyManifestContract() throws {
        let manifestURL = Self.resourceRoot.appendingPathComponent("PrivacyInfo.xcprivacy")
        let data = try Data(contentsOf: manifestURL)
        let propertyList = try PropertyListSerialization.propertyList(from: data, format: nil)
        let manifest = try #require(propertyList as? [String: Any])

        #expect(manifest["NSPrivacyTracking"] as? Bool == false)
        #expect((manifest["NSPrivacyTrackingDomains"] as? [Any])?.isEmpty == true)
        #expect((manifest["NSPrivacyCollectedDataTypes"] as? [Any])?.isEmpty == true)

        let entries = try #require(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        let reasons: [String: Set<String>] = Dictionary(uniqueKeysWithValues: entries.compactMap { entry -> (String, Set<String>)? in
            guard let category = entry["NSPrivacyAccessedAPIType"] as? String,
                  let values = entry["NSPrivacyAccessedAPITypeReasons"] as? [String] else { return nil }
            return (category, Set(values))
        })
        #expect(reasons["NSPrivacyAccessedAPICategoryUserDefaults"] == ["CA92.1"])
        #expect(reasons["NSPrivacyAccessedAPICategoryFileTimestamp"] == ["C617.1", "3B52.1"])
        #expect(reasons["NSPrivacyAccessedAPICategoryDiskSpace"] == ["E174.1", "85F4.1"])
        #expect(reasons["NSPrivacyAccessedAPICategorySystemBootTime"] == ["35F9.1"])

        let mobileManifestURL = Self.repositoryRoot
            .appendingPathComponent("Sources/OngakuMobile/Resources/PrivacyInfo.xcprivacy")
        let mobileData = try Data(contentsOf: mobileManifestURL)
        let mobilePropertyList = try PropertyListSerialization.propertyList(from: mobileData, format: nil)
        let mobileManifest = try #require(mobilePropertyList as? [String: Any])
        #expect(mobileManifest["NSPrivacyTracking"] as? Bool == false)
        #expect((mobileManifest["NSPrivacyCollectedDataTypes"] as? [Any])?.isEmpty == true)
        let mobileEntries = try #require(mobileManifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        let mobileReasons: [String: Set<String>] = Dictionary(uniqueKeysWithValues: mobileEntries.compactMap { entry -> (String, Set<String>)? in
            guard let category = entry["NSPrivacyAccessedAPIType"] as? String,
                  let values = entry["NSPrivacyAccessedAPITypeReasons"] as? [String] else { return nil }
            return (category, Set(values))
        })
        #expect(mobileReasons["NSPrivacyAccessedAPICategoryFileTimestamp"] == ["C617.1"])
        #expect(mobileReasons["NSPrivacyAccessedAPICategoryDiskSpace"] == ["E174.1"])
    }

    @Test("Critical windows expose automation hooks and keyboard escape routes")
    func criticalUIContracts() throws {
        let content = try Self.source("ContentView.swift")
        let sync = try Self.source("DeviceSyncView.swift")
        let appleMusic = try Self.source("AppleMusicStoreView.swift")

        #expect(content.contains(".accessibilityIdentifier(\"main.window\")"))
        #expect(content.contains(".accessibilityIdentifier(\"main.import-music\")"))
        #expect(content.contains(".accessibilityIdentifier(\"main.open-device-sync\")"))
        #expect(content.contains(".accessibilityIdentifier(\"main.open-apple-music\")"))
        #expect(content.contains(".keyboardShortcut(\"i\", modifiers: [.command, .shift])"))
        #expect(sync.contains(".accessibilityIdentifier(\"device-sync.window\")"))
        #expect(sync.contains(".accessibilityIdentifier(\"device-sync.retry\")"))
        #expect(sync.contains(".accessibilityIdentifier(\"device-sync.close\")"))
        #expect(sync.contains(".keyboardShortcut(.cancelAction)"))
        #expect(appleMusic.contains(".accessibilityIdentifier(\"apple-music.window\")"))
        #expect(appleMusic.contains(".accessibilityIdentifier(\"apple-music.close\")"))
        #expect(appleMusic.contains(".keyboardShortcut(.defaultAction)"))
        #expect(appleMusic.contains(".keyboardShortcut(.cancelAction)"))
    }

    @Test("The toolbar import and relink actions share one file importer presenter")
    func mainFileImporterHasOnePresenter() throws {
        let content = try Self.source("ContentView.swift")
        let presenterCount = content.components(separatedBy: ".fileImporter(").count - 1

        #expect(presenterCount == 1)
        #expect(content.contains("presentFileImporter(.music)"))
        #expect(content.contains("presentFileImporter(.relinkSearch)"))
        #expect(content.contains("switch fileImporterMode"))
    }

    @Test("The persistent player reserves space outside scrollable library content")
    func persistentPlayerLayoutContract() throws {
        let content = try Self.source("ContentView.swift")
        let sidebar = try Self.source("LibrarySidebar.swift")
        let inspector = try Self.source("TrackInspector.swift")

        #expect(content.contains(".safeAreaInset(edge: .top, spacing: 0)"))
        #expect(content.contains(".safeAreaInset(edge: .bottom, spacing: 0)"))
        #expect(content.contains(".layoutPriority(1)"))
        #expect(sidebar.contains("meterSettings.barPosition == .bottom"))
        #expect(sidebar.contains("Color.clear.frame(height: AppTheme.bottomPlayerClearance)"))
        #expect(inspector.contains("meterSettings.barPosition == .bottom"))
        #expect(inspector.contains("? AppTheme.bottomPlayerClearance"))
    }

    @Test("The settings scene injects every environment object required by its sections")
    func settingsSceneEnvironmentContract() throws {
        let app = try Self.source("OngakuDesktopApp.swift")
        let settingsScene = try #require(app.components(separatedBy: "Settings {").last)

        #expect(settingsScene.contains(".environmentObject(socialPrivacy)"))
        #expect(settingsScene.contains(".environmentObject(phoneSync)"))
        #expect(settingsScene.contains(".environmentObject(library)"))
    }

    @Test("The active library selector uses a visible button and dedicated popover")
    func activeLibrarySelectorUsesDedicatedPopover() throws {
        let sidebar = try Self.source("LibrarySidebar.swift")
        let labelReferenceCount = sidebar.components(
            separatedBy: "libraryProfileMenuLabel"
        ).count - 1

        #expect(labelReferenceCount == 2)
        #expect(sidebar.contains("isShowingLibraryProfilePopover.toggle()"))
        #expect(sidebar.contains("libraryProfileMenuLabel\n                        .frame(width: 170"))
        #expect(sidebar.contains(".contentShape(Rectangle())"))
        #expect(sidebar.contains(".popover(isPresented: $isShowingLibraryProfilePopover"))
        #expect(sidebar.contains("private var libraryProfilePopover: some View"))
        #expect(!sidebar.contains("libraryProfileMenuLabel\n                        .opacity(0)"))
        #expect(!sidebar.contains("libraryProfileMenuLabel\n                        .hidden()"))
        #expect(sidebar.contains(".lineLimit(1)\n                .layoutPriority(1)"))
    }

    @Test("The Pro effects rack reserves clearance above the persistent player")
    func proEffectsRackReservesPlayerClearance() throws {
        let effectsRack = try Self.source("EffectsRackView.swift")

        #expect(effectsRack.contains(
            "selectedTab == .pro ? AppTheme.bottomPlayerClearance : AppTheme.spaceLG"
        ))
    }

    private static func stringsTable(named name: String, locale: String) throws -> [String: String] {
        let url = resourceRoot
            .appendingPathComponent("\(locale).lproj", isDirectory: true)
            .appendingPathComponent("\(name).strings")
        let data = try Data(contentsOf: url)
        let propertyList = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(propertyList as? [String: String])
    }

    private static func source(_ name: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/OngakuDesktop/\(name)"),
            encoding: .utf8
        )
    }

    private static func formatArgumentTypes(in value: String) -> [String] {
        let pattern = #"%(?:(\d+)\$)?[-+#0 ']*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j)?[diuoxXfFeEgGaAcCsSp@]"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.matches(in: value, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: value),
                  let type = value[swiftRange].last else { return nil }
            return String(type)
        }
    }
}

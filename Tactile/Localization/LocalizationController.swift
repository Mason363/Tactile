import Combine
import Foundation
import SwiftUI

@MainActor
final class LocalizationController: ObservableObject {
    let registry: LanguagePackRegistry

    @Published private(set) var resolvedPack: LanguagePack

    private let settings: SettingsStore
    private var cancellables: Set<AnyCancellable> = []

    init(settings: SettingsStore, registry suppliedRegistry: LanguagePackRegistry? = nil) {
        let registry = suppliedRegistry ?? LanguagePackRegistry()
        self.settings = settings
        self.registry = registry
        resolvedPack = registry.resolve(
            selection: settings.languageSelection,
            preferredLanguages: Locale.preferredLanguages
        )

        settings.$languageSelection
            .removeDuplicates()
            // @Published emits before the stored property changes. Resolve
            // afterwards so normalization cannot be overwritten by that write.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] selection in
                self?.resolve(selection)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshSystemLanguage() }
            .store(in: &cancellables)

        normalizeMissingExplicitSelection()
    }

    var locale: Locale { resolvedPack.locale }

    var localizer: Localizer {
        Localizer(pack: resolvedPack, fallback: registry.englishPack)
    }

    var selection: LanguageSelection { settings.languageSelection }

    func setSelection(_ selection: LanguageSelection) {
        settings.languageSelection = selection
    }

    func refreshSystemLanguage() {
        guard settings.languageSelection == .system else { return }
        registry.reload()
        resolve(.system)
    }

    private func resolve(_ selection: LanguageSelection) {
        let next = registry.resolve(
            selection: selection,
            preferredLanguages: Locale.preferredLanguages
        )
        if next.identifier != resolvedPack.identifier || next.bundle.bundlePath != resolvedPack.bundle.bundlePath {
            resolvedPack = next
        }
        normalizeMissingExplicitSelection()
    }

    private func normalizeMissingExplicitSelection() {
        guard case .pack(let identifier) = settings.languageSelection,
              registry.pack(identifier: identifier) == nil,
              identifier != registry.englishPack.identifier
        else { return }
        settings.languageSelection = .pack(identifier: registry.englishPack.identifier)
    }
}

struct LocalizedRoot<Content: View>: View {
    @ObservedObject var localization: LocalizationController
    let content: Content

    var body: some View {
        content
            .environmentObject(localization)
            .environment(\.locale, localization.locale)
    }
}

import Foundation
import Testing

@testable import MusicLogic

/// The library choices, which must be right from the first frame rather than once the
/// server's folder list arrives near the end of launch.
@MainActor
struct LibraryScopeStoreTests {
    private let folders = [MusicFolder(id: 2, name: "Music"), MusicFolder(id: 1, name: "My Music")]

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "test-\(UUID().uuidString)")!
    }

    @Test func aChosenMixLibraryHoldsBeforeTheServerAnswers() {
        let saved = defaults()
        LibraryScopeStore(defaults: saved).adopt(folders: folders)
        saved.set(2, forKey: LibraryScopeStore.mixesKey)

        // The next launch, before any folder list has come back.
        let relaunched = LibraryScopeStore(defaults: saved)
        #expect(relaunched.mixScope == .folder(id: 2, name: "Music"))
        #expect(relaunched.mixScope.cacheKey == "2")
    }

    @Test func theBrowsingLibraryIsRestoredAtLaunchToo() {
        let saved = defaults()
        let first = LibraryScopeStore(defaults: saved)
        first.adopt(folders: folders)
        first.scope = .folder(id: 1, name: "My Music")

        #expect(LibraryScopeStore(defaults: saved).scope == .folder(id: 1, name: "My Music"))
    }

    @Test func bothLibrariesIsMinusOneOrNothingStored() {
        let saved = defaults()
        let store = LibraryScopeStore(defaults: saved)
        store.adopt(folders: folders)
        #expect(store.mixScope == .all)
        saved.set(-1, forKey: LibraryScopeStore.mixesKey)
        #expect(store.mixScope == .all)
    }

    @Test func aFolderTheServerNoLongerHasMeansAll() {
        let store = LibraryScopeStore(defaults: defaults())
        store.adopt(folders: folders)
        #expect(store.scope(forFolderID: 9) == .all)
        #expect(store.scope(forFolderID: 1) == .folder(id: 1, name: "My Music"))
    }

    @Test func aFirstLaunchKnowsNoFolders() {
        let store = LibraryScopeStore(defaults: defaults())
        #expect(store.folders.isEmpty)
        #expect(store.scope == .all)
    }
}

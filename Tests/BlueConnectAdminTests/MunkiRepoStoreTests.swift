import Testing
@testable import BlueConnectAdmin

/// `MunkiRepoStore.catalogURL` is what the Settings → Munki Repo pane
/// previews live, and what every catalog fetch ends up hitting. The
/// composition rules ("strip schemes, trim slashes, percent-encode the
/// key path") are easy to get wrong on a refactor, hence these tests.
// `MunkiRepoStore` is @MainActor-isolated, so its static URL helper
// inherits that isolation in Swift 5 + Sendable strict checking.
// Marking the suite @MainActor lets us call the helper synchronously.
@MainActor
@Suite("MunkiRepoStore.catalogURL composition")
struct MunkiRepoStoreTests {

    @Test func endpointOnlyComposesScheme() {
        let url = MunkiRepoStore.catalogURL(
            endpoint: "munki.example.com",
            bucket: "",
            prefix: "",
            key: "catalogs/all"
        )
        #expect(url == "https://munki.example.com/catalogs/all")
    }

    @Test func bucketAndPrefixGetAppended() {
        let url = MunkiRepoStore.catalogURL(
            endpoint: "s3.us-east-1.wasabisys.com",
            bucket: "my-bucket",
            prefix: "munki_repo",
            key: "catalogs/all"
        )
        #expect(url == "https://s3.us-east-1.wasabisys.com/my-bucket/munki_repo/catalogs/all")
    }

    @Test func endpointSchemeIsStripped() {
        let url = MunkiRepoStore.catalogURL(
            endpoint: "https://munki.example.com/",
            bucket: "",
            prefix: "",
            key: "catalogs/all"
        )
        #expect(url == "https://munki.example.com/catalogs/all")
    }

    @Test func extraSlashesAreTrimmed() {
        let url = MunkiRepoStore.catalogURL(
            endpoint: "munki.example.com",
            bucket: "/bucket/",
            prefix: "/repo/",
            key: "catalogs/all"
        )
        #expect(url == "https://munki.example.com/bucket/repo/catalogs/all")
    }

    @Test func pkgKeyWithSpacesGetsPercentEncoded() {
        let url = MunkiRepoStore.catalogURL(
            endpoint: "munki.example.com",
            bucket: "",
            prefix: "",
            key: "pkgs/A Better Finder Rename/abfr.dmg"
        )
        // Spaces → %20, but path separators stay as `/`.
        #expect(url == "https://munki.example.com/pkgs/A%20Better%20Finder%20Rename/abfr.dmg")
    }
}

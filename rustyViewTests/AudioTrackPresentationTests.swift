import XCTest
@testable import rustyView

final class AudioTrackPresentationTests: XCTestCase {
    func testTitledWireTracksRetainTheirLanguageInOnlineAndSavedLabels() throws {
        let data = Data(#"[{"index":4,"codec":"ac3","channels":6,"language":"rus","title":"Surround mix","default":true},{"index":12,"codec":"aac","channels":2,"language":"eng","title":"Commentary","default":false}]"#.utf8)
        let tracks = try JSONDecoder().decode([AudioTrack].self, from: data)
        XCTAssertEqual(tracks[0].displayName, "RUS · Surround mix")
        XCTAssertEqual(tracks[1].selectionLabel(defaultIndex: 4), "ENG · Commentary · AAC · Stereo")
        let saved = try JSONDecoder().decode([MovieAudioTrack].self,
            from: JSONEncoder().encode(tracks.map(MovieAudioTrack.init)))
        XCTAssertEqual(saved[0].displayName, "RUS · Surround mix")
        XCTAssertEqual(saved[1].selectionLabel, "ENG · Commentary · AAC · Stereo")
    }

    func testBlankTitlesAndUnknownLanguageDoNotHideUsableTrackNames() throws {
        let data = Data(#"[{"index":4,"codec":"aac","channels":2,"language":" eng ","title":"  ","default":false},{"index":12,"codec":"aac","channels":2,"language":"und","title":null,"default":false},{"index":16,"codec":"aac","channels":2,"language":"eng","title":"ENG","default":false}]"#.utf8)
        let tracks = try JSONDecoder().decode([AudioTrack].self, from: data)
        XCTAssertEqual(tracks.map(\.displayName), ["ENG", "Track 13", "ENG"])
    }
}

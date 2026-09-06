import XCTest
@testable import rustyView

final class DownloadOutputContractTests: XCTestCase {
    func testCompatibleSizeEstimateUsesTheRequestedEncodeAndNeverCopiesSourceByteCount() throws {
        var response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ServerModelDecodingTests.itemJSONForHTTP.utf8)) as? [String: Any])
        var fields = try XCTUnwrap(response["item"] as? [String: Any])
        fields["video_codec"] = "h264"
        fields["video_repair_required"] = false
        fields["duration_seconds"] = 10
        fields["size_bytes"] = 9_000_000_000 as Int64
        response["item"] = fields
        let item = try JSONDecoder().decode(ItemResponse.self, from: JSONSerialization.data(withJSONObject: response)).item
        let profile = try JSONDecoder().decode(QualityProfile.self, from: Data(#"{"id":"full_hd","label":"1080p","max_width":1920,"max_height":1080,"expected_bandwidth_kbps":8000,"automatic_fallback":false}"#.utf8))
        let client = RustyDLNAClient(configuration: .ephemeral)
        let automatic = client.compatiblePath(for: item, delivery: "mp4", quality: "auto", audioIndex: 0)
        XCTAssertEqual(try query("video_mode", in: automatic), "copy")
        XCTAssertNil(DownloadOutputSummary.estimatedByteCount(item: item, kind: .compatible, quality: "auto", profile: profile, audioIndex: 0),
                     "Source bytes must not be presented or used for low-space rejection as an unknown compatible output size")
        let encoded = client.compatiblePath(for: item, delivery: "mp4", quality: profile.id, audioIndex: 0)
        XCTAssertEqual(try query("video_mode", in: encoded), "transcode")
        XCTAssertEqual(try query("video_output", in: encoded), "h264_sdr")
        XCTAssertEqual(try query("audio_mode", in: encoded), "transcode")
        XCTAssertEqual(try query("audio", in: encoded), "0")
        XCTAssertEqual(DownloadOutputSummary.estimatedByteCount(item: item, kind: .compatible, quality: profile.id, profile: profile, audioIndex: 0), 10_000_000)
        XCTAssertEqual(DownloadOutputSummary.estimatedByteCount(item: item, kind: .original, quality: profile.id, profile: profile, audioIndex: 0), 9_000_000_000)
    }

    private func query(_ name: String, in path: String) throws -> String {
        try XCTUnwrap(URLComponents(string: path)?.queryItems?.first { $0.name == name }?.value)
    }
}

import CoreImage
import ImageIO
import Photos
import UIKit
import XCTest
@testable import PointAndShoot

/// Against the simulator's real Photos library: saving, RAW pairs, the Zero develop and
/// baking a filter. These are the paths that failed on device ("Couldn't save … 3300",
/// a filtered shot showing unfiltered).
///
/// Needs Photos access for the app: CI grants it with `xcrun simctl privacy … grant photos`.
/// Locally, without access, the tests skip; in CI (TEST_RUNNER_CI=1) they fail instead.
final class PhotoLibraryIntegrationTests: XCTestCase {
    override func setUp() async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status != .authorized {
            let inCI = ProcessInfo.processInfo.environment["CI"] != nil
            if inCI { XCTFail("Photos access not granted to the app in CI (status \(status.rawValue))") }
            throw XCTSkip("Photos access not granted; run: xcrun simctl privacy booted grant photos <bundle id>")
        }
    }

    private func jpeg(width: Int = 64, height: Int = 48) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: {
            let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f
        }()).image { ctx in
            UIColor.orange.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            UIColor.blue.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        }.jpegData(compressionQuality: 0.9)!
    }

    private func asset(_ id: String?, file: StaticString = #filePath, line: UInt = #line) throws -> PHAsset {
        let id = try XCTUnwrap(id, "save returned no asset id", file: file, line: line)
        return try XCTUnwrap(PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject,
                             "saved asset not found", file: file, line: line)
    }

    func testSavePhotoCreatesAnAsset() async throws {
        let id = try await PhotoLibrary.savePhoto(primary: jpeg(), rawCompanion: nil)
        let a = try asset(id)
        XCTAssertEqual(a.mediaType, .image)
        XCTAssertFalse(PhotoLibrary.hasRAW(a))
    }

    func testTestDNGIsAValidRAW() throws {
        let dng = TestDNG.make()
        let raw = try XCTUnwrap(CIRAWFilter(imageData: dng, identifierHint: "com.adobe.raw-image"),
                                "CIRAWFilter can't read the generated DNG")
        XCTAssertNotNil(raw.outputImage)
    }

    /// The device failure: Photos refused the RAW companion when it was added as Data.
    func testRAWPairSavesAsOneAssetWithARAWResource() async throws {
        let id = try await PhotoLibrary.savePhoto(primary: jpeg(), rawCompanion: TestDNG.make())
        let a = try asset(id)
        let types = PHAssetResource.assetResources(for: a).map(\.type)
        XCTAssertTrue(types.contains(.photo), "resources: \(types.map(\.rawValue))")
        XCTAssertTrue(types.contains(.alternatePhoto), "The DNG wasn't paired: \(types.map(\.rawValue))")
        let utis = PHAssetResource.assetResources(for: a).map(\.uniformTypeIdentifier)
        XCTAssertTrue(PhotoLibrary.hasRAW(a), "RAW not recognised; resource types: \(utis)")
    }

    func testZeroDevelopKeepsSensorPixelsAndTheOrientationTag() throws {
        for orientation: UInt16 in [1, 6] {
            let dng = TestDNG.make(orientation: orientation)
            let developed = try XCTUnwrap(ZeroDeveloper.developImage(dng: dng), "orientation \(orientation): the develop produced no image")
            XCTAssertEqual(developed.image.extent.size, CGSize(width: 64, height: 48), "sensor pixels, not rotated")
            let data = try XCTUnwrap(ZeroDeveloper.develop(dng: dng, asHEIF: false), "orientation \(orientation): encoding the develop failed")
            let src = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any])
            XCTAssertEqual(props[kCGImagePropertyPixelWidth as String] as? Int, 64, "orientation \(orientation)")
            XCTAssertEqual(props[kCGImagePropertyPixelHeight as String] as? Int, 48, "orientation \(orientation)")
            XCTAssertEqual(props[kCGImagePropertyOrientation as String] as? Int, Int(orientation),
                           "The develop must carry the DNG's orientation, not bake it in")
        }
    }

    func testZeroDevelopPairsWithItsDNG() async throws {
        let dng = TestDNG.make(orientation: 6)
        let developed = try XCTUnwrap(ZeroDeveloper.develop(dng: dng, asHEIF: true), "HEIF develop failed")
        let id = try await PhotoLibrary.savePhoto(primary: developed, rawCompanion: dng)
        let types = PHAssetResource.assetResources(for: try asset(id)).map(\.type)
        XCTAssertTrue(types.contains(.alternatePhoto), "Zero develop + DNG wasn't saved as a pair")
    }

    private func bake(_ lookID: String) async throws {
        let id = try await PhotoLibrary.savePhoto(primary: jpeg(width: 320, height: 240), rawCompanion: nil)
        let look = try XCTUnwrap(Look.named(lookID), "no look \(lookID)")
        try await RecipeBaker.apply(look.recipe, toAssetWithID: try XCTUnwrap(id))
        let a = try asset(id)
        XCTAssertTrue(a.hasAdjustments, "\(lookID): the baked look didn't land on the asset")

        let options = PHContentEditingInputRequestOptions()
        options.canHandleAdjustmentData = { $0.formatIdentifier == EditRecipe.formatID }
        let input: PHContentEditingInput? = await withCheckedContinuation { cont in
            a.requestContentEditingInput(with: options) { input, _ in cont.resume(returning: input) }
        }
        let data = try XCTUnwrap(input?.adjustmentData?.data, "\(lookID): no adjustment data")
        XCTAssertEqual(EditRecipe.decodeSaved(data)?.look, lookID, "\(lookID): the saved recipe doesn't reopen")
    }

    func testBakingAFilterEditsTheAssetAndReopens() async throws {
        try await bake("mono400")
    }

    func testBakingPrintWithoutRAWStillWorks() async throws {
        try await bake(CameraSettings.printLookID)
    }
}

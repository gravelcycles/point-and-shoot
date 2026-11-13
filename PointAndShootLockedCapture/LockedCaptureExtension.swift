import AVFoundation
import AVKit
import ImageIO
import LockedCameraCapture
import Photos
import SwiftUI
import UIKit

/// Runs from the Lock Screen without unlocking. Deliberately lean (extensions get a tight
/// memory budget): instant preview, one-tap shutter, volume buttons, and a hand-off to the
/// full app once you unlock.
@main
struct PointAndShootLockedCapture: LockedCameraCaptureExtension {
    var body: some LockedCameraCaptureExtensionScene {
        LockedCameraCaptureUIScene { session in
            LockedCaptureView(session: session)
        }
    }
}

struct LockedCaptureView: View {
    let session: LockedCameraCaptureSession
    @StateObject private var camera = LockedCamera()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            LockedPreview(session: camera.captureSession)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .frame(maxHeight: .infinity)
                .overlay(Color.black.opacity(camera.flash ? 0.85 : 0))

            VStack {
                HStack {
                    Text("POINT & SHOOT")
                        .font(.system(size: 12, weight: .bold))
                        .tracking(1.5)
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Button {
                        Task {
                            let activity = NSUserActivity(activityType: NSUserActivityTypeLockedCameraCapture)
                            try? await session.openApplication(for: activity)
                        }
                    } label: {
                        Label("Full app", systemImage: "lock.open.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .foregroundStyle(.white)
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)

                Spacer()

                HStack {
                    ZStack {
                        if let thumb = camera.thumbnail {
                            Image(uiImage: thumb).resizable().scaledToFill()
                        } else {
                            Color.white.opacity(0.1)
                        }
                    }
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        if camera.shotCount > 0 {
                            Text("\(camera.shotCount)")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.yellow, in: Capsule())
                                .offset(x: 6, y: -6)
                        }
                    }

                    Spacer()

                    Button { camera.capture() } label: {
                        ZStack {
                            Circle().stroke(Color.white, lineWidth: 4).frame(width: 78, height: 78)
                            Circle().fill(Color.white).frame(width: 64, height: 64)
                        }
                    }
                    .buttonStyle(LockedPressStyle())
                    .accessibilityLabel("Take photo")

                    Spacer()
                    Color.clear.frame(width: 52, height: 52)
                }
                .padding(.horizontal, 30)
                .padding(.bottom, 24)
            }
        }
        .background(LockedCaptureEvents { camera.capture() })
        .onAppear { camera.start(spillover: session.sessionContentURL) }
        .onDisappear { camera.stop() }
        .preferredColorScheme(.dark)
    }
}

struct LockedPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Camera

final class LockedCamera: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let captureSession = AVCaptureSession()
    @Published var thumbnail: UIImage?
    @Published var shotCount = 0
    @Published var flash = false

    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "locked.capture", qos: .userInitiated)
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var spillover: URL?

    func start(spillover url: URL) {
        spillover = url
        queue.async {
            if self.captureSession.inputs.isEmpty {
                self.captureSession.beginConfiguration()
                self.captureSession.sessionPreset = .photo
                if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                   let input = try? AVCaptureDeviceInput(device: device),
                   self.captureSession.canAddInput(input) {
                    self.captureSession.addInput(input)
                    self.rotation = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
                }
                if self.captureSession.canAddOutput(self.output) {
                    self.captureSession.addOutput(self.output)
                    self.output.maxPhotoQualityPrioritization = .balanced
                }
                self.captureSession.commitConfiguration()
            }
            if !self.captureSession.isRunning { self.captureSession.startRunning() }
        }
    }

    func stop() {
        queue.async {
            if self.captureSession.isRunning { self.captureSession.stopRunning() }
        }
    }

    func capture() {
        let angle = rotation?.videoRotationAngleForHorizonLevelCapture ?? 90
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        queue.async {
            guard self.captureSession.isRunning else { return }
            let codec: AVVideoCodecType = self.output.availablePhotoCodecTypes.contains(.hevc) ? .hevc : .jpeg
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: codec])
            settings.photoQualityPrioritization = .balanced
            if let connection = self.output.connection(with: .video), connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
            self.output.capturePhoto(with: settings, delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        DispatchQueue.main.async {
            self.flash = true
            withAnimation(.easeOut(duration: 0.25)) { self.flash = false }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else { return }
        let thumb = Self.thumbnail(from: data)
        DispatchQueue.main.async {
            self.shotCount += 1
            if let thumb { self.thumbnail = thumb }
        }
        let ext = output.availablePhotoCodecTypes.contains(.hevc) ? "heic" : "jpg"
        let spillover = self.spillover
        Task.detached(priority: .utility) {
            // Straight into Photos when allowed; otherwise park it for the app to import.
            if await Self.saveToPhotos(data) { return }
            guard let spillover else { return }
            let file = spillover.appendingPathComponent("\(Int(Date().timeIntervalSince1970 * 1000)).\(ext)")
            try? data.write(to: file)
        }
    }

    private static func saveToPhotos(_ data: Data) async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard status == .authorized || status == .limited else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }
            return true
        } catch {
            return false
        }
    }

    private static func thumbnail(from data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 160,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - Preview & hardware buttons

struct LockedPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewLayerView {
        let view = PreviewLayerView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: PreviewLayerView, context: Context) {}

    final class PreviewLayerView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

/// Volume buttons / Camera Control fire the shutter.
struct LockedCaptureEvents: UIViewRepresentable {
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let coordinator = context.coordinator
        coordinator.action = action
        let interaction = AVCaptureEventInteraction { event in
            if event.phase == .ended { coordinator.action?() }
        }
        view.addInteraction(interaction)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.action = action
    }

    final class Coordinator {
        var action: (() -> Void)?
    }
}

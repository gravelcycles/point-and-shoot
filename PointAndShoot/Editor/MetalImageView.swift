import CoreImage
import MetalKit
import SwiftUI

/// Draws a CIImage graph with Metal, aspect-fit. Re-renders only when the image changes,
/// so dragging an adjustment costs exactly one GPU pass per frame.
struct MetalImageView: UIViewRepresentable {
    let image: CIImage?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: EditPipeline.device)
        view.delegate = context.coordinator
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.autoResizeDrawable = true
        view.backgroundColor = .black
        view.isOpaque = true
        (view.layer as? CAMetalLayer)?.colorspace = EditPipeline.displayColorSpace
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.image = image
        view.setNeedsDisplay()
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        var image: CIImage?

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            view.setNeedsDisplay()
        }

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                  let commandBuffer = EditPipeline.queue.makeCommandBuffer() else { return }
            let size = view.drawableSize
            let bounds = CGRect(origin: .zero, size: size)
            var output = CIImage(color: .black).cropped(to: bounds)
            if let image, image.extent.width > 0, image.extent.height > 0, !image.extent.isInfinite {
                let e = image.extent
                let scale = min(size.width / e.width, size.height / e.height)
                let fitted = image
                    .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
                    .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                let tx = (size.width - e.width * scale) / 2
                let ty = (size.height - e.height * scale) / 2
                output = fitted
                    .transformed(by: CGAffineTransform(translationX: tx, y: ty))
                    .composited(over: output)
            }
            EditPipeline.context.render(output, to: drawable.texture, commandBuffer: commandBuffer,
                                        bounds: bounds, colorSpace: EditPipeline.displayColorSpace)
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}

/// Where an image of `imageSize` lands when aspect-fit into `container`.
func aspectFitRect(_ imageSize: CGSize, in container: CGSize) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0 else { return CGRect(origin: .zero, size: container) }
    let scale = min(container.width / imageSize.width, container.height / imageSize.height)
    let w = imageSize.width * scale, h = imageSize.height * scale
    return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
}

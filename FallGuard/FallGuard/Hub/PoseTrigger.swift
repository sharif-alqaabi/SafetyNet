import Combine
import CoreVideo
import Foundation
import UIKit
import Vision

@MainActor
final class PoseTrigger: ObservableObject {
    @Published private(set) var isDownCandidate = false
    @Published private(set) var wasUpright = false

    private var downStarted: Date?
    private let requiredDown: TimeInterval = 2
    var onFall: (() -> Void)?
    private var fired = false

    func reset() {
        isDownCandidate = false
        wasUpright = false
        downStarted = nil
        fired = false
    }

    func ingest(pixelBuffer: CVPixelBuffer) {
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return
        }
        guard let pose = request.results?.first else { return }
        evaluate(pose)
    }

    func ingest(jpeg: Data) {
        guard let image = UIImage(data: jpeg)?.cgImage else { return }
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        try? handler.perform([request])
        guard let pose = request.results?.first else { return }
        evaluate(pose)
    }

    private func evaluate(_ pose: VNHumanBodyPoseObservation) {
        guard
            let leftHip = try? pose.recognizedPoint(.leftHip),
            let rightHip = try? pose.recognizedPoint(.rightHip),
            let leftShoulder = try? pose.recognizedPoint(.leftShoulder),
            let rightShoulder = try? pose.recognizedPoint(.rightShoulder),
            leftHip.confidence > 0.3,
            rightHip.confidence > 0.3,
            leftShoulder.confidence > 0.3,
            rightShoulder.confidence > 0.3
        else { return }

        let hipY = (leftHip.location.y + rightHip.location.y) / 2
        let shoulderY = (leftShoulder.location.y + rightShoulder.location.y) / 2
        let shoulderX = (leftShoulder.location.x + rightShoulder.location.x) / 2
        let hipX = (leftHip.location.x + rightHip.location.x) / 2
        let dx = hipX - shoulderX
        let dy = hipY - shoulderY
        let angleFromVertical = abs(atan2(dx, dy))
        let hipsLow = hipY < 0.38
        let torsoHorizontal = angleFromVertical > (.pi / 2 - 0.55)
        let upright = hipY > 0.45 && angleFromVertical < 0.45

        if upright { wasUpright = true }

        if wasUpright && (hipsLow || torsoHorizontal) {
            isDownCandidate = true
            if downStarted == nil { downStarted = Date() }
            if !fired, let start = downStarted, Date().timeIntervalSince(start) >= requiredDown {
                fired = true
                onFall?()
            }
        } else {
            isDownCandidate = false
            downStarted = nil
        }
    }
}

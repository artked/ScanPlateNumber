import Foundation

import AVFoundation
import TesseractOCR
import UIKit
import Vision

typealias PropabilisticValue = (value: String, count: Int)

class Matches {
  private var numbers = [PropabilisticValue]()
  
  var matchesForResult: Int
  private var findAction: (String) -> ()
  
  init(matches: Int, action: @escaping (String) -> ()) {
    matchesForResult = matches
    findAction = action
  }
  
  func appendNumber(value: String) {
    print("RECOGNIZE TEXT:", value)
    if let index = numbers.index(where: { $0.value == value }) {
      var number = numbers[index]
      let newCount = number.count + 1
      if newCount >= matchesForResult {
        print("MATCH!!:", value)
        findAction(number.value)
      }
      number.count = newCount
      numbers[index] = number
    } else {
      numbers.append((value: value, count: 1))
    }
  }
}

class ScanViewController: UIViewController {
  private var font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
  
  private var tesseract = G8Tesseract(language: "eng", engineMode: .tesseractOnly)
  private var textDetectionRequest: VNDetectTextRectanglesRequest?
  private var textObservations = [VNTextObservation]()
  
  private let session = AVCaptureSession()
  private var cameraView: CameraView {
    return view as! CameraView
  }
  
  var scanAction: ((String) -> ())?
  
  private lazy var matches = Matches(matches: 10) { [weak self] result in
    self?.scanAction?(result)
    self?.session.stopRunning()
    self?.dismiss(animated: true, completion: nil)
  }
  
  // MARK: -
  
  override func viewDidLoad() {
    super.viewDidLoad()
    // Do any additional setup after loading the view, typically from a nib.
    tesseract?.pageSegmentationMode = .sparseText
    // Recognize only these characters
    tesseract?.charWhitelist = "ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890"
    if isAuthorized() {
      configureTextDetection()
      configureCamera()
    }
  }
  
  // MARK: - IBActions
  
  @IBAction func btnBackPressed(_: UIButton) {
    dismiss(animated: true, completion: nil)
  }
  
  // MARK: -
  
  private func isAuthorized() -> Bool {
    let authorizationStatus = AVCaptureDevice.authorizationStatus(for: AVMediaType.video)
    switch authorizationStatus {
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: AVMediaType.video,
                                    completionHandler: { [weak self] (granted: Bool) -> () in
                                      if granted {
                                        DispatchQueue.main.async {
                                          self?.configureTextDetection()
                                          self?.configureCamera()
                                        }
                                      }
      })
      return true
    case .authorized:
      return true
    case .denied, .restricted: return false
    }
  }
  
  private func configureTextDetection() {
    textDetectionRequest = VNDetectTextRectanglesRequest(completionHandler: handleDetection)
    textDetectionRequest?.reportCharacterBoxes = true
  }
  
  private func configureCamera() {
    cameraView.session = session
    
    let cameraDevices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: AVMediaType.video, position: .back)
    var cameraDevice: AVCaptureDevice?
    for device in cameraDevices.devices {
      if device.position == .back {
        cameraDevice = device
        break
      }
    }
    if let device = cameraDevice {
      do {
        let captureDeviceInput = try AVCaptureDeviceInput(device: device)
        if session.canAddInput(captureDeviceInput) {
          session.addInput(captureDeviceInput)
        }
      } catch {
        print("Error occured \(error)")
        return
      }
      session.sessionPreset = .high
      let videoDataOutput = AVCaptureVideoDataOutput()
      videoDataOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "Buffer Queue", qos: .userInteractive, attributes: .concurrent, autoreleaseFrequency: .inherit, target: nil))
      if session.canAddOutput(videoDataOutput) {
        session.addOutput(videoDataOutput)
      }
      cameraView.videoPreviewLayer.videoGravity = .resize
      session.startRunning()
    }
  }
  
  private func handleDetection(request: VNRequest, error _: Error?) {
    guard let detectionResults = request.results else {
      return
    }
    
    var textResults = detectionResults.map {
      return $0 as? VNTextObservation
    }
    textResults = textResults.filter({ result in
      guard let box = result?.boundingBox else { return false }
      return (box.minX > 0.2 && box.minY > 0.35 && box.maxX < 0.8 && box.maxY < 0.65)
    })
    
    if textResults.isEmpty {
      return
    }
    textObservations = textResults as! [VNTextObservation]
  }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension ScanViewController: AVCaptureVideoDataOutputSampleBufferDelegate {
  func captureOutput(_: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from _: AVCaptureConnection) {
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
      return
    }
    
    var ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    
    var imageRequestOptions = [VNImageOption: Any]()
    if let cameraData = CMGetAttachment(sampleBuffer, kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, nil) {
      imageRequestOptions[.cameraIntrinsics] = cameraData
    }
    let imageRequestHandler = VNImageRequestHandler(ciImage: ciImage, orientation: CGImagePropertyOrientation(rawValue: 6)!, options: imageRequestOptions)
    do {
      try imageRequestHandler.perform([textDetectionRequest!])
    } catch {
      print("Error occured \(error)")
    }
    
    let transform = ciImage.orientationTransform(for: CGImagePropertyOrientation(rawValue: 6)!)
    ciImage = ciImage.transformed(by: transform)
    let size = ciImage.extent.size
    var recognizedTextPositionTuples = [(rect: CGRect, text: String)]()
    for textObservation in textObservations {
      guard let rects = textObservation.characterBoxes else {
        continue
      }
      var xMin = CGFloat.greatestFiniteMagnitude
      var xMax: CGFloat = 0
      var yMin = CGFloat.greatestFiniteMagnitude
      var yMax: CGFloat = 0
      for rect in rects {
        xMin = min(xMin, rect.bottomLeft.x)
        xMax = max(xMax, rect.bottomRight.x)
        yMin = min(yMin, rect.bottomRight.y)
        yMax = max(yMax, rect.topRight.y)
      }
      let imageRect = CGRect(x: xMin * size.width, y: yMin * size.height, width: (xMax - xMin) * size.width, height: (yMax - yMin) * size.height)
      let context = CIContext(options: nil)
      guard let cgImage = context.createCGImage(ciImage, from: imageRect) else {
        continue
      }
      let uiImage = UIImage(cgImage: cgImage)
      tesseract?.image = uiImage
      tesseract?.recognize()
      guard var text = tesseract?.recognizedText else {
        continue
      }
      text = text.trimmingCharacters(in: CharacterSet.newlines)
      if !text.isEmpty {
        var texts = text.components(separatedBy: CharacterSet.newlines)
        texts = texts.compactMap({ $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) }).filter({ $0.count > 5 })
        
        texts.forEach({
          let x = xMin
          let y = 1 - yMax
          let width = xMax - xMin
          let height = yMax - yMin
          recognizedTextPositionTuples.append((rect: CGRect(x: x, y: y, width: width, height: height), text: $0))
        })
      }
    }
    textObservations.removeAll()
    DispatchQueue.main.async { [weak self] in
      for tuple in recognizedTextPositionTuples {
        self?.matches.appendNumber(value: tuple.text)
      }
    }
  }
}

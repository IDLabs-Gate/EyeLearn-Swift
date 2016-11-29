
//    The MIT License (MIT)
//
//    Copyright (c) 2016 ID Labs L.L.C.
//
//    Permission is hereby granted, free of charge, to any person obtaining a copy
//    of this software and associated documentation files (the "Software"), to deal
//    in the Software without restriction, including without limitation the rights
//    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//    copies of the Software, and to permit persons AVCaptureSessionto whom the Software is
//    furnished to do so, subject to the following conditions:
//
//    The above copyright notice and this permission notice shall be included in all
//    copies or substantial portions of the Software.
//
//    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//    SOFTWARE.
//

import UIKit
import Photos

private var cameraView: CameraView!

private var CapturingStillImageContext = UnsafeMutableRawPointer.allocate(bytes: 1, alignedTo: 128)//allocate(capacity: 1)
private var SessionRunningContext = UnsafeMutableRawPointer.allocate(bytes: 1, alignedTo: 128)

var frontCamera = false

// Session management
private let sessionQueue = DispatchQueue(label: "session queue", attributes: [])
private let framesQueue = DispatchQueue(label: "framesQueue", attributes: [])

private var session: AVCaptureSession!
private var videoDeviceInput: AVCaptureDeviceInput!
private var stillImageOutput: AVCaptureStillImageOutput!
private var videoDataOutput: AVCaptureVideoDataOutput!

enum AVCamSetupResult: Int {
    case success
    case cameraNotAuthorized
    case sessionConfigurationFailed
}

// Utils
private var setupResult: AVCamSetupResult = .success
private var sessionRunning = false
private var backgroundRecordingID: UIBackgroundTaskIdentifier = 0

private var dataQueueSuspended = false

private var timer: Timer?

extension ViewController : AVCaptureVideoDataOutputSampleBufferDelegate {

    func setupCam(_ completion:((Void)->Void)?) {
        
        sessionQueue.async {

            //Cam-related UI elements
            DispatchQueue.main.sync {
                
                cameraView?.removeFromSuperview()
                
                //cameraView
                cameraView = CameraView(frame: self.view.bounds)
                cameraView.layer.masksToBounds = true
                self.view.addSubview(cameraView)
                self.view.sendSubview(toBack: cameraView)
                cameraView.alpha = 1
                
            }
            
            // create AVCaptureSession
            session = AVCaptureSession()
            session.sessionPreset = AVCaptureSessionPresetHigh
            
            // setup the world view
            cameraView.session = session
            
            setupResult = .success
            
            // check video authorization status. Video access is required and audio access is optional
            // if audio access is denied, audio is not recorded during movie recording
            switch AVCaptureDevice.authorizationStatus(forMediaType: AVMediaTypeVideo) {
                
            case .authorized:
                // the user has previously granted access to the camera
                break
                
            case .notDetermined:
                // the user has not yet been presented with the option to grant video access.
                // we suspend the session queue to delay session setup until the access request has completed to avoid
                // asking the user for audio access if video access is denied.
                // note that audio access will be implicitly requested when we create an AVCaptureDeviceInput for audio during session setup
                sessionQueue.suspend()
                AVCaptureDevice.requestAccess(forMediaType: AVMediaTypeVideo) { granted in
                    if !granted {
                        setupResult = .cameraNotAuthorized
                    }
                    sessionQueue.resume()
                }
            default:
                // the user has previously denied access
                setupResult = .cameraNotAuthorized
            }
            
            // setup the capture session
            // in general it is not safe to mutate an AVCaptureSession or any of its inputs, or connections from multiple threads at the same time
            // why not do all of this on main queue?
            // because - AVCaptureSession.startRunning is a blocking call which can take a long time, we dispatch session setup to the sessionQueue
            // so that the main queue isn't blocked, which keeps the UI responsive
            
            guard setupResult == .success else {
                
                if let block = completion { DispatchQueue.main.async(execute: block) }
                return
            }
            
            backgroundRecordingID = UIBackgroundTaskInvalid
            
            guard let camera =  ViewController.deviceWithMediaType(AVMediaTypeVideo, preferringPosition: frontCamera ? .front : .back) else { return }
            let vidInput: AVCaptureDeviceInput!
            do {
                
                vidInput = try AVCaptureDeviceInput(device: camera)
            } catch let error as NSError {
                vidInput = nil
                NSLog("Could not create video device input: %@", error)
            } catch _ {
                fatalError()
            }
            
            session.beginConfiguration()
            
            if session.canAddInput(vidInput) {
                session.addInput(vidInput)
                videoDeviceInput = vidInput
                
                DispatchQueue.main.async{
                    // why are we dispatching this to the main queue?
                    // because AVCaptureVideoPreviewLayer is the backing layer for cameraView and UIView
                    // can only be manipulated on the main thread
                    // note: as an exception to the above rule, it is not necessary to serialize video orientation changes
                    // on the AVCaptureVideoPreviewLayer's connection with other session manipulation
                    
                    // use the status bar orientation as the initial video orientation. Subsequent orientation changes are handled by viewWillTransitionToSize:withTransitionCoordinator:
                    let statusBarOrientation = UIApplication.shared.statusBarOrientation
                    var initialVideoOrientation :AVCaptureVideoOrientation = .portrait
                    if statusBarOrientation != .unknown {
                        initialVideoOrientation = AVCaptureVideoOrientation(rawValue: statusBarOrientation.rawValue)!
                    }
                    
                    let previewLayer = cameraView.layer as! AVCaptureVideoPreviewLayer
                    previewLayer.connection.videoOrientation = initialVideoOrientation
                    previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill
                    
                }
            } else {
                NSLog("Could not add video device input to the session")
                setupResult = .sessionConfigurationFailed
            }
            
            /*
             //hight framerate format
             do {
             for vFormat in backCamera.formats {
             var ranges = vFormat.videoSupportedFrameRateRanges as! [AVFrameRateRange]
             let frameRates = ranges[0]
             if frameRates.maxFrameRate == 120 {
             try backCamera.lockForConfiguration()
             backCamera.activeFormat = vFormat as! AVCaptureDeviceFormat
             backCamera.activeVideoMinFrameDuration = CMTimeMake(10,1200)
             backCamera.activeVideoMaxFrameDuration = CMTimeMake(10,1200)
             backCamera.unlockForConfiguration()
             }
             }
             }
             catch {
             print("Error")
             }*/
            
            //videoData
            videoDataOutput = AVCaptureVideoDataOutput()
            
            videoDataOutput.videoSettings = NSDictionary(object: Int(kCVPixelFormatType_32BGRA),
                                                         forKey: kCVPixelBufferPixelFormatTypeKey as String as String as NSCopying) as! [AnyHashable: Any]
            
            videoDataOutput.alwaysDiscardsLateVideoFrames = true
            
            framesQueue.suspend(); dataQueueSuspended = true
            videoDataOutput .setSampleBufferDelegate(self, queue:framesQueue )
            
            if session .canAddOutput(videoDataOutput) { session .addOutput(videoDataOutput) }
            
            //orient frames to initial application orientation
            let statusBarOrientation = UIApplication.shared.statusBarOrientation
            if statusBarOrientation != .unknown {
                videoDataOutput.connection(withMediaType: AVMediaTypeVideo).videoOrientation = AVCaptureVideoOrientation(rawValue: statusBarOrientation.rawValue)! }
            
            //Still Image
            let still = AVCaptureStillImageOutput()
            if session.canAddOutput(still) {
                still.outputSettings = [AVVideoCodecKey: AVVideoCodecJPEG]
                session.addOutput(still)
                stillImageOutput = still
            } else {
                NSLog("Could not add still image output to the session")
                setupResult = .sessionConfigurationFailed
                
            }
            
            session.commitConfiguration()
            
            //start cam
            if setupResult == .success {
                session.startRunning()//blocking call
                sessionRunning = session.isRunning
            }
            
            if let block = completion { DispatchQueue.main.async(execute: block) }
            
        }
        
    }
    
    @IBAction func toggleCamAction(_ sender: Any) {
        
        guard let button = sender as? UIButton else { return }
        button.isEnabled = false
        
        stopCam()
        
        frontCamera = !frontCamera
        toggleCamButton.setTitle(frontCamera ? " F " : " B ", for: UIControlState())
        
        setupCam(){
            self.loadAllPredictors()
            
            self.resumeFrames()
            
            self.view.removeActivityIndicatorOverlay()
            
            button.isEnabled = true
        }
    }
    
    func checkCam() -> AVCamSetupResult {
        
        sessionQueue.async {
            switch setupResult {
            case .success:
                // only setupt observers and start the session running if setup succeeded
                
                self.addObservers()
                //session.startRunning()
                //sessionRunning = session.running
                
                break
                
            case .cameraNotAuthorized:
                DispatchQueue.main.async {
                    let message = NSLocalizedString("App doesn't have permission to use the camera, please change privacy settings", comment: "The user has denied access to the camera")
                    let alertController = UIAlertController(title: "Permission for App", message: message, preferredStyle: .alert)
                    let cancelAction = UIAlertAction(title: NSLocalizedString("OK", comment: "Alert OK button"), style: .cancel, handler: nil)
                    alertController.addAction(cancelAction)
                    // provide quick access to Settings.
                    let settingsAction = UIAlertAction(title: NSLocalizedString("Settings", comment: "Alert button to open Settings"), style: .default) { action in
                        UIApplication.shared.openURL(URL(string: UIApplicationOpenSettingsURLString)!)
                    }
                    alertController.addAction(settingsAction)
                    self.present(alertController, animated: true, completion: nil)
                }
            case .sessionConfigurationFailed:
                DispatchQueue.main.async {
                    let message = NSLocalizedString("Unable to capture media", comment: "Something went wrong during capture session configuration")
                    let alertController = UIAlertController(title: "Permission for App", message: message, preferredStyle: .alert)
                    let cancelAction = UIAlertAction(title: NSLocalizedString("OK", comment: "Alert OK button"), style: .cancel, handler: nil)
                    alertController.addAction(cancelAction)
                    self.present(alertController, animated: true, completion: nil)
                }
            }
        }

        return setupResult
    }
    
    
    func stopCam() {

        sessionQueue.async {
            if setupResult == .success {
                self.suspendFrames()
                session.stopRunning()
                sessionRunning = false
                
                //self .removeObservers()
            }
        }
        
    }

    
    func startCam() {

        sessionQueue.async {
            
            if setupResult == .success {
                session.startRunning()
                sessionRunning = session.isRunning
            }
        
        }
    }
    
    
    func captureOutput(_ captureOutput: AVCaptureOutput!, didOutputSampleBuffer sampleBuffer: CMSampleBuffer!, from connection: AVCaptureConnection!) {
        
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        sourcePixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)

        if let fdesc = CMSampleBufferGetFormatDescription(sampleBuffer){
            clap = CMVideoFormatDescriptionGetCleanAperture(fdesc, false /*originIsTopLeft == false*/)

        }
        
        let frameImage = CIImage(cvPixelBuffer: pixelBuffer)
        
        processFrame(frameImage);

    }
    
    func resumeFrames() {
        
        sessionQueue.async{
            if dataQueueSuspended { framesQueue.resume() }
            dataQueueSuspended = false
        }
        
    }

    
    func suspendFrames() {
       
        sessionQueue.async {
            if !dataQueueSuspended { framesQueue.suspend() }
            dataQueueSuspended = true
        }
        
        timer?.invalidate()
        timer = nil
    }
    
    func orientCam() {

        // note that the app delegate controls the device orientation notifications required to use the device orientation
        let deviceOrientation = UIDevice.current.orientation
        if UIDeviceOrientationIsPortrait(deviceOrientation) || UIDeviceOrientationIsLandscape(deviceOrientation) {
            let previewLayer = cameraView.layer as! AVCaptureVideoPreviewLayer
            previewLayer.connection.videoOrientation = AVCaptureVideoOrientation(rawValue: deviceOrientation.rawValue)!
            videoDataOutput.connection(withMediaType: AVMediaTypeVideo).videoOrientation = AVCaptureVideoOrientation(rawValue: deviceOrientation.rawValue)!
        }

    }
    
    
    func stillImageCapture(_ handler: @escaping (Data) -> Void) {
        
        sessionQueue.async {
            let connection = stillImageOutput.connection(withMediaType: AVMediaTypeVideo)
            let previewLayer = cameraView.layer as! AVCaptureVideoPreviewLayer
            
            // Update the orientation on the still image output video connection before capturing.
            connection?.videoOrientation = previewLayer.connection.videoOrientation
            
            // Flash set to Auto for Still Capture.
            ViewController.setFlashMode(AVCaptureFlashMode.auto, forDevice: videoDeviceInput.device)
            
            // Capture a still image.
            stillImageOutput.captureStillImageAsynchronously(from: connection) { (imageDataSampleBuffer, error) -> Void in
                
                if imageDataSampleBuffer != nil {
                    // The sample buffer is not retained. Create image data before saving the still image to the photo library asynchronously.
                    let imageData = AVCaptureStillImageOutput.jpegStillImageNSDataRepresentation(imageDataSampleBuffer)

                    handler(imageData!)
                    
                } else {
                    print("Could not capture still image")
                }
            }
            
        }
        
    }

    //MARK: KVO and Notifications
    
    fileprivate func addObservers() {
        session.addObserver(self, forKeyPath: "running", options: NSKeyValueObservingOptions.new, context: SessionRunningContext)
        stillImageOutput.addObserver(self, forKeyPath: "capturingStillImage", options:NSKeyValueObservingOptions.new, context: CapturingStillImageContext)
        
        NotificationCenter.default.addObserver(self, selector: #selector(ViewController.subjectAreaDidChange(_:)), name: NSNotification.Name.AVCaptureDeviceSubjectAreaDidChange, object: videoDeviceInput.device)
    }
    
    fileprivate func removeObservers() {
        NotificationCenter.default.removeObserver(self)
        
        session.removeObserver(self, forKeyPath: "running", context: SessionRunningContext)
        stillImageOutput.removeObserver(self, forKeyPath: "capturingStillImage", context: CapturingStillImageContext)
    }
    
    func subjectAreaDidChange(_ notification: Notification) {
        let devicePoint = CGPoint(x: 0.5, y: 0.5)
        self.focusWithMode(AVCaptureFocusMode.continuousAutoFocus, exposeWithMode: AVCaptureExposureMode.continuousAutoExposure, atDevicePoint: devicePoint, monitorSubjectAreaChange: false)
    }
    
    //MARK: Actions

    @IBAction func focusAndExposeTap(_ gestureRecognizer: UIGestureRecognizer) {
        let devicePoint = (cameraView.layer as! AVCaptureVideoPreviewLayer).captureDevicePointOfInterest(for: gestureRecognizer.location(in: gestureRecognizer.view))
        self.focusWithMode(AVCaptureFocusMode.autoFocus, exposeWithMode: AVCaptureExposureMode.autoExpose, atDevicePoint: devicePoint, monitorSubjectAreaChange: true)

    }

    //MARK: Device Configuration
    func focusWithMode(_ focusMode: AVCaptureFocusMode, exposeWithMode exposureMode: AVCaptureExposureMode, atDevicePoint point:CGPoint, monitorSubjectAreaChange: Bool) {
        sessionQueue.async {
            let device = videoDeviceInput.device
            do {
                try device?.lockForConfiguration()
                defer {device?.unlockForConfiguration()}
                // Setting (focus/exposure)PointOfInterest alone does not initiate a (focus/exposure) operation.
                // Call -set(Focus/Exposure)Mode: to apply the new point of interest.
                if (device?.isFocusPointOfInterestSupported)! && (device?.isFocusModeSupported(focusMode))! {
                    device?.focusPointOfInterest = point
                    device?.focusMode = focusMode
                }
                
                if (device?.isExposurePointOfInterestSupported)! && (device?.isExposureModeSupported(exposureMode))! {
                    device?.exposurePointOfInterest = point
                    device?.exposureMode = exposureMode
                }
                
                device?.isSubjectAreaChangeMonitoringEnabled = monitorSubjectAreaChange
            } catch let error as NSError {
                NSLog("Could not lock device for configuration: %@", error)
            } catch _ {}
        }
    }
    
    class func setFlashMode(_ flashMode: AVCaptureFlashMode, forDevice device: AVCaptureDevice) {
        if device.hasFlash && device.isFlashModeSupported(flashMode) {
            do {
                try device.lockForConfiguration()
                defer {device.unlockForConfiguration()}
                device.flashMode = flashMode
            } catch let error as NSError {
                NSLog("Could not lock device for configuration: %@", error)
            }
        }
    }

    class func deviceWithMediaType(_ mediaType: String, preferringPosition position: AVCaptureDevicePosition) -> AVCaptureDevice? {
        let devices = AVCaptureDevice.devices(withMediaType: mediaType)
        var captureDevice = devices?.first as! AVCaptureDevice?
        
        for device in devices as! [AVCaptureDevice] {
            if device.position == position {
                captureDevice = device
                break
            }
        }
        
        return captureDevice
    }
        
}

class CameraView: UIView {
    
    override class var layerClass : AnyClass {
        
        return AVCaptureVideoPreviewLayer.self
    }
    
    var session : AVCaptureSession {
        
        get {
            
            let previewLayer = self.layer as! AVCaptureVideoPreviewLayer
            return previewLayer.session
        }
        
        set (session) {
            
            let previewLayer = self.layer as! AVCaptureVideoPreviewLayer
            previewLayer.session = session
            
        }
    }
    
}

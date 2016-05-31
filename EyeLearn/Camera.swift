
//    The MIT License (MIT)
//
//    Copyright (c) 2016 ID Labs L.L.C.
//
//    Permission is hereby granted, free of charge, to any person obtaining a copy
//    of this software and associated documentation files (the "Software"), to deal
//    in the Software without restriction, including without limitation the rights
//    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//    copies of the Software, and to permit persons to whom the Software is
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

private var CapturingStillImageContext = UnsafeMutablePointer<Void>.alloc(1)
private var SessionRunningContext = UnsafeMutablePointer<Void>.alloc(1)

private var cameraUnavailableLabel: UILabel!
private var resumeButton: UIButton!

// Session management
private var sessionQueue: dispatch_queue_t!
private var session: AVCaptureSession!
private var videoDeviceInput: AVCaptureDeviceInput!
private var stillImageOutput: AVCaptureStillImageOutput!
private var videoDataOutput: AVCaptureVideoDataOutput!

enum AVCamSetupResult: Int {
    case Success
    case CameraNotAuthorized
    case SessionConfigurationFailed
}

// Utils
private var setupResult: AVCamSetupResult = .Success
private var sessionRunning = false
private var backgroundRecordingID: UIBackgroundTaskIdentifier = 0

private var framesQueue : dispatch_queue_t!
private var dataQueueSuspended = false

private var timer: NSTimer?

extension ViewController : AVCaptureVideoDataOutputSampleBufferDelegate {

    func setupCam(completion:(Void->Void)?) {
        
        //Cam-related UI elements
        do {
            
            //cameraView
            cameraView = CameraView(frame: view.bounds)
            cameraView.layer.masksToBounds = true
            view .addSubview(cameraView)
            view.sendSubviewToBack(cameraView)
            cameraView.alpha = 1

            resumeButton = UIButton(frame: CGRect(origin: cameraView.center, size: CGSize(width: 150, height: 50)))
            resumeButton .setTitle("Resume", forState: .Normal)
            resumeButton .setTitleColor(UIColor.whiteColor(), forState: .Normal)
            resumeButton.backgroundColor = UIColor.lightGrayColor().colorWithAlphaComponent(0.5)
            resumeButton .addTarget(self, action: #selector(ViewController.resumeInterruptedSession(_:)), forControlEvents: .TouchUpInside)
            resumeButton.center = cameraView.center
            resumeButton.hidden = true
            cameraView .addSubview(resumeButton)
            
            cameraUnavailableLabel = UILabel(frame: CGRect(origin: cameraView.center, size: CGSize(width: 200, height: 50)))
            cameraUnavailableLabel.text = "Camera Unavailable"
            cameraUnavailableLabel.textColor = UIColor.whiteColor()
            cameraUnavailableLabel.textAlignment = .Center
            cameraUnavailableLabel.backgroundColor = UIColor.lightGrayColor().colorWithAlphaComponent(0.5)
            cameraUnavailableLabel.center = cameraView.center
            cameraUnavailableLabel.hidden = true
            cameraView .addSubview(cameraUnavailableLabel)
        }
        
        // create AVCaptureSession
        session = AVCaptureSession()
        session.sessionPreset = AVCaptureSessionPresetHigh
        
        // setup the world view
        cameraView.session = session
        
        // communicate with the session and other session objects on this queue
        sessionQueue = dispatch_queue_create("session queue", DISPATCH_QUEUE_SERIAL)
        framesQueue = dispatch_queue_create("framesQueue", DISPATCH_QUEUE_SERIAL)
        
        setupResult = .Success
        
        // check video authorization status. Video access is required and audio access is optional
        // if audio access is denied, audio is not recorded during movie recording
        switch AVCaptureDevice.authorizationStatusForMediaType(AVMediaTypeVideo) {
            
        case .Authorized:
            // the user has previously granted access to the camera
            break
            
        case .NotDetermined:
            // the user has not yet been presented with the option to grant video access.
            // we suspend the session queue to delay session setup until the access request has completed to avoid
            // asking the user for audio access if video access is denied.
            // note that audio access will be implicitly requested when we create an AVCaptureDeviceInput for audio during session setup
            dispatch_suspend(sessionQueue)
            AVCaptureDevice.requestAccessForMediaType(AVMediaTypeVideo) { granted in
                if !granted {
                    setupResult = .CameraNotAuthorized
                }
                dispatch_resume(sessionQueue)
            }
        default:
            // the user has previously denied access
            setupResult = .CameraNotAuthorized
        }
        
        // setup the capture session
        // in general it is not safe to mutate an AVCaptureSession or any of its inputs, or connections from multiple threads at the same time
        // why not do all of this on main queue?
        // because - AVCaptureSession.startRunning is a blocking call which can take a long time, we dispatch session setup to the sessionQueue
        // so that the main queue isn't blocked, which keeps the UI responsive
        dispatch_async(sessionQueue) {
            guard setupResult == .Success else {

                if let block = completion { dispatch_async(dispatch_get_main_queue(), block) }
                return
            }
            
            backgroundRecordingID = UIBackgroundTaskInvalid
            
            guard let backCamera = ViewController.deviceWithMediaType(AVMediaTypeVideo, preferringPosition: .Back) else { return }
            let vidInput: AVCaptureDeviceInput!
            do {
                
                vidInput = try AVCaptureDeviceInput(device: backCamera)
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

                dispatch_async(dispatch_get_main_queue()){
                    // why are we dispatching this to the main queue?
                    // because AVCaptureVideoPreviewLayer is the backing layer for cameraView and UIView
                    // can only be manipulated on the main thread
                    // note: as an exception to the above rule, it is not necessary to serialize video orientation changes
                    // on the AVCaptureVideoPreviewLayer's connection with other session manipulation
                    
                    // use the status bar orientation as the initial video orientation. Subsequent orientation changes are handled by viewWillTransitionToSize:withTransitionCoordinator:
                    let statusBarOrientation = UIApplication.sharedApplication().statusBarOrientation
                    var initialVideoOrientation :AVCaptureVideoOrientation = .Portrait
                    if statusBarOrientation != .Unknown {
                        initialVideoOrientation = AVCaptureVideoOrientation(rawValue: statusBarOrientation.rawValue)!
                    }
                    
                    let previewLayer = cameraView.layer as! AVCaptureVideoPreviewLayer
                    previewLayer.connection.videoOrientation = initialVideoOrientation
                    previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill
                    
                }
            } else {
                NSLog("Could not add video device input to the session")
                setupResult = .SessionConfigurationFailed
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
                forKey: kCVPixelBufferPixelFormatTypeKey as String) as! [NSObject : AnyObject]
            
            videoDataOutput.alwaysDiscardsLateVideoFrames = true
            
            dispatch_suspend(framesQueue); dataQueueSuspended = true
            videoDataOutput .setSampleBufferDelegate(self, queue:framesQueue )
            
            if session .canAddOutput(videoDataOutput) { session .addOutput(videoDataOutput) }

            //orient frames to initial application orientation
            let statusBarOrientation = UIApplication.sharedApplication().statusBarOrientation
            if statusBarOrientation != .Unknown {
                videoDataOutput.connectionWithMediaType(AVMediaTypeVideo).videoOrientation = AVCaptureVideoOrientation(rawValue: statusBarOrientation.rawValue)! }

            //Still Image
            let still = AVCaptureStillImageOutput()
            if session.canAddOutput(still) {
                still.outputSettings = [AVVideoCodecKey: AVVideoCodecJPEG]
                session.addOutput(still)
                stillImageOutput = still
            } else {
                NSLog("Could not add still image output to the session")
                setupResult = .SessionConfigurationFailed
                
            }
            
            session.commitConfiguration()
            
            //start cam
            if setupResult == .Success {
                session.startRunning()//blocking call
                sessionRunning = session.running
            }
            
            if let block = completion { dispatch_async(dispatch_get_main_queue(), block) }

        }
        
    }

    
    func checkCam() -> AVCamSetupResult {
        
        dispatch_async(sessionQueue) {
            switch setupResult {
            case .Success:
                // only setupt observers and start the session running if setup succeeded
                
                self.addObservers()
                //session.startRunning()
                //sessionRunning = session.running
                
                break
                
            case .CameraNotAuthorized:
                dispatch_async(dispatch_get_main_queue()) {
                    let message = NSLocalizedString("App doesn't have permission to use the camera, please change privacy settings", comment: "The user has denied access to the camera")
                    let alertController = UIAlertController(title: "Permission for App", message: message, preferredStyle: .Alert)
                    let cancelAction = UIAlertAction(title: NSLocalizedString("OK", comment: "Alert OK button"), style: .Cancel, handler: nil)
                    alertController.addAction(cancelAction)
                    // provide quick access to Settings.
                    let settingsAction = UIAlertAction(title: NSLocalizedString("Settings", comment: "Alert button to open Settings"), style: .Default) { action in
                        UIApplication.sharedApplication().openURL(NSURL(string: UIApplicationOpenSettingsURLString)!)
                    }
                    alertController.addAction(settingsAction)
                    self.presentViewController(alertController, animated: true, completion: nil)
                }
            case .SessionConfigurationFailed:
                dispatch_async(dispatch_get_main_queue()) {
                    let message = NSLocalizedString("Unable to capture media", comment: "Something went wrong during capture session configuration")
                    let alertController = UIAlertController(title: "Permission for App", message: message, preferredStyle: .Alert)
                    let cancelAction = UIAlertAction(title: NSLocalizedString("OK", comment: "Alert OK button"), style: .Cancel, handler: nil)
                    alertController.addAction(cancelAction)
                    self.presentViewController(alertController, animated: true, completion: nil)
                }
            }
        }

        return setupResult
    }
    
    
    func stopCam() {

        dispatch_async(sessionQueue) {
            if setupResult == .Success {
                session.stopRunning()
                sessionRunning = false
                //self .removeObservers()
            }
        }
        
    }

    
    func startCam() {

        dispatch_async(sessionQueue) {
            
            if setupResult == .Success {
                session.startRunning()
                sessionRunning = session.running
            }
        
        }
    }
    
    
    func captureOutput(captureOutput: AVCaptureOutput!, didOutputSampleBuffer sampleBuffer: CMSampleBuffer!, fromConnection connection: AVCaptureConnection!) {
        
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        sourcePixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)

        if let fdesc = CMSampleBufferGetFormatDescription(sampleBuffer){
            clap = CMVideoFormatDescriptionGetCleanAperture(fdesc, false /*originIsTopLeft == false*/)

        }
        
        let frameImage = CIImage(CVPixelBuffer: pixelBuffer)
        
        processFrame(frameImage);

    }
    
    func resumeFrames() {
        
        dispatch_async(sessionQueue){
            if dataQueueSuspended { dispatch_resume(framesQueue) }
            dataQueueSuspended = false
        }
        
    }

    
    func suspendFrames() {
       
        dispatch_async(sessionQueue) {
            if !dataQueueSuspended { dispatch_suspend(framesQueue) }
            dataQueueSuspended = true
        }
        
        timer?.invalidate()
        timer = nil
    }
    
    func orientCam() {

        // note that the app delegate controls the device orientation notifications required to use the device orientation
        let deviceOrientation = UIDevice.currentDevice().orientation
        if UIDeviceOrientationIsPortrait(deviceOrientation) || UIDeviceOrientationIsLandscape(deviceOrientation) {
            let previewLayer = cameraView.layer as! AVCaptureVideoPreviewLayer
            previewLayer.connection.videoOrientation = AVCaptureVideoOrientation(rawValue: deviceOrientation.rawValue)!
            videoDataOutput.connectionWithMediaType(AVMediaTypeVideo).videoOrientation = AVCaptureVideoOrientation(rawValue: deviceOrientation.rawValue)!
        }

    }
    
    
    func stillImageCapture(handler: (NSData) -> Void) {
        
        dispatch_async(sessionQueue) {
            let connection = stillImageOutput.connectionWithMediaType(AVMediaTypeVideo)
            let previewLayer = cameraView.layer as! AVCaptureVideoPreviewLayer
            
            // Update the orientation on the still image output video connection before capturing.
            connection.videoOrientation = previewLayer.connection.videoOrientation
            
            // Flash set to Auto for Still Capture.
            ViewController.setFlashMode(AVCaptureFlashMode.Auto, forDevice: videoDeviceInput.device)
            
            // Capture a still image.
            stillImageOutput.captureStillImageAsynchronouslyFromConnection(connection) { (imageDataSampleBuffer, error) -> Void in
                
                if imageDataSampleBuffer != nil {
                    // The sample buffer is not retained. Create image data before saving the still image to the photo library asynchronously.
                    let imageData = AVCaptureStillImageOutput.jpegStillImageNSDataRepresentation(imageDataSampleBuffer)

                    handler(imageData)
                    
                } else {
                    NSLog("Could not capture still image: %@", error)
                }
            }
            
        }
        
    }

    //MARK: KVO and Notifications
    
    private func addObservers() {
        session.addObserver(self, forKeyPath: "running", options: NSKeyValueObservingOptions.New, context: SessionRunningContext)
        stillImageOutput.addObserver(self, forKeyPath: "capturingStillImage", options:NSKeyValueObservingOptions.New, context: CapturingStillImageContext)
        
        NSNotificationCenter.defaultCenter().addObserver(self, selector: #selector(ViewController.subjectAreaDidChange(_:)), name: AVCaptureDeviceSubjectAreaDidChangeNotification, object: videoDeviceInput.device)
        NSNotificationCenter.defaultCenter().addObserver(self, selector: #selector(ViewController.sessionRuntimeError(_:)), name: AVCaptureSessionRuntimeErrorNotification, object: session)
        // A session can only run when the app is full screen. It will be interrupted in a multi-app layout, introduced in iOS 9,
        // see also the documentation of AVCaptureSessionInterruptionReason. Add observers to handle these session interruptions
        // and show a preview is paused message. See the documentation of AVCaptureSessionWasInterruptedNotification for other
        // interruption reasons.
        NSNotificationCenter.defaultCenter().addObserver(self, selector: #selector(ViewController.sessionWasInterrupted(_:)), name: AVCaptureSessionWasInterruptedNotification, object: session)
        NSNotificationCenter.defaultCenter().addObserver(self, selector: #selector(ViewController.sessionInterruptionEnded(_:)), name: AVCaptureSessionInterruptionEndedNotification, object: session)
    }
    
    private func removeObservers() {
        NSNotificationCenter.defaultCenter().removeObserver(self)
        
        session.removeObserver(self, forKeyPath: "running", context: SessionRunningContext)
        stillImageOutput.removeObserver(self, forKeyPath: "capturingStillImage", context: CapturingStillImageContext)
    }
    
    override func observeValueForKeyPath(keyPath: String?, ofObject object: AnyObject?, change: [String : AnyObject]?, context: UnsafeMutablePointer<Void>) {
        switch context {
        case CapturingStillImageContext:
            
            let isCapturingStillImage = change![NSKeyValueChangeNewKey]! as! Bool
            
            if isCapturingStillImage {
                dispatch_async(dispatch_get_main_queue()) {
                    cameraView.layer.opacity = 0.0
                    UIView.animateWithDuration(0.25) {
                        cameraView.layer.opacity = 1.0
                    }
                }
            }
        case SessionRunningContext:
            //let isSessionRunning = change![NSKeyValueChangeNewKey]! as! Bool
            
            dispatch_async(dispatch_get_main_queue()) {
                //self.snapGesture.enabled = isSessionRunning
                //self.quickSnapGesture.enabled = isSessionRunning
            }
        default:
            super.observeValueForKeyPath(keyPath, ofObject: object, change: change, context: context)
        }
    }
    
    func subjectAreaDidChange(notification: NSNotification) {
        let devicePoint = CGPointMake(0.5, 0.5)
        self.focusWithMode(AVCaptureFocusMode.ContinuousAutoFocus, exposeWithMode: AVCaptureExposureMode.ContinuousAutoExposure, atDevicePoint: devicePoint, monitorSubjectAreaChange: false)
    }
    
    func sessionRuntimeError(notification: NSNotification) {
        let error = notification.userInfo![AVCaptureSessionErrorKey]! as! NSError
        NSLog("Capture session runtime error: %@", error)
        
        // Automatically try to restart the session running if media services were reset and the last start running succeeded.
        // Otherwise, enable the user to try to resume the session running.
        if error.code == AVError.MediaServicesWereReset.rawValue {
            dispatch_async(sessionQueue) {
                if sessionRunning {
                    session.startRunning()
                    sessionRunning = session.running
                } else {
                    dispatch_async(dispatch_get_main_queue()) {
                        resumeButton.hidden = false
                    }
                }
            }
        } else {
            resumeButton.hidden = false
        }
    }
    
    func sessionWasInterrupted(notification: NSNotification) {
        // In some scenarios we want to enable the user to resume the session running.
        // For example, if music playback is initiated via control center while using AVCam,
        // then the user can let AVCam resume the session running, which will stop music playback.
        // Note that stopping music playback in control center will not automatically resume the session running.
        // Also note that it is not always possible to resume, see -[resumeInterruptedSession:].
        var showResumeButton = false
        
        
        let reason = notification.userInfo![AVCaptureSessionInterruptionReasonKey]! as! Int
        NSLog("Capture session was interrupted with reason %ld", reason)
        
        if reason == AVCaptureSessionInterruptionReason.AudioDeviceInUseByAnotherClient.rawValue ||
            reason == AVCaptureSessionInterruptionReason.VideoDeviceInUseByAnotherClient.rawValue {
            showResumeButton = true
        } else if reason == AVCaptureSessionInterruptionReason.VideoDeviceNotAvailableWithMultipleForegroundApps.rawValue {
            // Simply fade-in a label to inform the user that the camera is unavailable.
            cameraUnavailableLabel.hidden = false
            cameraUnavailableLabel.alpha = 0.0
            UIView.animateWithDuration(0.25) {
                cameraUnavailableLabel.alpha = 1.0
            }
        }
        
        if showResumeButton {
            // Simply fade-in a button to enable the user to try to resume the session running.
            resumeButton.hidden = false
            resumeButton.alpha = 0.0
            UIView.animateWithDuration(0.25) {
                resumeButton.alpha = 1.0
            }
        }
    }
    
    func sessionInterruptionEnded(notification: NSNotification) {
        NSLog("Capture session interruption ended")
        
        if !resumeButton.hidden {
            UIView.animateWithDuration(0.25, animations: {
                resumeButton.alpha = 0.0
                }, completion: {finished in
                    resumeButton.hidden = true
            })
        }
        if !cameraUnavailableLabel.hidden {
            UIView.animateWithDuration(0.25, animations: {
                cameraUnavailableLabel.alpha = 0.0
                }, completion: {finished in
                    cameraUnavailableLabel.hidden = true
            })
        }
    }

    //MARK: Actions
    
    func resumeInterruptedSession(sender: AnyObject) {
    
        dispatch_async(sessionQueue) {
            // The session might fail to start running, e.g., if a phone or FaceTime call is still using audio or video.
            // A failure to start the session running will be communicated via a session runtime error notification.
            // To avoid repeatedly failing to start the session running, we only try to restart the session running in the
            // session runtime error handler if we aren't trying to resume the session running.
            session.startRunning()
            sessionRunning = session.running
            if !session.running {
                dispatch_async(dispatch_get_main_queue()) {
                    let message = NSLocalizedString("Unable to resume", comment: "Alert message when unable to resume the session running")
                    let alertController = UIAlertController(title: "AVCam", message: message, preferredStyle: UIAlertControllerStyle.Alert)
                    let cancelAction = UIAlertAction(title: NSLocalizedString("OK", comment: "Alert OK button"), style: UIAlertActionStyle.Cancel, handler: nil)
                    alertController.addAction(cancelAction)
                    self.presentViewController(alertController, animated: true, completion: nil)
                }
            } else {
                dispatch_async(dispatch_get_main_queue()) {
                    resumeButton.hidden = true
                }
            }
        }
    }
    

    @IBAction func focusAndExposeTap(gestureRecognizer: UIGestureRecognizer) {
        let devicePoint = (cameraView.layer as! AVCaptureVideoPreviewLayer).captureDevicePointOfInterestForPoint(gestureRecognizer.locationInView(gestureRecognizer.view))
        self.focusWithMode(AVCaptureFocusMode.AutoFocus, exposeWithMode: AVCaptureExposureMode.AutoExpose, atDevicePoint: devicePoint, monitorSubjectAreaChange: true)

    }

    //MARK: Device Configuration
    func focusWithMode(focusMode: AVCaptureFocusMode, exposeWithMode exposureMode: AVCaptureExposureMode, atDevicePoint point:CGPoint, monitorSubjectAreaChange: Bool) {
        dispatch_async(sessionQueue) {
            let device = videoDeviceInput.device
            do {
                try device.lockForConfiguration()
                defer {device.unlockForConfiguration()}
                // Setting (focus/exposure)PointOfInterest alone does not initiate a (focus/exposure) operation.
                // Call -set(Focus/Exposure)Mode: to apply the new point of interest.
                if device.focusPointOfInterestSupported && device.isFocusModeSupported(focusMode) {
                    device.focusPointOfInterest = point
                    device.focusMode = focusMode
                }
                
                if device.exposurePointOfInterestSupported && device.isExposureModeSupported(exposureMode) {
                    device.exposurePointOfInterest = point
                    device.exposureMode = exposureMode
                }
                
                device.subjectAreaChangeMonitoringEnabled = monitorSubjectAreaChange
            } catch let error as NSError {
                NSLog("Could not lock device for configuration: %@", error)
            } catch _ {}
        }
    }
    
    class func setFlashMode(flashMode: AVCaptureFlashMode, forDevice device: AVCaptureDevice) {
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

    class func deviceWithMediaType(mediaType: String, preferringPosition position: AVCaptureDevicePosition) -> AVCaptureDevice? {
        let devices = AVCaptureDevice.devicesWithMediaType(mediaType)
        var captureDevice = devices.first as! AVCaptureDevice?
        
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
    
    override class func layerClass() -> AnyClass {
        
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

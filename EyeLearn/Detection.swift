
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

private var nextState = PredictionState.start


private var predictors = NSPointerArray(options: .opaqueMemory)
private var predictorNames = [String]()
private var trainer : UnsafeMutableRawPointer? = nil
private var trainingName = String()

private let groupAlg = DispatchGroup()
private var lockAlg = false

private var transRatio = CGFloat(0)

let jobQueue = DispatchQueue(label: "jobQueue", attributes: [])

private var objectText = ""
private var faceText = ""

//neural network
private let network = jpcnn_create_network((Bundle.main.path(forResource: "jetpac", ofType: "ntwk")! as NSString).utf8String)

//svm
private var sampleCount = 0
//private var negativePredictionsCount = 0
var totalSamplesPlus = 50
var totalSamplesMinus = 50

private let faceDetector = CIDetector(ofType: CIDetectorTypeFace, context: nil, options: [ CIDetectorAccuracy : CIDetectorAccuracyLow ])

extension ViewController {
    
    func processFrame(_ frameImage: CIImage){
        
        let startTime = Date()
        
        let w = frameImage.extent.size.width
        let h = frameImage.extent.size.height
        
        transRatio = h/view.bounds.height
        let deltaX = (w-view.bounds.width*transRatio)/2
        
        
        defer {
            announce()
            
            //keep at least 0.2 sec between processing frames
            while Double(Date().timeIntervalSince(startTime))<0.2 {}
        }
        
        //Face Detection Algorithm
        
        var mask = CGRect(x: deltaX, y: 0, width: view.bounds.width*h/view.bounds.height, height: h) //full screen
        DispatchQueue.global(priority: DispatchQueue.GlobalQueuePriority.low).sync{
            
            self.detectFaces(frameImage, rect: mask)
        }

        
        //Object Recognition Algorithm
        guard !lockAlg else { return }
        lockAlg = true

        if let selection = selectRect {
            mask = CGRect(x: selection.origin.x*transRatio+deltaX, y: selection.origin.y*transRatio, width: selection.size.width*transRatio, height: selection.size.height*transRatio)
            
            //translate CoreImage coordinates to UIKit coordinates
            var transform = CGAffineTransform(scaleX: 1, y: -1)
            transform = transform.translatedBy(x: 0, y: -view.bounds.height*transRatio)
            
            mask = mask.applying(transform)
        }
        
        DispatchQueue.global(priority: DispatchQueue.GlobalQueuePriority.high).async(group: groupAlg){
            
            if let obj = self.predictObjects(frameImage,rect: mask){
                
                objectText = ""
                
                switch (self.state) {
                    
                case .learningPlus:
                    
                    jpcnn_train(trainer, 1.0, obj.predictions, obj.length)
                    sampleCount += 1
                    
                    DispatchQueue.main.async{
                        self.learningProgressView.setProgress(Float(sampleCount)/Float(totalSamplesPlus), animated: true)
                    }
                    
                    NSLog("progress+ %f", Float(sampleCount)/Float(totalSamplesPlus))
                    
                    if sampleCount>=totalSamplesPlus {
                        
                        self.changeState(.waiting)
                        
                        DispatchQueue.main.async{
                            self.learnButton.setTitle("Continue", for: UIControlState())
                            self.learningProgressView.isHidden = false
                            self.learningLabel.isHidden = false
                        }

                        self.speak("Now I need to see examples of things that are not the object you're looking for. Press the button when you're ready.", voice: manVoice)
                        
                    }
                    
                case .learningMinus:
                    
                    jpcnn_train(trainer, 0.0, obj.predictions, obj.length)
                    sampleCount += 1

                    DispatchQueue.main.async{
                        self.learningProgressView.setProgress(Float(sampleCount)/Float(totalSamplesMinus), animated: true)
                        NSLog("progress- %f", Float(sampleCount)/Float(totalSamplesPlus))
                    }

                    if sampleCount>=totalSamplesMinus {
                        
                        self.addPredictor()
                        
                        self.changeState(.predicting)
                        
                    }
                    
                case .predicting:
                    
                    jobQueue.sync{
                    
                        var indexes = [Int]()

                        for i in 0..<predictors.count {
                            
                            let p = predictors.pointer(at: i)
                            let predictionValue = jpcnn_predict(p, obj.predictions, obj.length)
                            NSLog("Predictor: %@  Value: %f", predictorNames[i], predictionValue)
                        
                            if predictionValue>0.7 {
                                indexes.append(i)
                            }
                        
                        }

                        for i in indexes {
                            objectText += predictorNames[i] + " "
                        }
                    }
                    
                    
                    
                default: break
                    
                }
                
            }
            
            
            NSLog("State: %d", self.state.rawValue)
            
            self.state = nextState
        }
        
        groupAlg.notify(queue: DispatchQueue.main){
            lockAlg = false
        }
        
    }
    
    //MARK: Faces
    
    func detectFaces(_ frameImage: CIImage, rect: CGRect){
        
        let frameImage = CIImage(cgImage: CIContext().createCGImage(frameImage, from: rect)!)
        
        let features = faceDetector?.features(in: frameImage, options: [CIDetectorSmile : true/*, CIDetectorEyeBlink : true*/]) as! [CIFaceFeature]
        
        faceText = ""
        if features.count>0{
            faceText = String(format:"%d Faces",features.count)

            let smiles = features.filter ({ $0.hasSmile }).count
            if smiles>0 {
                faceText += String(format: " - %d Smiles", smiles)
            }
        }
        
        self.drawFaceBoxesForFeatures(features)

        
    }
    
    
    func drawFaceBoxesForFeatures(_ features: [CIFaceFeature]){
        
        DispatchQueue.main.async{
            
            let layers = self.view.layer.sublayers
            
            CATransaction.begin()
            
            CATransaction.setValue(kCFBooleanTrue, forKey: kCATransactionDisableActions)
            
            if let subLayers = layers {
                
                for l in subLayers {
                    if l.name == "FaceLayer" {
                        l.isHidden = true
                    }
                }
                
            }
            
            guard features.count > 0 else { CATransaction.commit(); return }
            
            var currentSublayer = 0
            
            //translate CoreImage coordinates to UIKit coordinates
            //also compensate for transRatio of conforming to video frame height
            var transform = CGAffineTransform(scaleX: 1/transRatio, y: -1/transRatio)
            transform = transform.translatedBy(x: 0, y: -self.view.bounds.height*transRatio)
            
            for f in features {
                
                let faceRect = f.bounds.applying(transform)
                
                var featureLayer: CALayer? = nil
                
                //re-use existing layer if possible
                if let subLayers = layers {
                    
                    while featureLayer==nil && currentSublayer<subLayers.count {
                        let currentLayer = subLayers[currentSublayer]
                        currentSublayer += 1
                        if currentLayer.name == "FaceLayer" {
                            featureLayer = currentLayer
                        }
                    }
                    
                }
                
                if let layer = featureLayer {
                    layer.frame = faceRect
                    layer.isHidden = false
                }
                    
                else {
                    //create new one if necessary
                    
                    let newFeatureLayer = CALayer()
                    newFeatureLayer.contents = UIImage(named: "square1")?.cgImage
                    newFeatureLayer.name = "FaceLayer"
                    newFeatureLayer.frame = faceRect
                    self.view.layer .addSublayer(newFeatureLayer)
                    
                }
            }
            
            CATransaction.commit()
        }
    }
    
    
    
    //MARK: Predictors
    
    func predictObjects(_ frameImage: CIImage, rect: CGRect) -> (predictions:UnsafeMutablePointer<Float>, length:Int32)?{
        
        var frameImage = CIImage(cgImage: CIContext().createCGImage(frameImage, from: rect)!)
        
        let w = frameImage.extent.size.width
        let h = frameImage.extent.size.height
        
        //warp filter (to get a 230x230 square image)
        let ratio = h/w
        let scaleRatio = ratio > 1 ? 230/w : 230/h
        
        let warp = CIFilter(name: "CILanczosScaleTransform", withInputParameters: ["inputImage" : frameImage , "inputScale" : scaleRatio, "inputAspectRatio" : ratio])
        
        if let warpOutput = warp?.outputImage {
            frameImage = warpOutput
        }
        
        //rotate filter (in case video frame is rotated with respect to user view)
        /*let rotate = CIFilter(name: "CIStraightenFilter", withInputParameters: ["inputImage" : frameImage , "inputAngle" : degreesToRadians(-90)])
        
        if let rotateOutput = rotate?.outputImage {
        frameImage = rotateOutput
        }*/
        
        //showThumbImage(UIImage(CIImage: frameImage))
        
        var buffer : CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, Int(frameImage.extent.size.width), Int(frameImage.extent.size.height), sourcePixelFormat, [String(kCVPixelBufferIOSurfacePropertiesKey) : [:]] as CFDictionary, &buffer)
        
        guard let pixelBuffer = buffer else { NSLog("Can't craete pixel buffer !"); return nil }
        CIContext().render(frameImage, to: pixelBuffer)
        
        let doReverseChannels = sourcePixelFormat == kCVPixelFormatType_32ARGB ? 1 : 0
        
        let sourceRowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let fullHeight = CVPixelBufferGetHeight(pixelBuffer)
        
        CVPixelBufferLockBaseAddress(pixelBuffer, CVPixelBufferLockFlags(rawValue: 0))
        guard let sourceBaseAddr = CVPixelBufferGetBaseAddress(pixelBuffer)?.assumingMemoryBound(to: UInt8.self) else { return nil}
        
        
        let height = fullHeight<=width ? fullHeight : width
        let sourceStartAddr = fullHeight<=width ? sourceBaseAddr : sourceBaseAddr + ((fullHeight-width)/2) * sourceRowBytes
        
        let cnnInput = jpcnn_create_image_buffer_from_uint8_data(sourceStartAddr, Int32(width), Int32(height), 4, Int32(sourceRowBytes), Int32(doReverseChannels), 1)
        
        var predictions : UnsafeMutablePointer<Float>? = nil
        var length = Int32()
        var labels : UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>? = nil
        var labelsLength = Int32()
        
        jpcnn_classify_image(network, cnnInput, UInt32(JPCNN_RANDOM_SAMPLE), -2, &predictions, &length, &labels, &labelsLength)
        
        jpcnn_destroy_image_buffer(cnnInput)
        
        //showThumbImage(UIImage(CIImage: CIImage(CVPixelBuffer: pixelBuffer)))
        
        return (predictions!,length)
        
    }

    func newPredictorAlert(){
        
        dataEntryForm(title: "New Predictor", message: "Enter object name, and number of positive and negative samples", placeholders: ["<random object>", String(format:"%d <5-200>", totalSamplesPlus), String(format: "%d <5-200>", totalSamplesMinus)], returnHandler: { (fields) -> () in
            
            var name = ""
            if let text = fields.first?.text {
                if text.characters.count > 0 {
                    name = text
                } else {
                    name = String(format: "Object_%d", arc4random_uniform(1000))
                }
            }
            
            //make sure it's not a duplicate
            
            if !predictorNames.contains(where: { $0 == name }) {
                
                //get sample totals
                if let plusText = fields[1].text {
                    if let plus = Int(plusText) {
                        guard plus>=5 && plus<=200 else {
                            self.OKAlert(title: "Invalid Samples Number!", message: "Should be in the range [5..200]")
                            return
                        }
                        
                        totalSamplesPlus = plus
                        
                    }
                }
                
                if let minusText = fields[2].text {
                    if let minus = Int(minusText) {
                        guard minus>=5 && minus<=200 else {
                            self.OKAlert(title: "Invalid Samples Number", message: "Should be in the range [5..200]")
                            return
                        }
                        
                        totalSamplesMinus = minus
                        
                    }
                }
                
                trainingName = name
                
                self.learningLabel.text = String(format:"Learning %d / %d ", totalSamplesPlus, totalSamplesMinus) + trainingName
                
                self.startLearningPlus()
                
            } else {
                
                self.OKAlert(title: "Name Already Used!", message: "Try another one")
            }
            
            
            }, returnTitle: "Start")
        
    }
    
    func addPredictor(){
        
        let predictor = jpcnn_create_predictor_from_trainer(trainer)
        
        if predictor != nil {
            jobQueue.sync{
                predictorNames.append(trainingName)
                predictors.addPointer(predictor)
            }
        }
        
        changeState(.predicting)
        
        savePredictor(predictor!, toFileNamed: trainingName)
        
        NSLog("Predictor setup done!")
        
        DispatchQueue.main.async{
            self.learnButton.setTitle("Learn", for: UIControlState())
            self.learningProgressView.isHidden = true
            self.learningLabel.isHidden = true
        }
        
        speak("You can now scan around using the camera, to detect objects' presence", voice: manVoice)
        
    }
    
    func savePredictor(_ predictor: UnsafeMutableRawPointer, toFileNamed fileName: String) {
        
        struct SPredictorInfo {
            var model: UnsafeMutablePointer<svm_model>
            var problem: UnsafeMutablePointer<SLibSvmProblem>
        }
        
        let predictorInfo = unsafeBitCast(predictor, to: UnsafeMutablePointer<SPredictorInfo>.self)
        
        let model = predictorInfo.pointee.model
        
        let docsDir = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
        let path = docsDir + "/" + fileName

        let filePath = (path as NSString).cString(using: String.Encoding.ascii.rawValue)
        
        let fp = fopen(filePath, "w");
        
        if (fp != nil) {
            
            let saveResult = svm_save_model_to_file_handle(fp, model);
            
            if (saveResult == 0) { return }
        }

        NSLog("Couldn't save libsvm model file to %@", fileName)
        
        return

    }
    
    func deletePredictor(_ name : String) {
        
        jobQueue.sync{
            for i in 0..<predictorNames.count {

                if predictorNames[i] == name {
                    predictorNames.remove(at: i)
                    predictors.removePointer(at: i)
                    
                    break;
                }
            }
            
        }
        
        let docsDir = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
        let fileManager = FileManager.default
        
        do {
            let files = try fileManager.contentsOfDirectory(atPath: docsDir)
            
            let predictorFiles = files.filter({ $0 == name })
            
            for i in 0..<predictorFiles.count {
                let path = docsDir + "/" + predictorFiles[i]
                
                print("removing \(path)")
                do {
                    try fileManager.removeItem(atPath: path)
                } catch let error as NSError {
                    NSLog("could not remove \(path)")
                    print(error.localizedDescription)
                }
            }
            
        } catch let error as NSError {
            print("could not get contents of directory at \(docsDir)")
            print(error.localizedDescription)
        }
        
    }
    
    func loadAllPredictors() {
        
        let docsDir = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
        let fileManager = FileManager.default
        
        do {
            let files = try fileManager.contentsOfDirectory(atPath: docsDir)
            
            jobQueue.sync{
                predictors = NSPointerArray(options: .opaqueMemory)
                
                for name in files {
                    let path = docsDir + "/" + name
                    let filePath = (path as NSString).cString(using: String.Encoding.ascii.rawValue)
                    
                    let p = jpcnn_load_predictor(filePath)
                    
                    predictors.addPointer(p)
                    predictorNames.append(name)
                    
                }
                
            }
        }
        catch let error as NSError {
            print("could not get contents of directory at \(docsDir)")
            print(error.localizedDescription)
        }

        if predictors.count>0 {
            self.changeState(.predicting)
        }
        
    }
    
    func resetPredictors(){
        
        resetAll() {
            //dynamic reset

            self.cancelLearning()
            
            self.changeState(.start)
            
            jobQueue.sync{
                predictorNames.removeAll()
                predictors = NSPointerArray(options: .opaqueMemory)
            }
            
        }
    }
    
    //MARK: States
    
    func changeState(_ s: PredictionState){
        
        nextState = s
        
    }
    
    func startLearningPlus(){

        changeState(.learningPlus)

        //new trainer
        if trainer != nil {
            jpcnn_destroy_trainer(trainer)
        }
        trainer = jpcnn_create_trainer()
        
        sampleCount = 0
        
        DispatchQueue.main.async{
            self.learnButton.setTitle("Cancel", for: UIControlState())
            self.learningProgressView.setProgress(0, animated: false)
            self.learningProgressView.isHidden = false
            self.learningLabel.isHidden = false
        }
        
        speak("Move around the thing you want to recognize, keeping the camera pointed at it, to capture different angles", voice: manVoice)
    }
    
    func startLearningMinus(){
        
        changeState(.learningMinus)

        sampleCount = 0
        
        DispatchQueue.main.async{
            self.learnButton.setTitle("Cancel", for: UIControlState())
            self.learningProgressView.setProgress(0, animated: false)
            self.learningProgressView.isHidden = false
            self.learningLabel.isHidden = false
        }

        speak("Now move around the room pointing the camera at lots of things, that are not the object you want to recognize", voice: manVoice)
        
    }
    
    func cancelLearning() {
        
        guard state == .learningPlus || state == .learningMinus else { return }
        
        if predictors.count>0 {
            changeState(.predicting)
        } else {
            changeState(.start)
        }
        
        DispatchQueue.main.async{
            self.learnButton.setTitle("Learn", for: UIControlState())
            self.learningProgressView.isHidden = true
            self.learningLabel.isHidden = true
        }
        
        /*
        //destroy trainer
        if trainer != nil {
            jpcnn_destroy_trainer(trainer)
            trainer = nil
        }*/
    }
    
    //MARK: Utils
    
    func showThumbImage(_ image: UIImage) {
        
        //NSLog("%f x %f", image.size.width,image.size.height)
        DispatchQueue.main.async {
            self.thumbPreview.image = image
        }
    }
    
    func announce(){
        
        var text = objectText
        
        if faceText.characters.count>0 && objectText.characters.count>0 {
            text += " | "
        }
        
        text += faceText
        
        DispatchQueue.main.sync{
            self.announcer.text = text
        }
        
    }
    
}


func testNetwork() {

    let imagePath = Bundle.main.path(forResource: "<image file name>", ofType: "jpeg")! as NSString
    let inputImage = jpcnn_create_image_buffer_from_file(imagePath.utf8String)
    
    var predictions : UnsafeMutablePointer<Float>? = nil
    var length = Int32()
    var labels : UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>? = nil
    var labelsLength = Int32()
    
    jpcnn_classify_image(network, inputImage, 0, 0, &predictions, &length, &labels, &labelsLength)
    
    jpcnn_destroy_image_buffer(inputImage)
    
    for i in 0..<Int(length) {
        
        let predictionValue = predictions?[i]
        let label = labels?[i % Int(labelsLength)]
        
        //print labels and values
        NSLog(String(format: "%@ - %0.2f\n", label!, predictionValue!))
        
    }
    
    
}



//func degreesToRadians(degrees: Double)-> Double { return degrees * M_PI / 180 }

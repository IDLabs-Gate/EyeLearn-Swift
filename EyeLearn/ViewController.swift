
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

enum PredictionState: Int {
    case start
    case learningPlus
    case waiting
    case learningMinus
    case predicting
}

class ViewController: UIViewController {
    
    @IBOutlet weak var thumbPreview: UIImageView!
    @IBOutlet weak var announcer: UILabel!
    @IBOutlet weak var learnButton: UIButton!
    @IBOutlet weak var learningProgressView: UIProgressView!
    @IBOutlet weak var learningLabel: UILabel!
    
    var state = PredictionState.start

    var sourcePixelFormat = OSType()
    var clap = CGRect()
    
    var selectRect : CGRect?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.blackColor()
        
        learningProgressView.hidden = true
        learningLabel.hidden = true
        
        view.addActivityIndicatorOverlay {
            
            self.setupCam(){

                self.loadAllPredictors()
                
                self.resumeFrames()
                
                self.view.removeActivityIndicatorOverlay()
                
            }
            
        }
        
    }

    //MARK: Actions
    
    @IBAction func tapAction(sender: AnyObject) {
        
        let tap = sender.locationInView(view)
        
        if selectRect == nil {
            
            let height = 0.4 * view.bounds.height
            let width = 0.4 * view.bounds.width
            
            let rect = CGRect(x: tap.x-width/2, y: tap.y-height/2, width: width, height: height).keepWithin(view.bounds)

            let selectLayer = self.addLayer(name: "SelectLayer", image: UIImage(named: "square2")!, toLayer: view.layer)

            selectLayer.frame = rect
            
            selectRect = rect
            
        } else {
            //deselect
            selectRect = nil
            removeLayers(name: "SelectLayer", fromLayer: view.layer)
        }
    }
    
    @IBAction func learnAction(sender: AnyObject) {
        
        switch state {
            
        case .start, .predicting:
            
            newPredictorAlert()
            
        case .learningPlus, .learningMinus:
            
            cancelLearning()
            
        case .waiting:
            
            startLearningMinus()
            
        }
    }
    
    @IBAction func predictorsAction(sender: UIView) {
     
        let docsDir = NSSearchPathForDirectoriesInDomains(.DocumentDirectory, .UserDomainMask, true)[0]
        let fileManager = NSFileManager.defaultManager()

        do {
            let files = try fileManager.contentsOfDirectoryAtPath(docsDir)
            
            guard files.count>0 else {
                actionSheet(title: "No Predictors", itemNames: [String](), actionHandler: nil, fromSourceView: sender, lastRed: false)
                return
            }
            
            let items = files+["Delete All"]
            
            actionSheet(title: "Predictors", itemNames: items , actionHandler: { (i, name) -> () in
                
                guard i != items.count else {
                    
                    self.resetPredictors()
                    
                    return
                }
                
                self.YesNoAlert(title: "Delete Predictor: "+name+" ?"){
                    
                    self.deletePredictor(name)
                }
                
                }, fromSourceView: sender, lastRed: true)
            
        }
        catch let error as NSError {
            print("could not get contents of directory at \(docsDir)")
            print(error.localizedDescription)
        }
        
        
    }
    
    
    //MARK: Utils
        
    func addLayer(name name: String, image: UIImage, toLayer parent: CALayer) -> CALayer{
        
        //remove previous layer
        removeLayers(name: name, fromLayer: parent)
        
        let layer = CALayer()
        layer.contents = image.CGImage
        layer.name = name
        
        parent.addSublayer(layer)
        
        return layer
    }
    
    func removeLayers(name name: String, fromLayer parent: CALayer){
        
        guard let layers = parent.sublayers else { return }
        
        var rmv = [CALayer]()
        
        for l in layers {
            if l.name == name {
                rmv.append(l)
            }
        }
        
        for l in rmv {
            l.removeFromSuperlayer()
        }
    }
        
    //MARK: Orientation
    
    override func shouldAutorotate() -> Bool {
        
        return false
    }

    /*
    override func viewWillTransitionToSize(size: CGSize, withTransitionCoordinator coordinator: UIViewControllerTransitionCoordinator) {
        
        orientCam()
    }*/
    
    override func supportedInterfaceOrientations() -> UIInterfaceOrientationMask {
        return .LandscapeRight
    }
    
    override func prefersStatusBarHidden() -> Bool {
        return true
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }


}


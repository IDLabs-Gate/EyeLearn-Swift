
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
import AVFoundation

let synth = AVSpeechSynthesizer()
let manVoice = "en-gb"
let womanVoice = "en-au"

extension UIViewController : UIPopoverPresentationControllerDelegate {
    
    //MARK: Voice
    func speak(words: String, voice: String){
        
        let utterance = AVSpeechUtterance(string: words)
        utterance.voice = AVSpeechSynthesisVoice(language: voice)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.1
        utterance.volume = 0.5
        
        synth.speakUtterance(utterance)
    }

    //MARK: Memory
    func resetAll(dynamicReset:()->()){
        
        YesNoAlert(title: "Delete All Content?") { () -> () in
            self.view.addActivityIndicatorOverlay() {
                
                //delete all NSUserDefaults
                if let appDomain = NSBundle.mainBundle().bundleIdentifier {
                    NSUserDefaults.standardUserDefaults().removePersistentDomainForName(appDomain)
                }
                
                //delete all document files
                let docsDir = NSSearchPathForDirectoriesInDomains(.DocumentDirectory, .UserDomainMask, true)[0]
                let fileManager = NSFileManager.defaultManager()
                
                do {
                    let files = try fileManager.contentsOfDirectoryAtPath(docsDir)
                    
                    /*let thumbs = files.filter( { (name: String) -> Bool in
                    return name.hasSuffix("_thumb.JPEG")
                    })*/
                    
                    for var i = 0; i < files.count; i++ {
                        let path = docsDir + "/" + files[i]
                        
                        print("removing \(path)")
                        do {
                            try fileManager.removeItemAtPath(path)
                        } catch let error as NSError {
                            NSLog("could not remove \(path)")
                            print(error.localizedDescription)
                        }
                    }
                    
                } catch let error as NSError {
                    print("could not get contents of directory at \(docsDir)")
                    print(error.localizedDescription)
                }
                
                //remove objects from dynamic memory
                dynamicReset()
                
                self.view.removeActivityIndicatorOverlay()
            }
        }
        
    }

    //MARK: UI
    func OKAlert(title title: String, message: String) {
        
        let OKAlert = UIAlertController(title: title, message: message, preferredStyle: .Alert)
        
        OKAlert.addAction(UIAlertAction(title: "OK", style: .Default, handler: nil))
        
        presentViewController(OKAlert, animated: true, completion: nil)
    }
    
    func YesNoAlert(title title: String, yesHandler: ()->() ){
        
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .Alert)
        
        alert.addAction(UIAlertAction(title: "No", style: .Default, handler: nil))
        
        alert.addAction(UIAlertAction(title: "Yes", style: .Default, handler: { (alertAction) -> Void in
            
            yesHandler()
        }))
        
        
        presentViewController(alert, animated: true, completion: nil)
    }
    
    
    func dataEntryForm(title title: String, message: String, placeholders: [String], returnHandler: [UITextField]->(), returnTitle: String){
        
        let entryAlert = UIAlertController(title: title, message: message, preferredStyle: .Alert)
        
        for p in placeholders {
            
            entryAlert.addTextFieldWithConfigurationHandler { textField -> () in
                
                textField.placeholder = p
                
                //if it starts with a number show the Num pad instead
                if "0123456789".characters.contains ({ p.hasPrefix(String($0)) }) {
                    textField.keyboardType = .NumberPad
                } else {
                    textField.keyboardType = .ASCIICapable
                }
                
                textField.keyboardAppearance = UIKeyboardAppearance.Dark
                
            }
        }
        
        entryAlert.addAction(UIAlertAction(title: "Cancel", style: .Cancel, handler: nil))
        
        entryAlert.addAction(UIAlertAction(title: returnTitle, style: .Default) { alertAction in
            
            if let fields = entryAlert.textFields {
                
                returnHandler(fields)
            }
        })
        
        presentViewController(entryAlert, animated: true, completion: nil)
    }
    
    func actionSheet(title title: String, itemNames: [String], actionHandler: ((Int, String)->())?, fromSourceView sourceView: UIView, lastRed: Bool) {
        
        let sheet = UIAlertController(title: title, message: nil, preferredStyle: .ActionSheet)
        
        for name in itemNames {
            
            if (lastRed && name == itemNames.last) {
                
                sheet .addAction(UIAlertAction(title: name, style: .Destructive, handler: { (alertAction) -> () in
                    
                    actionHandler?(itemNames.count,name)
                    
                }))
                
            } else {
                
                sheet .addAction(UIAlertAction(title: name, style: .Default, handler: { (alertAction) -> () in
                    
                    var i = 1
                    
                    for task in itemNames {
                        
                        if task == name {
                            
                            actionHandler?(i,name)
                            
                            break
                        }
                        
                        i++
                    }
                }))
                
            }
        }
        
        
        sheet.modalPresentationStyle = .Popover
        
        if let pop = sheet.popoverPresentationController {
            
            pop.sourceView = sourceView
            pop.sourceRect = sourceView.bounds
            
            pop.delegate = self
            
            presentViewController(sheet, animated: true, completion: nil)
        }
    }

    //Popover delegate
    
    public func prepareForPopoverPresentation(popoverPresentationController: UIPopoverPresentationController) {
        
        //pause
    }
    
    public func popoverPresentationControllerDidDismissPopover(popoverPresentationController: UIPopoverPresentationController) {
        
        //resume
    }
    
}
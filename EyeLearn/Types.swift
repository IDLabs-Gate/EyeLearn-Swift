
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

//MARK: operators

public func + (left: CGPoint, right: CGPoint) -> CGPoint {
    return CGPoint(x: left.x + right.x, y: left.y + right.y)
}

public func - (left: CGPoint, right: CGPoint) -> CGPoint {
    return CGPoint(x: left.x - right.x, y: left.y - right.y)
}

public func -= (left: inout CGPoint, right: CGPoint) {
    left = left - right
}

public func += (left: inout CGPoint, right: CGPoint) {
    left = left + right
}

public func + (left: CGPoint, right: CGSize) -> CGPoint {
    return CGPoint(x: left.x + right.width, y: left.y + right.height)
}

public func + (left: CGSize, right: CGPoint) -> CGSize {
    return CGSize(width: left.width + right.x, height: left.height + right.y)
}


public func - (left: CGPoint, right: CGSize) -> CGPoint {
    return CGPoint(x: left.x - right.width, y: left.y - right.height)
}

public func - (left: CGSize, right: CGPoint) -> CGSize {
    return CGSize(width: left.width - right.x, height: left.height - right.y)
}


public func *(left: CGFloat, right: CGPoint) -> CGPoint {
    return CGPoint(x: right.x*left, y: right.y*left)
}

public func *(left: CGPoint, right: CGFloat) -> CGPoint {
    return CGPoint(x: left.x*right, y: left.y*right)
}

public func /(left: CGPoint, right: CGFloat) -> CGPoint {
    return CGPoint(x: left.x/right, y: left.y/right)
}


public func *(left: CGFloat, right: CGSize) -> CGSize {
    return CGSize(width: right.width*left, height: right.height*left)
}

public func *(left: CGSize, right: CGFloat) -> CGSize {
    return CGSize(width: left.width*right, height: left.height*right)
}

public func /(left: CGSize, right: CGFloat) -> CGSize {
    return CGSize(width: left.width/right, height: left.height/right)
}

//MARK: CGPoint

extension CGPoint {
    
    func distanceToPoint(_ p: CGPoint) -> CGFloat {
        
        return sqrt(pow(self.x-p.x, 2) + pow(self.y-p.y, 2))
        
    }
    
    func distanceToPoints(_ pts: Array<CGPoint>) -> Array<CGFloat> {
        
        return pts.map { p in distanceToPoint(p) }
        
    }
    
}

//MARK: CGRect

extension CGRect {
    
    func keepWithin(_ bounds: CGRect) -> CGRect {
        
        var output = self
        
        if origin.x<0 {
            output.origin.x = 0
        }
            
        else if origin.x>bounds.size.width-size.width {
            output.origin.x = bounds.size.width - size.width
        }
        
        
        if origin.y<0 {
            output.origin.y = 0
        }
            
        else if origin.y > bounds.size.height - size.height {
            output.origin.y = bounds.size.height - size.height
        }
        
        return output
        
    }

}

//MARK: UIView

var activityOverlay: UIView?

extension UIView : UIPopoverPresentationControllerDelegate {

    func flash() {
        
        let flashView = UIView(frame: CGRect(origin: CGPoint.zero, size: self.bounds.size))
        flashView.backgroundColor = UIColor.white
        flashView.alpha = 0.5
        addSubview(flashView)
        
        UIView .animate(withDuration: 0.1, animations: { () -> Void in
            
            flashView.alpha = 1
            
            }, completion: { b -> Void in
                
                UIView .animate(withDuration: 0.3, animations: { () -> Void in
                    
                    flashView.alpha = 0
                    
                    }, completion: { b in
                        
                        flashView .removeFromSuperview()
                })
                
        })
    }

    func snapImage() -> UIImage {

        UIGraphicsBeginImageContext(bounds.size)
        
        guard let currentContext = UIGraphicsGetCurrentContext() else { return UIImage() }
        
        layer .render(in: currentContext)
        
        let img = UIGraphicsGetImageFromCurrentImageContext()

        UIGraphicsEndImageContext()
        
        return img!
        
    }
    
    func smoothAddSubview(_ view: UIView, duration: TimeInterval, completion: ((Void)->Void)?) {

        let oldAlpha = view.alpha

        view.alpha = 0
        
        addSubview(view)
        
        UIView .animate(withDuration: duration, animations: {
            
            view.alpha = oldAlpha

            }, completion:  { b in completion?() })
        
    }
    
    func smoothHide(duration: TimeInterval, completion: ((Void)->Void)?) {
        
        UIView .animate(withDuration: duration, animations: { self.alpha = 0 }, completion: { b in completion?() })
    }
    
    func smoothChangeAlpha(_ a: CGFloat, duration: TimeInterval, completion: ((Void)->Void)?) {
        
        UIView .animate(withDuration: duration, animations: { self.alpha = a }, completion: { b in completion?() })
    }
    
    func addActivityIndicatorOverlay(_ completion:((Void)->Void)?) {
        
        let actView = UIView(frame: bounds)
        actView.backgroundColor = UIColor.black
        actView.alpha = 0.5
        
        let indict = UIActivityIndicatorView(frame: CGRect(origin: CGPoint.zero, size: actView.bounds.size/7))
        indict.center = actView.center; indict.activityIndicatorViewStyle = .whiteLarge
        actView .addSubview(indict)
        indict .startAnimating()
        
        smoothAddSubview(actView, duration: 0.5) { completion?() }
        
        activityOverlay = actView
        
    }
    
    func removeActivityIndicatorOverlay() {
        
        activityOverlay? .removeFromSuperview()
        activityOverlay = nil
    }

}


//
//  BallDetect.swift
//  CueSync AR
//
//  Created by Christopher Queen on 10/17/23.
//

import Roboflow

class BallDetect{
    
    //initalize with your API Key
    var rf = RoboflowMobile(apiKey: "rf_7Lp2oXibn6ZJU9IrS1tLzmGxLxy2")
    
    func detectBalls(img: UIImage ) async {
        
        //model is your model's project name
        let maxObjects = Float(16)
        let overlap = Double(50)
        let threshold = Double(50)
        let (model, loadingError, modelName, modelType) = await rf.load(model: "pool-ball-detection", modelVersion: 1)
        model!.configure(threshold: threshold, overlap: overlap, maxObjects: maxObjects)
        
        
        //model?.detect takes a UIImage and runs inference on it
        //let img = UIImage(named: "example.jpeg")
        let (predictions, predictionError) = await model!.detect(image: img)
        print(predictions)
        
    }
    
    
}

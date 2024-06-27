

import UIKit
fileprivate let kDeviceIdUserDefaultsKey:String = "SampleAppDeviceID"

fileprivate let kDeviceIdKey:String = "SampleAppDeviceId"

class Device {
    private static var deviceID:String = ""
    
    static var deviceId:String {
        if !deviceID.isEmpty {
            return deviceID
        }
        
        if let deviceIdString = UserDefaults.standard.string(forKey: kDeviceIdUserDefaultsKey) {
            deviceID = deviceIdString
            return deviceIdString
        }
        
        let newDeviceId = UIDevice.current.identifierForVendor?.uuidString ?? ""
        deviceID = newDeviceId
        
        UserDefaults.standard.setValue(newDeviceId, forKey: kDeviceIdUserDefaultsKey)
        defer {
            UserDefaults.standard.synchronize()
        }
        return newDeviceId
    }
}

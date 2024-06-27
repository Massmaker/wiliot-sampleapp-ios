import Foundation
import Combine

import WiliotCore
import WiliotBLEUpstream

import OSLog

#if DEBUG
let logger = Logger(subsystem: "Sample App", category: "Model")
#else
let logger = Logger(.disabled)
#endif

///plist value reading key
fileprivate let kAPPTokenKey = "app_token"
///plist value reading key
fileprivate let kOwnerIdKey = "owner_id"
fileprivate let kConstantsPlistFileName = "SampleAuthConstants"

typealias AppBuildInfo = String

@objc class Model:NSObject {
    
    private(set) lazy var permissions:Permissions = Permissions()
    
    private var bleUpstreamService:BLEUpstreamService?
    
    var permissionsPublisher:AnyPublisher<Bool, Never> {
        _permissionsPublisher.eraseToAnyPublisher()
    }

    var statusPublisher: AnyPublisher<String, Never> {
        return _statusPublisher.eraseToAnyPublisher()
    }
    
    var connectionPublisher:AnyPublisher<Bool,Never> {
        return _mqttConnectionPublisher.eraseToAnyPublisher()
    }
    
    var bleActivityPublisher:AnyPublisher<Float, Never> {
        return _bleScannerPublisher.eraseToAnyPublisher()
    }
    
    //sends some text for better overall status understanding
    var messageSentActionPublisher:AnyPublisher<String,Never> {
        return _mqttSentMessagePublisher.eraseToAnyPublisher()
    }
    
    
    private let _statusPublisher:CurrentValueSubject<String, Never> = .init("")
    private let _mqttConnectionPublisher:CurrentValueSubject<Bool, Never> = .init(false)
    private let _bleScannerPublisher:CurrentValueSubject<Float, Never> = .init(0.0)
    private let _permissionsPublisher:PassthroughSubject<Bool, Never> = .init()
    private let _mqttSentMessagePublisher:PassthroughSubject<String,Never> = .init()
    
    private var appToken = ""
    private var ownerId = ""
//    private var gatewayService:MobileGatewayService?
//    private var bleService:BLEService?
//    private var blePacketsmanager:BLEPacketsManager?
    private var networkService:NetworkService?
    private var locationService:LocationService?
    
    private var permissionsCompletionCancellable:AnyCancellable?
    private var gatewayServiceMessageCancellable:AnyCancellable?

    var appBuildInfo:AppBuildInfo = ""
    //MARK: -
    override init() {
        super.init()
        DispatchQueue.global(qos: .default).async {[weak self] in
            guard let self else { return }
            
            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
               let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
                self.appBuildInfo = "\(version) (build \(build))"
            }
        }
    }
    
    func loadRequiredData() {
        do {
            try tryReadRequiredUserData()
            checkAndRequestSystemPermissions()
        }
        catch {
            _statusPublisher.send(error.localizedDescription)
        }
    }
    
    private func canPrepare() -> Bool {
        guard permissions.gatewayPermissionsGranted && !appToken.isEmpty && !ownerId.isEmpty else {
            return false
        }
        return true
    }
    
   
    
    
    private func start() {
        _statusPublisher.send("Starting Connection..")
        startGateway()
    }

    // MARK: - PRIVATE
    private func tryReadRequiredUserData() throws {
        _statusPublisher.send("Reading API Token and Owner ID")
        
        guard let plistPath = Bundle.main.path(forResource: kConstantsPlistFileName, ofType: "plist"),
              let dataXML = FileManager.default.contents(atPath: plistPath)else {
            #if DEBUG
            print("No required data found in app Bundle. No required'\(kConstantsPlistFileName)' file")
            #endif
            throw ValueReadingError.missingRequiredValue("No required data found in app Bundle")
        }

        do {
            var propertyListFormat =  PropertyListSerialization.PropertyListFormat.xml
            let anObject = try PropertyListSerialization.propertyList(from: dataXML, options: .mutableContainersAndLeaves, format: &propertyListFormat)
            
            guard let values = anObject as? [String:String] else {
                #if DEBUG
                print("The '\(kConstantsPlistFileName)' file has wrong format.")
                #endif
                throw ValueReadingError.missingRequiredValue("Wrong Required Data format.")
            }

            guard let lvAppToken = values[kAPPTokenKey],
                  let lvOwnerId = values[kOwnerIdKey],
                  !lvAppToken.isEmpty,
                  !lvOwnerId.isEmpty else {
                
                #if DEBUG
                print("The app needs Owner_Id and Api_Key to be supplied in the '\(kConstantsPlistFileName)' file")
                #endif
                
                throw ValueReadingError.missingRequiredValue("No APP Token or Owner ID. Please provide values in the project file named '\(kConstantsPlistFileName)'.")
            }

            appToken = lvAppToken
            ownerId = lvOwnerId
            _statusPublisher.send("plist values present. OwnerId: \(lvOwnerId)")
            
        }
        catch(let plistError) {
            throw plistError
        }

    }
    
    private func checkAndRequestSystemPermissions() {
        permissions.checkAuthStatus()
        
        if !permissions.gatewayPermissionsGranted {

            self.permissionsCompletionCancellable =
            permissions.gatewayPermissionsPublisher
                .sink {[weak self] granted in
                    if let weakSelf = self {
                        weakSelf.handlePermissionsRequestsCompletion(granted)
                    }
                }
            _statusPublisher.send("Requesting system permissions...")
            permissions.requestPermissions()
        }
        else {
            handlePermissionsRequestsCompletion(true)
        }
    }
    
    
    private func handlePermissionsRequestsCompletion(_ granted:Bool) {
       
        if !granted {
            _statusPublisher.send("No required BLE or Location permissions.")
            return
        }
        
        defer {
            permissionsCompletionCancellable = nil
        }
        _statusPublisher.send("Required BLE and Location permissions granted.")
        _permissionsPublisher.send(granted)
        
        if canPrepare() {
            self.startGatewayRegistrationForTokens()
        }
        
    }

    private func startGatewayRegistrationForTokens() {
        let netService = NetworkService(appKey: self.appToken, ownerId: self.ownerId)
        self.networkService = netService
        let deviceId = Device.deviceId
        
        netService.registerGatewayFor(owner: self.ownerId, gatewayId: deviceId, authToken: self.appToken) { [weak self] tokensResult in
            guard let self else {
                return
            }
            
            self.handleGatewayTokensResult( tokensResult )
        }
        
    }
    
    private func handleGatewayTokensResult(_ tokensResult:TokensResult) {
        switch tokensResult {
        case .success(let gwTokens):
            logger.info("Gateway Tokens Resut: AUTH: \(String(describing: gwTokens.auth)), REFRESH: \(String(describing: gwTokens.refresh))")
            
            guard let gwAuth = gwTokens.auth else {
                _statusPublisher.send("Failuere Registering MobileGateway: not found GW Auth token")
                return
            }
            
            self.prepare(withGatewayToken: gwAuth) {[weak self] possibleError in
                guard let self else { return }
                
                if let error = possibleError {
                    _statusPublisher.send("Failed to prepare Mobile Gateway: \(error)")
                }
                else {
                    self.startGateway()
                }
            }
            
        case .failure(let error) :
            let message:String = "Failuere Registering MobileGateway: \(error.localizedDescription)"
            
            logger.warning("\(message)")
            _statusPublisher.send(message)
        }
    }
    
    // MARK: -
    private func prepare(withGatewayToken gwToken:String,  completion: @escaping ((Error?) -> ())) {
        
        let ownerId:String = self.ownerId
        
        let gatewayAuthToken:NonEmptyCollectionContainer<String> = .init(gwToken) ?? .init("<supply Gateway_Auth_token>")!
        
        let accountIdContainer = NonEmptyCollectionContainer<String>(ownerId) ?? NonEmptyCollectionContainer("SampleApp_Test")!
        let deviceIdStr:String = Device.deviceId
        let appVersionContainer = NonEmptyCollectionContainer(self.appBuildInfo) ?? NonEmptyCollectionContainer("<supply App Version here>")!
        let deviceIdContainer = NonEmptyCollectionContainer(deviceIdStr)!
        
        let receivers:BLEUExternalReceivers = BLEUExternalReceivers(bridgesUpdater: nil, //to listen to nearby bridges
                                                                    blePixelResolver: nil, //agent responsible for resolving pixel payload into pixel ID
                                                                    pixelsRSSIUpdater: nil, //to receive RSSI values updates per pixel
                                                                    resolvedPacketsInfoReceiver: nil) //to receive resolved pixel IDs
        
        let coordinatesContainer: any LocationCoordinatesContainer
        

        if let locService = self.locationService {
            coordinatesContainer = locService
        }
        else {
            let locService = LocationService()
            coordinatesContainer = WeakObject(locService)
            self.locationService = locService
        }
        
        
        
        let config:BLEUServiceConfiguration = BLEUServiceConfiguration(accountId: accountIdContainer,
                                                                       appVersion: appVersionContainer,
                                                                       endpoint: BLEUpstreamEndpoint.prod(),
                                                                       deviceId: deviceIdContainer,
                                                                       pacingEnabled: true,
                                                                       tagPayloadsLoggingEnabled: false,
                                                                       coordinatesContainer: coordinatesContainer,
                                                                       externalReceivers: receivers,
                                                                       externalLogger: nil)
        
        do {
            let upstreamService = try BLEUpstreamService(configuration: config)
            self.bleUpstreamService = upstreamService
            upstreamService.prepare(withToken: gatewayAuthToken)
            completion(nil)
        }
        catch {
            #if DEBUG
            print("BLEUpstream failed to prepare: \(error)")
            #endif
            completion(error)
        }
    }
    
    private func startGateway() {
        guard let upstreamService = self.bleUpstreamService else {
            return
        }
        
        do {
            try upstreamService.start()
        }
        catch {
            
            let message:String = "Model Failed to start BLEUpstreamService: \(error)"
            logger.warning("\(message)")
            _statusPublisher.send(message)
        }
    }

}

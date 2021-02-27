import MapboxNavigationNative
import CoreLocation
import MapboxDirections

/**
 An object that notifies its delegate when the user’s location changes, minimizing the noise that normally accompanies location updates from a `CLLocationManager` object.
 
 Unlike `Router` classes such as `RouteController` and `LegacyRouteController`, this class operates without a predefined route, matching the user’s location to the road network at large. You can use a passive location manager to determine a starting point for a route that you calculate using the `Directions.calculate(_:completionHandler:)` method. If the user happens to be moving while you calculate the route, the passive location manager makes it less likely that the route will begin with a short segment on a side road or driveway and a confusing instruction to turn onto the current road.
 
 To find out when the user’s location changes, implement the `PassiveLocationDataSourceDelegate` protocol, or observe `Notification.Name.passiveLocationDataSourceDidUpdate` notifications for more detailed information.
 */
open class PassiveLocationDataSource: NSObject {
    /**
     Initializes the location data source with the given directions service.
     
     - parameter directions: The directions service that allows the location data source to access road network data. If this argument is omitted, the shared `Directions` object is used.
     - parameter systemLocationManager: The location manager that provides raw locations for the receiver to match against the road network.
     
     - postcondition: Call `startUpdatingLocation(completionHandler:)` afterwards to begin receiving location updates.
     */
    public required init(directions: Directions = Directions.shared, systemLocationManager: NavigationLocationManager? = nil) {
        self.directions = directions
        
        let settingsProfile = SettingsProfile(application: ProfileApplication.kMobile, platform: ProfilePlatform.KIOS)
        let config = try! ConfigFactory.build(for: settingsProfile, config: NavigatorConfig(), customConfig: "")
        let runLoopExecutor = try! RunLoopExecutorFactory.build()
        let historyRecorder = try! HistoryRecorderHandle.build(forConfig: config)
        let cache = try! CacheFactory.build(for: TilesConfig(), config: config, runLoop: runLoopExecutor, historyRecorder: historyRecorder)
        self.graphAccessor = GraphAccessor(try! MapboxNavigationNative.GraphAccessor(cache: cache))
        self.navigator = try! Navigator(config: config, runLoopExecutor: runLoopExecutor, cache: cache, historyRecorder: historyRecorder)

        self.systemLocationManager = systemLocationManager ?? NavigationLocationManager()

        super.init()

        self.systemLocationManager.delegate = self

        try! self.navigator.setElectronicHorizonObserverFor(self)
    }

    deinit {
        try! self.navigator.setElectronicHorizonObserverFor(nil)
    }
    
    /**
     The directions service that allows the location data source to access road network data.
     */
    public let directions: Directions
    
    /**
     The location manager that provides raw locations for the receiver to match against the road network.
     */
    public let systemLocationManager: NavigationLocationManager
    
    /**
     The underlying navigator that performs map matching.
     */
    var navigator: Navigator
    
    /**
     Whether the navigator’s router has been configured.
     
     Set this property to `true` before calling `Navigator.configureRouter(for:)` and reset it to `false` if something causes the router to be unconfigured.
     */
    var isConfigured = false
    
    /**
     The location data source’s delegate.
     */
    public weak var delegate: PassiveLocationDataSourceDelegate?

    /**
     Delegate for Electronic Horizon updates.
     */
    public weak var electronicHorizonDelegate: EHorizonDelegate?
    
    /**
     Starts the generation of location updates with an optional completion handler that gets called when the location data source is ready to receive snapped location updates.
     */
    public func startUpdatingLocation(completionHandler: ((Error?) -> Void)? = nil) {
        systemLocationManager.startUpdatingLocation()
        
        guard !isConfigured else {
            return
        }
        
        directions.fetchAvailableOfflineVersions { [weak self] (versions, error) in
            guard let self = self, let latestVersion = versions?.first(where: { !$0.isEmpty }), error == nil else {
                completionHandler?(error)
                return
            }
            
            do {
                try self.configureNavigator(withTilesVersion: latestVersion)
                completionHandler?(nil)
            } catch {
                completionHandler?(error)
            }
        }
    }

    /**
     Sets electronic horizon options. Pass `nil` to reset to defaults.
     */
    public func set(electronicHorizonOptions: ElectronicHorizonOptions?) {
        try! navigator.setElectronicHorizonOptionsFor(electronicHorizonOptions)
    }

    public var graphAccessor: GraphAccessor

    public lazy var roadObjectsStore: RoadObjectsStore = {
        return RoadObjectsStore(try! navigator.roadObjectStore())
    }()

    public var peer: MBXPeerWrapper?
    
    /**
     Creates a cache for tiles of the given version and configures the navigator to use this cache.
     */
    func configureNavigator(withTilesVersion tilesVersion: String) throws {
        guard !isConfigured else {
            return
        }
        
        // ~/Library/Caches/tld.app.bundle.id/.mapbox/2020_08_08-03_00_00/
        guard var tilesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            preconditionFailure("No Caches directory to create the tile directory inside")
        }
        if let bundleIdentifier = Bundle.main.bundleIdentifier ?? Bundle.mapboxCoreNavigation.bundleIdentifier {
            tilesURL.appendPathComponent(bundleIdentifier, isDirectory: true)
        }
        tilesURL.appendPathComponent(".mapbox", isDirectory: true)
        tilesURL.appendPathComponent(tilesVersion, isDirectory: true)
        // Tiles with different versions shouldn't be mixed, it may cause inappropriate Navigator's behaviour
        try FileManager.default.createDirectory(at: tilesURL, withIntermediateDirectories: true, attributes: nil)
        try configureNavigator(withURL: tilesURL, tilesVersion: tilesVersion)
    }

    func configureNavigator(withURL tilesURL: URL, tilesVersion: String) throws {
        let endpointConfig = TileEndpointConfiguration(credentials: directions.credentials, tilesVersion: tilesVersion, minimumDaysToPersistVersion: nil)
        let tilesConfig = TilesConfig(tilesPath: tilesURL.path,
                                      inMemoryTileCache: nil,
                                      onDiskTileCache: nil,
                                      mapMatchingSpatialCache: nil,
                                      threadsCount: nil,
                                      endpointConfig: endpointConfig)
        
        let settingsProfile = SettingsProfile(application: ProfileApplication.kMobile, platform: ProfilePlatform.KIOS)
        navigator = try Navigator(profile: settingsProfile,
                                  config: NavigatorConfig(),
                                  customConfig: "",
                                  tilesConfig: tilesConfig)
        
        isConfigured = true
    }
    
    /**
     Manually sets the current location.
     
     This method stops any automatic location updates.
     */
    public func updateLocation(_ location: CLLocation?) {
        guard let location = location else { return }
        systemLocationManager.stopUpdatingLocation()
        systemLocationManager.stopUpdatingHeading()
        self.didUpdate(locations: [location])
    }

    private func didUpdate(locations: [CLLocation]) {
        for location in locations {
            _ = try? navigator.updateLocation(for: FixLocation(location))
        }

        guard let lastRawLocation = locations.last else {
            return
        }

        let status = navigator.status(at: lastRawLocation.timestamp)
        let lastLocation = CLLocation(status.location)

        delegate?.passiveLocationDataSource(self, didUpdateLocation: lastLocation, rawLocation: lastRawLocation)
        let matches = status.map_matcher_output.matches.map {
            Match(legs: [], shape: nil, distance: -1, expectedTravelTime: -1, confidence: $0.proba, weight: .routability(value: 1))
        }
        NotificationCenter.default.post(name: .passiveLocationDataSourceDidUpdate, object: self, userInfo: [
            NotificationUserInfoKey.locationKey: lastLocation,
            NotificationUserInfoKey.rawLocationKey: lastRawLocation,
            NotificationUserInfoKey.matchesKey: matches,
            NotificationUserInfoKey.roadNameKey: status.roadName,
        ])
    }
}

extension PassiveLocationDataSource: CLLocationManagerDelegate {
    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        didUpdate(locations: locations)
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        delegate?.passiveLocationDataSource(self, didUpdateHeading: newHeading)
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        delegate?.passiveLocationDataSource(self, didFailWithError: error)
    }
    
    public func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        if #available(iOS 14.0, *) {
            delegate?.passiveLocationDataSourceDidChangeAuthorization(self)
        }
    }
}

extension PassiveLocationDataSource: ElectronicHorizonObserver {
    public func onPositionUpdated(for position: ElectronicHorizonPosition, distances: [String : RoadObjectDistanceInfo]) {
        electronicHorizonDelegate?.didUpdatePosition(
            EHorizonPosition(position),
            distances: Dictionary(uniqueKeysWithValues:distances.map { key, value in (key, EHorizonObjectDistanceInfo(value)) })
        )
    }

    public func onRoadObjectEnter(for info: RoadObjectEnterExitInfo) {
        electronicHorizonDelegate?.didEnterObject(EHorizonObjectEnterExitInfo(info))
    }

    public func onRoadObjectExit(for info: RoadObjectEnterExitInfo) {
        electronicHorizonDelegate?.didExitRoadObject(EHorizonObjectEnterExitInfo(info))
    }
}

/**
 A delegate of a `PassiveLocationDataSource` object implements methods that the location data source calls as the user’s location changes.
 */
public protocol PassiveLocationDataSourceDelegate: class {
    /// - seealso: `CLLocationManagerDelegate.locationManagerDidChangeAuthorization(_:)`
    @available(iOS 14.0, *)
    func passiveLocationDataSourceDidChangeAuthorization(_ dataSource: PassiveLocationDataSource)
    
    /// - seealso: `CLLocationManagerDelegate.locationManager(_:didUpdateLocations:)`
    func passiveLocationDataSource(_ dataSource: PassiveLocationDataSource, didUpdateLocation location: CLLocation, rawLocation: CLLocation)
    
    /// - seealso: `CLLocationManagerDelegate.locationManager(_:didUpdateHeading:)`
    func passiveLocationDataSource(_ dataSource: PassiveLocationDataSource, didUpdateHeading newHeading: CLHeading)
    
    /// - seealso: `CLLocationManagerDelegate.locationManager(_:didFailWithError:)`
    func passiveLocationDataSource(_ dataSource: PassiveLocationDataSource, didFailWithError error: Error)
}

extension TileEndpointConfiguration {
    /**
     Initializes an object that configures a navigator to obtain routing tiles of the given version from an endpoint, using the given credentials.
     
      - parameter credentials: Credentials for accessing road network data.
      - parameter tilesVersion: Routing tile version.
      - parameter minimumDaysToPersistVersion: The minimum age in days that a tile version much reach before a new version can be requested from the tile endpoint.
     */
    convenience init(credentials: DirectionsCredentials, tilesVersion: String, minimumDaysToPersistVersion: Int?) {
        let host = credentials.host.absoluteString
        guard let accessToken = credentials.accessToken, !accessToken.isEmpty else {
            preconditionFailure("No access token specified in Info.plist")
        }
        let skuTokenProvider = SkuTokenProvider(with: credentials)
        

        self.init(host: host,
                  dataset: "mapbox/driving",
                  version: tilesVersion,
                  token: accessToken,
                  userAgent: URLSession.userAgent,
                  navigatorVersion: "",
                  skuTokenSource: skuTokenProvider,
                  minDiffInDaysToConsiderServerVersion: minimumDaysToPersistVersion as NSNumber?)
    }
}

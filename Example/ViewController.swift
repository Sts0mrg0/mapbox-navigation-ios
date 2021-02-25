import UIKit
import CoreLocation
import MapboxDirections
import Turf
import MapboxCoreNavigation
import MapboxMaps
import MapboxCoreMaps
import MapboxNavigation

class ViewController: UIViewController {
    
    @IBOutlet weak var longPressHintView: UIView!
    @IBOutlet weak var simulationButton: UIButton!
    @IBOutlet weak var startButton: UIButton!
    @IBOutlet weak var bottomBar: UIView!
    @IBOutlet weak var clearMap: UIButton!
    @IBOutlet weak var bottomBarBackground: UIView!
    
    var trackStyledFeature: StyledFeature!
    var rawTrackStyledFeature: StyledFeature!
    // let passiveLocationDataSource: PassiveLocationDataSource? = nil
    let passiveLocationDataSource: PassiveLocationDataSource? = PassiveLocationDataSource()
    
    typealias RouteRequestSuccess = ((RouteResponse) -> Void)
    typealias RouteRequestFailure = ((Error) -> Void)
    typealias ActionHandler = (UIAlertAction) -> Void
    
    var navigationMapView: NavigationMapView! {
        didSet {
            if let navigationMapView = oldValue {
                uninstall(navigationMapView)
            }
            
            if let navigationMapView = navigationMapView {
                configure(navigationMapView)
                view.insertSubview(navigationMapView, belowSubview: longPressHintView)
            }
        }
    }
    
    var waypoints: [Waypoint] = [] {
        didSet {
            waypoints.forEach {
                $0.coordinateAccuracy = -1
            }
        }
    }

    var response: RouteResponse? {
        didSet {
            guard let routes = response?.routes, let currentRoute = routes.first else {
                clearNavigationMapView()
                return
            }
            
            startButton.isEnabled = true
            navigationMapView.show(routes)
            navigationMapView.showWaypoints(on: currentRoute)
        }
    }
    
    weak var activeNavigationViewController: NavigationViewController?
    
    // MARK: - Initializer methods
    
    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        commonInit()
    }
    
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        commonInit()
    }
    
    private func commonInit() {
        if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            appDelegate.currentAppRootViewController = self
        }
    }
    
    deinit {
        if let navigationMapView = navigationMapView {
            uninstall(navigationMapView)
        }
    }
    
    // MARK: - UIViewController lifecycle methods
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        if navigationMapView == nil {
            navigationMapView = NavigationMapView(frame: view.bounds)
        }
        passiveLocationDataSource?.systemLocationManager.startUpdatingLocation()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        requestNotificationCenterAuthorization()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        passiveLocationDataSource?.systemLocationManager.stopUpdatingLocation()
    }
    
    private func configure(_ navigationMapView: NavigationMapView) {
        setupPassiveLocationManager()
        
        navigationMapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(navigationMapView)
        
        navigationMapView.delegate = self
        navigationMapView.mapView.update {
            $0.location.showUserLocation = true
        }
        
        setupGestureRecognizers()
        setupPerformActionBarButtonItem()
    }
    
    private func uninstall(_ navigationMapView: NavigationMapView) {
        unsubscribeFromFreeDriveNotifications()
        navigationMapView.removeFromSuperview()
    }
    
    private func clearNavigationMapView() {
        startButton.isEnabled = false
        clearMap.isHidden = true
        longPressHintView.isHidden = false
        
        // TODO: Unhighlight buildings when clearing map.
        navigationMapView.removeRoutes()
        navigationMapView.removeWaypoints()
        waypoints.removeAll()
    }
    
    func requestNotificationCenterAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.badge, .alert, .sound]) { _, _ in
            DispatchQueue.main.async {
                CLLocationManager().requestWhenInUseAuthorization()
            }
        }
    }
    
    @IBAction func simulateButtonPressed(_ sender: Any) {
        simulationButton.isSelected = !simulationButton.isSelected
    }

    @IBAction func clearMapPressed(_ sender: Any) {
        clearNavigationMapView()
    }

    @IBAction func startButtonPressed(_ sender: Any) {
        presentActionsAlertController()
    }
    
    // MARK: - CarPlay navigation methods
    
    public func beginNavigationWithCarPlay(navigationService: NavigationService) {
        let navigationViewController = activeNavigationViewController ?? self.navigationViewController(navigationService: navigationService)
        navigationViewController.didConnectToCarPlay()

        guard activeNavigationViewController == nil else { return }

        present(navigationViewController)
    }
    
    func beginCarPlayNavigation() {
        let delegate = UIApplication.shared.delegate as? AppDelegate
        
        if #available(iOS 12.0, *),
            let service = activeNavigationViewController?.navigationService,
            let location = service.router.location {
            delegate?.carPlayManager.beginNavigationWithCarPlay(using: location.coordinate, navigationService: service)
        }
    }
    
    private func presentActionsAlertController() {
        let alertController = UIAlertController(title: "Start Navigation", message: "Select the navigation type", preferredStyle: .actionSheet)
        
        let basic: ActionHandler = { _ in self.startBasicNavigation() }
        let day: ActionHandler = { _ in self.startNavigation(styles: [DayStyle()]) }
        let night: ActionHandler = { _ in self.startNavigation(styles: [NightStyle()]) }
        let custom: ActionHandler = { _ in self.startCustomNavigation() }
        let styled: ActionHandler = { _ in self.startStyledNavigation() }
        let guidanceCards: ActionHandler = { _ in self.startGuidanceCardsNavigation() }
        
        let actionPayloads: [(String, UIAlertAction.Style, ActionHandler?)] = [
            ("Default UI", .default, basic),
            ("DayStyle UI", .default, day),
            ("NightStyle UI", .default, night),
            ("Custom UI", .default, custom),
            ("Guidance Card UI", .default, guidanceCards),
            ("Styled UI", .default, styled),
            ("Cancel", .cancel, nil)
        ]
        
        actionPayloads
            .map { payload in UIAlertAction(title: payload.0, style: payload.1, handler: payload.2) }
            .forEach(alertController.addAction(_:))
        
        if let popoverController = alertController.popoverPresentationController {
            popoverController.sourceView = self.startButton
            popoverController.sourceRect = self.startButton.bounds
        }
        
        present(alertController, animated: true, completion: nil)
    }
    
    // MARK: - Active guidance navigation methods.
    
    func startNavigation(styles: [MapboxNavigation.Style]) {
        guard let response = response, let route = response.routes?.first, case let .route(routeOptions) = response.options else { return }
        
        let options = NavigationOptions(styles: styles, navigationService: navigationService(route: route, routeIndex: 0, options: routeOptions))
        let navigationViewController = NavigationViewController(for: route, routeIndex: 0, routeOptions: routeOptions, navigationOptions: options)
        navigationViewController.delegate = self
        
        // Example of building highlighting in 2D.
        navigationViewController.waypointStyle = .building
        
        present(navigationViewController, completion: beginCarPlayNavigation)
    }
    
    func startBasicNavigation() {
        guard let response = response, let route = response.routes?.first, case let .route(routeOptions) = response.options else { return }
        
        let service = navigationService(route: route, routeIndex: 0, options: routeOptions)
        let navigationViewController = self.navigationViewController(navigationService: service)
        
        // Render part of the route that has been traversed with full transparency, to give the illusion of a disappearing route.
        navigationViewController.routeLineTracksTraversal = false
        
        // Example of building highlighting in 3D.
        navigationViewController.waypointStyle = .extrudedBuilding
        
        // Show second level of detail for feedback items.
        navigationViewController.detailedFeedbackEnabled = true
        
        // Control floating buttons position in a navigation view.
        navigationViewController.floatingButtonsPosition = .topTrailing
        
        // Modify default `NavigationViewportDataSource` and `NavigationCameraStateTransition` to change
        // `NavigationCamera` behavior.
        if let mapView = navigationViewController.navigationMapView?.mapView {
            let customViewportDataSource = NavigationViewportDataSource(mapView)
            customViewportDataSource.defaultAltitude = 100.0
            navigationViewController.navigationMapView?.navigationCamera.viewportDataSource = customViewportDataSource
            
            let customCameraStateTransition = CustomCameraStateTransition(mapView)
            navigationViewController.navigationMapView?.navigationCamera.cameraStateTransition = customCameraStateTransition
        }
        
        present(navigationViewController, completion: nil)
    }
    
    func startCustomNavigation() {
        guard let route = response?.routes?.first, let responseOptions = response?.options, case let .route(routeOptions) = responseOptions else { return }

        guard let customViewController = storyboard?.instantiateViewController(withIdentifier: "custom") as? CustomViewController else { return }

        customViewController.userIndexedRoute = (route, 0)
        customViewController.userRouteOptions = routeOptions

        // TODO: Add the ability to show destination annotation.
        customViewController.simulateLocation = simulationButton.isSelected

        present(customViewController, animated: true, completion: nil)
    }

    func startStyledNavigation() {
        guard let response = response, let route = response.routes?.first, case let .route(routeOptions) = response.options else { return }

        let styles = [CustomDayStyle(), CustomNightStyle()]
        let options = NavigationOptions(styles: styles, navigationService: navigationService(route: route, routeIndex: 0, options: routeOptions))
        let navigationViewController = NavigationViewController(for: route, routeIndex: 0, routeOptions: routeOptions, navigationOptions: options)
        navigationViewController.delegate = self

        present(navigationViewController, completion: beginCarPlayNavigation)
    }
    
    func startGuidanceCardsNavigation() {
        guard let response = response, let route = response.routes?.first, case let .route(routeOptions) = response.options else { return }
        
        let instructionsCardCollection = InstructionsCardViewController()
        instructionsCardCollection.cardCollectionDelegate = self
        
        let options = NavigationOptions(navigationService: navigationService(route: route, routeIndex: 0, options: routeOptions), topBanner: instructionsCardCollection)
        let navigationViewController = NavigationViewController(for: route, routeIndex: 0, routeOptions: routeOptions, navigationOptions: options)
        navigationViewController.delegate = self
        
        present(navigationViewController, completion: beginCarPlayNavigation)
    }
    
    // MARK: - UIGestureRecognizer methods
    
    func setupGestureRecognizers() {
        let longPressGestureRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        navigationMapView.gestureRecognizers?.filter({ $0 is UILongPressGestureRecognizer }).forEach(longPressGestureRecognizer.require(toFail:))
        navigationMapView.addGestureRecognizer(longPressGestureRecognizer)
    }
    
    func setupPerformActionBarButtonItem() {
        let settingsBarButtonItem = UIBarButtonItem(title: NSString(string: "\u{2699}\u{0000FE0E}") as String, style: .plain, target: self, action: #selector(performAction))
        settingsBarButtonItem.setTitleTextAttributes([.font : UIFont.systemFont(ofSize: 30)], for: .normal)
        settingsBarButtonItem.setTitleTextAttributes([.font : UIFont.systemFont(ofSize: 30)], for: .highlighted)
        navigationItem.rightBarButtonItem = settingsBarButtonItem
    }
    
    @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let gestureLocation = gesture.location(in: navigationMapView)
        let destinationCoordinate = navigationMapView.mapView.coordinate(for: gestureLocation,
                                                                         in: navigationMapView)
        
        // TODO: Implement ability to get last annotation.
        // if let annotation = navigationMapView.annotations?.last, waypoints.count > 2 {
        //     mapView.removeAnnotation(annotation)
        // }
        
        if waypoints.count > 1 {
            waypoints = Array(waypoints.dropFirst())
        }
        
        // Note: The destination name can be modified. The value is used in the top banner when arriving at a destination.
        let waypoint = Waypoint(coordinate: destinationCoordinate, name: "Dropped Pin #\(waypoints.endIndex + 1)")
        // Example of building highlighting. `targetCoordinate`, in this example,
        // is used implicitly by NavigationViewController to determine which buildings to highlight.
        waypoint.targetCoordinate = destinationCoordinate
        waypoints.append(waypoint)
        
        requestRoute()
    }
    
    @objc func performAction(_ sender: Any) {
        let alertController = UIAlertController(title: "Perform action",
                                                message: "Select specific action to perform it", preferredStyle: .actionSheet)
        
        let toggleDayNightStyle: ActionHandler = { _ in self.toggleDayNightStyle() }
        let requestNavigationFollowingCamera: ActionHandler = { _ in self.requestNavigationFollowingCamera() }
        let requestNavigationIdleCamera: ActionHandler = { _ in self.requestNavigationIdleCamera() }
        let overrideViewportDataSourceAndCameraTransition: ActionHandler = { _ in self.overrideViewportDataSourceAndCameraTransition() }
        
        let actions: [(String, UIAlertAction.Style, ActionHandler?)] = [
            ("Toggle Day/Night Style", .default, toggleDayNightStyle),
            ("Request Following Camera", .default, requestNavigationFollowingCamera),
            ("Request Idle Camera", .default, requestNavigationIdleCamera),
            ("Override camera", .default, overrideViewportDataSourceAndCameraTransition),
            ("Cancel", .cancel, nil)
        ]
        
        actions
            .map({ payload in UIAlertAction(title: payload.0, style: payload.1, handler: payload.2) })
            .forEach(alertController.addAction(_:))
        
        if let popoverController = alertController.popoverPresentationController {
            popoverController.barButtonItem = navigationItem.rightBarButtonItem
        }
        
        present(alertController, animated: true, completion: nil)
    }
    
    func toggleDayNightStyle() {
        if navigationMapView.mapView?.style.styleURL.url == MapboxMaps.Style.navigationNightStyleURL {
            navigationMapView.mapView?.style.styleURL = StyleURL.custom(url: MapboxMaps.Style.navigationDayStyleURL)
        } else {
            navigationMapView.mapView?.style.styleURL = StyleURL.custom(url: MapboxMaps.Style.navigationNightStyleURL)
        }
    }
    
    func requestNavigationFollowingCamera() {
        navigationMapView.navigationCamera.requestNavigationCameraToFollowing()
    }
    
    func requestNavigationIdleCamera() {
        navigationMapView.navigationCamera.requestNavigationCameraToIdle()
    }
    
    func overrideViewportDataSourceAndCameraTransition() {
        let customViewportDataSource = CustomViewportDataSource(navigationMapView.mapView)
        // let customViewportDataSource = NavigationViewportDataSource(navigationMapView.mapView)
        // customViewportDataSource.defaultAltitude = 300.0
        navigationMapView.navigationCamera.viewportDataSource = customViewportDataSource
        
        let customCameraStateTransition = CustomCameraStateTransition(navigationMapView.mapView)
        navigationMapView.navigationCamera.cameraStateTransition = customCameraStateTransition
    }
    
    func requestRoute() {
        guard waypoints.count > 0 else { return }
        guard let currentLocation = navigationMapView.mapView.locationManager.latestLocation?.internalLocation else {
            print("User location is not valid. Make sure to enable Location Services.")
            return
        }
        
        let userWaypoint = Waypoint(location: currentLocation)
        waypoints.insert(userWaypoint, at: 0)

        let navigationRouteOptions = NavigationRouteOptions(waypoints: waypoints)
        
        // Get periodic updates regarding changes in estimated arrival time and traffic congestion segments along the route line.
        RouteControllerProactiveReroutingInterval = 30

        requestRoute(with: navigationRouteOptions, success: defaultSuccess, failure: defaultFailure)
    }
        
    fileprivate lazy var defaultSuccess: RouteRequestSuccess = { [weak self] (response) in
        guard let routes = response.routes, !routes.isEmpty, case let .route(options) = response.options else { return }
        self?.navigationMapView.removeWaypoints()
        self?.response = response
        
        // Waypoints which were placed by the user are rewritten by slightly changed waypoints
        // which are returned in response with routes.
        if let waypoints = response.waypoints {
            self?.waypoints = waypoints
        }
        
        self?.clearMap.isHidden = false
        self?.longPressHintView.isHidden = true
    }

    fileprivate lazy var defaultFailure: RouteRequestFailure = { [weak self] (error) in
        // Clear routes from the map
        self?.response = nil
        self?.presentAlert(message: error.localizedDescription)
    }

    func requestRoute(with options: RouteOptions, success: @escaping RouteRequestSuccess, failure: RouteRequestFailure?) {
        Directions.shared.calculate(options) { (session, result) in
            switch result {
            case let .success(response):
                success(response)
            case let .failure(error):
                failure?(error)
            }
        }
    }
    
    func navigationViewController(navigationService: NavigationService) -> NavigationViewController {
        let navigationOptions = NavigationOptions(navigationService: navigationService)

        let navigationViewController = NavigationViewController(for: navigationService.route,
                                                                routeIndex: navigationService.indexedRoute.1,
                                                                routeOptions: navigationService.routeProgress.routeOptions,
                                                                navigationOptions: navigationOptions)
        navigationViewController.delegate = self
        
        return navigationViewController
    }
    
    func present(_ navigationViewController: NavigationViewController, completion: CompletionHandler? = nil) {
        navigationViewController.modalPresentationStyle = .fullScreen
        activeNavigationViewController = navigationViewController
        
        present(navigationViewController, animated: true) {
            completion?()
        }
    }
    
    func endCarPlayNavigation(canceled: Bool) {
        if #available(iOS 12.0, *), let delegate = UIApplication.shared.delegate as? AppDelegate {
            delegate.carPlayManager.currentNavigator?.exitNavigation(byCanceling: canceled)
        }
    }
    
    func dismissActiveNavigationViewController() {
        activeNavigationViewController?.dismiss(animated: true) {
            self.activeNavigationViewController = nil
        }
    }

    func navigationService(route: Route, routeIndex: Int, options: RouteOptions) -> NavigationService {
        let mode: SimulationMode = simulationButton.isSelected ? .always : .onPoorGPS
        
        return MapboxNavigationService(route: route, routeIndex: routeIndex, routeOptions: options, simulating: mode)
    }
    
    // MARK: - Utility methods
    
    func presentAlert(_ title: String? = nil, message: String? = nil) {
        let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alertController.addAction(UIAlertAction(title: "OK", style: .default, handler: { (action) in
            alertController.dismiss(animated: true, completion: nil)
        }))
        
        present(alertController, animated: true, completion: nil)
    }
}

// MARK: - NavigationMapViewDelegate methods

extension ViewController: NavigationMapViewDelegate {
    
    func navigationMapView(_ navigationMapView: NavigationMapView, waypointCircleLayerWithIdentifier identifier: String, sourceIdentifier: String) -> CircleLayer? {
        var circleLayer = CircleLayer(id: identifier)
        circleLayer.source = sourceIdentifier
        let opacity = Exp(.switchCase) {
            Exp(.any) {
                Exp(.get) {
                    "waypointCompleted"
                }
            }
            0.5
            1
        }
        circleLayer.paint?.circleColor = .constant(.init(color: UIColor(red:0.9, green:0.9, blue:0.9, alpha:1.0)))
        circleLayer.paint?.circleOpacity = .expression(opacity)
        circleLayer.paint?.circleRadius = .constant(.init(10))
        circleLayer.paint?.circleStrokeColor = .constant(.init(color: UIColor.black))
        circleLayer.paint?.circleStrokeWidth = .constant(.init(1))
        circleLayer.paint?.circleStrokeOpacity = .expression(opacity)
        return circleLayer
    }

    func navigationMapView(_ navigationMapView: NavigationMapView, waypointSymbolLayerWithIdentifier identifier: String, sourceIdentifier: String) -> SymbolLayer? {
        var symbolLayer = SymbolLayer(id: identifier)
        symbolLayer.source = sourceIdentifier
        symbolLayer.layout?.textField = .expression(Exp(.toString){
                                                        Exp(.get){
                                                            "name"
                                                        }
                                                    })
        symbolLayer.layout?.textSize = .constant(.init(10))
        symbolLayer.paint?.textOpacity = .expression(Exp(.switchCase) {
            Exp(.any) {
                Exp(.get) {
                    "waypointCompleted"
                }
            }
            0.5
            1
        })
        symbolLayer.paint?.textHaloWidth = .constant(.init(0.25))
        symbolLayer.paint?.textHaloColor = .constant(.init(color: UIColor.black))
        return symbolLayer
    }
    
    func navigationMapView(_ navigationMapView: NavigationMapView, shapeFor waypoints: [Waypoint], legIndex: Int) -> FeatureCollection? {
        var features = [Feature]()
        for (waypointIndex, waypoint) in waypoints.enumerated() {
            var feature = Feature(Point(waypoint.coordinate))
            feature.properties = [
                "waypointCompleted": waypointIndex < legIndex,
                "name": "#\(waypointIndex + 1)"
            ]
            features.append(feature)
        }
        return FeatureCollection(features: features)
    }
    
    func navigationMapView(_ mapView: NavigationMapView, didSelect waypoint: Waypoint) {
        guard let responseOptions = response?.options, case let .route(routeOptions) = responseOptions else { return }
        let modifiedOptions = routeOptions.without(waypoint: waypoint)

        presentWaypointRemovalAlert { _ in
            self.requestRoute(with:modifiedOptions, success: self.defaultSuccess, failure: self.defaultFailure)
        }
    }

    func navigationMapView(_ mapView: NavigationMapView, didSelect route: Route) {
        guard let routes = response?.routes else { return }
        guard let index = routes.firstIndex(where: { $0 === route }) else { return }
        self.response?.routes?.swapAt(index, 0)
    }

    private func presentWaypointRemovalAlert(completionHandler approve: @escaping ((UIAlertAction) -> Void)) {
        let title = NSLocalizedString("REMOVE_WAYPOINT_CONFIRM_TITLE", value: "Remove Waypoint?", comment: "Title of alert confirming waypoint removal")
        let message = NSLocalizedString("REMOVE_WAYPOINT_CONFIRM_MSG", value: "Do you want to remove this waypoint?", comment: "Message of alert confirming waypoint removal")
        let removeTitle = NSLocalizedString("REMOVE_WAYPOINT_CONFIRM_REMOVE", value: "Remove Waypoint", comment: "Title of alert action for removing a waypoint")
        let cancelTitle = NSLocalizedString("REMOVE_WAYPOINT_CONFIRM_CANCEL", value: "Cancel", comment: "Title of action for dismissing waypoint removal confirmation sheet")
        
        let waypointRemovalAlertController = UIAlertController(title: title, message: message, preferredStyle: .alert)
        let removeAction = UIAlertAction(title: removeTitle, style: .destructive, handler: approve)
        let cancelAction = UIAlertAction(title: cancelTitle, style: .cancel, handler: nil)
        [removeAction, cancelAction].forEach(waypointRemovalAlertController.addAction(_:))
        
        self.present(waypointRemovalAlertController, animated: true, completion: nil)
    }
}

// MARK: - RouteVoiceControllerDelegate methods

extension ViewController: RouteVoiceControllerDelegate {

}

// MARK: - NavigationViewControllerDelegate methods

extension ViewController: NavigationViewControllerDelegate {

    func navigationViewController(_ navigationViewController: NavigationViewController, didArriveAt waypoint: Waypoint) -> Bool {
        return true
    }
    
    func navigationViewControllerDidDismiss(_ navigationViewController: NavigationViewController, byCanceling canceled: Bool) {
        endCarPlayNavigation(canceled: canceled)
        dismissActiveNavigationViewController()
        clearNavigationMapView()
    }
    
    func navigationViewController(_ navigationViewController: NavigationViewController, waypointCircleLayerWithIdentifier identifier: String, sourceIdentifier: String) -> CircleLayer? {
        var circleLayer = CircleLayer(id: identifier)
        circleLayer.source = sourceIdentifier
        let opacity = Exp(.switchCase) {
            Exp(.any) {
                Exp(.get) {
                    "waypointCompleted"
                }
            }
            0.5
            1
        }
        circleLayer.paint?.circleColor = .constant(.init(color: UIColor(red:0.9, green:0.9, blue:0.9, alpha:1.0)))
        circleLayer.paint?.circleOpacity = .expression(opacity)
        circleLayer.paint?.circleRadius = .constant(.init(10))
        circleLayer.paint?.circleStrokeColor = .constant(.init(color: UIColor.black))
        circleLayer.paint?.circleStrokeWidth = .constant(.init(1))
        circleLayer.paint?.circleStrokeOpacity = .expression(opacity)
        return circleLayer
    }

    func navigationViewController(_ navigationViewController: NavigationViewController, waypointSymbolLayerWithIdentifier identifier: String, sourceIdentifier: String) -> SymbolLayer? {
        var symbolLayer = SymbolLayer(id: identifier)
        symbolLayer.source = sourceIdentifier
        symbolLayer.layout?.textField = .expression(Exp(.toString) {
                                                        Exp(.get){
                                                            "name"
                                                        }
                                                    })
        symbolLayer.layout?.textSize = .constant(.init(10))
        symbolLayer.paint?.textOpacity = .expression(Exp(.switchCase) {
            Exp(.any) {
                Exp(.get) {
                    "waypointCompleted"
                }
            }
            0.5
            1
        })
        symbolLayer.paint?.textHaloWidth = .constant(.init(0.25))
        symbolLayer.paint?.textHaloColor = .constant(.init(color: UIColor.black))
        return symbolLayer
    }
    
    func navigationViewController(_ navigationViewController: NavigationViewController, shapeFor waypoints: [Waypoint], legIndex: Int) -> FeatureCollection? {
        var features = [Feature]()
        for (waypointIndex, waypoint) in waypoints.enumerated() {
            var feature = Feature(Point(waypoint.coordinate))
            feature.properties = [
                "waypointCompleted": waypointIndex < legIndex,
                "name": "#\(waypointIndex + 1)"
            ]
            features.append(feature)
        }
        return FeatureCollection(features: features)
    }
}

// MARK: - VisualInstructionDelegate methods

extension ViewController: VisualInstructionDelegate {

}

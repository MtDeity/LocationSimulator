//
//  WindowController.swift
//  LocationSimulator
//
//  Created by David Klopp on 18.08.19.
//  Copyright © 2019 David Klopp. All rights reserved.
//

import Foundation
import AppKit
import MapKit

/// The main window controller instance which hosts the map view and the toolbar.
class WindowController: NSWindowController {
    /// Enable, disable autofocus current location.
    @IBOutlet weak var autofocusLocationButton: NSButton!

    /// Set the current PC location as the spoofed location.
    @IBOutlet weak var currentLocationButton: NSButton!

    /// Change the current move speed.
    @IBOutlet weak var typeSegmented: NSSegmentedControl!

    /// Change the current move speed using the touchbar.
    @IBOutlet var typeSegmentedTouchbar: NSSegmentedControl!

    /// Search for a location inside the map.
    @IBOutlet weak var searchField: LocationSearchField!

    /// Change the current device.
    @IBOutlet weak var devicesPopup: NSPopUpButton!

    /// Search completer to find a location based on a string.
    public var searchCompleter: MKLocalSearchCompleter!

    /// All currently connected devices.
    public var devices: [Device] = []

    /// Cache to store the last known location for each device as long as it is connected
    var lastKnownLocationCache: [Device: CLLocationCoordinate2D] = [:]

    /// Internal reference to a NotificationCenterObserver.
    private var autofocusObserver: Any?

    /// Internal reference to a location manager for this mac's location
    private let locationManager = CLLocationManager()

    // MARK: - Window lifecycle

    override func windowDidLoad() {
        super.windowDidLoad()

        // register the default setting values
        UserDefaults.standard.registerNetworkDefaultValues()

        // Load the default value for network devices
        Device.detectNetworkDevices = UserDefaults.standard.detectNetworkDevices

        if Device.startGeneratingDeviceNotifications() {
            self.registerDeviceNotifications()
        }

        // Request the permission to access the mac's location.
        // Otherwise the current location button won't work.
        if #available(OSX 10.15, *) {
            locationManager.requestAlwaysAuthorization()
        }
        locationManager.desiredAccuracy = kCLLocationAccuracyBest

        // setup the location searchfield
        self.searchField.tableViewDelegate = self

        // only search for locations
        self.searchCompleter = MKLocalSearchCompleter()
        if #available(OSX 10.15, *) {
            self.searchCompleter.resultTypes = .address
        } else {
            // Fallback on earlier versions
            self.searchCompleter.filterType = .locationsOnly
        }
        self.searchCompleter.delegate = self

        // listen to current location changes
        self.autofocusObserver = NotificationCenter.default.addObserver(forName: .AutoFoucusCurrentLocationChanged,
                                                                        object: nil, queue: .main) { (notification) in
            if let isOn = notification.object as? Bool, isOn == true {
                self.autofocusLocationButton.state = .on
            } else {
                self.autofocusLocationButton.state = .off
            }
        }
    }

    deinit {
        // stop generating update notifications (0 != 1 can never occur)
        Device.stopGeneratingDeviceNotifications()

        // remove all notifications
        if let observer = self.autofocusObserver {
            NotificationCenter.default.removeObserver(observer)
            self.autofocusObserver = nil
        }
    }

    // MARK: - Interface Builder callbacks

    /// Toggle the autofocus feature on or off.
    /// - Parameter sender: the button which triggered the action
    @IBAction func autofocusLocationClicked(_ sender: NSButton) {
        guard let viewController = self.contentViewController as? MapViewController else { return }
        viewController.autoFocusCurrentLocation = (sender.state == .on)
    }

    /// Change the move speed to walk / cycle / drive based on the selected segment. Futhermore update the tool- and
    /// touchbar to represent the current status.
    /// - Parameter sender: the segmented control instance inside the tool- or touchbar.
    @IBAction func typeSegmentChanged(_ sender: NSSegmentedControl) {
        guard let viewController = self.contentViewController as? MapViewController else { return }

        // Update the toolbar state if the touchbar was clicked.
        if self.typeSegmented.selectedSegment != sender.selectedSegment {
            self.typeSegmented.selectedSegment = sender.selectedSegment
        }

        // Update the touchbar state if the toolbar was clicked.
        if self.typeSegmentedTouchbar.selectedSegment != sender.selectedSegment {
            self.typeSegmentedTouchbar.selectedSegment = sender.selectedSegment
        }

        viewController.spoofer?.moveType = MoveType(rawValue: sender.selectedSegment)!
    }

    /// Stop spoofing the current location.
    /// - Parameter sender: the button which triggered the action
    @IBAction func resetClicked(_ sender: Any) {
        guard let viewController = contentViewController as? MapViewController else { return }
        viewController.spoofer?.resetLocation()
    }

    @IBAction func currentLocationClicked(_ sender: Any) {
        guard let viewController = contentViewController as? MapViewController,
              let spoofer = viewController.spoofer else { return }

        guard CLLocationManager.locationServicesEnabled() else {
            window?.showError(
                NSLocalizedString("LOCATION_SERVICE_DISABLED", comment: ""),
                message: NSLocalizedString("LOCATION_SERVICE_DISABLED_MSG", comment: ""))
            return
        }

        // Check if we can read the current user location.
        guard let coord = locationManager.location?.coordinate else {
            window?.showError(
                NSLocalizedString("GET_LOCATION_ERROR", comment: ""),
                message: NSLocalizedString("GET_LOCATION_ERROR_MSG", comment: ""))
            return
        }

        // We silently fail if no spoofer instance exists / no device is connected.
        spoofer.setLocation(coord)
    }

    /// Change the currently select device to the new devive choosen from the list.
    /// - Parameter sender: the button which triggered the action
    @IBAction func deviceSelected(_ sender: NSPopUpButton) {
        guard let viewController = self.contentViewController as? MapViewController else { return }

        // New device is connected without a spoofed location
        MenubarController.state = .connected

        let index: Int = sender.indexOfSelectedItem
        let device: Device = self.devices[index]

        // cleanup the UI if a previous device was selected
        if let spoofer = viewController.spoofer {
            // if the selection did not change do nothing
            guard spoofer.device != device else { return }
            // reset the timer and cancel all delegate updates
            spoofer.moveState = .manual
            spoofer.delegate = nil

            // store the last known location for the last device
            self.lastKnownLocationCache[spoofer.device] = spoofer.currentLocation

            // explicitly force the UI to reset
            viewController.willChangeLocation(spoofer: spoofer, toCoordinate: nil)
            viewController.didChangeLocation(spoofer: spoofer, toCoordinate: nil)
        }

        let deviceLoadHandler = {
            // load the new device
            try viewController.load(device: device)
            // set the correct walking speed based on the current selection
            viewController.spoofer?.moveType = MoveType(rawValue: self.typeSegmented.selectedSegment) ?? .walk
            viewController.contentView?.hideErrorInidcator()

            // Activate the menubar items
            MenubarController.state = .connected

            // Check if we already have a known location for this device, if so load it.
            // TODO: This is not an optimal solution, because we do not keep information about the current route or
            // automove state. We could fix this by serializing the spoofer instance... but this is low priority.
            if let spoofer = viewController.spoofer, let coordinate = self.lastKnownLocationCache[device] {
                spoofer.currentLocation = coordinate
                viewController.willChangeLocation(spoofer: spoofer, toCoordinate: coordinate)
                viewController.didChangeLocation(spoofer: spoofer, toCoordinate: coordinate)
                // enable the move menubar items
                spoofer.moveState = .manual
            }
        }

        do {
            try deviceLoadHandler()
        } catch DeviceError.devDiskImageNotFound(_, let os, let iOSVersion) {
            // Show the error indicator
            viewController.contentView?.showErrorInidcator()

            // try to load device after a successfull DeveloperDiskImage download
            if viewController.downloadDeveloperDiskImage(os: os, iOSVersion: iOSVersion) {
                // Check if any device is left
                let index = self.devicesPopup.indexOfSelectedItem
                guard index >= 0 else { return }

                // If the device is still the selected device try to reload it
                let selectedDevice = self.devices[index]
                if selectedDevice == device {
                    do {
                        try deviceLoadHandler()
                        viewController.contentView?.hideErrorInidcator()
                    } catch {}
                }
            }
        } catch {
            // Show the error indicator
            viewController.contentView?.showErrorInidcator()
        }
    }
}
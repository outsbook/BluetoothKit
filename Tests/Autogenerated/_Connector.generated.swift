import Foundation
import RxSwift
import CoreBluetooth
@testable import RxBluetoothKit

/// `ConnectorMock` is a class that is responsible for establishing connection with peripherals.
class _Connector {
    let centralManager: CBCentralManagerMock
    let delegateWrapper: CBCentralManagerDelegateWrapperMock
    let connectedBox: ThreadSafeBox<Set<UUID>> = ThreadSafeBox(value: [])
    let disconnectingBox: ThreadSafeBox<Set<UUID>> = ThreadSafeBox(value: [])

    init(
        centralManager: CBCentralManagerMock,
        delegateWrapper: CBCentralManagerDelegateWrapperMock
    ) {
        self.centralManager = centralManager
        self.delegateWrapper = delegateWrapper
    }

    /// Establishes connection with a given `_Peripheral`.
    /// For more information see `_CentralManager.establishConnection(with:options:)`
    func establishConnection(with peripheral: _Peripheral, options: [String: Any]? = nil)
        -> Observable<_Peripheral> {
            return .deferred { [weak self] in
                guard let strongSelf = self else {
                    return Observable.error(_BluetoothError.destroyed)
                }

                let connectionObservable = strongSelf.createConnectionObservable(for: peripheral, options: options)

                let waitForDisconnectObservable = strongSelf.delegateWrapper.didDisconnectPeripheral
                    .filter { $0.0 == peripheral.peripheral }
                    .take(1)
                    .do(onNext: { [weak self] _ in
                        guard let strongSelf = self else { return }
                        strongSelf.disconnectingBox.write { $0.remove(peripheral.identifier) }
                    })
                    .map { _ in peripheral }
                let isDisconnectingObservable: Observable<_Peripheral> = Observable.create { observer in
                    var isDiconnecting = strongSelf.disconnectingBox.read { $0.contains(peripheral.identifier) }
                    let isDisconnected = peripheral.state == .disconnected
                    // it means that peripheral is already disconnected, but we didn't update disconnecting box
                    if isDiconnecting && isDisconnected {
                        strongSelf.disconnectingBox.write { $0.remove(peripheral.identifier) }
                        isDiconnecting = false
                    }
                    if !isDiconnecting {
                        observer.onNext(peripheral)
                    }
                    return Disposables.create()
                }
                return waitForDisconnectObservable.amb(isDisconnectingObservable)
                    .flatMap { _ in connectionObservable }
            }
    }

    fileprivate func createConnectionObservable(
        for peripheral: _Peripheral,
        options: [String: Any]? = nil
    ) -> Observable<_Peripheral> {
        return Observable.create { [weak self] observer in
            guard let strongSelf = self else {
                observer.onError(_BluetoothError.destroyed)
                return Disposables.create()
            }

            let connectingStarted = strongSelf.connectedBox.compareAndSet(
                compare: { !$0.contains(peripheral.identifier) },
                set: { $0.insert(peripheral.identifier) }
            )

            guard connectingStarted else {
                observer.onError(_BluetoothError.peripheralIsAlreadyObservingConnection(peripheral))
                return Disposables.create()
            }

            let connectedObservable = strongSelf.createConnectedObservable(for: peripheral)
            let failToConnectObservable = strongSelf.createFailToConnectObservable(for: peripheral)
            let disconnectedObservable = strongSelf.createDisconnectedObservable(for: peripheral)

            let disposable = connectedObservable.amb(failToConnectObservable)
                .do(onNext: { observer.onNext($0) })
                .flatMap { _ in disconnectedObservable }
                .subscribe(onError: { observer.onError($0) })

            // Apple recommends to always connect to a peripheral after retrieving it.
            // https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/BestPracticesForInteractingWithARemotePeripheralDevice/BestPracticesForInteractingWithARemotePeripheralDevice.html#//apple_ref/doc/uid/TP40013257-CH6-SW9
            //
            // Excerpts from "Reconnecting to Peripherals"
            //
            // "Retrieve a list of known peripherals???peripherals that you???ve discovered or connected to in the past???using the
            // retrievePeripheralsWithIdentifiers: method. If the peripheral you???re looking for is in the list, try to connect to it."
            //
            // "Assuming that the user finds and selects the desired peripheral, connect it locally to your app by calling the
            // connectPeripheral:options: method of the CBCentralManagerMock class. (Even though the device is already connected to
            // the system, you must still connect it locally to your app to begin exploring and interacting with it.) When the local
            // connection is established, the central manager calls the centralManager:didConnectPeripheral: method of its delegate
            // object, and the peripheral device is successfully reconnected."
            strongSelf.centralManager.connect(peripheral.peripheral, options: options)

            return Disposables.create { [weak self] in
                guard let strongSelf = self else { return }
                disposable.dispose()
                let isConnected = strongSelf.connectedBox.read { $0.contains(peripheral.identifier) }
                if isConnected {
                    if strongSelf.centralManager.state == .poweredOn {
                        strongSelf.disconnectingBox.write { $0.insert(peripheral.identifier) }
                        strongSelf.centralManager.cancelPeripheralConnection(peripheral.peripheral)
                    }
                    strongSelf.connectedBox.write { $0.remove(peripheral.identifier) }
                }
            }
        }
    }

    fileprivate func createConnectedObservable(for peripheral: _Peripheral) -> Observable<_Peripheral> {
        return delegateWrapper.didConnectPeripheral
            .filter { $0 == peripheral.peripheral }
            .take(1)
            .map { _ in peripheral }
    }

    fileprivate func createDisconnectedObservable(for peripheral: _Peripheral) -> Observable<_Peripheral> {
        return delegateWrapper.didDisconnectPeripheral
            .filter { $0.0 == peripheral.peripheral }
            .take(1)
            .do(onNext: { [weak self] _ in
                guard let strongSelf = self else { return }
                strongSelf.connectedBox.write { $0.remove(peripheral.identifier) }
                strongSelf.disconnectingBox.write { $0.remove(peripheral.identifier) }
            })
            .map { (_, error) -> _Peripheral in
                throw _BluetoothError.peripheralDisconnected(peripheral, error)
            }
    }

    fileprivate func createFailToConnectObservable(for peripheral: _Peripheral) -> Observable<_Peripheral> {
        return delegateWrapper.didFailToConnectPeripheral
            .filter { $0.0 == peripheral.peripheral }
            .take(1)
            .do(onNext: { [weak self] _ in
                guard let strongSelf = self else { return }
                strongSelf.connectedBox.write { $0.remove(peripheral.identifier) }
            })
            .map { (_, error) -> _Peripheral in
                throw _BluetoothError.peripheralConnectionFailed(peripheral, error)
            }
    }
}

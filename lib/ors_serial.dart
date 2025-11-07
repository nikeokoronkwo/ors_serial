import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:objective_c/objective_c.dart';

import 'src/ors_serial_bindings_generated.dart' as _bindings;

const String _libName = 'ORSSerial';

final DynamicLibrary _dynamicLib = () {
  if (Platform.isMacOS || Platform.isIOS) {
    return DynamicLibrary.open('$_libName.framework/$_libName');
  }
  throw UnsupportedError('Unsupported or Unknown platform: ${Platform.operatingSystem}. Only works on macOS and iOS (iPad)');
}();

class ORSSerialException implements Exception {
  final NSError objcError;
  final String message;

  ORSSerialException(this.objcError, {required this.message});
}

// TODO: Support RegExp
// TODO: ObjCBlock Instantiation:
class ORSSerialPacketDescriptor {
  final _bindings.ORSSerialPacketDescriptor packetDescriptor;

  ORSSerialPacketDescriptor._(this.packetDescriptor);
  ORSSerialPacketDescriptor.withPrefix(
    String prefix, {
    String? suffix,
    required int maximumPacketLength,
  }) : packetDescriptor = _bindings.ORSSerialPacketDescriptor.alloc()
           .initWithPrefixString(
             prefix.toNSString(),
             maximumPacketLength: maximumPacketLength,
             suffixString: suffix?.toNSString(),
           );
  ORSSerialPacketDescriptor.withPrefixData(
    Uint8List prefix, {
    Uint8List? suffix,
    required int maximumPacketLength,
  }) : packetDescriptor = _bindings.ORSSerialPacketDescriptor.alloc()
           .initWithPrefix(
             prefix.toNSData(),
             maximumPacketLength: maximumPacketLength,
             suffix: suffix?.toNSData(),
           );
  ORSSerialPacketDescriptor.fixed(Uint8List packetData)
    : packetDescriptor = _bindings.ORSSerialPacketDescriptor.alloc()
          .initWithPacketData(packetData.toNSData());
  ORSSerialPacketDescriptor({
    required int maximumPacketLength,
    required bool Function(NSData? data) responseEvaluator
  })
  : packetDescriptor = _bindings.ORSSerialPacketDescriptor.alloc().initWithMaximumPacketLength(
    maximumPacketLength,
    responseEvaluator: _bindings.ObjCBlock_bool_NSData.fromFunction(responseEvaluator)
  );
}

class ORSSerialPort {
  final DynamicLibrary _dylib;
  final _bindings.ORSSerialPort _serialPort;

  final StreamController<Uint8List> _dataController;
  final Map<_bindings.NSUUID, StreamController<Uint8List>> _packetControllers;

  /// A stream of [Uint8List] containing the data from the serial port
  /// thanks to the [_bindings.ORSSerialPortDelegate]
  Stream<Uint8List> get data => _dataController.stream;

  ORSSerialPort._(
    this._serialPort,
    this._dataController,
    StreamController<(_bindings.ORSSerialPacketDescriptor, NSData)>
    packetController, [
    DynamicLibrary? dylib,
  ]) : _packetControllers = {},
       _dylib = dylib ?? _dynamicLib {
    packetController.stream.listen((event) {
      final (descriptor, data) = event;
      _packetControllers.update(
        descriptor.uuid,
        (v) => v..add(data.toList()),
        ifAbsent: () => StreamController.broadcast()..add(data.toList()),
      );
    });
  }

  factory ORSSerialPort._fromNativePort(
    _bindings.ORSSerialPort port, {
    void Function(Uint8List, [ORSSerialPacketDescriptor?])? onReceive,
    void Function()? onRemoveSerialPort,
  }) {
    final StreamController<Uint8List> controller = StreamController.broadcast();
    final StreamController<(_bindings.ORSSerialPacketDescriptor, NSData)>
    packetController = StreamController.broadcast();

    port.delegate = _bindings.ORSSerialPortDelegate.implement(
      serialPortWasRemovedFromSystem_: (serial) {
        serial.release();
        onRemoveSerialPort?.call();
      },
      serialPort_didReceiveData_: (port, data) {
        final dataList = data.toList();
        // add to controller
        controller.add(dataList);
        onReceive?.call(dataList);
      },
      serialPort_didReceivePacket_matchingDescriptor_:
          (port, data, packetDescriptor) {
            // send to each packet stream
            packetController.add((packetDescriptor, data));
            onReceive?.call(
              data.toList(),
              ORSSerialPacketDescriptor._(packetDescriptor),
            );
          },
      serialPort_didEncounterError_: (port, error) {
        throw ORSSerialException(
          error,
          message: "Error encountered when reading from serial port",
        );
      },
    );

    return ORSSerialPort._(port, controller, packetController);
  }

  /// An array containing ORSSerialPort instances representing the
  /// serial ports available on the system. (read-only)
  ///
  /// As explained above, this property is Key Value Observing
  /// compliant, and can be bound to for example an NSPopUpMenu
  /// to easily give the user a way to select an available port
  /// on the system.
  static List<ORSSerialPort> get availablePorts {
    final manager = _bindings.ORSSerialPortManager.sharedSerialPortManager();
    return manager.availablePorts.toList().map((obj) {
      final serialPort = _bindings.ORSSerialPort.castFrom(obj);

      return ORSSerialPort._fromNativePort(serialPort);
    }).toList();
  }

  /// Returns an [ORSSerialPort] instance representing the serial port at [devicePath].
  ///
  /// [devicePath] must be the full, callout (cu.) or tty (tty.) path to an available
  /// serial port device on the system.
  ///
  /// @param [devicePath] The full path (e.g. /dev/cu.usbserial) to the device.
  ///
  /// @return An initalized [ORSSerialPort] instance, or nil if there was an error.
  ///
  /// @see [ORSSerialPort.availablePorts]
  /// @see [ORSSerialPort.withPath]
  static ORSSerialPort serialPortWithPath(String devicePath) {
    // create the serial port
    final serial = _bindings.ORSSerialPort.serialPortWithPath(
      devicePath.toNSString(),
    );
    if (serial == null) {
      throw Exception("Could not create serial port");
    }

    return ORSSerialPort._fromNativePort(serial);
  }

  /// Returns an [ORSSerialPort] instance representing the serial port at [devicePath].
  ///
  /// [devicePath] must be the full, callout (cu.) or tty (tty.) path to an available
  /// serial port device on the system.
  ///
  /// @param [devicePath] The full path (e.g. /dev/cu.usbserial) to the device.
  ///
  /// @return An initalized [ORSSerialPort] instance, or nil if there was an error.
  ///
  /// @see [ORSSerialPort.availablePorts]
  /// @see [ORSSerialPort.serialPortWithPath]
  factory ORSSerialPort.withPath(String path) {
    final serial = _bindings.ORSSerialPort.alloc().initWithPath(
      path.toNSString(),
    );

    if (serial == null) {
      throw Exception("Could not create serial port");
    }

    return ORSSerialPort._fromNativePort(serial);
  }

  /// Returns an `ORSSerialPort` instance for the serial port represented by `device`.
  ///
  /// Generally, `+serialPortWithPath:` is the method to use to get port instances
  /// programatically. This method may be useful if you're doing your own
  /// device discovery with IOKit functions, or otherwise have an IOKit port object
  /// you want to "turn into" an ORSSerialPort. Most people will not use this method
  /// directly.
  ///
  /// @param device An IOKit port object representing the serial port device.
  ///
  /// @return An initalized `ORSSerialPort` instance, or nil if there was an error.
  ///
  /// @see [ORSSerialPort.availablePorts]
  /// @see [ORSSerialPort.serialPortWithPath]
  static ORSSerialPort serialPortWithDevice(int device) {
    // create the serial port
    final serial = _bindings.ORSSerialPort.serialPortWithDevice(device);
    if (serial == null) {
      throw Exception("Could not create serial port");
    }

    return ORSSerialPort._fromNativePort(serial);
  }

  /// Returns an `ORSSerialPort` instance for the serial port represented by `device`.
  ///
  /// Generally, `-initWithPath:` is the method to use to get port instances
  /// programatically. This method may be useful if you're doing your own
  /// device discovery with IOKit functions, or otherwise have an IOKit port object
  /// you want to "turn into" an ORSSerialPort. Most people will not use this method
  /// directly.
  ///
  /// @param device An IOKit port object representing the serial port device.
  ///
  /// @return An initalized `ORSSerialPort` instance, or nil if there was an error.
  ///
  /// @see [ORSSerialPort.availablePorts]
  /// @see [ORSSerialPort.withPath]
  factory ORSSerialPort.withDevice(int device) {
    final serial = _bindings.ORSSerialPort.alloc().initWithDevice(device);

    if (serial == null) {
      throw Exception("Could not create serial port");
    }

    return ORSSerialPort._fromNativePort(serial);
  }

  int get baudRate => _serialPort.baudRate.integerValue;
  set baudRate(int newValue) {
    _serialPort.baudRate = newValue.toNSNumber();
  }

  void open() {
    return _serialPort.open();
  }

  /// Closes the port represented by the receiver.
  ///
  /// If the port is closed successfully, the ORSSerialPortDelegate method `-serialPortWasClosed:` will
  /// be called before this method returns.
  ///
  /// returns `true` if closing the port was closed successfully, `false` if closing the port failed.
  bool close() {
    return _serialPort.close();
  }

  /// A Boolean value that indicates whether the port is open. (read-only)
  bool get isOpen => _serialPort.open$1;

  /// Sends data synchronously out through the serial port represented by the receiver.
  ///
  /// This method attempts to send all data synchronously. That is, the method
  /// will not return until all passed in data has been sent, or an error has occurred.
  ///
  /// If an error occurs, the ORSSerialPortDelegate method `-serialPort:didEncounterError:` will
  /// be called. The exception to this is if sending data fails because the port
  /// is closed. In that case, this method returns NO, but `-serialPort:didEncounterError:`
  /// is *not* called. You can ensure that the port is open by calling `-isOpen` before
  /// calling this method.
  ///
  /// @note This method can take a long time to return when a very large amount of data
  /// is passed in, due to the relatively slow nature of serial communication. It is better
  /// to send data in discrete short packets if possible, or asynchronously.
  ///
  /// @param data A [Uint8List] object containing the data to be sent.
  ///
  /// @return `true` if sending data succeeded, `false` if an error occurred.
  bool sendData(Uint8List data) {
    return _serialPort.sendData(data.toNSData());
  }

  /// Same as [sendData], but runs asynchronously, on a separate isolate
  ///
  /// Prefer to use this over [sendData]
  Future<bool> sendDataAsync(Uint8List data) async {
    final SendPort helperIsolateSendPort = await _helperIsolateSendPort;
    final int requestId = _nextSendRequestId++;
    final request = _SendRequest(requestId, data);
    final Completer<bool> completer = Completer<bool>();
    _sendRequests[requestId] = completer;
    helperIsolateSendPort.send(request);
    return completer.future;
  }

  /// The SendPort belonging to the helper isolate.
  // TODO: Persist isolates
  Future<SendPort> get _helperIsolateSendPort async {
    // The helper isolate is going to send us back a SendPort, which we want to
    // wait for.
    final Completer<SendPort> completer = Completer<SendPort>();

    // Receive port on the main isolate to receive messages from the helper.
    // We receive two types of messages:
    // 1. A port to send messages on.
    // 2. Responses to requests we sent.
    final ReceivePort receivePort = ReceivePort()
      ..listen((dynamic data) {
        if (data is SendPort) {
          // The helper isolate sent us the port on which we can sent it requests.
          completer.complete(data);
          return;
        }
        if (data is _SendResponse) {
          // The helper isolate sent us a response to a request we sent.
          final Completer<bool> completer = _sendRequests[data.id]!;
          _sendRequests.remove(data.id);
          completer.complete(data.ok);
          return;
        }
        throw UnsupportedError('Unsupported message type: ${data.runtimeType}');
      });

    // Start the helper isolate.
    await Isolate.spawn((SendPort sendPort) async {
      final ReceivePort helperReceivePort = ReceivePort()
        ..listen((dynamic data) {
          // On the helper isolate listen to requests and respond to them.
          if (data is _SendRequest) {
            final bool result = _serialPort.sendData(data.data.toNSData());
            final _SendResponse response = _SendResponse(data.id, result);
            sendPort.send(response);
            return;
          }
          throw UnsupportedError(
            'Unsupported message type: ${data.runtimeType}',
          );
        });

      // Send the port to the main isolate on which we can receive requests.
      sendPort.send(helperReceivePort.sendPort);
    }, receivePort.sendPort);

    // Wait until the helper isolate has sent us back the SendPort on which we
    // can start sending requests.
    return completer.future;
  }

  // Counter to identify [_SumRequest]s and [_SumResponse]s.
  static int _nextSendRequestId = 0;

  /// Mapping from [_SumRequest] `id`s to the completers corresponding to the correct future of the pending request.
  static final Map<int, Completer<bool>> _sendRequests =
      <int, Completer<bool>>{};
}

class _SendRequest {
  final int id;
  final Uint8List data;

  const _SendRequest(this.id, this.data);
}

class _SendResponse {
  final int id;
  final bool ok;

  const _SendResponse(this.id, this.ok);
}

// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// @dart = 2.8

// TODO(gspencergoog): Remove this tag once this test's state leaks/test
// dependencies have been fixed.
// https://github.com/flutter/flutter/issues/85160
// Fails with "flutter test --test-randomize-ordering-seed=1000"
@Tags(<String>['no-shuffle'])

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_tools/src/android/android_device.dart';
import 'package:flutter_tools/src/android/android_workflow.dart';
import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/utils.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/commands/daemon.dart';
import 'package:flutter_tools/src/device.dart';
import 'package:flutter_tools/src/features.dart';
import 'package:flutter_tools/src/fuchsia/fuchsia_workflow.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/ios/ios_workflow.dart';
import 'package:flutter_tools/src/resident_runner.dart';
import 'package:test/fake.dart';

import '../../src/common.dart';
import '../../src/context.dart';
import '../../src/fake_devices.dart';
import '../../src/fakes.dart';

/// Runs a callback using FakeAsync.run while continually pumping the
/// microtask queue. This avoids a deadlock when tests `await` a Future
/// which queues a microtask that will not be processed unless the queue
/// is flushed.
Future<T> _runFakeAsync<T>(Future<T> Function(FakeAsync time) f) async {
  return FakeAsync().run((FakeAsync time) async {
    bool pump = true;
    final Future<T> future = f(time).whenComplete(() => pump = false);
    while (pump) {
      time.flushMicrotasks();
    }
    return future;
  });
}

void main() {
  Daemon daemon;
  NotifyingLogger notifyingLogger;
  BufferLogger bufferLogger;

  group('daemon', () {
    setUp(() {
      bufferLogger = BufferLogger.test();
      notifyingLogger = NotifyingLogger(verbose: false, parent: bufferLogger);
    });

    tearDown(() {
      if (daemon != null) {
        return daemon.shutdown();
      }
      notifyingLogger.dispose();
    });

    testUsingContext('daemon.version command should succeed', () async {
      final StreamController<Map<String, dynamic>> commands = StreamController<Map<String, dynamic>>();
      final StreamController<Map<String, dynamic>> responses = StreamController<Map<String, dynamic>>();
      daemon = Daemon(
        commands.stream,
        responses.add,
        notifyingLogger: notifyingLogger,
      );
      commands.add(<String, dynamic>{'id': 0, 'method': 'daemon.version'});
      final Map<String, dynamic> response = await responses.stream.firstWhere(_notEvent);
      expect(response['id'], 0);
      expect(response['result'], isNotEmpty);
      expect(response['result'], isA<String>());
      await responses.close();
      await commands.close();
    });

    testUsingContext('daemon.getSupportedPlatforms command should succeed', () async {
      final StreamController<Map<String, dynamic>> commands = StreamController<Map<String, dynamic>>();
      final StreamController<Map<String, dynamic>> responses = StreamController<Map<String, dynamic>>();
      daemon = Daemon(
        commands.stream,
        responses.add,
        notifyingLogger: notifyingLogger,
      );
      // Use the flutter_gallery project which has a known set of supported platforms.
      final String projectPath = globals.fs.path.join(getFlutterRoot(), 'dev', 'integration_tests', 'flutter_gallery');

      commands.add(<String, dynamic>{'id': 0, 'method': 'daemon.getSupportedPlatforms', 'params': <String, Object>{'projectRoot': projectPath}});
      final Map<String, dynamic> response = await responses.stream.firstWhere(_notEvent);

      expect(response['id'], 0);
      expect(response['result'], isNotEmpty);
      expect((response['result'] as Map<String, dynamic>)['platforms'], <String>{'macos'});
      await responses.close();
      await commands.close();
    }, overrides: <Type, Generator>{
      // Disable Android/iOS and enable macOS to make sure result is consistent and defaults are tested off.
      FeatureFlags: () => TestFeatureFlags(isAndroidEnabled: false, isIOSEnabled: false, isMacOSEnabled: true),
    });

    testUsingContext('printError should send daemon.logMessage event', () async {
      final StreamController<Map<String, dynamic>> commands = StreamController<Map<String, dynamic>>();
      final StreamController<Map<String, dynamic>> responses = StreamController<Map<String, dynamic>>();
      daemon = Daemon(
        commands.stream,
        responses.add,
        notifyingLogger: notifyingLogger,
      );
      globals.printError('daemon.logMessage test');
      final Map<String, dynamic> response = await responses.stream.firstWhere((Map<String, dynamic> map) {
        return map['event'] == 'daemon.logMessage' && (map['params'] as Map<String, dynamic>)['level'] == 'error';
      });
      expect(response['id'], isNull);
      expect(response['event'], 'daemon.logMessage');
      final Map<String, String> logMessage = castStringKeyedMap(response['params']).cast<String, String>();
      expect(logMessage['level'], 'error');
      expect(logMessage['message'], 'daemon.logMessage test');
      await responses.close();
      await commands.close();
    }, overrides: <Type, Generator>{
      Logger: () => notifyingLogger,
    });

    testUsingContext('printStatus should log to stdout when logToStdout is enabled', () async {
      final StringBuffer buffer = await capturedConsolePrint(() {
        final StreamController<Map<String, dynamic>> commands = StreamController<Map<String, dynamic>>();
        final StreamController<Map<String, dynamic>> responses = StreamController<Map<String, dynamic>>();
        daemon = Daemon(
          commands.stream,
          responses.add,
          notifyingLogger: notifyingLogger,
          logToStdout: true,
        );
        globals.printStatus('daemon.logMessage test');
        return Future<void>.value();
      });

      expect(buffer.toString().trim(), 'daemon.logMessage test');
    }, overrides: <Type, Generator>{
      Logger: () => notifyingLogger,
    });

    testUsingContext('daemon.shutdown command should stop daemon', () async {
      final StreamController<Map<String, dynamic>> commands = StreamController<Map<String, dynamic>>();
      final StreamController<Map<String, dynamic>> responses = StreamController<Map<String, dynamic>>();
      daemon = Daemon(
        commands.stream,
        responses.add,
        notifyingLogger: notifyingLogger,
      );
      commands.add(<String, dynamic>{'id': 0, 'method': 'daemon.shutdown'});
      return daemon.onExit.then<void>((int code) async {
        await commands.close();
        expect(code, 0);
      });
    });

    testUsingContext('app.restart without an appId should report an error', () async {
      final StreamController<Map<String, dynamic>> commands = StreamController<Map<String, dynamic>>();
      final StreamController<Map<String, dynamic>> responses = StreamController<Map<String, dynamic>>();
      daemon = Daemon(
        commands.stream,
        responses.add,
        notifyingLogger: notifyingLogger,
      );

      commands.add(<String, dynamic>{'id': 0, 'method': 'app.restart'});
      final Map<String, dynamic> response = await responses.stream.firstWhere(_notEvent);
      expect(response['id'], 0);
      expect(response['error'], contains('appId is required'));
      await responses.close();
      await commands.close();
    });

    testUsingContext('ext.flutter.debugPaint via service extension without an appId should report an error', () async {
      final StreamController<Map<String, dynamic>> commands = StreamController<Map<String, dynamic>>();
      final StreamController<Map<String, dynamic>> responses = StreamController<Map<String, dynamic>>();
      daemon = Daemon(
        commands.stream,
        responses.add,
        notifyingLogger: notifyingLogger,
      );

      commands.add(<String, dynamic>{
        'id': 0,
        'method': 'app.callServiceExtension',
        'params': <String, String>{
          'methodName': 'ext.flutter.debugPaint',
        },
      });
      final Map<String, dynamic> response = await responses.stream.firstWhere(_notEvent);
      expect(response['id'], 0);
      expect(response['error'], contains('appId is required'));
      await responses.close();
      await commands.close();
    });

    testUsingContext('app.stop without appId should report an error', () async {
      final StreamController<Map<String, dynamic>> commands = StreamController<Map<String, dynamic>>();
      final StreamController<Map<String, dynamic>> responses = StreamController<Map<String, dynamic>>();
      daemon = Daemon(
        commands.stream,
        responses.add,
        notifyingLogger: notifyingLogger,
      );

      commands.add(<String, dynamic>{'id': 0, 'method': 'app.stop'});
      final Map<String, dynamic> response = await responses.stream.firstWhere(_notEvent);
      expect(response['id'], 0);
      expect(response['error'], contains('appId is required'));
      await responses.close();
      await commands.close();
    });

    testUsingContext('device.getDevices should respond with list', () async {
      final StreamController<Map<String, dynamic>> commands = StreamController<Map<String, dynamic>>();
      final StreamController<Map<String, dynamic>> responses = StreamController<Map<String, dynamic>>();
      daemon = Daemon(
        commands.stream,
        responses.add,
        notifyingLogger: notifyingLogger,
      );
      commands.add(<String, dynamic>{'id': 0, 'method': 'device.getDevices'});
      final Map<String, dynamic> response = await responses.stream.firstWhere(_notEvent);
      expect(response['id'], 0);
      expect(response['result'], isList);
      await responses.close();
      await commands.close();
    });

    testUsingContext('device.getDevices reports available devices', () async {
      final StreamController<Map<String, dynamic>> commands = StreamController<Map<String, dynamic>>();
      final StreamController<Map<String, dynamic>> responses = StreamController<Map<String, dynamic>>();
      daemon = Daemon(
        commands.stream,
        responses.add,
        notifyingLogger: notifyingLogger,
      );
      final FakePollingDeviceDiscovery discoverer = FakePollingDeviceDiscovery();
      daemon.deviceDomain.addDeviceDiscoverer(discoverer);
      discoverer.addDevice(FakeAndroidDevice());
      commands.add(<String, dynamic>{'id': 0, 'method': 'device.getDevices'});
      final Map<String, dynamic> response = await responses.stream.firstWhere(_notEvent);
      expect(response['id'], 0);
      final dynamic result = response['result'];
      expect(result, isList);
      expect(result, isNotEmpty);
      await responses.close();
      await commands.close();
    });

    testUsingContext('should send device.added event when device is discovered', () async {
      final StreamController<Map<String, dynamic>> commands = StreamController<Map<String, dynamic>>();
      final StreamController<Map<String, dynamic>> responses = StreamController<Map<String, dynamic>>();
      daemon = Daemon(
        commands.stream,
        responses.add,
        notifyingLogger: notifyingLogger,
      );

      final FakePollingDeviceDiscovery discoverer = FakePollingDeviceDiscovery();
      daemon.deviceDomain.addDeviceDiscoverer(discoverer);
      discoverer.addDevice(FakeAndroidDevice());

      return responses.stream.skipWhile(_isConnectedEvent).first.then<void>((Map<String, dynamic> response) async {
        expect(response['event'], 'device.added');
        expect(response['params'], isMap);

        final Map<String, dynamic> params = castStringKeyedMap(response['params']);
        expect(params['platform'], isNotEmpty); // the fake device has a platform of 'android-arm'

        await responses.close();
        await commands.close();
      });
    }, overrides: <Type, Generator>{
      AndroidWorkflow: () => FakeAndroidWorkflow(),
      IOSWorkflow: () => FakeIOSWorkflow(),
      FuchsiaWorkflow: () => FakeFuchsiaWorkflow(),
    });

    testUsingContext('emulator.launch without an emulatorId should report an error', () async {
      final StreamController<Map<String, dynamic>> commands = StreamController<Map<String, dynamic>>();
      final StreamController<Map<String, dynamic>> responses = StreamController<Map<String, dynamic>>();
      daemon = Daemon(
        commands.stream,
        responses.add,
        notifyingLogger: notifyingLogger,
      );

      commands.add(<String, dynamic>{'id': 0, 'method': 'emulator.launch'});
      final Map<String, dynamic> response = await responses.stream.firstWhere(_notEvent);
      expect(response['id'], 0);
      expect(response['error'], contains('emulatorId is required'));
      await responses.close();
      await commands.close();
    });

    testUsingContext('emulator.launch coldboot parameter must be boolean', () async {
      final StreamController<Map<String, dynamic>> commands = StreamController<Map<String, dynamic>>();
      final StreamController<Map<String, dynamic>> responses = StreamController<Map<String, dynamic>>();
      daemon = Daemon(
        commands.stream,
        responses.add,
        notifyingLogger: notifyingLogger,
      );
      final Map<String, dynamic> params = <String, dynamic>{'emulatorId': 'device', 'coldBoot': 1};
      commands.add(<String, dynamic>{'id': 0, 'method': 'emulator.launch', 'params': params});
      final Map<String, dynamic> response = await responses.stream.firstWhere(_notEvent);
      expect(response['id'], 0);
      expect(response['error'], contains('coldBoot is not a bool'));
      await responses.close();
      await commands.close();
    });

    testUsingContext('emulator.getEmulators should respond with list', () async {
      final StreamController<Map<String, dynamic>> commands = StreamController<Map<String, dynamic>>();
      final StreamController<Map<String, dynamic>> responses = StreamController<Map<String, dynamic>>();
      daemon = Daemon(
        commands.stream,
        responses.add,
        notifyingLogger: notifyingLogger,
      );
      commands.add(<String, dynamic>{'id': 0, 'method': 'emulator.getEmulators'});
      final Map<String, dynamic> response = await responses.stream.firstWhere(_notEvent);
      expect(response['id'], 0);
      expect(response['result'], isList);
      await responses.close();
      await commands.close();
    });

    testUsingContext('daemon can send exposeUrl requests to the client', () async {
      const String originalUrl = 'http://localhost:1234/';
      const String mappedUrl = 'https://publichost:4321/';
      final StreamController<Map<String, dynamic>> input = StreamController<Map<String, dynamic>>();
      final StreamController<Map<String, dynamic>> output = StreamController<Map<String, dynamic>>();

      daemon = Daemon(
        input.stream,
        output.add,
        notifyingLogger: notifyingLogger,
      );

      // Respond to any requests from the daemon to expose a URL.
      unawaited(output.stream
        .firstWhere((Map<String, dynamic> request) => request['method'] == 'app.exposeUrl')
        .then((Map<String, dynamic> request) {
          expect((request['params'] as Map<String, dynamic>)['url'], equals(originalUrl));
          input.add(<String, dynamic>{'id': request['id'], 'result': <String, dynamic>{'url': mappedUrl}});
        })
      );

      final String exposedUrl = await daemon.daemonDomain.exposeUrl(originalUrl);
      expect(exposedUrl, equals(mappedUrl));

      await output.close();
      await input.close();
    });

    testUsingContext('devtools.serve command should return host and port on success', () async {
      final StreamController<Map<String, dynamic>> commands = StreamController<Map<String, dynamic>>();
      final StreamController<Map<String, dynamic>> responses = StreamController<Map<String, dynamic>>();
      daemon = Daemon(
        commands.stream,
        responses.add,
        notifyingLogger: notifyingLogger,
      );

      commands.add(<String, dynamic>{'id': 0, 'method': 'devtools.serve'});
      final Map<String, dynamic> response = await responses.stream.firstWhere((Map<String, dynamic> response) => response['id'] == 0);
      final Map<String, dynamic> result = response['result'] as Map<String, dynamic>;
      expect(result, isNotEmpty);
      expect(result['host'], '127.0.0.1');
      expect(result['port'], 1234);
      await responses.close();
      await commands.close();
    }, overrides: <Type, Generator>{
      DevtoolsLauncher: () => FakeDevtoolsLauncher(DevToolsServerAddress('127.0.0.1', 1234)),
    });

    testUsingContext('devtools.serve command should return null fields if null returned', () async {
      final StreamController<Map<String, dynamic>> commands = StreamController<Map<String, dynamic>>();
      final StreamController<Map<String, dynamic>> responses = StreamController<Map<String, dynamic>>();
      daemon = Daemon(
        commands.stream,
        responses.add,
        notifyingLogger: notifyingLogger,
      );

      commands.add(<String, dynamic>{'id': 0, 'method': 'devtools.serve'});
      final Map<String, dynamic> response = await responses.stream.firstWhere((Map<String, dynamic> response) => response['id'] == 0);
      final Map<String, dynamic> result = response['result'] as Map<String, dynamic>;
      expect(result, isNotEmpty);
      expect(result['host'], null);
      expect(result['port'], null);
      await responses.close();
      await commands.close();
    }, overrides: <Type, Generator>{
      DevtoolsLauncher: () => FakeDevtoolsLauncher(null),
    });
  });

  testUsingContext('notifyingLogger outputs trace messages in verbose mode', () async {
    final NotifyingLogger logger = NotifyingLogger(verbose: true, parent: bufferLogger);

    logger.printTrace('test');

    expect(bufferLogger.errorText, contains('test'));
  });

  testUsingContext('notifyingLogger ignores trace messages in non-verbose mode', () async {
    final NotifyingLogger logger = NotifyingLogger(verbose: false, parent: bufferLogger);

    final Future<LogMessage> messageResult = logger.onMessage.first;
    logger.printTrace('test');
    logger.printStatus('hello');

    final LogMessage message = await messageResult;

    expect(message.level, 'status');
    expect(message.message, 'hello');
    expect(bufferLogger.errorText, contains('test'));
  });

  testUsingContext('notifyingLogger buffers messages sent before a subscription', () async {
    final NotifyingLogger logger = NotifyingLogger(verbose: false, parent: bufferLogger);

    logger.printStatus('hello');

    final LogMessage message = await logger.onMessage.first;

    expect(message.level, 'status');
    expect(message.message, 'hello');
  });

  group('daemon serialization', () {
    test('OperationResult', () {
      expect(
        jsonEncodeObject(OperationResult.ok),
        '{"code":0,"message":""}',
      );
      expect(
        jsonEncodeObject(OperationResult(1, 'foo')),
        '{"code":1,"message":"foo"}',
      );
    });
  });

  group('daemon queue', () {
    DebounceOperationQueue<int, String> queue;
    const Duration debounceDuration = Duration(seconds: 1);

    setUp(() {
      queue = DebounceOperationQueue<int, String>();
    });

    testWithoutContext(
        'debounces/merges same operation type and returns same result',
        () async {
      await _runFakeAsync((FakeAsync time) async {
        final List<Future<int>> operations = <Future<int>>[
          queue.queueAndDebounce('OP1', debounceDuration, () async => 1),
          queue.queueAndDebounce('OP1', debounceDuration, () async => 2),
        ];

        time.elapse(debounceDuration * 5);
        final List<int> results = await Future.wait(operations);

        expect(results, orderedEquals(<int>[1, 1]));
      });
    });

    testWithoutContext('does not merge results outside of the debounce duration',
        () async {
      await _runFakeAsync((FakeAsync time) async {
        final List<Future<int>> operations = <Future<int>>[
          queue.queueAndDebounce('OP1', debounceDuration, () async => 1),
          Future<int>.delayed(debounceDuration * 2).then((_) =>
              queue.queueAndDebounce('OP1', debounceDuration, () async => 2)),
        ];

        time.elapse(debounceDuration * 5);
        final List<int> results = await Future.wait(operations);

        expect(results, orderedEquals(<int>[1, 2]));
      });
    });

    testWithoutContext('does not merge results of different operations',
        () async {
      await _runFakeAsync((FakeAsync time) async {
        final List<Future<int>> operations = <Future<int>>[
          queue.queueAndDebounce('OP1', debounceDuration, () async => 1),
          queue.queueAndDebounce('OP2', debounceDuration, () async => 2),
        ];

        time.elapse(debounceDuration * 5);
        final List<int> results = await Future.wait(operations);

        expect(results, orderedEquals(<int>[1, 2]));
      });
    });

    testWithoutContext('does not run any operations concurrently', () async {
      // Crete a function that's slow, but throws if another instance of the
      // function is running.
      bool isRunning = false;
      Future<int> f(int ret) async {
        if (isRunning) {
          throw 'Functions ran concurrently!';
        }
        isRunning = true;
        await Future<void>.delayed(debounceDuration * 2);
        isRunning = false;
        return ret;
      }

      await _runFakeAsync((FakeAsync time) async {
        final List<Future<int>> operations = <Future<int>>[
          queue.queueAndDebounce('OP1', debounceDuration, () => f(1)),
          queue.queueAndDebounce('OP2', debounceDuration, () => f(2)),
        ];

        time.elapse(debounceDuration * 5);
        final List<int> results = await Future.wait(operations);

        expect(results, orderedEquals(<int>[1, 2]));
      });
    });
  });
}

bool _notEvent(Map<String, dynamic> map) => map['event'] == null;

bool _isConnectedEvent(Map<String, dynamic> map) => map['event'] == 'daemon.connected';

class FakeFuchsiaWorkflow extends Fake implements FuchsiaWorkflow {
  FakeFuchsiaWorkflow({ this.canListDevices = true });

  @override
  final bool canListDevices;
}

class FakeAndroidWorkflow extends Fake implements AndroidWorkflow {
  FakeAndroidWorkflow({ this.canListDevices = true });

  @override
  final bool canListDevices;
}

class FakeIOSWorkflow extends Fake implements IOSWorkflow {
  FakeIOSWorkflow({ this.canListDevices = true });

  @override
  final bool canListDevices;
}

// Unfortunately Device, despite not being immutable, has an `operator ==`.
// Until we fix that, we have to also ignore related lints here.
// ignore: avoid_implementing_value_types
class FakeAndroidDevice extends Fake implements AndroidDevice {
  @override
  final String id = 'device';

  @override
  final String name = 'device';

  @override
  Future<String> get emulatorId async => 'device';

  @override
  Future<TargetPlatform> get targetPlatform async => TargetPlatform.android_arm;

  @override
  Future<bool> get isLocalEmulator async => false;

  @override
  final Category category = Category.mobile;

  @override
  final PlatformType platformType = PlatformType.android;

  @override
  final bool ephemeral = false;
}

class FakeDevtoolsLauncher extends Fake implements DevtoolsLauncher {
  FakeDevtoolsLauncher(this._serverAddress);

  final DevToolsServerAddress _serverAddress;

  @override
  Future<DevToolsServerAddress> serve() async => _serverAddress;

  @override
  Future<void> close() async {}
}

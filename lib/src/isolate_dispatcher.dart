// Copyright 2019 Google Inc. Use of this source code is governed by an
// MIT-style license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:protobuf/protobuf.dart';
import 'package:stream_channel/isolate_channel.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:tuple/tuple.dart';

import 'embedded_sass.pb.dart';
import 'utils.dart';
import 'dispatcher.dart';

/// A class that dispatches messages to and from the host.
class IsolateDispatcher {
  /// The channel of encoded protocol buffers, connected to the host.
  final StreamChannel<Uint8List> _channel;

  /// The set of all sinks for communicating with isolates.
  final _allIsolates = <StreamSink<GeneratedMessage>>{};

  /// A list whose indexes are outstanding request IDs and whose elements are
  /// the sinks for isolates that are waiting for responses to those requests.
  ///
  /// A `null` element indicates an ID whose request has been responded to.
  final _outstandingRequests = <StreamSink<GeneratedMessage>?>[];

  var _nextIsolateId = 0;

  IsolateDispatcher(this._channel);

  void listen() {
    _channel.stream.listen((binaryMessage) async {
      late InboundMessage message;
      try {
        message = InboundMessage.fromBuffer(binaryMessage);
      } on InvalidProtocolBufferException catch (error) {
        throw parseError(error.message);
      }

      switch (message.whichMessage()) {
        case InboundMessage_Message.versionRequest:
          var request = message.versionRequest;
          var response = versionResponse();
          response.id = request.id;
          _send(OutboundMessage()..versionResponse = response);
          break;

        case InboundMessage_Message.compileRequest:
          var request = message.compileRequest;
          var response = await _compile(message);
          response.id = request.id;
          _send(OutboundMessage()..compileResponse = response);
          break;

        case InboundMessage_Message.canonicalizeResponse:
          var response = message.canonicalizeResponse;
          _dispatchResponse(response.id, message);
          break;

        case InboundMessage_Message.importResponse:
          var response = message.importResponse;
          _dispatchResponse(response.id, message);
          break;

        case InboundMessage_Message.fileImportResponse:
          var response = message.fileImportResponse;
          _dispatchResponse(response.id, message);
          break;

        case InboundMessage_Message.functionCallResponse:
          var response = message.functionCallResponse;
          _dispatchResponse(response.id, message);
          break;

        case InboundMessage_Message.notSet:
          throw parseError("InboundMessage.message is not set.");

        default:
          throw parseError("Unknown message type: ${message.toDebugString()}");
      }
    });
  }

  Future<OutboundMessage_CompileResponse> _compile(
      InboundMessage compileRequest) async {
    var receivePort = ReceivePort();
    await Isolate.spawn(
        _isolateMain, Tuple2(receivePort.sendPort, _nextIsolateId++));

    var channel = IsolateChannel<GeneratedMessage>.connectReceive(receivePort);
    _allIsolates.add(channel.sink);
    channel.sink.add(compileRequest);

    await for (var message in channel.stream.cast<OutboundMessage>()) {
      // TODO before landing: close out the process on unrecoverable errors.
      if (message.whichMessage() == OutboundMessage_Message.compileResponse) {
        // TODO before landing: see if re-using isolates is more efficient
        channel.sink.close();
        return message.compileResponse;
      }

      _send(message);

      var id = _getOutboundId(message);
      if (id >= _outstandingRequests.length) {
        _outstandingRequests.length = id + 1;
      }

      assert(_outstandingRequests[id] == null);
      _outstandingRequests[id] = channel.sink;
    }

    throw StateError(
        "IsolateChannel closed without sending a CompileResponse.");
  }

  // TODO before landing: make this an extensio method.
  int _getOutboundId(OutboundMessage message) {
    switch (message.whichMessage()) {
      case OutboundMessage_Message.compileResponse:
        return message.compileResponse.id;
      case OutboundMessage_Message.canonicalizeRequest:
        return message.canonicalizeRequest.id;
      case OutboundMessage_Message.importRequest:
        return message.importRequest.id;
      case OutboundMessage_Message.fileImportRequest:
        return message.fileImportRequest.id;
      case OutboundMessage_Message.functionCallRequest:
        return message.functionCallRequest.id;
      case OutboundMessage_Message.versionResponse:
        return message.versionResponse.id;
      default:
        throw ArgumentError("Unknown message type: ${message.toDebugString()}");
    }
  }

  /// Creates a [OutboundMessage_VersionResponse]
  static OutboundMessage_VersionResponse versionResponse() {
    return OutboundMessage_VersionResponse()
      ..protocolVersion = const String.fromEnvironment("protocol-version")
      ..compilerVersion = const String.fromEnvironment("compiler-version")
      ..implementationVersion =
          const String.fromEnvironment("implementation-version")
      ..implementationName = "Dart Sass";
  }

  /// Dispatches [response] to the appropriate outstanding request.
  ///
  /// Throws an error if there's no outstanding request with the given [id].
  void _dispatchResponse<T extends GeneratedMessage>(int id, T response) {
    Sink<GeneratedMessage>? sink;
    if (id < _outstandingRequests.length) {
      sink = _outstandingRequests[id];
      _outstandingRequests[id] = null;
    }

    if (sink == null) {
      throw paramsError(
          "Response ID $id doesn't match any outstanding requests.");
    }

    sink.add(response);
  }

  /// Sends [message] to the host.
  void _send(OutboundMessage message) =>
      _channel.sink.add(message.writeToBuffer());
}

void _isolateMain(Tuple2<SendPort, int> args) {
  var channel = IsolateChannel<GeneratedMessage>.connectSend(args.item1);
  Dispatcher(
      channel.stream.cast<InboundMessage>(),
      channel.sink.transform(StreamSinkTransformer.fromHandlers(
          handleData: (data, sink) => sink.add(data))),
        args.item2).listen();
}

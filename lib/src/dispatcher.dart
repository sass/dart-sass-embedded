// Copyright 2019 Google Inc. Use of this source code is governed by an
// MIT-style license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:protobuf/protobuf.dart';
import 'package:sass/sass.dart' as sass;
import 'package:stack_trace/stack_trace.dart';

import 'embedded_sass.pb.dart';
import 'function_registry.dart';
import 'host_callable.dart';
import 'importer/file.dart';
import 'importer/host.dart';
import 'logger.dart';
import 'util/proto_extensions.dart';
import 'utils.dart';

/// A class that dispatches messages to and from the host.
class Dispatcher {
  /// The stream of messages sent from the host to the compiler.
  final Stream<InboundMessage> _stream;

  /// The sink for sending messages from the compiler to the host.
  final StreamSink<OutboundMessage> _sink;

  /// The ID to use for outbound requests.
  ///
  /// This is always the same ID because a single isolate only ever has one
  /// outbound request active at a time.
  final int _outboundId;

  /// Completers awaiting responses to outbound requests.
  ///
  /// The completers are located at indexes in this list matching the request
  /// IDs. `null` elements indicate IDs whose requests have been responded to,
  /// and which are therefore free to re-use.
  Completer<GeneratedMessage>? _outstandingRequest;

  /// Creates a [Dispatcher] that sends and receives encoded protocol buffers
  /// over [channel].
  Dispatcher(this._stream, this._sink, this._outboundId);

  /// Listens for incoming `CompileRequests` and passes them to [callback].
  ///
  /// The callback must return a `CompileResponse` which is sent to the host.
  /// The callback may throw [ProtocolError]s, which will be sent back to the
  /// host. Neither `CompileResponse`s nor [ProtocolError]s need to set their
  /// `id` fields; the [Dispatcher] will take care of that.
  ///
  /// This may only be called once.
  void listen() {
    _stream.listen((message) async {
      try {
        switch (message.whichMessage()) {
          // VersionRequest is handled by the isolate dispatcher.

          case InboundMessage_Message.compileRequest:
            var request = message.compileRequest;
            var response = await _compile(request);
            response.id = request.id;
            _send(OutboundMessage()..compileResponse = response);
            break;

          case InboundMessage_Message.canonicalizeResponse:
            var response = message.canonicalizeResponse;
            _dispatchResponse(response.id, response);
            break;

          case InboundMessage_Message.importResponse:
            var response = message.importResponse;
            _dispatchResponse(response.id, response);
            break;

          case InboundMessage_Message.fileImportResponse:
            var response = message.fileImportResponse;
            _dispatchResponse(response.id, response);
            break;

          case InboundMessage_Message.functionCallResponse:
            var response = message.functionCallResponse;
            _dispatchResponse(response.id, response);
            break;

          case InboundMessage_Message.notSet:
            throw parseError("InboundMessage.message is not set.");

          default:
            throw parseError(
                "Unknown message type: ${message.toDebugString()}");
        }
      } on ProtocolError catch (error) {
        error.id = _inboundId(message) ?? errorId;
        stderr.write("Host caused ${error.type.name.toLowerCase()} error");
        if (error.id != errorId) stderr.write(" with request ${error.id}");
        stderr.writeln(": ${error.message}");
        sendError(error);
        // PROTOCOL error from https://bit.ly/2poTt90
        exitCode = 76;
        _sink.close();
      } catch (error, stackTrace) {
        var errorMessage = "$error\n${Chain.forTrace(stackTrace)}";
        stderr.write("Internal compiler error: $errorMessage");
        sendError(ProtocolError()
          ..type = ProtocolErrorType.INTERNAL
          ..id = _inboundId(message) ?? errorId
          ..message = errorMessage);
        _sink.close();
      }
    });
  }

  Future<OutboundMessage_CompileResponse> _compile(
      InboundMessage_CompileRequest request) async {
    var functions = FunctionRegistry();

    var style = request.style == OutputStyle.COMPRESSED
        ? sass.OutputStyle.compressed
        : sass.OutputStyle.expanded;
    var logger = Logger(this, request.id,
        color: request.alertColor, ascii: request.alertAscii);

    try {
      var importers = request.importers.map((importer) =>
          _decodeImporter(request, importer) ??
          (throw mandatoryError("Importer.importer")));

      var globalFunctions = request.globalFunctions.map((signature) {
        try {
          return hostCallable(this, functions, request.id, signature);
        } on sass.SassException catch (error) {
          throw paramsError('CompileRequest.global_functions: $error');
        }
      });

      late sass.CompileResult result;
      switch (request.whichInput()) {
        case InboundMessage_CompileRequest_Input.string:
          var input = request.string;
          result = sass.compileStringToResult(input.source,
              color: request.alertColor,
              logger: logger,
              importers: importers,
              importer: _decodeImporter(request, input.importer) ??
                  (input.url.startsWith("file:") ? null : sass.Importer.noOp),
              functions: globalFunctions,
              syntax: syntaxToSyntax(input.syntax),
              style: style,
              url: input.url.isEmpty ? null : input.url,
              quietDeps: request.quietDeps,
              verbose: request.verbose,
              sourceMap: request.sourceMap,
              charset: request.charset);
          break;

        case InboundMessage_CompileRequest_Input.path:
          if (request.path.isEmpty) {
            throw mandatoryError("CompileRequest.Input.path");
          }

          try {
            result = sass.compileToResult(request.path,
                color: request.alertColor,
                logger: logger,
                importers: importers,
                functions: globalFunctions,
                style: style,
                quietDeps: request.quietDeps,
                verbose: request.verbose,
                sourceMap: request.sourceMap,
                charset: request.charset);
          } on FileSystemException catch (error) {
            return OutboundMessage_CompileResponse()
              ..failure = (OutboundMessage_CompileResponse_CompileFailure()
                ..message = error.path == null
                    ? error.message
                    : "${error.message}: ${error.path}"
                ..span = (SourceSpan()
                  ..start = SourceSpan_SourceLocation()
                  ..end = SourceSpan_SourceLocation()
                  ..url = p.toUri(request.path).toString()));
          }
          break;

        case InboundMessage_CompileRequest_Input.notSet:
          throw mandatoryError("CompileRequest.input");
      }

      var success = OutboundMessage_CompileResponse_CompileSuccess()
        ..css = result.css
        ..loadedUrls.addAll(result.loadedUrls.map((url) => url.toString()));

      var sourceMap = result.sourceMap;
      if (sourceMap != null) {
        success.sourceMap = json.encode(sourceMap.toJson(
            includeSourceContents: request.sourceMapIncludeSources));
      }
      return OutboundMessage_CompileResponse()..success = success;
    } on sass.SassException catch (error) {
      var formatted = withGlyphs(
          () => error.toString(color: request.alertColor),
          ascii: request.alertAscii);
      return OutboundMessage_CompileResponse()
        ..failure = (OutboundMessage_CompileResponse_CompileFailure()
          ..message = error.message
          ..span = protofySpan(error.span)
          ..stackTrace = error.trace.toString()
          ..formatted = formatted);
    }
  }

  /// Converts [importer] into a [sass.Importer].
  sass.Importer? _decodeImporter(InboundMessage_CompileRequest request,
      InboundMessage_CompileRequest_Importer importer) {
    switch (importer.whichImporter()) {
      case InboundMessage_CompileRequest_Importer_Importer.path:
        return sass.FilesystemImporter(importer.path);

      case InboundMessage_CompileRequest_Importer_Importer.importerId:
        return HostImporter(this, request.id, importer.importerId);

      case InboundMessage_CompileRequest_Importer_Importer.fileImporterId:
        return FileImporter(this, request.id, importer.fileImporterId);

      case InboundMessage_CompileRequest_Importer_Importer.notSet:
        return null;
    }
  }

  /// Sends [event] to the host.
  void sendLog(OutboundMessage_LogEvent event) =>
      _send(OutboundMessage()..logEvent = event);

  /// Sends [error] to the host.
  void sendError(ProtocolError error) =>
      _send(OutboundMessage()..error = error);

  Future<InboundMessage_CanonicalizeResponse> sendCanonicalizeRequest(
          OutboundMessage_CanonicalizeRequest request) =>
      _sendRequest<InboundMessage_CanonicalizeResponse>(
          OutboundMessage()..canonicalizeRequest = request);

  Future<InboundMessage_ImportResponse> sendImportRequest(
          OutboundMessage_ImportRequest request) =>
      _sendRequest<InboundMessage_ImportResponse>(
          OutboundMessage()..importRequest = request);

  Future<InboundMessage_FileImportResponse> sendFileImportRequest(
          OutboundMessage_FileImportRequest request) =>
      _sendRequest<InboundMessage_FileImportResponse>(
          OutboundMessage()..fileImportRequest = request);

  Future<InboundMessage_FunctionCallResponse> sendFunctionCallRequest(
          OutboundMessage_FunctionCallRequest request) =>
      _sendRequest<InboundMessage_FunctionCallResponse>(
          OutboundMessage()..functionCallRequest = request);

  /// Sends [request] to the host and returns the message sent in response.
  Future<T> _sendRequest<T extends GeneratedMessage>(
      OutboundMessage request) async {
    request.id = _outboundId;
    _send(request);

    return (_outstandingRequest = Completer<T>()).future;
  }

  /// Dispatches [response] to the appropriate outstanding request.
  ///
  /// Throws an error if there's no outstanding request with the given [id] or
  /// if that request is expecting a different type of response.
  void _dispatchResponse<T extends GeneratedMessage>(int id, T response) {
    var completer = _outstandingRequest;
    _outstandingRequest = null;
    if (completer == null || id != _outboundId) {
      throw paramsError(
          "Response ID $id doesn't match any outstanding requests.");
    } else if (completer is! Completer<T>) {
      throw paramsError("Request ID $id doesn't match response type "
          "${response.runtimeType}.");
    }

    completer.complete(response);
  }

  /// Sends [message] to the host.
  void _send(OutboundMessage message) => _sink.add(message);

  /// Returns the id for [message] if it it's a request, or `null`
  /// otherwise.
  int? _inboundId(InboundMessage? message) {
    if (message == null) return null;
    switch (message.whichMessage()) {
      case InboundMessage_Message.compileRequest:
        return message.compileRequest.id;
      default:
        return null;
    }
  }
}

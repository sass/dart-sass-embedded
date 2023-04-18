// Copyright 2023 Google Inc. Use of this source code is governed by an
// MIT-style license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import '../embedded_sass.pb.dart';

extension OutboundMessageExtensions on OutboundMessage {
  /// Returns the outbound ID of this message, regardless of its type.
  ///
  /// Throws an [ArgumentError] if [message] doesn't have an id field.
  int get id {
    switch (whichMessage()) {
      case OutboundMessage_Message.compileResponse:
        return compileResponse.id;
      case OutboundMessage_Message.canonicalizeRequest:
        return canonicalizeRequest.id;
      case OutboundMessage_Message.importRequest:
        return importRequest.id;
      case OutboundMessage_Message.fileImportRequest:
        return fileImportRequest.id;
      case OutboundMessage_Message.functionCallRequest:
        return functionCallRequest.id;
      case OutboundMessage_Message.versionResponse:
        return versionResponse.id;
      default:
        throw ArgumentError("Unknown message type: ${toDebugString()}");
    }
  }

  /// Sets the outbound ID of this message, regardless of its type.
  ///
  /// Throws an [ArgumentError] if [message] doesn't have an id field.
  set id(int id) {
    switch (whichMessage()) {
      case OutboundMessage_Message.compileResponse:
        compileResponse.id = id;
        break;
      case OutboundMessage_Message.canonicalizeRequest:
        canonicalizeRequest.id = id;
        break;
      case OutboundMessage_Message.importRequest:
        importRequest.id = id;
        break;
      case OutboundMessage_Message.fileImportRequest:
        fileImportRequest.id = id;
        break;
      case OutboundMessage_Message.functionCallRequest:
        functionCallRequest.id = id;
        break;
      case OutboundMessage_Message.versionResponse:
        versionResponse.id = id;
        break;
      default:
        throw ArgumentError("Unknown message type: ${toDebugString()}");
      }
  }
}

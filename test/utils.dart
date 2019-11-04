// Copyright 2019 Google Inc. Use of this source code is governed by an
// MIT-style license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:sass_embedded/src/embedded_sass.pb.dart';

import 'embedded_process.dart';

/// Returns a [InboundMessage] that compiles the given plain CSS
/// string.
InboundMessage compileString(String css,
    {InboundMessage_Syntax syntax,
    InboundMessage_CompileRequest_OutputStyle style,
    String url,
    bool sourceMap}) {
  var input = InboundMessage_CompileRequest_StringInput()..source = css;
  if (syntax != null) input.syntax = syntax;
  if (url != null) input.url = url;

  var request = InboundMessage_CompileRequest()..string = input;
  if (style != null) request.style = style;
  if (sourceMap != null) request.sourceMap = sourceMap;

  return InboundMessage()..compileRequest = request;
}

/// Asserts that [process] emits a [ProtocolError] parse error with the given
/// [message] on its protobuf stream and prints a notice on stderr.
Future<void> expectParseError(EmbeddedProcess process, message) async {
  await expectLater(process.outbound,
      emits(isProtocolError(-1, ProtocolError_ErrorType.PARSE, message)));
  await expectLater(process.stderr, emits("Host caused parse error: $message"));
}

/// Asserts that an [OutboundMessage] is a [ProtocolError] with the given [id],
/// [type], and optionally [message].
Matcher isProtocolError(int id, ProtocolError_ErrorType type, [message]) =>
    predicate((value) {
      expect(value, isA<OutboundMessage>());
      var outboundMessage = value as OutboundMessage;
      expect(outboundMessage.hasError(), isTrue,
          reason: "Expected $message to be a ProtocolError");
      expect(outboundMessage.error.id, equals(id));
      expect(outboundMessage.error.type, equals(type));
      if (message != null) expect(outboundMessage.error.message, message);
      return true;
    });

/// Asserts that [message] is an [OutboundMessage] with a
/// `CompileResponse.Failure` and returns it.
OutboundMessage_CompileResponse_CompileFailure getCompileFailure(value) {
  var response = getCompileResponse(value);
  expect(response.hasFailure(), isTrue,
      reason: "Expected $response to be a failure");
  return response.failure;
}

/// Asserts that [message] is an [OutboundMessage] with a `CompileResponse` and
/// returns it.
OutboundMessage_CompileResponse getCompileResponse(value) {
  expect(value, isA<OutboundMessage>());
  var message = value as OutboundMessage;
  expect(message.hasCompileResponse(), isTrue,
      reason: "Expected $message to have a CompileResponse");
  return message.compileResponse;
}

/// Asserts that an [OutboundMessage] is a `CompileResponse` with CSS that
/// matches [css], with a source map that matches [sourceMap] (if passed).
///
/// If [css] is a [String], this automatically wraps it in
/// [equalsIgnoringWhitespace].
Matcher isSuccess(css, {sourceMap}) => predicate((value) {
      var response = getCompileResponse(value);
      expect(response.hasSuccess(), isTrue,
          reason: "Expected $response to be successful");
      expect(response.success.css,
          css is String ? equalsIgnoringWhitespace(css) : css);
      if (sourceMap != null) expect(response.success.sourceMap, sourceMap);
      return true;
    });

/// Returns a [SourceSpan_SourceLocation] with the given [offset], [line], and
/// [column].
SourceSpan_SourceLocation location(int offset, int line, int column) =>
    SourceSpan_SourceLocation()
      ..offset = offset
      ..line = line
      ..column = column;

/// Returns a matcher that verifies whether the given value refers to the same
/// path as [expected].
Matcher equalsPath(String expected) => predicate<String>(
    (actual) => p.equals(actual, expected), "equals $expected");

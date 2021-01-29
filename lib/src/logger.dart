// Copyright 2019 Google Inc. Use of this source code is governed by an
// MIT-style license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import 'package:path/path.dart' as p;
import 'package:sass/sass.dart' as sass;
import 'package:source_span/source_span.dart';
import 'package:stack_trace/stack_trace.dart';

import 'dispatcher.dart';
import 'embedded_sass.pb.dart' hide SourceSpan;
import 'utils.dart';

/// A Sass logger that sends log messages as `LogEvent`s.
class Logger implements sass.Logger {
  /// The [Dispatcher] to which to send events.
  final Dispatcher _dispatcher;

  /// The ID of the compilation to which this logger is passed.
  final int _compilationId;

  /// Whether the formatted message should contain terminal colors.
  final bool _color;

  Logger(this._dispatcher, this._compilationId, {bool color = false})
      : _color = color;

  void debug(String message, SourceSpan span) {
    var url =
        span.start.sourceUrl == null ? '-' : p.prettyUri(span.start.sourceUrl);
    var formatted = StringBuffer()
      ..write('$url:${span.start.line + 1} ')
      ..write(_color ? '\u001b[1mDebug\u001b[0m' : 'DEBUG')
      ..writeln(': $message');

    _dispatcher.sendLog(OutboundMessage_LogEvent()
      ..compilationId = _compilationId
      ..type = OutboundMessage_LogEvent_Type.DEBUG
      ..message = message
      ..span = protofySpan(span)
      ..formatted = formatted.toString());
  }

  void warn(String message,
      {FileSpan span, Trace trace, bool deprecation = false}) {
    var formatted = new StringBuffer();
    if (_color) {
      formatted.write('\u001b[33m\u001b[1m');
      if (deprecation) formatted.write('Deprecation ');
      formatted.write('Warning\u001b[0m');
    } else {
      if (deprecation) formatted.write('DEPRECATION ');
      formatted.write('WARNING');
    }
    if (span == null) {
      formatted.writeln(': $message');
    } else if (trace != null) {
      formatted.writeln(': $message\n\n${span.highlight(color: _color)}');
    } else {
      formatted.writeln(' on ${span.message("\n" + message, color: _color)}');
    }
    if (trace != null) {
      formatted.writeln(_indent(trace.toString().trimRight(), 4));
    }

    var event = OutboundMessage_LogEvent()
      ..compilationId = _compilationId
      ..type = deprecation
          ? OutboundMessage_LogEvent_Type.DEPRECATION_WARNING
          : OutboundMessage_LogEvent_Type.WARNING
      ..message = message
      ..formatted = formatted.toString();
    if (span != null) {
      event.span = protofySpan(span);
    }
    if (trace != null) event.stackTrace = trace.toString();
    _dispatcher.sendLog(event);
  }

  // Returns [string] with every line indented [indentation] spaces.
  String _indent(String string, int indentation) =>
      string.split("\n").map((line) => (" " * indentation) + line).join("\n");
}

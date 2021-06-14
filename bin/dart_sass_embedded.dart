// Copyright 2019 Google Inc. Use of this source code is governed by an
// MIT-style license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import 'dart:io';
import 'dart:convert';

import 'package:sass/sass.dart' as sass;
import 'package:source_maps/source_maps.dart' as source_maps;
import 'package:stream_channel/stream_channel.dart';

import 'package:sass_embedded/src/dispatcher.dart';
import 'package:sass_embedded/src/embedded_sass.pb.dart';
import 'package:sass_embedded/src/function_registry.dart';
import 'package:sass_embedded/src/host_callable.dart';
import 'package:sass_embedded/src/importer.dart';
import 'package:sass_embedded/src/logger.dart';
import 'package:sass_embedded/src/util/length_delimited_transformer.dart';
import 'package:sass_embedded/src/utils.dart';

void main(List<String> args) {
  if (args.isNotEmpty) {
    stderr.writeln(
        "This executable is not intended to be executed with arguments.\n"
        "See https://github.com/sass/embedded-protocol#readme for details.");
    // USAGE error from https://bit.ly/2poTt90
    exitCode = 64;
    return;
  }

  var dispatcher = Dispatcher(
      StreamChannel.withGuarantees(stdin, stdout, allowSinkErrors: false)
          .transform(lengthDelimited));

  dispatcher.listen((request) async {
    var functions = FunctionRegistry();

    var style =
        request.style == OutputStyle.COMPRESSED
            ? sass.OutputStyle.compressed
            : sass.OutputStyle.expanded;
    var logger = Logger(dispatcher, request.id,
        color: request.alertColor, ascii: request.alertAscii);

    try {
      String result;
      source_maps.SingleMapping? sourceMap;
      var sourceMapCallback = request.sourceMap
          ? (source_maps.SingleMapping map) => sourceMap = map
          : null;

      var importers = request.importers.map((importer) =>
          _decodeImporter(dispatcher, request, importer) ??
          (throw mandatoryError("Importer.importer")));

      var globalFunctions = request.globalFunctions.map((signature) =>
          hostCallable(dispatcher, functions, request.id, signature));

      switch (request.whichInput()) {
        case InboundMessage_CompileRequest_Input.string:
          var input = request.string;
          result = sass.compileString(input.source,
              color: request.alertColor,
              logger: logger,
              importers: importers,
              importer: _decodeImporter(dispatcher, request, input.importer),
              functions: globalFunctions,
              syntax: syntaxToSyntax(input.syntax),
              style: style,
              url: input.url.isEmpty ? null : input.url,
              quietDeps: request.quietDeps,
              verbose: request.verbose,
              sourceMap: sourceMapCallback);
          break;

        case InboundMessage_CompileRequest_Input.path:
          try {
            result = sass.compile(request.path,
                color: request.alertColor,
                logger: logger,
                importers: importers,
                functions: globalFunctions,
                style: style,
                quietDeps: request.quietDeps,
                verbose: request.verbose,
                sourceMap: sourceMapCallback);
          } on FileSystemException catch (error) {
            return OutboundMessage_CompileResponse()
              ..failure = (OutboundMessage_CompileResponse_CompileFailure()
                ..message = error.path == null
                    ? error.message
                    : "${error.message}: ${error.path}");
          }
          break;

        case InboundMessage_CompileRequest_Input.notSet:
          throw mandatoryError("CompileRequest.input");
      }

      var success = OutboundMessage_CompileResponse_CompileSuccess()
        ..css = result;
      if (sourceMap != null) {
        // dart-lang/language#1536
        success.sourceMap = json.encode(sourceMap!.toJson());
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
  });
}

/// Converts [importer] into an [Importer].
sass.Importer? _decodeImporter(
    Dispatcher dispatcher,
    InboundMessage_CompileRequest request,
    InboundMessage_CompileRequest_Importer importer) {
  switch (importer.whichImporter()) {
    case InboundMessage_CompileRequest_Importer_Importer.path:
      return sass.FilesystemImporter(importer.path);

    case InboundMessage_CompileRequest_Importer_Importer.importerId:
      return Importer(dispatcher, request.id, importer.importerId);

    case InboundMessage_CompileRequest_Importer_Importer.fileImporterId:
      throw "CompileRequest.Importer.fileImporterId is not yet supported";

    case InboundMessage_CompileRequest_Importer_Importer.notSet:
      return null;
  }
}

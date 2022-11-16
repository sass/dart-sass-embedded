// Copyright 2021 Google Inc. Use of this source code is governed by an
// MIT-style license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import 'package:meta/meta.dart';
import 'package:sass_api/sass_api.dart' as sass;

import '../dispatcher.dart';

/// An abstract base class for importers that communicate with the host in some
/// way.
abstract class ImporterBase extends sass.Importer {
  /// The [Dispatcher] to which to send requests.
  @protected
  final Dispatcher dispatcher;

  ImporterBase(this.dispatcher);

  /// Parses [url] as a [Uri] and throws an error if it's invalid or relative
  /// (including root-relative).
  ///
  /// The [field] name is used in the error message if one is thrown.
  @protected
  Uri parseAbsoluteUrl(String field, String url) {
    Uri parsedUrl;
    try {
      parsedUrl = Uri.parse(url);
    } on FormatException catch (error) {
      throw "$field is invalid: $error";
    }

    if (parsedUrl.scheme.isNotEmpty) return parsedUrl;
    throw '$field must be absolute, was "$parsedUrl"';
  }
}

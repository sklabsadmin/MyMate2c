/// Off the web there is no Network Information API, and no equivalent in
/// dart:io. Null rather than a guess: an invented value here would be
/// indistinguishable from a real one in the `connection_type` column, and the
/// column exists to explain failures rather than to be populated.
String? connectionType() => null;

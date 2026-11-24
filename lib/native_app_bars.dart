/// Native (UIKit / Android View) and Flutter top bars and tab bars behind one
/// API, with Dart-owned selection and owner/session-checked native events.
library;

export 'src/config.dart';
export 'src/controller.dart'
    show NativeChromeController, ChromeBarKind, ChromeOwner;
export 'src/descriptors.dart';
export 'src/transport.dart';
export 'src/widgets.dart';
export 'src/document_backdrop.dart';
export 'src/android_header_backdrop.dart';
export 'src/segmented_control.dart';

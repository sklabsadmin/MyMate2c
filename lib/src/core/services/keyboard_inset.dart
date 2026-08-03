/// How many logical pixels the on-screen keyboard covers at the bottom of the
/// window, for platforms where Flutter does not work it out itself.
///
/// On iOS the keyboard does not shrink the layout viewport — `innerHeight` is
/// unchanged and only `visualViewport` moves — so Flutter web can be told
/// nothing happened and `MediaQuery.viewInsets.bottom` stays 0. Anything the
/// framework would normally lift clear of the keyboard (a Scaffold's body, its
/// bottom bar, a text field at the end of a column) therefore stays put,
/// underneath it.
///
/// This measures the gap directly and lets [ScaffoldWithNavBar] fold it into
/// the MediaQuery, after which the ordinary Scaffold behaviour applies.
///
/// Everywhere else — mobile, and browsers that do resize the layout viewport —
/// the stub reports 0 and nothing changes, so this can never double-count an
/// inset the framework has already applied.
export 'keyboard_inset_stub.dart'
    if (dart.library.js_interop) 'keyboard_inset_web.dart';

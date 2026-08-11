/// No-op off the web, where there is no page and no oscillator to drive.
///
/// Mobile builds would want a real sound here if the strip ever shipped on
/// them; today every visitor arrives through a browser, so a silent stub is
/// honest rather than a gap.
void playChime(int step) {}

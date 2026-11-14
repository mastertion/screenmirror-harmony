/**
 * 鸿蒙按键码 → 服务器期望的按键码。
 *
 * 关键事实：APK 里 `SAActivityDisplay.onKeyDown` 直接把
 * `android.view.KeyEvent.getKeyCode()` 塞进键盘报文的 offset 8（`C2597S1.m12697a`），
 * 也就是说 **服务器接收的是 Android keyCode**，不是 Windows VK 码。
 * 因此这里要把鸿蒙的 KeyCode 翻译成 Android 的取值。
 */
export function toServerKeyCode(hosKeyCode: number): number {
  switch (hosKeyCode) {
    case 2012: return 19;   // DPAD_UP
    case 2013: return 20;   // DPAD_DOWN
    case 2014: return 21;   // DPAD_LEFT
    case 2015: return 22;   // DPAD_RIGHT
    case 2016: return 23;   // DPAD_CENTER
    case 2045: return 57;   // ALT_LEFT
    case 2046: return 58;   // ALT_RIGHT
    case 2047: return 59;   // SHIFT_LEFT
    case 2048: return 60;   // SHIFT_RIGHT
    case 2049: return 61;   // TAB
    case 2054: return 66;   // ENTER
    case 2055: return 67;   // DEL（退格）
    case 2067: return 82;   // MENU
    case 2068: return 92;   // PAGE_UP
    case 2069: return 93;   // PAGE_DOWN
    case 2070: return 111;  // ESCAPE
    case 2071: return 112;  // FORWARD_DEL（Delete）
    case 2072: return 113;  // CTRL_LEFT
    case 2073: return 114;  // CTRL_RIGHT
    case 2074: return 115;  // CAPS_LOCK
    case 2076: return 117;  // META_LEFT（Win 键）
    case 2077: return 118;  // META_RIGHT
    case 2081: return 122;  // MOVE_HOME
    case 2082: return 123;  // MOVE_END
    case 2083: return 124;  // INSERT
    default: break;
  }
  // F1..F12：鸿蒙 2090..2101 → Android 131..142
  if (hosKeyCode >= 2090 && hosKeyCode <= 2101) {
    return 131 + (hosKeyCode - 2090);
  }
  // 小键盘 0..9：鸿蒙 2103..2112 → Android 144..153
  if (hosKeyCode >= 2103 && hosKeyCode <= 2112) {
    return 144 + (hosKeyCode - 2103);
  }
  switch (hosKeyCode) {
    case 2113: return 154;  // NUMPAD_DIVIDE
    case 2114: return 155;  // NUMPAD_MULTIPLY
    case 2115: return 156;  // NUMPAD_SUBTRACT
    case 2116: return 157;  // NUMPAD_ADD
    case 2117: return 158;  // NUMPAD_DOT
    default: return -1;
  }
}

/** 是否属于需要按“按下/抬起”上报的功能键（可打印字符走 Text 通道） */
export function isFunctionKey(hosKeyCode: number): boolean {
  return toServerKeyCode(hosKeyCode) > 0;
}

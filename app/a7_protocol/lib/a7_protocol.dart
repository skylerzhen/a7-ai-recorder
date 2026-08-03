/// Pure-Dart core of the 智芯 A7 ("X Note") BLE private protocol.
/// Ports a7ble (Python). Zero Flutter / zero Bluetooth dependencies.
library a7_protocol;

export 'src/crc.dart';
export 'src/framing.dart';
export 'src/advert.dart';
export 'src/commands.dart';
export 'src/mp3.dart';
export 'src/file_transfer.dart';

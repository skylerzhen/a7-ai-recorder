/// BLE advertisement manufacturer-data parsing.
/// Layout: companyId 0x1116 (LE 2B) + MAC (6B) + SN (10 ASCII) = 18B.
const int kCompanyId = 0x1116;

class AdvInfo {
  final int companyId;
  final String mac;
  final String sn;
  final List<int> raw;

  const AdvInfo({
    required this.companyId,
    required this.mac,
    required this.sn,
    required this.raw,
  });
}

/// blob = companyId(2B LE) + MAC(6B) + SN(10 ASCII).
AdvInfo parseManufacturerBlob(List<int> blob) {
  final companyId = (blob[0] & 0xFF) | ((blob[1] & 0xFF) << 8);
  final mac = [
    for (int i = 2; i < 8; i++)
      (blob[i] & 0xFF).toRadixString(16).padLeft(2, '0'),
  ].join(':');
  final sn = String.fromCharCodes(blob.sublist(8, 18).map((b) => b & 0xFF));
  return AdvInfo(
    companyId: companyId,
    mac: mac,
    sn: sn,
    raw: List<int>.unmodifiable(blob),
  );
}

/// The platform BLE scan API (wired up in M2) exposes manufacturerData as
/// {companyId: payload(MAC+SN)} — the payload already excludes the company id.
/// Returns null when our company id is absent (mirrors Python's None).
AdvInfo? parseFromBleak(Map<int, List<int>> manufacturerData) {
  final payload = manufacturerData[kCompanyId];
  if (payload == null) return null;
  final blob = <int>[kCompanyId & 0xFF, (kCompanyId >> 8) & 0xFF, ...payload];
  return parseManufacturerBlob(blob);
}

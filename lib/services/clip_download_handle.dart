/// Batalkan unduh klip antar potongan (bukan di tengah satu klip).
class ClipDownloadHandle {
  bool _stop = false;

  void requestStop() => _stop = true;

  bool get shouldStop => _stop;

  void reset() => _stop = false;
}

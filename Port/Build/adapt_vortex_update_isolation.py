#!/usr/bin/env python3
"""One reversible update-call omission; never edit upstream or drawing."""
from pathlib import Path
import hashlib
VIEW='Sources/Vortex/Views/VortexView.swift'
ORIGINAL_VIEW_SHA256='8050f795edae1e23dcc742334d68d26fd4c93ca93a6b4d850a8ad75a9edfcb38'
ORIGINAL_CALL='                particleSystem.update(date: timeline.date, drawSize: size)\n'
ISOLATION_LINE='                // Letterpress isolate5: deliberately omit particle update; keep Timeline, Canvas, symbols and draw.\n'
def digest(data):return hashlib.sha256(data).hexdigest()
def isolate_update(local:Path,original_swift_sha256:dict)->dict:
    if len(original_swift_sha256)!=26 or original_swift_sha256.get(VIEW)!=ORIGINAL_VIEW_SHA256:
        raise ValueError('Unexpected pinned Vortex source inventory')
    for name,expected in original_swift_sha256.items():
        if digest((local/name).read_bytes())!=expected:
            raise ValueError('Unclean upstream source before update isolation: '+name)
    target=local/VIEW;original=target.read_bytes();old=ORIGINAL_CALL.encode();new=ISOLATION_LINE.encode()
    if original.count(old)!=1 or new in original:raise ValueError('Unexpected update call site')
    adapted=original.replace(old,new,1)
    if adapted.count(new)!=1 or adapted.replace(new,old,1)!=original:
        raise ValueError('Update-only reverse proof failed')
    required=[b'TimelineView(.animation(minimumInterval: 1 / Double(targetFrameRate)))',b'Canvas { context, size in',b'                draw(particleSystem, into: context, at: size)\n',b'} symbols: {',b'private func draw(',b'contextCopy.draw(symbol, at: .zero)',b'targetFrameRate: Int = 60']
    if not all(adapted.count(x)==original.count(x) and original.count(x)>0 for x in required):
        raise ValueError('Original Timeline/Canvas/symbols/draw/default60 structure changed')
    target.write_bytes(adapted)
    compiled={name:digest((local/name).read_bytes()) for name in original_swift_sha256}
    if [name for name in compiled if compiled[name]!=original_swift_sha256[name]]!=[VIEW]:
        raise ValueError('Unexpected renderer mutation set')
    return {'scope':'whole-test-interval','draw_retained':True,'timeline_and_canvas_retained':True,'suppressed_call_count':1,'view_original_sha256':digest(original),'view_adapted_sha256':digest(adapted),'reverse_restores_upstream':True}

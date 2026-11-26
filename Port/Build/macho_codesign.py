#!/usr/bin/env python3
"""Check embedded Mach-O CodeDirectory hashes, not Apple trust or device eligibility."""
import hashlib
import struct


class SignatureError(ValueError):
    pass


def need(value, message):
    if not value:
        raise SignatureError(message)


def u32(data, offset):
    need(0 <= offset <= len(data)-4, 'truncated signature integer')
    return struct.unpack_from('>I', data, offset)[0]


def verify_signature(slice_data, signature_offset, signature_size):
    need(0 < signature_offset < len(slice_data), 'invalid signature offset')
    raw = slice_data[signature_offset:signature_offset+signature_size]
    need(len(raw) == signature_size and len(raw) >= 12, 'truncated signature')
    need(u32(raw, 0) == 0xfade0cc0, 'not an embedded-signature SuperBlob')
    length, count = u32(raw, 4), u32(raw, 8)
    need(12 <= length <= len(raw) and 0 < count <= 64 and 12+8*count <= length,
         'invalid signature SuperBlob dimensions')
    entries, spans = {}, []
    for i in range(count):
        slot, offset = struct.unpack_from('>II', raw, 12+8*i)
        need(slot not in entries, 'duplicate embedded signature slot')
        need(12+8*count <= offset <= length-8, 'embedded blob overlaps index/outside signature')
        size = u32(raw, offset+4)
        need(8 <= size <= length-offset, 'invalid embedded blob size')
        entries[slot] = raw[offset:offset+size]
        spans.append((offset, offset+size))
    spans.sort()
    need(all(a[1] <= b[0] for a, b in zip(spans, spans[1:])), 'overlapping signature blobs')
    need(0 in entries and u32(entries[0], 0) == 0xfade0c02, 'missing primary CodeDirectory')
    directories = []
    for slot, cd in sorted(entries.items()):
        if u32(cd, 0) != 0xfade0c02:
            continue
        need(slot == 0 or 0x1000 <= slot <= 0x1005, 'CodeDirectory in unexpected slot')
        need(len(cd) >= 44, 'short CodeDirectory')
        version, flags, hash_offset, ident_offset, special_slots, code_slots, code_limit = struct.unpack_from('>7I', cd, 8)
        hash_size, hash_type, platform, page_exp = struct.unpack_from('4B', cd, 36)
        need(0x20001 <= version <= 0x20600, 'unsupported CodeDirectory version')
        algorithms = {1: ('sha1', 20), 2: ('sha256', 32), 3: ('sha256', 20), 4: ('sha384', 48)}
        need(hash_type in algorithms, 'unsupported CodeDirectory hash type')
        algorithm, expected_size = algorithms[hash_type]
        need(hash_size == expected_size and page_exp <= 20, 'invalid hash/page size')
        if version >= 0x20300:
            need(len(cd) >= 64, 'short versioned CodeDirectory')
            if code_limit == 0xffffffff:
                code_limit = struct.unpack_from('>Q', cd, 56)[0]
        need(code_limit == signature_offset, 'CodeDirectory must cover all bytes preceding signature')
        page_size = (1 << page_exp) if page_exp else code_limit
        need(code_limit > 0 and page_size > 0, 'empty CodeDirectory coverage')
        expected_slots = (code_limit+page_size-1)//page_size
        need(code_slots == expected_slots and code_slots <= 1000000, 'CodeDirectory slot count mismatch')
        need(special_slots <= 64 and hash_offset-special_slots*hash_size >= 44,
             'special-slot hashes outside CodeDirectory')
        need(hash_offset+code_slots*hash_size <= len(cd), 'code hashes outside CodeDirectory')
        need(44 <= ident_offset < hash_offset-special_slots*hash_size,
             'invalid CodeDirectory identifier offset')
        stop = cd.find(b'\0', ident_offset, hash_offset-special_slots*hash_size)
        need(stop >= 0, 'unterminated CodeDirectory identifier')
        identifier = cd[ident_offset:stop].decode('utf-8', errors='strict')
        for i in range(code_slots):
            page = slice_data[i*page_size:min((i+1)*page_size, code_limit)]
            expected = cd[hash_offset+i*hash_size:hash_offset+(i+1)*hash_size]
            actual = hashlib.new(algorithm, page).digest()[:hash_size]
            need(actual == expected, 'code page hash mismatch at slot '+str(i))
        checked_special, external_special = [], []
        for i in range(1, special_slots+1):
            start = hash_offset-i*hash_size
            expected = cd[start:start+hash_size]
            if i in entries:
                actual = hashlib.new(algorithm, entries[i]).digest()[:hash_size]
                need(actual == expected, 'embedded special-slot hash mismatch at slot '+str(i))
                checked_special.append(i)
            elif expected != bytes(hash_size):
                external_special.append(i)
        directories.append({'slot': slot, 'identifier': identifier, 'hash': algorithm,
                            'code_pages_verified': code_slots, 'covered_bytes': code_limit,
                            'page_size': page_size, 'ad_hoc_flag': bool(flags & 2),
                            'embedded_special_slots_verified': checked_special,
                            'external_special_slots_not_verified': external_special})
    need(directories, 'no verifiable CodeDirectory')
    return {'status': 'embedded code hashes verified; not Apple trust or device validation',
            'directories': directories}
